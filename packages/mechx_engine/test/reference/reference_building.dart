// Reference buildings — the shared value class every fixed reference building
// (1 house, 2-5 to follow) is returned as. Pure Dart (no Flutter import), so
// the engine suite (`dart test`) and the app suite (`flutter test`, importing
// this file by relative path) build the SAME inputs.
library;

import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show Occupancy;

/// One drawing sheet of a reference building: its id (the key of
/// [ReferenceBuilding.calibrations] and of every node's `sheetId`), a display
/// name and the building floor it is mapped to.
class ReferenceSheet {
  final String id;
  final String name;
  final int floorIndex;

  const ReferenceSheet(
      {required this.id, required this.name, required this.floorIndex});
}

/// A complete reference building: the floor stack, the drawing sheets with
/// their scale calibrations, the mechanical network and the electrical
/// project — everything the engine sizers and the app stores take as input.
class ReferenceBuilding {
  final String name;
  final BuildingLevels building;
  final MountingHeights mounting;
  final List<ReferenceSheet> sheets;
  final Map<String, ScaleCalibration> calibrations;
  final Network network;
  final ElectricalProject electrical;

  /// The water-supply occupancy class the building is designed on (selects
  /// the UBAP column).
  final Occupancy occupancy;

  /// Backlog W-4 (2026-11-14) — the building population (persons) the daily
  /// water demand is computed on (the app's Building-page input). Each
  /// fixture states its basis.
  final int? population;

  const ReferenceBuilding({
    required this.name,
    required this.building,
    this.mounting = const MountingHeights(),
    required this.sheets,
    required this.calibrations,
    required this.network,
    required this.electrical,
    required this.occupancy,
    this.population,
  });
}
