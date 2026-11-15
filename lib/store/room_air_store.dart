/// Backlog F-3 (2026-11-13) — ONE headline air-unit duty per room.
///
/// A room carries two figures for its unit: the room-air ESTIMATE
/// (`sizeRoomAir`: kind internal + an assumed 15 m run x 1.3 + terminal drops)
/// and, once ducts are drawn to a unit in the room, that system's SOLVED fan
/// duty (`supplyFanDutiesByRootProvider` / `exhaustFanDutiesByRootProvider`).
/// The Rooms inspector printed the estimate beside the drawn duty with nothing
/// telling them apart (tower AHU 304.10 vs 326.44 Pa). [roomAirHeadlineProvider]
/// resolves which ONE figure a room prints: the drawn-system duty whenever a
/// drawn system roots at the room's unit, else the estimate, labelled
/// "estimate (no ducts drawn)" only when NO drawn system reaches the room at
/// all. The equipment schedule (and so the calc report, which embeds it)
/// labels its room-air rows from the same basis. No calculation changes.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/equipment_schedule.dart'
    show FanDutyBasis;
import 'package:mechx_engine/sizing/fan.dart';

import 'annotation_store.dart';
import 'network_store.dart';
import 'sizing_store.dart';
import 'solve_store.dart';

/// The headline air-unit duty of one room.
@immutable
class RoomAirHeadline {
  /// The duty to print: the drawn system's solved duty when [drawn], else the
  /// room-air estimate.
  final FanDuty duty;

  /// The drawn unit the system roots at (an AHU / FCU, or an exhaust fan for
  /// an extract room) — null for an estimate.
  final String? unitId;

  /// Null ⇒ a drawn-system duty; else which estimate [duty] is.
  final FanDutyBasis? estimate;

  const RoomAirHeadline({
    required this.duty,
    this.unitId,
    this.estimate,
  });

  /// True when [duty] is a drawn-duct solve, not the room estimate.
  bool get drawn => estimate == null;
}

/// The units a room's air system is rooted at: an AHU / FCU for a conditioned
/// room, an exhaust fan for an extract room.
bool _isRoomAirUnit(NodeComponent? c, {required bool extract}) => extract
    ? c == NodeComponent.exhaustFan
    : c == NodeComponent.ahu || c == NodeComponent.fcu;

/// Backlog F-3 — per room id, the ONE air-unit duty the Rooms inspector prints
/// (and the basis the schedule labels its room rows with). A room the sheet
/// cannot size (no scale) is absent.
final roomAirHeadlineProvider = Provider<Map<String, RoomAirHeadline>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final rooms = ref.watch(roomAreasProvider);
  final roomSizing = ref.watch(roomSizingProvider);
  final supplyDuties = ref.watch(supplyFanDutiesByRootProvider);
  final exhaustDuties = ref.watch(exhaustFanDutiesByRootProvider);
  final sizedEdgeIds = ref.watch(sizingProvider).keys.toSet();
  final out = <String, RoomAirHeadline>{};
  for (final r in rooms) {
    final s = roomSizing[r.id];
    if (s == null) continue;
    final extract = s.extractOnly;
    final duties = extract ? exhaustDuties : supplyDuties;
    RoomAirHeadline? drawn;
    for (final n in net.nodes) {
      if (!_isRoomAirUnit(n.component, extract: extract)) continue;
      if (roomUnitOwnerId(n, rooms) != r.id) continue;
      final d = duties[n.id];
      if (d != null) {
        drawn = RoomAirHeadline(duty: d, unitId: n.id);
        break;
      }
    }
    out[r.id] = drawn ??
        RoomAirHeadline(
          duty: s.equipment,
          estimate: roomServedByDrawnAir(r, rooms, net, sizedEdgeIds,
                  extract: extract)
              ? FanDutyBasis.estimateRoomOnly
              : FanDutyBasis.estimateNoDucts,
        );
  }
  return out;
});
