// Backlog Z-2 (2026-11-14) — designed fire zones in the app: the relay duty
// of the lower zone room, the break-tank judge, the per-zone surfaces.
//
// Drawing A (12 storeys x 3.5 m, 0.01 m/px, one sheet):
//   zone 1: FT (L0 ground tank, 120 000 L) -s1- P1 -d1- H0; ONE stack
//           H0..H5 with a hydrant box on L0..L5; fill H5 -f- BT.
//   zone 2: BT (L6, roof-typed below the top storey: its floor surface
//           6 x 3.5 = 21.0 m) -s2- P2 (L6) -d2- K6; TWO stacks to L7..L11.
// Hand figures (NFPA 14 / 20, `// VERIFY`):
//   one stack 500 gpm = 31.5451 L/s; two stacks 750 gpm = 47.3176 L/s.
//   residual 690 kPa / (1000 x 9.81) = 70.336 m; friction = max(15 m
//   allowance, the sized path) = 15 m on these short runs.
//   zone 1 own: lift 5 x 3.5 + 1.2 = 18.7 m -> 18.7 + 15 + 70.336 =
//     104.036 m at 31.5451 L/s.
//   zone 2: lift from its datum L6 (21.0 m) to L11's outlet (38.5 + 1.2 =
//     39.7 m) = 18.7 m -> 104.036 m at 47.3176 L/s.
//   zone 1 relay: fill flow = zone 2's 47.3176 L/s > 31.5451 -> the FILL
//     sets the flow; fill head = 21.0 m lift + the sized fill friction + 5 m
//     inlet residual (~26 m) < 104.036 -> the own zone sets the head.
//   break tank: 47.317647 L/s x 30 min x 60 = 85 171.77 L.
import 'package:flutter/widgets.dart' hide Velocity;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart' show buildCalcReportMarkdown;
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_zones.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeComponent? c, double? tankL}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: c == null
            ? NodeRole.main
            : c == NodeComponent.hydrantBox
                ? NodeRole.fixture
                : NodeRole.plant,
        component: c,
        tankCapacityLitres: tankL);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

/// Drawing A ([lowTop] = the lower zone's top floor, the break on
/// [lowTop] + 1); [btComponent] types the break tank.
Network _zoned({
  int lowTop = 5,
  int top = 11,
  double? btL = 60000,
  NodeComponent btComponent = NodeComponent.roofTank,
  int upperStacks = 2,
  bool lowerBoxesAllFloors = true,
}) {
  final brk = lowTop + 1;
  return Network(nodes: [
    _n('FT', 0, 100, c: NodeComponent.groundTank, tankL: 120000),
    _n('P1', 50, 100, c: NodeComponent.pump),
    for (var f = 0; f <= lowTop; f++) _n('H$f', 100, 100, floor: f),
    for (var f = 0; f <= (lowerBoxesAllFloors ? lowTop : 0); f++)
      _n('BX$f', 200, 100, floor: f, c: NodeComponent.hydrantBox),
    _n('BT', 0, 300, floor: brk, c: btComponent, tankL: btL),
    _n('P2', 50, 300, floor: brk, c: NodeComponent.pump),
    _n('K', 100, 300, floor: brk),
    for (var k = 0; k < upperStacks; k++)
      for (var f = brk; f <= top; f++) ...[
        _n('U$k-$f', 150 + 100.0 * k, 300, floor: f),
        if (f > brk)
          _n('UX$k-$f', 150 + 100.0 * k, 400,
              floor: f, c: NodeComponent.hydrantBox),
      ],
  ], edges: [
    _e('s1', 'FT', 'P1'),
    _e('d1', 'P1', 'H0'),
    for (var f = 1; f <= lowTop; f++)
      _e('r$f', 'H${f - 1}', 'H$f', k: EdgeKind.riser),
    for (var f = 0; f <= (lowerBoxesAllFloors ? lowTop : 0); f++)
      _e('b$f', 'H$f', 'BX$f'),
    _e('f', 'H$lowTop', 'BT'),
    _e('s2', 'BT', 'P2'),
    _e('d2', 'P2', 'K'),
    for (var k = 0; k < upperStacks; k++) ...[
      _e('t$k', 'K', 'U$k-$brk'),
      for (var f = brk + 1; f <= top; f++) ...[
        _e('u$k-$f', 'U$k-${f - 1}', 'U$k-$f', k: EdgeKind.riser),
        _e('ub$k-$f', 'U$k-$f', 'UX$k-$f'),
      ],
    ],
  ]);
}

