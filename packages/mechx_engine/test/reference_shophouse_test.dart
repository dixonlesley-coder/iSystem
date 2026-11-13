// Reference building 2 (shophouse row) — ENGINE-level solve smoke test.
//
// Builds the fixed three-unit shophouse row (`test/reference/shophouse.dart`)
// and runs it through the real engine: `autoSizeNetwork` with the building +
// calibrations (the argument set the app's `sizingDetailProvider` passes),
// one roof-tank DOWNFEED pressure solve per unit (from that unit's RT), the
// area-density cooling load of unit A's retail room, and the electrical
// `computeSystem` + `computeAdvancedStudy` over the three service boards. It
// asserts only that nothing throws, that every flowing edge comes back sized
// and that the three units size identically; the hand-derived expected
// values are a later task. Set REF_DUMP=1 to print the solved figures.
//
// What the engine level does NOT do (app-only, see the app test): the
// transfer / booster pump duties (`supplyMoverDutiesProvider`), the delivered
// field with the booster running, and the MEP-equipment electrical sync.
import 'dart:io';

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart'
    show defaultLvUtilityFaultKa, estimatedServiceFaultLevelA;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart' show defaultPrvSetpoint;
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show drainageFixtureUnit;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/shophouse.dart';

// The app-side defaults `sizingDetailProvider` feeds the sizer
// (lib/store/sizing_store.dart `kDefaultLeafDemand` /
// `kDefaultLeafFixtureUnits` / `kDefaultRoofAreaPerOutlet`, and
// lib/store/app_state.dart's 200 mm/h design rainfall), mirrored here because
// the engine package cannot import the app (same as the house test).
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

/// The ceiling the app's `RoomAreaController.add` seeds for a room on a
/// 4.0 m floor: floor-to-floor less the default 0.3 m ceiling drop.
const double _seededCeilingM = 4.0 - 0.3;

final bool _dump = Platform.environment['REF_DUMP'] == '1';
void _p(String s) {
  if (_dump) print(s); // ignore: avoid_print
}

String _f(double v, [int dp = 3]) => v.toStringAsFixed(dp);

/// [id] with its unit suffix stripped (`e_cw_WM_A_GT_A` → `e_cw_WM_GT`).
String _unsuffixed(String id) => id.replaceAll(RegExp(r'_[ABC](?=_|$)'), '');

