/// Air-side ventilation standards — pluggable data for air-change-rate (ACH)
/// driven sizing, mirroring the plumbing/electrical profile pattern (§12.6).
///
/// The headline input for AHU / FCU / fan room sizing is the **air change rate**
/// (ACH, perubahan udara per jam): how many times the room's air volume is
/// replaced per hour. Multiply ACH by the room volume to get the design
/// airflow. The per-room-type ACH values below are general HVAC engineering
/// practice (ASHRAE 62.1 / CIBSE Guide B style figures) cross-checked against
/// Indonesian ventilation guidance (SNI 03-6572-2001, "Tata cara perancangan
/// sistem ventilasi dan pengkondisian udara pada bangunan gedung"). They are
/// NOT confirmed verbatim against the official SNI PDF, so every value is
/// flagged [VerificationStatus.secondarySource] and surfaced as UNVERIFIED in
/// any report — keep that honesty surface intact.
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
/// corroborated against SNI 03-6572-2001; pending verbatim confirmation they
/// are all [VerificationStatus.secondarySource].
class SniVentilationProfile implements VentilationStandardsProfile {
  const SniVentilationProfile();

  static const String _doc = 'SNI 03-6572-2001';
  static const String _sourceUrl =
      'https://www.bsn.go.id/'; // VERIFY against official SNI 03-6572-2001 PDF.

  @override
  String get name => 'SNI (ventilation / ACH)';

  @override
  String get revision =>
      'ACH values are general HVAC practice (ASHRAE 62.1 / CIBSE Guide B) '
      'cross-checked against SNI 03-6572-2001; pending the official PDF every '
      'value is secondarySource (UNVERIFIED).';

  /// Bare ACH number per room type. Kept private so the public API always
  /// returns a provenance-tagged [StandardValue].
  static double _achValue(RoomType type) {
    switch (type) {
      case RoomType.corridor:
        return 4.0;
      case RoomType.lobby:
        return 5.0;
      case RoomType.office:
        return 6.0;
      case RoomType.bedroom:
        return 5.0;
      case RoomType.livingRoom:
        return 6.0;
      case RoomType.classroom:
        return 6.0;
      case RoomType.meetingRoom:
        return 8.0;
      case RoomType.retail:
        return 8.0;
      case RoomType.restaurant:
        return 10.0;
      case RoomType.toilet:
        return 12.0;
      case RoomType.hospitalWard:
        return 6.0;
      case RoomType.laboratory:
        return 10.0;
      case RoomType.serverRoom:
        return 15.0;
      case RoomType.commercialKitchen:
        return 20.0;
    }
  }

  @override
  StandardValue<double> recommendedAch(RoomType type) {
    final ach = _achValue(type);
    return StandardValue<double>(
      ach,
      unit: 'ACH (1/h)',
      citation: '$_doc — laju perubahan udara (${roomTypeLabel(type)})',
      sourceUrl: _sourceUrl,
      status: VerificationStatus.secondarySource,
      note: '${roomTypeLabel(type)}: ${ach.toStringAsFixed(0)} air changes per '
          'hour. Corroborated against ASHRAE 62.1-class ranges (office 4-6, '
          'classroom 6-8, retail 6-10, restaurant 8-12, toilet 8-15, hospital '
          'ward min 6); VERIFY the exact figure against SNI 03-6572-2001.',
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
      citation: '$_doc — beban pendinginan per luas (${roomTypeLabel(type)})',
      sourceUrl: _sourceUrl,
      status: VerificationStatus.secondarySource,
      note: '${roomTypeLabel(type)}: ${d.toStringAsFixed(0)} BTU/h per m2 floor. '
          'Corroborated against the common Indonesian rule of ~600 (well '
          'insulated) to ~800 (sun-exposed / poorly insulated) BTU/h per m2; '
          'low-gain spaces ~400-500, equipment-heavy ~900-1000. VERIFY.',
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
          'air-change-rate table (per room type)',
          unit: 'ACH (1/h)',
          citation: '$_doc — laju perubahan udara per ruang',
          sourceUrl: _sourceUrl,
          verified: false,
          status: VerificationStatus.secondarySource,
          note: 'ACH per room type from general HVAC practice; confirm each '
              'figure against the official SNI 03-6572-2001 clause.',
        ),
        const StandardValue<Object?>(
          'cooling-load density (BTU/h per m², per room type)',
          unit: 'BTU/h per m2',
          citation: '$_doc — beban pendinginan per luas',
          sourceUrl: _sourceUrl,
          verified: false,
          status: VerificationStatus.secondarySource,
          note: 'Area-density AC sizing figures from general HVAC practice; '
              'confirm against an SNI / cooling-load study.',
        ),
      ];
}
