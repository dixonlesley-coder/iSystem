// Reference building 4 (apartment) — ENGINE-level solve smoke test.
//
// Builds the fixed 12-storey apartment block (`test/reference/apartment.dart`)
// and runs it through the real engine: `autoSizeNetwork` with the argument
// set the app's `sizingDetailProvider` passes (building + calibrations,
// private-occupancy UBAP, the light-hazard sprinkler head flow + the
// remote-area cap, the standpipe design flow, the hand-picked jockey-leg
// sizes, and — mirrored from the app's second sizing pass — the jockey's 1 %
// duty flow), one gravity DOWNFEED solve from the roof tank (with and
// without the PRV station), the fire design primitives, and the electrical
// `computeSystem` + `computeAdvancedStudy` over LVMDP, PP-E and the twelve
// floor boards (without the app's MEP board). It asserts only that nothing
// throws and every flowing edge comes back sized; the hand-derived expected
// values are a later task. Set REF_DUMP=1 to print the solved figures.
//
// What the engine level does NOT do (app-only, see the app test): the
// transfer pump / booster duties, the delivered field with the booster
// running, the zone table, the fire system basis (rated point, NFPA 20
// motor, jockey / standby roles), the room cooling load and the MEP sync.
import 'dart:io';

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart'
    show defaultLvUtilityFaultKa, estimatedServiceFaultLevelA;
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart' show defaultPrvSetpoint;
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show drainageFixtureUnit;
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart'
    show kJockeyFlowFraction;
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/apartment.dart';

