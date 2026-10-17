import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/containment.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// 2026-10 audit, round-2 electrical residuals. Every expected value is
/// hand-derived from first principles in the comments beside it.
void main() {
  const profile = PuilProfile();

  // A 2-run feeder fixture: MDP → feeder → SUB carrying a 320 kW 3φ heater.
  //   Ib = 320 000 / (√3·400·1.0) = 320 000 / 692.82 = 461.9 A
  //   In ≥ 461.9 ⇒ the 500 A rung; Iz ≥ max(500, 1.25·461.9 = 577.4) = 577.4 A
  //   n=1: largest KHA 500 (300 mm²) < 577.4 ✗ ⇒ parallel runs (n = 2).
  ElectricalProject twoRunProject({
    double manualM = 10,
    bool placed = false,
  }) =>
      ElectricalProject(
        id: 'p2',
        name: 'Two-run feeder',
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'Main',
            layoutPos: placed
                ? const LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0)
                : null,
            circuits: [
              ElectricalCircuit(
                id: 'f',
                name: 'Feeder SUB',
                loadKind: LoadKind.feeder,
                cosPhi: 1.0,
                length: Length(manualM),
                feedsPanelId: 'SUB',
              ),
            ],
          ),
          ElectricalPanel(
            id: 'SUB',
            name: 'Sub',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f',
            layoutPos: placed
                // 8000 px × 0.01 m/px = 80 m planar from the MDP.
                ? const LayoutPos(sheetId: 's1', floorIndex: 0, x: 8000, y: 0)
                : null,
            circuits: const [
              ElectricalCircuit(
                id: 'h',
                name: 'Heater',
                loadKind: LoadKind.heating,
                loadW: 320000,
                cosPhi: 1.0,
                phases: 3,
                length: Length(10),
              ),
            ],
          ),
        ],
      );

  group('elec-core residual — grouping table runs past 9 circuits', () {
    // IEC 60364-5-52 Table B.52.17 row 1 (bunched in air / on a surface /
    // enclosed): 1→1.00, 2→0.80, 3→0.70, 4→0.65, 5→0.60, 6→0.57, 7→0.54,
    // 8→0.52, 9→0.50, 12→0.45, 16→0.41, 20→0.38.
    test('the profile table carries every row-1 rung', () {
      expect(profile.groupingFactors, {
        1.0: 1.0, 2.0: 0.8, 3.0: 0.7, 4.0: 0.65, 5.0: 0.6, 6.0: 0.57,
        7.0: 0.54, 8.0: 0.52, 9.0: 0.5, 12.0: 0.45, 16.0: 0.41, 20.0: 0.38,
      });
    });

    test('between rungs the NEXT-HIGHER count is read (conservative)', () {
      expect(groupingFactor(profile, 0), 1.0); // clamped to 1 circuit
      expect(groupingFactor(profile, 9), 0.5);
      expect(groupingFactor(profile, 10), 0.45); // → 12 column
      expect(groupingFactor(profile, 12), 0.45);
      expect(groupingFactor(profile, 13), 0.41); // → 16 column
      expect(groupingFactor(profile, 16), 0.41);
      expect(groupingFactor(profile, 17), 0.38); // → 20 column
      expect(groupingFactor(profile, 20), 0.38);
      expect(groupingFactor(profile, 40), 0.38); // no rung beyond 20
    });

    test('a 6-grouped 2-run feeder derates at gf(12) = 0.45, not 0.50', () {
      // g = 6 ⇒ df = gf(6) = 0.57 already applied. Ib 240 A, In 300 A ⇒
      //   Iz ≥ max(300, 1.25·240 = 300) = 300 A.
      //   n=1: per run ≥ 300 / 0.57 = 526.3 A > 500 (300 mm² KHA) ✗
      //   n=2: the two runs group with the 6 neighbours as 6·2 = 12 circuits:
      //        df_run = 0.57 · gf(12) / gf(6) = 0.57 · 0.45 / 0.57 = 0.45
      //        per run ≥ 300 / 2 / 0.45 = 333.3 A:
      //          150 mm² (KHA 325) ✗, 185 mm² (KHA 370) ✓
      //        Iz = 2 · 370 · 0.45 = 333.0 A ≥ 300 ✓
      // The saturated table read gf(12) as gf(9) = 0.50 ⇒ per run ≥ 300 A ⇒
      // 2×150 mm² "rated" 2·325·0.50 = 325 A — really 2·325·0.45 = 292.5 A,
      // BELOW the 300 A breaker (In > Iz, an unprotected cable).
      final cable = sizeCable(
        profile,
        designCurrent: const Current(240),
        breakerRating: const Current(300),
        deratingFactor: 0.57,
        minSectionMm2: 4,
        threePhase: true,
        groupingCount: 6,
      );
      expect(cable.runsPerPhase, 2);
      expect(cable.deratingFactor, 0.45);
      expect(cable.csaMm2, 185);
      expect(cable.deratedIz.amperes, closeTo(333.0, 0.05));
      expect(cable.deratedIz.amperes, greaterThanOrEqualTo(300));
      expect(2 * 325 * 0.45, lessThan(300)); // the rejected 2×150 really fails
    });
  });

  group('elec-core-2 residual — SPD feeder distance uses the SOLVED run', () {
    const building = BuildingLevels([Floor('Ground', Length(4.0))]);
    const calib = {'s1': ScaleCalibration(0.01)};

    test('a placed 80 m feeder (manual 5 m) is > 10 m from the origin SPD',
        () {
      final placed = twoRunProject(manualM: 5, placed: true);
      final sys = computeSystem(profile, placed,
          calibrationBySheet: calib, building: building);
      final runM = sys.panels['MDP']!.circuits.single.lengthM;
      // 8000 px × 0.01 = 80 m planar (plus any vertical drops).
      expect(runM, greaterThanOrEqualTo(80));
      final adv = computeAdvancedStudy(profile, placed, sys);
      // secondarySpdDistanceM = 10 m: 80 m ⇒ a coordinated Type 2 IS
      // recommended. The defect summed the manual 5 m ⇒ "not recommended".
      expect(adv.spd['SUB']!.recommended, isTrue);

      // Identical to the same run typed as the manual length.
      final manual = twoRunProject(manualM: runM);
      final advManual =
          computeAdvancedStudy(profile, manual, computeSystem(profile, manual));
      expect(adv.spd['SUB']!.note, advManual.spd['SUB']!.note);

      // And the stale manual 5 m reading would NOT have recommended one.
      final stale = twoRunProject(manualM: 5);
      final advStale =
          computeAdvancedStudy(profile, stale, computeSystem(profile, stale));
      expect(advStale.spd['SUB']!.recommended, isFalse);
    });
  });

  group('elec-advanced-7 residual — conduits count per parallel run', () {
    test('a 2-run feeder takes two conduits, one cable each', () {
      final project = twoRunProject();
      final sys = computeSystem(profile, project);
      final feeder = sys.panels['MDP']!.circuits.single;
      expect(feeder.cable.runsPerPhase, 2); // precondition (see fixture)

      final containment = containmentFor(sys.panels['MDP']!);
      final entry = containment.conduits.single;
      expect(entry.circuitId, 'f');
      expect(entry.count, 2);
      // Each conduit is sized for ONE run's cable (single-cable fill basis).
      final one = sizeConduit(feeder.cable.csaMm2, feeder.grounding.cores);
      expect(entry.conduit.conduitSizeMm, one.conduitSizeMm);
      expect(entry.conduit.fillPct, one.fillPct);
      expect(containment.totalConduitCount, 2);
      // The tray already laid both cables.
      expect(containment.tray.cableCount, 2);
    });

    test('the schedule token states the conduit COUNT for a 2-run way', () {
      final project = twoRunProject();
      final sys = computeSystem(profile, project);
      // A study spec that fits (≤ 53 % fill) for this run ⇒ a conduit route.
      const spec = ConduitSpec(cableOdMm: 40, conduitSizeMm: 63, fillPct: 50);
      final sheet = buildElectricalPanelDetail(
        project: project,
        result: sys,
        panelId: 'MDP',
        containmentByCircuitId: const {'f': spec},
      );
      final cells = sheet.prims
          .whereType<SldLabel>()
          .map((l) => l.text)
          .where((t) => t.contains(' mm2') && t.contains(' · '));
      expect(cells.any((t) => t.contains(' · 2x PVC 63mm')), isTrue);
    });
  });

  group('elec-advanced-6 residual — exact PV string layout', () {
    test('19 modules → strings of 10 + 9 (never 2 × 10 = 20)', () {
      // maxLen = min(floor(MPPT Vmax / Vmp), floor(Vsys / (Voc·1.15))) ⇒ the
      // existing suite pins 17 for these defaults; strings = ceil(19/17) = 2,
      // shortest = 19 ~/ 2 = 9, remainder = 19 − 9·2 = 1 ⇒ one string of 10
      // and one of 9.
      final s = sizeSolar(panelWp: 550, panels: 19);
      expect(s.strings, 2);
      expect(s.stringSize, 10);
      expect(s.stringLengths, [10, 9]);
      expect(s.stringLengths.fold<int>(0, (a, b) => a + b), 19);
      expect(s.stringsLong, 1);
      expect(s.stringsShort, 1);
      expect(s.note, contains('9-10'));
    });

    test('an even split lists equal strings', () {
      // 20 modules: strings = 2, 20 / 2 = 10 each, remainder 0.
      final s = sizeSolar(panelWp: 550, panels: 20);
      expect(s.stringLengths, [10, 10]);
      expect(s.stringsLong, 2);
      expect(s.stringsShort, 0);
    });
  });
}
