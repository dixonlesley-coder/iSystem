/// ROUND 11 (2026-10-18) — electrical sizing/protection rules, each pinned by a
/// hand-derived case and (where the rule is a property) a SEEDED property test.
///
///   1. A capacitor-bank way draws no real power: it adds nothing to the
///      connected / demand W or the phase balance, and its own device +
///      conductor size on 1.43 × Ib (IEC 60831-1 1.3 × 1.1).
///   2. Every FINAL way sizes its own device on its UNDIVERSIFIED current
///      (In ≥ Ib) — one machine does not diversify against itself.
///   3. TN ADS: an RCD on the way may provide the disconnection (Zs·IΔn ≤ U0).
///   4. TN ADS: a feeder or a final > 32 A may disconnect in 5 s (curve D at
///      10 × In), finals ≤ 32 A keep the 0.4 s multiples.
///   5. A VFD way on TT gets a Type B RCD.
///   6. The genset motor-start dip screen only sees motors the genset starts.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

ElectricalCircuitResult _way(ElectricalPanelResult r, String id) =>
    r.circuits.firstWhere((c) => c.circuitId == id);

ElectricalPanel _board(List<ElectricalCircuit> circuits,
        {String id = 'B', String name = 'Board', bool essential = false}) =>
    ElectricalPanel(
      id: id,
      name: name,
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      essential: essential,
      circuits: circuits,
    );

