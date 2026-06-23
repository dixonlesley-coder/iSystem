/// Indonesian PUIL electrical standards profile — pluggable data + lookups for
/// the "E" (electrical) domain, the sibling of [StandardsProfile]/`SniProfile`.
///
/// PUIL 2011 is published as **SNI 0225:2011** (amended 2020), so the same
/// [VerificationStatus] honesty tiers apply verbatim: `sniVerbatim` here means
/// "confirmed against the official PUIL / SNI 0225 text".
///
/// PROVENANCE POLICY (mirrors `sni.dart`): values ported from the PanelMaker
/// reference app default to **`secondarySource`** — they are real engineering
/// figures (manufacturer cable catalogues, IEC 60364/60898/60947 tables, PLN
/// practice) corroborated in literature, but NOT yet confirmed against the
/// official PUIL 2011 PDF. Rules-of-thumb that are deliberately general practice
/// (e.g. the busbar current-density fallback) are tagged `notAnSniClause`.
/// **Nothing is `sniVerbatim`** until checked against the official SNI 0225:2011
/// document — do NOT flip a flag from a secondary source (§12.6). Every
/// unverified value MUST surface via [verifyChecklist] in any report.
///
/// Source of the seed values: the PanelMaker (Electron/PUIL) `src/shared/
/// standards/{conductors,protection,grounding}.ts` tables, themselves sourced
/// from Supreme Cable (SUCACO) catalogues + IEC 60364-5-52/54.
///
/// Zero Flutter imports.
library;

import '../units.dart';
import 'sni.dart' show StandardValue, VerificationStatus;

/// Conductor insulation — PVC (70 °C) or XLPE (90 °C). Selects the ampacity
/// table and the ambient-derating curve.
enum ConductorInsulation { pvc, xlpe }

/// Conductor metal. Aluminium derates ampacity and raises resistance vs copper.
enum ConductorMaterial { copper, aluminum }

/// Installation method (the app's vocabulary). Maps to an IEC 60364-5-52
/// reference method whose ampacity table applies — see [refMethodFor].
enum CableInstallMethod { conduit, trunking, wall, air, tray, buried }

/// IEC 60364-5-52 reference installation methods the profile distinguishes:
///   B1 — in conduit/trunking on a wall (the base tables);
///   C  — clipped direct to a surface;
///   E  — free air / perforated tray;
///   D  — buried in the ground.
enum RefMethod { b1, c, e, d }

/// Trip curve (IEC 60898): B resistive/lighting, C general, D high-inrush.
enum BreakerCurve { b, c, d }

/// Breaker frame class — ≤63 A is an MCB, above it an MCCB.
enum BreakerClass { mcb, mccb }

/// A standard copper flat-bar size + its continuous rating.
class CopperBarSize {
  final double widthMm;
  final double thicknessMm;
  final double csaMm2;
  final Current ampacityA;
  const CopperBarSize(
      this.widthMm, this.thicknessMm, this.csaMm2, this.ampacityA);
}

/// The pluggable electrical-standards interface. The sizing layer depends on
/// THIS, never on the concrete PUIL numbers, so another jurisdiction's profile
/// can be swapped in. Mirrors `StandardsProfile`'s shape for the M+P domain.
abstract interface class ElectricalStandardsProfile {
  String get name;
  String get revision;

  // ── Supply / voltages ─────────────────────────────────────────────────────
  /// Nominal line (3-phase) voltage, e.g. 400 V.
  StandardValue<Voltage> get nominalLineVoltage;

  /// Nominal single-phase (phase-to-neutral, residential) voltage, e.g. 220 V.
  StandardValue<Voltage> get nominalSinglePhaseVoltage;

  /// Phase-to-neutral voltage used in fault/Zs calcs (U0), e.g. 230 V.
  StandardValue<Voltage> get nominalPhaseVoltage;

  /// Supply frequency (Hz).
  StandardValue<double> get nominalFrequencyHz;

  // ── Voltage drop limits (fraction, e.g. 0.05 = 5 %) ───────────────────────
  StandardValue<double> get maxVoltageDropGeneral;
  StandardValue<double> get maxVoltageDropLighting;

