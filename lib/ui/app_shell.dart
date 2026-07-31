import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/geo_length.dart';

import '../data/autosave.dart';
import '../data/project_assets.dart';
import '../data/recovery.dart';
import '../store/app_state.dart';
import '../store/command_store.dart';
import '../store/design_issues_store.dart';
import '../store/electrical_store.dart';
import '../store/history_store.dart';
import '../store/layer_store.dart';
import '../store/project_store.dart';
import '../store/sheets_store.dart';
import '../store/sizing_store.dart';
import '../update/update_banner.dart';
import '../update/version_label.dart';
import 'ai/copilot_panel.dart';
import 'canvas/text_entry_guard.dart';
import 'commercial/commercial_hub.dart';
import 'electrical/electrical_inspector.dart';
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
import 'shell/shell_shortcuts.dart';
import 'shell/shortcuts_sheet.dart';
import 'sheets/sheet_rail.dart';
import 'strings/app_strings.dart';
import 'theme/design_tokens.dart';
import 'theme/mechx_theme.dart';
import 'widgets/glass_surface.dart';
import 'widgets/mechx_button.dart';
import 'widgets/mechx_focus_ring.dart';
import 'widgets/mechx_tooltip.dart';
import 'widgets/section_label.dart';
import 'widgets/severity_glyph.dart';

