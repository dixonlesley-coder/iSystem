import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models/sheet.dart';
import '../shell/project_io.dart' show replaceSheetPlan;
import 'pdf_sheet_page.dart';

/// The app's PDF sheet content: a [PdfSheetPage] wired to the store so a plan
/// whose file cannot be opened offers the sheet rail's 'Replace plan…' flow
/// (`replaceSheetPlan`) straight from the load-error page — the PDF sibling of
/// `HostedDxfSheetPage`.
class HostedPdfSheetPage extends ConsumerWidget {
  final Sheet sheet;
  const HostedPdfSheetPage({super.key, required this.sheet});

  @override
  Widget build(BuildContext context, WidgetRef ref) => PdfSheetPage(
        sheet: sheet,
        onReplacePlan: () => replaceSheetPlan(context, ref, sheet.id),
      );
}
