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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/advanced_study.dart'
    show containmentByCircuitIdOf;
import 'package:mechx_engine/electrical/bom.dart' show faultSpecifiedKa;
import 'package:mechx_engine/electrical/containment.dart' show ConduitSpec;
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';

import '../../data/plan_underlay.dart';
import '../../store/app_state.dart';
import '../../store/document_control_store.dart';
import '../../store/electrical_store.dart';
import '../inspector/project_panel.dart'
    show pickExportSave, reportStringsFor, runExportGuarded;
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../shell/issued_sld_drawings.dart';
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
/// electrical drawings never all read `E-201`. A manual `documentNumber`
/// becomes the PREFIX (`<documentNumber>-<series><index>`, e.g.
/// `BRI-MEP-01-E-201`); only the cover keeps the bare base.
DrawingChrome electricalExportChrome(WidgetRef ref,
    {int sheetIndex = 1,
    int sheetTotal = 1,
    int index = 1,
    DrawingSeries series = DrawingSeries.electricalDetail}) {
  final doc = ref.read(documentControlProvider);
  return DrawingChrome(
    sheetIndex: sheetIndex,
    sheetTotal: sheetTotal,
    drawingNumber: sheetDrawingNumber(
        base: doc.documentNumber, series: series, index: index),
    revisionNumber: doc.revisionTag,
    clientName: doc.clientName,
    drawnBy: doc.preparedBy,
    checkedBy: doc.checkedBy,
    approvedBy: doc.approvedBy,
    dateString: DateTime.now().toIso8601String().split('T').first,
  );
}

/// Round 34 (electrical-drawings-4-standalone-layout-dwg-number) — the rail
/// sheets that carry an ELECTRICAL LAYOUT plan (placed panels / loads), in
/// rail order: the ONE list the submittal numbers its E-1xx layout sheets by
/// and the standalone layout export positions its sheet in.
List<String> electricalLayoutSheetIds(WidgetRef ref) {
  final sheets = ref.read(sheetsControllerProvider);
  final mech = ref.read(projectControllerProvider);
  final project = ref.read(electricalProjectProvider);
  final result = ref.read(electricalResultProvider);
  return [
    for (final s in sheets.sheets)
      if (!buildElectricalPlanData(
        project: project,
        result: result,
        sheetId: s.id,
        floorIndex: sheets.floorFor(s.id, mech.building.levelCount),
        calibrations: mech.calibrations,
        building: mech.building,
      ).isEmpty)
        s.id,
  ];
}

/// Round 46 (drawings-7-layout-unplaced-count-projectwide) — whether the
/// layout of [sheetId] lists the boards placed NOWHERE (no placed board up
/// their feeder chain): the first layout sheet does (or any sheet when no
/// sheet has electrical content yet), every other sheet's note is scoped to
/// its own boards.
bool electricalLayoutListsUnhomed(WidgetRef ref, String sheetId) {
  final ids = electricalLayoutSheetIds(ref);
  return ids.isEmpty || ids.first == sheetId;
}

