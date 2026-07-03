/// Measurement annotations — a dimension line drawn on the calibrated sheet
/// whose real-world length comes from the per-sheet scale (§10 geometry is the
/// single source of truth). Annotations are NOT part of the drawn network: they
/// never affect sizing/solve; they round-trip in the `.mechx` project as plain
/// data.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart' show NodeComponent;
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/network_sizing.dart'
    show DuctShape, DuctSizingMethod;
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';

import 'history_store.dart';

/// A two-point dimension annotation on a sheet/floor, in sheet (world) pixels.
@immutable
class Measurement {
  final String id;
  final String sheetId;
  final int floorIndex;
  final double ax;
  final double ay;
  final double bx;
  final double by;

  const Measurement({
    required this.id,
    required this.sheetId,
    required this.floorIndex,
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
  });

  /// Straight-line length in sheet pixels (convert to metres with the sheet's
  /// [ScaleCalibration.lengthForPixels]).
  double get pixelLength {
    final dx = bx - ax;
    final dy = by - ay;
    return math.sqrt(dx * dx + dy * dy);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sheetId': sheetId,
        'floor': floorIndex,
        'ax': ax,
        'ay': ay,
        'bx': bx,
        'by': by,
      };

  /// Tolerant decode — returns null for a non-map or one missing a coordinate,
  /// so a malformed entry is dropped rather than throwing.
  static Measurement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final sheetId = raw['sheetId'];
    final ax = raw['ax'], ay = raw['ay'], bx = raw['bx'], by = raw['by'];
    if (id is! String ||
        sheetId is! String ||
        ax is! num ||
        ay is! num ||
        bx is! num ||
        by is! num) {
      return null;
    }
    return Measurement(
      id: id,
      sheetId: sheetId,
      floorIndex: (raw['floor'] as num?)?.toInt() ?? 0,
      ax: ax.toDouble(),
      ay: ay.toDouble(),
      bx: bx.toDouble(),
      by: by.toDouble(),
    );
  }
}

/// The project's measurement annotations. Mutated by the canvas measure tool;
/// read by the measurement overlay and the persistence layer.
final measurementsProvider =
    NotifierProvider<MeasurementController, List<Measurement>>(
  MeasurementController.new,
);

class MeasurementController extends Notifier<List<Measurement>> {
  int _seq = 0;

  @override
  List<Measurement> build() => const [];

  /// Add a measurement between two world points on [sheetId]/[floorIndex].
  /// Ignores a degenerate (zero-length) span.
  void add({
    required String sheetId,
    required int floorIndex,
    required double ax,
    required double ay,
    required double bx,
    required double by,
  }) {
    if (ax == bx && ay == by) return;
    ref.read(annotationHistoryProvider.notifier).record();
    state = [
      ...state,
      Measurement(
        id: 'm${_seq++}',
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
      ),
    ];
  }

  void removeById(String id) {
    if (!state.any((m) => m.id == id)) return;
    ref.read(annotationHistoryProvider.notifier).record();
    state = [for (final m in state) if (m.id != id) m];
  }

  void clear() => state = const [];

  /// Replace the whole set (used when loading a `.mechx` document). Advances the
  /// fresh-id counter past any loaded ids so new ids never collide.
  void set(List<Measurement> measurements) {
    state = List.unmodifiable(measurements);
    for (final m in measurements) {
      final n = int.tryParse(m.id.replaceFirst('m', ''));
      if (n != null && n >= _seq) _seq = n + 1;
    }
  }
}

/// Construction material of a designated tank/reservoir area. Concrete is the
/// common cast-in-situ ground reservoir; the rest cover packaged tanks.
enum TankMaterial { concrete, panel, steel, hdpe, fibreglass }

extension TankMaterialInfo on TankMaterial {
  String get label => switch (this) {
        TankMaterial.concrete => 'Concrete',
        TankMaterial.panel => 'Panel (FRP)',
        TankMaterial.steel => 'Steel',
        TankMaterial.hdpe => 'HDPE / PVC',
        TankMaterial.fibreglass => 'Fibreglass',
      };
}

