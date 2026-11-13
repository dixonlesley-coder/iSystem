// Reference building 3 — a 4-storey OFFICE (kantor 4 lantai).
//
// A fixed, hand-checkable input set. Cold water: a water meter → ground tank
// → UPFEED pump → riser → a public toilet core on every floor (two
// FLUSH-VALVE WCs, a urinal, two lavatories); their drainage to a soil stack
// + outfall with one stack vent; two roof drains + downpipe. A separate FIRE
// network: fire tank → fire pump → a hydrant riser with one indoor hydrant
// box per floor and a sprinkler riser with six heads on Lantai 4. HVAC on
// Lantai 2: one office room with a ducted FCU, four supply diffusers in one
// line and a return grille. Electrical: a 3-phase service board `LVMDP`
// (declared 164 000 VA PLN) feeding four 3-phase floor sub-boards PP-L1..L4.
// Pure Dart (no Flutter import): the engine suite and the app suite
// (relative import) build exactly this.
//
// GEOMETRY. Calibration is 0.02 m/px on all four sheets (50 px = 1 m). Every
// RUN's straight pixel span x 0.02 is the spec PLAN length exactly: the
// trunks are axis-aligned on integer pixels; a fixture is BOTH the end of a
// cold branch from its floor's `T` (1.0 / 2.0 / 3.0 / 1.5 / 2.5 m) AND the
// start of a 1.5 m drain to its floor's `D`, so it sits on the INTERSECTION
// of the two circles ([_onCircles], as in the house / shophouse). T → D is
// 2.0 m, inside the [1.5, 2.5] m window every radius pair needs. Risers share
// x/y on their floors.
//
// COMPONENTS. The hydrant outlet is `NodeComponent.hydrantBox` (the indoor
// hydrant box / Class I hose valve); the urinal is
// `PlumbingFixture.urinalFlushTank` (the only urinal type the fixture table
// has — there is no flush-valve urinal); the ducted fan-coil is
// `NodeComponent.fcu` (role plant), the diffusers `supplyDiffuser`, the
// return grille `returnGrille`.
//
// ROOM AIR. The room is an APP annotation (`RoomArea`), described here as
// plain data ([kOfficeRooms]); its airflow is the SAME `sizeRoomAir` call the
// app's `RoomArea.sizing` makes (office type, seeded ceiling 4.0 − 0.3 =
// 3.7 m, the type's default ACH, FCU, default duct settings round /
// velocity), and each diffuser is stamped with one quarter of it, each of the
// two return grilles with half of it (backlog L-2, [kOfficeRoomAirflow]).
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart'
    show RoomType, SniVentilationProfile;
import 'package:mechx_engine/units.dart';

import 'reference_building.dart';

export 'reference_building.dart';

/// Sheet ids (one sheet per floor).
const List<String> kOfficeSheets = ['s_L1', 's_L2', 's_L3', 's_L4'];

/// 0.02 m per pixel ⇒ 50 px = 1 m.
const double kOfficeMetersPerPixel = 0.02;

/// Floor-to-floor height (m) of every storey.
const double kOfficeFloorHeightM = 4.0;

/// The per-floor delivery fixtures (base ids, suffixed with the floor index).
const List<String> kOfficeFloorFixtures = ['WCa', 'WCb', 'UR', 'LAVa', 'LAVb'];

/// The fixture type of each per-floor fixture base id.
const Map<String, PlumbingFixture> kOfficeFixtureType = {
  'WCa': PlumbingFixture.waterClosetFlushValve,
  'WCb': PlumbingFixture.waterClosetFlushValve,
  'UR': PlumbingFixture.urinalFlushTank,
  'LAVa': PlumbingFixture.lavatory,
  'LAVb': PlumbingFixture.lavatory,
};

/// Plan length (m) of the cold branch T → fixture.
const Map<String, double> kOfficeBranchM = {
  'WCa': 1.0,
  'WCb': 2.0,
  'UR': 3.0,
  'LAVa': 1.5,
  'LAVb': 2.5,
};

/// The four sprinkler heads + hydrant boxes, the HVAC node ids.
const List<String> kOfficeSprinklerHeads = [
  'SP1', 'SP2', 'SP3', 'SP4', 'SP5', 'SP6', //
];
const List<String> kOfficeHydrants = ['HYD0', 'HYD1', 'HYD2', 'HYD3'];
const String kOfficeFcuId = 'FCU1';
const List<String> kOfficeDiffusers = ['SD1', 'SD2', 'SD3', 'SD4'];
const String kOfficeReturnGrilleId = 'RG1';

