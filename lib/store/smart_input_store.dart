import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/widgets/locale_number.dart' show parseLocaleNumber;
import 'network_store.dart' show DrawTool, networkControllerProvider;
import 'route_geometry.dart';

/// Parsed smart-input: an exact length in millimetres with an optional
/// bearing override, OR (M9) an AutoCAD relative-Cartesian displacement. The
/// calm, discoverable alternative to AutoCAD's hidden command line — type
/// "3000" for a 3 m run along the current pointing direction (direct-distance
/// entry), "3000 90" / "3000<90" / "@3000<90" to also pin the bearing, or
/// "@1500,-2000" for a displacement 1.5 m east and 2 m south.
///
/// ANGLES follow the AutoCAD convention: 0° = East (+x), counter-clockwise
/// positive, so 90° = North = UP the screen (screen Y grows downward — the
/// target maths negates the sine, see [polarRunTarget]). Cartesian Y is the
/// AutoCAD +Y, i.e. also UP the screen ([drawInputTarget] negates it).
@immutable
class DrawInput {
  /// Run length in millimetres (> 0) for the length / polar forms; null for
  /// the Cartesian form, or when the text is empty or invalid (see [error]).
  final double? lengthMm;

  /// Optional bearing in degrees (0 = East / +x, 90 = North / up; CCW positive).
  /// Null ⇒ use the live pointing direction.
  final double? angleDeg;

  /// M9 — the relative Cartesian displacement (`@dx,dy`) in millimetres,
  /// AutoCAD axes (+X east, +Y north / up the screen). Both set or both null.
  final double? dxMm;
  final double? dyMm;

  /// A human-readable validation message, or null when input is empty/valid.
  final String? error;

  const DrawInput({
    this.lengthMm,
    this.angleDeg,
    this.dxMm,
    this.dyMm,
    this.error,
  });

  /// Whether this is the `@dx,dy` relative-Cartesian form.
  bool get isCartesian => dxMm != null && dyMm != null;

  /// True when there is a usable length (or displacement) and no error.
  bool get ok => error == null && (lengthMm != null || isCartesian);
}

/// The Cartesian example the active locale accepts, for messages.
String _xyExample(bool indonesian) =>
    indonesian ? '@1500;-2000' : '@1500,-2000';

/// Parse the smart-input text. Empty text is a no-op (no error, no length).
/// Validation messages are plain language. Accepted forms (M9 — the AutoCAD
/// dynamic-input vocabulary):
///
///   * `len`       — a length in mm along the live pointing direction;
///   * `len ang`   — a length and a bearing (the original form);
///   * `len<ang`   — AutoCAD polar: a length at a bearing;
///   * `@len<ang`  — the same written relative (every typed point here is
///                   relative to the last one, so the `@` is optional);
///   * `@dx,dy`    — AutoCAD relative Cartesian in mm (+Y is up / north).
///
/// Round 19 (regression-locale-parser-not-universal) — every number goes
/// through the ONE engineering-number parser ([parseLocaleNumber]): in the
/// Indonesian UI ([indonesian]) `1.500` is 1500 mm (`.` groups thousands) and
/// `2,5` is 2.5 mm, exactly as the offset dialog reads the same keystrokes.
///
/// The Cartesian SEPARATOR: `;` is ALWAYS accepted (`@1500;-2000`, either
/// locale — each part then parses by the locale's rules, so `@1,5;2,5` is
/// 1.5 / 2.5 mm in Indonesian). Without a `;`, exactly ONE `,` separates x and
/// y in either locale: in English that is AutoCAD's own form (`@1500,-2000`);
/// in Indonesian, where `,` is the decimal mark, a lone comma after `@` is
/// still unambiguous (an `@` point always needs TWO numbers), so it is read as
/// the separator too. Any other comma count (`@1,5,2,5`, `@1,500,2,000`) is
/// refused with a hint to use `;` — never guessed.
DrawInput parseDrawingInput(String text, {bool indonesian = false}) {
  final t = text.trim();
  if (t.isEmpty) return const DrawInput();
  var body = t;
  final relative = body.startsWith('@');
  if (relative) body = body.substring(1).trim();
  if (body.contains('<')) return _parsePolar(body, indonesian);
  if (relative) return _parseCartesian(body, indonesian);
  final parts = body.split(RegExp(r'\s+'));
  final mm = parseLocaleNumber(parts[0], indonesian: indonesian);
  // `double.tryParse` happily returns NaN / Infinity ('NaN', 'Infinity',
  // '1e400'); a non-finite length would plant a NaN/Infinity node that the
  // JSON encoder refuses, making Save and autosave throw (Round 10).
  if (mm == null || !mm.isFinite) {
    return const DrawInput(error: 'Enter a length in mm, e.g. 3000');
  }
  if (mm <= 0) return const DrawInput(error: 'Length must be greater than 0');
  if (parts.length > 2) {
    return const DrawInput(error: 'Enter a length and an optional angle only');
  }
  double? angle;
  if (parts.length > 1) {
    angle = parseLocaleNumber(parts[1], indonesian: indonesian);
    if (angle == null || !angle.isFinite) {
      return const DrawInput(error: 'Angle must be a number, e.g. 3000 90');
    }
  }
  return DrawInput(lengthMm: mm, angleDeg: angle);
}

