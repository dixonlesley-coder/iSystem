// Drawing review — fix round 4 (2026-11-13): the three residual legibility
// defects of the re-checked set (`docs/DRAWING-REVIEW-RECORD.md` "Fix round
// 4"), each pinned on the shared pure layout layer the PDF and the DXF both
// draw from.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart'
    show LabelBox;
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:test/test.dart';

import 'reference/apartment.dart' as apt;
import 'reference/reference_building.dart';
import 'reference/tower.dart' as tower;

double _segDist(double px, double py, LabelSegment s) {
  final dx = s.x2 - s.x1, dy = s.y2 - s.y1;
  final ll = dx * dx + dy * dy;
  final t = ll == 0
      ? 0.0
      : (((px - s.x1) * dx + (py - s.y1) * dy) / ll).clamp(0.0, 1.0);
  final ex = s.x1 + t * dx - px, ey = s.y1 + t * dy - py;
  return math.sqrt(ex * ex + ey * ey);
}

/// Does segment [s] pass through the axis-aligned box [b] (interior)?
bool _segHitsBox(LabelSegment s, LabelBox b) {
  // Sample densely: the boxes here are a few points wide.
  for (var i = 0; i <= 400; i++) {
    final t = i / 400;
    final x = s.x1 + (s.x2 - s.x1) * t, y = s.y1 + (s.y2 - s.y1) * t;
    if (x > b.minX && x < b.maxX && y > b.minY && y < b.maxY) return true;
  }
  return false;
}

SldSheet _riser(ReferenceBuilding b, ({int lo, int hi}) range,
    {MechRiserPlant plant = MechRiserPlant.auto}) {
  final net = b.network;
  final sizing = autoSizeNetwork(net, const SizingContext(),
      leafDemand: const {},
      calibrationBySheet: b.calibrations,
      building: b.building);
  return buildMechanicalRiserSld(
    network: net,
    sizing: sizing,
    building: b.building,
    edgeLengths: {
      for (final e in net.edges)
        e.id: edgeLength(e, net,
            calibrationBySheet: b.calibrations, building: b.building),
    },
    detailCallouts: true,
    floorRange: range,
    plant: plant,
  );
}

/// Every KEY circle of a riser sheet: a circle followed by its number.
List<SldCircle> _keyCircles(SldSheet s) {
  final out = <SldCircle>[];
  for (var i = 0; i + 1 < s.prims.length; i++) {
    final c = s.prims[i], l = s.prims[i + 1];
    if (c is SldCircle &&
        l is SldLabel &&
        RegExp(r'^\d{1,3}$').hasMatch(l.text) &&
        (l.x - c.cx).abs() < c.r &&
        (l.y - c.cy).abs() < c.r) {
      out.add(c);
    }
  }
  return out;
}

/// The drawn SYMBOL strokes of a riser sheet: every thin line of a closed
/// glyph (a tank, an impeller triangle, a fixture triangle, a valve body),
/// every thin box (a junction) and every non-key circle (a pump / fan body).
({List<LabelSegment> lines, List<SldCircle> circles}) _symbols(SldSheet s) {
  final keys = _keyCircles(s).toSet();
  final thin = [
    for (final p in s.prims)
      if (p is SldLine && p.weight == SldWeight.thin)
        (x1: p.x1, y1: p.y1, x2: p.x2, y2: p.y2),
    for (final p in s.prims)
      if (p is SldRect && p.weight == SldWeight.thin) ...[
        (x1: p.x, y1: p.y, x2: p.x + p.w, y2: p.y),
        (x1: p.x + p.w, y1: p.y, x2: p.x + p.w, y2: p.y + p.h),
        (x1: p.x + p.w, y1: p.y + p.h, x2: p.x, y2: p.y + p.h),
        (x1: p.x, y1: p.y + p.h, x2: p.x, y2: p.y),
      ],
  ];
  String k(double x, double y) =>
      '${(x * 100).round()},${(y * 100).round()}';
  final parent = <String, String>{};
  String find(String a) {
    while ((parent[a] ??= a) != a) {
      a = parent[a]!;
    }
    return a;
  }

  for (final l in thin) {
    final ra = find(k(l.x1, l.y1)), rb = find(k(l.x2, l.y2));
    if (ra != rb) parent[ra] = rb;
  }
  final edges = <String, int>{}, nodes = <String, Set<String>>{};
  for (final l in thin) {
    final r = find(k(l.x1, l.y1));
    edges[r] = (edges[r] ?? 0) + 1;
    (nodes[r] ??= {})
      ..add(k(l.x1, l.y1))
      ..add(k(l.x2, l.y2));
  }
  return (
    lines: [
      for (final l in thin)
        if (edges[find(k(l.x1, l.y1))]! >= nodes[find(k(l.x1, l.y1))]!.length)
          l,
    ],
    circles: [
      for (final p in s.prims)
        if (p is SldCircle && !keys.contains(p) && p.r <= 12) p,
    ],
  );
}

