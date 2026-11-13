// Reference building 1 — a two-storey HOUSE (rumah tinggal 2 lantai).
//
// A fixed, hand-checkable input set: roof-tank downfeed cold water to 8
// fixtures, their drainage to a soil stack and outfall, one vent, one roof
// drain + downpipe, and a single-phase house board with 9 ways. No hot
// water, fire, HVAC ducts or rooms. Pure Dart (no Flutter import): the
// engine suite and the app suite (relative import) build exactly this.
//
// GEOMETRY. Calibration is 0.02 m/px on both sheets (50 px = 1 m). Every
// node position is chosen so each RUN's straight pixel span x 0.02 is the
// spec length EXACTLY. The trunk runs (RT-A1-B1, A0-B0-C0, C0-KS0, C0-HB0,
// KS0-D0, D0-OUT and the rainwater runs) are axis-aligned on integer pixels.
// A fixture that is BOTH the end of a cold-water branch from B (1.0 / 1.5 /
// 2.0 m) AND the start of a 1.5 m drain to D cannot sit on axis-aligned
// integer pixels for all three fixtures of a floor at once, so those fixtures
// sit on the INTERSECTION of the two circles (centre B, radius = the cold
// branch; centre D, radius = the drain) — see [_onCircles]. WC1 and SH1 land
// on integer pixels; WC0, LAV0, LAV1, SH0 on irrational ones (lengths still
// exact to float precision). The two plans are not stacked pixel-for-pixel:
// the cold riser A1/A0 shares x/y, the soil stack D1 (0,25) sits 25 px
// (0.5 m) off D0 (0,0) — a riser's length is an elevation delta (§10), never
// its plan offset, so this changes no number.
//
// SHARED FIXTURE NODES. One fixture node carries both its cold-water branch
// and its drainage branch (the model keys services per EDGE, not per node).
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'reference_building.dart';

export 'reference_building.dart';

/// Sheet ids (one sheet per floor).
const String kHouseSheetL1 = 's_L1'; // Lantai 1, floor index 0
const String kHouseSheetL2 = 's_L2'; // Lantai 2, floor index 1

/// 0.02 m per pixel ⇒ 50 px = 1 m.
const double kHouseMetersPerPixel = 0.02;

/// Pixel offset applied to every node so the drawing sits inside the sheet.
const double _ox = 400;
const double _oy = 400;

/// The one electrical board.
const String kHousePanelId = 'panel_rumah';

