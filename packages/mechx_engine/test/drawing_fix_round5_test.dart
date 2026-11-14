// Drawing review — fix round 5 (2026-11-14): checklist item 8 on the riser
// (`docs/DRAWING-REVIEW-RECORD.md` "Fix round 5"). A riser key leader is
// capped ([kMechRiserKeyLeaderCapLabelHeights]), crosses no other key leader
// and passes through no other key circle; a key that cannot comply is
// counted, so the page escalation gives it room instead of a long leader.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:test/test.dart';

import 'reference/office.dart' as office;
import 'reference/reference_building.dart';
import 'reference/shophouse.dart' as shop;
import 'reference/tower.dart' as tower;

SldSheet _riser(ReferenceBuilding b, ({int lo, int hi})? range,
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
    // As the issued sheet prints them (`issuedRiserEquipmentDetailsProvider`
    // + `equipmentNodeTags`): every tag and duty, so the plant row is as
    // crowded as on M-201.
    nodeTags: equipmentNodeTags(net),
    equipmentDetailByNodeId: {
      for (final n in net.nodes)
        if (n.component == NodeComponent.pump)
          n.id: 'Q 47.3 L/s · H 210.7 m · 200.0 kW'
        else if (n.component == NodeComponent.groundTank ||
            n.component == NodeComponent.roofTank)
          n.id: '120 m3'
        else if (n.component == NodeComponent.hydrantBox)
          n.id: 'PRV 690 kPa',
    },
  );
}

/// Every KEY circle of a riser sheet (a circle followed by its number) with
/// the label size it prints at.
List<(SldCircle, double)> _keys(SldSheet s) => [
      for (var i = 0; i + 1 < s.prims.length; i++)
        if (s.prims[i] case final SldCircle c)
          if (s.prims[i + 1] case final SldLabel l)
            if (RegExp(r'^\d{1,3}$').hasMatch(l.text) &&
                (l.x - c.cx).abs() < c.r &&
                (l.y - c.cy).abs() < c.r)
              (c, l.size),
    ];

double _dist(double ax, double ay, double bx, double by) =>
    math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

double _segPoint(double px, double py, SldLine l) {
  final dx = l.x2 - l.x1, dy = l.y2 - l.y1;
  final ll = dx * dx + dy * dy;
  final t = ll == 0
      ? 0.0
      : (((px - l.x1) * dx + (py - l.y1) * dy) / ll).clamp(0.0, 1.0);
  return _dist(px, py, l.x1 + t * dx, l.y1 + t * dy);
}

bool _cross(SldLine a, SldLine b) {
  double o(double px, double py, double qx, double qy, double rx, double ry) =>
      (qx - px) * (ry - py) - (qy - py) * (rx - px);
  final d1 = o(b.x1, b.y1, b.x2, b.y2, a.x1, a.y1);
  final d2 = o(b.x1, b.y1, b.x2, b.y2, a.x2, a.y2);
  final d3 = o(a.x1, a.y1, a.x2, a.y2, b.x1, b.y1);
  final d4 = o(a.x1, a.y1, a.x2, a.y2, b.x2, b.y2);
  const e = 1e-9;
  return ((d1 > e && d2 < -e) || (d1 < -e && d2 > e)) &&
      ((d3 > e && d4 < -e) || (d3 < -e && d4 > e));
}

/// The item-8 faults of [s]: key leaders (thin lines ending radially ON a
/// key circle) over the cap, crossing one another, or through another key.
List<String> _faults(SldSheet s) {
  final keys = _keys(s);
  final leads = <(SldLine, SldCircle, double)>[];
  for (final p in s.prims) {
    if (p is! SldLine || p.weight != SldWeight.thin) continue;
    for (final (c, size) in keys) {
      final d1 = _dist(p.x1, p.y1, c.cx, c.cy);
      final d2 = _dist(p.x2, p.y2, c.cx, c.cy);
      final onEdge = (d2 - c.r).abs() < 0.05 && d1 > c.r + 0.5 ||
          (d1 - c.r).abs() < 0.05 && d2 > c.r + 0.5;
      final len = _dist(p.x1, p.y1, p.x2, p.y2);
      // Radial: its line runs through the circle's centre.
      final perp = len == 0
          ? double.infinity
          : ((p.x2 - p.x1) * (p.y1 - c.cy) - (p.y2 - p.y1) * (p.x1 - c.cx))
                  .abs() /
              len;
      if (onEdge && perp < 0.05) {
        leads.add((p, c, size));
        break;
      }
    }
  }
  final out = <String>[];
  for (final (l, c, size) in leads) {
    final len = _dist(l.x1, l.y1, l.x2, l.y2);
    if (len > kMechRiserKeyLeaderCapLabelHeights * size + 1e-6) {
      out.add('leader ${(len / size).toStringAsFixed(1)} label heights');
    }
    for (final (o, _) in keys) {
      if (identical(o, c)) continue;
      if (_segPoint(o.cx, o.cy, l) < o.r) out.add('leader through a key');
    }
  }
  for (var i = 0; i < leads.length; i++) {
    for (var j = i + 1; j < leads.length; j++) {
      if (_cross(leads[i].$1, leads[j].$1)) out.add('key leaders cross');
    }
  }
  return out;
}

void main() {
  group('riser key leaders are capped and uncrossed (item 8)', () {
    test('tower Lantai 1: floor, plant row and the plant split pages', () {
      final tw = tower.buildTower();
      const r = (lo: 0, hi: 0);
      for (final s in [
        _riser(tw, r),
        _riser(tw, r, plant: MechRiserPlant.row),
        _riser(tw, (lo: 0, hi: 1)),
      ]) {
        expect(_faults(s), isEmpty);
      }
    });

    test('office and shophouse: every lone floor and the whole riser', () {
      for (final b in [office.buildOffice(), shop.buildShophouse()]) {
        final n = b.building.levelCount;
        for (final r in [
          null,
          for (var f = 0; f < n; f++) (lo: f, hi: f),
        ]) {
          expect(_faults(_riser(b, r)), isEmpty, reason: 'range $r');
        }
      }
    });
  });

  group('a plan key that cannot clear is counted, never stretched', () {
    test('it keeps a first-pass slot within kPlanKeyTagLeaderMaxFactor', () {
      const ts = 9.0;
      final layout = PlanLabelLayout()
        // Everything within 14 text heights is occupied: no slot clears.
        ..addBox(const (minX: -126.0, minY: -126.0, maxX: 126.0, maxY: 126.0));
      final k = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 1,
          by: 0,
          text: 'CW-L1 · DN25',
          textSize: ts,
          layout: layout,
          anchorPoint: (x: 0, y: 0),
          keys: PlanKeyRegistry(),
          keyOnly: true);
      final c = k.keyCircle!;
      expect(_dist(c.x, c.y, 0, 0) - c.r,
          lessThanOrEqualTo(kPlanKeyTagLeaderMaxFactor * ts + 1e-9));
      expect(layout.unresolvedCount, 1);
    });
  });
}
