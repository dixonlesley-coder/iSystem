import 'package:flutter/widgets.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';

/// Distinct, legible line colour per service (readable on the light/dark canvas).
Color serviceColor(ServiceType service) => switch (service) {
      ServiceType.coldWater => const Color(0xFF2D6CDF),
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
