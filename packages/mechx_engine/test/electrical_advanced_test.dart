import 'dart:math' as math;

import 'package:mechx_engine/electrical/arc_flash.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/electrode.dart';
import 'package:mechx_engine/electrical/harmonics.dart';
import 'package:mechx_engine/electrical/lightning.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/metering.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/electrical/spd.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// A8 advanced electrical extras — hand-derived seed tests.
///
/// Each expected value is computed from first principles in the comments, NOT
/// read back from the engine, per the "tests are the spec" rule.
void main() {
  const p = PuilProfile();

  // A minimal hand-built circuit result so the harmonics estimator has
  // something to read (it weights by design current and reads neutral CSA).
  ElectricalCircuitResult circuit(
    String id,
    LoadKind kind, {
    required double currentA,
    required bool threePhase,
    double neutralMm2 = 4,
  }) {
    final g = GroundingResult(
      peCsaMm2: 4,
      neutralCsaMm2: neutralMm2,
      cores: 3,
      cableSpec: 'NYM 3x4 mm2',
      cableType: 'NYM',
    );
    return ElectricalCircuitResult(
      circuitId: id,
      name: id,
      loadKind: kind,
      designCurrent: Current(currentA),
      threePhase: threePhase,
      phase: threePhase ? PhaseAssignment.threePhase : PhaseAssignment.l1,
      breaker: const BreakerResult(
        ratingA: Current(16),
        deviceClass: BreakerClass.mcb,
        curve: BreakerCurve.c,
      ),
      cable: const CableResult(
        csaMm2: 2.5,
        baseKha: Current(24),
        deratedIz: Current(24),
        deratingFactor: 1,
        vdDriven: false,
        appliedRule: 'ampacity',
      ),
      voltageDrop: const VoltageDropResult(
        dropV: 1, dropPercent: 0.5, limitPercent: 5, withinLimit: true),
      cumulativeDropPercent: 0.5,
      grounding: g,
      rcd: const RcdSpec(required: false, ratingMa: 0, reason: ''),
    );
  }

  ElectricalPanelResult panel(
    List<ElectricalCircuitResult> circuits, {
    int poles = 4,
  }) {
    const bus = BusbarResult(
      widthMm: 20,
      thicknessMm: 5,
      csaMm2: 100,
      ampacityA: Current(250),
      totalCurrentA: Current(100),
    );
    return ElectricalPanelResult(
      panelId: 'P1',
      name: 'MDP',
      system: poles >= 3 ? ElectricalSystem.threePhase : ElectricalSystem.singlePhase,
      circuits: circuits,
      incomer: IncomerResult(
        breaker: const BreakerResult(
          ratingA: Current(100),
          deviceClass: BreakerClass.mccb,
          curve: BreakerCurve.c,
        ),
        poles: poles,
      ),
      busbar: bus,
      busbarSections: [
        BusbarSectionResult(
          index: 1,
          circuitIds: [for (final c in circuits) c.circuitId],
          ways: circuits.length,
          sectionCurrent: const Current(100),
          busbar: bus,
          manualBreak: false,
        ),
      ],
      neutralPeBars: const NeutralPeBars(
        neutralCsaMm2: 100, neutralAmpacityA: Current(250), peCsaMm2: 50),
      connectedW: 50000,
      demandW: 45000,
      demandCurrent: const Current(100),
      phaseBalance: const PhaseBalanceResult(
        l1: 33, l2: 33, l3: 34, imbalancePercent: 1),
      warnings: const [],
    );
  }

  // ── Harmonics ─────────────────────────────────────────────────────────────
  group('harmonics', () {
    test('no non-linear load → null (nothing to report)', () {
      final res = estimateHarmonics(
        panel([
          circuit('c1', LoadKind.lighting, currentA: 10, threePhase: false),
          circuit('c2', LoadKind.motor, currentA: 20, threePhase: true),
        ]),
        p,
      );
      expect(res, isNull);
    });

    test('neutralOversizeFactor ramps √3 at 100% single-phase', () {
      // f < 0.33 → 1.0 (flat); at f=0.33 → 1.0 (ramp start); at f=1 → √3.
      expect(neutralOversizeFactor(0.2), 1.0);
      expect(neutralOversizeFactor(0.33), closeTo(1.0, 1e-9));
      expect(neutralOversizeFactor(1.0), closeTo(math.sqrt(3), 1e-9));
      // At f=0.5: 1 + ((0.5-0.33)/0.67)·(√3-1) = 1 + 0.253731·0.732051 = 1.18574.
      expect(neutralOversizeFactor(0.5), closeTo(1.18574, 1e-4));
    });

    test('all-UPS single-phase panel → neutral oversize + high THD', () {
      // Two equal UPS circuits (single-phase): non-linear fraction = 1.0,
      // single-phase fraction = 1.0 ≥ 0.33 → oversize; nFactor = √3 ≈ 1.73.
      // Largest neutral = 4 mm²; 4·1.73 = 6.93 → next standard section ≥ 6.93
      // on the ladder [..,4,6,10,..] is 10 mm².
      final res = estimateHarmonics(
        panel(
          [
            circuit('u1', LoadKind.ups, currentA: 20, threePhase: false),
            circuit('u2', LoadKind.ups, currentA: 20, threePhase: false),
          ],
          poles: 4,
        ),
        p,
      )!;
      expect(res.nonLinearFraction, closeTo(1.0, 1e-9));
      expect(res.singlePhaseFraction, closeTo(1.0, 1e-9));
      expect(res.neutralOversizeFactor, closeTo(1.73, 1e-2));
      expect(res.recommendedNeutralCsaMm2, 10);
      expect(res.thdBand, ThdBand.high); // ≥ 0.45
      expect(res.filterRecommended, isTrue); // ≥ 0.6
    });

    test('caller-pinned 3φ VFD fraction → line reactor, no neutral oversize', () {
      // nonLinearFraction = 0.5 on a 3-phase panel → tpFrac = 0.5 ≥ 0.35 reactor,
      // < 0.6 so no filter; spFrac = 0 → no neutral oversize (factor 1.0).
      final res = estimateHarmonics(
        panel(
          [circuit('m1', LoadKind.motor, currentA: 40, threePhase: true)],
          poles: 4,
        ),
        p,
        nonLinearFraction: 0.5,
      )!;
      expect(res.threePhaseFraction, closeTo(0.5, 1e-9));
      expect(res.reactorRecommended, isTrue);
      expect(res.filterRecommended, isFalse);
      expect(res.neutralOversizeFactor, 1.0);
      expect(res.reactorPctZ, recommendedReactorPctZ);
    });
  });

  // ── Arc flash ───────────────────────────────────────────────────────────
  group('arc flash', () {
    test('25 kA, 0.2 s, 400 V, 455 mm → ~4.95 cal/cm², CAT 2', () {
      // E[J/cm²] = 2.142e6 · 0.4 · 25 · 0.2 / 455²
      //          = 2.142e6 · 2.0 / 207025 = 4284000/207025 = 20.6932 J/cm²
      // E[cal/cm²] = 20.6932 / 4.184 = 4.9458 → CAT 2 (≤8).
      // Boundary: 455 · sqrt(4.95/1.2) = 455·2.0301 = 923.7 mm.
      final res = estimateArcFlash(
        faultkA: Current.kiloamperes(25),
        clearingTimeS: 0.2,
      )!;
      expect(res.incidentEnergyCalCm2, closeTo(4.95, 0.01));
      expect(res.ppeCategory, PpeCategory.cat2);
      expect(res.arcFlashBoundaryMm, closeTo(924, 1));
      expect(res.gapMm, defaultGapMm);
    });

    test('10 kA, 0.05 s (fast MCB clearing) → ~0.49 cal/cm², no PPE band', () {
      // E = 2.142e6·0.4·10·0.05/455² = 2.142e6·0.2/207025 = 428400/207025
      //   = 2.0693 J/cm² → /4.184 = 0.4946 cal/cm² < 1.2 → PpeCategory.none.
      final res = estimateArcFlash(
        faultkA: Current.kiloamperes(10),
        clearingTimeS: 0.05,
      )!;
      expect(res.incidentEnergyCalCm2, closeTo(0.49, 0.01));
      expect(res.ppeCategory, PpeCategory.none);
    });

    test('zero fault → null', () {
      expect(
        estimateArcFlash(faultkA: const Current(0), clearingTimeS: 0.2),
        isNull,
      );
    });

    test('ppeCategoryFor boundaries', () {
      expect(ppeCategoryFor(1.0), PpeCategory.none);
      expect(ppeCategoryFor(4.0), PpeCategory.cat1);
      expect(ppeCategoryFor(8.0), PpeCategory.cat2);
      expect(ppeCategoryFor(25.0), PpeCategory.cat3);
      expect(ppeCategoryFor(40.0), PpeCategory.cat4);
      expect(ppeCategoryFor(41.0), PpeCategory.noSafePpe);
    });
  });

  // ── SPD ───────────────────────────────────────────────────────────────────
  group('spd', () {
    test('origin, no LPS → Type 2, common-mode (TN-S)', () {
      final r = recommendSpd(
        atOrigin: true,
        feederDistanceM: 0,
        earthingSystem: 'TN-S',
      );
      expect(r.type, SpdType.type2);
      expect(r.connection, SpdConnection.commonMode);
      expect(r.ucV, ucTnV);
      expect(r.npeUcV, isNull);
      expect(r.recommended, isTrue);
    });

    test('origin with external LPS → Type 1+2', () {
      final r = recommendSpd(
        atOrigin: true,
        feederDistanceM: 0,
        earthingSystem: 'TN-S',
        hasExternalLps: true,
      );
      expect(r.type, SpdType.type1plus2);
      expect(r.iimpKa, 12.5); // carries the partial-lightning impulse current
    });

    test('TT origin → 3+1 with higher N-PE Uc', () {
      final r = recommendSpd(
        atOrigin: true,
        feederDistanceM: 0,
        earthingSystem: 'TT',
      );
      expect(r.connection, SpdConnection.threePlusOne);
      expect(r.npeUcV, ucTtNpeV);
    });

    test('distant sub-board (> 10 m) → Type 2 required', () {
      final r = recommendSpd(
        atOrigin: false,
        feederDistanceM: 25,
        earthingSystem: 'TN-S',
      );
      expect(r.type, SpdType.type2);
      expect(r.recommended, isTrue);
    });

    test('close sub-board (≤ 10 m) → Type 2 optional (not required)', () {
      final r = recommendSpd(
        atOrigin: false,
        feederDistanceM: 5,
        earthingSystem: 'TN-S',
      );
      expect(r.recommended, isFalse);
    });
  });

  // ── Lightning ───────────────────────────────────────────────────────────
  group('lightning', () {
    test('collectionArea of an isolated box', () {
      // L=40, W=20, H=15 → 3H=45.
      // Ad = 40·20 + 2·45·(40+20) + π·45²
      //    = 800 + 5400 + π·2025 = 800 + 5400 + 6361.725 = 12561.725 m².
      final ad = collectionArea(40, 20, 15);
      expect(ad, closeTo(12561.73, 0.1));
    });

    test('large area, Ng=12 → LPS required, level I', () {
      // Ad = 10000 m², Ng=12, Cd=1 → Nd = 12·10000·1·1e-6 = 0.12 /yr.
      // Nd (0.12) > Nc (1e-3) → LPS required.
      // E = 1 − 1e-3/0.12 = 1 − 0.008333 = 0.99167 > 0.95 → level I.
      final r = assessLightning(groundFlashDensity: 12, areaM2: 10000);
      expect(r.eventsPerYear, closeTo(0.12, 1e-5));
      expect(r.lpsRequired, isTrue);
      expect(r.efficiency, closeTo(0.992, 1e-3));
      expect(r.level, LpsLevel.i);
    });

    test('small footprint → no LPS', () {
      // Ad = 50 m², Ng=12 → Nd = 12·50·1e-6 = 6e-4 < 1e-3 → no LPS.
      final r = assessLightning(groundFlashDensity: 12, areaM2: 50);
      expect(r.eventsPerYear, closeTo(6e-4, 1e-6));
      expect(r.lpsRequired, isFalse);
      expect(r.level, isNull);
      expect(r.efficiency, 0);
    });

    test('lpsLevelForEfficiency bands', () {
      expect(lpsLevelForEfficiency(0.0), isNull);
      expect(lpsLevelForEfficiency(0.85), LpsLevel.iii);
      expect(lpsLevelForEfficiency(0.92), LpsLevel.ii);
      expect(lpsLevelForEfficiency(0.99), LpsLevel.i);
      expect(lpsLevelForEfficiency(0.80), LpsLevel.iv);
    });
  });

  // ── Metering ──────────────────────────────────────────────────────────────
  group('metering', () {
    test('80 A → direct (whole-current)', () {
      final m = meterFor(const Current(80));
      expect(m.metering, MeteringKind.direct);
      expect(m.ctRatio, isNull);
    });

    test('exactly 100 A → still direct (≤ limit)', () {
      expect(meterFor(const Current(100)).metering, MeteringKind.direct);
    });

    test('130 A → CT, primary 150 (next ladder step ≥ 130), class 0.5S', () {
      // CT_PRIMARY ladder = [50,75,100,150,...]; first ≥ 130 is 150.
      final m = meterFor(const Current(130));
      expect(m.metering, MeteringKind.ct);
      expect(m.ctPrimaryA, 150);
      expect(m.ctRatio, '150/5');
      expect(m.ctClass, '0.5S');
    });

    test('huge demand beyond ladder → clamps to last primary', () {
      final m = meterFor(const Current(5000));
      expect(m.ctPrimaryA, 2500); // last entry
      expect(m.ctRatio, '2500/5');
    });
  });

  // ── Earth electrode ───────────────────────────────────────────────────────
  group('electrode', () {
    test('single rod 100 Ω·m, 3 m × 16 mm (Dwight)', () {
      // R = ρ/(2πL)·(ln(8L/d) − 1), d = 0.016 m.
      // = 100/(2π·3)·(ln(24/0.016) − 1) = 100/18.8496·(ln(1500) − 1)
      // = 5.30516·(7.31322 − 1) = 5.30516·6.31322 = 33.4927 Ω.
      final r = singleRodResistance(100, 3, 16);
      expect(r, closeTo(33.49, 0.01));
    });

    test('moist loam 100 Ω·m, target 5 Ω → multi-rod array', () {
      // single rod ≈ 33.49 Ω. rawCount = ceil(33.49/(5·0.8)) = ceil(8.373) = 9.
      // η(9): interpolate between (8,0.73) and (10,0.70): 0.73 + 0.5·(−0.03)
      //      = 0.715. achieved = 33.49/(9·0.715) = 33.49/6.435 = 5.205 Ω.
      // 5.205 > 5 → still just above target (honest result).
      final d = designElectrode(soilResistivityOhmM: 100);
      expect(d.singleRod.ohms, closeTo(33.49, 0.01));
      expect(d.rodCount, 9);
      expect(d.achieved.ohms, closeTo(5.205, 0.01));
      expect(d.meetsTarget, isFalse);
      expect(d.targetOhm, 5);
    });

    test('marshy 30 Ω·m → 3 rods meet 5 Ω', () {
      // single rod = 30/(2π·3)·(ln1500 − 1) = 1.59155·6.31322 = 10.0478 Ω.
      // rawCount = ceil(10.0478/4) = ceil(2.512) = 3. η(3)=0.82.
      // achieved = 10.0478/(3·0.82) = 10.0478/2.46 = 4.085 Ω ≤ 5 → meets.
      final d = designElectrode(soilResistivityOhmM: 30);
      expect(d.singleRod.ohms, closeTo(10.05, 0.01));
      expect(d.rodCount, 3);
      expect(d.achieved.ohms, closeTo(4.085, 0.01));
      expect(d.meetsTarget, isTrue);
    });

    test('utilisationFactor interpolation', () {
      expect(utilisationFactor(1), 1.0);
      expect(utilisationFactor(4), 0.80);
      expect(utilisationFactor(9), closeTo(0.715, 1e-9)); // mid 8→10
      expect(utilisationFactor(20), 0.70); // clamps to last
    });

    test('custom target loosens the array', () {
      // target 10 Ω in 100 Ω·m: rawCount = ceil(33.49/(10·0.8)) = ceil(4.186) = 5.
      final d = designElectrode(soilResistivityOhmM: 100, targetOhm: 10);
      expect(d.rodCount, 5);
      expect(d.meetsTarget, isTrue);
    });
  });

  // ── Honesty surface ─────────────────────────────────────────────────────
  test('every result carries a non-empty verifyItems list', () {
    expect(
      estimateHarmonics(
        panel([circuit('u', LoadKind.ups, currentA: 10, threePhase: false)]),
        p,
      )!.verifyItems,
      isNotEmpty,
    );
    expect(
      estimateArcFlash(faultkA: Current.kiloamperes(20), clearingTimeS: 0.1)!
          .verifyItems,
      isNotEmpty,
    );
    expect(
      recommendSpd(atOrigin: true, feederDistanceM: 0, earthingSystem: 'TT')
          .verifyItems,
      isNotEmpty,
    );
    expect(
      assessLightning(groundFlashDensity: 12, areaM2: 10000).verifyItems,
      isNotEmpty,
    );
    expect(meterFor(const Current(130)).verifyItems, isNotEmpty);
    expect(designElectrode(soilResistivityOhmM: 100).verifyItems, isNotEmpty);
  });
}
