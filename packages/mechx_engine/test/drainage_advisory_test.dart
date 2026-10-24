/// Tests for the gravity-drainage advisory layer (`drainage_advisory.dart`).
///
/// The advisories are a JUDGE-ONLY layer — they never resize. Round 9 made
/// both rules PER PIPE SIZE (general practice, // VERIFY vs SNI 8153):
///   • minimum laid slope: ≤ DN65 → 2 %, DN75–DN150 → 1 %, ≥ DN200 → 0.5 %
///     (IPC 704.1 / UPC 708);
///   • trap-arm developed length (fixture → first vent): DN32 1.5 m, DN40
///     1.8 m, DN50 2.4 m, DN75 3.7 m, DN100+ 4.9 m (IPC 909.1), summed over
///     every drawn segment by [trapArmRuns].
library;

import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('per-DN minimum slope', () {
    test('floors: ≤DN65 2 %, DN75–150 1 %, ≥DN200 0.5 %, unknown 0.5 %', () {
      expect(minSelfCleansingSlopeFor(40), 0.02);
      expect(minSelfCleansingSlopeFor(65), 0.02);
      expect(minSelfCleansingSlopeFor(75), 0.01);
      expect(minSelfCleansingSlopeFor(150), 0.01);
      expect(minSelfCleansingSlopeFor(200), 0.005);
      expect(minSelfCleansingSlopeFor(null), kMinSelfCleansingSlope);
    });

    test('a DN50 branch at the 1 % project default flags (needs 2 %)', () {
      final out = drainageAdvisories(edgeId: 'e', slope: 0.01, diameterMm: 50);
      expect(out.single.kind, DrainageAdvisoryKind.minSlope);
      expect(out.single.message, contains('1:50'));
    });

    test('a DN100 drain at 1 % is compliant; at 0.6 % it flags', () {
      expect(drainageAdvisories(edgeId: 'e', slope: 0.01, diameterMm: 100),
          isEmpty);
      expect(
          drainageAdvisories(edgeId: 'e', slope: 0.006, diameterMm: 100)
              .single
              .kind,
          DrainageAdvisoryKind.minSlope);
    });

    test('property: flags iff slope < floor(DN) (seeded)', () {
      final rng = math.Random(9);
      const dns = [32.0, 40, 50, 65, 75, 100, 125, 150, 200, 250];
      for (var i = 0; i < 400; i++) {
        final dn = dns[rng.nextInt(dns.length)].toDouble();
        final slope = 0.001 + rng.nextDouble() * 0.04;
        final out = drainageAdvisories(edgeId: 'e', slope: slope, diameterMm: dn);
        final flagged = out.any((a) => a.kind == DrainageAdvisoryKind.minSlope);
        expect(flagged, slope < minSelfCleansingSlopeFor(dn) - 1e-12,
            reason: 'DN$dn @ $slope');
      }
    });
  });

  group('trap-arm developed length', () {
    test('limits by DN (IPC 909.1)', () {
      expect(maxTrapArmLengthM(32), 1.5);
      expect(maxTrapArmLengthM(40), 1.8);
      expect(maxTrapArmLengthM(50), 2.4);
      expect(maxTrapArmLengthM(75), 3.7);
      expect(maxTrapArmLengthM(100), 4.9);
      expect(maxTrapArmLengthM(150), 4.9);
    });

    test('a 6 m DN40 arm flags (> 1.8 m); a 1.5 m one does not', () {
      expect(
          drainageAdvisories(
                  edgeId: 'e', slope: 0, developedLengthM: 6, diameterMm: 40)
              .single
              .kind,
          DrainageAdvisoryKind.developedLength);
      expect(
          drainageAdvisories(
              edgeId: 'e', slope: 0, developedLengthM: 1.5, diameterMm: 40),
          isEmpty);
    });

    test('no diameter ⇒ no flat-32 m judgement', () {
      expect(drainageAdvisories(edgeId: 'e', slope: 0, developedLengthM: 45),
          isEmpty);
    });

    // A lavatory branch drawn as 3 collinear 15 m segments to the stack: the
    // developed length is 15 + 15 + 15 = 45 m, judged as ONE trap arm.
    test('trapArmRuns sums segments to the first vented point (the stack)', () {
      const nodes = [
        NetNode(id: 'fx', sheetId: 's', x: 0, y: 0, floorIndex: 1,
            role: NodeRole.fixture),
        NetNode(id: 'a', sheetId: 's', x: 15, y: 0, floorIndex: 1),
        NetNode(id: 'b', sheetId: 's', x: 30, y: 0, floorIndex: 1),
        NetNode(id: 'st', sheetId: 's', x: 45, y: 0, floorIndex: 1),
        NetNode(id: 'base', sheetId: 's', x: 45, y: 0, floorIndex: 0),
      ];
      final edges = [
        const NetEdge(id: 'e1', fromId: 'fx', toId: 'a',
            service: ServiceType.drainage),
        const NetEdge(id: 'e2', fromId: 'a', toId: 'b',
            service: ServiceType.drainage),
        const NetEdge(id: 'e3', fromId: 'b', toId: 'st',
            service: ServiceType.drainage),
        const NetEdge(id: 'stack', fromId: 'base', toId: 'st',
            service: ServiceType.drainage, kind: EdgeKind.riser),
      ];
      final net = Network(nodes: nodes, edges: edges);
      EdgeSizing es(String id, String from) => EdgeSizing(
            edgeId: id,
            service: ServiceType.drainage,
            flow: const FlowRate(0),
            diameter: Diameter.mm(40),
            velocity: const Velocity(0),
            flowFromId: from,
          );
      final sizing = {
        'e1': es('e1', 'fx'),
        'e2': es('e2', 'a'),
        'e3': es('e3', 'b'),
        'stack': es('stack', 'st'),
      };
      final arms = trapArmRuns(
          net: net, sizing: sizing, lengthOf: (e) => e.kind == EdgeKind.run
              ? 15.0
              : 3.5);
      expect(arms, hasLength(1));
      expect(arms.single.fixtureNodeId, 'fx');
      expect(arms.single.firstEdgeId, 'e1');
      expect(arms.single.developedLengthM, closeTo(45.0, 1e-9));
    });

    test('a vent tie at the first junction ends the arm there', () {
      const nodes = [
        NetNode(id: 'fx', sheetId: 's', x: 0, y: 0, floorIndex: 0,
            role: NodeRole.fixture),
        NetNode(id: 'a', sheetId: 's', x: 1, y: 0, floorIndex: 0),
        NetNode(id: 'out', sheetId: 's', x: 50, y: 0, floorIndex: 0),
        NetNode(id: 'v', sheetId: 's', x: 1, y: 0, floorIndex: 1),
      ];
      const net = Network(nodes: nodes, edges: [
        NetEdge(id: 'e1', fromId: 'fx', toId: 'a',
            service: ServiceType.drainage),
        NetEdge(id: 'e2', fromId: 'a', toId: 'out',
            service: ServiceType.drainage),
        NetEdge(id: 'vt', fromId: 'a', toId: 'v', service: ServiceType.vent),
      ]);
      final sizing = {
        for (final (id, from) in [('e1', 'fx'), ('e2', 'a')])
          id: EdgeSizing(
            edgeId: id,
            service: ServiceType.drainage,
            flow: const FlowRate(0),
            diameter: Diameter.mm(50),
            velocity: const Velocity(0),
            flowFromId: from,
          ),
      };
      final arms = trapArmRuns(
          net: net,
          sizing: sizing,
          lengthOf: (e) => e.id == 'e1' ? 1.2 : 40.0);
      expect(arms.single.developedLengthM, closeTo(1.2, 1e-9));
    });
  });
}
