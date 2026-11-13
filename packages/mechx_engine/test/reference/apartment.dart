// Reference building 4 — a 12-storey APARTMENT block (rumah susun 12 lantai).
//
// A fixed, hand-checkable input set. Cold water: water meter → ground tank →
// transfer pump → fill riser → roof tank; the roof tank feeds a top main `A`
// that splits into a BOOSTED side branch (booster set → down-riser to the top
// two floors) and a GRAVITY down-riser to floors 10..1 (index 9..0). Every
// floor carries the same two-unit apartment layout ([_typicalFloor]): a floor
// main `M` and two unit branches `Ka` / `Kb`, each with a WC (flush tank),
// lavatory, shower and kitchen sink. Drainage: two soil stacks (one per unit
// column) to a junction and an outfall, one stack vent each. Rainwater: two
// 200 m² roof drains, one downpipe. A separate FIRE network: fire tank → duty
// fire pump + standby pump + jockey pump in parallel → a header that feeds a
// Class I hydrant riser (one box per floor) and a sprinkler riser with six
// heads on Lantai 12. HVAC on Lantai 6: two bedrooms with one split-wall AC
// each. Electrical: a 3-phase service board LVMDP (PLN + a standby genset),
// an essential board PP-E (lift, emergency lighting, the MEP machines) and
// twelve 3-phase floor boards PP-Lt1..12. Pure Dart (no Flutter import): the
// engine suite and the app suite (relative import) build exactly this.
//
// GEOMETRY. Calibration is 0.02 m/px on all twelve sheets (50 px = 1 m).
// Every RUN's straight pixel span x 0.02 is the spec PLAN length exactly.
// Risers share x/y on their floors. The typical floor is built once by
// [_typicalFloor] (local ids suffixed with the floor index) and replicated on
// every floor, so every floor is identical up to its riser feed (the booster
// riser BR on floors 11 / 10, the gravity riser GR below). The two riser
// stacks are 2.0 m from the floor main M (GR due west of M, BR due
// south of M); A sits 1.0 m from GR11 on the GR → BR line and BS on the
// circle intersection that keeps A → BS and BS → BR11 at 1.0 m. A fixture
// is BOTH the end of its cold branch from `K` (1.0 / 1.5 / 2.0 / 4.0 m) AND the start of a 1.5 m drain to
// the unit stack `D`, so it sits on the intersection of the two circles
// ([_onCircles]); K → D is 2.5 m (the only distance the 4.0 m sink and the
// 1.0 m WC both reach), so the WC and the sink lie on the K–D line.
//
// FIRE PUMP ROOM. The app reads duty / standby / jockey from the DRAWING
// (`parallelFirePumpRoles`, lib/store/electrical_feed.dart): pumps whose legs
// share both ends (FT and FH) are one parallel set; the pump on the largest
// bore is the duty, a pump on a strictly SMALLER leg is the jockey, any
// other pump the standby. So FP (2.0 + 2.0 m, axis-aligned, as specified),
// FPS (standby, 3.0 + 3.0 m) and FJ (jockey, 3.0 + 3.0 m, both legs given a
// hand-picked DN25 `sizeOverride` — the app's "drawn smaller leg") are drawn
// between FT and FH. There is no jockey / standby component or flag.
//
// PRV. [buildApartmentNetwork] takes the floor index of the drawn PRV: the
// app-prescribed station (see the app test's zone table) is a
// `NodeComponent.prv` node on the gravity riser, inserted between GR(k+1)
// and GRk: the riser GR(k+1) → PRVk lands on the PRV (floor k, at the riser's
// x/y) and a zero-length run PRVk → GRk joins it to the floor's riser node.
// `null` draws none (the BEFORE state).
//
// ROOMS. A room is an APP annotation (`RoomArea`), described here as plain
// data ([kApartmentRooms]) and drawn by the app test through
// `roomAreasProvider`.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart' show RoomType;
import 'package:mechx_engine/units.dart';

import 'reference_building.dart';

