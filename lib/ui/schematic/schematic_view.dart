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

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart'
    show flowFromBySizing, kPumpSetValveTrain, plantMoverCaptions;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/sni.dart';

import '../../store/app_state.dart';
import '../../store/command_store.dart' show ExportGroup, exportSheetProvider;
import '../../store/electrical_store.dart' show WorkspaceView, workspaceViewProvider;
import '../../store/electrical_feed.dart' show riserEquipmentDetailsProvider;
import '../../store/layer_store.dart'
    show DisciplineLayer, DisciplineLayerInfo, servicesFor;
import '../../store/models/sheet.dart' show Sheet;
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/schematic_layout_store.dart';
import '../../store/schematic_view_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../../store/solve_store.dart';
import '../canvas/canvas_view.dart' show canvasFitRequestProvider;
import '../canvas/edge_context_menu.dart';
import '../canvas/segment_symbols.dart';
import '../canvas/service_style.dart';
import '../canvas/text_entry_guard.dart';
import '../canvas/viewport.dart';
import '../canvas/viewport_keys.dart';
import '../canvas/zoom_controls.dart';
import '../shell/nav_rail.dart' show ShellSection, shellSectionProvider;
import '../strings/app_strings.dart';
import '../strings/occupancy_label.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/canvas_guide_popover.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_empty_state_card.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/mechx_segment.dart';
import '../widgets/section_label.dart';
import 'riser_tags.dart';

// `equipmentDetail` was lifted into the engine (`report/riser_tags.dart`) so
// the riser single-line EXPORT builds the same per-node capacity/duty suffixes
// the canvas draws (B1 export parity); re-exported so existing importers and
// tests keep resolving it from this library.
export 'riser_tags.dart' show equipmentDetail;

// ---------------------------------------------------------------------------
// Public widget
// ---------------------------------------------------------------------------

/// Renders the vertical (elevation) workspace — an Auto read-only riser diagram
/// or an Edit placement/sizing surface — from the current network / sizing /
/// building state. Drop-in: it fills the available space.
///
/// F7: the mode / filter / toggles / viewports are held in the transient
/// [schematicViewProvider] so they survive a hop to another workspace and back.
/// Only the ephemeral Export / Show popover-open flags stay widget-local.
class SchematicView extends ConsumerStatefulWidget {
  const SchematicView({super.key});

  @override
  ConsumerState<SchematicView> createState() => _SchematicViewState();
}

class _SchematicViewState extends ConsumerState<SchematicView> {
  /// Whether the 'Show' display-toggles popover is open. Ephemeral popover
  /// interaction state (never sticky; a fresh hop starts closed).
  bool _showDisplayMenu = false;

  /// Anchors the 'Show' popover under its toolbar button.
  final LayerLink _showLink = LayerLink();
  final GlobalKey _showButtonKey = GlobalKey();

