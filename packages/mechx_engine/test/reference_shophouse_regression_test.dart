// Reference building 2 (shophouse row) — ENGINE regression tests for the
// fixes its review raised (docs/REFERENCE-BUILDINGS.md §2):
//
// F2 — the mains feed of a root storage tank (meter → ground tank) carries
//      what the tank delivers, flowing INTO the tank (it sized DN15 at 0 L/s).
// F3 — a stack vent is sized on the whole stack's DFU at its base, not on
//      the top-floor junction's load.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show drainageFixtureUnit;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/house.dart' show buildHouse;
import 'reference/shophouse.dart';

/// The app's `sizingDetailProvider` argument set (mirrored, as in the
/// reference tests).
(Map<String, EdgeSizing>, Map<String, double>) _size(ReferenceBuilding b,
    {Network? network}) {
  final net = network ?? b.network;
  const profile = SniProfile();
  final fu = <String, double>{};
  final sizing = autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: {
      ServiceType.coldWater: const FlowRate(0.0002),
      ServiceType.drainage: const FlowRate(0.0008),
      ServiceType.vent: const FlowRate(0.0004),
      ServiceType.rainwater: rainwaterDesignFlow(
          intensityMmPerHr: 200,
          roofAreaM2: 100,
          runoffCoefficient: kDefaultRunoffCoefficient),
    },
    leafFixtureUnits: const {ServiceType.coldWater: 2.0},
    nodeFixtureUnits: {
      for (final n in net.nodes)
        if (n.fixture != null)
          n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: b.occupancy),
    },
    nodeDrainageUnits: {
      for (final n in net.nodes)
        if (n.fixture != null) n.id: drainageFixtureUnit(n.fixture!),
    },
    nodeFlowDemand: {
      for (final n in net.nodes)
        if (n.roofAreaM2 != null)
          n.id: rainwaterDesignFlow(
              intensityMmPerHr: 200,
              roofAreaM2: n.roofAreaM2!,
              runoffCoefficient: kDefaultRunoffCoefficient),
    },
    building: b.building,
    calibrationBySheet: b.calibrations,
    mounting: b.mounting,
    fixtureUnitsOut: fu,
  );
  return (sizing, fu);
}

void main() {
  group('F2 — the mains feed of a root tank', () {
    test('meter -> ground tank carries the tank\'s delivered flow, into the '
        'tank', () {
      final shop = buildShophouse();
      final (sizing, fu) = _size(shop);
      for (final u in kShopUnits) {
        final stub = 'e_cw_${shopId('WM', u)}_${shopId('GT', u)}';
        final out = 'e_cw_${shopId('GT', u)}_${shopId('TP', u)}';
        // GT delivers 12.5 UBAP (3 x (WC 2.5 + LAV 1.0) + KS 2.0) through
        // GT -> TP; the curve's 10..25 segment: 0.5 + (12.5 - 10) x
        // (0.88333 - 0.5) / 15 = 0.56389 L/s ⇒ DN15 v = 3.19 > 2.0, DN20
        // v = 0.56389e-3 / (pi 0.02^2 / 4) = 1.795 m/s.
        expect(fu[stub], 12.5, reason: stub);
        expect(sizing[stub]!.flow.inLitersPerSecond,
            closeTo(sizing[out]!.flow.inLitersPerSecond, 1e-12));
        expect(sizing[stub]!.flow.inLitersPerSecond, closeTo(0.56389, 5e-6));
        expect(sizing[stub]!.diameter.inMillimeters, 20);
        expect(sizing[stub]!.velocity.metersPerSecond, closeTo(1.795, 5e-4));
        expect(sizing[stub]!.flowFromId, shopId('WM', u));
      }
    });

    test('through an inline gate valve too; a branch ending in a bare leaf '
        'is not a mains feed', () {
      final shop = buildShophouse();
      final net = shop.network;
      final wm = shopId('WM', 'A'), gt = shopId('GT', 'A');
      final wmNode = net.nodeById(wm)!;
      final stub = 'e_cw_${wm}_$gt';
      final valved = Network(
        nodes: [
          ...net.nodes,
          NetNode(
              id: 'GV',
              sheetId: wmNode.sheetId,
              x: wmNode.x,
              y: wmNode.y - 50,
              floorIndex: 0,
              component: NodeComponent.gateValve),
        ],
        edges: [
          for (final e in net.edges)
            if (e.id != stub) e,
          NetEdge(
              id: 'e_wm_gv',
              fromId: wm,
              toId: 'GV',
              service: ServiceType.coldWater),
          NetEdge(
              id: 'e_gv_gt',
              fromId: 'GV',
              toId: gt,
              service: ServiceType.coldWater),
        ],
      );
      final (sizing, _) = _size(shop, network: valved);
      for (final id in ['e_wm_gv', 'e_gv_gt']) {
        expect(sizing[id]!.diameter.inMillimeters, 20, reason: id);
        expect(sizing[id]!.flow.inLitersPerSecond, closeTo(0.56389, 5e-6));
      }
      expect(sizing['e_gv_gt']!.flowFromId, 'GV');
      expect(sizing['e_wm_gv']!.flowFromId, wm);
    });

    test('the house (roof-tank root, no meter) sizes as before', () {
      final house = buildHouse();
      final (sizing, _) = _size(house);
      // RT -> A1 still carries the house's 15.5 UBAP (0.6406 L/s, DN25).
      expect(sizing['e_cw_RT_A1']!.diameter.inMillimeters, 25);
      expect(sizing['e_cw_RT_A1']!.flow.inLitersPerSecond, closeTo(0.6406, 5e-5));
    });
  });

  group('F3 — a stack vent vents the whole stack', () {
    test('shophouse: D2 -> VTR carries the stack base\'s 17 DFU ⇒ DN50', () {
      final shop = buildShophouse();
      final (sizing, fu) = _size(shop);
      for (final u in kShopUnits) {
        final vent = 'e_vt_${shopId('D2', u)}_${shopId('VTR', u)}';
        // Stack base D0 -> OUT: 3 WC x 4 + 3 LAV x 1 + KS 2 = 17 DFU. Vent
        // table (UPC 703.2): 8 < 17 <= 24 ⇒ DN50 (the floor: ½ of the DN100
        // drain 17 DFU needs = 50).
        expect(fu[vent], 17, reason: vent);
        expect(sizing[vent]!.diameter.inMillimeters, 50, reason: vent);
      }
    });

    test('house: D1 -> VTR carries 16 DFU ⇒ DN50', () {
      final house = buildHouse();
      final (sizing, fu) = _size(house);
      // D0 -> OUT: 2 x (WC 4 + LAV 1 + SH 2) + KS 2 = 16 DFU; 8 < 16 <= 24.
      expect(fu['e_vt_D1_VTR'], 16);
      expect(sizing['e_vt_D1_VTR']!.diameter.inMillimeters, 50);
    });
  });
}
