/// Tests for the two sizing-MUTATING folds in the electrical engine:
///   FOLD 1 — busbar short-circuit WITHSTAND: the bar is floored at the
///     cross-section the prospective fault's Icw demands (IEC 61439-1 §9.3), so
///     it grows to SURVIVE the fault, not merely carry the load.
///   FOLD 2 — harmonics triplen-NEUTRAL oversize: a panel whose single-phase
///     non-linear (VFD/soft-starter/UPS/welding) share crosses the triplen
///     threshold gets an oversized neutral bar (IEC 60364-5-52 §523.6.3 / Annex
///     E).
///
/// Expected values are hand-derived from first principles using the constants in
/// `PuilProfile` + `busbar.dart` + `harmonics.dart`, NOT magic numbers. Each fold
/// also has a REGRESSION-GUARD test proving an unaffected panel is byte-identical
/// to today's load-only / full-size-neutral sizing.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/busbar.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const p = PuilProfile();

  // ────────────────────────────────────────────────────────────────────────
  // FOLD 1 — busbar short-circuit withstand.
  // ────────────────────────────────────────────────────────────────────────

  group('FOLD 1 — minCsaForWithstand / checkBusbarWithstand (pure)', () {
    test('minCsaForWithstand inverts Icw = density·CSA/√t (density 80 A/mm²)', () {
      // 25 kA, 1 s: CSA_min = 25000·√1 / 80 = 312.5 mm².
      expect(minCsaForWithstand(p, 25), closeTo(312.5, 1e-9));
      // 25 kA, 0.1 s: CSA_min = 25000·√0.1 / 80 = 98.82 mm² (faster clear → less).
      expect(minCsaForWithstand(p, 25, durationS: 0.1),
          closeTo(25000 * math.sqrt(0.1) / 80, 1e-9));
      // No fault → no floor.
      expect(minCsaForWithstand(p, 0), 0);
    });

    test('checkBusbarWithstand: Icw, peak factor (Table 7), adequacy', () {
      // 500 mm² bar @ 25 kA, 1 s: Icw = 80·500/1000 = 40 kA ≥ 25 ⇒ adequate.
      final w = checkBusbarWithstand(p, 500, 25);
      expect(w.icwKa, closeTo(40, 1e-9));
      expect(w.adequate, isTrue);
      expect(w.marginKa, closeTo(15, 1e-9)); // 40 − 25
      // 20 < 25 ≤ 50 kA band ⇒ n = 2.1; Ipk = 2.1·25 = 52.5 kA.
      expect(w.peakFactor, 2.1);
      expect(w.ipkKa, closeTo(52.5, 1e-9));

      // 250 mm² bar @ 25 kA: Icw = 20 kA < 25 ⇒ inadequate.
      expect(checkBusbarWithstand(p, 250, 25).adequate, isFalse);
    });

    test('the result echoes the clearing-time basis it was sized on (durationS)',
        () {
      // The adequacy verdict scales by 1/√t, so the basis must be explicit and
      // not silently mixed: the result carries the durationS it used.
      expect(checkBusbarWithstand(p, 500, 25).durationS, closeTo(1, 1e-9));
      expect(checkBusbarWithstand(p, 500, 25, durationS: 0.1).durationS,
          closeTo(0.1, 1e-9));
    });

    test('peak-factor bands rise with the fault level (IEC 61439-1 Table 7)', () {
      expect(p.busbarPeakFactor(5), 1.5); // ≤ 5
      expect(p.busbarPeakFactor(10), 1.7); // ≤ 10
      expect(p.busbarPeakFactor(20), 2.0); // ≤ 20
      expect(p.busbarPeakFactor(50), 2.1); // ≤ 50
      expect(p.busbarPeakFactor(80), 2.2); // > 50
    });

    test('sizeBusbar floors the bar at the withstand CSA when faultKa > 0', () {
      // A 200 A bar alone is 60 mm² (the load-only pick). At 25 kA the withstand
      // floor is 312.5 mm², so the smallest bar with ampacity ≥ 200 AND
      // CSA ≥ 312.5 is the 500 mm² / 800 A bar.
      final b = sizeBusbar(p, const Current(200), faultKa: 25);
      expect(b.csaMm2, 500);
      expect(b.ampacityA.amperes, 800);
      expect(b.sizingReason, BusbarSizingReason.withstand);
      expect(b.withstand!.adequate, isTrue);
      expect(b.withstand!.icwKa, closeTo(40, 1e-9));
    });

    test('regression: sizeBusbar with no fault is byte-identical to today', () {
      // Same inputs as the existing busbar seed test — must be UNCHANGED.
      final b = sizeBusbar(p, const Current(200));
      expect(b.csaMm2, 60); // 20×3, 200 A — the load-only bar
      expect(b.ampacityA.amperes, 200);
      expect(b.sizingReason, BusbarSizingReason.ampacity);
      expect(b.withstand, isNull); // no withstand reported when no fault
    });
  });

  group('FOLD 1 — computeSystem busbar withstand integration', () {
    // A single 3φ MDP, demand ≈ 27.1 A → incomer 32 A → load-only main bus is
    // the 24 mm² / 110 A bar (≥ 32 A). (Identical panel to the compute seed
    // test, so the load-only sizing is the documented baseline.)
    const panel = ElectricalPanel(
      id: 'LP1',
      name: 'LP-1',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
            id: 'c1',
            name: 'Lighting',
            loadKind: LoadKind.lighting,
            isLighting: true,
            loadW: 1800,
            cosPhi: 0.9,
            length: Length(20)),
        ElectricalCircuit(
            id: 'c2',
            name: 'Sockets',
            loadKind: LoadKind.socket,
            loadW: 3000,
            cosPhi: 0.9,
            length: Length(20)),
        ElectricalCircuit(
            id: 'c3',
            name: 'Motor',
            loadKind: LoadKind.motor,
            motorKw: 7.5,
            cosPhi: 0.85,
            length: Length(30)),
      ],
    );
    const project = ElectricalProject(
      id: 'pr',
      name: 'B',
      panels: [panel],
      earthingSystem: EarthingSystem.tnCs,
    );

    test('(1) load-sized bar inadequate for the fault → UPSIZED, reason=withstand',
        () {
      // Origin 25 kA at the (utility-fed) root bus. Withstand floor = 312.5 mm²,
      // so the 24 mm² load-only bar is upsized to the 500 mm² / 800 A bar.
      final sys =
          computeSystem(p, project, originFaultLevel: Current.kiloamperes(25));
      final b = sys.panels['LP1']!.busbar;
      expect(b.csaMm2, 500);
      expect(b.sizingReason, BusbarSizingReason.withstand);
      expect(b.withstand, isNotNull);
      // Icw(500, 1 s) = 40 kA ≥ 25 ⇒ adequate, margin 15 kA, Ipk 52.5 kA.
      expect(b.withstand!.icwKa, closeTo(40, 1e-9));
      expect(b.withstand!.adequate, isTrue);
      expect(b.withstand!.marginKa, closeTo(15, 1e-9));
      expect(b.withstand!.ipkKa, closeTo(52.5, 1e-9));
      // Every section bar is floored the same way (one section here).
      for (final s in sys.panels['LP1']!.busbarSections) {
        expect(s.busbar.csaMm2, greaterThanOrEqualTo(312.5));
        expect(s.busbar.withstand!.adequate, isTrue);
      }
      // No inadequacy warning (the bar survives).
      expect(
        sys.warnings.where((w) => w.code == 'busbar-withstand-inadequate'),
        isEmpty,
      );
    });

    test('(2) regression guard — no fault level → bar UNCHANGED vs today', () {
      final sys = computeSystem(p, project); // no originFaultLevel
      final b = sys.panels['LP1']!.busbar;
      // The documented load-only bar from the compute seed test.
      expect(b.csaMm2, 24);
      expect(b.ampacityA.amperes, 110);
      expect(b.sizingReason, BusbarSizingReason.ampacity);
      expect(b.withstand, isNull);
      // Neutral + PE unchanged too (no harmonics → full-size neutral).
      expect(sys.panels['LP1']!.neutralPeBars.neutralCsaMm2, 24);
      expect(sys.panels['LP1']!.neutralPeBars.peCsaMm2, 16);
      expect(
        sys.warnings.where((w) => w.code == 'busbar-withstand-inadequate'),
        isEmpty,
      );
    });

    test('a very high fault grows the bar beyond the table to stay adequate', () {
      // 100 kA, 1 s needs CSA ≥ 100000/80 = 1250 mm² — beyond the largest
      // tabulated bar (1000 mm²), so the density-estimate branch produces a
      // 1250 mm² bar (widthMm/thicknessMm = 0) whose Icw = 80·1250/1000 = 100 kA
      // exactly meets the fault. The fold grows the bar to SURVIVE rather than
      // capping at the table and flagging inadequate.
      const tiny = ElectricalPanel(
        id: 'T',
        name: 'T',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
              id: 't1',
              name: 'L',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 500,
              cosPhi: 0.9,
              length: Length(10)),
        ],
      );
      final sys = computeSystem(
        p,
        const ElectricalProject(id: 'x', name: 'x', panels: [tiny]),
        originFaultLevel: Current.kiloamperes(100),
      );
      final b = sys.panels['T']!.busbar;
      expect(b.csaMm2, 1250); // density estimate beyond the table
      expect(b.widthMm, 0);
      expect(b.thicknessMm, 0);
      expect(b.sizingReason, BusbarSizingReason.withstand);
      expect(b.withstand!.icwKa, closeTo(100, 1e-9));
      expect(b.withstand!.adequate, isTrue);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // FOLD 2 — harmonics triplen-neutral oversize.
  // ────────────────────────────────────────────────────────────────────────

  group('FOLD 2 — sizeNeutralPeBars triplen oversize (pure)', () {
    test('factor 1.73 steps a 24 mm² phase bar up the ladder to 50 mm²', () {
      // √3 ≈ 1.732; target = 24·1.732 = 41.57 → next standard section ≥ = 50.
      final n = sizeNeutralPeBars(24, const Current(110),
          profile: p, neutralOversizeFactor: 1.73, triplenFraction: 1.0);
      expect(n.neutralCsaMm2, 50);
      expect(n.neutralOversizeFactor, 1.73);
      expect(n.triplenFraction, 1.0);
      expect(n.peCsaMm2, 16); // PE unchanged (16 < 24 ≤ 35 ⇒ 16)
      // The bar's continuous rating still tracks the phase bar.
      expect(n.neutralAmpacityA.amperes, 110);
    });

    test('regression: factor 1.0 → neutral = phase bar (byte-identical)', () {
      final n = sizeNeutralPeBars(24, const Current(110), profile: p);
      expect(n.neutralCsaMm2, 24);
      expect(n.neutralOversizeFactor, 1);
      expect(n.triplenFraction, 0);
      // Same as the no-profile call the orchestrator made before this fold.
      final old = sizeNeutralPeBars(24, const Current(110));
      expect(n.neutralCsaMm2, old.neutralCsaMm2);
      expect(n.peCsaMm2, old.peCsaMm2);
    });
  });

  group('FOLD 2 — computeSystem neutral oversize integration', () {
    test('(3) VFD-heavy single-phase panel → neutral oversized by ~√3', () {
      // A single-phase board with ONE non-linear way (a UPS) → the single-phase
      // non-linear share is 1.0 → neutralOversizeFactor(1.0) = √3 ≈ 1.73.
      const upsPanel = ElectricalPanel(
        id: 'U',
        name: 'UPS Board',
        system: ElectricalSystem.singlePhase,
        voltage: Voltage(220),
        circuits: [
          ElectricalCircuit(
              id: 'u1',
              name: 'IT UPS',
              loadKind: LoadKind.ups,
              loadW: 4000,
              cosPhi: 0.9,
              length: Length(15)),
        ],
      );
      final sys = computeSystem(
          p, const ElectricalProject(id: 'u', name: 'u', panels: [upsPanel]));
      final pr = sys.panels['U']!;
      final phaseBar = pr.busbar.csaMm2;
      final npe = pr.neutralPeBars;
      // factor = √3 rounded 2 dp = 1.73.
      expect(npe.neutralOversizeFactor, 1.73);
      expect(npe.triplenFraction, 1.0);
      // Neutral = smallest standard section ≥ phaseBar·1.73.
      final target = phaseBar * 1.73;
      final expectedN =
          p.standardSectionsMm2.firstWhere((s) => s >= target);
      expect(npe.neutralCsaMm2, expectedN);
      expect(npe.neutralCsaMm2, greaterThan(phaseBar));
      // Surfaced as a warning so it reaches the schedule.
      expect(
        sys.warnings.map((w) => w.code),
        contains('harmonics-neutral-oversize'),
      );
    });

    test('(4) regression guard — linear panel → neutral UNCHANGED (= phase bar)',
        () {
      // Same board but a LINEAR socket load → no non-linear share → factor 1.0.
      const linPanel = ElectricalPanel(
        id: 'L',
        name: 'Linear Board',
        system: ElectricalSystem.singlePhase,
        voltage: Voltage(220),
        circuits: [
          ElectricalCircuit(
              id: 'l1',
              name: 'Sockets',
              loadKind: LoadKind.socket,
              loadW: 4000,
              cosPhi: 0.9,
              length: Length(15)),
        ],
      );
      final sys = computeSystem(
          p, const ElectricalProject(id: 'l', name: 'l', panels: [linPanel]));
      final pr = sys.panels['L']!;
      final npe = pr.neutralPeBars;
      expect(npe.neutralOversizeFactor, 1);
      expect(npe.triplenFraction, 0);
      expect(npe.neutralCsaMm2, pr.busbar.csaMm2); // full-size = phase bar
      expect(
        sys.warnings.where((w) => w.code == 'harmonics-neutral-oversize'),
        isEmpty,
      );
    });

    test('a THREE-phase VFD load does NOT trigger the triplen-neutral oversize',
        () {
      // Triplen harmonics sum in the neutral only for SINGLE-phase non-linear
      // load; a 3φ VFD motor is a balanced 5th/7th source, no neutral oversize.
      const vfdPanel = ElectricalPanel(
        id: 'V',
        name: 'VFD Board',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
              id: 'v1',
              name: 'VFD pump',
              loadKind: LoadKind.pump,
              motorKw: 11,
              cosPhi: 0.85,
              length: Length(20),
              starterType: StarterType.vfd),
        ],
      );
      final sys = computeSystem(
          p, const ElectricalProject(id: 'v', name: 'v', panels: [vfdPanel]));
      final npe = sys.panels['V']!.neutralPeBars;
      expect(npe.neutralOversizeFactor, 1);
      expect(npe.neutralCsaMm2, sys.panels['V']!.busbar.csaMm2);
    });
  });
}
