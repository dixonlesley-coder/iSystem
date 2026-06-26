/// Room air-side sizing engine — the AHU / FCU / fan + duct + diffuser sizer
/// driven by **air changes per hour** (ACH).
///
/// This is the orchestration layer of the §7 "air" code path: from a room's
/// floor area (taken from the calibrated drawing) and a target ACH it derives
/// the design airflow (CFM / L/s), then composes the existing primitives to
/// auto-size everything that serves the room:
///
///   1. **Airflow** — `Q = volume × ACH / 3600` (m³/s); volume = area × height.
///   2. **Supply diffusers** — auto-count so each face stays within a quiet
///      standard size, then [selectStandardGrille] each one.
///   3. **Return grille(s)** — same auto-count over the full room airflow.
///   4. **Supply trunk duct** — round (velocity / equal-friction) or
///      rectangular, sized for the total airflow via `duct_sizing.dart`.
///   5. **Equipment** — AHU / FCU / fan duty via [sizeFan] against a static
///      pressure built up from the duct friction, terminal drops, and a
///      kind-dependent internal (filter + coil + casing) allowance.
///
/// The static build-up here is a first-pass estimate for *equipment selection*
/// from a single room; the full duct-network solve (`network/duct_static.dart`)
/// remains the authority once runs are drawn. The internal-static and
/// assumed-run defaults below are general engineering values — treat them as
/// `// VERIFY` design assumptions, not standard requirements.
///
/// Pure Dart, zero Flutter imports. Composes only typed quantities.
library;

import 'dart:math' as math;

import '../units.dart';
import 'duct_sizing.dart' as duct;
import 'fan.dart';
import 'grille_sizing.dart';
import 'network_sizing.dart' show DuctShape, DuctSizingMethod;

/// The unit serving the room — affects the assumed internal static pressure.
enum AirEquipmentKind {
  /// Air-handling unit: filter + cooling coil + casing → highest internal drop.
  ahu,

  /// Fan-coil unit: small coil, short ducting → modest internal drop.
  fcu,

  /// Plain supply / exhaust fan: no coil, essentially no internal drop.
  fan,
}

/// Human-readable label for [kind].
String airEquipmentLabel(AirEquipmentKind kind) {
  switch (kind) {
    case AirEquipmentKind.ahu:
      return 'AHU';
    case AirEquipmentKind.fcu:
      return 'FCU';
    case AirEquipmentKind.fan:
      return 'Fan';
  }
}

/// Default internal static pressure (filter + coil + casing) for [kind].
/// General engineering allowances — `// VERIFY` against the selected product.
Pressure defaultInternalStatic(AirEquipmentKind kind) {
  switch (kind) {
    case AirEquipmentKind.ahu:
      return const Pressure(250.0); // filter + cooling coil + casing
    case AirEquipmentKind.fcu:
      return const Pressure(50.0); // small coil only
    case AirEquipmentKind.fan:
      return const Pressure(0.0); // air mover only
  }
}

/// Room volume (m³) = floor area × ceiling height.
double roomVolumeM3(Area floorArea, Length ceilingHeight) =>
    floorArea.squareMeters * ceilingHeight.meters;

/// Design airflow for a room from its volume and target air-change rate.
///
/// `Q = volume × ACH / 3600`  (m³/s), where `volume = floorArea × ceilingHeight`.
/// Use [FlowRate.inCubicFeetPerMinute] / `.inLitersPerSecond` at the boundary.
FlowRate airChangeFlow({
  required Area floorArea,
  required Length ceilingHeight,
  required double airChangesPerHour,
}) {
  assert(floorArea.squareMeters > 0, 'floorArea must be positive');
  assert(ceilingHeight.meters > 0, 'ceilingHeight must be positive');
  assert(airChangesPerHour > 0, 'airChangesPerHour must be positive');
  final volume = roomVolumeM3(floorArea, ceilingHeight);
  return FlowRate(volume * airChangesPerHour / 3600.0);
}

/// One auto-counted bank of identical air terminals (supply or return).
final class TerminalBank {
  /// Number of identical terminals across which [totalAirflow] is split.
  final int count;

  /// Airflow carried by each terminal (= totalAirflow / count).
  final FlowRate airflowEach;

  /// Selected standard face for one terminal (see [selectStandardGrille]).
  final GrilleSizingResult each;

  const TerminalBank({
    required this.count,
    required this.airflowEach,
    required this.each,
  });
}

/// Largest standard grille gross face area (m²) — caps one terminal's quiet
/// airflow so the auto-count never has to fall back to an over-velocity face.
final double _largestStandardGrossM2 = standardGrilleFacesMm
    .map((f) => (f.$1 / 1000.0) * (f.$2 / 1000.0))
    .reduce(math.max);

/// Auto-split [airflow] across the fewest identical standard terminals that each
/// stay at or below [faceVelocity], then size one terminal.
TerminalBank _autoTerminals(
  FlowRate airflow,
  Velocity faceVelocity,
  double freeAreaRatio,
) {
  final maxPerTerminal =
      _largestStandardGrossM2 * freeAreaRatio * faceVelocity.metersPerSecond;
  final count =
      math.max(1, (airflow.cubicMetersPerSecond / maxPerTerminal).ceil());
  final each = FlowRate(airflow.cubicMetersPerSecond / count);
  return TerminalBank(
    count: count,
    airflowEach: each,
    each: selectStandardGrille(
      airflow: each,
      maxFaceVelocity: faceVelocity,
      freeAreaRatio: freeAreaRatio,
    ),
  );
}

