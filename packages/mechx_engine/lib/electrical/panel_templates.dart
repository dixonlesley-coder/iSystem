/// Sub-panel presets — convenience DATA for auto-populating a newly dropped
/// sub-panel with a typical starter circuit list, so an engineer doesn't have
/// to add every lighting/socket/HVAC way one at a time.
///
/// A template is just a canned sequence of [PanelTemplateCircuit]s (name / load
/// kind / watts) plus a [HeadroomSpec], meant to be REPLAYED through the
/// existing `addCircuit` flow one circuit at a time — it is a UI convenience,
/// not a new compute path or a standards table. The names/wattages are
/// representative typical-board figures (an engineer's placeholder starting
/// point, edited to match the real design), so — like [HeadroomSpec] itself —
/// there is nothing here to `// VERIFY`: it is not a PUIL/SNI clause, just a
/// preset the engineer overwrites.
///
/// Zero Flutter imports.
library;

import 'headroom.dart' show HeadroomSpec;
import 'load_kind.dart' show LoadKind;

/// One canned circuit in a [ElectricalPanelTemplate] — enough to replay through
/// `addCircuit` (kind + name + watts), plus the two optional attributes a
/// preset circuit commonly needs (a hand-entered motor kW, an explicit phase
/// count).
class PanelTemplateCircuit {
  /// The circuit's load kind (drives cosφ/demand-factor/curve defaults).
  final LoadKind kind;

  /// Display name for the added circuit.
  final String name;

  /// Connected load in watts.
  final double loadW;

  /// Optional hand-entered motor rating (kW), for motor-like loads.
  final double? motorKw;

  /// Optional explicit phase count (1 or 3). Null ⇒ the panel/kind default.
  final int? phases;

  const PanelTemplateCircuit({
    required this.kind,
    required this.name,
    required this.loadW,
    this.motorKw,
    this.phases,
  });
}

/// A named preset for a sub-panel — a typical circuit list + a suggested
/// [HeadroomSpec] (spare % / spare ways) to apply to the panel itself.
class ElectricalPanelTemplate {
  /// Stable id (`'lighting'` / `'power'` / `'mixed'`).
  final String id;

  /// Human label for a picker UI.
  final String label;

  /// The canned circuits to replay through `addCircuit`, in order.
  final List<PanelTemplateCircuit> circuits;

  /// Suggested headroom for the panel this template is applied to. Null ⇒ no
  /// headroom suggestion.
  final HeadroomSpec? headroom;

  const ElectricalPanelTemplate({
    required this.id,
    required this.label,
    required this.circuits,
    this.headroom,
  });
}

/// Shared suggested headroom for every built-in template: 20 % future-load
/// allowance + 2 reserved spare ways — a typical starter-board allowance, not
/// a standards figure (see `headroom.dart`).
const HeadroomSpec _defaultTemplateHeadroom =
    HeadroomSpec(sparePercentage: 20, spareWays: 2);

/// A typical lighting-only sub-panel: four lighting zones + one utility
/// socket circuit for maintenance/cleaning power.
const ElectricalPanelTemplate _lightingTemplate = ElectricalPanelTemplate(
  id: 'lighting',
  label: 'Lighting panel',
  circuits: [
    PanelTemplateCircuit(
        kind: LoadKind.lighting, name: 'Lighting — zone 1', loadW: 1200),
    PanelTemplateCircuit(
        kind: LoadKind.lighting, name: 'Lighting — zone 2', loadW: 1200),
    PanelTemplateCircuit(
        kind: LoadKind.lighting, name: 'Lighting — zone 3', loadW: 1200),
    PanelTemplateCircuit(
        kind: LoadKind.lighting, name: 'Lighting — zone 4', loadW: 1200),
    PanelTemplateCircuit(
        kind: LoadKind.socket, name: 'Sockets — utility', loadW: 2000),
  ],
  headroom: _defaultTemplateHeadroom,
);

/// A typical power (socket) sub-panel: four socket zones + one single-phase
/// air-con way.
const ElectricalPanelTemplate _powerTemplate = ElectricalPanelTemplate(
  id: 'power',
  label: 'Power panel',
  circuits: [
    PanelTemplateCircuit(
        kind: LoadKind.socket, name: 'Sockets — zone 1', loadW: 2000),
    PanelTemplateCircuit(
        kind: LoadKind.socket, name: 'Sockets — zone 2', loadW: 2000),
    PanelTemplateCircuit(
        kind: LoadKind.socket, name: 'Sockets — zone 3', loadW: 2000),
    PanelTemplateCircuit(
        kind: LoadKind.socket, name: 'Sockets — zone 4', loadW: 2000),
    PanelTemplateCircuit(
        kind: LoadKind.hvac, name: 'Air-con', loadW: 2500, phases: 1),
  ],
  headroom: _defaultTemplateHeadroom,
);

/// A typical mixed lighting + power sub-panel: two lighting zones, two socket
/// zones, and one single-phase air-con way.
const ElectricalPanelTemplate _mixedTemplate = ElectricalPanelTemplate(
  id: 'mixed',
  label: 'Mixed panel',
  circuits: [
    PanelTemplateCircuit(
        kind: LoadKind.lighting, name: 'Lighting — zone 1', loadW: 1200),
    PanelTemplateCircuit(
        kind: LoadKind.lighting, name: 'Lighting — zone 2', loadW: 1200),
    PanelTemplateCircuit(
        kind: LoadKind.socket, name: 'Sockets — zone 1', loadW: 2000),
    PanelTemplateCircuit(
        kind: LoadKind.socket, name: 'Sockets — zone 2', loadW: 2000),
    PanelTemplateCircuit(
        kind: LoadKind.hvac, name: 'Air-con', loadW: 2500, phases: 1),
  ],
  headroom: _defaultTemplateHeadroom,
);

/// The built-in sub-panel templates, in picker display order.
const List<ElectricalPanelTemplate> kPanelTemplates = [
  _lightingTemplate,
  _powerTemplate,
  _mixedTemplate,
];

/// Look up a built-in template by [id]. Returns null for an unknown id (never
/// throws) so a stale/typo'd id degrades to "no template" rather than a crash.
ElectricalPanelTemplate? panelTemplateById(String id) {
  for (final t in kPanelTemplates) {
    if (t.id == id) return t;
  }
  return null;
}
