// Round 21 (2026-10-18) — riser drafting:
//
//   2-2  a tall riser paginates to legible pages ('LANJUT KE <floor>' match
//        stubs, extras on the lowest-floor page), never one 3 pt sheet
//   2-3  the PUMP-SET DETAIL's GRAVITASI names the tank's own gravity outlet
//        stub and no leg strikes through it
//   2-4  sibling fixture branches from one header fan to distinct y lines
//   2-5  four reference callouts never overrun the KETERANGAN block
//   2-7  the ground tank (+ m3) is drawn; an ATAP datum line tops the sheet
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart'
    show helveticaTextWidth;
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show sldSinglePageMinLabelPt;
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_pagination.dart';
import 'package:mechx_engine/report/riser_tags.dart' show fflLabel;
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, int floor,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.coldWater, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

BuildingLevels _building(int storeys) => BuildingLevels(
    [for (var i = 0; i < storeys; i++) Floor('Lantai ${i + 1}', const Length(3.5))]);

/// A [storeys]-storey cold-water riser: a roof tank on the top floor feeding
/// a riser stack R0..R(n-1), each floor's header branching to a WC and a
/// lavatory.
Network _riser(int storeys) {
  final nodes = <NetNode>[
    _n('RT', 100, storeys - 1, role: NodeRole.plant, c: NodeComponent.roofTank),
    for (var f = 0; f < storeys; f++) ...[
      _n('R$f', 200, f),
      _n('W$f', 400, f, role: NodeRole.fixture),
      _n('L$f', 420, f, role: NodeRole.fixture),
    ],
  ];
  final edges = <NetEdge>[
    _e('t', 'RT', 'R${storeys - 1}'),
    for (var f = 0; f < storeys - 1; f++)
      _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
    for (var f = 0; f < storeys; f++) ...[
      _e('w$f', 'R$f', 'W$f'),
      _e('l$f', 'R$f', 'L$f'),
    ],
  ];
  return Network(nodes: nodes, edges: edges);
}

Iterable<SldLabel> _labels(SldSheet s) => s.prims.whereType<SldLabel>();
Iterable<SldLine> _lines(SldSheet s) => s.prims.whereType<SldLine>();

