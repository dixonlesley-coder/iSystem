import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/annotation_store.dart';
import '../../store/app_state.dart' show statusMessageProvider;
import '../../store/base_point_command_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/reference_line_store.dart';
import '../../store/selection_scope.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/smart_input_store.dart';
import '../../store/snap_settings_store.dart';
import '../strings/plural.dart';
import '../theme/mechx_theme.dart';
import 'canvas_grid.dart' show calibratedGridWorldStep, nearestGridIntersection;
import 'drawing_overlay.dart'
    show RubberBandPainter, polarLabel, snapKindLabel, snapOrTeeMarked;
import 'floor_index.dart';
import 'snapping.dart';
import 'underlay_snap_service.dart';
import 'viewport.dart';

/// M8 — arm a base-point [kind] (Move / Copy / Rotate) on the current
/// selection: the shared entry point of the G / C / T keys and the node / run
/// context-menu rows, so the two can never disagree about what is acted on.
///
/// The selection is SCOPED exactly like Delete (C3): only members on the
/// current sheet and on a visible, unlocked service take part, and the status
/// pill names any that were left out. Any annotation mode / draw tool is
/// stepped out of first (the command's overlay owns the clicks). Returns
/// whether a command was armed (false — with a status hint — when nothing in
/// scope is selected).
bool startBasePointCommand(WidgetRef ref, BasePointCommandKind kind) {
  final sheets = ref.read(sheetsContentProvider);
  final sheet = sheets.current;
  if (sheet == null) return false;
  final levelCount = ref.read(projectControllerProvider).building.levelCount;
  final floor = sheets.floorFor(sheet.id, levelCount);
  final sel = ref.read(selectionProvider);
  final scope = scopeSelection(
    net: ref.read(networkControllerProvider).network,
    nodeIds: sel.nodeIds.isEmpty
        ? {if (sel.nodeId != null) sel.nodeId!}
        : sel.nodeIds,
    edgeIds: sel.edgeIds.isEmpty
        ? {if (sel.edgeId != null) sel.edgeId!}
        : sel.edgeIds,
    sheetId: sheet.id,
    inertServices: ref.read(inertServicesProvider),
  );
  final status = ref.read(statusMessageProvider.notifier);
  if (scope.isEmpty) {
    status.showStatus('Select something on this sheet first, then '
        '${basePointVerb(kind).toLowerCase()} it');
    return false;
  }
  if (scope.hasExcluded) {
    status.showStatus('${pluralCount(scope.excludedCount, 'selected element',
        'selected elements')} on another sheet or a hidden / locked layer '
        'left out');
  }
  final net = ref.read(networkControllerProvider.notifier);
  if (ref.read(networkControllerProvider).tool != DrawTool.select) {
    net.setTool(DrawTool.select);
  }
  ref.read(measureModeProvider.notifier).set(false);
  ref.read(tankModeProvider.notifier).set(false);
  ref.read(roomModeProvider.notifier).set(false);
  ref.read(refLineModeProvider.notifier).set(false);
  return ref.read(basePointCommandProvider.notifier).start(
        kind,
        nodeIds: scope.nodeIds,
        edgeIds: scope.edgeIds,
        sheetId: sheet.id,
        floorIndex: floor,
      );
}

/// The command's verb ('Move' / 'Copy' / 'Rotate').
String basePointVerb(BasePointCommandKind kind) => switch (kind) {
      BasePointCommandKind.move => 'Move',
      BasePointCommandKind.copy => 'Copy',
      BasePointCommandKind.rotate => 'Rotate',
    };

/// The single-key shortcut that arms [kind] (echoed on the mode pill and in
/// the F1 sheet / menus).
String basePointKey(BasePointCommandKind kind) => switch (kind) {
      BasePointCommandKind.move => 'G',
      BasePointCommandKind.copy => 'C',
      BasePointCommandKind.rotate => 'T',
    };

/// The on-canvas mode-pill text for the live [c] — what the next click does.
String basePointModeLabel(BasePointCommand c) {
  final verb = basePointVerb(c.kind);
  if (c.pickingBase) return '$verb · pick base point';
  return switch (c.kind) {
    BasePointCommandKind.move => 'Move · pick target or type @x,y',
    BasePointCommandKind.copy => c.placed == 0
        ? 'Copy · pick target or type @x,y'
        : 'Copy · ${c.placed} placed · next target, Enter ends',
    BasePointCommandKind.rotate => 'Rotate · click a bearing or type an angle',
  };
}

/// The AutoCAD bearing (degrees, 0 = East, counter-clockwise positive as seen;
/// screen y is down) from [from] to [to].
double screenBearingDeg(Offset from, Offset to) {
  final d = to - from;
  return math.atan2(-d.dy, d.dx) * 180.0 / math.pi;
}

/// [p] turned by [deg] (AutoCAD sense: CCW as seen) about [pivot] — the
/// preview twin of `NetworkController.rotateSelectionAbout` (the commit keeps
/// its own exact quarter-turn / 45° paths; the ghost needs no bit-exactness).
Offset rotateAboutForPreview(Offset p, Offset pivot, double deg) {
  final r = deg * math.pi / 180.0;
  final c = math.cos(r), s = math.sin(r);
  final d = p - pivot;
  return pivot + Offset(d.dx * c + d.dy * s, -d.dx * s + d.dy * c);
}

