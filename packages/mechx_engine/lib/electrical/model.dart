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
import 'control/starter.dart' show StarterType;
import 'earthing.dart' show EarthingSystem;
import 'geo_length.dart' show LayoutPos;
import 'load_kind.dart' show LoadKind;
import 'sources.dart'
    show
        BatteryChemistry,
        BatterySource,
        ElectricalSources,
        GeneratorMode,
        GeneratorSource,
        GeneratorTransfer,
        SolarSource;

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

  /// Motor-starter / control scheme for this way (DOL / star-delta / VFD …),
  /// when it is a motor or pump circuit. Drives the A8 control-assembly pass
  /// (`applyStarterTemplate`); absent = no explicit starter (the advanced study
  /// then skips a control assembly for the circuit). Additive — the core A4
  /// sizing in `compute.dart` does not read it.
  final StarterType? starterType;

  /// Where this circuit's LOAD sits on the calibrated PDF layout (the geo
  /// substrate). When set — together with the panel's [ElectricalPanel.layoutPos]
  /// — the cable run length is derived from real geometry (`resolveCircuitLength`
  /// / `electricalCableLength`), the panel→load route. For a FEEDER the load is
  /// the sub-panel (`feedsPanelId`), so its geo length is panel→sub-panel and
  /// uses the target panel's [ElectricalPanel.layoutPos] rather than this field.
  /// Null = not placed ⇒ the manual [length] is used. Additive — a different
  /// space from any single-line canvas coordinate.
  final LayoutPos? loadPos;

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
    this.starterType,
    this.loadPos,
  });

  /// True when this way is a feeder (explicit kind or it feeds a panel).
  bool get isFeeder =>
      loadKind == LoadKind.feeder || feedsPanelId != null;

  /// Field-wise copy — every field carries through unless overridden. Purely
  /// additive (used by the app's edit intents); the engine never mutates inputs.
  /// Pass a `() => null` sentinel via the dedicated clear flags to null an
  /// optional field, since a plain `null` argument means "keep".
  ElectricalCircuit copyWith({
    String? id,
    String? name,
    CircuitRole? role,
    double? loadW,
    double? cosPhi,
    Length? length,
    LoadKind? loadKind,
    bool? isLighting,
    double? demandFactor,
    double? motorKw,
    bool clearMotorKw = false,
    int? phases,
    bool clearPhases = false,
    bool? lifeSafety,
    String? cableType,
    bool clearCableType = false,
    String? laying,
    double? cableOverrideMm2,
    Current? breakerOverrideA,
    int? groupingCountOverride,
    PhaseLine? phaseOverride,
    bool? busbarBreakBefore,
    String? feedsPanelId,
    String? sourceEquipmentId,
    Current? flaOverrideA,
    StarterType? starterType,
    LayoutPos? loadPos,
    bool clearLoadPos = false,
  }) =>
      ElectricalCircuit(
        id: id ?? this.id,
        name: name ?? this.name,
        role: role ?? this.role,
        loadW: loadW ?? this.loadW,
        cosPhi: cosPhi ?? this.cosPhi,
        length: length ?? this.length,
        loadKind: loadKind ?? this.loadKind,
        isLighting: isLighting ?? this.isLighting,
        demandFactor: demandFactor ?? this.demandFactor,
        motorKw: clearMotorKw ? null : (motorKw ?? this.motorKw),
        phases: clearPhases ? null : (phases ?? this.phases),
        lifeSafety: lifeSafety ?? this.lifeSafety,
        cableType: clearCableType ? null : (cableType ?? this.cableType),
        laying: laying ?? this.laying,
        cableOverrideMm2: cableOverrideMm2 ?? this.cableOverrideMm2,
        breakerOverrideA: breakerOverrideA ?? this.breakerOverrideA,
        groupingCountOverride:
            groupingCountOverride ?? this.groupingCountOverride,
        phaseOverride: phaseOverride ?? this.phaseOverride,
        busbarBreakBefore: busbarBreakBefore ?? this.busbarBreakBefore,
        feedsPanelId: feedsPanelId ?? this.feedsPanelId,
        sourceEquipmentId: sourceEquipmentId ?? this.sourceEquipmentId,
        flaOverrideA: flaOverrideA ?? this.flaOverrideA,
        starterType: starterType ?? this.starterType,
        loadPos: clearLoadPos ? null : (loadPos ?? this.loadPos),
      );

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
        if (starterType != null) 'starterType': starterType!.name,
        if (loadPos != null) 'loadPos': loadPos!.toJson(),
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
        starterType: _enumOrNull(StarterType.values, json['starterType']),
        loadPos: json['loadPos'] is Map<String, dynamic>
            ? LayoutPos.fromJson(json['loadPos'] as Map<String, dynamic>)
            : null,
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

  /// Essential (genset-backed) board: its aggregate demand sets the standby
  /// generator backup. Carried for the A8 sources / power-one-line pass.
  final bool essential;

  /// Critical / UPS-backed board: backed by the battery bank in the A8 sources
  /// pass (the topmost-flagged-demand tier).
  final bool upsBacked;

  /// Tenant sub-metered board — picks direct vs CT revenue metering in the A8
  /// metering pass.
  final bool submeter;

  /// Optional measured / specified internal heat dissipation (W). When set it
  /// overrides the A8 enclosure pass's control-device heat estimate.
  final Power? heatW;

  /// Canvas layout position (world px) on the single-line spatial canvas. Purely
  /// a UI concern — the engine never reads it; null = auto-layout. Additive (the
  /// Wave-5 electrical canvas; mirrors PanelMaker's React Flow node position).
  final double? x;
  final double? y;

  /// Where this panel sits on the calibrated PDF layout (the geo substrate):
  /// a sheet + floor + sheet-pixel position. When set, a placed circuit's cable
  /// run length is derived from real geometry (panel→load), instead of the
  /// manual circuit [ElectricalCircuit.length]. Additive — a DIFFERENT space
  /// from the abstract single-line [x]/[y] above ([x]/[y] are schematic-canvas
  /// world pixels; [layoutPos] is a calibrated PDF sheet/floor placement). The
  /// engine core never reads it; the geo resolver / Layout wave do. Null = the
  /// panel is not placed on the layout.
  final LayoutPos? layoutPos;

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
    this.essential = false,
    this.upsBacked = false,
    this.submeter = false,
    this.heatW,
    this.x,
    this.y,
    this.layoutPos,
    this.circuits = const [],
  });

  /// Field-wise copy — every field carries through unless overridden. Purely
  /// additive (used by the app's edit intents); the engine never mutates inputs.
  ElectricalPanel copyWith({
    String? id,
    String? name,
    String? tag,
    bool clearTag = false,
    ElectricalSystem? system,
    Voltage? voltage,
    double? ambientTempC,
    double? groundTempC,
    double? depthM,
    CableInstallMethod? installMethod,
    ConductorInsulation? insulation,
    ConductorMaterial? material,
    int? groupingCount,
    double? diversityFactor,
    String? occupancy,
    PanelSource? sourceType,
    String? fedByCircuitId,
    bool clearFedByCircuitId = false,
    bool? essential,
    bool? upsBacked,
    bool? submeter,
    Power? heatW,
    double? x,
    double? y,
    bool clearPosition = false,
    LayoutPos? layoutPos,
    bool clearLayoutPos = false,
    List<ElectricalCircuit>? circuits,
  }) =>
      ElectricalPanel(
        id: id ?? this.id,
        name: name ?? this.name,
        tag: clearTag ? null : (tag ?? this.tag),
        system: system ?? this.system,
        voltage: voltage ?? this.voltage,
        ambientTempC: ambientTempC ?? this.ambientTempC,
        groundTempC: groundTempC ?? this.groundTempC,
        depthM: depthM ?? this.depthM,
        installMethod: installMethod ?? this.installMethod,
        insulation: insulation ?? this.insulation,
        material: material ?? this.material,
        groupingCount: groupingCount ?? this.groupingCount,
        diversityFactor: diversityFactor ?? this.diversityFactor,
        occupancy: occupancy ?? this.occupancy,
        sourceType: sourceType ?? this.sourceType,
        fedByCircuitId:
            clearFedByCircuitId ? null : (fedByCircuitId ?? this.fedByCircuitId),
        essential: essential ?? this.essential,
        upsBacked: upsBacked ?? this.upsBacked,
        submeter: submeter ?? this.submeter,
        heatW: heatW ?? this.heatW,
        x: clearPosition ? null : (x ?? this.x),
        y: clearPosition ? null : (y ?? this.y),
        layoutPos: clearLayoutPos ? null : (layoutPos ?? this.layoutPos),
        circuits: circuits ?? this.circuits,
      );

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
        'essential': essential,
        'upsBacked': upsBacked,
        'submeter': submeter,
        if (heatW != null) 'heatW': heatW!.watts,
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        if (layoutPos != null) 'layoutPos': layoutPos!.toJson(),
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
        essential: json['essential'] == true,
        upsBacked: json['upsBacked'] == true,
        submeter: json['submeter'] == true,
        heatW: json['heatW'] == null
            ? null
            : Power((json['heatW'] as num).toDouble()),
        x: (json['x'] as num?)?.toDouble(),
        y: (json['y'] as num?)?.toDouble(),
        layoutPos: json['layoutPos'] is Map<String, dynamic>
            ? LayoutPos.fromJson(json['layoutPos'] as Map<String, dynamic>)
            : null,
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

  /// Distributed energy sources (generator / solar PV / battery), when the
  /// building has any. Drives the A8 sources + power-one-line pass; null = none.
  final ElectricalSources? sources;

  /// Force a dual-transformer MV supply (split bus + N.O. coupler) even below
  /// the LV ceiling (hotels / data centres). A8 supply pass.
  final bool dualTransformer;

  /// Building occupancy class (residential / office / commercial …) for the A8
  /// occupancy demand library. Null = not set.
  final String? occupancy;

  /// Measured / assumed soil resistivity (Ω·m) for the A8 earth-electrode design.
  /// Null = the electrode pass is skipped.
  final double? soilResistivityOhmM;

  /// Local ground flash density Ng (flashes/km²/yr) for the A8 lightning screen.
  /// Null = the lightning screen is skipped.
  final double? groundFlashDensity;

  /// Building has an external Lightning Protection System (forces an origin
  /// Type 1 SPD). A8 SPD pass.
  final bool externalLps;

  /// Supply arrives via an overhead line (direct-strike exposure → origin
  /// Type 1 SPD). A8 SPD pass.
  final bool overheadSupply;

  /// Building footprint length (m) for the A8 lightning collection area.
  final double? buildingLengthM;

  /// Building footprint width (m) for the A8 lightning collection area.
  final double? buildingWidthM;

  /// Building height (m) for the A8 lightning collection area.
  final double? buildingHeightM;

  const ElectricalProject({
    this.id = '',
    this.name = '',
    this.panels = const [],
    this.earthingSystem = EarthingSystem.tnCs,
    this.sources,
    this.dualTransformer = false,
    this.occupancy,
    this.soilResistivityOhmM,
    this.groundFlashDensity,
    this.externalLps = false,
    this.overheadSupply = false,
    this.buildingLengthM,
    this.buildingWidthM,
    this.buildingHeightM,
  });

  /// Serialize to a plain JSON map. Enums by `.name`; the panels recurse;
  /// optional fields are omitted when null so the file stays small + round-trips.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'earthingSystem': earthingSystem.name,
        if (sources != null) 'sources': _sourcesToJson(sources!),
        'dualTransformer': dualTransformer,
        if (occupancy != null) 'occupancy': occupancy,
        if (soilResistivityOhmM != null)
          'soilResistivityOhmM': soilResistivityOhmM,
        if (groundFlashDensity != null)
          'groundFlashDensity': groundFlashDensity,
        'externalLps': externalLps,
        'overheadSupply': overheadSupply,
        if (buildingLengthM != null) 'buildingLengthM': buildingLengthM,
        if (buildingWidthM != null) 'buildingWidthM': buildingWidthM,
        if (buildingHeightM != null) 'buildingHeightM': buildingHeightM,
        'panels': [for (final p in panels) p.toJson()],
      };

  /// Tolerant decode: an unknown earthing system falls back to PLN PME
  /// practice; a missing/non-list `panels` yields an empty list; absent optional
  /// fields stay null/false; never throws.
  static ElectricalProject fromJson(Map<String, dynamic> json) =>
      ElectricalProject(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        earthingSystem: _enumOr(
          EarthingSystem.values,
          json['earthingSystem'],
          EarthingSystem.tnCs,
        ),
        sources: json['sources'] is Map<String, dynamic>
            ? _sourcesFromJson(json['sources'] as Map<String, dynamic>)
            : null,
        dualTransformer: json['dualTransformer'] == true,
        occupancy: json['occupancy'] as String?,
        soilResistivityOhmM:
            (json['soilResistivityOhmM'] as num?)?.toDouble(),
        groundFlashDensity: (json['groundFlashDensity'] as num?)?.toDouble(),
        externalLps: json['externalLps'] == true,
        overheadSupply: json['overheadSupply'] == true,
        buildingLengthM: (json['buildingLengthM'] as num?)?.toDouble(),
        buildingWidthM: (json['buildingWidthM'] as num?)?.toDouble(),
        buildingHeightM: (json['buildingHeightM'] as num?)?.toDouble(),
        panels: [
          for (final p in (json['panels'] as List? ?? const []))
            ElectricalPanel.fromJson(p as Map<String, dynamic>),
        ],
      );
}

