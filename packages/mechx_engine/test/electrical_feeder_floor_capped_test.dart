/// G3 — THE CAPPED SELECTIVITY RESIDUAL EXPLAINS ITSELF.
///
/// The feeder floor is DEVICE-ONLY and capped at the largest rung the LOAD-sized
/// cable's derated Iz protects (`In ≤ Iz` always wins). Where that cap bites the
/// residual non-/partial-selectivity is real and stays reported — but the old
/// message only said "verify against the manufacturer curves", which reads as
/// "fit a bigger breaker": precisely the move the engine forbids. The real lever
/// is the CABLE, and nothing named it.
///
/// So `computeSystem` now records `ElectricalSystemResult.feederFloorsCapped`
/// (the feeders the cap held back) and `faultStudy` branches those pairs'
/// message onto the cap + its two numbers + the cable lever. Nothing about the
/// SIZING changes: same breaker, same cable, same warning codes and severities.
///
/// Every expected value is hand-derived from the `PuilProfile` tables:
///   - breaker ladder: 6 10 16 20 25 32 40 50 63 | 80 100 125 160 200 250 315
///     400 500 630 800 1000 1250 1600 A;
///   - KHA, Cu/PVC, reference method B1 (conduit): 4→34, 10→60, 16→80,
///     300→500 A;
///   - derating at the panel defaults (30 °C air, grouping 1, conduit) = 1.0;
///   - PUIL continuous-load factor 1.25 (Iz ≥ max(In, 1.25·Ib));
///   - 3φ trunk minimum section 4 mm².
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

ElectricalCircuitResult _way(ElectricalPanelResult r, String id) =>
    r.circuits.firstWhere((c) => c.circuitId == id);

/// MDP --f1--> SP, SP carrying ONE three-phase heater at cosφ 1.0 so every
/// current in the chain is a closed-form `P / (√3·V)`.
ElectricalProject _twoBoard({required double loadW, Current? feederOverride}) =>
    ElectricalProject(
      id: 'pr',
      name: 'Building',
      earthingSystem: EarthingSystem.tnS,
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'Main',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          circuits: [
            ElectricalCircuit(
              id: 'f1',
              name: 'Feeder to SP',
              loadKind: LoadKind.feeder,
              cosPhi: 1.0,
              length: const Length(25),
              feedsPanelId: 'SP',
              breakerOverrideA: feederOverride,
            ),
          ],
        ),
        ElectricalPanel(
          id: 'SP',
          name: 'Sub',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f1',
          circuits: [
            ElectricalCircuit(
              id: 's1',
              name: 'Heater',
              loadKind: LoadKind.heating,
              loadW: loadW,
              cosPhi: 1.0,
              phases: 3,
              length: const Length(10),
            ),
          ],
        ),
      ],
    );

String _nonSelectiveMessage(FaultStudyResult fs) =>
    fs.warnings.singleWhere((w) => w.code == 'non-selective').message;

