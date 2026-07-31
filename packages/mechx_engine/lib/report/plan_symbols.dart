/// Pure PLAN-symbol primitive library for the drawing exporters — the export
/// analogue of the on-canvas `lib/ui/canvas/segment_symbols.dart`
/// `paintComponentSymbol`. Given a [NodeComponent], it returns the equipment
/// glyph as a list of the existing neutral [SldPrim] records ([SldLine] /
/// [SldCircle] only) centred on a caller-supplied point, so the PDF and DXF
/// plan exporters can draw a real pump / tank / valve / diffuser at each node
/// instead of an anonymous dot (CAD-OUTPUT-UX-REVIEW Part 1 A5). Pure
/// (Flutter-free): the geometry is authored in a y-DOWN, [0..1] fractional box
/// (matching the canvas painter), scaled + translated to the caller's centre.
///
/// The renderers own the stroke colour / weight and any y-flip for their own
/// coordinate convention (PDF + DXF are y-up), so these prims carry only
/// geometry (default weight/role).
library;

import 'dart:math' as math;

import '../network/network.dart';
import 'drawing_chrome.dart' show LabelBox;
import 'sld_sheet.dart';

/// Equipment glyph for [c] as neutral drawing primitives, centred on
/// ([cx], [cy]) and fitting a [size]×[size] box. The geometry mirrors the
/// on-canvas `paintComponentSymbol` fraction-for-fraction (a pump circle +
/// impeller chevron, tank rects with a water line, bowtie valves, a PRV stem,
/// a Y-strainer, water-meter gauge, drains, cleanout, diffuser/grille
/// diagonals + louvers, dampers, AHU/FCU/fan, AC units …). Every
/// [NodeComponent] value returns a NON-EMPTY glyph (the switch is exhaustive).
///
/// Coordinates are y-DOWN in drawing space (fraction 0 = top, 1 = bottom),
/// exactly like the canvas; a y-up renderer (PDF / DXF) mirrors about [cy].
List<SldPrim> planComponentPrims(
  NodeComponent c, {
  required double cx,
  required double cy,
  double size = 14,
}) {
  final out = <SldPrim>[];
  // Fraction (0..1 across the box) → world coordinate.
  double fx(double f) => cx + (f - 0.5) * size;
  double fy(double f) => cy + (f - 0.5) * size;
  void ln(double x1, double y1, double x2, double y2) =>
      out.add(SldLine(fx(x1), fy(y1), fx(x2), fy(y2)));
  // Circle centred at fraction (fcx, fcy) with radius a fraction [fr] of size.
  void cir(double fcx, double fcy, double fr) =>
      out.add(SldCircle(fx(fcx), fy(fcy), fr * size));
  // Rectangle from top-left (l, t) to bottom-right (r, b) as four lines.
  void rect(double l, double t, double r, double b) {
    ln(l, t, r, t);
    ln(r, t, r, b);
    ln(r, b, l, b);
    ln(l, b, l, t);
  }

  // A valve body: two triangles meeting tip-to-tip (the canvas `bowtie`).
  void bowtie() {
    ln(0.2, 0.28, 0.2, 0.72);
    ln(0.2, 0.72, 0.5, 0.5);
    ln(0.5, 0.5, 0.2, 0.28);
    ln(0.8, 0.28, 0.8, 0.72);
    ln(0.8, 0.72, 0.5, 0.5);
    ln(0.5, 0.5, 0.8, 0.28);
  }

  // A 3-blade fan inside a circle (the canvas `_fan`): r = 0.26·size, blades
  // 0.9·r long at 120° apart.
  void fan() {
    cir(0.5, 0.5, 0.26);
    const bladeR = 0.26 * 0.9; // fraction of size
    for (var i = 0; i < 3; i++) {
      final a = i * 2 * math.pi / 3;
      ln(0.5, 0.5, 0.5 + bladeR * math.cos(a), 0.5 + bladeR * math.sin(a));
    }
  }

  switch (c) {
    case NodeComponent.pump:
      // Circle + an inscribed impeller triangle (flow to the right).
      cir(0.5, 0.5, 0.30);
      ln(0.40, 0.36, 0.68, 0.50);
      ln(0.68, 0.50, 0.40, 0.64);
      ln(0.40, 0.64, 0.40, 0.36);
    case NodeComponent.roofTank:
      // A tank with a roof cap + water line.
      rect(0.22, 0.34, 0.78, 0.80);
      ln(0.18, 0.34, 0.82, 0.34);
      ln(0.30, 0.34, 0.50, 0.18);
      ln(0.70, 0.34, 0.50, 0.18);
      ln(0.28, 0.50, 0.72, 0.50);
    case NodeComponent.groundTank:
      // A tank sitting on the ground (base line) + water line.
      rect(0.20, 0.30, 0.80, 0.76);
      ln(0.26, 0.44, 0.74, 0.44);
      ln(0.12, 0.80, 0.88, 0.80);
    case NodeComponent.boosterSet:
      // Two small pumps on a base — a packaged set.
      cir(0.36, 0.50, 0.16);
      cir(0.64, 0.50, 0.16);
      ln(0.14, 0.78, 0.86, 0.78);
    case NodeComponent.gateValve:
      bowtie();
    case NodeComponent.checkValve:
      // Valve body + a flow arrow (non-return direction).
      bowtie();
      ln(0.12, 0.50, 0.88, 0.50);
      ln(0.74, 0.42, 0.88, 0.50);
      ln(0.88, 0.50, 0.74, 0.58);
    case NodeComponent.prv:
      // Valve body + an adjuster stem/spring on top.
      bowtie();
      ln(0.50, 0.28, 0.50, 0.08);
      ln(0.40, 0.10, 0.60, 0.10);
    case NodeComponent.balancingValve:
      // Valve body + a handle dot.
      bowtie();
      ln(0.50, 0.28, 0.50, 0.12);
      cir(0.50, 0.12, 0.06);
    case NodeComponent.roofDrain:
      // A domed drain with a grate cross.
      cir(0.50, 0.50, 0.30);
      ln(0.26, 0.50, 0.74, 0.50);
      ln(0.50, 0.26, 0.50, 0.74);
    case NodeComponent.floorDrain:
      // A square grated drain.
      rect(0.22, 0.22, 0.78, 0.78);
      ln(0.30, 0.50, 0.70, 0.50);
      ln(0.50, 0.30, 0.50, 0.70);
    case NodeComponent.cleanout:
      // A circle with a removable plug cap.
      cir(0.50, 0.54, 0.26);
      rect(0.40, 0.12, 0.60, 0.24);
    case NodeComponent.riser:
      // B15 — the drafting-standard riser mark: a circle containing up + down
      // chevron arrows, converged with the on-canvas riser marker so plan and
      // print share one convention.
      cir(0.50, 0.50, 0.42);
      // Up chevron ("^") in the top half.
      ln(0.34, 0.44, 0.50, 0.26);
      ln(0.50, 0.26, 0.66, 0.44);
      // Down chevron ("v") in the bottom half.
      ln(0.34, 0.56, 0.50, 0.74);
      ln(0.50, 0.74, 0.66, 0.56);
    case NodeComponent.waterMeter:
      // A gauge: circle + a needle.
      cir(0.50, 0.50, 0.30);
      ln(0.50, 0.50, 0.66, 0.34);
      cir(0.50, 0.50, 0.04);
    case NodeComponent.strainer:
      // A Y-strainer: a horizontal line with a diagonal branch.
      ln(0.14, 0.50, 0.86, 0.50);
      ln(0.50, 0.50, 0.74, 0.82);
      ln(0.62, 0.74, 0.84, 0.90);
    case NodeComponent.expansionTank:
      // A capsule with a diaphragm line.
      rect(0.34, 0.16, 0.66, 0.84);
      ln(0.34, 0.50, 0.66, 0.50);
    case NodeComponent.airVent:
      // A small body with an up arrow (air escaping).
      cir(0.50, 0.64, 0.20);
      ln(0.50, 0.10, 0.38, 0.30);
      ln(0.50, 0.10, 0.62, 0.30);
      ln(0.50, 0.10, 0.50, 0.44);
    case NodeComponent.waterOutlet:
      // A clean-water outlet: a tap/faucet (body + handle + spout) delivering a
      // water drop (a small circle here, since plan prims are stroke-only).
      ln(0.16, 0.30, 0.60, 0.30);
      ln(0.60, 0.30, 0.60, 0.46);
      ln(0.34, 0.30, 0.34, 0.16);
      ln(0.24, 0.16, 0.44, 0.16);
      cir(0.60, 0.66, 0.14);
    case NodeComponent.sprinklerHead:
      // A pendent sprinkler: a small circle + a downward deflector bar.
      cir(0.50, 0.40, 0.16);
      ln(0.50, 0.56, 0.50, 0.74);
      ln(0.34, 0.78, 0.66, 0.78);
    case NodeComponent.fireExtinguisher:
      // A portable extinguisher: a bottle with a valve cap.
      rect(0.36, 0.34, 0.64, 0.84);
      rect(0.44, 0.22, 0.56, 0.34);
      ln(0.56, 0.26, 0.72, 0.26);
    case NodeComponent.hydrantBox:
      // A wall hydrant/hose box: a square with a coiled-hose ring inside.
      rect(0.18, 0.20, 0.82, 0.80);
      cir(0.50, 0.50, 0.14);
      cir(0.50, 0.50, 0.05);
    case NodeComponent.hoseReel:
      // A swing hose reel: concentric rings + a feed line.
      cir(0.50, 0.50, 0.28);
      cir(0.50, 0.50, 0.10);
      ln(0.10, 0.50, 0.22, 0.50);
    case NodeComponent.fireDeptConnection:
      // A Siamese FDC: two inlets with an arrow feeding in.
      cir(0.36, 0.50, 0.16);
      cir(0.64, 0.50, 0.16);
      ln(0.50, 0.10, 0.40, 0.26);
      ln(0.50, 0.10, 0.60, 0.26);
    case NodeComponent.supplyDiffuser:
      // A 4-way ceiling diffuser: a square with diagonals to the corners.
      rect(0.22, 0.22, 0.78, 0.78);
      ln(0.22, 0.22, 0.78, 0.78);
      ln(0.78, 0.22, 0.22, 0.78);
    case NodeComponent.returnGrille:
      // A return grille: a rectangle with horizontal louver lines.
      rect(0.20, 0.26, 0.80, 0.74);
      ln(0.20, 0.42, 0.80, 0.42);
      ln(0.20, 0.58, 0.80, 0.58);
    case NodeComponent.exhaustGrille:
      // A grille with an out arrow (extract).
      rect(0.20, 0.38, 0.80, 0.78);
      ln(0.20, 0.38 + 0.40 / 3, 0.80, 0.38 + 0.40 / 3);
      ln(0.20, 0.38 + 0.80 / 3, 0.80, 0.38 + 0.80 / 3);
      ln(0.50, 0.06, 0.40, 0.24);
      ln(0.50, 0.06, 0.60, 0.24);
      ln(0.50, 0.06, 0.50, 0.34);
    case NodeComponent.linearDiffuser:
      // A linear slot diffuser: a long thin rectangle with a centre slot.
      rect(0.14, 0.35, 0.86, 0.65);
      ln(0.14, 0.50, 0.86, 0.50);
    case NodeComponent.volumeDamper:
      // A VCD: a duct box with an angled blade + pivot.
      rect(0.22, 0.28, 0.78, 0.72);
      ln(0.22, 0.28, 0.78, 0.72);
      cir(0.50, 0.50, 0.04);
    case NodeComponent.fireDamper:
      // A damper with a flame mark.
      rect(0.22, 0.28, 0.78, 0.72);
      ln(0.22, 0.28, 0.78, 0.72);
      ln(0.50, 0.20, 0.60, 0.10);
    case NodeComponent.motorizedDamper:
      // A damper with a motor box on top.
      rect(0.22, 0.37, 0.78, 0.79);
      ln(0.22, 0.37, 0.78, 0.79);
      rect(0.42, 0.10, 0.58, 0.24);
    case NodeComponent.vavBox:
      // A VAV terminal: a box with a through-flow arrow + a blade.
      rect(0.18, 0.32, 0.82, 0.68);
      ln(0.10, 0.50, 0.90, 0.50);
      ln(0.78, 0.43, 0.90, 0.50);
      ln(0.90, 0.50, 0.78, 0.57);
    case NodeComponent.ahu:
      // An air-handling unit: a large box with a fan circle inside.
      rect(0.14, 0.24, 0.86, 0.76);
      cir(0.66, 0.50, 0.12);
    case NodeComponent.fcu:
      // A fan-coil unit: a box with a coil zigzag.
      rect(0.18, 0.30, 0.82, 0.70);
      var prevX = 0.26, prevY = 0.40;
      for (var i = 0; i < 3; i++) {
        final x = 0.26 + 0.16 * i;
        ln(prevX, prevY, x + 0.08, 0.60);
        ln(x + 0.08, 0.60, x + 0.16, 0.40);
        prevX = x + 0.16;
        prevY = 0.40;
      }
    case NodeComponent.supplyFan:
      // A fan + an out arrow line.
      fan();
      ln(0.80, 0.50, 0.94, 0.50);
    case NodeComponent.exhaustFan:
      // A fan with an in arrow (extract).
      fan();
      ln(0.94, 0.50, 0.80, 0.50);
      ln(0.86, 0.44, 0.80, 0.50);
      ln(0.80, 0.50, 0.86, 0.56);
    case NodeComponent.acCassette:
      // A ceiling cassette: a square with a smaller inset square.
      rect(0.20, 0.20, 0.80, 0.80);
      rect(0.34, 0.34, 0.66, 0.66);
    case NodeComponent.acSplitWall:
      // A wall-mounted split: a slim bar with a louvre line.
      rect(0.14, 0.38, 0.86, 0.62);
      ln(0.18, 0.56, 0.82, 0.56);
    case NodeComponent.acDucted:
      // A concealed ducted unit: a box with a supply arrow out one side.
      rect(0.16, 0.30, 0.72, 0.70);
      ln(0.72, 0.50, 0.92, 0.50);
      ln(0.86, 0.44, 0.92, 0.50);
      ln(0.92, 0.50, 0.86, 0.56);
  }
  return out;
}

