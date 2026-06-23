import 'package:mechx_engine/electrical/control/contactor.dart';
import 'package:mechx_engine/electrical/control/control_gear.dart';
import 'package:mechx_engine/electrical/control/motor_flc.dart';
import 'package:mechx_engine/electrical/control/pump_control.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/control/starting.dart';
import 'package:mechx_engine/electrical/control/vfd.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Seed tests for the IEC 60947 motor-control domain. Expected values are
/// hand-derived from the standards tables + the formulas and act as the
/// correctness anchor (CLAUDE.md: "tests are the spec").
void main() {
  group('motorFlc (IEC 60034-1 400 V table)', () {
    test('7.5 kW @ 400 V is the exact table entry → 15.5 A', () {
      // The 400 V table has an exact row: 7.5 kW → 15.5 A. Voltage scale
      // 400/400 = 1, so FLC = 15.5 A.
      expect(motorFlc(7.5).amperes, closeTo(15.5, 1e-9));
    });

    test('interpolates between rows: 9 kW (11 kW→22 A, 7.5 kW→15.5 A)', () {
      // Linear: t = (9 - 7.5)/(11 - 7.5) = 1.5/3.5 = 0.428571…
      // FLC = 15.5 + t·(22 - 15.5) = 15.5 + 0.428571·6.5 = 15.5 + 2.7857 = 18.2857 A
      expect(motorFlc(9).amperes, closeTo(18.2857, 1e-3));
    });

    test('voltage scaling: FLC ∝ 1/V → 7.5 kW @ 380 V', () {
      // 15.5 × 400/380 = 16.3158 A
      expect(motorFlc(7.5, const Voltage(380)).amperes, closeTo(16.3158, 1e-3));
    });

    test('clamps below/above the table', () {
      expect(motorFlc(0.1).amperes, closeTo(1.0, 1e-9)); // first row
      expect(motorFlc(999).amperes, closeTo(435.0, 1e-9)); // last row
    });

    test('motorFlc1ph uses η·cosφ: 1.5 kW @ 230 V, η·cosφ = 0.65', () {
      // I = 1500 / (230 × 0.65) = 1500 / 149.5 = 10.0334 A
      expect(motorFlc1ph(1.5).amperes, closeTo(10.0334, 1e-3));
    });
  });

  group('selectContactor (AC-3 frames)', () {
    test('DOL 7.5 kW (FLC 15.5 A) → smallest frame ≥ 15.5 = 18 A', () {
      final sel = selectContactor(const Current(15.5));
      expect(sel.ac3A, 18);
      expect(sel.kw400, 7.5);
      expect(sel.targetA, closeTo(15.5, 1e-9));
      expect(sel.ok, isTrue);
    });

    test('star winding ×0.58: 22 kW (FLC 42 A) → 42·0.58 = 24.36 → 25 A frame', () {
      final sel = selectContactor(const Current(42), starDelta: true);
      // target = 42 × 0.58 = 24.36 A, reported rounded to 1 dp = 24.4 A
      // (PanelMaker `round(targetA, 1)`); smallest frame ≥ 24.36 is 25 A.
      expect(sel.targetA, closeTo(24.4, 1e-9));
      expect(sel.ac3A, 25);
    });

    test('AC-4 jogging needs a much larger frame: FLC 9 A → 9/0.25 = 36 → 40 A', () {
      final sel = selectContactor(const Current(9), duty: StartingDuty.jogging);
      // required AC-3 = 9 / 0.25 = 36 A → smallest frame ≥ 36 is 40 A.
      expect(sel.ac3A, 40);
    });

    test('beyond the table → largest frame, ok = false', () {
      final sel = selectContactor(const Current(1000));
      expect(sel.ac3A, 630);
      expect(sel.ok, isFalse);
    });
  });

  group('selectOverload', () {
    test('setting = motor FLC, class 10 for normal duty', () {
      final ol = selectOverload(const Current(15.5));
      expect(ol.settingA.amperes, closeTo(15.5, 1e-9));
      expect(ol.tripClass, OverloadTripClass.class10);
    });

    test('delta leg ×0.58 + heavy duty → class 20', () {
      final ol =
          selectOverload(const Current(42), inStarLeg: true, duty: StartingDuty.heavy);
      // 42 × 0.58 = 24.36 → rounded 1 dp = 24.4 A
      expect(ol.settingA.amperes, closeTo(24.4, 1e-9));
      expect(ol.tripClass, OverloadTripClass.class20);
    });
  });

  group('selectVfd', () {
    test('FLC 15.5 A → required 17.05 A → smallest output ≥ 17.05 = 17 A? no → 25 A', () {
      // required = 15.5 × 1.1 = 17.05 A (reported rounded to 1 dp = 17.1 A).
      // The 17 A drive (7.5 kW) is < 17.05, so the next frame up
      // (11 kW / 25 A) is chosen.
      final v = selectVfd(const Current(15.5));
      expect(v.requiredA.amperes, closeTo(17.1, 1e-9));
      expect(v.outputA.amperes, 25);
      expect(v.ratedKw, 11);
      // heat = 11 kW × (1 − 0.96) = 440 W
      expect(v.heatLossW, closeTo(440, 1e-9));
      expect(v.ok, isTrue);
    });

    test('constant-torque bumps one frame up', () {
      final v = selectVfd(const Current(15.5), constantTorque: true);
      // base pick is 25 A (11 kW); constant-torque → next = 32 A (15 kW)
      expect(v.outputA.amperes, 32);
      expect(v.ratedKw, 15);
    });
  });

  group('sizeControlTransformer', () {
    test('two 25 A-frame contactor coils + 10 VA pilot → 150 VA', () {
      // Two contactors at ac3A=25 → frame ≤40 bucket → sealed 7, inrush 40 each.
      // ΣSealed = 7+7+10 = 24, ΣInrush = 40+40 = 80.
      // combined = √(24² + 80²) = √(576 + 6400) = √6976 = 83.5224 VA
      // × 1.2 margin = 100.2269 VA (reported rounded to 1 dp = 100.2 VA) →
      // smallest standard ≥ 100.23 = 150 VA.
      final burdens = [coilBurdenForFrame(25), coilBurdenForFrame(25)];
      final tx = sizeControlTransformer(burdens, pilotSealedVa: 10);
      expect(tx.requiredVa.voltAmperes, closeTo(100.2, 1e-9));
      expect(tx.chosenVa.voltAmperes, 150);
      expect(tx.ok, isTrue);
    });
  });

  group('startingAnalysis', () {
    test('DOL: 6.5× FLC, 100% torque', () {
      final s = startingAnalysis(const Current(15.5), StarterType.dol);
      // 15.5 × 6.5 = 100.75 → rounded 0 dp = 101 A
      expect(s.startCurrentMultiple, 6.5);
      expect(s.startCurrentA.amperes, closeTo(101, 1e-9));
      expect(s.startTorquePct, 100);
    });

    test('star-delta: 2.2× FLC, 33% torque', () {
      final s = startingAnalysis(const Current(42), StarterType.starDelta);
      // 42 × 2.2 = 92.4 → rounded 0 dp = 92 A
      expect(s.startCurrentMultiple, 2.2);
      expect(s.startCurrentA.amperes, closeTo(92, 1e-9));
      expect(s.startTorquePct, 33);
    });

    test('VFD variable-torque note mentions energy saving', () {
      final s = startingAnalysis(const Current(15.5), StarterType.vfd,
          variableTorque: true);
      expect(s.startCurrentMultiple, 1.5);
      expect(s.note.toLowerCase(), contains('energy saving'));
    });
  });

  group('applyStarterTemplate — DOL', () {
    final a = applyStarterTemplate(
      circuitId: 'c1',
      starterType: StarterType.dol,
      motorKw: 7.5,
    );

    test('FLC stamped on the motor (7.5 kW → 15.5 A)', () {
      expect(a.motor!.flcA.amperes, closeTo(15.5, 1e-9));
      expect(a.motor!.kw, 7.5);
    });

    test('5 device slots, no interlocks (main-contactor + overload + 3 pilots)', () {
      expect(a.devices.length, 5);
      expect(a.interlocks, isEmpty);
      expect(a.devices.map((d) => d.role),
          containsAll(['main-contactor', 'overload', 'start-pb', 'stop-pb', 'run-lamp']));
    });

    test('main contactor sized to 18 A AC-3', () {
      final mc = a.devices.firstWhere((d) => d.role == 'main-contactor');
      expect(mc.rating, contains('18 A AC-3'));
    });

    test('Type-2 coordination set attached for 7.5 kW (breaker 18 A, contactor 18 A)', () {
      expect(a.coordination, isNotNull);
      expect(a.coordination!.breakerA.amperes, 18);
      expect(a.coordination!.contactorAc3A.amperes, 18);
      expect(a.coordination!.contactorMatches, isTrue);
    });

    test('verifyItems carry the honesty surface', () {
      expect(a.verifyItems, isNotEmpty);
      expect(a.verifyItems.join(' '), contains('IEC 60034-1'));
    });

    test('no warnings for an in-range DOL', () {
      expect(a.warnings, isEmpty);
    });
  });

  group('applyStarterTemplate — Star-Delta', () {
    final a = applyStarterTemplate(
      circuitId: 'c2',
      starterType: StarterType.starDelta,
      motorKw: 22,
    );

    test('8 base slots + control transformer (required) = 9 devices', () {
      // template has 8 slots; starDelta requires a control transformer → +1.
      expect(a.devices.length, 9);
      expect(a.devices.any((d) => d.role == 'control-transformer'), isTrue);
    });

    test('three contactors: main + delta (full FLC) + star (58%)', () {
      final contactors =
          a.devices.where((d) => d.category == DeviceCategory.contactor).toList();
      expect(contactors.length, 3);
      final star = a.devices.firstWhere((d) => d.role == 'star-contactor');
      // 22 kW → FLC 42 A; star target = 42 × 0.58 = 24.36 → 25 A frame.
      expect(star.rating, contains('25 A AC-3'));
      expect(star.rating, contains('star'));
    });

    test('two interlocks (mechanical + electrical mutual-exclusion star/delta)', () {
      expect(a.interlocks.length, 2);
      for (final il in a.interlocks) {
        expect(il.relation, InterlockRelation.mutualExclusion);
        expect(il.deviceAId, 'c2:star-contactor');
        expect(il.deviceBId, 'c2:delta-contactor');
      }
      expect(a.interlocks.map((i) => i.kind),
          containsAll([InterlockKind.mechanical, InterlockKind.electrical]));
    });

    test('overload sits in the delta leg (FLC × 0.58)', () {
      final ol = a.devices.firstWhere((d) => d.role == 'overload');
      // 42 × 0.58 = 24.36 → 24.4 A (1 dp)
      expect(ol.rating, contains('24.4 A'));
      expect(ol.rating, contains('delta leg'));
    });
  });

  group('applyPumpControl', () {
    test('fill pump adds sensing devices + records the config', () {
      final base = applyStarterTemplate(
        circuitId: 'p1',
        starterType: StarterType.pump,
        motorKw: 3,
      );
      final pc = applyPumpControl(base, PumpControlMode.fill);
      expect(pc.pump.mode, PumpControlMode.fill);
      expect(pc.pump.sensing, LevelSensing.electrode);
      // base DOL-basis (5) + 3 fill sensors = 8 devices
      expect(pc.assembly.devices.length, 8);
    });
  });

  group('computePumpGroup', () {
    PumpGroupMember member(String id, String name) {
      final ctrl = applyStarterTemplate(
        circuitId: id,
        starterType: StarterType.pump,
        motorKw: 3,
      );
      return PumpGroupMember(circuitId: id, name: name, control: ctrl);
    }

    test('single-alternate (duty/standby) → controller + alternator + mutual-exclusion', () {
      final r = computePumpGroup(
        const PumpGroupConfig(
          id: 'g1',
          name: 'Transfer pumps',
          mode: PumpGroupMode.singleAlternate,
          trigger: PumpGroupTrigger.level,
        ),
        [member('pa', 'Pump A'), member('pb', 'Pump B')],
      );
      // level controller + alternator relay
      expect(r.devices.length, 2);
      expect(r.devices.any((d) => d.category == DeviceCategory.levelRelay), isTrue);
      expect(
          r.devices.any((d) => d.category == DeviceCategory.alternatorRelay), isTrue);
      // 2 members → one mutual-exclusion interlock
      expect(r.interlocks.length, 1);
      expect(r.interlocks.single.relation, InterlockRelation.mutualExclusion);
      expect(r.warnings, isEmpty);
    });

    test('lead-lag (sequence, no alternation) over 3 pumps → 2 sequence interlocks', () {
      final r = computePumpGroup(
        const PumpGroupConfig(
          id: 'g2',
          name: 'Booster set',
          mode: PumpGroupMode.leadLag,
          trigger: PumpGroupTrigger.pressure,
        ),
        [member('p1', 'P1'), member('p2', 'P2'), member('p3', 'P3')],
      );
      // pressure controller only (no alternation for fixed lead-lag)
      expect(r.devices.where((d) => d.category == DeviceCategory.alternatorRelay),
          isEmpty);
      // 3 members in sequence → 2 staging interlocks
      expect(r.interlocks.length, 2);
      for (final il in r.interlocks) {
        expect(il.relation, InterlockRelation.sequence);
      }
    });

    test('warns when fewer than minPumps', () {
      final r = computePumpGroup(
        const PumpGroupConfig(
          id: 'g3',
          name: 'Lonely',
          mode: PumpGroupMode.parallel,
          trigger: PumpGroupTrigger.manual,
        ),
        [member('only', 'Only')],
      );
      expect(r.warnings.any((w) => w.contains('at least 2 pumps')), isTrue);
    });
  });
}
