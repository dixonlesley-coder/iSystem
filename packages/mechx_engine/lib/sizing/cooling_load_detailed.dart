/// Detailed (heat-gain) cooling-load estimate — a transparent component
/// breakdown beyond the area-density rule in `cooling_load.dart`.
///
/// Where `estimateCoolingLoad` multiplies a per-m² density by floor area, this
/// module sums the physical heat-gain streams an HVAC engineer would tally by
/// hand, split into the two coil duties a real cooling system must reject:
///
///   * **Sensible** (dry-bulb, drives supply-air temperature):
///       - Envelope/transmission  Q = U·A·ΔT  over walls + roof + glazing
///       - Solar gain through glazing  Q = SHGC · irradiance · glass area
///       - Internal sensible gains: people (sensible part), lighting, equipment
///       - Infiltration/ventilation sensible: Q = ρ·cp · V̇ · ΔT
///   * **Latent** (moisture, drives the coil's dehumidification):
///       - People latent gain
///       - Infiltration/ventilation latent: Q = ρ·h_fg · V̇ · Δw
///
///   total = sensible + latent  → BTU/h → PK → nearest standard AC.
///
/// This is still ORCHESTRATION, not a full transient CLTD/RTS solve: every
/// coefficient (U-values, SHGC, gain densities, outdoor design ΔT / Δw,
/// infiltration rate, occupant load split) is a single representative steady-
/// state figure. They are general HVAC engineering practice (ASHRAE Fundamentals
/// / SNI 03-6390-2000 / SNI 03-6572-2001 style), NOT confirmed verbatim against
/// any official SNI clause — so every default below is `// VERIFY` and is
/// surfaced via [detailedCoolingVerifyChecklist]. A real design needs a
/// site-specific envelope audit + occupancy/lighting schedules.
///
/// The simple area-density [estimateCoolingLoad] stays the fallback; this is the
/// opt-in "detailed" method.
///
/// Pure Dart, zero Flutter imports. Composes typed quantities + the AC ladder /
/// PK conversion from `cooling_load.dart`.
library;

import '../standards/sni.dart' show StandardValue, VerificationStatus;
import '../units.dart';
import 'cooling_load.dart';

// ---------------------------------------------------------------------------
// Representative // VERIFY coefficients. All are steady-state, climate-generic
// figures for a hot-humid (Indonesian) context. Replace with a real envelope
// audit + occupancy/lighting schedule before a submission.
// ---------------------------------------------------------------------------

/// Outdoor↔indoor dry-bulb difference (K) for transmission + sensible
/// infiltration. ~33 °C outdoor design vs ~24 °C indoor ≈ 9 K. `// VERIFY`.
const double kDefaultDesignDeltaTK = 9.0;

/// Outdoor↔indoor humidity-ratio difference (kg water / kg dry air) for the
/// latent infiltration/ventilation stream. ~0.020 outdoor vs ~0.010 indoor at
/// ~24 °C / 50 % RH ≈ 0.010. `// VERIFY`.
const double kDefaultDesignDeltaWKgPerKg = 0.010;

/// Wall U-value (W/m²·K). Uninsulated/lightly-insulated brick-render ≈ 2.0–2.5.
/// `// VERIFY` against the actual construction.
const double kDefaultWallUValue = 2.5;

/// Roof U-value (W/m²·K). Insulated concrete/metal-deck ≈ 1.0–1.5. `// VERIFY`.
const double kDefaultRoofUValue = 1.5;

/// Glazing U-value (W/m²·K). Single clear glass ≈ 5.5; here a mid value for a
/// typical clear-glass facade. `// VERIFY`.
const double kDefaultGlassUValue = 3.0;

/// Glazing solar heat-gain coefficient (SHGC, dimensionless 0–1). Clear glass
/// ≈ 0.6–0.7. `// VERIFY`.
const double kDefaultGlassShgc = 0.65;

/// Design solar irradiance on the glazing plane (W/m²). A representative
/// peak-hour value averaged over orientations. `// VERIFY`.
const double kDefaultSolarIrradianceWPerM2 = 300.0;

/// Sensible heat gain per occupant (W). ASHRAE ≈ 70–75 W sensible for seated
/// light work; 75 here. `// VERIFY`.
const double kDefaultPersonSensibleW = 75.0;

/// Latent heat gain per occupant (W). ASHRAE ≈ 55–60 W latent for seated light
/// work; 55 here. `// VERIFY`.
const double kDefaultPersonLatentW = 55.0;

/// Default occupant density (people per m² of floor). ~0.1 (10 m²/person) for a
/// general office. `// VERIFY`.
const double kDefaultPeopleDensityPerM2 = 0.1;