/// Top-level layout (PanelMaker-style chrome): a left navigation rail beside a
/// slim top bar · body · status-bar column. The rail picks the [ShellSection];
/// the body is the workspace (Plan / Schematic / Electrical) or a hub/screen.
/// No Material Scaffold — a restrained, custom shell (§4).
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    // Focus-independent shell hotkeys (I1): a raw [HardwareKeyboard] handler
    // runs BEFORE focus dispatch, so Ctrl/Cmd+K / S / Shift+S / O work on
    // every screen — Projects / Review / Commercial / Building / Preferences
    // and the Riser view, where nothing holds focus and a bubble-phase Focus
    // ancestor never sees the keys.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  /// Dispatches the app-wide accelerators — the "normal controls" every desktop
  /// authoring tool answers to: Ctrl/Cmd+N/O/S/Shift+S/I/P (file), Ctrl+Z /
  /// Ctrl+Y / Ctrl+Shift+Z (edit), Ctrl+K / Ctrl+Shift+P / F1 (find + help) and
  /// Ctrl+1..8 / Ctrl+, (go to a destination). WHICH key means what is the pure,
  /// unit-tested table in `shell_shortcuts.dart`; this method only runs it.
  ///
  /// Returns true when consumed so the focus system doesn't double-dispatch
  /// the event to a focused canvas/field; everything else returns false and
  /// flows through the normal focus chain untouched.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // The shortcuts sheet carries no text field, so nothing inside it holds
    // focus and the bubble-phase Esc listener would never see the key on a hub
    // screen (the I1 dead spot). Close it here instead — pre-focus, but ONLY
    // while it is open, so Esc otherwise reaches the canvases untouched.
    final closingSheet = event.logicalKey == LogicalKeyboardKey.escape &&
        ref.read(shortcutsSheetOpenProvider);
    final command = closingSheet
        ? null
        : matchShellShortcut(
            event.logicalKey,
            mod: HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed,
            shift: HardwareKeyboard.instance.isShiftPressed,
            alt: HardwareKeyboard.instance.isAltPressed,
          );
    if (!closingSheet && command == null) return false;
    // This handler is pre-focus and process-global, so it must stand down when
    // a modal route (a dialog / file picker) is on top of the shell — otherwise
    // Ctrl+O could stack a second confirm dialog over the first, or Ctrl+K
    // would toggle the palette behind the barrier. Only act when the shell's
    // own route is the current one.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (closingSheet) {
      ref.read(shortcutsSheetOpenProvider.notifier).close();
      return true;
    }
    // A focused text field owns its own editing keys: Ctrl+Z/Y inside a field
    // must undo the FIELD (the framework's DefaultTextEditingShortcuts), never
    // the drawing. Everything else stays live while typing, as it does in every
    // desktop editor.
    if (command!.deferToTextField && isTextEntryFocused()) return false;
    _run(command);
    return true;
  }

  /// Run one resolved [ShellCommand] through the EXISTING controllers — the
  /// same entry points the top bar / nav rail / command palette use, so an
  /// accelerator can never diverge from its clicked equivalent.
  void _run(ShellCommand command) {
    void goDesign(WorkspaceView view) {
      ref.read(workspaceViewProvider.notifier).set(view);
      ref.read(shellSectionProvider.notifier).set(ShellSection.design);
    }

    switch (command) {
      // — File — Document-app conventions: Ctrl/Cmd+S saves in place (Shift
      // forces Save-As), Ctrl/Cmd+O opens. New / Open / Import guard unsaved
      // work, so they need the shell context to host the confirm dialog.
      case ShellCommand.newProject:
        newProject(context, ref);
      case ShellCommand.openProject:
        openProject(context, ref);
      case ShellCommand.save:
        saveProject(ref);
      case ShellCommand.saveAs:
        saveProject(ref, saveAs: true);
      case ShellCommand.importPlan:
        importPlan(context, ref);
      // The closest thing this app has to "print": the annotated plan PDF of
      // the current sheet (title block + real lengths). Guarded like every
      // other export — with no calibrated sheet it explains itself instead of
      // writing an empty drawing.
      case ShellCommand.printPlan:
        exportAnnotatedPlanPdf(ref);
      // — Edit — the ONE global timeline, so Ctrl+Z reverts the genuinely most
      // recent edit across mechanical / electrical / annotation domains.
      case ShellCommand.undo:
        ref.read(historyProvider.notifier).undo();
      case ShellCommand.redo:
        ref.read(historyProvider.notifier).redo();
      // — Find / help — both overlays render nothing when closed; opening one
      // closes the other so two scrims can never stack.
      case ShellCommand.commandPalette:
        ref.read(shortcutsSheetOpenProvider.notifier).close();
        ref.read(commandPaletteOpenProvider.notifier).toggle();
      case ShellCommand.shortcutsHelp:
        ref.read(commandPaletteOpenProvider.notifier).close();
        ref.read(shortcutsSheetOpenProvider.notifier).toggle();
      // — Go to — the nav-rail destinations, in rail order.
      case ShellCommand.goLayout:
        goDesign(WorkspaceView.plan);
      case ShellCommand.goRiser:
        goDesign(WorkspaceView.schematic);
      case ShellCommand.goElectrical:
        goDesign(WorkspaceView.electrical);
      case ShellCommand.goBuilding:
        ref.read(shellSectionProvider.notifier).set(ShellSection.building);
      case ShellCommand.goReview:
        ref.read(shellSectionProvider.notifier).set(ShellSection.review);
      case ShellCommand.goCommercial:
        ref.read(shellSectionProvider.notifier).set(ShellSection.commercial);
      case ShellCommand.goProjects:
        ref.read(shellSectionProvider.notifier).set(ShellSection.projects);
      case ShellCommand.goPreferences:
        ref.read(shellSectionProvider.notifier).set(ShellSection.preferences);
    }
  }

  /// Bubble-phase Esc handler (kept as a non-focus-stealing ancestor [Focus]):
  /// closes the command palette when it's open (the palette autofocuses its
  /// filter field, so Esc always reaches here; the field-less shortcuts sheet
  /// is closed pre-focus in [_onHardwareKey] instead). The global combos moved
  /// to [_onHardwareKey] — they must not also be handled here, or one keypress
  /// would dispatch twice.
  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (ref.read(commandPaletteOpenProvider)) {
      ref.read(commandPaletteOpenProvider.notifier).close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
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
    // A2: latch "Building visited" the first time the engineer opens the
    // Building (floors) section, so the workflow stepper's Floors stage
    // reflects a real interaction rather than the default 3-floor seed. This is
    // the always-mounted host; the latch itself is session-transient
    // (`buildingVisitedProvider`) and never fires in the seeded golden suite
    // (which drives Review/Commercial/Projects but never opens Building).
    ref.listen(shellSectionProvider, (previous, next) {
      if (next == ShellSection.building) {
        ref.read(buildingVisitedProvider.notifier).markVisited();
      }
    });
    // The auto-update banner + command palette are stacked on top as non-layout
    // overlays (each renders nothing when idle).
    return Focus(
      // A bubble-phase listener high in the tree: it never requests focus
      // itself, so it doesn't disturb in-canvas editing — Esc bubbles up here
      // when the focused descendant ignores it.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _onKey(event),
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
          const ShortcutsSheetOverlay(),
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
    // C1: the abstract electrical workspace now rides the SAME shared scaffold
    // as the mechanical Layout / Riser — a canvas-coloured backdrop with a
    // Liquid-Glass CollapsibleInspector — so the frame reads identically and
    // only the CONTENT differs. It is NOT sheet-based (its single-line / riser
    // tabs are projections of the solved model, not a calibrated PDF), so the
    // SheetRail is omitted here ("sheet rail where it applies"); the mechanical
    // views keep it. The inspector column is selection-first (C4): the open
    // circuit / panel editor when one is selected, else the Loads palette.
    if (view == WorkspaceView.electrical) {
      return Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: colors.canvas)),
          Row(
            children: [
              const Expanded(child: ElectricalView()),
              CollapsibleInspector(
                expandedWidth: ProjectPanel.width,
                child: const _ElectricalWorkspaceInspectorColumn(),
              ),
            ],
          ),
        ],
      );
    }
    final Widget canvas = view == WorkspaceView.schematic
        ? const SchematicView()
        : const LayoutCanvas();
    // Workspace-scoped inspector (collapsible), keyed on the active view (F1):
    //  · RISER (schematic) → a lean riser-relevant column (Building + feed
    //    strategy + a pointer to the on-canvas Auto/Edit riser tools), NOT the
    //    plan's DRAW inspector whose tools mutate the Layout canvas you can't
    //    see from here.
    //  · Layout + Electrical layer active → the electrical Loads palette.
    //  · Layout + a mechanical layer → the mechanical DRAW/project inspector.
    final active = ref.watch(activeDisciplineProvider);
    final Widget inspectorChild;
    if (view == WorkspaceView.schematic) {
      inspectorChild = const _RiserInspectorColumn();
    } else if (active == DisciplineLayer.electrical) {
      inspectorChild = const _ElectricalInspectorColumn();
    } else {
      inspectorChild = const ProjectPanel();
    }
    final Widget inspector = CollapsibleInspector(
      expandedWidth: ProjectPanel.width,
      child: inspectorChild,
    );
    // Liquid Glass: the sheet rail + inspector are translucent glass that floats
    // over a full-bleed CANVAS-coloured backdrop (painted behind the whole
    // workspace), so the chrome frosts the canvas tone — distinct from the
    // opaque content — without occluding the canvas's own overlays.
    //
    // D4: the Riser (schematic) canvas is, like Electrical, NOT sheet-based —
    // Auto/Edit always render the WHOLE building across every floor
    // regardless of the selected sheet (schematic_view.dart's
    // `_sheetIdForFloor` never consults `sheets.currentIndex`), so the same
    // "sheet rail where it applies" reasoning that omits it for Electrical
    // applies here too: clicking a floor number did nothing, just confusing
    // dead chrome. Omit it rather than wire a floor-focus control — the
    // Riser-scoped inspector already gives building/floor context, and
    // "every floor stacked" is the Riser's whole point (a per-floor filter
    // would fight that).
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: colors.canvas)),
        Row(
          children: [
            if (view != WorkspaceView.schematic) const SheetRail(),
            Expanded(child: canvas),
            inspector,
          ],
        ),
      ],
    );
  }
}

