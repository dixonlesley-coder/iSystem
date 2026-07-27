/// Enclosure sizing + thermal estimate (A8c, post-processing pass): estimate an
/// assembly's W×H×D, sheet thickness, ventilation method, internal temperature
/// rise and IP recommendation from an already-computed [ElectricalPanelResult].
///
/// Ported from PanelMaker `engine/{enclosure,enclosureThermal}.ts` +
/// `standards/{enclosure,enclosureThermal}.ts`. The DIN-module count is
/// ESTIMATED from the panel result via [deviceModules] (the post-processing
/// pass does not see the PanelMaker per-device control-gear widths): an
/// MCB-family device (incomer or outgoing way) is narrow, sized by pole count
/// (1-phase = 1 module, 3-phase = 3) plus a 2-module RCD header on an
/// RCD-protected way; an MCCB-family device is a wide moulded-case frame,
/// sized by its rating band instead of its pole count. A reserved spare way
/// adds 1 module (a blank filler still needs its own rail space). Rows pack
/// 24 modules; the WIDTH follows the widest ACTUAL row (capped at one 24-module
/// row), not always a full row; height/depth follow the DIN geometry; sheet
/// thickness steps with the largest dimension; ventilation and temperature
/// rise follow IEC 60890 / IEC 61439-1 §9.3.2.
///
/// This is a NEW pure function constructing only the result type in this file.
/// First-pass engineering estimates — verify against the actual device losses,
/// the manufacturer's enclosure data and PUIL 2011.
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../standards/puil.dart' show BreakerClass;
import '../units.dart' show Power;
import 'panel_results.dart' show ElectricalPanelResult;

// ---------------------------------------------------------------------------
// Local standards constants (kept local to stay file-disjoint; folding into
// PuilProfile is a known follow-up). Tier: notAnSniClause engineering
// estimates / general practice.
// ---------------------------------------------------------------------------

/// Width of one DIN module / breaker pole (mm). A 3-pole device = 3 modules.
// VERIFY (notAnSniClause): standard 17.5–18 mm DIN module pitch.
const double dinModuleWidthMm = 18;

/// Vertical pitch between DIN-rail rows including wiring gutter (mm).
// VERIFY (notAnSniClause): typical row pitch with gutter.
const double dinRowPitchMm = 150;

/// Usable modules per DIN row before a new row is started.
// VERIFY (notAnSniClause): common 24-way DIN row.
const int modulesPerRow = 24;

/// Top/bottom margin for glands, bending space and clearances (mm).
// VERIFY (notAnSniClause): gland + bending-space allowance.
const double enclosureVerticalMarginMm = 200;

/// Side margin plus busbar chamber + wiring gutter allowance (mm).
// VERIFY (notAnSniClause): busbar chamber + gutter allowance.
const double enclosureSideMarginMm = 150;

/// Default enclosure depth for wall-mount panels (mm).
// VERIFY (notAnSniClause): typical wall-box depth.
const double enclosureDepthWallMm = 200;

/// Default enclosure depth when floor-standing / VFD gear is present (mm).
// VERIFY (notAnSniClause): typical floor-standing depth.
const double enclosureDepthFloorMm = 400;

/// Extra DIN modules added for an RCD device on a protected way (an RCCB/RCBO
/// header width).
// VERIFY (notAnSniClause): a 2-module RCD/RCBO header width.
const int rcdModules = 2;

/// Representative MCCB (moulded-case) frame widths (mm), banded by rating,
/// converted to 18 mm DIN module-equivalents in [deviceModules]. An MCCB is a
/// wide control-gear frame sized by its rating band — NOT by pole count like
/// an MCB — so `maxRatingA` is checked ascending and the first band the rating
/// fits is used.
// VERIFY (notAnSniClause): representative moulded-case frame widths (90/105/140
// mm at ≤125 A / ≤250 A / above), not a specific manufacturer's certified
// drawing.
const List<({double maxRatingA, double frameWidthMm})> mccbFrameBands = [
  (maxRatingA: 125, frameWidthMm: 90),
  (maxRatingA: 250, frameWidthMm: 105),
  (maxRatingA: double.infinity, frameWidthMm: 140),
];

/// Surface heat-transfer coefficient `k` for a painted sheet-steel enclosure
/// wall under natural convection + radiation (W per m² per K).
// VERIFY (notAnSniClause): IEC 60890 representative ≈ 5.5 W/m²K for painted steel.
const double enclosureHeatWPerM2K = 5.5;

/// Allowable internal air-temperature rise (K) above ambient before device
/// derating becomes necessary.
// VERIFY (notAnSniClause): practical 35 K cabinet-air ceiling (IEC 61439-1 §9.3.2).
const double maxInternalTempRiseK = 35;