  // ── Cable sizing rule constants ───────────────────────────────────────────
  /// Continuous-load factor: cable Iz ≥ max(In, factor·Ib). PUIL/IEC 125 %.
  StandardValue<double> get continuousLoadFactor;

  /// Standard copper conductor cross-sections (mm²), ascending.
  List<double> get standardSectionsMm2;

  /// Smallest practical aluminium section (mm²).
  double get aluminiumMinSectionMm2;

  /// PUIL final-circuit minimum section (mm²) for a given character.
  double minSectionMm2({
    required bool lighting,
    required bool trunk,
    required bool threePhase,
  });

  // ── Ampacity (KHA) ────────────────────────────────────────────────────────
  /// IEC reference method whose ampacity table applies to an install method.
  RefMethod refMethodFor(CableInstallMethod method);

  /// Current-carrying capacity (KHA) at 30 °C for a standard [sectionMm2] under
  /// the given insulation / material / install method. `Current(0)` if unknown.
  Current ampacity(
    double sectionMm2, {
    ConductorInsulation insulation,
    ConductorMaterial material,
    CableInstallMethod method,
  });

  /// AC resistance (Ω/km, ~70 °C operating) for a section + material.
  double conductorResistanceOhmPerKm(double sectionMm2, {ConductorMaterial material});

  /// Typical LV cable reactance (Ω/km), roughly section-independent.
  double get conductorReactanceOhmPerKm;

  // ── Derating curves (multiplicative factors) ──────────────────────────────
  /// Ambient-temperature correction table (°C → factor) for the insulation.
  Map<double, double> ambientTempFactors(ConductorInsulation insulation);

  /// Grouping (bunching) correction table (circuit count → factor).
  Map<double, double> get groupingFactors;

  /// Buried soil thermal-resistivity correction table (K·m/W → factor).
  Map<double, double> get soilThermalResistivityFactors;

  /// IEC reference soil thermal resistivity (K·m/W) → factor 1.0.
  double get soilThermalResistivityReferenceKmW;

  /// Buried-run ground-temperature correction table (°C → factor), per
  /// insulation (IEC 60364-5-52 Table B.52.15, ground reference 20 °C). Used
  /// INSTEAD of the air ambient table for buried runs.
  Map<double, double> groundTempFactors(ConductorInsulation insulation);

  /// Buried-run depth-of-laying correction table (m → factor), reference 0.5 m.
  Map<double, double> get depthOfLayingFactors;

  // ── Protection ────────────────────────────────────────────────────────────
  /// Standard MCB ratings (A), IEC 60898.
  List<double> get mcbRatingsA;

  /// Standard MCCB preferred ratings (A), IEC 60947-2 (R10).
  List<double> get mccbRatingsA;

  /// All breaker frame ratings, ascending.
  List<double> get standardBreakerRatingsA;

  /// MCB (≤63 A) vs MCCB frame for a rating.
  BreakerClass breakerClassFor(double ratingA);

  /// Recommended trip curve for a load character.
  BreakerCurve recommendedCurve({required bool lighting, required bool motor});

  // ── Earthing / protective conductors ──────────────────────────────────────
  /// PE conductor section (mm²) from the phase CSA (IEC 60364-5-54 Table 54.2).
  double peConductorSizeMm2(double phaseCsaMm2);

  /// Neutral conductor section (mm²); [reduced] halves above 16 mm².
  double neutralConductorSizeMm2(double phaseCsaMm2, {bool reduced});

  /// Main earthing conductor (mm²): clamp(phasePE, 16..50).
  double mainEarthingConductorMm2(double supplyPeMm2);

  /// Main protective-bonding conductor (mm²): max(6, PE/2), capped at 25.
  double mainBondingConductorMm2(double supplyPeMm2);

  /// Target maximum earth-electrode resistance (Ω). PUIL ≈ 5 Ω.
  StandardValue<Resistance> get maxEarthResistance;

  // ── Busbar ────────────────────────────────────────────────────────────────
  /// Standard copper flat-bar sizes + continuous ratings (single bar, ~30 °C
  /// rise, painted), ascending by ampacity.
  List<CopperBarSize> get copperBusbarTable;

  /// Conservative continuous current density (A/mm²) for sizing a bar beyond the
  /// tabulated sizes.
  double get copperCurrentDensityAPerMm2;

