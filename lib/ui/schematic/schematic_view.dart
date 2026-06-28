/// The VERTICAL (elevation) workspace — the vertical sibling of the horizontal
/// Plan canvas. Floors are stacked by their TRUE elevation (§10): floor 0 at the
/// bottom, the roof at the top. It has two modes:
///
///   • **Auto** — the read-only generated riser diagram (nodes per floor laid
///     out by their canvas x, risers as orthogonal L-shapes), exactly as before.
///   • **Edit** — an editable placement/sizing surface: drag a "Riser" card from
///     the palette onto a floor to drop a riser at that horizontal x spanning to
///     the floor above; drag a riser sideways to reposition it; right-click a
///     riser to set its nominal size in inches or pick a material (the shared
///     [showEdgeContextMenu]); the riser's run length is the floor-to-floor
///     elevation delta and is shown beside it.
///
/// GEOMETRY-IS-TRUTH (§10): a riser's vertical length is ALWAYS the elevation
/// delta of its endpoints (via `edgeLength` / the building levels), NEVER a
/// pixel distance. Horizontal position (x) is free; vertical length is derived,
/// so dragging a riser sideways never changes its length.
///
/// Styled entirely with MechXTheme — no Material. The pure sizing engine does
/// all sizing; this widget reads its [EdgeSizing] records and drives the
/// network store's edit intents.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';

import '../../store/app_state.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../canvas/edge_context_menu.dart';
import '../canvas/segment_symbols.dart';
import '../canvas/service_style.dart';
import '../canvas/viewport.dart';
import '../canvas/zoom_controls.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_focus_ring.dart';

// ---------------------------------------------------------------------------
// Public widget
// ---------------------------------------------------------------------------

/// Which mode the elevation surface is in.
enum _Mode { auto, edit }

/// Renders the vertical (elevation) workspace — an Auto read-only riser diagram
/// or an Edit placement/sizing surface — from the current network / sizing /
/// building state. Drop-in: it fills the available space.
class SchematicView extends ConsumerStatefulWidget {
  const SchematicView({super.key});

  @override
  ConsumerState<SchematicView> createState() => _SchematicViewState();
}

class _SchematicViewState extends ConsumerState<SchematicView> {
  _Mode _mode = _Mode.auto;
  bool _showHelp = false;

  /// The service a dropped riser carries.
  ServiceType _service = ServiceType.coldWater;

  /// Auto-view system filter: null = the COMBINED single-line; a service = that
  /// system only (cold/hot water, drainage, vent, rainwater/storm, air, fire).
  ServiceType? _autoFocus;