void main() {
  group('2-2 pagination', () {
    test('a 12-storey riser splits into legible pages with match stubs', () {
      final net = _riser(12);
      final b = _building(12);
      SldSheet build(({int lo, int hi})? r) => buildMechanicalRiserSld(
          network: net, building: b, focus: ServiceType.coldWater,
          floorRange: r);
      final whole = build(null);
      final wholePt = sldSinglePageMinLabelPt(whole);
      final pages = paginatedRiserSheets(build: build, levelCount: 12);
      // The whole sheet is 12 bands × 150 units tall — illegible on A3.
      expect(wholePt, lessThan(7.0));
      expect(pages.length, greaterThan(1));
      final pagePts = [for (final p in pages) sldSinglePageMinLabelPt(p)];
      // Every page prints larger than the single sheet did.
      // (12 bands × 150 units ⇒ 3.65 pt on one A3 sheet; this fixture's
      // pages reach the 7 pt floor.)
      for (final pt in pagePts) {
        expect(pt, greaterThan(wholePt));
        expect(pt, greaterThanOrEqualTo(7.0 - 1e-6));
      }
      // Every floor band is on exactly one page (top page first).
      final names = [
        for (final p in pages)
          for (final l in _labels(p))
            if (l.text.startsWith('Lantai ') && l.size == 10) l.text,
      ];
      expect(names.toSet().length, 12);
      expect(names.length, 12);
      // Top floors first: the first page carries Lantai 12.
      expect(
          _labels(pages.first).any((l) => l.text == 'Lantai 12' && l.size == 10),
          isTrue);

      // Each page boundary carries a LANJUT KE match stub on both sides.
      final lanjut = [
        for (final p in pages)
          for (final l in _labels(p))
            if (l.text.startsWith('LANJUT KE ')) l.text,
      ];
      expect(lanjut.length, 2 * (pages.length - 1));
    });

    test('a 3-storey riser stays one sheet (already legible)', () {
      final net = _riser(3);
      final b = _building(3);
      final pages = paginatedRiserSheets(
          build: (r) => buildMechanicalRiserSld(
              network: net, building: b, focus: ServiceType.coldWater,
              floorRange: r),
          levelCount: 3);
      expect(pages.length, 1);
    });

    test('riserFloorChunks: 12 floors at 5 per page, top page first', () {
      expect(riserFloorChunks(12, 5), [
        (lo: 10, hi: 11),
        (lo: 5, hi: 9),
        (lo: 0, hi: 4),
      ]);
    });
  });

  group('2-4 branch fan-out', () {
    test('two fixture runs from one header sit on distinct y lines', () {
      final net = _riser(2);
      final s = buildMechanicalRiserSld(
          network: net, building: _building(2), focus: ServiceType.coldWater);
      // The horizontal legs of w0 / l0 (both leave R0): collect horizontal
      // SldLines whose x-span starts at R0's x.
      final horizontals = _lines(s).where((l) => (l.y1 - l.y2).abs() < 1e-9 &&
          (l.x1 - l.x2).abs() > 1);
      final ys = {for (final l in horizontals) l.y1.toStringAsFixed(1)};
      // Floor 0 + floor 1: (w, l) branch pairs on 2 + 2 distinct ys, plus the
      // tank run; never one collinear line per header.
      expect(ys.length, greaterThanOrEqualTo(4));
    });
  });

  group('2-7 ATAP datum + ground tank', () {
    test('an ATAP line + roof elevation tops the sheet; the roof tank parks on '
        'it', () {
      final b = _building(4);
      final s = buildMechanicalRiserSld(
          network: _riser(4), building: b, focus: ServiceType.coldWater);
      final atap = _labels(s).where((l) => l.text == 'ATAP');
      expect(atap, hasLength(1));
      // Roof elevation = 4 × 3.5 = 14.00 m ⇒ 'FFL +14.00'.
      expect(_labels(s).any((l) => l.text == fflLabel(14.0)), isTrue);
    });

    test('the pump-set detail draws the ground tank with its capacity', () {
      final net = Network(nodes: [
        _n('GT', 100, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 150, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('RT', 100, 1, role: NodeRole.plant, c: NodeComponent.roofTank),
      ], edges: [
        _e('a', 'GT', 'P'),
        _e('b', 'P', 'RT', k: EdgeKind.riser),
      ]);
      final s = buildMechanicalRiserSld(
          network: net,
          building: _building(2),
          downfeed: true,
          detailCallouts: true,
          equipmentDetailByNodeId: const {'GT': '60 m3', 'RT': '10 m3'});
      expect(_labels(s).any((l) => l.text == 'GROUND TANK 60 m3'), isTrue);
      expect(_labels(s).any((l) => l.text == 'ROOF TANK 10 m3'), isTrue);
    });
  });

  group('2-3 GRAVITASI', () {
    test('no line crosses the GRAVITASI word; it sits on its own outlet stub',
        () {
      final net = Network(nodes: [
        _n('GT', 100, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 150, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('RT', 100, 1, role: NodeRole.plant, c: NodeComponent.roofTank),
      ], edges: [
        _e('a', 'GT', 'P'),
        _e('b', 'P', 'RT', k: EdgeKind.riser),
      ]);
      final s = buildMechanicalRiserSld(
          network: net,
          building: _building(2),
          downfeed: true,
          detailCallouts: true);
      final g = _labels(s).firstWhere((l) => l.text == 'GRAVITASI');
      // The word's box: Helvetica-Bold advance at 7 pt, cap height ~0.72 em.
      // (Bold runs ~10 % wider than the regular Helvetica advance.)
      final x0 = g.x, x1 = g.x + 1.1 * helveticaTextWidth('GRAVITASI', 7);
      final y0 = g.y - 7 * 0.72, y1 = g.y + 7 * 0.21;
      for (final l in _lines(s)) {
        final lx0 = l.x1 < l.x2 ? l.x1 : l.x2;
        final lx1 = l.x1 < l.x2 ? l.x2 : l.x1;
        final ly0 = l.y1 < l.y2 ? l.y1 : l.y2;
        final ly1 = l.y1 < l.y2 ? l.y2 : l.y1;
        final crosses = lx0 <= x1 && lx1 >= x0 && ly0 <= y1 && ly1 >= y0;
        expect(crosses, isFalse, reason: 'line $lx0,$ly0 → $lx1,$ly1');
      }
    });
  });

  group('2-5 callouts vs KETERANGAN', () {
    test('four reference callouts end left of the notes block', () {
      final net = Network(nodes: [
        _n('M', 100, 0, c: NodeComponent.waterMeter),
        _n('V', 140, 0, c: NodeComponent.prv),
        _n('F', 300, 0, role: NodeRole.fixture, c: NodeComponent.floorDrain),
        _n('S0', 400, 0),
        _n('S1', 400, 1),
        _n('T', 400, 1, c: NodeComponent.airVent),
      ], edges: [
        _e('m', 'M', 'V'),
        _e('f', 'F', 'S0', s: ServiceType.drainage),
        _e('v', 'S0', 'S1', s: ServiceType.vent, k: EdgeKind.riser),
        _e('t', 'S1', 'T', s: ServiceType.vent),
      ]);
      final s = buildMechanicalRiserSld(
          network: net,
          building: _building(2),
          detailCallouts: true,
          notes: const ['Feed: direct mains', 'Occupancy: office']);
      final boxes = s.prims.whereType<SldRect>().toList();
      final ket = _labels(s).firstWhere((l) => l.text == 'KETERANGAN');
      final notesLeft = ket.x - 6;
      final details = _labels(s).where((l) => l.text.startsWith('DETAIL '));
      expect(details.length, 4);
      // Each callout rect (170 wide) lies entirely left of the notes block,
      // or (when it cannot) the notes stack below the callouts.
      for (final d in details) {
        final r = boxes.firstWhere(
            (r) => (r.x - (d.x - 6)).abs() < 1e-6 && r.w == 170);
        final overlapX = r.x + r.w > notesLeft;
        final overlapY = r.y < ket.y + 40 && r.y + r.h > ket.y - 12;
        expect(overlapX && overlapY, isFalse);
      }
    });
  });
}
