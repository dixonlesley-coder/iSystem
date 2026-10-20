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
    // Sample-project fixture values (Menara Contoh MDP).
    //
    // Re-derived 2026-10-18 (Round 37, electrical-sim-4-feeder-balanced-
    // phase-hides-fed-board-imbalance): each 3φ feeder now loads the MDP with
    // its fed board's OWN line currents instead of a balanced Ib on each line.
    //   PP-1: AC 13.2 A on L2, L3, L2 (1φ), water heater 22.4 A on L1, the
    //         3φ booster 1.0 A + AHU fan 0.7 A on every line
    //         => L1 22.4 + 1.7 = 24.1, L2 26.4 + 1.7 = 28.1, L3 13.2 + 1.7
    //            = 14.9 A
    //   EMG:  fire pump 103.8 A (3φ) + emergency lighting 5.1 A on L1
    //         => 108.9 / 103.8 / 103.8 A
    //   Lift 21.2 A + General power 13.6 A (3φ) on every line.
    // Before LP-1: L1 24.1 + 108.9 + 34.8 = 167.8, L2 28.1 + 103.8 + 34.8 =
    // 166.7, L3 14.9 + 103.8 + 34.8 = 153.5 A; the 1φ LP-1 feeder (59.1 A)
    // goes to the least-loaded L3 => R 167.8 / S 166.7 / T 212.6 A.
    expect(l1, closeTo(167.8, 0.05));
    expect(l2, closeTo(166.7, 0.05));
    expect(l3, closeTo(212.6, 0.05));

    // Hand derivation of the imbalance the engine must have computed:
    //   avg   = (167.8 + 166.7 + 212.6) / 3 = 547.1 / 3 = 182.37 A
    //   imbal = (212.6 - 166.7) / 182.37 * 100 = 45.9 / 182.37 * 100
    //         = 25.17...%  -> 25.2% (the engine's own `roundTo(_, 1)`)
    final avg = (l1 + l2 + l3) / 3;
    final handImbalance = (l3 - l2) / avg * 100; // max=l3, min=l2
    expect(handImbalance, closeTo(25.2, 0.05));
    expect(mdp.imbalancePercent, closeTo(25.2, 0.05));

    final sheet = buildElectricalPanelDetail(
        project: project, result: result, panelId: 'MDP');
    final total = sheetLabels(sheet).firstWhere((t) => t.startsWith('TOTAL'));
    expect(total, contains('imbalance 25.2%'),
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
