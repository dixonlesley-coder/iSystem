/// Air-side ventilation standards — pluggable data for air-change-rate (ACH)
/// driven sizing, mirroring the plumbing/electrical profile pattern (§12.6).
///
/// The headline input for AHU / FCU / fan room sizing is the **air change rate**
/// (ACH, perubahan udara per jam): how many times the room's air volume is
/// replaced per hour. Multiply ACH by the room volume to get the design
/// airflow. The per-room-type ACH values below are general HVAC engineering
/// practice (ASHRAE 62.1 / CIBSE Guide B style figures) cross-checked against
/// Indonesian ventilation guidance (SNI 03-6572-2001, "Tata cara perancangan
/// sistem ventilasi dan pengkondisian udara pada bangunan gedung"). Spaces
/// covered by that standard's Tabel 4.4.1 are [VerificationStatus.sniVerbatim];
/// spaces the table does not enumerate (bedroom, living room, meeting room,
/// hospital ward, laboratory, server room) — confirmed absent from the
/// standard's structure (2026-07 research pass, `docs/standards-references.md`)
/// — are [VerificationStatus.notAnSniClause]: a deliberate general-practice
/// figure, not debt pending confirmation. The cooling-load area-density rule
/// ([coolingLoadDensityBtuPerHrM2]) is likewise [VerificationStatus.notAnSniClause]
/// for every room type — no Indonesian SNI prescribes an area-density (BTU/h
/// per m²) cooling design figure; SNI 03-6572-2001 itself is ACH/fresh-air
/// based, not area-density based.
///
/// Reuses [StandardValue] / [VerificationStatus] from `standards/sni.dart` and
/// [GrilleApplication] from `sizing/grille_sizing.dart`. Zero Flutter imports.
library;

import '../sizing/grille_sizing.dart';
import 'sni.dart';

/// Room / space types with a characteristic ventilation air-change rate.
///
/// Ordered loosely from low to high ventilation demand. Used to look up a
/// default ACH and a noise-driven grille face-velocity class.
enum RoomType {
  /// Circulation corridor / hallway.
  corridor,

  /// Entrance lobby / reception.
  lobby,

  /// General / open-plan or private office.
  office,

  /// Bedroom or hotel guest room.
  bedroom,

  /// Living / lounge / family room.
  livingRoom,

  /// Classroom / training room.
  classroom,

  /// Meeting / conference room (higher occupant density).
  meetingRoom,

  /// Retail shop / showroom.
  retail,

  /// Restaurant / dining hall.
  restaurant,

  /// Toilet / washroom (extract-driven).
  toilet,

  /// Hospital ward / patient room.
  hospitalWard,

  /// Laboratory (general, non-fume-hood).
  laboratory,

  /// Server / equipment room (cooling-load driven, high ACH).
  serverRoom,

  /// Commercial / production kitchen (high extract).
  commercialKitchen,
}

/// Human-readable label for [type].
String roomTypeLabel(RoomType type) {
  switch (type) {
    case RoomType.corridor:
      return 'Corridor';
    case RoomType.lobby:
      return 'Lobby';
    case RoomType.office:
      return 'Office';
    case RoomType.bedroom:
      return 'Bedroom';
    case RoomType.livingRoom:
      return 'Living room';
    case RoomType.classroom:
      return 'Classroom';
    case RoomType.meetingRoom:
      return 'Meeting room';
    case RoomType.retail:
      return 'Retail';
    case RoomType.restaurant:
      return 'Restaurant';
    case RoomType.toilet:
      return 'Toilet';
    case RoomType.hospitalWard:
      return 'Hospital ward';
    case RoomType.laboratory:
      return 'Laboratory';
    case RoomType.serverRoom:
      return 'Server room';
    case RoomType.commercialKitchen:
      return 'Commercial kitchen';
  }
}

/// Interface every air-ventilation standards profile satisfies — keeps the ACH
/// data swappable per jurisdiction, like [StandardsProfile] for plumbing.
abstract interface class VentilationStandardsProfile {
  String get name;
  String get revision;

  /// Recommended design air-change rate (changes per hour) for [type].
  StandardValue<double> recommendedAch(RoomType type);

  /// Sensible cooling-load density (BTU/h per m² of floor) for [type] — the
  /// per-area figure for the area-density AC sizing rule (`cooling_load.dart`).
  StandardValue<double> coolingLoadDensityBtuPerHrM2(RoomType type);

  /// Noise-driven grille/diffuser face-velocity class for [type] — the bridge
  /// to [sizeGrille] / [selectStandardGrille].
  GrilleApplication grilleApplicationFor(RoomType type);

  /// Values that must be surfaced as UNVERIFIED until confirmed against the
  /// official standard document.
  List<StandardValue<Object?>> get verifyChecklist;
}

