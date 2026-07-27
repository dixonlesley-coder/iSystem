/// Pure layout geometry for the electrical single-line canvas — the panel-card
/// dimensions, the internal-schematic vertical bands, the way-column spacing,
/// the feeder tidy-tree auto-layout, and the service-root resolution. Ported
/// from PanelMaker's `BuildingSingleLine.tsx` constants + `buildUnified`
/// placement and `serviceRootId`.
///
/// DOM-free, deterministic — given the same project + result it produces the
/// same positions, so the canvas is stable across rebuilds.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';

// ── Panel-card horizontal layout (ported constants) ──────────────────────────
const int kLeft = 76;
const int kWayW = 108;
const int kRightPad = 16;
const double kMinPanelWidth = 280;

// ── Internal-schematic vertical bands ─────────────────────────────────────────
const int kIncomerY = 8;
const int kIncomerH = 26;
const int kBusTopY = 92;
const int kBarGap = 13;
const int kNpeGap = 11;
const int kBrkGap = 26;
const int kBrkH = 20;

/// Extra header / padding chrome above the SVG schematic (PanelMaker
/// `PANEL_CHROME`).
const double kPanelChrome = 64;

// ── Load node + drop ──────────────────────────────────────────────────────────
const double kLoadW = 70;
const double kLoadNodeH = 74;
const double kLoadDropGap = 64;

// Loads branch to the RIGHT of the panel (left-to-right, like the board
// schedule's way rows), stacked top-to-bottom — so they read consistently with
// the deep-zoom schedule and zooming in morphs them into its rows, and feeders
// (which drop straight down) never cross them.
const double kLoadGapX = 46; // horizontal gap from the card's right edge
const double kLoadRowH = 82; // vertical pitch per load in the right column

// ── PLN grid head ─────────────────────────────────────────────────────────────
const double kGridSrcW = 158;
const double kGridSrcH = 54;

// ── Auto-layout grid ──────────────────────────────────────────────────────────
const int kGrid = 16;

/// Card width (SUMMARY LOD): `max(280, LEFT + max(ways,1)*WAY_W + RIGHT_PAD)`.
double panelCardWidth(int ways) => math.max(
    kMinPanelWidth, (kLeft + math.max(ways, 1) * kWayW + kRightPad).toDouble());

/// The engine board-schedule sheet WIDTH (mirrors `_blockW` in
/// `report/electrical_sld_drawing.dart`). EVERY panel's schedule shares this
/// width — the DXF/PDF convention (one uniform column layout) — so at the detail
/// LOD the canvas renders them all at one consistent, readable scale. Widened
/// 920 -> 948 in lock-step with `_blockW` when the DEVICE column grew to carry
/// the per-device kA + RCD tokens (Wave 7 N9 / N10), so the canvas frames the
/// full schedule (the focus zoom clamps to this width).
const double kScheduleSheetWidth = 948;

/// The on-canvas scale the schedule sheet renders at (so 948 -> ~758 world px),
/// keeping a multi-way board about the readable size it had before.
const double kScheduleScale = 0.8;

/// The engine schedule sheet HEIGHT for a panel — mirrors
/// `buildElectricalPanelDetail`: header `46` + a column-header row + one row per
/// way + one per reserved spare + a TOTAL footer (`*20`) + body pad `12`.
double scheduleSheetHeight(ElectricalPanelResult panel) {
  final rows = 1 + math.max(1, panel.circuits.length) + panel.spareWaysReserved;
  return 46 + (1 + rows) * 20 + 12.0;
}

/// The detail-LOD card WIDTH — the schedule sheet width at [kScheduleScale], the
/// SAME for every panel, so a 1-way board (e.g. LP-1) reads as a SHORT version
/// of the MDP schedule rather than a squished narrow strip with the row jammed
/// at the top.
double panelDetailWidth() => kScheduleSheetWidth * kScheduleScale;

/// The three zoom-driven detail tiers a panel card renders at.
///
/// [micro] is the far-zoomed-out plan-reading tier — a chip carrying only the
/// board's identity, its connected kW and a proportional R/S/T bar, so a large
/// distribution tree stays legible (and cheap) when the whole building is on
/// screen. [summary] is the compact stats card, [schedule] the real engine board
/// schedule. The canvas maps zoom → tier; this file only supplies the geometry.
enum PanelLod { micro, summary, schedule }

/// Micro-tier card size — a fixed chip (identity + kW + phase bar), independent
/// of the way count (a 20-way board and a 1-way board read the same at this
/// zoom; the difference is only legible once the summary stats appear). The
/// height holds the two text lines + the phase bar + the card's padding and
/// border with a few px of slack, so the chip never clips its own three facts.
const double kPanelMicroW = 176;
const double kPanelMicroH = 72;

/// Card WIDTH at an explicit [PanelLod] — the uniform schedule width at
/// [PanelLod.schedule], the way-count summary width at [PanelLod.summary], the
/// fixed chip width at [PanelLod.micro].
double panelCardWidthLod(ElectricalPanelResult panel, PanelLod lod) =>
    switch (lod) {
      PanelLod.micro => kPanelMicroW,
      PanelLod.summary => panelCardWidth(panel.circuits.length),
      PanelLod.schedule => panelDetailWidth(),
    };

