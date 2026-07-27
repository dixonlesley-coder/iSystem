/// Geo-derived cable length for electrical circuits — the pure foundation that
/// lets a panel/load placed on the calibrated PDF layout drive a circuit's cable
/// length from REAL geometry (mirroring the mechanical `edgeLength` in
/// `network/network.dart`), instead of a typed-in run length.
///
/// §10 GEOMETRY-IS-TRUTH: the *horizontal* (planar) component of a cable run is
/// `pixel distance × per-sheet calibration`; the *vertical* component is a
/// true-elevation delta between floors, NEVER measured from the PDF. The two
/// sum to a defensible total cable length.
///
/// NOTE: the [LayoutPos] here is the *geo / PDF-substrate* placement space — a
/// sheet + floor + sheet-pixel (x, y). It is a DIFFERENT space from the abstract
/// single-line canvas position carried by `ElectricalPanel.x/y` (a schematic
/// layout coordinate from Wave 5). The two never alias.
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../units.dart';
import 'model.dart';

/// Where a panel or a circuit's load sits on the shared calibrated PDF substrate
/// (the electrical "Layout" projection). Pure, immutable value type — the
/// geo-space analogue of a mechanical [NetNode]'s `sheetId` / `floorIndex` /
/// `x` / `y`.
///
/// [x] / [y] are sheet PIXELS on [sheetId] (the planar position); [floorIndex]
/// indexes the project's [BuildingLevels] (the vertical position, via the
/// floor-elevation delta — §10). Two placements on the same sheet+floor differ
/// only in their planar (pixel) position; placements on different floors differ
/// vertically by the elevation delta of the floors.
class LayoutPos {
  /// Calibrated sheet this placement lives on.
  final String sheetId;

  /// Building level index (0 = lowest) — the vertical position basis.
  final int floorIndex;

  /// Planar position, sheet pixels.
  final double x;
  final double y;

  const LayoutPos({
    required this.sheetId,
    required this.floorIndex,
    required this.x,
    required this.y,
  });

  LayoutPos copyWith({
    String? sheetId,
    int? floorIndex,
    double? x,
    double? y,
  }) =>
      LayoutPos(
        sheetId: sheetId ?? this.sheetId,
        floorIndex: floorIndex ?? this.floorIndex,
        x: x ?? this.x,
        y: y ?? this.y,
      );

  /// Serialize to a plain JSON map (sheetId + floorIndex + pixel x/y as raw
  /// doubles). Always writes all four fields — a [LayoutPos] is only emitted by
  /// the model when non-null, so there is nothing to omit.
  Map<String, dynamic> toJson() => {
        'sheetId': sheetId,
        'floorIndex': floorIndex,
        'x': x,
        'y': y,
      };

