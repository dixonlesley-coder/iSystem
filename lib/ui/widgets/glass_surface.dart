import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A Liquid-Glass material surface for the FLOATING CHROME layers (nav rail,
/// top/status bars, inspector, sheet rail, command palette, popovers, zoom
/// cluster, banners). It blurs + tints whatever is painted behind it (so the
/// drawing refracts through), grades a soft specular sheen down from the top
/// edge, and rims itself with a hairline — the three reads that make glass feel
/// like glass. Content surfaces (cards, tables, reports) deliberately do NOT use
/// this; they stay opaque for legibility (Apple applies Liquid Glass to the
/// navigation/control layer, not to content).
///
/// Colours come from the active [MechXColors] (`glassFill` / `glassSheen` /
/// `glassEdge`), so it adapts to light/dark automatically.
class GlassSurface extends StatelessWidget {
  /// The content painted on top of the glass.
  final Widget child;

  /// Corner rounding. Defaults to square (full-bleed bars/rails); pass a radius
  /// for floating cards (inspector, popovers, zoom cluster).
  final BorderRadius borderRadius;

  /// Backdrop blur radius. Defaults to the primary-chrome blur.
  final double blurSigma;

  /// Which edges get the hairline rim. Full-bleed bars only want the edge that
  /// faces the content (e.g. a left rail rims its right side); floating cards
  /// rim all four. Null ⇒ all sides.
  final Border? edge;

  /// Optional drop shadow beneath the glass (floating cards lift; flush bars
  /// usually don't).
  final List<BoxShadow>? shadow;

  /// Whether to grade the specular sheen from the top. On for most surfaces;
  /// off for very short surfaces where the gradient would band.
  final bool sheen;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.blurSigma = MechXGlass.blurSigma,
    this.edge,
    this.shadow,
    this.sheen = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // The fill grades UP into the brighter sheen at the top edge, giving the
    // lens-like highlight; below ~55% it settles to the flat translucent fill.
    final decoration = BoxDecoration(
      borderRadius: borderRadius,
      gradient: sheen
          ? LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(colors.glassSheen.withAlpha(70), colors.glassFill),
                colors.glassFill,
              ],
              stops: const [0.0, 0.55],
            )
          : null,
      color: sheen ? null : colors.glassFill,
      border: edge ??
          Border.all(color: colors.glassEdge, width: MechXGlass.edgeWidth),
    );
    Widget glass = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(decoration: decoration, child: child),
      ),
    );
    if (shadow != null) {
      glass = DecoratedBox(
        decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadow),
        child: glass,
      );
    }
    return glass;
  }
}