/// Drawing backlog L-2 (2026-11-13) — the room's two-grille return bank
/// (office backlog i): RG2 → RG1 → FCU1, each 600 x 600 carrying half the
/// room airflow.
const String kOfficeReturnGrille2Id = 'RG2';
const List<String> kOfficeReturnGrilles = [
  kOfficeReturnGrilleId,
  kOfficeReturnGrille2Id,
];

/// A room annotation as plain data (as in the shophouse fixture).
class OfficeRoom {
  final String name;
  final String sheetId;
  final int floorIndex;
  final double ax, ay, bx, by;
  final RoomType roomType;
  const OfficeRoom({
    required this.name,
    required this.sheetId,
    required this.floorIndex,
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
    required this.roomType,
  });

  double get widthM => (bx - ax).abs() * kOfficeMetersPerPixel;
  double get depthM => (by - ay).abs() * kOfficeMetersPerPixel;
}

/// The office room on Lantai 2: 10.0 m (500 px) x 15.0 m (750 px), corners
/// (1300, 200) → (1800, 950), `RoomType.office`.
const List<OfficeRoom> kOfficeRooms = [
  OfficeRoom(
    name: 'Kantor L2',
    sheetId: 's_L2',
    floorIndex: 1,
    ax: 1300,
    ay: 200,
    bx: 1800,
    by: 950,
    roomType: RoomType.office,
  ),
];

/// The ceiling the app's Room tool seeds on a 4.0 m floor: floor-to-floor
/// less the default `MountingHeights.ceilingDrop` (0.3 m).
final double kOfficeRoomCeilingM =
    kOfficeFloorHeightM - const MountingHeights().ceilingDrop.meters;

/// The room's air sizing exactly as `RoomArea.sizing` runs it (default ACH
/// of the type, FCU, the type's grille application, round / velocity ducts).
RoomAirResult officeRoomAir() {
  final r = kOfficeRooms.single;
  const v = SniVentilationProfile();
  return sizeRoomAir(
    floorArea: Area(r.widthM * r.depthM),
    ceilingHeight: Length(kOfficeRoomCeilingM),
    airChangesPerHour: v.recommendedAch(r.roomType).value,
    equipmentKind: AirEquipmentKind.fcu,
    grilleApplication: v.grilleApplicationFor(r.roomType),
  );
}

/// The room's sized supply airflow (supply = return), stamped on the network.
final FlowRate kOfficeRoomAirflow = officeRoomAir().airflow;

/// Pass 2 — the stamped terminal faces (mm): each diffuser 450 x 300
/// (231.25 L/s over 0.135 m² x 0.8 free = 2.14 m/s <= 3.0; 300 x 300 would
/// be 3.21), each of the TWO return grilles 600 x 600 (backlog L-2: 462.5
/// L/s over 0.36 x 0.8 = 1.606 m/s <= the office return limit min(3.0, 4.0)
/// = 3.0 m/s; the room's bank is ceil(0.925 / (0.288 x 3.0)) = 2 grilles —
/// one grille carrying 925 L/s was 3.212 m/s and flagged).
const (double, double) kOfficeDiffuserFaceMm = (450, 300);
const (double, double) kOfficeReturnFaceMm = (600, 600);

/// The point at distance [ra] px from [a] AND [rb] px from [b] nearest
/// [near] (two circles' intersection).
(double, double) _onCircles((double, double) a, double ra, (double, double) b,
    double rb, (double, double) near) {
  final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
  final d = math.sqrt(dx * dx + dy * dy);
  final along = (ra * ra - rb * rb + d * d) / (2 * d);
  final h = math.sqrt(math.max(0, ra * ra - along * along));
  final mx = a.$1 + along * dx / d, my = a.$2 + along * dy / d;
  final p1 = (mx + h * dy / d, my - h * dx / d);
  final p2 = (mx - h * dy / d, my + h * dx / d);
  double dist((double, double) p) =>
      math.sqrt(math.pow(p.$1 - near.$1, 2) + math.pow(p.$2 - near.$2, 2));
  return dist(p1) <= dist(p2) ? p1 : p2;
}

double _px(double meters) => meters / kOfficeMetersPerPixel;

/// Edge id convention: `e_<svc>_<from>_<to>`.
NetEdge _edge(ServiceType s, String from, String to,
    {EdgeKind kind = EdgeKind.run}) {
  final tag = switch (s) {
    ServiceType.coldWater => 'cw',
    ServiceType.drainage => 'dr',
    ServiceType.vent => 'vt',
    ServiceType.rainwater => 'rw',
    ServiceType.fireHydrant => 'fh',
    ServiceType.fireSprinkler => 'sp',
    ServiceType.duct => 'sa',
    ServiceType.returnAir => 'ra',
    _ => s.name,
  };
  return NetEdge(
      id: 'e_${tag}_${from}_$to',
      fromId: from,
      toId: to,
      service: s,
      kind: kind);
}

