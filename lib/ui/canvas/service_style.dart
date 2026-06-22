import 'package:flutter/widgets.dart';
import 'package:mechx_engine/network/network.dart';

/// Distinct, legible line colour per service (readable on the light/dark canvas).
Color serviceColor(ServiceType service) => switch (service) {
      ServiceType.coldWater => const Color(0xFF2D6CDF),
      ServiceType.hotWater => const Color(0xFFE5673A),
      ServiceType.drainage => const Color(0xFF8A6D3B),
      ServiceType.vent => const Color(0xFF2BB6A3),
      ServiceType.rainwater => const Color(0xFF3AA0E5),
      ServiceType.duct => const Color(0xFF8A7BD8),
      ServiceType.fireSprinkler => const Color(0xFFD93838),
      ServiceType.fireHydrant => const Color(0xFFB02525),
    };

String serviceLabel(ServiceType service) => switch (service) {
      ServiceType.coldWater => 'Cold water',
      ServiceType.hotWater => 'Hot water',
      ServiceType.drainage => 'Drainage',
      ServiceType.vent => 'Vent',
      ServiceType.rainwater => 'Rainwater',
      ServiceType.duct => 'Duct',
      ServiceType.fireSprinkler => 'Sprinkler',
      ServiceType.fireHydrant => 'Hydrant',
    };
