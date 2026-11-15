// Backlog D-4 (2026-11-13) — shared by the apartment and tower reference app
// tests: place the fixture's PRV stations with the store intent
// `NetworkController.insertComponentOnRiser` and fingerprint every solved
// figure the reference pins read, so the drawn (intent) station and the
// fixture's spliced station (a 0 m run) can be compared exactly.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/network/network.dart';

/// Insert a PRV on the cold-water riser `GR(k+1) → GRk` at floor k for every
/// k in [prvFloors] (the fixture's station floors), through the store intent.
/// Returns fixture PRV id → the intent's node id.
Map<String, String> placePrvsByIntent(
    ProviderContainer c, Iterable<int> prvFloors) {
  final ctrl = c.read(networkControllerProvider.notifier);
  final ids = <String, String>{};
  for (final k in prvFloors) {
    final id = ctrl.insertComponentOnRiser(
      'e_cw_GR${k + 1}_GR$k',
      NodeComponent.prv,
      floorIndex: k,
    );
    if (id == null) throw StateError('PRV on GR${k + 1}_GR$k refused');
    ids['PRV$k'] = id;
  }
  return ids;
}

/// Every figure the PRV pins read, as sorted lines (PRV node ids replaced by
/// their fixture ids through [alias]). Pressures to 1e-6 kPa, lengths to
/// 1e-9 m.
List<String> prvFingerprint(ProviderContainer c,
    [Map<String, String> alias = const {}]) {
  String id(String x) => alias[x] ?? x;
  final out = <String>[];
  for (final z in c.read(zonesProvider)) {
    out.add('zone ${z.bottomFloorIndex}-${z.topFloorIndex}');
  }
  for (final s in c.read(zoneStaticsProvider)) {
    out.add('zoneStatic ${s.bottomStatic.inKiloPascals.toStringAsFixed(6)} '
        '${s.topResidual.inKiloPascals.toStringAsFixed(6)} ${s.viaPrv}');
  }
  final del = c.read(downfeedDeliveredProvider);
  if (del != null) {
    out.add('critical ${id(del.criticalNodeId)}');
    for (final e in del.residualPressure.entries) {
      out.add('res ${id(e.key)} ${e.value.inKiloPascals.toStringAsFixed(6)}');
    }
    for (final e in del.noFlowStaticPressure.entries) {
      out.add('st ${id(e.key)} ${e.value.inKiloPascals.toStringAsFixed(6)}');
    }
  }
  for (final o in c.read(downfeedOverPressureProvider)) {
    out.add('over ${id(o.nodeId)}');
  }
  for (final e in c.read(supplyMoverDutiesProvider).entries) {
    out.add('mover ${e.key} ${e.value.flow.inLitersPerSecond.toStringAsFixed(6)}'
        ' ${e.value.head.meters.toStringAsFixed(6)}');
  }
  for (final l in c.read(bomProvider)) {
    out.add('bom ${l.service.name} ${l.kind.name} ${l.diameterMm} '
        '${l.material} ${l.totalLength.meters.toStringAsFixed(9)} ${l.tag}');
  }
  for (final l in c.read(componentTakeoffProvider)) {
    out.add('takeoff ${l.component.name} ${l.variant} ${l.count}');
  }
  for (final i in c.read(designIssuesProvider)) {
    var k = i.kind;
    for (final a in alias.entries) {
      k = k.replaceAll(a.key, a.value);
    }
    out.add('issue $k');
  }
  return out..sort();
}
