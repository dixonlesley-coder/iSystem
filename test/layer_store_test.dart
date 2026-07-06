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
      // All plumbing pipework — water, sanitary, storm — is the ONE plumbing
      // layer (drawn together; separated by ServiceType downstream).
      expect(disciplineOf(ServiceType.coldWater), DisciplineLayer.plumbing);
      expect(disciplineOf(ServiceType.hotWater), DisciplineLayer.plumbing);
      expect(disciplineOf(ServiceType.drainage), DisciplineLayer.plumbing);
      expect(disciplineOf(ServiceType.vent), DisciplineLayer.plumbing);
      expect(disciplineOf(ServiceType.rainwater), DisciplineLayer.plumbing);
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

    test('defaults: plumbing active, all layers visible', () {
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

  group('F1: reference-layer lock', () {
    ProviderContainer make() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('default: nothing is locked', () {
      final c = make();
      expect(c.read(lockedDisciplinesProvider), isEmpty);
    });

    test('toggle locks a non-active layer, then unlocks it', () {
      final c = make();
      // plumbing is active; lock HVAC (a reference layer).
      c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.hvac);
      expect(c.read(lockedDisciplinesProvider), {DisciplineLayer.hvac});
      // toggle again → unlocked.
      c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.hvac);
      expect(c.read(lockedDisciplinesProvider), isEmpty);
    });

    test('the ACTIVE layer can never be locked (lock is for references)', () {
      final c = make();
      // plumbing is active by default — locking it is a no-op.
      c.read(lockedDisciplinesProvider.notifier)
          .toggle(DisciplineLayer.plumbing);
      expect(c.read(lockedDisciplinesProvider), isEmpty);
    });

    test('making a locked layer active unlocks it', () {
      final c = make();
      c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.hvac);
      expect(c.read(lockedDisciplinesProvider).contains(DisciplineLayer.hvac),
          isTrue);
      // Switch to edit HVAC → it can't stay a locked reference layer.
      c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
      expect(c.read(lockedDisciplinesProvider).contains(DisciplineLayer.hvac),
          isFalse);
    });

    test('inertServices carries every locked discipline\'s services', () {
      final c = make();
      expect(c.read(inertServicesProvider), isEmpty);
      // Lock plumbing (5 services) while HVAC is active.
      c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
      c.read(lockedDisciplinesProvider.notifier)
          .toggle(DisciplineLayer.plumbing);
      expect(c.read(inertServicesProvider),
          servicesFor(DisciplineLayer.plumbing).toSet());
    });
  });

  group('F4: per-service view filter', () {
    ProviderContainer make() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('default: nothing hidden', () {
      final c = make();
      expect(c.read(hiddenServicesProvider), isEmpty);
    });

    test('toggle hides a single service, then shows it', () {
      final c = make();
      c.read(hiddenServicesProvider.notifier).toggle(ServiceType.drainage);
      expect(c.read(hiddenServicesProvider), {ServiceType.drainage});
      // Cold water on the SAME plumbing layer stays shown.
      expect(c.read(hiddenServicesProvider).contains(ServiceType.coldWater),
          isFalse);
      c.read(hiddenServicesProvider.notifier).toggle(ServiceType.drainage);
      expect(c.read(hiddenServicesProvider), isEmpty);
    });

    test('inertServices unions hidden services with locked-layer services', () {
      final c = make();
      // Hide drainage (plumbing active) and lock HVAC.
      c.read(hiddenServicesProvider.notifier).toggle(ServiceType.drainage);
      c.read(lockedDisciplinesProvider.notifier).toggle(DisciplineLayer.hvac);
      final inert = c.read(inertServicesProvider);
      expect(inert.contains(ServiceType.drainage), isTrue);
      expect(inert.containsAll(servicesFor(DisciplineLayer.hvac)), isTrue);
      // Cold water (visible, unlocked) is NOT inert.
      expect(inert.contains(ServiceType.coldWater), isFalse);
    });
  });
}
