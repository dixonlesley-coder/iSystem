import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';

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
final standpipeDesignProvider = Provider<FireStandpipeDesign>((ref) {
  final building = ref.watch(projectControllerProvider).building;
  return designStandpipe(risers: 1, buildingHeight: building.totalHeight);
});
