import 'package:flutter/widgets.dart';

/// MechX design tokens — the single source for spacing, radii, motion, colour,
/// and type. Restrained and custom; deliberately NOT Material's defaults (§4).

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

abstract final class MechXRadii {
  static const Radius sm = Radius.circular(4);
  static const Radius md = Radius.circular(8);
  static const Radius lg = Radius.circular(12);
  static const BorderRadius card = BorderRadius.all(md);
  static const BorderRadius control = BorderRadius.all(sm);
}

/// Motion that orients — short, eased, never decorative (§4).
abstract final class MechXMotion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration medium = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubic;
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
  });

  static const MechXColors light = MechXColors(
    brightness: Brightness.light,
    background: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceHover: Color(0xFFEEF1F5),
    border: Color(0xFFE1E5EB),
    canvas: Color(0xFFEAEDF1),
    sheetPaper: Color(0xFFFFFFFF),
    gridLine: Color(0xFFD6DBE2),
    textPrimary: Color(0xFF1A1C20),
    textSecondary: Color(0xFF565C66),
    textMuted: Color(0xFF878E99),
    accent: Color(0xFF2D6CDF),
    accentMuted: Color(0xFFBCCFF4),
    warning: Color(0xFFB07A12),
    danger: Color(0xFFC0392B),
    success: Color(0xFF2E7D52),
  );

  static const MechXColors dark = MechXColors(
    brightness: Brightness.dark,
    background: Color(0xFF111317),
    surface: Color(0xFF181B20),
    surfaceHover: Color(0xFF20242B),
    border: Color(0xFF2A2F37),
    canvas: Color(0xFF0C0E11),
    sheetPaper: Color(0xFFF3F4F6),
    gridLine: Color(0xFF242932),
    textPrimary: Color(0xFFE9EBEF),
    textSecondary: Color(0xFFA2A9B4),
    textMuted: Color(0xFF6E7682),
    accent: Color(0xFF5B8DEF),
    accentMuted: Color(0xFF2B3D5F),
    warning: Color(0xFFD9A441),
    danger: Color(0xFFE5675A),
    success: Color(0xFF54B888),
  );
}

/// One type scale (color-less; callers apply a colour from [MechXColors]).
@immutable
class MechXTypography {
  final TextStyle display;
  final TextStyle title;
  final TextStyle subtitle;
  final TextStyle body;
  final TextStyle label;
  final TextStyle caption;
  final TextStyle mono; // measurements / tabular numbers

  const MechXTypography({
    required this.display,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.label,
    required this.caption,
    required this.mono,
  });

  static const MechXTypography standard = MechXTypography(
    display: TextStyle(fontSize: 26, height: 1.2, fontWeight: FontWeight.w600, letterSpacing: -0.2),
    title: TextStyle(fontSize: 18, height: 1.25, fontWeight: FontWeight.w600, letterSpacing: -0.1),
    subtitle: TextStyle(fontSize: 15, height: 1.3, fontWeight: FontWeight.w600),
    body: TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w400),
    label: TextStyle(fontSize: 12.5, height: 1.3, fontWeight: FontWeight.w500, letterSpacing: 0.1),
    caption: TextStyle(fontSize: 11.5, height: 1.3, fontWeight: FontWeight.w400, letterSpacing: 0.2),
    mono: TextStyle(
      fontSize: 13,
      height: 1.3,
      fontWeight: FontWeight.w500,
      fontFamilyFallback: ['Consolas', 'Menlo', 'monospace'],
      fontFeatures: [FontFeature.tabularFigures()],
    ),
  );
}
