// Round 23 (2026-10-18) — the app half of the round-23 audit:
//
//   regression-zones-phantom-roof-tank-datum
//                       the zone table hangs off a REAL gravity tank only
//   regression-mep-move-off-board-duplicates-load / mep-bridge-1
//                       an MEP-derived way cannot leave the MEP board
//   mep-bridge-2        a component swap re-derives phases / kind / name
//   mep-bridge-3        a standby supply / HW pump is the duty machine at df 0
//   mep-bridge-4        electrical undo re-syncs; the duty-feed flip is undoable
//   mep-bridge-5        a typed demand factor is never reverted by the sync

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c,
        fixture: fixture);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.coldWater, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

void _seed(ProviderContainer c, {int floors = 1, double h = 3.5}) {
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < floors; i++) Floor('L$i', Length(h))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
}

Future<void> _settle(ProviderContainer c) async {
  await Future<void>.delayed(Duration.zero);
  c.read(electricalProjectProvider);
}

List<ElectricalCircuit> _allWays(ProviderContainer c) => [
      for (final p in c.read(electricalProjectProvider).panels) ...p.circuits,
    ];

ElectricalPanel? _mepBoard(ProviderContainer c) => c
    .read(electricalProjectProvider)
    .panels
    .where((p) => p.id == kMepEquipmentPanelId)
    .firstOrNull;

