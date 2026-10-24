// Round 52 (2026-10-18) — engine half:
//
//   elec-convergence-4-undeclared-study-transformer-fault-not-the-printed-
//     transformer  the fault estimate reads the SAME supply study the advanced
//                  study prints (largest section / per-phase basis), so the
//                  fault study and every device kA derive from the issued unit
//   fire-convergence-4-staged-sprinkler-system-false-over-pressure
//                  a series (zoned) fire system is judged at each stage's
//                  discharge, never 1.4 x the summed head
//   regression-shared-suction-header-pump-rooms-still-combined-duty
//                  a pump-free suction header two independent pump rooms
//                  draw from splits them into two rating systems
//   regression-transfer-pump-into-tank (engine half) — a terminal-less system
//                  lifts to its OWN highest node, never the whole building
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _heat(String id, double w,
        {int phases = 3, PhaseLine? pin, double cosPhi = 0.9}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.heating,
      loadW: w,
      cosPhi: cosPhi,
      phases: phases,
      phaseOverride: pin,
      length: const Length(20),
    );

/// The fault (A) of the transformer [s] prints, one section's units.
double _printedFaultA(ElectricalProject p, dynamic s) {
  final units = p.dualTransformer ? s.units ~/ 2 : s.units;
  return (s.transformerKva as double) *
      1000 *
      math.max(1, units as int) /
      (math.sqrt(3) * 400 * ((s.impedancePct as double?) ?? 4.0) / 100);
}

