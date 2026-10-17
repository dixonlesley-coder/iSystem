// Riser drawing quality — bus TRACKS + channel-strike label pins (audit
// 2026-10 drawing-output-1 residual + drawing-output residual).
//
// Geometry used below (all from `electrical_sld_drawing.dart`):
//   gutter 150, gap 24, board 168 x 46 ⇒ boards at x = 174, 366, 558 … (pitch
//   192); band height 150, top band at y 0.
//   Bus tracks sit 12 / 17 / 22 / 7 / 27 above a band's box tops (first
//   claimant keeps the legacy 12).
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

ElectricalCircuit _feeder(String id, String to, double m) => ElectricalCircuit(
    id: id,
    name: 'F $to',
    loadKind: LoadKind.feeder,
    feedsPanelId: to,
    length: Length(m));

ElectricalCircuit _light(String id) => ElectricalCircuit(
    id: id,
    name: 'Light',
    loadKind: LoadKind.lighting,
    isLighting: true,
    loadW: 1200,
    length: const Length(20));

// R (L2, alone) feeds A, B, C (all on L1). B ALSO feeds X (G). The band packs
// the three L1 boards in feeder-tree order; whatever that order, on L1:
//   * the LEFTMOST board's CHILD leg would run channel -> its right edge at
//     mid-height straight through the other two ⇒ it jogs (childBusY);
//   * the MIDDLE board's child leg is blocked by the rightmost ⇒ jogs too;
//   * B->X's PARENT leg (B right edge -> channel) is blocked whenever B is not
//     rightmost ⇒ jogs.
// Before the fix every jog shared L1's single bus row (box top - 12), so a
// child row and B's parent row were collinear up to the channel — reading as
// a sibling wired to X through B's bus (a false topology).
ElectricalProject _project() => ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
          id: 'R',
          name: 'MDP',
          layoutPos: const LayoutPos(sheetId: 's2', floorIndex: 2, x: 0, y: 0),
          circuits: [
            _feeder('fa', 'A', 12),
            _feeder('fb', 'B', 14),
            _feeder('fc', 'C', 16),
          ]),
      ElectricalPanel(
          id: 'A',
          name: 'LP-A',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'fa',
          layoutPos: const LayoutPos(sheetId: 's1', floorIndex: 1, x: 0, y: 0),
          circuits: [_light('la')]),
      ElectricalPanel(
          id: 'B',
          name: 'LP-B',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'fb',
          layoutPos: const LayoutPos(sheetId: 's1', floorIndex: 1, x: 5, y: 0),
          circuits: [_light('lb'), _feeder('fx', 'X', 10)]),
      ElectricalPanel(
          id: 'C',
          name: 'LP-C',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'fc',
          layoutPos: const LayoutPos(sheetId: 's1', floorIndex: 1, x: 9, y: 0),
          circuits: [_light('lc')]),
      ElectricalPanel(
          id: 'X',
          name: 'LP-X',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'fx',
          layoutPos: const LayoutPos(sheetId: 's0', floorIndex: 0, x: 0, y: 0),
          circuits: [_light('lx')]),
    ]);

const _building = BuildingLevels(
    [Floor('G', Length(4)), Floor('L1', Length(4)), Floor('L2', Length(4))]);

bool _crossesInterior(SldLine l, SldRect r) {
  const e = 0.5;
  final x0 = r.x + e, x1 = r.x + r.w - e, y0 = r.y + e, y1 = r.y + r.h - e;
  if (l.y1 == l.y2) {
    final lo = math.min(l.x1, l.x2), hi = math.max(l.x1, l.x2);
    return l.y1 > y0 && l.y1 < y1 && lo < x1 && hi > x0;
  }
  if (l.x1 == l.x2) {
    final lo = math.min(l.y1, l.y2), hi = math.max(l.y1, l.y2);
    return l.x1 > x0 && l.x1 < x1 && lo < y1 && hi > y0;
  }
  return false;
}