ProviderContainer _load(Network net,
    {int floors = 12, double floorH = 3.5}) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors(
        [for (var i = 0; i < floors; i++) Floor('L$i', Length(floorH))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

double _fillFriction(ProviderContainer c, FireSystemBasis b, String tank) {
  final net = c.read(sizingNetworkProvider);
  final project = c.read(projectControllerProvider);
  return fireIndexPathFrictionM(
    net: net,
    system: b.system,
    pumpId: b.dutyPumpId!,
    sizing: c.read(sizingProvider),
    lengthOf: (e) => edgeLength(e, net,
            calibrationBySheet: project.calibrations,
            building: project.building,
            mounting: project.mounting)
        .meters,
    targetIds: {tank},
  )!;
}

const double _q500 = 31.5451, _q750 = 47.3176;
// The exact 750 gpm (3.785411784 L/gal): 47.317647 L/s x 1800 s.
const double _break = 750 * 3.785411784 / 60 * 1800; // 85 171.77 L
const double _resid = 690e3 / (1000 * 9.81); // 70.336 m

void main() {
  group('drawing A: the fill sets the lower pump flow', () {
    test('two zones; zone 1 relay 47.3176 L/s @ its own 104.036 m', () {
      final c = _load(_zoned());
      final zones = c.read(fireZoneChainProvider);
      expect([for (final z in zones) z.number], [1, 2]);
      final low = c.read(firePumpBasisByNodeProvider)['P1']!;
      final up = c.read(firePumpBasisByNodeProvider)['P2']!;
      const ownHead = 5 * 3.5 + 1.2 + 15 + _resid; // 104.036
      expect(ownHead, closeTo(104.036, 0.001));
      expect(low.fillTankId, 'BT');
      expect(low.ownFlow!.inLitersPerSecond, closeTo(_q500, 1e-4));
      expect(low.ownHead!.meters, closeTo(ownHead, 1e-6));
      expect(low.fillFlow!.inLitersPerSecond, closeTo(_q750, 1e-4));
      // Fill head = 21.0 m lift + the sized fill friction + 5 m.
      final ff = _fillFriction(c, low, 'BT');
      expect(low.fillHeadM, closeTo(21.0 + ff + 5.0, 1e-9));
      expect(low.fillHeadM!, lessThan(ownHead));
      expect(low.fillGovernsFlow, isTrue);
      expect(low.fillGovernsHead, isFalse);
      expect(low.flow.inLitersPerSecond, closeTo(_q750, 1e-4));
      expect(low.head.meters, closeTo(ownHead, 1e-6));
      // Zone 2: its own datum (L6) to L11's outlet.
      expect(up.fillTankId, isNull);
      expect(up.staticLiftM, closeTo(18.7, 1e-9));
      expect(up.flow.inLitersPerSecond, closeTo(_q750, 1e-4));
      expect(up.head.meters, closeTo(ownHead, 1e-6));
    });

    test('the fill path H0..H5 -> BT carries 47.3176 L/s', () {
      final c = _load(_zoned());
      final s = c.read(sizingProvider);
      for (final id in ['r1', 'r2', 'r3', 'r4', 'r5', 'f']) {
        expect(s[id]!.flow.inLitersPerSecond, closeTo(_q750, 1e-4),
            reason: id);
      }
    });

    test('break tank: 85 172 L required; 60 000 L warns, unset informs, '
        '90 000 L passes', () {
      for (final (cap, kind) in [
        (60000.0, 'fire-break-tank-undersized:BT'),
        (null, 'fire-break-tank-capacity-unset:BT'),
        (90000.0, null),
      ]) {
        final c = _load(_zoned(btL: cap));
        final t = c.read(fireBreakTankChecksProvider).single;
        expect(t.tankId, 'BT');
        expect(t.zoneNumber, 2);
        expect(t.requiredLitres, closeTo(_break, 1e-6));
        expect(t.requiredLitres, closeTo(85171.77, 0.01));
        expect(t.fillFlow!.inLitersPerSecond, closeTo(_q750, 1e-4));
        expect(t.fillEdgeId, 'f');
        final kinds = [for (final i in c.read(designIssuesProvider)) i.kind];
        for (final k in [
          'fire-break-tank-undersized:BT',
          'fire-break-tank-capacity-unset:BT',
        ]) {
          expect(kinds.contains(k), k == kind, reason: '$cap $k');
        }
        // A break tank is never judged as a full fire-water reserve.
        expect(kinds.where((k) => k.startsWith('fire-tank-') && k.endsWith(':BT')),
            isEmpty);
      }
    });

    test('a ground-typed break tank: break-tank judge only (no A-2 '
        'reserve row); FT keeps its reserve', () {
      final c = _load(_zoned(btComponent: NodeComponent.groundTank));
      expect(c.read(fireBreakTankChecksProvider).single.tankId, 'BT');
      final reserves = c.read(fireTankReservesProvider);
      expect([for (final r in reserves) r.tankId], ['FT']);
      // FT: the lower pump's RATED flow (the relay 47.3176 L/s) x 30 min.
      expect(reserves.single.requiredLitres, closeTo(_break, 1e-6));
    });

    test('zone lines: floors, terminal elevations, class', () {
      final c = _load(_zoned());
      final lines = c.read(fireZoneLinesProvider);
      expect(lines, hasLength(2));
      expect((lines[0].lowFloor, lines[0].highFloor), (0, 5));
      expect((lines[1].lowFloor, lines[1].highFloor), (7, 11));
      expect(lines[0].lowTerminalZ, closeTo(1.2, 1e-9));
      expect(lines[0].highTerminalZ, closeTo(5 * 3.5 + 1.2, 1e-9));
      expect(lines[1].lowTerminalZ, closeTo(7 * 3.5 + 1.2, 1e-9));
      expect(lines[1].highTerminalZ, closeTo(11 * 3.5 + 1.2, 1e-9));
      expect(lines[0].pressure, isNotNull);
      expect(lines[1].breakTank!.tankId, 'BT');
      expect(lines[0].breakTank, isNull);
    });
  });

  test('drawing B: a high break tank — the fill sets the lower pump head', () {
    // 30 storeys x 4.0 m; zone 1 has one box on L0, the riser runs to BT on
    // L25 (100.0 m). Own: 31.5451 L/s @ 1.2 + 15 + 70.336 = 86.536 m. Fill:
    // the one-stack zone 2's 31.5451 L/s (a tie: own flow kept) @ 100.0 m +
    // the sized fill friction + 5 m > 86.536 -> the fill sets the head.
    final c = _load(
        _zoned(
            lowTop: 24,
            top: 28,
            upperStacks: 1,
            lowerBoxesAllFloors: false),
        floors: 30,
        floorH: 4.0);
    final low = c.read(firePumpBasisByNodeProvider)['P1']!;
    const own = 1.2 + 15 + _resid;
    expect(low.ownHead!.meters, closeTo(own, 1e-6));
    final ff = _fillFriction(c, low, 'BT');
    final fill = 100.0 + ff + 5.0;
    expect(low.fillHeadM, closeTo(fill, 1e-9));
    expect(low.fillGovernsHead, isTrue);
    expect(low.fillGovernsFlow, isFalse);
    expect(low.head.meters, closeTo(fill, 1e-9));
    expect(low.flow.inLitersPerSecond, closeTo(_q500, 1e-4));
    expect(fireRelayFillHeadM(liftM: 100, frictionM: ff), closeTo(fill, 1e-9));
  });

  test('drawing C: a zone still above 350 psi warns naming the zone', () {
    // 30 storeys x 6.5 m, BT on L28 (182.0 m), zone 2 = L29: fill head >=
    // 182 + 5 = 187 m, churn >= 1.4 x 187 = 261.8 m = 2567 kPa > 2413 kPa
    // (350 psi): the lower zone still needs a further split.
    final c = _load(
        _zoned(
            lowTop: 27,
            top: 29,
            upperStacks: 1,
            lowerBoxesAllFloors: false),
        floors: 30,
        floorH: 6.5);
    final over = [
      for (final i in c.read(designIssuesProvider))
        if (i.kind.endsWith('system-over-pressure:P1')) i,
    ];
    expect(over, hasLength(1));
    expect(over.single.message, startsWith('Fire zone 1 (L0): '));
  });

  testWidgets('calc report: one block per zone + the break tank',
      (tester) async {
    late WidgetRef captured;
    await tester.pumpWidget(ProviderScope(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(builder: (context, ref, _) {
          captured = ref;
          return const SizedBox.shrink();
        }),
      ),
    ));
    await tester.pump();
    final c = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
        listen: false);
    c.read(projectControllerProvider.notifier)
      ..setFloors([for (var i = 0; i < 12; i++) Floor('L$i', const Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    c.read(networkControllerProvider.notifier).loadNetwork(_zoned());
    await tester.pump();
    final data = buildMechanicalReportData(captured);
    expect([for (final z in data.fireZones) z.number], [1, 2]);
    expect(data.fireZones[0].floors, 'L0-L5');
    expect(data.fireZones[1].floors, 'L7-L11');
    expect(data.fireZones[0].fillLps, closeTo(_q750, 1e-4));
    expect(data.fireZones[1].breakRequiredLitres, closeTo(_break, 1e-6));
    expect(data.fireZones[1].breakCapacityLitres, 60000);
    final md = buildCalcReportMarkdown(data);
    expect(md, contains('Fire zone 1 (L0-L5)'));
    expect(md, contains('Fire zone 1 relay duty'));
    expect(md, contains('flow set by the fill, head by the own zone'));
    expect(md, contains('Fire zone 2 break tank'));
    expect(md, contains('85172 L required'));
    expect(md, contains('Fire zone 2 (L7-L11)'));
  });

  test('a building with no break tank: one zone, no zone surfaces', () {
    final c = _load(Network(nodes: [
      _n('FT', 0, 100, c: NodeComponent.groundTank, tankL: 120000),
      _n('P1', 50, 100, c: NodeComponent.pump),
      for (var f = 0; f <= 3; f++) ...[
        _n('H$f', 100, 100, floor: f),
        _n('BX$f', 200, 100, floor: f, c: NodeComponent.hydrantBox),
      ],
    ], edges: [
      _e('s1', 'FT', 'P1'),
      _e('d1', 'P1', 'H0'),
      for (var f = 1; f <= 3; f++)
        _e('r$f', 'H${f - 1}', 'H$f', k: EdgeKind.riser),
      for (var f = 0; f <= 3; f++) _e('b$f', 'H$f', 'BX$f'),
    ]));
    expect(fireZoned(c.read(fireZoneChainProvider)), isFalse);
    expect(c.read(fireZoneLinesProvider), isEmpty);
    expect(c.read(fireBreakTankChecksProvider), isEmpty);
    final b = c.read(firePumpBasisByNodeProvider)['P1']!;
    expect(b.fillTankId, isNull);
    expect(b.fillHeadM, isNull);
  });
}
