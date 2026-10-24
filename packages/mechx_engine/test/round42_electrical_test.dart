// Round 42 (2026-10-18) — motor control gear, star-delta field run, genset
// start basis, large-service honesty.
//
// Each group pins one confirmed finding with a first-principles derivation;
// where a counterexample generalises it is a seeded property.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/containment.dart';
import 'package:mechx_engine/electrical/control/contactor.dart';
import 'package:mechx_engine/electrical/control/motor_flc.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/control/starting.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalProject _board(List<ElectricalCircuit> circuits,
        {ElectricalSystem system = ElectricalSystem.threePhase,
        double volts = 400}) =>
    ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: system,
          voltage: Voltage(volts),
          circuits: circuits),
    ]);

ElectricalCircuit _motor(String id, double kw,
        {StarterType? starter,
        int phases = 3,
        String? cable,
        double lengthM = 30,
        LoadKind kind = LoadKind.motor}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: kind,
      motorKw: kw,
      cosPhi: 0.85,
      phases: phases,
      starterType: starter,
      cableType: cable,
      length: Length(lengthM),
    );

ElectricalCircuitResult _way(ElectricalSystemResult s, String id) =>
    s.panels['MDP']!.circuits.firstWhere((r) => r.circuitId == id);

List<String> _labels(ElectricalProject pr, ElectricalSystemResult sys) =>
    buildElectricalSld(project: pr, result: sys)
        .prims
        .whereType<SldLabel>()
        .map((l) => l.text)
        .toList();