/// The layout PLACEMENT caption for a placed load/panel, e.g. 'Sheet 2 ·
/// Level 2' — the same numbered-rail index (`sheet_rail.dart`'s `${index +
/// 1}`) and floor-name fallback (`'Floor ${i + 1}'`) the sheet rail itself
/// uses, so the inspector names a sheet exactly as the rest of the app does.
/// Null when [pos]'s sheet no longer resolves (a stale/removed sheet id).
String? _layoutPlacementLabel(WidgetRef ref, LayoutPos pos) {
  final sheets = ref.watch(sheetsControllerProvider).sheets;
  final index = sheets.indexWhere((s) => s.id == pos.sheetId);
  if (index < 0) return null;
  final floors = ref.watch(projectControllerProvider).floors;
  final floorName = pos.floorIndex >= 0 && pos.floorIndex < floors.length
      ? floors[pos.floorIndex].name
      : 'Floor ${pos.floorIndex + 1}';
  return 'Sheet ${index + 1} · $floorName';
}

/// Builds the INLINE electrical editor body for the current
/// [electricalInspectorTargetProvider] target (a circuit / panel / the
/// project-wide Service / Sources / Advanced sections), or null when nothing is
/// targeted (the caller then shows the Loads palette). Shared (C1) by the
/// standalone electrical workspace column AND the Layout electrical-layer column
/// so both are selection-first. A stale target (its panel / circuit deleted) is
/// cleared next frame and returns null. Transparent — floats on the column's
/// Liquid-Glass.
Widget? buildElectricalInlineEditor(
  BuildContext context,
  WidgetRef ref,
  VoidCallback clear,
) {
  final target = ref.watch(electricalInspectorTargetProvider);
  if (target == null) return null;
  final project = ref.watch(electricalProjectProvider);
  final ctrl = ref.read(electricalProjectProvider.notifier);
  Widget? editor;
  if (target is ElectricalCircuitTarget) {
    final panel =
        project.panels.where((p) => p.id == target.panelId).firstOrNull;
    final circuit =
        panel?.circuits.where((c) => c.id == target.circuitId).firstOrNull;
    if (panel != null && circuit != null) {
      // H2/H3 — the way's solved protection (breaker/RCD/Icu), the SAME figures
      // the board schedule prints, for the circuit editor's read-only line.
      final result = ref.watch(electricalResultProvider);
      final circuitResult = result.panels[panel.id]?.circuits
          .where((c) => c.circuitId == circuit.id)
          .firstOrNull;
      final icuKa = ref
          .watch(electricalAdvancedProvider)
          .fault
          .panels[panel.id]
          ?.incomerKa;
      // §10 — the run length actually in force + its basis, off the SAME
      // shared calibration/building geometry `electricalResultProvider` itself
      // threads into the solve, so the inspector's "from layout"/"manual" line
      // can never disagree with the solved figures above it.
      final geo = ref.watch(projectControllerProvider);
      final panelById = {for (final p in project.panels) p.id: p};
      final resolved = resolveCircuitLengthDetailed(
        circuit,
        panel,
        calibrationBySheet: geo.calibrations,
        building: geo.building,
        panelById: panelById,
      );
      final loadPos = circuit.loadPos;
      final placementLabel =
          loadPos != null ? _layoutPlacementLabel(ref, loadPos) : null;
      editor = ElectricalCircuitInspector(
        key: ValueKey('${target.panelId}/${target.circuitId}'),
        panel: panel,
        circuit: circuit,
        controller: ctrl,
        onClose: clear,
        inline: true,
        circuitResult: circuitResult,
        breakerIcuKa: icuKa,
        lengthSource: resolved.source,
        effectiveLength: resolved.length,
        placementLabel: placementLabel,
        onUnplace: loadPos == null
            ? null
            : () => unplaceCircuitLoad(ref, context, panel.id, circuit.id),
        panelSystem: panel.system,
      );
    }
  } else if (target is ElectricalPanelTarget) {
    final panel =
        project.panels.where((p) => p.id == target.panelId).firstOrNull;
    if (panel != null) {
      final result = ref.watch(electricalResultProvider);
      final panelResult = result.panels[panel.id];
      final enclosureResult =
          ref.watch(electricalAdvancedProvider).enclosure[panel.id];
      // Boards this one could be fed FROM — every other panel a re-parent onto
      // wouldn't loop (the shared `feederRefusalReason` rule the canvas's own
      // context menu uses too, so the two entry points can never disagree on
      // the candidate set).
      final feedCandidates = [
        for (final p in project.panels)
          if (p.id != panel.id &&
              ctrl.feederRefusalReason(p.id, panel.id) == null)
            (id: p.id, label: p.tag ?? p.name),
      ];
      editor = ElectricalPanelInspector(
        key: ValueKey('panel/${target.panelId}'),
        panel: panel,
        controller: ctrl,
        onClose: clear,
        inline: true,
        panelResult: panelResult,
        enclosureResult: enclosureResult,
        fedFromLabel: feedingPanelLabel(project, panel.id),
        feedCandidates: feedCandidates,
        onFeedFrom: (fromId) => feedPanelFrom(ref, context, fromId, panel.id),
        onDisconnectFeeder: panel.fedByCircuitId == null
            ? null
            : () {
                ctrl.disconnectFeeder(panel.id);
                ref
                    .read(statusMessageProvider.notifier)
                    .showStatus(context
                        .strings(StringKey.electricalFeederDisconnected));
              },
        onApplyTemplate: () => applyTemplateTo(context, ref, panel.id),
        onPinPhases: () => pinPanelPhasesTo(ref, context, panel.id),
      );
    }
  } else if (target is ElectricalServiceTarget) {
    // C1: the project-wide Service & Earthing / Sources / Advanced editors now
    // render INLINE here (was a floating drawer over the canvas).
    editor = ElectricalServiceInspector(onClose: clear);
  } else if (target is ElectricalSourcesTarget) {
    editor = ElectricalSourcesInspector(onClose: clear);
  } else if (target is ElectricalAdvancedTarget) {
    editor = ElectricalAdvancedInspector(onClose: clear);
  }
  // A stale target whose panel / circuit was deleted: clear it next frame so the
  // column falls back to the palette (never a blank inspector).
  if (editor == null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => clear());
  }
  return editor;
}

