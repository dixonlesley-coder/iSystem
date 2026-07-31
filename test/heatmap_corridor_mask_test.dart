import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/network/network.dart';

/// J3 — the heatmap must stop asserting a pressure where there is no pipework.
/// The IDW field still covers the whole sheet (it is the interpolation kernel),
/// but the PAINTED wash is masked to a corridor around the solved nodes: full
/// opacity out to ~2x the network's own mean node spacing, a short fade, then
/// nothing. These pin the mask's shape, its grid alignment with the field, and
/// its memoization (a pan/zoom must not recompute it).
void main() {
  void drawColdRun(ProviderContainer c) {
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(100, 100));
    n.placeRunPoint('s1', 0, const Offset(300, 100));
    n.setTool(DrawTool.select);
  }

  const key = (
    sheetId: 's1',
    floorIndex: 0,
    width: 2000.0,
    height: 2000.0,
  );

  test('no residual data => no mask (nothing is painted at all)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(heatmapMaskProvider(key)), isNull);
  });

  test('the mask grid matches the field grid cell-for-cell', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    drawColdRun(c);
    final field = c.read(heatmapFieldProvider(key))!;
    final mask = c.read(heatmapMaskProvider(key))!;
    expect(mask.cols, field.cols);
    expect(mask.rows, field.rows);
    expect(mask.cellSize, field.cellSize);
    expect(mask.originX, field.originX);
    expect(mask.originY, field.originY);
    expect(mask.alpha, hasLength(field.cols * field.rows));
  });

  test('cells ON the pipework paint fully; the far corner is not painted', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    drawColdRun(c);
    final field = c.read(heatmapFieldProvider(key))!;
    final mask = c.read(heatmapMaskProvider(key))!;

    // Every alpha is a real 0..1 multiplier.
    for (final a in mask.alpha) {
      expect(a, inInclusiveRange(0.0, 1.0));
    }

    // The cell containing the run's midpoint (200, 100) is inside the corridor.
    int colOf(double x) =>
        ((x - field.originX) / field.cellSize).floor().clamp(0, field.cols - 1);
    int rowOf(double y) =>
        ((y - field.originY) / field.cellSize).floor().clamp(0, field.rows - 1);
    expect(mask.alphaAt(colOf(200), rowOf(100)), 1.0);

    // The opposite corner of a 2000x2000 sheet is ~2.5 k px from a 200 px run —
    // far outside any honest corridor. It must be fully masked away.
    expect(mask.alphaAt(field.cols - 1, field.rows - 1), 0.0);

    // …and the mask is therefore doing real work (not a no-op pass-through).
    expect(mask.isOpaqueEverywhere, isFalse);
    expect(mask.alpha.any((a) => a == 0.0), isTrue);
  });

  test('the corridor radius is derived from the network, not the paper', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    drawColdRun(c);
    final mask = c.read(heatmapMaskProvider(key))!;
    // Two nodes 200 px apart => mean nearest-neighbour spacing 200 px, so the
    // full-opacity radius is 2 x 200 = 400 px (the documented derivation), and
    // the fade reaches zero at 400 x 1.6 = 640 px.
    expect(mask.coreRadius, closeTo(200 * kHeatmapCorridorSpacings, 1e-9));

    final field = c.read(heatmapFieldProvider(key))!;
    // Every cell centre beyond the feathered radius of BOTH nodes is zero.
    final outer = mask.coreRadius * (1 + kHeatmapCorridorFeather);
    for (var row = 0; row < mask.rows; row++) {
      for (var col = 0; col < mask.cols; col++) {
        final cx = field.centerX(col);
        final cy = field.centerY(row);
        final d = [const Offset(100, 100), const Offset(300, 100)]
            .map((p) => math.sqrt(
                (p.dx - cx) * (p.dx - cx) + (p.dy - cy) * (p.dy - cy)))
            .reduce(math.min);
        if (d > outer) {
          expect(mask.alphaAt(col, row), 0.0,
              reason: 'cell ($col,$row) is ${d.round()} px out');
        } else if (d < mask.coreRadius) {
          expect(mask.alphaAt(col, row), 1.0,
              reason: 'cell ($col,$row) is ${d.round()} px out');
        }
      }
    }
  });

  test('the mask is memoized like the field (a pan/zoom never recomputes it)',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    drawColdRun(c);
    final m1 = c.read(heatmapMaskProvider(key));
    final m2 = c.read(heatmapMaskProvider(key));
    expect(identical(m1, m2), isTrue);

    // Moving a node changes the solve => a new field => a new mask.
    final term = c
        .read(networkControllerProvider)
        .network
        .nodes
        .reduce((a, b) => a.x > b.x ? a : b);
    c.read(networkControllerProvider.notifier).moveNode(term.id, 900, 700);
    final m3 = c.read(heatmapMaskProvider(key));
    expect(m3, isNotNull);
    expect(identical(m3, m1), isFalse);
  });
}
