/// AUTO-EMBEDDED catalogue dataset — DO NOT hand-edit the JSON below.
///
/// This is the verbatim PanelMaker `cables` catalogue file, embedded as a raw
/// `const String` so the pure-Dart engine can parse it with `dart:convert` at
/// load time (no asset / file I/O — the engine runs under `dart test`). The JSON
/// is transcribed-by-a-human verified manufacturer data ported from PanelMaker
/// at ref 8436cca3f471000eb86fffe520bc9c46e7b69e22; codes are NEVER machine-
/// generated. See `catalog.dart` for the projection onto [Part].
///
/// // VERIFY every order code / rating against the manufacturer datasheet
/// // before ordering — these are convenience references, not a substitute.
library;

/// `Part.manufacturer` brand label stamped onto every part from this dataset.
const String cablesCatalogBrand = "Generic";

/// The brand's catalogue JSON, embedded verbatim (see file header).
const String cablesCatalogJson = r'''
{
  "catalogVersion": "cables-sni-3",
  "manufacturer": "Generic",
  "source": "Standard Indonesian LV cable constructions (SNI/IEC, copper) across the standard conductor ladder: NYY (0.6/1 kV power), NYM (300/500 V sheathed indoor), NYA (450/750 V single-core in conduit), NYAF (flexible panel wiring) BC (bare copper, earthing) and FRC (fire-resistant 0.6/1 kV, mica-taped — life-safety circuits: fire pumps, smoke control, emergency lighting). These are generic type+size references — NOT brand-specific order codes — so the BOM can match and price cable runs; substitute a specific maker (Supreme, Kabelindo, Jembo, Voksel, KMI, Prysmian) and verify the KHA/derating against the datasheet and PUIL 2011.",
  "parts": [
    {"sku": "NYY-1.5", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 1.5 mm² Cu", "unit": "m", "attributes": {"csaMm2": 1.5, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-2.5", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 2.5 mm² Cu", "unit": "m", "attributes": {"csaMm2": 2.5, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-4", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 4 mm² Cu", "unit": "m", "attributes": {"csaMm2": 4, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-6", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 6 mm² Cu", "unit": "m", "attributes": {"csaMm2": 6, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-10", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 10 mm² Cu", "unit": "m", "attributes": {"csaMm2": 10, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-16", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 16 mm² Cu", "unit": "m", "attributes": {"csaMm2": 16, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-25", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 25 mm² Cu", "unit": "m", "attributes": {"csaMm2": 25, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-35", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 35 mm² Cu", "unit": "m", "attributes": {"csaMm2": 35, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-50", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 50 mm² Cu", "unit": "m", "attributes": {"csaMm2": 50, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-70", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 70 mm² Cu", "unit": "m", "attributes": {"csaMm2": 70, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-95", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 95 mm² Cu", "unit": "m", "attributes": {"csaMm2": 95, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-120", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 120 mm² Cu", "unit": "m", "attributes": {"csaMm2": 120, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-150", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 150 mm² Cu", "unit": "m", "attributes": {"csaMm2": 150, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-185", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 185 mm² Cu", "unit": "m", "attributes": {"csaMm2": 185, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-240", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 240 mm² Cu", "unit": "m", "attributes": {"csaMm2": 240, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYY-300", "category": "cable", "series": "NYY 0.6/1kV", "model": "NYY 300 mm² Cu", "unit": "m", "attributes": {"csaMm2": 300, "type": "NYY", "conductor": "Cu", "voltageRating": "0.6/1 kV"}},
    {"sku": "NYM-1.5", "category": "cable", "series": "NYM 300/500V", "model": "NYM 1.5 mm² Cu", "unit": "m", "attributes": {"csaMm2": 1.5, "type": "NYM", "conductor": "Cu", "voltageRating": "300/500 V"}},
    {"sku": "NYM-2.5", "category": "cable", "series": "NYM 300/500V", "model": "NYM 2.5 mm² Cu", "unit": "m", "attributes": {"csaMm2": 2.5, "type": "NYM", "conductor": "Cu", "voltageRating": "300/500 V"}},
    {"sku": "NYM-4", "category": "cable", "series": "NYM 300/500V", "model": "NYM 4 mm² Cu", "unit": "m", "attributes": {"csaMm2": 4, "type": "NYM", "conductor": "Cu", "voltageRating": "300/500 V"}},
    {"sku": "NYM-6", "category": "cable", "series": "NYM 300/500V", "model": "NYM 6 mm² Cu", "unit": "m", "attributes": {"csaMm2": 6, "type": "NYM", "conductor": "Cu", "voltageRating": "300/500 V"}},
    {"sku": "NYM-10", "category": "cable", "series": "NYM 300/500V", "model": "NYM 10 mm² Cu", "unit": "m", "attributes": {"csaMm2": 10, "type": "NYM", "conductor": "Cu", "voltageRating": "300/500 V"}},
    {"sku": "NYA-1.5", "category": "cable", "series": "NYA 450/750V", "model": "NYA 1.5 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 1.5, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-2.5", "category": "cable", "series": "NYA 450/750V", "model": "NYA 2.5 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 2.5, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-4", "category": "cable", "series": "NYA 450/750V", "model": "NYA 4 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 4, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-6", "category": "cable", "series": "NYA 450/750V", "model": "NYA 6 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 6, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-10", "category": "cable", "series": "NYA 450/750V", "model": "NYA 10 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 10, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-16", "category": "cable", "series": "NYA 450/750V", "model": "NYA 16 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 16, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-25", "category": "cable", "series": "NYA 450/750V", "model": "NYA 25 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 25, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-35", "category": "cable", "series": "NYA 450/750V", "model": "NYA 35 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 35, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-50", "category": "cable", "series": "NYA 450/750V", "model": "NYA 50 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 50, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-70", "category": "cable", "series": "NYA 450/750V", "model": "NYA 70 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 70, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYA-95", "category": "cable", "series": "NYA 450/750V", "model": "NYA 95 mm² Cu (single-core)", "unit": "m", "attributes": {"csaMm2": 95, "type": "NYA", "conductor": "Cu", "cores": 1, "voltageRating": "450/750 V"}},
    {"sku": "NYAF-0.75", "category": "cable", "series": "NYAF flexible", "model": "NYAF 0.75 mm² Cu (flexible)", "unit": "m", "attributes": {"csaMm2": 0.75, "type": "NYAF", "conductor": "Cu (flexible)", "voltageRating": "450/750 V"}},
    {"sku": "NYAF-1", "category": "cable", "series": "NYAF flexible", "model": "NYAF 1 mm² Cu (flexible)", "unit": "m", "attributes": {"csaMm2": 1, "type": "NYAF", "conductor": "Cu (flexible)", "voltageRating": "450/750 V"}},
    {"sku": "NYAF-1.5", "category": "cable", "series": "NYAF flexible", "model": "NYAF 1.5 mm² Cu (flexible)", "unit": "m", "attributes": {"csaMm2": 1.5, "type": "NYAF", "conductor": "Cu (flexible)", "voltageRating": "450/750 V"}},
    {"sku": "NYAF-2.5", "category": "cable", "series": "NYAF flexible", "model": "NYAF 2.5 mm² Cu (flexible)", "unit": "m", "attributes": {"csaMm2": 2.5, "type": "NYAF", "conductor": "Cu (flexible)", "voltageRating": "450/750 V"}},
    {"sku": "NYAF-4", "category": "cable", "series": "NYAF flexible", "model": "NYAF 4 mm² Cu (flexible)", "unit": "m", "attributes": {"csaMm2": 4, "type": "NYAF", "conductor": "Cu (flexible)", "voltageRating": "450/750 V"}},
    {"sku": "NYAF-6", "category": "cable", "series": "NYAF flexible", "model": "NYAF 6 mm² Cu (flexible)", "unit": "m", "attributes": {"csaMm2": 6, "type": "NYAF", "conductor": "Cu (flexible)", "voltageRating": "450/750 V"}},
    {"sku": "NYAF-10", "category": "cable", "series": "NYAF flexible", "model": "NYAF 10 mm² Cu (flexible)", "unit": "m", "attributes": {"csaMm2": 10, "type": "NYAF", "conductor": "Cu (flexible)", "voltageRating": "450/750 V"}},
    {"sku": "BC-6", "category": "cable", "series": "BC bare copper", "model": "BC 6 mm² bare copper (earthing)", "unit": "m", "attributes": {"csaMm2": 6, "type": "BC", "conductor": "Cu (bare)", "use": "earthing/bonding"}},
    {"sku": "BC-10", "category": "cable", "series": "BC bare copper", "model": "BC 10 mm² bare copper (earthing)", "unit": "m", "attributes": {"csaMm2": 10, "type": "BC", "conductor": "Cu (bare)", "use": "earthing/bonding"}},
    {"sku": "BC-16", "category": "cable", "series": "BC bare copper", "model": "BC 16 mm² bare copper (earthing)", "unit": "m", "attributes": {"csaMm2": 16, "type": "BC", "conductor": "Cu (bare)", "use": "earthing/bonding"}},
    {"sku": "BC-25", "category": "cable", "series": "BC bare copper", "model": "BC 25 mm² bare copper (earthing)", "unit": "m", "attributes": {"csaMm2": 25, "type": "BC", "conductor": "Cu (bare)", "use": "earthing/bonding"}},
    {"sku": "BC-35", "category": "cable", "series": "BC bare copper", "model": "BC 35 mm² bare copper (earthing)", "unit": "m", "attributes": {"csaMm2": 35, "type": "BC", "conductor": "Cu (bare)", "use": "earthing/bonding"}},
    {"sku": "BC-50", "category": "cable", "series": "BC bare copper", "model": "BC 50 mm² bare copper (earthing)", "unit": "m", "attributes": {"csaMm2": 50, "type": "BC", "conductor": "Cu (bare)", "use": "earthing/bonding"}},
    {"sku": "BC-70", "category": "cable", "series": "BC bare copper", "model": "BC 70 mm² bare copper (earthing)", "unit": "m", "attributes": {"csaMm2": 70, "type": "BC", "conductor": "Cu (bare)", "use": "earthing/bonding"}},
    {"sku": "BC-95", "category": "cable", "series": "BC bare copper", "model": "BC 95 mm² bare copper (earthing)", "unit": "m", "attributes": {"csaMm2": 95, "type": "BC", "conductor": "Cu (bare)", "use": "earthing/bonding"}},
    {"sku": "FRC-1.5", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 1.5 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 1.5, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-2.5", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 2.5 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 2.5, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-4", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 4 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 4, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-6", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 6 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 6, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-10", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 10 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 10, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-16", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 16 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 16, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-25", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 25 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 25, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-35", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 35 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 35, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-50", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 50 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 50, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-70", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 70 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 70, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}},
    {"sku": "FRC-95", "category": "cable", "series": "FRC 0.6/1kV fire-resistant", "model": "FRC 95 mm² Cu (mica)", "unit": "m", "attributes": {"csaMm2": 95, "type": "FRC", "conductor": "Cu", "voltageRating": "0.6/1 kV", "fireResistance": "PH120 / IEC 60331"}}
  ]
}
''';
