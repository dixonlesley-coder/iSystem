// Round-7 property audit — mechanical sizing/solve fixes, each pinned by the
// finding's counterexample AND turned into a seeded property where it fits:
//   mech-props-1  looped water: a bridge (dead-end branch) carries curve(its own
//                 far-side UBAP), never a share of the ring total;
//   mech-props-2 / mech-building-1  root choice is deterministic + physical, a
//                 plant leaf bears no phantom demand (edge-order invariance);
//   mech-props-3  ring pump head = the governing oriented path, edge-order
//                 invariant;
//   mech-props-4  Hardy–Cross convergence verdict is edge-order invariant;
//   mech-props-6  a demand-free duct ring no longer aborts the solve;
//   mech-building-3  a vent stack sizes on the DFU it vents;
//   mech-building-6  a dual-supply fixture loads 3/4 of its UBAP per supply;
//   mech-building-5  a hydrant riser carries the standpipe design flow;
//   mech-building-2  the upfeed fixture over-pressure check.
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/hardy_cross.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = SniProfile();
double _curve(double ubap) =>
    _profile.probableFlowForFixtureUnits(ubap).cubicMetersPerSecond;

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component,
        PlumbingFixture? fixture}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: role,
      component: component,
      fixture: fixture,
    );

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

List<T> _shuffled<T>(List<T> xs, int seed) =>
    [...xs]..shuffle(math.Random(seed));

