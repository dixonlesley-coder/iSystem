/// Measurement annotations — a dimension line drawn on the calibrated sheet
/// whose real-world length comes from the per-sheet scale (§10 geometry is the
/// single source of truth). Annotations are NOT part of the drawn network: they
/// never affect sizing/solve; they round-trip in the `.mechx` project as plain
/// data.
library;

import 'dart:convert' show jsonEncode;
import 'dart:math' as math;

import 'package:flutter/widgets.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart'
    show Network, NetNode, NodeComponent, ServiceType;
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/cooling_load_detailed.dart'
    show DetailedCoolingLoadInputs, estimateDetailedCoolingLoad;
import 'package:mechx_engine/sizing/network_sizing.dart'
    show DuctShape, DuctSizingMethod;
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';

import 'app_state.dart' show CoolingLoadMethod, coolingLoadMethodProvider;
import 'history_store.dart';
import 'project_store.dart';

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

  /// This measurement moved to building floor [fi] (a floor-stack / sheet
  /// re-mapping carries annotations with the drawn work — `floor_remap.dart`).
  Measurement withFloorIndex(int fi) => Measurement(
        id: id,
        sheetId: sheetId,
        floorIndex: fi,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
      );

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

  /// This tank moved to building floor [fi] (see [Measurement.withFloorIndex]).
  TankArea withFloorIndex(int fi) => TankArea(
        id: id,
        sheetId: sheetId,
        floorIndex: fi,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        depthM: depthM,
        material: material,
        name: name,
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
  /// F6 — returns the NEW tank's id (null when the box was rejected) so the
  /// drawing gesture can select it straight away, exactly as a drawn node is.
  String? add({
    required String sheetId,
    required int floorIndex,
    required double ax,
    required double ay,
    required double bx,
    required double by,
  }) {
    if ((ax - bx).abs() < 2 || (ay - by).abs() < 2) return null;
    ref.read(annotationHistoryProvider.notifier).record();
    // E7: seed a distinct sequential name ('Tank 1', 'Tank 2', …) so a schedule
    // never lists a wall of identical 'Tank' rows; still renamable in-place.
    final id = 't$_seq';
    state = [
      ...state,
      TankArea(
        id: id,
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
    return id;
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
    final cur = state.where((t) => t.id == id).firstOrNull;
    if (cur == null) return;
    // Round 13 (ui-journey-2) — a pick that changes nothing (re-tapping the
    // selected material, '-' at the depth floor) records NO undo step; it used
    // to spend one, so the engineer's real last edit needed a second Ctrl+Z.
    final next = f(cur);
    if (_sameAnnotation(cur.toJson(), next.toJson())) return;
    ref.read(annotationHistoryProvider.notifier).record();
    state = [for (final t in state) if (t.id == id) next else t];
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

  /// Floor area (m²) given the sheet's metres-per-pixel — the GROSS
  /// footprint, nested rooms included (see [netAreaM2]).
  double areaM2(double metersPerPixel) =>
      widthPx * heightPx * metersPerPixel * metersPerPixel;

  /// Round 27 (hvac-4-2) — whether [other] is SMALLER than this room for the
  /// nested-room rule: a strictly smaller gross footprint. Two equal
  /// footprints are never nested in each other (a duplicated room keeps its
  /// own sizing — the same rule as the smallest-room ownership tie).
  bool _isSmallerRoom(RoomArea other) =>
      other.widthPx * other.heightPx < widthPx * heightPx;

  /// Round 27 (hvac-4-2) — the NET floor area (m²): the footprint less the
  /// part covered by SMALLER rooms on the same sheet + floor (a meeting room
  /// drawn inside an office; a partial overlap is clipped to the overlap).
  /// The covered part is the UNION of those overlaps, so a room nested two
  /// deep is subtracted once. A nested room owns its own terminals and AC
  /// units, so it must own its own volume too: counting it in the outer room
  /// as well sized the inner room's air and cooling twice (office airflow
  /// +9.7 %, its cassette 120000 instead of 108000 BTU/h). No overlapping
  /// smaller room ⇒ exactly [areaM2].
  double netAreaM2(double metersPerPixel, Iterable<RoomArea> rooms) {
    final gross = areaM2(metersPerPixel);
    final loX = math.min(ax, bx), hiX = math.max(ax, bx);
    final loY = math.min(ay, by), hiY = math.max(ay, by);
    final clips = <(double, double, double, double)>[];
    for (final r in rooms) {
      if (r.id == id ||
          r.sheetId != sheetId ||
          r.floorIndex != floorIndex ||
          !_isSmallerRoom(r)) {
        continue;
      }
      final x0 = math.max(loX, math.min(r.ax, r.bx));
      final x1 = math.min(hiX, math.max(r.ax, r.bx));
      final y0 = math.max(loY, math.min(r.ay, r.by));
      final y1 = math.min(hiY, math.max(r.ay, r.by));
      if (x1 > x0 && y1 > y0) clips.add((x0, y0, x1, y1));
    }
    if (clips.isEmpty) return gross;
    // Union of the overlap rectangles on the compressed grid of their edges.
    final xs = {for (final c in clips) ...[c.$1, c.$3]}.toList()..sort();
    final ys = {for (final c in clips) ...[c.$2, c.$4]}.toList()..sort();
    var coveredPx = 0.0;
    for (var i = 0; i + 1 < xs.length; i++) {
      for (var j = 0; j + 1 < ys.length; j++) {
        final cx = (xs[i] + xs[i + 1]) / 2, cy = (ys[j] + ys[j + 1]) / 2;
        if (clips.any((c) => cx > c.$1 && cx < c.$3 && cy > c.$2 && cy < c.$4)) {
          coveredPx += (xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j]);
        }
      }
    }
    return math.max(
        0.0, gross - coveredPx * metersPerPixel * metersPerPixel);
  }

  /// Air-change rate actually applied: the [achOverride] if set, else the
  /// [roomType] default from the ventilation profile.
  double effectiveAch() =>
      achOverride ?? const SniVentilationProfile().recommendedAch(roomType).value;

  /// Full air-side sizing for the room, or null when the sheet has no scale or
  /// the footprint is degenerate. Honours the project [ductShape]/[ductMethod].
  ///
  /// Round 27 (hvac-4-2) — pass the project's [rooms] so a smaller room drawn
  /// inside this one is sized by itself, not twice ([netAreaM2]).
  RoomAirResult? sizing(
    double? metersPerPixel, {
    DuctShape ductShape = DuctShape.round,
    DuctSizingMethod ductMethod = DuctSizingMethod.velocity,
    Iterable<RoomArea> rooms = const [],
  }) {
    if (metersPerPixel == null) return null;
    final area = netAreaM2(metersPerPixel, rooms);
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
      // Round 11 (hvac-network-2) — a toilet / kitchen is EXTRACTED: exhaust
      // grilles + an exhaust fan, never supply nor recirculated return air.
      extractOnly: isExtractRoomType(roomType),
    );
  }

  /// Estimated AC cooling load (BTU/h · kW · PK + a recommended unit) for the
  /// room, or null when the sheet has no scale / the footprint is degenerate.
  ///
  /// [method] selects the BASIS (M15):
  ///  • [CoolingLoadMethod.simple] (default) — the area-density rule: floor area
  ///    × the ventilation profile's per-room-type density × the ceiling
  ///    correction. Every existing caller keeps this, byte-identical.
  ///  • [CoolingLoadMethod.detailed] — the heat-gain component breakdown
  ///    (`estimateDetailedCoolingLoad`): people + lighting + equipment +
  ///    ventilation/infiltration sensible & latent, over the room's real floor
  ///    area and ceiling. Its result is projected onto the SAME [CoolingLoad]
  ///    shape (total BTU/h · W · PK + the standard-AC pick) so nothing
  ///    downstream has to branch. ENVELOPE inputs (wall / roof / glass areas,
  ///    orientation) are not modelled by a rectangular room annotation, so they
  ///    are left at zero rather than invented — the detailed basis here is an
  ///    INTERNAL-GAIN + ventilation estimate, and every coefficient it does use
  ///    is a representative `// VERIFY` default
  ///    (`detailedCoolingVerifyChecklist`).
  CoolingLoad? coolingLoad(
    double? metersPerPixel, {
    CoolingLoadMethod method = CoolingLoadMethod.simple,
    Iterable<RoomArea> rooms = const [],
  }) {
    if (metersPerPixel == null) return null;
    // Round 27 (hvac-4-2) — the NET area: a nested room cools its own floor.
    final area = netAreaM2(metersPerPixel, rooms);
    if (area <= 0 || ceilingHeightM <= 0) return null;
    if (method == CoolingLoadMethod.detailed) {
      final d = estimateDetailedCoolingLoad(DetailedCoolingLoadInputs(
        floorArea: Area(area),
        ceilingHeight: Length(ceilingHeightM),
      ));
      return CoolingLoad(
        btuPerHr: d.totalBtuPerHr,
        watts: d.totalW,
        pk: d.totalPk,
        recommended: d.recommended,
      );
    }
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

  /// This room moved to building floor [fi] (see [Measurement.withFloorIndex]).
  RoomArea withFloorIndex(int fi) => RoomArea(
        id: id,
        sheetId: sheetId,
        floorIndex: fi,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        roomType: roomType,
        ceilingHeightM: ceilingHeightM,
        achOverride: achOverride,
        equipmentKind: equipmentKind,
        name: name,
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
      // Round 19 (persistence-2-3) — the bands the setters enforce
      // ([RoomAreaController.setCeiling] 1.5–12 m, [setAch] 0.5–60): a
      // non-positive / non-finite stored value falls back (ceiling 3.0 m, no
      // ACH override), an out-of-band one clamps — never a 0 / negative ACH
      // asserted on inside the room-air sizing.
      ceilingHeightM:
          _roomNum(raw['ceiling_m'], positive: true)?.clamp(1.5, 12).toDouble() ??
              3.0,
      achOverride:
          _roomNum(raw['ach'], positive: true)?.clamp(0.5, 60).toDouble(),
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
/// Round 19 (regression-room-stale-nested-rooms-false-warning) — the ONE room
/// an air terminal ([component] at sheet-pixel [x],[y] on [sheetId]/[floor])
/// belongs to among [rooms]: the smallest room containing it whose kind the
/// terminal serves (a supply diffuser / return grille → a conditioned room, an
/// exhaust grille → an extract-only room, `isExtractRoomType`), else the
/// smallest room containing it at all; ties break on room id. Null when no room
/// contains it. Shared by the Review stale check AND Auto-place's idempotence
/// filter, so a toilet nested inside an office neither counts its exhaust
/// grille as the office's extract nor has it deleted by re-placing the office.
String? roomTerminalOwnerId(NodeComponent? component, String sheetId,
    int floor, double x, double y, Iterable<RoomArea> rooms) {
  RoomArea? best;
  RoomArea? bestCompatible;
  double areaOf(RoomArea r) => r.widthPx * r.heightPx;
  bool smaller(RoomArea a, RoomArea? b) {
    if (b == null) return true;
    final d = areaOf(a) - areaOf(b);
    if (d.abs() > 1e-9) return d < 0;
    return a.id.compareTo(b.id) < 0;
  }

  for (final r in rooms) {
    if (!r.containsNode(sheetId, floor, x, y)) continue;
    if (smaller(r, best)) best = r;
    final extractRoom = isExtractRoomType(r.roomType);
    final compatible = component == NodeComponent.exhaustGrille
        ? extractRoom
        : !extractRoom;
    if (compatible && smaller(r, bestCompatible)) bestCompatible = r;
  }
  return (bestCompatible ?? best)?.id;
}

/// Round 20 (regression-autoplace-nested-same-kind-room-stacks-terminals) —
/// the owning room of an air-terminal NODE: the room whose Auto-place
/// generated it ([NetNode.autoPlacedRoomId]) while the terminal still sits
/// inside that room's footprint, else the geometric owner
/// ([roomTerminalOwnerId], for hand-placed terminals or one dragged out of its
/// room). With a meeting room nested in an open office, the office's grid can
/// land a diffuser inside the meeting room; geometry alone gave it to the
/// meeting room, so re-running the office's Auto-place neither deleted nor
/// avoided it and stacked a second generation on top (+50 % air), and the
/// stale judge under-counted the office / over-counted the meeting room.
/// Round 21: the tag wins only OUTSIDE every nested same-kind room of the
/// tagged room ([insideNestedSameKindRoom]); inside one the geometric owner
/// (the nested room) takes it.
/// Round 27 (hvac-4-3) — whether a DRAWN air system actually serves [room]:
/// a terminal of the room's kind that the room OWNS ([roomTerminalOwnerOf] —
/// an exhaust grille for an [extract] room, a supply diffuser / return grille
/// otherwise) is connected to a SIZED duct of the matching service
/// ([sizedEdgeIds]). The equipment schedule drops a room's own EF / AHU row
/// only then: any exhaust (or supply) duct ANYWHERE in the project used to
/// drop every room's row, so a ductless kitchen's 800 L/s exhaust fan
/// vanished from the issued schedule once the toilets were piped.
bool roomServedByDrawnAir(
  RoomArea room,
  Iterable<RoomArea> rooms,
  Network net,
  Set<String> sizedEdgeIds, {
  required bool extract,
}) {
  final terminals = extract
      ? const {NodeComponent.exhaustGrille}
      : const {NodeComponent.supplyDiffuser, NodeComponent.returnGrille};
  final services = extract
      ? const {ServiceType.exhaust}
      : const {ServiceType.duct, ServiceType.returnAir};
  for (final n in net.nodes) {
    if (!terminals.contains(n.component)) continue;
    if (roomTerminalOwnerOf(n, rooms) != room.id) continue;
    for (final e in net.edges) {
      if ((e.fromId == n.id || e.toId == n.id) &&
          services.contains(e.service) &&
          sizedEdgeIds.contains(e.id)) {
        return true;
      }
    }
  }
  return false;
}

String? roomTerminalOwnerOf(NetNode node, Iterable<RoomArea> rooms) {
  final tag = node.autoPlacedRoomId;
  if (tag != null) {
    for (final r in rooms) {
      if (r.id == tag &&
          r.containsNode(node.sheetId, node.floorIndex, node.x, node.y) &&
          // Round 21 — the tag never hides a terminal that now sits inside a
          // smaller same-kind room drawn AFTER the generating room's
          // Auto-place: that point is the nested room's, so its own Auto-place
          // replaces the terminal and the outer room goes stale (re-run it to
          // move the terminal out) instead of silently doubling the air.
          !insideNestedSameKindRoom(r, node.x, node.y, rooms)) {
        return r.id;
      }
    }
  }
  return roomTerminalOwnerId(
      node.component, node.sheetId, node.floorIndex, node.x, node.y, rooms);
}

/// Round 20 (hvac-3-1) — the ONE room a placed AC indoor unit ([node])
/// belongs to among [rooms]: the SMALLEST room containing it, ties broken on
/// room id; null when none contains it. The AC feed ([acUnitShare]), the
/// equipment schedule and the Rooms inspector all count a room's units by this
/// owner, so a cassette in a meeting room nested inside an office is the
/// meeting room's unit only — never counted again in the office's split, and
/// never fed the office's load because the office was drawn first.
String? roomUnitOwnerId(NetNode node, Iterable<RoomArea> rooms) {
  RoomArea? best;
  for (final r in rooms) {
    if (!r.containsNode(node.sheetId, node.floorIndex, node.x, node.y)) {
      continue;
    }
    if (best == null) {
      best = r;
      continue;
    }
    final d = r.widthPx * r.heightPx - best.widthPx * best.heightPx;
    if (d < -1e-9 || (d.abs() <= 1e-9 && r.id.compareTo(best.id) < 0)) {
      best = r;
    }
  }
  return best?.id;
}

/// Round 20 — true when ([x], [y]) on [room]'s sheet/floor falls inside a
/// DIFFERENT, smaller room of the same air kind (both conditioned, or both
/// extract-only): a nested room that sizes and places its own terminals, so
/// [room]'s Auto-place grid must not drop a terminal there.
bool insideNestedSameKindRoom(
    RoomArea room, double x, double y, Iterable<RoomArea> rooms) {
  final kind = isExtractRoomType(room.roomType);
  final area = room.widthPx * room.heightPx;
  for (final r in rooms) {
    if (r.id == room.id) continue;
    if (isExtractRoomType(r.roomType) != kind) continue;
    if (r.widthPx * r.heightPx >= area) continue;
    if (r.containsNode(room.sheetId, room.floorIndex, x, y)) return true;
  }
  return false;
}

/// Round 19 — a stored room number: finite (and > 0 when [positive]), else
/// null.
double? _roomNum(Object? raw, {bool positive = false}) {
  final v = raw is num ? raw.toDouble() : null;
  if (v == null || !v.isFinite) return null;
  if (positive && v <= 0) return null;
  return v;
}

final roomAreasProvider =
    NotifierProvider<RoomAreaController, List<RoomArea>>(RoomAreaController.new);

class RoomAreaController extends Notifier<List<RoomArea>> {
  int _seq = 0;

  @override
  List<RoomArea> build() => const [];

  /// Add a room from two opposite corners. Ignores a degenerate (zero-area) box.
  /// F6 — returns the NEW room's id (null when the box was rejected) so the
  /// drawing gesture can select it straight away, exactly as a drawn node is.
  String? add({
    required String sheetId,
    required int floorIndex,
    required double ax,
    required double ay,
    required double bx,
    required double by,
  }) {
    if ((ax - bx).abs() < 2 || (ay - by).abs() < 2) return null;
    ref.read(annotationHistoryProvider.notifier).record();
    // E7: seed a distinct sequential name ('Room 1', 'Room 2', …) so an issued
    // equipment schedule never lists a wall of identical 'Room' AHU rows; still
    // renamable in-place in the Rooms inspector.
    final id = 'r$_seq';
    state = [
      ...state,
      RoomArea(
        id: id,
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        name: 'Room ${_seq + 1}',
        // F7: seed the CEILING from the building the engineer just configured —
        // the floor's own floor-to-floor height less the project's ceiling drop
        // — instead of a hard-coded 3.0 m. It multiplies straight into the ACH
        // volume, the airflow, the ducts and the cooling load, so a 4.2 m
        // warehouse level must not start life as a 3.0 m office. Still fully
        // editable in the Rooms inspector, and LOADED rooms are untouched (the
        // constructor default stays 3.0).
        ceilingHeightM: _seedCeilingM(floorIndex),
      ),
    ];
    _seq++;
    return id;
  }

  /// F7 — the ceiling height a new room on [floorIndex] starts at: that floor's
  /// floor-to-floor height minus the project's [MountingHeights.ceilingDrop]
  /// (the same drop the §10 node elevations use for a ceiling-level main), so
  /// the room's volume matches the building model. Clamped into the same band
  /// [setCeiling] allows, with a 2.2 m floor so a shallow/odd level can never
  /// seed an unusably low ceiling.
  double _seedCeilingM(int floorIndex) {
    final project = ref.read(projectControllerProvider);
    final drop = project.mounting.ceilingDrop.meters;
    final floorToFloor = project.building.floorHeightOf(floorIndex).meters;
    return (floorToFloor - drop).clamp(2.2, 12.0).toDouble();
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
    final cur = state.where((r) => r.id == id).firstOrNull;
    if (cur == null) return;
    // Round 13 — a no-op edit (same room type, a clamp boundary) records no
    // undo step (see [TankAreaController._update]).
    final next = f(cur);
    if (_sameAnnotation(cur.toJson(), next.toJson())) return;
    ref.read(annotationHistoryProvider.notifier).record();
    state = [for (final r in state) if (r.id == id) next else r];
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

  /// Round 28 (persist-undo-2-4) — load a DOCUMENT's rooms: the counter
  /// restarts from the document, past every live room id, the saved counter
  /// ([nextSeq], `.mechx` `roomNextSeq`) and every room id still REFERENCED
  /// by the drawing ([referencedIds]: the terminals' `autoPlacedRoomId`), so
  /// a room drawn after a reload never re-uses a deleted room's id — and
  /// never adopts (then deletes on Auto-place) the terminals tagged with it.
  void load(List<RoomArea> rooms,
      {int? nextSeq, Iterable<String?> referencedIds = const []}) {
    _seq = 0;
    set(rooms);
    if (nextSeq != null && nextSeq > _seq) _seq = nextSeq;
    for (final id in referencedIds) {
      if (id == null || !id.startsWith('r')) continue;
      final n = int.tryParse(id.substring(1));
      if (n != null && n >= _seq) _seq = n + 1;
    }
  }

  /// Round 28 — the counter to persist (`roomNextSeq`), or null when the live
  /// room ids already imply it (an untouched file stays byte-identical).
  int? get persistedNextSeq {
    var implied = 0;
    for (final r in state) {
      final n = int.tryParse(r.id.replaceFirst('r', ''));
      if (n != null && n >= implied) implied = n + 1;
    }
    return _seq > implied ? _seq : null;
  }
}

/// M15 — the AC cooling load for one room (by [RoomArea.id]) computed on the
/// project's CHOSEN basis ([coolingLoadMethodProvider], set on the Building
/// page): area-density or heat-gain. The ONE place the method is applied, so a
/// consumer never has to know which basis is live; null when the room is
/// unknown, its sheet has no scale, or the footprint is degenerate.
///
/// This is the wire that makes `DesignSettings.coolingLoadMethod` a real
/// setting instead of a persisted field nothing read (R6).
final roomCoolingLoadProvider =
    Provider.family<CoolingLoad?, String>((ref, roomId) {
  final room =
      ref.watch(roomAreasProvider).where((r) => r.id == roomId).firstOrNull;
  if (room == null) return null;
  final mpp =
      ref.watch(projectControllerProvider).calibrationFor(room.sheetId)
          ?.metersPerPixel;
  return room.coolingLoad(mpp,
      method: ref.watch(coolingLoadMethodProvider),
      rooms: ref.watch(roomAreasProvider));
});

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

/// Two annotation records are the same edit-wise when their persisted form is
/// identical (every field the `.mechx` file stores) — the no-op test for the
/// tank/room `_update` (Round 13).
bool _sameAnnotation(Map<String, dynamic> a, Map<String, dynamic> b) =>
    jsonEncode(a) == jsonEncode(b);
