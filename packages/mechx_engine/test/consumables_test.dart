import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/bom.dart' show FittingType;
import 'package:mechx_engine/sizing/consumables.dart';
import 'package:test/test.dart';

void main() {
  group('joinMethodForService', () {
    test('PVC drainage/vent/storm weld; water fuses; fire threads', () {
      expect(joinMethodForService(ServiceType.drainage),
          PipeJoinMethod.solventWeld);
      expect(
          joinMethodForService(ServiceType.vent), PipeJoinMethod.solventWeld);
      expect(joinMethodForService(ServiceType.rainwater),
          PipeJoinMethod.solventWeld);
      expect(joinMethodForService(ServiceType.coldWater),
          PipeJoinMethod.heatFusion);
      expect(joinMethodForService(ServiceType.hotWater),
          PipeJoinMethod.heatFusion);
      expect(joinMethodForService(ServiceType.fireSprinkler),
          PipeJoinMethod.threaded);
    });
  });

  group('fittingSockets', () {
    test('elbow 2, tee 3, cross 4, reducer 2', () {
      expect(fittingSockets(FittingType.elbow), 2);
      expect(fittingSockets(FittingType.tee), 3);
      expect(fittingSockets(FittingType.cross), 4);
      expect(fittingSockets(FittingType.reducer), 2);
    });
  });

  group('estimateConsumables', () {
    test('PVC cement cans round up from per-joint ml by DN', () {
      // 200 joints @ DN100 ⇒ 6 ml each = 1200 ml ⇒ 2 cans (1000 ml/can).
      final e =
          estimateConsumables(solventJointsByDn: {100: 200}, ductSealMetres: 0, threadedJoints: 0);
      expect(e.solventJoints, 200);
      expect(e.pvcCementMl, closeTo(1200.0, 1e-6));
      expect(e.pvcCementCans, 2);
      expect(e.ductSealantCartridges, 0);
      expect(e.threadTapeRolls, 0);
    });

    test('mixed DN groups sum their cement', () {
      // 100×DN50 (3 ml) = 300 ml + 50×DN150 (9 ml) = 450 ml ⇒ 750 ml ⇒ 1 can.
      final e = estimateConsumables(
          solventJointsByDn: {50: 100, 150: 50},
          ductSealMetres: 0,
          threadedJoints: 0);
      expect(e.pvcCementMl, closeTo(750.0, 1e-6));
      expect(e.pvcCementCans, 1);
    });

    test('duct sealant cartridges from joint length', () {
      // 25 m of bead / 11 m per cartridge ⇒ 3 cartridges.
      final e = estimateConsumables(
          solventJointsByDn: const {}, ductSealMetres: 25.0, threadedJoints: 0);
      expect(e.ductSealantCartridges, 3);
    });

    test('thread tape rolls from threaded joints', () {
      // 65 threaded joints / 30 per roll ⇒ 3 rolls.
      final e = estimateConsumables(
          solventJointsByDn: const {}, ductSealMetres: 0, threadedJoints: 65);
      expect(e.threadTapeRolls, 3);
    });

    test('an empty network needs nothing', () {
      final e = estimateConsumables(
          solventJointsByDn: const {}, ductSealMetres: 0, threadedJoints: 0);
      expect(e.isEmpty, isTrue);
      expect(e.pvcCementCans, 0);
    });
  });
}
