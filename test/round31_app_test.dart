// Round 31 (2026-10-18) — the app half of the round-31 audit:
//
//   hvac-5-1   a room served only by drawn LINEAR diffusers is 'served' (no
//              phantom AHU-Rxx row) and the stale judge sees their airflow
//   hvac-5-2   the AHU outdoor-air intake leaf is never a 'loose end'
//   hvac-5-3   intake + return drawn to one AHU combine in PARALLEL
//   regression-duplex-ejector-standby-full-demand   a duplex ejector set is
//              duty + standby (demand factor 0, '(standby)' row)
//   stress-edits-2   an MEP-derived way's load cannot be moved / un-placed
//   ui-simplicity-4  PUIL verify debt only with electrical panels; the
//              inspector BOM writes 'DN15 run'
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/room_air.dart' show AirEquipmentKind;
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart'
    show VerificationStatus;
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
        int floor = 0}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: c?.role ?? role,
        component: c,
        airflow: airflow);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

void _seed(ProviderContainer c, {int levels = 1}) {
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < levels; i++) Floor('L$i', const Length(3)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
}

void main() {
  // ── hvac-5-1 ──────────────────────────────────────────────────────────────
  group('linear diffusers serve a room like supply diffusers', () {
    // 20 x 10 m office (2000 x 1000 px at 0.01 m/px), 3.0 m ceiling, 6 ACH:
    // required = 20 x 10 x 3.0 x 6 / 3600 = 1.0 m3/s.
    const office = RoomArea(
        id: 'office',
        sheetId: 's1',
        floorIndex: 0,
        ax: 0,
        ay: 0,
        bx: 2000,
        by: 1000,
        achOverride: 6,
        equipmentKind: AirEquipmentKind.ahu,
        name: 'Office');

    testWidgets('served (no phantom AHU row) and judged 10 % short',
        (tester) async {
      final (ref, c) = await _harness(tester);
      _seed(c);
      c.read(roomAreasProvider.notifier).set(const [office]);
      // An AHU OUTSIDE the room feeds two LINEAR diffusers inside it at
      // 0.45 m3/s each (0.9 placed vs 1.0 required).
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('ahu', 2600, 500, c: NodeComponent.ahu),
        _n('j', 2200, 500),
        _n('ld1', 500, 500,
            c: NodeComponent.linearDiffuser, airflow: const FlowRate(0.45)),
        _n('ld2', 1500, 500,
            c: NodeComponent.linearDiffuser, airflow: const FlowRate(0.45)),
      ], edges: [
        _e('a', 'ahu', 'j', ServiceType.duct),
        _e('b', 'j', 'ld1', ServiceType.duct),
        _e('d', 'j', 'ld2', ServiceType.duct),
      ]));
      await tester.pump();
      final sizing = office.sizing(0.01, rooms: const [office])!;
      expect(
          sizing.supply.count *
              sizing.supply.airflowEach.cubicMetersPerSecond,
          closeTo(1.0, 1e-9));
      expect(
          roomServedByDrawnAir(office, const [office],
              c.read(networkControllerProvider).network,
              c.read(sizingProvider).keys.toSet(),
              extract: false),
          isTrue);
      // No phantom room-air AHU row for the office: only the drawn AHU.
      final fans = gatherEquipmentScheduleData(ref).fans;
      expect(fans.where((f) => f.service == 'Office'), isEmpty);
      // The stale judge sees the 0.9 m3/s placed against 1.0 required.
      expect(
          c
              .read(designIssuesProvider)
              .any((i) => i.kind == 'room-terminals-stale:office'),
          isTrue);
    });
  });

  // ── hvac-5-2 / hvac-5-3 ───────────────────────────────────────────────────
  group('AHU intake + return', () {
    Network ahuNet() => Network(nodes: [
          _n('ahu', 1000, 500, c: NodeComponent.ahu),
          _n('j', 600, 500),
          _n('sd1', 400, 300,
              c: NodeComponent.supplyDiffuser, airflow: const FlowRate(0.2)),
          _n('sd2', 400, 700,
              c: NodeComponent.supplyDiffuser, airflow: const FlowRate(0.2)),
          _n('rg', 200, 500,
              c: NodeComponent.returnGrille, airflow: const FlowRate(0.15)),
          _n('md', 1200, 500, c: NodeComponent.motorizedDamper),
          _n('oa', 1600, 500),
        ], edges: [
          _e('s0', 'ahu', 'j', ServiceType.duct),
          _e('s1', 'j', 'sd1', ServiceType.duct),
          _e('s2', 'j', 'sd2', ServiceType.duct),
          _e('r0', 'rg', 'ahu', ServiceType.returnAir),
          _e('i0', 'ahu', 'md', ServiceType.duct),
          _e('i1', 'md', 'oa', ServiceType.duct),
        ]);

    testWidgets('the intake leaf is not a loose end', (tester) async {
      final (_, c) = await _harness(tester);
      _seed(c);
      c.read(networkControllerProvider.notifier).loadNetwork(ahuNet());
      await tester.pump();
      final kinds = c.read(designIssuesProvider).map((i) => i.kind).toSet();
      expect(kinds.contains('unconnected-loose-end:oa'), isFalse);
    });

    testWidgets('fan static = supply index + max(intake, return) + internal',
        (tester) async {
      final (_, c) = await _harness(tester);
      _seed(c);
      c.read(networkControllerProvider.notifier).loadNetwork(ahuNet());
      await tester.pump();
      final net = c.read(sizingNetworkProvider);
      final sizing = c.read(sizingProvider);
      final project = c.read(projectControllerProvider);
      final s = airSystemsFor(net, sizing, project, ServiceType.duct).single;
      final r =
          airSystemsFor(net, sizing, project, ServiceType.returnAir).single;
      expect(s.fanNodeId, 'ahu');
      expect(r.fanNodeId, 'ahu');
      expect(s.intake.pascals, greaterThan(0),
          reason: 'the intake path carries friction');
      // Intake and return enter the mixing box in PARALLEL: the inlet side
      // governs at max(intake, return); AHU internal 250 Pa (VERIFY).
      final internal =
          airUnitInternalStatic(net.nodeById('ahu')).pascals;
      expect(internal, closeTo(250, 1e-9));
      final expected = (s.stat.pascals - s.intake.pascals) +
          math.max(s.intake.pascals, r.stat.pascals) +
          internal;
      final duty = c.read(supplyFanDutiesByRootProvider)['ahu']!;
      expect(duty.totalStaticPressure.pascals, closeTo(expected, 1e-9));
      // Strictly below the old series sum (both inlet paths carry friction).
      expect(duty.totalStaticPressure.pascals,
          lessThan(s.stat.pascals + r.stat.pascals + internal - 1e-9));
    });
  });

  // ── regression-duplex-ejector-standby-full-demand ─────────────────────────
  testWidgets(
      'a duplex ejector set is duty + standby: df 0 on the standby way, '
      "'(standby)' on its schedule row, both at the full lift", (tester) async {
    final (ref, c) = await _harness(tester);
    c.read(projectControllerProvider.notifier)
      ..setFloors(const [Floor('L0', Length(3)), Floor('L1', Length(3))])
      ..setCalibration('s1', const ScaleCalibration(0.05));
    c.read(electricalProjectProvider); // build the MEP-feed listener
    // WC -> PIT -> EJ / EJ2 -> check valves -> header H -> riser -> sewer.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('WC', -50, 0, role: NodeRole.fixture),
      _n('PIT', 0, 0, c: NodeComponent.groundTank),
      _n('EJ', 20, 0, c: NodeComponent.pump),
      _n('EJ2', 20, 20, c: NodeComponent.pump),
      _n('CV1', 26, 0, c: NodeComponent.checkValve),
      _n('CV2', 26, 20, c: NodeComponent.checkValve),
      _n('H', 34, 10),
      _n('R1', 40, 0, floor: 1),
      _n('SW', 140, 0, floor: 1),
    ], edges: [
      _e('in', 'WC', 'PIT', ServiceType.drainage),
      _e('pe', 'PIT', 'EJ', ServiceType.drainage),
      _e('pe2', 'PIT', 'EJ2', ServiceType.drainage),
      _e('d1', 'EJ', 'CV1', ServiceType.drainage),
      _e('d2', 'EJ2', 'CV2', ServiceType.drainage),
      _e('h1', 'CV1', 'H', ServiceType.drainage),
      _e('h2', 'CV2', 'H', ServiceType.drainage),
      _e('rs', 'H', 'R1', ServiceType.drainage, kind: EdgeKind.riser),
      _e('sw', 'R1', 'SW', ServiceType.drainage),
    ]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final bind = c.read(mepDutyBindingProvider);
    // Equal bores ⇒ the lowest id is the duty unit.
    expect(bind.ejectorStandbyPumpNodeIds, {'EJ2': 'EJ'});
    final duties = c.read(ejectorDutiesProvider);
    // Lift through the valves + header: pump on the L0 slab (0.0 m) to R1,
    // a bare L1 drainage junction under its slab = 3.0 - 0.3 = 2.7 m; the
    // head adds friction on top.
    expect(duties['EJ']!.head.meters, greaterThan(2.7));
    expect(duties['EJ2']!.head.meters, greaterThan(2.7));

    final board = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == kMepEquipmentPanelId);
    final duty = board.circuits.firstWhere((w) => w.sourceEquipmentId == 'node-EJ');
    final standby =
        board.circuits.firstWhere((w) => w.sourceEquipmentId == 'node-EJ2');
    expect(duty.demandFactor, isNot(0));
    expect(standby.demandFactor, 0);
    expect(standby.motorKw, closeTo(duty.motorKw!, 1e-12));

    final rows = gatherEquipmentScheduleData(ref)
        .pumps
        .where((p) => p.service.startsWith('Sewage ejector'))
        .toList();
    expect(rows, hasLength(2));
    expect(rows.where((r) => r.service == 'Sewage ejector (standby)'),
        hasLength(1));
    await tester.pump(const Duration(seconds: 10));
  });

  // ── stress-edits-2 ────────────────────────────────────────────────────────
  testWidgets("an MEP-derived way's load position is locked to its equipment",
      (tester) async {
    final (_, c) = await _harness(tester);
    _seed(c);
    c.read(electricalProjectProvider);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('P', 100, 100, c: NodeComponent.pump),
      _n('X', 300, 100),
    ], edges: [
      _e('a', 'P', 'X', ServiceType.coldWater),
    ]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    final ctrl = c.read(electricalProjectProvider.notifier);
    final board = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == kMepEquipmentPanelId);
    final way = board.circuits.firstWhere((w) => w.sourceEquipmentId != null);
    expect(ctrl.isMepDerivedWay(board.id, way.id), isTrue);
    final before = way.loadPos;
    expect(before, isNotNull, reason: 'placed at its pump node');
    expect(before!.x, closeTo(100, 1e-9));
    ctrl.setLoadPos(board.id, way.id,
        const LayoutPos(sheetId: 's1', floorIndex: 0, x: 900, y: 750));
    ctrl.setLoadPos(board.id, way.id, null);
    final after = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == kMepEquipmentPanelId)
        .circuits
        .firstWhere((w) => w.id == way.id)
        .loadPos;
    expect(after, before);
    await tester.pump(const Duration(seconds: 10));
  });

  // ── ui-simplicity-4 ───────────────────────────────────────────────────────
  testWidgets(
      'PUIL verify debt surfaces only once the project has a panel '
      '(the pending PUIL secondarySource values, exactly)', (tester) async {
    final (_, c) = await _harness(tester);
    expect(c.read(electricalProjectProvider).panels, isEmpty);
    // The PUIL values the Review would surface: unverified + secondarySource.
    final puil = {
      for (final v in const PuilProfile().verifyChecklist)
        if (v.isUnverified && v.status == VerificationStatus.secondarySource)
          'verify:${v.citation}',
    };
    expect(puil, isNotEmpty);
    Set<String> verifyKinds() => {
          for (final i in c.read(designIssuesProvider))
            if (i.isVerify) i.kind,
        };
    expect(verifyKinds().intersection(puil), isEmpty);
    c.read(electricalProjectProvider.notifier).addPanel(name: 'DB');
    await tester.pump();
    expect(verifyKinds().containsAll(puil), isTrue);
  });
}
