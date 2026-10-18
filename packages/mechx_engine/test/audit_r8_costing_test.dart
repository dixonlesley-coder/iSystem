/// Audit round 8 — costing fixes.
///
///   costing-1  mechanical price key carries material + rectangular W×H.
///   costing-2  single-core NYA bought per conductor; multi-core keyed by cores.
///   costing-4  breaker matching honours the board's prospective fault (kA).
///   costing-5  enclosure / busbar / RCD / accessories carry pricelist keys;
///              RCDs match catalogue RCCBs.
///   costing-6  a straight pass-through vertex is NOT an elbow.
///   costing-7  joint consumables follow the pipe MATERIAL.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/bom.dart' as elec;
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/costing.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart'
    show ElectricalSystemResult;
import 'package:mechx_engine/electrical/results.dart' show BreakerResult;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mep_commercial.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/consumables.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

EdgeSizing _sz(String id, ServiceType s, double mm) => EdgeSizing(
      edgeId: id,
      service: s,
      flow: const FlowRate(0.001),
      diameter: Diameter(mm / 1000),
      velocity: const Velocity(1.0),
    );

void main() {
  group('costing-1 — mechanical key separates material and W×H', () {
    test('PPR vs HDPE DN32 price apart; legacy price still applies', () {
      const ppr = BomLine(
        service: ServiceType.coldWater,
        kind: EdgeKind.run,
        diameterMm: 32,
        totalLength: Length(10),
        segmentCount: 1,
        material: 'PPR',
      );
      const hdpe = BomLine(
        service: ServiceType.coldWater,
        kind: EdgeKind.run,
        diameterMm: 32,
        totalLength: Length(10),
        segmentCount: 1,
        material: 'HDPE',
      );
      expect(mechPipeKeyFor(ppr), 'mech:pipe:coldWater:run:PPR:32');
      expect(mechPipeKeyFor(hdpe), 'mech:pipe:coldWater:run:HDPE:32');
      final est = estimateMechanicalCost(
        pipes: const [ppr, hdpe],
        fittings: const [],
        priceList: {
          // A legacy (material-less) price + one material-specific price.
          'mech:pipe:coldWater:run:32': 50000,
          mechPipeKeyFor(hdpe): 80000,
        },
      );
      final a = est.lines.firstWhere((l) => l.key == mechPipeKeyFor(ppr));
      final b = est.lines.firstWhere((l) => l.key == mechPipeKeyFor(hdpe));
      expect(a.description, 'Cold water pipe DN32 PPR');
      expect(b.description, 'Cold water pipe DN32 HDPE');
      // 10 m · 50 000 (legacy fallback) and 10 m · 80 000 (own key).
      expect(a.lineTotal, 500000);
      expect(b.lineTotal, 800000);
      expect(est.grandTotal, 1300000);
    });

    test('600x300 PU vs 800x250 BJLS ducts never share a key', () {
      const pu = BomLine(
        service: ServiceType.duct,
        kind: EdgeKind.run,
        diameterMm: 459,
        totalLength: Length(5),
        segmentCount: 1,
        material: 'PU',
        widthMm: 600,
        heightMm: 300,
      );
      const bjls = BomLine(
        service: ServiceType.duct,
        kind: EdgeKind.run,
        diameterMm: 459,
        totalLength: Length(5),
        segmentCount: 1,
        material: 'BJLS',
        widthMm: 800,
        heightMm: 250,
      );
      expect(mechPipeKeyFor(pu), 'mech:pipe:duct:run:PU:600x300');
      expect(mechPipeKeyFor(bjls), 'mech:pipe:duct:run:BJLS:800x250');
      final est = estimateMechanicalCost(
          pipes: const [pu, bjls], fittings: const [], priceList: const {});
      expect(est.lines.map((l) => l.description),
          ['Supply air duct 600x300 PU', 'Supply air duct 800x250 BJLS']);
    });

    test('fittings carry the material into the key', () {
      expect(
          mechFittingKey(ServiceType.coldWater, FittingType.elbow, 25,
              material: 'PPR'),
          'mech:fitting:coldWater:elbow:PPR:25');
    });
  });

  group('costing-6 — elbows only where the line turns', () {
    // Straight DN25 cold-water run a(0,0)–b(100,0)–c(200,0)–d(300,0).
    Network straight({double cy = 0}) => Network(nodes: [
          const NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 0),
          const NetNode(id: 'b', sheetId: 's', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'c', sheetId: 's', x: 200, y: cy, floorIndex: 0),
          const NetNode(id: 'd', sheetId: 's', x: 300, y: 0, floorIndex: 0),
        ], edges: const [
          NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
          NetEdge(id: 'e2', fromId: 'b', toId: 'c', service: ServiceType.coldWater),
          NetEdge(id: 'e3', fromId: 'c', toId: 'd', service: ServiceType.coldWater),
        ]);
    final sizing = {
      for (final id in ['e1', 'e2', 'e3']) id: _sz(id, ServiceType.coldWater, 25),
    };

    test('three collinear segments ⇒ 0 elbows', () {
      final f = buildFittings(net: straight(), sizing: sizing);
      expect(f.where((l) => l.type == FittingType.elbow), isEmpty);
    });

    test('a real 90° turn still counts', () {
      // c lifted to (200,100): b→c turns 45°, c→d turns back — 2 elbows.
      final f = buildFittings(net: straight(cy: 100), sizing: sizing);
      expect(f.where((l) => l.type == FittingType.elbow).single.count, 2);
    });

    test('property (seeded): an elbow ⇔ the turn exceeds ≈12°', () {
      final rng = math.Random(6);
      for (var i = 0; i < 200; i++) {
        final angle = rng.nextDouble() * math.pi; // turn angle at b
        final net = Network(nodes: [
          const NetNode(id: 'a', sheetId: 's', x: -100, y: 0, floorIndex: 0),
          const NetNode(id: 'b', sheetId: 's', x: 0, y: 0, floorIndex: 0),
          NetNode(
              id: 'c',
              sheetId: 's',
              x: 100 * math.cos(angle),
              y: 100 * math.sin(angle),
              floorIndex: 0),
        ], edges: const [
          NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
          NetEdge(id: 'e2', fromId: 'b', toId: 'c', service: ServiceType.coldWater),
        ]);
        final elbows = buildFittings(net: net, sizing: {
          'e1': _sz('e1', ServiceType.coldWater, 25),
          'e2': _sz('e2', ServiceType.coldWater, 25),
        }).where((l) => l.type == FittingType.elbow).length;
        // Direction b→a is (−1,0); b→c is (cos θ, sin θ): dot = −cos θ.
        // Pass-through ⇔ −cos θ ≤ −0.978 ⇔ cos θ ≥ 0.978.
        expect(elbows, math.cos(angle) >= 0.978 ? 0 : 1, reason: 'θ=$angle');
      }
    });

    test('two risers stacked through a floor node are a pass-through', () {
      const net = Network(nodes: [
        NetNode(id: 'g', sheetId: 's', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'm', sheetId: 's', x: 0, y: 0, floorIndex: 1),
        NetNode(id: 't', sheetId: 's', x: 0, y: 0, floorIndex: 2),
      ], edges: [
        NetEdge(id: 'r1', fromId: 'g', toId: 'm', service: ServiceType.coldWater, kind: EdgeKind.riser),
        NetEdge(id: 'r2', fromId: 'm', toId: 't', service: ServiceType.coldWater, kind: EdgeKind.riser),
      ]);
      final f = buildFittings(net: net, sizing: {
        'r1': _sz('r1', ServiceType.coldWater, 50),
        'r2': _sz('r2', ServiceType.coldWater, 50),
      });
      expect(f.where((l) => l.type == FittingType.elbow), isEmpty);
    });

    test('fitting material = the largest incident edge material', () {
      final net = Network(nodes: straight(cy: 100).nodes, edges: [
        for (final e in straight(cy: 100).edges)
          NetEdge(
              id: e.id,
              fromId: e.fromId,
              toId: e.toId,
              service: e.service,
              pipeProduct: PipeProduct.pvcAw),
      ]);
      final f = buildFittings(net: net, sizing: sizing);
      expect(f.every((l) => l.material == 'PVC'), isTrue);
    });
  });

  group('costing-7 — join method follows the material', () {
    test('PVC clean water is solvent-welded; HDPE drainage is fused', () {
      expect(joinMethodFor(ServiceType.coldWater, 'PVC'),
          PipeJoinMethod.solventWeld);
      expect(joinMethodFor(ServiceType.drainage, 'HDPE'),
          PipeJoinMethod.heatFusion);
      expect(joinMethodFor(ServiceType.fireHydrant, 'BS'),
          PipeJoinMethod.threaded);
      // Unknown material ⇒ the service default.
      expect(joinMethodFor(ServiceType.drainage, ''),
          joinMethodForService(ServiceType.drainage));
    });
  });

  group('electrical BOM', () {
    final parts = fullCatalog();

    ElectricalSystemResult sys(List<ElectricalCircuit> cs) => computeSystem(
          _profile,
          ElectricalProject(
            id: 'p',
            name: 'p',
            earthingSystem: EarthingSystem.tnCs,
            panels: [
              ElectricalPanel(
                  id: 'mdp',
                  name: 'MDP',
                  voltage: const Voltage(400),
                  circuits: cs),
            ],
          ),
        );

    test('costing-2: NYA single-core bought per conductor', () {
      final s = sys(const [
        ElectricalCircuit(
          id: 's1',
          name: 'Socket',
          loadKind: LoadKind.socket,
          loadW: 1500,
          cosPhi: 0.9,
          length: Length(15),
          cableType: 'NYA',
        ),
      ]);
      final pr = s.panels['mdp']!;
      final c = pr.circuits.single;
      final lines = elec.buildPanelBom(pr, parts: parts)
          .where((l) => l.category == PartCategory.cable)
          .toList();
      final total = lines.fold(0.0, (a, l) => a + l.qty);
      // L + N + PE = grounding.cores conductors of 15 m each.
      expect(c.grounding.cores, 3);
      expect(total, 15.0 * c.grounding.cores);
      // Every line is a single-core NYA SKU.
      for (final l in lines) {
        expect(parts.firstWhere((p) => p.sku == l.sku).cores, 1);
      }
    });

    test('costing-2: a large NYA run (beyond the 95 mm² single-core parts) '
        'is still bought per conductor and never as a multi-core NYY SKU', () {
      final s = sys(const [
        ElectricalCircuit(
          id: 'f1',
          name: 'Feeder',
          loadKind: LoadKind.motor,
          motorKw: 30,
          phases: 3,
          length: Length(12),
          cableType: 'NYA',
          cableOverrideMm2: 150,
        ),
      ]);
      final pr = s.panels['mdp']!;
      final c = pr.circuits.single;
      expect(c.cable.csaMm2, greaterThanOrEqualTo(150)); // the premise
      // The catalogue's largest single-core NYA is below the run's section, so
      // the family (not the matched part) must trigger the single-core path.
      final ncore = parts.where((p) => p.cores == 1 && p.cableType == 'NYA');
      expect(ncore.every((p) => p.csaMm2! < c.cable.csaMm2), isTrue);
      final lines = elec.buildPanelBom(pr, parts: parts)
          .where((l) => l.category == PartCategory.cable)
          .toList();
      final runs = c.cable.runsPerPhase ?? 1;
      // Live conductors + the separate PE line = grounding.cores pulls.
      final total = lines.fold(0.0, (a, l) => a + l.qty);
      expect(total, 12.0 * runs * c.grounding.cores);
      for (final l in lines) {
        // Never a multi-core part, never a core-count NYY key.
        if (l.sku != null) {
          expect(parts.firstWhere((p) => p.sku == l.sku).cores, 1);
        }
        expect(l.priceKey, isNotNull);
        expect(l.priceKey, isNot(contains('NYY')));
      }
      final live = lines.first;
      expect(live.sku, isNull);
      expect(live.priceKey,
          '${elec.kElecPriceKeyPrefix}cable:NYA:1x${c.cable.csaMm2.toInt()}');
    });

    test('consolidation never drops a breaking-capacity shortfall', () {
      // ONE breaker part (6 kA) serves every way on two boards: board A needs
      // 3 kA (adequate), board B 10 kA (short). The shortfall must survive
      // consolidation as its own flagged line naming the missed 10 kA.
      const only = Part(
        sku: 'MCB-X',
        manufacturer: 'Generic',
        category: PartCategory.breaker,
        series: 'X',
        model: 'X',
        attributes: {
          'ratingA': 1000,
          'poles': 3,
          'curve': 'C',
          'deviceClass': 'MCB',
          'breakingKa': 6,
        },
      );
      ElectricalPanel board(String id) => ElectricalPanel(
            id: id,
            name: id.toUpperCase(),
            voltage: const Voltage(400),
            circuits: [
              ElectricalCircuit(
                id: '$id-l',
                name: 'Lighting',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 1100,
                cosPhi: 0.9,
                length: const Length(20),
              ),
            ],
          );
      final s = computeSystem(
        _profile,
        ElectricalProject(
          id: 'p',
          name: 'p',
          earthingSystem: EarthingSystem.tnCs,
          panels: [board('a'), board('b')],
        ),
      );
      final bom = elec.buildBom(s,
          parts: const [only], requiredIcuKaByPanelId: {'a': 3, 'b': 10});
      final breakers =
          bom.lines.where((l) => l.category == PartCategory.breaker).toList();
      final short = breakers.where((l) => l.breakingCapacityShort).toList();
      final ok = breakers.where((l) => !l.breakingCapacityShort).toList();
      expect(short, isNotEmpty);
      expect(ok, isNotEmpty);
      for (final l in short) {
        expect(l.sku, 'MCB-X');
        expect(l.description, contains('no catalogue part reaches 10kA'));
      }
      // Board B's 2 breakers (incomer + way) are all short; A's are all ok.
      expect(short.fold(0.0, (a, l) => a + l.qty), 2);
      expect(ok.fold(0.0, (a, l) => a + l.qty), 2);
    });

    test('costing-2: multi-core NYY keys its price by core count', () {
      final s = sys(const [
        ElectricalCircuit(
          id: 'm1',
          name: 'Motor',
          loadKind: LoadKind.motor,
          motorKw: 7.5,
          length: Length(20),
          cableType: 'NYY',
        ),
      ]);
      final pr = s.panels['mdp']!;
      final cable = elec.buildPanelBom(pr, parts: parts)
          .firstWhere((l) => l.category == PartCategory.cable);
      final cores = pr.circuits.single.grounding.cores;
      expect(cable.priceKey, '${cable.sku}:${cores}C');
      expect(cable.qty, 20);
      // A legacy bare-SKU price still applies; a core-keyed price wins.
      final bom = elec.Bom([cable]);
      expect(estimateCost(bom, {cable.sku!: 100}).grandTotal, 2000);
      expect(estimateCost(bom, {cable.sku!: 100, cable.priceKey!: 150})
          .grandTotal, 3000);
    });

    test('costing-4: an 18.2 kA bus never gets a 6 kA MCB', () {
      // 630 kVA / (√3·400·0.05) = 18.19 kA (estimatedServiceFaultLevelA).
      final needKa = 630e3 / (math.sqrt(3) * 400 * 0.05) / 1000;
      const b = BreakerResult(
          ratingA: Current(63),
          deviceClass: BreakerClass.mcb,
          curve: BreakerCurve.c);
      final blind = elec.matchBreakerSku(b, parts, poles: 3);
      expect(parts.firstWhere((p) => p.sku == blind).breakingKa, lessThan(needKa));
      final sku = elec.matchBreakerSku(b, parts, poles: 3, minBreakingKa: needKa);
      final p = parts.firstWhere((p) => p.sku == sku);
      expect(p.breakingKa, greaterThanOrEqualTo(needKa));
      expect(p.ratingA, greaterThanOrEqualTo(63));
    });

    test('costing-5: every line of a lighting/socket board is priceable', () {
      final s = sys(const [
        ElectricalCircuit(
          id: 'l1',
          name: 'Lighting',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 1100,
          cosPhi: 0.9,
          length: Length(20),
        ),
        ElectricalCircuit(
          id: 's1',
          name: 'Socket',
          loadKind: LoadKind.socket,
          loadW: 1800,
          cosPhi: 0.9,
          length: Length(15),
        ),
      ]);
      final bom = elec.buildBom(s, parts: parts);
      expect(bom.lines.every((l) => l.priceKey != null), isTrue,
          reason: bom.lines
              .where((l) => l.priceKey == null)
              .map((l) => l.description)
              .join('; '));
      // Price every key at 100 ⇒ nothing stays unpriced.
      final prices = {for (final l in bom.lines) l.priceKey!: 100.0};
      expect(estimateCost(bom, prices).unmatchedCount, 0);
      // The socket way's 30 mA RCD matches a catalogue RCCB/RCBO.
      final rcd = bom.lines.firstWhere((l) => l.category == PartCategory.rcd);
      expect(rcd.sku, isNotNull);
      final rp = parts.firstWhere((p) => p.sku == rcd.sku);
      expect(rp.residualMa, 30);
      // A 3-phase board's busbar line says so.
      expect(
          bom.lines.firstWhere((l) => l.category == PartCategory.busbar)
              .description,
          startsWith('Busbar set (3φ)'));
    });
  });
}
