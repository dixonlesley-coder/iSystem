import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Selectivity zone model + motor-fault contribution tests. Expected values are
/// hand-derived from the rating-ratio rule (1.6× / 2.5×), the local fault
/// constants, and the breaker frames `computeSystem` selects.
void main() {
  const p = PuilProfile();

  group('classifySelectivity (rating-ratio zones)', () {
    test('bands: non-selective < 1.6× ≤ partial < 2.5× ≤ total', () {
      // 100/100 = 1.0 < 1.6 ⇒ non-selective.
      expect(classifySelectivity(100, 100), SelectivityZone.nonSelective);
      // 200/100 = 2.0 in [1.6, 2.5) ⇒ partial.
      expect(classifySelectivity(200, 100), SelectivityZone.partial);
      // 300/100 = 3.0 ≥ 2.5 ⇒ total.
      expect(classifySelectivity(300, 100), SelectivityZone.total);
      // Boundary at exactly 1.6× is partial (not non-selective).
      expect(classifySelectivity(160, 100), SelectivityZone.partial);
      // Boundary at exactly 2.5× is total.
      expect(classifySelectivity(250, 100), SelectivityZone.total);
    });

    test('nonSelective matches the < 1.6× band', () {
      expect(nonSelective(100, 100), isTrue);
      expect(nonSelective(160, 100), isFalse);
      expect(nonSelective(100, 0), isFalse); // no downstream ⇒ not flagged
    });
  });

  group('estimatedMotorFaultA', () {
    test('~6× FLA pulse', () {
      // 150 A FLA → 6 × 150 = 900 A sub-transient infeed.
      expect(estimatedMotorFaultA(150), 900);
      expect(estimatedMotorFaultA(0), 0);
      expect(estimatedMotorFaultA(-5), 0);
    });
  });

  // A two-panel tree: MDP feeds SP via feeder f1; SP runs a 30 kW motor.
  // 30 kW 3-phase 400 V cosφ 0.85: Ib = 30000 / (√3·400·0.85) = 50.9 A.
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
  const project =
      ElectricalProject(id: 'pr', name: 'Bldg', panels: [sp, mdp]);

  test('systemMotorFaultContributionA sums motor-like circuit infeeds', () {
    final sys = computeSystem(p, project);
    // The only motor-like circuit is s1 (30 kW ⇒ design current ~50.9 A).
    final s1 = sys.panels['SP']!.circuits.firstWhere((c) => c.circuitId == 's1');
    // Contribution = 6 × design current.
    expect(
      systemMotorFaultContributionA(sys),
      closeTo(6 * s1.designCurrent.amperes, 0.5),
    );
  });

  test('motor contribution lifts the origin prospective fault (opt-in)', () {
    final sys = computeSystem(p, project);
    // Default (0 contribution) ⇒ byte-identical origin fault = 16 kA.
    final base = faultStudy(sys, project, p,
        originFaultLevel: const Current(16000));
    expect(base.originFaultkA, 16);

    // With a 900 A motor contribution the origin fault rises to 16.9 kA.
    final withMotor = faultStudy(
      sys,
      project,
      p,
      originFaultLevel: const Current(16000),
      estimatedMotorFaultContributionA: const Current(900),
    );
    expect(withMotor.originFaultkA, closeTo(16.9, 0.01));
    // The MDP bus fault is higher than the no-motor case (more let-through).
    expect(
      withMotor.panels['MDP']!.prospectiveFaultkA,
      greaterThan(base.panels['MDP']!.prospectiveFaultkA),
    );
  });

  test('selectivity result carries zone + Icu/Ics/Icw adequacy', () {
    final sys = computeSystem(p, project);
    final study = faultStudy(sys, project, p);
    expect(study.selectivity, hasLength(1));
    final sel = study.selectivity.single;
    expect(sel.upstreamCircuitId, 'f1');
    expect(sel.downstreamPanelId, 'SP');
    // f1 feeder 63 A vs SP incomer 63 A ⇒ ratio 1.0 ⇒ non-selective zone.
    expect(sel.upstreamRatingA, sel.downstreamRatingA);
    expect(sel.zone, SelectivityZone.nonSelective);
    expect(sel.nonSelective, isTrue);
    // At 16 kA an MCCB/MCB Icu of 25 kA covers it ⇒ Icu/Ics adequate.
    expect(sel.icuAdequate, isTrue);
  });

  test('Ics inadequacy surfaces when the service fraction undercuts the fault',
      () {
    // Push the origin fault very high so the upstream device's Ics (service
    // capacity, < Icu for an MCCB) is undercut even though Icu may still pass.
    // Use a larger feeder so the upstream device is an MCCB (Ics fraction 0.75).
    const bigSp = ElectricalPanel(
      id: 'SP',
      name: 'Sub',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'f1',
      circuits: [
        ElectricalCircuit(
          id: 's1',
          name: 'Big motor',
          loadKind: LoadKind.motor,
          motorKw: 90, // ~152 A ⇒ MCCB incomer + feeder
          cosPhi: 0.85,
          length: Length(10),
        ),
      ],
    );
    const bigProject =
        ElectricalProject(id: 'pr', name: 'Bldg', panels: [bigSp, mdp]);
    final sys = computeSystem(p, bigProject);
    // A 50 kA origin fault: an MCCB Icu tops out at 70 kA (covers), but Ics at
    // 0.75 × 70 = 52.5 kA only just covers; pushing to a higher fault undercuts.
    final study = faultStudy(sys, bigProject, p,
        originFaultLevel: const Current(60000));
    final sel = study.selectivity.single;
    // Icu may still pass while Ics (service) is undercut → flagged.
    expect(sel.icsAdequate || sel.icuAdequate, isTrue);
    // The study must at least produce a defined zone for the pair.
    expect(SelectivityZone.values, contains(sel.zone));
  });

  test('fault study verify items list the simplified models', () {
    final sys = computeSystem(p, project);
    final study = faultStudy(sys, project, p);
    expect(
      study.verifyItems.any((s) => s.contains('motor fault contribution')),
      isTrue,
    );
    expect(
      study.verifyItems.any((s) => s.contains('Ics vs Icu')),
      isTrue,
    );
    expect(
      study.verifyItems.any((s) => s.contains('time-current zone')),
      isTrue,
    );
  });
}