  /// Tolerant decode: missing fields fall back to a defined zero/empty so a
  /// malformed/older entry never throws (absent ⇒ a degenerate but safe pos).
  static LayoutPos fromJson(Map<String, dynamic> json) => LayoutPos(
        sheetId: json['sheetId'] as String? ?? '',
        floorIndex: (json['floorIndex'] as num?)?.toInt() ?? 0,
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is LayoutPos &&
      other.sheetId == sheetId &&
      other.floorIndex == floorIndex &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(sheetId, floorIndex, x, y);

  @override
  String toString() =>
      'LayoutPos(sheet: $sheetId, floor: $floorIndex, x: $x, y: $y)';
}

/// Planar pixel distance between two placements (Euclidean).
double layoutPixelDistance(LayoutPos a, LayoutPos b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  return math.sqrt(dx * dx + dy * dy);
}

/// Real geometric cable length of a panel→load (or panel→sub-panel) run between
/// two layout placements, from the §10 sources of truth — faithfully mirroring
/// `edgeLength` in `network/network.dart`:
///
///  • HORIZONTAL (planar) component = `pixelDistance(from,to) × calibration`,
///    using the calibration of the **[from] sheet**. A cable's planar route is
///    drawn on one sheet; when the two ends are on different sheets we use the
///    origin (panel) sheet's scale for the planar leg — a defensible single
///    choice (the alternative — splitting the planar leg across two scales — has
///    no well-defined breakpoint). The vertical leg below carries the
///    between-floor distance regardless.
///  • VERTICAL component (only when `from.floorIndex != to.floorIndex`) = the
///    true floor-to-floor **elevation delta** from [building], NEVER pixels.
///    Basis: floor-SURFACE elevations (`BuildingLevels.elevationOf`), i.e. the
///    same datum `riserLength` uses — a cable riser/drop between slabs is the
///    natural choice for a panel-to-load vertical leg, and is role-agnostic
///    (a panel and its load are not the ceiling-main / fixture / plant roles the
///    mechanical `nodeElevation` distinguishes). [mounting] is accepted for
///    signature parity / future role-aware refinement but is not consumed yet.
///  • TOTAL = planar + vertical (a simple additive routing model — a cable runs
///    horizontally on a floor then drops/rises between floors).
///    // VERIFY: the exact site routing (e.g. tray detours, slack, terminations)
///    is not modelled — this is the as-the-route-runs minimum, the same
///    idealisation the mechanical `edgeLength` makes.
///
/// Returns [Length] 0 for an uncalibrated [from] sheet (mirroring `edgeLength`,
/// which returns zero length for an uncalibrated run — the unplaced/uncalibrated
/// case is surfaced by the caller, not silently sized).
Length electricalCableLength(
  LayoutPos from,
  LayoutPos to, {
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
  MountingHeights mounting = const MountingHeights(),
}) {
  // Planar leg uses the origin (panel) sheet's calibration.
  final cal = calibrationBySheet[from.sheetId];
  if (cal == null) return const Length(0);
  final planar = cal.lengthForPixels(layoutPixelDistance(from, to)).meters;

  // Vertical leg: a true floor-elevation delta (§10), never pixels.
  var vertical = 0.0;
  if (from.floorIndex != to.floorIndex) {
    final levels = building.levelCount;
    if (from.floorIndex >= 0 &&
        from.floorIndex < levels &&
        to.floorIndex >= 0 &&
        to.floorIndex < levels) {
      vertical = building
          .riserLength(from.floorIndex, to.floorIndex)
          .meters;
    }
  }

  return Length(planar + vertical);
}

/// The effective cable run length for [circuit] on [panel]: the GEO length when
/// both ends are placed on the calibrated layout, else the circuit's manual
/// [ElectricalCircuit.length] (the unplaced fallback / override).
///
/// Geometry is truth: a length is geo-derived when
///  • the [panel] has a [ElectricalPanel.layoutPos] (the run origin), AND
///  • the load end is placed — for a normal way that is [ElectricalCircuit.loadPos];
///    for a FEEDER (it feeds `feedsPanelId`) it is the target sub-panel's
///    [ElectricalPanel.layoutPos], looked up via [panelById]. The cable then runs
///    panel→sub-panel.
/// If either end is unplaced (or the from-sheet is uncalibrated, where
/// [electricalCableLength] returns 0), this falls back to the manual length, so
/// an unplaced circuit sizes exactly as today.
///
/// Pure; reads only inputs + the supplied calibration/[building].
Length resolveCircuitLength(
  ElectricalCircuit circuit,
  ElectricalPanel panel, {
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
  MountingHeights mounting = const MountingHeights(),
  Map<String, ElectricalPanel> panelById = const {},
}) =>
    resolveCircuitLengthDetailed(
      circuit,
      panel,
      calibrationBySheet: calibrationBySheet,
      building: building,
      mounting: mounting,
      panelById: panelById,
    ).length;

/// Which basis produced a circuit's effective cable length.
enum CircuitLengthSource {
  /// The engineer's typed-in [ElectricalCircuit.length] — used whenever either
  /// end is unplaced, the origin sheet is uncalibrated, or the derived geo
  /// length comes back zero (see [resolveCircuitLengthDetailed]).
  manual,

  /// A real length derived from the calibrated layout + §10 elevations via
  /// [electricalCableLength].
  geo,
}

/// [resolveCircuitLength], but also reporting WHICH basis won — a length-source
/// honesty helper so a caller (e.g. a report or an inspector) can tell a
/// geometry-derived run apart from a manual/fallback one instead of just
/// seeing a number.
///
/// Same resolution logic as [resolveCircuitLength] — implemented ONCE here;
/// [resolveCircuitLength] is a thin wrapper that returns just the `.length`.
/// `source` is [CircuitLengthSource.geo] only when a real geo length was
/// actually derived (both ends placed, origin sheet calibrated, and the
/// derived length is > 0); every fallback path reports
/// [CircuitLengthSource.manual].
///
/// Pure; reads only inputs + the supplied calibration/[building].
({Length length, CircuitLengthSource source}) resolveCircuitLengthDetailed(
  ElectricalCircuit circuit,
  ElectricalPanel panel, {
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
  MountingHeights mounting = const MountingHeights(),
  Map<String, ElectricalPanel> panelById = const {},
}) {
  final from = panel.layoutPos;
  if (from == null) {
    return (length: circuit.length, source: CircuitLengthSource.manual);
  }

  // Resolve the load end: the fed sub-panel for a feeder, else the load pos.
  final LayoutPos? to;
  if (circuit.feedsPanelId != null) {
    to = panelById[circuit.feedsPanelId]?.layoutPos;
  } else {
    to = circuit.loadPos;
  }
  if (to == null) {
    return (length: circuit.length, source: CircuitLengthSource.manual);
  }

  final geo = electricalCableLength(
    from,
    to,
    calibrationBySheet: calibrationBySheet,
    building: building,
    mounting: mounting,
  );
  // An uncalibrated from-sheet yields 0; keep the manual length in that case so
  // an unplaceable run is never silently zeroed.
  if (geo.meters <= 0) {
    return (length: circuit.length, source: CircuitLengthSource.manual);
  }
  return (length: geo, source: CircuitLengthSource.geo);
}
