import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/zoning.dart' show DownfeedZoneStatic;
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/csv_text.dart' show excelCsv;
import 'package:mechx_engine/report/file_names.dart' show safeFileStem;
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/electrical/bom.dart' show faultSpecifiedKa;
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart'
    show SldDxfLayers, electricalSldToDxf;
import 'package:mechx_engine/report/electrical_pagination.dart'
    show electricalOverviewToPdf, electricalRiserToPdf;
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show electricalSldDetailToPdf, electricalSldToPdf;
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/mep_commercial.dart'
    show mepBomToCsv, mepQuotationToMarkdown;
import 'package:mechx_engine/report/mep_report.dart';
import 'package:mechx_engine/report/pdf_export.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart'
    show
        customFixturePlanTags,
        equipmentNodeTags,
        fixturePlanTags,
        planLegendSymbols,
        planEdgeElevationLabels,
        planSheetNotes;
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/standards/custom_fixture.dart' show CustomFixture;
import 'package:mechx_engine/report/report_pdf.dart';
import 'package:mechx_engine/report/report_strings.dart';
import 'package:mechx_engine/report/riser_tags.dart'
    show drawnWaterFeedEquipment, elementTags;
import 'package:mechx_engine/report/sld_export.dart'
    show sldSheetToDxf, sldSheetToPdf, sldSheetsToPdf;
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart'
    show standardDuctDiametersMm;
import 'package:mechx_engine/sizing/fan.dart' show FanDuty;
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/sizing/fire_standpipe.dart'
    show
        drawnStandpipeRiserCount,
        firePumpBasisVerifyChecklist,
        standpipeVerifyChecklist;
import 'package:mechx_engine/sizing/hot_water.dart' show hotWaterRecircVerifyChecklist;
import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
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
import '../widgets/locale_number.dart' show parseLocaleNumber;
import '../../store/inspector_store.dart';
import '../../store/assemblies_store.dart';
import '../../store/calibration_store.dart';
import '../../store/compliance_store.dart';
import '../../store/design_issues_store.dart';
import '../../store/document_control_store.dart';
import '../../store/electrical_feed.dart'
    show
        NodeLoadSource,
        acUnitShare,
        mepDutyBindingProvider,
        roomAirUnitDutiesProvider,
        nodeFedLoadsProvider;
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
import '../../store/selection_scope.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
import '../../store/snap_settings_store.dart';
import '../../store/solve_store.dart';
import '../canvas/edge_context_menu.dart' show npsLabel;
import '../canvas/segment_palette.dart';
import '../canvas/segment_symbols.dart';
import '../canvas/service_style.dart';
import '../electrical/electrical_export.dart'
    show
        adsFailedCircuitIds,
        breakerIcuKaByPanel,
        breakerKaByCircuit,
        containmentByCircuit,
        electricalLayoutSheetIds;
import '../../report/reference_grid_builder.dart';
import '../format/scale_format.dart';
import '../schematic/schematic_export.dart'
    show buildLiveRiserPages, buildLiveRiserSheet;
import '../shell/nav_rail.dart';
import '../strings/app_strings.dart';
import '../strings/plural.dart';
import 'disclosure_header.dart';
import 'feed_strategy_line.dart';
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
  // N16: the per-run sizing-basis schedule ('why DN32 not DN25') over the SAME
  // network the sizer solved, with real §10 lengths (runs via calibration,
  // risers via the project-mounting elevation delta).
  final net = ref.read(sizingNetworkProvider);
  final mounting = ref.read(mountingProvider);
  final runSchedule = buildRunSchedule(
    net: net,
    sizing: ref.read(sizingProvider),
    // Round 9 — the UBAP/DFU basis the sizer accumulated (was never passed,
    // so the issued schedule printed '—' in every FU cell).
    edgeFixtureUnits: ref.read(edgeFixtureUnitsProvider),
    edgeLengths: {
      for (final e in net.edges)
        e.id: edgeLength(
          e,
          net,
          calibrationBySheet: project.calibrations,
          building: project.building,
          mounting: mounting,
        ),
    },
    // Round 29 — run tags on the building's ground-relative levels.
    building: project.building,
  );

  // Round 12 (report-recompute-second-ahu-missing) — every drawn supply /
  // exhaust system with its OWN duty and the SAME tag the equipment schedule
  // prints (the schedule's per-root rows), so a second AHU is reported.
  final rs = reportStringsFor(ref);
  final scheduleData = gatherEquipmentScheduleData(ref);
  final scheduledFans = scheduleData.fans;
  // Round 17 — every drawn supply mover the schedule lists (root pump, zone
  // boosters, the transfer pump), with its tag + service; the HW recirc and
  // fire pumps have their own report sections.
  final movers = ref.read(supplyMoverDutiesProvider);
  final supplyPumps = [
    if (movers.isNotEmpty)
      for (final p in scheduleData.pumps)
        if (p.service == rs(RptStringKey.esSvcDomesticWater) ||
            p.service == rs(RptStringKey.esSvcTransferPump))
          (tag: p.tag ?? '', service: p.service, duty: p.duty),
  ];
  // Round 16 (regression-report-fire-pump-without-fire-service) — the SAME
  // drawn-fire-service gate [firePumpDutyProvider] applies: with no
  // sprinkler / hydrant pipe drawn the schedule and the MDP carry no fire
  // pump, so the report must not print one (or the standpipe / sprinkler
  // design it is rated on) either.
  final fireDrawn = net.edges.any((e) =>
      e.service == ServiceType.fireSprinkler ||
      e.service == ServiceType.fireHydrant);
  // Round 17 — each fire section is gated on ITS OWN drawn system: a
  // hydrant-only network printed a sprinkler design + remote-head check that
  // is not drawn, and the standpipe line rode a sprinkler-only network.
  final sprinklerDrawn =
      net.edges.any((e) => e.service == ServiceType.fireSprinkler);
  final hydrantDrawn =
      net.edges.any((e) => e.service == ServiceType.fireHydrant);
  // Round 29 — the governing hydrant system's design (friction-inclusive),
  // so the standpipe line agrees with the fire-pump rating beside it.
  final standpipe =
      hydrantDrawn ? ref.read(reportStandpipeDesignProvider) : null;
  final hwRecirc = ref.read(hotWaterRecircProvider);
  // Round 20 (drafting-visual-4-1) — the feed the report describes is the
  // DRAWN feed, on the same evidence as the riser sheet's `riserFeedNote`
  // (the two sheets of one submittal used to contradict each other): a
  // downfeed SETTING with no roof tank drawn is a booster (pump drawn) or a
  // direct-mains feed, and the booster head / gravity verdict / PRV zone
  // table — all solved from a VIRTUAL roof-level source — are not printed.
  // Round 30 (r2) — only WATER-network equipment is feed evidence (the
  // shared `drawnWaterFeedEquipment`, the inspector feed line / riser notes
  // use the same): a fire pump on the hydrant line or a sump pump on
  // drainage never makes the water feed 'Booster pump (no roof tank)'.
  final waterFeed = drawnWaterFeedEquipment(net);
  final hasRoofTank = waterFeed.hasRoofTank;
  final hasPump = waterFeed.hasPump;
  // Round 25 — the ONE drawn-feed predicate the inspector + Review share.
  final gravityDownfeed = ref.read(gravityDownfeedDrawnProvider);
  // Round 20 (hvac-3-4) — the HVAC trunk the report prints is a SCHEDULED
  // machine: a supply system rooted at a packaged AC is the AC's internal fan
  // (scheduled once, as its AC row), so the primary duty is the first
  // non-AC-rooted system — never the AC's fan while the scheduled AHU is
  // dropped — and null when every supply system is AC-rooted.
  final airRoots = ref.read(airSystemRootNodesProvider);
  bool acRoot(String? id) =>
      id != null && RoomArea.isAcComponent(net.nodeById(id)?.component);
  FanDuty? reportFan;
  if (!acRoot(airRoots.supply)) {
    reportFan = ref.read(ductFanProvider);
  } else {
    for (final e in ref.read(supplyFanDutiesByRootProvider).entries) {
      if (!acRoot(e.key)) {
        reportFan = e.value;
        break;
      }
    }
  }
  return CalcReportData(
    projectName: project.name,
    date: DateTime.now().toIso8601String().split('T').first,
    standardsName: profile.name,
    standardsRevision: profile.revision,
    // Round 12 (report-recompute-verify-items-incomplete) — every unverified
    // constant that drives a PRINTED number: the per-material H-W C / duct
    // roughness / BJLS gauges, and (when those lines print) the standpipe
    // allowance / η / residual and the HW-recirc loss / cp (golden rule 6).
    verifyItems: [
      ...profile.verifyChecklist,
      ...pipeProductsVerifyChecklist,
      ...ductProductsVerifyChecklist,
      // Round 21 — the Class I residual only when a standpipe is drawn; a
      // sprinkler-only pump still prints its allowance + η basis.
      if (hydrantDrawn)
        ...standpipeVerifyChecklist
      else if (fireDrawn)
        ...firePumpBasisVerifyChecklist,
      if (hwRecirc != null) ...hotWaterRecircVerifyChecklist,
    ],
    supplyFans: [
      for (final f in scheduledFans)
        if (f.service == rs(RptStringKey.esSvcMechVent))
          (tag: f.tag ?? '', duty: f.duty),
    ],
    exhaustFans: [
      for (final f in scheduledFans)
        if (f.service == rs(RptStringKey.esSvcExhaustVent))
          (tag: f.tag ?? '', duty: f.duty),
    ],
    building: project.building,
    mounting: mounting,
    runSchedule: runSchedule,
    feedStrategy: rs(strategy == FeedStrategy.upfeed
        ? RptStringKey.feedUpfeed
        : hasRoofTank
            ? RptStringKey.feedDownfeed
            : hasPump
                ? RptStringKey.feedBoosterNoTank
                : RptStringKey.feedDirectMains),
    targetResidual:
        SupplyDesignCriteria.recommended().targetFixtureResidualPressure,
    pump: ref.read(pumpDutyProvider),
    supplyPumps: supplyPumps,
    boosterHead: gravityDownfeed ? downfeed?.boosterHeadRequired : null,
    gravitySufficient:
        gravityDownfeed && (downfeed?.gravitySufficient ?? false),
    // mech-building-2 — the PRV zone table is a DOWNFEED design (compliant by
    // construction); on an upfeed it said nothing about the pump's real
    // lower-floor pressures (judged in Review instead), so it is not printed.
    // Round 22 (pressurized-3-1) — printed only when it holds a PRV station
    // (or an over-limit zone): a building the roof tank's own head keeps
    // under the limit needs no PRV and gets no invented zone pressures.
    zones: gravityDownfeed && _zoneTableNeeded(ref.read(zoneStaticsProvider))
        ? ref.read(zoneStaticsProvider)
        : const [],
    hotWaterRecirc: hwRecirc,
    additionalHotWaterRecirc: [
      for (final sys in ref.read(hotWaterRecircSystemsProvider).skip(1))
        sys.design,
    ],
    sprinkler: sprinklerDrawn ? ref.read(sprinklerDesignProvider) : null,
    standpipe: standpipe,
    sprinklerRemoteArea:
        sprinklerDrawn ? ref.read(sprinklerRemoteAreaProvider) : null,
    firePumpRating: fireDrawn ? ref.read(firePumpRatingProvider) : null,
    // Round 30 (report-parity-2-1) — each drawn fire system's own pump, under
    // the tag its schedule row / MDP way carry.
    fireSystems: fireDrawn
        ? [
            for (final (i, b) in ref.read(fireSystemBasesProvider).indexed)
              FireSystemReportLine(
                tag: (b.pumpIds.isEmpty
                        ? null
                        : equipmentNodeTags(net)[b.pumpIds.first]) ??
                    'FP-${(i + 1).toString().padLeft(2, '0')}',
                sprinklerOnly: b.sprinklerOnly,
                rating: b.rating,
              ),
          ]
        : const [],
    fan: reportFan,
    exhaustFan: ref.read(exhaustFanProvider),
    supplyAirflowLps: balance?.supplyLps ?? 0,
    returnAirflowLps: balance?.returnLps ?? 0,
    rainfallMmPerHr: ref.read(rainfallIntensityProvider),
    runoffCoefficient: ref.read(runoffCoefficientProvider),
    // Round 17 follow-up (gravity-3-6) — the laid slope + Manning basis every
    // collector size and drainage velocity in this report was sized on.
    drainageSlope: ref.read(drainageSlopeProvider),
    drainageManningN: const SizingContext().drainageManningN,
    drainageFillRatio: const SizingContext().drainageFillRatio,
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
  final effectiveFault = effectiveOriginFaultLevel(eProject,
      demand: eResult.supply.demandVa);
  return ElectricalCalcReportData(
    projectName: project.name,
    date: DateTime.now().toIso8601String().split('T').first,
    standardsName: eProfile.name,
    standardsRevision: eProfile.revision,
    standardsProvenance: eProfile.provenanceNote,
    project: eProject,
    result: eResult,
    powerOneLine: eAdvanced.powerOneLine,
    // Round 12 — the PUIL KHA / derating / Vd debt behind every printed cable
    // size, beside the advanced-study items.
    // Round 30 (report-parity-2-3) — the profile checklist goes through
    // with its verification TIER (the report prints it beside each value).
    verifyItems: eAdvanced.verifyItems,
    verifyChecklist: eProfile.verifyChecklist,
    // Round 12 (report-recompute-fault-basis-omitted) — the EFFECTIVE fault
    // level + clearing time the busbars were sized on (the same chain as
    // electricalResultProvider), with their provenance.
    originFaultLevelA: effectiveFault.amperes,
    faultLevelBasis: effectiveFault.basis,
    busbarClearingTimeS: effectiveBusbarClearingTimeS(eProject),
    revisions: ref.read(documentControlProvider).revisions,
    // R1 — the ISSUED report reads the SAME combined warning surface Review and
    // the compliance roll-up read (core sizing warnings + the advanced fault
    // study's selectivity / breaking-capacity / withstand / TT findings). Read
    // from `electricalAllWarningsProvider`, never either source directly.
    allWarnings: ref.read(electricalAllWarningsProvider),
    // Round 39 (elec-reports-parity-5) — every device's SPECIFIED breaking
    // capacity, the same maps the board schedule + BOM receive.
    incomerKaByPanelId: faultSpecifiedKa(eAdvanced.fault).incomers,
    breakerKaByCircuitId: faultSpecifiedKa(eAdvanced.fault).breakers,
  );
}

/// Shared export driver: the completeness GUARD + success/failure FEEDBACK that
/// wraps every export action. (1) If any sized edge resolves to zero geometric
/// length (an uncalibrated sheet carrying drawn runs — they size to ZERO
/// length), it raises a dismissible warning on [loadErrorProvider] and writes
/// NOTHING — the engineer must calibrate first, so the BOM / pressures / drawing
/// can't be silently wrong. (2) Otherwise it awaits [write] inside try/catch:
/// H3 — `write` is now TRI-STATE, because "cancelled" and "nothing to write"
/// used to be the same `false`, making an export with no imported plan a total
/// silent no-op (including the global **P** accelerator):
///
///  * `true`  — written ⇒ a transient "Exported `name`" confirmation pill;
///  * `false` — the user CANCELLED the file picker ⇒ deliberately silent;
///  * `null`  — there was NOTHING to write (no plan sheet imported yet) ⇒ a
///    visible "Nothing to export — import a plan first" error.
///
/// Any thrown error ⇒ a "Could not export `name`" warning. The success pill
/// reuses the same self-clearing mechanism as Save / Open / Import. Public so
/// every export surface (the riser drawing set in `schematic_export.dart`, the
/// electrical + commercial exports) routes through the SAME guard + feedback —
/// a `Future<bool> Function()` is a subtype of the declared
/// `Future<bool?> Function()`, so every existing writer keeps compiling and only
/// the ones that genuinely mean "nothing to write" return null.
///
/// The zero-length gate iterates only the MECHANICAL network, so a
/// pure-electrical project is never blocked; a project that also carries
/// uncalibrated mechanical runs is held back until the sheet is calibrated —
/// conservative, and correct for any deliverable that could embed those runs.
/// F4 — that blocker now NAMES the offending sheets (and points at the
/// locatable Review > Design issues surface) instead of a bare `N element(s)`.
///
/// BUSY FEEDBACK: while an export runs it is recorded in
/// [exportInFlightProvider] — a second trigger meanwhile is ignored — and once
/// the user has picked a file (`pickExportSave`) the status-bar busy pill reads
/// 'Exporting `name`...' until the write settles (cleared in `finally`, only if
/// it is still this export's message).
Future<void> runExportGuarded(
  WidgetRef ref, {
  required String name,
  required Future<bool?> Function() write,
}) async {
  // One export at a time: a repeated click / accelerator while a write is in
  // flight is a no-op, never a second dialog.
  if (ref.read(exportInFlightProvider) != null) return;
  final strings = MechXStringsData(ref.read(localeProvider));
  if (ref.read(exportHasZeroLengthEdgesProvider)) {
    final n = ref.read(zeroLengthSizedEdgeCountProvider);
    // F4 — name the SHEETS the offending runs sit on (the engineer's next
    // action is on one of them), and kill the '(s)' dev-speak via pluralCount.
    final sheetsState = ref.read(sheetsControllerProvider);
    final names = [
      for (final id in ref.read(zeroLengthSheetIdsProvider))
        sheetsState.sheetById(id)?.name ?? id,
    ];
    ref
        .read(loadErrorProvider.notifier)
        .set(
          strings.format(StringKey.exportZeroLengthBlockedTemplate, {
            'count': pluralCount(n, 'drawn element', 'drawn elements'),
            'sheets': names.isEmpty
                ? plural(n, 'the sheet', 'the sheets')
                : names.join(', '),
            'name': name,
          }),
        );
    return;
  }
  // Capture every notifier BEFORE the first await: if the widget that
  // started the export is disposed meanwhile (a closed palette / sheet), its
  // `ref` throws on use — the guard must still clear (review: a disposed ref
  // in `finally` left every later export silently ignored).
  final inFlight = ref.read(exportInFlightProvider.notifier);
  final busy = ref.read(busyProvider.notifier);
  final errors = ref.read(loadErrorProvider.notifier);
  final status = ref.read(statusMessageProvider.notifier);
  final exported = ref.read(reportExportedProvider.notifier);
  inFlight.set(name);
  try {
    final wrote = await write();
    if (wrote == null) {
      // H3 — nothing to write is a REPORTABLE state, not a silent cancel.
      errors.set(
        strings.format(StringKey.exportNothingToExportTemplate, {
          'name': name,
        }),
      );
      return;
    }
    if (wrote) {
      status.showStatus('Exported $name');
      // The stepper's Report stage is DONE only once a deliverable actually
      // exists — this one line covers every export routed through here.
      exported.markExported();
    }
  } catch (e) {
    errors.set('Could not export $name: $e');
  } finally {
    inFlight.set(null);
    // Clear the pill only if it is still OURS (a nested writer — the
    // submittal package — may have replaced and cleared it already).
    busy.clearIf(exportBusyMessage(strings, name));
  }
}

/// The busy-pill text for an export named [name].
String exportBusyMessage(MechXStringsData strings, String name) =>
    strings.format(StringKey.busyExporting, {'name': name});

