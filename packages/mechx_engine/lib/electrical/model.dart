/// Electrical input model — the pure, immutable data the A4 panel/system
/// orchestrator (`compute.dart`) consumes. Ported (CORE only) from PanelMaker's
/// `types/project.ts` (`CircuitInput` / `PanelInput` / `ProjectInput`). The
/// many fault/PF/source/occupancy/containment fields of the reference model are
/// deliberately NOT modelled here — they belong to later steps (A8 onward).
///
/// The DB / project-file layer (A6) will map onto these shapes; the engine never
/// imports DB or Flutter code. Result types are constructed ONLY by the
/// orchestrator, never from this model.
///
/// Zero Flutter imports.
library;

import '../standards/puil.dart'
    show CableInstallMethod, ConductorInsulation, ConductorMaterial;
import '../units.dart';
import 'earthing.dart' show EarthingSystem;
import 'load_kind.dart' show LoadKind;

/// A circuit's role on its panel: the incoming device, or an outgoing way.
enum CircuitRole { incomer, branch }

/// A single-phase or three-phase electrical system.
enum ElectricalSystem { singlePhase, threePhase }

extension ElectricalSystemInfo on ElectricalSystem {
  bool get isThreePhase => this == ElectricalSystem.threePhase;
  String get label =>
      this == ElectricalSystem.threePhase ? '3-phase' : '1-phase';
}

/// A user-pinned line for a single-phase circuit (excluded from auto-balancing).
enum PhaseLine { l1, l2, l3 }

/// One outgoing way (or the incomer) of a panel — the leaf input the engine
/// sizes. Mirrors PanelMaker `CircuitInput` (core fields only).
class ElectricalCircuit {
  final String id;
  final String name;
  final CircuitRole role;

  /// Connected load (W). For a feeder this is overridden by the fed panel's
  /// diversified demand at compute time.
  final double loadW;

  /// Power factor (cos φ).
  final double cosPhi;

  /// Run length (m).
  final Length length;

  final LoadKind loadKind;

  /// Lighting circuit — tighter 3 % voltage-drop limit + 1.5 mm² final minimum.
  final bool isLighting;

  /// Per-circuit demand / utilisation factor (0–1).
  final double demandFactor;

  /// Motor shaft rating (kW), when this is a motor/pump. Drives the design
  /// current via P = motorKw·1000 (the motor FLC table is an A8 refinement).
  final double? motorKw;

  /// Explicit supply phase count (1 or 3). Overrides the size-based inference;
  /// ignored on a single-phase panel (everything is 1-phase there).
  final int? phases;

  /// Life-safety circuit (fire pump, smoke fan, emergency lighting): no RCD,
  /// availability prevails. Default fire-resistant cable is an A8 concern.
  final bool lifeSafety;

  /// Explicit cable construction (NYY / NYM / NYA / NYAF / FRC …). Absent =
  /// derived from the panel. A label / BOM concern; sizing is unaffected.
  final String? cableType;

  /// Per-run laying override: `air` (above ground) or `ground` (buried). Absent
  /// = follow the panel's install method.
  final String? laying;

  /// Manual minimum cable section (mm²) — floors the auto-sized conductor.
  final double? cableOverrideMm2;

  /// Manual breaker rating override (A) — used verbatim instead of auto-sizing.
  final Current? breakerOverrideA;

  /// Per-circuit grouping count override (cables bunched on THIS route),
  /// replacing the panel-wide grouping count in the derating product.
  final int? groupingCountOverride;

  /// Pin a single-phase circuit to a line; excluded from auto-balancing.
  final PhaseLine? phaseOverride;

  /// Force a busbar section break at this way (manual split).
  final bool busbarBreakBefore;

  /// If set, this branch feeds another panel (its effective load = that panel's
  /// diversified demand). Wired by [ElectricalProject].
  final String? feedsPanelId;

  // ── Unified-link fields (A5 wires these; designed in now) ──────────────────
  /// Source MEP equipment id this electrical load represents (a pump, fan, AHU…)
  /// in the unified iSystem load list. A5 populates it; A4 only carries it.
  final String? sourceEquipmentId;

  /// Full-load amps supplied verbatim by the source equipment (overrides the
  /// computed design current). A5 populates it from the M/P equipment duty.
  final Current? flaOverrideA;

  const ElectricalCircuit({
    required this.id,
    required this.name,
    this.role = CircuitRole.branch,
    this.loadW = 0,
    this.cosPhi = 0.85,
    this.length = const Length(0),
    this.loadKind = LoadKind.general,
    this.isLighting = false,
    this.demandFactor = 1,
    this.motorKw,
    this.phases,
    this.lifeSafety = false,
    this.cableType,
    this.laying,
    this.cableOverrideMm2,
    this.breakerOverrideA,
    this.groupingCountOverride,
    this.phaseOverride,
    this.busbarBreakBefore = false,
    this.feedsPanelId,
    this.sourceEquipmentId,
    this.flaOverrideA,
  });

