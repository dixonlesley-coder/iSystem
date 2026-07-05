/// Pure-Dart electrical connectivity DETECTOR (zero Flutter imports, runnable
/// under `dart test`).
///
/// This is a READ-ONLY validation helper alongside `compute.dart` — it changes
/// NO sizing. It mirrors the parent/feeder map + root identification that
/// `compute.dart` builds (a panel referenced by some circuit's `feedsPanelId`
/// is "fed by a feeder"; the panels NOT referenced are root candidates), then
/// flags a distribution board that is neither the root nor fed by any feeder —
/// a panel wired to nothing upstream.
library;

import 'model.dart';

/// What kind of electrical connectivity problem a panel has.
enum ElectricalConnectivityDefectKind {
  /// The panel is NOT the root AND no circuit's `feedsPanelId` references it, so
  /// it has no upstream feeder — a floating, unconnected board.
  unfedPanel,
}

/// One detected electrical connectivity defect: the offending [panelId] and the
/// [kind].
class ElectricalConnectivityDefect {
  final String panelId;
  final ElectricalConnectivityDefectKind kind;

  const ElectricalConnectivityDefect({
    required this.panelId,
    required this.kind,
  });

  /// True for the "no upstream feeder" defect.
  bool get isUnfedPanel =>
      kind == ElectricalConnectivityDefectKind.unfedPanel;
}

/// Detect every unconnected sub-panel in [project].
///
/// Root identification mirrors `compute.dart`: a panel referenced by some
/// circuit's [ElectricalCircuit.feedsPanelId] is "fed by a feeder"; the panels
/// NOT referenced are root candidates (`panels.where((p) => !parentOf
/// .containsKey(p.id))`). In a well-formed project exactly one such panel
/// exists — the main board fed by the incomer/source — so THE root is taken as
/// the first unfed panel in project order (the MDP is listed first) and is never
/// a defect. Any FURTHER unfed panel is a floating board flagged
/// [ElectricalConnectivityDefectKind.unfedPanel].
///
/// With a single panel there is never a defect (it is the root). A degenerate
/// project where every panel is fed (a feeder cycle with no root — a distinct
/// defect `compute.dart` warns on) yields no unfed-panel defect here.
///
/// Pure + read-only — never sizes. Deterministic: the result is sorted by panel
/// id.
List<ElectricalConnectivityDefect> electricalConnectivityDefects(
  ElectricalProject project,
) {
  final panels = project.panels;
  if (panels.length <= 1) return const [];

  // Panels referenced by some circuit's feedsPanelId ("fed by a feeder").
  final fed = <String>{};
  for (final p in panels) {
    for (final c in p.circuits) {
      final target = c.feedsPanelId;
      if (target != null) fed.add(target);
    }
  }

  // THE root = the first panel not fed by any feeder (mirrors compute.dart's
  // root candidates; a well-formed project has exactly one). Never a defect.
  String? root;
  for (final p in panels) {
    if (!fed.contains(p.id)) {
      root = p.id;
      break;
    }
  }

  final defects = <ElectricalConnectivityDefect>[];
  for (final p in panels) {
    if (p.id == root) continue; // the root is fed by the incomer/source
    if (fed.contains(p.id)) continue; // fed by a feeder → connected
    defects.add(ElectricalConnectivityDefect(
      panelId: p.id,
      kind: ElectricalConnectivityDefectKind.unfedPanel,
    ));
  }

  defects.sort((a, b) => a.panelId.compareTo(b.panelId));
  return defects;
}