/// Cooling method options.
enum Ventilation { natural, fanFilter, forced, heatExchanger }

extension VentilationLabel on Ventilation {
  String get label => switch (this) {
        Ventilation.natural => 'natural',
        Ventilation.fanFilter => 'fan-filter',
        Ventilation.forced => 'forced',
        Ventilation.heatExchanger => 'heat-exchanger',
      };
}

/// Cooling method recommended for a given internal heat dissipation (W).
// VERIFY (notAnSniClause): heat-load → cooling thresholds (50 / 200 / 500 W).
Ventilation ventilationFor(double totalHeatW) {
  if (totalHeatW < 50) return Ventilation.natural;
  if (totalHeatW < 200) return Ventilation.fanFilter;
  if (totalHeatW < 500) return Ventilation.forced;
  return Ventilation.heatExchanger;
}

/// Sheet-metal body thickness (mm) as a function of the largest dimension.
// VERIFY (notAnSniClause): gauge-vs-size rule of thumb.
double sheetThicknessMm(double largestDimensionMm) {
  if (largestDimensionMm <= 600) return 1.2;
  if (largestDimensionMm <= 1000) return 1.5;
  if (largestDimensionMm <= 1600) return 2.0;
  return 2.5;
}

/// Recommended ingress-protection code + rationale for the default indoor
/// service environment (IEC 60529).
// VERIFY (notAnSniClause): IP recommendation library (indoor default).
({String code, String note}) recommendedIp() => (
      code: 'IP41',
      note: 'Indoor clean/dry area: IP31 (drip) to IP41 — keeps fingers and '
          'falling dirt out.',
    );

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// Round [v] up to the next multiple of [step].
double _roundUpTo(double v, double step) => (v / step).ceil() * step;

/// Round [v] to [dp] decimal places.
double _round(double v, [int dp = 1]) {
  final f = math.pow(10, dp);
  return (v * f).round() / f;
}

/// Effective heat-dissipating surface area (m²) of a rectangular wall-mounted
/// enclosure — five of six faces (the back is against the wall). IEC 60890.
double _effectiveAreaM2(double wMm, double hMm, double dMm) {
  final w = math.max(0, wMm) / 1000;
  final h = math.max(0, hMm) / 1000;
  final d = math.max(0, dMm) / 1000;
  final front = w * h;
  final top = w * d;
  final bottom = w * d;
  final left = h * d;
  final right = h * d;
  // Wall-mount: the back face is obstructed and excluded.
  return front + top + bottom + left + right;
}

/// Estimated DIN-module width of one outgoing/incoming device.
///
/// MCB-family devices (and anything not identified as MCCB) are narrow,
/// modelled by pole count (1-phase = 1 module … 3-phase = 3; an incomer's own
/// pole count for an incomer) plus a 2-module RCD/RCBO header when the way is
/// RCD-protected — today's behaviour. MCCB-family devices are wide
/// moulded-case frames: their width comes from their rating band
/// ([mccbFrameBands]), converted to 18 mm module-equivalents and rounded up —
/// their pole count does not drive the width. `deviceClass` is matched
/// case-insensitively against `'MCCB'`; anything else (including a null/empty
/// string) is treated as the narrow MCB-like default. A null/omitted
/// `ratingA` for an MCCB falls back to the smallest (≤125 A) frame band.
int deviceModules({
  required String deviceClass,
  required int poles,
  double? ratingA,
  bool rcdRequired = false,
}) {
  if (deviceClass.toUpperCase() == 'MCCB') {
    final rating = ratingA ?? 0;
    for (final band in mccbFrameBands) {
      if (rating <= band.maxRatingA) {
        return (band.frameWidthMm / dinModuleWidthMm).ceil();
      }
    }
    return (mccbFrameBands.last.frameWidthMm / dinModuleWidthMm).ceil();
  }
  return poles + (rcdRequired ? rcdModules : 0);
}

/// Map a breaker's [BreakerClass] to the catalogue-style label ('MCB'/'MCCB')
/// [deviceModules] matches against — mirrors the schedule-label convention in
/// `report/electrical_sld_drawing.dart`'s `_classCode` / `bom.dart`'s
/// `_classStr` (kept local rather than shared to stay file-disjoint).
String _classCode(BreakerClass c) => c == BreakerClass.mccb ? 'MCCB' : 'MCB';