  /// True when [global] lands on the 'Show' button — the scrim then leaves the
  /// close to the button's own toggle (else the tap would close-then-reopen).
  bool _onShowButton(Offset global) {
    final box =
        _showButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return (box.localToGlobal(Offset.zero) & box.size).contains(global);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vs = ref.watch(schematicViewProvider);
    final ctrl = ref.read(schematicViewProvider.notifier);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(
          mode: vs.mode,
          service: vs.service,
          autoFocus: vs.autoFocus,
          presentServices: ref
              .watch(networkControllerProvider.select((s) => s.network))
              .edges
              .map((e) => e.service)
              .toSet(),
          inferRisers: vs.inferRisers,
          editDiscipline: vs.effectiveEditDiscipline,
          onMode: ctrl.setMode,
          onService: ctrl.setService,
          onEditDiscipline: ctrl.setEditDiscipline,
          onAutoFocus: ctrl.setAutoFocus,
          onInferRisers: ctrl.setInferRisers,
          showLink: _showLink,
          showButtonKey: _showButtonKey,
          onShow: () => setState(() => _showDisplayMenu = !_showDisplayMenu),
          // Work item 8: Export opens the ONE Export sheet with its Drawings
          // group pre-expanded (the riser PDF/DXF + 'all systems' set rows
          // export the current Auto focus, as the old menu did).
          onExport: () {
            setState(() => _showDisplayMenu = false);
            ref.read(exportSheetProvider.notifier).open(ExportGroup.drawings);
          },
        ),
        Container(height: 1, color: colors.border),
        Expanded(
          child: vs.mode == SchematicMode.edit
              ? _EditElevation(
                  service: vs.service,
                  showHelp: vs.showHelp,
                  onToggleHelp: ctrl.toggleHelp,
                )
              : _AutoElevation(
                  focus: vs.autoFocus,
                  inferRisers: vs.inferRisers,
                  showLegend: vs.showLegend,
                  showTitleBlock: vs.showTitleBlock,
                  showDetails: vs.showDetails,
                  showNotes: vs.showNotes,
                  showHelp: vs.showHelp,
                  onToggleHelp: ctrl.toggleHelp,
                ),
        ),
      ],
    );
    final displayMenuOpen = _showDisplayMenu && vs.mode == SchematicMode.auto;

    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: colors.canvas, child: body)),
        // Tap-away scrim behind the open 'Show' popover. A press on the Show
        // button itself is left to the button's toggle.
        if (displayMenuOpen)
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) {
                if (_onShowButton(e.position)) return;
                setState(() => _showDisplayMenu = false);
              },
              child: const SizedBox.expand(),
            ),
          ),
        if (displayMenuOpen)
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _showLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              offset: const Offset(0, MechXSpacing.xs),
              child: Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    setState(() => _showDisplayMenu = false);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: _RiserDisplayMenu(
                  showDetails: vs.showDetails,
                  showNotes: vs.showNotes,
                  showLegend: vs.showLegend,
                  showTitleBlock: vs.showTitleBlock,
                  onShowDetails: ctrl.setShowDetails,
                  onShowNotes: ctrl.setShowNotes,
                  onShowLegend: ctrl.setShowLegend,
                  onTitleBlock: ctrl.setShowTitleBlock,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The riser 'Show' popover — the four DISPLAY toggles that only change what
/// the Auto diagram shows (never the design): Details + Notes (working-canvas
/// annotations, default on), then under an 'Export preview' caption the Legend
/// + Title block drawing chrome that rides the export (default off). Anchored
/// glass-card idiom; rows reuse the
/// [_ToggleChip] checkbox visual.
class _RiserDisplayMenu extends StatelessWidget {
  final bool showDetails;
  final bool showNotes;
  final bool showLegend;
  final bool showTitleBlock;
  final ValueChanged<bool> onShowDetails;
  final ValueChanged<bool> onShowNotes;
  final ValueChanged<bool> onShowLegend;
  final ValueChanged<bool> onTitleBlock;
  const _RiserDisplayMenu({
    required this.showDetails,
    required this.showNotes,
    required this.showLegend,
    required this.showTitleBlock,
    required this.onShowDetails,
    required this.onShowNotes,
    required this.onShowLegend,
    required this.onTitleBlock,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MechXMotion.resolve(context, MechXMotion.appear),
      curve: MechXMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(
          scale: 0.95 + 0.05 * t,
          alignment: Alignment.topLeft,
          child: child,
        ),
      ),
      // Opaque: a press in the card's padding must not reach the scrim.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 200,
          child: GlassSurface(
            borderRadius: MechXRadii.card,
            blurSigma: MechXGlass.blurSigmaLight,
            shadow: MechXShadow.popover,
            child: Padding(
              padding: const EdgeInsets.all(MechXSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ToggleChip(
                    label: context.strings(StringKey.schematicDetails),
                    value: showDetails,
                    onTap: () => onShowDetails(!showDetails),
                  ),
                  _ToggleChip(
                    label: context.strings(StringKey.schematicNotes),
                    value: showNotes,
                    onTap: () => onShowNotes(!showNotes),
                  ),
                  const SizedBox(height: MechXSpacing.xs),
                  Container(height: 1, color: colors.border),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(MechXSpacing.sm,
                        MechXSpacing.sm, MechXSpacing.sm, MechXSpacing.xs),
                    child: Text(
                      context.strings(StringKey.schematicExportPreview),
                      style:
                          context.type.caption.copyWith(color: colors.textMuted),
                    ),
                  ),
                  _ToggleChip(
                    label: context.strings(StringKey.schematicLegend),
                    value: showLegend,
                    onTap: () => onShowLegend(!showLegend),
                  ),
                  _ToggleChip(
                    label: context.strings(StringKey.schematicTitleBlock),
                    value: showTitleBlock,
                    onTap: () => onTitleBlock(!showTitleBlock),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Toolbar — Auto / Edit tabs + (in Edit) a service picker
// ---------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  final SchematicMode mode;
  final ServiceType service;
  final ServiceType? autoFocus;
  final Set<ServiceType> presentServices;
  final bool inferRisers;
  final DisciplineLayer editDiscipline;
  final ValueChanged<SchematicMode> onMode;
  final ValueChanged<ServiceType> onService;
  final ValueChanged<DisciplineLayer> onEditDiscipline;
  final ValueChanged<ServiceType?> onAutoFocus;
  final ValueChanged<bool> onInferRisers;

  /// Anchor + hit key for the 'Show' display-toggles popover (owned by the
  /// view state, which paints the popover above the canvas).
  final LayerLink showLink;
  final Key showButtonKey;
  final VoidCallback onShow;
  final VoidCallback onExport;

  const _Toolbar({
    required this.mode,
    required this.service,
    required this.autoFocus,
    required this.presentServices,
    required this.inferRisers,
    required this.editDiscipline,
    required this.onMode,
    required this.onService,
    required this.onEditDiscipline,
    required this.onAutoFocus,
    required this.onInferRisers,
    required this.showLink,
    required this.showButtonKey,
    required this.onShow,
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
          // C2: Auto/Edit is a RADIO group (one selected of N) — the shared
          // tinted selected-segment idiom (MechXSegment), the same widget the
          // draw-tool pills and the Layout layer switcher use.
          MechXSegment(
            label: context.strings(StringKey.schematicAuto),
            selected: mode == SchematicMode.auto,
            onTap: () => onMode(SchematicMode.auto),
          ),
          const SizedBox(width: MechXSpacing.xs),
          MechXSegment(
            label: context.strings(StringKey.schematicEdit),
            selected: mode == SchematicMode.edit,
            onTap: () => onMode(SchematicMode.edit),
          ),
          // Auto mode: a per-SYSTEM filter so the single-line can be read one
          // service at a time (clean / hot water, drainage, vent, rainwater,
          // air, fire …) or combined ("All").
          if (mode == SchematicMode.auto && presentServices.isNotEmpty) ...[
            const SizedBox(width: MechXSpacing.md),
            Container(width: 1, height: 22, color: colors.border),
            const SizedBox(width: MechXSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The system filter (All + per-service chips) is ALSO a
                    // radio group — "All" wears the shared tinted segment.
                    MechXSegment(
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
                    // C2: an INDEPENDENT on/off toggle — the checkbox idiom
                    // (never the accent pill). 'Infer risers' stays on the bar
                    // because it adds committable connectors (a design action);
                    // the pure DISPLAY toggles live behind 'Show'.
                    _ToggleChip(
                      label: context.strings(StringKey.schematicInferRisers),
                      value: inferRisers,
                      onTap: () => onInferRisers(!inferRisers),
                    ),
                    const SizedBox(width: MechXSpacing.sm),
                    Container(width: 1, height: 22, color: colors.border),
                    const SizedBox(width: MechXSpacing.sm),
                    // 2026-10-17: Details / Notes / Legend / Title block are
                    // one 'Show' popover (anchored under this button).
                    CompositedTransformTarget(
                      link: showLink,
                      child: KeyedSubtree(
                        key: showButtonKey,
                        child: MechXButton(
                          label: context.strings(StringKey.schematicShow),
                          onPressed: onShow,
                        ),
                      ),
                    ),
                    // F5: Export is an ACTION, not a toggle — a MechXButton
                    // (matching the electrical toolbar's Export grammar). It
                    // rides the END of the scroll strip so the strip keeps the
                    // full toolbar width on a narrow window.
                    const SizedBox(width: MechXSpacing.xs),
                    MechXButton(label: 'Export', onPressed: onExport),
                  ],
                ),
              ),
            ),
          ],
          if (mode == SchematicMode.edit) ...[
            const SizedBox(width: MechXSpacing.md),
            Container(width: 1, height: 22, color: colors.border),
            const SizedBox(width: MechXSpacing.md),
            // 2026-10-17: the riser service picker is DISCIPLINE-SCOPED — a
            // Plumbing / Fire / HVAC radio row, then only that discipline's
            // service chips (5 / 2 / 3), so the strip never clips at 1440.
            for (final d in DisciplineLayer.values)
              if (d.isMechanical) ...[
                MechXSegment(
                  label: d.label,
                  selected: d == editDiscipline,
                  onTap: () => onEditDiscipline(d),
                ),
                const SizedBox(width: MechXSpacing.xs),
              ],
            const SizedBox(width: MechXSpacing.sm),
            Container(width: 1, height: 22, color: colors.border),
            const SizedBox(width: MechXSpacing.sm),
            Flexible(
              // R1: kept as a safety net — on a very narrow window the chips
              // scroll with a soft edge fade (only on an edge with content past
              // it); when they fit it renders as a bare, unmasked Row.
              child: _FadeEdgeScrollStrip(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final s in servicesFor(editDiscipline)) ...[
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

/// R1: a horizontally scrollable strip whose EDGES fade only when there is
/// actually content past them — the affordance that turns a chip clipped at the
/// viewport edge ("Sprinkle…") into an honest "there's more, scroll".
///
/// When the content FITS, no [ShaderMask] is inserted at all, so the rendered
/// layout is identical to a bare `SingleChildScrollView` (the fade can never tint
/// a strip that has nothing to reveal). Overflow state is read from the scroll
/// metrics — `extentBefore`/`extentAfter` — and applied on the next frame (a
/// post-frame `setState`, never during layout), so a window resize that removes
/// the overflow also removes the fade. No Material: a plain gradient
/// [ShaderMask] in `dstIn` over theme-independent alpha (it masks the strip's own
/// pixels, so it works in both light and dark).
class _FadeEdgeScrollStrip extends StatefulWidget {
  final Widget child;

  const _FadeEdgeScrollStrip({required this.child});

  @override
  State<_FadeEdgeScrollStrip> createState() => _FadeEdgeScrollStripState();
}

class _FadeEdgeScrollStripState extends State<_FadeEdgeScrollStrip> {
  final ScrollController _controller = ScrollController();
  bool _fadeStart = false;
  bool _fadeEnd = false;
  bool _scheduled = false;

  /// Width of the fade ramp, as a fraction of the strip's width.
  static const double _rampFraction = 0.07;

  @override
  void initState() {
    super.initState();
    _scheduleSync();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Re-read the metrics on the NEXT frame (notifications can arrive mid-layout,
  /// where `setState` is illegal). Coalesced, so a burst of scroll updates costs
  /// one rebuild at most.
  void _scheduleSync() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final start =
          _controller.hasClients && _controller.position.extentBefore > 0.5;
      final end =
          _controller.hasClients && _controller.position.extentAfter > 0.5;
      if (start == _fadeStart && end == _fadeEnd) return;
      setState(() {
        _fadeStart = start;
        _fadeEnd = end;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final strip = NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _scheduleSync();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          _scheduleSync();
          return false;
        },
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          child: widget.child,
        ),
      ),
    );
    if (!_fadeStart && !_fadeEnd) return strip;
    final stops = <double>[
      0.0,
      _fadeStart ? _rampFraction : 0.0,
      _fadeEnd ? 1.0 - _rampFraction : 1.0,
      1.0,
    ];
    return ShaderMask(
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        stops: stops,
        colors: [
          _fadeStart ? const Color(0x00000000) : const Color(0xFF000000),
          const Color(0xFF000000),
          const Color(0xFF000000),
          _fadeEnd ? const Color(0x00000000) : const Color(0xFF000000),
        ],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: strip,
    );
  }
}

/// C2: an INDEPENDENT on/off toggle in the Riser toolbar (Infer risers / Legend
/// / Title block / Details / Notes). Deliberately DISTINCT from the radio
/// segments (Auto/Edit, All/service) — it never wears the accent-tinted pill;
/// instead a custom-painted checkbox glyph fills when on — so a viewer can tell
/// "flip each" apart from "pick one". Roboto-safe (no icon font), no Material.
class _ToggleChip extends StatefulWidget {
  final String label;
  final bool value;
  final VoidCallback onTap;
  const _ToggleChip(
      {required this.label, required this.value, required this.onTap});

  @override
  State<_ToggleChip> createState() => _ToggleChipState();
}

class _ToggleChipState extends State<_ToggleChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final on = widget.value;
    return MechXFocusRing(
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: MechXMotion.resolve(context, MechXMotion.hover),
            curve: MechXMotion.standard,
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 2),
            decoration: BoxDecoration(
              // No accent tint ever — only a soft hover lift, so the checkbox
              // glyph is the sole on/off signal.
              color: _hover ? colors.surfaceHover : const Color(0x00000000),
              borderRadius: MechXRadii.control,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CheckGlyph(
                  checked: on,
                  fill: colors.accent,
                  check: colors.onAccent,
                  border: colors.textMuted,
                ),
                const SizedBox(width: MechXSpacing.xs + 2),
                Text(
                  widget.label,
                  style: type.label.copyWith(
                    color: on ? colors.textPrimary : colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small custom-painted checkbox — a hollow rounded square when off, an
/// accent-filled square with a check when on. ASCII/no icon font, so it never
/// tofus in the golden pipeline.
class _CheckGlyph extends StatelessWidget {
  final bool checked;
  final Color fill;
  final Color check;
  final Color border;
  const _CheckGlyph(
      {required this.checked,
      required this.fill,
      required this.check,
      required this.border});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(14, 14),
        painter: _CheckPainter(checked, fill, check, border),
      );
}

class _CheckPainter extends CustomPainter {
  final bool checked;
  final Color fill;
  final Color check;
  final Color border;
  _CheckPainter(this.checked, this.fill, this.check, this.border);

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.75),
      const Radius.circular(3),
    );
    if (checked) {
      canvas.drawRRect(rrect, Paint()..color = fill);
      final w = size.width;
      final h = size.height;
      canvas.drawPath(
        Path()
          ..moveTo(w * 0.26, h * 0.52)
          ..lineTo(w * 0.44, h * 0.70)
          ..lineTo(w * 0.76, h * 0.30),
        Paint()
          ..color = check
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    } else {
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.checked != checked ||
      old.fill != fill ||
      old.check != check ||
      old.border != border;
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
            duration: MechXMotion.resolve(context, MechXMotion.hover),
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
                  duration: MechXMotion.resolve(context, MechXMotion.hover),
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

  /// C3: the shared on-demand (?) guide, now on Auto too (was Edit-only). Both
  /// modes read the one [schematicViewProvider.showHelp] flag.
  final bool showHelp;
  final VoidCallback onToggleHelp;

  const _AutoElevation({
    this.focus,
    this.inferRisers = false,
    this.showLegend = true,
    this.showTitleBlock = true,
    this.showDetails = true,
    this.showNotes = true,
    required this.showHelp,
    required this.onToggleHelp,
  });

  @override
  ConsumerState<_AutoElevation> createState() => _AutoElevationState();
}

class _AutoElevationState extends ConsumerState<_AutoElevation>
    with SingleTickerProviderStateMixin {
  /// R1 — the MEMOIZED painter: rebuilt only when one of its inputs changes
  /// ([_painterInputs] identity / value). A pan / zoom frame keeps the SAME
  /// instance under a RepaintBoundary, so only the Transform above it moves —
  /// no re-layout, no label-collision pass, no repaint of the diagram. Its
  /// framed node layout is also the one the inferred-riser hit test reads.
  _AutoSchematicPainter? _painter;
  /// The fit LOD bucket the last build settled on (no stored view yet).
  double? _lastFitLabelZoom;
  Object? _painterInputs;

  /// The viewport (widget) size and the R5 world the diagram lays out in.
  Size _size = Size.zero;
  Size _world = Size.zero;
  bool _hoverInferred = false;

  // Middle-button / trackpad pan tracking.
  bool _panning = false;
  Offset _lastPanPoint = Offset.zero;
  double _lastScale = 1.0;

  /// K1 — keyboard view control (F / Ctrl +-0 / arrows / hold Space).
  final FocusNode _focus = FocusNode(debugLabel: 'riser-auto-canvas');
  final SpacePanLatch _space = SpacePanLatch();
  bool _grabbing = false;

  /// V1 — programmatic changes (zoom buttons, Fit, keyboard zoom) ease.
  late final _ViewportEaser _easer;

  @override
  void initState() {
    super.initState();
    _easer = _ViewportEaser(this, _emit);
  }

  /// Click tolerance (px) for hitting a dashed inferred connector.
  static const double _hitTol = 9.0;

  @override
  void dispose() {
    _easer.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The fit framing of the R5 world — the IDENTITY whenever the building
  /// fits the window (world == viewport), so a default launch renders exactly
  /// as before. Also what Fit / F return to.
  ViewportTransform get _fit =>
      ViewportTransform.fit(_world, _size, padding: 0);

  // F2: the Auto diagram zooms/pans through a ViewportTransform, sticky across
  // workspace hops (F7) via [schematicAutoViewportProvider] — read, never
  // watched here (R1): only [_ViewportTransformed] rebuilds per frame.
  ViewportTransform get _current =>
      ref.read(schematicAutoViewportProvider) ?? _fit;

  void _emit(ViewportTransform next) {
    if (next == _current) return;
    ref.read(schematicAutoViewportProvider.notifier).set(next);
  }

  /// A live gesture (wheel / drag / pinch / arrow pan): immediate, and it
  /// cancels any in-flight eased change.
  void _emitLive(ViewportTransform next) {
    _easer.stop();
    _emit(next);
  }

  void _animateTo(ViewportTransform target) {
    if (_size.isEmpty) return;
    _easer.animateTo(context, _current, target);
  }

  void _fitView() => _animateTo(_fit);

  List<_InferredRiser> _inferred() {
    final painter = _painter;
    if (!widget.inferRisers || _world.isEmpty || painter == null) {
      return const [];
    }
    // Round 26 — the SAME framed layout the painter draws (memoized, P1).
    return painter.inferredRisers(_world);
  }

  /// Hit-test an inferred connector. [content] is a CONTENT-space point (the
  /// caller maps the screen point through the inverse transform first).
  _InferredRiser? _hit(Offset content) {
    _InferredRiser? best;
    var bestD = _hitTol;
    for (final r in _inferred()) {
      final d = _distanceToInferred(r, content);
      if (d < bestD) {
        bestD = d;
        best = r;
      }
    }
    return best;
  }

  void _commit(Offset content) {
    final r = _hit(content);
    if (r == null) return;
    final added = ref
        .read(networkControllerProvider.notifier)
        .connectRiser(r.fromId, r.toId, r.service);
    if (added != null) {
      // B4: this IS a real, sized network edge committed from the read-only Auto
      // view — signal that it is reversible so the click is never a silent,
      // unrecoverable mutation (paired with the on-hover "Click to add" hint).
      ref
          .read(statusMessageProvider.notifier)
          .showStatus('Riser added — Ctrl+Z to undo');
    }
  }

  // ── Zoom / pan gestures (F2) ────────────────────────────────────────────────

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final factor = math.pow(1.0015, -event.scrollDelta.dy).toDouble();
      _emitLive(_current.zoomedBy(factor, event.localPosition));
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _focus.requestFocus();
    if (event.buttons & kMiddleMouseButton != 0) {
      _panning = true;
      _lastPanPoint = event.localPosition;
    }
    if (!_grabbing) setState(() => _grabbing = true);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_panning) {
      _emitLive(_current.panned(event.localPosition - _lastPanPoint));
      _lastPanPoint = event.localPosition;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _panning = false;
    if (_grabbing) setState(() => _grabbing = false);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _easer.stop();
    _lastScale = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    var vt = _current;
    // Single-pointer drag pans (there is no drag action on the read-only Auto
    // diagram to conflict with); trackpad pinch zooms. Skip when [_panning] —
    // a MIDDLE-button drag is already panned by the Listener (`_onPointerMove`),
    // and the scale recognizer also accepts the middle button, so without this
    // guard a middle-drag would pan TWICE (at 2× the cursor speed).
    if (!_panning && details.focalPointDelta != Offset.zero) {
      vt = vt.panned(details.focalPointDelta);
    }
    final incremental = details.scale / _lastScale;
    _lastScale = details.scale;
    if (incremental != 1.0) {
      vt = vt.zoomedBy(incremental, details.localFocalPoint);
    }
    if (vt != _current) _emitLive(vt);
  }

  // ── Keyboard (K1) ────────────────────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (isTextEntryFocused()) return KeyEventResult.ignored;
    if (_space.handle(event)) {
      setState(() {}); // cursor: grab while held
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        widget.showHelp) {
      widget.onToggleHelp();
      return KeyEventResult.handled;
    }
    if (_size.isEmpty) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final intent = viewportIntentForKey(event,
        mod: kb.isControlPressed || kb.isMetaPressed,
        shift: kb.isShiftPressed,
        alt: kb.isAltPressed);
    if (intent == null) return KeyEventResult.ignored;
    final next = intent is ViewportFit
        ? _fit
        : applyViewportIntent(intent, _current,
            contentSize: _world, viewportSize: _size, fitPadding: 0);
    intent.eased ? _animateTo(next) : _emitLive(next);
    return KeyEventResult.handled;
  }

  /// The painter for the current inputs — the previous INSTANCE when nothing
  /// it draws changed (R1), so the diagram layer is reused.
  _AutoSchematicPainter _painterFor({
    required Network network,
    required Map<String, EdgeSizing> sizing,
    required (List<Floor>, int) levels,
    required BuildingLevels building,
    required MechXColors colors,
    required bool downfeed,
    required Map<String, String> riserTagsById,
    required Map<String, String> detailByNode,
    required Set<String> transferPumpNodeIds,
    required bool hotWaterRecirc,
    required double rightOverlayWidth,
    required double labelZoom,
  }) {
    final inputs = (
      network,
      sizing,
      levels,
      colors,
      widget.focus,
      widget.inferRisers,
      downfeed,
      riserTagsById,
      detailByNode,
      transferPumpNodeIds,
      widget.showDetails,
      hotWaterRecirc,
      rightOverlayWidth,
      labelZoom,
    );
    final cached = _painter;
    if (cached != null && inputs == _painterInputs) return cached;
    _painterInputs = inputs;
    return _painter = _AutoSchematicPainter(
      network: network,
      sizing: sizing,
      building: building,
      colors: colors,
      focus: widget.focus,
      inferRisers: widget.inferRisers,
      downfeed: downfeed,
      riserTagsById: riserTagsById,
      detailByNode: detailByNode,
      transferPumpNodeIds: transferPumpNodeIds,
      showDetails: widget.showDetails,
      hotWaterRecirc: hotWaterRecirc,
      rightOverlayWidth: rightOverlayWidth,
      labelZoom: labelZoom,
    );
  }

  @override
  Widget build(BuildContext context) {
    final network =
        ref.watch(networkControllerProvider.select((s) => s.network));
    final sizing = ref.watch(sizingProvider);
    // R1: `ProjectState.building` is a fresh BuildingLevels on every read (no
    // value equality), which made the memoized painter look stale on ANY
    // rebuild — watch (and key the painter on) the floor list + datum instead.
    final levels = ref.watch(
        projectControllerProvider.select((p) => (p.floors, p.groundIndex)));
    final building = BuildingLevels(levels.$1, groundIndex: levels.$2);
    final colors = context.colors;
    // K1 — the palette's / F key's shared fit bump frames this canvas too.
    ref.listen(canvasFitRequestProvider, (_, _) => _fitView());

    if (network.nodes.isEmpty) {
      // F8: the empty state carries a path forward — draw on the Layout canvas
      // or add floors — instead of a dead "No network drawn" line.
      return Center(
        child: MechXEmptyStateCard(
          title: context.strings(StringKey.schematicNoNetwork),
          body: 'Draw pipe runs and risers on the Layout canvas — they stack '
              'here as a vertical riser diagram, sized to their true '
              'floor-to-floor elevation delta.',
          actions: [
            MechXButton(
              label: 'Go to Layout',
              primary: true,
              onPressed: () {
                ref
                    .read(shellSectionProvider.notifier)
                    .set(ShellSection.design);
                ref
                    .read(workspaceViewProvider.notifier)
                    .set(WorkspaceView.plan);
              },
            ),
            MechXButton(
              label: 'Edit floors...',
              onPressed: () => ref
                  .read(shellSectionProvider.notifier)
                  .set(ShellSection.building),
            ),
          ],
        ),
      );
    }
    final feedStrategy = ref.watch(feedStrategyProvider);
    // Resolve the equipment detail suffix per node (tank m3 / pump-fan kW)
    // here, provider-free in the painter — a datum is included only when it
    // genuinely exists (equipmentDetail returns null otherwise).
    // Round 12 — each node's OWN duty (the shared per-node map the issued
    // riser + the panel feed read), never one system duty on every unit.
    final detailByNode = ref.watch(riserEquipmentDetailsProvider);
    final transferPumps = ref.watch(transferPumpNodeIdsProvider);
    // G2: the hot-water recirculation loop exists when the engine sizes one
    // (the provider is non-null) — draw the HWR return.
    final hotWaterRecirc = ref.watch(hotWaterAssumedReturnProvider);
    // R1: memoized per network — a fresh map here made every build repaint.
    final tags = ref.watch(riserTagsProvider(widget.focus));
    // Label LOD: only the QUANTISED zoom bucket is watched, so a pan frame
    // (and a zoom frame inside one bucket) never rebuilds the diagram.
    final watchedLabelZoom = ref.watch(schematicAutoViewportProvider
        .select((vt) => vt == null ? null : riserLabelZoomBucket(vt.scale)));

    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 800,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 600,
        );
        _AutoSchematicPainter painterAt(double labelZoom) => _painterFor(
              network: network,
              sizing: sizing,
              levels: levels,
              building: building,
              colors: colors,
              downfeed: feedStrategy == FeedStrategy.downfeed,
              riserTagsById: tags,
              detailByNode: detailByNode,
              transferPumpNodeIds: transferPumps,
              hotWaterRecirc: hotWaterRecirc,
              // Round 26 — the bottom-right notes / title block are kept clear
              // of the band diagram.
              rightOverlayWidth: (widget.showNotes || widget.showTitleBlock)
                  ? _kAutoNotesReserve
                  : 0,
              labelZoom: labelZoom,
            );
        // With no stored view, start from the fit LOD bucket the previous
        // build settled on, so a rebuild (hover, a tag tick) hits the painter
        // memo instead of building a 1.0 painter and immediately replacing it
        // (review: that defeated the R1 memo + the per-painter layout cache on
        // every rebuild of a tall building).
        var painter =
            painterAt(watchedLabelZoom ?? _lastFitLabelZoom ?? 1.0);
        // R5: the world the diagram lays out in (== the viewport unless the
        // building is too tall for legible bands).
        _world = painter.worldSizeFor(_size);
        // No stored view yet: the canvas shows the FIT framing, so key the
        // label LOD on the fit scale (1.0 — unchanged — whenever the
        // building fits the window).
        if (watchedLabelZoom == null) {
          final fitZoom = riserLabelZoomBucket(_fit.scale);
          if (fitZoom != painter.labelZoom) painter = painterAt(fitZoom);
          _lastFitLabelZoom = fitZoom;
        }
        // The painted single-line in its own layer (RepaintBoundary) under the
        // live ViewportTransform — the ONE widget that rebuilds per pan / zoom
        // frame. Identity at rest whenever world == viewport ⇒ byte-identical.
        final content = ClipRect(
          child: _ViewportTransformed(
            viewport: schematicAutoViewportProvider,
            fallback: _fit,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: 0,
              maxHeight: double.infinity,
              child: RepaintBoundary(
                child: CustomPaint(size: _world, painter: painter),
              ),
            ),
          ),
        );
        // Wheel + middle-button pan (Listener) and trackpad pinch / drag-pan
        // (GestureDetector). When inferred risers are shown the dashed connectors
        // are CLICKABLE (one tap commits a real sized riser) — the hit-test maps
        // the screen point through the inverse transform into content space.
        final body = Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          onFocusChange: (has) {
            if (!has && _space.release()) setState(() {});
          },
          child: Listener(
            onPointerSignal: _onPointerSignal,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            child: MouseRegion(
              cursor: _hoverInferred && !_space.held
                  ? SystemMouseCursors.click
                  : (_grabbing
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab),
              onHover: !widget.inferRisers
                  ? null
                  : (e) {
                      final over =
                          _hit(_current.screenToWorld(e.localPosition)) != null;
                      if (over != _hoverInferred) {
                        setState(() => _hoverInferred = over);
                      }
                    },
              onExit: (_) {
                if (_hoverInferred) setState(() => _hoverInferred = false);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onTapUp: !widget.inferRisers
                    ? null
                    : (d) {
                        // Hold-Space is a pan: never commit a riser on release.
                        if (_space.held) return;
                        _commit(_current.screenToWorld(d.localPosition));
                      },
                child: content,
              ),
            ),
          ),
        );
        return Stack(
          children: [
            Positioned.fill(child: body),
            // F2: on-canvas zoom controls (bottom-left) — the same cluster the
            // Edit / Layout / electrical canvases show. Fit returns to the R5
            // world framing (the identity whenever the building fits). V1: the
            // three buttons ease like the Layout's (reduced motion: instant).
            Positioned(
              left: MechXSpacing.md,
              bottom: MechXSpacing.md,
              child: ZoomControls(
                onIn: () =>
                    _animateTo(_current.zoomedBy(1.2, _size.center(Offset.zero))),
                onOut: () => _animateTo(
                    _current.zoomedBy(1 / 1.2, _size.center(Offset.zero))),
                onFit: _fitView,
              ),
            ),
            // The KETERANGAN / legend overlay now sits TOP-left (the bottom-left
            // corner is taken by the F2 zoom cluster); a drafting-chrome card
            // that lists the services actually drawn. Default OFF (export chrome).
            // Offset down to clear the shared (?) guide button (C3) that now sits
            // in the top-left corner.
            if (widget.showLegend)
              Positioned(
                left: MechXSpacing.md,
                top: MechXSpacing.md + 30,
                child: _AutoLegend(network: network, focus: widget.focus),
              ),
            // The system-NOTES (KETERANGAN) card + the title block both sit
            // bottom-RIGHT, STACKED vertically (notes above the title block) so
            // they never overlap — clear of the bottom-left zoom cluster.
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
            // C3: the shared on-demand (?) guide (top-left) — the SAME affordance
            // the Layout / electrical / Riser-Edit canvases use, now on Auto too.
            // The button is a small edge affordance; the popover is hidden by
            // default so the idle Auto canvas is byte-identical bar the button.
            Positioned(
              left: MechXSpacing.md,
              top: MechXSpacing.sm,
              child: CanvasGuideButton(
                open: widget.showHelp,
                onToggle: widget.onToggleHelp,
              ),
            ),
            if (widget.showHelp)
              Positioned(
                left: MechXSpacing.md,
                top: 48,
                child: CanvasGuideLegend(
                  onClose: widget.onToggleHelp,
                  // C3 follow-up: keep the Riser's own localized heading
                  // ("Elevation guide" / "Panduan elevasi") the bespoke popover had.
                  title: context.strings(StringKey.schematicElevationGuide),
                  items: [
                    context.strings(StringKey.schematicHelpModes),
                    context.strings(StringKey.schematicHelp2),
                    context.strings(StringKey.schematicHelp6),
                  ],
                ),
              ),
            // B4: hovering a dashed inferred connector — the ONE interactive
            // element in this otherwise read-only view — surfaces an explicit
            // "Click to add this riser" hint (top-centre), so committing a real
            // sized edge is a deliberate, confirmed action instead of a silent
            // mutation while the engineer believes the view is read-only.
            if (_hoverInferred)
              Positioned(
                top: MechXSpacing.sm,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: MechXSpacing.sm,
                          vertical: MechXSpacing.xs),
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: MechXRadii.control,
                        boxShadow: MechXShadow.popover,
                      ),
                      child: Text(
                        'Click to add this riser',
                        style: context.type.label
                            .copyWith(color: colors.onAccent),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// R1 — the ONE widget that rebuilds on a Riser pan / zoom frame: it watches
/// the canvas's viewport provider and applies the transform to a [child] whose
/// identity the parent keeps stable (so the framework never rebuilds — or,
/// under its RepaintBoundary, repaints — the diagram beneath).
class _ViewportTransformed extends ConsumerWidget {
  final ProviderListenable<ViewportTransform?> viewport;

  /// The view to use while the provider holds nothing yet (the host's fit).
  final ViewportTransform fallback;
  final Widget child;

  const _ViewportTransformed({
    required this.viewport,
    required this.fallback,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vt = ref.watch(viewport) ?? fallback;
    return Transform.translate(
      offset: vt.offset,
      child: Transform.scale(
        scale: vt.scale,
        alignment: Alignment.topLeft,
        child: child,
      ),
    );
  }
}

/// V1 — eases a Riser canvas's PROGRAMMATIC viewport change (zoom buttons,
/// Fit, keyboard zoom) from the current view to a target, like the Layout
/// canvas's G4 tween (`CanvasView._animateTo`: [MechXMotion.medium] on
/// [MechXMotion.standard]). The duration passes through [MechXMotion.resolve],
/// so with reduced motion the change is applied at once. Live manipulation
/// (wheel, drag, pinch, arrow pan) calls [stop] and writes directly.
class _ViewportEaser {
  _ViewportEaser(TickerProvider vsync, this._onTick)
      : _ctrl = AnimationController(vsync: vsync, duration: MechXMotion.medium) {
    _ctrl.addListener(_tick);
  }

  final AnimationController _ctrl;
  final void Function(ViewportTransform) _onTick;
  ViewportTransform? _from;
  ViewportTransform? _to;

  void animateTo(
      BuildContext context, ViewportTransform from, ViewportTransform to) {
    stop();
    if (from == to) return;
    final d = MechXMotion.resolve(context, MechXMotion.medium);
    if (d == Duration.zero) {
      _onTick(to);
      return;
    }
    _from = from;
    _to = to;
    _ctrl
      ..duration = d
      ..reset()
      ..forward();
  }

  void _tick() {
    final from = _from, to = _to;
    if (from == null || to == null) return;
    final t = MechXMotion.standard.transform(_ctrl.value);
    _onTick(ViewportTransform(
      scale: from.scale + (to.scale - from.scale) * t,
      offset: Offset.lerp(from.offset, to.offset, t)!,
    ));
  }

  void stop() {
    if (_ctrl.isAnimating) _ctrl.stop();
    _from = null;
    _to = null;
  }

  void dispose() => _ctrl.dispose();
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

class _EditElevationState extends ConsumerState<_EditElevation>
    with SingleTickerProviderStateMixin {
  Size _viewportSize = Size.zero;
  final FocusNode _focus = FocusNode(debugLabel: 'elevation-canvas');

  // Middle-button / hold-Space left-drag pan tracking.
  bool _panning = false;
  Offset _lastPanPoint = Offset.zero;
  double _lastScale = 1.0;

  /// K1 — hold Space: a left-drag pans instead of marqueeing (there is no
  /// other way to pan this canvas without a middle button).
  final SpacePanLatch _space = SpacePanLatch();

  /// V1 — programmatic viewport changes ease (reduced motion: instant).
  late final _ViewportEaser _easer;

  @override
  void initState() {
    super.initState();
    _easer = _ViewportEaser(this, _emit);
  }

  // R3 — a press on a selected riser ARMS a drag; it only starts once the
  // pointer travels past the platform pan slop (so a click's jitter never
  // slides the riser), and the whole drag is ONE undo step.
  String? _pressRiser;
  Offset _pressPos = Offset.zero;
  double _dragSlop = kTouchSlop;
  bool _dragActive = false;

  // D5: batch horizontal move — each selected riser's node x at drag start, plus
  // the cursor world-x at start, so the whole selection moves by ONE shared
  // delta (relative offsets preserved). Null when no drag is in flight.
  Map<String, double>? _dragBaseX;
  double _dragBaseCursorX = 0;

  // D5: the in-flight marquee (screen-space), drawn by an empty-canvas left-drag
  // to rubber-band-select several risers. Null when not marqueeing.
  Offset? _marqueeStart;
  Offset? _marqueeCurrent;

  // B3: the floor band a palette drag would drop the riser BASE on — tracked
  // live from the DragTarget so the painter highlights the real target band
  // (redirected down one for a top-band hover), replacing the old whole-canvas
  // tint as the only drop feedback. Null when no card is over the canvas.
  int? _dragBandFloor;

  /// V4 — the riser under the cursor (a hover halo + the move cursor). Null
  /// when the pointer is over blank canvas. Gesture-time only.
  String? _hoverRiser;

  /// World-px gap between adjacent floor bands. The vertical axis is laid out by
  /// floor index (true elevation order) at a fixed band height — the riser's
  /// REAL length is still the elevation delta (used for the label + sizing),
  /// this is only the on-screen band spacing.
  static const double _bandWorldH = 160;

  /// R4 — the minimum world width of the elevation frame (the historical fixed
  /// frame), and the margin kept beyond the outermost node either side.
  static const double _minWorldWidth = 1200;
  static const double _worldMargin = 80;

  /// K1 — one arrow-nudge step, in SCREEN px (so a nudge reads the same at
  /// every zoom).
  static const double _nudgeScreenPx = 8;

  @override
  void dispose() {
    _easer.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// R4 — the world frame the floor lines span and Fit frames: at least the
  /// historical 0..1200, grown to hold EVERY node at its diagram x (plan x, or
  /// its elevation override) plus a margin — a riser drawn at plan x 2400 used
  /// to sit beyond the floor lines and outside Fit.
  Rect _contentRect() {
    final net = ref.read(networkControllerProvider).network;
    final n = ref.read(projectControllerProvider).building.levelCount;
    final layout = ref.read(schematicLayoutProvider);
    return _elevationContentRect(net, layout, n,
        bandWorldH: _bandWorldH,
        minWidth: _minWorldWidth,
        margin: _worldMargin);
  }

  ViewportTransform _fitView() =>
      _fitRect(_contentRect(), _viewportSize, padding: 40);

  ViewportTransform get _current =>
      ref.read(schematicEditViewportProvider) ?? _fitView();

  // Screen-y (world) of a floor band's centre — floor 0 at the bottom.
  double _bandCentreWorldY(int floorIndex, int levelCount) {
    final inverted = (levelCount - 1) - floorIndex;
    return inverted * _bandWorldH + _bandWorldH / 2;
  }

  void _emit(ViewportTransform next) {
    if (next == ref.read(schematicEditViewportProvider)) return;
    // F7: persisted so a hop away and back restores this viewport.
    ref.read(schematicEditViewportProvider.notifier).set(next);
  }

  void _emitLive(ViewportTransform next) {
    _easer.stop();
    _emit(next);
  }

  void _animateTo(ViewportTransform target) {
    if (_viewportSize.isEmpty) return;
    _easer.animateTo(context, _current, target);
  }

  void _maybeFit() {
    if (ref.read(schematicEditViewportProvider) != null ||
        _viewportSize.isEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          ref.read(schematicEditViewportProvider) != null ||
          _viewportSize.isEmpty) {
        return;
      }
      _emit(_fitView());
    });
  }

  // ── Hit-testing ───────────────────────────────────────────────────────────

  /// The nearest riser edge whose vertical leg is within [tolWorld] of the world
  /// point [w], or null. A riser's vertical leg runs at the from/to node x
  /// between the two floor band centres.
  String? _riserAt(Offset w, double tolWorld) {
    final net = ref.read(networkControllerProvider).network;
    final levelCount = ref.read(projectControllerProvider).building.levelCount;
    final layout = ref.read(schematicLayoutProvider);
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
      // B3: the DIAGRAM x (an override when the riser was dragged sideways on
      // the elevation, else the plan x) — the same x the painter draws at.
      final dx = (w.dx - layout.xFor(a)).abs();
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
      _emitLive(_current.zoomedBy(factor, event.localPosition));
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _focus.requestFocus();
    final primary = event.buttons & kPrimaryMouseButton != 0;
    if (event.buttons & kMiddleMouseButton != 0 || (primary && _space.held)) {
      // Middle-drag, or a left-drag while Space is held (K1), pans.
      _easer.stop();
      setState(() => _panning = true);
      _lastPanPoint = event.localPosition;
      return;
    }
    if (primary) {
      final w = _current.screenToWorld(event.localPosition);
      final hit = _riserAt(w, 16 / _current.scale);
      if (hit != null) {
        // D5: shift toggles into the multi-selection; a plain click on a riser
        // NOT already in the selection replaces it (a click on one already in a
        // multi-selection keeps the set, so a group drag works).
        final shift = HardwareKeyboard.instance.isShiftPressed;
        final selNotifier = ref.read(selectionProvider.notifier);
        if (shift) {
          selNotifier.toggleEdge(hit);
        } else if (!ref.read(selectionProvider).containsEdge(hit)) {
          selNotifier.selectEdge(hit);
        }
        if (ref.read(selectionProvider).containsEdge(hit)) {
          // R3: ARM the drag; it starts past the slop in [_onPointerMove].
          _pressRiser = hit;
          _pressPos = event.localPosition;
          _dragSlop = computePanSlop(
              event.kind, MediaQuery.maybeGestureSettingsOf(context));
        }
      } else {
        // D5: empty-canvas left-drag draws a marquee (rubber-band multi-select).
        _marqueeStart = event.localPosition;
        _marqueeCurrent = event.localPosition;
      }
    }
  }

  /// D5: snapshot each selected riser's node x (+ the cursor world-x) so the
  /// group moves by one shared delta.
  void _beginRiserDrag(double cursorWorldX) {
    final net = ref.read(networkControllerProvider).network;
    final layout = ref.read(schematicLayoutProvider);
    final base = <String, double>{};
    for (final id in ref.read(selectionProvider).edgeIds) {
      final e = net.edgeById(id);
      if (e == null || e.kind != EdgeKind.riser) continue;
      final a = net.nodeById(e.fromId);
      if (a != null) base[id] = layout.xFor(a);
    }
    _dragBaseX = base;
    _dragBaseCursorX = cursorWorldX;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_panning) {
      _emitLive(_current.panned(event.localPosition - _lastPanPoint));
      _lastPanPoint = event.localPosition;
      return;
    }
    final pressed = _pressRiser;
    if (pressed != null) {
      if (!_dragActive) {
        // R3: below the slop a press is still a click — nothing moves.
        if ((event.localPosition - _pressPos).distance < _dragSlop) return;
        _dragActive = true;
        // The whole drag folds into ONE undo step (closed on pointer-up).
        ref.read(schematicLayoutProvider.notifier).beginGesture();
        // Measured from the PRESS point, so crossing the slop never jumps.
        _beginRiserDrag(_current.screenToWorld(_pressPos).dx);
      }
      // B3: this drag moves the riser on the DIAGRAM only
      // (`moveRiserHorizontal` writes the elevation-layout override, never the
      // plan nodes), so nothing heavy re-runs while it is in flight.
      final w = _current.screenToWorld(event.localPosition);
      final ctrl = ref.read(networkControllerProvider.notifier);
      final base = _dragBaseX;
      if (base != null && base.isNotEmpty) {
        // D5: move the WHOLE selection by one shared delta (relative x offsets
        // between risers preserved).
        final delta = w.dx - _dragBaseCursorX;
        base.forEach((id, x0) => ctrl.moveRiserHorizontal(id, x0 + delta));
      } else {
        ctrl.moveRiserHorizontal(pressed, w.dx);
      }
      return;
    }
    if (_marqueeStart != null) {
      setState(() => _marqueeCurrent = event.localPosition);
    }
  }

  /// End any riser drag (one undo step when something moved).
  void _endRiserDrag() {
    if (_dragActive) {
      ref.read(schematicLayoutProvider.notifier).endGesture();
    }
    _pressRiser = null;
    _dragActive = false;
    _dragBaseX = null;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_panning) setState(() => _panning = false);
    _endRiserDrag();
    // D5: finalize the marquee → select the risers it captures.
    final start = _marqueeStart;
    final current = _marqueeCurrent;
    if (start != null && current != null) {
      final rect = Rect.fromPoints(start, current);
      if (rect.width > 4 || rect.height > 4) {
        // V5: a LEFT-to-RIGHT drag is a WINDOW (a riser leg fully inside);
        // RIGHT-to-LEFT a CROSSING (any leg the box touches) — the Layout's B26
        // convention (ties favour the stricter window).
        _selectRisersInRect(rect, window: current.dx >= start.dx);
      }
      setState(() {
        _marqueeStart = null;
        _marqueeCurrent = null;
      });
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_panning) setState(() => _panning = false);
    _endRiserDrag();
    if (_marqueeStart != null) {
      setState(() {
        _marqueeStart = null;
        _marqueeCurrent = null;
      });
    }
  }

  /// D5 / V5: the risers the marquee [rect] captures — legs fully inside it
  /// ([window]) or any leg it touches (crossing). Shift extends the current
  /// selection, else replaces it.
  void _selectRisersInRect(Rect rect, {required bool window}) {
    final net = ref.read(networkControllerProvider).network;
    final levelCount = ref.read(projectControllerProvider).building.levelCount;
    final layout = ref.read(schematicLayoutProvider);
    final hit = riserIdsInScreenRect(
      net,
      rect,
      window: window,
      worldOf: (n) => _current.worldToScreen(
          Offset(layout.xFor(n), _bandCentreWorldY(n.floorIndex, levelCount))),
    );
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift) {
      ref.read(selectionProvider.notifier).addMulti(const {}, hit);
    } else {
      ref.read(selectionProvider.notifier).setMulti(const {}, hit);
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _easer.stop();
    _lastScale = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Single-pointer pan only when NOT dragging a riser, drawing a marquee or
    // panning (the Listener handles all three); trackpad pinch always zooms.
    if (_pressRiser != null || _marqueeStart != null || _panning) return;
    var vt = _current;
    if (details.pointerCount > 1 && details.focalPointDelta != Offset.zero) {
      vt = vt.panned(details.focalPointDelta);
    }
    final incremental = details.scale / _lastScale;
    _lastScale = details.scale;
    if (incremental != 1.0) {
      vt = vt.zoomedBy(incremental, details.localFocalPoint);
    }
    if (vt != _current) _emitLive(vt);
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final w = _current.screenToWorld(details.localPosition);
    final hit = _riserAt(w, 16 / _current.scale);
    if (hit == null) return;
    ref.read(selectionProvider.notifier).selectEdge(hit);
    final edge = ref.read(networkControllerProvider).network.edgeById(hit);
    final layout = ref.read(schematicLayoutProvider);
    final moved = edge != null &&
        (layout.schematicXOverrides.containsKey(edge.fromId) ||
            layout.schematicXOverrides.containsKey(edge.toId));
    showEdgeContextMenu(
      context,
      ref,
      hit,
      details.globalPosition,
      // R3: return a riser slid sideways on the diagram to its plan x (one
      // undo step). Offered only when it actually carries a diagram offset.
      extraActions: [
        if (moved)
          EdgeMenuAction(
            'Reset position',
            () => ref
                .read(schematicLayoutProvider.notifier)
                .resetNodes([edge.fromId, edge.toId]),
          ),
      ],
    );
  }

  /// The riser edges in the current selection (the only elements Edit mode
  /// selects / edits — runs are inert here, D3).
  Set<String> _selectedRiserIds() {
    final net = ref.read(networkControllerProvider).network;
    return {
      for (final id in ref.read(selectionProvider).edgeIds)
        if (net.edgeById(id)?.kind == EdgeKind.riser) id,
    };
  }

  /// K1 — nudge the selected risers sideways on the DIAGRAM by [dxScreen]
  /// screen px (one undo step). False when nothing riser-shaped is selected
  /// (the arrow then pans).
  bool _nudgeSelection(double dxScreen) {
    final ids = _selectedRiserIds();
    if (ids.isEmpty) return false;
    final net = ref.read(networkControllerProvider).network;
    final layout = ref.read(schematicLayoutProvider);
    final dx = dxScreen / _current.scale;
    final next = <String, double>{};
    for (final id in ids) {
      final e = net.edgeById(id)!;
      final a = net.nodeById(e.fromId);
      if (a == null) continue;
      final x = layout.xFor(a) + dx;
      next[e.fromId] = x;
      next[e.toId] = x;
    }
    ref.read(schematicLayoutProvider.notifier).setNodesXUndoable(next);
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // B4: while a text field owns the keyboard, canvas shortcuts edit TEXT —
    // never the drawing (the shared guard the Layout/electrical canvases use).
    if (isTextEntryFocused()) return KeyEventResult.ignored;
    // K1: hold-Space pan (down AND up are tracked).
    if (_space.handle(event)) {
      setState(() {}); // the grab cursor
      return KeyEventResult.handled;
    }
    final kb = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final mod = kb.isControlPressed || kb.isMetaPressed;

    if (event is KeyDownEvent) {
      // Round 12 (ui-journey-undo-redo-double-dispatch) — Ctrl/Cmd+Z / Y /
      // Shift+Z are run ONCE, by the shell's pre-focus HardwareKeyboard handler
      // (AppShell._onHardwareKey). That handler's return value does NOT stop
      // the framework delivering the same key down the focus chain, so acting
      // here too undid / redid TWO steps per press. Consume the combo without
      // acting so nothing further down this handler reacts to it.
      if (mod &&
          (key == LogicalKeyboardKey.keyZ || key == LogicalKeyboardKey.keyY)) {
        return KeyEventResult.handled;
      }

      // F4: the Esc ladder — close the help popover, else clear a selection,
      // else return to the read-only Auto view.
      if (key == LogicalKeyboardKey.escape) {
        if (widget.showHelp) {
          widget.onToggleHelp();
          return KeyEventResult.handled;
        }
        if (_marqueeStart != null) {
          setState(() {
            _marqueeStart = null;
            _marqueeCurrent = null;
          });
          return KeyEventResult.handled;
        }
        if (ref.read(selectionProvider).hasSelection) {
          ref.read(selectionProvider.notifier).clear();
          return KeyEventResult.handled;
        }
        ref.read(schematicViewProvider.notifier).setMode(SchematicMode.auto);
        return KeyEventResult.handled;
      }

      // R2: Delete removes EVERY selected riser (a marquee / Ctrl+A / shift
      // set), not just the primary one — ONE undo step via `deleteMany`.
      if (key == LogicalKeyboardKey.delete ||
          key == LogicalKeyboardKey.backspace) {
        final ids = _selectedRiserIds();
        if (ids.isEmpty) return KeyEventResult.ignored;
        final net = ref.read(networkControllerProvider).network;
        ref
            .read(networkControllerProvider.notifier)
            .deleteMany(orphanedRiserEndpoints(net, ids), ids);
        ref.read(selectionProvider.notifier).clear();
        return KeyEventResult.handled;
      }

      // K1: Ctrl/Cmd+A selects every riser on the elevation (Edit shows the
      // whole building, every service).
      if (mod && key == LogicalKeyboardKey.keyA) {
        final net = ref.read(networkControllerProvider).network;
        ref.read(selectionProvider.notifier).setMulti(const {}, {
          for (final e in net.edges)
            if (e.kind == EdgeKind.riser) e.id,
        });
        return KeyEventResult.handled;
      }
    }

    // K1: the shared canvas view keys (F fit, Ctrl +/-/0, arrows).
    if (_viewportSize.isEmpty) return KeyEventResult.ignored;
    final intent = viewportIntentForKey(event,
        mod: mod, shift: kb.isShiftPressed, alt: kb.isAltPressed);
    if (intent == null) return KeyEventResult.ignored;
    if (intent is ViewportPan && intent.nudgeCandidate) {
      // A selection nudges sideways (risers have no free vertical — their
      // length is the elevation delta); Up/Down and an empty selection pan.
      final dx = switch (intent.arrow) {
        LogicalKeyboardKey.arrowLeft => -_nudgeScreenPx,
        LogicalKeyboardKey.arrowRight => _nudgeScreenPx,
        _ => 0.0,
      };
      if (dx != 0 && _nudgeSelection(dx)) return KeyEventResult.handled;
    }
    final rect = _contentRect();
    final next = switch (intent) {
      ViewportFit() => _fitView(),
      ViewportActualSize() => ViewportTransform.actualSize(
              rect.size, _viewportSize)
          .panned(-rect.topLeft),
      _ => applyViewportIntent(intent, _current,
          contentSize: rect.size, viewportSize: _viewportSize),
    };
    intent.eased ? _animateTo(next) : _emitLive(next);
    return KeyEventResult.handled;
  }

  // ── Palette drop ────────────────────────────────────────────────────────────

  /// The floor index a drop at [localScreen] would place the riser's BASE on:
  /// the band under the cursor, redirected DOWN one when the cursor is on the
  /// topmost band (a riser always spans to the floor above, so the top band
  /// can't host a base). Null when there are < 2 floors or the point is out of
  /// range. B3: shared by the drag-preview highlight and the actual drop so the
  /// highlight shows exactly where the base will land.
  ({int floorIndex, bool redirected})? _dropTarget(Offset localScreen) {
    final levelCount = ref.read(projectControllerProvider).building.levelCount;
    if (levelCount < 2) return null;
    final w = _current.screenToWorld(localScreen);
    final invertedRaw = (w.dy / _bandWorldH).floor();
    final inverted = invertedRaw.clamp(0, levelCount - 1);
    var floorIndex = (levelCount - 1) - inverted;
    final redirected = floorIndex + 1 >= levelCount;
    if (redirected) floorIndex = levelCount - 2;
    if (floorIndex < 0) return null;
    return (floorIndex: floorIndex, redirected: redirected);
  }

  /// B2 — drop a riser from the Riser palette onto a floor band.
  ///
  /// The drop used to take the ELEVATION diagram's world x (and `y = 0`) as the
  /// riser's PLAN coordinates, and to fall back to the CURRENT sheet when the
  /// target floor had no plan assigned — producing a node whose sheetId maps to
  /// one floor while its floorIndex says another: invisible on every sheet
  /// forever, yet still sized into the BOM. Both halves are fixed here:
  ///
  ///   * an UNMAPPED floor REFUSES the drop with a status message naming the
  ///     level to assign a plan to (nothing is drawn — a riser with no plan to
  ///     live on is exactly the ghost this defect produced);
  ///   * a mapped floor places the riser at that SHEET'S CENTRE — a real plan
  ///     coordinate the engineer can find and drag — and says so, so the jump
  ///     from the cursor to the plan centre is never a silent surprise.
  void _onDrop(Offset localScreen) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final building = ref.read(projectControllerProvider).building;
    final target = _dropTarget(localScreen);
    if (target == null) return;
    final floorIndex = target.floorIndex;

    final sheet = _sheetForFloor(floorIndex);
    if (sheet == null) {
      final level = floorIndex < building.levelCount
          ? building.floors[floorIndex].name
          : '$floorIndex';
      ref.read(statusMessageProvider.notifier).showStatus(
          MechXStrings.of(context)
              .format(StringKey.schematicDropNeedsPlan, {'level': level}));
      return;
    }

    // The riser lands at the centre of the destination plan — a real sheet
    // coordinate, not the elevation's own x with y pinned to 0.
    final centre = Offset(sheet.sizePx.width / 2, sheet.sizePx.height / 2);
    final id = ref.read(networkControllerProvider.notifier).placeRiserAt(
          sheet.id,
          floorIndex,
          centre.dx,
          building.levelCount,
          service: widget.service,
          y: centre.dy,
        );
    if (id != null) {
      ref.read(selectionProvider.notifier).selectEdge(id);
      final strings = MechXStrings.of(context);
      // B3 (top band): a drop on the TOP band has no floor above it, so the
      // riser's base was placed on the floor BELOW (it still spans a real
      // elevation delta up to the top). Say so — a top-band drop otherwise
      // draws a connection one floor off the target.
      if (target.redirected &&
          floorIndex + 1 < building.levelCount &&
          floorIndex < building.levelCount) {
        final lower = building.floors[floorIndex].name;
        final upper = building.floors[floorIndex + 1].name;
        ref
            .read(statusMessageProvider.notifier)
            .showStatus('Riser to $upper — base on $lower below');
      } else {
        ref.read(statusMessageProvider.notifier).showStatus(
              strings.format(StringKey.schematicDropCentred, {
                'level': building.floors[floorIndex].name,
                'sheet': sheet.name,
              }),
            );
      }
    }
  }

  /// The SHEET mapped to [floorIndex], or null when that level carries no plan.
  /// Deliberately NOT falling back to the current sheet (B2): a riser stamped
  /// with another floor's sheet id is invisible on every plan.
  Sheet? _sheetForFloor(int floorIndex) {
    final sheets = ref.read(sheetsControllerProvider);
    final levelCount = ref.read(projectControllerProvider).building.levelCount;
    for (final s in sheets.sheets) {
      if (sheets.floorFor(s.id, levelCount) == floorIndex) return s;
    }
    return null;
  }

  /// V4 — the honest cursor: grab / grabbing while panning (Space held or a
  /// middle drag), a sideways-move cursor over a draggable riser, else basic.
  MouseCursor get _cursor {
    if (_panning) return SystemMouseCursors.grabbing;
    if (_space.held) return SystemMouseCursors.grab;
    if (_pressRiser != null || _hoverRiser != null) {
      return SystemMouseCursors.resizeLeftRight;
    }
    return SystemMouseCursors.basic;
  }

  void _onHover(PointerHoverEvent e) {
    final hit = _space.held
        ? null
        : _riserAt(_current.screenToWorld(e.localPosition), 16 / _current.scale);
    if (hit != _hoverRiser) setState(() => _hoverRiser = hit);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final network =
        ref.watch(networkControllerProvider.select((s) => s.network));
    final sizing = ref.watch(sizingProvider);
    final building = ref.watch(projectControllerProvider).building;
    final selection = ref.watch(selectionProvider);
    // B3: the diagram-only riser positions (empty unless one was dragged
    // sideways here). Watched so a drag repaints without touching the network.
    final schematicX = ref.watch(schematicLayoutProvider).schematicXOverrides;
    // The live viewport — this canvas paints in screen space, so a pan frame
    // repaints it (it is light; the heavy Auto diagram does not).
    final watchedVt = ref.watch(schematicEditViewportProvider);
    // K1 — the palette's / F key's shared fit bump frames this canvas too.
    ref.listen(canvasFitRequestProvider,
        (_, _) => _animateTo(_fitView()));
    final content = _elevationContentRect(
        network,
        SchematicLayoutState(schematicXOverrides: schematicX),
        building.levelCount,
        bandWorldH: _bandWorldH,
        minWidth: _minWorldWidth,
        margin: _worldMargin);

    final canvas = Focus(
      focusNode: _focus,
      // F4: autofocus on arrival so Delete / Ctrl+Z-Y / Esc work immediately,
      // without first clicking the canvas.
      autofocus: true,
      onKeyEvent: _onKey,
      onFocusChange: (has) {
        // The Space key-up lands elsewhere once focus leaves: drop the latch.
        if (!has && _space.release()) setState(() {});
      },
      child: MouseRegion(
        cursor: _cursor,
        onHover: _onHover,
        onExit: (_) {
          if (_hoverRiser != null) setState(() => _hoverRiser = null);
        },
        child: Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onSecondaryTapUp: _onSecondaryTapUp,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _viewportSize = constraints.biggest;
                _maybeFit();
                final vt = watchedVt ??
                    _fitRect(content, _viewportSize, padding: 40);
                return ClipRect(
                  child: CustomPaint(
                    size: _viewportSize,
                    painter: _EditSchematicPainter(
                      network: network,
                      sizing: sizing,
                      building: building,
                      mounting: ref.watch(mountingProvider),
                      colors: colors,
                      transform: vt,
                      selectedEdgeIds: selection.edgeIds,
                      bandWorldH: _bandWorldH,
                      worldLeft: content.left,
                      worldRight: content.right,
                      schematicX: schematicX,
                      highlightFloor: _dragBandFloor,
                      hoverEdgeId: _hoverRiser,
                      marquee: (_marqueeStart != null && _marqueeCurrent != null)
                          ? Rect.fromPoints(_marqueeStart!, _marqueeCurrent!)
                          : null,
                      marqueeWindow: _marqueeStart == null ||
                          _marqueeCurrent == null ||
                          _marqueeCurrent!.dx >= _marqueeStart!.dx,
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
                  // B3: track the target band live so the painter can highlight
                  // exactly where the riser base will land (redirected down one
                  // on the top band) — honest drop feedback, not a blanket tint.
                  onMove: (details) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final t = _dropTarget(box.globalToLocal(details.offset));
                    final f = t?.floorIndex;
                    if (f != _dragBandFloor) {
                      setState(() => _dragBandFloor = f);
                    }
                  },
                  onLeave: (_) {
                    if (_dragBandFloor != null) {
                      setState(() => _dragBandFloor = null);
                    }
                  },
                  onAcceptWithDetails: (details) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (_dragBandFloor != null) {
                      setState(() => _dragBandFloor = null);
                    }
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
              // F8: the <2-floors dead end now carries the fix as a button
              // (was an IgnorePointer banner that only NAMED the fix).
              if (building.levelCount < 2)
                Positioned.fill(
                  child: Center(
                    child: MechXEmptyStateCard(
                      title: 'Add a floor to place risers',
                      body: context.strings(StringKey.schematicAddFloorBanner),
                      actions: [
                        MechXButton(
                          label: 'Edit floors...',
                          primary: true,
                          onPressed: () => ref
                              .read(shellSectionProvider.notifier)
                              .set(ShellSection.building),
                        ),
                      ],
                    ),
                  ),
                ),
              // Zoom controls (bottom-left). V1: they ease like the Layout's.
              Positioned(
                left: MechXSpacing.md,
                bottom: MechXSpacing.md,
                child: ZoomControls(
                  onIn: () => _animateTo(_current.zoomedBy(
                      1.2, _viewportSize.center(Offset.zero))),
                  onOut: () => _animateTo(_current.zoomedBy(
                      1 / 1.2, _viewportSize.center(Offset.zero))),
                  onFit: () => _animateTo(_fitView()),
                ),
              ),
              // C3: the shared on-demand (?) guide (top-left) — the SAME
              // CanvasGuideButton the Layout / electrical / Auto canvases use,
              // replacing the bespoke _HelpButton / _ElevationHelp.
              Positioned(
                left: MechXSpacing.md,
                top: MechXSpacing.sm,
                child: CanvasGuideButton(
                    open: widget.showHelp, onToggle: widget.onToggleHelp),
              ),
              if (widget.showHelp)
                Positioned(
                  left: MechXSpacing.md,
                  top: 48,
                  child: CanvasGuideLegend(
                    onClose: widget.onToggleHelp,
                    width: 320,
                    // C3 follow-up: keep the Riser's own localized heading.
                    title: context.strings(StringKey.schematicElevationGuide),
                    items: [
                      context.strings(StringKey.schematicHelpModes),
                      context.strings(StringKey.schematicHelp1),
                      context.strings(StringKey.schematicHelp2),
                      context.strings(StringKey.schematicHelp3),
                      context.strings(StringKey.schematicHelp4),
                      context.strings(StringKey.schematicHelp5),
                      context.strings(StringKey.schematicHelp6),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// R4 — the Riser → Edit elevation's world frame: x from
/// `min(0, leftmost diagram x − margin)` to `max(minWidth, rightmost + margin)`
/// (every node at its diagram x — the override, else the plan x), y over the
/// floor bands. A building drawn inside the historical 0..1200 frame keeps it
/// exactly.
Rect _elevationContentRect(
  Network net,
  SchematicLayoutState layout,
  int levelCount, {
  required double bandWorldH,
  required double minWidth,
  required double margin,
}) {
  var left = 0.0;
  var right = minWidth;
  for (final n in net.nodes) {
    final x = layout.xFor(n);
    if (!x.isFinite) continue;
    left = math.min(left, x - margin);
    right = math.max(right, x + margin);
  }
  return Rect.fromLTRB(left, 0, right, bandWorldH * math.max(1, levelCount));
}

/// [ViewportTransform.fit] for a world [content] rect that need not start at
/// the origin.
ViewportTransform _fitRect(Rect content, Size viewport, {double padding = 12}) {
  final t = ViewportTransform.fit(content.size, viewport, padding: padding);
  return ViewportTransform(
      scale: t.scale, offset: t.offset - content.topLeft * t.scale);
}

/// V5 — the riser edges a marquee [rect] (screen space) captures: legs fully
/// inside it when [window] (a left-to-right drag), else every leg it touches
/// (crossing, right-to-left). [worldOf] maps a node to its SCREEN position.
@visibleForTesting
Set<String> riserIdsInScreenRect(
  Network net,
  Rect rect, {
  required bool window,
  required Offset Function(NetNode node) worldOf,
}) {
  final hit = <String>{};
  for (final e in net.edges) {
    if (e.kind != EdgeKind.riser) continue;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    final pa = worldOf(a);
    final pb = worldOf(b);
    // The riser's vertical leg sits at the FROM node's diagram x (the painter's
    // L-route mid-x equals it whenever both ends share a column).
    final top = Offset(pa.dx, math.min(pa.dy, pb.dy));
    final bot = Offset(pa.dx, math.max(pa.dy, pb.dy));
    final captured = window
        ? rect.contains(top) && rect.contains(bot)
        : Rect.fromPoints(top, bot).inflate(3).overlaps(rect);
    if (captured) hit.add(e.id);
  }
  return hit;
}

/// R2 — the bare `main` junctions a riser delete would leave orphaned (every
/// edge they touch is being deleted), so a keyboard delete of N risers prunes
/// their endpoints exactly as the single-riser delete always did.
@visibleForTesting
Set<String> orphanedRiserEndpoints(Network net, Set<String> edgeIds) {
  final out = <String>{};
  for (final id in edgeIds) {
    final e = net.edgeById(id);
    if (e == null) continue;
    for (final nid in [e.fromId, e.toId]) {
      final n = net.nodeById(nid);
      if (n == null || n.role != NodeRole.main) continue;
      if (net.edgesAt(nid).every((x) => edgeIds.contains(x.id))) out.add(nid);
    }
  }
  return out;
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
  if (s.service.regime == FlowRegime.air) {
    // A rectangular duct's `diameter` is only its circular equivalent — print
    // the real W x H (mirrors the engine riser export + the plan `_sizeLabel`).
    return s.isRectangular
        ? '${s.width!.inMillimeters.round()}x${s.height!.inMillimeters.round()}'
        : 'O$mm';
  }
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

/// Round 26 (riser-drafting-3-1) — a riser flow-arrow triangle whose APEX is
/// [tip]: for an up arrow the base sits [h] below the apex (screen y grows
/// downward), for a down arrow [h] above it. Shared by the Auto and Edit
/// painters (both used to draw the base on the wrong side).
@visibleForTesting
Path riserArrowPath(Offset tip, {required bool pointUp, double h = 6, double w = 4}) {
  final baseY = pointUp ? tip.dy + h : tip.dy - h;
  return Path()
    ..moveTo(tip.dx, tip.dy)
    ..lineTo(tip.dx - w, baseY)
    ..lineTo(tip.dx + w, baseY)
    ..close();
}

/// Round 26 (riser-drafting-3-1) — whether a riser's flow arrow points UP on
/// screen: from the SOLVED flow direction (`EdgeSizing.flowFromId`, the same
/// basis the issued sheet's chevron reads — a drainage stack flows DOWN, a
/// transfer riser UP) and only from the drawing direction when unsized.
@visibleForTesting
bool riserFlowGoesUp(NetEdge edge, Offset from, Offset to, EdgeSizing? s) {
  final flowFrom = s?.flowFromId;
  if (flowFrom == edge.toId) return from.dy < to.dy;
  return to.dy < from.dy;
}

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
///
/// Round 26 — the layout lives inside a FRAME: x in [[left], width − [right]]
/// (the floor-label / fan-out gutter on the left, the detail column on the
/// right — riser-drafting-3-2 / 3-8) and the bands over [bandsHeight] (the
/// bottom detail callouts sit below the ground band). Coincident nodes are
/// spread apart by the SHARED B5 rule ([coincidentSpreadDx], riser-drafting-
/// 3-3), exactly as the issued sheet does. Defaults = the legacy full-surface
/// layout.
Map<String, Offset> _autoNodePositions(
    Network network, int levelCount, Size size,
    {ServiceType? focus,
    double left = _kAutoSidePad,
    double right = _kAutoSidePad,
    double? bandsHeight}) {
  final n = levelCount.clamp(1, 999999);
  final h = bandsHeight ?? size.height;
  double bandCentreY(int floorIndex) {
    final bandH = h / n;
    return bandH * ((n - 1) - floorIndex) + bandH / 2;
  }

  final norm = riserLayoutPositions(network, focus: focus);
  // Round 14 (drafting-visual-3) — the SAME per-service lanes the export
  // draws (`riserServiceLanes`), scaled to this band by the shared
  // kRiserLaneBandFraction, so the canvas offsets the same share of a floor.
  final lanes = riserServiceLanes(network, focus: focus);
  final lanePitch = (h / n) * kRiserLaneBandFraction;
  final drawWidth = math.max(0.0, size.width - left - right);
  final positions = <String, Offset>{};
  for (final entry in norm.entries) {
    final node = network.nodeById(entry.key);
    if (node == null) continue;
    positions[entry.key] = Offset(
      left + entry.value * drawWidth,
      bandCentreY(node.floorIndex) + (lanes[entry.key] ?? 0) * lanePitch,
    );
  }
  final spread = coincidentSpreadDx(
    x: {for (final e in positions.entries) e.key: e.value.dx},
    floorOf: {
      for (final id in positions.keys) id: network.nodeById(id)!.floorIndex,
    },
    step: _kAutoSpreadStep,
  );
  for (final e in spread.entries) {
    final p = positions[e.key]!;
    positions[e.key] = Offset(p.dx + e.value, p.dy);
  }
  return positions;
}

/// Round 26 — the canvas B5 coincident-spread step (px): one node glyph box
/// (20 px) plus a hairline, the canvas counterpart of the export's 18-unit
/// step.
const double _kAutoSpreadStep = 24;

/// Round 26 (riser-drafting-3-2) — the right reserve (px) for the bottom-right
/// system-NOTES card / title block (their 240 px max width + the md inset).
const double _kAutoNotesReserve = 256;

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
    // P1 — through the indexed incidence (`Network.edgesAt`), never a scan of
    // every edge per node.
    bool drawnRiser(NetNode n, int otherFloor) => network.edgesAt(n.id).any((e) {
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
// R2: pure label-collision helpers (live Auto-riser canvas)
//
// The Auto painter stamps three families of text on one surface: the floor
// gutter labels ("Ground  FFL +0.00"), the per-floor fan-out stub labels
// ("Water outlet") and the run/riser pipe tags ("15-CW-PPR-GRAVITASI").
// Without arbitration the tags overpaint the gutter. These helpers are the
// arbiter: a DETERMINISTIC, framework-free estimate-nudge pass —
//
//   1. [estimateLabelRect] boxes a label from its CHARACTER COUNT × a per-size
//      advance (no TextPainter, so the geometry is pure and unit-testable and
//      matches the export side's `kElectricalRiserLabelCharW` idiom);
//   2. [runLabelNudgeCandidates] enumerates a BOUNDED, ordered candidate list —
//      in place, then stepped ALONG the run (both ways), then flipped to the
//      run's OTHER SIDE, then stepped along that side;
//   3. [resolveLabelDisplacement] picks the first clear candidate, or — when
//      every candidate still collides — the LEAST-overlapping one, so a label
//      is nudged, never dropped and never randomly placed.
//
// The live canvas only: the vector EXPORT has its own placer (the engine's
// `_RiserLabelPlacer`), which this deliberately does not touch.
// ---------------------------------------------------------------------------

/// Per-character horizontal advance of an on-canvas Roboto label, as a fraction
/// of its font size. Mirrors the engine export placer's
/// `kElectricalRiserLabelCharW` (0.6) so the canvas and the issued sheet reason
/// about label width the same way. // VERIFY: a drafting declutter heuristic
/// (uppercase tag text runs a little wide of Roboto's mixed-case average), not a
/// standard.
const double kSchematicLabelCharW = 0.6;

/// Line height of an on-canvas Roboto label, as a fraction of its font size.
const double kSchematicLabelLineH = 1.3;

/// The estimated bounding box of [text] drawn at [anchor] in [fontSize], grown
/// by [pad] on every side. [centered] mirrors the painter's centred-text idiom
/// (the anchor is the label's horizontal MIDDLE); otherwise [anchor] is the
/// top-left origin, exactly as `Canvas`/`TextPainter.paint` treats it.
///
/// Width = `text.length × fontSize × kSchematicLabelCharW`, height =
/// `fontSize × kSchematicLabelLineH` — a char-count estimate, deliberately not
/// a laid-out measurement, so the collision pass stays pure and deterministic.
Rect estimateLabelRect(
  String text,
  Offset anchor,
  double fontSize, {
  bool centered = false,
  double pad = 1.0,
}) {
  final w = text.length * fontSize * kSchematicLabelCharW;
  final h = fontSize * kSchematicLabelLineH;
  final left = centered ? anchor.dx - w / 2 : anchor.dx;
  return Rect.fromLTWH(left - pad, anchor.dy - pad, w + 2 * pad, h + 2 * pad);
}

/// True when [rect] overlaps any rect in [occupied]. Zero-area rects never
/// overlap (`Rect.overlaps` semantics), so an empty label is always "clear".
bool rectHitsAny(Rect rect, List<Rect> occupied) =>
    occupied.any((r) => r.overlaps(rect));

/// The area of the intersection of [a] and [b] — 0 when they don't overlap.
/// Used to rank candidate placements when none is fully clear.
double rectOverlapArea(Rect a, Rect b) {
  final w = math.min(a.right, b.right) - math.max(a.left, b.left);
  final h = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  if (w <= 0 || h <= 0) return 0;
  return w * h;
}

/// Total area of [rect] covered by [occupied] (double-counting overlaps between
/// occupied rects — a ranking score, not an exact union).
double totalOverlapArea(Rect rect, List<Rect> occupied) {
  var sum = 0.0;
  for (final r in occupied) {
    sum += rectOverlapArea(rect, r);
  }
  return sum;
}

/// The unit vector along a run, falling back to horizontal for a degenerate
/// (zero-length) run so a coincident-endpoint edge still gets a sane ladder.
Offset runUnitDirection(Offset runDirection) {
  final len = runDirection.distance;
  if (len < 0.001) return const Offset(1, 0);
  return Offset(runDirection.dx / len, runDirection.dy / len);
}

/// The run's left-hand normal — the unit direction rotated by -90° (in screen
/// coordinates, where +y points DOWN, that is the run's "up" side for a
/// left-to-right run).
Offset runNormal(Offset runDirection) {
  final d = runUnitDirection(runDirection);
  return Offset(d.dy, -d.dx);
}

/// The SIGNED distance [delta] (a label's offset from its run's midpoint) sits
/// off the run, measured along [runNormal] — positive on the run's left-hand
/// side. Feeding this to [runLabelNudgeCandidates] makes the "other side" flip
/// correct for a run drawn in EITHER direction.
double signedPerpendicularOffset(Offset runDirection, Offset delta) {
  final n = runNormal(runDirection);
  return delta.dx * n.dx + delta.dy * n.dy;
}

/// The ORDERED, BOUNDED displacement candidates for a run label that collides.
///
/// [runDirection] is the run's vector (need not be normalised; a zero/degenerate
/// vector falls back to horizontal). [perpendicularOffset] is the signed
/// distance the label already sits off the run — its sign is flipped to reach
/// "the run's other side", so the flip displacement is `-2 × offset` along the
/// run's normal.
///
/// Order (deterministic, no randomness): in place · +1 step along · −1 step
/// along · … ±[steps] · the other side · the other side ±1 step along · …
/// Length is `1 + 2·steps + 1 + 2·steps` — capped by construction.
List<Offset> runLabelNudgeCandidates({
  required Offset runDirection,
  required double perpendicularOffset,
  double step = 14.0,
  int steps = 3,
}) {
  final dir = runUnitDirection(runDirection);
  final flip = runNormal(runDirection) * (-2 * perpendicularOffset);
  final out = <Offset>[Offset.zero];
  for (var i = 1; i <= steps; i++) {
    out.add(dir * (step * i));
    out.add(dir * (-step * i));
  }
  out.add(flip);
  for (var i = 1; i <= steps; i++) {
    out.add(flip + dir * (step * i));
    out.add(flip + dir * (-step * i));
  }
  return out;
}

/// Resolve where to actually draw a label whose un-nudged box is [rect]:
/// the FIRST candidate in [candidates] whose displaced rect clears [occupied],
/// else the candidate with the SMALLEST total overlap (ties → the earliest
/// candidate, so the result is stable). Never returns null — a label is nudged,
/// never dropped.
Offset resolveLabelDisplacement(
  Rect rect,
  List<Rect> occupied,
  List<Offset> candidates,
) {
  if (candidates.isEmpty) return Offset.zero;
  var best = candidates.first;
  var bestScore = double.infinity;
  for (final d in candidates) {
    final moved = rect.shift(d);
    if (!rectHitsAny(moved, occupied)) return d;
    final score = totalOverlapArea(moved, occupied);
    if (score < bestScore) {
      bestScore = score;
      best = d;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Auto-mode painter (the prior read-only diagram)
// ---------------------------------------------------------------------------

/// Test hook: the Auto riser painter's OWN laid-out node positions (the one
/// layout its paint + the inferred-riser hit test share) when [painter] is
/// the Auto schematic painter, else null — a typed seam so a test never
/// reaches the private painter through `dynamic`.
@visibleForTesting
Map<String, Offset>? autoSchematicLayoutPositions(
        CustomPainter? painter, Size size) =>
    painter is _AutoSchematicPainter
        ? painter.layoutNodePositions(size)
        : null;

/// Test hook (P1): the Auto painter's memoized inferred risers for [size] —
/// the SAME list instance until an input changes — or null for another
/// painter.
@visibleForTesting
List<Object>? autoSchematicInferredRisers(CustomPainter? painter, Size size) =>
    painter is _AutoSchematicPainter ? painter.inferredRisers(size) : null;

/// Test hook (R6): the screen rects of every riser / run tag the Riser → Edit
/// painter placed in its LAST paint (cleared at the start of each paint).
@visibleForTesting
final List<({Rect rect, bool riser})> debugEditTagRects = [];

/// R1 / R5 / P1 — the Auto painter's memo of its own derived geometry. A
/// painter instance is rebuilt only when one of its INPUTS changes (the widget
/// memoizes it), so everything derived from those inputs and the laid-out size
/// — the node layout, the R5 world size, the inferred risers — is computed once
/// per (inputs, size) instead of per paint / per hover.
class _AutoLayoutCache {
  Size? layoutSize;
  Map<String, Offset>? layout;
  Size? worldFor;
  Size? world;
  Size? inferredSize;
  List<_InferredRiser>? inferred;
}

/// R5 — the minimum WORLD-space height of one floor band on the Auto riser.
/// The diagram is laid out in a world at least this tall per storey (fit to
/// the window when the building is short — the at-rest render is unchanged —
/// and taller than the window for a tall building), so zooming in reveals
/// legible, fully laid-out bands instead of magnifying a crushed fit. Sized to
/// hold the FFL label + a full fan-out column (24 + 5 rows x 11 px) with air.
const double kAutoRiserMinBandWorldH = 96;

/// R1 test hook — how many times ANY Auto riser painter has painted. A pan /
/// zoom frame must not move it (the diagram sits under a RepaintBoundary and
/// only its Transform changes).
@visibleForTesting
int debugAutoRiserPaintCount = 0;

/// Riser Auto canvas LABEL level of detail. The diagram is painted once in
/// world space and the live pan / zoom is a compositing [Transform.scale]
/// (R1), so without a guard every label simply scales with the view: a
/// zoomed-out building turned its 8–13 px labels into sub-pixel mush, and a
/// deep zoom blew them up to poster size. These two constants + the two pure
/// helpers below are the ONE label LOD for the canvas:
///  * a label whose ON-SCREEN size would fall below
///    [kRiserLabelMinScreenPx] is not drawn at all — a sub-legible smear, not
///    merely small text: the threshold sits BELOW the fit scale of a tall
///    building's 8 px labels (review: at 6 px a 12-storey fit at 0.56x dropped
///    every 8/9 px label and left the pump-set box an empty frame; small-but-
///    present at fit is the pre-LOD behaviour and stays);
///  * above [kRiserLabelMaxZoom] the label is counter-scaled, so its on-screen
///    size stops growing at ~[kRiserLabelMaxZoom]x its design size (the
///    geometry keeps zooming; the text stays a readable annotation).
const double kRiserLabelMinScreenPx = 3.5;
const double kRiserLabelMaxZoom = 2;

/// Quantises a live view [scale] into the LOD bucket the painter is keyed on,
/// so a zoom gesture repaints the (heavy, memoised) diagram only when the
/// bucket changes — never per frame (R1). Between 1x and [kRiserLabelMaxZoom]
/// labels draw at their design size, so the whole band is ONE bucket (1.0 —
/// the resting / fit view is byte-identical); below 1x it steps in 1/16ths;
/// above the cap in quarter-octaves.
double riserLabelZoomBucket(double scale) {
  if (!scale.isFinite || scale <= 0) return 1.0;
  if (scale < 1.0) return math.max(1 / 16, (scale * 16).floorToDouble() / 16);
  if (scale <= kRiserLabelMaxZoom) return 1.0;
  final quarterOctaves =
      ((math.log(scale / kRiserLabelMaxZoom) / math.ln2) * 4).floorToDouble();
  return kRiserLabelMaxZoom * math.pow(2, quarterOctaves / 4).toDouble();
}

/// The font size to paint a [base]-size label at for LOD bucket [zoom], or
/// null when it would be illegibly small on screen (skip it).
double? riserLabelFontSize(double base, double zoom) {
  if (base * zoom < kRiserLabelMinScreenPx) return null;
  if (zoom > kRiserLabelMaxZoom) return base * kRiserLabelMaxZoom / zoom;
  return base;
}

class _AutoSchematicPainter extends CustomPainter {
  _AutoSchematicPainter({
    required this.network,
    required this.sizing,
    required this.building,
    required this.colors,
    this.focus,
    this.inferRisers = false,
    this.downfeed = false,
    this.riserTagsById = const {},
    this.detailByNode = const {},
    this.transferPumpNodeIds = const {},
    this.showDetails = true,
    this.hotWaterRecirc = false,
    this.rightOverlayWidth = 0,
    this.labelZoom = 1.0,
  });

  /// The label LOD bucket ([riserLabelZoomBucket] of the live view scale).
  final double labelZoom;

  final Network network;
  final Map<String, EdgeSizing> sizing;
  final BuildingLevels building;
  final MechXColors colors;

  final _AutoLayoutCache _cache = _AutoLayoutCache();

  /// Round 26 (riser-drafting-3-2) — the width (px) of the screen-fixed
  /// bottom-right overlays (the system-NOTES card / title block) the band
  /// diagram must keep clear of; 0 when neither is shown.
  final double rightOverlayWidth;

  /// Round 17 — the drawn transfer pumps (ground tank -> roof tank), captioned
  /// TRANSFER PUMP in the plant detail; every other mover reads BOOSTER PUMP.
  /// The kW comes from each node's own duty in [detailByNode].
  final Set<String> transferPumpNodeIds;

  /// G2: true when the engine's hot-water RECIRCULATION loop exists (the
  /// `hotWaterRecircProvider` result is non-null). When set — and the network
  /// carries hot-water risers — the supply riser gains a thinner dashed `HWR`
  /// return leg + a recirc-pump glyph. False / no hot-water riser ⇒ nothing.
  final bool hotWaterRecirc;

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

  /// R2: the floor gutter is the diagram's PRIMARY orientation datum
  /// ("Level 1  FFL +4.00"), so it wears the `MechXTypography.label` scale
  /// (13 px / w500) in `textSecondary` — not the 11 px `textMuted` grey that
  /// was near-invisible on the dark canvas. Kept as a constant so
  /// [_floorLabelRects] (the label-collision seed) stays mirrored to
  /// [_paintBands].
  static const double _floorLabelFontSize = 13.0;

  double _bandTopY(int floorIndex, double totalHeight) {
    final n = building.levelCount;
    final bandH = totalHeight / n;
    final invertedIndex = (n - 1) - floorIndex;
    return bandH * invertedIndex;
  }

  /// Round 26 (riser-drafting-3-2) — the height the floor BANDS occupy: the
  /// bottom detail callouts get a reserved strip BELOW the ground band (the
  /// issued sheet keeps its extras outside the band grid) instead of painting
  /// opaque boxes over ground-floor equipment.
  double _bandsHeight(Size size) {
    if (!showDetails) return size.height;
    final callouts = _valveCalloutRects(size);
    if (callouts.isEmpty) return size.height;
    final top = callouts.map((r) => r.top).reduce(math.min);
    return math.max(size.height * 0.5, top - MechXSpacing.sm);
  }

  /// Round 26 (riser-drafting-3-8) — the left GUTTER: wide enough for the
  /// per-floor FFL labels (and, with details on, the fan-out stubs), so a
  /// riser column never strikes through the primary datum labels.
  double _leftGutter(Size size) {
    var right = 0.0;
    for (final r in _floorLabelRects(size)) {
      right = math.max(right, r.right);
    }
    if (showDetails) {
      for (final r in _fanOutLabelRects(size)) {
        right = math.max(right, r.right);
      }
    }
    return math.min(
        size.width * 0.4, math.max(_kAutoSidePad, right + MechXSpacing.md));
  }

  /// Round 26 (riser-drafting-3-2) — the right reserve: the PUMP-SET DETAIL
  /// column (top-right) and the notes / title-block overlays (bottom-right)
  /// sit OUTSIDE the band drawing width, never over equipment.
  double _rightReserve(Size size, double left) {
    var r = rightOverlayWidth;
    if (showDetails) {
      final pd = _plantDetailRect(size);
      if (pd != null) r = math.max(r, size.width - pd.left);
    }
    final right = r <= 0 ? _kAutoSidePad : r + MechXSpacing.md;
    // A too-narrow surface keeps the legacy span rather than crushing the
    // diagram to nothing.
    if (size.width - left - right < size.width * 0.3) return _kAutoSidePad;
    return right;
  }

  /// The laid-out position of every visible node (the ONE layout the painter
  /// and the widget's inferred-riser hit test share). Memoized per [size].
  Map<String, Offset> layoutNodePositions(Size size) {
    final c = _cache;
    if (c.layout != null && c.layoutSize == size) return c.layout!;
    final left = _leftGutter(size);
    c.layoutSize = size;
    return c.layout = _autoNodePositions(network, building.levelCount, size,
        focus: focus,
        left: left,
        right: _rightReserve(size, left),
        bandsHeight: _bandsHeight(size));
  }

  /// R5 — the WORLD size the diagram lays out in for a [viewport]: the
  /// viewport itself whenever every floor band is at least
  /// [kAutoRiserMinBandWorldH] tall (so a short building renders exactly as
  /// before), else the viewport grown just enough in height that it is. The
  /// band height depends on the reserved bottom callout strip, which depends
  /// on the size, so the growth is settled in a couple of passes. Memoized.
  Size worldSizeFor(Size viewport) {
    final c = _cache;
    if (c.world != null && c.worldFor == viewport) return c.world!;
    var world = viewport;
    if (!viewport.isEmpty) {
      final n = building.levelCount.clamp(1, 999999);
      for (var pass = 0; pass < 4; pass++) {
        final bandH = _bandsHeight(world) / n;
        if (bandH >= kAutoRiserMinBandWorldH - 0.01) break;
        world = Size(
            world.width, world.height + (kAutoRiserMinBandWorldH - bandH) * n);
      }
    }
    c.worldFor = viewport;
    return c.world = world;
  }

  /// P1 — the inferred risers for the layout at [size], memoized (the hover
  /// hit test asked for them on every mouse move).
  List<_InferredRiser> inferredRisers(Size size) {
    final c = _cache;
    if (c.inferred != null && c.inferredSize == size) return c.inferred!;
    c.inferredSize = size;
    return c.inferred =
        _computeInferredRisers(network, layoutNodePositions(size), focus);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    debugAutoRiserPaintCount++;
    final nodePos = layoutNodePositions(size);
    _paintBands(canvas, size);
    if (inferRisers) _paintInferredRisers(canvas, size);
    // F6/R2: seed the label-collision list BEFORE any tag places, in the order
    // the diagram's fixed furniture wins: the per-floor FFL gutter labels, the
    // per-floor fan-out stub labels, and (R3) the detail-callout boxes, whose
    // rects are all computable up front. The edge pass then accumulates its own
    // placed rects so run tags don't stack on each other either.
    final occupied = _floorLabelRects(size);
    if (showDetails) {
      occupied
        ..addAll(_fanOutLabelRects(size))
        ..addAll(_detailCalloutRects(size));
    }
    // Round 26 (riser-drafting-3-4 / 3-5) — the fixed geometry every tag must
    // dodge is seeded BEFORE the edge pass: each node's glyph halo, each HWR
    // return column + label, then the node labels themselves (placed through
    // the same collision ladder, so adjacent plant labels never overprint).
    final hwrLegs = hotWaterRecirc
        ? _hotWaterReturnStacks(nodePos)
        : const <({double x, double yTop, double yBot})>[];
    for (final leg in hwrLegs) {
      occupied
        ..add(Rect.fromLTRB(leg.x - 3, leg.yTop, leg.x + 3, leg.yBot))
        ..add(estimateLabelRect('HWR',
            Offset(leg.x + 5, (leg.yTop + leg.yBot) / 2 - MechXSpacing.sm), 9));
    }
    for (final e in nodePos.entries) {
      final r = _nodeGlyphRect(e.key, e.value);
      if (r != null) occupied.add(r);
    }
    final nodeLabels = _placeNodeLabels(nodePos, occupied);
    _paintEdges(canvas, nodePos, occupied,
        lanePitch: (_bandsHeight(size) / building.levelCount.clamp(1, 999999)) *
            kRiserLaneBandFraction);
    // G2: the hot-water recirculation return leg rides alongside the supply
    // riser — a structural element (drawn whenever the recirc loop exists),
    // not a toggleable detail callout.
    if (hotWaterRecirc) _paintHotWaterReturn(canvas, nodePos, hwrLegs);
    _paintNodes(canvas, nodePos, nodeLabels);
    if (showDetails) {
      _paintFloorFanOut(canvas, size);
      _paintPlantDetail(canvas, size);
      _paintValveCallouts(canvas, size);
      _paintStackDetails(canvas, size, nodePos);
    }
  }

  /// Round 26 (hot-water-2-phantom-hwr-leg-on-drawn-return) — the hot-water
  /// riser STACKS (risers sharing a column) the return leg rides beside: ONE
  /// leg per stack, never one per storey segment. Mirrors the export.
  List<({double x, double yTop, double yBot})> _hotWaterReturnStacks(
      Map<String, Offset> nodePos) {
    if (!(focus == null || focus == ServiceType.hotWater)) return const [];
    const off = 12.0;
    final stacks = <int, ({double x, double yTop, double yBot})>{};
    for (final e in network.edges) {
      if (e.service != ServiceType.hotWater || e.kind != EdgeKind.riser) {
        continue;
      }
      final from = nodePos[e.fromId];
      final to = nodePos[e.toId];
      if (from == null || to == null) continue;
      final midX = (from.dx + to.dx) / 2;
      final key = midX.round();
      final yTop = math.min(from.dy, to.dy);
      final yBot = math.max(from.dy, to.dy);
      final cur = stacks[key];
      stacks[key] = cur == null
          ? (x: midX + off, yTop: yTop, yBot: yBot)
          : (
              x: cur.x,
              yTop: math.min(cur.yTop, yTop),
              yBot: math.max(cur.yBot, yBot),
            );
    }
    return [for (final k in stacks.keys.toList()..sort()) stacks[k]!];
  }

  /// G2: draw the hot-water RECIRCULATION return leg(s) — a thinner dashed
  /// `HWR` return riser beside each hot-water riser STACK, a down arrow
  /// (return flow), and a recirc-pump glyph at the loop base of the WHOLE
  /// network (never beside a pump already drawn on the hot-water service).
  /// Mirrors the export builder's `_emitHotWaterReturn`.
  void _paintHotWaterReturn(Canvas canvas, Map<String, Offset> nodePos,
      List<({double x, double yTop, double yBot})> legs) {
    if (legs.isEmpty) return;
    final color = serviceColor(ServiceType.hotWater);
    const off = 12.0;
    final dashPaint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final leg in legs) {
      final legX = leg.x;
      final midX = legX - off;
      _dashedLine(
          canvas, Offset(legX, leg.yTop), Offset(legX, leg.yBot), dashPaint);
      _dashedLine(
          canvas, Offset(midX, leg.yTop), Offset(legX, leg.yTop), dashPaint);
      // A down arrow — recirculation flow returns to the heater.
      _drawArrow(canvas, Offset(legX, (leg.yTop + leg.yBot) / 2), false, color);
      _drawText(
        canvas,
        'HWR',
        Offset(legX + 5, (leg.yTop + leg.yBot) / 2 - MechXSpacing.sm),
        fontSize: 9,
        color: color,
        fontWeight: FontWeight.w600,
      );
    }
    final hwPumpDrawn = network.nodes.any((n) =>
        (n.component == NodeComponent.pump ||
            n.component == NodeComponent.boosterSet) &&
        network.edgesAt(n.id).any((e) => e.service == ServiceType.hotWater));
    if (hwPumpDrawn) return;
    // The recirc pump glyph at the loop base — the lowest hot-water riser node.
    NetNode? lowest;
    for (final e in network.edges) {
      if (e.service != ServiceType.hotWater || e.kind != EdgeKind.riser) {
        continue;
      }
      for (final id in [e.fromId, e.toId]) {
        final n = network.nodeById(id);
        if (n == null) continue;
        if (lowest == null ||
            n.floorIndex < lowest.floorIndex ||
            (n.floorIndex == lowest.floorIndex &&
                n.id.compareTo(lowest.id) < 0)) {
          lowest = n;
        }
      }
    }
    final lp = lowest == null ? null : nodePos[lowest.id];
    if (lp != null) {
      final px = lp.dx + off;
      const box = 18.0;
      canvas.drawCircle(
          Offset(px, lp.dy), box * 0.62, Paint()..color = colors.canvas);
      canvas.save();
      canvas.translate(px - box / 2, lp.dy - box / 2);
      paintComponentSymbol(
          canvas, const Size(box, box), NodeComponent.pump, color);
      canvas.restore();
      _drawText(
        canvas,
        'HWR PUMP',
        Offset(px + box / 2 + 3, lp.dy - 4),
        fontSize: 8,
        color: colors.textMuted,
        fontWeight: FontWeight.w500,
      );
    }
  }

  /// The bounding rects of the per-floor FFL labels (mirrors [_paintBands]'
  /// geometry) — the seed of the F6 label-collision list.
  List<Rect> _floorLabelRects(Size size) {
    final rects = <Rect>[];
    final bandsH = _bandsHeight(size);
    for (var i = 0; i < building.levelCount; i++) {
      final top = _bandTopY(i, bandsH);
      final floor = building.floors[i];
      final elevM = building.elevationOf(i).meters;
      // E6: the SAME FFL notation the export gutter uses (one shared formatter),
      // so the working canvas and the issued sheet read the elevation identically.
      final label = '${floor.name}  ${fflLabel(elevM)}';
      // R2: the pure char-count estimator (not a TextPainter layout) so every
      // rect in the collision list is produced the same deterministic way.
      rects.add(estimateLabelRect(
        label,
        Offset(_floorLabelX(top), top + MechXSpacing.xs),
        _floorLabelFontSize,
      ));
    }
    return rects;
  }

  /// R2: the estimated rects of the per-floor FAN-OUT stub labels — mirrors
  /// [_paintFloorFanOut]'s geometry exactly (same band pitch, same reserved
  /// (?)-button corner, same row pitch and band-overrun guard) so a run tag is
  /// nudged clear of the gutter stubs instead of printing across them.
  List<Rect> _fanOutLabelRects(Size size) {
    final visible = _focusedNodeIds(network, focus);
    final fans = floorFanOuts(
      network,
      visibleNodeIds: visible,
      labelOf: (n) => _nodeLabel(n) ?? 'Fixture',
    );
    if (fans.isEmpty) return const [];
    final n = building.levelCount;
    final bandsH = _bandsHeight(size);
    final bandH = bandsH / n;
    const stubX = MechXSpacing.sm;
    const rowPitch = 11.0;
    const buttonBottom = MechXSpacing.sm + 26;
    const fontSize = 9.0;
    final rects = <Rect>[];
    for (final fan in fans) {
      if (fan.floorIndex < 0 || fan.floorIndex >= n) continue;
      final top = _bandTopY(fan.floorIndex, bandsH);
      var y = top + 24;
      if (y < buttonBottom + MechXSpacing.xs) y = buttonBottom + MechXSpacing.xs;
      final (rows, overflow) = _fanRows(fan);
      for (final label in rows) {
        if (y + rowPitch > top + bandH) break;
        rects.add(
            estimateLabelRect(label, Offset(stubX + 10, y), fontSize));
        y += rowPitch;
      }
      if (overflow > 0 && y + rowPitch <= top + bandH) {
        rects.add(estimateLabelRect(
            '+$overflow more', Offset(stubX + 10, y), fontSize));
      }
    }
    return rects;
  }

  /// R3: the rects of the DETAIL CALLOUT boxes — the top-right PUMP-SET DETAIL
  /// and the bottom-centre valve/drainage assemblies. Both are computable before
  /// any label places (their geometry depends only on [size] + the has()-gating),
  /// so seeding them means a run label dodges the box rather than disappearing
  /// under it when the callout paints last.
  List<Rect> _detailCalloutRects(Size size) => [
        ?_plantDetailRect(size),
        ..._valveCalloutRects(size),
      ];

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
  void _paintInferredRisers(Canvas canvas, Size size) {
    for (final r in inferredRisers(size)) {
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

    final bandsH = _bandsHeight(size);
    for (var i = 0; i < building.levelCount; i++) {
      final top = _bandTopY(i, bandsH);
      canvas.drawLine(Offset(0, top), Offset(size.width, top), gridPaint);

      final floor = building.floors[i];
      final elevM = building.elevationOf(i).meters;
      // E6: shared FFL formatter — same term + precision as the exported gutter.
      final label = '${floor.name}  ${fflLabel(elevM)}';

      // Keep the floor label clear of the top-left (?) guide button: on a
      // compressed surface the topmost band's label would otherwise paint under
      // it (e.g. "Level 1 +4.0 m" behind the button). When the label row falls
      // within the button's height, start it just right of the button instead
      // of at the gutter edge.
      final labelY = top + MechXSpacing.xs;
      final labelX = _floorLabelX(top);

      _drawText(
        canvas,
        label,
        Offset(labelX, labelY),
        fontSize: _floorLabelFontSize,
        // R2: textSecondary at the label scale — legible on the near-black
        // canvas in dark mode (and its light-mode tier reads equally on paper
        // white); textMuted stays for tertiary detail stubs only.
        color: colors.textSecondary,
        fontWeight: FontWeight.w500,
        maxWidth: size.width / 2,
      );
    }

    canvas.drawLine(Offset(0, bandsH), Offset(size.width, bandsH), gridPaint);
  }

  /// The FFL label's x for a band whose top is [top]: clear of the top-left
  /// (?) guide button when the label row falls within its height (the ONE
  /// rule [_paintBands] and [_floorLabelRects] share).
  double _floorLabelX(double top) {
    final labelY = top + MechXSpacing.xs;
    const buttonBottom = MechXSpacing.sm + 26; // button: top=sm, 26px tall
    return labelY < buttonBottom + MechXSpacing.xs
        ? MechXSpacing.md + 26 + MechXSpacing.sm
        : MechXSpacing.sm;
  }

  void _paintEdges(
      Canvas canvas, Map<String, Offset> nodePos, List<Rect> occupied,
      {required double lanePitch}) {
    // Round 17 (drafting-visual-3-1) — each run on its own service lane even
    // between multi-service nodes (the SAME shared helper the export uses).
    final edgeLanes = riserEdgeLaneOffsets(network, focus: focus);
    // F6: label a continuous run ONCE. Group the visible run (non-riser) edges
    // into components connected by a shared node AND carrying the SAME pipe tag,
    // and keep only one representative edge per component to label (a horizontal
    // main split into collinear segments no longer prints its tag three times).
    final runTagOf = <String, String>{};
    for (final e in network.edges) {
      if (e.kind == EdgeKind.riser) continue;
      if (focus != null && e.service != focus) continue;
      if (nodePos[e.fromId] == null || nodePos[e.toId] == null) continue;
      final s = sizing[e.id];
      if (s == null) continue;
      runTagOf[e.id] =
          _pipeTag(s, e,
              function: riserFunctionFor(network, e,
                  downfeed: downfeed, flowFrom: flowFromBySizing(sizing)));
    }
    final runLabelEdgeIds = _dedupRunLabels(nodePos, runTagOf);

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
      final fn = riserFunctionFor(network, edge,
          downfeed: downfeed, flowFrom: flowFromBySizing(sizing));

      if (edge.kind == EdgeKind.riser) {
        final midX = (from.dx + to.dx) / 2;
        final path = Path()
          ..moveTo(from.dx, from.dy)
          ..lineTo(midX, from.dy)
          ..lineTo(midX, to.dy)
          ..lineTo(to.dx, to.dy);
        canvas.drawPath(path, linePaint);

        final arrowY = (from.dy + to.dy) / 2;
        // Round 26 — the SOLVED flow direction (the export's chevron basis),
        // the drawn direction only when unsized.
        final goingUp = riserFlowGoesUp(edge, from, to, sizing[edge.id]);
        _drawArrow(canvas, Offset(midX, arrowY), goingUp, color);

        final s = sizing[edge.id];
        if (s != null) {
          // Round 26 (riser-drafting-3-4) — through the SAME collision pass
          // as the run tags (the issued sheet's _LabelPlacer analogue): two
          // risers spanning one storey gap, or the HWR leg beside a HW
          // riser, no longer overprint each other's tag. Steps run DOWN the
          // riser first, then flip to its other side.
          _placeText(
            canvas,
            _pipeTag(s, edge, function: fn),
            Offset(midX + MechXSpacing.xs, arrowY - MechXSpacing.sm),
            occupied,
            fontSize: _labelFontSize,
            color: color,
            fontWeight: FontWeight.w500,
            runDirection: const Offset(0, 1),
            perpendicularOffset: MechXSpacing.xs,
          );
        }

        // A small boxed riser tag (CW-R1 …) near the riser TOP — nudged clear of
        // the floor label / other tags (F6) rather than printed across them.
        final tag = riserTagsById[edge.id];
        if (tag != null) {
          final topY = math.min(from.dy, to.dy);
          _drawBoxedTag(
            canvas,
            tag,
            Offset(midX, topY + MechXSpacing.sm + 3),
            color,
            occupied,
          );
        }
      } else {
        final laneDy = (edgeLanes[edge.id] ?? 0) * lanePitch;
        if (laneDy.abs() > 0.5) {
          // Off-lane endpoints: drop to the service lane, run, rise back.
          final y = from.dy + laneDy;
          canvas.drawPath(
              Path()
                ..moveTo(from.dx, from.dy)
                ..lineTo(from.dx, y)
                ..lineTo(to.dx, y)
                ..lineTo(to.dx, to.dy),
              linePaint);
        } else {
          canvas.drawLine(from, to, linePaint);
        }
        final s = sizing[edge.id];
        // F6: only the representative edge of a same-tag run carries the label,
        // placed avoiding the occupied rects (floor labels + earlier tags).
        if (s != null && runLabelEdgeIds.contains(edge.id)) {
          final midX = (from.dx + to.dx) / 2;
          final midY = laneDy.abs() > 0.5
              ? from.dy + laneDy
              : (from.dy + to.dy) / 2;
          // R2: the tag sits MechXSpacing.md above the run's midpoint, so its
          // nudge ladder runs ALONG the run first, then flips to the run's other
          // side (below it) — both derived from the drawn geometry, never random.
          _placeText(
            canvas,
            _pipeTag(s, edge, function: fn),
            Offset(midX, midY - MechXSpacing.md),
            occupied,
            fontSize: _labelFontSize,
            color: color,
            fontWeight: FontWeight.w500,
            centered: true,
            runDirection: to - from,
            perpendicularOffset: signedPerpendicularOffset(
                to - from, const Offset(0, -MechXSpacing.md)),
          );
        }
      }
    }
  }

  /// F6: reduce the visible run edges to ONE representative edge per "continuous
  /// run" — a set of edges connected through shared nodes that all carry the same
  /// pipe tag. The representative is the edge whose midpoint is nearest the run's
  /// centroid (so the single label sits mid-run). [runTagOf] holds the tag of
  /// every labelable run edge.
  ///
  /// The union never crosses a PLANT/equipment node (tank, pump, booster, AHU):
  /// a suction pipe and a discharge pipe meeting at a pump or tank are DISTINCT
  /// runs on an issued riser even when their tags read the same, so each keeps
  /// its own size tag (Round 12 review — dropping the BOOSTER suffix had merged
  /// the pump->ground-tank suction into the tank's discharge, leaving it
  /// untagged in golden 09).
  Set<String> _dedupRunLabels(
      Map<String, Offset> nodePos, Map<String, String> runTagOf) {
    if (runTagOf.isEmpty) return const {};
    final parent = <String, String>{for (final id in runTagOf.keys) id: id};
    String find(String x) {
      var r = x;
      while (parent[r] != r) {
        r = parent[r]!;
      }
      var cur = x;
      while (parent[cur] != r) {
        final next = parent[cur]!;
        parent[cur] = r;
        cur = next;
      }
      return r;
    }

    void union(String a, String b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[ra] = rb;
    }

    final byNode = <String, List<NetEdge>>{};
    for (final e in network.edges) {
      if (!runTagOf.containsKey(e.id)) continue;
      (byNode[e.fromId] ??= []).add(e);
      (byNode[e.toId] ??= []).add(e);
    }
    for (final entry in byNode.entries) {
      final node = network.nodeById(entry.key);
      if (node != null &&
          (node.role == NodeRole.plant ||
              node.component?.role == NodeRole.plant)) {
        continue;
      }
      final list = entry.value;
      for (var i = 0; i < list.length; i++) {
        for (var j = i + 1; j < list.length; j++) {
          if (runTagOf[list[i].id] == runTagOf[list[j].id]) {
            union(list[i].id, list[j].id);
          }
        }
      }
    }
    final comps = <String, List<NetEdge>>{};
    for (final e in network.edges) {
      if (!runTagOf.containsKey(e.id)) continue;
      (comps[find(e.id)] ??= []).add(e);
    }
    final reps = <String>{};
    for (final list in comps.values) {
      var cx = 0.0, cy = 0.0;
      for (final e in list) {
        final f = nodePos[e.fromId]!, t = nodePos[e.toId]!;
        cx += (f.dx + t.dx) / 2;
        cy += (f.dy + t.dy) / 2;
      }
      cx /= list.length;
      cy /= list.length;
      var best = list.first;
      var bestD = double.infinity;
      for (final e in list) {
        final f = nodePos[e.fromId]!, t = nodePos[e.toId]!;
        final m = Offset((f.dx + t.dx) / 2, (f.dy + t.dy) / 2);
        final d = (m - Offset(cx, cy)).distanceSquared;
        if (d < bestD) {
          bestD = d;
          best = e;
        }
      }
      reps.add(best.id);
    }
    return reps;
  }

  /// R2: draw [text] at [anchor], nudged clear of every rect in [occupied].
  ///
  /// The candidate ladder comes from the pure [runLabelNudgeCandidates] — in
  /// place, then stepped ALONG the run ([runDirection]), then flipped to the
  /// run's other side ([perpendicularOffset] is the signed distance the anchor
  /// already sits off the run) — and [resolveLabelDisplacement] picks the first
  /// clear one, or the least-overlapping one when the canvas is genuinely full.
  /// A label is therefore always DRAWN (the old pass silently skipped it, so a
  /// crowded riser lost run tags outright). Records the rect it lands in so
  /// later labels avoid it.
  void _placeText(
    Canvas canvas,
    String text,
    Offset anchor,
    List<Rect> occupied, {
    required double fontSize,
    required Color color,
    FontWeight fontWeight = FontWeight.w400,
    bool centered = false,
    double? maxWidth,
    Offset runDirection = const Offset(1, 0),
    double perpendicularOffset = 0,
  }) {
    if (text.isEmpty) return;
    final rect =
        estimateLabelRect(text, anchor, fontSize, centered: centered);
    final delta = resolveLabelDisplacement(
      rect,
      occupied,
      runLabelNudgeCandidates(
        runDirection: runDirection,
        perpendicularOffset: perpendicularOffset,
      ),
    );
    occupied.add(rect.shift(delta));
    _drawText(
      canvas,
      text,
      anchor + delta,
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
      maxWidth: maxWidth,
      centered: centered,
    );
  }

  /// A compact boxed tag (rounded rect, service-colour outline over a canvas
  /// halo fill) centred on [anchor] — used for the riser tags (CW-R1 …). F6: it
  /// nudges DOWN off any occupied rect (the floor label / earlier tags) so it is
  /// never printed across them; a riser tag is always drawn (never skipped) and
  /// records its rect.
  void _drawBoxedTag(Canvas canvas, String text, Offset anchor, Color color,
      List<Rect> occupied) {
    final fontSize = riserLabelFontSize(9, labelZoom);
    if (fontSize == null) return; // illegible at this zoom (LOD)
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: fontSize,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    const padX = 4.0;
    const padY = 2.0;
    Rect rectAt(Offset c) => Rect.fromCenter(
          center: c,
          width: tp.width + padX * 2,
          height: tp.height + padY * 2,
        );
    // R2: a riser tag steps DOWN the riser (its run direction is vertical), and
    // the shared resolver falls back to the least-overlapping step rather than
    // stamping on the last candidate regardless.
    final delta = resolveLabelDisplacement(
      rectAt(anchor),
      occupied,
      const <Offset>[Offset(0, 0), Offset(0, 16), Offset(0, 32), Offset(0, 48)],
    );
    final centre = anchor + delta;
    final rect = rectAt(centre);
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
        canvas, Offset(centre.dx - tp.width / 2, centre.dy - tp.height / 2));
    occupied.add(rect);
  }

  /// Round 26 (riser-drafting-3-1) — the apex IS [tip]; the base sits [h]
  /// BELOW it for an up arrow (screen y grows downward) and above it for a
  /// down arrow. The base used to be drawn on the wrong side, so every riser
  /// arrow pointed the opposite way to its flow.
  void _drawArrow(Canvas canvas, Offset tip, bool pointUp, Color color) {
    final path = riserArrowPath(tip, pointUp: pointUp);
    canvas.drawPath(path, Paint()..color = color);
  }

  /// A representative colour for [node] on the single-line: the focused system
  /// when filtered, else the service of any edge touching the node, else neutral.
  Color _nodeColor(NetNode node) {
    if (focus != null) return serviceColor(focus!);
    // The first incident edge in edge-list order (the indexed incidence —
    // identical to the old full scan, without the O(nodes x edges) cost).
    for (final e in network.edgesAt(node.id)) {
      return serviceColor(e.service);
    }
    return colors.textSecondary;
  }

  /// Nodes carry their schematic symbol — equipment (`paintComponentSymbol`:
  /// pump / tank / AHU / diffuser / valve / drain …), a fixture terminal (a
  /// small down-triangle "drop"), or a plain junction dot — so the single-line
  /// reads like an engineered riser, not a string of anonymous dots.
  /// Round 26 (riser-drafting-3-5) — the opaque halo rect of a node's glyph
  /// (equipment symbol or fixture drop), or null for a plain junction dot.
  /// Seeded into the collision list before any tag places, so a run / riser
  /// tag is never painted under a glyph.
  Rect? _nodeGlyphRect(String id, Offset pos) {
    final node = network.nodeById(id);
    if (node == null) return null;
    if (node.component != null) {
      return Rect.fromCircle(center: pos, radius: 20.0 * 0.62);
    }
    if (node.role == NodeRole.fixture) {
      return Rect.fromCircle(center: pos, radius: 6.0 + 2.5);
    }
    return null;
  }

  /// The label text of a node ('Roof tank · 10 m3'), or null for a junction.
  String? _nodeLabelText(NetNode node) {
    final label = _nodeLabel(node);
    if (label == null) return null;
    final detail = detailByNode[node.id];
    return detail != null ? '$label · $detail' : label;
  }

  /// Round 26 (riser-drafting-3-5) — every node label placed through the
  /// collision ladder (below the glyph, further below, above, then aside),
  /// in a deterministic order (top-to-bottom, left-to-right, then id), each
  /// recorded so adjacent plant labels ('Water meter' / 'Ground tank' /
  /// 'Pump') and the later edge tags never overprint it. Returns each
  /// labelled node's resolved (centred) text origin.
  Map<String, Offset> _placeNodeLabels(
      Map<String, Offset> nodePos, List<Rect> occupied) {
    final ids = nodePos.keys.toList()
      ..sort((a, b) {
        final pa = nodePos[a]!, pb = nodePos[b]!;
        final c = pa.dy.compareTo(pb.dy);
        if (c != 0) return c;
        final d = pa.dx.compareTo(pb.dx);
        return d != 0 ? d : a.compareTo(b);
      });
    const candidates = <Offset>[
      Offset(0, 0),
      Offset(0, 11),
      Offset(0, 22),
      Offset(0, -38),
      Offset(0, -49),
      Offset(48, 0),
      Offset(-48, 0),
      Offset(48, 11),
      Offset(-48, 11),
    ];
    final out = <String, Offset>{};
    for (final id in ids) {
      final node = network.nodeById(id);
      if (node == null) continue;
      final text = _nodeLabelText(node);
      if (text == null) continue;
      final pos = nodePos[id]!;
      final anchor = Offset(pos.dx, pos.dy + 13);
      final rect = estimateLabelRect(text, anchor, 9, centered: true);
      final delta = resolveLabelDisplacement(rect, occupied, candidates);
      occupied.add(rect.shift(delta));
      out[id] = anchor + delta;
    }
    return out;
  }

  void _paintNodes(Canvas canvas, Map<String, Offset> nodePos,
      [Map<String, Offset> labelAt = const {}]) {
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
      final text = node == null ? null : _nodeLabelText(node);
      if (text != null) {
        _drawText(
          canvas,
          text,
          labelAt[entry.key] ?? Offset(pos.dx, pos.dy + 13),
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
    List<(NodeComponent?, String)> items,
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
      if (component == null) {
        // Round 15 — a UNION: two short bars across the run (the export's
        // `unionMarkPrims` convention).
        final p = Paint()
          ..color = color
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke;
        final cx = left + glyph / 2;
        final half = glyph * 0.38;
        for (final dx in const [-2.0, 2.0]) {
          canvas.drawLine(
              Offset(cx + dx, cy - half), Offset(cx + dx, cy + half), p);
        }
      } else {
        canvas.save();
        canvas.translate(left, origin.dy);
        paintComponentSymbol(canvas, Size(glyph, glyph), component, color);
        canvas.restore();
      }
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

  /// G4: whether a drainage/vent reference detail should draw for the active
  /// focus (the combined view or a drainage/vent/rainwater filter).
  bool get _drainageFocus =>
      focus == null ||
      focus == ServiceType.drainage ||
      focus == ServiceType.vent ||
      focus == ServiceType.rainwater;

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

  /// Round 30 — [component] present on the WATER network (an endpoint of a
  /// cold / hot water edge): the pump-set detail never shows a fire pump or a
  /// drainage ejector as the water booster.
  bool _hasWaterComponent(NodeComponent component) {
    final eq = drawnWaterFeedEquipment(network);
    return switch (component) {
      NodeComponent.roofTank => eq.hasRoofTank,
      NodeComponent.groundTank => eq.hasGroundTank,
      NodeComponent.pump || NodeComponent.boosterSet => network.edges.any((e) =>
          (e.service == ServiceType.coldWater ||
              e.service == ServiceType.hotWater) &&
          [e.fromId, e.toId].any((id) => network.nodes
              .any((n) => n.id == id && n.component == component))),
      _ => _hasComponent(component),
    };
  }

  /// (1) PUMP-SET / ROOF-TANK PLANT DETAIL — a compact bordered callout in the
  /// TOP-RIGHT (H101 convention): a roof-tank glyph + capacity, a booster-pump
  /// glyph + duty, and the GRAVITASI / TRANSFER / BOOSTER leg labels. Drawn only
  /// when the network actually has a roof-tank / ground-tank / pump / booster set
  /// (else omitted entirely — honesty), and only on the clean-water view.
  /// R3: the PUMP-SET DETAIL callout's rect — the SINGLE source of that box's
  /// geometry (used both to draw it and to seed the label-collision list), or
  /// null when the callout isn't drawn at all (wrong focus, no plant, or a
  /// viewport too small to hold it).
  Rect? _plantDetailRect(Size size) {
    if (!_waterFocus) return null;
    final hasRoof = _hasWaterComponent(NodeComponent.roofTank);
    final hasGround = _hasWaterComponent(NodeComponent.groundTank);
    final hasPump = _hasWaterComponent(NodeComponent.pump) ||
        _hasWaterComponent(NodeComponent.boosterSet);
    if (!hasRoof && !hasGround && !hasPump) return null;
    const boxW = 250.0;
    // The box is exactly as tall as the rows it draws (Round 26 grew it for
    // the GROUND TANK row; a fixed 150 / 190 px left a roof-tank-only detail
    // two-thirds empty).
    final boxH = _plantDetailHeight(
        hasRoof: hasRoof, hasGround: hasGround, hasPump: hasPump);
    const pad = MechXSpacing.md;
    // Guard a too-narrow / too-short viewport.
    if (size.width < boxW + 2 * pad || size.height < boxH + 2 * pad) return null;
    return Rect.fromLTWH(size.width - boxW - pad, pad, boxW, boxH);
  }

  /// The mover captions the detail prints (ONE source for the height and the
  /// paint) — only the movers this (focused) sheet draws.
  List<String> _plantMoverCaptions() {
    final shown = _focusedNodeIds(network, focus);
    return plantMoverCaptions(network,
        detailByNodeId: detailByNode,
        transferPumpNodeIds: transferPumpNodeIds,
        include: (n) => shown == null || shown.contains(n.id));
  }

  /// The PUMP-SET DETAIL box height from the rows it holds — mirrors the row
  /// arithmetic of [_paintPlantDetail] (title band 24, roof row 22 + 26 gap,
  /// train glyph 22 with its abbrev line, 12 px per mover caption, the leg
  /// label, the ground-tank row) plus a bottom pad.
  double _plantDetailHeight(
      {required bool hasRoof, required bool hasGround, required bool hasPump}) {
    const glyph = 22.0, gl = 16.0, textH = 11.0, padBottom = MechXSpacing.sm;
    var y = 24.0;
    double bottom;
    if (hasRoof) {
      // The GRAVITASI label hangs just below the roof glyph.
      bottom = y + glyph + (downfeed ? 1 + textH : 0);
      y += glyph + 26;
    } else {
      bottom = y;
    }
    if (hasPump) {
      final trainCy = y + glyph / 2;
      final n = _plantMoverCaptions().length;
      // The valve abbreviations under the train.
      bottom = trainCy + gl / 2 + 2 + textH;
      if (n > 0) bottom = trainCy + gl / 2 + 16 + 12 * (n - 1) + textH;
      final hasLeg = (hasGround && hasRoof) || !downfeed;
      final legY = trainCy + gl / 2 + 30 + math.max(0, 12 * (n - 1));
      if (hasLeg) bottom = legY + textH;
      if (hasGround) bottom = legY + 12 + glyph;
    } else if (hasGround) {
      bottom = y + glyph;
    }
    return bottom + padBottom;
  }

  void _paintPlantDetail(Canvas canvas, Size size) {
    final rect = _plantDetailRect(size);
    if (rect == null) return;
    final hasRoof = _hasWaterComponent(NodeComponent.roofTank);
    final hasGround = _hasWaterComponent(NodeComponent.groundTank);
    final hasPump = _hasWaterComponent(NodeComponent.pump) ||
        _hasWaterComponent(NodeComponent.boosterSet);

    final color = serviceColor(ServiceType.coldWater);
    final boxW = rect.width;
    _detailBox(canvas, rect, 'PUMP-SET DETAIL', titleColor: colors.textMuted);

    final cx = rect.left + boxW / 2;
    const glyph = 22.0;
    var y = rect.top + 24;

    // ROOF TANK row (centred) with its capacity + GRAVITASI down-leg label.
    double? roofBottom;
    if (hasRoof) {
      canvas.save();
      canvas.translate(cx - glyph / 2, y);
      paintComponentSymbol(
          canvas, const Size(glyph, glyph), NodeComponent.roofTank, color);
      canvas.restore();
      final m3 = _tankM3(NodeComponent.roofTank);
      _drawText(
        canvas,
        m3 != null ? 'ROOF TANK $m3 m3' : 'ROOF TANK',
        Offset(cx + glyph / 2 + 8, y + glyph / 2 - 6),
        fontSize: 9,
        color: colors.textSecondary,
        fontWeight: FontWeight.w500,
        maxWidth: rect.right - (cx + glyph / 2 + 12),
      );
      if (downfeed) {
        _drawText(
          canvas,
          'GRAVITASI',
          Offset(cx - glyph / 2 - 4, y + glyph + 1),
          fontSize: 8,
          color: color,
          fontWeight: FontWeight.w600,
        );
      }
      roofBottom = y + glyph;
      y += glyph + 26;
    }

    // PUMP row with the suction / discharge VALVE TRAIN (G3): the pump centred,
    // flanked by its real train — suction (GV · STR · FJ) left, discharge (FJ ·
    // CV · GV) right — the safety-critical assembly drawn, not a bare icon.
    if (hasPump) {
      final pumpC = _hasWaterComponent(NodeComponent.boosterSet)
          ? NodeComponent.boosterSet
          : NodeComponent.pump;
      final trainCy = y + glyph / 2;
      if (roofBottom != null) {
        canvas.drawLine(
          Offset(cx, roofBottom),
          Offset(cx, trainCy - glyph / 2),
          Paint()
            ..color = color
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
      }
      // The engine's ONE train (FJ at each pump nozzle, Round 14).
      const train = kPumpSetValveTrain;
      const gap = 32.0;
      const gl = 16.0;
      final firstCx = cx - (train.length - 1) / 2 * gap;
      canvas.drawLine(
        Offset(firstCx - gl / 2, trainCy),
        Offset(firstCx + (train.length - 1) * gap + gl / 2, trainCy),
        Paint()
          ..color = color
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
      for (var i = 0; i < train.length; i++) {
        final (token, abbrev) = train[i];
        final gx = firstCx + i * gap;
        // Halo so the glyph reads over the run line.
        canvas.drawCircle(
            Offset(gx, trainCy), gl * 0.62, Paint()..color = colors.canvas);
        if (token == 'PUMP') {
          canvas.save();
          canvas.translate(gx - (gl + 3) / 2, trainCy - (gl + 3) / 2);
          paintComponentSymbol(canvas, Size(gl + 3, gl + 3), pumpC, color);
          canvas.restore();
        } else if (token == 'FJ') {
          _paintFlexJoint(
              canvas,
              Rect.fromCenter(
                  center: Offset(gx, trainCy), width: gl, height: gl),
              color);
        } else {
          canvas.save();
          canvas.translate(gx - gl / 2, trainCy - gl / 2);
          paintComponentSymbol(
              canvas, const Size(gl, gl), _trainComponent(token), color);
          canvas.restore();
        }
        if (abbrev.isNotEmpty) {
          _drawText(
            canvas,
            abbrev,
            Offset(gx, trainCy + gl / 2 + 2),
            fontSize: 8,
            color: colors.textMuted,
            fontWeight: FontWeight.w500,
            centered: true,
          );
        }
      }
      // Round 17 — ONE caption per drawn mover from the per-node duty map
      // (the SAME engine helper the export uses): a transfer pump reads
      // TRANSFER PUMP with its own kW, never a bare BOOSTER PUMP.
      // Round 32 r2 — only the movers this (focused) sheet draws, as the
      // export does.
      final caps = _plantMoverCaptions();
      var capDy = 0.0;
      for (final cap in caps) {
        _drawText(
          canvas,
          cap,
          Offset(cx, trainCy + gl / 2 + 16 + capDy),
          fontSize: 9,
          color: colors.textSecondary,
          fontWeight: FontWeight.w500,
          centered: true,
        );
        capDy += 12;
      }
      // TRANSFER (ground -> roof lift) only when BOTH tanks exist (Round 12,
      // printed-parity-3 — mirrors the engine callout + legend); else BOOSTER
      // (pump-up) on upfeed.
      final leg = hasGround && hasRoof
          ? 'TRANSFER'
          : (!downfeed ? 'BOOSTER' : null);
      final legY = trainCy + gl / 2 + 30 + (capDy - 12).clamp(0, 999);
      if (leg != null) {
        _drawText(
          canvas,
          leg,
          Offset(cx, legY),
          fontSize: 8,
          color: color,
          fontWeight: FontWeight.w600,
          centered: true,
        );
      }
      // Round 26 (riser-drafting-3-7) — the GROUND TANK the pump draws from,
      // with its real capacity, under the train (the export's callout row).
      if (hasGround) {
        final gy = math.min(legY + 12, rect.bottom - glyph - 4);
        canvas.save();
        canvas.translate(cx - glyph / 2, gy);
        paintComponentSymbol(
            canvas, const Size(glyph, glyph), NodeComponent.groundTank, color);
        canvas.restore();
        final m3 = _tankM3(NodeComponent.groundTank);
        _drawText(
          canvas,
          m3 != null ? 'GROUND TANK $m3 m3' : 'GROUND TANK',
          Offset(cx + glyph / 2 + 8, gy + glyph / 2 - 6),
          fontSize: 9,
          color: colors.textSecondary,
          fontWeight: FontWeight.w500,
          maxWidth: rect.right - (cx + glyph / 2 + 12),
        );
      }
    } else if (hasGround) {
      // A ground tank with no pump drawn: the tank row alone.
      canvas.save();
      canvas.translate(cx - glyph / 2, y);
      paintComponentSymbol(
          canvas, const Size(glyph, glyph), NodeComponent.groundTank, color);
      canvas.restore();
      final m3 = _tankM3(NodeComponent.groundTank);
      _drawText(
        canvas,
        m3 != null ? 'GROUND TANK $m3 m3' : 'GROUND TANK',
        Offset(cx + glyph / 2 + 8, y + glyph / 2 - 6),
        fontSize: 9,
        color: colors.textSecondary,
        fontWeight: FontWeight.w500,
        maxWidth: rect.right - (cx + glyph / 2 + 12),
      );
    }
  }

  /// The [NodeComponent] for a pump-set valve-train token (GV / STR / CV).
  NodeComponent _trainComponent(String token) => switch (token) {
        'GV' => NodeComponent.gateValve,
        'STR' => NodeComponent.strainer,
        'CV' => NodeComponent.checkValve,
        _ => NodeComponent.gateValve,
      };

  /// A FLEXIBLE-JOINT glyph (two flanges + a bellows "W") in [r] — the canvas
  /// counterpart of `planFlexibleJointPrims`, for the pump-set valve train (G3).
  void _paintFlexJoint(Canvas canvas, Rect r, Color color) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    double fx(double f) => r.left + f * r.width;
    double fy(double f) => r.top + f * r.height;
    void ln(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(fx(x1), fy(y1)), Offset(fx(x2), fy(y2)), p);
    ln(0.18, 0.28, 0.18, 0.72);
    ln(0.82, 0.28, 0.82, 0.72);
    ln(0.18, 0.50, 0.35, 0.32);
    ln(0.35, 0.32, 0.50, 0.68);
    ln(0.50, 0.68, 0.65, 0.32);
    ln(0.65, 0.32, 0.82, 0.50);
  }

  // The bottom-centre valve/drainage callout box metrics (shared by the rect
  // builder and the painter, so the seeded rect is the drawn rect).
  static const double _valveBoxW = 156.0;
  static const double _valveBoxH = 64.0;
  static const double _valveGap = MechXSpacing.md;

  /// R3: the rects of the bottom-centre valve/drainage detail callouts —
  /// [_paintValveCallouts]'s geometry, factored out so the same boxes can seed
  /// the label-collision list (the same mechanism as the pump-set callout).
  /// Empty when no box is drawn (nothing gated in, or no room).
  List<Rect> _valveCalloutRects(Size size) {
    final count = _valveCalloutDetails().length;
    if (count == 0) return const [];
    final totalW = count * _valveBoxW + (count - 1) * _valveGap;
    if (size.width < totalW + 320 ||
        size.height < _valveBoxH + 2 * MechXSpacing.md) {
      return const [];
    }
    var left = (size.width - totalW) / 2;
    final top = size.height - _valveBoxH - MechXSpacing.md;
    final rects = <Rect>[];
    for (var i = 0; i < count; i++) {
      rects.add(Rect.fromLTWH(left, top, _valveBoxW, _valveBoxH));
      left += _valveBoxW + _valveGap;
    }
    return rects;
  }

  /// The gated valve/drainage detail boxes (title, glyph row, colour) — one
  /// source shared by [_valveCalloutRects] and [_paintValveCallouts].
  List<(String, List<(NodeComponent?, String)>, Color)> _valveCalloutDetails() {
    final cwColor = serviceColor(ServiceType.coldWater);
    final drColor = serviceColor(ServiceType.drainage);
    final topFloor = building.levelCount - 1;

    // Each box is drawn ONLY when the network carries its key device (G7/G4):
    // WATER METER / PRV SET (clean water), FLOOR DRAIN / VTR (drainage/vent). The
    // combined view shows every applicable box in one centred row.
    final details = <(String, List<(NodeComponent?, String)>, Color)>[
      if (_waterFocus && _hasComponent(NodeComponent.waterMeter))
        ('DETAIL WATER METER', const [
          (NodeComponent.gateValve, 'GV'),
          (NodeComponent.waterMeter, 'WM'),
          (NodeComponent.gateValve, 'GV'),
          // Round 15 — the UNION mark (null), never a gate-valve bow-tie.
          (null, 'U'),
        ], cwColor),
      if (_waterFocus && _hasComponent(NodeComponent.prv))
        ('DETAIL PRV SET', const [
          (NodeComponent.gateValve, 'GV'),
          (NodeComponent.strainer, 'STR'),
          (NodeComponent.prv, 'PRV'),
          (NodeComponent.gateValve, 'GV'),
        ], cwColor),
      if (_drainageFocus && _hasComponent(NodeComponent.floorDrain))
        ('DETAIL FLOOR DRAIN', const [
          (NodeComponent.floorDrain, 'FD'),
          (NodeComponent.cleanout, 'CO'),
        ], drColor),
      if (_drainageFocus &&
          ventTopTerminalIds(network, topFloor: topFloor).isNotEmpty)
        ('DETAIL VTR', const [
          (NodeComponent.airVent, 'VTR'),
        ], drColor),
    ];
    return details;
  }

  /// (2) VALVE-ASSEMBLY CALLOUTS — compact bordered detail boxes at the
  /// BOTTOM-CENTRE (clear of the bottom-left legend + bottom-right title /
  /// notes): a WATER METER set and a PRV set, each a row of valve glyphs + ASCII
  /// abbrevs. Each is drawn ONLY when the network actually carries that
  /// assembly's key device (G7, mirroring the plant detail's has()-gating) — the
  /// meter box when a waterMeter node exists, the PRV box when a prv node exists
  /// — so a project without either shows neither (no boilerplate detail passing
  /// as an as-designed assembly). The glyph is schematic; the abbrev names the
  /// real device (no exact-glyph claim). The present boxes are centred as a
  /// group so a lone detail still reads balanced.
  void _paintValveCallouts(Canvas canvas, Size size) {
    final details = _valveCalloutDetails();
    // R3: the boxes' geometry comes from the ONE shared rect builder (which also
    // seeds the label-collision list) — empty ⇒ nothing gated in, or no room.
    final rects = _valveCalloutRects(size);
    if (rects.length != details.length) return;
    for (var i = 0; i < details.length; i++) {
      final (title, items, c) = details[i];
      final rect = rects[i];
      _detailBox(canvas, rect, title, titleColor: c);
      _drawDetailGlyphRow(
        canvas,
        Offset(rect.left + 12, rect.top + 24),
        items,
        c,
        glyph: 15,
        gap: 32,
      );
    }
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
    // G4: the DRAINAGE TERMINUS — where the soil/waste leaves the building. A
    // generic disposal glyph + 'KE SALURAN PEMBUANGAN'; the destination is NEVER
    // invented (no 'KE STP' / 'KE RIOL KOTA' the model can't confirm).
    if (focus == null ||
        focus == ServiceType.drainage ||
        focus == ServiceType.rainwater) {
      final exitId = _drainageExitNodeId(network);
      final p = exitId == null ? null : nodePos[exitId];
      if (p != null) {
        final c = Offset(p.dx, p.dy + 22);
        _paintSewerTerminus(canvas, c, drainColor);
        _drawText(
          canvas,
          'KE SALURAN PEMBUANGAN',
          Offset(c.dx + 12, c.dy - 4),
          fontSize: 8,
          color: drainColor,
          fontWeight: FontWeight.w600,
        );
      }
    }
  }

  /// The DRAINAGE EXIT node (G4) — the lowest drainage-connected node,
  /// preferring a genuine outlet (a plain main, not a fixture/cleanout branch)
  /// and, among equals, a leaf. Null when there's no drainage. Mirrors the
  /// export builder's `_drainageExitNodeId`.
  String? _drainageExitNodeId(Network net) {
    final touching = <String>{};
    for (final e in net.edges) {
      if (e.service != ServiceType.drainage) continue;
      touching
        ..add(e.fromId)
        ..add(e.toId);
    }
    final nodes = <NetNode>[
      for (final id in touching)
        if (net.nodeById(id) != null) net.nodeById(id)!,
    ];
    if (nodes.isEmpty) return null;
    int drainDegree(String id) => net.edges
        .where((e) =>
            e.service == ServiceType.drainage &&
            (e.fromId == id || e.toId == id))
        .length;
    bool poorExit(NetNode n) =>
        n.role == NodeRole.fixture || n.component == NodeComponent.cleanout;
    nodes.sort((a, b) {
      final byFloor = a.floorIndex.compareTo(b.floorIndex);
      if (byFloor != 0) return byFloor;
      final byExit = (poorExit(a) ? 1 : 0).compareTo(poorExit(b) ? 1 : 0);
      if (byExit != 0) return byExit;
      final byDeg = drainDegree(a.id).compareTo(drainDegree(b.id));
      if (byDeg != 0) return byDeg;
      final byX = a.x.compareTo(b.x);
      return byX != 0 ? byX : a.id.compareTo(b.id);
    });
    return nodes.first.id;
  }

  /// A SEWER / DISCHARGE TERMINUS glyph centred on [c] — the canvas counterpart
  /// of `planSewerTerminusPrims` (a down arrow into a hatched ground line).
  void _paintSewerTerminus(Canvas canvas, Offset c, Color color,
      {double size = 18}) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    double fx(double f) => c.dx + (f - 0.5) * size;
    double fy(double f) => c.dy + (f - 0.5) * size;
    void ln(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(fx(x1), fy(y1)), Offset(fx(x2), fy(y2)), p);
    ln(0.50, 0.10, 0.50, 0.58);
    ln(0.50, 0.58, 0.38, 0.42);
    ln(0.50, 0.58, 0.62, 0.42);
    ln(0.16, 0.66, 0.84, 0.66);
    ln(0.30, 0.66, 0.20, 0.82);
    ln(0.50, 0.66, 0.40, 0.82);
    ln(0.70, 0.66, 0.60, 0.82);
  }

  /// Round 26 (riser-drafting-3-7) — the canvas fan-out rows, GROUPED per
  /// fixture type with a count exactly like the issued sheet (`WC x2`), then
  /// capped at 4 rows with the remaining TYPES counted in a `+N more` row.
  (List<String>, int) _fanRows(FloorFanOut fan) {
    const maxRows = 4;
    final rows = [
      for (final g in fan.groups) g.count > 1 ? '${g.label} x${g.count}' : g.label,
    ];
    if (rows.isEmpty) return (fan.labels, fan.overflow);
    if (rows.length <= maxRows) return (rows, fan.groupOverflow);
    return (
      rows.sublist(0, maxRows),
      rows.length - maxRows + fan.groupOverflow,
    );
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
    final bandsH = _bandsHeight(size);
    final bandH = bandsH / n;
    const stubX = MechXSpacing.sm;
    const rowPitch = 11.0;
    const gutterW = 150.0;
    // E1: the fixed top-left (?) guide button (x:16-42, y:8-34 screen) has no
    // world awareness, so on the TOPMOST band (whose top is y=0) the fan-out
    // stubs would paint under it and be clipped (goldens 09/10 showed a bare
    // "e"/half-eaten "Supply diffuser"). Reserve the corner: start any fan-out
    // row that would fall within the button's height just below it — mirroring
    // the FFL-label offset in _paintBands.
    const buttonBottom = MechXSpacing.sm + 26;
    for (final fan in fans) {
      if (fan.floorIndex < 0 || fan.floorIndex >= n) continue;
      final top = _bandTopY(fan.floorIndex, bandsH);
      // Start below the FFL label (which sits at top + xs and is ~15px tall
      // at the R2 13px label scale), keeping an xs breathing gap.
      var y = top + 24;
      if (y < buttonBottom + MechXSpacing.xs) y = buttonBottom + MechXSpacing.xs;
      final color =
          focus != null ? serviceColor(focus!) : colors.textSecondary;
      final (rows, overflow) = _fanRows(fan);
      for (final label in rows) {
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
      if (overflow > 0 && y + rowPitch <= top + bandH) {
        _drawText(
          canvas,
          '+$overflow more',
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
    // The ONE label LOD (see [riserLabelFontSize]).
    final lodSize = riserLabelFontSize(fontSize, labelZoom);
    if (lodSize == null) return;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: lodSize,
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
      old.transferPumpNodeIds != transferPumpNodeIds ||
      old.showDetails != showDetails ||
      old.hotWaterRecirc != hotWaterRecirc ||
      old.rightOverlayWidth != rightOverlayWidth ||
      old.labelZoom != labelZoom;
}

// ---------------------------------------------------------------------------
// Edit-mode painter — world-space layout under a ViewportTransform
// ---------------------------------------------------------------------------

/// R6 — below this view scale the passive RUN size labels on the Riser → Edit
/// elevation are hidden (level of detail): they are dimmed context for the
/// risers, and at a zoomed-out scale they only crowd the riser labels. Riser
/// labels (the interactive elements) always print.
const double kEditRunLabelMinScale = 0.5;

class _EditSchematicPainter extends CustomPainter {
  const _EditSchematicPainter({
    required this.network,
    required this.sizing,
    required this.building,
    required this.colors,
    required this.transform,
    required this.selectedEdgeIds,
    required this.bandWorldH,
    required this.worldLeft,
    required this.worldRight,
    required this.schematicX,
    this.highlightFloor,
    this.hoverEdgeId,
    this.marquee,
    this.marqueeWindow = true,
    this.mounting = const MountingHeights(),
  });

  final Network network;
  final Map<String, EdgeSizing> sizing;
  final BuildingLevels building;

  /// The project mounting heights — the SAME value the solve sizes on, so the
  /// riser length label equals the solved length (audit water-drainage-8).
  final MountingHeights mounting;
  final MechXColors colors;
  final ViewportTransform transform;

  /// B3 — the DIAGRAM-only x per node id (empty unless a riser was dragged
  /// sideways on this elevation). Plan geometry is never rewritten by that
  /// gesture, so the diagram position lives here instead.
  final Map<String, double> schematicX;

  /// D5: the multi-selected riser edges (highlighted); a single-select is a set
  /// of one.
  final Set<String> selectedEdgeIds;
  final double bandWorldH;

  /// R4 — the world x-extent the floor lines span (the content frame: at least
  /// 0..1200, grown to hold every node).
  final double worldLeft;
  final double worldRight;

  /// B3: the floor band to highlight as the live drop target (the riser base
  /// lands here). Null when no palette card is being dragged over the canvas.
  final int? highlightFloor;

  /// V4: the riser under the cursor — a faint hover halo (gesture-time only).
  final String? hoverEdgeId;

  /// D5: the in-flight marquee rectangle (screen space), or null.
  final Rect? marquee;

  /// V5: the marquee's mode — a WINDOW (left-to-right, solid border) or a
  /// CROSSING (right-to-left, dashed border), the Layout's B26 language.
  final bool marqueeWindow;

  double _bandCentreWorldY(int floorIndex) {
    final inverted = (building.levelCount - 1) - floorIndex;
    return inverted * bandWorldH + bandWorldH / 2;
  }

  Offset _worldOf(NetNode n) =>
      Offset(schematicX[n.id] ?? n.x, _bandCentreWorldY(n.floorIndex));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    debugEditTagRects.clear();
    // R6: every label goes through ONE collision list — the floor gutter
    // labels first (the orientation datum wins), then each node's glyph and
    // label, then the riser / run tags as the edge pass places them.
    final occupied = _paintBands(canvas, size);
    final nodeLabels = _placeNodeLabels(occupied);
    _paintEdges(canvas, occupied);
    _paintNodes(canvas, nodeLabels);
    // D5 / V5: the rubber-band marquee, the Layout canvas's language — a
    // translucent accent fill with a solid (window) or dashed (crossing) edge.
    final m = marquee;
    if (m != null) {
      canvas.drawRect(m, Paint()..color = colors.accent.withAlpha(38));
      final border = Paint()
        ..color = colors.accent
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      if (marqueeWindow) {
        canvas.drawRect(m, border);
      } else {
        for (final (a, b) in [
          (m.topLeft, m.topRight),
          (m.topRight, m.bottomRight),
          (m.bottomRight, m.bottomLeft),
          (m.bottomLeft, m.topLeft),
        ]) {
          _dashedLine(canvas, a, b, border, dash: 5, gap: 3);
        }
      }
    }
  }

  /// Paints the floor lines + gutter labels; returns the labels' rects (the
  /// collision seed).
  List<Rect> _paintBands(Canvas canvas, Size size) {
    final n = building.levelCount;
    final gridPaint = Paint()
      ..color = colors.border.withAlpha(150)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    final rects = <Rect>[];

    // Draw a horizontal floor line at each band's BOTTOM (the floor surface) and
    // a label, all in world coords mapped through the transform.
    for (var i = 0; i < n; i++) {
      final inverted = (n - 1) - i;
      final bandTopWorldY = inverted * bandWorldH;
      final bandBotWorldY = bandTopWorldY + bandWorldH;
      // B3: a translucent fill on the band a drag would drop the riser base on
      // (the drop preview) — obvious BEFORE releasing, and on the top-band case
      // it lights the real (redirected-down) base band rather than misleading.
      if (i == highlightFloor) {
        final tl = transform.worldToScreen(Offset(worldLeft, bandTopWorldY));
        final br = transform.worldToScreen(Offset(worldRight, bandBotWorldY));
        canvas.drawRect(Rect.fromPoints(tl, br),
            Paint()..color = colors.accent.withAlpha(30));
      }
      // Floor surface line at the bottom of the band.
      final leftS = transform.worldToScreen(Offset(worldLeft, bandBotWorldY));
      final rightS = transform.worldToScreen(Offset(worldRight, bandBotWorldY));
      canvas.drawLine(leftS, rightS, gridPaint);

      final floor = building.floors[i];
      final elevM = building.elevationOf(i).meters;
      // E6: shared FFL formatter — same term + precision as the exported gutter.
      final label = '${floor.name}  ${fflLabel(elevM)}';
      final labelAt = transform.worldToScreen(
          Offset(worldLeft + 8, bandBotWorldY - bandWorldH + 8 / transform.scale));
      // R2: ONE floor-gutter idiom across Auto + Edit — the label scale
      // (13 px / w500) in textSecondary, so the primary orientation datum is
      // legible on the dark canvas instead of a dim 12 px textMuted grey.
      _drawText(
        canvas,
        label,
        labelAt,
        fontSize: 13,
        color: colors.textSecondary,
        fontWeight: FontWeight.w500,
        maxWidth: size.width / 2,
      );
      rects.add(estimateLabelRect(label, labelAt, 13));
    }
    // Top line (roof).
    final topLeft = transform.worldToScreen(Offset(worldLeft, 0));
    final topRight = transform.worldToScreen(Offset(worldRight, 0));
    canvas.drawLine(topLeft, topRight, gridPaint);
    return rects;
  }

  /// R6 — each labelled node's resolved (centred) label origin, placed through
  /// the Auto painter's node-label ladder (below the glyph, further below,
  /// above, then aside) in a deterministic order. Seeds [occupied] with every
  /// glyph halo and placed label so the riser tags then dodge them.
  Map<String, Offset> _placeNodeLabels(List<Rect> occupied) {
    final pos = <String, Offset>{
      for (final n in network.nodes) n.id: transform.worldToScreen(_worldOf(n)),
    };
    for (final n in network.nodes) {
      final p = pos[n.id]!;
      if (n.component != null) {
        occupied.add(Rect.fromCircle(center: p, radius: 20.0 * 0.62));
      } else if (n.role == NodeRole.fixture) {
        occupied.add(Rect.fromCircle(center: p, radius: 6.0 + 2.5));
      }
    }
    final ids = pos.keys.toList()
      ..sort((a, b) {
        final pa = pos[a]!, pb = pos[b]!;
        final c = pa.dy.compareTo(pb.dy);
        if (c != 0) return c;
        final d = pa.dx.compareTo(pb.dx);
        return d != 0 ? d : a.compareTo(b);
      });
    const candidates = <Offset>[
      Offset(0, 0),
      Offset(0, 11),
      Offset(0, 22),
      Offset(0, -38),
      Offset(0, -49),
      Offset(48, 0),
      Offset(-48, 0),
      Offset(48, 11),
      Offset(-48, 11),
    ];
    final out = <String, Offset>{};
    for (final id in ids) {
      final node = network.nodeById(id);
      if (node == null) continue;
      final text = _nodeLabel(node);
      if (text == null) continue;
      final p = pos[id]!;
      final anchor = Offset(p.dx, p.dy + 13);
      final rect = estimateLabelRect(text, anchor, 9, centered: true);
      final delta = resolveLabelDisplacement(rect, occupied, candidates);
      occupied.add(rect.shift(delta));
      out[id] = anchor + delta;
    }
    return out;
  }

  /// R6 — draw [text] at [origin] (its top-left, or its centre when
  /// [centered]) displaced to the first collision-free slot of the run label
  /// ladder along [runDirection] (never dropped: the least-overlapping slot
  /// wins when none is clear). A label pushed off its anchor gets a hairline
  /// leader back to [anchor] so it still reads as that run's tag.
  void _placeAndDrawTag(
    Canvas canvas,
    List<Rect> occupied,
    String text,
    Offset origin, {
    required Offset anchor,
    required Offset runDirection,
    required double fontSize,
    required Color color,
    required FontWeight fontWeight,
    required bool riser,
    bool centered = false,
  }) {
    final rect = estimateLabelRect(text, origin, fontSize, centered: centered);
    final delta = resolveLabelDisplacement(
      rect,
      occupied,
      runLabelNudgeCandidates(
        runDirection: runDirection,
        perpendicularOffset:
            signedPerpendicularOffset(runDirection, rect.center - anchor),
      ),
    );
    final placed = rect.shift(delta);
    occupied.add(placed);
    debugEditTagRects.add((rect: placed, riser: riser));
    if (delta.distance > 16) {
      final near = Offset(
        anchor.dx.clamp(placed.left, placed.right),
        anchor.dy.clamp(placed.top, placed.bottom),
      );
      canvas.drawLine(
        anchor,
        near,
        Paint()
          ..color = color.withAlpha(120)
          ..strokeWidth = 0.75,
      );
    }
    _drawText(
      canvas,
      text,
      origin + delta,
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
      centered: centered,
    );
  }

  void _paintEdges(Canvas canvas, List<Rect> occupied) {
    final showRunLabels = transform.scale >= kEditRunLabelMinScale;
    for (final edge in network.edges) {
      final a = network.nodeById(edge.fromId);
      final b = network.nodeById(edge.toId);
      if (a == null || b == null) continue;
      final color = serviceColor(edge.service);
      final selected = selectedEdgeIds.contains(edge.id);

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

      final hovered = !selected && edge.id == hoverEdgeId;
      if (selected || hovered) {
        // Selection halo behind the line — a soft, blurred glow so the
        // selection 'floats' (Apple-soft) rather than reading as a hard band.
        // V4: a hovered riser gets a fainter version of the same glow.
        final halo = Paint()
          ..color = colors.accent.withAlpha(selected ? 64 : 34)
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
        final goingUp = riserFlowGoesUp(edge, fromS, toS, sizing[edge.id]);
        final arrowY = (fromS.dy + toS.dy) / 2;
        final mid = Offset(midX, arrowY);
        _drawArrow(canvas, mid, goingUp, color);

        // Length (elevation delta) + sized diameter label.
        // Round 21 review — the SAME riser-end datum as `edgeLength` (the
        // BOM / report / exported riser), so a gravity stack never prints
        // its old ceiling-datum length here.
        final lengthM =
            riserElevationDelta(edge, a, b, building, mounting).meters;
        final s = sizing[edge.id];
        final lenStr = '${lengthM.toStringAsFixed(1)} m';
        final label = s != null ? '${_sizeLabel(s)} · $lenStr' : lenStr;
        _placeAndDrawTag(
          canvas,
          occupied,
          label,
          mid + const Offset(8, -16),
          anchor: mid,
          runDirection: const Offset(0, 1),
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
          riser: true,
        );
      } else {
        // D3: a plain run/main is INERT in Edit mode (only risers select / size
        // here — _riserAt filters to EdgeKind.riser). Render it visibly PASSIVE
        // — a thin, dimmed, DASHED ghost, like the inferred connectors — so only
        // the interactive risers carry solid full-opacity service ink and
        // nothing inert reads as actionable (was near-identical to a riser).
        final ghost = Paint()
          ..color = color.withAlpha(90)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        _dashedLine(canvas, fromS, toS, ghost);
        final s = sizing[edge.id];
        if (s != null && showRunLabels) {
          final mid = Offset((fromS.dx + toS.dx) / 2, (fromS.dy + toS.dy) / 2);
          _placeAndDrawTag(
            canvas,
            occupied,
            _sizeLabel(s),
            mid + const Offset(0, -14),
            anchor: mid,
            runDirection: toS - fromS,
            fontSize: 10,
            color: color.withAlpha(120),
            fontWeight: FontWeight.w500,
            riser: false,
            centered: true,
          );
        }
      }
    }
  }

  /// Draw a dashed segment from [a] to [b] (D3: the passive-run ghost). A tiny
  /// local copy of the Auto painter's dash helper — kept here so the Edit
  /// painter stays self-contained.
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

  /// A representative colour for [node]: the service of the first edge
  /// touching it in edge-list order (Edit shows every service — no focus), else
  /// neutral. Mirrors the Auto painter's combined-view `_nodeColor`; served by
  /// the indexed incidence, never a scan of every edge per node.
  Color _nodeColor(NetNode node) {
    for (final e in network.edgesAt(node.id)) {
      return serviceColor(e.service);
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
  /// [labelAt] holds each label's R6-resolved origin.
  void _paintNodes(Canvas canvas, Map<String, Offset> labelAt) {
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
          labelAt[node.id] ?? Offset(pos.dx, pos.dy + 13),
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
    canvas.drawPath(riserArrowPath(tip, pointUp: pointUp),
        Paint()..color = color);
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
      old.mounting != mounting ||
      old.colors != colors ||
      old.transform != transform ||
      // The diagram-only riser positions: a drag frame changes only these.
      !mapEquals(old.schematicX, schematicX) ||
      old.worldLeft != worldLeft ||
      old.worldRight != worldRight ||
      old.selectedEdgeIds.length != selectedEdgeIds.length ||
      !old.selectedEdgeIds.containsAll(selectedEdgeIds) ||
      old.highlightFloor != highlightFloor ||
      old.hoverEdgeId != hoverEdgeId ||
      old.marquee != marquee ||
      old.marqueeWindow != marqueeWindow;
}

// ---------------------------------------------------------------------------
// Canvas chrome (banner, zoom controls, help)
// ---------------------------------------------------------------------------

/// The KETERANGAN / legend overlay for the Auto single-line: a flat drafting
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
    ('U', 'Union'),
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
    // V3 (golden rule 8): the legend is drawing CONTENT that rides the export,
    // not navigation chrome — the flat, opaque, hairline `_detailBox` treatment
    // the NOTES card already wears (D8), never Liquid Glass.
    return DecoratedBox(
      decoration: _drawingAnnotationDecoration(colors),
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

/// D8 / V3 — the ONE decoration of every drafting annotation card on the Auto
/// riser (legend, title block, system notes): the flat, opaque, hairline box
/// the painter's `_detailBox` callouts use (radius 4, `colors.canvas` fill, a
/// 1 px `colors.border` stroke, no blur / shadow). They are diagram CONTENT, so
/// golden rule 8 keeps Liquid Glass off them.
BoxDecoration _drawingAnnotationDecoration(MechXColors colors) => BoxDecoration(
      color: colors.canvas,
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      border: Border.all(color: colors.border),
    );

/// The bottom-right TITLE BLOCK overlay for the Auto single-line — a compact
/// drafting-annotation card echoing a real drawing's kop gambar: the project NAME, an
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

    // V3 (golden rule 8): the title block is drawing CONTENT (it rides the
    // export) — flat, opaque, hairline like the NOTES card, never Liquid Glass.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: DecoratedBox(
        decoration: _drawingAnnotationDecoration(colors),
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
/// card that echoes the project inputs that actually exist:
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
///
/// D8: this and the PUMP-SET / valve `_detailBox` callouts are the SAME
/// conceptual thing — a toggleable drafting reference annotation on the
/// issuable single-line (this one gated by the 'Notes' chip, those by
/// 'Details') — but used to render in two unrelated visual systems (this a
/// Liquid-Glass `GlassSurface` with a popover shadow and a large card radius,
/// those flat canvas-painted boxes). Liquid Glass is reserved for persistent
/// NAVIGATION/CONTROL chrome (golden rule 8) — a drafting annotation is
/// DIAGRAM CONTENT, so this card now matches `_detailBox`'s flat, opaque,
/// hairline-bordered treatment instead.
class _SystemNotes extends ConsumerWidget {
  final ServiceType? focus;
  final Network network;
  const _SystemNotes({required this.focus, required this.network});

  // Round 17 follow-up (i18n-residuals-riser-notes-card-english) — every row
  // localizes like the heading. Round 29 (ui-journeys-3-occupancy-two-
  // vocabularies) — the value is the Building input's OWN label (Residential
  // / Office / public / Assembly / mall), never the internal enum name.
  String _occupancyLabel(BuildContext context, Occupancy o) =>
      context.strings(occupancyLabelKey(o));

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
    final peakFlow = ref.watch(supplyPeakFlowProvider);

    // F9: assert '(roof tank)' ONLY when a roofTank actually exists in the
    // network (mirrors the export `_supplyNote`) — the notes must never claim
    // equipment the design doesn't contain.
    // Round 30 — water-network equipment only (a fire pump is not a booster).
    final eq = drawnWaterFeedEquipment(network);
    final hasRoofTank = eq.hasRoofTank;
    // Round 17 — the SAME equipment-gated feed note the export prints.
    final str = context.strings;
    final hasPump = eq.hasPump;
    final hasMeter = eq.hasWaterMeter;
    // The feed line follows the SAME equipment gates as `riserFeedNote`
    // (detailed form), each outcome localized.
    final feedKey = feed != FeedStrategy.downfeed
        ? StringKey.schematicNotesFeedUpfeed
        : hasRoofTank
            ? StringKey.schematicNotesFeedRoofTank
            : hasPump
                ? StringKey.schematicNotesFeedBooster
                : hasMeter
                    ? StringKey.schematicNotesFeedMainsMeter
                    : StringKey.schematicNotesFeedMains;
    final lines = <String>[str(feedKey)];
    final roofM3 = _tankM3(NodeComponent.roofTank);
    if (roofM3 != null) {
      lines.add(str.format(StringKey.schematicNotesRoofTank, {'m3': roofM3}));
    }
    final groundM3 = _tankM3(NodeComponent.groundTank);
    if (groundM3 != null) {
      lines.add(
          str.format(StringKey.schematicNotesGroundTank, {'m3': groundM3}));
    }
    lines.add(str.format(StringKey.schematicNotesOccupancy,
        {'label': _occupancyLabel(context, occupancy)}));
    // Peak design flow is upfeed-only (supplyPeakFlowProvider null on
    // downfeed) and is the BUILDING trunk flow, never an inline booster's
    // partial flow (Round 15 r2). Never
    // fabricate a m3/day figure when no pump flow exists.
    if (peakFlow != null) {
      lines.add(str.format(StringKey.schematicNotesPeakFlow,
          {'lps': peakFlow.inLitersPerSecond.toStringAsFixed(1)}));
    }

    // D8: the SAME flat/opaque/hairline treatment `_detailBox` paints for the
    // PUMP-SET / valve callouts — a small radius (4, not `MechXRadii.card`'s
    // larger one), `colors.canvas` fill, a 1px `colors.border` stroke, no
    // blur/shadow — so this reference annotation reads as the SAME drafting
    // chrome family as the other 'Details'-gated callouts beside it, instead
    // of a mismatched Liquid-Glass popover.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: DecoratedBox(
        decoration: _drawingAnnotationDecoration(colors),
        child: Padding(
          padding: const EdgeInsets.all(MechXSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // R2: the card heading joins the body in the textSecondary tier
              // (the body rows below are already caption/textSecondary — the
              // textMuted heading was the near-invisible bit on the dark
              // canvas); the w600 weight alone keeps the heading/body
              // hierarchy.
              Text(
                context.strings(StringKey.schematicNotes),
                style: type.caption.copyWith(
                    color: colors.textSecondary, fontWeight: FontWeight.w600),
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

// ---------------------------------------------------------------------------
// R1: the riser inspector's read-only SYSTEM summary
// ---------------------------------------------------------------------------

/// R1 — a data-gated, read-only "System" summary section for the Riser
/// workspace's right inspector column (mounted by `_RiserInspectorColumn` in
/// `app_shell.dart` between the FEED STRATEGY section and the help text).
///
/// A PROJECTION of state the Riser view already derives — honest by
/// construction, nothing computed anew:
///
///   * **Services** present on the current diagram focus — the Auto view's
///     system filter ([SchematicViewState.autoFocus]); Edit mode draws every
///     service, so the summary reads unfiltered there.
///   * **Riser count + stack tags** (`CW-R1` …) from the SAME pure [riserTags]
///     helper the Auto painter labels risers with. Co-linear riser edges share
///     one stack tag, so the count is vertical STACKS (how a drafter counts
///     risers), not edges.
///   * **Total riser length** — the sum over riser edges of the §10
///     TRUE-ELEVATION delta of their riser ends ([riserElevationDelta] — the
///     same datum as `edgeLength`, so canvas == BOM == export), exactly the
///     per-riser length the Edit painter prints beside each riser. NEVER a
///     pixel distance (geometry-is-truth).
///
/// Renders NOTHING when the focused diagram has no edges, so a first launch
/// (and the empty inspector golden state) stays byte-identical; each row
/// renders only when its datum exists (no risers ⇒ no riser rows — never a
/// fabricated `0`). Numeric values wear [MechXTypography.tabular] so a live
/// re-solve changes digits without making the column wobble.
///
/// Styling matches the column's flat section idiom ([MechXSectionLabel] +
/// quiet key/value rows) in both light and dark [MechXColors] palettes.
class RiserSystemSummary extends ConsumerWidget {
  const RiserSystemSummary({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network =
        ref.watch(networkControllerProvider.select((s) => s.network));
    final building = ref.watch(projectControllerProvider).building;
    final mounting = ref.watch(mountingProvider);
    // The Auto diagram is focus-filtered; Edit always draws the whole network.
    // R1: only the focus is watched — never the whole view state.
    final focus = ref.watch(schematicViewProvider
        .select((v) => v.mode == SchematicMode.auto ? v.autoFocus : null));

    final edges = [
      for (final e in network.edges)
        if (focus == null || e.service == focus) e,
    ];
    // Data gate: nothing on the diagram ⇒ nothing to summarize (and no stray
    // section header / gap in the column).
    if (edges.isEmpty) return const SizedBox.shrink();

    // Services present, in the canonical ServiceType order (deterministic).
    final present = edges.map((e) => e.service).toSet();
    final services = [
      for (final s in ServiceType.values)
        if (present.contains(s)) serviceLabel(s),
    ].join(' · ');

    // One tag per vertical riser stack. `riserTags` builds its map in a
    // deterministic service-then-x order, so the de-duped values keep that
    // reading order (CW-R1 · CW-R2 · HW-R1 …).
    final tags = ref
        .watch(riserTagsProvider(focus))
        .values
        .toSet()
        .toList(growable: false);

    // Total riser length = Σ |elevation delta| over the focused riser edges —
    // the same derivation the Edit painter labels each riser with (§10).
    var riserEdgeCount = 0;
    var totalRiserM = 0.0;
    for (final e in edges) {
      if (e.kind != EdgeKind.riser) continue;
      final a = network.nodeById(e.fromId);
      final b = network.nodeById(e.toId);
      if (a == null || b == null) continue;
      riserEdgeCount++;
      totalRiserM += riserElevationDelta(e, a, b, building, mounting).meters;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MechXSectionLabel('System'),
        const SizedBox(height: MechXSpacing.xs),
        _kv(context, 'Services', services, maxLines: 2),
        // Round 31 (ui-simplicity-4) — the tags ARE the riser count spelled
        // out, so no separate 'Risers N' row; each tag is an unbreakable chip
        // in a right-aligned wrap (a joined string broke 'D-' / 'R1').
        if (tags.isNotEmpty) _tagsRow(context, tags),
        if (riserEdgeCount > 0)
          _kv(context, 'Riser length', '${totalRiserM.toStringAsFixed(1)} m',
              numeric: true),
        // Trailing gap carried INSIDE the card so the empty (shrunk) state
        // leaves the host column's own spacing untouched.
        const SizedBox(height: MechXSpacing.lg),
      ],
    );
  }

  /// One quiet key/value row — the inspector `_kv` idiom (caption/textMuted
  /// key, right-aligned caption/textSecondary value). The VALUE wins the row
  /// (it may wrap to [maxLines] before eliding); [numeric] values take
  /// [MechXTypography.tabular] fixed-advance figures.
  Widget _kv(BuildContext context, String key, String value,
      {bool numeric = false, int maxLines = 1}) {
    final colors = context.colors;
    final type = context.type;
    final base = numeric ? MechXTypography.tabular(type.caption) : type.caption;
    final valueStyle = base.copyWith(color: colors.textSecondary);
    // Round 31 (ui-simplicity-4) — the key takes its intrinsic width and the
    // VALUE is Expanded, so textAlign.right reaches the card's right edge
    // (a loose Flexible value started at the column's midpoint).
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(key,
              maxLines: 1,
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(width: MechXSpacing.sm),
          Expanded(
            child: Text(value,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: valueStyle),
          ),
        ],
      ),
    );
  }

  /// The riser tags as a right-aligned wrap of unbreakable chips
  /// (`softWrap: false`), so no tag ever splits at its hyphen.
  Widget _tagsRow(BuildContext context, List<String> tags) {
    final colors = context.colors;
    final type = context.type;
    final valueStyle = type.caption.copyWith(color: colors.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tags',
              maxLines: 1,
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(width: MechXSpacing.sm),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: MechXSpacing.xs,
              children: [
                for (var i = 0; i < tags.length; i++)
                  Text(
                    i < tags.length - 1 ? '${tags[i]} ·' : tags[i],
                    key: ValueKey('riser-summary-tag-${tags[i]}'),
                    softWrap: false,
                    maxLines: 1,
                    style: valueStyle,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
