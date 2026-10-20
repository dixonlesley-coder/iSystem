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
import 'package:mechx_engine/report/plan_symbols.dart' show equipmentNodeTags;
import 'package:mechx_engine/report/riser_tags.dart'
    show drainageStackBasesLackingCleanout;
import 'package:mechx_engine/sizing/air_velocity.dart'
    show VelocityBandVerdict;
import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart'
    show kFireComponentMaxPressureKpa;
import 'package:mechx_engine/sizing/network_sizing.dart'
    show CheckValveAmbiguity;
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';

import '../data/project_document.dart' show IssueAck;
import '../ui/strings/app_strings.dart';
import '../ui/strings/plural.dart';
import 'air_warnings_store.dart';
import 'annotation_store.dart' show roomAreasProvider, roomSizingProvider, roomTerminalOwnerOf;
import 'app_state.dart';
import 'document_control_store.dart';
import 'electrical_feed.dart' show mepDutyBindingProvider;
import 'electrical_store.dart';
import 'fire_store.dart'
    show
        fireOverPressureProvider,
        firePumpDutyProvider,
        fireSystemBasesProvider,
        sprinklerPumpCheckProvider;
import 'history_store.dart' show SettingsUndoEntry, settingsHistoryProvider;
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

  /// I6 — a NON-spatial target: the Document control inspector section (not a
  /// sheet, node or panel). When true the Review row jumps to the DESIGN Layout
  /// view and expands the Document control section rather than selecting a
  /// drawn element. Additive: defaults false so every existing location is
  /// unchanged.
  final bool documentControl;

  const IssueLocation(
    this.sheetId, {
    this.nodeId,
    this.edgeId,
    this.panelId,
    this.circuitId,
    this.documentControl = false,
  });

  @override
  bool operator ==(Object other) =>
      other is IssueLocation &&
      other.sheetId == sheetId &&
      other.nodeId == nodeId &&
      other.edgeId == edgeId &&
      other.panelId == panelId &&
      other.circuitId == circuitId &&
      other.documentControl == documentControl;

  @override
  int get hashCode =>
      Object.hash(sheetId, nodeId, edgeId, panelId, circuitId, documentControl);
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
/// The unconnected-element defects of the (drag-frozen) network, computed ONCE
/// per edit for the issue fan-in and its batch actions (drafting-feel perf —
/// each read used to re-walk the whole network).
final networkElementDefectsProvider = Provider<List<NetworkElementDefect>>(
    (ref) => networkElementDefects(ref.watch(sizingNetworkProvider)));

