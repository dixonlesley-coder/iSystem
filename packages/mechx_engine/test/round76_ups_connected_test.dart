// Round 76 (2026-10-18) — elec-convergence-27-ups-connected-below-demand.
//
// A UPS-backed board is supplied THROUGH its UPS (Round 44): its feeder and
// everything upstream carry the UPS INPUT = output x kUpsInputFactor
// (1.10 recharge / 0.94 efficiency = 1.17021...). The demand sum applied it;
// the supply 'connected load' and the report's per-board sub-tree 'connected'
// figure did not, so a project with a UPS board printed a connected load
// BELOW its diversified demand (impossible when every factor is <= 1).
//
// First principles (the probe): MDP -> UPS board of 4 x 5000 W sockets, every
// demand / diversity factor 1. Output 20 000 W; UPS input
// 20 000 x 1.10 / 0.94 = 23 404.26 W. Demand = connected = 23 404 W.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _probe({bool ups = true}) => ElectricalProject(
      id: 'u',
      name: 'Data room',
      earthingSystem: EarthingSystem.tnS,
      panels: [
        const ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'fu',
                  name: 'UPS feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(20),
                  feedsPanelId: 'UPS'),
            ]),
        ElectricalPanel(
            id: 'UPS',
            name: 'UPS',
            upsBacked: ups,
            voltage: const Voltage(400),
            circuits: [
              for (var k = 0; k < 4; k++)
                ElectricalCircuit(
                    id: 'r$k',
                    name: 'Rack $k',
                    loadKind: LoadKind.socket,
                    loadW: 5000,
                    phases: 1,
                    length: const Length(10)),
            ]),
      ],
    );

/// A random 2-3 level tree: MDP -> 1..3 sub-boards (each randomly UPS-backed)
/// -> optionally a nested board (randomly UPS-backed). Leaf ways are
/// socket / lighting with demand factor and board diversity in [0.5, 1].
ElectricalProject _randomTree(math.Random rnd, {required bool allowUps}) {
  final panels = <ElectricalPanel>[];
  var seq = 0;
  List<ElectricalCircuit> leaves(String prefix) => [
        for (var k = 0, n = 1 + rnd.nextInt(4); k < n; k++)
          ElectricalCircuit(
            id: '$prefix-w${seq++}',
            name: 'Way $k',
            loadKind: rnd.nextBool() ? LoadKind.socket : LoadKind.lighting,
            loadW: (500 + rnd.nextInt(4500)).toDouble(),
            demandFactor: 0.5 + rnd.nextDouble() * 0.5,
            phases: 1,
            length: const Length(15),
          ),
      ];
  final rootWays = <ElectricalCircuit>[...leaves('MDP')];
  for (var i = 0, n = 1 + rnd.nextInt(3); i < n; i++) {
    final id = 'SB$i';
    rootWays.add(ElectricalCircuit(
        id: 'f-$id',
        name: 'Feeder $id',
        loadKind: LoadKind.feeder,
        length: const Length(25),
        feedsPanelId: id));
    final ways = <ElectricalCircuit>[...leaves(id)];
    if (rnd.nextBool()) {
      final nid = '$id-N';
      ways.add(ElectricalCircuit(
          id: 'f-$nid',
          name: 'Feeder $nid',
          loadKind: LoadKind.feeder,
          length: const Length(15),
          feedsPanelId: nid));
      panels.add(ElectricalPanel(
          id: nid,
          name: nid,
          upsBacked: allowUps && rnd.nextBool(),
          diversityFactor: 0.5 + rnd.nextDouble() * 0.5,
          voltage: const Voltage(400),
          circuits: leaves(nid)));
    }
    panels.add(ElectricalPanel(
        id: id,
        name: id,
        upsBacked: allowUps && rnd.nextBool(),
        diversityFactor: 0.5 + rnd.nextDouble() * 0.5,
        voltage: const Voltage(400),
        circuits: ways));
  }
  panels.add(ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      diversityFactor: 0.5 + rnd.nextDouble() * 0.5,
      voltage: const Voltage(400),
      circuits: rootWays));
  return ElectricalProject(
      id: 'p',
      name: 'Random',
      earthingSystem: EarthingSystem.tnS,
      panels: panels);
}

String _report(ElectricalProject pr, ElectricalSystemResult sys) =>
    buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'P',
      date: '2026-10-18',
      standardsName: 'PUIL',
      standardsRevision: '2011',
      project: pr,
      result: sys,
    ));

void main() {
  test('the UPS probe: connected load carries the UPS input', () {
    final sys = computeSystem(_profile, _probe());
    const expected = 20000 * 1.10 / 0.94; // 23 404.26 W
    expect(sys.supply.connectedW, closeTo(expected, 0.5));
    expect(sys.supply.connectedW,
        greaterThanOrEqualTo(sys.supply.demandW - 0.5));
    final md = _report(_probe(), sys);
    expect(md, contains('(incl. UPS input losses)'));
    // The MDP board line's sub-tree connected figure == the supply total.
    expect(md, contains('connected ${expected.toStringAsFixed(1)} W'));
  });

  test('no UPS: the connected load is the plain leaf sum (unchanged)', () {
    final sys = computeSystem(_profile, _probe(ups: false));
    expect(sys.supply.connectedW, 20000);
    expect(_report(_probe(ups: false), sys),
        isNot(contains('UPS input losses')));
  });

  test('seeded: connected >= diversified demand; UPS-free == leaf sum', () {
    var upsTrials = 0;
    for (var seed = 0; seed < 300; seed++) {
      final rnd = math.Random(seed);
      final allowUps = seed.isEven;
      final pr = _randomTree(rnd, allowUps: allowUps);
      final sys = computeSystem(_profile, pr);
      expect(sys.supply.connectedW,
          greaterThanOrEqualTo(sys.supply.demandW - 1.0),
          reason: 'seed $seed');
      final anyUps = pr.panels.any((p) => p.upsBacked);
      if (anyUps) upsTrials++;
      if (!anyUps) {
        var leaf = 0.0;
        for (final p in pr.panels) {
          for (final c in p.circuits) {
            if (c.feedsPanelId == null) leaf += circuitUndiversifiedW(c);
          }
        }
        expect(sys.supply.connectedW, closeTo(leaf, 1.0),
            reason: 'seed $seed');
      }
    }
    expect(upsTrials, greaterThan(50)); // non-vacuous
  });
}
