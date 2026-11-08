// Round 28 (2026-10-18) — the app-side findings:
//
//   fire-3-sprinkler-pump-gets-standpipe-duty   each drawn fire pump is rated
//     on its OWN fire system (a sprinkler pump on a separate network is a
//     sprinkler pump, never the standpipe pump drawn elsewhere).
//   fire-3-standpipe-stacks-counted-across-independent-systems   two towers
//     with one stack each are two 500 gpm systems.
//   fire-3-pump-head-ignores-sized-fire-pipe-friction   on a calibrated
//     drawing the rated head carries the sized index-path friction.
//   persist-undo-2-1 / -4   node / room id counters survive a reload.
//   persist-undo-2-2 / -3   fixture library, commercial, equipment-spec and
//     document-control edits are one undo step each.
//   persist-undo-2-5   a damaged floor stack decodes into the setter band.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/commercial_store.dart';
import 'package:mechx/store/document_control_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/equipment_spec_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/fixture_library_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/standards/custom_fixture.dart';
import 'package:mechx_engine/standards/sni.dart' show Occupancy;
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.fireSprinkler,
        EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// 8 storeys x 4 m, light hazard, calibrated at 0.01 m/px when [cal].
void _seed(ProviderContainer c, {bool cal = true}) {
  final p = c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 8; i++) Floor('L$i', const Length(4))]);
  if (cal) p.setCalibration('s1', const ScaleCalibration(0.01));
  c.read(fireHazardProvider.notifier).set(FireHazardClass.lightHazard);
}

