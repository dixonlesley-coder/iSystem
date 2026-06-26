import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';

import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../../store/solve_store.dart';
import 'segment_symbols.dart';
import 'service_style.dart';
import 'viewport.dart';

/// Accent used to highlight the current selection.
const Color _kSelection = Color(0xFF4C8DFF);

/// Always-on render of the drawn network for the current sheet/floor, painted
/// in screen space via the sheet's viewport transform. Pointer-transparent so
/// the canvas keeps panning/zooming underneath.
///
/// On the unified Layout canvas it is layer-aware: pass [layerFiltered] so each
/// edge/node is drawn only when its discipline ([disciplineOf]) is visible, and
/// faded ([fadedDisciplines]) when its discipline isn't the active one. The
/// plain mechanical Plan leaves both unset → every service drawn full-opacity
/// (unchanged behaviour).
class NetworkLayer extends ConsumerWidget {
  final String sheetId;
  final int floorIndex;

  /// When true, the painter honours the discipline visibility / fade sets below
  /// (the unified canvas). When false (the legacy Plan), all services draw at
  /// full opacity.
  final bool layerFiltered;

  const NetworkLayer({
    super.key,
    required this.sheetId,
    required this.floorIndex,
    this.layerFiltered = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(networkControllerProvider).network;
    final transform = ref.watch(sheetsControllerProvider).viewportFor(sheetId) ??
        const ViewportTransform();
    // Sizing always drives the pipe WIDTH (so a pipe visibly grows with its DN);
    // the toggle only governs whether the size LABELS are drawn on top.
    final sizing = ref.watch(sizingProvider);
    final showLabels = ref.watch(showSizingProvider);
    final selection = ref.watch(selectionProvider);
    // Sheet scale (m per px) lets the painter mark a coupling joint every stock
    // pipe length along a run; null (uncalibrated) ⇒ no joint marks.
    final metersPerPixel =
        ref.watch(projectControllerProvider).calibrationFor(sheetId)?.metersPerPixel;
    // Continuous pipe chains → per-edge stock-coupling positions. A run is marked
    // along its WHOLE chain (collinear segments merged) so couplings fall at true
    // stock-length boundaries (4 m PVC/PPR, 6 m steel), not reset per segment —
    // the efficiency engine for where joints (and so offcuts) land.
    final edgeCuts = <String, _EdgeCut>{};
    for (final chain in ref.watch(pipeChainsProvider)) {
      for (final ce in chain.edges) {
        edgeCuts[ce.edgeId] =
            _EdgeCut(ce.offsetAtFromM, ce.offsetAtToM, chain.stockLengthM);
      }
    }

    // Layer filtering (unified canvas only).
    Set<DisciplineLayer> visible = DisciplineLayer.values.toSet();
    DisciplineLayer? active;
    if (layerFiltered) {
      visible = ref.watch(layerVisibilityProvider);
      active = ref.watch(activeDisciplineProvider);
    }

    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _NetworkPainter(
          net: net,
          sheetId: sheetId,
          floorIndex: floorIndex,
          transform: transform,
          sizing: sizing,
          showLabels: showLabels,
          metersPerPixel: metersPerPixel,
          edgeCuts: edgeCuts,
          selectedNodeId: selection.nodeId,
          selectedEdgeId: selection.edgeId,
          selectedNodeIds: selection.nodeIds,
          selectedEdgeIds: selection.edgeIds,
          layerFiltered: layerFiltered,
          visibleDisciplines: visible,
          activeDiscipline: active,
        ),
      ),
    );
  }
}

/// Opacity applied to a service whose discipline is visible but not the active
/// (editable) layer — ghosted for coordination, not for editing.
const double _kFadedAlpha = 0.28;

class _NetworkPainter extends CustomPainter {
  final Network net;
  final String sheetId;
  final int floorIndex;
  final ViewportTransform transform;
  final Map<String, EdgeSizing> sizing;

  /// Whether to draw the size LABELS (the toggle); the pipe WIDTH always tracks
  /// the sized DN regardless of this.
  final bool showLabels;

  /// Sheet scale (metres per pixel), or null when the sheet is uncalibrated. Used
  /// to place a coupling joint mark every stock pipe length along a run.
  final double? metersPerPixel;

  /// Per-edge stock-coupling layout (chain arc-length at each endpoint + the
  /// stock length), so couplings fall along the WHOLE continuous pipe rather than
  /// resetting each segment. Absent ⇒ that edge isn't part of a sized chain.
  final Map<String, _EdgeCut> edgeCuts;
  final String? selectedNodeId;
  final String? selectedEdgeId;

