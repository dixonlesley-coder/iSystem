import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/autosave.dart';
import '../data/project_assets.dart';
import '../data/recovery.dart';
import '../store/app_state.dart';
import '../store/command_store.dart';
import '../store/design_issues_store.dart';
import '../store/electrical_store.dart';
import '../store/layer_store.dart';
import '../store/project_store.dart';
import '../store/sheets_store.dart';
import '../store/sizing_store.dart';
import '../update/update_banner.dart';
import '../update/version_label.dart';
import 'ai/copilot_panel.dart';
import 'commercial/commercial_hub.dart';
import 'electrical/electrical_palette.dart';
import 'electrical/electrical_view.dart';
import 'inspector/collapsible_inspector.dart';
import 'inspector/project_panel.dart';
import 'layout/layout_canvas.dart';
import 'review/review_hub.dart';
import 'schematic/schematic_view.dart';
import 'shell/building_screen.dart';
import 'shell/command_palette.dart';
import 'shell/nav_rail.dart';
import 'shell/workflow_stepper.dart';
import 'shell/preferences_screen.dart';
import 'shell/project_io.dart';
import 'shell/projects_screen.dart';
import 'sheets/sheet_rail.dart';
import 'strings/app_strings.dart';
import 'theme/design_tokens.dart';
import 'theme/mechx_theme.dart';
import 'widgets/glass_surface.dart';
import 'widgets/mechx_button.dart';
import 'widgets/mechx_focus_ring.dart';
import 'widgets/severity_glyph.dart';

