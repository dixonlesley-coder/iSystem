import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/model.dart' show ElectricalProject;

import '../ai/ai_client.dart';
import '../store/annotation_store.dart';
import '../store/app_state.dart';
import '../store/commercial_store.dart';
import '../store/document_control_store.dart';
import '../store/electrical_store.dart';
import '../store/fire_store.dart';
import '../store/fixture_library_store.dart';
import '../store/history_store.dart';
import '../store/network_store.dart';
import '../store/project_store.dart';
import '../store/sheets_store.dart';
import 'project_document.dart';
import 'recovery.dart';

/// A generic provider reader satisfied by BOTH `WidgetRef.read` and
/// `ProviderContainer.read`. It lets the persistence glue (build/apply a
/// document) run unchanged from a widget (Save/Open) and from the headless
/// autosave loop.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// A recovery snapshot found on launch: the decoded document plus the
/// snapshot file's mtime (null when the mtime couldn't be read). Carrying the
/// timestamp alongside the doc lets the recovery banner say *when* the work
/// was last autosaved, not just that some work exists.
typedef RecoverySnapshot = ({ProjectDocument doc, DateTime? savedAt});

/// A recovery snapshot found on launch (previous session ended without a
/// clean exit). Non-null ⇒ the shell offers to restore it.
final recoveryDocProvider =
    NotifierProvider<RecoveryController, RecoverySnapshot?>(
  RecoveryController.new,
);

class RecoveryController extends Notifier<RecoverySnapshot?> {
  @override
  RecoverySnapshot? build() => null;

  void set(RecoverySnapshot? snapshot) => state = snapshot;
  void clear() => state = null;
}

/// Encoded JSON of the last state written to a real `.mechx` file (Save) or
/// loaded from one (Open) — the "clean" baseline. The autosave loop compares
/// against it so it never re-writes a recovery snapshot for work that is
/// already saved (which would resurrect a phantom recovery banner next launch).
final lastSavedSignatureProvider =
    NotifierProvider<LastSavedController, String?>(LastSavedController.new);

class LastSavedController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? signature) => state = signature;
}

/// Build a [ProjectDocument] from the live state reachable via [read].
ProjectDocument buildDocument(ProviderReader read) {
  final project = read(projectControllerProvider);
  final sheets = read(sheetsControllerProvider);
  final ducts = read(ductSettingsProvider);
  final commercial = read(commercialSettingsProvider);
  return ProjectDocument(
    projectName: project.name,
    floors: project.floors,
    calibrations: project.calibrations,
    sheets: sheets.sheets,
    network: read(networkControllerProvider).network,
    viewports: sheets.viewports,
    sheetFloors: sheets.sheetFloors,
    settings: DesignSettings(
      occupancy: read(occupancyProvider),
      upfeed: read(feedStrategyProvider) == FeedStrategy.upfeed,
      ductShape: ducts.shape,
      ductMethod: ducts.method,
      rainfallMmPerHr: read(rainfallIntensityProvider),
      runoffCoefficientStorm: read(runoffCoefficientProvider),
      fireHazard: read(fireHazardProvider),
      brightness: read(brightnessProvider),
      localeCode: read(localeProvider).name,
      // Commercial settings (pricelist + quote markups) round-trip too.
      priceList: commercial.priceList,
      labourRatePerHour: commercial.labourRatePerHour,
      overheadPct: commercial.overheadPct,
      contingencyPct: commercial.contingencyPct,
      marginPct: commercial.marginPct,
      // The user-defined fixture library round-trips with the project.
      fixtureLibrary: read(fixtureLibraryProvider),
      // BYO Claude copilot key + model + provider round-trip with the project.
      anthropicApiKey: read(aiApiKeyProvider),
      aiModel: read(aiModelProvider),
      aiProvider: read(aiProviderProvider).name,
      // Document control (drawing number/revision/client/DRAWN-CHECKED-APPROVED
      // + revision history) round-trips with the project.
      documentNumber: read(documentControlProvider).documentNumber,
      revisionTag: read(documentControlProvider).revisionTag,
      clientName: read(documentControlProvider).clientName,
      preparedBy: read(documentControlProvider).preparedBy,
      checkedBy: read(documentControlProvider).checkedBy,
      approvedBy: read(documentControlProvider).approvedBy,
      revisions: read(documentControlProvider).revisions,
    ),
    // The electrical sub-model (v2) round-trips alongside the plumbing project.
    electrical: read(electricalProjectProvider),
    // Measurement annotations round-trip with the project.
    measurements: read(measurementsProvider),
    // Designated tank areas round-trip with the project.
    tanks: read(tankAreasProvider),
    // Designated room/zone areas round-trip with the project.
    rooms: read(roomAreasProvider),
  );
}

/// The canonical encoding of a brand-new, untouched project — the default
/// settings plus whatever the stores seed on a fresh launch (notably the
/// built-in sample electrical board), with nothing drawn. Computed once from a
/// throwaway [ProviderContainer] so the dirty guard and the autosave loop agree
/// on exactly what "virgin" looks like, and memoized (the defaults are constant).
/// The container is deliberately not disposed — a single tiny leak for the
/// process, mirroring the root container the app never disposes — so the
/// electrical controller's post-build sync microtask never reads a disposed ref.
String? _virginSignature;
String virginDocumentSignature() =>
    _virginSignature ??= buildDocument(ProviderContainer().read).encode();

/// Whether the live work reachable via [read] genuinely differs from the last
/// clean Save — the GUARD-time dirty check (computed FRESH, unlike the timer-fed
/// [projectDirtyProvider] UI hint). A project that was saved/opened is dirty when
/// it no longer matches that baseline; a never-saved project is dirty only once
/// it diverges from the untouched virgin default (so a blank launch — or one that
/// only seeded the sample board — is NOT dirty and is never destroyed silently).
bool isProjectDirty(ProviderReader read) {
  final encoded = buildDocument(read).encode();
  final saved = read(lastSavedSignatureProvider);
  return saved != null
      ? encoded != saved
      : encoded != virginDocumentSignature();
}

