// Reference building 3 (office) — ENGINE-level solve smoke test.
//
// Builds the fixed 4-storey office (`test/reference/office.dart`) and runs it
// through the real engine: `autoSizeNetwork` with the argument set the app's
// `sizingDetailProvider` passes (building + calibrations, public-occupancy
// UBAP, the flush-valve node set, the light-hazard sprinkler head flow + the
// remote-area cap, the standpipe design flow), one UPFEED pressure solve from
// the sizer root, the fire design primitives (sprinkler design + remote-area
// hydraulics, standpipe design, the sized index-path friction from FP), the
// room air sizing of the Lantai 2 office, and the electrical `computeSystem`
// + `computeAdvancedStudy` over LVMDP and the four floor sub-boards. It
// asserts only that nothing throws and every flowing edge comes back sized;
// the hand-derived expected values are a later task. Set REF_DUMP=1 to print
// the solved figures.
//
// What the engine level does NOT do (app-only, see the app test): the pump /
// fire-pump / fan duties, the delivered field with P1 running, the fire
// system basis (rated point, NFPA 20 motor, jockey), the duct-network fan
// static and the MEP-equipment electrical sync.
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
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/office.dart';

// The app-side defaults `sizingDetailProvider` feeds the sizer (mirrored, as
// in the house / shophouse tests: the engine cannot import the app).
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
const FireHazardClass _hazard = FireHazardClass.lightHazard;

final bool _dump = Platform.environment['REF_DUMP'] == '1';
void _p(String s) {
  if (_dump) print(s); // ignore: avoid_print
}

String _f(double v, [int dp = 3]) => v.toStringAsFixed(dp);