/// Top-level layout (PanelMaker-style chrome): a left navigation rail beside a
/// slim top bar · body · status-bar column. The rail picks the [ShellSection];
/// the body is the workspace (Plan / Schematic / Electrical) or a hub/screen.
/// No Material Scaffold — a restrained, custom shell (§4).
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  /// Global hotkey handler, mounted as a non-focus-stealing ancestor [Focus]
  /// (see [build]). Key events bubble UP from the focused canvas/field to this
  /// node, so Ctrl/Cmd+K opens the command palette without grabbing focus from
  /// in-canvas editing. Esc closes the palette when it's open.
  KeyEventResult _onKey(BuildContext context, WidgetRef ref, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final mod = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (mod && key == LogicalKeyboardKey.keyK) {
      ref.read(commandPaletteOpenProvider.notifier).toggle();
      return KeyEventResult.handled;
    }
    // Document-app save/open conventions: Ctrl/Cmd+S saves in place (Shift
    // forces Save-As), Ctrl/Cmd+O opens — matching every desktop authoring
    // tool a CAD engineer is trained on. Open guards unsaved work, so it needs
    // the shell context to host the confirm dialog.
    if (mod && key == LogicalKeyboardKey.keyS) {
      saveProject(ref, saveAs: HardwareKeyboard.instance.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyO) {
      openProject(context, ref);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape &&
        ref.read(commandPaletteOpenProvider)) {
      ref.read(commandPaletteOpenProvider.notifier).close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    // First-auto-size nudge (J2): fires once per session, the moment the live
    // sizing solve goes from empty to non-empty. Note: OPENING a project whose
    // network sizes on load is also a genuine empty→non-empty transition, so
    // the (one-shot) nudge fires there too — acceptable, since the sizes shown
    // on the plan really were just auto-computed. AppShell is the
    // always-mounted host; the guard itself lives in `firstAutoSizeNudgeProvider`.
    ref.listen(sizingProvider, (previous, next) {
      if ((previous == null || previous.isEmpty) && next.isNotEmpty) {
        ref.read(firstAutoSizeNudgeProvider.notifier).maybeFire(next.length);
      }
    });
    // The auto-update banner + command palette are stacked on top as non-layout
    // overlays (each renders nothing when idle).
    return Focus(
      // A bubble-phase listener high in the tree: it never requests focus
      // itself, so it doesn't disturb in-canvas editing — Ctrl/Cmd+K bubbles up
      // here when the focused descendant ignores it.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _onKey(context, ref, event),
      child: Stack(
        children: [
          ColoredBox(
            color: colors.background,
            child: SafeArea(
              // PanelMaker-style chrome: a left navigation rail beside the
              // top-bar + body + status-bar column.
              child: Row(
                children: [
                  const NavRail(),
                  Expanded(
                    child: Column(
                      children: [
                        const _TopBar(),
                        const _RecoveryBanner(),
                        const _ErrorBanner(),
                        const Expanded(child: _ShellBody()),
                        const _StatusBar(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const UpdateBannerOverlay(),
          const CommandPaletteOverlay(),
          const CopilotOverlay(),
        ],
      ),
    );
  }
}

/// Routes the centre area by the active [ShellSection]. `design` shows the
/// workspace (Plan / Schematic / Electrical, driven by [workspaceViewProvider]
/// exactly as before); the other sections show their own screens.
class _ShellBody extends ConsumerWidget {
  const _ShellBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(shellSectionProvider);
    switch (section) {
      case ShellSection.building:
        return const BuildingScreen();
      case ShellSection.review:
        return const ReviewHub();
      case ShellSection.commercial:
        return const CommercialHub();
      case ShellSection.projects:
        return const ProjectsScreen();
      case ShellSection.preferences:
        return const PreferencesScreen();
      case ShellSection.design:
        return const _DesignWorkspace();
    }
  }
}

/// The Design workspace area. The abstract electrical workspace
/// ([WorkspaceView.electrical]) and the mechanical riser
/// ([WorkspaceView.schematic]) own the whole area. The "Layout" view
/// ([WorkspaceView.plan], relabelled in the rail) is the UNIFIED canvas — the
/// shared PDF with plumbing · HVAC · electrical layers — flanked by the sheet
/// rail and a layer-aware inspector (the DRAW tools when a mechanical layer is
/// active, the electrical Loads palette when Electrical is).
class _DesignWorkspace extends ConsumerWidget {
  const _DesignWorkspace();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final view = ref.watch(workspaceViewProvider);
    if (view == WorkspaceView.electrical) {
      return const ElectricalView();
    }
    final Widget canvas = view == WorkspaceView.schematic
        ? const SchematicView()
        : const LayoutCanvas();
    // Layer-aware inspector (collapsible): the electrical Loads palette when
    // Electrical is the active Layout layer, else the mechanical DRAW/project
    // inspector. Schematic always shows the project inspector.
    final active = ref.watch(activeDisciplineProvider);
    final Widget inspector =
        view != WorkspaceView.schematic && active == DisciplineLayer.electrical
            ? const CollapsibleInspector(
                expandedWidth: ProjectPanel.width,
                child: _ElectricalInspectorColumn(),
              )
            : const CollapsibleInspector(
                expandedWidth: ProjectPanel.width,
                child: ProjectPanel(),
              );
    // Liquid Glass: the sheet rail + inspector are translucent glass that floats
    // over a full-bleed CANVAS-coloured backdrop (painted behind the whole
    // workspace), so the chrome frosts the canvas tone — distinct from the
    // opaque content — without occluding the canvas's own overlays.
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: colors.canvas)),
        Row(
          children: [
            const SheetRail(),
            Expanded(child: canvas),
            inspector,
          ],
        ),
      ],
    );
  }
}

/// The right inspector shown when Electrical is the active Layout layer: the
/// Loads palette (drag onto the canvas) — the electrical editing toolset.
class _ElectricalInspectorColumn extends StatelessWidget {
  const _ElectricalInspectorColumn();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return SizedBox(
      width: ProjectPanel.width,
      // Transparent: floats on the CollapsibleInspector's Liquid-Glass surface.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MechXSpacing.md, MechXSpacing.md,
                MechXSpacing.md, MechXSpacing.xs),
            child: Text(context.strings(StringKey.shellElectricalLayer),
                style: type.subtitle.copyWith(color: colors.textPrimary)),
          ),
          const SizedBox(height: MechXSpacing.sm),
          const Expanded(child: ElectricalPalette()),
        ],
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final state = ref.watch(sheetsControllerProvider);
    final brightness = ref.watch(brightnessProvider);
    final projectName = ref.watch(projectControllerProvider).name;
    final dirty = ref.watch(projectDirtyProvider);
    final currentPath = ref.watch(currentProjectPathProvider);
    final fileName =
        currentPath?.split(Platform.pathSeparator).last;

    final current = state.current;
    final vt = current == null ? null : state.viewportFor(current.id);
    final zoom = vt == null ? '—' : '${(vt.scale * 100).round()}%';

    return GlassSurface(
      // The top bar floats over the workspace; its bottom edge faces content.
      edge: Border(bottom: BorderSide(color: colors.glassEdge, width: MechXGlass.edgeWidth)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md,
          vertical: MechXSpacing.sm,
        ),
        child: Row(
          children: [
            Text('iSystem',
                style: type.title.copyWith(color: colors.textPrimary)),
            // A hairline middot sets the product title apart from the project
            // name — a clearer path-style hierarchy than a bare gap.
            _titleDot(colors.textMuted),
            Flexible(
              child: Text(
                projectName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.body.copyWith(color: colors.textMuted),
              ),
            ),
            // The document-app "edited" cue: a small accent dot while the work
            // differs from the last clean save (cleared eagerly on Save/Open;
            // false at rest so goldens are unchanged).
            if (dirty)
              Padding(
                padding: const EdgeInsets.only(left: MechXSpacing.xs + 2),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            // Where Ctrl/Cmd+S will land — the remembered file (post Save/Open).
            if (fileName != null) ...[
              _titleDot(colors.textMuted),
              Flexible(
                child: Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
              ),
            ],
            const Spacer(),
            // Actions sit flush-right. The zoom read-out is a quiet pill: a
            // soft tinted fill carries it, no hairline border — less visual
            // mass than a fully-outlined chip (HIG).
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm,
                vertical: MechXSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: MechXRadii.control,
              ),
              child: Text(
                zoom,
                style: type.mono.copyWith(color: colors.textSecondary),
              ),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: context.strings(StringKey.shellOpen),
              onPressed: () => openProject(context, ref),
            ),
            const SizedBox(width: MechXSpacing.xs),
            MechXButton(
              label: context.strings(StringKey.shellSave),
              onPressed: () => saveProject(ref),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: context.strings(StringKey.shellImportPdf),
              onPressed: () => importPlan(context, ref),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              // Name the ACTION, not the current mode: in light mode the button
              // acts toward dark, and vice-versa.
              label: brightness == Brightness.dark
                  ? context.strings(StringKey.shellSwitchToLight)
                  : context.strings(StringKey.shellSwitchToDark),
              onPressed: () =>
                  ref.read(brightnessProvider.notifier).toggle(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _titleDot(Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: MechXSpacing.sm),
        child: Text('·', style: TextStyle(fontFamily: 'Roboto', color: color)),
      );
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final sheet = ref.watch(sheetsControllerProvider).current;
    final project = ref.watch(projectControllerProvider);
    final calibrated =
        sheet != null && project.calibrationFor(sheet.id) != null;
    // The standards-provenance dot lights only when there are genuinely
    // unverified values to flag — a quiet caption otherwise.
    final hasUnverified = ref
        .watch(designIssuesProvider)
        .any((i) => i.title == 'Unverified standard');

    final caption = type.caption;

    return GlassSurface(
      // The status bar floats over the workspace; its top edge faces content.
      edge: Border(top: BorderSide(color: colors.glassEdge, width: MechXGlass.edgeWidth)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md,
          vertical: MechXSpacing.xs + 1,
        ),
        child: Row(
          children: [
            // Left group: current sheet info (truncates first).
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      sheet?.name ?? context.strings(StringKey.shellNoSheet),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: caption.copyWith(color: colors.textSecondary),
                    ),
                  ),
                  if (sheet != null) ...[
                    _dot(colors.textMuted),
                    if (calibrated) ...[
                      // A redundant check glyph (shape + colour) so the
                      // calibrated state survives without hue alone.
                      Padding(
                        padding:
                            const EdgeInsets.only(right: MechXSpacing.xxs),
                        child: CustomPaint(
                          size: const Size(10, 10),
                          painter: SeverityGlyph(
                            kind: SeverityGlyphKind.check,
                            color: colors.success,
                          ),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          context.strings(StringKey.shellCalibrated),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: caption.copyWith(color: colors.success),
                        ),
                      ),
                    ] else
                      Flexible(
                        child: Text(
                          context.strings(StringKey.shellUncalibrated),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: caption.copyWith(color: colors.textMuted),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: MechXSpacing.md),
            // Centre: the compact workflow stepper (Calibrate · Floors · Draw ·
            // Size · Report) — a glanceable "where am I" guide. Read-only;
            // derived O(1) from project state. Clipped so it surrenders width
            // gracefully on a narrow window instead of overflowing.
            const Flexible(
              flex: 0,
              child: ClipRect(
                child: WorkflowStepper(),
              ),
            ),
            const SizedBox(width: MechXSpacing.md),
            // Busy pill for a slow foreground operation (importing / converting /
            // opening / saving). Null at rest, so it collapses to nothing and the
            // goldens are unchanged; it shows a small animated arc + message while
            // the operation runs. A bare (non-flex) child, same as `WorkflowStepper`
            // above — a plain `Flexible`/`Expanded` here would default to flex: 1
            // and compete with the two flanking `Expanded` groups for the row's
            // free space, halving their width even while this pill is empty. The
            // pill instead bounds its OWN max width internally (see
            // `_BusyIndicator`) so a long message ellipsises without disturbing
            // the row's flex balance.
            const _BusyIndicator(),
            // Transient confirmation pill (Saved / opened / imported). Null at
            // rest, so this collapses to nothing and the goldens are unchanged;
            // it cross-fades in/out via AnimatedSwitcher when a message arrives.
            // Same non-flex reasoning as `_BusyIndicator` above.
            const _StatusConfirmation(),
            // Right group: standards provenance + input hints.
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (hasUnverified)
                    Container(
                      key: const ValueKey('provenance-warning-dot'),
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: MechXSpacing.xs),
                      decoration: BoxDecoration(
                        color: colors.warning,
                        borderRadius:
                            const BorderRadius.all(Radius.circular(4)),
                      ),
                    ),
                  Flexible(
                    child: Text(
                      context.strings(StringKey.shellStandardsProvenance),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: caption.copyWith(color: colors.textMuted),
                    ),
                  ),
                  // App version (hidden in tests — no platform channel — so
                  // the golden screenshots stay byte-identical).
                  const VersionLabel(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: MechXSpacing.sm),
        child: Text('·', style: TextStyle(fontFamily: 'Roboto', color: color)),
      );
}

/// The transient save/open/export confirmation in the status bar. Reads the
/// [statusMessageProvider] (null at rest), rendering nothing when there is no
/// message and a quiet success-tinted pill — cross-fading in/out — when there
/// is. The pill mirrors the zoom read-out's soft idiom (a tint, no border).
class _StatusConfirmation extends ConsumerWidget {
  const _StatusConfirmation();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final message = ref.watch(statusMessageProvider);
    return AnimatedSwitcher(
      duration: MechXMotion.appear,
      switchInCurve: MechXMotion.standard,
      switchOutCurve: MechXMotion.standard,
      child: message == null
          ? const SizedBox.shrink()
          : Padding(
              key: const ValueKey('status-confirmation'),
              padding: const EdgeInsets.only(right: MechXSpacing.md),
              // Bounds the pill's OWN max width (rather than a row-level
              // Flexible — see the call site's comment) so a long message
              // (e.g. the first-auto-size nudge's run count) ellipsises
              // instead of demanding its full intrinsic width and pushing the
              // status bar's flanking Expanded groups into overflow.
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MechXSpacing.sm,
                    vertical: MechXSpacing.xxs,
                  ),
                  decoration: BoxDecoration(
                    color: colors.success.withAlpha(30),
                    borderRadius: MechXRadii.control,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // A small custom-painted check (Roboto-safe, can't tofu).
                      CustomPaint(
                        size: const Size(10, 10),
                        painter: _CheckMark(color: colors.success),
                      ),
                      const SizedBox(width: MechXSpacing.xs),
                      // Flexible so the message ellipsises against the
                      // ConstrainedBox's bound instead of the Row demanding
                      // its full intrinsic width.
                      Flexible(
                        child: Text(
                          message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: type.caption.copyWith(color: colors.success),
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

/// A small check-mark glyph (the same tick the workflow stepper paints), used
/// by the status confirmation pill. Custom-painted so it never renders as tofu.
class _CheckMark extends CustomPainter {
  final Color color;
  const _CheckMark({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(w * 0.18, h * 0.52)
      ..lineTo(w * 0.42, h * 0.76)
      ..lineTo(w * 0.84, h * 0.24);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_CheckMark old) => old.color != color;
}

/// The busy pill in the status bar. Reads [busyProvider] (null at rest,
/// rendering nothing so the goldens are unchanged) and shows a small animated
/// arc + the busy message while a slow operation runs. The animation ticker
/// exists only while mounted (i.e. only while busy), never at rest.
class _BusyIndicator extends ConsumerWidget {
  const _BusyIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(busyProvider);
    if (message == null) return const SizedBox.shrink();
    final colors = context.colors;
    final type = context.type;
    return Padding(
      key: const ValueKey('busy-indicator'),
      padding: const EdgeInsets.only(right: MechXSpacing.md),
      // Same bounded-max-width reasoning as `_StatusConfirmation` — the pill
      // caps its OWN width rather than becoming a row-level flex participant.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm,
            vertical: MechXSpacing.xxs,
          ),
          decoration: BoxDecoration(
            color: colors.accent.withAlpha(30),
            borderRadius: MechXRadii.control,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BusySpinner(color: colors.accent),
              const SizedBox(width: MechXSpacing.xs),
              // Flexible so the message ellipsises against the
              // ConstrainedBox's bound instead of the Row demanding its full
              // intrinsic width.
              Flexible(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption.copyWith(color: colors.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small custom-painted indeterminate spinner arc — a Roboto-safe, Material-
/// free progress cue. Spins a repeating [AnimationController]; mounted only by
/// [_BusyIndicator] while busy, so there is no ticker (and no repaint) at rest.
class _BusySpinner extends StatefulWidget {
  final Color color;
  const _BusySpinner({required this.color});

  @override
  State<_BusySpinner> createState() => _BusySpinnerState();
}

class _BusySpinnerState extends State<_BusySpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        size: const Size(11, 11),
        painter: _SpinnerArc(color: widget.color, t: _controller.value),
      ),
    );
  }
}

/// Paints a 270-degree arc rotated by [t] (0..1) — the indeterminate cue.
class _SpinnerArc extends CustomPainter {
  final Color color;
  final double t;
  const _SpinnerArc({required this.color, required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final rect = Offset.zero & size;
    final start = t * 2 * 3.1415926535;
    // A 270-degree sweep leaves a visible gap so the rotation reads.
    canvas.drawArc(rect.deflate(1), start, 4.71238898, false, stroke);
  }

  @override
  bool shouldRepaint(_SpinnerArc old) => old.t != t || old.color != color;
}

/// Eases a shell banner in and out: the height collapses ([AnimatedSize]) and
/// the content cross-fades ([AnimatedSwitcher]) on the `appear` idiom, so a
/// banner glides in/out instead of popping. When [child] is null it resolves to
/// a zero-size box (no phantom layout space when idle — goldens stay identical).
class _AnimatedBanner extends StatelessWidget {
  final Widget? child;
  const _AnimatedBanner({required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: MechXMotion.appear,
        switchInCurve: MechXMotion.standard,
        switchOutCurve: MechXMotion.standard,
        child: child ?? const SizedBox(width: double.infinity),
      ),
    );
  }
}

/// Offers to restore a crash-recovery snapshot from a previous session that
/// ended without a clean exit. Restore loads it; Dismiss discards it.
class _RecoveryBanner extends ConsumerWidget {
  const _RecoveryBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(recoveryDocProvider);
    final colors = context.colors;
    final type = context.type;

    Future<void> dismiss() async {
      await clearRecovery();
      ref.read(recoveryDocProvider.notifier).clear();
    }

    return _AnimatedBanner(
      child: doc == null
          ? null
          : Container(
              key: const ValueKey('recovery-banner'),
              width: double.infinity,
              color: colors.accent.withAlpha(30),
              padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.md,
                vertical: MechXSpacing.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.strings(StringKey.shellRecoverPrompt),
                      style: type.caption.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.shellRestore),
                    primary: true,
                    onPressed: () {
                      // Restore the full snapshot (drawing + settings). We
                      // deliberately do NOT mark it as the clean baseline:
                      // recovered work is still unsaved, so autosave should keep
                      // mirroring it after dismiss. (Recovery snapshots embed no
                      // assets, so rehydrate is a no-op here — kept for symmetry.)
                      applyDocument(ref.read, rehydrateAssets(doc));
                      dismiss();
                    },
                  ),
                  const SizedBox(width: MechXSpacing.sm),
                  MechXButton(
                      label: context.strings(StringKey.shellDismiss),
                      onPressed: dismiss),
                ],
              ),
            ),
    );
  }
}

/// A thin, dismissible banner that surfaces a transient load error (e.g. a
/// project that failed to open) instead of failing silently.
class _ErrorBanner extends ConsumerWidget {
  const _ErrorBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(loadErrorProvider);
    final colors = context.colors;
    final type = context.type;
    return _AnimatedBanner(
      child: message == null
          ? null
          : Container(
              key: const ValueKey('error-banner'),
              width: double.infinity,
              color: colors.danger.withAlpha(38),
              padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.md,
                vertical: MechXSpacing.xs,
              ),
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: MechXSpacing.sm),
                    decoration: BoxDecoration(
                      color: colors.danger,
                      borderRadius:
                          const BorderRadius.all(Radius.circular(4)),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: type.caption.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  const SizedBox(width: MechXSpacing.sm),
                  _DismissLink(
                    label: context.strings(StringKey.shellDismiss),
                    color: colors.danger,
                    onTap: () => ref.read(loadErrorProvider.notifier).clear(),
                  ),
                ],
              ),
            ),
    );
  }
}

/// A small text-link affordance (the error banner's Dismiss): brightens toward
/// the primary label on hover and dims on press, easing on the `hover` idiom —
/// so the link reads as tappable. Keyboard-focusable + Enter/Space via the
/// shared focus ring.
class _DismissLink extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _DismissLink({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  State<_DismissLink> createState() => _DismissLinkState();
}

class _DismissLinkState extends State<_DismissLink> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final type = context.type;
    final colors = context.colors;
    final fg = _down
        ? Color.lerp(widget.color, const Color(0xFF000000), 0.18)!
        : (_hover
            ? Color.lerp(widget.color, colors.textPrimary, 0.25)!
            : widget.color);
    return MechXFocusRing(
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _down = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.xs,
              vertical: MechXSpacing.xxs,
            ),
            child: AnimatedDefaultTextStyle(
              duration: MechXMotion.hover,
              curve: MechXMotion.standard,
              style: type.label.copyWith(color: fg),
              child: Text(widget.label),
            ),
          ),
        ),
      ),
    );
  }
}
