import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';

import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
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
    final sizing = ref.watch(showSizingProvider)
        ? ref.watch(sizingProvider)
        : const <String, EdgeSizing>{};
    final selection = ref.watch(selectionProvider);

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
        if (_edgeSelected(e.id)) {
          canvas.drawLine(
            pa,
            pb,
            Paint()
              ..color = _kSelection.withAlpha(120)
              ..strokeWidth = 7
              ..strokeCap = StrokeCap.round
              ..style = PaintingStyle.stroke,
          );
        }
        canvas.drawLine(
          pa,
          pb,
          Paint()
            ..color = color
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke,
        );
        // Suppress sizing labels on a faded (coordination) layer to keep the
        // active layer's annotation readable.
        final s = sizing[e.id];
        if (s != null && opacity >= 1.0) {
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
      } else {
        _nodeGlyph(canvas, p, n.role, layer.opacity);
      }
    }
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
