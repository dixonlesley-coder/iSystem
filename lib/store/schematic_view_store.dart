/// Transient UI state for the Riser (Schematic) workspace — F7 "sticky view
/// state". The Auto/Edit mode, the system filter, the five view toggles, the
/// Edit-mode help flag AND both canvas viewports were widget-local state in
/// `SchematicView`, destroyed every time the user hopped to another workspace
/// (Layout / Electrical) and back — punishing the core hop-fix-hop-back loop.
///
/// Lifted here into ONE transient provider (mirroring the `sectionVisibilityProvider`
/// precedent): it survives a workspace swap but is deliberately NOT persisted to
/// the `.mechx` file — a fresh session restarts from these defaults, so the
/// golden screenshots (which never persist this) are unchanged. The defaults are
/// byte-for-byte the widget's old initial values.
///
/// Riser drafting-feel (R1) — the two canvas VIEWPORTS live in their OWN
/// providers ([schematicAutoViewportProvider] / [schematicEditViewportProvider]),
/// not in [SchematicViewState]: a pan / zoom writes the viewport every frame,
/// and when it lived here every watcher of the whole view state (the Riser
/// workspace shell, its toolbar, the inspector's system summary) rebuilt per
/// frame. Mirrors the Layout's `sheetViewportProvider` split.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart' show ServiceType;
import 'package:mechx_engine/report/riser_tags.dart' show riserTags;

import '../ui/canvas/viewport.dart';
import 'layer_store.dart' show DisciplineLayer, disciplineOf, servicesFor;
import 'network_store.dart' show networkControllerProvider;

/// Which mode the elevation surface is in — the read-only generated riser
/// diagram (Auto) or the editable placement/sizing surface (Edit).
enum SchematicMode { auto, edit }

/// The full sticky UI state of the Riser workspace. Immutable value; the
/// controller replaces it wholesale via [copyWith].
@immutable
class SchematicViewState {
  /// Auto vs Edit mode.
  final SchematicMode mode;

  /// The service a dropped riser carries in Edit mode.
  final ServiceType service;

  /// The discipline whose services the Edit-mode service picker lists
  /// (Plumbing / Fire / HVAC). Null until the user picks one ⇒ it follows the
  /// discipline of [service] (see [effectiveEditDiscipline]).
  final DisciplineLayer? editDiscipline;

  /// Auto-view system filter: null = the COMBINED single-line; a service = that
  /// system only.
  final ServiceType? autoFocus;

  /// Auto-view toggles (defaults match the widget's original initial values, so
  /// a default launch is byte-identical).
  final bool inferRisers;
  final bool showLegend;
  final bool showTitleBlock;
  final bool showDetails;
  final bool showNotes;

  /// Edit-mode help popover open flag.
  final bool showHelp;

  const SchematicViewState({
    this.mode = SchematicMode.auto,
    this.service = ServiceType.coldWater,
    this.editDiscipline,
    this.autoFocus,
    this.inferRisers = false,
    this.showLegend = false,
    this.showTitleBlock = false,
    this.showDetails = true,
    this.showNotes = true,
    this.showHelp = false,
  });

  /// The Edit-mode discipline actually shown — the picked one, else the
  /// discipline the current riser [service] belongs to.
  DisciplineLayer get effectiveEditDiscipline =>
      editDiscipline ?? disciplineOf(service);

  SchematicViewState copyWith({
    SchematicMode? mode,
    ServiceType? service,
    DisciplineLayer? editDiscipline,
    ServiceType? autoFocus,
    bool clearAutoFocus = false,
    bool? inferRisers,
    bool? showLegend,
    bool? showTitleBlock,
    bool? showDetails,
    bool? showNotes,
    bool? showHelp,
  }) =>
      SchematicViewState(
        mode: mode ?? this.mode,
        service: service ?? this.service,
        editDiscipline: editDiscipline ?? this.editDiscipline,
        autoFocus: clearAutoFocus ? null : (autoFocus ?? this.autoFocus),
        inferRisers: inferRisers ?? this.inferRisers,
        showLegend: showLegend ?? this.showLegend,
        showTitleBlock: showTitleBlock ?? this.showTitleBlock,
        showDetails: showDetails ?? this.showDetails,
        showNotes: showNotes ?? this.showNotes,
        showHelp: showHelp ?? this.showHelp,
      );
}

