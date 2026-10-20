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

import 'compute.dart' show effectiveDemandFactor;
import 'diversity_library.dart' show DiversityLibrary;
import 'load_kind.dart' show LoadKind, kAssumedMotorEfficiency;
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

/// Smallest standard bank (kVAR) covering [requiredKvar], with the bank count:
/// one bank when the ladder covers it, else `n = ceil(required / top)` banks of
/// the largest rating — never one bank BELOW the requirement (audit r8).
({double kvar, int banks}) _selectCapacitorBanks(double requiredKvar) {
  for (final k in capacitorBankKvarLadder) {
    if (k >= requiredKvar) return (kvar: k, banks: 1);
  }
  final top = capacitorBankKvarLadder.last;
  return (kvar: top, banks: (requiredKvar / top).ceil());
}

// ── Result type ──────────────────────────────────────────────────────────────

/// Power-factor / capacitor-bank result.
class PowerFactorResult {
  /// Aggregate real demand (kW) over the leaf loads.
  final double totalKw;

  /// Aggregate reactive demand (kvar) over the leaf loads.
  final double totalKvar;

  /// Existing power factor (3 dp) — Round 16: AFTER the compensation already
  /// installed ([installedKvar]); equal to [uncorrectedPf] when none is.
  final double existingPf;

  /// Round 16 — the load's own power factor before any installed bank (3 dp).
  final double uncorrectedPf;

  /// Round 16 — compensation already installed (kvar, as delivered at the
  /// worst panel ambient): the capacitor ways' ratings, else the project's
  /// declared `capacitorBankKvar`. 0 when none.
  final double installedKvar;

  /// Round 16 — true when the installed compensation exceeds the reactive
  /// demand (the bus runs LEADING).
  final bool leading;

  /// Correction target power factor.
  final double targetPf;

  /// True when [existingPf] is below the PLN penalty threshold (a bank is
  /// recommended to avoid the penalty).
  final bool needed;

  /// Required compensation to reach [targetPf] (kvar) — 0 when already at/above.
  final double requiredKvar;

  /// Selected bank nameplate (kVAR) — 0 when no correction is sized. The TOTAL
  /// installed compensation (`banks × per-bank rating`).
  final double bankKvar;