void main() {
  final p = _project();
  final r = computeSystem(const PuilProfile(), p);
  final sheet = buildElectricalRiser(project: p, result: r, building: _building);
  final rects =
      sheet.prims.whereType<SldRect>().where((x) => x.w > 100).toList();
  final medium = sheet.prims
      .whereType<SldLine>()
      .where((l) => l.weight == SldWeight.medium)
      .toList();

  group('drawing-output-1 residual: every jogged leg owns its bus track', () {
    test('the fixture exercises the CHILD-leg jog (childBusY branch)', () {
      // The band packs A/B/C left to right in feeder-tree order; whichever is
      // LEFTMOST on L1 (x 174, y 150) has two boards between it and the
      // channel, so its child leg must jog. Right edge 342 ⇒ jog x 342 + 12 =
      // 354: a vertical rising from its centre-line (150 + 23 = 173) to a bus
      // track ABOVE the box top.
      final l1 = rects.where((rc) => rc.y == 150.0).toList()
        ..sort((a, b) => a.x.compareTo(b.x));
      expect(l1.length, 3);
      expect(l1.first.x, 174.0);
      final jog = medium.where((l) =>
          l.x1 == 354.0 &&
          l.x2 == 354.0 &&
          math.max(l.y1, l.y2) == 173.0 &&
          math.min(l.y1, l.y2) < 150.0);
      expect(jog, isNotEmpty);
    });

    test('no two different horizontals overlap (identical shared legs only)',
        () {
      // Normalise every medium horizontal to (y, lo, hi). Two DIFFERENT
      // segments on one y must not share any x-extent; an IDENTICAL duplicate
      // is the same wire drawn per feeder (e.g. the R right edge -> channel
      // leg every R feeder starts with, or B's centre-line stub that is both
      // its incoming and outgoing tie) — a truthful common connection.
      final hs = <(double, double, double)>{
        for (final l in medium)
          if (l.y1 == l.y2)
            (l.y1, math.min(l.x1, l.x2), math.max(l.x1, l.x2))
      }.toList();
      final hits = <String>[];
      for (var i = 0; i < hs.length; i++) {
        for (var j = i + 1; j < hs.length; j++) {
          final a = hs[i], b = hs[j];
          if (a.$1 != b.$1) continue;
          final overlap = math.min(a.$3, b.$3) - math.max(a.$2, b.$2);
          if (overlap > 0) hits.add('$a vs $b');
        }
      }
      expect(hits, isEmpty);
    });

    test('three jogs on L1 take three distinct tracks 12/17/22 above the boxes',
        () {
      // L1 box tops at y 150 ⇒ tracks 138, 133, 128 (12 / 17 / 22 above).
      final busRows = {
        for (final l in medium)
          if (l.y1 == l.y2 && l.y1 < 150 && l.y1 > 150 - 31) l.y1
      };
      expect(busRows, {138.0, 133.0, 128.0});
    });

    test('no feeder line passes through any panel box interior', () {
      expect(rects.length, 5);
      final hits = <String>[
        for (final l in medium)
          for (final rc in rects)
            if (_crossesInterior(l, rc))
              '(${l.x1},${l.y1})-(${l.x2},${l.y2}) through [${rc.x},${rc.y}]'
      ];
      expect(hits, isEmpty);
    });
  });

  group('drawing-output residual: the channel never strikes a feeder tag', () {
    test('no feeder tag glyph box is crossed by a feeder vertical', () {
      // A tag is `<cable> mm2 · <breaker>`; its glyph box is
      // [x, x + chars x size x 0.6] x [y - size, y].
      final tags = sheet.prims
          .whereType<SldLabel>()
          .where((t) => t.text.contains(' mm2 ') && t.text.contains('·'))
          .toList();
      expect(tags.length, 4, reason: 'one per fed board (A, B, C, X)');
      final hits = <String>[];
      for (final t in tags) {
        final w = t.text.length * t.size * kElectricalRiserLabelCharW;
        for (final l in medium) {
          if (l.x1 != l.x2) continue;
          final lo = math.min(l.y1, l.y2), hi = math.max(l.y1, l.y2);
          if (l.x1 > t.x && l.x1 < t.x + w && lo < t.y && hi > t.y - t.size) {
            hits.add('"${t.text}" @(${t.x},${t.y}) struck by x=${l.x1}');
          }
        }
      }
      expect(hits, isEmpty);
    });
  });
}
