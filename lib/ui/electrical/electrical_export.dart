/// App-side electrical export actions — gather the live electrical providers,
/// call the PURE engine exporters (`report/electrical_calc_report.dart` +
/// `report/electrical_dxf_export.dart`), and write the result to a user-chosen
/// file. The electrical mirror of the mechanical export fns in
/// `ui/inspector/project_panel.dart`.
///
/// Every export routes through the shared [runExportGuarded] driver (H3): the
/// zero-length completeness gate fires first (drawn work on an uncalibrated
/// sheet — the shared substrate the placed electrical layout also derives its
/// cable lengths from), a cancelled file picker writes nothing and shows no
/// pill, a successful write shows the "Exported ..." confirmation + credits the
/// Report stage, and any IO error surfaces as a dismissible warning instead of
/// an invisible no-op.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';

import '../../store/app_state.dart';
import '../../store/document_control_store.dart';
import '../../store/electrical_store.dart';
import '../inspector/project_panel.dart' show reportStringsFor, runExportGuarded;
import '../../store/project_store.dart';
import '../strings/app_strings.dart';

/// The status-pill message when a power one-line export is requested but the
/// project carries no energy sources (there is no one-line to draw) — an
/// explicit explanation instead of the old silent no-op. Public for tests.
const String kNoEnergySourcesMessage =
    'No energy sources configured - add them under Sources';

/// The document-control (D3 / C3) chrome stamped on every electrical drawing
/// export: the drawing number / revision tag / client / DRAWN-CHECKED-APPROVED
/// identity from [documentControlProvider] (unset fields stay null so their
/// title-block rows are omitted) plus today's date — the app formats the clock,
/// the engine never reads it. Sheet counters default 1 of 1 (the single-sheet
/// drawings); the paginated schedule export re-stamps them per page.
///
/// N19: the drawing NUMBER is DERIVED per drawing type — the per-panel/board
/// detail single-line `E-201`, the building overview `E-301`, the floor-by-floor
/// riser `E-401`, the power one-line `E-501` — via [series], so three different
/// electrical drawings never all read `E-201`. The manual `documentNumber`
/// remains the verbatim override.
DrawingChrome electricalExportChrome(WidgetRef ref,
    {int sheetIndex = 1,
    int sheetTotal = 1,
    DrawingSeries series = DrawingSeries.electricalDetail}) {
  final doc = ref.read(documentControlProvider);
  return DrawingChrome(
    sheetIndex: sheetIndex,
    sheetTotal: sheetTotal,
    drawingNumber: sheetDrawingNumber(base: doc.documentNumber, series: series),
    revisionNumber: doc.revisionTag,
    clientName: doc.clientName,
    drawnBy: doc.preparedBy,
    checkedBy: doc.checkedBy,
    approvedBy: doc.approvedBy,
    dateString: DateTime.now().toIso8601String().split('T').first,
  );
}

/// C5 — the per-panel breaking-capacity map (panel id → Icu, kA) for the SLD
/// device notation, from the live fault study:
/// `AdvancedStudy.fault.panels[id].incomerKa` is the CHOSEN standard
/// breaking-capacity rating at that board (its sibling `prospectiveFaultkA` is
/// the raw fault MAGNITUDE the device must cover — never shown as a rating).
/// Only positive finite ratings are forwarded, so a panel the study could not
/// resolve simply carries no kA in THIS map — but the engine
/// (`buildElectricalSld`) then backstops an unmapped panel with the busbar-
/// withstand prospective fault it already carries (the store always sizes with
/// a 16 kA / 0.1 s default), so every device still prints a kA (N9). This map
/// stays the PREFERRED source (the chosen device Icu rating) when the study
/// resolves it; nothing is fabricated in either path.
Map<String, double> breakerIcuKaByPanel(WidgetRef ref) {
  final fault = ref.read(electricalAdvancedProvider).fault;
  return {
    for (final e in fault.panels.entries)
      if (e.value.incomerKa.isFinite && e.value.incomerKa > 0)
        e.key: e.value.incomerKa,
  };
}

/// Export the sized electrical single-line as a DXF drawing file.
Future<void> exportElectricalSldDxf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical single-line',
      write: () {
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        // Build the sheet HERE (rather than inside the exporter) so the fault
        // study's breaking-capacity ratings reach the device notation (C5).
        final sheet = buildElectricalSld(
          project: project,
          result: result,
          breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
        );
        final dxf = electricalSldToDxf(
          sheet: sheet,
          chrome: electricalExportChrome(ref),
        );
        return _save(dxf,
            name: project.name,
            suffix: 'sld',
            ext: 'dxf',
            title: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleSldDxf));
      },
    );

