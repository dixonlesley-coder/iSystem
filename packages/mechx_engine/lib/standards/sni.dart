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

/// A single revision-history entry for an issuable calculation report — a date
/// and what changed. Pure data (no logic); the report renderers turn a
/// `List<Revision>` into a Revision-history table. Callers (the app) populate
/// it; an empty list renders no table, keeping legacy output byte-identical.
class Revision {
  final String date;
  final String description;
  const Revision(this.date, this.description);
}

/// Provenance tier for a standard value — the precise honesty surface (§12.6).
/// Splitting the old binary unverified flag tells the engineer WHY a value is
/// not yet authoritative, so the verification debt is actionable rather than a
/// flat "unverified" bucket.
enum VerificationStatus {
  /// Confirmed against the SNI text itself (verbatim phrasing surfaced and
  /// corroborated). May be presented as the SNI requirement.
  sniVerbatim,

  /// A real figure corroborated by independent secondary sources citing SNI,
  /// but the official clause is NOT yet confirmed against the SNI PDF. Use it,
  /// but confirm the clause before a submission.
  secondarySource,

  /// Explicitly NOT an SNI clause — a general engineering-practice value used
  /// where SNI prescribes a different method (e.g. drains sized by slope, not a
  /// velocity cap). Cannot become [sniVerbatim] by checking SNI; replace only
  /// if an actual SNI clause is found.
  notAnSniClause,
}

/// A provenance-tagged value from a published standard. Carries enough to both
/// compute with (`value`) and to be honest about (`citation`, `status`,
/// `sourceUrl`, `note`).
class StandardValue<T> {
  final T value;

  /// Human-readable unit label for display, e.g. "kPa", "L/s", "m/s".
  final String unit;

  /// Source citation, e.g. "SNI 8153:2015 — tekanan minimum alat plambing".
  final String citation;

  /// `false` ⇒ unverified (placeholder or secondary-only); UI must mark it so.
  final bool verified;

  /// Precise provenance tier (the honesty surface). Defaults from [verified]:
  /// verbatim when verified, else a secondary source. Pass it explicitly to flag
  /// a value that is deliberately NOT an SNI clause.
  final VerificationStatus status;

  /// Web source backing the value (where it was read/corroborated).
  final String? sourceUrl;

  /// Verbatim text, conversion, or caveat — the honesty surface for the value.
  final String? note;

  const StandardValue(
    this.value, {
    required this.unit,
    required this.citation,
    this.verified = false,
    VerificationStatus? status,
    this.sourceUrl,
    this.note,
  }) : status = status ??
            (verified
                ? VerificationStatus.sniVerbatim
                : VerificationStatus.secondarySource);

  bool get isUnverified => !verified;

  @override
  String toString() {
    final tag = verified ? '' : ' [UNVERIFIED]';
    // Prefer the human-readable `note` (correctly scaled) over the raw
    // `value`+`unit` pair: typed quantities store SI base units (Pressure in
    // Pa) while `unit` is a display label (kPa), so the pair mis-scales by
    // 1000×. Non-numeric entries (no note) print the value as-is.
    final detail = note ?? '$value $unit';
    return '$citation$tag — $detail';
  }
}

/// Pipe materials the engine knows roughness/HW-C for.
enum PipeMaterial { pvc, hdpe, copper, galvanizedIron, ductileIron, steel }

/// Flush-system type — the SNI demand curve (Gambar 1) has separate flush-tank
/// and flush-valve branches; they converge above ~1000 UBAP.
enum FlushSystem { flushTank, flushValve }

/// Occupancy class for UBAP fixture-unit loads (SNI 8153:2015 Tabel 3 columns):
/// pribadi (private) / umum (public) / tempat berkumpul (assembly).
enum Occupancy { private, public, assembly }

