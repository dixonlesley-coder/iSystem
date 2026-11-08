import 'package:flutter/widgets.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';

/// Distinct, legible line colour per service (readable on the light/dark canvas).
///
/// Cold water is a DEEP cobalt blue (#1E4FC4), deliberately deepened from the
/// old #2D6CDF so it reads as drawing INK, distinct from the app's bright
/// systemBlue selection accent (#007AFF) it used to collapse into — E3. This is
/// the single source of truth: the engine-side `serviceChromeColor` (PDF) and
/// `serviceAciColorFor` (DXF) mirror it channel-for-channel, pinned by
/// `service_colour_parity_test`.
Color serviceColor(ServiceType service) => switch (service) {
      ServiceType.coldWater => const Color(0xFF1E4FC4),
      ServiceType.hotWater => const Color(0xFFE5673A),
      ServiceType.drainage => const Color(0xFF8A6D3B),
      ServiceType.vent => const Color(0xFF2BB6A3),
      ServiceType.rainwater => const Color(0xFF3AA0E5),
      ServiceType.duct => const Color(0xFF8A7BD8),
      ServiceType.returnAir => const Color(0xFF6F8FC0),
      ServiceType.exhaust => const Color(0xFF5B6470),
      ServiceType.fireSprinkler => const Color(0xFFD93838),
      ServiceType.fireHydrant => const Color(0xFFB02525),
    };

/// On-canvas dash pattern per service (a `[dash, gap, …]` stroke recipe walked
/// by the painter), or null when the service is drawn SOLID. Vent + return air
/// read dashed; the two fire services read dash-dot — the standard drafting
/// convention for these lines.
///
/// This deliberately MIRRORS the engine-side chrome dash table the same way
/// [serviceColor] mirrors `serviceChromeColor`: two parallel lookups, one
/// convention. A parallel agent adds the engine-side table this stage, so this
/// intentionally does NOT import `drawing_chrome` (the app canvas has no engine
/// chrome dependency here) — keep the two in step by hand.
List<double>? serviceDashPattern(ServiceType service) => switch (service) {
      ServiceType.vent || ServiceType.returnAir => const [6, 4],
      ServiceType.fireSprinkler ||
      ServiceType.fireHydrant =>
        const [10, 3, 2, 3],
      _ => null,
    };

String serviceLabel(ServiceType service) => switch (service) {
      ServiceType.coldWater => 'Cold water',
      ServiceType.hotWater => 'Hot water',
      ServiceType.drainage => 'Drainage',
      ServiceType.vent => 'Vent',
      ServiceType.rainwater => 'Rainwater',
      ServiceType.duct => 'Supply air',
      ServiceType.returnAir => 'Return air',
      ServiceType.exhaust => 'Exhaust',
      ServiceType.fireSprinkler => 'Sprinkler',
      ServiceType.fireHydrant => 'Hydrant',
    };

/// Human-readable material label for an edge's chosen pipe/duct product, or
/// null when no material is set. Uses the catalog's own [labelFor]/[ductLabelFor].
String? edgeMaterialLabel(NetEdge edge) {
  if (edge.pipeProduct != null) return labelFor(edge.pipeProduct!);
  if (edge.ductProduct != null) return ductLabelFor(edge.ductProduct!);
  return null;
}

/// A horizontal line swatch in the service colour, drawn solid or as the
/// service's dash recipe so a dashed service (vent) reads dashed in the key too.
/// Shared by the canvas legend chip and the tool cluster — one swatch source.
class ServiceSwatchPainter extends CustomPainter {
  final Color color;
  final List<double>? dash;
  const ServiceSwatchPainter(this.color, this.dash);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    final d = dash;
    if (d == null || d.isEmpty) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    var x = 0.0;
    var i = 0;
    var on = true;
    while (x < size.width) {
      final seg = d[i % d.length];
      final end = (x + seg).clamp(0.0, size.width);
      if (on && end > x) canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x = end;
      i++;
      on = !on;
    }
  }

  @override
  bool shouldRepaint(ServiceSwatchPainter old) =>
      old.color != color || old.dash != dash;
}
