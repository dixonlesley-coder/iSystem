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
import 'package:mechx_engine/electrical/connectivity.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/network/connectivity.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart'
    show drainageStackBasesLackingCleanout;
import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';

import '../ui/strings/app_strings.dart';
import '../ui/strings/plural.dart';
import 'air_warnings_store.dart';
import 'app_state.dart';
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

  /// H7a — true when this issue is a `// VERIFY` standards-verification advisory
  /// (built by the [addVerify] path). A STABLE discriminator that survives the
  /// specific-value title: each verify row now NAMES its own value (e.g.
  /// 'Unverified: max supply velocity') instead of the generic 'Unverified
  /// standard' literal, so the compliance roll-up and the status-bar provenance
  /// dot key off this flag rather than the title text. Additive: this is a
  /// derived/transient type (never persisted to `.mechx`), so a new field has no
  /// file impact; default false keeps every non-verify issue byte-identical.
  final bool isVerify;

  /// H1 (Wave 5a) — a STABLE, locale-INDEPENDENT discriminator for this issue's
  /// class (e.g. `'duct-velocity'`, `'sheet-uncalibrated:<sheetId>'`,
  /// `'no-source:<service>'`, `'electrical:<code>'`, `'verify:<citation>'`). Set
  /// at every construction from engine/enum data, NEVER from the (now localized)
  /// [title]/[message]. It is the basis for both [key] (so an acknowledgement
  /// made in English still matches the same row in Bahasa) and the compliance
  /// fan-in's category matching (which used to substring-match English titles and
  /// would silently mis-bucket a localized title). Additive & derived/transient
  /// (never persisted to `.mechx`); default `''` for anything unclassified.
  final String kind;

  const DesignIssue({
    required this.severity,
    required this.title,
    required this.message,
    this.locate,
    this.isVerify = false,
    this.kind = '',
  });

  bool get isLocatable => locate != null;

  /// H1 — whether the engineer may ACKNOWLEDGE this issue so it stops blocking a
  /// PASS verdict. Only [info]-severity advisories (unverified `secondarySource`
  /// standards, drainage/Legionella/unsized-air notes) are acknowledgeable;
  /// [warning] and [critical] issues are real design findings that ALWAYS block —
  /// an acknowledgement must never hide a genuine error.
  bool get isAcknowledgeable => severity == IssueSeverity.info;

  /// A stable identity for persisting an acknowledgement (H1). Keyed on the
  /// locale-independent [kind] (+ the element target), NOT the localized
  /// title/message — so an acknowledgement recorded in English still matches the
  /// same row when the app is switched to Bahasa. Each [kind] embeds whatever it
  /// needs to stay unique per acknowledgeable row (the sheet id, the service, the
  /// standards citation…) so a locatable advisory folds its element target in and
  /// each is acknowledged individually. NOTE: this differs from the pre-Wave-5a
  /// `'$title $message $locKey'` scheme, so a project acknowledged by an OLDER
  /// build re-surfaces its advisories ONCE on first open under this build — a safe
  /// direction (an acknowledgement only relaxes an advisory; it can never hide a
  /// warning/error), after which the new keys persist.
  String get key {
    final loc = locate;
    final locKey = loc == null
        ? ''
        : '${loc.sheetId}|${loc.nodeId ?? ''}|${loc.edgeId ?? ''}'
            '|${loc.panelId ?? ''}|${loc.circuitId ?? ''}';
    return '$kind $locKey';
  }

  @override
  bool operator ==(Object other) =>
      other is DesignIssue &&
      other.severity == severity &&
      other.title == title &&
      other.message == message &&
      other.locate == locate &&
      other.isVerify == isVerify;

  @override
  int get hashCode => Object.hash(severity, title, message, locate, isVerify);
}

