import 'package:flutter/widgets.dart';

/// MechX design tokens — the single source for spacing, radii, motion, colour,
/// and type. Restrained and custom; deliberately NOT Material's defaults (§4).
///
/// The palette + radii + type follow Apple's Human Interface Guidelines (iOS):
/// the system colour set (systemBlue accent, grouped backgrounds, label tiers,
/// hairline separators), continuous-feel corner radii, soft elevation shadows,
/// and an SF-like type scale (negative tracking on large text, a clear weight
/// hierarchy). Rendered with Roboto (the bundled, offline, goldens-safe face).

/// 8pt spacing grid (with a 4pt half-step). Use these everywhere; never
/// hard-code pixel gaps.
abstract final class MechXSpacing {
  static const double unit = 8.0;
  static const double xxs = 2; // hairline insets
  static const double xs = 4; // ½ unit
  static const double sm = 8; // 1
  static const double md = 16; // 2
  static const double lg = 24; // 3
  static const double xl = 32; // 4
  static const double xxl = 48; // 6

  /// `n` grid units, e.g. `MechXSpacing.units(1.5) == 12`.
  static double units(double n) => unit * n;
}

/// Corner radii — iOS-scale (controls ~9, cards ~14, large surfaces ~20), plus
/// a fully-rounded [pill] for segmented controls / switches / sidebar items.
abstract final class MechXRadii {
  static const Radius xs = Radius.circular(4); // micro insets (chips, swatches)
  static const Radius sm = Radius.circular(6);
  static const Radius md = Radius.circular(9);
  static const Radius lg = Radius.circular(14);
  static const Radius xl = Radius.circular(20);
  static const Radius pill = Radius.circular(999);
  static const BorderRadius card = BorderRadius.all(lg);
  static const BorderRadius control = BorderRadius.all(md);
  static const BorderRadius small = BorderRadius.all(xs);
  static const BorderRadius large = BorderRadius.all(xl);
  static const BorderRadius rounded = BorderRadius.all(pill);
}

/// Soft, iOS-style elevation. Shadows are subtle and warm-neutral — they hint
/// layering without the heavy drop-shadows of Material.
abstract final class MechXShadow {
  /// A resting card / floating control (palette, toolbar chip group).
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0F000000), blurRadius: 10, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x14000000), blurRadius: 1, offset: Offset(0, 0.5)),
  ];

  /// A transient popover / menu / inspector that floats above content.
  static const List<BoxShadow> popover = [
    BoxShadow(color: Color(0x1F000000), blurRadius: 28, offset: Offset(0, 12)),
    BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 1)),
  ];

  /// The raised selected segment inside an iOS segmented control.
  static const List<BoxShadow> segment = [
    BoxShadow(color: Color(0x1A000000), blurRadius: 6, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x0D000000), blurRadius: 1, offset: Offset(0, 0.5)),
  ];
}

/// Motion that orients — short, eased, never decorative (§4).
///
/// Base durations + curves, plus SEMANTIC IDIOMS naming the UX moment each
/// pairing serves so motion is consistent across surfaces (pair every idiom
/// duration with [standard] unless noted):
///   • [press]   — a control's press/scale feedback (snappy)
///   • [hover]    — hover fills, focus-border + focus-ring fades
///   • [appear]   — reveals, selection fades, menus/drawers/banners entering
///   • [dismiss]  — close / collapse / fade-out
/// Drag tracking uses NO animation (live, 1:1).
abstract final class MechXMotion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration medium = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubic;

  // Semantic idioms (names map a moment → a base duration; see class doc).
  static const Duration press = instant;
  static const Duration hover = fast;
  static const Duration appear = medium;
  static const Duration dismiss = fast;

  /// Tactile scale feedback — the single source of truth for the subtle
  /// hover LIFT and press DOWN-scale used by interactive nodes / cards
  /// (canvas panels, load nodes, layout markers). Values match the literals
  /// they replace so adoption is byte-identical.
  static const double hoverLift = 1.03;
  static const double pressScale = 0.98;

  /// The REDUCED-MOTION gate. **Every animated duration in the app must pass
  /// through this** so the operating system's "reduce motion" accessibility
  /// setting is honoured: when it is on, the app snaps to its end state instead
  /// of animating (Apple HIG treats reduced motion as a first-class input, and
  /// Flutter surfaces it as `MediaQuery.disableAnimations`).
  ///
  /// Usage — never pass a raw token to an animated widget:
  /// ```dart
  /// AnimatedOpacity(
  ///   duration: MechXMotion.resolve(context, MechXMotion.appear),
  ///   ...
  /// )
  /// ```
  ///
  /// Uses the `maybe` lookup so a widget pumped without a [MediaQuery] ancestor
  /// (bare unit tests, painter harnesses) gets the base duration rather than
  /// throwing. Behaviour is unchanged for everyone who has not enabled the
  /// setting.
  ///
  /// ONE CAVEAT — `AnimatedSize` must not receive the [Duration.zero] this can
  /// return: `RenderAnimatedSize` starts its controller from `performLayout`,
  /// and a zero-duration `forward()` notifies synchronously, re-dirtying the
  /// render object mid-layout (a framework assert). At an `AnimatedSize` site,
  /// branch on the resolved value and render the child unwrapped when it is
  /// zero — no animation is exactly what reduced motion asked for, and the
  /// resting layout is identical either way. Every other implicitly-animated
  /// widget (`AnimatedOpacity`, `AnimatedContainer`, `AnimatedRotation`,
  /// `AnimatedSwitcher`, `AnimatedDefaultTextStyle`, …) takes zero happily.
  static Duration resolve(BuildContext context, Duration base) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
          ? Duration.zero
          : base;
}

