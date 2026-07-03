/// E4 — the "Duplicate floor to…" dialog: replicate one floor's drawn runs onto
/// a checked range of target floors, with an honest "no plan" note for a floor
/// that carries no sheet. Covers the pure [runsOnFloor] count and the dialog's
/// duplicate → status-pill flow (no filesystem I/O, so a standard widget test).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/shell/duplicate_floor_dialog.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

Widget _host(Widget child) => WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, _) => builder(context),
      ),
      home: MechXTheme(
        data: MechXThemeData.dark,
        child: child,
      ),
    );

/// Draw [count] chained run edges on ([sheetId], [floor]) via the controller
/// (mirrors how the app builds runs). [count] segments need count+1 points.
void _drawRuns(ProviderContainer c, String sheetId, int floor, int count) {
  final net = c.read(networkControllerProvider.notifier);
  net.setService(ServiceType.coldWater);
  net.setTool(DrawTool.drawRun);
  for (var i = 0; i <= count; i++) {
    net.placeRunPoint(sheetId, floor, Offset(100 + i * 200.0, 100));
  }
  net.setTool(DrawTool.select);
}

void main() {
  group('runsOnFloor', () {
    test('counts only the run edges wholly on the given sheet + floor', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedDemoSheets(c);
      // Two runs on s1/floor0, one run on s2/floor1.
      _drawRuns(c, 's1', 0, 2);
      _drawRuns(c, 's2', 1, 1);
      final net = c.read(networkControllerProvider).network;
      expect(runsOnFloor(net, 's1', 0), 2);
      expect(runsOnFloor(net, 's2', 1), 1);
      // Nothing drawn on floor 2 → zero.
      expect(runsOnFloor(net, 's3', 2), 0);
    });
  });

  testWidgets('duplicates the source floor onto a checked target + confirms',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: SizedBox()));
    // A Builder captures a context under the Navigator + MechXTheme to open the
    // modal from.
    late BuildContext dialogContext;
    final rootKey = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      child: _host(Builder(builder: (context) {
        dialogContext = context;
        return SizedBox.expand(key: rootKey);
      })),
    ));
    final c = ProviderScope.containerOf(rootKey.currentContext!);
    seedDemoSheets(c); // s1→floor0, s2→floor1, s3→floor2
    _drawRuns(c, 's1', 0, 2); // 2 runs on the Ground floor
    await tester.pumpAndSettle();

    // No dialog at rest.
    expect(find.text('Duplicate floor to…'), findsNothing);

    showDuplicateFloorDialog(dialogContext);
    await tester.pumpAndSettle();
    expect(find.text('Duplicate floor to…'), findsOneWidget);
    // The source defaults to the current sheet's floor and reports its runs.
    expect(find.text('2 runs on this floor.'), findsOneWidget);

    // "Level 1" appears twice — as a source chip and as a target row (the
    // target ListView is built after the source Wrap, so it is last). Tick the
    // target row and duplicate.
    await tester.tap(find.text('Level 1').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();

    // The dialog closed; the runs now exist on s2/floor1.
    expect(find.text('Duplicate floor to…'), findsNothing);
    final net = c.read(networkControllerProvider).network;
    expect(runsOnFloor(net, 's2', 1), 2);
    // The status pill confirms the copy.
    expect(c.read(statusMessageProvider), 'Copied 2 runs to Level 1');
  });

  testWidgets('a target floor with no sheet is flagged "no plan"',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: SizedBox()));
    late BuildContext dialogContext;
    final rootKey = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      child: _host(Builder(builder: (context) {
        dialogContext = context;
        return SizedBox.expand(key: rootKey);
      })),
    ));
    final c = ProviderScope.containerOf(rootKey.currentContext!);
    seedDemoSheets(c); // 3 sheets → floors 0,1,2
    // Give the building a 4th floor with no plan on it.
    c.read(projectControllerProvider.notifier).setFloors(const [
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(3.5)),
      Floor('Level 2', Length(3.5)),
      Floor('Level 3', Length(3.5)),
    ]);
    _drawRuns(c, 's1', 0, 1);
    await tester.pumpAndSettle();

    showDuplicateFloorDialog(dialogContext);
    await tester.pumpAndSettle();

    // Floor 3 ("Level 3") carries no sheet → shown with the honest note.
    expect(find.text('Level 3'), findsOneWidget);
    expect(find.text('no plan'), findsOneWidget);
  });
}
