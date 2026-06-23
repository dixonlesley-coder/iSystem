/// AUTO-EMBEDDED catalogue dataset — DO NOT hand-edit the JSON below.
///
/// This is the verbatim PanelMaker `schneider` catalogue file, embedded as a raw
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
const String schneiderCatalogBrand = "Schneider";

/// The brand's catalogue JSON, embedded verbatim (see file header).
const String schneiderCatalogJson = r'''
{
  "catalogVersion": "schneider-common-2",
  "manufacturer": "Schneider Electric",
  "source": "Order codes, pole/rating/curve and current-band attributes were transcribed individually from Schneider Electric (se.com) product-page titles across regional sites including se.com/id (Indonesia), with cross-checks against multiple regional mirrors (uk, au, sg, ww). Sources used: https://www.se.com/uk/en/product-range/7556-miniature-circuit-breaker-acti9-ic60/ (Acti9 iC60N MCBs, A9F44xxx C-curve), https://www.se.com/uk/en/product-range/7559-acti9-iid/ (Acti9 iID RCCB, A9R11xxx), https://www.se.com/id/en/product/LV429630/ and sibling LV4296xx/LV430630/LV431630 pages (ComPacT/Compact NSX100F-160F-250F TMD MCCBs), https://www.se.com/us/en/product-range/664-tesys-deca-contactors/ (TeSys Deca LC1Dxxx contactors, M7 = 220V AC 50/60Hz coil), https://www.se.com/ph/en/product-range/1885-tesys-deca-overload-relays/ (TeSys LRD thermal overload relays), and individual se.com product pages for Harmony XB5 pilot devices (XB5AVMx, XB5AA35) and METSECT5CC0xx current transformers. Order codes/ratings are convenience references — verify against the manufacturer datasheet before ordering. schneider-common-2 additions (each code transcribed from an se.com product-page title with matching spec, cross-checked on Clipsal/one-elec/distributor titles): Acti9 iC60N B-curve A9F43xxx and D-curve A9F45xxx MCBs from https://www.se.com/uk/en/product/A9F43116/ , https://www.se.com/uk/en/product/A9F45116/ , https://www.se.com/uk/en/product/A9F45120/ and sibling A9F43xxx/A9F45xxx pages (1P/2P/3P, B and D curve, 6kA Icn); further Acti9 iID RCCBs https://www.se.com/uk/en/product/A9R11491/ (4P 100A 30mA AC), https://www.se.com/ae/en/product/A9R11291/ (2P 100A 30mA AC), https://www.se.com/ww/en/product/A9R22440/ (4P 40A 100mA type A), https://www.se.com/in/en/product/A9R12240/ (2P 40A 100mA type AC), https://www.se.com/uk/en/product/A9R54463/ (4P 63A 300mA type A); ComPacT NSX N (50kA) and H (70kA) TMD MCCBs https://www.se.com/au/en/product/LV429840/ , https://www.se.com/au/en/product/LV430840/ , https://www.se.com/au/en/product/LV431832/ , https://www.se.com/au/en/product/LV431836/ , https://www.se.com/sg/en/product/C25N3TM250/ , https://www.se.com/ww/en/product/LV429670/ , https://www.se.com/us/en/product/LV429672/ , https://www.se.com/us/en/product/LV430670/ , https://www.se.com/us/en/product/LV431670/ ; larger TeSys Deca contactors https://www.se.com/in/en/product/LC1D80M7/ , https://www.se.com/in/en/product/LC1D95M7/ , https://www.se.com/us/en/product/LC1D115M7/ , https://www.se.com/us/en/product/LC1D150M7/ (220V 50/60Hz M7 coil, AC-3); Acti9 iPRD type-2 surge protective devices https://www.se.com/fr/fr/product/A9L20501/ , https://www.se.com/fr/fr/product/A9L20601/ , https://www.se.com/fr/fr/product/A9L40321/ , https://www.se.com/fr/fr/product/A9L40421/ , https://www.se.com/ch/fr/product/A9L40601/ (Up=1.4kV per A9L40601 datasheet); Acti9 iSW switch-disconnectors https://www.se.com/uk/en/product/A9S65340/ , https://www.se.com/uk/en/product/A9S65363/ , https://www.se.com/uk/en/product/A9S65440/ , https://www.se.com/uk/en/product/A9S65463/ , https://www.se.com/uk/en/product/A9S65491/ , https://www.se.com/eg/en/product/A9S60132/ ; Harmony/Zelio RE17 timer relays https://www.se.com/us/en/product/RE17RMMU/ and https://www.se.com/us/en/product/RE17RMEMU/ .",
  "parts": [
    { "sku": "A9F44116", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P C16", "attributes": { "ratingA": 16, "poles": 1, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44332", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P C32", "attributes": { "ratingA": 32, "poles": 3, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9F44106", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P C6", "attributes": { "ratingA": 6, "poles": 1, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44110", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P C10", "attributes": { "ratingA": 10, "poles": 1, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44120", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P C20", "attributes": { "ratingA": 20, "poles": 1, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44125", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P C25", "attributes": { "ratingA": 25, "poles": 1, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44132", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P C32", "attributes": { "ratingA": 32, "poles": 1, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44140", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P C40", "attributes": { "ratingA": 40, "poles": 1, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44150", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P C50", "attributes": { "ratingA": 50, "poles": 1, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44163", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P C63", "attributes": { "ratingA": 63, "poles": 1, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9F44206", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P C6", "attributes": { "ratingA": 6, "poles": 2, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44210", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P C10", "attributes": { "ratingA": 10, "poles": 2, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44216", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P C16", "attributes": { "ratingA": 16, "poles": 2, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44220", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P C20", "attributes": { "ratingA": 20, "poles": 2, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44225", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P C25", "attributes": { "ratingA": 25, "poles": 2, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44232", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P C32", "attributes": { "ratingA": 32, "poles": 2, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44240", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P C40", "attributes": { "ratingA": 40, "poles": 2, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44250", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P C50", "attributes": { "ratingA": 50, "poles": 2, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44263", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P C63", "attributes": { "ratingA": 63, "poles": 2, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9F44306", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P C6", "attributes": { "ratingA": 6, "poles": 3, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44310", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P C10", "attributes": { "ratingA": 10, "poles": 3, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44316", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P C16", "attributes": { "ratingA": 16, "poles": 3, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44320", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P C20", "attributes": { "ratingA": 20, "poles": 3, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44325", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P C25", "attributes": { "ratingA": 25, "poles": 3, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44340", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P C40", "attributes": { "ratingA": 40, "poles": 3, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44350", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P C50", "attributes": { "ratingA": 50, "poles": 3, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44363", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P C63", "attributes": { "ratingA": 63, "poles": 3, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9F44406", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 4P C6", "attributes": { "ratingA": 6, "poles": 4, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44410", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 4P C10", "attributes": { "ratingA": 10, "poles": 4, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44416", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 4P C16", "attributes": { "ratingA": 16, "poles": 4, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44420", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 4P C20", "attributes": { "ratingA": 20, "poles": 4, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44425", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 4P C25", "attributes": { "ratingA": 25, "poles": 4, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44432", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 4P C32", "attributes": { "ratingA": 32, "poles": 4, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44440", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 4P C40", "attributes": { "ratingA": 40, "poles": 4, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44450", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 4P C50", "attributes": { "ratingA": 50, "poles": 4, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F44463", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 4P C63", "attributes": { "ratingA": 63, "poles": 4, "curve": "C", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9R11225", "category": "breaker", "series": "Acti9 iID", "model": "iID 2P 25A AC 30mA RCCB", "attributes": { "ratingA": 25, "poles": 2, "deviceClass": "RCCB", "residualMa": 30, "rcdType": "AC" } },
    { "sku": "A9R11240", "category": "breaker", "series": "Acti9 iID", "model": "iID 2P 40A AC 30mA RCCB", "attributes": { "ratingA": 40, "poles": 2, "deviceClass": "RCCB", "residualMa": 30, "rcdType": "AC" } },
    { "sku": "A9R11440", "category": "breaker", "series": "Acti9 iID", "model": "iID 4P 40A AC 30mA RCCB", "attributes": { "ratingA": 40, "poles": 4, "deviceClass": "RCCB", "residualMa": 30, "rcdType": "AC" } },
    { "sku": "A9R11463", "category": "breaker", "series": "Acti9 iID", "model": "iID 4P 63A AC 30mA RCCB", "attributes": { "ratingA": 63, "poles": 4, "deviceClass": "RCCB", "residualMa": 30, "rcdType": "AC" } },

    { "sku": "LV429637", "category": "breaker", "series": "ComPacT NSX100F", "model": "NSX100F TMD 16A 3P3d", "attributes": { "ratingA": 16, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 36 } },
    { "sku": "LV429636", "category": "breaker", "series": "ComPacT NSX100F", "model": "NSX100F TMD 25A 3P3d", "attributes": { "ratingA": 25, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 36 } },
    { "sku": "LV429634", "category": "breaker", "series": "ComPacT NSX100F", "model": "NSX100F TMD 40A 3P3d", "attributes": { "ratingA": 40, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 36 } },
    { "sku": "LV429632", "category": "breaker", "series": "ComPacT NSX100F", "model": "NSX100F TMD 63A 3P3d", "attributes": { "ratingA": 63, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 36 } },
    { "sku": "LV429631", "category": "breaker", "series": "ComPacT NSX100F", "model": "NSX100F TMD 80A 3P3d", "attributes": { "ratingA": 80, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 36 } },
    { "sku": "LV429630", "category": "breaker", "series": "ComPacT NSX100F", "model": "NSX100F TMD 100A 3P3d", "attributes": { "ratingA": 100, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 36 } },
    { "sku": "LV430630", "category": "breaker", "series": "ComPacT NSX160F", "model": "NSX160F TMD 160A 3P3d", "attributes": { "ratingA": 160, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 36 } },
    { "sku": "LV431630", "category": "breaker", "series": "ComPacT NSX250F", "model": "NSX250F TMD 250A 3P3d", "attributes": { "ratingA": 250, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 36 } },

    { "sku": "LC1D09M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D09 3P 9A AC-3 220-230V coil", "attributes": { "ratingA": 9, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D12M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D12 3P 12A AC-3 220-230V coil", "attributes": { "ratingA": 12, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D18M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D18 3P 18A AC-3 220-230V coil", "attributes": { "ratingA": 18, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D25M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D25 3P 25A AC-3 220-230V coil", "attributes": { "ratingA": 25, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D32M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D32 3P 32A AC-3 220-230V coil", "attributes": { "ratingA": 32, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D38M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D38 3P 38A AC-3 220-230V coil", "attributes": { "ratingA": 38, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D40M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D40 3P 40A AC-3 220-230V coil", "attributes": { "ratingA": 40, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D50M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D50 3P 50A AC-3 220-230V coil", "attributes": { "ratingA": 50, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D65M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D65 3P 65A AC-3 220-230V coil", "attributes": { "ratingA": 65, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },

    { "sku": "LRD05", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD05 thermal overload 0.63-1A class 10A", "attributes": { "currentMinA": 0.63, "currentMaxA": 1, "tripClass": "10A" } },
    { "sku": "LRD06", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD06 thermal overload 1-1.6A class 10A", "attributes": { "currentMinA": 1, "currentMaxA": 1.6, "tripClass": "10A" } },
    { "sku": "LRD07", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD07 thermal overload 1.6-2.5A class 10A", "attributes": { "currentMinA": 1.6, "currentMaxA": 2.5, "tripClass": "10A" } },
    { "sku": "LRD08", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD08 thermal overload 2.5-4A class 10A", "attributes": { "currentMinA": 2.5, "currentMaxA": 4, "tripClass": "10A" } },
    { "sku": "LRD10", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD10 thermal overload 4-6A class 10A", "attributes": { "currentMinA": 4, "currentMaxA": 6, "tripClass": "10A" } },
    { "sku": "LRD12", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD12 thermal overload 5.5-8A class 10A", "attributes": { "currentMinA": 5.5, "currentMaxA": 8, "tripClass": "10A" } },
    { "sku": "LRD14", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD14 thermal overload 7-10A class 10A", "attributes": { "currentMinA": 7, "currentMaxA": 10, "tripClass": "10A" } },
    { "sku": "LRD16", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD16 thermal overload 9-13A class 10A", "attributes": { "currentMinA": 9, "currentMaxA": 13, "tripClass": "10A" } },
    { "sku": "LRD21", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD21 thermal overload 12-18A class 10A", "attributes": { "currentMinA": 12, "currentMaxA": 18, "tripClass": "10A" } },
    { "sku": "LRD22", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD22 thermal overload 16-24A class 10A", "attributes": { "currentMinA": 16, "currentMaxA": 24, "tripClass": "10A" } },
    { "sku": "LRD32", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD32 thermal overload 23-32A class 10A", "attributes": { "currentMinA": 23, "currentMaxA": 32, "tripClass": "10A" } },
    { "sku": "LRD35", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD35 thermal overload 30-38A class 10A", "attributes": { "currentMinA": 30, "currentMaxA": 38, "tripClass": "10A" } },
    { "sku": "LRD350", "category": "overload_relay", "series": "TeSys LRD", "model": "LRD350 thermal overload 37-50A class 10A EverLink", "attributes": { "currentMinA": 37, "currentMaxA": 50, "tripClass": "10A" } },

    { "sku": "XB5AA35", "category": "pilot_device", "series": "Harmony XB5", "model": "XB5AA35 green flush pushbutton 22mm 1NO+1NC", "attributes": { "color": "green", "diameterMm": 22, "contacts": "1NO+1NC", "actuator": "flush spring-return" } },
    { "sku": "XB5AVM3", "category": "indicator_lamp", "series": "Harmony XB5", "model": "XB5AVM3 green pilot light 22mm LED 230-240V AC", "attributes": { "color": "green", "diameterMm": 22, "voltageV": 230, "lampType": "LED" } },
    { "sku": "XB5AVM4", "category": "indicator_lamp", "series": "Harmony XB5", "model": "XB5AVM4 red pilot light 22mm LED 230-240V AC", "attributes": { "color": "red", "diameterMm": 22, "voltageV": 230, "lampType": "LED" } },
    { "sku": "XB5AVM5", "category": "indicator_lamp", "series": "Harmony XB5", "model": "XB5AVM5 orange pilot light 22mm LED 230-240V AC", "attributes": { "color": "orange", "diameterMm": 22, "voltageV": 230, "lampType": "LED" } },

    { "sku": "METSECT5CC005", "category": "current_transformer", "series": "PowerLogic METSECT5", "model": "CT tropicalised DIN mount 50/5 for cable d.21", "attributes": { "primaryA": 50, "secondaryA": 5, "mounting": "DIN", "cableDiameterMm": 21 } },
    { "sku": "METSECT5CC010", "category": "current_transformer", "series": "PowerLogic METSECT5", "model": "CT tropicalised DIN mount 100/5 for cable d.21", "attributes": { "primaryA": 100, "secondaryA": 5, "mounting": "DIN", "cableDiameterMm": 21 } },
    { "sku": "METSECT5CC015", "category": "current_transformer", "series": "PowerLogic METSECT5", "model": "CT tropicalised DIN mount 150/5 for cable d.21", "attributes": { "primaryA": 150, "secondaryA": 5, "mounting": "DIN", "cableDiameterMm": 21 } },
    { "sku": "METSECT5CC020", "category": "current_transformer", "series": "PowerLogic METSECT5", "model": "CT tropicalised DIN mount 200/5 for cable d.21", "attributes": { "primaryA": 200, "secondaryA": 5, "mounting": "DIN", "cableDiameterMm": 21 } },
    { "sku": "METSECT5CC025", "category": "current_transformer", "series": "PowerLogic METSECT5", "model": "CT tropicalised DIN mount 250/5 for cable d.21", "attributes": { "primaryA": 250, "secondaryA": 5, "mounting": "DIN", "cableDiameterMm": 21 } },

    { "sku": "A9F43106", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P B6", "attributes": { "ratingA": 6, "poles": 1, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43110", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P B10", "attributes": { "ratingA": 10, "poles": 1, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43116", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P B16", "attributes": { "ratingA": 16, "poles": 1, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43120", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P B20", "attributes": { "ratingA": 20, "poles": 1, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43132", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P B32", "attributes": { "ratingA": 32, "poles": 1, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43140", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P B40", "attributes": { "ratingA": 40, "poles": 1, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43163", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P B63", "attributes": { "ratingA": 63, "poles": 1, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9F43216", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P B16", "attributes": { "ratingA": 16, "poles": 2, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43220", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P B20", "attributes": { "ratingA": 20, "poles": 2, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43225", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P B25", "attributes": { "ratingA": 25, "poles": 2, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43232", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P B32", "attributes": { "ratingA": 32, "poles": 2, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9F43320", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P B20", "attributes": { "ratingA": 20, "poles": 3, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43332", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P B32", "attributes": { "ratingA": 32, "poles": 3, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F43363", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P B63", "attributes": { "ratingA": 63, "poles": 3, "curve": "B", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9F45110", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P D10", "attributes": { "ratingA": 10, "poles": 1, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45116", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P D16", "attributes": { "ratingA": 16, "poles": 1, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45120", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P D20", "attributes": { "ratingA": 20, "poles": 1, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45125", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P D25", "attributes": { "ratingA": 25, "poles": 1, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45132", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P D32", "attributes": { "ratingA": 32, "poles": 1, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45150", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P D50", "attributes": { "ratingA": 50, "poles": 1, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45163", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 1P D63", "attributes": { "ratingA": 63, "poles": 1, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9F45206", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 2P D6", "attributes": { "ratingA": 6, "poles": 2, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9F45316", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P D16", "attributes": { "ratingA": 16, "poles": 3, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45320", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P D20", "attributes": { "ratingA": 20, "poles": 3, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45325", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P D25", "attributes": { "ratingA": 25, "poles": 3, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45332", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P D32", "attributes": { "ratingA": 32, "poles": 3, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45340", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P D40", "attributes": { "ratingA": 40, "poles": 3, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45350", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P D50", "attributes": { "ratingA": 50, "poles": 3, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },
    { "sku": "A9F45363", "category": "breaker", "series": "Acti9 iC60N", "model": "iC60N 3P D63", "attributes": { "ratingA": 63, "poles": 3, "curve": "D", "deviceClass": "MCB", "breakingKa": 6 } },

    { "sku": "A9R11291", "category": "breaker", "series": "Acti9 iID", "model": "iID 2P 100A AC 30mA RCCB", "attributes": { "ratingA": 100, "poles": 2, "deviceClass": "RCCB", "residualMa": 30, "rcdType": "AC" } },
    { "sku": "A9R11491", "category": "breaker", "series": "Acti9 iID", "model": "iID 4P 100A AC 30mA RCCB", "attributes": { "ratingA": 100, "poles": 4, "deviceClass": "RCCB", "residualMa": 30, "rcdType": "AC" } },
    { "sku": "A9R12240", "category": "breaker", "series": "Acti9 iID", "model": "iID 2P 40A AC 100mA RCCB", "attributes": { "ratingA": 40, "poles": 2, "deviceClass": "RCCB", "residualMa": 100, "rcdType": "AC" } },
    { "sku": "A9R22440", "category": "breaker", "series": "Acti9 iID", "model": "iID 4P 40A type A 100mA RCCB", "attributes": { "ratingA": 40, "poles": 4, "deviceClass": "RCCB", "residualMa": 100, "rcdType": "A" } },
    { "sku": "A9R54463", "category": "breaker", "series": "Acti9 iID", "model": "iID 4P 63A type A 300mA RCCB", "attributes": { "ratingA": 63, "poles": 4, "deviceClass": "RCCB", "residualMa": 300, "rcdType": "A" } },

    { "sku": "LV429840", "category": "breaker", "series": "ComPacT NSX100N", "model": "NSX100N TMD 100A 3P3d 50kA", "attributes": { "ratingA": 100, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 50 } },
    { "sku": "LV430840", "category": "breaker", "series": "ComPacT NSX160N", "model": "NSX160N TMD 160A 3P3d 50kA", "attributes": { "ratingA": 160, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 50 } },
    { "sku": "LV431836", "category": "breaker", "series": "ComPacT NSX250N", "model": "NSX250N TMD 63A 3P3d 50kA", "attributes": { "ratingA": 63, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 50 } },
    { "sku": "LV431832", "category": "breaker", "series": "ComPacT NSX250N", "model": "NSX250N TMD 160A 3P3d 50kA", "attributes": { "ratingA": 160, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 50 } },
    { "sku": "C25N3TM250", "category": "breaker", "series": "ComPacT NSX250N", "model": "NSX250N TMD 250A 3P3d 50kA", "attributes": { "ratingA": 250, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 50 } },
    { "sku": "LV429670", "category": "breaker", "series": "ComPacT NSX100H", "model": "NSX100H TMD 100A 3P3d 70kA", "attributes": { "ratingA": 100, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 70 } },
    { "sku": "LV429672", "category": "breaker", "series": "ComPacT NSX100H", "model": "NSX100H TMD 63A 3P3d 70kA", "attributes": { "ratingA": 63, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 70 } },
    { "sku": "LV430670", "category": "breaker", "series": "ComPacT NSX160H", "model": "NSX160H TMD 160A 3P3d 70kA", "attributes": { "ratingA": 160, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 70 } },
    { "sku": "LV431670", "category": "breaker", "series": "ComPacT NSX250H", "model": "NSX250H TMD 250A 3P3d 70kA", "attributes": { "ratingA": 250, "poles": 3, "deviceClass": "MCCB", "tripUnit": "TMD", "breakingKa": 70 } },

    { "sku": "LC1D80M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D80 3P 80A AC-3 220-230V coil", "attributes": { "ratingA": 80, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D95M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D95 3P 95A AC-3 220-230V coil", "attributes": { "ratingA": 95, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D115M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D115 3P 115A AC-3 220-230V coil", "attributes": { "ratingA": 115, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },
    { "sku": "LC1D150M7", "category": "contactor", "series": "TeSys Deca", "model": "LC1D150 3P 150A AC-3 220-230V coil", "attributes": { "ratingA": 150, "poles": 3, "coilVoltageV": 220, "acClass": "AC-3", "contacts": "3NO" } },

    { "sku": "A9L20501", "category": "control_protection", "series": "Acti9 iPRD 20r", "model": "iPRD 20r SPD Type 2 1P+N 20kA 350V with remote signal", "attributes": { "deviceClass": "SPD", "spdType": "Type 2", "poleConfig": "1P+N", "imaxKa": 20, "ucV": 350, "remoteSignal": true } },
    { "sku": "A9L20601", "category": "control_protection", "series": "Acti9 iPRD 20r", "model": "iPRD 20r SPD Type 2 3P+N 20kA 350V with remote signal", "attributes": { "deviceClass": "SPD", "spdType": "Type 2", "poleConfig": "3P+N", "imaxKa": 20, "ucV": 350, "remoteSignal": true } },
    { "sku": "A9L40321", "category": "control_protection", "series": "Acti9 iPRD 40r", "model": "iPRD 40r SPD Type 2 3P 40kA 460V IT with remote signal", "attributes": { "deviceClass": "SPD", "spdType": "Type 2", "poleConfig": "3P", "imaxKa": 40, "ucV": 460, "remoteSignal": true } },
    { "sku": "A9L40421", "category": "control_protection", "series": "Acti9 iPRD 40r", "model": "iPRD 40r SPD Type 2 4P 40kA 460V IT with remote signal", "attributes": { "deviceClass": "SPD", "spdType": "Type 2", "poleConfig": "4P", "imaxKa": 40, "ucV": 460, "remoteSignal": true } },
    { "sku": "A9L40601", "category": "control_protection", "series": "Acti9 iPRD 40r", "model": "iPRD 40r SPD Type 2 3P+N 40kA 350V with remote signal", "attributes": { "deviceClass": "SPD", "spdType": "Type 2", "poleConfig": "3P+N", "imaxKa": 40, "ucV": 350, "upKv": 1.4, "remoteSignal": true } },

    { "sku": "A9S60132", "category": "switch", "series": "Acti9 iSW", "model": "iSW switch-disconnector 1P 32A 250V", "attributes": { "ratingA": 32, "poles": 1, "voltageV": 250, "deviceClass": "switch-disconnector" } },
    { "sku": "A9S65340", "category": "switch", "series": "Acti9 iSW", "model": "iSW switch-disconnector 3P 40A 415V", "attributes": { "ratingA": 40, "poles": 3, "voltageV": 415, "deviceClass": "switch-disconnector" } },
    { "sku": "A9S65363", "category": "switch", "series": "Acti9 iSW", "model": "iSW switch-disconnector 3P 63A 415V", "attributes": { "ratingA": 63, "poles": 3, "voltageV": 415, "deviceClass": "switch-disconnector" } },
    { "sku": "A9S65440", "category": "switch", "series": "Acti9 iSW", "model": "iSW switch-disconnector 4P 40A 415V", "attributes": { "ratingA": 40, "poles": 4, "voltageV": 415, "deviceClass": "switch-disconnector" } },
    { "sku": "A9S65463", "category": "switch", "series": "Acti9 iSW", "model": "iSW switch-disconnector 4P 63A 415V", "attributes": { "ratingA": 63, "poles": 4, "voltageV": 415, "deviceClass": "switch-disconnector" } },
    { "sku": "A9S65491", "category": "switch", "series": "Acti9 iSW", "model": "iSW switch-disconnector 4P 100A 415V", "attributes": { "ratingA": 100, "poles": 4, "voltageV": 415, "deviceClass": "switch-disconnector" } },

    { "sku": "RE17RMMU", "category": "timer_relay", "series": "Harmony Zelio RE17", "model": "RE17RMMU multifunction timing relay 8A 1CO 0.1s-100h 24-240V AC/DC", "attributes": { "outputA": 8, "contacts": "1CO", "timeRange": "0.1s-100h", "voltageRange": "24-240V AC / 24V DC", "function": "multifunction" } },
    { "sku": "RE17RMEMU", "category": "timer_relay", "series": "Harmony Zelio RE17", "model": "RE17RMEMU multifunction timing relay 8A 1CO 0.1s-100h 24-240V AC/DC", "attributes": { "outputA": 8, "contacts": "1CO", "timeRange": "0.1s-100h", "voltageRange": "24-240V AC / 24V DC", "function": "multifunction" } }
  ]
}
''';
