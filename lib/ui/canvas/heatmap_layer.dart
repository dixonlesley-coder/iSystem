import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/pressure_field.dart';

import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import '../../store/solve_store.dart';
import '../strings/app_strings.dart';
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

    // Legend endpoints stay the raw node residual range (byte-identical), a
    // cheap O(nodes) pass. The expensive IDW sampling is cached in the provider.
    final values = <double>[
      for (final n in net.nodes)
        if (n.sheetId == sheetId && n.floorIndex == floorIndex)
          if (residual[n.id] != null) residual[n.id]!.inKiloPascals,
    ];
    if (values.isEmpty) return const SizedBox.shrink();

    var minKpa = values.first;
    var maxKpa = values.first;
    for (final v in values) {
      if (v < minKpa) minKpa = v;
      if (v > maxKpa) maxKpa = v;
    }
    // I2: the absolute PASS anchor — the SNI target residual the solve holds —
    // so the colours (and the legend tick) read against the requirement, not
    // just this view's own min/max.
    final targetKpa = ref.watch(targetResidualProvider).inKiloPascals;

    // K3: the sampled field is memoized on the solve + sheet + sample grid, so a
    // pure pan/zoom (only [transform] changes) reuses this cached object and the
    // painter just redraws its cells — no per-frame re-sampling.
    final field = ref.watch(heatmapFieldProvider((
      sheetId: sheetId,
      floorIndex: floorIndex,
      width: contentSize.width,
      height: contentSize.height,
    )));
    if (field == null) return const SizedBox.shrink();

    // J3: the corridor mask — the wash fades out beyond the pipework the solve
    // actually measured, so an empty sheet corner is never coloured as if it
    // carried a residual. Derived from (and grid-aligned with) the same field.
    final mask = ref.watch(heatmapMaskProvider((
      sheetId: sheetId,
      floorIndex: floorIndex,
      width: contentSize.width,
      height: contentSize.height,
    )));

    // E4: a (near-)uniform residual field used to wash the whole sheet in the
    // mid-ramp amber (a pale tan at the overlay alpha), reading as a stained
    // page rather than a deliberate overlay. When there's essentially one value
    // everywhere, paint a subtle NEUTRAL tint instead — the legend carries the
    // honest PASS/LOW verdict, so nothing is hidden.
    final uniform = (maxKpa - minKpa).abs() < 1.0;
    final uniformColor = uniform ? _uniformTint(context.colors) : null;

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _HeatmapPainter(
                field: field,
                transform: transform,
                uniformColor: uniformColor,
                mask: mask,
              ),
            ),
          ),
          // Bottom-RIGHT, clear of the bottom-left zoom cluster so the two
          // don't overlap.
          Positioned(
            right: MechXSpacing.md,
            bottom: MechXSpacing.md,
            child: HeatmapLegend(
                minKpa: minKpa,
                maxKpa: maxKpa,
                targetKpa: targetKpa,
                // M9: on the upfeed solve the residuals meet the target BY
                // CONSTRUCTION (the pump head is defined as their max), so the
                // legend must not print a green PASS off them.
                targetHeldByDesign:
                    ref.watch(solveProvider)?.targetHeldByDesign ?? false),
          ),
        ],
      ),
    );
  }
}

/// E4: the calm neutral overlay tint for a (near-)uniform residual field — a
/// muted blue-slate blended from the theme's accent + muted-text so it reads as
/// a deliberate flat data layer in both light and dark, painted at a low alpha.
Color _uniformTint(MechXColors colors) =>
    Color.lerp(colors.accent, colors.textMuted, 0.55)!.withAlpha(46);

/// A small, self-explaining legend so the heatmap colours are readable: a
/// red→amber→teal ramp from the lowest to the highest residual pressure.
/// Sized to the labels' INTRINSIC width (J2): the numeric endpoints are the
/// legend's whole point, so they must never ellipsize — the ramp bar
/// stretches to match instead of pinning the row to a fixed 148 px. Public
/// (rather than file-private) so the no-truncation contract is unit-testable.
class HeatmapLegend extends StatelessWidget {
  final double minKpa;
  final double maxKpa;

