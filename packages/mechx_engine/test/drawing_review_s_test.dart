// Drawing review S1 / S2 (2026-11-13) — the finishing cures for the last
// overlap stamps: S1 splits a detail too dense for one sheet (one cluster per
// sheet, then halves along the longer side with MATCH LINES); S2 gives a
// crowded riser floor band its own page / a second key row. Pure rules.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart'
    show
        riserPitchEscalation,
        kMechRiserPitchSteps,
        kMechRiserBandSteps,
        riserColumnSplit,
        buildMechanicalRiserSld;
import 'package:mechx_engine/report/plan_detail.dart';
import 'package:mechx_engine/report/plan_detail_sheet.dart';
import 'package:mechx_engine/report/riser_pagination.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/apartment.dart';

void main() {
  group('S1 — split detail', () {
    test('a wide box splits across x in the anchor gap nearest the middle', () {
      const r = (minX: 0.0, minY: 0.0, maxX: 100.0, maxY: 40.0);
      // Anchors at 10, 30, 70 (x): gaps at 20 and 50; 50 is the middle.
      final (a, b) = planDetailSplitRect(r,
          const [(x: 10, y: 5), (x: 30, y: 5), (x: 70, y: 5), (x: 500, y: 5)]);
      expect(a, (minX: 0.0, minY: 0.0, maxX: 50.0, maxY: 40.0));
      expect(b, (minX: 50.0, minY: 0.0, maxX: 100.0, maxY: 40.0));
    });

    test('a tall box splits across y; no anchors -> the middle', () {
      const r = (minX: 0.0, minY: 0.0, maxX: 20.0, maxY: 80.0);
      final (a, b) = planDetailSplitRect(r, const []);
      expect(a.maxY, 40.0);
      expect(b.minY, 40.0);
      // An anchor never sits on the cut (each element labelled once).
      final (c, d) = planDetailSplitRect(
          r, const [(x: 5, y: 10), (x: 5, y: 12), (x: 5, y: 60)]);
      expect(c.maxY, 36.0); // gap 12..60 -> 36 (nearest the middle 40)
      expect(d.minY, 36.0);
    });

    test('shared cuts: touching pieces name each other, apart ones do not', () {
      final cuts = planDetailSharedCuts(const [
        (minX: 0.0, minY: 0.0, maxX: 50.0, maxY: 40.0),
        (minX: 50.0, minY: 10.0, maxX: 100.0, maxY: 60.0),
        (minX: 300.0, minY: 0.0, maxX: 310.0, maxY: 10.0),
      ]);
      expect(cuts[0], hasLength(1));
      expect(
          cuts[0].single, (x1: 50.0, y1: 10.0, x2: 50.0, y2: 40.0, other: 1));
      expect(cuts[1].single.other, 0);
      expect(cuts[2], isEmpty);
    });

    test('a split piece draws its match line and names the neighbour', () {
      final net = Network(nodes: [
        for (var i = 0; i < 4; i++)
          NetNode(
              id: 'n$i', sheetId: 's', x: 10.0 + 25 * i, y: 20, floorIndex: 0),
      ], edges: [
        for (var i = 0; i < 3; i++)
          NetEdge(
              id: 'e$i',
              fromId: 'n$i',
              toId: 'n${i + 1}',
              service: ServiceType.coldWater),
      ]);
      const match =
          PlanDetailMatch(50, 0, 50, 40, letter: 'B', sheetRef: 'M-502');
      final plot = planDetailSheetPlot(
        net: net,
        sizing: const {},
        edgeLengths: const {'e0': Length(0.25)},
        sheetId: 's',
        floorIndex: 0,
        metersPerPixel: 0.01,
        details: const [
          PlanDetailCallout(
              letter: 'A',
              rectPx: (minX: 0, minY: 0, maxX: 50, maxY: 40),
              sheetRef: 'M-501',
              matches: [match]),
        ],
        areaMm: (minX: 10, minY: 10, maxX: 400, maxY: 250),
      );
      expect(plot.marks.texts.map((t) => t.text),
          contains('MATCH LINE - LIHAT DETAIL B (M-502)'));
      final dashed = plot.marks.lines.where((l) => l.dashed).toList();
      expect(dashed, hasLength(1));
      // Vertical, at the cut, inside the frame.
      final f = plot.details.single.frameMm;
      expect(dashed.single.x1, dashed.single.x2);
      expect(dashed.single.x1, inInclusiveRange(f.minX, f.maxX));
      // The run crossing the cut (n2 at x=60 is outside the box) is drawn as
      // unlabelled context: labelled on the neighbour's sheet instead.
      expect(plot.unlabelledIds, contains('n2'));
    });
  });

  group('S2 — a crowded floor band gets its own page', () {
    // A fake builder: floors 0..1 share a legible page whose key circles
    // still overprint twice; floor 2 cannot join them (too tall at 7 pt).
    SldSheet sheet(double h, int overlaps) => SldSheet(
        prims: const [SldLabel(0, 10, 'X', size: 8)],
        minX: 0,
        minY: 0,
        maxX: 600,
        maxY: h,
        legend: const [],
        supplyNote: '',
        overlapCount: overlaps);
    List<SldSheet> paginate(int singleOverlaps) => paginatedRiserSheets(
          build: (r) {
            if (r == null || (r.hi == 2 && r.lo < 2)) return sheet(9000, 0);
            if (r.lo == 0 && r.hi == 1) return sheet(300, 2);
            return sheet(300, r.hi == r.lo && r.lo < 2 ? singleOverlaps : 0);
          },
          levelCount: 3,
        );

    test('the overprinting 2-floor page splits into two clear 1-floor pages',
        () {
      final pages = paginate(0);
      expect(pages, hasLength(3));
      expect(pages.every((p) => p.overlapCount == 0), isTrue);
      // Every page still prints at the 7 pt floor (none flagged).
      expect(pages.every((p) => p.belowMinLabelPt == null), isTrue);
    });

    test('no split when the lone floors overprint as much', () {
      final pages = paginate(1);
      expect(pages, hasLength(2));
      expect(pages.map((p) => p.overlapCount), [0, 2]);
    });
  });

  group('S3 — riser pitch escalation', () {
    SldSheet sheet(double h, int ov) => SldSheet(
        prims: const [],
        minX: 0,
        minY: 0,
        maxX: 600,
        maxY: h,
        legend: const [],
        supplyNote: '',
        overlapCount: ov);

    test('a page that already clears is built once, as drawn', () {
      final calls = <(double, double)>[];
      final s = riserPitchEscalation(
          build: (h, p) {
            calls.add((h, p));
            return sheet(h, 0);
          },
          bandH: 150);
      expect(calls, [(150.0, 1.0)]);
      expect(s.maxY, 150);
    });

    test('disabled (multi-floor page) never re-draws', () {
      final calls = <(double, double)>[];
      final s = riserPitchEscalation(
          build: (h, p) {
            calls.add((h, p));
            return sheet(h, 4);
          },
          bandH: 150,
          enabled: false);
      expect(calls, hasLength(1));
      expect(s.overlapCount, 4);
    });

    test('picks the FIRST step that reaches zero (pitch, then band)', () {
      final calls = <(double, double)>[];
      // Overprints fall with the pitch; zero first at pitch 1.5 x band 1.5.
      final s = riserPitchEscalation(
          build: (h, p) {
            calls.add((h, p));
            final ov = p >= 1.5 && h >= 225 ? 0 : (p >= 1.25 ? 2 : 4);
            return sheet(h * 10 + p, ov);
          },
          bandH: 150);
      expect(s.overlapCount, 0);
      expect(s.maxY, 2250 + 1.5);
      expect(calls.last, (225.0, 1.5));
      expect(calls.first, (150.0, 1.0));
    });

    test('no step clears: the strictly fewest wins, ties keep the earlier', () {
      final s = riserPitchEscalation(
          build: (h, p) => sheet(h * 10 + p, p >= 1.25 ? 1 : 3), bandH: 150);
      expect(s.overlapCount, 1);
      expect(s.maxY, 1500 + 1.25); // first sheet reaching 1, band 1.0
      expect(kMechRiserPitchSteps.first, 1.0);
      expect(kMechRiserBandSteps.first, 1.0);
    });
  });

  group('S4 — a width-bound lone floor splits its fixture columns', () {
    final apt = buildApartment();
    final net = apt.network;
    List<NetNode> floor0(Network n) =>
        n.nodes.where((m) => m.floorIndex == 0).toList();

    test('unit b (tee + its four fixtures) moves; risers and plant stay', () {
      final moved = riserColumnSplit(net, floor0(net))!;
      expect(moved, {'Kb0', 'WCb0', 'LAVb0', 'SHb0', 'KSb0'});
      // Order-independent: shuffled lists split identically.
      final shuffled = Network(
          nodes: net.nodes.reversed.toList(),
          edges: net.edges.reversed.toList());
      expect(riserColumnSplit(shuffled, floor0(shuffled)), moved);
      // One fixture group cannot split.
      expect(
          riserColumnSplit(
              net, floor0(net).where((n) => !moved.contains(n.id)).toList()),
          isNull);
    });

    test('part 1 marks the cut, part 2 continues from it; no part ⇒ as was',
        () {
      SldSheet part(int? k) => buildMechanicalRiserSld(
          network: net,
          building: apt.building,
          floorRange: (lo: 0, hi: 0),
          columnPart: k);
      Set<String> texts(SldSheet s) =>
          s.prims.whereType<SldLabel>().map((l) => l.text).toSet();
      final whole = buildMechanicalRiserSld(
          network: net, building: apt.building, floorRange: (lo: 0, hi: 0));
      expect(texts(part(null)), texts(whole));
      expect(part(null).prims.length, whole.prims.length);
      final p1 = texts(part(1)), p2 = texts(part(2));
      expect(p1, containsAll(['BAGIAN 1/2', 'LANJUT KE Lantai 1 - BAGIAN 2']));
      expect(
          p2, containsAll(['BAGIAN 2/2', 'LANJUTAN DARI Lantai 1 - BAGIAN 1']));
      // Part 2 never continues a riser (the risers ride part 1).
      expect(p2.where((t) => t.startsWith('LANJUT KE')), isEmpty);
      expect(p1.where((t) => t.startsWith('LANJUTAN DARI')), isEmpty);
    });

    SldSheet sheet(int ov, {double h = 300}) => SldSheet(
        prims: const [SldLabel(0, 10, 'X', size: 8)],
        minX: 0,
        minY: 0,
        maxX: 600,
        maxY: h,
        legend: const [],
        supplyNote: '',
        overlapCount: ov);
    // Two floors that never share a page (too tall at 7 pt); floor 0 alone
    // still overprints once.
    List<SldSheet> paginate(int partOverlaps) => paginatedRiserSheets(
          build: (r) => r == null || r.lo != r.hi
              ? sheet(0, h: 9000)
              : sheet(r.lo == 0 ? 1 : 0),
          levelCount: 2,
          buildColumnPart: (r, k, bare) => sheet(k == 2 ? partOverlaps : 0),
        );
    test('kept only when the parts overprint strictly less', () {
      final split = paginate(0);
      expect(split, hasLength(3));
      expect(split.every((p) => p.overlapCount == 0), isTrue);
      final kept = paginate(1);
      expect(kept, hasLength(2));
      expect(kept.last.overlapCount, 1);
    });
  });
}
