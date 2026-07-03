/// A custom (no-Material) modal that lets the user pick WHICH pages of a
/// just-opened PDF to import. Shown by the Import-PDF flow when the document has
/// more than one page; the chosen subset becomes the project's sheets.
///
/// A [showGeneralDialog]-driven floating card themed with [MechXTheme], so it
/// matches the fixture-library editor and renders in goldens. Returns the
/// selected sheets (in page order), or null if the user cancels.
library;

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../store/models/sheet.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_focus_ring.dart';

/// A small offscreen pdfrx-rendered THUMBNAIL of a PDF-backed [sheet]'s page —
/// shown in the page picker rows and the sheet rail so the engineer recognises a
/// plan VISUALLY instead of by "Page 17 · 1191 x 842" (A8). Rendering is async
/// and OFF the UI thread (pdfrx/pdfium worker) at whatever small box the parent
/// gives it; while it loads — and for any DXF/placeholder sheet, a missing file
/// or a render failure — it shows [placeholder], and it NEVER throws. The page is
/// fitted (aspect-preserved) inside the box.
///
/// Reused by both owned surfaces (the picker here + `sheet_rail.dart`), so the
/// thumbnail logic lives in exactly one place. A DXF-backed or placeholder sheet
/// has no pdfrx page to raster, so it returns [placeholder] synchronously — which
/// keeps the sheet rail's numbered-tile look (and the golden screenshots, whose
/// demo sheets are all placeholders) byte-identical.
class SheetThumbnail extends StatelessWidget {
  final Sheet sheet;
  final Widget placeholder;
  const SheetThumbnail({
    super.key,
    required this.sheet,
    required this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    final path = sheet.pdfPath;
    if (path == null) return placeholder; // DXF / placeholder — no page to draw
    return PdfDocumentViewBuilder.file(
      path,
      errorBuilder: (context, error, _) => placeholder,
      builder: (context, document) {
        if (document == null) return placeholder; // still opening
        final pageNumber = sheet.pageIndex + 1; // pdfrx is 1-based
        if (pageNumber < 1 || pageNumber > document.pages.length) {
          return placeholder;
        }
        return PdfPageView(
          document: document,
          pageNumber: pageNumber,
          decoration: const BoxDecoration(color: Color(0xFFFFFFFF)),
        );
      },
    );
  }
}

/// A framed thumbnail slot for a picker row — a hairline-bordered, clipped box
/// holding the sheet's [SheetThumbnail], falling back to a neutral page tile.
class _PickerThumbnail extends StatelessWidget {
  final Sheet sheet;
  const _PickerThumbnail({required this.sheet});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 52,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        border: Border.all(color: colors.border),
      ),
      child: SheetThumbnail(
        sheet: sheet,
        placeholder: const SizedBox.shrink(),
      ),
    );
  }
}

/// Open the page picker over [allSheets] (one per PDF page). Resolves to the
/// chosen subset, or null when cancelled.
Future<List<Sheet>?> showPdfPagePicker(
  BuildContext context,
  List<Sheet> allSheets,
) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<List<Sheet>>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Choose pages',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: Center(child: _PagePickerDialog(allSheets: allSheets)),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: MechXMotion.standard,
        reverseCurve: MechXMotion.standard,
      );
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

/// Open a single-select picker over [sheets] (e.g. to assign a PDF page to a
/// building floor). Resolves to the chosen sheet's id, or null when cancelled.
Future<String?> showSheetPicker(BuildContext context, List<Sheet> sheets) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Choose a floor plan',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: Center(child: _SheetPickerDialog(sheets: sheets)),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: MechXMotion.standard,
        reverseCurve: MechXMotion.standard,
      );
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