void main() {
  final shop = buildShophouse();
  final net = shop.network;
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
                occupancy: shop.occupancy),
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
      building: shop.building,
      calibrationBySheet: shop.calibrations,
      mounting: shop.mounting,
      fixtureUnitsOut: fuOut,
    );
  }

  test('the shophouse fixture is the spec: 3 floors, 3 identical units, '
      'every run its exact length', () {
    expect(shop.building.levelCount, 3);
    // Per unit 31 nodes (+1 AC in unit A), 35 edges.
    expect(net.nodes.length, 3 * 31 + 1);
    expect(net.edges.length, 3 * 35);
    const runM = {
      'e_cw_WM_GT': 3.0, 'e_cw_GT_TP': 1.0, 'e_cw_TP_U0': 1.0,
      'e_cw_U2_RT': 2.0, 'e_cw_RT_BS': 1.0, 'e_cw_BS_A2': 1.0,
      'e_cw_A2_B2': 2.0, 'e_cw_A1_B1': 2.0, 'e_cw_A0_B0': 2.0,
      'e_cw_B2_WC2': 1.0, 'e_cw_B2_LAV2': 1.5, 'e_cw_B1_WC1': 1.0,
      'e_cw_B1_LAV1': 1.5, 'e_cw_B0_WC0': 1.0, 'e_cw_B0_LAV0': 1.5,
      'e_cw_B0_KS0': 4.0,
      'e_dr_WC2_D2': 1.5, 'e_dr_LAV2_D2': 1.5, 'e_dr_WC1_D1': 1.5,
      'e_dr_LAV1_D1': 1.5, 'e_dr_WC0_D0': 1.5, 'e_dr_LAV0_D0': 1.5,
      'e_dr_KS0_D0': 2.0, 'e_dr_D0_OUT': 8.0,
      'e_rw_RD_RW2': 1.0, 'e_rw_RW0_RWOUT': 5.0,
    };
    for (final u in kShopUnits) {
      for (final MapEntry(:key, :value) in runM.entries) {
        final e = net.edges.firstWhere((e) => _unsuffixed(e.id) == key &&
            e.fromId.endsWith('_$u'));
        final cal = shop.calibrations[net.nodeById(e.fromId)!.sheetId]!;
        expect(cal.lengthForPixels(runPixelLength(e, net)).meters,
            closeTo(value, 1e-9),
            reason: '${e.id}');
      }
    }
    final room = kShophouseRooms.single;
    expect(room.widthM, closeTo(5.0, 1e-12));
    expect(room.depthM, closeTo(12.0, 1e-12));
  });

  test('mechanical: sizes every flowing edge, the three units identically, '
      'and solves each unit\'s downfeed', () {
    final sizing = size();
    _p('## ENGINE sizing (unit A; B and C compared below)');
    for (final e in net.edges) {
      if (!e.fromId.endsWith('_A')) continue;
      final s = sizing[e.id];
      final len = edgeLength(e, net,
              calibrationBySheet: shop.calibrations,
              building: shop.building,
              mounting: shop.mounting)
          .meters;
      _p('${e.id} ${e.service.name} ${e.kind.name} L=${_f(len)} '
          'FU=${fuOut[e.id]} '
          'Q=${s == null ? '-' : _f(s.flow.inLitersPerSecond, 4)} '
          'DN=${s?.diameter.inMillimeters} '
          'v=${s == null ? '-' : _f(s.velocity.metersPerSecond)} '
          'from=${s?.flowFromId}');
    }
    for (final e in net.edges) {
      expect(sizing[e.id], isNotNull, reason: e.id);
      expect(sizing[e.id]!.diameter.inMillimeters, greaterThan(0),
          reason: e.id);
      if (e.service == ServiceType.rainwater) {
        expect(sizing[e.id]!.flow.cubicMetersPerSecond, greaterThan(0),
            reason: e.id);
      } else if (e.service == ServiceType.drainage) {
        expect(fuOut[e.id], greaterThan(0), reason: e.id);
      }
    }
    // The three units are identical: the same unsuffixed edge sizes the same.
    String sig(String id) {
      final s = sizing[id]!;
      return 'FU=${fuOut[id]} Q=${_f(s.flow.inLitersPerSecond, 6)} '
          'DN=${s.diameter.inMillimeters} v=${_f(s.velocity.metersPerSecond, 6)} '
          'from=${s.flowFromId == null ? null : _unsuffixed(s.flowFromId!)}';
    }

    final diffs = <String>[];
    for (final e in net.edges.where((e) => e.fromId.endsWith('_A'))) {
      final base = _unsuffixed(e.id);
      for (final u in ['B', 'C']) {
        final other = net.edges.firstWhere(
            (o) => _unsuffixed(o.id) == base && o.fromId.endsWith('_$u'));
        if (sig(e.id) != sig(other.id)) {
          diffs.add('${other.id}: ${sig(other.id)} vs A ${sig(e.id)}');
        }
      }
    }
    _p('## ENGINE unit B / C vs A sizing differences: '
        '${diffs.isEmpty ? 'none' : diffs.join('; ')}');
    expect(diffs, isEmpty);

    final target =
        SupplyDesignCriteria.recommended().targetFixtureResidualPressure;
    final flows = {
      for (final e in net.edges)
        if (e.service == ServiceType.coldWater && sizing[e.id] != null)
          e.id: sizing[e.id]!.flow,
    };
    final perUnit = <String, Map<String, String>>{};
    for (final u in kShopUnits) {
      final sol = solveDownfeed(
        net: net,
        service: ServiceType.coldWater,
        tankId: shopId('RT', u),
        edgeFlows: flows,
        sizing: sizing,
        calibrationBySheet: shop.calibrations,
        building: shop.building,
        targetResidual: target,
        mounting: shop.mounting,
        prvSetpoint: defaultPrvSetpoint(
          targetResidual: target,
          maxFixtureStatic: profile.maxFixtureStaticPressure.value,
        ),
      );
      _p('## ENGINE downfeed unit $u from RT_$u critical=${sol.criticalNodeId} '
          'min=${_f(sol.minResidual.inKiloPascals)} kPa '
          'booster=${_f(sol.boosterHeadRequired.meters)} m '
          'gravitySufficient=${sol.gravitySufficient}');
      final ids = sol.residualPressure.keys.toList()..sort();
      perUnit[u] = {};
      for (final id in ids) {
        final line = 'delivery=${sol.deliveryNodeIds.contains(id)} '
            'residual=${_f(sol.residualPressure[id]!.inKiloPascals)} '
            'static=${_f(sol.noFlowStaticPressure[id]?.inKiloPascals ?? double.nan)}';
        perUnit[u]![_unsuffixed(id)] = line;
        _p('$id $line');
      }
      for (final f in kShopUnitFixtureIds) {
        expect(sol.deliveryNodeIds, contains(shopId(f, u)));
        expect(sol.residualPressure[shopId(f, u)], isNotNull,
            reason: shopId(f, u));
      }
    }
    expect(perUnit['B'], perUnit['A']);
    expect(perUnit['C'], perUnit['A']);
  });

  test('room cooling: unit A retail room by the area-density rule', () {
    final room = kShophouseRooms.single;
    final density = const SniVentilationProfile()
        .coolingLoadDensityBtuPerHrM2(room.roomType)
        .value;
    final area = room.widthM * room.depthM;
    final load = estimateCoolingLoad(
      floorArea: Area(area),
      ceilingHeight: const Length(_seededCeilingM),
      densityBtuPerHrPerM2: density,
    );
    final input = acInputPowerW(
        coolingBtuPerHr: load.recommended.exceedsRange
            ? load.btuPerHr
            : load.recommended.nominalBtuPerHr);
    _p('## ENGINE room cooling ${room.name} type=${room.roomType.name} '
        'area=${_f(area)} m2 ceiling=$_seededCeilingM m density=$density '
        'BTU/h/m2 load=${_f(load.btuPerHr, 1)} BTU/h (${_f(load.watts, 1)} W) '
        'pk=${_f(load.pk)} recommended=${load.recommended.pk} PK '
        '(${load.recommended.nominalBtuPerHr} BTU/h, '
        'exceedsRange=${load.recommended.exceedsRange}) '
        'inputW(one unit, COP $kAcDefaultCop)=${_f(input, 1)}');
    expect(load.btuPerHr, greaterThan(0));
  });

  test('electrical: computeSystem + computeAdvancedStudy evaluate over the '
      'three service boards', () {
    final project = shop.electrical;
    final fault = estimatedServiceFaultLevelA(project) ??
        const Current(defaultLvUtilityFaultKa * 1000);
    final sys = computeSystem(
      const PuilProfile(),
      project,
      calibrationBySheet: shop.calibrations,
      building: shop.building,
      originFaultLevel: fault,
      busbarClearingTimeS: 0.1,
      phaseReassignThresholdA: 1.0,
    );
    final adv = computeAdvancedStudy(const PuilProfile(), project, sys);
    _p('## ENGINE electrical origin fault=${_f(fault.amperes, 1)} A');
    for (final u in kShopUnits) {
      final panel = sys.panels[shopPanelId(u)]!;
      for (final c in panel.circuits) {
        _p('${c.circuitId} phase=${c.phase.name} Ib=${c.designCurrent.amperes} '
            'run=${c.runCurrentA.amperes} '
            'MCB=${c.breaker.ratingA.amperes} ${c.breaker.curve.name} '
            'cable=${c.cable.csaMm2} Iz=${c.cable.deratedIz.amperes} '
            'vd=${_f(c.voltageDrop.dropPercent)}%');
      }
      _p('panel ${panel.name} demandW=${panel.demandW} VA=${panel.demandVa} '
          'I=${panel.demandCurrent.amperes} '
          'incomer=${panel.incomer.breaker.ratingA.amperes} '
          'phaseBalance=${panel.phaseBalance.l1}/${panel.phaseBalance.l2}/'
          '${panel.phaseBalance.l3}');
      expect(panel.circuits.length, 8);
      for (final c in panel.circuits) {
        expect(c.breaker.ratingA.amperes, greaterThan(0), reason: c.circuitId);
        expect(c.cable.csaMm2, greaterThan(0), reason: c.circuitId);
      }
      expect(adv.fault.panels[shopPanelId(u)], isNotNull);
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
