/// Unified "Design Issues" aggregation — one actionable list of every design
/// warning the app already computes, collected READ-ONLY from existing sources
/// and surfaced in the Review hub.
///
/// This adds NO new engineering: it is a pure fan-in over providers that already
/// exist (`airVelocityChecksProvider` / `airUnsizedProvider` from the air-warnings
/// store, the per-sheet calibration gap from the project controller, and the
/// `// VERIFY` standards checklists on the SNI / ventilation / PUIL profiles).
/// Each issue optionally carries a [locate] target so the Review row can jump to
/// the offending element (set the active sheet, select it, switch to Layout).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/network/connectivity.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart'
    show drainageStackBasesLackingCleanout;
import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';

import 'air_warnings_store.dart';
import 'electrical_store.dart';
import 'models/sheet.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'sheets_store.dart';
import 'sizing_store.dart';
import 'solve_store.dart';

/// Triage level for a design issue. [critical] BLOCKS a sound deliverable (an
/// uncalibrated sheet that already carries drawn runs — they size to ZERO
/// length); [warning] needs the engineer's attention (out-of-band velocity, a
/// source-less network, a blank uncalibrated sheet); [info] is an honesty
/// advisory (an unsized air element, or an unverified standards value). Ordered
/// most-severe first so a plain enum compare / sort surfaces blockers ahead of
/// advisories.
enum IssueSeverity { critical, warning, info }

/// Where an issue lives on the drawing, so the Review row can jump to it.
/// [sheetId] is present for a MECHANICAL (PDF-sheet) issue; [nodeId]/[edgeId]
/// point at the specific element when one is known. An ELECTRICAL issue instead
/// carries [panelId] (+ optionally [circuitId]) and leaves [sheetId] empty — it
/// is located on the single-line, not a floor plan (the jump keys off panelId).
@immutable
class IssueLocation {
  final String sheetId;
  final String? nodeId;
  final String? edgeId;

  /// Electrical target: the panel the issue belongs to (the Review→Electrical
  /// jump focuses this panel). Null for a mechanical / sheet-based issue.
  final String? panelId;

  /// Electrical target: the specific circuit (way) when known. Null otherwise.
  final String? circuitId;

  const IssueLocation(
    this.sheetId, {
    this.nodeId,
    this.edgeId,
    this.panelId,
    this.circuitId,
  });

  @override
  bool operator ==(Object other) =>
      other is IssueLocation &&
      other.sheetId == sheetId &&
      other.nodeId == nodeId &&
      other.edgeId == edgeId &&
      other.panelId == panelId &&
      other.circuitId == circuitId;

  @override
  int get hashCode =>
      Object.hash(sheetId, nodeId, edgeId, panelId, circuitId);
}

/// One aggregated design issue: a [severity], a short [title] + [message], and
/// an optional [locate] target (null for non-spatial issues like standards).
@immutable
class DesignIssue {
  final IssueSeverity severity;
  final String title;
  final String message;
  final IssueLocation? locate;

  const DesignIssue({
    required this.severity,
    required this.title,
    required this.message,
    this.locate,
  });

  bool get isLocatable => locate != null;

  @override
  bool operator ==(Object other) =>
      other is DesignIssue &&
      other.severity == severity &&
      other.title == title &&
      other.message == message &&
      other.locate == locate;

  @override
  int get hashCode => Object.hash(severity, title, message, locate);
}

