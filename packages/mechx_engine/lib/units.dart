/// Typed SI quantities — the single internal unit system for the whole MechX
/// engine.
///
/// Architecture guardrail (§12): one unit system internally (SI). Every
/// quantity is stored in SI base units. Modules pass these *typed* quantities
/// to each other — never bare `double`s — so a length can never be silently
/// mistaken for a flow or a pressure. Conversion to/from engineering units
/// (mm, L/s, kPa, bar …) happens only at construction (static helpers) and
/// display (`inXxx` getters), i.e. at the UI boundary.
///
/// These are Dart 3 `extension type`s: zero-cost wrappers over `double`. At
/// runtime a `Velocity` *is* its `double`, so there is no allocation overhead,
/// but the static type system keeps the dimensions honest.
library;

/// Length in metres (m). Used for pipe runs, floor-elevation deltas, hydraulic
/// radius, etc.
extension type const Length(double meters) {
  /// From millimetres.
  static Length mm(double millimeters) => Length(millimeters / 1000.0);

  /// From centimetres.
  static Length cm(double centimeters) => Length(centimeters / 100.0);

  /// From kilometres.
  static Length km(double kilometers) => Length(kilometers * 1000.0);

  double get inMillimeters => meters * 1000.0;
  double get inCentimeters => meters * 100.0;
}

/// Pipe / duct inside diameter in metres (m). Kept distinct from [Length] so a
/// diameter and a run length cannot be transposed at a call site.
extension type const Diameter(double meters) {
  /// From millimetres (the usual way diameters are quoted).
  static Diameter mm(double millimeters) => Diameter(millimeters / 1000.0);

  double get inMillimeters => meters * 1000.0;
}

/// Cross-sectional / surface area in square metres (m²).
extension type const Area(double squareMeters) {
  static Area squareMillimeters(double mm2) => Area(mm2 / 1e6);

  double get inSquareMillimeters => squareMeters * 1e6;
}

/// Flow velocity in metres per second (m/s).
extension type const Velocity(double metersPerSecond) {}

/// Volumetric flow rate in cubic metres per second (m³/s).
extension type const FlowRate(double cubicMetersPerSecond) {
  /// Exact volume of one cubic foot in cubic metres (0.3048 m per foot, cubed).
  static const double _cubicMetresPerCubicFoot = 0.028316846592;

  static FlowRate litersPerSecond(double lps) => FlowRate(lps / 1000.0);
  static FlowRate litersPerMinute(double lpm) => FlowRate(lpm / 60000.0);
  static FlowRate cubicMetersPerHour(double m3h) => FlowRate(m3h / 3600.0);

  /// From cubic feet per minute (CFM) — the customary HVAC airflow unit.
  static FlowRate cubicFeetPerMinute(double cfm) =>
      FlowRate(cfm * _cubicMetresPerCubicFoot / 60.0);

  double get inLitersPerSecond => cubicMetersPerSecond * 1000.0;
  double get inLitersPerMinute => cubicMetersPerSecond * 60000.0;
  double get inCubicMetersPerHour => cubicMetersPerSecond * 3600.0;

  /// In cubic feet per minute (CFM). 1 m³/s ≈ 2118.88 CFM.
  double get inCubicFeetPerMinute =>
      cubicMetersPerSecond * 60.0 / _cubicMetresPerCubicFoot;
}

/// Pressure in pascals (Pa).
extension type const Pressure(double pascals) {
  static Pressure kiloPascals(double kpa) => Pressure(kpa * 1000.0);
  static Pressure bar(double bar) => Pressure(bar * 1e5);

  double get inKiloPascals => pascals / 1000.0;
  double get inBar => pascals / 1e5;
}

/// Pressure expressed as head of fluid, in metres (m). Convert to/from
/// [Pressure] via the helpers in `hydraulics.dart` (needs fluid density + g).
extension type const Head(double meters) {}

/// Mechanical / hydraulic power in watts (W).
extension type const Power(double watts) {
  static Power kiloWatts(double kw) => Power(kw * 1000.0);

  double get inKiloWatts => watts / 1000.0;
}

/// Absolute wall roughness ε in metres (m), for Darcy–Weisbach / Colebrook.
extension type const Roughness(double meters) {
  static Roughness mm(double millimeters) => Roughness(millimeters / 1000.0);

  double get inMillimeters => meters * 1000.0;
}

// ---------------------------------------------------------------------------
// Electrical quantities (the "E" domain — PUIL / IEC sizing).
//
// Same guardrail as the mechanical quantities above: stored in SI base units,
// constructed from / displayed in engineering units only at the boundary.
// Real (active) power reuses the existing [Power] (W); the electrical types
// below add the dimensions that have no mechanical analogue. Keeping apparent
// power (VA), reactive power (var) and active power (W) as *distinct* types
// means a kVA can never be silently summed with a kW.
// ---------------------------------------------------------------------------

/// Electric current in amperes (A). Design/load current `Ib`, breaker rating
/// `In`, full-load amps; fault levels are quoted in kA.
extension type const Current(double amperes) {
  /// From milliamperes (e.g. RCD trip thresholds: 30 mA).
  static Current milliamperes(double mA) => Current(mA / 1000.0);

  /// From kiloamperes (e.g. prospective short-circuit current).
  static Current kiloamperes(double kA) => Current(kA * 1000.0);

  double get inMilliamperes => amperes * 1000.0;
  double get inKiloamperes => amperes / 1000.0;
}

/// Electric potential in volts (V). Phase/line voltage, MV supply.
extension type const Voltage(double volts) {
  /// From kilovolts (e.g. 20 kV MV supply).
  static Voltage kilovolts(double kV) => Voltage(kV * 1000.0);

  double get inKilovolts => volts / 1000.0;
}

/// Apparent power in volt-amperes (VA). Distinct from [Power] (W, active) so a
/// kVA can't be confused with a kW. Transformer / supply / daya tersambung.
extension type const ApparentPower(double voltAmperes) {
  /// From kilovolt-amperes (kVA).
  static ApparentPower kilovoltAmperes(double kVA) =>
      ApparentPower(kVA * 1000.0);

  double get inKilovoltAmperes => voltAmperes / 1000.0;
}

/// Reactive power in volt-amperes reactive (var). Power-factor correction.
extension type const ReactivePower(double voltAmperesReactive) {
  /// From kilovar (kvar) — capacitor-bank steps.
  static ReactivePower kilovar(double kvar) =>
      ReactivePower(kvar * 1000.0);

  double get inKilovar => voltAmperesReactive / 1000.0;
}

/// Electrical resistance / impedance magnitude in ohms (Ω). Conductor
/// resistance, earth-fault loop impedance `Zs`, source impedance.
extension type const Resistance(double ohms) {
  /// From milliohms (conductor / loop impedances are typically small).
  static Resistance milliohms(double mOhm) => Resistance(mOhm / 1000.0);

  double get inMilliohms => ohms * 1000.0;
}

/// Energy in joules (J). Daily consumption, battery autonomy; quoted in kWh.
extension type const Energy(double joules) {
  /// From kilowatt-hours (1 kWh = 3.6 MJ).
  static Energy kilowattHours(double kWh) => Energy(kWh * 3.6e6);

  double get inKilowattHours => joules / 3.6e6;
}
