import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/pressure_field.dart';

import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import '../../store/solve_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'viewport.dart';

// Heatmap ramp endpoints (low residual → red, mid → amber, high → teal).
const Color _kRampLow = Color(0xFFD93838);
const Color _kRampMid = Color(0xFFE0A53A);
const Color _kRampHigh = Color(0xFF2BB6A3);

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
    final residual = ref.watch(residualByNodeProvider);
    if (residual.isEmpty) return const SizedBox.shrink();
    final net = ref.watch(networkControllerProvider).network;
    final transform = ref.watch(sheetsControllerProvider).viewportFor(sheetId) ??
        const ViewportTransform();

    final nodes = <FieldNode>[
      for (final n in net.nodes)
        if (n.sheetId == sheetId && n.floorIndex == floorIndex)
          if (residual[n.id] != null)
            FieldNode(n.x, n.y, residual[n.id]!.inKiloPascals),
    ];
    if (nodes.isEmpty) return const SizedBox.shrink();

    var minKpa = nodes.first.value;
    var maxKpa = nodes.first.value;
    for (final n in nodes) {
      if (n.value < minKpa) minKpa = n.value;
      if (n.value > maxKpa) maxKpa = n.value;
    }

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _HeatmapPainter(
                nodes: nodes,
                transform: transform,
                contentSize: contentSize,
              ),
            ),
          ),
          // Bottom-RIGHT, clear of the bottom-left zoom cluster so the two
          // don't overlap.
          Positioned(
            right: MechXSpacing.md,
            bottom: MechXSpacing.md,
            child: HeatmapLegend(minKpa: minKpa, maxKpa: maxKpa),
          ),
        ],
      ),
    );
  }
}

/// A small, self-explaining legend so the heatmap colours are readable: a
/// red→amber→teal ramp from the lowest to the highest residual pressure.
/// Sized to the labels' INTRINSIC width (J2): the numeric endpoints are the
/// legend's whole point, so they must never ellipsize — the ramp bar
/// stretches to match instead of pinning the row to a fixed 148 px. Public
/// (rather than file-private) so the no-truncation contract is unit-testable.
class HeatmapLegend extends StatelessWidget {
  final double minKpa;
  final double maxKpa;

  const HeatmapLegend(
      {super.key, required this.minKpa, required this.maxKpa});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final uniform = (maxKpa - minKpa).abs() < 1.0;

    String bar(double kpa) => '${kpa.toStringAsFixed(0)} kPa';

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(235),
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
      ),
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Residual pressure',
                style: type.caption.copyWith(color: colors.textSecondary)),
            const SizedBox(height: MechXSpacing.xs),
            // The ramp bar stretches to the widest line (title / label row).
            Container(
              height: 8,
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(4)),
                gradient: LinearGradient(
                  colors: [_kRampLow, _kRampMid, _kRampHigh],
                ),
              ),
            ),
            const SizedBox(height: MechXSpacing.xxs),
            // Always show the numeric min/max kPa endpoints — whole, never
            // truncated — even when the field is (near-)uniform, where both
            // ends read the same value.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Low ${bar(minKpa)}',
                    maxLines: 1,
                    softWrap: false,
                    style: type.mono.copyWith(color: colors.textMuted)),
                const SizedBox(width: MechXSpacing.xs),
                Text('High ${bar(maxKpa)}',
                    maxLines: 1,
                    softWrap: false,
                    textAlign: TextAlign.right,
                    style: type.mono.copyWith(color: colors.textMuted)),
              ],
            ),
            if (uniform)
              Padding(
                padding: const EdgeInsets.only(top: MechXSpacing.xxs),
                child: Text('uniform field',
                    style: type.caption.copyWith(color: colors.textMuted)),
              ),
          ],
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

  /// Low residual (tight) → red; mid → amber; high (ample) → teal. Matches the
  /// legend ramp so the colours read the same.
  Color _ramp(double t) => t < 0.5
      ? Color.lerp(_kRampLow, _kRampMid, t * 2)!
      : Color.lerp(_kRampMid, _kRampHigh, (t - 0.5) * 2)!;

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.nodes != nodes ||
      old.transform != transform ||
      old.contentSize != contentSize;
}