/// Lighting power density (W/m² of floor) — all dissipated as sensible heat.
/// LED office ≈ 8–12; 10 here. `// VERIFY`.
const double kDefaultLightingWPerM2 = 10.0;

/// Equipment/plug-load power density (W/m² of floor) — sensible. General office
/// ≈ 10–15; 12 here. `// VERIFY`.
const double kDefaultEquipmentWPerM2 = 12.0;

/// Outdoor-air / infiltration rate (air changes per hour) used for the
/// ventilation heat-gain streams when the caller gives no explicit airflow.
/// ~1 ACH of fresh/infiltration air. `// VERIFY`.
const double kDefaultVentilationAch = 1.0;

/// Air density at ~24 °C (kg/m³). `// VERIFY` (textbook value).
const double kAirDensityKgPerM3 = 1.2;

/// Specific heat of air at constant pressure (J/kg·K). Textbook ≈ 1006; 1005
/// here. `// VERIFY`.
const double kAirCpJPerKgK = 1005.0;

/// Latent heat of vaporisation of water (J/kg) near room conditions.
/// ~2.45 MJ/kg. `// VERIFY` (textbook value).
const double kWaterLatentHeatJPerKg = 2450000.0;

// ---------------------------------------------------------------------------
// Inputs.
// ---------------------------------------------------------------------------

/// One exposed envelope surface (wall/roof/glass): its area and U-value.
final class EnvelopeSurface {
  /// Surface area exposed to the outdoor ΔT.
  final Area area;

  /// Thermal transmittance U (W/m²·K).
  final double uValueWPerM2K;

  const EnvelopeSurface({required this.area, required this.uValueWPerM2K});
}

/// Inputs for [estimateDetailedCoolingLoad]. Only [floorArea] and
/// [ceilingHeight] are required; everything else defaults to a representative
/// `// VERIFY` figure so a caller can start from geometry alone.
final class DetailedCoolingLoadInputs {
  /// Conditioned floor area (drives floor-density gains + default volume).
  final Area floorArea;

  /// Floor-to-ceiling height (drives the ventilation volume).
  final Length ceilingHeight;

  /// Opaque wall area exposed to outdoor air. Default 0 (interior room).
  final Area wallArea;

  /// Roof/ceiling area exposed to outdoor air (top floor). Default 0.
  final Area roofArea;

  /// Glazing area (also used for the solar gain). Default 0.
  final Area glassArea;

  /// Wall / roof / glass U-values (W/m²·K).
  final double wallUValue;
  final double roofUValue;
  final double glassUValue;

  /// Solar properties of the glazing.
  final double glassShgc;
  final double solarIrradianceWPerM2;

  /// Outdoor design dry-bulb / humidity differences.
  final double deltaTK;
  final double deltaWKgPerKg;

  /// Internal-gain inputs.
  final int? occupantCount; // null ⇒ density × floor area
  final double peopleDensityPerM2;
  final double personSensibleW;
  final double personLatentW;
  final double lightingWPerM2;
  final double equipmentWPerM2;

  /// Ventilation/infiltration airflow. When null, derived from
  /// [ventilationAch] × room volume.
  final FlowRate? ventilationAirflow;
  final double ventilationAch;

  const DetailedCoolingLoadInputs({
    required this.floorArea,
    required this.ceilingHeight,
    this.wallArea = const Area(0.0),
    this.roofArea = const Area(0.0),
    this.glassArea = const Area(0.0),
    this.wallUValue = kDefaultWallUValue,
    this.roofUValue = kDefaultRoofUValue,
    this.glassUValue = kDefaultGlassUValue,
    this.glassShgc = kDefaultGlassShgc,
    this.solarIrradianceWPerM2 = kDefaultSolarIrradianceWPerM2,
    this.deltaTK = kDefaultDesignDeltaTK,
    this.deltaWKgPerKg = kDefaultDesignDeltaWKgPerKg,
    this.occupantCount,
    this.peopleDensityPerM2 = kDefaultPeopleDensityPerM2,
    this.personSensibleW = kDefaultPersonSensibleW,
    this.personLatentW = kDefaultPersonLatentW,
    this.lightingWPerM2 = kDefaultLightingWPerM2,
    this.equipmentWPerM2 = kDefaultEquipmentWPerM2,
    this.ventilationAirflow,
    this.ventilationAch = kDefaultVentilationAch,
  });

  /// Number of occupants — explicit count, else density × floor area (rounded).
  int get resolvedOccupants =>
      occupantCount ?? (peopleDensityPerM2 * floorArea.squareMeters).round();