/// Liquid-Glass material constants — the translucent, blurred "glass" used by
/// the floating chrome layers (nav rail, top/status bars, inspector, sheet rail,
/// command palette, popovers, banners, zoom controls). Apple's Liquid Glass:
/// the navigation/control layer floats above content, refracting + blurring what
/// is behind it, with a soft specular sheen and a hairline edge; CONTENT stays
/// opaque + legible. The per-brightness fill / sheen / edge colours live on
/// [MechXColors] (`glassFill` / `glassSheen` / `glassEdge`); these are the
/// shared geometry/optics.
abstract final class MechXGlass {
  /// Backdrop blur radius for a primary chrome surface (bars, rails, inspector).
  static const double blurSigma = 18.0;

  /// A lighter blur for small floating controls (zoom cluster, chips, popovers).
  static const double blurSigmaLight = 12.0;

  /// Hairline edge stroke width (the bright rim that gives glass its "lens" read).
  static const double edgeWidth = 0.6;
}

/// A complete colour set for one brightness.
@immutable
class MechXColors {
  final Brightness brightness;
  final Color background; // app shell background
  final Color surface; // rails, bars, panels
  final Color surfaceHover;
  final Color border;
  final Color canvas; // area behind the sheets
  final Color sheetPaper; // a drawing "page"
  final Color gridLine;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent; // single brand accent
  final Color accentMuted;
  final Color warning; // unverified-standard flags
  final Color danger;
  final Color success;

  /// The label/glyph colour that sits ON the [accent] fill or a coloured node
  /// (filled segment, accent dot, on-canvas chip). White in both modes — kept a
  /// token so canvas painters stop reaching for raw `Color(0xFFFFFFFF)`.
  final Color onAccent;

  /// Dimming behind a modal / drawer (iOS sheets dim the content beneath). A
  /// touch lighter in light mode, deeper in dark, per HIG.
  final Color scrim;

  /// Liquid-Glass material (floating chrome only — see [MechXGlass]).
  /// [glassFill] is the TRANSLUCENT panel tint painted over the blurred
  /// backdrop; [glassSheen] is the top specular highlight the fill grades up
  /// into; [glassEdge] is the hairline rim. Defaulted so a custom palette that
  /// omits them still constructs (falls back to a neutral frost).
  final Color glassFill;
  final Color glassSheen;
  final Color glassEdge;

  const MechXColors({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceHover,
    required this.border,
    required this.canvas,
    required this.sheetPaper,
    required this.gridLine,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentMuted,
    required this.warning,
    required this.danger,
    required this.success,
    this.onAccent = const Color(0xFFFFFFFF),
    this.scrim = const Color(0x66000000),
    this.glassFill = const Color(0xCCFFFFFF),
    this.glassSheen = const Color(0xF2FFFFFF),
    this.glassEdge = const Color(0x40FFFFFF),
  });

  /// iOS light — systemGroupedBackground behind white cells, systemBlue accent,
  /// label / secondaryLabel / tertiaryLabel tiers, hairline separators.
  static const MechXColors light = MechXColors(
    brightness: Brightness.light,
    background: Color(0xFFF2F2F7), // systemGroupedBackground
    surface: Color(0xFFFFFFFF), // secondarySystemGroupedBackground
    surfaceHover: Color(0xFFE8E8ED), // systemGray5/6 fill
    border: Color(0xFFD7D7DC), // separator
    canvas: Color(0xFFE7E7EC), // behind the drawing sheets
    sheetPaper: Color(0xFFFFFFFF),
    gridLine: Color(0xFFDBDBE1),
    textPrimary: Color(0xFF1C1C1E), // label
    textSecondary: Color(0xFF6C6C70), // secondaryLabel
    textMuted: Color(0xFF9A9AA0), // tertiaryLabel
    accent: Color(0xFF007AFF), // systemBlue
    accentMuted: Color(0xFFD6E6FF), // tinted-button fill
    warning: Color(0xFFF08C00), // systemOrange (text-contrast tuned)
    danger: Color(0xFFFF3B30), // systemRed
    success: Color(0xFF30A46C), // systemGreen (text-contrast tuned)
    scrim: Color(0x66000000), // ~0.40 dim
    // Liquid Glass (light): a bright frosted white that lets the canvas tone
    // blur through — translucent enough to read as glass, with a crisp top
    // sheen and a soft white rim.
    glassFill: Color(0xA6FFFFFF), // ~0.65 white
    glassSheen: Color(0xFFFFFFFF), // opaque top highlight
    glassEdge: Color(0x80FFFFFF), // ~0.50 white hairline
  );