  /// I2: the absolute pass threshold — the SNI target residual the solve holds
  /// at the critical fixture. Marked on the gradient (a threshold tick) so the
  /// colours read against the code requirement, and used for the uniform
  /// state's PASS/LOW verdict.
  final double targetKpa;

  /// M9 — true when these residuals hold [targetKpa] BY CONSTRUCTION rather
  /// than as a falsifiable outcome ([PressureSolution.targetHeldByDesign], the
  /// upfeed solve: the pump head is DEFINED as the max of
  /// friction + elevation + target, so `residual >= target` is an algebraic
  /// identity no drawn network can break). A PASS read off that is
  /// unfalsifiable, so the verdict reads "target held by design" instead of a
  /// green PASS. The gravity DOWNFEED solve leaves this false — its residuals
  /// fall from a FIXED tank elevation and really can miss the target, so its
  /// PASS/LOW is a genuine check and is unchanged.
  final bool targetHeldByDesign;

  const HeatmapLegend(
      {super.key,
      required this.minKpa,
      required this.maxKpa,
      required this.targetKpa,
      this.targetHeldByDesign = false});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    // Degrades to EN with no provider ancestor (the legend is also pumped
    // standalone in tests), so this never throws.
    final strings = MechXStrings.of(context);
    final uniform = (maxKpa - minKpa).abs() < 1.0;

    String bar(double kpa) => '${kpa.toStringAsFixed(0)} kPa';

