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
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';

import 'air_warnings_store.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'sheets_store.dart';
import 'sizing_store.dart';
import 'solve_store.dart';

/// Triage level for a design issue. [warning] needs the engineer's attention
/// (out-of-band velocity, uncalibrated sheet); [info] is an honesty advisory
/// (an unsized air element, or an unverified standards value).
enum IssueSeverity { warning, info }

/// Where an issue lives on the drawing, so the Review row can jump to it.
/// [sheetId] is always present for a locatable issue; [nodeId]/[edgeId] point at
/// the specific element when one is known.
@immutable
class IssueLocation {
  final String sheetId;
  final String? nodeId;
  final String? edgeId;

  const IssueLocation(this.sheetId, {this.nodeId, this.edgeId});

  @override
  bool operator ==(Object other) =>
      other is IssueLocation &&
      other.sheetId == sheetId &&
      other.nodeId == nodeId &&
      other.edgeId == edgeId;

  @override
  int get hashCode => Object.hash(sheetId, nodeId, edgeId);
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
  final drainAdvisories = ref.watch(drainageAdvisoryProvider);
  final legionellaReturnTempC = ref.watch(hotWaterLegionellaProvider);

  final warnings = <DesignIssue>[];
  final infos = <DesignIssue>[];

  // The sheet an element sits on: a node carries its own [sheetId]; an edge is
  // located by its `from` node (both endpoints share a sheet for a drawn run).
  final nodeById = <String, NetNode>{for (final n in net.nodes) n.id: n};
  String? sheetForEdge(NetEdge e) => nodeById[e.fromId]?.sheetId;

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

  // ── 3. Uncalibrated sheets (warning, locatable) ─────────────────────────────
  for (final s in sheets.sheets) {
    if (project.calibrationFor(s.id) != null) continue;
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      title: 'Sheet not calibrated',
      message: '"${s.name}" has no scale set — its run/riser lengths cannot '
          'be measured. Calibrate the sheet to size it.',
      locate: IssueLocation(s.id),
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

  // ── 6. Unverified // VERIFY standards (info, not locatable) ─────────────────
  void addVerify(StandardValue<Object?> v) {
    if (!v.isUnverified) return;
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

  return [...warnings, ...infos];
});

/// Total number of aggregated design issues (for a count badge / summary).
final designIssueCountProvider =
    Provider<int>((ref) => ref.watch(designIssuesProvider).length);

/// Number of warning-severity issues (the count that should draw attention).
final designIssueWarningCountProvider = Provider<int>((ref) => ref
    .watch(designIssuesProvider)
    .where((i) => i.severity == IssueSeverity.warning)
    .length);

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
