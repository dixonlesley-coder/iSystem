// Round 27 (2026-10-18) — the app half of the round-27 audit:
//
//   hvac-4-2   a nested room is sized ONCE: the outer room's airflow and
//              cooling load use its NET area (footprint less smaller rooms)
//   hvac-4-3   a drawn exhaust / supply network elsewhere never drops a room's
//              own schedule row — only a sized system reaching ITS terminals
//   hvac-4-4   a room trunk clamped over capacity is a Review warning
//   hvac-4-5   the Rooms inspector's grille face is the catalogue W x H
//   residuals-6  the Hunter curve per cold-water system in the live sizing
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
}