/// GT -> SP -> a 5 m main -> a sprinkler riser to the top floor -> 12 heads
/// at 3 m on the top floor.
List<NetNode> _sprinklerNodes(String p, double x0) => [
      _n('${p}GT', x0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('${p}SP', x0 + 50, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('${p}M', x0 + 550, 0),
      for (var f = 1; f < 8; f++) _n('${p}R$f', x0 + 550, 0, floor: f),
      for (var h = 1; h <= 12; h++)
        _n('${p}H$h', x0 + 550 + 300.0 * h, 0,
            floor: 7, role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
    ];
List<NetEdge> _sprinklerEdges(String p) => [
      _e('${p}g', '${p}GT', '${p}SP'),
      _e('${p}m', '${p}SP', '${p}M'),
      for (var f = 1; f < 8; f++)
        _e('${p}r$f', f == 1 ? '${p}M' : '${p}R${f - 1}', '${p}R$f',
            k: EdgeKind.riser),
      for (var h = 1; h <= 12; h++)
        _e('${p}b$h', h == 1 ? '${p}R7' : '${p}H${h - 1}', '${p}H$h'),
    ];

/// GT -> HP -> an 8-storey hydrant stack with a hose box per floor.
List<NetNode> _hydrantNodes(String p, double x0) => [
      _n('${p}GT', x0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('${p}HP', x0 + 50, 0, role: NodeRole.plant, c: NodeComponent.pump),
      for (var f = 0; f < 8; f++) ...[
        _n('${p}S$f', x0 + 100, 0, floor: f),
        _n('${p}HB$f', x0 + 150, 0,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ],
    ];
List<NetEdge> _hydrantEdges(String p) => [
      _e('${p}g', '${p}GT', '${p}HP', s: ServiceType.fireHydrant),
      _e('${p}h', '${p}HP', '${p}S0', s: ServiceType.fireHydrant),
      for (var f = 0; f < 8; f++) ...[
        _e('${p}b$f', '${p}S$f', '${p}HB$f', s: ServiceType.fireHydrant),
        if (f > 0)
          _e('${p}r$f', '${p}S${f - 1}', '${p}S$f',
              s: ServiceType.fireHydrant, k: EdgeKind.riser),
      ],
    ];

void main() {
  group('fire pumps are rated per fire system', () {
    test(
        'a sprinkler pump on its own network beside a separate standpipe is '
        'a SPRINKLER pump: the remote-area flow, not the 31.5 L/s / 75 kW '
        'standpipe duty', () {
      final c = _c();
      _seed(c);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(
            nodes: [..._sprinklerNodes('a', 0), ..._hydrantNodes('b', 10000)],
            edges: [..._sprinklerEdges('a'), ..._hydrantEdges('b')],
          ));
      final bases = c.read(firePumpBasisByNodeProvider);
      final sp = bases['aSP']!;
      final hp = bases['bHP']!;
      expect(sp.sprinklerOnly, isTrue);
      expect(hp.sprinklerOnly, isFalse);
      // The sprinkler system's rated flow IS the remote-area demand.
      final remote = c.read(sprinklerRemoteAreaProvider);
      expect(sp.flow.inLitersPerSecond,
          closeTo(remote.remoteAreaDemand.inLitersPerSecond, 1e-9));
      // One stack: standpipeFlow(1) = 500 gpm.
      expect(hp.flow.inLitersPerSecond,
          closeTo(standpipeFlow(1).inLitersPerSecond, 1e-9));
      final duties = c.read(equipmentNodeDutiesProvider);
      expect(duties['aSP']!.motor.watts, sp.duty!.selectedMotor.watts);
      expect(duties['bHP']!.motor.watts, hp.duty!.selectedMotor.watts);
      expect(duties['aSP']!.motor.watts,
          lessThan(duties['bHP']!.motor.watts / 2));
      // The project-level figure stays the governing (hydrant) system.
      expect(c.read(fireRatedPointProvider).sprinklerOnly, isFalse);
    });

    test(
        'two independent single-stack towers: each pump rated 500 gpm = '
        '31.55 L/s (was 750 gpm = 47.32 L/s)', () {
      final c = _c();
      _seed(c, cal: false);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(
            nodes: [..._hydrantNodes('a', 0), ..._hydrantNodes('b', 10000)],
            edges: [..._hydrantEdges('a'), ..._hydrantEdges('b')],
          ));
      final bases = c.read(firePumpBasisByNodeProvider);
      for (final id in ['aHP', 'bHP']) {
        expect(bases[id]!.standpipeRisers, 1, reason: id);
        expect(bases[id]!.flow.inLitersPerSecond,
            closeTo(1892.7 / 60, 0.05), reason: id);
      }
      expect(c.read(standpipeDesignProvider).requiredFlow.inLitersPerSecond,
          closeTo(standpipeFlow(1).inLitersPerSecond, 1e-9));
    });

    test(
        'calibrated: the sprinkler pump head = lift + remote head pressure + '
        'the sized index-path friction when it exceeds the 15 m allowance '
        'basis; uncalibrated: the allowance basis stands', () {
      for (final cal in [true, false]) {
        final c = _c();
        _seed(c, cal: cal);
        final net = Network(
            nodes: _sprinklerNodes('a', 0), edges: _sprinklerEdges('a'));
        c.read(networkControllerProvider.notifier).loadNetwork(net);
        final basis = c.read(firePumpBasisByNodeProvider)['aSP']!;
        final remote = c.read(sprinklerRemoteAreaProvider);
        final building = c.read(projectControllerProvider).building;
        final lift = building.ceilingElevationOf(7).meters -
            building.elevationOf(0).meters;
        const rhoG = 1000 * 9.81;
        final allowanceHead =
            lift + remote.branchBasePressure.pascals / rhoG + 15.0;
        if (!cal) {
          expect(basis.indexFrictionM, isNull);
          expect(basis.head.meters, closeTo(allowanceHead, 1e-9));
          continue;
        }
        // The friction recomputed from the sized pipes and true lengths.
        final project = c.read(projectControllerProvider);
        final f = fireIndexPathFrictionM(
          net: net,
          system: fireSystems(net).single,
          pumpId: 'aSP',
          sizing: c.read(sizingProvider),
          lengthOf: (e) => edgeLength(e, net,
                  calibrationBySheet: project.calibrations,
                  building: building,
                  mounting: project.mounting)
              .meters,
        )!;
        expect(basis.indexFrictionM, closeTo(f, 1e-9));
        // The fire sizer runs at up to 6 m/s: the sized index path loses far
        // more than the 15 m allowance.
        expect(f, greaterThan(15));
        final calculated =
            lift + remote.remoteHeadPressure.pascals / rhoG + f;
        expect(calculated, greaterThan(allowanceHead));
        expect(basis.head.meters, closeTo(calculated, 1e-9));
      }
    });
  });

  group('id counters survive a reload', () {
    test(
        'a node minted after reopening never re-uses a deleted top id: '
        'nextSeq persisted; an older file falls back to the referenced ids',
        () {
      final a = _c();
      final nc = a.read(networkControllerProvider.notifier);
      for (var i = 0; i < 3; i++) {
        nc.addComponentNode(
            's1', 0, Offset(100.0 * i, 0), NodeComponent.pump);
      }
      final ids = [for (final n in a.read(networkControllerProvider).network.nodes) n.id];
      final top = ids.last;
      nc.deleteNode(top);
      final doc = buildDocument(a.read);
      expect(doc.networkNextSeq, isNotNull);
      final reread = ProjectDocument.decode(doc.encode());
      expect(reread.networkNextSeq, doc.networkNextSeq);

      final b = _c();
      applyDocument(b.read, reread);
      b
          .read(networkControllerProvider.notifier)
          .addComponentNode('s1', 0, const Offset(500, 0), NodeComponent.pump);
      final fresh = b.read(networkControllerProvider).network.nodes.last.id;
      expect(fresh, isNot(top));

      // An older file (no nextSeq) whose acknowledgement still names n9.
      final legacy = ProjectDocument(
        projectName: 'p',
        floors: kDefaultProjectFloors,
        calibrations: const {},
        sheets: const [],
        network: Network(nodes: [_n('n0', 0, 0)]),
        settings: const DesignSettings(acknowledgedIssues: [
          IssueAck(key: 'fixture-untyped:n9 s1|n9|||'),
        ]),
      );
      final d = _c();
      applyDocument(d.read, ProjectDocument.decode(legacy.encode()));
      d
          .read(networkControllerProvider.notifier)
          .addComponentNode('s1', 0, const Offset(5, 0), NodeComponent.pump);
      final minted = d.read(networkControllerProvider).network.nodes.last.id;
      expect(int.parse(minted.substring(1)), greaterThan(9));
    });

    test('a room drawn after reopening never re-uses a deleted room id', () {
      final a = _c();
      final rc = a.read(roomAreasProvider.notifier);
      final r0 = rc.add(
          sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 100, by: 100)!;
      final r1 = rc.add(
          sheetId: 's1', floorIndex: 0, ax: 200, ay: 0, bx: 300, by: 100)!;
      rc.removeById(r1);
      final doc = ProjectDocument.decode(buildDocument(a.read).encode());
      expect(doc.roomNextSeq, isNotNull);
      final b = _c();
      applyDocument(b.read, doc);
      final next = b.read(roomAreasProvider.notifier).add(
          sheetId: 's1', floorIndex: 0, ax: 400, ay: 0, bx: 500, by: 100)!;
      expect(next, isNot(r1));
      expect(next, isNot(r0));
    });

    test('an untouched project writes no counter (byte-identical)', () {
      final a = _c();
      final doc = buildDocument(a.read);
      expect(doc.networkNextSeq, isNull);
      expect(doc.roomNextSeq, isNull);
      expect(doc.encode().contains('nextSeq'), isFalse);
      expect(doc.encode().contains('roomNextSeq'), isFalse);
    });
  });

  group('persisted settings edits are one undo step each', () {
    test(
        'a fixture-library edit is undone by Ctrl+Z (the previous network '
        'edit stays)', () {
      final c = _c();
      final lib = c.read(fixtureLibraryProvider.notifier);
      lib.add(const CustomFixture(
          id: 'cf1', name: 'Basin', supplyUnits: 2, drainageUnits: 2));
      c
          .read(networkControllerProvider.notifier)
          .addComponentNode('s1', 0, const Offset(0, 0), NodeComponent.pump);
      lib.update(const CustomFixture(
          id: 'cf1', name: 'Basin', supplyUnits: 400, drainageUnits: 400));
      final nodes = c.read(networkControllerProvider).network.nodes.length;
      c.read(historyProvider.notifier).undo();
      expect(c.read(fixtureLibraryProvider).single.supplyUnits, 2);
      expect(c.read(networkControllerProvider).network.nodes.length, nodes);
      c.read(historyProvider.notifier).redo();
      expect(c.read(fixtureLibraryProvider).single.supplyUnits, 400);
    });

    test(
        'an equipment-spec edit is undone by Ctrl+Z, never an older design '
        'setting (occupancy)', () {
      final c = _c();
      setOccupancyUndoable(c.read, Occupancy.public);
      c.read(equipmentModelSpecProvider.notifier).setSpec('P-01', 'Grundfos CR');
      c.read(historyProvider.notifier).undo();
      expect(c.read(equipmentModelSpecProvider), isEmpty);
      expect(c.read(occupancyProvider), Occupancy.public);
      // An equal-value edit records nothing.
      c.read(equipmentModelSpecProvider.notifier).setSpec('P-01', '');
      c.read(historyProvider.notifier).undo();
      expect(c.read(occupancyProvider), Occupancy.private);
    });

    test('a document-control edit is one undo step', () {
      final c = _c();
      setOccupancyUndoable(c.read, Occupancy.public);
      final dc = c.read(documentControlProvider.notifier)
        ..setDocumentNumber('M-101')
        ..addRevision('2026-10-18', 'Issued');
      c.read(historyProvider.notifier).undo();
      expect(c.read(documentControlProvider).revisions, isEmpty);
      expect(c.read(documentControlProvider).documentNumber, 'M-101');
      c.read(historyProvider.notifier).undo();
      expect(c.read(documentControlProvider).documentNumber, isNull);
      expect(c.read(occupancyProvider), Occupancy.public);
      dc.setDocumentNumber(null); // equal value: nothing recorded
      c.read(historyProvider.notifier).undo();
      expect(c.read(occupancyProvider), Occupancy.private);
    });

    test('a pricelist / markup edit is one undo step', () {
      final c = _c();
      c.read(commercialSettingsProvider.notifier)
        ..setPrice('SKU-1', 1000)
        ..setMarginPct(20);
      c.read(historyProvider.notifier).undo();
      expect(c.read(commercialSettingsProvider).marginPct, 15);
      expect(c.read(commercialSettingsProvider).priceList, {'SKU-1': 1000});
      c.read(historyProvider.notifier).undo();
      expect(c.read(commercialSettingsProvider).priceList, isEmpty);
    });
  });

  group('a damaged floor stack decodes into the band', () {
    Map<String, dynamic> json(List<Map<String, Object?>> floors) {
      final doc = ProjectDocument(
        projectName: 'p',
        floors: kDefaultProjectFloors,
        calibrations: const {},
        sheets: const [],
        network: const Network(),
      ).toJson();
      (doc['project'] as Map)['floors'] = floors;
      return doc;
    }

    test(
        'an empty list loads the DEFAULT stack, never the previously open '
        "project's floors", () {
      final c = _c();
      c.read(projectControllerProvider.notifier).setFloors(
          [for (var i = 0; i < 5; i++) Floor('L$i', const Length(6))]);
      applyDocument(c.read, ProjectDocument.fromJson(json([])));
      final floors = c.read(projectControllerProvider).floors;
      expect([for (final f in floors) f.height.meters], [4.0, 3.5, 3.5]);
    });

    test(
        'a negative / zero / non-finite height decodes to 3.5 m, an '
        'over-tall one clamps to 20 m (the setter band)', () {
      final doc = ProjectDocument.fromJson(json([
        {'name': 'G', 'height_m': 4.0},
        {'name': 'L1', 'height_m': -3.5},
        {'name': 'L2', 'height_m': 0},
        {'name': 'L3', 'height_m': 99},
      ]));
      expect([for (final f in doc.floors) f.height.meters],
          [4.0, 3.5, 3.5, 20.0]);
      final c = _c();
      applyDocument(c.read, doc);
      final b = c.read(projectControllerProvider).building;
      // Elevations rise monotonically again.
      for (var i = 1; i < b.floors.length; i++) {
        expect(b.elevationOf(i).meters, greaterThan(b.elevationOf(i - 1).meters));
      }
    });

    test('a custom fixture with negative units decodes to 0', () {
      final f = CustomFixture.fromJson(const {
        'id': 'cf',
        'name': 'x',
        'supplyUnits': -5,
        'drainageUnits': double.infinity,
      })!;
      expect(f.supplyUnits, 0);
      expect(f.drainageUnits, 0);
    });
  });
}