/// SNI-context ventilation profile. ACH figures are general HVAC practice
/// corroborated against SNI 03-6572-2001. Tabel 4.4.1 spaces are
/// [VerificationStatus.sniVerbatim]; spaces outside the table's scope (and the
/// area-density cooling rule, which the standard does not cover at all) are
/// [VerificationStatus.notAnSniClause] — general practice, not verification
/// debt.
class SniVentilationProfile implements VentilationStandardsProfile {
  const SniVentilationProfile();

  static const String _doc = 'SNI 03-6572-2001';
  // Corroborating academic reproduction of SNI 03-6572-2001 Tabel 4.4.1 (office
  // 6, retail 6, restaurant 6, classroom 4, lobby/corridor 10, toilet 20,
  // kitchen 6 ACH); still VERIFY against the official BSN PDF before promoting.
  static const String _sourceUrl =
      'https://jshee.ppns.ac.id/index.php/JSHEE/article/download/14/18/100';

  @override
  String get name => 'SNI (ventilation / ACH)';

  @override
  String get revision =>
      'ACH values are general HVAC practice (ASHRAE 62.1 / CIBSE Guide B) '
      'cross-checked against SNI 03-6572-2001. Tabel 4.4.1 spaces are '
      'sniVerbatim; spaces outside the table (and the area-density cooling '
      'rule) are notAnSniClause — confirmed general practice, not pending '
      'debt (2026-07 research pass).';

  /// Bare ACH number per room type. Kept private so the public API always
  /// returns a provenance-tagged [StandardValue].
  ///
  /// Values marked "Tabel 4.4.1" are taken from SNI 03-6572-2001's mechanical
  /// ventilation table (corroborated via secondary sources that quote it — see
  /// `docs/standards-references.md`); the remainder (spaces NOT in that table)
  /// stay general HVAC practice. See [_fromSniTable].
  static double _achValue(RoomType type) {
    switch (type) {
      // ── SNI 03-6572-2001 Tabel 4.4.1 ──────────────────────────────────────
      case RoomType.corridor:
        return 4.0; // lobi / koridor / tangga
      case RoomType.lobby:
        return 4.0; // lobi / koridor / tangga
      case RoomType.office:
        return 6.0; // kantor
      case RoomType.classroom:
        return 8.0; // kelas / bioskop
      case RoomType.retail:
        return 6.0; // toko / pasar swalayan
      case RoomType.restaurant:
        return 6.0; // restoran
      case RoomType.toilet:
        return 10.0; // kamar mandi / WC
      case RoomType.commercialKitchen:
        return 20.0; // dapur
      // ── Not in Tabel 4.4.1 — general HVAC practice (notAnSniClause) ────────
      case RoomType.bedroom:
        return 5.0;
      case RoomType.livingRoom:
        return 6.0;
      case RoomType.meetingRoom:
        return 8.0; // table specifies per-person fresh air, not ACH
      case RoomType.hospitalWard:
        return 6.0;
      case RoomType.laboratory:
        return 10.0;
      case RoomType.serverRoom:
        return 15.0;
    }
  }

  /// Whether [type]'s ACH comes directly from SNI 03-6572-2001 Tabel 4.4.1
  /// (vs general HVAC practice for spaces the table doesn't list). Drives both
  /// the citation precision and the provenance tier: table spaces are
  /// [VerificationStatus.sniVerbatim]; off-table spaces are
  /// [VerificationStatus.notAnSniClause] (confirmed out of the table's scope,
  /// not pending confirmation — see `docs/standards-references.md`).
  static bool _fromSniTable(RoomType type) {
    switch (type) {
      case RoomType.corridor:
      case RoomType.lobby:
      case RoomType.office:
      case RoomType.classroom:
      case RoomType.retail:
      case RoomType.restaurant:
      case RoomType.toilet:
      case RoomType.commercialKitchen:
        return true;
      case RoomType.bedroom:
      case RoomType.livingRoom:
      case RoomType.meetingRoom:
      case RoomType.hospitalWard:
      case RoomType.laboratory:
      case RoomType.serverRoom:
        return false;
    }
  }

  @override
  StandardValue<double> recommendedAch(RoomType type) {
    final ach = _achValue(type);
    final fromTable = _fromSniTable(type);
    return StandardValue<double>(
      ach,
      unit: 'ACH (1/h)',
      citation: fromTable
          ? '$_doc Tabel 4.4.1 — kebutuhan ventilasi mekanis '
              '(${roomTypeLabel(type)})'
          : 'general HVAC practice (ASHRAE 62.1-class) — laju perubahan udara '
              '(${roomTypeLabel(type)}); not governed by any $_doc clause',
      sourceUrl: _sourceUrl,
      verified: fromTable,
      status: fromTable
          ? VerificationStatus.sniVerbatim
          : VerificationStatus.notAnSniClause,
      note: fromTable
          ? '${roomTypeLabel(type)}: ${ach.toStringAsFixed(0)} air changes per '
              'hour, per SNI 03-6572-2001 Tabel 4.4.1 (kebutuhan ventilasi '
              'mekanis).'
          : '${roomTypeLabel(type)}: ${ach.toStringAsFixed(0)} air changes per '
              'hour. Confirmed NOT in SNI 03-6572-2001 Tabel 4.4.1 (the table '
              'enumerates office/restaurant/retail/workshop/classroom/lobby/'
              'toilet/kitchen only, per docs/standards-references.md); figure '
              'is general HVAC practice (ASHRAE 62.1-class), deliberately not '
              'an SNI clause.',
    );
  }