/// The fixed fixture ids (all of them draw cold water; all but HB0 drain).
const List<String> kHouseFixtureIds = [
  'WC1', 'LAV1', 'SH1', 'WC0', 'LAV0', 'SH0', 'KS0', 'HB0', //
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

/// Metres → pixels at the house calibration.
double _px(double meters) => meters / kHouseMetersPerPixel;

NetNode _node(
  String id,
  (double, double) at, {
  required int floor,
  NodeRole role = NodeRole.main,
  NodeComponent? component,
  PlumbingFixture? fixture,
  double? roofAreaM2,
}) =>
    NetNode(
      id: id,
      sheetId: floor == 0 ? kHouseSheetL1 : kHouseSheetL2,
      x: at.$1 + _ox,
      y: at.$2 + _oy,
      floorIndex: floor,
      role: component?.role ?? role,
      component: component,
      fixture: fixture,
      roofAreaM2: roofAreaM2,
    );

NetNode _fixture(String id, (double, double) at, PlumbingFixture f,
        {required int floor}) =>
    _node(id, at, floor: floor, role: NodeRole.fixture, fixture: f);

/// Edge id convention: `e_<svc>_<from>_<to>`.
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

/// The house's mechanical network.
Network buildHouseNetwork() {
  // ── Lantai 2 (floor index 1, sheet s_L2) ─────────────────────────────────
  const rt = (350.0, -50.0);
  const a1 = (250.0, -50.0); // RT -> A1 = 100 px = 2.0 m (west)
  const b1 = (100.0, -50.0); // A1 -> B1 = 150 px = 3.0 m (west)
  const d1 = (0.0, 25.0); // floor-1 drainage junction (top of soil stack)
  final wc1 = _onCircles(b1, _px(1.0), d1, _px(1.5), (60, -20)); // = (60,-20)
  final lav1 = _onCircles(b1, _px(1.5), d1, _px(1.5), (25, -46));
  final sh1 = _onCircles(b1, _px(2.0), d1, _px(1.5), (72, 46)); // = (72,46)
  const rd = (600.0, 300.0); // roof drain
  const rw1 = (650.0, 300.0); // RD -> RW1 = 50 px = 1.0 m (east)

  // ── Lantai 1 (floor index 0, sheet s_L1) ─────────────────────────────────
  const a0 = (250.0, -50.0); // under A1 (the cold riser)
  const b0 = (50.0, -50.0); // A0 -> B0 = 200 px = 4.0 m (west)
  const c0 = (50.0, 100.0); // B0 -> C0 = 150 px = 3.0 m (south)
  const ks0 = (0.0, 100.0); // C0 -> KS0 = 50 px = 1.0 m (west)
  const hb0 = (300.0, 100.0); // C0 -> HB0 = 250 px = 5.0 m (east)
  const d0 = (0.0, 0.0); // foot of the soil stack; KS0 -> D0 = 100 px = 2.0 m
  const out = (-300.0, 0.0); // D0 -> OUT = 300 px = 6.0 m (west)
  final wc0 = _onCircles(b0, _px(1.0), d0, _px(1.5), (6.5, -74.7));
  final lav0 = _onCircles(b0, _px(1.5), d0, _px(1.5), (71.8, 21.8));
  final sh0 = _onCircles(b0, _px(2.0), d0, _px(1.5), (-49.8, -56.1));
  const rw0 = (650.0, 300.0); // under RW1 (the downpipe)
  const rwout = (650.0, 500.0); // RW0 -> RWOUT = 200 px = 4.0 m (south)

  final nodes = <NetNode>[
    // Lantai 2.
    _node('RT', rt, floor: 1, component: NodeComponent.roofTank),
    _node('A1', a1, floor: 1),
    _node('B1', b1, floor: 1),
    _fixture('WC1', wc1, PlumbingFixture.waterClosetFlushTank, floor: 1),
    _fixture('LAV1', lav1, PlumbingFixture.lavatory, floor: 1),
    _fixture('SH1', sh1, PlumbingFixture.shower, floor: 1),
    _node('D1', d1, floor: 1),
    _node('VTR', d1, floor: 1), // vent terminal, above D1 (a riser)
    _node('RD', rd,
        floor: 1, component: NodeComponent.roofDrain, roofAreaM2: 60),
    _node('RW1', rw1, floor: 1),
    // Lantai 1.
    _node('A0', a0, floor: 0),
    _node('B0', b0, floor: 0),
    _fixture('WC0', wc0, PlumbingFixture.waterClosetFlushTank, floor: 0),
    _fixture('LAV0', lav0, PlumbingFixture.lavatory, floor: 0),
    _fixture('SH0', sh0, PlumbingFixture.shower, floor: 0),
    _node('C0', c0, floor: 0),
    _fixture('KS0', ks0, PlumbingFixture.kitchenSink, floor: 0),
    _fixture('HB0', hb0, PlumbingFixture.hoseBibb, floor: 0),
    _node('D0', d0, floor: 0),
    _node('OUT', out, floor: 0),
    _node('RW0', rw0, floor: 0),
    _node('RWOUT', rwout, floor: 0),
  ];

  const cw = ServiceType.coldWater;
  const dr = ServiceType.drainage;
  const rw = ServiceType.rainwater;
  const riser = EdgeKind.riser;
  final edges = <NetEdge>[
    // Cold water, roof-tank downfeed.
    _edge(cw, 'RT', 'A1'),
    _edge(cw, 'A1', 'B1'),
    _edge(cw, 'B1', 'WC1'),
    _edge(cw, 'B1', 'LAV1'),
    _edge(cw, 'B1', 'SH1'),
    _edge(cw, 'A1', 'A0', kind: riser),
    _edge(cw, 'A0', 'B0'),
    _edge(cw, 'B0', 'WC0'),
    _edge(cw, 'B0', 'LAV0'),
    _edge(cw, 'B0', 'SH0'),
    _edge(cw, 'B0', 'C0'),
    _edge(cw, 'C0', 'KS0'),
    _edge(cw, 'C0', 'HB0'),
    // Drainage (fixture -> junction -> stack -> outfall).
    _edge(dr, 'WC1', 'D1'),
    _edge(dr, 'LAV1', 'D1'),
    _edge(dr, 'SH1', 'D1'),
    _edge(dr, 'D1', 'D0', kind: riser),
    _edge(dr, 'WC0', 'D0'),
    _edge(dr, 'LAV0', 'D0'),
    _edge(dr, 'SH0', 'D0'),
    _edge(dr, 'KS0', 'D0'),
    _edge(dr, 'D0', 'OUT'),
    // Vent: the stack vent from the floor-1 junction to the roof terminal.
    _edge(ServiceType.vent, 'D1', 'VTR', kind: riser),
    // Rainwater: roof drain -> leader -> downpipe -> collector.
    _edge(rw, 'RD', 'RW1'),
    _edge(rw, 'RW1', 'RW0', kind: riser),
    _edge(rw, 'RW0', 'RWOUT'),
  ];
  return Network(nodes: nodes, edges: edges);
}

/// One way with the load kind's defaults (cos φ / demand factor from
/// [loadDefaults], lighting flag, motor kW for a motor-like kind) — the same
/// field defaults the app's `addCircuit` intent stamps, with the house's
/// load and manual length.
ElectricalCircuit _way(String id, String name, LoadKind kind,
    {double loadW = 0, double? motorKw, required double lengthM}) {
  final d = loadDefaults[kind]!;
  final isMotor = kind == LoadKind.motor || kind == LoadKind.pump;
  return ElectricalCircuit(
    id: id,
    name: name,
    loadKind: kind,
    cosPhi: d.cosPhi,
    demandFactor: d.demandFactor,
    isLighting: kind == LoadKind.lighting,
    motorKw: isMotor ? motorKw : null,
    loadW: isMotor ? 0 : loadW,
    length: Length(lengthM),
  );
}

/// The house's electrical project: one single-phase 220 V board on a
/// declared 4400 VA PLN connection, default (TN-C-S) earthing, nine ways,
/// nothing placed on the plan (manual lengths).
ElectricalProject buildHouseElectrical() => ElectricalProject(
      id: 'ref_house',
      name: 'Rumah tinggal 2 lantai',
      supplyKind: SupplyKind.pln,
      supplyCapacityVa: const ApparentPower(4400),
      panels: [
        ElectricalPanel(
          id: kHousePanelId,
          name: 'Panel Rumah',
          system: ElectricalSystem.singlePhase,
          voltage: const Voltage(220),
          circuits: [
            _way('c_lampu_lt1', 'Lampu Lt1', LoadKind.lighting,
                loadW: 300, lengthM: 12),
            _way('c_lampu_lt2', 'Lampu Lt2', LoadKind.lighting,
                loadW: 250, lengthM: 15),
            _way('c_kk_lt1', 'Stop kontak Lt1', LoadKind.socket,
                loadW: 1200, lengthM: 15),
            _way('c_kk_lt2', 'Stop kontak Lt2', LoadKind.socket,
                loadW: 800, lengthM: 18),
            _way('c_kk_dapur', 'Stop kontak dapur', LoadKind.socket,
                loadW: 2000, lengthM: 10),
            _way('c_ac_k1', 'AC kamar 1', LoadKind.hvac,
                loadW: 750, lengthM: 14),
            _way('c_ac_k2', 'AC kamar 2', LoadKind.hvac,
                loadW: 750, lengthM: 16),
            // A resistive storage water heater: the 'heating' kind (cos φ 1).
            _way('c_pemanas', 'Pemanas air', LoadKind.heating,
                loadW: 1500, lengthM: 12),
            _way('c_pompa', 'Pompa air', LoadKind.pump,
                motorKw: 0.25, lengthM: 8),
          ],
        ),
      ],
    );

/// Reference building 1 — the house.
ReferenceBuilding buildHouse() => ReferenceBuilding(
      name: 'Reference 1 - House',
      building: const BuildingLevels([
        Floor('Lantai 1', Length(3.5)),
        Floor('Lantai 2', Length(3.5)),
      ]),
      sheets: const [
        ReferenceSheet(id: kHouseSheetL1, name: 'Lantai 1', floorIndex: 0),
        ReferenceSheet(id: kHouseSheetL2, name: 'Lantai 2', floorIndex: 1),
      ],
      calibrations: const {
        kHouseSheetL1: ScaleCalibration(kHouseMetersPerPixel),
        kHouseSheetL2: ScaleCalibration(kHouseMetersPerPixel),
      },
      network: buildHouseNetwork(),
      electrical: buildHouseElectrical(),
      occupancy: Occupancy.private,
    );
