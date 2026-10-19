// Round 29 (2026-10-18) — issued-drawing findings:
//
//   drawings-3-1  the mechanical riser never prints a pipe tag fused into
//                 another tag; a sheet that cannot avoid it carries the
//                 overlap warning (PDF + DXF).
//   drawings-3-2  a paginated riser's LANJUT KE <floor> stub label is never
//                 struck by the neighbouring riser.
//   drawings-3-3  a true-width duct's tag clears its own outline.
//   drawings-3-4  the MV spine's genset / capacitor ties are CONNECTED to the
//                 LV main board (a collector bus), never floating.
//   drawings-3-5  the riser's LV-main -> root lead never runs through the
//                 capacitor-bank glyph.
//   drawings-3-7  run element tags read the building's ground-relative level.
//   drawings-3-8  the master legend's UP / DN glyph is the plan's riser mark.
//   drawings-3-6  a committed tag whose leader strikes a placed label is
//                 counted (overlap warning), never silent.
import 'dart:convert';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/cover_sheet.dart' show buildGeneralNotesSheet;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_annotation_layout.dart'
    show planDoubleLineOutline, planOverlapWarning;
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/riser_tags.dart'
    show elementTags, floorLocatorToken;
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
  group('drawings-3-4 / 3-5 — the MV source spine', () {
    final project = buildSampleElectrical();
    final result = computeSystem(const PuilProfile(), project,
        calibrationBySheet: calibrations,
        building: building,
        originFaultLevel: const Current(16000),
        busbarClearingTimeS: 0.1);

    /// Source-role lines connected (touching within 0.01) to the LV-main
    /// box's outline, by flood fill over shared points / T-junctions.
    Set<SldLine> connectedToBox(SldSheet s) {
      final lv = s.prims
          .whereType<SldLabel>()
          .firstWhere((l) => l.text.contains('RENDAH'));
      final box = s.prims.whereType<SldRect>().firstWhere((r) =>
          lv.x >= r.x - 1 &&
          lv.x <= r.x + r.w + 1 &&
          lv.y >= r.y - 1 &&
          lv.y <= r.y + r.h + 1);
      final lines = s.prims
          .whereType<SldLine>()
          .where((l) => l.role == SldRole.source)
          .toList();
      bool onSeg(double x, double y, SldLine l) {
        const t = 0.01;
        final minX = l.x1 < l.x2 ? l.x1 : l.x2;
        final maxX = l.x1 < l.x2 ? l.x2 : l.x1;
        final minY = l.y1 < l.y2 ? l.y1 : l.y2;
        final maxY = l.y1 < l.y2 ? l.y2 : l.y1;
        return x >= minX - t && x <= maxX + t && y >= minY - t && y <= maxY + t;
      }

      bool touches(SldLine a, SldLine b) =>
          onSeg(a.x1, a.y1, b) ||
          onSeg(a.x2, a.y2, b) ||
          onSeg(b.x1, b.y1, a) ||
          onSeg(b.x2, b.y2, a);
      bool onBox(double x, double y) {
        final onV = ((x - box.x).abs() < 0.01 ||
                (x - box.x - box.w).abs() < 0.01) &&
            y >= box.y - 0.01 &&
            y <= box.y + box.h + 0.01;
        final onH = ((y - box.y).abs() < 0.01 ||
                (y - box.y - box.h).abs() < 0.01) &&
            x >= box.x - 0.01 &&
            x <= box.x + box.w + 0.01;
        return onV || onH;
      }

      final reached = <SldLine>{
        for (final l in lines)
          if (onBox(l.x1, l.y1) || onBox(l.x2, l.y2)) l,
      };
      var grew = true;
      while (grew) {
        grew = false;
        for (final l in lines) {
          if (reached.contains(l)) continue;
          if (reached.any((r) => touches(l, r))) {
            reached.add(l);
            grew = true;
          }
        }
      }
      return reached;
    }

    for (final kind in ['overview', 'riser']) {
      test('$kind: the genset tie and the capacitor bank are wired to the LV '
          'main (was: ties 12 units off the box, touches=false)', () {
        final s = kind == 'overview'
            ? buildElectricalOverview(
                project: project, result: result, sourceChain: true)
            : buildElectricalRiser(
                project: project,
                result: result,
                building: building,
                sourceChain: true);
        final reached = connectedToBox(s);
        final labels = s.prims.whereType<SldLabel>().toList();
        final gen = labels.firstWhere((l) => l.text.startsWith('GENSET'));
        final cap = labels.firstWhere((l) => l.text == 'CAPACITOR BANK');
        // The genset tie: horizontal at the glyph's centre (label y + 2).
        expect(
            reached.any((l) =>
                l.y1 == l.y2 &&
                (l.y1 - (gen.y + 2)).abs() < 0.01 &&
                l.x2 > l.x1 &&
                l.x2 < gen.x),
            isTrue);
        // The capacitor: its top lead (a vertical source line ending at the
        // upper plate, cy - 3 = label y + 2 - 3, left of the label) is
        // reached.
        expect(
            reached.any((l) =>
                l.x1 == l.x2 &&
                l.x1 < cap.x &&
                (l.y2 - (cap.y + 2 - 3)).abs() < 0.01),
            isTrue);
      });
    }

    test('riser: no long source lead runs between the capacitor plates', () {
      final s = buildElectricalRiser(
          project: project,
          result: result,
          building: building,
          sourceChain: true);
      final lines = s.prims.whereType<SldLine>().toList();
      // The plates: two 18-unit horizontals 6 apart, same x span.
      final plates = [
        for (final l in lines)
          if (l.y1 == l.y2 && ((l.x2 - l.x1).abs() - 18).abs() < 0.01) l,
      ];
      final pairs = [
        for (final a in plates)
          for (final b in plates)
            if (a.x1 == b.x1 && (b.y1 - a.y1 - 6).abs() < 0.01) (a, b),
      ];
      expect(pairs, isNotEmpty);
      for (final (top, bottom) in pairs) {
        final minX = top.x1 < top.x2 ? top.x1 : top.x2;
        final maxX = top.x1 < top.x2 ? top.x2 : top.x1;
        for (final l in lines) {
          if (l.y1 != l.y2 || (l.x2 - l.x1).abs() < 30) continue;
          final lx0 = l.x1 < l.x2 ? l.x1 : l.x2;
          final lx1 = l.x1 < l.x2 ? l.x2 : l.x1;
          final overlapsX = lx1 > minX && lx0 < maxX;
          final inBand = l.y1 > top.y1 - 3 && l.y1 < bottom.y1 + 3;
          expect(overlapsX && inBand, isFalse,
              reason: 'lead (${l.x1},${l.y1})-(${l.x2},${l.y2}) through the '
                  'plates at y ${top.y1}..${bottom.y1}');
        }
      }
    });
  });
  group('drawings-3-7 — run tags follow the building levels', () {
    test('basements: [B2, B1, Ground, Lantai 1] with ground index 2 tag '
        'B2 / B1 / GF / L1 (was F1..F4)', () {
      final b = BuildingLevels([
        for (final n in ['Basement 2', 'Basement 1', 'Ground', 'Lantai 1'])
          Floor(n, const Length(3.5)),
      ], groundIndex: 2);
      expect([for (var i = 0; i < 4; i++) floorLocatorToken(i, b)],
          ['B2', 'B1', 'GF', 'L1']);
      // No building ⇒ the legacy 1-based token (byte-identical).
      expect(floorLocatorToken(3, null), 'F4');
      final net = Network(nodes: [
        for (var f = 0; f < 4; f++) ...[
          NetNode(
              id: 'a$f',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: f,
              role: NodeRole.main),
          NetNode(
              id: 'b$f',
              sheetId: 's1',
              x: 100,
              y: 0,
              floorIndex: f,
              role: NodeRole.main),
        ],
      ], edges: [
        for (var f = 0; f < 4; f++)
          NetEdge(
              id: 'r$f',
              fromId: 'a$f',
              toId: 'b$f',
              service: ServiceType.coldWater),
      ]);
      expect(elementTags(net, building: b),
          {'r0': 'CW-B2', 'r1': 'CW-B1', 'r2': 'CW-GF', 'r3': 'CW-L1'});
    });

    test('property: with no basement the token is L<floorIndex> above ground, '
        'and every level of any stack gets a distinct token', () {
      for (var n = 1; n <= 12; n++) {
        for (var g = 0; g < n; g++) {
          final b = BuildingLevels(
              [for (var i = 0; i < n; i++) Floor('F$i', const Length(3))],
              groundIndex: g);
          final tokens = {for (var i = 0; i < n; i++) floorLocatorToken(i, b)};
          expect(tokens.length, n, reason: '$n levels, ground $g');
          if (g == 0) {
            for (var i = 1; i < n; i++) {
              expect(floorLocatorToken(i, b), 'L$i');
            }
          }
        }
      }
    });
  });
  group('drawings-3-8 — the legend keys the plan riser mark', () {
    test('UP / DN rows draw the plan mark (circle + centre dot + sense text), '
        'never the arrow-shaft glyph no plan draws', () {
      final sheet = buildGeneralNotesSheet(
          services: const [ServiceType.coldWater]);
      final labels = sheet.prims.whereType<SldLabel>().toList();
      for (final (meaning, sense) in [
        ('Riser up (naik)', 'UP'),
        ('Riser down (turun)', 'DN'),
      ]) {
        final row = labels.firstWhere((l) => l.text == meaning);
        // The glyph cell: left of the code column on this row.
        final codeLabel = labels.firstWhere(
            (l) => l.text == sense && (l.y - row.y).abs() < 0.01 && l.size > 7);
        bool inCell(double x, double y) =>
            x < codeLabel.x - 1 && (y - (row.y - 3)).abs() <= 12;
        final circles = sheet.prims
            .whereType<SldCircle>()
            .where((c) => inCell(c.cx, c.cy))
            .toList();
        expect(circles.map((c) => c.r).toSet(), {5.0, 1.0}, reason: sense);
        expect(
            labels.any((l) => l.text == sense && l.size == 7 && inCell(l.x, l.y)),
            isTrue,
            reason: sense);
        expect(
            sheet.prims
                .whereType<SldLine>()
                .where((l) => inCell(l.x1, l.y1) && inCell(l.x2, l.y2)),
            isEmpty,
            reason: '$sense: no arrow shaft');
      }
    });
  });
}
