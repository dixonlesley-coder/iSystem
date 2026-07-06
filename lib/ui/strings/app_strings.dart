import 'package:flutter/widgets.dart';

import '../../store/app_state.dart';

/// Stable, symbolic keys for every localisable UI string. Adding a key here
/// (and to BOTH [_en] and [_id]) is how a literal becomes translatable; the
/// i18n test asserts the two maps carry exactly the same key set.
///
/// EN values are deliberately BYTE-IDENTICAL to the literals they replace so
/// the default rendered text — and therefore the golden screenshots — never
/// moves when a literal is migrated.
enum StringKey {
  // Left navigation rail.
  navGroupDesign,
  navLayout,
  navSchematic,
  navElectrical,
  navBuilding,
  navReview,
  navCommercial,
  navProjects,
  navPreferences,

  // Preferences screen.
  prefsTitle,
  prefsLead,
  prefsAppearance,
  prefsDark,
  prefsLight,
  prefsSwitchToLight,
  prefsSwitchToDark,
  prefsLanguage,

  // Commercial workspace — hub.
  commercialHubTitle,
  commercialHubLead,
  commercialExportBomCsv,
  commercialExportProposalMd,

  // Commercial workspace — electrical BOM.
  commercialBomTitle,
  commercialColQty,
  commercialColPart,
  commercialColBrand,
  commercialColSku,
  commercialColMatch,
  commercialMatched,
  commercialUnmatched,
  commercialBomLead, // {lines} {unmatched}

  // Commercial workspace — pricelist.
  commercialPricelistTitle,
  commercialColUnit,
  commercialColUnitPrice,
  commercialPricelistLead, // {priced} {total}

  // Commercial workspace — quotation.
  commercialQuotationTitle,
  commercialAllPriced,
  commercialUnpricedExcluded, // {n}
  commercialLabourRate, // {cur}
  commercialColAmount, // {cur}
  commercialLabourHours, // {hours}
  commercialQuoteSettings,
  commercialOverheadPct,
  commercialContingencyPct,
  commercialMarginPct,
  commercialColItem,
  commercialItemMaterial,
  commercialItemOverhead,
  commercialItemContingency,
  commercialItemMargin,
  commercialItemGrandTotal,

  // Commercial workspace — shared table.
  commercialNoItems,

  // Electrical — Export menu.
  electricalExportSld,
  electricalExportSldDxf,
  electricalExportSldPdf,
  electricalExportOverview,
  electricalExportOverviewPdf,
  electricalExportOverviewDxf,
  electricalExportRiser,
  electricalExportRiserPdf,
  electricalExportRiserDxf,
  electricalExportReport,
  electricalExportReportSub,
  electricalExportPowerOneLine,
  electricalExportPowerOneLineSub,
  electricalExportPlan,
  electricalExportSchedules,
  electricalExportSchedulesPdf,

  // Mechanical riser — Export menu (the B3 drawing set).
  mechExportAllSystems,
  mechExportAllSystemsPdf,
  mechExportAllSystemsDxf,

  // Electrical — Service & Earthing (Fold-1 fields).
  electricalOriginFaultLevel,
  electricalOriginFaultLevelNote,
  electricalBusbarClearingTime,
  electricalBusbarClearingTimeNote,

  // Electrical — Sources editor (genset / capacitor / transformer / dual-tx).
  electricalSources,
  electricalSourcesNote,
  electricalGenset,
  electricalGensetPresent,
  electricalGensetKva,
  electricalGensetMode,
  electricalGensetTransfer,
  electricalTransformerKva,
  electricalTransformerKvaNote,
  electricalCapacitorKvar,
  electricalCapacitorKvarNote,
  electricalDualTransformer,
  electricalGensetModeStandby,
  electricalGensetModePrime,
  electricalGensetTransferAts,
  electricalGensetTransferManual,

  // App shell — top bar.
  shellOpen,
  shellSave,
  shellImportPdf,
  shellDark,
  shellLight,
  shellSwitchToDark,
  shellSwitchToLight,

  // App shell — status bar.
  shellNoSheet,
  shellUncalibrated,
  shellCalibrated,
  shellCalibrationStale, // J1 — sheet-rail tooltip: plan replaced, re-verify scale
  shellStandardsProvenance,
  shellViewportHints,

  // App shell — banners.
  shellRecoverPrompt, // {name} {when}
  shellRecoverJustNow,
  shellRecoverMinutesAgo, // {n}
  shellRecoverHoursAgo, // {n}
  shellRecoverAtTime, // {time}
  shellRecoverEarlier,
  shellRestore,
  shellDismiss,
  shellDiscardSnapshot,
  shellDiscardConfirm,

  // App shell — busy pill (slow foreground operations).
  busyImportingPlan,
  busyConvertingDwg,
  busyOpeningProject,
  busySaving,
  busyExportingSubmittal, // {current} {total} — J2 per-sheet submittal export

  // Unsaved-changes guard dialog (Open / Import / quit).
  confirmDiscardTitle,
  confirmDiscardBody,
  confirmDiscardSave,
  confirmDiscardDiscard,
  confirmDiscardCancel,

  // App shell — Layout electrical inspector.
  shellElectricalLayer,
  shellElectricalLayerHelp,

  // Schematic / elevation — toolbar + palette.
  schematicAuto,
  schematicEdit,
  schematicRiserService,
  schematicSystemAll,
  schematicInferRisers,
  schematicLegend,
  schematicTitleBlock,
  schematicDetails,
  schematicNotes,
  schematicTitleSheet,
  schematicTitleSingleLine,
  schematicTitleCleanWaterRiser,
  schematicTitleHotWaterRiser,
  schematicTitleDrainageRiser,
  schematicTitleVentRiser,
  schematicTitleStormRiser,
  schematicTitleAirRiser,
  schematicTitleFireRiser,
  schematicNoNetwork,
  schematicPalette,
  schematicPaletteHelp,
  schematicRiser,
  schematicAddFloorBanner,

  // Schematic / elevation — help popover.
  schematicElevationGuide,
  schematicClose,
  canvasGuideTitle,
  schematicHelp1,
  schematicHelp2,
  schematicHelp3,
  schematicHelp4,
  schematicHelp5,
  schematicHelp6,
  schematicHelpModes,

  // Inspector — section labels.
  inspectorProject,
  inspectorBuilding,
  inspectorDraw,
  inspectorSizing,
  inspectorNetwork,
  inspectorFire,
  inspectorHvacDucting,
  inspectorSheet,
  inspectorScale,
  inspectorSelection,

  // Inspector — Project section.
  inspectorExportCalcReportMd,
  inspectorExportCalcReportPdfBtn,
  inspectorExportMepReportMd,
  inspectorExportMepReportPdfBtn,
  inspectorExportEquipmentScheduleMd,
  inspectorExportEquipmentSchedulePdfBtn,
  inspectorExportDrawingDxf,
  inspectorExportDrawingPdf,
  inspectorExportAnnotatedPlanPdf,

  // Inspector — Building section.
  inspectorAddLevel,

  // Inspector — Draw section.
  inspectorSelect,
  inspectorRun,
  inspectorRiser,
  inspectorUndo,
  inspectorRedo,
  inspectorClear,
  inspectorOrtho,
  inspectorSnapToPlan,
  inspectorRefLine,
  inspectorDuplicateFloorUp,

  // Inspector — Sizing section.
  inspectorHideSizes,
  inspectorShowSizes,
  inspectorSizingNote,
  inspectorOccupancy,
  inspectorRainfallStorm,

  // Inspector — occupancy labels.
  inspectorOccupancyResidential,
  inspectorOccupancyPublic,
  inspectorOccupancyAssembly,

  // Inspector — Network section.
  inspectorUpfeedPump,
  inspectorRoofTankDownfeed,
  inspectorHideHeatmap,
  inspectorShowHeatmap,
  inspectorExportBomCsv,

  // Inspector — Selection section.
  inspectorDeleteNode,
  inspectorFixtureType,
  inspectorAirTerminalAirflow,
  inspectorClearSizeOverride,
  inspectorEdgeSizeHint,

  // Inspector — Scale section.
  inspectorNotCalibrated,
  inspectorCalibrateScale,
  inspectorReCalibrate,
  inspectorMapsToFloor,
  inspectorScaleConfirmed, // J1 — clears the "plan replaced" stale flag

  // Inspector — HVAC section.
  inspectorRound,
  inspectorRectangular,
  inspectorVelocity,
  inspectorEqualFriction,
  inspectorDuctNote,

  // Inspector — node role labels.
  inspectorRoleJunction,
  inspectorRoleFixture,
  inspectorRoleSource,

  // Inspector — Document control section (D3 issuable-sheet identity).
  inspectorDocNumber,
  inspectorRevisionTag,
  inspectorClient,
  inspectorPreparedBy,
  inspectorCheckedBy,
  inspectorApprovedBy,
  inspectorRevisionHistory,
  inspectorAddRevision,
  inspectorRevisionDateHint,
  inspectorRevisionDescHint,

  // Inspector — Equipment schedule model/spec editor (N23).
  inspectorEquipmentSchedule,
  inspectorEquipmentScheduleHint,
  inspectorModelSpecHint,

  // Export — OS save-dialog titles.
  exportTitleCalcReport,
  exportTitleMepReport,
  exportTitleEquipmentSchedule,
  exportTitleCalcReportPdf,
  exportTitleMepReportPdf,
  exportTitleEquipmentSchedulePdf,
  exportTitleDrawingDxf,
  exportTitleDrawingPdf,
  exportTitleAnnotatedPlanPdf,
  exportTitleBom,
  exportTitleSldDxf,
  exportTitleSldPdf,
  exportTitleRiserSetPdf,
  exportTitleRiserSetDxf,
  exportTitlePanelSchedulesPdf,
  exportTitlePowerOneLineDxf,
  exportTitleElectricalPlanPdf,
  exportTitleElectricalPlanDxf,
  exportTitleElectricalReport,
  exportTitleElectricalBom,
  exportTitleElectricalProposal,

  // Electrical workspace — toolbar tabs + buttons (I6).
  electricalTabSingleLine,
  electricalTabPowerOneLine,
  electricalTabBuildingRiser,
  electricalToolbarIssues,
  electricalToolbarIssuesCount, // {n}
  electricalServiceEarthing,
  electricalAddPanel,
  electricalExport,
  electricalClose,

  // Electrical workspace — context-menu rows.
  electricalMenuEdit,
  electricalMenuDuplicate,
  electricalMenuDelete,
  electricalPanelProperties,
  electricalMenuOpenPanel,
  electricalMenuMarkEssential,
  electricalMenuUnmarkEssential,
  electricalMenuMarkCritical,
  electricalMenuUnmarkCritical,
  electricalMenuAddSubmeter,
  electricalMenuRemoveSubmeter,
  electricalMenuDisconnectFeeder,
  electricalMenuDeletePanel,
  electricalMenuDuplicatePanel,

  // Electrical workspace — circuit inspector.
  electricalCircuitEditTitle,
  electricalFieldProtection,
  electricalFieldName,
  electricalFieldLoadKind,
  electricalFieldMotorPower,
  electricalFieldLoadW,
  electricalFieldCosPhi,
  electricalFieldDemandFactor,
  electricalFieldRunLength,
  electricalFieldSupplyPhase,
  electricalPhaseAuto,
  electricalPhase1,
  electricalPhase3,
  electricalFieldCableType,
  electricalCablePanelDefault,
  electricalFieldStarter,
  electricalStarterNone,
  electricalToggleLighting,
  electricalToggleLifeSafety,

  // Electrical workspace — panel inspector.
  electricalFieldTag,
  electricalFieldDiversity,
  electricalFieldHeadroomSpare,
  electricalFieldSpareWays,
  electricalToggleEssential,
  electricalToggleCritical,
  electricalToggleSubmeter,

  // Electrical workspace — Service & Earthing field.
  electricalFieldEarthingSystem,

  // Electrical workspace — Loads palette group headers.
  electricalPaletteLoads,
  electricalPaletteMotorsPumps,
  electricalPaletteDistribution,
  electricalPaletteReadOnly,

  // Electrical workspace — Loads palette card labels.
  electricalLoadLighting,
  electricalLoadSockets,
  electricalLoadAircon1,
  electricalLoadAircon3,
  electricalLoadWaterHeater1,
  electricalLoadWaterHeater3,
  electricalLoadEv1,
  electricalLoadEv3,
  electricalLoadIndustrialSocket3,
  electricalLoadUpsIt,
  electricalLoadWelding3,
  electricalLoadCustom1,
  electricalLoadCustom3,
  electricalLoadMotorDol,
  electricalLoadMotorLarge,
  electricalLoadPump1,
  electricalLoadPump3,
  electricalLoadFirePump,
  electricalLoadSpareMcb,
  electricalLoadSubPanel,

  // Electrical workspace — empty state + gesture-guide items.
  electricalEmptyTitle,
  electricalEmptyBody,
  electricalGuide1,
  electricalGuide2,
  electricalGuide3,
  electricalGuide4,
  electricalGuide5,
  electricalGuide6,
  electricalGuide7,

  // Calibration overlay — next-step baton (A6).
  calibrationScaleSetNext, // {scale}

  // Apple design review Wave 2 — status + recovery copy. Defined here; wired by
  // other packages (autoSizedRuns by app_state.dart H4, recoveryTornUnreadable
  // by app_shell.dart H5).
  autoSizedRuns, // {count} — the sizing-success status toast
  recoveryTornUnreadable, // torn / unreadable crash-recovery banner

  // ── Apple design review Wave 5a (Themes H1 + H6) — the trust-surface
  //    localization. These keys are DEFINED here only; later Wire packages
  //    consume them (each owns its target file, NOT this one). EN values are
  //    byte-identical to today's literals so the EN-rendered goldens do not
  //    move. Parameterized templates carry identical {placeholders} in EN + ID
  //    (i18n_test pins this). Where a count needs an English plural, the value
  //    is split into a template that takes a pre-pluralized `{phrase}`
  //    placeholder plus a NOUN one/many pair the store feeds to
  //    `pluralCount(n, one, many)` / `plural(n, one, many)` — so today's EN is
  //    reproduced exactly while ID (no inflection) uses one word for both.

  // H1 — compliance roll-up categories (store/compliance_store.dart).
  complianceCategoryAirVelocity,
  complianceCategorySheetCalibration,
  complianceCategoryStandardsVerification,
  complianceCategoryElectricalSizing,

  // I4 — the acknowledgement-log row category (compliance_store.dart): one row
  // per accepted advisory, carrying its audit trail (author/date/note) in the
  // detail so the signed report records who accepted a value, when, and why.
  complianceAckEntry, // {label} = the acknowledged advisory's title

  // H1 — compliance roll-up detail phrases.
  complianceDetailAllWithinBand,
  complianceDetailOutOfBand, // {n}
  complianceDetailAllCalibrated,
  complianceDetailUncalibrated, // {n}
  complianceDetailAllVerified,
  complianceDetailAckNoneOpen, // {n}
  complianceDetailRequireVerification, // {values} = pluralCount(n,'value','values')
  complianceDetailOpenAck, // {open} {ack}
  complianceDetailNoSizingErrors,
  complianceDetailWarningsNoErrors, // {warnings} = pluralCount(n,'warning','warnings')
  complianceDetailErrorsWarnings, // {errors} {warnings}

