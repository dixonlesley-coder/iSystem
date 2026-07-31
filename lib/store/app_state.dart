import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/hot_water.dart' show kHotWaterFlowTempC;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart'
    show kDefaultRunoffCoefficient;
import 'package:mechx_engine/standards/sni.dart';

import '../ai/ai_client.dart';
import '../ui/strings/app_strings.dart';
import 'sizing_store.dart';

/// HVAC duct preferences (shape + sizing method) driving the air code path.
@immutable
class DuctSettings {
  final DuctShape shape;
  final DuctSizingMethod method;
  const DuctSettings({
    this.shape = DuctShape.round,
    this.method = DuctSizingMethod.velocity,
  });

  DuctSettings copyWith({DuctShape? shape, DuctSizingMethod? method}) =>
      DuctSettings(shape: shape ?? this.shape, method: method ?? this.method);
}

final ductSettingsProvider =
    NotifierProvider<DuctSettingsController, DuctSettings>(
  DuctSettingsController.new,
);

class DuctSettingsController extends Notifier<DuctSettings> {
  @override
  DuctSettings build() => const DuctSettings();

  void setShape(DuctShape s) => state = state.copyWith(shape: s);
  void setMethod(DuctSizingMethod m) => state = state.copyWith(method: m);
}

/// How the building is fed (drives the supply solve): an upfeed pump pushing
/// water up from a low plant, or a roof tank distributing by gravity downward.
enum FeedStrategy { upfeed, downfeed }

/// Active feed strategy. Defaults to roof-tank downfeed (the project's chosen
/// strategy); switch to upfeed for pumped ground/basement supply.
final feedStrategyProvider =
    NotifierProvider<FeedStrategyController, FeedStrategy>(
  FeedStrategyController.new,
);

class FeedStrategyController extends Notifier<FeedStrategy> {
  @override
  FeedStrategy build() => FeedStrategy.downfeed;

  void set(FeedStrategy s) => state = s;
}

/// Building occupancy class (private dwelling / public / assembly) — selects the
/// SNI fixture-unit loads used to size the water supply.
final occupancyProvider =
    NotifierProvider<OccupancyController, Occupancy>(OccupancyController.new);

class OccupancyController extends Notifier<Occupancy> {
  @override
  Occupancy build() => Occupancy.private;

  void set(Occupancy o) => state = o;
}

/// Default service to use as the supply (for source auto-pick / solve).
const ServiceType kSupplyService = ServiceType.coldWater;

/// Design rainfall intensity (mm/hr) driving storm/rainwater sizing.
final rainfallIntensityProvider =
    NotifierProvider<RainfallController, double>(RainfallController.new);

class RainfallController extends Notifier<double> {
  @override
  double build() => 200.0; // VERIFY against the local design storm

  void set(double v) => state = v.clamp(50.0, 600.0).toDouble();
  void nudge(double delta) => set(state + delta);
}

/// Design storm runoff coefficient C (dimensionless, 0–1) — the fraction of
/// design rainfall that becomes runoff at the outlet (rational method). Pairs
/// with [rainfallIntensityProvider]; both feed `rainwaterDesignFlow`. Defaults to
/// the impervious-roof figure (`kDefaultRunoffCoefficient`). // VERIFY vs SNI.
final runoffCoefficientProvider =
    NotifierProvider<RunoffCoefficientController, double>(
  RunoffCoefficientController.new,
);

class RunoffCoefficientController extends Notifier<double> {
  @override
  double build() => kDefaultRunoffCoefficient; // VERIFY — surface/region C

  void set(double v) => state = v.clamp(0.5, 1.0).toDouble();
  void nudge(double delta) => set(state + delta);
}

/// M13 — the LAID drainage design slope (m/m) for horizontal gravity branches.
///
/// Until now every call site passed the `SizingContext` default (0.01) as a
/// const, so the engine's own min-slope advisory (`drainage_advisory.dart`,
/// threshold 0.005) could never fire and the slope was a DARK constant the
/// engineer could not see or change. It is a genuine design input (a 1:100 fall
/// is a choice, not a law), so it lives here and feeds BOTH the sizer
/// (`SizingContext.drainageSlope` → the Manning full-bore velocity that decides
/// the self-cleansing verdict) and the advisory layer.
///
/// Clamped to a physically sane band (1:1000 … 1:10). Default 0.01 (1:100) ⇒
/// every existing project sizes byte-identically.
final drainageSlopeProvider =
    NotifierProvider<DrainageSlopeController, double>(
  DrainageSlopeController.new,
);

class DrainageSlopeController extends Notifier<double> {
  @override
  double build() => const SizingContext().drainageSlope; // 0.01 = 1:100

  void set(double v) => state = v.clamp(0.001, 0.1).toDouble();

  /// Nudge in 1:N space so the steps read as drafting fractions (1:100 → 1:90).
  void nudge(double delta) => set(state + delta);
}