void main() {
  group('undeclared MV service: the fault is the PRINTED transformer', () {
    // Dual, nothing declared. Root A: 250 + 150 kW (pf 0.9) + a 5 m feeder
    // to A1 carrying 100 kW; root B: 80 kW.
    //   total ~ 644 kVA / 2 = 322 / 0.8 = 403 ⇒ 500 kVA (the OLD estimate:
    //   500 000 / (√3·400·0.04) = 18 042 A);
    //   the study sizes on section A ~ 555 kVA / 0.8 = 694 ⇒ 800 kVA, prints
    //   2 x 800 kVA: 800 000 / (√3·400·0.04) = 28 867.5 A.
    ElectricalProject dual() => ElectricalProject(
          dualTransformer: true,
          panels: [
            ElectricalPanel(id: 'A', name: 'A', circuits: [
              _heat('a1', 250000),
              _heat('a2', 150000),
              const ElectricalCircuit(
                id: 'fa1',
                name: 'to A1',
                loadKind: LoadKind.feeder,
                loadW: 0,
                phases: 3,
                feedsPanelId: 'A1',
                length: Length(5),
              ),
            ]),
            ElectricalPanel(id: 'A1', name: 'A1', circuits: [
              _heat('x1', 100000),
            ]),
            ElectricalPanel(id: 'B', name: 'B', circuits: [
              _heat('b1', 80000),
            ]),
          ],
        );

    test('the derivation', () {
      expect(500000 / (math.sqrt(3) * 400 * 0.04), closeTo(18042.0, 0.5));
      expect(800000 / (math.sqrt(3) * 400 * 0.04), closeTo(28867.5, 0.5));
    });

    test('the estimate == the printed 800 kVA unit; every device rated on it',
        () {
      final p = dual();
      final sys = computeSystem(_p, p);
      final adv = computeAdvancedStudy(_p, p, sys);
      expect(adv.supply.isMv, isTrue);
      expect(adv.supply.transformerKva, 800);
      final printed = _printedFaultA(p, adv.supply);
      expect(printed, closeTo(28867.5, 0.5));
      final est = estimatedServiceFaultLevelA(p,
          demand: sys.supply.demandVa, supply: studySupplyDesign(p, sys))!;
      expect(est.amperes, closeTo(printed, 0.1));
      expect(adv.fault.originFaultkA * 1000, closeTo(printed, 6));
      // The OLD demand-only path still exists as the fallback (18 kA): the
      // fix is the threaded supply, never a changed formula.
      expect(estimatedServiceFaultLevelA(p, demand: sys.supply.demandVa)!
          .amperes, closeTo(18042.0, 0.5));
      for (final pf in adv.fault.panels.values) {
        expect(pf.incomerKa, greaterThanOrEqualTo(pf.prospectiveFaultkA - 1e-9),
            reason: pf.panelId);
      }
      for (final cf in adv.fault.circuits.values) {
        expect(cf.breakerKa, greaterThanOrEqualTo(cf.faultkA - 1e-9),
            reason: cf.circuitId);
      }
    });

    test('seeded property: undeclared MV projects (dual-unequal roots, a '
        'pinned-phase single root) fault on the printed unit', () {
      final rnd = math.Random(52);
      var mv = 0;
      for (var trial = 0; trial < 120; trial++) {
        final dualTx = rnd.nextBool();
        final roots = dualTx ? 2 + rnd.nextInt(2) : 1;
        final panels = <ElectricalPanel>[];
        for (var r = 0; r < roots; r++) {
          final n = 1 + rnd.nextInt(4);
          panels.add(ElectricalPanel(id: 'R$r', name: 'R$r', circuits: [
            for (var i = 0; i < n; i++)
              rnd.nextInt(3) == 0
                  // a single-phase way pinned to L1 (the per-phase basis)
                  ? _heat('R$r-$i', 5000.0 + rnd.nextInt(16000),
                      phases: 1, pin: PhaseLine.l1, cosPhi: 1)
                  : _heat('R$r-$i', 20000.0 + rnd.nextInt(280000)),
          ]));
        }
        final p = ElectricalProject(dualTransformer: dualTx, panels: panels);
        final sys = computeSystem(_p, p);
        final adv = computeAdvancedStudy(_p, p, sys);
        if (!adv.supply.isMv || adv.supply.transformerKva == null) continue;
        mv++;
        final printed = _printedFaultA(p, adv.supply);
        expect(adv.fault.originFaultkA * 1000, closeTo(printed, 6),
            reason: 'trial $trial');
        // Every verdict is judged against that unit's fault: a device below
        // it is reported inadequate (never a pass on a smaller transformer).
        for (final pf in adv.fault.panels.values) {
          expect(pf.incomerAdequate,
              pf.incomerKa >= pf.prospectiveFaultkA - 1e-9,
              reason: 'trial $trial ${pf.panelId}');
        }
        for (final cf in adv.fault.circuits.values) {
          expect(cf.breakerAdequate, cf.breakerKa >= cf.faultkA - 1e-9,
              reason: 'trial $trial ${cf.circuitId}');
        }
      }
      expect(mv, greaterThan(20), reason: 'the property is non-vacuous');
    });
  });

  group('staged fire over-pressure: judged at each stage discharge', () {
    // 20 x 3 m: FPS 67.77 m (L0) -> BS 30.00 m on L10 (30 m above datum).
    //   FPS discharge: 1.4 x 67.77 = 94.9 m = 930.6 kPa
    //   BS discharge:  94.9 - 30 + 1.4 x 30 = 106.9 m = 1048.9 kPa  (< 1210)
    //   the old judge: 1.4 x 97.77 = 136.9 m = 1342.8 kPa (> 1210, false)
    const q = FlowRate(0.012);
    final s0 = checkFirePumpRating(ratedFlow: q, ratedHead: const Head(67.77));
    final s1 = checkFirePumpRating(ratedFlow: q, ratedHead: const Head(30.0));
    const rhoG = 1000 * 9.81;

    test('the zoned tower passes; the maximum is at the booster', () {
      final c = fireStagedOverPressureCheck(stages: [
        FireStageLift(s0, 0, null),
        FireStageLift(s1, 30, 0),
      ], systemRatedHeadM: 97.77);
      const expectHead = 1.4 * 67.77 - 30 + 1.4 * 30;
      expect(c.stage, 1);
      expect(c.churnKpa,
          closeTo(rhoG * expectHead / 1000, rhoG * 0.05 / 1000));
      expect(c.over, isFalse);
      // The single-point judge at the summed head (the old basis) would warn.
      final whole = fireOverPressureCheck(
          rating: checkFirePumpRating(
              ratedFlow: q, ratedHead: const Head(97.77)));
      expect(whole.over, isTrue);
    });

    test('a single stage at z = 0 reduces exactly to fireOverPressureCheck',
        () {
      final one = fireStagedOverPressureCheck(
          stages: [FireStageLift(s0, 0, null)], systemRatedHeadM: 67.77);
      final ref = fireOverPressureCheck(rating: s0);
      expect(one.churnKpa, closeTo(ref.churnKpa, 1e-9));
      expect(one.over, ref.over);
    });
  });

  group('rating systems', () {
    NetNode n(String id, {int floor = 0, NodeRole role = NodeRole.main,
            NodeComponent? c}) =>
        NetNode(
            id: id,
            sheetId: 's',
            x: 0,
            y: 0,
            floorIndex: floor,
            role: role,
            component: c);
    NetEdge e(String id, String a, String b, ServiceType s,
            {EdgeKind k = EdgeKind.run}) =>
        NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);
    const h = ServiceType.fireHydrant;
    const sp = ServiceType.fireSprinkler;

    test('a shared suction header splits two pump rooms; the header is each '
        'one\'s SOURCE, never its kind', () {
      final net = Network(nodes: [
        n('GT', role: NodeRole.plant, c: NodeComponent.groundTank),
        n('SH'),
        n('FPH', role: NodeRole.plant, c: NodeComponent.pump),
        n('FPS', role: NodeRole.plant, c: NodeComponent.pump),
        n('DH'),
        n('HB', role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        n('DS'),
        n('SPK', role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
      ], edges: [
        e('gs', 'GT', 'SH', h),
        e('sh', 'SH', 'FPH', h),
        e('ss', 'SH', 'FPS', h),
        e('ph', 'FPH', 'DH', h),
        e('hb', 'DH', 'HB', h),
        e('ps', 'FPS', 'DS', sp),
        e('sk', 'DS', 'SPK', sp),
      ]);
      expect(fireSystems(net), hasLength(1));
      final r = fireRatingSystems(net);
      expect(r, hasLength(2));
      final hyd = r.singleWhere((s) => s.nodeIds.contains('FPH'));
      final spr = r.singleWhere((s) => s.nodeIds.contains('FPS'));
      expect(hyd.nodeIds.contains('FPS'), isFalse);
      expect(spr.nodeIds.contains('FPH'), isFalse);
      // The hydrant-service suction header never makes the sprinkler pump
      // room a hydrant system.
      expect(spr.hasHydrant, isFalse);
      expect(spr.hasSprinkler, isTrue);
      expect(hyd.hasHydrant, isTrue);
      expect(hyd.hasSprinkler, isFalse);
      for (final s in r) {
        expect(s.nodeIds, containsAll(['GT', 'SH']));
      }
    });

    test('a series chain and a single pump room stay one system', () {
      final net = Network(nodes: [
        n('GT', role: NodeRole.plant, c: NodeComponent.groundTank),
        n('P1', role: NodeRole.plant, c: NodeComponent.pump),
        n('M'),
        n('P2', role: NodeRole.plant, c: NodeComponent.pump),
        n('D'),
        n('HB', role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ], edges: [
        e('a', 'GT', 'P1', h),
        e('b', 'P1', 'M', h),
        e('c', 'M', 'P2', h),
        e('d', 'P2', 'D', h),
        e('f', 'D', 'HB', h),
      ]);
      expect(fireRatingSystems(net), hasLength(1));
    });

    test('no terminal: the lift is to the system\'s OWN highest node', () {
      final b = BuildingLevels([
        for (var i = 0; i < 20; i++) Floor('L$i', const Length(3)),
      ]);
      final net = Network(nodes: [
        n('GT', role: NodeRole.plant, c: NodeComponent.groundTank),
        n('TP', role: NodeRole.plant, c: NodeComponent.pump),
        n('A0'),
        n('A10', floor: 10),
      ], edges: [
        e('g', 'GT', 'TP', h),
        e('t', 'TP', 'A0', h),
        e('r', 'A0', 'A10', h, k: EdgeKind.riser),
      ]);
      final sys = fireSystems(net).single;
      // L10 outlet height: 10 x 3 + 1.2 = 31.2 m (never 19 x 3 + 1.2 = 58.2).
      expect(sys.staticLiftM(net, b, FireTerminalKind.hydrant),
          closeTo(31.2, 1e-9));
    });
  });
}
