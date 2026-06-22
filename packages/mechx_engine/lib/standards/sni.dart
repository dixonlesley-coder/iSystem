/// Indonesian SNI standards profile — pluggable data + lookups.
///
/// Architecture guardrail (§12): standards are pluggable DATA, not hardcoded
/// constants scattered through the engine. Other jurisdictions implement
/// [StandardsProfile]; the sizing layer depends on the interface, never on the
/// concrete numbers.
///
/// PLACEHOLDER POLICY: every value here whose [StandardValue.verified] is
/// `false` (and is also tagged `// VERIFY` in source) is a DRAFT placeholder.
/// It MUST be surfaced in the UI/output as UNVERIFIED and must NOT be presented
/// as authoritative. Real values get transcribed from official SNI PDFs and
/// flipped to `verified: true` with an exact clause citation.
///
/// Zero Flutter imports.
library;

import '../units.dart';

/// A provenance-tagged value from a published standard. Carries enough to both
/// compute with (`value`) and to be honest about (`citation`, `verified`).
class StandardValue<T> {
  final T value;

  /// Human-readable unit label for display, e.g. "kPa", "L/s", "m/s".
  final String unit;

  /// Source citation, e.g. "SNI 8153:2015 §7.3 Tabel 5".
  final String citation;

  /// `false` ⇒ placeholder; the UI/output must mark it UNVERIFIED.
  final bool verified;

  const StandardValue(
    this.value, {
    required this.unit,
    required this.citation,
    this.verified = false,
  });

  bool get isUnverified => !verified;

  @override
  String toString() =>
      '$value $unit${verified ? '' : ' [UNVERIFIED]'} ($citation)';
}

/// Pipe materials the engine knows roughness/HW-C for.
enum PipeMaterial { pvc, hdpe, copper, galvanizedIron, ductileIron, steel }

/// Interface every standards profile satisfies. Keeps standards swappable.
abstract interface class StandardsProfile {
  String get name;
  String get revision;

  /// Maximum static pressure permitted at a fixture — the trigger for breaking
  /// a supply system into pressure zones / boosters.
  StandardValue<Pressure> get maxFixtureStaticPressure;

  /// Minimum residual (flowing) pressure required at the most-remote fixture.
  StandardValue<Pressure> get minResidualPressureFlushValve;
  StandardValue<Pressure> get minResidualPressureFaucet;

  /// Velocity caps (noise/erosion) for supply and for gravity drains.
  StandardValue<Velocity> get maxSupplyVelocity;
  StandardValue<Velocity> get maxDrainVelocity;

  /// Probable simultaneous flow for a total fixture-unit load (demand curve).
  FlowRate probableFlowForFixtureUnits(double fixtureUnits);

  /// Hazen–Williams C for [material] (pressurized friction).
  double hazenWilliamsC(PipeMaterial material);

  /// Absolute wall roughness ε for [material] (Darcy–Weisbach friction).
  Roughness absoluteRoughness(PipeMaterial material);

  /// All currently-unverified values, most safety-critical first, for the UI
  /// "verify these against the official SNI PDF" panel.
  List<StandardValue<Object?>> get verifyChecklist;
}

/// Draft SNI profile. See PLACEHOLDER POLICY above.
class SniProfile implements StandardsProfile {
  const SniProfile();

  @override
  String get name => 'SNI — Standar Nasional Indonesia';

  @override
  String get revision =>
      'draft profile v0.1 — placeholders pending transcription from official SNI PDFs';

  // ── TOP-PRIORITY VERIFY ITEMS (zoning trigger + demand curve, per §13.4) ──

  @override
  StandardValue<Pressure> get maxFixtureStaticPressure => const StandardValue(
        // VERIFY (TOP PRIORITY): SNI 8153:2015 max static pressure at a fixture
        // — the booster/zoning trigger. Placeholder 500 kPa (5 bar).
        Pressure(500000.0),
        unit: 'kPa',
        citation: 'SNI 8153:2015 — max static fixture pressure (zoning trigger)',
        verified: false,
      );