/// Estimate the total DIN-module count for a panel result.
///
/// Post-processing estimate (PanelMaker counts real per-device control-gear
/// widths; this pass only sees the result): [deviceModules] applied to the
/// incomer (poles = the incomer's own pole count) + each outgoing way (poles =
/// 3 for a three-phase way, else 1; its RCD status carried through) + 1
/// module per reserved spare way ([ElectricalPanelResult.spareWaysReserved]
/// — a spare way still needs its own blank filler / reserved rail space).
int estimatePanelModules(ElectricalPanelResult panel) {
  final incomer = panel.incomer;
  var modules = deviceModules(
    deviceClass: _classCode(incomer.breaker.deviceClass),
    poles: incomer.poles,
    ratingA: incomer.breaker.ratingA.amperes,
  );
  for (final c in panel.circuits) {
    modules += deviceModules(
      deviceClass: _classCode(c.breaker.deviceClass),
      poles: c.threePhase ? 3 : 1,
      ratingA: c.breaker.ratingA.amperes,
      rcdRequired: c.rcd.required,
    );
  }
  modules += panel.spareWaysReserved;
  return math.max(1, modules);
}

// ---------------------------------------------------------------------------
// Result type (this file's own constructor).
// ---------------------------------------------------------------------------

/// Estimated enclosure geometry, sheet, ventilation and thermal verification.
class EnclosureResult {
  final double widthMm;
  final double heightMm;
  final double depthMm;

  /// Sheet-metal body thickness (mm).
  final double sheetMm;

  /// Estimated total DIN modules of mounted gear.
  final int modules;

  /// DIN-rail rows.
  final int rows;

  /// Recommended cooling method.
  final Ventilation ventilation;

  /// Estimated internal air-temperature rise over ambient (K).
  final double tempRiseK;

  /// True when the rise is within [maxInternalTempRiseK].
  final bool withinTempLimit;

  /// Recommended ingress-protection code (IEC 60529).
  final String ip;

  /// Honesty surface: which constants are unverified engineering estimates.
  final List<String> verifyItems;

  const EnclosureResult({
    required this.widthMm,
    required this.heightMm,
    required this.depthMm,
    required this.sheetMm,
    required this.modules,
    required this.rows,
    required this.ventilation,
    required this.tempRiseK,
    required this.withinTempLimit,
    required this.ip,
    required this.verifyItems,
  });
}

/// Estimate the enclosure for a panel result.
///
/// The DIN-module count is estimated from the result via
/// [estimatePanelModules]. Geometry:
///   rows         = ceil(modules / 24)
///   widthModules = min(modules, 24)      (the widest ACTUAL row — capped at
///                                          one 24-way row, so a small board
///                                          isn't sized for a full row it
///                                          doesn't have)
///   width        = roundUp(widthModules·18 + 2·150, 50)
///   height       = roundUp(rows·150 + 200, 50)
///   depth        = hasFloorGear ? 400 : 200
/// Sheet thickness steps with the largest dimension; ventilation from [heat];
/// the IEC 60890 power-balance temperature rise = heat / (A_eff · k) is checked
/// against [maxInternalTempRiseK].
EnclosureResult estimateEnclosure(
  ElectricalPanelResult panel, {
  Power heat = const Power(0),
  bool hasFloorGear = false,
}) {
  final modules = estimatePanelModules(panel);
  final rows = math.max(1, (modules / modulesPerRow).ceil());
  final widthModules = math.min(modules, modulesPerRow);

  final widthMm = _roundUpTo(
    widthModules * dinModuleWidthMm + 2 * enclosureSideMarginMm,
    50,
  );
  final heightMm = _roundUpTo(rows * dinRowPitchMm + enclosureVerticalMarginMm, 50);
  final depthMm = hasFloorGear ? enclosureDepthFloorMm : enclosureDepthWallMm;
  final largest = [widthMm, heightMm, depthMm].reduce(math.max);

  final heatW = math.max(0.0, heat.watts);
  final area = _effectiveAreaM2(widthMm, heightMm, depthMm);
  final tempRiseK = area > 0
      ? heatW / (enclosureHeatWPerM2K * area)
      : double.infinity;

  return EnclosureResult(
    widthMm: widthMm,
    heightMm: heightMm,
    depthMm: depthMm,
    sheetMm: sheetThicknessMm(largest),
    modules: modules,
    rows: rows,
    ventilation: ventilationFor(heatW),
    tempRiseK: tempRiseK.isFinite ? _round(tempRiseK, 1) : tempRiseK,
    withinTempLimit: tempRiseK <= maxInternalTempRiseK,
    ip: recommendedIp().code,
    verifyItems: const [
      'DIN-module count is ESTIMATED from breaker poles/MCCB frame width + RCD '
          'modules + reserved spare ways — verify against the actual mounted '
          'device widths.',
      'Enclosure geometry (DIN pitch, margins, depth) — verify against the '
          'enclosure manufacturer data.',
      'Sheet thickness, ventilation thresholds + IEC 60890 temp-rise (5.5 W/m²K, '
          '35 K) — verify against measured device losses + PUIL 2011.',
    ],
  );
}
