/// §P5 Fire standpipe / hydrant system + fire-pump sizing module.
///
/// ─────────────────────────────── PROVENANCE ─────────────────────────────────
/// The design flows, residual pressures, riser-diameter minimum, and flow-
/// accumulation rules in this file are taken from the Indonesian national
/// standards below. Engineering assumptions that the standards do NOT fix
/// (friction allowance, pump efficiency) remain tagged `// VERIFY`.
///
///   • SNI 03-1745-2000 — Tata Cara Perencanaan dan Pemasangan Sistem Pipa
///     Tegak dan Slang untuk Pencegahan Bahaya Kebakaran pada Bangunan Rumah
///     dan Gedung (standpipe & hose-cabinet system — flow, pressure, riser
///     rules).
///
///   • SNI 03-6570-2001 — Instalasi Pompa yang Dipasang Tetap untuk Proteksi
///     Kebakaran (fixed fire-pump installation — head, power, duty-point rules).
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Pure Dart; zero Flutter imports (§12: engine is framework-free).
library;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/units.dart';

// ── Unit conversion ──────────────────────────────────────────────────────────

/// US liquid gallon → litre. SNI 03-1745-2000 states standpipe flow demands in
/// US gpm (adopted from NFPA 14); we work internally in L/min.
const double _usGallonToLitre = 3.785411784;

// ── Standpipe class ──────────────────────────────────────────────────────────

/// Standpipe system class per SNI 03-1745-2000 §4, selected by hose-outlet size
/// and intended user. The class fixes the minimum residual pressure required at
/// the topmost (most remote) outlet.
enum StandpipeClass {
  /// Class I — 65 mm (2½") connections for trained fire-fighters. Residual
  /// 6.9 bar (690 kPa) at the most remote outlet.
  classI,

  /// Class II — 40 mm (1½") hose stations for building occupants. Residual
  /// 4.5 bar (450 kPa) at the most remote outlet.
  classII,

  /// Class III — both 65 mm and 40 mm outlets. The 65 mm outlet governs, so the
  /// higher Class I residual (6.9 bar) applies.
  classIII,
}

// ── Design constants (SNI 03-1745-2000) ──────────────────────────────────────

/// Minimum flow demand of the most remote (first) standpipe riser, in L/min.
///
/// SNI 03-1745-2000: 550 gpm at the hydraulically most remote standpipe.
const double kFirstRiserFlowLpm = 550.0 * _usGallonToLitre; // ≈ 2082 L/min

/// Additional flow added for each riser beyond the first, in L/min.
///
/// SNI 03-1745-2000: 250 gpm per additional standpipe.
const double kAdditionalRiserFlowLpm = 250.0 * _usGallonToLitre; // ≈ 946 L/min

/// Maximum total standpipe system flow demand, in L/min, regardless of riser
/// count.
///
/// SNI 03-1745-2000: the sum need not exceed 1250 gpm.
const double kMaxStandpipeFlowLpm = 1250.0 * _usGallonToLitre; // ≈ 4732 L/min

/// Minimum residual pressure at the most remote 65 mm (Class I/III) outlet, kPa.
///
/// SNI 03-1745-2000: 6.9 bar (100 psi) at the farthest 65 mm hose connection.
const double kResidualPressureClassIKpa = 690.0;

/// Minimum residual pressure at the most remote 40 mm (Class II) outlet, kPa.
///
/// SNI 03-1745-2000: 4.5 bar (65 psi) at the farthest 40 mm hose-box outlet.
const double kResidualPressureClassIIKpa = 450.0;

/// Minimum standpipe (riser) diameter for Class I and Class III systems.
///
/// SNI 03-1745-2000: standpipes for Class I and III must be at least 100 mm
/// (4"). (Class II systems may use smaller risers.)
const double kMinRiserDiameterMm = 100.0;

/// Minimum residual pressure required at the topmost outlet for [cls], in kPa.
double residualPressureKpa(StandpipeClass cls) {
  switch (cls) {
    case StandpipeClass.classI:
    case StandpipeClass.classIII:
      return kResidualPressureClassIKpa;
    case StandpipeClass.classII:
      return kResidualPressureClassIIKpa;
  }
}

// ── Flow-demand helper ────────────────────────────────────────────────────────

/// Total standpipe system flow demand for [risers] active risers
/// (SNI 03-1745-2000):
///
///   Q = kFirstRiserFlowLpm + kAdditionalRiserFlowLpm × (risers − 1)
///
/// clamped to the range `[kFirstRiserFlowLpm, kMaxStandpipeFlowLpm]`
/// (i.e. 550 gpm minimum, 1250 gpm cap).
///
/// Examples (gpm → L/min):
///   risers = 1 →  550 gpm ≈ 2082 L/min
///   risers = 2 →  800 gpm ≈ 3028 L/min
///   risers = 4 → 1250 gpm ≈ 4732 L/min [cap reached at 1250 gpm]
///   risers = 6 → 1250 gpm (cap applies)
FlowRate standpipeFlow(int risers) {
  assert(risers >= 1, 'risers must be ≥ 1');
  final lpm = (kFirstRiserFlowLpm + kAdditionalRiserFlowLpm * (risers - 1))
      .clamp(kFirstRiserFlowLpm, kMaxStandpipeFlowLpm);
  return FlowRate.litersPerMinute(lpm);
}