void main() {
  final office = buildOffice();
  final net = office.network;
  const profile = SniProfile();
  final sprinkler = designSprinklerSystem(hazard: _hazard);
  final remote = remoteAreaHydraulics(
      design: sprinkler, kFactor: kDefaultPendentKFactor);
  final standpipe = designStandpipe(
      risers: drawnStandpipeRiserCount(net),
      buildingHeight: standpipeStaticLift(office.building));
  final flushValveIds = {
    for (final n in net.nodes)
      if (n.fixture == PlumbingFixture.waterClosetFlushValve) n.id,
  };

  double lengthOf(NetEdge e) => edgeLength(e, net,
          calibrationBySheet: office.calibrations,
          building: office.building,
          mounting: office.mounting)
      .meters;

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
        ServiceType.fireSprinkler: remote.remoteHeadFlow,
      },
      leafFixtureUnits: _leafFixtureUnits,
      nodeFixtureUnits: {
        for (final n in net.nodes)
          if (n.fixture != null)
            n.id: profile.fixtureUnitLoad(n.fixture!,
                occupancy: office.occupancy),
      },
      nodeDrainageUnits: {
        for (final n in net.nodes)
          if (n.fixture != null) n.id: drainageFixtureUnit(n.fixture!),
      },
      nodeFlowDemand: {
        for (final n in net.nodes)
          if (n.airflow != null) n.id: n.airflow!,
        for (final n in net.nodes)
          if (n.roofAreaM2 != null && n.airflow == null)
            n.id: rainwaterDesignFlow(
                intensityMmPerHr: _rainfallMmPerHr,
                roofAreaM2: n.roofAreaM2!,
                runoffCoefficient: kDefaultRunoffCoefficient),
      },
      sprinklerDemandCap: remote.remoteAreaDemand,
      hydrantDesignFlow: standpipe.requiredFlow,
      flushSystem: FlushSystem.flushValve,
      flushValveNodeIds: flushValveIds,
      building: office.building,
      calibrationBySheet: office.calibrations,
      mounting: office.mounting,
      fixtureUnitsOut: fuOut,
    );
  }

  test('the office fixture is the spec: 4 floors, every run its exact plan '
      'length', () {
    expect(office.building.levelCount, 4);
    final cal = office.calibrations.values.first;
    double plan(String id) {
      final e = net.edgeById(id)!;
      return cal.lengthForPixels(runPixelLength(e, net)).meters;
    }

    final runM = <String, double>{
      'e_cw_WM_GT': 3.0, 'e_cw_GT_P1': 1.0, 'e_cw_P1_R0': 2.0,
      'e_dr_D0_OUT': 10.0, 'e_rw_RDa_RW3': 2.0, 'e_rw_RDb_RW3': 2.0,
      'e_rw_RW0_RWOUT': 6.0, 'e_fh_FT_FP': 2.0, 'e_fh_FP_H0': 3.0,
      'e_sp_FP_S0': 4.0, 'e_sp_S3_SP1': 3.0,
      for (var i = 2; i <= 6; i++) 'e_sp_SP${i - 1}_SP$i': 3.0,
      'e_sa_FCU1_SD1': 3.0,
      for (var i = 2; i <= 4; i++) 'e_sa_SD${i - 1}_SD$i': 3.0,
      'e_ra_RG1_FCU1': 2.0,
      for (var f = 0; f < 4; f++) ...{
        'e_cw_R${f}_T$f': 3.0,
        for (final b in kOfficeFloorFixtures) ...{
          'e_cw_T${f}_$b$f': kOfficeBranchM[b]!,
          'e_dr_$b${f}_D$f': 1.5,
        },
        'e_fh_H${f}_HYD$f': 2.0,
      },
    };
    for (final MapEntry(:key, :value) in runM.entries) {
      expect(plan(key), closeTo(value, 1e-9), reason: key);
    }
    final room = kOfficeRooms.single;
    expect(room.widthM, closeTo(10.0, 1e-12));
    expect(room.depthM, closeTo(15.0, 1e-12));
  });

  test('mechanical + fire + air: sizes every flowing edge and solves the '
      'upfeed', () {
    final sizing = size();
    _p('## ENGINE sizing (edge service kind L FU Q DN WxH v from)');
    for (final e in net.edges) {
      final s = sizing[e.id];
      _p('${e.id} ${e.service.name} ${e.kind.name} L=${_f(lengthOf(e))} '
          'FU=${fuOut[e.id]} '
          'Q=${s == null ? '-' : _f(s.flow.inLitersPerSecond, 4)} '
          'DN=${s?.diameter.inMillimeters} '
          '${s?.width == null ? '' : 'WxH=${s!.width!.inMillimeters}x${s.height!.inMillimeters} '}'
          'v=${s == null ? '-' : _f(s.velocity.metersPerSecond)} '
          'from=${s?.flowFromId}'
          '${(s?.overCapacity ?? false) ? ' overCapacity' : ''}');
    }
    for (final e in net.edges) {
      expect(sizing[e.id], isNotNull, reason: e.id);
      expect(sizing[e.id]!.diameter.inMillimeters, greaterThan(0),
          reason: e.id);
    }

    // Upfeed from the sizer root.
    final target =
        SupplyDesignCriteria.recommended().targetFixtureResidualPressure;
    final roots = serviceComponentRoots(net, ServiceType.coldWater,
        demandNodeIds: {
          for (final n in net.nodes)
            if (n.role == NodeRole.fixture) n.id,
        });
    final root = {for (final r in roots.values) r}.single;
    final sol = solvePressurized(
      net: net,
      service: ServiceType.coldWater,
      sourceId: root,
      edgeFlows: {
        for (final e in net.edges)
          if (e.service == ServiceType.coldWater && sizing[e.id] != null)
            e.id: sizing[e.id]!.flow,
      },
      sizing: sizing,
      calibrationBySheet: office.calibrations,
      building: office.building,
      targetResidual: target,
      mounting: office.mounting,
      prvSetpoint: defaultPrvSetpoint(
        targetResidual: target,
        maxFixtureStatic: profile.maxFixtureStaticPressure.value,
      ),
    );
    _p('## ENGINE upfeed from $root critical=${sol.criticalNodeId} '
        'requiredPumpHead=${_f(sol.requiredPumpHead.meters)} m '
        'target=${_f(target.inKiloPascals)} kPa '
        'targetHeldByDesign=${sol.targetHeldByDesign}');
    final ids = sol.residualPressure.keys.toList()..sort();
    for (final id in ids) {
      _p('$id delivery=${sol.deliveryNodeIds.contains(id)} '
          'residual=${_f(sol.residualPressure[id]!.inKiloPascals)} '
          'static=${_f(sol.noFlowStaticPressure[id]?.inKiloPascals ?? double.nan)} kPa');
    }
    for (var f = 0; f < 4; f++) {
      for (final b in kOfficeFloorFixtures) {
        expect(sol.deliveryNodeIds, contains('$b$f'));
      }
    }
    expect(sol.requiredPumpHead.meters, greaterThan(0));

    // Fire design primitives.
    _p('## ENGINE sprinkler design hazard=${sprinkler.hazard.name} '
        'designArea=${_f(sprinkler.designAreaValue.squareMeters)} m2 '
        'requiredFlow=${_f(sprinkler.requiredFlow.inLitersPerSecond, 4)} L/s '
        'count=${sprinkler.sprinklerCount} '
        'perHead=${_f(sprinkler.flowPerSprinkler.inLitersPerSecond, 4)} L/s');
    _p('## ENGINE remote area K=${remote.kFactor} '
        'remoteHeadFlow=${_f(remote.remoteHeadFlow.inLitersPerSecond, 4)} L/s '
        'densityShare=${_f(remote.densityShareFlow.inLitersPerSecond, 4)} L/s '
        'remoteHeadP=${_f(remote.remoteHeadPressure.inKiloPascals)} kPa '
        'minOpP=${_f(remote.minOperatingPressure.inKiloPascals)} kPa '
        'branchFriction=${_f(remote.branchLineFrictionHead.meters)} m '
        'branchBaseP=${_f(remote.branchBasePressure.inKiloPascals)} kPa '
        'remoteAreaDemand=${_f(remote.remoteAreaDemand.inLitersPerSecond, 4)} L/s '
        'governedByMinP=${remote.governedByMinimumPressure}');
    _p('## ENGINE standpipe (advisory, friction-free) risers='
        '${drawnStandpipeRiserCount(net)} '
        'lift=${_f(standpipeStaticLift(office.building).meters)} m '
        'class=${standpipe.standpipeClass.name} '
        'flow=${_f(standpipe.requiredFlow.inLitersPerSecond, 4)} L/s '
        'topResidual=${_f(standpipe.topResidualPressure.inKiloPascals)} kPa '
        'minRiser=${standpipe.minRiserDiameter.inMillimeters} '
        'pumpHead=${_f(standpipe.pumpHead.meters)} m '
        'hyd=${_f(standpipe.pumpHydraulicPower.watts, 1)} W '
        'shaft=${_f(standpipe.pumpShaftPower.watts, 1)} W');
    final sys = fireSystems(net);
    _p('## ENGINE fire systems: ${sys.length}');
    for (final s in sys) {
      for (final kind in FireTerminalKind.values) {
        final per = <String, double>{};
        final fr = fireIndexPathFrictionM(
          net: net,
          system: s,
          pumpId: 'FP',
          sizing: sizing,
          lengthOf: lengthOf,
          terminals: kind,
          frictionByTerminalOut: per,
        );
        _p('index friction from FP to ${kind.name}: '
            '${fr == null ? null : _f(fr)} m '
            'perTerminal=${{
          for (final e in (per.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
            e.key: _f(e.value)
        }}');
      }
    }
    expect(sys, isNotEmpty);
  });

  test('room air: the Lantai 2 office by the ACH method', () {
    final r = officeRoomAir();
    final room = kOfficeRooms.single;
    const v = SniVentilationProfile();
    _p('## ENGINE room air ${room.name} type=${room.roomType.name} '
        'area=${_f(room.widthM * room.depthM)} m2 ceiling=$kOfficeRoomCeilingM '
        'volume=${_f(r.roomVolumeM3)} m3 ACH=${r.airChangesPerHour} '
        'airflow=${_f(r.airflow.inLitersPerSecond, 3)} L/s '
        '(${_f(r.airflowCfm, 1)} CFM, ${_f(r.airflow.cubicMetersPerSecond, 6)} m3/s) '
        'grilleApp=${v.grilleApplicationFor(room.roomType).name} '
        'equipment=${r.equipmentKind.name}');
    _p('supply bank: count=${r.supply.count} '
        'each=${_f(r.supply.airflowEach.inLitersPerSecond, 3)} L/s '
        'face=${r.supply.faceMm} gross=${_f(r.supply.each.grossFaceArea.squareMeters, 4)} m2 '
        'free=${_f(r.supply.each.freeArea.squareMeters, 4)} m2 '
        'faceV=${_f(r.supply.each.faceVelocity.metersPerSecond)} m/s');
    _p('return bank: count=${r.return_.count} '
        'each=${_f(r.return_.airflowEach.inLitersPerSecond, 3)} L/s '
        'face=${r.return_.faceMm} gross=${_f(r.return_.each.grossFaceArea.squareMeters, 4)} m2 '
        'faceV=${_f(r.return_.each.faceVelocity.metersPerSecond)} m/s');
    _p('trunk: D=${r.supplyDuctDiameter.inMillimeters} mm '
        'v=${_f(r.supplyDuctVelocity.metersPerSecond)} m/s '
        'friction=${_f(r.supplyDuctRound!.frictionPerMetrePa, 4)} Pa/m '
        'overCapacity=${r.trunkOverCapacity}');
    final e = r.equipment;
    _p('equipment: static=${_f(e.totalStaticPressure.pascals, 2)} Pa '
        'air=${_f(e.airPower.watts, 2)} W shaft=${_f(e.shaftPower.watts, 2)} W '
        'input=${_f(e.motorInputPower.watts, 2)} W '
        'motor=${_f(e.selectedMotor.inKiloWatts, 2)} kW '
        'oversized=${e.motorOversized}');
    _p('stamped: SD each=${_f(kOfficeRoomAirflow.inLitersPerSecond / 4, 4)} L/s '
        'RG1=${_f(kOfficeRoomAirflow.inLitersPerSecond, 4)} L/s');
    expect(r.airflow.cubicMetersPerSecond, greaterThan(0));
  });

  test('electrical: computeSystem + computeAdvancedStudy over LVMDP and the '
      'four floor sub-boards', () {
    final project = office.electrical;
    final fault = estimatedServiceFaultLevelA(project) ??
        const Current(defaultLvUtilityFaultKa * 1000);
    final sys = computeSystem(
      const PuilProfile(),
      project,
      calibrationBySheet: office.calibrations,
      building: office.building,
      originFaultLevel: fault,
      busbarClearingTimeS: 0.1,
      phaseReassignThresholdA: 1.0,
    );
    final adv = computeAdvancedStudy(const PuilProfile(), project, sys);
    _p('## ENGINE electrical origin fault=${_f(fault.amperes, 1)} A');
    for (final pid in sys.order) {
      final panel = sys.panels[pid]!;
      final pf = adv.fault.panels[pid];
      _p('### ${panel.name} system=${panel.system.name} '
          'busFault=${pf?.prospectiveFaultkA} kA');
      for (final c in panel.circuits) {
        final cf = adv.fault.circuits[c.circuitId];
        _p('${c.circuitId} kind=${c.loadKind.name} 3ph=${c.threePhase} '
            'phase=${c.phase.name} Ib=${c.designCurrent.amperes} '
            '(exact ${c.designCurrentExactA}) run=${c.runCurrentA.amperes} '
            'breaker=${c.breaker.deviceClass.code} ${c.breaker.ratingA.amperes} '
            '${c.breaker.curve.name} cable=${c.cable.csaMm2} '
            'Iz=${c.cable.deratedIz.amperes} (${c.cable.appliedRule}) '
            'vd=${_f(c.voltageDrop.dropPercent)}% (${_f(c.voltageDrop.dropV)} V, '
            'lim ${c.voltageDrop.limitPercent}) cum=${_f(c.cumulativeDropPercent)}% '
            'L=${c.lengthM} kA=${cf?.breakerKa} fault=${cf?.faultkA}');
      }
      _p('panel ${panel.name} demandW=${panel.demandW} VA=${panel.demandVa} '
          'I=${panel.demandCurrent.amperes} '
          'incomer=${panel.incomer.breaker.ratingA.amperes} '
          'phaseBalance=${panel.phaseBalance.l1}/${panel.phaseBalance.l2}/'
          '${panel.phaseBalance.l3} incomerSizing='
          '${panel.incomer.sizingCurrent?.amperes} '
          '${panel.incomer.breaker.deviceClass.code} ${panel.incomer.poles}P '
          'busbar=${panel.busbar.widthMm}x${panel.busbar.thicknessMm}');
      for (final c in panel.circuits) {
        expect(c.breaker.ratingA.amperes, greaterThan(0), reason: c.circuitId);
        expect(c.cable.csaMm2, greaterThan(0), reason: c.circuitId);
      }
      expect(adv.fault.panels[pid], isNotNull);
    }
    expect(sys.panels[kOfficeMainPanelId]!.circuits.length, 4);
    for (final t in kOfficeFloorTags) {
      expect(sys.panels[officePanelId(t)]!.circuits.length, 8);
    }
    _p('supply demandVa=${sys.supply.demandVa.voltAmperes} '
        'system=${sys.supply.system.name} '
        'level=${adv.supply.lvOrMv.name} demandKva=${adv.supply.demandKva} '
        'daya=${adv.recommendedDayaVa} threePhase=${adv.recommendedDayaThreePhase}');
    final roots = originPanelIdsOf(sys, project).toList()..sort();
    for (final id in roots) {
      final va = rootServiceBasisVa(project, sys, id);
      _p('root $id basisVa=${_f(va, 1)} '
          'lineA=${_f(va / (1.7320508075688772 * 400), 2)}');
    }
    _p('servicePerPhaseBasisVa='
        '${_f(servicePerPhaseBasisVa(project, sys, roots), 1)} '
        '(= 3 x heaviest line)');
    _p('warnings: ${sys.warnings.length + adv.fault.warnings.length + adv.warnings.length}');
    for (final w in [...sys.warnings, ...adv.fault.warnings, ...adv.warnings]) {
      _p('- [${w.severity.name}] ${w.code} (${w.panelId}/${w.circuitId}): '
          '${w.message}');
    }
  });
}
