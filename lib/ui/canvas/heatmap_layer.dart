import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/pressure_field.dart';

import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import '../../store/solve_store.dart';
import 'viewport.dart';

/// Pressure heatmap — a GENERATED render of the node-pressure solve (§12, never
/// a parallel calculation). Samples residual pressure at the solved nodes into
/// a scalar field and colour-maps it across the sheet. Pointer-transparent.
class HeatmapLayer extends ConsumerWidget {
  final String sheetId;
  final int floorIndex;
  final Size contentSize;

  const HeatmapLayer({
    super.key,
    required this.sheetId,
    required this.floorIndex,
    required this.contentSize,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final solution = ref.watch(solveProvider);
    if (solution == null) return const SizedBox.shrink();
    final net = ref.watch(networkControllerProvider).network;
    final transform = ref.watch(sheetsControllerProvider).viewportFor(sheetId) ??
        const ViewportTransform();

    final nodes = <FieldNode>[
      for (final n in net.nodes)
        if (n.sheetId == sheetId && n.floorIndex == floorIndex)
          if (solution.residualPressure[n.id] != null)
            FieldNode(n.x, n.y, solution.residualPressure[n.id]!.inKiloPascals),
    ];
    if (nodes.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _HeatmapPainter(
          nodes: nodes,
          transform: transform,
          contentSize: contentSize,
        ),
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  final List<FieldNode> nodes;
  final ViewportTransform transform;
  final Size contentSize;

  _HeatmapPainter({
    required this.nodes,
    required this.transform,
    required this.contentSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ~28 cells across the longer edge.
    final resolution = (contentSize.longestSide / 28).clamp(1.0, 1e9);
    final field = sampleField(
      nodes: nodes,
      bounds: FieldBounds(0, 0, contentSize.width, contentSize.height),
      resolution: resolution,
    );
    final min = field.min;
    final max = field.max;
    final cell = resolution * transform.scale;

    for (var row = 0; row < field.rows; row++) {
      for (var col = 0; col < field.cols; col++) {
        final t = normalize(field.valueAt(col, row), min, max);
        final origin = transform.worldToScreen(
          Offset(field.centerX(col) - resolution / 2,
              field.centerY(row) - resolution / 2),
        );
        canvas.drawRect(
          // +0.5 overlap to avoid seams between cells.
          Rect.fromLTWH(origin.dx, origin.dy, cell + 0.5, cell + 0.5),
          Paint()..color = _ramp(t).withAlpha(105),
        );
      }
    }
  }

  /// Low residual (tight) → red; mid → amber; high (ample) → teal.
  Color _ramp(double t) => t < 0.5
      ? Color.lerp(const Color(0xFFD93838), const Color(0xFFE0A53A), t * 2)!
      : Color.lerp(const Color(0xFFE0A53A), const Color(0xFF2BB6A3), (t - 0.5) * 2)!;

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.nodes != nodes ||
      old.transform != transform ||
      old.contentSize != contentSize;
}