// Toilet core per floor: T (end of the 3.0 m trunk from the riser R) at
// (250, 700); its drainage junction D 2.0 m south at (250, 800). The WCs sit
// west, the urinal and lavatories east.
const _r = (100.0, 700.0);
const _t = (250.0, 700.0);
const _d = (250.0, 800.0);
final Map<String, (double, double)> _fixtureAt = {
  'WCa': _onCircles(_t, _px(1.0), _d, _px(1.5), (200, 730)),
  'WCb': _onCircles(_t, _px(2.0), _d, _px(1.5), (170, 760)),
  'UR': _onCircles(_t, _px(3.0), _d, _px(1.5), (390, 820)),
  'LAVa': _onCircles(_t, _px(1.5), _d, _px(1.5), (320, 750)),
  'LAVb': _onCircles(_t, _px(2.5), _d, _px(1.5), (350, 790)),
};

/// The office's mechanical + fire + HVAC network.
Network buildOfficeNetwork() {
  NetNode node(
    String id,
    (double, double) at, {
    required int floor,
    NodeRole role = NodeRole.main,
    NodeComponent? component,
    PlumbingFixture? fixture,
    double? roofAreaM2,
    FlowRate? airflow,
    (double, double)? faceMm,
  }) =>
      NetNode(
        id: id,
        sheetId: kOfficeSheets[floor],
        x: at.$1,
        y: at.$2,
        floorIndex: floor,
        role: component?.role ?? (fixture != null ? NodeRole.fixture : role),
        component: component,
        fixture: fixture,
        roofAreaM2: roofAreaM2,
        airflow: airflow,
        faceWidthMm: faceMm?.$1,
        faceHeightMm: faceMm?.$2,
      );

  final quarter = FlowRate(kOfficeRoomAirflow.cubicMetersPerSecond / 4);
  final nodes = <NetNode>[
    // ── Cold water: meter → ground tank → upfeed pump → riser base ────────
    node('WM', (100, 1000), floor: 0, component: NodeComponent.waterMeter),
    node('GT', (100, 850), floor: 0, component: NodeComponent.groundTank),
    node('P1', (100, 800), floor: 0, component: NodeComponent.pump),
    node('R0', _r, floor: 0),
    for (var f = 1; f < 4; f++) node('R$f', _r, floor: f),
    for (var f = 0; f < 4; f++) ...[
      node('T$f', _t, floor: f),
      for (final b in kOfficeFloorFixtures)
        node('$b$f', _fixtureAt[b]!, floor: f, fixture: kOfficeFixtureType[b]),
      node('D$f', _d, floor: f),
    ],
    node('OUT', (250, 1300), floor: 0), // D0 → OUT = 500 px = 10.0 m
    node('VTR', _d, floor: 3), // vent terminal above D3 (a riser)
    // ── Rainwater: two roof drains → leader → downpipe → collector ────────
    node('RDa', (600, 600),
        floor: 3, component: NodeComponent.roofDrain, roofAreaM2: 150),
    node('RDb', (700, 700),
        floor: 3, component: NodeComponent.roofDrain, roofAreaM2: 150),
    for (var f = 3; f >= 0; f--) node('RW$f', (600, 700), floor: f),
    node('RWOUT', (600, 1000), floor: 0), // RW0 → RWOUT = 300 px = 6.0 m
    // ── Fire: tank → fire pump → hydrant + sprinkler risers ──────────────
    node('FT', (1000, 1000), floor: 0, component: NodeComponent.groundTank),
    node('FP', (1000, 900), floor: 0, component: NodeComponent.pump),
    for (var f = 0; f < 4; f++) ...[
      node('H$f', (1150, 900), floor: f),
      node('HYD$f', (1250, 900),
          floor: f, component: NodeComponent.hydrantBox),
      node('S$f', (1000, 700), floor: f),
    ],
    for (var i = 1; i <= 6; i++)
      node('SP$i', (1000 + 150.0 * i, 700),
          floor: 3, component: NodeComponent.sprinklerHead),
    // ── HVAC (Lantai 2): FCU → 4 diffusers in a line; return grille ──────
    node(kOfficeFcuId, (1350, 250), floor: 1, component: NodeComponent.fcu),
    for (var i = 1; i <= 4; i++)
      node('SD$i', (1350, 250 + 150.0 * i),
          floor: 1,
          component: NodeComponent.supplyDiffuser,
          airflow: quarter,
          faceMm: kOfficeDiffuserFaceMm),
    // Backlog L-2 — two return grilles 3.0 m apart (150 px), half each.
    for (final (id, x) in [
      (kOfficeReturnGrilleId, 1450.0),
      (kOfficeReturnGrille2Id, 1600.0),
    ])
      node(id, (x, 250),
          floor: 1,
          component: NodeComponent.returnGrille,
          airflow: FlowRate(kOfficeRoomAirflow.cubicMetersPerSecond / 2),
          faceMm: kOfficeReturnFaceMm),
  ];

  const cw = ServiceType.coldWater;
  const dr = ServiceType.drainage;
  const rw = ServiceType.rainwater;
  const fh = ServiceType.fireHydrant;
  const sp = ServiceType.fireSprinkler;
  const riser = EdgeKind.riser;
  final edges = <NetEdge>[
    // Cold water — upfeed.
    _edge(cw, 'WM', 'GT'), // 150 px = 3.0 m
    _edge(cw, 'GT', 'P1'), // 50 px = 1.0 m
    _edge(cw, 'P1', 'R0'), // 100 px = 2.0 m
    for (var f = 1; f < 4; f++) _edge(cw, 'R${f - 1}', 'R$f', kind: riser),
    for (var f = 0; f < 4; f++) ...[
      _edge(cw, 'R$f', 'T$f'), // 150 px = 3.0 m
      for (final b in kOfficeFloorFixtures) _edge(cw, 'T$f', '$b$f'),
    ],
    // Drainage: fixture → floor junction → stack → outfall.
    for (var f = 0; f < 4; f++)
      for (final b in kOfficeFloorFixtures) _edge(dr, '$b$f', 'D$f'), // 1.5 m
    for (var f = 3; f > 0; f--) _edge(dr, 'D$f', 'D${f - 1}', kind: riser),
    _edge(dr, 'D0', 'OUT'), // 10.0 m
    // Vent: stack vent from the top-floor junction to the roof terminal.
    _edge(ServiceType.vent, 'D3', 'VTR', kind: riser),
    // Rainwater.
    _edge(rw, 'RDa', 'RW3'), // 100 px = 2.0 m
    _edge(rw, 'RDb', 'RW3'), // 100 px = 2.0 m
    for (var f = 3; f > 0; f--) _edge(rw, 'RW$f', 'RW${f - 1}', kind: riser),
    _edge(rw, 'RW0', 'RWOUT'), // 6.0 m
    // Fire — suction, hydrant riser + boxes, sprinkler riser + heads.
    _edge(fh, 'FT', 'FP'), // 100 px = 2.0 m
    _edge(fh, 'FP', 'H0'), // 150 px = 3.0 m
    for (var f = 1; f < 4; f++) _edge(fh, 'H${f - 1}', 'H$f', kind: riser),
    for (var f = 0; f < 4; f++) _edge(fh, 'H$f', 'HYD$f'), // 100 px = 2.0 m
    _edge(sp, 'FP', 'S0'), // 200 px = 4.0 m
    for (var f = 1; f < 4; f++) _edge(sp, 'S${f - 1}', 'S$f', kind: riser),
    _edge(sp, 'S3', 'SP1'), // 150 px = 3.0 m
    for (var i = 2; i <= 6; i++) _edge(sp, 'SP${i - 1}', 'SP$i'), // 3.0 m
    // HVAC — supply trunk FCU1 → SD1 → … → SD4 (150 px = 3.0 m each) and the
    // return ducts RG2 → RG1 (150 px = 3.0 m) and RG1 → FCU1 (100 px =
    // 2.0 m).
    _edge(ServiceType.duct, kOfficeFcuId, 'SD1'),
    for (var i = 2; i <= 4; i++)
      _edge(ServiceType.duct, 'SD${i - 1}', 'SD$i'),
    _edge(ServiceType.returnAir, kOfficeReturnGrille2Id,
        kOfficeReturnGrilleId),
    _edge(ServiceType.returnAir, kOfficeReturnGrilleId, kOfficeFcuId),
  ];
  return Network(nodes: nodes, edges: edges);
}

