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
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/sni.dart';

import '../../store/app_state.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../../store/solve_store.dart';
import '../canvas/edge_context_menu.dart';
import '../canvas/segment_symbols.dart';
import '../canvas/service_style.dart';
import '../canvas/viewport.dart';
import '../canvas/zoom_controls.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_focus_ring.dart';
import 'riser_tags.dart';
import 'schematic_export.dart';

// `equipmentDetail` was lifted into the engine (`report/riser_tags.dart`) so
// the riser single-line EXPORT builds the same per-node capacity/duty suffixes
// the canvas draws (B1 export parity); re-exported so existing importers and
// tests keep resolving it from this library.
export 'riser_tags.dart' show equipmentDetail;

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

  /// Auto-view: show the KETERANGAN / legend overlay (services present + codes).
  /// Default OFF — the legend is DRAWING CHROME that rides the export (PDF/DXF),
  /// keeping the live editing canvas uncluttered. Toggle ON to preview it.
  bool _showLegend = false;

  /// Auto-view: show the bottom-right TITLE BLOCK overlay (project name +
  /// adaptive drawing title + date). Default OFF — like the legend, it is export
  /// chrome (it always renders on the exported sheet); toggle ON to preview it.
  bool _showTitleBlock = false;

  /// Whether the Export menu (riser single-line PDF / DXF) is open.
  bool _showExportMenu = false;

  /// Auto-view: draw the H101-style DETAIL callouts — the pump-set / roof-tank
  /// plant detail block + the water-meter / PRV valve-assembly callouts. Default
  /// ON (part of the deliverable) — toggleable from the toolbar.
  bool _showDetails = true;

  /// Auto-view: show the system-NOTES (KETERANGAN) card — feed strategy, the
  /// tank capacities present, occupancy, and the real peak design flow (when a
  /// pump exists). Default ON — toggleable from the toolbar.
  bool _showNotes = true;

  /// Close the export menu and run the chosen export against the live providers
  /// (the file dialog + IO live in `schematic_export.dart`).
  void _runExport(Future<void> Function(WidgetRef, ServiceType?) action) {
    setState(() => _showExportMenu = false);
    action(ref, _autoFocus);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = Column(
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
          showLegend: _showLegend,
          showTitleBlock: _showTitleBlock,
          showDetails: _showDetails,
          showNotes: _showNotes,
          onMode: (m) => setState(() => _mode = m),
          onService: (s) => setState(() => _service = s),
          onAutoFocus: (s) => setState(() => _autoFocus = s),
          onInferRisers: (v) => setState(() => _inferRisers = v),
          onShowLegend: (v) => setState(() => _showLegend = v),
          onTitleBlock: (v) => setState(() => _showTitleBlock = v),
          onShowDetails: (v) => setState(() => _showDetails = v),
          onShowNotes: (v) => setState(() => _showNotes = v),
          onExport: () => setState(() => _showExportMenu = !_showExportMenu),
        ),
        Container(height: 1, color: colors.border),
        Expanded(
          child: _mode == _Mode.edit
              ? _EditElevation(
                  service: _service,
                  showHelp: _showHelp,
                  onToggleHelp: () => setState(() => _showHelp = !_showHelp),
                )
              : _AutoElevation(
                  focus: _autoFocus,
                  inferRisers: _inferRisers,
                  showLegend: _showLegend,
                  showTitleBlock: _showTitleBlock,
                  showDetails: _showDetails,
                  showNotes: _showNotes,
                ),
        ),
      ],
    );

    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: colors.canvas, child: body)),
        // Tap-away scrim behind the open export menu.
        if (_showExportMenu)
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => setState(() => _showExportMenu = false),
              child: const SizedBox.expand(),
            ),
          ),
        if (_showExportMenu)
          Positioned(
            top: 48,
            right: MechXSpacing.md,
            child: _RiserExportMenu(
              onPdf: () => _runExport(exportMechanicalRiserPdf),
              onDxf: () => _runExport(exportMechanicalRiserDxf),
              onSetPdf: () => _runExport(exportMechanicalRiserSetPdf),
              onSetDxf: () => _runExport(exportMechanicalRiserSetDxf),
            ),
          ),
      ],
    );
  }
}

