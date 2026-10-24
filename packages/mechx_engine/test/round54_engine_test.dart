// Round 54 (2026-10-18) — engine pins for the fire-network sizer:
//
//   regression-cross-service-fire-flow-depends-on-drawn-direction — a fire
//     fragment with no plant of its own (a combined riser drawn as sprinkler
//     pipe off a hydrant pump discharge) roots where it joins the fire
//     network nearest a source (`fireSourceHops`), never at the leaf it was
//     drawn from: flipping any fire pipe never changes a size or a flow.
//   regression-hydrant-standpipe-flow-lost-on-sprinkler-drawn-riser — every
//     fire pipe of a hydrant-bearing system carrying hydrant demand below it
//     is a standpipe trunk candidate whatever service it was drawn on.
//   regression-source-edge-override-above-caller-hydrant-flow — the caller's
//     `hydrantDesignFlow` caps the shared suction header too.
//   regression-cross-service-pass-skips-unoriented-and-mixed-ring — a ring
//     closed through sprinkler-drawn arms is a hydrant ring.
//   regression-tt-rcd-touch-voltage-judge-dead — Ra x IΔn <= 50 V judged on
//     the DESIGNED electrode (`designElectrode`), never the 5 ohm target.
//   elec-convergence-6-mcb-class-swap-creates-ads-failure — the MCB -> MCCB
//     class rule never creates an ADS failure the load-sized MCB did not have
//     (MCCB judged at 10 x In, a B-curve MCB at 5 x In).
//
// First principles: 1 US gpm = 3.785411784 / 60 L/s; 500 gpm = 31.545 L/s
// (one stack, SNI 03-1745 / NFPA 14), 750 gpm = 47.318 L/s (two stacks).
// DN100 at 31.5 L/s: v = Q / (pi d^2 / 4) = 0.031545 / 0.007854 = 4.0 m/s
// (inside the 6 m/s fire cap); DN65 would run 9.5 m/s.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/electrode.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _gpm = 3.785411784 / 60;

NetNode _n(String id, double x,
        {int floor = 0,
        double y = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.fireHydrant, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

BuildingLevels _floors(int n) => BuildingLevels(
    [for (var i = 0; i < n; i++) Floor('L$i', const Length(3.5))]);

Map<String, EdgeSizing> _size(Network net, BuildingLevels b,
        {FlowRate? sprinkler = const FlowRate(0.012), FlowRate? hydrant}) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.005),
        ServiceType.fireSprinkler: FlowRate(0.001),
      },
      sprinklerDemandCap: sprinkler,
      hydrantDesignFlow: hydrant ?? standpipeFlow(1),
      building: b,
    );

