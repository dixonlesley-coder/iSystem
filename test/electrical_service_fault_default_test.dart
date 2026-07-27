/// Task C — the app's Fold-1 fault-level fallback chain now has a MIDDLE tier:
/// explicit [ElectricalProject.originFaultLevelA] wins; else, when a service
/// size is declared (transformer kVA / connection capacity), the engine's
/// [estimatedServiceFaultLevelA] derives a size-appropriate default; else the
/// flat app default (16 kA, [defaultLvUtilityFaultKa]). Container-level
/// (mirrors `electrical_store_test.dart`): reads `electricalResultProvider`
/// through the real providers so the assertion exercises the SAME chain
/// `electricalResultProvider` wires (`lib/store/electrical_store.dart`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/fault.dart'
    show estimatedServiceFaultLevelA;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

/// A project declaring a small (domestic-scale) connection capacity, built off
/// the shared mdp/lp1 sample fixture — 'mdp' is the ROOT panel (no circuit
/// feeds it; it feeds lp1), so its busbar sees the origin fault level
/// undecayed (the compute-tree root case in `computeSystem`).
ElectricalProject _projectWithDeclaredCapacity({Current? originFaultLevelA}) {
  final sample = sampleElectricalProject();
  return ElectricalProject(
    id: sample.id,
    name: sample.name,
    earthingSystem: sample.earthingSystem,
    panels: sample.panels,
    supplyCapacityVa: const ApparentPower(5500),
    originFaultLevelA: originFaultLevelA,
  );
}

void main() {
  group('electrical service-size fault-level default (Task C)', () {
    test(
        'a declared connection capacity with no explicit origin fault level '
        "solves at the estimator's fault level", () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final project = _projectWithDeclaredCapacity();
      c.read(electricalProjectProvider.notifier).setProject(project);

      final expected = estimatedServiceFaultLevelA(project);
      expect(expected, isNotNull,
          reason: 'a declared 5500 VA connection capacity must yield an '
              'estimate, or this fixture cannot discriminate the tiers');

      final withstand =
          c.read(electricalResultProvider).panels['mdp']!.busbar.withstand;
      expect(withstand, isNotNull);
      expect(withstand!.faultKa, expected!.inKiloamperes);
    });

    test('an explicit origin fault level still wins over the estimate', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final explicit = Current.kiloamperes(20);
      final project =
          _projectWithDeclaredCapacity(originFaultLevelA: explicit);
      c.read(electricalProjectProvider.notifier).setProject(project);

      // The estimator would otherwise claim a different (smaller) figure for
      // this fixture — proving the explicit value, not the estimate, won.
      final estimate = estimatedServiceFaultLevelA(project);
      expect(estimate!.inKiloamperes, isNot(20));

      final withstand =
          c.read(electricalResultProvider).panels['mdp']!.busbar.withstand;
      expect(withstand!.faultKa, 20.0);
    });

    test('a project declaring nothing keeps the flat 16 kA default', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final project = sampleElectricalProject();
      expect(project.supplyCapacityVa, isNull);
      expect(project.transformerKva, isNull);
      expect(estimatedServiceFaultLevelA(project), isNull,
          reason: 'a project declaring no service size must yield no '
              'estimate, or this fixture cannot discriminate the tiers');
      c.read(electricalProjectProvider.notifier).setProject(project);

      final withstand =
          c.read(electricalResultProvider).panels['mdp']!.busbar.withstand;
      expect(withstand!.faultKa, 16.0);
    });
  });
}
