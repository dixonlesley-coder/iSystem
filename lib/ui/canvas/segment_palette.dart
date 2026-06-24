import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/network_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/palette_card.dart';
import '../widgets/section_label.dart';
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
        const MechXSectionLabel('Palette'),
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
            PaletteCard<PaletteItem>(
              label: 'Pipe segment',
              swatch: serviceColor(activeService),
              data: const PaletteItem(PaletteItemKind.pipeSegment),
            ),
            PaletteCard<PaletteItem>(
              label: 'Duct segment',
              swatch: serviceColor(ServiceType.duct),
              data: const PaletteItem(
                PaletteItemKind.ductSegment,
                service: ServiceType.duct,
              ),
              dotShape: BoxShape.rectangle,
            ),
            PaletteCard<PaletteItem>(
              label: 'Fitting',
              swatch: context.colors.textSecondary,
              data: const PaletteItem(PaletteItemKind.fitting),
            ),
            PaletteCard<PaletteItem>(
              label: 'Terminal',
              swatch: context.colors.textSecondary,
              data: const PaletteItem(PaletteItemKind.terminal),
              dotHollow: true,
            ),
          ],
        ),
      ],
    );
  }
}

