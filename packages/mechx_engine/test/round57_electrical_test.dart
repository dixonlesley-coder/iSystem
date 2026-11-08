// Round 57 (2026-10-18) — electrical engine pin:
//
//   elec-convergence-9-vfd-softstart-motor-d-curve-forces-ads-copper — a
//     motor way's trip curve follows its EFFECTIVE starter: a VFD / soft
//     starter / star-delta limits the inrush, so the way takes a C-curve MCB
//     and its TN loop limit is the C one, never the DOL D curve's half.
//
// First principles (TN ADS, IEC 60364-4-41 411.3.2, a final <= 32 A judged at
// 0.4 s): Zs_max = 0.95 x U0 / (k x In), k = 10 (C) or 20 (D). A 32 A MCB:
// C 0.95 x 230 / 320 = 0.6828 ohm, D 0.95 x 230 / 640 = 0.3414 ohm. A 15 kW
// 3ph motor at 0.88 efficiency and cos phi 0.85 draws
// 15000 / 0.88 / (sqrt3 x 400 x 0.85) = 28.9 A -> the 32 A rung. A long way's
// loop is cable-dominated (Zs ~ L / csa), so the D limit forces roughly twice
// the copper the C limit does.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _plant(double lengthM, StarterType? starter,
        {LoadKind kind = LoadKind.motor, int phases = 3}) =>
    ElectricalProject(
      id: 'p',
      name: 'Plant',
      earthingSystem: EarthingSystem.tnS,
      transformerKva: const ApparentPower(630e3),
      panels: [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: const Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'm',
                  name: 'Conveyor',
                  loadKind: kind,
                  motorKw: 15,
                  phases: phases,
                  starterType: starter,
                  length: Length(lengthM)),
            ]),
      ],
    );

({double csa, String curve, bool raised, bool? adsOk, List<String> codes})
    _solve(double len, StarterType? starter) {
  final pr = _plant(len, starter);
  final fault = estimatedServiceFaultLevelA(pr)!;
  final sys = computeSystem(_profile, pr, originFaultLevel: fault);
  final w = sys.panels['MDP']!.circuits.single;
  final f = faultStudy(sys, pr, _profile, originFaultLevel: fault);
  return (
    csa: w.cable.csaMm2,
    curve: w.breaker.curve.name,
    raised: w.cableRaisedForAds,
    adsOk: f.circuits['m']!.adsOk,
    codes: [
      for (final x in [...sys.warnings, ...f.warnings])
        if (x.circuitId == 'm') x.code,
    ],
  );
}

void main() {
  group('breakerCurveFor', () {
    test('inrush-limiting starters take C on motor-like kinds only', () {
      for (final k in [LoadKind.motor, LoadKind.pump, LoadKind.hvac]) {
        for (final s in [
          StarterType.vfd,
          StarterType.softStarter,
          StarterType.starDelta,
        ]) {
          expect(breakerCurveFor(k, s), BreakerCurve.c, reason: '$k $s');
        }
        for (final s in [
          null,
          StarterType.dol,
          StarterType.reversing,
          StarterType.pump,
        ]) {
          expect(breakerCurveFor(k, s), loadDefaults[k]!.curve,
              reason: '$k $s');
        }
      }
      // A non-motor kind keeps its own curve whatever starter it carries.
      expect(breakerCurveFor(LoadKind.lighting, StarterType.vfd),
          loadDefaults[LoadKind.lighting]!.curve);
      expect(
          breakerCurveFor(LoadKind.welding, StarterType.vfd), BreakerCurve.d);
    });
  });

  group('elec-convergence-9 VFD / soft-start motor ways', () {
    test('a 15 kW VFD way at 120 m: C32, 10 mm2, passes ADS ungrown', () {
      final v = _solve(120, StarterType.vfd);
      expect(v.curve, 'c');
      expect(v.csa, 10);
      expect(v.raised, isFalse);
      expect(v.adsOk, isTrue);
      // The same way started DOL keeps the D curve and grows its copper to
      // meet the 0.3414 ohm limit (the Round-56 ladder).
      final d = _solve(120, StarterType.dol);
      expect(d.curve, 'd');
      expect(d.csa, greaterThan(v.csa));
      expect(d.raised, isTrue);
    });

    test('a 160 m VFD way grows only to the C limit and passes', () {
      final v = _solve(160, StarterType.vfd);
      expect(v.curve, 'c');
      expect(v.adsOk, isTrue);
      expect(v.codes, isNot(contains('ads-disconnection')));
      // D at the same length cannot reach 0.3414 ohm within the bounded
      // ladder; C (0.6828 ohm) needs at most one rung more than 10 mm2.
      expect(v.csa, lessThanOrEqualTo(16));
    });

    test('a star-delta on a 1ph way is DOL: the D curve stays', () {
      final pr = _plant(40, StarterType.starDelta, phases: 1);
      final sys = computeSystem(_profile, pr,
          originFaultLevel: estimatedServiceFaultLevelA(pr));
      expect(sys.panels['MDP']!.circuits.single.breaker.curve, BreakerCurve.d);
    });

    test(
        'seeded property: a C-curve (inrush-limited) way never carries more '
        'copper than the same way DOL, and never fails ADS where DOL passes',
        () {
      final rnd = math.Random(5703);
      for (var t = 0; t < 60; t++) {
        final len = 10 + rnd.nextDouble() * 200;
        final starter = [
          StarterType.vfd,
          StarterType.softStarter,
          StarterType.starDelta,
        ][rnd.nextInt(3)];
        final c = _solve(len, starter);
        final d = _solve(len, StarterType.dol);
        expect(c.curve, 'c', reason: 'trial $t');
        // A star-delta way's field run is its two motor-lead cables (a
        // different conductor from the DOL way's, judged on the lead loop),
        // so only its curve is compared. Where DOL exhausts its ladder it
        // reverts to the load-sized cable with an error, so copper is
        // compared only where DOL passes.
        if (starter != StarterType.starDelta && d.adsOk == true) {
          expect(c.adsOk, isNot(isFalse), reason: 'trial $t $len m');
          expect(c.csa, lessThanOrEqualTo(d.csa), reason: 'trial $t $len m');
        }
      }
    });
  });
}