/// The right inspector shown when Electrical is the active Layout layer (C1):
/// selection-first — the inline circuit / panel editor when a marker is
/// double-clicked (driven by [electricalInspectorTargetProvider], the same
/// target the standalone workspace uses), else the "Electrical layer" header +
/// the Loads palette (drag onto the canvas).
class _ElectricalInspectorColumn extends ConsumerWidget {
  const _ElectricalInspectorColumn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    void clear() =>
        ref.read(electricalInspectorTargetProvider.notifier).clear();
    final editor = buildElectricalInlineEditor(context, ref, clear);
    if (editor != null) {
      return SizedBox(width: ProjectPanel.width, child: editor);
    }
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

/// The right inspector for the STANDALONE electrical workspace (C1/C4) — the
/// selection-first inline column that replaces the old floating slide-in
/// drawers. When a circuit / panel edit target is set
/// ([electricalInspectorTargetProvider], driven by the canvas's double-click /
/// context-menu Edit), its editor body renders INLINE at the top (the SAME
/// `ElectricalCircuitInspector` / `ElectricalPanelInspector` bodies, in their
/// `inline` form — transparent, so they float on the CollapsibleInspector's
/// Liquid-Glass); with nothing selected it shows the Loads palette. Transparent
/// (floats on the inspector glass), mirroring `_ElectricalInspectorColumn` /
/// `_RiserInspectorColumn`.
class _ElectricalWorkspaceInspectorColumn extends ConsumerWidget {
  const _ElectricalWorkspaceInspectorColumn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void clear() =>
        ref.read(electricalInspectorTargetProvider.notifier).clear();
    final editor = buildElectricalInlineEditor(context, ref, clear);

