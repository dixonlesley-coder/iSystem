// Round 79 (2026-10-18) — plumbing-hvac-convergence-28-standby-pump-bound-
// to-another-sets-duty.
//
// One cold-water network holding TWO duplex sets: a transfer set
// GT -> TPa / TPb -> TJ (riser to the roof tank RT) and a roof-outlet
// booster RT -> BPa / BPb -> H (riser down to the floors). A standby is the
// same machine as the duty pump of ITS OWN set — the transfer standby backs
// the transfer pump (the full lift to the roof tank), the booster standby
// the booster — never every standby bound to the largest-bore pump of the
// network (a 750 W booster figure for a 44 m transfer lift).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y, int floor,
        {NodeComponent? c, NodeRole? role, PlumbingFixture? fixture}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: role ?? c?.role ?? NodeRole.main,
      component: c,
      fixture: fixture,
    );

NetEdge _e(String id, String a, String b,
        {EdgeKind k = EdgeKind.run, ServiceType s = ServiceType.coldWater}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

const _nF = 12;

Network _tower() {
  final top = _nF - 1;
  final nodes = <NetNode>[
    _n('GT', 0, 0, 0, c: NodeComponent.groundTank),
    _n('TPa', 100, 0, 0, c: NodeComponent.pump),
    _n('TPb', 100, 100, 0, c: NodeComponent.pump),
    _n('TJ', 200, 0, 0),
    _n('TT', 200, 0, top),
    _n('RT', 300, 0, top, c: NodeComponent.roofTank),
    _n('BPa', 400, 0, top, c: NodeComponent.pump),
    _n('BPb', 400, 100, top, c: NodeComponent.pump),
    _n('H', 500, 0, top),
  ];
  final edges = <NetEdge>[
    _e('ga', 'GT', 'TPa'),
    _e('gb', 'GT', 'TPb'),
    _e('ta', 'TPa', 'TJ'),
    _e('tb', 'TPb', 'TJ'),
    _e('tr', 'TJ', 'TT', k: EdgeKind.riser),
    _e('tt', 'TT', 'RT'),
    _e('ra', 'RT', 'BPa'),
    _e('rb', 'RT', 'BPb'),
    _e('ba', 'BPa', 'H'),
    _e('bb', 'BPb', 'H'),
  ];
  var prev = 'H';
  for (var f = top; f >= 0; f--) {
    final x = 'X$f';
    nodes.add(_n(x, 600, 0, f));
    edges.add(f == top ? _e('hx', prev, x) : _e('x$f', prev, x, k: EdgeKind.riser));
    for (var k = 0; k < 4; k++) {
      final w = 'W${f}_$k';
      nodes.add(_n(w, 700 + 50.0 * k, 0, f,
          role: NodeRole.fixture, fixture: PlumbingFixture.lavatory));
      edges.add(_e('w${f}_$k', x, w));
    }
    prev = x;
  }
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _c(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < _nF; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  test('pure: leg ends key the parallel sets', () {
    final net = _tower();
    bool cw(NetEdge e) => e.service == ServiceType.coldWater;
    expect(pumpLegEnds(net, 'TPa', cw), ('GT', 'TJ'));
    expect(pumpLegEnds(net, 'TPb', cw), ('GT', 'TJ'));
    expect(pumpLegEnds(net, 'BPa', cw), ('H', 'RT'));
    final m = parallelStandbyPumps(net, {'TPa', 'TPb', 'BPa', 'BPb'},
        onService: cw, bore: (_) => 25);
    // Equal bores, nothing mirrored: the lowest id is each set's duty.
    expect(m, {'TPb': 'TPa', 'BPb': 'BPa'});
  });

  test('a two-circulator-pair hot-water system: each standby backs its own '
      'riser\'s duty', () {
    // H -> P0 / Q0 -> J0 -> R0 (return riser 0) and H -> P1 / Q1 -> J1 -> R1.
    final net = Network(nodes: [
      _n('H', 0, 0, 0, c: NodeComponent.groundTank),
      for (final r in [0, 1]) ...[
        _n('P$r', 100, 200.0 * r, 0, c: NodeComponent.pump),
        _n('Q$r', 100, 200.0 * r + 100, 0, c: NodeComponent.pump),
        _n('J$r', 200, 200.0 * r, 0),
        _n('R$r', 300, 200.0 * r, 0),
      ],
    ], edges: [
      for (final r in [0, 1]) ...[
        _e('hp$r', 'H', 'P$r', s: ServiceType.hotWater),
        _e('hq$r', 'H', 'Q$r', s: ServiceType.hotWater),
        _e('pj$r', 'P$r', 'J$r', s: ServiceType.hotWater),
        _e('qj$r', 'Q$r', 'J$r', s: ServiceType.hotWater),
        _e('jr$r', 'J$r', 'R$r', s: ServiceType.hotWater),
      ],
    ]);
    final m = parallelStandbyPumps(net, {'P0', 'Q0', 'P1', 'Q1'},
        onService: (e) => e.service == ServiceType.hotWater,
        bore: (_) => 20);
    expect(m, {'Q0': 'P0', 'Q1': 'P1'});
  });

  test('app: transfer and booster standbys each bound to their own set', () {
    final c = _c(_tower());
    final bind = c.read(mepDutyBindingProvider);
    final sb = bind.supplyStandbyPumpNodeIds;
    const transfer = {'TPa', 'TPb'}, booster = {'BPa', 'BPb'};
    for (final MapEntry(key: s, value: d) in sb.entries) {
      final set = transfer.contains(s) ? transfer : booster;
      expect(set.contains(d), isTrue, reason: '$s -> $d');
      expect(s == d, isFalse);
    }
    expect(sb.keys.where(transfer.contains), hasLength(1));
    expect(sb.keys.where(booster.contains), hasLength(1));
    // Fed at its OWN set's duty machine.
    final duties = c.read(equipmentNodeDutiesProvider);
    for (final MapEntry(key: s, value: d) in sb.entries) {
      expect(duties[s]?.motor.watts, duties[d]?.motor.watts, reason: s);
    }
    // The transfer lift is the larger machine (sanity: the sets differ).
    final tDuty = sb[sb.keys.firstWhere(transfer.contains)]!;
    final bDuty = sb[sb.keys.firstWhere(booster.contains)]!;
    expect(duties[tDuty]!.motor.watts,
        greaterThan(duties[bDuty]!.motor.watts));
    expect(c.read(sizingProvider), isNotEmpty);
  });
}