/// Serialize an [ElectricalSources] to JSON. `sources.dart` carries no codec
/// (it is an engine input the integration layer wires on), so the project owns
/// the mapping. Enums by `.name`, optional sub-sources omitted when absent.
Map<String, dynamic> _sourcesToJson(ElectricalSources s) => {
      if (s.generator != null) 'generator': {
          if (s.generator!.kva != null)
            'kva': s.generator!.kva!.voltAmperes,
          'backupFraction': s.generator!.backupFraction,
          'mode': s.generator!.mode.name,
          'transfer': s.generator!.transfer.name,
        },
      if (s.solar != null) 'solar': {
          'panelWp': s.solar!.panelWp,
          'panels': s.solar!.panels,
          'dcAcRatio': s.solar!.dcAcRatio,
        },
      if (s.battery != null) 'battery': {
          'chemistry': s.battery!.chemistry.name,
          'autonomyHours': s.battery!.autonomyHours,
        },
      if (s.hybridInverter != null) 'hybridInverter': s.hybridInverter,
    };

/// Tolerant decode of an [ElectricalSources] — unknown enum names fall back to
/// the source default; absent sub-sources stay null.
ElectricalSources _sourcesFromJson(Map<String, dynamic> json) {
  GeneratorSource? generator;
  final g = json['generator'];
  if (g is Map<String, dynamic>) {
    generator = GeneratorSource(
      kva: g['kva'] == null
          ? null
          : ApparentPower((g['kva'] as num).toDouble()),
      backupFraction: (g['backupFraction'] as num?)?.toDouble() ?? 1.0,
      mode: _enumOr(GeneratorMode.values, g['mode'], GeneratorMode.standby),
      transfer: _enumOr(
        GeneratorTransfer.values,
        g['transfer'],
        GeneratorTransfer.ats,
      ),
    );
  }
  SolarSource? solar;
  final so = json['solar'];
  if (so is Map<String, dynamic>) {
    solar = SolarSource(
      panelWp: (so['panelWp'] as num?)?.toInt() ?? 550,
      panels: (so['panels'] as num?)?.toInt() ?? 0,
      dcAcRatio: (so['dcAcRatio'] as num?)?.toDouble() ?? 1.2,
    );
  }
  BatterySource? battery;
  final b = json['battery'];
  if (b is Map<String, dynamic>) {
    battery = BatterySource(
      chemistry: _enumOr(
        BatteryChemistry.values,
        b['chemistry'],
        BatteryChemistry.lifepo4,
      ),
      autonomyHours: (b['autonomyHours'] as num?)?.toDouble() ?? 0,
    );
  }
  return ElectricalSources(
    generator: generator,
    solar: solar,
    battery: battery,
    hybridInverter: json['hybridInverter'] is bool
        ? json['hybridInverter'] as bool
        : null,
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
