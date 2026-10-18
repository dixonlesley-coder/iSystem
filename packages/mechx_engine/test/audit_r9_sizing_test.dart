// Round 9 (2026-10-18) — engine sizing findings:
//   mech-store-fuzz-3        a duct joining two plant nodes carries zero flow
//                            ⇒ left unsized (never reaches the duct sizers);
//   plumbing-rules-wc-count  > 2 WCs on a DN75 branch / > 6 on a stack ⇒ DN100;
//   plumbing-rules-floor-drain  a DN50-trap terminal floors its drains at DN50;
//   plumbing-rules-vent      vents sized on UPC 703.2 + the half-drain floor.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component,
        PlumbingFixture? fixture}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: 0,
      floorIndex: floor,
      role: role,
      component: component,
      fixture: fixture,
    );

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

void main() {
  group('mech-store-fuzz-3 — plant↔plant air duct', () {
    for (final svc in [
      ServiceType.duct,
      ServiceType.returnAir,
      ServiceType.exhaust
    ]) {
      for (final kind in [EdgeKind.run, EdgeKind.riser]) {
        test('$svc $kind AHU→fan is left unsized, never throws', () {
          final net = Network(nodes: [
            _n('ahu', 0, role: NodeRole.plant, component: NodeComponent.ahu),
            _n('fan', 100,
                floor: kind == EdgeKind.riser ? 1 : 0,
                role: NodeRole.plant,
                component: NodeComponent.exhaustFan),
          ], edges: [
            _e('d', 'ahu', 'fan', svc, kind: kind)
          ]);
          final sized = autoSizeNetwork(net, const SizingContext(),
              leafDemand: {svc: FlowRate.litersPerSecond(50)});
          // Zero carried flow ⇒ no sizing (like an unreached edge), and above
          // all no 0 L/s Ø100 duct emitted into the BOM.
          expect(sized.containsKey('d'), isFalse);
        });
      }
    }

    test('sizeNetwork skips an explicit zero AIR flow', () {
      final net = Network(
          nodes: [_n('a', 0), _n('b', 100)],
          edges: [_e('d', 'a', 'b', ServiceType.duct)]);
      expect(
          sizeNetwork(net, {'d': const FlowRate(0)}, const SizingContext()),
          isEmpty);
    });
  });

  // A horizontal toilet row: `wcCount` inline flush-tank WCs on one branch
  // (4 DFU each) draining to an outlet.
  Map<String, EdgeSizing> wcRow(int wcCount, {bool stack = false}) {
    final nodes = <NetNode>[_n('out', 0)];
    final edges = <NetEdge>[];
    var prev = 'out';
    for (var i = 0; i < wcCount; i++) {
      final id = 'wc$i';
      nodes.add(_n(id, 100.0 * (i + 1),
          floor: stack ? i + 1 : 0,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.waterClosetFlushTank));
      edges.add(_e('e$i', prev, id, ServiceType.drainage,
          kind: stack ? EdgeKind.riser : EdgeKind.run));
      prev = id;
    }
    return autoSizeNetwork(Network(nodes: nodes, edges: edges),
        const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: {for (var i = 0; i < wcCount; i++) 'wc$i': 4.0});
  }

  group('plumbing-rules-wc-count-on-dn75', () {
    test('2 WCs (8 DFU) on a branch stay DN75', () {
      expect(wcRow(2)['e0']!.diameter.inMillimeters, 75);
    });
    test('3 WCs (12 DFU — DN75 by the table) on a branch ⇒ DN100', () {
      // Branch table: 12 DFU → DN75; IPC 710.1(2) footnote: > 2 WCs ⇒ 4 in.
      expect(drain.drainDiameterForDfu(12, isStack: false).inMillimeters, 75);
      final s = wcRow(3);
      expect(s['e0']!.diameter.inMillimeters, 100); // carries all 3
      expect(s['e1']!.diameter.inMillimeters, 75); // carries 2
      expect(s['e2']!.diameter.inMillimeters, 75); // carries 1
    });
    test('5 WCs (20 DFU) ⇒ DN100, not overCapacity', () {
      final s = wcRow(5)['e0']!;
      expect(s.diameter.inMillimeters, 100);
      expect(s.overCapacity, isFalse);
    });
    test('a stack takes 6 WCs at DN75, the 7th raises it to DN100', () {
      // 7 × 4 = 28 DFU → stack table DN75 (24 < 28 ≤ 42).
      expect(drain.drainDiameterForDfu(28, isStack: true).inMillimeters, 75);
      final s = wcRow(7, stack: true);
      expect(s['e0']!.diameter.inMillimeters, 100); // 7 WCs
      expect(s['e1']!.diameter.inMillimeters, 75); // 6 WCs
    });
    test('property: branch DN ≥ the WC-count floor for any row (seeded)', () {
      final rng = math.Random(19);
      for (var i = 0; i < 25; i++) {
        final n = 1 + rng.nextInt(8);
        final s = wcRow(n);
        for (var k = 0; k < n; k++) {
          final carried = n - k;
          expect(s['e$k']!.diameter.inMillimeters,
              greaterThanOrEqualTo(drain.minDrainMmForWcCount(carried,
                  isStack: false)),
              reason: 'row of $n, edge e$k carries $carried WCs');
        }
      }
    });
  });

  group('plumbing-rules-floor-drain-dn40-stack', () {
    test('a floor drain dropping straight down a riser sizes DN50, not DN40',
        () {
      // Untyped floor drain ⇒ kDefaultLeafDfu = 2 ⇒ stack table DN40; the
      // 2 in trap floors it to DN50.
      expect(drain.drainDiameterForDfu(2, isStack: true).inMillimeters, 40);
      final net = Network(nodes: [
        _n('out', 0),
        _n('fd', 0, floor: 1, component: NodeComponent.floorDrain),
      ], edges: [
        _e('drop', 'out', 'fd', ServiceType.drainage, kind: EdgeKind.riser)
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {});
      expect(s['drop']!.diameter.inMillimeters, 50);
    });

    test('a shower (2 DFU) on a stack ⇒ DN50', () {
      final net = Network(nodes: [
        _n('out', 0),
        _n('sh', 0,
            floor: 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.shower),
      ], edges: [
        _e('drop', 'out', 'sh', ServiceType.drainage, kind: EdgeKind.riser)
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: const {'sh': 2.0});
      expect(s['drop']!.diameter.inMillimeters, 50);
    });

    test('a lavatory (1 DFU) is not floored (DN40 stays)', () {
      final net = Network(nodes: [
        _n('out', 0),
        _n('lav', 0,
            floor: 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.lavatory),
      ], edges: [
        _e('drop', 'out', 'lav', ServiceType.drainage, kind: EdgeKind.riser)
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: const {'lav': 1.0});
      expect(s['drop']!.diameter.inMillimeters, 40);
    });
  });

  group('plumbing-rules-vent-table-shifted', () {
    test('property: every vent ≥ table row and ≥ ½ served drain (seeded)', () {
      final rng = math.Random(29);
      const series = [32.0, 40, 50, 65, 75, 100, 125, 150];
      for (var i = 0; i < 300; i++) {
        final dfu = 0.5 + rng.nextDouble() * 1300;
        final served = series[rng.nextInt(series.length)].toDouble();
        final v =
            drain.ventDiameterForDfu(dfu, servedDrainMm: served).inMillimeters;
        expect(v, greaterThanOrEqualTo(drain.ventDiameterForDfu(dfu).inMillimeters));
        expect(v, greaterThanOrEqualTo(served / 2 - 1e-9));
        expect(v, greaterThanOrEqualTo(drain.kMinVentMm));
      }
    });
  });
}