/// H7a — a short human name for a `// VERIFY` [StandardValue], used as its design
/// issue's specific title (`Unverified: NAME`). Standards citations follow a
/// `SOURCE — DESCRIPTION` shape, so the descriptive tail after the em-dash is the
/// value's name (e.g. `SNI 8153:2015 — max supply velocity` yields `max supply
/// velocity`). A citation with no source prefix (no em-dash) is used whole.
String _verifyLabel(StandardValue<Object?> v) {
  final citation = v.citation.trim();
  final dash = citation.lastIndexOf('—');
  if (dash < 0) return citation;
  final tail = citation.substring(dash + 1).trim();
  return tail.isEmpty ? citation : tail;
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

  // Wave 5a (H1) — every user-facing title/message resolves through the active
  // locale; kinds + engine-sourced messages (velocity/drainage/electrical
  // `.message`, the `{service}` enum name, the `{code}`/`{name}` citations) stay
  // engine English. EN ⇒ byte-identical.
  final str = MechXStringsData(ref.watch(localeProvider));

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
      kind: 'orphan',
      title: str(StringKey.issueOrphanTitle),
      message: badFloor
          ? str.format(StringKey.issueOrphanFloorMessage, {
              'floor': '${n.floorIndex + 1}',
              'floors': pluralCount(levelCount,
                  str(StringKey.issueNounFloorOne),
                  str(StringKey.issueNounFloorMany)),
            })
          : str(StringKey.issueOrphanSheetMessage),
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
        kind: 'duct-velocity',
        title: str(StringKey.issueDuctVelocityTitle),
        message: check.message,
        locate: sheetId == null
            ? null
            : IssueLocation(sheetId, edgeId: id),
      ));
    } else if (node != null) {
      warnings.add(DesignIssue(
        severity: IssueSeverity.warning,
        kind: 'terminal-velocity',
        title: str(StringKey.issueTerminalVelocityTitle),
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
        kind: 'air-duct-unsized',
        title: str(StringKey.issueAirDuctUnsizedTitle),
        message: str(StringKey.issueAirDuctUnsizedMessage),
        locate:
            sheetId == null ? null : IssueLocation(sheetId, edgeId: id),
      ));
    } else if (node != null) {
      infos.add(DesignIssue(
        severity: IssueSeverity.info,
        kind: 'air-terminal-unsized',
        title: str(StringKey.issueAirTerminalUnsizedTitle),
        message: str(StringKey.issueAirTerminalUnsizedMessage),
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
      kind: 'duct-over-capacity',
      title: str(StringKey.issueDuctOverCapacityTitle),
      message: str(StringKey.issueDuctOverCapacityMessage),
      locate: sheetId == null ? null : IssueLocation(sheetId, edgeId: id),
    ));
  }

  // ── 2c. Stranded air terminals: carry airflow but no duct (warning) ─────────
  // A node carrying a design airflow with ZERO incident edges is invisible to
  // duct sizing, to connectivity (its node set is built from edges) and to the
  // BOM — its air is silently stranded. 'Auto-place diffusers' drops exactly
  // such terminals (unwired until a supply trunk is routed), so surfacing them
  // closes that trap. Locatable to the terminal's own sheet.
  for (final n in net.nodes) {
    if (n.airflow == null || net.edgesAt(n.id).isNotEmpty) continue;
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'diffuser-stranded',
      title: str(StringKey.issueDiffuserStrandedTitle),
      message: str(StringKey.issueDiffuserStrandedMessage),
      locate: IssueLocation(n.sheetId, nodeId: n.id),
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
        kind: 'sheet-uncalibrated:${s.id}',
        title: str(StringKey.issueSheetNotCalibratedTitle),
        message: str.format(
            StringKey.issueSheetNotCalibratedCriticalMessage, {'name': s.name}),
        locate: IssueLocation(s.id),
      ));
    } else {
      warnings.add(DesignIssue(
        severity: IssueSeverity.warning,
        kind: 'sheet-uncalibrated:${s.id}',
        title: str(StringKey.issueSheetNotCalibratedTitle),
        message: str.format(
            StringKey.issueSheetNotCalibratedWarningMessage, {'name': s.name}),
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
      kind: 'multi-sheet-floor',
      title: str(StringKey.issueMultiSheetFloorTitle),
      message: str.format(StringKey.issueMultiSheetFloorMessage, {
        'count': '${entry.value.length}',
        'floor': floorName,
        'names': names,
      }),
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
    final title = d.isIsland
        ? str(StringKey.issueNetworkIslandTitle)
        : str(StringKey.issueNetworkNoSourceTitle);
    final defectKind =
        d.isIsland ? 'network-island:$service' : 'no-source:$service';
    final nodeWord = pluralCount(
        n, str(StringKey.issueNounNodeOne), str(StringKey.issueNounNodeMany));
    final message = d.isIsland
        ? str.format(StringKey.issueNetworkIslandMessage,
            {'service': service, 'nodes': nodeWord})
        : str.format(StringKey.issueNetworkNoSourceMessage,
            {'service': service, 'nodes': nodeWord});
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: defectKind,
      title: title,
      message: message,
      locate: repNode == null
          ? null
          : IssueLocation(repNode.sheetId, nodeId: repId),
    ));
  }

  // ── 3c. Unconnected elements: loose run/duct ends + orphans (warning) ────────
  // A finer-grained companion to 3b: a single run/duct that ENDS in mid-air at a
  // bare junction (no fixture / terminal / plant / another run), or an element
  // placed but joined to NOTHING at all. Detected read-only by the pure engine
  // (`networkElementDefects`) — never resizes. Each defect is its OWN warning
  // (a per-node `kind` so acking/fixing one never hides the others), locatable
  // via the node's sheet.
  for (final d in networkElementDefects(net)) {
    final node = nodeById[d.nodeId];
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: d.isOrphan
          ? 'unconnected-orphan:${d.nodeId}'
          : 'unconnected-loose-end:${d.nodeId}',
      title: d.isOrphan
          ? str(StringKey.issueUnconnectedOrphanTitle)
          : str(StringKey.issueUnconnectedLooseEndTitle),
      message: d.isOrphan
          ? str(StringKey.issueUnconnectedOrphanMessage)
          : str(StringKey.issueUnconnectedLooseEndMessage),
      locate:
          node == null ? null : IssueLocation(node.sheetId, nodeId: d.nodeId),
    ));
  }

  // ── 3d. Downfeed pressure zone over the SNI max fixture static (I1, warning) ─
  // A pressure zone whose lowest fixture would exceed the SNI max fixture static
  // pressure needs a PRV / break-tank to split it. Derived from the building
  // height (zoneStaticsProvider) REGARDLESS of feed strategy — an over-pressure
  // zone is an SNI 8153:2015 safety concern the Review sign-off must reflect,
  // yet it previously only showed inline in the downfeed inspector (and not at
  // all on upfeed). Read-only: never resizes. Each over-limit zone is its own
  // warning, best-effort locatable to a sheet mapped onto its bottom floor. Its
  // generic title rolls up into its own compliance row (which then blocks PASS).
  final zoneStatics = ref.watch(zoneStaticsProvider);
  if (zoneStatics.any((z) => !z.withinLimit)) {
    final maxFixKpa =
        const SniProfile().maxFixtureStaticPressure.value.inKiloPascals;
    final floors = project.building.floors;
    // First sheet mapped onto each building floor (for the locate jump).
    final sheetForFloor = <int, String>{};
    for (final s in sheets.sheets) {
      sheetForFloor.putIfAbsent(sheets.floorFor(s.id, levelCount), () => s.id);
    }
    for (final z in zoneStatics) {
      if (z.withinLimit) continue;
      final bottomIdx = z.zone.bottomFloorIndex.clamp(0, floors.length - 1);
      final topIdx = z.zone.topFloorIndex.clamp(0, floors.length - 1);
      warnings.add(DesignIssue(
        severity: IssueSeverity.warning,
        kind:
            'pressure-zone:${z.zone.bottomFloorIndex}-${z.zone.topFloorIndex}',
        title: str(StringKey.issuePressureZoneTitle),
        message: str.format(StringKey.issuePressureZoneMessage, {
          'bottom': floors[bottomIdx].name,
          'top': floors[topIdx].name,
          'kpa': z.bottomStatic.inKiloPascals.toStringAsFixed(0),
          'limit': maxFixKpa.toStringAsFixed(0),
        }),
        locate: sheetForFloor[z.zone.bottomFloorIndex] == null
            ? null
            : IssueLocation(sheetForFloor[z.zone.bottomFloorIndex]!),
      ));
    }
  }

  // ── 4. Drainage advisories: too-flat slope / over-long branch (info) ────────
  // Each advisory is edge-locatable via the edge's `from` node sheet. Title is
  // fixed (golden-friendly); the engine message carries the specifics.
  for (final a in drainAdvisories) {
    final edge = edgeById[a.edgeId];
    final sheetId = edge == null ? null : sheetForEdge(edge);
    final (title, advKind) = switch (a.kind) {
      DrainageAdvisoryKind.minSlope => (
          str(StringKey.issueDrainageSlopeTitle),
          'drainage-slope'
        ),
      DrainageAdvisoryKind.developedLength => (
          str(StringKey.issueDrainageLengthTitle),
          'drainage-length'
        ),
    };
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: advKind,
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
      kind: 'drainage-cleanout',
      title: str(StringKey.issueDrainageCleanoutTitle),
      message: str(StringKey.issueDrainageCleanoutMessage),
      locate: node == null ? null : IssueLocation(node.sheetId, nodeId: id),
    ));
  }

  // ── 5. Hot-water anti-Legionella return temperature (info, not locatable) ───
  if (legionellaReturnTempC != null) {
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'legionella',
      title: str(StringKey.issueLegionellaTitle),
      message: str.format(StringKey.issueLegionellaMessage,
          {'temp': legionellaReturnTempC.toStringAsFixed(0)}),
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
      // The stable code (e.g. 'electrical:cable-ampacity-inadequate') is the
      // discriminator; the title humanizes the code for display (e.g.
      // 'Electrical: cable ampacity inadequate'), the engine message carries
      // the specifics.
      kind: 'electrical:${w.code}',
      title: str.format(
          StringKey.issueElectricalTitle, {'code': w.code.replaceAll('-', ' ')}),
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

  // ── 5c. Unconnected (unfed) electrical panels (warning, locatable) ──────────
  // The electrical analogue of 3c: a sub-panel that is neither the origin nor
  // fed by any feeder — a board wired to nothing. Detected read-only by the pure
  // engine (`electricalConnectivityDefects`). Located on the single-line via the
  // panel id (the Review row jumps to the Electrical workspace + focuses it).
  final electricalProject = ref.watch(electricalProjectProvider);
  for (final d in electricalConnectivityDefects(electricalProject)) {
    final panel =
        electricalProject.panels.where((p) => p.id == d.panelId).firstOrNull;
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      // NOT prefixed `electrical:` on purpose: the compliance store CLAIMS every
      // `electrical:*` design-issue (it assumes those mirror the solved system's
      // own warnings, already counted in the 'Electrical circuit sizing' row).
      // This unfed-panel check is designIssues-ONLY, so an `electrical:` kind
      // would be claimed AND never counted — swallowed from the sign-off card.
      // A plain kind lets it surface as its own compliance row + fail the verdict.
      kind: 'unfed-panel:${d.panelId}',
      title: str(StringKey.issueUnfedPanelTitle),
      message: str.format(
          StringKey.issueUnfedPanelMessage, {'panel': panel?.name ?? d.panelId}),
      locate: IssueLocation('', panelId: d.panelId),
    ));
  }

  // ── 6. Unverified // VERIFY standards (info, not locatable) ─────────────────
  // Only values genuinely PENDING official confirmation (secondarySource) are
  // surfaced here. A notAnSniClause value is a confirmed general-practice/design
  // choice — NOT a verification debt — so it is not nagged in the interactive
  // Review (it still appears in the calc report's transparency section for
  // submission honesty). H7a — each row NAMES its own value ('Unverified:
  // <value>') so the Review reads what needs checking, not a generic bucket;
  // consumers discriminate on the [DesignIssue.isVerify] flag, never the title.
  void addVerify(StandardValue<Object?> v) {
    if (!v.isUnverified) return;
    if (v.status != VerificationStatus.secondarySource) return;
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      // The citation is the stable, locale-independent per-value discriminator
      // (so each unverified value is acknowledged individually across locales);
      // [isVerify] stays the flag the compliance roll-up + provenance dot read.
      kind: 'verify:${v.citation}',
      title: str.format(StringKey.issueUnverifiedTitle, {'name': _verifyLabel(v)}),
      message: v.note ?? v.citation,
      isVerify: true,
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

/// H1 — the set of ACKNOWLEDGED advisory issue keys (see [DesignIssue.key]). An
/// acknowledgement records that the engineer has seen and accepted an advisory
/// (an unverified `secondarySource` standard, a drainage/Legionella note) so it
/// no longer blocks a PASS verdict — errors and warnings are NOT acknowledgeable
/// and always block. Persisted additively with the project via
/// `DesignSettings.acknowledgedIssueKeys` (round-trips in `.mechx`; empty ⇒
/// byte-identical, and compliance behaves exactly as before). Machine-agnostic:
/// the keys travel with the file so a colleague opening it sees the same
/// sign-off state.
final acknowledgedIssuesProvider =
    NotifierProvider<AcknowledgedIssuesController, Set<String>>(
  AcknowledgedIssuesController.new,
);

class AcknowledgedIssuesController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Replace the whole set (used by `applyDocument` on load).
  void set(Set<String> keys) => state = Set.unmodifiable(keys);

  /// Acknowledge one advisory by its [DesignIssue.key].
  void acknowledge(String key) => state = Set.unmodifiable({...state, key});

  /// Withdraw an acknowledgement (the row blocks again).
  void unacknowledge(String key) =>
      state = Set.unmodifiable({...state}..remove(key));

  /// Toggle the acknowledgement of [key].
  void toggle(String key) =>
      state.contains(key) ? unacknowledge(key) : acknowledge(key);

  /// Acknowledge every currently-OPEN acknowledgeable issue at once (the Review
  /// "Acknowledge all advisories" affordance). [keys] is the set of
  /// acknowledgeable issue keys the caller derived from [designIssuesProvider].
  void acknowledgeAll(Iterable<String> keys) =>
      state = Set.unmodifiable({...state, ...keys});

  void clear() => state = const {};
}