  /// Ventilation airflow (m³/s) — explicit value, else ACH × volume / 3600.
  FlowRate get resolvedVentilationAirflow =>
      ventilationAirflow ??
      FlowRate(floorArea.squareMeters *
          ceilingHeight.meters *
          ventilationAch /
          3600.0);
}

// ---------------------------------------------------------------------------
// Component primitives (each a single physical heat-gain stream, in watts).
// Kept public so tests can hand-verify them independently.
// ---------------------------------------------------------------------------

/// Conduction/transmission gain Q = U·A·ΔT through one surface (W).
double transmissionGainW(EnvelopeSurface s, double deltaTK) =>
    s.uValueWPerM2K * s.area.squareMeters * deltaTK;

/// Solar gain through glazing Q = SHGC · irradiance · area (W).
double solarGainW({
  required Area glassArea,
  required double shgc,
  required double irradianceWPerM2,
}) =>
    shgc * irradianceWPerM2 * glassArea.squareMeters;

/// Sensible ventilation/infiltration gain Q = ρ·cp · V̇ · ΔT (W).
double ventilationSensibleW({
  required FlowRate airflow,
  required double deltaTK,
}) =>
    kAirDensityKgPerM3 *
    kAirCpJPerKgK *
    airflow.cubicMetersPerSecond *
    deltaTK;

/// Latent ventilation/infiltration gain Q = ρ·h_fg · V̇ · Δw (W).
double ventilationLatentW({
  required FlowRate airflow,
  required double deltaWKgPerKg,
}) =>
    kAirDensityKgPerM3 *
    kWaterLatentHeatJPerKg *
    airflow.cubicMetersPerSecond *
    deltaWKgPerKg;

// ---------------------------------------------------------------------------
// Result.
// ---------------------------------------------------------------------------

/// Transparent component breakdown of the detailed cooling load. All component
/// fields are watts (thermal); the headline figures convert to BTU/h + PK.
final class DetailedCoolingLoad {
  /// Conduction through walls + roof + glazing (W, sensible).
  final double transmissionW;

  /// Solar gain through glazing (W, sensible).
  final double solarW;

  /// People sensible gain (W).
  final double peopleSensibleW;

  /// People latent gain (W).
  final double peopleLatentW;

  /// Lighting gain (W, all sensible).
  final double lightingW;

  /// Equipment / plug load (W, all sensible).
  final double equipmentW;

  /// Ventilation/infiltration sensible gain (W).
  final double ventilationSensibleW;

  /// Ventilation/infiltration latent gain (W).
  final double ventilationLatentW;

  /// Number of occupants used for the people gains.
  final int occupants;

  /// Ventilation/infiltration airflow used (m³/s).
  final FlowRate ventilationAirflow;

  const DetailedCoolingLoad({
    required this.transmissionW,
    required this.solarW,
    required this.peopleSensibleW,
    required this.peopleLatentW,
    required this.lightingW,
    required this.equipmentW,
    required this.ventilationSensibleW,
    required this.ventilationLatentW,
    required this.occupants,
    required this.ventilationAirflow,
  });

  /// Total sensible load (W) = transmission + solar + people-sensible +
  /// lighting + equipment + ventilation-sensible.
  double get sensibleW =>
      transmissionW +
      solarW +
      peopleSensibleW +
      lightingW +
      equipmentW +
      ventilationSensibleW;

  /// Total latent load (W) = people-latent + ventilation-latent.
  double get latentW => peopleLatentW + ventilationLatentW;

  /// Grand total cooling load (W) = sensible + latent — the coil duty.
  double get totalW => sensibleW + latentW;

  /// Sensible heat ratio SHR = sensible / total (0–1). 1.0 when there is no
  /// latent load (guards a zero total).
  double get sensibleHeatRatio => totalW > 0 ? sensibleW / totalW : 1.0;

  /// Total load in BTU/h — the customary AC headline figure.
  double get totalBtuPerHr => wattsToBtuPerHr(totalW);

  /// Total load in PK (= BTU/h ÷ 9000).
  double get totalPk => btuPerHrToPk(totalBtuPerHr);

  /// Nearest standard AC at or above the total load (rejects sensible + latent).
  AcSelection get recommended => selectAc(totalBtuPerHr);
}

// ---------------------------------------------------------------------------
// The estimator.
// ---------------------------------------------------------------------------