/// Export the sized electrical single-line as a native (vector) PDF.
Future<void> exportElectricalSldPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical single-line',
      write: () async {
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        // The single-line is one drawing for the whole project; stamp it as
        // sheet 1 of 1 over the document-control title block (D3). The sheet
        // is built HERE so the fault study's breaking-capacity ratings reach
        // the device notation (C5).
        final bytes = electricalSldToPdf(
          project: project,
          sheet: buildElectricalSld(
            project: project,
            result: result,
            breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
          ),
          chrome: electricalExportChrome(ref),
        );
        final base = project.name.isEmpty ? 'electrical' : project.name;
        final path = await FilePicker.saveFile(
          dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldPdf),
          fileName: '$base-sld.pdf',
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (path == null) return false;
        final full = path.endsWith('.pdf') ? path : '$path.pdf';
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// Export the ZOOMED-OUT building single-line (the whole distribution
/// hierarchy, compact panel tree, normal/essential colour split) as a vector PDF.
/// The PLN/MV/transformer/LV-main + genset/capacitor source spine is prepended.
Future<void> exportElectricalOverviewPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'building single-line',
      write: () async {
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        final bytes = electricalSldToPdf(
          project: project,
          result: result,
          overview: true,
          sourceChain: true,
          title: 'iSystem electrical single-line (overview)',
          chrome: electricalExportChrome(ref,
              series: DrawingSeries.electricalOverview),
        );
        final base = project.name.isEmpty ? 'electrical' : project.name;
        final path = await FilePicker.saveFile(
          dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldPdf),
          fileName: '$base-overview-sld.pdf',
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (path == null) return false;
        final full = path.endsWith('.pdf') ? path : '$path.pdf';
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// Export the ZOOMED-OUT building single-line as a DXF drawing file (with the
/// source spine prepended).
Future<void> exportElectricalOverviewDxf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'building single-line',
      write: () {
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        final dxf = electricalSldToDxf(
            project: project,
            result: result,
            overview: true,
            sourceChain: true,
            chrome: electricalExportChrome(ref,
                series: DrawingSeries.electricalOverview));
        return _save(dxf,
            name: project.name,
            suffix: 'overview-sld',
            ext: 'dxf',
            title: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleSldDxf));
      },
    );

/// Export the FLOOR-BY-FLOOR building riser (panels stacked by true elevation,
/// vertical riser feeders, a floor/FFL gutter) as a vector PDF. The riser sheet
/// is built here with the LIVE mechanical [BuildingLevels] (the shared §10
/// geometry) and handed to the role-aware exporter, so the SldSheet stays the
/// single source of geometry.
Future<void> exportElectricalRiserPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical building riser',
      write: () async {
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        final building = ref.read(projectControllerProvider).building;
        final sheet = buildElectricalRiser(
            project: project, result: result, building: building);
        final bytes = electricalSldToPdf(
          sheet: sheet,
          title: 'iSystem electrical building riser',
          chrome:
              electricalExportChrome(ref, series: DrawingSeries.electricalRiser),
        );
        final base = project.name.isEmpty ? 'electrical' : project.name;
        final path = await FilePicker.saveFile(
          dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldPdf),
          fileName: '$base-riser.pdf',
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (path == null) return false;
        final full = path.endsWith('.pdf') ? path : '$path.pdf';
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// Export the FLOOR-BY-FLOOR building riser as a DXF drawing file.
Future<void> exportElectricalRiserDxf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical building riser',
      write: () {
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        final building = ref.read(projectControllerProvider).building;
        final sheet = buildElectricalRiser(
            project: project, result: result, building: building);
        final dxf = electricalSldToDxf(
            sheet: sheet,
            chrome: electricalExportChrome(ref,
                series: DrawingSeries.electricalRiser));
        return _save(dxf,
            name: project.name,
            suffix: 'riser',
            ext: 'dxf',
            title: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleSldDxf));
      },
    );

