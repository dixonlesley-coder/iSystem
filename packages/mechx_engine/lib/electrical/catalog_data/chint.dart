/// AUTO-EMBEDDED catalogue dataset — DO NOT hand-edit the JSON below.
///
/// This is the verbatim PanelMaker `chint` catalogue file, embedded as a raw
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
const String chintCatalogBrand = "Chint";

/// The brand's catalogue JSON, embedded verbatim (see file header).
const String chintCatalogJson = r'''
{
  "catalogVersion": "chint-1",
  "manufacturer": "Chint",
  "source": "Chint low-voltage components transcribed from CHINT Global product pages, catalogues and reputable distributor listings (2026). Series covered: NXB-63 MCBs (IEC/EN 60898-1), NXBLE-63 RCBOs (IEC/EN 61009-1), NXM MCCBs (IEC/EN 60947-2), NXC AC contactors (IEC/EN 60947-4-1, AC-3) and NXR thermal overload relays (IEC/EN 60947-4-1). Order references use Chint type designation + configuration. Primary sources: https://www.chintglobal.com/global/en/products/low-voltage/iec/final-power-distribution/nxb-63.html ; https://www.chintglobal.com/global/en/products/low-voltage/iec/final-power-distribution/nxble-63.html ; https://www.chintglobal.com/global/en/products/low-voltage/iec/secondary-power-distribution/nxm.html ; https://www.chintglobal.com/global/en/products/low-voltage/iec/industrial-control/nxc.html ; https://www.chintglobal.com/global/en/products/low-voltage/iec/industrial-control/nxr.html . Cross-checked against distributor listings (sntelec.com, zorkelectric.com, lcsc.com, en.chint.id, latinafy.com). Ratings (current/curve/pole/Icu/coil) reflect catalogue data at time of transcription. Verify every order code/rating against the manufacturer datasheet before ordering.",
  "parts": [
    {
      "sku": "NXB-63 1P B6",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P B6",
      "attributes": { "deviceClass": "MCB", "ratingA": 6, "poles": 1, "curve": "B", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P B10",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P B10",
      "attributes": { "deviceClass": "MCB", "ratingA": 10, "poles": 1, "curve": "B", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P B16",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P B16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 1, "curve": "B", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P B20",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P B20",
      "attributes": { "deviceClass": "MCB", "ratingA": 20, "poles": 1, "curve": "B", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P B25",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P B25",
      "attributes": { "deviceClass": "MCB", "ratingA": 25, "poles": 1, "curve": "B", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P B32",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P B32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 1, "curve": "B", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P B40",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P B40",
      "attributes": { "deviceClass": "MCB", "ratingA": 40, "poles": 1, "curve": "B", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P B63",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P B63",
      "attributes": { "deviceClass": "MCB", "ratingA": 63, "poles": 1, "curve": "B", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P C6",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P C6",
      "attributes": { "deviceClass": "MCB", "ratingA": 6, "poles": 1, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P C10",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P C10",
      "attributes": { "deviceClass": "MCB", "ratingA": 10, "poles": 1, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P C16",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P C16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 1, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P C20",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P C20",
      "attributes": { "deviceClass": "MCB", "ratingA": 20, "poles": 1, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P C25",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P C25",
      "attributes": { "deviceClass": "MCB", "ratingA": 25, "poles": 1, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P C32",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P C32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 1, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P C40",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P C40",
      "attributes": { "deviceClass": "MCB", "ratingA": 40, "poles": 1, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P C63",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P C63",
      "attributes": { "deviceClass": "MCB", "ratingA": 63, "poles": 1, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P D16",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P D16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 1, "curve": "D", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 1P D32",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 1P D32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 1, "curve": "D", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 2P C16",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 2P C16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 2, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 2P C25",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 2P C25",
      "attributes": { "deviceClass": "MCB", "ratingA": 25, "poles": 2, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 2P C32",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 2P C32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 2, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 2P C40",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 2P C40",
      "attributes": { "deviceClass": "MCB", "ratingA": 40, "poles": 2, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 2P C63",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 2P C63",
      "attributes": { "deviceClass": "MCB", "ratingA": 63, "poles": 2, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 3P C10",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 3P C10",
      "attributes": { "deviceClass": "MCB", "ratingA": 10, "poles": 3, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 3P C16",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 3P C16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 3, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 3P C20",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 3P C20",
      "attributes": { "deviceClass": "MCB", "ratingA": 20, "poles": 3, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 3P C25",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 3P C25",
      "attributes": { "deviceClass": "MCB", "ratingA": 25, "poles": 3, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 3P C32",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 3P C32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 3, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 3P C40",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 3P C40",
      "attributes": { "deviceClass": "MCB", "ratingA": 40, "poles": 3, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 3P C50",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 3P C50",
      "attributes": { "deviceClass": "MCB", "ratingA": 50, "poles": 3, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 3P C63",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 3P C63",
      "attributes": { "deviceClass": "MCB", "ratingA": 63, "poles": 3, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 3P D32",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 3P D32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 3, "curve": "D", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 4P C16",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 4P C16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 4, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 4P C32",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 4P C32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 4, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXB-63 4P C63",
      "category": "breaker",
      "series": "NXB-63",
      "model": "NXB-63 4P C63",
      "attributes": { "deviceClass": "MCB", "ratingA": 63, "poles": 4, "curve": "C", "breakingKa": 6, "standard": "IEC 60898-1" }
    },
    {
      "sku": "NXBLE-63 1P+N C16 30mA",
      "category": "breaker",
      "series": "NXBLE-63",
      "model": "NXBLE-63 1P+N C16 30mA",
      "attributes": { "deviceClass": "RCBO", "ratingA": 16, "poles": 2, "curve": "C", "breakingKa": 6, "residualMa": 30, "standard": "IEC 61009-1" }
    },
    {
      "sku": "NXBLE-63 1P+N C20 30mA",
      "category": "breaker",
      "series": "NXBLE-63",
      "model": "NXBLE-63 1P+N C20 30mA",
      "attributes": { "deviceClass": "RCBO", "ratingA": 20, "poles": 2, "curve": "C", "breakingKa": 6, "residualMa": 30, "standard": "IEC 61009-1" }
    },
    {
      "sku": "NXBLE-63 1P+N C25 30mA",
      "category": "breaker",
      "series": "NXBLE-63",
      "model": "NXBLE-63 1P+N C25 30mA",
      "attributes": { "deviceClass": "RCBO", "ratingA": 25, "poles": 2, "curve": "C", "breakingKa": 6, "residualMa": 30, "standard": "IEC 61009-1" }
    },
    {
      "sku": "NXBLE-63 1P+N C32 30mA",
      "category": "breaker",
      "series": "NXBLE-63",
      "model": "NXBLE-63 1P+N C32 30mA",
      "attributes": { "deviceClass": "RCBO", "ratingA": 32, "poles": 2, "curve": "C", "breakingKa": 6, "residualMa": 30, "standard": "IEC 61009-1" }
    },
    {
      "sku": "NXBLE-63 1P+N C40 30mA",
      "category": "breaker",
      "series": "NXBLE-63",
      "model": "NXBLE-63 1P+N C40 30mA",
      "attributes": { "deviceClass": "RCBO", "ratingA": 40, "poles": 2, "curve": "C", "breakingKa": 6, "residualMa": 30, "standard": "IEC 61009-1" }
    },
    {
      "sku": "NXBLE-63 1P+N C63 30mA",
      "category": "breaker",
      "series": "NXBLE-63",
      "model": "NXBLE-63 1P+N C63 30mA",
      "attributes": { "deviceClass": "RCBO", "ratingA": 63, "poles": 2, "curve": "C", "breakingKa": 6, "residualMa": 30, "standard": "IEC 61009-1" }
    },
    {
      "sku": "NXM-125S/3300 100A",
      "category": "breaker",
      "series": "NXM-125",
      "model": "NXM-125S/3300 100A",
      "attributes": { "deviceClass": "MCCB", "ratingA": 100, "poles": 3, "frameA": 125, "standard": "IEC 60947-2" }
    },
    {
      "sku": "NXM-125S/3300 125A",
      "category": "breaker",
      "series": "NXM-125",
      "model": "NXM-125S/3300 125A",
      "attributes": { "deviceClass": "MCCB", "ratingA": 125, "poles": 3, "frameA": 125, "standard": "IEC 60947-2" }
    },
    {
      "sku": "NXM-250S/3300 250A",
      "category": "breaker",
      "series": "NXM-250",
      "model": "NXM-250S/3300 250A",
      "attributes": { "deviceClass": "MCCB", "ratingA": 250, "poles": 3, "frameA": 250, "standard": "IEC 60947-2" }
    },
    {
      "sku": "NXM-400S/3300 400A",
      "category": "breaker",
      "series": "NXM-400",
      "model": "NXM-400S/3300 400A",
      "attributes": { "deviceClass": "MCCB", "ratingA": 400, "poles": 3, "frameA": 400, "standard": "IEC 60947-2" }
    },
    {
      "sku": "NXM-630S/3300 630A",
      "category": "breaker",
      "series": "NXM-630",
      "model": "NXM-630S/3300 630A",
      "attributes": { "deviceClass": "MCCB", "ratingA": 630, "poles": 3, "frameA": 630, "standard": "IEC 60947-2" }
    },
    {
      "sku": "NXC-09 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-09",
      "attributes": { "ratingA": 9, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 4, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-12 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-12",
      "attributes": { "ratingA": 12, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 5.5, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-18 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-18",
      "attributes": { "ratingA": 18, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 7.5, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-25 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-25",
      "attributes": { "ratingA": 25, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 11, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-32 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-32",
      "attributes": { "ratingA": 32, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 15, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-40 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-40",
      "attributes": { "ratingA": 40, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 18.5, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-50 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-50",
      "attributes": { "ratingA": 50, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 22, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-65 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-65",
      "attributes": { "ratingA": 65, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 30, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-75 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-75",
      "attributes": { "ratingA": 75, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 37, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-100 230V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-100",
      "attributes": { "ratingA": 100, "poles": 3, "coilV": 230, "acClass": "AC-3", "motorKw400V": 45, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-09 400V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-09",
      "attributes": { "ratingA": 9, "poles": 3, "coilV": 400, "acClass": "AC-3", "motorKw400V": 4, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-18 400V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-18",
      "attributes": { "ratingA": 18, "poles": 3, "coilV": 400, "acClass": "AC-3", "motorKw400V": 7.5, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-25 400V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-25",
      "attributes": { "ratingA": 25, "poles": 3, "coilV": 400, "acClass": "AC-3", "motorKw400V": 11, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-09 110V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-09",
      "attributes": { "ratingA": 9, "poles": 3, "coilV": 110, "acClass": "AC-3", "motorKw400V": 4, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXC-65 110V",
      "category": "contactor",
      "series": "NXC",
      "model": "NXC-65",
      "attributes": { "ratingA": 65, "poles": 3, "coilV": 110, "acClass": "AC-3", "motorKw400V": 30, "standard": "IEC 60947-4-1" }
    },
    {
      "sku": "NXR-25 0.4-0.63A",
      "category": "overload_relay",
      "series": "NXR-25",
      "model": "NXR-25 0.4-0.63A",
      "attributes": { "currentMinA": 0.4, "currentMaxA": 0.63, "standard": "IEC 60947-4-1", "pairsWith": "NXC-09..NXC-25" }
    },
    {
      "sku": "NXR-25 0.63-1A",
      "category": "overload_relay",
      "series": "NXR-25",
      "model": "NXR-25 0.63-1A",
      "attributes": { "currentMinA": 0.63, "currentMaxA": 1, "standard": "IEC 60947-4-1", "pairsWith": "NXC-09..NXC-25" }
    },
    {
      "sku": "NXR-25 1-1.6A",
      "category": "overload_relay",
      "series": "NXR-25",
      "model": "NXR-25 1-1.6A",
      "attributes": { "currentMinA": 1, "currentMaxA": 1.6, "standard": "IEC 60947-4-1", "pairsWith": "NXC-09..NXC-25" }
    },
    {
      "sku": "NXR-25 4-6A",
      "category": "overload_relay",
      "series": "NXR-25",
      "model": "NXR-25 4-6A",
      "attributes": { "currentMinA": 4, "currentMaxA": 6, "standard": "IEC 60947-4-1", "pairsWith": "NXC-09..NXC-25" }
    },
    {
      "sku": "NXR-25 17-25A",
      "category": "overload_relay",
      "series": "NXR-25",
      "model": "NXR-25 17-25A",
      "attributes": { "currentMinA": 17, "currentMaxA": 25, "standard": "IEC 60947-4-1", "pairsWith": "NXC-09..NXC-25" }
    },
    {
      "sku": "NXR-38 23-32A",
      "category": "overload_relay",
      "series": "NXR-38",
      "model": "NXR-38 23-32A",
      "attributes": { "currentMinA": 23, "currentMaxA": 32, "standard": "IEC 60947-4-1", "pairsWith": "NXC-32..NXC-38" }
    },
    {
      "sku": "NXR-38 30-40A",
      "category": "overload_relay",
      "series": "NXR-38",
      "model": "NXR-38 30-40A",
      "attributes": { "currentMinA": 30, "currentMaxA": 40, "standard": "IEC 60947-4-1", "pairsWith": "NXC-32..NXC-38" }
    },
    {
      "sku": "NXR-100 37-50A",
      "category": "overload_relay",
      "series": "NXR-100",
      "model": "NXR-100 37-50A",
      "attributes": { "currentMinA": 37, "currentMaxA": 50, "standard": "IEC 60947-4-1", "pairsWith": "NXC-40..NXC-100" }
    },
    {
      "sku": "NXR-100 48-65A",
      "category": "overload_relay",
      "series": "NXR-100",
      "model": "NXR-100 48-65A",
      "attributes": { "currentMinA": 48, "currentMaxA": 65, "standard": "IEC 60947-4-1", "pairsWith": "NXC-40..NXC-100" }
    },
    {
      "sku": "NXR-100 80-100A",
      "category": "overload_relay",
      "series": "NXR-100",
      "model": "NXR-100 80-100A",
      "attributes": { "currentMinA": 80, "currentMaxA": 100, "standard": "IEC 60947-4-1", "pairsWith": "NXC-40..NXC-100" }
    }
  ]
}
''';
