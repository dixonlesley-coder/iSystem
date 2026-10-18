// The mechanical palette's PAYLOAD type and the F5 armed click-to-place
// provider. Pure store state (engine types only, no widgets) so both the
// palette UI and the data layer (`applyDocument` disarms it on load) can depend
// on it without a data→UI import.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;

/// What a palette card drops onto the canvas. The drop overlay reads [kind] to
/// pick the matching store add-action; [service] (a pipe segment) carries the
/// service so a duct vs water segment lands correctly; [component] (a
/// [PaletteItemKind.component]) carries which piece of equipment to drop.
enum PaletteItemKind { pipeSegment, ductSegment, fitting, terminal, component }

@immutable
class PaletteItem {
  final PaletteItemKind kind;

  /// For [PaletteItemKind.pipeSegment]/[PaletteItemKind.ductSegment] — the
  /// service the dropped segment carries. Null ⇒ use the active draw service.
  final ServiceType? service;

  /// For [PaletteItemKind.component] — which equipment node to drop.
  final NodeComponent? component;

  /// F5 — for [PaletteItemKind.terminal] — the PLUMBING FIXTURE the dropped
  /// terminal represents, carried into the existing `addTerminal(fixture:)` /
  /// `mergeOrAddTerminal(fixture:)` path so the node lands already typed (its
  /// real UBAP + DFU loads) instead of silently sizing on the representative
  /// 2.0-unit placeholder. Null ⇒ the generic, untyped Terminal card
  /// (unchanged behaviour).
  final PlumbingFixture? fixture;

  const PaletteItem(this.kind, {this.service, this.component, this.fixture});

  // VALUE equality (F5): the armed-placement provider compares the currently
  // armed item against each card's item to draw the armed tint; a non-const
  // component card rebuilds a fresh instance each frame, so identity equality
  // would never match.
  @override
  bool operator ==(Object other) =>
      other is PaletteItem &&
      other.kind == kind &&
      other.service == service &&
      other.component == component &&
      other.fixture == fixture;

  @override
  int get hashCode => Object.hash(kind, service, component, fixture);
}

/// F5 — the palette card ARMED for click-to-place-repeatedly. Non-null means
/// each canvas click drops another instance of this item (through the SAME
/// merge/snap add-actions a drag uses, in `drop_overlay.dart`); null is normal
/// single-drag placement. Esc / a canvas right-click / re-clicking the armed
/// card / picking another card disarms. Transient UI state — never persisted.
///
/// (Kept in its own store file beside [PaletteItem], its payload type, rather
/// than in `network_store`; the data layer's `applyDocument` disarms it on load,
/// so it must not live in the UI layer — that would invert data→UI.)
final armedPlacementProvider =
    NotifierProvider<ArmedPlacementController, PaletteItem?>(
  ArmedPlacementController.new,
);

class ArmedPlacementController extends Notifier<PaletteItem?> {
  @override
  PaletteItem? build() => null;

  /// Toggle: arming the already-armed item disarms it; a different item re-arms.
  void toggle(PaletteItem item) => state = (state == item) ? null : item;

  void disarm() => state = null;
}