/// The fixture-terminal glyph: a small filled DOWN-triangle drop, mirroring the
/// schematic riser convention (`schematic_view.dart` `_paintNodes` fixture
/// drop) — base at the top, apex at the bottom. Returned as three [SldLine]
/// edges (the renderers stroke them; the closed outline reads as a solid
/// triangle at plan scale). y-DOWN drawing space, centred on ([cx], [cy]).
List<SldPrim> planFixturePrims({
  required double cx,
  required double cy,
  double size = 14,
}) {
  final r = size * 0.4;
  return [
    SldLine(cx - r, cy - r * 0.7, cx + r, cy - r * 0.7),
    SldLine(cx + r, cy - r * 0.7, cx, cy + r),
    SldLine(cx, cy + r, cx - r, cy - r * 0.7),
  ];
}

/// A FLEXIBLE-JOINT (FJ) glyph — two end flanges bridged by a bellows "W" —
/// centred on ([cx], [cy]) in a [size]×[size] box. FJ is a drawing device (a
/// vibration-isolating pump-connection fitting), not a [NodeComponent], so it
/// lives here as a standalone glyph the pump-set detail's suction/discharge
/// valve train (G3) can draw alongside the gate/check-valve + strainer glyphs.
/// Line-only, y-DOWN drawing space (mirrored about [cy] by a y-up renderer).
List<SldPrim> planFlexibleJointPrims({
  required double cx,
  required double cy,
  double size = 14,
}) {
  double fx(double f) => cx + (f - 0.5) * size;
  double fy(double f) => cy + (f - 0.5) * size;
  SldLine ln(double x1, double y1, double x2, double y2) =>
      SldLine(fx(x1), fy(y1), fx(x2), fy(y2));
  return [
    // End flanges (short verticals).
    ln(0.18, 0.28, 0.18, 0.72),
    ln(0.82, 0.28, 0.82, 0.72),
    // Bellows: a "W" between the flanges.
    ln(0.18, 0.50, 0.35, 0.32),
    ln(0.35, 0.32, 0.50, 0.68),
    ln(0.50, 0.68, 0.65, 0.32),
    ln(0.65, 0.32, 0.82, 0.50),
  ];
}

