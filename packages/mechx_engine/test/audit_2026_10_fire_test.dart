/// Audit 2026-10, group C1-fire — findings fire-2 … fire-6.
///
/// Every expectation is hand-derived from first principles in the comment that
/// precedes it (ρ = 1000 kg/m³, g = 9.81 m/s², A = π·D²/4, v = Q/A); the
/// arithmetic is the spec, not the current output.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/mep_commercial.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/sizing/water_supply_sizing.dart' as water;
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Cross-section area (m²) of a nominal [mm] bore.
double areaMm(double mm) => math.pi * (mm / 1000) * (mm / 1000) / 4;

void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // fire-2 — fire services floor at their code-minimum pipe sizes, sprinkler
  //          heads take the hazard's per-head flow, and the accumulated
  //          sprinkler flow is capped at the remote-area demand.
  // ══════════════════════════════════════════════════════════════════════════
  group('fire-2 — fire-service minimum diameters', () {
    // One sprinkler head on a plant source, the old flat 0.5 L/s share:
    //   DN20: A = π·0.020²/4 = 3.1416e-4 m² → v = 0.0005/3.1416e-4 = 1.59 m/s
    //         ≤ 2 m/s ⇒ the domestic sizer picked DN20 (below the 25 mm
    //         sprinkler-pipe minimum).
    //   With the floor the first candidate is DN25:
    //         A = 4.9087e-4 m² → v = 0.0005/4.9087e-4 = 1.0186 m/s.
    test('a single sprinkler edge sizes at least DN25', () {
      const net = Network(nodes: [
        NetNode(
            id: 'P', sheetId: 's', x: 0, y: 0, floorIndex: 0,
            role: NodeRole.plant),
        NetNode(id: 'H', sheetId: 's', x: 100, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(
            id: 'e', fromId: 'P', toId: 'H', service: ServiceType.fireSprinkler),
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: {ServiceType.fireSprinkler: FlowRate.litersPerSecond(0.5)});
      // Without the floor this flow would fit DN20 (the regression):
      expect(0.0005 / areaMm(20), lessThan(2.0));
      expect(s['e']!.diameter.inMillimeters, closeTo(25, 1e-9));
      expect(s['e']!.velocity.metersPerSecond,
          closeTo(0.0005 / areaMm(25), 1e-9));
      expect(s['e']!.velocity.metersPerSecond, closeTo(1.0186, 1e-4));
    });

    // Hydrant: pump P (floor 0) → riser → landing R (floor 1) → run → box B,
    // 1 L/s at the box.
    //   riser: the velocity sizer would pick DN32 (v = 1e-3/8.0425e-4 =
    //          1.243 m/s); the SNI 03-1745-2000 Class I/III standpipe minimum
    //          is 100 mm ⇒ DN100, v = 1e-3/7.854e-3 = 0.1273 m/s.
    //   run:   DN32 by velocity; the 65 mm Class I landing valve it feeds sets
    //          the floor ⇒ DN65, v = 1e-3/3.3183e-3 = 0.3014 m/s.
    test('a hydrant riser sizes at least DN100, a hydrant run at least DN65',
        () {
      const net = Network(nodes: [
        NetNode(
            id: 'P', sheetId: 's', x: 0, y: 0, floorIndex: 0,
            role: NodeRole.plant),
        NetNode(id: 'R', sheetId: 's', x: 0, y: 0, floorIndex: 1),
        NetNode(id: 'B', sheetId: 's', x: 100, y: 0, floorIndex: 1),
      ], edges: [
        NetEdge(
            id: 'riser',
            fromId: 'P',
            toId: 'R',
            service: ServiceType.fireHydrant,
            kind: EdgeKind.riser),
        NetEdge(
            id: 'run', fromId: 'R', toId: 'B', service: ServiceType.fireHydrant),
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: {ServiceType.fireHydrant: FlowRate.litersPerSecond(1)});
      expect(0.001 / areaMm(32), lessThan(2.0)); // DN32 by velocity alone
      expect(s['riser']!.diameter.inMillimeters, closeTo(100, 1e-9));
      expect(s['riser']!.diameter.inMillimeters,
          closeTo(kMinRiserDiameterMm, 1e-9));
      expect(s['riser']!.velocity.metersPerSecond, closeTo(0.1273, 1e-4));
      expect(s['run']!.diameter.inMillimeters, closeTo(65, 1e-9));
      expect(s['run']!.velocity.metersPerSecond, closeTo(0.3014, 1e-4));
    });

    // The floor is a FLOOR, not a fixed size: 12 L/s on a hydrant riser
    //   DN100: v = 0.012/7.854e-3 = 1.528 m/s ≤ 2 ⇒ stays DN100;
    //   18 L/s: DN100 v = 2.292 > 2, DN125 v = 0.018/0.012272 = 1.467 ⇒ DN125.
    test('the velocity sizer still raises a fire pipe above its floor', () {
      NetEdge riser() => const NetEdge(
          id: 'r',
          fromId: 'a',
          toId: 'b',
          service: ServiceType.fireHydrant,
          kind: EdgeKind.riser);
      expect(
          sizeEdge(riser(), FlowRate.litersPerSecond(12), const SizingContext())
              .diameter
              .inMillimeters,
          closeTo(100, 1e-9));
      expect(
          sizeEdge(riser(), FlowRate.litersPerSecond(18), const SizingContext())
              .diameter
              .inMillimeters,
          closeTo(125, 1e-9));
    });

    // Domestic water is untouched: 0.2 L/s at DN15 → v = 2e-4/1.7671e-4 =
    // 1.132 m/s ≤ 2 ⇒ DN15 (no floor), and sizeForFlow without a minimum is
    // the same call as before.
    test('water services have no fire floor (byte-identical)', () {
      const cw = NetEdge(
          id: 'c', fromId: 'a', toId: 'b', service: ServiceType.coldWater);
      expect(fireMinimumDiameter(cw), isNull);
      expect(
          sizeEdge(cw, const FlowRate(0.0002), const SizingContext())
              .diameter
              .inMillimeters,
          closeTo(15, 1e-9));
      final a = water.sizeForFlow(flow: const FlowRate(0.0002));
      expect(a.diameter.inMillimeters, closeTo(15, 1e-9));
    });

    // OH1 remote area (SNI 03-3989-2000 Sedang I): 5.0 L/min/m² × 72 m² =
    // 360 L/min over ceil(72/12) = 6 heads ⇒ 60 L/min/head = 1.0 L/s; head
    // pressure (60/80)² = 0.5625 bar ≥ 0.5 ⇒ density-governed, so
    //   remoteHeadFlow   = 1.0 L/s,  remoteAreaDemand = 6 × 1.0 = 6.0 L/s.
    // A 60-head star (plant → hub → 60 heads):
    //   uncapped main = 60 × 1.0 = 60 L/s → DN200 (v = 0.06/0.031416 = 1.91);
    //   capped main   = 6.0 L/s: DN50 v = 0.006/1.9635e-3 = 3.06 > 2,
    //                   DN65 v = 0.006/3.3183e-3 = 1.808 ≤ 2 ⇒ DN65.
    //   each head branch = 1.0 L/s: DN25 v = 2.037 > 2 ⇒ DN32 (v = 1.243).
    test('a 60-head tree: main flow capped at the remote-area demand', () {
      final ra = remoteAreaHydraulics(
          design: designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1));
      expect(ra.governedByMinimumPressure, isFalse);
      expect(ra.remoteHeadFlow.inLitersPerSecond, closeTo(1.0, 1e-9));
      expect(ra.remoteAreaDemand.inLitersPerSecond, closeTo(6.0, 1e-9));

      final nodes = <NetNode>[
        const NetNode(
            id: 'P', sheetId: 's', x: 0, y: 0, floorIndex: 0,
            role: NodeRole.plant),
        const NetNode(id: 'J', sheetId: 's', x: 10, y: 0, floorIndex: 0),
        for (var i = 0; i < 60; i++)
          NetNode(id: 'h$i', sheetId: 's', x: 20, y: i * 5.0, floorIndex: 0),
      ];
      final edges = <NetEdge>[
        const NetEdge(
            id: 'main', fromId: 'P', toId: 'J', service: ServiceType.fireSprinkler),
        for (var i = 0; i < 60; i++)
          NetEdge(
              id: 'b$i',
              fromId: 'J',
              toId: 'h$i',
              service: ServiceType.fireSprinkler),
      ];
      final net = Network(nodes: nodes, edges: edges);
      final leaf = {ServiceType.fireSprinkler: ra.remoteHeadFlow};

      final uncapped =
          autoSizeNetwork(net, const SizingContext(), leafDemand: leaf);
      expect(uncapped['main']!.flow.inLitersPerSecond, closeTo(60.0, 1e-9));
      expect(uncapped['main']!.diameter.inMillimeters, closeTo(200, 1e-9));

      final capped = autoSizeNetwork(net, const SizingContext(),
          leafDemand: leaf, sprinklerDemandCap: ra.remoteAreaDemand);
      expect(capped['main']!.flow.cubicMetersPerSecond,
          lessThanOrEqualTo(ra.remoteAreaDemand.cubicMetersPerSecond + 1e-15));
      expect(capped['main']!.flow.inLitersPerSecond, closeTo(6.0, 1e-9));
      expect(capped['main']!.diameter.inMillimeters, closeTo(65, 1e-9));
      expect(capped['b0']!.flow.inLitersPerSecond, closeTo(1.0, 1e-9));
      expect(capped['b0']!.diameter.inMillimeters, closeTo(32, 1e-9));
    });

    // The per-head share the app now feeds the sizer is at or above the old
    // flat 0.5 L/s for every hazard:
    //   LH : K·√0.5 = 80·0.70711 = 56.569 L/min = 0.9428 L/s (K-floor uplift)
    //   OH1: 360/6 = 60 L/min = 1.0 L/s;  OH2: 5·144/12 = 720/12 = 60 L/min
    //   EH : 10·260/ceil(260/9 = 28.9 → 29) = 2600/29 = 89.66 L/min = 1.494 L/s
    test('every hazard per-head design flow exceeds the old 0.5 L/s default',
        () {
      double perHead(FireHazardClass h) => remoteAreaHydraulics(
              design: designSprinklerSystem(hazard: h))
          .remoteHeadFlow
          .inLitersPerSecond;
      expect(perHead(FireHazardClass.lightHazard),
          closeTo(80 * math.sqrt(0.5) / 60, 1e-9));
      expect(perHead(FireHazardClass.ordinaryHazard1), closeTo(1.0, 1e-9));
      expect(perHead(FireHazardClass.ordinaryHazard2), closeTo(1.0, 1e-9));
      expect(perHead(FireHazardClass.extraHazard),
          closeTo(2600 / 29 / 60, 1e-9));
      for (final h in FireHazardClass.values) {
        expect(perHead(h), greaterThan(0.5));
      }
    });

    test('the new floors are surfaced on the verify checklist (pinned equal)',
        () {
      final values = const SniProfile().verifyChecklist.map((v) => v.value);
      expect(values, contains(kMinSprinklerPipeDiameterMm));
      expect(values, contains(kMinHydrantBranchDiameterMm));
      expect(values, contains(kHoseOutletHeightM));
      expect(values, contains(kOverloadEfficiencyFactor));
      expect(kMinSprinklerPipeDiameterMm, 25.0);
      expect(kMinHydrantBranchDiameterMm, 65.0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // fire-3 — the report's bold sprinkler demand is the remote-area demand.
  // ══════════════════════════════════════════════════════════════════════════
  group('fire-3 — calc report prints the remote-area sprinkler demand', () {
    CalcReportData data(SprinklerDesign sp, SprinklerRemoteAreaResult? ra) =>
        CalcReportData(
          projectName: 'P',
          date: '2026-10-17',
          standardsName: 'SNI',
          standardsRevision: 'r',
          verifyItems: const [],
          building: const BuildingLevels([Floor('G', Length(3))]),
          feedStrategy: 'upfeed',
          targetResidual: Pressure.kiloPascals(100),
          sprinkler: sp,
          sprinklerRemoteArea: ra,
        );

    // LH: density × area = 2.25 × 84 = 189 L/min = 3.15 L/s, but the head is
    // uplifted to K·√Pmin = 56.569 L/min, so the area demand is
    // 5 × 56.569 = 282.84 L/min = 4.714 L/s ⇒ the report prints 4.7 L/s.
    test('light hazard (min-pressure governed) prints 4.7 L/s, not 3.2', () {
      final sp = designSprinklerSystem(hazard: FireHazardClass.lightHazard);
      final ra = remoteAreaHydraulics(design: sp);
      expect(ra.remoteAreaDemand.inLitersPerMinute,
          closeTo(5 * 80 * math.sqrt(0.5), 1e-9));
      final md = buildCalcReportMarkdown(data(sp, ra));
      expect(md, contains('**4.7 L/s** over 5 heads'));
      expect(md, isNot(contains('**3.1 L/s**')));
      expect(md, isNot(contains('**3.2 L/s**')));
    });

    // OH1 is density-governed: remoteAreaDemand == requiredFlow == 6.0 L/s, so
    // the row is byte-identical with or without the hydraulic check.
    test('ordinary hazard 1 (density governed) stays 6.0 L/s', () {
      final sp = designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1);
      final ra = remoteAreaHydraulics(design: sp);
      expect(buildCalcReportMarkdown(data(sp, ra)),
          contains('**6.0 L/s** over 6 heads'));
      expect(buildCalcReportMarkdown(data(sp, null)),
          contains('**6.0 L/s** over 6 heads'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // fire-4 — the 150 % overload point can govern the motor.
  // ══════════════════════════════════════════════════════════════════════════
  group('fire-4 — overload efficiency derate', () {
    // overload shaft / rated shaft = (1.5 × 0.65) / 0.85 = 0.975/0.85 = 1.1471
    // for ANY duty (the old constant-η model gave 0.975 — never governing).
    test('overload shaft > rated shaft, ratio 0.975/0.85, for any duty', () {
      for (final (lps, m) in [(10.0, 30.0), (34.7, 122.5), (60.0, 45.0)]) {
        final r = checkFirePumpRating(
            ratedFlow: FlowRate.litersPerSecond(lps), ratedHead: Head(m));
        expect(r.overload.shaftPower.watts,
            greaterThan(r.rated.shaftPower.watts));
        expect(r.overload.shaftPower.watts / r.rated.shaftPower.watts,
            closeTo(1.5 * 0.65 / 0.85, 1e-12));
        if (!r.oversized) {
          expect(r.selectedMotor.watts,
              greaterThanOrEqualTo(r.overload.shaftPower.watts));
        }
      }
    });

    // Probe P4 (default 1-riser standpipe, 14 m): Q = 500 gpm = 31.545 L/s
    // (SNI 03-1745 / NFPA 14 most-remote riser), H = 14 + 15 + 690e3/9810
    // = 99.336 m.
    //   rated shaft    = 9810 · 0.031545 · 99.336 / 0.70 = 43.92 kW
    //   overload shaft = 43.92 × 0.975 / 0.85           = 50.38 kW
    //   ⇒ the 45 kW frame the rated point alone would pick overloads at 150 %
    //     flow; the next standard frame (55 kW) covers the overload point.
    test('default standpipe: motor no longer overloads at 150 % flow', () {
      final st = designStandpipe(risers: 1, buildingHeight: const Length(14));
      final r =
          checkFirePumpRating(ratedFlow: st.requiredFlow, ratedHead: st.pumpHead);
      const q = 500 * 3.785411784 / 60000; // m³/s
      const h = 14 + 15 + 690000 / 9810;
      const ratedW = 9810 * q * h / 0.70;
      expect(r.rated.shaftPower.watts, closeTo(ratedW, 1e-3));
      expect(r.overload.shaftPower.watts, closeTo(ratedW * 0.975 / 0.85, 1e-3));
      expect(r.rated.shaftPower.inKiloWatts, lessThan(45.0));
      expect(r.overload.shaftPower.inKiloWatts, greaterThan(45.0));
      expect(r.selectedMotor.inKiloWatts, closeTo(55.0, 1e-9));
    });

    test('factor 1.0 reproduces the constant-efficiency model', () {
      final r = checkFirePumpRating(
          ratedFlow: FlowRate.litersPerSecond(100),
          ratedHead: const Head(50),
          overloadEfficiencyFactor: 1.0);
      expect(r.overload.shaftPower.watts, closeTo(9810 * 0.15 * 32.5 / 0.7, 1e-3));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // fire-5 — the cut plan never pools two materials.
  // ══════════════════════════════════════════════════════════════════════════
  group('fire-5 — cut plan keyed on material', () {
    // n0(0,0) – n1(50,0) – n2(100,0) at 0.04 m/px ⇒ two collinear 2.0 m DN50
    // cold-water segments. Stock for cold water is 4 m.
    Network line(PipeProduct? p0, PipeProduct? p1) => Network(nodes: const [
          NetNode(id: 'n0', sheetId: 's', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'n1', sheetId: 's', x: 50, y: 0, floorIndex: 0),
          NetNode(id: 'n2', sheetId: 's', x: 100, y: 0, floorIndex: 0),
        ], edges: [
          NetEdge(
              id: 'e0',
              fromId: 'n0',
              toId: 'n1',
              service: ServiceType.coldWater,
              pipeProduct: p0),
          NetEdge(
              id: 'e1',
              fromId: 'n1',
              toId: 'n2',
              service: ServiceType.coldWater,
              pipeProduct: p1),
        ]);
    EdgeSizing dn50(String id) => EdgeSizing(
        edgeId: id,
        service: ServiceType.coldWater,
        flow: const FlowRate(0.001),
        diameter: Diameter.mm(50),
        velocity: const Velocity(0.5));
    final sizing = {'e0': dn50('e0'), 'e1': dn50('e1')};
    const cal = {'s': ScaleCalibration(0.04)};
    const building = BuildingLevels([Floor('G', Length(3))]);

    // PPR 2 m + PVC 2 m: 2 chains (2.0 m each), 2 cut groups, 1 bar each =
    // 2 bars to buy (one PPR, one PVC). The old pooled plan said 1 chain of
    // 4.0 m packed into 1 bar.
    test('collinear PPR DN50 + PVC DN50 → 2 chains, 2 groups, 1 bar each', () {
      final net = line(PipeProduct.pprPn10, PipeProduct.pvcAw);
      final chains = buildPipeChains(
          net: net, sizing: sizing, calibrationBySheet: cal, building: building);
      expect(chains, hasLength(2));
      expect(chains.map((c) => c.material).toSet(), {'PPR', 'PVC'});
      for (final c in chains) {
        expect(c.lengthM, closeTo(2.0, 1e-9));
      }
      final plan = buildPipeCutPlan(chains);
      expect(plan, hasLength(2));
      expect(plan.map((g) => g.material).toList(), ['PPR', 'PVC']);
      for (final g in plan) {
        expect(g.plan.totalBars, 1);
        expect(g.plan.requiredM, closeTo(2.0, 1e-9));
      }

      // The BOM splits the same two lines; the commercial estimate attaches
      // each material's OWN bar count (1 + 1), not the pooled 1 to one row.
      final bom = buildBom(
          net: net, sizing: sizing, calibrationBySheet: cal, building: building);
      expect(bom.map((l) => l.material).toSet(), {'PPR', 'PVC'});
      final est = estimateMechanicalCost(
          pipes: bom, fittings: const [], priceList: const {}, cutPlan: plan);
      final runs = est.lines.where((l) => l.category == MechItemCategory.pipe);
      expect(runs, hasLength(2));
      for (final l in runs) {
        expect(l.stockBars, 1);
      }
    });

    // Same resolved material (explicit PPR + a null product that resolves to
    // the cold-water default PPR) still merges: 1 chain of 4.0 m = 1 bar.
    test('same resolved material still merges (byte-identical)', () {
      final chains = buildPipeChains(
          net: line(PipeProduct.pprPn16, null),
          sizing: sizing,
          calibrationBySheet: cal,
          building: building);
      expect(chains, hasLength(1));
      expect(chains.single.material, 'PPR');
      expect(chains.single.lengthM, closeTo(4.0, 1e-9));
      expect(buildPipeCutPlan(chains).single.plan.totalBars, 1);
    });

    test('bomMaterialFor is the chain material', () {
      expect(
          bomMaterialFor(const NetEdge(
              id: 'x',
              fromId: 'a',
              toId: 'b',
              service: ServiceType.coldWater,
              pipeProduct: PipeProduct.pvcAw)),
          'PVC');
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // fire-6 — standpipe static lift = pump datum → topmost hose outlet.
  // ══════════════════════════════════════════════════════════════════════════
  group('fire-6 — standpipe static lift', () {
    // 10 floors × 4 m: top floor surface = 9 × 4 = 36 m above floor 0; the
    // landing valve sits 1.2 m above it ⇒ lift = 37.2 m (the roof, 40 m, was
    // passed before). Head = 37.2 + 15 + 690e3/9810 (= 70.336) = 122.536 m.
    test('10 floors × 4 m → lift 37.2 m, pump head ≈ 122.54 m', () {
      final b = BuildingLevels([
        for (var i = 0; i < 10; i++) Floor('L$i', const Length(4)),
      ]);
      final lift = standpipeStaticLift(b);
      expect(lift.meters, closeTo(37.2, 1e-9));
      final st = designStandpipe(risers: 1, buildingHeight: lift);
      expect(st.pumpHead.meters, closeTo(37.2 + 15 + 690000 / 9810, 1e-9));
      expect(st.pumpHead.meters, closeTo(122.536, 1e-3));
      // The old basis (roof = totalHeight) overstated it by 4 − 1.2 = 2.8 m.
      expect(b.totalHeight.meters - lift.meters, closeTo(2.8, 1e-9));
    });

    // Basements: 2 × 4 m basements + 3 × 4 m floors, ground = index 2. The
    // pump sits in the lowest basement (floor 0); the top floor surface is
    // 4 × 4 = 16 m above it in ANY datum frame ⇒ lift = 16 + 1.2 = 17.2 m.
    test('basements: lift measured from the lowest floor, datum-independent',
        () {
      final floors = [for (var i = 0; i < 5; i++) Floor('F$i', const Length(4))];
      expect(standpipeStaticLift(BuildingLevels(floors, groundIndex: 2)).meters,
          closeTo(17.2, 1e-9));
      expect(standpipeStaticLift(BuildingLevels(floors)).meters,
          closeTo(17.2, 1e-9));
    });

    test('an empty building lifts nothing', () {
      expect(standpipeStaticLift(const BuildingLevels([])).meters, 0);
    });
  });
}
