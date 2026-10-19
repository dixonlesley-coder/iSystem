@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart' show statusMessageProvider;
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
}

NetNode _n(
  String id,
  double x,
  int floor, {
  NodeRole role = NodeRole.main,
  NodeComponent? component,
}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: 0,
      floorIndex: floor,
      role: role,
      component: component,
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets('single-line draws equipment + fixture symbols per floor',
      (tester) async {
    setDesktopSurface(tester, size: const Size(1100, 760));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Two stacked floors with a small mechanical network: plant + fixtures so
    // the single-line renders real schematic symbols, not anonymous dots.
    container.read(projectControllerProvider.notifier).setFloors(const [
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(4.0)),
    ]);
    container.read(networkControllerProvider.notifier).loadNetwork(Network(
      nodes: [
        _n('pump', 150, 0, role: NodeRole.plant, component: NodeComponent.pump),
        _n('gtank', 430, 0,
            role: NodeRole.plant, component: NodeComponent.groundTank),
        _n('junc', 720, 0),
        _n('rtank', 250, 1,
            role: NodeRole.plant, component: NodeComponent.roofTank),
        _n('fix', 520, 1, role: NodeRole.fixture),
        _n('diff', 780, 1,
            role: NodeRole.fixture, component: NodeComponent.supplyDiffuser),
      ],
      edges: [
        const NetEdge(
            id: 'e1', fromId: 'pump', toId: 'gtank', service: ServiceType.coldWater),
        const NetEdge(
            id: 'e2', fromId: 'gtank', toId: 'junc', service: ServiceType.coldWater),
        const NetEdge(
            id: 'e3',
            fromId: 'junc',
            toId: 'fix',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser),
        const NetEdge(
            id: 'e4', fromId: 'fix', toId: 'rtank', service: ServiceType.coldWater),
        const NetEdge(
            id: 'e5', fromId: 'fix', toId: 'diff', service: ServiceType.duct),
      ],
    ));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(size: Size(1100, 760)),
            child: SchematicView(),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
    // The Auto-mode system filter offers the two services present + "All".
    // (The fixture/equipment labels are canvas-painted, so they're verified by
    // the golden rather than the widget finder.)
    expect(find.text('All'), findsOneWidget);
    await expectLater(
      find.byType(SchematicView),
      matchesGoldenFile('goldens/09_single_line_symbols.png'),
    );
    // Loading a network with pumps runs the MEP->electrical sync, whose status
    // pill self-clears on a 3 s Timer; cancel it before the tree is disposed.
    container.read(statusMessageProvider.notifier).clear();
  });

  testWidgets('inferred risers connect floors that share a service unrouted',
      (tester) async {
    setDesktopSurface(tester, size: const Size(1100, 760));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(projectControllerProvider.notifier).setFloors(const [
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(4.0)),
    ]);
    // Cold water on BOTH floors but NO drawn riser between them — the single
    // line should offer to infer the vertical when the toggle is on.
    container.read(networkControllerProvider.notifier).loadNetwork(Network(
      nodes: [
        _n('a', 150, 0, role: NodeRole.plant, component: NodeComponent.pump),
        _n('b', 600, 0, role: NodeRole.fixture),
        _n('c', 250, 1),
        _n('d', 700, 1, role: NodeRole.fixture),
      ],
      edges: [
        const NetEdge(
            id: 'g1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        const NetEdge(
            id: 'g2', fromId: 'c', toId: 'd', service: ServiceType.coldWater),
      ],
    ));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(size: Size(1100, 760)),
            child: SchematicView(),
          ),
        ),
      ),
    ));
    await tester.pump();
    // Turn on inferred risers.
    await tester.tap(find.text('Infer risers'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(SchematicView),
      matchesGoldenFile('goldens/10_single_line_inferred.png'),
    );
    // Loading a network with pumps runs the MEP->electrical sync, whose status
    // pill self-clears on a 3 s Timer; cancel it before the tree is disposed.
    container.read(statusMessageProvider.notifier).clear();
  });

  testWidgets('tapping an inferred riser commits a real sized riser edge',
      (tester) async {
    setDesktopSurface(tester, size: const Size(1100, 760));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(projectControllerProvider.notifier).setFloors(const [
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(4.0)),
    ]);
    container.read(networkControllerProvider.notifier).loadNetwork(Network(
      nodes: [
        _n('a', 150, 0, role: NodeRole.plant, component: NodeComponent.pump),
        _n('b', 600, 0, role: NodeRole.fixture),
        _n('c', 250, 1),
        _n('d', 700, 1, role: NodeRole.fixture),
      ],
      edges: [
        const NetEdge(
            id: 'g1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        const NetEdge(
            id: 'g2', fromId: 'c', toId: 'd', service: ServiceType.coldWater),
      ],
    ));
    bool hasRiser() => container
        .read(networkControllerProvider)
        .network
        .edges
        .any((e) => e.kind == EdgeKind.riser);
    expect(hasRiser(), isFalse);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(size: Size(1100, 760)),
            child: SchematicView(),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Infer risers'));
    await tester.pump();
    int riserCount() => container
        .read(networkControllerProvider)
        .network
        .edges
        .where((e) => e.kind == EdgeKind.riser)
        .length;
    // Two mutual-nearest pairs (a↔c on the left, b↔d on the right) ⇒ two
    // inferred connectors, each clickable on its vertical leg at its
    // endpoints' mid-x. Round 26 — the Auto layout now sits in a FRAME (the
    // FFL/fan-out gutter on the left, the pump-set detail + notes column on
    // the right), so the node x's are read from the painter's OWN layout
    // (the same `layoutNodePositions` its hit test uses) rather than the old
    // full-width `sidePad + rank/(cols-1) * drawWidth` arithmetic.
    final pos = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => autoSchematicLayoutPositions(w.painter, w.size))
        .firstWhere((p) => p != null)!;
    // Column ranks a=0, c=1, b=2, d=3 (4 distinct x-buckets) ⇒ left-to-right.
    expect(pos['a']!.dx < pos['c']!.dx && pos['c']!.dx < pos['b']!.dx,
        isTrue);
    final leftX = (pos['a']!.dx + pos['c']!.dx) / 2;
    final rightX = (pos['b']!.dx + pos['d']!.dx) / 2;
    final midY = (pos['a']!.dy + pos['c']!.dy) / 2;
    await tester.tapAt(Offset(leftX, midY)); // left pair mid-x
    await tester.pump();
    expect(hasRiser(), isTrue);
    expect(riserCount(), 1);
    await tester.tapAt(Offset(rightX, midY)); // right pair mid-x
    // Drain the transient 'Riser added' status-message timers before teardown.
    await tester.pump(const Duration(seconds: 4));

    // Both dashed suggestions became real riser edges (per vertical stack).
    expect(riserCount(), 2);
  });
}
