/// A5 — the unified MEP → electrical auto-feed.
///
/// The payoff of the iSystem merge: a pump or fan that the mechanical engine has
/// ALREADY sized (`PumpDuty` / `FanDuty` in `sizing/{pump,fan}.dart`) becomes an
/// electrical load automatically — no re-entry of the kW. This module is a PURE
/// MAPPING, not a parallel calculation (guardrail §12.5): the electrical
/// full-load current is DERIVED from the existing mechanical duty.
///
/// The mechanical duties carry power only — no voltage / phase / power-factor.
/// So a neutral descriptor ([MepEquipmentLoad]) is built from a duty plus the
/// electrical attributes (phases, cosφ, motor efficiency), the full-load amps are
/// derived ([equipmentFullLoadCurrent]), and the load is projected into an
/// [ElectricalCircuit] ([equipmentToCircuit]) carrying:
///   * `sourceEquipmentId` — so a re-import updates the circuit in place, and
///   * `flaOverrideA` — so A4 `computePanel` sizes off MechX's derived current
///     verbatim rather than re-deriving it from kW.
///
/// Zero Flutter imports. May import other engine code only.
library;

import 'dart:math' as math;

import '../sizing/fan.dart' show FanDuty;
import '../sizing/pump.dart' show PumpDuty;
import '../units.dart';
import 'load_kind.dart' show LoadKind;
import 'model.dart' show CircuitRole, ElectricalCircuit;
import 'sizing.dart' show loadCurrent;

// ── source taxonomy ──────────────────────────────────────────────────────────

/// The kind of MEP equipment an electrical load was derived from. Covers the
/// rotating-equipment duty providers MechX already sizes (the water-supply /
/// drainage / fire / HVAC pumps and fans), plus a [generic] catch-all.
enum MepLoadSource {
  /// Domestic / cold-water supply (booster set's lead-duty role).
  supplyPump,

  /// Pressure-booster pump.
  boosterPump,

  /// Sump / drainage lift pump.
  sumpPump,

  /// Transfer pump (ground tank → roof tank).
  transferPump,

  /// HVAC supply-air fan / AHU.
  supplyFan,

  /// Exhaust-air fan.
  exhaustFan,

  /// Return-air fan.
  returnFan,

  /// Fire pump (sprinkler / hydrant) — a life-safety load.
  firePump,

  /// Hot-water recirculation pump.
  hotWaterRecircPump,

  /// Any other rotating equipment.
  generic,
}

extension MepLoadSourceInfo on MepLoadSource {
  /// Is this source a pump (vs. a fan)? Drives the default [LoadKind].
  bool get isPump => switch (this) {
        MepLoadSource.supplyFan ||
        MepLoadSource.exhaustFan ||
        MepLoadSource.returnFan =>
          false,
        _ => true,
      };

  /// Is this source a life-safety load (no RCD, fire-resistant cable)?
  bool get isLifeSafety => this == MepLoadSource.firePump;

  /// Short human label for the derived circuit name fallback.
  String get label => switch (this) {
        MepLoadSource.supplyPump => 'Supply pump',
        MepLoadSource.boosterPump => 'Booster pump',
        MepLoadSource.sumpPump => 'Sump pump',
        MepLoadSource.transferPump => 'Transfer pump',
        MepLoadSource.supplyFan => 'Supply fan',
        MepLoadSource.exhaustFan => 'Exhaust fan',
        MepLoadSource.returnFan => 'Return fan',
        MepLoadSource.firePump => 'Fire pump',
        MepLoadSource.hotWaterRecircPump => 'HW recirc pump',
        MepLoadSource.generic => 'Equipment',
      };
}

// ── defaults ─────────────────────────────────────────────────────────────────

/// Default power factor for a rotating-machine electrical load when the duty
/// provider does not specify one. Matches the motor/pump `cosPhi` in
/// `load_kind.dart` (`loadDefaults`). NOT a PUIL clause.
const double defaultMotorCosPhi = 0.85;

/// Default motor efficiency used to convert mechanical (shaft / rated) power to
/// electrical input power when the duty does not carry `motorInputPower`. Equals
/// the `motorEfficiency` default in `sizing/{pump,fan}.dart` (0.90), so the
/// derived FLA matches the mechanical engine's own motor-input figure.
const double defaultMotorEfficiency = 0.90;

// ── neutral descriptor ───────────────────────────────────────────────────────

/// A neutral, framework-free descriptor of ONE piece of rotating equipment as an
/// electrical load. Built from a mechanical duty (see the named constructors)
/// plus the electrical attributes the duty itself does not carry.
class MepEquipmentLoad {
  /// Stable id of the source equipment (a pump / fan / AHU) in the unified
  /// iSystem load list — used to update the derived circuit in place on re-import.
  final String id;

  /// Display name.
  final String name;

  /// What kind of equipment this is.
  final MepLoadSource source;

  /// Mechanical power — the selected motor's rated output (preferred) or the
  /// rated shaft kW. This is the `motorKw` the circuit reports.
  final Power mechanicalPower;

  /// Electrical input power, when the duty knows it (`motorInputPower`). Null →
  /// derived from [mechanicalPower] / [motorEfficiency].
  final Power? electricalInputPower;

  /// Supply phase count (1 or 3).
  final int phases;

  /// Power factor (cos φ).
  final double cosPhi;

