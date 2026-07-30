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
import '../../store/electrical_store.dart' show WorkspaceView, workspaceViewProvider;
import '../../store/history_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/schematic_view_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../../store/solve_store.dart';
import '../canvas/edge_context_menu.dart';
import '../canvas/segment_symbols.dart';
import '../canvas/service_style.dart';
import '../canvas/text_entry_guard.dart';
import '../canvas/viewport.dart';
import '../canvas/zoom_controls.dart';
import '../shell/nav_rail.dart' show ShellSection, shellSectionProvider;
import '../strings/app_strings.dart';
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
import 'schematic_export.dart';

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
/// Only the ephemeral Export-menu-open flag stays widget-local.
class SchematicView extends ConsumerStatefulWidget {
  const SchematicView({super.key});

  @override
  ConsumerState<SchematicView> createState() => _SchematicViewState();
}

class _SchematicViewState extends ConsumerState<SchematicView> {
  /// Whether the Export menu (riser single-line PDF / DXF) is open. Ephemeral
  /// popover interaction state — deliberately NOT sticky (a fresh hop starts
  /// with it closed).
  bool _showExportMenu = false;

  /// Close the export menu and run the chosen export against the live providers
  /// (the file dialog + IO live in `schematic_export.dart`). Awaited so the
  /// guarded export's success/failure feedback completes as part of this call
  /// (every riser export routes through `runExportGuarded`, which owns the
  /// pill/error reporting).
  Future<void> _runExport(
      Future<void> Function(WidgetRef, ServiceType?) action) async {
    final focus = ref.read(schematicViewProvider).autoFocus;
    setState(() => _showExportMenu = false);
    await action(ref, focus);
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
              .watch(networkControllerProvider)
              .network
              .edges
              .map((e) => e.service)
              .toSet(),
          inferRisers: vs.inferRisers,
          showLegend: vs.showLegend,
          showTitleBlock: vs.showTitleBlock,
          showDetails: vs.showDetails,
          showNotes: vs.showNotes,
          onMode: ctrl.setMode,
          onService: ctrl.setService,
          onAutoFocus: ctrl.setAutoFocus,
          onInferRisers: ctrl.setInferRisers,
          onShowLegend: ctrl.setShowLegend,
          onTitleBlock: ctrl.setShowTitleBlock,
          onShowDetails: ctrl.setShowDetails,
          onShowNotes: ctrl.setShowNotes,
          onExport: () => setState(() => _showExportMenu = !_showExportMenu),
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
            // F4: the export menu autofocuses so Esc closes it (it previously
            // closed only by scrim/button).
            child: Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  setState(() => _showExportMenu = false);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: _RiserExportMenu(
                onPdf: () => _runExport(exportMechanicalRiserPdf),
                onDxf: () => _runExport(exportMechanicalRiserDxf),
                onSetPdf: () => _runExport(exportMechanicalRiserSetPdf),
                onSetDxf: () => _runExport(exportMechanicalRiserSetDxf),
              ),
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
  final SchematicMode mode;
  final ServiceType service;
  final ServiceType? autoFocus;
  final Set<ServiceType> presentServices;
  final bool inferRisers;
  final bool showLegend;
  final bool showTitleBlock;
  final bool showDetails;
  final bool showNotes;
  final ValueChanged<SchematicMode> onMode;
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
                    // C2: these are INDEPENDENT on/off toggles (each flips
                    // alone) — a distinct checkbox idiom (never the accent
                    // pill) so they can't be mistaken for the radio groups.
                    _ToggleChip(
                      label: context.strings(StringKey.schematicInferRisers),
                      value: inferRisers,
                      onTap: () => onInferRisers(!inferRisers),
                    ),
                    const SizedBox(width: MechXSpacing.xs),
                    _ToggleChip(
                      label: context.strings(StringKey.schematicLegend),
                      value: showLegend,
                      onTap: () => onShowLegend(!showLegend),
                    ),
                    const SizedBox(width: MechXSpacing.xs),
                    _ToggleChip(
                      label: context.strings(StringKey.schematicTitleBlock),
                      value: showTitleBlock,
                      onTap: () => onTitleBlock(!showTitleBlock),
                    ),
                    const SizedBox(width: MechXSpacing.xs),
                    _ToggleChip(
                      label: context.strings(StringKey.schematicDetails),
                      value: showDetails,
                      onTap: () => onShowDetails(!showDetails),
                    ),
                    const SizedBox(width: MechXSpacing.xs),
                    _ToggleChip(
                      label: context.strings(StringKey.schematicNotes),
                      value: showNotes,
                      onTap: () => onShowNotes(!showNotes),
                    ),
                    // F5: Export is an ACTION, not a toggle — a MechXButton
                    // (matching the electrical toolbar's Export grammar), no
                    // longer a never-selected `_TabButton`. It rides the END of
                    // the scroll strip so the strip keeps the full toolbar width
                    // (the toggles + filter stay reachable on a narrow window).
                    const SizedBox(width: MechXSpacing.sm),
                    Container(width: 1, height: 22, color: colors.border),
                    const SizedBox(width: MechXSpacing.sm),
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
            Flexible(
              // R1: all ten services don't fit the toolbar at a 1440 window, so
              // the chip strip scrolls horizontally with a soft edge fade — but
              // ONLY on an edge that actually has content beyond it (see
              // [_FadeEdgeScrollStrip]). A chip clipped at the viewport edge then
              // reads as scrollable rather than a broken half-word ("Sprinkle"),
              // and a strip that fits renders exactly as an unmasked Row.
              child: _FadeEdgeScrollStrip(
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
            duration: MechXMotion.hover,
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

class _AutoElevationState extends ConsumerState<_AutoElevation> {
  Size _size = Size.zero;
  bool _hoverInferred = false;

  // F2: the Auto diagram now zooms/pans through a ViewportTransform. The IDENTITY
  // transform (scale 1, offset 0) renders the content at the fit-to-viewport base
  // exactly as before, so a default project is byte-identical. The transform is
  // sticky across workspace hops (F7) via [schematicViewProvider].
  ViewportTransform? _transform;

  // Middle-button / trackpad pan tracking.
  bool _panning = false;
  Offset _lastPanPoint = Offset.zero;
  double _lastScale = 1.0;

  /// Click tolerance (px) for hitting a dashed inferred connector.
  static const double _hitTol = 9.0;

  @override
  void initState() {
    super.initState();
    _transform = ref.read(schematicViewProvider).autoTransform;
  }

  ViewportTransform get _current => _transform ?? const ViewportTransform();

  void _emit(ViewportTransform next) {
    if (next == _current) return;
    setState(() => _transform = next);
    ref.read(schematicViewProvider.notifier).setAutoTransform(next);
  }

  List<_InferredRiser> _inferred(Network net, int levels) {
    if (!widget.inferRisers || _size.isEmpty) return const [];
    final pos = _autoNodePositions(net, levels, _size, focus: widget.focus);
    return _computeInferredRisers(net, pos, widget.focus);
  }

  /// Hit-test an inferred connector. [content] is a CONTENT-space point (the
  /// caller maps the screen point through the inverse transform first).
  _InferredRiser? _hit(Offset content, Network net, int levels) {
    _InferredRiser? best;
    var bestD = _hitTol;
    for (final r in _inferred(net, levels)) {
      final d = _distanceToInferred(r, content);
      if (d < bestD) {
        bestD = d;
        best = r;
      }
    }
    return best;
  }

  void _commit(Offset content, Network net, int levels) {
    final r = _hit(content, net, levels);
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
      _emit(_current.zoomedBy(factor, event.localPosition));
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons & kMiddleMouseButton != 0) {
      _panning = true;
      _lastPanPoint = event.localPosition;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_panning) {
      _emit(_current.panned(event.localPosition - _lastPanPoint));
      _lastPanPoint = event.localPosition;
    }
  }

  void _onPointerUp(PointerUpEvent event) => _panning = false;

  void _onScaleStart(ScaleStartDetails details) => _lastScale = 1.0;

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
    if (vt != _current) _emit(vt);
  }

  @override
  Widget build(BuildContext context) {
    final network = ref.watch(networkControllerProvider).network;
    final sizing = ref.watch(sizingProvider);
    final building = ref.watch(projectControllerProvider).building;
    final colors = context.colors;

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
        final vt = _current;
        // The painted single-line, wrapped in the ViewportTransform (identity by
        // default ⇒ byte-identical). The corner overlays below stay screen-fixed.
        final content = ClipRect(
          child: Transform.translate(
            offset: vt.offset,
            child: Transform.scale(
              scale: vt.scale,
              alignment: Alignment.topLeft,
              child: CustomPaint(
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
                  // G2: the hot-water recirculation loop exists when the engine
                  // sizes one (the provider is non-null) — draw the HWR return.
                  hotWaterRecirc:
                      ref.watch(hotWaterRecircProvider) != null,
                ),
              ),
            ),
          ),
        );
        // Wheel + middle-button pan (Listener) and trackpad pinch / drag-pan
        // (GestureDetector). When inferred risers are shown the dashed connectors
        // are CLICKABLE (one tap commits a real sized riser) — the hit-test maps
        // the screen point through the inverse transform into content space.
        final body = Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: MouseRegion(
            cursor: _hoverInferred
                ? SystemMouseCursors.click
                : SystemMouseCursors.grab,
            onHover: !widget.inferRisers
                ? null
                : (e) {
                    final over = _hit(_current.screenToWorld(e.localPosition),
                            network, levels) !=
                        null;
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
                  : (d) => _commit(
                      _current.screenToWorld(d.localPosition), network, levels),
              child: content,
            ),
          ),
        );
        return Stack(
          children: [
            Positioned.fill(child: body),
            // F2: on-canvas zoom controls (bottom-left) — the same cluster the
            // Edit / Layout / electrical canvases show. Fit resets to the
            // identity base (which IS the fit-to-viewport render).
            Positioned(
              left: MechXSpacing.md,
              bottom: MechXSpacing.md,
              child: ZoomControls(
                onIn: () =>
                    _emit(_current.zoomedBy(1.2, _size.center(Offset.zero))),
                onOut: () => _emit(
                    _current.zoomedBy(1 / 1.2, _size.center(Offset.zero))),
                onFit: () => _emit(const ViewportTransform()),
              ),
            ),
            // The KETERANGAN / legend overlay now sits TOP-left (the bottom-left
            // corner is taken by the F2 zoom cluster); a floating-chrome card
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

  // In-flight horizontal riser drag (the grabbed riser).
  String? _draggingRiser;

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

  // F3: the undo snapshot is DEFERRED from pointer-down to the FIRST move of
  // an actual riser drag (the onPanStart semantics the Layout / electrical
  // canvases use) — a plain select-to-inspect click must not push a phantom
  // undo step or clear the redo stack.
  bool _dragSnapshotPending = false;

  /// World-px gap between adjacent floor bands. The vertical axis is laid out by
  /// floor index (true elevation order) at a fixed band height — the riser's
  /// REAL length is still the elevation delta (used for the label + sizing),
  /// this is only the on-screen band spacing.
  static const double _bandWorldH = 160;
  static const double _worldWidth = 1200;

  @override
  void initState() {
    super.initState();
    // F7: restore the sticky viewport if the workspace was hopped away and back.
    _transform = ref.read(schematicViewProvider).editTransform;
  }

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
    // F7: persist so a hop away and back restores this viewport.
    ref.read(schematicViewProvider.notifier).setEditTransform(next);
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
          _draggingRiser = hit;
          _beginRiserDrag(w.dx);
          // The snapshot waits for the first real movement (F3).
          _dragSnapshotPending = true;
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
    final base = <String, double>{};
    for (final id in ref.read(selectionProvider).edgeIds) {
      final e = net.edgeById(id);
      if (e == null || e.kind != EdgeKind.riser) continue;
      final a = net.nodeById(e.fromId);
      if (a != null) base[id] = a.x;
    }
    _dragBaseX = base;
    _dragBaseCursorX = cursorWorldX;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_panning) {
      _emit(_current.panned(event.localPosition - _lastPanPoint));
      _lastPanPoint = event.localPosition;
      return;
    }
    final dragging = _draggingRiser;
    if (dragging != null) {
      // First movement of a genuine drag: NOW record the one undo step for the
      // whole move (moveRiserHorizontal itself never records — live drag).
      if (_dragSnapshotPending) {
        _dragSnapshotPending = false;
        ref.read(networkControllerProvider.notifier).pushUndoSnapshot();
        // K1: throttle the heavy chain during the live riser drag.
        ref.read(dragSessionProvider.notifier).beginDrag();
      }
      final w = _current.screenToWorld(event.localPosition);
      final ctrl = ref.read(networkControllerProvider.notifier);
      final base = _dragBaseX;
      if (base != null && base.isNotEmpty) {
        // D5: move the WHOLE selection by one shared delta (relative x offsets
        // between risers preserved), one undo step.
        final delta = w.dx - _dragBaseCursorX;
        base.forEach((id, x0) => ctrl.moveRiserHorizontal(id, x0 + delta));
      } else {
        ctrl.moveRiserHorizontal(dragging, w.dx);
      }
      return;
    }
    if (_marqueeStart != null) {
      setState(() => _marqueeCurrent = event.localPosition);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _panning = false;
    // K1: close the throttle session on riser-drag release (final refresh).
    if (_draggingRiser != null) {
      ref.read(dragSessionProvider.notifier).endDrag();
    }
    _draggingRiser = null;
    _dragBaseX = null;
    _dragSnapshotPending = false;
    // D5: finalize the marquee → select every riser its box crosses.
    final start = _marqueeStart;
    final current = _marqueeCurrent;
    if (start != null && current != null) {
      final rect = Rect.fromPoints(start, current);
      if (rect.width > 4 || rect.height > 4) _selectRisersInRect(rect);
      setState(() {
        _marqueeStart = null;
        _marqueeCurrent = null;
      });
    }
  }

  /// D5: union of the risers whose on-screen vertical leg crosses the marquee
  /// [rect] (shift extends the current selection, else replaces it).
  void _selectRisersInRect(Rect rect) {
    final net = ref.read(networkControllerProvider).network;
    final levelCount = ref.read(projectControllerProvider).building.levelCount;
    final vt = _current;
    final hit = <String>{};
    for (final e in net.edges) {
      if (e.kind != EdgeKind.riser) continue;
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      final yA = _bandCentreWorldY(a.floorIndex, levelCount);
      final yB = _bandCentreWorldY(b.floorIndex, levelCount);
      final p1 = vt.worldToScreen(Offset(a.x, math.min(yA, yB)));
      final p2 = vt.worldToScreen(Offset(a.x, math.max(yA, yB)));
      if (Rect.fromPoints(p1, p2).inflate(3).overlaps(rect)) hit.add(e.id);
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift) {
      ref.read(selectionProvider.notifier).addMulti(const {}, hit);
    } else {
      ref.read(selectionProvider.notifier).setMulti(const {}, hit);
    }
  }

  void _onScaleStart(ScaleStartDetails details) => _lastScale = 1.0;

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Single-pointer pan only when NOT dragging a riser or drawing a marquee
    // (the Listener handles both); trackpad pinch always zooms.
    if (_draggingRiser != null || _marqueeStart != null) return;
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
    // B4: while a text field owns the keyboard, canvas shortcuts edit TEXT —
    // never the drawing (the shared guard the Layout/electrical canvases use).
    if (isTextEntryFocused()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final mod = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    // F4: undo / redo on the SAME global timeline the Layout canvas drives — a
    // riser drag pushes a snapshot, so it must be poppable from here too.
    if (mod && key == LogicalKeyboardKey.keyZ) {
      HardwareKeyboard.instance.isShiftPressed
          ? ref.read(historyProvider.notifier).redo()
          : ref.read(historyProvider.notifier).undo();
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyY) {
      ref.read(historyProvider.notifier).redo();
      return KeyEventResult.handled;
    }

    // F4: the Esc ladder — close the help popover, else clear a selection, else
    // return to the read-only Auto view.
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

    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
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

  void _onDrop(Offset localScreen) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final building = ref.read(projectControllerProvider).building;
    final target = _dropTarget(localScreen);
    if (target == null) return;
    final floorIndex = target.floorIndex;
    final w = _current.screenToWorld(localScreen);

    final sheetId = _sheetIdForFloor(floorIndex);
    final id = ref.read(networkControllerProvider.notifier).placeRiserAt(
          sheetId,
          floorIndex,
          w.dx,
          building.levelCount,
          service: widget.service,
        );
    if (id != null) {
      ref.read(selectionProvider.notifier).selectEdge(id);
      // B3: a drop on the TOP band has no floor above it, so the riser's base
      // was placed on the floor BELOW (it still spans a real elevation delta up
      // to the top). Say so — a top-band drop otherwise draws a connection one
      // floor off the target, indistinguishable from a correct drop.
      if (target.redirected &&
          floorIndex + 1 < building.levelCount &&
          floorIndex < building.levelCount) {
        final lower = building.floors[floorIndex].name;
        final upper = building.floors[floorIndex + 1].name;
        ref
            .read(statusMessageProvider.notifier)
            .showStatus('Riser to $upper — base on $lower below');
      }
    }
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
      // F4: autofocus on arrival so Delete / Ctrl+Z-Y / Esc work immediately,
      // without first clicking the canvas.
      autofocus: true,
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
                      selectedEdgeIds: selection.edgeIds,
                      bandWorldH: _bandWorldH,
                      worldWidth: _worldWidth,
                      highlightFloor: _dragBandFloor,
                      marquee: (_marqueeStart != null && _marqueeCurrent != null)
                          ? Rect.fromPoints(_marqueeStart!, _marqueeCurrent!)
                          : null,
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
    this.hotWaterRecirc = false,
  });

  final Network network;
  final Map<String, EdgeSizing> sizing;
  final BuildingLevels building;
  final MechXColors colors;

  /// The system supply-pump duty (one trunk pump) — used for the plant-detail
  /// callout's BOOSTER PUMP kW caption. Null ⇒ no kW caption (no fabricated duty).
  final PumpDuty? supplyPump;

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

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final nodePos =
        _autoNodePositions(network, building.levelCount, size, focus: focus);
    _paintBands(canvas, size);
    if (inferRisers) _paintInferredRisers(canvas, nodePos);
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
    _paintEdges(canvas, nodePos, occupied);
    // G2: the hot-water recirculation return leg rides alongside the supply
    // riser — a structural element (drawn whenever the recirc loop exists),
    // not a toggleable detail callout.
    if (hotWaterRecirc) _paintHotWaterReturn(canvas, nodePos);
    _paintNodes(canvas, nodePos);
    if (showDetails) {
      _paintFloorFanOut(canvas, size);
      _paintPlantDetail(canvas, size);
      _paintValveCallouts(canvas, size);
      _paintStackDetails(canvas, size, nodePos);
    }
  }

