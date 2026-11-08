// Round 56 (2026-10-18) — electrical engine pins:
//
//   regression-ads-fail-both-classes-no-csa-growth — a final way failing ADS
//     as both MCB and MCCB grows its conductor (bounded) to the first rung
//     that disconnects in time; the ladder exhausted keeps the Round-55
//     reading (load-sized cable, MCCB, one ads-disconnection error).
//   regression-alternator-floor-all-lines-at-1ph-machine — the largest-machine
//     floor on the alternator lines loads only the lines that machine uses.
//   elec-convergence-8-ads-never-judged-on-standby-genset-source — genset-
//     backed ways are judged on the alternator fault too.
//   elec-convergence-8-enclosure-thermal-fail-silent-and-priced — the IEC
//     60890 rise verdict is surfaced and the BOM line names it.
//
// First principles:
//  * TN ADS limit Zs <= 0.95 x U0 / (k x In): a B6 MCB (k = 5) 0.95 x 230 /
//    30 = 7.283 ohm; a 16 A MCCB at the 10 x In magnetic multiple 0.95 x 230
//    / 160 = 1.366 ohm. A long final way's loop is cable-dominated, Zs ~ L /
//    csa, so 450 m of 2.5 mm2 (10.22 ohm) becomes ~10.22 x 2.5 / 4 = 6.39
//    ohm at 4 mm2 — under the B6 limit.
//  * Alternator sub-transient fault Isc = S / (sqrt3 x 400 x Xd''), Xd'' 0.12:
//    200 kVA -> 2405.6 A, a source impedance 230 / 2405.6 = 0.0956 ohm on the
//    U0 loop vs the 1600 kVA / 4 % transformer's 230 / 57 735 = 0.0040 ohm.
//  * A 1φ machine of I amperes loads one alternator line with I; floored on
//    all three lines it was counted 3 x I per line over three boards.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/catalog.dart' show PartCategory;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _hotel(double lengthM,
        {double loadW = 300, double? cableMm2}) =>
    ElectricalProject(
      id: 'h',
      name: 'Hotel',
      earthingSystem: EarthingSystem.tnS,
      transformerKva: const ApparentPower(1600e3),
      panels: [
        const ElectricalPanel(
            id: 'LV',
            name: 'LVMDP',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'f',
                  name: 'SDP-E feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(15),
                  cableOverrideMm2: 300,
                  feedsPanelId: 'SDP'),
            ]),
        ElectricalPanel(
            id: 'SDP',
            name: 'SDP-E',
            voltage: const Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'el',
                  name: 'Emergency lighting',
                  loadKind: LoadKind.lighting,
                  loadW: loadW,
                  phases: 1,
                  lifeSafety: true,
                  cableOverrideMm2: cableMm2,
                  length: Length(lengthM)),
            ]),
      ],
    );

ElectricalProject _mall(double fireLen, {bool genset = true}) =>
    ElectricalProject(
      id: 'm',
      name: 'Mall',
      earthingSystem: EarthingSystem.tnS,
      transformerKva: const ApparentPower(1600e3),
      sources: genset
          ? const ElectricalSources(
              generator: GeneratorSource(kva: ApparentPower(200e3)))
          : null,
      panels: [
        const ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'f',
                  name: 'PP-ESS feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(50),
                  cableOverrideMm2: 150,
                  feedsPanelId: 'ESS'),
            ]),
        ElectricalPanel(
            id: 'ESS',
            name: 'PP-ESS',
            essential: true,
            voltage: const Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'fp',
                  name: 'Fire pump',
                  loadKind: LoadKind.pump,
                  motorKw: 75,
                  phases: 3,
                  lifeSafety: true,
                  length: Length(fireLen)),
            ]),
      ],
    );

