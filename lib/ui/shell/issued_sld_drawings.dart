/// Drawing backlog I-1 (2026-11-13) — the ONE place the app builds each
/// issued single-line-family drawing (mechanical riser, electrical SLD,
/// building single-line, electrical riser, power one-line) from the live
/// providers: page list, drawing number + sign-off chrome, project name and
/// heading. The submittal package and every standalone PDF / DXF export call
/// these builders, so a standalone pair is byte-for-byte the package's pair
/// (same pages, `SHEET i of n`, LANJUT marks, drawing number).
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart' show ServiceType;
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart'
    show SldDxfLayers;
import 'package:mechx_engine/report/electrical_pagination.dart'
    show paginatedElectricalOverviewSheets, paginatedElectricalRiserSheets;
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show electricalSldDetailSheets, electricalSldToPdfPaginated;
import 'package:mechx_engine/report/electrical_sld_drawing.dart'
    show buildPowerOneLineSheet;
import 'package:mechx_engine/report/issued_sld_drawing.dart';

import '../../store/document_control_store.dart';
import '../../store/electrical_store.dart';
import '../../store/project_store.dart';
import '../electrical/electrical_export.dart'
    show
        adsFailedCircuitIds,
        breakerIcuKaByPanel,
        breakerKaByCircuit,
        containmentByCircuit,
        electricalSheetProjectName;
import '../schematic/schematic_export.dart'
    show buildLiveRiserPages, riserDiagramTitle;

export 'package:mechx_engine/report/issued_sld_drawing.dart'
    show IssuedSldDrawing;

