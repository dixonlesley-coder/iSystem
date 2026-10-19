// Round 33 (2026-10-18) — app-side findings:
//
//   regression-sni-minimum-judged-only-at-critical-node   every delivery
//     node is judged against its OWN SNI floor: a flush-valve WC below
//     98 kPa fails although the faucet-fed critical node meets 49 kPa.
//   regression-heatmap-legend-low-against-comfort-target  LOW only below the
//     SNI floor; 'below target' between the floor and the comfort target.
//   hydraulics-3-2   the upfeed heatmap / probe / over-pressure judge read the
//     DELIVERED field (root pump + zone booster at their own duties).
//   hydraulics-3-3   a PDAM meter -> pump -> roof tank fill pump is a
//     TRANSFER pump, never a 225 kPa-at-the-meter booster.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_assets.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/electrical_feed.dart' show isMepMintedCircuitName;
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sample_project.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/canvas/heatmap_layer.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart' show DxfBounds;
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart' show pressureFromHead;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_symbols.dart' show equipmentNodeTags;
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

NetNode _n(String id, double x, int floor,
        {NodeComponent? c,
        NodeRole role = NodeRole.main,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: kSampleSheetId,
        x: x,
        y: 600,
        floorIndex: floor,
        role: c?.role ?? role,
        component: c,
        fixture: fixture);

NetEdge _run(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);
NetEdge _riser(String id, String a, String b) => NetEdge(
    id: id,
    fromId: a,
    toId: b,
    service: ServiceType.coldWater,
    kind: EdgeKind.riser);

ProviderContainer _project(List<Floor> floors, Network net,
    {FeedStrategy feed = FeedStrategy.downfeed}) {
  final c = _c();
  loadSampleLayoutProjectTo(c.read);
  c.read(projectControllerProvider.notifier).setFloors(floors);
  c.read(feedStrategyProvider.notifier).set(feed);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  group('SNI minimum is judged at every delivery node', () {
    // Ground 4 m, L1 3 m, L2 4.5 m (roof 11.5 m). Roof tank T on L2 ->
    // R2 -riser- R1 (L1) -riser- R0 (Ground). A lavatory FA teed at R1, a
    // flush-valve WC FV teed at R0.
    // First principles: FA at the L1 fixture height (4 + 1.1 = 5.1 m) sees
    // 6.4 m of static (≈ 63 kPa) less friction; its path holds no flush
    // valve, so its SNI floor is 0.5 kgf/cm² = 49 kPa and it is the critical
    // (least-pressure) node. FV at 1.1 m sees 10.4 m (≈ 102 kPa) less the
    // flush-valve flow's friction — below ITS OWN 1.0 kgf/cm² = 98 kPa floor.
    const floors = [
      Floor('Ground', Length(4)),
      Floor('L1', Length(3)),
      Floor('L2', Length(4.5)),
    ];
    Network net() => Network(nodes: [
          _n('T', 550, 2, c: NodeComponent.roofTank),
          _n('R2', 600, 2),
          _n('R1', 600, 1),
          _n('R0', 600, 0),
          _n('FA', 650, 1,
              role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
          _n('FV', 650, 0,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushValve),
        ], edges: [
          _run('t', 'T', 'R2'),
          _riser('r21', 'R2', 'R1'),
          _riser('r10', 'R1', 'R0'),
          _run('fa', 'R1', 'FA'),
          _run('fv', 'R0', 'FV'),
        ]);

    test('a flush-valve WC below 98 kPa is a blocking warning', () {
      final c = _project(floors, net());
      final d = c.read(downfeedDeliveredProvider)!;
      final fa = d.residualPressure['FA']!.inKiloPascals;
      final fv = d.residualPressure['FV']!.inKiloPascals;
      const sni = SniProfile();
      final faucet = sni.minResidualPressureFaucet.value.inKiloPascals;
      final valve = sni.minResidualPressureFlushValve.value.inKiloPascals;
      expect(d.criticalNodeId, 'FA');
      expect(fa, greaterThan(faucet));
      expect(fv, lessThan(valve));
      final floorsByNode = c.read(downfeedSniFloorsProvider);
      expect(floorsByNode['FA']!.inKiloPascals, closeTo(faucet, 1e-9));
      expect(floorsByNode['FV']!.inKiloPascals, closeTo(valve, 1e-9));
      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'downfeed-below-target');
      expect(issue.severity, IssueSeverity.warning);
      // Names the WORST offender: FV, its own floor and residual.
      expect(issue.locate?.nodeId, 'FV');
      expect(issue.message, contains('${valve.toStringAsFixed(0)} kPa'));
      expect(issue.message, contains('${fv.toStringAsFixed(0)} kPa'));
      final row = c
          .read(complianceSummaryProvider)
          .items
          .firstWhere((i) => i.category == 'Supply pressure');
      expect(row.pass, isFalse);
      // The heatmap legend reads the same verdict.
      final h = c.read(heatmapSniSummaryProvider);
      expect(h.belowFloor, isTrue);
      expect(h.floorKpa, closeTo(valve, 1e-9));
    });

    test('per-node floors: a faucet off the flush-valve branch keeps 49 kPa',
        () {
      final c = _project(floors, net());
      final floorsByNode = sniMinimumResidualByNode(
        net: c.read(networkControllerProvider).network,
        sourceId: 'T',
        nodeIds: const ['FA', 'FV', 'R0', 'R1'],
        flushValveNodeIds: const {'FV'},
      );
      expect(floorsByNode['FA']!.inKiloPascals, closeTo(49.03, 0.01));
      expect(floorsByNode['FV']!.inKiloPascals, closeTo(98.07, 0.01));
      expect(floorsByNode['R0']!.inKiloPascals, closeTo(49.03, 0.01));
    });
  });

  group('residual verdict ladder (heatmap legend + probe)', () {
    test('pure ladder', () {
      expect(
          residualVerdict(residualPa: 60e3, targetPa: 225e3, sniFloorPa: 49e3),
          ResidualVerdict.belowTarget);
      expect(
          residualVerdict(residualPa: 40e3, targetPa: 225e3, sniFloorPa: 49e3),
          ResidualVerdict.low);
      expect(
          residualVerdict(residualPa: 230e3, targetPa: 225e3, sniFloorPa: 49e3),
          ResidualVerdict.pass);
      // No floor known: the legacy target-only verdict.
      expect(residualVerdict(residualPa: 60e3, targetPa: 225e3),
          ResidualVerdict.low);
    });

    Widget host(Widget child) => MechXTheme(
          data: MechXThemeData.light,
          child: Directionality(
              textDirection: TextDirection.ltr, child: Center(child: child)),
        );

    testWidgets('uniform 60 kPa above a 49 kPa floor reads below target',
        (t) async {
      await t.pumpWidget(host(const HeatmapLegend(
          minKpa: 60, maxKpa: 60, targetKpa: 225, sniFloorKpa: 49)));
      expect(find.text('LOW'), findsNothing);
      expect(find.text('below target'), findsOneWidget);
    });

    testWidgets('a node below its floor reads LOW', (t) async {
      await t.pumpWidget(host(const HeatmapLegend(
          minKpa: 60,
          maxKpa: 60,
          targetKpa: 225,
          sniFloorKpa: 98,
          belowSniFloor: true)));
      expect(find.text('LOW'), findsOneWidget);
    });

    testWidgets('spread field: the tick is the Target; SNI min labelled',
        (t) async {
      await t.pumpWidget(host(const HeatmapLegend(
          minKpa: 30, maxKpa: 260, targetKpa: 225, sniFloorKpa: 49)));
      expect(find.text('Min 225 kPa'), findsNothing);
      expect(find.text('Target 225 kPa'), findsOneWidget);
      expect(find.text('SNI min 49 kPa'), findsOneWidget);
    });
  });

  group('upfeed delivered field with drawn movers', () {
    test('root pump + zone booster: the field is shifted per mover', () {
      // 8 storeys x 3.5 m; root pump P (Ground) feeds L0-L4 directly; a
      // booster BS on the riser at L4 feeds L5-L7. Two WCs per floor.
      final floors = [
        for (var i = 0; i < 8; i++) Floor('L$i', const Length(3.5)),
      ];
      final nodes = <NetNode>[
        _n('P', 300, 0, c: NodeComponent.pump),
        for (var i = 0; i < 8; i++) _n('m$i', 500, i),
        _n('BS', 520, 4, c: NodeComponent.boosterSet),
        _n('m4b', 540, 4),
        for (var i = 0; i < 8; i++)
          _n('W$i', 800, i,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank),
      ];
      final edges = <NetEdge>[
        _run('p0', 'P', 'm0'),
        for (var i = 0; i < 4; i++) _riser('r$i', 'm$i', 'm${i + 1}'),
        _run('b0', 'm4', 'BS'),
        _run('b1', 'BS', 'm4b'),
        _riser('r4', 'm4b', 'm5'),
        for (var i = 5; i < 7; i++) _riser('r$i', 'm$i', 'm${i + 1}'),
        for (var i = 0; i < 8; i++) _run('w$i', 'm$i', 'W$i'),
      ];
      final c = _project(floors, Network(nodes: nodes, edges: edges),
          feed: FeedStrategy.upfeed);
      final base = c.read(solveProvider)!;
      final duties = c.read(supplyMoverDutiesProvider);
      expect(duties.keys, containsAll(['P', 'BS']));
      final delivered = c.read(upfeedDeliveredProvider)!;
      expect(identical(delivered, base), isFalse);
      // First principles: residuals are linear in the source head; the root
      // pump develops its OWN duty head (not the whole-system head), the
      // booster adds its head beyond itself.
      final shift = pressureFromHead(Head(
              base.requiredPumpHead.meters - duties['P']!.head.meters))
          .pascals;
      final boost = pressureFromHead(duties['BS']!.head).pascals;
      expect(delivered.residualPressure['W0']!.pascals,
          closeTo(base.residualPressure['W0']!.pascals - shift, 1e-6));
      expect(delivered.residualPressure['W7']!.pascals,
          closeTo(base.residualPressure['W7']!.pascals - shift + boost, 1e-6));
      // The heatmap field is the delivered one.
      expect(c.read(residualByNodeProvider), same(delivered.residualPressure));
      // Every delivery node meets the target with the movers at their duty.
      final target = c.read(targetResidualProvider).pascals;
      for (final id in delivered.deliveryNodeIds) {
        expect(delivered.residualPressure[id]!.pascals,
            greaterThanOrEqualTo(target - 1), reason: id);
      }
    });
  });

  group('PDAM meter -> pump -> roof tank (hydraulics-3-3)', () {
    test('the fill pump is a TRANSFER pump; no booster duty', () {
      const floors = [
        Floor('L0', Length(3.5)),
        Floor('L1', Length(3.5)),
        Floor('L2', Length(3.5)),
      ];
      final net = Network(nodes: [
        _n('WM', 300, 0, c: NodeComponent.waterMeter),
        _n('P', 400, 0, c: NodeComponent.pump),
        _n('m0', 500, 0),
        _n('m1', 500, 1),
        _n('m2', 500, 2),
        _n('T', 600, 2, c: NodeComponent.roofTank),
        _n('d2', 700, 2),
        _n('d1', 700, 1),
        _n('d0', 700, 0),
        _n('W0', 900, 0,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushTank),
        _n('W1', 900, 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushTank),
      ], edges: [
        _run('wp', 'WM', 'P'),
        _run('pm', 'P', 'm0'),
        _riser('fr0', 'm0', 'm1'),
        _riser('fr1', 'm1', 'm2'),
        _run('ft', 'm2', 'T'),
        _run('td', 'T', 'd2'),
        _riser('dr1', 'd2', 'd1'),
        _riser('dr0', 'd1', 'd0'),
        _run('w0', 'd0', 'W0'),
        _run('w1', 'd1', 'W1'),
      ]);
      final c = _project(floors, net);
      expect(c.read(transferPumpNodeIdsProvider), {'P'});
      expect(c.read(pumpDutyProvider), isNull);
      final duty = c.read(supplyMoverDutiesProvider)['P']!;
      // Lift: P on the L0 surface (0 m) to the roof tank at the roof
      // (10.5 m), plus the fill-line friction (> 0).
      expect(duty.head.meters, greaterThan(10.5));
      expect(duty.head.meters, lessThan(10.5 + 5));
    });
  });

  group(r'DXF $INSUNITS on Apply scale to all sheets (import-robustness-2-1)',
      () {
    // a.dxf: 40000 x 20000 mm; b.dxf: the same plan drawn 40 x 20 m. Both
    // normalise to 1684 x 842 content px.
    Sheet sheet(String id, double w, double h, int? units) => Sheet(
        id: id,
        name: id,
        dxfPath: '/plans/$id.dxf',
        sizePx: const Size(1684, 842),
        dxfFrame: DxfBounds(0, 0, w, h),
        dxfInsUnits: units);
    test('mm -> m: the scale is transferred verbatim (same content box)', () {
      final a = sheet('a', 40000, 20000, 4);
      final b = sheet('b', 40, 20, 6);
      // First principles: a physical length L spans L / u world units, i.e.
      // L·k / u px, so mpp = u / k. A: 0.001 / (1684/40000) = 40/1684;
      // B: 1 / (1684/40) = 40/1684 — the same figure (the old transfer gave
      // 40/1684 / 1000: a 40 m wall read 0.04 m).
      const mpp = 40 / 1684;
      final t = transferCalibration(const ScaleCalibration(mpp),
          from: a, to: b)!;
      expect(t.metersPerPixel, closeTo(mpp, 1e-15));
      // B's 40 m wall (1684 px) reads 40 m.
      expect(t.metersPerPixel * 1684, closeTo(40, 1e-9));
    });

    test('inch -> mm converts by 25.4', () {
      final a = sheet('a', 1000, 500, 1); // 1000 in = 25.4 m
      final b = sheet('b', 25400, 12700, 4); // the same 25.4 m in mm
      const mpp = 25.4 / 1684;
      final t = transferCalibration(const ScaleCalibration(mpp),
          from: a, to: b)!;
      expect(t.metersPerPixel, closeTo(mpp, 1e-15));
    });

    test('only one unit known: refused; neither known: legacy same-unit', () {
      final a = sheet('a', 40000, 20000, 4);
      expect(
          transferCalibration(const ScaleCalibration(0.02),
              from: a, to: sheet('b', 40, 20, 0)),
          isNull);
      expect(
          transferCalibration(const ScaleCalibration(0.02),
              from: a, to: sheet('b', 40, 20, null)),
          isNull);
      final t = transferCalibration(const ScaleCalibration(0.02),
          from: sheet('a', 40000, 20000, null),
          to: sheet('b', 20000, 10000, null))!;
      expect(t.metersPerPixel,
          closeTo(0.02 * (1684 / 40000) / (1684 / 20000), 1e-15));
    });

    test(r'$INSUNITS round-trips in .mechx (additive)', () {
      final doc = ProjectDocument(
        projectName: 'P',
        floors: const [Floor('G', Length(3.0))],
        calibrations: const {},
        sheets: [sheet('a', 40, 20, 6)],
        network: const Network(nodes: [], edges: []),
      );
      final back = ProjectDocument.decode(doc.encode());
      expect(back.sheets.single.dxfInsUnits, 6);
    });
  });

  group('a truncated / corrupt embedded plan is reported (2-4)', () {
    final bytes =
        utf8.encode('0\nLINE\n10\n0\n20\n0\n11\n100\n21\n50\n' * 3000);
    ProjectDocument docWith(String b64) => ProjectDocument(
          projectName: 'P',
          floors: const [Floor('G', Length(3.0))],
          calibrations: const {},
          sheets: const [
            Sheet(id: 'a', name: 'Denah', dxfPath: '/no/such/denah.dxf'),
          ],
          network: const Network(nodes: [], edges: []),
          assets: {'/no/such/denah.dxf': b64},
        );

    test('the ISIZE trailer catches a stream cut in half', () {
      final gz = gzip.encode(bytes);
      expect(gzipTrailerMatches(gz, bytes.length), isTrue);
      final half = gz.sublist(0, gz.length ~/ 2);
      // dart:io returns the inflated PREFIX without throwing — the reason the
      // trailer check exists.
      final prefix = gzip.decode(half);
      expect(prefix.length, lessThan(bytes.length));
      expect(gzipTrailerMatches(half, prefix.length), isFalse);
    });

    test('half a gzip asset: not repointed, named as missing', () {
      final gz = gzip.encode(bytes);
      final doc = rehydrateAssets(
          docWith(base64Encode(gz.sublist(0, gz.length ~/ 2))));
      expect(doc.sheets.single.dxfPath, '/no/such/denah.dxf');
      expect(missingPlanSheetNames(doc), ['Denah']);
    });

    test('a bit-flipped asset: same', () {
      final gz = gzip.encode(bytes);
      gz[gz.length ~/ 2] ^= 0xff;
      final doc = rehydrateAssets(docWith(base64Encode(gz)));
      expect(doc.sheets.single.dxfPath, '/no/such/denah.dxf');
      expect(missingPlanSheetNames(doc), ['Denah']);
    });

    test('a whole asset restores and is not missing', () {
      final doc = rehydrateAssets(docWith(base64Encode(gzip.encode(bytes))));
      expect(File(doc.sheets.single.dxfPath!).readAsBytesSync(), bytes);
      expect(missingPlanSheetNames(doc), isEmpty);
    });
  });

  group('stack growth pins only sheets with work', () {
    // Default 3 levels; 5 blank imported pages. First principles: an EMPTY
    // sheet carries nothing to keep in place, so it keeps its rail-position
    // mapping; adding 2 levels maps pages 4-5 onto the new floors 3-4.
    List<Sheet> pages() => [
          for (var i = 0; i < 5; i++) Sheet(id: 'p$i', name: 'Page ${i + 1}'),
        ];
    test('5 blank sheets + 2 levels on top -> [0,1,2,3,4]', () {
      final c = _c();
      c.read(sheetsControllerProvider.notifier).loadSheets(pages());
      c.read(projectControllerProvider.notifier).addFloorsOnTop(2, 4.0);
      final levels = c.read(projectControllerProvider).building.levelCount;
      expect(levels, 5);
      final s = c.read(sheetsControllerProvider);
      expect([for (final p in s.sheets) s.floorFor(p.id, levels)],
          [0, 1, 2, 3, 4]);
    });

    test('a sheet with drawn work stays on its old floor; empty ones follow',
        () {
      final c = _c();
      c.read(sheetsControllerProvider.notifier).loadSheets(pages());
      // Page 4 (clamped onto floor 2 of 3) carries a drawn node.
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(id: 'n', sheetId: 'p3', x: 10, y: 10, floorIndex: 2),
            ],
            edges: [],
          ));
      c.read(projectControllerProvider.notifier).addFloorsOnTop(2, 4.0);
      final s = c.read(sheetsControllerProvider);
      expect([for (final p in s.sheets) s.floorFor(p.id, 5)], [0, 1, 2, 2, 4]);
    });
  });

  group('equipment tags number per prefix (engineer-walkthrough-…-ordinal)',
      () {
    Map<String, String> tags(ProviderContainer c) =>
        equipmentNodeTags(c.read(networkControllerProvider).network);
    String idOf(ProviderContainer c, NodeComponent comp, {int skip = 0}) => c
        .read(networkControllerProvider)
        .network
        .nodes
        .where((n) => n.component == comp)
        .skip(skip)
        .first
        .id;

    test('tank then pump after fixtures -> TK-01, P-01 (not P-02 / P-41)', () {
      final c = _c();
      final net = c.read(networkControllerProvider.notifier);
      // Ten fixtures first: the global node counter runs to n9.
      for (var i = 0; i < 10; i++) {
        net.mergeOrAddTerminal('s1', 0, Offset(100.0 + 40 * i, 900),
            fixture: PlumbingFixture.lavatory);
      }
      net.addComponentNode('s1', 0, const Offset(100, 100),
          NodeComponent.groundTank);
      net.addComponentNode('s1', 0, const Offset(300, 100), NodeComponent.pump);
      final t = tags(c);
      expect(t[idOf(c, NodeComponent.groundTank)], 'TK-01');
      expect(t[idOf(c, NodeComponent.pump)], 'P-01');
    });

    test('a deleted P-01 is never re-issued (C6 stability), across a reload',
        () {
      final c = _c();
      final net = c.read(networkControllerProvider.notifier);
      net.addComponentNode('s1', 0, const Offset(100, 100), NodeComponent.pump);
      final p1 = idOf(c, NodeComponent.pump);
      net.deleteNode(p1);
      net.addComponentNode('s1', 0, const Offset(300, 100), NodeComponent.pump);
      expect(tags(c)[idOf(c, NodeComponent.pump)], 'P-02');
      // Persisted only because it runs ahead (P-02 live ⇒ next 3 implied).
      expect(net.persistedTagSeq, isEmpty);
      net.deleteNode(idOf(c, NodeComponent.pump));
      expect(net.persistedTagSeq, {'P': 3});
      // Reload the (empty) network with the saved sequence: the next pump is
      // P-03, never a re-issued P-01 / P-02.
      final c2 = _c();
      c2.read(networkControllerProvider.notifier).loadNetwork(
          c.read(networkControllerProvider).network,
          tagSeq: net.persistedTagSeq);
      c2.read(networkControllerProvider.notifier).addComponentNode(
          's1', 0, const Offset(300, 100), NodeComponent.pump);
      expect(tags(c2)[idOf(c2, NodeComponent.pump)], 'P-03');
    });

    test('a legacy file (no tag numbers) keeps its ordinal tags', () {
      final c = _c();
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(
                  id: 'n0',
                  sheetId: 's1',
                  x: 0,
                  y: 0,
                  floorIndex: 0,
                  role: NodeRole.plant,
                  component: NodeComponent.groundTank),
              NetNode(
                  id: 'n1',
                  sheetId: 's1',
                  x: 50,
                  y: 0,
                  floorIndex: 0,
                  role: NodeRole.plant,
                  component: NodeComponent.pump),
            ],
            edges: [],
          ));
      expect(tags(c), {'n0': 'TK-01', 'n1': 'P-02'});
      // A pump drawn afterwards never collides with the legacy P-02.
      c.read(networkControllerProvider.notifier).addComponentNode(
          's1', 0, const Offset(300, 100), NodeComponent.pump);
      expect(tags(c).values.where((v) => v.startsWith('P-')).toSet(),
          {'P-02', 'P-03'});
      expect(tags(c)['n1'], 'P-02');
    });

    test('two drawn pumps feed ways named after their tags', () async {
      final c = _c();
      c.read(projectControllerProvider.notifier)
          .setFloors(const [Floor('L0', Length(3.5))]);
      c.read(electricalProjectProvider);
      final net = c.read(networkControllerProvider.notifier);
      net.addComponentNode('s1', 0, const Offset(100, 100), NodeComponent.pump);
      net.addComponentNode('s1', 0, const Offset(300, 100), NodeComponent.pump);
      await Future<void>.delayed(Duration.zero);
      final names = [
        for (final p in c.read(electricalProjectProvider).panels)
          for (final w in p.circuits)
            if (w.sourceEquipmentId != null &&
                w.name.startsWith(NodeComponent.pump.label))
              w.name,
      ]..sort();
      expect(names, ['Pump P-01', 'Pump P-02']);
      expect(isMepMintedCircuitName('Pump P-02'), isTrue);
      expect(isMepMintedCircuitName('Pump'), isTrue);
      expect(isMepMintedCircuitName('Booster pump room A'), isFalse);
    });
  });
}
