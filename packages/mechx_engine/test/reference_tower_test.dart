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
import 'package:mechx_engine/sizing/sprinkler_feed_main.dart';
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
  Set<String> feedEnlarged = {};
  Map<String, EdgeSizing> size(Network net) {
    fuOut = {};
    final standpipe = designStandpipe(
        risers: drawnStandpipeRiserCount(net),
        buildingHeight: standpipeStaticLift(tower.building));
    final legs = <String>{};
    final sized = autoSizeNetwork(
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
      parallelLegEdgeIdsOut: legs,
    );
    // The app's post-pass (reference tower T2): a combined system's
    // sprinkler feed main is enlarged until the sprinkler point no longer
    // exceeds the standpipe head.
    final feed = enlargeCombinedSprinklerFeedMains(
      net: net,
      sizing: sized,
      remote: remote,
      building: tower.building,
      lengthOf: (e) => lengthOf(net, e),
      parallelLegEdgeIds: legs,
      overridden: {
        for (final e in net.edges)
          if (e.sizeOverride != null) e.id,
      },
    );
    feedEnlarged = feed.enlarged;
    return feed.sizing;
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
            '${(s?.stackRaisedForBranch ?? false) ? ' stackRaisedForBranch' : ''}'
            '${feedEnlarged.contains(e.id) ? ' sprinklerFeedEnlarged' : ''}');
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

  // ── Hand-derived pins (reviewer pass 3, 2026-11-13) ─────────────────────
  // Flush-VALVE branch of SNI 8153 Gambar 1 (`_demandValve`), linear between
  // the charted points (UBAP → L/s).
  double valve(double u) {
    const pts = [
      (0.0, 0.0), (10.0, 0.88333), (25.0, 1.51667), (50.0, 2.58333), //
      (100.0, 4.03333), (200.0, 5.93333), (500.0, 8.96667),
      (1000.0, 13.11667),
    ];
    for (var i = 1; i < pts.length; i++) {
      if (u <= pts[i].$1) {
        final (x0, y0) = pts[i - 1];
        final (x1, y1) = pts[i];
        return y0 + (u - x0) / (x1 - x0) * (y1 - y0);
      }
    }
    throw StateError('off the chart');
  }

  group('hand values — cold water (public, flush-valve curve)', () {
    late Map<String, EdgeSizing> sz;
    late Map<String, double> fu;
    late Network net;
    setUpAll(() {
      net = buildTowerNetwork(prvFloors: kTowerPrvFloors);
      sz = size(net);
      fu = Map.of(fuOut);
    });
    void check(String id, double u, double q, int dn, [double? v]) {
      expect(fu[id], closeTo(u, 1e-9), reason: id);
      expect(sz[id]!.flow.inLitersPerSecond, closeTo(q, 5e-5), reason: id);
      expect(sz[id]!.diameter.inMillimeters, dn, reason: id);
      if (v != null) {
        expect(sz[id]!.velocity.metersPerSecond, closeTo(v, 5e-4), reason: id);
      }
    }

    test('the curve read-offs: 24 UBAP per floor (each lavatory its total)',
        () {
      // WC valve 10 + 10, urinal 2, lavatories 1 + 1 = 24 per floor.
      expect(valve(24), closeTo(1.47445, 5e-5)); // 0.88333 + 14/15 x 0.63334
      expect(valve(48), closeTo(2.49800, 5e-5));
      expect(valve(72), closeTo(3.22133, 5e-5));
      // 240: 5.93333 + 40/300 x 3.03334 = 6.33778.
      expect(valve(240), closeTo(6.33778, 5e-5));
      expect(valve(480), closeTo(8.76445, 5e-5));
      // 624: 8.96667 + 124/500 x 4.15 = 9.99587; 720: + 220/500 x 4.15.
      expect(valve(624), closeTo(9.99587, 5e-5));
      expect(valve(648), closeTo(10.19507, 5e-5));
      expect(valve(720), closeTo(10.79267, 5e-5));
    });

    test('fill line, top main and the boosted branch', () {
      // 30 floors = 720 UBAP ⇒ 10.79267 L/s, DN100 at 1.374 m/s — the top
      // main RT → A (what the roof tank distributes).
      check('e_cw_RT_A', 720, valve(720), 100, 1.374);
      // Backlog W-1 (2026-11-14) — the fill line is sized on the tanks'
      // fill flows (capacity / refill time); the 720 UBAP it serves is
      // unchanged. Meter feed WM → GT: 60 000 L / (4 h x 3600 s) = 4.16667
      // L/s; DN50 v = 4.16667e-3 / 1.96350e-3 = 2.122 > 2.0 → DN65 v =
      // 4.16667e-3 / 3.31831e-3 = 1.256. Transfer GT → TP / TPS → U0..U29 →
      // RT: 30 000 L / (1 h x 3600 s) = 8.33333 L/s; DN65 v 2.511 > 2.0 →
      // DN80 v = 8.33333e-3 / 5.02655e-3 = 1.658 (was 10.79267 L/s DN100,
      // the peak demand; the standby leg TPS mirrors the duty leg).
      check('e_cw_WM_GT', 720, 4.16667, 65, 1.256);
      for (final id in [
        'e_cw_GT_TP', 'e_cw_TP_U0', 'e_cw_GT_TPS', 'e_cw_TPS_U0', //
        'e_cw_U29_RT',
        for (var f = 1; f < kTowerFloors; f++) 'e_cw_U${f - 1}_U$f',
      ]) {
        check(id, 720, 8.33333, 80, 1.658);
      }
      // Boosted: 3 x 24 = 72 on the combined path (the lavatories' cold and
      // hot shares rejoin), then 2 x 23.5 and 23.5 (0.75 cold per lavatory).
      check('e_cw_A_BS', 72, valve(72), 50);
      check('e_cw_BS_BR29', 72, valve(72), 50);
      check('e_cw_BR29_BR28', 47, valve(47), 40);
      check('e_cw_BR28_BR27', 23.5, valve(23.5), 32);
      // Gravity riser head: 27 floors = 648 ⇒ 10.19507 L/s DN100.
      check('e_cw_A_GR29', 648, valve(648), 100);
    });

    test(
        'backlog G-1: the curve per PIPE — branches without a flush valve '
        'downstream read the tank curve', () {
      // Tank curve below 10 UBAP: 0.05 L/s per UBAP. A WC branch (10 UBAP,
      // a flush valve downstream) keeps the valve curve 0.88333 L/s DN25;
      // the urinal (flush tank) 2 → 0.1000 L/s DN15 v 0.566 (was 0.17667);
      // a gravity-floor lavatory 1 → 0.0500 L/s v 0.283 (was 0.08833); a
      // boosted-floor lavatory's cold share 0.75 → 0.0375 L/s (was 0.06625).
      for (var f = 0; f < kTowerFloors; f++) {
        final lav = f >= 27 ? 0.75 : 1.0;
        check('e_cw_T${f}_WCa$f', 10, 0.88333, 25, 1.800);
        check('e_cw_T${f}_WCb$f', 10, 0.88333, 25, 1.800);
        check('e_cw_T${f}_UR$f', 2, 0.1, 15, 0.566);
        check('e_cw_T${f}_LAVa$f', lav, 0.05 * lav, 15);
        check('e_cw_T${f}_LAVb$f', lav, 0.05 * lav, 15);
        // The floor branch still serves both valve WCs: valve(24) (gravity)
        // / valve(23.5) (boosted, 0.25 hot per lavatory left the cold side).
        final floorU = f >= 27 ? 23.5 : 24.0;
        check('e_cw_${towerRiserNode(f)}_T$f', floorU, valve(floorU), 32);
      }
      // The heater's cold make-up serves no flush valve: 6 x 0.75 = 4.5
      // UBAP on the tank curve = 0.2250 L/s, DN15 at 0.225e-3 / (π/4 x
      // 0.015²) = 1.273 m/s (was the valve curve's 0.3975 L/s on DN20) —
      // the same draw its hot side reads (`e_hw_WH_HW29`).
      check('e_cw_BR29_WH', 4.5, 0.225, 15, 1.273);
    });

    test('every gravity riser edge carries the floors below it', () {
      int dnFor(double u) => u <= 24
          ? 32
          : u <= 48
              ? 40
              : u <= 96
                  ? 50
                  : u <= 264
                      ? 65
                      : u <= 624
                          ? 80
                          : 100;
      for (var f = kTowerFloors - 1; f >= 1; f--) {
        final floors = f >= 27 ? 27 : f;
        final u = 24.0 * floors;
        final k = f - 1;
        final ids = kTowerPrvFloors.contains(k)
            ? ['e_cw_GR${f}_PRV$k', 'e_cw_PRV${k}_GR$k']
            : ['e_cw_GR${f}_GR$k'];
        for (final id in ids) {
          check(id, u, valve(u), dnFor(u));
        }
      }
      // 26 floors: DN80 at 1.989 m/s; 27: DN100.
      check('e_cw_GR26_GR25', 624, 9.99587, 80, 1.989);
      check('e_cw_GR27_GR26', 648, 10.19507, 100);
    });
  });

  group('hand values — gravity downfeed, BEFORE / AFTER the PRVs', () {
    DownfeedSolution solve(Network net) {
      final sizing = size(net);
      final target =
          SupplyDesignCriteria.recommended().targetFixtureResidualPressure;
      return solveDownfeed(
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
        prvSetpoint: defaultPrvSetpoint(
          targetResidual: target,
          maxFixtureStatic: profile.maxFixtureStaticPressure.value,
        ),
      );
    }

    double kpa(Map<String, Pressure> m, String id) => m[id]!.inKiloPascals;

    test('WCb29 critical 13.831 kPa, booster 21.526 m; WCb26 134.370 kPa', () {
      final sol = solve(buildTowerNetwork(prvFloors: kTowerPrvFloors));
      // WCb29: static (120.0 − 117.1) x 9.81 = 28.449; friction 0.016819 x
      // 2.3 (DN100 @ 10.7927) + 0.052414 x 9.4 (DN50 @ 3.22133) + 0.105497
      // x 3.0 (DN32 @ 1.4533) + 0.139615 x 4.6 (DN25 @ 0.88333) = 1.4901 m
      // = 14.618 kPa ⇒ 13.831.
      expect(sol.criticalNodeId, 'WCb29');
      expect(kpa(sol.noFlowStaticPressure, 'WCb29'), closeTo(28.449, 2e-3));
      expect(kpa(sol.residualPressure, 'WCb29'), closeTo(13.831, 2e-3));
      // (225 − 13.831) / 9.81 = 21.526 m.
      expect(sol.boosterHeadRequired.meters, closeTo(21.526, 5e-4));
      // WCb26: static (120.0 − 105.1) x 9.81 = 146.169; friction 0.03868 +
      // 0.015135 x 13.0 (DN100 @ 10.1951) + 0.108357 x 3.0 + 0.64223 =
      // 1.2027 m ⇒ 134.370 kPa ≥ the 98.067 flush-valve floor.
      expect(kpa(sol.noFlowStaticPressure, 'WCb26'), closeTo(146.169, 2e-3));
      expect(kpa(sol.residualPressure, 'WCb26'), closeTo(134.370, 2e-3));
    });

    test('BEFORE: floors 0..19 over 392.266; AFTER: held by seven PRVs', () {
      final before = solve(buildTowerNetwork());
      // WCb19: (120.0 − 77.1) x 9.81 = 420.849 > 392.266; WCb0 (120.0 −
      // 1.1) x 9.81 = 1166.409.
      expect(kpa(before.noFlowStaticPressure, 'WCb19'), closeTo(420.849, 2e-3));
      expect(kpa(before.noFlowStaticPressure, 'WCb0'), closeTo(1166.409, 2e-3));
      expect(kpa(before.noFlowStaticPressure, 'WCb20'), lessThan(392.266));
      final after = solve(buildTowerNetwork(prvFloors: kTowerPrvFloors));
      for (final k in kTowerPrvFloors) {
        // Top floor of a PRV zone: 255 + (3.7 − 1.1) x 9.81 = 280.506.
        expect(kpa(after.noFlowStaticPressure, 'WCb$k'), closeTo(280.506, 2e-3),
            reason: 'WCb$k');
        expect(kpa(after.noFlowStaticPressure, 'PRV$k'), closeTo(255.0, 1e-6));
      }
      // Bottom of a 3-floor zone: 255 + 10.6 x 9.81 = 358.986.
      for (final f in [17, 14, 11, 8, 5, 2]) {
        expect(kpa(after.noFlowStaticPressure, 'WCb$f'), closeTo(358.986, 2e-3),
            reason: 'WCb$f');
      }
      // Zone 0-1: 255 + 6.6 x 9.81 = 319.746; WCb20 unreduced 381.609.
      expect(kpa(after.noFlowStaticPressure, 'WCb0'), closeTo(319.746, 2e-3));
      expect(kpa(after.noFlowStaticPressure, 'WCb20'), closeTo(381.609, 2e-3));
      final net = buildTowerNetwork(prvFloors: kTowerPrvFloors);
      expect(
          net.nodes.where((n) => n.component == NodeComponent.prv).length, 7);
    });
  });

  group('hand values — hot water, drainage, vent, rainwater', () {
    late Map<String, EdgeSizing> sz;
    late Map<String, double> fu;
    late Network net;
    setUpAll(() {
      net = buildTowerNetwork(prvFloors: kTowerPrvFloors);
      sz = size(net);
      fu = Map.of(fuOut);
    });

    test('hot water: 0.75 UBAP per lavatory on the flush-TANK branch', () {
      // Tank branch 0 → 10 UBAP: 0.05 L/s per UBAP.
      for (final (id, u, q) in [
        ('e_hw_WH_HW29', 4.5, 0.225),
        ('e_hw_HW29_HW28', 3.0, 0.150),
        ('e_hw_HW28_HW27', 1.5, 0.075),
        for (final f in kTowerBoostedFloors) ...[
          ('e_hw_HW${f}_LAVa$f', 0.75, 0.0375),
          ('e_hw_HW${f}_LAVb$f', 0.75, 0.0375),
        ],
      ]) {
        expect(fu[id], closeTo(u, 1e-9), reason: id);
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(q, 5e-5), reason: id);
        expect(sz[id]!.diameter.inMillimeters, 15, reason: id);
      }
    });

    test('drainage: 22 DFU per floor, graduated stack, DN200 drain', () {
      // WC 8 + 8, urinal 4, lavatories 1 + 1 = 22 DFU per floor.
      for (var f = kTowerFloors - 1; f >= 1; f--) {
        final id = 'e_dr_D${f}_D${f - 1}';
        final dfu = 22.0 * (kTowerFloors - f);
        expect(fu[id], dfu, reason: id);
        // Stack table: <= 42 DN75 (the WC floor), <= 240 DN100, then DN125
        // and DN150 at the base (638).
        final dn = dfu <= 22
            ? 75
            : dfu <= 240
                ? 100
                : dfu <= 528
                    ? 125
                    : 150;
        expect(sz[id]!.diameter.inMillimeters, dn, reason: id);
      }
      expect(fu['e_dr_D1_D0'], 638);
      expect(fu['e_dr_D0_OUT'], 660);
      expect(sz['e_dr_D0_OUT']!.diameter.inMillimeters, 200);
      // Stack vent: 660 DFU ⇒ DN150; 120.0 − 115.7 = 4.3 m.
      const v = 'e_vt_D29_VTR';
      expect(sz[v]!.diameter.inMillimeters, 150);
      expect(lengthOf(net, net.edgeById(v)!), closeTo(4.3, 1e-9));
    });

    test('rainwater: 4 x 0.9 x 200 x 200 / 3.6e6 = 4 x 10 L/s', () {
      for (final id in ['RDa', 'RDb', 'RDc', 'RDd']) {
        final e = 'e_rw_${id}_RW29';
        expect(sz[e]!.flow.inLitersPerSecond, closeTo(10.0, 1e-9));
        expect(sz[e]!.diameter.inMillimeters, 200);
      }
      for (var f = kTowerFloors - 1; f >= 1; f--) {
        final e = 'e_rw_RW${f}_RW${f - 1}';
        expect(sz[e]!.flow.inLitersPerSecond, closeTo(40.0, 1e-9));
        expect(sz[e]!.diameter.inMillimeters, 200);
      }
      // Outlet: DN250 half-full 38.65 < 40 L/s ⇒ DN300.
      expect(sz['e_rw_RW0_RWOUT']!.flow.inLitersPerSecond, closeTo(40.0, 1e-9));
      expect(sz['e_rw_RW0_RWOUT']!.diameter.inMillimeters, 300);
    });
  });
}
