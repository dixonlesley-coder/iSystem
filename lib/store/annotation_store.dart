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

  void removeById(String id) =>
      state = [for (final m in state) if (m.id != id) m];

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

  TankArea copyWith({double? depthM, TankMaterial? material, String? name}) =>
      TankArea(
        id: id,
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        depthM: depthM ?? this.depthM,
        material: material ?? this.material,
        name: name ?? this.name,
      );

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
    state = [
      ...state,
      TankArea(
        id: 't${_seq++}',
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
      ),
    ];
  }

  void setDepth(String id, double depthM) => _update(
      id, (t) => t.copyWith(depthM: depthM.clamp(0.1, 20).toDouble()));
  void setMaterial(String id, TankMaterial m) =>
      _update(id, (t) => t.copyWith(material: m));
  void setName(String id, String name) => _update(id, (t) => t.copyWith(name: name));

  void _update(String id, TankArea Function(TankArea) f) =>
      state = [for (final t in state) if (t.id == id) f(t) else t];

  void removeById(String id) =>
      state = [for (final t in state) if (t.id != id) t];

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
  bool containsNode(String nodeSheetId, int nodeFloor, double nx, double ny) {
    if (nodeSheetId != sheetId || nodeFloor != floorIndex) return false;
    final loX = ax < bx ? ax : bx;
    final hiX = ax < bx ? bx : ax;
    final loY = ay < by ? ay : by;
    final hiY = ay < by ? by : ay;
    return nx >= loX && nx <= hiX && ny >= loY && ny <= hiY;
  }

  RoomArea copyWith({
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
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
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
    state = [
      ...state,
      RoomArea(
        id: 'r${_seq++}',
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
      ),
    ];
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

  void _update(String id, RoomArea Function(RoomArea) f) =>
      state = [for (final r in state) if (r.id == id) f(r) else r];

  void removeById(String id) =>
      state = [for (final r in state) if (r.id != id) r];

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
