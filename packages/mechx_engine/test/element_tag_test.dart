/// N13 — one stable element tag across the plan, riser single-line, BOM and
/// calc report. These tests pin the shared [elementTags]/[elementTagForEdge]
/// scheme and, critically, the CROSS-ARTIFACT invariant: the SAME drawn element
/// resolves to the SAME tag string on all four deliverables so a run/riser can
/// be traced across the issued set (instead of matched by a bare, ambiguous DN).
library;

import 'dart:convert';

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // Two-floor cold-water fixture: a floor-0 branch run + a riser lifting from
  // floor 0 to floor 1 (so both a run tag and a riser tag are exercised).
  const building = BuildingLevels([
    Floor('Ground', Length(4.0)),
    Floor('Level 1', Length(3.5)),
  ]);
  const calibrations = <String, ScaleCalibration>{'s1': ScaleCalibration(0.05)};

  const n0 = NetNode(id: 'n0', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
  const n1 = NetNode(id: 'n1', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
  const n2 = NetNode(id: 'n2', sheetId: 's1', x: 0, y: 0, floorIndex: 1);
  const runEdge = NetEdge(
      id: 'run', fromId: 'n0', toId: 'n1', service: ServiceType.coldWater);
  const riserEdge = NetEdge(
      id: 'riser',
      fromId: 'n2',
      toId: 'n0',
      service: ServiceType.coldWater,
      kind: EdgeKind.riser);
  const net = Network(nodes: [n0, n1, n2], edges: [runEdge, riserEdge]);

  const sizing = <String, EdgeSizing>{
    'run': EdgeSizing(
      edgeId: 'run',
      service: ServiceType.coldWater,
      flow: FlowRate(0.001),
      diameter: Diameter(0.025), // DN25
      velocity: Velocity(1.0),
    ),
    'riser': EdgeSizing(
      edgeId: 'riser',
      service: ServiceType.coldWater,
      flow: FlowRate(0.001),
      diameter: Diameter(0.050), // DN50
      velocity: Velocity(0.5),
    ),
  };

  group('elementTagForEdge / elementTags', () {
    test('a riser resolves to its per-service stack tag', () {
      final risers = riserTags(net, null);
      expect(elementTagForEdge(net, riserEdge, risers), 'CW-R1');
    });

    test('a run resolves to its service code + 1-based floor', () {
      final risers = riserTags(net, null);
      expect(elementTagForEdge(net, runEdge, risers), 'CW-F1');
    });

    test('elementTags keys every edge with its stable tag', () {
      expect(elementTags(net), {'run': 'CW-F1', 'riser': 'CW-R1'});
    });

    test('a run with no from-node degrades to the bare service code', () {
      const orphan = Network(nodes: [], edges: [
        NetEdge(id: 'x', fromId: 'gone', toId: 'nope', service: ServiceType.hotWater),
      ]);
      expect(elementTags(orphan), {'x': 'HW'});
    });
  });

  // ── The N13 headline: the SAME element → the SAME tag on all four artifacts ──
  group('cross-artifact tag consistency', () {
    final edgeLengths = <String, Length>{
      for (final e in net.edges)
        e.id: edgeLength(e, net,
            calibrationBySheet: calibrations, building: building),
    };
    final tags = elementTags(net);

    // 1) PLAN (annotated PDF): the tag rides each run/riser label.
    final planText = latin1.decode(planToPdf(
      net: net,
      sizing: sizing,
      edgeLengths: edgeLengths,
      sheetId: 's1',
      floorIndex: 0,
      projectName: 'X',
      sheetName: 'Ground',
      dateString: 'd',
      edgeTags: tags,
    ));

    // 2) RISER single-line: the riser tag is drawn as an SldLabel.
    final riserSheet = buildMechanicalRiserSld(
      network: net,
      sizing: sizing,
      building: building,
    );
    Set<String> riserLabels() => {
          for (final p in riserSheet.prims)
            if (p is SldLabel) p.text,
        };

    // 3) BOM (floor-grouped, the issued deliverable): the row's tag column.
    final bom = buildBom(
      net: net,
      sizing: sizing,
      calibrationBySheet: calibrations,
      building: building,
      groupByFloor: true,
    );

    // 4) Calc-report run/riser schedule.
    final schedule = buildRunSchedule(
      net: net,
      sizing: sizing,
      edgeLengths: edgeLengths,
    );

    test('the riser reads CW-R1 on the plan, riser, BOM and schedule', () {
      const tag = 'CW-R1';
      // Source of truth.
      expect(tags['riser'], tag);
      // Plan.
      expect(planText, contains(tag));
      // Riser single-line.
      expect(riserLabels(), contains(tag));
      // BOM.
      expect(bom.singleWhere((l) => l.kind == EdgeKind.riser).tag, tag);
      // Schedule.
      expect(schedule.singleWhere((r) => r.kind == EdgeKind.riser).tag, tag);
    });

    test('the run reads CW-F1 on the plan, BOM and schedule', () {
      const tag = 'CW-F1';
      expect(tags['run'], tag);
      expect(planText, contains(tag));
      expect(bom.singleWhere((l) => l.kind == EdgeKind.run).tag, tag);
      expect(schedule.singleWhere((r) => r.kind == EdgeKind.run).tag, tag);
    });
  });
}
