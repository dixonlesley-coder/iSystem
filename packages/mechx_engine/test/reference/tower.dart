// Reference building 5 — a 30-storey OFFICE TOWER (gedung tinggi 30 lantai).
//
// A fixed, hand-checkable input set. Cold water: water meter → ground tank →
// transfer pump TP (with a mirrored parallel STANDBY pump TPS) → fill riser →
// roof tank; the roof tank feeds a top main `A` that splits into a BOOSTED
// branch (booster set → down-riser to the top three floors, index 29..27) and
// a GRAVITY down-riser to floors 26..0. Every floor carries the same public
// toilet core ([_typicalFloor]): a floor tee `T` with two flush-valve WCs, a
// urinal and two lavatories. Hot water on the top three floors: a water
// heater WH fed from BR29, a hot riser HW29 → HW27 to both lavatories of
// each of those floors. Drainage: one 30-storey soil stack to an outfall, one
// stack vent. Rainwater: four 200 m² roof drains, one downpipe. A separate
// FIRE network: fire tank → duty / standby / jockey pumps in parallel (as the
// apartment) → a header feeding TWO Class I hydrant risers (a box on every
// floor of each) and a sprinkler riser with six heads on the top floor. HVAC
// on floor index 15 ("Lantai 16"): an AHU office room (rectangular,
// equal-friction ducts) with eight supply diffusers and its return grilles,
// and an exhausted toilet with an exhaust fan and two exhaust grilles.
// Electrical: an MV service with a customer transformer, a standby genset,
// LVMDP, the essential board PP-E (three lifts, emergency lighting, the MEP
// machines) and thirty 3-phase floor boards PP-Lt1..30. Pure Dart (no
// Flutter import): the engine suite and the app suite build exactly this.
//
// GEOMETRY. Calibration is 0.02 m/px on all thirty sheets (50 px = 1 m).
// Every RUN's straight pixel span x 0.02 is the spec PLAN length exactly.
// Risers share x/y on their floors. The typical floor is built once by
// [_typicalFloor] (local ids suffixed with the floor index) and replicated.
// The floor tee T is 3.0 m from BOTH riser stacks (GR due west of T, BR on
// T's 3.0 m circle 2.0 m from GR); A is the GR–BR midpoint (1.0 m from each)
// and BS the apex of the 1.0 m equilateral triangle on A–BR. A fixture is
// BOTH the end of its cold branch from T (1.0 / 2.0 / 3.0 / 1.5 / 2.5 m) and
// the start of a 1.5 m drain to the stack D (2.0 m south of T), so it sits on
// the two circles' intersection ([_onCircles]), as in the office. The hot
// riser HW sits 4.5 m from LAVa and 5.5 m from LAVb; WH sits 2.0 m from both
// BR and HW.
//
// STANDBY TRANSFER PUMP. The app reads a supply standby from the DRAWING
// (`parallelStandbyPumps(legOnly: true)`, lib/store/electrical_feed.dart):
// a pump whose two legs share both ends with the duty pump (GT and U0) and
// that the sizer gave a MIRRORED set flow (`parallelLegEdgeIdsOut`). GT → TP
// → U0 is a straight 1.0 + 1.0 m, so the only point 1.0 m from both is TP
// itself: TPS is drawn on 1.5 + 1.5 m legs (the nearest mirrored leg), the
// one length that differs from the brief.
//
// WATER HEATER. The app has no heater component: a heater is a PLANT node
// with no component on both a cold and a hot pipe (`hotWaterHeaters`,
// network/hot_water_pressure.dart). It is not an electrical load
// (`NodeComponent.isElectricalLoad`), so no heater way is synced, and no
// provider sizes its capacity (kW / storage).
//
// RECIRCULATION. No return pipe or HW pump is drawn: the app ASSUMES one DN20
// return along the index path when the developed hot length exceeds 15 m
// (`hotWaterRecircSystemsProvider`), sizes its flow / head / pump from that
// and syncs a 'HW recirculation pump' MEP way.
//
// PRV. [buildTowerNetwork] takes the PRV station floors: each is a
// `NodeComponent.prv` node on the gravity riser, inserted between GR(k+1)
// and GRk: the riser GR(k+1) → PRVk lands on the PRV (floor k, at the riser's
// x/y) and a zero-length run PRVk → GRk joins it to the floor's riser node
// (there is no store intent that places a component on a riser — apartment
// backlog g). An empty list draws none (the BEFORE state).
//
// ROOMS. A room is an APP annotation (`RoomArea`), described here as plain
// data ([kTowerRooms]) and drawn by the app test through `roomAreasProvider`.
// The terminal airflows are the SAME `sizeRoomAir` call the app runs (the
// Room tool's seeded ceiling, the type's ACH, AHU / exhaust fan, rectangular
// equal-friction ducts) and the faces the smallest standard face within the
// app's terminal face-velocity band ([towerTerminalFace]).
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/air_velocity.dart'
    show kReturnFaceVelocityMax, kSupplyFaceVelocityMax;
import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart'
    show DuctShape, DuctSizingMethod;
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';

import 'reference_building.dart';

export 'reference_building.dart';

/// Number of storeys and the floor-to-floor height.
const int kTowerFloors = 30;
const double kTowerFloorHeightM = 4.0;

