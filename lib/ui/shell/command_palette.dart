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

import '../../store/ai_copilot_store.dart';
import '../../store/app_state.dart';
import '../../store/calibration_store.dart';
import '../../store/command_store.dart';
import '../../store/electrical_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../inspector/project_panel.dart' show exportCalcReport;
import '../shell/nav_rail.dart';
import '../shell/templates_dialog.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// One runnable palette command: a [title] (matched + shown), an optional
/// [subtitle] hint, and the [run] action wired to live controllers.
@immutable
class _Command {
  final String title;
  final String subtitle;
  final VoidCallback run;

  const _Command({required this.title, this.subtitle = '', required this.run});
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

  return [
    // — Switch the DESIGN workspace view —
    _Command(
      title: 'Go to Layout',
      subtitle: 'Design view',
      run: () => openDesign(WorkspaceView.plan),
    ),
    _Command(
      title: 'Go to Riser',
      subtitle: 'Vertical riser / elevation editor',
      run: () => openDesign(WorkspaceView.schematic),
    ),
    _Command(
      title: 'Go to Electrical',
      subtitle: 'Design view',
      run: () => openDesign(WorkspaceView.electrical),
    ),
    _Command(
      title: 'Go to Review',
      subtitle: 'Show issues + summaries',
      run: () => shell.set(ShellSection.review),
    ),
    _Command(
      title: 'Show issues',
      subtitle: 'Open the Review hub',
      run: () => shell.set(ShellSection.review),
    ),
    _Command(
      title: 'Go to Commercial',
      subtitle: 'BOM + quotation',
      run: () => shell.set(ShellSection.commercial),
    ),
    _Command(
      title: 'Go to Building',
      subtitle: 'Floors + occupancy',
      run: () => shell.set(ShellSection.building),
    ),
    _Command(
      title: 'Go to Preferences',
      run: () => shell.set(ShellSection.preferences),
    ),
    // — Toggle a discipline layer on the Layout canvas —
    for (final layer in DisciplineLayer.values)
      _Command(
        title: 'Toggle ${layer.label} layer',
        subtitle: 'Layout visibility',
        run: () {
          openDesign(WorkspaceView.plan);
          vis.toggle(layer);
        },
      ),
    for (final layer in DisciplineLayer.values)
      _Command(
        title: 'Edit ${layer.label} layer',
        subtitle: 'Make it the active layer',
        run: () {
          openDesign(WorkspaceView.plan);
          active.set(layer);
        },
      ),
    // — Pick a draw tool —
    _Command(
      title: 'Tool: Select',
      subtitle: 'Draw tool',
      run: () => net.setTool(DrawTool.select),
    ),
    _Command(
      title: 'Tool: Draw run',
      subtitle: 'Draw tool',
      run: () {
        openDesign(WorkspaceView.plan);
        net.setTool(DrawTool.drawRun);
      },
    ),
    _Command(
      title: 'Tool: Draw riser',
      subtitle: 'Draw tool',
      run: () {
        openDesign(WorkspaceView.plan);
        net.setTool(DrawTool.drawRiser);
      },
    ),
    // — Actions —
    _Command(
      title: 'Ask Claude',
      subtitle: 'Design or change the selection with AI',
      run: () => ref.read(copilotOpenProvider.notifier).open(),
    ),
    _Command(
      title: 'Clear drawing',
      subtitle: 'Remove all drawn elements (undoable)',
      run: net.clear,
    ),
    _Command(
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
      title: 'New from template',
      subtitle: 'Prefill floors / occupancy',
      run: () => showTemplatesDialog(context),
    ),
    _Command(
      title: 'Start calibration',
      subtitle: 'Mark a known distance on the sheet',
      run: () {
        openDesign(WorkspaceView.plan);
        ref.read(calibrationControllerProvider.notifier).start();
      },
    ),
    _Command(
      title: 'Export calculation report',
      subtitle: 'Markdown',
      run: () => exportCalcReport(ref),
    ),
    _Command(
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
    if (_query.trim().isEmpty) return all;
    final scored = <(int, _Command)>[];
    for (final c in all) {
      final s = fuzzyScore(_query, c.title);
      if (s != null) scored.add((s, c));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return scored.map((e) => e.$2).toList(growable: false);
  }

  void _runAt(List<_Command> list, int index) {
    if (list.isEmpty) return;
    final i = index.clamp(0, list.length - 1);
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
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 460),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: MechXRadii.card,
          boxShadow: MechXShadow.popover,
          border: Border.all(color: colors.border),
        ),
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
            ],
          ),
        ),
      ),
    );
  }
}
