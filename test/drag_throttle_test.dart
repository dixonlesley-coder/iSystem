import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/network/network.dart';

/// K1 — performance-feel. During an active node-drag the HEAVY sizing/solve/BOM
/// chain must NOT re-run on every pointer-move frame: it recomputes at most once
/// per throttle interval plus exactly once on drag end. At rest (no drag) the
/// throttle is inert and results are byte-identical to a direct mutation.
void main() {
  // A single cold-water run on s1/floor0 from (0,0) to (1000,0); returns the
  // container + the id of the far (terminal) node.
  ({ProviderContainer c, String termId}) coldRun() {
    final c = ProviderContainer();
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(1000, 0));
    n.setTool(DrawTool.select);
    final term = c
        .read(networkControllerProvider)
        .network
        .nodes
        .reduce((a, b) => a.x > b.x ? a : b);
    return (c: c, termId: term.id);
  }

  test('a live drag freezes the heavy sizing chain for every frame; endDrag '
      'does exactly one final recompute equal to a non-drag move', () {
    final f = coldRun();
    final c = f.c;
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    final drag = c.read(dragSessionProvider.notifier);
    // Pin a long throttle so no settle timer fires during the synchronous body:
    // the whole drag then coalesces to the single endDrag recompute.
    drag.throttleInterval = const Duration(seconds: 30);

    // sizingProvider returns a fresh Map on every recompute, so object identity
    // is an exact recompute counter.
    final before = c.read(sizingProvider);
    expect(before, isNotEmpty);

    drag.beginDrag();
    n.pushUndoSnapshot();
    // Opening the session freezes on the (still-unchanged) pre-drag network, so
    // no heavy recompute yet.
    expect(identical(c.read(sizingProvider), before), isTrue);

    // 12 drag frames — NONE re-runs the heavy sizing chain.
    for (var i = 0; i < 12; i++) {
      n.moveNode(f.termId, 1000.0 + i * 10, 0);
    }
    expect(identical(c.read(sizingProvider), before), isTrue,
        reason: 'heavy chain must stay frozen for the whole drag');

    // Drag end → exactly one recompute against the settled network.
    drag.endDrag();
    final afterDrag = c.read(sizingProvider);
    expect(identical(afterDrag, before), isFalse);
    expect(c.read(dragSessionProvider).active, isFalse);

    // The throttled result equals doing the SAME final move with no drag
    // session (byte-identical at-rest behaviour).
    final direct = coldRun();
    addTearDown(direct.c.dispose);
    direct.c
        .read(networkControllerProvider.notifier)
        .moveNode(direct.termId, 1000.0 + 11 * 10, 0);
    final directSizing = direct.c.read(sizingProvider);
    expect(afterDrag.length, directSizing.length);
    final a = afterDrag.values.single;
    final d = directSizing.values.single;
    expect(a.diameter.meters, d.diameter.meters);
    expect(a.flow.cubicMetersPerSecond, d.flow.cubicMetersPerSecond);
    expect(a.velocity.metersPerSecond, d.velocity.metersPerSecond);
  });

  test('at rest (no drag session) each moveNode recomputes immediately — '
      'byte-identical to before', () {
    final f = coldRun();
    final c = f.c;
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    final first = c.read(sizingProvider);
    // No beginDrag: moveNode is a plain edit and must re-run the chain at once.
    n.moveNode(f.termId, 1500, 200);
    expect(identical(c.read(sizingProvider), first), isFalse);
    // dragSession never opened.
    expect(c.read(dragSessionProvider).active, isFalse);
  });

  test('a paused/abandoned drag self-heals: the settle timer refreshes the '
      'heavy chain and closes the session', () async {
    final f = coldRun();
    final c = f.c;
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    final drag = c.read(dragSessionProvider.notifier);
    drag.throttleInterval = const Duration(milliseconds: 50);

    final before = c.read(sizingProvider);
    drag.beginDrag();
    n.pushUndoSnapshot();
    n.moveNode(f.termId, 1300, 0);
    // Immediately after the frame: still frozen, session open.
    expect(identical(c.read(sizingProvider), before), isTrue);
    expect(c.read(dragSessionProvider).active, isTrue);

    // No endDrag (e.g. a cancelled drag). After the throttle interval the settle
    // timer must refresh the chain and close the session on its own.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(identical(c.read(sizingProvider), before), isFalse);
    expect(c.read(dragSessionProvider).active, isFalse);
  });
}
