// Round 19 (2026-10-18) — the app half of the round-19 audit:
//
//   hw-ring-main          a stub-fed ring main is NOT a drawn recirc return
//   room-nested           a toilet nested in an office: no false stale
//                         warning, and re-placing one never deletes the
//                         other's terminals
//   locale-parser         the smart-input bar reads ID number separators
//   decode-tolerance      corrupt numeric fields in a .mechx are dropped /
//                         clamped, never asserted on downstream
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/smart_input_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y,
        {NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: c,
        fixture: fixture);

NetEdge _hw(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.hotWater);

void main() {
  // ── hw-ring-main ──────────────────────────────────────────────────────────
  group('hw-recirc: a stub-fed ring main is distribution, not a return', () {
    // Heater H —50 m→ J1, ring J1–J2–J3–J4–J1 (4 × 20 m), a shower branch off
    // each ring node (dead legs). No return to H is drawn.
    final net = Network(nodes: [
      _n('H', 0, 0, role: NodeRole.plant),
      _n('J1', 1, 0),
      _n('J2', 2, 0),
      _n('J3', 2, 1),
      _n('J4', 1, 1),
      for (final j in ['J1', 'J2', 'J3', 'J4'])
        _n('F$j', 5, 5, role: NodeRole.fixture, fixture: PlumbingFixture.shower),
    ], edges: [
      _hw('feed', 'H', 'J1'),
      _hw('r12', 'J1', 'J2'),
      _hw('r23', 'J2', 'J3'),
      _hw('r34', 'J3', 'J4'),
      _hw('r41', 'J4', 'J1'),
      for (final j in ['J1', 'J2', 'J3', 'J4']) _hw('b$j', j, 'F$j'),
    ]);
    double len(NetEdge e) => switch (e.id) {
          'feed' => 50.0,
          _ when e.id.startsWith('r') => 20.0,
          _ => 3.0,
        };
    const bore = Diameter(0.032);
    final sizing = {
      for (final e in net.edges)
        e.id: EdgeSizing(
            edgeId: e.id,
            service: ServiceType.hotWater,
            flow: const FlowRate(0.0001),
            diameter: bore,
            velocity: const Velocity(0.2)),
    };

    test('the ring keeps the heater feed and a mirrored return', () {
      final loop = hotWaterRecircLoop(net, sizing, lengthOf: len)!;
      // Circulated = feed + ring = 50 + 80 = 130 m (the 4 branches are dead
      // legs).
      expect(loop.circulatedLengthM, closeTo(130, 1e-9));
      // The ring passes through neither the heater nor a check valve ⇒ it is
      // NOT a drawn return: the index run (BFS tree from H) is
      // H→J1 (50) → J2 (20) → J3 (20) = 90 m, mirrored by the DN20 return.
      expect(loop.drawnLoopLengthM, isNull);
      expect(loop.returnLengthM, closeTo(90, 1e-9));
      final idx = loop.indexPath.fold<double>(0, (a, s) => a + s.length.meters);
      expect(idx, closeTo(90, 1e-9));

      // Q = 25 W/m × (130 + 90) m / (ρ c ΔT) = 5500 / (1000 × 4186 × 5)
      //   = 0.2628 L/s (the ring-as-loop figure was 0.155 L/s, −41 %).
      final d = sizeHotWaterRecirculation(
        heatLoss: heatLossFromLength(
            loopLength: Length(loop.circulatedLengthM + loop.returnLengthM)),
        loopLength: Length(loop.returnLengthM),
        returnDiameter: kDefaultRecircReturnDiameter,
        supplyPath: loop.indexPath,
      );
      final q = 25 * 220 / (1000 * waterSpecificHeat * 5);
      expect(d.recircFlow.cubicMetersPerSecond, closeTo(q, 1e-12));
      // Head = HW friction over the 90 m index run at DN32 + the 90 m DN20
      // return (the ring-as-loop head was 80 m of DN32 only, ~32× lower).
      final h = headLossHazenWilliams(
                  flow: FlowRate(q),
                  length: const Length(90),
                  diameter: bore,
                  hazenWilliamsC: 150)
              .meters +
          headLossHazenWilliams(
                  flow: FlowRate(q),
                  length: const Length(90),
                  diameter: kDefaultRecircReturnDiameter,
                  hazenWilliamsC: 150)
              .meters;
      expect(d.loopHead.meters, closeTo(h, 1e-9));
    });

    test('a ring that closes THROUGH a check valve is a drawn return', () {
      // Same drawing, J4 is a check valve ⇒ the ring carries the marker of a
      // recirc return (Round-12 convention) and is the loop.
      final withCv = Network(
          nodes: [
            for (final n in net.nodes)
              n.id == 'J4' ? _n('J4', 1, 1, c: NodeComponent.checkValve) : n,
          ],
          edges: net.edges);
      final loop = hotWaterRecircLoop(withCv, sizing, lengthOf: len)!;
      expect(loop.drawnLoopLengthM, closeTo(80, 1e-9));
      expect(loop.returnLengthM, 0.0);
    });
  });

  // ── room-nested ───────────────────────────────────────────────────────────
  group('room terminals: a toilet nested inside an office', () {
    // 20 × 10 m office (0,0)-(2000,1000) px at 0.01 m/px; a 5 × 4 m toilet
    // (1500,0)-(2000,400) inside it.
    const office = RoomArea(
        id: 'office', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 2000,
        by: 1000);
    const toilet = RoomArea(
        id: 'toilet',
        sheetId: 's1',
        floorIndex: 0,
        ax: 1500,
        ay: 0,
        bx: 2000,
        by: 400,
        roomType: RoomType.toilet);

    ProviderContainer setUp() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(projectControllerProvider.notifier)
        ..setFloors(const [Floor('L0', Length(3.5))])
        ..setCalibration('s1', const ScaleCalibration(0.01));
      c.read(roomAreasProvider.notifier).set(const [office, toilet]);
      return c;
    }

    bool stale(ProviderContainer c, String id) => c
        .read(designIssuesProvider)
        .any((i) => i.kind == 'room-terminals-stale:$id');
    int count(ProviderContainer c, NodeComponent comp) => c
        .read(networkControllerProvider)
        .network
        .nodes
        .where((n) => n.component == comp)
        .length;

    for (final order in [
      ['office', 'toilet'],
      ['toilet', 'office'],
    ]) {
      test('auto-place ${order.join(' then ')}: nothing is stale', () {
        final c = setUp();
        final net = c.read(networkControllerProvider.notifier);
        for (final id in order) {
          net.autoPlaceRoomTerminals(
              room: id == 'office' ? office : toilet, metersPerPixel: 0.01);
        }
        // The toilet's exhaust grille(s) survive re-placing the office, and
        // vice versa.
        expect(count(c, NodeComponent.exhaustGrille), greaterThan(0));
        expect(count(c, NodeComponent.supplyDiffuser), greaterThan(0));
        expect(count(c, NodeComponent.returnGrille), greaterThan(0));
        // Freshly placed ⇒ placed == required in BOTH rooms (each terminal
        // counted once, in the smallest room whose kind it serves).
        expect(stale(c, 'office'), isFalse);
        expect(stale(c, 'toilet'), isFalse);
      });
    }

    test('a real change to the office still warns (control)', () {
      final c = setUp();
      final net = c.read(networkControllerProvider.notifier);
      net.autoPlaceRoomTerminals(room: office, metersPerPixel: 0.01);
      net.autoPlaceRoomTerminals(room: toilet, metersPerPixel: 0.01);
      c.read(roomAreasProvider.notifier)
          .setRoomType('office', RoomType.meetingRoom);
      expect(stale(c, 'office'), isTrue);
      expect(stale(c, 'toilet'), isFalse);
    });

    test('ownership: smallest COMPATIBLE room, else smallest containing', () {
      const rooms = [office, toilet];
      // A point inside the toilet footprint.
      expect(
          roomTerminalOwnerId(
              NodeComponent.exhaustGrille, 's1', 0, 1700, 200, rooms),
          'toilet');
      expect(
          roomTerminalOwnerId(
              NodeComponent.supplyDiffuser, 's1', 0, 1700, 200, rooms),
          'office');
      // Alone (no conditioned room around it) a diffuser in a toilet is the
      // toilet's — so an extract room still carrying supply still warns.
      expect(
          roomTerminalOwnerId(
              NodeComponent.supplyDiffuser, 's1', 0, 1700, 200, const [toilet]),
          'toilet');
      expect(
          roomTerminalOwnerId(
              NodeComponent.supplyDiffuser, 's1', 0, 3000, 200, rooms),
          isNull);
    });
  });

  // ── locale-parser ─────────────────────────────────────────────────────────
  group('smart input: ID separators read like every other number field', () {
    test('1.500 is 1500 mm in the ID UI, 2,5 is 2.5 mm', () {
      expect(parseDrawingInput('1.500', indonesian: true).lengthMm, 1500);
      expect(parseDrawingInput('2,5', indonesian: true).lengthMm, 2.5);
      expect(parseDrawingInput('2,5', indonesian: true).error, isNull);
      expect(parseDrawingInput('1.500 45,5', indonesian: true).angleDeg, 45.5);
      // The EN UI is unchanged.
      expect(parseDrawingInput('1.5').lengthMm, 1.5);
      expect(parseDrawingInput('3000 90').angleDeg, 90);
      // Non-finite / non-positive still rejected in both locales.
      for (final bad in ['NaN', 'Infinity', '1e400', '0', '-5']) {
        expect(parseDrawingInput(bad, indonesian: true).ok, isFalse,
            reason: bad);
      }
    });
  });

  // ── decode-tolerance ──────────────────────────────────────────────────────
  group('.mechx decode: corrupt numbers are dropped / clamped', () {
    Map<String, dynamic> raw() => jsonDecode(ProjectDocument(
          projectName: 'P',
          floors: const [Floor('Ground', Length(4.0))],
          calibrations: const {
            'a': ScaleCalibration(0.01),
            'b': ScaleCalibration(0.01),
            'c': ScaleCalibration(0.01),
          },
          staleCalibrations: const {'b'},
          sheets: const [],
          network: const Network(nodes: [
            NetNode(id: 'n', sheetId: 'a', x: 0, y: 0, floorIndex: 0),
          ], edges: [
            NetEdge(
                id: 'e', fromId: 'n', toId: 'n', service: ServiceType.coldWater),
          ]),
          rooms: const [
            RoomArea(
                id: 'r', sheetId: 'a', floorIndex: 0, ax: 0, ay: 0, bx: 10,
                by: 10),
          ],
        ).encode()) as Map<String, dynamic>;

    test('non-positive calibrations: the sheet loads uncalibrated', () {
      final j = raw();
      final cals = (j['project'] as Map<String, dynamic>)['calibrations']
          as Map<String, dynamic>;
      cals['a'] = 0;
      cals['b'] = -0.01;
      final back = ProjectDocument.fromJson(j);
      expect(back.calibrations.keys, {'c'});
      // The stale flag on a dropped calibration goes with it.
      expect(back.staleCalibrations, isEmpty);
    });

    test('node / edge / room numbers outside their bands are dropped', () {
      final j = raw();
      final net = j['network'] as Map<String, dynamic>;
      final node = (net['nodes'] as List).single as Map<String, dynamic>;
      node['roof_area_m2'] = -50;
      node['airflow_lps'] = -100;
      node['tank_l'] = -1;
      node['elec_w'] = -1;
      node['face_w_mm'] = 0;
      node['face_h_mm'] = -10;
      final edge = (net['edges'] as List).single as Map<String, dynamic>;
      edge['size_override_mm'] = 0;
      final room = (j['rooms'] as List).single as Map<String, dynamic>;
      room['ach'] = -6;
      room['ceiling_m'] = 0;
      final back = ProjectDocument.fromJson(j);
      final n = back.network.nodes.single;
      expect(n.roofAreaM2, isNull);
      expect(n.airflow, isNull);
      expect(n.tankCapacityLitres, isNull);
      expect(n.electricalLoadW, isNull);
      expect(n.faceWidthMm, isNull);
      expect(n.faceHeightMm, isNull);
      expect(back.network.edges.single.sizeOverride, isNull);
      expect(back.rooms.single.achOverride, isNull);
      expect(back.rooms.single.ceilingHeightM, 3.0);
    });

    test('in-band values survive; out-of-band room / commercial values clamp',
        () {
      final j = raw();
      final room = (j['rooms'] as List).single as Map<String, dynamic>;
      room['ach'] = 500; // > 60 ⇒ 60
      room['ceiling_m'] = 2.7;
      final settings = (j['settings'] ?? <String, dynamic>{}) as Map;
      settings['labourRatePerHour'] = -1e6;
      settings['overheadPct'] = 500;
      settings['contingencyPct'] = -5;
      settings['marginPct'] = 100;
      j['settings'] = settings;
      final back = ProjectDocument.fromJson(j);
      expect(back.rooms.single.achOverride, 60);
      expect(back.rooms.single.ceilingHeightM, 2.7);
      expect(back.settings.labourRatePerHour, 0);
      expect(back.settings.overheadPct, 100);
      expect(back.settings.contingencyPct, 0);
      expect(back.settings.marginPct, 99.9);
    });

    test('a corrupt file still loads into the sizing chain without throwing',
        () {
      final j = raw();
      final node = ((j['network'] as Map)['nodes'] as List).single as Map;
      node['roof_area_m2'] = -50;
      node['airflow_lps'] = -100;
      final back = ProjectDocument.fromJson(j);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(networkControllerProvider.notifier).loadNetwork(back.network);
      expect(() => c.read(designIssuesProvider), returnsNormally);
      expect(() => c.read(hotWaterRecircProvider), returnsNormally);
    });
  });
}
