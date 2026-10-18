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
import '../tool/generate_export_samples.dart' show buildSampleElectrical;

void main() {
  const profile = PuilProfile();

  List<String> sheetLabels(SldSheet sheet) => [
        for (final p in sheet.prims)
          if (p is SldLabel) p.text
      ];

  test(
      '3-phase board — TOTAL footer prints "imbalance N%" matching a hand '
      'derivation from the printed R/S/T amps', () {
    final project = buildSampleElectrical();
    final result = computeSystem(profile, project);
    final mdp = result.panels['MDP']!;

    // The board's own per-line currents (already asserted against by other
    // compute tests) — read off the SAME result the drawing renders from.
    expect(mdp.system.isThreePhase, isTrue);
    final l1 = mdp.phaseBalance.l1;
    final l2 = mdp.phaseBalance.l2;
    final l3 = mdp.phaseBalance.l3;
    // Sample-project fixture values (Menara Contoh MDP): R=221.9A S=162.8A
    // T=162.8A.
    //
    // Re-derived 2026-10-18 (Round 12, printed-parity-5): the harness now
    // feeds the EMG fire-pump way from the NFPA 20 SELECTED motor exactly as
    // the app's electrical feed does (55 kW frame — the overload shaft power
    // 49.36 kW governs — not the 43.0 kW rated-point shaft), and the AHU
    // duty carries its 250 Pa internal static. MDP's ways, at 400 V 3φ,
    // cosφ 0.85 (√3 × 400 × 0.85 = 588.9 V·):
    //   Feeder to PP-1   3·2600 + 4400 + max(537.6, 550/0.9 = 611.1) (booster)
    //                    + max(179.1, 370/0.9 = 411.1) (AHU fan, 291 Pa)
    //                    = 13 222.2 W / 588.9 = 22.5 A  (3φ)
    //   Feeder to EMG    fire-pump motor 55 000 W ÷ η 0.90 = 61 111.1 W
    //                    + 1 000 W em. lighting = 62 111.1 W / 588.9 = 105.5 A
    //   Lift motor       11 kW ÷ 0.88 = 12 500 W / 588.9 = 21.2 A  (3φ)
    //   General power    8 000 W / 588.9 = 13.6 A  (3φ)
    //   Feeder to LP-1   11 050 W / (220 × 0.85) = 59.1 A  (1φ, line R)
    // S = T = 22.5 + 105.5 + 21.2 + 13.6 = 162.8 A; R = 162.8 + 59.1 = 221.9 A.
    expect(l1, closeTo(221.9, 0.05));
    expect(l2, closeTo(162.8, 0.05));
    expect(l3, closeTo(162.8, 0.05));

    // Hand derivation of the imbalance the engine must have computed:
    //   avg   = (221.9 + 162.8 + 162.8) / 3     = 547.5 / 3   = 182.5 A
    //   imbal = (max - min) / avg * 100         = (221.9 - 162.8) / 182.5 * 100
    //         = 59.1 / 182.5 * 100              = 32.38...%
    //   rounded to 1 dp (the engine's own `roundTo(_, 1)`)   -> 32.4%
    final avg = (l1 + l2 + l3) / 3;
    final handImbalance = (l1 - l3) / avg * 100; // max=l1, min=l3(==l2)
    expect(handImbalance, closeTo(32.4, 0.05));
    expect(mdp.imbalancePercent, closeTo(32.4, 0.05));

    final sheet = buildElectricalPanelDetail(
        project: project, result: result, panelId: 'MDP');
    final total = sheetLabels(sheet).firstWhere((t) => t.startsWith('TOTAL'));
    expect(total, contains('imbalance 32.4%'),
        reason: 'the printed TOTAL footer must carry the same imbalance % '
            'the engine computed, not a re-derived or rounded-differently one');
  });

  test(
      'single-phase board — TOTAL footer carries NO imbalance token '
      '(byte-identical to the pre-H7 footer)', () {
    final project = buildSampleElectrical();
    final result = computeSystem(profile, project);
    final lp1 = result.panels['LP1']!;
    expect(lp1.system.isThreePhase, isFalse);

    final sheet = buildElectricalPanelDetail(
        project: project, result: result, panelId: 'LP1');
    final total = sheetLabels(sheet).firstWhere((t) => t.startsWith('TOTAL'));
    expect(total, isNot(contains('imbalance')));
    // Exact pre-H7 shape: 'TOTAL  <kW|W> / <A>A' and nothing after.
    expect(total, matches(RegExp(r'^TOTAL  [\d.]+(kW|W) / [\d.]+A$')));
  });
}
