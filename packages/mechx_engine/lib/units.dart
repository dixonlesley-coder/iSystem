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
  static FlowRate litersPerSecond(double lps) => FlowRate(lps / 1000.0);
  static FlowRate litersPerMinute(double lpm) => FlowRate(lpm / 60000.0);
  static FlowRate cubicMetersPerHour(double m3h) => FlowRate(m3h / 3600.0);

  double get inLitersPerSecond => cubicMetersPerSecond * 1000.0;
  double get inLitersPerMinute => cubicMetersPerSecond * 60000.0;
  double get inCubicMetersPerHour => cubicMetersPerSecond * 3600.0;
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
