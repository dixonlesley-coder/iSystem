// Reference building 1 (house) — ENGINE-level solve smoke test.
//
// Builds the fixed house (`test/reference/house.dart`) and runs it through
// the real engine: `autoSizeNetwork` with the building + calibrations (the
// argument set the app's `sizingDetailProvider` passes), the roof-tank
// DOWNFEED pressure solve, and the electrical `computeSystem` +
// `computeAdvancedStudy`. It asserts only that nothing throws and that every
// flowing edge comes back sized; the hand-derived expected values are a
// later task. Set REF_DUMP=1 to print the solved figures.
import 'dart:io';
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart'
    show defaultLvUtilityFaultKa, estimatedServiceFaultLevelA;
import 'package:mechx_engine/electrical/panel_results.dart'
    show ElectricalSystemResult;
import 'package:mechx_engine/electrical/supply_design.dart' show SupplyLevel;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart' show defaultPrvSetpoint;
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show drainageFixtureUnit;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/house.dart';

// The app-side defaults `sizingDetailProvider` feeds the sizer
// (lib/store/sizing_store.dart `kDefaultLeafDemand` /
// `kDefaultLeafFixtureUnits` / `kDefaultRoofAreaPerOutlet`, and
// lib/store/app_state.dart's 200 mm/h design rainfall), mirrored here because
// the engine package cannot import the app.
const Map<ServiceType, FlowRate> _leafDemand = {
  ServiceType.duct: FlowRate(0.05),
  ServiceType.returnAir: FlowRate(0.05),
  ServiceType.exhaust: FlowRate(0.03),
  ServiceType.coldWater: FlowRate(0.0002),
  ServiceType.hotWater: FlowRate(0.0002),
  ServiceType.drainage: FlowRate(0.0008),
  ServiceType.vent: FlowRate(0.0004),
  ServiceType.rainwater: FlowRate(0.001),
  ServiceType.fireHydrant: FlowRate(0.005),
};
const Map<ServiceType, double> _leafFixtureUnits = {
  ServiceType.coldWater: 2.0,
  ServiceType.hotWater: 2.0,
};
const double _defaultRoofAreaPerOutlet = 100.0;
const double _rainfallMmPerHr = 200.0;

final bool _dump = Platform.environment['REF_DUMP'] == '1';
void _p(String s) {
  if (_dump) print(s); // ignore: avoid_print
}

String _f(double v, [int dp = 3]) => v.toStringAsFixed(dp);

