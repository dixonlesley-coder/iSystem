/// Unit tests for the F7 transient Riser-workspace UI state
/// ([schematicViewProvider]): default values (must match the widget's old
/// initial state so a default launch is byte-identical), the null-clearing
/// autoFocus setter, and copyWith field independence (a viewport write must not
/// clobber the filter, etc.).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
      expect(s.autoTransform, isNull);
      expect(s.editTransform, isNull);
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

    test('viewport transforms round-trip without clobbering other fields', () {
      final c = makeContainer();
      final ctrl = c.read(schematicViewProvider.notifier);
      const auto = ViewportTransform(scale: 2, offset: Offset(10, 20));
      const edit = ViewportTransform(scale: 0.5, offset: Offset(-5, -5));
      ctrl.setAutoFocus(ServiceType.vent);
      ctrl.setAutoTransform(auto);
      ctrl.setEditTransform(edit);
      final s = c.read(schematicViewProvider);
      expect(s.autoTransform, auto);
      expect(s.editTransform, edit);
      // A viewport write must preserve the filter (copyWith field independence).
      expect(s.autoFocus, ServiceType.vent);
    });
  });
}