  /// True when this way is a feeder (explicit kind or it feeds a panel).
  bool get isFeeder =>
      loadKind == LoadKind.feeder || feedsPanelId != null;

  /// Serialize to a plain JSON map (enums by `.name`, typed quantities as raw
  /// SI doubles). Optional fields are omitted when null so a smaller file
  /// results and round-trips cleanly.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role.name,
        'loadW': loadW,
        'cosPhi': cosPhi,
        'length': length.meters,
        'loadKind': loadKind.name,
        'isLighting': isLighting,
        'demandFactor': demandFactor,
        if (motorKw != null) 'motorKw': motorKw,
        if (phases != null) 'phases': phases,
        'lifeSafety': lifeSafety,
        if (cableType != null) 'cableType': cableType,
        if (laying != null) 'laying': laying,
        if (cableOverrideMm2 != null) 'cableOverrideMm2': cableOverrideMm2,
        if (breakerOverrideA != null)
          'breakerOverrideA': breakerOverrideA!.amperes,
        if (groupingCountOverride != null)
          'groupingCountOverride': groupingCountOverride,
        if (phaseOverride != null) 'phaseOverride': phaseOverride!.name,
        'busbarBreakBefore': busbarBreakBefore,
        if (feedsPanelId != null) 'feedsPanelId': feedsPanelId,
        if (sourceEquipmentId != null) 'sourceEquipmentId': sourceEquipmentId,
        if (flaOverrideA != null) 'flaOverrideA': flaOverrideA!.amperes,
      };

  /// Tolerant decode: unknown enum names fall back to the field default,
  /// absent optional fields stay null, never throws on a missing value.
  static ElectricalCircuit fromJson(Map<String, dynamic> json) =>
      ElectricalCircuit(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        role: _enumOr(CircuitRole.values, json['role'], CircuitRole.branch),
        loadW: (json['loadW'] as num?)?.toDouble() ?? 0,
        cosPhi: (json['cosPhi'] as num?)?.toDouble() ?? 0.85,
        length: Length((json['length'] as num?)?.toDouble() ?? 0),
        loadKind: _enumOr(LoadKind.values, json['loadKind'], LoadKind.general),
        isLighting: json['isLighting'] == true,
        demandFactor: (json['demandFactor'] as num?)?.toDouble() ?? 1,
        motorKw: (json['motorKw'] as num?)?.toDouble(),
        phases: (json['phases'] as num?)?.toInt(),
        lifeSafety: json['lifeSafety'] == true,
        cableType: json['cableType'] as String?,
        laying: json['laying'] as String?,
        cableOverrideMm2: (json['cableOverrideMm2'] as num?)?.toDouble(),
        breakerOverrideA: json['breakerOverrideA'] == null
            ? null
            : Current((json['breakerOverrideA'] as num).toDouble()),
        groupingCountOverride: (json['groupingCountOverride'] as num?)?.toInt(),
        phaseOverride: _enumOrNull(PhaseLine.values, json['phaseOverride']),
        busbarBreakBefore: json['busbarBreakBefore'] == true,
        feedsPanelId: json['feedsPanelId'] as String?,
        sourceEquipmentId: json['sourceEquipmentId'] as String?,
        flaOverrideA: json['flaOverrideA'] == null
            ? null
            : Current((json['flaOverrideA'] as num).toDouble()),
      );
}

/// A distribution panel / board. Mirrors PanelMaker `PanelInput` (core fields).
class ElectricalPanel {
  final String id;
  final String name;

  /// Short designation / tag, e.g. "LP-1", "MDP".
  final String? tag;

  final ElectricalSystem system;

  /// Nominal panel voltage (V) — the line voltage on a 3-phase board (400),
  /// the phase-to-neutral voltage on a 1-phase board (220).
  final Voltage voltage;

  /// Ambient air temperature (°C) for derating.
  final double ambientTempC;

  /// Ground temperature for buried runs (°C). Default 20 °C (IEC reference).
  final double groundTempC;

  /// Burial depth for buried runs (m). Default 0.5 m (IEC reference).
  final double depthM;

  final CableInstallMethod installMethod;
  final ConductorInsulation insulation;
  final ConductorMaterial material;

  /// Cables grouped on the common containment route (derating).
  final int groupingCount;

  /// Diversity factor applied to the aggregated connected load when this panel
  /// feeds upstream (and for its own demand current). Explicit value — the
  /// occupancy-driven demand library is deferred to A8.
  final double diversityFactor;

  /// Optional building occupancy class (carried for A8; not applied yet).
  final String? occupancy;

  /// Fed by the utility, or by a parent panel's feeder circuit.
  final PanelSource sourceType;

