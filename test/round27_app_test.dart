// Round 27 (2026-10-18) — the app half of the round-27 audit:
//
//   hvac-4-2   a nested room is sized ONCE: the outer room's airflow and
//              cooling load use its NET area (footprint less smaller rooms)
//   hvac-4-3   a drawn exhaust / supply network elsewhere never drops a room's
//              own schedule row — only a sized system reaching ITS terminals
//   hvac-4-4   a room trunk clamped over capacity is a Review warning
//   hvac-4-5   the Rooms inspector's grille face is the catalogue W x H
//   residuals-6  the Hunter curve per cold-water system in the live sizing
//   r3 (binding check-valve decision) — a hot-water check valve read as a
//              feed into a loop the heater already feeds is a locatable info
//              advisory (check-valve-feeds-ring:<id>), never re-interpreted
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart'
    show CheckValveAmbiguity;
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';

Future<(WidgetRef, ProviderContainer)> _harness(WidgetTester tester) async {
  late WidgetRef capturedRef;
  await tester.pumpWidget(
    ProviderScope(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Consumer)),
    listen: false,
  );
  return (capturedRef, container);
}

NetNode _n(String id, double x, double y,
        {NodeRole role = NodeRole.main,
        NodeComponent? c,
        FlowRate? airflow,
        PlumbingFixture? fixture,
        int floor = 0}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c,
        airflow: airflow,
        fixture: fixture);

