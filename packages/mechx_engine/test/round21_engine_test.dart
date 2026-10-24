// Round 21 (2026-10-18) — the engine half of the round-21 audit:
//
//   fire-3-motor-ladder      the IEC ladder runs to 315 kW (an 82 kW fire pump
//                            selects 90 kW, never a clamped 75 kW)
//   fire-3-riser-count       the standpipe flow counts the DRAWN riser stacks
//   fire-3-velocity          fire pipe sizes on a 6 m/s cap, not 2 m/s
//   electrical-plan-length   plan route labels print the one 0.1 m format
//   bom-quote-1              FRC / NYM never priced as another family's SKU
//   bom-quote-2              unmeasured runs are counted on the BOM line
//   bom-quote-3              drawn components are taken off; inline terminals
//                            sit on a tee
//   bom-quote-4              each enclosure is priced at its own W x H x D
//   bom-quote-5              control gear / genset / SPD / earthing reach the
//                            BOM
//   bom-quote-6              rectangular fittings key + label on W x H
//   riser-drafting-2-6       gravity stack junctions read the below-slab datum
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart' as elec;
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart'
    show StarterType;
import 'package:mechx_engine/electrical/costing.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/mep_commercial.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();
const _rhoG = 1000 * 9.81;

EdgeSizing _sz(String id, ServiceType s, double mm,
        {double? w, double? h}) =>
    EdgeSizing(
      edgeId: id,
      service: s,
      flow: const FlowRate(0.001),
      diameter: Diameter(mm / 1000),
      velocity: const Velocity(1.0),
      width: w == null ? null : Length(w / 1000),
      height: h == null ? null : Length(h / 1000),
    );