/// Load [doc] into every live store/provider reachable via [read] — the drawn
/// project AND the non-network design settings (occupancy, feed, ducts,
/// rainfall, fire hazard, theme). Used by both Open and crash-recovery restore.
void applyDocument(ProviderReader read, ProjectDocument doc) {
  read(projectControllerProvider.notifier).load(
        name: doc.projectName,
        floors: doc.floors,
        calibrations: doc.calibrations,
      );
  read(sheetsControllerProvider.notifier).loadSheets(
        doc.sheets,
        viewports: doc.viewports,
        sheetFloors: doc.sheetFloors,
      );
  read(networkControllerProvider.notifier).loadNetwork(doc.network);
  // An opened/restored document is a fresh baseline — clear the global timeline
  // to match the per-domain controllers clearing their own stacks on load.
  read(historyProvider.notifier).reset();
  final s = doc.settings;
  read(occupancyProvider.notifier).set(s.occupancy);
  read(feedStrategyProvider.notifier)
      .set(s.upfeed ? FeedStrategy.upfeed : FeedStrategy.downfeed);
  read(ductSettingsProvider.notifier)
    ..setShape(s.ductShape)
    ..setMethod(s.ductMethod);
  read(rainfallIntensityProvider.notifier).set(s.rainfallMmPerHr);
  read(runoffCoefficientProvider.notifier).set(s.runoffCoefficientStorm);
  read(fireHazardProvider.notifier).set(s.fireHazard);
  read(brightnessProvider.notifier).set(s.brightness);
  read(localeProvider.notifier)
      .set(s.localeCode == 'id' ? AppLocale.id : AppLocale.en);
  // Restore the commercial settings (pricelist + quote markups). Absent on an
  // older file ⇒ defaults (empty pricelist, engine-default markups).
  read(commercialSettingsProvider.notifier).set(CommercialSettings(
    priceList: s.priceList,
    labourRatePerHour: s.labourRatePerHour,
    overheadPct: s.overheadPct,
    contingencyPct: s.contingencyPct,
    marginPct: s.marginPct,
  ));
  // Restore the user-defined fixture library (absent on an older file ⇒ empty).
  read(fixtureLibraryProvider.notifier).set(s.fixtureLibrary);
  // Restore the BYO Claude copilot key + model + provider (absent ⇒ disabled /
  // default / Anthropic).
  read(aiApiKeyProvider.notifier).set(s.anthropicApiKey);
  read(aiModelProvider.notifier).set(s.aiModel);
  read(aiProviderProvider.notifier).set(aiProviderFromName(s.aiProvider));
  // Restore document control (absent on an older file ⇒ all unset / no
  // revisions, the controller's own defaults).
  read(documentControlProvider.notifier).set(DocumentControl(
    documentNumber: s.documentNumber,
    revisionTag: s.revisionTag,
    clientName: s.clientName,
    preparedBy: s.preparedBy,
    checkedBy: s.checkedBy,
    approvedBy: s.approvedBy,
    revisions: s.revisions,
  ));
  // Restore the electrical project. A v2 file carries one; a plumbing-only / v1
  // document has NO electrical sub-model — fall back to an EMPTY project (no
  // fictitious sample switchboard), so its BOM / equipment schedule / unified
  // report and the Review "panels sized" count read 0 panels rather than the
  // sample MDP/LP-1. The built-in sample now seeds ONLY a brand-new project (the
  // controller's `build()`), never an opened/recovered document.
  read(electricalProjectProvider.notifier)
      .setProject(doc.electrical ?? const ElectricalProject());
  // Restore measurement annotations (absent on an older file ⇒ empty).
  read(measurementsProvider.notifier).set(doc.measurements);
  // Restore designated tank areas (absent on an older file ⇒ empty).
  read(tankAreasProvider.notifier).set(doc.tanks);
  // Restore designated room/zone areas (absent on an older file ⇒ empty).
  read(roomAreasProvider.notifier).set(doc.rooms);
}

/// Start the periodic autosave loop: every [interval], snapshot the current
/// work to the recovery file — but only once the work differs from a clean
/// baseline (so a saved project never leaves a stale recovery snapshot behind).
/// The baseline is the last clean Save/Open when one exists, else the untouched
/// virgin default: a blank launch (or one that only carries the seeded sample
/// board) is clean and writes nothing, while an electrical-only or measurement-
/// only project — which has no drawn network nodes — DOES get recovered. Returns
/// the timer so the caller can cancel it.
Timer startAutosave(
  ProviderContainer c, {
  Duration interval = const Duration(seconds: 15),
}) {
  String? lastWritten; // last content we mirrored to the recovery file
  return Timer.periodic(interval, (_) {
    final doc = buildDocument(c.read);
    final encoded = doc.encode();
    final saved = c.read(lastSavedSignatureProvider);
    // Clean when it matches the last real Save, or (never saved yet) still equals
    // the untouched virgin default — either way there is nothing worth recovering.
    final clean = saved != null
        ? encoded == saved
        : encoded == virginDocumentSignature();
    // Piggy-back the "edited" indicator on the signature comparison we're
    // already doing (Save/Open clear it eagerly; this catches new edits).
    c.read(projectDirtyProvider.notifier).set(!clean);
    // Skip when the work already matches the clean baseline (no phantom
    // recovery), or when we've already mirrored this exact content.
    if (clean || encoded == lastWritten) {
      return;
    }
    lastWritten = encoded;
    writeRecovery(doc);
  });
}