  /// Motor efficiency η_m, used to derive electrical input power when
  /// [electricalInputPower] is null.
  final double motorEfficiency;

  const MepEquipmentLoad({
    required this.id,
    required this.name,
    required this.source,
    required this.mechanicalPower,
    this.electricalInputPower,
    this.phases = 3,
    this.cosPhi = defaultMotorCosPhi,
    this.motorEfficiency = defaultMotorEfficiency,
  });

  /// True when supplied three-phase.
  bool get threePhase => phases == 3;

  /// Build a load descriptor from an already-sized [PumpDuty]. Pulls the
  /// selected standard motor as the mechanical (rated) power and the duty's
  /// `motorInputPower` as the known electrical input power.
  factory MepEquipmentLoad.fromPumpDuty(
    PumpDuty duty, {
    required String id,
    required String name,
    MepLoadSource source = MepLoadSource.supplyPump,
    int phases = 3,
    double cosPhi = defaultMotorCosPhi,
    double motorEfficiency = defaultMotorEfficiency,
  }) =>
      MepEquipmentLoad(
        id: id,
        name: name,
        source: source,
        mechanicalPower: duty.selectedMotor,
        electricalInputPower: duty.motorInputPower,
        phases: phases,
        cosPhi: cosPhi,
        motorEfficiency: motorEfficiency,
      );

  /// Build a load descriptor from an already-sized [FanDuty]. Pulls the selected
  /// standard motor and the duty's `motorInputPower`.
  factory MepEquipmentLoad.fromFanDuty(
    FanDuty duty, {
    required String id,
    required String name,
    MepLoadSource source = MepLoadSource.supplyFan,
    int phases = 3,
    double cosPhi = defaultMotorCosPhi,
    double motorEfficiency = defaultMotorEfficiency,
  }) =>
      MepEquipmentLoad(
        id: id,
        name: name,
        source: source,
        mechanicalPower: duty.selectedMotor,
        electricalInputPower: duty.motorInputPower,
        phases: phases,
        cosPhi: cosPhi,
        motorEfficiency: motorEfficiency,
      );

  /// The electrical input power that drives the load current: the known
  /// `motorInputPower` if present, else mechanical / efficiency.
  Power get inputPower =>
      electricalInputPower ?? Power(mechanicalPower.watts / motorEfficiency);
}

// ── derivation ───────────────────────────────────────────────────────────────

/// Derive the full-load amps (FLA) for [e] at a panel [voltage].
///
///   electrical input power P = electricalInputPower ?? mechanicalPower / η_m
///   I = P / (√3·V·cosφ)  (3-phase)   or   P / (V·cosφ)  (1-phase)
///
/// Reuses [loadCurrent] so the formula is the single shared definition.
Current equipmentFullLoadCurrent(
  MepEquipmentLoad e, {
  required Voltage voltage,
}) =>
    loadCurrent(
      power: e.inputPower,
      voltage: voltage,
      cosPhi: e.cosPhi,
      threePhase: e.threePhase,
    );

/// Stable circuit id for the circuit derived from equipment [e]. Deterministic
/// (prefix + equipment id) so a re-import maps onto the same circuit.
String equipmentCircuitId(MepEquipmentLoad e) => 'mep-${e.id}';

/// Project a sized piece of MEP equipment into a branch [ElectricalCircuit].
///
/// The produced circuit:
///   * `loadKind` = [LoadKind.pump] for water-source equipment, [LoadKind.motor]
///     for fans,
///   * `motorKw` = the mechanical (rated motor) power in kW,
///   * `loadW` = the electrical input power (so a consumer that ignores the
///     override still has a sensible connected load),
///   * `sourceEquipmentId` = `e.id` (re-imports update in place),
///   * `flaOverrideA` = [equipmentFullLoadCurrent] (A4 sizes off MechX's derived
///     current verbatim — see `compute.dart`, where `flaOverrideA` wins),
///   * `lifeSafety` set for a fire pump (no RCD; fire-resistant cable).
ElectricalCircuit equipmentToCircuit(
  MepEquipmentLoad e, {
  required Voltage panelVoltage,
  double lengthM = 10,
  double demandFactor = 1,
}) {
  final fla = equipmentFullLoadCurrent(e, voltage: panelVoltage);
  return ElectricalCircuit(
    id: equipmentCircuitId(e),
    name: e.name,
    role: CircuitRole.branch,
    loadW: e.inputPower.watts,
    cosPhi: e.cosPhi,
    length: Length(math.max(0, lengthM)),
    loadKind: e.source.isPump ? LoadKind.pump : LoadKind.motor,
    demandFactor: demandFactor,
    motorKw: e.mechanicalPower.inKiloWatts,
    phases: e.phases,
    lifeSafety: e.source.isLifeSafety,
    sourceEquipmentId: e.id,
    flaOverrideA: fla,
  );
}

/// Map a whole list of sized MEP equipment to electrical circuits, preserving
/// input order (stable).
List<ElectricalCircuit> buildEquipmentCircuits(
  List<MepEquipmentLoad> loads, {
  required Voltage panelVoltage,
  double lengthM = 10,
  double demandFactor = 1,
}) =>
    [
      for (final e in loads)
        equipmentToCircuit(
          e,
          panelVoltage: panelVoltage,
          lengthM: lengthM,
          demandFactor: demandFactor,
        ),
    ];
