/// SELECTIVITY-AWARE FEEDER BREAKER SIZING.
///
/// A feeder way and the incomer of the board it feeds are sized from the SAME
/// diversified demand, so they routinely land on the same ladder rung — ratio
/// 1.0, i.e. `nonSelective` by `fault.dart`'s 1.6× rule. `computeSystem` now
/// re-sizes such a feeder in a SECOND pass at a floor of
/// `selectivityRatio × the fed board's incomer rating`, so the sizer stops
/// creating the condition the fault study warns about.
///
/// Every expected value below is hand-derived from first principles against the
/// `PuilProfile` tables:
///   - breaker ladder: 6 10 16 20 25 32 40 50 63 | 80 100 125 160 200 250 315
///     400 500 630 800 1000 1250 1600 A;
///   - KHA, Cu/PVC, reference method B1 (conduit): 1.5→18, 2.5→25, 4→34, 6→44,
///     10→60, 16→80, 25→105, 35→130, 50→160, 70→200, 95→245, 120→285, 150→325,
///     185→370, 240→435, 300→500 A;
///   - derating at the panel defaults (30 °C air, grouping 1, conduit) = 1.0;
///   - PUIL continuous-load factor 1.25 (Iz ≥ max(In, 1.25·Ib));
///   - 3φ trunk minimum section 4 mm².
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

ElectricalCircuitResult _way(ElectricalPanelResult p, String id) =>
    p.circuits.firstWhere((c) => c.circuitId == id);

