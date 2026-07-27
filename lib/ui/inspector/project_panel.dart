import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show electricalSldToPdf;
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/mep_commercial.dart'
    show mepBomToCsv, mepQuotationToMarkdown;
import 'package:mechx_engine/report/mep_report.dart';
import 'package:mechx_engine/report/pdf_export.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart' show equipmentNodeTags;
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/report_pdf.dart';
import 'package:mechx_engine/report/report_strings.dart';
import 'package:mechx_engine/report/riser_tags.dart' show elementTags;
import 'package:mechx_engine/report/sld_export.dart'
    show sldSheetToPdf, sldSheetsToPdf;
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart' show standardDuctDiametersMm;
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import '../../data/plan_underlay.dart';
import '../../store/air_warnings_store.dart';
import '../../store/annotation_store.dart';
import '../../store/app_state.dart';
import '../../store/assemblies_store.dart';
import '../../store/calibration_store.dart';
import '../../store/compliance_store.dart';
import '../../store/design_issues_store.dart';
import '../../store/document_control_store.dart';
import '../../store/electrical_store.dart';
import '../../store/command_store.dart';
import '../../store/commercial_store.dart';
import '../../store/equipment_spec_store.dart';
import '../../store/export_prefs.dart';
import '../../store/fire_store.dart';
import '../../store/fixture_library_store.dart';
import '../../store/history_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/reference_line_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../../store/snap_settings_store.dart';
import '../../store/solve_store.dart';
import '../canvas/edge_context_menu.dart' show npsLabel;
import '../canvas/segment_palette.dart';
import '../canvas/segment_symbols.dart';
import '../canvas/service_style.dart';
import '../electrical/electrical_export.dart' show breakerIcuKaByPanel;
import '../../report/reference_grid_builder.dart';
import '../format/scale_format.dart';
import '../schematic/schematic_export.dart' show buildLiveRiserSheet;
import '../shell/nav_rail.dart';
import '../strings/app_strings.dart';
import 'disclosure_header.dart';
import 'fixture_library_editor.dart';
import 'result_card.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/mechx_scrollbar.dart';
import '../widgets/mechx_text_field.dart';
import '../widgets/section_label.dart';
import '../widgets/severity_glyph.dart';
import '../widgets/stepped_value_field.dart';

/// Gather the live mechanical/plumbing design results into a [CalcReportData].
/// Shared by the standalone calc-report export and the unified MEP report so
/// both render the same mechanical basis + sections. Public for the export
/// wiring test (the document-control revisions must reach the report head).
CalcReportData buildMechanicalReportData(WidgetRef ref) {
  final project = ref.read(projectControllerProvider);
  final strategy = ref.read(feedStrategyProvider);
  final downfeed = ref.read(downfeedProvider);
  final balance = ref.read(airBalanceProvider);
  const profile = SniProfile();

  return CalcReportData(
    projectName: project.name,
    date: DateTime.now().toIso8601String().split('T').first,
    standardsName: profile.name,
    standardsRevision: profile.revision,
    verifyItems: profile.verifyChecklist,
    building: project.building,
    feedStrategy:
        strategy == FeedStrategy.upfeed ? 'Upfeed pump' : 'Roof-tank downfeed',
    targetResidual:
        SupplyDesignCriteria.recommended().targetFixtureResidualPressure,
    pump: ref.read(pumpDutyProvider),
    boosterHead: downfeed?.boosterHeadRequired,
    gravitySufficient: downfeed?.gravitySufficient ?? false,
    zones: ref.read(zoneStaticsProvider),
    hotWaterRecirc: ref.read(hotWaterRecircProvider),
    sprinkler: ref.read(sprinklerDesignProvider),
    standpipe: ref.read(standpipeDesignProvider),
    sprinklerRemoteArea: ref.read(sprinklerRemoteAreaProvider),
    firePumpRating: ref.read(firePumpRatingProvider),
    fan: ref.read(ductFanProvider),
    supplyAirflowLps: balance?.supplyLps ?? 0,
    returnAirflowLps: balance?.returnLps ?? 0,
    rainfallMmPerHr: ref.read(rainfallIntensityProvider),
    runoffCoefficient: ref.read(runoffCoefficientProvider),
    bom: ref.read(bomProvider),
    fittings: ref.read(fittingsProvider),
    occupancy: ref.read(occupancyProvider),
    revisions: ref.read(documentControlProvider).revisions,
  );
}

/// Gather the live electrical design into an [ElectricalCalcReportData] with the
/// document-control revisions. Shared by the unified MEP report exports (MD +
/// PDF) so both render the same electrical basis + sections. Public for the
/// export wiring test.
ElectricalCalcReportData buildElectricalReportData(WidgetRef ref) {
  final project = ref.read(projectControllerProvider);
  final eProject = ref.read(electricalProjectProvider);
  final eResult = ref.read(electricalResultProvider);
  final eAdvanced = ref.read(electricalAdvancedProvider);
  const eProfile = PuilProfile();
  return ElectricalCalcReportData(
    projectName: project.name,
    date: DateTime.now().toIso8601String().split('T').first,
    standardsName: eProfile.name,
    standardsRevision: eProfile.revision,
    project: eProject,
    result: eResult,
    powerOneLine: eAdvanced.powerOneLine,
    verifyItems: eAdvanced.verifyItems,
    originFaultLevelA: eProject.originFaultLevelA?.amperes,
    busbarClearingTimeS: eProject.busbarClearingTimeS,
    revisions: ref.read(documentControlProvider).revisions,
  );
}

/// Shared export driver: the completeness GUARD + success/failure FEEDBACK that
/// wraps every export action. (1) If any sized edge resolves to zero geometric
/// length (an uncalibrated sheet carrying drawn runs — they size to ZERO
/// length), it raises a dismissible warning on [loadErrorProvider] and writes
/// NOTHING — the engineer must calibrate first, so the BOM / pressures / drawing
/// can't be silently wrong. (2) Otherwise it awaits [write] inside try/catch:
/// `write` returns false when the user cancelled the file picker (no pill), true
/// after a successful write ⇒ a transient "Exported `name`" confirmation pill;
/// any thrown error ⇒ a "Could not export `name`" warning. The success pill
/// reuses the same self-clearing mechanism as Save / Open / Import. Public so
/// every export surface (the riser drawing set in `schematic_export.dart`, the
/// electrical + commercial exports) routes through the SAME guard + feedback.
///
/// The zero-length gate iterates only the MECHANICAL network, so a
/// pure-electrical project is never blocked; a project that also carries
/// uncalibrated mechanical runs is held back until the sheet is calibrated —
/// conservative, and correct for any deliverable that could embed those runs.
Future<void> runExportGuarded(
  WidgetRef ref, {
  required String name,
  required Future<bool> Function() write,
}) async {
  if (ref.read(exportHasZeroLengthEdgesProvider)) {
    final n = ref.read(zeroLengthSizedEdgeCountProvider);
    ref.read(loadErrorProvider.notifier).set(
          '$n drawn element(s) have zero length — calibrate the sheet before '
          'exporting $name. The BOM, pressures and drawing would be wrong.',
        );
    return;
  }
  try {
    final wrote = await write();
    if (wrote) {
      ref.read(statusMessageProvider.notifier).showStatus('Exported $name');
      // The stepper's Report stage is DONE only once a deliverable actually
      // exists — this one line covers every export routed through here.
      ref.read(reportExportedProvider.notifier).markExported();
    }
  } catch (e) {
    ref
        .read(loadErrorProvider.notifier)
        .set('Could not export $name: $e');
  }
}

/// H4 — a save-dialog wrapper that REMEMBERS the last export directory: it opens
/// the OS picker at the shared `lastExportDirProvider` folder (so a session's
/// exports converge on one place), normalizes the chosen path to end in [ext],
/// and records the folder so the next dialog re-opens there. Returns null when
/// the user cancels. Every owned export routes through this so the dir-memory is
/// uniform; the exporters in other files should adopt it too (see the H4 note in
/// the review).
Future<String?> pickExportSave(
  WidgetRef ref, {
  required String dialogTitle,
  required String fileName,
  required String ext,
}) async {
  final path = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [ext],
    initialDirectory: ref.read(lastExportDirProvider),
  );
  if (path == null) return null;
  final full = path.endsWith('.$ext') ? path : '$path.$ext';
  ref.read(lastExportDirProvider.notifier).rememberFile(full);
  return full;
}

/// Render the floor-grouped [bom] as CSV with the stock-bar cut-plan columns
/// (`stock_length_m`, `bars_purchased`, `waste_pct`) joined per (service, DN)
/// from [cutPlan] (the `pipeCutPlanProvider` output). [bom] must be built with
/// `groupByFloor: true` so runs carry their floor.
///
/// The three cut-plan columns are a per-(service, DN) property (the plan packs
/// all runs of a size into shared stock bars; risers are excluded from the
/// chains), so they are emitted ONCE on the first BOM row of each (service, DN)
/// group — sum-safe — and left empty on the rest, and empty when the plan has no
/// entry for a group (a riser-only DN, an air duct: never invented).
///
/// N13: a `tag` column (right after `kind`) carries the stable element tag
/// (`CW-R1` for a riser, `CW-F2` for a floor-grouped run) so a CSV takeoff line
/// traces to the same run/riser on the plan, riser single-line and calc report.
String bomCsvWithCutPlan(List<BomLine> bom, List<PipeCutGroup> cutPlan) {
  final planByKey = <({ServiceType service, int mm}), PipeCutGroup>{
    for (final g in cutPlan) (service: g.service, mm: g.diameterMm): g,
  };
  final emitted = <({ServiceType service, int mm})>{};
  final buffer = StringBuffer(
      'service,kind,tag,floor,nominal_dn_mm,length_m,segments,'
      'stock_length_m,bars_purchased,waste_pct\n');
  for (final line in bom) {
    final key = (service: line.service, mm: line.diameterMm);
    final g = planByKey[key];
    final showPlan = g != null && emitted.add(key);
    buffer
      ..write(line.service.name)
      ..write(',')
      ..write(line.kind.name)
      ..write(',')
      ..write(line.tag)
      ..write(',')
      ..write(line.floorIndex == null ? '' : (line.floorIndex! + 1))
      ..write(',')
      ..write(line.diameterMm)
      ..write(',')
      ..write(line.totalLength.meters.toStringAsFixed(2))
      ..write(',')
      ..write(line.segmentCount)
      ..write(',')
      ..write(showPlan ? g.stockLengthM.toStringAsFixed(1) : '')
      ..write(',')
      ..write(showPlan ? '${g.plan.totalBars}' : '')
      ..write(',')
      ..write(showPlan ? g.plan.wastePercent.toStringAsFixed(1) : '')
      ..write('\n');
  }
  return buffer.toString();
}


/// The report-body language for the active app locale (D4): Indonesian report
/// bodies when the app runs in ID, byte-identical EN otherwise.
ReportStrings reportStringsFor(WidgetRef ref) =>
    ref.read(localeProvider) == AppLocale.id
        ? const ReportStrings.id()
        : const ReportStrings.en();

/// Gather the live design results into a calc report and write it to a Markdown
/// file chosen by the user.
Future<void> exportCalcReport(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'calc report',
      write: () async {
        final project = ref.read(projectControllerProvider);
        final data = buildMechanicalReportData(ref);

        final full = await pickExportSave(ref,
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleCalcReport),
            fileName: '${project.name}-report.md',
            ext: 'md');
        if (full == null) return false;
        await File(full).writeAsString(
            buildCalcReportMarkdown(data, reportStringsFor(ref)));
        return true;
      },
    );

/// D1 — the TYPESET PDF calculation report: the SAME live data as the Markdown
/// export ([exportCalcReport]), rendered to a submittable A4-portrait PDF with
/// the document-control identity on the cover, and the mechanical riser
/// single-line appended as an embedded vector figure. The figure rides the PDF
/// build only — the Markdown output stays byte-identical.
Future<void> exportCalcReportPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'calc report (PDF)',
      write: () async {
        final project = ref.read(projectControllerProvider);
        final data = buildMechanicalReportData(ref);
        final doc = ref.read(documentControlProvider);
        final blocks = [
          ...buildCalcReportBlocks(data, reportStringsFor(ref)),
          RptFigure(buildLiveRiserSheet(ref, null),
              caption: 'Mechanical riser single-line diagram'),
        ];
        final bytes = reportBlocksToPdf(
          blocks,
          docTitle: 'MEP Calculation Report',
          projectName:
              project.name.isEmpty ? 'Untitled project' : project.name,
          documentNumber: doc.documentNumber,
          revisionTag: doc.revisionTag,
          dateString: data.date,
          standardsLine: '${data.standardsName} (${data.standardsRevision})',
          preparedBy: doc.preparedBy,
          checkedBy: doc.checkedBy,
          approvedBy: doc.approvedBy,
        );
        final base = project.name.isEmpty ? 'project' : project.name;
        final full = await pickExportSave(ref,
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleCalcReportPdf),
            fileName: '$base-report.pdf',
            ext: 'pdf');
        if (full == null) return false;
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// The compliance pass/fail roll-up. The fan-in moved to
/// `store/compliance_store.dart` (H2) as a WATCHED provider so the Review
/// hub's verdict re-computes live; this thin read keeps the export call sites
/// (and their tests) on one entry point.
ComplianceSummary buildComplianceSummary(WidgetRef ref) =>
    ref.read(complianceSummaryProvider);

/// Gather BOTH the mechanical and electrical designs into one unified MEP
/// building-services report (with a compliance summary) and write it to a
/// Markdown file chosen by the user.
Future<void> exportMepUnifiedReport(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'MEP report',
      write: () async {
        final project = ref.read(projectControllerProvider);
        final mechanical = buildMechanicalReportData(ref);
        final electrical = buildElectricalReportData(ref);

        final md = buildMepUnifiedReport(
          mechanical: mechanical,
          electrical: electrical,
          compliance: buildComplianceSummary(ref),
          strings: reportStringsFor(ref),
        );

        final base = project.name.isEmpty ? 'project' : project.name;
        final full = await pickExportSave(ref,
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleMepReport),
            fileName: '$base-mep-report.md',
            ext: 'md');
        if (full == null) return false;
        await File(full).writeAsString(md);
        return true;
      },
    );

/// D1 — the TYPESET PDF unified MEP report: the SAME mechanical + electrical +
/// compliance data as the Markdown export ([exportMepUnifiedReport]), rendered
/// to a submittable A4-portrait PDF with the document-control identity on the
/// cover, and BOTH single-line diagrams appended as embedded vector figures —
/// the mechanical riser (combined focus) and the electrical single-line (with
/// the C5 fault-study breaking-capacity notation). The figures ride the PDF
/// build only — the Markdown output stays byte-identical.
Future<void> exportMepUnifiedReportPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'MEP report (PDF)',
      write: () async {
        final project = ref.read(projectControllerProvider);
        final mechanical = buildMechanicalReportData(ref);
        final electrical = buildElectricalReportData(ref);
        final doc = ref.read(documentControlProvider);

        final blocks = [
          ...buildMepUnifiedReportBlocks(
            mechanical: mechanical,
            electrical: electrical,
            compliance: buildComplianceSummary(ref),
            strings: reportStringsFor(ref),
          ),
          const RptHeading(1, 'Drawings'),
          RptFigure(buildLiveRiserSheet(ref, null),
              caption: 'Mechanical riser single-line diagram'),
          RptFigure(
            buildElectricalSld(
              project: ref.read(electricalProjectProvider),
              result: ref.read(electricalResultProvider),
              breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
            ),
            caption: 'Electrical single-line diagram',
          ),
        ];
        final bytes = reportBlocksToPdf(
          blocks,
          docTitle: 'MEP Building-Services Report',
          projectName:
              project.name.isEmpty ? 'Untitled project' : project.name,
          documentNumber: doc.documentNumber,
          revisionTag: doc.revisionTag,
          dateString: mechanical.date,
          standardsLine:
              '${mechanical.standardsName} (${mechanical.standardsRevision})'
              ' / ${electrical.standardsName} ${electrical.standardsRevision}',
          preparedBy: doc.preparedBy,
          checkedBy: doc.checkedBy,
          approvedBy: doc.approvedBy,
        );

        final base = project.name.isEmpty ? 'project' : project.name;
        final full = await pickExportSave(ref,
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleMepReportPdf),
            fileName: '$base-mep-report.pdf',
            ext: 'pdf');
        if (full == null) return false;
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// Gather the live solved equipment (pumps, fans, room AHU/FCU/AC, and
/// electrical panels) into an [EquipmentScheduleData] and write the equipment
/// schedule to a Markdown file chosen by the user. The engine only tabulates
/// already-solved duties — no new sizing here. Tags are assigned at gather time
/// (sequential when not user-named), so the engine results stay untouched.
Future<void> exportEquipmentSchedule(WidgetRef ref) => runExportGuarded(
      ref,
      // The MD deliverable now writes a matching spreadsheet sibling too
      // (`-equipment-schedule.md` + `-equipment-schedule.csv`, mirroring the
      // BOM export's dual-file pattern) so the engineer gets both from one
      // dialog.
      name: 'equipment schedule (MD + CSV)',
      write: () => _writeEquipmentSchedule(ref),
    );

/// J3 — a STABLE equipment tag for a room's air-handling unit, derived from the
/// room's PERSISTED identity rather than its position in the live list. A room's
/// tag must not change when an unrelated room is added, deleted, reordered, or
/// skipped (an uncalibrated sheet's room has no sizing) between revisions, or the
/// schedule/BOM lose traceability to what was procured/installed.
///
/// `RoomAreaController` mints ids as `r0`, `r1`, … — a monotonic first-assigned
/// ordinal that round-trips in `.mechx`. The AHU number is that ordinal + 1
/// (so it also matches the room's `Room N` display name). Numbers may therefore
/// carry gaps after a deletion — that is the point: each unit keeps its number
/// for life. Falls back to the live index only when an id carries no trailing
/// integer (defensive — every real room id does).
String _roomScheduleTag(RoomArea room, int fallbackIndex) {
  final m = RegExp(r'(\d+)$').firstMatch(room.id);
  final n = m != null ? int.parse(m.group(1)!) + 1 : fallbackIndex + 1;
  return 'AHU-${n.toString().padLeft(2, '0')}';
}

/// Gather the live solved equipment (pumps, fans, room AHU/FCU/AC, and
/// electrical panels) into an [EquipmentScheduleData]. Shared by the MD/CSV and
/// PDF exports; the engine only TABULATES already-solved duties (no new sizing).
/// Tags are assigned here (sequential when a source carries none, stable per
/// room identity for AHUs), so the engine results stay untouched. Public for the
/// export wiring test.
EquipmentScheduleData gatherEquipmentScheduleData(WidgetRef ref) {
  final project = ref.read(projectControllerProvider);
  // N23: the engineer-entered "Model / spec" overrides, keyed by the SAME
  // stable tag assigned below — looked up once so a re-solve (which never
  // touches this map) still carries the entered spec through.
  final specs = ref.read(equipmentModelSpecProvider);

  // Pumps: the domestic-supply booster (upfeed) + the standpipe fire pump.
  final pumps = <PumpScheduleItem>[];
  final supplyPump = ref.read(pumpDutyProvider);
  if (supplyPump != null) {
    const tag = 'P-01';
    pumps.add(PumpScheduleItem(
      duty: supplyPump,
      service: 'Domestic water supply',
      tag: tag,
      modelSpec: specs[tag],
    ));
  }
  final standpipe = ref.read(standpipeDesignProvider);
  if (standpipe.requiredFlow.cubicMetersPerSecond > 0) {
    const tag = 'FP-01';
    pumps.add(PumpScheduleItem(
      duty: sizePump(
        flow: standpipe.requiredFlow,
        head: standpipe.pumpHead,
      ),
      service: 'Fire standpipe pump',
      tag: tag,
      modelSpec: specs[tag],
    ));
  }

  // Fans: the drawn supply/exhaust duct fan.
  final fans = <FanScheduleItem>[];
  final ductFan = ref.read(ductFanProvider);
  if (ductFan != null) {
    const tag = 'F-01';
    fans.add(FanScheduleItem(
      duty: ductFan,
      service: 'Mechanical ventilation',
      tag: tag,
      modelSpec: specs[tag],
    ));
  }

  // Air-handling: each drawn ROOM's AHU/FCU/AC equipment duty (FanDuty).
  final ducts = ref.read(ductSettingsProvider);
  final rooms = ref.read(roomAreasProvider);
  for (var i = 0; i < rooms.length; i++) {
    final r = rooms[i];
    final cal = project.calibrationFor(r.sheetId);
    final sizing = r.sizing(
      cal?.metersPerPixel,
      ductShape: ducts.shape,
      ductMethod: ducts.method,
    );
    if (sizing == null) continue;
    // J3: the AHU tag tracks the room's STABLE identity, not its live list
    // position — deleting / reordering / skipping (uncalibrated) another room
    // never renumbers this unit, so a procured AHU-03 stays AHU-03 across
    // revisions ([_roomScheduleTag]).
    final tag = _roomScheduleTag(r, i);
    fans.add(FanScheduleItem(
      duty: sizing.equipment,
      service: r.name,
      tag: tag,
      modelSpec: specs[tag],
      airHandling: true,
    ));
  }

  return EquipmentScheduleData(
    projectName: project.name,
    date: DateTime.now().toIso8601String().split('T').first,
    pumps: pumps,
    fans: fans,
    electrical: ref.read(electricalResultProvider),
    // N22 (app half): the source apparatus (transformer / standby genset /
    // PF-correction bank) the electrical project may carry, so the schedule
    // no longer omits the highest-value long-lead items on the source spine.
    electricalProject: ref.read(electricalProjectProvider),
    // N23 (residual): the engineer-entered model/spec for the PANEL + apparatus
    // rows (pumps/fans carry their own per-item override above), keyed by the
    // panel tag/name + the fixed TX-01/G-01/CB-01 apparatus tags.
    modelSpecs: specs,
  );
}

