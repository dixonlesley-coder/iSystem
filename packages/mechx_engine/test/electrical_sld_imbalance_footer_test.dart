// H7 — the panel-schedule TOTAL footer now appends the panel's already-
// computed phase-imbalance percentage (`ElectricalPanelResult.imbalancePercent`,
// the same figure `electrical_calc_report.dart` prints in its phase-balance
// bullet), gated on the board being genuinely 3-phase so a single-phase board
// stays byte-identical.
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/model.dart' show ElectricalSystemInfo;
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:test/test.dart';

// Reuses the real "Menara Contoh" acceptance-harness fixture (the same
// MDP -> LP-1 / PP-1 / EMG project the WORKFLOW-GOLDENS-REVIEW export audit
// exercises) so the imbalance figure is hand-verifiable against a real,
// already-reviewed project rather than a one-off test fixture.
import '../tool/generate_export_samples.dart' show buildElectrical;

void main() {
  const profile = PuilProfile();

  List<String> sheetLabels(SldSheet sheet) =>
      [for (final p in sheet.prims) if (p is SldLabel) p.text];

  test(
      '3-phase board — TOTAL footer prints "imbalance N%" matching a hand '
      'derivation from the printed R/S/T amps', () {
    final project = buildElectrical();
    final result = computeSystem(profile, project);
    final mdp = result.panels['MDP']!;

    // The board's own per-line currents (already asserted against by other
    // compute tests) — read off the SAME result the drawing renders from.
    expect(mdp.system.isThreePhase, isTrue);
    final l1 = mdp.phaseBalance.l1;
    final l2 = mdp.phaseBalance.l2;
    final l3 = mdp.phaseBalance.l3;
    // Sample-project fixture values (Menara Contoh MDP): R=134.4A S=75.3A
    // T=75.3A.
    //
    // Re-derived 2026-07-30 (audit E8a): LP-1 is a SINGLE-PHASE 220 V board, and
    // its feeder now takes the FED board's voltage as its base instead of the
    // 3φ parent's 231 V phase voltage. The feeder carries LP-1's 11 050 W
    // diversified demand at the feeder default cosφ 0.85, so
    //   Ib = 11 050 / (220 × 0.85) = 59.09 A -> 59.1 A   (was 11 050 /
    //        (231 × 0.85) = 56.28 -> 56.3 A), i.e. +2.8 A on line R.
    // R therefore reads 131.6 + 2.8 = 134.4 A; S and T are untouched.
    expect(l1, closeTo(134.4, 0.05));
    expect(l2, closeTo(75.3, 0.05));
    expect(l3, closeTo(75.3, 0.05));

    // Hand derivation of the imbalance the engine must have computed:
    //   avg   = (134.4 + 75.3 + 75.3) / 3       = 285.0 / 3   = 95.0 A
    //   imbal = (max - min) / avg * 100         = (134.4 - 75.3) / 95.0 * 100
    //         = 59.1 / 95.0 * 100               = 62.2105...%
    //   rounded to 1 dp (the engine's own `roundTo(_, 1)`)   -> 62.2%
    final avg = (l1 + l2 + l3) / 3;
    final handImbalance = (l1 - l3) / avg * 100; // max=l1, min=l3(==l2)
    expect(handImbalance, closeTo(62.2, 0.05));
    expect(mdp.imbalancePercent, closeTo(62.2, 0.05));

    final sheet =
        buildElectricalPanelDetail(project: project, result: result, panelId: 'MDP');
    final total = sheetLabels(sheet).firstWhere((t) => t.startsWith('TOTAL'));
    expect(total, contains('imbalance 62.2%'),
        reason: 'the printed TOTAL footer must carry the same imbalance % '
            'the engine computed, not a re-derived or rounded-differently one');
  });

  test(
      'single-phase board — TOTAL footer carries NO imbalance token '
      '(byte-identical to the pre-H7 footer)', () {
    final project = buildElectrical();
    final result = computeSystem(profile, project);
    final lp1 = result.panels['LP1']!;
    expect(lp1.system.isThreePhase, isFalse);

    final sheet =
        buildElectricalPanelDetail(project: project, result: result, panelId: 'LP1');
    final total = sheetLabels(sheet).firstWhere((t) => t.startsWith('TOTAL'));
    expect(total, isNot(contains('imbalance')));
    // Exact pre-H7 shape: 'TOTAL  <kW|W> / <A>A' and nothing after.
    expect(total, matches(RegExp(r'^TOTAL  [\d.]+(kW|W) / [\d.]+A$')));
  });
}