/// A SEWER / DISCHARGE TERMINUS glyph (G4) — a downward arrow meeting a hatched
/// ground line, the industry "discharge to the disposal system" mark — centred
/// on ([cx], [cy]) in a [size]×[size] box. Drawn at a drainage stack's exit
/// (the point where the soil/waste leaves the building) beside a
/// 'KE SALURAN PEMBUANGAN' label. HONEST: it names the generic disposal outlet,
/// never a specific septic/STP/city-sewer destination the model can't confirm.
/// Line-only, y-DOWN drawing space.
List<SldPrim> planSewerTerminusPrims({
  required double cx,
  required double cy,
  double size = 14,
}) {
  double fx(double f) => cx + (f - 0.5) * size;
  double fy(double f) => cy + (f - 0.5) * size;
  SldLine ln(double x1, double y1, double x2, double y2) =>
      SldLine(fx(x1), fy(y1), fx(x2), fy(y2));
  return [
    // Down arrow (flow leaving to the disposal system).
    ln(0.50, 0.10, 0.50, 0.58),
    ln(0.50, 0.58, 0.38, 0.42),
    ln(0.50, 0.58, 0.62, 0.42),
    // Ground / sewer line + hatch ticks below it.
    ln(0.16, 0.66, 0.84, 0.66),
    ln(0.30, 0.66, 0.20, 0.82),
    ln(0.50, 0.66, 0.40, 0.82),
    ln(0.70, 0.66, 0.60, 0.82),
  ];
}

