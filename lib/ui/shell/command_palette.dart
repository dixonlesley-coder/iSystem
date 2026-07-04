/// The Ctrl/Cmd+K command palette — a centred, modal overlay for discovering
/// and running the app's key actions (switch a DESIGN view, toggle a layer,
/// pick a draw tool, start calibration, export the report, …) from the keyboard.
///
/// App-shell-local: hosted as a non-layout [Stack] layer in `app_shell.dart`,
/// gated on [commandPaletteOpenProvider] (renders nothing when closed, so the
/// goldens are unchanged at rest). Each [_Command] runs through the EXISTING
/// controllers/providers — the palette adds no model state of its own.
///
/// Custom design system only (no Material): a tinted scrim + a [MechXTheme]
/// card, a text filter, and a fuzzy-filtered list. Esc closes; Up/Down move the
/// highlight; Enter runs it.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_settings.dart';
import '../../store/ai_copilot_store.dart';
import '../../store/annotation_store.dart';
import '../../store/app_state.dart';
import '../../store/calibration_store.dart';
import '../../store/command_store.dart';
import '../../store/electrical_store.dart';
import '../../store/history_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../inspector/project_panel.dart'
    show
        exportAnnotatedPlanPdf,
        exportCalcReport,
        exportCalcReportPdf,
        exportDrawingDxf,
        exportDrawingPdf,
        exportEquipmentSchedule,
        exportEquipmentSchedulePdf,
        exportMepUnifiedReport,
        exportMepUnifiedReportPdf,
        exportSubmittalPackage;
import '../shell/duplicate_floor_dialog.dart';
import '../shell/nav_rail.dart';
import '../shell/project_io.dart';
import '../shell/templates_dialog.dart';
import '../theme/design_tokens.dart';
import '../widgets/glass_surface.dart';
import '../theme/mechx_theme.dart';

/// One runnable palette command: a stable [id] (recency key, never shown), a
/// [title] (matched + shown), an optional [subtitle] hint (also matched), an
/// optional right-aligned [shortcut] keycap hint, and the [run] action wired to
/// live controllers.
@immutable
class _Command {
  final String id;
  final String title;
  final String subtitle;
  final String shortcut;
  final VoidCallback run;

  const _Command({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.shortcut = '',
    required this.run,
  });
}