void main() {
  const p = PuilProfile();

  // ── (0) the primitive: selectBreaker's minRatingA floor ────────────────────
  group('selectBreaker minRatingA (the coordination floor)', () {
    test('null floor is the historic selection', () {
      // Ib 50.5 A → first rung ≥ 50.5 is 63 A.
      final r = selectBreaker(p,
          designCurrent: const Current(50.5), loadKind: LoadKind.feeder);
      expect(r.ratingA.amperes, 63);
      expect(r.overridden, isFalse);
    });

    test('a floor BELOW the design pick changes nothing', () {
      // max(63, 40) = 63 ⇒ the same rung.
      final r = selectBreaker(p,
          designCurrent: const Current(50.5),
          loadKind: LoadKind.feeder,
          minRatingA: 40);
      expect(r.ratingA.amperes, 63);
    });

    test('a floor ABOVE the design pick lifts to the first rung ≥ the floor',
        () {
      // max(63, 100.8) = 100.8 ⇒ first rung ≥ 100.8 is 125 A (100 is below it).
      final r = selectBreaker(p,
          designCurrent: const Current(50.5),
          loadKind: LoadKind.feeder,
          minRatingA: 100.8);
      expect(r.ratingA.amperes, 125);
      expect(r.deviceClass, BreakerClass.mccb); // > 63 A
    });

    test('a rung EXACTLY at the floor is taken (no needless upsize)', () {
      final r = selectBreaker(p,
          designCurrent: const Current(50.5),
          loadKind: LoadKind.feeder,
          minRatingA: 100);
      expect(r.ratingA.amperes, 100);
    });

    test('an explicit override wins outright — never floored', () {
      final r = selectBreaker(p,
          designCurrent: const Current(50.5),
          loadKind: LoadKind.feeder,
          overrideA: const Current(63),
          minRatingA: 1000);
      expect(r.ratingA.amperes, 63);
      expect(r.overridden, isTrue);
    });

    test('a floor past the ladder top clamps to the largest rung (no throw)',
        () {
      final r = selectBreaker(p,
          designCurrent: const Current(50.5),
          loadKind: LoadKind.feeder,
          minRatingA: 9999);
      expect(r.ratingA.amperes, 1600); // the ladder top
    });
  });

  // ── (1) the two-panel case the sizer used to make non-selective ────────────
  group('(1) a feeder on the child incomer\'s own rung is lifted 1.6×', () {
    // SP: 3φ, ONE 3φ heater 35 kW at cosφ 1.0, diversity 1.
    //   Ib(s1) = 35 000 / (√3·400·1.0) = 50.518 A → 50.5 A ⇒ way breaker 63 A.
    //   The way is three-phase, so it loads L1=L2=L3 = 50.5 A ⇒ the board's
    //   demand current is 50.5 A ⇒ SP INCOMER = first rung ≥ 50.5 = 63 A.
    // MDP feeds SP through f1 (25 m, cosφ 1.0). The feeder's load is SP's
    //   diversified demand = 35 000 W ⇒ Ib(f1) = 50.518 A ⇒ PASS 1 would pick
    //   63 A — the SAME rung as SP's incomer (ratio 1.0 ⇒ non-selective).
    // FLOOR = 1.6 × 63 = 100.8 A ⇒ first rung ≥ 100.8 = 125 A.
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
          name: 'Heater',
          loadKind: LoadKind.heating,
          loadW: 35000,
          cosPhi: 1.0,
          phases: 3,
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
          cosPhi: 1.0,
          length: Length(25),
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

    // PASS-1 REFERENCE: `computePanel` on MDP alone, fed the same feeder load
    // and no floor, is exactly what pass 1 computes for f1.
    final pass1Mdp = computePanel(
      p,
      mdp,
      opts: const ComputePanelOptions(
        feederLoadW: {'SP': 35000},
        panelSystems: {
          'MDP': ElectricalSystem.threePhase,
          'SP': ElectricalSystem.threePhase,
        },
        earthingSystem: EarthingSystem.tnS,
      ),
    );
    final sys = computeSystem(p, project);

    test('premise: pass 1 puts the feeder on the child incomer\'s rung', () {
      expect(_way(pass1Mdp, 'f1').designCurrent.amperes, closeTo(50.5, 1e-9));
      expect(_way(pass1Mdp, 'f1').breaker.ratingA.amperes, 63);
      expect(sys.panels['SP']!.incomer.breaker.ratingA.amperes, 63);
      // 63 < 1.6 × 63 = 100.8 ⇒ the pass-1 pair would be non-selective.
      expect(nonSelective(63, 63), isTrue);
    });

    test('the sized feeder carries the first rung ≥ 1.6× the child incomer', () {
      final feeder = _way(sys.panels['MDP']!, 'f1');
      expect(feeder.breaker.ratingA.amperes, 125);
      expect(feeder.breaker.overridden, isFalse);
      // The floor never touches the design current — only the device.
      expect(feeder.designCurrent.amperes, closeTo(50.5, 1e-9));
    });

    test('the cable upsizes with the bumped In (Iz ≥ max(In, 1.25·Ib))', () {
      // PASS 1: Iz ≥ max(63, 1.25 × 50.518 = 63.15) = 63.15 A ⇒ 16 mm² (80 A);
      //         the 3φ trunk minimum 4 mm² is already cleared.
      expect(_way(pass1Mdp, 'f1').cable.csaMm2, 16);
      // PASS 2: Iz ≥ max(125, 63.15) = 125 A ⇒ 25 mm² (105 A) is short,
      //         35 mm² (130 A) is the first section that carries it.
      final feeder = _way(sys.panels['MDP']!, 'f1');
      expect(feeder.cable.csaMm2, 35);
      expect(feeder.cable.deratedIz.amperes, closeTo(130, 0.1));
      expect(feeder.cable.ampacityReached, isTrue);
    });

    test('the fault study no longer calls the pair non-selective', () {
      final fs = faultStudy(sys, project, p);
      final pair = fs.selectivity.single;
      expect(pair.upstreamRatingA, 125);
      expect(pair.downstreamRatingA, 63);
      // 125 / 63 = 1.98 ⇒ inside [1.6, 2.5) ⇒ partial, not non-selective.
      expect(pair.nonSelective, isFalse);
      expect(pair.zone, SelectivityZone.partial);
      expect(fs.warnings.map((w) => w.code), isNot(contains('non-selective')));
    });

    test('the second pass adds no duplicate warnings', () {
      // Every warning code appears at most once per (panel, circuit, code).
      final keys = sys.warnings
          .map((w) => '${w.panelId}/${w.circuitId}/${w.code}')
          .toList();
      expect(keys.toSet().length, keys.length);
    });
  });

  // ── (2) an overridden feeder is untouched ─────────────────────────────────
  group('(2) an explicit feeder override is never floored', () {
    // Same board as (1) but the engineer pins the feeder at 63 A.
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
          name: 'Heater',
          loadKind: LoadKind.heating,
          loadW: 35000,
          cosPhi: 1.0,
          phases: 3,
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
          cosPhi: 1.0,
          length: Length(25),
          feedsPanelId: 'SP',
          breakerOverrideA: Current(63),
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

    test('the overridden rating stands verbatim at 63 A', () {
      final feeder = _way(sys.panels['MDP']!, 'f1');
      expect(feeder.breaker.ratingA.amperes, 63);
      expect(feeder.breaker.overridden, isTrue);
      // Iz ≥ max(63, 63.15) = 63.15 ⇒ 16 mm², exactly the un-floored cable.
      expect(feeder.cable.csaMm2, 16);
    });

    test('and the residual non-selectivity is reported, not hidden', () {
      final fs = faultStudy(sys, project, p);
      expect(fs.selectivity.single.nonSelective, isTrue);
      expect(fs.warnings.map((w) => w.code), contains('non-selective'));
    });
  });

  // ── (3) an already-selective pair ⇒ no second pass ────────────────────────
  group('(3) an already-selective feeder is left exactly as pass 1 sized it',
      () {
    // SP: 3φ heater 20 kW at cosφ 1.0 ⇒ Ib = 20 000/(√3·400) = 28.868 → 28.9 A
    //   ⇒ SP incomer = first rung ≥ 28.9 = 32 A ⇒ floor would be 1.6×32 = 51.2.
    // The feeder runs at a poor cosφ 0.5, so it already sizes well above that:
    //   Ib(f1) = 20 000/(√3·400·0.5) = 57.735 A ⇒ 63 A ≥ 51.2 ⇒ NO floor is
    //   derived, the floors map is empty and pass 1 IS the answer.
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
          name: 'Heater',
          loadKind: LoadKind.heating,
          loadW: 20000,
          cosPhi: 1.0,
          phases: 3,
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
          cosPhi: 0.5,
          length: Length(25),
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

    final pass1Mdp = computePanel(
      p,
      mdp,
      opts: const ComputePanelOptions(
        feederLoadW: {'SP': 20000},
        panelSystems: {
          'MDP': ElectricalSystem.threePhase,
          'SP': ElectricalSystem.threePhase,
        },
        earthingSystem: EarthingSystem.tnS,
      ),
    );
    final sys = computeSystem(p, project);

    test('premise: the pass-1 feeder already clears 1.6× the child incomer', () {
      expect(sys.panels['SP']!.incomer.breaker.ratingA.amperes, 32);
      expect(_way(pass1Mdp, 'f1').designCurrent.amperes, closeTo(57.7, 1e-9));
      expect(_way(pass1Mdp, 'f1').breaker.ratingA.amperes, 63);
      expect(nonSelective(63, 32), isFalse); // 63 ≥ 1.6 × 32 = 51.2
    });

    test('the system result reproduces the pass-1 sizing field for field', () {
      final feeder = _way(sys.panels['MDP']!, 'f1');
      final ref = _way(pass1Mdp, 'f1');
      expect(feeder.breaker.ratingA.amperes, ref.breaker.ratingA.amperes);
      expect(feeder.breaker.deviceClass, ref.breaker.deviceClass);
      expect(feeder.cable.csaMm2, ref.cable.csaMm2);
      expect(feeder.cable.deratedIz.amperes, ref.cable.deratedIz.amperes);
      expect(feeder.voltageDrop.dropPercent, ref.voltageDrop.dropPercent);
      expect(feeder.grounding.peCsaMm2, ref.grounding.peCsaMm2);
      // Iz ≥ max(63, 1.25 × 57.735 = 72.17) = 72.17 ⇒ 16 mm² (80 A).
      expect(feeder.cable.csaMm2, 16);
    });
  });

  // ── (4) a single-panel project never runs a second pass ───────────────────
  test('(4) a project with no feeders is handed back from pass 1 unchanged', () {
    const solo = ElectricalProject(
      id: 'solo',
      name: 'One board',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'Main',
          circuits: [
            ElectricalCircuit(
              id: 'c1',
              name: 'Sockets',
              loadKind: LoadKind.socket,
              loadW: 3000,
              cosPhi: 0.9,
              length: Length(20),
            ),
          ],
        ),
      ],
    );
    final sys = computeSystem(p, solo);
    final direct = computePanel(p, solo.panels.single);
    final a = _way(sys.panels['MDP']!, 'c1');
    final b = _way(direct, 'c1');
    expect(a.breaker.ratingA.amperes, b.breaker.ratingA.amperes);
    expect(a.cable.csaMm2, b.cable.csaMm2);
    expect(sys.panels['MDP']!.incomer.breaker.ratingA.amperes,
        direct.incomer.breaker.ratingA.amperes);
  });

  // ── (5) a floor past the ladder top clamps, and says so honestly ──────────
  group('(5) a floor beyond the largest frame clamps to the ladder top', () {
    // SP: 3φ heater 830 kW at cosφ 1.0 ⇒ Ib = 830 000/(√3·400) = 1198.0018 A
    //   → 1198.0 A ⇒ SP incomer = first rung ≥ 1198.0 = 1250 A.
    // Feeder f1 carries the same 830 kW at cosφ 1.0 ⇒ Ib = 1198.0 A ⇒ pass 1
    //   picks 1250 A, the child incomer's own rung (non-selective).
    // FLOOR = 1.6 × 1250 = 2000 A — beyond the 1600 A ladder top, so the feeder
    //   lifts as far as the ladder allows (1600 A) and the RESIDUAL
    //   non-selectivity (1600 / 1250 = 1.28 < 1.6) is left for the fault study.
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
          name: 'Furnace',
          loadKind: LoadKind.heating,
          loadW: 830000,
          cosPhi: 1.0,
          phases: 3,
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
          cosPhi: 1.0,
          length: Length(10),
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

    test('premise: the child incomer sits two rungs below the top', () {
      expect(sys.panels['SP']!.demandCurrent.amperes, closeTo(1198.0, 1e-9));
      expect(sys.panels['SP']!.incomer.breaker.ratingA.amperes, 1250);
    });

    test('the feeder clamps at 1600 A instead of throwing', () {
      final feeder = _way(sys.panels['MDP']!, 'f1');
      expect(feeder.breaker.ratingA.amperes, 1600);
      // Still a real, protected conductor: 4× 240 mm² (435 A each) ⇒ Iz 1740 A.
      expect(feeder.cable.ampacityReached, isTrue);
      expect(feeder.cable.deratedIz.amperes,
          greaterThanOrEqualTo(feeder.breaker.ratingA.amperes));
    });

    test('the residual non-selectivity is reported, not swallowed', () {
      final fs = faultStudy(sys, project, p);
      expect(fs.selectivity.single.upstreamRatingA, 1600);
      expect(fs.selectivity.single.nonSelective, isTrue);
      expect(fs.warnings.map((w) => w.code), contains('non-selective'));
    });
  });

  // ── (6) the harmonics neutral oversize is a NOTE, not a defect ────────────
  test('(6) harmonics-neutral-oversize is info (FOLD 2 already fixed it)', () {
    // Two single-phase VFD ways ⇒ the whole panel load is single-phase
    // non-linear ⇒ the triplen fraction crosses the oversize threshold and the
    // always-on FOLD 2 has already grown the neutral bar.
    const board = ElectricalPanel(
      id: 'MDP',
      name: 'Main',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
          id: 'v1',
          name: 'VFD A',
          loadKind: LoadKind.motor,
          motorKw: 2,
          cosPhi: 0.85,
          length: Length(10),
          phases: 1,
          starterType: StarterType.vfd,
        ),
        ElectricalCircuit(
          id: 'v2',
          name: 'VFD B',
          loadKind: LoadKind.motor,
          motorKw: 2,
          cosPhi: 0.85,
          length: Length(10),
          phases: 1,
          starterType: StarterType.vfd,
        ),
      ],
    );
    final r = computePanel(p, board);
    final w = r.warnings.firstWhere((w) => w.code == 'harmonics-neutral-oversize');
    expect(w.severity, WarningSeverity.info);
    // The message is unchanged — it still names the applied oversize.
    expect(w.message, contains('neutral bar oversized to'));
    expect(r.neutralPeBars.neutralCsaMm2,
        greaterThan(r.busbar.csaMm2 * 0.999)); // grown, not shrunk
  });
}