/// A rectangular TANK / reservoir area drawn on the calibrated plan: its
/// footprint (two opposite corners, in sheet/world pixels) plus a water [depthM]
/// and [material]. The plan footprint × depth gives the stored capacity — so a
/// concrete ground reservoir can be sized straight off the drawing. Like
/// [Measurement] it is an annotation: it never feeds the network solve, and it
/// round-trips in the `.mechx` project as plain data.
@immutable
class TankArea {
  final String id;
  final String sheetId;
  final int floorIndex;
  final double ax;
  final double ay;
  final double bx;
  final double by;

  /// Water depth (m) — capacity = plan area × depth.
  final double depthM;
  final TankMaterial material;
  final String name;

  const TankArea({
    required this.id,
    required this.sheetId,
    required this.floorIndex,
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
    this.depthM = 2.0,
    this.material = TankMaterial.concrete,
    this.name = 'Tank',
  });

  /// Footprint width / height in sheet pixels.
  double get widthPx => (bx - ax).abs();
  double get heightPx => (by - ay).abs();

  TankArea copyWith({
    double? ax,
    double? ay,
    double? bx,
    double? by,
    double? depthM,
    TankMaterial? material,
    String? name,
  }) =>
      TankArea(
        id: id,
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax ?? this.ax,
        ay: ay ?? this.ay,
        bx: bx ?? this.bx,
        by: by ?? this.by,
        depthM: depthM ?? this.depthM,
        material: material ?? this.material,
        name: name ?? this.name,
      );

  /// Whether sheet-pixel ([px], [py]) on [pSheetId]/[pFloor] falls inside this
  /// tank's footprint (E6 — canvas hit-test to select/move).
  bool containsPoint(String pSheetId, int pFloor, double px, double py) {
    if (pSheetId != sheetId || pFloor != floorIndex) return false;
    final loX = ax < bx ? ax : bx;
    final hiX = ax < bx ? bx : ax;
    final loY = ay < by ? ay : by;
    final hiY = ay < by ? by : ay;
    return px >= loX && px <= hiX && py >= loY && py <= hiY;
  }

  /// Plan area (m²) given the sheet's metres-per-pixel, then capacity in m³ / L.
  double areaM2(double metersPerPixel) =>
      widthPx * heightPx * metersPerPixel * metersPerPixel;
  double volumeM3(double metersPerPixel) => areaM2(metersPerPixel) * depthM;
  double litres(double metersPerPixel) => volumeM3(metersPerPixel) * 1000;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sheetId': sheetId,
        'floor': floorIndex,
        'ax': ax,
        'ay': ay,
        'bx': bx,
        'by': by,
        'depth_m': depthM,
        'material': material.name,
        'name': name,
      };

  /// Tolerant decode — null for a non-map / missing coordinate (dropped, not
  /// thrown). Unknown material falls back to concrete; absent depth → 2.0 m.
  static TankArea? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], sheetId = raw['sheetId'];
    final ax = raw['ax'], ay = raw['ay'], bx = raw['bx'], by = raw['by'];
    if (id is! String ||
        sheetId is! String ||
        ax is! num ||
        ay is! num ||
        bx is! num ||
        by is! num) {
      return null;
    }
    final mat = TankMaterial.values.firstWhere(
      (m) => m.name == raw['material'],
      orElse: () => TankMaterial.concrete,
    );
    return TankArea(
      id: id,
      sheetId: sheetId,
      floorIndex: (raw['floor'] as num?)?.toInt() ?? 0,
      ax: ax.toDouble(),
      ay: ay.toDouble(),
      bx: bx.toDouble(),
      by: by.toDouble(),
      depthM: (raw['depth_m'] as num?)?.toDouble() ?? 2.0,
      material: mat,
      name: raw['name'] is String ? raw['name'] as String : 'Tank',
    );
  }
}

/// The project's designated tank areas. Mutated by the canvas tank tool; read by
/// the tank overlay, the inspector editor, and the persistence layer.
final tankAreasProvider =
    NotifierProvider<TankAreaController, List<TankArea>>(TankAreaController.new);

