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

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart'
    show defaultLvUtilityFaultKa, estimatedServiceFaultLevelA;
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
}