  /// Max outgoing ways on one busbar section before the panel bus is split.
  int get maxWaysPerBusbar;

  /// Max continuous current one section carries before splitting (the largest
  /// practical single bar's rating).
  Current get maxBusbarSectionCurrentA;

  // ── Busbar short-circuit withstand (IEC 61439-1 §9.3 — engineering data) ────
  /// One-second short-time withstand current *density* for a bare copper bar
  /// (A/mm²). A short circuit is adiabatic, so the rated short-time withstand
  /// current scales as Icw(t) = density·CSA / √t (IEC 61439-1 §9.3.2). Used to
  /// floor a bar at the section the prospective fault demands.
  double get busbarShortTimeDensityAPerMm2;

  /// IEC 61439-1 Table 7 peak factor n (= Ipk / Irms) for a prospective rms
  /// short-circuit current (kA) — folds in the worst-case DC-offset asymmetry.
  double busbarPeakFactor(double faultKa);

  /// Unverified values, most safety-critical first, for the report's
  /// "verify against the official PUIL PDF" section.
  List<StandardValue<Object?>> get verifyChecklist;
}

/// PUIL 2011 (SNI 0225:2011) profile, seeded from the PanelMaker reference data.
class PuilProfile implements ElectricalStandardsProfile {
  const PuilProfile();

  static const String _doc = 'PUIL 2011 (SNI 0225:2011)';

  @override
  String get name => 'PUIL — Persyaratan Umum Instalasi Listrik';

  @override
  String get revision =>
      'PUIL 2011 (SNI 0225:2011, amd. 2020) values ported 2026-06 from the '
      'PanelMaker reference app (Supreme Cable / SUCACO catalogues + '
      'IEC 60364-5-52/54, IEC 60898/60947). All secondary-sourced — clauses '
      'pending confirmation against the official PUIL PDF.';

  // ── Supply / voltages ─────────────────────────────────────────────────────

  @override
  StandardValue<Voltage> get nominalLineVoltage => const StandardValue(
        Voltage(400.0),
        unit: 'V',
        citation: '$_doc — nominal LV line voltage (3-phase)',
        verified: false,
        note: 'Indonesian LV three-phase nominal 400 V (230/400 V). '
            'Confirm clause against the official PUIL text.',
      );

  @override
  StandardValue<Voltage> get nominalSinglePhaseVoltage => const StandardValue(
        Voltage(220.0),
        unit: 'V',
        citation: '$_doc — nominal LV single-phase voltage',
        verified: false,
        note: 'Indonesian residential single-phase nominal 220 V. '
            'Confirm clause against the official PUIL text.',
      );

  @override
  StandardValue<Voltage> get nominalPhaseVoltage => const StandardValue(
        Voltage(230.0),
        unit: 'V',
        citation: '$_doc / IEC 60364 — phase-to-neutral voltage U0 (fault/Zs)',
        verified: false,
        note: 'U0 = 230 V used for earth-fault-loop (Zs) and ADS limits. '
            'IEC harmonised value; confirm against PUIL.',
      );

  @override
  StandardValue<double> get nominalFrequencyHz => const StandardValue(
        50.0,
        unit: 'Hz',
        citation: '$_doc — supply frequency',
        verified: false,
        note: 'Indonesian grid frequency 50 Hz.',
      );

  // ── Voltage drop ──────────────────────────────────────────────────────────

  @override
  StandardValue<double> get maxVoltageDropGeneral => const StandardValue(
        0.05,
        unit: '%',
        citation: '$_doc §4.2.3 / IEC 60364-5-52 — max voltage drop (general)',
        verified: false,
        note: 'Drop tegangan maks. 5 % dari titik suplai ke beban (umum). '
            'Confirm the PUIL clause.',
      );

  @override
  StandardValue<double> get maxVoltageDropLighting => const StandardValue(
        0.03,
        unit: '%',
        citation: '$_doc §4.2.3 / IEC 60364-5-52 — max voltage drop (lighting)',
        verified: false,
        note: 'Drop tegangan maks. 3 % untuk sirkit penerangan. '
            'Confirm the PUIL clause.',
      );

  // ── Cable sizing constants ────────────────────────────────────────────────

