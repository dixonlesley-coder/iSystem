// Backlog A-2..A-5 (2026-11-13) — fire / mechanical-judge backlog items on
// the reference buildings, through the real app providers.
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_water_reserve.dart';

import '../packages/mechx_engine/test/reference/office.dart';
import '../packages/mechx_engine/test/reference/shophouse.dart';

ProviderContainer _load(ReferenceBuilding b, FeedStrategy feed,
    {Network? network, bool shopRooms = false}) {
  final c = ProviderContainer();
  c.read(sheetsControllerProvider.notifier).loadSheets(
    [
      for (final s in b.sheets)
        Sheet(id: s.id, name: s.name, sizePx: const Size(2384, 1684)),
    ],
    sheetFloors: {for (final s in b.sheets) s.id: s.floorIndex},
  );
  final project = c.read(projectControllerProvider.notifier)
    ..setFloors(b.building.floors);
  for (final MapEntry(:key, :value) in b.calibrations.entries) {
    project.setCalibration(key, value);
  }
  c.read(feedStrategyProvider.notifier).set(feed);
  c.read(occupancyProvider.notifier).set(b.occupancy);
  c.read(fireHazardProvider.notifier).set(FireHazardClass.lightHazard);
  c.read(networkControllerProvider.notifier).loadNetwork(network ?? b.network);
  if (shopRooms) {
    final rooms = c.read(roomAreasProvider.notifier);
    for (final r in kShophouseRooms) {
      final id = rooms.add(
        sheetId: r.sheetId,
        floorIndex: r.floorIndex,
        ax: r.ax,
        ay: r.ay,
        bx: r.bx,
        by: r.by,
      )!;
      rooms
        ..setRoomType(id, r.roomType)
        ..setName(id, r.name);
    }
  }
  return c;
}

Network _withoutNodes(Network n, Set<String> ids) => Network(
      nodes: [for (final x in n.nodes) if (!ids.contains(x.id)) x],
      edges: [
        for (final e in n.edges)
          if (!ids.contains(e.fromId) && !ids.contains(e.toId)) e,
      ],
    );

void main() {
  group('A-2 fire-water reserve (office)', () {
    test(
        'FT has no capacity ⇒ info stating 31.5451 x 1800 = 56 781 L; a set '
        'capacity below it warns, at / above it is silent', () {
      final c = _load(buildOffice(), FeedStrategy.upfeed);
      addTearDown(c.dispose);
      final t = c.read(fireTankReservesProvider).single;
      expect(t.tankId, 'FT');
      expect(t.reserve.ratedFlow.inLitersPerSecond, closeTo(31.5451, 5e-5));
      expect(t.reserve.durationMin, 30); // standpipe + light hazard
      expect(t.requiredLitres, closeTo(56781.2, 0.1));
      expect(t.capacityLitres, isNull); // never fabricated
      expect(t.verdict, FireTankVerdict.unset);
      List<String> kinds() =>
          [for (final i in c.read(designIssuesProvider)) i.kind];
      expect(kinds(), contains('fire-tank-capacity-unset:FT'));
      expect(kinds(), isNot(contains('fire-tank-undersized:FT')));
      final info = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'fire-tank-capacity-unset:FT');
      expect(info.severity, IssueSeverity.info);
      expect(info.message, contains('56781 L'));
      expect(info.locate?.nodeId, 'FT');

      final net = c.read(networkControllerProvider.notifier);
      net.setNodeTankCapacity('FT', 50000);
      final w = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'fire-tank-undersized:FT');
      expect(w.severity, IssueSeverity.warning);
      expect(w.locate?.nodeId, 'FT');
      expect(kinds(), isNot(contains('fire-tank-capacity-unset:FT')));

      net.setNodeTankCapacity('FT', 56782);
      expect(kinds().where((k) => k.startsWith('fire-tank-')), isEmpty);
    });
  });

  group('A-4 too few / too small AC units (shophouse room, 44 400 BTU/h)', () {
    List<String> roomKinds(ProviderContainer c) => [
          for (final i in c.read(designIssuesProvider))
            if (i.kind.startsWith('room-cooling-undersized')) i.kind,
        ];

    test('two 2.5 PK cassettes (48 000 BTU/h) ⇒ no finding', () {
      final c = _load(buildShophouse(), FeedStrategy.downfeed, shopRooms: true);
      addTearDown(c.dispose);
      final room = c.read(roomAreasProvider).single;
      expect(c.read(roomCoolingLoadProvider(room.id))!.btuPerHr,
          closeTo(44400, 1e-6));
      expect(roomKinds(c), isEmpty);
    });

    test('one cassette ⇒ warning: 44 400 > 27 000, needs 2 units', () {
      final shop = buildShophouse();
      final c = _load(shop, FeedStrategy.downfeed,
          network: _withoutNodes(shop.network, {kShopAcNodeIds.last}),
          shopRooms: true);
      addTearDown(c.dispose);
      final room = c.read(roomAreasProvider).single;
      final w = c
          .read(designIssuesProvider)
          .singleWhere((i) => i.kind == 'room-cooling-undersized:${room.id}');
      expect(w.severity, IssueSeverity.warning);
      expect(w.message, contains('44400 BTU/h'));
      expect(w.message, contains('27000 BTU/h'));
      expect(w.message, contains('at least 2 x 3 PK'));
      expect(w.locate?.nodeId, kShopAcNodeIds.first);
      expect(w.locate?.sheetId, room.sheetId);
    });

    test('no AC unit at all ⇒ no finding (an un-designed room, not an '
        'undersized one)', () {
      final shop = buildShophouse();
      final c = _load(shop, FeedStrategy.downfeed,
          network: _withoutNodes(shop.network, kShopAcNodeIds.toSet()),
          shopRooms: true);
      addTearDown(c.dispose);
      expect(c.read(roomCoolingLoadProvider(c.read(roomAreasProvider).single.id)),
          isNotNull);
      expect(roomKinds(c), isEmpty);
    });
  });
}
