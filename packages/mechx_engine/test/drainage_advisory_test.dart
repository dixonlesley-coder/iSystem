/// Tests for the gravity-drainage advisory layer (`drainage_advisory.dart`).
///
/// The advisories are a JUDGE-ONLY layer over an already-computed
/// [DrainageSizingResult] + the run geometry — they never resize. Both
/// thresholds are general practice (// VERIFY vs SNI 8153):
///   • minimum self-cleansing slope  = 0.005 m/m (1:200)  → [kMinSelfCleansingSlope]
///   • maximum developed-length      = 32 m              → [kMaxDevelopedLengthM]
///
/// We size a representative branch with [sizeForFlow] and then assert which
/// advisories fire for chosen slope / developed-length inputs.
library;

import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // A small representative branch flow (~1 L/s) used across the cases; the exact
  // pipe chosen is immaterial to the advisory logic (it keys off slope + length).
  const flow = FlowRate(0.001);

  group('drainageAdvisories — minimum self-cleansing slope', () {
    test('slope 0.001 (1:1000, below 0.005) raises a minSlope advisory', () {
      final sizing = sizeForFlow(flow: flow, slope: 0.001);
      final out = drainageAdvisories(
        edgeId: 'e1',
        slope: 0.001,
        sizing: sizing,
        developedLengthM: 10.0,
      );
      // 0.001 < kMinSelfCleansingSlope (0.005) ⇒ exactly one (minSlope) advisory.
      expect(out, hasLength(1));
      expect(out.single.kind, DrainageAdvisoryKind.minSlope);
      expect(out.single.edgeId, 'e1');
    });

    test('slope 0.01 (1:100, at/above 0.005) raises no minSlope advisory', () {
      final sizing = sizeForFlow(flow: flow, slope: 0.01);
      final out = drainageAdvisories(
        edgeId: 'e1',
        slope: 0.01,
        sizing: sizing,
        developedLengthM: 20.0,
      );
      // 0.01 ≥ 0.005 and 20 m ≤ 32 m ⇒ no advisories.
      expect(out, isEmpty);
    });

    test('the threshold boundary 0.005 itself does NOT warn (strict <)', () {
      final sizing = sizeForFlow(flow: flow, slope: kMinSelfCleansingSlope);
      final out = drainageAdvisories(
        edgeId: 'e1',
        slope: kMinSelfCleansingSlope,
        sizing: sizing,
      );
      expect(out, isEmpty);
    });
  });

  group('drainageAdvisories — developed length / trap-arm limit', () {
    test('developed length 40 m (> 32 m) raises a developedLength advisory', () {
      final sizing = sizeForFlow(flow: flow, slope: 0.01);
      final out = drainageAdvisories(
        edgeId: 'e2',
        slope: 0.01, // healthy slope ⇒ only the length check can fire
        sizing: sizing,
        developedLengthM: 40.0,
      );
      // 40 m > kMaxDevelopedLengthM (32) ⇒ exactly one (developedLength) advisory.
      expect(out, hasLength(1));
      expect(out.single.kind, DrainageAdvisoryKind.developedLength);
      expect(out.single.edgeId, 'e2');
    });

    test('null developed length skips the length check', () {
      final sizing = sizeForFlow(flow: flow, slope: 0.01);
      final out = drainageAdvisories(
        edgeId: 'e2',
        slope: 0.01,
        sizing: sizing,
        developedLengthM: null,
      );
      expect(out, isEmpty);
    });

    test('the 32 m boundary itself does NOT warn (strict >)', () {
      final sizing = sizeForFlow(flow: flow, slope: 0.01);
      final out = drainageAdvisories(
        edgeId: 'e2',
        slope: 0.01,
        sizing: sizing,
        developedLengthM: kMaxDevelopedLengthM,
      );
      expect(out, isEmpty);
    });
  });

  group('drainageAdvisories — both checks together', () {
    test('flat AND over-long branch raises BOTH advisories', () {
      final sizing = sizeForFlow(flow: flow, slope: 0.002);
      final out = drainageAdvisories(
        edgeId: 'e3',
        slope: 0.002, // < 0.005
        sizing: sizing,
        developedLengthM: 50.0, // > 32
      );
      expect(out, hasLength(2));
      expect(
        out.map((a) => a.kind).toSet(),
        {DrainageAdvisoryKind.minSlope, DrainageAdvisoryKind.developedLength},
      );
    });

    test('normal branch (0.01 slope, 20 m) has no advisories', () {
      final sizing = sizeForFlow(flow: flow, slope: 0.01);
      final out = drainageAdvisories(
        edgeId: 'e4',
        slope: 0.01,
        sizing: sizing,
        developedLengthM: 20.0,
      );
      expect(out, isEmpty);
    });
  });
}
