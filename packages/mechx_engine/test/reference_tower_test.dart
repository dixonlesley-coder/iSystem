// Reference building 5 (tower) — ENGINE-level solve smoke test.
//
// Builds the fixed 30-storey office tower (`test/reference/tower.dart`) and
// runs it through the real engine: `autoSizeNetwork` with the argument set
// the app's `sizingDetailProvider` passes (building + calibrations, public
// occupancy UBAP, flush-valve curve, the light-hazard sprinkler head flow +
// the remote-area cap, the two-riser standpipe design flow, the hand-picked
// jockey-leg sizes and — mirrored from the app's second sizing pass — the
// jockey's 1 % duty flow, the project's RECTANGULAR / EQUAL-FRICTION duct
// settings), one gravity DOWNFEED solve from the roof tank (BEFORE / AFTER the
// PRV stations), the hot-water field through the heater, the fan statics of
// the three air systems, the fire design primitives, and the electrical
// `computeSystem` + `computeAdvancedStudy` over LVMDP, PP-E and the thirty
// floor boards (without the app's MEP board). It asserts only that nothing
// throws and every flowing edge comes back sized; the hand-derived expected
// values are a later task. Set REF_DUMP=1 to print the solved figures.
import 'dart:io';

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart'
    show defaultLvUtilityFaultKa, estimatedServiceFaultLevelA;
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/hot_water_pressure.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart' show defaultPrvSetpoint;
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show drainageFixtureUnit;
import 'package:mechx_engine/sizing/duct_sizing.dart'
    show ductFrictionPaPerMetre;
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart'
    show kJockeyFlowFraction;
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/tower.dart';

// The app-side defaults `sizingDetailProvider` feeds the sizer (mirrored, as
// in the other reference tests: the engine cannot import the app).
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
const SizingContext _ctx =
    SizingContext(ductShape: kTowerDuctShape, ductMethod: kTowerDuctMethod);

final bool _dump = Platform.environment['REF_DUMP'] == '1';
void _p(String s) {
  if (_dump) print(s); // ignore: avoid_print
}

String _f(double v, [int dp = 3]) => v.toStringAsFixed(dp);