/// `len<ang` (the `@` already stripped).
DrawInput _parsePolar(String body, bool indonesian) {
  const usage = 'Polar entry is length<angle, e.g. 3000<45';
  final parts = body.split('<');
  if (parts.length != 2) return const DrawInput(error: usage);
  final mm = parseLocaleNumber(parts[0].trim(), indonesian: indonesian);
  if (mm == null || !mm.isFinite) return const DrawInput(error: usage);
  if (mm <= 0) return const DrawInput(error: 'Length must be greater than 0');
  final angle = parseLocaleNumber(parts[1].trim(), indonesian: indonesian);
  if (angle == null || !angle.isFinite) {
    return const DrawInput(error: 'Angle must be a number, e.g. 3000<45');
  }
  return DrawInput(lengthMm: mm, angleDeg: angle);
}

/// `dx,dy` / `dx;dy` (the `@` already stripped). See [parseDrawingInput] for
/// the separator rules.
DrawInput _parseCartesian(String body, bool indonesian) {
  final example = _xyExample(indonesian);
  final List<String> parts;
  if (body.contains(';')) {
    parts = body.split(';');
  } else {
    if (','.allMatches(body).length != 1) {
      return DrawInput(error: 'Separate x and y with ; e.g. @1500;-2000');
    }
    parts = body.split(',');
  }
  if (parts.length != 2) {
    return DrawInput(error: 'Enter @x,y in mm, e.g. $example');
  }
  final dx = parseLocaleNumber(parts[0].trim(), indonesian: indonesian);
  final dy = parseLocaleNumber(parts[1].trim(), indonesian: indonesian);
  if (dx == null || dy == null || !dx.isFinite || !dy.isFinite) {
    return DrawInput(error: 'Enter @x,y in mm, e.g. $example');
  }
  if (dx == 0 && dy == 0) {
    return const DrawInput(error: 'The displacement must not be zero');
  }
  return DrawInput(dxMm: dx, dyMm: dy);
}

/// The world point a parsed, [DrawInput.ok] entry lands at from [from]:
/// `@dx,dy` adds the displacement (AutoCAD +Y is up the screen, so the world
/// y is NEGATED); the length forms go through [polarRunTarget] (a typed angle,
/// else the unit vector toward [hover]). [pxPerMm] is the sheet calibration's
/// world pixels per millimetre. Pure — shared by the run, the base-point
/// commands and their tests.
Offset drawInputTarget(
  Offset from,
  DrawInput input,
  double pxPerMm, {
  Offset? hover,
}) {
  if (input.isCartesian) {
    return from + Offset(input.dxMm! * pxPerMm, -input.dyMm! * pxPerMm);
  }
  return polarRunTarget(from, input.lengthMm! * pxPerMm,
      angleDeg: input.angleDeg, hover: hover);
}

/// A one-line read-back of a parsed [input] for the smart bar's preview
/// ("3000 mm = 3.00 m @ 90°", "@ x 1.50 m, y -2.00 m"). Empty for an
/// unusable input.
String describeDrawInput(DrawInput input) {
  if (!input.ok) return '';
  if (input.isCartesian) {
    return '@ x ${_metres(input.dxMm!)}, y ${_metres(input.dyMm!)}';
  }
  final len = input.lengthMm!;
  final m = len / 1000.0;
  final a = input.angleDeg;
  return '${len.toStringAsFixed(0)} mm = '
      '${m.toStringAsFixed(m >= 10 ? 0 : 2)} m'
      '${a != null ? ' @ ${formatAngleDeg(a)}°' : ''}';
}

String _metres(double mm) {
  final v = mm / 1000.0;
  return '${v.toStringAsFixed(v.abs() >= 10 ? 1 : 2)} m';
}

/// An angle for a read-back: whole degrees plain, else one decimal.
String formatAngleDeg(double a) =>
    a == a.roundToDouble() ? a.toStringAsFixed(0) : a.toStringAsFixed(1);

