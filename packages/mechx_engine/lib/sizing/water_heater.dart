/// Backlog G-2 (2026-11-13) — the duty of a placed WATER HEATER (an electric
/// storage heater, `NodeComponent.waterHeater`): its recovery, storage and
/// heating element, sized from the hot-water fixtures it serves by the
/// FIXTURE-DEMAND method (ASHRAE Handbook — HVAC Applications, "Service
/// Water Heating", the hot-water-demand-per-fixture table):
///
///   hourly demand    H  = Σ (fixture count × gal/h per fixture at 60 °C)
///   probable max     Pm = H × demand factor            (the recovery, L/h)
///   storage          S  = Pm × storage-capacity factor (litres)
///   heating power    kW = Pm [L/h] × 4.186 × (60 − 25) / 3600 / 0.98
///
/// then S is rounded UP to the standard tank ladder [kWaterHeaterTankLadderL]
/// and kW UP to the element ladder [kWaterHeaterElementLadderKw].
///
/// The table column follows the engine's occupancy: PRIVATE → the
/// "apartment" column (its lavatory row is the PRIVATE lavatory), PUBLIC and
/// ASSEMBLY → the "office" column (the PUBLIC lavatory row). Every table
/// value is a secondary source, NOT an SNI clause — `// VERIFY` against SNI
/// 03-7065 / the ASHRAE edition in use; surfaced once in
/// `SniProfile.verifyChecklist` ([waterHeaterVerifyItem]).
///
/// Pure Dart — zero Flutter imports.
library;

import '../standards/sni.dart'
    show Occupancy, PlumbingFixture, SniProfile, StandardValue;
import '../units.dart';

/// Litres per US gallon (exact by definition).
const double kLitresPerUsGallon = 3.785411784;

/// Stored / delivered hot-water temperature (°C) the table is calculated at
/// (140 °F). // VERIFY
const double kWaterHeaterStoredTempC = 60.0;

/// Cold-water inlet temperature (°C) for the heating power. // VERIFY
/// (Indonesian mains water ~25-28 °C).
const double kWaterHeaterInletTempC = 25.0;

/// Specific heat used for the element power (kJ/(kg·K)), water at 1 kg/L.
const double kWaterHeaterSpecificHeatKj = 4.186;

/// Heating efficiency of an electric storage heater (element → water).
/// // VERIFY
const double kWaterHeaterEfficiency = 0.98;

/// ASHRAE "apartment" column (gal/h per fixture at 60 °C) — the engine's
/// PRIVATE occupancy. A fixture absent from the map draws no hot water in
/// this method (a WC, urinal or hose bibb). // VERIFY
const Map<PlumbingFixture, double> kHotWaterGphApartment = {
  PlumbingFixture.lavatory: 2, // basin, private lavatory
  PlumbingFixture.bathtub: 20,
  PlumbingFixture.kitchenSink: 10,
  PlumbingFixture.shower: 30,
};

/// ASHRAE "office" column (gal/h per fixture at 60 °C) — the engine's
/// PUBLIC / ASSEMBLY occupancy. The office column lists no bathtub. // VERIFY
const Map<PlumbingFixture, double> kHotWaterGphOffice = {
  PlumbingFixture.lavatory: 6, // basin, public lavatory
  PlumbingFixture.kitchenSink: 20,
  PlumbingFixture.shower: 30,
};

/// ASHRAE demand factor (probable maximum ÷ hourly demand): apartment 0.30,
/// office 0.30. // VERIFY
const double kHotWaterDemandFactorApartment = 0.30;
const double kHotWaterDemandFactorOffice = 0.30;

/// ASHRAE storage-capacity factor (storage ÷ probable maximum): apartment
/// 1.25, office 2.00. // VERIFY
const double kHotWaterStorageFactorApartment = 1.25;
const double kHotWaterStorageFactorOffice = 2.00;

/// Standard storage-tank sizes (litres), ascending.
const List<double> kWaterHeaterTankLadderL = [
  50, 80, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000, //
];

/// Standard heating-element ratings (kW), ascending.
const List<double> kWaterHeaterElementLadderKw = [
  1.5, 2, 3, 4.5, 6, 9, 12, 18, 24, 36, //
];

/// The ONE verify-checklist entry behind every figure above
/// ([SniProfile.waterHeaterFixtureDemand]).
StandardValue<Object?> get waterHeaterVerifyItem =>
    const SniProfile().waterHeaterFixtureDemand;

/// The sized duty of one water heater.
class WaterHeaterDesign {
  /// Fixture count per type the heater serves (typed hot-water fixtures).
  final Map<PlumbingFixture, int> fixtures;

  /// Hot-water fixtures it serves that have no row in the column (no
  /// figure fabricated for them).
  final int unratedFixtures;

