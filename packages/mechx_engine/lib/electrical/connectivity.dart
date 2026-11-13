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
/// Backlog E-1 (2026-11-13) — the legitimacy test is now
/// [serviceEntrancePanelIds] (rules 1-3 above plus an explicit
/// [ElectricalPanel.serviceEntrance] flag), the SAME set the supply study
/// takes as its service roots.
///
/// Pure + read-only — never sizes. Deterministic: the result is sorted by panel
/// id.
List<ElectricalConnectivityDefect> electricalConnectivityDefects(
  ElectricalProject project,
) {
  final panels = project.panels;
  if (panels.length <= 1) return const [];
  final legit = serviceEntrancePanelIds(project);
  final defects = <ElectricalConnectivityDefect>[];
  for (final p in unfedPanelsOf(project)) {
    if (legit.contains(p.id)) continue;
    defects.add(ElectricalConnectivityDefect(
      panelId: p.id,
      kind: ElectricalConnectivityDefectKind.unfedPanel,
    ));
  }
  defects.sort((a, b) => a.panelId.compareTo(b.panelId));
  return defects;
}

/// The un-fed boards of [project] in list order: no circuit's
/// [ElectricalCircuit.feedsPanelId] references them (the connectivity
/// semantics `compute.dart`'s root candidates use). Pure.
List<ElectricalPanel> unfedPanelsOf(ElectricalProject project) {
  final fed = <String>{
    for (final p in project.panels)
      for (final c in p.circuits)
        if (c.feedsPanelId != null && c.feedsPanelId!.isNotEmpty)
          c.feedsPanelId!,
  };
  return [
    for (final p in project.panels)
      if (!fed.contains(p.id)) p,
  ];
}

/// Backlog E-1 (2026-11-13) — the ONE set of legitimate SERVICE ROOTS among
/// the un-fed boards, read by BOTH the connectivity judge
/// ([electricalConnectivityDefects]: every other un-fed board is
/// `unfed-panel`) and the supply study (`originPanelIdsOf`, `computeSystem`'s
/// service roots: the multi-root capacity judge, the per-line allocation, the
/// supply demand and connected load) — so one project is never judged two
/// ways. An un-fed board is a service root when:
///
///   0. it carries an explicit [ElectricalPanel.serviceEntrance] `true` (its
///      own utility meter — several separately metered entrances);
///   1. its flag is unset and it is the FIRST un-fed board (the MDP, listed
///      first) — the pre-E-1 default, so an old file judges unchanged;
///   2. it is a further LV main of a SECTIONED service (`serviceSections`:
///      [ElectricalProject.transformerUnits], else 2 on a
///      [ElectricalProject.dualTransformer]): while rules 0-1 gave fewer roots
///      than sections, the next board neither explicitly `false` nor a
///      genset-fed essential main is one (H2's "second main of a dual
///      service", generalised to N sections);
///   3. it is an [ElectricalPanel.essential] board while a generator source
///      is declared (the genset spine feeds an emergency main directly).
///
/// A declared solar / battery legitimises nothing (H2). A board flagged
/// `false` is never a root by rules 0-2; when NO board qualifies at all the
/// first un-fed board stays the root (a service needs one). Pure;
/// deterministic.
Set<String> serviceEntrancePanelIds(ElectricalProject project) {
  final unfed = unfedPanelsOf(project);
  if (unfed.isEmpty) return const {};
  final gensetDeclared = project.sources?.generator != null;
  final legit = <String>{};
  for (final p in unfed) {
    if (p.serviceEntrance == true) legit.add(p.id);
  }
  if (unfed.first.serviceEntrance == null) legit.add(unfed.first.id);
  // Rule 2 before rule 3: a section main is a TRANSFORMER main — counted
  // against the metered roots, never against a genset-fed essential main.
  final units = project.transformerUnits;
  final sections = units != null && units >= 1
      ? units
      : (project.dualTransformer ? 2 : 1);
  for (final p in unfed) {
    if (legit.length >= sections) break;
    if (legit.contains(p.id) || p.serviceEntrance == false) continue;
    if (p.essential && gensetDeclared) continue;
    legit.add(p.id);
  }
  if (gensetDeclared) {
    for (final p in unfed) {
      if (p.essential) legit.add(p.id);
    }
  }
  if (legit.isEmpty) legit.add(unfed.first.id);
  return legit;
}
