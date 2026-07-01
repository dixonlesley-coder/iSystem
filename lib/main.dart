import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';
import 'data/autosave.dart';
import 'data/recovery.dart';
import 'store/models/sheet.dart';
import 'ui/canvas/dxf_sheet_page.dart';
import 'ui/canvas/pdf_sheet_page.dart';
import 'ui/canvas/sheet_canvas.dart';

void main() async {
  // pdfrxFlutterInitialize calls WidgetsFlutterBinding.ensureInitialized()
  // internally, so we don't need to call it again here.
  await pdfrxFlutterInitialize();

  final container = ProviderContainer(
    overrides: [
      // Override the seam so PDF sheets render their page via pdfrx and
      // placeholder sheets continue to show PlaceholderSheetPage (P0 demo).
      sheetContentBuilderProvider.overrideWithValue(
        (BuildContext context, Sheet sheet) {
          if (sheet.pdfPath != null) {
            return PdfSheetPage(sheet: sheet);
          }
          if (sheet.dxfPath != null) {
            return DxfSheetPage(sheet: sheet);
          }
          return PlaceholderSheetPage(sheet: sheet);
        },
      ),
    ],
  );

  // Crash recovery: if a snapshot from a previous (unclean) session exists,
  // offer to restore it. Then start the periodic autosave loop.
  final recovered = await readRecovery();
  if (recovered != null) {
    container.read(recoveryDocProvider.notifier).set(recovered);
  }
  startAutosave(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const MechXApp(),
    ),
  );
}
