/// Round 32 seed suite (2026-10-18):
///   * regression-ejector-force-main-walks-up-soil-stack-when-sewer-ends-
///     in-ground-tank — a ground-tank OUTFALL (STP / septic) is the sewer's
///     sink, not a duplex header leg: the force-main walk stops where the
///     gravity soil stack joins.
///   * binding-2 / regression-duplex-ejector-standby-leg — a duplex ejector
///     set is duty / standby: the standby leg mirrors the duty leg (DN75,
///     20 DFU), no gravity-loop closing edge; the force main is floored at
///     the DN50 solids bore; order-independent (renamed + shuffled).
///   * regression-air-open-boundary — the loose-end judge reads the sizer's
///     own intake decision (a bare leaf off a NON-root FCU is a loose end).
///   * electrical-props-3 — the service-capacity judge reads the DIVERSIFIED
///     current; board totals are permutation-invariant (seeded property).
///   * riser-drawings-4-1..5 — paginated HWR leg / pump / loop turn, the
///     domestic-only pump-set detail, per-service callouts, Helvetica label
///     widths, leader-pipe crossing charge.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/connectivity.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/ejector.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import '../tool/generate_export_samples.dart' as harness
    show buildNetwork, sizeNetwork, calibrations, building;

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: component?.role ?? role,
        component: component);

NetEdge _e(String id, String a, String b,
        {EdgeKind kind = EdgeKind.run,
        ServiceType service = ServiceType.drainage}) =>
    NetEdge(id: id, fromId: a, toId: b, service: service, kind: kind);

// B2 / B1 / L0 / L1 / L2 at 3.0 m, groundIndex 2: B2 slab -6.0, L0 0.0.
const _b5 = BuildingLevels([
  Floor('B2', Length(3)),
  Floor('B1', Length(3)),
  Floor('L0', Length(3)),
  Floor('L1', Length(3)),
  Floor('L2', Length(3)),
], groundIndex: 2);

({double lift, double head}) _duty(Network net, String pump,
    {BuildingLevels building = _b5,
    Map<String, double> dfu = const {'WC': 20, 'FX': 4}}) {
  final fu = <String, double>{};
  final sizing = autoSizeNetwork(net, const SizingContext(),
      leafDemand: const {}, nodeDrainageUnits: dfu, fixtureUnitsOut: fu);
  final p = ejectorDutyPoint(
      net: net,
      pumpId: pump,
      sizing: sizing,
      edgeFixtureUnits: fu,
      building: building,
      calibrationBySheet: const {'s1': ScaleCalibration(0.05)})!;
  return (lift: p.staticLift.meters, head: p.head.meters);
}

/// Proper crossings between a LEADER (thin, unlayered, longer than 28 units,
/// not a full-width floor hairline) and a pipe (medium weight).
int _longLeaderPipeCrossings(SldSheet s) => _leaderPipeCrossings(s, 28);

