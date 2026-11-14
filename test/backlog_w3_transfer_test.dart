// Backlog W-3 (2026-11-14) — every roof tank drawn on the transfer system
// is filled from the transfer main: its own branch carries its own fill flow
// (W-1), the shared main the sum; the transfer pump's flow is the sum of the
// fills it serves and its head the WORST tank (lift + friction + the 5 m
// inlet residual). A roof tank with no drawn fill is never given one: the
// info `roof-tank-fill-undrawn`. Also the W-2 warning end to end. Hand
// arithmetic in the comments (Hazen–Williams C150, hf = 10.67 L Q^1.852 /
// (150^1.852 D^4.8704)).
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/store/tank_fill_store.dart';
import 'package:mechx_engine/hydraulics.dart' show headLossHazenWilliams;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

import '../packages/mechx_engine/test/reference/shophouse.dart';

ProviderContainer _load(ReferenceBuilding shop, Network net) {
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
  return c;
}

double _hf(double lps, int dnMm, double l) => headLossHazenWilliams(
      flow: FlowRate.litersPerSecond(lps),
      length: Length(l),
      diameter: Diameter.mm(dnMm.toDouble()),
      hazenWilliamsC: 150,
    ).meters;

/// The shophouse with unit A's RT_A at 2000 L and a SECOND roof tank RT2_A
/// (1800 L) teed off the fill riser head U2_A, 300 px = 6.0 m east on
/// Lantai 3 (6.0 plan + 0.3 from the 11.7 ceiling to the 12.0 roof = 6.3 m).
Network _twoTanks(ReferenceBuilding shop, {bool fillDrawn = true}) {
  final u2 = shop.network.nodeById('U2_A')!;
  return Network(nodes: [
    for (final n in shop.network.nodes)
      n.id == 'RT_A' ? n.copyWith(tankCapacityLitres: 2000) : n,
    NetNode(
      id: 'RT2_A',
      sheetId: u2.sheetId,
      x: u2.x + 300,
      y: u2.y,
      floorIndex: 2,
      role: NodeRole.plant,
      component: NodeComponent.roofTank,
      tankCapacityLitres: 1800,
    ),
    // Undrawn fill: RT2_A only feeds a lavatory 2.0 m away (its own
    // gravity system), nothing flows INTO it.
    if (!fillDrawn)
      NetNode(
        id: 'LX_A',
        sheetId: u2.sheetId,
        x: u2.x + 400,
        y: u2.y,
        floorIndex: 2,
        role: NodeRole.fixture,
        fixture: PlumbingFixture.lavatory,
      ),
  ], edges: [
    ...shop.network.edges,
    if (fillDrawn)
      const NetEdge(
          id: 'e_cw_U2_A_RT2_A',
          fromId: 'U2_A',
          toId: 'RT2_A',
          service: ServiceType.coldWater)
    else
      const NetEdge(
          id: 'e_cw_RT2_A_LX_A',
          fromId: 'RT2_A',
          toId: 'LX_A',
          service: ServiceType.coldWater),
  ]);
}