void _seed(ProviderContainer c) {
  c.read(projectControllerProvider.notifier)
    ..setFloors(const [Floor('L0', Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
}

void main() {
  // ── hvac-4-2 ──────────────────────────────────────────────────────────────
  group('nested room — sized once (net area)', () {
    // Office (0,0)-(2000,1000) px at 0.01 m/px = 200 m2, 3.0 m, 6 ACH; a
    // meeting room (200,200)-(700,600) = 20 m2 inside it, 8 ACH.
    const office = RoomArea(
        id: 'office',
        sheetId: 's1',
        floorIndex: 0,
        ax: 0,
        ay: 0,
        bx: 2000,
        by: 1000,
        achOverride: 6);
    const meeting = RoomArea(
        id: 'meeting',
        sheetId: 's1',
        floorIndex: 0,
        ax: 200,
        ay: 200,
        bx: 700,
        by: 600,
        roomType: RoomType.meetingRoom,
        achOverride: 8);
    const rooms = [office, meeting];

    test('first principles: 180 x 3 x 6 / 3600 + 20 x 3 x 8 / 3600', () {
      expect(office.netAreaM2(0.01, rooms), closeTo(180, 1e-9));
      expect(meeting.netAreaM2(0.01, rooms), closeTo(20, 1e-9));
      final o = office.sizing(0.01, rooms: rooms)!;
      final m = meeting.sizing(0.01, rooms: rooms)!;
      expect(o.airflow.cubicMetersPerSecond, closeTo(0.9, 1e-12));
      expect(m.airflow.cubicMetersPerSecond, closeTo(20 * 3 * 8 / 3600, 1e-12));
      expect(o.airflow.cubicMetersPerSecond + m.airflow.cubicMetersPerSecond,
          closeTo(1.0333333333, 1e-9));
      // Without the room list the legacy gross basis (byte-identical).
      expect(office.sizing(0.01)!.airflow.cubicMetersPerSecond,
          closeTo(1.0, 1e-12));
    });

    test('cooling: the office cools 180 m2 (area-density rule)', () {
      final density = const SniVentilationProfile()
          .coolingLoadDensityBtuPerHrM2(RoomType.office)
          .value;
      final net = office.coolingLoad(0.01, rooms: rooms)!;
      final ref = estimateCoolingLoad(
        floorArea: const Area(180),
        ceilingHeight: const Length(3.0),
        densityBtuPerHrPerM2: density,
      );
      expect(net.btuPerHr, closeTo(ref.btuPerHr, 1e-9));
    });

    test('a room nested two deep is subtracted once (union of overlaps)', () {
      const inner = RoomArea(
          id: 'inner', sheetId: 's1', floorIndex: 0, ax: 300, ay: 300,
          bx: 400, by: 400);
      // 200 m2 - 20 m2 (meeting, which contains inner's 1 m2) = 180.
      expect(office.netAreaM2(0.01, [...rooms, inner]), closeTo(180, 1e-9));
      // The meeting room loses inner's 1 m2.
      expect(meeting.netAreaM2(0.01, [...rooms, inner]), closeTo(19, 1e-9));
      // A partial overlap is clipped to the overlap: (1900..2100) x (0..100)
      // overlaps the office on 100 x 100 px = 1 m2.
      const corner = RoomArea(
          id: 'corner', sheetId: 's1', floorIndex: 0, ax: 1900, ay: 0,
          bx: 2100, by: 100);
      expect(office.netAreaM2(0.01, [office, corner]), closeTo(199, 1e-9));
      // Another floor never subtracts.
      const above = RoomArea(
          id: 'above', sheetId: 's1', floorIndex: 1, ax: 200, ay: 200,
          bx: 700, by: 600);
      expect(office.netAreaM2(0.01, [office, above]), closeTo(200, 1e-9));
    });

    testWidgets('Auto-place: the two rooms place 1.0333 m3/s in total',
        (tester) async {
      final (_, c) = await _harness(tester);
      _seed(c);
      c.read(roomAreasProvider.notifier).set(rooms);
      final ctl = c.read(networkControllerProvider.notifier);
      ctl.autoPlaceRoomTerminals(room: office, metersPerPixel: 0.01);
      ctl.autoPlaceRoomTerminals(room: meeting, metersPerPixel: 0.01);
      var supply = 0.0;
      for (final n in c.read(networkControllerProvider).network.nodes) {
        if (n.component == NodeComponent.supplyDiffuser) {
          supply += n.airflow!.cubicMetersPerSecond;
        }
      }
      expect(supply, closeTo(0.9 + 20 * 3 * 8 / 3600, 1e-9));
    });
  });

  // ── hvac-4-3 ──────────────────────────────────────────────────────────────
  group('schedule rows follow the system that serves the room', () {
    // A piped toilet (exhaust grille -> exhaust fan) and a ductless 8 x 6 m
    // commercial kitchen beside it.
    const toilet = RoomArea(
        id: 'toilet',
        sheetId: 's1',
        floorIndex: 0,
        ax: 0,
        ay: 0,
        bx: 300,
        by: 300,
        roomType: RoomType.toilet);
    const kitchen = RoomArea(
        id: 'kitchen',
        sheetId: 's1',
        floorIndex: 0,
        ax: 1000,
        ay: 0,
        bx: 1800,
        by: 600,
        roomType: RoomType.commercialKitchen);

    testWidgets('the ductless kitchen keeps its exhaust-fan row',
        (tester) async {
      final (ref, c) = await _harness(tester);
      _seed(c);
      c.read(roomAreasProvider.notifier).set(const [toilet, kitchen]);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('g', 150, 150,
            role: NodeRole.fixture,
            c: NodeComponent.exhaustGrille,
            airflow: const FlowRate(0.05)),
        _n('ef', 150, 600, role: NodeRole.plant, c: NodeComponent.exhaustFan),
      ], edges: const [
        NetEdge(id: 'x', fromId: 'g', toId: 'ef', service: ServiceType.exhaust),
      ]));
      await tester.pump();
      final fans = gatherEquipmentScheduleData(ref).fans;
      final kitchenRow =
          fans.where((f) => f.service == kitchen.name).toList();
      // The kitchen's own extract duty: 8 x 6 x 3.0 x ACH / 3600.
      final k = kitchen.sizing(0.01, rooms: const [toilet, kitchen])!;
      expect(kitchenRow, hasLength(1));
      expect(kitchenRow.single.duty.airflow.cubicMetersPerSecond,
          closeTo(k.airflow.cubicMetersPerSecond, 1e-12));
      expect(kitchenRow.single.tag, startsWith('EF-R'));
      // The piped toilet is served by its drawn system: no room row.
      expect(
          roomServedByDrawnAir(toilet, const [toilet, kitchen],
              c.read(networkControllerProvider).network,
              c.read(sizingProvider).keys.toSet(),
              extract: true),
          isTrue);
      expect(
          roomServedByDrawnAir(kitchen, const [toilet, kitchen],
              c.read(networkControllerProvider).network,
              c.read(sizingProvider).keys.toSet(),
              extract: true),
          isFalse);
    });
  });

  // ── hvac-4-4 ──────────────────────────────────────────────────────────────
  testWidgets('a room trunk over capacity is a Review warning', (tester) async {
    final (_, c) = await _harness(tester);
    c.read(projectControllerProvider.notifier)
      ..setFloors(const [Floor('L0', Length(10))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    // 40 x 30 m = 1200 m2 atrium, 10 m ceiling, 6 ACH: 20 m3/s.
    const atrium = RoomArea(
        id: 'atrium',
        sheetId: 's1',
        floorIndex: 0,
        ax: 0,
        ay: 0,
        bx: 4000,
        by: 3000,
        ceilingHeightM: 10,
        achOverride: 6,
        name: 'Atrium');
    c.read(roomAreasProvider.notifier).set(const [atrium]);
    await tester.pump();
    expect(atrium.sizing(0.01)!.trunkOverCapacity, isTrue);
    final issues = c.read(designIssuesProvider);
    expect(issues.map((i) => i.kind),
        contains('room-trunk-over-capacity:atrium'));
  });

  // ── hvac-4-5 ──────────────────────────────────────────────────────────────
  test('the bank face is the catalogue W x H Auto-place stamps', () {
    // 20 m2 x 3 m x 6 ACH = 0.1 m3/s on one diffuser: 200x200 carries
    // 0.04 x 0.8 x 3 = 0.096 < 0.1, so 300x150 (0.045 m2) is chosen.
    const room = RoomArea(
        id: 'r', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 500,
        by: 400, achOverride: 6);
    final s = room.sizing(0.01)!;
    expect(s.supply.count, 1);
    expect(s.supply.faceMm, (300.0, 150.0));
    expect(standardGrilleFaceForGrossArea(const Area(0.045)), (300.0, 150.0));
  });

  // ── residuals-6 ───────────────────────────────────────────────────────────
  testWidgets('a flush-valve WC on its own system keeps the other on tanks',
      (tester) async {
    final (_, c) = await _harness(tester);
    _seed(c);
    NetEdge cw(String id, String a, String b) => NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.coldWater);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('A', 0, 0, role: NodeRole.plant),
      for (var i = 0; i < 4; i++)
        _n('fx$i', 100.0 + 50 * i, 0,
            role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
      _n('B', 1000, 0, role: NodeRole.plant),
      _n('wc', 1100, 0,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.waterClosetFlushValve),
    ], edges: [
      cw('a0', 'A', 'fx0'),
      cw('a1', 'fx0', 'fx1'),
      cw('a2', 'fx1', 'fx2'),
      cw('a3', 'fx2', 'fx3'),
      cw('bw', 'B', 'wc'),
    ]));
    await tester.pump();
    final s = c.read(sizingProvider);
    final fu = c.read(edgeFixtureUnitsProvider);
    const sni = SniProfile();
    // The lavatory system is on the TANK curve of its own accumulated UBAP.
    expect(
        s['a0']!.flow.inLitersPerSecond,
        closeTo(
            sni
                .probableFlowForFixtureUnits(fu['a0']!,
                    system: FlushSystem.flushTank)
                .inLitersPerSecond,
            1e-9));
    // The toilet core is on the VALVE curve.
    expect(
        s['bw']!.flow.inLitersPerSecond,
        closeTo(
            sni
                .probableFlowForFixtureUnits(fu['bw']!,
                    system: FlushSystem.flushValve)
                .inLitersPerSecond,
            1e-9));
  });

  // ── r3 — the check-valve feed advisory ────────────────────────────────────
  group('check-valve-feeds-ring advisory (hot water)', () {
    // H -> S0 -> S1 supply riser with a fixture at each floor; S1 -> R1 ->
    // R0 return riser -> CV -> H. [backwards] draws the valve H -> CV -> R0:
    // the drawn arrow points AWAY from the heater, so it is sized as a feed
    // (and named); drawn R0 -> CV -> H it is a return (zero, no advisory).
    Network hotel({required bool backwards, bool ambiguous = false}) {
      NetEdge hw(String id, String a, String b,
              {EdgeKind k = EdgeKind.run}) =>
          NetEdge(
              id: id, fromId: a, toId: b, service: ServiceType.hotWater,
              kind: k);
      return Network(nodes: [
        _n('H', 0, 0, role: NodeRole.plant),
        _n('S0', 100, 0),
        _n('S1', 100, 0, floor: 1),
        _n('f0', 200, 0, role: NodeRole.fixture),
        _n('f1', 200, 0, role: NodeRole.fixture, floor: 1),
        _n('R1', 50, 0, floor: 1),
        _n('R0', 50, 0),
        _n('CV', 20, 0, c: NodeComponent.checkValve),
      ], edges: [
        hw('hs', 'H', 'S0'),
        hw('s1', 'S0', 'S1', k: EdgeKind.riser),
        hw('b0', 'S0', 'f0'),
        hw('b1', 'S1', 'f1'),
        hw('top', 'S1', 'R1'),
        hw('r1', 'R1', 'R0', k: EdgeKind.riser),
        if (ambiguous) ...[
          hw('rc', 'R0', 'CV'),
          hw('ch', 'H', 'CV'),
        ] else if (backwards) ...[
          hw('ch', 'H', 'CV'),
          hw('cr', 'CV', 'R0'),
        ] else ...[
          hw('rc', 'R0', 'CV'),
          hw('ch', 'CV', 'H'),
        ],
      ]);
    }

    testWidgets('a return drawn backwards is sized as drawn + named',
        (tester) async {
      final (_, c) = await _harness(tester);
      c.read(projectControllerProvider.notifier).setFloors(const [
        Floor('L0', Length(3.0)),
        Floor('L1', Length(3.0)),
      ]);
      c.read(networkControllerProvider.notifier)
          .loadNetwork(hotel(backwards: true));
      await tester.pump();
      expect(c.read(checkValveFeedsRingProvider), {'CV'});
      final s = c.read(sizingProvider);
      expect(s['ch']!.flow.inLitersPerSecond, greaterThan(0));
      expect(s['ch']!.flowFromId, 'H');
      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'check-valve-feeds-ring:CV');
      expect(issue.severity, IssueSeverity.info);
      expect(issue.locate?.nodeId, 'CV');
      expect(issue.locate?.sheetId, 's1');
    });

    testWidgets('the correctly drawn return: zero flow, no advisory',
        (tester) async {
      final (_, c) = await _harness(tester);
      c.read(projectControllerProvider.notifier).setFloors(const [
        Floor('L0', Length(3.0)),
        Floor('L1', Length(3.0)),
      ]);
      c.read(networkControllerProvider.notifier)
          .loadNetwork(hotel(backwards: false));
      await tester.pump();
      expect(c.read(checkValveFeedsRingProvider), isEmpty);
      expect(c.read(sizingProvider)['ch']!.flow.inLitersPerSecond, 0);
      expect(
          c.read(designIssuesProvider).map((i) => i.kind),
          isNot(contains(startsWith('check-valve-feeds-ring'))));
    });

    // r5 (binding rule) — a valve with NO drawn direction (both pipes drawn
    // into it) is read as a closed return (zero draw-off) and named, never
    // as a feed.
    testWidgets('an ambiguously drawn valve: closed return + locatable advisory',
        (tester) async {
      final (_, c) = await _harness(tester);
      c.read(projectControllerProvider.notifier).setFloors(const [
        Floor('L0', Length(3.0)),
        Floor('L1', Length(3.0)),
      ]);
      c.read(networkControllerProvider.notifier)
          .loadNetwork(hotel(backwards: false, ambiguous: true));
      await tester.pump();
      expect(c.read(checkValveAmbiguousProvider),
          {'CV': CheckValveAmbiguity.closedReturn});
      expect(c.read(checkValveFeedsRingProvider), isEmpty);
      expect(c.read(sizingProvider)['ch']!.flow.inLitersPerSecond, 0);
      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'check-valve-ambiguous:CV');
      expect(issue.severity, IssueSeverity.info);
      expect(issue.locate?.nodeId, 'CV');
      expect(issue.locate?.sheetId, 's1');
      expect(issue.title, 'Check valve has no drawn flow direction');
      expect(issue.message, contains('CLOSED'));
    });

    // r6 (binding refinement) — a valve on a pump's leg is never closed: an
    // ambiguous one is a feed away from the source, and one DRAWN back at its
    // own pump is read as a feed and named with its own title.
    testWidgets('a valve on a pump leg: never closed, named as a supply leg',
        (tester) async {
      Network pumpBypass({required bool back}) {
        NetEdge cw(String id, String a, String b) => NetEdge(
            id: id, fromId: a, toId: b, service: ServiceType.coldWater);
        return Network(nodes: [
          _n('T', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
          _n('P', 30, -30, role: NodeRole.plant, c: NodeComponent.pump),
          _n('CV', 60, -30, c: NodeComponent.checkValve),
          _n('J', 90, 0),
          _n('f0', 150, 0, role: NodeRole.fixture),
          _n('f1', 150, 30, role: NodeRole.fixture),
        ], edges: [
          cw('tp', 'T', 'P'),
          if (back) ...[cw('pc', 'CV', 'P'), cw('jc', 'J', 'CV')],
          if (!back) ...[cw('pc', 'P', 'CV'), cw('jc', 'J', 'CV')],
          cw('tj', 'T', 'J'),
          cw('b0', 'J', 'f0'),
          cw('b1', 'J', 'f1'),
        ]);
      }

      final (_, c) = await _harness(tester);
      for (final back in [false, true]) {
        c.read(networkControllerProvider.notifier)
            .loadNetwork(pumpBypass(back: back));
        await tester.pump();
        expect(c.read(checkValveAmbiguousProvider), {
          'CV': back
              ? CheckValveAmbiguity.drawnAgainstSupplyLeg
              : CheckValveAmbiguity.supplyLeg,
        });
        final s = c.read(sizingProvider);
        expect(s['pc']!.flow.inLitersPerSecond, greaterThan(0));
        expect(s['jc']!.flowFromId, 'CV');
        final issue = c
            .read(designIssuesProvider)
            .firstWhere((i) => i.kind == 'check-valve-ambiguous:CV');
        expect(issue.locate?.nodeId, 'CV');
        expect(
            issue.title,
            back
                ? 'Check valve drawn against its supply leg'
                : 'Check valve has no drawn flow direction');
        expect(issue.message, contains('FEED'));
      }
    });

    // r7 (binding orchestrator decision) — two undecided root chains are
    // sized on the ENVELOPE (named), and a pump leg the balance runs against
    // stays open in the pump's direction (named on the same kind with its
    // own message).
    testWidgets('envelope + balance-against-pump advisories', (tester) async {
      NetEdge hw(String id, String a, String b,
              {EdgeKind k = EdgeKind.run}) =>
          NetEdge(
              id: id, fromId: a, toId: b, service: ServiceType.hotWater,
              kind: k);
      final both = Network(nodes: [
        _n('H', 0, 0, role: NodeRole.plant),
        _n('CVd', 20, 0, c: NodeComponent.checkValve),
        _n('S0', 100, 0),
        _n('S1', 100, 0, floor: 1),
        _n('f0', 200, 0, role: NodeRole.fixture),
        _n('f1', 200, 0, role: NodeRole.fixture, floor: 1),
        _n('R1', 50, 0, floor: 1),
        _n('R0', 50, 0),
        _n('CV', 20, 20, c: NodeComponent.checkValve),
      ], edges: [
        hw('hc', 'H', 'CVd'),
        hw('cs', 'S0', 'CVd'),
        hw('s1', 'S0', 'S1', k: EdgeKind.riser),
        hw('b0', 'S0', 'f0'),
        hw('b1', 'S1', 'f1'),
        hw('top', 'S1', 'R1'),
        hw('r1', 'R1', 'R0', k: EdgeKind.riser),
        hw('rc', 'R0', 'CV'),
        hw('ch', 'H', 'CV'),
      ]);
      final (_, c) = await _harness(tester);
      c.read(projectControllerProvider.notifier).setFloors(const [
        Floor('L0', Length(3.0)),
        Floor('L1', Length(3.0)),
      ]);
      c.read(networkControllerProvider.notifier).loadNetwork(both);
      await tester.pump();
      expect(c.read(checkValveAmbiguousProvider), {
        'CV': CheckValveAmbiguity.envelope,
        'CVd': CheckValveAmbiguity.envelope,
      });
      final env = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'check-valve-ambiguous:CVd');
      expect(env.title, 'Check valve direction unclear at the source');
      expect(env.message, contains('sized for every plausible flow direction'));
      expect(env.locate?.nodeId, 'CVd');

      NetEdge cw(String id, String a, String b) =>
          NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('T', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('R0', 20, 0),
        _n('R1', 420, 0),
        _n('R2', 20, 20),
        _n('R3', 20, 40),
        _n('P', 220, 40, role: NodeRole.plant, c: NodeComponent.pump),
        _n('CV', 120, 40, c: NodeComponent.checkValve),
        _n('f1', 440, 0, role: NodeRole.fixture),
        _n('f3', 0, 40, role: NodeRole.fixture),
      ], edges: [
        cw('t0', 'T', 'R0'),
        cw('r01', 'R0', 'R1'),
        cw('r02', 'R0', 'R2'),
        cw('r23', 'R2', 'R3'),
        cw('r1p', 'R1', 'P'),
        cw('pc', 'P', 'CV'),
        cw('c3', 'CV', 'R3'),
        cw('b1', 'R1', 'f1'),
        cw('b3', 'R3', 'f3'),
      ]));
      await tester.pump();
      expect(c.read(checkValveAmbiguousProvider),
          {'CV': CheckValveAmbiguity.balanceAgainstPump});
      final s = c.read(sizingProvider);
      expect(s['pc']!.flow.inLitersPerSecond, greaterThan(0));
      expect(s['c3']!.flowFromId, 'CV');
      final pump = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'check-valve-ambiguous:CV');
      expect(pump.title, 'Balance runs against the drawn pump');
      expect(pump.locate?.nodeId, 'CV');
    });
  });
}
