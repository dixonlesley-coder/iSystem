// Round 15 (2026-10-18) — drafting-visual findings on the issued mechanical
// riser (M-201):
//   drafting-visual-2-1  no pipe tag is struck through by a riser pipe or by
//                        another tag's leader (leaders are reserved ink; ink
//                        outweighs label overlap; the escape widens sideways);
//   drafting-visual-2-2  a downfeed setting alone never stamps GRAVITASI on a
//                        meter-fed run with no roof tank;
//   drafting-visual-2-6  the water-meter detail's U is a UNION mark, not a
//                        fourth gate-valve bow-tie.
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/network_sizing.dart' show EdgeSizing;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import '../tool/generate_export_samples.dart'
    show buildNetwork, sizeNetwork, calibrations, building;

typedef _Box = ({double minX, double minY, double maxX, double maxY});

_Box _labelBox(SldLabel l) => (
      minX: l.x,
      minY: l.y - l.size,
      maxX: l.x + mechRiserLabelWidth(l.text, l.size),
      maxY: l.y,
    );

/// Liang–Barsky: does segment (x1,y1)-(x2,y2) pass through the OPEN interior
/// of [b] shrunk by [inset] (a line merely grazing an edge does not strike the
/// text through)?
bool _segmentCrosses(SldLine s, _Box b, {double inset = 0.5}) {
  final minX = b.minX + inset, maxX = b.maxX - inset;
  final minY = b.minY + inset, maxY = b.maxY - inset;
  if (minX >= maxX || minY >= maxY) return false;
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

SldSheet _harnessRiser() {
  final net = buildNetwork();
  final sizing = sizeNetwork(net);
  return buildMechanicalRiserSld(
    network: net,
    sizing: sizing,
    building: building,
    edgeLengths: {
      for (final e in net.edges)
        e.id: edgeLength(e, net,
            calibrationBySheet: calibrations, building: building),
    },
    detailCallouts: true,
    hotWaterRecirc: net.edges.any((e) => e.service == ServiceType.hotWater),
  );
}

void main() {
  group('drafting-visual-2-1 — no tag struck through by ink', () {
    test('the harness M-201: no label box is crossed by any line', () {
      final s = _harnessRiser();
      final lines = s.prims.whereType<SldLine>().toList();
      final labels = s.prims.whereType<SldLabel>().toList();
      // Bordered blocks (detail / notes / legend frames) draw their own text
      // inside; only the pipe / leader / glyph strokes are judged.
      final crossings = <String>[];
      for (final l in labels) {
        final b = _labelBox(l);
        for (final ln in lines) {
          if (_segmentCrosses(ln, b)) {
            crossings.add('"${l.text}" @(${l.x.toStringAsFixed(0)},'
                '${l.y.toStringAsFixed(0)}) x line (${ln.x1.toStringAsFixed(0)},'
                '${ln.y1.toStringAsFixed(0)})-(${ln.x2.toStringAsFixed(0)},'
                '${ln.y2.toStringAsFixed(0)}) w=${ln.weight.name}');
          }
        }
      }
      expect(crossings, isEmpty, reason: crossings.join('\n'));
    });
  });

  group('drafting-visual-2-2 — GRAVITASI only below a real roof tank', () {
    NetNode n(String id, double x, int floor, {NodeComponent? c}) => NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: c == null ? NodeRole.main : NodeRole.plant,
        component: c);
    test('a meter-fed downfeed riser carries no function suffix', () {
      final net = Network(nodes: [
        n('wm', 0, 0, c: NodeComponent.waterMeter),
        n('a', 0, 1),
      ], edges: const [
        NetEdge(
            id: 'r',
            fromId: 'wm',
            toId: 'a',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser),
      ]);
      expect(riserFunctionFor(net, net.edges.single, downfeed: true), isNull);
    });
    test('the same riser hanging from a roof tank IS gravitasi', () {
      final net = Network(nodes: [
        n('rt', 0, 2, c: NodeComponent.roofTank),
        n('t', 0, 1),
        n('a', 0, 0),
      ], edges: const [
        NetEdge(
            id: 'rt-t',
            fromId: 'rt',
            toId: 't',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser),
        NetEdge(
            id: 'r',
            fromId: 't',
            toId: 'a',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser),
      ]);
      expect(riserFunctionFor(net, net.edgeById('r')!, downfeed: true),
          RiserFunction.gravitasi);
    });
  });

  group('drafting-visual-2-6 — the water-meter detail draws a union', () {
    test('the U slot is two short parallel bars, keyed "U - Union"', () {
      const net = Network(nodes: const [
        NetNode(
            id: 'wm',
            sheetId: 's1',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.main,
            component: NodeComponent.waterMeter),
        NetNode(
            id: 'f',
            sheetId: 's1',
            x: 100,
            y: 0,
            floorIndex: 0,
            role: NodeRole.fixture),
      ], edges: [
        NetEdge(
            id: 'e', fromId: 'wm', toId: 'f', service: ServiceType.coldWater),
      ]);
      final s = buildMechanicalRiserSld(
        network: net,
        sizing: const <String, EdgeSizing>{},
        building: const BuildingLevels([Floor('G', Length(3.5))]),
        detailCallouts: true,
      );
      final u = s.prims
          .whereType<SldLabel>()
          .firstWhere((l) => l.text == 'U');
      // The union bars sit just above the U caption, centred on its glyph.
      final cx = u.x + mechRiserLabelWidth('U', u.size) / 2;
      final bars = s.prims.whereType<SldLine>().where((l) =>
          l.x1 == l.x2 &&
          (l.x1 - cx).abs() <= 3 &&
          l.y2 < u.y &&
          u.y - l.y2 < 20);
      expect(bars.length, 2);
      expect(s.legend.map((e) => '${e.code} - ${e.meaning}'),
          contains('U - Union'));
    });
  });
}
