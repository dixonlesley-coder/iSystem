/// ROUND 13 (2026-10-18) — app-side findings, each pinned by a hand-derived
/// case and (where the rule is a property) a seeded property test:
///   ui-journey-2  look-and-leave never writes (SteppedValueField editSeed
///                 guard: Mixed size / Auto ACH / electrical-load default);
///                 the electrical-load field shows the FED load; the ACH box
///                 pre-fills only an override; a floor's rooms/tanks/
///                 measurements count in the delete confirmation; a no-op
///                 tank/room edit records no undo step;
///   export-files  sanitised submittal file names, E-10k electrical layout
///                 numbering + Daftar Gambar rows, stale-file pruning, the
///                 document number as a PREFIX.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/document_control_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/floor_remap.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/stepped_value_field.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/model.dart' show ElectricalProject;
import 'package:mechx_engine/geometry/building.dart' show Floor;
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/standards/ventilation.dart' show RoomType;
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

Widget _host(Widget child, {double width = 260}) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

Future<ProviderContainer> _bootApp(WidgetTester tester) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false,
  );
  seedDemoSheets(container);
  await tester.pump();
  return container;
}

/// Real Roboto metrics (the app's bundled font) — the default test font
/// (Ahem) renders every glyph one em wide, so a normal inspector row would
/// report a phantom overflow.
Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

