import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart' show Power;

import 'project_store.dart';

/// Selected sprinkler hazard class (drives the sprinkler design).
final fireHazardProvider =
    NotifierProvider<FireHazardController, FireHazardClass>(
  FireHazardController.new,
);

class FireHazardController extends Notifier<FireHazardClass> {
  @override
  FireHazardClass build() => FireHazardClass.ordinaryHazard1;

  void set(FireHazardClass hazard) => state = hazard;
}

/// Sprinkler system design for the selected hazard class (SNI 03-3989-2000
/// density/area values; coverage defaults to the SNI per-class maximum).
final sprinklerDesignProvider = Provider<SprinklerDesign>(
  (ref) => designSprinklerSystem(hazard: ref.watch(fireHazardProvider)),
);

/// Standpipe + fire-pump design for the building height (single Class I riser
/// default; SNI 03-1745-2000 flow + residual pressure).
///
/// The static lift is pump datum (lowest floor) → the TOPMOST HOSE OUTLET on
/// the top floor ([standpipeStaticLift]), per `designStandpipe`'s contract —
/// not the roof (`building.totalHeight`), which overstated it by the top
/// floor's height less the outlet height.
final standpipeDesignProvider = Provider<FireStandpipeDesign>((ref) {
  final building = ref.watch(projectControllerProvider).building;
  return designStandpipe(
      risers: 1, buildingHeight: standpipeStaticLift(building));
});

/// Nominal per-head K-factor for the sprinkler remote-area check (L/min/bar^0.5).
/// Defaults to a standard 15 mm pendent head (K = 80). // VERIFY — head-model
/// dependent; see [kDefaultPendentKFactor].
final firePerHeadKFactorProvider =
    NotifierProvider<FirePerHeadKFactorController, double>(
  FirePerHeadKFactorController.new,
);

class FirePerHeadKFactorController extends Notifier<double> {
  @override
  double build() => kDefaultPendentKFactor;

  void set(double k) => state = k;
}

/// Remote-area hydraulic check for the sprinkler design — K-factor flow at the
/// most-remote head, branch-line friction, and the minimum-operating-pressure
/// verdict (orchestration over `hydraulics.dart`).
final sprinklerRemoteAreaProvider = Provider<SprinklerRemoteAreaResult>((ref) {
  final design = ref.watch(sprinklerDesignProvider);
  final k = ref.watch(firePerHeadKFactorProvider);
  return remoteAreaHydraulics(design: design, kFactor: k);
});

/// NFPA 20 fire-pump rating-curve check for the standpipe pump — churn / rated /
/// overload duty points, motor selection on the governing point, jockey-pump
/// recommendation, and duty/standby designation.
final firePumpRatingProvider = Provider<FirePumpRatingResult>((ref) {
  final st = ref.watch(standpipeDesignProvider);
  return checkFirePumpRating(
    ratedFlow: st.requiredFlow,
    ratedHead: st.pumpHead,
  );
});

/// The ONE fire-pump duty every downstream surface uses — the equipment
/// schedule's FP-01 row AND the MEP→electrical auto-feed. The hydraulic duty is
/// the standpipe rated point ([sizePump] on the required flow / pump head), but
/// the MOTOR is the NFPA 20 selection from [firePumpRatingProvider] (the
/// smallest standard frame covering the OVERLOAD shaft power) — so the schedule,
/// the Fire ResultCard's motor and the board-schedule circuit all name the same
/// kW. Null when no standpipe flow is required.
final firePumpDutyProvider = Provider<PumpDuty?>((ref) {
  final st = ref.watch(standpipeDesignProvider);
  if (st.requiredFlow.cubicMetersPerSecond <= 0) return null;
  final rating = ref.watch(firePumpRatingProvider);
  final base = sizePump(flow: st.requiredFlow, head: st.pumpHead);
  // The motor input at the GOVERNING curve point — the larger of the rated and
  // NFPA 20 overload (150 % flow) shaft powers, the point [selectedMotor] was
  // chosen to carry — so input power and motor frame describe one duty (the
  // rated-point input alone sits below the overload draw). Same motor
  // efficiency as the rated point (input / shaft).
  final motorEff = base.shaftPower.watts > 0
      ? base.motorInputPower.watts / base.shaftPower.watts
      : 1.0;
  final governingShaft =
      rating.overload.shaftPower.watts > base.shaftPower.watts
          ? rating.overload.shaftPower.watts
          : base.shaftPower.watts;
  return PumpDuty(
    flow: base.flow,
    head: base.head,
    hydraulicPower: base.hydraulicPower,
    shaftPower: base.shaftPower,
    motorInputPower: Power(governingShaft * motorEff),
    selectedMotor: rating.selectedMotor,
    motorOversized: rating.oversized,
  );
});