  /// Auto-view: draw dashed inferred risers for floors that share a service but
  /// have no drawn vertical between them. Default OFF (byte-identical) — opt in.
  bool _inferRisers = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: colors.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            mode: _mode,
            service: _service,
            autoFocus: _autoFocus,
            presentServices: ref
                .watch(networkControllerProvider)
                .network
                .edges
                .map((e) => e.service)
                .toSet(),
            inferRisers: _inferRisers,
            onMode: (m) => setState(() => _mode = m),
            onService: (s) => setState(() => _service = s),
            onAutoFocus: (s) => setState(() => _autoFocus = s),
            onInferRisers: (v) => setState(() => _inferRisers = v),
          ),
          Container(height: 1, color: colors.border),
          Expanded(
            child: _mode == _Mode.edit
                ? _EditElevation(
                    service: _service,
                    showHelp: _showHelp,
                    onToggleHelp: () => setState(() => _showHelp = !_showHelp),
                  )
                : _AutoElevation(focus: _autoFocus, inferRisers: _inferRisers),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Toolbar — Auto / Edit tabs + (in Edit) a service picker
// ---------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  final _Mode mode;
  final ServiceType service;
  final ServiceType? autoFocus;
  final Set<ServiceType> presentServices;
  final bool inferRisers;
  final ValueChanged<_Mode> onMode;
  final ValueChanged<ServiceType> onService;
  final ValueChanged<ServiceType?> onAutoFocus;
  final ValueChanged<bool> onInferRisers;

  const _Toolbar({
    required this.mode,
    required this.service,
    required this.autoFocus,
    required this.presentServices,
    required this.inferRisers,
    required this.onMode,
    required this.onService,
    required this.onAutoFocus,
    required this.onInferRisers,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md, vertical: MechXSpacing.sm),
      child: Row(
        children: [
          _TabButton(
            label: context.strings(StringKey.schematicAuto),
            selected: mode == _Mode.auto,
            onTap: () => onMode(_Mode.auto),
          ),
          const SizedBox(width: MechXSpacing.xs),
          _TabButton(
            label: context.strings(StringKey.schematicEdit),
            selected: mode == _Mode.edit,
            onTap: () => onMode(_Mode.edit),
          ),
          // Auto mode: a per-SYSTEM filter so the single-line can be read one
          // service at a time (clean / hot water, drainage, vent, rainwater,
          // air, fire …) or combined ("All").
          if (mode == _Mode.auto && presentServices.isNotEmpty) ...[
            const SizedBox(width: MechXSpacing.md),
            Container(width: 1, height: 22, color: colors.border),
            const SizedBox(width: MechXSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TabButton(
                      label: context.strings(StringKey.schematicSystemAll),
                      selected: autoFocus == null,
                      onTap: () => onAutoFocus(null),
                    ),
                    const SizedBox(width: MechXSpacing.xs),
                    for (final s in ServiceType.values)
                      if (presentServices.contains(s)) ...[
                        _ServiceChip(
                          service: s,
                          selected: autoFocus == s,
                          onTap: () => onAutoFocus(s),
                        ),
                        const SizedBox(width: MechXSpacing.xs),
                      ],
                    Container(width: 1, height: 22, color: colors.border),
                    const SizedBox(width: MechXSpacing.xs),
                    _TabButton(
                      label: context.strings(StringKey.schematicInferRisers),
                      selected: inferRisers,
                      onTap: () => onInferRisers(!inferRisers),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (mode == _Mode.edit) ...[
            const SizedBox(width: MechXSpacing.md),
            Container(width: 1, height: 22, color: colors.border),
            const SizedBox(width: MechXSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(context.strings(StringKey.schematicRiserService),
                        style: context.type.caption
                            .copyWith(color: colors.textMuted)),
                    const SizedBox(width: MechXSpacing.sm),
                    for (final s in ServiceType.values) ...[
                      _ServiceChip(
                        service: s,
                        selected: s == service,
                        onTap: () => onService(s),
                      ),
                      const SizedBox(width: MechXSpacing.xs),
                    ],
                  ],
                ),
              ),
            ),
            // The riser drag source is pinned at the toolbar's right — drag it
            // down onto a floor to drop a riser (no separate palette panel, so
            // the elevation canvas keeps the full width; the ? help explains).
            const SizedBox(width: MechXSpacing.sm),
            Container(width: 1, height: 22, color: colors.border),
            const SizedBox(width: MechXSpacing.sm),
            _RiserCard(service: service),
          ],
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabButton(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MechXFocusRing(
      onActivated: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs + 2),
            decoration: BoxDecoration(
              color: selected ? colors.accentMuted : const Color(0x00000000),
              borderRadius: MechXRadii.control,
              border: Border.all(
                  color: selected ? colors.accent : const Color(0x00000000)),
            ),
            child: AnimatedDefaultTextStyle(
              duration: MechXMotion.hover,
              curve: MechXMotion.standard,
              style: type.label.copyWith(
                  color: selected ? colors.textPrimary : colors.textSecondary),
              child: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}

class _ServiceChip extends StatelessWidget {
  final ServiceType service;
  final bool selected;
  final VoidCallback onTap;
  const _ServiceChip(
      {required this.service, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final swatch = serviceColor(service);
    return MechXFocusRing(
      onActivated: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 1),
            decoration: BoxDecoration(
              color: selected ? colors.accentMuted : colors.background,
              borderRadius: MechXRadii.control,
              border:
                  Border.all(color: selected ? colors.accent : colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration:
                      BoxDecoration(color: swatch, shape: BoxShape.circle),
                ),
                const SizedBox(width: MechXSpacing.xs),
                AnimatedDefaultTextStyle(
                  duration: MechXMotion.hover,
                  curve: MechXMotion.standard,
                  style: type.label.copyWith(
                      color: selected
                          ? colors.textPrimary
                          : colors.textSecondary),
                  child: Text(serviceLabel(service)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Auto mode — the read-only generated diagram (unchanged behaviour)
// ---------------------------------------------------------------------------

class _AutoElevation extends ConsumerStatefulWidget {
  final ServiceType? focus;
  final bool inferRisers;
  const _AutoElevation({this.focus, this.inferRisers = false});

  @override
  ConsumerState<_AutoElevation> createState() => _AutoElevationState();
}

class _AutoElevationState extends ConsumerState<_AutoElevation> {
  Size _size = Size.zero;
  bool _hoverInferred = false;

  /// Click tolerance (px) for hitting a dashed inferred connector.
  static const double _hitTol = 9.0;

  List<_InferredRiser> _inferred(Network net, int levels) {
    if (!widget.inferRisers || _size.isEmpty) return const [];
    final pos = _autoNodePositions(net, levels, _size, focus: widget.focus);
    return _computeInferredRisers(net, pos, widget.focus);
  }

  _InferredRiser? _hit(Offset local, Network net, int levels) {
    _InferredRiser? best;
    var bestD = _hitTol;
    for (final r in _inferred(net, levels)) {
      final d = _distanceToInferred(r, local);
      if (d < bestD) {
        bestD = d;
        best = r;
      }
    }
    return best;
  }

  void _commit(Offset local, Network net, int levels) {
    final r = _hit(local, net, levels);
    if (r == null) return;
    final added = ref
        .read(networkControllerProvider.notifier)
        .connectRiser(r.fromId, r.toId, r.service);
    if (added != null) {
      ref.read(statusMessageProvider.notifier).showStatus('Riser added');
    }
  }

  @override
  Widget build(BuildContext context) {
    final network = ref.watch(networkControllerProvider).network;
    final sizing = ref.watch(sizingProvider);
    final building = ref.watch(projectControllerProvider).building;
    final colors = context.colors;
    final type = context.type;

    if (network.nodes.isEmpty) {
      return Center(
        child: Text(
          context.strings(StringKey.schematicNoNetwork),
          style: type.body.copyWith(color: colors.textMuted),
        ),
      );
    }
    final levels = building.levelCount;

    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 800,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 600,
        );
        final paint = CustomPaint(
          size: _size,
          painter: _AutoSchematicPainter(
            network: network,
            sizing: sizing,
            building: building,
            colors: colors,
            focus: widget.focus,
            inferRisers: widget.inferRisers,
          ),
        );
        // Read-only unless inferred risers are shown — then the dashed
        // connectors become CLICKABLE: one tap commits a real sized riser.
        if (!widget.inferRisers) return paint;
        return MouseRegion(
          cursor: _hoverInferred
              ? SystemMouseCursors.click
              : MouseCursor.defer,
          onHover: (e) {
            final over = _hit(e.localPosition, network, levels) != null;
            if (over != _hoverInferred) {
              setState(() => _hoverInferred = over);
            }
          },
          onExit: (_) {
            if (_hoverInferred) setState(() => _hoverInferred = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _commit(d.localPosition, network, levels),
            child: paint,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Edit mode — interactive elevation: place / reposition / size risers
// ---------------------------------------------------------------------------

class _EditElevation extends ConsumerStatefulWidget {
  final ServiceType service;
  final bool showHelp;
  final VoidCallback onToggleHelp;

  const _EditElevation({
    required this.service,
    required this.showHelp,
    required this.onToggleHelp,
  });

  @override
  ConsumerState<_EditElevation> createState() => _EditElevationState();
}

class _EditElevationState extends ConsumerState<_EditElevation> {
  ViewportTransform? _transform;
  Size _viewportSize = Size.zero;
  final FocusNode _focus = FocusNode(debugLabel: 'elevation-canvas');

  // Middle-button pan tracking.
  bool _panning = false;
  Offset _lastPanPoint = Offset.zero;
  double _lastScale = 1.0;

  // In-flight horizontal riser drag.
  String? _draggingRiser;

  /// World-px gap between adjacent floor bands. The vertical axis is laid out by
  /// floor index (true elevation order) at a fixed band height — the riser's
  /// REAL length is still the elevation delta (used for the label + sizing),
  /// this is only the on-screen band spacing.
  static const double _bandWorldH = 160;
  static const double _worldWidth = 1200;

  ViewportTransform get _current =>
      _transform ??
      ViewportTransform.fit(_contentSize(), _viewportSize, padding: 40);

  Size _contentSize() {
    final n = ref.read(projectControllerProvider).building.levelCount;
    return Size(_worldWidth, _bandWorldH * math.max(1, n));
  }

  // Screen-y (world) of a floor band's centre — floor 0 at the bottom.
  double _bandCentreWorldY(int floorIndex, int levelCount) {
    final inverted = (levelCount - 1) - floorIndex;
    return inverted * _bandWorldH + _bandWorldH / 2;
  }

  void _emit(ViewportTransform next) {
    if (next == _transform) return;
    setState(() => _transform = next);
  }

  void _maybeFit() {
    if (_transform != null || _viewportSize.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _transform != null || _viewportSize.isEmpty) return;
      _emit(ViewportTransform.fit(_contentSize(), _viewportSize, padding: 40));
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // ── Hit-testing ───────────────────────────────────────────────────────────

  /// The nearest riser edge whose vertical leg is within [tolWorld] of the world
  /// point [w], or null. A riser's vertical leg runs at the from/to node x
  /// between the two floor band centres.
  String? _riserAt(Offset w, double tolWorld) {
    final net = ref.read(networkControllerProvider).network;
    final levelCount = ref.read(projectControllerProvider).building.levelCount;
    String? best;
    var bestD = tolWorld;
    for (final e in net.edges) {
      if (e.kind != EdgeKind.riser) continue;
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      final yA = _bandCentreWorldY(a.floorIndex, levelCount);
      final yB = _bandCentreWorldY(b.floorIndex, levelCount);
      final top = math.min(yA, yB);
      final bot = math.max(yA, yB);
      // Distance from the point to the vertical segment at x=a.x within [top,bot].
      final dx = (w.dx - a.x).abs();
      final inBand = w.dy >= top - tolWorld && w.dy <= bot + tolWorld;
      if (inBand && dx < bestD) {
        bestD = dx;
        best = e.id;
      }
    }
    return best;
  }

  // ── Gestures ───────────────────────────────────────────────────────────────

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final factor = math.pow(1.0015, -event.scrollDelta.dy).toDouble();
      _emit(_current.zoomedBy(factor, event.localPosition));
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _focus.requestFocus();
    if (event.buttons & kMiddleMouseButton != 0) {
      _panning = true;
      _lastPanPoint = event.localPosition;
      return;
    }
    if (event.buttons & kPrimaryMouseButton != 0) {
      final w = _current.screenToWorld(event.localPosition);
      final hit = _riserAt(w, 16 / _current.scale);
      if (hit != null) {
        _draggingRiser = hit;
        ref.read(selectionProvider.notifier).selectEdge(hit);
        ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
      }
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_panning) {
      _emit(_current.panned(event.localPosition - _lastPanPoint));
      _lastPanPoint = event.localPosition;
      return;
    }
    final dragging = _draggingRiser;
    if (dragging != null) {
      final w = _current.screenToWorld(event.localPosition);
      ref
          .read(networkControllerProvider.notifier)
          .moveRiserHorizontal(dragging, w.dx);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _panning = false;
    _draggingRiser = null;
  }

  void _onScaleStart(ScaleStartDetails details) => _lastScale = 1.0;

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Single-pointer pan only when NOT dragging a riser (the Listener handles
    // the riser drag); trackpad pinch always zooms.
    if (_draggingRiser != null) return;
    var vt = _current;
    if (details.pointerCount > 1 && details.focalPointDelta != Offset.zero) {
      vt = vt.panned(details.focalPointDelta);
    }
    final incremental = details.scale / _lastScale;
    _lastScale = details.scale;
    if (incremental != 1.0) {
      vt = vt.zoomedBy(incremental, details.localFocalPoint);
    }
    if (vt != _current) _emit(vt);
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final w = _current.screenToWorld(details.localPosition);
    final hit = _riserAt(w, 16 / _current.scale);
    if (hit == null) return;
    ref.read(selectionProvider.notifier).selectEdge(hit);
    showEdgeContextMenu(context, ref, hit, details.globalPosition);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      final sel = ref.read(selectionProvider);
      if (sel.isEdge) {
        ref.read(networkControllerProvider.notifier).deleteEdge(sel.edgeId!);
        ref.read(selectionProvider.notifier).clear();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // ── Palette drop ────────────────────────────────────────────────────────────

  void _onDrop(Offset localScreen) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final w = _current.screenToWorld(localScreen);
    final building = ref.read(projectControllerProvider).building;
    final levelCount = building.levelCount;
    if (levelCount < 2) return;

    // Which floor band the drop landed in.
    final invertedRaw = (w.dy / _bandWorldH).floor();
    final inverted = invertedRaw.clamp(0, levelCount - 1);
    var floorIndex = (levelCount - 1) - inverted;
    // A riser spans to the floor ABOVE — if the drop is on the top floor, drop
    // it on the floor below so it still spans a real elevation delta.
    if (floorIndex + 1 >= levelCount) floorIndex = levelCount - 2;
    if (floorIndex < 0) return;

    final sheetId = _sheetIdForFloor(floorIndex);
    final id = ref.read(networkControllerProvider.notifier).placeRiserAt(
          sheetId,
          floorIndex,
          w.dx,
          levelCount,
          service: widget.service,
        );
    if (id != null) ref.read(selectionProvider.notifier).selectEdge(id);
  }

  /// The sheet id mapped to [floorIndex] (so the riser's lower node sits on the
  /// right sheet). Falls back to the current sheet, else a synthetic id.
  String _sheetIdForFloor(int floorIndex) {
    final sheets = ref.read(sheetsControllerProvider);
    for (final s in sheets.sheets) {
      if (sheets.floorFor(
              s.id, ref.read(projectControllerProvider).building.levelCount) ==
          floorIndex) {
        return s.id;
      }
    }
    return sheets.current?.id ?? 'elevation';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final network = ref.watch(networkControllerProvider).network;
    final sizing = ref.watch(sizingProvider);
    final building = ref.watch(projectControllerProvider).building;
    final selection = ref.watch(selectionProvider);

    final canvas = Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onSecondaryTapUp: _onSecondaryTapUp,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _viewportSize = constraints.biggest;
                _maybeFit();
                final vt = _current;
                return ClipRect(
                  child: CustomPaint(
                    size: _viewportSize,
                    painter: _EditSchematicPainter(
                      network: network,
                      sizing: sizing,
                      building: building,
                      colors: colors,
                      transform: vt,
                      selectedEdgeId: selection.edgeId,
                      bandWorldH: _bandWorldH,
                      worldWidth: _worldWidth,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    // Canvas leads; the Riser palette sits on the RIGHT (tools-on-the-right,
    // consistent with the Layout / electrical workspaces).
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: DragTarget<_RiserDragData>(
                  hitTestBehavior: HitTestBehavior.translucent,
                  onAcceptWithDetails: (details) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    _onDrop(box.globalToLocal(details.offset));
                  },
                  builder: (context, candidate, rejected) {
                    final active = candidate.isNotEmpty;
                    return Stack(
                      children: [
                        Positioned.fill(child: canvas),
                        if (active)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.accent.withAlpha(18),
                                  borderRadius: MechXRadii.card,
                                  border: Border.all(
                                      color: colors.accent.withAlpha(110),
                                      width: 1.5),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (building.levelCount < 2)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: _Banner(
                        text: context
                            .strings(StringKey.schematicAddFloorBanner),
                      ),
                    ),
                  ),
                ),
              // Zoom controls (bottom-left).
              Positioned(
                left: MechXSpacing.md,
                bottom: MechXSpacing.md,
                child: ZoomControls(
                  onIn: () => _emit(_current.zoomedBy(
                      1.2, _viewportSize.center(Offset.zero))),
                  onOut: () => _emit(_current.zoomedBy(
                      1 / 1.2, _viewportSize.center(Offset.zero))),
                  onFit: () => _emit(ViewportTransform.fit(
                      _contentSize(), _viewportSize,
                      padding: 40)),
                ),
              ),
              // Help (?) (top-left).
              Positioned(
                left: MechXSpacing.md,
                top: MechXSpacing.sm,
                child: _HelpButton(
                    open: widget.showHelp, onToggle: widget.onToggleHelp),
              ),
              if (widget.showHelp)
                Positioned(
                  left: MechXSpacing.md,
                  top: 48,
                  child: _ElevationHelp(onClose: widget.onToggleHelp),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Payload dragged from the riser palette.
@immutable
class _RiserDragData {
  final ServiceType service;
  const _RiserDragData(this.service);
}

// ---------------------------------------------------------------------------
// Riser palette
// ---------------------------------------------------------------------------

class _RiserCard extends StatelessWidget {
  final ServiceType service;
  const _RiserCard({required this.service});

  @override
  Widget build(BuildContext context) {
    final chip = _chip(context, dragging: false);
    return Draggable<_RiserDragData>(
      data: _RiserDragData(service),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _chip(context, dragging: true),
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: chip),
    );
  }

  Widget _chip(BuildContext context, {required bool dragging}) {
    final colors = context.colors;
    final type = context.type;
    final swatch = serviceColor(service);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 2),
      decoration: BoxDecoration(
        color: dragging ? colors.surfaceHover : colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: dragging ? colors.accent : colors.border),
        boxShadow: dragging ? MechXShadow.popover : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A small vertical bar — a riser glyph.
          Container(width: 3, height: 16, color: swatch),
          const SizedBox(width: MechXSpacing.sm),
          Text(context.strings(StringKey.schematicRiser),
              style: type.label.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared size-label helper
// ---------------------------------------------------------------------------

String _sizeLabel(EdgeSizing s) {
  final mm = s.diameter.inMillimeters.round();
  return s.service.regime == FlowRegime.air ? 'D$mm' : 'DN$mm';
}

// ---------------------------------------------------------------------------
// Auto-mode layout + inferred-riser geometry (shared by the painter that DRAWS
// the single-line and the widget that makes the inferred risers CLICKABLE).
// ---------------------------------------------------------------------------

const double _kAutoSidePad = MechXSpacing.xl;

/// Node ids kept when one system is focused — endpoints of that service's edges
/// (null ⇒ no filtering ⇒ the combined view).
Set<String>? _focusedNodeIds(Network network, ServiceType? focus) {
  if (focus == null) return null;
  final ids = <String>{};
  for (final e in network.edges) {
    if (e.service == focus) {
      ids
        ..add(e.fromId)
        ..add(e.toId);
    }
  }
  return ids;
}

/// Screen position of each (visible) node: floors stacked by index (floor 0 at
/// the bottom), nodes spread left→right across the band by their x order.
Map<String, Offset> _autoNodePositions(
    Network network, int levelCount, Size size,
    {ServiceType? focus}) {
  final n = levelCount.clamp(1, 999999);
  double bandCentreY(int floorIndex) {
    final bandH = size.height / n;
    return bandH * ((n - 1) - floorIndex) + bandH / 2;
  }

  final visible = _focusedNodeIds(network, focus);
  final byFloor = <int, List<NetNode>>{};
  for (final node in network.nodes) {
    if (visible != null && !visible.contains(node.id)) continue;
    (byFloor[node.floorIndex] ??= []).add(node);
  }
  final positions = <String, Offset>{};
  final drawWidth = size.width - 2 * _kAutoSidePad;
  for (final entry in byFloor.entries) {
    final nodes = List<NetNode>.from(entry.value)
      ..sort((a, b) => a.x.compareTo(b.x));
    final cy = bandCentreY(entry.key);
    if (nodes.length == 1) {
      positions[nodes.first.id] = Offset(size.width / 2, cy);
    } else {
      final step = drawWidth / (nodes.length - 1);
      for (var i = 0; i < nodes.length; i++) {
        positions[nodes[i].id] = Offset(_kAutoSidePad + i * step, cy);
      }
    }
  }
  return positions;
}

/// An inferred vertical the engineer hasn't drawn: two existing nodes on
/// different floors that share a service with no drawn riser between them.
class _InferredRiser {
  final String fromId;
  final String toId;
  final ServiceType service;
  final Offset from;
  final Offset to;
  const _InferredRiser(
      this.fromId, this.toId, this.service, this.from, this.to);

  /// The vertical leg sits at the midpoint x — its main clickable extent.
  double get midX => (from.dx + to.dx) / 2;
}

/// For each service (respecting [focus]), connect consecutive service-bearing
/// floors — but per VERTICAL STACK, not one-per-floor. Nodes are paired across
/// the floor gap by **mutual-nearest-neighbour on world x**, so a building with
/// several risers of the same service gets one inferred connector per aligned
/// stack, while a spread-out horizontal main (no vertical alignment) doesn't
/// spawn a connector at every junction. Nodes already joined to the adjacent
/// floor by a DRAWN riser of that service are excluded.
List<_InferredRiser> _computeInferredRisers(
    Network network, Map<String, Offset> nodePos, ServiceType? focus) {
  final out = <_InferredRiser>[];
  final services = focus != null ? [focus] : ServiceType.values;
  for (final s in services) {
    // Visible nodes of this service, deduped, grouped by floor.
    final byFloor = <int, List<NetNode>>{};
    final seen = <String>{};
    for (final e in network.edges) {
      if (e.service != s) continue;
      for (final id in [e.fromId, e.toId]) {
        final node = network.nodeById(id);
        if (node == null || nodePos[node.id] == null) continue;
        if (seen.add(node.id)) (byFloor[node.floorIndex] ??= []).add(node);
      }
    }
    final floors = byFloor.keys.toList()..sort();
    if (floors.length < 2) continue;

    // A node already risered (drawn) to [otherFloor] for this service.
    bool drawnRiser(NetNode n, int otherFloor) => network.edges.any((e) {
          if (e.service != s || e.kind != EdgeKind.riser) return false;
          if (e.fromId == n.id) {
            return network.nodeById(e.toId)?.floorIndex == otherFloor;
          }
          if (e.toId == n.id) {
            return network.nodeById(e.fromId)?.floorIndex == otherFloor;
          }
          return false;
        });

    NetNode? nearestByX(NetNode n, List<NetNode> pool) {
      NetNode? best;
      var bestD = double.infinity;
      for (final m in pool) {
        final d = (n.x - m.x).abs();
        if (d < bestD) {
          bestD = d;
          best = m;
        }
      }
      return best;
    }

    for (var i = 0; i < floors.length - 1; i++) {
      final lo = floors[i], hi = floors[i + 1];
      final loNodes = byFloor[lo]!.where((n) => !drawnRiser(n, hi)).toList();
      final hiNodes = byFloor[hi]!.where((n) => !drawnRiser(n, lo)).toList();
      if (loNodes.isEmpty || hiNodes.isEmpty) continue;
      for (final loN in loNodes) {
        final hiN = nearestByX(loN, hiNodes);
        if (hiN == null) continue;
        // Mutual nearest → a genuine vertical stack (not a stray junction).
        if (nearestByX(hiN, loNodes)?.id != loN.id) continue;
        out.add(_InferredRiser(
            loN.id, hiN.id, s, nodePos[loN.id]!, nodePos[hiN.id]!));
      }
    }
  }
  return out;
}

/// Distance from [p] to the inferred riser's vertical leg (its main clickable
/// extent) — used to hit-test a tap/hover on the dashed connector.
double _distanceToInferred(_InferredRiser r, Offset p) {
  final x = r.midX;
  final yTop = math.min(r.from.dy, r.to.dy);
  final yBot = math.max(r.from.dy, r.to.dy);
  final clampedY = p.dy.clamp(yTop, yBot);
  return (Offset(x, clampedY) - p).distance;
}

// ---------------------------------------------------------------------------
// Auto-mode painter (the prior read-only diagram)
// ---------------------------------------------------------------------------

class _AutoSchematicPainter extends CustomPainter {
  const _AutoSchematicPainter({
    required this.network,
    required this.sizing,
    required this.building,
    required this.colors,
    this.focus,
    this.inferRisers = false,
  });

  final Network network;
  final Map<String, EdgeSizing> sizing;
  final BuildingLevels building;
  final MechXColors colors;

  /// When non-null, the single-line is filtered to ONE system (cold/hot water,
  /// drainage, vent, rainwater, air, fire …); null shows the COMBINED riser.
  final ServiceType? focus;

  /// When true, draw DASHED inferred risers connecting floors that share a
  /// service but have no DRAWN riser between them (a convenience overlay — the
  /// engineer hasn't routed the vertical, so it's shown dashed + flagged).
  final bool inferRisers;

  static const double _nodeRadius = 4.0;
  static const double _edgeStroke = 2.0;
  static const double _gridStrokeWidth = 0.5;
  static const double _labelFontSize = 10.0;
  static const double _floorLabelFontSize = 11.0;

  double _bandTopY(int floorIndex, double totalHeight) {
    final n = building.levelCount;
    final bandH = totalHeight / n;
    final invertedIndex = (n - 1) - floorIndex;
    return bandH * invertedIndex;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final nodePos =
        _autoNodePositions(network, building.levelCount, size, focus: focus);
    _paintBands(canvas, size);
    if (inferRisers) _paintInferredRisers(canvas, nodePos);
    _paintEdges(canvas, nodePos);
    _paintNodes(canvas, nodePos);
  }

  /// A human label for [node] on the single-line — its equipment name
  /// ([NodeComponent.label]) or fixture type — or null for a plain junction.
  String? _nodeLabel(NetNode node) {
    final c = node.component;
    if (c != null) return c.label;
    final f = node.fixture;
    if (f != null) return _fixtureLabel(f);
    return null;
  }

  String _fixtureLabel(PlumbingFixture f) => switch (f) {
        PlumbingFixture.waterClosetFlushValve => 'WC',
        PlumbingFixture.waterClosetFlushTank => 'WC',
        PlumbingFixture.urinalFlushTank => 'Urinal',
        PlumbingFixture.lavatory => 'Lavatory',
        PlumbingFixture.shower => 'Shower',
        PlumbingFixture.bathtub => 'Bathtub',
        PlumbingFixture.kitchenSink => 'Sink',
        PlumbingFixture.hoseBibb => 'Hose bibb',
      };

  /// Dashed connectors between floors that share a service but have NO drawn
  /// riser of that service between them — a "you haven't routed this vertical
  /// yet" overlay, drawn dashed + faded so it's clearly inferred, not designed.
  void _paintInferredRisers(Canvas canvas, Map<String, Offset> nodePos) {
    for (final r in _computeInferredRisers(network, nodePos, focus)) {
      _dashedRiser(canvas, r.from, r.to, serviceColor(r.service));
    }
  }

  void _dashedRiser(Canvas canvas, Offset from, Offset to, Color color) {
    final paint = Paint()
      ..color = color.withAlpha(140)
      ..strokeWidth = _edgeStroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final midX = (from.dx + to.dx) / 2;
    _dashedLine(canvas, from, Offset(midX, from.dy), paint);
    _dashedLine(canvas, Offset(midX, from.dy), Offset(midX, to.dy), paint);
    _dashedLine(canvas, Offset(midX, to.dy), to, paint);
    // An "inferred" tag at the vertical mid so it's not mistaken for a drawn run.
    _drawText(
      canvas,
      'inferred',
      Offset(midX + MechXSpacing.xs, (from.dy + to.dy) / 2 - MechXSpacing.sm),
      fontSize: 9,
      color: color.withAlpha(170),
      fontWeight: FontWeight.w500,
    );
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint,
      {double dash = 6, double gap = 4}) {
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final start = a + dir * d;
      final end = a + dir * math.min(d + dash, total);
      canvas.drawLine(start, end, paint);
      d += dash + gap;
    }
  }

  void _paintBands(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = colors.border.withAlpha(115)
      ..strokeWidth = _gridStrokeWidth
      ..style = PaintingStyle.stroke;

    for (var i = 0; i < building.levelCount; i++) {
      final top = _bandTopY(i, size.height);
      canvas.drawLine(Offset(0, top), Offset(size.width, top), gridPaint);

      final floor = building.floors[i];
      final elevM = building.elevationOf(i).meters;
      final label = '${floor.name}  +${elevM.toStringAsFixed(1)} m';

      _drawText(
        canvas,
        label,
        Offset(MechXSpacing.sm, top + MechXSpacing.xs),
        fontSize: _floorLabelFontSize,
        color: colors.textMuted,
        fontWeight: FontWeight.w500,
        maxWidth: size.width / 2,
      );
    }

    canvas.drawLine(
        Offset(0, size.height), Offset(size.width, size.height), gridPaint);
  }

  void _paintEdges(Canvas canvas, Map<String, Offset> nodePos) {
    for (final edge in network.edges) {
      if (focus != null && edge.service != focus) continue;
      final from = nodePos[edge.fromId];
      final to = nodePos[edge.toId];
      if (from == null || to == null) continue;

      final color = serviceColor(edge.service);
      final linePaint = Paint()
        ..color = color
        ..strokeWidth = _edgeStroke
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      if (edge.kind == EdgeKind.riser) {
        final midX = (from.dx + to.dx) / 2;
        final path = Path()
          ..moveTo(from.dx, from.dy)
          ..lineTo(midX, from.dy)
          ..lineTo(midX, to.dy)
          ..lineTo(to.dx, to.dy);
        canvas.drawPath(path, linePaint);

        final arrowY = (from.dy + to.dy) / 2;
        final goingUp = to.dy < from.dy;
        _drawArrow(canvas, Offset(midX, arrowY), goingUp, color);

        final s = sizing[edge.id];
        if (s != null) {
          _drawText(
            canvas,
            _sizeLabel(s),
            Offset(midX + MechXSpacing.xs, arrowY - MechXSpacing.sm),
            fontSize: _labelFontSize,
            color: color,
            fontWeight: FontWeight.w500,
          );
        }
      } else {
        canvas.drawLine(from, to, linePaint);
        final s = sizing[edge.id];
        if (s != null) {
          final midX = (from.dx + to.dx) / 2;
          final midY = (from.dy + to.dy) / 2;
          _drawText(
            canvas,
            _sizeLabel(s),
            Offset(midX, midY - MechXSpacing.md),
            fontSize: _labelFontSize,
            color: color,
            fontWeight: FontWeight.w500,
            centered: true,
          );
        }
      }
    }
  }

  void _drawArrow(Canvas canvas, Offset tip, bool pointUp, Color color) {
    const h = 6.0;
    const w = 4.0;
    final sign = pointUp ? -1.0 : 1.0;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - w, tip.dy + sign * h)
      ..lineTo(tip.dx + w, tip.dy + sign * h)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  /// A representative colour for [node] on the single-line: the focused system
  /// when filtered, else the service of any edge touching the node, else neutral.
  Color _nodeColor(NetNode node) {
    if (focus != null) return serviceColor(focus!);
    for (final e in network.edges) {
      if (e.fromId == node.id || e.toId == node.id) return serviceColor(e.service);
    }
    return colors.textSecondary;
  }

  /// Nodes carry their schematic symbol — equipment (`paintComponentSymbol`:
  /// pump / tank / AHU / diffuser / valve / drain …), a fixture terminal (a
  /// small down-triangle "drop"), or a plain junction dot — so the single-line
  /// reads like an engineered riser, not a string of anonymous dots.
  void _paintNodes(Canvas canvas, Map<String, Offset> nodePos) {
    const box = 20.0;
    for (final entry in nodePos.entries) {
      final pos = entry.value;
      final node = network.nodeById(entry.key);
      final color = node == null ? colors.textSecondary : _nodeColor(node);

      if (node?.component != null) {
        // A halo so the symbol reads over the run line, then the equipment glyph.
        canvas.drawCircle(pos, box * 0.62, Paint()..color = colors.canvas);
        canvas.save();
        canvas.translate(pos.dx - box / 2, pos.dy - box / 2);
        paintComponentSymbol(canvas, const Size(box, box), node!.component!, color);
        canvas.restore();
      } else if (node?.role == NodeRole.fixture) {
        // A fixture drop — a small filled down-triangle terminal.
        const r = 6.0;
        canvas.drawCircle(pos, r + 2.5, Paint()..color = colors.canvas);
        final tri = Path()
          ..moveTo(pos.dx - r, pos.dy - r * 0.7)
          ..lineTo(pos.dx + r, pos.dy - r * 0.7)
          ..lineTo(pos.dx, pos.dy + r)
          ..close();
        canvas.drawPath(tri, Paint()..color = color);
      } else {
        // A plain junction.
        canvas.drawCircle(pos, _nodeRadius + 1.5, Paint()..color = colors.canvas);
        canvas.drawCircle(pos, _nodeRadius, Paint()..color = color);
      }

      // Fixture / equipment label, centred just below the symbol.
      final label = node == null ? null : _nodeLabel(node);
      if (label != null) {
        _drawText(
          canvas,
          label,
          Offset(pos.dx, pos.dy + 13),
          fontSize: 9,
          color: colors.textMuted,
          fontWeight: FontWeight.w500,
          centered: true,
          maxWidth: 90,
        );
      }
    }
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset origin, {
    required double fontSize,
    required Color color,
    FontWeight fontWeight = FontWeight.w400,
    double? maxWidth,
    bool centered = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? 200);
    final dx = centered ? origin.dx - tp.width / 2 : origin.dx;
    tp.paint(canvas, Offset(dx, origin.dy));
  }

  @override
  bool shouldRepaint(_AutoSchematicPainter old) =>
      old.network != network ||
      old.sizing != sizing ||
      old.building != building ||
      old.colors != colors ||
      old.focus != focus ||
      old.inferRisers != inferRisers;
}

// ---------------------------------------------------------------------------
// Edit-mode painter — world-space layout under a ViewportTransform
// ---------------------------------------------------------------------------

class _EditSchematicPainter extends CustomPainter {
  const _EditSchematicPainter({
    required this.network,
    required this.sizing,
    required this.building,
    required this.colors,
    required this.transform,
    required this.selectedEdgeId,
    required this.bandWorldH,
    required this.worldWidth,
  });

  final Network network;
  final Map<String, EdgeSizing> sizing;
  final BuildingLevels building;
  final MechXColors colors;
  final ViewportTransform transform;
  final String? selectedEdgeId;
  final double bandWorldH;
  final double worldWidth;

  double _bandCentreWorldY(int floorIndex) {
    final inverted = (building.levelCount - 1) - floorIndex;
    return inverted * bandWorldH + bandWorldH / 2;
  }

  Offset _worldOf(NetNode n) =>
      Offset(n.x, _bandCentreWorldY(n.floorIndex));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _paintBands(canvas, size);
    _paintEdges(canvas);
    _paintNodes(canvas);
  }

  void _paintBands(Canvas canvas, Size size) {
    final n = building.levelCount;
    final gridPaint = Paint()
      ..color = colors.border.withAlpha(150)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Draw a horizontal floor line at each band's BOTTOM (the floor surface) and
    // a label, all in world coords mapped through the transform.
    for (var i = 0; i < n; i++) {
      final inverted = (n - 1) - i;
      final bandTopWorldY = inverted * bandWorldH;
      final bandBotWorldY = bandTopWorldY + bandWorldH;
      // Floor surface line at the bottom of the band.
      final leftS = transform.worldToScreen(Offset(0, bandBotWorldY));
      final rightS = transform.worldToScreen(Offset(worldWidth, bandBotWorldY));
      canvas.drawLine(leftS, rightS, gridPaint);

      final floor = building.floors[i];
      final elevM = building.elevationOf(i).meters;
      final label = '${floor.name}  +${elevM.toStringAsFixed(1)} m';
      final labelAt = transform.worldToScreen(
          Offset(8, bandBotWorldY - bandWorldH + 8 / transform.scale));
      _drawText(
        canvas,
        label,
        labelAt,
        fontSize: 12,
        color: colors.textMuted,
        fontWeight: FontWeight.w600,
        maxWidth: size.width / 2,
      );
    }
    // Top line (roof).
    final topLeft = transform.worldToScreen(const Offset(0, 0));
    final topRight = transform.worldToScreen(Offset(worldWidth, 0));
    canvas.drawLine(topLeft, topRight, gridPaint);
  }

  void _paintEdges(Canvas canvas) {
    for (final edge in network.edges) {
      final a = network.nodeById(edge.fromId);
      final b = network.nodeById(edge.toId);
      if (a == null || b == null) continue;
      final color = serviceColor(edge.service);
      final selected = edge.id == selectedEdgeId;

      final fromS = transform.worldToScreen(_worldOf(a));
      final toS = transform.worldToScreen(_worldOf(b));

      if (edge.id == selectedEdgeId) {
        // Selection halo behind the line — a soft, blurred glow so the
        // selection 'floats' (Apple-soft) rather than reading as a hard band.
        canvas.drawLine(
          fromS,
          toS,
          Paint()
            ..color = colors.accent.withAlpha(64)
            ..strokeWidth = 7
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
      }

      final stroke = (edge.kind == EdgeKind.riser ? 2.5 : 2.0) *
          (selected ? 1.3 : 1.0);
      final linePaint = Paint()
        ..color = color
        ..strokeWidth = stroke
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(fromS, toS, linePaint);

      if (edge.kind == EdgeKind.riser) {
        final goingUp = toS.dy < fromS.dy;
        final mid = Offset((fromS.dx + toS.dx) / 2, (fromS.dy + toS.dy) / 2);
        _drawArrow(canvas, mid, goingUp, color);

        // Length (elevation delta) + sized diameter label.
        final lengthM = (nodeElevation(b, building).meters -
                nodeElevation(a, building).meters)
            .abs();
        final s = sizing[edge.id];
        final lenStr = '${lengthM.toStringAsFixed(1)} m';
        final label = s != null ? '${_sizeLabel(s)} · $lenStr' : lenStr;
        _drawText(
          canvas,
          label,
          mid + const Offset(8, -16),
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        );
      } else {
        final s = sizing[edge.id];
        if (s != null) {
          final mid = Offset((fromS.dx + toS.dx) / 2, (fromS.dy + toS.dy) / 2);
          _drawText(
            canvas,
            _sizeLabel(s),
            mid + const Offset(0, -14),
            fontSize: 10,
            color: color,
            fontWeight: FontWeight.w500,
            centered: true,
          );
        }
      }
    }
  }

  void _paintNodes(Canvas canvas) {
    for (final node in network.nodes) {
      final pos = transform.worldToScreen(_worldOf(node));
      canvas.drawCircle(pos, 5, Paint()..color = colors.canvas);
      canvas.drawCircle(pos, 3.5, Paint()..color = colors.textSecondary);
    }
  }

  void _drawArrow(Canvas canvas, Offset tip, bool pointUp, Color color) {
    const h = 6.0;
    const w = 4.0;
    final sign = pointUp ? -1.0 : 1.0;
    final path = Path()
      ..moveTo(tip.dx, tip.dy - sign * h)
      ..lineTo(tip.dx - w, tip.dy)
      ..lineTo(tip.dx + w, tip.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset origin, {
    required double fontSize,
    required Color color,
    FontWeight fontWeight = FontWeight.w400,
    double? maxWidth,
    bool centered = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? 240);
    final dx = centered ? origin.dx - tp.width / 2 : origin.dx;
    tp.paint(canvas, Offset(dx, origin.dy));
  }

  @override
  bool shouldRepaint(_EditSchematicPainter old) =>
      old.network != network ||
      old.sizing != sizing ||
      old.building != building ||
      old.colors != colors ||
      old.transform != transform ||
      old.selectedEdgeId != selectedEdgeId;
}

// ---------------------------------------------------------------------------
// Canvas chrome (banner, zoom controls, help)
// ---------------------------------------------------------------------------

class _Banner extends StatelessWidget {
  final String text;
  const _Banner({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        padding: const EdgeInsets.all(MechXSpacing.md),
        decoration: BoxDecoration(
          color: colors.surface.withAlpha(230),
          borderRadius: MechXRadii.card,
          border: Border.all(color: colors.border),
        ),
        child: Text(text,
            style: context.type.body.copyWith(color: colors.textSecondary)),
      ),
    );
  }
}

class _HelpButton extends StatelessWidget {
  final bool open;
  final VoidCallback onToggle;
  const _HelpButton({required this.open, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MechXFocusRing(
      onActivated: onToggle,
      borderRadius: MechXRadii.rounded,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onToggle,
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: open ? colors.accent : colors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: colors.border),
            ),
            child: Text('?',
                style: context.type.label.copyWith(
                    color:
                        open ? const Color(0xFFFFFFFF) : colors.textSecondary)),
          ),
        ),
      ),
    );
  }
}

class _ElevationHelp extends StatelessWidget {
  final VoidCallback onClose;
  const _ElevationHelp({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final strings = context.strings;
    final items = <String>[
      strings(StringKey.schematicHelpModes),
      strings(StringKey.schematicHelp1),
      strings(StringKey.schematicHelp2),
      strings(StringKey.schematicHelp3),
      strings(StringKey.schematicHelp4),
      strings(StringKey.schematicHelp5),
      strings(StringKey.schematicHelp6),
    ];
    return Container(
      width: 320,
      padding: const EdgeInsets.all(MechXSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
        boxShadow: MechXShadow.popover,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(strings(StringKey.schematicElevationGuide),
                    style: type.subtitle.copyWith(color: colors.textPrimary)),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onClose,
                  child: Text(strings(StringKey.schematicClose),
                      style: type.label.copyWith(color: colors.textMuted)),
                ),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin:
                        const EdgeInsets.only(top: 6, right: MechXSpacing.sm),
                    decoration: BoxDecoration(
                      color: colors.accent,
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                    ),
                  ),
                  Expanded(
                    child: Text(item,
                        style: type.caption
                            .copyWith(color: colors.textSecondary)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