/// The issued chrome of a one-drawing series (sheet 1 of 1, re-stamped per
/// page by the set writers): drawing number by [series] (+ [index]), the
/// Document control revision / client / sign-off, and today's date. The same
/// chrome whether the drawing is issued in the package or on its own.
DrawingChrome issuedSldChrome(
  WidgetRef ref,
  DrawingSeries series, {
  int index = 1,
}) {
  final doc = ref.read(documentControlProvider);
  return DrawingChrome(
    sheetIndex: 1,
    sheetTotal: 1,
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

/// The mechanical riser single-line for [focus] (null = all systems, the
/// package's M-201) as issued pages. The combined riser stamps the register
/// title; a focused one its own system heading. [index] numbers a sheet of
/// the riser drawing SET (M-20[index]).
IssuedSldDrawing issuedMechanicalRiser(
  WidgetRef ref,
  ServiceType? focus, {
  int index = 1,
}) {
  final name = ref.read(projectControllerProvider).name.trim();
  final projectName = name.isEmpty ? null : name;
  final heading = focus == null
      ? drawingSeriesTitle(DrawingSeries.mechanicalRiser)
      : riserDiagramTitle(focus);
  final chrome =
      issuedSldChrome(ref, DrawingSeries.mechanicalRiser, index: index);
  return IssuedSldDrawing(
    pages: buildLiveRiserPages(ref, focus,
        diagramTitle: heading, chrome: chrome, projectName: projectName),
    title: 'iSystem mechanical single-line',
    diagramTitle: heading,
    chrome: chrome,
    projectName: projectName,
    layers: SldDxfLayers.forRiser(focus),
  );
}

/// The electrical detail single-line (E-201): one A3 sheet while it prints
/// at the label floor, else one board (way range) per page.
IssuedSldDrawing issuedElectricalSld(WidgetRef ref) {
  final chrome = issuedSldChrome(ref, DrawingSeries.electricalDetail);
  final projectName = electricalSheetProjectName(ref);
  final heading = drawingSeriesTitle(DrawingSeries.electricalDetail);
  return IssuedSldDrawing(
    pages: electricalSldDetailSheets(
      project: ref.read(electricalProjectProvider),
      result: ref.read(electricalResultProvider),
      breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
      breakerKaByCircuitId: breakerKaByCircuit(ref),
      adsFailedCircuitIds: adsFailedCircuitIds(ref),
      containmentByCircuitId: containmentByCircuit(ref),
      chrome: chrome,
      projectName: projectName,
      diagramTitle: heading,
    ),
    title: 'iSystem electrical single-line',
    diagramTitle: heading,
    chrome: chrome,
    projectName: projectName,
  );
}

/// The building single-line overview (E-301), with the source spine,
/// paginated by sub-tree when one sheet would print below the label floor.
IssuedSldDrawing issuedElectricalOverview(WidgetRef ref) {
  final chrome = issuedSldChrome(ref, DrawingSeries.electricalOverview);
  final projectName = electricalSheetProjectName(ref);
  final heading = drawingSeriesTitle(DrawingSeries.electricalOverview);
  return IssuedSldDrawing(
    pages: paginatedElectricalOverviewSheets(
      project: ref.read(electricalProjectProvider),
      result: ref.read(electricalResultProvider),
      sourceChain: true,
      chrome: chrome,
      projectName: projectName ?? 'Untitled project',
      diagramTitle: heading,
    ),
    title: 'iSystem electrical single-line (overview)',
    diagramTitle: heading,
    chrome: chrome,
    projectName: projectName,
  );
}

/// The floor-by-floor electrical riser (E-401) over the live building
/// levels, with the source spine, paginated by floor range.
IssuedSldDrawing issuedElectricalRiser(WidgetRef ref) {
  final chrome = issuedSldChrome(ref, DrawingSeries.electricalRiser);
  final projectName = electricalSheetProjectName(ref);
  final heading = drawingSeriesTitle(DrawingSeries.electricalRiser);
  return IssuedSldDrawing(
    pages: paginatedElectricalRiserSheets(
      project: ref.read(electricalProjectProvider),
      result: ref.read(electricalResultProvider),
      building: ref.read(projectControllerProvider).building,
      sourceChain: true,
      chrome: chrome,
      projectName: projectName ?? 'Untitled project',
      diagramTitle: heading,
    ),
    title: 'iSystem electrical building riser',
    diagramTitle: heading,
    chrome: chrome,
    projectName: projectName,
  );
}

/// The power one-line (E-501), or null when the project carries no energy
/// sources to draw one.
IssuedSldDrawing? issuedPowerOneLine(WidgetRef ref) {
  final oneLine = ref.read(electricalAdvancedProvider).powerOneLine;
  if (oneLine == null || oneLine.nodes.isEmpty) return null;
  final heading = drawingSeriesTitle(DrawingSeries.electricalPowerOneLine);
  return IssuedSldDrawing(
    pages: [buildPowerOneLineSheet(oneLine)],
    title: 'iSystem power one-line',
    diagramTitle: heading,
    chrome: issuedSldChrome(ref, DrawingSeries.electricalPowerOneLine),
    projectName: electricalSheetProjectName(ref),
  );
}

/// The panel schedules (E-601) as one multi-page vector PDF: one board (way
/// range) per page, `SHEET i of n` running over the set.
Uint8List issuedPanelSchedulesPdf(WidgetRef ref) =>
    electricalSldToPdfPaginated(
      project: ref.read(electricalProjectProvider),
      result: ref.read(electricalResultProvider),
      title: 'iSystem electrical panel schedules',
      // Drawing-review D3 — its own drawing: JADWAL PANEL / PANEL SCHEDULES,
      // number E-601 (never the SLD's E-201).
      diagramTitle: drawingSeriesTitle(DrawingSeries.panelSchedule),
      projectName: electricalSheetProjectName(ref),
      chrome: issuedSldChrome(ref, DrawingSeries.panelSchedule),
      breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
      breakerKaByCircuitId: breakerKaByCircuit(ref),
      adsFailedCircuitIds: adsFailedCircuitIds(ref),
      containmentByCircuitId: containmentByCircuit(ref),
    );
