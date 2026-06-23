import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/network_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'service_style.dart';

/// What a palette card drops onto the canvas. The drop overlay reads [kind] to
/// pick the matching store add-action; [service] (a pipe segment) carries the
/// service so a duct vs water segment lands correctly.
enum PaletteItemKind { pipeSegment, ductSegment, fitting, terminal }

@immutable
class PaletteItem {
  final PaletteItemKind kind;

  /// For [PaletteItemKind.pipeSegment]/[PaletteItemKind.ductSegment] — the
  /// service the dropped segment carries. Null ⇒ use the active draw service.
  final ServiceType? service;

  const PaletteItem(this.kind, {this.service});
}

/// A compact drag-and-drop palette: drag a card onto the canvas to drop the
/// matching element (a pipe / duct segment, a fitting, or a terminal). Mirrors
/// the PanelMaker electrical palette so the two canvases share one interaction
/// language. Styled with MechXTheme (no Material).
class SegmentPalette extends ConsumerWidget {
  const SegmentPalette({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeService = ref.watch(networkControllerProvider).service;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('Palette'),
        const SizedBox(height: MechXSpacing.xs),
        Text(
          'Drag onto the canvas to drop. Segments use the active service.',
          style: context.type.caption.copyWith(color: context.colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            _PaletteCard(
              label: 'Pipe segment',
              swatch: serviceColor(activeService),
              item: const PaletteItem(PaletteItemKind.pipeSegment),
            ),
            _PaletteCard(
              label: 'Duct segment',
              swatch: serviceColor(ServiceType.duct),
              item: const PaletteItem(
                PaletteItemKind.ductSegment,
                service: ServiceType.duct,
              ),
              dotShape: BoxShape.rectangle,
            ),
            _PaletteCard(
              label: 'Fitting',
              swatch: context.colors.textSecondary,
              item: const PaletteItem(PaletteItemKind.fitting),
            ),
            _PaletteCard(
              label: 'Terminal',
              swatch: context.colors.textSecondary,
              item: const PaletteItem(PaletteItemKind.terminal),
              dotHollow: true,
            ),
          ],
        ),
      ],
    );
  }
}

/// A draggable palette chip. Uses [Draggable] (in widgets.dart) with a small
/// feedback chip; the drag payload is the [PaletteItem] the drop overlay reads.
class _PaletteCard extends StatelessWidget {
  final String label;
  final Color swatch;
  final PaletteItem item;
  final BoxShape dotShape;
  final bool dotHollow;

  const _PaletteCard({
    required this.label,
    required this.swatch,
    required this.item,
    this.dotShape = BoxShape.circle,
    this.dotHollow = false,
  });

  @override
  Widget build(BuildContext context) {
    final chip = _chip(context, dragging: false);
    return Draggable<PaletteItem>(
      data: item,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _chip(context, dragging: true),
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: chip,
      ),
    );
  }

  Widget _chip(BuildContext context, {required bool dragging}) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: dragging ? colors.surfaceHover : colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: dragging ? colors.accent : colors.border),
        boxShadow: dragging
            ? const [
                BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 10,
                    offset: Offset(0, 3)),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: dotHollow ? const Color(0x00000000) : swatch,
              shape: dotShape,
              borderRadius: dotShape == BoxShape.rectangle
                  ? const BorderRadius.all(Radius.circular(2))
                  : null,
              border: dotHollow ? Border.all(color: swatch, width: 1.5) : null,
            ),
          ),
          const SizedBox(width: MechXSpacing.xs),
          Text(
            label,
            style: type.label.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Local copy of the inspector's section label (kept private to the canvas
/// palette so it has no cross-file dependency).
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: context.type.caption.copyWith(
          color: context.colors.textMuted,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      );
}
