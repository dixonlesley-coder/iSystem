import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx_engine/network/network.dart';

/// The discipline-LAYER state for the unified Layout canvas: the pure
/// `ServiceType → discipline` mapping, the active-layer / visibility providers,
/// and their invariants (the active layer is always visible).
void main() {
  group('disciplineOf / servicesFor (pure mapping)', () {
    test('air services map to HVAC, the rest to plumbing', () {
      expect(disciplineOf(ServiceType.duct), DisciplineLayer.hvac);
      expect(disciplineOf(ServiceType.returnAir), DisciplineLayer.hvac);
      expect(disciplineOf(ServiceType.exhaust), DisciplineLayer.hvac);
      for (final s in const [
        ServiceType.coldWater,
        ServiceType.hotWater,
        ServiceType.drainage,
        ServiceType.vent,
        ServiceType.rainwater,
        ServiceType.fireSprinkler,
        ServiceType.fireHydrant,
      ]) {
        expect(disciplineOf(s), DisciplineLayer.plumbing, reason: '$s');
      }
    });

    test('disciplineOf matches the engine isAir flag for every service', () {
      for (final s in ServiceType.values) {
        expect(
          disciplineOf(s),
          s.isAir ? DisciplineLayer.hvac : DisciplineLayer.plumbing,
          reason: '$s',
        );
      }
    });

    test('servicesFor partitions ServiceType exactly (plumbing + hvac = all)',
        () {
      final plumbing = servicesFor(DisciplineLayer.plumbing).toSet();
      final hvac = servicesFor(DisciplineLayer.hvac).toSet();
      // Disjoint…
      expect(plumbing.intersection(hvac), isEmpty);
      // …and together cover every service.
      expect({...plumbing, ...hvac}, ServiceType.values.toSet());
      // Every service maps back to the layer it was bucketed into.
      for (final s in plumbing) {
        expect(disciplineOf(s), DisciplineLayer.plumbing);
      }
      for (final s in hvac) {
        expect(disciplineOf(s), DisciplineLayer.hvac);
      }
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

    test('isMechanical: plumbing + hvac true, electrical false', () {
      expect(DisciplineLayer.plumbing.isMechanical, isTrue);
      expect(DisciplineLayer.hvac.isMechanical, isTrue);
      expect(DisciplineLayer.electrical.isMechanical, isFalse);
    });
  });

  group('active discipline + visibility', () {
    ProviderContainer make() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('defaults: plumbing active, all three visible', () {
      final c = make();
      expect(c.read(activeDisciplineProvider), DisciplineLayer.plumbing);
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
      // plumbing active by default — toggling it off is a no-op.
      c.read(layerVisibilityProvider.notifier).toggle(DisciplineLayer.plumbing);
      expect(
          c.read(layerVisibilityProvider).contains(DisciplineLayer.plumbing),
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
