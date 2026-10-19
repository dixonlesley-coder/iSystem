import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models/sheet.dart';
import '../../store/sheets_store.dart';
import 'dxf_sheet_page.dart';

/// The app's DXF sheet content: a [DxfSheetPage] wired to the store so a plan
/// revised IN PLACE (its live extent no longer matches the import frame)
/// records the live extent on the sheet and flags the calibration stale
/// ('Plan replaced - re-verify scale') — once per real change
/// (`SheetsController.reportDxfFrameChanged`), so 'Scale confirmed' survives
/// a canvas remount (Layout <-> Riser) and a reopen.
class HostedDxfSheetPage extends ConsumerWidget {
  final Sheet sheet;
  const HostedDxfSheetPage({super.key, required this.sheet});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DxfSheetPage(
        sheet: sheet,
        onFrameChanged: (id, live) => ref
            .read(sheetsControllerProvider.notifier)
            .reportDxfFrameChanged(id, live),
      );
}
