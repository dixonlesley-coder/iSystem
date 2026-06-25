import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/autosave.dart';
import '../data/pdf_import.dart';
import '../data/project_document.dart';
import '../data/recovery.dart';
import '../store/app_state.dart';
import '../store/electrical_store.dart';
import '../store/layer_store.dart';
import '../store/project_store.dart';
import '../store/sheets_store.dart';
import '../update/update_banner.dart';
import '../update/version_label.dart';
import 'commercial/commercial_hub.dart';
import 'electrical/electrical_palette.dart';
import 'electrical/electrical_view.dart';
import 'inspector/collapsible_inspector.dart';
import 'inspector/project_panel.dart';
import 'layout/layout_canvas.dart';
import 'review/review_hub.dart';
import 'schematic/schematic_view.dart';
import 'shell/building_screen.dart';
import 'shell/nav_rail.dart';
import 'shell/preferences_screen.dart';
import 'shell/projects_screen.dart';
import 'sheets/sheet_rail.dart';
import 'strings/app_strings.dart';
import 'theme/design_tokens.dart';
import 'theme/mechx_theme.dart';
import 'widgets/mechx_button.dart';
import 'widgets/mechx_focus_ring.dart';

/// Top-level layout (PanelMaker-style chrome): a left navigation rail beside a
/// slim top bar · body · status-bar column. The rail picks the [ShellSection];
/// the body is the workspace (Plan / Schematic / Electrical) or a hub/screen.
/// No Material Scaffold — a restrained, custom shell (§4).
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // The auto-update banner is stacked on top as a non-layout overlay (renders
    // nothing when idle/offline/no update).
    return Stack(
      children: [
        ColoredBox(
          color: colors.background,
          child: SafeArea(
            // PanelMaker-style chrome: a left navigation rail beside the
            // top-bar + body + status-bar column.
            child: Row(
              children: [
                const NavRail(),
                Container(width: 1, color: colors.border),
                Expanded(
                  child: Column(
                    children: [
                      const _TopBar(),
                      Container(height: 1, color: colors.border),
                      const _RecoveryBanner(),
                      const _ErrorBanner(),
                      const Expanded(child: _ShellBody()),
                      Container(height: 1, color: colors.border),
                      const _StatusBar(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const UpdateBannerOverlay(),
      ],
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
    if (view == WorkspaceView.schematic) {
      return Row(
        children: [
          const SheetRail(),
          Container(width: 1, color: colors.border),
          const Expanded(child: SchematicView()),
          // The collapsible wrapper carries its own left border, so the canvas
          // reclaims the full width when the inspector is collapsed.
          const CollapsibleInspector(
            expandedWidth: ProjectPanel.width,
            child: ProjectPanel(),
          ),
        ],
      );
    }
    // Layout (unified canvas).
    final active = ref.watch(activeDisciplineProvider);
    return Row(
      children: [
        const SheetRail(),
        Container(width: 1, color: colors.border),
        const Expanded(child: LayoutCanvas()),
        // Layer-aware inspector (collapsible): the electrical Loads palette when
        // Electrical is the active layer, else the mechanical DRAW/project
        // inspector. Either way it collapses to a thin strip so the canvas wins.
        if (active == DisciplineLayer.electrical)
          const CollapsibleInspector(
            expandedWidth: ProjectPanel.width,
            child: _ElectricalInspectorColumn(),
          )
        else
          const CollapsibleInspector(
            expandedWidth: ProjectPanel.width,
            child: ProjectPanel(),
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
      child: ColoredBox(
        color: colors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(MechXSpacing.md,
                  MechXSpacing.md, MechXSpacing.md, MechXSpacing.xs),
              child: Text(context.strings(StringKey.shellElectricalLayer),
                  style: type.subtitle.copyWith(color: colors.textPrimary)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MechXSpacing.md),
              child: Text(
                context.strings(StringKey.shellElectricalLayerHelp),
                style: type.caption.copyWith(color: colors.textMuted),
              ),
            ),
            const SizedBox(height: MechXSpacing.sm),
            const Expanded(child: ElectricalPalette()),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  Future<void> _pickAndLoadPdf(WidgetRef ref) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || path.isEmpty) return;

    try {
      final sheets = await importPdf(path);
      if (sheets.isEmpty) {
        ref
            .read(loadErrorProvider.notifier)
            .set('That PDF had no importable pages.');
        return;
      }
      ref.read(sheetsControllerProvider.notifier).loadSheets(sheets);
      ref.read(loadErrorProvider.notifier).clear();
    } catch (e) {
      // Surface the failure instead of silently keeping the old sheets.
      ref.read(loadErrorProvider.notifier).set('Could not import PDF: $e');
    }
  }

  Future<void> _saveProject(WidgetRef ref) async {
    final project = ref.read(projectControllerProvider);
    final doc = buildDocument(ref.read);
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save iSystem project',
      fileName: '${project.name}.mechx',
      type: FileType.custom,
      allowedExtensions: const ['mechx'],
    );
    if (path == null) return;
    final full = path.endsWith('.mechx') ? path : '$path.mechx';
    final encoded = doc.encode();
    try {
      await File(full).writeAsString(encoded);
    } catch (e) {
      ref.read(loadErrorProvider.notifier).set('Could not save project: $e');
      return;
    }
    // The work is now safely on disk — record it as the clean baseline and
    // drop any recovery snapshot/offer.
    ref.read(lastSavedSignatureProvider.notifier).set(encoded);
    await clearRecovery();
    ref.read(recoveryDocProvider.notifier).clear();
  }

  Future<void> _openProject(WidgetRef ref) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mechx', 'json'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      final doc = ProjectDocument.decode(await File(path).readAsString());
      applyDocument(ref.read, doc);
      // The just-loaded state is the clean baseline; capture its canonical
      // encoding so autosave won't immediately mirror it to recovery.
      ref
          .read(lastSavedSignatureProvider.notifier)
          .set(buildDocument(ref.read).encode());
      await clearRecovery();
      ref.read(recoveryDocProvider.notifier).clear();
      ref.read(loadErrorProvider.notifier).clear();
    } on ProjectDocumentException catch (e) {
      // Malformed/incompatible file — surface why, leave the project untouched.
      ref.read(loadErrorProvider.notifier).set(e.message);
    } catch (e) {
      ref.read(loadErrorProvider.notifier).set('Could not open project: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final state = ref.watch(sheetsControllerProvider);
    final brightness = ref.watch(brightnessProvider);
    final projectName = ref.watch(projectControllerProvider).name;

    final current = state.current;
    final vt = current == null ? null : state.viewportFor(current.id);
    final zoom = vt == null ? '—' : '${(vt.scale * 100).round()}%';

    return ColoredBox(
      color: colors.surface,
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
              onPressed: () => _openProject(ref),
            ),
            const SizedBox(width: MechXSpacing.xs),
            MechXButton(
              label: context.strings(StringKey.shellSave),
              onPressed: () => _saveProject(ref),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: context.strings(StringKey.shellImportPdf),
              onPressed: () => _pickAndLoadPdf(ref),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: brightness == Brightness.dark
                  ? context.strings(StringKey.shellDark)
                  : context.strings(StringKey.shellLight),
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

    final caption = type.caption;

    return ColoredBox(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md,
          vertical: MechXSpacing.xs + 1,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left group: current sheet info (truncates first).
            Flexible(
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
                    Text(
                      '${sheet.sizePx.width.round()} × ${sheet.sizePx.height.round()} px',
                      style: caption.copyWith(color: colors.textMuted),
                    ),
                    _dot(colors.textMuted),
                    Text(
                      context.strings(StringKey.shellUncalibrated),
                      style: caption.copyWith(color: colors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: MechXSpacing.md),
            // Right group: standards provenance + input hints.
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: MechXSpacing.xs),
                    decoration: BoxDecoration(
                      color: colors.warning,
                      borderRadius: const BorderRadius.all(Radius.circular(4)),
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
                  _dot(colors.textMuted),
                  Flexible(
                    child: Text(
                      context.strings(StringKey.shellViewportHints),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
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
                      // mirroring it after dismiss.
                      applyDocument(ref.read, doc);
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