class _SheetPickerDialog extends StatelessWidget {
  final List<Sheet> sheets;
  const _SheetPickerDialog({required this.sheets});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      width: 440,
      constraints: const BoxConstraints(maxHeight: 640),
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
          Row(
            children: [
              Expanded(
                child: Text('Assign a floor plan',
                    style: type.title.copyWith(color: colors.textPrimary)),
              ),
              MechXButton(
                label: 'Cancel',
                tertiary: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.xs),
          Text('Pick the PDF page that shows this floor.',
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(height: MechXSpacing.sm),
          Flexible(
            child: Container(
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: MechXRadii.control,
                border: Border.all(color: colors.border),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.all(MechXSpacing.xxs),
                itemCount: sheets.length,
                itemBuilder: (ctx, i) {
                  final s = sheets[i];
                  return _SheetRow(
                    sheet: s,
                    onTap: () => Navigator.of(context).pop(s.id),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tappable sheet row (name + its point size).
class _SheetRow extends StatefulWidget {
  final Sheet sheet;
  final VoidCallback onTap;
  const _SheetRow({required this.sheet, required this.onTap});

  @override
  State<_SheetRow> createState() => _SheetRowState();
}

class _SheetRowState extends State<_SheetRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final s = widget.sheet;
    return MechXFocusRing(
      borderRadius: MechXRadii.control,
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs),
            margin: const EdgeInsets.all(MechXSpacing.xxs),
            decoration: BoxDecoration(
              color: _hover ? colors.surfaceHover : const Color(0x00000000),
              borderRadius: MechXRadii.control,
            ),
            child: Row(
              children: [
                _PickerThumbnail(sheet: s),
                const SizedBox(width: MechXSpacing.sm),
                Expanded(
                  child: Text(s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.body.copyWith(color: colors.textPrimary)),
                ),
                Text('${s.sizePx.width.round()} x ${s.sizePx.height.round()}',
                    style: type.caption.copyWith(color: colors.textMuted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PagePickerDialog extends StatefulWidget {
  final List<Sheet> allSheets;
  const _PagePickerDialog({required this.allSheets});

  @override
  State<_PagePickerDialog> createState() => _PagePickerDialogState();
}

class _PagePickerDialogState extends State<_PagePickerDialog> {
  // Selection by page index; defaults to ALL pages selected (the prior
  // import-everything behaviour, now opt-out).
  late final Set<int> _selected = {
    for (final s in widget.allSheets) s.pageIndex,
  };

  void _toggle(int pageIndex) => setState(() {
        if (!_selected.remove(pageIndex)) _selected.add(pageIndex);
      });

  void _all() => setState(
      () => _selected.addAll(widget.allSheets.map((s) => s.pageIndex)));
  void _none() => setState(_selected.clear);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final count = _selected.length;

    return Container(
      width: 440,
      constraints: const BoxConstraints(maxHeight: 640),
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
          Row(
            children: [
              Expanded(
                child: Text('Choose pages to import',
                    style: type.title.copyWith(color: colors.textPrimary)),
              ),
              MechXButton(
                label: 'Cancel',
                tertiary: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.xs),
          Text(
            'This PDF has ${widget.allSheets.length} pages. Pick the floor plans '
            'to bring in — you can map each to a building level afterwards.',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.sm),
          Row(
            children: [
              MechXButton(label: 'Select all', tertiary: true, onPressed: _all),
              const SizedBox(width: MechXSpacing.xs),
              MechXButton(label: 'Clear', tertiary: true, onPressed: _none),
            ],
          ),
          const SizedBox(height: MechXSpacing.xs),
          Flexible(
            child: Container(
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: MechXRadii.control,
                border: Border.all(color: colors.border),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.all(MechXSpacing.xxs),
                itemCount: widget.allSheets.length,
                itemBuilder: (ctx, i) {
                  final s = widget.allSheets[i];
                  return _PageRow(
                    sheet: s,
                    selected: _selected.contains(s.pageIndex),
                    onTap: () => _toggle(s.pageIndex),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: MechXSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  count == 0
                      ? 'No pages selected'
                      : '$count of ${widget.allSheets.length} selected',
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
              ),
              MechXButton(
                label: count <= 1 ? 'Import page' : 'Import $count pages',
                primary: true,
                onPressed: count == 0
                    ? null
                    : () {
                        final chosen = [
                          for (final s in widget.allSheets)
                            if (_selected.contains(s.pageIndex)) s,
                        ];
                        Navigator.of(context).pop(chosen);
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One selectable page row: a checkbox box + page label + its point size.
class _PageRow extends StatefulWidget {
  final Sheet sheet;
  final bool selected;
  final VoidCallback onTap;
  const _PageRow(
      {required this.sheet, required this.selected, required this.onTap});

  @override
  State<_PageRow> createState() => _PageRowState();
}

class _PageRowState extends State<_PageRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final s = widget.sheet;
    return MechXFocusRing(
      borderRadius: MechXRadii.control,
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs),
            margin: const EdgeInsets.all(MechXSpacing.xxs),
            decoration: BoxDecoration(
              color: widget.selected
                  ? colors.accentMuted
                  : (_hover ? colors.surfaceHover : const Color(0x00000000)),
              borderRadius: MechXRadii.control,
            ),
            child: Row(
              children: [
                // A small check box — filled+tick when selected.
                Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.selected
                        ? colors.accent
                        : const Color(0x00000000),
                    borderRadius: const BorderRadius.all(MechXRadii.xs),
                    border: Border.all(
                      color: widget.selected ? colors.accent : colors.border,
                      width: 1.5,
                    ),
                  ),
                  child: CustomPaint(
                    size: const Size(11, 11),
                    painter: widget.selected
                        ? _CheckPainter(colors.onAccent)
                        : null,
                  ),
                ),
                const SizedBox(width: MechXSpacing.sm),
                _PickerThumbnail(sheet: s),
                const SizedBox(width: MechXSpacing.sm),
                Expanded(
                  child: Text('Page ${s.pageIndex + 1}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.body.copyWith(color: colors.textPrimary)),
                ),
                Text('${s.sizePx.width.round()} x ${s.sizePx.height.round()}',
                    style: type.caption.copyWith(color: colors.textMuted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small tick mark for a checked box.
class _CheckPainter extends CustomPainter {
  final Color color;
  _CheckPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.18, h * 0.52)
      ..lineTo(w * 0.42, h * 0.78)
      ..lineTo(w * 0.84, h * 0.22);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.color != color;
}