  /// Fixture-unit → probable-flow demand curve (Hunter-style). Monotonic;
  /// [probableFlowForFixtureUnits] interpolates linearly between points.
  // VERIFY (TOP PRIORITY): SNI 8153:2015 demand-curve table values.
  static const List<(double fixtureUnits, FlowRate flow)> _demandCurve = [
    (0, FlowRate(0.0)),
    (10, FlowRate(0.0006)), // ≈0.6 L/s
    (50, FlowRate(0.0019)), // ≈1.9 L/s
    (100, FlowRate(0.0030)), // ≈3.0 L/s
    (200, FlowRate(0.0048)), // ≈4.8 L/s
    (500, FlowRate(0.0085)), // ≈8.5 L/s
    (1000, FlowRate(0.0130)), // ≈13.0 L/s
  ];

  @override
  FlowRate probableFlowForFixtureUnits(double fixtureUnits) {
    if (fixtureUnits <= _demandCurve.first.$1) return _demandCurve.first.$2;
    if (fixtureUnits >= _demandCurve.last.$1) return _demandCurve.last.$2;
    for (var i = 1; i < _demandCurve.length; i++) {
      final (fuHi, qHi) = _demandCurve[i];
      if (fixtureUnits <= fuHi) {
        final (fuLo, qLo) = _demandCurve[i - 1];
        final t = (fixtureUnits - fuLo) / (fuHi - fuLo);
        return FlowRate(
          qLo.cubicMetersPerSecond +
              t * (qHi.cubicMetersPerSecond - qLo.cubicMetersPerSecond),
        );
      }
    }
    return _demandCurve.last.$2;
  }

  // ── Other supply parameters ───────────────────────────────────────────────

  @override
  StandardValue<Pressure> get minResidualPressureFlushValve =>
      const StandardValue(
        // VERIFY: SNI 8153:2015 minimum residual pressure at a flush valve.
        Pressure(100000.0), // 100 kPa (1 bar)
        unit: 'kPa',
        citation: 'SNI 8153:2015 — min residual pressure, flush valve',
        verified: false,
      );

  @override
  StandardValue<Pressure> get minResidualPressureFaucet => const StandardValue(
        // VERIFY: SNI 8153:2015 minimum residual pressure at a faucet/outlet.
        Pressure(50000.0), // 50 kPa (0.5 bar)
        unit: 'kPa',
        citation: 'SNI 8153:2015 — min residual pressure, faucet',
        verified: false,
      );

  @override
  StandardValue<Velocity> get maxSupplyVelocity => const StandardValue(
        // VERIFY: SNI 8153:2015 max design velocity in supply pipework.
        Velocity(2.0),
        unit: 'm/s',
        citation: 'SNI 8153:2015 — max supply velocity',
        verified: false,
      );

  @override
  StandardValue<Velocity> get maxDrainVelocity => const StandardValue(
        // VERIFY: SNI drainage max velocity (scour vs. erosion window).
        Velocity(3.0),
        unit: 'm/s',
        citation: 'SNI 8153:2015 — max gravity-drain velocity',
        verified: false,
      );

  // ── Material properties (physical references, not SNI-specific) ───────────

  @override
  double hazenWilliamsC(PipeMaterial material) => switch (material) {
        PipeMaterial.pvc => 150,
        PipeMaterial.hdpe => 150,
        PipeMaterial.copper => 135,
        PipeMaterial.galvanizedIron => 120,
        PipeMaterial.ductileIron => 130,
        PipeMaterial.steel => 120,
      };

  @override
  Roughness absoluteRoughness(PipeMaterial material) => switch (material) {
        PipeMaterial.pvc => const Roughness(1.5e-6),
        PipeMaterial.hdpe => const Roughness(1.5e-6),
        PipeMaterial.copper => const Roughness(1.5e-6),
        PipeMaterial.galvanizedIron => const Roughness(1.5e-4),
        PipeMaterial.ductileIron => const Roughness(2.5e-4),
        PipeMaterial.steel => const Roughness(4.5e-5),
      };

  @override
  List<StandardValue<Object?>> get verifyChecklist => [
        // Ordered most-critical first (§13.4): zoning trigger, then demand.
        maxFixtureStaticPressure,
        const StandardValue<Object?>(
          'fixture-unit → flow demand curve',
          unit: 'table',
          citation: 'SNI 8153:2015 — Hunter demand curve',
          verified: false,
        ),
        minResidualPressureFlushValve,
        minResidualPressureFaucet,
        maxSupplyVelocity,
        maxDrainVelocity,
      ].where((v) => v.isUnverified).toList();
}