/// The riser single-line Export popover — a vector PDF or DXF of the current
/// (focused) Auto riser diagram, with the KETERANGAN legend + title block on the
/// sheet. Mirrors the electrical `_ExportMenu` look.
class _RiserExportMenu extends StatelessWidget {
  final VoidCallback onPdf;
  final VoidCallback onDxf;
  final VoidCallback onSetPdf;
  final VoidCallback onSetDxf;
  const _RiserExportMenu({
    required this.onPdf,
    required this.onDxf,
    required this.onSetPdf,
    required this.onSetDxf,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(
          scale: 0.95 + 0.05 * t,
          alignment: Alignment.topRight,
          child: child,
        ),
      ),
      child: SizedBox(
        width: 240,
        child: GlassSurface(
          borderRadius: MechXRadii.card,
          blurSigma: MechXGlass.blurSigmaLight,
          shadow: MechXShadow.popover,
          child: Padding(
            padding: const EdgeInsets.all(MechXSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _RiserExportRow(
                  label: context.strings(StringKey.electricalExportSld),
                  sub: context.strings(StringKey.electricalExportSldPdf),
                  onTap: onPdf,
                ),
                _RiserExportRow(
                  label: context.strings(StringKey.electricalExportSld),
                  sub: context.strings(StringKey.electricalExportSldDxf),
                  onTap: onDxf,
                ),
                // The issuable drawing SET — every present service + the
                // combined sheet, numbered `Sheet i of t` (one multi-page PDF /
                // a per-service DXF series).
                _RiserExportRow(
                  label: context.strings(StringKey.mechExportAllSystems),
                  sub: context.strings(StringKey.mechExportAllSystemsPdf),
                  onTap: onSetPdf,
                ),
                _RiserExportRow(
                  label: context.strings(StringKey.mechExportAllSystems),
                  sub: context.strings(StringKey.mechExportAllSystemsDxf),
                  onTap: onSetDxf,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RiserExportRow extends StatelessWidget {
  final String label;
  final String sub;
  final VoidCallback onTap;
  const _RiserExportRow(
      {required this.label, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm, vertical: MechXSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: type.body.copyWith(color: colors.textPrimary)),
            ),
            Text(sub, style: type.caption.copyWith(color: colors.textMuted)),
          ],
        ),
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
  final bool showLegend;
  final bool showTitleBlock;
  final bool showDetails;
  final bool showNotes;
  final ValueChanged<_Mode> onMode;
  final ValueChanged<ServiceType> onService;
  final ValueChanged<ServiceType?> onAutoFocus;
  final ValueChanged<bool> onInferRisers;
  final ValueChanged<bool> onShowLegend;
  final ValueChanged<bool> onTitleBlock;
  final ValueChanged<bool> onShowDetails;
  final ValueChanged<bool> onShowNotes;
  final VoidCallback onExport;

  const _Toolbar({
    required this.mode,
    required this.service,
    required this.autoFocus,
    required this.presentServices,
    required this.inferRisers,
    required this.showLegend,
    required this.showTitleBlock,
    required this.showDetails,
    required this.showNotes,
    required this.onMode,
    required this.onService,
    required this.onAutoFocus,
    required this.onInferRisers,
    required this.onShowLegend,
    required this.onTitleBlock,
    required this.onShowDetails,
    required this.onShowNotes,
    required this.onExport,
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
                    const SizedBox(width: MechXSpacing.xs),
                    _TabButton(
                      label: context.strings(StringKey.schematicLegend),
                      selected: showLegend,
                      onTap: () => onShowLegend(!showLegend),
                    ),
                    const SizedBox(width: MechXSpacing.xs),
                    _TabButton(
                      label: context.strings(StringKey.schematicTitleBlock),
                      selected: showTitleBlock,
                      onTap: () => onTitleBlock(!showTitleBlock),
                    ),
                    const SizedBox(width: MechXSpacing.xs),
                    _TabButton(
                      label: context.strings(StringKey.schematicDetails),
                      selected: showDetails,
                      onTap: () => onShowDetails(!showDetails),
                    ),
                    const SizedBox(width: MechXSpacing.xs),
                    _TabButton(
                      label: context.strings(StringKey.schematicNotes),
                      selected: showNotes,
                      onTap: () => onShowNotes(!showNotes),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: MechXSpacing.sm),
            Container(width: 1, height: 22, color: colors.border),
            const SizedBox(width: MechXSpacing.sm),
            _TabButton(
              label: 'Export',
              selected: false,
              onTap: onExport,
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
  final bool showLegend;
  final bool showTitleBlock;
  final bool showDetails;
  final bool showNotes;
  const _AutoElevation({
    this.focus,
    this.inferRisers = false,
    this.showLegend = true,
    this.showTitleBlock = true,
    this.showDetails = true,
    this.showNotes = true,
  });

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
        final feedStrategy = ref.watch(feedStrategyProvider);
        // Resolve the equipment detail suffix per node (tank m3 / pump-fan kW)
        // here, provider-free in the painter — a datum is included only when it
        // genuinely exists (equipmentDetail returns null otherwise).
        final pump = ref.watch(pumpDutyProvider);
        final fan = ref.watch(ductFanProvider);
        final detailByNode = <String, String>{
          for (final node in network.nodes)
            node.id: ?equipmentDetail(node, supplyPump: pump, fan: fan),
        };
        final paint = CustomPaint(
          size: _size,
          painter: _AutoSchematicPainter(
            network: network,
            sizing: sizing,
            building: building,
            colors: colors,
            focus: widget.focus,
            inferRisers: widget.inferRisers,
            downfeed: feedStrategy == FeedStrategy.downfeed,
            riserTagsById: riserTags(network, widget.focus),
            detailByNode: detailByNode,
            supplyPump: pump,
            showDetails: widget.showDetails,
          ),
        );
        // Read-only unless inferred risers are shown — then the dashed
        // connectors become CLICKABLE: one tap commits a real sized riser.
        final Widget body = !widget.inferRisers
            ? paint
            : MouseRegion(
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
        // The KETERANGAN / legend overlay sits bottom-left (clear of where the
        // Edit view parks its ZoomControls — the Auto view has none today), a
        // floating-chrome card that lists the services actually drawn.
        return Stack(
          children: [
            Positioned.fill(child: body),
            if (widget.showLegend)
              Positioned(
                left: MechXSpacing.md,
                bottom: MechXSpacing.md,
                child: _AutoLegend(network: network, focus: widget.focus),
              ),
            // The system-NOTES (KETERANGAN) card + the title block both sit
            // bottom-RIGHT, STACKED vertically (notes above the title block) so
            // they never overlap — clear of the bottom-left legend.
            if (widget.showNotes || widget.showTitleBlock)
              Positioned(
                right: MechXSpacing.md,
                bottom: MechXSpacing.md,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (widget.showNotes)
                      _SystemNotes(focus: widget.focus, network: network),
                    if (widget.showNotes && widget.showTitleBlock)
                      const SizedBox(height: MechXSpacing.sm),
                    if (widget.showTitleBlock) _TitleBlock(focus: widget.focus),
                  ],
                ),
              ),
          ],
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

/// Industry single-line pipe tag — `SIZE-SERVICE-MATERIAL` (e.g. `100-CW-PPR`,
/// matching Indonesian air-bersih riser drawings). Air uses the ASCII duct
/// `O<mm>` form (the same stand-in the export/PDF path uses — one drawing must
/// not mix two notations). When a [function] is confidently derived
/// (riserFunctionFor), a `-GRAVITASI` / `-BOOSTER` / `-TRANSFER` suffix is
/// appended (piped services only).
String _pipeTag(EdgeSizing s, NetEdge edge, {RiserFunction? function}) {
  final mm = s.diameter.inMillimeters.round();
  if (s.service.regime == FlowRegime.air) return 'O$mm';
  final base = '$mm-${_serviceCode(edge.service)}-'
      '${_pipeMaterialCode(edge.pipeProduct, edge.service)}';
  return function != null ? '$base-${function.code}' : base;
}

/// Two-letter service code used on the single-line (CW = air bersih, etc.).
/// Delegates to the shared [riserServiceCode] so both files share one mapping.
String _serviceCode(ServiceType s) => riserServiceCode(s);

/// The title-block DRAWING TITLE [StringKey] for the active Auto-view system
/// [focus]: a per-service riser title (clean / hot water, drainage, vent, storm,
/// air, fire) when one system is filtered, else the generic single-line title.
///
/// Returns a [StringKey] (not a localized string) so it is locale-independent
/// and unit-testable; the widget localizes it. The mapping is TOTAL — every
/// [ServiceType] plus null is covered, so the title is always a deterministic
/// lookup, never a fabricated/guessed value.
StringKey drawingTitleKey(ServiceType? focus) {
  if (focus == null) return StringKey.schematicTitleSingleLine;
  return switch (focus) {
    ServiceType.coldWater => StringKey.schematicTitleCleanWaterRiser,
    ServiceType.hotWater => StringKey.schematicTitleHotWaterRiser,
    ServiceType.drainage => StringKey.schematicTitleDrainageRiser,
    ServiceType.vent => StringKey.schematicTitleVentRiser,
    ServiceType.rainwater => StringKey.schematicTitleStormRiser,
    ServiceType.duct ||
    ServiceType.returnAir ||
    ServiceType.exhaust =>
      StringKey.schematicTitleAirRiser,
    ServiceType.fireSprinkler ||
    ServiceType.fireHydrant =>
      StringKey.schematicTitleFireRiser,
  };
}

/// Pipe material code — the edge's chosen product, else the conventional
/// default for the service (clean/hot water ⇒ PPR, drainage/vent/storm ⇒ PVC,
/// fire ⇒ black steel) so the tag always reads like a real drawing.
String _pipeMaterialCode(PipeProduct? p, ServiceType s) {
  if (p != null) {
    return switch (p) {
      PipeProduct.pprPn10 ||
      PipeProduct.pprPn16 ||
      PipeProduct.pprPn20 =>
        'PPR',
      PipeProduct.pvcAw || PipeProduct.pvcD || PipeProduct.pvcJis => 'PVC',
      PipeProduct.acousticPvc => 'PVC',
      PipeProduct.castIron => 'CI',
      PipeProduct.hdpe => 'HDPE',
    };
  }
  return switch (s) {
    ServiceType.coldWater || ServiceType.hotWater => 'PPR',
    ServiceType.drainage ||
    ServiceType.vent ||
    ServiceType.rainwater =>
      'PVC',
    ServiceType.fireSprinkler || ServiceType.fireHydrant => 'BS',
    _ => 'GI',
  };
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
/// the bottom), nodes placed left→right by the SHARED [riserLayoutPositions]
/// column layout (B7) — a normalized x in [0,1] mapped into the drawing band —
/// so a vertical riser stack reads as one column both here and in the exported
/// sheet (the export consumes the same helper), instead of the two jogging
/// apart. A single column (all nodes aligned, or one node) centres at 0.5.
Map<String, Offset> _autoNodePositions(
    Network network, int levelCount, Size size,
    {ServiceType? focus}) {
  final n = levelCount.clamp(1, 999999);
  double bandCentreY(int floorIndex) {
    final bandH = size.height / n;
    return bandH * ((n - 1) - floorIndex) + bandH / 2;
  }

  final norm = riserLayoutPositions(network, focus: focus);
  final drawWidth = size.width - 2 * _kAutoSidePad;
  final positions = <String, Offset>{};
  for (final entry in norm.entries) {
    final node = network.nodeById(entry.key);
    if (node == null) continue;
    positions[entry.key] = Offset(
      _kAutoSidePad + entry.value * drawWidth,
      bandCentreY(node.floorIndex),
    );
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
    this.downfeed = false,
    this.riserTagsById = const {},
    this.detailByNode = const {},
    this.supplyPump,
    this.showDetails = true,
  });

  final Network network;
  final Map<String, EdgeSizing> sizing;
  final BuildingLevels building;
  final MechXColors colors;

  /// The system supply-pump duty (one trunk pump) — used for the plant-detail
  /// callout's BOOSTER PUMP kW caption. Null ⇒ no kW caption (no fabricated duty).
  final PumpDuty? supplyPump;

  /// Draw the H101-style DETAIL callouts (plant detail + valve assemblies) and
  /// the per-floor branch fan-out. Toolbar-toggleable, default on.
  final bool showDetails;

  /// When non-null, the single-line is filtered to ONE system (cold/hot water,
  /// drainage, vent, rainwater, air, fire …); null shows the COMBINED riser.
  final ServiceType? focus;

  /// When true, draw DASHED inferred risers connecting floors that share a
  /// service but have no DRAWN riser between them (a convenience overlay — the
  /// engineer hasn't routed the vertical, so it's shown dashed + flagged).
  final bool inferRisers;

  /// Project feed strategy — true for roof-tank downfeed, false for upfeed.
  /// Threaded into the pipe-tag FUNCTION-suffix heuristic (riserFunctionFor).
  final bool downfeed;

  /// Per-edge riser tag (`CW-R1` …) for every riser edge, drawn boxed near the
  /// riser top. Computed once in the widget via [riserTags].
  final Map<String, String> riserTagsById;

  /// Per-node equipment detail suffix (capacity `237 m3` / duty `5.5 kW`),
  /// appended to the node's name. Resolved provider-free in the widget via
  /// [equipmentDetail]; absent nodes keep their plain name.
  final Map<String, String> detailByNode;

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
    if (showDetails) {
      _paintFloorFanOut(canvas, size);
      _paintPlantDetail(canvas, size);
      _paintValveCallouts(canvas, size);
      _paintStackDetails(canvas, size, nodePos);
    }
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

      // FUNCTION suffix — appended only when confidently derivable (else null).
      final fn = riserFunctionFor(network, edge, downfeed: downfeed);

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
            _pipeTag(s, edge, function: fn),
            Offset(midX + MechXSpacing.xs, arrowY - MechXSpacing.sm),
            fontSize: _labelFontSize,
            color: color,
            fontWeight: FontWeight.w500,
          );
        }

        // A small boxed riser tag (CW-R1 …) near the riser TOP.
        final tag = riserTagsById[edge.id];
        if (tag != null) {
          final topY = math.min(from.dy, to.dy);
          _drawBoxedTag(
            canvas,
            tag,
            Offset(midX, topY + MechXSpacing.sm + 3),
            color,
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
            _pipeTag(s, edge, function: fn),
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

  /// A compact boxed tag (rounded rect, service-colour outline over a canvas
  /// halo fill) centred on [anchor] — used for the riser tags (CW-R1 …).
  void _drawBoxedTag(Canvas canvas, String text, Offset anchor, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    const padX = 4.0;
    const padY = 2.0;
    final rect = Rect.fromCenter(
      center: anchor,
      width: tp.width + padX * 2,
      height: tp.height + padY * 2,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(3));
    canvas.drawRRect(rrect, Paint()..color = colors.canvas);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    tp.paint(
        canvas, Offset(anchor.dx - tp.width / 2, anchor.dy - tp.height / 2));
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

      // Fixture / equipment label, centred just below the symbol. When the node
      // carries an equipment detail (capacity / duty), append it after a '·'
      // (e.g. 'Roof tank · 237 m3', 'Booster set · 5.5 kW').
      final label = node == null ? null : _nodeLabel(node);
      if (label != null) {
        final detail = node == null ? null : detailByNode[node.id];
        final text = detail != null ? '$label · $detail' : label;
        _drawText(
          canvas,
          text,
          Offset(pos.dx, pos.dy + 13),
          fontSize: 9,
          color: colors.textMuted,
          fontWeight: FontWeight.w500,
          centered: true,
          maxWidth: 130,
        );
      }
    }
  }

  // ── H101 DETAIL CALLOUTS ────────────────────────────────────────────────────

  /// A consistent drafting DETAIL box: a rounded rect (border over a canvas
  /// fill) with a small title row across the top.
  void _detailBox(Canvas canvas, Rect rect, String title,
      {required Color titleColor}) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(rrect, Paint()..color = colors.canvas);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = colors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    _drawText(
      canvas,
      title,
      Offset(rect.left + 6, rect.top + 4),
      fontSize: 9,
      color: titleColor,
      fontWeight: FontWeight.w600,
      maxWidth: rect.width - 12,
    );
  }

  /// Lay out a left→right row of schematic valve/meter glyphs joined by a thin
  /// run line, each with a tiny ASCII abbrev beneath it. Glyphs are schematic —
  /// the abbrev names the real device.
  void _drawDetailGlyphRow(
    Canvas canvas,
    Offset origin,
    List<(NodeComponent, String)> items,
    Color color, {
    double glyph = 16.0,
    double gap = 26.0,
  }) {
    if (items.isEmpty) return;
    final cy = origin.dy + glyph / 2;
    // The connecting run line spans the centres of the first and last glyph.
    final firstCx = origin.dx + glyph / 2;
    final lastCx = origin.dx + glyph / 2 + (items.length - 1) * gap;
    canvas.drawLine(
      Offset(firstCx - glyph / 2, cy),
      Offset(lastCx + glyph / 2, cy),
      Paint()
        ..color = color
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
    for (var i = 0; i < items.length; i++) {
      final (component, abbrev) = items[i];
      final left = origin.dx + i * gap;
      // Halo so the glyph reads over the run line.
      canvas.drawCircle(
          Offset(left + glyph / 2, cy), glyph * 0.62, Paint()..color = colors.canvas);
      canvas.save();
      canvas.translate(left, origin.dy);
      paintComponentSymbol(canvas, Size(glyph, glyph), component, color);
      canvas.restore();
      _drawText(
        canvas,
        abbrev,
        Offset(left + glyph / 2, origin.dy + glyph + 1),
        fontSize: 8,
        color: colors.textMuted,
        fontWeight: FontWeight.w500,
        centered: true,
      );
    }
  }

  /// Whether a non-air (clean-water) detail should draw for the active focus.
  /// The plant/valve details are a clean-water convention: shown for the
  /// combined view or a water filter, omitted when an air/fire/etc. system is
  /// filtered.
  bool get _waterFocus =>
      focus == null ||
      focus == ServiceType.coldWater ||
      focus == ServiceType.hotWater;

  /// Capacity (m3, ASCII) of the first node with [component], or null.
  String? _tankM3(NodeComponent component) {
    for (final n in network.nodes) {
      if (n.component != component) continue;
      final litres = n.tankCapacityLitres;
      if (litres == null || litres <= 0) continue;
      final m3 = litres / 1000.0;
      final s = m3 >= 100 ? m3.toStringAsFixed(0) : m3.toStringAsFixed(1);
      return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    }
    return null;
  }

  bool _hasComponent(NodeComponent component) =>
      network.nodes.any((n) => n.component == component);

  /// (1) PUMP-SET / ROOF-TANK PLANT DETAIL — a compact bordered callout in the
  /// TOP-RIGHT (H101 convention): a roof-tank glyph + capacity, a booster-pump
  /// glyph + duty, and the GRAVITASI / TRANSFER / BOOSTER leg labels. Drawn only
  /// when the network actually has a roof-tank / ground-tank / pump / booster set
  /// (else omitted entirely — honesty), and only on the clean-water view.
  void _paintPlantDetail(Canvas canvas, Size size) {
    if (!_waterFocus) return;
    final hasRoof = _hasComponent(NodeComponent.roofTank);
    final hasGround = _hasComponent(NodeComponent.groundTank);
    final hasPump = _hasComponent(NodeComponent.pump) ||
        _hasComponent(NodeComponent.boosterSet);
    if (!hasRoof && !hasGround && !hasPump) return;

    final color = serviceColor(ServiceType.coldWater);
    const boxW = 210.0;
    const boxH = 120.0;
    const pad = MechXSpacing.md;
    // Guard a too-narrow / too-short viewport.
    if (size.width < boxW + 2 * pad || size.height < boxH + 2 * pad) return;
    final rect =
        Rect.fromLTWH(size.width - boxW - pad, pad, boxW, boxH);
    _detailBox(canvas, rect, 'PUMP-SET DETAIL', titleColor: colors.textMuted);

    const glyph = 22.0;
    final leftX = rect.left + 14;
    var y = rect.top + 22;

    // ROOF TANK row.
    if (hasRoof) {
      canvas.save();
      canvas.translate(leftX, y);
      paintComponentSymbol(
          canvas, const Size(glyph, glyph), NodeComponent.roofTank, color);
      canvas.restore();
      final m3 = _tankM3(NodeComponent.roofTank);
      _drawText(
        canvas,
        m3 != null ? 'ROOF TANK $m3 m3' : 'ROOF TANK',
        Offset(leftX + glyph + 8, y + glyph / 2 - 6),
        fontSize: 9,
        color: colors.textSecondary,
        fontWeight: FontWeight.w500,
        maxWidth: boxW - (glyph + 28),
      );
      // GRAVITASI leg label on the down-leg below the roof tank (downfeed feed).
      if (downfeed) {
        _drawText(
          canvas,
          'GRAVITASI',
          Offset(leftX + glyph / 2 + 4, y + glyph + 1),
          fontSize: 8,
          color: color,
          fontWeight: FontWeight.w600,
        );
      }
      y += glyph + 18;
    }

    // A short vertical connecting leg down to the pump (when both present).
    if (hasRoof && hasPump) {
      canvas.drawLine(
        Offset(leftX + glyph / 2, rect.top + 22 + glyph),
        Offset(leftX + glyph / 2, y),
        Paint()
          ..color = color
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }

    // BOOSTER PUMP row.
    if (hasPump) {
      final pumpC = _hasComponent(NodeComponent.boosterSet)
          ? NodeComponent.boosterSet
          : NodeComponent.pump;
      canvas.save();
      canvas.translate(leftX, y);
      paintComponentSymbol(canvas, const Size(glyph, glyph), pumpC, color);
      canvas.restore();
      final kw = supplyPump != null
          ? '${supplyPump!.selectedMotor.inKiloWatts.toStringAsFixed(1)} kW'
          : null;
      _drawText(
        canvas,
        kw != null ? 'BOOSTER PUMP $kw' : 'BOOSTER PUMP',
        Offset(leftX + glyph + 8, y + glyph / 2 - 6),
        fontSize: 9,
        color: colors.textSecondary,
        fontWeight: FontWeight.w500,
        maxWidth: boxW - (glyph + 28),
      );
      // TRANSFER (ground -> roof lift) when a ground tank exists; else BOOSTER
      // (pump-up) on upfeed.
      final leg = hasGround ? 'TRANSFER' : (!downfeed ? 'BOOSTER' : null);
      if (leg != null) {
        _drawText(
          canvas,
          leg,
          Offset(leftX + glyph / 2 + 4, y + glyph + 1),
          fontSize: 8,
          color: color,
          fontWeight: FontWeight.w600,
        );
      }
    }
  }

  /// (2) VALVE-ASSEMBLY CALLOUTS — a row of two compact bordered detail boxes at
  /// the BOTTOM-CENTRE (clear of the bottom-left legend + bottom-right title /
  /// notes): a WATER METER set and a PRV set. Generic reference details (always
  /// drawn when Details is on), each a row of valve glyphs + ASCII abbrevs. The
  /// glyph is schematic; the abbrev names the real device (no exact-glyph claim).
  void _paintValveCallouts(Canvas canvas, Size size) {
    if (!_waterFocus) return;
    final color = serviceColor(ServiceType.coldWater);
    const boxW = 156.0;
    const boxH = 64.0;
    const gapBetween = MechXSpacing.md;
    final totalW = boxW * 2 + gapBetween;
    // Width guard: only draw when there's room clear of the corner overlays.
    if (size.width < totalW + 320 || size.height < boxH + 2 * MechXSpacing.md) {
      return;
    }
    final left = (size.width - totalW) / 2;
    final top = size.height - boxH - MechXSpacing.md;

    // Box A — DETAIL WATER METER.
    final rectA = Rect.fromLTWH(left, top, boxW, boxH);
    _detailBox(canvas, rectA, 'DETAIL WATER METER', titleColor: color);
    _drawDetailGlyphRow(
      canvas,
      Offset(rectA.left + 12, rectA.top + 24),
      const [
        (NodeComponent.gateValve, 'GV'),
        (NodeComponent.waterMeter, 'WM'),
        (NodeComponent.gateValve, 'GV'),
        (NodeComponent.gateValve, 'U'),
      ],
      color,
      glyph: 15,
      gap: 32,
    );

    // Box B — DETAIL PRV SET.
    final rectB = Rect.fromLTWH(left + boxW + gapBetween, top, boxW, boxH);
    _detailBox(canvas, rectB, 'DETAIL PRV SET', titleColor: color);
    _drawDetailGlyphRow(
      canvas,
      Offset(rectB.left + 8, rectB.top + 24),
      const [
        (NodeComponent.gateValve, 'GV'),
        (NodeComponent.strainer, 'STR'),
        (NodeComponent.prv, 'PRV'),
        (NodeComponent.gateValve, 'GV'),
      ],
      color,
      glyph: 15,
      gap: 32,
    );
  }

  /// (B2) STACK DETAIL — the drainage/vent riser conventions, all data-gated on
  /// the DRAWN network (never a fabricated cleanout / vent):
  ///   • a `CO` tag beside each cleanout that actually serves a drainage stack
  ///     base (the missing-cleanout case is a Review ADVISORY instead);
  ///   • a short tee bar where a vent riser ties into the soil stack;
  ///   • a VTR (vent-through-roof) stub + label where a vent riser reaches the
  ///     top floor.
  /// Mirrors the export builder's stack details (one convention, two renders).
  void _paintStackDetails(
      Canvas canvas, Size size, Map<String, Offset> nodePos) {
    final ventColor = serviceColor(ServiceType.vent);
    final drainColor = serviceColor(ServiceType.drainage);
    if (focus == null || focus == ServiceType.vent) {
      final topFloor = building.levelCount - 1;
      for (final id in ventTopTerminalIds(network, topFloor: topFloor)) {
        final p = nodePos[id];
        if (p == null) continue;
        final stubTop = Offset(p.dx, p.dy - 34);
        final paint = Paint()
          ..color = ventColor
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        canvas.drawLine(Offset(p.dx, p.dy - 10), stubTop, paint);
        // Roof-penetration cap tick.
        canvas.drawLine(Offset(p.dx - 4, stubTop.dy),
            Offset(p.dx + 4, stubTop.dy), paint);
        _drawText(
          canvas,
          'VTR',
          Offset(p.dx + 6, stubTop.dy - 4),
          fontSize: 9,
          color: ventColor,
          fontWeight: FontWeight.w600,
        );
      }
    }
    if (focus == null ||
        focus == ServiceType.vent ||
        focus == ServiceType.drainage) {
      for (final id in ventSoilTeeNodeIds(network)) {
        final p = nodePos[id];
        if (p == null) continue;
        canvas.drawLine(
          Offset(p.dx - 9, p.dy),
          Offset(p.dx + 9, p.dy),
          Paint()
            ..color = drainColor
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
    }
    if (focus == null || focus == ServiceType.drainage) {
      for (final id in cleanoutAtStackBaseIds(network)) {
        final p = nodePos[id];
        if (p == null) continue;
        _drawText(
          canvas,
          'CO',
          Offset(p.dx - 22, p.dy - 18),
          fontSize: 9,
          color: drainColor,
          fontWeight: FontWeight.w600,
        );
      }
    }
  }

  /// (5) PER-FLOOR BRANCH FAN-OUT — under each floor band, a compact column of
  /// short labelled stubs for the FIXTURES/terminals that floor distributes,
  /// capped at 4 with a `+N more` row (the cap is surfaced by [floorFanOuts], not
  /// silently dropped). Anchored in the band's left gutter, below the FFL label,
  /// honouring the focus filter.
  void _paintFloorFanOut(Canvas canvas, Size size) {
    final visible = _focusedNodeIds(network, focus);
    final fans = floorFanOuts(
      network,
      visibleNodeIds: visible,
      labelOf: (n) => _nodeLabel(n) ?? 'Fixture',
    );
    if (fans.isEmpty) return;
    final n = building.levelCount;
    final bandH = size.height / n;
    const stubX = MechXSpacing.sm;
    const rowPitch = 11.0;
    const gutterW = 150.0;
    for (final fan in fans) {
      if (fan.floorIndex < 0 || fan.floorIndex >= n) continue;
      final top = _bandTopY(fan.floorIndex, size.height);
      // Start below the FFL label (which sits at top + xs, ~12px tall).
      var y = top + 20;
      final color =
          focus != null ? serviceColor(focus!) : colors.textSecondary;
      for (final label in fan.labels) {
        if (y + rowPitch > top + bandH) break; // never overrun the band.
        // A tiny tick + the fixture short-name.
        canvas.drawLine(
          Offset(stubX, y + 4),
          Offset(stubX + 6, y + 4),
          Paint()
            ..color = color
            ..strokeWidth = 1.2
            ..style = PaintingStyle.stroke,
        );
        _drawText(
          canvas,
          label,
          Offset(stubX + 10, y),
          fontSize: 9,
          color: colors.textMuted,
          fontWeight: FontWeight.w400,
          maxWidth: gutterW,
        );
        y += rowPitch;
      }
      if (fan.overflow > 0 && y + rowPitch <= top + bandH) {
        _drawText(
          canvas,
          '+${fan.overflow} more',
          Offset(stubX + 10, y),
          fontSize: 9,
          color: colors.textMuted,
          fontWeight: FontWeight.w500,
          maxWidth: gutterW,
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
      old.inferRisers != inferRisers ||
      old.downfeed != downfeed ||
      old.riserTagsById != riserTagsById ||
      old.detailByNode != detailByNode ||
      old.supplyPump != supplyPump ||
      old.showDetails != showDetails;
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
      final isRiser = edge.kind == EdgeKind.riser;

      // A riser routes as the same orthogonal L-shape the Auto painter uses
      // (horizontal at the from-y, vertical at the mid-x, horizontal to the
      // to-x) so a riser joining two nodes at different x reads as a clean
      // vertical, not a diagonal (B6). Runs stay straight.
      final midX = (fromS.dx + toS.dx) / 2;
      Path riserPath() => Path()
        ..moveTo(fromS.dx, fromS.dy)
        ..lineTo(midX, fromS.dy)
        ..lineTo(midX, toS.dy)
        ..lineTo(toS.dx, toS.dy);

      if (selected) {
        // Selection halo behind the line — a soft, blurred glow so the
        // selection 'floats' (Apple-soft) rather than reading as a hard band.
        final halo = Paint()
          ..color = colors.accent.withAlpha(64)
          ..strokeWidth = 7
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
        if (isRiser) {
          canvas.drawPath(riserPath(), halo);
        } else {
          canvas.drawLine(fromS, toS, halo);
        }
      }

      final stroke = (isRiser ? 2.5 : 2.0) * (selected ? 1.3 : 1.0);
      final linePaint = Paint()
        ..color = color
        ..strokeWidth = stroke
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      if (isRiser) {
        canvas.drawPath(riserPath(), linePaint);
        final goingUp = toS.dy < fromS.dy;
        final arrowY = (fromS.dy + toS.dy) / 2;
        final mid = Offset(midX, arrowY);
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
        canvas.drawLine(fromS, toS, linePaint);
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

  /// A representative colour for [node]: the service of any edge touching it
  /// (Edit shows every service — no focus), else neutral. Mirrors the Auto
  /// painter's combined-view `_nodeColor`.
  Color _nodeColor(NetNode node) {
    for (final e in network.edges) {
      if (e.fromId == node.id || e.toId == node.id) {
        return serviceColor(e.service);
      }
    }
    return colors.textSecondary;
  }

  /// A human label for [node] — its equipment name or fixture type — or null for
  /// a plain junction. Mirrors the Auto painter.
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

  /// Nodes carry their schematic symbol (equipment glyph / fixture drop-triangle
  /// / plain junction) + a label — reusing the Auto painter's treatment (B6), so
  /// the Edit surface reads like an engineered riser rather than anonymous dots.
  void _paintNodes(Canvas canvas) {
    const box = 20.0;
    for (final node in network.nodes) {
      final pos = transform.worldToScreen(_worldOf(node));
      final color = _nodeColor(node);

      if (node.component != null) {
        // A halo so the glyph reads over the run line, then the equipment glyph.
        canvas.drawCircle(pos, box * 0.62, Paint()..color = colors.canvas);
        canvas.save();
        canvas.translate(pos.dx - box / 2, pos.dy - box / 2);
        paintComponentSymbol(
            canvas, const Size(box, box), node.component!, color);
        canvas.restore();
      } else if (node.role == NodeRole.fixture) {
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
        canvas.drawCircle(pos, 5.5, Paint()..color = colors.canvas);
        canvas.drawCircle(pos, 4, Paint()..color = color);
      }

      final label = _nodeLabel(node);
      if (label != null) {
        _drawText(
          canvas,
          label,
          Offset(pos.dx, pos.dy + 13),
          fontSize: 9,
          color: colors.textMuted,
          fontWeight: FontWeight.w500,
          centered: true,
          maxWidth: 130,
        );
      }
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

/// The KETERANGAN / legend overlay for the Auto single-line: a floating-glass
/// card listing the services actually drawn (colour swatch + code + full name).
/// It is a pure render of [network] + [focus] — no clock, no engine call, no
/// derived value (every swatch/code/name is a fixed lookup for an enum that is
/// genuinely present in the drawing). When a system [focus] is active it
/// collapses to exactly that one service (and only if still present). Renders
/// nothing when no service has any edge.
class _AutoLegend extends StatelessWidget {
  final Network network;
  final ServiceType? focus;
  const _AutoLegend({required this.network, required this.focus});

  /// The H101 fitting / valve abbreviations — reference detail, ASCII-only, not
  /// data-gated (always listed when the legend is shown).
  static const List<(String, String)> _fittings = [
    ('CW', 'Air bersih'),
    ('AAV', 'Auto air vent'),
    ('GV', 'Gate valve'),
    ('CV', 'Check valve'),
    ('STR', 'Strainer'),
    ('PRV', 'Pressure reducing'),
    ('WM', 'Water meter'),
    ('SF', 'Sand filter'),
    ('CF', 'Carbon filter'),
    ('BV', 'Butterfly valve'),
    ('FJ', 'Flexible joint'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final present = focus != null
        ? <ServiceType>[
            if (network.edges.any((e) => e.service == focus)) focus!,
          ]
        : <ServiceType>[
            for (final s in ServiceType.values)
              if (network.edges.any((e) => e.service == s)) s,
          ];
    if (present.isEmpty) return const SizedBox.shrink();
    return GlassSurface(
      borderRadius: MechXRadii.card,
      shadow: MechXShadow.popover,
      edge: Border.all(color: colors.glassEdge),
      child: Padding(
        padding: const EdgeInsets.all(MechXSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.strings(StringKey.schematicLegend),
              style: type.caption.copyWith(
                  color: colors.textMuted, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: MechXSpacing.xs),
            for (final s in present)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: serviceColor(s), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: MechXSpacing.sm),
                    Text(
                      _serviceCode(s),
                      style: type.caption.copyWith(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'Roboto'),
                    ),
                    const SizedBox(width: MechXSpacing.xs),
                    Text(
                      serviceLabel(s),
                      style: type.caption.copyWith(
                          color: colors.textSecondary, fontFamily: 'Roboto'),
                    ),
                  ],
                ),
              ),
            // The H101 fitting/valve abbreviation key — a reference subsection
            // beneath the service codes.
            const SizedBox(height: MechXSpacing.xs),
            Container(height: 1, width: 120, color: colors.border),
            const SizedBox(height: MechXSpacing.xs),
            Text(
              'FITTINGS',
              style: type.caption.copyWith(
                  color: colors.textMuted,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Roboto'),
            ),
            const SizedBox(height: 2),
            for (final (abbr, full) in _fittings)
              Padding(
                padding: const EdgeInsets.only(bottom: 1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 30,
                      child: Text(
                        abbr,
                        style: type.caption.copyWith(
                            color: colors.textSecondary,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'Roboto'),
                      ),
                    ),
                    Text(
                      full,
                      style: type.caption.copyWith(
                          color: colors.textSecondary, fontFamily: 'Roboto'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The bottom-right TITLE BLOCK overlay for the Auto single-line — a compact
/// floating-glass card echoing a real drawing's kop gambar: the project NAME, an
/// adaptive DRAWING TITLE (per the active system [focus] via [drawingTitleKey]),
/// the DATE, and a sheet/system line.
///
/// HONESTY: the project name always exists (defaults to 'Untitled project') and
/// is never fabricated; the drawing title is a deterministic, total lookup over
/// [focus] (never guessed); the DATE is read in the WIDGET (DateTime.now()),
/// NEVER in a painter/engine — it is a real machine date, not a heuristic. The
/// sheet/system line shows a fixed lead-in + the focused service (or 'All') and
/// deliberately does NOT invent a sheet number. Only ever rendered when a
/// project/network exists (the parent early-returns 'No network' otherwise).
class _TitleBlock extends ConsumerWidget {
  final ServiceType? focus;
  const _TitleBlock({required this.focus});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final name = ref.watch(projectControllerProvider).name;
    // The DATE is read here in the widget (yyyy-MM-dd) — NEVER in the painter or
    // engine (no clock in either). A real machine date, so no // VERIFY.
    final now = DateTime.now();
    final date = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final title = context.strings(drawingTitleKey(focus));
    // VERIFY: a real sheet number / revision is not plumbed into the Auto view,
    // so the sheet line stays generic ('SHEET · <system>') rather than
    // fabricating a 'X of Y' count (matches DrawingChrome's deferred number).
    final sheetLine = '${context.strings(StringKey.schematicTitleSheet)} · '
        '${focus == null ? context.strings(StringKey.schematicSystemAll) : serviceLabel(focus!)}';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: GlassSurface(
        borderRadius: MechXRadii.card,
        shadow: MechXShadow.popover,
        edge: Border.all(color: colors.glassEdge),
        child: Padding(
          padding: const EdgeInsets.all(MechXSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.label.copyWith(
                      color: colors.textPrimary, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: MechXSpacing.xs),
              Container(height: 1, width: 220, color: colors.border),
              const SizedBox(height: MechXSpacing.xs),
              Text(
                title,
                style: type.caption.copyWith(
                    color: colors.textSecondary, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                sheetLine,
                style: type.caption.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: 2),
              Text(
                date,
                style: type.caption.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The system-NOTES (KETERANGAN) card for the Auto single-line — a compact
/// floating-glass card that echoes the project inputs that actually exist:
///   • the FEED strategy (gravity downfeed vs upfeed / booster);
///   • each TANK present, with its real capacity (m3, from the node);
///   • the OCCUPANCY class; and
///   • the PEAK design flow (L/s) — shown ONLY when a supply pump was sized
///     (upfeed). There is no daily-volume (m3/day) figure in the engine, so on a
///     downfeed project the demand line is OMITTED rather than fabricated.
///
/// HONESTY: every line is a direct echo of a real provider / node value. A datum
/// that doesn't exist (no tank, no pump on downfeed) is simply not drawn. Only
/// rendered when a network exists (the parent early-returns 'No network').
class _SystemNotes extends ConsumerWidget {
  final ServiceType? focus;
  final Network network;
  const _SystemNotes({required this.focus, required this.network});

  String _occupancyLabel(Occupancy o) => switch (o) {
        Occupancy.private => 'Private',
        Occupancy.public => 'Public',
        Occupancy.assembly => 'Assembly',
      };

  /// Capacity (m3, ASCII) of the first node with [component] with a stored
  /// capacity, or null.
  String? _tankM3(NodeComponent component) {
    for (final n in network.nodes) {
      if (n.component != component) continue;
      final litres = n.tankCapacityLitres;
      if (litres == null || litres <= 0) continue;
      final m3 = litres / 1000.0;
      final s = m3 >= 100 ? m3.toStringAsFixed(0) : m3.toStringAsFixed(1);
      return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final feed = ref.watch(feedStrategyProvider);
    final occupancy = ref.watch(occupancyProvider);
    final pump = ref.watch(pumpDutyProvider);

    final lines = <String>[
      feed == FeedStrategy.downfeed
          ? 'Feed: gravity downfeed (roof tank)'
          : 'Feed: upfeed / booster pump',
    ];
    final roofM3 = _tankM3(NodeComponent.roofTank);
    if (roofM3 != null) lines.add('Roof tank: $roofM3 m3');
    final groundM3 = _tankM3(NodeComponent.groundTank);
    if (groundM3 != null) lines.add('Ground tank: $groundM3 m3');
    lines.add('Occupancy: ${_occupancyLabel(occupancy)}');
    // Peak design flow is upfeed-only (pumpDutyProvider null on downfeed). Never
    // fabricate a m3/day figure when no pump flow exists.
    if (pump != null) {
      lines.add(
          'Peak design flow: ${pump.flow.inLitersPerSecond.toStringAsFixed(1)} L/s');
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: GlassSurface(
        borderRadius: MechXRadii.card,
        shadow: MechXShadow.popover,
        edge: Border.all(color: colors.glassEdge),
        child: Padding(
          padding: const EdgeInsets.all(MechXSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.strings(StringKey.schematicNotes),
                style: type.caption.copyWith(
                    color: colors.textMuted, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: MechXSpacing.xs),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    line,
                    style: type.caption.copyWith(
                        color: colors.textSecondary, fontFamily: 'Roboto'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

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
