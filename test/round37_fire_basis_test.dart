// Round 37 (2026-10-18) — mech-sim-5-combined-fire-pump-head-adds-sprinkler-
// friction-to-standpipe.
//
// On a COMBINED sprinkler + hydrant system the hose basis (standpipe flow at
// the 6.9 bar hydrant residual) reads only the HYDRANT outlets' index-path
// friction; the sprinkler riser's friction belongs to its own remote-area
// duty. The pump is rated on the larger head at that basis's own flow.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.fireHydrant,
        EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// 13 storeys x 3.5 m, ordinary hazard, calibrated at 0.01 m/px. GT -> HP ->
/// header FH -> a hydrant stack with a hose box per floor; with [sprinkler]
/// a sprinkler riser off FH serves 4 heads per floor.
Network _tower(
    {required bool sprinkler, int stacks = 1, double sprinklerY = 400}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('HP', 50, 0, role: NodeRole.plant, c: NodeComponent.pump),
    _n('FH', 150, 0),
  ];
  final edges = <NetEdge>[_e('g', 'GT', 'HP'), _e('h', 'HP', 'FH')];
  for (var f = 0; f < 13; f++) {
    nodes
      ..add(_n('S$f', 250, 0, floor: f))
      ..add(_n('HB$f', 300, 0,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('hb$f', 'S$f', 'HB$f'))
      ..add(f == 0
          ? _e('s0', 'FH', 'S0')
          : _e('r$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser));
    if (stacks > 1) {
      nodes
        ..add(_n('T$f', 250, 200, floor: f))
        ..add(_n('HC$f', 300, 200,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
      edges
        ..add(_e('hc$f', 'T$f', 'HC$f'))
        ..add(f == 0
            ? _e('t0', 'FH', 'T0')
            : _e('tr$f', 'T${f - 1}', 'T$f', k: EdgeKind.riser));
    }
    if (sprinkler) {
      nodes.add(_n('Q$f', 150, sprinklerY, floor: f));
      edges.add(f == 0
          ? _e('q0', 'FH', 'Q0', s: ServiceType.fireSprinkler)
          : _e('qr$f', 'Q${f - 1}', 'Q$f',
              s: ServiceType.fireSprinkler, k: EdgeKind.riser));
      for (var h = 1; h <= 4; h++) {
        nodes.add(_n('H$f-$h', 150 + 300.0 * h, sprinklerY,
            floor: f, role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
        edges.add(_e('b$f-$h', h == 1 ? 'Q$f' : 'H$f-${h - 1}', 'H$f-$h',
            s: ServiceType.fireSprinkler));
      }
    }
  }
  return Network(nodes: nodes, edges: edges);
}

FireSystemBasis _basis(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 13; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(fireHazardProvider.notifier).set(FireHazardClass.ordinaryHazard1);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  final b = c.read(firePumpBasisByNodeProvider)['HP']!;
  // The hose basis friction is the HYDRANT terminals' index path only.
  final project = c.read(projectControllerProvider);
  final hyd = fireIndexPathFrictionM(
    net: net,
    system: fireSystems(net).single,
    pumpId: 'HP',
    sizing: c.read(sizingProvider),
    lengthOf: (e) => edgeLength(e, net,
            calibrationBySheet: project.calibrations,
            building: project.building,
            mounting: project.mounting)
        .meters,
    terminals: FireTerminalKind.hydrant,
  );
  expect(b.standpipe, isNotNull);
  // The governing (hose) basis carries the hydrant terminals' friction —
  // never a sprinkler head's.
  expect(hyd, isNotNull);
  expect(b.indexFrictionM, closeTo(hyd!, 1e-9));
  return b;
}

void main() {
  // Round 37 r2 — the literal rated point of the reviewer's 13-level probe
  // (TWO hydrant stacks), so the hose-basis ARITHMETIC is guarded, not only
  // the with/without-sprinkler equality:
  //   static lift  = 12 x 3.5 + 1.2 (hose outlet)          = 43.2 m
  //   friction     = max(15 m allowance, sized hydrant path ~8.9 m) = 15 m
  //                  (the sprinkler riser's path is NEVER added)
  //   residual     = 690 kPa / (1000 x 9.81)                = 70.336 m
  //   head         = 43.2 + 15 + 70.336                     = 128.536 m
  //   flow         = 500 + 250 gpm (two stacks) = 750 gpm   = 47.318 L/s
  //   motor        = the NFPA 20 pick at that point          = 110 kW
  test('the 13-level two-stack probe pins 128.54 m / 47.32 L/s / 110 kW, '
      'with or without the sprinkler riser', () {
    final expectedHead = 12 * 3.5 + 1.2 + 15 + 690e3 / (1000 * 9.81);
    expect(expectedHead, closeTo(128.54, 0.005));
    for (final sp in [false, true]) {
      final b = _basis(_tower(sprinkler: sp, stacks: 2));
      final r = 'sprinkler: $sp';
      expect(b.standpipeRisers, 2, reason: r);
      expect(b.head.meters, closeTo(expectedHead, 1e-6), reason: r);
      expect(b.head.meters, closeTo(128.54, 0.005), reason: r);
      expect(b.flow.inLitersPerSecond, closeTo(47.32, 0.005), reason: r);
      expect(b.flow.inLitersPerSecond, closeTo(750 * 0.0630902, 1e-3),
          reason: r);
      expect(b.indexFrictionM, lessThan(15), reason: r);
      expect(b.duty!.selectedMotor.watts, 110000, reason: r);
      expect(b.sprinklerGovernsCombined, isFalse, reason: r);
    }
  });

  // Round 37 r2 — the recorded 'larger head at its own flow, never both'
  // decision rates a SPRINKLER-governed combined system at the small
  // remote-area flow; that is now a judge-only Review warning. A 200 m
  // sprinkler feed main (sized at up to 6 m/s) pushes the sprinkler head
  // above the 128.54 m standpipe head.
  test('a sprinkler-governed combined system raises combined-fire-sprinkler-'
      'governs (locatable to the duty pump); a hose-governed one does not',
      () {
    ProviderContainer build(Network net) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(projectControllerProvider.notifier)
        ..setFloors(
            [for (var i = 0; i < 13; i++) Floor('L$i', const Length(3.5))])
        ..setCalibration('s1', const ScaleCalibration(0.01));
      c.read(fireHazardProvider.notifier).set(FireHazardClass.ordinaryHazard1);
      c.read(networkControllerProvider.notifier).loadNetwork(net);
      // Settle the MEP -> electrical sync before the Review fan-in reads the
      // electrical result (the sync writes the electrical project).
      c.read(electricalProjectProvider);
      c.read(mepAutoFeedCircuitsProvider);
      return c;
    }

    final gov = build(_tower(sprinkler: true, sprinklerY: 20000));
    final b = gov.read(firePumpBasisByNodeProvider)['HP']!;
    expect(b.sprinklerGovernsCombined, isTrue);
    expect(b.head.meters, greaterThan(b.standpipe!.pumpHead.meters));
    expect(b.flow.inLitersPerSecond,
        lessThan(b.standpipe!.requiredFlow.inLitersPerSecond));
    final issues = gov
        .read(designIssuesProvider)
        .where((i) => i.kind == 'combined-fire-sprinkler-governs:HP')
        .toList();
    expect(issues, hasLength(1));
    expect(issues.single.severity, IssueSeverity.warning);
    expect(issues.single.locate?.nodeId, 'HP');
    expect(issues.single.message, contains('31.5 L/s at 128.5 m'));

    final hose = build(_tower(sprinkler: true));
    expect(
        hose
            .read(designIssuesProvider)
            .any((i) => i.kind.startsWith('combined-fire-sprinkler-governs')),
        isFalse);
  });

  test('the standpipe rated point is the same with and without the sprinkler '
      'riser drawn off the same header', () {
    final hydrantOnly = _basis(_tower(sprinkler: false));
    final combined = _basis(_tower(sprinkler: true));
    expect(combined.sprinklerOnly, isFalse);
    expect(combined.standpipe!.pumpHead.meters,
        closeTo(hydrantOnly.standpipe!.pumpHead.meters, 1e-6));
    expect(combined.standpipe!.requiredFlow.inLitersPerSecond,
        closeTo(hydrantOnly.standpipe!.requiredFlow.inLitersPerSecond, 1e-9));
    // The hose basis governs (6.9 bar residual >> a head's pressure), so the
    // pump is rated on it — never the Σ of the two conditions.
    expect(combined.head.meters,
        closeTo(hydrantOnly.head.meters, 1e-6));
    expect(combined.flow.inLitersPerSecond,
        closeTo(hydrantOnly.flow.inLitersPerSecond, 1e-9));
    expect(combined.duty!.selectedMotor.watts,
        hydrantOnly.duty!.selectedMotor.watts);
  });

  test('mech-sim-5-jockey-leg-mirrors-main-pump-bore: three identical fire '
      'pumps (duty / standby / assumed jockey) — the jockey legs size on its '
      'own 1 % duty flow (DN25), the main pumps keep the full set flow', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier)
      ..setFloors([for (var i = 0; i < 4; i++) Floor('L$i', const Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    final nodes = <NetNode>[
      _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('FH', 200, 0),
    ];
    final edges = <NetEdge>[];
    for (final (i, p) in const ['FP1', 'FP2', 'JP'].indexed) {
      nodes
        ..add(_n(p, 100, 40.0 * i, role: NodeRole.plant, c: NodeComponent.pump))
        ..add(_n('V$p', 150, 40.0 * i, c: NodeComponent.checkValve));
      edges
        ..add(_e('s$p', 'GT', p))
        ..add(_e('p$p', p, 'V$p'))
        ..add(_e('v$p', 'V$p', 'FH'));
    }
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('S$f', 300, 0, floor: f))
        ..add(_n('HB$f', 340, 0,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
      edges
        ..add(_e('hb$f', 'S$f', 'HB$f'))
        ..add(f == 0
            ? _e('h0', 'FH', 'S0')
            : _e('r$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser));
    }
    c.read(networkControllerProvider.notifier)
        .loadNetwork(Network(nodes: nodes, edges: edges));
    final sz = c.read(sizingProvider);
    final basis = c.read(firePumpBasisByNodeProvider)['FP1']!;
    final jockeyQ = basis.rating.jockeyFlow.inLitersPerSecond;
    // 1 % of the one-stack standpipe flow (500 gpm = 31.5 L/s) = 0.315 L/s.
    expect(jockeyQ, closeTo(0.01 * basis.flow.inLitersPerSecond, 1e-9));
    for (final id in ['sJP', 'pJP', 'vJP']) {
      expect(sz[id]!.flow.inLitersPerSecond, closeTo(jockeyQ, 1e-9),
          reason: id);
      expect(sz[id]!.diameter.inMillimeters.round(), 25, reason: id);
    }
    final setQ = sz['h0']!.flow.inLitersPerSecond;
    for (final id in ['pFP1', 'pFP2']) {
      expect(sz[id]!.flow.inLitersPerSecond, closeTo(setQ, 1e-9), reason: id);
    }
    // The panel feed still reads JP as the jockey (now by its small bore).
    final bind = c.read(mepDutyBindingProvider);
    expect(bind.fireJockeyPumpNodeIds, contains('JP'));
    expect(bind.fireStandbyPumpNodeIds, contains('FP2'));
  });
}