/// N23 — the equipment tags [gatherEquipmentScheduleData] currently assigns,
/// paired with their service label, for the model/spec edit surface below. The
/// pump/fan/AHU rows are read from the schedule inputs directly (their tags are
/// assigned by the app); the electrical PANEL + source-apparatus rows
/// (transformer / standby genset / PF-correction bank) are taken from the BUILT
/// [EquipmentScheduleRow]s so the same stable tags the engine keys `modelSpecs`
/// on (a panel's tag/name, `TX-01` / `G-01` / `CB-01`) get an edit field too.
///
/// The section's VISIBILITY is gated on mechanical equipment (pumps/fans/AHU)
/// being present ([_hasMechanicalEquipmentTargets]) — so merely seeding an
/// electrical project's panels never SURFACES this mechanical-inspector section
/// (a blank-mechanical launch stays byte-identical); the panel/apparatus rows
/// ride along only once the section is already shown for real mechanical duty.
List<({String tag, String service})> _equipmentSpecTargets(WidgetRef ref) {
  final data = gatherEquipmentScheduleData(ref);
  const apparatus = {
    EquipmentCategory.panel,
    EquipmentCategory.transformer,
    EquipmentCategory.generator,
    EquipmentCategory.capacitorBank,
  };
  return [
    for (final p in data.pumps) (tag: p.tag!, service: p.service),
    for (final f in data.fans) (tag: f.tag!, service: f.service),
    for (final r in buildEquipmentScheduleRows(data))
      if (apparatus.contains(r.category)) (tag: r.tag, service: r.service),
  ];
}

/// Whether the equipment model/spec section should be SHOWN — true only when
/// the project carries sized MECHANICAL equipment (a pump or fan/AHU). The
/// electrical panel/apparatus rows are additive detail once shown; they never
/// surface the section on their own (keeps the goldens' seeded-electrical launch
/// byte-identical).
bool _hasMechanicalEquipmentTargets(WidgetRef ref) {
  final data = gatherEquipmentScheduleData(ref);
  return data.pumps.isNotEmpty || data.fans.isNotEmpty;
}

Future<bool> _writeEquipmentSchedule(WidgetRef ref) async {
  final project = ref.read(projectControllerProvider);
  final data = gatherEquipmentScheduleData(ref);

  final base = project.name.isEmpty ? 'project' : project.name;
  final full = await pickExportSave(ref,
      dialogTitle: MechXStringsData(ref.read(localeProvider))(
          StringKey.exportTitleEquipmentSchedule),
      fileName: '$base-equipment-schedule.md',
      ext: 'md');
  if (full == null) return false;
  // Write the Markdown at the chosen path plus a spreadsheet CSV sibling
  // (D5: the row model was designed for a CSV emitter). The engineer picks
  // one name; both files land beside it (the BOM export's dual-file pattern).
  final stem = full.substring(0, full.length - 3);
  await File('$stem.md')
      .writeAsString(buildEquipmentScheduleMarkdown(data, reportStringsFor(ref)));
  await File('$stem.csv')
      .writeAsString(equipmentScheduleToCsv(buildEquipmentScheduleRows(data)));
  return true;
}

/// D1 — the TYPESET PDF equipment schedule: the SAME live solved equipment as
/// the MD/CSV export ([exportEquipmentSchedule]), rendered to a submittable
/// A4-portrait PDF with the document-control identity on the cover.
Future<void> exportEquipmentSchedulePdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'equipment schedule (PDF)',
      write: () async {
        final project = ref.read(projectControllerProvider);
        final data = gatherEquipmentScheduleData(ref);
        final doc = ref.read(documentControlProvider);
        final bytes = reportBlocksToPdf(
          buildEquipmentScheduleBlocks(data, reportStringsFor(ref)),
          docTitle: 'Equipment Schedule',
          projectName:
              project.name.isEmpty ? 'Untitled project' : project.name,
          documentNumber: doc.documentNumber,
          revisionTag: doc.revisionTag,
          dateString: data.date,
          preparedBy: doc.preparedBy,
          checkedBy: doc.checkedBy,
          approvedBy: doc.approvedBy,
        );
        final base = project.name.isEmpty ? 'project' : project.name;
        final full = await pickExportSave(ref,
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleEquipmentSchedulePdf),
            fileName: '$base-equipment-schedule.pdf',
            ext: 'pdf');
        if (full == null) return false;
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// Build the issuable-drawing chrome (legend / scale bar / north arrow / sheet
/// "X of Y" / ISO-7200 title block) for the current [sheetId]/[floorIndex].
/// The legend lists the services actually present on this floor; the sheet
/// counter is the sheet's position in the rail. The document-control identity
/// (D3: revision tag, client, DRAWN/CHECKED/APPROVED) comes from
/// [documentControlProvider] — an unset field stays null so its title-block row
/// is simply omitted, EXCEPT the drawing NUMBER, which is always DERIVED per
/// sheet (N19: `M-1xx` by rail position, or the manual `documentNumber` verbatim
/// when set). The issue DATE is formatted HERE (the engine never reads the
/// clock). North defaults to 0 (page-up). Pure-data: the export engine renders
/// it. Public for the export wiring test.
DrawingChrome issuableChrome(
  WidgetRef ref, {
  required String sheetId,
  required int floorIndex,
}) {
  final sheets = ref.read(sheetsControllerProvider).sheets;
  final net = ref.read(networkControllerProvider).network;

  // Services present on this floor (runs on-floor, risers anchored here), in
  // the canonical draw order so the legend reads consistently.
  bool onFloor(String id) {
    final n = net.nodeById(id);
    return n != null && n.sheetId == sheetId && n.floorIndex == floorIndex;
  }

  final present = <ServiceType>{};
  for (final e in net.edges) {
    if (onFloor(e.fromId) || onFloor(e.toId)) present.add(e.service);
  }
  final legend = [
    for (final s in kDrawServices)
      if (present.contains(s)) s,
  ];

  final idx = sheets.indexWhere((s) => s.id == sheetId);
  final doc = ref.read(documentControlProvider);
  return DrawingChrome(
    sheetIndex: idx >= 0 ? idx + 1 : null,
    sheetTotal: sheets.isNotEmpty ? sheets.length : null,
    legendServices: legend,
    // N19: the plan's drawing number is DERIVED per sheet — the mechanical plan
    // band `M-1xx`, running by RAIL POSITION — so sheet 1 is `M-101`, sheet 2
    // `M-102`, never one number on every plan. A manual `documentNumber` remains
    // the verbatim override, so a set left on the defaults still numbers itself.
    drawingNumber: sheetDrawingNumber(
      base: doc.documentNumber,
      series: DrawingSeries.mechanicalPlan,
      index: idx >= 0 ? idx + 1 : 1,
    ),
    revisionNumber: doc.revisionTag,
    clientName: doc.clientName,
    drawnBy: doc.preparedBy,
    checkedBy: doc.checkedBy,
    approvedBy: doc.approvedBy,
    dateString: DateTime.now().toIso8601String().split('T').first,
  );
}

/// N5: a per-run centreline-elevation label ('CL +2.70') keyed by edge id — the
/// height of each horizontal run above its floor's FFL, from the §10 role-aware
/// [nodeElevation] (mains at the ceiling, fixture branches at fixture height).
/// Only RUN edges get an entry (risers carry the FFL gutter on the riser sheet);
/// the pure exporters receive the finished strings and never read the model. The
/// average of the two endpoint elevations is the run's representative centreline.
Map<String, String> planEdgeElevationLabels(Network net, BuildingLevels building) {
  const mounting = MountingHeights();
  final out = <String, String>{};
  for (final e in net.edges) {
    if (e.kind != EdgeKind.run) continue;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    final ea = nodeElevation(a, building, mounting).meters;
    final eb = nodeElevation(b, building, mounting).meters;
    final aboveFfl = (ea + eb) / 2 - building.elevationOf(a.floorIndex).meters;
    final sign = aboveFfl >= 0 ? '+' : '-';
    out[e.id] = 'CL $sign${aboveFfl.abs().toStringAsFixed(2)}';
  }
  return out;
}

/// Export the current sheet/floor's drawn network as a DXF drawing file.
Future<void> exportDrawingDxf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'DXF drawing',
      write: () => _writeDrawingDxf(ref),
    );

Future<bool> _writeDrawingDxf(WidgetRef ref) async {
  final sheets = ref.read(sheetsControllerProvider);
  final sheet = sheets.current;
  if (sheet == null) return false;
  final project = ref.read(projectControllerProvider);
  final levelCount = project.building.levelCount;
  final floorIndex = sheets.floorFor(sheet.id, levelCount);
  // A1: the floor-plan underlay — DXF sheets only here (the R12 re-emit is
  // vector-only; a PDF-backed sheet's raster rides the PDF exports instead).
  final planUnderlay =
      sheet.dxfPath != null ? await buildPlanUnderlay(sheet) : null;
  final net = ref.read(networkControllerProvider).network;
  final dxf = networkToDxf(
    net: net,
    sizing: ref.read(sizingProvider),
    sheetId: sheet.id,
    floorIndex: floorIndex,
    chrome: issuableChrome(ref, sheetId: sheet.id, floorIndex: floorIndex),
    // A2: the sheet calibration lets the DXF emit true-scale mm world units
    // (HEADER/$INSUNITS + named layers); null keeps the legacy pixel DXF.
    metersPerPixel: project.calibrationFor(sheet.id)?.metersPerPixel,
    underlay: planUnderlay is VectorPlanUnderlay ? planUnderlay : null,
    // N5: the §10 centreline-height token folded into each run's size label.
    edgeElevationLabels: planEdgeElevationLabels(net, project.building),
    // N13: the stable element tag (`CW-R1` / `CW-F2`) on each run/riser so the
    // plan DXF traces to the same element the riser + BOM + report carry.
    edgeTags: elementTags(net),
    // N4/B12: the setting-out grid from axis-aligned traced reference lines.
    grid: buildReferenceGrid(ref.read(referenceLinesProvider), sheet.id),
    // G1: the stable equipment tags (P-01 / TK-01 / AHU-01 …) beside each plant
    // glyph, and G5: the laid gravity fall (1:N) folded into gravity-run size
    // labels — the same tokens the on-canvas plan shows, now on the issued DXF.
    nodeTags: equipmentNodeTags(net),
    gravitySlope: const SizingContext().drainageSlope,
  );
  final full = await pickExportSave(ref,
      dialogTitle: MechXStringsData(ref.read(localeProvider))(
          StringKey.exportTitleDrawingDxf),
      fileName: '${sheet.name}.dxf',
      ext: 'dxf');
  if (full == null) return false;
  await File(full).writeAsString(dxf);
  return true;
}

/// Export the current sheet/floor's drawn network as a native (vector) PDF.
Future<void> exportDrawingPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'PDF drawing',
      write: () => _writeDrawingPdf(ref),
    );

Future<bool> _writeDrawingPdf(WidgetRef ref) async {
  final sheets = ref.read(sheetsControllerProvider);
  final sheet = sheets.current;
  if (sheet == null) return false;
  final project = ref.read(projectControllerProvider);
  final levelCount = project.building.levelCount;
  final floorIndex = sheets.floorFor(sheet.id, levelCount);
  final net = ref.read(networkControllerProvider).network;
  final bytes = networkToPdf(
    net: net,
    sizing: ref.read(sizingProvider),
    sheetId: sheet.id,
    floorIndex: floorIndex,
    title: sheet.name,
    chrome: issuableChrome(ref, sheetId: sheet.id, floorIndex: floorIndex),
    // A3: the sheet calibration snaps the plot to a standard scale (1:N) and
    // makes the scale bar honest; null keeps the auto-fit + an NTS scale row.
    metersPerPixel: project.calibrationFor(sheet.id)?.metersPerPixel,
    // A1: the floor-plan substrate beneath the network — vector for a DXF
    // sheet, faded raster for a PDF sheet; null (placeholder / unreadable
    // source) keeps the plain export.
    underlay: await buildPlanUnderlay(sheet),
    // G1: stable equipment tags (P-01 / TK-01 / AHU-01 …) beside each plant
    // glyph, and G5: the laid gravity fall (1:N) on gravity-run size labels —
    // the same tokens the on-canvas plan shows, now on the issued PDF.
    nodeTags: equipmentNodeTags(net),
    gravitySlope: const SizingContext().drainageSlope,
  );
  final full = await pickExportSave(ref,
      dialogTitle: MechXStringsData(ref.read(localeProvider))(
          StringKey.exportTitleDrawingPdf),
      fileName: '${sheet.name}.pdf',
      ext: 'pdf');
  if (full == null) return false;
  await File(full).writeAsBytes(bytes);
  return true;
}

/// Export the current sheet/floor's drawn network as a native ANNOTATED plan
/// PDF — the richer drawing deliverable with a title block (project / sheet /
/// date) and real §10 run/riser LENGTHS folded into each size label. The real
/// lengths are pre-computed here (the engine `edgeLength` over the live
/// calibrations + building) and passed to the pure `planToPdf`.
Future<void> exportAnnotatedPlanPdf(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'annotated plan PDF',
      write: () => _writeAnnotatedPlanPdf(ref),
    );

Future<bool> _writeAnnotatedPlanPdf(WidgetRef ref) async {
  final sheets = ref.read(sheetsControllerProvider);
  final sheet = sheets.current;
  if (sheet == null) return false;
  final project = ref.read(projectControllerProvider);
  final levelCount = project.building.levelCount;
  final floorIndex = sheets.floorFor(sheet.id, levelCount);
  final net = ref.read(networkControllerProvider).network;

  // Real length per edge from the §10 sources of truth (run via calibration,
  // riser via the elevation delta).
  final edgeLengths = <String, Length>{
    for (final e in net.edges)
      e.id: edgeLength(
        e,
        net,
        calibrationBySheet: project.calibrations,
        building: project.building,
      ),
  };

  final bytes = planToPdf(
    net: net,
    sizing: ref.read(sizingProvider),
    edgeLengths: edgeLengths,
    sheetId: sheet.id,
    floorIndex: floorIndex,
    projectName: project.name,
    sheetName: sheet.name,
    dateString: DateTime.now().toIso8601String().split('T').first,
    chrome: issuableChrome(ref, sheetId: sheet.id, floorIndex: floorIndex),
    // A3: the sheet calibration snaps the plot to a standard scale (1:N) and
    // makes the scale bar honest; null keeps the auto-fit + an NTS scale row.
    metersPerPixel: project.calibrationFor(sheet.id)?.metersPerPixel,
    // A1: the floor-plan substrate beneath the network — vector for a DXF
    // sheet, faded raster for a PDF sheet; null (placeholder / unreadable
    // source) keeps the plain export.
    underlay: await buildPlanUnderlay(sheet),
    // N5: the §10 centreline-height token folded into each run's size label.
    edgeElevationLabels: planEdgeElevationLabels(net, project.building),
    // N13: the stable element tag (`CW-R1` / `CW-F2`) prepended to each label so
    // the plan traces to the same element the riser + BOM + report carry.
    edgeTags: elementTags(net),
    // N4/B12: axis-aligned traced reference lines become the setting-out grid
    // (vertical → lettered columns, horizontal → numbered rows); diagonal ones
    // are snap-only. Empty ⇒ no grid drawn (byte-identical).
    grid: buildReferenceGrid(ref.read(referenceLinesProvider), sheet.id),
    // G1: stable equipment tags (P-01 / TK-01 / AHU-01 …) beside each plant
    // glyph, and G5: the laid gravity fall (1:N) on gravity-run size labels —
    // the same tokens the on-canvas plan shows, now on the issued plan PDF.
    nodeTags: equipmentNodeTags(net),
    gravitySlope: const SizingContext().drainageSlope,
  );
  final full = await pickExportSave(ref,
      dialogTitle: MechXStringsData(ref.read(localeProvider))(
          StringKey.exportTitleAnnotatedPlanPdf),
      fileName: '${sheet.name}-annotated.pdf',
      ext: 'pdf');
  if (full == null) return false;
  await File(full).writeAsBytes(bytes);
  return true;
}

/// H4 — the ONE-FOLDER SUBMITTAL PACKAGE. Pick a destination folder ONCE, then
/// write the full deliverable set — the calc report + unified MEP report (MD +
/// PDF), the equipment schedule (MD + CSV + PDF), the M+E+P BOM (CSV) + costed
/// quotation (MD), the mechanical riser single-line (PDF), EVERY sheet's
/// annotated plan (PDF + DXF — J2: the whole rail, not just the sheet that
/// happened to be active), and the electrical single-line (PDF, when panels
/// exist) — all consistently named `$project-*` into that one folder. Routed
/// through the shared export guard (zero-length gate + success/error feedback);
/// the chosen folder seeds `lastExportDirProvider` so subsequent single exports
/// re-open there. Reuses the SAME pure engine builders the individual exports do
/// (no new render path), so each file matches its standalone sibling.
Future<void> exportSubmittalPackage(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'submittal package',
      write: () => _writeSubmittalPackage(ref),
    );

Future<bool> _writeSubmittalPackage(WidgetRef ref) async {
  final dir = await FilePicker.getDirectoryPath(
    dialogTitle: 'Choose a folder for the submittal package',
    initialDirectory: ref.read(lastExportDirProvider),
  );
  if (dir == null || dir.isEmpty) return false;
  ref.read(lastExportDirProvider.notifier).set(dir);
  return writeSubmittalPackageToDir(ref, dir);
}