/// Sheet ids (one sheet per floor): `s_L1` .. `s_L30`.
final List<String> kTowerSheets = [
  for (var f = 0; f < kTowerFloors; f++) 's_L${f + 1}',
];

/// 0.02 m per pixel ⇒ 50 px = 1 m.
const double kTowerMetersPerPixel = 0.02;

/// The typical-floor fixtures (base ids; the id is `<base><floor>`).
const List<String> kTowerFixtures = ['WCa', 'WCb', 'UR', 'LAVa', 'LAVb'];

/// The fixture type of each base id. No flush-valve urinal type exists
/// (office backlog c): the urinal is `urinalFlushTank`.
const Map<String, PlumbingFixture> kTowerFixtureType = {
  'WCa': PlumbingFixture.waterClosetFlushValve,
  'WCb': PlumbingFixture.waterClosetFlushValve,
  'UR': PlumbingFixture.urinalFlushTank,
  'LAVa': PlumbingFixture.lavatory,
  'LAVb': PlumbingFixture.lavatory,
};

/// Plan length (m) of the cold branch T → fixture.
const Map<String, double> kTowerBranchM = {
  'WCa': 1.0,
  'WCb': 2.0,
  'UR': 3.0,
  'LAVa': 1.5,
  'LAVb': 2.5,
};

/// Plan length (m) of the hot branch HW → lavatory (top three floors).
const Map<String, double> kTowerHotBranchM = {'LAVa': 4.5, 'LAVb': 5.5};

/// Floors served by the boosted branch (index 29..27) and by gravity (26..0).
const List<int> kTowerBoostedFloors = [29, 28, 27];
final List<int> kTowerGravityFloors = [for (var f = 26; f >= 0; f--) f];

/// The riser node feeding floor [f]'s tee: `BR<f>` boosted, `GR<f>` gravity.
String towerRiserNode(int f) => f >= 27 ? 'BR$f' : 'GR$f';

/// Declared tank capacities (litres). No provider sizes a tank (office
/// backlog b), so they are the brief's values.
const double kTowerGroundTankL = 60000;
const double kTowerRoofTankL = 30000;
const double kTowerFireTankL = 120000;

/// The six sprinkler heads (top floor) and the fire pump room.
const List<String> kTowerSprinklerHeads = [
  'SP1', 'SP2', 'SP3', 'SP4', 'SP5', 'SP6', //
];
const String kTowerDutyFirePump = 'FP';
const String kTowerStandbyFirePump = 'FPS';
const String kTowerJockeyPump = 'FJ';
const String kTowerTransferPump = 'TP';
const String kTowerStandbyTransferPump = 'TPS';

/// The hand-picked bore of the jockey legs (mm), as in the apartment.
const double kTowerJockeyLegMm = 25;

/// The two hydrant risers.
const List<String> kTowerHydrantRisers = ['a', 'b'];

// ── HVAC (floor index 15, "Lantai 16") ───────────────────────────────────
const int kTowerHvacFloor = 15;
const String kTowerAhuId = 'AHU1';
const String kTowerExhaustFanId = 'EF1';
const List<String> kTowerDiffusers = [
  'SD1', 'SD2', 'SD3', 'SD4', 'SD5', 'SD6', 'SD7', 'SD8', //
];
const List<String> kTowerExhaustGrilles = ['EG1', 'EG2'];

/// The project duct settings the app test sets (`ductSettingsProvider`).
const DuctShape kTowerDuctShape = DuctShape.rectangular;
const DuctSizingMethod kTowerDuctMethod = DuctSizingMethod.equalFriction;

/// A room annotation as plain data.
class TowerRoom {
  final String name;
  final String sheetId;
  final int floorIndex;
  final double ax, ay, bx, by;
  final RoomType roomType;
  final AirEquipmentKind equipment;
  const TowerRoom({
    required this.name,
    required this.sheetId,
    required this.floorIndex,
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
    required this.roomType,
    required this.equipment,
  });

  double get widthM => (bx - ax).abs() * kTowerMetersPerPixel;
  double get depthM => (by - ay).abs() * kTowerMetersPerPixel;
}

/// Kantor: 20.0 m (1000 px) x 30.0 m (1500 px), AHU. Toilet: 4.0 m (200 px)
/// x 6.0 m (300 px), exhausted (extract room: the app gives it an exhaust
/// fan whatever the equipment field says). Both drawn clear of the plumbing
/// and fire nodes (the app test's sheets are 4200 x 1800 px).
const List<TowerRoom> kTowerRooms = [
  TowerRoom(
    name: 'Kantor',
    sheetId: 's_L16',
    floorIndex: kTowerHvacFloor,
    ax: 2500,
    ay: 150,
    bx: 3500,
    by: 1650,
    roomType: RoomType.office,
    equipment: AirEquipmentKind.ahu,
  ),
  TowerRoom(
    name: 'Toilet',
    sheetId: 's_L16',
    floorIndex: kTowerHvacFloor,
    ax: 3700,
    ay: 150,
    bx: 3900,
    by: 450,
    roomType: RoomType.toilet,
    equipment: AirEquipmentKind.fan,
  ),
];

