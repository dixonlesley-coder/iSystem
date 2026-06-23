import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/autosave.dart';
import '../data/pdf_import.dart';
import '../data/project_document.dart';
import '../data/recovery.dart';
import '../store/app_state.dart';
import '../store/project_store.dart';
import '../store/sheets_store.dart';
import 'canvas/sheet_canvas.dart';
import 'inspector/project_panel.dart';
import 'schematic/schematic_view.dart';
import 'sheets/sheet_rail.dart';
import 'theme/design_tokens.dart';
import 'theme/mechx_theme.dart';
import 'widgets/mechx_button.dart';

/// Top-level P0 layout: top bar · (sheet rail | canvas) · status bar.
/// No Material Scaffold — a restrained, custom shell (§4).
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: colors.background,
      child: SafeArea(
        child: Column(
          children: [
            const _TopBar(),
            Container(height: 1, color: colors.border),
            const _RecoveryBanner(),
            const _ErrorBanner(),
            Expanded(
              child: Row(
                children: [
                  const SheetRail(),
                  Container(width: 1, color: colors.border),
                  Expanded(
                    child: Consumer(
                      builder: (context, ref, _) =>
                          ref.watch(showSchematicProvider)
                              ? const SchematicView()
                              : const SheetCanvas(),
                    ),
                  ),
                  Container(width: 1, color: colors.border),
                  const ProjectPanel(),
                ],
              ),
            ),
            Container(height: 1, color: colors.border),
            const _StatusBar(),
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
      dialogTitle: 'Save MechX project',
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
    final showSchematic = ref.watch(showSchematicProvider);
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
            Text('MechX', style: type.title.copyWith(color: colors.textPrimary)),
            const SizedBox(width: MechXSpacing.sm),
            Flexible(
              child: Text(
                projectName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.body.copyWith(color: colors.textMuted),
              ),
            ),
            const Spacer(),
            // Actions sit flush-right.
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm,
                vertical: MechXSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: MechXRadii.control,
                border: Border.all(color: colors.border),
              ),
              child: Text(
                zoom,
                style: type.mono.copyWith(color: colors.textSecondary),
              ),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: 'Open',
              onPressed: () => _openProject(ref),
            ),
            const SizedBox(width: MechXSpacing.xs),
            MechXButton(
              label: 'Save',
              onPressed: () => _saveProject(ref),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: 'Import PDF',
              onPressed: () => _pickAndLoadPdf(ref),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: showSchematic ? 'Plan' : 'Schematic',
              primary: showSchematic,
              onPressed: () =>
                  ref.read(showSchematicProvider.notifier).toggle(),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: brightness == Brightness.dark ? 'Dark' : 'Light',
              onPressed: () =>
                  ref.read(brightnessProvider.notifier).toggle(),
            ),
          ],
        ),
      ),
    );
  }
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
                      sheet?.name ?? 'No sheet',
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
                      'Uncalibrated',
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
                      'SNI 8153:2015 (draft)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: caption.copyWith(color: colors.textMuted),
                    ),
                  ),
                  _dot(colors.textMuted),
                  Flexible(
                    child: Text(
                      'scroll zoom · drag pan · F fit · Ctrl+0 100%',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: caption.copyWith(color: colors.textMuted),
                    ),
                  ),
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

/// Offers to restore a crash-recovery snapshot from a previous session that
/// ended without a clean exit. Restore loads it; Dismiss discards it.
class _RecoveryBanner extends ConsumerWidget {
  const _RecoveryBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(recoveryDocProvider);
    if (doc == null) return const SizedBox.shrink();
    final colors = context.colors;
    final type = context.type;

    Future<void> dismiss() async {
      await clearRecovery();
      ref.read(recoveryDocProvider.notifier).clear();
    }

    return Container(
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
              'Recover unsaved work from your last session?',
              style: type.caption.copyWith(color: colors.textPrimary),
            ),
          ),
          MechXButton(
            label: 'Restore',
            primary: true,
            onPressed: () {
              // Restore the full snapshot (drawing + settings). We deliberately
              // do NOT mark it as the clean baseline: recovered work is still
              // unsaved, so autosave should keep mirroring it after dismiss.
              applyDocument(ref.read, doc);
              dismiss();
            },
          ),
          const SizedBox(width: MechXSpacing.sm),
          MechXButton(label: 'Dismiss', onPressed: dismiss),
        ],
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
    if (message == null) return const SizedBox.shrink();
    final colors = context.colors;
    final type = context.type;
    return Container(
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
              borderRadius: const BorderRadius.all(Radius.circular(4)),
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
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => ref.read(loadErrorProvider.notifier).clear(),
              child: Text('Dismiss',
                  style: type.label.copyWith(color: colors.danger)),
            ),
          ),
        ],
      ),
    );
  }
}
