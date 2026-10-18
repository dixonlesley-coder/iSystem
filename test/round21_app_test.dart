// Round 21 (2026-10-18) — the app half of the round-21 audit:
//
//   autoplace-outer-first  a room drawn inside an already-auto-placed room
//                          takes the outer room's terminal that now sits in
//                          it; the outer room goes STALE (never silent 5.7x)
//   gridcells-spread       a blocked grid cell is substituted by its nearest
//                          free cell; the rest of the legacy grid stays put
//   fire-riser-count       two drawn hydrant stacks rate the pump at 750 gpm
//   parallel-fire-pumps    duty / standby / jockey: the standby adds no
//                          demand, the jockey is fed its own small duty, the
//                          schedule lists every drawn fire pump
//   fire-motor-oversized   a fire pump past the 315 kW ladder top is a Review
//                          advisory and its way sizes on the governing input
//   riser-hwr-export       the issued riser carries the HWR return leg
//   fire-verify-items      the 690 kPa residual only with a standpipe drawn
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/schematic/schematic_export.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
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
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c,
        fixture: fixture);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.fireHydrant,
        EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

void _seed(ProviderContainer c, {int floors = 1, double h = 3.5}) {
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < floors; i++) Floor('L$i', Length(h))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
}

void main() {
  // ── autoplace-outer-first + gridcells-spread ──────────────────────────────
  group('Auto-place with a nested meeting room', () {
    // 20 × 10 m office (0,0)-(2000,1000) px at 0.01 m/px; a 4 × 4 m meeting
    // room (300,300)-(700,700) inside it (both conditioned).
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

    double supplyInside(ProviderContainer c, RoomArea r) => c
        .read(networkControllerProvider)
        .network
        .nodes
        .where((n) =>
            n.component == NodeComponent.supplyDiffuser &&
            r.containsNode(n.sheetId, n.floorIndex, n.x, n.y))
        .fold(0.0, (s, n) => s + n.airflow!.cubicMetersPerSecond);
    bool stale(ProviderContainer c, String id) => c
        .read(designIssuesProvider)
        .any((i) => i.kind == 'room-terminals-stale:$id');

    test('outer room first, nested room drawn later: no silent double air',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c);
      final net = c.read(networkControllerProvider.notifier);
      final sMeeting = meeting.sizing(0.01)!;
      final reqMeeting = sMeeting.supply.count *
          sMeeting.supply.airflowEach.cubicMetersPerSecond;
      // 1. The office alone: its legacy grid drops a diffuser at (500,500).
      c.read(roomAreasProvider.notifier).set(const [office]);
      net.autoPlaceRoomTerminals(room: office, metersPerPixel: 0.01);
      // 2. The meeting room is drawn around that point and auto-placed.
      c.read(roomAreasProvider.notifier).set(const [office, meeting]);
      net.autoPlaceRoomTerminals(room: meeting, metersPerPixel: 0.01);
      // The meeting room carries exactly its own design supply (the office's
      // diffuser it now contained was replaced, not stacked on) …
      expect(supplyInside(c, meeting), closeTo(reqMeeting, 1e-9));
      // … and the office, now one diffuser short, is flagged stale.
      expect(stale(c, 'office'), isTrue);
      expect(stale(c, 'meeting'), isFalse);
      // Re-running the office restores it, still never inside the meeting.
      net.autoPlaceRoomTerminals(room: office, metersPerPixel: 0.01);
      expect(stale(c, 'office'), isFalse);
      expect(supplyInside(c, meeting), closeTo(reqMeeting, 1e-9));
    });

    test('a blocked grid cell moves to its nearest free cell; the rest stay',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c);
      c.read(roomAreasProvider.notifier).set(const [office, meeting]);
      final s = office.sizing(0.01)!;
      // Precondition (the audit's probe): a 2-diffuser bank ⇒ legacy grid
      // cols = ceil(√2) = 2, rows = 1 ⇒ (500,500) and (1500,500).
      expect(s.supply.count, 2);
      c
          .read(networkControllerProvider.notifier)
          .autoPlaceRoomTerminals(room: office, metersPerPixel: 0.01);
      final pts = {
        for (final n in c.read(networkControllerProvider).network.nodes)
          if (n.component == NodeComponent.supplyDiffuser)
            '${n.x.toStringAsFixed(1)},${n.y.toStringAsFixed(1)}',
      };
      // (500,500) is inside the meeting room. The 3 × 2 grid's free cells
      // nearest it are (333.3,250) and (333.3,750), both at
      // √(166.7² + 250²) = 300.5 px; row-major tie ⇒ (333.3,250). The second
      // legacy cell (1500,500) is free and stays — the bank still spans the
      // room instead of crowding the top row at x = 3.3 m and 10 m.
      expect(pts, {'333.3,250.0', '1500.0,500.0'});
    });
  });

  // ── fire-riser-count ──────────────────────────────────────────────────────
  test('two drawn hydrant stacks rate the standpipe at 750 gpm', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    _seed(c, floors: 4);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('H', 50, 0),
      for (final s in ['A', 'B'])
        for (var f = 0; f < 4; f++) _n('$s$f', s == 'A' ? 100 : 300, 0, floor: f),
    ], edges: [
      _e('p', 'P', 'H'),
      for (final s in ['A', 'B']) ...[
        _e('h$s', 'H', '${s}0'),
        for (var f = 0; f < 3; f++)
          _e('$s$f', '$s$f', '$s${f + 1}', k: EdgeKind.riser),
      ],
    ]));
    // 500 + 250 gpm = 750 gpm × 3.785411784 / 60 = 47.32 L/s.
    expect(c.read(standpipeDesignProvider).requiredFlow.inLitersPerSecond,
        closeTo(750 * 3.785411784 / 60, 1e-9));
    expect(c.read(firePumpDutyProvider)!.flow.inLitersPerSecond,
        closeTo(750 * 3.785411784 / 60, 1e-9));
  });

  // ── parallel-fire-pumps ───────────────────────────────────────────────────
  group('a duty + standby + jockey fire pump room', () {
    // GT → suction header S → FP1 / FP2 / FP3 → discharge header D → riser.
    Network room() => Network(nodes: [
          _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
          _n('S', 100, 0),
          for (var i = 1; i <= 3; i++)
            _n('FP$i', 200, i * 50.0, role: NodeRole.plant,
                c: NodeComponent.pump),
          _n('D', 300, 0),
          _n('R1', 300, 0, floor: 1),
        ], edges: [
          _e('g', 'GT', 'S'),
          for (var i = 1; i <= 3; i++) ...[
            _e('s$i', 'S', 'FP$i'),
            _e('d$i', 'FP$i', 'D'),
          ],
          _e('r', 'D', 'R1', k: EdgeKind.riser),
        ]);

    test('roles, the standby demand factor and the jockey duty', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c, floors: 3);
      c.read(networkControllerProvider.notifier).loadNetwork(room());
      final bind = c.read(mepDutyBindingProvider);
      expect(bind.firePumpNodeIds, {'FP1', 'FP2', 'FP3'});
      // Equal legs: FP1 (lowest id) is the duty pump, the highest id the
      // jockey, the remaining one the standby.
      expect(bind.fireJockeyPumpNodeIds, {'FP3'});
      expect(bind.fireStandbyPumpNodeIds, {'FP2'});

      final duties = c.read(equipmentNodeDutiesProvider);
      final fire = c.read(firePumpDutyProvider)!;
      expect(duties['FP1']!.motor.watts, fire.selectedMotor.watts);
      expect(duties['FP2']!.motor.watts, fire.selectedMotor.watts);
      // The jockey: 1 % of the rated flow at churn + 5 m, on the ladder.
      final r = c.read(firePumpRatingProvider);
      final jockey = sizePump(flow: r.jockeyFlow, head: r.jockeyHead);
      expect(duties['FP3']!.motor.watts, jockey.selectedMotor.watts);
      expect(jockey.selectedMotor.inKiloWatts, lessThan(2.0));

      final loads = {
        for (final l in c.read(placedEquipmentLoadsProvider)) l.id: l,
      };
      expect(loads['node-FP2']!.demandFactor, 0);
      expect(loads['node-FP1']!.demandFactor, isNull);
      final circuits = {
        for (final cc in c.read(placedEquipmentCircuitsProvider))
          cc.sourceEquipmentId: cc,
      };
      expect(circuits['node-FP2']!.demandFactor, 0);
      expect(circuits['node-FP1']!.demandFactor, 1);
    });

    testWidgets('the schedule lists every drawn fire pump', (tester) async {
      final (ref, c) = await _harness(tester);
      _seed(c, floors: 3);
      c.read(networkControllerProvider.notifier).loadNetwork(room());
      await tester.pump();
      final data = gatherEquipmentScheduleData(ref);
      final fire = data.pumps
          .where((p) => p.duty.selectedMotor.watts > 0 && p.tag != null)
          .where((p) =>
              p.service.contains('ire') || p.service.contains('ebakaran'))
          .toList();
      expect(fire.length, 3);
      expect(fire.map((p) => p.tag).toSet().length, 3);
    });
  });

  // ── fire-motor-oversized ──────────────────────────────────────────────────
  test('a fire pump past 315 kW is a Review advisory, its way on the duty',
      () {
    // 50 storeys × 4 m, 4 hydrant stacks ⇒ 1250 gpm = 78.86 L/s; head =
    // (49 × 4 + 1.2) lift + 70.34 m residual + 15 m allowance = 282.5 m;
    // overload 118.3 L/s @ 183.6 m ⇒ shaft = 9810 × 0.1183 × 183.6 / 0.595
    // ≈ 358 kW > the 315 kW ladder top.
    final c = ProviderContainer();
    addTearDown(c.dispose);
    _seed(c, floors: 50, h: 4.0);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('H', 50, 0),
      for (var s = 0; s < 4; s++) ...[
        _n('a$s', 100.0 + s * 100, 0),
        _n('b$s', 100.0 + s * 100, 0, floor: 1),
      ],
    ], edges: [
      _e('p', 'P', 'H'),
      for (var s = 0; s < 4; s++) ...[
        _e('h$s', 'H', 'a$s'),
        _e('r$s', 'a$s', 'b$s', k: EdgeKind.riser),
      ],
    ]));
    // Build the electrical controller (and its MEP sync) up front.
    c.read(electricalProjectProvider);
    final fire = c.read(firePumpDutyProvider)!;
    expect(fire.motorOversized, isTrue);
    expect(c.read(designIssuesProvider).map((i) => i.kind),
        contains('fire-pump-motor-oversized'));
    // The way sizes on the governing input, never the clamped 315 kW / η.
    final d = c.read(equipmentNodeDutiesProvider)['P']!;
    expect(d.input.watts, closeTo(fire.motorInputPower.watts, 1e-6));
    expect(d.input.watts, greaterThan(315000 / 0.9));
  });

  // ── riser-hwr-export ──────────────────────────────────────────────────────
  testWidgets('the issued riser sheet carries the HWR return leg',
      (tester) async {
    final (ref, c) = await _harness(tester);
    _seed(c, floors: 6);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('HTR', 0, 0, role: NodeRole.plant),
      for (var f = 0; f < 6; f++) _n('H$f', 200, 0, floor: f),
      for (var f = 0; f < 6; f++)
        _n('S$f', 400, 0,
            floor: f, role: NodeRole.fixture, fixture: PlumbingFixture.shower),
    ], edges: [
      _e('hh', 'HTR', 'H0', s: ServiceType.hotWater),
      for (var f = 1; f < 6; f++)
        _e('r$f', 'H${f - 1}', 'H$f', s: ServiceType.hotWater, k: EdgeKind.riser),
      for (var f = 0; f < 6; f++)
        _e('s$f', 'H$f', 'S$f', s: ServiceType.hotWater),
    ]));
    await tester.pump();
    expect(c.read(hotWaterRecircProvider), isNotNull);
    final labels = buildLiveRiserSheet(ref, null)
        .prims
        .whereType<SldLabel>()
        .map((l) => l.text);
    expect(labels, contains('HWR'));
  });

  // ── fire-verify-items ─────────────────────────────────────────────────────
  testWidgets('the 690 kPa residual is printed only with a standpipe drawn',
      (tester) async {
    final (ref, c) = await _harness(tester);
    _seed(c, floors: 2);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('h', 100, 0, role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
    ], edges: [
      _e('e', 'P', 'h', s: ServiceType.fireSprinkler),
    ]));
    await tester.pump();
    var items = buildMechanicalReportData(ref).verifyItems.map((v) => v.value);
    expect(items, isNot(contains(kResidualPressureClassIKpa)));
    expect(items, contains(kMaxFireVelocityMps));
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('h', 100, 0, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ], edges: [
      _e('e', 'P', 'h'),
    ]));
    await tester.pump();
    items = buildMechanicalReportData(ref).verifyItems.map((v) => v.value);
    expect(items, contains(kResidualPressureClassIKpa));
    expect(c.read(feedStrategyProvider), isNotNull);
  });
}
