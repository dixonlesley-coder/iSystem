// Round 79 (2026-10-18) — fire-convergence-30-symmetric-ring-pipe-left-
// unsized.
//
// A centre-fed ring T -> J -> {A, B} -> {A1, B1}, closed by A1 -> M -> B1,
// with one equal draw-off on each of A1 and B1. By symmetry Hardy–Cross
// splits the feed exactly in half down each arm, and the closing pipes
// `am` / `mb` carry EXACTLY zero (head at A1 == head at B1). They are real
// pipes — they carry flow as soon as the demand moves off the symmetric
// point — so they must be sized (at zero flow, honestly) at least at the
// bore of the flowing pipes they meet, and taken off in the BOM. The
// demand-free duct pocket (mech-props-6) stays unsized.
//
// Hand check: the trunk carries the two equal draw-offs and each arm exactly
// half (Hardy–Cross on a mirror-symmetric ring: equal resistances, equal
// demands => equal arm flows, zero across the axis); `am` / `mb` take the
// arm's bore (the smallest flowing neighbour at A1 / B1 is `aa` / `bb`).
// The BOM gains exactly their solved lengths (100 px x 0.05 m/px = 5 m each
// horizontally, plus the fixture-height vertical leg at A1 / B1).
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {NodeRole role = NodeRole.main, NodeComponent? component}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: component);

NetEdge _e(String id, String a, String b, ServiceType s) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: EdgeKind.run);

Network _ring(ServiceType s, {NodeComponent? head}) => Network(nodes: [
      _n('T', 0, 0, role: NodeRole.plant, component: NodeComponent.groundTank),
      _n('J', 100, 0),
      _n('A', 100, -100),
      _n('B', 100, 100),
      _n('A1', 300, -100, role: NodeRole.fixture, component: head),
      _n('B1', 300, 100, role: NodeRole.fixture, component: head),
      _n('M', 300, 0),
    ], edges: [
      _e('t', 'T', 'J', s),
      _e('ja', 'J', 'A', s),
      _e('jb', 'J', 'B', s),
      _e('aa', 'A', 'A1', s),
      _e('bb', 'B', 'B1', s),
      _e('am', 'A1', 'M', s),
      _e('mb', 'M', 'B1', s),
    ]);

const _building = BuildingLevels([Floor('G', Length(3.5))]);
const _cal = <String, ScaleCalibration>{'s1': ScaleCalibration(0.05)};

void main() {
  for (final (label, service, head, demand) in [
    ('cold water', ServiceType.coldWater, null, null),
    (
      'sprinkler',
      ServiceType.fireSprinkler,
      NodeComponent.sprinklerHead,
      const FlowRate(0.0015)
    ),
  ]) {
    group('$label ring: the zero-balanced closing pipes are sized', () {
      Map<String, EdgeSizing> size({bool calibrated = false}) =>
          autoSizeNetwork(
            _ring(service, head: head),
            const SizingContext(),
            leafDemand: {service: demand ?? const FlowRate(0.0005)},
            nodeFixtureUnits:
                service == ServiceType.coldWater ? {'A1': 8, 'B1': 8} : {},
            nodeFlowDemand:
                demand == null ? const {} : {'A1': demand, 'B1': demand},
            calibrationBySheet: calibrated ? _cal : const <String, ScaleCalibration>{},
            building: calibrated ? _building : null,
          );

      for (final calibrated in [false, true]) {
        test('every ring edge sized (calibrated: $calibrated)', () {
          final s = size(calibrated: calibrated);
          for (final id in ['t', 'ja', 'jb', 'aa', 'bb', 'am', 'mb']) {
            expect(s[id], isNotNull, reason: id);
          }
          // Symmetric: the arms split the feed exactly in half.
          expect(s['aa']!.flow.cubicMetersPerSecond,
              closeTo(s['t']!.flow.cubicMetersPerSecond / 2, 1e-9));
          // Zero flow, honestly — never a fabricated figure…
          expect(s['am']!.flow.cubicMetersPerSecond, 0);
          expect(s['mb']!.flow.cubicMetersPerSecond, 0);
          // …at least the bore of the flowing pipes they meet.
          final nb = math.min(
              s['aa']!.diameter.inMillimeters, s['bb']!.diameter.inMillimeters);
          expect(s['am']!.diameter.inMillimeters,
              greaterThanOrEqualTo(nb - 1e-9));
          expect(s['mb']!.diameter.inMillimeters,
              greaterThanOrEqualTo(nb - 1e-9));
          // Undirected: at the symmetric point it carries nothing, off it
          // either way (never the drawn direction a flip would change).
          expect(s['am']!.flowFromId, isNull);
          expect(s['mb']!.flowFromId, isNull);
        });
      }

      test('the BOM takes the closing pipes off', () {
        final s = size(calibrated: true);
        final net = _ring(service, head: head);
        final bom = buildBom(
            net: net,
            sizing: s,
            calibrationBySheet: _cal,
            building: _building);
        double total(List<BomLine> b) => b
            .where((l) => l.service == service)
            .fold<double>(0, (a, l) => a + l.totalLength.meters);
        final without = buildBom(
            net: net,
            sizing: {...s}
              ..remove('am')
              ..remove('mb'),
            calibrationBySheet: _cal,
            building: _building);
        // The closing pipes contribute exactly their own solved lengths.
        double len(String id) => edgeLength(net.edgeById(id)!, net,
                calibrationBySheet: _cal, building: _building)
            .meters;
        expect(len('am'), greaterThanOrEqualTo(5 - 1e-9)); // 100 px x 0.05
        expect(total(bom) - total(without),
            closeTo(len('am') + len('mb'), 0.11)); // BOM rounds to 0.1 m
      });
    });
  }

  test('a hand-overridden zero-balanced pipe keeps the engineer\'s bore', () {
    final s = autoSizeNetwork(
      _ring(ServiceType.coldWater),
      const SizingContext(),
      leafDemand: const {ServiceType.coldWater: FlowRate(0.0005)},
      nodeFixtureUnits: const {'A1': 8, 'B1': 8},
      sizeOverrides: {'am': Diameter.mm(15)},
    );
    expect(s['am']!.diameter.inMillimeters, closeTo(15, 1e-9));
  });

  test('the trunk carries the sum of the two equal draw-offs', () {
    final s = autoSizeNetwork(
      _ring(ServiceType.coldWater),
      const SizingContext(),
      leafDemand: const {ServiceType.coldWater: FlowRate(0.0005)},
      nodeFixtureUnits: const {'A1': 8, 'B1': 8},
    );
    expect(s['t']!.flow.cubicMetersPerSecond,
        closeTo(2 * s['aa']!.flow.cubicMetersPerSecond, 1e-12));
  });
}