  // H1 — compliance pluralized nouns (fed to pluralCount(one, many)). The
  // 'finding'/'advisory note' details ARE the bare pluralCount phrase (no
  // surrounding template); 'value'/'warning'/'error' fill the templates above.
  complianceNounValueOne,
  complianceNounValueMany,
  complianceNounWarningOne,
  complianceNounWarningMany,
  complianceNounErrorOne,
  complianceNounErrorMany,
  complianceNounFindingOne,
  complianceNounFindingMany,
  complianceNounAdvisoryNoteOne,
  complianceNounAdvisoryNoteMany,

  // H1 — Review hub chrome (ui/review/review_hub.dart). The six deliverable
  // buttons ('Export calc report (MD)' …) reuse the existing inspectorExport*
  // keys (identical EN), so they are NOT re-declared here.
  reviewHubTitle,
  reviewHubLead,
  reviewStatPanelsSized,
  reviewStatBomLineItems,
  reviewStatStockPipes,
  reviewStatPipeRequired,
  reviewStatOffcutWaste,
  reviewStockNote,
  reviewExportDeliverables,
  reviewIssueReady,
  reviewIssueReviewRequired,
  reviewExportSubmittalPackage,
  reviewSubmittalHint,
  reviewVerdictPass,
  reviewVerdictReviewRequired,
  reviewDesignSignoff,
  reviewItemPass,
  reviewItemReview,
  reviewPipeCutPlan,
  reviewConsumablesTitle,
  reviewConsumablePvcCement,
  reviewConsumableDuctSealant,
  reviewConsumableThreadTape,
  reviewConsumablesNote,

  // H1 — Design issues card chrome (ui/review/issues_card.dart). The
  // '$text  ($count)' group-label wrapper stays in the widget; only the label
  // text is keyed.
  issuesCardCleanTitle,
  issuesCardCleanBody,
  issuesCardTitle,
  issuesCardQuickFixes,
  issuesCardWarnings,
  issuesCardAdvisory,
  issuesCardAcknowledged,
  issuesCardAcknowledgeAll,
  issuesCardAcknowledge,
  issuesCardUndo,
  issuesCardLocate,

  // I4 — the inline acknowledgement form (issues_card.dart): the engineer
  // records their initials + an optional one-line reason before an advisory is
  // accepted, so the sign-off carries an accountable author + justification.
  issuesCardAckInitials, // hint for the initials field
  issuesCardAckReasonHint, // hint for the optional reason field
  issuesCardAckCancel, // dismiss the inline form

  // H1 — Design issue TITLES (store/design_issues_store.dart). The engine-
  // sourced messages (air-velocity check.message, drainage a.message, the
  // electrical w.message) are a SEPARATE register and are NOT keyed here.
  issueOrphanTitle,
  issueDuctVelocityTitle,
  issueTerminalVelocityTitle,
  issueAirDuctUnsizedTitle,
  issueAirTerminalUnsizedTitle,
  issueDuctOverCapacityTitle,
  issueDiffuserStrandedTitle,
  issueSheetNotCalibratedTitle,
  issueCalibrationStaleTitle, // J1 — plan replaced, old scale unverified
  issueMultiSheetFloorTitle,
  issueNetworkIslandTitle,
  issueNetworkNoSourceTitle,
  issueDrainageSlopeTitle,
  issueDrainageLengthTitle,
  issueDrainageCleanoutTitle,
  issueLegionellaTitle,
  issueElectricalTitle, // {code} = w.code.replaceAll('-', ' ')
  issueUnverifiedTitle, // {name} = the // VERIFY value's short label

  // Unconnected-element checks (loose run/duct ends, orphans, unfed panels).
  issueUnconnectedLooseEndTitle,
  issueUnconnectedLooseEndMessage,
  issueUnconnectedOrphanTitle,
  issueUnconnectedOrphanMessage,
  issueUnfedPanelTitle,
  issueUnfedPanelMessage, // {panel} = the unfed panel's name

  // I1 — downfeed pressure-zone over the SNI max fixture static pressure.
  issuePressureZoneTitle,
  issuePressureZoneMessage, // {bottom} {top} {kpa} {limit}

  // I6 — document-control revision inconsistency (revision history logged but
  // the title-block Revision left blank).
  issueRevisionTagMissingTitle,
  issueRevisionTagMissingMessage,

  // H1 — Design issue MESSAGES.
  issueOrphanFloorMessage, // {floor} = index+1, {floors} = pluralCount(n,'floor','floors')
  issueOrphanSheetMessage,
  issueAirDuctUnsizedMessage,
  issueAirTerminalUnsizedMessage,
  issueDuctOverCapacityMessage,
  issueDiffuserStrandedMessage,
  issueSheetNotCalibratedCriticalMessage, // {name}
  issueSheetNotCalibratedWarningMessage, // {name}
  issueCalibrationStaleMessage, // J1 — {name}
  issueMultiSheetFloorMessage, // {count} {floor} {names}
  issueNetworkIslandMessage, // {service} {nodes} = pluralCount(n,'node','nodes')
  issueNetworkNoSourceMessage, // {service} {nodes}
  issueDrainageCleanoutMessage,
  issueLegionellaMessage, // {temp}

  // H1 — Design issue pluralized nouns + batch-action labels
  // (issueBatchActionsProvider). Batch labels use plural(n, one, many) (bare
  // word) filled into {noun}; messages use pluralCount(n, one, many) ("N word").
  issueNounFloorOne,
  issueNounFloorMany,
  issueNounNodeOne,
  issueNounNodeMany,
  issueNounVelocityOne,
  issueNounVelocityMany,
  issueNounElementOne,
  issueNounElementMany,
  issueNounSheetOne,
  issueNounSheetMany,
  issueBatchSelectVelocity, // {c} {noun}
  issueBatchSelectUnsized, // {c} {noun}
  issueBatchCalibrateNoSource, // {n}
  issueBatchCalibrateCopy, // {n} {noun}

  // H6 — Copilot panel (ui/ai/copilot_panel.dart).
  copilotTitle,
  copilotClose,
  copilotDescription,
  copilotThinkingButton,
  copilotAsk,
  copilotHintEnabled,
  copilotHintDisabled,
  copilotPlanning,
  copilotApplied,
  copilotSkipped,
  copilotDone,
  copilotNoSuggestion,
  copilotProposedPlan, // {changes} = pluralCount(n,'change','changes')
  copilotApply,
  copilotDiscard,
  copilotChangeNounOne,
  copilotChangeNounMany,

  // H6 — half-localized odds & ends (electrical empty state; Projects screen +
  // templates dialog title/barrierLabel).
  electricalLoadSampleProject,
  projectApplyBuildingTemplate,

  // Workflow-goldens review (2026-07-06): A2 template-cancel confirmation, A3
  // stepper/orientation-card term convergence (one "Building" everywhere), D1
  // Power one-line empty-state copy correction.
  templateAppliedImportPrompt,
  workflowStageCalibrate,
  workflowStageBuilding,
  workflowStageDraw,
  workflowStageSize,
  workflowStageReport,
  firstRunStepCalibrateDesc,
  firstRunStepBuildingDesc,
  firstRunStepDrawDesc,
  firstRunStepSizeDesc,
  firstRunStepReportDesc,
  electricalPowerOneLineEmptyBody,

  // L5/M4 — the shared MechXTooltip hover-tooltip mechanism, applied to
  // icon-only chrome that previously had no visible on-hover caption (the
  // zoom cluster, the inspector collapse chevron; the theme toggle and the
  // sheet-rail calibration dot reuse existing StringKeys below).
  tooltipZoomIn,
  tooltipZoomOut,
  tooltipZoomFit,
  tooltipCollapseInspector,
  tooltipExpandInspector,

  // E5 — the on-canvas service-colour LEGEND chip (Layout canvas, bottom-left):
  // its title + the show/hide tooltips.
  canvasLegendTitle,
  tooltipHideLegend,
  tooltipShowLegend,

  // Workflow-goldens review Theme F (drafting velocity): the layer-switcher
  // reference-layer LOCK (F1), the per-service view filter (F4) and the
  // click-to-place-repeatedly armed hint pill (F5).
  tooltipLockLayer,
  tooltipUnlockLayer,
  tooltipFilterServices,
  placementArmedHint, // {item}

  // L4 (a11y) — screen-reader names for icon-only controls that carry no visible
  // caption: the layer-visibility eye, and the shared numeric stepper's −/+
  // glyph buttons (suffixed with the field name where the caller supplies one).
  a11yShowLayer,
  a11yHideLayer,
  a11yDecrease, // optional " {field}" suffix appended by the caller
  a11yIncrease, // optional " {field}" suffix appended by the caller

  // L4 (a11y) — the on-canvas minimap's screen-reader name (it is otherwise an
  // unlabelled tap/drag surface), plus the field-name labels the numeric
  // steppers pass to a11yDecrease/a11yIncrease so a screen reader can tell one
  // dense inspector row from the next ("Decrease Ceiling height").
  a11yMinimapHint,
  a11yFieldDepth,
  a11yFieldCeilingHeight,
  a11yFieldAirChangesPerHour,
  a11yFieldFloorToFloorHeight,
  a11yFieldNumberOfLevels,
  a11yFieldFloorHeight,

  // A1 — the Layout empty-state's 'Load sample project' action (mirrors the
  // electrical workspace's `electricalLoadSampleProject`, kept as its own key
  // since the two seed independent domains).
  layoutLoadSampleProject,

  // A5 — the Projects-hub export surface: a leading 'Export deliverables'
  // group (reuses `reviewExportDeliverables`'s header text) followed by
  // labelled Drawings / Reports / Data disclosures, with the two near-
  // identical plan-PDF rows given a clarifying one-line subtitle each.
  projectsExportGroupDrawings,
  projectsExportGroupReports,
  projectsExportGroupData,
  projectsExportDrawingPdfHint,
  projectsExportAnnotatedPlanPdfHint,
}

