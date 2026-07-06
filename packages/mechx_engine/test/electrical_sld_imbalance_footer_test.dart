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
    // Sample-project fixture values (Menara Contoh MDP): R=131.6A S=75.3A
    // T=75.3A.
    expect(l1, closeTo(131.6, 0.05));
    expect(l2, closeTo(75.3, 0.05));
    expect(l3, closeTo(75.3, 0.05));

    // Hand derivation of the imbalance the engine must have computed:
    //   avg   = (131.6 + 75.3 + 75.3) / 3       = 282.2 / 3   = 94.0667 A
    //   imbal = (max - min) / avg * 100         = (131.6 - 75.3) / 94.0667 * 100
    //         = 56.3 / 94.0667 * 100            = 59.8656...%
    //   rounded to 1 dp (the engine's own `roundTo(_, 1)`)   -> 59.9%
    final avg = (l1 + l2 + l3) / 3;
    final handImbalance = (l1 - l3) / avg * 100; // max=l1, min=l3(==l2)
    expect(handImbalance, closeTo(59.9, 0.05));
    expect(mdp.imbalancePercent, closeTo(59.9, 0.05));

    final sheet =
        buildElectricalPanelDetail(project: project, result: result, panelId: 'MDP');
    final total = sheetLabels(sheet).firstWhere((t) => t.startsWith('TOTAL'));
    expect(total, contains('imbalance 59.9%'),
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
