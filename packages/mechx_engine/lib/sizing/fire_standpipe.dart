/// §P5 Fire standpipe / hydrant system + fire-pump sizing module.
///
/// ─────────────────────────────── IMPORTANT NOTICE ───────────────────────────
/// ALL design flows, pressures, and flow-accumulation rules in this file are
/// UNVERIFIED PLACEHOLDERS derived from general fire-protection practice.
/// They MUST be validated against the following Indonesian national standards
/// before use in a real project:
///
///   • SNI 03-1745-2000 — Tata Cara Perencanaan Sistem Pipa Tegak dan Slang
///     untuk Pencegahan Bahaya Kebakaran pada Bangunan Rumah dan Gedung
///     (standpipe & hose-cabinet system — flow, pressure, riser rules).
///
///   • SNI 03-6570-2001 — Instalasi Pompa yang Dipasang Tetap untuk
///     Proteksi Kebakaran
///     (fixed fire-pump installation — head, power, duty-point rules).
///
/// Every placeholder constant is tagged with `// VERIFY` in the source.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Pure Dart; zero Flutter imports (§12: engine is framework-free).
library;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/units.dart';

// ── Placeholder design constants (MUST be verified against SNI) ──────────────

/// Minimum flow demand for the first (or only) standpipe riser (L/min).
///
/// General-practice placeholder: 500 L/min per the first riser.
/// // VERIFY against SNI 03-1745-2000 for the correct demand per riser class.
const double kFirstRiserFlowLpm = 500.0; // VERIFY

/// Additional flow added for each riser beyond the first (L/min).
///
/// General-practice placeholder: 250 L/min per additional riser.
/// // VERIFY against SNI 03-1745-2000 table of riser flow demands.
const double kAdditionalRiserFlowLpm = 250.0; // VERIFY

/// Maximum total standpipe system flow demand (L/min), regardless of riser
/// count.
///
/// General-practice placeholder: 1 250 L/min cap.
/// // VERIFY against SNI 03-1745-2000 for the applicable system-flow ceiling.
const double kMaxStandpipeFlowLpm = 1250.0; // VERIFY

/// Minimum residual pressure required at the topmost hose outlet (kPa).
///
/// General-practice placeholder: 450 kPa (≈ 4.5 bar).
/// // VERIFY against SNI 03-1745-2000 for the correct minimum outlet pressure.
const double kTopResidualPressureKpa = 450.0; // VERIFY

// ── Flow-demand helper ────────────────────────────────────────────────────────

/// Total standpipe system flow demand for [risers] active risers.
///
/// Formula (placeholder — // VERIFY against SNI 03-1745-2000):
///
///   Q = kFirstRiserFlowLpm + kAdditionalRiserFlowLpm × (risers − 1)
///
/// clamped to the range `[kFirstRiserFlowLpm, kMaxStandpipeFlowLpm]`.
///
/// Examples:
///   risers = 1 →  500 L/min  (0.00833… m³/s)
///   risers = 2 →  750 L/min  (0.01250  m³/s)
///   risers = 4 → 1250 L/min  (0.02083… m³/s) [cap]
///   risers = 6 → 1250 L/min  (cap applies)
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
///
/// ─── UNVERIFIED PLACEHOLDERS ─────────────────────────────────────────────────
/// The values depend on [kFirstRiserFlowLpm], [kAdditionalRiserFlowLpm],
/// [kMaxStandpipeFlowLpm], and [kTopResidualPressureKpa], which are all
/// general-practice placeholders that MUST be verified against
/// SNI 03-1745-2000 and SNI 03-6570-2001 before use in production.
/// ─────────────────────────────────────────────────────────────────────────────
class FireStandpipeDesign {
  /// Total flow the fire pump must deliver to the standpipe system.
  final FlowRate requiredFlow;

  /// Minimum residual pressure required at the topmost hose outlet.
  ///
  /// // VERIFY: 450 kPa placeholder — see [kTopResidualPressureKpa].
  final Pressure topResidualPressure;

  /// Total pump head: static lift + friction allowance + residual-pressure head.
  final Head pumpHead;

  /// Useful (hydraulic) power delivered to the fluid: P = ρ · g · Q · H.
  final Power pumpHydraulicPower;

  /// Shaft (brake) power the pump motor must supply: P_shaft = P_hyd / η.
  final Power pumpShaftPower;

  const FireStandpipeDesign({
    required this.requiredFlow,
    required this.topResidualPressure,
    required this.pumpHead,
    required this.pumpHydraulicPower,
    required this.pumpShaftPower,
  });
}

// ── Public sizing API ─────────────────────────────────────────────────────────

/// Size a fire standpipe + pump system for a building with [risers] risers and
/// a roof / topmost-outlet height of [buildingHeight].
///
/// ### Head budget (unverified placeholder — // VERIFY against SNI 03-6570-2001)
///
///   pumpHead = buildingHeight       (static lift to the topmost outlet)
///            + frictionAllowance   (allowance for pipe friction losses)
///            + headFromPressure(topResidual)   (residual pressure as head)
///
/// ### Parameters
///
/// * [risers] — number of active standpipe risers (≥ 1).
/// * [buildingHeight] — elevation from pump datum to the topmost hose outlet.
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
  Head frictionAllowance = const Head(15),
  double pumpEfficiency = 0.70,
}) {
  assert(risers >= 1, 'risers must be ≥ 1');
  assert(
    pumpEfficiency > 0 && pumpEfficiency <= 1,
    'pumpEfficiency must be in (0, 1]',
  );

  // Required system flow demand. // VERIFY against SNI 03-1745-2000.
  final requiredFlow = standpipeFlow(risers);

  // Minimum residual pressure at the topmost hose outlet. // VERIFY.
  final topResidual = Pressure.kiloPascals(kTopResidualPressureKpa); // VERIFY

  // Convert residual pressure to an equivalent head of water (h = P / ρg).
  final residualHead = headFromPressure(topResidual);

  // Total pump head = static lift + friction allowance + residual head.
  // // VERIFY head budget against SNI 03-6570-2001 and a network analysis.
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
    requiredFlow: requiredFlow,
    topResidualPressure: topResidual,
    pumpHead: pumpHead,
    pumpHydraulicPower: pumpHydraulicPower,
    pumpShaftPower: pumpShaftPower,
  );
}
