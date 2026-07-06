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
///   e3  n3→n0  riser  ceiling-to-ceiling, floors 1→0 (both default mains)
///                      BuildingLevels: floor-0 height=4.0 m, floor-1 height=3.5 m
///                      ceiling(0) = 0.0 + 4.0 − 0.3 = 3.7 m
///                      ceiling(1) = 4.0 + 3.5 − 0.3 = 7.2 m
///                      length     = |7.2 − 3.7| = 3.500 m  (= level-1 height)
///
/// Sizing map
///   e1 → Diameter(0.025)  → inMillimeters = 25.0 → round() = 25
///   e2 → Diameter(0.025)  → inMillimeters = 25.0 → round() = 25
///   e3 → Diameter(0.050)  → inMillimeters = 50.0 → round() = 50
///
/// Expected BOM lines (sorted by service, kind, diameterMm)
///   BomLine(coldWater, run,   25, totalLength=8.750 m, segmentCount=2)
///   BomLine(coldWater, riser, 50, totalLength=3.500 m, segmentCount=1)
///
/// totalLengthForService(coldWater) = 8.750 + 3.500 = 12.250 m
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
    // e3: ceiling-to-ceiling riser, floors 1→0, both default mains.
    //   ceiling(0) = 4.0 − 0.3 = 3.7 m;  ceiling(1) = 4.0 + 3.5 − 0.3 = 7.2 m
    //   length = |7.2 − 3.7| = 3.500 m (= level-1 floor height),  count = 1
    group('riser line (DN50)', () {
      late BomLine riserLine;
      setUp(() {
        riserLine = _lineWhere(bom, ServiceType.coldWater, EdgeKind.riser, 50);
      });

      test('segmentCount is 1', () {
        expect(riserLine.segmentCount, 1);
      });

      test('totalLength is 3.500 m (ceiling-to-ceiling)', () {
        expect(riserLine.totalLength.meters, closeTo(3.500, 1e-9));
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
    // run (8.750 m) + riser (3.500 m) = 12.250 m
    test('sums all lines for coldWater → 12.250 m', () {
      final bom = buildBom(
        net: _net,
        sizing: _sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      final total =
          totalLengthForService(bom, ServiceType.coldWater);
      expect(total.meters, closeTo(12.250, 1e-9));
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

  group('buildFittings', () {
    // _net: n0{e1,e3}, n1{e1,e2}, n2{e2}, n3{e3}. e1,e2=DN25 runs; e3=DN50 riser.
    //   n0 → 2 edges (25,50): elbow@50 + reducer@50
    //   n1 → 2 edges (25,25): elbow@25
    //   n2,n3 → 1 edge: nothing
    test('infers elbows/tees/reducers from node degree + size change', () {
      final fittings = buildFittings(net: _net, sizing: _sizing);
      int countOf(FittingType t, int mm) => fittings
          .where((f) => f.type == t && f.diameterMm == mm)
          .fold(0, (s, f) => s + f.count);
      expect(countOf(FittingType.elbow, 25), 1); // n1
      expect(countOf(FittingType.elbow, 50), 1); // n0 (largest incident = 50)
      expect(countOf(FittingType.reducer, 50), 1); // n0: 25↔50
      expect(countOf(FittingType.tee, 25), 0);
    });

    test('a tee node yields one tee', () {
      const tee = Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'h', sheetId: 's1', x: 10, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 20, y: 0, floorIndex: 0),
          NetNode(id: 'c', sheetId: 's1', x: 10, y: 10, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'e1', fromId: 'a', toId: 'h', service: ServiceType.coldWater),
          NetEdge(id: 'e2', fromId: 'h', toId: 'b', service: ServiceType.coldWater),
          NetEdge(id: 'e3', fromId: 'h', toId: 'c', service: ServiceType.coldWater),
        ],
      );
      const s = EdgeSizing(
        edgeId: 'x',
        service: ServiceType.coldWater,
        flow: FlowRate(0.001),
        diameter: Diameter(0.025),
        velocity: Velocity(1),
      );
      final fittings = buildFittings(
        net: tee,
        sizing: {
          'e1': s,
          'e2': s,
          'e3': s,
        },
      );
      expect(
        fittings.where((f) => f.type == FittingType.tee).single.count,
        1,
      );
    });

    test('fittingsToCsv has a header and one row per line', () {
      final csv = fittingsToCsv(buildFittings(net: _net, sizing: _sizing));
      final lines = csv.trim().split('\n');
      // N18: neutral column name (was nominal_dn_mm).
      expect(lines.first, 'service,fitting,nominal_size_mm,count');
      expect(lines.length, greaterThan(1));
    });
  });

  group('bomToCsv', () {
    test('header + one row per line, lengths to 2 dp', () {
      final bom = buildBom(
        net: _net,
        sizing: _sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      final csv = bomToCsv(bom);
      final lines = csv.trim().split('\n');
      // N14: neutral nominal_size_mm + a material column (coldWater default PPR).
      // N13: a tag column right after kind (run → service code, riser → CW-R1).
      expect(lines.first,
          'service,kind,tag,nominal_size_mm,material,length_m,segments');
      expect(lines.length, bom.length + 1);
      // run line: coldWater,run,CW,25,PPR,8.75,2 (ungrouped run → bare code).
      expect(lines, contains('coldWater,run,CW,25,PPR,8.75,2'));
      // riser line: coldWater,riser,CW-R1,50,PPR,3.50,1 (the riser stack tag).
      expect(lines, contains('coldWater,riser,CW-R1,50,PPR,3.50,1'));
    });

    test('empty bom → header only', () {
      expect(bomToCsv(const []).trim(),
          'service,kind,tag,nominal_size_mm,material,length_m,segments');
    });
  });

  // ── I5: manual-override provenance ─────────────────────────────────────────
  group('buildBom — I5 manual override flag', () {
    // e1 carries a manual size override; e2/e3 do not.
    const e1over = NetEdge(
      id: 'e1',
      fromId: 'n0',
      toId: 'n1',
      service: ServiceType.coldWater,
      kind: EdgeKind.run,
      sizeOverride: Diameter(0.025),
    );
    const netOver = Network(
      nodes: [_n0, _n1, _n2, _n3],
      edges: [e1over, _e2, _e3],
    );

    test('a line with any overridden edge is flagged manual; the rest are not',
        () {
      final bom = buildBom(
        net: netOver,
        sizing: _sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      // The DN25 run line merges e1 (override) + e2 (auto) → manual (any).
      expect(_lineWhere(bom, ServiceType.coldWater, EdgeKind.run, 25).manual,
          isTrue);
      // The DN50 riser line (e3) was auto-sized → not manual.
      expect(_lineWhere(bom, ServiceType.coldWater, EdgeKind.riser, 50).manual,
          isFalse);
    });

    test('bomToCsv appends a manual column with a * token only for overrides',
        () {
      final bom = buildBom(
        net: netOver,
        sizing: _sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      final lines = bomToCsv(bom).trim().split('\n');
      // The conditional column is present and trails the header.
      expect(lines.first, endsWith(',manual'));
      // The run line carries the marker; the riser line's cell is empty.
      expect(lines.any((l) => l.startsWith('coldWater,run,') && l.endsWith(',*')),
          isTrue);
      expect(
          lines.any((l) => l.startsWith('coldWater,riser,') && l.endsWith(',')),
          isTrue);
    });

    test('an all-auto BOM stays byte-identical (no manual column, all false)',
        () {
      final bom = buildBom(
        net: _net,
        sizing: _sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      expect(bom.every((l) => !l.manual), isTrue);
      expect(bomToCsv(bom).split('\n').first.contains('manual'), isFalse);
    });
  });

  // ── N14/N18: material + one size notation ──────────────────────────────────
  group('material + duct notation', () {
    const dNet = Network(
      nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'duct', fromId: 'a', toId: 'b', service: ServiceType.duct),
      ],
    );

    test('a round AC supply duct resolves PU material and a Ø size label', () {
      const sizing = <String, EdgeSizing>{
        'duct': EdgeSizing(
          edgeId: 'duct',
          service: ServiceType.duct,
          flow: FlowRate(0.1),
          diameter: Diameter(0.2), // 200 mm
          velocity: Velocity(3.0),
        ),
      };
      final bom = buildBom(
        net: dNet,
        sizing: sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      final line = bom.single;
      expect(line.material, 'PU'); // supply-air default duct product
      expect(line.sizeLabel, 'Ø200'); // round air → Ø (report notation)
      expect(line.csvSize, '200'); // bare mm in the CSV
      // N13: ungrouped run tag = the bare service code (supply air → SA).
      expect(line.tag, 'SA');
      expect(bomToCsv(bom), contains('duct,run,SA,200,PU,'));
    });

    test('a rectangular duct prints W x H (size label + CSV + grouping)', () {
      const sizing = <String, EdgeSizing>{
        'duct': EdgeSizing(
          edgeId: 'duct',
          service: ServiceType.duct,
          flow: FlowRate(0.1),
          diameter: Diameter(0.2),
          velocity: Velocity(3.0),
          width: Length(0.3), // 300 mm
          height: Length(0.2), // 200 mm
        ),
      };
      final bom = buildBom(
        net: dNet,
        sizing: sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      final line = bom.single;
      expect(line.widthMm, 300);
      expect(line.heightMm, 200);
      expect(line.sizeLabel, '300x200');
      expect(line.csvSize, '300x200');
      expect(bomToCsv(bom), contains('duct,run,SA,300x200,PU,'));
    });

    test('same DN, different material splits into two priced lines', () {
      const twoServices = Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'c', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
        ],
        edges: [
          // coldWater (PPR) + drainage (PVC), both DN50 → two lines.
          NetEdge(id: 'cw', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
          NetEdge(id: 'dr', fromId: 'b', toId: 'c', service: ServiceType.drainage),
        ],
      );
      const sizing = <String, EdgeSizing>{
        'cw': EdgeSizing(
          edgeId: 'cw',
          service: ServiceType.coldWater,
          flow: FlowRate(0.001),
          diameter: Diameter(0.05),
          velocity: Velocity(1.0),
        ),
        'dr': EdgeSizing(
          edgeId: 'dr',
          service: ServiceType.drainage,
          flow: FlowRate(0.001),
          diameter: Diameter(0.05),
          velocity: Velocity(1.0),
        ),
      };
      final bom = buildBom(
        net: twoServices,
        sizing: sizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      final materials = bom.map((l) => l.material).toSet();
      expect(materials, {'PPR', 'PVC'});
    });
  });

  // ── D6: per-floor grouping ────────────────────────────────────────────────
  //
  // Two-floor fixture (reuses _building = ground 4.0 m, level-1 3.5 m; _cal
  // 0.05 m/px):
  //   Floor 0 (human 1):  nA(0,0)  nB(100,0)   rA nA→nB run, DN25
  //                        length = 100 px × 0.05 = 5.000 m
  //   Floor 1 (human 2):  nC(0,0)  nD(60,0)    rB nC→nD run, DN25 (SAME DN)
  //                        length = 60  px × 0.05 = 3.000 m
  //   Riser:              rC nC→nA riser, DN50, floors 1→0 (default mains)
  //                        ceiling(0)=4.0−0.3=3.7 m; ceiling(1)=4.0+3.5−0.3=7.2 m
  //                        length = |7.2 − 3.7| = 3.500 m
  group('buildBom — groupByFloor', () {
    const nA = NetNode(id: 'nA', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
    const nB = NetNode(id: 'nB', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
    const nC = NetNode(id: 'nC', sheetId: 's1', x: 0, y: 0, floorIndex: 1);
    const nD = NetNode(id: 'nD', sheetId: 's1', x: 60, y: 0, floorIndex: 1);
    const rA = NetEdge(
        id: 'rA',
        fromId: 'nA',
        toId: 'nB',
        service: ServiceType.coldWater,
        kind: EdgeKind.run);
    const rB = NetEdge(
        id: 'rB',
        fromId: 'nC',
        toId: 'nD',
        service: ServiceType.coldWater,
        kind: EdgeKind.run);
    const rC = NetEdge(
        id: 'rC',
        fromId: 'nC',
        toId: 'nA',
        service: ServiceType.coldWater,
        kind: EdgeKind.riser);
    const twoFloorNet =
        Network(nodes: [nA, nB, nC, nD], edges: [rA, rB, rC]);
    const dn25 = EdgeSizing(
      edgeId: 'x',
      service: ServiceType.coldWater,
      flow: FlowRate(0.001),
      diameter: Diameter(0.025),
      velocity: Velocity(1.0),
    );
    const dn50 = EdgeSizing(
      edgeId: 'x',
      service: ServiceType.coldWater,
      flow: FlowRate(0.001),
      diameter: Diameter(0.050),
      velocity: Velocity(0.5),
    );
    const twoFloorSizing = <String, EdgeSizing>{
      'rA': dn25,
      'rB': dn25,
      'rC': dn50,
    };

    test(
        'default (groupByFloor:false) merges the same DN across floors — every '
        'line carries a null floorIndex (byte-identity pin)', () {
      final bom = buildBom(
        net: twoFloorNet,
        sizing: twoFloorSizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      // rA + rB (DN25 runs) merge into one line; the riser is the other.
      expect(bom, hasLength(2));
      expect(bom.every((l) => l.floorIndex == null), isTrue);
      final run = bom.firstWhere((l) => l.kind == EdgeKind.run);
      expect(run.segmentCount, 2);
      // 5.000 + 3.000 = 8.000 m
      expect(run.totalLength.meters, closeTo(8.000, 1e-9));
    });

    test(
        'groupByFloor:true splits the same DN onto per-floor lines; the riser '
        'stays a single ungrouped (null-floor) line', () {
      final bom = buildBom(
        net: twoFloorNet,
        sizing: twoFloorSizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
        groupByFloor: true,
      );
      // Two run lines (floor 0 + floor 1) + one riser line = 3 lines.
      expect(bom, hasLength(3));

      final runF0 = bom.singleWhere(
          (l) => l.kind == EdgeKind.run && l.floorIndex == 0);
      final runF1 = bom.singleWhere(
          (l) => l.kind == EdgeKind.run && l.floorIndex == 1);
      final riser = bom.singleWhere((l) => l.kind == EdgeKind.riser);

      expect(runF0.diameterMm, 25);
      expect(runF0.segmentCount, 1);
      expect(runF0.totalLength.meters, closeTo(5.000, 1e-9));
      expect(runF1.diameterMm, 25);
      expect(runF1.segmentCount, 1);
      expect(runF1.totalLength.meters, closeTo(3.000, 1e-9));
      // The riser spans floors → null floorIndex, one line, 3.500 m.
      expect(riser.floorIndex, isNull);
      expect(riser.diameterMm, 50);
      expect(riser.totalLength.meters, closeTo(3.500, 1e-9));

      // Sort: run/floor0 → run/floor1 → riser.
      expect(bom[0], same(runF0));
      expect(bom[1], same(runF1));
      expect(bom[2], same(riser));
    });

    test('bomToCsv emits a 1-based floor column (empty for risers)', () {
      final bom = buildBom(
        net: twoFloorNet,
        sizing: twoFloorSizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
        groupByFloor: true,
      );
      final lines = bomToCsv(bom).trim().split('\n');
      // N13: the tag column sits right after kind, before the floor column.
      expect(lines.first,
          'service,kind,tag,floor,nominal_size_mm,material,length_m,segments');
      // Floor 0 → human 1 (tag CW-F1), floor 1 → human 2 (CW-F2), riser → the
      // stack tag CW-R1 with an empty floor cell (all PPR).
      expect(lines, contains('coldWater,run,CW-F1,1,25,PPR,5.00,1'));
      expect(lines, contains('coldWater,run,CW-F2,2,25,PPR,3.00,1'));
      expect(lines, contains('coldWater,riser,CW-R1,,50,PPR,3.50,1'));
    });

    test('bomToCsv keeps no floor column for the default (un-grouped) build',
        () {
      final bom = buildBom(
        net: twoFloorNet,
        sizing: twoFloorSizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      expect(bomToCsv(bom).split('\n').first,
          'service,kind,tag,nominal_size_mm,material,length_m,segments');
    });

    // ── N13: the stable element tag on each BomLine ─────────────────────────
    test('BomLine.tag carries the riser stack tag + the run floor tag', () {
      final grouped = buildBom(
        net: twoFloorNet,
        sizing: twoFloorSizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
        groupByFloor: true,
      );
      // Runs (floor-grouped): service code + 1-based floor.
      expect(
          grouped
              .singleWhere((l) => l.kind == EdgeKind.run && l.floorIndex == 0)
              .tag,
          'CW-F1');
      expect(
          grouped
              .singleWhere((l) => l.kind == EdgeKind.run && l.floorIndex == 1)
              .tag,
          'CW-F2');
      // Riser: its per-service stack tag (same as riserTags), never a floor tag.
      expect(grouped.singleWhere((l) => l.kind == EdgeKind.riser).tag, 'CW-R1');

      // Ungrouped: a run line carries the bare service code (no single floor).
      final ungrouped = buildBom(
        net: twoFloorNet,
        sizing: twoFloorSizing,
        calibrationBySheet: _calibrationBySheet,
        building: _building,
      );
      expect(ungrouped.singleWhere((l) => l.kind == EdgeKind.run).tag, 'CW');
      expect(ungrouped.singleWhere((l) => l.kind == EdgeKind.riser).tag, 'CW-R1');
    });
  });
}
