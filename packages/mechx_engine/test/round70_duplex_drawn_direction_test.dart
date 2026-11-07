// Round 70 — a duty / standby booster pair (two valveless pump legs on the
// same two leg ends) whatever way each leg is drawn:
//
//  * regression-duplex-backwards-duty-beside-incoherent-standby (cold water)
//    — a coherently BACKWARDS leg beside an INCOHERENTLY drawn one (both
//    pipes into its pump) is a disagreeing set: the incoherent leg records
//    the away-from-source direction, so the pair is oriented away from the
//    source and every leg carries the set flow.
//  * regression-hot-water-backwards-standby-leg-undersized (hot water) — the
//    disagreeing set is NOT oriented on hot water (a supply pump beside a
//    return circulator has the same topology), but the sizer envelopes the
//    drawn reading with the set-oriented reading, so a backwards standby leg
//    is never sized below the correctly drawn duty leg.
//
// Drawing: source -> SH; legs SH -s1- P1 -d1- DH and SH -s2- P2 -d2- DH;
// DH -> riser to 5 floors x 4 outlets of 2 UBAP each (40 UBAP).
//
// First principles: a running pump carries the whole set flow (a standby
// takes over the duty), so each leg carries the riser's probable flow
// curve(40 UBAP) — the SNI demand curve — exactly as when both legs are
// drawn source -> pump -> riser ("ok/ok").
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

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

enum _Draw { ok, back, inc }

Network _net(ServiceType svc, _Draw p1, _Draw p2) {
  NetEdge e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
      NetEdge(id: id, fromId: a, toId: b, service: svc, kind: k);
  List<NetEdge> leg(String n, _Draw d) => switch (d) {
        _Draw.ok => [e('s$n', 'SH', 'P$n'), e('d$n', 'P$n', 'DH')],
        _Draw.back => [e('s$n', 'P$n', 'SH'), e('d$n', 'DH', 'P$n')],
        // Both pipes INTO the pump.
        _Draw.inc => [e('s$n', 'SH', 'P$n'), e('d$n', 'DH', 'P$n')],
      };
  return Network(nodes: [
    if (svc == ServiceType.coldWater)
      _n('T', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank)
    else
      _n('T', 0, 0, role: NodeRole.plant),
    _n('SH', 100, 0),
    _n('P1', 200, -50, role: NodeRole.plant, c: NodeComponent.pump),
    _n('P2', 200, 50, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DH', 300, 0),
    for (var f = 1; f <= 5; f++) ...[
      _n('R$f', 300, 0, floor: f),
      for (var k = 0; k < 4; k++)
        _n('F$f$k', 400.0 + 50 * k, 0, floor: f, role: NodeRole.fixture),
    ],
  ], edges: [
    e('g', 'T', 'SH'),
    ...leg('1', p1),
    ...leg('2', p2),
    e('r1', 'DH', 'R1', k: EdgeKind.riser),
    for (var f = 2; f <= 5; f++) e('r$f', 'R${f - 1}', 'R$f', k: EdgeKind.riser),
    for (var f = 1; f <= 5; f++)
      for (var k = 0; k < 4; k++)
        e('b$f$k', k == 0 ? 'R$f' : 'F$f${k - 1}', 'F$f$k'),
  ]);
}

typedef _Run = ({
  Map<String, EdgeSizing> s,
  Set<String> disagree,
  Set<String> against,
});

_Run _size(ServiceType svc, _Draw p1, _Draw p2) {
  final dis = <String>{};
  final ma = <String>{};
  final s = autoSizeNetwork(
    _net(svc, p1, p2),
    const SizingContext(),
    leafDemand: {svc: const FlowRate(0)},
    leafFixtureUnits: {svc: 2.0},
    building: BuildingLevels(
        [for (var i = 0; i < 6; i++) Floor('L$i', const Length(3.0))]),
    calibrationBySheet: const {'s1': ScaleCalibration(0.02)},
    disagreeingSetMoversOut: dis,
    moverAgainstBalanceOut: ma,
  );
  return (s: s, disagree: dis, against: ma);
}

const _legs = ['s1', 'd1', 's2', 'd2'];

void main() {
  final setFlow =
      const SniProfile().probableFlowForFixtureUnits(40).cubicMetersPerSecond;

  group('cold water: backwards duty beside an incoherent standby', () {
    final okok = _size(ServiceType.coldWater, _Draw.ok, _Draw.ok);

    test('ok/ok: every leg carries curve(40 UBAP)', () {
      for (final id in _legs) {
        expect(okok.s[id]!.flow.cubicMetersPerSecond, closeTo(setFlow, 1e-9),
            reason: id);
      }
    });

    for (final (a, b) in [
      (_Draw.back, _Draw.ok),
      (_Draw.ok, _Draw.back),
      (_Draw.back, _Draw.inc),
      (_Draw.inc, _Draw.back),
      (_Draw.inc, _Draw.ok),
      (_Draw.ok, _Draw.inc),
    ]) {
      test('${a.name}/${b.name}: == ok/ok, backwards member named', () {
        final r = _size(ServiceType.coldWater, a, b);
        for (final id in _legs) {
          expect(r.s[id]!.diameter.inMillimeters,
              okok.s[id]!.diameter.inMillimeters,
              reason: '$id DN');
          expect(r.s[id]!.flow.cubicMetersPerSecond, closeTo(setFlow, 1e-9),
              reason: '$id flow');
          // Away from the source: suction legs leave SH, discharge legs
          // leave the pump.
          expect(r.s[id]!.flowFromId, okok.s[id]!.flowFromId,
              reason: '$id dir');
        }
        final backwards = {
          if (a == _Draw.back) 'P1',
          if (b == _Draw.back) 'P2',
        };
        expect(r.disagree.containsAll(backwards), isTrue);
        expect(r.against, isEmpty);
      });
    }
  });

  group('hot water: a backwards standby leg is enveloped, never undersized',
      () {
    final okok = _size(ServiceType.hotWater, _Draw.ok, _Draw.ok);
    for (final (a, b) in [
      (_Draw.back, _Draw.ok),
      (_Draw.ok, _Draw.back),
      (_Draw.back, _Draw.inc),
      (_Draw.inc, _Draw.back),
    ]) {
      test('${a.name}/${b.name}: every leg >= the ok/ok bore and flow', () {
        final r = _size(ServiceType.hotWater, a, b);
        for (final id in _legs) {
          expect(r.s[id]!.diameter.inMillimeters,
              greaterThanOrEqualTo(okok.s[id]!.diameter.inMillimeters),
              reason: '$id DN');
          expect(r.s[id]!.flow.cubicMetersPerSecond,
              greaterThanOrEqualTo(setFlow - 1e-9),
              reason: '$id flow');
        }
        // The backwards member is named as a disagreeing-set member.
        if (a == _Draw.back) expect(r.disagree, contains('P1'));
        if (b == _Draw.back) expect(r.disagree, contains('P2'));
      });
    }
  });
}
