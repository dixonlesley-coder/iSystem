// Round 52 (2026-10-18) — node-edit intents:
//
//   plumbing-hvac-convergence-2-1  an airflow typed on an AHU / fan never
//                                  turns it into a terminal (re-rooting the
//                                  system and doubling the trunk)
//   plumbing-hvac-convergence-2-2  setNodeElevation / setNodeAirflow /
//                                  setNodeRole / setNodeCustomFixture keep the
//                                  persisted equipment tag number

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_symbols.dart' show equipmentNodeTags;
import 'package:mechx_engine/units.dart';

void main() {
  test('an airflow typed on the AHU is refused: the root, the trunk flow and '
      'the duty stay', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier)
      ..setFloors([Floor('L0', const Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    NetNode n(String id, double x, {NodeRole role = NodeRole.main,
            NodeComponent? comp, FlowRate? q}) =>
        NetNode(
            id: id,
            sheetId: 's1',
            x: x,
            y: 0,
            floorIndex: 0,
            role: role,
            component: comp,
            airflow: q);
    const sa = ServiceType.duct;
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      n('AHU1', 0, role: NodeRole.plant, comp: NodeComponent.ahu),
      n('SJ', 300),
      for (var i = 0; i < 3; i++)
        n('D$i', 600.0 + 200 * i,
            role: NodeRole.fixture,
            comp: NodeComponent.supplyDiffuser,
            q: const FlowRate(0.25)),
    ], edges: [
      const NetEdge(id: 'a', fromId: 'AHU1', toId: 'SJ', service: sa),
      for (var i = 0; i < 3; i++)
        NetEdge(id: 'd$i', fromId: 'SJ', toId: 'D$i', service: sa),
    ]));
    final before = c.read(supplyFanDutiesByRootProvider);
    expect(before.keys, ['AHU1']);
    // First principles: the AHU delivers its 3 diffusers, 3 x 0.25 m3/s.
    expect(before['AHU1']!.airflow.cubicMetersPerSecond, closeTo(0.75, 1e-9));
    c
        .read(networkControllerProvider.notifier)
        .setNodeAirflow('AHU1', const FlowRate(0.75));
    final ahu = c.read(networkControllerProvider).network.nodeById('AHU1')!;
    expect(ahu.role, NodeRole.plant);
    expect(ahu.airflow, isNull);
    final after = c.read(supplyFanDutiesByRootProvider);
    expect(after.keys, ['AHU1']);
    expect(after['AHU1']!.airflow.cubicMetersPerSecond, closeTo(0.75, 1e-9));
  });

  test('a supply diffuser still takes its airflow (and the fixture role)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctl = c.read(networkControllerProvider.notifier);
    ctl.addComponentNode('s1', 0, Offset.zero, NodeComponent.supplyDiffuser);
    final id = c.read(networkControllerProvider).network.nodes.single.id;
    ctl.setNodeAirflow(id, const FlowRate(0.2));
    final d = c.read(networkControllerProvider).network.nodeById(id)!;
    expect(d.role, NodeRole.fixture);
    expect(d.airflow!.cubicMetersPerSecond, closeTo(0.2, 1e-12));
  });

  test('stable equipment tags survive every node-edit intent', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctl = c.read(networkControllerProvider.notifier);
    for (var i = 0; i < 6; i++) {
      ctl.addFitting('s1', 0, Offset(i * 10.0, 0));
    }
    ctl.addComponentNode('s1', 0, const Offset(100, 0), NodeComponent.pump);
    ctl.addComponentNode('s1', 0, const Offset(200, 0), NodeComponent.pump);
    ctl.addComponentNode('s1', 0, const Offset(300, 0), NodeComponent.ahu);
    Network net() => c.read(networkControllerProvider).network;
    final p1 = net().nodes[6].id, p2 = net().nodes[7].id, ahu = net().nodes[8].id;
    final tags0 = equipmentNodeTags(net());
    expect(tags0[p1], 'P-01');
    expect(tags0[p2], 'P-02');
    expect(tags0[ahu], 'AHU-01');
    final tagNo0 = {for (final n in net().nodes) n.id: n.tagNo};
    expect(tagNo0[p2], 2);

    void expectStable(String what) {
      expect(equipmentNodeTags(net()), tags0, reason: what);
      for (final n in net().nodes) {
        expect(n.tagNo, tagNo0[n.id], reason: '$what ${n.id}');
      }
    }

    ctl.setNodeElevation(p2, const Length(-3));
    expectStable('setNodeElevation');
    ctl.setNodeElevation(p2, null);
    expectStable('setNodeElevation(null)');
    ctl.setNodeAirflow(ahu, const FlowRate(1.5)); // refused on an AHU
    expectStable('setNodeAirflow(AHU)');
    ctl.setNodeAirflow(p1, const FlowRate(0.1));
    expectStable('setNodeAirflow(pump)');
    ctl.setNodeAirflow(p1, null);
    expectStable('setNodeAirflow(null)');
    ctl.setNodeRole(p2, NodeRole.main);
    ctl.setNodeRole(p2, NodeRole.plant);
    expectStable('setNodeRole plant -> main -> plant');
    ctl.setNodeCustomFixture(p1, 'cf-1');
    expect(net().nodeById(p1)!.customFixtureId, 'cf-1');
    ctl.setNodeCustomFixture(p1, null);
    expectStable('setNodeCustomFixture');
  });

  test('setNodeRole keeps the roof area; leaving a terminal clears its '
      'custom fixture', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(networkControllerProvider.notifier).loadNetwork(const Network(
          nodes: [
            NetNode(
              id: 'RD',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: 0,
              role: NodeRole.fixture,
              customFixtureId: 'cf',
              roofAreaM2: 120,
            ),
          ],
          edges: [],
        ));
    final ctl = c.read(networkControllerProvider.notifier);
    ctl.setNodeRole('RD', NodeRole.main);
    final n = c.read(networkControllerProvider).network.nodeById('RD')!;
    expect(n.roofAreaM2, 120);
    expect(n.customFixtureId, isNull);
  });
}