/// Assemble the command list against the live [ref] + [context]. Built fresh
/// each open so the actions close over the current providers.
List<_Command> _buildCommands(WidgetRef ref, BuildContext context) {
  final shell = ref.read(shellSectionProvider.notifier);
  final viewCtrl = ref.read(workspaceViewProvider.notifier);
  final net = ref.read(networkControllerProvider.notifier);
  final active = ref.read(activeDisciplineProvider.notifier);
  final vis = ref.read(layerVisibilityProvider.notifier);

  void openDesign(WorkspaceView v) {
    viewCtrl.set(v);
    shell.set(ShellSection.design);
  }

  // Enable one annotation mode on the Layout canvas, mirroring the draw
  // toolbar's exclusive toggle exactly: the three modes are mutually exclusive
  // and turning one on collapses the draw tool to Select.
  void enableMode({bool measure = false, bool tank = false, bool room = false}) {
    openDesign(WorkspaceView.plan);
    ref.read(measureModeProvider.notifier).set(measure);
    ref.read(tankModeProvider.notifier).set(tank);
    ref.read(roomModeProvider.notifier).set(room);
    net.setTool(DrawTool.select);
  }

  return [
    // — Switch the DESIGN workspace view —
    _Command(
      id: 'view.layout',
      title: 'Go to Layout',
      subtitle: 'Design view',
      run: () => openDesign(WorkspaceView.plan),
    ),
    _Command(
      id: 'view.riser',
      title: 'Go to Riser',
      subtitle: 'Vertical riser / elevation editor',
      run: () => openDesign(WorkspaceView.schematic),
    ),
    _Command(
      id: 'view.electrical',
      title: 'Go to Electrical',
      subtitle: 'Design view',
      run: () => openDesign(WorkspaceView.electrical),
    ),
    _Command(
      id: 'view.review',
      title: 'Go to Review',
      subtitle: 'Show issues + summaries',
      run: () => shell.set(ShellSection.review),
    ),
    _Command(
      id: 'view.issues',
      title: 'Show issues',
      subtitle: 'Open the Review hub',
      run: () => shell.set(ShellSection.review),
    ),
    _Command(
      id: 'view.commercial',
      title: 'Go to Commercial',
      subtitle: 'BOM + quotation',
      run: () => shell.set(ShellSection.commercial),
    ),
    _Command(
      id: 'view.building',
      title: 'Go to Building',
      subtitle: 'Floors + occupancy',
      run: () => shell.set(ShellSection.building),
    ),
    _Command(
      id: 'view.preferences',
      title: 'Go to Preferences',
      run: () => shell.set(ShellSection.preferences),
    ),
    // — Toggle a discipline layer on the Layout canvas —
    for (final layer in DisciplineLayer.values)
      _Command(
        id: 'layer.toggle.${layer.name}',
        title: 'Toggle ${layer.label} layer',
        subtitle: 'Layout visibility',
        run: () {
          openDesign(WorkspaceView.plan);
          vis.toggle(layer);
        },
      ),
    for (final layer in DisciplineLayer.values)
      _Command(
        id: 'layer.edit.${layer.name}',
        title: 'Edit ${layer.label} layer',
        subtitle: 'Make it the active layer',
        run: () {
          openDesign(WorkspaceView.plan);
          active.set(layer);
        },
      ),
    // — Pick a draw / annotation tool —
    // The single-key accelerators (V/R/E/M/K/B) fire on the mechanical Layout
    // canvas (see `layout_canvas.dart`); shown here as keycaps so the palette
    // advertises them (D2).
    _Command(
      id: 'tool.select',
      title: 'Tool: Select',
      subtitle: 'Draw tool',
      shortcut: 'V',
      run: () => net.setTool(DrawTool.select),
    ),
    _Command(
      id: 'tool.run',
      title: 'Tool: Draw run',
      subtitle: 'Draw tool',
      shortcut: 'R',
      run: () {
        openDesign(WorkspaceView.plan);
        net.setTool(DrawTool.drawRun);
      },
    ),
    _Command(
      id: 'tool.riser',
      title: 'Tool: Draw riser',
      subtitle: 'Draw tool',
      shortcut: 'E',
      run: () {
        openDesign(WorkspaceView.plan);
        net.setTool(DrawTool.drawRiser);
      },
    ),
    _Command(
      id: 'tool.measure',
      title: 'Tool: Measure',
      subtitle: 'Dimension a distance on the plan',
      shortcut: 'M',
      run: () => enableMode(measure: true),
    ),
    _Command(
      id: 'tool.tank',
      title: 'Tool: Tank area',
      subtitle: 'Draw a tank / reservoir footprint',
      shortcut: 'K',
      run: () => enableMode(tank: true),
    ),
    _Command(
      id: 'tool.room',
      title: 'Tool: Room area',
      subtitle: 'Draw a room footprint for air sizing',
      shortcut: 'B',
      run: () => enableMode(room: true),
    ),
    // — Edit —
    _Command(
      id: 'edit.undo',
      title: 'Undo',
      subtitle: 'Revert the most recent edit',
      shortcut: 'Ctrl+Z',
      run: () => ref.read(historyProvider.notifier).undo(),
    ),
    _Command(
      id: 'edit.redo',
      title: 'Redo',
      subtitle: 'Reapply the undone edit',
      shortcut: 'Ctrl+Y',
      run: () => ref.read(historyProvider.notifier).redo(),
    ),
    // — Actions —
    _Command(
      id: 'ai.ask',
      title: 'Ask Claude',
      subtitle: 'Design or change the selection with AI',
      run: () => ref.read(copilotOpenProvider.notifier).open(),
    ),
    _Command(
      id: 'net.clear',
      title: 'Clear drawing',
      subtitle: 'Remove all drawn elements (undoable)',
      run: net.clear,
    ),
    _Command(
      id: 'floor.dupUp',
      title: 'Duplicate floor up',
      subtitle: "Copy this floor's runs to the floor above",
      run: () {
        final sheets = ref.read(sheetsControllerProvider);
        final levelCount =
            ref.read(projectControllerProvider).building.levelCount;
        final current = sheets.current;
        if (current == null) return;
        final fromFloor = sheets.floorFor(current.id, levelCount);
        final toFloor = fromFloor + 1;
        if (toFloor >= levelCount) return;
        // Resolve the destination by the sheet→floor MAPPING (a sheet may carry
        // an explicit floor override, so list index need not equal floor index).
        String? toSheetId;
        for (final s in sheets.sheets) {
          if (sheets.floorFor(s.id, levelCount) == toFloor) {
            toSheetId = s.id;
            break;
          }
        }
        if (toSheetId == null) return;
        net.duplicateFloor(
          fromSheetId: current.id,
          fromFloor: fromFloor,
          toSheetId: toSheetId,
          toFloor: toFloor,
        );
      },
    ),
    _Command(
      id: 'floor.dupRange',
      title: 'Duplicate floor to…',
      subtitle: "Copy a floor's runs onto a range of floors",
      run: () => showDuplicateFloorDialog(context),
    ),
    _Command(
      id: 'project.template',
      title: 'Apply building template',
      subtitle: 'Prefill floors / occupancy on the current project',
      run: () => showTemplatesDialog(context),
    ),
    _Command(
      id: 'calibrate.start',
      title: 'Start calibration',
      subtitle: 'Mark a known distance on the sheet',
      run: () {
        openDesign(WorkspaceView.plan);
        ref.read(calibrationControllerProvider.notifier).start();
      },
    ),
    // — Deliverable exports —
    _Command(
      id: 'export.calc',
      title: 'Export calculation report',
      subtitle: 'Markdown',
      run: () => exportCalcReport(ref),
    ),
    _Command(
      id: 'export.calcPdf',
      title: 'Export calculation report (PDF)',
      subtitle: 'Typeset A4 PDF',
      run: () => exportCalcReportPdf(ref),
    ),
    _Command(
      id: 'export.mep',
      title: 'Export unified MEP report',
      subtitle: 'Markdown — mechanical + electrical',
      run: () => exportMepUnifiedReport(ref),
    ),
    _Command(
      id: 'export.mepPdf',
      title: 'Export unified MEP report (PDF)',
      subtitle: 'Typeset A4 PDF — mechanical + electrical',
      run: () => exportMepUnifiedReportPdf(ref),
    ),
    _Command(
      id: 'export.equip',
      title: 'Export equipment schedule',
      subtitle: 'Markdown + CSV',
      run: () => exportEquipmentSchedule(ref),
    ),
    _Command(
      id: 'export.equipPdf',
      title: 'Export equipment schedule (PDF)',
      subtitle: 'Typeset A4 PDF',
      run: () => exportEquipmentSchedulePdf(ref),
    ),
    _Command(
      id: 'export.dxf',
      title: 'Export drawing (DXF)',
      subtitle: 'Current sheet — vector CAD',
      run: () => exportDrawingDxf(ref),
    ),
    _Command(
      id: 'export.pdf',
      title: 'Export drawing (PDF)',
      subtitle: 'Current sheet — vector',
      run: () => exportDrawingPdf(ref),
    ),
    _Command(
      id: 'export.planPdf',
      title: 'Export annotated plan (PDF)',
      subtitle: 'Current sheet — with lengths + title block',
      run: () => exportAnnotatedPlanPdf(ref),
    ),
    _Command(
      id: 'export.submittal',
      title: 'Export submittal package',
      subtitle: 'Reports + drawings + BOM to a folder',
      run: () => exportSubmittalPackage(ref),
    ),
    // — Project file —
    _Command(
      id: 'project.new',
      title: 'New project',
      subtitle: 'Start a blank project (guards unsaved work)',
      run: () => newProject(context, ref),
    ),
    _Command(
      id: 'project.import',
      title: 'Import plan',
      subtitle: 'Add a PDF / DXF / DWG floor plan',
      run: () => importPlan(context, ref),
    ),
    _Command(
      id: 'project.open',
      title: 'Open project',
      subtitle: 'Open a .mechx project',
      shortcut: 'Ctrl+O',
      run: () => openProject(context, ref),
    ),
    // Reopen a recent project without the OS file dialog (machine-local MRU).
    for (final e in ref.read(appSettingsProvider).mru.take(6))
      _Command(
        id: 'project.recent.${e.path}',
        title: 'Open recent: ${e.name}',
        subtitle: 'Recent project',
        run: () => openProjectPath(context, ref, e.path),
      ),
    _Command(
      id: 'project.save',
      title: 'Save project',
      subtitle: 'Saves to the open file',
      shortcut: 'Ctrl+S',
      run: () => saveProject(ref),
    ),
    _Command(
      id: 'project.saveAs',
      title: 'Save project as...',
      subtitle: 'Pick a new file',
      shortcut: 'Ctrl+Shift+S',
      run: () => saveProject(ref, saveAs: true),
    ),
    _Command(
      id: 'theme.toggle',
      title: 'Toggle light / dark',
      run: () => ref.read(brightnessProvider.notifier).toggle(),
    ),
  ];
}

