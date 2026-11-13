// Reference building 2 — a row of THREE identical 3-storey SHOPHOUSES (ruko
// 3 lantai, unit A / B / C side by side).
//
// A fixed, hand-checkable input set. Per unit: a mains water meter → ground
// tank → transfer pump → riser → roof tank FILL line, the roof tank → booster
// set → down-riser DISTRIBUTION to a WC + lavatory on every floor and a
// kitchen sink on Lantai 1, their drainage to a soil stack + outfall with one
// stack vent, and one roof drain + downpipe. Unit A also has one retail room
// on Lantai 1 with a cassette AC in it. Electrical: three single-phase
// service-entrance boards (one per unit) on one declared 23 100 VA PLN
// connection. No hot water, fire or ducts. Pure Dart (no Flutter import): the
// engine suite and the app suite (relative import) build exactly this.
//
// GEOMETRY. Calibration is 0.02 m/px on all three sheets (50 px = 1 m). One
// unit is built by [_unit] in local pixels and replicated with a +300 px
// (6.0 m) x-offset per unit and an id suffix `_A` / `_B` / `_C`, so the
// three units are identical up to that translation. Every RUN's straight
// pixel span x 0.02 is the spec length EXACTLY: the fill / distribution
// trunks, the stack outfall and the rainwater runs are axis-aligned on
// integer pixels; a WC / LAV / KS0 is BOTH the end of a cold branch from its
// floor's `B` AND the start of a drain to its floor's `D`, so it sits on the
// INTERSECTION of the two circles ([_onCircles], as in the house). Each unit
// stays inside its own 300 px band (local x in [0, 300)); the long runs go
// along y (the shophouse depth). Risers share x/y on their floors.
//
// SHARED FIXTURE NODES. One fixture node carries both its cold-water branch
// and its drainage branch (the model keys services per EDGE, not per node).
//
// ROOM. A room is an APP annotation (`lib/store/annotation_store.dart`
// `RoomArea`), not an engine type, so [ReferenceBuilding] has no rooms field;
// the room is described here as plain data ([kShophouseRooms]) and the app
// test draws it through the real `roomAreasProvider` intents.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart' show RoomType;
import 'package:mechx_engine/units.dart';

import 'reference_building.dart';

export 'reference_building.dart';

/// Sheet ids (one sheet per floor).
const String kShopSheetL1 = 's_L1'; // Lantai 1, floor index 0
const String kShopSheetL2 = 's_L2'; // Lantai 2, floor index 1
const String kShopSheetL3 = 's_L3'; // Lantai 3, floor index 2
const List<String> _sheetByFloor = [kShopSheetL1, kShopSheetL2, kShopSheetL3];

/// 0.02 m per pixel ⇒ 50 px = 1 m.
const double kShopMetersPerPixel = 0.02;

/// The three units and their x-offset step (6.0 m = 300 px).
const List<String> kShopUnits = ['A', 'B', 'C'];
const double kShopUnitPitchPx = 300;

/// Pixel offset applied to every node so the drawing sits inside the sheet.
const double _ox = 400;
const double _oy = 400;

/// The per-unit (un-suffixed) delivery fixtures.
const List<String> kShopUnitFixtureIds = [
  'WC2', 'LAV2', 'WC1', 'LAV1', 'WC0', 'LAV0', 'KS0', //
];

/// [base] with unit [u]'s suffix (`WC2` → `WC2_A`).
String shopId(String base, String u) => '${base}_$u';

/// The service-entrance board id of unit [u].
String shopPanelId(String u) => 'panel_ruko_$u';

/// The cassette AC node in unit A's room.
const String kShopAcNodeId = 'AC0_A';

/// A room annotation as plain data: sheet + floor, two opposite corners in
/// sheet pixels, the room type. The ceiling is left to the app's default.
class ShophouseRoom {
  final String name;
  final String sheetId;
  final int floorIndex;
  final double ax, ay, bx, by;
  final RoomType roomType;
  const ShophouseRoom({
    required this.name,
    required this.sheetId,
    required this.floorIndex,
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
    required this.roomType,
  });