/// C1 — export the per-panel BOARD SCHEDULES as ONE multi-page vector PDF:
/// one panel per sheet (root-first `result.order`), each page a full board
/// schedule with a real per-page `Sheet i of t` counter (the engine re-stamps
/// the counter; the document-control chrome's other rows stamp every page).
Future<void> exportElectricalPanelSchedulesPdf(WidgetRef ref) =>
    runExportGuarded(
      ref,
      name: 'panel schedules',
      write: () async {
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        final bytes = electricalSldToPdfPaginated(
          project: project,
          result: result,
          title: 'iSystem electrical panel schedules',
          chrome: electricalExportChrome(ref),
          // The C5 device-notation kA (from the fault study) rides the schedule
          // set too, matching the single-sheet detail export.
          breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
        );
        final base = project.name.isEmpty ? 'electrical' : project.name;
        final path = await FilePicker.saveFile(
          dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitlePanelSchedulesPdf),
          fileName: '$base-panel-schedules.pdf',
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (path == null) return false;
        final full = path.endsWith('.pdf') ? path : '$path.pdf';
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// Export the hybrid power one-line as a DXF drawing file. When the project
/// carries no energy sources there is no one-line to draw — the status pill
/// explains why nothing was written (H3: never a silent no-op).
///
/// C7 — routed through the shared [buildPowerOneLineSheet] / [electricalSldToDxf]
/// pipeline (IEC source symbols, orthogonal routing, class layers, title block +
/// legend) rather than the legacy centre-to-centre wireframe grid.
Future<void> exportPowerOneLineDxf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'power one-line',
      write: () {
        final project = ref.read(electricalProjectProvider);
        final advanced = ref.read(electricalAdvancedProvider);
        final oneLine = advanced.powerOneLine;
        if (oneLine == null || oneLine.nodes.isEmpty) {
          ref
              .read(statusMessageProvider.notifier)
              .showStatus(kNoEnergySourcesMessage);
          return Future.value(false);
        }
        final dxf = electricalSldToDxf(
          sheet: buildPowerOneLineSheet(oneLine),
          diagramTitle: 'POWER ONE-LINE DIAGRAM',
          chrome: electricalExportChrome(ref,
              series: DrawingSeries.electricalPowerOneLine),
        );
        return _save(dxf,
            name: project.name,
            suffix: 'power-one-line',
            ext: 'dxf',
            title: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitlePowerOneLineDxf));
      },
    );

/// C7 — export the hybrid power one-line as a native (vector) PDF, via the same
/// shared [buildPowerOneLineSheet] geometry the DXF renders. The no-sources
/// case explains itself via the status pill (H3: never a silent no-op).
Future<void> exportPowerOneLinePdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'power one-line',
      write: () async {
        final project = ref.read(electricalProjectProvider);
        final advanced = ref.read(electricalAdvancedProvider);
        final oneLine = advanced.powerOneLine;
        if (oneLine == null || oneLine.nodes.isEmpty) {
          ref
              .read(statusMessageProvider.notifier)
              .showStatus(kNoEnergySourcesMessage);
          return false;
        }
        final bytes = electricalSldToPdf(
          sheet: buildPowerOneLineSheet(oneLine),
          title: 'iSystem power one-line',
          diagramTitle: 'POWER ONE-LINE DIAGRAM',
          chrome: electricalExportChrome(ref,
              series: DrawingSeries.electricalPowerOneLine),
        );
        final base = project.name.isEmpty ? 'electrical' : project.name;
        final path = await FilePicker.saveFile(
          dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldPdf),
          fileName: '$base-power-one-line.pdf',
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (path == null) return false;
        final full = path.endsWith('.pdf') ? path : '$path.pdf';
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// Export the electrical calculation report as Markdown.
Future<void> exportElectricalCalcReport(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical calc report',
      write: () {
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        final advanced = ref.read(electricalAdvancedProvider);
        const profile = PuilProfile();

        final md = buildElectricalCalcReport(
            ElectricalCalcReportData(
              projectName: project.name.isEmpty ? 'electrical' : project.name,
              date: DateTime.now().toIso8601String().split('T').first,
              standardsName: profile.name,
              standardsRevision: profile.revision,
              project: project,
              result: result,
              powerOneLine: advanced.powerOneLine,
              verifyItems: advanced.verifyItems,
              revisions: ref.read(documentControlProvider).revisions,
            ),
            reportStringsFor(ref));
        return _save(md,
            name: project.name,
            suffix: 'electrical-report',
            ext: 'md',
            title: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleElectricalReport));
      },
    );

/// Pick a destination and write [content]. Returns false when the user
/// cancelled the picker (nothing written — the guard shows no pill), true
/// after a successful write.
Future<bool> _save(
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
  if (path == null) return false;
  final full = path.endsWith('.$ext') ? path : '$path.$ext';
  await File(full).writeAsString(content);
  return true;
}
