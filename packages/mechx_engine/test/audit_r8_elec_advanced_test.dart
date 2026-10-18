/// Audit round 8 — advanced electrical study honesty fixes.
///
///   r8-1  harmonics: a VFD way is counted ADDITIVELY with the UPS/welding
///         share (adding non-linear load can never lower the fraction).
///   r8-2  enclosure heat includes the load-dependent breaker + busbar I²R, so
///         the temperature rise grows with load.
///   r8-3  recommendedDayaVa is always ≥ demand (null beyond the LV ladder).
///   r8-4  battery / PV inverters beyond 250 kW are paralleled units.
///   r8-5  genset / transformer / capacitor / CT ladders flag saturation.
///   r8-6  E > 0.98 is flagged as beyond what a level-I LPS provides.
///
/// Expected values are derived from first principles in the comments.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/enclosure.dart';
import 'package:mechx_engine/electrical/lightning.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/metering.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _project(List<ElectricalCircuit> circuits) =>
    ElectricalProject(
      id: 'p',
      name: 'r8',
      earthingSystem: EarthingSystem.tnCs,
      panels: [
        ElectricalPanel(
          id: 'mdp',
          name: 'MDP',
          voltage: const Voltage(400),
          circuits: circuits,
        ),
      ],
    );

ElectricalCircuit _ups(int i, double w, {bool threePhase = false}) =>
    ElectricalCircuit(
      id: 'ups$i',
      name: 'UPS $i',
      loadKind: LoadKind.ups,
      loadW: w,
      cosPhi: 0.9,
      phases: threePhase ? 3 : 1,
      length: const Length(15),
    );

ElectricalCircuit _light(int i, double w) => ElectricalCircuit(
      id: 'lt$i',
      name: 'Lighting $i',
      loadKind: LoadKind.lighting,
      isLighting: true,
      loadW: w,
      cosPhi: 0.9,
      length: const Length(15),
    );

ElectricalCircuit _vfd(String id, double kw) => ElectricalCircuit(
      id: id,
      name: 'Pump $id',
      loadKind: LoadKind.pump,
      motorKw: kw,
      cosPhi: 0.85,
      length: const Length(20),
      starterType: StarterType.vfd,
    );

double _nl(List<ElectricalCircuit> cs) {
  final p = _project(cs);
  final sys = computeSystem(_profile, p);
  final h = computeAdvancedStudy(_profile, p, sys).harmonics['mdp'];
  return h?.nonLinearFraction ?? 0;
}