  /// The full multi-selection sets — any node/edge whose id is in these gets the
  /// same highlight ring/halo as the primary (the primary's id is also in them).
  final Set<String> selectedNodeIds;
  final Set<String> selectedEdgeIds;

  /// Discipline-layer filtering (unified canvas). When [layerFiltered] is false
  /// the other two fields are ignored and every service draws full-opacity.
  final bool layerFiltered;
  final Set<DisciplineLayer> visibleDisciplines;
  final DisciplineLayer? activeDiscipline;

  _NetworkPainter({
    required this.net,
    required this.sheetId,
    required this.floorIndex,
    required this.transform,
    required this.sizing,
    this.showLabels = false,
    this.metersPerPixel,
    this.edgeCuts = const {},
    required this.selectedNodeId,
    required this.selectedEdgeId,
    this.selectedNodeIds = const {},
    this.selectedEdgeIds = const {},
    this.layerFiltered = false,
    this.visibleDisciplines = const {},
    this.activeDiscipline,
  });

  bool _onThisFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  /// An edge is highlighted when it's the primary OR in the multi-selection set.
  bool _edgeSelected(String id) =>
      id == selectedEdgeId || selectedEdgeIds.contains(id);

  /// A node is highlighted when it's the primary OR in the multi-selection set.
  bool _nodeSelected(String id) =>
      id == selectedNodeId || selectedNodeIds.contains(id);

  /// Whether a service's discipline should be drawn at all (visibility).
  bool _serviceVisible(ServiceType s) =>
      !layerFiltered || visibleDisciplines.contains(disciplineOf(s));

  /// The opacity multiplier for a service: 1.0 when not layer-filtered or when
  /// its discipline is the active one; [_kFadedAlpha] when it's a visible-but-
  /// inactive coordination layer.
  double _serviceOpacity(ServiceType s) {
    if (!layerFiltered) return 1.0;
    return disciplineOf(s) == activeDiscipline ? 1.0 : _kFadedAlpha;
  }

  // serviceColor + the node ink/light are opaque, so scaling the 255 alpha by
  // [opacity] is the fade (avoids the deprecated `.alpha` getter).
  Color _fade(Color base, double opacity) =>
      opacity >= 1.0 ? base : base.withAlpha((255 * opacity).round());

