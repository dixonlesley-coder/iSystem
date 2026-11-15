// Backlog Z-5 (2026-11-14) — the canvas riser painters (Auto and EDIT mode)
// name the reference tower's fire zone break tank BT 'Fire break tank' (the
// zone chain's `fireBreakTankIdsProvider`, as the issued M-201 since Z-4);
// the genuine roof tank RT still reads 'Roof tank'. Painter text is not
// reachable by widget finders, so the test reads the set each mounted
// painter was given and the ONE label function both painters call
// ([schematicNodeLabel]).
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/schematic_view_store.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';

import 'reference_drawing_loader.dart';
import 'test_util.dart';

void main() {
  testWidgets('tower: Edit and Auto riser painters label BT "Fire break tank"',
      (tester) async {
    final spec = kRefDrawingSpecs.firstWhere((s) => s.key == 'tower');
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.runAsync(() => loadRefDrawingSpec(c, spec));
    expect(c.read(fireBreakTankIdsProvider), {'BT'});

    setDesktopSurface(tester);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(1280, 832)),
            child: SizedBox(
              width: 1280,
              height: 832,
              child: Overlay(initialEntries: [
                OverlayEntry(builder: (_) => const SchematicView()),
              ]),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    final net = c.read(sizingNetworkProvider);
    final bt = net.nodeById('BT')!;
    final rt = net.nodeById('RT')!;
    void check(String painterType) {
      final painters = [
        for (final w in tester.widgetList<CustomPaint>(find.byType(CustomPaint)))
          if (w.painter?.runtimeType.toString() == painterType) w.painter!,
      ];
      expect(painters, isNotEmpty, reason: painterType);
      for (final p in painters) {
        final ids = (p as dynamic).fireBreakTankIds as Set<String>;
        expect(ids, {'BT'}, reason: painterType);
        expect(schematicNodeLabel(bt, fireBreakTankIds: ids),
            'Fire break tank');
        expect(schematicNodeLabel(rt, fireBreakTankIds: ids), 'Roof tank');
      }
    }

    check('_AutoSchematicPainter');
    c.read(schematicViewProvider.notifier)
      ..setMode(SchematicMode.edit)
      ..setService(ServiceType.fireHydrant);
    await tester.pump();
    await tester.pump();
    check('_EditSchematicPainter');
    expect(tester.takeException(), isNull);

    // Without the break-tank set a roof-typed tank still reads its drawn kind.
    expect(schematicNodeLabel(bt), 'Roof tank');
    expect(bt.component, NodeComponent.roofTank);
  });
}