/// Card WIDTH at the active LOD: the uniform schedule width when [detail], else
/// the way-count summary width. The pre-micro two-tier API, kept so the callers
/// that only distinguish "schedule vs not" (the minimap, the golden harness)
/// compile unchanged; it delegates to [panelCardWidthLod].
double panelCardWidthAt(ElectricalPanelResult panel, bool detail) =>
    panelCardWidthLod(panel, detail ? PanelLod.schedule : PanelLod.summary);

/// Centre x of way column [i].
double wayColumnX(int i) => kLeft + i * kWayW + kWayW / 2;

/// The internal-schematic geometry for a panel: the rail y-positions (keyed
/// L1/L2/L3 or L, plus N + PE), and the output-terminal y.
class PanelGeometry {
  /// Rail key → local y.
  final Map<String, double> bars;

  /// Output-terminal y (where the load drop line begins).
  final double outY;

  /// Total schematic height.
  final double height;

  const PanelGeometry({
    required this.bars,
    required this.outY,
    required this.height,
  });
}

PanelGeometry panelGeometry(ElectricalPanelResult panel) {
  final threePhase = panel.system == ElectricalSystem.threePhase;
  final phases = threePhase ? ['L1', 'L2', 'L3'] : ['L'];
  final bars = <String, double>{};
  for (var i = 0; i < phases.length; i++) {
    bars[phases[i]] = (kBusTopY + i * kBarGap).toDouble();
  }
  final nY = kBusTopY + phases.length * kBarGap + kNpeGap;
  bars['N'] = nY.toDouble();
  bars['PE'] = (nY + kNpeGap).toDouble();

  final lastBarY = bars.values.reduce(math.max);
  final brkTop = lastBarY + kBrkGap;
  final afterBrk = brkTop + kBrkH;
  final outY = afterBrk + 12;
  final height = outY + 18;
  return PanelGeometry(bars: bars, outY: outY, height: height);
}

/// The card footprint height (the reserved schematic band, identical at both
/// LOD levels so loads sit a fixed gap below).
double panelCardHeight(ElectricalPanelResult panel) =>
    panelGeometry(panel).height;

/// Compact summary-body band (header [kPanelChrome] excluded) used when a panel
/// is COLLAPSED (zoomed out): the kW / demand / incomer / bus / system / ways /
/// placed stats + the phase-balance row — no schematic band, so the card is a
/// tidy block instead of a tall card of empty space.
///
/// Sized so the full stat set still fits on the NARROWEST card
/// ([kMinPanelWidth], a one-way board), where the stats wrap to three rows. It
/// grew 104 -> 136 when the busbar + "n/m placed" stats joined: the band is a
/// reserved height, so under-sizing it clips real numbers rather than making
/// the card honest.
const double kPanelSummaryBodyH = 136;

/// The detail-LOD card HEIGHT — the schedule sheet height at [kScheduleScale].
/// Because the card width is also the sheet width at the SAME scale
/// ([panelDetailWidth]), the card's aspect ratio equals the schedule sheet's, so
/// `ViewportTransform.fit` fills the card EXACTLY — the schedule fills the panel
/// instead of being letter-boxed as a strip at the top (the "loads on top of the
/// panel" artefact a fixed-width sheet caused in a narrow card).
double panelScheduleHeight(ElectricalPanelResult panel) =>
    scheduleSheetHeight(panel) * kScheduleScale;

/// Card footprint HEIGHT at an explicit [PanelLod]: the BOARD SCHEDULE height
/// (grows with the way count) at [PanelLod.schedule] — the card has no separate
/// header band there, the engine schedule draws its own — the compact summary
/// band (header + summary body) at [PanelLod.summary], and the fixed chip height
/// at [PanelLod.micro]. Threaded through the canvas so the card height, the
/// merged-node connector and the feeder endpoints all agree at every zoom.
double panelFootprintLod(ElectricalPanelResult panel, PanelLod lod) =>
    switch (lod) {
      PanelLod.micro => kPanelMicroH,
      PanelLod.summary => kPanelChrome + kPanelSummaryBodyH,
      PanelLod.schedule => panelScheduleHeight(panel),
    };

/// Card footprint at the active LOD (the pre-micro two-tier API — see
/// [panelCardWidthAt]); delegates to [panelFootprintLod].
double panelFootprint(ElectricalPanelResult panel, bool detail) =>
    panelFootprintLod(panel, detail ? PanelLod.schedule : PanelLod.summary);

/// Resolve each panel's world position: a saved `x,y` wins, else the
/// deterministic tidy-tree [autoLayout]. The single shared resolver used by the
/// interactive single-line canvas AND the minimap (I8) so the minimap tracks
/// dragged panels instead of only the auto-layout.
Map<String, Offset> resolvePanelPositions(
    ElectricalProject project, ElectricalSystemResult result) {
  final auto = autoLayout(project, result);
  return {
    for (final p in project.panels)
      p.id: (p.x != null && p.y != null)
          ? Offset(p.x!, p.y!)
          : (auto[p.id] ?? Offset.zero),
  };
}

