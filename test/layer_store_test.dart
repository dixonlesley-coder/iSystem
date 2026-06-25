import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx_engine/network/network.dart';

/// The discipline-LAYER state for the unified Layout canvas: the pure
/// `ServiceType → discipline` mapping, the active-layer / visibility providers,
/// and their invariants (the active layer is always visible).
void main() {
  group('disciplineOf / servicesFor (pure mapping)', () {
    test('each service maps to its engineering-system layer', () {
      expect(disciplineOf(ServiceType.coldWater), DisciplineLayer.water);
      expect(disciplineOf(ServiceType.hotWater), DisciplineLayer.water);
      expect(disciplineOf(ServiceType.drainage), DisciplineLayer.sanitary);
      expect(disciplineOf(ServiceType.vent), DisciplineLayer.sanitary);
      expect(disciplineOf(ServiceType.rainwater), DisciplineLayer.storm);
      expect(disciplineOf(ServiceType.fireSprinkler), DisciplineLayer.fire);
      expect(disciplineOf(ServiceType.fireHydrant), DisciplineLayer.fire);
      expect(disciplineOf(ServiceType.duct), DisciplineLayer.hvac);
      expect(disciplineOf(ServiceType.returnAir), DisciplineLayer.hvac);
      expect(disciplineOf(ServiceType.exhaust), DisciplineLayer.hvac);
    });

    test('every air service is HVAC; no non-air service is HVAC', () {
      for (final s in ServiceType.values) {
        expect(disciplineOf(s) == DisciplineLayer.hvac, s.isAir, reason: '$s');
      }
    });

    test('servicesFor partitions ServiceType exactly across the layers', () {
      final byLayer = {
        for (final l in DisciplineLayer.values) l: servicesFor(l).toSet(),
      };
      // Pairwise disjoint…
      final all = <ServiceType>[];
      for (final set in byLayer.values) {
        expect(set.intersection(all.toSet()), isEmpty);
        all.addAll(set);
      }
      // …and together cover every service.
      expect(all.toSet(), ServiceType.values.toSet());
      // Every service maps back to the layer it was bucketed into.
      byLayer.forEach((layer, services) {
        for (final s in services) {
          expect(disciplineOf(s), layer);
        }
      });
    });

    test('electrical has no ServiceType services', () {
      expect(servicesFor(DisciplineLayer.electrical), isEmpty);
    });

    test('every discipline has an ASCII label (Roboto-safe, no tofu)', () {
      for (final l in DisciplineLayer.values) {
        expect(l.label.codeUnits.every((c) => c < 128), isTrue,
            reason: '"${l.label}"');
      }
    });

    test('isMechanical: every system true, electrical false', () {
      for (final l in DisciplineLayer.values) {
        expect(l.isMechanical, l != DisciplineLayer.electrical, reason: '$l');
      }
    });
  });

  group('active discipline + visibility', () {
    ProviderContainer make() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('defaults: water active, all layers visible', () {
      final c = make();
      expect(c.read(activeDisciplineProvider), DisciplineLayer.water);
      expect(c.read(layerVisibilityProvider), DisciplineLayer.values.toSet());
    });

    test('setting the active layer changes it', () {
      final c = make();
      c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
      expect(c.read(activeDisciplineProvider), DisciplineLayer.hvac);
      c
          .read(activeDisciplineProvider.notifier)
          .set(DisciplineLayer.electrical);
      expect(c.read(activeDisciplineProvider), DisciplineLayer.electrical);
    });

    test('toggling a non-active layer hides then shows it', () {
      final c = make();
      // plumbing is active; toggle electrical (non-active) off.
      c.read(layerVisibilityProvider.notifier).toggle(DisciplineLayer.electrical);
      expect(
          c.read(layerVisibilityProvider).contains(DisciplineLayer.electrical),
          isFalse);
      // Toggle it back on.
      c.read(layerVisibilityProvider.notifier).toggle(DisciplineLayer.electrical);
      expect(
          c.read(layerVisibilityProvider).contains(DisciplineLayer.electrical),
          isTrue);
    });

    test('the active layer cannot be toggled off (you edit it)', () {
      final c = make();
      // water active by default — toggling it off is a no-op.
      c.read(layerVisibilityProvider.notifier).toggle(DisciplineLayer.water);
      expect(
          c.read(layerVisibilityProvider).contains(DisciplineLayer.water),
          isTrue);
    });

    test('selecting a hidden layer as active re-shows it', () {
      final c = make();
      // Hide HVAC (not active), then make it active → it must become visible.
      c.read(layerVisibilityProvider.notifier).toggle(DisciplineLayer.hvac);
      expect(c.read(layerVisibilityProvider).contains(DisciplineLayer.hvac),
          isFalse);
      c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
      expect(c.read(activeDisciplineProvider), DisciplineLayer.hvac);
      expect(c.read(layerVisibilityProvider).contains(DisciplineLayer.hvac),
          isTrue);
    });
  });
}