void main() {
  // ── zones hang off a real tank only ───────────────────────────────────────
  group('regression-zones-phantom-roof-tank-datum', () {
    test('upfeed 8 x 3.5 m: no phantom roof tank, two PRV zones', () {
      final c = _c();
      _seed(c, floors: 8);
      c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
      expect(c.read(downfeedTankElevationProvider), isNull);
      // First principles: the pump holds the 225 kPa target at the TOP
      // fixture, so the ground fixture sees 225 kPa + rho·g·(7 × 3.5 m)
      // = 225 + 9.81 × 24.5 = 465.3 kPa > the 392 kPa SNI fixture limit —
      // one zone cannot hold the whole stack.
      final maxFix = const SniProfile().maxFixtureStaticPressure.value;
      const groundStatic = 225000 + 1000 * 9.81 * 24.5;
      expect(groundStatic, greaterThan(maxFix.pascals));
      final zones = c.read(zonesProvider);
      expect(zones.length, 2);
      // ... and it is exactly the legacy PRV-budget walk.
      final project = c.read(projectControllerProvider);
      final legacy = computeDownfeedZones(
        building: project.building,
        mounting: project.mounting,
        maxStaticPressure: Pressure(maxFix.pascals - 255000),
        maxFixtureStatic: maxFix,
      );
      expect([for (final z in zones) (z.topFloorIndex, z.bottomFloorIndex)],
          [for (final z in legacy) (z.topFloorIndex, z.bottomFloorIndex)]);
    });

    test('downfeed fed only by a ground pump never reads "tank head OK"', () {
      final c = _c();
      _seed(c, floors: 8);
      c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 8; f++) ...[
          _n('R$f', 100, 0, floor: f),
          _n('W$f', 300, 0,
              floor: f,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank),
        ],
      ], edges: [
        _e('p', 'P', 'R0'),
        for (var f = 0; f < 7; f++)
          _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
        for (var f = 0; f < 8; f++) _e('w$f', 'R$f', 'W$f'),
      ]));
      expect(c.read(downfeedTankElevationProvider), isNull);
      final statics = c.read(zoneStaticsProvider);
      // Never the clamped 0-kPa single zone a ground-pump "tank" produced.
      expect(statics.length, greaterThanOrEqualTo(2));
      expect(statics.every((s) => s.bottomStatic.pascals > 0), isTrue);
    });

    test('a drawn roof tank still feeds the top zone (Round 22 kept)', () {
      final c = _c();
      _seed(c, floors: 3);
      c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('RT', 0, 0,
            floor: 2, role: NodeRole.plant, c: NodeComponent.roofTank),
        for (var f = 0; f < 3; f++) ...[
          _n('R$f', 100, 0, floor: f),
          _n('W$f', 300, 0, floor: f, role: NodeRole.fixture),
        ],
      ], edges: [
        _e('t', 'RT', 'R2'),
        for (var f = 0; f < 2; f++)
          _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
        for (var f = 0; f < 3; f++) _e('w$f', 'R$f', 'W$f'),
      ]));
      final project = c.read(projectControllerProvider);
      expect(c.read(downfeedTankElevationProvider)!.meters,
          project.building.roofElevation.meters);
    });
  });

  // ── an MEP-derived way cannot leave its board ─────────────────────────────
  test('moving a derived way off the MEP board is refused; one way per machine',
      () async {
    final c = _c();
    _seed(c);
    c.read(electricalProjectProvider);
    final e = c.read(electricalProjectProvider.notifier);
    e.addPanelAt(name: 'MDP', x: 0, y: 0);
    final mdp = c.read(electricalProjectProvider).panels.single.id;
    c.read(networkControllerProvider.notifier).addComponentNode(
        's1', 0, const Offset(700, 200), NodeComponent.acDucted);
    await _settle(c);
    final way =
        _mepBoard(c)!.circuits.firstWhere((w) => w.sourceEquipmentId != null);
    final demand0 = c.read(electricalResultProvider).panels[mdp]!.demandW;
    e.moveCircuit(kMepEquipmentPanelId, way.id, mdp);
    // Any drawing edit + a resync.
    c.read(networkControllerProvider.notifier).addComponentNode(
        's1', 0, const Offset(100, 100), NodeComponent.gateValve);
    await _settle(c);
    e.resyncMepEquipment();
    final ways = _allWays(c).where((w) => w.id == way.id).toList();
    expect(ways.length, 1, reason: 'circuit ids stay unique');
    expect(ways.single.sourceEquipmentId, way.sourceEquipmentId);
    expect(c.read(electricalResultProvider).panels[mdp]!.demandW,
        closeTo(demand0, 1e-9));
  });

  test('a legacy moved way is never re-minted under the same id', () async {
    final c = _c();
    _seed(c);
    c.read(electricalProjectProvider);
    final e = c.read(electricalProjectProvider.notifier);
    e.addPanelAt(name: 'MDP', x: 0, y: 0);
    final mdp = c.read(electricalProjectProvider).panels.single.id;
    c.read(networkControllerProvider.notifier).addComponentNode(
        's1', 0, const Offset(700, 200), NodeComponent.acDucted);
    await _settle(c);
    final way =
        _mepBoard(c)!.circuits.firstWhere((w) => w.sourceEquipmentId != null);
    // A legacy file: the way sits on the MDP, user-owned, same id.
    final legacy = ElectricalCircuit.fromJson(
        {...way.toJson()}..remove('sourceEquipmentId'));
    final j = c.read(electricalProjectProvider).toJson();
    for (final panel in (j['panels'] as List).cast<Map<String, dynamic>>()) {
      final ways = (panel['circuits'] as List).cast<Map<String, dynamic>>();
      if (panel['id'] == mdp) {
        panel['circuits'] = [...ways, legacy.toJson()];
      } else if (panel['id'] == kMepEquipmentPanelId) {
        panel['circuits'] = [
          for (final w in ways)
            if (w['id'] != way.id) w,
        ];
      }
    }
    e.setProject(ElectricalProject.fromJson(j));
    e.resyncMepEquipment();
    expect(_allWays(c).where((w) => w.id == way.id).length, 1);
  });

  // ── a component swap re-derives the electrical character ─────────────────
  test('swapping an AHU for a split AC: phases, kind and name follow',
      () async {
    final c = _c();
    _seed(c);
    c.read(electricalProjectProvider);
    final net = c.read(networkControllerProvider.notifier);
    net.addComponentNode('s1', 0, const Offset(700, 200), NodeComponent.ahu);
    await _settle(c);
    final node = c
        .read(networkControllerProvider)
        .network
        .nodes
        .firstWhere((n) => n.component == NodeComponent.ahu);
    final before = _mepBoard(c)!.circuits.single;
    expect(before.name, NodeComponent.ahu.label);
    net.setNodeComponent(node.id, NodeComponent.acSplitWall);
    await _settle(c);
    final after = _mepBoard(c)!.circuits.single;
    // The fresh mint for the same node is the reference.
    final fresh = c
        .read(mepAutoFeedCircuitsProvider)
        .firstWhere((w) => w.sourceEquipmentId == before.sourceEquipmentId);
    expect(after.id, before.id);
    expect(after.phases, fresh.phases);
    expect(after.loadKind, fresh.loadKind);
    expect(after.loadKind, LoadKind.hvac);
    expect(after.cosPhi, fresh.cosPhi);
    expect(after.name, NodeComponent.acSplitWall.label);
    expect(after.flaOverrideA!.amperes, fresh.flaOverrideA!.amperes);
  });

  // ── a typed demand factor is the engineer's ──────────────────────────────
  test('a typed df 0 on a fire-pump way survives every sync', () async {
    final c = _c();
    _seed(c);
    c.read(electricalProjectProvider);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('FP', 100, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('H', 300, 0, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ], edges: [
      _e('a', 'GT', 'FP', s: ServiceType.fireHydrant),
      _e('b', 'FP', 'H', s: ServiceType.fireHydrant),
    ]));
    await _settle(c);
    final e = c.read(electricalProjectProvider.notifier);
    final way = _mepBoard(c)!.circuits.firstWhere((w) => w.lifeSafety);
    expect(way.demandFactor, 1);
    e.setCircuit(kMepEquipmentPanelId, way.id, demandFactor: 0);
    // An unrelated drawing edit re-syncs the board.
    c.read(networkControllerProvider.notifier).addComponentNode(
        's1', 0, const Offset(900, 900), NodeComponent.exhaustFan);
    await _settle(c);
    e.resyncMepEquipment();
    final now = _mepBoard(c)!.circuits.firstWhere((w) => w.id == way.id);
    expect(now.demandFactor, 0);
    expect(now.demandFactorUserSet, isTrue);
    // Provenance round-trips in .mechx.
    expect(
        ElectricalCircuit.fromJson(now.toJson()).demandFactorUserSet, isTrue);
  });

  // ── duty / standby supply pumps ──────────────────────────────────────────
  test('a standby supply pump is the duty machine at demand factor 0',
      () async {
    final c = _c();
    _seed(c, floors: 2);
    c.read(electricalProjectProvider);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('S', 100, 0),
      _n('P1', 200, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('P2', 200, 100, role: NodeRole.plant, c: NodeComponent.pump),
      _n('CV1', 300, 0, c: NodeComponent.checkValve),
      _n('CV2', 300, 100, c: NodeComponent.checkValve),
      _n('D', 400, 0),
      _n('R1', 400, 0, floor: 1),
      for (var i = 0; i < 6; i++)
        _n('W$i', 500 + 50.0 * i, 0,
            floor: 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.lavatory),
    ], edges: [
      _e('g', 'GT', 'S'),
      _e('s1', 'S', 'P1'),
      _e('s2', 'S', 'P2'),
      _e('p1', 'P1', 'CV1'),
      _e('p2', 'P2', 'CV2'),
      _e('c1', 'CV1', 'D'),
      _e('c2', 'CV2', 'D'),
      _e('r', 'D', 'R1', k: EdgeKind.riser),
      for (var i = 0; i < 6; i++) _e('w$i', 'R1', 'W$i'),
    ]));
    await _settle(c);
    final bind = c.read(mepDutyBindingProvider);
    expect(bind.supplyStandbyPumpNodeIds.length, 1);
    final standby = bind.supplyStandbyPumpNodeIds.keys.single;
    final duty = bind.supplyStandbyPumpNodeIds[standby]!;
    expect(bind.supplyPumpNodeId, duty);
    final duties = c.read(equipmentNodeDutiesProvider);
    // One machine, two identical sets.
    expect(duties[standby]!.motor.watts, duties[duty]!.motor.watts);
    final board = _mepBoard(c)!;
    final wDuty = board.circuits.firstWhere((w) => w.id == 'mep-node-$duty');
    final wStby =
        board.circuits.firstWhere((w) => w.id == 'mep-node-$standby');
    expect(wStby.motorKw, wDuty.motorKw);
    expect(wStby.flaOverrideA!.amperes, wDuty.flaOverrideA!.amperes);
    expect(wDuty.demandFactor, 1);
    expect(wStby.demandFactor, 0);
  });

  test('parallelStandbyPumps: series movers are never standby (legOnly)', () {
    // Two pumps in SERIES (A -> B -> X), no mirrored parallel leg.
    final net = Network(nodes: [
      _n('A', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('B', 100, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('X', 200, 0),
    ], edges: [
      _e('ab', 'A', 'B'),
      _e('bx', 'B', 'X'),
    ]);
    final out = parallelStandbyPumps(net, {'A', 'B'},
        onService: (e) => e.service == ServiceType.coldWater,
        bore: (_) => 25,
        legOnly: true);
    expect(out, isEmpty);
    // Without legOnly (a hot-water recirc set) the lower-ranked pump of a
    // connected pair (equal bores: the higher id) backs up the duty one.
    final hw = parallelStandbyPumps(net, {'A', 'B'},
        onService: (e) => e.service == ServiceType.coldWater,
        bore: (_) => 25);
    expect(hw, {'B': 'A'});
  });

  // ── electrical undo re-syncs; the feed flip is undoable ──────────────────
  group('mep-bridge-4', () {
    Network hydrant() => Network(nodes: [
          _n('A', 0, 0),
          _n('H', 300, 0, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ], edges: [
          _e('h', 'A', 'H', s: ServiceType.fireHydrant),
        ]);
    bool hasDutyWay(ProviderContainer c) =>
        _allWays(c).any((w) => w.sourceEquipmentId != null && w.lifeSafety);

    test('an electrical undo never resurrects a duty way the feed dropped',
        () async {
      final c = _c();
      _seed(c);
      c.read(electricalProjectProvider);
      c.read(networkControllerProvider.notifier).loadNetwork(hydrant());
      final e = c.read(electricalProjectProvider.notifier);
      e.addPanelAt(name: 'DB-1', x: 0, y: 0);
      c.read(mepDutyFeedEnabledProvider.notifier).set(true);
      await _settle(c);
      expect(hasDutyWay(c), isTrue);
      e.addPanelAt(name: 'DB-2', x: 400, y: 0);
      c.read(mepDutyFeedEnabledProvider.notifier).set(false);
      await _settle(c);
      expect(hasDutyWay(c), isFalse);
      e.undo(); // reverts only the DB-2 add
      await _settle(c);
      expect(c.read(mepDutyFeedEnabledProvider), isFalse);
      expect(hasDutyWay(c), isFalse);
    });

    test('Ctrl+Z reverts the duty-feed flip itself', () async {
      final c = _c();
      _seed(c);
      c.read(electricalProjectProvider);
      c.read(networkControllerProvider.notifier).loadNetwork(hydrant());
      c
          .read(electricalProjectProvider.notifier)
          .addPanelAt(name: 'DB-1', x: 0, y: 0);
      setMepDutyFeedUndoable(c.read, true);
      await _settle(c);
      expect(hasDutyWay(c), isTrue);
      c.read(historyProvider.notifier).undo();
      await _settle(c);
      expect(c.read(mepDutyFeedEnabledProvider), isFalse);
      expect(hasDutyWay(c), isFalse);
      c.read(historyProvider.notifier).redo();
      await _settle(c);
      expect(c.read(mepDutyFeedEnabledProvider), isTrue);
      expect(hasDutyWay(c), isTrue);
    });
  });
}
