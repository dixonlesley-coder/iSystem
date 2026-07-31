import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart' show WarningSeverity;
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// A8a protection / fault-study tests. Expected values are hand-derived from
/// first principles using the PUIL/Supreme tables in `PuilProfile`, the cable
/// sizing produced by `computeSystem`, and the local fault constants, so they
/// anchor the port to the reference PanelMaker `engine/fault.ts`.
///
/// Probe of the sizing (`computeSystem`) used below:
///   - Feeder f1 (50 m): Ib = 30 000/(√3·400·0.85) = 50.943 A → 50.9 A. Its
///     CABLE is sized on that load (audit E3, 2026-07-30 — the selectivity floor
///     is device-only and never inflates copper): Iz ≥ max(63, 1.25 × 50.943 =
///     63.68) = 63.68 A ⇒ 16 mm² (B1 Cu/PVC KHA 80 A), PE 16 mm².
///     Its DEVICE would floor at 1.6 × SP's 63 A incomer = 100.8 A ⇒ rung 125 A,
///     but the cap "In ≤ Iz = 80 A" allows only the 80 A rung, so the feeder is
///     an MCCB 80 A and the residual non-selectivity (80/63 = 1.27) is reported.
///   - SP incomer: MCB 63 A (sized on the board's own 57.9 A demand, load-side
///     and therefore unaffected by the feeder floor). SP motor s1 (30 kW, 10 m):
///     MCB 63 A (curve D), cable 16 mm², PE 16 mm².
void main() {
  const p = PuilProfile();

  group('(a) two-panel feeder tree on TN-S — Isc decay, kA, Zs/ADS, selectivity',
      () {
    const sp = ElectricalPanel(
      id: 'SP',
      name: 'Sub',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'f1',
      circuits: [
        ElectricalCircuit(
          id: 's1',
          name: 'Motor',
          loadKind: LoadKind.motor,
          motorKw: 30,
          cosPhi: 0.85,
          length: Length(10),
        ),
      ],
    );
    const mdp = ElectricalPanel(
      id: 'MDP',
      name: 'Main',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
          id: 'f1',
          name: 'Feeder to SP',
          loadKind: LoadKind.feeder,
          cosPhi: 0.85,
          length: Length(50),
          feedsPanelId: 'SP',
        ),
      ],
    );
    const project = ElectricalProject(
      id: 'pr',
      name: 'Building',
      panels: [mdp, sp],
      earthingSystem: EarthingSystem.tnS,
    );
    final sys = computeSystem(p, project);
    final fs = faultStudy(sys, project, p); // default origin 16 kA

    test('origin fault level = the 16 kA default', () {
      expect(fs.originFaultkA, 16.0);
      // The root (utility-fed) MDP bus carries the full origin fault.
      expect(fs.panels['MDP']!.prospectiveFaultkA, 16.0);
    });

    test('Isc decays through the feeder cable to the sub-panel bus', () {
      // Source |Z| at the origin: z = 400/(√3·16000) = 0.0144338 Ω, split by
      // X/R = 7 ⇒ R = z/√50 = 0.00204124, X = 7R = 0.01428869.
      // Feeder 16 mm² Cu (the LOAD-sized conductor — E3: the device floor never
      // grows it), 50 m: R = 1.38·50/1000 = 0.069, X = 0.08·50/1000 = 0.004.
      // SP source Z = (0.00204124+0.069, 0.01428869+0.004)
      //             = (0.07104124, 0.01828869)
      //   |Z| = √(0.07104124² + 0.01828869²) = 0.0733576 Ω.
      // Isc_SP = 400/(√3·0.0733576) = 3148.1 A → 3.15 kA (< 16 kA upstream).
      expect(fs.panels['SP']!.prospectiveFaultkA, closeTo(3.15, 0.01));
    });

    test('breaker breaking-capacity adequacy (Icu ≥ Isc)', () {
      // MDP incomer MCB 63 A vs 16 kA: MCB ladder [6,10,15,25] → 25 kA ≥ 16 ⇒ OK.
      expect(fs.panels['MDP']!.incomerKa, 25);
      expect(fs.panels['MDP']!.incomerAdequate, isTrue);
      // SP incomer MCB 63 A vs 3.15 kA: first ladder rung ≥ 3.15 is 6 kA ⇒ OK.
      expect(fs.panels['SP']!.incomerKa, 6);
      expect(fs.panels['SP']!.incomerAdequate, isTrue);
      // The SP motor breaker sees the SP bus fault (3.15 kA) ⇒ 6 kA, adequate.
      final motor = fs.circuits['s1']!;
      expect(motor.faultkA, closeTo(3.15, 0.01));
      expect(motor.breakerKa, 6);
      expect(motor.breakerAdequate, isTrue);
    });

    test('TN-S earth-fault loop Zs + ADS disconnection (the SP motor)', () {
      // Loop = SP source Z + phaseZ(temp ×1.28) + peZ(temp ×1.28) over 10 m.
      // 16 mm²: R = 1.38·10/1000 = 0.0138, X = 0.0008. With ×1.28 on R:
      //   phaseZ = peZ = (0.017664, 0.0008).
      // loopR = 0.07104124 + 0.017664 + 0.017664 = 0.10636924
      // loopX = 0.01828869 + 0.0008 + 0.0008 = 0.01988869
      //   Zs = √(loopR² + loopX²) = 0.108213 Ω → 0.108 (3 dp).
      final motor = fs.circuits['s1']!;
      expect(motor.zsOhm, closeTo(0.108, 0.001));
      // Ia (curve D) = 20·63 = 1260 A; Zs_max = 0.95·230/1260 = 0.17341 Ω.
      expect(motor.zsMaxOhm, closeTo(0.173, 0.001));
      // 0.108 ≤ 0.173 ⇒ still disconnects in time.
      expect(motor.adsOk, isTrue);
    });

    test('selectivity: the ampacity cap holds the feeder at 80 A over 63 A', () {
      // Re-derived 2026-07-30 (audit E3+E4): `computeSystem` floors a feeder at
      // 1.6 × the fed board's incomer (100.8 A ⇒ rung 125 A) but caps it at the
      // largest rung its LOAD-sized 16 mm² conductor protects (Iz 80 A) — copper
      // is never inflated for discrimination. 80/63 = 1.27 < 1.6, so the pair
      // stays non-selective and is REPORTED (a capped floor is never counted as
      // applied, so nothing is suppressed for it).
      expect(fs.selectivity, hasLength(1));
      final pair = fs.selectivity.single;
      expect(pair.upstreamCircuitId, 'f1');
      expect(pair.downstreamPanelId, 'SP');
      expect(pair.upstreamRatingA, 80);
      expect(pair.downstreamRatingA, 63);
      expect(sys.feederFloorsApplied, isEmpty);
      expect(pair.nonSelective, isTrue);
      expect(pair.zone, SelectivityZone.nonSelective);
      expect(fs.warnings.map((w) => w.code), contains('non-selective'));
      expect(fs.warnings.map((w) => w.code),
          isNot(contains('selectivity-partial')));
    });

    test('verify items surface the unverified constants', () {
      expect(fs.verifyItems, isNotEmpty);
      expect(
        fs.verifyItems.any((s) => s.contains('16 kA')),
        isTrue,
      );
    });
  });

  group('(b) high origin fault ⇒ breaking-capacity inadequate', () {
    const mdp = ElectricalPanel(
      id: 'MDP',
      name: 'Main',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
          id: 'c1',
          name: 'Sockets',
          loadKind: LoadKind.socket,
          loadW: 6000,
          cosPhi: 0.9,
          length: Length(10),
        ),
      ],
    );
    const project = ElectricalProject(
      id: 'pr2',
      name: 'B2',
      panels: [mdp],
      earthingSystem: EarthingSystem.tnCs,
    );
    final sys = computeSystem(p, project);
    // 50 kA origin: an MCB incomer (max 25 kA Icu) cannot interrupt it.
    final fs = faultStudy(sys, project, p,
        originFaultLevel: Current.kiloamperes(50));

    test('origin + MDP bus at 50 kA', () {
      expect(fs.originFaultkA, 50.0);
      expect(fs.panels['MDP']!.prospectiveFaultkA, 50.0);
    });

    test('MCB incomer breaking capacity tops out below 50 kA ⇒ inadequate', () {
      // MCB ladder max = 25 kA < 50 kA.
      expect(fs.panels['MDP']!.incomerKa, 25);
      expect(fs.panels['MDP']!.incomerAdequate, isFalse);
      expect(
        fs.warnings.map((w) => w.code),
        contains('breaking-capacity-inadequate'),
      );
    });
  });

  group('(c) TT system relaxes ADS (RCD clears earth faults)', () {
    const mdp = ElectricalPanel(
      id: 'MDP',
      name: 'Main',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
          id: 'c1',
          name: 'Sockets',
          loadKind: LoadKind.socket,
          loadW: 4000,
          cosPhi: 0.9,
          length: Length(15),
        ),
      ],
    );
    const project = ElectricalProject(
      id: 'pr3',
      name: 'B3',
      panels: [mdp],
      earthingSystem: EarthingSystem.tt,
    );
    final sys = computeSystem(p, project);
    final fs = faultStudy(sys, project, p);

    test('TT circuits report no Zs/ADS (relaxed — handled by the RCD)', () {
      final c = fs.circuits['c1']!;
      expect(c.zsOhm, isNull);
      expect(c.zsMaxOhm, isNull);
      expect(c.adsOk, isNull);
      // No ADS warnings on TT.
      expect(
        fs.warnings.where((w) => w.code == 'ads-disconnection'),
        isEmpty,
      );
      // The socket final carries an RCD (covered) ⇒ no uncovered-TT warning.
      expect(sys.panels['MDP']!.circuits.single.rcd.required, isTrue);
      expect(
        fs.warnings.where((w) => w.code == 'tt-no-earth-fault-protection'),
        isEmpty,
      );
    });
  });

  group('(c2) TT way with NO modelled RCD → tt-no-earth-fault-protection', () {
    // A life-safety run on TT: circuitRcd deliberately omits the RCD
    // (availability prevails), so its earth fault is covered by NEITHER ADS
    // (TT loop) NOR an RCD — the fault study must flag it.
    const mdp = ElectricalPanel(
      id: 'MDP',
      name: 'Main',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
          id: 'fp',
          name: 'Fire pump',
          loadKind: LoadKind.pump,
          motorKw: 15,
          cosPhi: 0.85,
          lifeSafety: true,
          cableType: 'FRC',
          length: Length(15),
        ),
      ],
    );
    const project = ElectricalProject(
      id: 'pr3b',
      name: 'B3b',
      panels: [mdp],
      earthingSystem: EarthingSystem.tt,
    );
    final sys = computeSystem(p, project);
    final fs = faultStudy(sys, project, p);

    test('the uncovered life-safety TT way is flagged exactly once', () {
      // The life-safety way carries no RCD (covered=false).
      expect(sys.panels['MDP']!.circuits.single.rcd.required, isFalse);
      final w =
          fs.warnings.where((w) => w.code == 'tt-no-earth-fault-protection');
      expect(w, hasLength(1));
      expect(w.single.severity, WarningSeverity.warning);
      expect(w.single.circuitId, 'fp');
      // Still no Zs/ADS on TT, and no ADS warning.
      final c = fs.circuits['fp']!;
      expect(c.zsOhm, isNull);
      expect(c.adsOk, isNull);
      expect(
        fs.warnings.where((w) => w.code == 'ads-disconnection'),
        isEmpty,
      );
    });
  });

  group('(d) pure helpers', () {
    test('downstreamFaultA clamps to the upstream value when Z ≈ 0', () {
      expect(downstreamFaultA(400, const Impedance(0, 0), 16000), 16000);
    });

    test('breakerKa picks the smallest ladder rung that covers the fault', () {
      expect(breakerKa(40, BreakerClass.mcb, 8), 10); // [6,10,15,25]
      expect(breakerKa(40, BreakerClass.mcb, 100), 25); // capped at max
      // MCCB ≥ 400 A frame floors at 36 kA.
      expect(breakerKa(400, BreakerClass.mccb, 10), 36);
    });

    test('nonSelective applies the 1.6× discrimination ratio', () {
      expect(nonSelective(63, 63), isTrue); // 63 < 100.8
      expect(nonSelective(160, 63), isFalse); // 160 ≥ 100.8
      expect(nonSelective(63, 0), isFalse); // guard
    });

    test('sourceImpedanceFromIsc preserves |Z| while splitting R/X by X/R', () {
      final z = sourceImpedanceFromIsc(16000, 400);
      // |Z| = 400/(√3·16000) = 0.0144338 Ω, regardless of the split.
      expect(z.magnitude, closeTo(0.0144338, 1e-6));
      // X/R = 7.
      expect(z.xOhm / z.rOhm, closeTo(7, 1e-9));
    });
  });

  group('(e) estimatedServiceFaultLevelA — service-size-derived fault level',
      () {
    // A bare one-panel project; the estimate reads ONLY the project-level
    // service declarations, so the panel content is irrelevant here.
    const mdp = ElectricalPanel(
      id: 'MDP',
      name: 'Main',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
          id: 'c1',
          name: 'Sockets',
          loadKind: LoadKind.socket,
          loadW: 3000,
          cosPhi: 0.9,
          length: Length(10),
        ),
      ],
    );

    test('declared transformer ⇒ Isc = S/(√3·U·Zpu)', () {
      // 630 kVA at the representative 5 % p.u., referred to 400 V:
      //   √3·400·0.05 = 1.732050808·400·0.05 = 34.641016151
      //   Isc = 630000 / 34.641016151 = 18186.5335 A → rounded to 0.1 A.
      const project = ElectricalProject(
        id: 'e1',
        name: 'Tx',
        panels: [mdp],
        transformerKva: ApparentPower(630000),
      );
      expect(estimatedServiceFaultLevelA(project)!.amperes, 18186.5);
    });

    test('a huge transformer clamps at the 50 kA ceiling', () {
      // 5000 kVA: 5000000 / 34.641016151 = 144337.6 A — far past any LV device
      // ladder, so the estimate is clamped to maxEstimatedServiceFaultKa.
      const project = ElectricalProject(
        id: 'e2',
        name: 'BigTx',
        panels: [mdp],
        transformerKva: ApparentPower(5000000),
      );
      expect(estimatedServiceFaultLevelA(project)!.amperes, 50000);
      expect(maxEstimatedServiceFaultKa, 50);
    });

    test('LV connection-capacity rungs are monotone and banded', () {
      Current? forVa(double va) => estimatedServiceFaultLevelA(
            ElectricalProject(
              id: 'e3',
              name: 'Daya',
              panels: const [mdp],
              supplyCapacityVa: ApparentPower(va),
            ),
          );
      // 5500 VA — a domestic PLN step, inside the ≤ 16500 VA small band ⇒ 6 kA
      // (the breaking capacity domestic MCBs are actually built to).
      expect(forVa(5500)!.amperes, 6000);
      // 16500 VA — the band ceiling itself is INCLUSIVE ⇒ still 6 kA.
      expect(forVa(16500)!.amperes, 6000);
      // 33000 VA — a commercial 3φ daya step above the small band, still within
      // the PLN TR ceiling ⇒ the 10 kA rung.
      expect(forVa(33000)!.amperes, 10000);
      // 197000 VA — the top PLN TR step, inclusive ⇒ still 10 kA.
      expect(forVa(197000)!.amperes, 10000);
      // 250000 VA — beyond the TR ceiling with NO declared transformer ⇒ no
      // better claim than the flat default.
      expect(forVa(250000)!.amperes, 16000);
      expect(defaultLvUtilityFaultKa, 16);
      // Monotone non-decreasing across the bands.
      final rungs = [5500.0, 16500.0, 33000.0, 197000.0, 250000.0]
          .map((va) => forVa(va)!.amperes)
          .toList();
      for (var i = 1; i < rungs.length; i++) {
        expect(rungs[i], greaterThanOrEqualTo(rungs[i - 1]));
      }
    });

    test('nothing declared ⇒ null (the caller keeps its flat default)', () {
      const project = ElectricalProject(id: 'e4', name: 'Bare', panels: [mdp]);
      expect(estimatedServiceFaultLevelA(project), isNull);
    });

    test('dualTransformer alone ⇒ null (it carries no rating)', () {
      const project = ElectricalProject(
        id: 'e5',
        name: 'Dual',
        panels: [mdp],
        dualTransformer: true,
      );
      expect(estimatedServiceFaultLevelA(project), isNull);
    });

    test('a declared transformer WINS over a declared capacity', () {
      const project = ElectricalProject(
        id: 'e6',
        name: 'Both',
        panels: [mdp],
        transformerKva: ApparentPower(630000),
        supplyCapacityVa: ApparentPower(5500),
      );
      // The transformer branch (18186.5 A), not the 6 kA capacity rung.
      expect(estimatedServiceFaultLevelA(project)!.amperes, 18186.5);
    });

    test('a non-positive declaration falls through to the next step', () {
      const project = ElectricalProject(
        id: 'e7',
        name: 'Zero',
        panels: [mdp],
        transformerKva: ApparentPower(0),
        supplyCapacityVa: ApparentPower(5500),
      );
      expect(estimatedServiceFaultLevelA(project)!.amperes, 6000);
    });

    test('the estimate lowers the printed device kA on a domestic board', () {
      // This is the defect the estimate closes: at the flat 16 kA default the
      // MCB ladder [6,10,15,25] has to reach 25 kA; at the 6 kA domestic rung
      // the first rung already covers it.
      const project = ElectricalProject(
        id: 'e8',
        name: 'House',
        panels: [mdp],
        earthingSystem: EarthingSystem.tnCs,
        supplyCapacityVa: ApparentPower(5500),
      );
      final sys = computeSystem(p, project);
      final flat = faultStudy(sys, project, p); // 16 kA default
      expect(flat.panels['MDP']!.incomerKa, 25);

      final sized = faultStudy(sys, project, p,
          originFaultLevel: estimatedServiceFaultLevelA(project)!);
      expect(sized.originFaultkA, 6.0);
      expect(sized.panels['MDP']!.incomerKa, 6);
      expect(sized.panels['MDP']!.incomerAdequate, isTrue);
    });
  });
}
