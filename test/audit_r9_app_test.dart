// Round 9 (2026-10-18) — store-level findings from the mech/elec fuzz lenses
// and the report-parity FU column, each pinned on the real providers.
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/canvas/edge_context_menu.dart' show cornerJoinPartner;
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

const _size = Size(1000, 800);
List<Sheet> _pages(int n) => [
      for (var i = 1; i <= n; i++) Sheet(id: 'p$i', name: 'Page $i', sizePx: _size),
    ];

NetNode _n(String id, double x, double y,
        {String sheet = 'p1',
        int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component}) =>
    NetNode(
        id: id,
        sheetId: sheet,
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: component);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

void main() {
  // ── mech-store-fuzz-1 ────────────────────────────────────────────────────
  group('mech-store-fuzz-1 — growing the stack keeps clamped sheets on their work',
      () {
    test('Add on top x2: p5 (clamped to floor 2) stays on floor 2', () {
      final c = _c();
      c.read(sheetsControllerProvider.notifier).loadSheets(_pages(5));
      // Default 3 floors ⇒ p4/p5 clamp to floor 2; draw a run on p5 there.
      final sheets0 = c.read(sheetsControllerProvider);
      expect(sheets0.floorFor('p5', 3), 2);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(
          nodes: [_n('a', 0, 0, sheet: 'p5', floor: 2), _n('b', 100, 0, sheet: 'p5', floor: 2)],
          edges: [_e('r', 'a', 'b', ServiceType.coldWater)]));
      c.read(projectControllerProvider.notifier).addFloorsOnTop(2, 3.5);
      final levels = c.read(projectControllerProvider).floors.length;
      expect(levels, 5);
      final sheets = c.read(sheetsControllerProvider);
      // Every sheet's floor is unchanged (p3..p5 pinned at 2), so the canvas
      // filter (sheetId AND floorIndex) still shows p5's two nodes.
      for (final id in ['p1', 'p2', 'p3', 'p4', 'p5']) {
        expect(sheets.floorFor(id, levels), sheets0.floorFor(id, 3), reason: id);
      }
      final f = sheets.floorFor('p5', levels);
      final visible = c
          .read(networkControllerProvider)
          .network
          .nodes
          .where((n) => n.sheetId == 'p5' && n.floorIndex == f);
      expect(visible, hasLength(2));
    });

    test('a 6-floor template keeps p4 on its drawn floor', () {
      final c = _c();
      c.read(sheetsControllerProvider.notifier).loadSheets(_pages(5));
      c.read(networkControllerProvider.notifier).loadNetwork(
          Network(nodes: [_n('a', 0, 0, sheet: 'p4', floor: 2)]));
      c.read(projectControllerProvider.notifier).setFloors([
        for (var i = 0; i < 6; i++) Floor('L$i', const Length(3.5)),
      ]);
      expect(c.read(sheetsControllerProvider).floorFor('p4', 6), 2);
    });

    test('property: any growth keeps every sheet↔node pairing (seeded)', () {
      for (var seed = 0; seed < 12; seed++) {
        final c = _c();
        final pages = 2 + seed % 5;
        c.read(sheetsControllerProvider.notifier).loadSheets(_pages(pages));
        final s0 = c.read(sheetsControllerProvider);
        c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          for (var i = 1; i <= pages; i++)
            _n('n$i', 10.0 * i, 0, sheet: 'p$i', floor: s0.floorFor('p$i', 3)),
        ]));
        final grow = 1 + seed % 4;
        if (seed.isEven) {
          c.read(projectControllerProvider.notifier).addFloorsOnTop(grow, 3.0);
        } else {
          c.read(projectControllerProvider.notifier).setFloors([
            for (var i = 0; i < 3 + grow; i++) Floor('L$i', const Length(3.0)),
          ]);
        }
        final levels = c.read(projectControllerProvider).floors.length;
        final s = c.read(sheetsControllerProvider);
        for (final n in c.read(networkControllerProvider).network.nodes) {
          expect(s.floorFor(n.sheetId, levels), n.floorIndex,
              reason: 'seed $seed ${n.id}');
        }
      }
    });
  });

  // ── mech-store-fuzz-4 ────────────────────────────────────────────────────
  test('mech-store-fuzz-4 — a 2-floor template removes the floor-2 riser, never '
      'collapses it to zero length', () {
    final c = _c();
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('lo', 50, 50, floor: 1),
      _n('hi', 50, 50, floor: 2),
      _n('x', 150, 50, floor: 1),
    ], edges: [
      _e('riser', 'lo', 'hi', ServiceType.coldWater, kind: EdgeKind.riser),
      _e('run', 'lo', 'x', ServiceType.coldWater),
    ]));
    expect(c.read(networkControllerProvider.notifier).elementsAboveFloor(2), 2);
    c.read(projectControllerProvider.notifier).setFloors(const [
      Floor('G', Length(4.0)),
      Floor('L1', Length(3.5)),
    ]);
    final net = c.read(networkControllerProvider).network;
    expect(net.edges.map((e) => e.id), ['run']);
    expect(net.edges.where((e) => e.kind == EdgeKind.riser), isEmpty);
  });

  // ── mech-store-fuzz-2 ────────────────────────────────────────────────────
  group('mech-store-fuzz-2 — edits never splice across services', () {
    Network base() => Network(nodes: [
          _n('P', 0, 0),
          _n('J', 100, 0),
          _n('M', 100, 80),
          _n('D0', 0, 150),
          _n('D1', 300, 150),
        ], edges: [
          _e('c1', 'P', 'J', ServiceType.coldWater),
          _e('c3', 'J', 'M', ServiceType.coldWater),
          _e('d1', 'D0', 'D1', ServiceType.drainage),
        ]);

    test('dragging a CW end onto a drain does not tee into the drain', () {
      final c = _c();
      final n = c.read(networkControllerProvider.notifier)..loadNetwork(base());
      n.moveNode('M', 150, 145);
      n.endNodeDragWithSnap('M', 12);
      final net = c.read(networkControllerProvider).network;
      expect(net.edges.where((e) => e.service == ServiceType.drainage),
          hasLength(1));
      expect(net.edges.map((e) => e.id).toSet(), {'c1', 'c3', 'd1'});
    });

    test('trim/extend refuses a boundary of another service', () {
      final c = _c();
      final n = c.read(networkControllerProvider.notifier)..loadNetwork(base());
      expect(n.trimExtendEdge('c3', 'M', 'd1'), isFalse);
      expect(c.read(networkControllerProvider).network.edges, hasLength(3));
    });

    test('same-service tee-in still works (CW end onto a CW run)', () {
      final c = _c();
      final n = c.read(networkControllerProvider.notifier)
        ..loadNetwork(Network(nodes: [
          _n('A', 0, 0),
          _n('B', 300, 0),
          _n('M', 150, 100),
          _n('K', 150, 200),
        ], edges: [
          _e('ab', 'A', 'B', ServiceType.coldWater),
          _e('km', 'K', 'M', ServiceType.coldWater),
        ]));
      n.moveNode('M', 150, 5);
      n.endNodeDragWithSnap('M', 12);
      expect(c.read(networkControllerProvider).network.edges.length,
          greaterThan(2));
    });
  });

  // ── mech-store-fuzz-5 ────────────────────────────────────────────────────
  test('mech-store-fuzz-5 — copy/paste of a riser keeps its vertical span', () {
    final c = _c();
    final n = c.read(networkControllerProvider.notifier)
      ..loadNetwork(Network(nodes: [
        _n('lo', 100, 100, floor: 0),
        _n('hi', 100, 100, floor: 1),
      ], edges: [
        _e('r', 'lo', 'hi', ServiceType.coldWater, kind: EdgeKind.riser),
      ]));
    n.copySelection({'lo', 'hi'}, {'r'});
    final gen = n.paste(sheetId: 'p1', floorIndex: 0);
    final net = c.read(networkControllerProvider).network;
    final e = net.edgeById(gen.edgeIds.single)!;
    expect(e.kind, EdgeKind.riser);
    final a = net.nodeById(e.fromId)!;
    final b = net.nodeById(e.toId)!;
    expect({a.floorIndex, b.floorIndex}, {0, 1});
    // Its §10 length is the floor-0 → floor-1 elevation delta, not 0.
    final p = c.read(projectControllerProvider);
    expect(
        edgeLength(e, net,
                calibrationBySheet: p.calibrations,
                building: p.building,
                mounting: p.mounting)
            .meters,
        greaterThan(0));
  });

  test('mech-store-fuzz-5 — a riser pasted past the top floor is dropped', () {
    final c = _c();
    final n = c.read(networkControllerProvider.notifier)
      ..loadNetwork(Network(nodes: [
        _n('lo', 100, 100, floor: 0),
        _n('hi', 100, 100, floor: 1),
      ], edges: [
        _e('r', 'lo', 'hi', ServiceType.coldWater, kind: EdgeKind.riser),
      ]));
    n.copySelection({'lo', 'hi'}, {'r'});
    final gen = n.paste(sheetId: 'p1', floorIndex: 2); // top of 3 floors
    expect(gen.edgeIds, isEmpty);
  });

  // ── mech-store-fuzz-6 ────────────────────────────────────────────────────
  test('mech-store-fuzz-6 — two stubs off one tee are never corner-joined', () {
    final c = _c();
    final n = c.read(networkControllerProvider.notifier)
      ..loadNetwork(Network(nodes: [
        _n('m', 0, 0),
        _n('j', 100, 0),
        _n('a', 100, -20),
        _n('b', 115, 0),
      ], edges: [
        _e('e0', 'm', 'j', ServiceType.coldWater),
        _e('e1', 'j', 'a', ServiceType.coldWater),
        _e('e2', 'j', 'b', ServiceType.coldWater),
      ]));
    final net0 = c.read(networkControllerProvider).network;
    expect(cornerJoinPartner(net0, 'a'), isNull);
    expect(n.joinCorner('a', 'b'), isFalse);
    expect(c.read(networkControllerProvider).network.edges, hasLength(3));
  });

  // ── mech-store-fuzz-7 ────────────────────────────────────────────────────
  test('mech-store-fuzz-7 — trim/extend with the anchor ON the boundary refuses',
      () {
    final c = _c();
    final n = c.read(networkControllerProvider.notifier)
      ..loadNetwork(Network(nodes: [
        _n('Q0', 0, 0),
        _n('Q1', 200, 0),
        _n('A', 100, 0),
        _n('M', 100, 100),
      ], edges: [
        _e('b', 'Q0', 'Q1', ServiceType.coldWater),
        _e('e', 'A', 'M', ServiceType.coldWater),
      ]));
    expect(n.trimExtendEdge('e', 'M', 'b'), isFalse);
    final net = c.read(networkControllerProvider).network;
    expect(net.nodeById('M')!.y, 100);
    expect(net.edges, hasLength(2));
  });

  // ── mech-store-fuzz-8 ────────────────────────────────────────────────────
  test('mech-store-fuzz-8 — no-op setters record no undo step', () {
    final c = _c();
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('f', 0, 0, role: NodeRole.fixture, component: NodeComponent.ahu),
    ]));
    final hist = c.read(historyProvider.notifier);
    final n = c.read(networkControllerProvider.notifier);
    n.setNodeFixture('f', PlumbingFixture.lavatory);
    expect(hist.canUndo, isTrue);
    hist.undo();
    n.setNodeFixture('f', PlumbingFixture.lavatory);
    final steps0 = c.read(historyProvider);
    n.setNodeFixture('f', PlumbingFixture.lavatory); // same ⇒ no-op
    n.setNodeElevation('f', null); // already null ⇒ no-op
    final p = c.read(projectControllerProvider);
    c.read(projectControllerProvider.notifier).setFloors(p.floors);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('p1', const ScaleCalibration(0.01));
    final steps1 = c.read(historyProvider);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('p1', const ScaleCalibration(0.01)); // same ⇒ no-op
    expect(c.read(historyProvider), steps1);
    expect(steps1, isNot(steps0)); // only the first calibration recorded
    // Setting an elevation keeps the node's component (was stripped).
    n.setNodeElevation('f', const Length(2.0));
    expect(c.read(networkControllerProvider).network.nodeById('f')!.component,
        NodeComponent.ahu);
  });

  // ── elec-store-fuzz-1/2 ──────────────────────────────────────────────────
  ElectricalCircuit derived(
          {double x = 100, bool fire = false, double kw = 5.5}) =>
      ElectricalCircuit(
        id: 'mep-p1',
        name: fire ? 'Fire pump' : 'Pump',
        loadKind: LoadKind.pump,
        loadW: kw * 1000 / 0.9,
        motorKw: kw,
        sourceEquipmentId: 'p1',
        lifeSafety: fire,
        cableType: fire ? 'FRC' : null,
        loadPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: x, y: 100),
      );

  ElectricalCircuit mepWay(ProviderContainer c) => c
      .read(electricalProjectProvider)
      .panels
      .firstWhere((p) => p.id == kMepEquipmentPanelId)
      .circuits
      .single;

  test('elec-store-fuzz-1 — a moved pump refreshes its way position', () {
    final c = _c();
    final e = c.read(electricalProjectProvider.notifier);
    e.syncMepEquipment([derived(x: 100)]);
    e.syncMepEquipment([derived(x: 3100)]);
    expect(mepWay(c).loadPos!.x, 3100);
  });

  test('elec-store-fuzz-2 — re-derived as a fire pump ⇒ lifeSafety + FRC', () {
    final c = _c();
    final e = c.read(electricalProjectProvider.notifier);
    e.syncMepEquipment([derived()]);
    expect(mepWay(c).lifeSafety, isFalse);
    e.syncMepEquipment([derived(fire: true)]);
    expect(mepWay(c).lifeSafety, isTrue);
    expect(mepWay(c).cableType, 'FRC');
    // A cable family the engineer typed is kept.
    e.setCircuit(kMepEquipmentPanelId, 'mep-p1', cableType: 'NYY');
    e.syncMepEquipment([derived(fire: true)]);
    expect(mepWay(c).cableType, 'NYY');
  });

  test('elec-store-fuzz-3 — duplicating the MEP board copies user-owned ways',
      () {
    final c = _c();
    final e = c.read(electricalProjectProvider.notifier);
    e.syncMepEquipment([derived()]);
    e.duplicatePanel(kMepEquipmentPanelId);
    final copy = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id != kMepEquipmentPanelId);
    expect(copy.circuits.single.sourceEquipmentId, isNull);
    expect(copy.circuits.single.flaOverrideA, isNull);
    // Deleting the pump never leaves the copy claiming it.
    e.syncMepEquipment(const []);
    expect(
        c
            .read(electricalProjectProvider)
            .panels
            .expand((p) => p.circuits)
            .where((w) => w.sourceEquipmentId == 'p1'),
        isEmpty);
  });

  test('elec-store-fuzz-4 — a duplicated MEP way is user-owned (1:1 invariant)',
      () {
    final c = _c();
    final e = c.read(electricalProjectProvider.notifier);
    e.syncMepEquipment([derived()]);
    e.duplicateCircuit(kMepEquipmentPanelId, 'mep-p1');
    final ways = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == kMepEquipmentPanelId)
        .circuits;
    expect(ways.where((w) => w.sourceEquipmentId == 'p1'), hasLength(1));
  });

  test('elec-store-fuzz-5 — moving a feeder way cannot create a cycle', () {
    final c = _c();
    final e = c.read(electricalProjectProvider.notifier);
    final a = e.addPanelAt(name: 'A', x: 0, y: 0);
    final b = e.addFedPanelAt(fromPanelId: a, x: 200, y: 0);
    final cc = e.addFedPanelAt(fromPanelId: b, x: 400, y: 0);
    final feederAB = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == a)
        .circuits
        .firstWhere((w) => w.feedsPanelId == b);
    e.moveCircuit(a, feederAB.id, cc);
    final result = c.read(electricalResultProvider);
    expect(result.warnings.where((w) => w.code == 'feeder-cycle'), isEmpty);
    expect(
        c
            .read(electricalProjectProvider)
            .panels
            .firstWhere((p) => p.id == a)
            .circuits
            .any((w) => w.id == feederAB.id),
        isTrue);
  });

  test('elec-store-fuzz-6 — no-op electrical edits record no undo step', () {
    final c = _c();
    final e = c.read(electricalProjectProvider.notifier);
    final p = e.addPanelAt(name: 'MDP', x: 0, y: 0);
    final w = e.addCircuit(p, kind: LoadKind.lighting);
    final steps = c.read(historyProvider);
    e.setCircuit(p, w, clearBreakerOverrideA: true);
    e.setSupplyCapacityVa(null);
    e.setGenerator(null);
    expect(c.read(historyProvider), steps);
  });

  // ── report-parity-run-schedule-fu-blank ──────────────────────────────────
  test('the sizer records the UBAP/DFU basis the run schedule prints', () {
    final c = _c();
    c.read(sheetsControllerProvider.notifier).loadDemoSheets();
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.02));
    c.read(networkControllerProvider.notifier).loadNetwork(const Network(
          nodes: [
            NetNode(
                id: 'wc',
                sheetId: 's1',
                x: 0,
                y: 0,
                floorIndex: 0,
                role: NodeRole.fixture,
                fixture: PlumbingFixture.waterClosetFlushTank),
            NetNode(id: 'out', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          ],
          edges: [
            NetEdge(
                id: 'd', fromId: 'wc', toId: 'out', service: ServiceType.drainage),
          ],
        ));
    // A flush-tank WC is 4 DFU (drainageFixtureUnit) — the DN75 basis.
    expect(c.read(edgeFixtureUnitsProvider)['d'], 4.0);
    expect(c.read(sizingProvider)['d']!.diameter.inMillimeters, 75);
  });
}
