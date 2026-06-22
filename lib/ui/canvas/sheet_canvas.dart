import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/calibration_store.dart';
import '../../store/models/sheet.dart';
import '../../store/sheets_store.dart';
import '../theme/mechx_theme.dart';
import 'calibration_overlay.dart';
import 'canvas_view.dart';

/// Builds the content widget for a sheet. This is the seam where pdfrx (PDFium)
/// rendering slots in: a future provider override returns a PDF-page widget for
/// sheets with a `pdfPath`. For P0 every sheet shows a placeholder page so the
/// canvas, navigation, and viewport logic are fully exercised without native
/// dependencies.
typedef SheetContentBuilder = Widget Function(BuildContext context, Sheet sheet);

final sheetContentBuilderProvider = Provider<SheetContentBuilder>(
  (ref) => (context, sheet) => PlaceholderSheetPage(sheet: sheet),
);

/// The current sheet rendered inside the pannable/zoomable [CanvasView], with
/// per-sheet viewport restore wired to the store.
class SheetCanvas extends ConsumerWidget {
  const SheetCanvas({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sheetsControllerProvider);
    final colors = context.colors;
    final sheet = state.current;

    if (sheet == null) {
      return ColoredBox(
        color: colors.canvas,
        child: Center(
          child: Text(
            'No sheet loaded',
            style: context.type.body.copyWith(color: colors.textMuted),
          ),
        ),
      );
    }

    final content = ref.watch(sheetContentBuilderProvider)(context, sheet);
    final calibrating = ref.watch(calibrationControllerProvider).isActive;

    return Stack(
      children: [
        CanvasView(
          // Fresh CanvasView per sheet, seeded from that sheet's stored viewport.
          key: ValueKey(sheet.id),
          contentSize: sheet.sizePx,
          initialTransform: state.viewportFor(sheet.id),
          background: colors.canvas,
          onTransformChanged: (vt) => ref
              .read(sheetsControllerProvider.notifier)
              .setViewport(sheet.id, vt),
          child: content,
        ),
        if (calibrating)
          Positioned.fill(child: CalibrationOverlay(sheetId: sheet.id)),
      ],
    );
  }
}

/// A placeholder "paper" page for a sheet without a PDF (P0). Paper stays light
/// in both themes — like a real drawing — so its ink colour is fixed.
class PlaceholderSheetPage extends StatelessWidget {
  final Sheet sheet;

  const PlaceholderSheetPage({super.key, required this.sheet});

  static const Color _ink = Color(0xFF9AA1AC);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.sheetPaper,
        border: Border.all(color: colors.border),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              sheet.name,
              style: const TextStyle(
                fontSize: 40,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: _ink,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${sheet.sizePx.width.round()} × ${sheet.sizePx.height.round()} px'
              '   ·   PDF import in P1',
              style: const TextStyle(fontSize: 18, color: _ink),
            ),
          ],
        ),
      ),
    );
  }
}
