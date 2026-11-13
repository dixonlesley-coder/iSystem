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
import 'package:mechx_engine/hydraulics.dart' show headLossHazenWilliams;
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
    // Per unit 31 nodes (+2 cassette ACs in unit A), 35 edges.
    expect(net.nodes.length, 3 * 31 + 2);
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
    // Two cassettes share the room (the app's `acUnitShare` rule).
    final perUnit = load.btuPerHr / kShopAcNodeIds.length;
    final unit = selectAc(perUnit);
    final unitInput = acInputPowerW(
        coolingBtuPerHr:
            unit.exceedsRange ? perUnit : unit.nominalBtuPerHr);
    _p('## ENGINE per cassette (x${kShopAcNodeIds.length}): '
        '${_f(perUnit, 1)} BTU/h -> ${unit.pk} PK (${unit.nominalBtuPerHr} '
        'BTU/h, exceedsRange=${unit.exceedsRange}) inputW=${_f(unitInput, 1)}');
    expect(load.btuPerHr, greaterThan(0));
  });

  test('electrical: computeSystem + computeAdvancedStudy evaluate over PP '
      'Ruko and the three sub-boards', () {
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
    expect(sys.panels[kShopMainPanelId]!.circuits.length, 3);
    for (final u in kShopUnits) {
      expect(sys.panels[shopPanelId(u)]!.circuits.length, 8);
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
  // Per unit, identical for A / B / C (each unit asserted). Tolerances as in
  // the house tests.
  group('hand values — cold water sizing (per unit)', () {
    late Map<String, EdgeSizing> sz;
    late Map<String, double> fu;
    setUpAll(() {
      sz = size();
      fu = Map.of(fuOut);
    });
    double lengthOf(String id) => edgeLength(net.edgeById(id)!, net,
            calibrationBySheet: shop.calibrations,
            building: shop.building,
            mounting: shop.mounting)
        .meters;
    // UBAP (private): WC flush tank 2.5, LAV 1.0, KS 2.0. Demand curve
    // (flush tank) 10..25 segment: q = 0.5 + (u - 10) x 0.38333 / 15; below
    // 10 linear 0.05 L/s per UBAP. DN: first nominal with Q / (pi D^2 / 4)
    // <= 2.0 m/s. Lengths: plan + vertical leg (main 3.7 / 7.7 / 11.7 m,
    // fixture 1.1 / 5.1 / 9.1 m, ground plant 0.0, roof tank 12.0, booster on
    // the L3 slab 8.0, meter at the L1 ceiling 3.7).
    const cases = <String, ({double l, double fu, double q, int dn, double v})>{
      // F2: the meter stub feeds GT what GT delivers: 12.5 UBAP; 3.0 plan +
      // 3.7 meter ceiling -> GT slab.
      'e_cw_WM_GT': (l: 6.7, fu: 12.5, q: 0.5639, dn: 20, v: 1.795),
      // 12.5 UBAP = 3 x (2.5 + 1.0) + 2.0; q = 0.5 + 2.5 x 0.38333 / 15
      // = 0.56389; DN15 v 3.19 > 2 -> DN20 v 1.795.
      'e_cw_GT_TP': (l: 1.0, fu: 12.5, q: 0.5639, dn: 20, v: 1.795),
      'e_cw_TP_U0': (l: 4.7, fu: 12.5, q: 0.5639, dn: 20, v: 1.795), // 1 + 3.7
      'e_cw_U0_U1': (l: 4.0, fu: 12.5, q: 0.5639, dn: 20, v: 1.795),
      'e_cw_U1_U2': (l: 4.0, fu: 12.5, q: 0.5639, dn: 20, v: 1.795),
      'e_cw_U2_RT': (l: 2.3, fu: 12.5, q: 0.5639, dn: 20, v: 1.795), // 2 + 0.3
      'e_cw_RT_BS': (l: 5.0, fu: 12.5, q: 0.5639, dn: 20, v: 1.795), // 1 + 4
      'e_cw_BS_A2': (l: 4.7, fu: 12.5, q: 0.5639, dn: 20, v: 1.795), // 1 + 3.7
      // L3 branch: 2.5 + 1.0 = 3.5 x 0.05 = 0.175 L/s, DN15 v 0.990.
      'e_cw_A2_B2': (l: 2.0, fu: 3.5, q: 0.175, dn: 15, v: 0.990),
      // Riser below L3: 2 x 3.5 + 2.0 = 9.0 -> 0.45 L/s; DN15 v 2.55 -> DN20
      // v 1.432.
      'e_cw_A2_A1': (l: 4.0, fu: 9.0, q: 0.45, dn: 20, v: 1.432),
      // Below L2: 3.5 + 2.0 = 5.5 -> 0.275, DN15 v 1.556.
      'e_cw_A1_A0': (l: 4.0, fu: 5.5, q: 0.275, dn: 15, v: 1.556),
      'e_cw_A1_B1': (l: 2.0, fu: 3.5, q: 0.175, dn: 15, v: 0.990),
      'e_cw_A0_B0': (l: 2.0, fu: 5.5, q: 0.275, dn: 15, v: 1.556),
      // Branches: plan + main 11.7 / 7.7 / 3.7 -> fixture 9.1 / 5.1 / 1.1 =
      // + 2.6 m.
      'e_cw_B2_WC2': (l: 3.6, fu: 2.5, q: 0.125, dn: 15, v: 0.707),
      'e_cw_B2_LAV2': (l: 4.1, fu: 1.0, q: 0.05, dn: 15, v: 0.283),
      'e_cw_B1_WC1': (l: 3.6, fu: 2.5, q: 0.125, dn: 15, v: 0.707),
      'e_cw_B1_LAV1': (l: 4.1, fu: 1.0, q: 0.05, dn: 15, v: 0.283),
      'e_cw_B0_WC0': (l: 3.6, fu: 2.5, q: 0.125, dn: 15, v: 0.707),
      'e_cw_B0_LAV0': (l: 4.1, fu: 1.0, q: 0.05, dn: 15, v: 0.283),
      'e_cw_B0_KS0': (l: 6.6, fu: 2.0, q: 0.1, dn: 15, v: 0.566),
    };
    for (final MapEntry(key: base, value: x) in cases.entries) {
      test(base, () {
        for (final u in kShopUnits) {
          final id = net.edges
              .firstWhere((e) =>
                  _unsuffixed(e.id) == base && e.fromId.endsWith('_$u'))
              .id;
          expect(lengthOf(id), closeTo(x.l, 1e-9), reason: id);
          expect(fu[id], closeTo(x.fu, 1e-9), reason: id);
          expect(sz[id]!.flow.inLitersPerSecond, closeTo(x.q, 5e-5),
              reason: id);
          expect(sz[id]!.diameter.inMillimeters, x.dn, reason: id);
          expect(sz[id]!.velocity.metersPerSecond, closeTo(x.v, 5e-4),
              reason: id);
        }
      });
    }
    test('Hazen–Williams C150 friction per metre', () {
      // hf/L = 10.67 Q^1.852 / (150^1.852 D^4.8704).
      double hfPerM(double lps, int dnMm) => headLossHazenWilliams(
            flow: FlowRate.litersPerSecond(lps),
            length: const Length(1),
            diameter: Diameter.mm(dnMm.toDouble()),
            hazenWilliamsC: 150,
          ).meters;
      expect(hfPerM(0.5638883333, 20), closeTo(0.18026, 5e-5));
      expect(hfPerM(0.45, 20), closeTo(0.11870, 5e-5));
      expect(hfPerM(0.275, 15), closeTo(0.19358, 5e-5));
      expect(hfPerM(0.175, 15), closeTo(0.083814, 5e-6));
      expect(hfPerM(0.125, 15), closeTo(0.044946, 5e-6));
      expect(hfPerM(0.1, 15), closeTo(0.029731, 5e-6));
      expect(hfPerM(0.05, 15), closeTo(0.0082356, 5e-7));
    });
  });

  group('hand values — gravity downfeed (per unit, from its own RT)', () {
    test('statics, residuals, critical WC2, booster 22.114 m', () {
      final sizing = size();
      final target =
          SupplyDesignCriteria.recommended().targetFixtureResidualPressure;
      for (final u in kShopUnits) {
        final sol = solveDownfeed(
          net: net,
          service: ServiceType.coldWater,
          tankId: shopId('RT', u),
          edgeFlows: {
            for (final e in net.edges)
              if (e.service == ServiceType.coldWater && sizing[e.id] != null)
                e.id: sizing[e.id]!.flow,
          },
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
        double kpa(Map<String, Pressure> m, String base) =>
            m[shopId(base, u)]!.inKiloPascals;
        // Static = 9.81 x (12.0 − fixture height): 2.9 / 6.9 / 10.9 m.
        for (final (f, st) in [
          ('WC2', 28.449), ('LAV2', 28.449), ('WC1', 67.689),
          ('LAV1', 67.689), ('WC0', 106.929), ('LAV0', 106.929),
          ('KS0', 106.929), //
        ]) {
          expect(kpa(sol.noFlowStaticPressure, f), closeTo(st, 5e-4),
              reason: '$f $u');
        }
        // Residual = static − 9.81 x Σ hf. WC2: RT→BS 5.0 + BS→A2 4.7 at
        // 0.18026, A2→B2 2.0 at 0.083814, B2→WC2 3.6 at 0.044946 =
        // 2.0717 m ⇒ 28.449 − 20.324 = 8.064 kPa.
        for (final (f, r) in [
          ('WC2', 8.064), ('LAV2', 9.320), ('WC1', 42.646), ('LAV1', 43.902),
          ('WC0', 72.136), ('LAV0', 73.392), ('KS0', 71.799), //
        ]) {
          expect(kpa(sol.residualPressure, f), closeTo(r, 5e-4),
              reason: '$f $u');
        }
        expect(sol.criticalNodeId, shopId('WC2', u));
        // (225 − 8.064) / 9.81 = 22.114 m.
        expect(sol.boosterHeadRequired.meters, closeTo(22.114, 5e-4));
        expect(sol.residualPressure[shopId('RT', u)]!.pascals, 0);
      }
    });
  });

  group('hand values — drainage, vent, rainwater (per unit)', () {
    late Map<String, EdgeSizing> sz;
    late Map<String, double> fu;
    setUpAll(() {
      sz = size();
      fu = Map.of(fuOut);
    });
    double lengthOf(String id) => edgeLength(net.edgeById(id)!, net,
            calibrationBySheet: shop.calibrations,
            building: shop.building,
            mounting: shop.mounting)
        .meters;
    // DFU: WC 4, LAV 1, KS 2. Branch table 3/6/12/20/160 → 40/50/65/75/100,
    // stack table 2/10/20/42/240 → 40/50/65/75/100; any drain carrying a WC
    // is ≥ DN75, > 2 WCs on a branch ⇒ DN100.
    const cases = <String, ({double dfu, int dn, double l})>{
      'e_dr_WC2_D2': (dfu: 4, dn: 75, l: 1.5),
      'e_dr_LAV2_D2': (dfu: 1, dn: 40, l: 1.5),
      'e_dr_WC1_D1': (dfu: 4, dn: 75, l: 1.5),
      'e_dr_LAV1_D1': (dfu: 1, dn: 40, l: 1.5),
      'e_dr_WC0_D0': (dfu: 4, dn: 75, l: 1.5),
      'e_dr_LAV0_D0': (dfu: 1, dn: 40, l: 1.5),
      'e_dr_KS0_D0': (dfu: 2, dn: 40, l: 2.0),
      // Stack: 5 DFU (stack table → DN50, WC floor DN75), 7.7 → 3.7 under
      // the L3 / L2 slabs = 4.0 m; 10 DFU, 3.7 → 0.0 = 3.7 m.
      'e_dr_D2_D1': (dfu: 5, dn: 75, l: 4.0),
      'e_dr_D1_D0': (dfu: 10, dn: 75, l: 3.7),
      // Building drain: 17 DFU (branch table DN100 at 20; 3 WCs > 2 ⇒ DN100).
      'e_dr_D0_OUT': (dfu: 17, dn: 100, l: 8.0),
      // F3 stack vent: the stack base's 17 DFU, vent table 8 < 17 <= 24 ⇒
      // DN50; M1 length 12.0 roof − 7.7 under-slab = 4.3 m.
      'e_vt_D2_VTR': (dfu: 17, dn: 50, l: 4.3),
    };
    for (final MapEntry(key: base, value: x) in cases.entries) {
      test(base, () {
        for (final u in kShopUnits) {
          final id = net.edges
              .firstWhere((e) =>
                  _unsuffixed(e.id) == base && e.fromId.endsWith('_$u'))
              .id;
          expect(fu[id], closeTo(x.dfu, 1e-9), reason: id);
          expect(sz[id]!.diameter.inMillimeters, x.dn, reason: id);
          expect(lengthOf(id), closeTo(x.l, 1e-9), reason: id);
        }
      });
    }
    test('rainwater: Q = 0.9 × 200 × 80 / 3.6e6 = 4.0 L/s, DN125 throughout',
        () {
      for (final u in kShopUnits) {
        for (final base in [
          'e_rw_RD_RW2', 'e_rw_RW2_RW1', 'e_rw_RW1_RW0', 'e_rw_RW0_RWOUT', //
        ]) {
          final id = net.edges
              .firstWhere((e) =>
                  _unsuffixed(e.id) == base && e.fromId.endsWith('_$u'))
              .id;
          expect(sz[id]!.flow.inLitersPerSecond, closeTo(4.0, 1e-4),
              reason: id);
          // Half-full Manning n 0.010 at 1 %: DN100 3.36 L/s < 4.0, DN125
          // 6.09 ⇒ DN125; the downpipes are raised to it (no necking).
          expect(sz[id]!.diameter.inMillimeters, 125, reason: id);
        }
      }
    });
  });

  group('hand values — room cooling', () {
    test('60 m² × 600 × 3.7 / 3.0 = 44 400 BTU/h; 2 × 22 200 → 2.5 PK, '
        '2344.6 W each', () {
      final room = kShophouseRooms.single;
      final load = estimateCoolingLoad(
        floorArea: Area(room.widthM * room.depthM),
        ceilingHeight: const Length(_seededCeilingM),
        densityBtuPerHrPerM2: const SniVentilationProfile()
            .coolingLoadDensityBtuPerHrM2(room.roomType)
            .value,
      );
      expect(load.btuPerHr, closeTo(44400, 1e-6));
      expect(load.pk, closeTo(4.933, 5e-4)); // 44 400 / 9000
      final unit = selectAc(load.btuPerHr / 2);
      expect(unit.pk, 2.5);
      expect(unit.nominalBtuPerHr, 24000);
      // 24 000 / 3.412141633 / 3.0 = 2344.6 W.
      expect(acInputPowerW(coolingBtuPerHr: unit.nominalBtuPerHr),
          closeTo(2344.6, 0.05));
    });
  });

  group('hand values — sub-board ways (per unit)', () {
    test('lighting / sockets / AC ways and the board demand', () {
      final project = shop.electrical;
      final sys = computeSystem(
        const PuilProfile(),
        project,
        calibrationBySheet: shop.calibrations,
        building: shop.building,
        originFaultLevel: estimatedServiceFaultLevelA(project)!,
        busbarClearingTimeS: 0.1,
        phaseReassignThresholdA: 1.0,
      );
      // I = W / (220 cos φ); sockets size + run on the undiversified 1000 W
      // (5.051 A, Ib diversified 0.7 × = 3.535 A); VD = 2 I L (R cos φ +
      // 0.08 sin φ) / 1000 / 220, printed to 0.01 % (the reviewer's 0.168 /
      // 0.216 / 0.442 / 0.589 / 0.736 / 0.608 round to the pins below).
      const cases = <String,
          ({double runA, int mcb, String curve, double csa, double vd})>{
        'lampu_lt1': (runA: 1.0, mcb: 6, curve: 'b', csa: 1.5, vd: 0.12),
        'lampu_lt2': (runA: 1.0, mcb: 6, curve: 'b', csa: 1.5, vd: 0.17),
        'lampu_lt3': (runA: 1.0, mcb: 6, curve: 'b', csa: 1.5, vd: 0.22),
        'kk_lt1': (runA: 5.1, mcb: 6, curve: 'c', csa: 2.5, vd: 0.44),
        'kk_lt2': (runA: 5.1, mcb: 6, curve: 'c', csa: 2.5, vd: 0.59),
        'kk_lt3': (runA: 5.1, mcb: 6, curve: 'c', csa: 2.5, vd: 0.74),
        'ac_lt2': (runA: 5.9, mcb: 6, curve: 'c', csa: 2.5, vd: 0.61),
        'ac_lt3': (runA: 5.9, mcb: 6, curve: 'c', csa: 2.5, vd: 0.77),
      };
      for (final u in kShopUnits) {
        final p = sys.panels[shopPanelId(u)]!;
        for (final MapEntry(key: base, value: x) in cases.entries) {
          final r = p.circuits.firstWhere((c) => c.circuitId == 'c_${base}_$u');
          expect(r.runCurrentA.amperes, closeTo(x.runA, 1e-9), reason: base);
          expect(r.breaker.ratingA.amperes, x.mcb, reason: base);
          expect(r.breaker.curve.name, x.curve, reason: base);
          expect(r.cable.csaMm2, x.csa, reason: base);
          expect(r.voltageDrop.dropPercent, closeTo(x.vd, 1e-9), reason: base);
        }
        // Exact currents: 200 / 198 = 1.0101; 1000 / 198 = 5.0505 run,
        // × 0.7 = 3.5354 design; 1100 / 187 = 5.882 run, × 0.9 = 5.2941.
        double exact(String base) => p.circuits
            .firstWhere((c) => c.circuitId == 'c_${base}_$u')
            .designCurrentExactA!;
        expect(exact('lampu_lt1'), closeTo(1.0101, 5e-5));
        expect(exact('kk_lt1'), closeTo(3.5354, 5e-5));
        expect(exact('ac_lt2'), closeTo(5.2941, 5e-5));
        // 600 + 3 × 700 + 2 × 990 = 4680 W; VA 600/0.9 + 2100/0.9 +
        // 1980/0.85 = 5329; I = 5329 / 220 = 24.2 A ⇒ incomer 25 A.
        expect(p.demandW, closeTo(4680, 1e-6));
        expect(p.demandVa, closeTo(5329, 0.5));
        expect(p.demandCurrent.amperes, closeTo(24.2, 1e-9));
        expect(p.incomer.breaker.ratingA.amperes, 25);
      }
    });
  });
}