void main() {
  // ── 1. motor FLC above 250 kW ────────────────────────────────────────────
  group('elec-props-8-motor-flc-clamps-above-250kw', () {
    test('seeded property: FLC is non-decreasing in kW and scales above '
        'the table (never clamps)', () {
      final rng = math.Random(4242);
      final kws = [for (var i = 0; i < 300; i++) 0.2 + rng.nextDouble() * 600]
        ..sort();
      var prev = 0.0;
      for (final kw in kws) {
        final f = motorFlc(kw).amperes;
        expect(f + 1e-9, greaterThanOrEqualTo(prev), reason: '$kw kW');
        prev = f;
      }
      // 400 kW: 545 x 400 / 315 = 692.06 A (a clamp would print 545 A).
      expect(motorFlc(400).amperes, closeTo(545 * 400 / 315, 1e-9));
      expect(motorFlc(280).amperes, 490);
    });

    test('315 kW DOL pump: every contactor + the overload >= the solved Ib',
        () {
      // Ib = 315 000 / 0.88 / (√3 · 400 · 0.85) = 607.8 A (> the 545 A
      // table FLC — the gear sizes on the larger).
      final pr = _board([
        _motor('p', 315, starter: StarterType.dol, kind: LoadKind.pump),
      ]);
      final sys = computeSystem(_p, pr);
      final ib = _way(sys, 'p').runCurrentA.amperes;
      expect(ib, closeTo(315000 / 0.88 / (math.sqrt(3) * 400 * 0.85), 0.1));
      final a = computeAdvancedStudy(_p, pr, sys).controlAssemblies['p']!;
      expect(a.motor!.flcA.amperes, closeTo(ib, 0.05));
      for (final d in a.devices
          .where((d) => d.category == DeviceCategory.contactor)) {
        final frame = double.parse(d.rating!.split(' ').first);
        expect(frame, greaterThanOrEqualTo(ib), reason: d.rating);
      }
      final ol =
          a.devices.firstWhere((d) => d.category == DeviceCategory.overloadRelay);
      expect(ol.targetRatingA!.amperes, closeTo(ib, 0.05));
    });

    test('a table FLC above 315 kW is flagged on the assembly', () {
      final a = applyStarterTemplate(
          circuitId: 'x', starterType: StarterType.dol, motorKw: 400);
      expect(a.warnings.any((w) => w.contains('extrapolated')), isTrue);
      final b = applyStarterTemplate(
          circuitId: 'x', starterType: StarterType.dol, motorKw: 250);
      expect(b.warnings.any((w) => w.contains('extrapolated')), isFalse);
    });
  });

  // ── 2. control gear basis vs the schedule Ib ─────────────────────────────
  group('elec-props-8-control-gear-flc-basis-below-schedule-ib', () {
    test('seeded property: no contactor below its role fraction x the '
        'printed Ib; the overload is the basis x its leg factor', () {
      final rng = math.Random(4243);
      const starters = [
        StarterType.dol,
        StarterType.starDelta,
        StarterType.reversing,
        StarterType.softStarter,
      ];
      for (var t = 0; t < 60; t++) {
        final kw = 4 + rng.nextDouble() * 300;
        final st = starters[rng.nextInt(starters.length)];
        final pr = _board([_motor('m', kw, starter: st)]);
        final sys = computeSystem(_p, pr);
        final ib = _way(sys, 'm').runCurrentA.amperes;
        final a = computeAdvancedStudy(_p, pr, sys).controlAssemblies['m']!;
        // basis = max(table FLC, Ib) — never below the printed Ib.
        final basis = math.max(motorFlc(kw).amperes, ib);
        expect(a.motor!.flcA.amperes, closeTo(basis, 0.05),
            reason: '$kw kW $st');
        for (final d in a.devices
            .where((d) => d.category == DeviceCategory.contactor)) {
          final frame = double.parse(d.rating!.split(' ').first);
          final fraction = d.role == 'star-contactor'
              ? 1 / 3
              : (st == StarterType.starDelta ? starDeltaWindingFactor : 1.0);
          expect(frame + 0.05, greaterThanOrEqualTo(fraction * ib),
              reason: '$kw kW $st ${d.role}');
        }
        for (final d in a.devices
            .where((d) => d.category == DeviceCategory.overloadRelay)) {
          final leg = st == StarterType.starDelta ? starDeltaWindingFactor : 1.0;
          expect(d.targetRatingA!.amperes,
              closeTo((a.motor!.flcA.amperes * leg * 10).round() / 10, 1e-9));
          expect(d.targetRatingA!.amperes + 0.1,
              greaterThanOrEqualTo(leg * ib));
        }
      }
    });
  });

  // ── 3. star-delta on a single-phase way ──────────────────────────────────
  group('elec-props-8-star-delta-on-single-phase-way', () {
    for (final onOnePhaseBoard in [false, true]) {
      test('2.2 kW 1φ pump, star-delta (${onOnePhaseBoard ? '1φ 230 V' : '3φ 400 V'} '
          'board): DOL gear on the full current + a warning', () {
        final pr = _board(
          [_motor('jp', 2.2, starter: StarterType.starDelta, phases: 1,
              kind: LoadKind.pump)],
          system: onOnePhaseBoard
              ? ElectricalSystem.singlePhase
              : ElectricalSystem.threePhase,
          volts: onOnePhaseBoard ? 230 : 400,
        );
        final sys = computeSystem(_p, pr);
        expect(_way(sys, 'jp').threePhase, isFalse);
        final adv = computeAdvancedStudy(_p, pr, sys);
        final a = adv.controlAssemblies['jp']!;
        expect(a.starterType, StarterType.dol);
        // No 58 % winding gear: every contactor carries the full current.
        expect(a.devices.any((d) => d.role == 'star-contactor'), isFalse);
        final ol = a.devices
            .firstWhere((d) => d.category == DeviceCategory.overloadRelay);
        expect(ol.rating, isNot(contains('delta leg')));
        expect(ol.targetRatingA!.amperes,
            greaterThanOrEqualTo(_way(sys, 'jp').runCurrentA.amperes - 0.05));
        expect(adv.warnings.where((w) => w.code == 'star-delta-single-phase'),
            hasLength(1));
        // The schedule prints the starter the gear uses (DOL).
        final labels = _labels(pr, sys);
        expect(labels.any((t) => t.contains('star-delta')), isFalse);
        expect(labels.any((t) => t.contains('· DOL')), isTrue);
      });
    }

    test('a 3φ star-delta way is untouched (no warning)', () {
      final pr = _board([_motor('m', 45, starter: StarterType.starDelta)]);
      final sys = computeSystem(_p, pr);
      final adv = computeAdvancedStudy(_p, pr, sys);
      expect(adv.controlAssemblies['m']!.starterType, StarterType.starDelta);
      expect(adv.warnings.where((w) => w.code == 'star-delta-single-phase'),
          isEmpty);
    });

    test('a starter left on a re-kinded heater prints no starter token', () {
      final pr = _board([
        const ElectricalCircuit(
          id: 'h',
          name: 'h',
          loadKind: LoadKind.heating,
          loadW: 12500,
          cosPhi: 1,
          phases: 3,
          starterType: StarterType.starDelta,
          length: Length(10),
        ),
      ]);
      final sys = computeSystem(_p, pr);
      expect(_labels(pr, sys).any((t) => t.contains('star-delta')), isFalse);
    });
  });

  // ── 4. star-delta: one field run (the leads) ─────────────────────────────
  group('regression-star-delta-supply-cable-and-leads-both-bought-full-length',
      () {
    test('150 kW, 55 m: the BOM buys the leads at 55 m and the internal '
        'link only, never both at the way length', () {
      final pr = _board([
        _motor('ch', 150, starter: StarterType.starDelta, cable: 'NYY',
            lengthM: 55),
      ]);
      final sys = computeSystem(_p, pr);
      final ch = _way(sys, 'ch');
      final leads = ch.motorLeads!;
      final cables = buildBom(sys)
          .lines
          .where((l) => l.category == PartCategory.cable)
          .toList();
      final leadLine =
          cables.where((l) => l.description.contains('motor leads')).single;
      expect(leadLine.qty, 2 * 55);
      final supply = cables.where((l) => !l.description.contains('leads'));
      expect(supply.single.qty, kStarDeltaInternalWiringM);
      // Copper bought = leads (2 x 55 m x (3 x 150 + PE)) + the internal
      // link (2 m x the supply make-up) — the supply at 55 m is gone.
      // Round 43 re-derivation: Ib 289.4 A, I_w = 289.4/√3 = 167.1 A, Iz
      // needed 1.25 x 167.1 = 208.9 A. The two lead cables are 2 grouped
      // circuits (gf 0.80): 120 mm2 (Iz x 0.80 < 208.9 A) -> 150 mm2
      // (deratedIz 209.6 A).
      expect(leads.deratingFactor, closeTo(0.80, 1e-9));
      expect(leads.deratedIz.amperes, greaterThanOrEqualTo(1.25 * 289.4 / math.sqrt(3)));
      expect(leads.csaMm2, 150);
      expect(cables.map((l) => l.qty).fold<double>(0, (a, b) => a + b),
          2 * 55 + kStarDeltaInternalWiringM);
    });

    test('containment routes the two lead runs; Vd is the lead run', () {
      final pr = _board([
        _motor('ch', 150, starter: StarterType.starDelta, cable: 'NYY',
            lengthM: 55),
      ]);
      final sys = computeSystem(_p, pr);
      final ch = _way(sys, 'ch');
      final cc = containmentFor(sys.panels['MDP']!).conduits.single;
      expect(cc.count, 2);
      expect(cc.conduit.conduitSizeMm,
          sizeConduit(ch.motorLeads!.csaMm2, 4).conduitSizeMm);
      // Vd = the internal link (Ib, 2 m, supply section) + the lead run.
      // Round 43: each winding sits between its own two lead conductors, so
      // the lead drop is the single-phase LOOP 2·I_w·Z·L at I_w = Ib/√3
      // against 400 V (never the balanced √3 factor).
      final internal = voltageDrop(_p,
          current: ch.runCurrentA,
          length: const Length(kStarDeltaInternalWiringM),
          csaMm2: ch.cable.csaMm2,
          cosPhi: 0.85,
          threePhase: true,
          voltage: const Voltage(400),
          isLighting: false);
      final lead = voltageDrop(_p,
          current: Current(ch.runCurrentA.amperes / math.sqrt(3)),
          length: const Length(55),
          csaMm2: ch.motorLeads!.csaMm2,
          cosPhi: 0.85,
          threePhase: false,
          voltage: const Voltage(400),
          isLighting: false);
      expect(ch.voltageDrop.dropPercent,
          closeTo(internal.dropPercent + lead.dropPercent, 0.011));
      // The schedule's PENGHANTAR is the lead run (no 300 mm2 field cable).
      final labels = _labels(pr, sys);
      expect(labels.any((t) => t.startsWith('leads 2x(NYY')), isTrue);
      expect(labels.any((t) => t.contains('3x300')), isFalse);
    });

    test('seeded property: field copper metres = 2 x way length of the '
        'lead (+ the internal link), for every star-delta way', () {
      final rng = math.Random(4244);
      for (var t = 0; t < 40; t++) {
        final kw = 7.5 + rng.nextDouble() * 200;
        final len = (5 + rng.nextInt(120)).toDouble();
        final pr = _board([
          _motor('m', kw, starter: StarterType.starDelta, cable: 'NYY',
              lengthM: len),
        ]);
        final sys = computeSystem(_p, pr);
        final cables = buildBom(sys)
            .lines
            .where((l) => l.category == PartCategory.cable)
            .toList();
        final leadRuns = 2 * (_way(sys, 'm').motorLeads!.runsPerPhase ?? 1);
        final supplyRuns = _way(sys, 'm').cable.runsPerPhase ?? 1;
        expect(
            cables
                .where((l) => l.description.contains('motor leads'))
                .single
                .qty,
            len * leadRuns,
            reason: '$kw kW $len m');
        expect(
            cables.where((l) => !l.description.contains('leads')).single.qty,
            kStarDeltaInternalWiringM * supplyRuns,
            reason: '$kw kW $len m');
      }
    });
  });

  // ── 5. single-core star-delta leads ──────────────────────────────────────
  group('elec-props-8-single-core-star-delta-leads-bought-as-multicore', () {
    test('45 kW NYA star-delta, 40 m: 2 x 40 x 3 single cores + 2 x 40 PE',
        () {
      final pr = _board([
        _motor('m', 45, starter: StarterType.starDelta, cable: 'NYA',
            lengthM: 40),
      ]);
      final sys = computeSystem(_p, pr);
      final leads = _way(sys, 'm').motorLeads!;
      expect(leads.runsPerPhase ?? 1, 1);
      final lines = buildBom(sys, parts: fullCatalog())
          .lines
          .where((l) =>
              l.category == PartCategory.cable &&
              l.description.contains('motor leads'))
          .toList();
      final live = lines.where((l) => !l.description.contains('PE')).single;
      final pe = lines.where((l) => l.description.contains('PE')).single;
      expect(live.qty, 2 * 40 * 3);
      expect(pe.qty, 2 * 40);
      // Never a 4-core NYA spec / key.
      for (final l in lines) {
        expect(l.description, isNot(contains('4×')));
        expect(l.priceKey ?? '', isNot(contains('4x')));
        if (l.sku == null) expect(l.priceKey, contains(':1x'));
      }
    });
  });

  // ── 6. one starting basis for the genset dip ─────────────────────────────
  group('electrical-sim-7-genset-dip-multiples-disagree-with-starter', () {
    ElectricalProject genProject(StarterType st) => ElectricalProject(
          id: 'p',
          name: 'P',
          sources: const ElectricalSources(
              generator:
                  GeneratorSource(kva: ApparentPower(200000))),
          panels: [
            ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
              _motor('pump', 55, starter: st, kind: LoadKind.pump),
            ]),
          ],
        );

    test('55 kW DOL on 200 kVA: the dip reads the assembly start current',
        () {
      final pr = genProject(StarterType.dol);
      final sys = computeSystem(_p, pr);
      final adv = computeAdvancedStudy(_p, pr, sys);
      final a = adv.controlAssemblies['pump']!;
      // Ib = 55 000 / 0.88 / (√3·400·0.85) = 106.1 A > the 100 A table;
      // start = 6.5 x 106.1 = 690 A ⇒ √3·400·690 = 478 kVA.
      final startA = a.starting!.startCurrentA.amperes;
      expect(startA,
          closeTo((a.motor!.flcA.amperes * 6.5).roundToDouble(), 1e-9));
      final motors =
          gensetStartMotors(pr, sys: sys, assemblies: adv.controlAssemblies);
      final startKva = math.sqrt(3) * 400 * startA / 1000;
      expect(motors.single.startKva!.inKilovoltAmperes,
          closeTo(startKva, 1e-6));
      final r = assessGensetStart(const ApparentPower(200000),
          motors: motors);
      expect(r.startingKva.inKilovoltAmperes, closeTo(startKva, 0.01));
      // dip = 0.15 S / (200 + 0.15 S) ≈ 71.7 / 271.7 = 26.4 % > 25 %.
      final z = 0.15 * startKva;
      expect(r.estimatedDipPct, closeTo(100 * z / (200 + z), 0.01));
      expect(r.acceptable, isFalse);
      expect(adv.powerOneLine!.nodeOfKind(PowerNodeKind.generator)!.sub,
          contains('over'));
    });

    test('the dip multiple table IS the starting-profile table', () {
      expect(startKvaMultiple('DOL'),
          startingProfiles[StarterType.dol]!.startMultiple);
      expect(startKvaMultiple('STAR_DELTA'),
          startingProfiles[StarterType.starDelta]!.startMultiple);
      expect(startKvaMultiple('VFD'),
          startingProfiles[StarterType.vfd]!.startMultiple);
      expect(startKvaMultiple('SOFT_STARTER'),
          startingProfiles[StarterType.softStarter]!.startMultiple);
    });
  });

  // ── 7. the service cable beyond 4 parallel runs ──────────────────────────
  group('electrical-sim-7-parallel-run-cap-4-unsizable-feeders-and-silent-'
      'service-cable', () {
    test('a 2000 A service says its cable cannot be 4 runs', () {
      // 1300 kW of heaters ⇒ 1876 A ⇒ the 2000 A incomer; 4 x 300 mm2 at
      // 1.0 derating gives at most 4 x KHA(300) < 2000 A.
      final pr = _board([
        for (var i = 0; i < 13; i++)
          ElectricalCircuit(
              id: 'h$i',
              name: 'h$i',
              loadKind: LoadKind.heating,
              loadW: 100000,
              cosPhi: 1,
              phases: 3,
              length: const Length(10)),
      ]);
      final sys = computeSystem(_p, pr);
      final ws = sys.warnings
          .where((w) => w.code == 'service-cable-ampacity-inadequate')
          .toList();
      expect(ws, hasLength(1));
      expect(ws.single.panelId, 'MDP');
      expect(ws.single.message, contains('busduct'));
    });

    test('a 250 A service raises nothing', () {
      final pr = _board([
        for (var i = 0; i < 3; i++)
          ElectricalCircuit(
              id: 'h$i',
              name: 'h$i',
              loadKind: LoadKind.heating,
              loadW: 40000,
              cosPhi: 1,
              phases: 3,
              length: const Length(10)),
      ]);
      expect(
          computeSystem(_p, pr)
              .warnings
              .where((w) => w.code == 'service-cable-ampacity-inadequate'),
          isEmpty);
    });
  });

  // ── 8. MCCB Icu beyond 70 kA ─────────────────────────────────────────────
  group('electrical-sim-7-mccb-icu-ladder-tops-at-70ka', () {
    test('2000 kVA LVMDP (72.2 kA): every MCCB way is achievable', () {
      // 2 000 000 / (√3 · 400 · 0.04) = 72 169 A > the old 70 kA top.
      final project = ElectricalProject(
        id: 'p',
        name: 'P',
        transformerKva: const ApparentPower(2000000),
        panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            for (var i = 0; i < 4; i++)
              ElectricalCircuit(
                  id: 'h$i',
                  name: 'h$i',
                  loadKind: LoadKind.heating,
                  loadW: 150000,
                  cosPhi: 1,
                  phases: 3,
                  length: const Length(20)),
          ]),
        ],
      );
      final origin = estimatedServiceFaultLevelA(project)!;
      expect(origin.amperes, closeTo(2e6 / (math.sqrt(3) * 400 * 0.04), 1));
      final sys = computeSystem(_p, project, originFaultLevel: origin);
      final fs = faultStudy(sys, project, _p, originFaultLevel: origin);
      expect(
          fs.warnings.where((w) => w.code == 'breaking-capacity-inadequate'),
          isEmpty);
      for (var i = 0; i < 4; i++) {
        final w = _way(sys, 'h$i');
        expect(w.breaker.deviceClass, BreakerClass.mccb);
        // Icu 100 ≥ 72.2 and Ics 75 ≥ 72.2 ⇒ the 100 kA rung.
        expect(fs.circuits['h$i']!.breakerKa, 100);
      }
    });
  });

  // ── 9. PF study on a VFD bus ─────────────────────────────────────────────
  group('electrical-sim-7-pfc-ignores-vfd-supply-pf', () {
    test('4 x 90 kW VFD motors at the 0.95 target need no bank', () {
      final pr = _board([
        for (var i = 0; i < 4; i++)
          _motor('v$i', 90, starter: StarterType.vfd),
      ]);
      final sys = computeSystem(_p, pr);
      final pf = powerFactorCorrection(sys, pr);
      // kW = 4 x 90 / 0.88 = 409.1; displacement pf 0.95 ⇒ kvar =
      // kW · tan(acos 0.95) ⇒ at the 0.95 target: required 0.
      expect(pf.totalKw, closeTo(360 / 0.88, 0.1));
      expect(pf.existingPf, closeTo(electronicLoadPf, 1e-3));
      expect(pf.requiredKvar, closeTo(0, 1e-6));
      expect(pf.bankKvar, 0);
    });

    test('the same motors on DOL keep the motor cos φ 0.85', () {
      final pr = _board([
        for (var i = 0; i < 4; i++)
          _motor('d$i', 90, starter: StarterType.dol),
      ]);
      final pf = powerFactorCorrection(computeSystem(_p, pr), pr);
      expect(pf.uncorrectedPf, closeTo(0.85, 1e-3));
      expect(pf.bankKvar, greaterThan(0));
    });
  });

  // ── 10. non-standard breaker override ────────────────────────────────────
  group('elec-ui-journey-3-free-typed-breaker-override-nonstandard', () {
    test('a typed 17 A override is kept and named; 16 A is silent', () {
      ElectricalProject pr(double a) => _board([
            ElectricalCircuit(
              id: 's',
              name: 'Sockets',
              loadKind: LoadKind.socket,
              loadW: 2000,
              phases: 1,
              breakerOverrideA: Current(a),
              length: const Length(15),
            ),
          ], system: ElectricalSystem.singlePhase, volts: 220);
      final odd = computeSystem(_p, pr(17));
      expect(_way(odd, 's').breaker.ratingA.amperes, 17);
      final ws = odd.warnings
          .where((w) => w.code == 'breaker-override-nonstandard')
          .toList();
      expect(ws, hasLength(1));
      expect(ws.single.message, contains('16 A / 20 A'));
      expect(
          computeSystem(_p, pr(16))
              .warnings
              .where((w) => w.code == 'breaker-override-nonstandard'),
          isEmpty);
    });
  });
}
