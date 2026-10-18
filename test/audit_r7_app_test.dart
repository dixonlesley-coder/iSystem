// Round-7 property audit — app-side fixes:
//   mech-building-2  upfeed fixture over-pressure is judged (Review);
//   mech-building-4  the AHU fan static includes the unit's internal losses;
//   mech-building-5  the hydrant riser carries the standpipe design flow;
//   roundtrip-1      addBasement / removeFloor move each sheet's floor mapping;
//   roundtrip-2      loading a project clears the phase-prior cache;
//   roundtrip-3      a re-minted MEP way returns to its slot, board stays put.
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart' show defaultMotorCosPhi;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x,
  int floor, {
  NodeRole role = NodeRole.main,
  NodeComponent? component,
  PlumbingFixture? fixture,
  FlowRate? airflow,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: 0,
  floorIndex: floor,
  role: role,
  component: component,
  fixture: fixture,
  airflow: airflow,
);

ProviderContainer _container(List<Floor> floors, Network net) {
  final c = ProviderContainer();
  c.read(projectControllerProvider.notifier).setFloors(floors);
  c
      .read(projectControllerProvider.notifier)
      .setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  group('mech-building-2 — upfeed fixture over-pressure', () {
    // N storeys × 3.5 m upfeed, 4 flush-tank WCs per floor off a riser.
    (List<Floor>, Network) building(int storeys) {
      final floors = [
        for (var f = 0; f < storeys; f++) Floor('L$f', const Length(3.5)),
      ];
      final nodes = <NetNode>[
        _n('P', 0, 0, role: NodeRole.plant, component: NodeComponent.pump),
        for (var f = 0; f < storeys; f++) _n('R$f', 100, f),
        for (var f = 0; f < storeys; f++)
          for (var k = 0; k < 4; k++)
            _n(
              'W${f}_$k',
              200.0 + 50 * k,
              f,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank,
            ),
      ];
      final edges = <NetEdge>[
        const NetEdge(
          id: 'feed',
          fromId: 'P',
          toId: 'R0',
          service: ServiceType.coldWater,
        ),
        for (var f = 0; f < storeys - 1; f++)
          NetEdge(
            id: 'r$f',
            fromId: 'R$f',
            toId: 'R${f + 1}',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser,
          ),
        for (var f = 0; f < storeys; f++)
          for (var k = 0; k < 4; k++)
            NetEdge(
              id: 'b${f}_$k',
              fromId: 'R$f',
              toId: 'W${f}_$k',
              service: ServiceType.coldWater,
            ),
      ];
      return (floors, Network(nodes: nodes, edges: edges));
    }

    test('the lowest fixtures are flagged; the top ones are not', () {
      final (floors, net) = building(8);
      final c = _container(floors, net);
      addTearDown(c.dispose);
      c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
      final sol = c.read(solveProvider)!;
      const maxFix = 392266.0; // SNI 8153 4 kgf/cm²
      // Ground-floor fixture: the pump head less a fixture-height lift.
      final ground = sol.residualPressure['W0_0']!.pascals;
      expect(ground, greaterThan(maxFix));
      // no-flow static = flowing residual + its path friction (≥ residual).
      expect(
        sol.noFlowStaticPressure['W0_0']!.pascals,
        greaterThanOrEqualTo(ground),
      );

      final over = c.read(upfeedOverPressureProvider);
      final flagged = over.map((o) => o.nodeId).toSet();
      expect(flagged, containsAll(['W0_0', 'W0_1', 'W0_2', 'W0_3']));
      expect(flagged, isNot(contains('W7_0'))); // the critical (top) fixture
      for (final o in over) {
        expect(o.flowing.pascals > maxFix || o.noFlow.pascals > maxFix, isTrue);
      }

      // Mount the electrical model first (its MEP auto-sync of the placed
      // pump runs on build, as the app shell does at launch).
      c.read(electricalProjectProvider);
      final issues = c
          .read(designIssuesProvider)
          .where((i) => i.kind.startsWith('upfeed-over-pressure:'))
          .toList();
      expect(issues.map((i) => i.kind.split(':').last).toSet(), flagged);
      for (final i in issues) {
        expect(
          i.severity,
          anyOf(IssueSeverity.warning, IssueSeverity.critical),
        );
        expect(i.locate?.nodeId, isNotNull);
      }
    });

    test('a downfeed (or a low upfeed) raises none', () {
      final (floors, net) = building(8);
      final c = _container(floors, net);
      addTearDown(c.dispose);
      expect(c.read(upfeedOverPressureProvider), isEmpty); // downfeed default
      final (lowFloors, lowNet) = building(2);
      final low = _container(lowFloors, lowNet);
      addTearDown(low.dispose);
      low.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
      expect(low.read(solveProvider), isNotNull);
      expect(low.read(upfeedOverPressureProvider), isEmpty);
    });
  });

  group('mech-building-4 — AHU fan static includes internal losses', () {
    Network airNet(NodeComponent? unit) => Network(
      nodes: [
        _n('U', 0, 0, role: NodeRole.plant, component: unit),
        _n('j', 3000, 0),
        _n('d1', 3200, 0, airflow: const FlowRate(0.2)),
        _n('d2', 4000, 0, airflow: const FlowRate(0.2)),
      ],
      edges: const [
        NetEdge(id: 'e1', fromId: 'U', toId: 'j', service: ServiceType.duct),
        NetEdge(id: 'e2', fromId: 'j', toId: 'd1', service: ServiceType.duct),
        NetEdge(id: 'e3', fromId: 'j', toId: 'd2', service: ServiceType.duct),
      ],
    );

    double external(ProviderContainer c) {
      final project = c.read(projectControllerProvider);
      final sizing = c.read(sizingProvider);
      return solveDuctStatic(
        net: c.read(sizingNetworkProvider),
        service: ServiceType.duct,
        fanNodeId: 'U',
        edgeFlows: {for (final e in sizing.entries) e.key: e.value.flow},
        sizing: sizing,
        calibrationBySheet: project.calibrations,
        building: project.building,
      ).totalStaticPressure.pascals;
    }

    for (final (unit, internal) in [
      (NodeComponent.ahu, 250.0), // filter + coil + casing
      (NodeComponent.fcu, 50.0), // small coil
      (NodeComponent.supplyFan, 0.0), // air mover only
    ]) {
      test('${unit.name}: total = external index run + $internal Pa', () {
        final c = _container(const [Floor('G', Length(3.5))], airNet(unit));
        addTearDown(c.dispose);
        final fan = c.read(ductFanProvider)!;
        expect(
          fan.totalStaticPressure.pascals,
          closeTo(external(c) + internal, 1e-9),
        );
      });
    }
  });

  test('mech-building-5 — the hydrant riser carries the standpipe flow', () {
    final floors = [
      for (var f = 0; f < 10; f++) Floor('L$f', const Length(3.5)),
    ];
    final c = _container(
      floors,
      Network(
        nodes: [
          _n('FP', 0, 0, role: NodeRole.plant, component: NodeComponent.pump),
          for (var f = 0; f < 10; f++) _n('H$f', 100, f),
          for (var f = 0; f < 10; f++)
            _n(
              'B$f',
              300,
              f,
              role: NodeRole.fixture,
              component: NodeComponent.hydrantBox,
            ),
        ],
        edges: [
          const NetEdge(
            id: 'feed',
            fromId: 'FP',
            toId: 'H0',
            service: ServiceType.fireHydrant,
          ),
          for (var f = 0; f < 9; f++)
            NetEdge(
              id: 'h$f',
              fromId: 'H$f',
              toId: 'H${f + 1}',
              service: ServiceType.fireHydrant,
              kind: EdgeKind.riser,
            ),
          for (var f = 0; f < 10; f++)
            NetEdge(
              id: 'box$f',
              fromId: 'H$f',
              toId: 'B$f',
              service: ServiceType.fireHydrant,
            ),
        ],
      ),
    );
    addTearDown(c.dispose);
    final design = c.read(standpipeDesignProvider).requiredFlow;
    final sizing = c.read(sizingProvider);
    // One system, one flow: the riser + trunk carry what the pump delivers
    // (was 10 × 5 L/s = 50 L/s at the riser base), and the riser velocity at
    // that flow stays inside the sizer's 2.0 m/s cap.
    for (final id in ['feed', for (var f = 0; f < 9; f++) 'h$f']) {
      expect(
        sizing[id]!.flow.cubicMetersPerSecond,
        closeTo(design.cubicMetersPerSecond, 1e-12),
        reason: id,
      );
      expect(sizing[id]!.velocity.metersPerSecond, lessThanOrEqualTo(2.0));
    }
    // A branch to ONE box keeps its per-box flow.
    expect(
      sizing['box3']!.flow.cubicMetersPerSecond,
      closeTo(
        kDefaultLeafDemand[ServiceType.fireHydrant]!.cubicMetersPerSecond,
        1e-12,
      ),
    );
  });

  group('roundtrip-1 — floor-stack edits move every sheet mapping', () {
    ProviderContainer setup() {
      final c = ProviderContainer();
      c.read(projectControllerProvider.notifier).setFloors(const [
        Floor('G', Length(3)),
        Floor('L1', Length(3)),
        Floor('L2', Length(3)),
        Floor('L3', Length(3)),
      ]);
      c.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 'g', name: 'G', sizePx: Size(1000, 1000)),
        Sheet(id: 'a', name: 'L1', sizePx: Size(1000, 1000)),
        Sheet(id: 'b', name: 'L2', sizePx: Size(1000, 1000)),
        Sheet(id: 'd', name: 'L3', sizePx: Size(1000, 1000)),
      ]);
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(
            Network(
              nodes: [
                for (final (i, s) in ['g', 'a', 'b', 'd'].indexed)
                  NetNode(
                    id: 'p$s',
                    sheetId: s,
                    x: 10,
                    y: 10,
                    floorIndex: i,
                    role: NodeRole.plant,
                    component: NodeComponent.pump,
                  ),
              ],
            ),
          );
      c.read(historyProvider.notifier).reset();
      return c;
    }

    // Every sheet must still see exactly its own drawn node.
    void expectEachSheetSeesItsNode(ProviderContainer c, List<String> ids) {
      final sheets = c.read(sheetsControllerProvider);
      final levels = c.read(projectControllerProvider).building.levelCount;
      final net = c.read(networkControllerProvider).network;
      for (final s in ids) {
        final f = sheets.floorFor(s, levels);
        final onSheet = net.nodes
            .where((n) => n.sheetId == s && n.floorIndex == f)
            .map((n) => n.id);
        expect(onSheet, ['p$s'], reason: 'sheet $s on floor $f');
      }
    }

    test('addBasement shifts each sheet with its work; undo restores both', () {
      final c = setup();
      addTearDown(c.dispose);
      c.read(projectControllerProvider.notifier).addBasement(1, 3.0);
      final sheets = c.read(sheetsControllerProvider);
      final project = c.read(projectControllerProvider);
      // 'g' is still the Ground plan — now floor 1, named 'G'.
      expect(project.floors[sheets.floorFor('g', 5)].name, 'G');
      expect(project.floors[sheets.floorFor('d', 5)].name, 'L3');
      expectEachSheetSeesItsNode(c, ['g', 'a', 'b', 'd']);

      c.read(historyProvider.notifier).undo();
      expect(c.read(sheetsControllerProvider).sheetFloors, isEmpty);
      expect(c.read(sheetsControllerProvider).floorFor('g', 4), 0);
      expectEachSheetSeesItsNode(c, ['g', 'a', 'b', 'd']);
    });

    test('removeFloor drops the higher sheets one floor with their work', () {
      final c = setup();
      addTearDown(c.dispose);
      c.read(projectControllerProvider.notifier).removeFloor(1);
      final sheets = c.read(sheetsControllerProvider);
      expect(sheets.floorFor('b', 3), 1); // L2 now at index 1
      expect(sheets.floorFor('d', 3), 2); // L3 at index 2 (was clamped onto 2)
      expectEachSheetSeesItsNode(c, ['g', 'b', 'd']);
      // The removed floor's sheet falls to the floor below (its work is gone).
      expect(sheets.floorFor('a', 3), 0);
    });
  });

  test('roundtrip-2 — opening a project starts from no phase prior', () {
    ElectricalProject project(List<double> watts) => ElectricalProject(
      panels: [
        ElectricalPanel(
          id: 'db',
          name: 'DB',
          circuits: [
            for (var i = 0; i < watts.length; i++)
              ElectricalCircuit(
                id: 'x$i',
                name: 'x$i',
                loadKind: LoadKind.lighting,
                loadW: watts[i],
                isLighting: true,
                length: const Length(10),
              ),
          ],
        ),
      ],
    );
    final a = project([200, 200, 200, 2200]);
    final b = project([60, 60, 60]);

    final session = ProviderContainer();
    addTearDown(session.dispose);
    final ctl = session.read(electricalProjectProvider.notifier);
    ctl.setProject(a);
    session.read(electricalResultProvider); // populates the prior cache
    ctl.setProject(b);
    final leaked = session.read(electricalResultProvider).panels['db']!;

    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    fresh.read(electricalProjectProvider.notifier).setProject(b);
    final clean = fresh.read(electricalResultProvider).panels['db']!;

    expect(
      leaked.circuits.map((c) => c.phase).toList(),
      clean.circuits.map((c) => c.phase).toList(),
    );
    expect(leaked.imbalancePercent, clean.imbalancePercent);
    expect(leaked.imbalancePercent, 0);
    expect(
      leaked.warnings.map((w) => w.code),
      isNot(contains('phase-imbalance')),
    );
  });

  group('roundtrip-3 — a re-minted MEP way returns to its slot', () {
    ElectricalCircuit way(String src, String name) => ElectricalCircuit(
      id: 'mep-$src',
      name: name,
      loadKind: LoadKind.motor,
      loadW: 3000,
      cosPhi: defaultMotorCosPhi,
      length: kDefaultCircuitLength,
      sourceEquipmentId: src,
      flaOverrideA: const Current(5),
    );
    final pump = way('pump', kSupplyPumpLoadName);
    final fan = way('fan', kSupplyFanLoadName);
    final fire = way('fire', kFirePumpLoadName);

    test('drop + re-mint restores the way order and the panel position', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setProject(
        const ElectricalProject(
          panels: [ElectricalPanel(id: 'mdp', name: 'MDP')],
        ),
      );
      ctl.syncMepEquipment([pump, fan, fire]);
      // A board added AFTER the MEP board.
      ctl.setProject(
        ElectricalProject(
          panels: [
            ...c.read(electricalProjectProvider).panels,
            const ElectricalPanel(id: 'lp', name: 'LP'),
          ],
        ),
      );
      List<String> order() => c
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == kMepEquipmentPanelId)
          .circuits
          .map((w) => w.id)
          .toList();
      List<String> panels() =>
          c.read(electricalProjectProvider).panels.map((p) => p.id).toList();
      final before = panels();
      expect(order(), ['mep-pump', 'mep-fan', 'mep-fire']);

      ctl.syncMepEquipment([fan, fire]); // pump source gone (pristine ⇒ drop)
      expect(order(), ['mep-fan', 'mep-fire']);
      ctl.syncMepEquipment([pump, fan, fire]); // …and back
      expect(order(), ['mep-pump', 'mep-fan', 'mep-fire']);
      expect(panels(), before); // the MEP board kept its place
    });
  });
}