/// The ceiling the app's Room tool seeds on a 4.0 m floor: floor-to-floor
/// less the default `MountingHeights.ceilingDrop` (0.3 m) = 3.7 m.
final double kTowerRoomCeilingM =
    kTowerFloorHeightM - const MountingHeights().ceilingDrop.meters;

/// A room's air sizing exactly as `RoomArea.sizing` runs it.
RoomAirResult towerRoomAir(TowerRoom r) {
  const v = SniVentilationProfile();
  return sizeRoomAir(
    floorArea: Area(r.widthM * r.depthM),
    ceilingHeight: Length(kTowerRoomCeilingM),
    airChangesPerHour: v.recommendedAch(r.roomType).value,
    equipmentKind: r.equipment,
    grilleApplication: v.grilleApplicationFor(r.roomType),
    ductShape: kTowerDuctShape,
    ductMethod: kTowerDuctMethod,
    extractOnly: isExtractRoomType(r.roomType),
  );
}

/// The office room's sized supply airflow (supply = return).
final FlowRate kTowerOfficeAirflow = towerRoomAir(kTowerRooms[0]).airflow;

/// The toilet's sized exhaust airflow.
final FlowRate kTowerToiletAirflow = towerRoomAir(kTowerRooms[1]).airflow;

/// The smallest standard face (`standardGrilleFacesMm`) whose face velocity
/// over the 0.8 free area stays within [maxFace] (the air-velocity checker's
/// band, `air_velocity.dart`: supply 3.0 m/s, return / exhaust 4.0 m/s);
/// null when no standard face can carry [q].
(double, double)? towerTerminalFace(FlowRate q, Velocity maxFace) {
  final faces = [...standardGrilleFacesMm]
    ..sort((a, b) => (a.$1 * a.$2).compareTo(b.$1 * b.$2));
  for (final f in faces) {
    final v = q.cubicMetersPerSecond / (f.$1 * f.$2 / 1e6 * 0.8);
    if (v <= maxFace.metersPerSecond + 1e-12) return f;
  }
  return null;
}

/// The fewest equal return grilles whose share a standard face carries
/// within the 4.0 m/s return band.
int _returnGrilleCount() {
  for (var n = 1; n < 100; n++) {
    final q = FlowRate(kTowerOfficeAirflow.cubicMetersPerSecond / n);
    if (towerTerminalFace(q, kReturnFaceVelocityMax) != null) return n;
  }
  throw StateError('no return grille count');
}

/// The return grilles RG1..RGn (n = [_returnGrilleCount]).
final List<String> kTowerReturnGrilles = [
  for (var i = 1; i <= _returnGrilleCount(); i++) 'RG$i',
];

/// The stamped terminal airflows and faces.
final FlowRate kTowerDiffuserFlow =
    FlowRate(kTowerOfficeAirflow.cubicMetersPerSecond / kTowerDiffusers.length);
final FlowRate kTowerReturnFlow = FlowRate(
    kTowerOfficeAirflow.cubicMetersPerSecond / kTowerReturnGrilles.length);
final FlowRate kTowerExhaustFlow = FlowRate(
    kTowerToiletAirflow.cubicMetersPerSecond / kTowerExhaustGrilles.length);
final (double, double) kTowerDiffuserFaceMm =
    towerTerminalFace(kTowerDiffuserFlow, kSupplyFaceVelocityMax)!;
final (double, double) kTowerReturnFaceMm =
    towerTerminalFace(kTowerReturnFlow, kReturnFaceVelocityMax)!;
final (double, double) kTowerExhaustFaceMm =
    towerTerminalFace(kTowerExhaustFlow, kReturnFaceVelocityMax)!;

/// The point at distance [ra] px from [a] AND [rb] px from [b] nearest
/// [near] (two circles' intersection; tangent when h = 0).
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

double _px(double meters) => meters / kTowerMetersPerPixel;

/// Edge id convention: `e_<svc>_<from>_<to>`.
NetEdge _edge(ServiceType s, String from, String to,
    {EdgeKind kind = EdgeKind.run, Diameter? sizeOverride}) {
  final tag = switch (s) {
    ServiceType.coldWater => 'cw',
    ServiceType.hotWater => 'hw',
    ServiceType.drainage => 'dr',
    ServiceType.vent => 'vt',
    ServiceType.rainwater => 'rw',
    ServiceType.fireHydrant => 'fh',
    ServiceType.fireSprinkler => 'sp',
    ServiceType.duct => 'sa',
    ServiceType.returnAir => 'ra',
    ServiceType.exhaust => 'ea',
  };
  return NetEdge(
      id: 'e_${tag}_${from}_$to',
      fromId: from,
      toId: to,
      service: s,
      kind: kind,
      sizeOverride: sizeOverride);
}

