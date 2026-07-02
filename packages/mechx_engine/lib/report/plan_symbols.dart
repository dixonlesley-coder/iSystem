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
      // A junction dot with a double-headed vertical arrow.
      cir(0.50, 0.50, 0.10);
      ln(0.50, 0.12, 0.50, 0.88);
      ln(0.50, 0.12, 0.40, 0.28);
      ln(0.50, 0.12, 0.60, 0.28);
      ln(0.50, 0.88, 0.40, 0.72);
      ln(0.50, 0.88, 0.60, 0.72);
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