void main() {
  // ── (A) the cap bites, and the 1.6× target IS on the ladder ───────────────
  group('(A) a capped floor names the cap, its numbers and the cable lever', () {
    // SP: 35 kW 3φ at cosφ 1.0 ⇒ Ib = 35 000 / (√3·400) = 50.518 A → 50.5 A.
    //   A 3φ way loads all three lines ⇒ SP demand current 50.5 A ⇒ SP INCOMER
    //   = first rung ≥ 50.5 = 63 A.
    // f1 carries SP's diversified demand 35 000 W at cosφ 1.0 ⇒ the same
    //   50.518 A ⇒ the LOAD-sized device is 63 A (pass 1: ratio 1.0).
    // CABLE (load-sized, derating 1.00): Iz ≥ max(63, 1.25 × 50.518 = 63.15)
    //   = 63.15 A ⇒ 10 mm² (60 A) is short, 16 mm² (80 A) carries it ⇒ Iz 80.0.
    // FLOOR target = 1.6 × 63 = 100.8 A ⇒ floor RUNG = first ≥ 100.8 = 125 A.
    // CAP = largest rung ≤ Iz 80 = 80 A. 125 > 80 ⇒ THE CAP BITES: the device
    //   lifts 63 → 80 and stops, at 80/63 = 1.27× — still non-selective.
    final project = _twoBoard(loadW: 35000);
    final sys = computeSystem(p, project);
    final feeder = _way(sys.panels['MDP']!, 'f1');

    test('premise: the sizing is exactly the E3/E4 policy answer', () {
      expect(sys.panels['SP']!.incomer.breaker.ratingA.amperes, 63);
      expect(feeder.breaker.ratingA.amperes, 80);
      expect(feeder.cable.csaMm2, 16);
      expect(feeder.cable.deratedIz.amperes, closeTo(80.0, 1e-9));
      // In ≤ Iz — the inviolable rule that produced the cap.
      expect(feeder.breaker.ratingA.amperes,
          lessThanOrEqualTo(feeder.cable.deratedIz.amperes));
    });

    test('feederFloorsCapped names it; feederFloorsApplied does not', () {
      expect(sys.feederFloorsCapped, {'f1'});
      expect(sys.feederFloorsApplied, isEmpty);
      // The two sets are disjoint by construction (a capped floor never lands).
      expect(
          sys.feederFloorsCapped.intersection(sys.feederFloorsApplied), isEmpty);
    });

    test('the non-selective message names the cap, the CSA, the Iz and the '
        'cable lever', () {
      final msg = _nonSelectiveMessage(faultStudy(sys, project, p));
      expect(
        msg,
        'Feeder to SP (80 A) may not discriminate with Sub incomer (63 A): '
        'the device is already at the largest rung the 16 mm2 feeder cable '
        'protects (Iz 80.0 A). To reach the 1.6x target, increase the feeder '
        'cable (then the device can rise); verify against manufacturer curves '
        'otherwise.',
      );
      // The message the user could act on wrongly is GONE: nothing tells them
      // to raise the device, and the cable is named.
      expect(msg, isNot(contains('ratio <')));
      expect(msg, contains('increase the feeder cable'));
      // ASCII only — the sheets and the Roboto canvas render this text.
      expect(msg.codeUnits.every((u) => u < 128), isTrue, reason: msg);
    });

    test('only the WORDING changed — the verdict, code and severity hold', () {
      final fs = faultStudy(sys, project, p);
      final w = fs.warnings.singleWhere((x) => x.code == 'non-selective');
      expect(w.severity, WarningSeverity.warning);
      expect(w.panelId, 'MDP');
      expect(w.circuitId, 'f1');
      expect(fs.selectivity.single.nonSelective, isTrue);
      expect(fs.selectivity.single.zone, SelectivityZone.nonSelective);
      expect(fs.warnings.where((x) => x.code == 'selectivity-partial'), isEmpty);
    });
  });

  // ── (B) the floor FITS ⇒ nothing is capped, nothing is reworded ───────────
  group('(B) a floor that lands leaves the capped set empty', () {
    // SP: 5 kW 3φ at cosφ 1.0 ⇒ Ib = 5000 / (√3·400) = 7.2169 A → 7.2 A ⇒
    //   SP INCOMER = first rung ≥ 7.2 = 10 A. f1 carries the same ⇒ 10 A.
    // CABLE: Iz ≥ max(10, 1.25 × 7.2169 = 9.02) = 10 A, but the 3φ trunk
    //   minimum 4 mm² (Iz 34.0 A) already clears it ⇒ 4 mm², Iz 34.0.
    // FLOOR target = 1.6 × 10 = 16 A ⇒ rung 16 A. CAP = largest ≤ 34 = 32 A.
    //   16 ≤ 32 ⇒ the floor stands in full: APPLIED, not capped.
    final project = _twoBoard(loadW: 5000);
    final sys = computeSystem(p, project);

    test('applied, not capped', () {
      expect(_way(sys.panels['MDP']!, 'f1').breaker.ratingA.amperes, 16);
      expect(sys.feederFloorsApplied, {'f1'});
      expect(sys.feederFloorsCapped, isEmpty);
    });

    test('and the pair raises no selectivity finding at all', () {
      final fs = faultStudy(sys, project, p);
      // 16 / 10 = 1.60 ⇒ the partial boundary, and the advisory is suppressed
      // because the sizer reached its own target (feederFloorsApplied).
      expect(fs.selectivity.single.zone, SelectivityZone.partial);
      expect(fs.warnings.map((w) => w.code),
          isNot(contains('selectivity-partial')));
      expect(fs.warnings.map((w) => w.code), isNot(contains('non-selective')));
    });
  });

  // ── (C) an UNCAPPED genuine non-selective pair keeps the OLD wording ──────
  group('(C) an overridden feeder is never floored, so it is never capped', () {
    // The same 35 kW board, but the engineer pins f1 at 63 A. An overridden
    // feeder is excluded from the floor map entirely (`computeSystem`), so it
    // can never be capped — the residual 63/63 = 1.0 non-selectivity is the
    // ENGINEER's, and the legacy "verify against the manufacturer curves"
    // wording is exactly right for it (raising the device IS the lever here:
    // Iz is 80 A, so 80 A would fit).
    final project = _twoBoard(loadW: 35000, feederOverride: const Current(63));
    final sys = computeSystem(p, project);

    test('the override stands and nothing is recorded on either set', () {
      final feeder = _way(sys.panels['MDP']!, 'f1');
      expect(feeder.breaker.ratingA.amperes, 63);
      expect(feeder.breaker.overridden, isTrue);
      expect(sys.feederFloorsApplied, isEmpty);
      expect(sys.feederFloorsCapped, isEmpty);
    });

    test('the message is byte-identical to the pre-G3 wording', () {
      expect(
        _nonSelectiveMessage(faultStudy(sys, project, p)),
        'Feeder to SP (63 A) may not discriminate with Sub incomer (63 A): '
        'ratio < 1.6× — verify against the manufacturer time-current '
        '/ let-through curves.',
      );
    });
  });

  // ── (D) the 1.6× target itself above the ladder top ⇒ honest variant ──────
  group('(D) when no cable can reach the target, the message says so', () {
    // SP: 830 kW 3φ at cosφ 1.0 ⇒ Ib = 830 000 / (√3·400) = 1198.0018 A →
    //   1198.0 A ⇒ SP INCOMER = first rung ≥ 1198.0 = 1250 A; f1 the same.
    // CABLE: Iz ≥ max(1250, 1.25 × 1198.0018 = 1497.5) = 1497.5 A. One run tops
    //   out at 300 mm² (500 A), two at 1000 A ⇒ 3 parallel runs of 300 mm²
    //   ⇒ Iz = 3 × 500 = 1500.0 A.
    // FLOOR target = 1.6 × 1250 = 2000 A — ABOVE the 1600 A ladder top, so the
    //   floor rung clamps to 1600 A. CAP = largest rung ≤ 1500 = 1250 A.
    //   1600 > 1500 ⇒ the cap bites (the device never leaves 1250 A), but even
    //   an infinite cable only buys the 1600 A top rung = 1.28× — so the advice
    //   must NOT be "increase the cable to reach 1.6×".
    final project = _twoBoard(loadW: 830000);
    final sys = computeSystem(p, project);

    test('premise: 3 x 300 mm2 at Iz 1500 A, device held at 1250 A', () {
      final feeder = _way(sys.panels['MDP']!, 'f1');
      expect(sys.panels['SP']!.incomer.breaker.ratingA.amperes, 1250);
      expect(feeder.breaker.ratingA.amperes, 1250);
      expect(feeder.cable.csaMm2, 300);
      expect(feeder.cable.runsPerPhase, 3);
      expect(feeder.cable.deratedIz.amperes, closeTo(1500.0, 1e-9));
      expect(sys.feederFloorsCapped, {'f1'});
      expect(sys.feederFloorsApplied, isEmpty);
    });

    test('the message states the target is beyond the largest frame', () {
      final msg = _nonSelectiveMessage(faultStudy(sys, project, p));
      expect(
        msg,
        'Feeder to SP (1250 A) may not discriminate with Sub incomer (1250 A): '
        'the device is already at the largest rung the 300 mm2 feeder cable '
        'protects (Iz 1500.0 A). The 1.6x target (2000 A) is itself beyond the '
        'largest standard frame (1600 A), so no cable increase reaches it - '
        'split the load or verify against manufacturer curves.',
      );
      // The claim the other variant makes would be FALSE here, so it is absent.
      expect(msg, isNot(contains('increase the feeder cable')));
      expect(msg.codeUnits.every((u) => u < 128), isTrue, reason: msg);
    });
  });

  // ── (E) a legacy-constructed result reworks nothing ───────────────────────
  test('(E) an empty feederFloorsCapped keeps every message as it was', () {
    final project = _twoBoard(loadW: 35000);
    final sys = computeSystem(p, project);
    // Rebuild the SAME result with the G3 set dropped (what a result
    // constructed the legacy way looks like) — the wording reverts verbatim.
    final legacy = ElectricalSystemResult(
      projectId: sys.projectId,
      panels: sys.panels,
      order: sys.order,
      totalDemandW: sys.totalDemandW,
      supply: sys.supply,
      earthing: sys.earthing,
      warnings: sys.warnings,
      feederFloorsApplied: sys.feederFloorsApplied,
    );
    expect(legacy.feederFloorsCapped, isEmpty);
    expect(
      _nonSelectiveMessage(faultStudy(legacy, project, p)),
      'Feeder to SP (80 A) may not discriminate with Sub incomer (63 A): '
      'ratio < 1.6× — verify against the manufacturer time-current '
      '/ let-through curves.',
    );
  });
}
