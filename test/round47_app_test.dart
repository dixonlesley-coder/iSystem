// Round 47 (2026-10-18) — app-side regressions: a standby domestic / HW
// pump gets its own '(standby)' row on the equipment schedule (the count the
// MDP, the riser and the takeoff already carry), and the upfeed pump ASSUMED
// at a water meter is sized from its floor surface, the drawn pump's datum.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
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
        role: c?.role ?? role,
        component: c,
        fixture: fixture);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.coldWater, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

void _seed(ProviderContainer c, List<Floor> floors, {bool calibrate = true}) {
  final p = c.read(projectControllerProvider.notifier)..setFloors(floors);
  if (calibrate) p.setCalibration('s1', const ScaleCalibration(0.01));
}

/// GT -> S -> {P1 -> CV1, P2 -> CV2} -> D header -> riser -> six lavatories:
/// a duty / standby pump pair on [s].
Network _duplex(ServiceType s) => Network(nodes: [
      _n('GT', 0, 0, c: NodeComponent.groundTank),
      _n('S', 100, 0),
      _n('P1', 200, 0, c: NodeComponent.pump),
      _n('P2', 200, 100, c: NodeComponent.pump),
      _n('CV1', 300, 0, c: NodeComponent.checkValve),
      _n('CV2', 300, 100, c: NodeComponent.checkValve),
      _n('D', 400, 0),
      _n('R1', 400, 0, floor: 1),
      for (var i = 0; i < 6; i++)
        _n('W$i', 500 + 50.0 * i, 0,
            floor: 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.lavatory),
    ], edges: [
      _e('g', 'GT', 'S', s: s),
      _e('s1', 'S', 'P1', s: s),
      _e('s2', 'S', 'P2', s: s),
      _e('p1', 'P1', 'CV1', s: s),
      _e('p2', 'P2', 'CV2', s: s),
      _e('c1', 'CV1', 'D', s: s),
      _e('c2', 'CV2', 'D', s: s),
      _e('r', 'D', 'R1', s: s, k: EdgeKind.riser),
      for (var i = 0; i < 6; i++) _e('w$i', 'R1', 'W$i', s: s),
    ]);

void main() {
  // ── cross-surface-standby-pump-missing-from-equipment-schedule ────────────
  testWidgets(
      'a duty / standby supply pair: two schedule rows (one standby), the '
      'count the MDP pump ways carry', (tester) async {
    final (ref, c) = await _harness(tester);
    _seed(c, const [Floor('L0', Length(3.5)), Floor('L1', Length(3.5))]);
    c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
    c.read(networkControllerProvider.notifier)
        .loadNetwork(_duplex(ServiceType.coldWater));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final bind = c.read(mepDutyBindingProvider);
    expect(bind.supplyStandbyPumpNodeIds, hasLength(1));
    final standbyId = bind.supplyStandbyPumpNodeIds.keys.single;

    final rows = gatherEquipmentScheduleData(ref)
        .pumps
        .where((p) => p.service.startsWith('Domestic water supply'))
        .toList();
    expect(rows, hasLength(2));
    final standby =
        rows.where((r) => r.service == 'Domestic water supply (standby)');
    expect(standby, hasLength(1));
    // The standby row is the duty machine (same duty) under ITS plan tag.
    final duty = rows.firstWhere((r) => !r.service.contains('standby'));
    expect(standby.single.duty.head.meters,
        closeTo(duty.duty.head.meters, 1e-12));
    expect(standby.single.tag, isNot(duty.tag));
    // The MDP wires one way per drawn pump.
    final board = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == kMepEquipmentPanelId);
    final pumpWays = board.circuits.where((w) =>
        w.sourceEquipmentId == 'node-P1' || w.sourceEquipmentId == 'node-P2');
    expect(pumpWays, hasLength(rows.length));
    expect(
        board.circuits
            .firstWhere((w) => w.sourceEquipmentId == 'node-$standbyId')
            .demandFactor,
        0);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets(
      'a parallel hot-water circulator pair: two HW recirc rows, one standby',
      (tester) async {
    final (ref, c) = await _harness(tester);
    _seed(c, const [Floor('L0', Length(3.5)), Floor('L1', Length(3.5))]);
    final net = _duplex(ServiceType.hotWater);
    // A water heater in place of the ground tank.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(
        nodes: [
          for (final n in net.nodes)
            n.id == 'GT' ? _n('GT', 0, 0, role: NodeRole.plant) : n,
        ],
        edges: net.edges));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final bind = c.read(mepDutyBindingProvider);
    expect(bind.hwRecircPumpNodeIds, {'P1', 'P2'});
    expect(bind.hwStandbyPumpNodeIds, hasLength(1));
    final rows = gatherEquipmentScheduleData(ref)
        .pumps
        .where((p) => p.service.startsWith('Hot-water recirculation'))
        .toList();
    expect(rows, hasLength(2));
    expect(
        rows.where((r) => r.service == 'Hot-water recirculation (standby)'),
        hasLength(1));
    expect(rows.map((r) => r.tag).toSet(), hasLength(2));
    await tester.pump(const Duration(seconds: 10));
  });

  // ── mech-convergence-2-assumed-upfeed-pump-at-ceiling-datum ───────────────
  testWidgets(
      'upfeed fed by a water meter: the assumed pump head == the same drawing '
      'with the pump drawn at the meter', (tester) async {
    final (_, c) = await _harness(tester);
    _seed(c, const [Floor('L0', Length(3.5)), Floor('L1', Length(3.2))],
        calibrate: false);
    c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
    Network draw(bool pumped) => Network(nodes: [
          _n('M', 0, 0, c: NodeComponent.waterMeter),
          if (pumped) _n('P', 10, 0, c: NodeComponent.pump),
          _n('R0', 20, 0),
          _n('R1', 20, 0, floor: 1),
          _n('W1', 40, 0,
              floor: 1,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank),
          _n('L1', 60, 0,
              floor: 1,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.lavatory),
        ], edges: [
          if (pumped) ...[_e('e0', 'M', 'P'), _e('e1', 'P', 'R0')]
          else _e('e1', 'M', 'R0'),
          _e('e2', 'R0', 'R1', k: EdgeKind.riser),
          _e('e3', 'R1', 'W1'),
          _e('e4', 'R1', 'L1'),
        ]);
    c.read(networkControllerProvider.notifier).loadNetwork(draw(false));
    await tester.pump();
    final meterHead = c.read(solveProvider)!.requiredPumpHead.meters;
    c.read(networkControllerProvider.notifier).loadNetwork(draw(true));
    await tester.pump();
    final pumpHead = c.read(solveProvider)!.requiredPumpHead.meters;
    // Uncalibrated: the runs carry no length, the riser the same 3.5 m on
    // both; the static term is (critical fixture − the L0 SURFACE) for both.
    expect(meterHead, closeTo(pumpHead, 1e-9));
    expect(c.read(pumpDutyProvider)!.head.meters, closeTo(pumpHead, 1e-9));
    await tester.pump(const Duration(seconds: 10));
  });
}