// ── Plan positions (px) ───────────────────────────────────────────────────
// Floor tee T; its drainage stack D 2.0 m south; the gravity riser GR 3.0 m
// due west of T; the booster riser BR on T's 3.0 m circle, 2.0 m from GR.
const _t = (400.0, 700.0);
const _d = (400.0, 800.0);
const _gr = (250.0, 700.0);
final (double, double) _br = _onCircles(_t, 150, _gr, 100, (290, 600));
// A: the GR–BR midpoint (1.0 m from each); BS 1.0 m from both A and BR.
final (double, double) _a = ((_gr.$1 + _br.$1) / 2, (_gr.$2 + _br.$2) / 2);
final (double, double) _bs = _onCircles(_a, 50, _br, 50, (200, 600));
// RT 2.0 m west of A; the fill riser U 2.0 m south of RT; TP, GT, WM below.
final (double, double) _rt = (_a.$1 - 100, _a.$2);
final (double, double) _u = (_rt.$1, _rt.$2 + 100);
final (double, double) _tp = (_u.$1, _u.$2 + 50);
final (double, double) _gt = (_tp.$1, _tp.$2 + 50);
final (double, double) _wm = (_gt.$1, _gt.$2 + 150);
// TPS: 1.5 m from both GT and U0 (the mirrored standby leg), west of TP.
final (double, double) _tps =
    _onCircles(_gt, 75, _u, 75, (_tp.$1 - 60, _tp.$2));
// Fixtures: on T's branch circle AND D's 1.5 m circle (office hints).
final Map<String, (double, double)> _fixtureAt = {
  'WCa': _onCircles(_t, _px(1.0), _d, _px(1.5), (_t.$1 - 50, _t.$2 + 30)),
  'WCb': _onCircles(_t, _px(2.0), _d, _px(1.5), (_t.$1 - 80, _t.$2 + 60)),
  'UR': _onCircles(_t, _px(3.0), _d, _px(1.5), (_t.$1 + 140, _t.$2 + 120)),
  'LAVa': _onCircles(_t, _px(1.5), _d, _px(1.5), (_t.$1 + 70, _t.$2 + 50)),
  'LAVb': _onCircles(_t, _px(2.5), _d, _px(1.5), (_t.$1 + 100, _t.$2 + 90)),
};
// The hot riser HW: 4.5 m from LAVa and 5.5 m from LAVb; WH 2.0 m from both
// BR (its cold feed) and HW.
final (double, double) _hw = _onCircles(
    _fixtureAt['LAVa']!, _px(4.5), _fixtureAt['LAVb']!, _px(5.5), (250, 600));
final (double, double) _wh = _onCircles(_br, 100, _hw, 100, (150, 550));
// The drainage outfall OUT 10.0 m south of D.
final (double, double) _out = (_d.$1, _d.$2 + 500);

// Rainwater: RW and four roof drains 2.0 m N / E / S / W of it.
const _rw = (1000.0, 300.0);
const Map<String, (double, double)> _rd = {
  'RDa': (900.0, 300.0),
  'RDb': (1100.0, 300.0),
  'RDc': (1000.0, 200.0),
  'RDd': (1000.0, 400.0),
};

// Fire pump room (as the apartment) and the two hydrant risers.
const _ft = (1300.0, 1300.0);
const _fh = (1300.0, 1100.0);
const Map<String, (double, double)> _hRiser = {
  'a': (1450.0, 1100.0), // 3.0 m east of FH
  'b': (1000.0, 1100.0), // 6.0 m west of FH
};
const Map<String, (double, double)> _hyd = {
  'a': (1550.0, 1100.0), // 2.0 m east of Ha
  'b': (900.0, 1100.0), // 2.0 m west of Hb
};
const _s = (1300.0, 900.0);

// HVAC (floor 15): AHU1 inside Kantor; SD1..SD8 south of it 3.0 m apart; RG1..
// east of it 3.0 m apart. EF1 in the toilet's NW corner; EG1, EG2 along the
// toilet diagonal 3.0 m apart.
const _ahu = (2600.0, 300.0);
const _ef = (3705.0, 155.0);
final double _diag = math.sqrt(4 * 4 + 6 * 6);
final (double, double) _efStep = (150 * 4 / _diag, 150 * 6 / _diag);

/// The cold-water + drainage nodes and edges of one typical floor [f], fed
/// from its riser node ([towerRiserNode]).
(List<NetNode>, List<NetEdge>) _typicalFloor(
    int f,
    NetNode Function(String, (double, double),
            {required int floor, PlumbingFixture? fixture})
        node) {
  const cw = ServiceType.coldWater;
  const dr = ServiceType.drainage;
  final nodes = <NetNode>[
    node('T$f', _t, floor: f),
    for (final b in kTowerFixtures)
      node('$b$f', _fixtureAt[b]!, floor: f, fixture: kTowerFixtureType[b]),
    node('D$f', _d, floor: f),
  ];
  final edges = <NetEdge>[
    _edge(cw, towerRiserNode(f), 'T$f'), // 150 px = 3.0 m
    for (final b in kTowerFixtures) _edge(cw, 'T$f', '$b$f'),
    for (final b in kTowerFixtures) _edge(dr, '$b$f', 'D$f'), // 1.5 m
  ];
  return (nodes, edges);
}