/// GT -> FP -> A on hydrant; the riser A-R0..R7 drawn as SPRINKLER; one
/// hydrant box per floor; 4 heads per floor on L0..L6. [topDown] draws every
/// riser edge from its upper node.
Network _combinedRiser(bool topDown) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('A', 20),
  ];
  final edges = <NetEdge>[_e('g', 'GT', 'FP'), _e('d', 'FP', 'A')];
  for (var k = 0; k < 8; k++) {
    nodes.add(_n('R$k', 30, floor: k));
    nodes.add(_n('B$k', 40,
        floor: k, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges.add(_e('b$k', 'R$k', 'B$k'));
    final prev = k == 0 ? 'A' : 'R${k - 1}';
    final id = k == 0 ? 'a0' : 'r$k';
    final kind = k == 0 ? EdgeKind.run : EdgeKind.riser;
    edges.add(topDown
        ? _e(id, 'R$k', prev, s: ServiceType.fireSprinkler, k: kind)
        : _e(id, prev, 'R$k', s: ServiceType.fireSprinkler, k: kind));
    if (k < 7) {
      for (var j = 0; j < 4; j++) {
        nodes.add(_n('H${k}_$j', 50.0 + j * 5,
            floor: k, role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
        edges.add(
            _e('h${k}_$j', 'R$k', 'H${k}_$j', s: ServiceType.fireSprinkler));
      }
    }
  }
  return Network(nodes: nodes, edges: edges);
}

/// A 10-floor hydrant stack rising from [base] (risers + a box per floor).
void _stack(String tag, String base, double x, List<NetNode> nodes,
    List<NetEdge> edges) {
  var prev = base;
  for (var f = 1; f < 10; f++) {
    final id = '$tag$f';
    nodes.add(_n(id, x, floor: f));
    edges.add(_e('${tag}r$f', prev, id, k: EdgeKind.riser));
    nodes.add(_n('${tag}B$f', x + 5,
        floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges.add(_e('${tag}b$f', id, '${tag}B$f'));
    prev = id;
  }
}

/// FP -> J1; J1-J2, J2-J3 hydrant; J3-J4, J4-J1 [sprinklerArms] or hydrant;
/// a stack at J2 and at J3. [a34From] / [a41From] pick the drawn direction.
Network _ring(
    {bool sprinklerArms = true, String a34From = 'J3', String a41From = 'J4'}) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('J1', 20),
    _n('J2', 60),
    _n('J3', 60, y: 40),
    _n('J4', 20, y: 40),
  ];
  final arm =
      sprinklerArms ? ServiceType.fireSprinkler : ServiceType.fireHydrant;
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('f', 'FP', 'J1'),
    _e('a12', 'J1', 'J2'),
    _e('a23', 'J2', 'J3'),
    _e('a34', a34From, a34From == 'J3' ? 'J4' : 'J3', s: arm),
    _e('a41', a41From, a41From == 'J4' ? 'J1' : 'J4', s: arm),
  ];
  _stack('S', 'J2', 70, nodes, edges);
  _stack('T', 'J3', 90, nodes, edges);
  return Network(nodes: nodes, edges: edges);
}

void main() {
  group('combined riser drawn as sprinkler pipe', () {
    final b = _floors(8);
    test(
        'both drawing directions size the pump train identically, at the '
        '500 gpm standpipe flow on DN100', () {
      final top = _size(_combinedRiser(true), b);
      final up = _size(_combinedRiser(false), b);
      for (final id in ['g', 'd', 'a0', 'r1', 'r4', 'r7']) {
        expect(top[id]!.flow.cubicMetersPerSecond,
            closeTo(up[id]!.flow.cubicMetersPerSecond, 1e-12),
            reason: id);
        expect(top[id]!.diameter.inMillimeters, up[id]!.diameter.inMillimeters,
            reason: id);
        expect(top[id]!.flowFromId, up[id]!.flowFromId, reason: id);
        // 500 gpm = 31.545 L/s on every trunk of the one stack.
        expect(top[id]!.flow.inLitersPerSecond, closeTo(500 * _gpm, 1e-3),
            reason: id);
        expect(top[id]!.diameter.inMillimeters, greaterThanOrEqualTo(100),
            reason: id);
      }
      // The pump discharge flows away from the pump, the riser upward.
      expect(top['d']!.flowFromId, 'FP');
      expect(top['a0']!.flowFromId, 'A');
      expect(top['r1']!.flowFromId, 'R0');
    });

    test(
        'the sprinkler-drawn riser with boxes teed above its base counts as '
        'one standpipe stack; a sprinkler riser teed only at its base does '
        'not', () {
      expect(
          parallelStandpipeCount(
              _combinedRiser(false), _combinedRiser(false).edges),
          1);
      final net = Network(nodes: [
        _n('X', 0),
        _n('Y', 0, floor: 1),
        _n('Z', 10),
      ], edges: [
        _e('h', 'Z', 'X'),
        _e('s', 'X', 'Y', s: ServiceType.fireSprinkler, k: EdgeKind.riser),
      ]);
      expect(parallelStandpipeCount(net, net.edges), 0);
    });
  });

  group('hydrant ring closed through sprinkler arms', () {
    final b = _floors(10);
    final stacks2 = standpipeFlow(2).inLitersPerSecond; // 750 gpm
    test(
        '750 gpm = 47.318 L/s DN125 on every arm, whatever the arms\' '
        'service and drawn direction', () {
      expect(stacks2, closeTo(750 * _gpm, 1e-3));
      for (final net in [
        _ring(sprinklerArms: false),
        _ring(),
        _ring(a34From: 'J4'),
        _ring(a41From: 'J1'),
        _ring(a34From: 'J4', a41From: 'J1'),
      ]) {
        final r = _size(net, b, hydrant: standpipeFlow(2));
        for (final id in ['a12', 'a23', 'a34', 'a41']) {
          expect(r[id]!.flow.inLitersPerSecond, closeTo(stacks2, 1e-3),
              reason: id);
          expect(r[id]!.diameter.inMillimeters, 125, reason: id);
        }
      }
    });
  });

  group('shared suction header under an explicit hydrant design flow', () {
    test(
        'GT -> HD -> P1 (2 stacks) / P2 (1 stack) with hydrantDesignFlow = '
        '500 gpm: header == suction == discharge == 31.545 L/s', () {
      final nodes = <NetNode>[
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('HD', 10),
        _n('P1', 20, role: NodeRole.plant, c: NodeComponent.pump),
        _n('P2', 20, y: 50, role: NodeRole.plant, c: NodeComponent.pump),
        _n('T1', 30),
        _n('T2', 30, y: 50),
      ];
      final edges = <NetEdge>[
        _e('gh', 'GT', 'HD'),
        _e('s1', 'HD', 'P1'),
        _e('s2', 'HD', 'P2'),
        _e('d1', 'P1', 'T1'),
        _e('d2', 'P2', 'T2'),
      ];
      nodes.addAll([_n('T1a', 40), _n('T1b', 40, y: 20)]);
      edges.addAll([_e('t1a', 'T1', 'T1a'), _e('t1b', 'T1', 'T1b')]);
      _stack('A', 'T1a', 50, nodes, edges);
      _stack('B', 'T1b', 60, nodes, edges);
      _stack('C', 'T2', 70, nodes, edges);
      final r = _size(Network(nodes: nodes, edges: edges), _floors(10),
          sprinkler: null, hydrant: standpipeFlow(1));
      for (final id in ['gh', 's1', 'd1', 's2', 'd2']) {
        expect(r[id]!.flow.inLitersPerSecond, closeTo(500 * _gpm, 1e-3),
            reason: id);
      }
    });
  });

  test(
      'seeded property: 200 random mixed hydrant / sprinkler fire trees '
      '(pump at the root) — flipping any fire pipe and shuffling the edge '
      'order never changes any fire pipe\'s size, flow or flow direction', () {
    final b = _floors(6);
    for (var seed = 0; seed < 200; seed++) {
      final rnd = math.Random(seed);
      final nodes = <NetNode>[
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FP', 5, role: NodeRole.plant, c: NodeComponent.pump),
      ];
      final edges = <NetEdge>[_e('g', 'GT', 'FP')];
      final open = <NetNode>[nodes[1]];
      final count = 6 + rnd.nextInt(20);
      for (var i = 0; i < count; i++) {
        final parent = open[rnd.nextInt(open.length)];
        final svc = rnd.nextBool()
            ? ServiceType.fireHydrant
            : ServiceType.fireSprinkler;
        final up = rnd.nextInt(4) == 0 && parent.floorIndex < 5;
        final floor = up ? parent.floorIndex + 1 : parent.floorIndex;
        final terminal = rnd.nextInt(3) == 0;
        final id = 'N$i';
        final node = terminal
            ? _n(id, parent.x + 5,
                y: i.toDouble(),
                floor: floor,
                role: NodeRole.fixture,
                c: svc == ServiceType.fireHydrant
                    ? NodeComponent.hydrantBox
                    : NodeComponent.sprinklerHead)
            : _n(id, parent.x + 5, y: i.toDouble(), floor: floor);
        nodes.add(node);
        if (!terminal) open.add(node);
        edges.add(_e('e$i', parent.id, id,
            s: svc, k: up ? EdgeKind.riser : EdgeKind.run));
      }
      final base = _size(Network(nodes: nodes, edges: edges), b);
      final flipped = [
        for (final e in edges)
          rnd.nextBool()
              ? NetEdge(
                  id: e.id,
                  fromId: e.toId,
                  toId: e.fromId,
                  service: e.service,
                  kind: e.kind)
              : e,
      ]..shuffle(rnd);
      final other =
          _size(Network(nodes: [...nodes]..shuffle(rnd), edges: flipped), b);
      for (final e in edges) {
        final x = base[e.id], y = other[e.id];
        expect(x == null, y == null, reason: 'seed $seed ${e.id}');
        if (x == null || y == null) continue;
        expect(y.flow.cubicMetersPerSecond,
            closeTo(x.flow.cubicMetersPerSecond, 1e-9),
            reason: 'seed $seed ${e.id} flow');
        expect(y.diameter.inMillimeters, x.diameter.inMillimeters,
            reason: 'seed $seed ${e.id} size');
        expect(y.flowFromId, x.flowFromId, reason: 'seed $seed ${e.id} from');
      }
    }
  });

  group('TT RCD touch voltage judged on the designed electrode', () {
    ElectricalCircuit feeder(String id, String to) => ElectricalCircuit(
        id: id,
        name: id,
        loadKind: LoadKind.feeder,
        length: const Length(15),
        feedsPanelId: to);
    ElectricalProject project(double? soil) => ElectricalProject(
          id: 'p',
          name: 'TT',
          earthingSystem: EarthingSystem.tt,
          soilResistivityOhmM: soil,
          panels: [
            ElectricalPanel(
                id: 'MDP',
                name: 'MDP',
                voltage: const Voltage(400),
                circuits: [feeder('fS', 'SDB')]),
            ElectricalPanel(
                id: 'SDB',
                name: 'SDB',
                voltage: const Voltage(400),
                circuits: [feeder('fSS', 'SSB')]),
            ElectricalPanel(
                id: 'SSB',
                name: 'SSB',
                voltage: const Voltage(400),
                circuits: [feeder('fD', 'DB')]),
            const ElectricalPanel(
                id: 'DB',
                name: 'DB',
                voltage: Voltage(400),
                circuits: [
                  ElectricalCircuit(
                      id: 'l1',
                      name: 'Lighting',
                      loadKind: LoadKind.lighting,
                      loadW: 800,
                      length: Length(20)),
                  ElectricalCircuit(
                      id: 's1',
                      name: 'Sockets',
                      loadKind: LoadKind.socket,
                      loadW: 1800,
                      length: Length(20)),
                ]),
          ],
        );
    const profile = PuilProfile();
    List<ElectricalWarning> touch(double? soil) {
      final pr = project(soil);
      final sys = computeSystem(profile, pr);
      return computeAdvancedStudy(profile, pr, sys).warnings;
    }

    test(
        'soil 3000 ohm-m: every RCD way whose IΔn x the achieved Ra > 50 V '
        'is named — the MDP feeder included', () {
      final pr = project(3000);
      final sys = computeSystem(profile, pr);
      final ra = designElectrode(soilResistivityOhmM: 3000).achieved.ohms;
      expect(ra, greaterThan(5));
      final expected = <String>{
        for (final p in sys.panels.values)
          for (final c in p.circuits)
            if (c.rcd.required && ra * c.rcd.ratingMa / 1000 > 50) c.circuitId,
      };
      final got = {
        for (final w in computeAdvancedStudy(profile, pr, sys).warnings)
          if (w.code == 'tt-rcd-touch-voltage') w.circuitId,
      };
      expect(got, expected);
      expect(got, contains('fS'));
      final mdpRcd = sys.panels['MDP']!.circuits.single.rcd.ratingMa;
      expect(ra * mdpRcd / 1000, greaterThan(50));
    });

    test(
        'soil 50 ohm-m: no touch-voltage warning; no soil: one INFO saying '
        'the condition is unverified', () {
      expect(touch(50).where((w) => w.code == 'tt-rcd-touch-voltage'), isEmpty);
      final none = touch(null);
      expect(none.where((w) => w.code == 'tt-rcd-touch-voltage'), isEmpty);
      final info = none.where((w) => w.code == 'tt-earth-fault-unchecked');
      expect(info, hasLength(1));
      expect(info.single.severity, WarningSeverity.info);
    });
  });

  group(
      'MCB -> MCCB class change on a high-fault bus never creates an ADS '
      'failure', () {
    const profile = PuilProfile();
    ElectricalProject hotel(
            {double loadW = 6000,
            double lengthM = 60,
            int phases = 3,
            double txKva = 1600,
            bool lifeSafety = true,
            LoadKind kind = LoadKind.lighting}) =>
        ElectricalProject(
          id: 'h',
          name: 'Hotel',
          earthingSystem: EarthingSystem.tnS,
          transformerKva: ApparentPower(txKva * 1000),
          panels: [
            const ElectricalPanel(
              id: 'LV',
              name: 'LVMDP',
              voltage: Voltage(400),
              circuits: [
                ElectricalCircuit(
                    id: 'f',
                    name: 'SDP-E feeder',
                    loadKind: LoadKind.feeder,
                    length: Length(15),
                    cableOverrideMm2: 300,
                    feedsPanelId: 'SDP'),
              ],
            ),
            ElectricalPanel(
              id: 'SDP',
              name: 'SDP-E',
              voltage: const Voltage(400),
              circuits: [
                ElectricalCircuit(
                    id: 'el',
                    name: 'Emergency lighting',
                    loadKind: kind,
                    loadW: loadW,
                    phases: phases,
                    lifeSafety: lifeSafety,
                    length: Length(lengthM)),
              ],
            ),
          ],
        );

    // Every non-overridden final MCCB <= 63 A that fails ADS must ALSO fail
    // as the load-sized MCB: the MCCB limit is judged at max(10, curve) x In
    // (`kMccbMagneticTripMultiple`), the MCB limit at the curve multiple, so
    // Zs_max(MCB) = Zs_max(MCCB) x max(10, m) / m.
    void expectNoClassCreatedAds(ElectricalProject pr, String why) {
      final sys = computeSystem(profile, pr,
          originFaultLevel: estimatedServiceFaultLevelA(pr));
      final f = faultStudy(sys, pr, profile,
          originFaultLevel: estimatedServiceFaultLevelA(pr)!);
      for (final p in sys.panels.values) {
        for (final w in p.circuits) {
          if (w.loadKind == LoadKind.feeder) continue;
          final c = f.circuits[w.circuitId];
          if (c == null || c.adsOk != false || c.adsByRcd) continue;
          final b = w.breaker;
          if (b.deviceClass != BreakerClass.mccb ||
              b.overridden ||
              b.ratingA.amperes > 63) {
            continue;
          }
          final m = curveTripMultiple[b.curve] ?? kMccbMagneticTripMultiple;
          final mcbLimit =
              c.zsMaxOhm! * math.max(kMccbMagneticTripMultiple, m) / m;
          expect(c.zsOhm!, greaterThan(mcbLimit - 1e-9),
              reason: '$why ${w.name}: an MCB would pass ADS');
        }
      }
    }

    test(
        'the hotel SDP-E emergency lighting way (16 A, 60 m, 1600 kVA '
        'service): kept as an MCB, no ads-disconnection error, a back-up '
        'note instead', () {
      final pr = hotel();
      final fault = estimatedServiceFaultLevelA(pr)!;
      // Isc = 1600e3 / (sqrt3 x 400 x 0.04) = 57.7 kA, above the MCB top.
      expect(fault.amperes, closeTo(1600e3 / (math.sqrt(3) * 400 * 0.04), 1));
      final sys = computeSystem(profile, pr, originFaultLevel: fault);
      final way = sys.panels['SDP']!.circuits.single;
      expect(way.breaker.deviceClass, BreakerClass.mcb);
      final f = faultStudy(sys, pr, profile, originFaultLevel: fault);
      expect(f.circuits['el']!.adsOk, isTrue);
      final codes = {
        for (final w in [...sys.warnings, ...f.warnings])
          if (w.circuitId == 'el') w.code,
      };
      expect(codes, isNot(contains('ads-disconnection')));
      expect(codes, contains('mcb-backup-protection-required'));
    });

    test(
        'seeded property: 200 random final ways on the high-fault SDP — the '
        'class rule never adds an ADS failure the MCB did not have', () {
      final rnd = math.Random(54);
      for (var i = 0; i < 200; i++) {
        final pr = hotel(
          loadW: 500 + rnd.nextDouble() * 12000,
          lengthM: 10 + rnd.nextDouble() * 120,
          phases: rnd.nextBool() ? 3 : 1,
          txKva: const [1000.0, 1250.0, 1600.0, 2000.0][rnd.nextInt(4)],
          lifeSafety: rnd.nextBool(),
          kind: [
            LoadKind.lighting,
            LoadKind.socket,
            LoadKind.general
          ][rnd.nextInt(3)],
        );
        expectNoClassCreatedAds(pr, 'trial $i');
      }
    });
  });
}