  double get widthM => (bx - ax).abs() * kShopMetersPerPixel;
  double get depthM => (by - ay).abs() * kShopMetersPerPixel;
}

/// Unit A's shop on Lantai 1: 5.0 m (250 px) x 12.0 m (600 px), the RETAIL
/// room type (`RoomType.retail`, "Retail shop / showroom"), local corners
/// (0, -200) → (250, 400).
const List<ShophouseRoom> kShophouseRooms = [
  ShophouseRoom(
    name: 'Toko A',
    sheetId: kShopSheetL1,
    floorIndex: 0,
    ax: 0 + _ox,
    ay: -200 + _oy,
    bx: 250 + _ox,
    by: 400 + _oy,
    roomType: RoomType.retail,
  ),
];

/// The point at distance [ra] px from [a] AND [rb] px from [b] (two circles'
/// intersection) nearest [near] — all in un-offset drawing pixels.
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

/// Metres → pixels at the shophouse calibration.
double _px(double meters) => meters / kShopMetersPerPixel;

/// Edge id convention: `e_<svc>_<from>_<to>` (suffixed node ids).
NetEdge _edge(ServiceType s, String from, String to,
    {EdgeKind kind = EdgeKind.run}) {
  final tag = switch (s) {
    ServiceType.coldWater => 'cw',
    ServiceType.drainage => 'dr',
    ServiceType.vent => 'vt',
    ServiceType.rainwater => 'rw',
    _ => s.name,
  };
  return NetEdge(
      id: 'e_${tag}_${from}_$to',
      fromId: from,
      toId: to,
      service: s,
      kind: kind);
}

/// The local (un-offset, un-suffixed) layout of one unit, in pixels.
/// Distribution trunk per floor: A (down-riser) at (90,-150) → B at
/// (190,-150) = 100 px = 2.0 m (east); the floor's drainage junction D at
/// (190,-40) = 110 px (2.2 m) south of B — inside the [0.5, 2.5] m window the
/// WC circles (1.0 / 1.5 m) and the [2, 6] m window the KS0 circles
/// (4.0 / 2.0 m) need.
const _a = (90.0, -150.0);
const _b = (190.0, -150.0);
const _d = (190.0, -40.0);
final _wc = _onCircles(_b, _px(1.0), _d, _px(1.5), (160, -110)); // west
final _lav = _onCircles(_b, _px(1.5), _d, _px(1.5), (240, -95)); // east
final _ks = _onCircles(_b, _px(4.0), _d, _px(2.0), (130, 40)); // west

