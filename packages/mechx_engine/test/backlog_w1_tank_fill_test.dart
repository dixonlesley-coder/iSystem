// Backlog W-1 (2026-11-14) — a storage tank fills at its capacity / its
// refill time. The meter feed of a ground tank and the transfer pipework into
// a roof tank are sized on that FILL FLOW (`tankFillFlow`), not on the
// diversified peak of what the tank distributes; a tank with no capacity
// keeps the peak basis. Hand arithmetic in every comment.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/tank_fill.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/shophouse.dart';

Map<String, EdgeSizing> _size(ReferenceBuilding b, Network net) {
  const profile = SniProfile();
  return autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: const {ServiceType.coldWater: FlowRate(0.0002)},
    leafFixtureUnits: const {ServiceType.coldWater: 2.0},
    nodeFixtureUnits: {
      for (final n in net.nodes)
        if (n.fixture != null)
          n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: b.occupancy),
    },
    building: b.building,
    calibrationBySheet: b.calibrations,
    mounting: b.mounting,
  );
}

/// The shophouse with [edit] applied to each node.
Network _with(Network net, NetNode Function(NetNode n) edit,
        {List<NetNode> extraNodes = const [],
        List<NetEdge> extraEdges = const []}) =>
    Network(
      nodes: [for (final n in net.nodes) edit(n), ...extraNodes],
      edges: [...net.edges, ...extraEdges],
    );

String _e(String a, String b) => 'e_cw_${a}_$b';