void main() {
  final house = buildHouse();
  final net = house.network;
  const profile = SniProfile();

  Map<String, double> fuOut = {};
  Map<String, EdgeSizing> size() {
    fuOut = {};
    return autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: {
        ..._leafDemand,
        ServiceType.rainwater: rainwaterDesignFlow(
            intensityMmPerHr: _rainfallMmPerHr,
            roofAreaM2: _defaultRoofAreaPerOutlet,
            runoffCoefficient: kDefaultRunoffCoefficient),
      },
      leafFixtureUnits: _leafFixtureUnits,
      nodeFixtureUnits: {
        for (final n in net.nodes)
          if (n.fixture != null)
            n.id: profile.fixtureUnitLoad(n.fixture!,
                occupancy: house.occupancy),
      },
      nodeDrainageUnits: {
        for (final n in net.nodes)
          if (n.fixture != null) n.id: drainageFixtureUnit(n.fixture!),
      },
      nodeFlowDemand: {
        for (final n in net.nodes)
          if (n.roofAreaM2 != null)
            n.id: rainwaterDesignFlow(
                intensityMmPerHr: _rainfallMmPerHr,
                roofAreaM2: n.roofAreaM2!,
                runoffCoefficient: kDefaultRunoffCoefficient),
      },
      building: house.building,
      calibrationBySheet: house.calibrations,
      mounting: house.mounting,
      fixtureUnitsOut: fuOut,
    );
  }

  test('the house fixture is the spec: 2 floors, 22 nodes, 26 edges, every '
      'run its exact length', () {
    expect(house.building.levelCount, 2);
    expect(net.nodes.length, 22);
    expect(net.edges.length, 26);
    const runM = {
      'e_cw_RT_A1': 2.0, 'e_cw_A1_B1': 3.0, 'e_cw_B1_WC1': 1.0,
      'e_cw_B1_LAV1': 1.5, 'e_cw_B1_SH1': 2.0, 'e_cw_A0_B0': 4.0,
      'e_cw_B0_WC0': 1.0, 'e_cw_B0_LAV0': 1.5, 'e_cw_B0_SH0': 2.0,
      'e_cw_B0_C0': 3.0, 'e_cw_C0_KS0': 1.0, 'e_cw_C0_HB0': 5.0,
      'e_dr_WC1_D1': 1.5, 'e_dr_LAV1_D1': 1.5, 'e_dr_SH1_D1': 1.5,
      'e_dr_WC0_D0': 1.5, 'e_dr_LAV0_D0': 1.5, 'e_dr_SH0_D0': 1.5,
      'e_dr_KS0_D0': 2.0, 'e_dr_D0_OUT': 6.0,
      'e_rw_RD_RW1': 1.0, 'e_rw_RW0_RWOUT': 4.0,
    };
    for (final MapEntry(:key, :value) in runM.entries) {
      final e = net.edgeById(key)!;
      final cal = house.calibrations[net.nodeById(e.fromId)!.sheetId]!;
      expect(cal.lengthForPixels(runPixelLength(e, net)).meters,
          closeTo(value, 1e-9),
          reason: key);
    }
  });

  test('mechanical: sizes every flowing edge and solves the downfeed', () {
    final sizing = size();
    _p('## ENGINE sizing');
    for (final e in net.edges) {
      final s = sizing[e.id];
      final len = edgeLength(e, net,
              calibrationBySheet: house.calibrations,
              building: house.building,
              mounting: house.mounting)
          .meters;
      _p('${e.id} ${e.service.name} ${e.kind.name} L=${_f(len)} '
          'FU=${fuOut[e.id]} '
          'Q=${s == null ? '-' : _f(s.flow.inLitersPerSecond, 4)} '
          'DN=${s?.diameter.inMillimeters} '
          'v=${s == null ? '-' : _f(s.velocity.metersPerSecond)} '
          'from=${s?.flowFromId}');
    }
    // Every edge is sized. Pressurized + rainwater edges carry a flow;
    // sanitary drainage is sized on accumulated DFU (its EdgeSizing flow is
    // not a DFU-path output), so it must carry units instead; a vent carries
    // neither but is still sized by its table.
    for (final e in net.edges) {
      expect(sizing[e.id], isNotNull, reason: e.id);
      expect(sizing[e.id]!.diameter.inMillimeters, greaterThan(0),
          reason: e.id);
      if (e.service == ServiceType.coldWater ||
          e.service == ServiceType.rainwater) {
        expect(sizing[e.id]!.flow.cubicMetersPerSecond, greaterThan(0),
            reason: e.id);
      } else if (e.service == ServiceType.drainage) {
        expect(fuOut[e.id], greaterThan(0), reason: e.id);
      }
    }

    final target =
        SupplyDesignCriteria.recommended().targetFixtureResidualPressure;
    final sol = solveDownfeed(
      net: net,
      service: ServiceType.coldWater,
      tankId: 'RT',
      edgeFlows: {
        for (final e in net.edges)
          if (e.service == ServiceType.coldWater && sizing[e.id] != null)
            e.id: sizing[e.id]!.flow,
      },
      sizing: sizing,
      calibrationBySheet: house.calibrations,
      building: house.building,
      targetResidual: target,
      mounting: house.mounting,
      prvSetpoint: defaultPrvSetpoint(
        targetResidual: target,
        maxFixtureStatic: profile.maxFixtureStaticPressure.value,
      ),
    );
    _p('## ENGINE downfeed critical=${sol.criticalNodeId} '
        'min=${_f(sol.minResidual.inKiloPascals)} kPa '
        'booster=${_f(sol.boosterHeadRequired.meters)} m');
    for (final id in sol.deliveryNodeIds.toList()..sort()) {
      _p('$id residual=${_f(sol.residualPressure[id]!.inKiloPascals)} '
          'static=${_f(sol.noFlowStaticPressure[id]?.inKiloPascals ?? double.nan)}');
    }
    expect(sol.deliveryNodeIds, containsAll(kHouseFixtureIds));
    for (final id in kHouseFixtureIds) {
      expect(sol.residualPressure[id], isNotNull, reason: id);
    }
  });

  test('electrical: computeSystem + computeAdvancedStudy evaluate', () {
    final project = house.electrical;
    final fault = estimatedServiceFaultLevelA(project) ??
        const Current(defaultLvUtilityFaultKa * 1000);
    final sys = computeSystem(
      const PuilProfile(),
      project,
      calibrationBySheet: house.calibrations,
      building: house.building,
      originFaultLevel: fault,
      busbarClearingTimeS: 0.1,
      phaseReassignThresholdA: 1.0,
    );
    final adv = computeAdvancedStudy(const PuilProfile(), project, sys);
    final panel = sys.panels[kHousePanelId]!;
    _p('## ENGINE electrical origin fault=${_f(fault.amperes, 1)} A');
    for (final c in panel.circuits) {
      _p('${c.circuitId} Ib=${c.designCurrent.amperes} '
          'run=${c.runCurrentA.amperes} '
          'MCB=${c.breaker.ratingA.amperes} ${c.breaker.curve.name} '
          'cable=${c.cable.csaMm2} Iz=${c.cable.deratedIz.amperes} '
          'vd=${_f(c.voltageDrop.dropPercent)}%');
    }
    _p('panel demandW=${panel.demandW} VA=${panel.demandVa} '
        'I=${panel.demandCurrent.amperes} '
        'incomer=${panel.incomer.breaker.ratingA.amperes} '
        'daya=${adv.recommendedDayaVa}');
    expect(panel.circuits.length, 9);
    for (final c in panel.circuits) {
      expect(c.breaker.ratingA.amperes, greaterThan(0), reason: c.circuitId);
      expect(c.cable.csaMm2, greaterThan(0), reason: c.circuitId);
    }
    expect(adv.fault.panels[kHousePanelId], isNotNull);
  });


  // ══ Hand-derived values (reference review 2026-11-13) ═════════════════════
  // Every expected value below was derived by hand from the rule tables
  // (docs/REFERENCE-BUILDINGS.md → house_tables) BEFORE reading the engine's
  // output. Tolerances: flow 1e-4 L/s, velocity 0.005 m/s, pressure 0.05 kPa,
  // percent 0.01, DN / ratings exact.

  double lengthOf(String id) => edgeLength(net.edgeById(id)!, net,
          calibrationBySheet: house.calibrations,
          building: house.building,
          mounting: house.mounting)
      .meters;

  group('hand values — cold water', () {
    late Map<String, EdgeSizing> sz;
    setUpAll(() => sz = size());
    // UBAP (private): WC tank 2.5, LAV 1, SH 2, KS 2, HB 2.5. Flush-TANK
    // curve: 0-10 UBAP linear at 0.05 L/s per unit; 10-25 UBAP
    // 0.5 + (u − 10)/15 × 0.38333 L/s. DN = first of 15/20/25… with
    // Q / (π D² / 4) <= 2.0 m/s. Lengths: plan + vertical leg (a ceiling main at
    // 6.7 / 3.2 m to a fixture at 4.6 / 1.1 m = 2.1 m; RT at the roof 7.0 to A1
    // at 6.7 = 0.3 m); the riser = 6.7 − 3.2 = 3.5 m.
    final cases = <String, ({double u, double q, int dn, double v, double l})>{
      // 5.5 (L2) + 10 (L1) = 15.5 u → 0.5 + 5.5/15 × 0.38333 = 0.64056 L/s;
      // DN20 would run 0.64056e-3 / 3.1416e-4 = 2.04 m/s > 2 → DN25:
      // 0.64056e-3 / 4.9087e-4 = 1.305 m/s. L = 2.0 + 0.3.
      'e_cw_RT_A1': (u: 15.5, q: 0.64056, dn: 25, v: 1.305, l: 2.3),
      // 2.5 + 1 + 2 = 5.5 u → 5.5 × 0.05 = 0.275 L/s; DN15 (A = 1.7671e-4)
      // 1.556 m/s.
      'e_cw_A1_B1': (u: 5.5, q: 0.275, dn: 15, v: 1.556, l: 3.0),
      // Fixture branches: 2.5 u → 0.125 L/s → 0.707 m/s; 1 u → 0.05 → 0.283;
      // 2 u → 0.1 → 0.566. L = plan + 2.1.
      'e_cw_B1_WC1': (u: 2.5, q: 0.125, dn: 15, v: 0.707, l: 3.1),
      'e_cw_B1_LAV1': (u: 1.0, q: 0.05, dn: 15, v: 0.283, l: 3.6),
      'e_cw_B1_SH1': (u: 2.0, q: 0.1, dn: 15, v: 0.566, l: 4.1),
      // 2.5 + 1 + 2 + 2 + 2.5 = 10 u → 0.5 L/s; DN15 = 2.83 m/s > 2 → DN20
      // (A = 3.1416e-4) 1.592 m/s.
      'e_cw_A1_A0': (u: 10.0, q: 0.5, dn: 20, v: 1.592, l: 3.5),
      'e_cw_A0_B0': (u: 10.0, q: 0.5, dn: 20, v: 1.592, l: 4.0),
      'e_cw_B0_WC0': (u: 2.5, q: 0.125, dn: 15, v: 0.707, l: 3.1),
      'e_cw_B0_LAV0': (u: 1.0, q: 0.05, dn: 15, v: 0.283, l: 3.6),
      'e_cw_B0_SH0': (u: 2.0, q: 0.1, dn: 15, v: 0.566, l: 4.1),
      // KS 2 + HB 2.5 = 4.5 u → 0.225 L/s → DN15 1.273 m/s.
      'e_cw_B0_C0': (u: 4.5, q: 0.225, dn: 15, v: 1.273, l: 3.0),
      'e_cw_C0_KS0': (u: 2.0, q: 0.1, dn: 15, v: 0.566, l: 3.1),
      'e_cw_C0_HB0': (u: 2.5, q: 0.125, dn: 15, v: 0.707, l: 7.1),
    };
    for (final MapEntry(key: id, value: x) in cases.entries) {
      test(id, () {
        final s = sz[id]!;
        expect(fuOut[id], closeTo(x.u, 1e-9));
        expect(s.flow.inLitersPerSecond, closeTo(x.q, 1e-4));
        expect(s.diameter.inMillimeters, closeTo(x.dn, 1e-9));
        expect(s.velocity.metersPerSecond, closeTo(x.v, 0.005));
        expect(lengthOf(id), closeTo(x.l, 1e-9));
        expect(s.overCapacity, isFalse);
      });
    }
  });

  group('hand values — downfeed', () {
    late DownfeedSolution sol;
    setUpAll(() => sol = _solveDown(house, size()));
    // static head = tank 7.0 − fixture z (4.6 on L2, 1.1 on L1); 1 m = 9.81 kPa.
    // 2.4 m × 9.81 = 23.544 kPa; 5.9 m × 9.81 = 57.879 kPa.
    // hf = 10.67 L Q^1.852 / (150^1.852 D^4.8704) (m, Q m³/s, D m):
    //   RT_A1 0.1771, A1_B1 0.5807, WC branch 0.1393, LAV 0.0296, SH 0.1219,
    //   riser 0.5050, A0_B0 0.5771, B0_C0 0.4005, KS 0.0922, HB 0.3191.
    // residual = (static − Σ hf on the path) × 9.81, e.g.
    //   WC1 (2.4 − 0.1771 − 0.5807 − 0.1393) × 9.81 = 14.74 kPa.
    const residual = {
      'WC1': 14.74, 'LAV1': 15.82, 'SH1': 14.91,
      'WC0': 44.16, 'LAV0': 45.24, 'SH0': 44.33,
      'KS0': 40.69, 'HB0': 38.47, //
    };
    test('the Hazen-Williams branch losses match the hand figures', () {
      double hf(double lM, double qLps, double dMm) =>
          10.67 *
          lM *
          math.pow(qLps / 1000, 1.852) /
          (math.pow(150, 1.852) * math.pow(dMm / 1000, 4.8704));
      expect(hf(2.3, 0.64056, 25), closeTo(0.1771, 5e-4));
      expect(hf(3.0, 0.275, 15), closeTo(0.5807, 5e-4));
      expect(hf(3.1, 0.125, 15), closeTo(0.1393, 5e-4));
      expect(hf(3.5, 0.5, 20), closeTo(0.5050, 5e-4));
      expect(hf(7.1, 0.125, 15), closeTo(0.3191, 5e-4));
    });
    test('static and residual per delivery node', () {
      for (final MapEntry(key: id, value: kpa) in residual.entries) {
        expect(sol.residualPressure[id]!.inKiloPascals, closeTo(kpa, 0.05),
            reason: id);
        expect(sol.noFlowStaticPressure[id]!.inKiloPascals,
            closeTo(id.endsWith('1') ? 23.544 : 57.879, 0.05),
            reason: id);
      }
    });
    test('critical WC1; booster = 225/9.81 − 1.503 = 21.43 m; every node '
        'below the 49.03 kPa SNI faucet floor', () {
      expect(sol.criticalNodeId, 'WC1');
      expect(sol.boosterHeadRequired.meters, closeTo(21.43, 0.005));
      expect(sol.gravitySufficient, isFalse);
      final floor = const SniProfile().minResidualPressureFaucet.value;
      expect(floor.inKiloPascals, closeTo(49.03, 0.05));
      for (final id in kHouseFixtureIds) {
        expect(sol.residualPressure[id]!.pascals, lessThan(floor.pascals),
            reason: id);
      }
    });
  });

  group('hand values — drainage, vent, rainwater', () {
    late Map<String, EdgeSizing> sz;
    setUpAll(() => sz = size());
    // DFU: WC 4, LAV 1, SH 2, KS 2 (HB does not drain). Branch table
    // <=3 DN40, <=6 DN50, <=20 DN75; stack table <=2 DN40, <=10 DN50; WC floor
    // DN75 (<= 2 WCs on a branch); shower trap floor DN50.
    final cases = <String, ({double dfu, int dn, double l})>{
      'e_dr_WC1_D1': (dfu: 4, dn: 75, l: 1.5), // table DN50, WC floor ⇒ DN75
      'e_dr_LAV1_D1': (dfu: 1, dn: 40, l: 1.5), // 1 <= 3 ⇒ DN40
      'e_dr_SH1_D1': (dfu: 2, dn: 50, l: 1.5), // DN40, trap floor ⇒ DN50
      // Stack: 4 + 1 + 2 = 7 DFU → stack table DN50, WC floor ⇒ DN75;
      // L = under L2 slab (ceiling of L1, 3.2) − foot on the slab (0.0).
      'e_dr_D1_D0': (dfu: 7, dn: 75, l: 3.2),
      'e_dr_WC0_D0': (dfu: 4, dn: 75, l: 1.5),
      'e_dr_LAV0_D0': (dfu: 1, dn: 40, l: 1.5),
      'e_dr_SH0_D0': (dfu: 2, dn: 50, l: 1.5),
      'e_dr_KS0_D0': (dfu: 2, dn: 40, l: 2.0), // 2 <= 3 ⇒ DN40
      // 7 + 4 + 1 + 2 + 2 = 16 DFU → branch DN75 (<= 20); 2 WCs, not > 2.
      'e_dr_D0_OUT': (dfu: 16, dn: 75, l: 6.0),
    };
    for (final MapEntry(key: id, value: x) in cases.entries) {
      test(id, () {
        expect(fuOut[id], closeTo(x.dfu, 1e-9));
        expect(sz[id]!.diameter.inMillimeters, closeTo(x.dn, 1e-9));
        expect(lengthOf(id), closeTo(x.l, 1e-9));
      });
    }
    test('vent: 7 DFU → DN40 (>= ½ × DN75 = 37.5 → 40); M1 stack vent '
        '3.2 → 7.0 = 3.8 m', () {
      expect(fuOut['e_vt_D1_VTR'], closeTo(7, 1e-9));
      expect(sz['e_vt_D1_VTR']!.diameter.inMillimeters, closeTo(40, 1e-9));
      expect(lengthOf('e_vt_D1_VTR'), closeTo(3.8, 1e-9));
      // The node inspector reads the same riser-end datums.
      expect(
          displayedNodeElevation(
                  net, net.nodeById('D1')!, house.building, house.mounting)
              .meters,
          closeTo(3.2, 1e-9));
      expect(
          displayedNodeElevation(
                  net, net.nodeById('VTR')!, house.building, house.mounting)
              .meters,
          closeTo(7.0, 1e-9));
    });
    test('rainwater: Q = 0.9 × 200 × 60 / 3.6e6 = 3.000 L/s', () {
      for (final id in ['e_rw_RD_RW1', 'e_rw_RW1_RW0', 'e_rw_RW0_RWOUT']) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(3.0, 1e-4), reason: id);
        // Collectors: half-full Manning at 1 %: DN75 carries 1.56 L/s < 3,
        // DN100 3.36 ⇒ DN100. Riser: downpipe table gives DN65 (<= 3.4 L/s),
        // raised to the DN100 collector (no necking).
        expect(sz[id]!.diameter.inMillimeters, closeTo(100, 1e-9), reason: id);
      }
      expect(sz['e_rw_RW1_RW0']!.stackRaisedForBranch, isTrue);
      // Leader: 1.0 plan + roof 7.0 − RW1 under-slab 3.2 = 4.8 m.
      expect(lengthOf('e_rw_RD_RW1'), closeTo(4.8, 1e-9));
      expect(lengthOf('e_rw_RW1_RW0'), closeTo(3.2, 1e-9));
      expect(lengthOf('e_rw_RW0_RWOUT'), closeTo(4.0, 1e-9));
    });
  });

  group('hand values — electrical', () {
    late ElectricalSystemResult sys;
    late AdvancedStudy adv;
    setUpAll(() {
      final r = _solveElectrical(house);
      sys = r.sys;
      adv = r.adv;
    });
    // V = 220; I = W / (V cos φ); final ways size and run on the
    // UNDIVERSIFIED current (run current rounded to 0.1 A); Ib (design) is
    // the diversified one. VD = 2 I L (R cos φ + 0.08 sin φ) / 1000 / 220.
    final cases = <String,
        ({
          double runA,
          double ibA,
          int mcb,
          String curve,
          double csa,
          double vd,
          bool rcd,
          String family,
        })>{
      // 300 / (220 × 0.9) = 1.515 A → MCB 6 B; 1.5 mm²; VD 2 × 1.515 × 12 ×
      // (14.5 × 0.9 + 0.08 × 0.436) / 1000 / 220 = 0.22 %.
      'c_lampu_lt1': (runA: 1.515, ibA: 1.515, mcb: 6, curve: 'b', csa: 1.5,
          vd: 0.22, rcd: false, family: 'NYM'),
      // 250 / 198 = 1.263 A; 15 m ⇒ 0.23 %.
      'c_lampu_lt2': (runA: 1.263, ibA: 1.263, mcb: 6, curve: 'b', csa: 1.5,
          vd: 0.23, rcd: false, family: 'NYM'),
      // 1200 / 198 = 6.061 A (diversified × 0.7 = 4.24) → MCB 10 C (Iz_req
      // max(10, 7.6)); 2.5 mm² (21 A); 0.66 %; socket ⇒ 30 mA RCD.
      'c_kk_lt1': (runA: 6.061, ibA: 4.242, mcb: 10, curve: 'c', csa: 2.5,
          vd: 0.66, rcd: true, family: 'NYM'),
      // 800 / 198 = 4.040 (2.83) → 6 A; 0.53 %.
      'c_kk_lt2': (runA: 4.040, ibA: 2.828, mcb: 6, curve: 'c', csa: 2.5,
          vd: 0.53, rcd: true, family: 'NYM'),
      // 2000 / 198 = 10.101 (7.07) → 16 A; 0.74 %.
      'c_kk_dapur': (runA: 10.101, ibA: 7.071, mcb: 16, curve: 'c', csa: 2.5,
          vd: 0.74, rcd: true, family: 'NYM'),
      // 750 / (220 × 0.85) = 4.011 (× 0.9 = 3.61) → 6 A C; 2.5 NYY;
      // 14 m ⇒ 0.39 %, 16 m ⇒ 0.44 %.
      'c_ac_k1': (runA: 4.011, ibA: 3.610, mcb: 6, curve: 'c', csa: 2.5,
          vd: 0.39, rcd: false, family: 'NYY'),
      'c_ac_k2': (runA: 4.011, ibA: 3.610, mcb: 6, curve: 'c', csa: 2.5,
          vd: 0.44, rcd: false, family: 'NYY'),
      // 1500 / 220 = 6.818 → 10 A C (Iz_req max(10, 8.5)); 0.66 %.
      'c_pemanas': (runA: 6.818, ibA: 6.818, mcb: 10, curve: 'c', csa: 2.5,
          vd: 0.66, rcd: false, family: 'NYM'),
      // (250 / 0.88) / (220 × 0.85) = 1.519 → 6 A D; 2.5 NYY; 0.08 %.
      'c_pompa': (runA: 1.519, ibA: 1.519, mcb: 6, curve: 'd', csa: 2.5,
          vd: 0.08, rcd: false, family: 'NYY'),
    };
    for (final MapEntry(key: id, value: x) in cases.entries) {
      test(id, () {
        final c = sys.panels[kHousePanelId]!.circuits
            .firstWhere((r) => r.circuitId == id);
        expect(c.threePhase, isFalse);
        // The run current is reported rounded to 0.1 A.
        expect(c.runCurrentA.amperes, closeTo(x.runA, 0.05));
        expect(c.designCurrentSumA, closeTo(x.ibA, 1e-3));
        expect(c.breaker.ratingA.amperes, x.mcb.toDouble());
        expect(c.breaker.deviceClass, BreakerClass.mcb);
        expect(c.breaker.curve.name, x.curve);
        expect(c.cable.csaMm2, x.csa);
        expect(c.grounding.cableType, x.family);
        expect(c.grounding.peCsaMm2, x.csa); // PE = phase CSA (<= 16 mm²)
        expect(c.voltageDrop.dropPercent, closeTo(x.vd, 0.01));
        expect(c.rcd.required, x.rcd);
        if (x.rcd) expect(c.rcd.ratingMa, 30);
        expect(adv.fault.circuits[id]!.breakerKa, 6.0);
      });
    }
    test('panel, incomer, busbar, fault, daya, warnings', () {
      final p = sys.panels[kHousePanelId]!;
      // 300 + 250 + 840 + 560 + 1400 + 675 + 675 + 1500 + 284.09 = 6484.09 W
      // (the engine reports whole W).
      expect(p.demandW, closeTo(6484.09, 0.5));
      // 3350/0.9 + 1350/0.85 + 1500 + 284.09/0.85 = 7144.7 VA (whole VA).
      expect(p.demandVa, closeTo(7144.7, 0.5));
      // 7144.7 / 220 = 32.48 A (reported to 0.1 A).
      expect(p.demandCurrent.amperes, closeTo(32.48, 0.05));
      // Incomer on max(20 [4400 / 220], 10.1 [largest way], 32.48) → 40 A.
      expect(p.incomer.breaker.ratingA.amperes, 40);
      expect(p.incomer.breaker.deviceClass, BreakerClass.mcb);
      expect(p.incomer.poles, 2);
      expect(adv.fault.panels[kHousePanelId]!.incomerKa, 6.0);
      // Busbar 12 × 2 (110 A >= 40 A); withstand 6000 × √0.1 / 80 =
      // 23.7 mm² <= 24.
      expect(p.busbar.widthMm, 12);
      expect(p.busbar.thicknessMm, 2);
      expect(p.busbar.withstand!.adequate, isTrue);
      // Origin fault: declared 4400 VA <= 16.5 kVA ⇒ 6 kA.
      expect(adv.fault.originFaultkA, 6.0);
      // Daya: first 1φ step >= 7145 VA = 7700 VA.
      expect(adv.recommendedDayaVa, 7700);
      expect(adv.recommendedDayaThreePhase, isFalse);
      // M2 — the all-1φ LV note quotes no 3φ worst-phase basis.
      expect(adv.supply.lvOrMv, SupplyLevel.lv);
      expect(adv.supply.note, isNot(contains('worst-phase')));
      expect(adv.supply.note, contains('7.1 kVA'));
      expect(adv.supply.note, contains('7,700 VA'));
      // Exactly one warning: 32.5 A on L1 > 4400 / 220 = 20 A.
      final codes = [
        ...sys.warnings.map((w) => w.code),
        ...adv.fault.warnings.map((w) => w.code),
      ];
      expect(codes, ['service-capacity-below-demand']);
    });
  });
}

