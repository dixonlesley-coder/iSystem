// Round 17 follow-up (2026-10-18) — the app half of the follow-up audit:
//
//   hw-recirc-drawn-loop      a DRAWN return is the loop (no phantom DN20 leg)
//   fire-headline / FP-01     a sprinkler-only pump reads as a sprinkler pump
//   electrical-inspector-ib   the inspector Ib is the RUN current (report parity)
//   locale-number             ID separators in every engineering number field
//   gravity-below-code-min    a hand pick under the code minimum reaches Review
//   gravity-velocity-verdict  stacks get no velocity verdict; G1 is repeated
//   riser-ghost               a riser top re-homes onto the floor's new plan
//   assembly-stamp            a multi-floor assembly lands on each floor's plan
//   room-terminals-stale      a room edit after Auto-place warns
//   stepper-honesty           Size needs every drawn sheet measured; File>New
//                             resets the Building visit
import 'package:flutter/widgets.dart' hide Velocity;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/air_warnings_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/electrical/electrical_format.dart';
import 'package:mechx/ui/electrical/electrical_inspector.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/strings/app_strings.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/electrical/electrical_controls.dart';
import 'package:mechx/ui/widgets/locale_number.dart';
import 'package:mechx/ui/widgets/stepped_value_field.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/report_strings.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        String sheet = 's1',
        NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: sheet,
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c,
        fixture: fixture);

NetEdge _e(String id, String a, String b,
        {ServiceType service = ServiceType.coldWater,
        EdgeKind kind = EdgeKind.run,
        Diameter? size}) =>
    NetEdge(
        id: id,
        fromId: a,
        toId: b,
        service: service,
        kind: kind,
        sizeOverride: size);

