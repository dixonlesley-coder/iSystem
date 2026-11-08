// Round 25 — app half of the round-25 review fixes.
//
//   regression-legacy-demand-factor-0-reverted
//     Before round 23 the MEP feed minted demand factor 0 ONLY for a
//     life-safety standby fire pump. A 0 on a NON-life-safety way in a
//     pre-flag file can therefore only have been TYPED (the manual standby
//     workaround) — the first sync keeps it and flags it user-set.
//   regression-legacy-parked-way-typed-character-reverted-on-readopt
//     A PARKED way (source removed) from a legacy file is legacy too, so its
//     typed cos phi / phases survive re-adoption.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/electrical/load_list.dart' show defaultMotorCosPhi;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

Future<void> _settle(ProviderContainer c) async {
  await Future<void>.delayed(Duration.zero);
  c.read(electricalProjectProvider);
}

List<ElectricalCircuit> _mepWays(ProviderContainer c) => c
    .read(electricalProjectProvider)
    .panels
    .firstWhere((p) => p.id == kMepEquipmentPanelId)
    .circuits;

ElectricalCircuit _mepWay(ProviderContainer c) => _mepWays(c).single;

Future<ProviderContainer> _ahu() async {
  final c = _c();
  c.read(projectControllerProvider.notifier)
    ..setFloors([Floor('L0', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(electricalProjectProvider);
  c
      .read(networkControllerProvider.notifier)
      .addComponentNode('s1', 0, const Offset(700, 200), NodeComponent.ahu);
  await _settle(c);
  return c;
}

/// Re-encode the live project as a LEGACY (pre-round-23) file: no
/// `*UserSet` flags, no provenance marker; [edit] applies the typed values
/// (and may park the way by dropping its source id).
ElectricalProject _legacy(
  ElectricalProject p,
  void Function(Map<String, dynamic> way) edit,
) {
  final json = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
  for (final panel in (json['panels'] as List).cast<Map<String, dynamic>>()) {
    for (final w in (panel['circuits'] as List).cast<Map<String, dynamic>>()) {
      if (w['sourceEquipmentId'] == null) continue;
      w
        ..remove('cosPhiUserSet')
        ..remove('phasesUserSet')
        ..remove('loadKindUserSet')
        ..remove('demandFactorUserSet')
        ..remove(ElectricalCircuit.kMepProvenanceKey);
      edit(w);
    }
  }
  return ElectricalProject.fromJson(json);
}

void main() {
  group('legacy demand factor 0 on a non-life-safety way', () {
    test('is kept and flagged user-set on the first sync', () async {
      final c = await _ahu();
      expect(_mepWay(c).lifeSafety, isFalse);
      expect(_mepWay(c).demandFactor, 1); // the duty mint
      final e = c.read(electricalProjectProvider.notifier);
      e.setProject(_legacy(c.read(electricalProjectProvider), (w) {
        w['demandFactor'] = 0.0;
      }));
      expect(_mepWay(c).legacyProvenance, isTrue);
      e.resyncMepEquipment();
      final now = _mepWay(c);
      // Pre-r23 feeds minted 0 only on a life-safety fire standby ⇒ typed.
      expect(now.demandFactor, 0.0);
      expect(now.demandFactorUserSet, isTrue);
      expect(now.legacyProvenance, isFalse);
    });

    test('a legacy 1 (the duty mint) stays machine-owned', () async {
      final c = await _ahu();
      final e = c.read(electricalProjectProvider.notifier);
      e.setProject(_legacy(c.read(electricalProjectProvider), (_) {}));
      e.resyncMepEquipment();
      expect(_mepWay(c).demandFactor, 1);
      expect(_mepWay(c).demandFactorUserSet, isFalse);
    });

    test('a legacy typed 0 is PARKED, not dropped, when its source goes',
        () async {
      final c = await _ahu();
      final e = c.read(electricalProjectProvider.notifier);
      e.setProject(_legacy(c.read(electricalProjectProvider), (w) {
        w['demandFactor'] = 0.0;
      }));
      final nodeId = c.read(networkControllerProvider).network.nodes.single.id;
      c.read(networkControllerProvider.notifier).deleteNode(nodeId);
      await _settle(c);
      e.resyncMepEquipment();
      final ways = _mepWays(c);
      expect(ways, hasLength(1));
      expect(ways.single.name, endsWith(kMepParkedSuffix));
      expect(ways.single.demandFactor, 0.0);
    });
  });

  group('legacy PARKED way keeps its typed character on re-adoption', () {
    test('cos phi 0.95 + phases 1 survive', () async {
      final c = await _ahu();
      final minted = _mepWay(c);
      expect(minted.cosPhi, closeTo(defaultMotorCosPhi, 1e-12));
      expect(minted.phases, 3);
      final e = c.read(electricalProjectProvider.notifier);
      e.setProject(_legacy(c.read(electricalProjectProvider), (w) {
        w
          ..remove('sourceEquipmentId')
          ..['name'] = '${w['name']}$kMepParkedSuffix'
          ..['cosPhi'] = 0.95
          ..['phases'] = 1;
      }));
      expect(_mepWay(c).sourceEquipmentId, isNull);
      expect(_mepWay(c).legacyProvenance, isTrue);
      e.resyncMepEquipment();
      final now = _mepWay(c);
      expect(now.sourceEquipmentId, isNotNull); // re-adopted
      expect(now.name.endsWith(kMepParkedSuffix), isFalse);
      expect(now.cosPhi, 0.95);
      expect(now.phases, 1);
      expect(now.cosPhiUserSet, isTrue);
      expect(now.phasesUserSet, isTrue);
    });

    test('a parked way written by this build carries the marker', () {
      const parked = ElectricalCircuit(
          id: 'x', name: 'AHU$kMepParkedSuffix', cosPhi: 0.95);
      final j = parked.toJson();
      expect(j[ElectricalCircuit.kMepProvenanceKey], 1);
      expect(ElectricalCircuit.fromJson(j).legacyProvenance, isFalse);
      j.remove(ElectricalCircuit.kMepProvenanceKey);
      expect(ElectricalCircuit.fromJson(j).legacyProvenance, isTrue);
      // A hand-added way is never legacy.
      expect(
          ElectricalCircuit.fromJson(
                  const ElectricalCircuit(id: 'h', name: 'Pump').toJson())
              .legacyProvenance,
          isFalse);
    });
  });
}