/// The downfeed solve with the app's arguments (target 225 kPa, PRV setpoint
/// = target + margin).
DownfeedSolution _solveDown(ReferenceBuilding house, Map<String, EdgeSizing> sz) {
  final net = house.network;
  final target =
      SupplyDesignCriteria.recommended().targetFixtureResidualPressure;
  return solveDownfeed(
    net: net,
    service: ServiceType.coldWater,
    tankId: 'RT',
    edgeFlows: {
      for (final e in net.edges)
        if (e.service == ServiceType.coldWater && sz[e.id] != null)
          e.id: sz[e.id]!.flow,
    },
    sizing: sz,
    calibrationBySheet: house.calibrations,
    building: house.building,
    targetResidual: target,
    mounting: house.mounting,
    prvSetpoint: defaultPrvSetpoint(
      targetResidual: target,
      maxFixtureStatic: const SniProfile().maxFixtureStaticPressure.value,
    ),
  );
}

/// The electrical solve on the app's fault chain for this project (an
/// explicit level is absent; the declared PLN service gives the estimate).
({ElectricalSystemResult sys, AdvancedStudy adv}) _solveElectrical(
    ReferenceBuilding house) {
  final project = house.electrical;
  final fault = estimatedServiceFaultLevelA(project) ??
      const Current(defaultLvUtilityFaultKa * 1000);
  final sys = computeSystem(
    const PuilProfile(),
    project,
    calibrationBySheet: house.calibrations,
    building: house.building,
    originFaultLevel: fault,
    busbarClearingTimeS: 0.1,
    phaseReassignThresholdA: 1.0,
  );
  return (
    sys: sys,
    adv: computeAdvancedStudy(const PuilProfile(), project, sys),
  );
}
