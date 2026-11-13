// Reference apartment — regression tests for its review fixes (app level).
//
// A2: the `combined-fire-sprinkler-governs` Review warning is keyed and
// located on the DUTY fire pump of the basis, never the first String-sorted
// pump id (the jockey `FJ` sorted before the duty `FP`). The duty pump is
// read from the drawing (bore rank, then the mirrored leg, then draw order),
// so renaming the jockey to sort first or last, or shuffling the node / edge
// lists, never moves the warning off the duty pump.
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;

import '../packages/mechx_engine/test/reference/apartment.dart';

ProviderContainer _load(ReferenceBuilding b, Network net) {
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
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(occupancyProvider.notifier).set(b.occupancy);
  c.read(fireHazardProvider.notifier).set(FireHazardClass.lightHazard);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

/// [net] with node ids renamed by [rename] (edges follow) and both lists
/// rotated by [shift] (a deterministic shuffle).
Network _renamed(Network net, Map<String, String> rename, int shift) {
  String r(String id) => rename[id] ?? id;
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
        tankCapacityLitres: n.tankCapacityLitres,
      ),
  ];
  final edges = [
    for (final e in net.edges)
      NetEdge(
        id: e.id,
        fromId: r(e.fromId),
        toId: r(e.toId),
        service: e.service,
        kind: e.kind,
        sizeOverride: e.sizeOverride,
      ),
  ];
  List<T> rot<T>(List<T> l) =>
      [...l.skip(shift % l.length), ...l.take(shift % l.length)];
  return Network(nodes: rot(nodes), edges: rot(edges.reversed.toList()));
}

void main() {
  final apt = buildApartment();
  for (final (label, rename, shift) in [
    ('as drawn (jockey FJ sorts before the duty FP)', <String, String>{}, 0),
    ('jockey renamed to sort last, lists shuffled', {'FJ': 'ZZ_jockey'}, 37),
    ('jockey renamed to sort first, lists shuffled', {'FJ': 'AA_jockey'}, 101),
  ]) {
    test('A2 — combined-fire-sprinkler-governs is keyed on the duty pump: '
        '$label', () {
      final c = _load(apt, _renamed(apt.network, rename, shift));
      addTearDown(c.dispose);
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.sprinklerGovernsCombined, isTrue);
      expect(b.dutyPumpId, kAptDutyFirePump);
      final hits = [
        for (final i in c.read(designIssuesProvider))
          if (i.kind.startsWith('combined-fire-sprinkler-governs')) i,
      ];
      expect(hits.length, 1);
      expect(hits.single.kind, 'combined-fire-sprinkler-governs:FP');
      expect(hits.single.locate?.nodeId, kAptDutyFirePump);
    });
  }
}
