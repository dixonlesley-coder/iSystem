import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/templates.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/standards/sni.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('the four built-in templates exist with the expected identities', () {
    expect(kBuildingTemplates.map((t) => t.name).toList(), [
      'Residential highrise',
      'Office tower',
      'Hospital',
      'Retail shop',
    ]);
    // Each carries a non-empty floor stack.
    for (final t in kBuildingTemplates) {
      expect(t.floors, isNotEmpty);
    }
  });

  test('applyTemplate sets floors + occupancy + fireHazard + rainfall', () {
    final c = makeContainer();
    // The Office tower template: 8 floors, public occupancy, ordinary-hazard-1,
    // 200 mm/hr design rainfall (see kBuildingTemplates).
    final office =
        kBuildingTemplates.firstWhere((t) => t.name == 'Office tower');

    applyTemplateTo(c.read, office);

    final project = c.read(projectControllerProvider);
    // Floors match the template's stack exactly (count, names, heights).
    expect(project.floors.length, office.floors.length);
    for (var i = 0; i < office.floors.length; i++) {
      expect(project.floors[i].name, office.floors[i].name);
      expect(project.floors[i].height.meters,
          closeTo(office.floors[i].height.meters, 1e-9));
    }
    expect(c.read(occupancyProvider), Occupancy.public);
    expect(c.read(fireHazardProvider), FireHazardClass.ordinaryHazard1);
    expect(c.read(rainfallIntensityProvider), closeTo(200.0, 1e-9));
  });

  test('Hospital template applies assembly + ordinary-hazard-2 + 250 mm/hr', () {
    final c = makeContainer();
    final hospital =
        kBuildingTemplates.firstWhere((t) => t.name == 'Hospital');

    applyTemplateTo(c.read, hospital);

    expect(c.read(projectControllerProvider).floors.length, 5);
    expect(c.read(occupancyProvider), Occupancy.assembly);
    expect(c.read(fireHazardProvider), FireHazardClass.ordinaryHazard2);
    expect(c.read(rainfallIntensityProvider), closeTo(250.0, 1e-9));
  });

  test('setFloors is a single undo step on the project domain', () {
    final c = makeContainer();
    final before = c.read(projectControllerProvider).floors.length; // 3
    final residential =
        kBuildingTemplates.firstWhere((t) => t.name == 'Residential highrise');

    c.read(projectControllerProvider.notifier).setFloors(residential.floors);
    expect(c.read(projectControllerProvider).floors.length,
        residential.floors.length);

    // One project-domain undo reverts the whole floor swap.
    c.read(historyProvider.notifier).undo();
    expect(c.read(projectControllerProvider).floors.length, before);
  });

  test('setFloors ignores an empty list', () {
    final c = makeContainer();
    final before = c.read(projectControllerProvider).floors;
    c.read(projectControllerProvider.notifier).setFloors(const []);
    expect(c.read(projectControllerProvider).floors, same(before));
  });
}
