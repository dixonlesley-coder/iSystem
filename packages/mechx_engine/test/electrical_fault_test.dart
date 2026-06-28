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
///   - Feeder f1 (50 m): Ib 50.9 A → MCB 63 A (curve C), cable 16 mm², PE 16 mm².
///   - SP incomer: MCB 63 A. SP motor s1 (30 kW, 10 m): MCB 63 A (curve D),
///     cable 16 mm², PE 16 mm².
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
      // Feeder 16 mm² Cu, 50 m: R = 1.38·50/1000 = 0.069, X = 0.08·50/1000 = 0.004.
      // SP source Z = (0.00204124+0.069, 0.01428869+0.004) = (0.0710412, 0.0182887)
      //   |Z| = √(0.0710412² + 0.0182887²) = 0.0733576 Ω.
      // Isc_SP = 400/(√3·0.0733576) = 3148.14 A → 3.15 kA (< 16 kA upstream).
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
      // loopR = 0.0710412 + 0.017664 + 0.017664 = 0.1063692
      // loopX = 0.0182887 + 0.0008 + 0.0008 = 0.0198887
      //   Zs = √(loopR² + loopX²) = 0.10821 Ω.
      final motor = fs.circuits['s1']!;
      expect(motor.zsOhm, closeTo(0.108, 0.001));
      // Ia (curve D) = 20·63 = 1260 A; Zs_max = 0.95·230/1260 = 0.17341 Ω.
      expect(motor.zsMaxOhm, closeTo(0.173, 0.001));
      // 0.108 ≤ 0.173 ⇒ disconnects in time.
      expect(motor.adsOk, isTrue);
    });

    test('selectivity: feeder vs sub-panel incomer (both 63 A ⇒ non-selective)',
        () {
      // 63 A < 1.6·63 = 100.8 A ⇒ no current discrimination — flagged.
      expect(fs.selectivity, hasLength(1));
      final pair = fs.selectivity.single;
      expect(pair.upstreamCircuitId, 'f1');
      expect(pair.downstreamPanelId, 'SP');
      expect(pair.nonSelective, isTrue);
      expect(fs.warnings.map((w) => w.code), contains('non-selective'));
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
}