void main() {
  // ── 1. capacitor bank ──────────────────────────────────────────────────────
  group('1 — a capacitor-bank way', () {
    const motor = ElectricalCircuit(
      id: 'm',
      name: 'Motor',
      loadKind: LoadKind.motor,
      motorKw: 30,
      cosPhi: 0.8,
      phases: 3,
      length: Length(20),
    );
    const cap = ElectricalCircuit(
      id: 'cap',
      name: 'Capacitor bank',
      loadKind: LoadKind.capacitor,
      loadW: 20000, // 20 kvar
      cosPhi: 1.0,
      phases: 3,
      length: Length(5),
    );
    final alone = computePanel(p, _board([motor]));
    final withCap = computePanel(p, _board([motor, cap]));

    test('adds no real power and no phase current (the bank OFF is worst)', () {
      // Motor input = 30 / 0.88 = 34.091 kW; Ib = 34 091 / (√3·400·0.8)
      // = 61.5 A on every line ⇒ incomer 63 A. The 20 kvar bank used to add
      // +20 kW and +28.9 A arithmetically (⇒ 90.4 A, a 100 A incomer).
      expect(alone.demandW, closeTo(30000 / kAssumedMotorEfficiency, 0.5));
      expect(withCap.connectedW, alone.connectedW);
      expect(withCap.demandW, alone.demandW);
      expect(withCap.phaseBalance.l1, alone.phaseBalance.l1);
      expect(withCap.phaseBalance.l1, closeTo(61.5, 0.05));
      expect(withCap.incomer.breaker.ratingA.amperes,
          alone.incomer.breaker.ratingA.amperes);
      expect(withCap.incomer.breaker.ratingA.amperes, 63);
    });

    test('its own device sizes on 1.43 × Ib (IEC 60831-1 1.3 × 1.1)', () {
      final c = _way(withCap, 'cap');
      // Ib = Q / (√3·U) = 20 000 / (√3·400) = 28.868 A (displayed 28.9).
      final ib = 20000 / (math.sqrt(3) * 400);
      expect(c.designCurrent.amperes, closeTo(28.9, 1e-9));
      // Sizing current 1.43 × 28.868 = 41.28 A ⇒ first rung ≥ 41.28 = 50 A
      // (it was 32 A — 1.11 × Ib).
      expect(kCapacitorSwitchingFactor, 1.43);
      expect(c.breaker.ratingA.amperes, 50);
      expect(c.breaker.ratingA.amperes,
          greaterThanOrEqualTo(kCapacitorSwitchingFactor * ib));
      // Conductor: Iz ≥ max(50, 1.25 × 41.28 = 51.6) = 51.6 A on conduit PVC
      // (IEC B.52.4 B1): 10 mm² = 50 ✗, 16 mm² = 68 ✓.
      expect(c.cable.csaMm2, 16);
    });

    test('circuitConnectedW of a capacitor is 0 (kvar is not kW)', () {
      expect(circuitConnectedW(cap), 0);
      expect(circuitConnectedW(motor),
          closeTo(30000 / kAssumedMotorEfficiency, 1e-6));
    });

    // Property: on ANY seeded board, adding a capacitor way of ANY size leaves
    // the connected / demand W, all three line currents and the incomer exactly
    // as they were.
    test('property: adding a capacitor never moves demand, phases or incomer',
        () {
      final rnd = math.Random(20261018);
      for (var trial = 0; trial < 60; trial++) {
        final ways = <ElectricalCircuit>[
          for (var i = 0; i < 1 + rnd.nextInt(6); i++)
            ElectricalCircuit(
              id: 'w$i',
              name: 'Way $i',
              loadKind: LoadKind.general,
              loadW: 500 + rnd.nextInt(15000).toDouble(),
              cosPhi: 0.7 + rnd.nextDouble() * 0.3,
              phases: rnd.nextBool() ? 3 : 1,
              length: Length(5 + rnd.nextInt(40).toDouble()),
            ),
        ];
        final kvar = 2000 + rnd.nextInt(60000).toDouble();
        final base = computePanel(p, _board(ways));
        final plus = computePanel(
            p,
            _board([
              ...ways,
              ElectricalCircuit(
                id: 'cap',
                name: 'Cap',
                loadKind: LoadKind.capacitor,
                loadW: kvar,
                cosPhi: 1.0,
                phases: 3,
                length: const Length(5),
              ),
            ]));
        final why = 'trial $trial, $kvar var';
        expect(plus.connectedW, base.connectedW, reason: why);
        expect(plus.demandW, base.demandW, reason: why);
        expect(plus.phaseBalance.l1, base.phaseBalance.l1, reason: why);
        expect(plus.phaseBalance.l2, base.phaseBalance.l2, reason: why);
        expect(plus.phaseBalance.l3, base.phaseBalance.l3, reason: why);
        // Round 13 — the incomer is now floored at the bank's own switching
        // current (a dedicated PFC board must carry its bank): it never drops
        // below the load-only incomer, always carries 1.43 × Q/(√3·U), and is
        // EXACTLY the load-only incomer whenever the load current governs.
        final capSwitchA = roundTo(
            kCapacitorSwitchingFactor * kvar / (math.sqrt(3) * 400), 1);
        expect(plus.capacitorCurrentA, closeTo(capSwitchA, 0.11),
            reason: why);
        expect(plus.incomer.breaker.ratingA.amperes,
            greaterThanOrEqualTo(base.incomer.breaker.ratingA.amperes),
            reason: why);
        expect(plus.incomer.breaker.ratingA.amperes,
            greaterThanOrEqualTo(plus.capacitorCurrentA),
            reason: why);
        if (base.demandCurrent.amperes >= plus.capacitorCurrentA) {
          expect(plus.incomer.breaker.ratingA.amperes,
              base.incomer.breaker.ratingA.amperes,
              reason: why);
        }
        final c = _way(plus, 'cap');
        expect(c.breaker.ratingA.amperes,
            greaterThanOrEqualTo(
                kCapacitorSwitchingFactor * kvar / (math.sqrt(3) * 400) -
                    1e-6),
            reason: why);
      }
    });
  });

  // ── 2. final ways size on the undiversified current ───────────────────────
  group('2 — a final way sizes its own device on the UNDIVERSIFIED current',
      () {
    test('a 2.5 PK split AC at df 0.9: In 16 A ≥ Ib 10.5 A (was 10 A)', () {
      // 1φ on a 3φ 400 V board ⇒ U0 = round(400/√3) = 231 V.
      // Real Ib = 2062 / (231·0.85) = 10.50 A; diversified 0.9 × = 9.45 A.
      final r = computePanel(
          p,
          _board(const [
            ElectricalCircuit(
              id: 'ac',
              name: 'Split AC',
              loadKind: LoadKind.hvac,
              loadW: 2062,
              cosPhi: 0.85,
              demandFactor: 0.9,
              phases: 1,
              length: Length(15),
            ),
          ]));
      final c = _way(r, 'ac');
      // The design (balance / demand) current keeps the diversity …
      expect(c.designCurrent.amperes, closeTo(9.5, 1e-9));
      expect(r.demandW, closeTo(2062 * 0.9, 0.5)); // rounded to the watt
      // … but the device carries the machine: first rung ≥ 10.50 = 16 A.
      expect(2062 / (231 * 0.85), closeTo(10.50, 0.005));
      expect(c.breaker.ratingA.amperes, 16);
    });

    // Property: for any seeded non-motor, non-feeder way at any demand factor
    // ≤ 1, the breaker is never below the way's undiversified current.
    test('property: In ≥ undiversified Ib on every final way', () {
      final rnd = math.Random(181018);
      const kinds = [
        LoadKind.general,
        LoadKind.hvac,
        LoadKind.heating,
        LoadKind.welding,
        LoadKind.ups,
        LoadKind.lighting,
      ];
      for (var trial = 0; trial < 120; trial++) {
        final kind = kinds[rnd.nextInt(kinds.length)];
        final three = rnd.nextBool();
        final w = 200 + rnd.nextInt(40000).toDouble();
        final cos = 0.6 + rnd.nextDouble() * 0.4;
        final df = 0.3 + rnd.nextDouble() * 0.7;
        final r = computePanel(
            p,
            _board([
              ElectricalCircuit(
                id: 'x',
                name: 'X',
                loadKind: kind,
                loadW: w,
                cosPhi: cos,
                demandFactor: df,
                phases: three ? 3 : 1,
                length: const Length(10),
              ),
            ]));
        final c = _way(r, 'x');
        final ib = loadCurrent(
          power: Power(w),
          voltage: Voltage(three ? 400 : 231),
          cosPhi: cos,
          threePhase: three,
        ).amperes;
        expect(c.breaker.ratingA.amperes, greaterThanOrEqualTo(ib - 1e-9),
            reason: 'trial $trial: $kind ${three ? '3ph' : '1ph'} $w W '
                'cos $cos df $df ⇒ Ib $ib A, In ${c.breaker.ratingA.amperes}');
      }
    });
  });

  // ── 3 + 4. TN ADS: RCD and the 5 s limit ───────────────────────────────────
  group('3 — an RCD may provide ADS in TN (IEC 60364-4-41 411.4.5)', () {
    ElectricalProject socketProject({required bool lifeSafety}) =>
        ElectricalProject(
          id: 'pr',
          name: 'B',
          earthingSystem: EarthingSystem.tnS,
          panels: [
            _board([
              ElectricalCircuit(
                id: 's',
                name: 'Long socket run',
                loadKind: LoadKind.socket,
                loadW: 2100,
                cosPhi: 0.9,
                phases: 1,
                length: const Length(66),
                lifeSafety: lifeSafety,
                cableType: lifeSafety ? 'FRC' : null,
                // Round 56 — the life-safety (RCD-exempt) run pins its
                // load-sized 2.5 mm2: an override disables the ADS conductor
                // growth, so the MCB-alone failure stays the fixture.
                cableOverrideMm2: lifeSafety ? 2.5 : null,
              ),
            ]),
          ],
        );

    test('a 66 m socket run fails on its MCB alone but passes on its RCD', () {
      final project = socketProject(lifeSafety: false);
      final sys = computeSystem(p, project);
      final fs = faultStudy(sys, project, p);
      final c = _way(sys.panels['B']!, 's');
      expect(c.rcd.required, isTrue);
      expect(c.rcd.ratingMa, 30);
      final f = fs.circuits['s']!;
      // A final ≤ 32 A keeps the 0.4 s multiple: C × 10.
      expect(f.disconnectionTimeS, 0.4);
      final zsMaxMcb =
          zsVoltageFactor * u0PhaseVoltageV / (10 * c.breaker.ratingA.amperes);
      expect(f.zsOhm!, greaterThan(zsMaxMcb),
          reason: 'the fixture must defeat the MCB alone');
      // The RCD limit: Zs ≤ 0.95 · 230 / 0.030 = 7283 Ω ⇒ ADS by the RCD.
      expect(f.zsMaxOhm, closeTo(zsVoltageFactor * u0PhaseVoltageV / 0.030, 1));
      expect(f.adsOk, isTrue);
      expect(f.adsByRcd, isTrue);
      expect(fs.warnings.where((w) => w.code == 'ads-disconnection'), isEmpty);
    });

    test('the same run WITHOUT an RCD (life-safety, exempt) still errors', () {
      final project = socketProject(lifeSafety: true);
      final sys = computeSystem(p, project);
      final fs = faultStudy(sys, project, p);
      final c = _way(sys.panels['B']!, 's');
      expect(c.rcd.required, isFalse);
      final f = fs.circuits['s']!;
      expect(f.adsOk, isFalse);
      expect(f.adsByRcd, isFalse);
      final w = fs.warnings.singleWhere((w) => w.code == 'ads-disconnection');
      expect(w.severity, WarningSeverity.error);
      // Round 38 — the advice names only the levers the tool provides (the
      // model has no RCD request on a TN way): cable / breaker overrides.
      expect(w.message, isNot(contains('fit an RCD')));
      expect(w.message, contains('cable override'));
      expect(w.message, contains('breaker override'));
    });
  });

  group('4 — the permitted disconnection time', () {
    test('pure: feeders and finals > 32 A get 5 s, finals ≤ 32 A 0.4 s', () {
      expect(adsDisconnectionTimeS(isFeeder: false, ratingA: 32), 0.4);
      expect(adsDisconnectionTimeS(isFeeder: false, ratingA: 40), 5.0);
      expect(adsDisconnectionTimeS(isFeeder: true, ratingA: 16), 5.0);
      // Curve D: 20 × In within 0.4 s, 10 × In within 5 s; B and C unchanged.
      expect(curveTripMultiple[BreakerCurve.d], 20);
      expect(curveTripMultiple5s[BreakerCurve.d], 10);
      expect(curveTripMultiple5s[BreakerCurve.b], curveTripMultiple[BreakerCurve.b]);
      expect(curveTripMultiple5s[BreakerCurve.c], curveTripMultiple[BreakerCurve.c]);
    });

    test('a ≤ 32 A D-curve motor final keeps the 20 × In (0.4 s) limit', () {
      // 5.5 kW motor: Ib = 5.5/0.88/(√3·400·0.85) = 10.61 A ⇒ D 16 A ≤ 32 A.
      const project = ElectricalProject(
        id: 'pr',
        name: 'B',
        earthingSystem: EarthingSystem.tnS,
        panels: [
          ElectricalPanel(
            id: 'B',
            name: 'Board',
            system: ElectricalSystem.threePhase,
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                id: 'm',
                name: 'Small motor',
                loadKind: LoadKind.motor,
                motorKw: 5.5,
                cosPhi: 0.85,
                length: Length(20),
              ),
            ],
          ),
        ],
      );
      final sys = computeSystem(p, project);
      final c = _way(sys.panels['B']!, 'm');
      expect(c.breaker.ratingA.amperes, 16);
      final f = faultStudy(sys, project, p).circuits['m']!;
      expect(f.disconnectionTimeS, 0.4);
      expect(f.zsMaxOhm, closeTo(0.95 * 230 / (20 * 16), 0.0005));
    });
  });

  // ── 5. VFD on TT ───────────────────────────────────────────────────────────
  test('5 — a TT VFD way gets a Type B RCD (smooth DC fault current)', () {
    ElectricalCircuitResult vfdWay(StarterType? starter) {
      final project = ElectricalProject(
        id: 'pr',
        name: 'B',
        earthingSystem: EarthingSystem.tt,
        panels: [
          _board([
            ElectricalCircuit(
              id: 'm',
              name: 'Pump',
              loadKind: LoadKind.motor,
              motorKw: 15,
              cosPhi: 0.85,
              length: const Length(20),
              starterType: starter,
            ),
          ]),
        ],
      );
      return _way(computeSystem(p, project).panels['B']!, 'm');
    }

    final vfd = vfdWay(StarterType.vfd);
    expect(vfd.rcd.required, isTrue);
    expect(vfd.rcd.type, RcdType.b);
    // The same way on a DOL starter keeps its (non-B) recommendation.
    expect(vfdWay(StarterType.dol).rcd.type, isNot(RcdType.b));
  });

  // ── 6. genset dip screen ───────────────────────────────────────────────────
  group('6 — the genset dip screen sees only the motors the genset starts', () {
    ElectricalProject project({required double backup, bool flagEp = true}) =>
        ElectricalProject(
          id: 'pr',
          name: 'B',
          sources: ElectricalSources(
              generator: GeneratorSource(backupFraction: backup)),
          panels: [
            _board(const [
              ElectricalCircuit(
                id: 'f-ep',
                name: 'Feeder EP',
                loadKind: LoadKind.feeder,
                length: Length(10),
                feedsPanelId: 'EP',
              ),
              ElectricalCircuit(
                id: 'chiller',
                name: 'Chiller',
                loadKind: LoadKind.motor,
                motorKw: 110,
                cosPhi: 0.85,
                length: Length(30),
              ),
            ], id: 'MDP', name: 'MDP'),
            ElectricalPanel(
              id: 'EP',
              name: 'Life-safety board',
              system: ElectricalSystem.threePhase,
              voltage: const Voltage(400),
              essential: flagEp,
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f-ep',
              circuits: const [
                ElectricalCircuit(
                  id: 'fp',
                  name: 'Fire pump',
                  loadKind: LoadKind.pump,
                  motorKw: 15,
                  cosPhi: 0.85,
                  length: Length(20),
                ),
              ],
            ),
          ],
        );

    test('a 30 % backup with an essential board screens only its motors', () {
      final motors = gensetStartMotors(project(backup: 0.3));
      expect(motors.map((m) => m.name), ['Fire pump']);
    });

    test('essential propagates down the fed sub-tree', () {
      expect(gensetBackedPanelIds(project(backup: 0.3)), {'EP'});
    });

    test('a full-backup set with no essential designation screens all', () {
      final motors =
          gensetStartMotors(project(backup: 1.0, flagEp: false));
      expect(motors.map((m) => m.name).toSet(), {'Chiller', 'Fire pump'});
    });

    test('the advanced study screens the fire pump, not the 110 kW chiller', () {
      final pr = project(backup: 0.3);
      final sys = computeSystem(p, pr);
      final adv = computeAdvancedStudy(p, pr, sys);
      String? genSub(PowerOneLine one) =>
          one.nodes.firstWhere((n) => n.id == 'gen').sub;
      // The one-line the study built == the one-line built from the fire pump
      // ALONE (derived from the engine's own primitive), and differs from the
      // one that also screens the chiller (whose 110/0.8·6 = 825 kVA start
      // used to set the verdict).
      PowerOneLine oneLine(List<GensetMotor> motors) => buildPowerOneLine(
            pr.sources!,
            demand: sys.supply.demandVa,
            voltage: sys.supply.voltage,
            motors: motors,
          );
      const firePump = GensetMotor(
          name: 'Fire pump', shaftPower: Power(15000), starterType: null);
      const chiller = GensetMotor(
          name: 'Chiller', shaftPower: Power(110000), starterType: null);
      expect(genSub(adv.powerOneLine!), genSub(oneLine(const [firePump])));
      expect(genSub(oneLine(const [firePump, chiller])),
          isNot(genSub(oneLine(const [firePump]))));
    });
  });
}