/// The aggregated list of design issues, warnings first then info. Read-only:
/// it never mutates the network, the project, or any standard.
final designIssuesProvider = Provider<List<DesignIssue>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final project = ref.watch(projectControllerProvider);
  final sheets = ref.watch(sheetsControllerProvider);
  final velocity = ref.watch(airVelocityChecksProvider);
  final unsized = ref.watch(airUnsizedProvider);
  final overCapacity = ref.watch(airOverCapacityProvider);
  final drainAdvisories = ref.watch(drainageAdvisoryProvider);
  final legionellaReturnTempC = ref.watch(hotWaterLegionellaProvider);

  final criticals = <DesignIssue>[];
  final warnings = <DesignIssue>[];
  final infos = <DesignIssue>[];

  // The sheet an element sits on: a node carries its own [sheetId]; an edge is
  // located by its `from` node (both endpoints share a sheet for a drawn run).
  final nodeById = <String, NetNode>{for (final n in net.nodes) n.id: n};
  String? sheetForEdge(NetEdge e) => nodeById[e.fromId]?.sheetId;

  final levelCount = project.building.levelCount;
  final liveSheetIds = <String>{for (final s in sheets.sheets) s.id};

  // ── 0. Elements referencing a missing floor / sheet (CRITICAL, locatable) ───
  // A node whose floorIndex falls outside the live floor stack, or whose
  // sheetId is no longer among the loaded sheets, is an ORPHAN. The engine now
  // CLAMPS an out-of-range floorIndex so the solve can't crash, but that means
  // the node is silently sizing at the wrong (clamped) elevation — or is on a
  // sheet the engineer can no longer see. Floor-stack and sheet-remap edits
  // remap/clamp nodes to keep this from happening, so when it does it is a hard
  // blocker: surface it first, locatable to the offending element.
  for (final n in net.nodes) {
    final badFloor = n.floorIndex < 0 || n.floorIndex >= levelCount;
    // Only flag a missing sheet once sheets exist — an empty project hasn't
    // loaded its sheets yet, so every node would spuriously flag.
    final badSheet = liveSheetIds.isNotEmpty && !liveSheetIds.contains(n.sheetId);
    if (!badFloor && !badSheet) continue;
    criticals.add(DesignIssue(
      severity: IssueSeverity.critical,
      title: 'Element references a missing floor or sheet',
      message: badFloor
          ? 'A drawn element sits on floor ${n.floorIndex + 1}, which no longer '
              'exists (the building has $levelCount floor(s)) — it is being '
              'sized at a clamped elevation. Delete it or move it onto a real '
              'floor.'
          : 'A drawn element belongs to a sheet that is no longer loaded — '
              're-import that sheet or delete the orphaned element.',
      locate: IssueLocation(n.sheetId, nodeId: n.id),
    ));
  }

  // ── 1. Out-of-band air velocities (warning, locatable) ──────────────────────
  final edgeById = <String, NetEdge>{for (final e in net.edges) e.id: e};
  for (final entry in velocity.entries) {
    final check = entry.value;
    if (!check.isWarning) continue;
    final id = entry.key;
    final edge = edgeById[id];
    final node = nodeById[id];
    if (edge != null) {
      final sheetId = sheetForEdge(edge);
      warnings.add(DesignIssue(
        severity: IssueSeverity.warning,
        title: 'Duct velocity out of band',
        message: check.message,
        locate: sheetId == null
            ? null
            : IssueLocation(sheetId, edgeId: id),
      ));
    } else if (node != null) {
      warnings.add(DesignIssue(
        severity: IssueSeverity.warning,
        title: 'Terminal face velocity out of band',
        message: check.message,
        locate: IssueLocation(node.sheetId, nodeId: id),
      ));
    }
  }

  // ── 2. Not-yet-sized air elements (info, locatable) ─────────────────────────
  for (final id in unsized) {
    final edge = edgeById[id];
    final node = nodeById[id];
    if (edge != null) {
      final sheetId = sheetForEdge(edge);
      infos.add(DesignIssue(
        severity: IssueSeverity.info,
        title: 'Air duct not manually sized',
        message: 'This duct carries air but has no chosen size — still '
            'relying on auto-sizing.',
        locate:
            sheetId == null ? null : IssueLocation(sheetId, edgeId: id),
      ));
    } else if (node != null) {
      infos.add(DesignIssue(
        severity: IssueSeverity.info,
        title: 'Air terminal not manually sized',
        message: 'This terminal carries air but has no chosen face size.',
        locate: IssueLocation(node.sheetId, nodeId: id),
      ));
    }
  }

  // ── 2b. Duct over capacity: clamped to the largest standard size (warning) ──
  // The auto-sizer clamps an oversize air duct to the largest standard duct
  // and flags it instead of aborting the solve; surface each clamped edge.
  for (final id in overCapacity) {
    final edge = edgeById[id];
    if (edge == null) continue;
    final sheetId = sheetForEdge(edge);
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      title: 'Duct over capacity',
      message: 'This duct carries more air than the largest standard duct can '
          'handle within the velocity / friction limit — it was clamped to the '
          'largest standard size. Split the run or add a parallel duct.',
      locate: sheetId == null ? null : IssueLocation(sheetId, edgeId: id),
    ));
  }

  // ── 3. Uncalibrated sheets (warning, or CRITICAL when edges are drawn) ───────
  // An uncalibrated sheet that already carries drawn runs is a BLOCKER: every
  // run on it sizes to ZERO length (edgeLength returns Length(0) for an
  // uncalibrated run), so the BOM / pressures / report are silently wrong. A
  // blank uncalibrated sheet stays a plain warning. We escalate only the
  // edge-bearing ones; the title is kept ('… calibrated') so the compliance
  // roll-up and any title match still catch it.
  final sheetsWithEdges = <String>{
    for (final n in net.nodes)
      if (net.edgesAt(n.id).isNotEmpty) n.sheetId,
  };
  for (final s in sheets.sheets) {
    if (project.calibrationFor(s.id) != null) continue;
    if (sheetsWithEdges.contains(s.id)) {
      criticals.add(DesignIssue(
        severity: IssueSeverity.critical,
        title: 'Sheet not calibrated',
        message: '"${s.name}" carries drawn runs but has no scale set — they '
            'are sizing to ZERO length. Calibrate the sheet before sizing or '
            'export, or the BOM and pressures will be wrong.',
        locate: IssueLocation(s.id),
      ));
    } else {
      warnings.add(DesignIssue(
        severity: IssueSeverity.warning,
        title: 'Sheet not calibrated',
        message: '"${s.name}" has no scale set — its run/riser lengths cannot '
            'be measured. Calibrate the sheet to size it.',
        locate: IssueLocation(s.id),
      ));
    }
  }

  // ── 3c. Sheet→floor pile-up (warning, locatable) ────────────────────────────
  // More sheets than floors — or an explicit double-mapping — pile multiple
  // plans onto ONE building floor: `floorFor` silently clamps the overflow to
  // the top floor (import 8 pages into a 3-floor default and pages 4-8 all land
  // on the top). Only one plan per floor feeds the riser/sizing at that
  // elevation, so the stacked extras are invisible work. Warn per
  // over-subscribed floor, locatable to one of the piled sheets.
  final sheetsByFloor = <int, List<Sheet>>{};
  for (final s in sheets.sheets) {
    (sheetsByFloor[sheets.floorFor(s.id, levelCount)] ??= []).add(s);
  }
  for (final entry in sheetsByFloor.entries) {
    if (entry.value.length < 2) continue;
    final floorName = project.building.floors[entry.key].name;
    final names = entry.value.map((s) => '"${s.name}"').join(', ');
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      title: 'Multiple sheets mapped to one floor',
      message: '${entry.value.length} sheets map to floor "$floorName" '
          '($names) — only one plan per floor feeds sizing at that elevation, '
          'so the extras are stacked there (often an import that ran past the '
          'floor count). Re-map the extra sheets or add floors.',
      locate: IssueLocation(entry.value.last.id),
    ));
  }

  // ── 3b. Network connectivity / supply integrity (warning, locatable) ────────
  // A pressurized/air component with no plant/source is being rooted
  // heuristically and sized as if supplied; a plant-less component alongside a
  // fed one is a branch that fell off the rooted tree. Both are detected by the
  // pure engine helper (read-only — never resizes). Locate via a representative
  // node's sheet. Gravity services are skipped (a drain has no source).
  for (final d in networkConnectivityDefects(net)) {
    final repId = d.representativeNodeId;
    final repNode = repId == null ? null : nodeById[repId];
    final service = d.service.name;
    final n = d.nodeIds.length;
    final title =
        d.isIsland ? 'Network branch not connected' : 'Network has no source';
    final message = d.isIsland
        ? 'A $service branch with $n node(s) is disconnected from its fed '
            'network — it is rooted heuristically and sized as if supplied. '
            'Connect it to the source, or add a plant.'
        : 'A $service component with $n node(s) has no plant/source — it is '
            'being rooted heuristically and sized as if supplied. Add a pump / '
            'tank / AHU source.';
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      title: title,
      message: message,
      locate: repNode == null
          ? null
          : IssueLocation(repNode.sheetId, nodeId: repId),
    ));
  }

  // ── 4. Drainage advisories: too-flat slope / over-long branch (info) ────────
  // Each advisory is edge-locatable via the edge's `from` node sheet. Title is
  // fixed (golden-friendly); the engine message carries the specifics.
  for (final a in drainAdvisories) {
    final edge = edgeById[a.edgeId];
    final sheetId = edge == null ? null : sheetForEdge(edge);
    final title = switch (a.kind) {
      DrainageAdvisoryKind.minSlope => 'Drainage slope below self-cleansing',
      DrainageAdvisoryKind.developedLength => 'Drainage branch too long',
    };
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      title: title,
      message: a.message,
      locate: sheetId == null
          ? null
          : IssueLocation(sheetId, edgeId: a.edgeId),
    ));
  }

  // ── 4b. Drainage stack base without a cleanout (info, locatable) ────────────
  // B2: the riser drawing draws a cleanout ONLY where the engineer placed one;
  // a stack whose lowest node lacks a cleanout at/beside its base is surfaced
  // here as a muted advisory instead of fabricating the symbol. Pure engine
  // detection (`drainageStackBasesLackingCleanout`), shared with the drawing.
  for (final id in drainageStackBasesLackingCleanout(net)) {
    final node = nodeById[id];
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      title: 'Drainage stack has no cleanout at its base',
      message: 'A drainage stack reaches its lowest drawn point here with no '
          'cleanout component at or beside the base — rodding access is '
          'conventional at every stack base. Place a cleanout, or confirm '
          'access exists elsewhere.',
      locate: node == null ? null : IssueLocation(node.sheetId, nodeId: id),
    ));
  }

  // ── 5. Hot-water anti-Legionella return temperature (info, not locatable) ───
  if (legionellaReturnTempC != null) {
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      title: 'Hot-water return temperature low',
      message: 'Modelled recirculation return temperature '
          '${legionellaReturnTempC.toStringAsFixed(0)} °C is below the '
          'anti-Legionella floor (~55 °C). Reduce the loop temperature drop or '
          'add trace heating. (// VERIFY vs SNI / WHO guidance.)',
    ));
  }

  // ── 5b. Electrical sizing warnings (fanned in from the solved system) ───────
  // Every ElectricalWarning the A4 orchestrator raises (cable-ampacity, voltage
  // drop, earthing, phase imbalance, …) becomes a DesignIssue so the one Review
  // list — not a bare count — carries the electrical health of an M+E+P design.
  // Severity maps straight across: error ⇒ critical (a blocker — e.g. a way its
  // cable can't protect), warning ⇒ warning, info ⇒ info. Nothing is skipped.
  // An electrical issue is located on the single-line via its [panelId] (the
  // sheetId is empty/unused), so the Review row jumps to the Electrical
  // workspace + focuses the panel rather than a floor plan. A system-level
  // warning with no panel is non-locatable.
  final electrical = ref.watch(electricalResultProvider);
  for (final w in electrical.warnings) {
    final severity = switch (w.severity) {
      WarningSeverity.error => IssueSeverity.critical,
      WarningSeverity.warning => IssueSeverity.warning,
      WarningSeverity.info => IssueSeverity.info,
    };
    final issue = DesignIssue(
      severity: severity,
      // A short humanized form of the code (e.g. 'cable-ampacity-inadequate' →
      // 'Electrical: cable ampacity inadequate'); the engine message carries
      // the specifics.
      title: 'Electrical: ${w.code.replaceAll('-', ' ')}',
      message: w.message,
      locate: w.panelId == null
          ? null
          : IssueLocation('', panelId: w.panelId, circuitId: w.circuitId),
    );
    switch (severity) {
      case IssueSeverity.critical:
        criticals.add(issue);
      case IssueSeverity.warning:
        warnings.add(issue);
      case IssueSeverity.info:
        infos.add(issue);
    }
  }

  // ── 6. Unverified // VERIFY standards (info, not locatable) ─────────────────
  // Only values genuinely PENDING official confirmation (secondarySource) are
  // surfaced here as "Unverified standard". A notAnSniClause value is a confirmed
  // general-practice/design choice — NOT a verification debt — so it is not
  // nagged in the interactive Review (it still appears in the calc report's
  // transparency section for submission honesty).
  void addVerify(StandardValue<Object?> v) {
    if (!v.isUnverified) return;
    if (v.status != VerificationStatus.secondarySource) return;
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      title: 'Unverified standard',
      message: v.note ?? v.citation,
    ));
  }

  for (final v in const SniProfile().verifyChecklist) {
    addVerify(v);
  }
  for (final v in const SniVentilationProfile().verifyChecklist) {
    addVerify(v);
  }
  for (final v in const PuilProfile().verifyChecklist) {
    addVerify(v);
  }

  return [...criticals, ...warnings, ...infos];
});

