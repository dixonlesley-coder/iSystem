// Round 37 r2 — edit-fuzz-3-1, pinned at the STORE level.
//
// The live `electricalResultProvider` feeds the previous solve's phase
// assignment back as `priorAssignments` (the session-only [PhasePriorCache],
// stickiness 1.0 A). That memory is never written to `.mechx`, so the
// incomer rating and its sizing current — the issued device — must read the
// same live, after a sequence of edits, as they do after
// buildDocument -> encode -> decode -> applyDocument into a fresh container
// (no memory). The engine suite (round37_phase_history_test) covers
// computePanel seeded vs unseeded; this covers the app's actual prior feed +
// reopen path.
//
// The seeded fuzz is the regression pin: with the pre-Round-37 stickiness
// rule (a worst-phase gain had to beat the 1.0 A threshold, and no fresh
// re-solve guard) it fails at trial 1 op 6 (live sizing 19.0 A vs 18.4 A
// reopened). With ONLY the engine's fresh-solve wrapper removed it still
// passes — the in-loop rule (a lower worst phase is always taken) holds it on
// its own; the wrapper is a second guard.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

// cos phi 1 socket ways on a 400 V board: 231 W per amp on a phase.
ElectricalCircuit _way(String id, double amps) => ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.socket,
      loadW: 231 * amps,
      cosPhi: 1,
      length: const Length(20),
    );

typedef _Snap = Map<String, (double, double?, double)>;

_Snap _snap(ProviderContainer c) {
  final r = c.read(electricalResultProvider);
  return {
    for (final e in r.panels.entries)
      e.key: (
        e.value.incomer.breaker.ratingA.amperes,
        e.value.incomer.sizingCurrent?.amperes,
        math.max(e.value.phaseBalance.l1,
            math.max(e.value.phaseBalance.l2, e.value.phaseBalance.l3)),
      ),
  };
}

_Snap _reopened(ProviderContainer live) {
  final doc = ProjectDocument.decode(buildDocument(live.read).encode());
  final b = _c();
  applyDocument(b.read, doc);
  return _snap(b);
}

void _expectSame(_Snap live, _Snap reopened, String reason) {
  expect(reopened.keys.toSet(), live.keys.toSet(), reason: reason);
  for (final id in live.keys) {
    final l = live[id]!;
    final r = reopened[id]!;
    expect(r.$1, l.$1, reason: '$reason: $id incomer rating');
    expect(r.$2, closeTo(l.$2 ?? 0, 1e-9), reason: '$reason: $id sizing A');
    expect(r.$3, closeTo(l.$3, 1e-9), reason: '$reason: $id worst phase');
  }
}

void main() {
  test('a scripted 7-op sequence: incomer + sizing current identical live '
      'and after save + reopen', () {
    final live = _c();
    final ctrl = live.read(electricalProjectProvider.notifier)
      ..setProject(ElectricalProject(panels: [
        ElectricalPanel(id: 'lp', name: 'LP', circuits: [
          _way('a', 12.0),
          _way('b', 11.0),
          _way('c', 10.0),
          _way('d', 9.0),
        ]),
      ]));
    // Each op is followed by a live read so the session memory is fed back
    // exactly as the running app feeds it.
    _snap(live);
    ctrl.setCircuit('lp', 'a', loadW: 231 * 12.6); // 1
    _snap(live);
    ctrl.setCircuit('lp', 'b', loadW: 231 * 11.1); // 2
    _snap(live);
    ctrl.setCircuit('lp', 'c', loadW: 231 * 9.6); // 3
    _snap(live);
    ctrl.setCircuit('lp', 'd', loadW: 231 * 9.6); // 4
    _snap(live);
    final e = ctrl.addCircuit('lp', kind: LoadKind.socket, loadW: 231 * 0.4);
    _snap(live); // 5
    ctrl.setCircuit('lp', e, cosPhi: 1); // 6
    _snap(live);
    ctrl.setCircuit('lp', 'c', loadW: 231 * 9.2); // 7
    final after = _snap(live);
    _expectSame(after, _reopened(live), 'scripted');
  });

  test('seeded edit fuzz: after every op the live incomer equals the '
      'reopened one (no session memory)', () {
    final rng = math.Random(3701);
    for (var trial = 0; trial < 25; trial++) {
      final live = _c();
      final n = 3 + rng.nextInt(4);
      final ctrl = live.read(electricalProjectProvider.notifier)
        ..setProject(ElectricalProject(panels: [
          ElectricalPanel(id: 'lp', name: 'LP', circuits: [
            for (var i = 0; i < n; i++)
              _way('w$i', (5 + rng.nextInt(200)) / 10.0),
          ]),
        ]));
      _snap(live);
      for (var op = 0; op < 7; op++) {
        final ways =
            live.read(electricalProjectProvider).panels.single.circuits;
        final pick = ways[rng.nextInt(ways.length)];
        switch (rng.nextInt(3)) {
          case 0:
            ctrl.addCircuit('lp',
                kind: LoadKind.socket,
                loadW: 231 * (5 + rng.nextInt(200)) / 10.0);
          case 1:
            ctrl.setCircuit('lp', pick.id,
                loadW: math.max(
                    23.1, pick.loadW + 231 * (rng.nextInt(21) - 10) / 10.0));
          default:
            ctrl.setCircuit('lp', pick.id,
                loadW: 231 * (5 + rng.nextInt(200)) / 10.0);
        }
        final s = _snap(live);
        _expectSame(s, _reopened(live), 'trial $trial op $op');
      }
    }
  });

  test('the store really does feed a prior (the cache is populated)', () {
    final live = _c();
    live.read(electricalProjectProvider.notifier).setProject(
        ElectricalProject(panels: [
          ElectricalPanel(id: 'lp', name: 'LP', circuits: [
            _way('a', 10),
            _way('b', 9),
          ]),
        ]));
    _snap(live);
    final prior = live.read(phasePriorCacheProvider).prior;
    expect(prior['lp'], isNotNull);
    expect(prior['lp']!.keys, containsAll(['a', 'b']));
    expect(prior['lp']!['a'], isNot(PhaseAssignment.threePhase));
  });
}
