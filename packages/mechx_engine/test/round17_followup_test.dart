// Round 17 follow-up — the engine half of the 2026-10-18 follow-up audit.
//
//   gravity-3-1  a hand-picked drain / vent / downpipe size BELOW the code
//                minimum is flagged (EdgeSizing.belowCodeMinimum)
//   gravity-3-2  the DFU tables continue past DN150 (IPC 710.1(2) rows)
//   gravity-3-3  roof / floor drains sit ON their surface, not at tap height
//   gravity-3-5  a drainage STACK prints no Manning velocity in the schedule
//   gravity-3-6  the calc report states the drainage design slope
//   i18n-essential-name   the ID spellings mark a board essential
//   i18n-oneline          the ID report localizes the power one-line labels
//
// Every expected value is derived in the comments from the tables / the
// building geometry, never read back from the code under test.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/report_strings.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'report_test_fixtures.dart';

// The nominal drain series the DFU tables select from (drainage_sizing).
const _series = [40.0, 50.0, 65.0, 75.0, 100.0, 125.0, 150.0, 200.0, 250.0, 300.0];

Network _one(ServiceType s, EdgeKind k) => Network(
      nodes: const [
        NetNode(id: 'r', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(
            id: 'd',
            sheetId: 's1',
            x: 0,
            y: 0,
            floorIndex: 1,
            role: NodeRole.fixture),
      ],
      edges: [NetEdge(id: 'e', fromId: 'r', toId: 'd', service: s, kind: k)],
    );

EdgeSizing _sanitary(EdgeKind k, double dfu,
        {Diameter? override, Set<String> wc = const {}}) =>
    autoSizeNetwork(
      _one(ServiceType.drainage, k),
      const SizingContext(),
      leafDemand: const {ServiceType.drainage: FlowRate(0)},
      nodeDrainageUnits: {'d': dfu},
      waterClosetNodeIds: wc,
      sizeOverrides: override == null ? const {} : {'e': override},
    )['e']!;

EdgeSizing _storm(double lps, {Diameter? override}) => autoSizeNetwork(
      _one(ServiceType.rainwater, EdgeKind.riser),
      const SizingContext(),
      leafDemand: const {ServiceType.rainwater: FlowRate(0)},
      nodeFlowDemand: {'d': FlowRate.litersPerSecond(lps)},
      sizeOverrides: override == null ? const {} : {'e': override},
    )['e']!;

void main() {
  // ── gravity-3-1 ───────────────────────────────────────────────────────────
  group('gravity-3-1 · a hand pick below the code minimum is flagged', () {
    test('128 DFU stack: DN100 by table (42 < 128 ≤ 240); DN75 is flagged', () {
      final auto = _sanitary(EdgeKind.riser, 128);
      expect(auto.diameter.inMillimeters, closeTo(100, 1e-9));
      expect(auto.belowCodeMinimum, isFalse);
      final small = _sanitary(EdgeKind.riser, 128, override: Diameter.mm(75));
      expect(small.belowCodeMinimum, isTrue);
      // AT or ABOVE the minimum is a legitimate hand pick.
      expect(_sanitary(EdgeKind.riser, 128, override: Diameter.mm(100))
          .belowCodeMinimum, isFalse);
      expect(_sanitary(EdgeKind.riser, 128, override: Diameter.mm(125))
          .belowCodeMinimum, isFalse);
    });

    test('a WC branch (DN75 closet floor) overridden to DN50 is flagged', () {
      // 4 DFU alone is the DN65 branch row (3 < 4 ≤ 6); the WC floors it at
      // DN75 (kMinWcDrainMm), so DN50 is below the code minimum.
      final auto = _sanitary(EdgeKind.run, 4, wc: {'d'});
      expect(auto.diameter.inMillimeters, closeTo(drain.kMinWcDrainMm, 1e-9));
      expect(
          _sanitary(EdgeKind.run, 4, wc: {'d'}, override: Diameter.mm(50))
              .belowCodeMinimum,
          isTrue);
    });

    test('a 10 L/s downpipe (DN100 rated 10.5 L/s) overridden to DN65 (3.4)',
        () {
      final auto = _storm(10);
      expect(auto.diameter.inMillimeters, closeTo(100, 1e-9));
      expect(_storm(10, override: Diameter.mm(65)).belowCodeMinimum, isTrue);
      expect(_storm(10, override: Diameter.mm(100)).belowCodeMinimum, isFalse);
      expect(_storm(10, override: Diameter.mm(150)).belowCodeMinimum, isFalse);
    });

    // Seeded property: for any DFU load, the next-smaller series size than the
    // auto pick is flagged, and the auto pick and every larger size are not.
    test('property: next-smaller flagged, auto and larger never (seed 1718)',
        () {
      final rng = math.Random(1718);
      for (var i = 0; i < 60; i++) {
        final k = rng.nextBool() ? EdgeKind.riser : EdgeKind.run;
        final dfu = 1 + rng.nextDouble() * 5000;
        final auto = _sanitary(k, dfu);
        final idx = _series.indexOf(auto.diameter.inMillimeters);
        expect(idx, greaterThanOrEqualTo(0), reason: 'auto on the series');
        if (idx > 0) {
          expect(
              _sanitary(k, dfu, override: Diameter.mm(_series[idx - 1]))
                  .belowCodeMinimum,
              isTrue,
              reason: '$k $dfu DFU');
        }
        for (final mm in _series.skip(idx)) {
          expect(_sanitary(k, dfu, override: Diameter.mm(mm)).belowCodeMinimum,
              isFalse,
              reason: '$k $dfu DFU @ DN$mm');
        }
      }
    });
  });

  // ── gravity-3-2 ───────────────────────────────────────────────────────────
  group('gravity-3-2 · the DFU tables continue past DN150', () {
    test('12-storey office building drain: 12 × 70 = 840 DFU → DN200', () {
      // 6 WC × 8 + 4 lav × 4 + 6 × 1 = 70 DFU / floor (the probe), × 12.
      final bd = _sanitary(EdgeKind.run, 12 * 70.0);
      // 620 < 840 ≤ 1400 ⇒ the DN200 branch row, NOT a DN150 clamp.
      expect(bd.diameter.inMillimeters, closeTo(200, 1e-9));
      expect(bd.overCapacity, isFalse);
      // The stack carrying the same load is still DN150 (840 ≤ 960).
      expect(_sanitary(EdgeKind.riser, 840).diameter.inMillimeters,
          closeTo(150, 1e-9));
    });

    test('property: diameter monotone in DFU, clamp only past the top rows',
        () {
      for (final stack in [true, false]) {
        var prev = 0.0;
        for (var dfu = 1.0; dfu <= 7000; dfu += 7) {
          final mm = drain.drainDiameterForDfu(dfu, isStack: stack).inMillimeters;
          expect(mm, greaterThanOrEqualTo(prev));
          prev = mm;
          final top = stack ? 6000 : 3900;
          expect(drain.drainDfuExceedsTable(dfu, isStack: stack), dfu > top);
        }
      }
    });
  });

  // ── gravity-3-3 ───────────────────────────────────────────────────────────
  group('gravity-3-3 · drains sit on their surface', () {
    // 3 levels × 3.5 m: floors at 0 / 3.5 / 7.0, roof 10.5; ceiling drop 0.3.
    const building = BuildingLevels([
      Floor('L0', Length(3.5)),
      Floor('L1', Length(3.5)),
      Floor('L2', Length(3.5)),
    ]);
    NetNode n(String id, int floor, NodeComponent? c,
            {NodeRole role = NodeRole.fixture}) =>
        NetNode(
            id: id,
            sheetId: 's$floor',
            x: 0,
            y: 0,
            floorIndex: floor,
            role: role,
            component: c);

    test('roof drain on the top storey is at the roof; floor drain on its slab',
        () {
      expect(nodeElevation(n('rd', 2, NodeComponent.roofDrain), building).meters,
          closeTo(10.5, 1e-9));
      expect(nodeElevation(n('fd', 1, NodeComponent.floorDrain), building).meters,
          closeTo(3.5, 1e-9));
      expect(nodeElevation(n('co', 0, NodeComponent.cleanout), building).meters,
          closeTo(0.0, 1e-9));
      // A roof drain BELOW the top storey (a terrace) sits on that floor.
      expect(nodeElevation(n('rt', 1, NodeComponent.roofDrain), building).meters,
          closeTo(3.5, 1e-9));
      // A tap still sits at the 1.1 m fixture height (unchanged).
      expect(nodeElevation(n('wc', 1, NodeComponent.waterOutlet), building).meters,
          closeTo(3.5 + 1.1, 1e-9));
    });

    test('downpipe from the roof drain to the L1 stack junction is 7.3 m',
        () {
      final net = Network(nodes: [
        n('rd', 2, NodeComponent.roofDrain),
        n('m1', 1, null, role: NodeRole.main),
      ], edges: const [
        NetEdge(
            id: 'dp',
            fromId: 'rd',
            toId: 'm1',
            service: ServiceType.rainwater,
            kind: EdgeKind.riser),
      ]);
      // Round 21 (riser-drafting-2-6) — a bare GRAVITY stack junction sits
      // where its floor's branch joins: UNDER the L1 slab, in L0's ceiling
      // space = 3.5 − 0.3 = 3.2 m (it used to read L1's own ceiling, 6.7 m).
      // roof 10.5 − 3.2 = 7.3 m: the downpipe through L2 and L1.
      final len = edgeLength(net.edges.single, net,
          calibrationBySheet: const {}, building: building);
      expect(len.meters, closeTo(7.3, 1e-9));
    });
  });

  // ── gravity-3-5 ───────────────────────────────────────────────────────────
  test('gravity-3-5 · a drainage stack prints the velocity dash', () {
    final net = _one(ServiceType.drainage, EdgeKind.riser);
    final sizing = {'e': _sanitary(EdgeKind.riser, 128)};
    // The engine still records the Manning figure on the sizing …
    expect(sizing['e']!.velocity.metersPerSecond, greaterThan(0));
    final rows = buildRunSchedule(
        net: net, sizing: sizing, edgeLengths: const {'e': Length(3.5)});
    // … but the schedule states none for a vertical stack (renders '—').
    expect(rows.single.velocityMs, 0.0);
    // A drainage RUN keeps its Manning velocity.
    final runNet = _one(ServiceType.drainage, EdgeKind.run);
    final runRows = buildRunSchedule(
        net: runNet,
        sizing: {'e': _sanitary(EdgeKind.run, 128)},
        edgeLengths: const {'e': Length(3.5)});
    expect(runRows.single.velocityMs, greaterThan(0));
  });

  // ── gravity-3-6 ───────────────────────────────────────────────────────────
  group('gravity-3-6 · the report states the drainage slope', () {
    CalcReportData withSlope(double? slope) {
      final b = richMechData();
      return CalcReportData(
        projectName: b.projectName,
        date: b.date,
        standardsName: b.standardsName,
        standardsRevision: b.standardsRevision,
        verifyItems: b.verifyItems,
        building: b.building,
        feedStrategy: b.feedStrategy,
        targetResidual: b.targetResidual,
        drainageSlope: slope,
      );
    }

    test('1:50 → "1:50", Manning n 0.010, fill 0.50 (EN + ID)', () {
      // 1 / 0.02 = 50.
      final en = mechanicalDesignBasisBlock(withSlope(0.02)).rows;
      expect(en.any((r) => r.$1 == 'Drainage design slope:'), isTrue);
      expect(
          en.firstWhere((r) => r.$1 == 'Drainage design slope:').$2,
          '**1:50** (Manning n 0.010, design fill 0.50)');
      final id = mechanicalDesignBasisBlock(
              withSlope(0.01), const ReportStrings.id())
          .rows;
      expect(id.firstWhere((r) => r.$1 == 'Kemiringan desain drainase:').$2,
          '**1:100** (Manning n 0.010, pengisian desain 0.50)');
    });

    test('no slope ⇒ no row (legacy byte-identical)', () {
      final rows = mechanicalDesignBasisBlock(withSlope(null)).rows;
      expect(rows.any((r) => r.$1.startsWith('Drainage design slope')), isFalse);
    });
  });

  // ── i18n-essential-name ───────────────────────────────────────────────────
  group('i18n · an ID-named board is essential', () {
    ElectricalProject project(String epName) => ElectricalProject(
          id: 'pr',
          name: 'B',
          sources: const ElectricalSources(
              generator: GeneratorSource(backupFraction: 0.2)),
          panels: [
            const ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
              ElectricalCircuit(
                id: 'f-lp',
                name: 'Feeder LP',
                loadKind: LoadKind.feeder,
                length: Length(10),
                feedsPanelId: 'LP',
              ),
            ]),
            ElectricalPanel(
              id: 'LP',
              name: epName,
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f-lp',
              circuits: const [
                ElectricalCircuit(
                  id: 'l',
                  name: 'Lighting',
                  loadKind: LoadKind.lighting,
                  loadW: 9000,
                  length: Length(20),
                ),
              ],
            ),
          ],
        );

    for (final name in [
      'LP-ESSENTIAL',
      'PANEL EMERGENCY',
      'PANEL DARURAT',
      'LP-ESENSIAL',
      'Panel Emergensi',
    ]) {
      test('"$name" is genset-backed', () {
        expect(isEssentialByName(name), isTrue);
        expect(gensetBackedPanelIds(project(name)), {'LP'});
      });
    }

    test('a plain board name is not', () {
      expect(isEssentialByName('LP-1'), isFalse);
      expect(gensetBackedPanelIds(project('LP-1')), isEmpty);
    });
  });

  // ── i18n-oneline ──────────────────────────────────────────────────────────
  test('i18n · the ID report localizes the one-line labels + leads EN notes',
      () {
    final base = richElecData();
    const oneLine = PowerOneLine(
      nodes: [
        PowerNode(
            id: 'u',
            kind: PowerNodeKind.utility,
            label: 'PLN utility',
            sub: '400 V LV'),
        PowerNode(
            id: 'cos',
            kind: PowerNodeKind.ats,
            label: 'COS',
            sub: 'manual changeover'),
        PowerNode(id: 'b', kind: PowerNodeKind.battery, label: 'Battery'),
      ],
      edges: [],
      interlocks: [
        PowerInterlock(
            id: 'il',
            kind: PowerInterlockKind.mechanical,
            aId: 'u',
            bId: 'cos',
            relation: PowerInterlockRelation.mutualExclusion,
            note: 'Mains and generator must never be paralleled.'),
      ],
    );
    final data = ElectricalCalcReportData(
      projectName: base.projectName,
      date: base.date,
      standardsName: base.standardsName,
      standardsRevision: base.standardsRevision,
      project: base.project,
      result: base.result,
      powerOneLine: oneLine,
      verifyItems: base.verifyItems,
    );
    final id = buildElectricalCalcReport(data, const ReportStrings.id());
    expect(id, contains('Utilitas PLN (utilitas) — 400 V TR'));
    // A manual changeover is tagged (COS), never (ATS).
    expect(id, contains('COS (COS) — pemindah manual'));
    expect(id, contains('Baterai ('));
    expect(id, contains('(catatan dalam bahasa Inggris) Mains and generator'));
    expect(id, isNot(contains('PLN utility')));
    // EN keeps its literals (and the COS tag) with no lead.
    final en = buildElectricalCalcReport(data);
    expect(en, contains('PLN utility (utility) — 400 V LV'));
    expect(en, contains('COS (COS) — manual changeover'));
    expect(en, isNot(contains('(note in English)')));
  });
}