class TankAreaController extends Notifier<List<TankArea>> {
  int _seq = 0;

  @override
  List<TankArea> build() => const [];

  /// Add a tank from two opposite corners. Ignores a degenerate (zero-area) box.
  void add({
    required String sheetId,
    required int floorIndex,
    required double ax,
    required double ay,
    required double bx,
    required double by,
  }) {
    if ((ax - bx).abs() < 2 || (ay - by).abs() < 2) return;
    ref.read(annotationHistoryProvider.notifier).record();
    // E7: seed a distinct sequential name ('Tank 1', 'Tank 2', …) so a schedule
    // never lists a wall of identical 'Tank' rows; still renamable in-place.
    state = [
      ...state,
      TankArea(
        id: 't$_seq',
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        name: 'Tank ${_seq + 1}',
      ),
    ];
    _seq++;
  }

  void setDepth(String id, double depthM) => _update(
      id, (t) => t.copyWith(depthM: depthM.clamp(0.1, 20).toDouble()));
  void setMaterial(String id, TankMaterial m) =>
      _update(id, (t) => t.copyWith(material: m));
  void setName(String id, String name) => _update(id, (t) => t.copyWith(name: name));

  /// Begin a live geometry drag (move/resize): snapshot the current annotation
  /// state onto the undo stack so the whole drag collapses into ONE undo step
  /// (E6). Call ONCE, on the first movement — pair with [setBounds] (which does
  /// NOT record) during the drag.
  void beginGeometryEdit() =>
      ref.read(annotationHistoryProvider.notifier).record();

  /// Set the footprint corners of [id] WITHOUT recording undo (live drag) —
  /// pair with [beginGeometryEdit] at the first movement. No-op if [id] is gone.
  void setBounds(String id, double ax, double ay, double bx, double by) {
    if (!state.any((t) => t.id == id)) return;
    state = [
      for (final t in state)
        if (t.id == id) t.copyWith(ax: ax, ay: ay, bx: bx, by: by) else t,
    ];
  }

  void _update(String id, TankArea Function(TankArea) f) {
    if (!state.any((t) => t.id == id)) return;
    ref.read(annotationHistoryProvider.notifier).record();
    state = [for (final t in state) if (t.id == id) f(t) else t];
  }

  void removeById(String id) {
    if (!state.any((t) => t.id == id)) return;
    ref.read(annotationHistoryProvider.notifier).record();
    state = [for (final t in state) if (t.id != id) t];
  }

  void clear() => state = const [];

  /// Replace the whole set (used when loading a `.mechx` document). Advances the
  /// fresh-id counter past any loaded ids so new ids never collide.
  void set(List<TankArea> tanks) {
    state = List.unmodifiable(tanks);
    for (final t in tanks) {
      final n = int.tryParse(t.id.replaceFirst('t', ''));
      if (n != null && n >= _seq) _seq = n + 1;
    }
  }
}

/// Whether the canvas tank tool is active (drag to draw a tank footprint).
/// Mutually exclusive with the network draw tools + the measure tool.
final tankModeProvider =
    NotifierProvider<TankModeController, bool>(TankModeController.new);

class TankModeController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
  void toggle() => state = !state;
}

/// Whether the canvas measure tool is active (two-click to place a dimension).
/// Mutually exclusive with the network draw tools — the toolbar collapses the
/// draw tool to select when this turns on, and clears this when a draw tool is
/// chosen.
final measureModeProvider =
    NotifierProvider<MeasureModeController, bool>(MeasureModeController.new);

class MeasureModeController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
  void toggle() => state = !state;
}

