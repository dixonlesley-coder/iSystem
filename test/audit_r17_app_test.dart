// Round 17 (2026-10-18) — app-side regressions:
//   ducted-ac-intake-phantom-fan  a stand-alone ducted AC with a bare OA leaf
//                                 keeps the AC as its machine: no F-01 row, no
//                                 'Supply air fan' MDP way;
//   report-supply-movers          the calc report prints EVERY scheduled
//                                 supply mover (transfer pump included);
//   fire-sections-per-system      each fire section is gated on its own drawn
//                                 system; a sprinkler-only pump is rated on the
//                                 sprinkler demand;
//   electrical-riser-supply       the packaged E-401 riser draws the PLN
//                                 supply head the overview draws.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x,
  double y, {
  int floor = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
  PlumbingFixture? fixture,
  FlowRate? airflow,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: y,
  floorIndex: floor,
  role: role,
  component: c,
  fixture: fixture,
  airflow: airflow,
);

NetEdge _e(
  String id,
  String a,
  String b, {
  EdgeKind kind = EdgeKind.run,
  ServiceType service = ServiceType.coldWater,
}) => NetEdge(id: id, fromId: a, toId: b, service: service, kind: kind);

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

void main() {
  group('ducted-ac-intake-phantom-fan', () {
    const room = RoomArea(
      id: 'r0',
      sheetId: 's1',
      floorIndex: 0,
      ax: 0,
      ay: 0,
      bx: 1000,
      by: 1000,
    );
    Network net({required bool intake, bool damper = false}) => Network(
      nodes: [
        _n('ac', 500, 500, role: NodeRole.plant, c: NodeComponent.acDucted),
        _n('j', 600, 500),
        _n(
          'd1',
          700,
          400,
          role: NodeRole.fixture,
          c: NodeComponent.supplyDiffuser,
          airflow: const FlowRate(0.15),
        ),
        _n(
          'd2',
          700,
          600,
          role: NodeRole.fixture,
          c: NodeComponent.supplyDiffuser,
          airflow: const FlowRate(0.15),
        ),
        if (intake) _n('oa', 300, 500),
        if (intake && damper)
          _n('md', 400, 500, c: NodeComponent.motorizedDamper),
      ],
      edges: [
        _e('aj', 'ac', 'j', service: ServiceType.duct),
        _e('j1', 'j', 'd1', service: ServiceType.duct),
        _e('j2', 'j', 'd2', service: ServiceType.duct),
        if (intake && !damper) _e('ao', 'ac', 'oa', service: ServiceType.duct),
        if (intake && damper) ...[
          _e('ao', 'ac', 'md', service: ServiceType.duct),
          _e('mo', 'md', 'oa', service: ServiceType.duct),
        ],
      ],
    );

    testWidgets('the OA leaf never takes the AC duty as a phantom fan', (
      tester,
    ) async {
      final (ref, c) = await _harness(tester);
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
      c.read(roomAreasProvider.notifier).set(const [room]);
      for (final damper in [false, true]) {
        c
            .read(networkControllerProvider.notifier)
            .loadNetwork(net(intake: true, damper: damper));
        await tester.pump();
        expect(c.read(airSystemRootNodesProvider).supply, 'ac');
        expect(c.read(supplyFanDutiesByRootProvider).keys.toSet(), {'ac'});
        final data = gatherEquipmentScheduleData(ref);
        expect(data.acUnits, hasLength(1));
        expect(data.fans, isEmpty, reason: 'no phantom F-01 (damper=$damper)');
        expect(
          c
              .read(mepEquipmentLoadsProvider)
              .where((l) => l.source == MepLoadSource.supplyFan),
          isEmpty,
          reason: 'no second Supply-air-fan way beside the AC',
        );
        // The AC's way stays on the room-PK compressor input.
        expect(
          c.read(nodeFedLoadsProvider)['ac']!.source,
          NodeLoadSource.roomPk,
        );
      }
    });
  });

  group('report-supply-movers', () {
    // GT → TP → (riser) RT (L2) → gravity riser, 2 flush-tank WCs per floor.
    Network build() => Network(
      nodes: [
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('TP', 100, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n(
          'RT',
          100,
          0,
          floor: 2,
          role: NodeRole.plant,
          c: NodeComponent.roofTank,
        ),
        for (var f = 0; f < 3; f++) _n('H$f', 200, 0, floor: f),
        for (var f = 0; f < 3; f++)
          for (var i = 0; i < 2; i++)
            _n(
              'W${f}_$i',
              400,
              i * 200.0,
              floor: f,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank,
            ),
      ],
      edges: [
        _e('gt', 'GT', 'TP'),
        _e('tr', 'TP', 'RT', kind: EdgeKind.riser),
        _e('rh', 'RT', 'H2'),
        _e('r1', 'H2', 'H1', kind: EdgeKind.riser),
        _e('r0', 'H1', 'H0', kind: EdgeKind.riser),
        for (var f = 0; f < 3; f++)
          for (var i = 0; i < 2; i++) _e('w${f}_$i', 'H$f', 'W${f}_$i'),
      ],
    );

    testWidgets('a pure transfer scheme prints its transfer pump', (
      tester,
    ) async {
      final (ref, c) = await _harness(tester);
      c.read(projectControllerProvider.notifier)
        ..setFloors([
          for (var i = 0; i < 3; i++) Floor('L$i', const Length(3.5)),
        ])
        ..setCalibration('s1', const ScaleCalibration(0.01));
      c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
      c.read(networkControllerProvider.notifier).loadNetwork(build());
      await tester.pump();
      final duty = c.read(supplyMoverDutiesProvider)['TP']!;
      // pumpDutyProvider skips transfers ⇒ the legacy single line had nothing.
      expect(c.read(pumpDutyProvider), isNull);
      final data = buildMechanicalReportData(ref);
      expect(data.supplyPumps, hasLength(1));
      expect(identical(data.supplyPumps.single.duty, duty), isTrue);
      final row = gatherEquipmentScheduleData(ref).pumps.single;
      expect(data.supplyPumps.single.tag, row.tag);
      final md = buildCalcReportMarkdown(data);
      expect(md, contains('- Pump ${row.tag} (${row.service}): '));
      expect(md, contains('${duty.head.meters.toStringAsFixed(1)} m'));
    });
  });

  group('fire-sections-per-system', () {
    Network hydrantOnly() => Network(
      nodes: [
        _n('a', 0, 0),
        _n('h', 500, 0, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ],
      edges: [_e('fh', 'a', 'h', service: ServiceType.fireHydrant)],
    );
    Network sprinklerOnly() => Network(
      nodes: [
        _n('a', 0, 0),
        _n(
          's',
          500,
          0,
          role: NodeRole.fixture,
          c: NodeComponent.sprinklerHead,
        ),
      ],
      edges: [_e('fs', 'a', 's', service: ServiceType.fireSprinkler)],
    );

    testWidgets('hydrant only ⇒ no sprinkler design or remote-head check', (
      tester,
    ) async {
      final (ref, c) = await _harness(tester);
      c.read(networkControllerProvider.notifier).loadNetwork(hydrantOnly());
      final data = buildMechanicalReportData(ref);
      expect(data.sprinkler, isNull);
      expect(data.sprinklerRemoteArea, isNull);
      expect(data.standpipe, isNotNull);
      expect(data.firePumpRating, isNotNull);
      // The pump stays on the standpipe basis.
      final st = c.read(standpipeDesignProvider);
      expect(
        c.read(firePumpDutyProvider)!.flow.cubicMetersPerSecond,
        closeTo(st.requiredFlow.cubicMetersPerSecond, 1e-12),
      );
    });

    testWidgets('sprinkler only ⇒ no standpipe; pump on the sprinkler demand', (
      tester,
    ) async {
      final (ref, c) = await _harness(tester);
      c.read(networkControllerProvider.notifier).loadNetwork(sprinklerOnly());
      final data = buildMechanicalReportData(ref);
      expect(data.standpipe, isNull);
      expect(data.sprinkler, isNotNull);
      expect(data.sprinklerRemoteArea, isNotNull);
      final remote = c.read(sprinklerRemoteAreaProvider);
      final pump = c.read(firePumpDutyProvider)!;
      expect(
        pump.flow.cubicMetersPerSecond,
        closeTo(remote.remoteAreaDemand.cubicMetersPerSecond, 1e-12),
      );
      // Far below the 31.5 L/s standpipe rating it used to carry.
      expect(
        pump.flow.inLitersPerSecond,
        lessThan(c.read(standpipeDesignProvider).requiredFlow.inLitersPerSecond),
      );
      // The rating curve, schedule and pump all name the same rated point.
      expect(
        data.firePumpRating!.ratedFlow.cubicMetersPerSecond,
        closeTo(pump.flow.cubicMetersPerSecond, 1e-12),
      );
    });
  });

  group('electrical-riser-supply', () {
    testWidgets('the packaged riser DXF carries the PLN supply head', (
      tester,
    ) async {
      final (ref, c) = await _harness(tester);
      ref.read(projectControllerProvider.notifier).setName('project');
      c.read(electricalProjectProvider.notifier).setProject(
        const ElectricalProject(
          id: 'e',
          name: 'e',
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              system: ElectricalSystem.threePhase,
              voltage: Voltage(400),
              circuits: [
                ElectricalCircuit(
                  id: 'l',
                  name: 'Load',
                  loadKind: LoadKind.general,
                  loadW: 20000,
                  phases: 3,
                  length: Length(10),
                ),
              ],
            ),
          ],
        ),
      );
      final dir = Directory.systemTemp.createTempSync('mechx_r17_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final wrote = await tester.runAsync(
        () => writeSubmittalPackageToDir(ref, dir.path),
      );
      expect(wrote, isTrue);
      final riser = File('${dir.path}/project-electrical-riser.dxf');
      expect(riser.existsSync(), isTrue);
      final overview = File('${dir.path}/project-electrical-overview-sld.dxf');
      // Both electrical sheets of one submittal state the same supply.
      expect(overview.readAsStringSync(), contains('PLN'));
      expect(riser.readAsStringSync(), contains('PLN'));
    });
  });

  test('SNI target used by the PRV margin is the supply-design target', () {
    // Guard: the 255 kPa PRV setpoint the zone tests derive is 225 + 30.
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var i = 0; i < 12; i++) Floor('L$i', const Length(3.5)),
    ]);
    // Round 22 — the top zone is tank-fed (12 × 3.5 m: floors 11..1 sit
    // within 42 − (3.5f + 1.1) ≤ 39.99 m of tank head); the first PRV zone
    // (floor 0) holds the setpoint.
    expect(
      c
          .read(zoneStaticsProvider)
          .firstWhere((z) => z.viaPrv)
          .topResidual
          .inKiloPascals,
      closeTo(255, 1e-9),
    );
    expect(
      const SniProfile().maxFixtureStaticPressure.value.inKiloPascals,
      greaterThan(255),
    );
  });
}
