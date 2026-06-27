import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Parsed smart-input while drawing a run: an exact length in millimetres and an
/// optional bearing override. The calm, discoverable alternative to AutoCAD's
/// hidden command line — type "3000" for a 3 m run along the current pointing
/// direction (direct-distance entry), or "3000 90" to also pin the bearing.
@immutable
class DrawInput {
  /// Run length in millimetres (> 0) once parsed; null when the text is empty
  /// or invalid (see [error]).
  final double? lengthMm;

  /// Optional bearing in degrees (0 = East / +x, 90 = North / up; CCW positive).
  /// Null ⇒ use the live pointing direction.
  final double? angleDeg;

  /// A human-readable validation message, or null when input is empty/valid.
  final String? error;

  const DrawInput({this.lengthMm, this.angleDeg, this.error});

  /// True when there is a usable length and no error.
  bool get ok => error == null && lengthMm != null;
}

/// Parse the smart-input text. Format: `<length-mm> [<angle-deg>]`. Empty text
/// is a no-op (no error, no length). Validation messages are plain language.
DrawInput parseDrawingInput(String text) {
  final t = text.trim();
  if (t.isEmpty) return const DrawInput();
  final parts = t.split(RegExp(r'\s+'));
  final mm = double.tryParse(parts[0]);
  if (mm == null) {
    return const DrawInput(error: 'Enter a length in mm, e.g. 3000');
  }
  if (mm <= 0) return const DrawInput(error: 'Length must be greater than 0');
  double? angle;
  if (parts.length > 1) {
    angle = double.tryParse(parts[1]);
    if (angle == null) {
      return const DrawInput(error: 'Angle must be a number, e.g. 3000 90');
    }
  }
  return DrawInput(lengthMm: mm, angleDeg: angle);
}

/// Compute the target world point for a precise run entry, [lengthPx] pixels
/// from [pending]. The direction is [angleDeg] when given (0° = East/+x, 90° =
/// North/up; screen Y is down so sin is negated), otherwise the unit vector
/// toward [hover] (direct-distance entry), falling back to East when the cursor
/// hasn't moved off [pending]. Pure — drives both the widget and its test.
Offset polarRunTarget(
  Offset pending,
  double lengthPx, {
  double? angleDeg,
  Offset? hover,
}) {
  Offset dir;
  if (angleDeg != null) {
    final rad = angleDeg * math.pi / 180.0;
    dir = Offset(math.cos(rad), -math.sin(rad));
  } else if (hover != null && hover != pending) {
    final d = hover - pending;
    dir = d.distance > 0 ? d / d.distance : const Offset(1, 0);
  } else {
    dir = const Offset(1, 0);
  }
  return pending + dir * lengthPx;
}

/// Live draw-cursor world point, published by the DrawingOverlay so the smart
/// input bar can place a length-only entry along the current pointing direction
/// (direct-distance entry). It is READ on commit, never watched, so per-frame
/// hover churn never rebuilds the bar.
class DrawHoverController extends Notifier<Offset?> {
  @override
  Offset? build() => null;

  void set(Offset? p) {
    if (state != p) state = p;
  }
}

final drawHoverProvider =
    NotifierProvider<DrawHoverController, Offset?>(DrawHoverController.new);