/// The non-layout overlay layer hosted at app-shell level. Renders nothing when
/// the palette is closed (so the goldens are unchanged at rest).
class CommandPaletteOverlay extends ConsumerWidget {
  const CommandPaletteOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(commandPaletteOpenProvider);
    if (!open) return const SizedBox.shrink();
    final colors = context.colors;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(commandPaletteOpenProvider.notifier).close(),
        child: ColoredBox(
          color: colors.scrim,
          child: Align(
            alignment: const Alignment(0, -0.35),
            // Swallow taps on the card itself (don't dismiss).
            child: GestureDetector(
              onTap: () {},
              child: const _PaletteCard(),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteCard extends ConsumerStatefulWidget {
  const _PaletteCard();

  @override
  ConsumerState<_PaletteCard> createState() => _PaletteCardState();
}

class _PaletteCardState extends ConsumerState<_PaletteCard> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    // Autofocus the filter field on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _close() => ref.read(commandPaletteOpenProvider.notifier).close();

  List<_Command> _filtered() {
    final all = _buildCommands(ref, context);
    final recent = ref.read(recentCommandsProvider);
    // Recency rank: 0 = most-recently-run, larger = older, huge = never run.
    int recencyRank(_Command c) {
      final i = recent.indexOf(c.id);
      return i < 0 ? 1 << 30 : i;
    }

    if (_query.trim().isEmpty) {
      // No query: keep registration order but hoist recently-run commands to
      // the top. Carry the original index so the sort is deterministic (Dart's
      // List.sort isn't guaranteed stable).
      final indexed = <(int, _Command)>[
        for (var i = 0; i < all.length; i++) (i, all[i]),
      ];
      indexed.sort((a, b) {
        final ra = recencyRank(a.$2);
        final rb = recencyRank(b.$2);
        if (ra != rb) return ra.compareTo(rb);
        return a.$1.compareTo(b.$1);
      });
      return indexed.map((e) => e.$2).toList(growable: false);
    }
    // With a query: rank by fuzzy score over title AND subtitle, breaking ties
    // by recency (a recently-run command wins an equal-score tie).
    final scored = <(int, int, _Command)>[];
    for (final c in all) {
      final s = commandMatchScore(_query, c.title, c.subtitle);
      if (s != null) scored.add((s, recencyRank(c), c));
    }
    scored.sort((a, b) {
      if (a.$1 != b.$1) return b.$1.compareTo(a.$1);
      return a.$2.compareTo(b.$2);
    });
    return scored.map((e) => e.$3).toList(growable: false);
  }

  void _runAt(List<_Command> list, int index) {
    if (list.isEmpty) return;
    final i = index.clamp(0, list.length - 1);
    // Record the run BEFORE closing (which disposes this state) so the next
    // open hoists it to the top.
    ref.read(recentCommandsProvider.notifier).record(list[i].id);
    _close();
    list[i].run();
  }

  KeyEventResult _onKey(List<_Command> list, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight =
          list.isEmpty ? 0 : (_highlight + 1) % list.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight =
          list.isEmpty ? 0 : (_highlight - 1 + list.length) % list.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _runAt(list, _highlight);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final list = _filtered();
    if (_highlight >= list.length) _highlight = list.isEmpty ? 0 : list.length - 1;

    return Focus(
      onKeyEvent: (_, event) => _onKey(list, event),
      child: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 460),
          // Liquid-Glass command palette — a translucent blurred card.
          child: GlassSurface(
            borderRadius: MechXRadii.card,
            blurSigma: MechXGlass.blurSigmaLight,
            shadow: MechXShadow.popover,
            child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Filter field.
            Padding(
              padding: const EdgeInsets.fromLTRB(MechXSpacing.md,
                  MechXSpacing.md, MechXSpacing.md, MechXSpacing.sm),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: MechXSpacing.sm,
                  vertical: MechXSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: MechXRadii.control,
                  border: Border.all(color: colors.border),
                ),
                child: EditableText(
                  controller: _controller,
                  focusNode: _focus,
                  style:
                      type.body.copyWith(color: colors.textPrimary),
                  cursorColor: colors.accent,
                  backgroundCursorColor: colors.textMuted,
                  selectionColor: colors.accentMuted,
                  onChanged: (v) => setState(() {
                    _query = v;
                    _highlight = 0;
                  }),
                  onSubmitted: (_) => _runAt(_filtered(), _highlight),
                ),
              ),
            ),
            if (_query.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    MechXSpacing.md, 0, MechXSpacing.md, MechXSpacing.sm),
                child: Text(
                  'Type to filter commands. Up / Down to move, Enter to run, Esc to close.',
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
              ),
            Container(height: 1, color: colors.border),
            Flexible(
              child: list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(MechXSpacing.md),
                      child: Text(
                        'No matching commands.',
                        style:
                            type.caption.copyWith(color: colors.textMuted),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(
                          vertical: MechXSpacing.xs),
                      itemCount: list.length,
                      itemBuilder: (ctx, i) => _CommandRow(
                        command: list[i],
                        highlighted: i == _highlight,
                        onHover: () => setState(() => _highlight = i),
                        onTap: () => _runAt(list, i),
                      ),
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

class _CommandRow extends StatelessWidget {
  final _Command command;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _CommandRow({
    required this.command,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm, vertical: 1),
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 2),
          decoration: BoxDecoration(
            color: highlighted ? colors.accentMuted : const Color(0x00000000),
            borderRadius: MechXRadii.control,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  command.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.body.copyWith(
                    color:
                        highlighted ? colors.accent : colors.textPrimary,
                  ),
                ),
              ),
              if (command.subtitle.isNotEmpty) ...[
                const SizedBox(width: MechXSpacing.sm),
                Text(
                  command.subtitle,
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
              ],
              // Right-aligned keyboard-shortcut hint (a keycap), for the rows
              // that have a global accelerator.
              if (command.shortcut.isNotEmpty) ...[
                const SizedBox(width: MechXSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: MechXSpacing.xs, vertical: 1),
                  decoration: BoxDecoration(
                    color: colors.surfaceHover,
                    borderRadius: MechXRadii.small,
                    border: Border.all(color: colors.border),
                  ),
                  child: Text(
                    command.shortcut,
                    // Monospace so keycaps line up cleanly down the right edge
                    // (D2), muted so they read as a hint not a label.
                    style: type.micro.copyWith(
                      fontFamily: MechXTypography.monoFamily,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