/// Riser vertical sense for a marker on floor [hereFloor] whose other endpoint
/// is on [otherFloor]: `'UP'` when the run rises to a physically HIGHER floor
/// (a larger `floorIndex` is a higher elevation — see `geometry/building.dart`
/// `elevationOf`), `'DN'` when it drops, and `null` when both ends share a
/// floor (no vertical sense to label). ASCII by construction (no Ø / arrows).
/// Used by all three plan exporters to annotate riser markers
/// (CAD-OUTPUT-UX-REVIEW Part 1 A5).
String? riserUpDown({required int hereFloor, required int otherFloor}) {
  if (otherFloor > hereFloor) return 'UP';
  if (otherFloor < hereFloor) return 'DN';
  return null;
}

// ── G1: stable equipment TAGS for the plan (P-01 / TK-01 / AHU-01 …) ─────────
//
// A NetNode carries no name/tag, so an equipment glyph on the plan (pump, tank,
// AHU, fan, AC) reads as anonymous clip-art. This gives each MAJOR-EQUIPMENT
// node a stable, deterministic tag from ONE source shared by the canvas + all
// three plan exporters (never a second numbering), following the same
// `<prefix>-NN` shape the equipment schedule uses (P-01, TK-01, AHU-01, F-01,
// AC-01). Only role-bearing equipment is tagged — inline valves / meters /
// fittings / drains / air terminals get their symbol, not a tag.
//
// NOTE — this numbering is INDEPENDENT of the equipment schedule's, not a
// guaranteed cross-reference. The schedule (`gatherEquipmentScheduleData`)
// gathers from SOLVED providers (pump/fan/room duties), not network nodes, and
// numbers differently: the fire pump takes an `FP` prefix, room AHUs number by
// stable room identity (with gaps), and tanks appear in no schedule row at all.
// The tags therefore coincide only for a single-unit-per-prefix, all-calibrated
// project; a multi-unit / fire-pump / skipped-room project WILL diverge.