/// Plumbing fixtures with assigned UBAP (unit beban alat plambing) loads.
enum PlumbingFixture {
  waterClosetFlushValve, // kloset, katup gelontor
  waterClosetFlushTank, // kloset, tangki gelontor
  urinalFlushTank, // peturasan, tangki gelontor
  lavatory, // wastafel / bak cuci tangan
  shower,
  bathtub, // bak rendam
  kitchenSink, // bak cuci dapur
  hoseBibb, // keran taman
}

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

  /// The demand-estimation method this profile prescribes.
  StandardValue<String> get demandMethod;

  /// Fixture-unit (UBAP) load for [fixture] at the given [occupancy].
  double fixtureUnitLoad(
    PlumbingFixture fixture, {
    Occupancy occupancy = Occupancy.private,
  });

  /// Probable simultaneous flow for a total fixture-unit load (demand curve),
  /// on the given flush [system] branch.
  FlowRate probableFlowForFixtureUnits(
    double fixtureUnits, {
    FlushSystem system = FlushSystem.flushTank,
  });

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
        verified: false,
        // Not an SNI clause: SNI 8153 sizes drains by slope + UBAP, not velocity.
        status: VerificationStatus.notAnSniClause,
        note: 'SNI 8153:2015 sizes building drains by slope (kemiringan) and '
            'fixture-unit loading, not an explicit velocity cap. 3,0 m/s is a '
            'general-practice upper bound; self-cleansing minimum ≈0,6 m/s. '
            'Replace if an explicit SNI drainage velocity limit is confirmed.',
      );

  // ── Demand (fixture units → flow) ─────────────────────────────────────────

  @override
  StandardValue<String> get demandMethod => const StandardValue(
        'UBAP (unit beban alat plambing) + kurva perkiraan beban (Hunter curve)',
        unit: 'method',
        citation: '$_doc — demand-estimation method',
        sourceUrl: _archiveUrl,
        verified: true,
        note: 'SNI 8153:2015 prescribes the fixture-unit (UBAP) + Hunter demand '
            'curve method (Noerbambang & Morimura; UPC 2012 basis); it supersedes '
            'SNI 03-6481-2000 & 03-7065-2005. The METHOD is confirmed; the curve '
            'point VALUES and the UBAP table below are secondary / chart read-offs '
            'and remain UNVERIFIED.',
      );

  @override
  double fixtureUnitLoad(
    PlumbingFixture fixture, {
    Occupancy occupancy = Occupancy.private,
  }) =>
      // SNI 8153:2015 Tabel 3 (UBAP). Secondary-sourced (literal table not yet
      // confirmed) — flagged via the demand-curve entry in verifyChecklist.
      // VERIFY against the official Tabel 3.
      switch ((fixture, occupancy)) {
        (PlumbingFixture.waterClosetFlushValve, Occupancy.private) => 6.0,
        (PlumbingFixture.waterClosetFlushValve, _) => 10.0,
        (PlumbingFixture.waterClosetFlushTank, Occupancy.assembly) => 3.5,
        (PlumbingFixture.waterClosetFlushTank, _) => 2.5,
        (PlumbingFixture.urinalFlushTank, Occupancy.assembly) => 3.0,
        (PlumbingFixture.urinalFlushTank, _) => 2.0,
        (PlumbingFixture.lavatory, _) => 1.0,
        (PlumbingFixture.shower, _) => 2.0,
        (PlumbingFixture.bathtub, _) => 4.0,
        (PlumbingFixture.kitchenSink, _) => 2.0,
        (PlumbingFixture.hoseBibb, _) => 2.5,
      };

  // SNI 8153:2015 Gambar 1 "kurva perkiraan beban" — flush-TANK branch.
  // VERIFY: chart read-offs from the Hunter / UPC-2012 curve lineage
  // (L/min → m³/s); not a literal digitisation of Gambar 1. Secondary literal
  // anchor point: 314 UBAP → 400 L/min.
  static const List<(double ubap, FlowRate flow)> _demandTank = [
    (0, FlowRate(0.0)),
    (10, FlowRate(0.0005)), //   30 L/min
    (25, FlowRate(0.00088333)), //   53 L/min
    (50, FlowRate(0.00183333)), //  110 L/min
    (100, FlowRate(0.00303333)), //  182 L/min
    (200, FlowRate(0.00473333)), //  284 L/min
    (314, FlowRate(0.00666667)), //  400 L/min (secondary literal)
    (500, FlowRate(0.00788333)), //  473 L/min
    (1000, FlowRate(0.01311667)), //  787 L/min
    (2000, FlowRate(0.02025)), // 1215 L/min
    (3000, FlowRate(0.02723333)), // 1634 L/min
  ];

  // Gambar 1 — flush-VALVE branch (higher demand at low UBAP; merges with the
  // tank branch above ~1000 UBAP). Same provenance caveat as the tank branch.
  static const List<(double ubap, FlowRate flow)> _demandValve = [
    (0, FlowRate(0.0)),
    (10, FlowRate(0.00088333)), //   53 L/min
    (25, FlowRate(0.00151667)), //   91 L/min
    (50, FlowRate(0.00258333)), //  155 L/min
    (100, FlowRate(0.00403333)), //  242 L/min
    (200, FlowRate(0.00593333)), //  356 L/min
    (500, FlowRate(0.00896667)), //  538 L/min
    (1000, FlowRate(0.01311667)), //  787 L/min
    (2000, FlowRate(0.02025)), // 1215 L/min
    (3000, FlowRate(0.02723333)), // 1634 L/min
  ];

  @override
  FlowRate probableFlowForFixtureUnits(
    double fixtureUnits, {
    FlushSystem system = FlushSystem.flushTank,
  }) {
    final curve = system == FlushSystem.flushValve ? _demandValve : _demandTank;
    if (fixtureUnits <= curve.first.$1) return curve.first.$2;
    if (fixtureUnits >= curve.last.$1) return curve.last.$2;
    for (var i = 1; i < curve.length; i++) {
      final (xHi, yHi) = curve[i];
      if (fixtureUnits <= xHi) {
        final (xLo, yLo) = curve[i - 1];
        final t = (fixtureUnits - xLo) / (xHi - xLo);
        return FlowRate(
          yLo.cubicMetersPerSecond +
              t * (yHi.cubicMetersPerSecond - yLo.cubicMetersPerSecond),
        );
      }
    }
    return curve.last.$2;
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
        // Plumbing-rigour advisory thresholds — all general practice, NOT yet
        // confirmed against the SNI clauses (surfaced so the report stays honest).
        const StandardValue<Object?>(
          0.9,
          unit: 'C',
          citation: '$_doc — storm runoff coefficient (rational method)',
          status: VerificationStatus.notAnSniClause,
          note: 'Default runoff coefficient C ≈ 0.9 (impervious roof); '
              'surface/region-dependent — confirm vs SNI rational-method table.',
        ),
        const StandardValue<Object?>(
          0.005,
          unit: 'm/m',
          citation: '$_doc — minimum self-cleansing drainage gradient',
          status: VerificationStatus.notAnSniClause,
          note: 'Minimum branch gradient ≈ 0.005 (1:200) for self-cleansing; '
              'general plumbing practice — confirm vs SNI 8153 gradient table.',
        ),
        const StandardValue<Object?>(
          32.0,
          unit: 'm',
          citation: '$_doc — drainage developed-length / trap-arm limit',
          status: VerificationStatus.notAnSniClause,
          note: 'Developed-length limit ≈ 32 m before self-siphonage / loss of '
              'grade; general practice — confirm vs SNI 8153.',
        ),
        const StandardValue<Object?>(
          55.0,
          unit: 'C',
          citation: '$_doc — anti-Legionella minimum return temperature',
          status: VerificationStatus.notAnSniClause,
          note: 'Hot-water return kept ≥ ~55 °C (60 °C stored) for Legionella '
              'control; general guidance — confirm vs SNI / WHO clause.',
        ),
      ].where((v) => v.isUnverified).toList();
}