/// Total number of aggregated design issues (for a count badge / summary).
final designIssueCountProvider =
    Provider<int>((ref) => ref.watch(designIssuesProvider).length);

/// Number of warning-severity issues (the count that should draw attention).
final designIssueWarningCountProvider = Provider<int>((ref) => ref
    .watch(designIssuesProvider)
    .where((i) => i.severity == IssueSeverity.warning)
    .length);

/// Number of CRITICAL-severity issues — blockers a sound deliverable can't carry
/// (an uncalibrated sheet with drawn runs sizing to zero length). The export
/// gate (cluster D) consumes this.
final designIssueCriticalCountProvider = Provider<int>((ref) => ref
    .watch(designIssuesProvider)
    .where((i) => i.severity == IssueSeverity.critical)
    .length);

/// How many SIZED edges resolve to ZERO geometric length under the §10 length
/// rule (a run on an uncalibrated sheet ⇒ `edgeLength` returns Length(0)). This
/// is the SHARED zero-length detection: the export gate (cluster D) blocks an
/// export when this is > 0, and the uncalibrated-sheet escalation (cluster C)
/// keys off the same predicate (sized edge ⇒ engine length == 0). A riser keeps
/// the true-elevation delta (never calibration), so it is never counted. Only
/// edges that actually appear in the sizing map are considered, so an empty /
/// fully-calibrated network returns 0 and the gate is inert.
final zeroLengthSizedEdgeCountProvider = Provider<int>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final project = ref.watch(projectControllerProvider);
  final sizing = ref.watch(sizingProvider);
  var count = 0;
  for (final e in net.edges) {
    if (!sizing.containsKey(e.id)) continue;
    final len = edgeLength(
      e,
      net,
      calibrationBySheet: project.calibrations,
      building: project.building,
    );
    if (len.meters <= 0) count++;
  }
  return count;
});

