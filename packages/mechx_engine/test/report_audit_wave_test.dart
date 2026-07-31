/// Audit-wave report-surface fixes (R1, R5, M16, M8/M19 wording, G5).
///
/// Each group pins BOTH halves of the contract: the new behaviour when the
/// caller opts in, and BYTE-IDENTITY when it does not — the guardrail every
/// additive report change in this repo carries.
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart'
    show serviceFaultEstimateVerifyItems;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart' show cableLabel;
import 'package:mechx_engine/report/report_strings.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'report_test_fixtures.dart';

void main() {
  // ── R1 — the printed deliverable reads the COMBINED warning surface ───────
  group('R1 — ElectricalCalcReportData.allWarnings', () {
    final base = richElecData();

    // Two findings the ADVANCED fault study raises and the core result does
    // not: one carrying a panel id (so it must also reach that panel's own
    // section) and one system-wide.
    const faultFindings = [
      ElectricalWarning(
        code: 'breaking-capacity-inadequate',
        severity: WarningSeverity.error,
        message: 'MDP incomer Icu 10 kA is below the 16 kA prospective fault.',
        panelId: 'MDP',
      ),
      ElectricalWarning(
        code: 'non-selective',
        severity: WarningSeverity.warning,
        message: 'Feeder SP-1 may not discriminate with the SP-1 incomer.',
      ),
    ];

    ElectricalCalcReportData withAll(List<ElectricalWarning>? all) =>
        ElectricalCalcReportData(
          projectName: base.projectName,
          date: base.date,
          standardsName: base.standardsName,
          standardsRevision: base.standardsRevision,
          project: base.project,
          result: base.result,
          powerOneLine: base.powerOneLine,
          verifyItems: base.verifyItems,
          originFaultLevelA: base.originFaultLevelA,
          busbarClearingTimeS: base.busbarClearingTimeS,
          revisions: base.revisions,
          allWarnings: all,
        );

    test('null allWarnings ⇒ byte-identical to the legacy report', () {
      // The same data rebuilt through the NEW constructor with an explicit
      // null — the guarantee that adding the field changed nothing for every
      // existing caller.
      expect(buildElectricalCalcReport(withAll(null)),
          buildElectricalCalcReport(base));
    });

    test('the System warnings section prints the COMBINED list, severity-tagged',
        () {
      final md = buildElectricalCalcReport(
          withAll([...base.result.warnings, ...faultFindings]));
      expect(md, contains('## Warnings'));
      // The error-severity fault finding the issued report used to omit.
      expect(md, contains('_ERROR_: MDP incomer Icu 10 kA'));
      expect(md, contains('_WARN_: Feeder SP-1 may not discriminate'));
      // Every core warning still prints.
      for (final w in base.result.warnings) {
        expect(md, contains(w.message));
      }
    });

    test('a panel section gains the fault findings carrying ITS panel id', () {
      final md = buildElectricalCalcReport(withAll(faultFindings));
      final mdpSection = md.split('### SP-1')[0];
      // The MDP-scoped error appears under MDP, ahead of the next panel.
      expect(mdpSection, contains('MDP incomer Icu 10 kA'));
      // The system-wide finding does NOT get attributed to a panel.
      expect(mdpSection, isNot(contains('Feeder SP-1 may not discriminate')));
    });

    test('a finding already in the panel list is not printed twice', () {
      final mdp = base.result.panels['MDP']!;
      // Re-supply one of the panel's OWN warnings through the combined surface
      // (exactly what the app's deduped provider does).
      final own = mdp.warnings.isNotEmpty
          ? mdp.warnings.first
          : const ElectricalWarning(
              code: 'phase-imbalance',
              severity: WarningSeverity.info,
              message: 'seeded',
              panelId: 'MDP');
      final md = buildElectricalCalcReport(withAll([own]));
      final mdpSection = md.split('### SP-1')[0];
      expect(own.message.allMatches(mdpSection).length, 1,
          reason: 'the panel section must not repeat its own warning');
    });
  });

  // ── R5 — the service-size fault estimate declares its provenance ──────────
  group('R5 — serviceFaultEstimateVerifyItems reaches AdvancedStudy', () {
    const puil = PuilProfile();

    ElectricalProject projectWith({
      ApparentPower? capacity,
      Current? declaredFault,
    }) =>
        ElectricalProject(
          id: 'p',
          name: 'probe',
          supplyCapacityVa: capacity,
          originFaultLevelA: declaredFault,
          panels: const [
            ElectricalPanel(
              id: 'P',
              name: 'P',
              circuits: [
                ElectricalCircuit(
                  id: 'w1',
                  name: 'Lighting',
                  loadKind: LoadKind.lighting,
                  isLighting: true,
                  loadW: 900,
                  length: Length(20),
                ),
              ],
            ),
          ],
        );

    test('nothing declared ⇒ no estimate ⇒ the debt is NOT added', () {
      final p = projectWith();
      final study = computeAdvancedStudy(puil, p, computeSystem(puil, p));
      for (final item in serviceFaultEstimateVerifyItems) {
        expect(study.verifyItems, isNot(contains(item)));
      }
    });

    test('a declared connection capacity ⇒ the estimate governs ⇒ debt added',
        () {
      // 5500 VA ≤ the small-service ceiling ⇒ the 6 kA rung; nothing else was
      // declared, so this estimate really is what the kA tokens are printed on.
      final p = projectWith(capacity: const ApparentPower(5500));
      final study = computeAdvancedStudy(puil, p, computeSystem(puil, p));
      for (final item in serviceFaultEstimateVerifyItems) {
        expect(study.verifyItems, contains(item));
      }
    });

    test('an EXPLICIT origin fault level wins ⇒ the estimate debt is NOT added',
        () {
      final p = projectWith(
          capacity: const ApparentPower(5500),
          declaredFault: const Current(16000));
      final study = computeAdvancedStudy(puil, p, computeSystem(puil, p));
      for (final item in serviceFaultEstimateVerifyItems) {
        expect(study.verifyItems, isNot(contains(item)));
      }
    });

    test('an explicit ARGUMENT also wins over the estimate', () {
      final p = projectWith(capacity: const ApparentPower(5500));
      final study = computeAdvancedStudy(puil, p, computeSystem(puil, p),
          originFaultLevel: const Current(25000));
      for (final item in serviceFaultEstimateVerifyItems) {
        expect(study.verifyItems, isNot(contains(item)));
      }
    });
  });

  // ── M16 — the raised-stack note reaches the run schedule ──────────────────
  group('M16 — stackRaisedForBranch in the run schedule', () {
    RunScheduleRow row({required bool raised, String tag = 'D-R1'}) =>
        RunScheduleRow(
          service: ServiceType.drainage,
          kind: EdgeKind.riser,
          tag: tag,
          sizeLabel: 'DN75',
          fixtureUnits: 12,
          flowLps: 0,
          velocityMs: 0.8,
          lengthM: 3.5,
          stackRaisedForBranch: raised,
        );

    CalcReportData dataWith(List<RunScheduleRow> rows) {
      final d = richMechData();
      return CalcReportData(
        projectName: d.projectName,
        date: d.date,
        standardsName: d.standardsName,
        standardsRevision: d.standardsRevision,
        verifyItems: d.verifyItems,
        building: d.building,
        feedStrategy: d.feedStrategy,
        targetResidual: d.targetResidual,
        pump: d.pump,
        zones: d.zones,
        rainfallMmPerHr: d.rainfallMmPerHr,
        bom: d.bom,
        fittings: d.fittings,
        runSchedule: rows,
        revisions: d.revisions,
      );
    }

    test('no raised row ⇒ no note (byte-identical to the plain schedule)', () {
      expect(buildCalcReportMarkdown(dataWith([row(raised: false)])),
          isNot(contains('Stack raised to match branch')));
    });

    test('a raised row names the stack in a footnote under the schedule', () {
      final md = buildCalcReportMarkdown(
          dataWith([row(raised: false, tag: 'D-F1'), row(raised: true)]));
      expect(md, contains('Stack raised to match branch: D-R1'));
      // The note follows the schedule table, not the other way round.
      expect(md.indexOf('Stack raised to match branch'),
          greaterThan(md.indexOf('Run / riser schedule')));
      // Only the RAISED row is named.
      expect(md, isNot(contains('D-F1, D-R1')));
    });

    test('the note is localized (no English leak in the ID report)', () {
      final id = buildCalcReportMarkdown(
          dataWith([row(raised: true)]), const ReportStrings.id());
      expect(id, isNot(contains('Stack raised to match branch')));
      expect(id, contains('Tegak dinaikkan menyesuaikan cabang: D-R1'));
    });

    test('buildRunSchedule carries the sizer flag through', () {
      // A hand-built one-edge network with a sizing that carries the flag —
      // the schedule row must echo it (it had no consumer at all before).
      const net = Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's', x: 10, y: 0, floorIndex: 1),
        ],
        edges: [
          NetEdge(
              id: 'e1',
              fromId: 'a',
              toId: 'b',
              service: ServiceType.drainage,
              kind: EdgeKind.riser),
        ],
      );
      const sizing = EdgeSizing(
        edgeId: 'e1',
        service: ServiceType.drainage,
        diameter: Diameter(0.075),
        flow: FlowRate(0),
        velocity: Velocity(0.8),
        stackRaisedForBranch: true,
      );
      final rows = buildRunSchedule(
        net: net,
        sizing: const {'e1': sizing},
        edgeLengths: const {'e1': Length(3.0)},
      );
      expect(rows.single.stackRaisedForBranch, isTrue);
    });
  });

  // ── M8 / M19 — honest fire verdicts ───────────────────────────────────────
  group('M8/M19 — fire verdict wording', () {
    test('M19: both fire-pump verdicts name the MOTOR frame, not the curve', () {
      const en = ReportStrings.en();
      const id = ReportStrings.id();
      expect(en(RptStringKey.firePumpVerdictWithin),
          'Motor within standard frame range');
      expect(en(RptStringKey.firePumpVerdictOversized),
          startsWith('Motor above standard frame range'));
      // The old, wrong wording is gone from BOTH locales.
      for (final s in [en, id]) {
        expect(s(RptStringKey.firePumpVerdictWithin),
            isNot(contains('Rating curve')));
        expect(s(RptStringKey.firePumpVerdictOversized),
            isNot(contains('Kurva pompa kebesaran')));
      }
      // …and the report string matches the engine's own ASCII getter, so the
      // printed sheet and the in-app verdict can never diverge.
      final within = checkFirePumpRating(
          ratedFlow: const FlowRate(0.02), ratedHead: const Head(30));
      expect(within.oversized, isFalse);
      expect(within.verdict, en(RptStringKey.firePumpVerdictWithin));
    });

    test('M8: a minimum-pressure-governed remote head prints PASS + the note',
        () {
      // Light hazard: the density/area share alone sits under the 0.5 bar
      // floor, so the demand is re-derived at Q = K·√P_min ⇒ governed.
      final design = designSprinklerSystem(hazard: FireHazardClass.lightHazard);
      final ra = remoteAreaHydraulics(design: design);
      expect(ra.governedByMinimumPressure, isTrue,
          reason: 'fixture precondition: this is the governed branch');

      final d = richMechData();
      final md = buildCalcReportMarkdown(CalcReportData(
        projectName: d.projectName,
        date: d.date,
        standardsName: d.standardsName,
        standardsRevision: d.standardsRevision,
        verifyItems: d.verifyItems,
        building: d.building,
        feedStrategy: d.feedStrategy,
        targetResidual: d.targetResidual,
        sprinkler: design,
        sprinklerRemoteArea: ra,
        rainfallMmPerHr: d.rainfallMmPerHr,
        bom: d.bom,
        fittings: d.fittings,
      ));
      // PASS + the reason, never the old "under-pressure" failure.
      expect(md, contains('Remote head OK - demand governed by head minimum '
          'pressure, not density'));
      expect(md, isNot(contains('Remote head under-pressure')));
    });

    test('M8: an ungoverned remote head still prints the plain OK verdict', () {
      final d = richMechData();
      final ra = d.sprinklerRemoteArea!;
      expect(ra.governedByMinimumPressure, isFalse);
      final md = buildCalcReportMarkdown(d);
      expect(md, contains('**Remote head OK**'));
      expect(md, isNot(contains('governed by head minimum pressure')));
    });
  });

  // ── G5 — the cable label's core count matches the containment basis ───────
  group('G5 — cableLabel core count', () {
    test('no cores supplied ⇒ the legacy drawing convention (3 / 5)', () {
      expect(cableLabel(null, 2.5, false), 'NYY 3x2.5');
      expect(cableLabel(null, 6, true), 'NYY 5x6');
    });

    test('the REAL count wins: 3φ + neutral = 5, 3φ without = 4, 1φ = 3', () {
      expect(cableLabel(null, 50, true, cores: 5), 'NYY 5x50');
      expect(cableLabel(null, 50, true, cores: 4), 'NYY 4x50');
      expect(cableLabel(null, 2.5, false, cores: 3), 'NYY 3x2.5');
    });

    test('a nonsensical count falls back to the convention (never 0 cores)', () {
      expect(cableLabel(null, 6, true, cores: 0), 'NYY 5x6');
    });

    test('a sized 3φ MOTOR way labels 4 cores — the count the study sizes from',
        () {
      const puil = PuilProfile();
      const project = ElectricalProject(
        id: 'p',
        name: 'motor probe',
        panels: [
          ElectricalPanel(
            id: 'P',
            name: 'P',
            system: ElectricalSystem.threePhase,
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                id: 'm1',
                name: 'Chiller',
                loadKind: LoadKind.motor,
                motorKw: 30,
                cableType: 'NYY',
                length: Length(20),
              ),
              // A 3-phase NON-motor way — it keeps its neutral, so it is the
              // 5-core counterpart of the motor above.
              ElectricalCircuit(
                id: 'h1',
                name: 'EV charger',
                loadKind: LoadKind.evCharger,
                loadW: 12000,
                cableType: 'NYY',
                length: Length(20),
              ),
            ],
          ),
        ],
      );
      final sys = computeSystem(puil, project);
      final panel = sys.panels['P']!;
      final motor = panel.circuits.firstWhere((c) => c.circuitId == 'm1');
      final hvac = panel.circuits.firstWhere((c) => c.circuitId == 'h1');
      // Motor-like ⇒ no neutral ⇒ 3L + PE.
      expect(motor.grounding.cores, 4);
      // A non-motor 3-phase way keeps its neutral ⇒ 3L + N + PE.
      expect(hvac.threePhase, isTrue);
      expect(hvac.grounding.cores, 5);
      expect(
          cableLabel(null, motor.cable.csaMm2, true, cores: motor.grounding.cores),
          startsWith('NYY 4x'));
      expect(
          cableLabel(null, hvac.cable.csaMm2, true, cores: hvac.grounding.cores),
          startsWith('NYY 5x'));
    });
  });
}
