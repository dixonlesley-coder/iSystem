/// THE FEEDER SELECTIVITY-FLOOR POLICY (audit findings E3 + E4).
///
/// The floor used to lift a feeder's BREAKER to `selectivityRatio ×` the fed
/// board's incomer and then let `sizeCable` chase it (Iz ≥ In), so discrimination
/// was bought with CONDUCTOR COPPER: in the W-SIM office the PP-1 feeder — a
/// board drawing 42.9 A — took a 160 A MCCB on 150 mm², and the 5 kW
/// single-phase LP-3 board took an 80 A MCCB on 50 mm². Real practice
/// discriminates with the DEVICE, not the cable.
///
/// The policy this file pins:
///   (a) the feeder CABLE sizes on the LOAD — the un-floored, Ib-based breaker
///       pick plus the existing minimum-section and voltage-drop rules;
///   (b) the feeder DEVICE floors to the first rung ≥ `selectivityRatio ×` the
///       fed board's incomer, CAPPED at the largest rung that load-sized cable's
///       derated Iz still protects (In ≤ Iz is inviolable);
///   (c) `ElectricalSystemResult.feederFloorsApplied` names the feeders that
///       reached the FULL target, and `faultStudy` suppresses the
///       `selectivity-partial` advisory for exactly those (landing in the
///       1.6×..2.5× band is what the floor targets — the engine's own trade-off,
///       not a finding). `non-selective` is NEVER suppressed, and a floor the
///       cap held back is NOT in the set, so its residual is still reported;
///   (d) an explicit `breakerOverrideA` wins outright — never floored, never
///       suppressed.
///
/// Every expected value is hand-derived from the `PuilProfile` tables:
///   - breaker ladder: 6 10 16 20 25 32 40 50 63 | 80 100 125 160 200 250 315
///     400 500 630 800 1000 1250 1600 A;
///   - KHA, Cu/PVC, reference method B1 (conduit): 1.5→18, 2.5→25, 4→34, 6→44,
///     10→60, 16→80, 25→105, 35→130, 50→160, 70→200 A;
///   - ambient air factors (PVC): 30 °C → 1.00, 35 °C → 0.94;
///   - grouping factors: 1 → 1.00, 6 → 0.57;
///   - PUIL continuous-load factor 1.25 (Iz ≥ max(In, 1.25·Ib));
///   - minimum section: 3φ trunk 4 mm², 1φ trunk 2.5 mm².
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

// The W-SIM design itself (the 3-storey / 7-board / 38-way office the audit
// drove through the public API) — the two "outrage" boards are re-checked here
// against the new policy. Only the builder is imported; the exercise's own
// `main` stays with its file.
import 'whole_building_electrical_design_test.dart' show buildOfficeProject;

ElectricalCircuitResult _way(ElectricalPanelResult p, String id) =>
    p.circuits.firstWhere((c) => c.circuitId == id);

/// A two-board project: MDP -> SP, one load on SP, one feeder on MDP.
ElectricalProject _twoBoard({
  required double loadW,
  required double loadCosPhi,
  required double feederCosPhi,
  required double feederLengthM,
  Current? feederOverrideA,
}) =>
    ElectricalProject(
      id: 'pr',
      name: 'Building',
      earthingSystem: EarthingSystem.tnS,
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'Main',
          circuits: [
            ElectricalCircuit(
              id: 'f1',
              name: 'Feeder to SP',
              loadKind: LoadKind.feeder,
              cosPhi: feederCosPhi,
              length: Length(feederLengthM),
              feedsPanelId: 'SP',
              breakerOverrideA: feederOverrideA,
            ),
          ],
        ),
        ElectricalPanel(
          id: 'SP',
          name: 'Sub',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f1',
          circuits: [
            ElectricalCircuit(
              id: 's1',
              name: 'Heater',
              loadKind: LoadKind.heating,
              loadW: loadW,
              cosPhi: loadCosPhi,
              phases: 3,
              length: const Length(10),
            ),
          ],
        ),
      ],
    );