final designIssuesProvider = Provider<List<DesignIssue>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final project = ref.watch(projectControllerProvider);
  final sheets = ref.watch(sheetsContentProvider);
  final velocity = ref.watch(airVelocityChecksProvider);
  final unsized = ref.watch(airUnsizedProvider);
  // M3/M4 — the discipline-neutral over-capacity set (air + storm + water),
  // not the air-only view: a clamped downpipe / over-velocity supply pipe used
  // to be computed and dropped.
  final overCapacity = ref.watch(overCapacityEdgesProvider);
  final belowCodeMinimum = ref.watch(belowCodeMinimumEdgesProvider);
  final waterVelocity = ref.watch(waterVelocityChecksProvider);
  final selfCleansing = ref.watch(selfCleansingDefectsProvider);
  final loopUnbalanced = ref.watch(loopUnbalancedEdgesProvider);
  final demandExtrapolated = ref.watch(demandCurveExtrapolatedEdgesProvider);
  final drainAdvisories = ref.watch(drainageAdvisoryProvider);
  final legionellaReturnTempC = ref.watch(hotWaterLegionellaProvider);
  final sprinklerPump = ref.watch(sprinklerPumpCheckProvider);
  final fireBases = ref.watch(fireSystemBasesProvider);
  final fireOverPressure = ref.watch(fireOverPressureProvider);
  final coolingMethod = ref.watch(coolingLoadMethodProvider);
  final rooms = ref.watch(roomAreasProvider);
  final hasRooms = rooms.isNotEmpty;
  final docControl = ref.watch(documentControlProvider);

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

  // ── 2b. Over capacity: the printed size is a TABLE LIMIT (warning) ─────────
  // The sizer clamps rather than aborting the solve and flags
  // `EdgeSizing.overCapacity`. Wave 1 widened that flag past air, so this fan-in
  // is service-aware (M3/M4): an AIR duct clamped at the largest standard duct,
  // a STORM downpipe whose catchment exceeds the largest tabulated size, or a
  // WATER SUPPLY run that cannot hold the SNI 2,0 m/s cap at any DN in the
  // series. One flag, three honest messages — each naming the action that
  // actually fixes it (split the run / split the roof outlets / split the flow).
  for (final id in overCapacity) {
    final edge = edgeById[id];
    if (edge == null) continue;
    final sheetId = sheetForEdge(edge);
    final (kind, title, message) = switch (edge.service) {
      _ when edge.service.isAir => (
          'duct-over-capacity',
          str(StringKey.issueDuctOverCapacityTitle),
          str(StringKey.issueDuctOverCapacityMessage),
        ),
      // Audit 2026-10 wd-2 — a horizontal rainwater COLLECTOR is Manning-sized;
      // past the largest drain it needs splitting, not more downpipes.
      ServiceType.rainwater when edge.kind != EdgeKind.riser => (
          'storm-collector-over-capacity',
          str(StringKey.issueStormCollectorOverCapacityTitle),
          str(StringKey.issueStormCollectorOverCapacityMessage),
        ),
      // Audit 2026-10 wd-4 — the DFU load is past the top row of its table.
      ServiceType.drainage || ServiceType.vent => (
          'drainage-over-capacity',
          str(StringKey.issueDrainageOverCapacityTitle),
          str(StringKey.issueDrainageOverCapacityMessage),
        ),
      ServiceType.rainwater => (
          'storm-over-capacity',
          str(StringKey.issueStormOverCapacityTitle),
          str(StringKey.issueStormOverCapacityMessage),
        ),
      _ => (
          'water-over-capacity',
          str(StringKey.issueWaterOverCapacityTitle),
          str(StringKey.issueWaterOverCapacityMessage),
        ),
    };
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: kind,
      title: title,
      message: message,
      locate: sheetId == null ? null : IssueLocation(sheetId, edgeId: id),
    ));
  }

  // ── 2b-i. Hand-picked gravity size BELOW the code minimum (warning) ───────
  // Round 17 (gravity-3-1) — a drain / vent / downpipe override smaller than
  // the DFU / WC-count / trap floor or the downpipe / Manning capacity.
  for (final id in belowCodeMinimum) {
    final edge = edgeById[id];
    if (edge == null) continue;
    final sheetId = sheetForEdge(edge);
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'gravity-below-code-minimum',
      title: str(StringKey.issueBelowCodeMinimumTitle),
      message: str(StringKey.issueBelowCodeMinimumMessage),
      locate: sheetId == null ? null : IssueLocation(sheetId, edgeId: id),
    ));
  }

  // ── 2b-ii. Out-of-band WATER / DRAINAGE velocity (M4/M5, warning) ──────────
  // The air twin of this fan-in has existed since Wave 3; the water/drainage
  // one never did, so an `sniVerbatim` 2,0 m/s supply-velocity violation shipped
  // silently (it showed only in the edge inspector, if the engineer happened to
  // select that run).
  //
  // The gravity TOO-LOW case is deliberately NOT emitted here: it is exactly the
  // self-cleansing finding below, which carries the actionable message. Emitting
  // both would print the same physics twice on one edge (the drainage band's
  // minimum IS the self-cleansing floor, judged on the same full-bore Manning
  // velocity). G1 — since the engine now raises `selfCleansingOk == false` only
  // for a run sized ABOVE its DFU-table minimum, a code-minimum branch that runs
  // slow emits NEITHER row: at the minimum no pipe change is available, so the
  // only honest levers (the laid slope, the grouped discharge) belong to the
  // slope input and the min-slope advisory below — not to a per-edge warning
  // that could name no action.
  for (final entry in waterVelocity.entries) {
    final check = entry.value;
    if (!check.isWarning) continue;
    final edge = edgeById[entry.key];
    if (edge == null) continue;
    if (edge.service.regime == FlowRegime.gravity &&
        check.verdict == VelocityBandVerdict.tooLow) {
      continue; // owned by the self-cleansing advisory below
    }
    // G2 — the OVER-CAPACITY case is owned by 2b-i above: a run clamped at the
    // largest tabulated size is over-velocity BY CONSTRUCTION (the clamp is what
    // pushed it there), so emitting `water-velocity:<id>` as well prints the
    // same physics twice on one edge with the weaker advice. Mirrors the gravity
    // dedupe directly above (that guard proved the pattern); the over-capacity
    // row carries the actionable message ("split the flow / split the run").
    if (overCapacity.contains(entry.key)) continue;
    final sheetId = sheetForEdge(edge);
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'water-velocity:${entry.key}',
      title: str(StringKey.issueWaterVelocityTitle),
      // Engine-sourced message (`3.4 m/s — too high (> 2.0)`) like its air twin.
      message: check.message,
      locate:
          sheetId == null ? null : IssueLocation(sheetId, edgeId: entry.key),
    ));
  }

  // ── 2b-iii. Drainage branch below the self-cleansing velocity (info) ───────
  // `EdgeSizing.selfCleansingOk` (Wave 1) is false when the full-bore Manning
  // velocity at the design slope falls under 0.6 m/s AND the run is sized ABOVE
  // the DFU table's minimum for its load (G1) — i.e. a smaller compliant pipe
  // genuinely exists. An ADVISORY, not a warning: the diameter is still legal,
  // and the honest remedies are the design slope (a Building-page input) or
  // grouping more discharge onto the branch.
  //
  // Service-aware: a RAINWATER collector carries no DFU table and no grouped
  // fixture discharge — it is auto-sized on the storm runoff alone — so the
  // drainage copy ("group more discharge onto the branch", "larger than the
  // DFU minimum") is false for it. It gets its own kind + copy whose only
  // lever is the one it genuinely has: the laid slope.
  for (final id in selfCleansing) {
    final edge = edgeById[id];
    if (edge == null) continue;
    final sheetId = sheetForEdge(edge);
    final rainwater = edge.service == ServiceType.rainwater;
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: rainwater ? 'rainwater-self-cleansing' : 'drainage-self-cleansing',
      title: str(rainwater
          ? StringKey.issueRainwaterSelfCleansingTitle
          : StringKey.issueSelfCleansingTitle),
      message: str(rainwater
          ? StringKey.issueRainwaterSelfCleansingMessage
          : StringKey.issueSelfCleansingMessage),
      locate: sheetId == null ? null : IssueLocation(sheetId, edgeId: id),
    ));
  }

  // ── 2b-iii-b. Plumbing fixture placed with no fixture TYPE (F5, info) ──────
  // A terminal dropped on a water-supply or sanitary run with no `fixture` (and
  // no resolved custom fixture) is not sized on nothing — it is sized on the
  // REPRESENTATIVE PLACEHOLDER the engine substitutes for an untyped leaf:
  // `kDefaultLeafFixtureUnits` (2.0 UBAP) on cold/hot water and
  // `kDefaultLeafDfu` (2.0 DFU) on drainage/vent. That placeholder then flows
  // into the accumulated demand, the mains, the pump duty, the BOM and the
  // issued report with no marker anywhere — the plumbing twin of the air side's
  // `air-terminal-unsized` advisory, which never existed until now.
  //
  // Gated to the services that actually apply a placeholder: the UBAP path is
  // cold/hot water only (the fire services size from a flow default, not
  // fixture units) and the DFU path is drainage/vent. An advisory, not a
  // warning: the number IS a defensible representative load, so the design is
  // sizable — it is the SILENCE that was dishonest. Locatable to the node.
  for (final n in net.nodes) {
    if (n.role != NodeRole.fixture) continue;
    if (n.fixture != null || n.customFixtureId != null) continue;
    var onSupply = false;
    var onSanitary = false;
    for (final e in net.edgesAt(n.id)) {
      switch (e.service) {
        case ServiceType.coldWater:
        case ServiceType.hotWater:
          onSupply = true;
        case ServiceType.drainage:
        case ServiceType.vent:
          onSanitary = true;
        default:
          break;
      }
    }
    if (!onSupply && !onSanitary) continue;
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'fixture-untyped:${n.id}',
      title: str(StringKey.issueFixtureUntypedTitle),
      // A fixture on BOTH systems (the normal case) leads with the supply
      // placeholder — it is the one that drives the diversified demand and the
      // pump duty; the drainage-only message names the DFU default instead.
      message: onSupply
          ? str(StringKey.issueFixtureUntypedSupplyMessage)
          : str(StringKey.issueFixtureUntypedDrainageMessage),
      locate: IssueLocation(n.sheetId, nodeId: n.id),
    ));
  }

  // ── 2b-iii-b. Demand past the charted curve (audit 2026-10 wd-6, info) ─────
  // The UBAP → flow curve is continued linearly beyond its last charted point
  // (3000 UBAP) instead of clamping flat; the extrapolated flow is surfaced as
  // an advisory so the engineer confirms the main / pump flow.
  for (final id in demandExtrapolated) {
    final edge = edgeById[id];
    if (edge == null) continue;
    final sheetId = sheetForEdge(edge);
    warnings.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'demand-curve-extrapolated',
      title: str(StringKey.issueDemandCurveExtrapolatedTitle),
      message: str(StringKey.issueDemandCurveExtrapolatedMessage),
      locate: sheetId == null ? null : IssueLocation(sheetId, edgeId: id),
    ));
  }

  // ── 2b-iv. Unsettled ring: Hardy-Cross did not converge (M17, warning) ─────
  // The carried flow still satisfies continuity at every node, but the loop
  // head-loss balance was never achieved — so the split, and every size derived
  // from it, is PROVISIONAL. Previously unobservable anywhere in the app.
  for (final id in loopUnbalanced) {
    final edge = edgeById[id];
    if (edge == null) continue;
    final sheetId = sheetForEdge(edge);
    // Round 12 — on a GRAVITY service the flag marks a loop's CLOSING edge
    // (nearest-outlet tree, sized on the larger adjacent load), not a
    // Hardy–Cross non-convergence: say so.
    final gravity = edge.service.regime == FlowRegime.gravity;
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'loop-unbalanced',
      title: str(gravity
          ? StringKey.issueGravityLoopTitle
          : StringKey.issueLoopUnbalancedTitle),
      message: str(gravity
          ? StringKey.issueGravityLoopMessage
          : StringKey.issueLoopUnbalancedMessage),
      locate: sheetId == null ? null : IssueLocation(sheetId, edgeId: id),
    ));
  }

  // ── 2b-v. Duty past the largest standard motor frame (M11, info) ───────────
  // `selectMotor` CLAMPS at the top of the standard ladder (315 kW since
  // Round 21; 75 kW before); without this
  // the app printed a 75 kW motor for a 90 kW duty on the canvas, the schedule,
  // the BOM and the electrical feed with no hint the frame had saturated.
  // Non-locatable (it is a plant duty, not a drawn element).
  //
  // G4 — an ADVISORY, not a warning. It is a real and honest finding, but it is
  // NOT a design defect the app can be made to clear: a legitimately large
  // building has a duty past the 75 kW ladder, there is no custom-motor field to
  // fill in, and the honest verdict already rides the Results ResultCard beside
  // the duty figure itself. As a warning it was a permanent, unlocatable and
  // (per `DesignIssue.isAcknowledgeable`) unacknowledgeable compliance blocker —
  // a PASS was unreachable by construction. At [info] it still prints in Review
  // and in the reports, and the engineer can acknowledge it with a reason.
  if (ref.watch(pumpDutyProvider)?.motorOversized ?? false) {
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'pump-motor-oversized',
      title: str(StringKey.issueMotorOversizedTitle),
      message: str(StringKey.issuePumpMotorOversizedMessage),
    ));
  }
  // Round 21 (fire-3-motor-ladder-clamp-feeds-electrical) — the fire pump
  // too: its NFPA 20 governing point past the 315 kW ladder top.
  if (ref.watch(firePumpDutyProvider)?.motorOversized ?? false) {
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'fire-pump-motor-oversized',
      title: str(StringKey.issueMotorOversizedTitle),
      message: str(StringKey.issueFirePumpMotorOversizedMessage),
    ));
  }
  // Round 21 review (fire-3-parallel-fire-pumps) — three or more identical
  // fire pumps: the last-drawn one was ASSUMED to be the jockey (fed a small
  // pressure-maintenance duty). Name it so the engineer can confirm or draw
  // the jockey on its own smaller leg.
  final assumedJockeys =
      ref.watch(mepDutyBindingProvider).fireAssumedJockeyPumpNodeIds.toList()
        ..sort();
  if (assumedJockeys.isNotEmpty) {
    final tags = equipmentNodeTags(net);
    for (final id in assumedJockeys) {
      final n = net.nodeById(id);
      if (n == null) continue;
      infos.add(DesignIssue(
        severity: IssueSeverity.info,
        kind: 'fire-jockey-assumed:$id',
        title: str(StringKey.issueFireJockeyAssumedTitle),
        message: str.format(StringKey.issueFireJockeyAssumedMessage,
            {'tag': tags[id] ?? id}),
        locate: IssueLocation(n.sheetId, nodeId: id),
      ));
    }
  }
  // Round 27 r3 (binding check-valve decision) — the drawn direction of a
  // check valve is authoritative: a hot-water valve read as a FEED into a
  // loop the heater already feeds is sized as drawn (it carries draw-off).
  // Topology cannot tell a genuine second feed from a recirculation return
  // drawn backwards, so name it (judge-only) instead of re-reading it.
  final feedsRing = ref.watch(checkValveFeedsRingProvider).toList()..sort();
  for (final id in feedsRing) {
    final n = net.nodeById(id);
    if (n == null) continue;
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'check-valve-feeds-ring:$id',
      title: str(StringKey.issueCheckValveFeedsRingTitle),
      message: str(StringKey.issueCheckValveFeedsRingMessage),
      locate: IssueLocation(n.sheetId, nodeId: id),
    ));
  }
  // Round 27 r5 (binding check-valve decision) — a cycle check valve drawn
  // with NO direction cannot be read from topology: the sizer assumed it
  // conservatively (closed return / plain pipe / standby leg). Name each so
  // the engineer redraws it instead of trusting the assumption.
  final ambiguousValves = ref.watch(checkValveAmbiguousProvider);
  for (final id in ambiguousValves.keys.toList()..sort()) {
    final n = net.nodeById(id);
    if (n == null) continue;
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'check-valve-ambiguous:$id',
      // Round 27 r6 — a DRAWN valve pointing back at its own pump / the
      // source is not direction-less: it carries its own title.
      // Round 27 r7 — the envelope and the balance-against-pump readings
      // carry their own titles too.
      title: str(switch (ambiguousValves[id]!) {
        CheckValveAmbiguity.drawnAgainstSupplyLeg =>
          StringKey.issueCheckValveAgainstSupplyTitle,
        CheckValveAmbiguity.envelope => StringKey.issueCheckValveEnvelopeTitle,
        CheckValveAmbiguity.balanceAgainstPump =>
          StringKey.issueCheckValveAgainstPumpTitle,
        _ => StringKey.issueCheckValveAmbiguousTitle,
      }),
      message: str(switch (ambiguousValves[id]!) {
        CheckValveAmbiguity.closedReturn =>
          StringKey.issueCheckValveAmbiguousClosedMessage,
        CheckValveAmbiguity.plainPipe =>
          StringKey.issueCheckValveAmbiguousPipeMessage,
        CheckValveAmbiguity.standbySet =>
          StringKey.issueCheckValveAmbiguousStandbyMessage,
        CheckValveAmbiguity.supplyLeg =>
          StringKey.issueCheckValveAmbiguousSupplyMessage,
        CheckValveAmbiguity.drawnAgainstSupplyLeg =>
          StringKey.issueCheckValveAgainstSupplyMessage,
        CheckValveAmbiguity.envelope =>
          StringKey.issueCheckValveEnvelopeMessage,
        CheckValveAmbiguity.balanceAgainstPump =>
          StringKey.issueCheckValveAgainstPumpMessage,
      }),
      locate: IssueLocation(n.sheetId, nodeId: id),
    ));
  }
  // Round 27 r8 — a VALVELESS pump leg whose balanced split runs against
  // the drawn pump: sized on the envelope (leg closed / leg open), never
  // backwards through the pump. Named on the pump node.
  for (final id in ref.watch(moverAgainstBalanceProvider).toList()..sort()) {
    final n = net.nodeById(id);
    if (n == null) continue;
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'mover-against-balance:$id',
      title: str(StringKey.issueMoverAgainstBalanceTitle),
      message: str(StringKey.issueMoverAgainstBalanceMessage),
      locate: IssueLocation(n.sheetId, nodeId: id),
    ));
  }
  if (ref.watch(ductFanProvider)?.motorOversized ?? false) {
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'fan-motor-oversized',
      title: str(StringKey.issueMotorOversizedTitle),
      message: str(StringKey.issueFanMotorOversizedMessage),
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

  // ── 3. Uncalibrated sheets (info, or CRITICAL when edges are drawn) ─────────
  // An uncalibrated sheet that already carries drawn runs is a BLOCKER: every
  // run on it sizes to ZERO length (edgeLength returns Length(0) for an
  // uncalibrated run), so the BOM / pressures / report are silently wrong. A
  // BLANK uncalibrated sheet (nothing drawn on it yet) has nothing measurable
  // to be wrong — it's an honesty ADVISORY ("calibrate before you draw"), not
  // a warning, so it drops to [IssueSeverity.info] (and no longer blocks a
  // compliance PASS on its own). We escalate only the edge-bearing ones; the
  // title is kept ('… calibrated') so the compliance roll-up and any title
  // match still catch it.
  // Round 34 — only RUN edges count: a riser's length is the §10 true-
  // elevation delta (golden rule 3), independent of any calibration, so a
  // sheet holding only riser ends has nothing that sizes to zero and stays
  // an advisory.
  final nodeSheet = {for (final n in net.nodes) n.id: n.sheetId};
  final sheetsWithEdges = <String>{
    for (final e in net.edges)
      if (e.kind == EdgeKind.run) ...[
        if (nodeSheet[e.fromId] != null) nodeSheet[e.fromId]!,
        if (nodeSheet[e.toId] != null) nodeSheet[e.toId]!,
      ],
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
      infos.add(DesignIssue(
        severity: IssueSeverity.info,
        kind: 'sheet-uncalibrated:${s.id}',
        title: str(StringKey.issueSheetNotCalibratedTitle),
        message: str.format(
            StringKey.issueSheetNotCalibratedInfoMessage, {'name': s.name}),
        locate: IssueLocation(s.id),
      ));
    }
  }

  // ── 3b. Stale calibration since the last plan swap (warning, locatable) ────
  // "Replace plan…" swaps a sheet's PDF/DXF/DWG source in place but keeps the
  // sheet id — so its calibration (keyed by id) silently survives even when
  // the revised drawing has a different DPI/plot scale/title block. Flagged by
  // `SheetsController.replaceSheetSource` via
  // `ProjectController.markCalibrationStale`; cleared by re-calibrating or the
  // Scale inspector's explicit "Scale confirmed" action (J1).
  for (final s in sheets.sheets) {
    if (!project.staleCalibrations.contains(s.id)) continue;
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'sheet-calibration-stale:${s.id}',
      title: str(StringKey.issueCalibrationStaleTitle),
      message:
          str.format(StringKey.issueCalibrationStaleMessage, {'name': s.name}),
      locate: IssueLocation(s.id),
    ));
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
  // Round 34 — the nodes of components already reported as no-source /
  // island: their loose ends are the SAME defect, never a second and third
  // row (one isolated 2-node riser read as three issues).
  final componentReportedNodes = <String>{};
  for (final d in networkConnectivityDefects(net)) {
    final repId = d.representativeNodeId;
    final repNode = repId == null ? null : nodeById[repId];
    // The stable, locale-independent ack key keeps the enum identifier; the
    // message prints the localized human service name (R6).
    final service = d.service.name;
    final serviceName = str(_serviceNameKey(d.service));
    final n = d.nodeIds.length;
    // Round 25 — a water network fed straight from the mains through a drawn
    // meter is not a drawing defect: an ACKNOWLEDGEABLE info (the mains
    // pressure is not modelled), never the blocking no-source warning that a
    // direct-from-PDAM building could only clear by drawing a fake tank.
    if (d.isMainsFed) {
      // Round 29 (ui-journeys-3-feed-shown-three-ways) — on the UPFEED
      // setting the solve sizes an assumed upfeed pump at the meter (the
      // schedule + electrical feed carry it), so 'mains pressure is not
      // modelled' would contradict them: ONE story — the pump is assumed,
      // not drawn.
      if (ref.watch(feedStrategyProvider) == FeedStrategy.upfeed &&
          d.service == ServiceType.coldWater) {
        infos.add(DesignIssue(
          severity: IssueSeverity.info,
          kind: 'upfeed-pump-assumed:$service',
          title: str(StringKey.issueUpfeedAssumedTitle),
          message: str.format(StringKey.issueUpfeedAssumedMessage, {
            'service': serviceName,
            'nodes': pluralCount(n, str(StringKey.issueNounNodeOne),
                str(StringKey.issueNounNodeMany)),
          }),
          locate: repNode == null
              ? null
              : IssueLocation(repNode.sheetId, nodeId: repId),
        ));
        continue;
      }
      infos.add(DesignIssue(
        severity: IssueSeverity.info,
        kind: 'mains-fed:$service',
        title: str(StringKey.issueMainsFedTitle),
        message: str.format(StringKey.issueMainsFedMessage, {
          'service': serviceName,
          'nodes': pluralCount(n, str(StringKey.issueNounNodeOne),
              str(StringKey.issueNounNodeMany)),
        }),
        locate: repNode == null
            ? null
            : IssueLocation(repNode.sheetId, nodeId: repId),
      ));
      continue;
    }
    final title = d.isIsland
        ? str(StringKey.issueNetworkIslandTitle)
        : str(StringKey.issueNetworkNoSourceTitle);
    final defectKind =
        d.isIsland ? 'network-island:$service' : 'no-source:$service';
    componentReportedNodes.addAll(d.nodeIds);
    final nodeWord = pluralCount(
        n, str(StringKey.issueNounNodeOne), str(StringKey.issueNounNodeMany));
    final message = d.isIsland
        ? str.format(StringKey.issueNetworkIslandMessage,
            {'service': serviceName, 'nodes': nodeWord})
        : str.format(StringKey.issueNetworkNoSourceMessage,
            {'service': serviceName, 'nodes': nodeWord});
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
  for (final d in ref.watch(networkElementDefectsProvider)) {
    // Round 34 — a loose end of a component already reported above is not
    // repeated (orphans keep their own row).
    if (!d.isOrphan && componentReportedNodes.contains(d.nodeId)) continue;
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

  // ── 3e. UPFEED fixture over-pressure (mech-building-2) ─────────────────────
  // The downfeed PRV zones above are compliant by construction and say
  // nothing about an UPFEED riser, whose pump delivers nearly its whole head
  // to the lowest fixtures. Each delivery node whose flowing residual or
  // no-flow static exceeds the SNI max fixture pressure is its own WARNING; at
  // the mandatory pressure-relief threshold it is CRITICAL. Judge-only,
  // locatable to the node.
  final overPressure = ref.watch(upfeedOverPressureProvider);
  if (overPressure.isNotEmpty) {
    const sni = SniProfile();
    final maxFixKpa = sni.maxFixtureStaticPressure.value.inKiloPascals;
    final reliefKpa = sni.mandatoryPressureReliefThreshold.value.inKiloPascals;
    final floors = project.building.floors;
    for (final o in overPressure) {
      final node = nodeById[o.nodeId];
      final floorName = node == null || floors.isEmpty
          ? ''
          : floors[node.floorIndex.clamp(0, floors.length - 1)].name;
      warnings.add(DesignIssue(
        severity:
            o.overRelief ? IssueSeverity.critical : IssueSeverity.warning,
        kind: 'upfeed-over-pressure:${o.nodeId}',
        title: o.overRelief
            ? str(StringKey.issueUpfeedOverReliefTitle)
            : str(StringKey.issueUpfeedOverPressureTitle),
        message: str.format(StringKey.issueUpfeedOverPressureMessage, {
          'floor': floorName,
          'flowing': o.flowing.inKiloPascals.toStringAsFixed(0),
          'static': o.noFlow.inKiloPascals.toStringAsFixed(0),
          'limit': maxFixKpa.toStringAsFixed(0),
          'relief': reliefKpa.toStringAsFixed(0),
        }),
        locate: node == null
            ? null
            : IssueLocation(node.sheetId, nodeId: o.nodeId),
      ));
    }
  }

  // ── 3f. DOWNFEED fixture over-pressure (Round 16) ─────────────────────────
  // The zone table above assumes a PRV at every zone top; this judges what is
  // DRAWN: the gravity solve holds each drawn PRV's setpoint, and any delivery
  // node still over the SNI fixture maximum is a WARNING (CRITICAL at the
  // mandatory relief threshold). Judge-only, locatable to the node.
  final downOver = ref.watch(downfeedOverPressureProvider);
  if (downOver.isNotEmpty) {
    const sni = SniProfile();
    final maxFixKpa = sni.maxFixtureStaticPressure.value.inKiloPascals;
    final reliefKpa = sni.mandatoryPressureReliefThreshold.value.inKiloPascals;
    final floors = project.building.floors;
    for (final o in downOver) {
      final node = nodeById[o.nodeId];
      final floorName = node == null || floors.isEmpty
          ? ''
          : floors[node.floorIndex.clamp(0, floors.length - 1)].name;
      warnings.add(DesignIssue(
        severity:
            o.overRelief ? IssueSeverity.critical : IssueSeverity.warning,
        kind: 'downfeed-over-pressure:${o.nodeId}',
        title: o.overRelief
            ? str(StringKey.issueDownfeedOverReliefTitle)
            : str(StringKey.issueDownfeedOverPressureTitle),
        message: str.format(StringKey.issueDownfeedOverPressureMessage, {
          'floor': floorName,
          'flowing': o.flowing.inKiloPascals.toStringAsFixed(0),
          'static': o.noFlow.inKiloPascals.toStringAsFixed(0),
          'limit': maxFixKpa.toStringAsFixed(0),
          'relief': reliefKpa.toStringAsFixed(0),
        }),
        locate: node == null
            ? null
            : IssueLocation(node.sheetId, nodeId: o.nodeId),
      ));
    }
  }

  // ── 3g. DOWNFEED below the target residual (Round 25) ─────────────────────
  // A drawn roof tank whose gravity head (less friction) leaves the worst-
  // served delivery node below the target residual needs a booster or a
  // higher tank. Judged on what the drawn system DELIVERS (sized boosters
  // running); the inspector card and the calc report already say 'boost', so
  // Review / compliance must not stay silent (an under-pressure downfeed could
  // print PASS). Judge-only, locatable to the critical node.
  //
  // Round 32 (binding-1) — TWO thresholds, ONE kind: the 225 kPa target is a
  // COMFORT target; the SNI 8153 floor is the minimum delivery pressure at
  // the critical node (49 kPa at a faucet, 98 kPa when a flush valve lies on
  // its supply path — [downfeedSniMinimumResidualProvider]). Below the SNI
  // floor ⇒ a blocking WARNING citing it; between floor and target ⇒ an
  // acknowledgeable INFO advisory ('SNI minimum met, booster recommended').
  // The kind stays `downfeed-below-target` so acks / compliance matching hold.
  //
  // Round 33 (regression-sni-minimum-judged-only-at-critical-node) — the SNI
  // floor is judged at EVERY delivery node against its OWN floor
  // ([downfeedSniFloorsProvider]): a flush-valve WC at 83 kPa elsewhere
  // fails although the faucet-fed critical node meets its 49 kPa. Below any
  // floor ⇒ the warning names the LARGEST shortfall node (its floor, its
  // residual, locate); otherwise the info advisory at the critical node.
  if (ref.watch(gravityDownfeedDrawnProvider)) {
    final delivered = ref.watch(downfeedDeliveredProvider);
    if (delivered != null && !delivered.gravitySufficient) {
      final short = worstSniShortfall(
          floors: ref.watch(downfeedSniFloorsProvider),
          residual: delivered.residualPressure);
      final belowSni = short != null;
      final node = nodeById[short?.nodeId ?? delivered.criticalNodeId];
      final floors = project.building.floors;
      final floorName = node == null || floors.isEmpty
          ? ''
          : floors[node.floorIndex.clamp(0, floors.length - 1)].name;
      final sniMin = short?.floor ??
          ref.watch(downfeedSniMinimumResidualProvider) ??
          const SniProfile().minResidualPressureFaucet.value;
      final residualShown = short?.residual ?? delivered.minResidual;
      warnings.add(DesignIssue(
        severity: belowSni ? IssueSeverity.warning : IssueSeverity.info,
        kind: 'downfeed-below-target',
        title: str(belowSni
            ? StringKey.issueDownfeedBelowTargetTitle
            : StringKey.issueDownfeedBelowComfortTitle),
        message: str.format(
            belowSni
                ? StringKey.issueDownfeedBelowTargetMessage
                : StringKey.issueDownfeedBelowComfortMessage,
            {
          'floor': floorName,
          'sni': sniMin.inKiloPascals.toStringAsFixed(0),
          'residual': residualShown.inKiloPascals.toStringAsFixed(0),
          'target': ref
              .watch(targetResidualProvider)
              .inKiloPascals
              .toStringAsFixed(0),
          'head': delivered.boosterHeadRequired.meters.toStringAsFixed(1),
        }),
        locate: node == null
            ? null
            : IssueLocation(node.sheetId, nodeId: node.id),
      ));
    }
  }

  // ── 3h. UPFEED below the target residual (Round 25 follow-up) ─────────────
  // The upfeed pump is sized so every delivery node meets the target — unless
  // a drawn reducing PRV cuts the field afterwards (Round 23:
  // `targetHeldByDesign` false, critical node re-picked as the least-residual
  // delivery node). Then the shortfall is a real finding: Review says so and
  // the compliance 'Supply pressure' row claims it, never a vacuous PASS.
  // Round 32 (binding-1) — the same SNI-floor / comfort-target split as 3g.
  // Round 33 — judged on the DELIVERED upfeed field (drawn movers at their
  // own duties, [upfeedDeliveredProvider]) with the per-node SNI floor.
  final upfeed = ref.watch(upfeedDeliveredProvider);
  if (upfeed != null && !upfeed.targetHeldByDesign) {
    final target = ref.watch(targetResidualProvider);
    final critical = upfeed.residualPressure[upfeed.criticalNodeId];
    if (critical != null &&
        critical.inKiloPascals < target.inKiloPascals - 0.5) {
      final short = worstSniShortfall(
          floors: ref.watch(upfeedSniFloorsProvider),
          residual: upfeed.residualPressure);
      final belowSni = short != null;
      final worst = short?.residual ?? critical;
      final node = nodeById[short?.nodeId ?? upfeed.criticalNodeId];
      final floors = project.building.floors;
      final floorName = node == null || floors.isEmpty
          ? ''
          : floors[node.floorIndex.clamp(0, floors.length - 1)].name;
      final sniMin = short?.floor ??
          ref.watch(upfeedSniMinimumResidualProvider) ??
          const SniProfile().minResidualPressureFaucet.value;
      warnings.add(DesignIssue(
        severity: belowSni ? IssueSeverity.warning : IssueSeverity.info,
        kind: 'upfeed-below-target',
        title: str(belowSni
            ? StringKey.issueUpfeedBelowTargetTitle
            : StringKey.issueUpfeedBelowComfortTitle),
        message: str.format(
            belowSni
                ? StringKey.issueUpfeedBelowTargetMessage
                : StringKey.issueUpfeedBelowComfortMessage,
            {
          'floor': floorName,
          'sni': sniMin.inKiloPascals.toStringAsFixed(0),
          'residual': worst.inKiloPascals.toStringAsFixed(0),
          'target': target.inKiloPascals.toStringAsFixed(0),
        }),
        locate: node == null
            ? null
            : IssueLocation(node.sheetId, nodeId: node.id),
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
      DrainageAdvisoryKind.laidSteeperThanProject => (
          str(StringKey.issueDrainageLaidSteeperTitle),
          'drainage-laid-steeper'
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

  // ── 5a-bis. Sprinkler demand vs the one scheduled fire pump (audit r8) ──────
  // Judge-only: the fire pump is rated on the standpipe duty; a drawn sprinkler
  // system whose design-area demand / pressure that pump cannot meet is a real
  // design finding (warning — blocks a PASS, never acknowledgeable).
  if (sprinklerPump != null && sprinklerPump.flowShort) {
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'sprinkler-flow-exceeds-fire-pump',
      title: str(StringKey.issueSprinklerFlowTitle),
      message: str.format(StringKey.issueSprinklerFlowMessage, {
        'demand': sprinklerPump.demandLps.toStringAsFixed(1),
        'pump': sprinklerPump.pumpLps.toStringAsFixed(1),
      }),
    ));
  }
  if (sprinklerPump != null && sprinklerPump.headShort) {
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'sprinkler-head-exceeds-fire-pump',
      title: str(StringKey.issueSprinklerHeadTitle),
      message: str.format(StringKey.issueSprinklerHeadMessage, {
        'need': sprinklerPump.requiredHeadM.toStringAsFixed(1),
        'pump': sprinklerPump.pumpHeadM.toStringAsFixed(1),
      }),
    ));
  }

  // ── 5a-ter. Combined fire system rated on its sprinkler point (warning) ───
  // Round 37 r2 — a combined sprinkler + hydrant system is rated on the
  // LARGER head at that basis's own flow (never Σ of the two conditions).
  // When the sprinkler head wins, the rated point carries the small
  // remote-area flow, so the hose (standpipe) flow at the standpipe head is
  // not a rated point of the pump — judge-only, never resizes; locatable to
  // the duty pump.
  for (final b in fireBases) {
    final st = b.standpipe;
    if (!b.sprinklerGovernsCombined || st == null) continue;
    final pumpNode =
        b.pumpIds.isEmpty ? null : net.nodeById(b.pumpIds.first);
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'combined-fire-sprinkler-governs'
          '${b.pumpIds.isEmpty ? '' : ':${b.pumpIds.first}'}',
      title: str(StringKey.issueCombinedFireSprinklerGovernsTitle),
      message: str.format(StringKey.issueCombinedFireSprinklerGovernsMessage, {
        'sprHead': b.head.meters.toStringAsFixed(1),
        'sprFlow': b.flow.inLitersPerSecond.toStringAsFixed(1),
        'hoseFlow': st.requiredFlow.inLitersPerSecond.toStringAsFixed(1),
        'hoseHead': st.pumpHead.meters.toStringAsFixed(1),
      }),
      locate: pumpNode == null
          ? null
          : IssueLocation(pumpNode.sheetId, nodeId: pumpNode.id),
    ));
  }

  // Round 48 (mech-convergence-3-fire-pressure-rating-unjudged) — a fire
  // pump whose churn pressure exceeds the standard component rating
  // (175 psi): judge-only, locatable to the duty pump.
  for (final o in fireOverPressure) {
    final b = o.basis;
    final pumpNode = b.pumpIds.isEmpty ? null : net.nodeById(b.pumpIds.first);
    final share = o.check.frictionShare;
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'fire-system-over-pressure'
          '${b.pumpIds.isEmpty ? '' : ':${b.pumpIds.first}'}',
      title: str(StringKey.issueFireOverPressureTitle),
      message: str.format(StringKey.issueFireOverPressureMessage, {
        'churn': o.check.churnKpa.toStringAsFixed(0),
        'limit': kFireComponentMaxPressureKpa.toStringAsFixed(0),
        'head': b.head.meters.toStringAsFixed(1),
        'share': share == null
            ? ''
            : str.format(StringKey.issueFireOverPressureShare,
                {'pct': (share * 100).toStringAsFixed(0)}),
      }),
      locate: pumpNode == null
          ? null
          : IssueLocation(pumpNode.sheetId, nodeId: pumpNode.id),
    ));
  }

  // ── 5a-quater. Room terminals stale vs the room requirement (warning) ──────
  // Round 17 follow-up (ui-journeys-3-room-terminals-stale-airflow) — Auto-
  // place stamps a FIXED airflow on each terminal; changing the room's type,
  // ACH or ceiling afterwards left the plan (duct sizing, fan duty, BOM) on the
  // old airflow while the Rooms inspector / equipment schedule showed the new
  // requirement — two airflows for one system, with no warning. Judge-only:
  // for each scaled room carrying terminals with an airflow, the placed supply
  // (diffusers) and extract (return / exhaust grilles) sums are compared with
  // the room's sized banks; a > 1 % difference — or a now-extract-only room
  // still carrying supply diffusers — warns, locatable to a terminal.
  //
  // Round 19 (regression-room-stale-nested-rooms-false-warning) — each
  // terminal belongs to exactly ONE room: the smallest room containing it
  // whose kind it serves (a supply diffuser / return grille → a conditioned
  // room, an exhaust grille → an extract-only room), else the smallest room
  // containing it at all (so a stale diffuser left in a now-extract room still
  // warns). Summing every terminal inside every footprint counted a toilet's
  // exhaust grille as the surrounding office's extract (1.167 vs 1.000 m3/s on
  // freshly auto-placed terminals — a warning Auto-place can never clear).
  final roomSizing = ref.watch(roomSizingProvider);
  final terminalOwner = <String, String?>{
    for (final n in net.nodes)
      if ((isSupplyAirTerminal(n.component) ||
              n.component == NodeComponent.returnGrille ||
              n.component == NodeComponent.exhaustGrille) &&
          n.airflow != null)
        n.id: roomTerminalOwnerOf(n, rooms),
  };
  // Each room's terminals, bucketed ONCE in node order (the per-room scan of
  // every node in the building was O(rooms x nodes) per edit).
  final terminalsByRoom = <String, List<NetNode>>{};
  for (final n in net.nodes) {
    final owner = terminalOwner[n.id];
    if (owner != null) (terminalsByRoom[owner] ??= <NetNode>[]).add(n);
  }
  for (final r in rooms) {
    final sizing = roomSizing[r.id];
    if (sizing == null) continue;
    var placedSupply = 0.0;
    var placedExtract = 0.0;
    var supplyCount = 0;
    var extractCount = 0;
    String? firstTerminal;
    for (final n in terminalsByRoom[r.id] ?? const <NetNode>[]) {
      final c = n.component;
      final isSupply = isSupplyAirTerminal(c);
      final isExtract = c == NodeComponent.returnGrille ||
          c == NodeComponent.exhaustGrille;
      if (!isSupply && !isExtract) continue;
      final q = n.airflow;
      if (q == null) continue;
      if (terminalOwner[n.id] != r.id) continue;
      firstTerminal ??= n.id;
      if (isSupply) {
        placedSupply += q.cubicMetersPerSecond;
        supplyCount++;
      } else {
        placedExtract += q.cubicMetersPerSecond;
        extractCount++;
      }
    }
    if (firstTerminal == null) continue;
    final reqSupply =
        sizing.supply.count * sizing.supply.airflowEach.cubicMetersPerSecond;
    final reqExtract =
        sizing.return_.count * sizing.return_.airflowEach.cubicMetersPerSecond;
    bool stale(double placed, double required, int count) {
      if (count == 0) return false; // that bank has nothing placed to judge
      if (required <= 0) return placed > 0;
      return (placed - required).abs() / required > 0.01;
    }

    final String? bank;
    final double placed;
    final double required;
    if (stale(placedSupply, reqSupply, supplyCount)) {
      bank = str(StringKey.issueRoomBankSupply);
      placed = placedSupply;
      required = reqSupply;
    } else if (stale(placedExtract, reqExtract, extractCount)) {
      bank = str(StringKey.issueRoomBankExtract);
      placed = placedExtract;
      required = reqExtract;
    } else {
      bank = null;
      placed = 0;
      required = 0;
    }
    if (bank == null) continue;
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'room-terminals-stale:${r.id}',
      title: str(StringKey.issueRoomTerminalsStaleTitle),
      message: str.format(StringKey.issueRoomTerminalsStaleMessage, {
        'room': r.name.isEmpty ? r.id : r.name,
        'placed': placed.toStringAsFixed(3),
        'required': required.toStringAsFixed(3),
        'bank': bank,
      }),
      locate: IssueLocation(r.sheetId, nodeId: firstTerminal),
    ));
  }

  // ── 5a-quinquies. Room trunk over capacity (warning) ──────────────────────
  // Round 27 (hvac-4-4) — a room whose airflow exceeds the largest standard
  // trunk is CLAMPED by `sizeRoomAir` (`trunkOverCapacity`); the Rooms
  // inspector used to print the clamped size as 'sized' with nothing in
  // Review, unlike the drawn-network duct (`airOverCapacityProvider`).
  for (final r in rooms) {
    final sizing = roomSizing[r.id];
    if (sizing == null || !sizing.trunkOverCapacity) continue;
    final round = sizing.supplyDuctRound;
    final rect = sizing.supplyDuctRect;
    final size = round != null
        ? 'D${round.diameter.inMillimeters.round()} mm'
        : '${rect!.width.inMillimeters.round()}x'
            '${rect.height.inMillimeters.round()} mm';
    warnings.add(DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'room-trunk-over-capacity:${r.id}',
      title: str(StringKey.issueRoomTrunkOverCapacityTitle),
      message: str.format(StringKey.issueRoomTrunkOverCapacityMessage, {
        'room': r.name.isEmpty ? r.id : r.name,
        'flow': sizing.airflow.cubicMetersPerSecond.toStringAsFixed(2),
        'size': size,
        'velocity': sizing.supplyDuctVelocity.metersPerSecond.toStringAsFixed(1),
      }),
      locate: IssueLocation(r.sheetId),
    ));
  }

  // ── 5a-ter. AC basis honesty (audit r8 fire-hvac-4) ────────────────────────
  // The 'Internal gains' basis omits envelope transmission + solar; while it is
  // active (and rooms exist) the engineer is told so — an INFO advisory.
  if (coolingMethod == CoolingLoadMethod.detailed && hasRooms) {
    infos.add(DesignIssue(
      severity: IssueSeverity.info,
      kind: 'cooling-internal-gains-only',
      title: str(StringKey.issueCoolingInternalOnlyTitle),
      message: str(StringKey.issueCoolingInternalOnlyMessage),
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
  final electricalWarnings = ref.watch(electricalAllWarningsProvider);
  for (final w in electricalWarnings) {
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
      // Round 34 — a localized human title, never the raw code.
      title: str.format(StringKey.issueElectricalTitle,
          {'code': str.electricalWarningTitle(w.code)}),
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
  final electricalProject = ref.watch(electricalSizingProjectProvider);
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

  // ── 5d. Document-control revision inconsistency (I6, info, locatable) ───────
  // The title-block Revision tag (stamped on every issued sheet/report) and the
  // Revision-history table are two independently-typed fields. When the history
  // carries entries but the title-block Revision is left blank, every issued
  // sheet stamps NO revision while the printed history lists changes — the
  // document-control inconsistency a tender reviewer flags. Read-only fan-in (it
  // never mutates document control); locatable to the Document control section.
  // A per-row revision-letter cross-check is deferred (a `Revision` row carries
  // no letter), so this surfaces the one letter-free, false-positive-free case.
  {
    final tag = docControl.revisionTag?.trim() ?? '';
    if (docControl.revisions.isNotEmpty && tag.isEmpty) {
      infos.add(DesignIssue(
        severity: IssueSeverity.info,
        kind: 'revision-tag-missing',
        title: str(StringKey.issueRevisionTagMissingTitle),
        message: str(StringKey.issueRevisionTagMissingMessage),
        locate: const IssueLocation('', documentControl: true),
      ));
    }
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
      // Round 34 (ui-simplicity-5-verify-rows-research-notes) — a short,
      // localized action naming the source; the full provenance note (a
      // research log) stays in the calc report's Unverified-values section.
      message: str.format(
          StringKey.issueUnverifiedMessage, {'citation': v.citation}),
      isVerify: true,
    ));
  }

  for (final v in const SniProfile().verifyChecklist) {
    addVerify(v);
  }
  for (final v in const SniVentilationProfile().verifyChecklist) {
    addVerify(v);
  }
  // Round 31 (ui-simplicity-4) — the PUIL (electrical) verification debt is
  // surfaced only once the project HAS electrical panels: a fresh project
  // never shows a Review badge for electrical constants nothing uses. The
  // electrical calc report keeps printing the full list (guardrail 6).
  if (electricalProject.panels.isNotEmpty) {
    for (final v in const PuilProfile().verifyChecklist) {
      addVerify(v);
    }
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

/// H1 + I4 — the ACKNOWLEDGED advisories, keyed by [DesignIssue.key], each
/// carrying its AUDIT record ([IssueAck]: author initials, app-stamped date,
/// optional justification). An acknowledgement records that the engineer has
/// seen and accepted an advisory (an unverified `secondarySource` standard, a
/// drainage/Legionella note) so it no longer blocks a PASS verdict — errors and
/// warnings are NOT acknowledgeable and always block. Persisted additively with
/// the project via `DesignSettings.acknowledgedIssues` (round-trips in `.mechx`;
/// empty ⇒ byte-identical, and compliance behaves exactly as before).
/// Machine-agnostic: the record travels with the file so a colleague opening it
/// sees the same sign-off state AND who signed it off, when, and why. The map
/// KEYS are the acknowledged issue keys — every reader that only needs the "is
/// this acknowledged?" question uses `.containsKey`.
final acknowledgedIssuesProvider =
    NotifierProvider<AcknowledgedIssuesController, Map<String, IssueAck>>(
  AcknowledgedIssuesController.new,
);

class AcknowledgedIssuesController extends Notifier<Map<String, IssueAck>> {
  @override
  Map<String, IssueAck> build() => const {};

  /// Replace the whole map (used by `applyDocument` on load).
  void set(Map<String, IssueAck> acks) => state = Map.unmodifiable(acks);

  /// Round 25 (ui-journeys-4-undo-skips-riser-drag-and-acknowledge) — every
  /// forward acknowledgement edit is persisted in `.mechx`, so it records ONE
  /// [UndoDomain.settings] step on the global timeline (a registered revert
  /// pair restoring the previous map). Ctrl+Z after 'Acknowledge all' used to
  /// revert an older, unrelated edit instead. [set] / [clear] (load, new
  /// document) stay non-recording.
  void _commit(Map<String, IssueAck> next) {
    final previous = state;
    final applied = Map<String, IssueAck>.unmodifiable(next);
    state = applied;
    ref.read(settingsHistoryProvider.notifier).record(SettingsUndoEntry(
          label: MechXStringsData(ref.read(localeProvider))(
              StringKey.undoLabelAcknowledge),
          undo: () => state = previous,
          redo: () => state = applied,
        ));
  }

  /// Acknowledge one advisory by its [DesignIssue.key], recording who accepted
  /// it ([author]), an optional one-line [note], and the app-stamped [date]
  /// (the engine never reads the clock; the caller passes today's date).
  void acknowledge(String key,
          {String author = '', String note = '', String date = ''}) =>
      _commit({
        ...state,
        key: IssueAck(key: key, author: author, note: note, date: date),
      });

  /// Withdraw an acknowledgement (the row blocks again). A no-op (nothing
  /// recorded) when [key] is not acknowledged.
  void unacknowledge(String key) {
    if (!state.containsKey(key)) return;
    _commit({...state}..remove(key));
  }

  /// Toggle the acknowledgement of [key].
  void toggle(String key,
          {String author = '', String note = '', String date = ''}) =>
      state.containsKey(key)
          ? unacknowledge(key)
          : acknowledge(key, author: author, note: note, date: date);

  /// Acknowledge every currently-OPEN acknowledgeable issue at once (the Review
  /// "Acknowledge all advisories" affordance), stamping them with ONE audit
  /// record ([author]/[note]/[date]) — ONE undo step. [keys] is the set of
  /// acknowledgeable issue keys the caller derived from [designIssuesProvider].
  void acknowledgeAll(Iterable<String> keys,
      {String author = '', String note = '', String date = ''}) {
    if (keys.isEmpty) return;
    _commit({
      ...state,
      for (final k in keys)
        k: IssueAck(key: k, author: author, note: note, date: date),
    });
  }

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
      .where((i) => !(i.isAcknowledgeable && ack.containsKey(i.key)))
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
  final net = ref.watch(sizingNetworkProvider);
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
      mounting: project.mounting,
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

/// F4 — the SHEET IDS carrying the zero-length sized edges the export gate
/// blocks on, in stable edge-list order (deduped). The gate used to name no
/// sheet at all ("N drawn element(s) have zero length"), so the engineer had to
/// go hunting; naming the offending sheets turns the blocker into an
/// instruction. Empty ⇒ the gate is inert (byte-identical). An edge whose
/// endpoint node is missing contributes nothing (never invents a sheet).
final zeroLengthSheetIdsProvider = Provider<List<String>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final project = ref.watch(projectControllerProvider);
  final sizing = ref.watch(sizingProvider);
  final out = <String>[];
  final seen = <String>{};
  for (final e in net.edges) {
    if (!sizing.containsKey(e.id)) continue;
    final len = edgeLength(
      e,
      net,
      calibrationBySheet: project.calibrations,
      building: project.building,
      mounting: project.mounting,
    );
    if (len.meters > 0) continue;
    final sheetId = net.nodeById(e.fromId)?.sheetId;
    if (sheetId == null) continue;
    if (seen.add(sheetId)) out.add(sheetId);
  }
  return List.unmodifiable(out);
});

/// A one-click batch action over a whole CLASS of issues. SAFE by construction —
/// it only SELECTS the offending elements or applies an already-existing bulk op
/// (copy one sheet's calibration to the rest). It never invents geometry or
/// resizes anything; the executor lives in the UI (see `issues_card.dart`).
enum IssueBatchKind {
  /// Multi-select every out-of-band air-velocity element.
  selectVelocityWarnings,

  /// Multi-select every air element carrying air with no chosen size yet.
  selectUnsizedAir,

  /// Multi-select every water/drainage run with an out-of-band velocity
  /// warning (A6 — excludes edges already covered by the over-capacity set,
  /// mirroring the fan-in's dedupe).
  selectWaterVelocity,

  /// Multi-select every clamped-at-table-top edge (air size cap, storm
  /// catchment, water velocity — the discipline-neutral over-capacity set).
  selectOverCapacity,

  /// Multi-select every drainage branch flagged below self-cleansing velocity.
  selectSelfCleansing,

  /// Multi-select every unconnected element (loose run ends + orphans).
  selectUnconnected,

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
  final net = ref.watch(sizingNetworkProvider);
  final project = ref.watch(projectControllerProvider);
  final sheets = ref.watch(sheetsContentProvider);
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

  // A6 — the audit-wave issue classes gain the same select-all treatment.
  final overCap = ref.watch(overCapacityEdgesProvider);
  final waterVel = <String>{
    for (final e in ref.watch(waterVelocityChecksProvider).entries)
      if (e.value.isWarning &&
          edgeIds.contains(e.key) &&
          !overCap.contains(e.key))
        e.key,
  };
  final selfClean = {
    for (final id in ref.watch(selfCleansingDefectsProvider))
      if (edgeIds.contains(id)) id,
  };
  final unconnected = <String>{
    for (final d in ref.watch(networkElementDefectsProvider)) d.nodeId,
  };
  void addSelect(IssueBatchKind kind, StringKey template,
      {Set<String> n = const {}, Set<String> e = const {}}) {
    final c = n.length + e.length;
    if (c == 0) return;
    actions.add(IssueBatchAction(
      kind: kind,
      label: str.format(template, {
        'c': '$c',
        'noun': plural(c, str(StringKey.issueNounElementOne),
            str(StringKey.issueNounElementMany)),
      }),
      enabled: true,
      nodeIds: n,
      edgeIds: e,
    ));
  }

  addSelect(IssueBatchKind.selectWaterVelocity,
      StringKey.issueBatchSelectWaterVelocity,
      e: waterVel);
  addSelect(IssueBatchKind.selectOverCapacity,
      StringKey.issueBatchSelectOverCapacity,
      e: overCap.intersection(edgeIds));
  addSelect(IssueBatchKind.selectSelfCleansing,
      StringKey.issueBatchSelectSelfCleansing,
      e: selfClean);
  addSelect(IssueBatchKind.selectUnconnected,
      StringKey.issueBatchSelectUnconnected,
      n: unconnected);

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

/// The [StringKey] of a service's human, in-sentence name (R6) — what a
/// design-issue message prints instead of the [ServiceType] identifier.
StringKey _serviceNameKey(ServiceType s) => switch (s) {
      ServiceType.coldWater => StringKey.issueServiceColdWater,
      ServiceType.hotWater => StringKey.issueServiceHotWater,
      ServiceType.drainage => StringKey.issueServiceDrainage,
      ServiceType.vent => StringKey.issueServiceVent,
      ServiceType.rainwater => StringKey.issueServiceRainwater,
      ServiceType.duct => StringKey.issueServiceSupplyAir,
      ServiceType.returnAir => StringKey.issueServiceReturnAir,
      ServiceType.exhaust => StringKey.issueServiceExhaust,
      ServiceType.fireSprinkler => StringKey.issueServiceSprinkler,
      ServiceType.fireHydrant => StringKey.issueServiceHydrant,
    };