void main() {
  group('r8-1 harmonics — VFD share is additive', () {
    test('UPS board + one VFD: fraction = (ΣIb_ups + Ib_vfd) / ΣIb', () {
      final base = [
        for (var i = 0; i < 6; i++) _ups(i, 3000),
        _light(0, 2000),
        _light(1, 2000),
      ];
      final withVfd = [...base, _vfd('vfd', 1.5)];
      final p = _project(withVfd);
      final sys = computeSystem(_profile, p);
      // First principles: the design-current-weighted share of every
      // non-linear way (6 UPS + the drive-fed pump) over all ways.
      var nl = 0.0, total = 0.0;
      for (final c in sys.panels['mdp']!.circuits) {
        final a = c.designCurrent.amperes;
        total += a;
        if (c.loadKind == LoadKind.ups || c.circuitId == 'vfd') nl += a;
      }
      final h = computeAdvancedStudy(_profile, p, sys).harmonics['mdp']!;
      expect(h.nonLinearFraction, closeTo(nl / total, 1e-3));
      // Before the fix the drive OVERRODE the share (vfd/total ≈ 0.08).
      expect(h.nonLinearFraction, greaterThanOrEqualTo(_nl(base) - 1e-9));
      expect(h.nonLinearFraction, greaterThan(0.75));
      // The 1φ UPS share keeps the neutral-oversize verdict.
      expect(h.singlePhaseFraction, greaterThan(0.5));
    });

    test('property (seeded): adding a VFD never lowers the non-linear share',
        () {
      final rng = math.Random(8);
      for (var trial = 0; trial < 25; trial++) {
        final cs = <ElectricalCircuit>[
          for (var i = 0; i < 1 + rng.nextInt(5); i++)
            _ups(i, 500 + rng.nextDouble() * 4000,
                threePhase: rng.nextBool()),
          for (var i = 0; i < rng.nextInt(5); i++)
            _light(i, 300 + rng.nextDouble() * 2500),
        ];
        final before = _nl(cs);
        final after = _nl([...cs, _vfd('v$trial', 0.75 + rng.nextDouble() * 7)]);
        expect(after, greaterThanOrEqualTo(before - 1e-3),
            reason: 'trial $trial: $before -> $after');
      }
    });
  });

  group('r8-2 enclosure heat grows with load', () {
    ElectricalProject board(int ways, double kw) => _project([
          for (var i = 0; i < ways; i++)
            ElectricalCircuit(
              id: 'm$i',
              name: 'Load $i',
              loadKind: LoadKind.heating,
              loadW: kw * 1000,
              cosPhi: 1.0,
              phases: 3,
              length: const Length(10),
            ),
        ]);

    test('switchgearLossW is the hand formula over the sized result', () {
      final p = board(4, 10);
      final pr = computeSystem(_profile, p).panels['mdp']!;
      // Σ (Ib/In)²·P_pole·poles over ways + the incomer + busbar I²R.
      var expected = 0.0;
      for (final c in pr.circuits) {
        final r = c.designCurrent.amperes / c.breaker.ratingA.amperes;
        final pp = c.breaker.deviceClass == BreakerClass.mccb
            ? mccbLossPerPoleW
            : mcbLossPerPoleW;
        expected += r * r * pp * 3;
      }
      final inc = pr.incomer;
      final ri = pr.demandCurrent.amperes / inc.breaker.ratingA.amperes;
      expected += ri *
          ri *
          (inc.breaker.deviceClass == BreakerClass.mccb
              ? mccbLossPerPoleW
              : mcbLossPerPoleW) *
          inc.poles;
      final modules = estimatePanelModules(pr);
      final rows = math.max(1, (modules / modulesPerRow).ceil());
      final lM = ((rows * dinRowPitchMm + enclosureVerticalMarginMm) / 50)
              .ceil() *
          50 /
          1000;
      final i = pr.demandCurrent.amperes;
      expected += (inc.poles >= 3 ? 3 : 2) *
          i *
          i *
          copperResistivityOhmM *
          lM /
          (pr.busbar.csaMm2 * 1e-6);
      expect(switchgearLossW(pr), closeTo(expected, 1e-9));
    });

    test('a heavily loaded big board no longer passes at a tiny rise', () {
      // 20 × 30 kW 3φ ways (Ib ≈ 43 A each, ~870 A demand): each MCCB pole
      // loses ~(Ib/In)²·15 W, the incomer + busbar add tens to ~100 W —
      // hundreds of watts in all ⇒ not "natural" ventilation (< 50 W).
      final big = board(20, 30);
      final small = board(1, 0.4);
      final sb = computeSystem(_profile, big);
      final ss = computeSystem(_profile, small);
      final eb = computeAdvancedStudy(_profile, big, sb).enclosure['mdp']!;
      final es = computeAdvancedStudy(_profile, small, ss).enclosure['mdp']!;
      expect(switchgearLossW(sb.panels['mdp']!), greaterThan(200));
      expect(eb.ventilation, isNot(Ventilation.natural));
      expect(eb.tempRiseK, greaterThan(es.tempRiseK));
    });

    test('property (seeded): loss is monotone in load on a fixed board', () {
      final rng = math.Random(28);
      for (var t = 0; t < 10; t++) {
        final ways = 1 + rng.nextInt(8);
        final kw = 1 + rng.nextDouble() * 10;
        final lo = computeSystem(_profile, board(ways, kw)).panels['mdp']!;
        final hi =
            computeSystem(_profile, board(ways, kw * 1.5)).panels['mdp']!;
        // Larger devices may be picked at the higher load, so compare against
        // the hand floor: the higher load never DISSIPATES less in the busbar
        // conductor path of the same CSA, and the total stays positive.
        expect(switchgearLossW(hi), greaterThan(0));
        expect(switchgearLossW(lo), greaterThan(0));
        if (hi.busbar.csaMm2 == lo.busbar.csaMm2 &&
            hi.incomer.breaker.ratingA.amperes ==
                lo.incomer.breaker.ratingA.amperes &&
            [for (final c in hi.circuits) c.breaker.ratingA.amperes]
                    .join(',') ==
                [for (final c in lo.circuits) c.breaker.ratingA.amperes]
                    .join(',')) {
          expect(switchgearLossW(hi), greaterThan(switchgearLossW(lo)));
        }
      }
    });
  });

  group('r8-4 inverters beyond the largest rung are paralleled', () {
    test('1.2 MW critical load ⇒ ceil(1200/250) = 5 × 250 kW', () {
      final b = sizeBattery(Power.kiloWatts(1200), autonomyHours: 0.25);
      expect(b.inverterUnits, 5);
      expect(b.inverterKw.inKiloWatts, 250);
      expect(b.inverterKw.inKiloWatts * b.inverterUnits,
          greaterThanOrEqualTo(1200));
      expect(b.note, contains('5 x 250 kW'));
    });

    test('one-line: 1500 kVA × 0.8 = 1200 kW battery ⇒ "5 x 250 kW"', () {
      final ol = buildPowerOneLine(
        const ElectricalSources(battery: BatterySource(autonomyHours: 0.25)),
        demand: ApparentPower.kilovoltAmperes(1500),
      );
      final inv = ol.nodes.firstWhere((n) => n.id == 'battinv');
      expect(inv.sub, '5 x 250 kW');
    });

    test('within the ladder: one unit, label unchanged', () {
      final b = sizeBattery(Power.kiloWatts(12), autonomyHours: 2);
      expect(b.inverterUnits, 1);
      expect(b.inverterKw.inKiloWatts, 15);
      expect(b.note, contains('15 kW inverter/charger'));
    });
  });

  group('r8-5 saturating ladders are flagged', () {
    test('genset 3200 kVA ⇒ ceil(3200/2500) = 2 × 2500 kVA', () {
      final g = sizeGenerator(ApparentPower.kilovoltAmperes(3200));
      expect(g.units, 2);
      expect(g.ladderExceeded, isTrue);
      expect(g.ratingKva.inKilovoltAmperes * g.units, greaterThanOrEqualTo(3200));
      expect(g.note, contains('2 x 2500 kVA'));
      expect(sizeGenerator(ApparentPower.kilovoltAmperes(400)).units, 1);
    });

    test('transformer: 3 MVA / 0.8 = 3750 kVA ⇒ 2 × 2500 kVA', () {
      final s = determineSupply(ApparentPower.kilovoltAmperes(3000));
      expect(s.ladderExceeded, isTrue);
      expect(s.units, 2);
      expect(s.transformerKva, 2500);
      // Loading per unit = 3000 / (2·2500) = 60 % ≤ the 80 % basis.
      expect(3000 / (s.units * s.transformerKva!),
          lessThanOrEqualTo(transformerLoadingFactor));
      expect(s.note, contains('2 x 2500 kVA'));
    });

    test('CT: 2887 A > 2500 A top primary ⇒ flagged', () {
      final m = meterFor(const Current(2887));
      expect(m.ladderExceeded, isTrue);
      expect(m.note, contains('special-ratio CT'));
      expect(meterFor(const Current(900)).ladderExceeded, isFalse);
    });

    test('capacitor: 20 × 100 kW @ pf 0.7 ⇒ 1383 kVAR ⇒ 2 × 1000 kVAR', () {
      // requiredKvar = 2000·(tanφ1 − tanφ2) = 2000·(1.020204 − 0.328684)
      //              = 1383.04 kVAR > the 1000 kVAR top bank ⇒ 2 banks.
      final project = ElectricalProject(
        id: 'P',
        name: 'PF',
        earthingSystem: EarthingSystem.tnCs,
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: const Voltage(400),
            ambientTempC: 30,
            circuits: [
              for (var i = 0; i < 20; i++)
                ElectricalCircuit(
                  id: 'w$i',
                  name: 'Welder $i',
                  loadKind: LoadKind.welding,
                  loadW: 100000,
                  cosPhi: 0.7,
                  length: const Length(10),
                ),
            ],
          ),
        ],
      );
      final r = powerFactorCorrection(computeSystem(_profile, project), project);
      expect(r.requiredKvar, closeTo(1383.0, 0.5));
      expect(r.banks, 2);
      expect(r.bankKvar, 2000);
      expect(r.bankKvar, greaterThanOrEqualTo(r.requiredKvar));
      expect(r.note, contains('2 x 1000 kVAR'));
    });
  });

  group('r8-6 lightning E above level I', () {
    test('30×20×20 m, Ng 12 ⇒ E = 0.995 > 0.98 ⇒ beyondLevelI', () {
      // Ad = 600 + 2·60·50 + π·60² = 17 909.7 m²; Nd = 12·0.0179097 = 0.21492;
      // E = 1 − 0.001/0.21492 = 0.99535.
      final ad = collectionArea(30, 20, 20);
      expect(ad, closeTo(600 + 6000 + math.pi * 3600, 1e-6));
      final r = assessLightning(groundFlashDensity: 12, areaM2: ad);
      expect(r.efficiency, closeTo(0.995, 1e-3));
      expect(r.level, LpsLevel.i);
      expect(r.beyondLevelI, isTrue);
      expect(r.note, contains('does not reach'));
    });

    test('10×10×5 m ⇒ E = 0.941 ⇒ level II, not flagged', () {
      // Ad = 100 + 2·15·20 + π·225 = 1406.86; Nd = 0.016882; E = 0.9408.
      final r = assessLightning(
          groundFlashDensity: 12, areaM2: collectionArea(10, 10, 5));
      expect(r.efficiency, closeTo(0.941, 1e-3));
      expect(r.level, LpsLevel.ii);
      expect(r.beyondLevelI, isFalse);
    });
  });

  group('r8-3 daya is never below demand', () {
    test('2 MVA project: no LV daya (null)', () {
      expect(recommendedDayaVa(ApparentPower.kilovoltAmperes(2000),
          ElectricalSystem.threePhase), isNull);
    });
  });
}