void main() {
  group('tankFillFlow — capacity / refill time', () {
    NetNode tank(NodeComponent c, {double? l, double? h}) => NetNode(
        id: 't',
        sheetId: 's',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: NodeRole.plant,
        component: c,
        tankCapacityLitres: l,
        tankRefillHours: h);
    test('ground tank default 4 h, roof tank default 1 h', () {
      // 20 000 L / 1000 / (4 x 3600 s) = 1.388889e-3 m3/s = 1.38889 L/s.
      expect(
          tankFillFlow(tank(NodeComponent.groundTank, l: 20000))!
              .inLitersPerSecond,
          closeTo(1.388889, 1e-6));
      // 10 000 L / (1 x 3600 s) = 2.77778 L/s.
      expect(
          tankFillFlow(tank(NodeComponent.roofTank, l: 10000))!
              .inLitersPerSecond,
          closeTo(2.777778, 1e-6));
      expect(tankRefillHoursOf(tank(NodeComponent.groundTank)),
          kGroundTankRefillHoursDefault);
      expect(tankRefillHoursOf(tank(NodeComponent.roofTank)),
          kRoofTankRefillHoursDefault);
    });
    test('an entered refill time wins; no capacity / not a tank ⇒ null', () {
      // 10 000 L / (2.5 h x 3600) = 1.11111 L/s.
      expect(
          tankFillFlow(tank(NodeComponent.roofTank, l: 10000, h: 2.5))!
              .inLitersPerSecond,
          closeTo(1.111111, 1e-6));
      expect(tankFillFlow(tank(NodeComponent.roofTank)), isNull);
      expect(tankFillFlow(tank(NodeComponent.roofTank, l: 0)), isNull);
      expect(tankFillFlow(tank(NodeComponent.pump, l: 5000)), isNull);
    });
    test('the defaults are one verify-checklist entry', () {
      final v = const SniProfile().tankFillBasis;
      expect(const SniProfile().verifyChecklist, contains(v));
      expect(v.status, VerificationStatus.notAnSniClause);
      expect(v.isUnverified, isTrue);
    });
  });

  group('the sizer sizes the fill on the fill flow', () {
    final shop = buildShophouse();
    // Unit A: GT_A 6000 L (4 h), RT_A 2000 L (1 h); B and C keep no
    // capacity (today's basis).
    NetNode capA(NetNode n) => switch (n.id) {
          'GT_A' => n.copyWith(tankCapacityLitres: 6000),
          'RT_A' => n.copyWith(tankCapacityLitres: 2000),
          _ => n,
        };

    test('meter feed = GT fill, transfer = RT fill; distribution unchanged',
        () {
      final net = _with(shop.network, capA);
      final sz = _size(shop, net);
      // WM → GT: 6000 / 1000 / (4 x 3600) = 0.416667 L/s; DN15 v =
      // 0.416667e-3 / (pi x 0.015^2 / 4 = 1.76715e-4) = 2.358 > 2.0 → DN20
      // v = 0.416667e-3 / 3.14159e-4 = 1.326.
      final wm = sz[_e('WM_A', 'GT_A')]!;
      expect(wm.flow.inLitersPerSecond, closeTo(0.416667, 1e-6));
      expect(wm.diameter.inMillimeters, 20);
      expect(wm.velocity.metersPerSecond, closeTo(1.326, 5e-4));
      expect(wm.flowFromId, 'WM_A');
      // GT → TP → U0 → U1 → U2 → RT: 2000 / (1 x 3600) = 0.555556 L/s;
      // DN15 v 3.144 > 2.0 → DN20 v = 0.555556e-3 / 3.14159e-4 = 1.768.
      for (final id in [
        _e('GT_A', 'TP_A'),
        _e('TP_A', 'U0_A'),
        _e('U0_A', 'U1_A'),
        _e('U1_A', 'U2_A'),
        _e('U2_A', 'RT_A'),
      ]) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(0.555556, 1e-6),
            reason: id);
        expect(sz[id]!.diameter.inMillimeters, 20, reason: id);
        expect(sz[id]!.velocity.metersPerSecond, closeTo(1.768, 5e-4),
            reason: id);
      }
      // RT → BS distributes 12.5 UBAP: 0.5 + 2.5 x 0.38333 / 15 = 0.56389
      // L/s (the demand curve, unchanged).
      expect(sz[_e('RT_A', 'BS_A')]!.flow.inLitersPerSecond,
          closeTo(0.56389, 5e-5));
      // Units B / C have no capacity: the peak basis stays, 0.56389 L/s on
      // the meter feed and the fill line (reference shophouse F2).
      for (final u in ['B', 'C']) {
        expect(sz[_e('WM_$u', 'GT_$u')]!.flow.inLitersPerSecond,
            closeTo(0.56389, 5e-5));
        expect(sz[_e('U2_$u', 'RT_$u')]!.flow.inLitersPerSecond,
            closeTo(0.56389, 5e-5));
      }
    });

    test('an entered refill time changes the fill flow', () {
      final net = _with(
          shop.network,
          (n) => n.id == 'RT_A'
              ? n.copyWith(tankCapacityLitres: 2000, tankRefillHours: 2)
              : n);
      final sz = _size(shop, net);
      // 2000 / (2 x 3600) = 0.277778 L/s; DN15 v = 0.277778e-3 / 1.76715e-4
      // = 1.572.
      final q = sz[_e('U2_A', 'RT_A')]!;
      expect(q.flow.inLitersPerSecond, closeTo(0.277778, 1e-6));
      expect(q.diameter.inMillimeters, 15);
      expect(q.velocity.metersPerSecond, closeTo(1.572, 5e-4));
      // GT_A has no capacity: its meter feed keeps the F2 basis, what GT
      // DELIVERS — and GT now delivers only the RT fill, so the feed carries
      // 0.277778 L/s (never the 12.5 UBAP peak 0.56389 of the distribution
      // beyond the filled roof tank).
      expect(sz[_e('WM_A', 'GT_A')]!.flow.inLitersPerSecond,
          closeTo(0.277778, 1e-6));
    });

    test('a fixture on the fill riser adds its own demand to the fill', () {
      // A lavatory on Lantai 2 tapped off U1_A: U0 → U1 carries the fill +
      // curve(1.0 UBAP) = 0.555556 + 1.0 x 0.05 = 0.605556 L/s; U1 → U2 the
      // fill alone 0.555556.
      const lav = NetNode(
          id: 'LX_A',
          sheetId: kShopSheetL2,
          x: 140,
          y: 0,
          floorIndex: 1,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.lavatory);
      final net = _with(shop.network, capA, extraNodes: [
        lav
      ], extraEdges: [
        const NetEdge(
            id: 'e_cw_U1_A_LX_A',
            fromId: 'U1_A',
            toId: 'LX_A',
            service: ServiceType.coldWater),
      ]);
      final sz = _size(shop, net);
      expect(sz[_e('U0_A', 'U1_A')]!.flow.inLitersPerSecond,
          closeTo(0.605556, 1e-6));
      expect(sz[_e('U1_A', 'U2_A')]!.flow.inLitersPerSecond,
          closeTo(0.555556, 1e-6));
      expect(sz['e_cw_U1_A_LX_A']!.flow.inLitersPerSecond, closeTo(0.05, 1e-9));
    });

    test('order-independent: shuffled lists and renamed ids size the same',
        () {
      final base = _with(shop.network, capA);
      final ref = _size(shop, base);
      final rnd = math.Random(7);
      for (var trial = 0; trial < 6; trial++) {
        String ren(String id) => 'z${trial}_$id';
        final nodes = [
          for (final n in base.nodes)
            NetNode(
              id: ren(n.id),
              sheetId: n.sheetId,
              x: n.x,
              y: n.y,
              floorIndex: n.floorIndex,
              role: n.role,
              fixture: n.fixture,
              component: n.component,
              roofAreaM2: n.roofAreaM2,
              tankCapacityLitres: n.tankCapacityLitres,
              tankRefillHours: n.tankRefillHours,
            ),
        ]..shuffle(rnd);
        final edges = [
          for (final e in base.edges)
            NetEdge(
              id: ren(e.id),
              fromId: ren(e.fromId),
              toId: ren(e.toId),
              service: e.service,
              kind: e.kind,
            ),
        ]..shuffle(rnd);
        final sz = _size(shop, Network(nodes: nodes, edges: edges));
        for (final e in base.edges) {
          if (e.service != ServiceType.coldWater) continue;
          final a = ref[e.id]!;
          final b = sz[ren(e.id)]!;
          expect(b.flow.cubicMetersPerSecond,
              closeTo(a.flow.cubicMetersPerSecond, 1e-12),
              reason: e.id);
          expect(b.diameter.meters, a.diameter.meters, reason: e.id);
        }
      }
    });
  });
}
