/// Cable-family construction facts for the Indonesian LV families the app
/// offers (NYY / NYM / NYA / NYAF / FRC). The Supreme Cable (SUCACO) catalogue
/// publishes current-carrying capacity (KHA) per cable TYPE; the engine's
/// ampacity tables ([ElectricalStandardsProfile.ampacity]) are keyed by
/// insulation temperature-class × install method × section (the IEC 60364-5-52
/// model the catalogue figures map onto). This file is the missing link: it
/// resolves a circuit's chosen family to the insulation class its construction
/// dictates, so the family — not just the panel-wide default — drives KHA.
///
/// Provenance: `secondarySource` — these classes are standard Indonesian cable
/// constructions (Supreme/SUCACO catalogue + SNI/IEC), pending confirmation
/// against the official datasheet. // VERIFY each family's temperature class
/// (and any per-family KHA that departs from the generic method table) against
/// the Supreme datasheet before a quotation relies on it.
library;

import '../standards/puil.dart' show ConductorInsulation;

/// The conductor insulation temperature-class for each cable family:
///   • NYY (0.6/1 kV power), NYM (300/500 V sheathed), NYA (450/750 V single-
///     core), NYAF (flexible panel wiring) — PVC, 70 °C.
///   • FRC (fire-resistant, mica-taped — life-safety) — 90 °C class; sized on
///     the XLPE (90 °C) table, matching its continuous rating.
const Map<String, ConductorInsulation> cableFamilyInsulation = {
  'NYY': ConductorInsulation.pvc,
  'NYM': ConductorInsulation.pvc,
  'NYA': ConductorInsulation.pvc,
  'NYAF': ConductorInsulation.pvc,
  'FRC': ConductorInsulation.xlpe,
};

/// The insulation to size a run on: the family's own class when a [cableType]
/// is specified and known, else the panel-wide [fallback] (so an untyped
/// circuit is byte-identical to the prior behaviour).
ConductorInsulation insulationForCableType(
  String? cableType, {
  required ConductorInsulation fallback,
}) =>
    cableType == null ? fallback : (cableFamilyInsulation[cableType] ?? fallback);