/// English — the source language. These MUST match the inline literals being
/// migrated character-for-character (see the per-key migration notes).
const Map<StringKey, String> _en = {
  StringKey.navGroupDesign: 'DESIGN',
  StringKey.navLayout: 'Layout',
  StringKey.navSchematic: 'Riser',
  StringKey.navElectrical: 'Electrical',
  StringKey.navBuilding: 'Building',
  StringKey.navReview: 'Review',
  StringKey.navCommercial: 'Commercial',
  StringKey.navProjects: 'Projects',
  StringKey.navPreferences: 'Preferences',
  StringKey.prefsTitle: 'Preferences',
  StringKey.prefsLead: 'App-wide settings. More design defaults will gather here.',
  StringKey.prefsAppearance: 'Appearance',
  StringKey.prefsDark: 'Dark',
  StringKey.prefsLight: 'Light',
  StringKey.prefsSwitchToLight: 'Switch to Light',
  StringKey.prefsSwitchToDark: 'Switch to Dark',
  StringKey.prefsLanguage: 'Language',

  // Commercial workspace — hub.
  StringKey.commercialHubTitle: 'Commercial',
  StringKey.commercialHubLead:
      'The electrical bill of materials, your pricelist and the '
          'priced proposal. Edit prices below and the quotation updates '
          'live.',
  StringKey.commercialExportBomCsv: 'Export BOM (CSV)',
  StringKey.commercialExportProposalMd: 'Export proposal (Markdown)',

  // Commercial workspace — electrical BOM.
  StringKey.commercialBomTitle: 'BOM',
  StringKey.commercialColQty: 'Qty',
  StringKey.commercialColPart: 'Part',
  StringKey.commercialColBrand: 'Brand',
  StringKey.commercialColSku: 'SKU',
  StringKey.commercialColMatch: 'Match',
  StringKey.commercialMatched: 'matched',
  StringKey.commercialUnmatched: 'unmatched',
  StringKey.commercialBomLead:
      '{lines} line(s) from the sized electrical model, matched '
          'to the parts catalogue. {unmatched} line(s) have no catalogue match.',

  // Commercial workspace — pricelist.
  StringKey.commercialPricelistTitle: 'Pricelist',
  StringKey.commercialColUnit: 'Unit',
  StringKey.commercialColUnitPrice: 'Unit price',
  StringKey.commercialPricelistLead:
      'Unit prices for the catalogue parts your design uses. Stored with the '
          'project, never in the catalogue. {priced} of {total} priced.',

  // Commercial workspace — quotation.
  StringKey.commercialQuotationTitle: 'Quotation',
  StringKey.commercialAllPriced: 'All catalogue-matched lines are priced.',
  StringKey.commercialUnpricedExcluded:
      '{n} line(s) are unpriced and excluded from the material subtotal.',
  StringKey.commercialLabourRate: 'Labour rate ({cur} / h)',
  StringKey.commercialColAmount: 'Amount ({cur})',
  StringKey.commercialLabourHours: 'Labour ({hours} h)',
  StringKey.commercialQuoteSettings: 'Quote settings',
  StringKey.commercialOverheadPct: 'Overhead (%)',
  StringKey.commercialContingencyPct: 'Contingency (%)',
  StringKey.commercialMarginPct: 'Margin (%)',
  StringKey.commercialColItem: 'Item',
  StringKey.commercialItemMaterial: 'Material',
  StringKey.commercialItemOverhead: 'Overhead',
  StringKey.commercialItemContingency: 'Contingency',
  StringKey.commercialItemMargin: 'Margin',
  StringKey.commercialItemGrandTotal: 'Grand total',

  // Commercial workspace — shared table.
  StringKey.commercialNoItems: 'No items.',

  // Electrical — Export menu.
  StringKey.electricalExportSld: 'Single-line drawing',
  StringKey.electricalExportSldDxf: 'DXF (CAD)',
  StringKey.electricalExportSldPdf: 'PDF (vector)',
  StringKey.electricalExportOverview: 'Building single-line (overview)',
  StringKey.electricalExportOverviewPdf: 'PDF (vector)',
  StringKey.electricalExportOverviewDxf: 'DXF (CAD)',
  StringKey.electricalExportRiser: 'Building riser',
  StringKey.electricalExportRiserPdf: 'PDF (vector)',
  StringKey.electricalExportRiserDxf: 'DXF (CAD)',
  StringKey.electricalExportReport: 'Calculation report',
  StringKey.electricalExportReportSub: 'Markdown',
  StringKey.electricalExportPowerOneLine: 'Power one-line',
  StringKey.electricalExportPowerOneLineSub: 'DXF (needs energy sources)',
  StringKey.electricalExportPlan: 'Layout plan (denah)',
  StringKey.electricalExportSchedules: 'Panel schedules',
  StringKey.electricalExportSchedulesPdf: 'PDF (one panel per sheet)',

  // Mechanical riser — Export menu (the B3 drawing set).
  StringKey.mechExportAllSystems: 'All systems (drawing set)',
  StringKey.mechExportAllSystemsPdf: 'PDF (multi-page)',
  StringKey.mechExportAllSystemsDxf: 'DXF (one file per system)',

  // Electrical — Service & Earthing (Fold-1 fields).
  StringKey.electricalOriginFaultLevel: 'Origin fault level (kA)',
  StringKey.electricalOriginFaultLevelNote:
      'Prospective 3-phase fault at the supply origin. Drives '
          'Fold-1 busbar short-circuit withstand sizing. Default '
          '16 kA. VERIFY against the PLN / upstream let-through.',
  StringKey.electricalBusbarClearingTime: 'Busbar clearing time (s)',
  StringKey.electricalBusbarClearingTimeNote:
      'Protective-device clearing time for the withstand '
          'thermal check (smaller = less oversize). Default 0.1 s.',

  // Electrical — Sources editor.
  StringKey.electricalSources: 'Sources',
  StringKey.electricalSourcesNote:
      'The genset, transformer and capacitor draw on the source spine '
          '(Overview / Riser / single-line head + exports). Drawing inputs '
          'only — all VERIFY.',
  StringKey.electricalGenset: 'Standby generator (genset)',
  StringKey.electricalGensetPresent: 'Genset present',
  StringKey.electricalGensetKva: 'Genset rating (kVA, 0 = auto)',
  StringKey.electricalGensetMode: 'Genset mode',
  StringKey.electricalGensetTransfer: 'Transfer',
  StringKey.electricalTransformerKva: 'Transformer (kVA, 0 = auto)',
  StringKey.electricalTransformerKvaNote:
      'Explicit MV/LV transformer rating. 0 derives it from the building '
          'demand. VERIFY against the transformer schedule.',
  StringKey.electricalCapacitorKvar: 'Capacitor bank (kvar, 0 = none)',
  StringKey.electricalCapacitorKvarNote:
      'Installed PF-correction bank. 0 shows the generic "PF correction" '
          'note. VERIFY against the PF target / step plan.',
  StringKey.electricalDualTransformer: 'Dual transformer (split bus)',
  StringKey.electricalGensetModeStandby: 'Standby',
  StringKey.electricalGensetModePrime: 'Prime',
  StringKey.electricalGensetTransferAts: 'ATS',
  StringKey.electricalGensetTransferManual: 'Manual',

  // App shell — top bar.
  StringKey.shellOpen: 'Open',
  StringKey.shellSave: 'Save',
  StringKey.shellImportPdf: 'Import plan',
  StringKey.shellDark: 'Dark',
  StringKey.shellLight: 'Light',
  StringKey.shellSwitchToDark: 'Switch to dark',
  StringKey.shellSwitchToLight: 'Switch to light',

  // App shell — status bar.
  StringKey.shellNoSheet: 'No sheet',
  StringKey.shellUncalibrated: 'Uncalibrated',
  StringKey.shellCalibrated: 'Calibrated',
  StringKey.shellCalibrationStale: 'Plan replaced — re-verify scale',
  StringKey.shellStandardsProvenance: 'SNI 8153:2015 (draft)',
  StringKey.shellViewportHints:
      'scroll zoom · Space/middle-drag pan · F fit · Ctrl+0 100%',

  // App shell — banners.
  StringKey.shellRecoverPrompt: 'Recover "{name}" — autosaved {when}?',
  StringKey.shellRecoverJustNow: 'just now',
  StringKey.shellRecoverMinutesAgo: '{n} min ago',
  StringKey.shellRecoverHoursAgo: '{n} h ago',
  StringKey.shellRecoverAtTime: 'at {time}',
  StringKey.shellRecoverEarlier: 'earlier',
  StringKey.shellRestore: 'Restore',
  StringKey.shellDismiss: 'Dismiss',
  StringKey.shellDiscardSnapshot: 'Discard snapshot',
  StringKey.shellDiscardConfirm: 'Tap again to discard',

  // App shell — busy pill.
  StringKey.busyImportingPlan: 'Importing plan...',
  StringKey.busyConvertingDwg: 'Converting DWG...',
  StringKey.busyOpeningProject: 'Opening project...',
  StringKey.busySaving: 'Saving...',
  StringKey.busyExportingSubmittal:
      'Exporting submittal package ({current}/{total})...',

  // Unsaved-changes guard dialog.
  StringKey.confirmDiscardTitle: 'Unsaved changes',
  StringKey.confirmDiscardBody:
      'This project has changes that are not saved. Save them before '
          'continuing?',
  StringKey.confirmDiscardSave: 'Save',
  StringKey.confirmDiscardDiscard: 'Discard',
  StringKey.confirmDiscardCancel: 'Cancel',

  // App shell — Layout electrical inspector.
  StringKey.shellElectricalLayer: 'Electrical layer',
  StringKey.shellElectricalLayerHelp:
      'Drag a load onto a panel to add a way, or onto the sheet to '
          'place it. Double-click to edit; right-click for the menu.',

  // Schematic / elevation — toolbar + palette.
  StringKey.schematicAuto: 'Auto',
  StringKey.schematicEdit: 'Edit',
  StringKey.schematicRiserService: 'Riser service',
  StringKey.schematicSystemAll: 'All',
  StringKey.schematicInferRisers: 'Infer risers',
  StringKey.schematicLegend: 'Legend',
  StringKey.schematicTitleBlock: 'Title block',
  StringKey.schematicDetails: 'Details',
  StringKey.schematicNotes: 'Notes',
  StringKey.schematicTitleSheet: 'SHEET',
  StringKey.schematicTitleSingleLine: 'SINGLE-LINE DIAGRAM',
  StringKey.schematicTitleCleanWaterRiser: 'CLEAN WATER RISER',
  StringKey.schematicTitleHotWaterRiser: 'HOT WATER RISER',
  StringKey.schematicTitleDrainageRiser: 'DRAINAGE RISER',
  StringKey.schematicTitleVentRiser: 'VENT RISER',
  StringKey.schematicTitleStormRiser: 'STORM WATER RISER',
  StringKey.schematicTitleAirRiser: 'AIR DUCT RISER',
  StringKey.schematicTitleFireRiser: 'FIRE RISER',
  StringKey.schematicNoNetwork: 'No network drawn',
  StringKey.schematicPalette: 'Palette',
  StringKey.schematicPaletteHelp:
      'Drag onto a floor to drop a riser to the floor above. Its length is '
          'the elevation delta. Drag a riser sideways to move it; right-click '
          'to set its size.',
  StringKey.schematicRiser: 'Riser',
  StringKey.schematicAddFloorBanner:
      'Add a second floor (Project panel) to place risers — '
          'a riser spans a floor-to-floor elevation delta.',

  // Schematic / elevation — help popover.
  StringKey.schematicElevationGuide: 'Elevation guide',
  StringKey.schematicClose: 'Close',
  StringKey.canvasGuideTitle: 'Canvas guide',
  StringKey.schematicHelp1:
      'Drag the Riser card onto a floor to place a riser to the floor above',
  StringKey.schematicHelp2:
      'A riser length is the floor-to-floor elevation delta, never a PDF distance',
  StringKey.schematicHelp3:
      'Drag a riser sideways to reposition it; its length does not change',
  StringKey.schematicHelp4:
      'Right-click a riser to set its nominal size in inches or pick a material',
  StringKey.schematicHelpModes:
      'Auto shows the read-only generated riser; switch to Edit to place and '
          'size risers by hand',
  StringKey.schematicHelp5: 'Select a riser and press Delete to remove it',
  StringKey.schematicHelp6:
      'Middle-drag or scroll to pan; Ctrl+scroll or pinch to zoom',

  // Inspector — section labels.
  StringKey.inspectorProject: 'Project',
  StringKey.inspectorBuilding: 'Building',
  StringKey.inspectorDraw: 'Draw',
  StringKey.inspectorSizing: 'Sizing',
  StringKey.inspectorNetwork: 'Network',
  StringKey.inspectorFire: 'Fire',
  StringKey.inspectorHvacDucting: 'HVAC · ducting',
  StringKey.inspectorSheet: 'Sheet',
  StringKey.inspectorScale: 'Scale',
  StringKey.inspectorSelection: 'Selection',

  // Inspector — Project section.
  StringKey.inspectorExportCalcReportMd: 'Export calc report (MD)',
  StringKey.inspectorExportCalcReportPdfBtn: 'Export calc report (PDF)',
  StringKey.inspectorExportMepReportMd: 'Export unified MEP report (MD)',
  StringKey.inspectorExportMepReportPdfBtn: 'Export unified MEP report (PDF)',
  StringKey.inspectorExportEquipmentScheduleMd:
      'Export equipment schedule (MD + CSV)',
  StringKey.inspectorExportEquipmentSchedulePdfBtn: 'Export equipment schedule (PDF)',
  StringKey.inspectorExportDrawingDxf: 'Export drawing (DXF)',
  StringKey.inspectorExportDrawingPdf: 'Export drawing (PDF)',
  StringKey.inspectorExportAnnotatedPlanPdf: 'Export annotated plan (PDF)',

  // Inspector — Building section.
  StringKey.inspectorAddLevel: '+  Add level',

  // Inspector — Draw section.
  StringKey.inspectorSelect: 'Select',
  StringKey.inspectorRun: 'Run',
  StringKey.inspectorRiser: 'Riser',
  StringKey.inspectorUndo: 'Undo',
  StringKey.inspectorRedo: 'Redo',
  StringKey.inspectorClear: 'Clear',
  StringKey.inspectorOrtho: 'Ortho',
  StringKey.inspectorSnapToPlan: 'Snap to plan',
  StringKey.inspectorRefLine: 'Ref line',
  StringKey.inspectorDuplicateFloorUp: 'Duplicate floor up',

  // Inspector — Sizing section.
  StringKey.inspectorHideSizes: 'Hide sizes',
  StringKey.inspectorShowSizes: 'Show sizes',
  StringKey.inspectorSizingNote:
      'Auto-sized to SNI velocity limits. Water supply uses accumulated '
          'fixture units via the Hunter demand curve; assign fixture types per '
          'node.',
  StringKey.inspectorOccupancy: 'Occupancy',
  StringKey.inspectorRainfallStorm: 'Rainfall (storm)',

  // Inspector — occupancy labels.
  StringKey.inspectorOccupancyResidential: 'Residential',
  StringKey.inspectorOccupancyPublic: 'Office / public',
  StringKey.inspectorOccupancyAssembly: 'Assembly / mall',

  // Inspector — Network section.
  StringKey.inspectorUpfeedPump: 'Upfeed pump',
  StringKey.inspectorRoofTankDownfeed: 'Roof-tank downfeed',
  StringKey.inspectorHideHeatmap: 'Hide heatmap',
  StringKey.inspectorShowHeatmap: 'Show heatmap',
  StringKey.inspectorExportBomCsv: 'Export BOM (CSV)',

  // Inspector — Selection section.
  StringKey.inspectorDeleteNode: 'Delete node',
  StringKey.inspectorFixtureType: 'Fixture type',
  StringKey.inspectorAirTerminalAirflow: 'Air terminal (diffuser) airflow',
  StringKey.inspectorClearSizeOverride: 'Clear size override',
  StringKey.inspectorEdgeSizeHint:
      'Right-click the run to set its size and material.',

  // Inspector — Scale section.
  StringKey.inspectorNotCalibrated: 'Not calibrated — mark a known distance',
  StringKey.inspectorCalibrateScale: 'Calibrate scale',
  StringKey.inspectorReCalibrate: 'Re-calibrate',
  StringKey.inspectorMapsToFloor: 'Maps to floor',
  StringKey.inspectorScaleConfirmed: 'Scale confirmed',

  // Inspector — HVAC section.
  StringKey.inspectorRound: 'Round',
  StringKey.inspectorRectangular: 'Rectangular',
  StringKey.inspectorVelocity: 'Velocity',
  StringKey.inspectorEqualFriction: 'Equal friction',
  StringKey.inspectorDuctNote:
      'Draw a duct network and assign diffuser airflows.',

  // Inspector — node role labels.
  StringKey.inspectorRoleJunction: 'Junction',
  StringKey.inspectorRoleFixture: 'Fixture',
  StringKey.inspectorRoleSource: 'Source / tank',

  // Inspector — Document control section.
  StringKey.inspectorDocNumber: 'Document no.',
  StringKey.inspectorRevisionTag: 'Revision',
  StringKey.inspectorClient: 'Client',
  StringKey.inspectorPreparedBy: 'Prepared by',
  StringKey.inspectorCheckedBy: 'Checked by',
  StringKey.inspectorApprovedBy: 'Approved by',
  StringKey.inspectorRevisionHistory: 'Revision history',
  StringKey.inspectorAddRevision: 'Add revision',
  StringKey.inspectorRevisionDateHint: 'YYYY-MM-DD',
  StringKey.inspectorRevisionDescHint: 'Description',

  // Inspector — Equipment schedule model/spec editor (N23).
  StringKey.inspectorEquipmentSchedule: 'Equipment schedule',
  StringKey.inspectorEquipmentScheduleHint:
      'Model / spec for the issued equipment schedule. Blank prints as "—".',
  StringKey.inspectorModelSpecHint: 'Model / spec',

  // Export — OS save-dialog titles.
  StringKey.exportTitleCalcReport: 'Export calc report',
  StringKey.exportTitleMepReport: 'Export unified MEP report',
  StringKey.exportTitleEquipmentSchedule: 'Export equipment schedule',
  StringKey.exportTitleCalcReportPdf: 'Export calc report (PDF)',
  StringKey.exportTitleMepReportPdf: 'Export unified MEP report (PDF)',
  StringKey.exportTitleEquipmentSchedulePdf: 'Export equipment schedule (PDF)',
  StringKey.exportTitleDrawingDxf: 'Export drawing (DXF)',
  StringKey.exportTitleDrawingPdf: 'Export drawing (PDF)',
  StringKey.exportTitleAnnotatedPlanPdf: 'Export annotated plan (PDF)',
  StringKey.exportTitleBom: 'Export BOM',
  StringKey.exportTitleSldDxf: 'Export single-line (DXF)',
  StringKey.exportTitleSldPdf: 'Export single-line (PDF)',
  StringKey.exportTitleRiserSetPdf: 'Export riser drawing set (PDF)',
  StringKey.exportTitleRiserSetDxf:
      'Export riser drawing set (DXF, one file per system)',
  StringKey.exportTitlePanelSchedulesPdf: 'Export panel schedules (PDF)',
  StringKey.exportTitleElectricalPlanPdf: 'Export layout plan (PDF)',
  StringKey.exportTitleElectricalPlanDxf: 'Export layout plan (DXF)',
  StringKey.exportTitlePowerOneLineDxf: 'Export power one-line (DXF)',
  StringKey.exportTitleElectricalReport: 'Export electrical report',
  StringKey.exportTitleElectricalBom: 'Export electrical BOM',
  StringKey.exportTitleElectricalProposal: 'Export electrical proposal',

  // Electrical workspace — toolbar tabs + buttons.
  StringKey.electricalTabSingleLine: 'Single-line',
  StringKey.electricalTabPowerOneLine: 'Power one-line',
  StringKey.electricalTabBuildingRiser: 'Building riser',
  StringKey.electricalToolbarIssues: 'Electrical issues',
  StringKey.electricalToolbarIssuesCount: 'Electrical issues ({n})',
  StringKey.electricalServiceEarthing: 'Service & Earthing',
  StringKey.electricalAddPanel: '+ Panel',
  StringKey.electricalExport: 'Export',
  StringKey.electricalClose: 'Close',

  // Electrical workspace — context-menu rows.
  StringKey.electricalMenuEdit: 'Edit',
  StringKey.electricalMenuDuplicate: 'Duplicate',
  StringKey.electricalMenuDelete: 'Delete',
  StringKey.electricalPanelProperties: 'Panel properties',
  StringKey.electricalMenuOpenPanel: 'Open panel',
  StringKey.electricalMenuMarkEssential: 'Mark essential',
  StringKey.electricalMenuUnmarkEssential: 'Unmark essential',
  StringKey.electricalMenuMarkCritical: 'Mark critical (UPS)',
  StringKey.electricalMenuUnmarkCritical: 'Unmark critical (UPS)',
  StringKey.electricalMenuAddSubmeter: 'Add submeter',
  StringKey.electricalMenuRemoveSubmeter: 'Remove submeter',
  StringKey.electricalMenuDisconnectFeeder: 'Disconnect feeder',
  StringKey.electricalMenuDeletePanel: 'Delete panel',
  StringKey.electricalMenuDuplicatePanel: 'Duplicate panel',

  // Electrical workspace — circuit inspector.
  StringKey.electricalCircuitEditTitle: 'Edit circuit',
  StringKey.electricalFieldProtection: 'Protection',
  StringKey.electricalFieldName: 'Name',
  StringKey.electricalFieldLoadKind: 'Load kind',
  StringKey.electricalFieldMotorPower: 'Motor power (kW)',
  StringKey.electricalFieldLoadW: 'Load (W)',
  StringKey.electricalFieldCosPhi: 'cos phi (0-1)',
  StringKey.electricalFieldDemandFactor: 'Demand factor (0-1)',
  StringKey.electricalFieldRunLength: 'Run length (m)',
  StringKey.electricalFieldSupplyPhase: 'Supply phase',
  StringKey.electricalPhaseAuto: 'Auto',
  StringKey.electricalPhase1: '1-phase',
  StringKey.electricalPhase3: '3-phase',
  StringKey.electricalFieldCableType: 'Cable type',
  StringKey.electricalCablePanelDefault: 'Panel default',
  StringKey.electricalFieldStarter: 'Starter / control',
  StringKey.electricalStarterNone: 'None',
  StringKey.electricalToggleLighting: 'Lighting circuit (3% Vd limit)',
  StringKey.electricalToggleLifeSafety: 'Life-safety (no RCD)',

  // Electrical workspace — panel inspector.
  StringKey.electricalFieldTag: 'Tag (e.g. LP-1)',
  StringKey.electricalFieldDiversity: 'Diversity factor (0-1)',
  StringKey.electricalFieldHeadroomSpare: 'Headroom — spare demand (%)',
  StringKey.electricalFieldSpareWays: 'Spare ways (CADANGAN)',
  StringKey.electricalToggleEssential: 'Essential (genset-backed)',
  StringKey.electricalToggleCritical: 'Critical (UPS-backed)',
  StringKey.electricalToggleSubmeter: 'Tenant submeter',

  // Electrical workspace — Service & Earthing field.
  StringKey.electricalFieldEarthingSystem: 'Earthing system',

  // Electrical workspace — Loads palette group headers.
  StringKey.electricalPaletteLoads: 'Loads',
  StringKey.electricalPaletteMotorsPumps: 'Motors & pumps',
  StringKey.electricalPaletteDistribution: 'Distribution',
  StringKey.electricalPaletteReadOnly:
      'Read-only view — switch to Single-line to edit',

  // Electrical workspace — Loads palette card labels.
  StringKey.electricalLoadLighting: 'Lighting',
  StringKey.electricalLoadSockets: 'Sockets',
  StringKey.electricalLoadAircon1: 'Air-con (1φ)',
  StringKey.electricalLoadAircon3: 'Air-con (3φ)',
  StringKey.electricalLoadWaterHeater1: 'Water heater (1φ)',
  StringKey.electricalLoadWaterHeater3: 'Water heater (3φ)',
  StringKey.electricalLoadEv1: 'EV charger (1φ)',
  StringKey.electricalLoadEv3: 'EV charger (3φ)',
  StringKey.electricalLoadIndustrialSocket3: 'Industrial socket (3φ)',
  StringKey.electricalLoadUpsIt: 'UPS / IT load',
  StringKey.electricalLoadWelding3: 'Welding set (3φ)',
  StringKey.electricalLoadCustom1: 'Custom load (1φ)',
  StringKey.electricalLoadCustom3: 'Custom load (3φ)',
  StringKey.electricalLoadMotorDol: 'Motor (DOL)',
  StringKey.electricalLoadMotorLarge: 'Motor (large)',
  StringKey.electricalLoadPump1: 'Pump (1φ)',
  StringKey.electricalLoadPump3: 'Pump (3φ)',
  StringKey.electricalLoadFirePump: 'Fire pump',
  StringKey.electricalLoadSpareMcb: 'Spare MCB way',
  StringKey.electricalLoadSubPanel: 'Sub-panel',

  // Electrical workspace — empty state + gesture-guide items.
  StringKey.electricalEmptyTitle: 'Set up your service',
  StringKey.electricalEmptyBody:
      'Add a distribution panel, then drag loads from the palette '
          'onto it. Set the supply phase and earthing from Service & '
          'Earthing.',
  StringKey.electricalGuide1:
      'Double-click a component to edit its size, type or label',
  StringKey.electricalGuide2:
      'Right-click a component for compatible replacement parts',
  StringKey.electricalGuide3:
      'Drag a card from the palette onto a panel to add a way',
  StringKey.electricalGuide4:
      "Drag a panel's round outlet onto another panel to feed it",
  StringKey.electricalGuide5:
      'Drag a load onto a panel to wire it (creates the MCB)',
  StringKey.electricalGuide6:
      'Select a panel or floating load and press Delete; right-click a way to delete it',
  StringKey.electricalGuide7:
      'Drag the empty canvas to pan; scroll to zoom; panels reveal their internals up close',

  // Calibration overlay — next-step baton (A6). Points at the "Building" screen
  // (floors + heights), matching the nav-rail label — the baton-pass and its
  // destination now share ONE name.
  StringKey.calibrationScaleSetNext:
      'Scale set: {scale} - next: set floor heights (Building)',

  // Apple design review Wave 2 — status + recovery copy.
  StringKey.autoSizedRuns: 'Auto-sized {count} runs · sizes shown on the plan',
  StringKey.recoveryTornUnreadable:
      'The recovery file could not be read. Start a new project or open a '
          'saved copy.',

  // ── Apple design review Wave 5a (H1 + H6) — trust-surface localization. EN
  //    values are BYTE-IDENTICAL to the literals they replace.

  // H1 — compliance roll-up categories.
  StringKey.complianceCategoryAirVelocity: 'Air velocity',
  StringKey.complianceCategorySheetCalibration: 'Sheet calibration',
  StringKey.complianceCategoryStandardsVerification: 'Standards verification',
  StringKey.complianceCategoryElectricalSizing: 'Electrical circuit sizing',
  StringKey.complianceAckEntry: 'Acknowledged: {label}',

  // H1 — compliance roll-up detail phrases.
  StringKey.complianceDetailAllWithinBand: 'all within band',
  StringKey.complianceDetailOutOfBand: '{n} out of band',
  StringKey.complianceDetailAllCalibrated: 'all sheets calibrated',
  StringKey.complianceDetailUncalibrated: '{n} uncalibrated',
  StringKey.complianceDetailAllVerified: 'all values verified',
  StringKey.complianceDetailAckNoneOpen: '{n} acknowledged, none open',
  StringKey.complianceDetailRequireVerification:
      '{values} to verify or acknowledge',
  StringKey.complianceDetailOpenAck: '{open} open, {ack} acknowledged',
  StringKey.complianceDetailNoSizingErrors: 'no sizing errors',
  StringKey.complianceDetailWarningsNoErrors: '{warnings}, no errors',
  StringKey.complianceDetailErrorsWarnings: '{errors}, {warnings}',

  // H1 — compliance pluralized nouns (pluralCount(one, many)).
  StringKey.complianceNounValueOne: 'value',
  StringKey.complianceNounValueMany: 'values',
  StringKey.complianceNounWarningOne: 'warning',
  StringKey.complianceNounWarningMany: 'warnings',
  StringKey.complianceNounErrorOne: 'error',
  StringKey.complianceNounErrorMany: 'errors',
  StringKey.complianceNounFindingOne: 'finding',
  StringKey.complianceNounFindingMany: 'findings',
  StringKey.complianceNounAdvisoryNoteOne: 'advisory note',
  StringKey.complianceNounAdvisoryNoteMany: 'advisory notes',

  // H1 — Review hub chrome.
  StringKey.reviewHubTitle: 'Review',
  StringKey.reviewHubLead: 'Check the design before you issue it.',
  StringKey.reviewStatPanelsSized: 'Panels sized',
  StringKey.reviewStatBomLineItems: 'BOM line items',
  StringKey.reviewStatStockPipes: 'Stock pipes',
  StringKey.reviewStatPipeRequired: 'Pipe required',
  StringKey.reviewStatOffcutWaste: 'Offcut waste',
  StringKey.reviewStockNote:
      'Stock lengths: 4 m PVC/PPR, 6 m steel (sprinkler/hydrant), and duct '
          'sections 1.2 m BJLS / 4 m PU. The cut plan reuses offcuts to minimise '
          'waste; couplings and duct flanges on the canvas fall at these '
          'boundaries. The calc report (PDF or MD, below) carries the full '
          'breakdown.',
  StringKey.reviewExportDeliverables: 'Export deliverables',
  StringKey.reviewIssueReady: 'PASS — ready to issue',
  StringKey.reviewIssueReviewRequired:
      'REVIEW REQUIRED — you decide whether to issue',
  StringKey.reviewExportSubmittalPackage: 'Export submittal package...',
  StringKey.reviewSubmittalHint:
      'The submittal package above bundles the drawings too (the current '
          "sheet's annotated plan, the mechanical riser, and the electrical "
          'single-line). For a single per-sheet drawing, use the Export '
          'buttons on the Projects screen or the Riser view.',
  StringKey.reviewVerdictPass: 'PASS',
  StringKey.reviewVerdictReviewRequired: 'REVIEW REQUIRED',
  StringKey.reviewDesignSignoff: 'design sign-off',
  StringKey.reviewItemPass: 'PASS',
  StringKey.reviewItemReview: 'REVIEW',
  StringKey.reviewPipeCutPlan: 'Pipe cut plan',
  StringKey.reviewConsumablesTitle: 'Consumables (estimate)',
  StringKey.reviewConsumablePvcCement: 'PVC solvent cement',
  StringKey.reviewConsumableDuctSealant: 'Duct joint sealant',
  StringKey.reviewConsumableThreadTape: 'Thread-seal tape',
  StringKey.reviewConsumablesNote:
      'Estimate — coverage assumes ~1 L cement tins, 300 ml sealant '
          'cartridges, 30 joints/tape roll (verify per datasheet). PPR water '
          'pipe is heat-fused (no cement).',

  // H1 — Design issues card chrome.
  StringKey.issuesCardCleanTitle: 'No design issues found',
  StringKey.issuesCardCleanBody:
      'Air velocities are in band, sheets are calibrated, and '
          'every standards value is accounted for.',
  StringKey.issuesCardTitle: 'Design issues',
  StringKey.issuesCardQuickFixes: 'Quick fixes',
  StringKey.issuesCardWarnings: 'Warnings',
  StringKey.issuesCardAdvisory: 'Advisory',
  StringKey.issuesCardAcknowledged: 'Acknowledged',
  StringKey.issuesCardAcknowledgeAll: 'Acknowledge all',
  StringKey.issuesCardAcknowledge: 'Acknowledge',
  StringKey.issuesCardUndo: 'Undo',
  StringKey.issuesCardLocate: 'Locate',
  StringKey.issuesCardAckInitials: 'Initials',
  StringKey.issuesCardAckReasonHint: 'Reason (optional)',
  StringKey.issuesCardAckCancel: 'Cancel',

  // H1 — Design issue titles.
  StringKey.issueOrphanTitle: 'Element references a missing floor or sheet',
  StringKey.issueDuctVelocityTitle: 'Duct velocity out of band',
  StringKey.issueTerminalVelocityTitle: 'Terminal face velocity out of band',
  StringKey.issueAirDuctUnsizedTitle: 'Air duct not manually sized',
  StringKey.issueAirTerminalUnsizedTitle: 'Air terminal not manually sized',
  StringKey.issueDuctOverCapacityTitle: 'Duct over capacity',
  StringKey.issueDiffuserStrandedTitle: 'Diffuser not connected to any duct',
  StringKey.issueSheetNotCalibratedTitle: 'Sheet not calibrated',
  StringKey.issueCalibrationStaleTitle: 'Plan replaced — re-verify scale',
  StringKey.issueMultiSheetFloorTitle: 'Multiple sheets mapped to one floor',
  StringKey.issueNetworkIslandTitle: 'Network branch not connected',
  StringKey.issueNetworkNoSourceTitle: 'Network has no source',
  StringKey.issueDrainageSlopeTitle: 'Drainage slope below self-cleansing',
  StringKey.issueDrainageLengthTitle: 'Drainage branch too long',
  StringKey.issueDrainageCleanoutTitle: 'Drainage stack cleanout',
  StringKey.issueLegionellaTitle: 'Hot-water return temperature low',
  StringKey.issueElectricalTitle: 'Electrical: {code}',
  StringKey.issueUnverifiedTitle: 'Unverified: {name}',
  StringKey.issueUnconnectedLooseEndTitle: 'Unconnected run end',
  StringKey.issueUnconnectedLooseEndMessage:
      'This run ends at a bare junction — it is not joined to a fixture, '
      'terminal, plant, or another run. Connect the loose end or remove it.',
  StringKey.issueUnconnectedOrphanTitle: 'Unconnected element',
  StringKey.issueUnconnectedOrphanMessage:
      'This element is placed but not connected to anything. Connect it into '
      'the network, or remove it.',
  StringKey.issueUnfedPanelTitle: 'Panel not connected to a supply',
  StringKey.issueUnfedPanelMessage:
      '"{panel}" is neither the origin board nor fed by a feeder — it is wired '
      'to nothing. Feed it from an upstream panel.',
  StringKey.issuePressureZoneTitle: 'Pressure zone over the fixture limit',
  StringKey.issuePressureZoneMessage:
      'The pressure zone from "{bottom}" to "{top}" reaches {kpa} kPa static at '
      'its lowest fixture, above the SNI max fixture static of {limit} kPa. Add '
      'a PRV / break-tank to split the zone.',
  StringKey.issueRevisionTagMissingTitle: 'Revision not set for logged history',
  StringKey.issueRevisionTagMissingMessage:
      'The revision history has entries but the title-block Revision is blank, '
      'so every issued sheet and report stamps no revision. Set the current '
      'Revision under Document control.',

  // H1 — Design issue messages.
  StringKey.issueOrphanFloorMessage:
      'A drawn element sits on floor {floor}, which no longer '
          'exists (the building has {floors}) — it is being '
          'sized at a clamped elevation. Delete it or move it onto a real '
          'floor.',
  StringKey.issueOrphanSheetMessage:
      'A drawn element belongs to a sheet that is no longer loaded — '
          're-import that sheet or delete the orphaned element.',
  StringKey.issueAirDuctUnsizedMessage:
      'This duct carries air but has no chosen size — still '
          'relying on auto-sizing.',
  StringKey.issueAirTerminalUnsizedMessage:
      'This terminal carries air but has no chosen face size.',
  StringKey.issueDuctOverCapacityMessage:
      'This duct carries more air than the largest standard duct can '
          'handle within the velocity / friction limit — it was clamped to the '
          'largest standard size. Split the run or add a parallel duct.',
  StringKey.issueDiffuserStrandedMessage:
      'This air terminal carries a design airflow but has no duct '
          'connected — its demand is invisible to duct sizing and the BOM. '
          'Route a duct to it (or wire the supply trunk after auto-placing '
          'diffusers).',
  StringKey.issueSheetNotCalibratedCriticalMessage:
      '"{name}" carries drawn runs but has no scale set — they '
          'are sizing to ZERO length. Calibrate the sheet before sizing or '
          'export, or the BOM and pressures will be wrong.',
  StringKey.issueSheetNotCalibratedWarningMessage:
      '"{name}" has no scale set — its run/riser lengths cannot '
          'be measured. Calibrate the sheet to size it.',
  StringKey.issueCalibrationStaleMessage:
      '"{name}"\'s plan was replaced but kept its OLD scale — a revised '
          'drawing (different DPI, plot scale, or title block) can silently '
          'carry the wrong calibration. Re-check the scale, or confirm it '
          'still holds.',
  StringKey.issueMultiSheetFloorMessage:
      '{count} sheets map to floor "{floor}" '
          '({names}) — only one plan per floor feeds sizing at that elevation, '
          'so the extras are stacked there (often an import that ran past the '
          'floor count). Re-map the extra sheets or add floors.',
  StringKey.issueNetworkIslandMessage:
      'A {service} branch with {nodes} is disconnected from its fed '
          'network — it is rooted heuristically and sized as if supplied. '
          'Connect it to the source, or add a plant.',
  StringKey.issueNetworkNoSourceMessage:
      'A {service} component with {nodes} has no plant/source — it is '
          'being rooted heuristically and sized as if supplied. Add a pump / '
          'tank / AHU source.',
  StringKey.issueDrainageCleanoutMessage:
      'A drainage stack reaches its lowest drawn point here with no '
          'cleanout component at or beside the base — rodding access is '
          'conventional at every stack base. Place a cleanout, or confirm '
          'access exists elsewhere.',
  StringKey.issueLegionellaMessage:
      'Modelled recirculation return temperature '
          '{temp} °C is below the '
          'anti-Legionella floor (~55 °C). Reduce the loop temperature drop or '
          'add trace heating. (// VERIFY vs SNI / WHO guidance.)',

  // H1 — Design issue pluralized nouns + batch labels.
  StringKey.issueNounFloorOne: 'floor',
  StringKey.issueNounFloorMany: 'floors',
  StringKey.issueNounNodeOne: 'node',
  StringKey.issueNounNodeMany: 'nodes',
  StringKey.issueNounVelocityOne: 'velocity',
  StringKey.issueNounVelocityMany: 'velocities',
  StringKey.issueNounElementOne: 'element',
  StringKey.issueNounElementMany: 'elements',
  StringKey.issueNounSheetOne: 'sheet',
  StringKey.issueNounSheetMany: 'sheets',
  StringKey.issueBatchSelectVelocity: 'Select {c} out-of-band {noun}',
  StringKey.issueBatchSelectUnsized: 'Select {c} unsized air {noun}',
  StringKey.issueBatchCalibrateNoSource:
      'Calibrate one sheet to copy scale to {n} more',
  StringKey.issueBatchCalibrateCopy: 'Copy scale to {n} uncalibrated {noun}',

  // H6 — Copilot panel.
  StringKey.copilotTitle: 'Ask Claude',
  StringKey.copilotClose: 'Close',
  StringKey.copilotDescription:
      'Select a room or element, then ask Claude to add equipment, runs or '
          "terminals — or to auto-place a room's air terminals. Claude adds and "
          'advises; it does not edit or delete existing elements. You review '
          'every step before it is applied.',
  StringKey.copilotThinkingButton: 'Thinking…',
  StringKey.copilotAsk: 'Ask',
  StringKey.copilotHintEnabled: 'e.g. design supply air for this room',
  StringKey.copilotHintDisabled: 'Add an API key in Preferences to enable',
  StringKey.copilotPlanning: 'Claude is planning…',
  StringKey.copilotApplied: 'Applied.',
  StringKey.copilotSkipped: 'Skipped',
  StringKey.copilotDone: 'Done',
  StringKey.copilotNoSuggestion: 'No suggestion.',
  StringKey.copilotProposedPlan: 'Proposed plan · {changes}',
  StringKey.copilotApply: 'Apply',
  StringKey.copilotDiscard: 'Discard',
  StringKey.copilotChangeNounOne: 'change',
  StringKey.copilotChangeNounMany: 'changes',

  // H6 — half-localized odds & ends.
  StringKey.electricalLoadSampleProject: 'Load sample project',
  StringKey.projectApplyBuildingTemplate: 'Apply a building template',

  // Workflow-goldens review (2026-07-06).
  StringKey.templateAppliedImportPrompt:
      'Template applied — import a plan when ready',
  StringKey.workflowStageCalibrate: 'Calibrate',
  StringKey.workflowStageBuilding: 'Building',
  StringKey.workflowStageDraw: 'Draw',
  StringKey.workflowStageSize: 'Size',
  StringKey.workflowStageReport: 'Report',
  StringKey.firstRunStepCalibrateDesc: 'set the drawing scale on your plan',
  StringKey.firstRunStepBuildingDesc: "set each level's height",
  StringKey.firstRunStepDrawDesc: 'lay out pipes, ducts and panels',
  StringKey.firstRunStepSizeDesc: 'auto-size everything to SNI / PUIL',
  StringKey.firstRunStepReportDesc: 'export the BOM and calc report',
  StringKey.electricalPowerOneLineEmptyBody:
      'Add a generator from the Sources button in the toolbar above to build '
          'a hybrid power one-line with source interlocks.',

  // L5/M4 — the shared MechXTooltip hover-tooltip mechanism.
  StringKey.tooltipZoomIn: 'Zoom in',
  StringKey.tooltipZoomOut: 'Zoom out',
  StringKey.tooltipZoomFit: 'Fit view',
  StringKey.tooltipCollapseInspector: 'Collapse inspector',
  StringKey.tooltipExpandInspector: 'Expand inspector',

  // E5 — the on-canvas service-colour legend chip.
  StringKey.canvasLegendTitle: 'Legend',
  StringKey.tooltipHideLegend: 'Hide legend',
  StringKey.tooltipShowLegend: 'Show legend',

  // Theme F — layer lock (F1) / per-service filter (F4) / armed placement (F5).
  StringKey.tooltipLockLayer: 'Lock layer',
  StringKey.tooltipUnlockLayer: 'Unlock layer',
  StringKey.tooltipFilterServices: 'Filter services',
  StringKey.placementArmedHint: 'Placing {item} · click to place · Esc to cancel',
  StringKey.a11yShowLayer: 'Show layer',
  StringKey.a11yHideLayer: 'Hide layer',
  StringKey.a11yDecrease: 'Decrease',
  StringKey.a11yIncrease: 'Increase',
  StringKey.a11yMinimapHint: 'Canvas minimap — tap or drag to jump the view',
  StringKey.a11yFieldDepth: 'Depth',
  StringKey.a11yFieldCeilingHeight: 'Ceiling height',
  StringKey.a11yFieldAirChangesPerHour: 'Air changes per hour',
  StringKey.a11yFieldFloorToFloorHeight: 'Floor-to-floor height',
  StringKey.a11yFieldNumberOfLevels: 'Number of levels',
  StringKey.a11yFieldFloorHeight: 'Floor height',

  // A1 — Layout empty-state 'Load sample project'.
  StringKey.layoutLoadSampleProject: 'Load sample project',

  // A5 — Projects-hub export grouping.
  StringKey.projectsExportGroupDrawings: 'Drawings',
  StringKey.projectsExportGroupReports: 'Reports',
  StringKey.projectsExportGroupData: 'Data',
  StringKey.projectsExportDrawingPdfHint:
      'Plain plan — no calibrated run/riser lengths on size labels.',
  StringKey.projectsExportAnnotatedPlanPdfHint:
      'Annotated plan — includes real run/riser lengths on every size label.',
};