export 'reference_building.dart';

/// Number of storeys and the floor-to-floor height.
const int kAptFloors = 12;
const double kAptFloorHeightM = 3.5;

/// Sheet ids (one sheet per floor): `s_L1` .. `s_L12`.
final List<String> kAptSheets = [
  for (var f = 0; f < kAptFloors; f++) 's_L${f + 1}',
];

/// 0.02 m per pixel ⇒ 50 px = 1 m.
const double kAptMetersPerPixel = 0.02;

/// The two units per floor.
const List<String> kAptUnits = ['a', 'b'];

/// The per-unit fixtures (base ids; the id is `<base><unit><floor>`).
const List<String> kAptFixtures = ['WC', 'LAV', 'SH', 'KS'];

/// The fixture type of each base id.
const Map<String, PlumbingFixture> kAptFixtureType = {
  'WC': PlumbingFixture.waterClosetFlushTank,
  'LAV': PlumbingFixture.lavatory,
  'SH': PlumbingFixture.shower,
  'KS': PlumbingFixture.kitchenSink,
};

/// Plan length (m) of the cold branch K → fixture.
const Map<String, double> kAptBranchM = {
  'WC': 1.0,
  'LAV': 1.5,
  'SH': 2.0,
  'KS': 4.0,
};

/// Plan length (m) of the floor main M → unit tee K.
const Map<String, double> kAptUnitBranchM = {'a': 3.0, 'b': 6.0};

/// Floors served by the boosted branch (index 11, 10) and by gravity (9..0).
const List<int> kAptBoostedFloors = [11, 10];
final List<int> kAptGravityFloors = [for (var f = 9; f >= 0; f--) f];

/// The riser node feeding floor [f]'s main: `BR<f>` on a boosted floor,
/// `GR<f>` on a gravity floor.
String aptRiserNode(int f) => f >= 10 ? 'BR$f' : 'GR$f';

/// Declared tank capacities (litres). The fire tank has no app rule: no
/// provider sizes a fire-water reserve (office backlog b), so it is the
/// brief's 60 000 L.
const double kAptGroundTankL = 20000;
const double kAptRoofTankL = 10000;
const double kAptFireTankL = 60000;

/// The six sprinkler heads (Lantai 12) and the fire pump room.
const List<String> kAptSprinklerHeads = [
  'SP1', 'SP2', 'SP3', 'SP4', 'SP5', 'SP6', //
];
const String kAptDutyFirePump = 'FP';
const String kAptStandbyFirePump = 'FPS';
const String kAptJockeyPump = 'FJ';

/// The hand-picked bore of the jockey legs (mm).
const double kAptJockeyLegMm = 25;

/// A room annotation as plain data.
class ApartmentRoom {
  final String name;
  final String sheetId;
  final int floorIndex;
  final double ax, ay, bx, by;
  final RoomType roomType;
  const ApartmentRoom({
    required this.name,
    required this.sheetId,
    required this.floorIndex,
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
    required this.roomType,
  });

  double get widthM => (bx - ax).abs() * kAptMetersPerPixel;
  double get depthM => (by - ay).abs() * kAptMetersPerPixel;
}

/// Two bedrooms on Lantai 6 (floor index 5), 3.0 m (150 px) x 4.0 m (200 px).
const List<ApartmentRoom> kApartmentRooms = [
  ApartmentRoom(
    name: 'Kamar 6a',
    sheetId: 's_L6',
    floorIndex: 5,
    ax: 1700,
    ay: 200,
    bx: 1850,
    by: 400,
    roomType: RoomType.bedroom,
  ),
  ApartmentRoom(
    name: 'Kamar 6b',
    sheetId: 's_L6',
    floorIndex: 5,
    ax: 1900,
    ay: 200,
    bx: 2050,
    by: 400,
    roomType: RoomType.bedroom,
  ),
];

/// The split-wall AC node in each bedroom (at the room centre).
const List<String> kAptAcNodeIds = ['AC6a', 'AC6b'];

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