/// A rectangular ROOM/ZONE drawn on the calibrated plan, sized for air by the
/// air-change-rate (ACH) method. Its footprint (two opposite corners, in
/// sheet/world pixels) × the per-sheet scale gives the floor area; with a
/// ceiling height and a target ACH the engine derives the design airflow (CFM /
/// L/s) and auto-sizes the supply diffusers, return grille(s), the supply trunk
/// and the AHU/FCU/fan duty (`sizeRoomAir`). Like [TankArea] it is an
/// annotation: it never feeds the pressurised network solve, and it round-trips
/// in the `.mechx` project as plain data.
@immutable
class RoomArea {
  final String id;
  final String sheetId;
  final int floorIndex;
  final double ax;
  final double ay;
  final double bx;
  final double by;

  /// Space type — drives the default ACH and the diffuser face-velocity class.
  final RoomType roomType;

  /// Ceiling height (m) used for the room volume.
  final double ceilingHeightM;

  /// Explicit ACH override; when null the [roomType] default ACH is used.
  final double? achOverride;

  /// Unit serving the room (affects the assumed equipment internal static).
  final AirEquipmentKind equipmentKind;

  final String name;

  const RoomArea({
    required this.id,
    required this.sheetId,
    required this.floorIndex,
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
    this.roomType = RoomType.office,
    this.ceilingHeightM = 3.0,
    this.achOverride,
    this.equipmentKind = AirEquipmentKind.fcu,
    this.name = 'Room',
  });

  /// Footprint width / height in sheet pixels.
  double get widthPx => (bx - ax).abs();
  double get heightPx => (by - ay).abs();

  /// Floor area (m²) given the sheet's metres-per-pixel.
  double areaM2(double metersPerPixel) =>
      widthPx * heightPx * metersPerPixel * metersPerPixel;

  /// Air-change rate actually applied: the [achOverride] if set, else the
  /// [roomType] default from the ventilation profile.
  double effectiveAch() =>
      achOverride ?? const SniVentilationProfile().recommendedAch(roomType).value;

  /// Full air-side sizing for the room, or null when the sheet has no scale or
  /// the footprint is degenerate. Honours the project [ductShape]/[ductMethod].
  RoomAirResult? sizing(
    double? metersPerPixel, {
    DuctShape ductShape = DuctShape.round,
    DuctSizingMethod ductMethod = DuctSizingMethod.velocity,
  }) {
    if (metersPerPixel == null) return null;
    final area = areaM2(metersPerPixel);
    if (area <= 0 || ceilingHeightM <= 0) return null;
    const profile = SniVentilationProfile();
    return sizeRoomAir(
      floorArea: Area(area),
      ceilingHeight: Length(ceilingHeightM),
      airChangesPerHour: effectiveAch(),
      equipmentKind: equipmentKind,
      grilleApplication: profile.grilleApplicationFor(roomType),
      ductShape: ductShape,
      ductMethod: ductMethod,
    );
  }

  /// Estimated AC cooling load (BTU/h · kW · PK + a recommended unit) for the
  /// room, or null when the sheet has no scale / the footprint is degenerate.
  /// The per-area density comes from the ventilation profile (room-type based).
  CoolingLoad? coolingLoad(double? metersPerPixel) {
    if (metersPerPixel == null) return null;
    final area = areaM2(metersPerPixel);
    if (area <= 0 || ceilingHeightM <= 0) return null;
    final density = const SniVentilationProfile()
        .coolingLoadDensityBtuPerHrM2(roomType)
        .value;
    return estimateCoolingLoad(
      floorArea: Area(area),
      ceilingHeight: Length(ceilingHeightM),
      densityBtuPerHrPerM2: density,
    );
  }

  /// True if [component] is an AC indoor unit (cassette / split wall / ducted).
  static bool isAcComponent(NodeComponent? component) =>
      component == NodeComponent.acCassette ||
      component == NodeComponent.acSplitWall ||
      component == NodeComponent.acDucted;

  /// Whether a node at sheet-pixel ([nx], [ny]) on [nodeSheetId]/[nodeFloor]
  /// falls inside this room's footprint (used to attach AC units to a room).
  bool containsNode(String nodeSheetId, int nodeFloor, double nx, double ny) =>
      containsPoint(nodeSheetId, nodeFloor, nx, ny);

