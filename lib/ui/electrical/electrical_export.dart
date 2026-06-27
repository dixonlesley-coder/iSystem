/// App-side electrical export actions — gather the live electrical providers,
/// call the PURE engine exporters (`report/electrical_calc_report.dart` +
/// `report/electrical_dxf_export.dart`), and write the result to a user-chosen
/// file. The electrical mirror of the mechanical export fns in
/// `ui/inspector/project_panel.dart`.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/standards/puil.dart';

import '../../store/app_state.dart';
import '../../store/electrical_store.dart';
import '../strings/app_strings.dart';

/// Export the sized electrical single-line as a DXF drawing file.
Future<void> exportElectricalSldDxf(WidgetRef ref) async {
  final project = ref.read(electricalProjectProvider);
  final result = ref.read(electricalResultProvider);
  final dxf = electricalSldToDxf(project: project, result: result);
  await _save(dxf, name: project.name, suffix: 'sld', ext: 'dxf',
      title: MechXStringsData(ref.read(localeProvider))(StringKey.exportTitleSldDxf));
}

/// Export the sized electrical single-line as a native (vector) PDF.
Future<void> exportElectricalSldPdf(WidgetRef ref) async {
  final project = ref.read(electricalProjectProvider);
  final result = ref.read(electricalResultProvider);
  // The single-line is one drawing for the whole project; stamp it as sheet
  // 1 of 1 with a north arrow so it reads as an issuable document. (Drawing
  // number / revision aren't tracked in the model yet — a future wave.)
  final bytes = electricalSldToPdf(
    project: project,
    result: result,
    chrome: const DrawingChrome(sheetIndex: 1, sheetTotal: 1),
  );
  final base = project.name.isEmpty ? 'electrical' : project.name;
  final path = await FilePicker.saveFile(
    dialogTitle: MechXStringsData(ref.read(localeProvider))(StringKey.exportTitleSldPdf),
    fileName: '$base-sld.pdf',
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
  );
  if (path == null) return;
  final full = path.endsWith('.pdf') ? path : '$path.pdf';
  await File(full).writeAsBytes(bytes);
}

/// Export the hybrid power one-line as a DXF drawing file. No-op (returns) when
/// the project carries no energy sources, so there is no one-line to draw.
Future<void> exportPowerOneLineDxf(WidgetRef ref) async {
  final project = ref.read(electricalProjectProvider);
  final advanced = ref.read(electricalAdvancedProvider);
  final oneLine = advanced.powerOneLine;
  if (oneLine == null || oneLine.nodes.isEmpty) return;
  final dxf = powerOneLineToDxf(oneLine);
  await _save(dxf, name: project.name, suffix: 'power-one-line', ext: 'dxf',
      title: MechXStringsData(ref.read(localeProvider))(StringKey.exportTitlePowerOneLineDxf));
}

/// Export the electrical calculation report as Markdown.
Future<void> exportElectricalCalcReport(WidgetRef ref) async {
  final project = ref.read(electricalProjectProvider);
  final result = ref.read(electricalResultProvider);
  final advanced = ref.read(electricalAdvancedProvider);
  const profile = PuilProfile();

  final md = buildElectricalCalcReport(ElectricalCalcReportData(
    projectName: project.name.isEmpty ? 'electrical' : project.name,
    date: DateTime.now().toIso8601String().split('T').first,
    standardsName: profile.name,
    standardsRevision: profile.revision,
    project: project,
    result: result,
    powerOneLine: advanced.powerOneLine,
    verifyItems: advanced.verifyItems,
  ));
  await _save(md, name: project.name, suffix: 'electrical-report', ext: 'md',
      title: MechXStringsData(ref.read(localeProvider))(StringKey.exportTitleElectricalReport));
}

Future<void> _save(
  String content, {
  required String name,
  required String suffix,
  required String ext,
  required String title,
}) async {
  final base = name.isEmpty ? 'electrical' : name;
  final path = await FilePicker.saveFile(
    dialogTitle: title,
    fileName: '$base-$suffix.$ext',
    type: FileType.custom,
    allowedExtensions: [ext],
  );
  if (path == null) return;
  final full = path.endsWith('.$ext') ? path : '$path.$ext';
  await File(full).writeAsString(content);
}
