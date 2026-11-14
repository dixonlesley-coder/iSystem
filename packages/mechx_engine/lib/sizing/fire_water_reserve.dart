/// Backlog A-2 (2026-11-13, reference office backlog b) — the fire-water
/// RESERVE a fire tank must hold: the governing fire system's rated demand
/// flow for the required duration,
///
///     V = Q_rated x t
///
/// t = the longest duration the system's drawn terminals call for: a
/// standpipe (hose outlets) [kFireReserveStandpipeMin], a sprinkler system its
/// hazard class ([fireReserveSprinklerDurationMin]). The rated flow is the
/// pump's RATED point (the larger of the standpipe and sprinkler flows on a
/// combined system — the flow the pump is sized to deliver). Every duration is
/// `// VERIFY` against SNI 03-1745 / SNI 03-3989 (NFPA 14 / NFPA 13 values)
/// and surfaced in `SniProfile.verifyChecklist`. Pure; JUDGE-ONLY consumers
/// never resize a tank or fabricate a capacity.
library;

import '../units.dart';
import 'fire_sprinkler.dart' show FireHazardClass;

/// Standpipe (hose) supply duration, minutes. NFPA 14 9.2 (30 min);
/// `// VERIFY notAnSniClause` against SNI 03-1745.
const double kFireReserveStandpipeMin = 30;

/// Sprinkler supply duration for LIGHT hazard, minutes. NFPA 13 Table
/// 19.3.3.1.2 lower bound (30 min); `// VERIFY notAnSniClause` against
/// SNI 03-3989.
const double kFireReserveLightHazardMin = 30;

/// Sprinkler supply duration for ORDINARY hazard (groups 1-2), minutes.
/// NFPA 13 lower bound (60 min); `// VERIFY notAnSniClause` against
/// SNI 03-3989.
const double kFireReserveOrdinaryHazardMin = 60;

/// Sprinkler supply duration for EXTRA hazard, minutes. NFPA 13 lower bound
/// (90 min); `// VERIFY notAnSniClause` against SNI 03-3989.
const double kFireReserveExtraHazardMin = 90;

/// The sprinkler supply duration (minutes) of [hazard].
double fireReserveSprinklerDurationMin(FireHazardClass hazard) =>
    switch (hazard) {
      FireHazardClass.lightHazard => kFireReserveLightHazardMin,
      FireHazardClass.ordinaryHazard1 ||
      FireHazardClass.ordinaryHazard2 =>
        kFireReserveOrdinaryHazardMin,
      _ => kFireReserveExtraHazardMin,
    };

/// The required fire-water reserve of one fire system.
class FireWaterReserve {
  /// The rated demand flow the reserve is reckoned on.
  final FlowRate ratedFlow;

  /// The required duration (minutes).
  final double durationMin;

  const FireWaterReserve({required this.ratedFlow, required this.durationMin});

  /// Required volume, litres: Q (L/s) x t (s).
  double get volumeLitres => ratedFlow.inLitersPerSecond * durationMin * 60;
}

/// The reserve of a fire system rated at [ratedFlow] whose drawn terminals
/// include hose outlets ([standpipe]) and / or sprinkler heads
/// ([sprinkler], at [hazard]): the longest applicable duration. Null when
/// neither terminal kind is drawn or the flow is not positive.
FireWaterReserve? fireWaterReserve({
  required FlowRate ratedFlow,
  required bool standpipe,
  required bool sprinkler,
  required FireHazardClass hazard,
}) {
  if (ratedFlow.cubicMetersPerSecond <= 0 || (!standpipe && !sprinkler)) {
    return null;
  }
  var t = 0.0;
  if (standpipe && kFireReserveStandpipeMin > t) t = kFireReserveStandpipeMin;
  if (sprinkler) {
    final s = fireReserveSprinklerDurationMin(hazard);
    if (s > t) t = s;
  }
  return FireWaterReserve(ratedFlow: ratedFlow, durationMin: t);
}

/// The judge's verdict on one fire tank.
enum FireTankVerdict {
  /// Capacity set and at least the requirement.
  ok,

  /// Capacity set below the requirement (warning).
  undersized,

  /// No capacity entered (info stating the requirement).
  unset,
}

/// JUDGE-ONLY: [capacityLitres] (the tank node's own, null when unset)
/// against [requiredLitres]. Never fabricates a capacity.
FireTankVerdict judgeFireTank({
  required double? capacityLitres,
  required double requiredLitres,
}) {
  if (capacityLitres == null) return FireTankVerdict.unset;
  return capacityLitres + 1e-9 < requiredLitres
      ? FireTankVerdict.undersized
      : FireTankVerdict.ok;
}