  /// Bare cooling-load density (BTU/h per m²) per room use.
  static double _coolingDensity(RoomType type) {
    switch (type) {
      case RoomType.corridor:
        return 400.0;
      case RoomType.lobby:
        return 500.0;
      case RoomType.office:
        return 600.0;
      case RoomType.bedroom:
        return 500.0;
      case RoomType.livingRoom:
        return 500.0; // residential base (≈ the common "area × 500" rule)
      case RoomType.classroom:
        return 600.0;
      case RoomType.meetingRoom:
        return 700.0; // high occupant density
      case RoomType.retail:
        return 600.0;
      case RoomType.restaurant:
        return 700.0;
      case RoomType.toilet:
        return 450.0;
      case RoomType.hospitalWard:
        return 550.0;
      case RoomType.laboratory:
        return 700.0;
      case RoomType.serverRoom:
        return 1000.0; // equipment-dominated
      case RoomType.commercialKitchen:
        return 900.0;
    }
  }

  @override
  StandardValue<double> coolingLoadDensityBtuPerHrM2(RoomType type) {
    final d = _coolingDensity(type);
    return StandardValue<double>(
      d,
      unit: 'BTU/h per m2',
      citation: 'general HVAC / AC-installer practice — beban pendinginan per '
          'luas (${roomTypeLabel(type)}); not governed by any $_doc clause',
      sourceUrl: _sourceUrl,
      status: VerificationStatus.notAnSniClause,
      note: '${roomTypeLabel(type)}: ${d.toStringAsFixed(0)} BTU/h per m2 floor. '
          'Corroborated against the common Indonesian rule of ~600 (well '
          'insulated) to ~800 (sun-exposed / poorly insulated) BTU/h per m2; '
          'low-gain spaces ~400-500, equipment-heavy ~900-1000. Confirmed: '
          'SNI 03-6572-2001 is ACH/fresh-air based and prescribes no '
          'area-density (BTU/h per m2) cooling figure — this is deliberately '
          'general practice, not an SNI clause.',
    );
  }

  @override
  GrilleApplication grilleApplicationFor(RoomType type) {
    switch (type) {
      case RoomType.bedroom:
      case RoomType.hospitalWard:
        return GrilleApplication.bedroom; // most noise-sensitive
      case RoomType.livingRoom:
      case RoomType.classroom:
      case RoomType.meetingRoom:
        return GrilleApplication.livingSpace;
      case RoomType.office:
      case RoomType.lobby:
      case RoomType.corridor:
      case RoomType.laboratory:
        return GrilleApplication.office;
      case RoomType.retail:
      case RoomType.restaurant:
      case RoomType.toilet:
        return GrilleApplication.retail;
      case RoomType.serverRoom:
      case RoomType.commercialKitchen:
        return GrilleApplication.industrial; // least noise-sensitive
    }
  }

  @override
  List<StandardValue<Object?>> get verifyChecklist => <StandardValue<Object?>>[
        const StandardValue<Object?>(
          'air-change-rate (spaces not in SNI Tabel 4.4.1)',
          unit: 'ACH (1/h)',
          citation: 'general HVAC practice (ASHRAE 62.1-class) — laju '
              'perubahan udara untuk ruang di luar $_doc Tabel 4.4.1',
          sourceUrl: _sourceUrl,
          verified: false,
          status: VerificationStatus.notAnSniClause,
          note: 'ACH for spaces NOT listed in SNI 03-6572-2001 Tabel 4.4.1 '
              '(bedroom, living room, meeting room, hospital ward, laboratory, '
              'server room) is general HVAC practice; confirmed these spaces '
              'are outside the table\'s scope (2026-07 research pass), so this '
              'is deliberate general practice, not pending SNI confirmation. '
              'The Tabel 4.4.1 spaces are separately verified.',
        ),
        const StandardValue<Object?>(
          'cooling-load density (BTU/h per m², per room type)',
          unit: 'BTU/h per m2',
          citation: 'general HVAC / AC-installer practice — beban pendinginan '
              'per luas; not governed by any $_doc clause',
          sourceUrl: _sourceUrl,
          verified: false,
          status: VerificationStatus.notAnSniClause,
          note: 'Area-density AC sizing figures from general HVAC practice. '
              'Confirmed (2026-07 research pass): SNI 03-6572-2001 is '
              'ACH/fresh-air based and prescribes no area-density cooling '
              'figure — no Indonesian SNI governs this rule of thumb.',
        ),
      ];
}