void main() {
  group('R1 a key leader never runs through text registered as a box', () {
    test('the leader steps round a detail caption instead of through it', () {
      const ts = 9.0;
      final layout = PlanLabelLayout();
      // A ring of plain (non-text) occupied boxes fills the hugging ring so
      // the key has to step out on a leader.
      for (final b in const [
        (minX: -4.05, minY: -4.05, maxX: 4.05, maxY: -1.35),
        (minX: -4.05, minY: 1.35, maxX: 4.05, maxY: 4.05),
        (minX: -4.05, minY: -4.05, maxX: -1.35, maxY: 4.05),
        (minX: 1.35, minY: -4.05, maxX: 4.05, maxY: 4.05),
      ]) {
        layout.addBox(b);
      }
      // A detail caption just above the element, under the first (straight
      // up) leader slot but clear of that slot's circle.
      const caption = (minX: -40.0, minY: 4.3, maxX: 40.0, maxY: 5.2);
      layout.addTextBox(caption);
      final k = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 1,
          by: 0,
          text: 'RA-L16 · 1200x700',
          textSize: ts,
          layout: layout,
          anchorPoint: (x: 0, y: 0),
          keys: PlanKeyRegistry(),
          keyOnly: true);
      expect(k.keyCircle, isNotNull);
      expect(k.leaderAnchor, isNotNull, reason: 'stepped out on a leader');
      final leader = (
        x1: k.leaderAnchor!.x,
        y1: k.leaderAnchor!.y,
        x2: k.leaderEnd!.x,
        y2: k.leaderEnd!.y
      );
      expect(_segHitsBox(leader, caption), isFalse,
          reason: 'the leader misses the caption');
    });
  });

  group('R2 a riser key circle clears every symbol', () {
    void check(String name, SldSheet s) {
      final sym = _symbols(s);
      for (final c in _keyCircles(s)) {
        for (final l in sym.lines) {
          // Its own leader ends on the circle.
          final onEdge = [
            math.sqrt(math.pow(l.x1 - c.cx, 2) + math.pow(l.y1 - c.cy, 2)),
            math.sqrt(math.pow(l.x2 - c.cx, 2) + math.pow(l.y2 - c.cy, 2)),
          ].any((d) => (d - c.r).abs() < 0.05);
          if (onEdge) continue;
          expect(_segDist(c.cx, c.cy, l) - c.r, greaterThan(0.5),
              reason: '$name: key at (${c.cx}, ${c.cy}) on a symbol stroke');
        }
        for (final o in sym.circles) {
          final d = math.sqrt(
              math.pow(o.cx - c.cx, 2) + math.pow(o.cy - c.cy, 2));
          expect(d - c.r - o.r, greaterThan(0.5),
              reason: '$name: key at (${c.cx}, ${c.cy}) on a symbol circle');
        }
      }
    }

    test('tower: the Lantai 1-2 plant (keys 24 / 25 sat on TK-03 / P-04)', () {
      final tw = tower.buildTower();
      for (final plant in [MechRiserPlant.auto, MechRiserPlant.row]) {
        final s = _riser(tw, (lo: 0, hi: 1), plant: plant);
        expect(_keyCircles(s), isNotEmpty);
        check('tower L1-2 $plant', s);
      }
    });

    test('apartment: the plant level and a typical floor', () {
      final b = apt.buildApartment();
      check('apartment L1', _riser(b, (lo: 0, hi: 0)));
      check('apartment L5', _riser(b, (lo: 4, hi: 4)));
    });
  });
}
