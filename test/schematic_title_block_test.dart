// Unit tests for the pure `drawingTitleKey` helper that drives the title-block
// DRAWING TITLE on the Auto single-line (Riser SLD) view.
//
// HONESTY contract under test: the title is a DETERMINISTIC, TOTAL mapping over
// the active system filter — every ServiceType plus null resolves to a fixed
// StringKey, never a fabricated/guessed value.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx/ui/strings/app_strings.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  group('drawingTitleKey', () {
    test('null focus -> generic single-line diagram title', () {
      expect(drawingTitleKey(null), StringKey.schematicTitleSingleLine);
    });

    test('each service maps to its riser title', () {
      expect(drawingTitleKey(ServiceType.coldWater),
          StringKey.schematicTitleCleanWaterRiser);
      expect(drawingTitleKey(ServiceType.hotWater),
          StringKey.schematicTitleHotWaterRiser);
      expect(drawingTitleKey(ServiceType.drainage),
          StringKey.schematicTitleDrainageRiser);
      expect(
          drawingTitleKey(ServiceType.vent), StringKey.schematicTitleVentRiser);
      expect(drawingTitleKey(ServiceType.rainwater),
          StringKey.schematicTitleStormRiser);
      // All three air services share the air-duct riser title.
      expect(
          drawingTitleKey(ServiceType.duct), StringKey.schematicTitleAirRiser);
      expect(drawingTitleKey(ServiceType.returnAir),
          StringKey.schematicTitleAirRiser);
      expect(drawingTitleKey(ServiceType.exhaust),
          StringKey.schematicTitleAirRiser);
      // Both fire services share the fire riser title.
      expect(drawingTitleKey(ServiceType.fireSprinkler),
          StringKey.schematicTitleFireRiser);
      expect(drawingTitleKey(ServiceType.fireHydrant),
          StringKey.schematicTitleFireRiser);
    });

    test('every ServiceType resolves to a mapped title StringKey (total)', () {
      const titleKeys = {
        StringKey.schematicTitleCleanWaterRiser,
        StringKey.schematicTitleHotWaterRiser,
        StringKey.schematicTitleDrainageRiser,
        StringKey.schematicTitleVentRiser,
        StringKey.schematicTitleStormRiser,
        StringKey.schematicTitleAirRiser,
        StringKey.schematicTitleFireRiser,
      };
      for (final s in ServiceType.values) {
        expect(titleKeys.contains(drawingTitleKey(s)), isTrue,
            reason: 'no title mapped for $s');
      }
    });
  });
}
