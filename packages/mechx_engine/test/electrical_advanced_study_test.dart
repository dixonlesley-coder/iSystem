/// A8 advanced-study BUNDLING layer — `computeAdvancedStudy` integration tests.
///
/// These exercise the derived pass over a real, computed system: that it runs
/// every advanced module, keys the per-panel/per-circuit maps correctly, and
/// preserves the provenance honesty surface. They assert structure + presence
/// (the per-module arithmetic is verified by each module's own seed suite), per
/// the "tests are the spec" rule — the bundling layer's contract is what's new.
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = PuilProfile();

  /// A 3-phase MDP (utility-fed) with a VFD-driven pump (carries a starterType),
  /// a heating final, and a feeder to a single-phase lighting sub-panel; plus a
  /// generator + battery so the power one-line + dip screen run. Site inputs
  /// (soil resistivity, ground flash density, building geometry) are set so the
  /// electrode + lightning passes run too.
  ElectricalProject buildProject() {
    const lp1 = ElectricalPanel(
      id: 'lp1',
      name: 'Lighting Panel',
      tag: 'LP-1',
      system: ElectricalSystem.singlePhase,
      voltage: Voltage(220),
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'mdp-f1',
      diversityFactor: 0.9,
      circuits: [
        ElectricalCircuit(
          id: 'lp1-c1',
          name: 'Lighting',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 2400,
          cosPhi: 0.9,
          length: Length(30),
        ),
      ],
    );

    const mdp = ElectricalPanel(
      id: 'mdp',
      name: 'Main Distribution Panel',
      tag: 'MDP',
      voltage: Voltage(400),
      diversityFactor: 0.8,
      essential: true,
      circuits: [
        ElectricalCircuit(
          id: 'mdp-f1',
          name: 'Feeder to LP-1',
          loadKind: LoadKind.feeder,
          feedsPanelId: 'lp1',
          length: Length(22),
        ),
        ElectricalCircuit(
          id: 'mdp-c1',
          name: 'Booster pump (VFD)',
          loadKind: LoadKind.pump,
          motorKw: 7.5,
          cosPhi: 0.85,
          length: Length(25),
          starterType: StarterType.vfd,
        ),
        ElectricalCircuit(
          id: 'mdp-c2',
          name: 'Water heater',
          loadKind: LoadKind.heating,
          loadW: 9000,
          cosPhi: 1.0,
          length: Length(15),
        ),
      ],
    );

    return const ElectricalProject(
      id: 'p1',
      name: 'Advanced study building',
      earthingSystem: EarthingSystem.tnCs,
      panels: [mdp, lp1],
      sources: ElectricalSources(
        generator: GeneratorSource(backupFraction: 1.0),
        battery: BatterySource(autonomyHours: 2),
      ),
      soilResistivityOhmM: 100,
      groundFlashDensity: 12,
      buildingLengthM: 40,
      buildingWidthM: 25,
      buildingHeightM: 18,
    );
  }

  test('computeAdvancedStudy runs every pass over a computed system', () {
    final project = buildProject();
    final sys = computeSystem(profile, project);
    final study = computeAdvancedStudy(profile, project, sys);

    // A fault entry per panel.
    for (final id in sys.order) {
      expect(study.fault.panels.containsKey(id), isTrue,
          reason: 'fault result for $id');
    }
    expect(study.fault.panels.length, sys.panels.length);
    expect(study.fault.originFaultkA, greaterThan(0));

    // A supply design + a recommended daya step.
    expect(study.supply.demandKva, greaterThan(0));
    expect(study.recommendedDayaVa, greaterThan(0));

    // A control assembly for the VFD pump circuit (and only motor-like circuits
    // with a starterType get one — the heating final has none).
    expect(study.controlAssemblies.containsKey('mdp-c1'), isTrue);
    expect(study.controlAssemblies['mdp-c1']!.starterType, StarterType.vfd);
    expect(study.controlAssemblies.containsKey('mdp-c2'), isFalse);
    expect(study.controlAssemblies['mdp-c1']!.motor, isNotNull);

    // An enclosure per panel.
    for (final id in sys.order) {
      expect(study.enclosure.containsKey(id), isTrue,
          reason: 'enclosure for $id');
      expect(study.enclosure[id]!.widthMm, greaterThan(0));
    }

    // Per-panel containment + metering + spd + arc-flash + harmonics keys.
    for (final id in sys.order) {
      expect(study.containment.containsKey(id), isTrue);
      expect(study.metering.containsKey(id), isTrue);
      expect(study.spd.containsKey(id), isTrue);
      expect(study.arcFlash.containsKey(id), isTrue); // value may be null
      expect(study.harmonics.containsKey(id), isTrue); // value may be null
    }

    // The origin (MDP) SPD is an origin device; the sub-board is sub-distribution.
    expect(study.spd['mdp']!.location, contains('Origin'));
    expect(study.spd['lp1']!.location, contains('Sub-distribution'));

    // The VFD panel reports harmonics (non-linear share from the drive).
    expect(study.harmonics['mdp'], isNotNull);

    // A non-empty BOM.
    expect(study.bom.lines, isNotEmpty);

    // A power one-line when sources are set, with a generator + battery node.
    expect(study.powerOneLine, isNotNull);
    final kinds = study.powerOneLine!.nodes.map((n) => n.kind).toSet();
    expect(kinds.contains(PowerNodeKind.generator), isTrue);
    expect(kinds.contains(PowerNodeKind.battery), isTrue);

    // Lightning + electrode ran (site inputs given).
    expect(study.lightning, isNotNull);
    expect(study.electrode, isNotNull);
    expect(study.electrode!.rodCount, greaterThanOrEqualTo(1));

    // The aggregated provenance honesty surface is non-empty and de-duplicated.
    expect(study.verifyItems, isNotEmpty);
    expect(study.verifyItems.toSet().length, study.verifyItems.length,
        reason: 'verifyItems are de-duplicated');
  });

  test('no energy sources → no power one-line; no site inputs → no lightning/electrode',
      () {
    const bare = ElectricalProject(
      id: 'bare',
      name: 'Bare',
      panels: [
        ElectricalPanel(
          id: 'mdp',
          name: 'MDP',
          voltage: Voltage(400),
          circuits: [
            ElectricalCircuit(
              id: 'c1',
              name: 'General load',
              loadKind: LoadKind.general,
              loadW: 6000,
              length: Length(20),
            ),
          ],
        ),
      ],
    );
    final sys = computeSystem(profile, bare);
    final study = computeAdvancedStudy(profile, bare, sys);

    expect(study.powerOneLine, isNull);
    expect(study.lightning, isNull);
    expect(study.electrode, isNull);
    // Still runs the always-on passes.
    expect(study.fault.panels.containsKey('mdp'), isTrue);
    expect(study.bom.lines, isNotEmpty);
    expect(study.controlAssemblies, isEmpty);
  });

  test('model: new advanced fields round-trip through toJson/fromJson', () {
    const project = ElectricalProject(
      id: 'p1',
      name: 'Round-trip',
      earthingSystem: EarthingSystem.tt,
      dualTransformer: true,
      occupancy: 'office',
      soilResistivityOhmM: 150,
      groundFlashDensity: 10,
      externalLps: true,
      overheadSupply: true,
      buildingLengthM: 50,
      buildingWidthM: 30,
      buildingHeightM: 20,
      sources: ElectricalSources(
        generator: GeneratorSource(
          kva: ApparentPower(150000),
          backupFraction: 0.6,
          mode: GeneratorMode.prime,
          transfer: GeneratorTransfer.manual,
        ),
        solar: SolarSource(panelWp: 550, panels: 24, dcAcRatio: 1.25),
        battery: BatterySource(
          chemistry: BatteryChemistry.leadAcid,
          autonomyHours: 4,
        ),
        hybridInverter: true,
      ),
      panels: [
        ElectricalPanel(
          id: 'mdp',
          name: 'MDP',
          voltage: Voltage(400),
          essential: true,
          upsBacked: true,
          submeter: true,
          heatW: Power(320),
          circuits: [
            ElectricalCircuit(
              id: 'c1',
              name: 'Pump',
              loadKind: LoadKind.pump,
              motorKw: 11,
              length: Length(25),
              starterType: StarterType.starDelta,
            ),
          ],
        ),
      ],
    );

    final decoded = ElectricalProject.fromJson(project.toJson());

    expect(decoded.dualTransformer, isTrue);
    expect(decoded.occupancy, 'office');
    expect(decoded.soilResistivityOhmM, 150);
    expect(decoded.groundFlashDensity, 10);
    expect(decoded.externalLps, isTrue);
    expect(decoded.overheadSupply, isTrue);
    expect(decoded.buildingLengthM, 50);
    expect(decoded.buildingWidthM, 30);
    expect(decoded.buildingHeightM, 20);

    final s = decoded.sources;
    expect(s, isNotNull);
    expect(s!.generator!.kva!.voltAmperes, 150000);
    expect(s.generator!.backupFraction, 0.6);
    expect(s.generator!.mode, GeneratorMode.prime);
    expect(s.generator!.transfer, GeneratorTransfer.manual);
    expect(s.solar!.panelWp, 550);
    expect(s.solar!.panels, 24);
    expect(s.solar!.dcAcRatio, 1.25);
    expect(s.battery!.chemistry, BatteryChemistry.leadAcid);
    expect(s.battery!.autonomyHours, 4);
    expect(s.hybridInverter, isTrue);

    final mdp = decoded.panels.single;
    expect(mdp.essential, isTrue);
    expect(mdp.upsBacked, isTrue);
    expect(mdp.submeter, isTrue);
    expect(mdp.heatW!.watts, 320);
    expect(mdp.circuits.single.starterType, StarterType.starDelta);
  });
}