/// Parse a typed ROTATION angle (degrees, the AutoCAD sense: counter-clockwise
/// positive as seen on the plan). An optional leading `<` is accepted. Empty
/// text is neither an angle nor an error.
({double? degrees, String? error}) parseAngleInput(String text,
    {bool indonesian = false}) {
  var t = text.trim();
  if (t.isEmpty) return (degrees: null, error: null);
  if (t.startsWith('<')) t = t.substring(1).trim();
  final a = parseLocaleNumber(t, indonesian: indonesian);
  if (a == null || !a.isFinite) {
    return (degrees: null, error: 'Enter an angle in degrees, e.g. 90');
  }
  return (degrees: a, error: null);
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

/// The live endpoint STRETCH a typed length may finish: the free run end
/// [nodeId] being dragged by its grip, the one run [edgeId] it ends, and
/// whether a typed length has already set it ([typed] — the rest of the
/// pointer drag is then inert, so the exact length survives the release).
typedef EndpointStretch = ({String nodeId, String edgeId, bool typed});

/// Item 2 (AutoCAD grip-stretch + typed distance) — published by the
/// selection overlay while a free run endpoint's grip is dragged, so the smart
/// input bar can offer 'Length' and the canvas forwards the typed digits to it.
/// Null at rest (no bar, byte-identical).
class EndpointStretchController extends Notifier<EndpointStretch?> {
  @override
  EndpointStretch? build() {
    // A tool switch unmounts the selection overlay mid-drag (its pan end never
    // fires): never leave a stale stretch for the bar to offer.
    ref.listen<DrawTool>(networkControllerProvider.select((d) => d.tool),
        (_, _) => end());
    return null;
  }

  void begin(String nodeId, String edgeId) =>
      state = (nodeId: nodeId, edgeId: edgeId, typed: false);

  /// A typed length has set the run: the rest of this drag is inert.
  void markTyped() {
    final s = state;
    if (s != null && !s.typed) {
      state = (nodeId: s.nodeId, edgeId: s.edgeId, typed: true);
    }
  }

  void end() {
    if (state != null) state = null;
  }
}

final endpointStretchProvider =
    NotifierProvider<EndpointStretchController, EndpointStretch?>(
        EndpointStretchController.new);

/// B17 — the ortho two-click ROUTE shape currently previewed while drawing. Null
/// = auto ([autoRouteKind] picks from the start→end geometry); Tab cycles
/// auto → L(H,V) → L(V,H) → Z → auto. Reset to null when the pending run clears
/// or a route commits, so a fresh run starts on Auto. Transient draw-UI state —
/// never persisted, so an idle canvas is byte-identical.
class OrthoRouteKindController extends Notifier<OrthoRouteKind?> {
  @override
  OrthoRouteKind? build() => null;

  /// Cycle to the next explicit route shape (Tab), wrapping back to Auto.
  void cycle() {
    state = switch (state) {
      null => OrthoRouteKind.horizontalFirst,
      OrthoRouteKind.horizontalFirst => OrthoRouteKind.verticalFirst,
      OrthoRouteKind.verticalFirst => OrthoRouteKind.diagonalZ,
      OrthoRouteKind.diagonalZ => null,
    };
  }

  /// Back to Auto (a route committed / the run cancelled).
  void reset() {
    if (state != null) state = null;
  }
}

final orthoRouteKindProvider =
    NotifierProvider<OrthoRouteKindController, OrthoRouteKind?>(
        OrthoRouteKindController.new);

/// B25 — the last parallel-offset distance (millimetres) used by the Alt
/// parallel-lock draw gesture, seeded live from the smart input bar. Default
/// 300 mm. Held in memory only (never persisted).
class ParallelOffsetController extends Notifier<double> {
  @override
  double build() => 300;

  void set(double mm) {
    if (mm > 0 && mm != state) state = mm;
  }
}

final parallelOffsetProvider =
    NotifierProvider<ParallelOffsetController, double>(
        ParallelOffsetController.new);

/// B30 — the live draw pointer in canvas-local screen px (or null when not in a
/// draw gesture), published by the drawing overlay so the shared [CanvasView]
/// can auto-pan while the cursor sits in the viewport edge band. Read (never
/// watched) by the canvas's auto-pan ticker; null ⇒ no auto-pan ⇒
/// byte-identical.
class CanvasAutoPanController extends Notifier<Offset?> {
  @override
  Offset? build() => null;

  /// Whether a draw gesture currently holds the probe (P14 — lets a teardown
  /// path skip a no-op write instead of touching the provider mid-build).
  bool get isActive => state != null;

  void set(Offset? p) {
    if (state != p) state = p;
  }
}

final canvasAutoPanProbeProvider =
    NotifierProvider<CanvasAutoPanController, Offset?>(
        CanvasAutoPanController.new);
