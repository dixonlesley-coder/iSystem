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
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';

import 'air_warnings_store.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'sheets_store.dart';

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

  // ── 4. Unverified // VERIFY standards (info, not locatable) ─────────────────
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
