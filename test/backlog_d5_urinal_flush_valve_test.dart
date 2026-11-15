// Backlog D-5 (2026-11-13) — the flush-valve urinal is counted as a
// flush-valve node: its supply system takes the valve branch of the demand
// curve and the 98.067 kPa SNI floor applies on its path.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

void main() {
  ProviderContainer load(PlumbingFixture fixture) {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier)
      ..setFloors([const Floor('L1', Length(4.0))])
      ..setCalibration('s0', const ScaleCalibration(0.02));
    c.read(networkControllerProvider.notifier).loadNetwork(Network(
      nodes: [
        const NetNode(
            id: 'RT',
            sheetId: 's0',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.plant,
            component: NodeComponent.roofTank),
        const NetNode(id: 'J', sheetId: 's0', x: 100, y: 0, floorIndex: 0),
        NetNode(
            id: 'UR',
            sheetId: 's0',
            x: 200,
            y: 0,
            floorIndex: 0,
            role: NodeRole.fixture,
            fixture: fixture),
      ],
      edges: const [
        NetEdge(id: 'a', fromId: 'RT', toId: 'J', service: ServiceType.coldWater),
        NetEdge(id: 'b', fromId: 'J', toId: 'UR', service: ServiceType.coldWater),
      ],
    ));
    return c;
  }

  test('a flush-valve urinal is a flush-valve node: valve curve, 98 kPa', () {
    final c = load(PlumbingFixture.urinalFlushValve);
    expect(c.read(supplyFlushValveNodeIdsProvider), {'UR'});
    // 5 UBAP (private) on the valve branch: 5 x 0.88333 / 10 = 0.44167 L/s.
    expect(c.read(sizingProvider)['b']!.flow.inLitersPerSecond,
        closeTo(0.441665, 1e-6));
    final floors = sniMinimumResidualByNode(
      net: c.read(sizingNetworkProvider),
      sourceId: 'RT',
      nodeIds: const ['UR'],
      flushValveNodeIds: c.read(supplyFlushValveNodeIdsProvider),
    );
    expect(floors['UR']!.inKiloPascals, closeTo(98.067, 1e-3));
  });

  test('the flush-TANK urinal stays a faucet node: tank curve, 49 kPa', () {
    final c = load(PlumbingFixture.urinalFlushTank);
    expect(c.read(supplyFlushValveNodeIdsProvider), isEmpty);
    // 2 UBAP below 10 on the tank branch: 2 x 0.05 = 0.1 L/s.
    expect(c.read(sizingProvider)['b']!.flow.inLitersPerSecond,
        closeTo(0.1, 1e-9));
    final floors = sniMinimumResidualByNode(
      net: c.read(sizingNetworkProvider),
      sourceId: 'RT',
      nodeIds: const ['UR'],
      flushValveNodeIds: c.read(supplyFlushValveNodeIdsProvider),
    );
    expect(floors['UR']!.inKiloPascals, closeTo(49.033, 1e-3));
  });
}