void main() {
  final tower = buildTower();
  const profile = SniProfile();
  final sprinkler = designSprinklerSystem(hazard: _hazard);
  final remote =
      remoteAreaHydraulics(design: sprinkler, kFactor: kDefaultPendentKFactor);

  double lengthOf(Network net, NetEdge e) => edgeLength(e, net,
          calibrationBySheet: tower.calibrations,
          building: tower.building,
          mounting: tower.mounting)
      .meters;

  Map<String, double> fuOut = {};
  Map<String, EdgeSizing> size(Network net) {
    fuOut = {};
    final standpipe = designStandpipe(
        risers: drawnStandpipeRiserCount(net),
        buildingHeight: standpipeStaticLift(tower.building));
    return autoSizeNetwork(
      net,
      _ctx,
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
            n.id:
                profile.fixtureUnitLoad(n.fixture!, occupancy: tower.occupancy),
      },
      nodeDrainageUnits: {
        for (final n in net.nodes)
          if (n.fixture != null) n.id: drainageFixtureUnit(n.fixture!),
      },
      nodeFlowDemand: {
        for (final n in net.nodes)
          if (n.roofAreaM2 != null && n.airflow == null)
            n.id: rainwaterDesignFlow(
                intensityMmPerHr: _rainfallMmPerHr,
                roofAreaM2: n.roofAreaM2!,
                runoffCoefficient: kDefaultRunoffCoefficient),
        for (final n in net.nodes)
          if (n.airflow != null) n.id: n.airflow!,
      },
      sizeOverrides: {
        for (final e in net.edges)
          if (e.sizeOverride != null) e.id: e.sizeOverride!,
      },
      sprinklerDemandCap: remote.remoteAreaDemand,
      hydrantDesignFlow: standpipe.requiredFlow,
      flushSystem: FlushSystem.flushValve,
      flushValveNodeIds: {
        for (final n in net.nodes)
          if (n.fixture == PlumbingFixture.waterClosetFlushValve) n.id,
      },
      jockeyLegFlows: {
        kTowerJockeyPump: FlowRate(
            standpipe.requiredFlow.cubicMetersPerSecond * kJockeyFlowFraction),
      },
      building: tower.building,
      calibrationBySheet: tower.calibrations,
      mounting: tower.mounting,
      fixtureUnitsOut: fuOut,
    );
  }

  test(
      'the tower fixture is the spec: 30 floors, every run its exact plan '
      'length', () {
    final net = tower.network;
    expect(tower.building.levelCount, 30);
    final cal = tower.calibrations.values.first;
    double plan(String id) {
      final e = net.edgeById(id);
      expect(e, isNotNull, reason: id);
      return cal.lengthForPixels(runPixelLength(e!, net)).meters;
    }

    final runM = <String, double>{
      'e_cw_WM_GT': 3.0,
      'e_cw_GT_TP': 1.0,
      'e_cw_TP_U0': 1.0,
      'e_cw_GT_TPS': 1.5,
      'e_cw_TPS_U0': 1.5,
      'e_cw_U29_RT': 2.0,
      'e_cw_RT_A': 2.0,
      'e_cw_A_BS': 1.0,
      'e_cw_BS_BR29': 1.0,
      'e_cw_A_GR29': 1.0,
      'e_cw_BR29_WH': 2.0,
      'e_hw_WH_HW29': 2.0,
      'e_dr_D0_OUT': 10.0,
      for (final id in ['RDa', 'RDb', 'RDc', 'RDd']) 'e_rw_${id}_RW29': 2.0,
      'e_rw_RW0_RWOUT': 6.0,
      'e_fh_FT_FP': 2.0,
      'e_fh_FP_FH': 2.0,
      'e_fh_FT_FPS': 3.0,
      'e_fh_FPS_FH': 3.0,
      'e_fh_FT_FJ': 3.0,
      'e_fh_FJ_FH': 3.0,
      'e_fh_FH_Ha0': 3.0,
      'e_fh_FH_Hb0': 6.0,
      'e_sp_FH_S0': 4.0,
      'e_sp_S29_SP1': 3.0,
      for (var i = 2; i <= 6; i++) 'e_sp_SP${i - 1}_SP$i': 3.0,
      'e_sa_AHU1_SD1': 3.0,
      for (var i = 2; i <= 8; i++) 'e_sa_SD${i - 1}_SD$i': 3.0,
      'e_ra_RG1_AHU1': 3.0,
      for (var i = 2; i <= kTowerReturnGrilles.length; i++)
        'e_ra_RG${i}_RG${i - 1}': 3.0,
      'e_ea_EF1_EG1': 3.0,
      'e_ea_EG1_EG2': 3.0,
      for (var f = 0; f < kTowerFloors; f++) ...{
        'e_cw_${towerRiserNode(f)}_T$f': 3.0,
        for (final b in kTowerFixtures) ...{
          'e_cw_T${f}_$b$f': kTowerBranchM[b]!,
          'e_dr_$b${f}_D$f': 1.5,
        },
        for (final r in kTowerHydrantRisers) 'e_fh_H$r${f}_HYD$r$f': 2.0,
      },
      for (final f in kTowerBoostedFloors)
        for (final b in kTowerHotBranchM.keys)
          'e_hw_HW${f}_$b$f': kTowerHotBranchM[b]!,
    };
    for (final MapEntry(:key, :value) in runM.entries) {
      expect(plan(key), closeTo(value, 1e-9), reason: key);
    }
    expect(kTowerRooms[0].widthM, closeTo(20.0, 1e-12));
    expect(kTowerRooms[0].depthM, closeTo(30.0, 1e-12));
    expect(kTowerRooms[1].widthM, closeTo(4.0, 1e-12));
    expect(kTowerRooms[1].depthM, closeTo(6.0, 1e-12));
    _p('## ENGINE HVAC fixture: office airflow='
        '${_f(kTowerOfficeAirflow.inLitersPerSecond)} L/s toilet exhaust='
        '${_f(kTowerToiletAirflow.inLitersPerSecond)} L/s; diffuser '
        '${_f(kTowerDiffuserFlow.inLitersPerSecond)} L/s face '
        '$kTowerDiffuserFaceMm; return x${kTowerReturnGrilles.length} '
        '${_f(kTowerReturnFlow.inLitersPerSecond)} L/s face $kTowerReturnFaceMm; '
        'exhaust x2 ${_f(kTowerExhaustFlow.inLitersPerSecond)} L/s face '
        '$kTowerExhaustFaceMm');
  });

  for (final withPrv in [false, true]) {
    final label = withPrv ? 'AFTER (PRVs drawn)' : 'BEFORE (no PRV)';
    test(
        'mechanical + fire + air: sizes every flowing edge and solves the '
        'gravity downfeed — $label', () {
      if (withPrv && kTowerPrvFloors.isEmpty) return;
      final net = buildTowerNetwork(prvFloors: withPrv ? kTowerPrvFloors : []);
      final sizing = size(net);
      _p('## ENGINE $label sizing (edge service kind L FU Q DN WxH v from)');
      for (final e in net.edges) {
        final s = sizing[e.id];
        _p('${e.id} ${e.service.name} ${e.kind.name} L=${_f(lengthOf(net, e))} '
            'FU=${fuOut[e.id]} '
            'Q=${s == null ? '-' : _f(s.flow.inLitersPerSecond, 4)} '
            'DN=${s?.diameter.inMillimeters} '
            '${s?.width == null ? '' : 'WxH=${s!.width!.inMillimeters}x${s.height!.inMillimeters} '}'
            'v=${s == null ? '-' : _f(s.velocity.metersPerSecond)} '
            'from=${s?.flowFromId}'
            '${(s?.overCapacity ?? false) ? ' overCapacity' : ''}'
            '${(s?.demandCurveExtrapolated ?? false) ? ' demandCurveExtrapolated' : ''}'
            '${(s?.stackRaisedForBranch ?? false) ? ' stackRaisedForBranch' : ''}');
      }
      for (final e in net.edges) {
        expect(sizing[e.id], isNotNull, reason: e.id);
        expect(sizing[e.id]!.diameter.inMillimeters, greaterThan(0),
            reason: e.id);
      }

      // Gravity downfeed from the roof tank.
      final target =
          SupplyDesignCriteria.recommended().targetFixtureResidualPressure;
      final setpoint = defaultPrvSetpoint(
        targetResidual: target,
        maxFixtureStatic: profile.maxFixtureStaticPressure.value,
      );
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
        calibrationBySheet: tower.calibrations,
        building: tower.building,
        targetResidual: target,
        mounting: tower.mounting,
        prvSetpoint: setpoint,
      );
      _p('## ENGINE $label downfeed from RT critical=${sol.criticalNodeId} '
          'min=${_f(sol.minResidual.inKiloPascals)} kPa '
          'booster=${_f(sol.boosterHeadRequired.meters)} m '
          'gravitySufficient=${sol.gravitySufficient} '
          'prvSetpoint=${_f(setpoint.inKiloPascals)} kPa');
      final ids = sol.residualPressure.keys.toList()..sort();
      for (final id in ids) {
        _p('$id delivery=${sol.deliveryNodeIds.contains(id)} '
            'residual=${_f(sol.residualPressure[id]!.inKiloPascals)} '
            'static=${_f(sol.noFlowStaticPressure[id]?.inKiloPascals ?? double.nan)} kPa');
      }
      for (var f = 0; f < kTowerFloors; f++) {
        for (final b in kTowerFixtures) {
          expect(sol.deliveryNodeIds, contains('$b$f'));
        }
      }

      // Hot water through the heater from the gravity cold field.
      final hot = solveHotWaterFromHeaters(
        net: net,
        coldResidual: sol.residualPressure,
        coldNoFlow: sol.noFlowStaticPressure,
        sizing: sizing,
        calibrationBySheet: tower.calibrations,
        building: tower.building,
        targetResidual: target,
        mounting: tower.mounting,
        prvSetpoint: setpoint,
      );
      _p('## ENGINE $label hot water heaters=${hot.heaterIds} '
          'critical=${hot.criticalNodeId} '
          'shortfall=${_f(hot.shortfall.meters)} m');
      for (final id in (hot.residual.keys.toList()..sort())) {
        _p('hot $id residual=${_f(hot.residual[id]!.inKiloPascals)} '
            'static=${_f(hot.noFlowStatic[id]?.inKiloPascals ?? double.nan)} kPa');
      }

      if (withPrv) return;
      // Air systems: per-duct friction and the fan statics.
      _p('## ENGINE air (edge | Q L/s | WxH | De mm | v | Pa/m at product)');
      for (final e in net.edges) {
        if (e.service.regime != FlowRegime.air) continue;
        final s = sizing[e.id]!;
        _p('${e.id} Q=${_f(s.flow.inLitersPerSecond)} '
            'WxH=${s.width?.inMillimeters}x${s.height?.inMillimeters} '
            'De=${s.diameter.inMillimeters} v=${_f(s.velocity.metersPerSecond)} '
            'Pa/m=${_f(ductFrictionPaPerMetre(s.flow, s.diameter, roughness: ductRoughnessFor(effectiveDuctProductFor(e))), 4)} '
            '(${effectiveDuctProductFor(e).name})');
      }
      for (final (svc, fan) in [
        (ServiceType.duct, kTowerAhuId),
        (ServiceType.returnAir, kTowerAhuId),
        (ServiceType.exhaust, kTowerExhaustFanId),
      ]) {
        final st = solveDuctStatic(
          net: net,
          service: svc,
          fanNodeId: fan,
          edgeFlows: {
            for (final e in net.edges)
              if (e.service == svc) e.id: sizing[e.id]!.flow,
          },
          sizing: sizing,
          calibrationBySheet: tower.calibrations,
          building: tower.building,
          mounting: tower.mounting,
        );
        _p('ductStatic ${svc.name} from $fan: '
            '${_f(st.totalStaticPressure.pascals, 2)} Pa '
            'critical=${st.criticalNodeId} (default 30 Pa terminal, x1.3)');
      }

      // Fire design primitives (no PRV on the fire side).
      final standpipe = designStandpipe(
          risers: drawnStandpipeRiserCount(net),
          buildingHeight: standpipeStaticLift(tower.building));
      _p('## ENGINE sprinkler design hazard=${sprinkler.hazard.name} '
          'designArea=${_f(sprinkler.designAreaValue.squareMeters)} m2 '
          'requiredFlow=${_f(sprinkler.requiredFlow.inLitersPerSecond, 4)} L/s '
          'count=${sprinkler.sprinklerCount} '
          'perHead=${_f(sprinkler.flowPerSprinkler.inLitersPerSecond, 4)} L/s');
      _p('## ENGINE remote area K=${remote.kFactor} '
          'remoteHeadFlow=${_f(remote.remoteHeadFlow.inLitersPerSecond, 4)} L/s '
          'remoteHeadP=${_f(remote.remoteHeadPressure.inKiloPascals)} kPa '
          'remoteAreaDemand=${_f(remote.remoteAreaDemand.inLitersPerSecond, 4)} L/s');
      _p('## ENGINE standpipe (advisory, friction-free) risers='
          '${drawnStandpipeRiserCount(net)} '
          'lift=${_f(standpipeStaticLift(tower.building).meters)} m '
          'class=${standpipe.standpipeClass.name} '
          'flow=${_f(standpipe.requiredFlow.inLitersPerSecond, 4)} L/s '
          'topResidual=${_f(standpipe.topResidualPressure.inKiloPascals)} kPa '
          'minRiser=${standpipe.minRiserDiameter.inMillimeters} '
          'pumpHead=${_f(standpipe.pumpHead.meters)} m '
          'shaft=${_f(standpipe.pumpShaftPower.watts, 1)} W');
      final sys = fireSystems(net);
      _p('## ENGINE fire systems: ${sys.length}');
      for (final s in sys) {
        for (final kind in FireTerminalKind.values) {
          final per = <String, double>{};
          final fr = fireIndexPathFrictionM(
            net: net,
            system: s,
            pumpId: kTowerDutyFirePump,
            sizing: sizing,
            lengthOf: (e) => lengthOf(net, e),
            terminals: kind,
            frictionByTerminalOut: per,
          );
          _p('index friction from FP to ${kind.name}: '
              '${fr == null ? null : _f(fr)} m '
              'perTerminal=${{
            for (final e
                in (per.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key))))
              e.key: _f(e.value)
          }}');
        }
      }
      expect(sys, isNotEmpty);
    });
  }

  test(
      'electrical: computeSystem + computeAdvancedStudy over LVMDP, PP-E '
      'and the thirty floor boards (no MEP board)', () {
    final project = tower.electrical;
    final fault = estimatedServiceFaultLevelA(project) ??
        const Current(defaultLvUtilityFaultKa * 1000);
    final sys = computeSystem(
      const PuilProfile(),
      project,
      calibrationBySheet: tower.calibrations,
      building: tower.building,
      originFaultLevel: fault,
      busbarClearingTimeS: 0.1,
      phaseReassignThresholdA: 1.0,
    );
    final adv = computeAdvancedStudy(const PuilProfile(), project, sys);
    _p('## ENGINE electrical origin fault=${_f(fault.amperes, 1)} A');
    for (final pid in sys.order) {
      final panel = sys.panels[pid]!;
      final pf = adv.fault.panels[pid];
      final full = pid == kTowerMainPanelId ||
          pid == kTowerEssentialPanelId ||
          pid == towerFloorPanelId(0) ||
          pid == towerFloorPanelId(kTowerFloors - 1);
      _p('### ${panel.name} system=${panel.system.name} '
          'busFault=${pf?.prospectiveFaultkA} kA');
      for (final c in panel.circuits) {
        if (!full && c.loadKind.name != 'feeder') continue;
        final cf = adv.fault.circuits[c.circuitId];
        _p('${c.circuitId} kind=${c.loadKind.name} 3ph=${c.threePhase} '
            'phase=${c.phase.name} Ib=${c.designCurrent.amperes} '
            'breaker=${c.breaker.deviceClass.code} ${c.breaker.ratingA.amperes} '
            '${c.breaker.curve.name} cable=${c.cable.csaMm2} '
            'Iz=${c.cable.deratedIz.amperes} (${c.cable.appliedRule}) '
            'vd=${_f(c.voltageDrop.dropPercent)}% cum=${_f(c.cumulativeDropPercent)}% '
            'L=${c.lengthM} kA=${cf?.breakerKa} fault=${cf?.faultkA}');
      }
      _p('panel ${panel.name} demandW=${panel.demandW} VA=${panel.demandVa} '
          'I=${panel.demandCurrent.amperes} '
          'incomer=${panel.incomer.breaker.deviceClass.code} '
          '${panel.incomer.breaker.ratingA.amperes} '
          'phaseBalance=${panel.phaseBalance.l1}/${panel.phaseBalance.l2}/'
          '${panel.phaseBalance.l3}');
      for (final c in panel.circuits) {
        expect(c.breaker.ratingA.amperes, greaterThan(0), reason: c.circuitId);
        expect(c.cable.csaMm2, greaterThan(0), reason: c.circuitId);
      }
      expect(adv.fault.panels[pid], isNotNull);
    }
    expect(sys.panels[kTowerMainPanelId]!.circuits.length, 31);
    expect(sys.panels[kTowerEssentialPanelId]!.circuits.length, 4);
    for (var f = 0; f < kTowerFloors; f++) {
      expect(sys.panels[towerFloorPanelId(f)]!.circuits.length, 8);
    }
    final s = adv.supply;
    _p('supply demandVa=${sys.supply.demandVa.voltAmperes} '
        'system=${sys.supply.system.name} level=${s.lvOrMv.name} '
        'demandKva=${s.demandKva} tx=${s.transformerKva} x${s.units} '
        'Z=${s.impedancePct}% primaryFlc=${s.primaryFlc?.amperes} '
        'secondaryFlc=${s.secondaryFlc?.amperes} declared=${s.declared} '
        'daya=${adv.recommendedDayaVa} threePhase=${adv.recommendedDayaThreePhase}');
    _p('supply note: ${s.note}');
    final pf = adv.powerFactor;
    _p('powerFactor: kW=${pf.totalKw} kvar=${pf.totalKvar} '
        'existing=${pf.existingPf} uncorrected=${pf.uncorrectedPf} '
        'target=${pf.targetPf} needed=${pf.needed} required=${pf.requiredKvar} '
        'bank=${pf.bankKvar} x${pf.banks}');
    _p('genset: backedPanels=${(gensetBackedPanelIds(project).toList()..sort())} '
        'backupVa=${_f(gensetBackupDemandVa(project, sys).voltAmperes, 1)} '
        'startFloor=${_f(gensetStartFloorFor(project, sys).inKilovoltAmperes, 2)} kVA');
    _p('warnings: ${sys.warnings.length + adv.fault.warnings.length + adv.warnings.length}');
    final counts = <String, int>{};
    for (final w in [...sys.warnings, ...adv.fault.warnings, ...adv.warnings]) {
      counts.update('[${w.severity.name}] ${w.code}', (n) => n + 1,
          ifAbsent: () => 1);
    }
    for (final e in (counts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key)))) {
      _p('- ${e.key} x${e.value}');
    }
  });
}