ProviderContainer _container(Network net, {int floors = 3}) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  // ── hw-recirc-drawn-loop ──────────────────────────────────────────────────
  group('hw-recirc: a drawn return closes the loop', () {
    // Heater H → A (20) → B (20), fixture F on B (3, a dead leg), and a
    // DRAWN return B → C (20) → check valve V (20) → H (20).
    final net = Network(nodes: [
      _n('H', 0, 0, role: NodeRole.plant),
      _n('A', 1, 0),
      _n('B', 2, 0),
      _n('F', 2, 1,
          role: NodeRole.fixture, fixture: PlumbingFixture.shower),
      _n('C', 3, 0),
      _n('V', 4, 0, c: NodeComponent.checkValve),
    ], edges: [
      _e('ha', 'H', 'A', service: ServiceType.hotWater),
      _e('ab', 'A', 'B', service: ServiceType.hotWater),
      _e('bf', 'B', 'F', service: ServiceType.hotWater),
      _e('bc', 'B', 'C', service: ServiceType.hotWater),
      _e('cv', 'C', 'V', service: ServiceType.hotWater),
      _e('vh', 'V', 'H', service: ServiceType.hotWater),
    ]);
    const len = {'ha': 20.0, 'ab': 20.0, 'bf': 3.0, 'bc': 20.0, 'cv': 20.0,
        'vh': 20.0};
    const bore = Diameter(0.025);
    final sizing = {
      for (final e in net.edges)
        e.id: EdgeSizing(
            edgeId: e.id,
            service: ServiceType.hotWater,
            flow: const FlowRate(0.0001),
            diameter: bore,
            velocity: const Velocity(0.2)),
    };

    test('no phantom return: heat loss on 100 m, head around the 100 m loop',
        () {
      final loop = hotWaterRecircLoop(net, sizing, lengthOf: (e) => len[e.id]!)!;
      // Circulated = the five loop edges (the 3 m shower branch is a dead leg).
      expect(loop.circulatedLengthM, closeTo(100, 1e-9));
      // The drawn return is already inside it — no mirrored 40 m DN20 leg.
      expect(loop.returnLengthM, 0.0);
      expect(loop.drawnLoopLengthM, closeTo(100, 1e-9));
      final idx = loop.indexPath.fold<double>(0, (a, s) => a + s.length.meters);
      expect(idx, closeTo(100, 1e-9));
      expect(loop.indexPath, hasLength(5));

      // Q = 25 W/m × 100 m / (ρ c ΔT) = 2500 / (1000 × 4186 × 5)
      //   = 0.1194 L/s (the phantom return gave 0.1672, +40 %).
      final d = sizeHotWaterRecirculation(
        heatLoss: heatLossFromLength(
            loopLength: Length(loop.circulatedLengthM + loop.returnLengthM)),
        loopLength: Length(loop.returnLengthM),
        returnDiameter: kDefaultRecircReturnDiameter,
        supplyPath: loop.indexPath,
      );
      final q = 25 * 100 / (1000 * waterSpecificHeat * 5);
      expect(d.recircFlow.cubicMetersPerSecond, closeTo(q, 1e-12));
      // Head = Hazen–Williams friction over the 100 m of real DN25 bore.
      final h = headLossHazenWilliams(
              flow: FlowRate(q),
              length: const Length(100),
              diameter: bore,
              hazenWilliamsC: 150)
          .meters;
      expect(d.loopHead.meters, closeTo(h, 1e-9));
    });

    test('a TREE (no drawn return) keeps the mirrored DN20 return', () {
      final tree = Network(
          nodes: net.nodes,
          edges: net.edges.where((e) => e.id != 'vh').toList());
      // Without vh, V is a bare open leaf ⇒ cv is a dead leg; circulated =
      // ha + ab + bc = 60 m, the index run the return mirrors.
      final loop =
          hotWaterRecircLoop(tree, sizing, lengthOf: (e) => len[e.id]!)!;
      expect(loop.drawnLoopLengthM, isNull);
      expect(loop.circulatedLengthM, closeTo(60, 1e-9));
      expect(loop.returnLengthM, closeTo(60, 1e-9));
    });
  });

  // ── fire headline / FP-01 ─────────────────────────────────────────────────
  group('fire: a sprinkler-only pump reads as a sprinkler pump', () {
    final sprinklerOnly = Network(nodes: [
      _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('S', 300, 0, role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
    ], edges: [
      _e('ps', 'P', 'S', service: ServiceType.fireSprinkler),
    ]);

    test('the headline head is the governing rated point, label sprinkler', () {
      final c = _container(sprinklerOnly, floors: 8);
      final rp = c.read(fireRatedPointProvider);
      expect(rp.sprinklerOnly, isTrue);
      final rating = c.read(firePumpRatingProvider);
      final text = fireHeadlineText(rp.head, rating.selectedMotor);
      // The head printed is the SPRINKLER rated head, never the standpipe's.
      expect(text, startsWith('${rp.head.meters.toStringAsFixed(0)} m'));
      final standpipeHead = c.read(standpipeDesignProvider).pumpHead.meters;
      expect(rp.head.meters, lessThan(standpipeHead));
      expect(text, isNot(startsWith('${standpipeHead.toStringAsFixed(0)} m')));
      expect(fireHeadlineLabel(sprinklerOnly: true), 'Fire pump (sprinkler)');
      expect(fireHeadlineLabel(sprinklerOnly: false), 'Fire pump (standpipe)');
    });

    testWidgets('FP-01 is scheduled as a sprinkler pump (EN + ID key)',
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
      final c = ProviderScope.containerOf(tester.element(find.byType(Consumer)),
          listen: false);
      c.read(projectControllerProvider.notifier)
        ..setFloors([for (var i = 0; i < 8; i++) Floor('L$i', const Length(3.5))])
        ..setCalibration('s1', const ScaleCalibration(0.01));
      c.read(networkControllerProvider.notifier).loadNetwork(sprinklerOnly);
      // Let the electrical project's MEP auto-sync settle (a microtask).
      await tester.pump();
      c.read(electricalResultProvider);
      await tester.pump();
      final pumps = gatherEquipmentScheduleData(captured).pumps;
      // Round 28 — the drawn pump's row carries its OWN fire system's duty
      // (here the only, governing system: the same rated point as the
      // project-level duty).
      final own = c.read(firePumpBasisByNodeProvider)['P']!.duty!;
      final fp = pumps.singleWhere((p) => identical(p.duty, own));
      final project = c.read(firePumpDutyProvider)!;
      expect(own.flow.cubicMetersPerSecond,
          closeTo(project.flow.cubicMetersPerSecond, 1e-12));
      expect(own.head.meters, closeTo(project.head.meters, 1e-9));
      expect(own.selectedMotor.watts, project.selectedMotor.watts);
      expect(fp.service, 'Fire sprinkler pump');
      expect(const ReportStrings.id()(RptStringKey.esSvcFireSprinkler),
          'Pompa sprinkler kebakaran');
    });
  });

  // ── electrical-inspector-ib ───────────────────────────────────────────────
  testWidgets('electrical inspector Ib is the run current (report parity)',
      (tester) async {
    setDesktopSurface(tester);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // 1φ 230 V board, socket way 3000 W, cos φ 0.9, demand factor 0.5, 20 m.
    final ctrl = c.read(electricalProjectProvider.notifier);
    ctrl.setProject(const ElectricalProject(id: 'p', name: 'B', panels: [
      ElectricalPanel(
        id: 'DB',
        name: 'DB',
        system: ElectricalSystem.singlePhase,
        voltage: Voltage(230),
        circuits: [
          ElectricalCircuit(
            id: 'w',
            name: 'Sockets',
            loadKind: LoadKind.socket,
            loadW: 3000,
            cosPhi: 0.9,
            demandFactor: 0.5,
            length: Length(20),
          ),
        ],
      ),
    ]));
    final live = c.read(electricalProjectProvider);
    final result = computeSystem(const PuilProfile(), live);
    final way = result.panels['DB']!.circuits.single;
    // Run current = 3000 / (230 × 0.9) = 14.49 A; the diversified design
    // current is half of it — the two MUST differ for this test to bite.
    expect(way.runCurrentA.amperes, closeTo(3000 / (230 * 0.9), 0.05));
    expect(way.designCurrent.amperes,
        closeTo(way.runCurrentA.amperes * 0.5, 0.05));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 340,
                height: 800,
                child: ElectricalCircuitInspector(
                  panel: live.panels.single,
                  circuit: live.panels.single.circuits.single,
                  controller: ctrl,
                  onClose: () {},
                  inline: true,
                  circuitResult: way,
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('${fmtNum(way.runCurrentA.amperes)} A'), findsWidgets);
    expect(find.text('Ib (diversified)'), findsOneWidget);
    expect(find.text('${fmtNum(way.designCurrent.amperes)} A'), findsWidgets);
  });

  // ── locale-number ─────────────────────────────────────────────────────────
  group('locale-aware engineering numbers', () {
    test('ID: dot groups thousands, comma is the decimal', () {
      expect(parseLocaleNumber('33.000', indonesian: true), 33000);
      expect(parseLocaleNumber('5.500', indonesian: true), 5500);
      expect(parseLocaleNumber('0,85', indonesian: true), closeTo(0.85, 1e-12));
      expect(parseLocaleNumber('1.250,5', indonesian: true), 1250.5);
      // A lone-0 integer part is always decimal (no thousands group starts 0).
      expect(parseLocaleNumber('0.125', indonesian: true), 0.125);
      expect(parseLocaleNumber('-2,5', indonesian: true), -2.5);
      expect(parseLocaleNumber('abc', indonesian: true), isNull);
    });

    test('EN keeps the dot decimal; NaN / 1e999 reach the finite check', () {
      expect(parseLocaleNumber('33.000', indonesian: false), 33.0);
      expect(parseLocaleNumber('0.85', indonesian: false), 0.85);
      expect(parseLocaleNumber('1,500', indonesian: false), 1500);
      expect(parseLocaleNumber('1e-3', indonesian: false), 0.001);
      expect(parseLocaleNumber('NaN', indonesian: false)!.isNaN, isTrue);
      expect(parseLocaleNumber('1e999', indonesian: false)!.isFinite, isFalse);
    });

    testWidgets('a SteppedValueField in the ID UI reads 1.500 as 1500 and '
        'localizes its errors', (tester) async {
      setDesktopSurface(tester);
      double? got;
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MechXTheme(
            data: MechXThemeData.dark,
            child: MechXStrings(
              data: const MechXStringsData(AppLocale.id),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 260,
                  child: SteppedValueField(
                    display: '500 L',
                    editSeed: '500',
                    max: 10000,
                    onDecrement: () {},
                    onIncrement: () {},
                    onSubmit: (v) => got = v,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('500 L'));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '1.500');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(got, 1500);

      await tester.tap(find.text('500 L'));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '20.000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Masukkan nilai maksimal 10000'), findsOneWidget);
      await tester.enterText(find.byType(EditableText), 'x');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Masukkan angka'), findsOneWidget);
    });

    // Round 18 review follow-up: a dot-decimal DISPLAY re-read by the ID
    // rules turned an edited `1.126` into 1126. The field now SHOWS the
    // locale's decimal comma, so editing the shown text round-trips.
    test('localizeNumberText round-trips through parseLocaleNumber', () {
      expect(localizeNumberText('1.125', indonesian: true), '1,125');
      expect(localizeNumberText('1.125', indonesian: false), '1.125');
      expect(localizeNumberText('33000', indonesian: true), '33000');
      expect(localizeNumberText('1e-7', indonesian: true), '1e-7');
      for (final v in [1.125, 0.85, 12.5, 2.375, -4.25, 33000.0, 1250.125]) {
        for (final id in [true, false]) {
          final plain = v == v.roundToDouble()
              ? v.toInt().toString()
              : v.toString();
          expect(
              parseLocaleNumber(localizeNumberText(plain, indonesian: id),
                  indonesian: id),
              v,
              reason: 'v=$v id=$id');
        }
      }
    });

    testWidgets('an ID ElectricalNumInput shows 1,125 and an edit to 1,126 '
        'commits 1.126 (never 1126)', (tester) async {
      setDesktopSurface(tester);
      final commits = <double>[];
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MechXTheme(
            data: MechXThemeData.dark,
            child: MechXStrings(
              data: const MechXStringsData(AppLocale.id),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 260,
                  child: ElectricalNumInput(
                      value: 1.125, onChanged: commits.add),
                ),
              ),
            ),
          ),
        ),
      ));
      expect(find.text('1,125'), findsOneWidget);
      await tester.enterText(find.byType(EditableText), '1,126');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(commits, [1.126]);
    });
  });

  // ── gravity-below-code-min + gravity-velocity-verdict ─────────────────────
  group('gravity verdicts on the app surfaces', () {
    // A 3-storey drainage stack of lavatories: L2 lav → stack → L0 outfall.
    Network stack({Diameter? stackSize}) => Network(nodes: [
          _n('O', 0, 0, role: NodeRole.plant),
          _n('S1', 0, 0, floor: 1),
          _n('S2', 0, 0, floor: 2),
          for (var f = 0; f < 3; f++)
            for (var i = 0; i < 4; i++)
              _n('W${f}_$i', 100.0 + 100 * i, 0,
                  floor: f,
                  role: NodeRole.fixture,
                  fixture: PlumbingFixture.waterClosetFlushTank),
        ], edges: [
          _e('st1', 'S1', 'O',
              service: ServiceType.drainage,
              kind: EdgeKind.riser,
              size: stackSize),
          _e('st2', 'S2', 'S1',
              service: ServiceType.drainage, kind: EdgeKind.riser),
          for (var f = 0; f < 3; f++)
            for (var i = 0; i < 4; i++)
              _e('b${f}_$i', 'W${f}_$i', f == 0 ? 'O' : 'S$f',
                  service: ServiceType.drainage),
        ]);

    test('a stack hand-picked under its code minimum is a Review warning', () {
      final auto = _container(stack());
      final autoSize = auto.read(sizingProvider)['st1']!.diameter.inMillimeters;
      // 8 WCs reach st1 (> 6 on a riser) ⇒ the DN100 floor.
      expect(autoSize, closeTo(100, 1e-9));
      expect(auto.read(belowCodeMinimumEdgesProvider), isEmpty);

      final c = _container(stack(stackSize: Diameter.mm(75)));
      expect(c.read(sizingProvider)['st1']!.belowCodeMinimum, isTrue);
      expect(c.read(belowCodeMinimumEdgesProvider), {'st1'});
      final issues = c.read(designIssuesProvider);
      expect(
          issues.where((i) => i.kind == 'gravity-below-code-minimum'),
          hasLength(1));
    });

    test('no velocity verdict on a stack; drainage runs repeat the engine', () {
      final c = _container(stack());
      final checks = c.read(waterVelocityChecksProvider);
      final sizing = c.read(sizingProvider);
      expect(checks.containsKey('st1'), isFalse);
      expect(checks.containsKey('st2'), isFalse);
      for (final e in checks.entries) {
        final s = sizing[e.key]!;
        if (s.service != ServiceType.drainage) continue;
        // Self-cleansing OK to the engine ⇒ never 'too low' in the inspector.
        if (s.selfCleansingOk) {
          expect(e.value.isWarning, isFalse, reason: e.key);
        }
      }
    });
  });

  // ── riser-ghost ───────────────────────────────────────────────────────────
  test('riser-ghost: the riser top re-homes onto the floor\'s new plan', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(sheetsControllerProvider.notifier)
        .loadSheets(const [Sheet(id: 'gf', name: 'Ground')]);
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRiser);
    n.placeRiser('gf', 0, const Offset(300, 300), 3);
    var net = c.read(networkControllerProvider).network;
    final top = net.nodes.singleWhere((x) => x.floorIndex == 1);
    // No floor-1 plan yet ⇒ the far node falls back to the source sheet.
    expect(top.sheetId, 'gf');

    // Import the L1 plan: positional floor 1.
    c.read(sheetsControllerProvider.notifier)
        .addSheets(const [Sheet(id: 'l1', name: 'Level 1')]);
    net = c.read(networkControllerProvider).network;
    expect(net.nodeById(top.id)!.sheetId, 'l1');
    expect(net.nodeById(top.id)!.floorIndex, 1);
    // Round 18 review follow-up: the re-home rides the (non-undoable) import,
    // so it adds NO undo step — Ctrl+Z reverts the riser placement itself,
    // never a torn 'riser top back on the ghost sheet' with the plan kept.
    final hist = c.read(historyProvider.notifier);
    hist.undo();
    expect(c.read(networkControllerProvider).network.nodeById(top.id), isNull);
    hist.redo();
    net = c.read(networkControllerProvider).network;
    expect(net.nodeById(top.id)!.sheetId, 'l1');

    // A cold-water run started ON the riser top tees into it: one component.
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('l1', 1, const Offset(300, 300));
    n.placeRunPoint('l1', 1, const Offset(600, 300));
    net = c.read(networkControllerProvider).network;
    final run = net.edges.singleWhere((e) => e.kind == EdgeKind.run);
    expect({run.fromId, run.toId}, contains(top.id));
  });

  // ── assembly-stamp ────────────────────────────────────────────────────────
  test('assembly-stamp: upper-floor nodes land on the floor-1 plan', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(sheetsControllerProvider.notifier).loadSheets(const [
      Sheet(id: 'gf', name: 'Ground'),
      Sheet(id: 'l1', name: 'Level 1'),
    ]);
    final n = c.read(networkControllerProvider.notifier);
    final r = n.stampAssembly([
      _n('a', 0, 0, sheet: 'x'),
      _n('b', 0, 0, floor: 1, sheet: 'x'),
      _n('cc', 100, 0, floor: 1, sheet: 'x'),
    ], [
      _e('r', 'a', 'b', kind: EdgeKind.riser),
      _e('ru', 'b', 'cc'),
    ], sheetId: 'gf', floorIndex: 0, world: const Offset(500, 500));
    final net = c.read(networkControllerProvider).network;
    for (final id in r.nodeIds) {
      final node = net.nodeById(id)!;
      expect(node.sheetId, node.floorIndex == 0 ? 'gf' : 'l1',
          reason: 'node on floor ${node.floorIndex}');
    }
    expect(r.nodeIds.where((id) => net.nodeById(id)!.floorIndex == 1),
        hasLength(2));
  });

  // ── room-terminals-stale ──────────────────────────────────────────────────
  test('room-terminals-stale: a room edit after Auto-place warns', () {
    final c = _container(const Network(nodes: [], edges: []));
    // 10 × 8 m office (1000 × 800 px at 0.01 m/px).
    const room = RoomArea(
        id: 'rm', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1000, by: 800);
    c.read(roomAreasProvider.notifier).set(const [room]);
    c.read(networkControllerProvider.notifier)
        .autoPlaceRoomTerminals(room: room, metersPerPixel: 0.01);
    bool stale() => c
        .read(designIssuesProvider)
        .any((i) => i.kind == 'room-terminals-stale:rm');
    // Freshly placed: placed == required (count × each, exact).
    expect(stale(), isFalse);

    // Office 6 ACH → meeting room 8 ACH: the requirement rises by 8/6.
    c.read(roomAreasProvider.notifier).setRoomType('rm', RoomType.meetingRoom);
    expect(stale(), isTrue);
    // Re-running Auto-place brings the terminals back in line.
    final edited = c.read(roomAreasProvider).single;
    c.read(networkControllerProvider.notifier)
        .autoPlaceRoomTerminals(room: edited, metersPerPixel: 0.01);
    expect(stale(), isFalse);

    // Now an extract-only kitchen still carrying conditioned supply ⇒ stale.
    c.read(roomAreasProvider.notifier)
        .setRoomType('rm', RoomType.commercialKitchen);
    expect(stale(), isTrue);
  });

  // ── stepper-honesty ───────────────────────────────────────────────────────
  group('stepper honesty', () {
    test('Calibrate/Size stay open while the drawn sheet is unmeasured', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 'gf', name: 'Ground'),
        Sheet(id: 'l1', name: 'Level 1'),
      ]);
      c.read(projectControllerProvider.notifier)
          .setCalibration('gf', const ScaleCalibration(0.01));
      final n = c.read(networkControllerProvider.notifier);
      n.setService(ServiceType.coldWater);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('l1', 1, const Offset(0, 0));
      n.placeRunPoint('l1', 1, const Offset(300, 0));
      final s = c.read(workflowStageStateProvider);
      expect(s.done[WorkflowStage.draw], isTrue);
      expect(s.done[WorkflowStage.calibrate], isFalse);
      expect(s.done[WorkflowStage.size], isFalse);
      // Calibrating the drawn sheet closes both.
      c.read(projectControllerProvider.notifier)
          .setCalibration('l1', const ScaleCalibration(0.01));
      final s2 = c.read(workflowStageStateProvider);
      expect(s2.done[WorkflowStage.calibrate], isTrue);
      expect(s2.done[WorkflowStage.size], isTrue);
    });

    test('applying a new document resets the Building visit', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(buildingVisitedProvider.notifier).markVisited();
      expect(c.read(workflowStageStateProvider).done[WorkflowStage.floors],
          isTrue);
      // The File > New virgin document: the untouched default 3-floor seed.
      applyDocument(
          c.read,
          const ProjectDocument(
            projectName: 'New',
            floors: [
              Floor('Ground', Length(4.0)),
              Floor('Level 1', Length(3.5)),
              Floor('Level 2', Length(3.5)),
            ],
            calibrations: {},
            sheets: [],
            network: Network(nodes: [], edges: []),
          ));
      expect(c.read(buildingVisitedProvider), isFalse);
      expect(c.read(workflowStageStateProvider).done[WorkflowStage.floors],
          isFalse);
    });
  });

  // ── small i18n / caption residuals ────────────────────────────────────────
  group('i18n residuals', () {
    const en = MechXStringsData(AppLocale.en);
    const id = MechXStringsData(AppLocale.id);

    test('Auto-place caption states the RETURN count (20×20 m office: 3 + 3)',
        () {
      const room = RoomArea(
          id: 'big', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 2000,
          by: 2000);
      final s = room.sizing(0.01)!;
      final caption = en.format(StringKey.roomAutoPlaceCaption,
          {'supply': s.supply.count, 'return': s.return_.count});
      expect(caption, '${s.supply.count} + ${s.return_.count}');
      expect(s.return_.count, greaterThan(1),
          reason: 'the case the old fixed "+ 1" under-stated');
    });

    test('inspector literals resolve in ID', () {
      expect(id(StringKey.nodeElectricalLoadLabel), 'Beban listrik');
      expect(id(StringKey.electricalFeedCurrentSuffix), ' (saat ini)');
      expect(en(StringKey.electricalFeedCurrentSuffix), ' (current)');
      expect(id(StringKey.inspectorOccupancyPublic), 'Kantor / publik');
      expect(en.format(StringKey.schematicNotesRoofTank, {'m3': '12'}),
          'Roof tank: 12 m3');
      expect(feedChooserItems(
              candidates: const [(id: 'a', label: 'MDP')],
              currentLabel: 'MDP',
              onPick: (_) {},
              currentSuffix: id(StringKey.electricalFeedCurrentSuffix))
          .single
          .label, 'MDP (saat ini)');
    });
  });
}
