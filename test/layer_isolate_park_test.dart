import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/network/network.dart';

/// J5 — the per-service isolate belongs to the layer whose funnel raised it, so
/// it must PARK when that layer stops being active (the funnel only renders for
/// the active layer; a filter that keeps applying while its control is
/// off-screen is invisible state) and auto-restore on return.
///
/// E3 — flipping the discipline layer must not silently reset the draw service:
/// each mechanical layer remembers the service it was last drawing with.
void main() {
  ProviderContainer make() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('J5: the isolate parks with its layer', () {
    test('a plumbing isolate stops filtering while HVAC is active, and comes '
        'back on return', () {
      final c = make();
      final hide = c.read(hiddenServicesProvider.notifier);
      final active = c.read(activeDisciplineProvider.notifier);

      // Isolate cold water on Plumbing (hide drainage + vent).
      hide.toggle(ServiceType.drainage);
      hide.toggle(ServiceType.vent);
      expect(c.read(hiddenServicesProvider),
          {ServiceType.drainage, ServiceType.vent});

      // Switch to HVAC: the plumbing isolate must stop applying…
      active.set(DisciplineLayer.hvac);
      expect(c.read(hiddenServicesProvider), isEmpty);
      expect(c.read(inertServicesProvider), isEmpty);
      // …but it is PARKED, not lost.
      expect(hide.parkedFor(DisciplineLayer.plumbing),
          {ServiceType.drainage, ServiceType.vent});

      // Back to Plumbing: the drafter's isolate returns exactly as it was.
      active.set(DisciplineLayer.plumbing);
      expect(c.read(hiddenServicesProvider),
          {ServiceType.drainage, ServiceType.vent});
      expect(hide.parkedFor(DisciplineLayer.plumbing), isEmpty);
    });

    test('each layer keeps its OWN isolate across a round trip', () {
      final c = make();
      final hide = c.read(hiddenServicesProvider.notifier);
      final active = c.read(activeDisciplineProvider.notifier);

      hide.toggle(ServiceType.rainwater); // plumbing isolate
      active.set(DisciplineLayer.hvac);
      hide.toggle(ServiceType.exhaust); // hvac isolate
      expect(c.read(hiddenServicesProvider), {ServiceType.exhaust});

      active.set(DisciplineLayer.plumbing);
      expect(c.read(hiddenServicesProvider), {ServiceType.rainwater});
      active.set(DisciplineLayer.hvac);
      expect(c.read(hiddenServicesProvider), {ServiceType.exhaust});
    });

    test('switching to ELECTRICAL (which has no services) still parks', () {
      final c = make();
      final hide = c.read(hiddenServicesProvider.notifier);
      hide.toggle(ServiceType.hotWater);
      c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.electrical);
      expect(c.read(hiddenServicesProvider), isEmpty);
      c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.plumbing);
      expect(c.read(hiddenServicesProvider), {ServiceType.hotWater});
    });

    test('nothing hidden => a layer switch is a no-op on the filter', () {
      final c = make();
      c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.fire);
      expect(c.read(hiddenServicesProvider), isEmpty);
      expect(
          c.read(hiddenServicesProvider.notifier)
              .parkedFor(DisciplineLayer.plumbing),
          isEmpty);
    });
  });

  group('E3: the draw service is remembered per layer', () {
    test('a layer round trip restores the service instead of resetting it', () {
      final c = make();
      final net = c.read(networkControllerProvider.notifier);
      final active = c.read(activeDisciplineProvider.notifier);

      // Draw exhaust air on HVAC…
      active.set(DisciplineLayer.hvac);
      net.setService(ServiceType.exhaust);
      // …take a trip through Plumbing (which picks its own remembered service)…
      active.set(DisciplineLayer.plumbing);
      expect(c.read(networkControllerProvider).service,
          servicesFor(DisciplineLayer.plumbing).first);
      // …and back: Exhaust, not Supply.
      active.set(DisciplineLayer.hvac);
      expect(c.read(networkControllerProvider).service, ServiceType.exhaust);
    });

    test('plumbing remembers its own service too (drainage stays drainage)',
        () {
      final c = make();
      final net = c.read(networkControllerProvider.notifier);
      final active = c.read(activeDisciplineProvider.notifier);
      net.setService(ServiceType.drainage);
      active.set(DisciplineLayer.fire);
      expect(c.read(networkControllerProvider).service,
          servicesFor(DisciplineLayer.fire).first);
      active.set(DisciplineLayer.plumbing);
      expect(c.read(networkControllerProvider).service, ServiceType.drainage);
    });

    test('an unvisited layer starts at its FIRST service (unchanged default)',
        () {
      final c = make();
      expect(
          c.read(activeDisciplineProvider.notifier)
              .rememberedService(DisciplineLayer.hvac),
          servicesFor(DisciplineLayer.hvac).first);
      // Electrical carries no ServiceType, so it never drives the draw service.
      expect(
          c.read(activeDisciplineProvider.notifier)
              .rememberedService(DisciplineLayer.electrical),
          isNull);
    });

    test('switching to ELECTRICAL leaves the mechanical draw service alone', () {
      final c = make();
      c.read(networkControllerProvider.notifier).setService(ServiceType.vent);
      c.read(activeDisciplineProvider.notifier).set(DisciplineLayer.electrical);
      expect(c.read(networkControllerProvider).service, ServiceType.vent);
    });
  });
}