/// H6 — the count of OPEN (unacknowledged) design issues, driving the Review
/// nav-rail badge. Blockers (critical) and warnings are never acknowledgeable so
/// they always count; an acknowledged advisory drops out. Zero ⇒ the badge is
/// hidden (a fully-acknowledged, warning-free design shows no badge).
final openDesignIssueCountProvider = Provider<int>((ref) {
  final issues = ref.watch(designIssuesProvider);
  final ack = ref.watch(acknowledgedIssuesProvider);
  return issues
      .where((i) => !(i.isAcknowledgeable && ack.contains(i.key)))
      .length;
});

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
  final str = MechXStringsData(ref.watch(localeProvider));

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
      label: str.format(StringKey.issueBatchSelectVelocity, {
        'c': '$c',
        'noun': plural(c, str(StringKey.issueNounVelocityOne),
            str(StringKey.issueNounVelocityMany)),
      }),
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
      label: str.format(StringKey.issueBatchSelectUnsized, {
        'c': '$c',
        'noun': plural(c, str(StringKey.issueNounElementOne),
            str(StringKey.issueNounElementMany)),
      }),
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
          ? str.format(StringKey.issueBatchCalibrateNoSource, {'n': '$n'})
          : str.format(StringKey.issueBatchCalibrateCopy, {
              'n': '$n',
              'noun': plural(n, str(StringKey.issueNounSheetOne),
                  str(StringKey.issueNounSheetMany)),
            }),
      enabled: source != null,
      sourceSheetId: source,
      targetSheetIds: uncalibrated,
    ));
  }

  return actions;
});
