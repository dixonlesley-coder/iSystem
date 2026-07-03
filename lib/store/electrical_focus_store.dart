/// The Review → Electrical "focus this panel" jump seam.
///
/// The Review hub's unified Design Issues list (see `design_issues_store.dart` /
/// `issues_card.dart`) can carry an ELECTRICAL issue located by panel id. When
/// the engineer taps such a row, the IssuesCard switches to the Electrical
/// workspace and hands the panel id here; the electrical single-line then reads
/// this provider, frames that panel, and clears the request.
///
/// This store owns ONLY the request/clear seam — a tiny, single-slot pending
/// focus id (null at rest). The ElectricalView consumption hook (listen →
/// frame → [clear]) is wired centrally afterward; keeping the request side here
/// lets the Review hub hand a panel id across the view switch without
/// ElectricalView depending on the Review hub (or vice-versa).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A pending Review → Electrical focus request: the [panelId] to frame plus,
/// when the issue pinpoints one, the specific [circuitId] (way) to select (H7).
/// The circuit is optional — a panel-level issue (no way) leaves it null and the
/// view just frames the board.
@immutable
class ElectricalFocusRequest {
  final String panelId;
  final String? circuitId;

  const ElectricalFocusRequest(this.panelId, {this.circuitId});

  @override
  bool operator ==(Object other) =>
      other is ElectricalFocusRequest &&
      other.panelId == panelId &&
      other.circuitId == circuitId;

  @override
  int get hashCode => Object.hash(panelId, circuitId);
}

/// The pending focus request from the Review → Electrical jump. Null when there
/// is nothing to focus.
final electricalFocusProvider =
    NotifierProvider<ElectricalFocusController, ElectricalFocusRequest?>(
  ElectricalFocusController.new,
);

/// Holds the single pending [request] until the electrical workspace consumes
/// and [clear]s it. Mirrors the house Notifier controller style.
class ElectricalFocusController extends Notifier<ElectricalFocusRequest?> {
  @override
  ElectricalFocusRequest? build() => null;

  /// Request that the electrical workspace bring [panelId] into focus, and
  /// (when known) select the specific [circuitId] way (H7).
  void request(String panelId, {String? circuitId}) =>
      state = ElectricalFocusRequest(panelId, circuitId: circuitId);

  /// Clear the pending focus request (called once the view has consumed it).
  void clear() => state = null;
}