void main() {
  final shop = buildShophouse();

  test('two roof tanks on one transfer main: branch = own fill, main = sum',
      () {
    final c = _load(shop, _twoTanks(shop));
    addTearDown(c.dispose);
    final sz = c.read(sizingProvider);
    // RT_A 2000 L / 3600 s = 0.555556 L/s; RT2_A 1800 / 3600 = 0.5 L/s.
    expect(sz['e_cw_U2_A_RT_A']!.flow.inLitersPerSecond,
        closeTo(0.555556, 1e-6));
    expect(sz['e_cw_U2_A_RT2_A']!.flow.inLitersPerSecond, closeTo(0.5, 1e-9));
    // 0.5 L/s: DN15 v 2.829 > 2.0 → DN20 v = 0.5e-3 / 3.14159e-4 = 1.592.
    expect(sz['e_cw_U2_A_RT2_A']!.diameter.inMillimeters, 20);
    // Shared main GT → TP → U0 → U1 → U2: 0.555556 + 0.5 = 1.055556 L/s;
    // DN25 v 2.150 > 2.0 → DN32 v = 1.055556e-3 / 8.04248e-4 = 1.312.
    for (final id in [
      'e_cw_GT_A_TP_A',
      'e_cw_TP_A_U0_A',
      'e_cw_U0_A_U1_A',
      'e_cw_U1_A_U2_A',
    ]) {
      expect(sz[id]!.flow.inLitersPerSecond, closeTo(1.055556, 1e-6),
          reason: id);
      expect(sz[id]!.diameter.inMillimeters, 32, reason: id);
    }
  });

  test('the transfer pump: flow = the sum of fills, head = the worst tank',
      () {
    final c = _load(shop, _twoTanks(shop));
    addTearDown(c.dispose);
    final tp = c.read(supplyMoverDutiesProvider)['TP_A']!;
    expect(c.read(transferPumpNodeIdsProvider), contains('TP_A'));
    expect(tp.flow.inLitersPerSecond, closeTo(1.055556, 1e-6));
    // Lift GT_A (slab 0.0) → roof 12.0 = 12.0 m for both tanks.
    // Common: GT → TP 1.0 m + TP → U0 4.7 + U0 → U1 4.0 + U1 → U2 4.0 at
    // 1.055556 L/s on DN32: 0.05835 + 0.74106 = 0.79941 m.
    // RT_A branch: 2.3 m at 0.555556 L/s DN20 = 0.40334 m → 12.0 + 0.79941
    // + 0.40334 + 5.0 = 18.20275 m.
    // RT2_A branch: 6.3 m at 0.5 L/s DN20 = 0.90895 m → 12.0 + 0.79941 +
    // 0.90895 + 5.0 = 18.70836 m — the worst, so the pump head.
    final common = _hf(1.055556, 32, 1.0 + 4.7 + 4.0 + 4.0);
    final rt = 12.0 + common + _hf(0.555556, 20, 2.3) + 5.0;
    final rt2 = 12.0 + common + _hf(0.5, 20, 6.3) + 5.0;
    expect(rt, closeTo(18.20275, 5e-4));
    expect(rt2, closeTo(18.70836, 5e-4));
    expect(tp.head.meters, closeTo(math.max(rt, rt2), 1e-6));
  });

  test('a roof tank with no drawn fill: no invented fill, an info on it', () {
    final c = _load(shop, _twoTanks(shop, fillDrawn: false));
    addTearDown(c.dispose);
    final kinds = [for (final i in c.read(designIssuesProvider)) i.kind];
    expect(kinds, contains('roof-tank-fill-undrawn:RT2_A'));
    expect(kinds.where((k) => k.startsWith('roof-tank-fill-undrawn')),
        hasLength(1));
    // The transfer main carries RT_A's fill alone.
    expect(
        c.read(sizingProvider)['e_cw_U1_A_U2_A']!.flow.inLitersPerSecond,
        closeTo(0.555556, 1e-6));
    final issue = c
        .read(designIssuesProvider)
        .firstWhere((i) => i.kind == 'roof-tank-fill-undrawn:RT2_A');
    expect(issue.locate?.nodeId, 'RT2_A');
  });

  test('W-5 warning: no capacity and no population ⇒ tank-capacity-unset, '
      'the peak basis kept', () {
    final c = _load(shop, shop.network);
    addTearDown(c.dispose);
    final kinds = {
      for (final i in c.read(designIssuesProvider))
        if (i.kind.startsWith('tank-capacity-unset')) i.kind,
    };
    expect(kinds, {
      for (final u in kShopUnits) ...{
        'tank-capacity-unset:GT_$u',
        'tank-capacity-unset:RT_$u',
      },
    });
    expect(c.read(tankFillsProvider).every((t) => t.fillFlow == null), isTrue);
    // Nothing fabricated: the fill line keeps the 12.5-UBAP peak.
    expect(c.read(sizingProvider)['e_cw_U2_A_RT_A']!.flow.inLitersPerSecond,
        closeTo(0.56389, 5e-5));
  });

  test('W-2 end to end: the meter warns only when the mains is short', () {
    final c = _load(shop, shop.network);
    addTearDown(c.dispose);
    bool warns() => c
        .read(designIssuesProvider)
        .any((i) => i.kind == 'mains-pressure-insufficient:WM_A');
    // Each unit's feed: −0.5 m lift + 3.5 m at 0.56389 L/s DN20 (0.63093 m)
    // + 5.0 m = 5.13093 m required (backlog_w2_mains_pressure_test).
    final chk = c
        .read(mainsPressureChecksProvider)
        .firstWhere((m) => m.meterId == 'WM_A');
    expect(chk.required.meters, closeTo(5.13093, 5e-4));
    expect(warns(), isFalse); // 10 m default
    c.read(mainsHeadProvider.notifier).set(5.0);
    expect(warns(), isTrue);
    final issue = c
        .read(designIssuesProvider)
        .firstWhere((i) => i.kind == 'mains-pressure-insufficient:WM_A');
    expect(issue.locate?.nodeId, 'WM_A');
    // Judge-only: the feed's size does not move.
    expect(c.read(sizingProvider)['e_cw_WM_A_GT_A']!.diameter.inMillimeters,
        20);
  });
}
