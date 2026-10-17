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

  List<String> sheetLabels(SldSheet sheet) =>
      [for (final p in sheet.prims) if (p is SldLabel) p.text];

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
    // Sample-project fixture values (Menara Contoh MDP): R=198.3A S=139.2A
    // T=139.2A.
    //
    // Re-derived 2026-10-17 (R3 reports-7): the harness fixture's motor ways
    // are no longer hand-typed — the booster pump + AHU fan (on PP-1) and the
    // fire pump (on EMG) are projected from the SOLVED duties via
    // `buildEquipmentCircuits`. MDP's ways, at 400 V 3φ, cosφ 0.85
    // (√3 × 400 × 0.85 = 588.9 V·):
    //   Feeder to PP-1   13 120 W / 588.9 = 22.3 A  (3φ)
    //   Feeder to EMG    48 334 W / 588.9 = 82.1 A  (3φ; EMG = the standpipe
    //                    fire pump's 47.33 kW shaft ÷ η 0.90 + 1 kW em. light)
    //   Lift motor       11 kW ÷ 0.88 / 588.9 = 21.2 A  (3φ)
    //   General power    8 000 W / 588.9 = 13.6 A  (3φ)
    //   Feeder to LP-1   11 050 W / (220 × 0.85) = 59.1 A  (1φ, line R)
    // S = T = 22.3 + 82.1 + 21.2 + 13.6 = 139.2 A; R = 139.2 + 59.1 = 198.3 A.
    expect(l1, closeTo(198.3, 0.05));
    expect(l2, closeTo(139.2, 0.05));
    expect(l3, closeTo(139.2, 0.05));

    // Hand derivation of the imbalance the engine must have computed:
    //   avg   = (198.3 + 139.2 + 139.2) / 3     = 476.7 / 3   = 158.9 A
    //   imbal = (max - min) / avg * 100         = (198.3 - 139.2) / 158.9 * 100
    //         = 59.1 / 158.9 * 100              = 37.193...%
    //   rounded to 1 dp (the engine's own `roundTo(_, 1)`)   -> 37.2%
    final avg = (l1 + l2 + l3) / 3;
    final handImbalance = (l1 - l3) / avg * 100; // max=l1, min=l3(==l2)
    expect(handImbalance, closeTo(37.2, 0.05));
    expect(mdp.imbalancePercent, closeTo(37.2, 0.05));

    final sheet =
        buildElectricalPanelDetail(project: project, result: result, panelId: 'MDP');
    final total = sheetLabels(sheet).firstWhere((t) => t.startsWith('TOTAL'));
    expect(total, contains('imbalance 37.2%'),
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

    final sheet =
        buildElectricalPanelDetail(project: project, result: result, panelId: 'LP1');
    final total = sheetLabels(sheet).firstWhere((t) => t.startsWith('TOTAL'));
    expect(total, isNot(contains('imbalance')));
    // Exact pre-H7 shape: 'TOTAL  <kW|W> / <A>A' and nothing after.
    expect(total, matches(RegExp(r'^TOTAL  [\d.]+(kW|W) / [\d.]+A$')));
  });
}
