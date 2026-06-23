/// AUTO-EMBEDDED catalogue dataset — DO NOT hand-edit the JSON below.
///
/// This is the verbatim PanelMaker `abb` catalogue file, embedded as a raw
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
const String abbCatalogBrand = "ABB";

/// The brand's catalogue JSON, embedded verbatim (see file header).
const String abbCatalogJson = r'''
{
  "catalogVersion": "abb-1",
  "manufacturer": "ABB",
  "source": "ABB low-voltage components. Order/type codes transcribed from ABB product pages (new.abb.com) and reputable distributor listings whose titles carry the full spec (ratedcurrent / poles / curve / Icu / coil / setting range): ElectGo (electgo.com), Kempston Controls (kempstoncontrols.com), RS Components (rsdelivers.com), Santa Clara Systems (santaclarasystems.com), Amazon listings of genuine ABB parts, and Electric Automation Network (electricautomationnetwork.com). Families: System pro M compact S200 MCBs (S201/S202/S203/S204, B and C curve, Icn 6 kA per IEC/EN 60898-1); SACE Tmax XT1N 160 MCCBs (3P/4P, thermomagnetic, Icu 36 kA at 415 V); F200-series F204 RCCBs (4-pole, Type AC); AF-range contactors (3-pole, AC-3, 100-250 V AC/DC electronic coil, '-13' suffix); TA..DU thermal overload relays. Codes were taken only from real listings, never pattern-generated or extrapolated across a ratings matrix; uncertain codes were omitted. Verify every order code/rating against the manufacturer datasheet before ordering.",
  "parts": [
    {
      "sku": "2CDS251001R0014",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C1",
      "attributes": { "deviceClass": "MCB", "ratingA": 1, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0014" }
    },
    {
      "sku": "2CDS251001R0024",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C2",
      "attributes": { "deviceClass": "MCB", "ratingA": 2, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0024" }
    },
    {
      "sku": "2CDS251001R0034",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C3",
      "attributes": { "deviceClass": "MCB", "ratingA": 3, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0034" }
    },
    {
      "sku": "2CDS251001R0064",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C6",
      "attributes": { "deviceClass": "MCB", "ratingA": 6, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0064" }
    },
    {
      "sku": "2CDS251001R0104",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C10",
      "attributes": { "deviceClass": "MCB", "ratingA": 10, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0104" }
    },
    {
      "sku": "2CDS251001R0164",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0164" }
    },
    {
      "sku": "2CDS251001R0204",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C20",
      "attributes": { "deviceClass": "MCB", "ratingA": 20, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0204" }
    },
    {
      "sku": "2CDS251001R0254",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C25",
      "attributes": { "deviceClass": "MCB", "ratingA": 25, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0254" }
    },
    {
      "sku": "2CDS251001R0324",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0324" }
    },
    {
      "sku": "2CDS251001R0504",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-C50",
      "attributes": { "deviceClass": "MCB", "ratingA": 50, "poles": 1, "curve": "C", "breakingKa": 6, "orderCode": "2CDS251001R0504" }
    },
    {
      "sku": "2CDS251001R1165",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-B16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 1, "curve": "B", "breakingKa": 6, "orderCode": "2CDS251001R1165" }
    },
    {
      "sku": "2CDS251001R0205",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-B20",
      "attributes": { "deviceClass": "MCB", "ratingA": 20, "poles": 1, "curve": "B", "breakingKa": 6, "orderCode": "2CDS251001R0205" }
    },
    {
      "sku": "2CDS251001R0255",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-B25",
      "attributes": { "deviceClass": "MCB", "ratingA": 25, "poles": 1, "curve": "B", "breakingKa": 6, "orderCode": "2CDS251001R0255" }
    },
    {
      "sku": "2CDS251001R0105",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-B10",
      "attributes": { "deviceClass": "MCB", "ratingA": 10, "poles": 1, "curve": "B", "breakingKa": 6, "orderCode": "2CDS251001R0105" }
    },
    {
      "sku": "2CDS252001R0024",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S202-C2",
      "attributes": { "deviceClass": "MCB", "ratingA": 2, "poles": 2, "curve": "C", "breakingKa": 6, "orderCode": "2CDS252001R0024" }
    },
    {
      "sku": "2CDS252001R0064",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S202-C6",
      "attributes": { "deviceClass": "MCB", "ratingA": 6, "poles": 2, "curve": "C", "breakingKa": 6, "orderCode": "2CDS252001R0064" }
    },
    {
      "sku": "2CDS252001R0164",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S202-C16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 2, "curve": "C", "breakingKa": 6, "orderCode": "2CDS252001R0164" }
    },
    {
      "sku": "2CDS252001R0254",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S202-C25",
      "attributes": { "deviceClass": "MCB", "ratingA": 25, "poles": 2, "curve": "C", "breakingKa": 6, "orderCode": "2CDS252001R0254" }
    },
    {
      "sku": "2CDS252001R0324",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S202-C32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 2, "curve": "C", "breakingKa": 6, "orderCode": "2CDS252001R0324" }
    },
    {
      "sku": "2CDS252001R0634",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S202-C63",
      "attributes": { "deviceClass": "MCB", "ratingA": 63, "poles": 2, "curve": "C", "breakingKa": 6, "orderCode": "2CDS252001R0634" }
    },
    {
      "sku": "2CDS252001R0165",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S202-B16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 2, "curve": "B", "breakingKa": 6, "orderCode": "2CDS252001R0165" }
    },
    {
      "sku": "2CDS253001R0014",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C1",
      "attributes": { "deviceClass": "MCB", "ratingA": 1, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0014" }
    },
    {
      "sku": "2CDS253001R0034",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C3",
      "attributes": { "deviceClass": "MCB", "ratingA": 3, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0034" }
    },
    {
      "sku": "2CDS253001R0104",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C10",
      "attributes": { "deviceClass": "MCB", "ratingA": 10, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0104" }
    },
    {
      "sku": "2CDS253001R0164",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0164" }
    },
    {
      "sku": "2CDS253001R0204",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C20",
      "attributes": { "deviceClass": "MCB", "ratingA": 20, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0204" }
    },
    {
      "sku": "2CDS253001R0254",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C25",
      "attributes": { "deviceClass": "MCB", "ratingA": 25, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0254" }
    },
    {
      "sku": "2CDS253001R0324",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0324" }
    },
    {
      "sku": "2CDS253001R0404",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C40",
      "attributes": { "deviceClass": "MCB", "ratingA": 40, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0404" }
    },
    {
      "sku": "2CDS253001R0504",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C50",
      "attributes": { "deviceClass": "MCB", "ratingA": 50, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0504" }
    },
    {
      "sku": "2CDS253001R0634",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-C63",
      "attributes": { "deviceClass": "MCB", "ratingA": 63, "poles": 3, "curve": "C", "breakingKa": 6, "orderCode": "2CDS253001R0634" }
    },
    {
      "sku": "2CDS253001R0165",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-B16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 3, "curve": "B", "breakingKa": 6, "orderCode": "2CDS253001R0165" }
    },
    {
      "sku": "2CDS253001R0325",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-B32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 3, "curve": "B", "breakingKa": 6, "orderCode": "2CDS253001R0325" }
    },
    {
      "sku": "2CDS253001R0635",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-B63",
      "attributes": { "deviceClass": "MCB", "ratingA": 63, "poles": 3, "curve": "B", "breakingKa": 6, "orderCode": "2CDS253001R0635" }
    },
    {
      "sku": "2CDS253001R0101",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-D10",
      "attributes": { "deviceClass": "MCB", "ratingA": 10, "poles": 3, "curve": "D", "breakingKa": 6, "orderCode": "2CDS253001R0101" }
    },
    {
      "sku": "2CDS253001R0321",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-D32",
      "attributes": { "deviceClass": "MCB", "ratingA": 32, "poles": 3, "curve": "D", "breakingKa": 6, "orderCode": "2CDS253001R0321" }
    },
    {
      "sku": "2CDS253001R0401",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S203-D40",
      "attributes": { "deviceClass": "MCB", "ratingA": 40, "poles": 3, "curve": "D", "breakingKa": 6, "orderCode": "2CDS253001R0401" }
    },
    {
      "sku": "2CDS251001R0201",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S201-D20",
      "attributes": { "deviceClass": "MCB", "ratingA": 20, "poles": 1, "curve": "D", "breakingKa": 6, "orderCode": "2CDS251001R0201" }
    },
    {
      "sku": "2CDS254001R0164",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S204-C16",
      "attributes": { "deviceClass": "MCB", "ratingA": 16, "poles": 4, "curve": "C", "breakingKa": 6, "orderCode": "2CDS254001R0164" }
    },
    {
      "sku": "2CDS254001R0254",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S204-C25",
      "attributes": { "deviceClass": "MCB", "ratingA": 25, "poles": 4, "curve": "C", "breakingKa": 6, "orderCode": "2CDS254001R0254" }
    },
    {
      "sku": "2CDS254001R0634",
      "category": "breaker",
      "series": "System pro M compact S200",
      "model": "S204-C63",
      "attributes": { "deviceClass": "MCB", "ratingA": 63, "poles": 4, "curve": "C", "breakingKa": 6, "orderCode": "2CDS254001R0634" }
    },
    {
      "sku": "1SDA067413R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=50A 3P FF thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 50, "poles": 3, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067413R1" }
    },
    {
      "sku": "1SDA067414R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=63A 3P FF thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 63, "poles": 3, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067414R1" }
    },
    {
      "sku": "1SDA067415R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=80A 3P FF thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 80, "poles": 3, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067415R1" }
    },
    {
      "sku": "1SDA067416R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=100A 3P FF thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 100, "poles": 3, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067416R1" }
    },
    {
      "sku": "1SDA067417R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=125A 3P FF thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 125, "poles": 3, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067417R1" }
    },
    {
      "sku": "1SDA067418R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=160A 3P FF thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 160, "poles": 3, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067418R1" }
    },
    {
      "sku": "1SDA067420R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=40A 4P FF thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 40, "poles": 4, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067420R1" }
    },
    {
      "sku": "1SDA067422R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=63A 4P thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 63, "poles": 4, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067422R1" }
    },
    {
      "sku": "1SDA067423R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=80A 4P FF thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 80, "poles": 4, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067423R1" }
    },
    {
      "sku": "1SDA067424R1",
      "category": "breaker",
      "series": "SACE Tmax XT1N 160",
      "model": "XT1N 160 In=100A 4P FF thermomagnetic",
      "attributes": { "deviceClass": "MCCB", "ratingA": 100, "poles": 4, "frameA": 160, "breakingKa": 36, "icuKa": 36, "orderCode": "1SDA067424R1" }
    },
    {
      "sku": "2CSF204001R1250",
      "category": "breaker",
      "series": "System pro M compact F200",
      "model": "F204 AC-25/0.03",
      "attributes": { "deviceClass": "RCCB", "ratingA": 25, "poles": 4, "residualMa": 30, "acClass": "AC", "orderCode": "2CSF204001R1250" }
    },
    {
      "sku": "2CSF204001R1400",
      "category": "breaker",
      "series": "System pro M compact F200",
      "model": "F204 AC-40/0.03",
      "attributes": { "deviceClass": "RCCB", "ratingA": 40, "poles": 4, "residualMa": 30, "acClass": "AC", "orderCode": "2CSF204001R1400" }
    },
    {
      "sku": "2CSF204001R1630",
      "category": "breaker",
      "series": "System pro M compact F200",
      "model": "F204 AC-63/0.03",
      "attributes": { "deviceClass": "RCCB", "ratingA": 63, "poles": 4, "residualMa": 30, "acClass": "AC", "orderCode": "2CSF204001R1630" }
    },
    {
      "sku": "1SBL137001R1310",
      "category": "contactor",
      "series": "AF range",
      "model": "AF09-30-10-13",
      "attributes": { "ratingA": 9, "poles": 3, "coilV": "100-250 V AC/DC", "acClass": "AC-3", "orderCode": "1SBL137001R1310" }
    },
    {
      "sku": "1SBL157001R1310",
      "category": "contactor",
      "series": "AF range",
      "model": "AF12-30-10-13",
      "attributes": { "ratingA": 12, "poles": 3, "coilV": "100-250 V AC/DC", "acClass": "AC-3", "orderCode": "1SBL157001R1310" }
    },
    {
      "sku": "1SBL177001R1310",
      "category": "contactor",
      "series": "AF range",
      "model": "AF16-30-10-13",
      "attributes": { "ratingA": 18, "poles": 3, "coilV": "100-250 V AC/DC", "acClass": "AC-3", "orderCode": "1SBL177001R1310" }
    },
    {
      "sku": "1SBL237001R1300",
      "category": "contactor",
      "series": "AF range",
      "model": "AF26-30-00-13",
      "attributes": { "ratingA": 26, "poles": 3, "coilV": "100-250 V AC/DC", "acClass": "AC-3", "orderCode": "1SBL237001R1300" }
    },
    {
      "sku": "1SBL277001R1300",
      "category": "contactor",
      "series": "AF range",
      "model": "AF30-30-00-13",
      "attributes": { "ratingA": 32, "poles": 3, "coilV": "100-250 V AC/DC", "acClass": "AC-3", "orderCode": "1SBL277001R1300" }
    },
    {
      "sku": "1SBL297001R1300",
      "category": "contactor",
      "series": "AF range",
      "model": "AF38-30-00-13",
      "attributes": { "ratingA": 38, "poles": 3, "coilV": "100-250 V AC/DC", "acClass": "AC-3", "orderCode": "1SBL297001R1300" }
    },
    {
      "sku": "1SBL367001R1300",
      "category": "contactor",
      "series": "AF range",
      "model": "AF52-30-00-13",
      "attributes": { "ratingA": 50, "poles": 3, "coilV": "100-250 V AC/DC", "acClass": "AC-3", "orderCode": "1SBL367001R1300" }
    },
    {
      "sku": "1SBL387001R1300",
      "category": "contactor",
      "series": "AF range",
      "model": "AF65-30-00-13",
      "attributes": { "ratingA": 65, "poles": 3, "coilV": "100-250 V AC/DC", "acClass": "AC-3", "orderCode": "1SBL387001R1300" }
    },
    {
      "sku": "1SBL407001R1111",
      "category": "contactor",
      "series": "AF range",
      "model": "AF96-30-11-11",
      "attributes": { "ratingA": 96, "poles": 3, "coilV": "100-250 V AC/DC", "acClass": "AC-3", "orderCode": "1SBL407001R1111" }
    },
    {
      "sku": "1SAZ211201R1043",
      "category": "overload_relay",
      "series": "TA25DU",
      "model": "TA25DU-11",
      "attributes": { "currentMinA": 7.5, "currentMaxA": 11, "orderCode": "1SAZ211201R1043" }
    },
    {
      "sku": "1SAZ211201R1045",
      "category": "overload_relay",
      "series": "TA25DU",
      "model": "TA25DU-14",
      "attributes": { "currentMinA": 10, "currentMaxA": 14, "orderCode": "1SAZ211201R1045" }
    },
    {
      "sku": "1SAZ211201R1047",
      "category": "overload_relay",
      "series": "TA25DU",
      "model": "TA25DU-19",
      "attributes": { "currentMinA": 13, "currentMaxA": 19, "orderCode": "1SAZ211201R1047" }
    },
    {
      "sku": "1SAZ211201R1051",
      "category": "overload_relay",
      "series": "TA25DU",
      "model": "TA25DU-25",
      "attributes": { "currentMinA": 18, "currentMaxA": 25, "orderCode": "1SAZ211201R1051" }
    },
    {
      "sku": "1SAZ311201R1003",
      "category": "overload_relay",
      "series": "TA42DU",
      "model": "TA42DU-42",
      "attributes": { "currentMinA": 29, "currentMaxA": 42, "orderCode": "1SAZ311201R1003" }
    },
    {
      "sku": "1SAZ321201R1006",
      "category": "overload_relay",
      "series": "TA75DU",
      "model": "TA75DU-80",
      "attributes": { "currentMinA": 60, "currentMaxA": 80, "orderCode": "1SAZ321201R1006" }
    }
  ]
}
''';