/// Full air-side sizing outcome for one room.
final class RoomAirResult {
  /// Room volume used for the ACH calc (m³).
  final double roomVolumeM3;

  /// Air-change rate applied (changes per hour).
  final double airChangesPerHour;

  /// Total design airflow (supply = return) for the room.
  final FlowRate airflow;

  /// Equipment type assumed for the static build-up.
  final AirEquipmentKind equipmentKind;

  /// Auto-counted supply diffuser bank.
  final TerminalBank supply;

  /// Auto-counted return grille bank.
  final TerminalBank return_;

  /// Sized supply trunk — set when [DuctShape.round] was requested.
  final duct.DuctSizingResult? supplyDuctRound;

  /// Sized supply trunk — set when [DuctShape.rectangular] was requested.
  final duct.RectangularDuctResult? supplyDuctRect;

  /// Selected equipment duty (air/shaft/motor power + motor selection).
  final FanDuty equipment;

  const RoomAirResult({
    required this.roomVolumeM3,
    required this.airChangesPerHour,
    required this.airflow,
    required this.equipmentKind,
    required this.supply,
    required this.return_,
    required this.supplyDuctRound,
    required this.supplyDuctRect,
    required this.equipment,
  });

  /// Total design airflow in CFM — the customary HVAC headline figure.
  double get airflowCfm => airflow.inCubicFeetPerMinute;

  /// Equivalent circular diameter of the supply trunk (round value, or the
  /// rectangular circular-equivalent), for labelling/comparison.
  Diameter get supplyDuctDiameter =>
      supplyDuctRound?.diameter ?? supplyDuctRect!.equivalentDiameter;

  /// Mean velocity in the supply trunk.
  Velocity get supplyDuctVelocity =>
      supplyDuctRound?.actualVelocity ?? supplyDuctRect!.actualVelocity;
}

/// Size the complete air system for a room from its geometry and target ACH.
///
/// Defaults pick the quieter / smaller of each choice; tune via the named
/// parameters. The duct static is a first-pass estimate for equipment
/// selection (see the library doc); the network solve is the authority once
/// runs are drawn.
RoomAirResult sizeRoomAir({
  required Area floorArea,
  required Length ceilingHeight,
  required double airChangesPerHour,
  AirEquipmentKind equipmentKind = AirEquipmentKind.fcu,
  GrilleApplication grilleApplication = GrilleApplication.office,
  double freeAreaRatio = 0.8,
  DuctShape ductShape = DuctShape.round,
  DuctSizingMethod ductMethod = DuctSizingMethod.velocity,
  Velocity maxDuctVelocity = const Velocity(5.0),
  double ductEqualFrictionPa = 1.0,
  double ductAspectRatio = 1.5,
  Length assumedDuctRun = const Length(15.0),
  double fittingFactor = 1.3,
  Pressure supplyTerminalLoss = const Pressure(30.0),
  Pressure returnTerminalLoss = const Pressure(20.0),
  Pressure? equipmentInternalStatic,
  double fanEfficiency = 0.65,
  double motorEfficiency = 0.90,
}) {
  final volume = roomVolumeM3(floorArea, ceilingHeight);
  final airflow = airChangeFlow(
    floorArea: floorArea,
    ceilingHeight: ceilingHeight,
    airChangesPerHour: airChangesPerHour,
  );

  // 2 + 3 — air terminals (supply diffusers, return grilles).
  final faceVelocity = recommendedFaceVelocity(grilleApplication);
  final supply = _autoTerminals(airflow, faceVelocity, freeAreaRatio);
  final return_ = _autoTerminals(airflow, faceVelocity, freeAreaRatio);

  // 4 — supply trunk duct (carries the whole room airflow).
  duct.DuctSizingResult? round;
  duct.RectangularDuctResult? rect;
  double frictionPerMetre;
  if (ductShape == DuctShape.rectangular) {
    rect = duct.sizeRectangularByVelocity(
      airflow: airflow,
      maxVelocity: maxDuctVelocity,
      aspectRatio: ductAspectRatio,
    );
    frictionPerMetre = rect.frictionPerMetrePa;
  } else if (ductMethod == DuctSizingMethod.equalFriction) {
    round = duct.sizeByEqualFriction(
      airflow: airflow,
      targetPaPerMetre: ductEqualFrictionPa,
    );
    frictionPerMetre = round.frictionPerMetrePa;
  } else {
    round = duct.sizeByVelocity(airflow: airflow, maxVelocity: maxDuctVelocity);
    frictionPerMetre = round.frictionPerMetrePa;
  }

  // 5 — equipment duty against an estimated total static pressure:
  //   internal (filter+coil+casing) + duct friction over the assumed run
  //   (× fitting factor) + supply terminal drop + return terminal drop.
  final internal = equipmentInternalStatic ?? defaultInternalStatic(equipmentKind);
  final ductLoss = frictionPerMetre * assumedDuctRun.meters * fittingFactor;
  final totalStatic = Pressure(
    internal.pascals +
        ductLoss +
        supplyTerminalLoss.pascals +
        returnTerminalLoss.pascals,
  );
  final equipment = sizeFan(
    airflow: airflow,
    totalStaticPressure: totalStatic,
    fanEfficiency: fanEfficiency,
    motorEfficiency: motorEfficiency,
  );

  return RoomAirResult(
    roomVolumeM3: volume,
    airChangesPerHour: airChangesPerHour,
    airflow: airflow,
    equipmentKind: equipmentKind,
    supply: supply,
    return_: return_,
    supplyDuctRound: round,
    supplyDuctRect: rect,
    equipment: equipment,
  );
}