/// M14 — hot-water FLOW (supply) temperature leaving the heater (°C) and the
/// allowable loop temperature DROP ΔT (K). Both were engine defaults nobody
/// could change (60 − 5 = 55 exactly ⇒ `returnTempC < 55` was never true), so
/// the anti-Legionella check was dark. They are design inputs: a project that
/// stores at 55 °C, or accepts a 10 K drop, genuinely risks a cold return.
/// Defaults mirror the engine (60 °C / 5 K) ⇒ byte-identical.
final hotWaterFlowTempProvider =
    NotifierProvider<HotWaterFlowTempController, double>(
  HotWaterFlowTempController.new,
);

class HotWaterFlowTempController extends Notifier<double> {
  @override
  double build() => kHotWaterFlowTempC; // 60 °C

  void set(double v) => state = v.clamp(40.0, 90.0).toDouble();
  void nudge(double delta) => set(state + delta);
}

/// Allowable hot-water recirculation loop temperature drop ΔT (K). Drives the
/// recirc flow (Q = heatLoss / (ρ·c·ΔT)) AND the modelled return temperature.
final hotWaterDeltaTProvider =
    NotifierProvider<HotWaterDeltaTController, double>(
  HotWaterDeltaTController.new,
);

class HotWaterDeltaTController extends Notifier<double> {
  @override
  double build() => 5.0; // K — the engine's own default ΔT

  void set(double v) => state = v.clamp(1.0, 20.0).toDouble();
  void nudge(double delta) => set(state + delta);
}

/// M15/R6 — which cooling-load basis the Rooms AC estimate uses: the
/// area-density rule (`sizing/cooling_load.dart`, the default) or the heat-gain
/// component breakdown (`sizing/cooling_load_detailed.dart`). The engine module
/// existed and was tested but was reachable from NOTHING in the app while
/// `DesignSettings.coolingLoadMethod` round-tripped in `.mechx` — implying a
/// capability that wasn't there. This provider is that setting made real.
enum CoolingLoadMethod {
  /// Area × per-room-type density × ceiling correction (the fallback).
  simple,

  /// Envelope + solar + internal + ventilation heat-gain streams.
  detailed;

  /// The persisted code (`'simple'` / `'detailed'`).
  String get code => name;

  /// Tolerant decode: anything unknown ⇒ [simple].
  static CoolingLoadMethod fromCode(Object? code) =>
      code == 'detailed' ? CoolingLoadMethod.detailed : CoolingLoadMethod.simple;
}

final coolingLoadMethodProvider =
    NotifierProvider<CoolingLoadMethodController, CoolingLoadMethod>(
  CoolingLoadMethodController.new,
);

class CoolingLoadMethodController extends Notifier<CoolingLoadMethod> {
  @override
  CoolingLoadMethod build() => CoolingLoadMethod.simple;

  void set(CoolingLoadMethod m) => state = m;
}

/// BYO Anthropic API key for the in-app Claude copilot. Empty ⇒ the copilot is
/// disabled (offline-graceful). Round-trips via `DesignSettings.anthropicApiKey`.
final aiApiKeyProvider =
    NotifierProvider<AiApiKeyController, String>(AiApiKeyController.new);

class AiApiKeyController extends Notifier<String> {
  @override
  String build() => '';

  void set(String v) => state = v.trim();
}

/// Which LLM backend the copilot uses — Anthropic (primary) or OpenAI (backup).
/// Round-trips via `DesignSettings.aiProvider`.
final aiProviderProvider =
    NotifierProvider<AiProviderController, AiProviderKind>(
        AiProviderController.new);

class AiProviderController extends Notifier<AiProviderKind> {
  @override
  AiProviderKind build() => AiProviderKind.anthropic;

  void set(AiProviderKind v) => state = v;
}

/// Model id the copilot calls (default `claude-sonnet-4-6`). Round-trips via
/// `DesignSettings.aiModel`. Empty falls back to the Anthropic default; switch
/// the provider in Preferences to re-seed it with that provider's default.
final aiModelProvider =
    NotifierProvider<AiModelController, String>(AiModelController.new);

class AiModelController extends Notifier<String> {
  @override
  String build() => kDefaultAnthropicModel;

  void set(String v) => state = v.trim().isEmpty ? kDefaultAnthropicModel : v.trim();
}

/// A transient, user-facing error message (e.g. a failed project open). Null
/// when there is nothing to show; the shell renders it as a dismissible banner.
final loadErrorProvider =
    NotifierProvider<LoadErrorController, String?>(LoadErrorController.new);

class LoadErrorController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? message) => state = message;
  void clear() => state = null;
}

/// A transient, positive status confirmation (e.g. "Saved project.mechx",
/// "Project opened"). Null at rest — so the status bar slot is empty and the
/// goldens are unchanged. Set via [StatusMessageController.showStatus], which
/// also schedules a self-clear after a few seconds; calling it again restarts
/// the timer so the latest message always shows for its full window.
final statusMessageProvider =
    NotifierProvider<StatusMessageController, String?>(
  StatusMessageController.new,
);

class StatusMessageController extends Notifier<String?> {
  Timer? _timer;