/// Round 34 — the layout export chrome of [sheetId]: numbered `E-10k` /
/// `Sheet k of n` by its position among [electricalLayoutSheetIds] (the
/// submittal's numbering, so a standalone sheet matches the Daftar Gambar).
/// A sheet with no electrical content yet takes its rail position within
/// that list (n + 1 total), never a flat E-101 / 1 of 1.
DrawingChrome electricalLayoutChrome(WidgetRef ref, String sheetId) {
  final ids = electricalLayoutSheetIds(ref);
  final list = ids.contains(sheetId)
      ? ids
      : () {
          final rail = [
            for (final s in ref.read(sheetsControllerProvider).sheets) s.id,
          ];
          return [
            for (final id in rail)
              if (ids.contains(id) || id == sheetId) id,
          ];
        }();
  final k = list.indexOf(sheetId) + 1;
  return electricalExportChrome(ref,
      series: DrawingSeries.electricalLayout,
      index: k < 1 ? 1 : k,
      sheetIndex: k < 1 ? 1 : k,
      sheetTotal: list.isEmpty ? 1 : list.length);
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

/// Round 14 (drafting-visual-1) — the title-block PROJECT row every electrical
/// drawing stamps: the LIVE project name (the same one the mechanical sheets,
/// the cover and the Daftar Gambar carry), falling back to the electrical
/// model's own name only when the project is unnamed. A prebuilt-sheet export
/// (overview / riser) used to print 'Untitled project' beside a named set.
String? electricalSheetProjectName(WidgetRef ref) {
  final mech = ref.read(projectControllerProvider).name.trim();
  if (mech.isNotEmpty) return mech;
  final elec = ref.read(electricalProjectProvider).name.trim();
  return elec.isEmpty ? null : elec;
}

/// Round 14 (elec-building-sim-3) — the per-DEVICE breaking-capacity map
/// (circuit id -> kA) the fault study CHOSE for each way
/// (`AdvancedStudy.fault.circuits[id].breakerKa`). Threaded beside
/// [breakerIcuKaByPanel] into every board schedule (exports, the live canvas,
/// the report figures) so an MCB way prints the MCB rating the study picked
/// (`MCB 25A 3ph 10kA`) — without it every way fell back to its panel's
/// INCOMER frame rating (`16kA` on an MCB, a rating no MCB is built to). Only
/// positive finite ratings are forwarded.
/// Round 34 — the containment study's conduit per circuit (the ONE
/// containment source): every schedule export + the live canvas pass it, so
/// the app's `PVC <n>mm` token equals the study's, never the CSA ladder.
Map<String, ConduitSpec> containmentByCircuit(WidgetRef ref) =>
    containmentByCircuitIdOf(ref.read(electricalAdvancedProvider));

Map<String, double> breakerKaByCircuit(WidgetRef ref) {
  final fault = ref.read(electricalAdvancedProvider).fault;
  return {
    for (final e in fault.circuits.entries)
      if (e.value.breakerKa.isFinite && e.value.breakerKa > 0)
        e.key: e.value.breakerKa,
  };
}

/// Round 43 — the fault study's ways that FAIL automatic disconnection, so
/// every issued board schedule marks them ` Zs!` (the same study the kA maps
/// read). Round 56 — on ANY supply: the ways failing ADS only on the standby
/// genset ([AdvancedStudy.gensetAdsFailedCircuitIds]) are marked too.
Set<String> adsFailedCircuitIds(WidgetRef ref) =>
    ref.read(electricalAdvancedProvider).adsFailedCircuitIds;

/// Export the sized electrical single-line as a DXF drawing file.
Future<void> exportElectricalSldDxf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical single-line',
      // Drawing backlog I-1 — the PDF's pages, one DXF frame each.
      write: () => _saveDrawingDxf(ref, issuedElectricalSld(ref),
          suffix: 'sld',
          title: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldDxf)),
    );

/// Export the sized electrical single-line as a native (vector) PDF.
Future<void> exportElectricalSldPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical single-line',
      // Drawing backlog I-1 — the package's own E-201 page list (one board /
      // way range per page when one sheet would print below the label floor).
      write: () => _saveDrawingPdf(ref, issuedElectricalSld(ref),
          suffix: 'sld',
          title: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldPdf)),
    );

/// Export the ZOOMED-OUT building single-line (the whole distribution
/// hierarchy, compact panel tree, normal/essential colour split) as a vector PDF.
/// The PLN/MV/transformer/LV-main + genset/capacitor source spine is prepended.
Future<void> exportElectricalOverviewPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'building single-line',
      write: () => _saveDrawingPdf(ref, issuedElectricalOverview(ref),
          suffix: 'overview-sld',
          title: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldPdf)),
    );

/// Export the ZOOMED-OUT building single-line as a DXF drawing file (with the
/// source spine prepended).
Future<void> exportElectricalOverviewDxf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'building single-line',
      // Drawing backlog I-1 — the PDF's sub-tree pages, one frame each.
      write: () => _saveDrawingDxf(ref, issuedElectricalOverview(ref),
          suffix: 'overview-sld',
          title: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldDxf)),
    );

/// Export the FLOOR-BY-FLOOR building riser (panels stacked by true elevation,
/// vertical riser feeders, a floor/FFL gutter) as a vector PDF. The riser sheet
/// is built here with the LIVE mechanical [BuildingLevels] (the shared §10
/// geometry) and handed to the role-aware exporter, so the SldSheet stays the
/// single source of geometry.
Future<void> exportElectricalRiserPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical building riser',
      write: () => _saveDrawingPdf(ref, issuedElectricalRiser(ref),
          suffix: 'riser',
          title: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldPdf)),
    );

