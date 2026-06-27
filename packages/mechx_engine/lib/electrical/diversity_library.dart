/// Occupancy-keyed diversity / demand-factor library for the electrical domain.
///
/// PanelMaker (and the current A4 core) apply a single panel-wide
/// [ElectricalPanel.diversityFactor] to the whole connected load, plus a flat
/// per-[LoadKind] `demandFactor` default on each circuit. Real installations
/// diversify DIFFERENTLY by both the BUILDING TYPE (occupancy) and the LOAD KIND:
/// an office's socket-outlet load diversifies hard (few are ever simultaneously
/// loaded), an office's lighting barely diversifies (all lights on together);
/// a residential block diversifies its general load against the number of
/// dwellings, and so on.
///
/// This library is OPT-IN. A panel references it by occupancy id
/// ([ElectricalPanel.diversityLibraryId]); when set, `computePanel` uses
/// [DiversityLibrary.demandFactorFor] as the circuit demand factor in place of
/// the model's per-circuit `demandFactor`. When ABSENT (the default), the engine
/// uses the per-circuit `demandFactor` exactly as before — byte-identical.
///
/// PROVENANCE: every factor here is a defensible engineering value drawn from
/// IEC 60364-1 Annex / NEC Art. 220 / CIBSE-style demand-factor practice, NOT a
/// verbatim PUIL 2011 clause. All tagged `secondarySource` // VERIFY and surfaced
/// via [diversityLibraryVerifyItems]; nothing here is `sniVerbatim` until checked
/// against the official PUIL / SNI 0225:2011 document.
///
/// Zero Flutter imports.
library;

import '../standards/sni.dart' show StandardValue, VerificationStatus;
import 'load_kind.dart' show LoadKind;

/// The pluggable demand-factor library interface — occupancy + load kind → a
/// demand (utilisation) factor in 0..1. A jurisdiction / project can swap a
/// different table in without touching the sizing core. Mirrors the
/// [ElectricalStandardsProfile] pattern: the sizing layer depends on THIS, not
/// on the concrete PUIL numbers.
abstract interface class DiversityLibrary {
  /// Interface version for forward-compat (a newer table can bump it; the
  /// reader can fall back if it sees a version it doesn't understand).
  int get interfaceVersion;

  /// All occupancy ids this library knows, e.g. `residential` / `office`.
  List<String> get occupancyIds;

  /// Human label for an occupancy id (e.g. `office` → "Office / commercial").
  /// Returns the raw id when unknown.
  String occupancyLabel(String occupancyId);

  /// Whether this library has a table for [occupancyId].
  bool hasOccupancy(String occupancyId);

  /// Demand (utilisation) factor in 0..1 for a [loadKind] under [occupancyId].
  /// An unknown occupancy OR an unmapped load kind falls back to [fallback]
  /// (the model's own per-circuit demand factor), so the result is never worse
  /// than the pre-library behaviour.
  ///
  /// // VERIFY — secondarySource (IEC 60364-1 / NEC 220 demand-factor practice,
  /// pending the official PUIL 2011 clause).
  double demandFactorFor(
    String occupancyId,
    LoadKind loadKind, {
    required double fallback,
  });
}

/// PUIL/IEC-flavoured concrete diversity library, seeded from general LV
/// demand-factor practice. Every value is `secondarySource` // VERIFY.
class PuilDiversityLibrary implements DiversityLibrary {
  const PuilDiversityLibrary();

  @override
  int get interfaceVersion => 1;

  /// Occupancy id → friendly label.
  static const Map<String, String> _labels = {
    'residential': 'Residential / dwelling',
    'office': 'Office / commercial',
    'retail': 'Retail / shop',
    'hospital': 'Hospital / healthcare',
    'hotel': 'Hotel / hospitality',
    'industrial': 'Industrial / workshop',
  };

