// Backlog E-1 (2026-11-13) — several separately metered service entrances
// (shophouse backlog a). One explicit, persisted `serviceEntrance` flag per
// un-fed board decides BOTH the connectivity judge (`unfed-panel`) and the
// supply study's service roots (`originPanelIdsOf`, the multi-root daya
// judge, the per-line allocation), so a project is never judged two ways.
//
// Fixture: the ORIGINAL three-meter shophouse — the three unit boards of
// `reference/shophouse.dart` (1-phase 220 V, eight ways each) as three un-fed
// boards, a declared 23 100 VA PLN connection (3 x 7 700 VA meters).
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/connectivity.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/shophouse.dart';

ElectricalProject _threeMeters({required List<bool?> flags}) {
  final units = [
    for (final p in buildShophouseElectrical().panels)
      if (p.id != kShopMainPanelId) p,
  ];
  return ElectricalProject(
    id: 'three_meters',
    name: 'Ruko 3 meter',
    supplyKind: SupplyKind.pln,
    supplyCapacityVa: const ApparentPower(23100),
    panels: [
      for (var i = 0; i < units.length; i++)
        units[i].copyWith(
          sourceType: PanelSource.utility,
          clearFedByCircuitId: true,
          serviceEntrance: flags[i],
          clearServiceEntrance: flags[i] == null,
        ),
    ],
  );
}

void main() {
  const profile = PuilProfile();
  final ids = [for (final u in kShopUnits) shopPanelId(u)];

  group('serviceEntrancePanelIds (the one root set)', () {
    test('unset flags: the first un-fed board only (the pre-E-1 judge)', () {
      final p = _threeMeters(flags: [null, null, null]);
      expect(serviceEntrancePanelIds(p), {ids[0]});
      expect([for (final d in electricalConnectivityDefects(p)) d.panelId],
          [ids[1], ids[2]]);
    });

    test('a board flagged false is never a root; none left => the first', () {
      final p = _threeMeters(flags: [false, true, null]);
      expect(serviceEntrancePanelIds(p), {ids[1]});
      final none = _threeMeters(flags: [false, false, false]);
      expect(serviceEntrancePanelIds(none), {ids[0]});
    });

    test('the flag round-trips additively and is tolerant', () {
      final b = _threeMeters(flags: [true, false, null]).panels;
      for (final p in b) {
        final back = ElectricalPanel.fromJson(p.toJson());
        expect(back.serviceEntrance, p.serviceEntrance);
      }
      expect(b[2].toJson().containsKey('serviceEntrance'), isFalse);
      expect(
          ElectricalPanel.fromJson({'id': 'x', 'serviceEntrance': 'yes'})
              .serviceEntrance,
          isNull);
    });
  });

  group('three meters, all flagged', () {
    final project = _threeMeters(flags: [true, true, true]);
    final sys = computeSystem(profile, project);
    final adv = computeAdvancedStudy(profile, project, sys);

    test('no unfed-panel; every board is a service root', () {
      expect(electricalConnectivityDefects(project), isEmpty);
      expect(originPanelIdsOf(sys, project), ids.toSet());
    });

    test('per-line basis sqrt3 x 400 x 24.2 = 16 766 VA each; daya 23 000 '
        'VA 3-phase; no capacity warning', () {
      for (final id in ids) {
        // 5 329.4 VA / 220 V = 24.22 A -> 24.2 (rounded as the judge
        // rounds); sqrt3 x 400 x 24.2 = 16 766.1 VA on its own line.
        expect(rootServiceBasisVa(project, sys, id),
            closeTo(1.7320508 * 400 * 24.2, 0.5));
      }
      // One board per line (LPT): 3 x the heaviest line = 16 766 VA.
      final studied = studySupplyInputs(project, sys);
      expect(studied.perPhaseBasisVa, closeTo(16766.1, 0.5));
      // The 1-phase ladder tops at 13 900 < 16 766 => the 3-phase step
      // >= 16 766 is 23 000 VA.
      expect(adv.recommendedDayaVa, 23000);
      expect(adv.recommendedDayaThreePhase, isTrue);
      // Declared 23 100 VA 3-phase: 23 100 / (sqrt3 x 400) = 33.3 A per
      // line >= 24.2 => no warning.
      final all = [...sys.warnings, ...adv.warnings];
      expect(all.where((w) => w.code == 'service-capacity-below-demand'),
          isEmpty);
      // Supply demand: 3 x 5 329.4 = 15 988 VA.
      expect(sys.supply.demandVa.voltAmperes, closeTo(15988, 1));
    });
  });

  group('three meters, only the first flagged', () {
    final project = _threeMeters(flags: [true, null, null]);
    final sys = computeSystem(profile, project);
    final adv = computeAdvancedStudy(profile, project, sys);

    test('B and C are unfed-panel and outside the study', () {
      expect([for (final d in electricalConnectivityDefects(project)) d.panelId],
          [ids[1], ids[2]]);
      expect(originPanelIdsOf(sys, project), {ids[0]});
      // The study covers board A alone: demand 5 329.4 VA, connected
      // 3 x 200 + 3 x 1000 + 2 x 1100 = 5 800 W (B / C not on the service).
      expect(sys.supply.demandVa.voltAmperes, closeTo(5329, 1));
      expect(sys.supply.connectedW, closeTo(5800, 0.5));
      // The boards themselves are still sized (each is a board).
      for (final id in ids) {
        expect(sys.panels[id], isNotNull);
      }
    });

    test("board A's own daya: max(5 329.4, 24.2 x 220 = 5 324) = 5 329 VA "
        '-> the first 1-phase step >= 5 329 is 5 500 VA', () {
      expect(adv.recommendedDayaVa, 5500);
      expect(adv.recommendedDayaThreePhase, isFalse);
      // The declared 23 100 VA now sits on ONE 1-phase root (single-root
      // rules): above the 13 900 VA 1-phase ladder it is a 3-phase service
      // the board loads one line of — the existing Round-38 warning.
      final codes = {for (final w in sys.warnings) w.code};
      expect(codes, contains('service-single-phase-root-on-three-phase-daya'));
    });
  });
}
