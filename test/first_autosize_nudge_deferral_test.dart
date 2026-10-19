import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// Any derived provider that happens to be the FIRST reader of the live
/// sizing solve (the downfeed / SNI-minimum / advisory providers all are, in
/// some flush order).
final _derivedSizingReader =
    Provider<int>((ref) => ref.watch(sizingProvider).length);

/// Round 32 r2 — the golden capture flaked with Riverpod's "Providers are not
/// allowed to modify other providers during their initialization": the
/// AppShell first-auto-size listener wrote `firstAutoSizeNudgeProvider` while
/// `sizingProvider` was first computed INSIDE another provider's build (the
/// dependent flush walks a hash map, so which provider reads sizing first is
/// order-dependent). This pins the worst-case order deterministically: the
/// first non-empty sizing is computed from inside a Provider build, every
/// time, and the nudge must still fire (deferred) without the assertion.
void main() {
  for (var run = 0; run < 3; run++) {
    testWidgets(
        'first-size nudge never writes a Notifier mid provider build '
        '(run ${run + 1})', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container.read(sheetsControllerProvider.notifier).loadDemoSheets();
      await tester.pump();
      expect(container.read(sizingProvider), isEmpty);

      final net = container.read(networkControllerProvider.notifier);
      net.setService(ServiceType.coldWater);
      net.setTool(DrawTool.drawRun);
      net.placeRunPoint('s1', 0, const Offset(360, 360));
      net.placeRunPoint('s1', 0, const Offset(1040, 360));
      net.placeRunPoint('s1', 0, const Offset(1040, 820));
      net.setTool(DrawTool.select);

      // No frame yet: sizing is dirty. Its first non-empty computation now
      // happens inside `_derivedSizingReader`'s build.
      expect(container.read(_derivedSizingReader), greaterThan(0));
      expect(tester.takeException(), isNull);

      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(container.read(firstAutoSizeNudgeProvider), isTrue,
          reason: 'the deferred nudge still fires once');
      container.read(statusMessageProvider.notifier).clear();
      await tester.pumpAndSettle();
    });
  }
}
