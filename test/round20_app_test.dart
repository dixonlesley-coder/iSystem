// Round 20 (2026-10-18) — the app half of the round-20 audit:
//
//   autoplace-nested     a meeting room nested in an office (same air kind):
//                        re-running Auto-place never stacks terminals, the
//                        stale judge counts each terminal in its generating
//                        room, and the tag round-trips in .mechx
//   lighting-kind        re-kinding a way re-derives its lighting flag
//   report-feed          the calc report describes the DRAWN feed (no
//                        phantom roof-tank booster head / PRV zone table)
//   ac-owner             an AC unit belongs to its smallest room: the fed PK
//                        is independent of the room draw order
//   room-air-units       a drawn AHU/FCU is scheduled once, and an unpiped one
//                        is fed its room-air duty, never the component default
//   report-fan           the report's HVAC trunk is a scheduled machine, never
//                        a packaged AC's internal fan
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart' show buildDocument;
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sample_project.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
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
        FlowRate? airflow}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: c,
        airflow: airflow);

NetEdge _duct(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.duct);

void _seedBuilding(ProviderContainer c) {
  c.read(projectControllerProvider.notifier)
    ..setFloors(const [Floor('L0', Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
}

void main() {
  // ── autoplace-nested ──────────────────────────────────────────────────────
  group('Auto-place: a meeting room nested in an office (same kind)', () {
    // 20 × 10 m office (0,0)-(2000,1000) px at 0.01 m/px; a 4 × 4 m meeting
    // room (300,300)-(700,700) inside it — BOTH conditioned, so geometry
    // alone gives any office terminal landing in (300..700)² to the meeting
    // room (the smaller compatible room).
    const office = RoomArea(
        id: 'office', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 2000,
        by: 1000);
    const meeting = RoomArea(
        id: 'meeting',
        sheetId: 's1',
        floorIndex: 0,
        ax: 300,
        ay: 300,
        bx: 700,
        by: 700,
        roomType: RoomType.meetingRoom);

    ProviderContainer setUp() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seedBuilding(c);
      c.read(roomAreasProvider.notifier).set(const [office, meeting]);
      return c;
    }

    double carried(ProviderContainer c, NodeComponent comp) => c
        .read(networkControllerProvider)
        .network
        .nodes
        .where((n) => n.component == comp)
        .fold(0.0, (s, n) => s + n.airflow!.cubicMetersPerSecond);
    bool stale(ProviderContainer c, String id) => c
        .read(designIssuesProvider)
        .any((i) => i.kind == 'room-terminals-stale:$id');

    test('placing office, meeting, office again: totals stay at the sizing',
        () {
      final c = setUp();
      final net = c.read(networkControllerProvider.notifier);
      // Round 27 (hvac-4-2) — each room on its NET area: the office's 200 m2
      // less the nested meeting room's 16 m2 (the meeting room is sized once).
      const rooms = [office, meeting];
      final sOffice = office.sizing(0.01, rooms: rooms)!;
      final sMeeting = meeting.sizing(0.01, rooms: rooms)!;
      expect(office.netAreaM2(0.01, rooms), closeTo(200 - 16, 1e-9));
      // Each room's required supply = count × airflowEach (the bank).
      final reqSupply = sOffice.supply.count *
              sOffice.supply.airflowEach.cubicMetersPerSecond +
          sMeeting.supply.count *
              sMeeting.supply.airflowEach.cubicMetersPerSecond;
      final reqReturn = sOffice.return_.count *
              sOffice.return_.airflowEach.cubicMetersPerSecond +
          sMeeting.return_.count *
              sMeeting.return_.airflowEach.cubicMetersPerSecond;

      net.autoPlaceRoomTerminals(room: office, metersPerPixel: 0.01);
      // No office terminal is dropped inside the nested meeting room.
      for (final n in c.read(networkControllerProvider).network.nodes) {
        expect(meeting.containsNode(n.sheetId, n.floorIndex, n.x, n.y),
            isFalse,
            reason: 'office terminal ${n.id} at (${n.x}, ${n.y})');
        expect(n.autoPlacedRoomId, 'office');
      }
      net.autoPlaceRoomTerminals(room: meeting, metersPerPixel: 0.01);
      net.autoPlaceRoomTerminals(room: office, metersPerPixel: 0.01);
      net.autoPlaceRoomTerminals(room: office, metersPerPixel: 0.01);
      expect(carried(c, NodeComponent.supplyDiffuser), closeTo(reqSupply, 1e-9));
      expect(carried(c, NodeComponent.returnGrille), closeTo(reqReturn, 1e-9));
      expect(stale(c, 'office'), isFalse);
      expect(stale(c, 'meeting'), isFalse);
    });

    test('the generating-room tag wins only outside a nested same-kind room',
        () {
      // Round 21 — a tagged office terminal still inside the office (and in
      // no nested room) stays the office's; one that a LATER-drawn meeting
      // room now contains is the meeting room's (so the meeting room's
      // Auto-place replaces it and the office goes stale), exactly like a
      // hand-placed (untagged) one.
      const rooms = [office, meeting];
      final tagged = _n('t', 500, 500, c: NodeComponent.supplyDiffuser)
          .copyWith(autoPlacedRoomId: 'office');
      final hand = _n('h', 500, 500, c: NodeComponent.supplyDiffuser);
      expect(roomTerminalOwnerOf(tagged, rooms), 'meeting');
      expect(roomTerminalOwnerOf(hand, rooms), 'meeting');
      final outside = tagged.copyWith(x: 1500);
      expect(roomTerminalOwnerOf(outside, rooms), 'office');
      // Dragged OUT of its generating room ⇒ the geometric owner again.
      final moved = tagged.copyWith(x: 2500);
      expect(roomTerminalOwnerOf(moved, rooms), isNull);
    });

    test('the generating-room tag round-trips in .mechx (tolerant)', () {
      final c = setUp();
      c.read(networkControllerProvider.notifier)
          .autoPlaceRoomTerminals(room: office, metersPerPixel: 0.01);
      final back = ProjectDocument.decode(buildDocument(c.read).encode());
      expect(back.network.nodes.map((n) => n.autoPlacedRoomId).toSet(),
          {'office'});
    });
  });

  // ── lighting-kind ─────────────────────────────────────────────────────────
  group('re-kinding a way re-derives its lighting flag', () {
    test('socket -> lighting -> motor; an explicit flag in the edit wins', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(electricalProjectProvider.notifier)
          .setProject(sampleElectricalProject());
      final ctrl = c.read(electricalProjectProvider.notifier);
      final id = ctrl.addCircuit('mdp', kind: LoadKind.socket, loadW: 2000);
      bool lighting() => c
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == 'mdp')
          .circuits
          .firstWhere((x) => x.id == id)
          .isLighting;
      expect(lighting(), isFalse);
      ctrl.setCircuit('mdp', id, loadKind: LoadKind.lighting);
      expect(lighting(), isTrue, reason: 'judged against the 3 % limit');
      ctrl.setCircuit('mdp', id, loadKind: LoadKind.motor);
      expect(lighting(), isFalse, reason: 'no longer over-tightened to 3 %');
      // The toggle stays an override in the SAME edit and afterwards.
      ctrl.setCircuit('mdp', id, loadKind: LoadKind.lighting, isLighting: false);
      expect(lighting(), isFalse);
      ctrl.setCircuit('mdp', id, isLighting: true);
      expect(lighting(), isTrue);
      // An edit that does not change the kind leaves the flag alone.
      ctrl.setCircuit('mdp', id, isLighting: false);
      ctrl.setCircuit('mdp', id, loadKind: LoadKind.lighting, loadW: 1500);
      expect(lighting(), isFalse);
    });
  });

  // ── report-feed ───────────────────────────────────────────────────────────
  group('the calc report describes the drawn feed', () {
    testWidgets('sample (water meter, no tank/pump) ⇒ direct mains, no booster',
        (tester) async {
      final (ref, c) = await _harness(tester);
      loadSampleLayoutProjectTo(c.read);
      expect(c.read(feedStrategyProvider), FeedStrategy.downfeed);
      await tester.pump();
      final data = buildMechanicalReportData(ref);
      expect(data.feedStrategy, 'Direct mains');
      expect(data.boosterHead, isNull);
      expect(data.gravitySufficient, isFalse);
      expect(data.zones, isEmpty);
    });

    testWidgets('a drawn roof tank keeps the downfeed design', (tester) async {
      final (ref, c) = await _harness(tester);
      loadSampleLayoutProjectTo(c.read);
      final net = c.read(networkControllerProvider).network;
      final meter =
          net.nodes.firstWhere((n) => n.component == NodeComponent.waterMeter);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(
            nodes: [
              for (final n in net.nodes)
                n.id == meter.id
                    ? n.copyWith(
                        component: NodeComponent.roofTank,
                        role: NodeRole.plant)
                    : n,
            ],
            edges: net.edges,
          ));
      await tester.pump();
      final data = buildMechanicalReportData(ref);
      expect(data.feedStrategy, 'Roof-tank downfeed');
      final d = c.read(downfeedProvider);
      expect(data.boosterHead, d?.boosterHeadRequired);
    });
  });

  // ── ac-owner ──────────────────────────────────────────────────────────────
  group('an AC unit belongs to its smallest room', () {
    // Office 20 × 10 m with two cassettes; a 5 × 4 m meeting room nested in
    // it with one cassette.
    const office = RoomArea(
        id: 'office', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 2000,
        by: 1000);
    const meeting = RoomArea(
        id: 'meeting',
        sheetId: 's1',
        floorIndex: 0,
        ax: 200,
        ay: 200,
        bx: 700,
        by: 600,
        roomType: RoomType.meetingRoom);
    final net = Network(nodes: [
      _n('o1', 1200, 500, role: NodeRole.plant, c: NodeComponent.acCassette),
      _n('o2', 1700, 500, role: NodeRole.plant, c: NodeComponent.acCassette),
      _n('m1', 450, 400, role: NodeRole.plant, c: NodeComponent.acCassette),
    ], edges: const []);

    Map<String, NodeFedLoad> fed(List<RoomArea> rooms) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seedBuilding(c);
      c.read(roomAreasProvider.notifier).set(rooms);
      c.read(networkControllerProvider.notifier).loadNetwork(net);
      return c.read(nodeFedLoadsProvider);
    }

    // The feed: per-unit share of the OWNING room's cooling, input = the
    // selected unit's nominal (or the real requirement above 3 PK) ÷ COP.
    // Round 27 (hvac-4-2) — on the room's NET area (the office cools its
    // 200 m2 less the nested meeting room's 20 m2).
    double expectedInput(RoomArea room, int units) {
      final perUnit = room.coolingLoad(0.01, rooms: const [office, meeting])!
              .btuPerHr /
          units;
      final sel = selectAc(perUnit);
      return acInputPowerW(
          coolingBtuPerHr: sel.exceedsRange ? perUnit : sel.nominalBtuPerHr);
    }

    test('both draw orders feed the same watts, split per owning room', () {
      final a = fed(const [office, meeting]);
      final b = fed(const [meeting, office]);
      for (final id in ['o1', 'o2', 'm1']) {
        expect(a[id]!.source, NodeLoadSource.roomPk);
        expect(a[id]!.watts, closeTo(b[id]!.watts, 1e-9), reason: id);
      }
      // The office's load splits over ITS two units (the nested unit is the
      // meeting room's), the meeting room's over its one.
      expect(a['o1']!.watts, closeTo(expectedInput(office, 2), 1e-6));
      expect(a['m1']!.watts, closeTo(expectedInput(meeting, 1), 1e-6));
    });
  });

  // ── room-air-units ────────────────────────────────────────────────────────
  group('drawn AHU / FCU: one schedule row, one machine on the panel', () {
    // 10 × 8 m office (0,0)-(1000,800) px.
    const room = RoomArea(
        id: 'r0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1000,
        by: 800);

    testWidgets('an FCU rooting two diffusers is scheduled ONCE',
        (tester) async {
      final (ref, c) = await _harness(tester);
      _seedBuilding(c);
      c.read(roomAreasProvider.notifier).set(const [room]);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('fcu', 500, 400, role: NodeRole.plant, c: NodeComponent.fcu),
        _n('j', 600, 400),
        _n('d1', 700, 300,
            role: NodeRole.fixture,
            c: NodeComponent.supplyDiffuser,
            airflow: const FlowRate(0.12)),
        _n('d2', 700, 500,
            role: NodeRole.fixture,
            c: NodeComponent.supplyDiffuser,
            airflow: const FlowRate(0.12)),
      ], edges: [
        _duct('a', 'fcu', 'j'),
        _duct('b', 'j', 'd1'),
        _duct('c', 'j', 'd2'),
      ]));
      await tester.pump();
      expect(c.read(roomAirUnitDutiesProvider), isEmpty);
      final fans = gatherEquipmentScheduleData(ref).fans;
      final tags = [for (final f in fans) f.tag];
      expect(tags.toSet().length, tags.length, reason: 'duplicate tag: $tags');
      expect(fans, hasLength(1));
      // The one row is the SOLVED duct duty the panel way is fed from.
      expect(c.read(nodeFedLoadsProvider)['fcu']!.source,
          NodeLoadSource.solvedDuty);
    });

    testWidgets('an unpiped AHU is fed its room-air duty', (tester) async {
      final (ref, c) = await _harness(tester);
      _seedBuilding(c);
      c.read(roomAreasProvider.notifier).set(const [room]);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('ahu', 500, 400, role: NodeRole.plant, c: NodeComponent.ahu),
      ], edges: const []));
      await tester.pump();
      final duty = room.sizing(0.01)!.equipment;
      final f = c.read(nodeFedLoadsProvider)['ahu']!;
      expect(f.source, NodeLoadSource.roomAir);
      // The motor the schedule prints, input on the nameplate basis — never
      // the 5.5 kW component default.
      expect(f.watts, duty.selectedMotor.watts);
      expect(
          f.input,
          MepEquipmentLoad.nameplateInput(duty.motorInputPower,
                  duty.selectedMotor, defaultMotorEfficiency)
              .watts);
      expect(f.watts, lessThan(NodeComponent.ahu.defaultMotorKw * 1000));
      final row = gatherEquipmentScheduleData(ref).fans.single;
      expect(identical(row.duty, duty) || row.duty.selectedMotor == duty.selectedMotor,
          isTrue);
    });
  });

  // ── report-fan ────────────────────────────────────────────────────────────
  testWidgets('report fan: the scheduled AHU, never a packaged AC fan',
      (tester) async {
    final (ref, c) = await _harness(tester);
    _seedBuilding(c);
    // AHU → one 0.5 m3/s diffuser; a ducted AC → two 0.5 m3/s diffusers (the
    // larger, PRIMARY system by airflow).
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('ahu', 0, 0, role: NodeRole.plant, c: NodeComponent.ahu),
      _n('da', 300, 0,
          role: NodeRole.fixture,
          c: NodeComponent.supplyDiffuser,
          airflow: const FlowRate(0.5)),
      _n('ac', 0, 1000, role: NodeRole.plant, c: NodeComponent.acDucted),
      _n('j', 300, 1000),
      _n('d1', 600, 900,
          role: NodeRole.fixture,
          c: NodeComponent.supplyDiffuser,
          airflow: const FlowRate(0.5)),
      _n('d2', 600, 1100,
          role: NodeRole.fixture,
          c: NodeComponent.supplyDiffuser,
          airflow: const FlowRate(0.5)),
    ], edges: [
      _duct('a1', 'ahu', 'da'),
      _duct('c1', 'ac', 'j'),
      _duct('c2', 'j', 'd1'),
      _duct('c3', 'j', 'd2'),
    ]));
    await tester.pump();
    final ahuDuty = c.read(supplyFanDutiesByRootProvider)['ahu'];
    expect(ahuDuty, isNotNull);
    final data = buildMechanicalReportData(ref);
    expect(identical(data.fan, ahuDuty), isTrue);
    expect(data.fan!.airflow.cubicMetersPerSecond, closeTo(0.5, 1e-9));
  });
}