/// The tower's mechanical + fire + HVAC network. [prvFloors] draws a PRV
/// station on the gravity riser at each floor index k (between GR(k+1) and
/// GRk); empty draws none.
Network buildTowerNetwork({List<int> prvFloors = const []}) {
  NetNode node(
    String id,
    (double, double) at, {
    required int floor,
    NodeRole? role,
    NodeComponent? component,
    PlumbingFixture? fixture,
    double? roofAreaM2,
    double? tankL,
    FlowRate? airflow,
    (double, double)? faceMm,
  }) =>
      NetNode(
        id: id,
        sheetId: kTowerSheets[floor],
        x: at.$1,
        y: at.$2,
        floorIndex: floor,
        role: role ??
            component?.role ??
            (fixture != null ? NodeRole.fixture : NodeRole.main),
        component: component,
        fixture: fixture,
        roofAreaM2: roofAreaM2,
        tankCapacityLitres: tankL,
        airflow: airflow,
        faceWidthMm: faceMm?.$1,
        faceHeightMm: faceMm?.$2,
      );
  NetNode plain(String id, (double, double) at,
          {required int floor, PlumbingFixture? fixture}) =>
      node(id, at, floor: floor, fixture: fixture);

  const top = kTowerFloors - 1;
  const cw = ServiceType.coldWater;
  const hw = ServiceType.hotWater;
  const dr = ServiceType.drainage;
  const rw = ServiceType.rainwater;
  const fh = ServiceType.fireHydrant;
  const sp = ServiceType.fireSprinkler;
  const riser = EdgeKind.riser;
  const hv = kTowerHvacFloor;

  final nodes = <NetNode>[
    // ── Cold water: fill line meter → GT → TP / TPS → riser U → RT ─────────
    node('WM', _wm, floor: 0, component: NodeComponent.waterMeter),
    node('GT', _gt,
        floor: 0,
        component: NodeComponent.groundTank,
        tankL: kTowerGroundTankL),
    node(kTowerTransferPump, _tp, floor: 0, component: NodeComponent.pump),
    node(kTowerStandbyTransferPump, _tps,
        floor: 0, component: NodeComponent.pump),
    for (var f = 0; f <= top; f++) node('U$f', _u, floor: f),
    node('RT', _rt,
        floor: top, component: NodeComponent.roofTank, tankL: kTowerRoofTankL),
    // RT → top main A → booster BS → BR riser; A → GR riser.
    node('A', _a, floor: top),
    node('BS', _bs, floor: top, component: NodeComponent.boosterSet),
    for (final f in kTowerBoostedFloors) node('BR$f', _br, floor: f),
    for (var f = top; f >= 0; f--) node('GR$f', _gr, floor: f),
    for (final k in prvFloors)
      node('PRV$k', _gr, floor: k, component: NodeComponent.prv),
    // ── Hot water (top three floors): heater WH → hot riser HW ───────────
    node('WH', _wh, floor: top, role: NodeRole.plant),
    for (final f in kTowerBoostedFloors) node('HW$f', _hw, floor: f),
    // Drainage outfall + vent terminal.
    node('OUT', _out, floor: 0),
    node('VTR', _d, floor: top),
    // ── Rainwater ──────────────────────────────────────────────────────
    for (final MapEntry(:key, :value) in _rd.entries)
      node(key, value,
          floor: top, component: NodeComponent.roofDrain, roofAreaM2: 200),
    for (var f = top; f >= 0; f--) node('RW$f', _rw, floor: f),
    node('RWOUT', (_rw.$1, _rw.$2 + 300), floor: 0), // 300 px = 6.0 m
    // ── Fire: tank → duty / standby / jockey → header → risers ───────────
    node('FT', _ft,
        floor: 0, component: NodeComponent.groundTank, tankL: kTowerFireTankL),
    node(kTowerDutyFirePump, (1300, 1200),
        floor: 0, component: NodeComponent.pump),
    node(kTowerStandbyFirePump, (1300 + math.sqrt(150 * 150 - 100 * 100), 1200),
        floor: 0, component: NodeComponent.pump),
    node(kTowerJockeyPump, (1300 - math.sqrt(150 * 150 - 100 * 100), 1200),
        floor: 0, component: NodeComponent.pump),
    node('FH', _fh, floor: 0),
    for (var f = 0; f <= top; f++) ...[
      for (final r in kTowerHydrantRisers) ...[
        node('H$r$f', _hRiser[r]!, floor: f),
        node('HYD$r$f', _hyd[r]!,
            floor: f, component: NodeComponent.hydrantBox),
      ],
      node('S$f', _s, floor: f),
    ],
    for (var i = 1; i <= 6; i++)
      node('SP$i', (_s.$1 + 150.0 * i, _s.$2),
          floor: top, component: NodeComponent.sprinklerHead),
    // ── HVAC (floor 15) ──────────────────────────────────────────────────
    node(kTowerAhuId, _ahu, floor: hv, component: NodeComponent.ahu),
    for (var i = 1; i <= kTowerDiffusers.length; i++)
      node('SD$i', (_ahu.$1, _ahu.$2 + 150.0 * i),
          floor: hv,
          component: NodeComponent.supplyDiffuser,
          airflow: kTowerDiffuserFlow,
          faceMm: kTowerDiffuserFaceMm),
    for (var i = 1; i <= kTowerReturnGrilles.length; i++)
      node('RG$i', (_ahu.$1 + 150.0 * i, _ahu.$2),
          floor: hv,
          component: NodeComponent.returnGrille,
          airflow: kTowerReturnFlow,
          faceMm: kTowerReturnFaceMm),
    node(kTowerExhaustFanId, _ef,
        floor: hv, component: NodeComponent.exhaustFan),
    for (var i = 1; i <= kTowerExhaustGrilles.length; i++)
      node('EG$i', (_ef.$1 + _efStep.$1 * i, _ef.$2 + _efStep.$2 * i),
          floor: hv,
          component: NodeComponent.exhaustGrille,
          airflow: kTowerExhaustFlow,
          faceMm: kTowerExhaustFaceMm),
  ];

  final edges = <NetEdge>[
    // Fill line (duty TP 1.0 + 1.0 m; standby TPS 1.5 + 1.5 m).
    _edge(cw, 'WM', 'GT'), // 150 px = 3.0 m
    _edge(cw, 'GT', kTowerTransferPump), // 50 px = 1.0 m
    _edge(cw, kTowerTransferPump, 'U0'), // 50 px = 1.0 m
    _edge(cw, 'GT', kTowerStandbyTransferPump), // 75 px = 1.5 m
    _edge(cw, kTowerStandbyTransferPump, 'U0'), // 75 px = 1.5 m
    for (var f = 1; f <= top; f++) _edge(cw, 'U${f - 1}', 'U$f', kind: riser),
    _edge(cw, 'U$top', 'RT'), // 100 px = 2.0 m
    _edge(cw, 'RT', 'A'), // 100 px = 2.0 m
    // Boosted branch.
    _edge(cw, 'A', 'BS'), // 50 px = 1.0 m
    _edge(cw, 'BS', 'BR$top'), // 50 px = 1.0 m
    for (var i = 1; i < kTowerBoostedFloors.length; i++)
      _edge(
          cw, 'BR${kTowerBoostedFloors[i - 1]}', 'BR${kTowerBoostedFloors[i]}',
          kind: riser),
    // Gravity riser (no branch on 29..27), the PRV stations spliced in.
    _edge(cw, 'A', 'GR$top'), // 50 px = 1.0 m
    for (var f = top; f > 0; f--)
      if (prvFloors.contains(f - 1)) ...[
        _edge(cw, 'GR$f', 'PRV${f - 1}', kind: riser),
        _edge(cw, 'PRV${f - 1}', 'GR${f - 1}'), // 0 px (same x/y)
      ] else
        _edge(cw, 'GR$f', 'GR${f - 1}', kind: riser),
    // Hot water: BR29 → WH (cold feed), WH → HW29, hot riser, lavatories.
    _edge(cw, 'BR$top', 'WH'), // 100 px = 2.0 m
    _edge(hw, 'WH', 'HW$top'), // 100 px = 2.0 m
    for (var i = 1; i < kTowerBoostedFloors.length; i++)
      _edge(
          hw, 'HW${kTowerBoostedFloors[i - 1]}', 'HW${kTowerBoostedFloors[i]}',
          kind: riser),
    for (final f in kTowerBoostedFloors)
      for (final b in kTowerHotBranchM.keys) _edge(hw, 'HW$f', '$b$f'),
  ];
  // Every floor's typical cold-water + drainage branch.
  for (var f = 0; f <= top; f++) {
    final (n, e) = _typicalFloor(f, plain);
    nodes.addAll(n);
    edges.addAll(e);
  }
  edges.addAll([
    // Drainage stack → outfall; one stack vent.
    for (var f = top; f > 0; f--) _edge(dr, 'D$f', 'D${f - 1}', kind: riser),
    _edge(dr, 'D0', 'OUT'), // 500 px = 10.0 m
    _edge(ServiceType.vent, 'D$top', 'VTR', kind: riser),
    // Rainwater.
    for (final id in _rd.keys) _edge(rw, id, 'RW$top'), // 100 px = 2.0 m
    for (var f = top; f > 0; f--) _edge(rw, 'RW$f', 'RW${f - 1}', kind: riser),
    _edge(rw, 'RW0', 'RWOUT'), // 6.0 m
    // Fire: the pump room (duty 2.0 + 2.0 m; standby and jockey 3.0 + 3.0 m,
    // the jockey legs hand-picked DN25).
    _edge(fh, 'FT', kTowerDutyFirePump),
    _edge(fh, kTowerDutyFirePump, 'FH'),
    _edge(fh, 'FT', kTowerStandbyFirePump),
    _edge(fh, kTowerStandbyFirePump, 'FH'),
    _edge(fh, 'FT', kTowerJockeyPump,
        sizeOverride: Diameter.mm(kTowerJockeyLegMm)),
    _edge(fh, kTowerJockeyPump, 'FH',
        sizeOverride: Diameter.mm(kTowerJockeyLegMm)),
    // Two hydrant risers + a box per floor on each.
    _edge(fh, 'FH', 'Ha0'), // 150 px = 3.0 m
    _edge(fh, 'FH', 'Hb0'), // 300 px = 6.0 m
    for (final r in kTowerHydrantRisers) ...[
      for (var f = 1; f <= top; f++)
        _edge(fh, 'H$r${f - 1}', 'H$r$f', kind: riser),
      for (var f = 0; f <= top; f++) _edge(fh, 'H$r$f', 'HYD$r$f'), // 2.0 m
    ],
    // Sprinkler riser + six heads on the top floor.
    _edge(sp, 'FH', 'S0'), // 200 px = 4.0 m
    for (var f = 1; f <= top; f++) _edge(sp, 'S${f - 1}', 'S$f', kind: riser),
    _edge(sp, 'S$top', 'SP1'), // 150 px = 3.0 m
    for (var i = 2; i <= 6; i++) _edge(sp, 'SP${i - 1}', 'SP$i'), // 3.0 m
    // HVAC — supply trunk AHU1 → SD1 → … → SD8 (3.0 m each); return RGn →
    // … → RG1 → AHU1 (3.0 m each); exhaust EF1 → EG1 → EG2 (3.0 m each).
    _edge(ServiceType.duct, kTowerAhuId, 'SD1'),
    for (var i = 2; i <= kTowerDiffusers.length; i++)
      _edge(ServiceType.duct, 'SD${i - 1}', 'SD$i'),
    for (var i = kTowerReturnGrilles.length; i >= 2; i--)
      _edge(ServiceType.returnAir, 'RG$i', 'RG${i - 1}'),
    _edge(ServiceType.returnAir, 'RG1', kTowerAhuId),
    _edge(ServiceType.exhaust, kTowerExhaustFanId, 'EG1'),
    for (var i = 2; i <= kTowerExhaustGrilles.length; i++)
      _edge(ServiceType.exhaust, 'EG${i - 1}', 'EG$i'),
  ]);
  return Network(nodes: nodes, edges: edges);
}