  /// A node's discipline visibility/opacity is taken from the edges touching it
  /// (a node carries no service); a node with no edge is treated as visible at
  /// full opacity so freestanding fittings/fixtures aren't lost.
  ({bool visible, double opacity}) _nodeLayer(NetNode n) {
    if (!layerFiltered) return (visible: true, opacity: 1.0);
    var visible = false;
    var active = false;
    var touched = false;
    for (final e in net.edges) {
      if (e.fromId != n.id && e.toId != n.id) continue;
      touched = true;
      if (visibleDisciplines.contains(disciplineOf(e.service))) visible = true;
      if (disciplineOf(e.service) == activeDiscipline) active = true;
    }
    if (!touched) return (visible: true, opacity: 1.0);
    return (visible: visible, opacity: active ? 1.0 : _kFadedAlpha);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Incidence collected while drawing pipes: per node, the screen-space unit
    // directions of the run pipes leaving it + the widest pipe + its opacity —
    // used to draw the right fitting (coupling / elbow / tee / cross / cap) where
    // pipes meet.
    final joints = <String, _Joint>{};

    for (final e in net.edges) {
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      if (!_serviceVisible(e.service)) continue;
      final opacity = _serviceOpacity(e.service);
      final color = _fade(serviceColor(e.service), opacity);

      if (e.kind == EdgeKind.run) {
        if (!_onThisFloor(a) || !_onThisFloor(b)) continue;
        final pa = transform.worldToScreen(Offset(a.x, a.y));
        final pb = transform.worldToScreen(Offset(b.x, b.y));
        final s = sizing[e.id];
        final outer = _pipeOuterPx(s, e.service);

        if (_edgeSelected(e.id)) {
          canvas.drawLine(
            pa,
            pb,
            Paint()
              ..color = _kSelection.withAlpha(120)
              ..strokeWidth = outer + 5
              ..strokeCap = StrokeCap.round
              ..style = PaintingStyle.stroke,
          );
        }
        // The pipe as a walled body: a darker casing stroke with the service-
        // colour bore inside it — two parallel wall lines, not a single line.
        _paintPipe(canvas, pa, pb, color, outer);

        // Record incidence at both ends (direction points AWAY from the node).
        final len = (pb - pa).distance;
        if (len > 0.0) {
          final u = (pb - pa) / len;
          (joints[a.id] ??= _Joint(opacity)).add(u, outer, opacity);
          (joints[b.id] ??= _Joint(opacity)).add(-u, outer, opacity);

          // Joint marks at stock/section boundaries along the WHOLE chain
          // (collinear segments merged) — pipe couplings (4 m PVC/PPR, 6 m
          // steel) and duct flanges (1.2 m BJLS, 4 m PU) alike — placed by the
          // efficiency engine so offcuts fall once per chain, not per segment.
          // Only when the sheet is calibrated.
          final cut = edgeCuts[e.id];
          if (metersPerPixel != null && cut != null) {
            final lo = math.min(cut.offFromM, cut.offToM);
            final hi = math.max(cut.offFromM, cut.offToM);
            final span = cut.offToM - cut.offFromM;
            if (span.abs() > 1e-6) {
              final metal = _fade(const Color(0xFF3A3F47), opacity);
              for (var k = (lo / cut.stockM).floor() + 1;
                  k * cut.stockM < hi - 1e-6;
                  k++) {
                final c = k * cut.stockM;
                if (c <= lo + 1e-6) continue;
                final t = (c - cut.offFromM) / span; // 0..1 along from→to
                _couplingMark(canvas, pa + u * t * len, u, outer, metal);
              }
            }
          }
        }

        // Size labels are drawn only when the toggle is on, and never on a faded
        // (coordination) layer — to keep the active layer's annotation readable.
        if (s != null && showLabels && opacity >= 1.0) {
          String label;
          if (s.isRectangular) {
            label = '${s.width!.inMillimeters.round()}'
                '×${s.height!.inMillimeters.round()}';
          } else {
            final mm = s.diameter.inMillimeters.round();
            label = e.service.regime == FlowRegime.air ? 'Ø$mm' : 'DN$mm';
          }
          final tag = _productTag(e, s);
          if (tag != null) label = '$label  $tag';
          _label(canvas, (pa + pb) / 2, label);
        }
      } else {
        final lowFloor = math.min(a.floorIndex, b.floorIndex);
        for (final n in [a, b]) {
          if (_onThisFloor(n)) {
            final mp = transform.worldToScreen(Offset(n.x, n.y));
            if (_edgeSelected(e.id)) {
              canvas.drawCircle(mp, 11,
                  Paint()..color = _kSelection.withAlpha(90));
            }
            _riserMarker(canvas, mp, color, up: n.floorIndex == lowFloor);
          }
        }
      }
    }

    // Fittings where pipes meet — drawn over the pipe bodies, under the node
    // glyphs. Only plain junctions (role main, no equipment component) become a
    // coupling/elbow/tee; fixtures/plant/equipment keep their own glyph.
    for (final n in net.nodes) {
      if (!_onThisFloor(n)) continue;
      if (n.component != null || n.role != NodeRole.main) continue;
      final j = joints[n.id];
      if (j == null) continue;
      final layer = _nodeLayer(n);
      if (!layer.visible) continue;
      _paintFitting(
          canvas, transform.worldToScreen(Offset(n.x, n.y)), j, n.fittingType);
    }

    // Nodes on top, drawn with a role-distinct glyph and a selection ring.
    for (final n in net.nodes) {
      if (!_onThisFloor(n)) continue;
      final layer = _nodeLayer(n);
      if (!layer.visible) continue;
      final p = transform.worldToScreen(Offset(n.x, n.y));
      final selected = _nodeSelected(n.id);
      if (selected) {
        canvas.drawCircle(p, 9, Paint()..color = _kSelection.withAlpha(70));
        canvas.drawCircle(
          p,
          9,
          Paint()
            ..color = _kSelection
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke,
        );
      }
      if (n.component != null) {
        _componentGlyph(canvas, p, n.component!, layer.opacity);
      } else if (n.role != NodeRole.main || joints[n.id] == null) {
        // A plain junction that carries a fitting glyph (drawn above) no longer
        // needs the bare dot; a free main node (no pipes yet) still gets it.
        _nodeGlyph(canvas, p, n.role, layer.opacity);
      }
    }
  }