/// Bahasa Indonesia. Any missing key falls back to [_en] at lookup time, so the
/// app never shows a blank even before a translation lands.
const Map<StringKey, String> _id = {
  StringKey.navGroupDesign: 'DESAIN',
  StringKey.navLayout: 'Tata Letak',
  StringKey.navSchematic: 'Riser',
  StringKey.navElectrical: 'Listrik',
  StringKey.navBuilding: 'Bangunan',
  StringKey.navReview: 'Tinjauan',
  StringKey.navCommercial: 'Komersial',
  StringKey.navProjects: 'Proyek',
  StringKey.navPreferences: 'Preferensi',
  StringKey.prefsTitle: 'Preferensi',
  StringKey.prefsLead:
      'Pengaturan seluruh aplikasi. Lebih banyak default desain akan terkumpul di sini.',
  StringKey.prefsAppearance: 'Tampilan',
  StringKey.prefsDark: 'Gelap',
  StringKey.prefsLight: 'Terang',
  StringKey.prefsSwitchToLight: 'Beralih ke Terang',
  StringKey.prefsSwitchToDark: 'Beralih ke Gelap',
  StringKey.prefsLanguage: 'Bahasa',

  // Commercial workspace — hub.
  StringKey.commercialHubTitle: 'Komersial',
  StringKey.commercialHubLead:
      'Daftar material kelistrikan, daftar harga Anda, dan proposal '
          'berbiaya. Ubah harga di bawah ini dan penawaran akan diperbarui '
          'secara langsung.',
  StringKey.commercialExportBomCsv: 'Ekspor BOM (CSV)',
  StringKey.commercialExportProposalMd: 'Ekspor proposal (Markdown)',

  // Commercial workspace — electrical BOM.
  StringKey.commercialBomTitle: 'BOM',
  StringKey.commercialColQty: 'Jml',
  StringKey.commercialColPart: 'Komponen',
  StringKey.commercialColBrand: 'Merek',
  StringKey.commercialColSku: 'SKU',
  StringKey.commercialColMatch: 'Kecocokan',
  StringKey.commercialMatched: 'cocok',
  StringKey.commercialUnmatched: 'tidak cocok',
  StringKey.commercialBomLead:
      '{lines} baris dari model kelistrikan terhitung, dicocokkan ke katalog '
          'komponen. {unmatched} baris tanpa kecocokan katalog.',

  // Commercial workspace — pricelist.
  StringKey.commercialPricelistTitle: 'Daftar Harga',
  StringKey.commercialColUnit: 'Satuan',
  StringKey.commercialColUnitPrice: 'Harga satuan',
  StringKey.commercialPricelistLead:
      'Harga satuan untuk komponen katalog yang dipakai desain Anda. Disimpan '
          'bersama proyek, bukan di katalog. {priced} dari {total} diberi harga.',

  // Commercial workspace — quotation.
  StringKey.commercialQuotationTitle: 'Penawaran',
  StringKey.commercialAllPriced: 'Semua baris yang cocok katalog telah diberi harga.',
  StringKey.commercialUnpricedExcluded:
      '{n} baris belum diberi harga dan dikecualikan dari subtotal material.',
  StringKey.commercialLabourRate: 'Tarif tenaga kerja ({cur} / jam)',
  StringKey.commercialColAmount: 'Jumlah ({cur})',
  StringKey.commercialLabourHours: 'Tenaga kerja ({hours} jam)',
  StringKey.commercialQuoteSettings: 'Pengaturan penawaran',
  StringKey.commercialOverheadPct: 'Overhead (%)',
  StringKey.commercialContingencyPct: 'Kontingensi (%)',
  StringKey.commercialMarginPct: 'Margin (%)',
  StringKey.commercialColItem: 'Item',
  StringKey.commercialItemMaterial: 'Material',
  StringKey.commercialItemOverhead: 'Overhead',
  StringKey.commercialItemContingency: 'Kontingensi',
  StringKey.commercialItemMargin: 'Margin',
  StringKey.commercialItemGrandTotal: 'Total keseluruhan',

  // Commercial workspace — shared table.
  StringKey.commercialNoItems: 'Tidak ada item.',

  // Electrical — Export menu.
  StringKey.electricalExportSld: 'Gambar satu-garis',
  StringKey.electricalExportSldDxf: 'DXF (CAD)',
  StringKey.electricalExportSldPdf: 'PDF (vektor)',
  StringKey.electricalExportOverview: 'Satu-garis gedung (ikhtisar)',
  StringKey.electricalExportOverviewPdf: 'PDF (vektor)',
  StringKey.electricalExportOverviewDxf: 'DXF (CAD)',
  StringKey.electricalExportRiser: 'Riser gedung',
  StringKey.electricalExportRiserPdf: 'PDF (vektor)',
  StringKey.electricalExportRiserDxf: 'DXF (CAD)',
  StringKey.electricalExportReport: 'Laporan perhitungan',
  StringKey.electricalExportReportSub: 'Markdown',
  StringKey.electricalExportPowerOneLine: 'Diagram daya satu-garis',
  StringKey.electricalExportPowerOneLineSub: 'DXF (perlu sumber energi)',
  StringKey.electricalExportPlan: 'Denah instalasi (denah)',
  StringKey.electricalExportSchedules: 'Diagram panel',
  StringKey.electricalExportSchedulesPdf: 'PDF (satu panel per lembar)',

  // Mechanical riser — Export menu (the B3 drawing set).
  StringKey.mechExportAllSystems: 'Semua sistem (set gambar)',
  StringKey.mechExportAllSystemsPdf: 'PDF (multi-halaman)',
  StringKey.mechExportAllSystemsDxf: 'DXF (satu berkas per sistem)',

  // Electrical — Service & Earthing (Fold-1 fields).
  StringKey.electricalOriginFaultLevel: 'Tingkat gangguan sumber (kA)',
  StringKey.electricalOriginFaultLevelNote:
      'Gangguan 3-fasa prospektif di titik asal suplai. Menjadi dasar '
          'pengukuran ketahanan hubung-singkat busbar Fold-1. Default '
          '16 kA. VERIFIKASI terhadap let-through PLN / hulu.',
  StringKey.electricalBusbarClearingTime: 'Waktu pemutusan busbar (s)',
  StringKey.electricalBusbarClearingTimeNote:
      'Waktu pemutusan perangkat proteksi untuk pemeriksaan ketahanan '
          'termal (lebih kecil = lebih sedikit pembesaran). Default 0,1 s.',

  // Electrical — Sources editor.
  StringKey.electricalSources: 'Sumber',
  StringKey.electricalSourcesNote:
      'Genset, trafo, dan kapasitor digambar pada tulang sumber '
          '(Ikhtisar / Riser / kepala satu-garis + ekspor). Hanya masukan '
          'gambar — semua VERIFIKASI.',
  StringKey.electricalGenset: 'Generator cadangan (genset)',
  StringKey.electricalGensetPresent: 'Genset tersedia',
  StringKey.electricalGensetKva: 'Daya genset (kVA, 0 = otomatis)',
  StringKey.electricalGensetMode: 'Mode genset',
  StringKey.electricalGensetTransfer: 'Transfer',
  StringKey.electricalTransformerKva: 'Trafo (kVA, 0 = otomatis)',
  StringKey.electricalTransformerKvaNote:
      'Daya trafo MV/LV eksplisit. 0 menurunkannya dari beban gedung. '
          'VERIFIKASI terhadap jadwal trafo.',
  StringKey.electricalCapacitorKvar: 'Bank kapasitor (kvar, 0 = tidak ada)',
  StringKey.electricalCapacitorKvarNote:
      'Bank koreksi PF terpasang. 0 menampilkan catatan "PF correction" '
          'umum. VERIFIKASI terhadap target / rencana langkah PF.',
  StringKey.electricalDualTransformer: 'Trafo ganda (bus terpisah)',
  StringKey.electricalGensetModeStandby: 'Cadangan',
  StringKey.electricalGensetModePrime: 'Utama',
  StringKey.electricalGensetTransferAts: 'ATS',
  StringKey.electricalGensetTransferManual: 'Manual',

  // App shell — top bar.
  StringKey.shellOpen: 'Buka',
  StringKey.shellSave: 'Simpan',
  StringKey.shellImportPdf: 'Impor denah',
  StringKey.shellDark: 'Gelap',
  StringKey.shellLight: 'Terang',
  StringKey.shellSwitchToDark: 'Ke mode gelap',
  StringKey.shellSwitchToLight: 'Ke mode terang',

  // App shell — status bar.
  StringKey.shellNoSheet: 'Tidak ada lembar',
  StringKey.shellUncalibrated: 'Belum dikalibrasi',
  StringKey.shellCalibrated: 'Terkalibrasi',
  StringKey.shellCalibrationStale: 'Denah diganti — verifikasi ulang skala',
  StringKey.shellStandardsProvenance: 'SNI 8153:2015 (draf)',
  StringKey.shellViewportHints:
      'gulir zoom · Spasi/seret-tengah geser · F pas · Ctrl+0 100%',

  // App shell — banners.
  StringKey.shellRecoverPrompt:
      'Pulihkan "{name}" — disimpan otomatis {when}?',
  StringKey.shellRecoverJustNow: 'baru saja',
  StringKey.shellRecoverMinutesAgo: '{n} menit lalu',
  StringKey.shellRecoverHoursAgo: '{n} jam lalu',
  StringKey.shellRecoverAtTime: 'pukul {time}',
  StringKey.shellRecoverEarlier: 'sebelumnya',
  StringKey.shellRestore: 'Pulihkan',
  StringKey.shellDismiss: 'Tutup',
  StringKey.shellDiscardSnapshot: 'Buang cadangan',
  StringKey.shellDiscardConfirm: 'Ketuk lagi untuk membuang',

  // App shell — busy pill.
  StringKey.busyImportingPlan: 'Mengimpor denah...',
  StringKey.busyConvertingDwg: 'Mengonversi DWG...',
  StringKey.busyOpeningProject: 'Membuka proyek...',
  StringKey.busySaving: 'Menyimpan...',
  StringKey.busyExportingSubmittal:
      'Mengekspor paket submittal ({current}/{total})...',

  // Unsaved-changes guard dialog.
  StringKey.confirmDiscardTitle: 'Perubahan belum disimpan',
  StringKey.confirmDiscardBody:
      'Proyek ini memiliki perubahan yang belum disimpan. Simpan sebelum '
          'melanjutkan?',
  StringKey.confirmDiscardSave: 'Simpan',
  StringKey.confirmDiscardDiscard: 'Buang',
  StringKey.confirmDiscardCancel: 'Batal',

  // App shell — Layout electrical inspector.
  StringKey.shellElectricalLayer: 'Lapisan listrik',
  StringKey.shellElectricalLayerHelp:
      'Seret beban ke panel untuk menambah jalur, atau ke lembar untuk '
          'menempatkannya. Klik-ganda untuk mengedit; klik-kanan untuk menu.',

  // Schematic / elevation — toolbar + palette.
  StringKey.schematicAuto: 'Otomatis',
  StringKey.schematicEdit: 'Edit',
  StringKey.schematicRiserService: 'Layanan riser',
  StringKey.schematicSystemAll: 'Semua',
  StringKey.schematicInferRisers: 'Perkirakan riser',
  StringKey.schematicLegend: 'Legenda',
  StringKey.schematicTitleBlock: 'Kop gambar',
  StringKey.schematicDetails: 'Detail',
  StringKey.schematicNotes: 'Catatan',
  StringKey.schematicTitleSheet: 'LEMBAR',
  StringKey.schematicTitleSingleLine: 'DIAGRAM SATU GARIS',
  StringKey.schematicTitleCleanWaterRiser: 'RISER AIR BERSIH',
  StringKey.schematicTitleHotWaterRiser: 'RISER AIR PANAS',
  StringKey.schematicTitleDrainageRiser: 'RISER AIR KOTOR',
  StringKey.schematicTitleVentRiser: 'RISER VENT',
  StringKey.schematicTitleStormRiser: 'RISER AIR HUJAN',
  StringKey.schematicTitleAirRiser: 'RISER DUCTING UDARA',
  StringKey.schematicTitleFireRiser: 'RISER PEMADAM',
  StringKey.schematicNoNetwork: 'Belum ada jaringan digambar',
  StringKey.schematicPalette: 'Palet',
  StringKey.schematicPaletteHelp:
      'Seret ke lantai untuk menjatuhkan riser ke lantai di atasnya. '
          'Panjangnya adalah selisih elevasi. Seret riser ke samping untuk '
          'memindahkannya; klik-kanan untuk mengatur ukurannya.',
  StringKey.schematicRiser: 'Riser',
  StringKey.schematicAddFloorBanner:
      'Tambahkan lantai kedua (panel Proyek) untuk menempatkan riser — '
          'sebuah riser membentang sepanjang selisih elevasi antar-lantai.',

  // Schematic / elevation — help popover.
  StringKey.schematicElevationGuide: 'Panduan elevasi',
  StringKey.schematicClose: 'Tutup',
  StringKey.canvasGuideTitle: 'Panduan kanvas',
  StringKey.schematicHelp1:
      'Seret kartu Riser ke lantai untuk menempatkan riser ke lantai di atasnya',
  StringKey.schematicHelp2:
      'Panjang riser adalah selisih elevasi antar-lantai, bukan jarak pada PDF',
  StringKey.schematicHelp3:
      'Seret riser ke samping untuk memindahkannya; panjangnya tidak berubah',
  StringKey.schematicHelp4:
      'Klik-kanan riser untuk mengatur ukuran nominalnya dalam inci atau memilih material',
  StringKey.schematicHelpModes:
      'Otomatis menampilkan riser yang dibuat otomatis (hanya-baca); beralih ke '
          'Edit untuk menempatkan dan mengukur riser secara manual',
  StringKey.schematicHelp5:
      'Pilih riser dan tekan Delete untuk menghapusnya',
  StringKey.schematicHelp6:
      'Seret-tengah atau gulir untuk menggeser; Ctrl+gulir atau cubit untuk zoom',

  // Inspector — section labels.
  StringKey.inspectorProject: 'Proyek',
  StringKey.inspectorBuilding: 'Bangunan',
  StringKey.inspectorDraw: 'Gambar',
  StringKey.inspectorSizing: 'Pengukuran',
  StringKey.inspectorNetwork: 'Jaringan',
  StringKey.inspectorFire: 'Kebakaran',
  StringKey.inspectorHvacDucting: 'HVAC · saluran',
  StringKey.inspectorSheet: 'Lembar',
  StringKey.inspectorScale: 'Skala',
  StringKey.inspectorSelection: 'Pilihan',

  // Inspector — Project section.
  StringKey.inspectorExportCalcReportMd: 'Ekspor laporan hitung (MD)',
  StringKey.inspectorExportCalcReportPdfBtn: 'Ekspor laporan hitung (PDF)',
  StringKey.inspectorExportMepReportMd: 'Ekspor laporan MEP terpadu (MD)',
  StringKey.inspectorExportMepReportPdfBtn: 'Ekspor laporan MEP terpadu (PDF)',
  StringKey.inspectorExportEquipmentScheduleMd:
      'Ekspor jadwal peralatan (MD + CSV)',
  StringKey.inspectorExportEquipmentSchedulePdfBtn: 'Ekspor jadwal peralatan (PDF)',
  StringKey.inspectorExportDrawingDxf: 'Ekspor gambar (DXF)',
  StringKey.inspectorExportDrawingPdf: 'Ekspor gambar (PDF)',
  StringKey.inspectorExportAnnotatedPlanPdf: 'Ekspor denah beranotasi (PDF)',

  // Inspector — Building section.
  StringKey.inspectorAddLevel: '+  Tambah lantai',

  // Inspector — Draw section.
  StringKey.inspectorSelect: 'Pilih',
  StringKey.inspectorRun: 'Saluran',
  StringKey.inspectorRiser: 'Riser',
  StringKey.inspectorUndo: 'Urungkan',
  StringKey.inspectorRedo: 'Ulangi',
  StringKey.inspectorClear: 'Bersihkan',
  StringKey.inspectorOrtho: 'Orto',
  StringKey.inspectorSnapToPlan: 'Kancing ke gambar',
  StringKey.inspectorRefLine: 'Garis acuan',
  StringKey.inspectorDuplicateFloorUp: 'Gandakan ke lantai atas',

  // Inspector — Sizing section.
  StringKey.inspectorHideSizes: 'Sembunyikan ukuran',
  StringKey.inspectorShowSizes: 'Tampilkan ukuran',
  StringKey.inspectorSizingNote:
      'Diukur otomatis sesuai batas kecepatan SNI. Pasokan air memakai akumulasi '
          'unit fikstur via kurva permintaan Hunter; tetapkan jenis fikstur per '
          'simpul.',
  StringKey.inspectorOccupancy: 'Hunian',
  StringKey.inspectorRainfallStorm: 'Curah hujan (badai)',

  // Inspector — occupancy labels.
  StringKey.inspectorOccupancyResidential: 'Hunian',
  StringKey.inspectorOccupancyPublic: 'Kantor / publik',
  StringKey.inspectorOccupancyAssembly: 'Pertemuan / mal',

  // Inspector — Network section.
  StringKey.inspectorUpfeedPump: 'Pompa naik',
  StringKey.inspectorRoofTankDownfeed: 'Tangki atap turun',
  StringKey.inspectorHideHeatmap: 'Sembunyikan peta panas',
  StringKey.inspectorShowHeatmap: 'Tampilkan peta panas',
  StringKey.inspectorExportBomCsv: 'Ekspor BOM (CSV)',

  // Inspector — Selection section.
  StringKey.inspectorDeleteNode: 'Hapus simpul',
  StringKey.inspectorFixtureType: 'Jenis fikstur',
  StringKey.inspectorAirTerminalAirflow: 'Aliran udara terminal (difuser)',
  StringKey.inspectorClearSizeOverride: 'Hapus penimpaan ukuran',
  StringKey.inspectorEdgeSizeHint:
      'Klik-kanan saluran untuk mengatur ukuran dan materialnya.',

  // Inspector — Scale section.
  StringKey.inspectorNotCalibrated:
      'Belum dikalibrasi — tandai jarak yang diketahui',
  StringKey.inspectorCalibrateScale: 'Kalibrasi skala',
  StringKey.inspectorReCalibrate: 'Kalibrasi ulang',
  StringKey.inspectorMapsToFloor: 'Memetakan ke lantai',
  StringKey.inspectorScaleConfirmed: 'Skala dikonfirmasi',

  // Inspector — HVAC section.
  StringKey.inspectorRound: 'Bulat',
  StringKey.inspectorRectangular: 'Persegi panjang',
  StringKey.inspectorVelocity: 'Kecepatan',
  StringKey.inspectorEqualFriction: 'Gesekan sama',
  StringKey.inspectorDuctNote:
      'Gambar jaringan saluran dan tetapkan aliran udara difuser.',

  // Inspector — node role labels.
  StringKey.inspectorRoleJunction: 'Persimpangan',
  StringKey.inspectorRoleFixture: 'Fikstur',
  StringKey.inspectorRoleSource: 'Sumber / tangki',

  // Inspector — Document control section.
  StringKey.inspectorDocNumber: 'No. dokumen',
  StringKey.inspectorRevisionTag: 'Revisi',
  StringKey.inspectorClient: 'Klien',
  StringKey.inspectorPreparedBy: 'Disiapkan oleh',
  StringKey.inspectorCheckedBy: 'Diperiksa oleh',
  StringKey.inspectorApprovedBy: 'Disetujui oleh',
  StringKey.inspectorRevisionHistory: 'Riwayat revisi',
  StringKey.inspectorAddRevision: 'Tambah revisi',
  StringKey.inspectorRevisionDateHint: 'YYYY-MM-DD',
  StringKey.inspectorRevisionDescHint: 'Uraian',

  // Inspector — Equipment schedule model/spec editor (N23).
  StringKey.inspectorEquipmentSchedule: 'Jadwal peralatan',
  StringKey.inspectorEquipmentScheduleHint:
      'Model / spesifikasi untuk jadwal peralatan yang diterbitkan. Kosong '
      'tercetak sebagai "—".',
  StringKey.inspectorModelSpecHint: 'Model / spesifikasi',

  // Export — OS save-dialog titles.
  StringKey.exportTitleCalcReport: 'Ekspor laporan hitung',
  StringKey.exportTitleMepReport: 'Ekspor laporan MEP terpadu',
  StringKey.exportTitleEquipmentSchedule: 'Ekspor jadwal peralatan',
  StringKey.exportTitleCalcReportPdf: 'Ekspor laporan hitung (PDF)',
  StringKey.exportTitleMepReportPdf: 'Ekspor laporan MEP terpadu (PDF)',
  StringKey.exportTitleEquipmentSchedulePdf: 'Ekspor jadwal peralatan (PDF)',
  StringKey.exportTitleDrawingDxf: 'Ekspor gambar (DXF)',
  StringKey.exportTitleDrawingPdf: 'Ekspor gambar (PDF)',
  StringKey.exportTitleAnnotatedPlanPdf: 'Ekspor denah beranotasi (PDF)',
  StringKey.exportTitleBom: 'Ekspor BOM',
  StringKey.exportTitleSldDxf: 'Ekspor satu-garis (DXF)',
  StringKey.exportTitleSldPdf: 'Ekspor satu-garis (PDF)',
  StringKey.exportTitleRiserSetPdf: 'Ekspor set gambar riser (PDF)',
  StringKey.exportTitleRiserSetDxf:
      'Ekspor set gambar riser (DXF, satu berkas per sistem)',
  StringKey.exportTitlePanelSchedulesPdf: 'Ekspor diagram panel (PDF)',
  StringKey.exportTitleElectricalPlanPdf: 'Ekspor denah instalasi (PDF)',
  StringKey.exportTitleElectricalPlanDxf: 'Ekspor denah instalasi (DXF)',
  StringKey.exportTitlePowerOneLineDxf: 'Ekspor daya satu-garis (DXF)',
  StringKey.exportTitleElectricalReport: 'Ekspor laporan kelistrikan',
  StringKey.exportTitleElectricalBom: 'Ekspor BOM kelistrikan',
  StringKey.exportTitleElectricalProposal: 'Ekspor proposal kelistrikan',

  // Electrical workspace — toolbar tabs + buttons.
  StringKey.electricalTabSingleLine: 'Satu-garis',
  StringKey.electricalTabPowerOneLine: 'Daya satu-garis',
  StringKey.electricalTabBuildingRiser: 'Riser bangunan',
  StringKey.electricalToolbarIssues: 'Masalah kelistrikan',
  StringKey.electricalToolbarIssuesCount: 'Masalah kelistrikan ({n})',
  StringKey.electricalServiceEarthing: 'Sambungan & Pembumian',
  StringKey.electricalAddPanel: '+ Panel',
  StringKey.electricalExport: 'Ekspor',
  StringKey.electricalClose: 'Tutup',

  // Electrical workspace — context-menu rows.
  StringKey.electricalMenuEdit: 'Ubah',
  StringKey.electricalMenuDuplicate: 'Duplikat',
  StringKey.electricalMenuDelete: 'Hapus',
  StringKey.electricalPanelProperties: 'Properti panel',
  StringKey.electricalMenuOpenPanel: 'Buka panel',
  StringKey.electricalMenuMarkEssential: 'Tandai esensial',
  StringKey.electricalMenuUnmarkEssential: 'Hapus tanda esensial',
  StringKey.electricalMenuMarkCritical: 'Tandai kritis (UPS)',
  StringKey.electricalMenuUnmarkCritical: 'Hapus tanda kritis (UPS)',
  StringKey.electricalMenuAddSubmeter: 'Tambah submeter',
  StringKey.electricalMenuRemoveSubmeter: 'Hapus submeter',
  StringKey.electricalMenuDisconnectFeeder: 'Putuskan feeder',
  StringKey.electricalMenuDeletePanel: 'Hapus panel',
  StringKey.electricalMenuDuplicatePanel: 'Duplikat panel',

  // Electrical workspace — circuit inspector.
  StringKey.electricalCircuitEditTitle: 'Ubah sirkuit',
  StringKey.electricalFieldProtection: 'Proteksi',
  StringKey.electricalFieldName: 'Nama',
  StringKey.electricalFieldLoadKind: 'Jenis beban',
  StringKey.electricalFieldMotorPower: 'Daya motor (kW)',
  StringKey.electricalFieldLoadW: 'Beban (W)',
  StringKey.electricalFieldCosPhi: 'cos phi (0-1)',
  StringKey.electricalFieldDemandFactor: 'Faktor permintaan (0-1)',
  StringKey.electricalFieldRunLength: 'Panjang tarikan (m)',
  StringKey.electricalFieldSupplyPhase: 'Fasa suplai',
  StringKey.electricalPhaseAuto: 'Otomatis',
  StringKey.electricalPhase1: '1-fasa',
  StringKey.electricalPhase3: '3-fasa',
  StringKey.electricalFieldCableType: 'Jenis kabel',
  StringKey.electricalCablePanelDefault: 'Default panel',
  StringKey.electricalFieldStarter: 'Starter / kontrol',
  StringKey.electricalStarterNone: 'Tidak ada',
  StringKey.electricalToggleLighting: 'Sirkuit pencahayaan (batas Vd 3%)',
  StringKey.electricalToggleLifeSafety: 'Keselamatan jiwa (tanpa RCD)',

  // Electrical workspace — panel inspector.
  StringKey.electricalFieldTag: 'Tag (mis. LP-1)',
  StringKey.electricalFieldDiversity: 'Faktor diversitas (0-1)',
  StringKey.electricalFieldHeadroomSpare: 'Cadangan — permintaan luang (%)',
  StringKey.electricalFieldSpareWays: 'Jalur cadangan (CADANGAN)',
  StringKey.electricalToggleEssential: 'Esensial (didukung genset)',
  StringKey.electricalToggleCritical: 'Kritis (didukung UPS)',
  StringKey.electricalToggleSubmeter: 'Submeter penyewa',

  // Electrical workspace — Service & Earthing field.
  StringKey.electricalFieldEarthingSystem: 'Sistem pembumian',

  // Electrical workspace — Loads palette group headers.
  StringKey.electricalPaletteLoads: 'Beban',
  StringKey.electricalPaletteMotorsPumps: 'Motor & pompa',
  StringKey.electricalPaletteDistribution: 'Distribusi',
  StringKey.electricalPaletteReadOnly:
      'Tampilan hanya-baca — beralih ke Segaris untuk mengedit',

  // Electrical workspace — Loads palette card labels.
  StringKey.electricalLoadLighting: 'Pencahayaan',
  StringKey.electricalLoadSockets: 'Stopkontak',
  StringKey.electricalLoadAircon1: 'AC (1φ)',
  StringKey.electricalLoadAircon3: 'AC (3φ)',
  StringKey.electricalLoadWaterHeater1: 'Pemanas air (1φ)',
  StringKey.electricalLoadWaterHeater3: 'Pemanas air (3φ)',
  StringKey.electricalLoadEv1: 'Pengisi EV (1φ)',
  StringKey.electricalLoadEv3: 'Pengisi EV (3φ)',
  StringKey.electricalLoadIndustrialSocket3: 'Stopkontak industri (3φ)',
  StringKey.electricalLoadUpsIt: 'Beban UPS / IT',
  StringKey.electricalLoadWelding3: 'Mesin las (3φ)',
  StringKey.electricalLoadCustom1: 'Beban khusus (1φ)',
  StringKey.electricalLoadCustom3: 'Beban khusus (3φ)',
  StringKey.electricalLoadMotorDol: 'Motor (DOL)',
  StringKey.electricalLoadMotorLarge: 'Motor (besar)',
  StringKey.electricalLoadPump1: 'Pompa (1φ)',
  StringKey.electricalLoadPump3: 'Pompa (3φ)',
  StringKey.electricalLoadFirePump: 'Pompa kebakaran',
  StringKey.electricalLoadSpareMcb: 'Jalur MCB cadangan',
  StringKey.electricalLoadSubPanel: 'Sub-panel',

  // Electrical workspace — empty state + gesture-guide items.
  StringKey.electricalEmptyTitle: 'Siapkan sambungan Anda',
  StringKey.electricalEmptyBody:
      'Tambahkan panel distribusi, lalu seret beban dari palet ke '
          'atasnya. Atur fasa suplai dan pembumian dari Sambungan & '
          'Pembumian.',
  StringKey.electricalGuide1:
      'Klik ganda komponen untuk mengubah ukuran, jenis, atau labelnya',
  StringKey.electricalGuide2:
      'Klik-kanan komponen untuk suku cadang pengganti yang cocok',
  StringKey.electricalGuide3:
      'Seret kartu dari palet ke panel untuk menambah jalur',
  StringKey.electricalGuide4:
      'Seret keluaran bundar sebuah panel ke panel lain untuk memberinya suplai',
  StringKey.electricalGuide5:
      'Seret beban ke panel untuk mengkabelkannya (membuat MCB)',
  StringKey.electricalGuide6:
      'Pilih panel atau beban mengambang lalu tekan Delete; klik-kanan jalur untuk menghapusnya',
  StringKey.electricalGuide7:
      'Seret kanvas kosong untuk menggeser; gulir untuk zoom; panel menampilkan isinya saat didekatkan',

  // Calibration overlay — next-step baton (A6). "Bangunan" matches the nav-rail
  // Building label.
  StringKey.calibrationScaleSetNext:
      'Skala diatur: {scale} - berikutnya: atur tinggi lantai (Bangunan)',

  // Apple design review Wave 2 — status + recovery copy.
  StringKey.autoSizedRuns:
      'Ukuran otomatis {count} saluran · ukuran ditampilkan pada denah',
  StringKey.recoveryTornUnreadable:
      'Berkas pemulihan tidak dapat dibaca. Mulai proyek baru atau buka '
          'salinan tersimpan.',

  // ── Apple design review Wave 5a (H1 + H6) — trust-surface localization.

  // H1 — compliance roll-up categories.
  StringKey.complianceCategoryAirVelocity: 'Kecepatan udara',
  StringKey.complianceCategorySheetCalibration: 'Kalibrasi lembar',
  StringKey.complianceCategoryStandardsVerification: 'Verifikasi standar',
  StringKey.complianceCategoryElectricalSizing: 'Pengukuran sirkuit listrik',
  StringKey.complianceAckEntry: 'Diakui: {label}',

  // H1 — compliance roll-up detail phrases.
  StringKey.complianceDetailAllWithinBand: 'semua dalam batas',
  StringKey.complianceDetailOutOfBand: '{n} di luar batas',
  StringKey.complianceDetailAllCalibrated: 'semua lembar terkalibrasi',
  StringKey.complianceDetailUncalibrated: '{n} belum dikalibrasi',
  StringKey.complianceDetailAllVerified: 'semua nilai terverifikasi',
  StringKey.complianceDetailAckNoneOpen: '{n} diakui, tidak ada yang terbuka',
  StringKey.complianceDetailRequireVerification:
      '{values} untuk diverifikasi atau diakui',
  StringKey.complianceDetailOpenAck: '{open} terbuka, {ack} diakui',
  StringKey.complianceDetailNoSizingErrors: 'tidak ada kesalahan pengukuran',
  StringKey.complianceDetailWarningsNoErrors: '{warnings}, tanpa kesalahan',
  StringKey.complianceDetailErrorsWarnings: '{errors}, {warnings}',

  // H1 — compliance pluralized nouns (ID has no plural inflection: same word).
  StringKey.complianceNounValueOne: 'nilai',
  StringKey.complianceNounValueMany: 'nilai',
  StringKey.complianceNounWarningOne: 'peringatan',
  StringKey.complianceNounWarningMany: 'peringatan',
  StringKey.complianceNounErrorOne: 'kesalahan',
  StringKey.complianceNounErrorMany: 'kesalahan',
  StringKey.complianceNounFindingOne: 'temuan',
  StringKey.complianceNounFindingMany: 'temuan',
  StringKey.complianceNounAdvisoryNoteOne: 'catatan anjuran',
  StringKey.complianceNounAdvisoryNoteMany: 'catatan anjuran',

  // H1 — Review hub chrome.
  StringKey.reviewHubTitle: 'Tinjauan',
  StringKey.reviewHubLead: 'Periksa desain sebelum Anda menerbitkannya.',
  StringKey.reviewStatPanelsSized: 'Panel terhitung',
  StringKey.reviewStatBomLineItems: 'Item baris BOM',
  StringKey.reviewStatStockPipes: 'Batang pipa',
  StringKey.reviewStatPipeRequired: 'Pipa diperlukan',
  StringKey.reviewStatOffcutWaste: 'Sisa potongan',
  StringKey.reviewStockNote:
      'Panjang batang: 4 m PVC/PPR, 6 m baja (sprinkler/hidran), dan bagian '
          'saluran 1,2 m BJLS / 4 m PU. Rencana potong menggunakan kembali sisa '
          'potongan untuk meminimalkan limbah; kopling dan flensa saluran pada '
          'kanvas jatuh di batas-batas ini. Laporan hitung (PDF atau MD, di '
          'bawah) memuat rincian lengkapnya.',
  StringKey.reviewExportDeliverables: 'Ekspor dokumen serah',
  StringKey.reviewIssueReady: 'LULUS — siap diterbitkan',
  StringKey.reviewIssueReviewRequired:
      'PERLU TINJAUAN — Anda memutuskan apakah akan menerbitkan',
  StringKey.reviewExportSubmittalPackage: 'Ekspor paket serah...',
  StringKey.reviewSubmittalHint:
      'Paket serah di atas juga menyertakan gambar (denah beranotasi lembar '
          'saat ini, riser mekanikal, dan satu-garis kelistrikan). Untuk satu '
          'gambar per lembar, gunakan tombol Ekspor di layar Proyek atau '
          'tampilan Riser.',
  StringKey.reviewVerdictPass: 'LULUS',
  StringKey.reviewVerdictReviewRequired: 'PERLU TINJAUAN',
  StringKey.reviewDesignSignoff: 'pengesahan desain',
  StringKey.reviewItemPass: 'LULUS',
  StringKey.reviewItemReview: 'TINJAU',
  StringKey.reviewPipeCutPlan: 'Rencana potong pipa',
  StringKey.reviewConsumablesTitle: 'Bahan habis pakai (perkiraan)',
  StringKey.reviewConsumablePvcCement: 'Semen pelarut PVC',
  StringKey.reviewConsumableDuctSealant: 'Sealant sambungan saluran',
  StringKey.reviewConsumableThreadTape: 'Pita seal ulir',
  StringKey.reviewConsumablesNote:
      'Perkiraan — cakupan mengasumsikan kaleng semen ~1 L, kartrid sealant '
          '300 ml, 30 sambungan/rol pita (verifikasi per lembar data). Pipa air '
          'PPR dilas-panas (tanpa semen).',

  // H1 — Design issues card chrome.
  StringKey.issuesCardCleanTitle: 'Tidak ditemukan masalah desain',
  StringKey.issuesCardCleanBody:
      'Kecepatan udara dalam batas, lembar terkalibrasi, dan '
          'setiap nilai standar telah diperhitungkan.',
  StringKey.issuesCardTitle: 'Masalah desain',
  StringKey.issuesCardQuickFixes: 'Perbaikan cepat',
  StringKey.issuesCardWarnings: 'Peringatan',
  StringKey.issuesCardAdvisory: 'Anjuran',
  StringKey.issuesCardAcknowledged: 'Diakui',
  StringKey.issuesCardAcknowledgeAll: 'Akui semua',
  StringKey.issuesCardAcknowledge: 'Akui',
  StringKey.issuesCardUndo: 'Urungkan',
  StringKey.issuesCardLocate: 'Cari lokasi',
  StringKey.issuesCardAckInitials: 'Inisial',
  StringKey.issuesCardAckReasonHint: 'Alasan (opsional)',
  StringKey.issuesCardAckCancel: 'Batal',

  // H1 — Design issue titles.
  StringKey.issueOrphanTitle: 'Elemen merujuk lantai atau lembar yang hilang',
  StringKey.issueDuctVelocityTitle: 'Kecepatan saluran di luar batas',
  StringKey.issueTerminalVelocityTitle: 'Kecepatan muka terminal di luar batas',
  StringKey.issueAirDuctUnsizedTitle: 'Saluran udara belum diukur manual',
  StringKey.issueAirTerminalUnsizedTitle: 'Terminal udara belum diukur manual',
  StringKey.issueDuctOverCapacityTitle: 'Saluran melebihi kapasitas',
  StringKey.issueDiffuserStrandedTitle:
      'Difuser tidak terhubung ke saluran mana pun',
  StringKey.issueSheetNotCalibratedTitle: 'Lembar belum dikalibrasi',
  StringKey.issueCalibrationStaleTitle:
      'Denah diganti — verifikasi ulang skala',
  StringKey.issueMultiSheetFloorTitle:
      'Beberapa lembar dipetakan ke satu lantai',
  StringKey.issueNetworkIslandTitle: 'Cabang jaringan tidak terhubung',
  StringKey.issueNetworkNoSourceTitle: 'Jaringan tidak memiliki sumber',
  StringKey.issueDrainageSlopeTitle: 'Kemiringan drainase di bawah swa-bersih',
  StringKey.issueDrainageLengthTitle: 'Cabang drainase terlalu panjang',
  StringKey.issueDrainageCleanoutTitle: 'Cleanout tegak drainase',
  StringKey.issueLegionellaTitle: 'Suhu balik air panas rendah',
  StringKey.issueElectricalTitle: 'Listrik: {code}',
  StringKey.issueUnverifiedTitle: 'Belum terverifikasi: {name}',
  StringKey.issueUnconnectedLooseEndTitle: 'Ujung jalur tidak terhubung',
  StringKey.issueUnconnectedLooseEndMessage:
      'Jalur ini berakhir di sambungan kosong — tidak tersambung ke fikstur, '
      'terminal, plant, atau jalur lain. Sambungkan ujung yang menggantung '
      'atau hapus.',
  StringKey.issueUnconnectedOrphanTitle: 'Elemen tidak terhubung',
  StringKey.issueUnconnectedOrphanMessage:
      'Elemen ini ditempatkan tetapi tidak terhubung ke apa pun. Sambungkan ke '
      'jaringan, atau hapus.',
  StringKey.issueUnfedPanelTitle: 'Panel tidak terhubung ke suplai',
  StringKey.issueUnfedPanelMessage:
      '"{panel}" bukan panel asal maupun disuplai oleh feeder — tidak '
      'tersambung ke apa pun. Suplai dari panel di hulunya.',
  StringKey.issuePressureZoneTitle: 'Zona tekanan melebihi batas fikstur',
  StringKey.issuePressureZoneMessage:
      'Zona tekanan dari "{bottom}" hingga "{top}" mencapai {kpa} kPa statik di '
      'fikstur terendahnya, di atas tekanan statik fikstur maksimum SNI {limit} '
      'kPa. Tambahkan PRV / tangki pemutus untuk membagi zona.',
  StringKey.issueRevisionTagMissingTitle:
      'Revisi belum diisi untuk riwayat yang tercatat',
  StringKey.issueRevisionTagMissingMessage:
      'Riwayat revisi memiliki entri tetapi kolom Revisi pada kop gambar kosong, '
      'sehingga setiap lembar dan laporan yang diterbitkan tidak mencantumkan '
      'revisi. Isi Revisi saat ini di bawah Kontrol dokumen.',

  // H1 — Design issue messages.
  StringKey.issueOrphanFloorMessage:
      'Sebuah elemen tergambar berada di lantai {floor}, yang sudah tidak ada '
          'lagi (bangunan memiliki {floors}) — elemen ini diukur pada elevasi '
          'yang dijepit. Hapus atau pindahkan ke lantai yang nyata.',
  StringKey.issueOrphanSheetMessage:
      'Sebuah elemen tergambar termasuk dalam lembar yang tidak lagi dimuat — '
          'impor ulang lembar itu atau hapus elemen yatim tersebut.',
  StringKey.issueAirDuctUnsizedMessage:
      'Saluran ini mengalirkan udara tetapi belum memiliki ukuran terpilih — '
          'masih mengandalkan pengukuran otomatis.',
  StringKey.issueAirTerminalUnsizedMessage:
      'Terminal ini mengalirkan udara tetapi belum memiliki ukuran muka '
          'terpilih.',
  StringKey.issueDuctOverCapacityMessage:
      'Saluran ini mengalirkan lebih banyak udara daripada yang bisa ditangani '
          'saluran standar terbesar dalam batas kecepatan / gesekan — ukurannya '
          'dijepit ke ukuran standar terbesar. Bagi salurannya atau tambahkan '
          'saluran paralel.',
  StringKey.issueDiffuserStrandedMessage:
      'Terminal udara ini membawa aliran udara desain tetapi tidak ada saluran '
          'yang terhubung — kebutuhannya tak terlihat oleh pengukuran saluran '
          'dan BOM. Arahkan saluran ke sana (atau sambungkan trunk suplai '
          'setelah menempatkan difuser otomatis).',
  StringKey.issueSheetNotCalibratedCriticalMessage:
      '"{name}" memuat saluran tergambar tetapi belum memiliki skala — '
          'semuanya diukur ke panjang NOL. Kalibrasi lembar sebelum pengukuran '
          'atau ekspor, atau BOM dan tekanan akan salah.',
  StringKey.issueSheetNotCalibratedWarningMessage:
      '"{name}" belum memiliki skala — panjang saluran/riser-nya tidak dapat '
          'diukur. Kalibrasi lembar untuk mengukurnya.',
  StringKey.issueCalibrationStaleMessage:
      'Denah "{name}" telah diganti tetapi masih memakai skala LAMA — gambar '
          'revisi (DPI, skala cetak, atau kop gambar yang berbeda) dapat diam-'
          'diam membawa kalibrasi yang salah. Verifikasi ulang skalanya, atau '
          'konfirmasi bahwa skala itu masih berlaku.',
  StringKey.issueMultiSheetFloorMessage:
      '{count} lembar dipetakan ke lantai "{floor}" ({names}) — hanya satu '
          'denah per lantai yang memasok pengukuran pada elevasi itu, sehingga '
          'kelebihannya ditumpuk di sana (sering kali impor yang melewati '
          'jumlah lantai). Petakan ulang lembar tambahan atau tambahkan lantai.',
  StringKey.issueNetworkIslandMessage:
      'Cabang {service} dengan {nodes} terputus dari jaringan yang dipasoknya — '
          'ia diakar secara heuristik dan diukur seolah-olah dipasok. Hubungkan '
          'ke sumber, atau tambahkan plant.',
  StringKey.issueNetworkNoSourceMessage:
      'Komponen {service} dengan {nodes} tidak memiliki plant/sumber — ia '
          'diakar secara heuristik dan diukur seolah-olah dipasok. Tambahkan '
          'sumber pompa / tangki / AHU.',
  StringKey.issueDrainageCleanoutMessage:
      'Sebuah tegak drainase mencapai titik gambar terendahnya di sini tanpa '
          'komponen cleanout di atau di samping dasarnya — akses rodding lazim '
          'ada di setiap dasar tegak. Tempatkan cleanout, atau pastikan akses '
          'tersedia di tempat lain.',
  StringKey.issueLegionellaMessage:
      'Suhu balik resirkulasi termodelkan {temp} °C berada di bawah batas '
          'anti-Legionella (~55 °C). Kurangi penurunan suhu loop atau tambahkan '
          'pemanas jejak. (// VERIFY terhadap panduan SNI / WHO.)',

  // H1 — Design issue pluralized nouns + batch labels.
  StringKey.issueNounFloorOne: 'lantai',
  StringKey.issueNounFloorMany: 'lantai',
  StringKey.issueNounNodeOne: 'simpul',
  StringKey.issueNounNodeMany: 'simpul',
  StringKey.issueNounVelocityOne: 'kecepatan',
  StringKey.issueNounVelocityMany: 'kecepatan',
  StringKey.issueNounElementOne: 'elemen',
  StringKey.issueNounElementMany: 'elemen',
  StringKey.issueNounSheetOne: 'lembar',
  StringKey.issueNounSheetMany: 'lembar',
  StringKey.issueBatchSelectVelocity: 'Pilih {c} {noun} di luar batas',
  StringKey.issueBatchSelectUnsized: 'Pilih {c} {noun} udara belum terukur',
  StringKey.issueBatchCalibrateNoSource:
      'Kalibrasi satu lembar untuk menyalin skala ke {n} lainnya',
  StringKey.issueBatchCalibrateCopy: 'Salin skala ke {n} {noun} belum dikalibrasi',

  // H6 — Copilot panel.
  StringKey.copilotTitle: 'Tanya Claude',
  StringKey.copilotClose: 'Tutup',
  StringKey.copilotDescription:
      'Pilih ruangan atau elemen, lalu minta Claude menambahkan peralatan, '
          'saluran, atau terminal — atau menempatkan terminal udara ruangan '
          'secara otomatis. Claude menambahkan dan memberi saran; ia tidak '
          'mengubah atau menghapus elemen yang ada. Anda meninjau setiap '
          'langkah sebelum diterapkan.',
  StringKey.copilotThinkingButton: 'Berpikir…',
  StringKey.copilotAsk: 'Tanya',
  StringKey.copilotHintEnabled: 'mis. desain suplai udara untuk ruangan ini',
  StringKey.copilotHintDisabled:
      'Tambahkan kunci API di Preferensi untuk mengaktifkan',
  StringKey.copilotPlanning: 'Claude sedang merencanakan…',
  StringKey.copilotApplied: 'Diterapkan.',
  StringKey.copilotSkipped: 'Dilewati',
  StringKey.copilotDone: 'Selesai',
  StringKey.copilotNoSuggestion: 'Tidak ada saran.',
  StringKey.copilotProposedPlan: 'Rencana usulan · {changes}',
  StringKey.copilotApply: 'Terapkan',
  StringKey.copilotDiscard: 'Buang',
  StringKey.copilotChangeNounOne: 'perubahan',
  StringKey.copilotChangeNounMany: 'perubahan',

  // H6 — half-localized odds & ends.
  StringKey.electricalLoadSampleProject: 'Muat proyek contoh',
  StringKey.projectApplyBuildingTemplate: 'Terapkan templat bangunan',

  // Workflow-goldens review (2026-07-06).
  StringKey.templateAppliedImportPrompt:
      'Templat diterapkan — impor denah saat sudah siap',
  StringKey.workflowStageCalibrate: 'Kalibrasi',
  StringKey.workflowStageBuilding: 'Bangunan',
  StringKey.workflowStageDraw: 'Gambar',
  StringKey.workflowStageSize: 'Ukuran',
  StringKey.workflowStageReport: 'Laporan',
  StringKey.firstRunStepCalibrateDesc: 'atur skala gambar pada denah Anda',
  StringKey.firstRunStepBuildingDesc: 'atur tinggi setiap lantai',
  StringKey.firstRunStepDrawDesc: 'gambar pipa, saluran, dan panel',
  StringKey.firstRunStepSizeDesc: 'ukuran otomatis sesuai SNI / PUIL',
  StringKey.firstRunStepReportDesc: 'ekspor BOM dan laporan perhitungan',
  StringKey.electricalPowerOneLineEmptyBody:
      'Tambahkan generator dari tombol Sumber di toolbar di atas untuk '
          'membangun diagram satu-garis daya hibrida dengan interlock sumber.',

  // L5/M4 — the shared MechXTooltip hover-tooltip mechanism.
  StringKey.tooltipZoomIn: 'Perbesar',
  StringKey.tooltipZoomOut: 'Perkecil',
  StringKey.tooltipZoomFit: 'Sesuaikan tampilan',
  StringKey.tooltipCollapseInspector: 'Ciutkan panel',
  StringKey.tooltipExpandInspector: 'Perluas panel',

  // E5 — the on-canvas service-colour legend chip.
  StringKey.canvasLegendTitle: 'Keterangan',
  StringKey.tooltipHideLegend: 'Sembunyikan keterangan',
  StringKey.tooltipShowLegend: 'Tampilkan keterangan',

  // Theme F — layer lock (F1) / per-service filter (F4) / armed placement (F5).
  StringKey.tooltipLockLayer: 'Kunci lapisan',
  StringKey.tooltipUnlockLayer: 'Buka kunci lapisan',
  StringKey.tooltipFilterServices: 'Saring layanan',
  StringKey.placementArmedHint:
      'Menempatkan {item} · klik untuk menaruh · Esc untuk batal',
  StringKey.a11yShowLayer: 'Tampilkan lapisan',
  StringKey.a11yHideLayer: 'Sembunyikan lapisan',
  StringKey.a11yDecrease: 'Kurangi',
  StringKey.a11yIncrease: 'Tambah',
  StringKey.a11yMinimapHint:
      'Peta mini kanvas — ketuk atau seret untuk memindahkan tampilan',
  StringKey.a11yFieldDepth: 'Kedalaman',
  StringKey.a11yFieldCeilingHeight: 'Tinggi plafon',
  StringKey.a11yFieldAirChangesPerHour: 'Pergantian udara per jam',
  StringKey.a11yFieldFloorToFloorHeight: 'Tinggi antar lantai',
  StringKey.a11yFieldNumberOfLevels: 'Jumlah lantai',
  StringKey.a11yFieldFloorHeight: 'Tinggi lantai',

  // A1 — Layout empty-state 'Load sample project'.
  StringKey.layoutLoadSampleProject: 'Muat proyek contoh',

  // A5 — Projects-hub export grouping.
  StringKey.projectsExportGroupDrawings: 'Gambar',
  StringKey.projectsExportGroupReports: 'Laporan',
  StringKey.projectsExportGroupData: 'Data',
  StringKey.projectsExportDrawingPdfHint:
      'Denah polos — tanpa panjang jalur/riser terkalibrasi pada label ukuran.',
  StringKey.projectsExportAnnotatedPlanPdfHint:
      'Denah beranotasi — menyertakan panjang jalur/riser sebenarnya pada '
          'setiap label ukuran.',
};

