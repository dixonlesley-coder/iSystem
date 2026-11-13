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
import 'package:mechx_engine/hydraulics.dart' show headLossHazenWilliams;
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

  // ── Hand-derived pins (reviewer pass 2, 2026-11-13) ─────────────────────
  group('hand values — cold water (public, flush-valve curve)', () {
    late Map<String, EdgeSizing> sz;
    late Map<String, double> fu;
    setUpAll(() {
      sz = size();
      fu = Map.of(fuOut);
    });
    // UBAP per floor 2 x 10 (WC valve) + 2 (urinal) + 2 x 1 (LAV) = 24.
    // Valve curve: 24 → 0.88333 + 14/15 x 0.63334 = 1.47445; 48 → 1.51667 +
    // 23/25 x 1.06666 = 2.49800; 72 → 2.58333 + 22/50 x 1.45 = 3.22133; 96 →
    // 2.58333 + 46/50 x 1.45 = 3.91733; WC 10 → 0.88333; UR 2 → 0.17667;
    // LAV 1 → 0.08833. DN: first nominal with v <= 2.0 m/s.
    const trunk = <String, ({double l, double fu, double q, int dn, double v})>{
      'e_cw_WM_GT': (l: 6.7, fu: 96, q: 3.91733, dn: 50, v: 1.995),
      'e_cw_GT_P1': (l: 1.0, fu: 96, q: 3.91733, dn: 50, v: 1.995),
      'e_cw_P1_R0': (l: 5.7, fu: 96, q: 3.91733, dn: 50, v: 1.995),
      'e_cw_R0_R1': (l: 4.0, fu: 72, q: 3.22133, dn: 50, v: 1.641),
      'e_cw_R1_R2': (l: 4.0, fu: 48, q: 2.49800, dn: 40, v: 1.988),
      'e_cw_R2_R3': (l: 4.0, fu: 24, q: 1.47445, dn: 32, v: 1.833),
    };
    // Per floor: plan + the drop from the ceiling main (3.7 m above its
    // slab) to the 1.1 m fixture = plan + 2.6 m.
    const branch = <String, ({double l, double fu, double q, int dn, double v})>{
      'WCa': (l: 3.6, fu: 10, q: 0.88333, dn: 25, v: 1.800),
      'WCb': (l: 4.6, fu: 10, q: 0.88333, dn: 25, v: 1.800),
      'UR': (l: 5.6, fu: 2, q: 0.17667, dn: 15, v: 1.000),
      'LAVa': (l: 4.1, fu: 1, q: 0.08833, dn: 15, v: 0.500),
      'LAVb': (l: 5.1, fu: 1, q: 0.08833, dn: 15, v: 0.500),
    };
    void check(
        String id, ({double l, double fu, double q, int dn, double v}) x) {
      expect(lengthOf(net.edgeById(id)!), closeTo(x.l, 1e-9), reason: id);
      expect(fu[id], closeTo(x.fu, 1e-9), reason: id);
      expect(sz[id]!.flow.inLitersPerSecond, closeTo(x.q, 5e-5), reason: id);
      expect(sz[id]!.diameter.inMillimeters, x.dn, reason: id);
      expect(sz[id]!.velocity.metersPerSecond, closeTo(x.v, 5e-4),
          reason: id);
    }

    test('trunk and riser', () {
      for (final MapEntry(:key, :value) in trunk.entries) {
        check(key, value);
      }
    });
    test('every floor: R → T DN32 at 24 UBAP and the five branches', () {
      for (var f = 0; f < 4; f++) {
        check('e_cw_R${f}_T$f',
            (l: 3.0, fu: 24, q: 1.47445, dn: 32, v: 1.833));
        for (final MapEntry(:key, :value) in branch.entries) {
          check('e_cw_T${f}_$key$f', value);
        }
      }
    });
    test('Hazen–Williams C150 friction per metre', () {
      double hf(double lps, int dn) => headLossHazenWilliams(
            flow: FlowRate.litersPerSecond(lps),
            length: const Length(1),
            diameter: Diameter.mm(dn.toDouble()),
            hazenWilliamsC: 150,
          ).meters;
      expect(hf(3.917333, 50), closeTo(0.075302, 5e-6));
      expect(hf(3.221333, 50), closeTo(0.052414, 5e-6));
      expect(hf(2.498, 40), closeTo(0.097030, 5e-6));
      expect(hf(1.474445, 32), closeTo(0.108357, 5e-6));
      expect(hf(0.883333, 25), closeTo(0.139615, 5e-6));
    });
  });

  group('hand values — upfeed from GT', () {
    test('required head 38.539 m at WCb3, statics by floor, all residuals',
        () {
      final sizing = size();
      final target =
          SupplyDesignCriteria.recommended().targetFixtureResidualPressure;
      final sol = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 'GT',
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
      // Path GT → WCb3: 0.075302 x 6.7 (GT→P1 1.0 + P1→R0 5.7) + 0.052414 x
      // 4 + 0.097030 x 4 + 0.108357 x 7 (R2→R3 4 + R3→T3 3) + 0.139615 x
      // 4.6 = 2.503 m; + lift 13.1 (WCb3 at 12.0 + 1.1) + 225 / 9.81 =
      // 38.539 m.
      expect(sol.criticalNodeId, 'WCb3');
      expect(sol.requiredPumpHead.meters, closeTo(38.539, 5e-4));
      // Fixture static = 9.81 x (38.539 − z), z = 1.1 / 5.1 / 9.1 / 13.1.
      const statics = [367.275, 328.035, 288.795, 249.555];
      const residuals = <String, List<double>>{
        'WCa': [354.206, 312.909, 269.862, 226.370],
        'WCb': [352.836, 311.539, 268.492, 225.000],
        'UR': [354.451, 313.154, 270.106, 226.614],
        'LAVa': [358.186, 316.889, 273.842, 230.350],
        'LAVb': [357.954, 316.658, 273.610, 230.118],
      };
      for (var f = 0; f < 4; f++) {
        for (final MapEntry(:key, :value) in residuals.entries) {
          final id = '$key$f';
          expect(sol.deliveryNodeIds, contains(id));
          expect(sol.noFlowStaticPressure[id]!.inKiloPascals,
              closeTo(statics[f], 2e-3),
              reason: id);
          expect(sol.residualPressure[id]!.inKiloPascals,
              closeTo(value[f], 2e-3),
              reason: id);
          // Above the SNI floor (98.067 at a flush-valve WC, 49.033
          // otherwise); every static under 392.266 kPa.
          expect(sol.residualPressure[id]!.inKiloPascals,
              greaterThan(key.startsWith('WC') ? 98.067 : 49.033));
          expect(sol.noFlowStaticPressure[id]!.inKiloPascals,
              lessThan(392.266));
        }
      }
    });
  });

  group('hand values — drainage, vent, rainwater', () {
    late Map<String, EdgeSizing> sz;
    late Map<String, double> fu;
    setUpAll(() {
      sz = size();
      fu = Map.of(fuOut);
    });
    test('fixture arms, stack, building drain, vent', () {
      // DFU: WC valve 8, urinal 4, LAV 1 ⇒ 22 per floor. WC arm DN75 (WC
      // floor), UR DN50 (trap floor), LAV DN40 (branch table <= 3).
      for (var f = 0; f < 4; f++) {
        for (final (b, dfu, dn) in [
          ('WCa', 8.0, 75), ('WCb', 8.0, 75), ('UR', 4.0, 50),
          ('LAVa', 1.0, 40), ('LAVb', 1.0, 40), //
        ]) {
          final id = 'e_dr_$b${f}_D$f';
          expect(fu[id], dfu, reason: id);
          expect(sz[id]!.diameter.inMillimeters, dn, reason: id);
        }
      }
      // Stack table <= 42 → DN75, <= 240 → DN100; the drain on the branch
      // table <= 160 → DN100.
      for (final (id, dfu, dn) in [
        ('e_dr_D3_D2', 22.0, 75), ('e_dr_D2_D1', 44.0, 100),
        ('e_dr_D1_D0', 66.0, 100), ('e_dr_D0_OUT', 88.0, 100),
        // Vent: 88 DFU (84 < 88 <= 256 ⇒ DN100).
        ('e_vt_D3_VTR', 88.0, 100), //
      ]) {
        expect(fu[id], dfu, reason: id);
        expect(sz[id]!.diameter.inMillimeters, dn, reason: id);
      }
      // 16.0 roof − 11.7 (the D3 under-slab datum) = 4.3 m.
      expect(lengthOf(net.edgeById('e_vt_D3_VTR')!), closeTo(4.3, 1e-9));
    });
    test('rainwater 0.9 x 200 x 150 / 3.6e6 = 7.5 L/s per drain', () {
      // Half-full Manning n 0.010 @ 1 %: DN125 6.09 < 7.5, DN150 9.90 ⇒
      // DN150; downpipes 15 L/s DN150; RW0→RWOUT DN150 9.90 < 15, DN200
      // 21.3 ⇒ DN200.
      for (final id in ['e_rw_RDa_RW3', 'e_rw_RDb_RW3']) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(7.5, 1e-9));
        expect(sz[id]!.diameter.inMillimeters, 150);
      }
      for (final id in ['e_rw_RW3_RW2', 'e_rw_RW2_RW1', 'e_rw_RW1_RW0']) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(15.0, 1e-9));
        expect(sz[id]!.diameter.inMillimeters, 150);
      }
      expect(sz['e_rw_RW0_RWOUT']!.diameter.inMillimeters, 200);
    });
  });

  group('hand values — fire', () {
    test('sprinkler design + remote head (light hazard)', () {
      // ceil(84 / 20) = 5 heads; share 2.25 x 84 / 5 = 37.8 L/min →
      // (37.8 / 80)² = 0.223 bar < 0.5 ⇒ head at 80 √0.5 = 56.569 L/min.
      expect(sprinkler.sprinklerCount, 5);
      expect(sprinkler.flowPerSprinkler.inLitersPerSecond,
          closeTo(37.8 / 60, 1e-9));
      expect(remote.governedByMinimumPressure, isTrue);
      expect(remote.remoteHeadFlow.inLitersPerSecond, closeTo(0.94281, 5e-6));
      expect(
          remote.remoteAreaDemand.inLitersPerSecond, closeTo(4.71405, 5e-5));
    });
    test('fire pipes and the hydrant index friction (C120)', () {
      final sz = size();
      // Standpipe 500 gpm = 31.545 L/s; NFPA 20 discharge DN125 on the pump
      // legs, the Class I riser DN100 (v 4.016), boxes 5 L/s on DN65.
      for (final id in ['e_fh_FT_FP', 'e_fh_FP_H0', 'e_sp_FP_S0']) {
        expect(sz[id]!.diameter.inMillimeters, 125, reason: id);
      }
      for (final id in ['e_fh_FT_FP', 'e_fh_FP_H0']) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(31.5451, 5e-4));
      }
      // Backlog A-5 — the BRANCH run FP→S0 keeps its DN125 discharge size
      // but carries the sprinkler system's own 5-head 4.71405 L/s.
      expect(sz['e_sp_FP_S0']!.flow.inLitersPerSecond, closeTo(4.71405, 5e-5));
      for (var f = 1; f < 4; f++) {
        final id = 'e_fh_H${f - 1}_H$f';
        expect(sz[id]!.diameter.inMillimeters, 100, reason: id);
        expect(sz[id]!.velocity.metersPerSecond, closeTo(4.016, 5e-4));
      }
      for (var f = 0; f < 4; f++) {
        final id = 'e_fh_H${f}_HYD$f';
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(5.0, 1e-9));
        expect(sz[id]!.diameter.inMillimeters, 65, reason: id);
      }
      // After O1: the sprinkler riser and the line keep their own sizes
      // (heads accumulate 0.94281 each, capped at the 5-head demand).
      const sp = <String, (double, int)>{
        'e_sp_S0_S1': (4.71405, 32), 'e_sp_S1_S2': (4.71405, 32),
        'e_sp_S2_S3': (4.71405, 32), 'e_sp_S3_SP1': (4.71405, 32),
        'e_sp_SP1_SP2': (4.71405, 32), 'e_sp_SP2_SP3': (3.77124, 32),
        'e_sp_SP3_SP4': (2.82843, 25), 'e_sp_SP4_SP5': (1.88562, 25),
        'e_sp_SP5_SP6': (0.94281, 25),
      };
      for (final MapEntry(key: id, value: (q, dn)) in sp.entries) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(q, 5e-5), reason: id);
        expect(sz[id]!.diameter.inMillimeters, dn, reason: id);
      }
      // Index friction FP → HYD3 at C = 120: FP→H0 6.7 m DN125 @ 31.545 +
      // three 4.0 m DN100 risers @ 31.545 + H3→HYD3 4.6 m DN65 @ 5.0.
      double hf(String id) => headLossHazenWilliams(
            flow: sz[id]!.flow,
            length: Length(lengthOf(net.edgeById(id)!)),
            diameter: sz[id]!.diameter,
            hazenWilliamsC: 120,
          ).meters;
      final byHand = hf('e_fh_FP_H0') +
          hf('e_fh_H0_H1') +
          hf('e_fh_H1_H2') +
          hf('e_fh_H2_H3') +
          hf('e_fh_H3_HYD3');
      final fr = fireIndexPathFrictionM(
        net: net,
        system: fireSystems(net).single,
        pumpId: 'FP',
        sizing: sz,
        lengthOf: lengthOf,
        terminals: FireTerminalKind.hydrant,
      )!;
      expect(fr, closeTo(byHand, 1e-9));
      expect(fr, closeTo(2.872, 5e-4));
      // Below the 15 m allowance ⇒ H = 13.2 + 15 + 690 / 9.81 = 98.536 m.
      expect(fr, lessThan(15));
      expect(standpipe.pumpHead.meters, closeTo(98.536, 5e-4));
      expect(standpipe.pumpHydraulicPower.watts, closeTo(30492.8, 0.05));
      expect(standpipe.pumpShaftPower.watts, closeTo(43561.2, 0.05));
    });
  });

  group('hand values — room air', () {
    test('150 x 3.7 x 6 / 3600 = 0.925 m³/s; trunk DN500', () {
      final r = officeRoomAir();
      expect(r.airflow.cubicMetersPerSecond, closeTo(0.925, 1e-12));
      // √(4 x 0.925 / (5π)) = 485 mm → 500, v = 4.711.
      expect(r.supplyDuctDiameter.inMillimeters, 500);
      expect(r.supplyDuctVelocity.metersPerSecond, closeTo(4.711, 5e-4));
      // Backlog F-1 — the FCU estimate reads the PU (0.03 mm) trunk friction
      // the drawn supply duct reads: Swamee–Jain at Re 157 033, ε/D 6e-5,
      // f = 0.016754 ⇒ 0.016754 / 0.5 x 1.2 x 4.711² / 2 = 0.44620 Pa/m;
      // 50 + 0.44620 x 15 x 1.3 + 30 + 20 = 108.70 Pa (galvanised 0.46829
      // Pa/m read 109.13 Pa).
      expect(r.supplyDuctRound!.frictionPerMetrePa, closeTo(0.44620, 5e-6));
      expect(r.equipment.totalStaticPressure.pascals, closeTo(108.70, 5e-3));
    });
  });

  group('hand values — floor sub-boards (each of 4) and their feeders', () {
    test('ways at 231 V, demand, lines, incomer, feeder', () {
      final project = office.electrical;
      final sys = computeSystem(
        const PuilProfile(),
        project,
        calibrationBySheet: office.calibrations,
        building: office.building,
        originFaultLevel: estimatedServiceFaultLevelA(project)!,
        busbarClearingTimeS: 0.1,
        phaseReassignThresholdA: 1.0,
      );
      // 164 000 VA declared ⇒ still the 10 kA (<= 197 kVA) rung.
      expect(estimatedServiceFaultLevelA(project)!.amperes, 10000);
      // Lighting 1200 / (231 x 0.9) = 5.772; socket run 2000 / (231 x 0.9)
      // = 9.620; AC run 3500 / (231 x 0.85) = 17.825.
      const ways = <String,
          ({double run, int mcb, String curve, double csa, double vd})>{
        'lampu_a': (run: 5.8, mcb: 6, curve: 'b', csa: 1.5, vd: 1.31),
        'lampu_b': (run: 5.8, mcb: 6, curve: 'b', csa: 1.5, vd: 1.63),
        'kk_a': (run: 9.6, mcb: 10, curve: 'c', csa: 2.5, vd: 1.00),
        'kk_b': (run: 9.6, mcb: 10, curve: 'c', csa: 2.5, vd: 1.34),
        'kk_c': (run: 9.6, mcb: 10, curve: 'c', csa: 2.5, vd: 1.67),
        'ac_1': (run: 17.8, mcb: 20, curve: 'c', csa: 4.0, vd: 1.10),
        'ac_2': (run: 17.8, mcb: 20, curve: 'c', csa: 4.0, vd: 1.32),
        'ac_3': (run: 17.8, mcb: 20, curve: 'c', csa: 4.0, vd: 1.53),
      };
      // Backlog B-1 (2026-11-13): the feeders (10 / 14 / 18 / 22 m) grow
      // from 6 mm² to 16 mm² for their selectivity floor (below). Board pf
      // 16 050 / 18 451 = 0.86986 (sin 0.49327): √3 × 28.5 × (1.38 ×
      // 0.86986 + 0.08 × 0.49327) / 1000 / 400 × 100 = 0.015301 %/m ⇒
      // 0.15 / 0.21 / 0.28 / 0.34 % (was 0.40 / 0.56 / 0.72 / 0.88 on 6 mm²).
      const feederVd = [0.15, 0.21, 0.28, 0.34];
      final lvmdp = sys.panels[kOfficeMainPanelId]!;
      for (var i = 0; i < 4; i++) {
        final t = kOfficeFloorTags[i];
        final p = sys.panels[officePanelId(t)]!;
        for (final MapEntry(key: base, value: x) in ways.entries) {
          final r =
              p.circuits.firstWhere((c) => c.circuitId == 'c_${base}_$t');
          expect(r.runCurrentA.amperes, closeTo(x.run, 1e-9), reason: base);
          expect(r.breaker.ratingA.amperes, x.mcb, reason: base);
          expect(r.breaker.curve.name, x.curve, reason: base);
          expect(r.cable.csaMm2, x.csa, reason: base);
          expect(r.voltageDrop.dropPercent, closeTo(x.vd, 1e-9),
              reason: base);
          // Cumulative = the feeder's own drop + the way's own.
          expect(r.cumulativeDropPercent, closeTo(feederVd[i] + x.vd, 1e-9),
              reason: base);
          expect(r.rcd.required, base.startsWith('kk'), reason: base);
        }
        // 2400 + 0.7 x 6000 + 0.9 x 10 500 = 16 050 W; VA 2400 / 0.9 +
        // 4200 / 0.9 + 9450 / 0.85 = 18 451.
        expect(p.demandW, closeTo(16050, 1e-6));
        expect(p.demandVa, closeTo(18451, 0.5));
        // Lines sorted: 16.04 + 6.73 + 5.77 = 28.5 twice, 16.04 + 6.73 =
        // 22.8.
        final lines = [p.phaseBalance.l1, p.phaseBalance.l2, p.phaseBalance.l3]
          ..sort();
        expect(lines, [22.8, 28.5, 28.5]);
        expect(p.incomer.breaker.ratingA.amperes, 32);
        expect(p.incomer.poles, 4);
        // Feeder: Ib = the worst line 28.5 A; load-sized MCB 32 A on 6 mm²
        // (Iz 36). Backlog B-1: the 1.6 x 32 = 51.2 A floor ⇒ rung 63 A; the
        // auto-sized cable grows to Iz ≥ 63: 10 mm² 50 ✗, 16 mm² 68 ✓ ⇒
        // MCB 63 A C, NYY 5 x 16.
        final fd = lvmdp.circuits
            .firstWhere((c) => c.circuitId == officeFeederId(t));
        expect(fd.designCurrent.amperes, 28.5);
        expect(fd.breaker.ratingA.amperes, 63);
        expect(fd.breaker.curve.name, 'c');
        expect(fd.cable.csaMm2, 16);
        expect(fd.cable.deratedIz.amperes, 68);
        expect(fd.cableRaisedForSelectivity, isTrue);
        expect(fd.grounding.cores, 5);
        expect(fd.voltageDrop.dropPercent, closeTo(feederVd[i], 1e-9));
      }
    });
  });
}