/// Export the FLOOR-BY-FLOOR building riser as a DXF drawing file.
Future<void> exportElectricalRiserDxf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical building riser',
      // Drawing backlog I-1 — the PDF's floor-range pages (LANJUT KE marks).
      write: () => _saveDrawingDxf(ref, issuedElectricalRiser(ref),
          suffix: 'riser',
          title: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldDxf)),
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
        // Drawing backlog I-1 — the package's own E-601 builder.
        final bytes = issuedPanelSchedulesPdf(ref);
        final base = project.name.isEmpty ? 'electrical' : project.name;
        final full = await pickExportSave(ref,
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitlePanelSchedulesPdf),
            fileName: '$base-panel-schedules.pdf',
            ext: 'pdf');
        if (full == null) return false;
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
        final drawing = issuedPowerOneLine(ref);
        if (drawing == null) {
          ref
              .read(statusMessageProvider.notifier)
              .showStatus(kNoEnergySourcesMessage);
          return Future.value(false);
        }
        return _saveDrawingDxf(ref, drawing,
            suffix: 'power-one-line',
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
      write: () {
        final drawing = issuedPowerOneLine(ref);
        if (drawing == null) {
          ref
              .read(statusMessageProvider.notifier)
              .showStatus(kNoEnergySourcesMessage);
          return Future.value(false);
        }
        return _saveDrawingPdf(ref, drawing,
            suffix: 'power-one-line',
            title: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleSldPdf));
      },
    );