    // J2 (superseding D6): the Loads palette belongs to the Single-line tab —
    // it is the only surface with a drop target. On the read-only Building-riser
    // / Power one-line projections it used to render as twenty DIMMED, inert
    // cards: a full column of affordances that do nothing. Those tabs now show
    // the live electrical SYSTEM summary instead (the counterpart of the
    // mechanical Riser's `RiserSystemSummary` above) — what the diagram in
    // front of you actually contains, rather than what you cannot do to it.
    final tab = ref.watch(electricalTabProvider);
    return SizedBox(
      width: ProjectPanel.width,
      // Transparent: floats on the CollapsibleInspector's Liquid-Glass surface.
      child: editor ??
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: tab == ElectricalTab.singleLine
                    ? const ElectricalPalette()
                    : const ElectricalSystemSummary(),
              ),
            ],
          ),
    );
  }
}

/// The right inspector shown on the RISER (Schematic) workspace (F1). A lean,
/// riser-relevant column — the building context, the feed strategy that drives
/// the riser's function tags (gravity vs booster), and a pointer to the
/// on-canvas Auto/Edit riser tools — instead of the plan's DRAW inspector
/// (whose tools + palette mutate the Layout canvas, invisible from here).
class _RiserInspectorColumn extends ConsumerWidget {
  const _RiserInspectorColumn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final building = ref.watch(projectControllerProvider).building;
    final strategy = ref.watch(feedStrategyProvider);
    return SizedBox(
      width: ProjectPanel.width,
      // Transparent: floats on the CollapsibleInspector's Liquid-Glass surface.
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MechXSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // C5: converge on the shared section-heading idiom
            // (`MechXSectionLabel`) the main + electrical inspectors use, rather
            // than a raw ad-hoc `Text` title with a bespoke type/colour.
            const MechXSectionLabel('Riser'),
            const SizedBox(height: MechXSpacing.md),
            // Building context (levels/height) → opens the Building page.
            const MechXSectionLabel('Building'),
            const SizedBox(height: MechXSpacing.xs),
            _RiserSummaryCard(
              summary:
                  '${building.totalHeight.meters.toStringAsFixed(1)} m · '
                  '${building.levelCount} levels',
              onOpen: () => ref
                  .read(shellSectionProvider.notifier)
                  .set(ShellSection.building),
            ),
            const SizedBox(height: MechXSpacing.lg),
            // Feed strategy — the input that decides each riser's function tag
            // (gravity downfeed vs upfeed/booster) on the diagram.
            const MechXSectionLabel('Feed strategy'),
            const SizedBox(height: MechXSpacing.xs),
            // C5: the two feed-strategy choices are a mutually-exclusive segment,
            // so they wear the shared TINTED selected-segment idiom (accentMuted
            // fill + accent border) used by the draw tools / service chips — not a
            // solid-accent fill, so a single solid accent stays reserved for the
            // primary action.
            _TintedToggle(
              label: 'Upfeed pump',
              selected: strategy == FeedStrategy.upfeed,
              onTap: () => setFeedStrategyUndoable(ref.read, FeedStrategy.upfeed),
            ),
            const SizedBox(height: MechXSpacing.xs),
            _TintedToggle(
              label: 'Roof-tank downfeed',
              selected: strategy == FeedStrategy.downfeed,
              onTap: () =>
                  setFeedStrategyUndoable(ref.read, FeedStrategy.downfeed),
            ),
            const SizedBox(height: MechXSpacing.lg),
            const RiserSystemSummary(),
            Text(
              'Place, move and size risers on the canvas — switch Auto '
              '(read-only diagram) and Edit on the toolbar above.',
              style: type.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tinted selected-segment toggle (C5) — the shared idiom used by the draw
/// tools / service chips: a soft `accentMuted` fill + accent border when
/// selected, so a single SOLID accent stays reserved for the primary action.
/// A local mirror of the (file-private) `_TintedToggle` in `project_panel.dart`
/// — same styling, kept in step so the riser inspector reads as one app.
class _TintedToggle extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TintedToggle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: MechXFocusRing(
        onActivated: onTap,
        borderRadius: MechXRadii.control,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: EdgeInsets.symmetric(
              // Match the default MechXButton padding, compensating the heavier
              // selected border so the toggle never resizes between states.
              horizontal: MechXSpacing.sm + 4 - (selected ? 1 : 0),
              vertical: MechXSpacing.xs + 2 - (selected ? 1 : 0),
            ),
            decoration: BoxDecoration(
              color: selected ? colors.accentMuted : colors.surfaceHover,
              borderRadius: MechXRadii.control,
              border: Border.all(
                color: selected ? colors.accent : const Color(0x00000000),
                width: selected ? 2 : 1,
              ),
            ),
            child: Text(
              label,
              style: type.label.copyWith(
                color: selected ? colors.accent : colors.textPrimary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tappable summary card (levels/height) that opens the Building page — the
/// riser inspector's own copy of the plan inspector's building summary.
class _RiserSummaryCard extends StatefulWidget {
  final String summary;
  final VoidCallback onOpen;
  const _RiserSummaryCard({required this.summary, required this.onOpen});

  @override
  State<_RiserSummaryCard> createState() => _RiserSummaryCardState();
}

class _RiserSummaryCardState extends State<_RiserSummaryCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MechXFocusRing(
      borderRadius: MechXRadii.control,
      onActivated: widget.onOpen,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onOpen,
          child: AnimatedContainer(
            duration: MechXMotion.resolve(context, MechXMotion.hover),
            curve: MechXMotion.standard,
            padding: const EdgeInsets.all(MechXSpacing.sm),
            decoration: BoxDecoration(
              color: _hover ? colors.surfaceHover : colors.background,
              borderRadius: MechXRadii.control,
              border: Border.all(
                  color: _hover ? colors.textMuted : colors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.body.copyWith(color: colors.textSecondary)),
                ),
                const SizedBox(width: MechXSpacing.xs),
                Text('Edit',
                    style: type.caption.copyWith(color: colors.accent)),
              ],
            ),
          ),
        ),
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

    // J3 (revised): the zoom pill reflects the Layout sheet's viewport — the
    // only zoom this bar can read truthfully. On the Riser/Electrical
    // workspaces (whose real zoom lives in their own canvases, which already
    // carry their own zoom readouts) and on non-design screens, the pill is
    // OMITTED entirely rather than showing a literal '—': those canvases own
    // their zoom, and an em-dash readout reads as broken chrome, not as
    // "not applicable". Absence is the honest state.
    final section = ref.watch(shellSectionProvider);
    final view = ref.watch(workspaceViewProvider);
    final onLayout =
        section == ShellSection.design && view == WorkspaceView.plan;
    final current = state.current;
    final vt =
        (onLayout && current != null) ? state.viewportFor(current.id) : null;
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
            // D1: a small, permanent entry point for the command palette, which
            // is otherwise reachable only via the invisible Ctrl/Cmd+K
            // accelerator. A quiet keycap pill (a hint, not a primary action)
            // that both advertises the shortcut and opens the palette on click.
            _PaletteHintButton(
              onTap: () =>
                  ref.read(commandPaletteOpenProvider.notifier).open(),
            ),
            const SizedBox(width: MechXSpacing.sm),
            // Actions sit flush-right. The zoom read-out is a quiet pill: a
            // soft tinted fill carries it, no hairline border — less visual
            // mass than a fully-outlined chip (HIG). Only meaningful on
            // Layout (see the J3 note above) — omitted entirely elsewhere.
            if (onLayout) ...[
              Container(
                key: const ValueKey('zoom-pill'),
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
            ],
            MechXButton(
              label: context.strings(StringKey.shellOpen),
              onPressed: () => openProject(context, ref),
            ),
            const SizedBox(width: MechXSpacing.xs),
            MechXButton(
              label: context.strings(StringKey.shellSave),
              // F6: Save is the top bar's primary anchor — it wears the solid
              // accent while the work is dirty (the same `projectDirtyProvider`
              // signal that drives the "edited" dot), and falls back to the
              // quiet gray button once the work matches the last clean save.
              primary: dirty,
              onPressed: () => saveProject(ref),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: context.strings(StringKey.shellImportPdf),
              onPressed: () => importPlan(context, ref),
            ),
            const SizedBox(width: MechXSpacing.sm),
            // F6: the theme toggle is DEMOTED from a full gray button (a visual
            // peer of Save) to a compact, muted icon control so it stops
            // competing with the primary action. Names the ACTION for a screen
            // reader (act toward the opposite mode).
            _ThemeToggleButton(
              semanticLabel: brightness == Brightness.dark
                  ? context.strings(StringKey.shellSwitchToLight)
                  : context.strings(StringKey.shellSwitchToDark),
              onTap: () => ref.read(brightnessProvider.notifier).toggle(),
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

/// The top-bar command-palette affordance (D1): a quiet keycap pill mirroring
/// the zoom read-out's soft-tint idiom — a permanent, unobtrusive entry point
/// for the palette (which otherwise has no visible entry at all, only the
/// invisible Ctrl/Cmd+K accelerator). A hint, not a primary action: it never
/// wears the solid accent; it brightens on hover and opens the palette on
/// click. The keycap is plain ASCII ("Ctrl K", Windows-first) so it can never
/// render as tofu, and it is keyboard-focusable + Enter/Space-activatable via
/// the shared focus ring, announced as an "Open command palette" button.
class _PaletteHintButton extends StatefulWidget {
  final VoidCallback onTap;
  const _PaletteHintButton({required this.onTap});

  @override
  State<_PaletteHintButton> createState() => _PaletteHintButtonState();
}

class _PaletteHintButtonState extends State<_PaletteHintButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Semantics(
      button: true,
      label: 'Open command palette',
      child: MechXFocusRing(
        borderRadius: MechXRadii.control,
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
                horizontal: MechXSpacing.sm,
                vertical: MechXSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: _hover ? colors.surfaceHover : colors.background,
                borderRadius: MechXRadii.control,
              ),
              child: Text(
                'Ctrl K',
                style: type.mono.copyWith(
                  color: _hover ? colors.textSecondary : colors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The demoted theme toggle (F6): a compact, muted icon control — the sibling
/// of [_PaletteHintButton]'s quiet idiom — so the "switch appearance" action no
/// longer reads as a gray-button peer of the primary Save. Transparent at rest
/// (an iconic glyph, not a filled chip), it brightens on hover, is
/// keyboard-focusable + Enter/Space-activatable via the shared focus ring, and
/// announces its ACTION (switch to light / dark) to a screen reader. The glyph
/// is custom-painted (no icon font) so it can never render as tofu.
class _ThemeToggleButton extends StatefulWidget {
  final String semanticLabel;
  final VoidCallback onTap;
  const _ThemeToggleButton({required this.semanticLabel, required this.onTap});

  @override
  State<_ThemeToggleButton> createState() => _ThemeToggleButtonState();
}

class _ThemeToggleButtonState extends State<_ThemeToggleButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // L5/M4: the demoted, icon-only toggle previously only named itself for a
    // screen reader (semanticLabel); a hover tooltip now shows the same text
    // to a sighted mouse user too.
    return MechXTooltip(
      message: widget.semanticLabel,
      child: Semantics(
        button: true,
        label: widget.semanticLabel,
        child: MechXFocusRing(
          borderRadius: MechXRadii.control,
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
                  horizontal: MechXSpacing.sm,
                  vertical: MechXSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: _hover ? colors.surfaceHover : const Color(0x00000000),
                  borderRadius: MechXRadii.control,
                ),
                child: CustomPaint(
                  size: const Size(16, 16),
                  painter: _ThemeGlyphPainter(
                    color: _hover ? colors.textSecondary : colors.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "appearance" (light/dark) mark: a ring with its left half filled — the
/// conventional half-moon-in-a-circle theme glyph. Custom-painted from
/// primitives (no icon font, no trig), so it never renders as tofu.
class _ThemeGlyphPainter extends CustomPainter {
  final Color color;
  const _ThemeGlyphPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final c = Offset(w * 0.5, h * 0.5);
    final r = w * 0.30;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(c, r, stroke);
    // The left half: a semicircle (chord = 2·r, radius = r ⇒ exact half circle)
    // closed back along the vertical diameter.
    final leftHalf = Path()
      ..moveTo(c.dx, c.dy - r)
      ..arcToPoint(
        Offset(c.dx, c.dy + r),
        radius: Radius.circular(r),
        clockwise: false,
      )
      ..close();
    canvas.drawPath(leftHalf, fill);
  }

  @override
  bool shouldRepaint(_ThemeGlyphPainter old) => old.color != color;
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
    // unverified values to flag — a quiet caption otherwise. H7a — verify rows
    // now name their specific value in the title, so match on the stable
    // [DesignIssue.isVerify] flag rather than the old generic literal.
    final hasUnverified = ref
        .watch(designIssuesProvider)
        .any((i) => i.isVerify);

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
/// message and a quiet success-tinted pill — bridged in and out — when there
/// is. The pill mirrors the zoom read-out's soft idiom (a tint, no border).
///
/// C4: the pill used to pop straight in and out. It now ENTERS with a fade plus
/// a 2 px upward settle (`appear`) and LEAVES on a shorter fade (`dismiss`), so
/// a confirmation registers as an arrival rather than a flicker. Both durations
/// go through [MechXMotion.resolve], so the OS reduced-motion setting collapses
/// them to an instant swap. Occasional-tier surface (a handful of times a day),
/// hence real — but still sub-quarter-second — motion.
class _StatusConfirmation extends ConsumerWidget {
  const _StatusConfirmation();

  /// Fade + a small rise, shared by the entering and leaving child (the leaving
  /// one runs the same curve in reverse over the shorter `reverseDuration`, so
  /// it sinks back the 2 px as it fades).
  static Widget _bridge(Widget child, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      child: FadeTransition(opacity: animation, child: child),
      builder: (context, inner) => Transform.translate(
        offset: Offset(0, 2 * (1 - animation.value)),
        child: inner,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final message = ref.watch(statusMessageProvider);
    return AnimatedSwitcher(
      duration: MechXMotion.resolve(context, MechXMotion.appear),
      reverseDuration: MechXMotion.resolve(context, MechXMotion.dismiss),
      switchInCurve: MechXMotion.standard,
      switchOutCurve: MechXMotion.standard,
      transitionBuilder: _bridge,
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
///
/// Deliberately NOT routed through [MechXMotion.resolve] (C1): this is an
/// indeterminate PROGRESS indicator, not decorative motion — it is the only cue
/// that a slow operation is still alive, and reduced-motion guidance exempts
/// that class of feedback. (A zero duration would also assert on `repeat()`.)
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
    // C1: both durations go through the reduced-motion gate.
    final appear = MechXMotion.resolve(context, MechXMotion.appear);
    final content = AnimatedSwitcher(
      duration: appear,
      switchInCurve: MechXMotion.standard,
      switchOutCurve: MechXMotion.standard,
      child: child ?? const SizedBox(width: double.infinity),
    );
    // `AnimatedSize` cannot take Duration.zero (RenderAnimatedSize starts its
    // controller from performLayout, and a zero-duration forward() notifies
    // synchronously, re-dirtying the render object mid-layout). Under OS
    // reduced motion, drop the size animation entirely — which is precisely
    // what the setting asks for; the resting layout is identical either way.
    if (appear == Duration.zero) return content;
    return AnimatedSize(
      duration: appear,
      curve: MechXMotion.standard,
      alignment: Alignment.topCenter,
      child: content,
    );
  }
}

/// Human-readable "autosaved …" fragment for the recovery banner: a short
/// delta for anything within the last day, else the wall-clock time the
/// snapshot was written; a missing mtime (unreadable stat) degrades to a
/// generic "earlier" rather than guessing. ASCII only. A negative delta
/// (clock skew) falls into the "just now" bucket rather than throwing.
String _recoveryWhen(BuildContext context, DateTime? savedAt) {
  if (savedAt == null) return context.strings(StringKey.shellRecoverEarlier);
  final delta = DateTime.now().difference(savedAt);
  if (delta.inMinutes < 1) {
    return context.strings(StringKey.shellRecoverJustNow);
  }
  if (delta.inMinutes < 60) {
    return context.strings
        .format(StringKey.shellRecoverMinutesAgo, {'n': delta.inMinutes});
  }
  if (delta.inHours < 24) {
    return context.strings
        .format(StringKey.shellRecoverHoursAgo, {'n': delta.inHours});
  }
  final hh = savedAt.hour.toString().padLeft(2, '0');
  final mm = savedAt.minute.toString().padLeft(2, '0');
  return context.strings
      .format(StringKey.shellRecoverAtTime, {'time': '$hh:$mm'});
}

/// Offers to restore a crash-recovery snapshot from a previous session that
/// ended without a clean exit. Names the project and says when it was
/// autosaved (rather than a bare "unsaved work?"), and discard is made
/// deliberate: the first tap on "Discard snapshot" only arms a
/// confirmation (relabelling the button), timing back out after a few
/// seconds; only the SECOND, confirming tap actually clears the snapshot —
/// so a stray click can never destroy the only copy.
class _RecoveryBanner extends ConsumerStatefulWidget {
  const _RecoveryBanner();

  @override
  ConsumerState<_RecoveryBanner> createState() => _RecoveryBannerState();
}

class _RecoveryBannerState extends ConsumerState<_RecoveryBanner> {
  bool _confirmingDiscard = false;
  Timer? _confirmTimer;

  static const _confirmWindow = Duration(seconds: 4);

  @override
  void dispose() {
    _confirmTimer?.cancel();
    super.dispose();
  }

  void _armDiscardConfirm() {
    _confirmTimer?.cancel();
    setState(() => _confirmingDiscard = true);
    _confirmTimer = Timer(_confirmWindow, () {
      if (mounted) setState(() => _confirmingDiscard = false);
    });
  }

  Future<void> _discard() async {
    _confirmTimer?.cancel();
    // Clear the snapshot's OWN per-project slot (not a stale global default);
    // falls back to the untitled slot when the path is unknown.
    await clearRecovery(path: ref.read(recoveryDocProvider)?.recoveryPath);
    ref.read(recoveryDocProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(recoveryDocProvider);
    final colors = context.colors;
    final type = context.type;
    // A snapshot record with a null doc = the file exists but could not be
    // decoded (torn by an interrupted write). Surfaced distinctly — it can't
    // be restored, but it must never masquerade as a clean exit.
    final doc = snapshot?.doc;

    return _AnimatedBanner(
      child: snapshot == null
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
                      doc == null
                          // H5 — say what to DO, not what broke internally.
                          ? context.strings(StringKey.recoveryTornUnreadable)
                          : context.strings
                              .format(StringKey.shellRecoverPrompt, {
                              'name': doc.projectName,
                              'when': _recoveryWhen(context, snapshot.savedAt),
                            }),
                      style: type.caption.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  if (doc != null)
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
                        // Re-link the file identity so the next Ctrl+S saves back
                        // to the source `.mechx` (not a Save-As fork) — when the
                        // file still exists. B2. (snapshot is promoted non-null
                        // inside this branch.)
                        final src = snapshot.sourcePath;
                        if (src != null &&
                            src.isNotEmpty &&
                            File(src).existsSync()) {
                          ref
                              .read(currentProjectPathProvider.notifier)
                              .set(src);
                        }
                        _discard();
                      },
                    ),
                  const SizedBox(width: MechXSpacing.sm),
                  MechXButton(
                    key: const ValueKey('recovery-discard'),
                    label: context.strings(_confirmingDiscard
                        ? StringKey.shellDiscardConfirm
                        : StringKey.shellDiscardSnapshot),
                    tone: MechXButtonTone.danger,
                    onPressed:
                        _confirmingDiscard ? _discard : _armDiscardConfirm,
                  ),
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
              duration: MechXMotion.resolve(context, MechXMotion.hover),
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
