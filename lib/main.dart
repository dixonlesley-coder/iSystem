import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';
import 'store/models/sheet.dart';
import 'ui/canvas/pdf_sheet_page.dart';
import 'ui/canvas/sheet_canvas.dart';

void main() async {
  // pdfrxFlutterInitialize calls WidgetsFlutterBinding.ensureInitialized()
  // internally, so we don't need to call it again here.
  await pdfrxFlutterInitialize();

  runApp(
    ProviderScope(
      overrides: [
        // Override the seam so PDF sheets render their page via pdfrx and
        // placeholder sheets continue to show PlaceholderSheetPage (P0 demo).
        sheetContentBuilderProvider.overrideWithValue(
          (BuildContext context, Sheet sheet) {
            if (sheet.pdfPath != null) {
              return PdfSheetPage(sheet: sheet);
            }
            return PlaceholderSheetPage(sheet: sheet);
          },
        ),
      ],
      child: const MechXApp(),
    ),
  );
}
