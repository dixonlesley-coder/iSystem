// Round 17 — engine-side regressions (2026-10-18). Each group names the
// finding it pins; expected values are derived from first principles in the
// comments (never relaxed tolerances).
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

ElectricalPanel _p3(String id, List<ElectricalCircuit> circuits,
        {String? fedBy, bool essential = false}) =>
    ElectricalPanel(
      id: id,
      name: id,
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      essential: essential,
      sourceType: fedBy == null ? PanelSource.utility : PanelSource.feeder,
      fedByCircuitId: fedBy,
      circuits: circuits,
    );

NetNode _n(String id, double x, int f,
        {NodeRole role = NodeRole.main, NodeComponent? c, FlowRate? q}) =>
    NetNode(
        id: id,
        sheetId: 's',
        x: x,
        y: 0,
        floorIndex: f,
        role: role,
        component: c,
        airflow: q);

void main() {
  // ── regression-forced-genset-kw-limit-unjudged ────────────────────────────
  group('forced genset nameplate is judged on kW too', () {
    ElectricalProject proj(double kva) => ElectricalProject(
          id: 'g',
          name: 'g',
          sources: ElectricalSources(
              generator: GeneratorSource(kva: ApparentPower(kva * 1000))),
          panels: [
            _p3(
                'EMDP',
                [
                  for (var i = 0; i < 6; i++)
                    ElectricalCircuit(
                      id: 'h$i',
                      name: 'Load $i',
                      loadKind: LoadKind.general,
                      loadW: 15000,
                      cosPhi: 0.95,
                      phases: 3,
                      length: const Length(10),
                    ),
                ],
                essential: true),
          ],
        );

    test('100 kVA / 80 kW set vs 90 kW at cos 0.95: power warning only', () {
      final pr = proj(100);
      final sys = computeSystem(p, pr);
      // Essential W = 6 × 15 kW = 90 kW; VA = 90 000 / 0.95 = 94 737 VA.
      expect(essentialDemandW(pr, sys), closeTo(90000, 1));
      expect(essentialDemandVa(pr, sys), closeTo(94736.8, 1));
      final codes = gensetBackupWarnings(pr, sys).map((w) => w.code).toList();
      // 100 kVA ≥ 94.7 kVA (VA passes) but 0.8 × 100 = 80 kW < 90 kW.
      expect(codes, ['genset-below-essential-power']);
      final w = gensetBackupWarnings(pr, sys).single;
      expect(w.message, contains('80.0 kW'));
      expect(w.message, contains('90.0'));
      // It reaches the advanced study's ONE warning list.
      expect(computeAdvancedStudy(p, pr, sys).warnings.map((w) => w.code),
          contains('genset-below-essential-power'));
    });

    test('property: no warning iff the set covers both VA and W', () {
      for (var kva = 60.0; kva <= 140; kva += 2.5) {
        final pr = proj(kva);
        final sys = computeSystem(p, pr);
        final codes = gensetBackupWarnings(pr, sys).map((w) => w.code).toSet();
        final vaOk = kva * 1000 + 1e-6 >= essentialDemandVa(pr, sys);
        final wOk =
            kva * 1000 * kGeneratorPf + 1e-6 >= essentialDemandW(pr, sys);
        expect(codes.contains('genset-below-essential-demand'), !vaOk,
            reason: '$kva');
        expect(codes.contains('genset-below-essential-power'), !wOk,
            reason: '$kva');
      }
    });
  });

  // ── protection-2-service-estimate-50ka-clamp-hides-fault + fault-z label ──
  group('service fault estimate: unclamped, flagged above 50 kA, 4 % label',
      () {
    const mdp = ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
            id: 'l',
            name: 'Load',
            loadKind: LoadKind.general,
            loadW: 20000,
            phases: 3,
            length: Length(10)),
      ],
    );

    test('1600 kVA ⇒ 57 735.0 A (no 50 kA clamp) and a review warning', () {
      // Isc = 1.6e6 / (√3·400·0.04) = 1.6e6 / 27.712813 = 57735.03 A.
      const pr = ElectricalProject(
          id: 't',
          name: 't',
          panels: [mdp],
          transformerKva: ApparentPower(1600000));
      expect(estimatedServiceFaultLevelA(pr)!.amperes, 57735.0);
      final sys = computeSystem(p, pr);
      final study = computeAdvancedStudy(p, pr, sys);
      expect(study.fault.originFaultkA, closeTo(57.74, 0.01));
      expect(study.warnings.map((w) => w.code),
          contains('service-fault-estimate-high'));
    });

    test(
        'property: estimate = S/(√3·400·0.04) for every rating, flagged iff >50 kA',
        () {
      for (var kva = 100.0; kva <= 3000; kva += 137) {
        final pr = ElectricalProject(
            id: 't',
            name: 't',
            panels: const [mdp],
            transformerKva: ApparentPower(kva * 1000));
        final expected = kva * 1000 / (math.sqrt(3) * 400 * 0.04);
        expect(
            estimatedServiceFaultLevelA(pr)!.amperes, closeTo(expected, 0.051),
            reason: '$kva');
        final study = computeAdvancedStudy(p, pr, computeSystem(p, pr));
        expect(
            study.warnings.any((w) => w.code == 'service-fault-estimate-high'),
            expected > 50000,
            reason: '$kva');
      }
    });

    test('an explicit origin fault level is never second-guessed', () {
      const pr = ElectricalProject(
          id: 't',
          name: 't',
          panels: [mdp],
          transformerKva: ApparentPower(2000000),
          originFaultLevelA: Current(65000));
      final study = computeAdvancedStudy(p, pr, computeSystem(p, pr));
      expect(study.warnings.any((w) => w.code == 'service-fault-estimate-high'),
          isFalse);
    });

    test('the printed impedance label is the 4 % the estimate uses', () {
      expect(serviceFaultEstimateVerifyItems.first, contains('(4 % p.u.)'));
      expect(serviceFaultEstimateVerifyItems.join(' '), isNot(contains('5 %')));
    });
  });

  // ── protection-2-max-fault-uses-70C-resistance ────────────────────────────
  group('maximum fault decays through conductor R at 20 °C', () {
    // 10 kA origin, MDP -> DB1 over a 16 mm² Cu feeder of 20 m.
    ElectricalProject proj(double lengthM) => ElectricalProject(
          id: 'f',
          name: 'f',
          earthingSystem: EarthingSystem.tnS,
          panels: [
            _p3('MDP', [
              ElectricalCircuit(
                  id: 'fd',
                  name: 'Feeder DB1',
                  loadKind: LoadKind.feeder,
                  length: Length(lengthM),
                  cableOverrideMm2: 16,
                  feedsPanelId: 'DB1'),
            ]),
            _p3(
                'DB1',
                const [
                  ElectricalCircuit(
                      id: 'w',
                      name: 'Lighting',
                      loadKind: LoadKind.lighting,
                      loadW: 1000,
                      length: Length(10)),
                ],
                fedBy: 'fd'),
          ],
        );

    test('20 m 16 mm²: 6.43 kA ⇒ the 10 kA MCB rung (70 °C printed 5.86 kA)',
        () {
      final pr = proj(20);
      final sys = computeSystem(p, pr);
      expect(sys.panels['MDP']!.circuits.single.cable.csaMm2, 16);
      final fs = faultStudy(sys, pr, p, originFaultLevel: const Current(10000));
      // Source: z = 400/(√3·10000) = 0.0230940 Ω; R = z/√50 = 0.00326599,
      // X = 7R = 0.0228619. Feeder R20 = 1.38·0.020·(254.5/304.5) =
      // 0.0276·0.835796 = 0.0230680 Ω, X = 0.08·0.020 = 0.0016 Ω.
      //   |Z| = √(0.0263340² + 0.0244619²) = 0.0359424 Ω
      //   Isc = 400/(√3·0.0359424) = 6425.3 A > 6 kA.
      const r = 0.00326599 + 0.0276 * 254.5 / 304.5;
      const x = 0.0228619 + 0.0016;
      final isc = 400 / (math.sqrt(3) * math.sqrt(r * r + x * x));
      expect(isc, closeTo(6425.3, 0.5));
      expect(fs.panels['DB1']!.prospectiveFaultkA, closeTo(isc / 1000, 0.01));
      expect(fs.panels['DB1']!.incomerKa, 10);
      expect(fs.circuits['w']!.breakerKa, 10);
    });

    test('coldConductorResistanceFactor is (β+20)/(β+70)', () {
      expect(coldConductorResistanceFactor(ConductorMaterial.copper),
          closeTo(254.5 / 304.5, 1e-12));
      expect(coldConductorResistanceFactor(ConductorMaterial.aluminum),
          closeTo(248 / 298, 1e-12));
    });

    test('property: the bus fault is the 20 °C decay for every feeder length',
        () {
      for (var l = 5.0; l <= 120; l += 7.5) {
        final pr = proj(l);
        final sys = computeSystem(p, pr);
        final fs =
            faultStudy(sys, pr, p, originFaultLevel: const Current(10000));
        final csa = sys.panels['MDP']!.circuits.single.cable.csaMm2;
        final r = 0.00326599 +
            p.conductorResistanceOhmPerKm(csa) * l / 1000 * 254.5 / 304.5;
        final x = 0.0228619 + p.conductorReactanceOhmPerKm * l / 1000;
        final isc = 400 / (math.sqrt(3) * math.sqrt(r * r + x * x));
        expect(fs.panels['DB1']!.prospectiveFaultkA, closeTo(isc / 1000, 0.006),
            reason: '$l m');
        // The specified rung always covers it (the unsafe direction is shut).
        expect(fs.panels['DB1']!.incomerKa + 1e-9,
            greaterThanOrEqualTo(fs.panels['DB1']!.prospectiveFaultkA));
      }
    });
  });

  // ── regression-flow-path-function-applies-to-fire-and-drainage ────────────
  group('FUNCTION suffix only on domestic water', () {
    test('hydrant network behind a fire pump carries no BOOSTER', () {
      final net = Network(nodes: [
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FP', 20, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('J0', 40, 0),
        _n('J1', 40, 1),
        _n('J2', 40, 2),
        _n('h1', 60, 1, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        _n('h2', 60, 2, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ], edges: const [
        NetEdge(
            id: 's',
            fromId: 'GT',
            toId: 'FP',
            service: ServiceType.fireHydrant),
        NetEdge(
            id: 'd',
            fromId: 'FP',
            toId: 'J0',
            service: ServiceType.fireHydrant),
        NetEdge(
            id: 'r1',
            fromId: 'J0',
            toId: 'J1',
            service: ServiceType.fireHydrant,
            kind: EdgeKind.riser),
        NetEdge(
            id: 'r2',
            fromId: 'J1',
            toId: 'J2',
            service: ServiceType.fireHydrant,
            kind: EdgeKind.riser),
        NetEdge(
            id: 'b1',
            fromId: 'J1',
            toId: 'h1',
            service: ServiceType.fireHydrant),
        NetEdge(
            id: 'b2',
            fromId: 'J2',
            toId: 'h2',
            service: ServiceType.fireHydrant),
      ]);
      final sizing = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.fireHydrant: FlowRate(0.0063)});
      final flow = flowFromBySizing(sizing);
      expect(flow, isNotEmpty);
      for (final e in net.edges) {
        for (final down in [false, true]) {
          expect(
              riserFunctionFor(net, e, downfeed: down, flowFrom: flow), isNull,
              reason: e.id);
        }
      }
    });

    test('sewage ejector discharge to the STP carries no TRANSFER', () {
      final net = Network(nodes: [
        _n('F1', 0, 0, role: NodeRole.fixture),
        _n('pit', 20, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('EP', 40, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('J', 60, 0),
        _n('STP', 80, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      ], edges: const [
        NetEdge(
            id: 'a', fromId: 'F1', toId: 'pit', service: ServiceType.drainage),
        NetEdge(
            id: 'b', fromId: 'pit', toId: 'EP', service: ServiceType.drainage),
        NetEdge(
            id: 'c', fromId: 'EP', toId: 'J', service: ServiceType.drainage),
        NetEdge(
            id: 'd', fromId: 'J', toId: 'STP', service: ServiceType.drainage),
      ]);
      final flow = <String, String>{'a': 'F1', 'b': 'pit', 'c': 'EP', 'd': 'J'};
      for (final e in net.edges) {
        expect(riserFunctionFor(net, e, downfeed: true, flowFrom: flow), isNull,
            reason: e.id);
        expect(riserFunctionFor(net, e, downfeed: false), isNull, reason: e.id);
      }
    });
  });

  // ── regression-ahu-intake-behind-damper-phantom ───────────────────────────
  group('AHU intake through an OA damper', () {
    const q = FlowRate(0.05);
    Network build(NodeRole damperRole, {int dampers = 1}) => Network(nodes: [
          _n('oa', 0, 0),
          for (var i = 0; i < dampers; i++)
            _n('md$i', 10.0 + i, 0,
                role: damperRole, c: NodeComponent.motorizedDamper),
          _n('ahu', 40, 0, role: NodeRole.plant, c: NodeComponent.ahu),
          _n('j', 80, 0),
          _n('d1', 120, 0,
              role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: q),
          _n('d2', 130, 0,
              role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: q),
        ], edges: [
          for (var i = 0; i <= dampers; i++)
            NetEdge(
                id: 'i$i',
                fromId: i == 0 ? 'oa' : 'md${i - 1}',
                toId: i == dampers ? 'ahu' : 'md$i',
                service: ServiceType.duct),
          const NetEdge(
              id: 'aj', fromId: 'ahu', toId: 'j', service: ServiceType.duct),
          const NetEdge(
              id: 'j1', fromId: 'j', toId: 'd1', service: ServiceType.duct),
          const NetEdge(
              id: 'j2', fromId: 'j', toId: 'd2', service: ServiceType.duct),
        ]);

    test('every chain edge carries the delivered 0.1 m³/s INTO the AHU', () {
      for (final role in [NodeRole.main, NodeRole.plant]) {
        for (final dampers in [1, 2]) {
          final net = build(role, dampers: dampers);
          final s = autoSizeNetwork(net, const SizingContext(),
              leafDemand: const {ServiceType.duct: FlowRate(0.05)},
              nodeFlowDemand: const {'d1': q, 'd2': q});
          // The unit delivers d1 + d2 = 0.05 + 0.05 = 0.10 m³/s — no phantom
          // 0.05 at the intake leaf (it used to deliver 0.15).
          expect(s['aj']!.flow.cubicMetersPerSecond, closeTo(0.10, 1e-12));
          for (var i = 0; i <= dampers; i++) {
            final e = s['i$i']!;
            expect(e.flow.cubicMetersPerSecond, closeTo(0.10, 1e-12),
                reason: 'i$i ($role, $dampers)');
            // Flow comes from the LEAF side (oa / the outer damper).
            expect(e.flowFromId, i == 0 ? 'oa' : 'md${i - 1}');
          }
        }
      }
    });
  });

  // ── regression-ducted-ac-intake-phantom-fan-way (engine root half) ────────
  group('stand-alone ducted AC with an OA leaf roots at the AC', () {
    const q = FlowRate(0.15);
    test('the bare intake leaf never roots the system', () {
      for (final withDamper in [false, true]) {
        final net = Network(nodes: [
          _n('oa', 0, 0),
          if (withDamper) _n('md', 10, 0, c: NodeComponent.motorizedDamper),
          _n('ac', 40, 0, role: NodeRole.plant, c: NodeComponent.acDucted),
          _n('j', 80, 0),
          _n('d1', 120, 0,
              role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: q),
          _n('d2', 130, 0,
              role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: q),
        ], edges: [
          if (withDamper) ...const [
            NetEdge(
                id: 'ao', fromId: 'ac', toId: 'md', service: ServiceType.duct),
            NetEdge(
                id: 'mo', fromId: 'md', toId: 'oa', service: ServiceType.duct),
          ] else
            const NetEdge(
                id: 'ao', fromId: 'ac', toId: 'oa', service: ServiceType.duct),
          const NetEdge(
              id: 'aj', fromId: 'ac', toId: 'j', service: ServiceType.duct),
          const NetEdge(
              id: 'j1', fromId: 'j', toId: 'd1', service: ServiceType.duct),
          const NetEdge(
              id: 'j2', fromId: 'j', toId: 'd2', service: ServiceType.duct),
        ]);
        final roots = serviceComponentRoots(net, ServiceType.duct,
            demandNodeIds: const {'d1', 'd2'});
        expect(roots['oa'], 'ac', reason: 'damper=$withDamper');
        final s = autoSizeNetwork(net, const SizingContext(),
            leafDemand: const {ServiceType.duct: FlowRate(0.05)},
            nodeFlowDemand: const {'d1': q, 'd2': q});
        // The intake carries the 0.30 m³/s the AC delivers, INWARD.
        expect(s['ao']!.flow.cubicMetersPerSecond, closeTo(0.30, 1e-12));
        expect(s['ao']!.flowFromId, withDamper ? 'md' : 'oa');
        expect(s['aj']!.flowFromId, 'ac');
      }
    });
  });

  // ── report-recompute-2-component-less-source-at-roof-on-upfeed ────────────
  group('untyped plant elevation', () {
    final b6 = BuildingLevels(
        [for (var i = 0; i < 6; i++) Floor('L$i', const Length(3.5))]);
    test('an untyped L0 source sits on L0 (== a ground tank on L0)', () {
      final untyped = _n('S', 0, 0, role: NodeRole.plant);
      final gt =
          _n('G', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank);
      expect(nodeElevation(untyped, b6).meters, nodeElevation(gt, b6).meters);
      expect(nodeElevation(untyped, b6).meters, 0.0);
      // Top storey keeps the roof datum (6 × 3.5 = 21 m).
      expect(nodeElevation(_n('T', 0, 5, role: NodeRole.plant), b6).meters,
          closeTo(21.0, 1e-12));
    });
  });

  // ── regression-downfeed-prv-setpoint-equals-target ────────────────────────
  group('downfeed PRV setpoint', () {
    test('target + 30 kPa friction margin, bounded to half the window', () {
      const target = Pressure(225000);
      final maxFix = const SniProfile().maxFixtureStaticPressure.value;
      // window = 392.266 − 225 = 167.266 kPa; margin = min(30, 83.6) = 30.
      expect(
          defaultPrvSetpoint(targetResidual: target, maxFixtureStatic: maxFix)
              .pascals,
          closeTo(255000, 1e-6));
      // A narrow window caps the margin at half of it.
      expect(
          defaultPrvSetpoint(
                  targetResidual: target,
                  maxFixtureStatic: const Pressure(265000))
              .pascals,
          closeTo(245000, 1e-6));
      // No window ⇒ the target itself.
      expect(
          defaultPrvSetpoint(
                  targetResidual: target,
                  maxFixtureStatic: const Pressure(200000))
              .pascals,
          225000);
    });
  });

  // ── riser drafting: edge lanes, bowtie, feed note, mover captions ─────────
  group('riser SLD drafting', () {
    // Floor 0: a D+V stack junction S0 and a WC fixture W0 carrying CW + D +
    // V; both are multi-service, so their nodes sit on the band centre.
    Network stack() => Network(nodes: [
          _n('S0', 0, 0),
          _n('S1', 0, 1),
          _n('W0', 100, 0, role: NodeRole.fixture),
          _n('C0', 200, 0),
        ], edges: const [
          NetEdge(
              id: 'd', fromId: 'S0', toId: 'W0', service: ServiceType.drainage),
          NetEdge(id: 'v', fromId: 'S0', toId: 'W0', service: ServiceType.vent),
          NetEdge(
              id: 'c',
              fromId: 'C0',
              toId: 'W0',
              service: ServiceType.coldWater),
          NetEdge(
              id: 'ds',
              fromId: 'S1',
              toId: 'S0',
              service: ServiceType.drainage,
              kind: EdgeKind.riser),
          NetEdge(
              id: 'vs',
              fromId: 'S1',
              toId: 'S0',
              service: ServiceType.vent,
              kind: EdgeKind.riser),
        ]);

    test('runs between multi-service nodes sit on their own service lane', () {
      final lanes = riserEdgeLaneOffsets(stack());
      expect(lanes['d'], riserServiceLane(ServiceType.drainage));
      expect(lanes['v'], riserServiceLane(ServiceType.vent));
      // Focused / single-service sheets are untouched.
      expect(
          riserEdgeLaneOffsets(stack(), focus: ServiceType.drainage), isEmpty);
    });

    test('property: no two horizontal runs of different layers overlap', () {
      final building = BuildingLevels(
          [for (var i = 0; i < 2; i++) Floor('L$i', const Length(3.5))]);
      final sheet =
          buildMechanicalRiserSld(network: stack(), building: building);
      final h = [
        for (final pr in sheet.prims)
          if (pr is SldLine &&
              pr.layer != null &&
              (pr.y1 - pr.y2).abs() < 1e-6 &&
              (pr.x1 - pr.x2).abs() > 1)
            pr,
      ];
      for (var i = 0; i < h.length; i++) {
        for (var j = i + 1; j < h.length; j++) {
          final a = h[i], b = h[j];
          if (a.layer == b.layer) continue;
          if ((a.y1 - b.y1).abs() > 0.5) continue;
          final lo = math.max(math.min(a.x1, a.x2), math.min(b.x1, b.x2));
          final hi = math.min(math.max(a.x1, a.x2), math.max(b.x1, b.x2));
          expect(hi - lo, lessThanOrEqualTo(1.0),
              reason: '${a.layer} vs ${b.layer} at y=${a.y1}');
        }
      }
    });

    test('feed note follows the drawn equipment', () {
      expect(
          riserFeedNote(
              downfeed: true,
              hasRoofTank: false,
              hasPump: false,
              hasWaterMeter: true,
              detailed: true),
          'Feed: direct mains (water meter)');
      expect(riserFeedNote(downfeed: true, hasRoofTank: false, hasPump: false),
          'Feed: direct mains');
      expect(
          riserFeedNote(
              downfeed: true,
              hasRoofTank: true,
              hasPump: false,
              detailed: true),
          'Feed: gravity downfeed (roof tank)');
      expect(riserFeedNote(downfeed: true, hasRoofTank: false, hasPump: true),
          'Feed: booster pump');
      expect(riserFeedNote(downfeed: false, hasRoofTank: false, hasPump: false),
          'Feed: upfeed / booster');
      // Never 'gravity downfeed' without a roof tank.
      for (final pump in [false, true]) {
        for (final wm in [false, true]) {
          for (final det in [false, true]) {
            expect(
                riserFeedNote(
                    downfeed: true,
                    hasRoofTank: false,
                    hasPump: pump,
                    hasWaterMeter: wm,
                    detailed: det),
                isNot(contains('gravity')));
          }
        }
      }
    });

    test('a transfer pump is captioned TRANSFER PUMP with its own kW', () {
      final net = Network(nodes: [
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('TP', 20, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('BS', 40, 0, role: NodeRole.plant, c: NodeComponent.boosterSet),
        _n('FP', 60, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('RT', 20, 3, role: NodeRole.plant, c: NodeComponent.roofTank),
      ], edges: const [
        NetEdge(
            id: 'a', fromId: 'GT', toId: 'TP', service: ServiceType.coldWater),
        NetEdge(
            id: 'b',
            fromId: 'TP',
            toId: 'RT',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser),
        NetEdge(
            id: 'c', fromId: 'RT', toId: 'BS', service: ServiceType.coldWater),
        // A fire pump is never a domestic plant-detail mover.
        NetEdge(
            id: 'f',
            fromId: 'GT',
            toId: 'FP',
            service: ServiceType.fireHydrant),
      ]);
      expect(
          plantMoverCaptions(net, detailByNodeId: const {
            'TP': '0.37 kW',
            'BS': '0.37 kW',
            'FP': '55 kW'
          }, transferPumpNodeIds: const {
            'TP'
          }),
          ['BOOSTER PUMP 0.37 kW', 'TRANSFER PUMP 0.37 kW']);
      final sheet = buildMechanicalRiserSld(
        network: net,
        detailCallouts: true,
        equipmentDetailByNodeId: const {'TP': '0.37 kW', 'BS': '0.37 kW'},
        transferPumpNodeIds: const {'TP'},
      );
      final texts = [
        for (final pr in sheet.prims)
          if (pr is SldLabel) pr.text,
      ];
      expect(texts, contains('TRANSFER PUMP 0.37 kW'));
      expect(texts, contains('BOOSTER PUMP 0.37 kW'));
    });
  });

  group('electrical vertical source spine: the isolator is in series', () {
    test('the lead below the PLN head touches the bowtie', () {
      const pr = ElectricalProject(
          id: 'e',
          name: 'e',
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              system: ElectricalSystem.threePhase,
              voltage: Voltage(400),
              circuits: [
                ElectricalCircuit(
                    id: 'l',
                    name: 'L',
                    loadKind: LoadKind.general,
                    loadW: 20000,
                    phases: 3,
                    length: Length(10)),
              ],
            ),
          ],
          transformerKva: ApparentPower(630000));
      final sys = computeSystem(p, pr);
      for (final sheet in [
        buildElectricalOverview(project: pr, result: sys, sourceChain: true),
        buildElectricalRiser(project: pr, result: sys, sourceChain: true),
      ]) {
        final lines = sheet.prims.whereType<SldLine>().toList();
        // The bowtie's lower BAR is horizontal (axis along the conductor) and
        // a vertical lead starts exactly on it.
        final bars = [
          for (final l in lines)
            if (l.weight == SldWeight.medium &&
                (l.y1 - l.y2).abs() < 1e-9 &&
                (l.x2 - l.x1 - 19.8).abs() < 1e-6)
              l,
        ];
        expect(bars.length, greaterThanOrEqualTo(2));
        final lower = bars.reduce((a, b) => a.y1 > b.y1 ? a : b);
        final cx = (lower.x1 + lower.x2) / 2;
        expect(
            lines.any((l) =>
                (l.x1 - cx).abs() < 1e-6 &&
                (l.x2 - cx).abs() < 1e-6 &&
                (l.y1 - lower.y1).abs() < 1e-6 &&
                l.y2 > l.y1),
            isTrue);
      }
    });
  });

  group('sheet legend + cover', () {
    test('the PDF legend dashes the vent swatch, solid CW stays solid', () {
      final pdf = pdfLegend(
          const DrawingChrome(
              legendServices: [ServiceType.coldWater, ServiceType.vent]),
          originX: 10,
          originY: 10);
      expect(pdf, contains('[6.00 4.00] 0 d'));
      expect(pdf, contains('[] 0 d'));
      final solid = pdfLegend(
          const DrawingChrome(legendServices: [ServiceType.coldWater]),
          originX: 10,
          originY: 10);
      expect(solid, isNot(contains(' d\n')));
    });

    test('the DXF plan legend swatch carries the vent linetype', () {
      final dxf = dxfPlanChrome(
        const DrawingChrome(legendServices: [ServiceType.vent]),
        minX: 0,
        minY: 0,
        maxX: 1000,
        maxY: 1000,
        unitsPerPaperMm: 1,
        plotDenominator: null,
        projectName: 'P',
      );
      expect(dxf, contains('\n6\nDASHED\n'));
    });

    test('the cover counts DRAWINGS, labelled as such', () {
      final sheet = buildCoverSheet(projectName: 'P', drawingCount: 5);
      final texts = [
        for (final pr in sheet.prims)
          if (pr is SldLabel) pr.text,
      ];
      expect(texts, contains('JUMLAH GAMBAR / DRAWINGS'));
      expect(texts, isNot(contains('JUMLAH LEMBAR / SHEETS')));
    });
  });

  group('reports', () {
    test('calc report prints one tagged line per supply mover', () {
      final tp =
          sizePump(flow: const FlowRate(0.000883), head: const Head(20.1));
      final bs =
          sizePump(flow: const FlowRate(0.00025), head: const Head(22.2));
      final md = buildCalcReportMarkdown(CalcReportData(
        projectName: 'T',
        date: '2026-10-18',
        standardsName: 'SNI',
        standardsRevision: 'r',
        verifyItems: const [],
        building: const BuildingLevels([Floor('G', Length(4))]),
        feedStrategy: 'Downfeed',
        targetResidual: const Pressure(225000),
        pump: bs,
        supplyPumps: [
          (
            tag: 'P-01',
            service: 'Transfer pump (ground tank to roof tank)',
            duty: tp
          ),
          (tag: 'P-02', service: 'Domestic water supply', duty: bs),
        ],
      ));
      expect(
          md,
          contains('- Pump P-01 (Transfer pump (ground tank to roof tank)): '
              '**0.88 L/s @ 20.1 m**'));
      expect(
          md,
          contains(
              '- Pump P-02 (Domestic water supply): **0.25 L/s @ 22.2 m**'));
      // The legacy untagged head line is replaced, not duplicated.
      expect(md, isNot(contains('- Pump head:')));
    });

    test('electrical report Ib is the RUN current the way is sized on', () {
      const pr = ElectricalProject(id: 'r', name: 'r', panels: [
        ElectricalPanel(
          id: 'LP',
          name: 'LP-1',
          system: ElectricalSystem.threePhase,
          voltage: Voltage(400),
          circuits: [
            ElectricalCircuit(
                id: 's',
                name: 'Sockets',
                loadKind: LoadKind.socket,
                loadW: 2000,
                cosPhi: 0.9,
                demandFactor: 0.7,
                length: Length(25)),
          ],
        ),
      ]);
      final sys = computeSystem(p, pr);
      final c = sys.panels['LP']!.circuits.single;
      // Diversified Ib = 0.7 × run current; the run current is the
      // undiversified 2000 W / (U·0.9) the device + Vd were sized on.
      expect(
          c.runCurrentA.amperes, closeTo(c.designCurrent.amperes / 0.7, 0.15));
      expect(c.runCurrentA.amperes, greaterThan(c.designCurrent.amperes));
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
        projectName: 'r',
        date: '2026-10-18',
        standardsName: p.name,
        standardsRevision: p.revision,
        project: pr,
        result: sys,
      ));
      final row = md.split('\n').firstWhere((l) => l.contains('| Sockets'));
      expect(row, contains(c.runCurrentA.amperes.toStringAsFixed(1)));
    });

    test('equipment schedule prints a sub-1 L/s circulator at 2 dp', () {
      final hw =
          sizePump(flow: const FlowRate(0.0000709), head: const Head(0.2));
      final rows = buildEquipmentScheduleRows(
          EquipmentScheduleData(projectName: 'T', date: '2026-10-18', pumps: [
        PumpScheduleItem(duty: hw, service: 'HW recirc', tag: 'HWP-01'),
        PumpScheduleItem(
            duty: sizePump(flow: const FlowRate(0.0015), head: const Head(30)),
            service: 'Domestic',
            tag: 'P-01'),
      ]));
      expect(rows[0].duty, '0.07 L/s @ 0.20 m');
      // ≥ 1 keeps the 1-dp format.
      expect(rows[1].duty, '1.5 L/s @ 30.0 m');
    });
  });

  group('sprinkler-only fire pump rated point', () {
    test('remote-area demand at lift + branch pressure + 15 m', () {
      final remote = remoteAreaHydraulics(
          design:
              designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1),
          kFactor: 80);
      final rp = sprinklerPumpRatedPoint(remote: remote, staticLiftM: 6.0);
      expect(rp.flow.cubicMetersPerSecond,
          remote.remoteAreaDemand.cubicMetersPerSecond);
      // H = 6.0 + P/(1000·9.81) + 15.
      expect(rp.head.meters,
          closeTo(6.0 + remote.branchBasePressure.pascals / 9810 + 15, 1e-9));
    });
  });
}