/// One unit's nodes + edges, suffixed `_<u>` and shifted [dx] px east.
(List<NetNode>, List<NetEdge>) _unit(String u, double dx) {
  String id(String base) => shopId(base, u);
  NetNode node(
    String base,
    (double, double) at, {
    required int floor,
    NodeRole role = NodeRole.main,
    NodeComponent? component,
    PlumbingFixture? fixture,
    double? roofAreaM2,
  }) =>
      NetNode(
        id: id(base),
        sheetId: _sheetByFloor[floor],
        x: at.$1 + _ox + dx,
        y: at.$2 + _oy,
        floorIndex: floor,
        role: component?.role ?? (fixture != null ? NodeRole.fixture : role),
        component: component,
        fixture: fixture,
        roofAreaM2: roofAreaM2,
      );

  final nodes = <NetNode>[
    // ── Lantai 1 (floor 0): mains entry, ground tank, transfer pump ───────
    node('WM', (40, 250), floor: 0, component: NodeComponent.waterMeter),
    node('GT', (40, 100), floor: 0, component: NodeComponent.groundTank),
    node('TP', (40, 50), floor: 0, component: NodeComponent.pump),
    node('U0', (40, 0), floor: 0),
    // ── Fill riser U0 → U1 → U2, roof tank + booster on Lantai 3 ──────────
    node('U1', (40, 0), floor: 1),
    node('U2', (40, 0), floor: 2),
    node('RT', (40, -100), floor: 2, component: NodeComponent.roofTank),
    node('BS', (40, -150), floor: 2, component: NodeComponent.boosterSet),
    // ── Distribution: A (down-riser) → B → WC / LAV per floor ─────────────
    for (final f in [2, 1, 0]) ...[
      node('A$f', _a, floor: f),
      node('B$f', _b, floor: f),
      node('WC$f', _wc,
          floor: f, fixture: PlumbingFixture.waterClosetFlushTank),
      node('LAV$f', _lav, floor: f, fixture: PlumbingFixture.lavatory),
      node('D$f', _d, floor: f),
    ],
    node('KS0', _ks, floor: 0, fixture: PlumbingFixture.kitchenSink),
    node('OUT', (190, 360), floor: 0), // D0 -> OUT = 400 px = 8.0 m (south)
    node('VTR', _d, floor: 2), // vent terminal above D2 (a riser)
    // ── Rainwater: roof drain → leader → downpipe → collector ─────────────
    node('RD', (260, 100),
        floor: 2, component: NodeComponent.roofDrain, roofAreaM2: 80),
    node('RW2', (260, 150), floor: 2), // RD -> RW2 = 50 px = 1.0 m
    node('RW1', (260, 150), floor: 1),
    node('RW0', (260, 150), floor: 0),
    node('RWOUT', (260, 400), floor: 0), // RW0 -> RWOUT = 250 px = 5.0 m
    // ── Unit A only: the cassette AC inside the retail room ───────────────
    if (u == 'A')
      node('AC0', (125, 100), floor: 0, component: NodeComponent.acCassette),
  ];

  const cw = ServiceType.coldWater;
  const dr = ServiceType.drainage;
  const rw = ServiceType.rainwater;
  const riser = EdgeKind.riser;
  final edges = <NetEdge>[
    // Cold water — FILL line: meter → ground tank → transfer pump → riser →
    // roof tank.
    _edge(cw, id('WM'), id('GT')), // 150 px = 3.0 m
    _edge(cw, id('GT'), id('TP')), // 50 px = 1.0 m
    _edge(cw, id('TP'), id('U0')), // 50 px = 1.0 m
    _edge(cw, id('U0'), id('U1'), kind: riser),
    _edge(cw, id('U1'), id('U2'), kind: riser),
    _edge(cw, id('U2'), id('RT')), // 100 px = 2.0 m
    // Cold water — DISTRIBUTION: roof tank → booster → down-riser.
    _edge(cw, id('RT'), id('BS')), // 50 px = 1.0 m
    _edge(cw, id('BS'), id('A2')), // 50 px = 1.0 m
    _edge(cw, id('A2'), id('B2')), // 100 px = 2.0 m
    _edge(cw, id('A2'), id('A1'), kind: riser),
    _edge(cw, id('A1'), id('A0'), kind: riser),
    _edge(cw, id('A1'), id('B1')), // 2.0 m
    _edge(cw, id('A0'), id('B0')), // 2.0 m
    for (final f in [2, 1, 0]) ...[
      _edge(cw, id('B$f'), id('WC$f')), // 1.0 m
      _edge(cw, id('B$f'), id('LAV$f')), // 1.5 m
    ],
    _edge(cw, id('B0'), id('KS0')), // 4.0 m
    // Drainage: fixture → floor junction → stack → outfall.
    for (final f in [2, 1, 0]) ...[
      _edge(dr, id('WC$f'), id('D$f')), // 1.5 m
      _edge(dr, id('LAV$f'), id('D$f')), // 1.5 m
    ],
    _edge(dr, id('KS0'), id('D0')), // 2.0 m
    _edge(dr, id('D2'), id('D1'), kind: riser),
    _edge(dr, id('D1'), id('D0'), kind: riser),
    _edge(dr, id('D0'), id('OUT')), // 8.0 m
    // Vent: the stack vent from the top-floor junction to the roof terminal.
    _edge(ServiceType.vent, id('D2'), id('VTR'), kind: riser),
    // Rainwater.
    _edge(rw, id('RD'), id('RW2')), // 1.0 m
    _edge(rw, id('RW2'), id('RW1'), kind: riser),
    _edge(rw, id('RW1'), id('RW0'), kind: riser),
    _edge(rw, id('RW0'), id('RWOUT')), // 5.0 m
  ];
  return (nodes, edges);
}