/// The active string table for a locale. Exposed for tests; resolves a [key]
/// against the active map, falling back to English for any missing translation.
@immutable
class MechXStringsData {
  final AppLocale locale;
  const MechXStringsData(this.locale);

  Map<StringKey, String> get _map => switch (locale) {
        AppLocale.en => _en,
        AppLocale.id => _id,
      };

  /// Resolve [key]: the active locale's value, or the English fallback so the
  /// app never renders a blank for an as-yet-untranslated key.
  String call(StringKey key) => _map[key] ?? _en[key]!;

  /// Resolve a parameterized [key] whose template carries `{name}` placeholders,
  /// substituting each entry of [params] (e.g. `format(k, {'n': 3})` turns
  /// `'{n} items'` into `'3 items'`). Unknown placeholders are left intact and
  /// unused params ignored, so a template + call can never throw. Falls back to
  /// English like [call] — keep the `{name}` placeholders identical across the EN
  /// and ID templates so both substitute correctly.
  String format(StringKey key, Map<String, Object?> params) {
    var out = _map[key] ?? _en[key]!;
    params.forEach((k, v) => out = out.replaceAll('{$k}', '$v'));
    return out;
  }
}

/// Inherited string table. Mirrors [MechXTheme]: provided once above the shell
/// (keyed off [localeProvider]) and read via the `context.strings` extension.
class MechXStrings extends InheritedWidget {
  final MechXStringsData data;

  const MechXStrings({super.key, required this.data, required super.child});

  /// The active string table for [context]. Falls back to English when no
  /// [MechXStrings] ancestor is present (e.g. a widget pumped in isolation by a
  /// test, or before the root provider is mounted) so `context.strings` never
  /// throws — a missing provider degrades to EN rather than crashing.
  static MechXStringsData of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<MechXStrings>();
    return widget?.data ?? const MechXStringsData(AppLocale.en);
  }

  static MechXStringsData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MechXStrings>()?.data;

  @override
  bool updateShouldNotify(MechXStrings oldWidget) =>
      data.locale != oldWidget.data.locale;
}

/// Ergonomic accessor: `context.strings(StringKey.navLayout)`.
extension MechXStringsContext on BuildContext {
  MechXStringsData get strings => MechXStrings.of(this);
}

/// Test-only view onto the raw maps (so the i18n test can assert key parity and
/// resolution without reaching into private symbols via reflection).
@visibleForTesting
Map<StringKey, String> debugEnStrings() => _en;
@visibleForTesting
Map<StringKey, String> debugIdStrings() => _id;