/// One way with the load kind's defaults (cos φ / demand factor, lighting
/// flag) — the same field defaults the app's `addCircuit` intent stamps (a
/// motor way: loadW 0 + motorKw).
ElectricalCircuit _way(String id, String name, LoadKind kind,
    {double loadW = 0,
    double? motorKw,
    required double lengthM,
    int? phases,
    String? cableType}) {
  final d = loadDefaults[kind]!;
  return ElectricalCircuit(
    id: id,
    name: name,
    loadKind: kind,
    cosPhi: d.cosPhi,
    demandFactor: d.demandFactor,
    isLighting: kind == LoadKind.lighting,
    loadW: loadW,
    motorKw: motorKw,
    length: Length(lengthM),
    phases: phases,
    phasesUserSet: phases != null,
    cableType: cableType,
  );
}

/// Panel ids.
const String kTowerMainPanelId = 'panel_lvmdp';
const String kTowerEssentialPanelId = 'panel_pp_e';
const String kTowerEssentialFeederId = 'c_feeder_pp_e';
String towerFloorPanelId(int f) => 'panel_pp_lt${f + 1}';
String towerFloorFeederId(int f) => 'c_feeder_lt${f + 1}';

/// The essential board's ways.
const List<String> kTowerLiftWayIds = ['c_lift_1', 'c_lift_2', 'c_lift_3'];
const String kTowerEmergencyLightWayId = 'c_lampu_darurat';