/// J2: the submittal package's actual file-writing pass, factored out of
/// [_writeSubmittalPackage] so a test can drive it directly with an explicit
/// [dir] — bypassing the (headless-incompatible) `FilePicker.getDirectoryPath`
/// call above. Every sheet in the rail gets its own annotated plan PDF + DXF
/// (not just `sheets.current`), each numbered by [issuableChrome]'s per-sheet
/// N19 drawing number (`M-101`/`M-102`/… by rail position); the Daftar Gambar
/// (N21) front matter lists one row per bundled sheet to match. Progress
/// during the per-sheet loop rides the shared [busyProvider] pill, cleared in
/// a `finally` so a thrown mid-loop error never leaves it stuck.
@visibleForTesting
Future<bool> writeSubmittalPackageToDir(WidgetRef ref, String dir) async {
  final project = ref.read(projectControllerProvider);
  final base = project.name.trim().isEmpty ? 'project' : project.name.trim();
  final strings = reportStringsFor(ref);
  final doc = ref.read(documentControlProvider);
  final today = DateTime.now().toIso8601String().split('T').first;
  final sep = Platform.pathSeparator;
  String out(String suffix) => '$dir$sep$base-$suffix';

  // N19: the riser single-line and the electrical single-line in the package
  // are DIFFERENT drawings, so each derives its own number by [series] (the
  // mechanical riser `M-201`, the electrical detail `E-201`) rather than sharing
  // one `documentNumber` verbatim.
  DrawingChrome sldChrome(DrawingSeries series) => DrawingChrome(
        sheetIndex: 1,
        sheetTotal: 1,
        drawingNumber:
            sheetDrawingNumber(base: doc.documentNumber, series: series),
        revisionNumber: doc.revisionTag,
        clientName: doc.clientName,
        drawnBy: doc.preparedBy,
        checkedBy: doc.checkedBy,
        approvedBy: doc.approvedBy,
        dateString: today,
      );

  // ── N21/N24: front matter — cover + Daftar Gambar + general-notes & MASTER
  // legend — written FIRST so the issued set opens with a cover, an index, and
  // the shared symbol dictionary (services / equipment / riser markers / flow
  // chevron / fixture triangle / cable families). Built from the SAME derived
  // drawing numbers the individual sheets stamp; rendered through the shared SLD
  // path so it carries the uniform title block. ────────────────────────────────
  final netFm = ref.read(networkControllerProvider).network;
  final eProjectFm = ref.read(electricalProjectProvider);
  final eResultFm = ref.read(electricalResultProvider);
  final sheetsFm = ref.read(sheetsControllerProvider);
  final rev = doc.revisionTag ?? '';

  // J2: one Daftar Gambar row per BUNDLED sheet — every floor in the rail,
  // not just whichever sheet happened to be active — matching the per-sheet
  // plan export loop below.
  final drawingList = <DrawingListEntry>[];
  for (final s in sheetsFm.sheets) {
    final fIdx = sheetsFm.floorFor(s.id, project.building.levelCount);
    final planChromeFm = issuableChrome(ref, sheetId: s.id, floorIndex: fIdx);
    drawingList.add(DrawingListEntry(
      number: planChromeFm.drawingNumber ?? '',
      title: 'PLAN - ${s.name}',
      revision: rev,
      date: today,
    ));
  }
  drawingList.add(DrawingListEntry(
    number: sheetDrawingNumber(
        base: doc.documentNumber, series: DrawingSeries.mechanicalRiser),
    title: 'DIAGRAM RISER MEKANIKAL / MECHANICAL RISER SLD',
    revision: rev,
    date: today,
  ));
  if (eResultFm.order.isNotEmpty) {
    drawingList.add(DrawingListEntry(
      number: sheetDrawingNumber(
          base: doc.documentNumber, series: DrawingSeries.electricalDetail),
      title: 'DIAGRAM PANEL / ELECTRICAL SLD',
      revision: rev,
      date: today,
    ));
  }

  // Cable families the electrical set actually specifies; fall back to the
  // conventional NYY/NYM defaults only when panels exist but none are typed.
  final specifiedCables = <String>{
    for (final p in eProjectFm.panels)
      for (final c in p.circuits)
        if (c.cableType != null && c.cableType!.trim().isNotEmpty) c.cableType!,
  };
  final frontMatter = buildSubmittalFrontMatter(
    projectName: base,
    drawings: drawingList,
    clientName: doc.clientName,
    coverDrawingNumber: doc.documentNumber,
    revision: doc.revisionTag,
    date: today,
    preparedBy: doc.preparedBy,
    services: {for (final e in netFm.edges) e.service},
    components: {
      for (final n in netFm.nodes)
        if (n.component != null) n.component!,
    },
    cableFamilies: specifiedCables.isNotEmpty
        ? specifiedCables
        : (eResultFm.order.isNotEmpty
            ? const <String>{'NYY', 'NYM'}
            : const <String>{}),
  );
  await File(out('00-cover-sheets.pdf')).writeAsBytes(sldSheetsToPdf(
    frontMatter,
    title: 'iSystem MEP submittal',
    diagramTitles: kFrontMatterDiagramTitles,
    // No per-set DWG NO on the shared block (each front-matter sheet is a
    // distinct page — the cover carries the project number in its own register).
    chrome: DrawingChrome(
      revisionNumber: doc.revisionTag,
      clientName: doc.clientName,
      drawnBy: doc.preparedBy,
      checkedBy: doc.checkedBy,
      approvedBy: doc.approvedBy,
      dateString: today,
    ),
    projectName: base,
  ));

  // ── Reports ───────────────────────────────────────────────────────────────
  final mech = buildMechanicalReportData(ref);
  final electrical = buildElectricalReportData(ref);
  final compliance = buildComplianceSummary(ref);

  await File(out('report.md'))
      .writeAsString(buildCalcReportMarkdown(mech, strings));
  await File(out('report.pdf')).writeAsBytes(reportBlocksToPdf(
    [
      ...buildCalcReportBlocks(mech, strings),
      RptFigure(buildLiveRiserSheet(ref, null),
          caption: 'Mechanical riser single-line diagram'),
    ],
    docTitle: 'MEP Calculation Report',
    projectName: base,
    documentNumber: doc.documentNumber,
    revisionTag: doc.revisionTag,
    dateString: mech.date,
    standardsLine: '${mech.standardsName} (${mech.standardsRevision})',
    preparedBy: doc.preparedBy,
    checkedBy: doc.checkedBy,
    approvedBy: doc.approvedBy,
  ));

  await File(out('mep-report.md')).writeAsString(buildMepUnifiedReport(
    mechanical: mech,
    electrical: electrical,
    compliance: compliance,
    strings: strings,
  ));
  await File(out('mep-report.pdf')).writeAsBytes(reportBlocksToPdf(
    [
      ...buildMepUnifiedReportBlocks(
        mechanical: mech,
        electrical: electrical,
        compliance: compliance,
        strings: strings,
      ),
      const RptHeading(1, 'Drawings'),
      RptFigure(buildLiveRiserSheet(ref, null),
          caption: 'Mechanical riser single-line diagram'),
      RptFigure(
        buildElectricalSld(
          project: ref.read(electricalProjectProvider),
          result: ref.read(electricalResultProvider),
          breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
        ),
        caption: 'Electrical single-line diagram',
      ),
    ],
    docTitle: 'MEP Building-Services Report',
    projectName: base,
    documentNumber: doc.documentNumber,
    revisionTag: doc.revisionTag,
    dateString: mech.date,
    standardsLine: '${mech.standardsName} (${mech.standardsRevision})'
        ' / ${electrical.standardsName} ${electrical.standardsRevision}',
    preparedBy: doc.preparedBy,
    checkedBy: doc.checkedBy,
    approvedBy: doc.approvedBy,
  ));

  // ── Equipment schedule (MD + CSV + PDF) ─────────────────────────────────────
  final sched = gatherEquipmentScheduleData(ref);
  await File(out('equipment-schedule.md'))
      .writeAsString(buildEquipmentScheduleMarkdown(sched, strings));
  await File(out('equipment-schedule.csv'))
      .writeAsString(equipmentScheduleToCsv(buildEquipmentScheduleRows(sched)));
  await File(out('equipment-schedule.pdf')).writeAsBytes(reportBlocksToPdf(
    buildEquipmentScheduleBlocks(sched, strings),
    docTitle: 'Equipment Schedule',
    projectName: base,
    documentNumber: doc.documentNumber,
    revisionTag: doc.revisionTag,
    dateString: sched.date,
    preparedBy: doc.preparedBy,
    checkedBy: doc.checkedBy,
    approvedBy: doc.approvedBy,
  ));

  // ── BOM (CSV) + costed quotation (MD) — the unified M+E+P pipeline ───────────
  final mechCost = ref.read(mechanicalCostProvider);
  final elecCost = ref.read(electricalCostProvider);
  await File(out('bom.csv')).writeAsString(mepBomToCsv(mechCost, elecCost));
  await File(out('quotation.md')).writeAsString(mepQuotationToMarkdown(
    ref.read(mepQuotationProvider),
    mechanical: mechCost,
    electrical: elecCost,
    projectName: base,
  ));

  // ── Mechanical riser single-line (PDF) ──────────────────────────────────────
  await File(out('riser-sld.pdf')).writeAsBytes(sldSheetToPdf(
    sheet: buildLiveRiserSheet(ref, null),
    title: 'iSystem mechanical single-line',
    diagramTitle: 'MECHANICAL SINGLE-LINE DIAGRAM',
    chrome: sldChrome(DrawingSeries.mechanicalRiser),
  ));

  // ── Every sheet's annotated plan (PDF + DXF) — J2: the whole rail, not just
  // whichever sheet happened to be active, so a multi-floor tender folder is
  // complete without manually switching sheets and re-exporting by hand. Each
  // sheet keeps its own drawing number (N19, by rail position) and filename.
  // Progress rides the shared busy pill; cleared in `finally` so a thrown
  // mid-loop error (a bad underlay, a disk error) never leaves it stuck.
  final planSheets = sheetsFm.sheets;
  final localeStrings = MechXStringsData(ref.read(localeProvider));
  try {
    for (var i = 0; i < planSheets.length; i++) {
      final sheet = planSheets[i];
      ref.read(busyProvider.notifier).set(localeStrings.format(
        StringKey.busyExportingSubmittal,
        {'current': '${i + 1}', 'total': '${planSheets.length}'},
      ));
      final levelCount = project.building.levelCount;
      final floorIndex = sheetsFm.floorFor(sheet.id, levelCount);
      final net = ref.read(networkControllerProvider).network;
      final sizing = ref.read(sizingProvider);
      final planChrome =
          issuableChrome(ref, sheetId: sheet.id, floorIndex: floorIndex);
      final metersPerPixel = project.calibrationFor(sheet.id)?.metersPerPixel;
      final underlay = await buildPlanUnderlay(sheet);
      final edgeLengths = <String, Length>{
        for (final e in net.edges)
          e.id: edgeLength(
            e,
            net,
            calibrationBySheet: project.calibrations,
            building: project.building,
          ),
      };
      // N5: the §10 centreline-height token folded into each run's size label.
      final elevationLabels = planEdgeElevationLabels(net, project.building);
      // N13: the stable element tags shared by both plan formats + the reports.
      final tags = elementTags(net);
      // N4/B12: the setting-out grid from axis-aligned traced reference lines,
      // shared by both plan formats.
      final grid =
          buildReferenceGrid(ref.read(referenceLinesProvider), sheet.id);
      // G1/G5: the equipment tags + gravity fall, shared by both plan formats
      // (the same tokens the on-canvas plan shows).
      final nodeTags = equipmentNodeTags(net);
      final gravitySlope = const SizingContext().drainageSlope;
      // One file per sheet, numbered by rail position so a multi-floor bundle
      // never collides (`project-plan-1-Ground Floor.pdf`, `-2-Level 1.pdf`…).
      final suffix = 'plan-${i + 1}-${sheet.name}';
      await File(out('$suffix.pdf')).writeAsBytes(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: edgeLengths,
        sheetId: sheet.id,
        floorIndex: floorIndex,
        projectName: base,
        sheetName: sheet.name,
        dateString: today,
        chrome: planChrome,
        metersPerPixel: metersPerPixel,
        underlay: underlay,
        edgeElevationLabels: elevationLabels,
        edgeTags: tags,
        grid: grid,
        nodeTags: nodeTags,
        gravitySlope: gravitySlope,
      ));
      await File(out('$suffix.dxf')).writeAsString(networkToDxf(
        net: net,
        sizing: sizing,
        sheetId: sheet.id,
        floorIndex: floorIndex,
        chrome: planChrome,
        metersPerPixel: metersPerPixel,
        underlay: underlay is VectorPlanUnderlay ? underlay : null,
        edgeElevationLabels: elevationLabels,
        edgeTags: tags,
        grid: grid,
        nodeTags: nodeTags,
        gravitySlope: gravitySlope,
      ));
      // H1: the electrical installation layout (denah instalasi listrik) for
      // this same sheet+floor — panels/loads at their placed positions + feeder
      // routes over the same underlay — so the tender folder carries the
      // electrical denah beside each mechanical plan. Written only when the
      // sheet actually has placed electrical items (else no file, honestly).
      final ePlan = buildElectricalPlanData(
        project: ref.read(electricalProjectProvider),
        result: ref.read(electricalResultProvider),
        sheetId: sheet.id,
        floorIndex: floorIndex,
        calibrations: project.calibrations,
        building: project.building,
      );
      if (!ePlan.isEmpty) {
        final eChrome = sldChrome(DrawingSeries.electricalLayout);
        await File(out('elec-$suffix.pdf')).writeAsBytes(electricalPlanToPdf(
          data: ePlan,
          projectName: base,
          sheetName: sheet.name,
          dateString: today,
          chrome: eChrome,
          metersPerPixel: metersPerPixel,
          underlay: underlay,
        ));
        await File(out('elec-$suffix.dxf')).writeAsString(electricalPlanToDxf(
          data: ePlan,
          projectName: base,
          sheetName: sheet.name,
          chrome: eChrome,
        ));
      }
    }
  } finally {
    ref.read(busyProvider.notifier).clear();
  }

  // ── Electrical single-line (PDF), when the project has sized panels ──────────
  final eResult = ref.read(electricalResultProvider);
  if (eResult.order.isNotEmpty) {
    final eProject = ref.read(electricalProjectProvider);
    await File(out('electrical-sld.pdf')).writeAsBytes(electricalSldToPdf(
      project: eProject,
      sheet: buildElectricalSld(
        project: eProject,
        result: eResult,
        breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
      ),
      chrome: sldChrome(DrawingSeries.electricalDetail),
    ));
  }

  return true;
}

/// H5 — the document-control identity surfaced AT the export moment. A compact
/// inline card of the three title-block fields most reviewers bounce a drawing
/// over (drawing/document number, revision, client), bound live to
/// [documentControlProvider] so the engineer confirms/edits them right before
/// exporting instead of hunting the Layout inspector's collapsed section. The
/// full DRAWN/CHECKED/APPROVED + revision-history controls stay in that section;
/// this is the pre-flight surface. Additive: an unset field prints no title-block
/// chrome, so leaving it blank is byte-identical to before.
class ExportIdentityBar extends ConsumerWidget {
  const ExportIdentityBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final doc = ref.watch(documentControlProvider);
    final ctrl = ref.read(documentControlProvider.notifier);

    Widget field(
      String label,
      String? value,
      ValueChanged<String> onSet,
      String hint,
    ) =>
        SizedBox(
          width: 176,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: type.caption.copyWith(color: colors.textMuted)),
              const SizedBox(height: MechXSpacing.xxs),
              MechXTextField(
                value: value ?? '',
                hint: hint,
                onCommitted: onSet,
              ),
            ],
          ),
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MechXSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Document control',
              style: type.subtitle.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.xxs),
          Text(
            'Stamped on every exported drawing + report title block. Confirm it '
            'before you export; the full DRAWN/CHECKED/APPROVED + revision block '
            'lives in the Layout inspector.',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.sm),
          Wrap(
            spacing: MechXSpacing.md,
            runSpacing: MechXSpacing.sm,
            children: [
              field('Drawing no.', doc.documentNumber, ctrl.setDocumentNumber,
                  'e.g. M-101'),
              field('Revision', doc.revisionTag, ctrl.setRevisionTag, 'e.g. A'),
              field('Client', doc.clientName, ctrl.setClientName,
                  'Client name'),
            ],
          ),
        ],
      ),
    );
  }
}

/// All services offered in the draw palette / edge editor, in a sensible order.
const List<ServiceType> kDrawServices = [
  ServiceType.coldWater,
  ServiceType.hotWater,
  ServiceType.drainage,
  ServiceType.vent,
  ServiceType.rainwater,
  ServiceType.duct,
  ServiceType.returnAir,
  ServiceType.exhaust,
  ServiceType.fireSprinkler,
  ServiceType.fireHydrant,
];

/// Right inspector: project details, per-floor heights (the vertical
/// length source of truth, §10), and the per-sheet scale-calibration status.
class ProjectPanel extends ConsumerStatefulWidget {
  const ProjectPanel({super.key});

  static const double width = 272;

  @override
  ConsumerState<ProjectPanel> createState() => _ProjectPanelState();
}