class SchematicViewController extends Notifier<SchematicViewState> {
  @override
  SchematicViewState build() => const SchematicViewState();

  void setMode(SchematicMode m) {
    if (state.mode != m) state = state.copyWith(mode: m);
  }

  /// Set the Edit-mode riser service. A service outside the shown discipline
  /// (e.g. picked from elsewhere) moves the discipline picker with it, so the
  /// selected chip is always visible.
  void setService(ServiceType s) => state = state.copyWith(
        service: s,
        editDiscipline: disciplineOf(s),
      );

  /// Pick the Edit-mode discipline (Plumbing / Fire / HVAC). When the current
  /// service isn't one of its services, that discipline's FIRST service is
  /// selected, so the picker never shows a hidden selection.
  void setEditDiscipline(DisciplineLayer d) {
    final services = servicesFor(d);
    if (services.isEmpty) return; // electrical has no riser services
    state = state.copyWith(
      editDiscipline: d,
      service: services.contains(state.service) ? null : services.first,
    );
  }

  /// Set the Auto system filter — pass null for the combined "All" view.
  void setAutoFocus(ServiceType? s) => state =
      s == null ? state.copyWith(clearAutoFocus: true) : state.copyWith(autoFocus: s);

  void setInferRisers(bool v) => state = state.copyWith(inferRisers: v);
  void setShowLegend(bool v) => state = state.copyWith(showLegend: v);
  void setShowTitleBlock(bool v) => state = state.copyWith(showTitleBlock: v);
  void setShowDetails(bool v) => state = state.copyWith(showDetails: v);
  void setShowNotes(bool v) => state = state.copyWith(showNotes: v);
  void setShowHelp(bool v) => state = state.copyWith(showHelp: v);
  void toggleHelp() => setShowHelp(!state.showHelp);
}

/// Transient (session-only, never `.mechx`-persisted) Riser-workspace UI state.
final schematicViewProvider =
    NotifierProvider<SchematicViewController, SchematicViewState>(
  SchematicViewController.new,
);

/// One Riser canvas's sticky viewport (F2/F7). Null ⇒ the canvas frames its
/// content on first layout (the Auto diagram's fit is the identity whenever the
/// building fits the window, so a default launch is byte-identical).
class SchematicViewportController extends Notifier<ViewportTransform?> {
  @override
  ViewportTransform? build() => null;

  /// Publish [t]. A no-op (no notification) when it equals the current view.
  void set(ViewportTransform t) {
    if (state != t) state = t;
  }
}

/// The Riser → Auto diagram's live pan / zoom. Written every pan / zoom frame,
/// so ONLY the transform widget and the viewport-dependent hit tests read it —
/// never the workspace shell (R1).
final schematicAutoViewportProvider =
    NotifierProvider<SchematicViewportController, ViewportTransform?>(
  SchematicViewportController.new,
);

/// The Riser → Edit elevation's live pan / zoom (see
/// [schematicAutoViewportProvider]).
final schematicEditViewportProvider =
    NotifierProvider<SchematicViewportController, ViewportTransform?>(
  SchematicViewportController.new,
);

/// R1 — the riser stack tags (`CW-R1` …) for one diagram [focus] (null = the
/// combined view), memoized per NETWORK: [riserTags] builds a fresh map each
/// call, and the Auto painter's repaint check compares it by identity, so
/// calling it in a build made every rebuild a full re-layout + repaint. The
/// painter and the inspector's system summary read this one value.
final riserTagsProvider =
    Provider.family<Map<String, String>, ServiceType?>((ref, focus) {
  final network =
      ref.watch(networkControllerProvider.select((s) => s.network));
  return riserTags(network, focus);
});
