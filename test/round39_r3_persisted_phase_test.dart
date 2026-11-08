// Round 39 r3 (2026-10-20) — the DOCUMENT fully determines the phase balance.
//
// Root cause of the round-37..39 live-vs-reopen divergences: the solved phase
// assignment lived only in session memory (the phase-stability prior), so a
// live project and the same project reopened from `.mechx` balanced from
// different priors. Since r3 every forward store mutation persists each
// single-phase way's solved line (`ElectricalCircuit.assignedPhase`) and the
// engine reads it back as the prior — so `buildDocument -> applyDocument`
// reproduces the live result exactly, for every board's L1/L2/L3, incomer,
// feeder rows and the genset per-phase basis.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

// A cos phi 1 single-phase way of 231·A W draws A on a 400 V board.
ElectricalCircuit _amps(String id, double a, {PhaseLine? pin}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.heating,
      loadW: 231 * a,
      cosPhi: 1,
      phases: 1,
      phaseOverride: pin,
      length: const Length(10),
    );

ElectricalCircuit _feeder(String id, String fed) => ElectricalCircuit(
      id: id,
      name: 'to $fed',
      loadKind: LoadKind.feeder,
      feedsPanelId: fed,
      length: const Length(10),
    );

/// Everything the issued set prints off the phase balance.
typedef _Snap = ({
  Map<String, List<double>> lines,
  Map<String, double> incomer,
  Map<String, List<double>?> feederRows,
  Map<String, String> phases,
  double gensetVa,
});

_Snap _snap(ProviderContainer c) {
  final r = c.read(electricalResultProvider);
  final p = c.read(electricalProjectProvider);
  return (
    lines: {
      for (final e in r.panels.entries)
        e.key: [
          e.value.phaseBalance.l1,
          e.value.phaseBalance.l2,
          e.value.phaseBalance.l3,
        ],
    },
    incomer: {
      for (final e in r.panels.entries)
        e.key: e.value.incomer.breaker.ratingA.amperes,
    },
    feederRows: {
      for (final e in r.panels.entries)
        for (final w in e.value.circuits)
          if (w.loadKind == LoadKind.feeder)
            '${e.key}/${w.circuitId}': w.lineCurrentsA,
    },
    phases: {
      for (final e in r.panels.entries)
        for (final w in e.value.circuits)
          '${e.key}/${w.circuitId}': w.phase.name,
    },
    gensetVa: gensetBackupDemandVa(p, r).voltAmperes,
  );
}

_Snap _reopened(ProviderContainer live) {
  final doc = ProjectDocument.decode(buildDocument(live.read).encode());
  final b = _c();
  applyDocument(b.read, doc);
  return _snap(b);
}

void _expectSame(_Snap live, _Snap re, String why) {
  expect(re.lines.keys.toSet(), live.lines.keys.toSet(), reason: why);
  for (final id in live.lines.keys) {
    for (var k = 0; k < 3; k++) {
      expect(re.lines[id]![k], live.lines[id]![k], reason: '$why $id L${k + 1}');
    }
    expect(re.incomer[id], live.incomer[id], reason: '$why $id incomer');
  }
  expect(re.feederRows.keys.toSet(), live.feederRows.keys.toSet(), reason: why);
  for (final k in live.feederRows.keys) {
    final a = live.feederRows[k], b = re.feederRows[k];
    expect(b == null, a == null, reason: '$why $k row');
    if (a != null) {
      for (var i = 0; i < a.length; i++) {
        expect(b![i], a[i], reason: '$why $k row[$i]');
      }
    }
  }
  expect(re.phases, live.phases, reason: '$why phases');
  expect(re.gensetVa, live.gensetVa, reason: '$why genset');
}

Map<String, String> _freshPhases(ProviderContainer c) {
  final p = c.read(electricalProjectProvider);
  final stripped = p.withPanels([
    for (final b in p.panels)
      b.copyWith(circuits: [
        for (final w in b.circuits) w.copyWith(clearAssignedPhase: true),
      ]),
  ]);
  final r = solveElectricalLive(stripped, c.read(projectControllerProvider));
  return {
    for (final e in r.panels.entries)
      for (final w in e.value.circuits) '${e.key}/${w.circuitId}': w.phase.name,
  };
}