  /// iOS dark — elevated grey cells on a near-black grouped background,
  /// systemBlue (dark) accent, the dark label tiers.
  static const MechXColors dark = MechXColors(
    brightness: Brightness.dark,
    background: Color(0xFF1C1C1E), // systemGroupedBackground (dark)
    surface: Color(0xFF2C2C2E), // secondarySystemGroupedBackground (dark)
    surfaceHover: Color(0xFF3A3A3C), // systemGray5 (dark)
    border: Color(0xFF38383A), // separator (dark)
    canvas: Color(0xFF0E0E10), // near-black behind the design canvas
    sheetPaper: Color(0xFFF3F4F6),
    gridLine: Color(0xFF2A2A2C),
    textPrimary: Color(0xFFF5F5F7), // label (dark)
    textSecondary: Color(0xFFAEAEB2), // secondaryLabel (dark)
    textMuted: Color(0xFF8E8E93), // tertiaryLabel (dark)
    accent: Color(0xFF0A84FF), // systemBlue (dark)
    accentMuted: Color(0xFF1C3A5E), // tinted-button fill (dark)
    warning: Color(0xFFFF9F0A), // systemOrange (dark)
    danger: Color(0xFFFF453A), // systemRed (dark)
    success: Color(0xFF30D158), // systemGreen (dark)
    scrim: Color(0x8A000000), // ~0.54 dim (deeper in dark)
    // Liquid Glass (dark): a smoked translucent panel that lets the near-black
    // canvas blur through — dark enough to keep label contrast, with a white
    // sheen + rim that catch the light like real glass.
    glassFill: Color(0x99343438), // ~0.60 elevated grey
    glassSheen: Color(0x33FFFFFF), // ~0.20 white top highlight
    glassEdge: Color(0x40FFFFFF), // ~0.25 white hairline
  );
}

/// One type scale (color-less; callers apply a colour from [MechXColors]).
/// An SF-like scale rendered in Roboto: negative tracking on large text, a
/// clear weight hierarchy, comfortable line heights.
@immutable
class MechXTypography {
  final TextStyle display;
  final TextStyle title;
  final TextStyle subtitle;
  final TextStyle body;
  final TextStyle label;
  final TextStyle caption;
  final TextStyle micro; // dense on-canvas labels (panel letters, wire tags)
  final TextStyle mono; // measurements / tabular numbers

  const MechXTypography({
    required this.display,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.label,
    required this.caption,
    required this.micro,
    required this.mono,
  });

  static const String fontFamily = 'Roboto';
  static const String monoFamily = 'Roboto Mono';

  /// Returns [base] with TABULAR (fixed-advance) figures.
  ///
  /// Use for **any number that updates while it is visible** — live readouts,
  /// solved totals, stepper values, zoom %, stat tiles, schedule/BOM numeric
  /// columns. With proportional figures a `1` is narrower than a `0`, so a
  /// recomputing value makes its row shuffle sideways; `tnum` fixes every digit
  /// to one advance width, so the digits change but the layout never moves.
  /// (Roboto ships the feature — the gap is adoption, not the font. [mono]
  /// already carries it; this is the helper for the proportional styles.)
  ///
  /// Static numbers (labels, one-shot captions) do not need it.
  static TextStyle tabular(TextStyle base) =>
      base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  static const MechXTypography standard = MechXTypography(
    display: TextStyle(fontFamily: fontFamily, fontSize: 28, height: 1.16, fontWeight: FontWeight.w700, letterSpacing: -0.5),
    title: TextStyle(fontFamily: fontFamily, fontSize: 19, height: 1.2, fontWeight: FontWeight.w600, letterSpacing: -0.4),
    subtitle: TextStyle(fontFamily: fontFamily, fontSize: 15.5, height: 1.27, fontWeight: FontWeight.w600, letterSpacing: -0.2),
    body: TextStyle(fontFamily: fontFamily, fontSize: 14.5, height: 1.4, fontWeight: FontWeight.w400, letterSpacing: -0.1),
    label: TextStyle(fontFamily: fontFamily, fontSize: 13, height: 1.3, fontWeight: FontWeight.w500, letterSpacing: -0.05),
    caption: TextStyle(fontFamily: fontFamily, fontSize: 12, height: 1.3, fontWeight: FontWeight.w500, letterSpacing: 0.1),
    micro: TextStyle(fontFamily: fontFamily, fontSize: 9, height: 1.2, fontWeight: FontWeight.w600, letterSpacing: 0.1),
    mono: TextStyle(
      fontFamily: monoFamily,
      fontSize: 13,
      height: 1.3,
      fontWeight: FontWeight.w500,
      fontFeatures: [FontFeature.tabularFigures()],
    ),
  );
}
