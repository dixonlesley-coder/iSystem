import 'package:flutter/widgets.dart' show Offset;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// Drafting-feel perf (2026-10-20) — what a drag frame or a pan / zoom frame is
/// allowed to recompute. Pinned by object IDENTITY (every pinned provider
/// returns a fresh object on each recompute), never by wall-clock time, so the
/// suite stays deterministic on any machine.
///
/// * During a K1 drag session the ANALYTIC fan-ins (Design Issues, the
///   electrical MEP feed, the workflow stepper) read the drag-frozen
///   [sizingNetworkProvider], like the sizing chain itself: a pointer frame
///   replaces the live network but must not re-run them (they cost tens of ms
///   per frame on a 30-storey building and the result was inconsistent anyway
///   — live geometry against frozen sizing).
/// * A pan / zoom frame writes only the sheet's viewport: nothing that reads
///   the sheet LIST may re-run ([sheetsContentProvider]); the overlays follow
///   the fine-grained [sheetViewportProvider].
void main() {
  ProviderContainer drawnProject() {
    final c = ProviderContainer();
    seedDemoSheets(c);
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(100, 100));
    n.placeRunPoint('s1', 0, const Offset(600, 100));
    n.placeRunPoint('s1', 0, const Offset(600, 400));
    n.setTool(DrawTool.select);
    return c;
  }

  String farNode(ProviderContainer c) => c
      .read(networkControllerProvider)
      .network
      .nodes
      .reduce((a, b) => a.y > b.y ? a : b)
      .id;

  test('a drag frame re-runs none of the analytic fan-ins; drag END refreshes '
      'them once against the settled network', () {
    final c = drawnProject();
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    final drag = c.read(dragSessionProvider.notifier);
    drag.throttleInterval = const Duration(seconds: 30);
    final id = farNode(c);

    final issues = c.read(designIssuesProvider);
    final workflow = c.read(workflowStageStateProvider);
    final loads = c.read(placedEquipmentLoadsProvider);
    final binding = c.read(mepDutyBindingProvider);

    drag.beginDrag();
    n.pushUndoSnapshot();
    for (var i = 0; i < 10; i++) {
      n.moveNode(id, 600.0 + i * 7, 400);
      expect(identical(c.read(designIssuesProvider), issues), isTrue,
          reason: 'Design Issues must not re-run on drag frame $i');
      expect(identical(c.read(workflowStageStateProvider), workflow), isTrue);
      expect(identical(c.read(placedEquipmentLoadsProvider), loads), isTrue);
      expect(identical(c.read(mepDutyBindingProvider), binding), isTrue);
    }

    drag.endDrag();
    expect(identical(c.read(designIssuesProvider), issues), isFalse,
        reason: 'the settled drag refreshes the fan-in');
    // At rest the fan-in follows the live network immediately.
    final settled = c.read(designIssuesProvider);
    n.moveNode(id, 500, 420);
    expect(identical(c.read(designIssuesProvider), settled), isFalse);
  });

  test('a pan / zoom frame re-runs nothing that reads the sheet list; the '
      'per-sheet viewport channel follows it', () {
    final c = drawnProject();
    addTearDown(c.dispose);
    final sheets = c.read(sheetsControllerProvider.notifier);
    final issues = c.read(designIssuesProvider);
    final workflow = c.read(workflowStageStateProvider);
    final content = c.read(sheetsContentProvider);
    expect(c.read(sheetViewportProvider('s1')), isNull);

    for (var i = 1; i <= 8; i++) {
      final vt = ViewportTransform(scale: 0.5 + i / 20, offset: Offset(i * 9, 3));
      sheets.setViewport('s1', vt);
      expect(c.read(sheetViewportProvider('s1')), vt);
      expect(identical(c.read(sheetsContentProvider), content), isTrue);
      expect(identical(c.read(designIssuesProvider), issues), isTrue);
      expect(identical(c.read(workflowStageStateProvider), workflow), isTrue);
    }
    // Another sheet's viewport channel is untouched by s1's pan.
    expect(c.read(sheetViewportProvider('s2')), isNull);

    // A real content change (switching sheet) DOES flow through.
    sheets.selectSheet(1);
    expect(identical(c.read(sheetsContentProvider), content), isFalse);
    expect(c.read(sheetsContentProvider).current?.id, 's2');
  });

  test('held arrow-key nudges ride the drag session: sizing stays frozen '
      'while keys repeat and re-solves once when they settle', () async {
    final c = drawnProject();
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    final drag = c.read(dragSessionProvider.notifier);
    drag.throttleInterval = const Duration(milliseconds: 60);
    final id = farNode(c);
    final before = c.read(sizingProvider);
    // What the layout canvas nudge handler does per auto-repeat.
    for (var i = 0; i < 6; i++) {
      drag.beginDrag();
      n.moveMany({id}, 4, 0);
      expect(identical(c.read(sizingProvider), before), isTrue);
    }
    expect(c.read(dragSessionProvider).active, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(c.read(dragSessionProvider).active, isFalse);
    expect(identical(c.read(sizingProvider), before), isFalse);
    final moved = c.read(networkControllerProvider).network.nodeById(id)!;
    expect(moved.x, 600 + 6 * 4);
  });
}