/// True when ANY sized edge resolves to zero geometric length — the boolean the
/// export guard reads to block-and-warn instead of silently writing a wrong BOM
/// / pressure / drawing. False (byte-identical) for a calibrated or empty
/// network.
final exportHasZeroLengthEdgesProvider =
    Provider<bool>((ref) => ref.watch(zeroLengthSizedEdgeCountProvider) > 0);

/// A one-click batch action over a whole CLASS of issues. SAFE by construction —
/// it only SELECTS the offending elements or applies an already-existing bulk op
/// (copy one sheet's calibration to the rest). It never invents geometry or
/// resizes anything; the executor lives in the UI (see `issues_card.dart`).
enum IssueBatchKind {
  /// Multi-select every out-of-band air-velocity element.
  selectVelocityWarnings,

  /// Multi-select every air element carrying air with no chosen size yet.
  selectUnsizedAir,

  /// Copy a calibrated sheet's scale onto every uncalibrated sheet.
  calibrateAllSheets,
}

@immutable
class IssueBatchAction {
  final IssueBatchKind kind;
  final String label;

  /// False when the action can't run yet (e.g. calibrate-all with no calibrated
  /// source sheet) — the UI shows it disabled with the explanatory label.
  final bool enabled;

  /// Selection payload (for the select-* kinds).
  final Set<String> nodeIds;
  final Set<String> edgeIds;

