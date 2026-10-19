// Round 29 (2026-10-18) — issued-drawing findings:
//
//   drawings-3-1  the mechanical riser never prints a pipe tag fused into
//                 another tag; a sheet that cannot avoid it carries the
//                 overlap warning (PDF + DXF).
//   drawings-3-2  a paginated riser's LANJUT KE <floor> stub label is never
//                 struck by the neighbouring riser.
//   drawings-3-3  a true-width duct's tag clears its own outline.
//   drawings-3-6  a committed tag whose leader strikes a placed label is
//                 counted (overlap warning), never silent.
import 'dart:convert';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_annotation_layout.dart'
    show planDoubleLineOutline, planOverlapWarning;
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import '../tool/generate_export_samples.dart'
    show buildNetwork, buildSampleElectrical, sizeNetwork, calibrations, building;

typedef _Box = ({double minX, double minY, double maxX, double maxY});

_Box _box(SldLabel l) => (
      minX: l.x,
      minY: l.y - l.size,
      maxX: l.x + l.text.length * l.size * kMechRiserLabelCharW,
      maxY: l.y,
    );

/// Two label boxes FUSE when their glyph bodies overlap by more than a
/// hairline in both axes.
bool _fused(SldLabel a, SldLabel b) {
  final x = _box(a), y = _box(b);
  final dx = (x.maxX < y.maxX ? x.maxX : y.maxX) -
      (x.minX > y.minX ? x.minX : y.minX);
  final dy = (x.maxY < y.maxY ? x.maxY : y.maxY) -
      (x.minY > y.minY ? x.minY : y.minY);
  return dx > 1 && dy > 1;
}

/// Liang–Barsky: does [s] pass through the open interior of [b] (inset 0.5)?
bool _crosses(SldLine s, _Box b) {
  const inset = 0.5;
  final minX = b.minX + inset, maxX = b.maxX - inset;
  final minY = b.minY + inset, maxY = b.maxY - inset;
  var t0 = 0.0, t1 = 1.0;
  final dx = s.x2 - s.x1, dy = s.y2 - s.y1;
  for (final (p, q) in [
    (-dx, s.x1 - minX),
    (dx, maxX - s.x1),
    (-dy, s.y1 - minY),
    (dy, maxY - s.y1),
  ]) {
    if (p == 0) {
      if (q < 0) return false;
    } else {
      final t = q / p;
      if (p < 0) {
        if (t > t1) return false;
        if (t > t0) t0 = t;
      } else {
        if (t < t0) return false;
        if (t < t1) t1 = t;
      }
    }
  }
  return t0 < t1;
}

List<String> _fusedPairs(SldSheet s) {
  final labels = s.prims.whereType<SldLabel>().toList();
  return [
    for (var i = 0; i < labels.length; i++)
      for (var j = i + 1; j < labels.length; j++)
        if (_fused(labels[i], labels[j]))
          '"${labels[i].text}" x "${labels[j].text}"',
  ];
}

NetNode _n(String id, double x, int floor) => NetNode(
    id: id, sheetId: 's1', x: x, y: 0, floorIndex: floor, role: NodeRole.main);