double _px(double meters) => meters / kAptMetersPerPixel;

/// Edge id convention: `e_<svc>_<from>_<to>`.
NetEdge _edge(ServiceType s, String from, String to,
    {EdgeKind kind = EdgeKind.run, Diameter? sizeOverride}) {
  final tag = switch (s) {
    ServiceType.coldWater => 'cw',
    ServiceType.drainage => 'dr',
    ServiceType.vent => 'vt',
    ServiceType.rainwater => 'rw',
    ServiceType.fireHydrant => 'fh',
    ServiceType.fireSprinkler => 'sp',
    _ => s.name,
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
// Floor main M; the gravity riser GR 2.0 m due west of it; the booster
// riser BR 2.0 m due south of it.
const _m = (300.0, 800.0);
const _gr = (200.0, 800.0);
const _br = (300.0, 900.0);
// A: 1.0 m from GR11 along GR → BR; BS on both 1.0 m circles of A and BR11.
final (double, double) _a = (
  _gr.$1 + 50 * (_br.$1 - _gr.$1) / 141.4213562373095,
  _gr.$2 + 50 * (_br.$2 - _gr.$2) / 141.4213562373095,
);
final (double, double) _bs = _onCircles(_a, 50, _br, 50, (300, 830));
// RT 2.0 m west of A; the fill riser U 2.0 m south of RT; TP, GT, WM below.
final (double, double) _rt = (_a.$1 - 100, _a.$2);
final (double, double) _u = (_rt.$1, _rt.$2 + 100);
final (double, double) _tp = (_u.$1, _u.$2 + 50);
final (double, double) _gt = (_tp.$1, _tp.$2 + 50);
final (double, double) _wm = (_gt.$1, _gt.$2 + 150);
// Unit tees: Ka 3.0 m north of M, Kb 6.0 m east of M. Stacks: Da 2.5 m east
// of Ka, Db 2.5 m north of Kb.
const _k = <String, (double, double)>{
  'a': (300.0, 650.0),
  'b': (600.0, 800.0),
};
const _d = <String, (double, double)>{
  'a': (425.0, 650.0),
  'b': (600.0, 675.0),
};
// Fixtures: on K's branch circle AND D's 1.5 m circle. Hints pick the side.
final Map<String, Map<String, (double, double)>> _fixtureAt = {
  for (final u in kAptUnits)
    u: {
      for (final b in kAptFixtures)
        b: _onCircles(
            _k[u]!,
            _px(kAptBranchM[b]!),
            _d[u]!,
            _px(1.5),
            u == 'a'
                ? (_k[u]!.$1 + 60, _k[u]!.$2 - 80)
                : (_k[u]!.$1 + 80, _k[u]!.$2 - 60)),
    },
};
// Drainage junction J: 4.0 m from both stack bases; OUT 10.0 m below J.
final (double, double) _j =
    _onCircles(_d['a']!, 200, _d['b']!, 200, (520, 850));
final (double, double) _out = (_j.$1, _j.$2 + 500);

/// The cold-water nodes and edges of one typical floor [f], fed from its
/// riser node ([aptRiserNode]).
(List<NetNode>, List<NetEdge>) _typicalFloor(
    int f,
    NetNode Function(String, (double, double),
            {required int floor, PlumbingFixture? fixture})
        node) {
  const cw = ServiceType.coldWater;
  const dr = ServiceType.drainage;
  final nodes = <NetNode>[
    node('M$f', _m, floor: f),
    for (final u in kAptUnits) ...[
      node('K$u$f', _k[u]!, floor: f),
      for (final b in kAptFixtures)
        node('$b$u$f', _fixtureAt[u]![b]!,
            floor: f, fixture: kAptFixtureType[b]),
      node('D$u$f', _d[u]!, floor: f),
    ],
  ];
  final edges = <NetEdge>[
    _edge(cw, aptRiserNode(f), 'M$f'), // 100 px = 2.0 m
    for (final u in kAptUnits) ...[
      _edge(cw, 'M$f', 'K$u$f'), // 3.0 / 6.0 m
      for (final b in kAptFixtures) _edge(cw, 'K$u$f', '$b$u$f'),
      for (final b in kAptFixtures) _edge(dr, '$b$u$f', 'D$u$f'), // 1.5 m
    ],
  ];
  return (nodes, edges);
}

/// The apartment's mechanical + fire network. [prvFloor] draws the PRV
/// station on the gravity riser at floor index [prvFloor] (between
/// GR(prvFloor + 1) and GR(prvFloor)); null draws none.
Network buildApartmentNetwork({int? prvFloor}) {
  NetNode node(
    String id,
    (double, double) at, {
    required int floor,
    NodeComponent? component,
    PlumbingFixture? fixture,
    double? roofAreaM2,
    double? tankL,
  }) =>
      NetNode(
        id: id,
        sheetId: kAptSheets[floor],
        x: at.$1,
        y: at.$2,
        floorIndex: floor,
        role: component?.role ??
            (fixture != null ? NodeRole.fixture : NodeRole.main),
        component: component,
        fixture: fixture,
        roofAreaM2: roofAreaM2,
        tankCapacityLitres: tankL,
      );
  NetNode plain(String id, (double, double) at,
          {required int floor, PlumbingFixture? fixture}) =>
      node(id, at, floor: floor, fixture: fixture);

  const top = kAptFloors - 1;
  const cw = ServiceType.coldWater;
  const dr = ServiceType.drainage;
  const rw = ServiceType.rainwater;
  const fh = ServiceType.fireHydrant;
  const sp = ServiceType.fireSprinkler;
  const riser = EdgeKind.riser;

  final nodes = <NetNode>[
    // ── Cold water: fill line meter → GT → TP → riser U → RT ────────────
    node('WM', _wm, floor: 0, component: NodeComponent.waterMeter),
    node('GT', _gt,
        floor: 0, component: NodeComponent.groundTank, tankL: kAptGroundTankL),
    node('TP', _tp, floor: 0, component: NodeComponent.pump),
    for (var f = 0; f <= top; f++) node('U$f', _u, floor: f),
    node('RT', _rt,
        floor: top, component: NodeComponent.roofTank, tankL: kAptRoofTankL),
    // RT → top main A → booster BS → BR riser; A → GR riser.
    node('A', _a, floor: top),
    node('BS', _bs, floor: top, component: NodeComponent.boosterSet),
    for (final f in kAptBoostedFloors) node('BR$f', _br, floor: f),
    for (var f = top; f >= 0; f--) node('GR$f', _gr, floor: f),
    if (prvFloor != null)
      node('PRV$prvFloor', _gr, floor: prvFloor, component: NodeComponent.prv),
    // Drainage outfall + vent terminals.
    node('J', _j, floor: 0),
    node('OUT', _out, floor: 0),
    node('VTRa', _d['a']!, floor: top),
    node('VTRb', _d['b']!, floor: top),
    // ── Rainwater ──────────────────────────────────────────────────────
    node('RDa', (900, 300),
        floor: top, component: NodeComponent.roofDrain, roofAreaM2: 200),
    node('RDb', (1100, 300),
        floor: top, component: NodeComponent.roofDrain, roofAreaM2: 200),
    for (var f = top; f >= 0; f--) node('RW$f', (1000, 300), floor: f),
    node('RWOUT', (1000, 600), floor: 0), // 300 px = 6.0 m
    // ── Fire: tank → duty / standby / jockey → header → risers ───────────
    node('FT', (1300, 1300),
        floor: 0, component: NodeComponent.groundTank, tankL: kAptFireTankL),
    node(kAptDutyFirePump, (1300, 1200),
        floor: 0, component: NodeComponent.pump),
    node(kAptStandbyFirePump, (1300 + math.sqrt(150 * 150 - 100 * 100), 1200),
        floor: 0, component: NodeComponent.pump),
    node(kAptJockeyPump, (1300 - math.sqrt(150 * 150 - 100 * 100), 1200),
        floor: 0, component: NodeComponent.pump),
    node('FH', (1300, 1100), floor: 0),
    for (var f = 0; f <= top; f++) ...[
      node('H$f', (1450, 1100), floor: f),
      node('HYD$f', (1550, 1100),
          floor: f, component: NodeComponent.hydrantBox),
      node('S$f', (1300, 900), floor: f),
    ],
    for (var i = 1; i <= 6; i++)
      node('SP$i', (1300 + 150.0 * i, 900),
          floor: top, component: NodeComponent.sprinklerHead),
    // ── HVAC (Lantai 6): one split-wall AC per bedroom ───────────────────
    for (var i = 0; i < kApartmentRooms.length; i++)
      node(
          kAptAcNodeIds[i],
          (
            (kApartmentRooms[i].ax + kApartmentRooms[i].bx) / 2,
            (kApartmentRooms[i].ay + kApartmentRooms[i].by) / 2,
          ),
          floor: kApartmentRooms[i].floorIndex,
          component: NodeComponent.acSplitWall),
  ];

  final edges = <NetEdge>[
    // Fill line.
    _edge(cw, 'WM', 'GT'), // 150 px = 3.0 m
    _edge(cw, 'GT', 'TP'), // 50 px = 1.0 m
    _edge(cw, 'TP', 'U0'), // 50 px = 1.0 m
    for (var f = 1; f <= top; f++) _edge(cw, 'U${f - 1}', 'U$f', kind: riser),
    _edge(cw, 'U$top', 'RT'), // 100 px = 2.0 m
    _edge(cw, 'RT', 'A'), // 100 px = 2.0 m
    // Boosted side branch.
    _edge(cw, 'A', 'BS'), // 50 px = 1.0 m
    _edge(cw, 'BS', 'BR$top'), // 50 px = 1.0 m
    _edge(cw, 'BR11', 'BR10', kind: riser),
    // Gravity riser (floors 9..0), the PRV station spliced in.
    _edge(cw, 'A', 'GR$top'), // 50 px = 1.0 m
    for (var f = top; f > 0; f--)
      if (prvFloor != null && f - 1 == prvFloor) ...[
        _edge(cw, 'GR$f', 'PRV$prvFloor', kind: riser),
        _edge(cw, 'PRV$prvFloor', 'GR$prvFloor'), // 0 px (same x/y)
      ] else
        _edge(cw, 'GR$f', 'GR${f - 1}', kind: riser),
  ];
  // Every floor's typical cold-water + drainage branch.
  for (var f = 0; f <= top; f++) {
    final (n, e) = _typicalFloor(f, plain);
    nodes.addAll(n);
    edges.addAll(e);
  }
  edges.addAll([
    // Drainage stacks → junction → outfall.
    for (final u in kAptUnits)
      for (var f = top; f > 0; f--)
        _edge(dr, 'D$u$f', 'D$u${f - 1}', kind: riser),
    _edge(dr, 'Da0', 'J'), // 4.0 m
    _edge(dr, 'Db0', 'J'), // 4.0 m
    _edge(dr, 'J', 'OUT'), // 10.0 m
    // Vent: one stack vent per stack.
    _edge(ServiceType.vent, 'Da$top', 'VTRa', kind: riser),
    _edge(ServiceType.vent, 'Db$top', 'VTRb', kind: riser),
    // Rainwater.
    _edge(rw, 'RDa', 'RW$top'), // 100 px = 2.0 m
    _edge(rw, 'RDb', 'RW$top'), // 100 px = 2.0 m
    for (var f = top; f > 0; f--) _edge(rw, 'RW$f', 'RW${f - 1}', kind: riser),
    _edge(rw, 'RW0', 'RWOUT'), // 6.0 m
    // Fire: the pump room (duty 2.0 + 2.0 m; standby and jockey 3.0 + 3.0 m,
    // the jockey legs hand-picked DN25).
    _edge(fh, 'FT', kAptDutyFirePump),
    _edge(fh, kAptDutyFirePump, 'FH'),
    _edge(fh, 'FT', kAptStandbyFirePump),
    _edge(fh, kAptStandbyFirePump, 'FH'),
    _edge(fh, 'FT', kAptJockeyPump, sizeOverride: Diameter.mm(kAptJockeyLegMm)),
    _edge(fh, kAptJockeyPump, 'FH', sizeOverride: Diameter.mm(kAptJockeyLegMm)),
    // Hydrant riser + boxes.
    _edge(fh, 'FH', 'H0'), // 150 px = 3.0 m
    for (var f = 1; f <= top; f++) _edge(fh, 'H${f - 1}', 'H$f', kind: riser),
    for (var f = 0; f <= top; f++) _edge(fh, 'H$f', 'HYD$f'), // 2.0 m
    // Sprinkler riser + six heads on Lantai 12.
    _edge(sp, 'FH', 'S0'), // 200 px = 4.0 m
    for (var f = 1; f <= top; f++) _edge(sp, 'S${f - 1}', 'S$f', kind: riser),
    _edge(sp, 'S$top', 'SP1'), // 150 px = 3.0 m
    for (var i = 2; i <= 6; i++) _edge(sp, 'SP${i - 1}', 'SP$i'), // 3.0 m
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
const String kAptMainPanelId = 'panel_lvmdp';
const String kAptEssentialPanelId = 'panel_pp_e';
const String kAptEssentialFeederId = 'c_feeder_pp_e';
String aptFloorPanelId(int f) => 'panel_pp_lt${f + 1}';
String aptFloorFeederId(int f) => 'c_feeder_lt${f + 1}';

/// The essential board's ways.
const String kAptLiftWayId = 'c_lift';
const String kAptEmergencyLightWayId = 'c_lampu_darurat';

/// Floor board PP-Lt<f+1>: 3-phase 400 V, seven 1-phase ways, fed from LVMDP.
ElectricalPanel _floorBoard(int f) {
  final t = 'lt${f + 1}';
  String c(String base) => 'c_${base}_$t';
  const lighting = LoadKind.lighting;
  const socket = LoadKind.socket;
  const hvac = LoadKind.hvac;
  return ElectricalPanel(
    id: aptFloorPanelId(f),
    name: 'PP-Lt${f + 1}',
    system: ElectricalSystem.threePhase,
    voltage: const Voltage(400),
    sourceType: PanelSource.feeder,
    fedByCircuitId: aptFloorFeederId(f),
    circuits: [
      _way(c('lampu_a'), 'Lampu unit a', lighting,
          loadW: 400, lengthM: 15, phases: 1),
      _way(c('lampu_b'), 'Lampu unit b', lighting,
          loadW: 400, lengthM: 20, phases: 1),
      _way(c('kk_a'), 'Stop kontak unit a', socket,
          loadW: 1500, lengthM: 15, phases: 1),
      _way(c('kk_b'), 'Stop kontak unit b', socket,
          loadW: 1500, lengthM: 20, phases: 1),
      _way(c('ac_a'), 'AC unit a', hvac, loadW: 900, lengthM: 12, phases: 1),
      _way(c('ac_b'), 'AC unit b', hvac, loadW: 900, lengthM: 17, phases: 1),
      _way(c('lampu_koridor'), 'Lampu koridor', lighting,
          loadW: 300, lengthM: 25, phases: 1),
    ],
  );
}

/// PP-E: the essential (genset-backed) board, 3-phase 400 V, fed from LVMDP
/// over a 20 m FRC feeder; the lift and the emergency lighting by hand (the
/// MEP machines arrive with the MEP board the app re-feeds onto it).
ElectricalPanel _essentialBoard() => ElectricalPanel(
      id: kAptEssentialPanelId,
      name: 'PP-E',
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      sourceType: PanelSource.feeder,
      fedByCircuitId: kAptEssentialFeederId,
      essential: true,
      circuits: [
        _way(kAptLiftWayId, 'Lift', LoadKind.motor,
            motorKw: 11, lengthM: 45, phases: 3),
        _way(kAptEmergencyLightWayId, 'Lampu darurat', LoadKind.lighting,
            loadW: 600, lengthM: 40, phases: 1),
      ],
    );

/// LVMDP: the service entrance, 3-phase 400 V: the PP-E feeder (20 m, FRC)
/// and twelve floor feeders, manual 10 + 3.5 x floor index m.
ElectricalPanel _mainBoard() => ElectricalPanel(
      id: kAptMainPanelId,
      name: 'LVMDP',
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      circuits: [
        const ElectricalCircuit(
          id: kAptEssentialFeederId,
          name: 'Feeder PP-E',
          loadKind: LoadKind.feeder,
          feedsPanelId: kAptEssentialPanelId,
          length: const Length(20),
          cableType: 'FRC',
        ),
        for (var f = 0; f < kAptFloors; f++)
          ElectricalCircuit(
            id: aptFloorFeederId(f),
            name: 'Feeder PP-Lt${f + 1}',
            loadKind: LoadKind.feeder,
            feedsPanelId: aptFloorPanelId(f),
            length: Length(10 + 3.5 * f),
          ),
      ],
    );

/// The app-recommended declared PLN capacity (VA) and genset rating (kVA),
/// read from the app's own recommendation on a run with neither declared
/// (`electricalAdvancedProvider.recommendedDayaVa` = 197 000 VA, 3-phase LV
/// at the 197 kVA ceiling, no transformer, after A1 made the fire pump 75 kW
/// — 105 000 VA before; the unforced genset sizing
/// `sizeGenerator(gensetBackupDemandVa, minKvaForStart: gensetStartFloorFor)`
/// = 1 x 300 kVA, motor-start floor 286.83 kVA; 50 kVA before A1) and set
/// here. Pass null to either to read them again.
const double? kAptDeclaredPlnVa = 197000;
const double? kAptGensetKva = 300;

/// The apartment's electrical project.
ElectricalProject buildApartmentElectrical({
  double? declaredPlnVa = kAptDeclaredPlnVa,
  double? gensetKva = kAptGensetKva,
}) =>
    ElectricalProject(
      id: 'ref_apartment',
      name: 'Rumah susun 12 lantai',
      supplyKind: SupplyKind.pln,
      supplyCapacityVa:
          declaredPlnVa == null ? null : ApparentPower(declaredPlnVa),
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
        for (var f = 0; f < kAptFloors; f++) _floorBoard(f),
      ],
    );

/// The app-prescribed PRV station floor: with no PRV drawn the zone table
/// (`zonesProvider`) reads [1-11, 0-0] — floors 1..11 straight from the roof
/// tank, Lantai 1 (index 0) through a PRV at the 255 kPa setpoint — and the
/// solve raises `downfeed-over-pressure` on every Lantai 1 fixture ("Draw a
/// PRV on the riser above this zone"). So the station sits on the gravity
/// riser between GR1 and GR0.
const int? kAptPrvFloor = 0;

/// Reference building 4 — the apartment block.
ReferenceBuilding buildApartment({int? prvFloor = kAptPrvFloor}) =>
    ReferenceBuilding(
      name: 'Reference 4 - Apartment',
      building: BuildingLevels([
        for (var f = 0; f < kAptFloors; f++)
          Floor('Lantai ${f + 1}', const Length(kAptFloorHeightM)),
      ]),
      sheets: [
        for (var f = 0; f < kAptFloors; f++)
          ReferenceSheet(
              id: kAptSheets[f], name: 'Lantai ${f + 1}', floorIndex: f),
      ],
      calibrations: {
        for (final s in kAptSheets)
          s: const ScaleCalibration(kAptMetersPerPixel),
      },
      network: buildApartmentNetwork(prvFloor: prvFloor),
      electrical: buildApartmentElectrical(),
      occupancy: Occupancy.private,
    );