  @override
  StandardValue<double> get continuousLoadFactor => const StandardValue(
        1.25,
        unit: '×',
        citation: '$_doc / IEC 60364-4-43 — continuous-load factor (Iz ≥ 1.25·Ib)',
        verified: false,
        note: 'Cable Iz must be ≥ max(In, 1.25·Ib); 125 % continuous-load rule.',
      );

  @override
  List<double> get standardSectionsMm2 => const <double>[
        1.5, 2.5, 4, 6, 10, 16, 25, 35, 50, 70, 95, 120, 150, 185, 240, 300,
      ];

  @override
  double get aluminiumMinSectionMm2 => 16;

  @override
  double minSectionMm2({
    required bool lighting,
    required bool trunk,
    required bool threePhase,
  }) {
    // PanelMaker computePanel: trunk → (3φ ? 4 : 2.5); final → (lighting ? 1.5 : 2.5).
    if (trunk) return threePhase ? 4 : 2.5;
    return lighting ? 1.5 : 2.5;
  }

  // ── Ampacity (KHA) ────────────────────────────────────────────────────────

  @override
  RefMethod refMethodFor(CableInstallMethod method) => switch (method) {
        CableInstallMethod.conduit => RefMethod.b1,
        CableInstallMethod.trunking => RefMethod.b1,
        CableInstallMethod.wall => RefMethod.c,
        CableInstallMethod.air => RefMethod.e,
        CableInstallMethod.tray => RefMethod.e,
        CableInstallMethod.buried => RefMethod.d,
      };

  // Base KHA, copper / PVC, 30 °C, reference method B1 (Supreme NYY "in air").
  static final Map<double, double> _khaCuPvcB1 = {
    1.5: 18, 2.5: 25, 4: 34, 6: 44, 10: 60, 16: 80, 25: 105, 35: 130,
    50: 160, 70: 200, 95: 245, 120: 285, 150: 325, 185: 370, 240: 435, 300: 500,
  };
  // Base KHA, copper / XLPE (90 °C), method B1 (~IEC 60364-5-52 Table B.52.4).
  static final Map<double, double> _khaCuXlpeB1 = {
    1.5: 20, 2.5: 28, 4: 37, 6: 48, 10: 66, 16: 88, 25: 117, 35: 144,
    50: 175, 70: 222, 95: 269, 120: 312, 150: 358, 185: 408, 240: 481, 300: 553,
  };
  // Copper/PVC by method C/E (== B1 "in air") and D (buried, "in ground").
  static final Map<double, double> _khaCuPvcD = {
    1.5: 24, 2.5: 32, 4: 41, 6: 52, 10: 69, 16: 89, 25: 116, 35: 138,
    50: 165, 70: 205, 95: 245, 120: 285, 150: 315, 185: 355, 240: 415, 300: 465,
  };
  // Copper/XLPE by method.
  static final Map<double, double> _khaCuXlpeC = {
    1.5: 24, 2.5: 33, 4: 45, 6: 58, 10: 80, 16: 107, 25: 138, 35: 171,
    50: 209, 70: 269, 95: 328, 120: 382, 150: 441, 185: 506, 240: 599, 300: 693,
  };
  static final Map<double, double> _khaCuXlpeE = {
    1.5: 26, 2.5: 36, 4: 49, 6: 63, 10: 86, 16: 115, 25: 149, 35: 185,
    50: 225, 70: 289, 95: 352, 120: 410, 150: 473, 185: 542, 240: 641, 300: 741,
  };
  static final Map<double, double> _khaCuXlpeD = {
    1.5: 21, 2.5: 28, 4: 36, 6: 44, 10: 58, 16: 75, 25: 96, 35: 115,
    50: 135, 70: 167, 95: 197, 120: 223, 150: 251, 185: 281, 240: 324, 300: 365,
  };

  /// Aluminium ampacity as a fraction of copper at equal section.
  static const double _alAmpacityRatio = 0.78;

  /// Aluminium/copper resistance ratio (ρAl ≈ 0.036 vs ρCu ≈ 0.0225).
  static const double _alResistanceRatio = 1.61;