void main() {
  group('mech-props-1 — looped water bridges carry curve(own far-side UBAP)',
      () {
    // Pump P — A, ring A-B-C-D(-A), 4 apartment branches of 8 UBAP off each of
    // B, C and D (12 × 8 = 96 UBAP).
    Network build({required bool closeRing}) {
      final nodes = <NetNode>[
        _n('P', 0, 0, role: NodeRole.plant, component: NodeComponent.pump),
        _n('A', 0, 100),
        _n('B', 2000, 100),
        _n('C', 2000, 600),
        _n('D', 0, 600),
      ];
      final edges = <NetEdge>[
        _e('pa', 'P', 'A', ServiceType.coldWater),
        _e('ab', 'A', 'B', ServiceType.coldWater),
        _e('bc', 'B', 'C', ServiceType.coldWater),
        _e('cd', 'C', 'D', ServiceType.coldWater),
        if (closeRing) _e('da', 'D', 'A', ServiceType.coldWater),
      ];
      var i = 0;
      for (final hub in ['B', 'C', 'D']) {
        for (var k = 0; k < 4; k++) {
          final f = 'f$i';
          nodes.add(_n(f, 3000.0 + 10 * i, 100.0 * k, role: NodeRole.fixture));
          edges.add(_e('br$i', hub, f, ServiceType.coldWater));
          i++;
        }
      }
      return Network(nodes: nodes, edges: edges);
    }

    Map<String, EdgeSizing> size(Network net) => autoSizeNetwork(
          net,
          const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 2.0},
          nodeFixtureUnits: {for (var i = 0; i < 12; i++) 'f$i': 8.0},
        );

    test('closing the ring leaves every branch at curve(8) = 0.400 L/s', () {
      final tree = size(build(closeRing: false));
      final ring = size(build(closeRing: true));
      // Tree path: br0 carries curve(8) (flush-tank Gambar 1 segment
      // 0→10 UBAP: 8/10 × 0.5 L/s = 0.400 L/s).
      expect(_curve(8), closeTo(0.0004, 1e-12));
      for (var i = 0; i < 12; i++) {
        expect(
            tree['br$i']!.flow.cubicMetersPerSecond, closeTo(_curve(8), 1e-12));
        expect(
            ring['br$i']!.flow.cubicMetersPerSecond, closeTo(_curve(8), 1e-12),
            reason: 'br$i must not drop to the 8/96 share of the ring total');
        expect(ring['br$i']!.diameter.inMillimeters,
            tree['br$i']!.diameter.inMillimeters);
        // ...and therefore stays under the 2.0 m/s cap.
        expect(ring['br$i']!.velocity.metersPerSecond, lessThanOrEqualTo(2.0));
      }
      // The feed bridge P-A carries the diversified TOTAL: curve(96).
      expect(ring['pa']!.flow.cubicMetersPerSecond, closeTo(_curve(96), 1e-12));
    });

    test('property: every dead-end branch of a random ring = curve(its UBAP)',
        () {
      for (var seed = 0; seed < 40; seed++) {
        final rnd = math.Random(seed);
        final ringN = 3 + rnd.nextInt(5);
        final nodes = <NetNode>[
          _n('P', -100, 0, role: NodeRole.plant, component: NodeComponent.pump),
        ];
        final edges = <NetEdge>[_e('feed', 'P', 'r0', ServiceType.coldWater)];
        for (var r = 0; r < ringN; r++) {
          final a = 2 * math.pi * r / ringN;
          nodes.add(_n('r$r', 1000 * math.cos(a), 1000 * math.sin(a)));
          edges.add(_e(
              'ring$r', 'r$r', 'r${(r + 1) % ringN}', ServiceType.coldWater));
        }
        final ubap = <String, double>{};
        var b = 0;
        for (var r = 0; r < ringN; r++) {
          for (var k = rnd.nextInt(4); k > 0; k--) {
            final f = 'f$b';
            ubap[f] = 1.0 + rnd.nextInt(40);
            nodes.add(_n(f, 2000.0 + b, 50.0 * b, role: NodeRole.fixture));
            edges.add(_e('br$b', 'r$r', f, ServiceType.coldWater));
            b++;
          }
        }
        if (b == 0) continue;
        final sized = autoSizeNetwork(
          Network(nodes: nodes, edges: _shuffled(edges, seed)),
          const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 2.0},
          nodeFixtureUnits: ubap,
        );
        final total = ubap.values.fold(0.0, (s, u) => s + u);
        expect(sized['feed']!.flow.cubicMetersPerSecond,
            closeTo(_curve(total), 1e-12),
            reason: 'seed $seed feed');
        ubap.forEach((f, u) {
          final id = 'br${f.substring(1)}';
          expect(
              sized[id]!.flow.cubicMetersPerSecond, closeTo(_curve(u), 1e-12),
              reason: 'seed $seed $id');
        });
      }
    });
  });

  group('mech-props-2 / mech-building-1 — deterministic physical root', () {
    // GT → P (run) → RT (riser) → downfeed h3..h0 with 2 × 8 UBAP per floor.
    Network transfer() {
      final nodes = <NetNode>[
        _n('GT', 0, 0,
            role: NodeRole.plant, component: NodeComponent.groundTank),
        _n('P', 100, 0, role: NodeRole.plant, component: NodeComponent.pump),
        _n('RT', 100, 0,
            floor: 3, role: NodeRole.plant, component: NodeComponent.roofTank),
      ];
      final edges = <NetEdge>[
        _e('gtp', 'GT', 'P', ServiceType.coldWater),
        _e('prt', 'P', 'RT', ServiceType.coldWater, kind: EdgeKind.riser),
      ];
      for (var f = 3; f >= 0; f--) {
        nodes.add(_n('h$f', 300, 0, floor: f));
        edges.add(f == 3
            ? _e('rth3', 'RT', 'h3', ServiceType.coldWater)
            : _e('d$f', 'h${f + 1}', 'h$f', ServiceType.coldWater,
                kind: EdgeKind.riser));
        for (var k = 0; k < 2; k++) {
          nodes.add(
              _n('x${f}_$k', 400, 100.0 * k, floor: f, role: NodeRole.fixture));
          edges.add(_e('b${f}_$k', 'h$f', 'x${f}_$k', ServiceType.coldWater));
        }
      }
      return Network(nodes: nodes, edges: edges);
    }

    final fixtureUbap = {
      for (var f = 0; f < 4; f++)
        for (var k = 0; k < 2; k++) 'x${f}_$k': 8.0,
    };

    test('transfer + suction size on the full 64 UBAP in ANY drawing order',
        () {
      final base = transfer();
      for (var seed = 0; seed < 25; seed++) {
        final net =
            Network(nodes: base.nodes, edges: _shuffled(base.edges, seed));
        final sized = autoSizeNetwork(
          net,
          const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 2.0},
          nodeFixtureUnits: fixtureUbap,
        );
        // Rooted at the degree-1 ground tank: the suction and the transfer
        // riser both carry every fixture, curve(8 × 8 = 64 UBAP).
        for (final id in ['gtp', 'prt']) {
          expect(
              sized[id]!.flow.cubicMetersPerSecond, closeTo(_curve(64), 1e-12),
              reason: 'seed $seed $id');
        }
        expect(sized['gtp']!.flowFromId, 'GT', reason: 'seed $seed');
        expect(sized['prt']!.flowFromId, 'P', reason: 'seed $seed');
      }
    });

    test('a plant leaf that is not the root carries no phantom demand', () {
      // Two ground tanks: the lower-id one roots, the other plant leaf adds 0.
      final net = Network(nodes: [
        _n('GT1', 0, 0,
            role: NodeRole.plant, component: NodeComponent.groundTank),
        _n('GT2', 0, 200,
            role: NodeRole.plant, component: NodeComponent.groundTank),
        _n('J', 100, 100),
        _n('F', 200, 100, role: NodeRole.fixture),
      ], edges: [
        _e('a', 'GT1', 'J', ServiceType.coldWater),
        _e('b', 'GT2', 'J', ServiceType.coldWater),
        _e('c', 'J', 'F', ServiceType.coldWater),
      ]);
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.coldWater: 2.0},
        nodeFixtureUnits: const {'F': 8.0},
      );
      // GT2 bears no load: the root edge carries curve(8) — never curve(8+2)
      // with a phantom 2-UBAP leaf default.
      expect(sized['a']!.flow.cubicMetersPerSecond, closeTo(_curve(8), 1e-12));
      expect(sized['c']!.flow.cubicMetersPerSecond, closeTo(_curve(8), 1e-12));
      // Round 14 (parallel-sources-by-id) re-derivation: GT2 is a PARALLEL
      // source of equal rank, so its bridge mirrors the set flow curve(8)
      // (each compartment must carry the whole suction alone) — it no longer
      // prints a 0 L/s minimum-size leg that depends on the node ids. It is
      // still curve(8), not curve(10): the mirror adds no demand.
      expect(sized['b']!.flow.cubicMetersPerSecond, closeTo(_curve(8), 1e-12),
          reason: 'GT2 mirrors the set flow (was 0 / 2 UBAP)');
      expect(sized['b']!.flowFromId, 'GT2');
    });

    test('a drainage stack accumulates to the building drain in ANY order', () {
      // out —sewer— s0, risers s0-s1-s2-s3-top, 6 WC (4 DFU) on s1..s3.
      final nodes = <NetNode>[
        _n('out', 0, 0),
        for (var f = 0; f <= 3; f++) _n('s$f', 100, 0, floor: f),
        _n('top', 100, 0, floor: 4),
      ];
      final edges = <NetEdge>[
        _e('sewer', 'out', 's0', ServiceType.drainage),
        for (var f = 0; f < 3; f++)
          _e('r$f', 's$f', 's${f + 1}', ServiceType.drainage,
              kind: EdgeKind.riser),
        _e('r3', 's3', 'top', ServiceType.drainage, kind: EdgeKind.riser),
      ];
      final dfu = <String, double>{};
      for (var f = 1; f <= 3; f++) {
        for (var k = 0; k < 6; k++) {
          final id = 'wc${f}_$k';
          nodes.add(_n(id, 200, 20.0 * k,
              floor: f,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank));
          edges.add(_e('w${f}_$k', 's$f', id, ServiceType.drainage));
          dfu[id] = 4.0;
        }
      }
      final base = Network(nodes: nodes, edges: edges);
      Map<String, EdgeSizing> run(Network n) => autoSizeNetwork(
            n,
            const SizingContext(),
            leafDemand: const {},
            nodeDrainageUnits: dfu,
          );
      final ref = run(base);
      // 18 WC × 4 = 72 DFU on the horizontal building drain (branch table).
      expect(ref['sewer']!.diameter.inMillimeters,
          drain.drainDiameterForDfu(72, isStack: false).inMillimeters);
      expect(ref['sewer']!.flowFromId, 's0');
      for (var seed = 0; seed < 25; seed++) {
        final s = run(Network(nodes: nodes, edges: _shuffled(edges, seed)));
        for (final e in edges) {
          expect(s[e.id]?.diameter.inMillimeters,
              ref[e.id]?.diameter.inMillimeters,
              reason: 'seed $seed ${e.id}');
          expect(s[e.id]?.flowFromId, ref[e.id]?.flowFromId,
              reason: 'seed $seed ${e.id}');
        }
      }
    });
  });

  group('mech-props-3 — ring pump head is the governing ORIENTED path', () {
    const cal = {'s1': ScaleCalibration(0.01)};
    const building = BuildingLevels([Floor('G', Length(3.5))]);
    final nodes = <NetNode>[
      _n('P', 0, 0, role: NodeRole.plant, component: NodeComponent.pump),
      _n('A', 0, 100),
      _n('B', 2000, 100),
      _n('C', 2000, 600),
      _n('D', 0, 600),
      _n('fb', 2100, 100, role: NodeRole.fixture),
      _n('fc', 2100, 600, role: NodeRole.fixture),
      _n('fd', -100, 600, role: NodeRole.fixture),
    ];
    final edges = <NetEdge>[
      _e('feed', 'P', 'A', ServiceType.coldWater),
      _e('ab', 'A', 'B', ServiceType.coldWater),
      _e('bc', 'B', 'C', ServiceType.coldWater),
      _e('cd', 'C', 'D', ServiceType.coldWater),
      _e('da', 'D', 'A', ServiceType.coldWater),
      _e('bfb', 'B', 'fb', ServiceType.coldWater),
      _e('cfc', 'C', 'fc', ServiceType.coldWater),
      _e('dfd', 'D', 'fd', ServiceType.coldWater),
    ];
    const ubap = {'fb': 120.0, 'fc': 10.0, 'fd': 10.0};

    ({double head, Map<String, EdgeSizing> sizing}) solve(List<NetEdge> es) {
      final net = Network(nodes: nodes, edges: es);
      final sizing = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.coldWater: 2.0},
        nodeFixtureUnits: ubap,
        building: building,
        calibrationBySheet: cal,
      );
      final sol = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 'P',
        edgeFlows: {for (final s in sizing.values) s.edgeId: s.flow},
        sizing: sizing,
        calibrationBySheet: cal,
        building: building,
        targetResidual: const Pressure(100000),
      );
      return (head: sol.requiredPumpHead.meters, sizing: sizing);
    }

    test('identical for forward, reversed and shuffled edge orders', () {
      final fwd = solve(edges);
      final rev = solve(edges.reversed.toList());
      expect(rev.head, closeTo(fwd.head, 1e-9));
      for (var seed = 0; seed < 20; seed++) {
        expect(solve(_shuffled(edges, seed)).head, closeTo(fwd.head, 1e-9),
            reason: 'seed $seed');
      }
    });

    test('equals target + max friction over flow-consistent simple paths', () {
      // First-principles derivation, independent of the solver's Kahn pass:
      // enumerate every simple path P→fixture that walks each edge IN its
      // sized flow direction, sum Hazen–Williams losses, take the maximum.
      final r = solve(edges);
      final net = Network(nodes: nodes, edges: edges);
      double hf(NetEdge e) {
        final s = r.sizing[e.id]!;
        return headLossHazenWilliams(
          flow: s.flow,
          length:
              edgeLength(e, net, calibrationBySheet: cal, building: building),
          diameter: s.diameter,
          hazenWilliamsC: _profile.hazenWilliamsC(PipeMaterial.pvc),
        ).meters;
      }

      var worst = 0.0;
      void walk(String at, Set<String> seen, double acc) {
        if (ubap.containsKey(at)) worst = math.max(worst, acc);
        for (final e in edges) {
          final from = r.sizing[e.id]!.flowFromId;
          if (from != at) continue;
          final to = e.fromId == at ? e.toId : e.fromId;
          if (seen.contains(to)) continue;
          walk(to, {...seen, to}, acc + hf(e));
        }
      }

      walk('P', {'P'}, 0);
      // Fixtures sit on the pump's floor (same fixture height datum offset is
      // constant), so required head = governing friction + elevation + target.
      final elevGain =
          nodeElevation(nodes[5], building, const MountingHeights()).meters -
              nodeElevation(nodes[0], building, const MountingHeights()).meters;
      final target = headFromPressure(const Pressure(100000)).meters;
      expect(r.head, closeTo(worst + elevGain + target, 1e-9));
    });
  });

  group('mech-props-4 — Hardy–Cross verdict is edge-order invariant', () {
    // Ladder grid: two 4 m legs L0..LN / R0..RN, 30 m rungs Li-Ri, root L0,
    // 0.01 m3/s drawn at every R node.
    List<({String id, String from, String to})> ladder(int n) => [
          for (var i = 0; i < n; i++) ...[
            (id: 'L$i', from: 'L$i', to: 'L${i + 1}'),
            (id: 'R$i', from: 'R$i', to: 'R${i + 1}'),
          ],
          for (var i = 0; i <= n; i++) (id: 'rung$i', from: 'L$i', to: 'R$i'),
        ];
    double k(String id) => id.startsWith('rung') ? 30.0 : 4.0;

    for (final n in [12, 16, 20]) {
      for (final exponent in [1.852, 2.0]) {
        test('$n-rung ladder, n=$exponent: every order converges to one split',
            () {
          final edges = ladder(n);
          final demand = {for (var i = 0; i <= n; i++) 'R$i': 0.01};
          LoopBalanceResult run(
                  List<({String id, String from, String to})> es) =>
              balanceFlows(
                edges: es,
                root: 'L0',
                demand: demand,
                resistance: k,
                exponent: exponent,
              );
          final fwd = run(edges);
          expect(fwd.converged, isTrue);
          expect(fwd.loopCount, n); // edges − nodes + 1 = (3n+1) − 2(n+1) + 1
          final orders = [
            edges.reversed.toList(),
            for (var seed = 0; seed < 8; seed++) _shuffled(edges, seed),
          ];
          for (final es in orders) {
            final r = run(es);
            expect(r.converged, isTrue);
            for (final e in edges) {
              expect(r.edgeFlow[e.id]!, closeTo(fwd.edgeFlow[e.id]!, 1e-9));
            }
          }
          // Head balance around every rung loop holds at the settled split:
          // Σ ± k|Q|^n = 0 over L_i → L_{i+1} → R_{i+1} → R_i → L_i.
          double h(String id) {
            final q = fwd.edgeFlow[id]!;
            return (q < 0 ? -1 : 1) * k(id) * math.pow(q.abs(), exponent);
          }

          for (var i = 0; i < n; i++) {
            final loop = h('L$i') + h('rung${i + 1}') - h('R$i') - h('rung$i');
            expect(loop.abs(), lessThan(1e-9));
          }
        });
      }
    }
  });

  test('mech-props-6 — a bare duct ring drawn before its diffusers', () {
    final net = Network(nodes: [
      _n('AHU', 0, 0, role: NodeRole.plant, component: NodeComponent.ahu),
      _n('j', 100, 0),
      _n('dif', 200, 0,
          role: NodeRole.fixture, component: NodeComponent.supplyDiffuser),
      _n('a', 100, 100),
      _n('b', 0, 100),
    ], edges: [
      _e('feed', 'AHU', 'j', ServiceType.duct),
      _e('jd', 'j', 'dif', ServiceType.duct),
      _e('ja', 'j', 'a', ServiceType.duct),
      _e('ab', 'a', 'b', ServiceType.duct),
      _e('bj', 'b', 'j', ServiceType.duct),
    ]);
    final sized = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.duct: FlowRate(0)},
      nodeFlowDemand: const {'dif': FlowRate(0.3)},
    );
    // No assertion error; the zero-flow ring pocket is left unsized.
    expect(sized['feed']!.flow.cubicMetersPerSecond, closeTo(0.3, 1e-12));
    expect(sized['jd']!.flow.cubicMetersPerSecond, closeTo(0.3, 1e-12));
    for (final id in ['ja', 'ab', 'bj']) {
      expect(sized.containsKey(id), isFalse, reason: id);
    }
  });

  test('mech-building-3 — a tied vent stack sizes on the DFU it vents', () {
    // Soil stack DS0..DS3 (24 DFU entering per floor → 96 DFU), vent stack
    // V0..V3 tied at every floor, rising to a VTR.
    final nodes = <NetNode>[_n('out', 0, 0)];
    final edges = <NetEdge>[_e('sewer', 'out', 'DS0', ServiceType.drainage)];
    final dfu = <String, double>{};
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('DS$f', 100, 0, floor: f))
        ..add(_n('V$f', 120, 0, floor: f))
        ..add(_n('fx$f', 200, 0, floor: f, role: NodeRole.fixture));
      dfu['fx$f'] = 24.0;
      edges
        ..add(_e('fb$f', 'DS$f', 'fx$f', ServiceType.drainage))
        ..add(_e('tie$f', 'V$f', 'DS$f', ServiceType.vent));
      if (f > 0) {
        edges
          ..add(_e('ds$f', 'DS${f - 1}', 'DS$f', ServiceType.drainage,
              kind: EdgeKind.riser))
          ..add(_e('v$f', 'V${f - 1}', 'V$f', ServiceType.vent,
              kind: EdgeKind.riser));
      }
    }
    nodes.add(_n('VTR', 120, 0, floor: 4));
    edges.add(_e('vtr', 'V3', 'VTR', ServiceType.vent, kind: EdgeKind.riser));
    final sized = autoSizeNetwork(
      Network(nodes: nodes, edges: edges),
      const SizingContext(),
      leafDemand: const {},
      nodeDrainageUnits: dfu,
    );
    // Each tie vents its floor's 24 DFU (through-DFU at DS_f minus what enters
    // through the tie below it); the vent accumulates toward the VTR:
    //   tie_f 24, v1 24, v2 48, v3 72, vtr 96.
    // Round 12 (mech-props-2 vent-stack-reverse-taper) — a VENT STACK is
    // sized over its whole developed length on the TOTAL DFU of the soil
    // stack it serves (IPC 916.1 / UPC 703.2), so every riser segment
    // v1..v3 + vtr takes the stack's largest load, 96 DFU → DN100 — never
    // the reverse-tapered DN50 base. The branch ties keep their own 24 DFU.
    expect(sized['tie2']!.diameter.inMillimeters,
        drain.ventDiameterForDfu(24).inMillimeters);
    for (final id in ['v1', 'v2', 'v3', 'vtr']) {
      expect(sized[id]!.diameter.inMillimeters,
          drain.ventDiameterForDfu(96).inMillimeters,
          reason: id);
    }
    // Round 9 — UPC 703.2 puts 96 DFU (84 < 96 ≤ 256) in the DN100 row; the
    // half-drain floor (96 DFU stack → DN100 ⇒ ½ = 50) does not bind.
    expect(drain.ventDiameterForDfu(96).inMillimeters, 100);
    // The edge order does not move the vent root off the VTR.
    final shuffled = autoSizeNetwork(
      Network(nodes: nodes, edges: _shuffled(edges, 3)),
      const SizingContext(),
      leafDemand: const {},
      nodeDrainageUnits: dfu,
    );
    expect(shuffled['vtr']!.diameter.inMillimeters, 100);
  });

  test('mech-building-6 — a dual-supply fixture loads 3/4 of its UBAP each',
      () {
    // 8 lavatories (1 UBAP each) on both a CW and an HW branch, + one
    // cold-only hose bibb (2.5 UBAP) on the CW main.
    final nodes = <NetNode>[
      _n('CW', 0, 0, role: NodeRole.plant, component: NodeComponent.pump),
      _n('HW', 0, 200, role: NodeRole.plant),
      _n('mc', 100, 0),
      _n('mh', 100, 200),
      _n('hb', 100, -100, role: NodeRole.fixture),
    ];
    final edges = <NetEdge>[
      _e('cmain', 'CW', 'mc', ServiceType.coldWater),
      _e('hmain', 'HW', 'mh', ServiceType.hotWater),
      _e('chb', 'mc', 'hb', ServiceType.coldWater),
    ];
    final fu = <String, double>{'hb': 2.5};
    for (var i = 0; i < 8; i++) {
      nodes.add(_n('lav$i', 200, 20.0 * i, role: NodeRole.fixture));
      edges
        ..add(_e('c$i', 'mc', 'lav$i', ServiceType.coldWater))
        ..add(_e('h$i', 'mh', 'lav$i', ServiceType.hotWater));
      fu['lav$i'] = 1.0;
    }
    final sized = autoSizeNetwork(
      Network(nodes: nodes, edges: edges),
      const SizingContext(),
      leafDemand: const {},
      leafFixtureUnits: const {
        ServiceType.coldWater: 2.0,
        ServiceType.hotWater: 2.0,
      },
      nodeFixtureUnits: fu,
    );
    final f = _profile.dualSupplyFixtureUnitFactor.value;
    expect(f, 0.75);
    // HW main: 8 × 0.75 = 6 UBAP → curve(6) = 0.30 L/s (was curve(8)).
    expect(sized['hmain']!.flow.cubicMetersPerSecond,
        closeTo(_curve(8 * f), 1e-12));
    expect(_curve(6), closeTo(0.0003, 1e-12));
    // CW main: the cold-only bibb keeps its full 2.5 → 6 + 2.5 = 8.5 UBAP.
    expect(sized['cmain']!.flow.cubicMetersPerSecond,
        closeTo(_curve(8 * f + 2.5), 1e-12));
    expect(
        sized['chb']!.flow.cubicMetersPerSecond, closeTo(_curve(2.5), 1e-12));
    // The factor is surfaced on the honesty surface.
    expect(_profile.verifyChecklist,
        contains(_profile.dualSupplyFixtureUnitFactor));
  });

  group('mech-building-5 — hydrant riser at the standpipe design flow', () {
    // 4-storey riser, one box per floor (5 L/s per box default).
    Network riser(int storeys) => Network(nodes: [
          _n('FP', 0, 0, role: NodeRole.plant, component: NodeComponent.pump),
          for (var f = 0; f < storeys; f++) _n('H$f', 100, 0, floor: f),
          for (var f = 0; f < storeys; f++)
            _n('B$f', 300, 0,
                floor: f,
                role: NodeRole.fixture,
                component: NodeComponent.hydrantBox),
        ], edges: [
          _e('feed', 'FP', 'H0', ServiceType.fireHydrant),
          for (var f = 0; f < storeys - 1; f++)
            _e('h$f', 'H$f', 'H${f + 1}', ServiceType.fireHydrant,
                kind: EdgeKind.riser),
          for (var f = 0; f < storeys; f++)
            _e('box$f', 'H$f', 'B$f', ServiceType.fireHydrant),
        ]);
    const perBox = FlowRate(0.005);
    final design = designStandpipe(risers: 1, buildingHeight: const Length(12))
        .requiredFlow;

    test('SNI 03-1745 one riser = 500 gpm = 31.5 L/s ≫ 4 × 5 L/s', () {
      // 500 gpm × 3.785 L/gal / 60 = 31.54 L/s (engine standpipeFlow(1)).
      expect(design.cubicMetersPerSecond,
          closeTo(standpipeFlow(1).cubicMetersPerSecond, 1e-15));
      expect(design.cubicMetersPerSecond, greaterThan(4 * 0.005));
    });

    for (final storeys in [4, 10]) {
      test('$storeys boxes: riser + trunk = design flow, box branch = 5 L/s',
          () {
        final sized = autoSizeNetwork(
          riser(storeys),
          const SizingContext(),
          leafDemand: const {ServiceType.fireHydrant: perBox},
          hydrantDesignFlow: design,
        );
        for (final id in [
          'feed',
          for (var f = 0; f < storeys - 1; f++) 'h$f'
        ]) {
          expect(sized[id]!.flow.cubicMetersPerSecond,
              closeTo(design.cubicMetersPerSecond, 1e-15),
              reason: id);
          // The pipe the pump pushes its flow through stays inside the cap.
          expect(sized[id]!.velocity.metersPerSecond, lessThanOrEqualTo(2.0));
        }
        expect(sized['box0']!.flow.cubicMetersPerSecond, closeTo(0.005, 1e-15));
        // Without the design flow the legacy Σ-boxes accumulation is unchanged.
        final legacy = autoSizeNetwork(riser(storeys), const SizingContext(),
            leafDemand: const {ServiceType.fireHydrant: perBox});
        expect(legacy['feed']!.flow.cubicMetersPerSecond,
            closeTo(storeys * 0.005, 1e-12));
      });
    }
  });

  test('mech-building-2 — upfeed over-pressure = residual or no-flow > 392 kPa',
      () {
    const storeys = 8;
    final building = BuildingLevels(
        [for (var f = 0; f < storeys; f++) Floor('L$f', const Length(3.5))]);
    const cal = {'s1': ScaleCalibration(0.01)};
    final nodes = <NetNode>[
      _n('P', 0, 0, role: NodeRole.plant, component: NodeComponent.pump),
      for (var f = 0; f < storeys; f++) _n('R$f', 100, 0, floor: f),
      for (var f = 0; f < storeys; f++)
        for (var k = 0; k < 4; k++)
          _n('W${f}_$k', 200.0 + 50 * k, 0,
              floor: f,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank),
    ];
    final edges = <NetEdge>[
      _e('feed', 'P', 'R0', ServiceType.coldWater),
      for (var f = 0; f < storeys - 1; f++)
        _e('r$f', 'R$f', 'R${f + 1}', ServiceType.coldWater,
            kind: EdgeKind.riser),
      for (var f = 0; f < storeys; f++)
        for (var k = 0; k < 4; k++)
          _e('b${f}_$k', 'R$f', 'W${f}_$k', ServiceType.coldWater),
    ];
    final net = Network(nodes: nodes, edges: edges);
    final sizing = autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {},
        leafFixtureUnits: const {ServiceType.coldWater: 2.0},
        nodeFixtureUnits: {
          for (final n in nodes)
            if (n.fixture != null) n.id: _profile.fixtureUnitLoad(n.fixture!),
        },
        building: building,
        calibrationBySheet: cal);
    final sol = solvePressurized(
      net: net,
      service: ServiceType.coldWater,
      sourceId: 'P',
      edgeFlows: {for (final s in sizing.values) s.edgeId: s.flow},
      sizing: sizing,
      calibrationBySheet: cal,
      building: building,
      targetResidual: const Pressure(225000),
    );
    // First-principles no-flow static: pump head − elevation gain (no friction).
    const mh = MountingHeights();
    final srcElev = nodeElevation(nodes.first, building, mh).meters;
    const maxFix = 392266.0, relief = 490332.5;
    final expected = <String>{};
    for (final n in nodes.where((n) => n.fixture != null)) {
      final noFlow = pressureFromHead(Head(sol.requiredPumpHead.meters -
              (nodeElevation(n, building, mh).meters - srcElev)))
          .pascals;
      expect(sol.noFlowStaticPressure[n.id]!.pascals, closeTo(noFlow, 1e-6));
      // no-flow = residual + path friction ≥ residual.
      expect(noFlow, greaterThanOrEqualTo(sol.residualPressure[n.id]!.pascals));
      if (noFlow > maxFix || sol.residualPressure[n.id]!.pascals > maxFix) {
        expected.add(n.id);
      }
    }
    final over = upfeedOverPressure(sol);
    expect(over.map((o) => o.nodeId).toSet(), expected);
    expect(expected, containsAll(['W0_0', 'W0_3']));
    expect(expected, isNot(contains('W7_0')));
    for (final o in over) {
      expect(o.overRelief, o.noFlow.pascals >= relief);
    }
    // Worst (highest no-flow static) first.
    for (var i = 1; i < over.length; i++) {
      expect(over[i - 1].noFlow.pascals,
          greaterThanOrEqualTo(over[i].noFlow.pascals));
    }
  });
}
