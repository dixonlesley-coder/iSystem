/// A8b — power-factor correction (capacitor bank) sizing. Pure post-processing
/// pass over the A4 result + the input project.
///
/// Ported from PanelMaker `engine/capacitor.ts` + `standards/capacitor.ts`. In
/// Indonesia PLN applies a reactive-energy (kVARh) penalty when the average
/// power factor falls below ~0.85; correction is typically designed to ~0.95.
///
/// Aggregates the installation's real (kW) and reactive (kvar) demand over the
/// REAL leaf loads (a leaf = a branch way that does not feed a sub-panel and is
/// not a spare/feeder/capacitor — feeders would double-count the loads below
/// them), derives the existing PF and, when it is below the penalty threshold,
/// sizes a capacitor bank to reach the target. Electronic / VFD-fed loads
/// present a near-unity input displacement PF, so they are treated as ~0.95
/// (no significant reactive demand).
///
/// PROVENANCE: thresholds + ladders are local `// VERIFY` constants with a tier
/// note; the result carries a [verifyItems] list. Zero Flutter imports.
library;

import 'dart:math' as math;

import 'load_kind.dart' show LoadKind;
import 'model.dart'
    show CircuitRole, ElectricalCircuit, ElectricalProject;
import 'panel_results.dart' show ElectricalSystemResult;

// ── Local reference constants (`// VERIFY`) ─────────────────────────────────

/// Power factor below which a PLN reactive-power penalty applies.
/// // VERIFY — secondary source (PLN reactive-energy penalty ≈ 0.85).
const double pfPenaltyThreshold = 0.85;

/// Default correction target power factor.
/// // VERIFY — secondary source (common PFC design target 0.95).
const double pfTargetDefault = 0.95;

/// Displacement PF assumed for electronic / VFD-fed loads (near unity at input).
/// // VERIFY — secondary source (typical front-end displacement PF).
const double electronicLoadPf = 0.95;

/// Standard automatic power-factor-correction bank ratings (kVAR), ascending.
/// // VERIFY — secondary source (common automatic-bank ratings).
const List<double> capacitorBankKvarLadder = [
  10, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 600, 800, 1000,
];

/// Step size (kVAR) for an automatic bank of a given total.
/// // VERIFY — secondary source (typical step granularity).
double capacitorStepKvar(double bankKvar) {
  if (bankKvar <= 50) return 5;
  if (bankKvar <= 150) return 25;
  return 50;
}

/// Smallest standard bank (kVAR) covering [requiredKvar] (largest ladder entry
/// when the requirement exceeds the catalogue).
double _selectCapacitorBankKvar(double requiredKvar) {
  for (final k in capacitorBankKvarLadder) {
    if (k >= requiredKvar) return k;
  }
  return capacitorBankKvarLadder.last;
}

// ── Result type ──────────────────────────────────────────────────────────────

/// Power-factor / capacitor-bank result.
class PowerFactorResult {
  /// Aggregate real demand (kW) over the leaf loads.
  final double totalKw;

  /// Aggregate reactive demand (kvar) over the leaf loads.
  final double totalKvar;

  /// Existing (uncorrected) power factor (3 dp).
  final double existingPf;

  /// Correction target power factor.
  final double targetPf;

  /// True when [existingPf] is below the PLN penalty threshold (a bank is
  /// recommended to avoid the penalty).
  final bool needed;

  /// Required compensation to reach [targetPf] (kvar) — 0 when already at/above.
  final double requiredKvar;

  /// Selected bank nameplate (kVAR) — 0 when no correction is sized.
  final double bankKvar;

  /// Automatic-bank step size (kVAR) — 0 when no bank is sized.
  final double stepKvar;

  /// Number of switching steps (≥ 1 when a bank is sized, else 0).
  final int steps;

  /// True when a DETUNED bank (≈7 % reactors) is recommended (harmonic-rich bus).
  final bool detuned;

  /// Plain-language summary.
  final String note;

  /// Provenance items still to verify against an official document.
  final List<String> verifyItems;

  const PowerFactorResult({
    required this.totalKw,
    required this.totalKvar,
    required this.existingPf,
    required this.targetPf,
    required this.needed,
    required this.requiredKvar,
    required this.bankKvar,
    required this.stepKvar,
    required this.steps,
    required this.detuned,
    required this.note,
    required this.verifyItems,
  });
}

// ── Aggregation + sizing ─────────────────────────────────────────────────────

double _clampPf(double pf) => math.min(0.999, math.max(0.3, pf));

double _round(double x, int dp) {
  final f = math.pow(10, dp).toDouble();
  return (x * f).round() / f;
}

/// Whether a circuit's PF should be treated as the near-unity electronic value
/// (VFD / electronic front end). UPS and EV chargers are electronically fed.
bool _isElectronic(ElectricalCircuit c) =>
    c.loadKind == LoadKind.ups || c.loadKind == LoadKind.evCharger;

/// Whether a circuit contributes a real load to the PF aggregate. Feeders
/// (which represent the diversified demand of a downstream panel) are excluded
/// to avoid double-counting; so are spares (no load) and capacitor banks
/// (they ARE the correction, not a load).
bool _isLeafLoad(ElectricalCircuit c) =>
    c.role == CircuitRole.branch &&
    !c.isFeeder &&
    c.loadKind != LoadKind.spare &&
    c.loadKind != LoadKind.capacitor;

