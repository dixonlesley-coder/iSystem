/// Round 33 seed suite (2026-10-18) — engineer-walkthrough-bom-breaker-
/// upsized-above-cable-iz: the BOM never prices a protective device of a
/// different RATING than the schedule's, nor one below the specified kA.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  final parts = fullCatalog();
  final bySku = {for (final p in parts) p.sku: p};

  test('the reported case: MCB 32A at 25 kA is never an MCCB 40A', () {
    // In 32 A on a cable with derated Iz 36 A: a 40 A device breaks
    // In <= Iz (IEC 60364-4-43), so it is never a valid stand-in.
    const b = BreakerResult(
        ratingA: Current(32),
        deviceClass: BreakerClass.mcb,
        curve: BreakerCurve.c);
    final sku = matchBreakerSku(b, parts, poles: 3, minBreakingKa: 25);
    if (sku != null) {
      expect(bySku[sku]!.ratingA, 32);
      expect(bySku[sku]!.breakingKa ?? 25, greaterThanOrEqualTo(25));
    }
    // A plain 16 A C-curve 1P at 6 kA still matches the exact MCB.
    const m = BreakerResult(
        ratingA: Current(16),
        deviceClass: BreakerClass.mcb,
        curve: BreakerCurve.c);
    final m16 = matchBreakerSku(m, parts, poles: 1, minBreakingKa: 6);
    expect(m16, isNotNull);
    final p16 = bySku[m16]!;
    expect(p16.ratingA, 16);
    expect(p16.poles, 1);
    expect(p16.curve, 'C');
    expect(p16.deviceClass, 'MCB');
  });

  test('seeded property: a match always has the sized rating and the kA', () {
    final rnd = math.Random(33);
    const ratings = PuilProfile();
    final rungs = ratings.standardBreakerRatingsA;
    for (var i = 0; i < 3000; i++) {
      final a = rungs[rnd.nextInt(rungs.length)];
      final cls = a > 63
          ? BreakerClass.mccb
          : (rnd.nextBool() ? BreakerClass.mcb : BreakerClass.mccb);
      final curve = BreakerCurve.values[rnd.nextInt(3)];
      final poles = 1 + rnd.nextInt(4);
      final ka = const [0.0, 3, 6, 10, 16, 25, 36, 50][rnd.nextInt(8)];
      final b = BreakerResult(ratingA: Current(a), deviceClass: cls, curve: curve);
      final sku = matchBreakerSku(b, parts,
          poles: poles, minBreakingKa: ka > 0 ? ka.toDouble() : null);
      if (sku == null) continue;
      final p = bySku[sku]!;
      expect(p.ratingA, closeTo(a, 1e-9), reason: '$i $a');
      if (ka > 0 && p.breakingKa != null) {
        expect(p.breakingKa!, greaterThanOrEqualTo(ka - 1e-9), reason: '$i');
      }
    }
  });
}