  /// G2: draw the hot-water RECIRCULATION return leg(s) — a thinner dashed
  /// `HWR` return riser alongside each hot-water supply riser, a down arrow
  /// (return flow), and a recirc-pump glyph at the loop base. Mirrors the export
  /// builder's `_emitHotWaterReturn`.
  void _paintHotWaterReturn(Canvas canvas, Map<String, Offset> nodePos) {
    if (!(focus == null || focus == ServiceType.hotWater)) return;
    final hwRisers = network.edges
        .where((e) =>
            e.service == ServiceType.hotWater &&
            e.kind == EdgeKind.riser &&
            nodePos[e.fromId] != null &&
            nodePos[e.toId] != null)
        .toList();
    if (hwRisers.isEmpty) return;
    final color = serviceColor(ServiceType.hotWater);
    const off = 12.0;
    final dashPaint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final e in hwRisers) {
      final from = nodePos[e.fromId]!;
      final to = nodePos[e.toId]!;
      final midX = (from.dx + to.dx) / 2;
      final legX = midX + off;
      final yTop = math.min(from.dy, to.dy);
      final yBot = math.max(from.dy, to.dy);
      _dashedLine(canvas, Offset(legX, yTop), Offset(legX, yBot), dashPaint);
      _dashedLine(canvas, Offset(midX, yTop), Offset(legX, yTop), dashPaint);
      // A down arrow — recirculation flow returns to the heater.
      _drawArrow(canvas, Offset(legX, (yTop + yBot) / 2), false, color);
      _drawText(
        canvas,
        'HWR',
        Offset(legX + 5, (yTop + yBot) / 2 - MechXSpacing.sm),
        fontSize: 9,
        color: color,
        fontWeight: FontWeight.w600,
      );
    }
    // The recirc pump glyph at the loop base — the lowest hot-water node.
    NetNode? lowest;
    for (final e in hwRisers) {
      for (final id in [e.fromId, e.toId]) {
        final n = network.nodeById(id);
        if (n == null) continue;
        if (lowest == null || n.floorIndex < lowest.floorIndex) lowest = n;
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
    for (var i = 0; i < building.levelCount; i++) {
      final top = _bandTopY(i, size.height);
      final floor = building.floors[i];
      final elevM = building.elevationOf(i).meters;
      // E6: the SAME FFL notation the export gutter uses (one shared formatter),
      // so the working canvas and the issued sheet read the elevation identically.
      final label = '${floor.name}  ${fflLabel(elevM)}';
      // R2: the pure char-count estimator (not a TextPainter layout) so every
      // rect in the collision list is produced the same deterministic way.
      rects.add(estimateLabelRect(
        label,
        Offset(MechXSpacing.sm, top + MechXSpacing.xs),
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
    final bandH = size.height / n;
    const stubX = MechXSpacing.sm;
    const rowPitch = 11.0;
    const buttonBottom = MechXSpacing.sm + 26;
    const fontSize = 9.0;
    final rects = <Rect>[];
    for (final fan in fans) {
      if (fan.floorIndex < 0 || fan.floorIndex >= n) continue;
      final top = _bandTopY(fan.floorIndex, size.height);
      var y = top + 24;
      if (y < buttonBottom + MechXSpacing.xs) y = buttonBottom + MechXSpacing.xs;
      for (final label in fan.labels) {
        if (y + rowPitch > top + bandH) break;
        rects.add(
            estimateLabelRect(label, Offset(stubX + 10, y), fontSize));
        y += rowPitch;
      }
      if (fan.overflow > 0 && y + rowPitch <= top + bandH) {
        rects.add(estimateLabelRect(
            '+${fan.overflow} more', Offset(stubX + 10, y), fontSize));
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
      // E6: shared FFL formatter — same term + precision as the exported gutter.
      final label = '${floor.name}  ${fflLabel(elevM)}';

      // Keep the floor label clear of the top-left (?) guide button: on a
      // compressed surface the topmost band's label would otherwise paint under
      // it (e.g. "Level 1 +4.0 m" behind the button). When the label row falls
      // within the button's height, start it just right of the button instead
      // of at the gutter edge.
      final labelY = top + MechXSpacing.xs;
      const buttonBottom = MechXSpacing.sm + 26; // button: top=sm, 26px tall
      final labelX = labelY < buttonBottom + MechXSpacing.xs
          ? MechXSpacing.md + 26 + MechXSpacing.sm
          : MechXSpacing.sm;

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

    canvas.drawLine(
        Offset(0, size.height), Offset(size.width, size.height), gridPaint);
  }

  void _paintEdges(
      Canvas canvas, Map<String, Offset> nodePos, List<Rect> occupied) {
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
          _pipeTag(s, e, function: riserFunctionFor(network, e, downfeed: downfeed));
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
        canvas.drawLine(from, to, linePaint);
        final s = sizing[edge.id];
        // F6: only the representative edge of a same-tag run carries the label,
        // placed avoiding the occupied rects (floor labels + earlier tags).
        if (s != null && runLabelEdgeIds.contains(edge.id)) {
          final midX = (from.dx + to.dx) / 2;
          final midY = (from.dy + to.dy) / 2;
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
    for (final list in byNode.values) {
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
    final hasRoof = _hasComponent(NodeComponent.roofTank);
    final hasGround = _hasComponent(NodeComponent.groundTank);
    final hasPump = _hasComponent(NodeComponent.pump) ||
        _hasComponent(NodeComponent.boosterSet);
    if (!hasRoof && !hasGround && !hasPump) return null;
    const boxW = 250.0;
    const boxH = 150.0;
    const pad = MechXSpacing.md;
    // Guard a too-narrow / too-short viewport.
    if (size.width < boxW + 2 * pad || size.height < boxH + 2 * pad) return null;
    return Rect.fromLTWH(size.width - boxW - pad, pad, boxW, boxH);
  }

  void _paintPlantDetail(Canvas canvas, Size size) {
    final rect = _plantDetailRect(size);
    if (rect == null) return;
    final hasRoof = _hasComponent(NodeComponent.roofTank);
    final hasGround = _hasComponent(NodeComponent.groundTank);
    final hasPump = _hasComponent(NodeComponent.pump) ||
        _hasComponent(NodeComponent.boosterSet);

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
    // flanked by its real train — suction (GV · STR · FJ) left, discharge (CV ·
    // GV · FJ) right — the safety-critical assembly drawn, not a bare icon.
    if (hasPump) {
      final pumpC = _hasComponent(NodeComponent.boosterSet)
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
      const train = <(String, String)>[
        ('GV', 'GV'),
        ('STR', 'STR'),
        ('FJ', 'FJ'),
        ('PUMP', ''),
        ('CV', 'CV'),
        ('GV', 'GV'),
        ('FJ', 'FJ'),
      ];
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
      final kw = supplyPump != null
          ? '${supplyPump!.selectedMotor.inKiloWatts.toStringAsFixed(1)} kW'
          : null;
      _drawText(
        canvas,
        kw != null ? 'BOOSTER PUMP $kw' : 'BOOSTER PUMP',
        Offset(cx, trainCy + gl / 2 + 16),
        fontSize: 9,
        color: colors.textSecondary,
        fontWeight: FontWeight.w500,
        centered: true,
      );
      // TRANSFER (ground -> roof lift) when a ground tank exists; else BOOSTER
      // (pump-up) on upfeed.
      final leg = hasGround ? 'TRANSFER' : (!downfeed ? 'BOOSTER' : null);
      if (leg != null) {
        _drawText(
          canvas,
          leg,
          Offset(cx, trainCy + gl / 2 + 30),
          fontSize: 8,
          color: color,
          fontWeight: FontWeight.w600,
          centered: true,
        );
      }
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
  List<(String, List<(NodeComponent, String)>, Color)> _valveCalloutDetails() {
    final cwColor = serviceColor(ServiceType.coldWater);
    final drColor = serviceColor(ServiceType.drainage);
    final topFloor = building.levelCount - 1;

    // Each box is drawn ONLY when the network carries its key device (G7/G4):
    // WATER METER / PRV SET (clean water), FLOOR DRAIN / VTR (drainage/vent). The
    // combined view shows every applicable box in one centred row.
    final details = <(String, List<(NodeComponent, String)>, Color)>[
      if (_waterFocus && _hasComponent(NodeComponent.waterMeter))
        ('DETAIL WATER METER', const [
          (NodeComponent.gateValve, 'GV'),
          (NodeComponent.waterMeter, 'WM'),
          (NodeComponent.gateValve, 'GV'),
          (NodeComponent.gateValve, 'U'),
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
    // E1: the fixed top-left (?) guide button (x:16-42, y:8-34 screen) has no
    // world awareness, so on the TOPMOST band (whose top is y=0) the fan-out
    // stubs would paint under it and be clipped (goldens 09/10 showed a bare
    // "e"/half-eaten "Supply diffuser"). Reserve the corner: start any fan-out
    // row that would fall within the button's height just below it — mirroring
    // the FFL-label offset in _paintBands.
    const buttonBottom = MechXSpacing.sm + 26;
    for (final fan in fans) {
      if (fan.floorIndex < 0 || fan.floorIndex >= n) continue;
      final top = _bandTopY(fan.floorIndex, size.height);
      // Start below the FFL label (which sits at top + xs and is ~15px tall
      // at the R2 13px label scale), keeping an xs breathing gap.
      var y = top + 24;
      if (y < buttonBottom + MechXSpacing.xs) y = buttonBottom + MechXSpacing.xs;
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
      old.showDetails != showDetails ||
      old.hotWaterRecirc != hotWaterRecirc;
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
    required this.selectedEdgeIds,
    required this.bandWorldH,
    required this.worldWidth,
    this.highlightFloor,
    this.marquee,
  });

  final Network network;
  final Map<String, EdgeSizing> sizing;
  final BuildingLevels building;
  final MechXColors colors;
  final ViewportTransform transform;

  /// D5: the multi-selected riser edges (highlighted); a single-select is a set
  /// of one.
  final Set<String> selectedEdgeIds;
  final double bandWorldH;
  final double worldWidth;

  /// B3: the floor band to highlight as the live drop target (the riser base
  /// lands here). Null when no palette card is being dragged over the canvas.
  final int? highlightFloor;

  /// D5: the in-flight marquee rectangle (screen space), or null.
  final Rect? marquee;

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
    // D5: the rubber-band marquee, same translucent-accent language as the
    // Layout / electrical canvases.
    final m = marquee;
    if (m != null) {
      canvas.drawRect(m, Paint()..color = colors.accent.withAlpha(28));
      canvas.drawRect(
        m,
        Paint()
          ..color = colors.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
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
      // B3: a translucent fill on the band a drag would drop the riser base on
      // (the drop preview) — obvious BEFORE releasing, and on the top-band case
      // it lights the real (redirected-down) base band rather than misleading.
      if (i == highlightFloor) {
        final tl = transform.worldToScreen(Offset(0, bandTopWorldY));
        final br = transform.worldToScreen(Offset(worldWidth, bandBotWorldY));
        canvas.drawRect(Rect.fromPoints(tl, br),
            Paint()..color = colors.accent.withAlpha(30));
      }
      // Floor surface line at the bottom of the band.
      final leftS = transform.worldToScreen(Offset(0, bandBotWorldY));
      final rightS = transform.worldToScreen(Offset(worldWidth, bandBotWorldY));
      canvas.drawLine(leftS, rightS, gridPaint);

      final floor = building.floors[i];
      final elevM = building.elevationOf(i).meters;
      // E6: shared FFL formatter — same term + precision as the exported gutter.
      final label = '${floor.name}  ${fflLabel(elevM)}';
      final labelAt = transform.worldToScreen(
          Offset(8, bandBotWorldY - bandWorldH + 8 / transform.scale));
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
        if (s != null) {
          final mid = Offset((fromS.dx + toS.dx) / 2, (fromS.dy + toS.dy) / 2);
          _drawText(
            canvas,
            _sizeLabel(s),
            mid + const Offset(0, -14),
            fontSize: 10,
            color: color.withAlpha(120),
            fontWeight: FontWeight.w500,
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
      old.selectedEdgeIds.length != selectedEdgeIds.length ||
      !old.selectedEdgeIds.containsAll(selectedEdgeIds) ||
      old.highlightFloor != highlightFloor ||
      old.marquee != marquee;
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

    // F9: assert '(roof tank)' ONLY when a roofTank actually exists in the
    // network (mirrors the export `_supplyNote`) — the notes must never claim
    // equipment the design doesn't contain.
    final hasRoofTank =
        network.nodes.any((n) => n.component == NodeComponent.roofTank);
    final lines = <String>[
      feed == FeedStrategy.downfeed
          ? (hasRoofTank
              ? 'Feed: gravity downfeed (roof tank)'
              : 'Feed: gravity downfeed')
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

    // D8: the SAME flat/opaque/hairline treatment `_detailBox` paints for the
    // PUMP-SET / valve callouts — a small radius (4, not `MechXRadii.card`'s
    // larger one), `colors.canvas` fill, a 1px `colors.border` stroke, no
    // blur/shadow — so this reference annotation reads as the SAME drafting
    // chrome family as the other 'Details'-gated callouts beside it, instead
    // of a mismatched Liquid-Glass popover.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.canvas,
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          border: Border.all(color: colors.border),
        ),
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
///     TRUE-ELEVATION delta of their endpoints ([nodeElevation]), exactly the
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
    final network = ref.watch(networkControllerProvider).network;
    final building = ref.watch(projectControllerProvider).building;
    final vs = ref.watch(schematicViewProvider);
    // The Auto diagram is focus-filtered; Edit always draws the whole network.
    final focus = vs.mode == SchematicMode.auto ? vs.autoFocus : null;

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
    final tags =
        riserTags(network, focus).values.toSet().toList(growable: false);

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
      totalRiserM += (nodeElevation(b, building).meters -
              nodeElevation(a, building).meters)
          .abs();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MechXSectionLabel('System'),
        const SizedBox(height: MechXSpacing.xs),
        _kv(context, 'Services', services, maxLines: 2),
        if (tags.isNotEmpty)
          _kv(context, 'Risers', '${tags.length}', numeric: true),
        if (tags.isNotEmpty)
          _kv(context, 'Tags', tags.join(' · '), maxLines: 2),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.caption.copyWith(color: colors.textMuted)),
          ),
          const SizedBox(width: MechXSpacing.xs),
          Flexible(
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
}
