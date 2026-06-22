/// Tests for the BOM aggregator (lib/sizing/bom.dart).
///
/// Hand-computed expected values are documented inline so they can be verified
/// without running the engine.
///
/// Network layout
/// ──────────────
/// Sheet "s1"   ScaleCalibration(0.05)  → 0.05 m per pixel
///
/// Nodes
///   n0  sheetId:s1  x:0   y:0   floorIndex:0
///   n1  sheetId:s1  x:100 y:0   floorIndex:0
///   n2  sheetId:s1  x:100 y:75  floorIndex:0
///   n3  sheetId:s1  x:0   y:0   floorIndex:1
///
/// Edges (all ServiceType.coldWater)
///   e1  n0→n1  run    pixel-dist = √((100-0)²+(0-0)²) = 100 px
///                      length  = 100 × 0.05 = 5.000 m
///   e2  n1→n2  run    pixel-dist = √((100-100)²+(75-0)²) = 75 px
///                      length  = 75  × 0.05 = 3.750 m
///   e3  n3→n0  riser  floors 1→0 → riserLength(1,0) = elevationOf(1)−elevationOf(0)
///                      BuildingLevels: floor-0 height=4.0 m, floor-1 height=3.5 m
///                      elevationOf(0) = 0.0 m
///                      elevationOf(1) = 4.0 m   (cumulative after floor-0)
///                      riserLength    = |4.0 − 0.0| = 4.000 m
///
/// Sizing map
///   e1 → Diameter(0.025)  → inMillimeters = 25.0 → round() = 25
///   e2 → Diameter(0.025)  → inMillimeters = 25.0 → round() = 25
///   e3 → Diameter(0.050)  → inMillimeters = 50.0 → round() = 50
///
/// Expected BOM lines (sorted by service, kind, diameterMm)
///   BomLine(coldWater, run,   25, totalLength=8.750 m, segmentCount=2)
///   BomLine(coldWater, riser, 50, totalLength=4.000 m, segmentCount=1)
///
/// totalLengthForService(coldWater) = 8.750 + 4.000 = 12.750 m
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

// ── shared fixtures ──────────────────────────────────────────────────────────

// 0.05 m/px calibration (one sheet named "s1").
const _cal = ScaleCalibration(0.05);
const _calibrationBySheet = <String, ScaleCalibration>{'s1': _cal};

// Two-floor building: ground (4.0 m), level-1 (3.5 m).
const _building = BuildingLevels([
  Floor('Ground', Length(4.0)),
  Floor('Level 1', Length(3.5)),
]);

