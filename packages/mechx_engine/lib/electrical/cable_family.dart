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
import 'load_kind.dart' show LoadKind;

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

/// The conventional cable FAMILY for a circuit that hasn't been assigned an
/// explicit [ElectricalCircuit.cableType] — so a drawing names a real cable
/// construction (NYY / NYM) instead of the bare conductor material ("Cu"). The
/// Indonesian building convention:
///   • final sub-circuits (lighting / socket / general / heating) → **NYM**
///     (300/500 V sheathed PVC, the workhorse final-circuit cable);
///   • everything else — feeders, sub-mains, motors, pumps, HVAC, EV, welding,
///     UPS, capacitors, spares → **NYY** (0.6/1 kV power cable).
/// A drawing/labelling default only (the engineer overrides via `cableType`);
/// it never changes sizing (KHA still uses the panel-wide insulation fallback
/// when `cableType` is null). // VERIFY — drawing convention, not a PUIL clause.
String defaultCableFamily(LoadKind? kind) => switch (kind) {
      LoadKind.lighting ||
      LoadKind.socket ||
      LoadKind.general ||
      LoadKind.heating =>
        'NYM',
      _ => 'NYY',
    };

/// A DISTINCT construction description per cable family — the legend meaning a
/// drawing's KETERANGAN carries next to the family code. Fixes the N24 defect
/// where the electrical single-line legend printed the identical text
/// "Cable construction" against BOTH `NYY` and `NYM` (indistinguishable to a
/// reviewer): each family now names its own voltage rating / insulation /
/// typical use, ASCII-safe for the vector renderers. `BC` (bare copper) covers
/// the large-earth conductor the schedule tokens. An unknown family degrades to
/// a generic label (never blank). A drafting-office description, not an
/// engineering value — no `// VERIFY`.
String cableFamilyDescription(String family) => switch (family) {
      'NYY' => 'Power cable, PVC 0.6/1 kV (feeders / sub-mains)',
      'NYM' => 'Sheathed cable, PVC 300/500 V (final circuits)',
      'NYA' => 'Single-core, PVC 450/750 V (in conduit)',
      'NYAF' => 'Flexible single-core, PVC (panel wiring)',
      'FRC' => 'Fire-resistant cable, 90 C class (life-safety)',
      'BC' => 'Bare copper conductor (earthing)',
      _ => 'Cable construction ($family)',
    };
