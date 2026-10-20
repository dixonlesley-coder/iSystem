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

import '../geometry/building.dart';
import '../network/network.dart';
import '../sizing/drainage_advisory.dart' show laidGravitySlope;
import '../sizing/network_sizing.dart' show EdgeSizing;
import '../standards/custom_fixture.dart';
import '../standards/sni.dart' show PlumbingFixture;
import '../units.dart';
import 'drawing_chrome.dart' show LabelBox;
import 'number_format.dart' show signedElevationText;
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
// NOTE — the equipment schedule (`gatherEquipmentScheduleData`) keys its rows
// by THIS map (drafting-7): the supply pump row takes the tag of the first
// drawn pump/booster on a non-fire service, the fire pump row the first pump on
// a fire service, the duct fan row the first drawn supply/exhaust fan, and each
// room's AHU row the AHU node drawn inside that room — so plan, riser and
// schedule print the same tag for the same unit. Only when no such unit is
// DRAWN does the schedule fall back to its own fixed tag (`P-01` / `FP-01` /
// `F-01`, or the room-identity `AHU-NN`); tanks appear in no schedule row.

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
/// Round 33 (engineer-walkthrough-plan-fixtures-anonymous) — the short
/// ASCII PLAN CODE of a plumbing fixture / drain terminal: WC (water closet,
/// flush valve or tank), UR (urinal), LAV (lavatory), SH (shower), BT
/// (bathtub), KS (kitchen sink), HB (hose bibb), FD (floor drain). Null for
/// anything else (equipment carries its own `P-01` tag). Pure; the plan PDF
/// and DXF print it beside the fixture glyph (one placer, PDF == DXF).
///
/// Round 33 r2 — a node typed from the user fixture LIBRARY
/// ([NetNode.customFixtureId] resolving in [customFixtures]) prints its
/// short name ([customFixturePlanCode]) instead, so a custom fixture is never
/// anonymous on the plan; an unresolved id falls back to the built-in rule.
String? fixturePlanCode(NetNode n,
    {Map<String, CustomFixture> customFixtures = const {}}) {
  final customId = n.customFixtureId;
  if (customId != null) {
    final cf = customFixtures[customId];
    final code = cf == null ? null : customFixturePlanCode(cf);
    if (code != null) return code;
  }
  if (n.component == NodeComponent.floorDrain) return 'FD';
  // Round 34 (fire-hvac-drawings-air-terminals-and-heads-carry-no-data) —
  // fire outlets are coded too, so a reviewer can count them on the plan.
  if (n.component == NodeComponent.hydrantBox) return 'HYD';
  if (n.component == NodeComponent.hoseReel) return 'HR';
  return switch (n.fixture) {
    PlumbingFixture.waterClosetFlushValve ||
    PlumbingFixture.waterClosetFlushTank =>
      'WC',
    PlumbingFixture.urinalFlushTank => 'UR',
    PlumbingFixture.lavatory => 'LAV',
    PlumbingFixture.shower => 'SH',
    PlumbingFixture.bathtub => 'BT',
    PlumbingFixture.kitchenSink => 'KS',
    PlumbingFixture.hoseBibb => 'HB',
    null => null,
  };
}

/// Round 33 r2 — the max length of a custom fixture's plan code.
const int kCustomFixturePlanCodeMaxChars = 12;

