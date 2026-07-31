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
/// .containsKey(p.id))`). `compute.dart` allows MULTIPLE roots (a real
/// dual-source design — a normal MDP plus a genset/emergency MDP, each fed by
/// the source spine), so an extra un-fed board is not automatically a defect.
///
/// H2 — the legitimacy test is PER PANEL, not project-wide. An un-fed board is
/// legitimate only when it is:
///
///   1. THE primary root (the first un-fed panel — the MDP, listed first);
///   2. the SECOND LV main of a declared [ElectricalProject.dualTransformer]
///      service — two mains are expected, so exactly ONE further root is
///      allowed (a third is still a defect); or
///   3. an [ElectricalPanel.essential] board WHEN a generator source is
///      declared (`sources.generator`) — the genset spine feeds an emergency
///      main directly, not through a feeder.
///
/// Everything else warns exactly as the single-supply case does. In particular a
/// declared SOLAR or BATTERY source legitimises NOTHING: both attach to the LV
/// bus of an existing board (see `_emitPvArray` / `_emitBattery` on the source
/// spine), they never feed a floating distribution board. Before H2 the mere
/// presence of ANY `sources` object (a rooftop PV, a battery) switched the whole
/// check off project-wide, so a genuinely floating sub-panel went unreported.
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

  // A declared genset is what legitimises an essential (emergency) main sitting
  // outside the feeder tree. Solar / battery deliberately do NOT count.
  final gensetDeclared = project.sources?.generator != null;

  // The un-fed boards, in list order. The FIRST is THE primary root (mirrors
  // compute.dart's root candidates; the MDP is listed first) and is never a
  // defect.
  final unfed = [
    for (final p in panels)
      if (!fed.contains(p.id)) p,
  ];
  if (unfed.isEmpty) return const [];

  // Pass 1 — every essential board with a declared genset is a legitimate
  // source-fed root (rule 3), independent of position in the list.
  final legit = <String>{unfed.first.id};
  if (gensetDeclared) {
    for (final p in unfed) {
      if (p.essential) legit.add(p.id);
    }
  }

  // Pass 2 — a dual-transformer service expects TWO LV mains, so it legitimises
  // exactly ONE further root beyond the primary (never "any number of roots"):
  // the allowance is spent on the first board not already legitimised above, so
  // a THIRD floating main is still reported. A genset-backed essential main is
  // counted separately under rule 3 — it is a different supply, not the second
  // transformer.
  if (project.dualTransformer) {
    for (final p in unfed) {
      if (legit.contains(p.id)) continue;
      legit.add(p.id);
      break;
    }
  }

  final defects = <ElectricalConnectivityDefect>[];
  for (final p in unfed) {
    if (legit.contains(p.id)) continue;
    defects.add(ElectricalConnectivityDefect(
      panelId: p.id,
      kind: ElectricalConnectivityDefectKind.unfedPanel,
    ));
  }

  defects.sort((a, b) => a.panelId.compareTo(b.panelId));
  return defects;
}