  /// Calibrate-all payload: the source (a calibrated sheet, null ⇒ disabled) and
  /// the uncalibrated targets.
  final String? sourceSheetId;
  final Set<String> targetSheetIds;

  const IssueBatchAction({
    required this.kind,
    required this.label,
    required this.enabled,
    this.nodeIds = const {},
    this.edgeIds = const {},
    this.sourceSheetId,
    this.targetSheetIds = const {},
  });
}

/// Safe one-click batch actions, derived READ-ONLY from the same sources as
/// [designIssuesProvider] (not from issue titles). Empty when there's nothing to
/// batch — so a clean design surfaces no actions.
final issueBatchActionsProvider = Provider<List<IssueBatchAction>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final project = ref.watch(projectControllerProvider);
  final sheets = ref.watch(sheetsControllerProvider);
  final velocity = ref.watch(airVelocityChecksProvider);
  final unsized = ref.watch(airUnsizedProvider);

  final nodeIds = {for (final n in net.nodes) n.id};
  final edgeIds = {for (final e in net.edges) e.id};
  final actions = <IssueBatchAction>[];

  // 1. Out-of-band velocity warnings → select.
  final velN = <String>{};
  final velE = <String>{};
  velocity.forEach((id, check) {
    if (!check.isWarning) return;
    if (edgeIds.contains(id)) {
      velE.add(id);
    } else if (nodeIds.contains(id)) {
      velN.add(id);
    }
  });
  if (velN.isNotEmpty || velE.isNotEmpty) {
    final c = velN.length + velE.length;
    actions.add(IssueBatchAction(
      kind: IssueBatchKind.selectVelocityWarnings,
      label: 'Select $c out-of-band ${c == 1 ? 'velocity' : 'velocities'}',
      enabled: true,
      nodeIds: velN,
      edgeIds: velE,
    ));
  }

  // 2. Unsized air → select.
  final unN = <String>{};
  final unE = <String>{};
  for (final id in unsized) {
    if (edgeIds.contains(id)) {
      unE.add(id);
    } else if (nodeIds.contains(id)) {
      unN.add(id);
    }
  }
  if (unN.isNotEmpty || unE.isNotEmpty) {
    final c = unN.length + unE.length;
    actions.add(IssueBatchAction(
      kind: IssueBatchKind.selectUnsizedAir,
      label: 'Select $c unsized air ${c == 1 ? 'element' : 'elements'}',
      enabled: true,
      nodeIds: unN,
      edgeIds: unE,
    ));
  }

  // 3. Calibrate-all from the first calibrated sheet (if any).
  final uncalibrated = <String>{
    for (final s in sheets.sheets)
      if (project.calibrationFor(s.id) == null) s.id,
  };
  if (uncalibrated.isNotEmpty) {
    String? source;
    for (final s in sheets.sheets) {
      if (project.calibrationFor(s.id) != null) {
        source = s.id;
        break;
      }
    }
    final n = uncalibrated.length;
    actions.add(IssueBatchAction(
      kind: IssueBatchKind.calibrateAllSheets,
      label: source == null
          ? 'Calibrate one sheet to copy scale to $n more'
          : 'Copy scale to $n uncalibrated ${n == 1 ? 'sheet' : 'sheets'}',
      enabled: source != null,
      sourceSheetId: source,
      targetSheetIds: uncalibrated,
    ));
  }

  return actions;
});
