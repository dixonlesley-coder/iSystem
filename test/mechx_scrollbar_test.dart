/// J1 — the shared themed scroll indicator. [MechXScrollbar] is a thin wrapper
/// on `widgets.dart`'s [RawScrollbar] (NOT Material's `Scrollbar`), styled from
/// MechXTheme. These guard: it wraps its child in a RawScrollbar, the child
/// stays scrollable, a controller is forwarded (so the thumb is draggable and a
/// persistent thumb doesn't assert), and it renders indicator-only when no
/// controller is supplied.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_scrollbar.dart';

import 'test_util.dart';

/// The minimal ancestry a bespoke MechX control needs (mirrors
/// `mechx_text_field_test`'s `_host`).
Widget _host(Widget child) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MechXTheme(data: MechXThemeData.dark, child: child),
      ),
    );

Widget _list(ScrollController? controller) => ListView.builder(
      controller: controller,
      itemCount: 100,
      itemBuilder: (_, i) =>
          SizedBox(height: 40, child: Text('row $i')),
    );

void main() {
  testWidgets(
      'wraps its child in a RawScrollbar and the child stays scrollable',
      (tester) async {
    setDesktopSurface(tester, size: const Size(400, 300));
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(SizedBox(
      height: 200,
      child: MechXScrollbar(
        controller: controller,
        child: _list(controller),
      ),
    )));

    // It builds a RawScrollbar (the widgets.dart primitive), not a wall.
    expect(find.byType(RawScrollbar), findsOneWidget);
    expect(find.byType(MechXScrollbar), findsOneWidget);

    // The wrapped scroll view still scrolls: the first row leaves the viewport.
    expect(find.text('row 0'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsNothing);
  });

  testWidgets(
      'thumbVisibility:true with a controller keeps a thumb and does not assert',
      (tester) async {
    setDesktopSurface(tester, size: const Size(400, 300));
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(SizedBox(
      height: 200,
      child: MechXScrollbar(
        controller: controller,
        thumbVisibility: true,
        child: _list(controller),
      ),
    )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(RawScrollbar), findsOneWidget);
  });

  testWidgets('renders indicator-only (no controller) without throwing',
      (tester) async {
    setDesktopSurface(tester, size: const Size(400, 300));

    await tester.pumpWidget(_host(SizedBox(
      height: 200,
      child: MechXScrollbar(child: _list(null)),
    )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(RawScrollbar), findsOneWidget);
    // The child is present and scrollable via the wheel / its own controller.
    expect(find.byType(ListView), findsOneWidget);
  });
}
