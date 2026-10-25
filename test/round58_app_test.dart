// Round 58 (2026-10-18) — app-side pins:
//
//   plumbing-hvac-convergence-8-pump-sized-on-prv-held-shortfall — a fixture
//     behind a drawn PRV holds the PRV setpoint whatever head the pump
//     develops, so the series mover duty never charges its shortfall: the
//     printed pump head equals the solve's required head, and no floor not
//     behind the PRV is pushed above the target by a phantom head. The same
//     for a hot-water heater behind the PRV (its shortfall never raises the
//     source head).
//
// First principles: without the PRV term the mover duty would read
// H = H_req + (target - p_K)/(rho g) for the PRV-fed sink K whose residual is
// pinned at (setpoint - its branch friction) < target — a head that moves
// every non-held floor up 1:1 and never moves K. With the rule the duty is
// max over the NON-held delivery nodes (the top lavatory at exactly the
// target ⇒ H = H_req) and the PRV inlet owed its setpoint (L2 of a 10-storey
// upfeed sits far above it).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart' show prvHeldNodes;
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x,
  double y, {
  int floor = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
  PlumbingFixture? fixture,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: y,
  floorIndex: floor,
  role: c?.role ?? role,
  component: c,
  fixture: fixture,
);

NetEdge _e(
  String id,
  String a,
  String b, {
  ServiceType s = ServiceType.coldWater,
  EdgeKind k = EdgeKind.run,
}) => NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// 10 storeys at 3.5 m: GT -> P (pump, L0) -> the riser R0..R9 with a
/// lavatory per floor; at L2 the branch R2 -> PRV -> C2 then a 100 m run to
/// four kitchen sinks K0..K3. [hot]: a heater WH after the PRV feeding four
/// showers over another 100 m hot run instead of the sinks.
Network _tower({bool hot = false}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, c: NodeComponent.groundTank),
    _n('P', 50, 0, c: NodeComponent.pump),
    for (var f = 0; f < 10; f++) ...[
      _n('R$f', 100, 0, floor: f),
      _n(
        'W$f',
        150,
        0,
        floor: f,
        role: NodeRole.fixture,
        fixture: PlumbingFixture.lavatory,
      ),
    ],
    _n('PRV', 100, 100, floor: 2, c: NodeComponent.prv),
    _n('C2', 100, 200, floor: 2),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'P'),
    _e('d', 'P', 'R0'),
    for (var f = 0; f < 10; f++) ...[
      if (f > 0) _e('r$f', 'R${f - 1}', 'R$f', k: EdgeKind.riser),
      _e('w$f', 'R$f', 'W$f'),
    ],
    _e('pi', 'R2', 'PRV'),
    _e('po', 'PRV', 'C2'),
  ];
  if (!hot) {
    nodes.add(_n('X', 10100, 200, floor: 2));
    edges.add(_e('run', 'C2', 'X'));
    for (var k = 0; k < 4; k++) {
      nodes.add(
        _n(
          'K$k',
          10100,
          300.0 + 100 * k,
          floor: 2,
          fixture: PlumbingFixture.kitchenSink,
          role: NodeRole.fixture,
        ),
      );
      edges.add(_e('k$k', k == 0 ? 'X' : 'K${k - 1}', 'K$k'));
    }
  } else {
    nodes
      ..add(_n('WH', 200, 200, floor: 2, role: NodeRole.plant))
      ..add(_n('HX', 10200, 200, floor: 2));
    edges
      ..add(_e('wf', 'C2', 'WH'))
      ..add(_e('hrun', 'WH', 'HX', s: ServiceType.hotWater));
    for (var k = 0; k < 4; k++) {
      nodes.add(
        _n(
          'S$k',
          10200,
          300.0 + 100 * k,
          floor: 2,
          fixture: PlumbingFixture.shower,
          role: NodeRole.fixture,
        ),
      );
      edges.add(
        _e('s$k', k == 0 ? 'HX' : 'S${k - 1}', 'S$k', s: ServiceType.hotWater),
      );
    }
  }
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _load(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 10; i++) Floor('L$i', Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  final target =
      SupplyDesignCriteria.recommended().targetFixtureResidualPressure;

  test('prvHeldNodes: the PRV, its outlet side and nothing upstream', () {
    final h = prvHeldNodes(
      _tower(),
      service: ServiceType.coldWater,
      sourceId: 'GT',
    );
    expect(h.inletOf, {'PRV': 'R2'});
    for (final id in ['PRV', 'C2', 'X', 'K0', 'K3']) {
      expect(h.heldBy[id], 'PRV', reason: id);
    }
    for (final id in ['R2', 'W2', 'R9', 'W9', 'P']) {
      expect(h.heldBy.containsKey(id), isFalse, reason: id);
    }
  });

  test('cold: the pump duty equals the required head; non-held floors are '
      'never pushed past the target by a phantom head', () {
    final c = _load(_tower());
    final sol = c.read(solveProvider)!;
    // Non-vacuous: the PRV-fed sink really sits below the target (the PRV
    // holds it there whatever the pump develops).
    expect(sol.residualPressure['K3']!.pascals, lessThan(target.pascals));
    final duty = c.read(pumpDutyProvider)!;
    expect(duty.head.meters, closeTo(sol.requiredPumpHead.meters, 1e-6));
    // The top lavatory is delivered at exactly the target, not above it.
    final delivered = c.read(upfeedDeliveredProvider)!;
    expect(
      delivered.residualPressure['W9']!.pascals,
      closeTo(target.pascals, 1),
    );
  });

  test('hot behind the PRV: the heater shortfall never raises the source', () {
    final c = _load(_tower(hot: true));
    final sol = c.read(solveProvider)!;
    // Non-vacuous: the far hot shower behind the PRV is below the target
    // (the PRV pins the heater inlet at its setpoint).
    expect(sol.residualPressure['S3']!.pascals, lessThan(target.pascals));
    // The source was NOT raised by that unattainable shortfall: the top
    // cold lavatory (the cold index) sits at exactly the target, never the
    // 'target + shortfall' a raised source would give it.
    expect(sol.residualPressure['W9']!.pascals, closeTo(target.pascals, 1));
    // One head on every surface: the pump duty is the solve's head.
    expect(
      c.read(pumpDutyProvider)!.head.meters,
      closeTo(sol.requiredPumpHead.meters, 1e-6),
    );
    expect(
      c.read(upfeedDeliveredProvider)!.residualPressure['W9']!.pascals,
      closeTo(target.pascals, 1),
    );
  });
}
