import 'dart:async';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/model.dart' show ElectricalProject;

import '../store/annotation_store.dart';
import '../store/app_state.dart';
import '../store/commercial_store.dart';
import '../store/design_issues_store.dart';
import '../store/document_control_store.dart';
import '../store/electrical_feed.dart';
import '../store/electrical_store.dart';
import '../store/equipment_spec_store.dart';
import '../store/fire_store.dart';
import '../store/assemblies_store.dart';
import '../store/fixture_library_store.dart';
import '../store/history_store.dart';
import '../store/network_store.dart';
import '../store/project_store.dart';
import '../store/reference_line_store.dart';
import '../store/sheets_store.dart';
import '../ui/canvas/underlay_snap_service.dart';
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
/// was last autosaved, not just that some work exists. A null [doc] means a
/// snapshot file EXISTS but could not be decoded (torn by an interrupted
/// write) — the banner surfaces that distinctly instead of restoring nothing
/// silently, so a torn snapshot is never indistinguishable from a clean exit.
///
/// [sourcePath] is the `.mechx` file the snapshot belongs to (from its `.src`
/// sidecar) — a Restore re-links the file identity to it so the next Ctrl+S
/// saves back to the right file, not a Save-As fork. [recoveryPath] is the
/// snapshot file itself, so a discard clears the correct per-project slot.
typedef RecoverySnapshot = ({
  ProjectDocument? doc,
  DateTime? savedAt,
  String? sourcePath,
  String? recoveryPath,
});

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

/// The last encoded content the autosave tick mirrored to the recovery file —
/// hoisted OUT of the timer closure so Save/Open can reset it. Without the
/// reset, undoing back to a previously-mirrored state after a Save would skip
/// the recovery rewrite (the stale mirror still matches), leaving dirty work
/// with zero snapshot: dirty-after-Save must get a fresh snapshot on the next
/// tick. Null means "nothing mirrored since the last clean Save/Open".
final autosaveMirrorProvider =
    NotifierProvider<AutosaveMirrorController, String?>(
  AutosaveMirrorController.new,
);

class AutosaveMirrorController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? encoded) => state = encoded;
  void clear() => state = null;
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
    groundIndex: project.groundIndex,
    calibrations: project.calibrations,
    staleCalibrations: project.staleCalibrations,
    sheets: sheets.sheets,
    network: read(networkControllerProvider).network,
    viewports: sheets.viewports,
    sheetFloors: sheets.sheetFloors,
    settings: DesignSettings(
      occupancy: read(occupancyProvider),
      upfeed: read(feedStrategyProvider) == FeedStrategy.upfeed,
      // G1 solved-duty MEP feed opt-in round-trips (default off ⇒ omitted).
      mepDutyFeedEnabled: read(mepDutyFeedEnabledProvider),
      ductShape: ducts.shape,
      ductMethod: ducts.method,
      rainfallMmPerHr: read(rainfallIntensityProvider),
      runoffCoefficientStorm: read(runoffCoefficientProvider),
      // M13/M14/M15 — the four design inputs that used to be dark engine
      // constants (the drainage fall, the hot-water flow temp + loop ΔT behind
      // the Legionella check, and which cooling-load basis the Rooms AC
      // estimate uses). They are real per-project choices now, so they must
      // survive Save/Open like any other. Defaults mirror the engine's own
      // (1:100 / 60 °C / 5 K / simple) ⇒ an untouched project encodes
      // byte-identically.
      drainageSlope: read(drainageSlopeProvider),
      hotWaterFlowTempC: read(hotWaterFlowTempProvider),
      hotWaterDeltaTK: read(hotWaterDeltaTProvider),
      coolingLoadMethod: read(coolingLoadMethodProvider).code,
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
      // Saved drawing assemblies (E5) round-trip with the project.
      savedAssemblies: read(assembliesProvider),
      // The BYO AI copilot provider/key/model are MACHINE-LOCAL (kept out of the
      // shareable `.mechx` — B8): they live in `app_settings.dart`, so the
      // document carries the harmless defaults and never leaks the secret key.
      // Document control (drawing number/revision/client/DRAWN-CHECKED-APPROVED
      // + revision history) round-trips with the project.
      documentNumber: read(documentControlProvider).documentNumber,
      revisionTag: read(documentControlProvider).revisionTag,
      clientName: read(documentControlProvider).clientName,
      preparedBy: read(documentControlProvider).preparedBy,
      checkedBy: read(documentControlProvider).checkedBy,
      approvedBy: read(documentControlProvider).approvedBy,
      revisions: read(documentControlProvider).revisions,
      // Acknowledged advisories + their I4 audit metadata (H1 + I4) round-trip
      // with the project.
      acknowledgedIssues: read(acknowledgedIssuesProvider).values.toList(),
      // The N23 equipment model/spec overrides round-trip with the project.
      equipmentModelSpecs: read(equipmentModelSpecProvider),
    ),
    // The electrical sub-model (v2) round-trips alongside the plumbing project.
    electrical: read(electricalProjectProvider),
    // Measurement annotations round-trip with the project.
    measurements: read(measurementsProvider),
    // Designated tank areas round-trip with the project.
    tanks: read(tankAreasProvider),
    // Designated room/zone areas round-trip with the project.
    rooms: read(roomAreasProvider),
    // Traced reference lines (B12) round-trip with the project.
    referenceLines: read(referenceLinesProvider),
  );
}