  @override
  Current ampacity(
    double sectionMm2, {
    ConductorInsulation insulation = ConductorInsulation.pvc,
    ConductorMaterial material = ConductorMaterial.copper,
    CableInstallMethod method = CableInstallMethod.conduit,
  }) {
    final ref = refMethodFor(method);
    double cu;
    if (insulation == ConductorInsulation.pvc) {
      cu = switch (ref) {
        // C/E read the "in air" base table; D reads "in ground".
        RefMethod.b1 || RefMethod.c || RefMethod.e =>
          _khaCuPvcB1[sectionMm2] ?? 0,
        RefMethod.d => _khaCuPvcD[sectionMm2] ?? 0,
      };
    } else {
      cu = switch (ref) {
        RefMethod.b1 => _khaCuXlpeB1[sectionMm2] ?? 0,
        RefMethod.c => _khaCuXlpeC[sectionMm2] ?? 0,
        RefMethod.e => _khaCuXlpeE[sectionMm2] ?? 0,
        RefMethod.d => _khaCuXlpeD[sectionMm2] ?? 0,
      };
    }
    final a = material == ConductorMaterial.aluminum ? cu * _alAmpacityRatio : cu;
    return Current(a);
  }

  // AC resistance (Ω/km, ~70 °C), copper. IEC 60909 / manufacturer data.
  static final Map<double, double> _resistanceOhmPerKm = {
    1.5: 14.5, 2.5: 8.87, 4: 5.52, 6: 3.69, 10: 2.19, 16: 1.38, 25: 0.87,
    35: 0.627, 50: 0.463, 70: 0.321, 95: 0.232, 120: 0.184, 150: 0.15,
    185: 0.121, 240: 0.0930, 300: 0.0752,
  };

  @override
  double conductorResistanceOhmPerKm(
    double sectionMm2, {
    ConductorMaterial material = ConductorMaterial.copper,
  }) {
    // Tabulated copper, else a resistivity estimate (ρCu ≈ 0.0225 Ω·mm²/m).
    final cu = _resistanceOhmPerKm[sectionMm2] ?? (0.0225 / sectionMm2) * 1000;
    return material == ConductorMaterial.aluminum ? cu * _alResistanceRatio : cu;
  }

  @override
  double get conductorReactanceOhmPerKm => 0.08;

  // ── Derating ──────────────────────────────────────────────────────────────

  // IEC 60364-5-52 Table B.52.14 (base 30 °C).
  static final Map<double, double> _ambientPvc = {
    10: 1.22, 15: 1.17, 20: 1.12, 25: 1.06, 30: 1.0, 35: 0.94, 40: 0.87,
    45: 0.79, 50: 0.71, 55: 0.61, 60: 0.5,
  };
  static final Map<double, double> _ambientXlpe = {
    10: 1.15, 15: 1.12, 20: 1.08, 25: 1.04, 30: 1.0, 35: 0.96, 40: 0.91,
    45: 0.87, 50: 0.82, 55: 0.76, 60: 0.71,
  };

  @override
  Map<double, double> ambientTempFactors(ConductorInsulation insulation) =>
      insulation == ConductorInsulation.xlpe ? _ambientXlpe : _ambientPvc;

  // Double keys can't be const map keys in Dart (no primitive equality), so
  // these are static final (built once) rather than const.
  static final Map<double, double> _groupingFactors = {
    1: 1.0, 2: 0.8, 3: 0.7, 4: 0.65, 5: 0.6, 6: 0.57, 7: 0.54, 8: 0.52, 9: 0.5,
  };
  static final Map<double, double> _soilThermalFactors = {
    1: 1.18, 1.5: 1.1, 2: 1.05, 2.5: 1.0, 3: 0.96,
  };

  @override
  Map<double, double> get groupingFactors => _groupingFactors;

  @override
  Map<double, double> get soilThermalResistivityFactors => _soilThermalFactors;

  @override
  double get soilThermalResistivityReferenceKmW => 2.5;

  // Buried-run ground-temperature factors (IEC 60364-5-52 Table B.52.15).
  static final Map<double, double> _groundTempPvc = {
    10: 1.1, 15: 1.05, 20: 1.0, 25: 0.95, 30: 0.89, 35: 0.84, 40: 0.77,
    45: 0.71, 50: 0.63,
  };
  static final Map<double, double> _groundTempXlpe = {
    10: 1.07, 15: 1.04, 20: 1.0, 25: 0.96, 30: 0.93, 35: 0.89, 40: 0.85,
    45: 0.8, 50: 0.76,
  };
  // Depth-of-laying factors (m → factor), reference depth 0.5 m.
  static final Map<double, double> _depthFactors = {
    0.5: 1.0, 0.6: 0.98, 0.8: 0.96, 1.0: 0.95, 1.25: 0.94, 1.5: 0.93,
    1.75: 0.93, 2.0: 0.92,
  };