void main() {
  group('regression-ads-fail-both-classes-no-csa-growth', () {
    test('the 450 m way grows to 4 mm2 on a B6 MCB and passes ADS', () {
      final pr = _hotel(450);
      final fault = estimatedServiceFaultLevelA(pr)!;
      final sys = computeSystem(_profile, pr, originFaultLevel: fault);
      final w = sys.panels['SDP']!.circuits.single;
      final f = faultStudy(sys, pr, _profile, originFaultLevel: fault);
      expect(w.cable.csaMm2, 4);
      expect(w.cableRaisedForAds, isTrue);
      expect(w.breaker.deviceClass, BreakerClass.mcb);
      expect(w.breaker.ratingA.amperes, 6);
      expect(f.circuits['el']!.adsOk, isTrue);
      expect(f.circuits['el']!.zsOhm!, lessThan(0.95 * 230 / (5 * 6)));
      // The load alone sizes 2.5 mm2 (the cable override pins it there):
      // Zs 2.5 / Zs 4 ~ 4 / 2.5 = 1.6 (cable-dominated loop).
      final pinned = computeSystem(_profile, _hotel(450, cableMm2: 2.5),
          originFaultLevel: fault);
      final fp = faultStudy(pinned, pr, _profile, originFaultLevel: fault);
      expect(fp.circuits['el']!.adsOk, isFalse);
      expect(fp.circuits['el']!.zsOhm! / f.circuits['el']!.zsOhm!,
          closeTo(1.6, 0.02));
      // No user override is claimed: the info names the engine floor.
      expect(
          sys.warnings.where((x) =>
              x.code == 'cable-raised-for-ads' && x.circuitId == 'el'),
          hasLength(1));
    });

    test('TT / passing ways are untouched (no floor, no info)', () {
      final pr = _hotel(60, loadW: 300);
      final sys = computeSystem(_profile, pr,
          originFaultLevel: estimatedServiceFaultLevelA(pr));
      expect(sys.panels['SDP']!.circuits.single.cableRaisedForAds, isFalse);
      expect(sys.warnings.map((w) => w.code),
          isNot(contains('cable-raised-for-ads')));
    });

    test(
        'seeded property: every final way either passes ADS, or keeps its '
        'load-sized cable with the error (the bounded ladder exhausted); a '
        'grown cable is the FIRST passing rung', () {
      final rnd = math.Random(5602);
      final sections = _profile.standardSectionsMm2;
      for (var t = 0; t < 120; t++) {
        final len = 20 + rnd.nextDouble() * 3500;
        final loadW = 100 + rnd.nextDouble() * 1500;
        final pr = _hotel(len, loadW: loadW);
        final fault = estimatedServiceFaultLevelA(pr)!;
        final sys = computeSystem(_profile, pr, originFaultLevel: fault);
        final w = sys.panels['SDP']!.circuits.single;
        final f = faultStudy(sys, pr, _profile, originFaultLevel: fault);
        final ok = f.circuits['el']!.adsOk != false;
        if (w.cableRaisedForAds) {
          expect(ok, isTrue, reason: 'trial $t ($len m): grown but failing');
          expect(w.cable.csaMm2, lessThanOrEqualTo(kAdsCsaGrowthMaxMm2));
          // One rung lower (pinned as an override, which disables growth)
          // fails: the growth stops at the first passing rung.
          final below = sections.lastWhere((x) => x < w.cable.csaMm2 - 1e-9);
          final pinned = _hotel(len, loadW: loadW, cableMm2: below);
          final s2 = computeSystem(_profile, pinned, originFaultLevel: fault);
          final f2 = faultStudy(s2, pinned, _profile, originFaultLevel: fault);
          if (s2.panels['SDP']!.circuits.single.cable.csaMm2 == below) {
            expect(f2.circuits['el']!.adsOk, isFalse,
                reason: 'trial $t: $below mm2 already passed');
          }
        } else if (!ok) {
          // Exhausted (or never growable): the Round-55 single defect.
          final codes = [
            for (final x in f.warnings)
              if (x.circuitId == 'el') x.code,
          ];
          expect(codes.where((c) => c == 'ads-disconnection'), hasLength(1),
              reason: 'trial $t');
        }
      }
    });
  });

  group('regression-alternator-floor-all-lines-at-1ph-machine', () {
    // MDP feeding three essential 3φ boards A / B / C; each holds one 1φ 3 kW
    // pump (Ib 3000 / (0.88 x 230 x 0.85) ~ 17.4 A) and two 400 W lighting
    // ways (~2 A). The balance spreads the three pumps over L1 / L2 / L3.
    ElectricalProject three({bool threePhasePump = false}) => ElectricalProject(
          id: 'g',
          name: 'G',
          earthingSystem: EarthingSystem.tnS,
          sources: const ElectricalSources(
              generator: GeneratorSource(backupFraction: 0)),
          panels: [
            ElectricalPanel(
                id: 'MDP',
                name: 'MDP',
                voltage: const Voltage(400),
                circuits: [
                  for (final b in ['A', 'B', 'C'])
                    ElectricalCircuit(
                        id: 'f$b',
                        name: 'Feeder $b',
                        loadKind: LoadKind.feeder,
                        length: const Length(20),
                        feedsPanelId: b),
                ]),
            for (final b in ['A', 'B', 'C'])
              ElectricalPanel(
                  id: b,
                  name: 'DB-$b',
                  essential: true,
                  voltage: const Voltage(400),
                  circuits: [
                    ElectricalCircuit(
                        id: 'p$b',
                        name: 'Pump $b',
                        loadKind: LoadKind.pump,
                        motorKw: 3,
                        phases: threePhasePump ? 3 : 1,
                        length: const Length(15)),
                    for (var k = 0; k < 2; k++)
                      ElectricalCircuit(
                          id: 'l$b$k',
                          name: 'Lighting $b$k',
                          loadKind: LoadKind.lighting,
                          loadW: 400,
                          phases: 1,
                          length: const Length(15)),
                  ]),
          ],
        );

    test(
        'three 1φ pumps on L1 / L2 / L3: the floor adds nothing (the real '
        'lines already carry each pump), never 3 x 17.4 A per line', () {
      final pr = three();
      final sys = computeSystem(_profile, pr);
      final ids = ['A', 'B', 'C'];
      final plain = alternatorLineDemandVa(pr, sys, ids);
      final floored =
          alternatorLineDemandVa(pr, sys, ids, withLargestMachine: true);
      expect(floored, closeTo(plain, 1e-6));
      // Each board's machine vector loads only its pump's line.
      for (final b in ids) {
        final r = sys.panels[b]!;
        final v = r.largestDownstreamRunLinesA!;
        expect(v.where((x) => x > 0), hasLength(1), reason: b);
        expect(v.reduce(math.max), closeTo(r.largestDownstreamRunA, 1e-9));
      }
      // The old all-lines floor: 3 boards x the pump current on every line.
      final pump = sys.panels['A']!.largestDownstreamRunA;
      final oldVa = math.sqrt(3) * 400 * 3 * pump;
      expect(floored, lessThan(oldVa * 0.6));
    });

    test('a 3φ machine still floors all three lines', () {
      final pr = three(threePhasePump: true);
      final sys = computeSystem(_profile, pr);
      for (final b in ['A', 'B', 'C']) {
        final r = sys.panels[b]!;
        final v = r.largestDownstreamRunLinesA!;
        expect(v[0], closeTo(r.largestDownstreamRunA, 1e-9));
        expect(v[1], closeTo(r.largestDownstreamRunA, 1e-9));
        expect(v[2], closeTo(r.largestDownstreamRunA, 1e-9));
      }
      // The floor never lowers the demand.
      expect(
          alternatorLineDemandVa(pr, sys, ['A', 'B', 'C'],
              withLargestMachine: true),
          greaterThanOrEqualTo(
              alternatorLineDemandVa(pr, sys, ['A', 'B', 'C']) - 1e-6));
    });

    test('the MDP carries its fed boards\' machine on the feeder line', () {
      final pr = three();
      final sys = computeSystem(_profile, pr);
      final mdp = sys.panels['MDP']!;
      // A 3φ feeder carries the fed board's vector verbatim: one line.
      expect(mdp.largestDownstreamRunLinesA!.where((x) => x > 0),
          hasLength(1));
    });
  });

  group('elec-convergence-8-ads-never-judged-on-standby-genset-source', () {
    test(
        'a 60 m fire-pump way passes ADS on the utility and fails on the '
        '200 kVA genset: one ads-disconnection-on-genset error', () {
      final pr = _mall(60);
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      final u = st.fault.circuits['fp']!;
      expect(u.adsOk, isTrue);
      // Isc = 200e3 / (sqrt3 x 400 x 0.12) = 2405.6 A.
      final isc = onSiteSourceFaultA(SupplyKind.generator, 200e3);
      expect(isc, closeTo(200e3 / (math.sqrt(3) * 400 * 0.12), 1e-6));
      expect(isc, closeTo(2405.6, 0.1));
      final g = faultStudy(sys, pr, _profile, originFaultLevel: Current(isc));
      expect(g.circuits['fp']!.adsOk, isFalse);
      expect(g.circuits['fp']!.zsOhm!, greaterThan(u.zsOhm!));
      expect(st.gensetAdsFailedCircuitIds, {'fp'});
      expect(st.adsFailedCircuitIds, contains('fp'));
      final errs = [
        for (final w in st.warnings)
          if (w.code == 'ads-disconnection-on-genset') w,
      ];
      expect(errs, hasLength(1));
      expect(errs.single.severity, WarningSeverity.error);
      expect(errs.single.circuitId, 'fp');
      expect(errs.single.message, contains('200 kVA'));
      expect(st.verifyItems, contains(gensetSustainedFaultVerifyItem));
    });

    test('no genset, a short way, or a utility failure: nothing new', () {
      for (final (len, gen) in [(60.0, false), (20.0, true), (140.0, true)]) {
        final pr = _mall(len, genset: gen);
        final st =
            computeAdvancedStudy(_profile, pr, computeSystem(_profile, pr));
        expect(st.gensetAdsFailedCircuitIds, isEmpty, reason: '$len $gen');
        expect(st.warnings.map((w) => w.code),
            isNot(contains('ads-disconnection-on-genset')));
      }
      final st = computeAdvancedStudy(
          _profile, _mall(60, genset: false), computeSystem(_profile, _mall(60, genset: false)));
      expect(st.verifyItems, isNot(contains(gensetSustainedFaultVerifyItem)));
    });
  });

  group('elec-convergence-8-enclosure-thermal-fail-silent-and-priced', () {
    test(
        'a board whose IEC 60890 rise exceeds 35 K raises the warning and '
        'its BOM enclosure line names the rise; a cool board is unchanged',
        () {
      final pr = _mall(60, genset: false);
      final sys = computeSystem(_profile, pr);
      final st = computeAdvancedStudy(_profile, pr, sys);
      final hot = st.enclosure['ESS']!;
      final cool = st.enclosure['MDP']!;
      expect(hot.withinTempLimit, isFalse);
      expect(hot.tempRiseK, greaterThan(35));
      expect(cool.withinTempLimit, isTrue);
      final w = [
        for (final x in st.warnings)
          if (x.code == 'enclosure-temp-rise-exceeded') x,
      ];
      expect(w.map((x) => x.panelId), ['ESS']);
      expect(w.single.severity, WarningSeverity.warning);
      final lines = [
        for (final l in st.bom.lines)
          if (l.category == PartCategory.enclosure) l.description,
      ];
      expect(
          lines.where((d) =>
              d.contains('(temp rise ${hot.tempRiseK.toStringAsFixed(0)} K '
                  '> 35 K, verify)')),
          hasLength(1));
      expect(lines.where((d) => !d.contains('temp rise')), hasLength(1));
    });
  });

  test('ElectricalCircuitResult.copyWith keeps cableRaisedForAds', () {
    final pr = _hotel(450);
    final sys = computeSystem(_profile, pr,
        originFaultLevel: estimatedServiceFaultLevelA(pr));
    final w = sys.panels['SDP']!.circuits.single;
    expect(w.copyWith(cumulativeDropPercent: 1).cableRaisedForAds, isTrue);
    expect(w, isA<ElectricalCircuitResult>());
  });
}
