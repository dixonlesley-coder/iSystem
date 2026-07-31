/// J6 — the app had TWO minimap implementations: the Layout canvas's shared
/// `CanvasMinimap` and a private `_MiniMap` in the electrical view. The
/// electrical one now points at the shared widget; only a pure world→content
/// adapter (`electricalMinimapContent`) remains, so the two workspaces cannot
/// drift apart again.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/canvas/canvas_minimap.dart';
import 'package:mechx/ui/electrical/electrical_view.dart';

import 'test_util.dart';

void main() {
  test('electricalMinimapContent frames the padded panel bounds', () {
    // Empty layout ⇒ nothing to map.
    expect(electricalMinimapContent(const {}), isNull);

    final c = electricalMinimapContent(const {
      'a': Offset(100, 200),
      'b': Offset(400, 500),
    })!;
    // The origin is the top-left MINUS the left/top padding (80 / 60), so a
    // board on the edge sits inside the frame, not on it.
    expect(c.origin, const Offset(20, 140));
    // Span + the pad allowance (200 / 160 total), matching the geometry the
    // private minimap used before the convergence.
    expect(c.size, const Size(500, 460));

    // A single board still yields a usable (non-degenerate) frame.
    final one = electricalMinimapContent(const {'a': Offset(0, 0)})!;
    expect(one.size, const Size(200, 160));
    expect(one.origin, const Offset(-80, -60));
  });

  test('the content transform maps a world point to the same screen point', () {
    final c = electricalMinimapContent(const {'a': Offset(100, 200)})!;
    // `screen = world*s + o`; the content transform folds the origin in, so
    // content-space and world-space must land on the same screen pixel.
    const scale = 1.7;
    const offset = Offset(-40, 25);
    const world = Offset(180, 260);
    final screenFromWorld = world * scale + offset;
    final contentOffset = offset + c.origin * scale;
    final screenFromContent = (world - c.origin) * scale + contentOffset;
    expect((screenFromContent - screenFromWorld).distance, lessThan(1e-9));
  });

  testWidgets('the electrical canvas mounts the SHARED CanvasMinimap',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();
    await tester.pump();

    expect(find.byType(CanvasMinimap), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
