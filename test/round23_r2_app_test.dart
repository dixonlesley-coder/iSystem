// Round 23 r2 — the app half of the round-23 reviewer follow-ups:
//
//   elec-drafting-2-5  the summary card labels an ACB incomer 'ACB'
//   mep-bridge-2       a typed cos phi / phase count / load kind on a derived
//                      way is the engineer's (provenance) — the MEP sync's
//                      component-swap re-derivation never reverts it

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart'
    show breakerClassLabel;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/puil.dart';
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

ElectricalPanel? _mepBoard(ProviderContainer c) => c
    .read(electricalProjectProvider)
    .panels
    .where((p) => p.id == kMepEquipmentPanelId)
    .firstOrNull;

void main() {
  test('elec-drafting-2-5: the card labels every class by its own code', () {
    BreakerResult b(BreakerClass cls, double a) => BreakerResult(
      ratingA: Current(a),
      deviceClass: cls,
      curve: BreakerCurve.c,
    );
    expect(breakerClassLabel(b(BreakerClass.mcb, 16)), 'MCB');
    expect(breakerClassLabel(b(BreakerClass.mccb, 250)), 'MCCB');
    expect(breakerClassLabel(b(BreakerClass.acb, 2500)), 'ACB');
  });

  group('mep-bridge-2: typed electrical character survives the sync', () {
    Future<(ProviderContainer, ElectricalCircuit, String)> ahu() async {
      final c = _c();
      c.read(projectControllerProvider.notifier)
        ..setFloors([Floor('L0', const Length(3.5))])
        ..setCalibration('s1', const ScaleCalibration(0.01));
      c.read(electricalProjectProvider);
      final net = c.read(networkControllerProvider.notifier);
      net.addComponentNode('s1', 0, const Offset(700, 200), NodeComponent.ahu);
      await _settle(c);
      final node = c
          .read(networkControllerProvider)
          .network
          .nodes
          .firstWhere((n) => n.component == NodeComponent.ahu);
      return (c, _mepBoard(c)!.circuits.single, node.id);
    }

    test(
      'a typed cos phi + phase count are kept across a component swap',
      () async {
        final (c, way, nodeId) = await ahu();
        final e = c.read(electricalProjectProvider.notifier);
        e.setCircuit(kMepEquipmentPanelId, way.id, cosPhi: 0.95, phases: 1);
        c
            .read(networkControllerProvider.notifier)
            .setNodeComponent(nodeId, NodeComponent.acSplitWall);
        await _settle(c);
        e.resyncMepEquipment();
        final now = _mepBoard(c)!.circuits.firstWhere((w) => w.id == way.id);
        final fresh = c
            .read(mepAutoFeedCircuitsProvider)
            .firstWhere((w) => w.sourceEquipmentId == way.sourceEquipmentId);
        expect(now.cosPhi, 0.95);
        expect(now.phases, 1);
        expect(now.cosPhiUserSet, isTrue);
        expect(now.phasesUserSet, isTrue);
        // The UNTYPED character still follows the new unit.
        expect(now.loadKindUserSet, isFalse);
        expect(now.loadKind, fresh.loadKind);
        expect(now.name, NodeComponent.acSplitWall.label);
        // Provenance round-trips in .mechx.
        final back = ElectricalCircuit.fromJson(now.toJson());
        expect(back.cosPhiUserSet, isTrue);
        expect(back.phasesUserSet, isTrue);
        expect(back.loadKindUserSet, isFalse);
      },
    );

    test('an untouched derived way still re-derives all three', () async {
      final (c, way, nodeId) = await ahu();
      expect(
        way.cosPhiUserSet || way.phasesUserSet || way.loadKindUserSet,
        isFalse,
      );
      c
          .read(networkControllerProvider.notifier)
          .setNodeComponent(nodeId, NodeComponent.acSplitWall);
      await _settle(c);
      final now = _mepBoard(c)!.circuits.firstWhere((w) => w.id == way.id);
      final fresh = c
          .read(mepAutoFeedCircuitsProvider)
          .firstWhere((w) => w.sourceEquipmentId == way.sourceEquipmentId);
      expect(now.cosPhi, fresh.cosPhi);
      expect(now.phases, fresh.phases);
      expect(now.loadKind, fresh.loadKind);
    });

    test('a typed load kind is kept', () async {
      final (c, way, nodeId) = await ahu();
      final e = c.read(electricalProjectProvider.notifier);
      e.setCircuit(kMepEquipmentPanelId, way.id, loadKind: way.loadKind);
      c
          .read(networkControllerProvider.notifier)
          .setNodeComponent(nodeId, NodeComponent.acSplitWall);
      await _settle(c);
      final now = _mepBoard(c)!.circuits.firstWhere((w) => w.id == way.id);
      expect(now.loadKindUserSet, isTrue);
      expect(now.loadKind, way.loadKind);
    });
  });
}
