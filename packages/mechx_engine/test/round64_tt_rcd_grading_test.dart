// Round 64 (elec-convergence-16-tt-feeder-rcd-not-graded-over-empty-sub-
// board-feeder) — a TT feeder RCD is graded over the IΔn ACTUALLY issued
// below it, an empty (future) board's feeder included.
//
// First principles (IEC 60364-5-53 536.4.1.4, the >= 3 x IΔn rule the TT
// ladder 300 / 1000 / 3000 / 10000 mA encodes): R -f4-> P2 (30 mA socket
// finals) -f2-> P3 (no ways). The P2-f2 feeder still carries the level-ladder
// 300 mA S device (nothing tripping below it), so the feeder above P2 must be
// >= 3 x 300 = 900 -> the 1000 mA rung, never a second 300 mA S device.
// Seeded property: every TT feeder RCD is >= 3 x the largest tripping RCD
// reachable below it (through ways carrying no RCD), or the feeder raises
// `tt-rcd-not-selective`.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalCircuit _feeder(String id, String to) => ElectricalCircuit(
    id: id,
    name: 'Feeder $to',
    loadKind: LoadKind.feeder,
    feedsPanelId: to,
    length: const Length(20));

ElectricalCircuit _final(String id, LoadKind k,
        {bool life = false, double w = 1500}) =>
    ElectricalCircuit(
        id: id,
        name: '$k $id',
        loadKind: k,
        loadW: w,
        lifeSafety: life,
        length: const Length(15));

ElectricalPanel _board(String id, List<ElectricalCircuit> cs) =>
    ElectricalPanel(
        id: id,
        name: id,
        system: ElectricalSystem.threePhase,
        voltage: const Voltage(400),
        circuits: cs);

/// The largest tripping-RCD IΔn reachable below board [pid] through ways
/// carrying no RCD of their own.
int _belowMa(ElectricalProject p, ElectricalSystemResult sys, String pid) {
  final model = p.panels.firstWhere((x) => x.id == pid);
  final res = sys.panels[pid]!;
  var best = 0;
  for (final c in res.circuits) {
    final m = model.circuits.firstWhere((x) => x.id == c.circuitId);
    if (c.rcd.required) {
      best = math.max(best, c.rcd.ratingMa);
    } else if (m.feedsPanelId != null) {
      best = math.max(best, _belowMa(p, sys, m.feedsPanelId!));
    }
  }
  return best;
}

void _checkGrading(ElectricalProject p, String why) {
  final sys = computeSystem(_profile, p);
  for (final panel in p.panels) {
    final res = sys.panels[panel.id];
    if (res == null) continue;
    for (final c in res.circuits) {
      final m = panel.circuits.firstWhere((x) => x.id == c.circuitId);
      if (m.feedsPanelId == null || !c.rcd.required) continue;
      final below = _belowMa(p, sys, m.feedsPanelId!);
      if (below == 0) continue;
      final warned = sys.warnings.any((w) =>
          w.code == 'tt-rcd-not-selective' && w.circuitId == c.circuitId);
      expect(c.rcd.ratingMa >= 3 * below || warned, isTrue,
          reason: '$why: ${panel.id}/${c.circuitId} ${c.rcd.ratingMa} mA '
              'over $below mA below');
    }
  }
}

void main() {
  test('a feeder over an empty board feeder steps to 1000 mA', () {
    final p = ElectricalProject(
      id: 'p',
      name: 'TT',
      earthingSystem: EarthingSystem.tt,
      panels: [
        _board('R', [_feeder('f4', 'P2')]),
        _board('P2', [
          _final('s1', LoadKind.socket),
          _final('s2', LoadKind.socket),
          _feeder('f2', 'P3'),
        ]),
        _board('P3', const []),
      ],
    );
    final sys = computeSystem(_profile, p);
    final f2 =
        sys.panels['P2']!.circuits.firstWhere((c) => c.circuitId == 'f2');
    final f4 = sys.panels['R']!.circuits.firstWhere((c) => c.circuitId == 'f4');
    expect(f2.rcd.required, isTrue);
    expect(f2.rcd.ratingMa, ttFeederRcdMa(0)); // 300 mA S
    expect(f2.rcd.timeDelayed, isTrue);
    expect(f4.rcd.ratingMa, 1000);
    expect(f4.rcd.ratingMa, greaterThanOrEqualTo(3 * f2.rcd.ratingMa));
    _checkGrading(p, 'fixed');
  });

  test('seeded: every TT feeder RCD grades over what is issued below it', () {
    final rnd = math.Random(1675);
    const kinds = [
      LoadKind.socket,
      LoadKind.lighting,
      LoadKind.motor,
      LoadKind.heating,
    ];
    for (var trial = 0; trial < 150; trial++) {
      final n = 2 + rnd.nextInt(5);
      final circuits = List.generate(n, (_) => <ElectricalCircuit>[]);
      for (var b = 1; b < n; b++) {
        final parent = rnd.nextInt(b);
        circuits[parent].add(_feeder('f$b', 'B$b'));
      }
      for (var b = 0; b < n; b++) {
        final ways = rnd.nextInt(3); // 0 => an empty (future) board
        for (var w = 0; w < ways; w++) {
          circuits[b].add(_final('c${b}_$w', kinds[rnd.nextInt(kinds.length)],
              life: rnd.nextInt(8) == 0));
        }
      }
      final p = ElectricalProject(
        id: 'p',
        name: 'TT',
        earthingSystem: EarthingSystem.tt,
        panels: [for (var b = 0; b < n; b++) _board('B$b', circuits[b])],
      );
      _checkGrading(p, 'trial $trial');
    }
  });
}
