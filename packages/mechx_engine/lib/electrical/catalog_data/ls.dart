/// AUTO-EMBEDDED catalogue dataset — DO NOT hand-edit the JSON below.
///
/// This is the verbatim PanelMaker `ls` catalogue file, embedded as a raw
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
const String lsCatalogBrand = "LS Electric";

/// The brand's catalogue JSON, embedded verbatim (see file header).
const String lsCatalogJson = r'''
{
  "catalogVersion": "ls-1",
  "manufacturer": "LS Electric",
  "source": "Verified LS Electric (formerly LS Industrial Systems / LSIS) low-voltage parts for the Indonesian market: Metasol ABN (economic) and ABS (standard) MCCBs, Susol TS-series MCCBs, BKN miniature circuit breakers, Metasol MC magnetic contactors, and Metasol MT thermal overload relays. Each order code, rating, pole count and breaking capacity (Icu @415V) was transcribed from authoritative manufacturer/distributor listings, NOT pattern-generated. Where sources conflicted on a value (e.g. Susol TS400N Icu listed as both 50 kA and 65 kA across listings) the disputed attribute was omitted rather than guessed. Sources consulted: LS Electric product pages (https://www.ls-electric.com/products/view/Smart_Power_Solution/Low_Voltage), KVC Malaysia distributor listings (https://www.kvc.com.my), GOTO Automation (https://www.goto-automation.com), Kreatronix LS distributor (https://kreatronix.in), TME (https://www.tme.com), Dalroad (https://shop.dalroad.com), Kent Industries (https://kentstore.com), and the LS Electric / LS Electric America Metasol MCCB, MCB & RCD, and Metasol MS contactor catalogues. Verify every order code/rating against the manufacturer datasheet before ordering.",
  "parts": [
    {
      "sku": "ABN53c",
      "category": "breaker",
      "series": "Metasol ABN",
      "model": "Metasol ABN53c economic MCCB, 50AF frame, 50 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 50,
        "poles": 3,
        "frameA": 50,
        "breakingKa": 18
      }
    },
    {
      "sku": "ABN103c",
      "category": "breaker",
      "series": "Metasol ABN",
      "model": "Metasol ABN103c economic MCCB, 100AF frame, 100 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 100,
        "poles": 3,
        "frameA": 100,
        "breakingKa": 18
      }
    },
    {
      "sku": "ABN203c",
      "category": "breaker",
      "series": "Metasol ABN",
      "model": "Metasol ABN203c economic MCCB, 250AF frame, 250 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 250,
        "poles": 3,
        "frameA": 250,
        "breakingKa": 26
      }
    },
    {
      "sku": "ABN403c",
      "category": "breaker",
      "series": "Metasol ABN",
      "model": "Metasol ABN403c economic MCCB, 400AF frame, 400 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 400,
        "poles": 3,
        "frameA": 400,
        "breakingKa": 37
      }
    },
    {
      "sku": "ABN803c",
      "category": "breaker",
      "series": "Metasol ABN",
      "model": "Metasol ABN803c economic MCCB, 800AF frame, 800 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 800,
        "poles": 3,
        "frameA": 800,
        "breakingKa": 37
      }
    },
    {
      "sku": "ABS33c",
      "category": "breaker",
      "series": "Metasol ABS",
      "model": "Metasol ABS33c standard MCCB, 30AF frame, 30 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 30,
        "poles": 3,
        "frameA": 30,
        "breakingKa": 18
      }
    },
    {
      "sku": "ABS53c",
      "category": "breaker",
      "series": "Metasol ABS",
      "model": "Metasol ABS53c standard MCCB, 50AF frame, 50 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 50,
        "poles": 3,
        "frameA": 50,
        "breakingKa": 18
      }
    },
    {
      "sku": "ABS103c",
      "category": "breaker",
      "series": "Metasol ABS",
      "model": "Metasol ABS103c standard MCCB, 100AF frame, 100 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 100,
        "poles": 3,
        "frameA": 100,
        "breakingKa": 37
      }
    },
    {
      "sku": "ABS203c",
      "category": "breaker",
      "series": "Metasol ABS",
      "model": "Metasol ABS203c standard MCCB, 250AF frame, 250 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 250,
        "poles": 3,
        "frameA": 250,
        "breakingKa": 37
      }
    },
    {
      "sku": "ABS403c",
      "category": "breaker",
      "series": "Metasol ABS",
      "model": "Metasol ABS403c standard MCCB, 400AF frame, 400 A, 3-pole",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 400,
        "poles": 3,
        "frameA": 400,
        "breakingKa": 50
      }
    },
    {
      "sku": "TS100N",
      "category": "breaker",
      "series": "Susol TS",
      "model": "Susol TS100N MCCB, 100AF frame, 3-pole (interchangeable FTU/FMU/ATU trip unit)",
      "attributes": {
        "deviceClass": "MCCB",
        "poles": 3,
        "frameA": 100,
        "breakingKa": 50
      }
    },
    {
      "sku": "TS160N",
      "category": "breaker",
      "series": "Susol TS",
      "model": "Susol TS160N MCCB, 160AF frame, 3-pole (interchangeable FTU/FMU/ATU trip unit)",
      "attributes": {
        "deviceClass": "MCCB",
        "poles": 3,
        "frameA": 160,
        "breakingKa": 50
      }
    },
    {
      "sku": "TS250N",
      "category": "breaker",
      "series": "Susol TS",
      "model": "Susol TS250N MCCB, 250AF frame, 250 A, 3-pole (interchangeable FTU/FMU/ATU trip unit)",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 250,
        "poles": 3,
        "frameA": 250,
        "breakingKa": 50
      }
    },
    {
      "sku": "TS400N",
      "category": "breaker",
      "series": "Susol TS",
      "model": "Susol TS400N MCCB, 400AF frame, 400 A, 3-pole (interchangeable trip unit; Icu omitted - distributor listings disagree 50 vs 65 kA)",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 400,
        "poles": 3,
        "frameA": 400
      }
    },
    {
      "sku": "TS630N",
      "category": "breaker",
      "series": "Susol TS",
      "model": "Susol TS630N MCCB, 630AF frame, 630 A, 3-pole (interchangeable FTU/FMU/ATU trip unit)",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 630,
        "poles": 3,
        "frameA": 630,
        "breakingKa": 50
      }
    },
    {
      "sku": "TS800N",
      "category": "breaker",
      "series": "Susol TS",
      "model": "Susol TS800N MCCB, 800AF frame, 800 A, 3-pole (interchangeable ATU/MTU trip unit)",
      "attributes": {
        "deviceClass": "MCCB",
        "ratingA": 800,
        "poles": 3,
        "frameA": 800,
        "breakingKa": 65
      }
    },
    {
      "sku": "BKN-1P-C10",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 1-pole, 10 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06110075R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 10,
        "poles": 1,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06110075R0"
      }
    },
    {
      "sku": "BKN-1P-C16",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 1-pole, 16 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06110076R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 16,
        "poles": 1,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06110076R0"
      }
    },
    {
      "sku": "BKN-1P-C20",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 1-pole, 20 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06110077R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 20,
        "poles": 1,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06110077R0"
      }
    },
    {
      "sku": "BKN-1P-C25",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 1-pole, 25 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06110078R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 25,
        "poles": 1,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06110078R0"
      }
    },
    {
      "sku": "BKN-1P-C40",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 1-pole, 40 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06110080R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 40,
        "poles": 1,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06110080R0"
      }
    },
    {
      "sku": "BKN-2P-C10",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 2-pole, 10 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06120218R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 10,
        "poles": 2,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06120218R0"
      }
    },
    {
      "sku": "BKN-2P-C16",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 2-pole, 16 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06120219R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 16,
        "poles": 2,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06120219R0"
      }
    },
    {
      "sku": "BKN-2P-C25",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 2-pole, 25 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06120221R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 25,
        "poles": 2,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06120221R0"
      }
    },
    {
      "sku": "BKN-3P-C16",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 3-pole, 16 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06130056R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 16,
        "poles": 3,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06130056R0"
      }
    },
    {
      "sku": "BKN-4P-C6",
      "category": "breaker",
      "series": "Metasol BKN",
      "model": "Metasol BKN MCB, 4-pole, 6 A, C-curve, 6 kA (IEC 60898-1); catalogue no. 06140121R0",
      "attributes": {
        "deviceClass": "MCB",
        "ratingA": 6,
        "poles": 4,
        "curve": "C",
        "breakingKa": 6,
        "orderCode": "06140121R0"
      }
    },
    {
      "sku": "MC-9b",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-9b magnetic contactor, 9 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 9,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-12b",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-12b magnetic contactor, 12 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 12,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-18b",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-18b magnetic contactor, 18 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 18,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-22b",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-22b magnetic contactor, 22 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 22,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-32a",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-32a magnetic contactor, 32 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 32,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-40a",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-40a magnetic contactor, 40 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 40,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-50a",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-50a magnetic contactor, 50 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 50,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-65a",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-65a magnetic contactor, 65 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 65,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-75a",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-75a magnetic contactor, 75 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 75,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-85a",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-85a magnetic contactor, 85 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 85,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-100a",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-100a magnetic contactor, 100 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 100,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-130a",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-130a magnetic contactor, 130 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 130,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MC-150a",
      "category": "contactor",
      "series": "Metasol MC",
      "model": "Metasol MC-150a magnetic contactor, 150 A AC-3 @415V, 3-pole, AC 220-240V coil",
      "attributes": {
        "ratingA": 150,
        "poles": 3,
        "coilV": "AC220-240V",
        "acClass": "AC-3"
      }
    },
    {
      "sku": "MT-32",
      "category": "overload_relay",
      "series": "Metasol MT",
      "model": "Metasol MT-32 thermal overload relay, setting range 0.1-40 A (Class 10A), for MC-9b..MC-40a",
      "attributes": {
        "currentMinA": 0.1,
        "currentMaxA": 40
      }
    },
    {
      "sku": "MT-63",
      "category": "overload_relay",
      "series": "Metasol MT",
      "model": "Metasol MT-63 thermal overload relay, setting range 4-65 A (Class 10A)",
      "attributes": {
        "currentMinA": 4,
        "currentMaxA": 65
      }
    },
    {
      "sku": "MT-95",
      "category": "overload_relay",
      "series": "Metasol MT",
      "model": "Metasol MT-95 thermal overload relay, setting range 7-100 A (Class 10A)",
      "attributes": {
        "currentMinA": 7,
        "currentMaxA": 100
      }
    }
  ]
}
''';