/// The canonical encoding of a brand-new, untouched project — the default
/// project state (default floors, nothing drawn, empty electrical) at the CURRENT
/// app-level language + theme. Those two presentation prefs are seeded from the
/// machine-local settings at launch (A4), so an engineer who chose Bahasa/light
/// gets a virgin baseline that ALSO reads Bahasa/light — otherwise a blank launch
/// would spuriously look "dirty" (and write a phantom recovery snapshot). Keyed
/// + memoized by `<locale>/<brightness>` (≤4 tiny throwaway containers over the
/// process). The containers are deliberately not disposed — a tiny leak mirroring
/// the root container the app never disposes — so the electrical controller's
/// post-build sync microtask never reads a disposed ref.
final Map<String, String> _virginSignatures = {};
String virginDocumentSignature(ProviderReader read) {
  final locale = read(localeProvider);
  final brightness = read(brightnessProvider);
  final key = '${locale.name}/${brightness.name}';
  return _virginSignatures.putIfAbsent(key, () {
    final c = ProviderContainer();
    c.read(localeProvider.notifier).set(locale);
    c.read(brightnessProvider.notifier).set(brightness);
    return buildDocument(c.read).encode();
  });
}

/// Whether the live work reachable via [read] genuinely differs from the last
/// clean Save — the GUARD-time dirty check (computed FRESH, unlike the timer-fed
/// [projectDirtyProvider] UI hint). A project that was saved/opened is dirty when
/// it no longer matches that baseline; a never-saved project is dirty only once
/// it diverges from the untouched virgin default (so a blank launch — at the
/// user's chosen language/theme — is NOT dirty and is never destroyed silently).
bool isProjectDirty(ProviderReader read) {
  final encoded = buildDocument(read).encode();
  final saved = read(lastSavedSignatureProvider);
  return saved != null
      ? encoded != saved
      : encoded != virginDocumentSignature(read);
}