/// The shophouse row's mechanical network (units A, B, C).
Network buildShophouseNetwork() {
  final nodes = <NetNode>[];
  final edges = <NetEdge>[];
  for (var i = 0; i < kShopUnits.length; i++) {
    final (n, e) = _unit(kShopUnits[i], i * kShopUnitPitchPx);
    nodes.addAll(n);
    edges.addAll(e);
  }
  return Network(nodes: nodes, edges: edges);
}

/// One way with the load kind's defaults (cos φ / demand factor from
/// [loadDefaults], lighting flag) — the same field defaults the app's
/// `addCircuit` intent stamps, with the unit's load and manual length.
ElectricalCircuit _way(String id, String name, LoadKind kind,
    {required double loadW, required double lengthM}) {
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
  );
}

/// Unit [u]'s service-entrance board: single-phase 220 V, eight ways.
ElectricalPanel _board(String u) {
  String c(String base) => 'c_${base}_$u';
  return ElectricalPanel(
    id: shopPanelId(u),
    name: 'Panel Ruko $u',
    system: ElectricalSystem.singlePhase,
    voltage: const Voltage(220),
    circuits: [
      _way(c('lampu_lt1'), 'Lampu Lt1', LoadKind.lighting,
          loadW: 200, lengthM: 10),
      _way(c('lampu_lt2'), 'Lampu Lt2', LoadKind.lighting,
          loadW: 200, lengthM: 14),
      _way(c('lampu_lt3'), 'Lampu Lt3', LoadKind.lighting,
          loadW: 200, lengthM: 18),
      _way(c('kk_lt1'), 'Stop kontak Lt1', LoadKind.socket,
          loadW: 1000, lengthM: 12),
      _way(c('kk_lt2'), 'Stop kontak Lt2', LoadKind.socket,
          loadW: 1000, lengthM: 16),
      _way(c('kk_lt3'), 'Stop kontak Lt3', LoadKind.socket,
          loadW: 1000, lengthM: 20),
      _way(c('ac_lt2'), 'AC Lt2', LoadKind.hvac, loadW: 1100, lengthM: 15),
      _way(c('ac_lt3'), 'AC Lt3', LoadKind.hvac, loadW: 1100, lengthM: 19),
    ],
  );
}

/// The row's electrical project: three single-phase 220 V service-entrance
/// boards (one per unit, none feeding another), default (TN-C-S) earthing,
/// a declared 23 100 VA (3 x 7700) PLN connection, nothing placed on the plan
/// (manual lengths). No way for the transfer pump, booster or AC is added by
/// hand.
ElectricalProject buildShophouseElectrical() => ElectricalProject(
      id: 'ref_shophouse',
      name: 'Ruko 3 lantai (3 unit)',
      supplyKind: SupplyKind.pln,
      supplyCapacityVa: const ApparentPower(23100),
      panels: [for (final u in kShopUnits) _board(u)],
    );

/// Reference building 2 — the shophouse row.
ReferenceBuilding buildShophouse() => ReferenceBuilding(
      name: 'Reference 2 - Shophouse row',
      building: const BuildingLevels([
        Floor('Lantai 1', Length(4.0)),
        Floor('Lantai 2', Length(4.0)),
        Floor('Lantai 3', Length(4.0)),
      ]),
      sheets: const [
        ReferenceSheet(id: kShopSheetL1, name: 'Lantai 1', floorIndex: 0),
        ReferenceSheet(id: kShopSheetL2, name: 'Lantai 2', floorIndex: 1),
        ReferenceSheet(id: kShopSheetL3, name: 'Lantai 3', floorIndex: 2),
      ],
      calibrations: const {
        kShopSheetL1: ScaleCalibration(kShopMetersPerPixel),
        kShopSheetL2: ScaleCalibration(kShopMetersPerPixel),
        kShopSheetL3: ScaleCalibration(kShopMetersPerPixel),
      },
      network: buildShophouseNetwork(),
      electrical: buildShophouseElectrical(),
      occupancy: Occupancy.private,
    );
