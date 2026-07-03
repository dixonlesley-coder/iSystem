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
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart' show ServiceType;

import '../ui/canvas/viewport.dart';

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

  /// The persisted Auto-view viewport (F2 zoom/pan). Null ⇒ the identity base
  /// (the fit-to-viewport render, byte-identical to before F2).
  final ViewportTransform? autoTransform;

  /// The persisted Edit-view viewport (F7). Null ⇒ fit-to-content on first
  /// layout (the prior behaviour).
  final ViewportTransform? editTransform;

  const SchematicViewState({
    this.mode = SchematicMode.auto,
    this.service = ServiceType.coldWater,
    this.autoFocus,
    this.inferRisers = false,
    this.showLegend = false,
    this.showTitleBlock = false,
    this.showDetails = true,
    this.showNotes = true,
    this.showHelp = false,
    this.autoTransform,
    this.editTransform,
  });

  SchematicViewState copyWith({
    SchematicMode? mode,
    ServiceType? service,
    ServiceType? autoFocus,
    bool clearAutoFocus = false,
    bool? inferRisers,
    bool? showLegend,
    bool? showTitleBlock,
    bool? showDetails,
    bool? showNotes,
    bool? showHelp,
    ViewportTransform? autoTransform,
    ViewportTransform? editTransform,
  }) =>
      SchematicViewState(
        mode: mode ?? this.mode,
        service: service ?? this.service,
        autoFocus: clearAutoFocus ? null : (autoFocus ?? this.autoFocus),
        inferRisers: inferRisers ?? this.inferRisers,
        showLegend: showLegend ?? this.showLegend,
        showTitleBlock: showTitleBlock ?? this.showTitleBlock,
        showDetails: showDetails ?? this.showDetails,
        showNotes: showNotes ?? this.showNotes,
        showHelp: showHelp ?? this.showHelp,
        autoTransform: autoTransform ?? this.autoTransform,
        editTransform: editTransform ?? this.editTransform,
      );
}

class SchematicViewController extends Notifier<SchematicViewState> {
  @override
  SchematicViewState build() => const SchematicViewState();

  void setMode(SchematicMode m) {
    if (state.mode != m) state = state.copyWith(mode: m);
  }

  void setService(ServiceType s) => state = state.copyWith(service: s);

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

  void setAutoTransform(ViewportTransform t) =>
      state = state.copyWith(autoTransform: t);
  void setEditTransform(ViewportTransform t) =>
      state = state.copyWith(editTransform: t);
}

/// Transient (session-only, never `.mechx`-persisted) Riser-workspace UI state.
final schematicViewProvider =
    NotifierProvider<SchematicViewController, SchematicViewState>(
  SchematicViewController.new,
);