/// Aggregate the installation's real + reactive demand, derive the existing PF
/// and, when below the penalty threshold, size a capacitor bank to reach
/// [targetPf].
///
/// `requiredKvar = kW·(tanφ₁ − tanφ₂)`, oversized for the worst panel ambient
/// (IEC 60831 ~0.6 %/°C above a 30 °C reference) so the hot bank still delivers
/// the required compensation, then rounded up to the next standard bank.
///
/// [sys] supplies the per-panel ambient (for the temperature derate); [project]
/// supplies the leaf-load list (load W, cos φ, demand factor, kind). The pass is
/// pure — it reads, never mutates, both.
PowerFactorResult powerFactorCorrection(
  ElectricalSystemResult sys,
  ElectricalProject project, {
  double targetPf = pfTargetDefault,
  /// True when the installation carries significant harmonic distortion (e.g.
  /// VFD-heavy). A8 harmonics may set this; defaults false.
  bool harmonicRich = false,
}) {
  var kw = 0.0;
  var kvar = 0.0;

  for (final panel in project.panels) {
    for (final c in panel.circuits) {
      if (!_isLeafLoad(c)) continue;
      // Motor shaft rating drives the connected kW when given; else the W field.
      final baseKw = (c.motorKw != null) ? c.motorKw! : c.loadW / 1000.0;
      final loadKw = baseKw * c.demandFactor;
      final pf = _clampPf(_isElectronic(c) ? electronicLoadPf : c.cosPhi);
      final phi = math.acos(pf);
      kw += loadKw;
      kvar += loadKw * math.tan(phi);
    }
  }

  final kva = _hypot(kw, kvar);
  final existingPf = kva > 0 ? kw / kva : 1.0;
  final needed = existingPf < pfPenaltyThreshold;

  // Capacitor output falls with ambient (IEC 60831, ~0.6 %/°C above a 30 °C
  // reference). At an Indonesian PFC-room 45–50 °C the delivered kvar is
  // ~10–15 % low, so the NAMEPLATE bank is oversized to still deliver the
  // required compensation hot.
  var ambientC = 30.0;
  for (final p in project.panels) {
    if (p.ambientTempC > ambientC) ambientC = p.ambientTempC;
  }
  final tempDerate =
      ambientC > 30 ? math.max(0.85, 1 - 0.006 * (ambientC - 30)) : 1.0;

  var requiredKvar = 0.0;
  var bankKvar = 0.0;
  var stepKvar = 0.0;
  var steps = 0;
  if (existingPf < targetPf && kw > 0) {
    final phi1 = math.acos(_clampPf(existingPf));
    final phi2 = math.acos(_clampPf(targetPf));
    requiredKvar = kw * (math.tan(phi1) - math.tan(phi2));
    // Oversize the nameplate so the hot bank still delivers `requiredKvar`.
    bankKvar = _selectCapacitorBankKvar(requiredKvar / tempDerate);
    stepKvar = capacitorStepKvar(bankKvar);
    steps = math.max(1, (bankKvar / stepKvar).round());
  }

  // A plain bank on a harmonic-rich bus risks parallel resonance with the
  // supply inductance — detuning reactors (typ. 7 %, 189 Hz) shift the
  // resonance below the 5th harmonic so the bank does not amplify it.
  final detuned = harmonicRich && bankKvar > 0;

  final existingPfR = _round(existingPf, 2);
  var note = needed
      ? 'Power factor $existingPfR is below the $pfPenaltyThreshold PLN penalty '
          'threshold — fit a ${_fmt(bankKvar)} kVAR automatic bank '
          '($steps x ${_fmt(stepKvar)} kVAR) to reach $targetPf.'
      : existingPf < targetPf
          ? 'Power factor $existingPfR avoids the PLN penalty; a '
              '${_fmt(bankKvar)} kVAR bank would raise it to $targetPf and cut '
              'losses.'
          : 'Power factor $existingPfR is already at/above target — no '
              'correction needed.';
  if (detuned) {
    note += ' The installation carries significant harmonic distortion — '
        'specify a DETUNED bank (~7% reactors) so the capacitors do not '
        'resonate with the supply.';
  }
  if (tempDerate < 1 && bankKvar > 0) {
    note += ' Bank oversized for a ${_fmt(ambientC)} C ambient '
        '(x${_round(1 / tempDerate, 2)}) so it still delivers '
        '${_round(requiredKvar, 1)} kVAR hot.';
  }

  return PowerFactorResult(
    totalKw: _round(kw, 1),
    totalKvar: _round(kvar, 1),
    existingPf: _round(existingPf, 3),
    targetPf: targetPf,
    needed: needed,
    requiredKvar: _round(requiredKvar, 1),
    bankKvar: bankKvar,
    stepKvar: stepKvar,
    steps: steps,
    detuned: detuned,
    note: note,
    verifyItems: const [
      'PF penalty threshold 0.85 / target 0.95 — secondary source (verify vs '
          'PLN reactive-energy tariff).',
      'Capacitor bank kVAR ladder + step rule + ambient derate — secondary '
          'source (verify vs the chosen manufacturer / IEC 60831).',
    ],
  );
}

/// `√(a² + b²)` without overflow concerns at these magnitudes.
double _hypot(double a, double b) => math.sqrt(a * a + b * b);

String _fmt(double x) =>
    x == x.roundToDouble() ? x.toInt().toString() : x.toStringAsFixed(1);
