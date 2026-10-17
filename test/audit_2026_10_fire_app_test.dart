// Audit 2026-10, group C1-fire — app-side wiring of fire-2 / fire-5 / fire-6.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart' show bomCsvWithCutPlan;
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/units.dart';

void main() {
  // fire-6: 10 floors × 4 m. Lift = pump datum (floor 0) → top-floor landing
  // valve = 9 × 4 + 1.2 = 37.2 m (NOT the 40 m roof). Head = 37.2 + 15 +
  // 690e3/9810 (70.336) = 122.536 m (was 125.336 m).
  test('fire-6: standpipe head uses the topmost hose outlet, not the roof', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var i = 0; i < 10; i++) Floor('L${i + 1}', const Length(4)),
    ]);
    final st = c.read(standpipeDesignProvider);
    expect(st.pumpHead.meters, closeTo(37.2 + 15 + 690000 / 9810, 1e-9));
    expect(st.pumpHead.meters, closeTo(122.54, 0.005));
  });

  // fire-2: one drawn sprinkler head on a plant source sizes on the hazard's
  // per-head flow (OH1 default: 360 L/min / 6 = 1.0 L/s), floored at DN25:
  //   DN25 v = 1e-3 / 4.9087e-4 = 2.037 > 2 ⇒ DN32 (v = 1e-3/8.0425e-4 = 1.243).
  test('fire-2: sprinkler leaf demand = the remote-head design flow', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final net = c.read(networkControllerProvider.notifier);
    net.loadNetwork(const Network(nodes: [
      NetNode(
          id: 'P', sheetId: 's', x: 0, y: 0, floorIndex: 0,
          role: NodeRole.plant),
      NetNode(id: 'H', sheetId: 's', x: 100, y: 0, floorIndex: 0),
    ], edges: [
      NetEdge(id: 'e', fromId: 'P', toId: 'H', service: ServiceType.fireSprinkler),
    ]));
    final s = c.read(sizingProvider)['e']!;
    expect(s.flow.inLitersPerSecond, closeTo(1.0, 1e-9));
    expect(s.diameter.inMillimeters, closeTo(32, 1e-9));
  });

  // fire-5: a PPR and a PVC DN50 run each carry their OWN bar count.
  test('fire-5: CSV bars_purchased joined per (service, DN, material)', () {
    const bom = [
      BomLine(
          service: ServiceType.coldWater,
          kind: EdgeKind.run,
          diameterMm: 50,
          material: 'PPR',
          totalLength: Length(2.0),
          segmentCount: 1),
      BomLine(
          service: ServiceType.coldWater,
          kind: EdgeKind.run,
          diameterMm: 50,
          material: 'PVC',
          totalLength: Length(2.0),
          segmentCount: 1),
    ];
    final plan = [
      for (final m in ['PPR', 'PVC'])
        PipeCutGroup(
          service: ServiceType.coldWater,
          diameterMm: 50,
          material: m,
          stockLengthM: 4.0,
          plan: planStockCuts(const [2.0], 4.0),
        ),
    ];
    final lines = bomCsvWithCutPlan(bom, plan).trim().split('\n');
    // 1 bar of 4 m for 2 m ⇒ waste 50.0 % on BOTH rows (was: 1 bar on the PPR
    // row only, the PVC row blank).
    expect(lines[1], endsWith(',PPR,2.00,1,4.0,1,50.0'));
    expect(lines[2], endsWith(',PVC,2.00,1,4.0,1,50.0'));
  });
}