// ── Design result ─────────────────────────────────────────────────────────────

/// All quantities produced by [designStandpipe] for one fire standpipe system.
///
/// Every field is a typed SI quantity from `units.dart`.
class FireStandpipeDesign {
  /// Standpipe class governing the residual-pressure requirement.
  final StandpipeClass standpipeClass;

  /// Total flow the fire pump must deliver to the standpipe system.
  final FlowRate requiredFlow;

  /// Minimum residual pressure required at the topmost hose outlet
  /// (SNI 03-1745-2000: 6.9 bar Class I/III, 4.5 bar Class II).
  final Pressure topResidualPressure;

  /// Minimum riser diameter for the system (100 mm for Class I/III).
  final Diameter minRiserDiameter;

  /// Total pump head: static lift + friction allowance + residual-pressure head.
  final Head pumpHead;

  /// Useful (hydraulic) power delivered to the fluid: P = ρ · g · Q · H.
  final Power pumpHydraulicPower;

  /// Shaft (brake) power the pump motor must supply: P_shaft = P_hyd / η.
  final Power pumpShaftPower;

  const FireStandpipeDesign({
    required this.standpipeClass,
    required this.requiredFlow,
    required this.topResidualPressure,
    required this.minRiserDiameter,
    required this.pumpHead,
    required this.pumpHydraulicPower,
    required this.pumpShaftPower,
  });
}

// ── Public sizing API ─────────────────────────────────────────────────────────

/// Size a fire standpipe + pump system for a building with [risers] risers and
/// a roof / topmost-outlet height of [buildingHeight].
///
/// ### Head budget (SNI 03-6570-2001 — verify against a full network analysis)
///
///   pumpHead = buildingHeight       (static lift to the topmost outlet)
///            + frictionAllowance    (allowance for pipe friction losses)
///            + headFromPressure(topResidual)   (residual pressure as head)
///
/// ### Parameters
///
/// * [risers] — number of active standpipe risers (≥ 1).
/// * [buildingHeight] — elevation from pump datum to the topmost hose outlet.
/// * [standpipeClass] — system class (default [StandpipeClass.classI]); fixes
///   the topmost-outlet residual pressure per SNI 03-1745-2000.
/// * [frictionAllowance] — conservative fixed head allowance for pipe friction
///   losses in the standpipe mains (default 15 m).
///   // VERIFY against a full Hazen–Williams network calculation per
///   SNI 03-1745-2000 once pipe diameters and routes are fixed.
/// * [pumpEfficiency] — overall pump + motor efficiency η (0 < η ≤ 1, default
///   0.70). // VERIFY against the selected pump's certified performance curve
///   per SNI 03-6570-2001.
///
/// ### Returns
///
/// A [FireStandpipeDesign] with all quantities computed using the hydraulic
/// kernel from `hydraulics.dart` (ρ = 1000 kg/m³, g = 9.81 m/s²).
FireStandpipeDesign designStandpipe({
  required int risers,
  required Length buildingHeight,
  StandpipeClass standpipeClass = StandpipeClass.classI,
  Head frictionAllowance = const Head(15),
  double pumpEfficiency = 0.70,
}) {
  assert(risers >= 1, 'risers must be ≥ 1');
  assert(
    pumpEfficiency > 0 && pumpEfficiency <= 1,
    'pumpEfficiency must be in (0, 1]',
  );

  // Required system flow demand (SNI 03-1745-2000).
  final requiredFlow = standpipeFlow(risers);

  // Minimum residual pressure at the topmost hose outlet for this class.
  final topResidual =
      Pressure.kiloPascals(residualPressureKpa(standpipeClass));

  // Convert residual pressure to an equivalent head of water (h = P / ρg).
  final residualHead = headFromPressure(topResidual);

  // Total pump head = static lift + friction allowance + residual head.
  final totalHeadMeters =
      buildingHeight.meters + frictionAllowance.meters + residualHead.meters;
  final pumpHead = Head(totalHeadMeters);

  // Pump power calculations using the hydraulic kernel.
  final pumpHydraulicPower = hydraulicPower(
    flow: requiredFlow,
    head: pumpHead,
  );
  final pumpShaftPower = shaftPower(
    flow: requiredFlow,
    head: pumpHead,
    efficiency: pumpEfficiency,
  );

  return FireStandpipeDesign(
    standpipeClass: standpipeClass,
    requiredFlow: requiredFlow,
    topResidualPressure: topResidual,
    minRiserDiameter: Diameter.mm(kMinRiserDiameterMm),
    pumpHead: pumpHead,
    pumpHydraulicPower: pumpHydraulicPower,
    pumpShaftPower: pumpShaftPower,
  );
}