/// Load [doc] into every live store/provider reachable via [read] — the drawn
/// project AND the non-network design settings (occupancy, feed, ducts,
/// rainfall, fire hazard, theme). Used by both Open and crash-recovery restore.
void applyDocument(ProviderReader read, ProjectDocument doc) {
  read(projectControllerProvider.notifier).load(
        name: doc.projectName,
        floors: doc.floors,
        calibrations: doc.calibrations,
        staleCalibrations: doc.staleCalibrations,
        groundIndex: doc.groundIndex,
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
  // Restore the G1 solved-duty MEP feed opt-in (absent on an older file ⇒ off).
  read(mepDutyFeedEnabledProvider.notifier).set(s.mepDutyFeedEnabled);
  read(ductSettingsProvider.notifier)
    ..setShape(s.ductShape)
    ..setMethod(s.ductMethod);
  read(rainfallIntensityProvider.notifier).set(s.rainfallMmPerHr);
  read(runoffCoefficientProvider.notifier).set(s.runoffCoefficientStorm);
  // The four M13/M14/M15 design inputs (absent on an older file ⇒ the document
  // decoder's engine-matching defaults, so an old project restores unchanged).
  read(drainageSlopeProvider.notifier).set(s.drainageSlope);
  read(hotWaterFlowTempProvider.notifier).set(s.hotWaterFlowTempC);
  read(hotWaterDeltaTProvider.notifier).set(s.hotWaterDeltaTK);
  read(coolingLoadMethodProvider.notifier)
      .set(CoolingLoadMethod.fromCode(s.coolingLoadMethod));
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
  // Restore saved drawing assemblies (E5; absent on an older file ⇒ empty).
  read(assembliesProvider.notifier).set(s.savedAssemblies);
  // The AI copilot provider/key/model are MACHINE-LOCAL now (B8) — never reset
  // them to a document's values. A LEGACY `.mechx` that carried the key in-file
  // is migrated ONLY into an EMPTY machine-local slot: opening a colleague's
  // file must never overwrite (or import) the user's own key — that would both
  // lose the user's key and pull a foreign secret onto their machine.
  if (s.anthropicApiKey.isNotEmpty && read(aiApiKeyProvider).isEmpty) {
    read(aiApiKeyProvider.notifier).set(s.anthropicApiKey);
  }
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
  // Restore acknowledged advisories + their I4 audit metadata (H1 + I4; absent
  // on an older file ⇒ empty ⇒ compliance behaves exactly as before). A pre-I4
  // file's bare keys rehydrate with blank author/note/date.
  read(acknowledgedIssuesProvider.notifier)
      .set({for (final a in s.acknowledgedIssues) a.key: a});
  // Restore the N23 equipment model/spec overrides (absent on an older file ⇒
  // empty ⇒ every row prints the engine's own '—' placeholder).
  read(equipmentModelSpecProvider.notifier).set(s.equipmentModelSpecs);
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
  // Restore traced reference lines (B12; absent on an older file ⇒ empty).
  read(referenceLinesProvider.notifier).set(doc.referenceLines);
  // Drop the underlay snap caches (vector/ink/reference indices) — they are keyed
  // by sheet id / source path / reference-line ids, all of which restart
  // deterministically per project, so a new project must not inherit the previous
  // one's snap geometry for a colliding id/path.
  read(underlaySnapServiceProvider).invalidateAll();
  // Clear any stale room/tank selection so a deterministic reused id (r0/t0)
  // from the previous project doesn't surface as a phantom selection in the new
  // one (mirrors clearing the network selection on load).
  read(selectedAnnotationProvider.notifier).clear();
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
  // The recovery snapshot path. When null (production), a PER-PROJECT slot is
  // computed each tick from the live project path ([recoverySlotFor]) so every
  // project has its own snapshot instead of clobbering one global file; tests
  // inject a unique fixed temp path so concurrently-running isolates don't race.
  String? recoveryPath,
}) {
  // A `Timer.periodic` callback can't `await`, and the encode below now does —
  // guard against a slow tick still being in flight when the next one fires (two
  // overlapping ticks would race each other over the shared mirror/recovery
  // state), by skipping a tick rather than starting a second one on top of it.
  var tickInFlight = false;
  return Timer.periodic(interval, (_) {
    if (tickInFlight) return;
    tickInFlight = true;
    _autosaveTick(c, recoveryPath).whenComplete(() => tickInFlight = false);
  });
}