bool _sameMap(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.keys.every((k) => a[k] == b[k]);

void main() {
  test('the reviewer\'s two-fed-board shape: a parent of two boards reads '
      'the same R/S/T live and after reopen, through a sequence of edits', () {
    // MDP feeds A and B (each 30 / 20 / 10 A 1ph) and carries a 1ph way of
    // its own. Editing B's loads so its labels stick in a rotated order used
    // to give the MDP 40 / 50 / 30 A live (a 50 A incomer) and 60 A after
    // reopen (63 A) on the same document.
    final live = _c();
    final ctrl = live.read(electricalProjectProvider.notifier)
      ..setProject(ElectricalProject(
        sources: const ElectricalSources(
            generator: GeneratorSource(backupFraction: 1.0)),
        panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            _feeder('fA', 'A'),
            _feeder('fB', 'B'),
            _amps('m', 7),
          ]),
          ElectricalPanel(
              id: 'A',
              name: 'A',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'fA',
              circuits: [_amps('a30', 30), _amps('a20', 20), _amps('a10', 10)]),
          ElectricalPanel(
              id: 'B',
              name: 'B',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'fB',
              circuits: [_amps('b30', 30), _amps('b20', 20), _amps('b10', 10)]),
        ],
      ));
    _snap(live);
    // Re-rank B's ways one by one (each edit is sticky within 1 A).
    ctrl.setCircuit('B', 'b10', loadW: 231 * 30.5);
    _snap(live);
    ctrl.setCircuit('B', 'b30', loadW: 231 * 10.4);
    _snap(live);
    ctrl.setCircuit('B', 'b20', loadW: 231 * 20.2);
    final s = _snap(live);
    _expectSame(s, _reopened(live), 'reviewer shape');
    // Non-vacuous: B kept history-shaped labels a fresh solve would not.
    expect(_sameMap(_freshPhases(live), s.phases), isFalse);
    // The parent reads the board's PRINTED lines (one labelled assignment).
    final r = live.read(electricalResultProvider);
    final row = r.panels['MDP']!.circuits
        .firstWhere((w) => w.circuitId == 'fB')
        .lineCurrentsA;
    final b = r.panels['B']!.phaseBalance;
    if (row != null) {
      expect(row, [b.l1, b.l2, b.l3].map((x) => closeTo(x, 1e-9)).toList());
    }
    // …and the persisted assignment IS what B prints.
    for (final w in live
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == 'B')
        .circuits) {
      final solved =
          r.panels['B']!.circuits.firstWhere((x) => x.circuitId == w.id);
      expect(w.assignedPhase?.name, solved.phase.name, reason: w.id);
    }
  });

  test('a load-then-no-edit document stays verbatim (no phantom stamp)', () {
    final c = _c();
    final project = ElectricalProject(panels: [
      ElectricalPanel(
          id: 'lp', name: 'LP', circuits: [_amps('a', 10), _amps('b', 9)]),
    ]);
    c.read(electricalProjectProvider.notifier).setProject(project);
    _snap(c);
    expect(identical(c.read(electricalProjectProvider), project), isTrue);
  });

  test('seeded property (300 trials): random multi-level trees edited in '
      'sequence through the store == buildDocument -> applyDocument reopen',
      () {
    final rng = math.Random(39303);
    var historyMattered = 0;
    double amps() => (5 + rng.nextInt(300)) / 10.0; // 0.5 .. 30.4 A
    for (var trial = 0; trial < 300; trial++) {
      // MDP (3ph) with 1..3 own 1ph ways and 2..3 feeders; each child board
      // has 2..5 1ph ways, sometimes a 3ph way, sometimes its own sub-board.
      final panels = <ElectricalPanel>[];
      final mdpWays = <ElectricalCircuit>[
        for (var i = 0; i < 1 + rng.nextInt(3); i++) _amps('m$i', amps()),
      ];
      final kids = 2 + rng.nextInt(2);
      for (var k = 0; k < kids; k++) {
        final id = 'D$k';
        mdpWays.add(_feeder('f$k', id));
        final ways = <ElectricalCircuit>[
          for (var i = 0; i < 2 + rng.nextInt(4); i++)
            _amps('${id}w$i', amps(),
                pin: rng.nextDouble() < 0.08
                    ? PhaseLine.values[rng.nextInt(3)]
                    : null),
          if (rng.nextDouble() < 0.3)
            ElectricalCircuit(
                id: '${id}m3',
                name: '${id}m3',
                loadKind: LoadKind.heating,
                loadW: 400 * 1.732 * (1 + rng.nextInt(15)),
                cosPhi: 1,
                phases: 3,
                length: const Length(10)),
        ];
        if (rng.nextDouble() < 0.35) {
          final g = '${id}S';
          ways.add(_feeder('${id}fs', g));
          panels.add(ElectricalPanel(
              id: g,
              name: g,
              sourceType: PanelSource.feeder,
              fedByCircuitId: '${id}fs',
              circuits: [
                for (var i = 0; i < 2 + rng.nextInt(3); i++)
                  _amps('${g}w$i', amps()),
              ]));
        }
        panels.add(ElectricalPanel(
            id: id,
            name: id,
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f$k',
            circuits: ways));
      }
      panels.insert(
          0, ElectricalPanel(id: 'MDP', name: 'MDP', circuits: mdpWays));
      final live = _c();
      final ctrl = live.read(electricalProjectProvider.notifier)
        ..setProject(ElectricalProject(
          sources: const ElectricalSources(
              generator: GeneratorSource(backupFraction: 1.0)),
          panels: panels,
        ));
      _snap(live);
      final ops = 2 + rng.nextInt(5);
      for (var op = 0; op < ops; op++) {
        final project = live.read(electricalProjectProvider);
        final board = project.panels[rng.nextInt(project.panels.length)];
        final singles = board.circuits
            .where((w) => w.feedsPanelId == null && w.phases == 1)
            .toList();
        final choice = rng.nextInt(4);
        if (choice == 0 || singles.isEmpty) {
          ctrl.addCircuit(board.id,
              kind: LoadKind.heating, phases: 1, loadW: 231 * amps());
        } else {
          final w = singles[rng.nextInt(singles.length)];
          if (choice == 1) {
            // A small nudge: the sticky labels survive it.
            ctrl.setCircuit(board.id, w.id,
                loadW: math.max(23.1,
                    w.loadW + 231 * (rng.nextInt(21) - 10) / 10.0));
          } else if (choice == 2) {
            ctrl.setCircuit(board.id, w.id, loadW: 231 * amps());
          } else if (singles.length > 1) {
            ctrl.deleteCircuit(board.id, w.id);
          }
        }
        _snap(live);
      }
      final s = _snap(live);
      _expectSame(s, _reopened(live), 'trial $trial');
      // Non-vacuity: the editing history DID shape the labels (a solve of
      // the same loads with no persisted assignment differs) — so the
      // equality above is carried by the persisted field, not by luck.
      if (!_sameMap(_freshPhases(live), s.phases)) historyMattered++;
    }
    expect(historyMattered, greaterThan(20));
  });
}