/// Every thin (leader / glyph-stroke) line properly crossing a pipe, of any
/// length above [minLength].
int _leaderPipeCrossings(SldSheet s, double minLength) {
  bool proper(SldLine a, SldLine b) {
    double o(
            double ax, double ay, double bx, double by, double cx, double cy) =>
        (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    final d1 = o(a.x1, a.y1, a.x2, a.y2, b.x1, b.y1);
    final d2 = o(a.x1, a.y1, a.x2, a.y2, b.x2, b.y2);
    final d3 = o(b.x1, b.y1, b.x2, b.y2, a.x1, a.y1);
    final d4 = o(b.x1, b.y1, b.x2, b.y2, a.x2, a.y2);
    return d1 * d2 < -1e-9 && d3 * d4 < -1e-9;
  }

  final lines = s.prims.whereType<SldLine>().toList();
  final leaders = lines.where((l) =>
      l.weight == SldWeight.thin &&
      l.layer == null &&
      !((l.y1 - l.y2).abs() < 1e-9 && (l.x2 - l.x1).abs() > 400) &&
      math.sqrt(math.pow(l.x2 - l.x1, 2) + math.pow(l.y2 - l.y1, 2)) >
          minLength);
  final pipes = lines.where((l) => l.weight == SldWeight.medium);
  var n = 0;
  for (final a in leaders) {
    for (final b in pipes) {
      if (proper(a, b)) n++;
    }
  }
  return n;
}

void main() {
  group('ejector force main stops at the soil stack (STP outfall)', () {
    // First principles: the pump sits on the B2 slab (-6.0 m). The force
    // main rises to J, a bare L0 drainage junction read under its slab =
    // the B1 ceiling = 0.0 - 0.3 = -0.3 m. J also receives the gravity soil
    // stack from L2, so the force main ENDS there: lift = -0.3 - (-6.0) =
    // 5.70 m whatever the sewer's outfall is (a bare leaf or a ground-tank
    // STP / septic tank).
    const expectedLift = 5.70;
    Network net({required bool stpOutfall}) => Network(nodes: [
          _n('WC', -50, 0, role: NodeRole.fixture),
          _n('PIT', 0, 0, component: NodeComponent.groundTank),
          _n('EJ', 20, 0, component: NodeComponent.pump),
          _n('J', 40, 0, floor: 2),
          _n('S4', 40, 0, floor: 4),
          _n('FX', 60, 0, floor: 4, role: NodeRole.fixture),
          _n('X', 100, 0, floor: 2),
          stpOutfall
              ? _n('OUT', 160, 0, floor: 2, component: NodeComponent.groundTank)
              : _n('OUT', 160, 0, floor: 2),
        ], edges: [
          _e('in', 'WC', 'PIT'),
          _e('pe', 'PIT', 'EJ'),
          _e('rs', 'EJ', 'J', kind: EdgeKind.riser),
          _e('st', 'S4', 'J', kind: EdgeKind.riser),
          _e('fx', 'FX', 'S4'),
          _e('jx', 'J', 'X'),
          _e('xo', 'X', 'OUT'),
        ]);

    test('bare-leaf outfall', () {
      final d = _duty(net(stpOutfall: false), 'EJ');
      expect(d.lift, closeTo(expectedLift, 1e-9));
    });

    test('ground-tank STP outfall: never climbs the soil stack', () {
      final bare = _duty(net(stpOutfall: false), 'EJ');
      final d = _duty(net(stpOutfall: true), 'EJ');
      expect(d.lift, closeTo(expectedLift, 1e-9));
      // The same force main (EJ -> J) either way, so the same friction.
      expect(d.head, closeTo(bare.head, 1e-9));
    });
  });

  group('duplex ejector set: duty / standby, never a gravity ring', () {
    // B2 / B1 / L0 at 3 m. PIT -> EJ -> CV1 -> H and PIT -> EJ2 -> CV2 -> H,
    // H -riser- R1 -> SW; a WC (20 DFU) drains into the pit.
    // First principles: either pump runs ALONE at full duty, so every leg
    // carries the pit's whole 20 DFU, and a drain carrying a WC floors at
    // DN75 (IPC/UPC, `kMinWcDrainMm`) — the duty leg's size. The standby leg
    // mirrors it (DN75, 20 DFU), flows pump -> header, and no edge of the set
    // is a gravity-loop closing edge.
    const b3 = BuildingLevels([
      Floor('B2', Length(3)),
      Floor('B1', Length(3)),
      Floor('L0', Length(3)),
    ], groundIndex: 2);
    Network duplex(
        {bool valves = true,
        Map<String, String> rename = const {},
        int shuffleSeed = -1}) {
      String r(String id) => rename[id] ?? id;
      final nodes = [
        _n(r('WC'), -50, 0, role: NodeRole.fixture),
        _n(r('PIT'), 0, 0, component: NodeComponent.groundTank),
        _n(r('EJ'), 20, 0, component: NodeComponent.pump),
        _n(r('EJ2'), 20, 20, component: NodeComponent.pump),
        if (valves) ...[
          _n(r('CV1'), 26, 0, component: NodeComponent.checkValve),
          _n(r('CV2'), 26, 20, component: NodeComponent.checkValve),
        ],
        _n(r('H'), 34, 10),
        _n(r('R1'), 40, 0, floor: 2),
        _n(r('SW'), 140, 0, floor: 2),
      ];
      final edges = [
        _e(r('in'), r('WC'), r('PIT')),
        _e(r('pe'), r('PIT'), r('EJ')),
        _e(r('pe2'), r('PIT'), r('EJ2')),
        if (valves) ...[
          _e(r('d1'), r('EJ'), r('CV1')),
          _e(r('d2'), r('EJ2'), r('CV2')),
          _e(r('h1'), r('CV1'), r('H')),
          _e(r('h2'), r('CV2'), r('H')),
        ] else ...[
          _e(r('h1'), r('EJ'), r('H')),
          _e(r('h2'), r('EJ2'), r('H')),
        ],
        _e(r('rs'), r('H'), r('R1'), kind: EdgeKind.riser),
        _e(r('sw'), r('R1'), r('SW')),
      ];
      if (shuffleSeed >= 0) {
        nodes.shuffle(math.Random(shuffleSeed));
        edges.shuffle(math.Random(shuffleSeed + 1));
      }
      return Network(nodes: nodes, edges: edges);
    }

    ({Map<String, EdgeSizing> sz, Map<String, double> fu, Set<String> legs})
        size(Network net) {
      final fu = <String, double>{};
      final legs = <String>{};
      final sz = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {},
          nodeDrainageUnits: {
            for (final n in net.nodes)
              if (n.role == NodeRole.fixture) n.id: 20,
          },
          fixtureUnitsOut: fu,
          parallelLegEdgeIdsOut: legs);
      return (sz: sz, fu: fu, legs: legs);
    }

    for (final valves in [true, false]) {
      test('standby leg mirrors the duty leg (valves: $valves)', () {
        final r = size(duplex(valves: valves));
        final legIds = valves ? ['pe2', 'd2', 'h2'] : ['pe2', 'h2'];
        final dutyIds = valves ? ['pe', 'd1', 'h1'] : ['pe', 'h1'];
        for (var i = 0; i < legIds.length; i++) {
          final s = r.sz[legIds[i]]!;
          final d = r.sz[dutyIds[i]]!;
          expect(s.diameter.inMillimeters, 75, reason: legIds[i]);
          expect(s.diameter.inMillimeters, d.diameter.inMillimeters);
          expect(r.fu[legIds[i]], 20, reason: legIds[i]);
          expect(s.loopUnbalanced, isFalse, reason: legIds[i]);
          expect(d.loopUnbalanced, isFalse, reason: dutyIds[i]);
        }
        // Oriented pump -> header (the pit edge from the pit).
        expect(r.sz['pe2']!.flowFromId, 'PIT');
        expect(r.sz['h2']!.flowFromId, valves ? 'CV2' : 'EJ2');
        expect(r.legs, containsAll(legIds));
        expect(r.sz['rs']!.diameter.inMillimeters, 75);
        expect(r.fu['rs'], 20);
        expect(r.sz.values.where((s) => s.loopUnbalanced), isEmpty);
      });
    }

    test('order-independent: renamed ids + shuffled nodes / edges', () {
      final base = size(duplex());
      // Rename so EJ2 sorts BEFORE EJ (the duty swaps legs): sizes identical.
      const rename = {'EJ': 'Z-EJ', 'EJ2': 'A-EJ2'};
      for (var seed = 0; seed < 20; seed++) {
        final r = size(duplex(rename: rename, shuffleSeed: seed));
        for (final id in base.sz.keys) {
          expect(r.sz[id]!.diameter.inMillimeters,
              base.sz[id]!.diameter.inMillimeters,
              reason: 'seed $seed $id');
          expect(r.fu[id], base.fu[id], reason: 'seed $seed $id');
          expect(r.sz[id]!.loopUnbalanced, isFalse);
        }
      }
      final sets = duplexEjectorSets(duplex(rename: rename));
      expect(sets, hasLength(1));
      expect(sets.single.duty.pumpId, 'A-EJ2');
      expect(sets.single.standby.single.pumpId, 'Z-EJ');
    });

    test('both pumps keep the full 5.70 m lift', () {
      for (final p in ['EJ', 'EJ2']) {
        final d = _duty(duplex(), p, building: b3, dfu: const {'WC': 20});
        expect(d.lift, closeTo(5.70, 1e-9), reason: p);
      }
    });

    test('a small pit force main is floored at the DN50 solids bore', () {
      // A single lavatory (1 DFU) into the pit: the DFU table gives DN32 for
      // the drain, but a sewage pump passes 2 in solids, so its force main
      // (EJ -> R1 -> SW) is never below DN50 (`kEjectorForceMainMinBoreMm`).
      final net = Network(nodes: [
        _n('LV', -50, 0, role: NodeRole.fixture),
        _n('PIT', 0, 0, component: NodeComponent.groundTank),
        _n('EJ', 20, 0, component: NodeComponent.pump),
        _n('R1', 40, 0, floor: 2),
        _n('SW', 140, 0, floor: 2),
      ], edges: [
        _e('in', 'LV', 'PIT'),
        _e('pe', 'PIT', 'EJ'),
        _e('rs', 'EJ', 'R1', kind: EdgeKind.riser),
        _e('sw', 'R1', 'SW'),
      ]);
      final sz = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: const {'LV': 1});
      expect(kEjectorForceMainMinBoreMm, 50);
      expect(sz['in']!.diameter.inMillimeters, lessThan(50));
      for (final id in ['rs', 'sw']) {
        expect(sz[id]!.diameter.inMillimeters, 50, reason: id);
      }
    });
  });

  group('air open boundary = the sizer\'s intake decision', () {
    NetNode a(String id, double x, {NodeComponent? c, FlowRate? airflow}) =>
        NetNode(
            id: id,
            sheetId: 's1',
            x: x,
            y: 0,
            floorIndex: 0,
            role: c?.role ?? NodeRole.main,
            component: c,
            airflow: airflow);
    NetEdge d(String id, String f, String t) =>
        NetEdge(id: id, fromId: f, toId: t, service: ServiceType.duct);

    test('PAU primary air: a bare leaf off a NON-root FCU is a loose end', () {
      // pau(AHU) -e1- j; j -e2- d1 (diffuser 0.2 m3/s); j -e3- fcu;
      // fcu -e4- end (bare: the FCU's diffuser not yet drawn).
      // The component roots at the PAU (a terminal FCU never roots while a
      // source exists, Round 15), so the sizer loads `end` as a default
      // terminal (its duct flows OUT of the FCU) — Review must say so.
      final net = Network(nodes: [
        a('pau', 0, c: NodeComponent.ahu),
        a('j', 10),
        a('d1', 20,
            c: NodeComponent.supplyDiffuser, airflow: const FlowRate(0.2)),
        a('fcu', 30, c: NodeComponent.fcu),
        a('end', 40),
      ], edges: [
        d('e1', 'pau', 'j'),
        d('e2', 'j', 'd1'),
        d('e3', 'j', 'fcu'),
        d('e4', 'fcu', 'end'),
      ]);
      final sz = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.duct: FlowRate(0.05)},
          nodeFlowDemand: const {'d1': FlowRate(0.2)});
      expect(sz['e4']!.flowFromId, 'fcu'); // loaded as a terminal
      expect(airOpenBoundaryLeaves(net), isNot(contains('end')));
      expect(isAirOpenBoundaryLeaf(net, 'end'), isFalse);
      expect({
        for (final x in networkElementDefects(net))
          if (x.isLooseEnd) x.nodeId,
      }, {
        'end'
      });
    });

    test('a stand-alone FCU (it roots) keeps its intake leaf exempt', () {
      // oa -e0- fcu -e1- d1: the FCU roots its own component, so `oa` is its
      // intake (load-free) and never a loose end.
      final net = Network(nodes: [
        a('oa', -10),
        a('fcu', 0, c: NodeComponent.fcu),
        a('d1', 10,
            c: NodeComponent.supplyDiffuser, airflow: const FlowRate(0.1)),
      ], edges: [
        d('e0', 'oa', 'fcu'),
        d('e1', 'fcu', 'd1'),
      ]);
      expect(isAirOpenBoundaryLeaf(net, 'oa'), isTrue);
      expect(networkElementDefects(net).where((x) => x.isLooseEnd), isEmpty);
    });

    test('the memo never serves a stale set after the lists change (r2)', () {
      // Plain mutable lists: the same Network instance first holds the
      // stand-alone FCU with its intake leaf, then loses the intake edge —
      // `oa` is then an orphan, not an intake.
      final nodes = <NetNode>[
        a('oa', -10),
        a('fcu', 0, c: NodeComponent.fcu),
        a('d1', 10,
            c: NodeComponent.supplyDiffuser, airflow: const FlowRate(0.1)),
      ];
      final edges = <NetEdge>[d('e1', 'fcu', 'd1'), d('e0', 'oa', 'fcu')];
      final net = Network(nodes: nodes, edges: edges);
      expect(airOpenBoundaryLeaves(net), contains('oa'));
      edges.removeLast();
      expect(airOpenBoundaryLeaves(net), isNot(contains('oa')));
    });
  });

  group('riser drawings', () {
    BuildingLevels levels(int n) => BuildingLevels(
        [for (var i = 0; i < n; i++) Floor('L$i', const Length(3.5))]);
    NetNode rn(String id, double x, int f,
            {NodeRole role = NodeRole.main, NodeComponent? c}) =>
        NetNode(
            id: id,
            sheetId: 's1',
            x: x,
            y: 0,
            floorIndex: f,
            role: c?.role ?? role,
            component: c);
    NetEdge re(String id, String a, String b, ServiceType s,
            {EdgeKind kind = EdgeKind.run}) =>
        NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);
    List<SldLabel> labels(SldSheet s) => s.prims.whereType<SldLabel>().toList();

    test(
        '4-1 paginated HW stack: one HWR PUMP, one loop turn, a leg on '
        'every page', () {
      // Heater on L1, HW risers U0..U5, a fixture per storey; pages
      // (0..0), (1..3), (4..5). The return leg must run edge-to-edge on
      // every page the stack spans, close ONCE at the stack's real top (U5,
      // page 4..5) and carry ONE circulator at its base (U0, page 0..0).
      final net = Network(nodes: [
        rn('HTR', -40, 1, c: NodeComponent.boosterSet),
        for (var f = 0; f < 6; f++) ...[
          rn('U$f', 0, f),
          rn('F$f', 60, f, role: NodeRole.fixture),
        ],
      ], edges: [
        re('h', 'HTR', 'U1', ServiceType.coldWater),
        for (var f = 0; f < 5; f++)
          re('u$f', 'U$f', 'U${f + 1}', ServiceType.hotWater,
              kind: EdgeKind.riser),
        for (var f = 0; f < 6; f++)
          re('b$f', 'U$f', 'F$f', ServiceType.hotWater),
      ]);
      final b = levels(6);
      final ranges = [(lo: 4, hi: 5), (lo: 1, hi: 3), (lo: 0, hi: 0)];
      var pumps = 0;
      var turns = 0;
      for (final r in ranges) {
        final s = buildMechanicalRiserSld(
            network: net,
            building: b,
            focus: ServiceType.hotWater,
            hotWaterRecirc: true,
            floorRange: r);
        pumps += labels(s).where((l) => l.text == 'HWR PUMP').length;
        final hw = s.prims.whereType<SldLine>().where(
            (l) => l.layer == 'HW' && l.dashed && l.weight == SldWeight.thin);
        final legs = hw.where((l) => (l.x1 - l.x2).abs() < 1e-9).toList();
        turns += hw.where((l) => (l.y1 - l.y2).abs() < 1e-9).length;
        expect(legs, hasLength(1), reason: '$r');
        // The leg spans the same height as the drawn supply riser(s).
        final supply = s.prims.whereType<SldLine>().where((l) =>
            l.layer == 'HW' &&
            l.weight == SldWeight.medium &&
            (l.x1 - l.x2).abs() < 1e-9 &&
            (l.y1 - l.y2).abs() > 1);
        final supTop = supply.map((l) => math.min(l.y1, l.y2)).reduce(math.min);
        final supBot = supply.map((l) => math.max(l.y1, l.y2)).reduce(math.max);
        final leg = legs.single;
        expect(math.min(leg.y1, leg.y2), closeTo(supTop, 1e-6), reason: '$r');
        expect(math.max(leg.y1, leg.y2), closeTo(supBot, 1e-6), reason: '$r');
        expect(labels(s).any((l) => l.text == 'HWR'), isTrue, reason: '$r');
      }
      expect(pumps, 1);
      expect(turns, 1);
    });

    test(
        '4-2 meter-fed CW + a hydrant fire pump: no domestic PUMP-SET '
        'DETAIL', () {
      final net = Network(nodes: [
        rn('WM', 0, 0, c: NodeComponent.waterMeter),
        rn('C0', 40, 0),
        rn('C1', 40, 1),
        rn('W1', 80, 1, role: NodeRole.fixture),
        rn('GT', 200, 0, c: NodeComponent.groundTank),
        rn('FP', 240, 0, c: NodeComponent.pump),
        rn('H0', 280, 0),
        rn('H1', 280, 1),
        rn('HB', 320, 1, c: NodeComponent.hydrantBox),
      ], edges: [
        re('m', 'WM', 'C0', ServiceType.coldWater),
        re('c', 'C0', 'C1', ServiceType.coldWater, kind: EdgeKind.riser),
        re('w', 'C1', 'W1', ServiceType.coldWater),
        re('g', 'GT', 'FP', ServiceType.fireHydrant),
        re('p', 'FP', 'H0', ServiceType.fireHydrant),
        re('hr', 'H0', 'H1', ServiceType.fireHydrant, kind: EdgeKind.riser),
        re('hb', 'H1', 'HB', ServiceType.fireHydrant),
      ]);
      for (final focus in [ServiceType.coldWater, null]) {
        final s = buildMechanicalRiserSld(
            network: net,
            building: levels(2),
            focus: focus,
            detailCallouts: true,
            equipmentDetailByNodeId: const {'FP': '55 kW', 'GT': '120 m3'});
        final t = labels(s).map((l) => l.text).toList();
        expect(t.where((x) => x.contains('PUMP-SET DETAIL')), isEmpty,
            reason: '$focus');
        expect(t.where((x) => x.contains('BOOSTER')), isEmpty,
            reason: '$focus');
        expect(t.where((x) => x.startsWith('GROUND TANK')), isEmpty,
            reason: '$focus');
      }
      expect(plantMoverCaptions(net, detailByNodeId: const {'FP': '55 kW'}),
          isEmpty);
    });

    test('4-2/4-3 r2 — the HW sheet captions only the movers it draws', () {
      // HB: a booster on the CW feed whose discharge is the HOT-water riser
      // (visible on the HW sheet). P1: a cold-water-only booster (not drawn
      // on the HW sheet). The HW sheet's pump-set detail captions HB alone,
      // and its box is sized for ONE caption row set, not two.
      final net = Network(nodes: [
        rn('G', 0, 0),
        rn('P1', 40, 0, c: NodeComponent.boosterSet),
        rn('C0', 80, 0),
        rn('C1', 80, 1),
        rn('W1', 120, 1, role: NodeRole.fixture),
        rn('Y', 160, 0),
        rn('HB', 200, 0, c: NodeComponent.boosterSet),
        rn('H0', 240, 0),
        rn('H1', 240, 1),
        rn('X1', 280, 1, role: NodeRole.fixture),
      ], edges: [
        re('g', 'G', 'P1', ServiceType.coldWater),
        re('p', 'P1', 'C0', ServiceType.coldWater),
        re('c', 'C0', 'C1', ServiceType.coldWater, kind: EdgeKind.riser),
        re('w', 'C1', 'W1', ServiceType.coldWater),
        re('f', 'Y', 'HB', ServiceType.coldWater),
        re('h', 'HB', 'H0', ServiceType.hotWater),
        re('hr', 'H0', 'H1', ServiceType.hotWater, kind: EdgeKind.riser),
        re('x', 'H1', 'X1', ServiceType.hotWater),
      ]);
      const detail = {'P1': '1.5 kW', 'HB': '0.75 kW'};
      final hw = buildMechanicalRiserSld(
          network: net,
          building: levels(2),
          focus: ServiceType.hotWater,
          detailCallouts: true,
          equipmentDetailByNodeId: detail);
      final t = labels(hw).map((l) => l.text).toList();
      expect(t.where((x) => x.contains('PUMP-SET DETAIL')), hasLength(1));
      expect(t.where((x) => x.startsWith('BOOSTER PUMP')).toList(),
          ['BOOSTER PUMP 0.75 kW']);
      // The combined sheet still captions both movers.
      final all = buildMechanicalRiserSld(
          network: net,
          building: levels(2),
          detailCallouts: true,
          equipmentDetailByNodeId: detail);
      expect(
          labels(all).where((l) => l.text.startsWith('BOOSTER PUMP')).length,
          2);
      expect(
          plantMoverCaptions(net,
              detailByNodeId: detail, include: (n) => n.id == 'HB'),
          ['BOOSTER PUMP 0.75 kW']);
    });

    test('4-3 the HW sheet carries no CW roof tank / GRAVITASI / PRV set', () {
      final net = Network(nodes: [
        rn('RT', 0, 2, c: NodeComponent.roofTank),
        rn('C2', 40, 2),
        rn('C1', 40, 1),
        rn('PV', 60, 1, c: NodeComponent.prv),
        rn('W1', 100, 1, role: NodeRole.fixture),
        rn('HT', 200, 0, c: NodeComponent.boosterSet),
        rn('H0', 240, 0),
        rn('H1', 240, 1),
        rn('X1', 280, 1, role: NodeRole.fixture),
      ], edges: [
        re('r', 'RT', 'C2', ServiceType.coldWater),
        re('c', 'C2', 'C1', ServiceType.coldWater, kind: EdgeKind.riser),
        re('pv', 'C1', 'PV', ServiceType.coldWater),
        re('w', 'PV', 'W1', ServiceType.coldWater),
        re('h', 'HT', 'H0', ServiceType.coldWater),
        re('hr', 'H0', 'H1', ServiceType.hotWater, kind: EdgeKind.riser),
        re('x', 'H1', 'X1', ServiceType.hotWater),
      ]);
      final s = buildMechanicalRiserSld(
          network: net,
          building: levels(3),
          focus: ServiceType.hotWater,
          downfeed: true,
          detailCallouts: true,
          equipmentDetailByNodeId: const {'RT': '10 m3'});
      final t = labels(s).map((l) => l.text).toList();
      for (final bad in ['PRV', 'GRAVITASI', 'DETAIL PRV SET']) {
        expect(
            t.where(
                (x) => x.split(RegExp(r'[\s\-]+')).contains(bad) || x == bad),
            isEmpty,
            reason: bad);
      }
      expect(t.where((x) => x.startsWith('ROOF TANK')), isEmpty);
      final keys = s.legend.map((e) => e.code).toSet();
      expect(keys.intersection({'GRAVITASI', 'PRV', 'STR'}), isEmpty);
      // The CW sheet keeps its own plant + PRV set.
      final cw = buildMechanicalRiserSld(
          network: net,
          building: levels(3),
          focus: ServiceType.coldWater,
          downfeed: true,
          detailCallouts: true,
          equipmentDetailByNodeId: const {'RT': '10 m3'});
      final ct = labels(cw).map((l) => l.text).toList();
      expect(ct, contains('DETAIL PRV SET'));
      expect(ct, contains('ROOF TANK 10 m3'));
    });

    test('4-4 label width is the printed Helvetica advance', () {
      // C 722 + W 944 + '-' 333 + R 722 + '1' 556 = 3277 /1000 em;
      // at 8 units: 26.216 (the flat 0.6 x 8 x 5 = 24.0 under-reserved).
      expect(mechRiserLabelWidth('CW-R1', 8), closeTo(26.216, 1e-9));
      // Two adjacent uppercase stacks never print fused tags.
      final net = Network(nodes: [
        for (var k = 0; k < 4; k++) ...[
          rn('A$k', 30.0 * k, 0),
          rn('B$k', 30.0 * k, 1),
        ],
      ], edges: [
        for (var k = 0; k < 4; k++)
          re('r$k', 'A$k', 'B$k', ServiceType.coldWater, kind: EdgeKind.riser),
      ]);
      final s = buildMechanicalRiserSld(network: net, building: levels(2));
      final ls =
          labels(s).where((l) => RegExp(r'^CW-R\d$').hasMatch(l.text)).toList();
      expect(ls.length, 4);
      for (var i = 0; i < ls.length; i++) {
        for (var j = i + 1; j < ls.length; j++) {
          final a = ls[i], c = ls[j];
          final overlapX = a.x < c.x + mechRiserLabelWidth(c.text, c.size) &&
              c.x < a.x + mechRiserLabelWidth(a.text, a.size);
          final overlapY = a.y - a.size < c.y && c.y - c.size < a.y;
          expect(overlapX && overlapY, isFalse,
              reason: '${a.text} vs ${c.text}');
        }
      }
    });

    test('4-5 leaders avoid crossing pipes they do not name', () {
      // A combined 8-storey, 6-service tower page set: no leader longer than
      // the 28-unit long-leader threshold properly crosses a pipe.
      final nodes = <NetNode>[];
      final edges = <NetEdge>[];
      const services = [
        ServiceType.coldWater,
        ServiceType.hotWater,
        ServiceType.drainage,
        ServiceType.vent,
        ServiceType.rainwater,
        ServiceType.exhaust,
      ];
      for (var si = 0; si < services.length; si++) {
        final sv = services[si];
        for (var f = 0; f < 8; f++) {
          nodes.add(rn('${sv.name}R$f', 100.0 * si, f));
          if (f > 0) {
            edges.add(re(
                '${sv.name}r$f', '${sv.name}R${f - 1}', '${sv.name}R$f', sv,
                kind: EdgeKind.riser));
          }
          if (sv != ServiceType.vent && sv != ServiceType.rainwater) {
            nodes.add(rn('${sv.name}F$f', 100.0 * si + 40, f,
                role: NodeRole.fixture));
            edges
                .add(re('${sv.name}b$f', '${sv.name}R$f', '${sv.name}F$f', sv));
          }
        }
      }
      final tower = Network(nodes: nodes, edges: edges);
      for (var lo = 0; lo < 8; lo += 2) {
        final s = buildMechanicalRiserSld(
            network: tower,
            building: levels(8),
            floorRange: (lo: lo, hi: lo + 1));
        expect(_longLeaderPipeCrossings(s), 0, reason: 'page $lo');
      }
      // (The tower is a no-regression guard: its leaders cleared before the
      // charge too. The harness sheet below is where the charge decides.)
      //
      // The export harness M-201 riser (a dense mixed-service sheet). Both
      // figures are DISCRIMINATING ratchets, measured by zeroing
      // `_kLeaderCrossingWeight` (no charge) and by restoring the r1
      // long-leader-only gate:
      //   long-leader (> 28) crossings   no charge 17 · r1 9 · now 9
      //   all thin-line crossings (incl.  no charge 51 · r1 44 · now 43
      //   fixed glyph strokes)
      // so the HARD long-leader charge moves 8 tags off the risers they
      // slashed and the SOFT short-leader charge re-orders one more tag
      // that cannot clear. The 9 left have no crossing-free slot in the
      // placer's ladder.
      final hn = harness.buildNetwork();
      final hs = buildMechanicalRiserSld(
        network: hn,
        sizing: harness.sizeNetwork(hn),
        building: harness.building,
        edgeLengths: {
          for (final e in hn.edges)
            e.id: edgeLength(e, hn,
                calibrationBySheet: harness.calibrations,
                building: harness.building),
        },
        detailCallouts: true,
        hotWaterRecirc: hn.edges.any((e) => e.service == ServiceType.hotWater),
      );
      expect(_longLeaderPipeCrossings(hs), lessThanOrEqualTo(9));
      expect(_leaderPipeCrossings(hs, 0), lessThanOrEqualTo(43));
    });
  });

  group('board totals are permutation-invariant (seeded property)', () {
    // Float addition is not associative: a board total landing within ~1e-11
    // of a rounding boundary (an exact-half product of demand factors) could
    // round either way depending on circuit order. The engine sums integer
    // micro-units, so shuffling the ways never moves the printed demand W,
    // connected W or capacitor floor current.
    const p = PuilProfile();
    const factors = [1.0, 0.9, 0.8, 0.7, 0.65, 0.5, 0.35, 0.3, 0.1];
    test('3000 seeds × a shuffle', () {
      for (var seed = 0; seed < 3000; seed++) {
        final rnd = math.Random(32000 + seed);
        final n = 3 + rnd.nextInt(10);
        final ways = <ElectricalCircuit>[
          for (var i = 0; i < n; i++)
            rnd.nextInt(5) == 0
                ? ElectricalCircuit(
                    id: 'k$i',
                    name: 'Cap $i',
                    loadKind: LoadKind.capacitor,
                    phases: 3,
                    loadW: 5000.0 + rnd.nextInt(400) * 125.5,
                    cosPhi: 1,
                    length: const Length(5),
                  )
                : ElectricalCircuit(
                    id: 'w$i',
                    name: 'Way $i',
                    loadKind: LoadKind.heating,
                    phases: 3,
                    loadW: 100.0 + rnd.nextInt(20000) * 0.5 + 0.1 * i,
                    demandFactor: factors[rnd.nextInt(factors.length)],
                    cosPhi: 1,
                    length: const Length(5),
                  ),
        ];
        ElectricalProject proj(List<ElectricalCircuit> cs) =>
            ElectricalProject(id: 'p', panels: [
              ElectricalPanel(
                id: 'P0',
                name: 'P0',
                system: ElectricalSystem.threePhase,
                voltage: const Voltage(400),
                diversityFactor: factors[seed % factors.length],
                circuits: cs,
              ),
            ]);
        final a = computeSystem(p, proj(ways)).panels['P0']!;
        final shuffled = [...ways]..shuffle(math.Random(seed));
        final b = computeSystem(p, proj(shuffled)).panels['P0']!;
        expect(b.demandW, a.demandW, reason: 'seed $seed');
        expect(b.connectedW, a.connectedW, reason: 'seed $seed');
        expect(b.capacitorCurrentA, a.capacitorCurrentA, reason: 'seed $seed');
      }
    });
  });

  group('service-capacity judge reads the DIVERSIFIED current', () {
    // One 3φ 400 V root board, diversity 0.6, six 3φ 8 kW heaters (cos φ 1).
    //   Undiversified: each way Ib = 8000 / (√3·400 V) = 11.547 A; Round 43
    //   — the line sums the EXACT way currents and rounds once: six ways =
    //   69.28 → 69.3 A per line (the incomer basis; was 6 × 11.5 = 69.0).
    //   Diversified:   28.8 kW → 69.3 × 0.6 = 41.58 → 41.6 A.
    //   PLN 33 kVA limiter: 33000 / (√3·400) = 47.6 A ≥ 41.6 ⇒ no trip.
    //   A 23 kVA service: 23000 / 692.8 = 33.2 A < 41.6 ⇒ trips.
    ElectricalProject project(double? capacityVa) => ElectricalProject(
          id: 'p',
          supplyCapacityVa:
              capacityVa == null ? null : ApparentPower(capacityVa),
          panels: [
            ElectricalPanel(
              id: 'mdp',
              name: 'MDP',
              system: ElectricalSystem.threePhase,
              voltage: const Voltage(400),
              diversityFactor: 0.6,
              circuits: [
                for (var i = 0; i < 6; i++)
                  ElectricalCircuit(
                    id: 'h$i',
                    name: 'Heater $i',
                    loadKind: LoadKind.heating,
                    phases: 3,
                    loadW: 8000,
                    cosPhi: 1,
                    length: const Length(10),
                  ),
              ],
            ),
          ],
        );
    const p = PuilProfile();
    List<ElectricalWarning> svc(ElectricalSystemResult s) => [
          for (final w in s.warnings)
            if (w.code == 'service-capacity-below-demand') w,
        ];

    test('declared at the engine\'s own recommended daya ⇒ no warning', () {
      final base = computeSystem(p, project(null));
      final mdp = base.panels['mdp']!;
      expect(mdp.demandW, closeTo(28800, 1e-6));
      expect(mdp.demandCurrent.amperes, closeTo(69.3, 1e-9));
      // 69.3 × 0.6 = 41.58 A (printed 41.6).
      expect(mdp.diversifiedDemandCurrent.amperes, closeTo(41.58, 1e-9));
      final rec =
          computeAdvancedStudy(p, project(null), base).recommendedDayaVa!;
      expect(rec, greaterThanOrEqualTo(28800));
      final sys = computeSystem(p, project(rec));
      expect(svc(sys), isEmpty);
      // The incomer still sizes conservatively on the undiversified 69.3 A.
      expect(sys.panels['mdp']!.incomer.breaker.ratingA.amperes,
          greaterThanOrEqualTo(69.3));
    });

    test('a 23 kVA service below the 28.8 kVA diversified demand trips', () {
      final w = svc(computeSystem(p, project(23000)));
      expect(w, hasLength(1));
      expect(w.single.message, contains('diversified demand 41.6 A'));
    });
  });
}
