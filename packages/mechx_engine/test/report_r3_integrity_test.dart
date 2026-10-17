// R3 report-integrity fixes — what the ISSUED electrical documents print must
// agree with the engine's own solve and with each other:
//   reports-2  the PENGHANTAR cell states PE once (core count incl. PE, no
//              separate `+ NYA/BC` earth conductor on top);
//   reports-3  the schedule `VD!` honours the CUMULATIVE drop the engine warns on;
//   reports-5  the calc report never prints a trip-curve letter on an MCCB.
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// MDP (3ph 400 V) → long 1ph feeder → LP-1 (1ph 220 V) with one lighting way.
/// The feeder is long enough to drop ~1-2 % and the lighting run ~2 %, so the
/// way is inside the 3 % lighting limit on its OWN drop but over it
/// CUMULATIVELY — exactly the case the schedule used to call fine.
ElectricalProject _twoLevel({double feederM = 60, double lightingM = 30}) =>
    ElectricalProject(
      id: 'p-vd',
      name: 'Cumulative VD',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'f-lp1',
              name: 'Feeder to LP-1',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'LP1',
              length: Length(feederM),
            ),
            const ElectricalCircuit(
              id: 'm-1',
              name: 'Chiller',
              loadKind: LoadKind.motor,
              motorKw: 55,
              cableType: 'NYY',
              length: Length(25),
            ),
          ],
        ),
        ElectricalPanel(
          id: 'LP1',
          name: 'LP-1',
          system: ElectricalSystem.singlePhase,
          voltage: const Voltage(220),
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f-lp1',
          circuits: [
            ElectricalCircuit(
              id: 'lp1-l1',
              name: 'Lighting L.2',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 1500,
              cableType: 'NYM',
              length: Length(lightingM),
            ),
          ],
        ),
      ],
    );

String _rowText(ElectricalProject project, String panelId) {
  final result = computeSystem(const PuilProfile(), project);
  final sheet = buildElectricalPanelDetail(
      project: project, result: result, panelId: panelId);
  return sheet.prims.whereType<SldLabel>().map((l) => l.text).join(' | ');
}

void main() {
  group('reports-3 — schedule VD! honours the cumulative drop', () {
    test('own drop within limit but cumulative over ⇒ VD! on the row', () {
      final project = _twoLevel();
      final result = computeSystem(const PuilProfile(), project);
      final lp1 = result.panels['LP1']!;
      final way = lp1.circuits.single;
      final feeder = result.panels['MDP']!.circuits
          .firstWhere((c) => c.circuitId == 'f-lp1');

      // First principles: cumulative = upstream feeder drop + the way's own
      // drop (the root board's origin drop is 0).
      expect(way.cumulativeDropPercent,
          closeTo(feeder.voltageDrop.dropPercent + way.voltageDrop.dropPercent,
              0.011));
      // Preconditions of the scenario (computed, not assumed).
      expect(way.voltageDrop.withinLimit, isTrue,
          reason: 'own drop ${way.voltageDrop.dropPercent}% must be inside '
              'the ${way.voltageDrop.limitPercent}% limit');
      expect(way.cumulativeDropPercent,
          greaterThan(way.voltageDrop.limitPercent));
      // The engine warns on it…
      expect(
          result.warnings.any((w) =>
              w.code == 'cumulative-voltage-drop-exceeded' &&
              w.circuitId == 'lp1-l1'),
          isTrue);
      // …so the shared gate and the issued schedule must say so too.
      expect(voltageDropOverLimit(way, isFeeder: false), isTrue);
      expect(_rowText(project, 'LP1'), contains('Lighting L.2  VD!'));
    });

    test('a short feed stays clean (no VD!)', () {
      final project = _twoLevel(feederM: 5, lightingM: 5);
      final result = computeSystem(const PuilProfile(), project);
      final way = result.panels['LP1']!.circuits.single;
      expect(way.cumulativeDropPercent,
          lessThanOrEqualTo(way.voltageDrop.limitPercent));
      expect(_rowText(project, 'LP1'), isNot(contains('VD!')));
    });

    test('a feeder is judged on its own drop only', () {
      final project = _twoLevel();
      final result = computeSystem(const PuilProfile(), project);
      final feeder = result.panels['MDP']!.circuits
          .firstWhere((c) => c.circuitId == 'f-lp1');
      expect(voltageDropOverLimit(feeder, isFeeder: true),
          !feeder.voltageDrop.withinLimit);
    });

    test('the calc report Vdrop verdict uses the same gate', () {
      final project = _twoLevel();
      final result = computeSystem(const PuilProfile(), project);
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
        projectName: 'p',
        date: '2026-10-17',
        standardsName: 'PUIL',
        standardsRevision: '2011',
        project: project,
        result: result,
      ));
      final row = md
          .split('\n')
          .firstWhere((l) => l.startsWith('| Lighting L.2 |'));
      expect(row, contains('OVER'));
    });
  });

  group('reports-2 — PE is stated once in PENGHANTAR', () {
    test('the PE-inclusive core count carries no extra + NYA / + BC earth', () {
      final project = _twoLevel();
      final result = computeSystem(const PuilProfile(), project);
      final text = _rowText(project, 'MDP');
      expect(text, isNot(contains('+ NYA')));
      expect(text, isNot(contains('+ BC')));
      // The 3ph motor way: 3 L + PE = 4 cores (no neutral), PE INSIDE.
      final motor = result.panels['MDP']!.circuits
          .firstWhere((c) => c.circuitId == 'm-1');
      expect(motor.grounding.cores, 4);
      expect(text, contains('NYY 4x${motor.cable.csaMm2.round()} mm2 · '));
      // BC only reaches the legend if a way actually uses a BC conductor.
      expect(text, isNot(contains('Bare copper')));
    });
  });

  group('reports-5 — no trip curve on an MCCB in the calc report', () {
    test('MCCB rows print the class only; MCB rows keep the curve', () {
      final project = _twoLevel();
      final result = computeSystem(const PuilProfile(), project);
      final motor = result.panels['MDP']!.circuits
          .firstWhere((c) => c.circuitId == 'm-1');
      final lighting = result.panels['LP1']!.circuits.single;
      expect(motor.breaker.deviceClass, BreakerClass.mccb);
      expect(lighting.breaker.deviceClass, BreakerClass.mcb);
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
        projectName: 'p',
        date: '2026-10-17',
        standardsName: 'PUIL',
        standardsRevision: '2011',
        project: project,
        result: result,
      ));
      expect(md, isNot(contains('MCCB/')));
      final motorRow =
          md.split('\n').firstWhere((l) => l.startsWith('| Chiller |'));
      expect(motorRow,
          contains('${motor.breaker.ratingA.amperes.round()} A MCCB |'));
      final lightRow =
          md.split('\n').firstWhere((l) => l.startsWith('| Lighting L.2 |'));
      expect(lightRow, contains('A MCB/'));
    });
  });
}