class _ProjectPanelState extends ConsumerState<ProjectPanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final building = ref.watch(projectControllerProvider).building;

    // Context before document (the Keynote inspector rule): the selection
    // editor is pinned FIRST, and picking something on canvas snaps the panel
    // to the top so the pick is immediately visible — the panel otherwise
    // gives no cue that anything changed.
    //
    // C2: this used to guard on prev being EMPTY, so only the very first
    // empty→non-empty pick ever jumped — clicking through several elements in
    // sequence while the panel is scrolled to Results/Fire/HVAC left the
    // Selection editor silently updating out of view. Jump on any CHANGE of
    // selection identity (a different node/edge, not just a rebuild of the
    // same one), guarded to only actually move the scroll offset when the
    // panel is scrolled away from the top (an already-at-top panel has
    // nothing to jump).
    ref.listen(selectionProvider, (prev, next) {
      if (!_scroll.hasClients || next.isEmpty) return;
      final changed =
          prev == null || prev.nodeId != next.nodeId || prev.edgeId != next.edgeId;
      if (changed && _scroll.offset > 0) {
        _scroll.jumpTo(0);
      }
    });

    return SizedBox(
      width: ProjectPanel.width,
      // Transparent: the inspector floats on a Liquid-Glass surface
      // (CollapsibleInspector) so the canvas refracts through behind it.
      child: MechXScrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(MechXSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Selection (only shown when something is selected) ─────────
              const _SelectionSection(),

              // ── Building (summary → its own page) ─────────────────────────
              // The full floor/level editor (+ per-floor fixture heights) now
              // lives on the dedicated Building page so the inspector stays
              // canvas-focused; this is a read-only summary that opens it.
              MechXSectionLabel(context.strings(StringKey.inspectorBuilding)),
              const SizedBox(height: MechXSpacing.sm),
              _BuildingSummary(
                summary: '${building.totalHeight.meters.toStringAsFixed(1)} m · '
                    '${building.levelCount} levels',
                onOpen: () => ref
                    .read(shellSectionProvider.notifier)
                    .set(ShellSection.building),
              ),
              const SizedBox(height: MechXSpacing.lg),

              // ── Scale (E10) ───────────────────────────────────────────────
              // Setup lives under Building, above the draw→size→report flow —
              // calibration is the gating step the banner demands, so it sits
              // near the top (was buried dead-last, below Document control) and
              // is collapsible with a calibration-aware default. (Sheet→floor
              // mapping is NOT here: it lives on the sheet itself — the rail
              // tile's `F#` stamp + its right-click "Assign floor…" — and on the
              // Building page, so a third control here was redundant.)
              _scaleSection(context),

              // ── Draw ──────────────────────────────────────────────────────
              const _DrawSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── Tanks (only shown when the sheet has designated areas) ─────
              const _TanksSection(),

              // ── Rooms (only shown when the sheet has designated rooms) ─────
              const _RoomsSection(),

              // ── Network results ───────────────────────────────────────────
              // (Occupancy / rainfall / runoff design INPUTS moved to the
              // Building setup page; the Show/Hide-sizes canvas toggle lives
              // atop Results now.)
              const _ResultsSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── Fire protection ───────────────────────────────────────────
              const _FireSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── HVAC / ducting ────────────────────────────────────────────
              const _HvacSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── Document control (issuable-sheet identity, D3) ────────────
              const _DocumentControlSection(),
              const SizedBox(height: MechXSpacing.lg),

              // ── Equipment schedule model/spec (N23; only shown once there's
              // at least one tagged pump/fan/AHU to fill in a spec for) ─────
              const _EquipmentModelSpecSection(),
            ],
          ),
        ),
      ),
    );
  }

  /// The Scale calibration section (E10). Moved up under Building and wrapped in
  /// a [DisclosureSection] whose default is calibration-aware: EXPANDED while the
  /// sheet is uncalibrated (the gating step demands attention), collapsing once
  /// a scale is set so it stops competing with the draw flow (a user's explicit
  /// toggle still wins over the default). J1: also stays expanded while the
  /// sheet's calibration is STALE (its plan was just replaced) — the Design
  /// Issue's locate jump lands here needing the same attention as "not
  /// calibrated".
  Widget _scaleSection(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final currentSheet = ref.watch(sheetsControllerProvider).current;
    final project = ref.watch(projectControllerProvider);
    final calibration =
        currentSheet == null ? null : project.calibrationFor(currentSheet.id);
    final stale =
        currentSheet != null && project.isCalibrationStale(currentSheet.id);
    // Bound once so the stale-row widgets below don't re-derive nullability
    // from [currentSheet] (avoids relying on the analyzer's boolean-guard
    // promotion of an unrelated local).
    final staleSheetId = stale ? currentSheet.id : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.lg),
      child: DisclosureSection(
        name: 'Scale',
        defaultExpanded: calibration == null || stale,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(MechXSpacing.sm),
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: MechXRadii.control,
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: MechXSpacing.sm),
                    decoration: BoxDecoration(
                      color: calibration == null || stale
                          ? colors.warning
                          : colors.success,
                      borderRadius: const BorderRadius.all(Radius.circular(4)),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      calibration == null
                          ? 'Not calibrated'
                          // One shared human readout (D1): PDF sheets lead with
                          // the plotted `1 : N`, else `1 m = N px`.
                          : formatScaleReadout(calibration.metersPerPixel,
                              isPdf: currentSheet?.pdfPath != null),
                      style:
                          type.caption.copyWith(color: colors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            // J1: a calibration that SURVIVED a plan-source swap needs
            // re-verification — a distinct warning row + an explicit
            // "Scale confirmed" action that clears the flag WITHOUT touching
            // the scale itself (the engineer checked and it still holds).
            if (staleSheetId != null) ...[
              const SizedBox(height: MechXSpacing.sm),
              Container(
                padding: const EdgeInsets.all(MechXSpacing.sm),
                decoration: BoxDecoration(
                  color: colors.warning.withAlpha(24),
                  borderRadius: MechXRadii.control,
                  border: Border.all(color: colors.warning),
                ),
                child: Text(
                  context.strings(StringKey.issueCalibrationStaleTitle),
                  style: type.caption.copyWith(color: colors.warning),
                ),
              ),
              const SizedBox(height: MechXSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: MechXButton(
                  label: context.strings(StringKey.inspectorScaleConfirmed),
                  onPressed: () => ref
                      .read(projectControllerProvider.notifier)
                      .confirmCalibration(staleSheetId),
                ),
              ),
            ],
            if (currentSheet != null) ...[
              const SizedBox(height: MechXSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: MechXButton(
                  label:
                      calibration == null ? 'Calibrate scale' : 'Re-calibrate',
                  onPressed: () =>
                      ref.read(calibrationControllerProvider.notifier).start(),
                ),
              ),
              // Second scale path (D1): type the drawing's STATED plot scale
              // (1 : N). A plotted PDF's pixels are points at 72/inch, so
              // `metersPerPixel = N × 0.0254 / 72` — exact, no measuring. Only
              // meaningful for PDF sheets; a normalized DXF/DWG pixel has no
              // paper-unit basis, so those keep the two-point measure only.
              if (currentSheet.pdfPath != null) ...[
                const SizedBox(height: MechXSpacing.sm),
                _PdfScaleTypeIn(
                  sheetId: currentSheet.id,
                  calibration: calibration,
                ),
              ],
              // QoL: once this sheet is calibrated, stamp its scale onto other
              // sheets in one undo step (typical floors share a scale) —
              // defaulting to UNCALIBRATED sheets only, confirming before it
              // would overwrite a sheet's own DIFFERENT scale, and reporting the
              // count (D2).
              if (calibration != null) ...[
                const SizedBox(height: MechXSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: MechXButton(
                    label: 'Apply scale to all sheets',
                    onPressed: () =>
                        _applyScaleToAllSheets(context, ref, currentSheet.id),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// The engineer's choice when "Apply scale to all sheets" would overwrite sheets
/// that already carry their own DIFFERENT scale (D2).
enum _ScaleApplyChoice { overwriteAll, keepSeparate, cancel }

/// Apply [fromSheetId]'s scale to the other sheets (D2). Safe by default —
/// stamps UNCALIBRATED sheets only; if some sheets carry their OWN different
/// scale it asks before overwriting them; always finishes with a status pill
/// reporting the count.
Future<void> _applyScaleToAllSheets(
    BuildContext context, WidgetRef ref, String fromSheetId) async {
  final proj = ref.read(projectControllerProvider);
  final allIds =
      ref.read(sheetsControllerProvider).sheets.map((s) => s.id).toSet();
  final uncalibrated = proj.uncalibratedAmong(allIds, exclude: fromSheetId);
  final different = proj.differentlyCalibratedFrom(fromSheetId, allIds);

  var targets = uncalibrated;
  if (different.isNotEmpty) {
    final choice = await _confirmScaleApply(context, different.length);
    if (!context.mounted) return;
    switch (choice) {
      case null:
      case _ScaleApplyChoice.cancel:
        return; // abort — do nothing
      case _ScaleApplyChoice.keepSeparate:
        targets = uncalibrated; // safe subset only
      case _ScaleApplyChoice.overwriteAll:
        targets = {...uncalibrated, ...different};
    }
  }

  void status(String m) =>
      ref.read(statusMessageProvider.notifier).showStatus(m);
  if (targets.isEmpty) {
    status('All other sheets already use this scale');
    return;
  }
  final n = ref.read(projectControllerProvider.notifier).applyCalibrationToAllSheets(
        fromSheetId,
        toSheetIds: {fromSheetId, ...targets},
      );
  status('Scale applied to $n ${n == 1 ? 'sheet' : 'sheets'}');
}

/// Ask before overwriting [count] sheets that carry their own different scale
/// (D2). A themed [showGeneralDialog] card (no Material) — dismiss / Esc resolves
/// to null (treated as cancel).
Future<_ScaleApplyChoice?> _confirmScaleApply(BuildContext context, int count) {
  final theme = MechXTheme.of(context);
  final noun = count == 1 ? 'sheet has' : 'sheets have';
  return showGeneralDialog<_ScaleApplyChoice>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Apply scale',
    barrierColor: theme.colors.scrim,
    // C1: the fade/scale entrance collapses to zero under OS reduced motion.
    transitionDuration: MechXMotion.resolve(context, MechXMotion.appear),
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: Center(
        child: Builder(builder: (ctx) {
          final colors = ctx.colors;
          final type = ctx.type;
          void pop(_ScaleApplyChoice c) => Navigator.of(ctx).pop(c);
          return Container(
            width: 420,
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
                Text('Overwrite different scales?',
                    style: type.title.copyWith(color: colors.textPrimary)),
                const SizedBox(height: MechXSpacing.xs),
                Text(
                  '$count $noun their own scale. Overwrite them with this '
                  'sheet\'s scale, or apply only to the uncalibrated sheets?',
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
                const SizedBox(height: MechXSpacing.md),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: MechXSpacing.sm,
                  runSpacing: MechXSpacing.xs,
                  children: [
                    MechXButton(
                      label: 'Cancel',
                      tertiary: true,
                      onPressed: () => pop(_ScaleApplyChoice.cancel),
                    ),
                    MechXButton(
                      label: 'Uncalibrated only',
                      onPressed: () => pop(_ScaleApplyChoice.keepSeparate),
                    ),
                    MechXButton(
                      label: 'Overwrite all',
                      primary: true,
                      onPressed: () => pop(_ScaleApplyChoice.overwriteAll),
                    ),
                  ],
                ),
              ],
            ),
          );
        }),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: MechXMotion.standard);
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

/// The `1 : N` drawing-scale type-in (D1) — the second calibration path beside
/// the two-point measure, for PDF sheets (whose pixels are points at 72/inch).
/// Type the drawing's stated plot scale, or tap a common preset; commits via
/// [ProjectController.setCalibration] and reports the resolved scale.
class _PdfScaleTypeIn extends ConsumerStatefulWidget {
  final String sheetId;
  final ScaleCalibration? calibration;
  const _PdfScaleTypeIn({required this.sheetId, required this.calibration});

  @override
  ConsumerState<_PdfScaleTypeIn> createState() => _PdfScaleTypeInState();
}

class _PdfScaleTypeInState extends ConsumerState<_PdfScaleTypeIn> {
  late String _text = _seed();

  String _seed() {
    final cal = widget.calibration;
    if (cal == null) return '';
    return pdfScaleDenominatorFor(cal.metersPerPixel).round().toString();
  }

  void _apply() {
    final n = double.tryParse(_text.trim());
    if (n == null || n <= 0) return;
    final mpp = metersPerPixelForPdfScale(n);
    ref
        .read(projectControllerProvider.notifier)
        .setCalibration(widget.sheetId, ScaleCalibration(mpp));
    ref.read(statusMessageProvider.notifier).showStatus(
        'Scale set: ${formatScaleReadout(mpp, isPdf: true)}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Or type the drawing scale',
            style: type.caption.copyWith(color: colors.textMuted)),
        const SizedBox(height: MechXSpacing.xs),
        Row(
          children: [
            Text('1 :', style: type.body.copyWith(color: colors.textSecondary)),
            const SizedBox(width: MechXSpacing.xs),
            SizedBox(
              width: 88,
              child: MechXTextField(
                value: _text,
                hint: '100',
                textStyle: type.mono,
                keyboardType: const TextInputType.numberWithOptions(),
                onChanged: (v) => setState(() => _text = v),
                onSubmitted: _apply,
              ),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(label: 'Set scale', onPressed: _apply),
          ],
        ),
        const SizedBox(height: MechXSpacing.xs),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            for (final d in kCommonPdfScaleDenominators)
              _Pill(
                label: '1:$d',
                selected: _text.trim() == '$d',
                onTap: () {
                  setState(() => _text = '$d');
                  _apply();
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// The compact building summary shown in the inspector: a one-line "11.0 m · 3
/// levels" readout in a tappable card that opens the dedicated Building page
/// (where floors are edited). Keeps the inspector canvas-focused.
class _BuildingSummary extends StatefulWidget {
  final String summary;
  final VoidCallback onOpen;
  const _BuildingSummary({required this.summary, required this.onOpen});

  @override
  State<_BuildingSummary> createState() => _BuildingSummaryState();
}

class _BuildingSummaryState extends State<_BuildingSummary> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MechXFocusRing(
      borderRadius: MechXRadii.control,
      onActivated: widget.onOpen,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onOpen,
          child: AnimatedContainer(
            // C1: hover motion collapses to zero under OS reduced motion.
            duration: MechXMotion.resolve(context, MechXMotion.hover),
            curve: MechXMotion.standard,
            padding: const EdgeInsets.all(MechXSpacing.sm),
            decoration: BoxDecoration(
              color: _hover ? colors.surfaceHover : colors.background,
              borderRadius: MechXRadii.control,
              border: Border.all(color: _hover ? colors.textMuted : colors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // L2: '11.0 m · 3 levels' updates in place with edits.
                      style: MechXTypography.tabular(
                          type.body.copyWith(color: colors.textSecondary))),
                ),
                const SizedBox(width: MechXSpacing.xs),
                Text('Edit',
                    style: type.caption.copyWith(color: colors.accent)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlyphButton extends StatefulWidget {
  final String glyph;
  final VoidCallback? onTap;
  const _GlyphButton({required this.glyph, required this.onTap});

  @override
  State<_GlyphButton> createState() => _GlyphButtonState();
}

class _GlyphButtonState extends State<_GlyphButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = widget.onTap != null;
    final fg = !enabled
        ? colors.textMuted.withAlpha(90)
        : (_hover ? colors.textPrimary : colors.textSecondary);
    final glyph = AnimatedScale(
      scale: _down && enabled ? 0.9 : 1.0,
      // C1: press/hover motion collapses to zero under OS reduced motion.
      duration: MechXMotion.resolve(context, MechXMotion.press),
      curve: MechXMotion.standard,
      child: AnimatedContainer(
        duration: MechXMotion.resolve(context, MechXMotion.hover),
        curve: MechXMotion.standard,
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              _hover && enabled ? colors.surfaceHover : const Color(0x00000000),
          borderRadius: MechXRadii.control,
        ),
        child: Text(
          widget.glyph,
          style:
              TextStyle(fontFamily: 'Roboto', fontSize: 16, height: 1.0, color: fg),
        ),
      ),
    );
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: MechXFocusRing(
        enabled: enabled,
        onActivated: widget.onTap,
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          child: glyph,
        ),
      ),
    );
  }
}

/// Document control — the issuable-sheet identity (D3): document/drawing
/// number, revision tag, client, and the DRAWN/CHECKED/APPROVED names, plus a
/// minimal revision-history editor. All fields commit straight into
/// [documentControlProvider] (persisted with the project), from where they feed
/// every report head ([buildMechanicalReportData]) and PDF/DXF title block
/// ([issuableChrome], the riser/electrical export chromes). Collapsed by
/// default so a blank launch stays canvas-focused.
class _DocumentControlSection extends ConsumerStatefulWidget {
  const _DocumentControlSection();

  @override
  ConsumerState<_DocumentControlSection> createState() =>
      _DocumentControlSectionState();
}

class _DocumentControlSectionState
    extends ConsumerState<_DocumentControlSection> {
  // The pending add-revision row. The epoch keys the row's text fields so a
  // successful Add remounts them EMPTY — an EditableText keeps its own text
  // while focused, so clearing the state alone would not clear the field.
  String _revDate = '';
  String _revDesc = '';
  int _addEpoch = 0;

  void _addRevision() {
    final date = _revDate.trim();
    final desc = _revDesc.trim();
    if (date.isEmpty && desc.isEmpty) return;
    ref.read(documentControlProvider.notifier).addRevision(date, desc);
    setState(() {
      _revDate = '';
      _revDesc = '';
      _addEpoch++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final doc = ref.watch(documentControlProvider);
    final ctrl = ref.read(documentControlProvider.notifier);

    // A labelled single-line field. The store setter normalizes (trims; an
    // emptied field clears back to null), so committing on every change is
    // safe — the same idiom as the project-name field on the Projects page.
    Widget field(
      StringKey label,
      String? value,
      ValueChanged<String> onChanged,
    ) =>
        Padding(
          padding: const EdgeInsets.only(bottom: MechXSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.strings(label),
                  style: type.caption.copyWith(color: colors.textMuted)),
              const SizedBox(height: MechXSpacing.xs),
              MechXTextField(value: value ?? '', onChanged: onChanged),
            ],
          ),
        );

    return DisclosureSection(
      name: 'Document control',
      defaultExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field(StringKey.inspectorDocNumber, doc.documentNumber,
              ctrl.setDocumentNumber),
          field(StringKey.inspectorRevisionTag, doc.revisionTag,
              ctrl.setRevisionTag),
          field(StringKey.inspectorClient, doc.clientName, ctrl.setClientName),
          field(StringKey.inspectorPreparedBy, doc.preparedBy,
              ctrl.setPreparedBy),
          field(StringKey.inspectorCheckedBy, doc.checkedBy, ctrl.setCheckedBy),
          field(StringKey.inspectorApprovedBy, doc.approvedBy,
              ctrl.setApprovedBy),

          // ── Revision history (date + description rows) ───────────────────
          Text(context.strings(StringKey.inspectorRevisionHistory),
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          for (var i = 0; i < doc.revisions.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${doc.revisions[i].date} · ${doc.revisions[i].description}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          type.caption.copyWith(color: colors.textSecondary),
                    ),
                  ),
                  _GlyphButton(
                    glyph: '−',
                    onTap: () => ctrl.removeRevisionAt(i),
                  ),
                ],
              ),
            ),
          Row(
            key: ValueKey('doc-rev-add-$_addEpoch'),
            children: [
              SizedBox(
                width: 92,
                child: MechXTextField(
                  value: '',
                  hint: context.strings(StringKey.inspectorRevisionDateHint),
                  onChanged: (v) => _revDate = v,
                ),
              ),
              const SizedBox(width: MechXSpacing.xs),
              Expanded(
                child: MechXTextField(
                  value: '',
                  hint: context.strings(StringKey.inspectorRevisionDescHint),
                  onChanged: (v) => _revDesc = v,
                ),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: MechXButton(
              label: context.strings(StringKey.inspectorAddRevision),
              onPressed: _addRevision,
            ),
          ),
        ],
      ),
    );
  }
}

/// N23 — the compact "Model / spec" editor for the equipment schedule: one
/// row per tagged pump / fan / AHU-FCU-AC (the same tags
/// `gatherEquipmentScheduleData` assigns), each with a free-text field
/// committing straight into [equipmentModelSpecProvider] (persisted with the
/// project). Threaded into every equipment-schedule export (Markdown / CSV /
/// PDF) by tag, so a spec entered here is what procurement sees. Renders
/// nothing when there is no tagged equipment yet — an empty/blank project is
/// byte-identical to before this feature.
class _EquipmentModelSpecSection extends ConsumerWidget {
  const _EquipmentModelSpecSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // [_equipmentSpecTargets] (like the export gather it shares) reads rather
    // than watches, so explicitly watch every provider its tag/service
    // derivation depends on — this section then shows/hides and its rows stay
    // live as the pump/fan/room duties change, matching how `_ResultsSection`
    // / `_RoomsSection` watch the same state.
    ref.watch(projectControllerProvider);
    ref.watch(pumpDutyProvider);
    ref.watch(standpipeDesignProvider);
    ref.watch(ductFanProvider);
    ref.watch(ductSettingsProvider);
    ref.watch(roomAreasProvider);
    // N23 residual: the electrical panels + source apparatus are edit targets
    // too, so react to their live state (a panel added / a source configured).
    ref.watch(electricalResultProvider);
    ref.watch(electricalProjectProvider);
    final specs = ref.watch(equipmentModelSpecProvider);
    // Gate visibility on mechanical equipment so seeding an electrical project's
    // panels alone never surfaces this mechanical-inspector section (goldens).
    if (!_hasMechanicalEquipmentTargets(ref)) return const SizedBox.shrink();
    final targets = _equipmentSpecTargets(ref);
    if (targets.isEmpty) return const SizedBox.shrink();

    final colors = context.colors;
    final type = context.type;
    final ctrl = ref.read(equipmentModelSpecProvider.notifier);

    return DisclosureSection(
      name: context.strings(StringKey.inspectorEquipmentSchedule),
      defaultExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.strings(StringKey.inspectorEquipmentScheduleHint),
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.sm),
          for (final t in targets)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${t.tag} · ${t.service}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.caption.copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(height: MechXSpacing.xxs),
                  MechXTextField(
                    value: specs[t.tag] ?? '',
                    hint: context.strings(StringKey.inspectorModelSpecHint),
                    onCommitted: (v) => ctrl.setSpec(t.tag, v),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DrawSection extends ConsumerWidget {
  const _DrawSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final drawing = ref.watch(networkControllerProvider);
    final ctrl = ref.read(networkControllerProvider.notifier);
    final ortho = ref.watch(orthoProvider);

    // On the unified Layout canvas, scope the drawable services to the ACTIVE
    // discipline layer (plumbing services when Plumbing is active, air services
    // when HVAC). On the Schematic view there is no layer concept, so the full
    // list is offered (unchanged). Electrical isn't a `ServiceType`, so it too
    // falls back to the full list (the electrical palette is shown elsewhere).
    final onLayout = ref.watch(workspaceViewProvider) == WorkspaceView.plan;
    final active = ref.watch(activeDisciplineProvider);
    final scoped = (onLayout && active.isMechanical)
        ? servicesFor(active)
        : kDrawServices;
    // If the active service isn't in scope, switch to the first scoped one so a
    // hidden service is never silently the draw target.
    if (scoped.isNotEmpty && !scoped.contains(drawing.service)) {
      final next = scoped.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(networkControllerProvider).service != next) {
          ctrl.setService(next);
        }
      });
    }

    final measureMode = ref.watch(measureModeProvider);
    final tankMode = ref.watch(tankModeProvider);
    final roomMode = ref.watch(roomModeProvider);
    final refLineMode = ref.watch(refLineModeProvider);
    // Every peer draw tool shares ONE selected idiom — the tinted
    // selected-segment look (F1) — so the tool group reads consistently and no
    // tool competes with the layer/service accent as a solid-accent fill.
    Widget tool(String label, DrawTool t) => _TintedToggle(
          label: label,
          // While the measure / tank / room / ref-line tool is on, no draw tool
          // reads as active.
          selected: drawing.tool == t &&
              !measureMode &&
              !tankMode &&
              !roomMode &&
              !refLineMode,
          onTap: () {
            ctrl.setTool(t);
            ref.read(measureModeProvider.notifier).set(false);
            ref.read(tankModeProvider.notifier).set(false);
            ref.read(roomModeProvider.notifier).set(false);
            ref.read(refLineModeProvider.notifier).set(false);
          },
        );

    // Duplicating the current floor's runs to the floor above now lives in the
    // command palette ("Duplicate floor up") — a niche power action that no
    // longer crowds the primary draw toolbar.

    // A muted group caption (the Design-inputs section idiom) so the Draw
    // section reads as a few whitespace-separated labelled groups instead of one
    // flat wall of equal-weight rows — the primary Tools group leads (F5).
    Widget groupLabel(String text) =>
        Text(text, style: type.caption.copyWith(color: colors.textMuted));

    // The Select tool is the drawing default, so at rest it would carry a SOLID
    // accent fill and compete with the layer/service accent for "the primary
    // action". Render its SELECTED state as the tinted selected-segment idiom
    // (F1) so a single solid-accent primary remains on the Layout.
    final selectActive = drawing.tool == DrawTool.select &&
        !measureMode &&
        !tankMode &&
        !roomMode &&
        !refLineMode;

    // C3: Draw is the biggest section in the panel (Tools + Service chips +
    // Undo/Redo/Ortho + the full SegmentPalette) and, unlike every other
    // content section, never gated its default on real state — it always
    // opened, burying Sizing/Results/Fire/HVAC below the fold every session.
    // Mirror the Results/Fire gating idiom: a fresh, empty project (nothing
    // drawn yet) needs the palette open by default (the first-run path), but
    // once the network has real runs/risers the drafting toolbar has already
    // done its first job, so default-collapse it and let Sizing/Results rise.
    // The user's own manual expand/collapse (sectionVisibilityProvider) always
    // wins over this default for the session.
    final networkExists =
        drawing.network.nodes.isNotEmpty || drawing.network.edges.isNotEmpty;

    return DisclosureSection(
      name: 'Draw',
      defaultExpanded: !networkExists,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        groupLabel('Tools'),
        const SizedBox(height: MechXSpacing.xs),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            _TintedToggle(
              label: 'Select',
              selected: selectActive,
              onTap: () {
                ctrl.setTool(DrawTool.select);
                ref.read(measureModeProvider.notifier).set(false);
                ref.read(tankModeProvider.notifier).set(false);
                ref.read(roomModeProvider.notifier).set(false);
                ref.read(refLineModeProvider.notifier).set(false);
              },
            ),
            tool('Run', DrawTool.drawRun),
            tool('Riser', DrawTool.drawRiser),
            // Measure is a separate mode (annotation, not a network element);
            // turning it on collapses the draw tool to Select.
            _TintedToggle(
              label: 'Measure',
              selected: measureMode,
              onTap: () {
                final on = !measureMode;
                ref.read(measureModeProvider.notifier).set(on);
                if (on) {
                  ref.read(tankModeProvider.notifier).set(false);
                  ref.read(roomModeProvider.notifier).set(false);
                  ref.read(refLineModeProvider.notifier).set(false);
                  ctrl.setTool(DrawTool.select);
                }
              },
            ),
            // Ref line (B12): a two-click construction line traced along the
            // imported plan (e.g. a shaft wall) that a PDF sheet can then SNAP
            // to — and that seeds the N4 setting-out grid on export. A separate
            // annotation mode, like Measure.
            _TintedToggle(
              label: context.strings(StringKey.inspectorRefLine),
              selected: refLineMode,
              onTap: () {
                final on = !refLineMode;
                ref.read(refLineModeProvider.notifier).set(on);
                if (on) {
                  ref.read(measureModeProvider.notifier).set(false);
                  ref.read(tankModeProvider.notifier).set(false);
                  ref.read(roomModeProvider.notifier).set(false);
                  ctrl.setTool(DrawTool.select);
                }
              },
            ),
            // Tank tool: drag a rectangle on the calibrated plan to designate a
            // tank/reservoir area; its capacity comes from the footprint × depth
            // (edit depth/material in the Tanks inspector below).
            _TintedToggle(
              label: 'Tank',
              selected: tankMode,
              onTap: () {
                final on = !tankMode;
                ref.read(tankModeProvider.notifier).set(on);
                if (on) {
                  ref.read(measureModeProvider.notifier).set(false);
                  ref.read(roomModeProvider.notifier).set(false);
                  ref.read(refLineModeProvider.notifier).set(false);
                  ctrl.setTool(DrawTool.select);
                }
              },
            ),
            // Room tool: drag a rectangle on the calibrated plan to designate a
            // room/zone; its design airflow (CFM) comes from area × ceiling ×
            // target ACH, and the ducts/diffusers/equipment auto-size from it
            // (edit room type / ACH / ceiling / equipment in the Rooms inspector).
            _TintedToggle(
              label: 'Room',
              selected: roomMode,
              onTap: () {
                final on = !roomMode;
                ref.read(roomModeProvider.notifier).set(on);
                if (on) {
                  ref.read(measureModeProvider.notifier).set(false);
                  ref.read(tankModeProvider.notifier).set(false);
                  ref.read(refLineModeProvider.notifier).set(false);
                  ctrl.setTool(DrawTool.select);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.md),
        groupLabel('Service'),
        const SizedBox(height: MechXSpacing.xs),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            for (final s in scoped)
              _ServiceChip(
                service: s,
                selected: drawing.service == s,
                onTap: () => ctrl.setService(s),
              ),
          ],
        ),
        const SizedBox(height: MechXSpacing.md),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            MechXButton(
              label: 'Undo',
              onPressed: ref.read(historyProvider.notifier).undo,
            ),
            MechXButton(
              label: 'Redo',
              onPressed: ref.read(historyProvider.notifier).redo,
            ),
            // Ortho's SELECTED state uses the tinted selected-segment idiom too
            // (F1) — it's a persistent draw toggle, not the screen's primary
            // action, so it must not read as a solid-accent fill.
            _TintedToggle(
              label: 'Ortho',
              selected: ortho,
              onTap: () => ref.read(orthoProvider.notifier).toggle(),
            ),
            // B12: gates ALL plan-underlay snap sources (DXF vector, reference
            // lines, PDF ink) — never the node/grid snap. Default ON.
            _TintedToggle(
              label: context.strings(StringKey.inspectorSnapToPlan),
              selected: ref.watch(snapToPlanProvider),
              onTap: () => ref.read(snapToPlanProvider.notifier).toggle(),
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.lg),
        const SegmentPalette(),
      ],
    ),
    );
  }
}

/// A tool/toggle button whose SELECTED state uses the tinted selected-segment
/// idiom — an `accentMuted` fill + an accent border + an accent label, the same
/// "selected" look the service chips / segmented controls already use — rather
/// than a solid-accent [MechXButton] fill (F1). Unselected, it matches the
/// default gray [MechXButton] at rest (a soft `surfaceHover` fill, no visible
/// border), and a transparent 1-px border keeps the button the exact same size
/// in both states so it never jumps when toggled. Built locally on the shared
/// tokens (the button package is owned elsewhere, so it is not edited).
class _TintedToggle extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TintedToggle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: MechXFocusRing(
        onActivated: onTap,
        borderRadius: MechXRadii.control,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: EdgeInsets.symmetric(
              // Match the default MechXButton padding, compensating the heavier
              // selected border so the toggle never resizes between states.
              horizontal: MechXSpacing.sm + 4 - (selected ? 1 : 0),
              vertical: MechXSpacing.xs + 2 - (selected ? 1 : 0),
            ),
            decoration: BoxDecoration(
              color: selected ? colors.accentMuted : colors.surfaceHover,
              borderRadius: MechXRadii.control,
              border: Border.all(
                color: selected ? colors.accent : const Color(0x00000000),
                width: selected ? 2 : 1,
              ),
            ),
            child: Text(
              label,
              style: type.label.copyWith(
                color: selected ? colors.accent : colors.textPrimary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Which tank / room row is expanded in the inspector's master-detail list. A
// transient, file-local UI state (never persisted to `.mechx`); null ⇒ all rows
// collapsed. Exactly one item is open at a time (H6), so eight tanks/rooms no
// longer stack ~3000 px of always-expanded editors in a 272-px panel.
/// How many BOM lines the Network section lists inline before collapsing the
/// rest into a '+N more' summary (the full breakdown is in the CSV export).
const int _kBomInlineCap = 6;

/// The tappable compact header of a master-detail list item: a rotating chevron,
/// the item title, an optional warning glyph, and a right-aligned headline
/// figure. Tapping toggles the item's editor open (via the owning section's
/// expanded-id provider). Custom-painted chevron/glyph so nothing renders tofu.
class _MasterRow extends StatelessWidget {
  final String title;
  final String headline;
  final bool expanded;
  final bool warning;
  final VoidCallback onTap;

  const _MasterRow({
    required this.title,
    required this.headline,
    required this.expanded,
    required this.onTap,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: MechXFocusRing(
        onActivated: onTap,
        borderRadius: MechXRadii.control,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: [
              AnimatedRotation(
                turns: expanded ? 0.25 : 0.0,
                // C1: collapses to an instant flip under OS reduced motion.
                duration: MechXMotion.resolve(context, MechXMotion.appear),
                curve: MechXMotion.standard,
                child: CustomPaint(
                  size: const Size(12, 12),
                  painter: _MasterChevronPainter(color: colors.textMuted),
                ),
              ),
              const SizedBox(width: MechXSpacing.xs),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // L2: the title carries live dims while a footprint drags.
                    style: MechXTypography.tabular(
                        type.body.copyWith(color: colors.textPrimary))),
              ),
              if (warning) ...[
                const SizedBox(width: MechXSpacing.xs),
                CustomPaint(
                  size: const Size(13, 13),
                  painter: SeverityGlyph(
                      kind: SeverityGlyphKind.warn, color: colors.danger),
                ),
              ],
              const SizedBox(width: MechXSpacing.sm),
              Text(headline,
                  // L2: capacity/CFM recompute live — tabular digits keep the
                  // headline from wobbling sideways.
                  style: MechXTypography.tabular(
                      type.caption.copyWith(color: colors.accent))),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single right-pointing chevron (no glyph font ⇒ never tofu); the caller's
/// [AnimatedRotation] turns it down when the item is expanded.
class _MasterChevronPainter extends CustomPainter {
  final Color color;
  _MasterChevronPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.40, h * 0.24)
      ..lineTo(w * 0.66, h * 0.50)
      ..lineTo(w * 0.40, h * 0.76);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_MasterChevronPainter old) => old.color != color;
}

/// Lists the tank areas designated on the CURRENT sheet as compact master-detail
/// rows — one expanded editor at a time (depth stepper + material + delete).
/// Hidden when there are none, so the at-rest inspector (and goldens) are
/// unchanged.
class _TanksSection extends ConsumerWidget {
  const _TanksSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final sheet = ref.watch(sheetsControllerProvider).current;
    if (sheet == null) return const SizedBox.shrink();
    final tanks = [
      for (final t in ref.watch(tankAreasProvider))
        if (t.sheetId == sheet.id) t,
    ];
    if (tanks.isEmpty) return const SizedBox.shrink();
    final cal = ref.watch(projectControllerProvider).calibrationFor(sheet.id);
    final ctrl = ref.read(tankAreasProvider.notifier);

    String capacity(TankArea t) {
      if (cal == null) return 'set scale';
      final l = t.litres(cal.metersPerPixel);
      return l >= 10000
          ? '${t.volumeM3(cal.metersPerPixel).toStringAsFixed(1)} m3 (${(l / 1000).round()} kL)'
          : '${l.round()} L';
    }

    String dims(TankArea t) {
      if (cal == null) return '';
      final mpp = cal.metersPerPixel;
      return '${(t.widthPx * mpp).toStringAsFixed(1)} x '
          '${(t.heightPx * mpp).toStringAsFixed(1)} m';
    }

    // E6: the open master-detail row is the shared canvas selection — tapping a
    // tank on the plan opens it here (and framing it here highlights the plan).
    final sel = ref.watch(selectedAnnotationProvider);
    final expandedId =
        (sel != null && sel.kind == AnnotationKind.tank) ? sel.id : null;
    final selCtrl = ref.read(selectedAnnotationProvider.notifier);
    return DisclosureSection(
      name: 'Tanks',
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in tanks) ...[
          Container(
            padding: const EdgeInsets.all(MechXSpacing.sm),
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: MechXRadii.control,
              border: Border.all(color: colors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MasterRow(
                  title: '${t.name} · ${dims(t)}',
                  headline: capacity(t),
                  expanded: expandedId == t.id,
                  onTap: () => expandedId == t.id
                      ? selCtrl.clear(t.id)
                      : selCtrl.selectTank(t.id),
                ),
                if (expandedId == t.id) ...[
                  const SizedBox(height: MechXSpacing.sm),
                  // E7: editable name (commit-on-blur/Enter = one undo step).
                  Row(
                    children: [
                      Text('Name',
                          style:
                              type.caption.copyWith(color: colors.textMuted)),
                      const SizedBox(width: MechXSpacing.sm),
                      Expanded(
                        child: MechXTextField(
                          key: ValueKey('tank-name-${t.id}'),
                          value: t.name,
                          hint: 'Tank name',
                          onCommitted: (s) {
                            final name = s.trim();
                            if (name.isNotEmpty) ctrl.setName(t.id, name);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: MechXSpacing.sm),
                  Row(
                    children: [
                      Text('Depth',
                          style:
                              type.caption.copyWith(color: colors.textMuted)),
                      const Spacer(),
                      SteppedValueField(
                        display: '${t.depthM.toStringAsFixed(2)} m',
                        editSeed: t.depthM.toStringAsFixed(2),
                        label: context.strings(StringKey.a11yFieldDepth),
                        gap: 0,
                        valueWidth: 56,
                        valueAlign: TextAlign.center,
                        valueColor: colors.textPrimary,
                        min: 0.1,
                        max: 20,
                        onDecrement: () =>
                            ctrl.setDepth(t.id, t.depthM - 0.25),
                        onIncrement: () =>
                            ctrl.setDepth(t.id, t.depthM + 0.25),
                        onSubmit: (v) {
                          if (v != null) ctrl.setDepth(t.id, v);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: MechXSpacing.xs),
                  Wrap(
                    spacing: MechXSpacing.xs,
                    runSpacing: MechXSpacing.xs,
                    children: [
                      for (final m in TankMaterial.values)
                        _Pill(
                          label: m.label,
                          selected: t.material == m,
                          onTap: () => ctrl.setMaterial(t.id, m),
                        ),
                    ],
                  ),
                  const SizedBox(height: MechXSpacing.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: MechXButton(
                      label: 'Delete tank',
                      onPressed: () {
                        ctrl.removeById(t.id);
                        selCtrl.clear(t.id);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: MechXSpacing.sm),
        ],
        const SizedBox(height: MechXSpacing.sm),
      ],
    ),
    );
  }
}

class _RoomsSection extends ConsumerWidget {
  const _RoomsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final sheet = ref.watch(sheetsControllerProvider).current;
    if (sheet == null) return const SizedBox.shrink();
    final rooms = [
      for (final r in ref.watch(roomAreasProvider))
        if (r.sheetId == sheet.id) r,
    ];
    if (rooms.isEmpty) return const SizedBox.shrink();
    final cal = ref.watch(projectControllerProvider).calibrationFor(sheet.id);
    final ducts = ref.watch(ductSettingsProvider);
    final ctrl = ref.read(roomAreasProvider.notifier);
    final nodes = ref.watch(networkControllerProvider).network.nodes;
    // E6: the open master-detail row is the shared canvas selection.
    final sel = ref.watch(selectedAnnotationProvider);
    final expandedRoomId =
        (sel != null && sel.kind == AnnotationKind.room) ? sel.id : null;
    final selCtrl = ref.read(selectedAnnotationProvider.notifier);

    String pkStr(double pk) =>
        pk == pk.roundToDouble() ? pk.toStringAsFixed(0) : pk.toString();

    String dims(RoomArea r) {
      if (cal == null) return '';
      final mpp = cal.metersPerPixel;
      return '${(r.widthPx * mpp).toStringAsFixed(1)} x '
          '${(r.heightPx * mpp).toStringAsFixed(1)} m';
    }

    String duct(RoomAirResult s) {
      final round = s.supplyDuctRound;
      if (round != null) {
        return 'Duct Ø${round.diameter.inMillimeters.round()} mm @ '
            '${round.actualVelocity.metersPerSecond.toStringAsFixed(1)} m/s';
      }
      final rect = s.supplyDuctRect!;
      return 'Duct ${rect.width.inMillimeters.round()}x'
          '${rect.height.inMillimeters.round()} mm @ '
          '${rect.actualVelocity.metersPerSecond.toStringAsFixed(1)} m/s';
    }

    String bank(TerminalBank b) =>
        '${b.count} x ${b.each.squareSide.inMillimeters.round()} mm @ '
        '${b.each.faceVelocity.metersPerSecond.toStringAsFixed(1)} m/s';

    return DisclosureSection(
      name: 'Rooms (ACH airflow)',
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rooms) ...[
          Builder(builder: (context) {
            final s = r.sizing(
              cal?.metersPerPixel,
              ductShape: ducts.shape,
              ductMethod: ducts.method,
            );
            // AC cooling — computed once so the compact row can flag an
            // over-range unit and the expanded editor can detail it.
            final acs = [
              for (final n in nodes)
                if (RoomArea.isAcComponent(n.component) &&
                    r.containsNode(n.sheetId, n.floorIndex, n.x, n.y))
                  n,
            ];
            final load = r.coolingLoad(cal?.metersPerPixel);
            final perUnit = (acs.isNotEmpty && load != null)
                ? selectAc(load.btuPerHr / acs.length)
                : null;
            final expanded = expandedRoomId == r.id;
            return Container(
              padding: const EdgeInsets.all(MechXSpacing.sm),
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: MechXRadii.control,
                border: Border.all(color: colors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _MasterRow(
                    title: '${r.name} · ${roomTypeLabel(r.roomType)}',
                    headline:
                        s == null ? 'set scale' : '${s.airflowCfm.round()} CFM',
                    warning: perUnit?.exceedsRange ?? false,
                    expanded: expanded,
                    onTap: () => expanded
                        ? selCtrl.clear(r.id)
                        : selCtrl.selectRoom(r.id),
                  ),
                  if (expanded) ...[
                    const SizedBox(height: MechXSpacing.sm),
                    // E7: editable name (commit-on-blur/Enter = one undo step) —
                    // flows into the equipment schedule so AHU rows read
                    // distinctly, not a wall of 'Room'.
                    Row(
                      children: [
                        Text('Name',
                            style: type.caption
                                .copyWith(color: colors.textMuted)),
                        const SizedBox(width: MechXSpacing.sm),
                        Expanded(
                          child: MechXTextField(
                            key: ValueKey('room-name-${r.id}'),
                            value: r.name,
                            hint: 'Room name',
                            onCommitted: (str) {
                              final name = str.trim();
                              if (name.isNotEmpty) ctrl.setName(r.id, name);
                            },
                          ),
                        ),
                        const SizedBox(width: MechXSpacing.sm),
                        Text(dims(r),
                            // L2: live dims while the footprint drags.
                            style: MechXTypography.tabular(type.caption
                                .copyWith(color: colors.textMuted))),
                      ],
                    ),
                    const SizedBox(height: MechXSpacing.sm),
                    // C4: identity (name, above) leads; the 1-2 headline
                    // results — design airflow and the sized equipment's duty
                    // — are promoted to the shared ResultCard (matching the
                    // Fire/HVAC sections), with the supporting duct/bank
                    // figures demoted to muted caption rows beneath. A room
                    // with no scale set yet has nothing to promote.
                    if (s == null)
                      Text('set scale',
                          style:
                              type.caption.copyWith(color: colors.textMuted))
                    else ...[
                      ResultCard(
                        headline: '${s.airflowCfm.round()} CFM',
                        label: 'Design airflow · '
                            '${s.airflow.inLitersPerSecond.round()} L/s · '
                            '${s.airflow.inCubicMetersPerHour.round()} m3/h',
                        verdict: 'sized',
                        verdictColor: colors.success,
                      ),
                      const SizedBox(height: MechXSpacing.xs),
                      // L2: these figures re-size live with the footprint —
                      // tabular digits stop the rows shuffling as they change.
                      Text(duct(s),
                          style: MechXTypography.tabular(
                              type.caption.copyWith(color: colors.textMuted))),
                      Text('Supply ${bank(s.supply)}',
                          style: MechXTypography.tabular(
                              type.caption.copyWith(color: colors.textMuted))),
                      Text('Return ${bank(s.return_)}',
                          style: MechXTypography.tabular(
                              type.caption.copyWith(color: colors.textMuted))),
                      const SizedBox(height: MechXSpacing.xs),
                      ResultCard(
                        headline:
                            '${s.equipment.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW',
                        label: '${airEquipmentLabel(s.equipmentKind)} · '
                            '${s.equipment.totalStaticPressure.pascals.round()} Pa',
                        verdict: 'sized',
                        verdictColor: colors.success,
                      ),
                    ],
                    // Cooling (AC) — shown only when an AC indoor unit sits in
                    // the room. Auto-computes the BTU/h + PK requirement and a
                    // per-unit recommendation split across the placed units,
                    // promoted to its own ResultCard (verdict flags an
                    // over-range unit the way the master row's warning dot
                    // already did).
                    if (perUnit != null) ...() {
                      final labels = {for (final n in acs) n.component!.label};
                      final typeStr =
                          labels.length == 1 ? labels.first : 'mixed';
                      return <Widget>[
                        const SizedBox(height: MechXSpacing.xs),
                        ResultCard(
                          headline: '${pkStr(perUnit.pk)} PK',
                          label: '${acs.length} ${acs.length == 1 ? 'unit' : 'units'} '
                              '($typeStr) · ${perUnit.nominalBtuPerHr.round()} BTU/h',
                          verdict: perUnit.exceedsRange ? 'over' : 'sized',
                          verdictColor: perUnit.exceedsRange
                              ? colors.danger
                              : colors.success,
                        ),
                        const SizedBox(height: MechXSpacing.xxs),
                        Text(
                          // The raw computed load PK (= BTU/h ÷ 9000); the
                          // ResultCard above shows the recommended
                          // market-ladder PK, so the two figures are labelled
                          // to read as distinct.
                          'Cooling load ${load!.btuPerHr.round()} BTU/h · '
                          '${load.pk.toStringAsFixed(1)} PK (load)',
                          // L2: recomputes live with the room footprint.
                          style: MechXTypography.tabular(
                              type.caption.copyWith(color: colors.textMuted)),
                        ),
                        Text('Feeds the electrical panel at the kW above.',
                            style: type.caption
                                .copyWith(color: colors.textMuted)),
                        if (perUnit.exceedsRange)
                          Text(
                            'Load exceeds the largest single unit — add more units.',
                            style:
                                type.caption.copyWith(color: colors.danger),
                          ),
                      ];
                    }(),
                    const SizedBox(height: MechXSpacing.sm),
                    // C4: ceiling/ACH/room-type/equipment-kind are set once and
                    // rarely revisited — demote them below the identity +
                    // promoted results into a collapsed disclosure, mirroring
                    // the node editor's identity-first + demoted-Placement
                    // pattern (every control preserved, just regrouped).
                    DisclosureSection(
                      name: 'Room settings',
                      defaultExpanded: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Ceiling height stepper.
                          Row(
                            children: [
                              Text('Ceiling',
                                  style: type.caption
                                      .copyWith(color: colors.textMuted)),
                              const Spacer(),
                              SteppedValueField(
                                display:
                                    '${r.ceilingHeightM.toStringAsFixed(2)} m',
                                editSeed: r.ceilingHeightM.toStringAsFixed(2),
                                label: context.strings(
                                    StringKey.a11yFieldCeilingHeight),
                                gap: 0,
                                valueWidth: 56,
                                valueAlign: TextAlign.center,
                                valueColor: colors.textPrimary,
                                min: 1.5,
                                max: 12,
                                onDecrement: () => ctrl.setCeiling(
                                    r.id, r.ceilingHeightM - 0.25),
                                onIncrement: () => ctrl.setCeiling(
                                    r.id, r.ceilingHeightM + 0.25),
                                onSubmit: (v) {
                                  if (v != null) ctrl.setCeiling(r.id, v);
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: MechXSpacing.xxs),
                          // ACH stepper (override; 'Auto' resets to the
                          // room-type value).
                          Row(
                            children: [
                              Text('ACH',
                                  style: type.caption
                                      .copyWith(color: colors.textMuted)),
                              const SizedBox(width: MechXSpacing.xs),
                              _Pill(
                                label: 'Auto',
                                selected: r.achOverride == null,
                                onTap: () => ctrl.setAch(r.id, null),
                              ),
                              const Spacer(),
                              SteppedValueField(
                                display:
                                    '${r.effectiveAch().toStringAsFixed(0)}/h',
                                editSeed: r.effectiveAch().toStringAsFixed(0),
                                label: context.strings(
                                    StringKey.a11yFieldAirChangesPerHour),
                                gap: 0,
                                valueWidth: 56,
                                valueAlign: TextAlign.center,
                                valueColor: colors.textPrimary,
                                min: 0.5,
                                max: 60,
                                onDecrement: () =>
                                    ctrl.setAch(r.id, r.effectiveAch() - 1),
                                onIncrement: () =>
                                    ctrl.setAch(r.id, r.effectiveAch() + 1),
                                onSubmit: (v) {
                                  if (v != null) ctrl.setAch(r.id, v);
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: MechXSpacing.xs),
                          Wrap(
                            spacing: MechXSpacing.xs,
                            runSpacing: MechXSpacing.xs,
                            children: [
                              for (final t in RoomType.values)
                                _Pill(
                                  label: roomTypeLabel(t),
                                  selected: r.roomType == t,
                                  onTap: () => ctrl.setRoomType(r.id, t),
                                ),
                            ],
                          ),
                          const SizedBox(height: MechXSpacing.xs),
                          Wrap(
                            spacing: MechXSpacing.xs,
                            runSpacing: MechXSpacing.xs,
                            children: [
                              for (final k in AirEquipmentKind.values)
                                _Pill(
                                  label: airEquipmentLabel(k),
                                  selected: r.equipmentKind == k,
                                  onTap: () => ctrl.setEquipment(r.id, k),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: MechXSpacing.xs),
                    // Drop the sized supply diffusers + a return grille onto the
                    // plan inside this room's footprint, in one undo step.
                    Row(
                      children: [
                        MechXButton(
                          label: 'Auto-place diffusers',
                          onPressed: (s != null && cal != null)
                              ? () => ref
                                  .read(networkControllerProvider.notifier)
                                  .autoPlaceRoomTerminals(
                                    room: r,
                                    metersPerPixel: cal.metersPerPixel,
                                    ductShape: ducts.shape,
                                    ductMethod: ducts.method,
                                  )
                              : null,
                        ),
                        const Spacer(),
                        if (s != null)
                          Text('${s.supply.count} + 1',
                              // L2: the diffuser count tracks the live sizing.
                              style: MechXTypography.tabular(type.caption
                                  .copyWith(color: colors.textMuted))),
                      ],
                    ),
                    const SizedBox(height: MechXSpacing.sm),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: MechXButton(
                        label: 'Delete room',
                        onPressed: () {
                          ctrl.removeById(r.id);
                          selCtrl.clear(r.id);
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
          const SizedBox(height: MechXSpacing.sm),
        ],
        const SizedBox(height: MechXSpacing.sm),
      ],
    ),
    );
  }
}


/// One key/value row of a results list (Results / Fire / HVAC sections).
///
/// L1: the numeric VALUE always wins the space fight — it is laid out at its
/// intrinsic width and never truncated ('319 kPa' must never become '319 …');
/// the LABEL is the only child that yields (it soft-wraps to two lines, then
/// ellipsizes). First baselines align so a wrapped label still reads against
/// its value. L2: the value wears [MechXTypography.standard.mono], which
/// already carries tabular figures, so a live re-solve never makes the row
/// wobble sideways.
Widget _kvRow(BuildContext context, String key, String value) {
  final colors = context.colors;
  final type = context.type;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
    child: LayoutBuilder(builder: (context, constraints) {
      // The value may take the WHOLE row (the label then wraps/ellipsizes to
      // nothing), but is capped at the row width so a pathologically wide
      // value soft-wraps instead of overflowing the panel — data is shown in
      // full either way.
      final valueMax = constraints.hasBoundedWidth
          ? (constraints.maxWidth - MechXSpacing.xs).clamp(0.0, double.infinity)
          : double.infinity;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(key,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: type.caption.copyWith(color: colors.textMuted)),
          ),
          const SizedBox(width: MechXSpacing.xs),
          // Deliberately NOT Flexible: the value's intrinsic width is
          // honoured in full, so only the label shrinks in the space fight.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: valueMax),
            child: Text(value,
                textAlign: TextAlign.right,
                style: type.mono.copyWith(color: colors.textSecondary)),
          ),
        ],
      );
    }),
  );
}

class _ResultsSection extends ConsumerWidget {
  const _ResultsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(showHeatmapProvider);
    final showSizes = ref.watch(showSizingProvider);
    final strategy = ref.watch(feedStrategyProvider);
    final stratCtrl = ref.read(feedStrategyProvider.notifier);
    final solution = ref.watch(solveProvider);
    final downfeed = ref.watch(downfeedProvider);
    final pump = ref.watch(pumpDutyProvider);
    final zones = ref.watch(zonesProvider);
    final zoneStatics = ref.watch(zoneStaticsProvider);
    final bom = ref.watch(bomProvider);
    final fittings = ref.watch(fittingsProvider);
    final hwr = ref.watch(hotWaterRecircProvider);
    final worstZone = zoneStatics.isEmpty
        ? 0.0
        : zoneStatics
            .map((z) => z.bottomStatic.inKiloPascals)
            .reduce((a, b) => a > b ? a : b);
    final zonesOk = zoneStatics.every((z) => z.withinLimit);
    final totalLength =
        bom.fold<double>(0, (sum, line) => sum + line.totalLength.meters);

    // L1: keep the BOM row leader short enough that it never fights the
    // quantity for space. When every listed line shares ONE service the
    // service word is redundant ('15 DN riser'); with several services a
    // compact service word — the trailing 'water'/'air' dropped, never a
    // mid-word abbreviation — keeps rows distinct ('15 DN · Cold riser').
    final bomServiceCount = {for (final l in bom) l.service}.length;
    String bomLeader(BomLine line) {
      final size =
          '${line.diameterMm}${line.service.regime == FlowRegime.air ? ' Ø' : ' DN'}';
      final kindWord = line.kind == EdgeKind.riser ? 'riser' : 'run';
      if (bomServiceCount <= 1) return '$size $kindWord';
      final service = serviceLabel(line.service)
          .replaceAll(' water', '')
          .replaceAll(' air', '');
      return '$size · $service $kindWord';
    }

    // The promoted headline result for this feed strategy: the single number an
    // engineer scans for (pump motor kW upfeed; worst PRV-zone status downfeed),
    // with a colour-coded verdict. Only built once there is a real result, so a
    // fresh/blank launch (the golden state) renders no card — byte-identical.
    final colors = context.colors;
    Widget? headlineCard;
    if (strategy == FeedStrategy.upfeed) {
      if (pump != null) {
        headlineCard = ResultCard(
          headline: '${pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW',
          label: 'Pump motor',
          verdict: 'sized',
          verdictColor: colors.success,
        );
      }
    } else {
      if (downfeed != null) {
        if (zoneStatics.isEmpty) {
          // No PRV zones drawn — the headline is the gravity/booster verdict.
          headlineCard = ResultCard(
            headline: downfeed.gravitySufficient
                ? 'gravity'
                : '+${downfeed.boosterHeadRequired.meters.toStringAsFixed(1)} m',
            label: 'Downfeed booster',
            verdict: downfeed.gravitySufficient ? 'OK' : 'boost',
            verdictColor: downfeed.gravitySufficient
                ? colors.success
                : colors.warning,
          );
        } else {
          headlineCard = ResultCard(
            headline: '${zones.length} zone${zones.length == 1 ? '' : 's'}'
                ' · ${worstZone.toStringAsFixed(0)} kPa',
            label: 'PRV zones (worst)',
            verdict: zonesOk ? 'OK' : 'over',
            verdictColor: zonesOk ? colors.success : colors.danger,
          );
        }
      }
    }

    // E1: gate the disclosure default on real content the way the Scale section
    // gates on calibration — a plumbing network with sized runs/risers (or a
    // solved feed) opens itself; a blank launch stays a quiet collapsed header
    // instead of showing dash rows. Mirrors the empty-state predicate below.
    final hasNetworkResults =
        bom.isNotEmpty || solution != null || downfeed != null || hwr != null;

    return DisclosureSection(
      // E5: this is the plumbing sizing RESULTS surface, not a generic "Network".
      name: 'Results',
      defaultExpanded: hasNetworkResults,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            _Pill(
              label: 'Upfeed pump',
              selected: strategy == FeedStrategy.upfeed,
              onTap: () => stratCtrl.set(FeedStrategy.upfeed),
            ),
            _Pill(
              label: 'Roof-tank downfeed',
              selected: strategy == FeedStrategy.downfeed,
              onTap: () => stratCtrl.set(FeedStrategy.downfeed),
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        // Canvas view toggles: show the auto-sized labels + the pressure heatmap.
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            MechXButton(
              label: showSizes ? 'Hide sizes' : 'Show sizes',
              primary: showSizes,
              onPressed: () => ref.read(showSizingProvider.notifier).toggle(),
            ),
            MechXButton(
              label: show ? 'Hide heatmap' : 'Show heatmap',
              primary: show,
              onPressed: () => ref.read(showHeatmapProvider.notifier).toggle(),
            ),
          ],
        ),
        if (headlineCard != null) ...[
          const SizedBox(height: MechXSpacing.sm),
          headlineCard,
        ],
        const SizedBox(height: MechXSpacing.sm),
        // E11: honest empty state — until a network is actually drawn and
        // solved, show a muted prompt (the HVAC-section idiom) instead of
        // dash rows and a misleading 'BOM total 0.0 m'.
        if (bom.isEmpty && solution == null && downfeed == null && hwr == null)
          Text('Draw a network to size runs and risers.',
              style: context.type.caption.copyWith(color: colors.textMuted))
        else ...[
          if (strategy == FeedStrategy.upfeed) ...[
            // 'Motor' kW is promoted to the ResultCard above; keep only the
            // distinct supporting figure here (H8 — no headline/kv duplication).
            _kvRow(context, 'Pump head',
                solution == null ? '—' : '${solution.requiredPumpHead.meters.toStringAsFixed(1)} m'),
          ] else ...[
            _kvRow(context, 'Top residual',
                downfeed == null ? '—' : '${downfeed.minResidual.inKiloPascals.toStringAsFixed(0)} kPa'),
            _kvRow(
              context,
              'Booster',
              downfeed == null
                  ? '—'
                  : downfeed.gravitySufficient
                      ? 'gravity OK'
                      : '+${downfeed.boosterHeadRequired.meters.toStringAsFixed(1)} m',
            ),
            _kvRow(
              context,
              'PRV zones',
              zoneStatics.isEmpty
                  ? '${zones.length}'
                  : '${zones.length} · worst ${worstZone.toStringAsFixed(0)} kPa'
                      ' ${zonesOk ? 'OK' : 'over'}',
            ),
          ],
          if (strategy == FeedStrategy.upfeed)
            _kvRow(context, 'Pressure zones', '${zones.length}'),
          if (hwr != null)
            _kvRow(context, 'HW recirc',
                '${hwr.recircFlow.inLitersPerSecond.toStringAsFixed(2)} L/s · ${hwr.pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW'),
          _kvRow(context, 'BOM total', '${totalLength.toStringAsFixed(1)} m'),
          if (bom.isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.xs),
            // Cap the per-line listing so a big BOM doesn't push the whole panel
            // off-screen; the overflow is summarised, never silently dropped (the
            // full breakdown is in the CSV export below). (H6/H8.)
            for (final line in bom.take(_kBomInlineCap))
              _kvRow(
                context,
                bomLeader(line),
                '${line.totalLength.meters.toStringAsFixed(1)} m ×${line.segmentCount}',
              ),
            if (bom.length > _kBomInlineCap)
              _kvRow(
                context,
                '+${bom.length - _kBomInlineCap} more line'
                    '${bom.length - _kBomInlineCap == 1 ? '' : 's'}',
                'see CSV',
              ),
            if (fittings.isNotEmpty)
              _kvRow(context, 'Fittings (est.)',
                  '${fittings.fold<int>(0, (s, f) => s + f.count)}'),
            const SizedBox(height: MechXSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: MechXButton(
                label: 'Export BOM (CSV)',
                onPressed: () => _exportBom(ref, fittings,
                    MechXStringsData(ref.read(localeProvider))(
                        StringKey.exportTitleBom)),
              ),
            ),
          ],
        ],
      ],
    ),
    );
  }

  Future<void> _exportBom(WidgetRef ref, List<FittingLine> fittings,
          String dialogTitle) =>
      runExportGuarded(
        ref,
        // Two clean single-schema files (Excel-aligned) instead of one mixed CSV.
        name: 'BOM (-bom.csv + -fittings.csv)',
        write: () async {
          // H8: the default name carries the PROJECT name like every other
          // export — never the internal 'mechx' codename.
          final projectName = ref.read(projectControllerProvider).name;
          final defaultBase = projectName.isEmpty ? 'project' : projectName;
          final full = await pickExportSave(ref,
              dialogTitle: dialogTitle,
              fileName: '$defaultBase-bom.csv',
              ext: 'csv');
          if (full == null) return false;
          // Derive a base by stripping a trailing .csv (and a trailing '-bom',
          // so accepting the suggested name yields '<name>-bom.csv', not
          // '<name>-bom-bom.csv'), then write the two aligned files:
          // <base>-bom.csv + <base>-fittings.csv.
          var base = full.substring(0, full.length - 4);
          if (base.endsWith('-bom')) {
            base = base.substring(0, base.length - 4);
          }
          // Rebuild the BOM grouped by floor (bomProvider is un-grouped) and
          // join the live stock-bar cut plan onto the CSV.
          final project = ref.read(projectControllerProvider);
          final floorBom = buildBom(
            net: ref.read(networkControllerProvider).network,
            sizing: ref.read(sizingProvider),
            calibrationBySheet: project.calibrations,
            building: project.building,
            groupByFloor: true,
          );
          final cutPlan = ref.read(pipeCutPlanProvider);
          await File('$base-bom.csv')
              .writeAsString(bomCsvWithCutPlan(floorBom, cutPlan));
          await File('$base-fittings.csv')
              .writeAsString(fittingsToCsv(fittings));
          return true;
        },
      );

}

class _FireSection extends ConsumerWidget {
  const _FireSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final sprinkler = ref.watch(sprinklerDesignProvider);
    final standpipe = ref.watch(standpipeDesignProvider);
    final rating = ref.watch(firePumpRatingProvider);
    // E11: the whole fire design derives from occupancy/height/hazard alone, so
    // it computes even with NO fire pipework drawn. Detect real sprinkler/
    // hydrant edges so the verdict is honest — a preliminary 'draft' from
    // building defaults, not a validated 'rated', until fire runs exist.
    final hasFireEdges = ref.watch(networkControllerProvider).network.edges.any(
        (e) =>
            e.service == ServiceType.fireSprinkler ||
            e.service == ServiceType.fireHydrant);

    // The shared value-wins row (L1) — the label yields, the figure never
    // truncates.
    Widget kv(String key, String value) => _kvRow(context, key, value);

    // The one INPUT the whole fire design derives from — previously settable
    // only through the New-from-template dialog (a results panel with an
    // invisible input); mirrors the Sizing section's Occupancy pill row.
    String hazardLabel(FireHazardClass h) => switch (h) {
          FireHazardClass.lightHazard => 'Light',
          FireHazardClass.ordinaryHazard1 => 'Ordinary 1',
          FireHazardClass.ordinaryHazard2 => 'Ordinary 2',
          FireHazardClass.extraHazard => 'Extra',
        };

    return DisclosureSection(
      name: 'Fire',
      // E1: expand only when fire (sprinkler/hydrant) pipework actually exists —
      // otherwise this section computed a full fire-pump duty from building
      // defaults alone and greeted a blank launch with a phantom rating. An
      // empty project now keeps a quiet collapsed header.
      defaultExpanded: hasFireEdges,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Hazard class',
            style: type.caption.copyWith(color: colors.textMuted)),
        const SizedBox(height: MechXSpacing.xs),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            for (final h in FireHazardClass.values)
              _Pill(
                label: hazardLabel(h),
                selected: ref.watch(fireHazardProvider) == h,
                onTap: () => ref.read(fireHazardProvider.notifier).set(h),
              ),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        // Promoted headline: the standpipe fire-pump duty, with the NFPA 20
        // rating-curve verdict — 'rated' when the curve sits inside the standard
        // frame, 'oversized' when the largest standard motor is still below the
        // overload shaft power. Demotes the pump figure from the kv rows (H8).
        ResultCard(
          headline:
              '${standpipe.pumpHead.meters.toStringAsFixed(0)} m · ${standpipe.pumpShaftPower.inKiloWatts.toStringAsFixed(1)} kW',
          label: 'Fire pump (standpipe)',
          // Neutral 'draft' (not a green 'rated') until sprinkler/hydrant runs
          // are drawn — the duty is a building-defaults preliminary, not a
          // validated design.
          verdict: !hasFireEdges
              ? 'draft'
              : (rating.oversized ? 'oversized' : 'rated'),
          verdictColor: !hasFireEdges
              ? colors.textMuted
              : (rating.oversized ? colors.warning : colors.success),
        ),
        const SizedBox(height: MechXSpacing.xs),
        kv('Sprinkler flow',
            '${sprinkler.requiredFlow.inLitersPerSecond.toStringAsFixed(1)} L/s'),
        kv('Sprinkler heads', '${sprinkler.sprinklerCount}'),
        kv('Standpipe flow',
            '${standpipe.requiredFlow.inLitersPerSecond.toStringAsFixed(1)} L/s'),
        const SizedBox(height: MechXSpacing.xs),
        Row(
          children: [
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: MechXSpacing.xs),
              decoration: BoxDecoration(
                color: colors.warning,
                borderRadius: const BorderRadius.all(Radius.circular(4)),
              ),
            ),
            Expanded(
              child: Text(
                hasFireEdges
                    ? 'SNI 03-3989 / 1745 / 6570 · single-riser draft demand'
                    : 'Draft demand from building defaults — draw '
                        'sprinkler/hydrant runs to validate.',
                style: type.caption.copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ),
      ],
    ),
    );
  }
}

class _ServiceChip extends StatelessWidget {
  final ServiceType service;
  final bool selected;
  final VoidCallback onTap;

  const _ServiceChip({
    required this.service,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: MechXFocusRing(
        onActivated: onTap,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(
              // Compensate the heavier selected border so the chip never jumps.
              horizontal: MechXSpacing.sm - (selected ? 1 : 0),
              vertical: MechXSpacing.xs - (selected ? 1 : 0),
            ),
            decoration: BoxDecoration(
              color: selected ? colors.accentMuted : colors.surface,
              borderRadius: MechXRadii.control,
              border: Border.all(
                color: selected ? colors.accent : colors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: serviceColor(service),
                    borderRadius: const BorderRadius.all(Radius.circular(2)),
                  ),
                ),
                const SizedBox(width: MechXSpacing.xs),
                Text(
                  serviceLabel(service),
                  style: type.label.copyWith(
                    color:
                        selected ? colors.textPrimary : colors.textSecondary,
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _roleLabel(NodeRole r) => switch (r) {
      NodeRole.main => 'Junction',
      NodeRole.fixture => 'Fixture',
      NodeRole.plant => 'Source / tank',
    };

String fixtureLabel(PlumbingFixture f) => switch (f) {
      PlumbingFixture.waterClosetFlushValve => 'WC · valve',
      PlumbingFixture.waterClosetFlushTank => 'WC · tank',
      PlumbingFixture.urinalFlushTank => 'Urinal',
      PlumbingFixture.lavatory => 'Lavatory',
      PlumbingFixture.shower => 'Shower',
      PlumbingFixture.bathtub => 'Bathtub',
      PlumbingFixture.kitchenSink => 'Kitchen sink',
      PlumbingFixture.hoseBibb => 'Hose bibb',
    };

/// Inspector editor for the current canvas selection (node or edge). Renders
/// nothing when nothing is selected.
class _SelectionSection extends ConsumerWidget {
  const _SelectionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    if (selection.isEmpty) return const SizedBox.shrink();

    final net = ref.watch(networkControllerProvider).network;
    final ctrl = ref.read(networkControllerProvider.notifier);
    final selCtrl = ref.read(selectionProvider.notifier);

    // Multi-selection: a count header + Copy / Paste / Delete actions (the
    // single-element editor is shown only for a single selection).
    if (selection.isMulti) {
      return _multiSelectionSection(context, ref, net, selection, ctrl, selCtrl);
    }

    Widget? body;
    if (selection.isNode) {
      final node = net.nodeById(selection.nodeId!);
      if (node != null) {
        body = _nodeEditor(context, ref, node, ctrl, selCtrl);
      }
    } else if (selection.isEdge) {
      NetEdge? edge;
      for (final e in net.edges) {
        if (e.id == selection.edgeId) {
          edge = e;
          break;
        }
      }
      if (edge != null) {
        body = _edgeEditor(context, ref, edge, net, ctrl, selCtrl);
      }
    }
    if (body == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: MechXSectionLabel('Selection')),
            _GlyphButton(glyph: '×', onTap: selCtrl.clear),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        body,
        const SizedBox(height: MechXSpacing.lg),
      ],
    );
  }

  Widget _multiSelectionSection(BuildContext context, WidgetRef ref, Network net,
      Selection selection, NetworkController ctrl, SelectionController selCtrl) {
    final colors = context.colors;
    final type = context.type;
    final n = selection.nodeIds.length;
    final m = selection.edgeIds.length;
    final edgeIds = selection.edgeIds;
    final nodeIds = selection.nodeIds;

    // Resolve the selected elements to drive the shared property editors (E1).
    final selEdges = <NetEdge>[
      for (final e in net.edges)
        if (edgeIds.contains(e.id)) e,
    ];
    final selNodes = <NetNode>[
      for (final nd in net.nodes)
        if (nodeIds.contains(nd.id)) nd,
    ];

    // A HOMOGENEOUS selection (all edges, or all nodes of one role) unlocks the
    // shared editors — the SAME pickers the single-element inspector uses, but
    // each applies to EVERY id in ONE undo step via the plural setEdges*/
    // setNodes* intents (which never touch the selection ⇒ the batch survives).
    final allEdges = selEdges.isNotEmpty && selNodes.isEmpty;
    final allNodes = selNodes.isNotEmpty && selEdges.isEmpty;
    // Size/material pickers differ by regime, so they show only when every
    // selected edge shares one (air vs pipe); a mixed batch keeps the service
    // chips (re-servicing all is always coherent).
    final allAir = allEdges && selEdges.every((e) => e.service.isAir);
    final allPipe = allEdges && selEdges.every((e) => !e.service.isAir);
    // E6: resolve the batch's shared size override for the compact size stepper
    // — a single shared size, null (every edge on Auto), or "mixed" when the
    // selected edges disagree (differing sizes, or a mix of Auto + sized).
    Diameter? batchSizeCommon;
    var batchSizeMixed = false;
    if (allEdges && selEdges.isNotEmpty) {
      final mmSet = <int>{};
      var anyAuto = false;
      for (final e in selEdges) {
        if (e.sizeOverride == null) {
          anyAuto = true;
        } else {
          mmSet.add(e.sizeOverride!.inMillimeters.round());
        }
      }
      if (mmSet.isEmpty) {
        batchSizeCommon = null; // every edge on Auto
      } else if (mmSet.length == 1 && !anyAuto) {
        batchSizeCommon = Diameter.mm(mmSet.first.toDouble());
      } else {
        batchSizeMixed = true;
      }
    }
    NodeRole? commonRole;
    if (allNodes) {
      commonRole = selNodes.first.role;
      for (final nd in selNodes) {
        if (nd.role != commonRole) {
          commonRole = null;
          break;
        }
      }
    }
    final showNodeEditors = allNodes && commonRole == NodeRole.fixture;
    final showApply = allEdges || showNodeEditors;
    final applyCount = allEdges ? m : n;

    Widget label(String text) => Text(text,
        style: type.caption.copyWith(color: colors.textMuted));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: MechXSectionLabel('Selection')),
            _GlyphButton(glyph: '×', onTap: selCtrl.clear),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        Text(
          '$n ${n == 1 ? 'node' : 'nodes'} / $m ${m == 1 ? 'edge' : 'edges'} '
          'selected',
          // L2: the counts change live while marquee-selecting.
          style: MechXTypography.tabular(
              type.caption.copyWith(color: colors.textMuted)),
        ),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            MechXButton(
              label: 'Copy',
              onPressed: () =>
                  ctrl.copySelection(selection.nodeIds, selection.edgeIds),
            ),
            MechXButton(
              label: 'Paste',
              onPressed: () {
                final sheet = ref.read(sheetsControllerProvider).current;
                if (sheet == null) return;
                final levelCount =
                    ref.read(projectControllerProvider).building.levelCount;
                final floorIndex = ref
                    .read(sheetsControllerProvider)
                    .floorFor(sheet.id, levelCount);
                ctrl.paste(sheetId: sheet.id, floorIndex: floorIndex);
              },
            ),
            MechXButton(
              label: 'Delete',
              onPressed: () {
                ctrl.deleteMany(selection.nodeIds, selection.edgeIds);
                selCtrl.clear();
              },
            ),
          ],
        ),

        // ── E1: batch property editors on a HOMOGENEOUS selection ─────────────
        if (showApply) ...[
          const SizedBox(height: MechXSpacing.lg),
          MechXSectionLabel('Apply to $applyCount selected'),
          if (allEdges) ...[
            // Service (always coherent for an all-edge batch).
            const SizedBox(height: MechXSpacing.sm),
            label('Service'),
            const SizedBox(height: MechXSpacing.xs),
            Wrap(
              spacing: MechXSpacing.xs,
              runSpacing: MechXSpacing.xs,
              children: [
                for (final s in kDrawServices)
                  _ServiceChip(
                    service: s,
                    selected: selEdges.every((e) => e.service == s),
                    onTap: () => ctrl.setEdgesService(edgeIds, s),
                  ),
              ],
            ),
            // Size + material only when every selected edge shares a regime.
            if (allAir || allPipe) ...[
              const SizedBox(height: MechXSpacing.sm),
              label('Size'),
              const SizedBox(height: MechXSpacing.xs),
              // E6: a compact stepper replaces the inline ~11-pill ladder; it
              // applies to every selected edge in one undo step.
              _sizeStepper(
                isAir: allAir,
                current: batchSizeCommon,
                mixed: batchSizeMixed,
                onSet: (d) => ctrl.setEdgesSizeOverride(edgeIds, d),
              ),
              const SizedBox(height: MechXSpacing.sm),
              label('Material'),
              const SizedBox(height: MechXSpacing.xs),
              Wrap(
                spacing: MechXSpacing.xs,
                runSpacing: MechXSpacing.xs,
                children: [
                  if (allAir) ...[
                    _Pill(
                      label: 'Auto',
                      selected: selEdges.every((e) => e.ductProduct == null),
                      onTap: () => ctrl.setEdgesDuctProduct(edgeIds, null),
                    ),
                    for (final p in DuctProduct.values)
                      _Pill(
                        label: ductLabelFor(p),
                        selected: selEdges.every((e) => e.ductProduct == p),
                        onTap: () => ctrl.setEdgesDuctProduct(edgeIds, p),
                      ),
                  ] else ...[
                    _Pill(
                      label: 'Default',
                      selected: selEdges.every((e) => e.pipeProduct == null),
                      onTap: () => ctrl.setEdgesPipeProduct(edgeIds, null),
                    ),
                    for (final p in PipeProduct.values)
                      _Pill(
                        label: labelFor(p),
                        selected: selEdges.every((e) => e.pipeProduct == p),
                        onTap: () => ctrl.setEdgesPipeProduct(edgeIds, p),
                      ),
                  ],
                ],
              ),
            ],
          ],
          if (showNodeEditors) ...[
            // Fixture type (all nodes share the fixture role).
            const SizedBox(height: MechXSpacing.sm),
            label('Fixture type'),
            const SizedBox(height: MechXSpacing.xs),
            Wrap(
              spacing: MechXSpacing.xs,
              runSpacing: MechXSpacing.xs,
              children: [
                for (final f in PlumbingFixture.values)
                  _Pill(
                    label: fixtureLabel(f),
                    selected: selNodes.every(
                        (nd) => nd.customFixtureId == null && nd.fixture == f),
                    onTap: () => ctrl.setNodesFixture(nodeIds, f),
                  ),
              ],
            ),
            const SizedBox(height: MechXSpacing.sm),
            label('Diffuser / grille face size'),
            const SizedBox(height: MechXSpacing.xs),
            Wrap(
              spacing: MechXSpacing.xs,
              runSpacing: MechXSpacing.xs,
              children: [
                _Pill(
                  label: 'Auto',
                  selected: selNodes.every((nd) =>
                      nd.faceWidthMm == null || nd.faceHeightMm == null),
                  onTap: () => ctrl.setNodesFaceSize(nodeIds, null, null),
                ),
                for (final face in standardGrilleFacesMm)
                  _Pill(
                    label: '${face.$1.round()}x${face.$2.round()}',
                    selected: selNodes.every((nd) =>
                        nd.faceWidthMm == face.$1 &&
                        nd.faceHeightMm == face.$2),
                    onTap: () =>
                        ctrl.setNodesFaceSize(nodeIds, face.$1, face.$2),
                  ),
              ],
            ),
          ],
        ],

        // ── E5: save this selection as a reusable, re-stampable block ─────────
        const SizedBox(height: MechXSpacing.lg),
        MechXSectionLabel('Assembly'),
        const SizedBox(height: MechXSpacing.xs),
        _SaveAssemblyField(
          onSave: (name) {
            final saved = ref
                .read(assembliesProvider.notifier)
                .saveSelection(name, net, nodeIds, edgeIds);
            if (saved != null) {
              ref
                  .read(statusMessageProvider.notifier)
                  .showStatus('Saved block "${saved.name}"');
            }
          },
        ),
        const SizedBox(height: MechXSpacing.lg),
      ],
    );
  }

  Widget _nodeEditor(BuildContext context, WidgetRef ref, NetNode node,
      NetworkController ctrl, SelectionController selCtrl) {
    final project = ref.watch(projectControllerProvider);
    final elev = nodeElevation(node, project.building).meters;

    // Scope the fixture field groups to the node's ACTUAL discipline, derived
    // from its connected edges — a WC must not offer a diffuser-airflow
    // stepper, nor a supply diffuser the WC/urinal pills. An unconnected node
    // falls back to showing a group (nothing becomes unreachable before its
    // pipes are drawn) unless its component already rules the group out; a
    // group with a value set always shows so it stays editable/clearable.
    final net = ref.watch(networkControllerProvider).network;
    final touching = <ServiceType>{
      for (final e in net.edges)
        if (e.fromId == node.id || e.toId == node.id) e.service,
    };
    final airTerminal = switch (node.component) {
      NodeComponent.supplyDiffuser ||
      NodeComponent.returnGrille ||
      NodeComponent.exhaustGrille ||
      NodeComponent.linearDiffuser =>
        true,
      _ => false,
    };
    final plumbingTouch = touching.any((s) =>
        s == ServiceType.coldWater ||
        s == ServiceType.hotWater ||
        s == ServiceType.drainage ||
        s == ServiceType.vent);
    final airTouch = touching.any((s) => s.isAir);
    final rainTouch = touching.contains(ServiceType.rainwater);
    final unconnected = touching.isEmpty;
    final showFixtureType = plumbingTouch ||
        node.fixture != null ||
        node.customFixtureId != null ||
        (unconnected && !airTerminal);
    final showAirflow = airTouch ||
        airTerminal ||
        node.airflow != null ||
        (unconnected &&
            node.fixture == null &&
            node.customFixtureId == null);
    final showRoofArea = rainTouch ||
        node.roofAreaM2 != null ||
        node.component == NodeComponent.roofDrain ||
        (unconnected && !airTerminal);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Node · floor ${node.floorIndex + 1} · elev '
            '${elev.toStringAsFixed(1)} m',
            // L2: floor/elevation update in place as the node is edited.
            style: MechXTypography.tabular(context.type.caption
                .copyWith(color: context.colors.textMuted))),
        // I2 — the pressure-solve PROBE. Whenever the solve has a residual for
        // this node, surface its actual residual pressure so a fixture can be
        // spot-checked against the SNI target the heatmap colour alone can't
        // name. For a demand (fixture) node it carries the PASS/LOW verdict
        // against that target (min residual); other nodes just show the value.
        Builder(builder: (context) {
          final residual = ref.watch(residualByNodeProvider)[node.id];
          if (residual == null) return const SizedBox.shrink();
          final target = ref.watch(targetResidualProvider);
          final kpa = residual.inKiloPascals;
          final isFixture = node.role == NodeRole.fixture;
          // Mirror the heatmap legend's 0.5 kPa slack (= 500 Pa), NOT 0.5 Pa —
          // both verdicts read the same targetResidualProvider, so they must use
          // the same-unit tolerance or a sub-target residual splits PASS vs LOW.
          final pass = residual.pascals >= target.pascals - 500;
          final verdict = isFixture
              ? ' · ${pass ? 'PASS' : 'LOW'} (min '
                  '${target.inKiloPascals.toStringAsFixed(0)} kPa)'
              : '';
          return Padding(
            padding: const EdgeInsets.only(top: MechXSpacing.xxs),
            child: Text(
              'Residual ${kpa.toStringAsFixed(0)} kPa$verdict',
              // L2: the probe re-reads every solve — tabular kPa digits.
              style: MechXTypography.tabular(context.type.caption.copyWith(
                color: !isFixture
                    ? context.colors.textSecondary
                    : (pass ? context.colors.success : context.colors.danger),
              )),
            ),
          );
        }),
        if (node.component != null) ...[
          const SizedBox(height: MechXSpacing.xxs),
          Row(
            children: [
              ComponentSymbol(
                  component: node.component!,
                  color: context.colors.textSecondary,
                  size: 15),
              const SizedBox(width: MechXSpacing.xs),
              Expanded(
                child: Text(node.component!.label,
                    style: context.type.body
                        .copyWith(color: context.colors.textPrimary)),
              ),
              MechXButton(
                label: 'Clear',
                tertiary: true,
                onPressed: () => ctrl.setNodeComponent(node.id, null),
              ),
            ],
          ),
          // A prebuilt tank (e.g. a bought fibreglass/HDPE tank) carries a
          // directly-entered capacity; a cast concrete reservoir uses the drawn
          // tank-area footprint instead. Shown only for tank components.
          if (node.component == NodeComponent.roofTank ||
              node.component == NodeComponent.groundTank) ...[
            const SizedBox(height: MechXSpacing.xs),
            Text('Tank capacity (prebuilt)',
                style: context.type.caption
                    .copyWith(color: context.colors.textMuted)),
            const SizedBox(height: MechXSpacing.xxs),
            SteppedValueField(
              display: node.tankCapacityLitres == null
                  ? '—'
                  : '${node.tankCapacityLitres!.round()} L',
              label: 'Tank capacity',
              editSeed: node.tankCapacityLitres == null
                  ? ''
                  : node.tankCapacityLitres!.round().toString(),
              gap: MechXSpacing.sm,
              min: 0,
              onDecrement: () {
                final next = (node.tankCapacityLitres ?? 0) - 500;
                ctrl.setNodeTankCapacity(node.id, next <= 0 ? null : next);
              },
              onIncrement: () => ctrl.setNodeTankCapacity(
                  node.id, (node.tankCapacityLitres ?? 0) + 500),
              onSubmit: (v) => ctrl.setNodeTankCapacity(
                  node.id, (v == null || v <= 0) ? null : v),
            ),
          ],
          // A motorised component (pump / fan / air unit) is INTER-RELATED with
          // the electrical model: it feeds the MEP equipment panel as its own
          // circuit. Edit its electrical load here (kW); blank ⇒ the default
          // rating for this equipment.
          if (node.component!.isElectricalLoad) ...[
            const SizedBox(height: MechXSpacing.xs),
            Text('Electrical load (feeds the panel)',
                style: context.type.caption
                    .copyWith(color: context.colors.textMuted)),
            const SizedBox(height: MechXSpacing.xxs),
            SteppedValueField(
              display: () {
                final w = node.electricalLoadW ??
                    node.component!.defaultMotorKw * 1000;
                final suffix =
                    node.electricalLoadW == null ? ' · default' : '';
                return '${(w / 1000).toStringAsFixed(2)} kW$suffix';
              }(),
              label: 'Electrical load',
              editSeed: ((node.electricalLoadW ??
                          node.component!.defaultMotorKw * 1000) /
                      1000)
                  .toStringAsFixed(2),
              gap: MechXSpacing.sm,
              min: 0,
              onDecrement: () {
                final base = node.electricalLoadW ??
                    node.component!.defaultMotorKw * 1000;
                final next = base - 250;
                ctrl.setNodeElectricalLoad(node.id, next <= 0 ? null : next);
              },
              onIncrement: () {
                final base = node.electricalLoadW ??
                    node.component!.defaultMotorKw * 1000;
                ctrl.setNodeElectricalLoad(node.id, base + 250);
              },
              // The typed value is in kW (the displayed unit); store it as W.
              onSubmit: (v) => ctrl.setNodeElectricalLoad(
                  node.id, (v == null || v <= 0) ? null : v * 1000),
            ),
          ],
        ],
        // E2: identity first — the fixture/type group (below, gated on the
        // fixture role) leads the node editor; Role + Mounting height are
        // demoted into the collapsed "Placement" disclosure further down.
        if (node.role == NodeRole.fixture) ...[
          if (showFixtureType) ...[
          const SizedBox(height: MechXSpacing.sm),
          Text('Fixture type',
              style: context.type.caption
                  .copyWith(color: context.colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: [
              for (final f in PlumbingFixture.values)
                _Pill(
                  label: fixtureLabel(f),
                  selected:
                      node.customFixtureId == null && node.fixture == f,
                  onTap: () => ctrl.setNodeFixture(node.id, f),
                ),
            ],
          ),
          // User-defined fixture library — shown only when non-empty so the
          // built-in-only goldens are unchanged. A selected custom pill clears
          // the built-in fixture (mutual exclusivity, handled in the store).
          if (ref.watch(fixtureLibraryProvider).isNotEmpty) ...[
            const SizedBox(height: MechXSpacing.xs),
            Wrap(
              spacing: MechXSpacing.xs,
              runSpacing: MechXSpacing.xs,
              children: [
                for (final cf in ref.watch(fixtureLibraryProvider))
                  _Pill(
                    label: cf.name,
                    selected: node.customFixtureId == cf.id,
                    onTap: () => ctrl.setNodeCustomFixture(node.id, cf.id),
                  ),
              ],
            ),
          ],
          const SizedBox(height: MechXSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: MechXButton(
              label: 'Manage fixtures…',
              onPressed: () => showFixtureLibraryEditor(context, ref),
            ),
          ),
          ],
          if (showAirflow) ...[
          const SizedBox(height: MechXSpacing.sm),
          Text('Air terminal (diffuser) airflow',
              style: context.type.caption
                  .copyWith(color: context.colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          SteppedValueField(
            display: node.airflow == null
                ? '—'
                : '${node.airflow!.inLitersPerSecond.toStringAsFixed(0)} L/s',
            label: 'Air terminal airflow',
            editSeed: node.airflow == null
                ? ''
                : node.airflow!.inLitersPerSecond.toStringAsFixed(0),
            gap: MechXSpacing.sm,
            min: 0,
            onDecrement: () {
              final lps = (node.airflow?.inLitersPerSecond ?? 0) - 5;
              ctrl.setNodeAirflow(
                  node.id, lps <= 0 ? null : FlowRate.litersPerSecond(lps));
            },
            onIncrement: () {
              final lps = (node.airflow?.inLitersPerSecond ?? 0) + 5;
              ctrl.setNodeAirflow(node.id, FlowRate.litersPerSecond(lps));
            },
            onSubmit: (v) => ctrl.setNodeAirflow(node.id,
                (v == null || v <= 0) ? null : FlowRate.litersPerSecond(v)),
          ),
          // Manually chosen diffuser/grille FACE size + a face-velocity warning.
          // Lets the engineer pick a size for aesthetics and be told when the
          // velocity is too high (noisy) or too low (poor throw / dumping).
          if (node.airflow != null ||
              node.component == NodeComponent.supplyDiffuser ||
              node.component == NodeComponent.returnGrille ||
              node.component == NodeComponent.exhaustGrille ||
              node.component == NodeComponent.linearDiffuser) ...[
            const SizedBox(height: MechXSpacing.sm),
            Text('Diffuser / grille face size',
                style: context.type.caption
                    .copyWith(color: context.colors.textMuted)),
            const SizedBox(height: MechXSpacing.xs),
            Wrap(
              spacing: MechXSpacing.xs,
              runSpacing: MechXSpacing.xs,
              children: [
                _Pill(
                  label: 'Auto',
                  selected:
                      node.faceWidthMm == null || node.faceHeightMm == null,
                  onTap: () => ctrl.setNodeFace(node.id, null, null),
                ),
                for (final face in standardGrilleFacesMm)
                  _Pill(
                    label: '${face.$1.round()}x${face.$2.round()}',
                    selected: node.faceWidthMm == face.$1 &&
                        node.faceHeightMm == face.$2,
                    onTap: () => ctrl.setNodeFace(node.id, face.$1, face.$2),
                  ),
              ],
            ),
            const SizedBox(height: MechXSpacing.xs),
            Builder(builder: (context) {
              final check = ref.watch(airVelocityChecksProvider)[node.id];
              if (check == null) {
                // No face chosen yet — the face-size pills above are the
                // affordance; nothing to coach here.
                return const SizedBox.shrink();
              }
              return Text(
                'Face velocity: ${check.message}',
                style: context.type.caption.copyWith(
                  color: check.isWarning
                      ? context.colors.danger
                      : context.colors.accent,
                ),
              );
            }),
          ],
          ],
          if (showRoofArea) ...[
          const SizedBox(height: MechXSpacing.sm),
          Text('Rainwater outlet roof area',
              style: context.type.caption
                  .copyWith(color: context.colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          SteppedValueField(
            display: node.roofAreaM2 == null
                ? '—'
                : '${node.roofAreaM2!.toStringAsFixed(0)} m2',
            label: 'Rainwater outlet roof area',
            editSeed: node.roofAreaM2 == null
                ? ''
                : node.roofAreaM2!.toStringAsFixed(0),
            gap: MechXSpacing.sm,
            min: 0,
            onDecrement: () {
              final a = (node.roofAreaM2 ?? 0) - 50;
              ctrl.setNodeRoofArea(node.id, a <= 0 ? null : a);
            },
            onIncrement: () =>
                ctrl.setNodeRoofArea(node.id, (node.roofAreaM2 ?? 0) + 50),
            onSubmit: (v) =>
                ctrl.setNodeRoofArea(node.id, (v == null || v <= 0) ? null : v),
          ),
          ],
        ],
        // E2: placement (role + mounting height) is rarely changed once a node
        // is placed, so it is demoted below the identity into a collapsed
        // disclosure — every control preserved, just regrouped.
        const SizedBox(height: MechXSpacing.sm),
        DisclosureSection(
          name: 'Placement',
          defaultExpanded: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: MechXSpacing.xs,
                runSpacing: MechXSpacing.xs,
                children: [
                  for (final r in NodeRole.values)
                    _Pill(
                      label: _roleLabel(r),
                      selected: node.role == r,
                      onTap: () => ctrl.setNodeRole(node.id, r),
                    ),
                ],
              ),
              // Per-node mounting height — "how high on the wall" this
              // fixture/outlet sits above its own floor. Drives the vertical
              // pipe/cable run to it (§10). Shown in cm; "default" = the role's
              // standard height.
              const SizedBox(height: MechXSpacing.sm),
              Text('Mounting height (above floor)',
                  style: context.type.caption
                      .copyWith(color: context.colors.textMuted)),
              const SizedBox(height: MechXSpacing.xs),
              Row(
                children: [
                  SteppedValueField(
                    display: node.mountHeight == null
                        ? 'default'
                        : '${(node.mountHeight!.meters * 100).round()} cm',
                    label: 'Mounting height',
                    editSeed: node.mountHeight == null
                        ? ''
                        : (node.mountHeight!.meters * 100).round().toString(),
                    gap: MechXSpacing.sm,
                    min: 0,
                    onDecrement: () {
                      final base = node.mountHeight?.meters ??
                          const MountingHeights().fixtureHeight.meters;
                      final next = base - 0.05;
                      // Stepping down through floor level reverts to the role
                      // default.
                      ctrl.setNodeMountHeight(
                          node.id, next <= 0 ? null : Length(next));
                    },
                    onIncrement: () {
                      final base = node.mountHeight?.meters ??
                          const MountingHeights().fixtureHeight.meters;
                      ctrl.setNodeMountHeight(node.id, Length(base + 0.05));
                    },
                    // The typed value is in cm (the displayed unit); store as
                    // metres. A non-positive / empty entry reverts to the role
                    // default.
                    onSubmit: (v) => ctrl.setNodeMountHeight(node.id,
                        (v == null || v <= 0) ? null : Length(v / 100)),
                  ),
                  if (node.mountHeight != null) ...[
                    const SizedBox(width: MechXSpacing.sm),
                    MechXButton(
                      label: 'Reset',
                      tertiary: true,
                      onPressed: () => ctrl.setNodeMountHeight(node.id, null),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: MechXSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: MechXButton(
            label: 'Delete node',
            onPressed: () {
              ctrl.deleteNode(node.id);
              selCtrl.clear();
            },
          ),
        ),
      ],
    );
  }

  Widget _edgeEditor(BuildContext context, WidgetRef ref, NetEdge edge,
      Network net, NetworkController ctrl, SelectionController selCtrl) {
    final project = ref.watch(projectControllerProvider);
    final sizing = ref.watch(sizingProvider)[edge.id];
    final len = edgeLength(
      edge,
      net,
      calibrationBySheet: project.calibrations,
      building: project.building,
    ).meters;
    final kind = edge.kind == EdgeKind.riser ? 'Riser / drop' : 'Run';
    final sizeStr = sizing == null
        ? '—'
        : '${edge.service.regime == FlowRegime.air ? 'Ø' : 'DN'}'
            '${sizing.diameter.inMillimeters.round()}';
    final material = edgeMaterialLabel(edge);
    // Per-segment duct sheet-material takeoff (developed m² + standard sheets)
    // and the ducting accessories (covering angle / gasket / hangers / bolts).
    final takeoff =
        sizing == null ? null : ductSheetTakeoff(edge, sizing, len);
    final accessories =
        sizing == null ? null : computeDuctAccessories(edge, sizing, len);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$kind · ${len.toStringAsFixed(2)} m · $sizeStr'
            '${edge.sizeOverride != null ? ' (set)' : ''}',
            // L2: length/size track the drag live — tabular digits.
            style: MechXTypography.tabular(context.type.caption
                .copyWith(color: context.colors.textMuted))),
        // E3: the editable controls (size / material / service) lead; the
        // read-only procurement takeoff is demoted into the "Details" disclosure
        // below. These use the SAME setters the right-click menu does — the
        // "Auto" size step clears the override; "Default"/"Auto" material falls
        // back to the service default.
        const SizedBox(height: MechXSpacing.sm),
        Text('Size',
            style:
                context.type.caption.copyWith(color: context.colors.textMuted)),
        const SizedBox(height: MechXSpacing.xs),
        // E6: a compact stepper replaces the inline ~11-pill Ø/DN ladder.
        _sizeStepper(
          fieldKey: const ValueKey('edge-size-stepper'),
          isAir: edge.service.isAir,
          current: edge.sizeOverride,
          onSet: (d) => ctrl.setEdgeSizeOverride(edge.id, d),
        ),
        // Air-duct velocity check (warns too-high / too-low for the chosen
        // size) — live feedback attached to the size control above.
        if (edge.service.isAir && sizing != null) ...[
          const SizedBox(height: MechXSpacing.xxs),
          Builder(builder: (context) {
            final check = ref.watch(airVelocityChecksProvider)[edge.id];
            final msg = check?.message ??
                '${sizing.velocity.metersPerSecond.toStringAsFixed(1)} m/s';
            return Text(
              'Air velocity: $msg',
              // L2: the m/s readout tracks the live sizing.
              style: MechXTypography.tabular(context.type.caption.copyWith(
                color: (check != null && check.isWarning)
                    ? context.colors.danger
                    : context.colors.textSecondary,
              )),
            );
          }),
        ],
        // I3 — water / drainage velocity vs the SNI max pipe-velocity band. The
        // auto-sizer sizes TO this limit (SNI 03-7065-2005 caps supply at
        // 2,0 m/s), but the resulting velocity was previously invisible for
        // non-air pipes. Surface it with the SAME verdict idiom the air path
        // uses so the engineer can certify the SNI velocity compliance live.
        if (!edge.service.isAir && sizing != null) ...[
          Builder(builder: (context) {
            final check = ref.watch(waterVelocityChecksProvider)[edge.id];
            if (check == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: MechXSpacing.xxs),
              child: Text(
                'Velocity: ${check.message}',
                // L2: the m/s readout tracks the live sizing.
                style: MechXTypography.tabular(context.type.caption.copyWith(
                  color: check.isWarning
                      ? context.colors.danger
                      : context.colors.textSecondary,
                )),
              ),
            );
          }),
        ],
        // Soft advisory: this air duct carries air but isn't manually sized yet.
        if (ref.watch(airUnsizedProvider).contains(edge.id)) ...[
          const SizedBox(height: MechXSpacing.xxs),
          Text('Auto-sized — no duct size chosen yet.',
              style: context.type.caption
                  .copyWith(color: context.colors.textMuted)),
        ],
        const SizedBox(height: MechXSpacing.sm),
        Text('Material',
            style:
                context.type.caption.copyWith(color: context.colors.textMuted)),
        const SizedBox(height: MechXSpacing.xs),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            if (edge.service.isAir) ...[
              _Pill(
                label: 'Auto',
                selected: edge.ductProduct == null,
                onTap: () => ctrl.setEdgeDuctProduct(edge.id, null),
              ),
              for (final p in DuctProduct.values)
                _Pill(
                  label: ductLabelFor(p),
                  selected: edge.ductProduct == p,
                  onTap: () => ctrl.setEdgeDuctProduct(edge.id, p),
                ),
            ] else ...[
              _Pill(
                label: 'Default',
                selected: edge.pipeProduct == null,
                onTap: () => ctrl.setEdgePipeProduct(edge.id, null),
              ),
              for (final p in PipeProduct.values)
                _Pill(
                  label: labelFor(p),
                  selected: edge.pipeProduct == p,
                  onTap: () => ctrl.setEdgePipeProduct(edge.id, p),
                ),
            ],
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            for (final s in kDrawServices)
              _ServiceChip(
                service: s,
                selected: edge.service == s,
                onTap: () => ctrl.setEdgeService(edge.id, s),
              ),
          ],
        ),
        // E3: read-only material echo + duct procurement takeoff (developed m²,
        // sheets, covering angle / gasket / hangers / bolts), tucked into a
        // collapsed "Details" disclosure so the editable controls above lead.
        // Only rendered when there's something to show.
        if (material != null || takeoff != null || accessories != null) ...[
          const SizedBox(height: MechXSpacing.sm),
          DisclosureSection(
            name: 'Details',
            defaultExpanded: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (material != null)
                  Text('Material: $material',
                      style: context.type.caption
                          .copyWith(color: context.colors.textSecondary)),
                if (takeoff != null) ...[
                  if (material != null)
                    const SizedBox(height: MechXSpacing.xxs),
                  Text(
                    'Sheet: ${takeoff.developedAreaM2.toStringAsFixed(2)} m2'
                    ' (perimeter x length) · '
                    '${takeoff.sheets} ${takeoff.product == DuctProduct.pu ? 'panel' : 'sheet'}'
                    '${takeoff.sheets == 1 ? '' : 's'} '
                    '@ ${takeoff.sheetAreaM2.toStringAsFixed(2)} m2 · '
                    '${takeoff.thicknessMm.toStringAsFixed(takeoff.product == DuctProduct.pu ? 0 : 2)} mm',
                    // L2: recomputes with the live edge length.
                    style: MechXTypography.tabular(context.type.caption
                        .copyWith(color: context.colors.textSecondary)),
                  ),
                ],
                if (accessories != null) ...[
                  const SizedBox(height: MechXSpacing.xxs),
                  Text(
                    'Accessories: ${accessories.flangeAngleM.toStringAsFixed(1)} m '
                    'covering angle · ${accessories.gasketM.toStringAsFixed(1)} m gasket'
                    ' · ${accessories.hangers} hanger'
                    '${accessories.hangers == 1 ? '' : 's'} · ${accessories.bolts} bolts',
                    // L2: recomputes with the live edge length.
                    style: MechXTypography.tabular(context.type.caption
                        .copyWith(color: context.colors.textSecondary)),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: MechXSpacing.sm),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            // (Size override is cleared by stepping "Size" down to Auto, E6.)
            MechXButton(
              label: 'Delete ${edge.kind == EdgeKind.riser ? 'riser' : 'run'}',
              onPressed: () {
                ctrl.deleteEdge(edge.id);
                selCtrl.clear();
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// A compact size stepper (E6) that replaces the inline ~11-pill Ø/DN ladder in
/// the single and batch edge editors — the ladder crowded a 272-px column. It
/// walks the SAME standard ladder (round-duct Ø in mm for air, NPS/DN for pipe)
/// with "Auto" (a null size override) sitting just below the smallest size, and
/// the value can be typed directly (snapped to the nearest ladder entry; an
/// empty entry ⇒ Auto). Every ladder size stays reachable and the apply intent
/// is unchanged — [onSet] wraps the same `setEdge(s)SizeOverride` the pills
/// called. [mixed] marks a multi-selection whose edges disagree: it shows
/// "Mixed", stepping down resets all to Auto and stepping up sets all to the
/// smallest size.
Widget _sizeStepper({
  required bool isAir,
  required Diameter? current,
  required void Function(Diameter?) onSet,
  bool mixed = false,
  Key? fieldKey,
  String label = 'Nominal size',
}) {
  final ladderMm = isAir
      ? standardDuctDiametersMm
      : <double>[for (final inches in npsInches) npsToMm(inches)];

  String labelForIndex(int i) =>
      isAir ? 'Ø${ladderMm[i].round()}' : npsLabel(npsInches[i]);
  String seedForIndex(int i) {
    if (isAir) return ladderMm[i].round().toString();
    final inches = npsInches[i];
    return inches == inches.roundToDouble()
        ? inches.round().toString()
        : inches.toString();
  }

  var idx = -1;
  if (!mixed && current != null) {
    final mm = current.inMillimeters;
    for (var i = 0; i < ladderMm.length; i++) {
      if ((ladderMm[i] - mm).abs() < 0.5) {
        idx = i;
        break;
      }
    }
  }

  final display = mixed ? 'Mixed' : (idx < 0 ? 'Auto' : labelForIndex(idx));
  final editSeed = (mixed || idx < 0) ? '' : seedForIndex(idx);

  VoidCallback? onDec;
  VoidCallback? onInc;
  if (mixed) {
    onDec = () => onSet(null); // → Auto
    onInc = () => onSet(Diameter.mm(ladderMm.first)); // → smallest
  } else if (idx < 0) {
    // Auto sits below the smallest size — can't step lower; stepping up enters
    // the ladder at the smallest standard size.
    onDec = null;
    onInc = () => onSet(Diameter.mm(ladderMm.first));
  } else {
    onDec = () => onSet(idx == 0 ? null : Diameter.mm(ladderMm[idx - 1]));
    onInc = idx >= ladderMm.length - 1
        ? null
        : () => onSet(Diameter.mm(ladderMm[idx + 1]));
  }

  return SteppedValueField(
    key: fieldKey,
    display: display,
    editSeed: editSeed,
    label: label,
    gap: MechXSpacing.sm,
    onDecrement: onDec,
    onIncrement: onInc,
    onSubmit: (v) {
      if (v == null) {
        onSet(null);
        return;
      }
      // The typed value is in the ladder's own unit (inches for pipe, mm for
      // air); snap it to the nearest standard size so the selectable set is
      // exactly the ladder the pills offered.
      final targetMm = isAir ? v : npsToMm(v);
      var best = 0;
      var bestErr = double.infinity;
      for (var i = 0; i < ladderMm.length; i++) {
        final err = (ladderMm[i] - targetMm).abs();
        if (err < bestErr) {
          bestErr = err;
          best = i;
        }
      }
      onSet(Diameter.mm(ladderMm[best]));
    },
  );
}

/// HVAC / duct sizing controls + fan duty readout (the air-path analogue of the
/// Network section).
class _HvacSection extends ConsumerWidget {
  const _HvacSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final settings = ref.watch(ductSettingsProvider);
    final ctrl = ref.read(ductSettingsProvider.notifier);
    final fan = ref.watch(ductFanProvider);
    final balance = ref.watch(airBalanceProvider);

    // The shared value-wins row (L1) — the label yields, the figure never
    // truncates.
    Widget kv(String k, String v) => _kvRow(context, k, v);

    return DisclosureSection(
      name: 'HVAC · ducting',
      // E1: expand only when air elements exist (a sized fan, or a supply/return
      // balance). A plumbing-only launch keeps a quiet collapsed header rather
      // than opening on a "Draw a duct network…" empty prompt.
      defaultExpanded: fan != null || balance != null,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            _Pill(
              label: 'Round',
              selected: settings.shape == DuctShape.round,
              onTap: () => ctrl.setShape(DuctShape.round),
            ),
            _Pill(
              label: 'Rectangular',
              selected: settings.shape == DuctShape.rectangular,
              onTap: () => ctrl.setShape(DuctShape.rectangular),
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.xs),
        Wrap(
          spacing: MechXSpacing.xs,
          runSpacing: MechXSpacing.xs,
          children: [
            _Pill(
              label: 'Velocity',
              selected: settings.method == DuctSizingMethod.velocity,
              onTap: () => ctrl.setMethod(DuctSizingMethod.velocity),
            ),
            _Pill(
              label: 'Equal friction',
              selected: settings.method == DuctSizingMethod.equalFriction,
              onTap: () => ctrl.setMethod(DuctSizingMethod.equalFriction),
            ),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        if (fan == null)
          Text('Draw a duct network and assign diffuser airflows.',
              style: type.caption.copyWith(color: colors.textMuted))
        else ...[
          // Promoted headline: fan total static + selected motor. Only rendered
          // once a fan exists, so the blank/golden launch is byte-identical.
          ResultCard(
            headline:
                '${fan.totalStaticPressure.pascals.toStringAsFixed(0)} Pa',
            label:
                'Fan static · ${fan.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW motor',
            verdict: 'sized',
            verdictColor: colors.success,
          ),
          const SizedBox(height: MechXSpacing.xs),
          // 'Fan static' + 'Fan motor' are the ResultCard headline/label above;
          // keep only the distinct supporting figures (H8 — no duplication).
          kv('Trunk airflow',
              '${fan.airflow.inLitersPerSecond.toStringAsFixed(0)} L/s'),
          kv('Fan power',
              '${fan.shaftPower.inKiloWatts.toStringAsFixed(2)} kW'),
        ],
        if (balance != null) ...[
          const SizedBox(height: MechXSpacing.xs),
          kv('Supply air', '${balance.supplyLps.toStringAsFixed(0)} L/s'),
          kv('Return air', '${balance.returnLps.toStringAsFixed(0)} L/s'),
          kv('Air balance', _balanceLabel(balance.supplyLps, balance.returnLps)),
        ],
      ],
    ),
    );
  }
}

String _balanceLabel(double supplyLps, double returnLps) {
  if (returnLps <= 0) return 'no return drawn';
  if (supplyLps <= 0) return 'exhaust only';
  final deltaPct = (supplyLps - returnLps) / supplyLps * 100;
  if (deltaPct.abs() < 1) return 'balanced';
  final sign = deltaPct > 0 ? '+' : '';
  return '$sign${deltaPct.toStringAsFixed(0)}% supply';
}

/// A compact selectable pill used by the selection editor (role / fixture).
/// Inline name field + Save button (E5): captures the current multi-selection
/// into a named reusable assembly. Stateful so the typed name persists across
/// rebuilds and clears after a save (a changing key re-seeds the field text).
class _SaveAssemblyField extends StatefulWidget {
  final void Function(String name) onSave;
  const _SaveAssemblyField({required this.onSave});

  @override
  State<_SaveAssemblyField> createState() => _SaveAssemblyFieldState();
}

class _SaveAssemblyFieldState extends State<_SaveAssemblyField> {
  String _name = '';
  int _gen = 0; // bumped on save to reset the field text

  void _save() {
    final name = _name.trim();
    if (name.isEmpty) return;
    widget.onSave(name);
    setState(() {
      _name = '';
      _gen++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: MechXTextField(
            key: ValueKey(_gen),
            value: _name,
            hint: 'Assembly name',
            onChanged: (s) => _name = s,
            onSubmitted: _save,
          ),
        ),
        const SizedBox(width: MechXSpacing.xs),
        MechXButton(label: 'Save block', onPressed: _save),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: MechXFocusRing(
        onActivated: onTap,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(
              // Compensate the heavier selected border so the pill never jumps.
              horizontal: MechXSpacing.sm - (selected ? 1 : 0),
              vertical: MechXSpacing.xs - (selected ? 1 : 0),
            ),
            decoration: BoxDecoration(
              color: selected ? colors.accentMuted : colors.surface,
              borderRadius: MechXRadii.control,
              border: Border.all(
                color: selected ? colors.accent : colors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Text(
              label,
              style: type.label.copyWith(
                color: selected ? colors.textPrimary : colors.textSecondary,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