  /// The on-screen outer width (px) of a pipe, scaled CONTINUOUSLY from its
  /// sized nominal bore (or a small default when unsized) — so a pipe visibly
  /// grows with its DN. Kept in screen px (constant at any zoom) and clamped to
  /// a sane band so the thinnest still reads as a pipe and the fattest doesn't
  /// dominate. Ducts use a gentler slope (their mm are far larger).
  double _pipeOuterPx(EdgeSizing? s, ServiceType svc) {
    final double mm = s == null
        ? 20
        : (s.isRectangular
            ? math.max(s.width!.inMillimeters, s.height!.inMillimeters)
            : s.diameter.inMillimeters);
    if (svc.regime == FlowRegime.air) {
      return (6.0 + mm * 0.012).clamp(8.0, 20.0);
    }
    return (3.6 + mm * 0.06).clamp(4.0, 16.0);
  }

  /// A coupling joint mark across a pipe — a short perpendicular steel collar at
  /// a stock-length boundary along the run.
  void _couplingMark(
      Canvas canvas, Offset p, Offset dir, double outer, Color metal) {
    final perp = Offset(-dir.dy, dir.dx);
    final half = outer / 2 + 1.2;
    canvas.drawLine(
      p + perp * half,
      p - perp * half,
      Paint()
        ..color = metal
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  /// Draws a run as a walled pipe: a darker casing stroke (the two visible wall
  /// lines) with the service-colour bore inside it.
  void _paintPipe(Canvas canvas, Offset pa, Offset pb, Color color, double outer) {
    final wall = Color.lerp(color, const Color(0xFF000000), 0.45)!;
    canvas.drawLine(
      pa,
      pb,
      Paint()
        ..color = wall
        ..strokeWidth = outer
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
    final bore = (outer - 2.6).clamp(1.2, outer);
    canvas.drawLine(
      pa,
      pb,
      Paint()
        ..color = color
        ..strokeWidth = bore
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  /// Draws the fitting at a junction. The body is built from short, fat metal
  /// "arms" laid along the ACTUAL incident pipe directions, so the fitting takes
  /// the true shape of the joint — a tee reads as a T, an elbow as an L, a cross
  /// as a +, a wye keeps its angled branch. The fitting TYPE (auto-derived from
  /// the joint, or the node's [override]) chooses the cap face / inline sleeve /
  /// wye crotch detailing.
  void _paintFitting(
      Canvas canvas, Offset p, _Joint j, JunctionFitting? override) {
    final metal = _fade(const Color(0xFF3A3F47), j.opacity);
    final light = _fade(const Color(0xFFFFFFFF), j.opacity);
    final w = j.maxOuter;
    final dirs = j.dirs;
    if (dirs.isEmpty) return;

    final auto = override == null || override == JunctionFitting.auto;
    final type = auto ? _autoFitting(dirs) : override;

    // A COLLINEAR pass-through vertex (auto-coupling) is just continuous pipe —
    // the stock-length coupling marks already show the real joints, so draw
    // nothing here unless the user explicitly pinned a coupling.
    if (type == JunctionFitting.coupling) {
      if (auto) return;
      _sleeve(canvas, p, dirs.first, w, metal, light);
      return;
    }

    // Arms along each pipe direction + a fused hub.
    final armLen = w * 0.85 + 2;
    final armW = w + 2.6;
    for (final d in dirs) {
      _arm(canvas, p, d, armLen, armW, metal);
    }
    final hubR = (type == JunctionFitting.cross || type == JunctionFitting.teeWye)
        ? armW / 2 + 0.5
        : armW / 2;
    canvas.drawCircle(p, hubR, Paint()..color = metal);

    // Wye / tee-wye → fill the branch crotch (the narrowest gap between two
    // arms) so the swept-Y reads distinctly from a square tee.
    if (type == JunctionFitting.wye || type == JunctionFitting.teeWye) {
      _wyeGusset(canvas, p, dirs, armLen, metal);
    }

    // End cap → a flat face bar across the open end of the single arm.
    if (type == JunctionFitting.cap) {
      final d = dirs.first;
      final perp = Offset(-d.dy, d.dx);
      final tip = p + d * armLen;
      final half = armW / 2;
      canvas.drawLine(
        tip + perp * half,
        tip - perp * half,
        Paint()
          ..color = metal
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
    }

    // A hairline ring on the hub lifts it off the pipes.
    canvas.drawCircle(
        p,
        hubR,
        Paint()
          ..color = light
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke);
  }

  /// The geometry-derived fitting for a joint with no override.
  JunctionFitting _autoFitting(List<Offset> dirs) {
    if (dirs.length >= 4) return JunctionFitting.cross;
    if (dirs.length == 3) return JunctionFitting.tee;
    if (dirs.length == 2) {
      final dot = dirs[0].dx * dirs[1].dx + dirs[0].dy * dirs[1].dy;
      return dot < -0.94 ? JunctionFitting.coupling : JunctionFitting.elbow;
    }
    return JunctionFitting.cap;
  }

  /// A coupling sleeve: a short rounded collar centred on [p], its long axis
  /// along the pipe direction [axis].
  void _sleeve(Canvas canvas, Offset p, Offset axis, double w, Color metal,
      Color light) {
    canvas.save();
    canvas.translate(p.dx, p.dy);
    canvas.rotate(math.atan2(axis.dy, axis.dx));
    final rect = Rect.fromCenter(center: Offset.zero, width: 10, height: w + 3);
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(2));
    canvas.drawRRect(rr, Paint()..color = metal);
    canvas.drawRRect(
        rr,
        Paint()
          ..color = light
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke);
    canvas.restore();
  }

  /// A fat rounded arm of the fitting body extending from [p] along [dir].
  void _arm(Canvas canvas, Offset p, Offset dir, double len, double thick,
      Color metal) {
    canvas.save();
    canvas.translate(p.dx, p.dy);
    canvas.rotate(math.atan2(dir.dy, dir.dx));
    final rect = Rect.fromLTWH(-thick / 2, -thick / 2, len + thick / 2, thick);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(thick / 2)),
      Paint()..color = metal,
    );
    canvas.restore();
  }

  /// Fills the crotch between the two closest-together arms (the swept branch of
  /// a wye), so a Y reads differently from a square tee.
  void _wyeGusset(
      Canvas canvas, Offset p, List<Offset> dirs, double len, Color metal) {
    if (dirs.length < 2) return;
    var bestDot = -2.0;
    var ai = 0, bi = 1;
    for (var i = 0; i < dirs.length; i++) {
      for (var k = i + 1; k < dirs.length; k++) {
        final dot = dirs[i].dx * dirs[k].dx + dirs[i].dy * dirs[k].dy;
        if (dot > bestDot) {
          bestDot = dot;
          ai = i;
          bi = k;
        }
      }
    }
    final path = Path()
      ..moveTo(p.dx, p.dy)
      ..lineTo(p.dx + dirs[ai].dx * len * 0.7, p.dy + dirs[ai].dy * len * 0.7)
      ..lineTo(p.dx + dirs[bi].dx * len * 0.7, p.dy + dirs[bi].dy * len * 0.7)
      ..close();
    canvas.drawPath(path, Paint()..color = metal);
  }

  /// Draws an equipment node as its schematic symbol on a light chip so it
  /// stands out from plain junctions. [opacity] fades it on a coordination layer.
  void _componentGlyph(
      Canvas canvas, Offset p, NodeComponent c, double opacity) {
    final dark = _fade(const Color(0xFF15171B), opacity);
    final light = _fade(const Color(0xFFFFFFFF), opacity);
    const r = 9.0;
    final box = Rect.fromCenter(center: p, width: r * 2, height: r * 2);
    // A rounded white chip with a hairline, then the symbol centred in it.
    canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(4)),
        Paint()..color = light);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(4)),
      Paint()
        ..color = dark
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
    canvas.save();
    canvas.translate(box.left, box.top);
    paintComponentSymbol(canvas, const Size(r * 2, r * 2), c, dark, stroke: 1.2);
    canvas.restore();
  }

