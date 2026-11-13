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
import 'package:mechx_engine/hydraulics.dart' show headLossHazenWilliams;
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

  // ── Hand-derived pins (reviewer pass 2, 2026-11-13) ─────────────────────
  group('hand values — cold water (private, flush-tank curve)', () {
    late Map<String, EdgeSizing> sz;
    late Map<String, double> fu;
    late Network net;
    setUpAll(() {
      net = buildApartmentNetwork(prvFloor: kAptPrvFloor);
      sz = size(net);
      fu = Map.of(fuOut);
    });
    // UBAP (private): WC tank 2.5 + LAV 1 + SH 2 + KS 2 = 7.5 per unit, 15
    // per floor, 180 for the building. Tank curve, linear between points:
    // 7.5 → 0.375; 15 → 0.5 + 5/15 x 0.38333 = 0.62778; 30 → 0.88333 + 5/25
    // x 0.95 = 1.07333; 45 → 1.64333; 60 → 2.07333; 75 → 2.43333; 90 →
    // 1.83333 + 40/50 x 1.2 = 2.79333; 105 → 3.03333 + 0.05 x 1.7 = 3.11833;
    // 120 → 3.37333; 135 → 3.62833; 150 → 3.88333; 180 → 4.39333. DN: the
    // first nominal with v <= 2.0 m/s.
    const fill = (fu: 180.0, q: 4.39333, dn: 65, v: 1.324);
    final trunk = <String, ({double l, double fu, double q, int dn, double v})>{
      // Fill line: the meter (ceiling 3.2) to GT on the slab = 3.0 + 3.2;
      // TP (slab) → U0 (ceiling) 1.0 + 3.2; U11 (41.7) → RT (roof 42.0)
      // 2.0 + 0.3; RT → A (41.7) 2.0 + 0.3.
      'e_cw_WM_GT': (l: 6.2, fu: fill.fu, q: fill.q, dn: fill.dn, v: fill.v),
      'e_cw_GT_TP': (l: 1.0, fu: fill.fu, q: fill.q, dn: fill.dn, v: fill.v),
      'e_cw_TP_U0': (l: 4.2, fu: fill.fu, q: fill.q, dn: fill.dn, v: fill.v),
      for (var f = 1; f <= 11; f++)
        'e_cw_U${f - 1}_U$f': (
          l: 3.5,
          fu: fill.fu,
          q: fill.q,
          dn: fill.dn,
          v: fill.v
        ),
      'e_cw_U11_RT': (l: 2.3, fu: fill.fu, q: fill.q, dn: fill.dn, v: fill.v),
      'e_cw_RT_A': (l: 2.3, fu: fill.fu, q: fill.q, dn: fill.dn, v: fill.v),
      // Boosted branch: A (41.7) → BS (slab 38.5) 1.0 + 3.2; BS → BR11
      // (41.7) 1.0 + 3.2; 30 UBAP DN32, then 15 UBAP DN20.
      'e_cw_A_BS': (l: 4.2, fu: 30, q: 1.07333, dn: 32, v: 1.335),
      'e_cw_BS_BR11': (l: 4.2, fu: 30, q: 1.07333, dn: 32, v: 1.335),
      'e_cw_BR11_BR10': (l: 3.5, fu: 15, q: 0.62778, dn: 20, v: 1.998),
      // Gravity riser: 150 UBAP down to floor 9's tee, 15 less per floor.
      'e_cw_A_GR11': (l: 1.0, fu: 150, q: 3.88333, dn: 50, v: 1.978),
      'e_cw_GR11_GR10': (l: 3.5, fu: 150, q: 3.88333, dn: 50, v: 1.978),
      'e_cw_GR10_GR9': (l: 3.5, fu: 150, q: 3.88333, dn: 50, v: 1.978),
      'e_cw_GR9_GR8': (l: 3.5, fu: 135, q: 3.62833, dn: 50, v: 1.848),
      'e_cw_GR8_GR7': (l: 3.5, fu: 120, q: 3.37333, dn: 50, v: 1.718),
      'e_cw_GR7_GR6': (l: 3.5, fu: 105, q: 3.11833, dn: 50, v: 1.588),
      'e_cw_GR6_GR5': (l: 3.5, fu: 90, q: 2.79333, dn: 50, v: 1.423),
      'e_cw_GR5_GR4': (l: 3.5, fu: 75, q: 2.43333, dn: 40, v: 1.936),
      'e_cw_GR4_GR3': (l: 3.5, fu: 60, q: 2.07333, dn: 40, v: 1.650),
      'e_cw_GR3_GR2': (l: 3.5, fu: 45, q: 1.64333, dn: 40, v: 1.308),
      'e_cw_GR2_GR1': (l: 3.5, fu: 30, q: 1.07333, dn: 32, v: 1.335),
      'e_cw_GR1_PRV0': (l: 3.5, fu: 15, q: 0.62778, dn: 20, v: 1.998),
      'e_cw_PRV0_GR0': (l: 0.0, fu: 15, q: 0.62778, dn: 20, v: 1.998),
    };
    // Per floor: the riser node → M 2.0 m; M → K 3.0 / 6.0 m; K → fixture
    // plan + the 2.1 m drop (ceiling 3.2 above its slab to the 1.1 m
    // fixture).
    const branch =
        <String, ({double l, double fu, double q, int dn, double v})>{
      'WC': (l: 3.1, fu: 2.5, q: 0.125, dn: 15, v: 0.707),
      'LAV': (l: 3.6, fu: 1.0, q: 0.05, dn: 15, v: 0.283),
      'SH': (l: 4.1, fu: 2.0, q: 0.1, dn: 15, v: 0.566),
      'KS': (l: 6.1, fu: 2.0, q: 0.1, dn: 15, v: 0.566),
    };
    void check(
        String id, ({double l, double fu, double q, int dn, double v}) x) {
      expect(lengthOf(net, net.edgeById(id)!), closeTo(x.l, 1e-9), reason: id);
      expect(fu[id], closeTo(x.fu, 1e-9), reason: id);
      expect(sz[id]!.flow.inLitersPerSecond, closeTo(x.q, 5e-5), reason: id);
      expect(sz[id]!.diameter.inMillimeters, x.dn, reason: id);
      expect(sz[id]!.velocity.metersPerSecond, closeTo(x.v, 5e-4), reason: id);
    }

    test('fill line, top main, booster branch and gravity riser', () {
      for (final MapEntry(:key, :value) in trunk.entries) {
        check(key, value);
      }
    });
    test('every floor: riser node → M DN20 at 15 UBAP and the unit branches',
        () {
      for (var f = 0; f < kAptFloors; f++) {
        check('e_cw_${aptRiserNode(f)}_M$f',
            (l: 2.0, fu: 15, q: 0.62778, dn: 20, v: 1.998));
        for (final u in kAptUnits) {
          check('e_cw_M${f}_K$u$f',
              (l: kAptUnitBranchM[u]!, fu: 7.5, q: 0.375, dn: 20, v: 1.194));
          for (final MapEntry(:key, :value) in branch.entries) {
            check('e_cw_K$u${f}_$key$u$f', value);
          }
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
      expect(hf(4.393333, 65), closeTo(0.025947, 5e-6));
      expect(hf(3.883333, 50), closeTo(0.074093, 5e-6));
      expect(hf(1.073333, 32), closeTo(0.060184, 5e-6));
      expect(hf(0.627778, 20), closeTo(0.219909, 5e-6));
      expect(hf(0.375, 20), closeTo(0.084687, 5e-6));
      expect(hf(0.1, 15), closeTo(0.029731, 5e-6));
    });
  });

  group('hand values — gravity downfeed from RT, BEFORE / AFTER the PRV', () {
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
        calibrationBySheet: apt.calibrations,
        building: apt.building,
        targetResidual: target,
        mounting: apt.mounting,
        prvSetpoint: defaultPrvSetpoint(
          targetResidual: target,
          maxFixtureStatic: profile.maxFixtureStaticPressure.value,
        ),
      );
    }

    double kpa(Map<String, Pressure> m, String id) => m[id]!.inKiloPascals;

    test('KSb11 critical 6.921 kPa, booster 22.230 m; KSb9 74.735 kPa', () {
      final sol = solve(buildApartmentNetwork(prvFloor: kAptPrvFloor));
      // KSb11: static (42.0 − 39.6) x 9.81 = 23.544. Friction RT → KSb11:
      // 0.025947 x 2.3 (RT→A DN65) + 0.060184 x 8.4 (A→BS→BR11 DN32) +
      // 0.219909 x 2.0 (BR11→M11 DN20) + 0.084687 x 6.0 (M11→Kb11 DN20) +
      // 0.029731 x 6.1 (Kb11→KSb11 DN15) = 1.6945 m = 16.623 kPa ⇒ 6.921.
      expect(sol.criticalNodeId, 'KSb11');
      expect(kpa(sol.noFlowStaticPressure, 'KSb11'), closeTo(23.544, 2e-3));
      expect(kpa(sol.residualPressure, 'KSb11'), closeTo(6.921, 2e-3));
      // (225 − 6.921) / 9.81 = 22.230 m.
      expect(sol.boosterHeadRequired.meters, closeTo(22.230, 5e-4));
      // KSb9 (gravity riser): static (42.0 − 32.6) x 9.81 = 92.214;
      // friction 0.05968 (RT→A) + 0.074093 x 8.0 (A→GR11→GR10→GR9 DN50) +
      // 0.43982 (GR9→M9) + 0.50812 (M9→Kb9) + 0.18136 (Kb9→KSb9) = 1.7818 m
      // ⇒ 74.735 kPa, above the 49.033 SNI floor.
      expect(kpa(sol.noFlowStaticPressure, 'KSb9'), closeTo(92.214, 2e-3));
      expect(kpa(sol.residualPressure, 'KSb9'), closeTo(74.735, 2e-3));
      expect(kpa(sol.residualPressure, 'KSb9'), greaterThan(49.033));
      // Floor 1 (above the PRV) keeps the tank head: (42.0 − 4.6) x 9.81.
      for (final u in kAptUnits) {
        for (final b in kAptFixtures) {
          expect(
              kpa(sol.noFlowStaticPressure, '$b${u}1'), closeTo(366.894, 2e-3));
        }
      }
    });

    test('Lantai 1 over the limit BEFORE, held by PRV0 AFTER', () {
      final before = solve(buildApartmentNetwork());
      final after = solve(buildApartmentNetwork(prvFloor: kAptPrvFloor));
      for (final u in kAptUnits) {
        for (final b in kAptFixtures) {
          final id = '$b${u}0';
          // BEFORE: (42.0 − 1.1) x 9.81 = 401.229 > 392.266.
          expect(kpa(before.noFlowStaticPressure, id), closeTo(401.229, 2e-3));
          expect(kpa(before.noFlowStaticPressure, id), greaterThan(392.266));
          // AFTER: PRV0 at 3.2 m holds 255; 255 + (3.2 − 1.1) x 9.81 =
          // 275.601.
          expect(kpa(after.noFlowStaticPressure, id), closeTo(275.601, 2e-3));
        }
      }
      expect(kpa(after.noFlowStaticPressure, 'PRV0'), closeTo(255.0, 1e-6));
      expect(kpa(after.residualPressure, 'PRV0'), closeTo(255.0, 1e-6));
      // Exactly one PRV station is drawn.
      final net = buildApartmentNetwork(prvFloor: kAptPrvFloor);
      expect(
          net.nodes.where((n) => n.component == NodeComponent.prv).length, 1);
    });
  });

  group('hand values — drainage, vent, rainwater', () {
    late Map<String, EdgeSizing> sz;
    late Map<String, double> fu;
    late Network net;
    setUpAll(() {
      net = buildApartmentNetwork(prvFloor: kAptPrvFloor);
      sz = size(net);
      fu = Map.of(fuOut);
    });
    test('arms, graduated stacks, junction, outfall, stack vents', () {
      // DFU: WC 4 (DN75 WC floor), LAV 1 (DN40), SH 2 (DN50 trap floor), KS
      // 2 (DN40) = 9 per unit-floor.
      for (var f = 0; f < kAptFloors; f++) {
        for (final u in kAptUnits) {
          for (final (b, dfu, dn) in [
            ('WC', 4.0, 75), ('LAV', 1.0, 40), ('SH', 2.0, 50), //
            ('KS', 2.0, 40),
          ]) {
            final id = 'e_dr_$b$u${f}_D$u$f';
            expect(fu[id], dfu, reason: id);
            expect(sz[id]!.diameter.inMillimeters, dn, reason: id);
          }
        }
      }
      // Stack table <= 42 → DN75 (9, 18, 27, 36 DFU; the 9-DFU top raised
      // by the WC floor), <= 240 → DN100 from Da7→Da6 (45) to the base (99).
      for (final u in kAptUnits) {
        for (var f = 11; f >= 1; f--) {
          final id = 'e_dr_D$u${f}_D$u${f - 1}';
          final dfu = 9.0 * (12 - f);
          expect(fu[id], dfu, reason: id);
          expect(sz[id]!.diameter.inMillimeters, dfu <= 36 ? 75 : 100,
              reason: id);
        }
        // Branch table: 108 <= 160 → DN100.
        expect(fu['e_dr_D${u}0_J'], 108);
        expect(sz['e_dr_D${u}0_J']!.diameter.inMillimeters, 100);
        // Vent: 108 DFU (84 < 108 <= 256) → DN100; 42.0 − 38.2 = 3.8 m.
        final v = 'e_vt_D${u}11_VTR$u';
        expect(fu[v], 108);
        expect(sz[v]!.diameter.inMillimeters, 100);
        expect(lengthOf(net, net.edgeById(v)!), closeTo(3.8, 1e-9));
      }
      // 216 DFU on the branch table (<= 360) → DN125.
      expect(fu['e_dr_J_OUT'], 216);
      expect(sz['e_dr_J_OUT']!.diameter.inMillimeters, 125);
    });
    test('rainwater 0.9 x 200 x 200 / 3.6e6 = 10 L/s per drain', () {
      // Half-full Manning n 0.010 @ 1 %: DN150 9.90 < 10 ⇒ DN200; the
      // downpipe (20 L/s, table DN150) is raised to the DN200 collector.
      for (final id in ['e_rw_RDa_RW11', 'e_rw_RDb_RW11']) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(10.0, 1e-9));
        expect(sz[id]!.diameter.inMillimeters, 200);
      }
      for (var f = 11; f >= 1; f--) {
        final id = 'e_rw_RW${f}_RW${f - 1}';
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(20.0, 1e-9));
        expect(sz[id]!.diameter.inMillimeters, 200);
      }
      expect(sz['e_rw_RW0_RWOUT']!.flow.inLitersPerSecond, closeTo(20.0, 1e-9));
      expect(sz['e_rw_RW0_RWOUT']!.diameter.inMillimeters, 200);
    });
  });
}