  @override
  Map<double, double> groundTempFactors(ConductorInsulation insulation) =>
      insulation == ConductorInsulation.xlpe ? _groundTempXlpe : _groundTempPvc;

  @override
  Map<double, double> get depthOfLayingFactors => _depthFactors;

  // ── Protection ────────────────────────────────────────────────────────────

  @override
  List<double> get mcbRatingsA =>
      const <double>[6, 10, 16, 20, 25, 32, 40, 50, 63];

  @override
  List<double> get mccbRatingsA => const <double>[
        80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
      ];

  @override
  List<double> get standardBreakerRatingsA =>
      <double>[...mcbRatingsA, ...mccbRatingsA];

  @override
  BreakerClass breakerClassFor(double ratingA) =>
      ratingA <= 63 ? BreakerClass.mcb : BreakerClass.mccb;

  @override
  BreakerCurve recommendedCurve({required bool lighting, required bool motor}) {
    if (lighting) return BreakerCurve.b;
    if (motor) return BreakerCurve.d;
    return BreakerCurve.c;
  }

  // ── Earthing / protective conductors (IEC 60364-5-54) ─────────────────────

  @override
  double peConductorSizeMm2(double phaseCsaMm2) {
    if (phaseCsaMm2 <= 16) return phaseCsaMm2;
    if (phaseCsaMm2 <= 35) return 16;
    final half = phaseCsaMm2 / 2;
    for (final s in standardSectionsMm2) {
      if (s >= half) return s;
    }
    return half;
  }

  @override
  double neutralConductorSizeMm2(double phaseCsaMm2, {bool reduced = false}) {
    if (!reduced || phaseCsaMm2 <= 16) return phaseCsaMm2;
    final target = phaseCsaMm2 / 2 > 16 ? phaseCsaMm2 / 2 : 16.0;
    for (final s in standardSectionsMm2) {
      if (s >= target) return s;
    }
    return phaseCsaMm2;
  }

  @override
  double mainEarthingConductorMm2(double supplyPeMm2) {
    final lower = supplyPeMm2 > 16 ? supplyPeMm2 : 16.0;
    return lower < 50 ? lower : 50.0;
  }

  @override
  double mainBondingConductorMm2(double supplyPeMm2) {
    final target = supplyPeMm2 / 2 > 6 ? supplyPeMm2 / 2 : 6.0;
    double std = 25;
    for (final s in standardSectionsMm2) {
      if (s >= target) {
        std = s;
        break;
      }
    }
    return std < 25 ? std : 25.0;
  }

  @override
  StandardValue<Resistance> get maxEarthResistance => const StandardValue(
        Resistance(5.0),
        unit: 'Ω',
        citation: '$_doc §3 — max earth-electrode resistance',
        verified: false,
        note: 'Target electrode resistance ≤ 5 Ω (PUIL practice). '
            'Confirm against site Wenner survey + the PUIL clause.',
      );

  // ── Busbar (IEC 61439-1 — engineering estimates) ──────────────────────────

  static const List<CopperBarSize> _copperBusbar = [
    CopperBarSize(12, 2, 24, Current(110)),
    CopperBarSize(15, 3, 45, Current(170)),
    CopperBarSize(20, 3, 60, Current(200)),
    CopperBarSize(25, 3, 75, Current(230)),
    CopperBarSize(20, 5, 100, Current(270)),
    CopperBarSize(25, 5, 125, Current(310)),
    CopperBarSize(30, 5, 150, Current(370)),
    CopperBarSize(40, 5, 200, Current(460)),
    CopperBarSize(50, 5, 250, Current(550)),
    CopperBarSize(50, 10, 500, Current(800)),
    CopperBarSize(60, 10, 600, Current(930)),
    CopperBarSize(80, 10, 800, Current(1180)),
    CopperBarSize(100, 10, 1000, Current(1430)),
  ];

  @override
  List<CopperBarSize> get copperBusbarTable => _copperBusbar;