  /// Draws a node glyph by role: plant = filled square (tank/pump), fixture =
  /// hollow ring, main/junction = small filled dot. [opacity] fades it on a
  /// coordination (inactive) layer.
  void _nodeGlyph(Canvas canvas, Offset p, NodeRole role, double opacity) {
    final dark = _fade(const Color(0xFF15171B), opacity);
    final light = _fade(const Color(0xFFFFFFFF), opacity);
    switch (role) {
      case NodeRole.plant:
        final r = Rect.fromCenter(center: p, width: 9, height: 9);
        canvas.drawRect(r, Paint()..color = dark);
        canvas.drawRect(
          r,
          Paint()
            ..color = light
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke,
        );
      case NodeRole.fixture:
        canvas.drawCircle(p, 4.5, Paint()..color = dark);
        canvas.drawCircle(
          p,
          4.5,
          Paint()
            ..color = light
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke,
        );
      case NodeRole.main:
        canvas.drawCircle(p, 3, Paint()..color = dark);
        canvas.drawCircle(
          p,
          3,
          Paint()
            ..color = light
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
    }
  }

  void _riserMarker(Canvas canvas, Offset p, Color color, {required bool up}) {
    canvas.drawCircle(p, 7, Paint()..color = color.withAlpha(38));
    canvas.drawCircle(
      p,
      7,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
    final path = Path();
    if (up) {
      path.moveTo(p.dx, p.dy - 4);
      path.lineTo(p.dx - 3, p.dy + 2);
      path.lineTo(p.dx + 3, p.dy + 2);
    } else {
      path.moveTo(p.dx, p.dy + 4);
      path.lineTo(p.dx - 3, p.dy - 2);
      path.lineTo(p.dx + 3, p.dy - 2);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  /// Compact ASCII-safe material tag for an edge ("PPR16", "PVC-AW", "BJLS 0.6",
  /// "PU"), or null when no material is set. BJLS shows its auto sheet thickness
  /// derived from the sized largest side. No symbol glyphs (Roboto-safe).
  String? _productTag(NetEdge e, EdgeSizing s) {
    final pp = e.pipeProduct;
    if (pp != null) {
      return switch (pp) {
        PipeProduct.pprPn10 => 'PPR10',
        PipeProduct.pprPn16 => 'PPR16',
        PipeProduct.pprPn20 => 'PPR20',
        PipeProduct.pvcAw => 'PVC-AW',
        PipeProduct.pvcD => 'PVC-D',
        PipeProduct.pvcJis => 'PVC-JIS',
        PipeProduct.castIron => 'CI',
        PipeProduct.acousticPvc => 'PVC-AC',
        PipeProduct.hdpe => 'HDPE',
      };
    }
    final dp = e.ductProduct;
    if (dp != null) {
      if (dp == DuctProduct.pu) return 'PU';
      final largest = s.isRectangular
          ? math.max(s.width!.inMillimeters, s.height!.inMillimeters)
          : s.diameter.inMillimeters;
      return 'BJLS ${bjlsThicknessMm(largest).toStringAsFixed(2)}';
    }
    return null;
  }

  void _label(Canvas canvas, Offset center, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 10.5,
          color: Color(0xFFFFFFFF),
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
      center: center,
      width: tp.width + 8,
      height: tp.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = const Color(0xD915171B),
    );
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_NetworkPainter old) =>
      old.net != net ||
      old.transform != transform ||
      old.floorIndex != floorIndex ||
      old.sheetId != sheetId ||
      old.sizing != sizing ||
      old.showLabels != showLabels ||
      old.metersPerPixel != metersPerPixel ||
      !identical(old.edgeCuts, edgeCuts) ||
      old.selectedNodeId != selectedNodeId ||
      old.selectedEdgeId != selectedEdgeId ||
      !_sameStrSet(old.selectedNodeIds, selectedNodeIds) ||
      !_sameStrSet(old.selectedEdgeIds, selectedEdgeIds) ||
      old.layerFiltered != layerFiltered ||
      old.activeDiscipline != activeDiscipline ||
      !_sameSet(old.visibleDisciplines, visibleDisciplines);

  static bool _sameSet(Set<DisciplineLayer> a, Set<DisciplineLayer> b) =>
      a.length == b.length && a.containsAll(b);

  static bool _sameStrSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

/// One run edge's stock-coupling layout within its continuous pipe chain: the
/// chain arc-length (metres) at the edge's from/to endpoints and the stock pipe
/// length, so couplings fall at chain `k·stock` boundaries regardless of which
/// way the edge was drawn.
class _EdgeCut {
  final double offFromM;
  final double offToM;
  final double stockM;
  const _EdgeCut(this.offFromM, this.offToM, this.stockM);
}

/// Accumulates the run pipes incident to one node (screen-space unit directions
/// away from it, the widest pipe, and the node's draw opacity) so the painter
/// can choose the right fitting where they meet.
class _Joint {
  final List<Offset> dirs = [];
  double maxOuter = 0;
  double opacity;

  _Joint(this.opacity);

  void add(Offset unit, double outer, double op) {
    dirs.add(unit);
    if (outer > maxOuter) maxOuter = outer;
    // A junction touched by the active layer draws solid; keep the strongest.
    if (op > opacity) opacity = op;
  }
}