/// The interaction layer of a live base-point command (mounted on the Layout
/// canvas above the selection overlay while [basePointCommandProvider] is
/// set): it resolves each pick through the drafting snap ladder (node >
/// run midpoint > on-run nearest > plan underlay > magnetic grid; ortho ^
/// Shift constrains the target to 45° steps from the base), paints the base
/// marker, the base → cursor rubber band with its polar read-out, and a GHOST
/// of the selection where the click would put it. Left-click picks; a
/// right-click backs out (Copy: ends after its placements). Gesture-time only
/// — never mounted at rest, so goldens are byte-identical.
class BasePointOverlay extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;

  const BasePointOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
  });

  @override
  ConsumerState<BasePointOverlay> createState() => _BasePointOverlayState();
}

class _BasePointOverlayState extends ConsumerState<BasePointOverlay> {
  Offset? _hoverWorld;

  @override
  Widget build(BuildContext context) {
    final cmd = ref.watch(basePointCommandProvider);
    if (cmd == null) return const SizedBox.shrink();
    final net = ref.watch(networkControllerProvider.select((d) => d.network));
    final transform = ref.watch(sheetViewportProvider(widget.sheetId)) ??
        const ViewportTransform();
    final calibration =
        ref.watch(projectControllerProvider).calibrationFor(widget.sheetId);
    final inert = ref.watch(inertServicesProvider);
    final ortho = ref.watch(orthoProvider);
    final snapToPlan = ref.watch(snapToPlanProvider);
    final refLines = ref.watch(referenceLinesProvider);
    final sheet = ref.watch(sheetsContentProvider).sheetById(widget.sheetId);
    final underlaySvc = ref.read(underlaySnapServiceProvider);
    final gridMpp = calibration?.metersPerPixel;
    final gridEligible = ref.watch(gridSnapProvider) &&
        gridMpp != null &&
        calibratedGridWorldStep(gridMpp) * transform.scale >= 6.0;
    final snapWorld = 12 / transform.scale;
    final pickWorld = 14 / transform.scale;
    final effOrtho = ortho ^ HardwareKeyboard.instance.isShiftPressed;
    final base = cmd.base;
    final accent = context.colors.accent;

    // The snap ladder for one raw world point.
    _Pick resolve(Offset raw) {
      final hit = snapOrTeeMarked(
          net, widget.sheetId, widget.floorIndex, raw, snapWorld,
          avoidServices: inert);
      if (hit != null && hit.kind == SnapKind.node) {
        return _Pick(hit.point, SnapKind.node);
      }
      final runs = <(Offset, Offset)>[
        for (final r in floorIndexOf(net, widget.sheetId, widget.floorIndex)
            .runs)
          if (!inert.contains(r.edge.service))
            (Offset(r.a.x, r.a.y), Offset(r.b.x, r.b.y)),
      ];
      final mid = nearestRunMidpoint(runs, raw, pickWorld);
      if (mid != null &&
          (hit == null || mid.distance <= (hit.point - raw).distance)) {
        return _Pick(mid.point, SnapKind.midpoint);
      }
      if (hit != null) return _Pick(hit.point, SnapKind.refline);
      if (sheet != null) {
        final u = underlaySvc.snap(sheet, refLines, raw, pickWorld,
            enabled: snapToPlan,
            orthoAnchor: effOrtho ? base : null,
            anchor: base);
        if (u != null) return _Pick(u.point, u.kind, segments: u.segments);
      }
      if (effOrtho && gridEligible) {
        final g = nearestGridIntersection(raw, gridMpp);
        if ((g - raw).distance <= snapWorld) return _Pick(g, SnapKind.grid);
      }
      return _Pick(raw, null);
    }

    // The live pick under the cursor (ortho-projected from the base first).
    _Pick? pick;
    final hover = _hoverWorld;
    if (hover != null) {
      final raw = (base != null && effOrtho) ? orthoSnap(base, hover) : hover;
      pick = resolve(raw);
    }

    // Where the selection would land for the live pick.
    Offset Function(Offset p)? place;
    if (base != null && pick != null) {
      if (cmd.kind == BasePointCommandKind.rotate) {
        if (pick.point != base) {
          var deg = screenBearingDeg(base, pick.point);
          if (effOrtho) deg = (deg / 45).roundToDouble() * 45;
          place = (p) => rotateAboutForPreview(p, base, deg);
        }
      } else {
        final d = pick.point - base;
        place = (p) => p + d;
      }
    }

    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      onHover: (e) {
        final w = transform.screenToWorld(e.localPosition);
        ref.read(drawHoverProvider.notifier).set(w);
        setState(() => _hoverWorld = w);
      },
      onExit: (_) => ref.read(drawHoverProvider.notifier).set(null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final w = transform.screenToWorld(d.localPosition);
          final b = ref.read(basePointCommandProvider)?.base;
          final eo = ref.read(orthoProvider) ^
              HardwareKeyboard.instance.isShiftPressed;
          final p = resolve((b != null && eo) ? orthoSnap(b, w) : w).point;
          final ctrl = ref.read(basePointCommandProvider.notifier);
          if (b == null) {
            ctrl.setBase(p);
          } else if (cmd.kind == BasePointCommandKind.rotate) {
            if (p == b) return;
            var deg = screenBearingDeg(b, p);
            if (eo) deg = (deg / 45).roundToDouble() * 45;
            ctrl.rotateBy(deg);
          } else {
            ctrl.placeTarget(p);
          }
          setState(() => _hoverWorld = w);
        },
        onSecondaryTapUp: (_) =>
            ref.read(basePointCommandProvider.notifier).cancel(),
        child: CustomPaint(
          size: Size.infinite,
          painter: _GhostPainter(
            segments: place == null
                ? const []
                : _ghostSegments(net, cmd, place, transform),
            color: accent,
          ),
          foregroundPainter: RubberBandPainter(
            pending: base,
            hover: base == null ? null : pick?.point,
            snapScreen: (pick != null && pick.kind != null)
                ? transform.worldToScreen(pick.point)
                : null,
            snapKind: pick?.kind ?? SnapKind.refline,
            snapLabel: (pick != null && pick.kind != null)
                ? (pick.kind == SnapKind.refline &&
                        pick.segments.isEmpty
                    ? 'Nearest'
                    : snapKindLabel(pick.kind!))
                : null,
            snapSegmentsScreen: [
              if (pick != null && pick.kind != null)
                for (final (a, b) in pick.segments)
                  (transform.worldToScreen(a), transform.worldToScreen(b)),
            ],
            polarText: (base != null && pick != null)
                ? (cmd.kind == BasePointCommandKind.rotate
                    ? 'turn ${formatAngleDeg(_roundedBearing(base, pick.point, effOrtho))}'
                    : polarLabel(base, pick.point, calibration))
                : null,
            transform: transform,
            calibration: calibration,
            color: accent,
            active: true,
          ),
        ),
      ),
    );
  }

  static double _roundedBearing(Offset base, Offset p, bool ortho) {
    var deg = screenBearingDeg(base, p);
    if (ortho) deg = (deg / 45).roundToDouble() * 45;
    return (deg * 10).roundToDouble() / 10;
  }

  /// The selection's edges (both ends in the captured set) mapped through
  /// [place], in screen px — the ghost.
  static List<(Offset, Offset)> _ghostSegments(
    Network net,
    BasePointCommand cmd,
    Offset Function(Offset) place,
    ViewportTransform t,
  ) {
    final ids = <String>{...cmd.nodeIds};
    for (final id in cmd.edgeIds) {
      final e = net.edgeById(id);
      if (e != null) ids..add(e.fromId)..add(e.toId);
    }
    // The edges the commit carries along: a Copy clones exactly the selected
    // edges; a Move / Rotate moves every edge whose two ends both move.
    // Indexed lookups only (`edgeById` / `edgesAt`) — never a whole-network
    // scan per hover frame.
    final edges = <String, NetEdge>{};
    for (final id in cmd.edgeIds) {
      final e = net.edgeById(id);
      if (e != null) edges[e.id] = e;
    }
    if (cmd.kind != BasePointCommandKind.copy) {
      for (final id in ids) {
        for (final e in net.edgesAt(id)) {
          if (ids.contains(e.fromId) && ids.contains(e.toId)) edges[e.id] = e;
        }
      }
    }
    final out = <(Offset, Offset)>[];
    for (final e in edges.values) {
      final a = net.nodeById(e.fromId), b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      if (a.sheetId != cmd.sheetId && b.sheetId != cmd.sheetId) continue;
      out.add((
        t.worldToScreen(place(Offset(a.x, a.y))),
        t.worldToScreen(place(Offset(b.x, b.y))),
      ));
    }
    for (final id in ids) {
      final n = net.nodeById(id);
      if (n == null || n.sheetId != cmd.sheetId) continue;
      final p = t.worldToScreen(place(Offset(n.x, n.y)));
      out.add((p, p));
    }
    return out;
  }
}

/// One resolved pick: the point, the OSNAP feature it latched (null = raw),
/// and the plan segments it latched onto (for the highlight).
class _Pick {
  final Offset point;
  final SnapKind? kind;
  final List<(Offset, Offset)> segments;
  const _Pick(this.point, this.kind, {this.segments = const []});
}

/// Paints the selection ghost: each segment as a translucent accent line, each
/// zero-length segment (a node) as a small ring.
class _GhostPainter extends CustomPainter {
  final List<(Offset, Offset)> segments;
  final Color color;
  const _GhostPainter({required this.segments, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (segments.isEmpty) return;
    final line = Paint()
      ..color = color.withAlpha(140)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final ring = Paint()
      ..color = color.withAlpha(170)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final (a, b) in segments) {
      if (a == b) {
        canvas.drawCircle(a, 3.5, ring);
      } else {
        canvas.drawLine(a, b, line);
      }
    }
  }

  @override
  bool shouldRepaint(_GhostPainter old) =>
      old.color != color || old.segments != segments;
}