/// One way with the load kind's defaults (cos φ / demand factor, lighting
/// flag) — the same field defaults the app's `addCircuit` intent stamps.
ElectricalCircuit _way(String id, String name, LoadKind kind,
    {required double loadW, required double lengthM, int? phases}) {
  final d = loadDefaults[kind]!;
  return ElectricalCircuit(
    id: id,
    name: name,
    loadKind: kind,
    cosPhi: d.cosPhi,
    demandFactor: d.demandFactor,
    isLighting: kind == LoadKind.lighting,
    loadW: loadW,
    length: Length(lengthM),
    phases: phases,
    phasesUserSet: phases != null,
  );
}

/// The ONE service board (3-phase 400 V, PLN).
const String kOfficeMainPanelId = 'panel_lvmdp';

/// The four floor sub-boards (Lantai 1..4).
const List<String> kOfficeFloorTags = ['L1', 'L2', 'L3', 'L4'];
String officePanelId(String tag) => 'panel_pp_$tag';
String officeFeederId(String tag) => 'c_feeder_$tag';

/// Floor sub-board PP-<tag>: 3-phase 400 V, eight ways, fed from LVMDP.
ElectricalPanel _board(String tag) {
  String c(String base) => 'c_${base}_$tag';
  const lighting = LoadKind.lighting;
  const socket = LoadKind.socket;
  const hvac = LoadKind.hvac;
  return ElectricalPanel(
    id: officePanelId(tag),
    name: 'PP-$tag',
    system: ElectricalSystem.threePhase,
    voltage: const Voltage(400),
    sourceType: PanelSource.feeder,
    fedByCircuitId: officeFeederId(tag),
    circuits: [
      _way(c('lampu_a'), 'Lampu A', lighting, loadW: 1200, lengthM: 20),
      _way(c('lampu_b'), 'Lampu B', lighting, loadW: 1200, lengthM: 25),
      _way(c('kk_a'), 'Stop kontak A', socket, loadW: 2000, lengthM: 15),
      _way(c('kk_b'), 'Stop kontak B', socket, loadW: 2000, lengthM: 20),
      _way(c('kk_c'), 'Stop kontak C', socket, loadW: 2000, lengthM: 25),
      _way(c('ac_1'), 'AC 1', hvac, loadW: 3500, lengthM: 15, phases: 1),
      _way(c('ac_2'), 'AC 2', hvac, loadW: 3500, lengthM: 18, phases: 1),
      _way(c('ac_3'), 'AC 3', hvac, loadW: 3500, lengthM: 21, phases: 1),
    ],
  );
}