  /// Whether sheet-pixel ([px], [py]) on [pSheetId]/[pFloor] falls inside this
  /// room's footprint (E6 — canvas hit-test to select/move).
  bool containsPoint(String pSheetId, int pFloor, double px, double py) {
    if (pSheetId != sheetId || pFloor != floorIndex) return false;
    final loX = ax < bx ? ax : bx;
    final hiX = ax < bx ? bx : ax;
    final loY = ay < by ? ay : by;
    final hiY = ay < by ? by : ay;
    return px >= loX && px <= hiX && py >= loY && py <= hiY;
  }

  RoomArea copyWith({
    double? ax,
    double? ay,
    double? bx,
    double? by,
    RoomType? roomType,
    double? ceilingHeightM,
    Object? achOverride = _unset,
    AirEquipmentKind? equipmentKind,
    String? name,
  }) =>
      RoomArea(
        id: id,
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax ?? this.ax,
        ay: ay ?? this.ay,
        bx: bx ?? this.bx,
        by: by ?? this.by,
        roomType: roomType ?? this.roomType,
        ceilingHeightM: ceilingHeightM ?? this.ceilingHeightM,
        achOverride:
            achOverride == _unset ? this.achOverride : achOverride as double?,
        equipmentKind: equipmentKind ?? this.equipmentKind,
        name: name ?? this.name,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sheetId': sheetId,
        'floor': floorIndex,
        'ax': ax,
        'ay': ay,
        'bx': bx,
        'by': by,
        'roomType': roomType.name,
        'ceiling_m': ceilingHeightM,
        if (achOverride != null) 'ach': achOverride,
        'equipment': equipmentKind.name,
        'name': name,
      };

  /// Tolerant decode — null for a non-map / missing coordinate (dropped, not
  /// thrown). Unknown room type → office, unknown equipment → fcu, absent
  /// ceiling → 3.0 m, absent ACH → null (room-type default applies).
  static RoomArea? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], sheetId = raw['sheetId'];
    final ax = raw['ax'], ay = raw['ay'], bx = raw['bx'], by = raw['by'];
    if (id is! String ||
        sheetId is! String ||
        ax is! num ||
        ay is! num ||
        bx is! num ||
        by is! num) {
      return null;
    }
    final type = RoomType.values.firstWhere(
      (t) => t.name == raw['roomType'],
      orElse: () => RoomType.office,
    );
    final kind = AirEquipmentKind.values.firstWhere(
      (k) => k.name == raw['equipment'],
      orElse: () => AirEquipmentKind.fcu,
    );
    return RoomArea(
      id: id,
      sheetId: sheetId,
      floorIndex: (raw['floor'] as num?)?.toInt() ?? 0,
      ax: ax.toDouble(),
      ay: ay.toDouble(),
      bx: bx.toDouble(),
      by: by.toDouble(),
      roomType: type,
      ceilingHeightM: (raw['ceiling_m'] as num?)?.toDouble() ?? 3.0,
      achOverride: (raw['ach'] as num?)?.toDouble(),
      equipmentKind: kind,
      name: raw['name'] is String ? raw['name'] as String : 'Room',
    );
  }
}

/// Sentinel so [RoomArea.copyWith] can distinguish "leave achOverride" from
/// "set it to null" (clear the override back to the room-type default).
const Object _unset = Object();

/// The project's designated room/zone areas. Mutated by the canvas room tool;
/// read by the room overlay, the inspector editor, and the persistence layer.
final roomAreasProvider =
    NotifierProvider<RoomAreaController, List<RoomArea>>(RoomAreaController.new);

class RoomAreaController extends Notifier<List<RoomArea>> {
  int _seq = 0;

  @override
  List<RoomArea> build() => const [];

