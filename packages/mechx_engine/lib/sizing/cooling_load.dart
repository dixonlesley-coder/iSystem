/// Room air-conditioning cooling-load estimate — BTU/h, kW and **PK**.
///
/// When an AC indoor unit is placed in a drawn room, the app needs the room's
/// cooling requirement to recommend a unit size. This module gives a first-pass
/// estimate by the **area-density rule** common in Indonesian practice:
///
///   load (BTU/h) = floor area (m²) × per-m² density (by room use) × ceiling
///                  correction (ceiling ÷ a 3 m reference)
///
/// then maps it to **PK** (the capacity unit AC is quoted in here) and the
/// nearest standard unit. This is an orchestration helper, not a CLTD/heat-gain
/// solve — the density (from the ventilation profile) and the PK convention are
/// general practice, NOT a verbatim SNI clause (`// VERIFY`).
///
/// Pure Dart, zero Flutter imports.
library;

import '../units.dart';

/// 1 watt of cooling = 3.412141633 BTU/h.
const double kBtuPerHrPerWatt = 3.412141633;

/// AC capacity in Indonesia is quoted in **PK** (paardenkracht). By common
/// convention 1 PK ≈ 9000 BTU/h of COOLING (not a horsepower of input power).
/// `// VERIFY` against the chosen product's rated capacity.
const double kBtuPerHrPerPk = 9000.0;

double wattsToBtuPerHr(double watts) => watts * kBtuPerHrPerWatt;
double btuPerHrToWatts(double btuPerHr) => btuPerHr / kBtuPerHrPerWatt;
double btuPerHrToPk(double btuPerHr) => btuPerHr / kBtuPerHrPerPk;
double pkToBtuPerHr(double pk) => pk * kBtuPerHrPerPk;

/// Estimated sensible cooling load (BTU/h) for a room by the area-density rule.
/// [densityBtuPerHrPerM2] is supplied by the caller from the ventilation
/// profile; the ceiling correction scales linearly from [referenceCeiling].
double coolingLoadBtuPerHr({
  required Area floorArea,
  required Length ceilingHeight,
  required double densityBtuPerHrPerM2,
  Length referenceCeiling = const Length(3.0),
}) {
  assert(floorArea.squareMeters > 0, 'floorArea must be positive');
  assert(ceilingHeight.meters > 0, 'ceilingHeight must be positive');
  assert(densityBtuPerHrPerM2 > 0, 'density must be positive');
  final heightFactor = ceilingHeight.meters / referenceCeiling.meters;
  return floorArea.squareMeters * densityBtuPerHrPerM2 * heightFactor;
}

/// Standard market AC nominal capacities: PK → rated BTU/h. Representative
/// split/cassette/ducted sizes, ascending. `// VERIFY` against the product range.
const List<(double pk, double btuPerHr)> standardAcCapacities =
    <(double, double)>[
  (0.5, 5000),
  (0.75, 7000),
  (1.0, 9000),
  (1.5, 12000),
  (2.0, 18000),
  (2.5, 24000),
  (3.0, 27000),
];

/// A recommended single AC unit for a cooling load.
final class AcSelection {
  /// Capacity in PK.
  final double pk;

  /// Rated cooling capacity of that PK size (BTU/h).
  final double nominalBtuPerHr;

  /// True when the load exceeds even the largest standard size — the caller
  /// should split it across multiple units.
  final bool exceedsRange;

  const AcSelection({
    required this.pk,
    required this.nominalBtuPerHr,
    required this.exceedsRange,
  });
}

/// Smallest standard AC whose nominal capacity ≥ [requiredBtuPerHr]. If the load
/// exceeds the largest size, returns the largest with [AcSelection.exceedsRange]
/// set (split across multiple units).
AcSelection selectAc(double requiredBtuPerHr) {
  for (final (pk, btu) in standardAcCapacities) {
    if (btu >= requiredBtuPerHr) {
      return AcSelection(pk: pk, nominalBtuPerHr: btu, exceedsRange: false);
    }
  }
  final last = standardAcCapacities.last;
  return AcSelection(
      pk: last.$1, nominalBtuPerHr: last.$2, exceedsRange: true);
}

/// Full cooling-load result for a room: the requirement plus the recommended AC.
final class CoolingLoad {
  /// Estimated cooling load (BTU/h).
  final double btuPerHr;

  /// The same load in watts (thermal).
  final double watts;

  /// The load expressed in PK (= btuPerHr ÷ 9000) — the raw requirement.
  final double pk;

  /// Nearest standard AC size at or above the load.
  final AcSelection recommended;

  const CoolingLoad({
    required this.btuPerHr,
    required this.watts,
    required this.pk,
    required this.recommended,
  });
}

/// Estimate the cooling load + recommend an AC for a room.
CoolingLoad estimateCoolingLoad({
  required Area floorArea,
  required Length ceilingHeight,
  required double densityBtuPerHrPerM2,
  Length referenceCeiling = const Length(3.0),
}) {
  final btu = coolingLoadBtuPerHr(
    floorArea: floorArea,
    ceilingHeight: ceilingHeight,
    densityBtuPerHrPerM2: densityBtuPerHrPerM2,
    referenceCeiling: referenceCeiling,
  );
  return CoolingLoad(
    btuPerHr: btu,
    watts: btuPerHrToWatts(btu),
    pk: btuPerHrToPk(btu),
    recommended: selectAc(btu),
  );
}