/// Compute the detailed (heat-gain) cooling load for a room from [inputs].
///
/// Sums the four sensible streams (transmission, solar, internal-sensible,
/// ventilation-sensible) and the two latent streams (people + ventilation), then
/// exposes both the split and the standard-AC recommendation. All coefficients
/// are representative `// VERIFY` defaults unless the caller overrides them.
DetailedCoolingLoad estimateDetailedCoolingLoad(
    DetailedCoolingLoadInputs inputs) {
  assert(inputs.floorArea.squareMeters > 0, 'floorArea must be positive');
  assert(inputs.ceilingHeight.meters > 0, 'ceilingHeight must be positive');

  // Envelope transmission: walls + roof + glazing, each U·A·ΔT.
  final transmission = transmissionGainW(
        EnvelopeSurface(
            area: inputs.wallArea, uValueWPerM2K: inputs.wallUValue),
        inputs.deltaTK,
      ) +
      transmissionGainW(
        EnvelopeSurface(
            area: inputs.roofArea, uValueWPerM2K: inputs.roofUValue),
        inputs.deltaTK,
      ) +
      transmissionGainW(
        EnvelopeSurface(
            area: inputs.glassArea, uValueWPerM2K: inputs.glassUValue),
        inputs.deltaTK,
      );

  // Solar gain through the glazing.
  final solar = solarGainW(
    glassArea: inputs.glassArea,
    shgc: inputs.glassShgc,
    irradianceWPerM2: inputs.solarIrradianceWPerM2,
  );

  // Internal gains.
  final occupants = inputs.resolvedOccupants;
  final peopleSensible = occupants * inputs.personSensibleW;
  final peopleLatent = occupants * inputs.personLatentW;
  final lighting = inputs.lightingWPerM2 * inputs.floorArea.squareMeters;
  final equipment = inputs.equipmentWPerM2 * inputs.floorArea.squareMeters;

  // Ventilation/infiltration (sensible + latent).
  final ventAir = inputs.resolvedVentilationAirflow;
  final ventSensible =
      ventilationSensibleW(airflow: ventAir, deltaTK: inputs.deltaTK);
  final ventLatent = ventilationLatentW(
      airflow: ventAir, deltaWKgPerKg: inputs.deltaWKgPerKg);

  return DetailedCoolingLoad(
    transmissionW: transmission,
    solarW: solar,
    peopleSensibleW: peopleSensible,
    peopleLatentW: peopleLatent,
    lightingW: lighting,
    equipmentW: equipment,
    ventilationSensibleW: ventSensible,
    ventilationLatentW: ventLatent,
    occupants: occupants,
    ventilationAirflow: ventAir,
  );
}

/// The `// VERIFY` honesty surface for the detailed-cooling-load coefficients —
/// every representative figure that is NOT a confirmed SNI clause. Surface this
/// in any report that uses [estimateDetailedCoolingLoad], like the ventilation
/// profile's `verifyChecklist`.
List<StandardValue<Object?>> get detailedCoolingVerifyChecklist =>
    <StandardValue<Object?>>[
      const StandardValue<Object?>(
        'envelope U-values (wall/roof/glass)',
        unit: 'W/m2.K',
        citation: 'general HVAC practice (ASHRAE Fundamentals) — not an SNI clause',
        verified: false,
        status: VerificationStatus.secondarySource,
        note: 'Representative steady-state U-values (wall ~2.5, roof ~1.5, glass '
            '~3.0 W/m2.K); confirm against the actual construction / an SNI '
            'envelope audit.',
      ),
      const StandardValue<Object?>(
        'glazing solar gain (SHGC + design irradiance)',
        unit: 'SHGC / W/m2',
        citation: 'general HVAC practice — not an SNI clause',
        verified: false,
        status: VerificationStatus.secondarySource,
        note: 'SHGC ~0.65 (clear glass) and ~300 W/m2 peak-hour irradiance are '
            'representative; confirm against the glazing spec + a solar study.',
      ),
      const StandardValue<Object?>(
        'internal gains (people sensible/latent, lighting, equipment)',
        unit: 'W / W/m2',
        citation: 'general HVAC practice (ASHRAE) — not an SNI clause',
        verified: false,
        status: VerificationStatus.secondarySource,
        note: 'Person ~75 W sensible / ~55 W latent (seated light work), '
            'lighting ~10 W/m2, equipment ~12 W/m2, ~0.1 people/m2; confirm '
            'against the occupancy + lighting + equipment schedule.',
      ),
      const StandardValue<Object?>(
        'outdoor design conditions (dT, dw) + infiltration rate',
        unit: 'K / kg/kg / ACH',
        citation: 'general HVAC practice — not an SNI clause',
        verified: false,
        status: VerificationStatus.secondarySource,
        note: 'Design dT ~9 K, dw ~0.010 kg/kg, ~1 ACH outdoor air, air rho '
            '1.2 kg/m3, cp 1005 J/kg.K, h_fg 2.45 MJ/kg are representative '
            'hot-humid figures; confirm against the site design conditions.',
      ),
    ];
