// Reference apartment — regression tests for its review fixes (app level).
//
// A2: the `combined-fire-sprinkler-governs` Review warning is keyed and
// located on the DUTY fire pump of the basis, never the first String-sorted
// pump id (the jockey `FJ` sorted before the duty `FP`). The duty pump is
// read from the drawing (bore rank, then the mirrored leg, then draw order),
// so renaming the jockey to sort first or last, or shuffling the node / edge
// lists, never moves the warning off the duty pump.
//
// A1: a combined sprinkler + hydrant fire pump is rated at the larger flow
// and the larger head of its two bases (every consumer reads that one
// point); standpipe-only and sprinkler-only systems are unchanged.
//
// Reference tower T2 (2026-11-13): as drawn, the apartment's velocity-sized
// DN32 sprinkler feed main is now ENLARGED (DN40) until the sprinkler point
// no longer exceeds the standpipe head, so the standpipe governs. The A1 /
// A2 cases below therefore HAND-PICK the feed main at DN32 (a sizeOverride
// is never enlarged): the sprinkler still sets the head there, exactly the
// situation the A1 / A2 rules are about.
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart' show nodeFedLoadsProvider;
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/units.dart' show Diameter;

import '../packages/mechx_engine/test/reference/apartment.dart';

ProviderContainer _load(ReferenceBuilding b, Network net) {
  final c = ProviderContainer();
  c
      .read(sheetsControllerProvider.notifier)
      .loadSheets(
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
  List<T> rot<T>(List<T> l) => [
    ...l.skip(shift % l.length),
    ...l.take(shift % l.length),
  ];
  return Network(nodes: rot(nodes), edges: rot(edges.reversed.toList()));
}

/// [net] with the sprinkler feed main (FH→S0 and the risers) hand-picked at
/// DN32, the bore the velocity rule gives it (T2 never enlarges a hand pick).
Network _feedMainPinned(Network net) => Network(
  nodes: net.nodes,
  edges: [
    for (final e in net.edges)
      if (e.service == ServiceType.fireSprinkler &&
          (e.id == 'e_sp_FH_S0' || RegExp(r'^e_sp_S\d+_S\d+$').hasMatch(e.id)))
        NetEdge(
          id: e.id,
          fromId: e.fromId,
          toId: e.toId,
          service: e.service,
          kind: e.kind,
          sizeOverride: Diameter.mm(32),
        )
      else
        e,
  ],
);

void main() {
  final apt = buildApartment();
  for (final (label, rename, shift) in [
    ('as drawn (jockey FJ sorts before the duty FP)', <String, String>{}, 0),
    ('jockey renamed to sort last, lists shuffled', {'FJ': 'ZZ_jockey'}, 37),
    ('jockey renamed to sort first, lists shuffled', {'FJ': 'AA_jockey'}, 101),
  ]) {
    test('A2 — combined-fire-sprinkler-governs is keyed on the duty pump: '
        '$label', () {
      final c = _load(
        apt,
        _renamed(_feedMainPinned(apt.network), rename, shift),
      );
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

  // A1: a combined sprinkler + hydrant pump is rated at the LARGER flow and
  // the LARGER head. Standpipe: Class I, 500 gpm = 31.5451 L/s @ 39.7 + 15 +
  // 70.336 = 125.036 m; sprinkler: 4.7140 L/s @ 41.7 + 5.097 + 80.257 =
  // 127.054 m ⇒ rated 31.5451 L/s @ 127.054 m.
  test('A1 — the combined pump covers both points: 31.545 L/s @ 127.054 m '
      '(feed main hand-picked DN32)', () {
    final c = _load(apt, _feedMainPinned(apt.network));
    addTearDown(c.dispose);
    final b = c.read(fireSystemBasesProvider).single;
    expect(b.standpipe!.requiredFlow.inLitersPerSecond, closeTo(31.5451, 5e-4));
    expect(b.standpipe!.pumpHead.meters, closeTo(125.036, 5e-4));
    expect(b.sprinklerGovernsCombined, isTrue); // the sprinkler sets the HEAD
    expect(b.flow.inLitersPerSecond, closeTo(31.5451, 5e-4));
    expect(b.head.meters, closeTo(127.054, 5e-4));
    // Hydraulic 9810 x 0.0315451 x 127.054 = 39 317.8 W; shaft / 0.70 =
    // 56 168.4 W.
    final d = c.read(firePumpDutyProvider)!;
    expect(d.flow.inLitersPerSecond, closeTo(31.5451, 5e-4));
    expect(d.hydraulicPower.watts, closeTo(39317.8, 0.5));
    expect(d.shaftPower.watts, closeTo(56168.4, 0.5));
    // Churn 1.4 x 127.054 = 177.876 m; overload 1.5 Q = 47.318 L/s @ 0.65 H
    // = 82.585 m, shaft 0.975 x 39 317.8 / 0.595 = 64 428 W ⇒ 75 kW.
    final r = b.rating;
    expect(r.ratedFlow.inLitersPerSecond, closeTo(31.5451, 5e-4));
    expect(r.churn.head.meters, closeTo(177.876, 5e-4));
    expect(r.overload.flow.inLitersPerSecond, closeTo(47.3176, 5e-4));
    expect(r.overload.head.meters, closeTo(82.585, 5e-4));
    expect(r.overload.shaftPower.watts, closeTo(64428.4, 0.5));
    expect(r.selectedMotor.inKiloWatts, closeTo(75, 1e-9));
    expect(d.selectedMotor.inKiloWatts, closeTo(75, 1e-9));
    // Jockey 1 % = 0.31545 L/s (= the flow its DN25 legs are sized on) @
    // churn + 5 = 182.876 m.
    final j = c.read(fireJockeyDutyProvider)!;
    expect(j.flow.inLitersPerSecond, closeTo(0.31545, 5e-5));
    expect(j.head.meters, closeTo(182.876, 5e-4));
    expect(
      c.read(sizingProvider)['e_fh_FT_FJ']!.flow.inLitersPerSecond,
      closeTo(j.flow.inLitersPerSecond, 1e-9),
    );
    // The MEP load reads the same point: 75 kW / 0.9 = 83 333.3 W.
    expect(c.read(nodeFedLoadsProvider)['FP']!.input, closeTo(83333.3, 0.05));
    // The Review names the split as an INFO on the duty pump.
    final i = c
        .read(designIssuesProvider)
        .singleWhere(
          (x) => x.kind.startsWith('combined-fire-sprinkler-governs'),
        );
    expect(i.severity, IssueSeverity.info);
    expect(i.message, contains('standpipe flow (31.5 L/s)'));
    // The over-pressure judges read the same rated head (churn 177.876 m).
    expect(
      c.read(fireOverPressureProvider).single.check.churnKpa,
      closeTo(177.876 * 9.81, 0.05),
    );
  });

  test('T2 — as drawn, the feed main is enlarged to DN40 and the standpipe '
      'governs: 31.545 L/s @ 125.036 m', () {
    final c = _load(apt, apt.network);
    addTearDown(c.dispose);
    final b = c.read(fireSystemBasesProvider).single;
    expect(b.sprinklerGovernsCombined, isFalse);
    expect(b.flow.inLitersPerSecond, closeTo(31.5451, 5e-4));
    expect(b.head.meters, closeTo(125.036, 5e-4));
    final sz = c.read(sizingProvider);
    final feed = [
      'e_sp_FH_S0',
      for (var f = 1; f < kAptFloors; f++) 'e_sp_S${f - 1}_S$f',
    ];
    for (final id in feed) {
      expect(sz[id]!.diameter.inMillimeters, 40, reason: id);
    }
    expect(c.read(sprinklerFeedEnlargedProvider), feed.toSet());
    // The heads' line is never enlarged.
    expect(sz['e_sp_S11_SP1']!.diameter.inMillimeters, 32);
    // 75 kW either way: overload shaft 0.975 x 38 693.4 / 0.595 = 63 405.2 W.
    expect(b.rating.selectedMotor.inKiloWatts, closeTo(75, 1e-9));
  });

  test('A1 — a standpipe-only and a sprinkler-only system are unchanged', () {
    bool sprinklerPart(String id) => RegExp(r'^(S\d+|SP\d)$').hasMatch(id);
    bool hydrantPart(String id) => RegExp(r'^(H\d+|HYD\d+)$').hasMatch(id);
    Network without(bool Function(String) drop) => Network(
      nodes: [
        for (final n in apt.network.nodes)
          if (!drop(n.id)) n,
      ],
      edges: [
        for (final e in apt.network.edges)
          if (!drop(e.fromId) && !drop(e.toId)) e,
      ],
    );
    // Standpipe only: rated on the standpipe point, 31.5451 L/s @ 125.036 m.
    final hose = _load(apt, without(sprinklerPart));
    addTearDown(hose.dispose);
    final bh = hose.read(fireSystemBasesProvider).single;
    expect(bh.sprinklerGovernsCombined, isFalse);
    expect(bh.flow.inLitersPerSecond, closeTo(31.5451, 5e-4));
    expect(bh.head.meters, closeTo(125.036, 5e-4));
    // Sprinkler only: rated on the sprinkler remote-area flow 4.7140 L/s.
    final spr = _load(apt, without(hydrantPart));
    addTearDown(spr.dispose);
    final bs = spr.read(fireSystemBasesProvider).single;
    expect(bs.sprinklerOnly, isTrue);
    expect(bs.sprinklerGovernsCombined, isFalse);
    expect(bs.flow.inLitersPerSecond, closeTo(4.7140, 5e-4));
  });
}
