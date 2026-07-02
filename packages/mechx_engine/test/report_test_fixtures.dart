/// Shared RICH report fixtures for the report characterization + typesetter
/// tests. Deliberately self-contained: the mechanical verify items are
/// hand-made [StandardValue]s (NOT the live `SniProfile.verifyChecklist`) so
/// the characterization pins do not drift when the standards profile gains or
/// loses entries.
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

/// FNV-1a 32-bit hash of [s] — a stable, dependency-free content fingerprint
/// for the characterization pins.
int fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// A rich mechanical report fixture exercising every section: design basis,
/// revisions (incl. a `|` needing escape), custom unverified values (both
/// provenance tiers), pump + operating point (with its 2-space sub-bullets),
/// PRV zones, Legionella-flagged hot water, all four fire modules, HVAC with
/// operating point + air balance, storm, BOM + fittings.
CalcReportData richMechData() {
  final standpipe = designStandpipe(risers: 2, buildingHeight: const Length(11.0));
  return CalcReportData(
    projectName: 'Menara Kencana',
    date: '2026-07-02',
    standardsName: 'SNI plumbing pack',
    standardsRevision: 'test rev',
    verifyItems: const [
      StandardValue<double>(392000,
          unit: 'kPa',
          citation: 'SNI 8153:2015 pasal 5.3',
          note: 'max static ~392 kPa',
          status: VerificationStatus.secondarySource),
      StandardValue<double>(0.7,
          unit: 'm/s',
          citation: 'Self-cleansing drain velocity',
          note: '0.6-0.7 m/s',
          status: VerificationStatus.notAnSniClause),
    ],
    building: const BuildingLevels([
      Floor('Ground', Length(4.0)),
      Floor('L1', Length(3.5)),
      Floor('L2', Length(3.5)),
    ]),
    feedStrategy: 'Upfeed pump',
    targetResidual: const Pressure(225000),
    pump: sizePump(
        flow: const FlowRate(0.005),
        head: const Head(30),
        withOperatingPoint: true),
    zones: const [
      DownfeedZoneStatic(
          zone: PressureZone(2, 1),
          topResidual: Pressure(200000),
          bottomStatic: Pressure(430000),
          withinLimit: true),
      DownfeedZoneStatic(
          zone: PressureZone(0, 0),
          topResidual: Pressure(200000),
          bottomStatic: Pressure(520000),
          withinLimit: false),
    ],
    hotWaterRecirc: sizeHotWaterRecirculation(
      heatLoss: const Power(4186),
      loopLength: const Length(30),
      returnDiameter: Diameter.mm(25),
      allowableDropK: 8.0,
    ),
    sprinkler: designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1),
    sprinklerRemoteArea: remoteAreaHydraulics(
        design: designSprinklerSystem(hazard: FireHazardClass.ordinaryHazard1)),
    standpipe: standpipe,
    firePumpRating: checkFirePumpRating(
      ratedFlow: standpipe.requiredFlow,
      ratedHead: standpipe.pumpHead,
    ),
    fan: sizeFan(
        airflow: const FlowRate(0.15),
        totalStaticPressure: const Pressure(50),
        withOperatingPoint: true),
    supplyAirflowLps: 150,
    returnAirflowLps: 120,
    rainfallMmPerHr: 200,
    runoffCoefficient: 0.9,
    bom: const [
      BomLine(
          service: ServiceType.coldWater,
          kind: EdgeKind.run,
          diameterMm: 50,
          totalLength: Length(12.5),
          segmentCount: 3),
      BomLine(
          service: ServiceType.duct,
          kind: EdgeKind.riser,
          diameterMm: 250,
          totalLength: Length(6.0),
          segmentCount: 2),
    ],
    fittings: const [
      FittingLine(
          service: ServiceType.coldWater,
          type: FittingType.elbow,
          diameterMm: 50,
          count: 4),
    ],
    occupancy: Occupancy.public,
    revisions: const [
      Revision('2026-06-01', 'Issued for tender'),
      Revision('2026-07-02', 'Pipe|escape check'),
    ],
  );
}

