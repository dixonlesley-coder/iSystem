import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/network/network.dart';

/// K3 — the heatmap's IDW field is memoized on the solve + sheet + sample grid,
/// so a pure pan/zoom (which only moves the camera) reuses the cached field and
/// never re-samples; only a new solve invalidates it.
void main() {
  void drawColdRun(ProviderContainer c) {
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(1000, 0));
    n.setTool(DrawTool.select);
  }

  test('two successive reads with an unchanged solve return the identical '
      'cached field; a solve change invalidates it', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    drawColdRun(c); // downfeed (default) fills the residual field
    expect(c.read(residualByNodeProvider), isNotEmpty);

    const key = (
      sheetId: 's1',
      floorIndex: 0,
      width: 1000.0,
      height: 1000.0,
    );
    final f1 = c.read(heatmapFieldProvider(key));
    expect(f1, isNotNull);

    // A pan/zoom changes only the viewport transform — NOT a provider input —
    // so re-reading returns the SAME cached object (no re-sample).
    final f2 = c.read(heatmapFieldProvider(key));
    expect(identical(f1, f2), isTrue);

    // Moving a node changes positions/residuals → a new solve → new field.
    final term = c
        .read(networkControllerProvider)
        .network
        .nodes
        .reduce((a, b) => a.x > b.x ? a : b);
    c.read(networkControllerProvider.notifier).moveNode(term.id, 1600, 300);
    final f3 = c.read(heatmapFieldProvider(key));
    expect(f3, isNotNull);
    expect(identical(f3, f1), isFalse);
  });

  test('empty residual (no network) → null field', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    const key = (
      sheetId: 's1',
      floorIndex: 0,
      width: 1000.0,
      height: 1000.0,
    );
    expect(c.read(heatmapFieldProvider(key)), isNull);
  });
}