/// Floor board PP-Lt<f+1>: 3-phase 400 V, eight ways, fed from LVMDP.
ElectricalPanel _floorBoard(int f) {
  final t = 'lt${f + 1}';
  String c(String base) => 'c_${base}_$t';
  const lighting = LoadKind.lighting;
  const socket = LoadKind.socket;
  const hvac = LoadKind.hvac;
  return ElectricalPanel(
    id: towerFloorPanelId(f),
    name: 'PP-Lt${f + 1}',
    system: ElectricalSystem.threePhase,
    voltage: const Voltage(400),
    sourceType: PanelSource.feeder,
    fedByCircuitId: towerFloorFeederId(f),
    circuits: [
      _way(c('lampu_a'), 'Lampu A', lighting,
          loadW: 1500, lengthM: 20, phases: 1),
      _way(c('lampu_b'), 'Lampu B', lighting,
          loadW: 1500, lengthM: 25, phases: 1),
      _way(c('lampu_c'), 'Lampu C', lighting,
          loadW: 1500, lengthM: 30, phases: 1),
      _way(c('kk_a'), 'Stop kontak A', socket,
          loadW: 2500, lengthM: 15, phases: 1),
      _way(c('kk_b'), 'Stop kontak B', socket,
          loadW: 2500, lengthM: 20, phases: 1),
      _way(c('kk_c'), 'Stop kontak C', socket,
          loadW: 2500, lengthM: 25, phases: 1),
      _way(c('ac_a'), 'AC A', hvac, loadW: 5000, lengthM: 20, phases: 3),
      _way(c('ac_b'), 'AC B', hvac, loadW: 5000, lengthM: 25, phases: 3),
    ],
  );
}

/// PP-E: the essential (genset-backed) board, 3-phase 400 V, fed from LVMDP
/// over a 20 m FRC feeder; three lifts and the emergency lighting by hand
/// (the MEP machines arrive with the MEP board the app re-feeds onto it).
ElectricalPanel _essentialBoard() => ElectricalPanel(
      id: kTowerEssentialPanelId,
      name: 'PP-E',
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      sourceType: PanelSource.feeder,
      fedByCircuitId: kTowerEssentialFeederId,
      essential: true,
      circuits: [
        for (var i = 0; i < kTowerLiftWayIds.length; i++)
          _way(kTowerLiftWayIds[i], 'Lift ${i + 1}', LoadKind.motor,
              motorKw: 15, lengthM: 60, phases: 3),
        _way(kTowerEmergencyLightWayId, 'Lampu darurat', LoadKind.lighting,
            loadW: 2000, lengthM: 50, phases: 1),
      ],
    );