/// Above this many network elements the tick's JSON encode moves off-thread.
/// Below it the encode is sub-millisecond, and a synchronous encode keeps the
/// tick's timing deterministic (an [Isolate.run] spawn costs more than the
/// encode it offloads for small docs, and made recovery-write latency flaky
/// under test/suite load).
const int kAutosaveOffloadThreshold = 400;

/// One autosave tick's body, factored out so it can `await` (the
/// `Timer.periodic` callback itself cannot). [buildDocument] must stay on the UI
/// isolate — it reads live Riverpod state, which isn't isolate-transferable —
/// but the resulting [ProjectDocument] is a plain, already-built data graph, so
/// for a LARGE project the tick's actual CPU cost (the indented JSON stringify
/// over the whole project: floors, sheets, the full Network, the electrical
/// sub-model, settings) is offloaded to an [Isolate.run], the same pattern
/// [gatherSheetAssetsAsync] uses for the Save path's asset embedding — so the
/// periodic dirty-check no longer competes with drag/pan/solve for the UI
/// thread's frame budget. Small projects (under [kAutosaveOffloadThreshold]
/// elements) encode synchronously: the isolate spawn would cost more than the
/// encode, and the deterministic timing keeps the recovery-write invariants
/// (and their tests) exact.
Future<void> _autosaveTick(ProviderContainer c, String? recoveryPath) async {
  try {
    final doc = buildDocument(c.read);
    final complexity = doc.network.nodes.length +
        doc.network.edges.length +
        doc.sheets.length;
    // Capture the comparands BEFORE the off-thread encode: a Save / Open /
    // File-New can land while the encode is in flight, and comparing this
    // tick's pre-await snapshot against a post-await baseline would write a
    // phantom recovery slot for already-superseded work (the TOCTOU the
    // synchronous encode could never hit).
    final saved = c.read(lastSavedSignatureProvider);
    final pathBefore = c.read(currentProjectPathProvider);
    final encoded = complexity > kAutosaveOffloadThreshold
        ? await Isolate.run(doc.encode)
        : doc.encode();
    // If the clean baseline or the project identity moved while the encode
    // was off-thread, this tick's snapshot is stale — skip; the next tick
    // (15 s) reads the settled state.
    if (c.read(lastSavedSignatureProvider) != saved ||
        c.read(currentProjectPathProvider) != pathBefore) {
      return;
    }
    // Clean when it matches the last real Save, or (never saved yet) still equals
    // the untouched virgin default — either way there is nothing worth recovering.
    final clean = saved != null
        ? encoded == saved
        : encoded == virginDocumentSignature(c.read);
    // Piggy-back the "edited" indicator on the signature comparison we're
    // already doing (Save/Open clear it eagerly; this catches new edits).
    c.read(projectDirtyProvider.notifier).set(!clean);
    // Skip when the work already matches the clean baseline (no phantom
    // recovery), or when we've already mirrored this exact content. The mirror
    // lives in [autosaveMirrorProvider] (not a closure) so Save/Open reset it.
    if (clean || encoded == c.read(autosaveMirrorProvider)) {
      return;
    }
    c.read(autosaveMirrorProvider.notifier).set(encoded);
    final projectPath = c.read(currentProjectPathProvider);
    // R4: AWAIT the write. Un-awaited, the tick's future completed the instant
    // the write was scheduled, so `tickInFlight` cleared while the file IO was
    // still running — two slow ticks could then race the SAME `.tmp` / `.bak`
    // siblings the atomic write uses, and any exception escaped as an unhandled
    // async error instead of the guarded path below. Awaiting makes the
    // documented overlap guard actually cover the write.
    await writeRecovery(
      doc,
      path: recoveryPath ?? recoverySlotFor(projectPath),
      // Stash the source file so a Restore can re-link the file identity.
      sourcePath: projectPath,
    );
  } on StateError {
    // The container was torn down (app quit / test teardown) while this tick's
    // off-thread encode was still in flight — nothing left to update.
  }
}