  @override
  String? build() {
    // Cancel any pending clear when the provider is disposed/rebuilt.
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  /// How long a confirmation lingers before it fades out on its own.
  static const Duration _window = Duration(seconds: 3);

  /// Show [message] and schedule it to clear after [_window]. A fresh call
  /// supersedes any in-flight clear (the newest message wins its full window).
  void showStatus(String message) {
    _timer?.cancel();
    state = message;
    _timer = Timer(_window, () {
      // Only clear if this is still the message we set (a newer call would have
      // restarted the timer, so this guard is belt-and-braces).
      state = null;
    });
  }

  void clear() {
    _timer?.cancel();
    state = null;
  }
}

/// One-shot session nudge for the FIRST auto-size: the moment the live sizing
/// solve (`sizingProvider`) transitions from empty to non-empty, a listener
/// (hosted in `AppShell`, see `app_shell.dart`) calls [maybeFire] with the
/// count of newly-sized edges. Guarded so it fires at most ONCE per session —
/// subsequent re-solves (editing a run, reopening a project that already has a
/// sized network) never re-nudge. False at rest; no persistence, so a fresh
/// session always gets the nudge again.
final firstAutoSizeNudgeProvider =
    NotifierProvider<FirstAutoSizeNudgeController, bool>(
  FirstAutoSizeNudgeController.new,
);

class FirstAutoSizeNudgeController extends Notifier<bool> {
  @override
  bool build() => false; // true once the nudge has fired this session

  /// Show the "Auto-sized N runs" confirmation for [count] edges, unless the
  /// nudge has already fired this session or there is nothing to report.
  void maybeFire(int count) {
    if (state || count <= 0) return;
    state = true;
    // F2 — the toast said "sizes shown on the plan" while `showSizingProvider`
    // defaulted false and nothing ever set it: the first solve's ONLY feedback
    // named something the engineer could not see. Turning the overlay on as
    // part of the one-shot makes the sentence true at the moment it is read.
    // A project that never sizes never reaches here (the guard above), so a
    // blank launch is unchanged, and the inspector toggle can still switch the
    // labels back off.
    ref.read(showSizingProvider.notifier).show();
    ref.read(statusMessageProvider.notifier).showStatus(
          MechXStringsData(ref.read(localeProvider))
              .format(StringKey.autoSizedRuns, {'count': '$count'}),
        );
  }
}

/// A transient "busy" message for a slow foreground operation (importing a
/// plan, converting a DWG, opening/saving a project). Null at rest — so the
/// status bar shows no busy pill and the goldens are unchanged. Set/cleared in
/// a try/finally around the slow path; the pill mounts only while non-null.
final busyProvider =
    NotifierProvider<BusyController, String?>(BusyController.new);

class BusyController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? message) => state = message;
  void clear() => state = null;
}

/// The file the open project lives in — set on a successful Open or Save, so
/// Ctrl/Cmd+S saves IN PLACE instead of re-opening the OS dialog every time.
/// Null until the project has a home (a brand-new project Save-As's first).
/// Machine-local session state — deliberately NOT persisted into `.mechx`.
final currentProjectPathProvider =
    NotifierProvider<CurrentProjectPathController, String?>(
  CurrentProjectPathController.new,
);

class CurrentProjectPathController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? path) => state = path;
}

/// Whether the live work differs from the last clean Save — drives the small
/// "edited" dot beside the project name. Maintained by the autosave loop's
/// existing signature comparison (no per-frame encode) and cleared eagerly on
/// Save/Open. False at rest ⇒ the goldens (no autosave timer in tests) are
/// unchanged.
final projectDirtyProvider =
    NotifierProvider<ProjectDirtyController, bool>(ProjectDirtyController.new);

class ProjectDirtyController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool dirty) => state = dirty;
}

/// App-wide light/dark brightness. Defaults to dark (the restrained, low-glare
/// default for a drawing tool). Persisted to the project file later.
final brightnessProvider = NotifierProvider<BrightnessController, Brightness>(
  BrightnessController.new,
);

class BrightnessController extends Notifier<Brightness> {
  @override
  Brightness build() => Brightness.dark;

  void toggle() => state =
      state == Brightness.dark ? Brightness.light : Brightness.dark;

  void set(Brightness brightness) => state = brightness;
}

/// The app's UI language. `en` = English (the default), `id` = Bahasa Indonesia.
/// Persisted to the project file via `DesignSettings.locale`.
enum AppLocale { en, id }

extension AppLocaleLabel on AppLocale {
  /// The human-readable name of this locale, shown in the language toggle.
  String get displayName => switch (this) {
        AppLocale.en => 'English',
        AppLocale.id => 'Bahasa Indonesia',
      };
}

/// App-wide UI language. Defaults to English so the default rendered text (and
/// the golden screenshots) is unchanged. Persisted to the project file later.
/// Mirrors [brightnessProvider]'s shape exactly.
final localeProvider =
    NotifierProvider<LocaleController, AppLocale>(LocaleController.new);

class LocaleController extends Notifier<AppLocale> {
  @override
  AppLocale build() => AppLocale.en;

  void set(AppLocale locale) => state = locale;
}

/// Whether the main area shows the generated schematic diagram instead of the
/// plan canvas.
final showSchematicProvider =
    NotifierProvider<ShowSchematicController, bool>(ShowSchematicController.new);

class ShowSchematicController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}