NetNode _n(String id, double x, double y,
        {int floor = 0,
        String sheet = 's1',
        NodeRole role = NodeRole.main,
        NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: sheet,
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

void main() {
  // ── fire-3-motor-ladder ───────────────────────────────────────────────────
  group('fire-3 motor ladder', () {
    // The audit's 20-storey office: rated 31.545 L/s @ 162.54 m ⇒ overload
    // 47.32 L/s @ 0.65 × 162.54 = 105.65 m; η_overload = 0.70 × 0.85 = 0.595:
    //   shaft = 9810 × 0.047318 × 105.65 / 0.595 = 82.42 kW ⇒ 90 kW frame.
    test('an 82.4 kW overload shaft selects the 90 kW IEC frame', () {
      final r = checkFirePumpRating(
          ratedFlow: FlowRate.litersPerSecond(31.545),
          ratedHead: const Head(162.54));
      const expected = _rhoG * 0.0315450 * 1.5 * 162.54 * 0.65 / 0.595;
      expect(r.overload.shaftPower.watts, closeTo(expected, 1));
      expect(expected / 1000, closeTo(82.42, 0.01));
      expect(r.selectedMotor.inKiloWatts, 90);
      expect(r.oversized, isFalse);
    });

    // Property: for any shaft power up to the ladder top the selected frame
    // covers it and is the SMALLEST that does (seeded sweep).
    test('selectMotor is the smallest covering frame (seeded property)', () {
      final rnd = math.Random(21);
      for (var i = 0; i < 500; i++) {
        final kw = rnd.nextDouble() * 330;
        final m = selectMotor(Power.kiloWatts(kw)).inKiloWatts;
        if (kw <= standardMotorKw.last) {
          expect(m, greaterThanOrEqualTo(kw));
          final idx = standardMotorKw.indexOf(m);
          if (idx > 0) expect(standardMotorKw[idx - 1], lessThan(kw));
          expect(motorOversizedFor(Power.kiloWatts(kw)), isFalse);
        } else {
          expect(m, standardMotorKw.last);
          expect(motorOversizedFor(Power.kiloWatts(kw)), isTrue);
        }
      }
    });
  });

  // ── fire-3-riser-count ────────────────────────────────────────────────────
  group('fire-3 drawn standpipe riser count', () {
    // Two separate hydrant stacks A / B (3 riser edges each) off one header.
    Network twoStacks() => Network(nodes: [
          _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
          _n('H', 50, 0),
          for (final s in ['A', 'B'])
            for (var f = 0; f < 4; f++) _n('$s$f', s == 'A' ? 100 : 300, 0,
                floor: f),
        ], edges: [
          const NetEdge(
              id: 'p', fromId: 'P', toId: 'H', service: ServiceType.fireHydrant),
          for (final s in ['A', 'B']) ...[
            NetEdge(
                id: 'h$s',
                fromId: 'H',
                toId: '${s}0',
                service: ServiceType.fireHydrant),
            for (var f = 0; f < 3; f++)
              NetEdge(
                  id: '$s$f',
                  fromId: '$s$f',
                  toId: '$s${f + 1}',
                  service: ServiceType.fireHydrant,
                  kind: EdgeKind.riser),
          ],
        ]);

    test('two stacks count 2; the flow is 500 + 250 gpm = 47.32 L/s', () {
      final n = drawnStandpipeRiserCount(twoStacks());
      expect(n, 2);
      // 750 gpm × 3.785411784 L/gal / 60 = 47.3176 L/s.
      expect(standpipeFlow(n).inLitersPerSecond,
          closeTo(750 * 3.785411784 / 60, 1e-9));
    });

    test('no hydrant riser drawn ⇒ the single-riser basis (1)', () {
      expect(drawnStandpipeRiserCount(const Network(nodes: [], edges: [])), 1);
    });
  });

  // ── fire-3-velocity ───────────────────────────────────────────────────────
  group('fire-3 fire velocity cap', () {
    // 5 L/s branch (5 OH heads): DN32 v = 0.005/8.0425e-4 = 6.22 > 6;
    // DN40 v = 0.005/1.2566e-3 = 3.98 ≤ 6 ⇒ DN40 (NFPA 13 pipe schedule's
    // 1-1/2 in for 5 OH heads). The domestic 2 m/s cap gave DN65.
    test('a 5 L/s sprinkler branch sizes DN40, cold water DN65', () {
      double dn(ServiceType s) => sizeEdge(
              NetEdge(id: 'e', fromId: 'a', toId: 'b', service: s),
              FlowRate.litersPerSecond(5),
              const SizingContext())
          .diameter
          .inMillimeters;
      expect(dn(ServiceType.fireSprinkler), closeTo(40, 1e-9));
      expect(dn(ServiceType.coldWater), closeTo(65, 1e-9));
    });

    // Property: every fire pipe's velocity is within the 6 m/s cap and the
    // next SMALLER standard size would exceed it (or hit the code floor).
    test('fire pipe = the smallest DN within 6 m/s (seeded property)', () {
      final rnd = math.Random(2110);
      const series = <double>[15, 20, 25, 32, 40, 50, 65, 80, 100, 125, 150, 200];
      for (var i = 0; i < 300; i++) {
        final lps = 0.2 + rnd.nextDouble() * 120;
        const e = NetEdge(
            id: 'e', fromId: 'a', toId: 'b', service: ServiceType.fireSprinkler);
        final r = sizeEdge(
            e, FlowRate.litersPerSecond(lps), const SizingContext());
        final d = r.diameter.inMillimeters;
        double v(double mm) => lps / 1000 / (math.pi * math.pow(mm / 1000, 2) / 4);
        if (!r.overCapacity) {
          expect(v(d), lessThanOrEqualTo(kMaxFireVelocityMps + 1e-9));
        }
        final idx = series.indexOf(d);
        if (idx > 0 && series[idx - 1] >= 25) {
          expect(v(series[idx - 1]), greaterThan(kMaxFireVelocityMps));
        }
      }
    });
  });

  // ── electrical plan length format ─────────────────────────────────────────
  test('electrical plan route labels use the one 0.1 m format', () {
    final data = buildElectricalPlanData(
      project: const ElectricalProject(
        id: 'p',
        name: 'p',
        panels: [
          ElectricalPanel(
            id: 'mdp',
            name: 'MDP',
            layoutPos:
                LayoutPos(sheetId: 's1', floorIndex: 0, x: 100, y: 100),
            circuits: [
              ElectricalCircuit(
                  id: 'c',
                  name: 'GP',
                  loadW: 1000,
                  loadPos: LayoutPos(
                      sheetId: 's1', floorIndex: 0, x: 400, y: 100)),
            ],
          ),
        ],
      ),
      sheetId: 's1',
      floorIndex: 0,
      calibrations: const {'s1': ScaleCalibration(0.02)},
      building: const BuildingLevels([Floor('L0', Length(3.5))]),
    );
    // 300 px × 0.02 m/px = 6.0 m ⇒ '6.0 m' (never '6 m').
    expect(data.routes.map((r) => r.label), contains('6.0 m'));
  });

  // ── bom-quote-1 ───────────────────────────────────────────────────────────
  group('bom-quote-1 cable family never substituted', () {
    test('an FRC run beyond the FRC catalogue stays FRC on its own key', () {
      final parts = fullCatalog();
      final maxFrc = parts
          .where((p) => p.category == PartCategory.cable && p.cableType == 'FRC')
          .map((p) => p.csaMm2!)
          .reduce(math.max);
      final sys = computeSystem(
        _profile,
        const ElectricalProject(
          id: 'p',
          name: 'p',
          earthingSystem: EarthingSystem.tnCs,
          panels: [
            ElectricalPanel(id: 'mdp', name: 'MDP', voltage: Voltage(400),
                circuits: [
              ElectricalCircuit(
                id: 'fp',
                name: 'Fire pump',
                loadKind: LoadKind.pump,
                loadW: 220000,
                motorKw: 200,
                cosPhi: 0.85,
                length: Length(40),
                cableType: 'FRC',
                lifeSafety: true,
              ),
            ]),
          ],
        ),
      );
      final c = sys.panels['mdp']!.circuits.single;
      // Precondition: the sized section exceeds every FRC part.
      expect(c.cable.csaMm2, greaterThan(maxFrc));
      final cable = elec
          .buildPanelBom(sys.panels['mdp']!, parts: parts)
          .firstWhere((l) => l.category == PartCategory.cable);
      expect(cable.sku, isNull);
      expect(cable.priceKey, startsWith('elec:cable:FRC:'));
      expect(cable.description, contains('FRC'));
    });
  });

  // ── bom-quote-2 ───────────────────────────────────────────────────────────
  test('bom-quote-2: an uncalibrated run is counted, never a measured 0 m', () {
    // Two DN32 runs of 1000 px: s1 at 0.05 m/px (= 50 m), s2 uncalibrated.
    final net = Network(nodes: [
      _n('a', 0, 0),
      _n('b', 1000, 0),
      _n('c', 0, 0, sheet: 's2'),
      _n('d', 1000, 0, sheet: 's2'),
    ], edges: const [
      NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      NetEdge(id: 'e2', fromId: 'c', toId: 'd', service: ServiceType.coldWater),
    ]);
    final bom = buildBom(
      net: net,
      sizing: {
        'e1': _sz('e1', ServiceType.coldWater, 32),
        'e2': _sz('e2', ServiceType.coldWater, 32),
      },
      calibrationBySheet: const {'s1': ScaleCalibration(0.05)},
      building: const BuildingLevels([Floor('L0', Length(3.5))]),
    );
    final line = bom.single;
    expect(line.totalLength.meters, closeTo(50, 1e-9));
    expect(line.segmentCount, 2);
    expect(line.unmeasuredSegments, 1);
    final est = estimateMechanicalCost(
        pipes: bom, fittings: const [], priceList: const {});
    expect(est.lines.single.unmeasuredSegments, 1);
    expect(est.lines.single.description, contains('1 of 2 runs unmeasured'));
  });

  // ── bom-quote-3 ───────────────────────────────────────────────────────────
  test('bom-quote-3: valves + heads are taken off; an inline head is a tee',
      () {
    // p → gate valve q → r → inline head h → end head t (sprinkler).
    final net = Network(nodes: [
      _n('p', 0, 0, role: NodeRole.plant),
      _n('q', 100, 0, c: NodeComponent.gateValve),
      _n('r', 200, 0),
      _n('h', 300, 0, role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
      _n('t', 400, 0, role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
    ], edges: const [
      NetEdge(id: 'e1', fromId: 'p', toId: 'q', service: ServiceType.fireSprinkler),
      NetEdge(id: 'e2', fromId: 'q', toId: 'r', service: ServiceType.fireSprinkler),
      NetEdge(id: 'e3', fromId: 'r', toId: 'h', service: ServiceType.fireSprinkler),
      NetEdge(id: 'e4', fromId: 'h', toId: 't', service: ServiceType.fireSprinkler),
    ]);
    final sizing = {
      'e1': _sz('e1', ServiceType.fireSprinkler, 50),
      'e2': _sz('e2', ServiceType.fireSprinkler, 50),
      'e3': _sz('e3', ServiceType.fireSprinkler, 32),
      'e4': _sz('e4', ServiceType.fireSprinkler, 25),
    };
    final comps = buildComponentTakeoff(net: net, sizing: sizing);
    String row(ComponentLine c) =>
        '${c.component.name} ${c.sizeLabel} x${c.count}';
    expect(comps.map(row).toSet(), {
      'gateValve DN50 x1',
      'sprinklerHead DN32 x1', // inline head: largest incident DN32
      'sprinklerHead DN25 x1',
    });
    final fittings = buildFittings(net: net, sizing: sizing);
    expect(
        fittings.any((f) => f.type == FittingType.tee && f.diameterMm == 32),
        isTrue,
        reason: 'the inline head h sits on a reducing tee');
    final est = estimateMechanicalCost(
        pipes: const [], fittings: const [], components: comps,
        priceList: {
          mechComponentKey(
              ServiceType.fireSprinkler, NodeComponent.gateValve, 'DN50'): 1e6,
        });
    // 1 × 1 000 000 priced; the two heads unpriced (counted, never 0).
    expect(est.grandTotal, 1e6);
    expect(est.unpricedCount, 2);
    // Labour: 3 components × 0.5 h.
    expect(
        mechanicalLabourHours(
            pipes: const [], fittings: const [], components: comps),
        closeTo(3 * mechInstallHoursPerComponent, 1e-9));
  });

  // ── bom-quote-4 / 5 ───────────────────────────────────────────────────────
  group('bom-quote-4/5 advanced BOM', () {
    const project = ElectricalProject(
      id: 'p',
      name: 'p',
      earthingSystem: EarthingSystem.tnCs,
      soilResistivityOhmM: 100,
      sources: const ElectricalSources(generator: GeneratorSource()),
      panels: const [
        ElectricalPanel(id: 'mdp', name: 'MDP', voltage: Voltage(400),
            circuits: [
          ElectricalCircuit(
            id: 'pump',
            name: 'Pump',
            loadKind: LoadKind.motor,
            loadW: 25000,
            motorKw: 22,
            cosPhi: 0.85,
            length: Length(20),
            starterType: StarterType.starDelta,
          ),
          ElectricalCircuit(id: 'f', name: 'LP feed', feedsPanelId: 'lp'),
        ]),
        ElectricalPanel(id: 'lp', name: 'LP', voltage: Voltage(400),
            circuits: [
          ElectricalCircuit(
              id: 'l', name: 'Lights', loadKind: LoadKind.lighting,
              loadW: 2000),
        ]),
      ],
    );
    final sys = computeSystem(_profile, project);
    final adv = computeAdvancedStudy(_profile, project, sys);

    test('each enclosure prices at its own W x H x D', () {
      final enc = adv.bom.lines
          .where((l) => l.category == PartCategory.enclosure)
          .toList();
      expect(enc.length, adv.enclosure.length);
      for (final e in adv.enclosure.values) {
        final dims = '${e.widthMm.round()}x${e.heightMm.round()}x'
            '${e.depthMm.round()}';
        expect(enc.any((l) => l.priceKey == 'elec:enclosure:$dims'), isTrue);
      }
      // A legacy bare price still prices a sized enclosure.
      final cost = estimateCost(adv.bom, const {'elec:enclosure': 1000});
      final encCost = cost.lines
          .where((l) => l.line.category == PartCategory.enclosure);
      expect(encCost.every((l) => l.matched), isTrue);
    });

    test('control gear, genset + ATS, SPD and earthing reach the BOM', () {
      final keys = {for (final l in adv.bom.lines) l.priceKey ?? ''};
      expect(keys.any((k) => k.startsWith('elec:control:contactor')), isTrue);
      expect(keys.any((k) => k.startsWith('elec:genset:')), isTrue);
      expect(keys.any((k) => k.startsWith('elec:transfer:ats:')), isTrue);
      expect(keys.any((k) => k.startsWith('elec:spd:')), isTrue);
      expect(keys.any((k) => k.startsWith('elec:earth-rod:')), isTrue);
      expect(keys.any((k) => k.startsWith('elec:earthing:bc:')), isTrue);
      // The rods: the designed count.
      final rods = adv.bom.lines
          .firstWhere((l) => (l.priceKey ?? '').startsWith('elec:earth-rod:'));
      expect(rods.qty, adv.electrode!.rodCount.toDouble());
    });
  });

  // ── bom-quote-6 ───────────────────────────────────────────────────────────
  test('bom-quote-6: rect fittings key on W x H; a W x H change is a '
      'transition; the CSV carries material', () {
    // a —600x300— b —600x300— c —500x350— d, turning at b, straight at c
    // (equivalent ≈ 457 mm on all three).
    final net = Network(nodes: [
      _n('a', 0, 0),
      _n('b', 100, 0),
      _n('c', 100, 100),
      _n('d', 100, 200),
    ], edges: const [
      NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.duct),
      NetEdge(id: 'e2', fromId: 'b', toId: 'c', service: ServiceType.duct),
      NetEdge(id: 'e3', fromId: 'c', toId: 'd', service: ServiceType.duct),
    ]);
    final sizing = {
      'e1': _sz('e1', ServiceType.duct, 457, w: 600, h: 300),
      'e2': _sz('e2', ServiceType.duct, 457, w: 600, h: 300),
      'e3': _sz('e3', ServiceType.duct, 457, w: 500, h: 350),
    };
    final f = buildFittings(net: net, sizing: sizing);
    final elbow = f.firstWhere((l) => l.type == FittingType.elbow);
    expect(elbow.sizeLabel, '600x300');
    expect(
        mechFittingKey(elbow.service, elbow.type, elbow.diameterMm,
            material: elbow.material,
            widthMm: elbow.widthMm,
            heightMm: elbow.heightMm),
        'mech:fitting:duct:elbow:PU:600x300');
    expect(f.where((l) => l.type == FittingType.reducer), hasLength(1));
    final csv = fittingsToCsv(f).split('\n');
    expect(csv.first, 'service,fitting,nominal_size_mm,material,count');
    expect(csv, contains('duct,elbow,600x300,PU,1'));
  });

  // ── riser-drafting-2-6 ────────────────────────────────────────────────────
  group('riser-drafting-2-6 gravity stack datum', () {
    // 8 floors × 3.6 m, default 0.3 m ceiling offset.
    final b = BuildingLevels(
        [for (var i = 0; i < 8; i++) Floor('L$i', const Length(3.6))]);
    Length len(NetNode a, NetNode z, ServiceType s) => edgeLength(
        NetEdge(id: 'e', fromId: a.id, toId: z.id, service: s,
            kind: EdgeKind.riser),
        Network(nodes: [a, z], edges: const []),
        calibrationBySheet: const {},
        building: b);

    test('stack: base 3.3 m, every storey 3.6 m, top junction under L7 slab',
        () {
      final co = _n('co', 0, 0, role: NodeRole.fixture, c: NodeComponent.cleanout);
      final s = [for (var f = 0; f < 8; f++) _n('s$f', 0, 0, floor: f)];
      // cleanout on L0 surface (0.0) → L1 junction under the L1 slab
      // = 3.6 − 0.3 = 3.3 m (was 6.9 m from the L1 ceiling).
      expect(len(co, s[1], ServiceType.drainage).meters, closeTo(3.3, 1e-9));
      for (var f = 1; f < 7; f++) {
        expect(len(s[f], s[f + 1], ServiceType.drainage).meters,
            closeTo(3.6, 1e-9));
      }
      // The L7 junction: 7 × 3.6 − 0.3 = 24.9 m.
      expect(gravityRiserEndElevation(s[7], b).meters, closeTo(24.9, 1e-9));
      // A pressurized riser between the same junctions keeps the ceiling datum.
      expect(len(s[1], s[2], ServiceType.coldWater).meters, closeTo(3.6, 1e-9));
    });

    test('a rainwater downpipe foot sits at grade', () {
      final foot = _n('rh0', 0, 0);
      final r1 = _n('rh1', 0, 0, floor: 1);
      // L1 junction 3.3 m − grade 0.0 = 3.3 m (the exit leg used to stop at
      // the ground ceiling, 3.3 m above grade).
      expect(gravityRiserEndElevation(foot, b).meters, 0.0);
      expect(len(foot, r1, ServiceType.rainwater).meters, closeTo(3.3, 1e-9));
    });

    // Round 21 follow-up: the inspector readout and the hover FFL chip share
    // ONE helper, so a bare stack junction shows the datum its riser is
    // measured from, and a node on no gravity riser keeps nodeElevation.
    test('displayedNodeElevation follows the gravity riser datum', () {
      final s1 = _n('s1', 0, 0, floor: 1);
      final s2 = _n('s2', 0, 0, floor: 2);
      final net = Network(nodes: [s1, s2], edges: const [
        NetEdge(id: 'st', fromId: 's1', toId: 's2',
            service: ServiceType.drainage, kind: EdgeKind.riser),
      ]);
      expect(displayedNodeElevation(net, s1, b).meters,
          gravityRiserEndElevation(s1, b).meters);
      expect(displayedNodeElevation(net, s1, b).meters, closeTo(3.3, 1e-9));
      final cw = Network(nodes: [s1, s2], edges: const [
        NetEdge(id: 'c', fromId: 's1', toId: 's2',
            service: ServiceType.coldWater, kind: EdgeKind.riser),
      ]);
      expect(displayedNodeElevation(cw, s1, b).meters,
          nodeElevation(s1, b).meters);
    });
  });

  test('a component description never repeats the service word', () {
    expect(mechComponentDescription(
            ServiceType.coldWater, NodeComponent.waterOutlet),
        'Cold water outlet');
    // No shared word at the seam: both labels print in full.
    expect(
        mechComponentDescription(ServiceType.coldWater, NodeComponent.gateValve),
        'Cold water ${NodeComponent.gateValve.label}');
  });

  test('a riser length reads the same datum as edgeLength', () {
    final b = BuildingLevels(
        [for (var i = 0; i < 3; i++) Floor('L$i', const Length(3.6))]);
    const a = NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 0);
    const c = NetNode(id: 'c', sheetId: 's', x: 0, y: 0, floorIndex: 2);
    for (final svc in [ServiceType.drainage, ServiceType.coldWater]) {
      final e = NetEdge(
          id: 'r', fromId: 'a', toId: 'c', service: svc, kind: EdgeKind.riser);
      final net = Network(nodes: [a, c], edges: [e]);
      expect(
          riserElevationDelta(e, a, c, b).meters,
          edgeLength(e, net, calibrationBySheet: const {}, building: b)
              .meters,
          reason: svc.name);
    }
  });
}
