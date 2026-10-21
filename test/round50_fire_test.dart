// Round 50 — fire pump rooms, combined hose-reel + sprinkler systems and
// gravity (roof-tank) fire supplies:
//   regression-1 / fire-convergence-2-jockey-on-downstream-tee
//   regression-2 / regression-3 (combined Class II + sprinkler)
//   fire-convergence-2-gravity-roof-tank-fire-system-gets-phantom-pump
//   fire-convergence-2-roof-tank-feed-into-pumped-standpipe-unsized
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart' show bomProvider;
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x,
        {int floor = 0,
        double y = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c}) =>
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
        EdgeKind k = EdgeKind.run,
        double? mm}) =>
    NetEdge(
        id: id,
        fromId: a,
        toId: b,
        service: s,
        kind: k,
        sizeOverride: mm == null ? null : Diameter.mm(mm));

ProviderContainer _container(Network net, int floors, {double h = 3.5}) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < floors; i++) Floor('L$i', Length(h)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

/// A 3-storey hydrant stack Q0..Q2 (a box per floor) fed from node [from].
(List<NetNode>, List<NetEdge>) _stack(String from) => (
      [
        for (var f = 0; f < 3; f++) ...[
          _n('Q$f', 900, floor: f),
          _n('HB$f', 1000,
              floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ],
      ],
      [
        _e('dq', from, 'Q0'),
        for (var f = 0; f < 3; f++) ...[
          if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser),
          _e('hb$f', 'Q$f', 'HB$f'),
        ],
      ],
    );

void main() {
  group('a pump room is one parallel set whatever its header tees', () {
    test('(a) suction + discharge headers with a tee per pump: FP2 standby, '
        'the DN25 FP3 the jockey on its own duty', () {
      final st = _stack('D3');
      final net = Network(nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        for (var i = 1; i <= 3; i++) ...[
          _n('S$i', 100.0 * i),
          _n('FP$i', 100.0 * i,
              y: 100, role: NodeRole.plant, c: NodeComponent.pump),
          _n('D$i', 100.0 * i, y: 200),
        ],
        ...st.$1,
      ], edges: [
        _e('gs', 'GT', 'S1'),
        _e('s12', 'S1', 'S2'),
        _e('s23', 'S2', 'S3'),
        _e('d12', 'D1', 'D2'),
        _e('d23', 'D2', 'D3'),
        for (var i = 1; i <= 3; i++) ...[
          _e('sp$i', 'S$i', 'FP$i', mm: i == 3 ? 25 : null),
          _e('pd$i', 'FP$i', 'D$i', mm: i == 3 ? 25 : null),
        ],
        ...st.$2,
      ]);
      final c = _container(net, 3);
      final bind = c.read(mepDutyBindingProvider);
      expect(bind.firePumpNodeIds, {'FP1', 'FP2', 'FP3'});
      expect(bind.fireJockeyPumpNodeIds, {'FP3'});
      expect(bind.fireStandbyPumpNodeIds.length, 1);
      expect(bind.fireStandbyPumpNodeIds, {'FP2'});
      final basis = c.read(fireSystemBasesProvider).single;
      // One pump room = one stage: no stage heads, every main pump at the
      // full system head.
      expect(basis.stageHeads, isEmpty);
      // The jockey is fed its pressure-maintenance duty (1 % rated flow at
      // churn + 5 m), never the main NFPA 20 frame.
      final duties = c.read(equipmentNodeDutiesProvider);
      expect(duties['FP3']!.motor.watts, basis.jockey!.selectedMotor.watts);
      expect(duties['FP3']!.motor.watts,
          lessThan(basis.duty!.selectedMotor.watts));
      // Duty + standby + jockey: only ONE main machine at demand factor 1.
      final loads = c.read(placedEquipmentLoadsProvider);
      double dfOf(String id) =>
          loads.firstWhere((l) => l.id.contains(id)).demandFactor ?? 1.0;
      final standby = bind.fireStandbyPumpNodeIds.single;
      final duty = standby == 'FP1' ? 'FP2' : 'FP1';
      expect(dfOf(duty), 1.0);
      expect(dfOf(standby), 0.0);
    });

    test('(b) a jockey discharging onto a tee downstream of the main header '
        'is the jockey', () {
      final st = _stack('J');
      final net = Network(nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('S', 100),
        _n('FP1', 200, role: NodeRole.plant, c: NodeComponent.pump),
        _n('FP2', 200, y: 100, role: NodeRole.plant, c: NodeComponent.pump),
        _n('FP3', 200, y: 200, role: NodeRole.plant, c: NodeComponent.pump),
        _n('D', 300),
        _n('J', 400),
        ...st.$1,
      ], edges: [
        _e('gs', 'GT', 'S'),
        _e('s1', 'S', 'FP1'),
        _e('s2', 'S', 'FP2'),
        _e('p1', 'FP1', 'D'),
        _e('p2', 'FP2', 'D'),
        _e('dj', 'D', 'J'),
        _e('s3', 'S', 'FP3', mm: 25),
        _e('p3', 'FP3', 'J', mm: 25),
        ...st.$2,
      ]);
      final c = _container(net, 3);
      final bind = c.read(mepDutyBindingProvider);
      expect(bind.fireStandbyPumpNodeIds, {'FP2'});
      expect(bind.fireJockeyPumpNodeIds, {'FP3'});
      final basis = c.read(fireSystemBasesProvider).single;
      expect(c.read(equipmentNodeDutiesProvider)['FP3']!.motor.watts,
          basis.jockey!.selectedMotor.watts);
    });
  });

  group('combined hose-reel (Class II) + sprinkler system', () {
    // GT -> P -> riser R0..R3 (4 floors x 4 m, OH2); a hose reel and a
    // 6-head sprinkler branch per floor teed off the SAME hydrant riser.
    Network combined(NodeComponent outlet) {
      const h = ServiceType.fireHydrant;
      const sp = ServiceType.fireSprinkler;
      return Network(nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 50, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 4; f++) ...[
          _n('R$f', 150, floor: f),
          _n('HR$f', 250, floor: f, role: NodeRole.fixture, c: outlet),
          for (var k = 1; k <= 6; k++)
            _n('H$f-$k', 150 + 300.0 * k,
                floor: f,
                y: 300,
                role: NodeRole.fixture,
                c: NodeComponent.sprinklerHead),
        ],
      ], edges: [
        _e('g', 'GT', 'P', s: h),
        _e('p', 'P', 'R0', s: h),
        for (var f = 0; f < 4; f++) ...[
          if (f > 0) _e('r$f', 'R${f - 1}', 'R$f', s: h, k: EdgeKind.riser),
          _e('hr$f', 'R$f', 'HR$f', s: h),
          for (var k = 1; k <= 6; k++)
            _e('b$f-$k', k == 1 ? 'R$f' : 'H$f-${k - 1}', 'H$f-$k', s: sp),
        ],
      ]);
    }

    ProviderContainer probe(NodeComponent outlet) {
      final c = _container(combined(outlet), 4, h: 4);
      c.read(fireHazardProvider.notifier).set(FireHazardClass.ordinaryHazard2);
      return c;
    }

    test('the shared riser + pump discharge carry the sprinkler demand within '
        'the 6 m/s fire cap', () {
      final c = probe(NodeComponent.hoseReel);
      final demand =
          c.read(sprinklerRemoteAreaProvider).remoteAreaDemand.inLitersPerSecond;
      // OH2 remote area: well above the 100 gpm (6.31 L/s) hose station.
      expect(demand, greaterThan(6.31));
      final sz = c.read(sizingProvider);
      for (final id in ['p', 'r1', 'r2', 'r3']) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(demand, 1e-6),
            reason: id);
        expect(sz[id]!.velocity.metersPerSecond,
            lessThanOrEqualTo(kMaxFireVelocityMps + 1e-9),
            reason: id);
      }
      // The hose-only sub-branch keeps the hose-station flow.
      expect(sz['hr0']!.flow.inLitersPerSecond, lessThanOrEqualTo(6.31));
    });

    test('the pump is rated on the sprinkler flow at the larger head, and the '
        'sprinkler-vs-pump judge passes', () {
      final c = probe(NodeComponent.hoseReel);
      final b = c.read(fireSystemBasesProvider).single;
      final demand = c.read(sprinklerRemoteAreaProvider).remoteAreaDemand;
      expect(b.standpipeClass, StandpipeClass.classII);
      expect(b.flow.inLitersPerSecond,
          closeTo(demand.inLitersPerSecond, 1e-9));
      // Head = max(standpipe head, sprinkler head) — both points covered.
      expect(b.head.meters,
          greaterThanOrEqualTo(b.standpipe!.pumpHead.meters - 1e-9));
      expect(b.sprinklerGovernsCombined, isFalse);
      final chk = c.read(sprinklerPumpCheckProvider)!;
      expect(chk.flowShort, isFalse);
      expect(
          c
              .read(designIssuesProvider)
              .any((i) => i.kind.startsWith('sprinkler-flow-exceeds-fire-pump')),
          isFalse);
    });

    test('the hydrant-box variant keeps the Class I 500 gpm basis', () {
      final c = probe(NodeComponent.hydrantBox);
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.standpipeClass, StandpipeClass.classI);
      expect(b.flow.inLitersPerSecond,
          closeTo(standpipeFlow(1).inLitersPerSecond, 1e-9));
      expect(b.duty!.selectedMotor.inKiloWatts, 55);
    });
  });

  group('gravity (roof-tank) fire supply', () {
    // 25 storeys x 3 m, OH1, 6 heads per storey, fed ONLY by a roof tank on
    // L24 down a riser Q24..Q0.
    Network gravity() {
      const sp = ServiceType.fireSprinkler;
      return Network(nodes: [
        _n('RT', 0, floor: 24, role: NodeRole.plant, c: NodeComponent.roofTank),
        for (var f = 0; f < 25; f++) ...[
          _n('Q$f', 150, floor: f),
          for (var k = 1; k <= 6; k++)
            _n('H$f-$k', 150 + 300.0 * k,
                floor: f, role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
        ],
      ], edges: [
        _e('t', 'RT', 'Q24', s: sp),
        for (var f = 0; f < 25; f++) ...[
          if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', s: sp, k: EdgeKind.riser),
          for (var k = 1; k <= 6; k++)
            _e('b$f-$k', k == 1 ? 'Q$f' : 'H$f-${k - 1}', 'H$f-$k', s: sp),
        ],
      ]);
    }

    test('no phantom pump, no churn over-pressure; the 0.3 m tank head is a '
        'gravity-head warning', () {
      final c = _container(gravity(), 25, h: 3);
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.gravityFed, isTrue);
      expect(b.duty, isNull);
      expect(b.jockey, isNull);
      expect(c.read(governingFireBasisProvider), isNull);
      expect(c.read(firePumpDutyProvider), isNull);
      expect(c.read(fireOverPressureProvider), isEmpty);
      expect(c.read(sprinklerPumpCheckProvider), isNull);
      expect(
          c.read(mepEquipmentLoadsProvider).any((l) => l.id == 'fire-pump'),
          isFalse);
      // The roof tank sits at the L24 roof (25 x 3 = 75.0 m), the top heads
      // at the L24 ceiling (75 - 0.3 = 74.7 m): 0.3 m less friction, against
      // the remote head's minimum pressure (0.5 bar = 5.1 m).
      final need = c
              .read(sprinklerRemoteAreaProvider)
              .remoteHeadPressure
              .pascals /
          (1000 * 9.81);
      expect(b.gravityRequiredHeadM, closeTo(need, 1e-9));
      expect(b.gravityAvailableHeadM, lessThanOrEqualTo(0.3 + 1e-9));
      expect(b.gravityHeadShort, isTrue);
      final issues = c.read(designIssuesProvider);
      expect(issues.any((i) => i.kind == 'fire-gravity-head-insufficient:RT'),
          isTrue);
      expect(
          issues.any((i) => i.kind.startsWith('fire-system-over-pressure')),
          isFalse);
    });

    test('a roof-tank gravity feed into a pumped standpipe is sized and taken '
        'off', () {
      const h = ServiceType.fireHydrant;
      final net = Network(nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FP', 50, role: NodeRole.plant, c: NodeComponent.pump),
        _n('HD', 100),
        for (final s in ['A', 'B'])
          for (var f = 0; f < 25; f++) ...[
            _n('$s$f', s == 'A' ? 200 : 2000, floor: f),
            _n('${s}HB$f', s == 'A' ? 300 : 2100,
                floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
          ],
        _n('RT', 0, floor: 24, role: NodeRole.plant, c: NodeComponent.roofTank),
        _n('CV', 100, floor: 24, c: NodeComponent.checkValve),
      ], edges: [
        _e('g', 'GT', 'FP', s: h),
        _e('p', 'FP', 'HD', s: h),
        _e('ha', 'HD', 'A0', s: h),
        _e('hbb', 'HD', 'B0', s: h),
        for (final s in ['A', 'B'])
          for (var f = 0; f < 25; f++) ...[
            if (f > 0)
              _e('${s.toLowerCase()}$f', '$s${f - 1}', '$s$f',
                  s: h, k: EdgeKind.riser),
            _e('${s}box$f', '$s$f', '${s}HB$f', s: h),
          ],
        _e('ab24', 'A24', 'B24', s: h),
        _e('rtcv', 'RT', 'CV', s: h),
        _e('cvA', 'CV', 'A24', s: h),
      ]);
      final c = _container(net, 25, h: 3);
      final sz = c.read(sizingProvider);
      final join = sz['a24']!;
      for (final id in ['rtcv', 'cvA']) {
        final s = sz[id];
        expect(s, isNotNull, reason: id);
        expect(s!.flow.inLitersPerSecond,
            greaterThanOrEqualTo(join.flow.inLitersPerSecond - 1e-9));
        expect(s.diameter.inMillimeters,
            greaterThanOrEqualTo(join.diameter.inMillimeters));
        expect(s.diameter.inMillimeters, greaterThanOrEqualTo(100));
      }
      // Every hydrant pipe drawn is taken off (none silently skipped).
      final bomSegments = c
          .read(bomProvider)
          .where((l) => l.service == h)
          .fold<int>(0, (a, l) => a + l.segmentCount);
      expect(bomSegments, net.edges.where((e) => e.service == h).length);
      // A pumped system: never treated as gravity-fed.
      expect(c.read(fireSystemBasesProvider).single.gravityFed, isFalse);
    });
  });
}
