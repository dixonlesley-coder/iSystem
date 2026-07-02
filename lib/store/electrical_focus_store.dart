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

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The pending panel-id focus request from the Review → Electrical jump. Null
/// when there is nothing to focus.
final electricalFocusProvider =
    NotifierProvider<ElectricalFocusController, String?>(
  ElectricalFocusController.new,
);

/// Holds the single pending [request] until the electrical workspace consumes
/// and [clear]s it. Mirrors the house Notifier controller style.
class ElectricalFocusController extends Notifier<String?> {
  @override
  String? build() => null;

  /// Request that the electrical workspace bring [panelId] into focus.
  void request(String panelId) => state = panelId;

  /// Clear the pending focus request (called once the view has consumed it).
  void clear() => state = null;
}