/// H4 — a save-dialog wrapper that REMEMBERS the last export directory: it opens
/// the OS picker at the shared `lastExportDirProvider` folder (so a session's
/// exports converge on one place), normalizes the chosen path to end in [ext],
/// and records the folder so the next dialog re-opens there. Returns null when
/// the user cancels.
///
/// I1 — this is now the ONE save-dialog seam: every export in the app routes
/// through it (the electrical set, the mechanical riser set, the commercial
/// BOM/proposal and the project Save-As included), so a revision re-opens where
/// the last one was written instead of re-navigating the OS picker per file.
///
/// [initialDirectory] overrides the remembered folder for the rare dialog with a
/// better-informed starting point (the project Save-As starts beside the file
/// the project was loaded from). Null — the default — keeps the shared memory.
/// The chosen folder is recorded either way, so the memory converges.
Future<String?> pickExportSave(
  WidgetRef ref, {
  required String dialogTitle,
  required String fileName,
  required String ext,
  String? initialDirectory,
}) async {
  final path = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    // Round 13 (export-files-1) — the suggested name embeds the free-text
    // project / sheet name; '/' ':' '?' … are not legal in a file name.
    fileName: safeFileStem(fileName, fallback: 'export.$ext'),
    type: FileType.custom,
    allowedExtensions: [ext],
    initialDirectory: initialDirectory ?? ref.read(lastExportDirProvider),
  );
  if (path == null) return null;
  final full = path.endsWith('.$ext') ? path : '$path.$ext';
  ref.read(lastExportDirProvider.notifier).rememberFile(full);
  // The file is chosen — the slow part (building + writing the artifact)
  // starts now, so an export in flight raises the busy pill.
  final exporting = ref.read(exportInFlightProvider);
  if (exporting != null) {
    ref.read(busyProvider.notifier).set(exportBusyMessage(
        MechXStringsData(ref.read(localeProvider)), exporting));
  }
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
///
/// R2 — this is the app's ONLY BOM CSV export, and it used to carry its own
/// hand-rolled column set: it omitted the `material` column (a cutting crew
/// could not tell PPR from PVC on the takeoff) and the I5 `manual` (`*`)
/// override marker, and its size column was the pipe-implying `nominal_dn_mm`.
/// It now DELEGATES the takeoff columns to the engine's own [bomToCsv] — the
/// one source of that format, including its two CONDITIONAL columns (`floor`
/// when any line is floor-grouped, trailing `manual` when any line is a manual
/// override) — and appends the three cut-plan columns to each row. The two CSVs
/// can no longer disagree about what a BOM line is.
///
/// Header (floor-grouped, no manual override — the normal app export):
/// `service,kind,tag,floor,nominal_size_mm,material,length_m,segments,`
/// `stock_length_m,bars_purchased,waste_pct`
String bomCsvWithCutPlan(List<BomLine> bom, List<PipeCutGroup> cutPlan) {
  // Joined per (service, DN, MATERIAL) — each material is its own bar pool.
  final planByKey = <({ServiceType service, int mm, String mat}), PipeCutGroup>{
    for (final g in cutPlan)
      (service: g.service, mm: g.diameterMm, mat: g.material): g,
  };
  final emitted = <({ServiceType service, int mm, String mat})>{};
  // The engine CSV: a header row + one row per BOM line, in the SAME order.
  final base = bomToCsv(bom).split('\n');
  final buffer = StringBuffer()
    ..write(base.first)
    ..write(',stock_length_m,bars_purchased,waste_pct\n');
  for (var i = 0; i < bom.length; i++) {
    final line = bom[i];
    var key = (service: line.service, mm: line.diameterMm, mat: line.material);
    if (!planByKey.containsKey(key)) {
      key = (service: line.service, mm: line.diameterMm, mat: ''); // legacy
    }
    final g = planByKey[key];
    // The cut plan is a (service, DN, material) property (all runs of a size share
    // stock bars), so it is emitted ONCE per group — sum-safe — and left empty
    // on the rest, and empty when the plan has no entry (a riser-only DN, an
    // air duct: never invented).
    final showPlan = g != null && emitted.add(key);
    buffer
      ..write(base[i + 1])
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

    final full = await pickExportSave(
      ref,
      dialogTitle: MechXStringsData(ref.read(localeProvider))(
        StringKey.exportTitleCalcReport,
      ),
      fileName: '${project.name}-report.md',
      ext: 'md',
    );
    if (full == null) return false;
    await File(
      full,
    ).writeAsString(buildCalcReportMarkdown(data, reportStringsFor(ref)));
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
      RptFigure(
        buildLiveRiserSheet(ref, null),
        caption: reportStringsFor(ref)(RptStringKey.capMechRiser),
      ),
    ];
    final bytes = reportBlocksToPdf(
      blocks,
      docTitle: reportStringsFor(ref)(RptStringKey.docCalcReport),
      projectName: project.name.isEmpty
          ? reportStringsFor(ref)(RptStringKey.untitledProject)
          : project.name,
      documentNumber: doc.documentNumber,
      revisionTag: doc.revisionTag,
      dateString: data.date,
      standardsLine: '${data.standardsName} (${data.standardsRevision})',
      preparedBy: doc.preparedBy,
      checkedBy: doc.checkedBy,
      approvedBy: doc.approvedBy,
      strings: reportStringsFor(ref),
    );
    final base = project.name.isEmpty ? 'project' : project.name;
    final full = await pickExportSave(
      ref,
      dialogTitle: MechXStringsData(ref.read(localeProvider))(
        StringKey.exportTitleCalcReportPdf,
      ),
      fileName: '$base-report.pdf',
      ext: 'pdf',
    );
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
    final full = await pickExportSave(
      ref,
      dialogTitle: MechXStringsData(ref.read(localeProvider))(
        StringKey.exportTitleMepReport,
      ),
      fileName: '$base-mep-report.md',
      ext: 'md',
    );
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
      RptHeading(1, reportStringsFor(ref)(RptStringKey.headingDrawings)),
      RptFigure(
        buildLiveRiserSheet(ref, null),
        caption: reportStringsFor(ref)(RptStringKey.capMechRiser),
      ),
      RptFigure(
        buildElectricalSld(
          project: ref.read(electricalProjectProvider),
          result: ref.read(electricalResultProvider),
          breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
          breakerKaByCircuitId: breakerKaByCircuit(ref),
          adsFailedCircuitIds: adsFailedCircuitIds(ref),
          containmentByCircuitId: containmentByCircuit(ref),
        ),
        caption: reportStringsFor(ref)(RptStringKey.capElecSld),
      ),
    ];
    final bytes = reportBlocksToPdf(
      blocks,
      docTitle: reportStringsFor(ref)(RptStringKey.docMepReport),
      projectName: project.name.isEmpty
          ? reportStringsFor(ref)(RptStringKey.untitledProject)
          : project.name,
      documentNumber: doc.documentNumber,
      revisionTag: doc.revisionTag,
      dateString: mechanical.date,
      standardsLine:
          '${mechanical.standardsName} (${mechanical.standardsRevision})'
          ' / ${electrical.standardsName} ${electrical.standardsRevision}',
      preparedBy: doc.preparedBy,
      checkedBy: doc.checkedBy,
      approvedBy: doc.approvedBy,
      strings: reportStringsFor(ref),
    );

    final base = project.name.isEmpty ? 'project' : project.name;
    final full = await pickExportSave(
      ref,
      dialogTitle: MechXStringsData(ref.read(localeProvider))(
        StringKey.exportTitleMepReportPdf,
      ),
      fileName: '$base-mep-report.pdf',
      ext: 'pdf',
    );
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
///
/// When that natural `AHU-NN` collides with a tag the plan already prints
/// beside a DRAWN unit ([usedNodeTags], from `equipmentNodeTags`), the room's
/// fallback is namespaced `AHU-RNN` so the schedule never names two different
/// units the same (audit r8 coupling-3). Node tags never contain `R`, and room
/// ids are unique, so the namespaced tag is unique too.
String _roomScheduleTag(
  RoomArea room,
  int fallbackIndex, {
  Set<String> usedNodeTags = const {},
}) {
  final m = RegExp(r'(\d+)$').firstMatch(room.id);
  final n = m != null ? int.parse(m.group(1)!) + 1 : fallbackIndex + 1;
  final nn = n.toString().padLeft(2, '0');
  final natural = 'AHU-$nn';
  return usedNodeTags.contains(natural) ? 'AHU-R$nn' : natural;
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
  // drafting-7: the schedule keys each row by the SAME stable tag the plan /
  // canvas / DXF / riser print beside the drawn unit (`equipmentNodeTags`, the
  // node-identity numbering), so plan, riser, schedule and BOM cross-reference.
  // A hard-coded `P-01` only matched when the pump happened to be node n0. The
  // fixed tag stays the fallback when no such unit is drawn.
  final net = ref.read(networkControllerProvider).network;
  final nodeTags = equipmentNodeTags(net);
  String? tagOfFirst(bool Function(NetNode n) pick) {
    for (final n in net.nodes) {
      if (pick(n) && nodeTags[n.id] != null) return nodeTags[n.id];
    }
    return null;
  }

  // Which services a node's incident edges carry (a pump node has no service
  // of its own — the supply booster sits on water, the fire pump on fire).
  Set<ServiceType> servicesAt(String id) => {
    for (final e in net.edges)
      if (e.fromId == id || e.toId == id) e.service,
  };
  bool isPumpNode(NetNode n) =>
      n.component == NodeComponent.pump ||
      n.component == NodeComponent.boosterSet;
  // Both picks need a POSITIVE service match: an unpiped pump (no incident
  // edges yet — e.g. a fire pump dropped but not connected) is neither the
  // domestic booster nor the fire pump, so it can never steal either row's
  // tag; the fixed fallback applies until it is piped.
  bool onFire(NetNode n) => servicesAt(
    n.id,
  ).any((s) => s == ServiceType.fireHydrant || s == ServiceType.fireSprinkler);
  bool onWater(NetNode n) => servicesAt(
    n.id,
  ).any((s) => s == ServiceType.coldWater || s == ServiceType.hotWater);

  // The drawn plant node each solved duty is rooted at — the SAME binding the
  // MEP→electrical feed uses, so a schedule tag, the plan tag and the panel
  // way all name one machine (audit r8 coupling-2/3).
  final binding = ref.read(mepDutyBindingProvider);
  String? tagOfNode(String? id) => id == null ? null : nodeTags[id];

  // Pumps: the domestic-supply booster (upfeed) + the standpipe fire pump.
  final pumps = <PumpScheduleItem>[];
  // Round 16 — ONE row per drawn supply mover with a solved duty (the root /
  // main pump, every zone booster, the transfer pump), each under its own
  // plan tag; the single legacy row stays for the undrawn upfeed pump.
  final movers = ref.read(supplyMoverDutiesProvider);
  final transfers = ref.read(transferPumpNodeIdsProvider);
  var pumpOrdinal = 0;
  String nextPumpTag() {
    String t;
    do {
      pumpOrdinal++;
      t = 'P-${pumpOrdinal.toString().padLeft(2, '0')}';
    } while (nodeTags.values.contains(t));
    return t;
  }

  final moverIds = movers.keys.toList()..sort();
  for (final id in moverIds) {
    final tag = tagOfNode(id) ?? nextPumpTag();
    pumps.add(
      PumpScheduleItem(
        duty: movers[id]!,
        service: reportStringsFor(ref)(transfers.contains(id)
            ? RptStringKey.esSvcTransferPump
            : RptStringKey.esSvcDomesticWater),
        tag: tag,
        modelSpec: specs[tag],
      ),
    );
  }
  final supplyPump = movers.isEmpty ? ref.read(pumpDutyProvider) : null;
  if (supplyPump != null) {
    final tag = tagOfNode(binding.supplyPumpNodeId) ??
        tagOfFirst((n) => isPumpNode(n) && onWater(n) && !onFire(n)) ??
        'P-01';
    pumps.add(
      PumpScheduleItem(
        duty: supplyPump,
        service: reportStringsFor(ref)(RptStringKey.esSvcDomesticWater),
        tag: tag,
        modelSpec: specs[tag],
      ),
    );
  }
  // Round 30 (mech-sim-4-ejector-pump-no-duty-no-schedule) — one row per
  // drawn sewage ejector, under its plan tag, on the duty its MDP way is fed.
  // Round 31 — a duplex STANDBY ejector is the duty ejector's machine,
  // designated '(standby)' (its MDP way carries demand factor 0).
  final ejectors = ref.read(ejectorDutiesProvider);
  for (final id in ejectors.keys.toList()..sort()) {
    final tag = tagOfNode(id) ?? nextPumpTag();
    final dutyId = binding.ejectorStandbyPumpNodeIds[id];
    pumps.add(PumpScheduleItem(
      duty: ejectors[dutyId ?? id] ?? ejectors[id]!,
      service: reportStringsFor(ref)(dutyId != null
          ? RptStringKey.esSvcSewageEjectorStandby
          : RptStringKey.esSvcSewageEjector),
      tag: tag,
      modelSpec: specs[tag],
    ));
  }
  // Round 16 (plumbing-plant-recirc-pump-not-bound) — the HW recirculation
  // pump the inspector and the report print, scheduled under the drawn HW
  // pump's tag (else HWP-01) — the same duty the panel way is fed on.
  // Round 26 (hot-water-2-separate-systems-merged) — one row per hot-water
  // system, under the pump drawn on THAT system (else HWP-0n).
  final recircSystems = ref.read(hotWaterRecircSystemsProvider);
  for (var i = 0; i < recircSystems.length; i++) {
    final sys = recircSystems[i];
    if (sys.design.pump.selectedMotor.watts <= 0) continue;
    final onSys = [
      for (final id in binding.hwRecircPumpNodeIds)
        if (sys.nodeIds.contains(id)) id,
    ]..sort();
    final tag = tagOfNode(onSys.isEmpty ? null : onSys.first) ??
        'HWP-${(i + 1).toString().padLeft(2, '0')}';
    pumps.add(
      PumpScheduleItem(
        duty: sys.design.pump,
        service: reportStringsFor(ref)(RptStringKey.esSvcHwRecirc),
        tag: tag,
        modelSpec: specs[tag],
      ),
    );
  }
  // The ONE fire-pump duty (NFPA 20 motor) shared with the electrical feed.
  final firePump = ref.read(firePumpDutyProvider);
  if (firePump != null) {
    // Round 17 follow-up — a sprinkler-rated pump (no hydrant drawn) is a
    // SPRINKLER pump, never 'Pompa hidran kebakaran'.
    final fireService = reportStringsFor(ref)(
        ref.read(fireRatedPointProvider).sprinklerOnly
            ? RptStringKey.esSvcFireSprinkler
            : RptStringKey.esSvcFireStandpipe);
    // Round 21 (fire-3-parallel-fire-pumps-each-full-duty) — ONE row per
    // DRAWN fire pump, each under its own plan tag and the duty its panel way
    // is fed on (the standby at the full motor, the jockey at its pressure-
    // maintenance duty), so the schedule and the MDP agree on the count.
    final drawn = [
      for (final n in net.nodes)
        if (isPumpNode(n) && onFire(n) && nodeTags[n.id] != null) n.id,
    ]..sort();
    if (drawn.isEmpty) {
      pumps.add(PumpScheduleItem(
        duty: firePump,
        service: fireService,
        tag: 'FP-01',
        modelSpec: specs['FP-01'],
      ));
    }
    final jockeyDuty = ref.read(fireJockeyDutyProvider);
    // Round 28 — each drawn pump on the duty and service of its OWN fire
    // system (a sprinkler pump on its own network is a sprinkler pump).
    final bases = ref.read(firePumpBasisByNodeProvider);
    for (final id in drawn) {
      final tag = nodeTags[id]!;
      final jockey = binding.fireJockeyPumpNodeIds.contains(id);
      final basis = bases[id];
      final mainDuty = basis?.duty ?? firePump;
      final sysService = basis == null
          ? fireService
          : reportStringsFor(ref)(basis.sprinklerOnly
              ? RptStringKey.esSvcFireSprinkler
              : RptStringKey.esSvcFireStandpipe);
      pumps.add(PumpScheduleItem(
        duty: jockey
            ? (basis?.jockey ?? jockeyDuty ?? mainDuty)
            : mainDuty,
        service: jockey
            ? reportStringsFor(ref)(RptStringKey.esSvcFireJockeyPump)
            : binding.fireStandbyPumpNodeIds.contains(id)
                ? reportStringsFor(ref)(RptStringKey.esSvcFireStandbyPump)
                : sysService,
        tag: tag,
        modelSpec: specs[tag],
      ));
    }
  }

  // Fans: the drawn supply/return duct fan + the separate exhaust fan.
  final fans = <FanScheduleItem>[];
  final airRoots = ref.read(airSystemRootNodesProvider);
  bool onService(NetNode n, ServiceType s) => servicesAt(n.id).contains(s);
  // Round 16 — a packaged AC unit rooting its own ducts is scheduled ONCE,
  // as its AC row (below); its internal fan is not a separate machine.
  bool acRoot(String? id) =>
      id != null && RoomArea.isAcComponent(net.nodeById(id)?.component);
  final ductFan = acRoot(airRoots.supply) ? null : ref.read(ductFanProvider);
  if (ductFan != null) {
    // The unit the supply (else return) duct system is ROOTED at carries this
    // duty — never the exhaust fan's tag (audit r8 coupling-3).
    final tag = tagOfNode(airRoots.supply) ??
        tagOfFirst(
          (n) =>
              (n.component == NodeComponent.supplyFan ||
                  n.component == NodeComponent.ahu) &&
              (onService(n, ServiceType.duct) ||
                  onService(n, ServiceType.returnAir)),
        ) ??
        'F-01';
    fans.add(
      FanScheduleItem(
        duty: ductFan,
        service: reportStringsFor(ref)(RptStringKey.esSvcMechVent),
        tag: tag,
        modelSpec: specs[tag],
      ),
    );
  }
  // Round 11 (hvac-network-4) — every OTHER drawn supply / return system (a
  // second AHU on another floor) is scheduled with its OWN solved duty, tagged
  // after its root unit (else the next free F-nn).
  var fanOrdinal = fans.length;
  String nextFanTag(String prefix) {
    fanOrdinal++;
    return '$prefix-${fanOrdinal.toString().padLeft(2, '0')}';
  }

  for (final e in ref.read(supplyFanDutiesByRootProvider).entries) {
    if (e.key == airRoots.supply || acRoot(e.key)) continue;
    final tag = tagOfNode(e.key) ?? nextFanTag('F');
    fans.add(
      FanScheduleItem(
        duty: e.value,
        service: reportStringsFor(ref)(RptStringKey.esSvcMechVent),
        tag: tag,
        modelSpec: specs[tag],
      ),
    );
  }
  final exhaustFan = ref.read(exhaustFanProvider);
  if (exhaustFan != null) {
    // The exhaust system's ROOT fan's plan tag; 'EF-01' only when none drawn.
    final tag = tagOfNode(airRoots.exhaust) ??
        tagOfFirst((n) =>
            n.component == NodeComponent.exhaustFan &&
            onService(n, ServiceType.exhaust)) ??
        'EF-01';
    fans.add(
      FanScheduleItem(
        duty: exhaustFan,
        service: reportStringsFor(ref)(RptStringKey.esSvcExhaustVent),
        tag: tag,
        modelSpec: specs[tag],
      ),
    );
  }
  var exOrdinal = 1;
  for (final e in ref.read(exhaustFanDutiesByRootProvider).entries) {
    if (e.key == airRoots.exhaust) continue;
    exOrdinal++;
    final tag =
        tagOfNode(e.key) ?? 'EF-${exOrdinal.toString().padLeft(2, '0')}';
    fans.add(
      FanScheduleItem(
        duty: e.value,
        service: reportStringsFor(ref)(RptStringKey.esSvcExhaustVent),
        tag: tag,
        modelSpec: specs[tag],
      ),
    );
  }

  // Air-handling: each drawn ROOM's AHU/FCU equipment duty (FanDuty) — only
  // when that unit EXISTS: an AHU/FCU node drawn in the room, or a room with
  // neither AC units nor an air network (the room-air sizing is then the only
  // statement of its air handling). A room served by AC units schedules THOSE
  // units instead (below), so every scheduled unit has exactly one electrical
  // way and vice versa (audit r8 coupling-6).
  final rooms = ref.read(roomAreasProvider);
  final usedNodeTags = nodeTags.values.toSet();
  // Round 27 (hvac-4-3) — a room's own row is dropped only when a drawn,
  // sized system actually reaches ITS terminals ([roomServedByDrawnAir]),
  // never because some duct exists elsewhere in the project.
  final sizedEdgeIds = ref.read(sizingProvider).keys.toSet();
  final roomAirUnits = ref.read(roomAirUnitDutiesProvider);
  final roomSizing = ref.read(roomSizingProvider);
  for (var i = 0; i < rooms.length; i++) {
    final r = rooms[i];
    final sizing = roomSizing[r.id];
    if (sizing == null) continue;
    // Round 11 (hvac-network-2) — an EXTRACT room (toilet / kitchen) is served
    // by an exhaust fan, never an AHU/FCU: scheduled as an EF row (stable per
    // room identity) unless a drawn exhaust system already carries its duty.
    if (sizing.extractOnly) {
      if (roomServedByDrawnAir(r, rooms, net, sizedEdgeIds, extract: true)) {
        continue;
      }
      final ahuTag = _roomScheduleTag(r, i, usedNodeTags: usedNodeTags);
      final tag = ahuTag.replaceFirst('AHU-', 'EF-R');
      fans.add(
        FanScheduleItem(
          duty: sizing.equipment,
          service: r.name,
          tag: tag,
          modelSpec: specs[tag],
        ),
      );
      continue;
    }
    // Round 20 (hvac-3-2) — the units this room OWNS (smallest containing
    // room). A drawn AHU / FCU that carries a SOLVED duct duty is already
    // scheduled by its duty row (same tag), so the room-air row is emitted
    // only for the unit [roomAirUnitDutiesProvider] gives the room duty to —
    // the very unit the panel feed sizes on it.
    final drawnUnit = net.nodes.any((n) =>
        (n.component == NodeComponent.ahu ||
            n.component == NodeComponent.fcu) &&
        roomUnitOwnerId(n, rooms) == r.id);
    final hasAc = net.nodes.any((n) =>
        RoomArea.isAcComponent(n.component) &&
        roomUnitOwnerId(n, rooms) == r.id);
    final roomAirUnitId = [
      for (final e in roomAirUnits.entries)
        if (e.value.room.id == r.id) e.key,
    ].firstOrNull;
    if (drawnUnit && roomAirUnitId == null) continue;
    if (!drawnUnit &&
        (hasAc ||
            roomServedByDrawnAir(r, rooms, net, sizedEdgeIds,
                extract: false))) {
      continue;
    }
    // J3: the AHU tag tracks the room's STABLE identity, not its live list
    // position — deleting / reordering / skipping (uncalibrated) another room
    // never renumbers this unit, so a procured AHU-03 stays AHU-03 across
    // revisions ([_roomScheduleTag]).
    // drafting-7: an AHU/FCU node DRAWN inside the room carries the plan tag;
    // the room-identity tag stays the fallback for a room with no drawn unit.
    final tag = tagOfNode(roomAirUnitId) ??
        _roomScheduleTag(r, i, usedNodeTags: usedNodeTags);
    fans.add(
      FanScheduleItem(
        duty: sizing.equipment,
        service: r.name,
        tag: tag,
        modelSpec: specs[tag],
        airHandling: true,
      ),
    );
  }

  // Placed AC units — one row each, on the SAME per-unit share + input the
  // electrical feed sizes its panel way on ([acUnitShare]).
  final method = ref.read(coolingLoadMethodProvider);
  double? mppFor(String sheetId) =>
      project.calibrationFor(sheetId)?.metersPerPixel;
  final acUnits = <AcScheduleItem>[];
  for (final n in net.nodes) {
    if (!RoomArea.isAcComponent(n.component)) continue;
    final share = acUnitShare(net, rooms, mppFor, n, method: method);
    if (share == null) continue;
    final tag = nodeTags[n.id] ?? 'AC-${(acUnits.length + 1).toString().padLeft(2, '0')}';
    acUnits.add(AcScheduleItem(
      tag: tag,
      service: '${share.room.name} · ${n.component!.label}',
      coolingBtuPerHr: share.btuPerHr,
      pk: share.unit.pk,
      inputW: share.inputW,
      modelSpec: specs[tag],
    ));
  }

  // Round 25 — every drawn storage tank, under its plan tag, so the TK-nn the
  // riser / plans print reaches the procurement schedule (the BOM leaves
  // plant out as scheduled equipment).
  final tanks = <TankScheduleItem>[];
  var tankOrdinal = 0;
  for (final n in net.nodes) {
    if (n.component != NodeComponent.roofTank &&
        n.component != NodeComponent.groundTank) {
      continue;
    }
    tankOrdinal++;
    tanks.add(TankScheduleItem(
      tag: nodeTags[n.id] ?? 'TK-${tankOrdinal.toString().padLeft(2, '0')}',
      roof: n.component == NodeComponent.roofTank,
      capacityLitres: n.tankCapacityLitres,
    ));
  }

  return EquipmentScheduleData(
    projectName: project.name,
    date: DateTime.now().toIso8601String().split('T').first,
    pumps: pumps,
    fans: fans,
    acUnits: acUnits,
    tanks: tanks,
    electrical: ref.read(electricalResultProvider),
    // N22 (app half): the source apparatus (transformer / standby genset /
    // PF-correction bank) the electrical project may carry, so the schedule
    // no longer omits the highest-value long-lead items on the source spine.
    electricalProject: ref.read(electricalProjectProvider),
    // N23 (residual): the engineer-entered model/spec for the PANEL + apparatus
    // rows (pumps/fans carry their own per-item override above), keyed by the
    // panel tag/name + the fixed TX-01/G-01/CB-01 apparatus tags.
    modelSpecs: specs,
    // Round 41 — the study's PF result, so the schedule lists the
    // recommended APFC bank the BOM buys (one capacitor-bank source).
    powerFactor: ref.read(electricalAdvancedProvider).powerFactor,
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
/// being present ([hasMechanicalEquipmentTargets]) — so merely seeding an
/// electrical project's panels never SURFACES this mechanical-inspector section
/// (a blank-mechanical launch stays byte-identical); the panel/apparatus rows
/// ride along only once the section is already shown for real mechanical duty.
List<({String tag, String service})> equipmentSpecTargets(WidgetRef ref) {
  final data = gatherEquipmentScheduleData(ref);
  const apparatus = {
    EquipmentCategory.panel,
    EquipmentCategory.transformer,
    EquipmentCategory.generator,
    EquipmentCategory.capacitorBank,
    EquipmentCategory.distributedSource,
  };
  return [
    for (final p in data.pumps) (tag: p.tag!, service: p.service),
    for (final f in data.fans) (tag: f.tag!, service: f.service),
    for (final a in data.acUnits) (tag: a.tag, service: a.service),
    for (final r in buildEquipmentScheduleRows(data))
      if (apparatus.contains(r.category)) (tag: r.tag, service: r.service),
  ];
}

/// Whether the equipment model/spec section should be SHOWN — true only when
/// the project carries sized MECHANICAL equipment (a pump or fan/AHU). The
/// electrical panel/apparatus rows are additive detail once shown; they never
/// surface the section on their own (keeps the goldens' seeded-electrical launch
/// byte-identical).
bool hasMechanicalEquipmentTargets(WidgetRef ref) {
  final data = gatherEquipmentScheduleData(ref);
  return data.pumps.isNotEmpty ||
      data.fans.isNotEmpty ||
      data.acUnits.isNotEmpty;
}

/// Watch every provider [equipmentSpecTargets]'s tag/service derivation reads
/// (it — like the export gather it shares — READS rather than watches), so a
/// surface listing the spec targets shows/hides and stays live as the
/// pump/fan/room duties and the electrical panels change.
void watchEquipmentSpecInputs(WidgetRef ref) {
  ref.watch(projectControllerProvider);
  ref.watch(pumpDutyProvider);
  ref.watch(standpipeDesignProvider);
  ref.watch(ductFanProvider);
  ref.watch(ductSettingsProvider);
  ref.watch(roomAreasProvider);
  ref.watch(sizingNetworkProvider);
  ref.watch(exhaustFanProvider);
  ref.watch(coolingLoadMethodProvider);
  ref.watch(electricalResultProvider);
  ref.watch(electricalProjectProvider);
}

/// The number of equipment model/spec edit targets to SHOW — 0 unless the
/// project carries sized mechanical equipment (the
/// [hasMechanicalEquipmentTargets] gate), so seeding an electrical project's
/// panels alone never surfaces the editor. Watches its inputs.
int visibleEquipmentSpecTargetCount(WidgetRef ref) {
  watchEquipmentSpecInputs(ref);
  if (!hasMechanicalEquipmentTargets(ref)) return 0;
  return equipmentSpecTargets(ref).length;
}

Future<bool> _writeEquipmentSchedule(WidgetRef ref) async {
  final project = ref.read(projectControllerProvider);
  final data = gatherEquipmentScheduleData(ref);

  final base = project.name.isEmpty ? 'project' : project.name;
  final full = await pickExportSave(
    ref,
    dialogTitle: MechXStringsData(ref.read(localeProvider))(
      StringKey.exportTitleEquipmentSchedule,
    ),
    fileName: '$base-equipment-schedule.md',
    ext: 'md',
  );
  if (full == null) return false;
  // Write the Markdown at the chosen path plus a spreadsheet CSV sibling
  // (D5: the row model was designed for a CSV emitter). The engineer picks
  // one name; both files land beside it (the BOM export's dual-file pattern).
  final stem = full.substring(0, full.length - 3);
  await File(
    '$stem.md',
  ).writeAsString(buildEquipmentScheduleMarkdown(data, reportStringsFor(ref)));
  await File(
    '$stem.csv',
  ).writeAsString(excelCsv(equipmentScheduleToCsv(
        buildEquipmentScheduleRows(data, reportStringsFor(ref)))));
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
      docTitle: reportStringsFor(ref)(RptStringKey.docEquipSchedule),
      projectName: project.name.isEmpty
          ? reportStringsFor(ref)(RptStringKey.untitledProject)
          : project.name,
      documentNumber: doc.documentNumber,
      revisionTag: doc.revisionTag,
      dateString: data.date,
      preparedBy: doc.preparedBy,
      checkedBy: doc.checkedBy,
      approvedBy: doc.approvedBy,
      strings: reportStringsFor(ref),
    );
    final base = project.name.isEmpty ? 'project' : project.name;
    final full = await pickExportSave(
      ref,
      dialogTitle: MechXStringsData(ref.read(localeProvider))(
        StringKey.exportTitleEquipmentSchedulePdf,
      ),
      fileName: '$base-equipment-schedule.pdf',
      ext: 'pdf',
    );
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
  // Round 33 — the plan's sheet NOTES printed once in its legend (the same
  // chrome feeds `planSheetPlot`, the plan PDF and the plan DXF, so all three
  // reserve the same legend box): the fixture codes used on this floor, the
  // floor-relative CL datum (the riser sheet states ABSOLUTE levels) and the
  // per-DN drain-fall rule.
  final project = ref.read(projectControllerProvider);
  final floors = project.building.floors;
  final hasCl = planEdgeElevationLabels(net, project.building,
          mounting: ref.read(mountingProvider))
      .keys
      .any((id) {
    final e = net.edgeById(id);
    return e != null && (onFloor(e.fromId) || onFloor(e.toId));
  });
  final notes = planSheetNotes(
    net: net,
    sheetId: sheetId,
    floorIndex: floorIndex,
    fixtureTags: fixturePlanTags(net,
        sheetId: sheetId,
        floorIndex: floorIndex,
        nodeTags:
            planExportNodeTags(net, ref.read(fixtureLibraryProvider))),
    hasCentrelineLabels: hasCl,
    floorFflM: floorIndex >= 0 && floorIndex < floors.length
        ? project.building.elevationOf(floorIndex).meters
        : null,
    floorName: floorIndex >= 0 && floorIndex < floors.length
        ? floors[floorIndex].name
        : null,
    gravitySlope: ref.read(drainageSlopeProvider),
    sizing: ref.read(sizingProvider),
    // Round 34 — the sprinkler head basis (K-factor + hazard class).
    sprinklerKFactor: ref.read(firePerHeadKFactorProvider),
    sprinklerHazard: switch (ref.read(fireHazardProvider)) {
      FireHazardClass.lightHazard => 'light hazard',
      FireHazardClass.ordinaryHazard1 => 'ordinary hazard 1',
      FireHazardClass.ordinaryHazard2 => 'ordinary hazard 2',
      FireHazardClass.extraHazard => 'extra hazard',
    },
  );
  return DrawingChrome(
    sheetIndex: idx >= 0 ? idx + 1 : null,
    sheetTotal: sheets.isNotEmpty ? sheets.length : null,
    legendServices: legend,
    legendNotes: notes,
    // Round 34 — the symbol key: every component glyph on this floor.
    legendSymbols:
        planLegendSymbols(net, sheetId: sheetId, floorIndex: floorIndex),
    // N19: the plan's drawing number is DERIVED per sheet — the mechanical plan
    // band `M-1xx`, running by RAIL POSITION — so sheet 1 is `M-101`, sheet 2
    // `M-102`, never one number on every plan. A manual `documentNumber`
    // becomes the PREFIX (`<documentNumber>-<series><index>`, e.g.
    // `BRI-MEP-01-M-101`); only the cover keeps the bare base.
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

/// Export the current sheet/floor's drawn network as a DXF drawing file.
Future<void> exportDrawingDxf(WidgetRef ref) => runExportGuarded(
  ref,
  name: 'DXF drawing',
  write: () => _writeDrawingDxf(ref),
);

Future<bool?> _writeDrawingDxf(WidgetRef ref) async {
  final sheets = ref.read(sheetsControllerProvider);
  final sheet = sheets.current;
  // H3 — NOTHING TO WRITE (no plan sheet imported yet) is not a user
  // cancel: null makes the guard raise a visible error instead of a no-op.
  if (sheet == null) return null;
  final project = ref.read(projectControllerProvider);
  final levelCount = project.building.levelCount;
  final floorIndex = sheets.floorFor(sheet.id, levelCount);
  // A1: the floor-plan underlay — DXF sheets only here (the R12 re-emit is
  // vector-only; a PDF-backed sheet's raster rides the PDF exports instead).
  final planUnderlay = sheet.dxfPath != null
      ? await buildPlanUnderlay(sheet)
      : null;
  final net = ref.read(networkControllerProvider).network;
  final chrome = issuableChrome(ref, sheetId: sheet.id, floorIndex: floorIndex);
  final metersPerPixel = project.calibrationFor(sheet.id)?.metersPerPixel;
  final grid = buildReferenceGrid(ref.read(referenceLinesProvider), sheet.id);
  final dxf = networkToDxf(
    net: net,
    sizing: ref.read(sizingProvider),
    sheetId: sheet.id,
    floorIndex: floorIndex,
    // The same §10 lengths the plan PDF prints, so the DXF labels match it.
    edgeLengths: projectEdgeLengths(net, project),
    chrome: chrome,
    // A2: the sheet calibration lets the DXF emit true-scale mm world units
    // (HEADER/$INSUNITS + named layers); null keeps the legacy pixel DXF.
    metersPerPixel: metersPerPixel,
    // Round 14 (drafting-visual-5) — the ISO title block's PROJECT row.
    projectName: project.name,
    // R6: plotted exactly like the sheet's plan PDF (its `1 : N` + frame
    // limits), so the shared annotation layout makes the PDF's label choices.
    sheetPlot: planSheetPlot(
      net: net,
      sheetId: sheet.id,
      floorIndex: floorIndex,
      projectName: project.name,
      sheetName: sheet.name,
      dateString: DateTime.now().toIso8601String().split('T').first,
      chrome: chrome,
      metersPerPixel: metersPerPixel,
      underlay: sheet.dxfPath != null
          ? planUnderlay
          : await buildPlanUnderlay(sheet),
      grid: grid,
    ),
    underlay: planUnderlay is VectorPlanUnderlay ? planUnderlay : null,
    // N5: the §10 centreline-height token folded into each run's size label.
    edgeElevationLabels: planEdgeElevationLabels(
      net,
      project.building,
      mounting: ref.read(mountingProvider),
    ),
    // N13: the stable element tag (`CW-R1` / `CW-F2`) on each run/riser so the
    // plan DXF traces to the same element the riser + BOM + report carry.
    edgeTags: elementTags(net, building: project.building),
    // N4/B12: the setting-out grid from axis-aligned traced reference lines.
    grid: grid,
    // G1: the stable equipment tags (P-01 / TK-01 / AHU-01 …) beside each plant
    // glyph, and G5: the laid gravity fall (1:N) folded into gravity-run size
    // labels — the same tokens the on-canvas plan shows, now on the issued DXF.
    nodeTags: planExportNodeTags(net, ref.read(fixtureLibraryProvider)),
    // H5: the LAID design slope the sizer + the report actually used
    // (`drainageSlopeProvider`), never the dark `SizingContext` default — the
    // issued sheet must not contradict the signed report (see the contract note
    // at `plan_symbols.dart` `gravitySlopeLabel`).
    gravitySlope: ref.read(drainageSlopeProvider),
  );
  final full = await pickExportSave(
    ref,
    dialogTitle: MechXStringsData(ref.read(localeProvider))(
      StringKey.exportTitleDrawingDxf,
    ),
    fileName: '${sheet.name}.dxf',
    ext: 'dxf',
  );
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

Future<bool?> _writeDrawingPdf(WidgetRef ref) async {
  final sheets = ref.read(sheetsControllerProvider);
  final sheet = sheets.current;
  // H3 — NOTHING TO WRITE (no plan sheet imported yet) is not a user
  // cancel: null makes the guard raise a visible error instead of a no-op.
  if (sheet == null) return null;
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
    nodeTags: planExportNodeTags(net, ref.read(fixtureLibraryProvider)),
    // H5: the LAID design slope the sizer + the report actually used
    // (`drainageSlopeProvider`), never the dark `SizingContext` default — the
    // issued sheet must not contradict the signed report (see the contract note
    // at `plan_symbols.dart` `gravitySlopeLabel`).
    gravitySlope: ref.read(drainageSlopeProvider),
  );
  final full = await pickExportSave(
    ref,
    dialogTitle: MechXStringsData(ref.read(localeProvider))(
      StringKey.exportTitleDrawingPdf,
    ),
    fileName: '${sheet.name}.pdf',
    ext: 'pdf',
  );
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

Future<bool?> _writeAnnotatedPlanPdf(WidgetRef ref) async {
  final sheets = ref.read(sheetsControllerProvider);
  final sheet = sheets.current;
  // H3 — NOTHING TO WRITE (no plan sheet imported yet) is not a user
  // cancel: null makes the guard raise a visible error instead of a no-op.
  if (sheet == null) return null;
  final project = ref.read(projectControllerProvider);
  final levelCount = project.building.levelCount;
  final floorIndex = sheets.floorFor(sheet.id, levelCount);
  final net = ref.read(networkControllerProvider).network;

  // Real length per edge from the §10 sources of truth (run via calibration,
  // riser via the elevation delta).
  final edgeLengths = projectEdgeLengths(net, project);

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
    edgeElevationLabels: planEdgeElevationLabels(
      net,
      project.building,
      mounting: ref.read(mountingProvider),
    ),
    // N13: the stable element tag (`CW-R1` / `CW-F2`) prepended to each label so
    // the plan traces to the same element the riser + BOM + report carry.
    edgeTags: elementTags(net, building: project.building),
    // N4/B12: axis-aligned traced reference lines become the setting-out grid
    // (vertical → lettered columns, horizontal → numbered rows); diagonal ones
    // are snap-only. Empty ⇒ no grid drawn (byte-identical).
    grid: buildReferenceGrid(ref.read(referenceLinesProvider), sheet.id),
    // G1: stable equipment tags (P-01 / TK-01 / AHU-01 …) beside each plant
    // glyph, and G5: the laid gravity fall (1:N) on gravity-run size labels —
    // the same tokens the on-canvas plan shows, now on the issued plan PDF.
    nodeTags: planExportNodeTags(net, ref.read(fixtureLibraryProvider)),
    // H5: the LAID design slope the sizer + the report actually used
    // (`drainageSlopeProvider`), never the dark `SizingContext` default — the
    // issued sheet must not contradict the signed report (see the contract note
    // at `plan_symbols.dart` `gravitySlopeLabel`).
    gravitySlope: ref.read(drainageSlopeProvider),
  );
  final full = await pickExportSave(
    ref,
    dialogTitle: MechXStringsData(ref.read(localeProvider))(
      StringKey.exportTitleAnnotatedPlanPdf,
    ),
    fileName: '${sheet.name}-annotated.pdf',
    ext: 'pdf',
  );
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
  final removed = <String>[];
  final ok = await writeSubmittalPackageToDir(ref, dir, removedOut: removed);
  if (ok && removed.isNotEmpty) {
    // export-files-3 — say that superseded files were pruned (the guard's
    // own 'Exported …' pill would otherwise be the only cue). Deferred to
    // the next event so it lands after the guard's generic confirmation.
    final text = MechXStringsData(ref.read(localeProvider)).format(
      StringKey.exportSubmittalStaleRemovedTemplate,
      {'count': '${removed.length}'},
    );
    Future<void>.delayed(
      Duration.zero,
      () => ref.read(statusMessageProvider.notifier).showStatus(text),
    );
  }
  return ok;
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
///
/// Round 13 — (export-files-1) every FILE name is built from [safeFileStem] of
/// the project / sheet name (the raw names still print in the title blocks),
/// so `Ruko A/B` or `Proyek: Tahap 1` can no longer throw mid-package or hide
/// the set in an NTFS stream; (export-files-3) after writing, any file in
/// [dir] that belongs to THIS project's package (`<stem>-<package suffix>`)
/// but was not written by this run — a superseded sheet from an earlier
/// revision — is deleted, so the folder holds exactly the set the new cover
/// lists. The removed paths are appended to [removedOut] when given.
@visibleForTesting
Future<bool> writeSubmittalPackageToDir(
  WidgetRef ref,
  String dir, {
  List<String>? removedOut,
}) async {
  final project = ref.read(projectControllerProvider);
  final base = project.name.trim().isEmpty ? 'project' : project.name.trim();
  final fileBase = safeFileStem(base);
  final strings = reportStringsFor(ref);
  final doc = ref.read(documentControlProvider);
  final today = DateTime.now().toIso8601String().split('T').first;
  final sep = Platform.pathSeparator;
  final written = <String>{};
  String out(String suffix) {
    final path = '$dir$sep$fileBase-$suffix';
    written.add(path);
    return path;
  }

  // N19: the riser single-line and the electrical single-line in the package
  // are DIFFERENT drawings, so each derives its own number by [series] (the
  // mechanical riser `M-201`, the electrical detail `E-201`) rather than sharing
  // one `documentNumber` verbatim.
  DrawingChrome sldChrome(DrawingSeries series) => DrawingChrome(
    sheetIndex: 1,
    sheetTotal: 1,
    drawingNumber: sheetDrawingNumber(base: doc.documentNumber, series: series),
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
  // export-files-2 — the sheets that carry an ELECTRICAL LAYOUT plan (placed
  // panels/loads), pre-collected so the k-th one is numbered E-10k with its
  // own SHEET k-of-n counter and listed on the Daftar Gambar (every elec plan
  // used to stamp E-101 / '1 of 1' and none was indexed).
  // Round 34 — the ONE list the standalone layout export numbers by too.
  final elecPlanSheetIds = electricalLayoutSheetIds(ref);
  DrawingChrome elecPlanChrome(String sheetId) {
    final k = elecPlanSheetIds.indexOf(sheetId) + 1;
    return DrawingChrome(
      sheetIndex: k,
      sheetTotal: elecPlanSheetIds.length,
      drawingNumber: sheetDrawingNumber(
        base: doc.documentNumber,
        series: DrawingSeries.electricalLayout,
        index: k,
      ),
      revisionNumber: doc.revisionTag,
      clientName: doc.clientName,
      drawnBy: doc.preparedBy,
      checkedBy: doc.checkedBy,
      approvedBy: doc.approvedBy,
      dateString: today,
    );
  }

  final drawingList = <DrawingListEntry>[];
  for (final s in sheetsFm.sheets) {
    final fIdx = sheetsFm.floorFor(s.id, project.building.levelCount);
    final planChromeFm = issuableChrome(ref, sheetId: s.id, floorIndex: fIdx);
    drawingList.add(
      DrawingListEntry(
        number: planChromeFm.drawingNumber ?? '',
        // Round 14 (drafting-visual-6) — the SAME title the sheet's own title
        // block stamps ([drawingSeriesTitle]), so register == sheet.
        title: drawingSeriesTitle(DrawingSeries.mechanicalPlan,
            sheetName: s.name),
        revision: rev,
        date: today,
      ),
    );
  }
  for (final id in elecPlanSheetIds) {
    drawingList.add(
      DrawingListEntry(
        number: elecPlanChrome(id).drawingNumber ?? '',
        title: drawingSeriesTitle(DrawingSeries.electricalLayout,
            sheetName: sheetsFm.sheetById(id)?.name ?? id),
        revision: rev,
        date: today,
      ),
    );
  }
  drawingList.add(
    DrawingListEntry(
      number: sheetDrawingNumber(
        base: doc.documentNumber,
        series: DrawingSeries.mechanicalRiser,
      ),
      title: drawingSeriesTitle(DrawingSeries.mechanicalRiser),
      revision: rev,
      date: today,
    ),
  );
  // I2 — the electrical DRAWINGS bundled below each get their own Daftar Gambar
  // row (one row per DRAWING, not per format: a sheet issued as PDF + DXF is one
  // entry, exactly like the per-sheet plans above). The power one-line is listed
  // only when the project actually carries one to draw.
  final powerOneLineFm = ref.read(electricalAdvancedProvider).powerOneLine;
  final hasPowerOneLine =
      powerOneLineFm != null && powerOneLineFm.nodes.isNotEmpty;
  if (eResultFm.order.isNotEmpty) {
    drawingList.add(
      DrawingListEntry(
        number: sheetDrawingNumber(
          base: doc.documentNumber,
          series: DrawingSeries.electricalDetail,
        ),
        title: drawingSeriesTitle(DrawingSeries.electricalDetail),
        revision: rev,
        date: today,
      ),
    );
    drawingList.add(
      DrawingListEntry(
        number: sheetDrawingNumber(
          base: doc.documentNumber,
          series: DrawingSeries.electricalOverview,
        ),
        title: drawingSeriesTitle(DrawingSeries.electricalOverview),
        revision: rev,
        date: today,
      ),
    );
    drawingList.add(
      DrawingListEntry(
        number: sheetDrawingNumber(
          base: doc.documentNumber,
          series: DrawingSeries.electricalRiser,
        ),
        title: drawingSeriesTitle(DrawingSeries.electricalRiser),
        revision: rev,
        date: today,
      ),
    );
    if (hasPowerOneLine) {
      drawingList.add(
        DrawingListEntry(
          number: sheetDrawingNumber(
            base: doc.documentNumber,
            series: DrawingSeries.electricalPowerOneLine,
          ),
          title: drawingSeriesTitle(DrawingSeries.electricalPowerOneLine),
          revision: rev,
          date: today,
        ),
      );
    }
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
  await File(out('00-cover-sheets.pdf')).writeAsBytes(
    sldSheetsToPdf(
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
    ),
  );

  // ── Reports ───────────────────────────────────────────────────────────────
  final mech = buildMechanicalReportData(ref);
  final electrical = buildElectricalReportData(ref);
  final compliance = buildComplianceSummary(ref);

  await File(
    out('report.md'),
  ).writeAsString(buildCalcReportMarkdown(mech, strings));
  await File(out('report.pdf')).writeAsBytes(
    reportBlocksToPdf(
      [
        ...buildCalcReportBlocks(mech, strings),
        RptFigure(
          buildLiveRiserSheet(ref, null),
          caption: reportStringsFor(ref)(RptStringKey.capMechRiser),
        ),
      ],
      docTitle: reportStringsFor(ref)(RptStringKey.docCalcReport),
      projectName: base,
      documentNumber: doc.documentNumber,
      revisionTag: doc.revisionTag,
      dateString: mech.date,
      standardsLine: '${mech.standardsName} (${mech.standardsRevision})',
      preparedBy: doc.preparedBy,
      checkedBy: doc.checkedBy,
      approvedBy: doc.approvedBy,
      strings: reportStringsFor(ref),
    ),
  );

  await File(out('mep-report.md')).writeAsString(
    buildMepUnifiedReport(
      mechanical: mech,
      electrical: electrical,
      compliance: compliance,
      strings: strings,
    ),
  );
  await File(out('mep-report.pdf')).writeAsBytes(
    reportBlocksToPdf(
      [
        ...buildMepUnifiedReportBlocks(
          mechanical: mech,
          electrical: electrical,
          compliance: compliance,
          strings: strings,
        ),
        RptHeading(1, reportStringsFor(ref)(RptStringKey.headingDrawings)),
        RptFigure(
          buildLiveRiserSheet(ref, null),
          caption: reportStringsFor(ref)(RptStringKey.capMechRiser),
        ),
        RptFigure(
          buildElectricalSld(
            project: ref.read(electricalProjectProvider),
            result: ref.read(electricalResultProvider),
            breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
            breakerKaByCircuitId: breakerKaByCircuit(ref),
            adsFailedCircuitIds: adsFailedCircuitIds(ref),
            containmentByCircuitId: containmentByCircuit(ref),
          ),
          caption: reportStringsFor(ref)(RptStringKey.capElecSld),
        ),
      ],
      docTitle: reportStringsFor(ref)(RptStringKey.docMepReport),
      projectName: base,
      documentNumber: doc.documentNumber,
      revisionTag: doc.revisionTag,
      dateString: mech.date,
      standardsLine:
          '${mech.standardsName} (${mech.standardsRevision})'
          ' / ${electrical.standardsName} ${electrical.standardsRevision}',
      preparedBy: doc.preparedBy,
      checkedBy: doc.checkedBy,
      approvedBy: doc.approvedBy,
      strings: reportStringsFor(ref),
    ),
  );

  // ── Equipment schedule (MD + CSV + PDF) ─────────────────────────────────────
  final sched = gatherEquipmentScheduleData(ref);
  await File(
    out('equipment-schedule.md'),
  ).writeAsString(buildEquipmentScheduleMarkdown(sched, strings));
  await File(
    out('equipment-schedule.csv'),
  ).writeAsString(excelCsv(equipmentScheduleToCsv(
        buildEquipmentScheduleRows(sched, strings))));
  await File(out('equipment-schedule.pdf')).writeAsBytes(
    reportBlocksToPdf(
      buildEquipmentScheduleBlocks(sched, strings),
      docTitle: reportStringsFor(ref)(RptStringKey.docEquipSchedule),
      projectName: base,
      documentNumber: doc.documentNumber,
      revisionTag: doc.revisionTag,
      dateString: sched.date,
      preparedBy: doc.preparedBy,
      checkedBy: doc.checkedBy,
      approvedBy: doc.approvedBy,
      strings: reportStringsFor(ref),
    ),
  );

  // ── BOM (CSV) + costed quotation (MD) — the unified M+E+P pipeline ───────────
  final mechCost = ref.read(mechanicalCostProvider);
  final elecCost = ref.read(electricalCostProvider);
  await File(out('bom.csv'))
      .writeAsString(excelCsv(mepBomToCsv(mechCost, elecCost)));
  await File(out('quotation.md')).writeAsString(
    mepQuotationToMarkdown(
      ref.read(mepQuotationProvider),
      mechanical: mechCost,
      electrical: elecCost,
      projectName: base,
      strings: reportStringsFor(ref),
    ),
  );

  // ── Mechanical riser single-line (PDF + DXF) ────────────────────────────────
  // I2 — the DXF rides along: the riser is the one drawing a contractor most
  // often re-uses in CAD, and issuing it PDF-only forced a separate menu trip +
  // dialog every revision. One sheet build, both formats, one heading source
  // (`riserDiagramTitle`) so PDF and DXF can never disagree; the DXF lands on
  // the M-* layer namespace (N15).
  //
  // N2 — the title-block PROJECT row carries the LIVE name (null when the
  // project is genuinely unnamed, so nothing is fabricated), matching the
  // standalone riser exports rather than stamping 'Untitled project'.
  final titleProjectName = project.name.trim().isEmpty
      ? null
      : project.name.trim();
  final riserSheet = buildLiveRiserSheet(ref, null);
  // Round 21 (riser-drafting-2-2) — the issued PDF paginates a tall riser to
  // legible pages; the DXF below stays one sheet.
  final riserPages = buildLiveRiserPages(ref, null);
  await File(out('riser-sld.pdf')).writeAsBytes(
    riserPages.length == 1
        ? sldSheetToPdf(
            sheet: riserPages.single,
            title: 'iSystem mechanical single-line',
            diagramTitle: drawingSeriesTitle(DrawingSeries.mechanicalRiser),
            chrome: sldChrome(DrawingSeries.mechanicalRiser),
            projectName: titleProjectName,
          )
        : sldSheetsToPdf(
            riserPages,
            title: 'iSystem mechanical single-line',
            diagramTitle: drawingSeriesTitle(DrawingSeries.mechanicalRiser),
            chrome: sldChrome(DrawingSeries.mechanicalRiser),
            projectName: titleProjectName,
          ),
  );
  await File(out('riser-sld.dxf')).writeAsString(
    sldSheetToDxf(
      sheet: riserSheet,
      diagramTitle: drawingSeriesTitle(DrawingSeries.mechanicalRiser),
      chrome: sldChrome(DrawingSeries.mechanicalRiser),
      projectName: titleProjectName,
      layers: SldDxfLayers.mechanical,
    ),
  );

  // ── Every sheet's annotated plan (PDF + DXF) — J2: the whole rail, not just
  // whichever sheet happened to be active, so a multi-floor tender folder is
  // complete without manually switching sheets and re-exporting by hand. Each
  // sheet keeps its own drawing number (N19, by rail position) and filename.
  // Progress rides the shared busy pill; cleared in `finally` so a thrown
  // mid-loop error (a bad underlay, a disk error) never leaves it stuck.
  final planSheets = sheetsFm.sheets;
  final localeStrings = MechXStringsData(ref.read(localeProvider));
  // Round 14 (drafting-visual-7) — every plan of ONE set is issued at ONE
  // plotted scale: the largest natural `1 : N` over the calibrated sheets
  // floors each sheet's snap, so a sparse floor no longer plots at 1 : 50
  // beside a dense 1 : 100 of the same building (overlaying floors, riser
  // positions and setting-out then need no re-scaling).
  final planUnderlays = <String, PlanUnderlay?>{};
  int? sharedPlanScale;
  {
    final net0 = ref.read(networkControllerProvider).network;
    for (final sheet in planSheets) {
      final underlay = await buildPlanUnderlay(sheet);
      planUnderlays[sheet.id] = underlay;
      final natural = planSheetPlot(
        net: net0,
        sheetId: sheet.id,
        floorIndex: sheetsFm.floorFor(sheet.id, project.building.levelCount),
        projectName: base,
        sheetName: sheet.name,
        dateString: today,
        chrome: issuableChrome(
          ref,
          sheetId: sheet.id,
          floorIndex: sheetsFm.floorFor(sheet.id, project.building.levelCount),
        ),
        metersPerPixel: project.calibrationFor(sheet.id)?.metersPerPixel,
        underlay: underlay,
        grid: buildReferenceGrid(ref.read(referenceLinesProvider), sheet.id),
      )?.scaleDenominator;
      if (natural != null && natural > 0) {
        sharedPlanScale =
            sharedPlanScale == null || natural > sharedPlanScale
                ? natural
                : sharedPlanScale;
      }
    }
  }
  try {
    for (var i = 0; i < planSheets.length; i++) {
      final sheet = planSheets[i];
      ref
          .read(busyProvider.notifier)
          .set(
            localeStrings.format(StringKey.busyExportingSubmittal, {
              'current': '${i + 1}',
              'total': '${planSheets.length}',
            }),
          );
      final levelCount = project.building.levelCount;
      final floorIndex = sheetsFm.floorFor(sheet.id, levelCount);
      final net = ref.read(networkControllerProvider).network;
      final sizing = ref.read(sizingProvider);
      // Round 14 (drafting-visual-6) — the plan's title block stamps the
      // register title ([drawingSeriesTitle]).
      final planChrome = issuableChrome(
        ref,
        sheetId: sheet.id,
        floorIndex: floorIndex,
      ).withTitle(
        drawingSeriesTitle(DrawingSeries.mechanicalPlan, sheetName: sheet.name),
      );
      final metersPerPixel = project.calibrationFor(sheet.id)?.metersPerPixel;
      final underlay = planUnderlays.containsKey(sheet.id)
          ? planUnderlays[sheet.id]
          : await buildPlanUnderlay(sheet);
      final edgeLengths = projectEdgeLengths(net, project);
      // N5: the §10 centreline-height token folded into each run's size label.
      final elevationLabels = planEdgeElevationLabels(
        net,
        project.building,
        mounting: ref.read(mountingProvider),
      );
      // N13: the stable element tags shared by both plan formats + the reports.
      final tags = elementTags(net, building: project.building);
      // N4/B12: the setting-out grid from axis-aligned traced reference lines,
      // shared by both plan formats.
      final grid = buildReferenceGrid(
        ref.read(referenceLinesProvider),
        sheet.id,
      );
      // G1/G5: the equipment tags + gravity fall, shared by both plan formats
      // (the same tokens the on-canvas plan shows).
      final nodeTags =
          planExportNodeTags(net, ref.read(fixtureLibraryProvider));
      // H5: the LAID design slope from `drainageSlopeProvider` (the Building
      // page input the sizer + calc report already honour), so every bundled
      // submittal sheet stamps the SAME fall the report signs off on.
      final gravitySlope = ref.read(drainageSlopeProvider);
      // One file per sheet, numbered by rail position so a multi-floor bundle
      // never collides (`project-plan-1-Ground Floor.pdf`, `-2-Level 1.pdf`…).
      final suffix =
          'plan-${i + 1}-${safeFileStem(sheet.name, fallback: 'sheet')}';
      await File(out('$suffix.pdf')).writeAsBytes(
        planToPdf(
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
          minScaleDenominator: sharedPlanScale,
        ),
      );
      await File(out('$suffix.dxf')).writeAsString(
        networkToDxf(
          net: net,
          sizing: sizing,
          edgeLengths: edgeLengths,
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
          // Round 14 (drafting-visual-5) — the ISO title block's PROJECT row.
          projectName: base,
          // R6: plotted exactly like the PDF beside it, so both carry the
          // same label splits + slots.
          sheetPlot: planSheetPlot(
            net: net,
            sheetId: sheet.id,
            floorIndex: floorIndex,
            projectName: base,
            sheetName: sheet.name,
            dateString: today,
            chrome: planChrome,
            metersPerPixel: metersPerPixel,
            underlay: underlay,
            grid: grid,
            minScaleDenominator: sharedPlanScale,
          ),
        ),
      );
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
        // Round 46 — boards placed nowhere are listed once, on the first
        // layout sheet; every other note is scoped to its own sheet.
        listUnhomedUnplaced:
            elecPlanSheetIds.isEmpty || elecPlanSheetIds.first == sheet.id,
      );
      if (!ePlan.isEmpty) {
        final eChrome = elecPlanChrome(sheet.id).withTitle(
          drawingSeriesTitle(DrawingSeries.electricalLayout,
              sheetName: sheet.name),
        );
        await File(out('elec-$suffix.pdf')).writeAsBytes(
          electricalPlanToPdf(
            data: ePlan,
            projectName: base,
            sheetName: sheet.name,
            dateString: today,
            chrome: eChrome,
            metersPerPixel: metersPerPixel,
            underlay: underlay,
          ),
        );
        await File(out('elec-$suffix.dxf')).writeAsString(
          electricalPlanToDxf(
            data: ePlan,
            projectName: base,
            sheetName: sheet.name,
            chrome: eChrome,
            // Round 23 (elec-drafting-2-3) — world millimetres + the PDF's
            // snapped 1 : N, like the mechanical plan DXF beside it. The N
            // is the PDF twin's own fit (same args, underlay frame + real
            // title block included), so the two sheets stamp one scale.
            metersPerPixel: metersPerPixel,
            plottedScaleDenominator: electricalPlanPlottedScaleDenominator(
              data: ePlan,
              projectName: base,
              sheetName: sheet.name,
              dateString: today,
              chrome: eChrome,
              metersPerPixel: metersPerPixel,
              underlay: underlay,
            ),
          ),
        );
      }
    }
  } finally {
    ref.read(busyProvider.notifier).clear();
  }

  // ── The ELECTRICAL set, when the project has sized panels ───────────────────
  //
  // I2 — the package used to stop at the per-panel single-line PDF, so the
  // building single-line, the floor-by-floor riser, the power one-line and the
  // electrical calc report were each their own menu trip + save dialog on EVERY
  // revision (the set an Indonesian kontraktor is actually handed). Each is
  // built from the SAME pure engine builder its standalone export uses (no new
  // render path), stamped with its own N19 drawing number by [DrawingSeries],
  // and — where a contractor works the sheet in CAD — issued as PDF **and** DXF.
  //
  // Honest by construction: nothing here is written when there are no sized
  // panels, and the power one-line is written only when the project carries the
  // energy sources to draw one (the same gate the standalone export enforces).
  final eResult = ref.read(electricalResultProvider);
  if (eResult.order.isNotEmpty) {
    final eProject = ref.read(electricalProjectProvider);
    // Round 10 (elec-drawing-props-3) — one A3 sheet only while every label
    // still prints at the minimum plotted size; a larger project issues one
    // board per page instead of shrinking the schedules to ~3 pt.
    await File(out('electrical-sld.pdf')).writeAsBytes(
      electricalSldDetailToPdf(
        project: eProject,
        result: eResult,
        breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
        breakerKaByCircuitId: breakerKaByCircuit(ref),
        adsFailedCircuitIds: adsFailedCircuitIds(ref),
        containmentByCircuitId: containmentByCircuit(ref),
        chrome: sldChrome(DrawingSeries.electricalDetail),
        // Round 14 (drafting-visual-1) — ONE project name + the register
        // title on every electrical sheet of the package.
        projectName: base,
        diagramTitle: drawingSeriesTitle(DrawingSeries.electricalDetail),
      ),
    );
    // Round 20 (drafting-visual-4-3) — the board schedule is THE sheet a panel
    // builder redraws / annotates in CAD, so it is issued in DXF too (like
    // every other electrical sheet of the set), built exactly as the
    // standalone 'Single-line DXF' export builds it (same kA maps).
    await File(out('electrical-sld.dxf')).writeAsString(
      electricalSldToDxf(
        sheet: buildElectricalSld(
          project: eProject,
          result: eResult,
          breakerIcuKaByPanelId: breakerIcuKaByPanel(ref),
          breakerKaByCircuitId: breakerKaByCircuit(ref),
          adsFailedCircuitIds: adsFailedCircuitIds(ref),
          containmentByCircuitId: containmentByCircuit(ref),
        ),
        diagramTitle: drawingSeriesTitle(DrawingSeries.electricalDetail),
        chrome: sldChrome(DrawingSeries.electricalDetail),
        projectName: base,
      ),
    );

    // Building single-line (overview) — the whole distribution hierarchy on one
    // sheet, with the PLN/MV/TX/LV source spine, in both formats.
    final overviewChrome = sldChrome(DrawingSeries.electricalOverview);
    final overviewSheet = buildElectricalOverview(
      project: eProject,
      result: eResult,
      sourceChain: true,
    );
    // Round 23 (elec-drafting-2-1) — paginated by sub-tree whenever one A3
    // sheet would print below the minimum plotted label size.
    await File(out('electrical-overview-sld.pdf')).writeAsBytes(
      electricalOverviewToPdf(
        project: eProject,
        result: eResult,
        title: 'iSystem electrical single-line (overview)',
        diagramTitle: drawingSeriesTitle(DrawingSeries.electricalOverview),
        chrome: overviewChrome,
        projectName: base,
      ),
    );
    await File(out('electrical-overview-sld.dxf')).writeAsString(
      electricalSldToDxf(
        sheet: overviewSheet,
        diagramTitle: drawingSeriesTitle(DrawingSeries.electricalOverview),
        chrome: overviewChrome,
        projectName: base,
      ),
    );

    // Floor-by-floor electrical riser — built with the LIVE mechanical
    // [BuildingLevels] (the shared §10 geometry), like its standalone sibling.
    final eRiserChrome = sldChrome(DrawingSeries.electricalRiser);
    // Round 17 (drafting-visual-3-2) — the riser carries the SAME supply
    // spine (PLN head / earthing / TX / genset) as the overview in this
    // package, so two sheets of one submittal never disagree on the supply.
    final eRiserSheet = buildElectricalRiser(
      project: eProject,
      result: eResult,
      building: project.building,
      sourceChain: true,
    );
    // Round 23 (elec-drafting-2-1) — floor-range pages (LANJUT KE match
    // stubs) whenever one A3 sheet would print below the label floor.
    await File(out('electrical-riser.pdf')).writeAsBytes(
      electricalRiserToPdf(
        project: eProject,
        result: eResult,
        building: project.building,
        title: 'iSystem electrical building riser',
        diagramTitle: drawingSeriesTitle(DrawingSeries.electricalRiser),
        chrome: eRiserChrome,
        projectName: base,
      ),
    );
    await File(out('electrical-riser.dxf')).writeAsString(
      electricalSldToDxf(
        sheet: eRiserSheet,
        diagramTitle: drawingSeriesTitle(DrawingSeries.electricalRiser),
        chrome: eRiserChrome,
        projectName: base,
      ),
    );

    // Power one-line — only when energy sources exist to draw one.
    if (hasPowerOneLine) {
      final oneLineChrome = sldChrome(DrawingSeries.electricalPowerOneLine);
      final oneLineSheet = buildPowerOneLineSheet(powerOneLineFm);
      await File(out('electrical-power-one-line.pdf')).writeAsBytes(
        electricalSldToPdf(
          sheet: oneLineSheet,
          title: 'iSystem power one-line',
          diagramTitle: drawingSeriesTitle(DrawingSeries.electricalPowerOneLine),
          chrome: oneLineChrome,
          projectName: base,
        ),
      );
      await File(out('electrical-power-one-line.dxf')).writeAsString(
        electricalSldToDxf(
          sheet: oneLineSheet,
          diagramTitle: drawingSeriesTitle(DrawingSeries.electricalPowerOneLine),
          chrome: oneLineChrome,
          projectName: base,
        ),
      );
    }

    // The electrical calculation report (MD) — the panel-builder's own document,
    // over the SAME combined warning surface Review and compliance read (R1).
    await File(out('electrical-report.md')).writeAsString(
      buildElectricalCalcReport(buildElectricalReportData(ref), strings),
    );
  }

  // export-files-3 — prune superseded package files of THIS project.
  final removed = await removeStaleSubmittalFiles(
    dir,
    fileBase: fileBase,
    keep: written,
  );
  removedOut?.addAll(removed);
  return true;
}

/// The file suffixes (after `<stem>-`) a submittal package writes — the ONLY
/// files [removeStaleSubmittalFiles] may delete, so an unrelated file that
/// happens to share the stem is never touched.
final RegExp _submittalSuffix = RegExp(
  r'^(00-cover-sheets\.pdf'
  r'|report\.(md|pdf)'
  r'|mep-report\.(md|pdf)'
  r'|equipment-schedule\.(md|csv|pdf)'
  r'|bom\.csv'
  r'|quotation\.md'
  r'|riser-sld\.(pdf|dxf)'
  r'|(elec-)?plan-\d+-.+\.(pdf|dxf)'
  r'|electrical-sld\.(pdf|dxf)'
  r'|electrical-overview-sld\.(pdf|dxf)'
  r'|electrical-riser\.(pdf|dxf)'
  r'|electrical-power-one-line\.(pdf|dxf)'
  r'|electrical-report\.md)$',
);

/// Round 13 (export-files-3) — delete every file directly in [dir] named
/// `<fileBase>-<a submittal package suffix>` that is NOT in [keep] (the paths
/// this run wrote): drawings superseded since the last issue into the same
/// folder (a removed sheet, a cleared electrical set). Returns the deleted
/// paths. Never recurses; a file that cannot be deleted is left in place.
@visibleForTesting
Future<List<String>> removeStaleSubmittalFiles(
  String dir, {
  required String fileBase,
  required Set<String> keep,
}) async {
  final removed = <String>[];
  final folder = Directory(dir);
  if (!await folder.exists()) return removed;
  final prefix = '$fileBase-';
  await for (final entity in folder.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.isEmpty
        ? ''
        : entity.uri.pathSegments.last;
    final decoded = Uri.decodeComponent(name);
    if (!decoded.startsWith(prefix)) continue;
    final suffix = decoded.substring(prefix.length);
    if (!_submittalSuffix.hasMatch(suffix)) continue;
    final path = '$dir${Platform.pathSeparator}$decoded';
    if (keep.contains(path) || keep.contains(entity.path)) continue;
    try {
      await entity.delete();
      removed.add(entity.path);
    } on FileSystemException {
      // Locked / read-only — leave it; the cover still lists the true set.
    }
  }
  removed.sort();
  return removed;
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
  const ExportIdentityBar({super.key, this.footer = const []});

  /// Extra content beneath the Drawing no. / Revision / Client row — the
  /// Projects page hosts its sign-off + equipment model/spec disclosures here
  /// so the whole document-control identity reads as ONE card. Empty (the
  /// Review hub) ⇒ just the row.
  final List<Widget> footer;

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
    ) => SizedBox(
      width: 176,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(height: MechXSpacing.xxs),
          MechXTextField(value: value ?? '', hint: hint, onCommitted: onSet),
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
          Text(
            context.strings(StringKey.exportIdentityTitle),
            style: type.subtitle.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: MechXSpacing.xxs),
          Text(
            context.strings(StringKey.projectsDocControlCaption),
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.sm),
          Wrap(
            spacing: MechXSpacing.md,
            runSpacing: MechXSpacing.sm,
            children: [
              field(
                context.strings(StringKey.exportIdentityDrawingNo),
                doc.documentNumber,
                ctrl.setDocumentNumber,
                context.strings(StringKey.exportIdentityDrawingNoHint),
              ),
              field(
                context.strings(StringKey.inspectorRevisionTag),
                doc.revisionTag,
                ctrl.setRevisionTag,
                context.strings(StringKey.exportIdentityRevisionHint),
              ),
              field(
                context.strings(StringKey.inspectorClient),
                doc.clientName,
                ctrl.setClientName,
                context.strings(StringKey.exportIdentityClientHint),
              ),
            ],
          ),
          ...footer,
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
    final layer = ref.watch(activeDisciplineProvider);

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
          prev == null ||
          prev.nodeId != next.nodeId ||
          prev.edgeId != next.edgeId;
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
                summary:
                    '${building.totalHeight.meters.toStringAsFixed(1)} m · '
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

              // ── The ACTIVE layer's sections only ──────────────────────────
              // The inspector is scoped to the discipline being edited: the
              // Plumbing layer shows its Tanks + network Results, Fire its
              // fire-protection block, HVAC its Rooms + ducting. (Electrical
              // swaps the whole column for the Loads palette in app_shell.)
              // Document control + the equipment model/spec editor moved to
              // the Projects page, beside the exports they stamp.
              ...switch (layer) {
                DisciplineLayer.plumbing => const <Widget>[
                  // Tanks (only shown when the sheet has designated areas).
                  _TanksSection(),
                  // Network results (the Show/Hide-sizes toggle sits atop).
                  _ResultsSection(),
                  SizedBox(height: MechXSpacing.lg),
                ],
                DisciplineLayer.fire => const <Widget>[
                  _FireSection(),
                  SizedBox(height: MechXSpacing.lg),
                ],
                DisciplineLayer.hvac => const <Widget>[
                  // Rooms (only shown when the sheet has designated rooms).
                  _RoomsSection(),
                  _HvacSection(),
                  SizedBox(height: MechXSpacing.lg),
                ],
                DisciplineLayer.electrical => const <Widget>[],
              },
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
    final currentSheet = ref.watch(sheetsContentProvider).current;
    final project = ref.watch(projectControllerProvider);
    final calibration = currentSheet == null
        ? null
        : project.calibrationFor(currentSheet.id);
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
            // Round 31 (ui-simplicity-4) — an uncalibrated sheet's state is
            // stated by the Layout breadcrumb tail; here the 'Calibrate
            // scale' button carries it, so the 'Not calibrated' status row
            // shows only when there is no sheet to calibrate.
            if (calibration != null || currentSheet == null)
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
                      borderRadius: MechXRadii.small,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      calibration == null
                          ? 'Not calibrated'
                          // One shared human readout (D1): PDF sheets lead with
                          // the plotted `1 : N`, else `1 m = N px`.
                          : formatScaleReadout(
                              calibration.metersPerPixel,
                              isPdf: currentSheet?.pdfPath != null,
                            ),
                      style: type.caption.copyWith(color: colors.textSecondary),
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
              if (calibration != null) const SizedBox(height: MechXSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: MechXButton(
                  label: calibration == null
                      ? 'Calibrate scale'
                      : 'Re-calibrate',
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
  BuildContext context,
  WidgetRef ref,
  String fromSheetId,
) async {
  final proj = ref.read(projectControllerProvider);
  final allIds = ref
      .read(sheetsControllerProvider)
      .sheets
      .map((s) => s.id)
      .toSet();
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
    status(context.strings(StringKey.scaleAlreadyAllSheets));
    return;
  }
  // Round 24 — transferred per sheet type: DXF sheets are rescaled by their
  // own import frames, a PDF <-> DXF copy is skipped (and said so).
  final skipped = <String>{};
  final n = ref
      .read(projectControllerProvider.notifier)
      .applyCalibrationToAllSheets(
        fromSheetId,
        toSheetIds: {fromSheetId, ...targets},
        sheets: {
          for (final s in ref.read(sheetsControllerProvider).sheets) s.id: s,
        },
        skippedOut: skipped,
      );
  final m = skipped.length;
  status(context.strings.scaleAppliedStatus(n, m));
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
        child: Builder(
          builder: (ctx) {
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
                  Text(
                    'Overwrite different scales?',
                    style: type.title.copyWith(color: colors.textPrimary),
                  ),
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
          },
        ),
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
    // Round 19 (regression-locale-parser-not-universal) — the scale N reads
    // through the ONE engineering-number parser: in the ID UI `1.000` is
    // 1 : 1000, never a silent 1 : 1 calibration (every length ~1000× short).
    final n = parseLocaleNumber(_text,
        indonesian: ref.read(localeProvider) == AppLocale.id);
    if (n == null || !n.isFinite || n <= 0) return;
    final mpp = metersPerPixelForPdfScale(n);
    ref
        .read(projectControllerProvider.notifier)
        .setCalibration(widget.sheetId, ScaleCalibration(mpp));
    ref
        .read(statusMessageProvider.notifier)
        .showStatus('Scale set: ${formatScaleReadout(mpp, isPdf: true)}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Or type the drawing scale',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
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
              border: Border.all(
                color: _hover ? colors.textMuted : colors.border,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // L2: '11.0 m · 3 levels' updates in place with edits.
                    style: MechXTypography.tabular(
                      type.body.copyWith(color: colors.textSecondary),
                    ),
                  ),
                ),
                const SizedBox(width: MechXSpacing.xs),
                Text(
                  'Edit',
                  style: type.caption.copyWith(color: colors.accent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class InspectorGlyphButton extends StatefulWidget {
  final String glyph;
  final VoidCallback? onTap;
  const InspectorGlyphButton({
    super.key,
    required this.glyph,
    required this.onTap,
  });

  @override
  State<InspectorGlyphButton> createState() => InspectorGlyphButtonState();
}

class InspectorGlyphButtonState extends State<InspectorGlyphButton> {
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
          color: _hover && enabled
              ? colors.surfaceHover
              : const Color(0x00000000),
          borderRadius: MechXRadii.control,
        ),
        child: Text(
          widget.glyph,
          style: TextStyle(
            fontFamily: 'Roboto',
            fontSize: 16,
            height: 1.0,
            color: fg,
          ),
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

class _DrawSection extends ConsumerWidget {
  const _DrawSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    // Only what this section shows (tool, service, network-exists) — a drag
    // frame replaces the network and must not rebuild the inspector.
    final drawing = ref.watch(networkControllerProvider.select((d) => (
          tool: d.tool,
          service: d.service,
          hasNetwork:
              d.network.nodes.isNotEmpty || d.network.edges.isNotEmpty,
        )));
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
      selected:
          drawing.tool == t &&
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
    final selectActive =
        drawing.tool == DrawTool.select &&
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
        drawing.hasNetwork;

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
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // L2: the title carries live dims while a footprint drags.
                  style: MechXTypography.tabular(
                    type.body.copyWith(color: colors.textPrimary),
                  ),
                ),
              ),
              if (warning) ...[
                const SizedBox(width: MechXSpacing.xs),
                CustomPaint(
                  size: const Size(13, 13),
                  painter: SeverityGlyph(
                    kind: SeverityGlyphKind.warn,
                    color: colors.danger,
                  ),
                ),
              ],
              const SizedBox(width: MechXSpacing.sm),
              Text(
                headline,
                // L2: capacity/CFM recompute live — tabular digits keep the
                // headline from wobbling sideways.
                style: MechXTypography.tabular(
                  type.caption.copyWith(color: colors.accent),
                ),
              ),
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
    final sheet = ref.watch(sheetsContentProvider).current;
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
    final expandedId = (sel != null && sel.kind == AnnotationKind.tank)
        ? sel.id
        : null;
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
                        Text(
                          'Name',
                          style: type.caption.copyWith(color: colors.textMuted),
                        ),
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
                        Text(
                          'Depth',
                          style: type.caption.copyWith(color: colors.textMuted),
                        ),
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
    final sheet = ref.watch(sheetsContentProvider).current;
    if (sheet == null) return const SizedBox.shrink();
    final allRooms = ref.watch(roomAreasProvider);
    final rooms = [
      for (final r in allRooms)
        if (r.sheetId == sheet.id) r,
    ];
    if (rooms.isEmpty) return const SizedBox.shrink();
    final cal = ref.watch(projectControllerProvider).calibrationFor(sheet.id);
    final ducts = ref.watch(ductSettingsProvider);
    final roomSizing = ref.watch(roomSizingProvider);
    final ctrl = ref.read(roomAreasProvider.notifier);
    final nodes = ref.watch(sizingNetworkProvider).nodes;
    // E6: the open master-detail row is the shared canvas selection.
    final sel = ref.watch(selectedAnnotationProvider);
    final expandedRoomId = (sel != null && sel.kind == AnnotationKind.room)
        ? sel.id
        : null;
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
      // Round 27 (hvac-4-4) — a trunk clamped to the largest standard size
      // says so; it is not a valid selection.
      final over = s.trunkOverCapacity ? ' · over capacity' : '';
      final round = s.supplyDuctRound;
      if (round != null) {
        return 'Duct Ø${round.diameter.inMillimeters.round()} mm @ '
            '${round.actualVelocity.metersPerSecond.toStringAsFixed(1)} m/s'
            '$over';
      }
      final rect = s.supplyDuctRect!;
      return 'Duct ${rect.width.inMillimeters.round()}x'
          '${rect.height.inMillimeters.round()} mm @ '
          '${rect.actualVelocity.metersPerSecond.toStringAsFixed(1)} m/s'
          '$over';
    }

    // Round 27 (hvac-4-5) — the selected catalogue face W x H (the face
    // Auto-place stamps on the node), never the square-equivalent side.
    String bank(TerminalBank b) {
      final (w, h) = b.faceMm;
      return '${b.count} x ${w.round()}x${h.round()} mm @ '
          '${b.each.faceVelocity.metersPerSecond.toStringAsFixed(1)} m/s';
    }

    return DisclosureSection(
      name: 'Rooms (ACH airflow)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in rooms) ...[
            Builder(
              builder: (context) {
                final s = roomSizing[r.id];
                // AC cooling — computed once so the compact row can flag an
                // over-range unit and the expanded editor can detail it.
                // Round 20 (hvac-3-1) — the units this room OWNS (smallest
                // containing room), the same split the panel feed and the
                // schedule use: a unit in a nested room is not counted here.
                final acs = [
                  for (final n in nodes)
                    if (RoomArea.isAcComponent(n.component) &&
                        roomUnitOwnerId(n, allRooms) == r.id)
                      n,
                ];
                // M15/R6 — read the project's CHOSEN cooling-load basis (the
                // Building page's 'AC load basis' picker) rather than hard-coding
                // the area-density rule here, so the displayed BTU/h + PK actually
                // follow the setting instead of ignoring it.
                final load = ref.watch(roomCoolingLoadProvider(r.id));
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
                        headline: s == null
                            ? 'set scale'
                            : '${s.airflowCfm.round()} CFM',
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
                            Text(
                              'Name',
                              style: type.caption.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
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
                            Text(
                              dims(r),
                              // L2: live dims while the footprint drags.
                              style: MechXTypography.tabular(
                                type.caption.copyWith(color: colors.textMuted),
                              ),
                            ),
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
                          Text(
                            'set scale',
                            style: type.caption.copyWith(
                              color: colors.textMuted,
                            ),
                          )
                        else ...[
                          ResultCard(
                            headline: '${s.airflowCfm.round()} CFM',
                            label:
                                'Design airflow · '
                                '${s.airflow.inLitersPerSecond.round()} L/s · '
                                '${s.airflow.inCubicMetersPerHour.round()} m3/h',
                            verdict: 'sized',
                            verdictColor: colors.success,
                          ),
                          const SizedBox(height: MechXSpacing.xs),
                          // L2: these figures re-size live with the footprint —
                          // tabular digits stop the rows shuffling as they change.
                          Text(
                            duct(s),
                            style: MechXTypography.tabular(
                              type.caption.copyWith(
                                  color: s.trunkOverCapacity
                                      ? colors.danger
                                      : colors.textMuted),
                            ),
                          ),
                          // Round 11 — an extract room shows its exhaust bank
                          // only (no conditioned supply, no recirculation).
                          if (!s.extractOnly)
                            Text(
                              'Supply ${bank(s.supply)}',
                              style: MechXTypography.tabular(
                                type.caption.copyWith(color: colors.textMuted),
                              ),
                            ),
                          Text(
                            '${s.extractOnly ? 'Exhaust' : 'Return'} '
                            '${bank(s.return_)}',
                            style: MechXTypography.tabular(
                              type.caption.copyWith(color: colors.textMuted),
                            ),
                          ),
                          const SizedBox(height: MechXSpacing.xs),
                          // M11: an equipment duty past the largest standard motor
                          // frame is a CLAMP, not a selection — flag it.
                          ResultCard(
                            headline:
                                '${s.equipment.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW',
                            label:
                                '${airEquipmentLabel(s.equipmentKind)} · '
                                '${s.equipment.totalStaticPressure.pascals.round()} Pa'
                                '${s.equipment.motorOversized ? ' · above standard frame' : ''}',
                            verdict: s.equipment.motorOversized
                                ? 'over frame'
                                : s.trunkOverCapacity
                                    ? 'duct over capacity'
                                    : 'sized',
                            verdictColor: s.equipment.motorOversized ||
                                    s.trunkOverCapacity
                                ? colors.danger
                                : colors.success,
                          ),
                        ],
                        // Cooling (AC) — shown only when an AC indoor unit sits in
                        // the room. Auto-computes the BTU/h + PK requirement and a
                        // per-unit recommendation split across the placed units,
                        // promoted to its own ResultCard (verdict flags an
                        // over-range unit the way the master row's warning dot
                        // already did).
                        if (perUnit != null)
                          ...() {
                            final labels = {
                              for (final n in acs) n.component!.label,
                            };
                            final typeStr = labels.length == 1
                                ? labels.first
                                : 'mixed';
                            return <Widget>[
                              const SizedBox(height: MechXSpacing.xs),
                              ResultCard(
                                headline: '${pkStr(perUnit.pk)} PK',
                                label:
                                    '${acs.length} ${acs.length == 1 ? 'unit' : 'units'} '
                                    '($typeStr) · ${perUnit.nominalBtuPerHr.round()} BTU/h',
                                verdict: perUnit.exceedsRange
                                    ? 'over'
                                    : 'sized',
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
                                  type.caption.copyWith(
                                    color: colors.textMuted,
                                  ),
                                ),
                              ),
                              Text(
                                'Feeds the electrical panel at the kW above.',
                                style: type.caption.copyWith(
                                  color: colors.textMuted,
                                ),
                              ),
                              if (perUnit.exceedsRange)
                                Text(
                                  'Load exceeds the largest single unit — add more units.',
                                  style: type.caption.copyWith(
                                    color: colors.danger,
                                  ),
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
                                  Text(
                                    'Ceiling',
                                    style: type.caption.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                                  const Spacer(),
                                  SteppedValueField(
                                    display:
                                        '${r.ceilingHeightM.toStringAsFixed(2)} m',
                                    editSeed: r.ceilingHeightM.toStringAsFixed(
                                      2,
                                    ),
                                    label: context.strings(
                                      StringKey.a11yFieldCeilingHeight,
                                    ),
                                    gap: 0,
                                    valueWidth: 56,
                                    valueAlign: TextAlign.center,
                                    valueColor: colors.textPrimary,
                                    min: 1.5,
                                    max: 12,
                                    onDecrement: () => ctrl.setCeiling(
                                      r.id,
                                      r.ceilingHeightM - 0.25,
                                    ),
                                    onIncrement: () => ctrl.setCeiling(
                                      r.id,
                                      r.ceilingHeightM + 0.25,
                                    ),
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
                                  Text(
                                    'ACH',
                                    style: type.caption.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                                  const SizedBox(width: MechXSpacing.xs),
                                  _Pill(
                                    label: 'Auto',
                                    selected: r.achOverride == null,
                                    onTap: () => ctrl.setAch(r.id, null),
                                  ),
                                  const Spacer(),
                                  // Round 13 (ui-journey-2) — the edit box
                                  // pre-fills only an explicit OVERRIDE (Auto
                                  // ⇒ '' — a look-and-leave no longer pins the
                                  // room-type ACH, which then went stale on a
                                  // room-type change), and ACH prints to one
                                  // decimal so a 2.5 override never re-seeds
                                  // as '3'. The selected Auto pill marks the
                                  // auto figure.
                                  SteppedValueField(
                                    display: '${_fmtAch(r.effectiveAch())}/h',
                                    editSeed: r.achOverride == null
                                        ? ''
                                        : _fmtAch(r.achOverride!),
                                    label: context.strings(
                                      StringKey.a11yFieldAirChangesPerHour,
                                    ),
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
                                        .read(
                                          networkControllerProvider.notifier,
                                        )
                                        .autoPlaceRoomTerminals(
                                          room: r,
                                          metersPerPixel: cal.metersPerPixel,
                                          ductShape: ducts.shape,
                                          ductMethod: ducts.method,
                                        )
                                  : null,
                            ),
                            const SizedBox(width: MechXSpacing.sm),
                            // Round 13 — the count flexes (wrapping, right-
                            // aligned) beside the button: an extract room's
                            // 'N exhaust grilles' caption overflowed the 222 px
                            // column by ~120 px.
                            Expanded(
                              child: s == null
                                  ? const SizedBox.shrink()
                                  : Text(
                                      // Round 11 — an extract room (toilet /
                                      // kitchen) places exhaust grilles only.
                                      s.extractOnly
                                          ? context.strings.format(
                                              StringKey.roomExtractGrilleCount,
                                              {'n': s.return_.count})
                                          // Round 17 follow-up — the button
                                          // places return_.count grilles (M10),
                                          // never a fixed one.
                                          : context.strings.format(
                                              StringKey.roomAutoPlaceCaption, {
                                              'supply': s.supply.count,
                                              'return': s.return_.count,
                                            }),
                                      textAlign: TextAlign.end,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      // L2: the diffuser count tracks the live
                                      // sizing.
                                      style: MechXTypography.tabular(
                                        type.caption.copyWith(
                                          color: colors.textMuted,
                                        ),
                                      ),
                                    ),
                            ),
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
              },
            ),
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
    child: LayoutBuilder(
      builder: (context, constraints) {
        // The value may take the WHOLE row (the label then wraps/ellipsizes to
        // nothing), but is capped at the row width so a pathologically wide
        // value soft-wraps instead of overflowing the panel — data is shown in
        // full either way.
        final valueMax = constraints.hasBoundedWidth
            ? (constraints.maxWidth - MechXSpacing.xs).clamp(
                0.0,
                double.infinity,
              )
            : double.infinity;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                key,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: type.caption.copyWith(color: colors.textMuted),
              ),
            ),
            const SizedBox(width: MechXSpacing.xs),
            // Deliberately NOT Flexible: the value's intrinsic width is
            // honoured in full, so only the label shrinks in the space fight.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: valueMax),
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: type.mono.copyWith(color: colors.textSecondary),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _ResultsSection extends ConsumerWidget {
  const _ResultsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(showHeatmapProvider);
    final showSizes = ref.watch(showSizingProvider);
    final strategy = ref.watch(feedStrategyProvider);
    final solution = ref.watch(solveProvider);
    // Round 25 — the gravity solve describes a DRAWN roof tank only: with no
    // tank it solved from a phantom source (the highest meter / fixture), so
    // its booster head, top residual and zone verdict are not shown — the
    // same gate the calc report prints on.
    final gravityDrawn = ref.watch(gravityDownfeedDrawnProvider);
    final downfeed = gravityDrawn ? ref.watch(downfeedProvider) : null;
    // Round 34 — the DELIVERED field (drawn boosters at their sized duty) is
    // what the heatmap, probe and Review read, so 'Top residual' reads it
    // too; [downfeed] (unboosted) stays the booster-DUTY basis.
    final delivered =
        gravityDrawn ? ref.watch(downfeedDeliveredProvider) : null;
    // Round 34 — the Round-32 split: below the SNI 8153 floor at some
    // delivery node is a code failure (amber 'boost'); between the floor and
    // the comfort target it is advisory, so the headline must not contradict
    // the compliance PASS.
    final sniFloors =
        gravityDrawn ? ref.watch(downfeedSniFloorsProvider) : const <String, Pressure>{};
    final belowSniFloor = delivered == null ||
        sniFloors.isEmpty ||
        worstSniShortfall(
                floors: sniFloors, residual: delivered.residualPressure) !=
            null;
    // Round 30 (r2) — water-network pumps only (a fire / sump pump is not a
    // water booster), the same evidence as the feed line above.
    final hasPumpDrawn =
        drawnWaterFeedEquipment(ref.watch(sizingNetworkProvider)).hasPump;
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
    // Round 22 (pressurized-3-1) — the PRV stations the zone table actually
    // needs (the tank-fed top zone has none).
    final prvStations = zoneStatics.where((z) => z.viaPrv).length;
    final totalLength = bom.fold<double>(
      0,
      (sum, line) => sum + line.totalLength.meters,
    );
    // L1: an uncalibrated sheet has no measurable length, so a drawn run's BOM
    // line totals an exact 0 — that must never read as a MEASURED zero. Any
    // such line flips the totals row to an honest "measured + unmeasured"
    // split instead of implying the whole BOM was 0.0 m.
    // Round 21 (bom-quote-2) — ANY unmeasured run marks its line, not only an
    // all-zero total: a 50 m calibrated run merged with an uncalibrated one
    // used to pass as a measured 50 m.
    bool isUnmeasured(BomLine line) => line.unmeasuredSegments > 0;
    final hasUnmeasuredBomLine = bom.any(isUnmeasured);
    final unmeasuredRunCount = bom.fold<int>(
        0, (sum, line) => sum + line.unmeasuredSegments);
    final notMeasured = context.strings(StringKey.bomNotMeasured);

    // L1: keep the BOM row leader short enough that it never fights the
    // quantity for space. When every listed line shares ONE service the
    // service word is redundant ('DN15 riser'); with several services a
    // compact service word — the trailing 'water'/'air' dropped, never a
    // mid-word abbreviation — keeps rows distinct ('DN15 · Cold riser').
    final bomServiceCount = {for (final l in bom) l.service}.length;
    String bomLeader(BomLine line) {
      // Round 31 — the standard size notation every other surface prints
      // (canvas chips, riser tags, Commercial BOM): 'DN15' / 'Ø300'.
      final size = line.service.regime == FlowRegime.air
          ? 'Ø${line.diameterMm}'
          : 'DN${line.diameterMm}';
      final kindWord = line.kind == EdgeKind.riser ? 'riser' : 'run';
      if (bomServiceCount <= 1) return '$size $kindWord';
      final service = serviceLabel(
        line.service,
      ).replaceAll(' water', '').replaceAll(' air', '');
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
        // M11 — `selectMotor` clamps at the largest standard frame (75 kW), so
        // a 90 kW duty used to print a clean, green '75.00 kW' everywhere. When
        // the duty saturated the ladder the figure is NOT a selection — say so.
        final over = pump.motorOversized;
        headlineCard = ResultCard(
          headline: '${pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW',
          label: over ? 'Pump motor · above standard frame' : 'Pump motor',
          verdict: over ? 'over frame' : 'sized',
          verdictColor: over ? colors.danger : colors.success,
        );
      }
    } else {
      if (downfeed != null) {
        // Round 22 (pressurized-3-5) — a booster requirement leads: a green
        // zone card must never hide that gravity cannot deliver. With gravity
        // sufficient, the PRV-zone verdict shows only when a PRV station is
        // actually needed; otherwise the gravity verdict.
        if (!downfeed.gravitySufficient && !belowSniFloor) {
          // Round 34 — SNI minimum met at every delivery node; the comfort
          // booster is a recommendation, carried by a muted row below.
          headlineCard = ResultCard(
            headline:
                '${delivered.minResidual.inKiloPascals.toStringAsFixed(0)} kPa',
            label: 'Top residual · SNI min met',
            verdict: 'OK',
            verdictColor: colors.success,
          );
        } else if (!downfeed.gravitySufficient) {
          headlineCard = ResultCard(
            headline:
                '+${downfeed.boosterHeadRequired.meters.toStringAsFixed(1)} m',
            label: 'Downfeed booster',
            verdict: 'boost',
            verdictColor: colors.warning,
          );
        } else if (_zoneTableNeeded(zoneStatics)) {
          headlineCard = ResultCard(
            headline:
                '$prvStations PRV zone${prvStations == 1 ? '' : 's'}'
                ' · ${worstZone.toStringAsFixed(0)} kPa',
            label: 'PRV zones (worst) · zone static',
            verdict: zonesOk ? 'OK' : 'over',
            verdictColor: zonesOk ? colors.success : colors.danger,
          );
        } else {
          headlineCard = ResultCard(
            headline: 'gravity',
            label: 'Downfeed booster',
            verdict: 'OK',
            verdictColor: colors.success,
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
                onPressed: () =>
                    ref.read(showHeatmapProvider.notifier).toggle(),
              ),
            ],
          ),
          if (headlineCard != null) ...[
            const SizedBox(height: MechXSpacing.sm),
            headlineCard,
          ],
          const SizedBox(height: MechXSpacing.sm),
          // 2026-10-17: the feed strategy is a Building design input — reported
          // read-only here, with a 'Change' link to the Building page.
          const FeedStrategyLine(),
          // E11: honest empty state — until a network is actually drawn and
          // solved, show a muted prompt (the HVAC-section idiom) instead of
          // dash rows and a misleading 'BOM total 0.0 m'.
          if (bom.isEmpty &&
              solution == null &&
              downfeed == null &&
              hwr == null)
            Text(
              'Draw a network to size runs and risers.',
              style: context.type.caption.copyWith(color: colors.textMuted),
            )
          else ...[
            if (strategy == FeedStrategy.upfeed) ...[
              // 'Motor' kW is promoted to the ResultCard above; keep only the
              // distinct supporting figure here (H8 — no headline/kv duplication).
              _kvRow(
                context,
                'Pump head',
                // Round 33 (hydraulics-3-2) — the head of the PRIMARY drawn
                // pump (the same duty the motor ResultCard above is sized
                // on), never the whole-system single-source head when a root
                // pump + zone booster split it.
                solution == null
                    ? '—'
                    : '${(pump?.head ?? solution.requiredPumpHead).meters.toStringAsFixed(1)} m',
              ),
            ] else if (!gravityDrawn) ...[
              // Round 25 — no roof tank drawn: the drawn feed is the mains (or
              // a booster), so no gravity duty / zone table is claimed.
              // A caption, not a key/value row: the Feed setting line above
              // already carries the label, and the value must never truncate.
              Text(
                context.strings(hasPumpDrawn
                    ? StringKey.resultsFeedBoosterNoTank
                    : StringKey.resultsFeedDirectMains),
                style: context.type.caption
                    .copyWith(color: colors.textSecondary),
              ),
            ] else ...[
              // Round 34 — the DELIVERED top residual (the heatmap's and the
              // probe's figure); omitted when the SNI-met card states it.
              if (downfeed == null ||
                  downfeed.gravitySufficient ||
                  belowSniFloor)
                _kvRow(
                  context,
                  'Top residual',
                  delivered == null
                      ? '—'
                      : '${delivered.minResidual.inKiloPascals.toStringAsFixed(0)} kPa',
                ),
              // Round 34 — a drawn booster lifts the delivered field; the
              // unboosted gravity figure stays visible, muted.
              if (downfeed != null &&
                  delivered != null &&
                  (delivered.minResidual.inKiloPascals -
                              downfeed.minResidual.inKiloPascals)
                          .abs() >=
                      0.5)
                _kvRow(
                  context,
                  'Gravity only',
                  '${downfeed.minResidual.inKiloPascals.toStringAsFixed(0)} kPa',
                ),
              if (downfeed != null &&
                  !downfeed.gravitySufficient &&
                  !belowSniFloor)
                // The comfort booster, as a recommendation (SNI min met).
                _kvRow(
                  context,
                  'Booster',
                  '+${downfeed.boosterHeadRequired.meters.toStringAsFixed(1)} m advised',
                ),
              // Round 31 (ui-simplicity-4) — H8 on the downfeed branch too: a
              // figure the headline card already states is not repeated as a
              // supporting row. The booster card (or the 'gravity OK' card)
              // carries the booster verdict; the PRV-zone card the zones.
              if (downfeed == null ||
                  (downfeed.gravitySufficient &&
                      _zoneTableNeeded(zoneStatics)))
                _kvRow(
                  context,
                  'Booster',
                  downfeed == null ? '—' : 'gravity OK',
                ),
              if (downfeed == null ||
                  !downfeed.gravitySufficient ||
                  !_zoneTableNeeded(zoneStatics))
                _kvRow(
                  context,
                  'PRV zones',
                  !_zoneTableNeeded(zoneStatics)
                      ? 'none needed'
                      : '$prvStations · worst ${worstZone.toStringAsFixed(0)} kPa'
                            ' ${zonesOk ? 'OK' : 'over'}',
                ),
            ],
            if (strategy == FeedStrategy.upfeed)
              _kvRow(context, 'Pressure zones', '${zones.length}'),
            if (hwr != null)
              _kvRow(
                context,
                'HW recirc',
                '${hwr.recircFlow.inLitersPerSecond.toStringAsFixed(2)} L/s · ${hwr.pump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW',
              ),
            _kvRow(
              context,
              'BOM total',
              hasUnmeasuredBomLine
                  ? '${totalLength.toStringAsFixed(1)} m + $notMeasured'
                  : '${totalLength.toStringAsFixed(1)} m',
            ),
            if (bom.isNotEmpty) ...[
              const SizedBox(height: MechXSpacing.xs),
              // Cap the per-line listing so a big BOM doesn't push the whole panel
              // off-screen; the overflow is summarised, never silently dropped (the
              // full breakdown is in the CSV export below). (H6/H8.)
              for (final line in bom.take(_kBomInlineCap))
                _kvRow(
                  context,
                  bomLeader(line),
                  !isUnmeasured(line)
                      ? '${line.totalLength.meters.toStringAsFixed(1)} m ×${line.segmentCount}'
                      : line.unmeasuredSegments >= line.segmentCount
                          ? '$notMeasured ×${line.segmentCount}'
                          : '${line.totalLength.meters.toStringAsFixed(1)} m '
                              '×${line.segmentCount - line.unmeasuredSegments}'
                              ' + $notMeasured ×${line.unmeasuredSegments}',
                ),
              if (bom.length > _kBomInlineCap)
                _kvRow(
                  context,
                  '+${bom.length - _kBomInlineCap} more line'
                      '${bom.length - _kBomInlineCap == 1 ? '' : 's'}',
                  'see CSV',
                ),
              // Work item 4 (2026-10-17): ONE actionable caption under the BOM
              // rows when any line is not measured — tapping it opens the Scale
              // section and scrolls the inspector to it.
              if (hasUnmeasuredBomLine)
                _CalibrateToMeasureHint(runCount: unmeasuredRunCount),
              if (fittings.isNotEmpty)
                _kvRow(
                  context,
                  'Fittings (est.)',
                  '${fittings.fold<int>(0, (s, f) => s + f.count)}',
                ),
              // Work item 8: 'Export BOM (CSV)' now lives in the Export sheet's
              // Data group (Ctrl/Cmd+E) — one door for every deliverable.
            ],
          ],
        ],
      ),
    );
  }
}

/// The mechanical BOM export — `<base>-bom.csv` (floor-grouped, with the
/// stock-bar cut plan joined) + `<base>-fittings.csv`. Listed in the Export
/// sheet's Data group (work item 8; was the Results-section button).
Future<void> exportBomCsv(WidgetRef ref) {
  final fittings = ref.read(fittingsProvider);
  final dialogTitle = MechXStringsData(ref.read(localeProvider))(
    StringKey.exportTitleBom,
  );
  return runExportGuarded(
    ref,
    // Two clean single-schema files (Excel-aligned) instead of one mixed CSV.
    name: 'BOM (-bom.csv + -fittings.csv)',
    write: () async {
      // H8: the default name carries the PROJECT name like every other
      // export — never the internal 'mechx' codename.
      final projectName = ref.read(projectControllerProvider).name;
      final defaultBase = projectName.isEmpty ? 'project' : projectName;
      final full = await pickExportSave(
        ref,
        dialogTitle: dialogTitle,
        fileName: '$defaultBase-bom.csv',
        ext: 'csv',
      );
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
        mounting: project.mounting,
        groupByFloor: true,
      );
      final cutPlan = ref.read(pipeCutPlanProvider);
      await File(
        '$base-bom.csv',
      ).writeAsString(excelCsv(bomCsvWithCutPlan(floorBom, cutPlan)));
      await File('$base-fittings.csv')
          .writeAsString(excelCsv(fittingsToCsv(fittings)));
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
    final ratedPoint = ref.watch(fireRatedPointProvider);
    final hasHydrantEdges = ref.watch(sizingNetworkProvider)
        .edges
        .any((e) => e.service == ServiceType.fireHydrant);
    final hasSprinklerEdges = ref.watch(sizingNetworkProvider)
        .edges
        .any((e) => e.service == ServiceType.fireSprinkler);
    final standpipeRisers = drawnStandpipeRiserCount(
        ref.watch(sizingNetworkProvider));
    // E11: the whole fire design derives from occupancy/height/hazard alone, so
    // it computes even with NO fire pipework drawn. Detect real sprinkler/
    // hydrant edges so the verdict is honest — a preliminary 'draft' from
    // building defaults, not a validated 'rated', until fire runs exist.
    final hasFireEdges = ref.watch(sizingNetworkProvider)
        .edges
        .any(
          (e) =>
              e.service == ServiceType.fireSprinkler ||
              e.service == ServiceType.fireHydrant,
        );

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
          Text(
            'Hazard class',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.xs),
          Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: [
              for (final h in FireHazardClass.values)
                _Pill(
                  label: hazardLabel(h),
                  selected: ref.watch(fireHazardProvider) == h,
                  onTap: () => setFireHazardUndoable(ref.read, h),
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
                // The SELECTED NFPA 20 motor frame (it carries the overload
                // point) — the same kW the equipment schedule's FP-01 and the
                // electrical feed use, never the raw rated-point shaft power.
                //
                // Round 17 follow-up — the head is the SAME governing rated
                // point the motor was sized on (`fireRatedPointProvider`): the
                // sprinkler remote-area duty on a sprinkler-only network, never
                // the standpipe head of a system that is not drawn.
                fireHeadlineText(ratedPoint.head, rating.selectedMotor),
            label: fireHeadlineLabel(sprinklerOnly: ratedPoint.sprinklerOnly),
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
          // Round 21 — only when a sprinkler system is drawn (or nothing is —
          // the draft basis), mirroring the report's sprinklerDrawn gate: a
          // hydrant-only building has no sprinkler flow to print.
          if (hasSprinklerEdges || !hasFireEdges) ...[
            kv(
              'Sprinkler flow',
              '${ref.watch(sprinklerRemoteAreaProvider).remoteAreaDemand.inLitersPerSecond.toStringAsFixed(1)} L/s',
            ),
            kv('Sprinkler heads', '${sprinkler.sprinklerCount}'),
          ],
          // Only when a standpipe is drawn (or nothing is — the draft basis).
          if (hasHydrantEdges || !hasFireEdges)
            kv(
              'Standpipe flow',
              '${standpipe.requiredFlow.inLitersPerSecond.toStringAsFixed(1)} L/s',
            ),
          const SizedBox(height: MechXSpacing.xs),
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: MechXSpacing.xs),
                decoration: BoxDecoration(
                  color: colors.warning,
                  borderRadius: MechXRadii.small,
                ),
              ),
              Expanded(
                child: Text(
                  hasFireEdges
                      ? (hasHydrantEdges
                          ? 'SNI 03-3989 / 1745 / 6570 · '
                              '$standpipeRisers-riser standpipe demand'
                          : 'SNI 03-3989 / 6570 · sprinkler remote-area demand')
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

/// The BOM's single 'Calibrate the sheet to measure N runs' caption: expands
/// the Scale section and scrolls the inspector to it.
class _CalibrateToMeasureHint extends ConsumerWidget {
  final int runCount;
  const _CalibrateToMeasureHint({required this.runCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final label = runCount == 1
        ? context.strings(StringKey.bomCalibrateHintOne)
        : context.strings.format(StringKey.bomCalibrateHint, {'n': runCount});
    void reveal() {
      ref.read(sectionVisibilityProvider.notifier).set('Scale', true);
      ref.read(sectionRevealProvider.notifier).reveal('Scale');
    }

    return Padding(
      padding: const EdgeInsets.only(top: MechXSpacing.xxs),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: MechXFocusRing(
          onActivated: reveal,
          child: GestureDetector(
            key: const ValueKey('bom-calibrate-hint'),
            onTap: reveal,
            behavior: HitTestBehavior.opaque,
            child: Semantics(
              button: true,
              child: Text(
                label,
                style: context.type.caption.copyWith(color: colors.warning),
              ),
            ),
          ),
        ),
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
                    color: selected ? colors.textPrimary : colors.textSecondary,
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

    final net = ref.watch(sizingNetworkProvider);
    final ctrl = ref.read(networkControllerProvider.notifier);
    final selCtrl = ref.read(selectionProvider.notifier);

    // Multi-selection: a count header + Copy / Paste / Delete actions (the
    // single-element editor is shown only for a single selection).
    if (selection.isMulti) {
      return _multiSelectionSection(
        context,
        ref,
        net,
        selection,
        ctrl,
        selCtrl,
      );
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

    // C3 — the selection outlives a sheet switch, so this editor could offer a
    // full set of MUTATING controls for an element the engineer cannot see (on
    // another floor's plan). Badge the header with the owning sheet and make the
    // body read-only in that state: the edit belongs where the element is. Null
    // (the normal case: the target is on the current sheet) ⇒ byte-identical.
    final sheets = ref.watch(sheetsContentProvider);
    final elsewhereId = owningSheetIfElsewhere(
      net,
      nodeId: selection.nodeId,
      edgeId: selection.edgeId,
      currentSheetId: sheets.current?.id,
    );
    final strings = context.strings;
    final colors = context.colors;
    final type = context.type;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: MechXSectionLabel('Selection')),
            InspectorGlyphButton(glyph: '×', onTap: selCtrl.clear),
          ],
        ),
        if (elsewhereId != null) ...[
          const SizedBox(height: MechXSpacing.xs),
          Text(
            strings.format(StringKey.selectionOnOtherSheetTemplate, {
              'sheet': sheets.sheetById(elsewhereId)?.name ?? elsewhereId,
            }),
            style: type.caption.copyWith(color: colors.warning),
          ),
          const SizedBox(height: 2),
          Text(
            strings(StringKey.selectionOffSheetReadOnly),
            style: type.caption.copyWith(color: colors.textMuted),
          ),
        ],
        const SizedBox(height: MechXSpacing.sm),
        if (elsewhereId == null)
          body
        else
          // Every mutating control in the editor stands down; the header's ×
          // (clear selection) stays live above.
          IgnorePointer(child: Opacity(opacity: 0.5, child: body)),
        const SizedBox(height: MechXSpacing.lg),
      ],
    );
  }

  Widget _multiSelectionSection(
    BuildContext context,
    WidgetRef ref,
    Network net,
    Selection selection,
    NetworkController ctrl,
    SelectionController selCtrl,
  ) {
    final colors = context.colors;
    final type = context.type;
    final n = selection.nodeIds.length;
    final m = selection.edgeIds.length;

    // C3 — the selection outlives sheet and layer switches, so the batch
    // appliers (and Delete) below could silently rewrite elements on another
    // floor or on a hidden/locked layer. Scope them with the SAME precondition
    // the canvas hit-test uses: on the current sheet, on a visible + unlocked
    // service. Off-scope members drop out of every operation here, and the
    // header says how many were left alone. Nothing hidden/locked and one sheet
    // ⇒ the scoped sets equal the raw selection (byte-identical).
    final scope = scopeSelection(
      net: net,
      nodeIds: selection.nodeIds,
      edgeIds: selection.edgeIds,
      sheetId: ref.watch(sheetsContentProvider).current?.id,
      inertServices: ref.watch(inertServicesProvider),
    );
    final edgeIds = scope.edgeIds;
    final nodeIds = scope.nodeIds;

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
    // E2 — the batch header names the floor span: a scoped select-similar is
    // single-floor, but a marquee or the all-floors variant can span the
    // building, and 'Apply to 14 selected' must not hide that.
    final applyFloors = <int>{
      for (final e in selEdges) ...[
        if (net.nodeById(e.fromId) case final a?) a.floorIndex,
        if (net.nodeById(e.toId) case final b?) b.floorIndex,
      ],
      for (final nd in selNodes) nd.floorIndex,
    };

    Widget label(String text) =>
        Text(text, style: type.caption.copyWith(color: colors.textMuted));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: MechXSectionLabel('Selection')),
            InspectorGlyphButton(glyph: '×', onTap: selCtrl.clear),
          ],
        ),
        const SizedBox(height: MechXSpacing.sm),
        Text(
          '$n ${n == 1 ? 'node' : 'nodes'} / $m ${m == 1 ? 'edge' : 'edges'} '
          'selected',
          // L2: the counts change live while marquee-selecting.
          style: MechXTypography.tabular(
            type.caption.copyWith(color: colors.textMuted),
          ),
        ),
        // C3 — name what this panel will NOT touch, rather than quietly doing
        // less than the count above implies. Absent when nothing is off-scope.
        if (scope.hasExcluded) ...[
          const SizedBox(height: 2),
          Text(
            context.strings.format(StringKey.selectionOffScopeAppliedTemplate, {
              'count': pluralCount(
                scope.excludedCount,
                'selected element',
                'selected elements',
              ),
            }),
            style: type.caption.copyWith(color: colors.warning),
          ),
        ],
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
                final levelCount = ref
                    .read(projectControllerProvider)
                    .building
                    .levelCount;
                final floorIndex = ref
                    .read(sheetsControllerProvider)
                    .floorFor(sheet.id, levelCount);
                ctrl.paste(sheetId: sheet.id, floorIndex: floorIndex);
              },
            ),
            MechXButton(
              label: 'Delete',
              onPressed: () {
                // C3 — delete only what is in scope (the canvas Delete key
                // applies the same guard); the excluded caption above already
                // names what survives.
                if (scope.hasExcluded) {
                  ref
                      .read(statusMessageProvider.notifier)
                      .showStatus(
                        context.strings.format(
                          StringKey.selectionOffScopeDeletedTemplate,
                          {
                            'count': pluralCount(
                              scope.excludedCount,
                              'selected element',
                              'selected elements',
                            ),
                          },
                        ),
                      );
                }
                ctrl.deleteMany(scope.nodeIds, scope.edgeIds);
                selCtrl.clear();
              },
            ),
          ],
        ),

        // ── E1: batch property editors on a HOMOGENEOUS selection ─────────────
        if (showApply) ...[
          const SizedBox(height: MechXSpacing.lg),
          MechXSectionLabel(
            applyFloors.length > 1
                ? 'Apply to $applyCount selected across ${applyFloors.length} floors'
                : 'Apply to $applyCount selected',
          ),
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
                      (nd) => nd.customFixtureId == null && nd.fixture == f,
                    ),
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
                  selected: selNodes.every(
                    (nd) => nd.faceWidthMm == null || nd.faceHeightMm == null,
                  ),
                  onTap: () => ctrl.setNodesFaceSize(nodeIds, null, null),
                ),
                for (final face in standardGrilleFacesMm)
                  _Pill(
                    label: '${face.$1.round()}x${face.$2.round()}',
                    selected: selNodes.every(
                      (nd) =>
                          nd.faceWidthMm == face.$1 &&
                          nd.faceHeightMm == face.$2,
                    ),
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

  Widget _nodeEditor(
    BuildContext context,
    WidgetRef ref,
    NetNode node,
    NetworkController ctrl,
    SelectionController selCtrl,
  ) {
    final project = ref.watch(projectControllerProvider);
    final net = ref.watch(sizingNetworkProvider);
    // Round 21 review — a node on a GRAVITY riser reads the same riser-end
    // datum its riser length is measured from (one engine helper, shared
    // with the Layout hover FFL chip).
    final elev = displayedNodeElevation(
            net, node, project.building, project.mounting)
        .meters;

    // Scope the fixture field groups to the node's ACTUAL discipline, derived
    // from its connected edges — a WC must not offer a diffuser-airflow
    // stepper, nor a supply diffuser the WC/urinal pills. An unconnected node
    // falls back to showing a group (nothing becomes unreachable before its
    // pipes are drawn) unless its component already rules the group out; a
    // group with a value set always shows so it stays editable/clearable.
    final touching = <ServiceType>{
      for (final e in net.edges)
        if (e.fromId == node.id || e.toId == node.id) e.service,
    };
    final airTerminal = switch (node.component) {
      NodeComponent.supplyDiffuser ||
      NodeComponent.returnGrille ||
      NodeComponent.exhaustGrille ||
      NodeComponent.linearDiffuser => true,
      _ => false,
    };
    final plumbingTouch = touching.any(
      (s) =>
          s == ServiceType.coldWater ||
          s == ServiceType.hotWater ||
          s == ServiceType.drainage ||
          s == ServiceType.vent,
    );
    final airTouch = touching.any((s) => s.isAir);
    final rainTouch = touching.contains(ServiceType.rainwater);
    final unconnected = touching.isEmpty;
    final showFixtureType =
        plumbingTouch ||
        node.fixture != null ||
        node.customFixtureId != null ||
        (unconnected && !airTerminal);
    final showAirflow =
        airTouch ||
        airTerminal ||
        node.airflow != null ||
        (unconnected && node.fixture == null && node.customFixtureId == null);
    final showRoofArea =
        rainTouch ||
        node.roofAreaM2 != null ||
        node.component == NodeComponent.roofDrain ||
        (unconnected && !airTerminal);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Node · floor ${node.floorIndex + 1} · elev '
          '${elev.toStringAsFixed(1)} m',
          // L2: floor/elevation update in place as the node is edited.
          style: MechXTypography.tabular(
            context.type.caption.copyWith(color: context.colors.textMuted),
          ),
        ),
        // I2 — the pressure-solve PROBE. Whenever the solve has a residual for
        // this node, surface its actual residual pressure so a fixture can be
        // spot-checked against the SNI target the heatmap colour alone can't
        // name. For a demand (fixture) node it carries the PASS/LOW verdict
        // against that target (min residual); other nodes just show the value.
        Builder(
          builder: (context) {
            final residual = ref.watch(residualByNodeProvider)[node.id];
            if (residual == null) return const SizedBox.shrink();
            final target = ref.watch(targetResidualProvider);
            final kpa = residual.inKiloPascals;
            final isFixture = node.role == NodeRole.fixture;
            // Mirror the heatmap legend's 0.5 kPa slack (= 500 Pa), NOT 0.5 Pa —
            // both verdicts read the same targetResidualProvider, so they must use
            // the same-unit tolerance or a sub-target residual splits PASS vs LOW.
            // Round 33 — the shared ladder: LOW only below this node's own
            // SNI 8153 floor; floor met but under the comfort target reads
            // 'below target' (advisory), never a red LOW against 225 kPa.
            final sniFloor = ref.watch(sniFloorByNodeProvider)[node.id];
            final v = residualVerdict(
                residualPa: residual.pascals,
                targetPa: target.pascals,
                sniFloorPa: sniFloor?.pascals);
            final pass = v == ResidualVerdict.pass;
            // M9 — on the UPFEED solve the pump head is DEFINED as the max of
            // (friction + elevation + target), so residual >= target is an
            // algebraic identity: no drawn network can make this probe read LOW.
            // Printing a green PASS off an unfalsifiable inequality is the same
            // lie the 'all sheets calibrated' row was. Say what is true instead —
            // the target is held BY DESIGN, and the falsifiable question (can a
            // real pump deliver the required head?) lives on the pump duty.
            final held =
                ref.watch(upfeedDeliveredProvider)?.targetHeldByDesign ?? false;
            final targetTxt = '${context.strings(StringKey.heatmapTarget).toLowerCase()} '
                '${target.inKiloPascals.toStringAsFixed(0)} kPa';
            final verdict = !isFixture
                ? ''
                : held
                ? ' · target held by design ($targetTxt) - '
                      '${context.strings(StringKey.heatmapRealCheckPumpDuty)}'
                : switch (v) {
                    ResidualVerdict.low => sniFloor == null
                        ? ' · LOW ($targetTxt)'
                        : ' · LOW (${context.strings(StringKey.heatmapSniMin)} '
                            '${sniFloor.inKiloPascals.toStringAsFixed(0)} kPa)',
                    ResidualVerdict.belowTarget =>
                      ' · ${context.strings(StringKey.heatmapBelowTarget)} '
                          '($targetTxt)',
                    ResidualVerdict.pass => ' · PASS ($targetTxt)',
                  };
            return Padding(
              padding: const EdgeInsets.only(top: MechXSpacing.xxs),
              child: Text(
                'Residual ${kpa.toStringAsFixed(0)} kPa$verdict',
                // L2: the probe re-reads every solve — tabular kPa digits.
                style: MechXTypography.tabular(
                  context.type.caption.copyWith(
                    color: !isFixture || held
                        ? context.colors.textSecondary
                        : (pass
                              ? context.colors.success
                              : v == ResidualVerdict.belowTarget
                              ? context.colors.warning
                              : context.colors.danger),
                  ),
                ),
              ),
            );
          },
        ),
        if (node.component != null) ...[
          const SizedBox(height: MechXSpacing.xxs),
          Row(
            children: [
              ComponentSymbol(
                component: node.component!,
                color: context.colors.textSecondary,
                size: 15,
              ),
              const SizedBox(width: MechXSpacing.xs),
              Expanded(
                child: Text(
                  node.component!.label,
                  style: context.type.body.copyWith(
                    color: context.colors.textPrimary,
                  ),
                ),
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
            Text(
              'Tank capacity (prebuilt)',
              style: context.type.caption.copyWith(
                color: context.colors.textMuted,
              ),
            ),
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
                node.id,
                (node.tankCapacityLitres ?? 0) + 500,
              ),
              onSubmit: (v) => ctrl.setNodeTankCapacity(
                node.id,
                (v == null || v <= 0) ? null : v,
              ),
            ),
          ],
          // A motorised component (pump / fan / air unit) is INTER-RELATED with
          // the electrical model: it feeds the MEP equipment panel as its own
          // circuit. Edit its electrical load here (kW); blank ⇒ the default
          // rating for this equipment.
          if (node.component!.isElectricalLoad) ...[
            const SizedBox(height: MechXSpacing.xs),
            Text(
              'Electrical load (feeds the panel)',
              style: context.type.caption.copyWith(
                color: context.colors.textMuted,
              ),
            ),
            const SizedBox(height: MechXSpacing.xxs),
            // Round 13 (ui-journey-2) — the figure shown, and the +/- base,
            // are the load the panel ACTUALLY carries ([nodeFedLoadsProvider]:
            // explicit → solved duty → room PK → component default), labelled
            // by source; the edit box pre-fills only an explicit override, so
            // a look-and-leave can never pin the default as an override.
            Builder(builder: (context) {
              final fed = ref.watch(nodeFedLoadsProvider)[node.id];
              final fedW =
                  fed?.watts ?? node.component!.defaultMotorKw * 1000;
              final strings = context.strings;
              final suffix = switch (fed?.source) {
                NodeLoadSource.explicit => '',
                NodeLoadSource.solvedDuty =>
                  ' · ${strings(StringKey.nodeLoadSourceDuty)}',
                NodeLoadSource.roomPk =>
                  ' · ${strings(StringKey.nodeLoadSourceRoomPk)}',
                NodeLoadSource.roomAir =>
                  ' · ${strings(StringKey.nodeLoadSourceRoomAir)}',
                _ => ' · ${strings(StringKey.nodeLoadSourceDefault)}',
              };
              return SteppedValueField(
                display: '${(fedW / 1000).toStringAsFixed(2)} kW$suffix',
                label: strings(StringKey.nodeElectricalLoadLabel),
                editSeed: node.electricalLoadW == null
                    ? ''
                    : (node.electricalLoadW! / 1000).toStringAsFixed(2),
                gap: MechXSpacing.sm,
                min: 0,
                onDecrement: () {
                  final next = fedW - 250;
                  ctrl.setNodeElectricalLoad(
                      node.id, next <= 0 ? null : next);
                },
                onIncrement: () =>
                    ctrl.setNodeElectricalLoad(node.id, fedW + 250),
                // The typed value is in kW (the displayed unit); store as W.
                onSubmit: (v) => ctrl.setNodeElectricalLoad(
                  node.id,
                  (v == null || v <= 0) ? null : v * 1000,
                ),
              );
            }),
          ],
        ],
        // E2: identity first — the fixture/type group (below, gated on the
        // fixture role) leads the node editor; Role + Mounting height are
        // demoted into the collapsed "Placement" disclosure further down.
        if (node.role == NodeRole.fixture) ...[
          if (showFixtureType) ...[
            const SizedBox(height: MechXSpacing.sm),
            Text(
              'Fixture type',
              style: context.type.caption.copyWith(
                color: context.colors.textMuted,
              ),
            ),
            const SizedBox(height: MechXSpacing.xs),
            Wrap(
              spacing: MechXSpacing.xs,
              runSpacing: MechXSpacing.xs,
              children: [
                for (final f in PlumbingFixture.values)
                  _Pill(
                    label: fixtureLabel(f),
                    selected: node.customFixtureId == null && node.fixture == f,
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
            Text(
              'Air terminal (diffuser) airflow',
              style: context.type.caption.copyWith(
                color: context.colors.textMuted,
              ),
            ),
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
                  node.id,
                  lps <= 0 ? null : FlowRate.litersPerSecond(lps),
                );
              },
              onIncrement: () {
                final lps = (node.airflow?.inLitersPerSecond ?? 0) + 5;
                ctrl.setNodeAirflow(node.id, FlowRate.litersPerSecond(lps));
              },
              onSubmit: (v) => ctrl.setNodeAirflow(
                node.id,
                (v == null || v <= 0) ? null : FlowRate.litersPerSecond(v),
              ),
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
              Text(
                'Diffuser / grille face size',
                style: context.type.caption.copyWith(
                  color: context.colors.textMuted,
                ),
              ),
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
                      selected:
                          node.faceWidthMm == face.$1 &&
                          node.faceHeightMm == face.$2,
                      onTap: () => ctrl.setNodeFace(node.id, face.$1, face.$2),
                    ),
                ],
              ),
              const SizedBox(height: MechXSpacing.xs),
              Builder(
                builder: (context) {
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
                },
              ),
            ],
          ],
          if (showRoofArea) ...[
            const SizedBox(height: MechXSpacing.sm),
            Text(
              'Rainwater outlet roof area',
              style: context.type.caption.copyWith(
                color: context.colors.textMuted,
              ),
            ),
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
              onSubmit: (v) => ctrl.setNodeRoofArea(
                node.id,
                (v == null || v <= 0) ? null : v,
              ),
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
              Text(
                'Mounting height (above floor)',
                style: context.type.caption.copyWith(
                  color: context.colors.textMuted,
                ),
              ),
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
                      final base =
                          node.mountHeight?.meters ??
                          ref.read(mountingProvider).fixtureHeight.meters;
                      final next = base - 0.05;
                      // Stepping down through floor level reverts to the role
                      // default.
                      ctrl.setNodeMountHeight(
                        node.id,
                        next <= 0 ? null : Length(next),
                      );
                    },
                    onIncrement: () {
                      final base =
                          node.mountHeight?.meters ??
                          ref.read(mountingProvider).fixtureHeight.meters;
                      ctrl.setNodeMountHeight(node.id, Length(base + 0.05));
                    },
                    // The typed value is in cm (the displayed unit); store as
                    // metres. A non-positive / empty entry reverts to the role
                    // default.
                    onSubmit: (v) => ctrl.setNodeMountHeight(
                      node.id,
                      (v == null || v <= 0) ? null : Length(v / 100),
                    ),
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

  Widget _edgeEditor(
    BuildContext context,
    WidgetRef ref,
    NetEdge edge,
    Network net,
    NetworkController ctrl,
    SelectionController selCtrl,
  ) {
    final project = ref.watch(projectControllerProvider);
    final sizing = ref.watch(sizingProvider)[edge.id];
    final len = projectEdgeLength(edge, net, project).meters;
    final kind = edge.kind == EdgeKind.riser ? 'Riser / drop' : 'Run';
    final sizeStr = sizing == null
        ? '—'
        : '${edge.service.regime == FlowRegime.air ? 'Ø' : 'DN'}'
              '${sizing.diameter.inMillimeters.round()}';
    final material = edgeMaterialLabel(edge);
    // Per-segment duct sheet-material takeoff (developed m² + standard sheets)
    // and the ducting accessories (covering angle / gasket / hangers / bolts).
    final takeoff = sizing == null ? null : ductSheetTakeoff(edge, sizing, len);
    final accessories = sizing == null
        ? null
        : computeDuctAccessories(edge, sizing, len);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$kind · ${len.toStringAsFixed(2)} m · $sizeStr'
          '${edge.sizeOverride != null ? ' (set)' : ''}',
          // L2: length/size track the drag live — tabular digits.
          style: MechXTypography.tabular(
            context.type.caption.copyWith(color: context.colors.textMuted),
          ),
        ),
        // E3: the editable controls (size / material / service) lead; the
        // read-only procurement takeoff is demoted into the "Details" disclosure
        // below. These use the SAME setters the right-click menu does — the
        // "Auto" size step clears the override; "Default"/"Auto" material falls
        // back to the service default.
        const SizedBox(height: MechXSpacing.sm),
        Text(
          'Size',
          style: context.type.caption.copyWith(color: context.colors.textMuted),
        ),
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
          Builder(
            builder: (context) {
              final check = ref.watch(airVelocityChecksProvider)[edge.id];
              final msg =
                  check?.message ??
                  '${sizing.velocity.metersPerSecond.toStringAsFixed(1)} m/s';
              return Text(
                'Air velocity: $msg',
                // L2: the m/s readout tracks the live sizing.
                style: MechXTypography.tabular(
                  context.type.caption.copyWith(
                    color: (check != null && check.isWarning)
                        ? context.colors.danger
                        : context.colors.textSecondary,
                  ),
                ),
              );
            },
          ),
        ],
        // I3 — water / drainage velocity vs the SNI max pipe-velocity band. The
        // auto-sizer sizes TO this limit (SNI 03-7065-2005 caps supply at
        // 2,0 m/s), but the resulting velocity was previously invisible for
        // non-air pipes. Surface it with the SAME verdict idiom the air path
        // uses so the engineer can certify the SNI velocity compliance live.
        if (!edge.service.isAir && sizing != null) ...[
          Builder(
            builder: (context) {
              final check = ref.watch(waterVelocityChecksProvider)[edge.id];
              if (check == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: MechXSpacing.xxs),
                child: Text(
                  'Velocity: ${check.message}',
                  // L2: the m/s readout tracks the live sizing.
                  style: MechXTypography.tabular(
                    context.type.caption.copyWith(
                      color: check.isWarning
                          ? context.colors.danger
                          : context.colors.textSecondary,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
        // M16 — the drainage stack≥branch clamp, named. When the sizer raised
        // this stack to match the largest branch entering it, its size did NOT
        // come from its own DFU load, and an engineer checking "why DN75 not
        // DN65?" must be able to read that here (the same note the calc
        // report's run schedule now footnotes).
        if (sizing != null && sizing.stackRaisedForBranch) ...[
          const SizedBox(height: MechXSpacing.xxs),
          Text(
            'Stack raised to match branch — sized up to the largest branch '
            'entering it, not from its own load.',
            style: context.type.caption.copyWith(
              color: context.colors.textSecondary,
            ),
          ),
        ],
        // Soft advisory: this air duct carries air but isn't manually sized yet.
        if (ref.watch(airUnsizedProvider).contains(edge.id)) ...[
          const SizedBox(height: MechXSpacing.xxs),
          Text(
            'Auto-sized — no duct size chosen yet.',
            style: context.type.caption.copyWith(
              color: context.colors.textMuted,
            ),
          ),
        ],
        const SizedBox(height: MechXSpacing.sm),
        Text(
          'Material',
          style: context.type.caption.copyWith(color: context.colors.textMuted),
        ),
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
                  Text(
                    'Material: $material',
                    style: context.type.caption.copyWith(
                      color: context.colors.textSecondary,
                    ),
                  ),
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
                    style: MechXTypography.tabular(
                      context.type.caption.copyWith(
                        color: context.colors.textSecondary,
                      ),
                    ),
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
                    style: MechXTypography.tabular(
                      context.type.caption.copyWith(
                        color: context.colors.textSecondary,
                      ),
                    ),
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
    final fan = ref.watch(ductFanProvider);
    final exhaust = ref.watch(exhaustFanProvider);
    final balance = ref.watch(airBalanceProvider);

    // The shared value-wins row (L1) — the label yields, the figure never
    // truncates.
    Widget kv(String k, String v) => _kvRow(context, k, v);

    return DisclosureSection(
      name: 'HVAC · ducting',
      // E1: expand only when air elements exist (a sized fan, or a supply/return
      // balance). A plumbing-only launch keeps a quiet collapsed header rather
      // than opening on a "Draw a duct network…" empty prompt.
      defaultExpanded: fan != null || exhaust != null || balance != null,
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
                onTap: () => setDuctShapeUndoable(ref.read, DuctShape.round),
              ),
              _Pill(
                label: 'Rectangular',
                selected: settings.shape == DuctShape.rectangular,
                onTap: () =>
                    setDuctShapeUndoable(ref.read, DuctShape.rectangular),
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
                onTap: () =>
                    setDuctMethodUndoable(ref.read, DuctSizingMethod.velocity),
              ),
              _Pill(
                label: 'Equal friction',
                selected: settings.method == DuctSizingMethod.equalFriction,
                onTap: () => setDuctMethodUndoable(
                  ref.read,
                  DuctSizingMethod.equalFriction,
                ),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          if (fan == null && exhaust == null)
            Text(
              'Draw a duct network and assign diffuser airflows.',
              style: type.caption.copyWith(color: colors.textMuted),
            )
          else if (fan != null) ...[
            // Promoted headline: fan total static + selected motor. Only rendered
            // once a fan exists, so the blank/golden launch is byte-identical.
            // M11: a duty past the largest standard frame prints the clamp
            // honestly instead of a clean, green figure.
            ResultCard(
              headline:
                  '${fan.totalStaticPressure.pascals.toStringAsFixed(0)} Pa',
              label:
                  'Fan static · '
                  '${fan.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW motor'
                  '${fan.motorOversized ? ' · above standard frame' : ''}',
              verdict: fan.motorOversized ? 'over frame' : 'sized',
              verdictColor: fan.motorOversized ? colors.danger : colors.success,
            ),
            const SizedBox(height: MechXSpacing.xs),
            // 'Fan static' + 'Fan motor' are the ResultCard headline/label above;
            // keep only the distinct supporting figures (H8 — no duplication).
            kv(
              'Trunk airflow',
              '${fan.airflow.inLitersPerSecond.toStringAsFixed(0)} L/s',
            ),
            kv(
              'Fan power',
              '${fan.shaftPower.inKiloWatts.toStringAsFixed(2)} kW',
            ),
          ],
          if (exhaust != null) ...[
            if (fan != null) const SizedBox(height: MechXSpacing.xs),
            // The separate exhaust system's own fan (its own index run).
            ResultCard(
              headline:
                  '${exhaust.totalStaticPressure.pascals.toStringAsFixed(0)} Pa',
              label:
                  context.strings.format(
                    StringKey.inspectorExhaustFanLabelTemplate,
                    {
                      'kw': exhaust.selectedMotor.inKiloWatts.toStringAsFixed(
                        2,
                      ),
                    },
                  ) +
                  (exhaust.motorOversized ? ' · above standard frame' : ''),
              verdict: exhaust.motorOversized ? 'over frame' : 'sized',
              verdictColor: exhaust.motorOversized
                  ? colors.danger
                  : colors.success,
            ),
            const SizedBox(height: MechXSpacing.xs),
            kv(
              context.strings(StringKey.inspectorExhaustAirflow),
              '${exhaust.airflow.inLitersPerSecond.toStringAsFixed(0)} L/s',
            ),
          ],
          if (balance != null) ...[
            const SizedBox(height: MechXSpacing.xs),
            kv('Supply air', '${balance.supplyLps.toStringAsFixed(0)} L/s'),
            kv('Return air', '${balance.returnLps.toStringAsFixed(0)} L/s'),
            kv(
              'Air balance',
              _balanceLabel(balance.supplyLps, balance.returnLps),
            ),
          ],
        ],
      ),
    );
  }
}

String _balanceLabel(double supplyLps, double returnLps) {
  if (returnLps <= 0) return 'no return drawn';
  if (supplyLps <= 0) return 'return only';
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

/// A motor-frame kW figure as a schedule prints it: whole frames bare (`75`),
/// fractional frames trimmed (`0.55`, `5.5`).
/// Round 17 follow-up — the Fire inspector headline: the governing rated
/// point's HEAD (`fireRatedPointProvider`) beside the NFPA 20 motor sized on
/// that same point, so the card can never pair a standpipe head with a
/// sprinkler-rated motor. Public for the regression test.
String fireHeadlineText(Head head, Power motor) =>
    '${head.meters.toStringAsFixed(0)} m · ${_motorKw(motor)} kW motor';

/// The headline label names the system the pump is rated on.
String fireHeadlineLabel({required bool sprinklerOnly}) =>
    sprinklerOnly ? 'Fire pump (sprinkler)' : 'Fire pump (standpipe)';

String _motorKw(Power p) {
  final v = p.inKiloWatts;
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// An ACH figure for the Rooms inspector: whole numbers bare (`6`), anything
/// else to one decimal (`2.5`) — never rounded to an integer (Round 13).
String _fmtAch(double v) =>
    (v - v.roundToDouble()).abs() < 1e-9 ? '${v.round()}' : v.toStringAsFixed(1);

/// Round 22 (pressurized-3-1) — the downfeed zone table is shown / printed
/// only when it says something: a PRV station is needed, or a zone is over
/// the limit. A building the roof tank's own head keeps under the limit is one
/// tank-fed zone with no PRV — no table.
bool _zoneTableNeeded(List<DownfeedZoneStatic> statics) =>
    statics.any((z) => z.viaPrv || !z.withinLimit);

/// Round 33 r2 (engineer-walkthrough-plan-fixtures-anonymous) — the node tags
/// every plan export prints: the stable equipment tags (P-01 / TK-01 …) over
/// the custom-library fixtures' short names, so a fixture typed from the user
/// library is never anonymous on the issued plan (PDF == DXF — both read this
/// one map). Built-in fixtures keep their WC / LAV codes inside the engine.
Map<String, String> planExportNodeTags(
        Network net, List<CustomFixture> library) =>
    {
      ...customFixturePlanTags(net, library),
      ...equipmentNodeTags(net),
    };
