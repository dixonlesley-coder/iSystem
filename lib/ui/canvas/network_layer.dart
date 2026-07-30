import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_symbols.dart'
    show equipmentNodeTags, gravitySlopeLabel;
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';

import '../../store/air_warnings_store.dart';
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

/// Warning colour for an out-of-band air velocity (too high / too low).
const Color _kWarn = Color(0xFFE8703A);

/// Danger colour for an edge clamped at the largest table size (over capacity —
/// duct, storm downpipe or supply pipe) — a harder limit than an out-of-band
/// velocity, so it reads red (systemRed-tuned for the sheet) and as a distinct
/// triangle shape.
const Color _kOverCapacity = Color(0xFFDB3B3B);

/// Muted colour for the softer "carries air but not yet sized" advisory.
const Color _kUnsized = Color(0xFF9AA0A6);

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
    // Hover pre-highlight (E7): the single node/edge under the Select cursor,
    // published by the gesture layer. Null at idle ⇒ no halo (byte-identical).
    final hover = ref.watch(hoverTargetProvider);
    // Ids of air elements whose velocity is out of band — get an on-plan badge.
    final checks = ref.watch(airVelocityChecksProvider);
    final warningIds = <String>{
      for (final e in checks.entries)
        if (e.value.isWarning) e.key,
    };
    // Air elements carrying air but not yet manually sized — a softer advisory.
    final unsizedIds = ref.watch(airUnsizedProvider);
    // Edges clamped at the largest table size (over capacity) — a hard limit
    // that takes precedence over a plain velocity warning on the badge. Now the
    // DISCIPLINE-NEUTRAL set (M3/M4): an air duct clamped at the largest duct, a
    // storm downpipe past the largest tabulated catchment, or a supply run that
    // cannot hold the SNI velocity cap at any DN. The badge shape/precedence
    // rules are unchanged — only the source widened.
    final overCapacityIds = ref.watch(overCapacityEdgesProvider);
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
    // F4 — per-service view filter (hidden services omitted from render + hit
    // test). Empty by default ⇒ byte-identical.
    Set<ServiceType> hiddenServices = const {};
    if (layerFiltered) {
      visible = ref.watch(layerVisibilityProvider);
      active = ref.watch(activeDisciplineProvider);
      hiddenServices = ref.watch(hiddenServicesProvider);
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
          hoveredNodeId: hover?.nodeId,
          hoveredEdgeId: hover?.edgeId,
          layerFiltered: layerFiltered,
          visibleDisciplines: visible,
          activeDiscipline: active,
          hiddenServices: hiddenServices,
          warningIds: warningIds,
          unsizedIds: unsizedIds,
          overCapacityIds: overCapacityIds,
        ),
      ),
    );
  }
}

/// Opacity applied to a service whose discipline is visible but not the active
/// (editable) layer — ghosted for coordination, not for editing.
const double _kFadedAlpha = 0.28;

/// The on-screen outer width (px) of a pipe/duct, scaled CONTINUOUSLY from its
/// sized nominal bore (or a small default when unsized) — so a pipe visibly
/// grows with its DN. Kept in screen px (constant at any zoom) and clamped to
/// a sane band so the thinnest still reads as a pipe and the fattest doesn't
/// dominate. Ducts use a gentler slope (their mm are far larger).
///
/// E4 — TRUE-WIDTH when calibrated: once the sheet has a real scale
/// ([metersPerPixel]) this also knows the element's PHYSICAL footprint in
/// screen px (`mm/1000 / metresPerPixel × scale`). The final width is
/// `max(clampedPx, min(truePx, cap))`: at a zoomed-OUT view the physical
/// footprint is tiny so the clamp floor wins (byte-identical to before — a
/// 600×400 duct no longer paints ~13 px at every zoom), and as the engineer
/// zooms IN the duct/large-pipe grows to its real footprint (capped so a
/// trunk can't swamp the sheet). Uncalibrated sheets keep the pure screen-px
/// band.
///
/// Top-level (not painter-private) — B5's canvas hit-test corridor
/// (`selection_overlay.dart`'s `_edgeAt`) reuses this SAME formula so the
/// clickable band tracks exactly what's drawn, instead of duplicating (and
/// risking drifting from) the true-width math.
double pipeOuterPx(EdgeSizing? s, ServiceType svc,
    {required double scale, double? metersPerPixel}) {
  final double mm = s == null
      ? 20
      : (s.isRectangular
          ? math.max(s.width!.inMillimeters, s.height!.inMillimeters)
          : s.diameter.inMillimeters);
  final double clamped = svc.regime == FlowRegime.air
      ? (6.0 + mm * 0.012).clamp(8.0, 20.0)
      : (3.6 + mm * 0.06).clamp(4.0, 16.0);
  final mpp = metersPerPixel;
  if (mpp == null || mpp <= 0) return clamped;
  // Physical footprint of the element in screen pixels at the current zoom.
  final truePx = (mm / 1000.0) / mpp * scale;
  // 120 px cap so a large trunk grows realistically without dominating.
  return math.max(clamped, math.min(truePx, 120.0));
}

