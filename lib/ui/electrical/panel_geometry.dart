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

/// Card footprint (header + body) at the active LOD: the full schematic band
/// when [detail], else the compact summary band. Threaded through the canvas so
/// the card height, its load/merged-node drop, and the feeder endpoints all
/// agree at every zoom.
double panelFootprint(ElectricalPanelResult panel, bool detail) =>
    kPanelChrome + (detail ? panelGeometry(panel).height : kPanelSummaryBodyH);

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

/// Deterministic tidy-tree auto-layout: the service root at the top-left, fed
/// panels stepping DOWN by feeder depth, siblings laid out left-to-right so
/// feeders never cross. Breadth axis = X, depth axis = Y (vertical mode).
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

  // The breadth pitch per panel = its card width + gap.
  double extentOf(String id) {
    final r = result.panels[id];
    return (r == null ? kMinPanelWidth : panelCardWidth(r.circuits.length)) + 80;
  }

  // Depth row pitch: tallest panel footprint + the load band + slack.
  var maxH = 120.0;
  for (final p in project.panels) {
    final r = result.panels[p.id];
    if (r != null) maxH = math.max(maxH, panelCardHeight(r));
  }
  final rowPitch = maxH + kPanelChrome + kLoadDropGap + kLoadNodeH + 80;

  var cursorX = 40.0;

  // Recursive subtree placement: a leaf consumes its extent; a parent is
  // centred over its children.
  double place(String id, int depth, Set<String> seen) {
    if (!seen.add(id)) {
      // Cycle guard — place at the cursor and stop.
      final x = cursorX;
      cursorX += extentOf(id);
      positions[id] = Offset(snap(x), snap(40 + depth * rowPitch));
      return x + extentOf(id) / 2;
    }
    final kids = childrenOf[id] ?? const [];
    final y = 40 + depth * rowPitch;
    if (kids.isEmpty) {
      final ext = extentOf(id);
      final x = cursorX;
      cursorX += ext;
      positions[id] = Offset(snap(x), snap(y));
      return x + ext / 2;
    }
    final centers = <double>[];
    for (final k in kids) {
      centers.add(place(k, depth + 1, seen));
    }
    final center = (centers.first + centers.last) / 2;
    final ext = extentOf(id);
    positions[id] = Offset(snap(center - ext / 2), snap(y));
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
    cursorX += 80; // forest separation between disjoint trees.
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
