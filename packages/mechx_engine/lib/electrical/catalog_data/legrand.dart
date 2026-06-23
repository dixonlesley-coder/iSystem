/// AUTO-EMBEDDED catalogue dataset — DO NOT hand-edit the JSON below.
///
/// This is the verbatim PanelMaker `legrand` catalogue file, embedded as a raw
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
const String legrandCatalogBrand = "Legrand";

/// The brand's catalogue JSON, embedded verbatim (see file header).
const String legrandCatalogJson = r'''
{
  "catalogVersion": "legrand-1",
  "manufacturer": "Legrand",
  "source": "Verified Legrand low-voltage components transcribed from authoritative sources: Legrand International e-catalogue (legrand.com/ecatalogue), Legrand country e-catalogues (legrand.co.uk, legrand.es, legrand.com.lb, legrand.com.sg, ecatalogue.legrand.co.in), and reputable distributors (TME / Transfer Multisort Elektronik, RS Components, PowerFactorShop, Vashi Integrated Solutions). Each numeric catalogue (order) reference, pole count, rating, curve and Icu/breaking capacity was read directly from a product listing title; no order code was generated, extrapolated or pattern-completed. Families covered: DX3 6000 (10 kA) MCBs (1P/2P/3P/4P, B & C curves), DX3 6000 RCBOs (1P+N / 2P / 4P, type AC, 30 mA), DX3 RCCBs, DPX3 160 / DPX3 250 / DPX3 630 MCCBs, CTX3 contactors (AC-3), and RTX3 thermal overload relays. Catalogue codes are convenience references only. Verify every order code/rating against the manufacturer datasheet before ordering.",
  "sourceUrls": [
    "https://www.legrand.com/ecatalogue/",
    "https://www.legrand.co.uk/en/catalog/products/",
    "https://www.tme.com/",
    "https://www.powerfactorshop.com/",
    "https://ecatalogue.legrand.co.in/"
  ],
  "parts": [
    {
      "sku": "407666",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P C 6A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 6, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407668",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P C 10A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 10, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407670",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P C 16A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 16, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407671",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P C 20A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 20, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407672",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P C 25A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 25, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407673",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P C 32A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 32, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407674",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P C 40A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 40, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407675",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P C 50A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 50, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407676",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P C 63A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 63, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407798",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 2P C 10A",
      "attributes": { "deviceClass": "MCB", "poles": 2, "ratingA": 10, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407800",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 2P C 16A",
      "attributes": { "deviceClass": "MCB", "poles": 2, "ratingA": 16, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407801",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 2P C 20A",
      "attributes": { "deviceClass": "MCB", "poles": 2, "ratingA": 20, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407802",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 2P C 25A",
      "attributes": { "deviceClass": "MCB", "poles": 2, "ratingA": 25, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407803",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 2P C 32A",
      "attributes": { "deviceClass": "MCB", "poles": 2, "ratingA": 32, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407804",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 2P C 40A",
      "attributes": { "deviceClass": "MCB", "poles": 2, "ratingA": 40, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407806",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 2P C 63A",
      "attributes": { "deviceClass": "MCB", "poles": 2, "ratingA": 63, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407855",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P C 6A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 6, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407857",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P C 10A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 10, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407859",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P C 16A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 16, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407860",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P C 20A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 20, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407861",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P C 25A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 25, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407862",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P C 32A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 32, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407863",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P C 40A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 40, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407864",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P C 50A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 50, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407865",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P C 63A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 63, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407927",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 4P C 13A",
      "attributes": { "deviceClass": "MCB", "poles": 4, "ratingA": 13, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407928",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 4P C 16A",
      "attributes": { "deviceClass": "MCB", "poles": 4, "ratingA": 16, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407930",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 4P C 25A",
      "attributes": { "deviceClass": "MCB", "poles": 4, "ratingA": 25, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407931",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 4P C 32A",
      "attributes": { "deviceClass": "MCB", "poles": 4, "ratingA": 32, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407932",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 4P C 40A",
      "attributes": { "deviceClass": "MCB", "poles": 4, "ratingA": 40, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407933",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 4P C 50A",
      "attributes": { "deviceClass": "MCB", "poles": 4, "ratingA": 50, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407934",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 4P C 63A",
      "attributes": { "deviceClass": "MCB", "poles": 4, "ratingA": 63, "curve": "C", "breakingKa": 10 }
    },
    {
      "sku": "407426",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 1P B 2A",
      "attributes": { "deviceClass": "MCB", "poles": 1, "ratingA": 2, "curve": "B", "breakingKa": 10 }
    },
    {
      "sku": "407509",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 2P B 16A",
      "attributes": { "deviceClass": "MCB", "poles": 2, "ratingA": 16, "curve": "B", "breakingKa": 10 }
    },
    {
      "sku": "407561",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P B 16A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 16, "curve": "B", "breakingKa": 10 }
    },
    {
      "sku": "407567",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA",
      "model": "DX³ 6000 3P B 63A",
      "attributes": { "deviceClass": "MCB", "poles": 3, "ratingA": 63, "curve": "B", "breakingKa": 10 }
    },
    {
      "sku": "411002",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA RCBO",
      "model": "DX³ 6000 1P+N C 16A 30mA type AC",
      "attributes": { "deviceClass": "RCBO", "poles": 2, "ratingA": 16, "curve": "C", "breakingKa": 10, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "411003",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA RCBO",
      "model": "DX³ 6000 1P+N C 20A 30mA type AC",
      "attributes": { "deviceClass": "RCBO", "poles": 2, "ratingA": 20, "curve": "C", "breakingKa": 10, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "411005",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA RCBO",
      "model": "DX³ 6000 1P+N C 32A 30mA type AC",
      "attributes": { "deviceClass": "RCBO", "poles": 2, "ratingA": 32, "curve": "C", "breakingKa": 10, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "411163",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA RCBO",
      "model": "DX³ 6000 2P C 50A 30mA type AC",
      "attributes": { "deviceClass": "RCBO", "poles": 2, "ratingA": 50, "curve": "C", "breakingKa": 10, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "411185",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA RCBO",
      "model": "DX³ 6000 4P C 10A 30mA type AC",
      "attributes": { "deviceClass": "RCBO", "poles": 4, "ratingA": 10, "curve": "C", "breakingKa": 10, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "411187",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA RCBO",
      "model": "DX³ 6000 4P C 20A 30mA type AC",
      "attributes": { "deviceClass": "RCBO", "poles": 4, "ratingA": 20, "curve": "C", "breakingKa": 10, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "411189",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA RCBO",
      "model": "DX³ 6000 4P C 32A 30mA type AC",
      "attributes": { "deviceClass": "RCBO", "poles": 4, "ratingA": 32, "curve": "C", "breakingKa": 10, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "411191",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA RCBO",
      "model": "DX³ 6000 4P C 50A 30mA type AC",
      "attributes": { "deviceClass": "RCBO", "poles": 4, "ratingA": 50, "curve": "C", "breakingKa": 10, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "411192",
      "category": "breaker",
      "series": "DX³ 6000 / 10kA RCBO",
      "model": "DX³ 6000 4P C 63A 30mA type AC",
      "attributes": { "deviceClass": "RCBO", "poles": 4, "ratingA": 63, "curve": "C", "breakingKa": 10, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "411556",
      "category": "breaker",
      "series": "DX³ RCCB",
      "model": "DX³ RCCB 2P 63A 30mA type A",
      "attributes": { "deviceClass": "RCCB", "poles": 2, "ratingA": 63, "residualMa": 30, "rcdType": "A" }
    },
    {
      "sku": "411661",
      "category": "breaker",
      "series": "DX³ RCCB",
      "model": "DX³ RCCB 4P 40A 30mA type AC",
      "attributes": { "deviceClass": "RCCB", "poles": 4, "ratingA": 40, "residualMa": 30, "rcdType": "AC" }
    },
    {
      "sku": "420000",
      "category": "breaker",
      "series": "DPX³ 160 / 16kA",
      "model": "DPX³ 160 3P 16A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 16, "breakingKa": 16, "icuKa": 16, "frameA": 160 }
    },
    {
      "sku": "420001",
      "category": "breaker",
      "series": "DPX³ 160 / 16kA",
      "model": "DPX³ 160 3P 25A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 25, "breakingKa": 16, "icuKa": 16, "frameA": 160 }
    },
    {
      "sku": "420002",
      "category": "breaker",
      "series": "DPX³ 160 / 16kA",
      "model": "DPX³ 160 3P 40A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 40, "breakingKa": 16, "icuKa": 16, "frameA": 160 }
    },
    {
      "sku": "420003",
      "category": "breaker",
      "series": "DPX³ 160 / 16kA",
      "model": "DPX³ 160 3P 63A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 63, "breakingKa": 16, "icuKa": 16, "frameA": 160 }
    },
    {
      "sku": "420005",
      "category": "breaker",
      "series": "DPX³ 160 / 16kA",
      "model": "DPX³ 160 3P 100A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 100, "breakingKa": 16, "icuKa": 16, "frameA": 160 }
    },
    {
      "sku": "420006",
      "category": "breaker",
      "series": "DPX³ 160 / 16kA",
      "model": "DPX³ 160 3P 125A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 125, "breakingKa": 16, "icuKa": 16, "frameA": 160 }
    },
    {
      "sku": "420007",
      "category": "breaker",
      "series": "DPX³ 160 / 16kA",
      "model": "DPX³ 160 3P 160A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 160, "breakingKa": 16, "icuKa": 16, "frameA": 160 }
    },
    {
      "sku": "420207",
      "category": "breaker",
      "series": "DPX³ 250 / 25kA",
      "model": "DPX³ 250 3P 160A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 160, "breakingKa": 25, "icuKa": 25, "frameA": 250 }
    },
    {
      "sku": "420208",
      "category": "breaker",
      "series": "DPX³ 250 / 25kA",
      "model": "DPX³ 250 3P 200A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 200, "breakingKa": 25, "icuKa": 25, "frameA": 250 }
    },
    {
      "sku": "420237",
      "category": "breaker",
      "series": "DPX³ 250 / 36kA",
      "model": "DPX³ 250 3P 160A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 160, "breakingKa": 36, "icuKa": 36, "frameA": 250 }
    },
    {
      "sku": "420238",
      "category": "breaker",
      "series": "DPX³ 250 / 36kA",
      "model": "DPX³ 250 3P 200A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 200, "breakingKa": 36, "icuKa": 36, "frameA": 250 }
    },
    {
      "sku": "420239",
      "category": "breaker",
      "series": "DPX³ 250 / 36kA",
      "model": "DPX³ 250 3P 250A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 250, "breakingKa": 36, "icuKa": 36, "frameA": 250 }
    },
    {
      "sku": "422002",
      "category": "breaker",
      "series": "DPX³ 630 / 36kA",
      "model": "DPX³ 630 3P 400A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 400, "breakingKa": 36, "icuKa": 36, "frameA": 630 }
    },
    {
      "sku": "422003",
      "category": "breaker",
      "series": "DPX³ 630 / 36kA",
      "model": "DPX³ 630 3P 500A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 500, "breakingKa": 36, "icuKa": 36, "frameA": 630 }
    },
    {
      "sku": "422004",
      "category": "breaker",
      "series": "DPX³ 630 / 36kA",
      "model": "DPX³ 630 3P 630A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 630, "breakingKa": 36, "icuKa": 36, "frameA": 630 }
    },
    {
      "sku": "422016",
      "category": "breaker",
      "series": "DPX³ 630 / 50kA",
      "model": "DPX³ 630 3P 400A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 400, "breakingKa": 50, "icuKa": 50, "frameA": 630 }
    },
    {
      "sku": "422017",
      "category": "breaker",
      "series": "DPX³ 630 / 50kA",
      "model": "DPX³ 630 3P 500A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 500, "breakingKa": 50, "icuKa": 50, "frameA": 630 }
    },
    {
      "sku": "422018",
      "category": "breaker",
      "series": "DPX³ 630 / 50kA",
      "model": "DPX³ 630 3P 630A thermal-magnetic",
      "attributes": { "deviceClass": "MCCB", "poles": 3, "ratingA": 630, "breakingKa": 50, "icuKa": 50, "frameA": 630 }
    },
    {
      "sku": "416086",
      "category": "contactor",
      "series": "CTX³ 22",
      "model": "CTX³ 22 3P 9A AC-3 230V~ 1NO+1NC",
      "attributes": { "poles": 3, "ratingA": 9, "coilV": 230, "acClass": "AC-3", "auxContacts": "1NO+1NC" }
    },
    {
      "sku": "416100",
      "category": "contactor",
      "series": "CTX³ 22",
      "model": "CTX³ 22 3P 18A AC-3 24V~ 1NO+1NC",
      "attributes": { "poles": 3, "ratingA": 18, "coilV": 24, "acClass": "AC-3", "auxContacts": "1NO+1NC" }
    },
    {
      "sku": "416110",
      "category": "contactor",
      "series": "CTX³ 22",
      "model": "CTX³ 22 3P 22A AC-3 24V~ 1NO+1NC",
      "attributes": { "poles": 3, "ratingA": 22, "coilV": 24, "acClass": "AC-3", "auxContacts": "1NO+1NC" }
    },
    {
      "sku": "416116",
      "category": "contactor",
      "series": "CTX³ 22",
      "model": "CTX³ 22 3P 22A AC-3 230V~ 1NO+1NC",
      "attributes": { "poles": 3, "ratingA": 22, "coilV": 230, "acClass": "AC-3", "auxContacts": "1NO+1NC" }
    },
    {
      "sku": "416134",
      "category": "contactor",
      "series": "CTX³ 40",
      "model": "CTX³ 40 3P 40A AC-3 110V~ 2NO+2NC",
      "attributes": { "poles": 3, "ratingA": 40, "coilV": 110, "acClass": "AC-3", "auxContacts": "2NO+2NC" }
    },
    {
      "sku": "416136",
      "category": "contactor",
      "series": "CTX³ 40",
      "model": "CTX³ 40 3P 40A AC-3 230V~ 2NO+2NC",
      "attributes": { "poles": 3, "ratingA": 40, "coilV": 230, "acClass": "AC-3", "auxContacts": "2NO+2NC" }
    },
    {
      "sku": "416160",
      "category": "contactor",
      "series": "CTX³ 65",
      "model": "CTX³ 65 3P 65A AC-3 24V~ 2NO+2NC",
      "attributes": { "poles": 3, "ratingA": 65, "coilV": 24, "acClass": "AC-3", "auxContacts": "2NO+2NC" }
    },
    {
      "sku": "416166",
      "category": "contactor",
      "series": "CTX³ 65",
      "model": "CTX³ 65 3P 65A AC-3 230V~ 2NO+2NC",
      "attributes": { "poles": 3, "ratingA": 65, "coilV": 230, "acClass": "AC-3", "auxContacts": "2NO+2NC" }
    },
    {
      "sku": "416226",
      "category": "contactor",
      "series": "CTX³ 100",
      "model": "CTX³ 100 3P 100A AC-3 230V~ 2NO+2NC",
      "attributes": { "poles": 3, "ratingA": 100, "coilV": 230, "acClass": "AC-3", "auxContacts": "2NO+2NC" }
    },
    {
      "sku": "416640",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 0.1-0.16A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 0.1, "currentMaxA": 0.16, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416643",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 0.4-0.63A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 0.4, "currentMaxA": 0.63, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416644",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 0.63-1A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 0.63, "currentMaxA": 1, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416645",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 1-1.6A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 1, "currentMaxA": 1.6, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416646",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 1.6-2.5A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 1.6, "currentMaxA": 2.5, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416647",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 2.5-4A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 2.5, "currentMaxA": 4, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416648",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 4-6A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 4, "currentMaxA": 6, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416650",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 6-9A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 6, "currentMaxA": 9, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416653",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 12-18A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 12, "currentMaxA": 18, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416655",
      "category": "overload_relay",
      "series": "RTX³ 40",
      "model": "RTX³ 40 18-25A (for CTX³ 22/40, non-diff, Class 10A)",
      "attributes": { "currentMinA": 18, "currentMaxA": 25, "trippingClass": "10A", "forContactor": "CTX³ 22/40" }
    },
    {
      "sku": "416684",
      "category": "overload_relay",
      "series": "RTX³ 65",
      "model": "RTX³ 65 12-18A (for CTX³ 65, non-diff)",
      "attributes": { "currentMinA": 12, "currentMaxA": 18, "forContactor": "CTX³ 65" }
    },
    {
      "sku": "416687",
      "category": "overload_relay",
      "series": "RTX³ 65",
      "model": "RTX³ 65 24-36A (for CTX³ 65, non-diff)",
      "attributes": { "currentMinA": 24, "currentMaxA": 36, "forContactor": "CTX³ 65" }
    },
    {
      "sku": "416705",
      "category": "overload_relay",
      "series": "RTX³ 65",
      "model": "RTX³ 65 16-22A differential Class 10A (for CTX³ 65)",
      "attributes": { "currentMinA": 16, "currentMaxA": 22, "trippingClass": "10A", "differential": true, "forContactor": "CTX³ 65" }
    },
    {
      "sku": "416707",
      "category": "overload_relay",
      "series": "RTX³ 65",
      "model": "RTX³ 65 24-36A differential (for CTX³ 65)",
      "attributes": { "currentMinA": 24, "currentMaxA": 36, "differential": true, "forContactor": "CTX³ 65" }
    },
    {
      "sku": "416709",
      "category": "overload_relay",
      "series": "RTX³ 65",
      "model": "RTX³ 65 34-50A differential (for CTX³ 65)",
      "attributes": { "currentMinA": 34, "currentMaxA": 50, "differential": true, "forContactor": "CTX³ 65" }
    },
    {
      "sku": "416710",
      "category": "overload_relay",
      "series": "RTX³ 65",
      "model": "RTX³ 65 45-65A differential (for CTX³ 65)",
      "attributes": { "currentMinA": 45, "currentMaxA": 65, "differential": true, "forContactor": "CTX³ 65" }
    },
    {
      "sku": "416725",
      "category": "overload_relay",
      "series": "RTX³ 100",
      "model": "RTX³ 100 28-40A (for CTX³ 65, non-diff)",
      "attributes": { "currentMinA": 28, "currentMaxA": 40, "forContactor": "CTX³ 65" }
    },
    {
      "sku": "416729",
      "category": "overload_relay",
      "series": "RTX³ 100",
      "model": "RTX³ 100 63-85A Class 10A (for CTX³ 65)",
      "attributes": { "currentMinA": 63, "currentMaxA": 85, "trippingClass": "10A", "forContactor": "CTX³ 65" }
    }
  ]
}
''';
