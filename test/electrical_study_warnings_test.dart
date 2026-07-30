/// Tests for `electricalAllWarningsProvider` (`store/electrical_store.dart`) —
/// THE single combined electrical-warnings surface — and its wiring into
/// `designIssuesProvider` (§5b) + the blank-sheet calibration tiering (§3).
///
/// (1) a fault-study-only finding (`non-selective`) reaches
///     `designIssuesProvider` with the stable `electrical:non-selective` kind
///     — before this fix `FaultStudyResult.warnings` had no consumer at all.
/// (2) a warning present in BOTH the core sizing pass and the fault study
///     (same code/panelId/circuitId) is deduped to one, keeping the core
///     (first) occurrence.
/// (3) a blank uncalibrated sheet lands in the info group; an edge-bearing one
///     stays critical.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart' show EarthingSystem;
import 'package:mechx_engine/electrical/fault.dart' show FaultStudyResult;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

void main() {
  group('electricalAllWarningsProvider → designIssuesProvider (§5b)', () {
    test(
        'a fault-study-only finding (non-selective) surfaces as a design '
        'issue with kind electrical:non-selective', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      // A two-panel feeder tree (mirrors the engine's own
      // electrical_fault_test.dart "(a)" fixture): MDP feeds SP, whose only
      // load is a 30 kW motor — SP's incomer naturally sizes to a 63 A MCB.
      // The feeder's breaker is FORCED to the same 63 A via an explicit
      // override — overridden feeders are exempt from the engine's feeder-
      // selectivity floor (compute.dart's second sizing pass, landed
      // concurrently with this fix), which would otherwise bump an
      // auto-sized feeder above 1.6x the child incomer and remove the
      // non-selective pair. The override keeps this test stable regardless
      // of that pass. 63 A < 1.6 x 63 A = 100.8 A ⇒ non-selective.
      const sub = ElectricalPanel(
        id: 'SP',
        name: 'Sub',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'f1',
        circuits: [
          ElectricalCircuit(
            id: 's1',
            name: 'Motor',
            loadKind: LoadKind.motor,
            motorKw: 30,
            cosPhi: 0.85,
            length: Length(10),
          ),
        ],
      );
      const mdp = ElectricalPanel(
        id: 'MDP',
        name: 'Main',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
            id: 'f1',
            name: 'Feeder to SP',
            loadKind: LoadKind.feeder,
            cosPhi: 0.85,
            length: Length(50),
            feedsPanelId: 'SP',
            breakerOverrideA: Current(63),
          ),
        ],
      );
      const project = ElectricalProject(
        id: 'pr',
        name: 'Building',
        panels: [mdp, sub],
        earthingSystem: EarthingSystem.tnS,
      );
      c.read(electricalProjectProvider.notifier).setProject(project);

      // Sanity: the fault study really does raise it, and the core sizing
      // pass does NOT (so this genuinely exercises the previously-unwired
      // fault.warnings, not a duplicate of an existing core warning).
      final advanced = c.read(electricalAdvancedProvider);
      expect(advanced.fault.warnings.map((w) => w.code),
          contains('non-selective'));
      final core = c.read(electricalResultProvider);
      expect(core.warnings.map((w) => w.code), isNot(contains('non-selective')));

      final issues = c.read(designIssuesProvider);
      final issue = issues.firstWhere(
        (i) => i.kind == 'electrical:non-selective',
        orElse: () => fail('expected an electrical:non-selective design issue'),
      );
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.locate?.panelId, 'MDP');
      expect(issue.locate?.circuitId, 'f1');
    });
  });

  group('electricalAllWarningsProvider dedupe', () {
    test(
        'a warning present in both the core pass and the fault study appears '
        'once, keeping the core (first) occurrence', () {
      // A trivial one-panel project just to obtain REAL, fully-populated
      // result/study objects to clone from (avoids hand-building every
      // nested field of ElectricalSystemResult / AdvancedStudy).
      const project = ElectricalProject(
        id: 'p',
        name: 'p',
        panels: [
          ElectricalPanel(
            id: 'X',
            name: 'X',
            system: ElectricalSystem.singlePhase,
            voltage: Voltage(230),
            circuits: [
              ElectricalCircuit(
                id: 'c1',
                name: 'Load',
                loadKind: LoadKind.socket,
                loadW: 1000,
                length: Length(5),
              ),
            ],
          ),
        ],
      );
      const profile = PuilProfile();
      final baseResult = computeSystem(profile, project);
      final baseAdvanced = computeAdvancedStudy(profile, project, baseResult);

      const coreDup = ElectricalWarning(
        code: 'test-duplicate',
        severity: WarningSeverity.warning,
        message: 'core message',
        panelId: 'X',
        circuitId: 'c1',
      );
      const faultDup = ElectricalWarning(
        code: 'test-duplicate',
        severity: WarningSeverity.warning,
        message: 'fault-study message', // must NOT win the dedupe
        panelId: 'X',
        circuitId: 'c1',
      );

      final resultWithDup = ElectricalSystemResult(
        projectId: baseResult.projectId,
        panels: baseResult.panels,
        order: baseResult.order,
        totalDemandW: baseResult.totalDemandW,
        supply: baseResult.supply,
        earthing: baseResult.earthing,
        warnings: [...baseResult.warnings, coreDup],
      );
      final advancedWithDup = AdvancedStudy(
        fault: FaultStudyResult(
          originFaultkA: baseAdvanced.fault.originFaultkA,
          panels: baseAdvanced.fault.panels,
          circuits: baseAdvanced.fault.circuits,
          selectivity: baseAdvanced.fault.selectivity,
          warnings: [...baseAdvanced.fault.warnings, faultDup],
          verifyItems: baseAdvanced.fault.verifyItems,
        ),
        supply: baseAdvanced.supply,
        recommendedDayaVa: baseAdvanced.recommendedDayaVa,
        powerFactor: baseAdvanced.powerFactor,
        controlAssemblies: baseAdvanced.controlAssemblies,
        harmonics: baseAdvanced.harmonics,
        arcFlash: baseAdvanced.arcFlash,
        containment: baseAdvanced.containment,
        enclosure: baseAdvanced.enclosure,
        metering: baseAdvanced.metering,
        spd: baseAdvanced.spd,
        lightning: baseAdvanced.lightning,
        electrode: baseAdvanced.electrode,
        powerOneLine: baseAdvanced.powerOneLine,
        bom: baseAdvanced.bom,
        verifyItems: baseAdvanced.verifyItems,
      );

      final c = ProviderContainer(overrides: [
        electricalResultProvider.overrideWithValue(resultWithDup),
        electricalAdvancedProvider.overrideWithValue(advancedWithDup),
      ]);
      addTearDown(c.dispose);

      final all = c.read(electricalAllWarningsProvider);
      final dups = all.where((w) => w.code == 'test-duplicate').toList();
      expect(dups, hasLength(1));
      // The CORE occurrence wins (kept first).
      expect(dups.single.message, 'core message');
    });
  });

  group('blank-sheet calibration tiering (§3)', () {
    test(
        'a blank uncalibrated sheet lands in the info group; an edge-bearing '
        'one stays critical', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();

      // s1 gets a drawn edge ⇒ edge-bearing ⇒ its calibration issue escalates
      // to CRITICAL. s2/s3 stay blank ⇒ INFO advisories.
      const nodeA = NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const nodeB =
          NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
      const edge = NetEdge(
          id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);
      c.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [nodeA, nodeB], edges: [edge]),
          );

      final issues = c.read(designIssuesProvider);
      final calib =
          issues.where((i) => i.title == 'Sheet not calibrated').toList();

      final s1Issue = calib.firstWhere((i) => i.locate?.sheetId == 's1');
      expect(s1Issue.severity, IssueSeverity.critical);

      final blank = calib.where((i) => i.locate?.sheetId != 's1').toList();
      expect(blank, isNotEmpty);
      expect(blank.every((i) => i.severity == IssueSeverity.info), isTrue);
    });
  });
}