void main() {
  group('drawings-3-1 — no fused pipe tags on the riser', () {
    test('the harness riser: no two tags fused, overlapCount 0', () {
      final net = buildNetwork();
      final sizing = sizeNetwork(net);
      final s = buildMechanicalRiserSld(
        network: net,
        sizing: sizing,
        building: building,
        edgeLengths: {
          for (final e in net.edges)
            e.id: edgeLength(e, net,
                calibrationBySheet: calibrations, building: building)
        },
        detailCallouts: true,
        hotWaterRecirc:
            net.edges.any((e) => e.service == ServiceType.hotWater),
      );
      // Was: '32-CW-PPR-BOOSTER - 4.2 m' over '15-CW-PPR-BOOSTER - 5.4 m'
      // (91 x 4 units of shared box) with no warning.
      expect(_fusedPairs(s), isEmpty);
      expect(s.overlapCount, 0);
    });

    test('a sheet carrying unresolved overlaps prints the warning on the PDF '
        'and the DXF', () {
      const sheet = SldSheet(
        prims: [SldLabel(0, 10, 'A'), SldLine(0, 0, 50, 0)],
        minX: 0,
        minY: 0,
        maxX: 100,
        maxY: 100,
        legend: [],
        supplyNote: '',
        overlapCount: 2,
      );
      final note = planOverlapWarning(2)!;
      final pdf = latin1.decode(sldSheetToPdf(sheet: sheet));
      expect(pdf, contains('labels overlap'));
      final dxf = sldSheetToDxf(sheet: sheet);
      expect(dxf, contains(note));
      // Clean sheets stay byte-identical (no note).
      const clean = SldSheet(
        prims: [SldLabel(0, 10, 'A')],
        minX: 0,
        minY: 0,
        maxX: 100,
        maxY: 100,
        legend: [],
        supplyNote: '',
      );
      expect(latin1.decode(sldSheetToPdf(sheet: clean)),
          isNot(contains('labels overlap')));
    });
  });

  group('drawings-3-2 — LANJUT stubs are never struck by a neighbour', () {
    test('seven adjacent service stacks crossing a middle page: no LANJUT '
        'label is crossed by any line', () {
      const storeys = 6;
      const svcs = [
        ServiceType.coldWater,
        ServiceType.hotWater,
        ServiceType.drainage,
        ServiceType.vent,
        ServiceType.rainwater,
        ServiceType.fireHydrant,
        ServiceType.fireSprinkler,
      ];
      // Stacks 10 plan px apart: the lanes land closer than one LANJUT
      // label's width (the CW stub's label used to be struck by the HW
      // stub reserved only after it was placed).
      final net = Network(nodes: [
        for (var f = 0; f < storeys; f++)
          for (var k = 0; k < svcs.length; k++) _n('N$k-$f', 200 + 10.0 * k, f),
      ], edges: [
        for (var f = 0; f < storeys - 1; f++)
          for (var k = 0; k < svcs.length; k++)
            NetEdge(
                id: 'e$k-$f',
                fromId: 'N$k-$f',
                toId: 'N$k-${f + 1}',
                service: svcs[k],
                kind: EdgeKind.riser),
      ]);
      final b = BuildingLevels([
        for (var i = 0; i < storeys; i++)
          Floor('Lantai ${i + 1}', const Length(3.5)),
      ]);
      for (final r in [(lo: 2, hi: 3), (lo: 0, hi: 2), (lo: 3, hi: 5)]) {
        final s = buildMechanicalRiserSld(
            network: net, building: b, floorRange: r);
        final lanjut = s.prims
            .whereType<SldLabel>()
            .where((l) => l.text.startsWith('LANJUT KE '))
            .toList();
        expect(lanjut, isNotEmpty, reason: '$r');
        final hits = [
          for (final l in lanjut)
            for (final ln in s.prims.whereType<SldLine>())
              if (_crosses(ln, _box(l)))
                '"${l.text}" @(${l.x},${l.y}) x (${ln.x1},${ln.y1})-'
                    '(${ln.x2},${ln.y2})',
        ];
        expect(hits, isEmpty, reason: '$r\n${hits.join('\n')}');
      }
    });
  });

  group('drawings-3-3 — a duct tag clears its drawn outline', () {
    test('property: for any paper half-width, the tag text never sits inside '
        'the duct outline (|v| >= half-width + 0.7 ts)', () {
      const ts = 2.5; // mm on paper
      for (final hw in [0.0, 1.0, 2.0, 3.15, 5.0, 8.0]) {
        final layout = PlanLabelLayout();
        layout.addRun('d', 0, 0, 200, 0);
        if (hw > 0) {
          for (final o in planDoubleLineOutline(0, 0, 200, 0, hw)) {
            layout.addRun('d', o.x1, o.y1, o.x2, o.y2);
          }
        }
        final p = placePlanLabel(
            ax: 0,
            ay: 0,
            bx: 200,
            by: 0,
            text: 'SA-F2 - %%c315 - 7.7 m',
            textSize: ts,
            layout: layout,
            ownRunId: 'd',
            ownHalfWidth: hw);
        // Horizontal run: v is the y offset. A baseline at |y| below the
        // centreline carries its text box toward the line (+ts), above it
        // away; either way the near edge of the text is >= hw + 0.7 ts.
        final line = p.lines.single;
        // Upper side: the text spans v in [d, d + ts]; lower: [-d - ts, -d].
        final nearEdge = line.y > 0 ? line.y : -line.y - ts;
        expect(nearEdge, greaterThanOrEqualTo(hw + 0.7 * ts - 1e-9),
            reason: 'hw $hw: baseline ${line.y}');
      }
    });
  });

  group('drawings-3-6 — off-sheet riser tags at one board', () {
    test('2..5 off-sheet risers at one board: no tag is struck by another '
        "tag's leader unless the sheet counts it (overlap warning)", () {
      for (var n = 2; n <= 5; n++) {
        final data = ElectricalPlanData(nodes: const [
          ElectricalPlanNode(
              x: 0, y: 0, tag: 'MDP', kind: ElectricalPlanNodeKind.panel),
        ], routes: const [], risers: [
          for (var i = 0; i < n; i++)
            ElectricalPlanRiser(
                x: 0,
                y: 0,
                text: 'ke LP-$i (Lantai ${i + 1}) - ${8.2 + i} m',
                sense: 'UP'),
        ]);
        final ann = layoutElectricalPlanAnnotations(data,
            map: (x, y) => (x: x, y: -y), sizes: kElectricalPlanPdfSizes);
        final ts = kElectricalPlanPdfSizes.routeTextSize;
        _Box box(LeaderedLabelPlacement p) {
          final l = p.lines.first;
          return (
            minX: l.x,
            minY: l.y - ts,
            maxX: l.x + l.text.length * ts * 0.55,
            maxY: l.y + ts,
          );
        }

        var strikes = 0;
        for (final a in ann.risers) {
          final la = a.label;
          if (la.leaderAnchor == null) continue;
          final seg = SldLine(la.leaderAnchor!.x, la.leaderAnchor!.y,
              la.leaderEnd!.x, la.leaderEnd!.y);
          for (final b in ann.risers) {
            if (identical(a, b)) continue;
            if (_crosses(seg, box(b.label))) strikes++;
          }
        }
        expect(strikes == 0 || ann.overlapCount > 0, isTrue,
            reason: '$n risers: $strikes silent strike(s)');
        expect(ann.risers.length, n);
      }
    });

    test('the harness ground floor at its plotted 1:50: the LP-1 / PP-1 tags '
        'each sit beside their own mark, no leader strikes a tag', () {
      final project = buildSampleElectrical();
      final result = computeSystem(const PuilProfile(), project,
          calibrationBySheet: calibrations,
          building: building,
          originFaultLevel: const Current(16000),
          busbarClearingTimeS: 0.1);
      final data = buildElectricalPlanData(
          project: project,
          result: result,
          sheetId: 's0',
          floorIndex: 0,
          calibrations: calibrations,
          building: building);
      final n = electricalPlanPlottedScaleDenominator(
          data: data,
          projectName: 'P',
          sheetName: 'S',
          dateString: 'd',
          metersPerPixel: calibrations['s0']?.metersPerPixel)!;
      // The PDF's uniform plot scale: px -> m -> paper mm -> pt.
      final s = calibrations['s0']!.metersPerPixel * 1000 / n * 72 / 25.4;
      final ann = layoutElectricalPlanAnnotations(data,
          map: (x, y) => (x: x * s, y: -y * s),
          sizes: kElectricalPlanPdfSizes);
      expect(ann.risers, hasLength(2));
      // Was: PP-1's tag escaped with a leader straight through LP-1's tag,
      // overlapCount 0.
      for (final r in ann.risers) {
        expect(r.label.leaderAnchor, isNull, reason: r.riser.text);
      }
      expect(ann.overlapCount, 0);
      // Opposite sides of the board: each tag beside its own mark.
      final xs = [for (final r in ann.risers) r.label.lines.first.x - r.x2];
      expect(xs[0].sign, isNot(xs[1].sign));
    });
  });
}