void main() {
  setUpAll(_loadFonts);

  // ── SteppedValueField: an untouched commit is a no-op ──────────────────────
  group('ui-journey-2 — look-and-leave never writes', () {
    testWidgets('an empty seed (Mixed / Auto) tapped and committed: no submit',
        (tester) async {
      setDesktopSurface(tester);
      var calls = 0;
      await tester.pumpWidget(_host(SteppedValueField(
        display: 'Mixed',
        editSeed: '',
        onDecrement: () {},
        onIncrement: () {},
        onSubmit: (_) => calls++,
      )));
      await tester.tap(find.text('Mixed'));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(calls, 0); // was onSubmit(null) ⇒ every manual size wiped
      expect(find.byType(EditableText), findsNothing);
    });

    testWidgets('clearing a NON-empty box still submits null (explicit Auto)',
        (tester) async {
      setDesktopSurface(tester);
      final got = <double?>[];
      await tester.pumpWidget(_host(SteppedValueField(
        display: '3.00 m',
        editSeed: '3.00',
        onDecrement: () {},
        onIncrement: () {},
        onSubmit: got.add,
      )));
      await tester.tap(find.text('3.00 m'));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(got, [null]);
    });

    testWidgets('property: an untouched seed never submits (seeded)',
        (tester) async {
      setDesktopSurface(tester);
      final rnd = math.Random(1313);
      for (var trial = 0; trial < 12; trial++) {
        final seed = rnd.nextBool()
            ? ''
            : (rnd.nextDouble() * 100).toStringAsFixed(rnd.nextInt(3));
        var calls = 0;
        await tester.pumpWidget(_host(SteppedValueField(
          key: ValueKey(trial),
          display: 'v$trial',
          editSeed: seed,
          onDecrement: () {},
          onIncrement: () {},
          onSubmit: (_) => calls++,
        )));
        await tester.tap(find.text('v$trial'));
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(calls, 0, reason: 'seed "$seed"');
      }
    });

    testWidgets('a long display ellipsizes in a narrow column (no overflow)',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(_host(
        SteppedValueField(
          display: '0.49 kW · solved duty · a long caption tail',
          editSeed: '',
          onDecrement: () {},
          onIncrement: () {},
          onSubmit: (_) {},
        ),
        width: 140,
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Mixed size on two hand-sized runs survives a tap-and-commit',
        (tester) async {
      final c = await _bootApp(tester);
      final sheet = c.read(sheetsControllerProvider).current!;
      c.read(networkControllerProvider.notifier).loadNetwork(Network(
            nodes: [
              for (final (id, x) in [('a', 100.0), ('b', 300.0), ('d', 500.0)])
                NetNode(id: id, sheetId: sheet.id, x: x, y: 200, floorIndex: 0),
            ],
            edges: [
              NetEdge(
                  id: 'e1',
                  fromId: 'a',
                  toId: 'b',
                  service: ServiceType.coldWater,
                  sizeOverride: Diameter.mm(50)),
              NetEdge(
                  id: 'e2',
                  fromId: 'b',
                  toId: 'd',
                  service: ServiceType.coldWater,
                  sizeOverride: Diameter.mm(80)),
            ],
          ));
      c.read(selectionProvider.notifier).setMulti(const {}, const {'e1', 'e2'});
      await tester.pumpAndSettle();
      final mixed = find.text('Mixed');
      expect(mixed, findsWidgets);
      await tester.tap(mixed.first);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      final edges = c.read(networkControllerProvider).network.edges;
      expect(edges.firstWhere((e) => e.id == 'e1').sizeOverride?.inMillimeters,
          50);
      expect(edges.firstWhere((e) => e.id == 'e2').sizeOverride?.inMillimeters,
          80);
    });
  });

  // ── the electrical-load field reads the FED load ───────────────────────────
  group('ui-journey-2 — nodeFedLoadsProvider is the one fed-load source', () {
    ProviderContainer setup({double? overrideW}) {
      final c = ProviderContainer();
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
      c.read(roomAreasProvider.notifier).set(const [
        RoomArea(
            id: 'r0',
            sheetId: 's1',
            floorIndex: 0,
            ax: 0,
            ay: 0,
            bx: 200,
            by: 100),
      ]);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
            NetNode(
              id: 'ac1',
              sheetId: 's1',
              x: 100,
              y: 50,
              floorIndex: 0,
              role: NodeRole.plant,
              component: NodeComponent.acCassette,
              electricalLoadW: overrideW,
            ),
          ]));
      return c;
    }

    test('an AC in a 2 m² office feeds the room-PK load, labelled roomPk', () {
      final c = setup();
      addTearDown(c.dispose);
      // 2 m² × 600 BTU/h·m² = 1200 BTU/h → 0.5 PK rung = 5000 BTU/h nominal
      // → 5000 / 3.412 / COP 3 = 488 W (NOT the 1.8 kW cassette default).
      final expected = acInputPowerW(coolingBtuPerHr: 5000.0);
      final fed = c.read(nodeFedLoadsProvider)['ac1']!;
      expect(fed.source, NodeLoadSource.roomPk);
      expect(fed.watts, closeTo(expected, 1e-6));
      // The panel feed carries the SAME figure (one source).
      expect(c.read(placedEquipmentLoadsProvider).single.mechanicalPower.watts,
          fed.watts);
    });

    test('an explicit override is labelled explicit and wins', () {
      final c = setup(overrideW: 1234);
      addTearDown(c.dispose);
      final fed = c.read(nodeFedLoadsProvider)['ac1']!;
      expect(fed.source, NodeLoadSource.explicit);
      expect(fed.watts, 1234);
    });
  });

  // ── ACH: Auto stays Auto on a look-and-leave ───────────────────────────────
  testWidgets('ACH: tapping the auto 6/h and committing keeps Auto', (tester) async {
    final c = await _bootApp(tester);
    final sheet = c.read(sheetsControllerProvider).current!;
    c
        .read(projectControllerProvider.notifier)
        .setCalibration(sheet.id, const ScaleCalibration(0.01));
    c.read(roomAreasProvider.notifier).set([
      RoomArea(
          id: 'r0',
          sheetId: sheet.id,
          floorIndex: 0,
          ax: 0,
          ay: 0,
          bx: 400,
          by: 300),
    ]);
    c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
    c.read(selectedAnnotationProvider.notifier).selectRoom('r0');
    c.read(sectionVisibilityProvider.notifier).set('Rooms', true);
    c.read(sectionVisibilityProvider.notifier).set('Room settings', true);
    await tester.pumpAndSettle();
    final ach = find.text('6/h');
    expect(ach, findsOneWidget);
    await tester.ensureVisible(ach);
    await tester.tap(ach);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(c.read(roomAreasProvider).single.achOverride, isNull);
    // So a room-type change still follows SNI 03-6572 Tabel 4.4.1 (toilet 10).
    c.read(roomAreasProvider.notifier).setRoomType('r0', RoomType.toilet);
    expect(c.read(roomAreasProvider).single.effectiveAch(),
        RoomArea(
                id: 'x',
                sheetId: 's',
                floorIndex: 0,
                ax: 0,
                ay: 0,
                bx: 1,
                by: 1,
                roomType: RoomType.toilet)
            .effectiveAch());
  });

  // ── floor delete counts every kind of floor-placed work ────────────────────
  group('ui-journey-2 — a level\'s rooms / tanks / measurements count', () {
    test('floorPlacedWorkCount names what remapFloorPlacedWork removes', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(projectControllerProvider.notifier).setFloors(const [
        Floor('Ground', Length(4)),
        Floor('Level 1', Length(4)),
      ]);
      c.read(roomAreasProvider.notifier).set(const [
        RoomArea(
            id: 'r0', sheetId: 's1', floorIndex: 1, ax: 0, ay: 0, bx: 9, by: 9),
        RoomArea(
            id: 'r1', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 9, by: 9),
      ]);
      c.read(tankAreasProvider.notifier).set(const [
        TankArea(
            id: 't0', sheetId: 's1', floorIndex: 1, ax: 0, ay: 0, bx: 9, by: 9),
      ]);
      final count = floorPlacedWorkCount(c.read, (fi) => fi == 1);
      expect(count.rooms, 1);
      expect(count.tanks, 1);
      expect(count.total, 2);
      // …and removing Level 1 really does delete exactly those.
      c.read(projectControllerProvider.notifier).removeFloor(1);
      expect(c.read(roomAreasProvider).map((r) => r.id), ['r1']);
      expect(c.read(tankAreasProvider), isEmpty);
    });
  });

  // ── no-op annotation edits record no undo step ─────────────────────────────
  test('re-picking the same room type / a clamp step records no undo', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(roomAreasProvider.notifier).set(const [
      RoomArea(
          id: 'r0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 9, by: 9),
    ]);
    final before = c.read(historyProvider);
    final ctrl = c.read(roomAreasProvider.notifier);
    ctrl.setRoomType('r0', c.read(roomAreasProvider).single.roomType);
    ctrl.setAch('r0', 0.1); // clamps to 0.5 — a real change, records once
    final afterOne = c.read(historyProvider);
    ctrl.setAch('r0', 0.2); // clamps to 0.5 again — no change, no record
    expect(afterOne, before + 1);
    expect(c.read(historyProvider), afterOne);
  });

  // ── the submittal package ───────────────────────────────────────────────────
  group('export-files — the submittal package', () {
    Future<WidgetRef> harness(WidgetTester tester) async {
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(builder: (context, ref, _) {
              capturedRef = ref;
              return const SizedBox.shrink();
            }),
          ),
        ),
      );
      await tester.pump();
      return capturedRef;
    }

    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mechx_r13_'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Set<String> names() => dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .map(Uri.decodeComponent)
        .toSet();

    testWidgets("'Ruko A/B' + sheet 'GF/LG' write a complete package",
        (tester) async {
      final ref = await harness(tester);
      ref.read(projectControllerProvider.notifier).setName('Ruko A/B');
      ref.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'GF/LG', sizePx: Size(1000, 800)),
      ]);
      final wrote = await tester
          .runAsync(() => writeSubmittalPackageToDir(ref, dir.path));
      expect(wrote, isTrue); // used to throw PathNotFoundException
      final files = names();
      expect(files, contains('Ruko A_B-00-cover-sheets.pdf'));
      expect(files, contains('Ruko A_B-plan-1-GF_LG.pdf'));
      expect(files, contains('Ruko A_B-plan-1-GF_LG.dxf'));
      expect(files.every((f) => !f.contains(':') && !f.contains('/')), isTrue);
    });

    testWidgets('each electrical layout plan gets E-10k + its own row',
        (tester) async {
      final ref = await harness(tester);
      ref.read(projectControllerProvider.notifier).setName('Tower');
      ref.read(projectControllerProvider.notifier).setFloors(const [
        Floor('Ground', Length(4)),
        Floor('Level 1', Length(4)),
      ]);
      ref.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground', sizePx: Size(1000, 800)),
        Sheet(id: 's2', name: 'Level 1', sizePx: Size(1000, 800)),
      ]);
      final sheets = ref.read(sheetsControllerProvider);
      final f1 = sheets.floorFor('s1', 2), f2 = sheets.floorFor('s2', 2);
      final sample = sampleElectricalProject();
      ref.read(electricalProjectProvider.notifier).setProject(ElectricalProject(
            id: sample.id,
            name: sample.name,
            panels: [
              for (var i = 0; i < sample.panels.length; i++)
                i == 0
                    ? sample.panels[i].copyWith(
                        layoutPos: LayoutPos(
                            sheetId: 's1', floorIndex: f1, x: 100, y: 100))
                    : i == 1
                        ? sample.panels[i].copyWith(
                            layoutPos: LayoutPos(
                                sheetId: 's2', floorIndex: f2, x: 200, y: 200))
                        : sample.panels[i],
            ],
          ));
      await tester.pump();
      await tester.runAsync(() => writeSubmittalPackageToDir(ref, dir.path));
      String read(String n) =>
          File('${dir.path}${Platform.pathSeparator}$n').readAsStringSync();
      final dxf1 = read('Tower-elec-plan-1-Ground.dxf');
      final dxf2 = read('Tower-elec-plan-2-Level 1.dxf');
      // Was: both 'E-101' / '1 of 1'.
      expect(dxf1, contains('E-101'));
      expect(dxf2, contains('E-102'));
      expect(dxf2, isNot(contains('E-101')));
    });

    testWidgets('re-exporting a smaller set prunes the superseded files',
        (tester) async {
      final ref = await harness(tester);
      ref.read(projectControllerProvider.notifier).setName('Tower');
      ref.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground', sizePx: Size(1000, 800)),
        Sheet(id: 's2', name: 'Level 1', sizePx: Size(1000, 800)),
      ]);
      ref
          .read(electricalProjectProvider.notifier)
          .setProject(sampleElectricalProject());
      await tester.pump();
      await tester.runAsync(() => writeSubmittalPackageToDir(ref, dir.path));
      // An unrelated file sharing the stem, and another project's file, stay.
      File('${dir.path}${Platform.pathSeparator}Tower-notes.txt')
          .writeAsStringSync('keep');
      File('${dir.path}${Platform.pathSeparator}Other-plan-1-X.pdf')
          .writeAsStringSync('keep');
      expect(names(), contains('Tower-plan-2-Level 1.pdf'));
      expect(names(), contains('Tower-electrical-riser.dxf'));

      // Second revision: one sheet, electrical cleared.
      ref.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground', sizePx: Size(1000, 800)),
      ]);
      ref
          .read(electricalProjectProvider.notifier)
          .setProject(const ElectricalProject());
      await tester.pump();
      final removed = <String>[];
      await tester.runAsync(() =>
          writeSubmittalPackageToDir(ref, dir.path, removedOut: removed));
      final files = names();
      expect(files, isNot(contains('Tower-plan-2-Level 1.pdf')));
      expect(files, isNot(contains('Tower-plan-2-Level 1.dxf')));
      expect(files.where((f) => f.startsWith('Tower-electrical')), isEmpty);
      expect(files, contains('Tower-plan-1-Ground.pdf'));
      expect(files, contains('Tower-notes.txt'));
      expect(files, contains('Other-plan-1-X.pdf'));
      expect(removed, isNotEmpty);
    });

    testWidgets('a filled document number PREFIXES every sheet number',
        (tester) async {
      final ref = await harness(tester);
      ref.read(projectControllerProvider.notifier).setName('Tower');
      ref.read(documentControlProvider.notifier).setDocumentNumber('BRI-MEP-01');
      ref.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground', sizePx: Size(1000, 800)),
        Sheet(id: 's2', name: 'Level 1', sizePx: Size(1000, 800)),
      ]);
      await tester.runAsync(() => writeSubmittalPackageToDir(ref, dir.path));
      String read(String n) =>
          File('${dir.path}${Platform.pathSeparator}$n').readAsStringSync();
      expect(read('Tower-plan-1-Ground.dxf'), contains('BRI-MEP-01-M-101'));
      expect(read('Tower-plan-2-Level 1.dxf'), contains('BRI-MEP-01-M-102'));
      expect(read('Tower-riser-sld.dxf'), contains('BRI-MEP-01-M-201'));
    });
  });
}
