/// Indonesian SNI standards profile — pluggable data + lookups.
///
/// Architecture guardrail (§12): standards are pluggable DATA, not hardcoded
/// constants scattered through the engine. Other jurisdictions implement
/// [StandardsProfile]; the sizing layer depends on the interface, never on the
/// concrete numbers.
///
/// PROVENANCE POLICY:
///   • `verified == true`  — the value was found in the SNI text itself
///     (verbatim phrasing surfaced and corroborated across independent sources)
///     and may be presented as the SNI requirement. Carries a `citation`,
///     `sourceUrl`, and (often) the verbatim `note`.
///   • `verified == false` — either a raw placeholder OR a real figure sourced
///     only from secondary literature citing SNI (clause not yet confirmed
///     against the official PDF). It MUST be surfaced in the UI/output as
///     UNVERIFIED and must NOT be presented as authoritative. `note` records
///     the caveat; flip to `verified: true` once confirmed against the
///     official SNI document.
///
/// Sources seeded 2026-06 from the SNI 8153:2015 full text on archive.org plus
/// corroborating Indonesian engineering literature (see `sourceUrl`s).
///
/// Zero Flutter imports.
library;

import '../units.dart';

/// A provenance-tagged value from a published standard. Carries enough to both
/// compute with (`value`) and to be honest about (`citation`, `verified`,
/// `sourceUrl`, `note`).
class StandardValue<T> {
  final T value;

  /// Human-readable unit label for display, e.g. "kPa", "L/s", "m/s".
  final String unit;

  /// Source citation, e.g. "SNI 8153:2015 — tekanan minimum alat plambing".
  final String citation;

  /// `false` ⇒ unverified (placeholder or secondary-only); UI must mark it so.
  final bool verified;

  /// Web source backing the value (where it was read/corroborated).
  final String? sourceUrl;

  /// Verbatim text, conversion, or caveat — the honesty surface for the value.
  final String? note;

