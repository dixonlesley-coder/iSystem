// Reference building 2 (shophouse row) — regression tests for the fixes its
// review raised (see docs/REFERENCE-BUILDINGS.md §2):
//
// F1 — a downfeed cold-water component holding its OWN roof tank is a
//      downfeed system from that tank (gravity field, booster duty on the
//      gravity residual, delivered field, zone table), never an upfeed
//      "extra supply component" from its ground tank. The three identical
//      units solve identically, whatever the id order / naming.
// F4 — a cassette / split-wall AC unit inside a room needs no pipe / duct:
//      it is never an `unconnected-orphan` (a ducted AC / FCU still is).
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/network/network.dart';

import '../packages/mechx_engine/test/reference/shophouse.dart';

ProviderContainer _load(ReferenceBuilding shop, Network net,
    {bool room = false}) {
  final c = ProviderContainer();
  c.read(sheetsControllerProvider.notifier).loadSheets(
    [
      for (final s in shop.sheets)
        Sheet(id: s.id, name: s.name, sizePx: const Size(1684, 1190)),
    ],
    sheetFloors: {for (final s in shop.sheets) s.id: s.floorIndex},
  );
  final project = c.read(projectControllerProvider.notifier)
    ..setFloors(shop.building.floors);
  for (final MapEntry(:key, :value) in shop.calibrations.entries) {
    project.setCalibration(key, value);
  }
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(occupancyProvider.notifier).set(shop.occupancy);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  if (room) {
    final rooms = c.read(roomAreasProvider.notifier);
    for (final r in kShophouseRooms) {
      final id = rooms.add(
          sheetId: r.sheetId,
          floorIndex: r.floorIndex,
          ax: r.ax,
          ay: r.ay,
          bx: r.bx,
          by: r.by)!;
      rooms.setRoomType(id, r.roomType);
    }
  }
  return c;
}

/// The unit letter of a suffixed id, and the id without it.
String? _unit(String id) => RegExp(r'_([A-Z])$').firstMatch(id)?.group(1);
String _base(String id) => id.replaceAll(RegExp(r'_[A-Z](?=_|$)'), '');

/// Per-unit, per-base-id figures of the solve, for comparison across units.
Map<String, Map<String, String>> _perUnit(ProviderContainer c) {
  final down = c.read(downfeedProvider)!;
  final del = c.read(downfeedDeliveredProvider)!;
  final duties = c.read(supplyMoverDutiesProvider);
  final out = <String, Map<String, String>>{};
  void put(String id, String what, String v) {
    final u = _unit(id);
    if (u == null) return;
    (out[u] ??= {})['$what ${_base(id)}'] = v;
  }

  for (final e in down.residualPressure.entries) {
    put(e.key, 'gravity',
        '${e.value.inKiloPascals.toStringAsFixed(3)} / '
        '${down.noFlowStaticPressure[e.key]!.inKiloPascals.toStringAsFixed(3)}');
  }
  for (final e in del.residualPressure.entries) {
    put(e.key, 'delivered',
        '${e.value.inKiloPascals.toStringAsFixed(3)} / '
        '${del.noFlowStaticPressure[e.key]!.inKiloPascals.toStringAsFixed(3)}');
  }
  for (final e in duties.entries) {
    put(e.key, 'duty',
        'Q ${e.value.flow.inLitersPerSecond.toStringAsFixed(6)} '
        'H ${e.value.head.meters.toStringAsFixed(3)}');
  }
  return out;
}

