/// The OFFSET dialog — the simpler-than-AutoCAD parallel-run action. Pick a real
/// distance (mm) and a side, and the run is duplicated parallel at that offset in
/// one undo step (see [NetworkController.offsetEdgeParallel]). No Material: a
/// [showGeneralDialog] card themed with [MechXTheme].
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';

/// Open the offset dialog for run [edgeId]. No-op if the edge is gone, is a
/// riser, or sits on an uncalibrated sheet (offset needs a real scale).
Future<void> showOffsetDialog(
  BuildContext context,
  WidgetRef ref,
  String edgeId,
) {
  final net = ref.read(networkControllerProvider).network;
  final edge = net.edgeById(edgeId);
  if (edge == null || edge.kind != EdgeKind.run) return Future.value();
  final sheetId = net.nodeById(edge.fromId)?.sheetId;
  if (sheetId == null) return Future.value();
  final cal = ref.read(projectControllerProvider).calibrationFor(sheetId);
  if (cal == null) return Future.value();

  final theme = MechXTheme.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Offset run',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: Center(child: _OffsetDialog(edgeId: edgeId)),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: MechXMotion.standard);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _OffsetDialog extends ConsumerStatefulWidget {
  final String edgeId;
  const _OffsetDialog({required this.edgeId});

  @override
  ConsumerState<_OffsetDialog> createState() => _OffsetDialogState();
}

class _OffsetDialogState extends ConsumerState<_OffsetDialog> {
  String _text = '500';
  bool _leftSide = true;
  String? _error;

  void _create() {
    final mm = double.tryParse(_text.trim());
    if (mm == null || mm <= 0) {
      setState(() => _error = 'Enter a distance in mm, e.g. 500');
      return;
    }
    final net = ref.read(networkControllerProvider).network;
    final edge = net.edgeById(widget.edgeId);
    final sheetId =
        edge == null ? null : net.nodeById(edge.fromId)?.sheetId;
    final cal = sheetId == null
        ? null
        : ref.read(projectControllerProvider).calibrationFor(sheetId);
    if (cal == null) {
      Navigator.of(context).pop();
      return;
    }
    final px = cal.pixelsForLength(Length.mm(mm));
    ref
        .read(networkControllerProvider.notifier)
        .offsetEdgeParallel(widget.edgeId, px, leftSide: _leftSide);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    return Container(
      width: 360,
      padding: const EdgeInsets.all(MechXSpacing.lg),
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
          Text('Offset run',
              style: type.title.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.xs),
          Text(
            'Create a parallel run at a set distance and side — one step, '
            'auto-cleaned, undo as a single action.',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.md),
          Text('Distance (mm)',
              style: type.caption.copyWith(color: colors.textSecondary)),
          const SizedBox(height: MechXSpacing.xs),
          MechXTextField(
            value: _text,
            hint: '500',
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) => setState(() {
              _text = v;
              _error = null;
            }),
            // Enter creates the offset without a mouse trip to the button (I3).
            onSubmitted: _create,
          ),
          if (_error != null) ...[
            const SizedBox(height: MechXSpacing.xs),
            Text(_error!, style: type.caption.copyWith(color: colors.danger)),
          ],
          const SizedBox(height: MechXSpacing.md),
          Text('Side',
              style: type.caption.copyWith(color: colors.textSecondary)),
          const SizedBox(height: MechXSpacing.xs),
          Row(
            children: [
              Expanded(
                child: _SideButton(
                  label: 'Left',
                  selected: _leftSide,
                  onTap: () => setState(() => _leftSide = true),
                ),
              ),
              const SizedBox(width: MechXSpacing.xs),
              Expanded(
                child: _SideButton(
                  label: 'Right',
                  selected: !_leftSide,
                  onTap: () => setState(() => _leftSide = false),
                ),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              MechXButton(
                label: 'Cancel',
                tertiary: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: MechXSpacing.xs),
              MechXButton(
                label: 'Create offset',
                primary: true,
                onPressed: _create,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SideButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SideButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: MechXSpacing.sm),
        decoration: BoxDecoration(
          color: selected ? colors.accentMuted : colors.background,
          borderRadius: MechXRadii.control,
          border: Border.all(
            color: selected ? colors.accent : colors.border,
          ),
        ),
        child: Text(
          label,
          style: type.body.copyWith(
            color: selected ? colors.accent : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}