/// The equipment-tag prefix for [c] — `P` pumps/booster, `TK` tanks, `AHU`,
/// `FCU`, `F` fans, `AC` indoor AC units — or null for a component that is not
/// scheduled equipment (valves, meters, drains, terminals, dampers, riser mark).
String? equipmentTagPrefix(NodeComponent c) => switch (c) {
      NodeComponent.pump || NodeComponent.boosterSet => 'P',
      NodeComponent.roofTank || NodeComponent.groundTank => 'TK',
      NodeComponent.ahu => 'AHU',
      NodeComponent.fcu => 'FCU',
      NodeComponent.supplyFan || NodeComponent.exhaustFan => 'F',
      NodeComponent.acCassette ||
      NodeComponent.acSplitWall ||
      NodeComponent.acDucted =>
        'AC',
      _ => null,
    };

/// The trailing integer of a node id (`n7` → 7), or null when the id carries
/// none. The store mints every node id as `n<seq>` with a monotonic counter that
/// round-trips in `.mechx`, so this integer is the node's FIRST-ASSIGNED ordinal
/// — an identity that outlives every later edit.
int? _nodeIdOrdinal(String id) {
  final m = RegExp(r'(\d+)$').firstMatch(id);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Stable equipment tags keyed by NODE id (G1 / C6): a `<prefix>-NN` per
/// equipment CATEGORY. A node with no equipment component gets no entry, so the
/// map is empty for a network with no plant. This is the ONE tag source the
/// on-canvas glyph label AND the PDF/DXF plan exporters both read (so the plan
/// and its own canvas agree). It is NOT keyed to the equipment schedule's
/// numbering — see the block comment above.
///
/// C6 — the number is derived from the node's OWN IDENTITY (its id's
/// first-assigned ordinal + 1), not from its rank among the surviving equipment
/// nodes. The old positional counter renumbered every later unit whenever an
/// earlier one was deleted, so `P-02` on one revision's plan was a DIFFERENT
/// pump from `P-02` on the next — silently breaking the drawing↔schedule↔BOM
/// trace an installer works from. This is the same first-assigned-ordinal idiom
/// the room AHU schedule tag uses (J3): numbers may therefore carry GAPS after a
/// deletion, which is exactly the point — each unit keeps its number for life.
///
/// A node id with no trailing integer (never minted by the app; hand-written
/// fixtures and imported data only) falls back to the smallest number that
/// prefix has not used, assigned in node order — so a tag is never fabricated as
/// a duplicate. Two ids that would collide on the same ordinal (only possible
/// for hand-built data) push to the next free number, in node order.
///
/// Pure + deterministic — never fabricates a tag for a non-equipment node.
Map<String, String> equipmentNodeTags(Network net) {
  final out = <String, String>{};
  final used = <String, Set<int>>{};
  final unnumbered = <(String nodeId, String prefix)>[];

  String format(String prefix, int n) =>
      '$prefix-${n.toString().padLeft(2, '0')}';

  for (final n in net.nodes) {
    final c = n.component;
    if (c == null) continue;
    final prefix = equipmentTagPrefix(c);
    if (prefix == null) continue;
    final ordinal = _nodeIdOrdinal(n.id);
    if (ordinal == null) {
      unnumbered.add((n.id, prefix));
      continue;
    }
    final taken = used.putIfAbsent(prefix, () => <int>{});
    var number = ordinal + 1;
    while (!taken.add(number)) {
      number++;
    }
    out[n.id] = format(prefix, number);
  }

  for (final (nodeId, prefix) in unnumbered) {
    final taken = used.putIfAbsent(prefix, () => <int>{});
    var number = 1;
    while (!taken.add(number)) {
      number++;
    }
    out[nodeId] = format(prefix, number);
  }
  return out;
}

// ── G5: gravity-run fall / slope label ───────────────────────────────────────
//
// `SizingContext.drainageSlope` is the laid gradient the drainage sizer uses,
// but a plan run reads only its size (DN100) — an installer can't see the
// required fall. This formats that REAL context gradient as the drafting fall
// ratio `1:N`, appended to a gravity-regime (drainage / vent / rainwater) run's
// size label in the canvas + both plan exporters. The caller passes the actual
// `SizingContext.drainageSlope` — never a hardcoded default.

/// The fall label for a gravity run at [slope] (m/m) as a drafting ratio `1:N`
/// (slope 0.01 → `1:100`), or null when [slope] is non-positive / non-finite
/// (nothing to quote). Pure.
String? gravitySlopeLabel(double slope) {
  if (!slope.isFinite || slope <= 0) return null;
  return '1:${(1 / slope).round()}';
}

// ── N3: never-drop leadered edge-label placer ───────────────────────────────
//
// The shared `drawing_chrome.placeEdgeLabel` DROPS a size tag when no greedy
// slot clears — on dense branches that silently loses labels, and two short
// branches sharing a midpoint print nothing. This placer mirrors the riser
// side (`mechanical_sld_drawing._LabelPlacer`): a tag is the drawing's content
// and is NEVER dropped — when the greedy ladder can't clear, it ESCAPES
// perpendicular in growing steps and ties the pulled-off label back to its run
// with a LEADER, so tags never fuse into one unreadable token. Byte-identical
// to the old placer whenever the first greedy slot clears (the common case).

/// Perpendicular escape step (× textSize) + count for [placeEdgeLabelLeadered]
/// when no greedy ladder slot clears — the tag is pushed further off the line
/// in growing steps rather than dropped, then tied back with a leader. The step
/// COUNT is generous (12) so a DENSE riser base — several branch runs + two
/// coincident risers + the tie dimensions converging on one node (N3) — spreads
/// its tags far enough to clear instead of settling on a least-bad overlap.
const double _kLeaderEscapeFactor = 1.6;
const int _kLeaderEscapeSteps = 12;

/// A resolved leadered edge-label placement: the text anchor (baseline START)
/// + the rotation in degrees CCW in the y-up output space, PLUS an optional
/// [leaderAnchor] (the edge midpoint) — non-null when the label was pulled off
/// the line and a thin leader should be drawn from the run to the label so it
/// stays legible/unfused (N3).
class LeaderedLabelPlacement {
  final double x;
  final double y;
  final double angleDeg;
  final ({double x, double y})? leaderAnchor;
  const LeaderedLabelPlacement({
    required this.x,
    required this.y,
    required this.angleDeg,
    this.leaderAnchor,
  });
}

bool _boxesOverlap(LabelBox a, LabelBox b) =>
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY;

/// Summed overlap AREA of [r] against every already-[placed] box (0 = clear) —
/// used to pick the least-bad escape slot.
double _totalOverlapArea(LabelBox r, List<LabelBox> placed) {
  var total = 0.0;
  for (final p in placed) {
    final dx = math.min(r.maxX, p.maxX) - math.max(r.minX, p.minX);
    final dy = math.min(r.maxY, p.maxY) - math.max(r.minY, p.minY);
    if (dx > 0 && dy > 0) total += dx * dy;
  }
  return total;
}

/// Place [text] along the edge (ax,ay)→(bx,by) in the y-up output space, rotated
/// to the edge bearing (flipped past ±90° so it never reads upside-down), offset
/// perpendicular by 0.7 × [textSize] on the consistent upper side. Greedy pass
/// (midpoint upper/lower, quarter upper/lower) against [placed]; the first slot
/// that clears wins with NO leader (byte-identical to `placeEdgeLabel`'s first
/// candidate). When NONE clears — two short branch tags sharing a midpoint (N3)
/// — the placer ESCAPES perpendicular from the midpoint in growing steps (up
/// then down) until it clears, falling back to the least-overlapping escape slot
/// if even that can't fully clear; the escaped label is ALWAYS returned with a
/// [leaderAnchor] so the caller ties it back to the run. Never returns null: a
/// size tag is content, never dropped. A successful placement appends its box to
/// [placed]. Pure and deterministic given a stable emission order.
LeaderedLabelPlacement placeEdgeLabelLeadered({
  required double ax,
  required double ay,
  required double bx,
  required double by,
  required String text,
  required double textSize,
  required List<LabelBox> placed,
}) {
  final dx = bx - ax, dy = by - ay;
  var angle = (dx == 0 && dy == 0) ? 0.0 : math.atan2(dy, dx);
  if (angle > math.pi / 2 || angle <= -math.pi / 2) {
    angle += angle > 0 ? -math.pi : math.pi;
  }
  final ca = math.cos(angle), sa = math.sin(angle);
  final w = text.length * textSize * 0.55;
  final mx = (ax + bx) / 2, my = (ay + by) / 2;
  final angleDeg = angle * 180 / math.pi;

  // The baseline START (anchor) of a label at ([cx],[cy]) offset perpendicular
  // by [d] — the value the renderers feed a `Tm`/group-50 rotation.
  (double, double) anchorFor(double cx, double cy, double d) =>
      (cx - sa * d - ca * w / 2, cy + ca * d - sa * w / 2);
  // Axis-aligned bounds of the rotated w × textSize text rect at that anchor.
  LabelBox boxAt(double cx, double cy, double d) {
    final (x0, y0) = anchorFor(cx, cy, d);
    final xs = [x0, x0 + ca * w, x0 - sa * textSize, x0 + ca * w - sa * textSize];
    final ys = [y0, y0 + sa * w, y0 + ca * textSize, y0 + sa * w + ca * textSize];
    return (
      minX: xs.reduce(math.min),
      minY: ys.reduce(math.min),
      maxX: xs.reduce(math.max),
      maxY: ys.reduce(math.max),
    );
  }

  final du = 0.7 * textSize; // upper offset
  final dl = -(0.7 * textSize + textSize); // lower offset (backs off the box)

  // Greedy ladder: midpoint upper, midpoint lower, quarter upper, quarter lower
  // (the exact order — and geometry — of the old greedy placer).
  final greedy = <(double, double, double)>[
    (mx, my, du),
    (mx, my, dl),
    (ax + dx * 0.25, ay + dy * 0.25, du),
    (ax + dx * 0.25, ay + dy * 0.25, dl),
  ];
  for (final (cx, cy, d) in greedy) {
    final box = boxAt(cx, cy, d);
    if (!placed.any((p) => _boxesOverlap(p, box))) {
      placed.add(box);
      final (x0, y0) = anchorFor(cx, cy, d);
      return LeaderedLabelPlacement(x: x0, y: y0, angleDeg: angleDeg);
    }
  }

  // Nothing cleared → escape perpendicular from the midpoint in growing steps,
  // tracking the least-overlapping fallback. The tag is never dropped.
  var bestD = du;
  var bestBox = boxAt(mx, my, du);
  var bestOverlap = double.infinity;
  var cleared = false;
  for (var k = 1; k <= _kLeaderEscapeSteps && !cleared; k++) {
    final step = _kLeaderEscapeFactor * textSize * k;
    for (final d in [du + step, dl - step]) {
      final box = boxAt(mx, my, d);
      final ov = _totalOverlapArea(box, placed);
      if (ov < bestOverlap) {
        bestOverlap = ov;
        bestBox = box;
        bestD = d;
      }
      if (ov <= 0) {
        cleared = true;
        break;
      }
    }
  }
  placed.add(bestBox);
  final (x0, y0) = anchorFor(mx, my, bestD);
  return LeaderedLabelPlacement(
      x: x0, y: y0, angleDeg: angleDeg, leaderAnchor: (x: mx, y: my));
}

// ── N4: reference setting-out grid (first honest increment) ─────────────────
//
// The plan export draws the network + labels + chrome but nothing that LOCATES
// a pipe in the building — no column grid, no dimension to a structural datum.
// This adds an OPT-IN reference grid (labelled column/row axes in sheet pixels,
// the same space the drawn nodes live in) the exporters draw as thin chain
// lines with bubble labels, plus auto per-riser TIE dimensions to the nearest
// axes. Null/empty ⇒ nothing drawn (byte-identical). Positions are supplied by
// the caller; the engine never invents a grid.

/// DXF layer the reference gridlines live on (grey, chain linetype) so a CAD
/// user can toggle the setting-out grid independently.
const String kDxfLayerGrid = 'G-ANNO-GRID';

/// One labelled setting-out axis at a fixed sheet-pixel [position] — a vertical
/// column line (constant x, label like `A`) or a horizontal row line (constant
/// y, label like `1`), per which list it sits in on [ReferenceGrid].
class GridAxis {
  final String label;
  final double position;
  const GridAxis(this.label, this.position);
}

/// A reference setting-out grid for a plan export (N4): vertical column axes
/// ([columns], constant sheet-x) + horizontal row axes ([rows], constant
/// sheet-y), in sheet pixels. [isEmpty] ⇒ the exporters draw nothing.
class ReferenceGrid {
  final List<GridAxis> columns;
  final List<GridAxis> rows;
  const ReferenceGrid({this.columns = const [], this.rows = const []});
  bool get isEmpty => columns.isEmpty && rows.isEmpty;
}

/// The axis in [axes] whose [GridAxis.position] is nearest [pos], or null when
/// [axes] is empty — for a riser tie to its closest setting-out line.
GridAxis? nearestAxis(List<GridAxis> axes, double pos) {
  GridAxis? best;
  var bestErr = double.infinity;
  for (final a in axes) {
    final err = (a.position - pos).abs();
    if (err < bestErr) {
      bestErr = err;
      best = a;
    }
  }
  return best;
}

/// Format a tie-dimension offset of [offsetPx] sheet pixels as an integer
/// millimetre string (CAD dimension convention, no unit), or null when the
/// sheet is uncalibrated ([metersPerPixel] null/≤0 — a dimension without a scale
/// would be fabricated) or the node sits on the axis (< 1 mm, nothing to tie).
String? formatTieOffsetMm(double offsetPx, double? metersPerPixel) {
  if (metersPerPixel == null || metersPerPixel <= 0) return null;
  final mm = offsetPx * metersPerPixel * 1000;
  if (mm < 1) return null;
  return mm.round().toString();
}