/// H1 — export the PLAN-ACCURATE electrical layout (denah instalasi listrik) for
/// the CURRENT sheet/floor as a vector PDF: panels + loads drawn at their real
/// placed sheet-pixel positions over the floor-plan underlay, feeder/drop routes
/// with §10 cable lengths, and a corner "Unplaced" note for anything not placed
/// on this sheet. The electrical analogue of the mechanical `exportDrawingPdf`.
Future<void> exportElectricalPlanPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical layout plan',
      write: () async {
        final sheets = ref.read(sheetsControllerProvider);
        final sheet = sheets.current;
        // H3 tri-state: no plan sheet at all is NOTHING TO WRITE (a visible
        // "Nothing to export - import a plan first" message), not a silent
        // cancel — the electrical layout is drawn ON a plan sheet.
        if (sheet == null) return null;
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        final mech = ref.read(projectControllerProvider);
        final floorIndex = sheets.floorFor(sheet.id, mech.building.levelCount);
        final data = buildElectricalPlanData(
          project: project,
          result: result,
          sheetId: sheet.id,
          floorIndex: floorIndex,
          calibrations: mech.calibrations,
          building: mech.building,
          listUnhomedUnplaced: electricalLayoutListsUnhomed(ref, sheet.id),
        );
        // Round 23 (elec-drafting-2-7) — the register title + the live
        // project name, exactly as the submittal package stamps this sheet.
        final bytes = electricalPlanToPdf(
          data: data,
          projectName: electricalSheetProjectName(ref) ?? 'electrical',
          sheetName: sheet.name,
          dateString: DateTime.now().toIso8601String().split('T').first,
          chrome: electricalLayoutChrome(ref, sheet.id).withTitle(
              drawingSeriesTitle(DrawingSeries.electricalLayout,
                  sheetName: sheet.name)),
          metersPerPixel: mech.calibrationFor(sheet.id)?.metersPerPixel,
          underlay: await buildPlanUnderlay(sheet),
        );
        final base = project.name.isEmpty ? 'electrical' : project.name;
        final full = await pickExportSave(ref,
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleElectricalPlanPdf),
            fileName: '$base-${sheet.name}-layout.pdf',
            ext: 'pdf');
        if (full == null) return false;
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// H1 — export the plan-accurate electrical layout for the current sheet/floor
/// as a DXF drawing (E-* class layers). The DXF is vector-only; the floor-plan
/// underlay rides the PDF variant (matching the mechanical exporters).
Future<void> exportElectricalPlanDxf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'electrical layout plan',
      write: () async {
        final sheets = ref.read(sheetsControllerProvider);
        final sheet = sheets.current;
        // H3 tri-state: no plan sheet at all is NOTHING TO WRITE (a visible
        // "Nothing to export - import a plan first" message), not a silent
        // cancel — the electrical layout is drawn ON a plan sheet.
        if (sheet == null) return null;
        final project = ref.read(electricalProjectProvider);
        final result = ref.read(electricalResultProvider);
        final mech = ref.read(projectControllerProvider);
        final floorIndex = sheets.floorFor(sheet.id, mech.building.levelCount);
        final data = buildElectricalPlanData(
          project: project,
          result: result,
          sheetId: sheet.id,
          floorIndex: floorIndex,
          calibrations: mech.calibrations,
          building: mech.building,
          listUnhomedUnplaced: electricalLayoutListsUnhomed(ref, sheet.id),
        );
        final projectName = electricalSheetProjectName(ref) ?? 'electrical';
        final chrome = electricalLayoutChrome(ref, sheet.id).withTitle(
            drawingSeriesTitle(DrawingSeries.electricalLayout,
                sheetName: sheet.name));
        final metersPerPixel = mech.calibrationFor(sheet.id)?.metersPerPixel;
        final dxf = electricalPlanToDxf(
          data: data,
          projectName: projectName,
          sheetName: sheet.name,
          chrome: chrome,
          // Round 23 (elec-drafting-2-3) — world millimetres + the snapped
          // 1 : N of the PDF twin (its own fit: underlay frame + the real
          // title block), so the DXF and PDF stamp one scale.
          metersPerPixel: metersPerPixel,
          plottedScaleDenominator: metersPerPixel == null
              ? null
              : electricalPlanPlottedScaleDenominator(
                  data: data,
                  projectName: projectName,
                  sheetName: sheet.name,
                  dateString:
                      DateTime.now().toIso8601String().split('T').first,
                  chrome: chrome,
                  metersPerPixel: metersPerPixel,
                  underlay: await buildPlanUnderlay(sheet),
                ),
        );
        return _save(ref, dxf,
            name: project.name,
            suffix: '${sheet.name}-layout',
            ext: 'dxf',
            title: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleElectricalPlanDxf));
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
              standardsProvenance: profile.provenanceNote,
              project: project,
              result: result,
              powerOneLine: advanced.powerOneLine,
              // Round 12 — the PUIL KHA / derating / Vd debt beside the
              // advanced-study items, and the EFFECTIVE fault basis the
              // busbars were sized on (same chain as the live solve).
              // Round 30 (report-parity-2-3) — with its verification tier.
              verifyItems: advanced.verifyItems,
              verifyChecklist: profile.verifyChecklist,
              originFaultLevelA: effectiveOriginFaultLevel(project, result: result)
                  .amperes,
              faultLevelBasis: effectiveOriginFaultLevel(project, result: result)
                  .basis,
              busbarClearingTimeS: effectiveBusbarClearingTimeS(project),
              revisions: ref.read(documentControlProvider).revisions,
              // R1 — the issued report prints the SAME combined warning
              // surface Review + compliance show (core sizing warnings PLUS
              // the fault study's selectivity / breaking-capacity / withstand /
              // TT findings), so an error-severity finding can no longer be on
              // screen but missing from the panel builder's document.
              allWarnings: ref.read(electricalAllWarningsProvider),
              // Round 39 (elec-reports-parity-5) — each device's specified kA.
              incomerKaByPanelId: faultSpecifiedKa(advanced.fault).incomers,
              breakerKaByCircuitId: faultSpecifiedKa(advanced.fault).breakers,
            ),
            reportStringsFor(ref));
        return _save(ref, md,
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
///
/// I1 — the destination comes from the shared [pickExportSave] seam, so these
/// text/DXF exports remember the last export folder exactly like the PDF ones.
Future<bool> _save(
  WidgetRef ref,
  String content, {
  required String name,
  required String suffix,
  required String ext,
  required String title,
}) async {
  final base = name.isEmpty ? 'electrical' : name;
  final full = await pickExportSave(ref,
      dialogTitle: title, fileName: '$base-$suffix.$ext', ext: ext);
  if (full == null) return false;
  await File(full).writeAsString(content);
  return true;
}

/// Drawing backlog I-1 — write an issued drawing's PDF (its full page list)
/// to a user-chosen `<electrical name>-<suffix>.pdf`.
Future<bool> _saveDrawingPdf(
  WidgetRef ref,
  IssuedSldDrawing drawing, {
  required String suffix,
  required String title,
}) async {
  final bytes = drawing.toPdf();
  final name = ref.read(electricalProjectProvider).name;
  final base = name.isEmpty ? 'electrical' : name;
  final full = await pickExportSave(ref,
      dialogTitle: title, fileName: '$base-$suffix.pdf', ext: 'pdf');
  if (full == null) return false;
  await File(full).writeAsBytes(bytes);
  return true;
}

/// Drawing backlog I-1 — write an issued drawing's DXF twin (one frame per
/// PDF page) to a user-chosen `<electrical name>-<suffix>.dxf`.
Future<bool> _saveDrawingDxf(
  WidgetRef ref,
  IssuedSldDrawing drawing, {
  required String suffix,
  required String title,
}) =>
    _save(ref, drawing.toDxf(),
        name: ref.read(electricalProjectProvider).name,
        suffix: suffix,
        ext: 'dxf',
        title: title);