/// [net] with its node and edge lists shuffled by [seed] and unit letters
/// renamed by [rename] (ids, edge ends and edge ids).
Network _permuted(Network net, int seed, Map<String, String> rename) {
  String r(String id) => id.replaceAllMapped(
      RegExp(r'_([A-Z])(?=_|$)'), (m) => '_${rename[m[1]] ?? m[1]}');
  final rng = math.Random(seed);
  final nodes = [
    for (final n in net.nodes)
      NetNode(
        id: r(n.id),
        sheetId: n.sheetId,
        x: n.x,
        y: n.y,
        floorIndex: n.floorIndex,
        role: n.role,
        component: n.component,
        fixture: n.fixture,
        roofAreaM2: n.roofAreaM2,
      ),
  ]..shuffle(rng);
  final edges = [
    for (final e in net.edges)
      NetEdge(
          id: r(e.id),
          fromId: r(e.fromId),
          toId: r(e.toId),
          service: e.service,
          kind: e.kind),
  ]..shuffle(rng);
  return Network(nodes: nodes, edges: edges);
}

void main() {
  group('F1 — each roof-tank unit is its own downfeed system', () {
    test('B and C solve exactly like A: gravity, booster duty, delivered, '
        'zones', () {
      final shop = buildShophouse();
      final c = _load(shop, shop.network);
      addTearDown(c.dispose);
      final per = _perUnit(c);
      expect(per['B'], per['A']);
      expect(per['C'], per['A']);
      // Every unit is in the GRAVITY field (it used to hold unit A only).
      final down = c.read(downfeedProvider)!;
      for (final u in kShopUnits) {
        for (final f in kShopUnitFixtureIds) {
          expect(down.deliveryNodeIds, contains(shopId(f, u)));
        }
        // Each roof tank is its own gravity source (it read -146 kPa as a
        // pipe node of an upfeed solve from the ground tank).
        expect(down.residualPressure[shopId('RT', u)]!.pascals, 0);
      }
      // The booster duty is sized on the gravity residual for every unit:
      // BS_x = (225 - 8.064) / 9.81 = 22.114 m (it was 36.998 m for B / C,
      // i.e. + the transfer pump's 14.884 m).
      final duties = c.read(supplyMoverDutiesProvider);
      for (final u in kShopUnits) {
        expect(duties[shopId('BS', u)]!.head.meters, closeTo(22.114, 5e-4));
      }
      // The project verdict is the least over all three units (they tie, so
      // the first id: WC2_A).
      expect(down.criticalNodeId, shopId('WC2', 'A'));
      expect(down.minResidual.inKiloPascals, closeTo(8.064, 5e-4));
      // No component is left to the upfeed extra-supply path.
      expect(c.read(extraSupplySourcesProvider), isEmpty);
      expect(c.read(extraDownfeedTanksProvider).map((t) => t.tank),
          [shopId('RT', 'B'), shopId('RT', 'C')]);
      // One zone group per tank, identical.
      final zones = c.read(zonesProvider);
      expect(zones.length, 3);
      expect({for (final z in zones) '${z.bottomFloorIndex}-${z.topFloorIndex}'},
          {'0-2'});
      final statics = c.read(zoneStaticsProvider);
      expect({for (final z in statics) z.bottomStatic.pascals.round()}.length,
          1);
    });

    test('order independence: shuffled lists and renamed units give the same '
        'per-unit figures', () {
      final shop = buildShophouse();
      final ref = _load(shop, shop.network);
      addTearDown(ref.dispose);
      final expected = _perUnit(ref)['A']!;
      for (final (seed, rename) in [
        (1, const <String, String>{}),
        (2, const {'A': 'C', 'C': 'A'}),
        (3, const {'A': 'Z', 'B': 'Y', 'C': 'X'}),
      ]) {
        final c = _load(shop, _permuted(shop.network, seed, rename));
        addTearDown(c.dispose);
        final per = _perUnit(c);
        expect(per.length, 3, reason: 'seed $seed');
        for (final u in per.keys) {
          expect(per[u], expected, reason: 'seed $seed unit $u');
        }
      }
    });

    test('a component WITHOUT a roof tank keeps the extra-supply path', () {
      final shop = buildShophouse();
      // Unit C without its roof tank: its fill line ends at U2 and its
      // booster takes suction from the riser (a ground-tank booster system).
      final net = shop.network;
      final rt = shopId('RT', 'C');
      final drop = {for (final e in net.edges) if (e.fromId == rt || e.toId == rt) e.id};
      final cut = Network(
        nodes: [for (final n in net.nodes) if (n.id != rt) n],
        edges: [
          for (final e in net.edges)
            if (!drop.contains(e.id)) e,
          NetEdge(
              id: 'e_cw_U2_C_BS_C',
              fromId: shopId('U2', 'C'),
              toId: shopId('BS', 'C'),
              service: ServiceType.coldWater),
        ],
      );
      final c = _load(shop, cut);
      addTearDown(c.dispose);
      expect(c.read(extraDownfeedTanksProvider).map((t) => t.tank),
          [shopId('RT', 'B')]);
      expect(c.read(extraSupplySourcesProvider).map((x) => x.source),
          [shopId('GT', 'C')]);
    });
  });

  group('F4 — a cassette / split-wall AC needs no pipe or duct', () {
    test('the cassette in unit A\'s room raises no unconnected-orphan', () {
      final shop = buildShophouse();
      final c = _load(shop, shop.network, room: true);
      addTearDown(c.dispose);
      final kinds = [for (final i in c.read(designIssuesProvider)) i.kind];
      expect(kinds.where((k) => k.startsWith('unconnected-orphan')), isEmpty);
    });

    test('a split-wall AC is exempt too; a ducted AC and an FCU still flag',
        () {
      final shop = buildShophouse();
      NetNode unit(String id, NodeComponent comp, double x) => NetNode(
          id: id,
          sheetId: kShopSheetL1,
          x: x,
          y: 500,
          floorIndex: 0,
          role: comp.role,
          component: comp);
      final net = Network(nodes: [
        ...shop.network.nodes,
        unit('SPLIT', NodeComponent.acSplitWall, 450),
        unit('DUCTED', NodeComponent.acDucted, 480),
        unit('FCU', NodeComponent.fcu, 510),
      ], edges: shop.network.edges);
      final c = _load(shop, net, room: true);
      addTearDown(c.dispose);
      final kinds = {for (final i in c.read(designIssuesProvider)) i.kind};
      expect(kinds, isNot(contains('unconnected-orphan:SPLIT')));
      expect(kinds, isNot(contains('unconnected-orphan:$kShopAcNodeId')));
      expect(kinds, contains('unconnected-orphan:DUCTED'));
      expect(kinds, contains('unconnected-orphan:FCU'));
    });

    // Backlog D-6 (shophouse backlog h) — the exemption holds only INSIDE a
    // drawn room: a split / cassette unit outside every room (here on
    // Lantai 2, where no room is drawn) is flagged like any other orphan,
    // and with the room not drawn unit A's cassettes are flagged too.
    test('outside any room a split / cassette unit is an orphan', () {
      final shop = buildShophouse();
      final net = Network(nodes: [
        ...shop.network.nodes,
        NetNode(
            id: 'SPLIT_L2',
            sheetId: kShopSheetL2,
            x: 450,
            y: 500,
            floorIndex: 1,
            role: NodeComponent.acSplitWall.role,
            component: NodeComponent.acSplitWall),
      ], edges: shop.network.edges);
      final c = _load(shop, net, room: true);
      addTearDown(c.dispose);
      final kinds = {for (final i in c.read(designIssuesProvider)) i.kind};
      expect(kinds, contains('unconnected-orphan:SPLIT_L2'));
      expect(kinds, isNot(contains('unconnected-orphan:$kShopAcNodeId')));

      final bare = _load(shop, shop.network, room: false);
      addTearDown(bare.dispose);
      final bareKinds = {
        for (final i in bare.read(designIssuesProvider)) i.kind,
      };
      expect(bareKinds, contains('unconnected-orphan:$kShopAcNodeId'));
    });
  });
}