  /// The parent circuit id feeding this panel (when [sourceType] is feeder).
  final String? fedByCircuitId;

  final List<ElectricalCircuit> circuits;

  const ElectricalPanel({
    required this.id,
    required this.name,
    this.tag,
    this.system = ElectricalSystem.threePhase,
    this.voltage = const Voltage(400),
    this.ambientTempC = 30,
    this.groundTempC = 20,
    this.depthM = 0.5,
    this.installMethod = CableInstallMethod.conduit,
    this.insulation = ConductorInsulation.pvc,
    this.material = ConductorMaterial.copper,
    this.groupingCount = 1,
    this.diversityFactor = 1,
    this.occupancy,
    this.sourceType = PanelSource.utility,
    this.fedByCircuitId,
    this.circuits = const [],
  });

  /// Serialize to a plain JSON map (enums by `.name`, typed quantities as raw
  /// SI doubles).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (tag != null) 'tag': tag,
        'system': system.name,
        'voltage': voltage.volts,
        'ambientTempC': ambientTempC,
        'groundTempC': groundTempC,
        'depthM': depthM,
        'installMethod': installMethod.name,
        'insulation': insulation.name,
        'material': material.name,
        'groupingCount': groupingCount,
        'diversityFactor': diversityFactor,
        if (occupancy != null) 'occupancy': occupancy,
        'sourceType': sourceType.name,
        if (fedByCircuitId != null) 'fedByCircuitId': fedByCircuitId,
        'circuits': [for (final c in circuits) c.toJson()],
      };

  /// Tolerant decode: unknown enum names fall back to the field default.
  static ElectricalPanel fromJson(Map<String, dynamic> json) => ElectricalPanel(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        tag: json['tag'] as String?,
        system: _enumOr(
          ElectricalSystem.values,
          json['system'],
          ElectricalSystem.threePhase,
        ),
        voltage: Voltage((json['voltage'] as num?)?.toDouble() ?? 400),
        ambientTempC: (json['ambientTempC'] as num?)?.toDouble() ?? 30,
        groundTempC: (json['groundTempC'] as num?)?.toDouble() ?? 20,
        depthM: (json['depthM'] as num?)?.toDouble() ?? 0.5,
        installMethod: _enumOr(
          CableInstallMethod.values,
          json['installMethod'],
          CableInstallMethod.conduit,
        ),
        insulation: _enumOr(
          ConductorInsulation.values,
          json['insulation'],
          ConductorInsulation.pvc,
        ),
        material: _enumOr(
          ConductorMaterial.values,
          json['material'],
          ConductorMaterial.copper,
        ),
        groupingCount: (json['groupingCount'] as num?)?.toInt() ?? 1,
        diversityFactor: (json['diversityFactor'] as num?)?.toDouble() ?? 1,
        occupancy: json['occupancy'] as String?,
        sourceType: _enumOr(
          PanelSource.values,
          json['sourceType'],
          PanelSource.utility,
        ),
        fedByCircuitId: json['fedByCircuitId'] as String?,
        circuits: [
          for (final c in (json['circuits'] as List? ?? const []))
            ElectricalCircuit.fromJson(c as Map<String, dynamic>),
        ],
      );
}

/// Where a panel takes its supply from.
enum PanelSource { utility, feeder }

/// A whole project (building) — the panels and the installation earthing system.
class ElectricalProject {
  final String id;
  final String name;
  final List<ElectricalPanel> panels;
  final EarthingSystem earthingSystem;

  const ElectricalProject({
    this.id = '',
    this.name = '',
    this.panels = const [],
    this.earthingSystem = EarthingSystem.tnCs,
  });

  /// Serialize to a plain JSON map. Enums by `.name`; the panels recurse.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'earthingSystem': earthingSystem.name,
        'panels': [for (final p in panels) p.toJson()],
      };

  /// Tolerant decode: an unknown earthing system falls back to PLN PME
  /// practice; a missing/non-list `panels` yields an empty list; never throws.
  static ElectricalProject fromJson(Map<String, dynamic> json) =>
      ElectricalProject(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        earthingSystem: _enumOr(
          EarthingSystem.values,
          json['earthingSystem'],
          EarthingSystem.tnCs,
        ),
        panels: [
          for (final p in (json['panels'] as List? ?? const []))
            ElectricalPanel.fromJson(p as Map<String, dynamic>),
        ],
      );
}

/// Resolve an enum [name] to a [values] entry, falling back to [fallback] when
/// the name is unknown/absent — so a `.mechx` written by a newer build (with an
/// enum value this build doesn't have) loads with a sensible default instead of
/// throwing. Pure Dart; mirrors the app-layer `_enumOr`.
T _enumOr<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is! String) return fallback;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// Like [_enumOr] but returns null for an unknown/absent name (optional fields).
T? _enumOrNull<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}