  const StandardValue(
    this.value, {
    required this.unit,
    required this.citation,
    this.verified = false,
    this.sourceUrl,
    this.note,
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

  /// Practical maximum static pressure targeted at a fixture — the design
  /// trigger for breaking a supply system into pressure zones / boosters.
  StandardValue<Pressure> get maxFixtureStaticPressure;

  /// Hard threshold above which a pressure-relief device is mandatory.
  StandardValue<Pressure> get mandatoryPressureReliefThreshold;

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

/// SNI profile, seeded from SNI 8153:2015 research (see PROVENANCE POLICY).
class SniProfile implements StandardsProfile {
  const SniProfile();

  // Shared citation/source constants. 1 kgf/cm² = 98 066.5 Pa exactly;
  // 1 m water column = 9 806.65 Pa.
  static const String _doc = 'SNI 8153:2015';
  static const String _archiveUrl =
      'https://archive.org/details/SNI81532015SistemPlambingPadaBangunanGedung';

  @override
  String get name => 'SNI — Standar Nasional Indonesia';

  @override
  String get revision =>
      'SNI 8153:2015 supply values seeded 2026-06 (pressures from verbatim '
      'text; velocity/demand from secondary sources, pending official PDF). '
      'NB: SNI 8153:2025 now supersedes the 2015 edition.';

  // ── Pressure (water supply) ───────────────────────────────────────────────

  @override
  StandardValue<Pressure> get maxFixtureStaticPressure => const StandardValue(
        // Design target ~4 kgf/cm². The HARD relief trigger is 5 kgf/cm² — see
        // mandatoryPressureReliefThreshold. Kept as the zoning design maximum.
        Pressure(392266.0), // 4.0 kgf/cm² = 40 m water column
        unit: 'kPa',
        citation: '$_doc — practical max fixture pressure (zoning design target)',
        sourceUrl: _archiveUrl,
        verified: false, // VERIFY: ~4 kgf/cm² is secondary design guidance only
        note: 'Design maximum ≈4 kgf/cm² (≈392 kPa) per secondary sources citing '
            'SNI 8153:2015; the mandatory pressure-relief threshold is 5 kgf/cm² '
            '(see mandatoryPressureReliefThreshold). Confirm against official PDF.',
      );

  @override
  StandardValue<Pressure> get mandatoryPressureReliefThreshold =>
      const StandardValue(
        Pressure(490332.5), // 5.0 kgf/cm² = 50 m water column
        unit: 'kPa',
        citation: '$_doc — mandatory pressure-relief threshold (>5 kgf/cm²)',
        sourceUrl: _archiveUrl,
        verified: true,
        note: 'Verbatim: bila tekanan air lebih dari 5 kg/cm² atau 50 m kolom air '
            'harus dilengkapi katup pelepas tekan / kran menutup sendiri / tabung '
            'udara untuk mencegah bahaya tekanan, pukulan air, dan suara pipa. '
            'Clause no. unconfirmed.',
      );

  @override
  StandardValue<Pressure> get minResidualPressureFlushValve =>
      const StandardValue(
        Pressure(98066.5), // 1.0 kgf/cm²
        unit: 'kPa',
        citation: '$_doc — min pressure at direct flush valve (katup penggelontor)',
        sourceUrl: _archiveUrl,
        verified: true,
        note: 'Verbatim: tekanan pada katup penggelontor langsung sekurang-kurangnya '
            '1 kg/cm² (≈98 kPa). Clause no. unconfirmed.',
      );

  @override
  StandardValue<Pressure> get minResidualPressureFaucet => const StandardValue(
        Pressure(49033.25), // 0.50 kgf/cm² = 5 m water column
        unit: 'kPa',
        citation: '$_doc — min pressure at fixture outlet (titik aliran keluar)',
        sourceUrl: _archiveUrl,
        verified: true,
        note: 'Verbatim: tekanan minimum pada setiap saat di titik aliran keluar '
            'unit alat plambing adalah 0,50 kg/cm² atau 5 m kolom air (≈49 kPa). '
            'Clause no. unconfirmed.',
      );

  // ── Velocity ──────────────────────────────────────────────────────────────

  @override
  StandardValue<Velocity> get maxSupplyVelocity => const StandardValue(
        Velocity(2.0),
        unit: 'm/s',
        citation: '$_doc — max water velocity in supply pipes',
        sourceUrl: _archiveUrl,
        verified: false, // VERIFY: secondary consensus, clause not confirmed
        note: 'Design velocity range 0,9–2,0 m/detik; 2,0 m/s is the consistently '
            'cited maximum (Noerbambang/Morimura basis, also SNI 03-7065-2005) '
            'across ≥8 Indonesian studies. Confirm clause against official PDF.',
      );

  @override
  StandardValue<Velocity> get maxDrainVelocity => const StandardValue(
        Velocity(3.0),
        unit: 'm/s',
        citation: 'general plumbing practice (NOT an SNI 8153:2015 clause)',
        verified: false, // VERIFY: SNI 8153 sizes drains by slope + UBAP, not velocity
        note: 'SNI 8153:2015 sizes building drains by slope (kemiringan) and '
            'fixture-unit loading, not an explicit velocity cap. 3,0 m/s is a '
            'general-practice upper bound; self-cleansing minimum ≈0,6 m/s. '
            'Replace if an explicit SNI drainage velocity limit is confirmed.',
      );

  // ── Demand (fixture units → flow) ─────────────────────────────────────────

  /// Fixture-unit → probable-flow demand curve (Hunter-style). Monotonic;
  /// [probableFlowForFixtureUnits] interpolates linearly between points.
  // VERIFY (TOP PRIORITY): SNI 8153:2015 demand-curve values (Hunter / Noerbambang).
  // Placeholder pending the demand-curve research pass — flush-valve vs
  // flush-tank branches and the UBAP fixture-unit table land in the next commit.
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

  // ── Material properties (physical engineering references, not SNI-specific) ─

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

  // ── Verify checklist (UI surfaces these as still-unverified) ──────────────

  @override
  List<StandardValue<Object?>> get verifyChecklist => <StandardValue<Object?>>[
        // Ordered most-critical first (§13.4): zoning target, then demand.
        maxFixtureStaticPressure,
        const StandardValue<Object?>(
          'fixture-unit → flow demand curve (Hunter / Noerbambang)',
          unit: 'table',
          citation: '$_doc — demand curve',
          sourceUrl: _archiveUrl,
          verified: false,
        ),
        maxSupplyVelocity,
        maxDrainVelocity,
        mandatoryPressureReliefThreshold,
        minResidualPressureFlushValve,
        minResidualPressureFaucet,
      ].where((v) => v.isUnverified).toList();
}