/// Round 33 r2 (engineer-walkthrough-plan-fixtures-anonymous) — the plan
/// code of a user-library [fixture]: its NAME, reduced to plan-safe ASCII
/// (letters, digits, space, `-`, `/`, `.`; runs of whitespace collapsed) and
/// shortened to [kCustomFixturePlanCodeMaxChars] — cut at the last word break
/// that fits, else hard. Self-describing, so it takes no legend entry. Null
/// when nothing printable is left (the node then reads as an unnamed fixture).
String? customFixturePlanCode(CustomFixture fixture) {
  final ascii = fixture.name
      .replaceAll(RegExp(r'[^A-Za-z0-9 ./-]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (ascii.isEmpty) return null;
  if (ascii.length <= kCustomFixturePlanCodeMaxChars) return ascii;
  final head = ascii.substring(0, kCustomFixturePlanCodeMaxChars + 1);
  final cut = head.lastIndexOf(' ');
  return (cut > 0
          ? ascii.substring(0, cut)
          : ascii.substring(0, kCustomFixturePlanCodeMaxChars))
      .trim();
}

/// Round 33 r2 — the plan codes of every node typed from the user fixture
/// [library] (node id → [customFixturePlanCode]). The app merges these under
/// the equipment tags it hands the plan PDF / DXF (`nodeTags`), so both
/// formats print the custom name through the one placer.
Map<String, String> customFixturePlanTags(
    Network net, Iterable<CustomFixture> library) {
  final byId = {for (final f in library) f.id: f};
  if (byId.isEmpty) return const {};
  final out = <String, String>{};
  for (final n in net.nodes) {
    final id = n.customFixtureId;
    if (id == null) continue;
    final f = byId[id];
    final code = f == null ? null : customFixturePlanCode(f);
    if (code != null) out[n.id] = code;
  }
  return out;
}

/// Round 33 — what each [fixturePlanCode] stands for (the plan legend key).
const Map<String, String> kFixturePlanCodeNames = {
  'WC': 'water closet',
  'UR': 'urinal',
  'LAV': 'lavatory',
  'SH': 'shower',
  'BT': 'bathtub',
  'KS': 'kitchen sink',
  'HB': 'hose bibb',
  'FD': 'floor drain',
  'HYD': 'hydrant box',
  'HR': 'hose reel',
};

/// Round 34 (fire-hvac-drawings-legend-lacks-symbols) — the components whose
/// plan glyph appears on ([sheetId], [floorIndex]), each once, in the enum's
/// canonical order: the legend's symbol key ([DrawingChrome.legendSymbols]).
/// Pure; no drawn component ⇒ empty.
List<NodeComponent> planLegendSymbols(Network net,
    {required String sheetId, required int floorIndex}) {
  final present = <NodeComponent>{
    for (final n in net.nodes)
      if (n.sheetId == sheetId &&
          n.floorIndex == floorIndex &&
          n.component != null)
        n.component!,
  };
  return [
    for (final c in NodeComponent.values)
      if (present.contains(c)) c,
  ];
}

/// Round 34 (fire-hvac-drawings-air-terminals-and-heads-carry-no-data) — the
/// installer's tag of an AIR TERMINAL (supply / linear diffuser, return /
/// exhaust grille): its design airflow and, when chosen, its face size —
/// `200 L/s 450x450`. Null for a node that is not an air terminal or carries
/// no airflow (nothing honest to print). Pure ASCII, so PDF == DXF.
String? airTerminalPlanTag(NetNode n) {
  switch (n.component) {
    case NodeComponent.supplyDiffuser:
    case NodeComponent.linearDiffuser:
    case NodeComponent.returnGrille:
    case NodeComponent.exhaustGrille:
      break;
    default:
      return null;
  }
  final q = n.airflow;
  if (q == null ||
      !q.cubicMetersPerSecond.isFinite ||
      q.cubicMetersPerSecond <= 0) {
    return null;
  }
  final ls = q.inLitersPerSecond;
  final flow =
      '${ls >= 10 ? ls.toStringAsFixed(0) : ls.toStringAsFixed(1)} L/s';
  final w = n.faceWidthMm, h = n.faceHeightMm;
  if (w != null && h != null && w > 0 && h > 0 && w.isFinite && h.isFinite) {
    return '$flow ${w.round()}x${h.round()}';
  }
  return flow;
}

/// Round 34 — [airTerminalPlanTag] for every air terminal on ([sheetId],
/// [floorIndex]) not already tagged in [nodeTags].
Map<String, String> airTerminalPlanTags(Network net,
    {required String sheetId,
    required int floorIndex,
    Map<String, String>? nodeTags}) {
  final out = <String, String>{};
  for (final n in net.nodes) {
    if (n.sheetId != sheetId || n.floorIndex != floorIndex) continue;
    if ((nodeTags?[n.id] ?? '').isNotEmpty) continue;
    final t = airTerminalPlanTag(n);
    if (t != null) out[n.id] = t;
  }
  return out;
}

/// Round 33 — the fixture-code tags of every node on ([sheetId],
/// [floorIndex]) that carries a [fixturePlanCode] and no tag in [nodeTags].
Map<String, String> fixturePlanTags(Network net,
    {required String sheetId,
    required int floorIndex,
    Map<String, String>? nodeTags}) {
  final out = <String, String>{};
  for (final n in net.nodes) {
    if (n.sheetId != sheetId || n.floorIndex != floorIndex) continue;
    if ((nodeTags?[n.id] ?? '').isNotEmpty) continue;
    final code = fixturePlanCode(n);
    if (code != null) out[n.id] = code;
  }
  return out;
}

/// Round 33 — the plan sheet NOTES a plan PDF / DXF prints once in its
/// legend (reserved chrome, PDF == DXF text):
///   * the fixture codes used on the sheet ([fixtureTags]);
///   * (engineer-walkthrough-plan-cl-datum-unstated) the `CL` datum when the
///     sheet prints centreline heights ([hasCentrelineLabels]) and the
///     floor's FFL is known: `CL = pipe centreline above this floor's FFL
///     (<floor> FFL +16.00)` — a floor plan's CL is floor-relative while the
///     riser sheet states absolute levels;
///   * (engineer-walkthrough-plan-fall-below-own-minimum) the laid-fall
///     rule when some drainage run is printed steeper than the project
///     slope ([laidGravitySlope]).
/// Pure; empty ⇒ nothing printed.
List<String> planSheetNotes({
  required Network net,
  required String sheetId,
  required int floorIndex,
  Map<String, String> fixtureTags = const {},
  bool hasCentrelineLabels = false,
  double? floorFflM,
  String? floorName,
  double? gravitySlope,
  Map<String, EdgeSizing> sizing = const {},
  double? sprinklerKFactor,
  String? sprinklerHazard,
}) {
  final notes = <String>[];
  final codes = fixtureTags.values.toSet().toList()
    ..sort((a, b) {
      final ka = kFixturePlanCodeNames.keys.toList();
      return ka.indexOf(a).compareTo(ka.indexOf(b));
    });
  // A custom-library code is its own name (self-describing): no key entry.
  codes.removeWhere((c) => !kFixturePlanCodeNames.containsKey(c));
  if (codes.isNotEmpty) {
    notes.add(codes.map((c) => '$c ${kFixturePlanCodeNames[c]}').join(' - '));
  }
  if (hasCentrelineLabels && floorFflM != null && floorFflM.isFinite) {
    final where = [
      if (floorName != null && floorName.isNotEmpty) floorName,
      'FFL ${signedElevationText(floorFflM)}',
    ].join(' ');
    notes.add("CL = pipe centreline above this floor's FFL ($where)");
  }
  // Round 34 — a floor with sprinkler heads states the head basis once: the
  // project K-factor (and hazard class) the remote-area check used, flagged
  // VERIFY (head-model dependent, never a certified head selection).
  final k = sprinklerKFactor;
  if (k != null &&
      k.isFinite &&
      k > 0 &&
      net.nodes.any((n) =>
          n.component == NodeComponent.sprinklerHead &&
          n.sheetId == sheetId &&
          n.floorIndex == floorIndex)) {
    final hazard = (sprinklerHazard == null || sprinklerHazard.isEmpty)
        ? ''
        : ', $sprinklerHazard';
    notes.add('Sprinkler heads: K ${k.toStringAsFixed(0)} '
        '(L/min/bar^0.5)$hazard - VERIFY head model');
  }
  final slope = gravitySlope;
  if (slope != null && slope > 0 && slope.isFinite) {
    var steeper = false;
    for (final e in net.edges) {
      if (e.service != ServiceType.drainage || e.kind != EdgeKind.run) continue;
      final a = net.nodeById(e.fromId), c = net.nodeById(e.toId);
      bool on(NetNode? n) =>
          n != null && n.sheetId == sheetId && n.floorIndex == floorIndex;
      if (!on(a) || !on(c)) continue;
      final d = sizing[e.id]?.diameter.inMillimeters;
      if (laidGravitySlope(e, slope, d) > slope + 1e-12) {
        steeper = true;
        break;
      }
    }
    if (steeper) {
      notes.add('Drain fall: <= DN65 at 1:50 min, DN75-150 at 1:100 min, '
          'else ${gravitySlopeLabel(slope)}');
    }
  }
  return notes;
}

///
/// Round 33 (engineer-walkthrough-equipment-tag-global-ordinal) — a node
/// minted with a per-prefix [NetNode.tagNo] claims THAT number first (the
/// first pump drawn is P-01, never P-41 after 40 fixtures); legacy nodes
/// without one keep the node-id ordinal rule below, unchanged.
Map<String, String> equipmentNodeTags(Network net) {
  final out = <String, String>{};
  final used = <String, Set<int>>{};
  final unnumbered = <(String nodeId, String prefix)>[];

  String format(String prefix, int n) =>
      '$prefix-${n.toString().padLeft(2, '0')}';

  final claimed = <String>{};
  for (final n in net.nodes) {
    final c = n.component;
    final no = n.tagNo;
    if (c == null || no == null || no < 1) continue;
    final prefix = equipmentTagPrefix(c);
    if (prefix == null) continue;
    if (!used.putIfAbsent(prefix, () => <int>{}).add(no)) continue;
    out[n.id] = format(prefix, no);
    claimed.add(n.id);
  }

  for (final n in net.nodes) {
    if (claimed.contains(n.id)) continue;
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

// ── N3 / R5: never-drop, run-hugging leadered edge-label placer ─────────────
//
// The shared `drawing_chrome.placeEdgeLabel` DROPS a size tag when no greedy
// slot clears — on dense branches that silently loses labels. The first N3
// placer fixed the drop but escaped STRAIGHT OUT from the midpoint in growing
// steps (up to ~170 pt), so on a real floor a tag landed far from its run on a
// long leader that crossed other services (R5: `V-F2 · DN32 - …` leadered from
// the sheet top). The R5 placer reads like a drafter's hand:
//
//   1. ALONG + BESIDE the run first — the tag stays parallel to its run, on
//      either side, at several stations along it (mid, quarters, eighths), at
//      the standard 0.7 × text offset; no leader.
//   2. TWO LINES before escaping — a long label is split `tag · size` over
//      `length - CL - fall` ([composePlanEdgeLabelLines]) so it fits beside a
//      short run; a label much longer than its run tries the split first.
//   3. Only then ESCAPE, one text row at a time, still parallel and still
//      opposite a station on the run, with the leader CAPPED at
//      [kPlanLeaderMaxFactor] × text size; among clear slots the placer prefers
//      one whose leader crosses NO other run, then the shortest leader.
//
// Collision is judged on the label's real ORIENTED rectangle (a 45° tag's
// axis-aligned bounds are a huge square, which made two diagonal tags "collide"
// when they never touched and pushed both off), against: other placed labels,
// the caller's occupied boxes (frame strips, title block, node glyphs, UP/DN,
// tie text) and the other RUNS' linework (a tag never overprints another
// service when a clear slot exists). Pure and deterministic given a stable
// emission order. Both plan exporters (PDF + DXF) place through this ONE
// function, so the two formats make the same choices for the same sheet.
//
// R6 refinements: every test is SCALE-FREE (geometry ÷ text size), and both
// exporters now reach it through `layoutPlanAnnotations` with paper-sized
// marks, so the PDF and DXF make identical splits + slots; a point tag
// without a leader keeps its near edge within [kPlanAnchorAttachFactor] text
// sizes of its feature; a run may place its tag just past a FREE end; the
// setting-out grid lines are a SOFT obstacle (a tag prefers not to cross one,
// a leader never runs along one — nor along any other linework).

/// Line pitch (× text size) of a two-line label block and of the escape rows.
const double kPlanLabelLineFactor = 1.3;

/// The PREFERRED longest leader, × text size (≈ 8 text heights — ~25 mm on an
/// A3 plot at 9 pt): a clear slot within it always wins.
const double kPlanLeaderMaxFactor = 8.0;

/// The HARD leader cap, × text size: only when nothing within
/// [kPlanLeaderMaxFactor] is clear does a tag go further, and never beyond
/// this (a short leader that overprints beats a cross-sheet one).
const double kPlanLeaderHardMaxFactor = 16.0;

/// R6: a point feature's tag (riser marker, equipment glyph) placed WITHOUT a
/// leader keeps its near edge within this many text sizes of the feature;
/// any slot further out is tied back by a leader from the feature, so a tag
/// never floats unattributed beside the wrong mark.
const double kPlanAnchorAttachFactor = 1.5;

/// Clearance (× text size) a label keeps from ANOTHER run's linework.
const double _kRunClearFactor = 0.25;

/// Gap (× text size) a label keeps from other labels / occupied boxes, so two
/// tags never abut into one fused token (`DN752.4 m`).
const double _kLabelGapFactor = 0.2;

/// Stations along the run (fraction of its length) tried for the label centre,
/// in preference order: midpoint, quarters, then the 3/8 / 5/8 and eighth
/// points. The first two match the original greedy ladder (mid, quarter).
const List<double> _kAlongStations = [
  0.5,
  0.25,
  0.75,
  0.375,
  0.625,
  0.125,
  0.875
];

/// A run's linework as an obstacle segment in the output space.
typedef LabelSegment = ({double x1, double y1, double x2, double y2});

/// Round 34 (fire-hvac-drawings-double-line-duct-junctions) — one true-width
/// duct run for [planDuctOutlines]: its end node ids, its centreline (a → b)
/// in the caller's output space, and its half-width in the same units.
typedef PlanDuctRun = ({
  String id,
  String fromId,
  String toId,
  double ax,
  double ay,
  double bx,
  double by,
  double half,
});

/// Round 34 (fire-hvac-drawings-double-line-duct-junctions) — the trimmed
/// double-line OUTLINES of every [runs] entry (run id → its wall segments),
/// the ONE geometry the plan PDF and the plan DXF both draw:
///
///  * at a node shared with other double-line runs, a run's walls are
///    EXTENDED past the node by the largest half-width among those runs (so
///    an elbow's outer walls meet in a square corner instead of a notch);
///  * every wall is then CLIPPED by the (extended) rectangles of the runs it
///    meets at a shared node, removing the part strictly inside one — a
///    branch's walls stop at the trunk wall, the trunk wall breaks across the
///    take-off opening, an elbow's inner walls stop at their crossing.
///
/// A run with no double-line neighbour keeps exactly [planDoubleLineOutline]'s
/// two walls (byte-identical); ducts that merely cross (no shared node) are
/// never clipped against each other. Pure.
Map<String, List<LabelSegment>> planDuctOutlines(List<PlanDuctRun> runs) {
  final atNode = <String, List<PlanDuctRun>>{};
  for (final r in runs) {
    (atNode[r.fromId] ??= []).add(r);
    if (r.toId != r.fromId) (atNode[r.toId] ??= []).add(r);
  }
  double extAt(PlanDuctRun r, String node) {
    var ext = 0.0;
    for (final o in atNode[node] ?? const <PlanDuctRun>[]) {
      if (o.id != r.id) ext = math.max(ext, o.half);
    }
    return ext;
  }

  // The extended rectangle of a run: centre line p0 → p1, unit direction u.
  final rect = <String, ({double x0, double y0, double ux, double uy,
      double len, double half})>{};
  for (final r in runs) {
    final dx = r.bx - r.ax, dy = r.by - r.ay;
    final l = math.sqrt(dx * dx + dy * dy);
    if (l <= 0 || !(r.half > 0)) continue;
    final ux = dx / l, uy = dy / l;
    final ea = extAt(r, r.fromId), eb = extAt(r, r.toId);
    rect[r.id] = (
      x0: r.ax - ux * ea,
      y0: r.ay - uy * ea,
      ux: ux,
      uy: uy,
      len: l + ea + eb,
      half: r.half,
    );
  }

  // Parameter interval (0..1) of segment (x1,y1)-(x2,y2) strictly inside a
  // rectangle (shrunk by [eps]), or null.
  (double, double)? inside(LabelSegment s, ({double x0, double y0, double ux,
      double uy, double len, double half}) q) {
    const eps = 1e-6;
    // Local coordinates: along t, across n.
    double along(double x, double y) => (x - q.x0) * q.ux + (y - q.y0) * q.uy;
    double across(double x, double y) =>
        -(x - q.x0) * q.uy + (y - q.y0) * q.ux;
    final a1 = along(s.x1, s.y1), a2 = along(s.x2, s.y2);
    final c1 = across(s.x1, s.y1), c2 = across(s.x2, s.y2);
    var lo = 0.0, hi = 1.0;
    bool clip(double p, double q0) {
      // Keep where p*t <= q0 (Liang–Barsky).
      if (p.abs() < 1e-12) return q0 > 0;
      final t = q0 / p;
      if (p < 0) {
        if (t > hi) return false;
        if (t > lo) lo = t;
      } else {
        if (t < lo) return false;
        if (t < hi) hi = t;
      }
      return true;
    }

    final da = a2 - a1, dc = c2 - c1;
    // A wall lying ALONG the rectangle's boundary (parallel, on a side or an
    // end line) is not inside it: kept. Otherwise the exact bounds clip, so
    // the trimmed ends land exactly on the neighbour's wall (no slivers).
    if (dc.abs() < 1e-12 && c1.abs() >= q.half - eps) return null;
    if (da.abs() < 1e-12 && (a1 <= eps || a1 >= q.len - eps)) return null;
    if (!clip(-da, a1)) return null; // a >= 0
    if (!clip(da, q.len - a1)) return null; // a <= len
    if (!clip(-dc, c1 + q.half)) return null; // c >= -half
    if (!clip(dc, q.half - c1)) return null; // c <= half
    return hi - lo > 1e-9 ? (lo, hi) : null;
  }

  final out = <String, List<LabelSegment>>{};
  for (final r in runs) {
    final q = rect[r.id];
    if (q == null) {
      out[r.id] = const [];
      continue;
    }
    final nx = -q.uy * q.half, ny = q.ux * q.half;
    final x1 = q.x0, y1 = q.y0;
    final x2 = q.x0 + q.ux * q.len, y2 = q.y0 + q.uy * q.len;
    final walls = <LabelSegment>[
      (x1: x1 + nx, y1: y1 + ny, x2: x2 + nx, y2: y2 + ny),
      (x1: x1 - nx, y1: y1 - ny, x2: x2 - nx, y2: y2 - ny),
    ];
    // The runs met at a shared node (each once).
    final others = <String>{
      for (final o in atNode[r.fromId] ?? const <PlanDuctRun>[]) o.id,
      for (final o in atNode[r.toId] ?? const <PlanDuctRun>[]) o.id,
    }..remove(r.id);
    final pieces = <LabelSegment>[];
    for (final w in walls) {
      var keep = <(double, double)>[(0.0, 1.0)];
      for (final oid in others.toList()..sort()) {
        final oq = rect[oid];
        if (oq == null) continue;
        final cut = inside(w, oq);
        if (cut == null) continue;
        keep = [
          for (final (a, b) in keep) ...[
            if (cut.$1 > a) (a, math.min(b, cut.$1)),
            if (cut.$2 < b) (math.max(a, cut.$2), b),
          ],
        ].where((iv) => iv.$2 - iv.$1 > 1e-6).toList();
      }
      for (final (a, b) in keep) {
        pieces.add((
          x1: w.x1 + (w.x2 - w.x1) * a,
          y1: w.y1 + (w.y2 - w.y1) * a,
          x2: w.x1 + (w.x2 - w.x1) * b,
          y2: w.y1 + (w.y2 - w.y1) * b,
        ));
      }
    }
    out[r.id] = pieces;
  }
  return out;
}

/// One positioned text line of a placed label: its [text] and the baseline
/// START anchor ([x], [y]) in the y-up output space (rotation is the
/// placement's `angleDeg`).
typedef PlacedLabelLine = ({String text, double x, double y});

/// The shared occupancy model the plan exporters place labels into: hard
/// axis-aligned [boxes] (frame strips, title block, node glyphs, riser marks,
/// UP/DN text, tie-dimension text), the ORIENTED rectangles of labels already
/// placed, and the RUN linework segments (keyed by edge id, so a label skips
/// only its own run). Construct one per sheet, register runs + boxes, then
/// place each label with [placePlanLabel].
class PlanLabelLayout {
  /// Axis-aligned occupied boxes. Exposed (and live) so a caller can register
  /// its own marks; a legacy caller may pass its own list.
  final List<LabelBox> boxes;
  final List<List<(double, double)>> _labels = [];
  final List<({String? id, LabelSegment seg})> _runs = [];
  final List<LabelSegment> _grid = [];

  PlanLabelLayout({List<LabelBox>? boxes}) : boxes = boxes ?? <LabelBox>[];

  /// Register an occupied axis-aligned box.
  void addBox(LabelBox b) => boxes.add(b);

  /// Register a run's linework (an obstacle for every OTHER edge's label and
  /// for leaders). [id] is the owning edge id (null ⇒ obstacle for all).
  void addRun(String? id, double x1, double y1, double x2, double y2) =>
      _runs.add((id: id, seg: (x1: x1, y1: y1, x2: x2, y2: y2)));

  /// Register a setting-out GRID line (R6): a SOFT obstacle — a tag prefers a
  /// slot clear of every grid line (it is cheaper to cross than a run, so a
  /// tag still crosses one when nothing clear fits), and a leader never runs
  /// coincident with one (it would read as part of the grid).
  void addGridLine(double x1, double y1, double x2, double y2) =>
      _grid.add((x1: x1, y1: y1, x2: x2, y2: y2));

  /// Number of labels placed so far.
  int get labelCount => _labels.length;

  int _unresolved = 0;

  /// Round 24 — how many annotations were committed to a slot that STILL
  /// overprints something (a label / mark / run) because no clear slot
  /// existed: the placer never drops a tag, but it must not stay silent
  /// either — the exporters print this as a warning on the sheet.
  int get unresolvedCount => _unresolved;

  /// Record one annotation committed to an overlapping slot (a caller's own
  /// fallback, e.g. the UP/DN stack or a tie figure's historic slot).
  void markUnresolved() => _unresolved++;

  /// True when [b] overlaps an occupied box or a placed label's oriented
  /// rectangle — for a caller's own (axis-aligned) marks to dodge the labels.
  bool hitsBox(LabelBox b) {
    for (final o in boxes) {
      if (_boxesOverlap(o, b)) return true;
    }
    final q = _boxQuad(b);
    for (final l in _labels) {
      if (_quadsOverlap(l, q)) return true;
    }
    return false;
  }

  /// True when a registered run / leader / dimension line passes within
  /// [clearance] of the axis-aligned box [b] (R6: the UP/DN marks dodge runs).
  bool hitsRun(LabelBox b, {double clearance = 0}) {
    for (final r in _runs) {
      if (_segHitsBox(r.seg, b, clearance)) return true;
    }
    return false;
  }

  /// True when a registered grid line passes through the box [b].
  bool hitsGrid(LabelBox b) {
    for (final s in _grid) {
      if (_segHitsBox(s, b, 0)) return true;
    }
    return false;
  }
}

bool _segHitsBox(LabelSegment seg, LabelBox b, double clear) => _segHitsRect(
    seg,
    1,
    0,
    (b.minX + b.maxX) / 2,
    (b.minY + b.maxY) / 2,
    (b.maxX - b.minX) / 2,
    -(b.maxY - b.minY) / 2,
    (b.maxY - b.minY) / 2,
    clear);

/// Does [seg] pass within [clear] of the oriented rectangle [-hw,hw]×[v0,v1]
/// about (cx,cy) in the frame whose u axis is (ca,sa)? A Liang–Barsky clip of
/// the segment against the inflated rectangle in its local frame.
bool _segHitsRect(LabelSegment seg, double ca, double sa, double cx, double cy,
    double hw, double v0, double v1, double clear) {
  (double, double) local(double x, double y) {
    final px = x - cx, py = y - cy;
    return (px * ca + py * sa, -px * sa + py * ca);
  }

  final (u1, w1) = local(seg.x1, seg.y1);
  final (u2, w2) = local(seg.x2, seg.y2);
  var t0 = 0.0, t1 = 1.0;
  final du = u2 - u1, dw = w2 - w1;
  for (final (p, q) in [
    (-du, u1 - (-hw - clear)),
    (du, (hw + clear) - u1),
    (-dw, w1 - (v0 - clear)),
    (dw, (v1 + clear) - w1),
  ]) {
    if (p == 0) {
      if (q < 0) return false;
    } else {
      final t = q / p;
      if (p < 0) {
        if (t > t1) return false;
        if (t > t0) t0 = t;
      } else {
        if (t < t0) return false;
        if (t < t1) t1 = t;
      }
    }
  }
  return t0 < t1;
}

/// A resolved leadered edge-label placement: the first line's text anchor
/// (baseline START) + the rotation in degrees CCW in the y-up output space,
/// every positioned [lines] entry (one or two), PLUS an optional
/// [leaderAnchor] (the point ON the run the leader starts from) and
/// [leaderEnd] (the nearest point of the label block) — non-null when the
/// label was pulled off the run and a thin leader ties it back (N3/R5).
class LeaderedLabelPlacement {
  final double x;
  final double y;
  final double angleDeg;
  final ({double x, double y})? leaderAnchor;
  final ({double x, double y})? leaderEnd;
  final List<PlacedLabelLine> lines;
  const LeaderedLabelPlacement({
    required this.x,
    required this.y,
    required this.angleDeg,
    this.leaderAnchor,
    this.leaderEnd,
    this.lines = const [],
  });
}

bool _boxesOverlap(LabelBox a, LabelBox b) =>
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY;

List<(double, double)> _boxQuad(LabelBox b) => [
      (b.minX, b.minY),
      (b.maxX, b.minY),
      (b.maxX, b.maxY),
      (b.minX, b.maxY),
    ];

LabelBox _quadBounds(List<(double, double)> q) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final (x, y) in q) {
    minX = math.min(minX, x);
    minY = math.min(minY, y);
    maxX = math.max(maxX, x);
    maxY = math.max(maxY, y);
  }
  return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
}

/// Separating-axis test for two convex quads (strict: touching ≠ overlap).
bool _quadsOverlap(List<(double, double)> a, List<(double, double)> b) {
  for (final poly in [a, b]) {
    for (var i = 0; i < poly.length; i++) {
      final (x1, y1) = poly[i];
      final (x2, y2) = poly[(i + 1) % poly.length];
      final nx = -(y2 - y1), ny = x2 - x1;
      if (nx == 0 && ny == 0) continue;
      var aMin = double.infinity, aMax = -double.infinity;
      for (final (x, y) in a) {
        final p = x * nx + y * ny;
        aMin = math.min(aMin, p);
        aMax = math.max(aMax, p);
      }
      var bMin = double.infinity, bMax = -double.infinity;
      for (final (x, y) in b) {
        final p = x * nx + y * ny;
        bMin = math.min(bMin, p);
        bMax = math.max(bMax, p);
      }
      // Tolerance scaled to the axis length keeps exactly-touching boxes clear.
      final eps = 1e-9 * (nx.abs() + ny.abs());
      if (aMax <= bMin + eps || bMax <= aMin + eps) return false;
    }
  }
  return true;
}

/// Proper (crossing) intersection of two segments — shared endpoints and
/// collinear touches do NOT count (a leader that starts on a junction is fine).
bool _segmentsCross(double ax, double ay, double bx, double by, double cx,
    double cy, double dx, double dy) {
  double orient(
          double px, double py, double qx, double qy, double rx, double ry) =>
      (qx - px) * (ry - py) - (qy - py) * (rx - px);
  final d1 = orient(cx, cy, dx, dy, ax, ay);
  final d2 = orient(cx, cy, dx, dy, bx, by);
  final d3 = orient(ax, ay, bx, by, cx, cy);
  final d4 = orient(ax, ay, bx, by, dx, dy);
  const eps = 1e-9;
  return ((d1 > eps && d2 < -eps) || (d1 < -eps && d2 > eps)) &&
      ((d3 > eps && d4 < -eps) || (d3 < -eps && d4 > eps));
}

/// The two-line form of a plan edge label: line 1 = `<tag> · <size>` (the
/// element identity + size), line 2 = `<length> - <CL> - <fall>` (the set-out
/// data). Returns null when the label would not split (nothing on one of the
/// two lines). Pure; the joined form is [composePlanEdgeLabel].
List<String>? composePlanEdgeLabelLines({
  String? tag,
  String? size,
  String? length,
  String? elevation,
  String? slope,
}) {
  final first = composePlanEdgeLabel(tag: tag, size: size);
  final rest = <String>[
    for (final p in [length, elevation, slope])
      if (p != null && p.isNotEmpty) p,
  ];
  if (first == null || rest.isEmpty) return null;
  return [first, rest.join(' - ')];
}

/// Place a plan edge label for the run (ax,ay)→(bx,by) into [layout] (see the
/// section note above): [text] is the one-line form, [splitLines] the optional
/// two-line form ([composePlanEdgeLabelLines]); [ownRunId] names the run the
/// label belongs to (its own linework is not an obstacle). Text width is
/// estimated as chars × size × 0.55 (the Helvetica average). The first
/// beside-the-run slot that clears wins with no leader — the midpoint upper
/// slot is byte-identical to the original greedy placer. Never returns null:
/// a size tag is content, never dropped. The placed rectangle is recorded in
/// [layout] (and its bounds appended to `layout.boxes` when [recordBounds]).
///
/// Every decision is SCALE-FREE: it reads only ratios of geometry to
/// [textSize], so two exporters that hand the placer the same sheet in
/// different units (PDF points, DXF model millimetres) at the same plotted
/// text-to-geometry ratio make the same line split and the same slot choice
/// (R6 — see `layoutPlanAnnotations`).
///
/// For a POINT feature labelled along a short pseudo-run beside it (a riser
/// marker, an equipment glyph), [anchorPoint] names the feature: the tag is
/// tried hugging it on either side (its NEAR edge at the pseudo-run's gap,
/// whatever the line form's width) and centred over / under it, and a slot
/// with no leader must keep its near edge within [kPlanAnchorAttachFactor] ×
/// text size of the feature — a tag any further away is tied back by a leader
/// from the feature itself (R6), so it can never float unattributed.
/// [extraStations] (same bearing) adds caller stations.
///
/// A RUN (no [anchorPoint]) also gets stations just BEYOND each end along its
/// axis (R6), so a tag in a narrow wedge can sit past the run end instead of
/// escaping on a leader across a neighbouring run — only past a FREE end (no
/// other registered run meets it), and only when [beyondEnds] (a caller that
/// registers no run topology turns it off).
LeaderedLabelPlacement placePlanLabel({
  required double ax,
  required double ay,
  required double bx,
  required double by,
  required String text,
  required double textSize,
  required PlanLabelLayout layout,
  List<String>? splitLines,
  String? ownRunId,
  bool recordBounds = false,
  ({double x, double y})? anchorPoint,
  List<({double x, double y})> extraStations = const [],
  bool beyondEnds = true,
  double ownHalfWidth = 0,
}) {
  final dx = bx - ax, dy = by - ay;
  var angle = (dx == 0 && dy == 0) ? 0.0 : math.atan2(dy, dx);
  if (angle > math.pi / 2 || angle <= -math.pi / 2) {
    angle += angle > 0 ? -math.pi : math.pi;
  }
  final ca = math.cos(angle), sa = math.sin(angle);
  final angleDeg = angle * 180 / math.pi;
  final ts = textSize;
  final eps = 1e-9 * ts; // scale-free tolerance (R6)
  final lh = kPlanLabelLineFactor * ts;
  final runLen = math.sqrt(dx * dx + dy * dy);
  double widthOf(String s) => s.length * ts * 0.55;

  // Line forms, in preference order. A label much longer than its run reads
  // as detached from it, so the split form goes first there.
  final single = [text];
  final split =
      (splitLines != null && splitLines.length == 2) ? splitLines : null;
  final forms = <List<String>>[
    if (split != null && widthOf(text) > runLen * 1.15) split,
    single,
    if (split != null && widthOf(text) <= runLen * 1.15) split,
  ];
  double halfWidthOf(List<String> form) {
    var w = 0.0;
    for (final s in form) {
      w = math.max(w, widthOf(s));
    }
    return w / 2;
  }

  // Local frame: u along the (upright) bearing, v along the upper normal.
  (double, double) world(double cx, double cy, double u, double v) =>
      (cx + ca * u - sa * v, cy + sa * u + ca * v);

  // A candidate block: centre station (cx,cy), side (+1 upper / -1 lower /
  // 0 centred ON the axis — the beyond-the-end slots), near-edge offset d.
  _Block block(List<String> form, double cx, double cy, int side, double d) {
    final n = form.length;
    final h = ts + (n - 1) * lh;
    final maxW = 2 * halfWidthOf(form);
    final v0 = side > 0 ? d : (side < 0 ? -(d + h) : -h / 2);
    final v1 = v0 + h;
    final lines = <PlacedLabelLine>[];
    for (var i = 0; i < n; i++) {
      final base = v1 - ts - i * lh;
      final (x0, y0) = world(cx, cy, -widthOf(form[i]) / 2, base);
      lines.add((text: form[i], x: x0, y: y0));
    }
    final quad = [
      world(cx, cy, -maxW / 2, v0),
      world(cx, cy, maxW / 2, v0),
      world(cx, cy, maxW / 2, v1),
      world(cx, cy, -maxW / 2, v1),
    ];
    // The collision footprint keeps a small gap around the text.
    final g = _kLabelGapFactor * ts;
    final padded = [
      world(cx, cy, -maxW / 2 - g, v0 - g / 2),
      world(cx, cy, maxW / 2 + g, v0 - g / 2),
      world(cx, cy, maxW / 2 + g, v1 + g / 2),
      world(cx, cy, -maxW / 2 - g, v1 + g / 2),
    ];
    return _Block(quad, padded, lines, cx, cy, v0, v1, maxW / 2);
  }

  // Does an oriented block come within the run clearance of another run's
  // linework?
  final clear = _kRunClearFactor * ts;
  int runHits(_Block b) {
    var hits = 0;
    for (final r in layout._runs) {
      if (r.id != null && r.id == ownRunId) continue;
      if (_segHitsRect(r.seg, ca, sa, b.cx, b.cy, b.halfW, b.v0, b.v1, clear)) {
        hits++;
      }
    }
    return hits;
  }

  // How many setting-out grid lines pass through the block (R6, soft).
  int gridHits(_Block b) {
    var hits = 0;
    for (final s in layout._grid) {
      if (_segHitsRect(s, ca, sa, b.cx, b.cy, b.halfW, b.v0, b.v1, 0)) hits++;
    }
    return hits;
  }

  bool hitsPlaced(List<(double, double)> quad) {
    final bounds = _quadBounds(quad);
    for (final o in layout.boxes) {
      if (_boxesOverlap(o, bounds) && _quadsOverlap(_boxQuad(o), quad)) {
        return true;
      }
    }
    for (final l in layout._labels) {
      if (_quadsOverlap(l, quad)) return true;
    }
    return false;
  }

  double overlapArea(List<(double, double)> quad) {
    final r = _quadBounds(quad);
    var total = 0.0;
    void add(LabelBox p) {
      final ox = math.min(r.maxX, p.maxX) - math.max(r.minX, p.minX);
      final oy = math.min(r.maxY, p.maxY) - math.max(r.minY, p.minY);
      if (ox > 0 && oy > 0) total += ox * oy;
    }

    for (final o in layout.boxes) {
      add(o);
    }
    for (final l in layout._labels) {
      if (_quadsOverlap(l, quad)) add(_quadBounds(l));
    }
    return total;
  }

  // Distance from the point feature to the block's (unpadded) rectangle.
  double anchorGap(_Block b) {
    final a = anchorPoint!;
    final px = a.x - b.cx, py = a.y - b.cy;
    final u = px * ca + py * sa, w = -px * sa + py * ca;
    final du = math.max(u.abs() - b.halfW, 0.0);
    final dv = w < b.v0 ? b.v0 - w : (w > b.v1 ? w - b.v1 : 0.0);
    return math.sqrt(du * du + dv * dv);
  }

  LeaderedLabelPlacement commit(_Block b,
      {({double x, double y})? anchor, ({double x, double y})? end}) {
    layout._labels.add(b.quad);
    if (recordBounds) layout.boxes.add(_quadBounds(b.quad));
    // A drawn leader is linework too: later tags keep clear of it.
    if (anchor != null && end != null) {
      layout.addRun(null, anchor.x, anchor.y, end.x, end.y);
    }
    return LeaderedLabelPlacement(
      x: b.lines.first.x,
      y: b.lines.first.y,
      angleDeg: angleDeg,
      leaderAnchor: anchor,
      leaderEnd: end,
      lines: b.lines,
    );
  }

  // The standard beside-the-run offset, measured from the run's DRAWN edge:
  // Round 29 (drawings-3-3) — a true-width (double-line) duct's tag clears
  // its own outline ([ownHalfWidth] = the paper half-width; 0 for a
  // single-line run ⇒ byte-identical), never printing along the duct edge.
  final du = 0.7 * ts + (ownHalfWidth > 0 ? ownHalfWidth : 0);
  final along = [
    for (final t in _kAlongStations) (ax + dx * t, ay + dy * t),
    for (final p in extraStations) (p.x, p.y),
  ];
  // The along-bearing gap from the point feature to the pseudo-run's start.
  final anchorAlong = anchorPoint == null
      ? 0.0
      : math.max((ax - anchorPoint.x) * ca + (ay - anchorPoint.y) * sa, 0.0);

  // Is the run end (x,y) FREE — no other run starts or ends there?
  bool freeEnd(double x, double y) {
    final tol = 0.05 * ts;
    for (final r in layout._runs) {
      if (r.id == null || r.id == ownRunId) continue;
      for (final (px, py) in [(r.seg.x1, r.seg.y1), (r.seg.x2, r.seg.y2)]) {
        if ((px - x).abs() <= tol && (py - y).abs() <= tol) return false;
      }
    }
    return true;
  }

  // The candidate slots for one line form, in preference order: (station,
  // side, near-edge offset). A point feature first hugs itself on either side
  // (near edge at the pseudo-run gap) and centred over / under itself; a run
  // tries its along stations — and, as a later [beyond] pass over every form,
  // just past each end along its axis (centred on it, then either side).
  List<(double, double, int, double)> slots(List<String> form, double d,
      {bool beyond = false}) {
    final out = <(double, double, int, double)>[];
    final hw = halfWidthOf(form);
    if (beyond) {
      if (!beyondEnds || anchorPoint != null || runLen <= 0) return out;
      final ox = dx / runLen, oy = dy / runLen; // outward at the b end
      for (final g in const [0.5, 1.5]) {
        final r = hw + g * ts;
        for (final (ex, ey, s) in [(bx, by, 1.0), (ax, ay, -1.0)]) {
          // Only past a FREE end: where another run continues (a tee, an
          // elbow, a pump between two runs) the tag would read as tagging it.
          if (!freeEnd(ex, ey)) continue;
          final cx = ex + ox * r * s, cy = ey + oy * r * s;
          out
            ..add((cx, cy, 0, 0))
            ..add((cx, cy, 1, d))
            ..add((cx, cy, -1, d));
        }
      }
      return out;
    }
    if (anchorPoint != null) {
      final r = anchorAlong + hw;
      for (final s in const [1.0, -1.0]) {
        final cx = anchorPoint.x + ca * r * s, cy = anchorPoint.y + sa * r * s;
        out
          ..add((cx, cy, 1, d))
          ..add((cx, cy, -1, d));
      }
      out
        ..add((anchorPoint.x, anchorPoint.y, 1, d))
        ..add((anchorPoint.x, anchorPoint.y, -1, d));
    }
    for (final (cx, cy) in along) {
      out
        ..add((cx, cy, 1, d))
        ..add((cx, cy, -1, d));
    }
    return out;
  }

  // 1 + 2. Beside the run: every slot, one then two lines. A slot clear of
  // every grid line wins outright; the first slot that only crosses a grid
  // line is the fallback before any escape (R6).
  final attach = kPlanAnchorAttachFactor * ts;
  _Block? gridFallback;
  for (final beyond in const [false, true]) {
    for (final form in forms) {
      for (final (cx, cy, side, d) in slots(form, du, beyond: beyond)) {
        final b = block(form, cx, cy, side, d);
        if (hitsPlaced(b.padded)) continue;
        if (runHits(b) > 0) continue;
        if (anchorPoint != null && anchorGap(b) > attach + eps) continue;
        if (gridHits(b) == 0) return commit(b);
        gridFallback ??= b;
      }
    }
    // A beside slot that only crosses a grid line still beats moving past
    // the run end (and any escape).
    if (gridFallback != null) return commit(gridFallback);
  }

  // 3. Escape row by row, still parallel + opposite a station, leader capped.
  final cap = kPlanLeaderMaxFactor * ts;
  final hardCap = kPlanLeaderHardMaxFactor * ts;
  _Block? best;
  ({double x, double y})? bestA, bestE;
  var bestLeaderStrikesLabel = false;
  // Lexicographic score: (tier, crossings, grid hits, overprint, leader).
  var bestScore = (9, 1 << 30, 1 << 30, double.infinity, double.infinity);
  bool better((int, int, int, double, double) s) {
    if (s.$1 != bestScore.$1) return s.$1 < bestScore.$1;
    if (s.$2 != bestScore.$2) return s.$2 < bestScore.$2;
    if (s.$3 != bestScore.$3) return s.$3 < bestScore.$3;
    if ((s.$4 - bestScore.$4).abs() > eps * ts) return s.$4 < bestScore.$4;
    return s.$5 < bestScore.$5 - eps;
  }

  // A leader must never run COINCIDENT with other linework (R6) — a grid
  // line, another run, a dimension / extension line: parallel to it and
  // within a hair of it along an overlapping span, it would read as part of
  // that line instead of a leader.
  final linework = <LabelSegment>[
    ...layout._grid,
    for (final r in layout._runs)
      if (r.id == null || r.id != ownRunId) r.seg,
  ];
  bool onLinework(double sx, double sy, double ex, double ey) {
    final lx = ex - sx, ly = ey - sy;
    final ll = math.sqrt(lx * lx + ly * ly);
    if (ll <= eps) return false;
    for (final g in linework) {
      final gx = g.x2 - g.x1, gy = g.y2 - g.y1;
      final gl = math.sqrt(gx * gx + gy * gy);
      if (gl <= eps) continue;
      // Parallel within ~1°.
      if ((lx * gy - ly * gx).abs() > 0.02 * ll * gl) continue;
      // Perpendicular distance of the leader start from the line.
      final dist = ((sx - g.x1) * gy - (sy - g.y1) * gx).abs() / gl;
      if (dist > 0.25 * ts) continue;
      // Overlapping projections along the line (a leader that only meets it
      // end-to-end, continuing away from it, is fine).
      final t1 = ((sx - g.x1) * gx + (sy - g.y1) * gy) / gl;
      final t2 = ((ex - g.x1) * gx + (ey - g.y1) * gy) / gl;
      if (math.max(t1, t2) > eps && math.min(t1, t2) < gl - eps) return true;
    }
    return false;
  }

  // Escape prefers the compact (two-line) form when one exists.
  final escapeForms = [if (split != null) split, single];
  for (final form in escapeForms) {
    for (var k = 1; du + k * lh <= hardCap + eps; k++) {
      final d = du + k * lh;
      for (final (cx, cy, side, dd) in slots(form, d)) {
        final b = block(form, cx, cy, side, dd);
        // The leader runs from the station on the run to the NEAREST point
        // of the block (its near edge, clamped along the block width).
        // A small gap keeps the leader tip off the glyphs.
        final gap = 0.15 * ts;
        final endV = side > 0 ? b.v0 - gap : b.v1 + gap;
        // The leader starts at the station on the run — or, for a POINT
        // feature ([anchorPoint]: a riser marker, an equipment glyph), at
        // the feature itself, ending at the nearest point of the block's
        // near edge (so it never reads as tagging a coincident run).
        final double sx, sy, ex, ey;
        if (anchorPoint == null) {
          sx = cx;
          sy = cy;
          (ex, ey) = world(cx, cy, 0, endV);
        } else {
          sx = anchorPoint.x;
          sy = anchorPoint.y;
          final px = sx - cx, py = sy - cy;
          final ua = px * ca + py * sa;
          (ex, ey) = world(cx, cy, ua.clamp(-b.halfW, b.halfW), endV);
        }
        final len = math.sqrt((ex - sx) * (ex - sx) + (ey - sy) * (ey - sy));
        if (len > hardCap + eps) continue;
        if (onLinework(sx, sy, ex, ey)) continue;
        final placedHit = hitsPlaced(b.padded);
        final rh = runHits(b);
        // A leader should cross nothing: no other run, no placed label, no
        // occupied mark (a leader through a tag reads as a strike-through).
        var crossings = 0;
        for (final r in layout._runs) {
          if (r.id != null && r.id == ownRunId) continue;
          if (_segmentsCross(
              sx, sy, ex, ey, r.seg.x1, r.seg.y1, r.seg.x2, r.seg.y2)) {
            crossings++;
          }
        }
        final leaderSeg = [(sx, sy), (ex, ey)];
        var labelCrossings = 0;
        for (final l in layout._labels) {
          if (_quadsOverlap(l, leaderSeg)) {
            crossings++;
            labelCrossings++;
          }
        }
        for (final o in layout.boxes) {
          final lb = _quadBounds(leaderSeg);
          if (_boxesOverlap(o, lb) && _quadsOverlap(_boxQuad(o), leaderSeg)) {
            crossings++;
          }
        }
        final isClear = !placedHit && rh == 0;
        final gh = gridHits(b);
        // Tiers: 0 clear + uncrossed within the preferred cap; 1 the same
        // out to the hard cap; 2 clear but the leader crosses something;
        // 3 the least-bad overprint. Within a tier a slot clear of the grid
        // lines beats one that crosses them (R6).
        final near = len <= cap + eps;
        final score = isClear
            ? (crossings == 0 ? (near ? 0 : 1) : 2, crossings, gh, 0.0, len)
            : (3, crossings, gh, overlapArea(b.quad) + rh * ts * ts, len);
        if (better(score)) {
          bestScore = score;
          best = b;
          bestA = (x: sx, y: sy);
          bestE = (x: ex, y: ey);
          bestLeaderStrikesLabel = labelCrossings > 0;
        }
      }
    }
  }
  if (best == null) {
    // Degenerate (no station within the cap): first escape row at the midpoint.
    final (cx, cy) = along.first;
    final b = block(escapeForms.first, cx, cy, 1, du + lh);
    final (ex, ey) = world(cx, cy, 0, b.v0 - 0.15 * ts);
    if (hitsPlaced(b.padded) || runHits(b) > 0) layout._unresolved++;
    return commit(b,
        anchor: anchorPoint ?? (x: cx, y: cy), end: (x: ex, y: ey));
  }
  // Round 24 — tier 3 is the least-bad OVERPRINT: count it (never silent).
  // Round 29 (drawings-3-6) — so is a tier-2 slot whose LEADER strikes
  // through a placed label (it reads as tagging that label's element).
  if (bestScore.$1 == 3 || (bestScore.$1 == 2 && bestLeaderStrikesLabel)) {
    layout._unresolved++;
  }
  return commit(best, anchor: bestA, end: bestE);
}

/// One candidate label block in the placer's local frame: the text quad, its
/// padded collision footprint, the positioned lines, the centre station, the
/// near/far normal offsets and the half width.
class _Block {
  final List<(double, double)> quad;
  final List<(double, double)> padded;
  final List<PlacedLabelLine> lines;
  final double cx, cy, v0, v1, halfW;
  const _Block(this.quad, this.padded, this.lines, this.cx, this.cy, this.v0,
      this.v1, this.halfW);
}

/// Legacy entry point (N3): place [text] for the edge (ax,ay)→(bx,by) against
/// a plain list of occupied [placed] boxes, appending the placed label's
/// bounds to it. Delegates to [placePlanLabel] (no run obstacles, no split
/// form, no beyond-the-end slots), so the midpoint-upper first slot is byte-identical to the original
/// greedy placer and a crowded tag is never dropped (it escapes with a leader).
LeaderedLabelPlacement placeEdgeLabelLeadered({
  required double ax,
  required double ay,
  required double bx,
  required double by,
  required String text,
  required double textSize,
  required List<LabelBox> placed,
}) =>
    placePlanLabel(
      ax: ax,
      ay: ay,
      bx: bx,
      by: by,
      text: text,
      textSize: textSize,
      layout: PlanLabelLayout(boxes: placed),
      recordBounds: true,
      // No runs are registered here, so no end can be known to be free.
      beyondEnds: false,
    );

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

// ── Shared plan run/riser label composition (PDF == DXF) ────────────────────
//
// The annotated plan PDF and the professional plan DXF print the SAME label for
// the same edge — `<tag> · <size> - <length> - <CL> - <fall>` — so a contractor
// working from either format reads identical take-off data. Both exporters
// compose through these two pure helpers (audit 2026-10 drawing-output-7/-8).

/// A human metres string for a run/riser length label: `3.5 m`, `4.0 m`. The
/// value is ROUNDED to the printed 0.1 m first, so floating-point noise in a
/// §10 elevation delta (11.7 − 7.7 = 3.999999999999999) prints the same
/// `4.0 m` as an exact 4.0. Pure.
///
/// Round 20 (drafting-visual-4-7) — ONE fixed precision (0.1 m) for every
/// length on every sheet: the plan used to print '3 m' for the run the riser
/// tag and the report schedule print as '3.0 m', so the same quantity read as
/// differently rounded. The riser tag now routes through this helper too.
String planLengthLabel(Length l) {
  final r = (l.meters * 10).round() / 10;
  return '${r.toStringAsFixed(1)} m';
}

/// Compose a plan edge label from its parts: the present tokens of [size],
/// [length], [elevation] and [slope] joined with ` - `, prefixed by the stable
/// element [tag] as `<tag> · <core>` (U+00B7, WinAnsi pass-through in the PDF).
/// Null/empty parts are skipped; returns null when nothing is left. Pure.
String? composePlanEdgeLabel({
  String? tag,
  String? size,
  String? length,
  String? elevation,
  String? slope,
}) {
  final parts = <String>[
    for (final p in [size, length, elevation, slope])
      if (p != null && p.isNotEmpty) p,
  ];
  final core = parts.isEmpty ? null : parts.join(' - ');
  if (tag != null && tag.isNotEmpty) {
    return core == null ? tag : '$tag · $core';
  }
  return core;
}

// ── N5: per-run centreline SETTING-OUT elevation labels ─────────────────────
//
// The plan prints `CL +2.70` on each horizontal run — the height a foreman
// hangs the pipe/duct at, above that run's floor FFL. The label is a RENDER of
// the solve's §10 [nodeElevation] (golden rule 5): a floor-standing pump /
// ground tank / AHU sits on its own floor surface there (audit 2026-10
// water-drainage-1), so its runs print the same height the static lift uses.
// The one plant the solve still parks at the ROOF datum when it carries no
// explicit elevation / mount height is a roof tank (or a plant with no
// component); a run from it averaged with a ground-floor node printed
// `CL +12.00` on a 4 m storey (audit 2026-10 drawing-output-2), so the label
// resolves that roof-parked plant to its own floor's ceiling main level instead
// and never prints a CL outside the storey.

/// The elevation a PLAN label uses for [node]: its run-connection elevation
/// ([runConnectionElevation] — [nodeElevation], with a ceiling-hung diffuser /
/// grille / sprinkler at the ceiling), EXCEPT a datum-less [NodeRole.plant]
/// node that [nodeElevation] parks at the roof (a roof tank or a
/// component-less plant on a lower sheet) — that one sits at its own floor's
/// ceiling main level ([BuildingLevels.ceilingElevationOf]). Pure.
Length planSettingOutElevation(
  NetNode node,
  BuildingLevels building, [
  MountingHeights mounting = const MountingHeights(),
]) {
  final solved = runConnectionElevation(node, building, mounting);
  if (node.role == NodeRole.plant &&
      node.elevation == null &&
      node.mountHeight == null &&
      solved.meters == building.roofElevation.meters) {
    return building.ceilingElevationOf(node.floorIndex, mounting);
  }
  return solved;
}

/// N5 — per-RUN centreline SETTING-OUT labels keyed by edge id. Only RUN edges
/// get an entry (risers carry the FFL gutter on the riser sheet); the pure
/// exporters receive the finished strings and never read the model.
///
/// A run whose endpoints sit at different elevations (a floor-standing pump up
/// to the ceiling main, a ceiling main down to a WC) is not a straight sloped
/// pipe: its HORIZONTAL leg hangs at the main's level (the `main`-role end, else
/// the higher end) and the difference is a vertical leg. So the label states the
/// hanging height a foreman sets out, plus `drop N.NN m` for that leg — the
/// SAME figure the run's quantity includes: the leg is read from
/// [runVerticalLeg] itself (the one source [edgeLength] uses), never
/// re-derived here — never the misleading mean of the two ends. A level run
/// (a ceiling main to a ceiling diffuser) prints the bare `CL` token; a
/// GRAVITY run prints none (no invert datum in the model — R5). Hanging heights come from [planSettingOutElevation] (so
/// a roof-parked datum-less plant reads its own floor's ceiling); a hanging
/// height outside `[0, floor height]` of its storey, or a leg taller than the
/// storey, cannot be set out on this floor (e.g. a roof tank drawn on a lower
/// sheet, an explicit plant datum on another level), so it is OMITTED rather
/// than printed. Pure.
Map<String, String> runCentrelineLabels(
  Network net,
  BuildingLevels building, {
  MountingHeights mounting = const MountingHeights(),
}) {
  final out = <String, String>{};
  if (building.levelCount == 0) return out;
  const eps = 0.005; // half the printed 0.01 m resolution
  for (final e in net.edges) {
    if (e.kind != EdgeKind.run) continue;
    // R5 — GRAVITY runs (drainage / vent / rainwater) print NO `CL`. The §10
    // model gives a gravity `main` node no below-slab / invert datum: it
    // resolves to its OWN floor's ceiling (see `runVerticalLeg`), so the token
    // read `CL +3.70` on an upper-floor soil branch — but Indonesian practice
    // hangs a floor's drain branches UNDER its slab (in the ceiling void of the
    // floor below) and sets them out by INVERT along the laid fall, neither of
    // which the engine models. Printing the ceiling figure would be a
    // fabricated set-out height, so the run keeps its honest tokens — size,
    // §10 length and the real `1:N` fall from the design gradient — and the
    // CL is omitted until gravity mains carry a real invert datum.
    if (e.service.regime == FlowRegime.gravity) continue;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    final ea = planSettingOutElevation(a, building, mounting).meters;
    final eb = planSettingOutElevation(b, building, mounting).meters;
    final leg =
        runVerticalLeg(e, net, building: building, mounting: mounting).meters;
    final NetNode level;
    if (a.role == NodeRole.main && b.role != NodeRole.main) {
      level = a;
    } else if (b.role == NodeRole.main && a.role != NodeRole.main) {
      level = b;
    } else {
      level = ea >= eb ? a : b;
    }
    final levelElev = identical(level, a) ? ea : eb;
    final aboveFfl = levelElev - building.elevationOf(level.floorIndex).meters;
    final storey = building.floorHeightOf(level.floorIndex).meters;
    if (aboveFfl < -eps || aboveFfl > storey + eps || leg > storey + eps) {
      continue;
    }
    final sign = aboveFfl >= 0 ? '+' : '-';
    final drop = leg > 0 ? ' drop ${leg.toStringAsFixed(2)} m' : '';
    out[e.id] = 'CL $sign${aboveFfl.abs().toStringAsFixed(2)}$drop';
  }
  return out;
}

/// The plan exporters' name for [runCentrelineLabels] (kept so the app, the
/// export harness and the tests share one function).
Map<String, String> planEdgeElevationLabels(
  Network net,
  BuildingLevels building, {
  MountingHeights mounting = const MountingHeights(),
}) =>
    runCentrelineLabels(net, building, mounting: mounting);