/// LVMDP: the service entrance, 3-phase 400 V: the PP-E feeder (20 m, FRC)
/// and thirty floor feeders, manual 15 + 4 x floor index m.
ElectricalPanel _mainBoard() => ElectricalPanel(
      id: kTowerMainPanelId,
      name: 'LVMDP',
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      circuits: [
        const ElectricalCircuit(
          id: kTowerEssentialFeederId,
          name: 'Feeder PP-E',
          loadKind: LoadKind.feeder,
          feedsPanelId: kTowerEssentialPanelId,
          length: Length(20),
          cableType: 'FRC',
        ),
        for (var f = 0; f < kTowerFloors; f++)
          ElectricalCircuit(
            id: towerFloorFeederId(f),
            name: 'Feeder PP-Lt${f + 1}',
            loadKind: LoadKind.feeder,
            feedsPanelId: towerFloorPanelId(f),
            length: Length(15 + 4.0 * f),
          ),
      ],
    );

/// The app-recommended supply, read from the app's own recommendation on a
/// run with none declared (the app test's BEFORE container) and set here;
/// pass null to any to read it again. Pass 2 (after T1–T4): the 998.8 kVA
/// demand (worst-phase basis 1003.3 kVA) is above the 197 kVA LV ceiling, so
/// `electricalAdvancedProvider.supply` prescribes an MV (20 kV) service on
/// the smallest ladder transformer loaded <= 80 %: 1003.3 / 0.8 = 1254 kVA ⇒
/// 1600 kVA (62.4 %). On MV `recommendedDayaVa` is null, so no PLN daya is
/// declared (the declared rating is the transformer). The unforced genset
/// sizing `sizeGenerator(gensetBackupDemandVa, minKvaForStart:
/// gensetStartFloorFor)` = 1 x 800 kVA (backup 360.6 kVA; the 200 kW fire
/// pump's start floor 764.77 kVA governs; pass 1: 1000 kVA on the 250 kW
/// pump). The power-factor study reads PF 0.867 (above the 0.85 PLN penalty,
/// `needed` false) and quotes 213.6 kvar ⇒ a 250 kvar bank to reach 0.95:
/// that bank is declared (`capacitorBankKvar`). The figures are unchanged
/// when re-read after declaring.
const double? kTowerDeclaredPlnVa = null;
const double? kTowerTransformerKva = 1600;
const double? kTowerGensetKva = 800;
const double? kTowerCapacitorKvar = 250;

/// The tower's electrical project.
ElectricalProject buildTowerElectrical({
  double? declaredPlnVa = kTowerDeclaredPlnVa,
  double? transformerKva = kTowerTransformerKva,
  double? gensetKva = kTowerGensetKva,
  double? capacitorKvar = kTowerCapacitorKvar,
}) =>
    ElectricalProject(
      id: 'ref_tower',
      name: 'Gedung kantor 30 lantai',
      supplyKind: SupplyKind.pln,
      supplyCapacityVa:
          declaredPlnVa == null ? null : ApparentPower(declaredPlnVa),
      transformerKva: transformerKva == null
          ? null
          : ApparentPower.kilovoltAmperes(transformerKva),
      capacitorBankKvar: capacitorKvar,
      sources: ElectricalSources(
        generator: GeneratorSource(
          kva: gensetKva == null
              ? null
              : ApparentPower.kilovoltAmperes(gensetKva),
        ),
      ),
      panels: [
        _mainBoard(),
        _essentialBoard(),
        for (var f = 0; f < kTowerFloors; f++) _floorBoard(f),
      ],
    );

/// The app-prescribed PRV station floors: with no PRV drawn the zone table
/// (`zonesProvider`) reads [20-29, 17-19, 14-16, 11-13, 8-10, 5-7, 2-4, 0-1]
/// — floors 20..29 straight from the roof tank (the boosted 27..29 at the
/// booster's datum), then seven PRV zones of three floors (two at the
/// bottom), each fed at the 255 kPa setpoint — and the solve raises 100
/// `downfeed-over-pressure` findings on floors 0..19. So a station sits at
/// the TOP of each PRV zone, on the gravity riser above floor 19, 16, 13,
/// 10, 7, 4 and 1 (seven PRVs in series).
const List<int> kTowerPrvFloors = [19, 16, 13, 10, 7, 4, 1];

/// Reference building 5 — the office tower.
ReferenceBuilding buildTower({List<int> prvFloors = kTowerPrvFloors}) =>
    ReferenceBuilding(
      name: 'Reference 5 - Tower',
      building: BuildingLevels([
        for (var f = 0; f < kTowerFloors; f++)
          Floor('Lantai ${f + 1}', const Length(kTowerFloorHeightM)),
      ]),
      sheets: [
        for (var f = 0; f < kTowerFloors; f++)
          ReferenceSheet(
              id: kTowerSheets[f], name: 'Lantai ${f + 1}', floorIndex: f),
      ],
      calibrations: {
        for (final s in kTowerSheets)
          s: const ScaleCalibration(kTowerMetersPerPixel),
      },
      network: buildTowerNetwork(prvFloors: prvFloors),
      electrical: buildTowerElectrical(),
      occupancy: Occupancy.public,
    );
