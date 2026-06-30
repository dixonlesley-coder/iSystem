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

/// Card width: `max(280, LEFT + max(ways,1)*WAY_W + RIGHT_PAD)`.
double panelCardWidth(int ways) => math.max(
    kMinPanelWidth, (kLeft + math.max(ways, 1) * kWayW + kRightPad).toDouble());

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
/// is COLLAPSED (zoomed out): just the kW / demand / incomer / system / ways +
/// phase-balance rows — no schematic band, so the card is a tidy block instead
/// of a tall card of empty space.
const double kPanelSummaryBodyH = 104;

/// The board-schedule block height for a panel — mirrors
/// `buildElectricalPanelDetail`: header `46` + a column-header row + one row per
/// way + one per reserved spare + a TOTAL footer (`*20`) + body pad `12`, plus a
/// little card padding. Keeps the canvas card sized to its schedule.
double panelScheduleHeight(ElectricalPanelResult panel) {
  final rows = 1 + math.max(1, panel.circuits.length) + panel.spareWaysReserved;
  return 46 + (1 + rows) * 20 + 12 + 22;
}

/// Card footprint at the active LOD: the BOARD SCHEDULE height (grows with the
/// way count) when [detail] — the card has no separate header band there, the
/// engine schedule draws its own — else the compact summary band (header +
/// summary body). Threaded through the canvas so the card height, the
/// merged-node connector and the feeder endpoints all agree at every zoom.
double panelFootprint(ElectricalPanelResult panel, bool detail) => detail
    ? panelScheduleHeight(panel)
    : kPanelChrome + kPanelSummaryBodyH;

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
  // so siblings stacked top-to-bottom never collide.
  double extentOf(String id) {
    final r = result.panels[id];
    if (r == null) return 160.0 + 60;
    return panelFootprint(r, true) + 70;
  }

  // Depth column pitch (horizontal): the widest card + a feeder gap, so a child
  // clears its parent.
  var maxW = kMinPanelWidth;
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
