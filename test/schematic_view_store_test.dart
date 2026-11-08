/// Unit tests for the F7 transient Riser-workspace UI state
/// ([schematicViewProvider]): default values (must match the widget's old
/// initial state so a default launch is byte-identical), the null-clearing
/// autoFocus setter, and copyWith field independence (a viewport write must not
/// clobber the filter, etc.).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/schematic_view_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('schematicViewProvider (F7 sticky view state)', () {
    test('defaults are byte-identical to the widget\'s original initial values',
        () {
      final s = makeContainer().read(schematicViewProvider);
      expect(s.mode, SchematicMode.auto);
      expect(s.service, ServiceType.coldWater);
      expect(s.autoFocus, isNull);
      expect(s.inferRisers, isFalse);
      expect(s.showLegend, isFalse);
      expect(s.showTitleBlock, isFalse);
      expect(s.showDetails, isTrue);
      expect(s.showNotes, isTrue);
      expect(s.showHelp, isFalse);
      // R1 — the viewports live in their own providers, null until framed.
      final c = makeContainer();
      expect(c.read(schematicAutoViewportProvider), isNull);
      expect(c.read(schematicEditViewportProvider), isNull);
    });

    test('setAutoFocus picks a service and clears back to null (All)', () {
      final c = makeContainer();
      final ctrl = c.read(schematicViewProvider.notifier);
      ctrl.setAutoFocus(ServiceType.hotWater);
      expect(c.read(schematicViewProvider).autoFocus, ServiceType.hotWater);
      ctrl.setAutoFocus(null);
      expect(c.read(schematicViewProvider).autoFocus, isNull);
    });

    test('mode / service / toggles are held independently', () {
      final c = makeContainer();
      final ctrl = c.read(schematicViewProvider.notifier);
      ctrl.setMode(SchematicMode.edit);
      ctrl.setService(ServiceType.drainage);
      ctrl.setInferRisers(true);
      ctrl.setShowLegend(true);
      ctrl.setShowDetails(false);
      ctrl.toggleHelp();
      final s = c.read(schematicViewProvider);
      expect(s.mode, SchematicMode.edit);
      expect(s.service, ServiceType.drainage);
      expect(s.inferRisers, isTrue);
      expect(s.showLegend, isTrue);
      expect(s.showDetails, isFalse);
      expect(s.showHelp, isTrue);
      // Untouched fields keep their defaults.
      expect(s.showNotes, isTrue);
      expect(s.showTitleBlock, isFalse);
    });

    test('viewport transforms round-trip in their own providers and never '
        'notify the view-state watchers (R1)', () {
      final c = makeContainer();
      final ctrl = c.read(schematicViewProvider.notifier);
      const auto = ViewportTransform(scale: 2, offset: Offset(10, 20));
      const edit = ViewportTransform(scale: 0.5, offset: Offset(-5, -5));
      ctrl.setAutoFocus(ServiceType.vent);
      var viewStateNotifications = 0;
      c.listen(schematicViewProvider, (_, _) => viewStateNotifications++);
      c.read(schematicAutoViewportProvider.notifier).set(auto);
      c.read(schematicEditViewportProvider.notifier).set(edit);
      expect(c.read(schematicAutoViewportProvider), auto);
      expect(c.read(schematicEditViewportProvider), edit);
      // A viewport write leaves the view state (and its watchers) alone.
      expect(viewStateNotifications, 0);
      expect(c.read(schematicViewProvider).autoFocus, ServiceType.vent);
    });

    test('Edit discipline follows the service until picked; picking one '
        'whose services exclude the current service selects its first', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(schematicViewProvider.notifier);
      expect(c.read(schematicViewProvider).editDiscipline, isNull);
      expect(c.read(schematicViewProvider).effectiveEditDiscipline,
          DisciplineLayer.plumbing);

      ctrl.setEditDiscipline(DisciplineLayer.fire);
      var s = c.read(schematicViewProvider);
      expect(s.effectiveEditDiscipline, DisciplineLayer.fire);
      expect(s.service, servicesFor(DisciplineLayer.fire).first);

      // A service already inside the picked discipline is kept.
      ctrl.setService(ServiceType.fireHydrant);
      ctrl.setEditDiscipline(DisciplineLayer.fire);
      expect(c.read(schematicViewProvider).service, ServiceType.fireHydrant);

      // Setting a service from another discipline moves the picker with it.
      ctrl.setService(ServiceType.exhaust);
      s = c.read(schematicViewProvider);
      expect(s.effectiveEditDiscipline, DisciplineLayer.hvac);

      // Electrical has no riser services — ignored.
      ctrl.setEditDiscipline(DisciplineLayer.electrical);
      expect(c.read(schematicViewProvider).effectiveEditDiscipline,
          DisciplineLayer.hvac);
    });
  });
}