/// B16 — the on-screen RADIUS (px) of a node / fitting / riser glyph, grown
/// world-proportionally with the widest incident pipe's rendered width
/// [outerPx] (from [pipeOuterPx]) but never below a screen [floor] so a thin or
/// unsized pipe keeps today's compact marker. Shared by the node glyph, the
/// riser marker and the selection/hover halos so they scale together — and,
/// because it reads the same [pipeOuterPx] the B5 hit corridor uses, the
/// clickable target tracks the drawn glyph automatically.
double glyphRadiusPx(double outerPx, double floor) =>
    math.max(floor, outerPx * 0.5);

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

  /// The single node/edge under the Select cursor (E7 hover pre-highlight), or
  /// null when nothing is hovered. Gets a subtler, slightly-wider halo painted
  /// UNDER the selection halo. A stale id (a just-deleted element) simply never
  /// matches a drawn element, so the painter tolerates it with no extra guard.
  final String? hoveredNodeId;
  final String? hoveredEdgeId;

  /// Discipline-layer filtering (unified canvas). When [layerFiltered] is false
  /// the other two fields are ignored and every service draws full-opacity.
  final bool layerFiltered;
  final Set<DisciplineLayer> visibleDisciplines;
  final DisciplineLayer? activeDiscipline;

  /// F4 — services the engineer has individually hidden within a visible
  /// discipline (a view filter): omitted from paint AND hit-test. Empty ⇒
  /// byte-identical.
  final Set<ServiceType> hiddenServices;

  /// Ids of air elements (edges / terminal nodes) whose velocity is out of band.
  final Set<String> warningIds;

  /// Ids of air elements carrying air but not yet manually sized (soft advisory).
  final Set<String> unsizedIds;

  /// Ids of edges clamped at the largest TABLE size (over capacity): an air
  /// duct, a storm downpipe, or a supply pipe over the SNI velocity cap.
  final Set<String> overCapacityIds;

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
    this.hoveredNodeId,
    this.hoveredEdgeId,
    this.layerFiltered = false,
    this.visibleDisciplines = const {},
    this.activeDiscipline,
    this.hiddenServices = const {},
    this.warningIds = const {},
    this.unsizedIds = const {},
    this.overCapacityIds = const {},
  });

  bool _onThisFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  /// An edge is highlighted when it's the primary OR in the multi-selection set.
  bool _edgeSelected(String id) =>
      id == selectedEdgeId || selectedEdgeIds.contains(id);

  /// A node is highlighted when it's the primary OR in the multi-selection set.
  bool _nodeSelected(String id) =>
      id == selectedNodeId || selectedNodeIds.contains(id);

  /// The subtler hover pre-highlight, drawn under the selection halo.
  bool _edgeHovered(String id) => id == hoveredEdgeId;
  bool _nodeHovered(String id) => id == hoveredNodeId;

  /// Whether a service should be drawn at all: its discipline must be visible
  /// AND the service must not be individually hidden by the F4 view filter.
  bool _serviceVisible(ServiceType s) =>
      !layerFiltered ||
      (visibleDisciplines.contains(disciplineOf(s)) &&
          !hiddenServices.contains(s));

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
      // F4 — a node stays visible only while at least one touching edge's
      // service is itself visible (discipline shown AND not individually hidden).
      if (_serviceVisible(e.service)) visible = true;
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

    // Screen-space bounds of every run label already placed this frame, so a
    // later label that would collide can dodge to the other side / quarter-point
    // or be dropped. Deterministic (edge-list order).
    final placedLabels = <Rect>[];

    // B16 — per node, the widest incident pipe's rendered outer width (px),
    // computed in the visible-services pre-pass so a node's glyph size is
    // independent of edge iteration order. Drives world-proportional node /
    // riser glyph + halo sizes below.
    final nodeMaxOuter = <String, double>{};

    // E6 — one label convention across plan and riser. Compute the deterministic
    // per-riser tags (CW-R1 …) ONCE per paint (shared with the schematic view's
    // engine helper), and whether MULTIPLE distinct services are visible on this
    // floor: on a multi-service layer a run label carries its service code
    // (DN15-CW); on a single-service view it stays bare (DN15).
    final riserTagById = riserTags(net, null);
    // G1: one stable equipment tag per plant/air-unit node (P-01 / TK-01 / …),
    // the SAME source the plan exporters + equipment schedule use.
    final equipmentTagById = equipmentNodeTags(net);
    // G5: the laid gravity fall as a `1:100` token — read from the SizingContext
    // gradient the sizer actually uses (the store builds SizingContext without
    // overriding drainageSlope), never a hardcoded string.
    final gravitySlopeText =
        gravitySlopeLabel(const SizingContext().drainageSlope);
    final visibleServices = <ServiceType>{};
    for (final e in net.edges) {
      if (!_serviceVisible(e.service)) continue;
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      if (e.kind == EdgeKind.run) {
        if (!_onThisFloor(a) || !_onThisFloor(b)) continue;
      } else if (!_onThisFloor(a) && !_onThisFloor(b)) {
        continue;
      }
      visibleServices.add(e.service);
      // B16 — accumulate the widest incident pipe per node (runs + risers).
      final outer = _pipeOuterPx(sizing[e.id], e.service);
      if (outer > (nodeMaxOuter[a.id] ?? 0.0)) nodeMaxOuter[a.id] = outer;
      if (outer > (nodeMaxOuter[b.id] ?? 0.0)) nodeMaxOuter[b.id] = outer;
    }
    final multiService = visibleServices.length > 1;

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

        // Hover pre-highlight (E7) — a wider, fainter version of the selection
        // halo, drawn UNDER it so a hovered-and-selected edge still reads as
        // selected. Null hover ⇒ never drawn (idle byte-identical).
        if (_edgeHovered(e.id)) {
          canvas.drawLine(
            pa,
            pb,
            Paint()
              ..color = _kSelection.withAlpha(45)
              ..strokeWidth = outer + 8
              ..strokeCap = StrokeCap.round
              ..style = PaintingStyle.stroke,
          );
        }
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
        // A dash-patterned service (vent/return air dashed, fire dash-dot) walks
        // its bore as dash segments over a thinner casing; solid services are
        // byte-identical to before.
        _paintPipe(canvas, pa, pb, color, outer,
            dash: serviceDashPattern(e.service));

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

        // Flow-direction chevron: one small open chevron at the 2/3 point of a
        // long-enough run whose sizing knows its orientation (EdgeSizing.
        // flowFromId). Above the pipe body, beneath the labels; faded on a
        // coordination layer with everything else.
        if (s?.flowFromId != null && len > 48) {
          final upstream = s!.flowFromId == a.id ? pa : pb;
          final downstream = upstream == pa ? pb : pa;
          final fdir = (downstream - upstream) / len;
          final at = upstream + fdir * (len * 2 / 3);
          _flowChevron(canvas, at, fdir, serviceColor(e.service), opacity);
        }

        // Size labels are drawn only when the toggle is on, and never on a faded
        // (coordination) layer — to keep the active layer's annotation readable.
        // [labelSide] records which perpendicular side the chip took (null when
        // no chip was drawn) so the status badge below can dodge to the other
        // side (B2).
        int? labelSide;
        if (s != null && showLabels && opacity >= 1.0) {
          String label;
          if (s.isRectangular) {
            label = '${s.width!.inMillimeters.round()}'
                '×${s.height!.inMillimeters.round()}';
          } else {
            final mm = s.diameter.inMillimeters.round();
            label = e.service.regime == FlowRegime.air ? 'Ø$mm' : 'DN$mm';
          }
          // On a multi-service layer append the service code (DN15-CW) so the
          // run is cross-referenced like the riser tags; bare on a single view.
          if (multiService) label = '$label-${riserServiceCode(e.service)}';
          final tag = _productTag(e, s);
          if (tag != null) label = '$label  $tag';
          // G5: append the laid fall (`1:100`) on a gravity-regime run so the
          // soil/waste/rainwater branch shows its slope, not just its size.
          if (e.service.regime == FlowRegime.gravity &&
              gravitySlopeText != null) {
            label = '$label  $gravitySlopeText';
          }
          labelSide = _label(canvas, pa, pb, outer, label, placedLabels);
        }
        // Air status badge (independent of the size-label toggle), active layer
        // only. Precedence: over-capacity (hard size limit) → out-of-band
        // velocity warning → not-yet-sized advisory. B2: the badge sits
        // PERPENDICULAR to the duct axis, clear of the casing, on the side the
        // size chip did NOT take — so neither the DN/Ø chip nor (on a vertical
        // duct) the casing is overprinted. Its footprint joins [placedLabels] so
        // a later run's label dodges it too.
        if (opacity >= 1.0 &&
            (overCapacityIds.contains(e.id) ||
                warningIds.contains(e.id) ||
                unsizedIds.contains(e.id))) {
          final badge = _badgeCenter(pa, pb, outer, labelSide);
          placedLabels.add(Rect.fromCenter(center: badge, width: 16, height: 16));
          if (overCapacityIds.contains(e.id)) {
            _overCapacityBadge(canvas, badge);
          } else if (warningIds.contains(e.id)) {
            _warnBadge(canvas, badge);
          } else {
            _unsizedBadge(canvas, badge);
          }
        }
      } else {
        final tag = riserTagById[e.id];
        for (final n in [a, b]) {
          if (_onThisFloor(n)) {
            final mp = transform.worldToScreen(Offset(n.x, n.y));
            // B16 — the riser glyph + its halos grow with the widest incident
            // pipe (floored so a thin riser keeps the compact marker).
            final markerR = glyphRadiusPx(nodeMaxOuter[n.id] ?? 0.0, 7.0);
            if (_edgeHovered(e.id)) {
              canvas.drawCircle(mp, math.max(13.0, markerR + 5),
                  Paint()..color = _kSelection.withAlpha(45));
            }
            if (_edgeSelected(e.id)) {
              canvas.drawCircle(mp, math.max(11.0, markerR + 3),
                  Paint()..color = _kSelection.withAlpha(90));
            }
            // B15 — a circle with chevron arrows: up if a riser rises from here,
            // down if it drops, both when it passes through (from the riser
            // floor deltas of this service at this node).
            final sense = _riserSenseAt(n, e.service);
            _riserMarker(canvas, mp, color,
                up: sense.up, down: sense.down, radius: markerR);
            // E6 — the engine's per-service riser id (CW-R1) beside the marker,
            // in the service colour, closing the plan↔riser cross-reference.
            // Gated to the active layer (like the size labels) so a ghosted
            // coordination layer stays uncluttered.
            if (tag != null && opacity >= 1.0) {
              _riserTagLabel(canvas, mp, tag, color);
            }
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
      // B16 — the glyph radius grows with the widest incident pipe, floored to
      // the role's current compact size so a thin/unsized node is unchanged; the
      // hover/selection halos ride on it (only exceeding today's fixed sizes
      // when the glyph itself does).
      final incidentOuter = nodeMaxOuter[n.id] ?? 0.0;
      final glyphR = n.component != null
          ? glyphRadiusPx(incidentOuter, 9.0)
          : glyphRadiusPx(incidentOuter, n.role == NodeRole.main ? 3.0 : 4.5);
      // Hover pre-highlight (E7) — a wider, fainter ring under the selection ring.
      if (_nodeHovered(n.id)) {
        canvas.drawCircle(p, math.max(11.0, glyphR + 2),
            Paint()..color = _kSelection.withAlpha(45));
      }
      final selected = _nodeSelected(n.id);
      if (selected) {
        final ringR = math.max(9.0, glyphR);
        canvas.drawCircle(p, ringR, Paint()..color = _kSelection.withAlpha(70));
        canvas.drawCircle(
          p,
          ringR,
          Paint()
            ..color = _kSelection
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke,
        );
      }
      if (n.component != null) {
        _componentGlyph(canvas, p, n.component!, layer.opacity, glyphR);
        // G1: the stable equipment tag (P-01 / TK-01 / AHU-01 …) beside the
        // glyph — the plan↔schedule cross-reference. Active layer only (like the
        // size + riser labels), collision-aware against the run labels already
        // placed this frame.
        final eqTag = equipmentTagById[n.id];
        if (eqTag != null && layer.opacity >= 1.0) {
          _equipmentTagLabel(canvas, p, eqTag, placedLabels);
        }
      } else if (n.role != NodeRole.main || joints[n.id] == null) {
        // A plain junction that carries a fitting glyph (drawn above) no longer
        // needs the bare dot; a free main node (no pipes yet) still gets it.
        _nodeGlyph(canvas, p, n.role, layer.opacity, incidentOuter);
      }
      // Air-terminal ring: out-of-band face velocity (warning) takes precedence
      // over the not-yet-sized advisory. B16 — the ring rides the glyph size.
      if (layer.opacity >= 1.0) {
        final termR = math.max(12.0, glyphR + 3);
        if (warningIds.contains(n.id)) {
          canvas.drawCircle(
            p,
            termR,
            Paint()
              ..color = _kWarn
              ..strokeWidth = 2
              ..style = PaintingStyle.stroke,
          );
        } else if (unsizedIds.contains(n.id)) {
          canvas.drawCircle(
            p,
            termR,
            Paint()
              ..color = _kUnsized
              ..strokeWidth = 1.5
              ..style = PaintingStyle.stroke,
          );
        }
      }
    }
  }

  /// A small hollow advisory dot for an air element not yet manually sized.
  /// The screen point for an air status badge on the run pa→pb (B2): offset
  /// PERPENDICULAR to the duct axis, clear of the [outer] casing, on the side
  /// OPPOSITE the size chip ([labelSide]: `1` chip upper → badge lower, `-1`
  /// chip lower → badge upper, `null` no chip → default lower). This keeps the
  /// "!"/triangle off the DN/Ø chip and, on a vertical duct, off the casing
  /// (both of which the old fixed `mid.y-13` offset overprinted). Falls back to
  /// the midpoint for a degenerate zero-length run.
  Offset _badgeCenter(Offset pa, Offset pb, double outer, int? labelSide) {
    final mid = (pa + pb) / 2;
    final len = (pb - pa).distance;
    if (len <= 1e-6) return mid;
    final u = (pb - pa) / len;
    var perp = Offset(-u.dy, u.dx);
    if (perp.dy > 0) perp = -perp; // consistent "up" (perp+)
    // Opposite the chip; default lower (perp-) when there is no chip.
    final side = labelSide == -1 ? 1.0 : -1.0;
    final off = outer / 2 + 10; // clear the wall + the badge halo
    return mid + perp * side * off;
  }

  void _unsizedBadge(Canvas canvas, Offset center) {
    canvas.drawCircle(center, 4, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(
      center,
      4,
      Paint()
        ..color = _kUnsized
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  /// The on-screen outer width (px) of a pipe — delegates to the top-level
  /// [pipeOuterPx] (shared with the B5 canvas hit-test corridor in
  /// selection_overlay.dart) with this painter's own scale/calibration.
  double _pipeOuterPx(EdgeSizing? s, ServiceType svc) => pipeOuterPx(s, svc,
      scale: transform.scale, metersPerPixel: metersPerPixel);

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

  /// A small "!" badge marking an air element whose velocity is out of band.
  void _warnBadge(Canvas canvas, Offset center) {
    canvas.drawCircle(center, 6, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(center, 5.5, Paint()..color = _kWarn);
    final tp = TextPainter(
      text: const TextSpan(
        text: '!',
        style: TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 9,
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  /// A warning-TRIANGLE badge marking an edge clamped at the largest table
  /// size (over capacity). The triangle shape (vs the round velocity
  /// "!" dot) plus the red colour give a redundant, distinct cue that this is a
  /// hard size limit, not merely an out-of-band velocity.
  void _overCapacityBadge(Canvas canvas, Offset center) {
    // White halo so it reads over the pipe body.
    canvas.drawCircle(center, 7.5, Paint()..color = const Color(0xFFFFFFFF));
    final tri = Path()
      ..moveTo(center.dx, center.dy - 6.5)
      ..lineTo(center.dx + 6.0, center.dy + 5.0)
      ..lineTo(center.dx - 6.0, center.dy + 5.0)
      ..close();
    canvas.drawPath(tri, Paint()..color = _kOverCapacity);
    final tp = TextPainter(
      text: const TextSpan(
        text: '!',
        style: TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 8,
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
        canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2 + 1.5));
  }

  /// Draws a run as a walled pipe: a darker casing stroke (the two visible wall
  /// lines) with the service-colour bore inside it. When [dash] is null (solid
  /// services) this is byte-identical to before. When [dash] is a stroke recipe
  /// ([serviceDashPattern] — dashed vent/return air, dash-dot fire) the bore is
  /// walked as dash segments over a THINNER solid casing so the line reads as its
  /// drafting linetype while still showing pipe width.
  void _paintPipe(Canvas canvas, Offset pa, Offset pb, Color color, double outer,
      {List<double>? dash}) {
    final wall = Color.lerp(color, const Color(0xFF000000), 0.45)!;
    if (dash == null) {
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
      return;
    }
    // Dashed linetype: a thinner solid casing, then the coloured bore walked as
    // dash segments over it.
    final casingW = math.max(2.4, outer - 2.0);
    canvas.drawLine(
      pa,
      pb,
      Paint()
        ..color = wall
        ..strokeWidth = casingW
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
    final boreW = math.max(1.2, casingW - 2.0);
    _walkDash(
      canvas,
      pa,
      pb,
      dash,
      Paint()
        ..color = color
        ..strokeWidth = boreW
        ..strokeCap = StrokeCap.butt
        ..style = PaintingStyle.stroke,
    );
  }

  /// Walks a `[on, off, on, off, …]` dash [pattern] from [a] to [b], drawing the
  /// "on" segments with [paint] (crib of the inferred-riser dash loop, generalised
  /// to an alternating multi-element pattern so a dash-dot recipe works too).
  void _walkDash(
      Canvas canvas, Offset a, Offset b, List<double> pattern, Paint paint) {
    final total = (b - a).distance;
    if (total <= 0 || pattern.isEmpty) return;
    final dir = (b - a) / total;
    var dist = 0.0;
    var idx = 0;
    var on = true; // pattern[0] is a drawn dash
    while (dist < total) {
      final seg = pattern[idx % pattern.length];
      final end = math.min(dist + seg, total);
      if (on && end > dist) {
        canvas.drawLine(a + dir * dist, a + dir * end, paint);
      }
      dist = end;
      idx++;
      on = !on;
    }
  }

  /// A small open flow-direction chevron (two short strokes, an arrow-head with
  /// no base) at [p] pointing along the unit flow direction [dir], in the service
  /// [base] colour at reduced alpha (scaled by the layer [opacity] so it fades
  /// with a coordination layer).
  void _flowChevron(
      Canvas canvas, Offset p, Offset dir, Color base, double opacity) {
    const arm = 5.0;
    final perp = Offset(-dir.dy, dir.dx);
    final tip = p + dir * (arm * 0.5);
    final back = tip - dir * arm;
    final wing1 = back + perp * (arm * 0.75);
    final wing2 = back - perp * (arm * 0.75);
    final paint = Paint()
      ..color = base.withAlpha((150 * opacity).round().clamp(0, 255))
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(wing1, tip, paint);
    canvas.drawLine(wing2, tip, paint);
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
      Canvas canvas, Offset p, NodeComponent c, double opacity, double r) {
    final dark = _fade(const Color(0xFF15171B), opacity);
    final light = _fade(const Color(0xFFFFFFFF), opacity);
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
    paintComponentSymbol(canvas, Size(r * 2, r * 2), c, dark, stroke: 1.2);
    canvas.restore();
  }

  /// Draws a node glyph by role: plant = filled square (tank/pump), fixture =
  /// hollow ring, main/junction = small filled dot. [opacity] fades it on a
  /// coordination (inactive) layer. B16 — the glyph radius grows with the widest
  /// incident pipe [incidentOuter] (px), floored to the role's compact size so a
  /// thin/unsized node is unchanged.
  void _nodeGlyph(Canvas canvas, Offset p, NodeRole role, double opacity,
      double incidentOuter) {
    final dark = _fade(const Color(0xFF15171B), opacity);
    final light = _fade(const Color(0xFFFFFFFF), opacity);
    switch (role) {
      case NodeRole.plant:
        final half = glyphRadiusPx(incidentOuter, 4.5);
        final r = Rect.fromCenter(center: p, width: half * 2, height: half * 2);
        canvas.drawRect(r, Paint()..color = dark);
        canvas.drawRect(
          r,
          Paint()
            ..color = light
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke,
        );
      case NodeRole.fixture:
        final rr = glyphRadiusPx(incidentOuter, 4.5);
        canvas.drawCircle(p, rr, Paint()..color = dark);
        canvas.drawCircle(
          p,
          rr,
          Paint()
            ..color = light
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke,
        );
      case NodeRole.main:
        final rr = glyphRadiusPx(incidentOuter, 3.0);
        canvas.drawCircle(p, rr, Paint()..color = dark);
        canvas.drawCircle(
          p,
          rr,
          Paint()
            ..color = light
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
    }
  }

  /// B15 — the vertical sense of the risers of [svc] meeting at [n]: `up` when a
  /// riser rises to a higher floor from here, `down` when one drops, both when a
  /// riser passes through. Falls back to both when indeterminate so the marker
  /// never reads as a bare circle (never fabricates a wrong single direction).
  ({bool up, bool down}) _riserSenseAt(NetNode n, ServiceType svc) {
    var up = false;
    var down = false;
    for (final e in net.edges) {
      if (e.kind != EdgeKind.riser || e.service != svc) continue;
      if (e.fromId != n.id && e.toId != n.id) continue;
      final other = net.nodeById(e.fromId == n.id ? e.toId : e.fromId);
      if (other == null) continue;
      if (other.floorIndex > n.floorIndex) {
        up = true;
      } else if (other.floorIndex < n.floorIndex) {
        down = true;
      }
    }
    if (!up && !down) return (up: true, down: true);
    return (up: up, down: down);
  }

  /// B15/B16 — the riser marker: a service-coloured circle containing chevron
  /// arrow(s) (up when a riser rises from here, down when it drops, both when it
  /// passes through). Pure Path chevrons — no text glyph, so it never renders as
  /// a missing-glyph box. The [radius] grows with the incident pipe (B16),
  /// floored so a thin riser keeps the compact marker.
  void _riserMarker(Canvas canvas, Offset p, Color color,
      {required bool up, required bool down, double radius = 7}) {
    canvas.drawCircle(p, radius, Paint()..color = color.withAlpha(38));
    canvas.drawCircle(
      p,
      radius,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
    final chevron = Paint()
      ..color = color
      ..strokeWidth = math.max(1.4, radius * 0.22)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final half = radius * 0.42;
    if (up && down) {
      // Two stacked chevrons: rise in the top half, drop in the bottom half.
      _riserChevron(canvas, p + Offset(0, -radius * 0.30), half,
          up: true, paint: chevron);
      _riserChevron(canvas, p + Offset(0, radius * 0.30), half,
          up: false, paint: chevron);
    } else {
      _riserChevron(canvas, p, half, up: up, paint: chevron);
    }
  }

  /// One chevron ("^" when [up], "v" otherwise) centred on [c] with arm
  /// half-width [half], as a pure open path (tofu-safe).
  void _riserChevron(Canvas canvas, Offset c, double half,
      {required bool up, required Paint paint}) {
    final tipY = up ? c.dy - half : c.dy + half;
    final baseY = up ? c.dy + half : c.dy - half;
    final path = Path()
      ..moveTo(c.dx - half, baseY)
      ..lineTo(c.dx, tipY)
      ..lineTo(c.dx + half, baseY);
    canvas.drawPath(path, paint);
  }

  /// The per-service riser id (e.g. `CW-R1`) drawn just to the right of a riser
  /// marker in the service [color], on a translucent chip for legibility — the
  /// plan↔riser cross-reference tag (E6). ASCII-only (Roboto-safe).
  void _riserTagLabel(Canvas canvas, Offset marker, String tag, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: tag,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 9.5,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final left = marker.dx + 9;
    final top = marker.dy - tp.height / 2;
    final rect = Rect.fromLTWH(left - 2, top - 1, tp.width + 4, tp.height + 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2.5)),
      Paint()..color = const Color(0xCCFFFFFF),
    );
    tp.paint(canvas, Offset(left, top));
  }

  /// The stable equipment tag (e.g. `P-01`) beside an equipment glyph at
  /// [glyph], in dark ink on a translucent white chip so it reads over the plan
  /// (G1). Collision-aware like the run labels: tries right / left / below /
  /// above of the glyph and takes the first slot that clears [placed] (adding
  /// its box), else draws to the right anyway — an identifier is never dropped.
  /// ASCII-only (Roboto-safe).
  void _equipmentTagLabel(
      Canvas canvas, Offset glyph, String tag, List<Rect> placed) {
    final tp = TextPainter(
      text: TextSpan(
        text: tag,
        style: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 9.5,
          color: Color(0xFF15171B),
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final boxW = tp.width + 6;
    final boxH = tp.height + 3;
    final candidates = <Offset>[
      Offset(glyph.dx + 13 + boxW / 2, glyph.dy), // right
      Offset(glyph.dx - 13 - boxW / 2, glyph.dy), // left
      Offset(glyph.dx, glyph.dy + 13 + boxH / 2), // below
      Offset(glyph.dx, glyph.dy - 13 - boxH / 2), // above
    ];
    var center = candidates.first;
    for (final c in candidates) {
      final r = Rect.fromCenter(center: c, width: boxW, height: boxH);
      if (!placed.any(r.overlaps)) {
        center = c;
        placed.add(r);
        break;
      }
    }
    final rect = Rect.fromCenter(center: center, width: boxW, height: boxH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2.5)),
      Paint()..color = const Color(0xCCFFFFFF),
    );
    tp.paint(
        canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
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
    // Ducts: the explicit product, else the service default (PU for AC
    // supply/return, BJLS for exhaust), so the canvas reflects what will be used.
    if (e.service.regime == FlowRegime.air) {
      final dp = effectiveDuctProductFor(e);
      if (dp == DuctProduct.pu) return 'PU';
      final largest = s.isRectangular
          ? math.max(s.width!.inMillimeters, s.height!.inMillimeters)
          : s.diameter.inMillimeters;
      return 'BJLS ${bjlsThicknessMm(largest).toStringAsFixed(2)}';
    }
    return null;
  }

  /// Draws a run's size label ALONG the run: rotated to the edge bearing (flipped
  /// 180° when it would read upside-down), offset perpendicular clear of the pipe
  /// body on the "upper" side, with LOD (skipped when the run is shorter than the
  /// text) and a per-frame collision dodge (opposite side → quarter-point → drop).
  /// [placedLabels] carries the screen-space bounds already placed this frame.
  ///
  /// Returns the perpendicular SIDE the chip landed on (`1` = "upper"/perp+,
  /// `-1` = "lower"/perp-) so the air status badge can dodge to the opposite
  /// side (B2), or `null` when the label was dropped for space (LOD-short or a
  /// full collision) — in which case a small tick is left at the midpoint so a
  /// sized run never reads identical to an unsized one (B8).
  int? _label(Canvas canvas, Offset pa, Offset pb, double outer, String text,
      List<Rect> placedLabels) {
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

    final runLen = (pb - pa).distance;
    final boxW = tp.width + 8;
    final boxH = tp.height + 4;
    // LOD: don't crowd a short run with a label longer than it (plus a margin).
    // B8: leave a tick so the sized-but-unlabelled run is still marked.
    if (runLen < tp.width + 12) {
      _droppedLabelMark(canvas, (pa + pb) / 2);
      return null;
    }

    final u = (pb - pa) / runLen;
    // Perpendicular pointing "up" (toward smaller screen y) for a consistent side.
    var perp = Offset(-u.dy, u.dx);
    if (perp.dy > 0) perp = -perp;
    final mid = (pa + pb) / 2;
    // Offset the chip centre clear of the pipe: half its width + 5 + half the
    // label height so the chip edge clears the wall.
    final off = outer / 2 + 5 + boxH / 2;

    // Candidate centres in order: upper side, opposite side, quarter-point upper.
    // The parallel `sides` list records which perpendicular side each candidate
    // sits on so the caller can steer the badge to the other side (B2).
    final quarter = pa + u * (runLen * 0.25);
    final candidates = <Offset>[
      mid + perp * off,
      mid - perp * off,
      quarter + perp * off,
    ];
    const sides = <int>[1, -1, 1];
    Offset? center;
    var side = 1;
    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      // Collision test uses the axis-aligned chip box (a good-enough proxy for
      // the rotated label); deterministic in edge-list order.
      final r = Rect.fromCenter(center: c, width: boxW, height: boxH);
      if (!placedLabels.any(r.overlaps)) {
        center = c;
        side = sides[i];
        placedLabels.add(r);
        break;
      }
    }
    if (center == null) {
      // Still colliding → drop the chip but leave a tick (B8) so the run doesn't
      // read as unsized.
      _droppedLabelMark(canvas, mid);
      return null;
    }

    // Rotate to the bearing; flip 180° when it would read upside-down.
    var angle = math.atan2(u.dy, u.dx);
    if (angle > math.pi / 2 || angle < -math.pi / 2) angle += math.pi;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    final rect = Rect.fromCenter(center: Offset.zero, width: boxW, height: boxH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = const Color(0xD915171B),
    );
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
    return side;
  }

  /// A tiny placeholder tick left at a run's midpoint when its size label was
  /// dropped for space (B8) — a short run or a full collision dodge. It signals
  /// "a size value exists here, just not shown" so a sized run never reads
  /// identical to an unsized one. Deliberately DISTINCT from the hollow
  /// unsized-advisory ring: a small SOLID chip-coloured dot with a white halo.
  void _droppedLabelMark(Canvas canvas, Offset mid) {
    canvas.drawCircle(mid, 3.0, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(mid, 2.0, Paint()..color = const Color(0xD915171B));
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
      old.hoveredNodeId != hoveredNodeId ||
      old.hoveredEdgeId != hoveredEdgeId ||
      !_sameStrSet(old.selectedNodeIds, selectedNodeIds) ||
      !_sameStrSet(old.selectedEdgeIds, selectedEdgeIds) ||
      old.layerFiltered != layerFiltered ||
      old.activeDiscipline != activeDiscipline ||
      !_sameSet(old.visibleDisciplines, visibleDisciplines) ||
      !_sameSvcSet(old.hiddenServices, hiddenServices) ||
      !_sameStrSet(old.warningIds, warningIds) ||
      !_sameStrSet(old.unsizedIds, unsizedIds) ||
      !_sameStrSet(old.overCapacityIds, overCapacityIds);

  static bool _sameSet(Set<DisciplineLayer> a, Set<DisciplineLayer> b) =>
      a.length == b.length && a.containsAll(b);

  static bool _sameSvcSet(Set<ServiceType> a, Set<ServiceType> b) =>
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