/// The single service entrance — the utility-fed root with the most demand
/// (PanelMaker `serviceRootId`): a utility panel that has feeder children,
/// preferring the highest-demand one, else the first utility root, else the
/// first panel.
String? serviceRootId(
    ElectricalProject project, ElectricalSystemResult result) {
  if (project.panels.isEmpty) return null;
  // Panels that have at least one outgoing feeder.
  final hasChildren = <String>{};
  for (final p in project.panels) {
    if (p.circuits.any((c) => c.feedsPanelId != null)) hasChildren.add(p.id);
  }
  // Set of panels fed by some other panel.
  final fed = <String>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      if (c.feedsPanelId != null) fed.add(c.feedsPanelId!);
    }
  }
  // Utility-fed (unparented) roots.
  final roots = [
    for (final p in project.panels)
      if (!fed.contains(p.id)) p,
  ];
  if (roots.isEmpty) return project.panels.first.id;
  // Prefer a root with feeder children, by descending demand.
  roots.sort((a, b) {
    final ad = result.panels[a.id]?.demandW ?? 0;
    final bd = result.panels[b.id]?.demandW ?? 0;
    final aHas = hasChildren.contains(a.id) ? 1 : 0;
    final bHas = hasChildren.contains(b.id) ? 1 : 0;
    if (aHas != bHas) return bHas - aHas;
    return bd.compareTo(ad);
  });
  return roots.first.id;
}

/// Deterministic tidy-tree auto-layout: the service root at the top-LEFT, fed
/// panels stepping RIGHT by feeder depth, siblings stacked top-to-bottom so
/// feeders never cross. Depth axis = X, breadth axis = Y (left-to-right mode,
/// like the CAD building single-line: bus on the left, loads + feeders branch
/// right, sub-panels step rightward).
Map<String, Offset> autoLayout(
    ElectricalProject project, ElectricalSystemResult result) {
  final positions = <String, Offset>{};
  if (project.panels.isEmpty) return positions;

  // parent map + children map.
  final parentOf = <String, String>{};
  final childrenOf = <String, List<String>>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final fed = c.feedsPanelId;
      if (fed != null) {
        parentOf[fed] = p.id;
        (childrenOf[p.id] ??= []).add(fed);
      }
    }
  }

  // The breadth (vertical) extent per panel = its board-schedule height + gap,
  // so siblings stacked top-to-bottom never collide. PINNED to the SCHEDULE
  // footprint (the tallest tier) on purpose: world positions must not change
  // with zoom, so neither the summary nor the micro tier may feed this.
  double extentOf(String id) {
    final r = result.panels[id];
    if (r == null) return 160.0 + 60;
    return panelFootprintLod(r, PanelLod.schedule) + 70;
  }

  // Depth column pitch (horizontal): the widest card + a feeder gap, so a child
  // clears its parent at EITHER LOD — include the uniform detail width so even an
  // all-small-panel project doesn't overlap once zoomed into the schedules.
  var maxW = math.max(kMinPanelWidth, panelDetailWidth());
  for (final p in project.panels) {
    final r = result.panels[p.id];
    if (r != null) maxW = math.max(maxW, panelCardWidth(r.circuits.length));
  }
  final colPitch = maxW + 180;

  var cursorY = 40.0;

  // Recursive subtree placement: a leaf consumes its (vertical) extent; a parent
  // is centred over its children.
  double place(String id, int depth, Set<String> seen) {
    final x = 40 + depth * colPitch;
    if (!seen.add(id)) {
      // Cycle guard — place at the cursor and stop.
      final y = cursorY;
      cursorY += extentOf(id);
      positions[id] = Offset(snap(x), snap(y));
      return y + extentOf(id) / 2;
    }
    final kids = childrenOf[id] ?? const [];
    if (kids.isEmpty) {
      final ext = extentOf(id);
      final y = cursorY;
      cursorY += ext;
      positions[id] = Offset(snap(x), snap(y));
      return y + ext / 2;
    }
    final centers = <double>[];
    for (final k in kids) {
      centers.add(place(k, depth + 1, seen));
    }
    final center = (centers.first + centers.last) / 2;
    final ext = extentOf(id);
    positions[id] = Offset(snap(x), snap(center - ext / 2));
    return center;
  }

  // Roots = unparented panels (service root first by demand).
  final root = serviceRootId(project, result);
  final roots = [
    for (final p in project.panels)
      if (!parentOf.containsKey(p.id)) p.id,
  ];
  // Service root first so it anchors the top-left.
  if (root != null && roots.contains(root)) {
    roots.remove(root);
    roots.insert(0, root);
  }
  final seen = <String>{};
  for (final r in roots) {
    place(r, 0, seen);
    cursorY += 80; // forest separation between disjoint trees.
  }
  // Any orphan not reached (inside a cycle) gets a fallback slot.
  for (final p in project.panels) {
    if (!positions.containsKey(p.id)) {
      place(p.id, 0, seen);
    }
  }
  return positions;
}

double snap(double v) => (v / kGrid).round() * kGrid.toDouble();