  /// Add a room from two opposite corners. Ignores a degenerate (zero-area) box.
  void add({
    required String sheetId,
    required int floorIndex,
    required double ax,
    required double ay,
    required double bx,
    required double by,
  }) {
    if ((ax - bx).abs() < 2 || (ay - by).abs() < 2) return;
    ref.read(annotationHistoryProvider.notifier).record();
    // E7: seed a distinct sequential name ('Room 1', 'Room 2', …) so an issued
    // equipment schedule never lists a wall of identical 'Room' AHU rows; still
    // renamable in-place in the Rooms inspector.
    state = [
      ...state,
      RoomArea(
        id: 'r$_seq',
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        name: 'Room ${_seq + 1}',
      ),
    ];
    _seq++;
  }

  void setRoomType(String id, RoomType t) =>
      _update(id, (r) => r.copyWith(roomType: t));
  void setCeiling(String id, double m) =>
      _update(id, (r) => r.copyWith(ceilingHeightM: m.clamp(1.5, 12).toDouble()));
  void setAch(String id, double? ach) => _update(
      id, (r) => r.copyWith(achOverride: ach?.clamp(0.5, 60).toDouble()));
  void setEquipment(String id, AirEquipmentKind k) =>
      _update(id, (r) => r.copyWith(equipmentKind: k));
  void setName(String id, String name) =>
      _update(id, (r) => r.copyWith(name: name));

  /// Begin a live geometry drag (move/resize): snapshot the current annotation
  /// state onto the undo stack so the whole drag collapses into ONE undo step
  /// (E6). Call ONCE, on the first movement — pair with [setBounds] (which does
  /// NOT record) during the drag.
  void beginGeometryEdit() =>
      ref.read(annotationHistoryProvider.notifier).record();

  /// Set the footprint corners of [id] WITHOUT recording undo (live drag) —
  /// pair with [beginGeometryEdit] at the first movement. No-op if [id] is gone.
  void setBounds(String id, double ax, double ay, double bx, double by) {
    if (!state.any((r) => r.id == id)) return;
    state = [
      for (final r in state)
        if (r.id == id) r.copyWith(ax: ax, ay: ay, bx: bx, by: by) else r,
    ];
  }

  void _update(String id, RoomArea Function(RoomArea) f) {
    if (!state.any((r) => r.id == id)) return;
    ref.read(annotationHistoryProvider.notifier).record();
    state = [for (final r in state) if (r.id == id) f(r) else r];
  }

  void removeById(String id) {
    if (!state.any((r) => r.id == id)) return;
    ref.read(annotationHistoryProvider.notifier).record();
    state = [for (final r in state) if (r.id != id) r];
  }

  void clear() => state = const [];

  /// Replace the whole set (used when loading a `.mechx` document). Advances the
  /// fresh-id counter past any loaded ids so new ids never collide.
  void set(List<RoomArea> rooms) {
    state = List.unmodifiable(rooms);
    for (final r in rooms) {
      final n = int.tryParse(r.id.replaceFirst('r', ''));
      if (n != null && n >= _seq) _seq = n + 1;
    }
  }
}

/// Whether the canvas room tool is active (drag to draw a room footprint).
/// Mutually exclusive with the network draw tools, measure tool, and tank tool.
final roomModeProvider =
    NotifierProvider<RoomModeController, bool>(RoomModeController.new);

class RoomModeController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
  void toggle() => state = !state;
}

/// Which kind of annotation a [SelectedAnnotation] refers to.
enum AnnotationKind { room, tank }

/// The room/tank annotation currently SELECTED (E6) — the single source of
/// truth shared by the canvas overlays (which set it on a click/drag and
/// highlight the matching footprint) and the inspector (which opens + frames the
/// matching master-detail row). `null` ⇒ nothing selected, so a blank project is
/// byte-identical (no highlight, no auto-expanded row).
@immutable
class SelectedAnnotation {
  final AnnotationKind kind;
  final String id;
  const SelectedAnnotation(this.kind, this.id);

  @override
  bool operator ==(Object other) =>
      other is SelectedAnnotation && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

final selectedAnnotationProvider =
    NotifierProvider<SelectedAnnotationController, SelectedAnnotation?>(
  SelectedAnnotationController.new,
);

class SelectedAnnotationController extends Notifier<SelectedAnnotation?> {
  @override
  SelectedAnnotation? build() => null;