  /// The table column read ('apartment' / 'office').
  final String column;

  /// Σ fixtures × gal/h, in litres per hour.
  final double hourlyDemandLph;
  final double demandFactor;
  final double storageFactor;

  /// Probable maximum demand = the required RECOVERY (L/h at 60 °C).
  final double recoveryLph;

  /// Required storage (L) and the selected standard tank.
  final double storageRequiredL;
  final double tankL;

  /// Required heating power (kW) and the selected standard element.
  final double heatingKwRequired;
  final double elementKw;

  /// The tank ladder top was exceeded: [tankL] is the requirement rounded
  /// up to 100 L (several tanks / a site-built vessel).
  final bool tankBeyondLadder;

  /// The element ladder top was exceeded: [elementKw] is the requirement
  /// rounded up to 0.5 kW.
  final bool elementBeyondLadder;

  const WaterHeaterDesign({
    required this.fixtures,
    required this.unratedFixtures,
    required this.column,
    required this.hourlyDemandLph,
    required this.demandFactor,
    required this.storageFactor,
    required this.recoveryLph,
    required this.storageRequiredL,
    required this.tankL,
    required this.heatingKwRequired,
    required this.elementKw,
    required this.tankBeyondLadder,
    required this.elementBeyondLadder,
  });

  /// The recovery the SELECTED element delivers (L/h at 60 °C).
  double get elementRecoveryLph =>
      elementKw *
      kWaterHeaterEfficiency *
      3600 /
      (kWaterHeaterSpecificHeatKj *
          (kWaterHeaterStoredTempC - kWaterHeaterInletTempC));

  /// The element rating as a [Power] (the electrical load).
  Power get elementPower => Power(elementKw * 1000);
}

/// Round [v] UP to the first [ladder] rung >= it. Beyond the top rung the
/// requirement itself rounded UP to [beyondStep] (flagged by the caller) —
/// never the top rung, which would under-size a safety quantity.
double _ladderUp(double v, List<double> ladder, double beyondStep) {
  for (final r in ladder) {
    if (r >= v - 1e-9) return r;
  }
  return (v / beyondStep - 1e-9).ceil() * beyondStep;
}

/// Size a water heater serving [fixtures] (one entry per hot-water fixture
/// node, `null` for an untyped one) at [occupancy]. Null when it serves no
/// rated fixture (nothing to size). Order-independent: only the counts per
/// type enter.
WaterHeaterDesign? sizeWaterHeater({
  required Iterable<PlumbingFixture?> fixtures,
  required Occupancy occupancy,
}) {
  final private = occupancy == Occupancy.private;
  final gph = private ? kHotWaterGphApartment : kHotWaterGphOffice;
  final counts = <PlumbingFixture, int>{};
  var unrated = 0;
  var gal = 0.0;
  for (final f in fixtures) {
    final row = f == null ? null : gph[f];
    if (row == null) {
      unrated++;
      continue;
    }
    counts[f!] = (counts[f] ?? 0) + 1;
    gal += row;
  }
  if (gal <= 0) return null;
  final demandFactor =
      private ? kHotWaterDemandFactorApartment : kHotWaterDemandFactorOffice;
  final storageFactor =
      private ? kHotWaterStorageFactorApartment : kHotWaterStorageFactorOffice;
  final hourly = gal * kLitresPerUsGallon;
  final recovery = hourly * demandFactor;
  final storage = recovery * storageFactor;
  final kw = recovery *
      kWaterHeaterSpecificHeatKj *
      (kWaterHeaterStoredTempC - kWaterHeaterInletTempC) /
      3600 /
      kWaterHeaterEfficiency;
  return WaterHeaterDesign(
    fixtures: Map.unmodifiable(counts),
    unratedFixtures: unrated,
    column: private ? 'apartment' : 'office',
    hourlyDemandLph: hourly,
    demandFactor: demandFactor,
    storageFactor: storageFactor,
    recoveryLph: recovery,
    storageRequiredL: storage,
    tankL: _ladderUp(storage, kWaterHeaterTankLadderL, 100),
    heatingKwRequired: kw,
    elementKw: _ladderUp(kw, kWaterHeaterElementLadderKw, 0.5),
    tankBeyondLadder: storage > kWaterHeaterTankLadderL.last + 1e-9,
    elementBeyondLadder: kw > kWaterHeaterElementLadderKw.last + 1e-9,
  );
}

/// The element's supply phases: single-phase up to [singlePhaseMaxW]
/// (the app's single-phase final ceiling), three-phase above.
int waterHeaterPhases(double elementKw, {double singlePhaseMaxW = 5500}) =>
    elementKw * 1000 <= singlePhaseMaxW + 1e-9 ? 1 : 3;