  /// Number of banks (> 1 only when the requirement exceeds the largest
  /// standard bank — then each bank is `bankKvar / banks`).
  final int banks;

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
    this.uncorrectedPf = 1.0,
    this.installedKvar = 0,
    this.leading = false,
    required this.targetPf,
    required this.needed,
    required this.requiredKvar,
    required this.bankKvar,
    this.banks = 1,
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
  /// Optional occupancy diversity library — the SAME one the core solve used,
  /// so each leaf's demand factor matches `circuitConnectedW`. Null ⇒ the
  /// per-circuit factor (the app today).
  DiversityLibrary? diversityLibrary,
}) {
  var kw = 0.0;
  var kvar = 0.0;

  // Round 13 (elec-props-2-pfc-ignores-diversity) — the bank compensates the
  // DIVERSIFIED demand the supply summary reports, so each leaf carries its
  // effective demand factor (library-aware) × the diversityFactor of its board
  // AND of every board upstream (the supply demand applies each level's
  // diversity in turn). It used to apply only the per-circuit factor, so a
  // board at diversity 0.5 got a bank sized on twice the kW it compensates.
  final parentOf = <String, String>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final fed = c.feedsPanelId;
      if (fed != null && fed.isNotEmpty) parentOf[fed] = p.id;
    }
  }
  final byId = {for (final p in project.panels) p.id: p};
  double pathDiversity(String id) {
    var f = 1.0;
    final seen = <String>{};
    String? cur = id;
    while (cur != null && seen.add(cur)) {
      f *= byId[cur]?.diversityFactor ?? 1.0;
      cur = parentOf[cur];
    }
    return f;
  }

  for (final panel in project.panels) {
    final boardDiversity = pathDiversity(panel.id);
    for (final c in panel.circuits) {
      if (!_isLeafLoad(c)) continue;
      // Motor shaft rating drives the connected kW when given; else the W field.
      // A motor/pump way's ELECTRICAL input is shaft ÷ efficiency — the same
      // basis `compute.dart` derives its Ib from — so the reactive demand the
      // bank must cancel is not understated by ~1/0.88.
      final motorLike =
          c.loadKind == LoadKind.motor || c.loadKind == LoadKind.pump;
      //
      // Round 36 (elec-props-4-stale-motorkw-after-rekind) — a NON-motor way
      // sizes on its `loadW` in compute (motorKw is read only on motor / pump
      // ways), so a stray `motorKw` (left by re-kinding a motor to HVAC /
      // general, hidden by the inspector) never becomes the bank's kW while
      // `loadW` is set.
      final double baseKw;
      if (motorLike && c.motorKw != null) {
        baseKw = c.motorKw! / kAssumedMotorEfficiency;
      } else if (c.loadW > 0 || c.motorKw == null) {
        baseKw = c.loadW / 1000.0;
      } else {
        baseKw = c.motorKw!;
      }
      final loadKw = baseKw *
          effectiveDemandFactor(c,
              library: diversityLibrary,
              diversityLibraryId: panel.diversityLibraryId) *
          boardDiversity;
      final pf = _clampPf(_isElectronic(c) ? electronicLoadPf : c.cosPhi);
      final phi = math.acos(pf);
      kw += loadKw;
      kvar += loadKw * math.tan(phi);
    }
  }

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

  // Round 16 (supply-sources-installed-pfc-ignored) — compensation ALREADY
  // installed: every capacitor way's rating (a capacitor way's `loadW` is its
  // kvar), else the project's declared `capacitorBankKvar` when no way models
  // it — as delivered hot (× the same ambient derate the new bank is
  // oversized for). An automatic bank switches up to its rating, so no load
  // diversity applies to it. The study used to drop the bank from the
  // aggregate without subtracting it, so an installed 75 kvar bank still read
  // pf 0.75 and was told to fit a SECOND 75 kvar bank (150 kvar against
  // 105.8 kvar of demand — a leading bus).
  var installedRated = 0.0;
  for (final panel in project.panels) {
    for (final c in panel.circuits) {
      if (c.loadKind == LoadKind.capacitor && c.loadW > 0) {
        installedRated += c.loadW / 1000.0;
      }
    }
  }
  if (installedRated <= 0) installedRated = project.capacitorBankKvar ?? 0;
  final installedKvar = installedRated * tempDerate;
  final uncorrectedKva = _hypot(kw, kvar);
  final uncorrectedPf = uncorrectedKva > 0 ? kw / uncorrectedKva : 1.0;
  final residualKvar = kvar - installedKvar;
  final leading = installedKvar > 0 && residualKvar < 0;
  final kva = _hypot(kw, residualKvar);
  final existingPf = kva > 0 ? kw / kva : 1.0;
  // A leading bus is not corrected further (more capacitance only worsens it).
  final needed = !leading && existingPf < pfPenaltyThreshold;

  var requiredKvar = 0.0;
  var bankKvar = 0.0;
  var stepKvar = 0.0;
  var steps = 0;
  var banks = 1;
  if (!leading && existingPf < targetPf && kw > 0) {
    final phi1 = math.acos(_clampPf(existingPf));
    final phi2 = math.acos(_clampPf(targetPf));
    requiredKvar = kw * (math.tan(phi1) - math.tan(phi2));
    // Oversize the nameplate so the hot bank still delivers `requiredKvar`.
    final sel = _selectCapacitorBanks(requiredKvar / tempDerate);
    banks = sel.banks;
    bankKvar = sel.kvar * sel.banks;
    stepKvar = capacitorStepKvar(sel.kvar);
    steps = math.max(1, (bankKvar / stepKvar).round());
  }

  // A plain bank on a harmonic-rich bus risks parallel resonance with the
  // supply inductance — detuning reactors (typ. 7 %, 189 Hz) shift the
  // resonance below the 5th harmonic so the bank does not amplify it.
  final detuned = harmonicRich && bankKvar > 0;

  final existingPfR = _round(existingPf, 2);
  final installedText = installedKvar > 0
      ? 'With the installed ${_fmt(installedRated)} kVAR of compensation '
          '(load pf ${_round(uncorrectedPf, 2)}), '
      : '';
  var note = leading
      ? '${installedText}the bus runs LEADING at pf $existingPfR — the '
          'installed compensation exceeds the ${_round(kvar, 1)} kvar reactive '
          'demand; reduce the bank (or its automatic steps).'
      : installedText + (needed
      ? 'Power factor $existingPfR is below the $pfPenaltyThreshold PLN penalty '
          'threshold — fit ${banks > 1 ? '$banks x ${_fmt(bankKvar / banks)} kVAR '
              'automatic banks (exceeds the largest standard bank), total '
              '${_fmt(bankKvar)} kVAR' : 'a ${_fmt(bankKvar)} kVAR automatic bank'} '
          '($steps x ${_fmt(stepKvar)} kVAR) to reach $targetPf.'
      : existingPf < targetPf
          ? 'Power factor $existingPfR avoids the PLN penalty; a '
              '${_fmt(bankKvar)} kVAR bank would raise it to $targetPf and cut '
              'losses.'
          : 'Power factor $existingPfR is already at/above target — no '
              '${installedKvar > 0 ? 'further ' : ''}correction needed.');
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
    uncorrectedPf: _round(uncorrectedPf, 3),
    installedKvar: _round(installedKvar, 1),
    leading: leading,
    targetPf: targetPf,
    needed: needed,
    requiredKvar: _round(requiredKvar, 1),
    bankKvar: bankKvar,
    banks: banks,
    stepKvar: stepKvar,
    steps: steps,
    detuned: detuned,
    note: note,
    verifyItems: const [
      'PF penalty threshold 0.85 / target 0.95 — secondary source (verify vs '
          'PLN reactive-energy tariff).',
      'Capacitor bank kVAR ladder + step rule + ambient derate — secondary '
          'source (verify vs the chosen manufacturer / IEC 60831).',
      'Assumed motor efficiency 0.88 (shaft kW to electrical input kW) — '
          'secondary source (verify vs the motor nameplate).',
    ],
  );
}

/// `√(a² + b²)` without overflow concerns at these magnitudes.
double _hypot(double a, double b) => math.sqrt(a * a + b * b);

String _fmt(double x) =>
    x == x.roundToDouble() ? x.toInt().toString() : x.toStringAsFixed(1);