/// Two-panel electrical project: the MDP feeds SP-1 through a feeder way, so
/// the report carries two panel sections, a feeder row, per-panel + system
/// warnings (deliberately imbalanced phases).
const richElectricalProject = ElectricalProject(
  id: 'p1',
  name: 'Menara Kencana',
  panels: [
    ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      tag: 'MDP',
      circuits: [
        ElectricalCircuit(
            id: 'c1',
            name: 'Lighting',
            loadKind: LoadKind.lighting,
            isLighting: true,
            loadW: 1800,
            length: Length(20)),
        ElectricalCircuit(
            id: 'c2',
            name: 'Sockets',
            loadKind: LoadKind.socket,
            loadW: 3000,
            length: Length(20)),
        ElectricalCircuit(
            id: 'f1',
            name: 'Feeder SP-1',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'SP1',
            length: Length(30)),
      ],
    ),
    ElectricalPanel(
      id: 'SP1',
      name: 'SP-1',
      circuits: [
        ElectricalCircuit(
            id: 'c3',
            name: 'AC unit',
            loadKind: LoadKind.hvac,
            loadW: 1500,
            length: Length(15)),
      ],
    ),
  ],
);

/// A rich electrical report fixture: two panels, power one-line with an
/// interlock, an explicit verify item, the Fold-1 fault basis, and a revision.
ElectricalCalcReportData richElecData() {
  const puil = PuilProfile();
  final result = computeSystem(puil, richElectricalProject);
  const oneLine = PowerOneLine(
    nodes: [
      PowerNode(id: 'u', kind: PowerNodeKind.utility, label: 'PLN', sub: '400 V'),
      PowerNode(id: 'g', kind: PowerNodeKind.generator, label: 'Genset 100 kVA'),
    ],
    edges: [],
    interlocks: [
      PowerInterlock(
          id: 'il1',
          kind: PowerInterlockKind.mechanical,
          aId: 'u',
          bId: 'g',
          relation: PowerInterlockRelation.mutualExclusion,
          note: 'ATS mechanical interlock'),
    ],
  );
  return ElectricalCalcReportData(
    projectName: 'Menara Kencana',
    date: '2026-07-02',
    standardsName: puil.name,
    standardsRevision: puil.revision,
    project: richElectricalProject,
    result: result,
    powerOneLine: oneLine,
    verifyItems: const ['Busbar Icw — confirm against the assembly rating'],
    originFaultLevelA: 16000,
    busbarClearingTimeS: 0.1,
    revisions: const [Revision('2026-06-10', 'Issued for construction')],
  );
}

/// A rich equipment schedule: two pumps (one tagged, one sequential), a fan +
/// an AHU, and the two solved electrical panels.
EquipmentScheduleData richEquipmentData() => EquipmentScheduleData(
      projectName: 'Menara Kencana',
      date: '2026-07-02',
      pumps: [
        PumpScheduleItem(
            duty: sizePump(flow: const FlowRate(0.02), head: const Head(30)),
            service: 'Domestic water supply',
            tag: 'P-01'),
        PumpScheduleItem(
            duty: sizePump(flow: const FlowRate(0.01), head: const Head(10)),
            service: 'Hot-water recirculation'),
      ],
      fans: [
        FanScheduleItem(
            duty: sizeFan(
                airflow: const FlowRate(0.15),
                totalStaticPressure: const Pressure(50)),
            service: 'Exhaust air'),
        FanScheduleItem(
            duty: sizeFan(
                airflow: const FlowRate(0.5),
                totalStaticPressure: const Pressure(200)),
            service: 'Office AHU',
            airHandling: true),
      ],
      electrical: computeSystem(const PuilProfile(), richElectricalProject),
    );
