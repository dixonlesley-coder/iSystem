/// AUTO-EMBEDDED catalogue dataset — DO NOT hand-edit the JSON below.
///
/// This is the verbatim PanelMaker `mitsubishi` catalogue file, embedded as a raw
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
const String mitsubishiCatalogBrand = "Mitsubishi Electric";

/// The brand's catalogue JSON, embedded verbatim (see file header).
const String mitsubishiCatalogJson = r'''
{
  "catalogVersion": "mitsubishi-1",
  "manufacturer": "Mitsubishi Electric",
  "source": "Order codes and ratings (rated current AT, frame AF, poles, breaking capacity Icu at 415V, residual current, AC-3 current/coil, and thermal-overload setting bands) were transcribed individually from Mitsubishi Electric product-page titles and specification listings — Mitsubishi Electric Factory Automation Americas e-shop (shop1.us.mitsubishielectric.com), the Mitsubishi Electric Europe e-shop (mitsubishi-electric-eshop.mee.com), the Mitsubishi Electric EMEA/GB/IE product pages (emea/gb/ie.mitsubishielectric.com/fa), and the Mitsubishi Electric F.A. FASPEC specification database (www.mitsubishielectric.com/fa/products/faspec). MCCB/ELCB Icu is the IEC 60947-2 value at 415Vac (which for the economy NF-C class is lower than the 400Vac figure). Contactor current is the AC-3 rating at 415Vac with the AC200-240V (50/60Hz) coil; overload bands are the relay's adjustable trip-current range. Source URLs include: https://mitsubishi-electric-eshop.mee.com/.../NF32-SV-3P-32A , https://mitsubishi-electric-eshop.mee.com/.../NF125-SV-3P-100A , https://shop1.us.mitsubishielectric.com/products/NF63-CV3P63A , https://shop1.us.mitsubishielectric.com/products/NF63-SV3P50A , https://shop1.us.mitsubishielectric.com/products/NF125-CV3P100A , https://emea.mitsubishielectric.com/fa/products/lv_distri/lvc-breakers/mccb/...nf125-sv-3p-100a.html , https://shop1.us.mitsubishielectric.com/products/NF250-CV3P250A , https://emea.mitsubishielectric.com/fa/products/.../nf250-sv-3p-250a.html , https://shop1.us.mitsubishielectric.com/products/NF400-SW3P400A , https://shop1.us.mitsubishielectric.com/products/NF400-CW3P400A , https://shop1.us.mitsubishielectric.com/products/NF630-SEW3P630A , https://shop1.us.mitsubishielectric.com/products/NV63-CV3P63A30 , https://shop1.us.mitsubishielectric.com/products/NV125-SV3P125A30 , https://shop1.us.mitsubishielectric.com/products/NV250-SV3P200A100 , https://www.mitsubishielectric.com/fa/products/faspec/detail.page?...CONTACTOR_S-N10 (and S-N11/S-N12/S-N18/S-N20/S-N25/S-N35/S-N50/S-N65/S-N80/S-N95) , https://www.mitsubishielectric.com/fa/products/faspec/detail.page?...CONTACTOR_S-T20 (and S-T10/S-T12/S-T32/S-T35) , and Mitsubishi Electric TH-T / TH-N thermal overload relay heater listings on shop1.us.mitsubishielectric.com (TH-T18, TH-T25, TH-T65, TH-N20, TH-N60). Order codes/ratings are convenience references — verify every order code/rating against the manufacturer datasheet before ordering.",
  "parts": [
    { "sku": "NF32-SV 3P 32A", "category": "breaker", "series": "WS-V NF32-SV", "model": "NF32-SV 3P 32A MCCB", "attributes": { "ratingA": 32, "poles": 3, "frameA": 32, "breakingKa": 2.5, "deviceClass": "MCCB" } },

    { "sku": "NF63-CV 3P 25A", "category": "breaker", "series": "WS-V NF63-CV", "model": "NF63-CV 3P 25A MCCB", "attributes": { "ratingA": 25, "poles": 3, "frameA": 63, "breakingKa": 2.5, "deviceClass": "MCCB" } },
    { "sku": "NF63-CV 3P 40A", "category": "breaker", "series": "WS-V NF63-CV", "model": "NF63-CV 3P 40A MCCB", "attributes": { "ratingA": 40, "poles": 3, "frameA": 63, "breakingKa": 2.5, "deviceClass": "MCCB" } },
    { "sku": "NF63-CV 3P 50A", "category": "breaker", "series": "WS-V NF63-CV", "model": "NF63-CV 3P 50A MCCB", "attributes": { "ratingA": 50, "poles": 3, "frameA": 63, "breakingKa": 2.5, "deviceClass": "MCCB" } },
    { "sku": "NF63-CV 3P 63A", "category": "breaker", "series": "WS-V NF63-CV", "model": "NF63-CV 3P 63A MCCB", "attributes": { "ratingA": 63, "poles": 3, "frameA": 63, "breakingKa": 2.5, "deviceClass": "MCCB" } },

    { "sku": "NF63-SV 3P 50A", "category": "breaker", "series": "WS-V NF63-SV", "model": "NF63-SV 3P 50A MCCB", "attributes": { "ratingA": 50, "poles": 3, "frameA": 63, "breakingKa": 7.5, "deviceClass": "MCCB" } },
    { "sku": "NF63-SV 3P 63A", "category": "breaker", "series": "WS-V NF63-SV", "model": "NF63-SV 3P 63A MCCB", "attributes": { "ratingA": 63, "poles": 3, "frameA": 63, "breakingKa": 7.5, "deviceClass": "MCCB" } },

    { "sku": "NF125-CV 3P 100A", "category": "breaker", "series": "WS-V NF125-CV", "model": "NF125-CV 3P 100A MCCB", "attributes": { "ratingA": 100, "poles": 3, "frameA": 125, "breakingKa": 10, "deviceClass": "MCCB" } },
    { "sku": "NF125-CV 3P 125A", "category": "breaker", "series": "WS-V NF125-CV", "model": "NF125-CV 3P 125A MCCB", "attributes": { "ratingA": 125, "poles": 3, "frameA": 125, "breakingKa": 10, "deviceClass": "MCCB" } },

    { "sku": "NF125-SV 3P 50A", "category": "breaker", "series": "WS-V NF125-SV", "model": "NF125-SV 3P 50A MCCB", "attributes": { "ratingA": 50, "poles": 3, "frameA": 125, "breakingKa": 30, "deviceClass": "MCCB" } },
    { "sku": "NF125-SV 3P 63A", "category": "breaker", "series": "WS-V NF125-SV", "model": "NF125-SV 3P 63A MCCB", "attributes": { "ratingA": 63, "poles": 3, "frameA": 125, "breakingKa": 30, "deviceClass": "MCCB" } },
    { "sku": "NF125-SV 3P 75A", "category": "breaker", "series": "WS-V NF125-SV", "model": "NF125-SV 3P 75A MCCB", "attributes": { "ratingA": 75, "poles": 3, "frameA": 125, "breakingKa": 30, "deviceClass": "MCCB" } },
    { "sku": "NF125-SV 3P 80A", "category": "breaker", "series": "WS-V NF125-SV", "model": "NF125-SV 3P 80A MCCB", "attributes": { "ratingA": 80, "poles": 3, "frameA": 125, "breakingKa": 30, "deviceClass": "MCCB" } },
    { "sku": "NF125-SV 3P 100A", "category": "breaker", "series": "WS-V NF125-SV", "model": "NF125-SV 3P 100A MCCB", "attributes": { "ratingA": 100, "poles": 3, "frameA": 125, "breakingKa": 30, "deviceClass": "MCCB" } },
    { "sku": "NF125-SV 3P 125A", "category": "breaker", "series": "WS-V NF125-SV", "model": "NF125-SV 3P 125A MCCB", "attributes": { "ratingA": 125, "poles": 3, "frameA": 125, "breakingKa": 30, "deviceClass": "MCCB" } },

    { "sku": "NF250-CV 3P 200A", "category": "breaker", "series": "WS-V NF250-CV", "model": "NF250-CV 3P 200A MCCB", "attributes": { "ratingA": 200, "poles": 3, "frameA": 250, "breakingKa": 25, "deviceClass": "MCCB" } },
    { "sku": "NF250-CV 3P 250A", "category": "breaker", "series": "WS-V NF250-CV", "model": "NF250-CV 3P 250A MCCB", "attributes": { "ratingA": 250, "poles": 3, "frameA": 250, "breakingKa": 25, "deviceClass": "MCCB" } },

    { "sku": "NF250-SV 3P 200A", "category": "breaker", "series": "WS-V NF250-SV", "model": "NF250-SV 3P 200A MCCB", "attributes": { "ratingA": 200, "poles": 3, "frameA": 250, "breakingKa": 36, "deviceClass": "MCCB" } },
    { "sku": "NF250-SV 3P 250A", "category": "breaker", "series": "WS-V NF250-SV", "model": "NF250-SV 3P 250A MCCB", "attributes": { "ratingA": 250, "poles": 3, "frameA": 250, "breakingKa": 36, "deviceClass": "MCCB" } },

    { "sku": "NF400-CW 3P 400A", "category": "breaker", "series": "WS-V NF400-CW", "model": "NF400-CW 3P 400A MCCB", "attributes": { "ratingA": 400, "poles": 3, "frameA": 400, "breakingKa": 36, "deviceClass": "MCCB" } },

    { "sku": "NF400-SW 3P 400A", "category": "breaker", "series": "WS-V NF400-SW", "model": "NF400-SW 3P 400A MCCB", "attributes": { "ratingA": 400, "poles": 3, "frameA": 400, "breakingKa": 45, "deviceClass": "MCCB" } },

    { "sku": "NF630-SW 3P 630A", "category": "breaker", "series": "WS-V NF630-SW", "model": "NF630-SW 3P 630A MCCB", "attributes": { "ratingA": 630, "poles": 3, "frameA": 630, "breakingKa": 50, "deviceClass": "MCCB" } },

    { "sku": "NV63-CV 3P 63A 30mA", "category": "breaker", "series": "WS-V NV63-CV", "model": "NV63-CV 3P 63A 30mA ELCB", "attributes": { "ratingA": 63, "poles": 3, "frameA": 63, "breakingKa": 2.5, "residualMa": 30, "deviceClass": "ELCB" } },
    { "sku": "NV125-SV 3P 125A 30mA", "category": "breaker", "series": "WS-V NV125-SV", "model": "NV125-SV 3P 125A 30mA ELCB", "attributes": { "ratingA": 125, "poles": 3, "frameA": 125, "breakingKa": 30, "residualMa": 30, "deviceClass": "ELCB" } },
    { "sku": "NV125-SV 3P 100A 100mA", "category": "breaker", "series": "WS-V NV125-SV", "model": "NV125-SV 3P 100A 100mA ELCB", "attributes": { "ratingA": 100, "poles": 3, "frameA": 125, "breakingKa": 30, "residualMa": 100, "deviceClass": "ELCB" } },
    { "sku": "NV250-SV 3P 250A 100mA", "category": "breaker", "series": "WS-V NV250-SV", "model": "NV250-SV 3P 250A 100/200/500mA ELCB", "attributes": { "ratingA": 250, "poles": 3, "frameA": 250, "breakingKa": 36, "residualMa": 100, "deviceClass": "ELCB" } },

    { "sku": "S-T10 AC200-240V", "category": "contactor", "series": "MS-T S-T10", "model": "S-T10 magnetic contactor 9A AC-3 (4kW@440V)", "attributes": { "ratingA": 9, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-T12 AC200-240V", "category": "contactor", "series": "MS-T S-T12", "model": "S-T12 magnetic contactor 12A AC-3 (5.5kW@440V)", "attributes": { "ratingA": 12, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-T20 AC200-240V", "category": "contactor", "series": "MS-T S-T20", "model": "S-T20 magnetic contactor 18A AC-3 (7.5kW@440V)", "attributes": { "ratingA": 18, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-T32 AC200-240V", "category": "contactor", "series": "MS-T S-T32", "model": "S-T32 magnetic contactor 32A AC-3 (15kW@440V)", "attributes": { "ratingA": 32, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-T35 AC200-240V", "category": "contactor", "series": "MS-T S-T35", "model": "S-T35 magnetic contactor 40A AC-3 (18.5kW@440V)", "attributes": { "ratingA": 40, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },

    { "sku": "S-N10 AC200-240V", "category": "contactor", "series": "MS-N S-N10", "model": "S-N10 magnetic contactor 9A AC-3 (4kW@440V)", "attributes": { "ratingA": 9, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N11 AC200-240V", "category": "contactor", "series": "MS-N S-N11", "model": "S-N11 magnetic contactor 12A AC-3 (5.5kW@440V)", "attributes": { "ratingA": 12, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N12 AC200-240V", "category": "contactor", "series": "MS-N S-N12", "model": "S-N12 magnetic contactor 12A AC-3 (5.5kW@440V)", "attributes": { "ratingA": 12, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N18 AC200-240V", "category": "contactor", "series": "MS-N S-N18", "model": "S-N18 magnetic contactor 16A AC-3 (7.5kW@440V)", "attributes": { "ratingA": 16, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N20 AC200-240V", "category": "contactor", "series": "MS-N S-N20", "model": "S-N20 magnetic contactor 22A AC-3 (11kW@440V)", "attributes": { "ratingA": 22, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N25 AC200-240V", "category": "contactor", "series": "MS-N S-N25", "model": "S-N25 magnetic contactor 30A AC-3 (15kW@440V)", "attributes": { "ratingA": 30, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N35 AC200-240V", "category": "contactor", "series": "MS-N S-N35", "model": "S-N35 magnetic contactor 40A AC-3 (18.5kW@440V)", "attributes": { "ratingA": 40, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N50 AC200-240V", "category": "contactor", "series": "MS-N S-N50", "model": "S-N50 magnetic contactor 50A AC-3 (22kW@440V)", "attributes": { "ratingA": 50, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N65 AC200-240V", "category": "contactor", "series": "MS-N S-N65", "model": "S-N65 magnetic contactor 65A AC-3 (30kW@440V)", "attributes": { "ratingA": 65, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N80 AC200-240V", "category": "contactor", "series": "MS-N S-N80", "model": "S-N80 magnetic contactor 85A AC-3 (45kW@440V)", "attributes": { "ratingA": 85, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },
    { "sku": "S-N95 AC200-240V", "category": "contactor", "series": "MS-N S-N95", "model": "S-N95 magnetic contactor 105A AC-3 (55kW@440V)", "attributes": { "ratingA": 105, "poles": 3, "coilV": "AC200-240V", "acClass": "AC-3" } },

    { "sku": "TH-T18 0.5A", "category": "overload_relay", "series": "MS-T TH-T18", "model": "TH-T18 thermal overload relay 0.4-0.6A", "attributes": { "ratingA": 0.5, "currentMinA": 0.4, "currentMaxA": 0.6 } },
    { "sku": "TH-T18 1.3A", "category": "overload_relay", "series": "MS-T TH-T18", "model": "TH-T18 thermal overload relay 1.0-1.6A", "attributes": { "ratingA": 1.3, "currentMinA": 1.0, "currentMaxA": 1.6 } },
    { "sku": "TH-T18 2.1A", "category": "overload_relay", "series": "MS-T TH-T18", "model": "TH-T18 thermal overload relay 1.7-2.5A", "attributes": { "ratingA": 2.1, "currentMinA": 1.7, "currentMaxA": 2.5 } },
    { "sku": "TH-T18 6.6A", "category": "overload_relay", "series": "MS-T TH-T18", "model": "TH-T18 thermal overload relay 5.2-8A", "attributes": { "ratingA": 6.6, "currentMinA": 5.2, "currentMaxA": 8 } },

    { "sku": "TH-T25 2.1A", "category": "overload_relay", "series": "MS-T TH-T25", "model": "TH-T25 thermal overload relay 1.7-2.5A", "attributes": { "ratingA": 2.1, "currentMinA": 1.7, "currentMaxA": 2.5 } },
    { "sku": "TH-T25 5A", "category": "overload_relay", "series": "MS-T TH-T25", "model": "TH-T25 thermal overload relay 4-6A", "attributes": { "ratingA": 5, "currentMinA": 4, "currentMaxA": 6 } },
    { "sku": "TH-T25 6.6A", "category": "overload_relay", "series": "MS-T TH-T25", "model": "TH-T25 thermal overload relay 5.2-8A", "attributes": { "ratingA": 6.6, "currentMinA": 5.2, "currentMaxA": 8 } },
    { "sku": "TH-T25 15A", "category": "overload_relay", "series": "MS-T TH-T25", "model": "TH-T25 thermal overload relay 12-18A", "attributes": { "ratingA": 15, "currentMinA": 12, "currentMaxA": 18 } },

    { "sku": "TH-T65 15A", "category": "overload_relay", "series": "MS-T TH-T65", "model": "TH-T65 thermal overload relay 12-18A", "attributes": { "ratingA": 15, "currentMinA": 12, "currentMaxA": 18 } },
    { "sku": "TH-T65 29A", "category": "overload_relay", "series": "MS-T TH-T65", "model": "TH-T65 thermal overload relay 24-34A", "attributes": { "ratingA": 29, "currentMinA": 24, "currentMaxA": 34 } },
    { "sku": "TH-T65 35A", "category": "overload_relay", "series": "MS-T TH-T65", "model": "TH-T65 thermal overload relay 30-40A", "attributes": { "ratingA": 35, "currentMinA": 30, "currentMaxA": 40 } },

    { "sku": "TH-N20 1.3A", "category": "overload_relay", "series": "MS-N TH-N20", "model": "TH-N20 thermal overload relay 1.0-1.6A", "attributes": { "ratingA": 1.3, "currentMinA": 1.0, "currentMaxA": 1.6 } },
    { "sku": "TH-N20 2.1A", "category": "overload_relay", "series": "MS-N TH-N20", "model": "TH-N20 thermal overload relay 1.7-2.5A", "attributes": { "ratingA": 2.1, "currentMinA": 1.7, "currentMaxA": 2.5 } },
    { "sku": "TH-N20 3.6A", "category": "overload_relay", "series": "MS-N TH-N20", "model": "TH-N20 thermal overload relay 2.8-4.4A", "attributes": { "ratingA": 3.6, "currentMinA": 2.8, "currentMaxA": 4.4 } },
    { "sku": "TH-N20 6.6A", "category": "overload_relay", "series": "MS-N TH-N20", "model": "TH-N20 thermal overload relay 5.2-8A", "attributes": { "ratingA": 6.6, "currentMinA": 5.2, "currentMaxA": 8 } },
    { "sku": "TH-N20 11A", "category": "overload_relay", "series": "MS-N TH-N20", "model": "TH-N20 thermal overload relay 9-13A", "attributes": { "ratingA": 11, "currentMinA": 9, "currentMaxA": 13 } },
    { "sku": "TH-N20 22A", "category": "overload_relay", "series": "MS-N TH-N20", "model": "TH-N20TAFS thermal overload relay 18-26A", "attributes": { "ratingA": 22, "currentMinA": 18, "currentMaxA": 26 } },

    { "sku": "TH-N60 29A", "category": "overload_relay", "series": "MS-N TH-N60", "model": "TH-N60 thermal overload relay 24-34A", "attributes": { "ratingA": 29, "currentMinA": 24, "currentMaxA": 34 } },
    { "sku": "TH-N60 35A", "category": "overload_relay", "series": "MS-N TH-N60", "model": "TH-N60 thermal overload relay 30-40A", "attributes": { "ratingA": 35, "currentMinA": 30, "currentMaxA": 40 } },
    { "sku": "TH-N60 42A", "category": "overload_relay", "series": "MS-N TH-N60", "model": "TH-N60 thermal overload relay 34-50A", "attributes": { "ratingA": 42, "currentMinA": 34, "currentMaxA": 50 } },
    { "sku": "TH-N60 54A", "category": "overload_relay", "series": "MS-N TH-N60", "model": "TH-N60 thermal overload relay 43-65A", "attributes": { "ratingA": 54, "currentMinA": 43, "currentMaxA": 65 } }
  ]
}
''';