    // A residual passes when it meets the target the solve holds (a small
    // tolerance so a value pinned exactly at the target reads PASS).
    final pass = minKpa >= targetKpa - 0.5;
    // Fractional position of the threshold along the min→max ramp; clamped so
    // an all-pass (target below min) tick pins left, an all-fail pins right.
    final span = maxKpa - minKpa;
    final targetFrac =
        span.abs() < 1e-9 ? 0.0 : ((targetKpa - minKpa) / span).clamp(0.0, 1.0);

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
            // L-2a: the Results card beside this legend verdicts on ZONE
            // STATIC, so each surface must name its own basis — this one is
            // the residual AT FIXTURES, not the zone-wide static figure.
            Text('residual at fixtures',
                maxLines: 1,
                softWrap: false,
                style: type.micro.copyWith(color: colors.textMuted)),
            const SizedBox(height: MechXSpacing.xs),
            // The ramp bar stretches to the widest line (title / label row). A
            // thin ink tick marks the absolute target residual on the gradient
            // (I2) so the colours read against the requirement — omitted only in
            // the uniform state (no meaningful position; the verdict line below
            // carries the anchor instead).
            SizedBox(
              height: 8,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      decoration: const BoxDecoration(
                        borderRadius: BorderRadius.all(Radius.circular(4)),
                        gradient: LinearGradient(
                          colors: [_kRampLow, _kRampMid, _kRampHigh],
                        ),
                      ),
                    ),
                  ),
                  if (!uniform)
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment(2 * targetFrac - 1, 0),
                        child: Container(
                          width: 2,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: MechXSpacing.xxs),
            // Show the numeric kPa endpoints — whole, never truncated. When the
            // field is (near-)uniform both ends read the same value, so a single
            // "Uniform NN kPa" line reads honestly instead of the identical
            // "Low 31 / High 31" pair (which looked like a bug); it carries the
            // PASS/LOW verdict against the target (E4).
            if (uniform)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Uniform ${bar(minKpa)}',
                      maxLines: 1,
                      softWrap: false,
                      style: type.mono.copyWith(color: colors.textMuted)),
                  const SizedBox(width: MechXSpacing.xs),
                  // M9: an upfeed residual cannot fail this comparison, so it
                  // gets the honest neutral statement, never a green PASS.
                  Text(targetHeldByDesign
                      ? 'held by design'
                      : pass
                          ? 'PASS'
                          : 'LOW',
                      maxLines: 1,
                      softWrap: false,
                      style: type.mono.copyWith(
                          color: targetHeldByDesign
                              ? colors.textSecondary
                              : pass
                                  ? colors.success
                                  : colors.danger)),
                ],
              )
            else ...[
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
              const SizedBox(height: MechXSpacing.xxs),
              // The tick's meaning, labelled (the absolute code anchor).
              Text('Min ${bar(targetKpa)}',
                  maxLines: 1,
                  softWrap: false,
                  style: type.mono.copyWith(color: colors.textSecondary)),
              // G6 — a SPREAD field used to print that bare Min tick with no
              // caveat at all: on the upfeed solve every residual clears it by
              // construction, so an engineer reads a PASS off an unfalsifiable
              // inequality. The caveat the uniform branch already carried now
              // appears here too.
              if (targetHeldByDesign)
                Text(strings(StringKey.heatmapHeldByDesign),
                    maxLines: 1,
                    softWrap: false,
                    style: type.micro.copyWith(color: colors.textSecondary)),
            ],
            // G6 — and BOTH branches name the question that CAN fail: whether a
            // real pump can deliver the head this solve assumed.
            if (targetHeldByDesign)
              Text('- ${strings(StringKey.heatmapRealCheckPumpDuty)}',
                  maxLines: 1,
                  softWrap: false,
                  style: type.micro.copyWith(color: colors.textMuted)),
          ],
        ),
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  /// The pre-sampled residual field (cached in [heatmapFieldProvider]). The
  /// painter only maps its cells to screen — it never re-samples (K3).
  final ScalarField field;
  final ViewportTransform transform;

  /// E4: when the field is (near-)uniform, every cell is filled with this flat
  /// neutral tint (already carrying its alpha) instead of the mid-ramp amber
  /// wash. Null ⇒ the normal per-cell red→amber→teal ramp.
  final Color? uniformColor;

  /// J3 — the per-cell corridor opacity mask (grid-aligned with [field]). Null
  /// ⇒ no masking (the pre-J3 full-sheet wash). Applied as a multiplier on the
  /// cell colour's alpha, so a cell far from any solved node is not painted at
  /// all: colour where there is no pipework is extrapolation, not measurement.
  final HeatmapMask? mask;

  _HeatmapPainter({
    required this.field,
    required this.transform,
    this.uniformColor,
    this.mask,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final min = field.min;
    final max = field.max;
    final resolution = field.cellSize;
    final cell = resolution * transform.scale;
    // Only usable when it describes THIS grid (it is derived from it, but a
    // mismatched pair must degrade to the unmasked wash rather than misalign).
    final m = (mask != null && mask!.cols == field.cols && mask!.rows == field.rows)
        ? mask
        : null;

    for (var row = 0; row < field.rows; row++) {
      for (var col = 0; col < field.cols; col++) {
        final maskAlpha = m == null ? 1.0 : m.alphaAt(col, row);
        // Nothing to say here — leave the plan bare.
        if (maskAlpha <= 0.0) continue;
        final Color color;
        if (uniformColor != null) {
          color = uniformColor!;
        } else {
          final t = normalize(field.valueAt(col, row), min, max);
          color = _ramp(t).withAlpha(105);
        }
        final faded = maskAlpha >= 1.0
            ? color
            : color.withAlpha((color.a * 255 * maskAlpha).round());
        final origin = transform.worldToScreen(
          Offset(field.centerX(col) - resolution / 2,
              field.centerY(row) - resolution / 2),
        );
        canvas.drawRect(
          // +0.5 overlap to avoid seams between cells.
          Rect.fromLTWH(origin.dx, origin.dy, cell + 0.5, cell + 0.5),
          Paint()..color = faded,
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
      // A pure pan/zoom keeps the SAME cached field (identity) → repaint to
      // redraw cells at the new offset/scale, but no re-sample. A new solve
      // yields a new field object → repaint.
      !identical(old.field, field) ||
      old.transform != transform ||
      old.uniformColor != uniformColor ||
      !identical(old.mask, mask);
}