// Nodes.
const _n0 = NetNode(id: 'n0', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
const _n1 = NetNode(id: 'n1', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
const _n2 = NetNode(id: 'n2', sheetId: 's1', x: 100, y: 75, floorIndex: 0);
const _n3 = NetNode(id: 'n3', sheetId: 's1', x: 0, y: 0, floorIndex: 1);

// Edges.
const _e1 = NetEdge(
  id: 'e1',
  fromId: 'n0',
  toId: 'n1',
  service: ServiceType.coldWater,
  kind: EdgeKind.run,
);
const _e2 = NetEdge(
  id: 'e2',
  fromId: 'n1',
  toId: 'n2',
  service: ServiceType.coldWater,
  kind: EdgeKind.run,
);
const _e3 = NetEdge(
  id: 'e3',
  fromId: 'n3',
  toId: 'n0',
  service: ServiceType.coldWater,
  kind: EdgeKind.riser,
);

// Full network (e1, e2 = runs; e3 = riser).
const _net = Network(
  nodes: [_n0, _n1, _n2, _n3],
  edges: [_e1, _e2, _e3],
);

// Sizing entries (only diameter matters for BOM grouping; flow/velocity are
// arbitrary stand-ins required by the EdgeSizing constructor).
const _sizing = <String, EdgeSizing>{
  'e1': EdgeSizing(
    edgeId: 'e1',
    service: ServiceType.coldWater,
    flow: FlowRate(0.001),
    diameter: Diameter(0.025), // 25 mm
    velocity: Velocity(1.0),
  ),
  'e2': EdgeSizing(
    edgeId: 'e2',
    service: ServiceType.coldWater,
    flow: FlowRate(0.001),
    diameter: Diameter(0.025), // 25 mm
    velocity: Velocity(1.0),
  ),
  'e3': EdgeSizing(
    edgeId: 'e3',
    service: ServiceType.coldWater,
    flow: FlowRate(0.001),
    diameter: Diameter(0.050), // 50 mm
    velocity: Velocity(0.5),
  ),
};

// ── helpers ──────────────────────────────────────────────────────────────────

BomLine _lineWhere(
  List<BomLine> bom,
  ServiceType service,
  EdgeKind kind,
  int diameterMm,
) {
  return bom.firstWhere(
    (l) =>
        l.service == service &&
        l.kind == kind &&
        l.diameterMm == diameterMm,
    orElse: () => throw StateError(
      'No BomLine for ($service, $kind, ${diameterMm}mm)',
    ),
  );
}

// ── tests ────────────────────────────────────────────────────────────────────

void main() {
  group('buildBom — empty network', () {
    test('returns an empty list when no edges exist', () {
      const emptyNet = Network(nodes: [], edges: []);
      final bom = buildBom(
        net: emptyNet,
        sizing: const {},
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      expect(bom, isEmpty);
    });

    test('returns empty when sizing map has no entries for the network edges',
        () {
      final bom = buildBom(
        net: _net,
        sizing: const {}, // no sizing → all edges skipped
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      expect(bom, isEmpty);
    });
  });

  group('buildBom — cold-water network (2 runs + 1 riser)', () {
    late List<BomLine> bom;

    setUp(() {
      bom = buildBom(
        net: _net,
        sizing: _sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
    });

    test('produces exactly two BomLines', () {
      expect(bom, hasLength(2));
    });

    // ── run group ────────────────────────────────────────────────────────────
    // e1: 100 px × 0.05 m/px = 5.000 m
    // e2:  75 px × 0.05 m/px = 3.750 m
    // total = 8.750 m,  segmentCount = 2
    group('run line (DN25)', () {
      late BomLine runLine;
      setUp(() {
        runLine = _lineWhere(bom, ServiceType.coldWater, EdgeKind.run, 25);
      });

      test('segmentCount is 2', () {
        expect(runLine.segmentCount, 2);
      });

      test('totalLength is 8.750 m', () {
        expect(runLine.totalLength.meters, closeTo(8.750, 1e-9));
      });

      test('service is coldWater', () {
        expect(runLine.service, ServiceType.coldWater);
      });

      test('kind is run', () {
        expect(runLine.kind, EdgeKind.run);
      });

      test('diameterMm is 25', () {
        expect(runLine.diameterMm, 25);
      });
    });

    // ── riser group ──────────────────────────────────────────────────────────
    // e3: riserLength(1, 0) = |elevationOf(1) − elevationOf(0)| = |4.0 − 0.0|
    //   = 4.000 m,  segmentCount = 1
    group('riser line (DN50)', () {
      late BomLine riserLine;
      setUp(() {
        riserLine = _lineWhere(bom, ServiceType.coldWater, EdgeKind.riser, 50);
      });

      test('segmentCount is 1', () {
        expect(riserLine.segmentCount, 1);
      });

      test('totalLength is 4.000 m', () {
        expect(riserLine.totalLength.meters, closeTo(4.000, 1e-9));
      });

      test('service is coldWater', () {
        expect(riserLine.service, ServiceType.coldWater);
      });

      test('kind is riser', () {
        expect(riserLine.kind, EdgeKind.riser);
      });

      test('diameterMm is 50', () {
        expect(riserLine.diameterMm, 50);
      });
    });

    // ── runs and risers are separate lines ────────────────────────────────────
    test('run and riser are NOT merged into the same BomLine', () {
      final runLines =
          bom.where((l) => l.kind == EdgeKind.run).toList();
      final riserLines =
          bom.where((l) => l.kind == EdgeKind.riser).toList();
      expect(runLines, hasLength(1));
      expect(riserLines, hasLength(1));
      expect(runLines.first.diameterMm, isNot(riserLines.first.diameterMm));
    });
  });

  group('buildBom — sort order', () {
    test('lines are ordered service-index, kind-index, diameterMm ascending',
        () {
      final bom = buildBom(
        net: _net,
        sizing: _sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      // Only cold-water here; run (index 0) must come before riser (index 1).
      expect(bom[0].kind, EdgeKind.run);
      expect(bom[1].kind, EdgeKind.riser);
    });
  });

  group('totalLengthForService', () {
    // run (8.750 m) + riser (4.000 m) = 12.750 m
    test('sums all lines for coldWater → 12.750 m', () {
      final bom = buildBom(
        net: _net,
        sizing: _sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      final total =
          totalLengthForService(bom, ServiceType.coldWater);
      expect(total.meters, closeTo(12.750, 1e-9));
    });

    test('returns zero for a service with no BomLines', () {
      final bom = buildBom(
        net: _net,
        sizing: _sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      final total =
          totalLengthForService(bom, ServiceType.hotWater);
      expect(total.meters, 0.0);
    });
  });

  group('buildBom — partial sizing (one unsized edge)', () {
    // Only e1 is sized; e2 and e3 are skipped.
    // Expected: one BomLine (coldWater, run, 25 mm), length=5.000 m, count=1.
    test('skips edges absent from the sizing map', () {
      const partialSizing = <String, EdgeSizing>{
        'e1': EdgeSizing(
          edgeId: 'e1',
          service: ServiceType.coldWater,
          flow: FlowRate(0.001),
          diameter: Diameter(0.025),
          velocity: Velocity(1.0),
        ),
      };

      final bom = buildBom(
        net: _net,
        sizing: partialSizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );

      expect(bom, hasLength(1));
      expect(bom.first.segmentCount, 1);
      // e1: 100 px × 0.05 m/px = 5.000 m
      expect(bom.first.totalLength.meters, closeTo(5.000, 1e-9));
    });
  });
}
