import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'segment_palette.dart';
import 'viewport.dart';

/// A [DragTarget] spanning the canvas: a [PaletteItem] dropped here is mapped
/// from the local drop offset to sheet/world coordinates (via the live
/// [ViewportTransform]) and routed to the matching add-action on the network
/// store. Pointer-translucent so the canvas keeps panning/zooming when nothing
/// is being dragged. Mounted only while NOT calibrating and NOT drawing.
class DropOverlay extends ConsumerWidget {
  final String sheetId;
  final int floorIndex;

  const DropOverlay({
    super.key,
    required this.sheetId,
    required this.floorIndex,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DragTarget<PaletteItem>(
      hitTestBehavior: HitTestBehavior.translucent,
      onAcceptWithDetails: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(details.offset);
        final transform =
            ref.read(sheetsControllerProvider).viewportFor(sheetId) ??
                const ViewportTransform();
        final world = transform.screenToWorld(local);
        final ctrl = ref.read(networkControllerProvider.notifier);
        final snapWorld = 14 / transform.scale; // ≈14 screen px
        switch (details.data.kind) {
          case PaletteItemKind.pipeSegment:
          case PaletteItemKind.ductSegment:
            ctrl.addSegment(
              sheetId,
              floorIndex,
              world,
              service: details.data.service,
              snapRadius: snapWorld,
            );
          case PaletteItemKind.fitting:
            ctrl.addFitting(sheetId, floorIndex, world);
          case PaletteItemKind.terminal:
            ctrl.addTerminal(sheetId, floorIndex, world);
        }
      },
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        // Translucent fill while a card hovers, so the user sees the canvas is a
        // valid drop zone; fully transparent (and pointer-ignored) otherwise.
        if (!active) return const IgnorePointer(child: SizedBox.expand());
        return DecoratedBox(
          decoration: BoxDecoration(
            color: context.colors.accent.withAlpha(18),
            border: Border.all(
              color: context.colors.accent.withAlpha(120),
              width: 1.5,
            ),
            borderRadius: MechXRadii.card,
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}