  @override
  double get copperCurrentDensityAPerMm2 => 1.3;

  @override
  int get maxWaysPerBusbar => 12;

  @override
  Current get maxBusbarSectionCurrentA => _copperBusbar.last.ampacityA;

  // ── Busbar short-circuit withstand (IEC 61439-1 §9.3) ──────────────────────

  // One-second adiabatic short-time withstand density for a bare copper bar
  // (A/mm²). ~80 A/mm² is conservative within the commonly quoted 80–110 band:
  // the density that lifts copper from ~70 °C to the short-circuit limit
  // (~200–300 °C) in one second; Icw scales as 1/√t (IEC 61439-1 §9.3.2).
  @override
  double get busbarShortTimeDensityAPerMm2 => 80;

  // IEC 61439-1 Table 7: n = Ipk/Irms by prospective rms fault band (inclusive
  // upper bound): ≤5→1.5, ≤10→1.7, ≤20→2.0, ≤50→2.1, else 2.2. Higher faults are
  // fed from stiffer (more reactive) sources, so the asymmetry (n) rises.
  static const List<({double maxKa, double n})> _peakFactorTable = [
    (maxKa: 5, n: 1.5),
    (maxKa: 10, n: 1.7),
    (maxKa: 20, n: 2.0),
    (maxKa: 50, n: 2.1),
    (maxKa: double.infinity, n: 2.2),
  ];

  @override
  double busbarPeakFactor(double faultKa) {
    for (final band in _peakFactorTable) {
      if (faultKa <= band.maxKa) return band.n;
    }
    return 2.2; // unreachable — the last band is open-ended.
  }

  // ── Verify checklist (report surfaces these as still-unverified) ──────────

  @override
  List<StandardValue<Object?>> get verifyChecklist => <StandardValue<Object?>>[
        // Most safety-critical first: protective limits, then sizing data.
        maxVoltageDropGeneral,
        maxVoltageDropLighting,
        maxEarthResistance,
        continuousLoadFactor,
        const StandardValue<Object?>(
          'copper busbar continuous ratings (single bar, ~30 °C rise)',
          unit: 'table',
          citation: 'IEC 61439-1 — engineering estimate (not a PUIL clause)',
          verified: false,
          status: VerificationStatus.notAnSniClause,
          note: 'Approximate single-bar ratings (~1.3–1.6 A/mm²); a general '
              'engineering reference, not a PUIL/SNI table. Verify against the '
              'manufacturer / a type-tested assembly.',
        ),
        const StandardValue<Object?>(
          'busbar short-circuit withstand — 1 s copper short-time density '
              '(~80 A/mm²) + IEC 61439-1 Table 7 peak factor',
          unit: 'A/mm² + table',
          citation: 'IEC 61439-1 §9.3 / Table 7 — engineering estimate '
              '(not a PUIL clause)',
          verified: false,
          status: VerificationStatus.notAnSniClause,
          note: 'Adiabatic 1-second copper short-time withstand density '
              '(~80–110 A/mm² band; 80 conservative) and the Table 7 '
              'Ipk/Irms peak factors. Verify against a type-tested assembly '
              'Icw/Ipk declaration.',
        ),
        const StandardValue<Object?>(
          'cable ampacity (KHA) tables — Cu/PVC + Cu/XLPE × method B1/C/E/D',
          unit: 'table',
          citation: '$_doc / IEC 60364-5-52 — Supreme Cable (SUCACO) catalogue',
          verified: false,
          note: 'Transcribed from the Supreme NYY 0.6/1 kV catalogue '
              '(IEC/SNI 60502-1). Verify against the manufacturer datasheet '
              'and the PUIL ampacity table for the specific construction.',
        ),
        const StandardValue<Object?>(
          'ambient / grouping / soil-thermal derating factors',
          unit: 'table',
          citation: 'IEC 60364-5-52 Tables B.52.14 / B.52.17 / B.52.16',
          verified: false,
          note: 'IEC reference values; confirm against the IEC tables (and any '
              'PUIL-specific Indonesian adjustment).',
        ),
        nominalLineVoltage,
        nominalSinglePhaseVoltage,
        nominalPhaseVoltage,
      ].where((v) => v.isUnverified).toList();
}