/// LVMDP: the service entrance, 3-phase 400 V, four feeder ways to the
/// floor sub-boards, manual 10 / 14 / 18 / 22 m. No phase is pinned.
ElectricalPanel _mainBoard() {
  const lengths = [10.0, 14.0, 18.0, 22.0];
  return ElectricalPanel(
    id: kOfficeMainPanelId,
    name: 'LVMDP',
    system: ElectricalSystem.threePhase,
    voltage: const Voltage(400),
    circuits: [
      for (var i = 0; i < kOfficeFloorTags.length; i++)
        ElectricalCircuit(
          id: officeFeederId(kOfficeFloorTags[i]),
          name: 'Feeder PP-${kOfficeFloorTags[i]}',
          loadKind: LoadKind.feeder,
          feedsPanelId: officePanelId(kOfficeFloorTags[i]),
          length: Length(lengths[i]),
        ),
    ],
  );
}

/// The office's electrical project: LVMDP feeding the four floor sub-boards,
/// default (TN-C-S) earthing, a declared 164 000 VA PLN connection, nothing
/// placed. No way for P1, FP or FCU1 is added by hand (the app's MEP sync
/// mints them).
ElectricalProject buildOfficeElectrical() => ElectricalProject(
      id: 'ref_office',
      name: 'Kantor 4 lantai',
      supplyKind: SupplyKind.pln,
      supplyCapacityVa: const ApparentPower(164000),
      panels: [_mainBoard(), for (final t in kOfficeFloorTags) _board(t)],
    );

/// Reference building 3 — the office.
ReferenceBuilding buildOffice() => ReferenceBuilding(
      name: 'Reference 3 - Office',
      building: const BuildingLevels([
        Floor('Lantai 1', Length(kOfficeFloorHeightM)),
        Floor('Lantai 2', Length(kOfficeFloorHeightM)),
        Floor('Lantai 3', Length(kOfficeFloorHeightM)),
        Floor('Lantai 4', Length(kOfficeFloorHeightM)),
      ]),
      sheets: [
        for (var f = 0; f < 4; f++)
          ReferenceSheet(
              id: kOfficeSheets[f], name: 'Lantai ${f + 1}', floorIndex: f),
      ],
      calibrations: {
        for (final s in kOfficeSheets)
          s: const ScaleCalibration(kOfficeMetersPerPixel),
      },
      network: buildOfficeNetwork(),
      electrical: buildOfficeElectrical(),
      occupancy: Occupancy.public,
    );