  void selectRoom(String id) =>
      state = SelectedAnnotation(AnnotationKind.room, id);
  void selectTank(String id) =>
      state = SelectedAnnotation(AnnotationKind.tank, id);

  /// Clear the selection, but only if [id] is currently selected (so deleting a
  /// non-selected item never disturbs the active selection). Pass no [id] to
  /// clear unconditionally.
  void clear([String? id]) {
    if (id == null || state?.id == id) state = null;
  }
}

/// An immutable snapshot of ALL THREE annotation lists at one instant —
/// measurements + tanks + rooms. One combined snapshot is the unit of the
/// annotation undo domain (B3): a single stack covering the three lists keeps
/// every annotation edit (a footprint add, a property change on a room/tank, a
/// delete) on ONE `UndoDomain.annotation` timeline entry, so it is reverted as
/// the genuinely most-recent edit across every domain.
@immutable
class AnnotationSnapshot {
  final List<Measurement> measurements;
  final List<TankArea> tanks;
  final List<RoomArea> rooms;
  const AnnotationSnapshot({
    required this.measurements,
    required this.tanks,
    required this.rooms,
  });
}

/// The shared undo coordinator for the three annotation lists. The measurement /
/// tank / room controllers each hold their own state, but a SINGLE snapshot
/// stack lives here: every forward mutation on any of them calls [record] (which
/// snapshots all three lists and records [UndoDomain.annotation] on the global
/// timeline), and the global `historyProvider` drives [undo]/[redo] here to
/// restore all three at once. Mirrors the electrical controller's local
/// snapshot-stack + record pattern — the difference is only that the state to
/// snapshot lives across three sibling providers, read/written via [ref].
///
/// The document-load path (`MeasurementController.set` / `TankAreaController.set`
/// / `RoomAreaController.set`) deliberately never records, so opening a project
/// leaves the timeline empty (no phantom undo); its stacks are dropped by
/// [HistoryController.reset] in the same breath the global timeline is reset.
final annotationHistoryProvider =
    NotifierProvider<AnnotationHistoryController, int>(
  AnnotationHistoryController.new,
);

class AnnotationHistoryController extends Notifier<int> {
  final List<AnnotationSnapshot> _undo = [];
  final List<AnnotationSnapshot> _redo = [];

  @override
  int build() => 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  AnnotationSnapshot _capture() => AnnotationSnapshot(
        measurements: ref.read(measurementsProvider),
        tanks: ref.read(tankAreasProvider),
        rooms: ref.read(roomAreasProvider),
      );

  void _restore(AnnotationSnapshot s) {
    // Restore through each controller's `set` (which replaces the list and
    // advances its fresh-id counter, never lowering it). `set` does not touch
    // this coordinator, so restoring never re-enters undo/redo.
    ref.read(measurementsProvider.notifier).set(s.measurements);
    ref.read(tankAreasProvider.notifier).set(s.tanks);
    ref.read(roomAreasProvider.notifier).set(s.rooms);
  }

  /// Snapshot the CURRENT (pre-mutation) state of all three lists onto the undo
  /// stack and record this domain on the global timeline (which clears the
  /// global redo branch). Every forward annotation mutation calls this BEFORE
  /// it changes state; the load path deliberately does not.
  void record() {
    _undo.add(_capture());
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.annotation);
    state++;
  }

  /// Revert the most recent annotation edit. Driven by the global
  /// [historyProvider] (which owns cross-domain ordering) — not called directly
  /// by widgets.
  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_capture());
    _restore(_undo.removeLast());
    state++;
  }

  /// Replay the most recently undone annotation edit (see [undo]).
  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_capture());
    _restore(_redo.removeLast());
    state++;
  }

  /// Drop both stacks — called from [HistoryController.reset] when a document is
  /// opened/restored (a fresh baseline). The shared stack lives here rather than
  /// in the three controllers, so it is cleared here rather than from `set`.
  void reset() {
    _undo.clear();
    _redo.clear();
    state++;
  }
}