void main() {
  const p = PuilProfile();

  // ── (0) the primitive: the CAP is applied last, so it beats the FLOOR ──────
  group('(0) selectBreaker — cap beats floor', () {
    // Ib 50.5 A ⇒ the design pick is the first rung ≥ 50.5 = 63 A.
    test('no constraint: the plain design pick', () {
      expect(
        selectBreaker(p,
                designCurrent: const Current(50.5), loadKind: LoadKind.feeder)
            .ratingA
            .amperes,
        63,
      );
    });

    test('a floor alone lifts to the first rung at/above it', () {
      // max(63, 100.8) ⇒ first rung ≥ 100.8 = 125 A (100 A is below it).
      expect(
        selectBreaker(p,
                designCurrent: const Current(50.5),
                loadKind: LoadKind.feeder,
                minRatingA: 100.8)
            .ratingA
            .amperes,
        125,
      );
    });

    test('a cap BELOW the floor wins — the conductor is never over-protected',
        () {
      // Floor asks for 125 A; the cable only carries 80 A ⇒ the largest rung
      // ≤ 80 is 80 A. In ≤ Iz is inviolable, so the floor is held back here.
      expect(
        selectBreaker(p,
                designCurrent: const Current(50.5),
                loadKind: LoadKind.feeder,
                minRatingA: 100.8,
                maxRatingA: const Current(80))
            .ratingA
            .amperes,
        80,
      );
      // A tighter cable pulls it right back to the design pick.
      expect(
        selectBreaker(p,
                designCurrent: const Current(50.5),
                loadKind: LoadKind.feeder,
                minRatingA: 100.8,
                maxRatingA: const Current(63))
            .ratingA
            .amperes,
        63,
      );
    });

    test('a cap ABOVE the floor leaves the floor intact', () {
      // Floor 100.8 ⇒ 125 A; the cable carries 130 A ⇒ the cap never bites.
      expect(
        selectBreaker(p,
                designCurrent: const Current(50.5),
                loadKind: LoadKind.feeder,
                minRatingA: 100.8,
                maxRatingA: const Current(130))
            .ratingA
            .amperes,
        125,
      );
    });

    test('an override wins outright over BOTH', () {
      final r = selectBreaker(p,
          designCurrent: const Current(50.5),
          loadKind: LoadKind.feeder,
          overrideA: const Current(63),
          minRatingA: 1000,
          maxRatingA: const Current(10));
      expect(r.ratingA.amperes, 63);
      expect(r.overridden, isTrue);
    });
  });

  // ── (1) the floor FITS inside the cable ⇒ full target ⇒ partial suppressed ──
  group('(1) a small feeder: the floor fits, and its advisory is suppressed',
      () {
    // SP: one 3φ 5 kW heater at cosφ 1.0 ⇒
    //   Ib = 5000 / (√3·400·1.0) = 7.2169 A → printed 7.2 A.
    //   A 3φ way loads all three lines ⇒ demand current 7.2 A ⇒ SP INCOMER =
    //   first rung ≥ 7.2 = 10 A (no headroom spec).
    // Feeder f1 carries SP's diversified demand 5000 W at cosφ 1.0 ⇒ the same
    //   7.2169 A ⇒ the LOAD-SIZED device is 10 A.
    // CABLE (on the load-sized 10 A): panel defaults ⇒ 30 °C air, grouping 1,
    //   conduit ⇒ derating 1.00. Iz ≥ max(10, 1.25 × 7.2169 = 9.02) = 10 A, and
    //   the 3φ trunk minimum is 4 mm² (KHA 34 A) — which already clears it.
    //   ⇒ 4 mm², Iz 34.0 A.
    // FLOOR = 1.6 × 10 = 16 A ⇒ first rung ≥ 16 = 16 A.
    // CAP  = Iz 34 A ⇒ the largest rung ≤ 34 is 32 A. 16 ≤ 32, so the floor
    //   stands in full and the CABLE DOES NOT MOVE.
    final project = _twoBoard(
      loadW: 5000,
      loadCosPhi: 1.0,
      feederCosPhi: 1.0,
      feederLengthM: 25,
    );
    final sys = computeSystem(p, project);
    final feeder = _way(sys.panels['MDP']!, 'f1');

    // The un-floored reference: `computePanel` on MDP alone with no floor is
    // exactly what pass 1 sizes, so "the cable did not move" is a comparison,
    // not a magic number.
    final pass1 = computePanel(
      p,
      project.panels.first,
      opts: const ComputePanelOptions(
        feederLoadW: {'SP': 5000},
        panelSystems: {
          'MDP': ElectricalSystem.threePhase,
          'SP': ElectricalSystem.threePhase,
        },
        earthingSystem: EarthingSystem.tnS,
      ),
    );

    test('premise: pass 1 puts the feeder on the child incomer\'s own rung', () {
      expect(sys.panels['SP']!.incomer.breaker.ratingA.amperes, 10);
      expect(_way(pass1, 'f1').designCurrent.amperes, closeTo(7.2, 1e-9));
      expect(_way(pass1, 'f1').breaker.ratingA.amperes, 10);
      expect(nonSelective(10, 10), isTrue); // 10 < 1.6 × 10
    });

    test('the DEVICE reaches the full 1.6x target', () {
      expect(feeder.breaker.ratingA.amperes, 16);
      expect(feeder.breaker.overridden, isFalse);
      // The floor never touches the design current.
      expect(feeder.designCurrent.amperes, closeTo(7.2, 1e-9));
    });

    test('the CABLE is byte-identical to the un-floored pass-1 conductor', () {
      final ref = _way(pass1, 'f1');
      expect(feeder.cable.csaMm2, 4.0);
      expect(feeder.cable.csaMm2, ref.cable.csaMm2);
      expect(feeder.cable.deratedIz.amperes, closeTo(34.0, 1e-9));
      expect(feeder.cable.deratedIz.amperes, ref.cable.deratedIz.amperes);
      expect(feeder.grounding.peCsaMm2, ref.grounding.peCsaMm2);
      // In ≤ Iz still holds with a wide margin.
      expect(feeder.breaker.ratingA.amperes,
          lessThanOrEqualTo(feeder.cable.deratedIz.amperes));
    });

    test('feederFloorsApplied names it', () {
      expect(sys.feederFloorsApplied, {'f1'});
    });

    test('faultStudy suppresses the partial advisory for that pair', () {
      final fs = faultStudy(sys, project, p);
      final pair = fs.selectivity.single;
      expect(pair.upstreamRatingA, 16);
      expect(pair.downstreamRatingA, 10);
      // 16 / 10 = 1.60 ⇒ exactly at the partial boundary, NOT non-selective.
      expect(pair.nonSelective, isFalse);
      expect(pair.zone, SelectivityZone.partial);
      // The zone is still classified honestly — only the ADVISORY is dropped.
      expect(fs.warnings.map((w) => w.code),
          isNot(contains('selectivity-partial')));
      expect(fs.warnings.map((w) => w.code), isNot(contains('non-selective')));
    });

    test('the suppression is the SET, not a silent drop', () {
      // Told the sizer floored nothing, the very same study raises the advisory.
      final fs = faultStudy(sys, project, p, engineFlooredFeederIds: const {});
      expect(fs.warnings.map((w) => w.code), contains('selectivity-partial'));
    });
  });

  // ── (2) the cap BITES: the floor is held back and the residual is reported ──
  group('(2) a heavy feeder: the cable caps the floor, non-selectivity remains',
      () {
    // SP: one 3φ 35 kW heater at cosφ 1.0 ⇒
    //   Ib = 35 000 / (√3·400) = 50.518 A → 50.5 A ⇒ SP INCOMER = 63 A.
    // Feeder f1 carries 35 000 W at cosφ 1.0 ⇒ the same 50.518 A ⇒ LOAD-SIZED
    //   device = first rung ≥ 50.518 = 63 A.
    // CABLE (derating 1.00): Iz ≥ max(63, 1.25 × 50.518 = 63.15) = 63.15 A ⇒
    //   10 mm² (60 A) is short, 16 mm² (80 A) carries it ⇒ 16 mm², Iz 80.0 A.
    // FLOOR = 1.6 × 63 = 100.8 ⇒ would be 125 A.
    // CAP   = Iz 80 A ⇒ the largest rung ≤ 80 is 80 A — BELOW the target, so
    //   the device lifts 63 → 80 A and stops there. Under the OLD policy the
    //   cable chased the 125 A device up to 35 mm²; it now stays at 16 mm².
    final project = _twoBoard(
      loadW: 35000,
      loadCosPhi: 1.0,
      feederCosPhi: 1.0,
      feederLengthM: 25,
    );
    final sys = computeSystem(p, project);
    final feeder = _way(sys.panels['MDP']!, 'f1');

    test('the device stops at the rung the conductor protects', () {
      expect(sys.panels['SP']!.incomer.breaker.ratingA.amperes, 63);
      expect(feeder.breaker.ratingA.amperes, 80);
      expect(feeder.cable.csaMm2, 16.0); // was 35 mm² under the old policy
      expect(feeder.cable.deratedIz.amperes, closeTo(80.0, 1e-9));
      expect(feeder.breaker.ratingA.amperes,
          lessThanOrEqualTo(feeder.cable.deratedIz.amperes));
    });

    test('it is NOT counted as a floor applied', () {
      // 80 A is short of the 100.8 A target, so the pair is not the engine's
      // own deliberate trade-off and nothing is suppressed for it.
      expect(sys.feederFloorsApplied, isEmpty);
    });

    test('the residual non-selectivity is reported, never suppressed', () {
      final fs = faultStudy(sys, project, p);
      // 80 / 63 = 1.27 < 1.6 ⇒ non-selective.
      expect(fs.selectivity.single.nonSelective, isTrue);
      expect(fs.warnings.map((w) => w.code), contains('non-selective'));
    });
  });

  // ── (3) an explicit override is never floored and never suppressed ─────────
  group('(3) an overridden feeder', () {
    final project = _twoBoard(
      loadW: 35000,
      loadCosPhi: 1.0,
      feederCosPhi: 1.0,
      feederLengthM: 25,
      feederOverrideA: const Current(63),
    );
    final sys = computeSystem(p, project);
    final feeder = _way(sys.panels['MDP']!, 'f1');

    test('the pinned rating stands verbatim, on the load-sized conductor', () {
      expect(feeder.breaker.ratingA.amperes, 63);
      expect(feeder.breaker.overridden, isTrue);
      // Iz ≥ max(63, 63.15) = 63.15 ⇒ 16 mm², the same load-sized cable.
      expect(feeder.cable.csaMm2, 16.0);
    });

    test('no floor is derived for it, and its residual is reported', () {
      expect(sys.feederFloorsApplied, isEmpty);
      final fs = faultStudy(sys, project, p);
      expect(fs.selectivity.single.nonSelective, isTrue); // 63 / 63 = 1.0
      expect(fs.warnings.map((w) => w.code), contains('non-selective'));
    });
  });

  // ── (4) an already-selective feeder ⇒ no floor at all ──────────────────────
  test('(4) an already-selective feeder is not floored and not listed', () {
    // SP: 3φ 20 kW at cosφ 1.0 ⇒ Ib = 28.868 → 28.9 A ⇒ SP incomer 32 A ⇒ the
    // floor would be 1.6 × 32 = 51.2 A. The feeder's own poor cosφ 0.5 already
    // puts it at Ib = 20 000/(√3·400·0.5) = 57.735 A ⇒ 63 A ≥ 51.2 ⇒ no floor.
    final project = _twoBoard(
      loadW: 20000,
      loadCosPhi: 1.0,
      feederCosPhi: 0.5,
      feederLengthM: 25,
    );
    final sys = computeSystem(p, project);
    expect(sys.panels['SP']!.incomer.breaker.ratingA.amperes, 32);
    expect(_way(sys.panels['MDP']!, 'f1').breaker.ratingA.amperes, 63);
    expect(sys.feederFloorsApplied, isEmpty);
    // 63 / 32 = 1.97 ⇒ partial, and since the SIZER did not floor it the
    // advisory is a genuine finding and IS raised.
    final fs = faultStudy(sys, project, p);
    expect(fs.selectivity.single.zone, SelectivityZone.partial);
    expect(fs.warnings.map((w) => w.code), contains('selectivity-partial'));
  });

  test('(5) a project with no feeders reports an empty floors set', () {
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
    expect(computeSystem(p, solo).feederFloorsApplied, isEmpty);
  });

  // ── (6) the W-SIM outrage cases, re-checked on the real design ─────────────
  group('(6) the W-SIM office: copper is back at the load size', () {
    final project = buildOfficeProject();
    // The fault level drives FOLD-1 busbar withstand only, never a circuit's
    // device/cable, so the plain solve is the right one to size-check.
    final sys = computeSystem(p, project);
    final mdp = sys.panels['MDP'] ?? sys.panels['mdp']!;

    test('PP-1: a board drawing 42.9 A no longer takes 150 mm2', () {
      // PP-1's diversified demand is 25 245 W; the feeder converts it at the
      // feeder default cosφ 0.85:
      //   Ib = 25 245 / (√3·400·0.85) = 25 245 / 588.897 = 42.87 A → 42.9 A
      //   ⇒ LOAD-SIZED device = first rung ≥ 42.87 = 50 A.
      // CABLE: MDP is 35 °C / grouping 6 / conduit ⇒ derating
      //   0.94 × 0.57 = 0.5358. Iz ≥ max(50, 1.25 × 42.87 = 53.59) = 53.59 A:
      //   16 mm² → 80 × 0.5358 = 42.9 A ✗;  25 mm² → 105 × 0.5358 = 56.3 A ✓.
      //   ⇒ 25 mm², Iz 56.3 A  (the old policy landed on 150 mm²).
      final f = _way(mdp, 'mdp-f-pp1');
      expect(f.designCurrent.amperes, 42.9);
      expect(f.cable.csaMm2, 25.0);
      expect(f.cable.deratedIz.amperes, closeTo(56.3, 0.05));
      // The conductor is now proportionate: Iz/Ib was > 3.0, it is now < 1.5.
      expect(f.cable.deratedIz.amperes / f.designCurrent.amperes,
          lessThan(1.5));

      // DEVICE: PP-1's incomer is 80 A (58.0 A worst phase × 1.25 headroom ⇒
      // 72.5 ⇒ rung 80), so the floor target is 1.6 × 80 = 128 ⇒ rung 160 A.
      // The cap is Iz 56.3 ⇒ the largest rung ≤ 56.3 is 50 A, i.e. the floor
      // cannot move this device at all.
      expect(sys.panels['pp1']!.incomer.breaker.ratingA.amperes, 80);
      expect(f.breaker.ratingA.amperes, 50);
      expect(sys.feederFloorsApplied, isNot(contains('mdp-f-pp1')));
    });

    test('LP-3: the small 1-phase board no longer takes 50 mm2', () {
      // LP-3 connected 1400 + 1000 + 2600×0.7 + 2000×0.7 = 5620 W, diversity
      // 0.9 ⇒ demand 5058 W. Its feeder follows the FED board — 1φ at 220 V
      // (E8a) — so Ib = 5058 / (220 × 0.85) = 27.05 A → 27.0 A ⇒ LOAD-SIZED
      // device = first rung ≥ 27.05 = 32 A.
      // CABLE: Iz ≥ max(32, 1.25 × 27.05 = 33.81) = 33.81 A at derating 0.5358:
      //   10 mm² → 60 × 0.5358 = 32.1 ✗;  16 mm² → 80 × 0.5358 = 42.9 ✓
      //   ⇒ 16 mm² (the old policy landed on 50 mm²).
      final f = _way(mdp, 'mdp-f-lp3');
      expect(f.threePhase, isFalse);
      expect(f.designCurrent.amperes, 27.0);
      expect(f.cable.csaMm2, 16.0);
      expect(f.cable.deratedIz.amperes, closeTo(42.9, 0.05));

      // DEVICE: LP-3's incomer is 40 A (28.5 A × 1.20 headroom = 34.2 ⇒ 40), so
      // the target is 1.6 × 40 = 64 ⇒ rung 80 A. The cap is Iz 42.9 ⇒ the
      // largest rung ≤ 42.9 is 40 A: the device lifts ONE rung (32 → 40) and
      // stops. Copper never moved.
      expect(sys.panels['lp3']!.incomer.breaker.ratingA.amperes, 40);
      expect(f.breaker.ratingA.amperes, 40);
      expect(sys.feederFloorsApplied, isNot(contains('mdp-f-lp3')));
    });

    test('no MDP feeder carries more than 1.6x the ampacity its load needs', () {
      // The blunt copper-inflation guard: every feeder conductor is within one
      // section step of what its own design current asks for.
      for (final c in mdp.circuits) {
        expect(c.cable.deratedIz.amperes / c.designCurrent.amperes,
            lessThan(1.6),
            reason: '${c.name}: Iz ${c.cable.deratedIz.amperes} A for '
                'Ib ${c.designCurrent.amperes} A on ${c.cable.csaMm2} mm2');
      }
    });

    test('every feeder still protects its conductor (In <= Iz)', () {
      for (final c in mdp.circuits) {
        expect(c.breaker.ratingA.amperes,
            lessThanOrEqualTo(c.cable.deratedIz.amperes),
            reason: c.name);
        expect(c.cable.ampacityReached, isTrue, reason: c.name);
      }
    });
  });
}