  /// occupancy id → (load kind → demand factor).
  ///
  /// Read each column as "how much of the connected [LoadKind] is assumed
  /// simultaneously demanded in this kind of building". Lighting and HVAC run
  /// near-fully in offices/hospitals; socket outlets diversify hard everywhere;
  /// residential general/socket load diversifies against dwelling count. These
  /// are engineering norms, NOT a PUIL table — // VERIFY.
  static const Map<String, Map<LoadKind, double>> _table = {
    'residential': {
      LoadKind.general: 0.6,
      LoadKind.lighting: 0.66,
      LoadKind.socket: 0.5,
      LoadKind.heating: 0.8,
      LoadKind.hvac: 0.75,
      LoadKind.motor: 0.7,
      LoadKind.pump: 0.7,
      LoadKind.evCharger: 0.6,
    },
    'office': {
      LoadKind.general: 0.7,
      LoadKind.lighting: 0.9,
      LoadKind.socket: 0.4,
      LoadKind.heating: 0.8,
      LoadKind.hvac: 0.9,
      LoadKind.motor: 0.75,
      LoadKind.pump: 0.75,
      LoadKind.evCharger: 0.7,
    },
    'retail': {
      LoadKind.general: 0.8,
      LoadKind.lighting: 0.9,
      LoadKind.socket: 0.5,
      LoadKind.heating: 0.85,
      LoadKind.hvac: 0.9,
      LoadKind.motor: 0.8,
      LoadKind.pump: 0.8,
      LoadKind.evCharger: 0.7,
    },
    'hospital': {
      LoadKind.general: 0.8,
      LoadKind.lighting: 0.9,
      LoadKind.socket: 0.6,
      LoadKind.heating: 0.9,
      LoadKind.hvac: 0.95,
      LoadKind.motor: 0.85,
      LoadKind.pump: 0.85,
      LoadKind.evCharger: 0.7,
    },
    'hotel': {
      LoadKind.general: 0.6,
      LoadKind.lighting: 0.8,
      LoadKind.socket: 0.4,
      LoadKind.heating: 0.8,
      LoadKind.hvac: 0.85,
      LoadKind.motor: 0.75,
      LoadKind.pump: 0.75,
      LoadKind.evCharger: 0.6,
    },
    'industrial': {
      LoadKind.general: 0.8,
      LoadKind.lighting: 0.9,
      LoadKind.socket: 0.5,
      LoadKind.heating: 0.9,
      LoadKind.hvac: 0.85,
      LoadKind.motor: 0.85,
      LoadKind.pump: 0.85,
      LoadKind.evCharger: 0.8,
    },
  };

  @override
  List<String> get occupancyIds => _labels.keys.toList();

  @override
  String occupancyLabel(String occupancyId) =>
      _labels[occupancyId] ?? occupancyId;

  @override
  bool hasOccupancy(String occupancyId) => _table.containsKey(occupancyId);

  @override
  double demandFactorFor(
    String occupancyId,
    LoadKind loadKind, {
    required double fallback,
  }) {
    final byKind = _table[occupancyId];
    if (byKind == null) return fallback;
    final f = byKind[loadKind];
    if (f == null) return fallback;
    // Defensive clamp — a table edit can't push the factor out of 0..1.
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
  }
}

/// Unverified-value labels the diversity library introduces, for a report's
/// "verify against the official PUIL / IEC text" section.
const List<String> diversityLibraryVerifyItems = [
  'occupancy demand-factor library (residential / office / retail / hospital / '
      'hotel / industrial × lighting / socket / HVAC / motor / pump …)',
];

/// The diversity library as a single [StandardValue] honesty entry, so a report
/// (and any aggregate verify checklist) can surface it with its provenance tier.
const StandardValue<Object?> diversityLibraryStandardValue =
    StandardValue<Object?>(
  'occupancy diversity / demand-factor library',
  unit: 'table',
  citation:
      'IEC 60364-1 Annex / NEC Art. 220 demand-factor practice — engineering '
      'estimate (not a PUIL clause)',
  verified: false,
  status: VerificationStatus.secondarySource,
  note: 'Per-occupancy, per-load-kind demand (utilisation) factors are general '
      'LV engineering norms, NOT a verbatim PUIL 2011 / SNI 0225:2011 table. '
      'Verify the diversity assumptions against the official PUIL clause and '
      'the project brief before a submission.',
);
