import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Seed tests for earthing / RCD policy (A3 ▸2b).
void main() {
  const p = PuilProfile();

  group('recommendedRcdType', () {
    test('VFD → Type B (smooth DC)', () {
      expect(recommendedRcdType(LoadKind.motor, hasVfd: true).type, RcdType.b);
    });
    test('EV charger → Type B', () {
      expect(recommendedRcdType(LoadKind.evCharger).type, RcdType.b);
    });
    test('socket / general → Type A (never AC)', () {
      expect(recommendedRcdType(LoadKind.socket).type, RcdType.a);
      expect(recommendedRcdType(LoadKind.general).type, RcdType.a);
    });
    test('rank ordering AC<A<F<B', () {
      expect(rcdTypeRank(RcdType.ac) < rcdTypeRank(RcdType.a), isTrue);
      expect(rcdTypeRank(RcdType.f) < rcdTypeRank(RcdType.b), isTrue);
    });
  });

  group('sizeGrounding (cable make-up)', () {
    test('1φ general 4 mm² → L+N+PE, 3 cores, NYM', () {
      final g =
          sizeGrounding(p, phaseCsaMm2: 4, threePhase: false, cableType: 'NYM');
      expect(g.peCsaMm2, 4); // S ≤ 16 → PE = S
      expect(g.neutralCsaMm2, 4);
      expect(g.cores, 3); // 1L + N + PE
      expect(g.cableSpec, 'NYM 3×4 mm²'); // 4(L)+4(N)+4(PE) grouped
      expect(g.cableType, 'NYM');
    });

    test('3φ 50 mm² with neutral → 3L+N+PE, 5 cores, reduced PE 25', () {
      final g = sizeGrounding(p, phaseCsaMm2: 50, threePhase: true);
      expect(g.peCsaMm2, 25); // 50 > 35 → S/2
      expect(g.neutralCsaMm2, 50);
      expect(g.cores, 5);
      expect(g.cableSpec, 'NYY 4×50 + 25 mm²'); // 3L+N at 50, PE 25
    });

    test('3φ motor, no neutral → 3L+PE, 4 cores', () {
      final g = sizeGrounding(p, phaseCsaMm2: 25, threePhase: true, hasNeutral: false);
      expect(g.neutralCsaMm2, 0);
      expect(g.cores, 4); // 3L + PE
      expect(g.peCsaMm2, 16); // 16 < 25 ≤ 35 → 16
      expect(g.cableSpec, 'NYY 3×25 + 16 mm²');
    });

    test('parallel runs prefix the spec', () {
      final g = sizeGrounding(p,
          phaseCsaMm2: 50, threePhase: true, runsPerPhase: 2);
      expect(g.cableSpec, startsWith('2× NYY'));
    });
  });

  group('computeEarthing', () {
    test('TT requires RCD; main earthing/bonding from supply PE', () {
      final e = computeEarthing(p, system: EarthingSystem.tt, supplyPeMm2: 50);
      expect(e.requiresRcd, isTrue);
      expect(e.label, 'TT');
      expect(e.mainEarthingConductorMm2, 50); // clamp(50,16..50)
      expect(e.mainBondingConductorMm2, 25); // max(6,25) capped 25
      expect(e.electrodeResistanceTarget.ohms, 5.0);
    });

    test('TN-C-S does not require an RCD by system', () {
      final e =
          computeEarthing(p, system: EarthingSystem.tnCs, supplyPeMm2: 10);
      expect(e.requiresRcd, isFalse);
      expect(e.mainEarthingConductorMm2, 16); // clamp(10,16..50)
    });
  });

  group('circuitRcd', () {
    test('TT final ≤63 A → 30 mA Type A', () {
      final r = circuitRcd(
          earthingSystem: EarthingSystem.tt,
          loadKind: LoadKind.general,
          isFinalCircuit: true,
          designCurrent: const Current(20));
      expect(r.required, isTrue);
      expect(r.ratingMa, 30);
      expect(r.type, RcdType.a);
    });

    test('TT final >63 A → 100 mA', () {
      final r = circuitRcd(
          earthingSystem: EarthingSystem.tt,
          loadKind: LoadKind.general,
          isFinalCircuit: true,
          designCurrent: const Current(80));
      expect(r.ratingMa, 100);
    });

    test('socket on TN → 30 mA additional protection', () {
      final r = circuitRcd(
          earthingSystem: EarthingSystem.tnCs,
          loadKind: LoadKind.socket,
          isFinalCircuit: true,
          designCurrent: const Current(16));
      expect(r.required, isTrue);
      expect(r.ratingMa, 30);
    });

    test('life-safety → no RCD (availability prevails)', () {
      final r = circuitRcd(
          earthingSystem: EarthingSystem.tt,
          loadKind: LoadKind.pump,
          isFinalCircuit: true,
          designCurrent: const Current(20),
          lifeSafety: true);
      expect(r.required, isFalse);
      expect(r.reason, contains('Life-safety'));
    });

    test('spare way → no RCD', () {
      final r = circuitRcd(
          earthingSystem: EarthingSystem.tt,
          loadKind: LoadKind.spare,
          isFinalCircuit: true,
          designCurrent: const Current(0));
      expect(r.required, isFalse);
    });

    test('general circuit on TN → no RCD', () {
      final r = circuitRcd(
          earthingSystem: EarthingSystem.tnCs,
          loadKind: LoadKind.general,
          isFinalCircuit: true,
          designCurrent: const Current(20));
      expect(r.required, isFalse);
    });
  });
}