// The app-side defaults `sizingDetailProvider` feeds the sizer (mirrored, as
// in the house / shophouse / office tests: the engine cannot import the app).
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
  final apt = buildApartment();
  const profile = SniProfile();
  final sprinkler = designSprinklerSystem(hazard: _hazard);
  final remote =
      remoteAreaHydraulics(design: sprinkler, kFactor: kDefaultPendentKFactor);

  double lengthOf(Network net, NetEdge e) => edgeLength(e, net,
          calibrationBySheet: apt.calibrations,
          building: apt.building,
          mounting: apt.mounting)
      .meters;

  Map<String, double> fuOut = {};
  Map<String, EdgeSizing> size(Network net) {
    fuOut = {};
    final standpipe = designStandpipe(
        risers: drawnStandpipeRiserCount(net),
        buildingHeight: standpipeStaticLift(apt.building));
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
            n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: apt.occupancy),
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
      },
      sizeOverrides: {
        for (final e in net.edges)
          if (e.sizeOverride != null) e.id: e.sizeOverride!,
      },
      sprinklerDemandCap: remote.remoteAreaDemand,
      hydrantDesignFlow: standpipe.requiredFlow,
      flushSystem: FlushSystem.flushTank,
      // The app's second sizing pass: the jockey (a drawn smaller leg) at
      // 1 % of its system's standpipe flow.
      jockeyLegFlows: {
        kAptJockeyPump: FlowRate(
            standpipe.requiredFlow.cubicMetersPerSecond * kJockeyFlowFraction),
      },
      building: apt.building,
      calibrationBySheet: apt.calibrations,
      mounting: apt.mounting,
      fixtureUnitsOut: fuOut,
    );
  }

  test(
      'the apartment fixture is the spec: 12 floors, every run its exact '
      'plan length', () {
    final net = apt.network;
    expect(apt.building.levelCount, 12);
    final cal = apt.calibrations.values.first;
    double plan(String id) {
      final e = net.edgeById(id);
      expect(e, isNotNull, reason: id);
      return cal.lengthForPixels(runPixelLength(e!, net)).meters;
    }

    final runM = <String, double>{
      'e_cw_WM_GT': 3.0,
      'e_cw_GT_TP': 1.0,
      'e_cw_TP_U0': 1.0,
      'e_cw_U11_RT': 2.0,
      'e_cw_RT_A': 2.0,
      'e_cw_A_BS': 1.0,
      'e_cw_BS_BR11': 1.0,
      'e_cw_A_GR11': 1.0,
      'e_dr_Da0_J': 4.0,
      'e_dr_Db0_J': 4.0,
      'e_dr_J_OUT': 10.0,
      'e_rw_RDa_RW11': 2.0,
      'e_rw_RDb_RW11': 2.0,
      'e_rw_RW0_RWOUT': 6.0,
      'e_fh_FT_FP': 2.0,
      'e_fh_FP_FH': 2.0,
      'e_fh_FT_FPS': 3.0,
      'e_fh_FPS_FH': 3.0,
      'e_fh_FT_FJ': 3.0,
      'e_fh_FJ_FH': 3.0,
      'e_fh_FH_H0': 3.0,
      'e_sp_FH_S0': 4.0,
      'e_sp_S11_SP1': 3.0,
      for (var i = 2; i <= 6; i++) 'e_sp_SP${i - 1}_SP$i': 3.0,
      for (var f = 0; f < kAptFloors; f++) ...{
        'e_cw_${aptRiserNode(f)}_M$f': 2.0,
        for (final u in kAptUnits) ...{
          'e_cw_M${f}_K$u$f': kAptUnitBranchM[u]!,
          for (final b in kAptFixtures) ...{
            'e_cw_K$u${f}_$b$u$f': kAptBranchM[b]!,
            'e_dr_$b$u${f}_D$u$f': 1.5,
          },
        },
        'e_fh_H${f}_HYD$f': 2.0,
      },
    };
    for (final MapEntry(:key, :value) in runM.entries) {
      expect(plan(key), closeTo(value, 1e-9), reason: key);
    }
    for (final r in kApartmentRooms) {
      expect(r.widthM, closeTo(3.0, 1e-12));
      expect(r.depthM, closeTo(4.0, 1e-12));
    }
  });

  for (final withPrv in [false, true]) {
    final label = withPrv ? 'AFTER (PRV drawn)' : 'BEFORE (no PRV)';
    test(
        'mechanical + fire: sizes every flowing edge and solves the gravity '
        'downfeed — $label', () {
      if (withPrv && kAptPrvFloor == null) return;
      final net = withPrv
          ? buildApartmentNetwork(prvFloor: kAptPrvFloor)
          : buildApartmentNetwork();
      final sizing = size(net);
      _p('## ENGINE $label sizing (edge service kind L FU Q DN v from)');
      for (final e in net.edges) {
        final s = sizing[e.id];
        _p('${e.id} ${e.service.name} ${e.kind.name} L=${_f(lengthOf(net, e))} '
            'FU=${fuOut[e.id]} '
            'Q=${s == null ? '-' : _f(s.flow.inLitersPerSecond, 4)} '
            'DN=${s?.diameter.inMillimeters} '
            'v=${s == null ? '-' : _f(s.velocity.metersPerSecond)} '
            'from=${s?.flowFromId}'
            '${(s?.overCapacity ?? false) ? ' overCapacity' : ''}'
            '${(s?.stackRaisedForBranch ?? false) ? ' stackRaisedForBranch' : ''}');
      }
      for (final e in net.edges) {
        expect(sizing[e.id], isNotNull, reason: e.id);
        expect(sizing[e.id]!.diameter.inMillimeters, greaterThan(0),
            reason: e.id);
      }
      final roots =
          serviceComponentRoots(net, ServiceType.coldWater, demandNodeIds: {
        for (final n in net.nodes)
          if (n.role == NodeRole.fixture) n.id,
      });
      _p('sizer roots (cold water): ${{for (final r in roots.values) r}}');

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
        calibrationBySheet: apt.calibrations,
        building: apt.building,
        targetResidual: target,
        mounting: apt.mounting,
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
      for (var f = 0; f < kAptFloors; f++) {
        for (final u in kAptUnits) {
          for (final b in kAptFixtures) {
            expect(sol.deliveryNodeIds, contains('$b$u$f'));
          }
        }
      }

      if (withPrv) return;
      // Fire design primitives (no PRV on the fire side).
      final standpipe = designStandpipe(
          risers: drawnStandpipeRiserCount(net),
          buildingHeight: standpipeStaticLift(apt.building));
      _p('## ENGINE sprinkler design hazard=${sprinkler.hazard.name} '
          'designArea=${_f(sprinkler.designAreaValue.squareMeters)} m2 '
          'requiredFlow=${_f(sprinkler.requiredFlow.inLitersPerSecond, 4)} L/s '
          'count=${sprinkler.sprinklerCount} '
          'perHead=${_f(sprinkler.flowPerSprinkler.inLitersPerSecond, 4)} L/s');
      _p('## ENGINE remote area K=${remote.kFactor} '
          'remoteHeadFlow=${_f(remote.remoteHeadFlow.inLitersPerSecond, 4)} L/s '
          'remoteHeadP=${_f(remote.remoteHeadPressure.inKiloPascals)} kPa '
          'branchFriction=${_f(remote.branchLineFrictionHead.meters)} m '
          'branchBaseP=${_f(remote.branchBasePressure.inKiloPascals)} kPa '
          'remoteAreaDemand=${_f(remote.remoteAreaDemand.inLitersPerSecond, 4)} L/s '
          'governedByMinP=${remote.governedByMinimumPressure}');
      _p('## ENGINE standpipe (advisory, friction-free) risers='
          '${drawnStandpipeRiserCount(net)} '
          'lift=${_f(standpipeStaticLift(apt.building).meters)} m '
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
            pumpId: kAptDutyFirePump,
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
      'and the twelve floor boards (no MEP board)', () {
    final project = apt.electrical;
    final fault = estimatedServiceFaultLevelA(project) ??
        const Current(defaultLvUtilityFaultKa * 1000);
    final sys = computeSystem(
      const PuilProfile(),
      project,
      calibrationBySheet: apt.calibrations,
      building: apt.building,
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
    expect(sys.panels[kAptMainPanelId]!.circuits.length, 13);
    expect(sys.panels[kAptEssentialPanelId]!.circuits.length, 2);
    for (var f = 0; f < kAptFloors; f++) {
      expect(sys.panels[aptFloorPanelId(f)]!.circuits.length, 7);
    }
    _p('supply demandVa=${sys.supply.demandVa.voltAmperes} '
        'system=${sys.supply.system.name} '
        'level=${adv.supply.lvOrMv.name} demandKva=${adv.supply.demandKva} '
        'tx=${adv.supply.transformerKva} '
        'daya=${adv.recommendedDayaVa} threePhase=${adv.recommendedDayaThreePhase}');
    _p('supply note: ${adv.supply.note}');
    _p('genset: backedPanels=${(gensetBackedPanelIds(project).toList()..sort())} '
        'backupFraction=${effectiveGeneratorBackupFraction(project)} '
        'essentialVa=${_f(essentialDemandVa(project, sys), 1)} '
        'backupVa=${_f(gensetBackupDemandVa(project, sys).voltAmperes, 1)} '
        'backupW=${_f(gensetBackupDemandW(project, sys).watts, 1)} '
        'startFloor=${_f(gensetStartFloorFor(project, sys).inKilovoltAmperes, 2)} kVA '
        'plantVa=${gensetPlantVa(project, sys)}');
    _p('warnings: ${sys.warnings.length + adv.fault.warnings.length + adv.warnings.length}');
    for (final w in [...sys.warnings, ...adv.fault.warnings, ...adv.warnings]) {
      _p('- [${w.severity.name}] ${w.code} (${w.panelId}/${w.circuitId}): '
          '${w.message}');
    }
  });
}
