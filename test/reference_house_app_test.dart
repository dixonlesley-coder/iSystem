// Reference building 1 (house) — APP-level smoke test.
//
// Loads the fixed house (`packages/mechx_engine/test/reference/house.dart`)
// into a ProviderContainer through the real store intents (sheets, floors,
// calibrations, feed strategy, occupancy, the network and the electrical
// project) and evaluates the providers every printed surface reads: sizing,
// the downfeed solve, pump / PRV duties, BOM + fittings, the Review fan-in,
// the compliance roll-up and the electrical result / advanced study /
// warnings. It asserts only that the project loads and the providers
// evaluate; hand-derived expected values are a later task. Set REF_DUMP=1 to
// print every solved figure (the source of the reference report).
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/electrical/panel_results.dart' show PhaseAssignmentInfo;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/puil.dart' show BreakerClassCode;

import '../packages/mechx_engine/test/reference/house.dart';

final bool _dump = Platform.environment['REF_DUMP'] == '1';
final StringBuffer _out = StringBuffer();
void _p(String s) => _out.writeln(s);

String _f(double? v, [int dp = 3]) => v == null ? '-' : v.toStringAsFixed(dp);

Future<ProviderContainer> _loadHouse(ReferenceBuilding house) async {
  final c = ProviderContainer();
  c.read(sheetsControllerProvider.notifier).loadSheets(
    [
      for (final s in house.sheets)
        Sheet(id: s.id, name: s.name, sizePx: const Size(1684, 1190)),
    ],
    sheetFloors: {for (final s in house.sheets) s.id: s.floorIndex},
  );
  final project = c.read(projectControllerProvider.notifier)
    ..setFloors(house.building.floors);
  for (final MapEntry(:key, :value) in house.calibrations.entries) {
    project.setCalibration(key, value);
  }
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(occupancyProvider.notifier).set(house.occupancy);
  c.read(networkControllerProvider.notifier).loadNetwork(house.network);
  c.read(electricalProjectProvider.notifier).setProject(house.electrical);
  // Let the electrical store's deferred MEP-equipment sync run.
  await Future<void>.delayed(Duration.zero);
  return c;
}

void _dumpMechanical(ProviderContainer c, ReferenceBuilding house) {
  final net = c.read(sizingNetworkProvider);
  final project = c.read(projectControllerProvider);
  final sizing = c.read(sizingProvider);
  final fu = c.read(edgeFixtureUnitsProvider);
  final lengths = projectEdgeLengths(net, project);
  _p('## APP sizing (edge | service | kind | L m | FU | Q L/s | DN | W x H | '
      'v m/s | from | flags)');
  for (final e in net.edges) {
    final s = sizing[e.id];
    final flags = [
      if (s?.overCapacity ?? false) 'overCapacity',
      if (s?.stackRaisedForBranch ?? false) 'stackRaisedForBranch',
      if (!(s?.selfCleansingOk ?? true)) 'selfCleansingFail',
      if (s?.loopUnbalanced ?? false) 'loopUnbalanced',
      if (s?.demandCurveExtrapolated ?? false) 'demandCurveExtrapolated',
      if (s?.belowCodeMinimum ?? false) 'belowCodeMinimum',
    ];
    _p('| ${e.id} | ${e.service.name} | ${e.kind.name} | '
        '${_f(lengths[e.id]?.meters)} | ${fu[e.id] ?? '-'} | '
        '${_f(s?.flow.inLitersPerSecond, 4)} | ${s?.diameter.inMillimeters} | '
        '${s?.width == null ? '-' : '${s!.width!.inMillimeters}x${s.height!.inMillimeters}'} | '
        '${_f(s?.velocity.metersPerSecond)} | ${s?.flowFromId} | '
        '${flags.isEmpty ? '-' : flags.join(',')} |');
  }
  _p('## APP velocity checks');
  for (final e in c.read(waterVelocityChecksProvider).entries) {
    final v = e.value;
    _p('${e.key}: ${_f(v.actual.metersPerSecond)} in '
        '[${_f(v.min.metersPerSecond)}, ${_f(v.max.metersPerSecond)}] '
        '${v.verdict.name}');
  }
  _p('## APP drainage advisories');
  for (final a in c.read(drainageAdvisoryProvider)) {
    _p('${a.edgeId}: ${a.kind} ${a.message}');
  }

  _p('## APP node elevations (nodeElevation / displayed)');
  for (final n in net.nodes) {
    _p('${n.id} floor=${n.floorIndex} role=${n.role.name} '
        'comp=${n.component?.name} fixture=${n.fixture?.name} '
        'z=${_f(nodeElevation(n, project.building, project.mounting).meters)} '
        'shown=${_f(displayedNodeElevation(net, n, project.building, project.mounting).meters)}');
  }

  _p('## APP downfeed');
  _p('gravityDownfeedDrawn=${c.read(gravityDownfeedDrawnProvider)} '
      'tankElevation=${_f(c.read(downfeedTankElevationProvider)?.meters)} '
      'target=${_f(c.read(targetResidualProvider).inKiloPascals)} kPa');
  final down = c.read(downfeedProvider);
  final delivered = c.read(downfeedDeliveredProvider);
  final floors = c.read(downfeedSniFloorsProvider);
  if (down != null) {
    _p('critical=${down.criticalNodeId} '
        'minResidual=${_f(down.minResidual.inKiloPascals)} kPa '
        'boosterHeadRequired=${_f(down.boosterHeadRequired.meters)} m '
        'gravitySufficient=${down.gravitySufficient}');
    _p('sniMinimumAtCritical='
        '${_f(c.read(downfeedSniMinimumResidualProvider)?.inKiloPascals)} kPa');
    final ids = down.residualPressure.keys.toList()..sort();
    for (final id in ids) {
      _p('$id delivery=${down.deliveryNodeIds.contains(id)} '
          'static=${_f(down.noFlowStaticPressure[id]?.inKiloPascals)} '
          'residual=${_f(down.residualPressure[id]?.inKiloPascals)} '
          'delivered=${_f(delivered?.residualPressure[id]?.inKiloPascals)} '
          'sniFloor=${_f(floors[id]?.inKiloPascals)} kPa');
    }
  }
  _p('overPressure=${c.read(downfeedOverPressureProvider)}');
  final pump = c.read(pumpDutyProvider);
  _p('pumpDuty=${pump == null ? 'null' : 'Q=${_f(pump.flow.inLitersPerSecond, 4)} L/s '
      'H=${_f(pump.head.meters)} m shaft=${_f(pump.shaftPower.watts, 1)} W '
      'motor=${_f(pump.selectedMotor.inKiloWatts, 2)} kW'}');
  _p('supplyMovers=${c.read(supplyMoverDutiesProvider).keys.toList()} '
      'booster=${c.read(supplyBoosterProvider)} '
      'peakFlow=${_f(c.read(supplyPeakFlowProvider)?.inLitersPerSecond, 4)} L/s');
  _p('zones=${[for (final z in c.read(zonesProvider)) '${z.bottomFloorIndex}-${z.topFloorIndex}']}');
  for (final z in c.read(zoneStaticsProvider)) {
    _p('zoneStatic ${z.zone.bottomFloorIndex}-${z.zone.topFloorIndex} '
        'topResidual=${_f(z.topResidual.inKiloPascals)} '
        'bottomStatic=${_f(z.bottomStatic.inKiloPascals)} '
        'within=${z.withinLimit} viaPrv=${z.viaPrv}');
  }

  _p('## APP BOM (service | kind | DN | m | segs | material | tag | floor | flags)');
  for (final b in c.read(bomProvider)) {
    _p('| ${b.service.name} | ${b.kind.name} | ${b.diameterMm} | '
        '${_f(b.totalLength.meters)} | ${b.segmentCount} | ${b.material} | '
        '${b.tag} | ${b.floorIndex} | manual=${b.manual} assumed=${b.assumed} '
        'unmeasured=${b.unmeasuredSegments} |');
  }
  _p('## APP fittings (service | type | DN | count | material)');
  for (final f in c.read(fittingsProvider)) {
    _p('| ${f.service.name} | ${f.type.name} | ${f.diameterMm} | ${f.count} | '
        '${f.material} |');
  }
  _p('## APP component takeoff');
  for (final l in c.read(componentTakeoffProvider)) {
    _p('${l.service.name} ${l.component.name} ${l.sizeLabel} x${l.count} '
        'assumed=${l.assumed} equipment=${l.equipment}');
  }
}

void _dumpIssues(ProviderContainer c) {
  final issues = c.read(designIssuesProvider);
  _p('## APP design issues (${issues.length}; '
      '${issues.where((i) => i.isVerify).length} are // VERIFY)');
  final verifyBySeverity = <String, int>{};
  for (final i in issues) {
    if (i.isVerify) {
      verifyBySeverity.update(i.severity.name, (n) => n + 1,
          ifAbsent: () => 1);
      continue;
    }
    _p('- [${i.severity.name}] ${i.kind} | ${i.title} | ${i.message} | '
        'locate=${i.locate?.sheetId}/${i.locate?.nodeId}/${i.locate?.edgeId}'
        '/${i.locate?.panelId}/${i.locate?.circuitId}');
  }
  _p('verify advisories by severity: $verifyBySeverity');
  _p('## APP verify advisories (kind | title)');
  for (final i in issues.where((i) => i.isVerify)) {
    _p('- ${i.kind} | ${i.title}');
  }
  _p('## APP compliance summary');
  for (final it in c.read(complianceSummaryProvider).items) {
    _p('- ${it.category}: pass=${it.pass} | ${it.detail}');
  }
}

void _dumpElectrical(ProviderContainer c) {
  final project = c.read(electricalSizingProjectProvider);
  final sys = c.read(electricalResultProvider);
  final adv = c.read(electricalAdvancedProvider);
  final fault = effectiveOriginFaultLevel(project, result: sys);
  _p('## APP electrical');
  _p('panels=${project.panels.map((p) => '${p.id}:${p.name}').toList()} '
      'earthing=${project.earthingSystem.name} supplyKind=${project.supplyKind.name} '
      'declared=${project.supplyCapacityVa?.voltAmperes} VA');
  _p('originFault=${_f(fault.amperes, 1)} A basis=${fault.basis.name} '
      'study.originFaultkA=${adv.fault.originFaultkA} '
      'busbarClearing=${effectiveBusbarClearingTimeS(project)} s');
  final model = {
    for (final p in project.panels)
      for (final ci in p.circuits) ci.id: ci,
  };
  for (final pid in sys.order) {
    final p = sys.panels[pid]!;
    final panelModel = project.panels.firstWhere((x) => x.id == pid);
    _p('### panel $pid "${p.name}" system=${p.system.name} '
        'V=${panelModel.voltage.volts} install=${panelModel.installMethod.name} '
        'ins=${panelModel.insulation.name} amb=${panelModel.ambientTempC} '
        'grouping=${panelModel.groupingCount} diversity=${panelModel.diversityFactor}');
    _p('| way | name | kind | 3ph | phase | cos | DF | loadW | connW | Ib | run | '
        'breaker | poles | kA | cable | Iz derated (base, k, Izreq, CLF, rule) | '
        'VD% own/lim | VD% cum | RCD | L m |');
    for (final r in p.circuits) {
      final m = model[r.circuitId];
      final cf = adv.fault.circuits[r.circuitId];
      final poles = r.phase.isThreePhase ? 3 : 1;
      _p('| ${r.circuitId} | ${r.name} | ${r.loadKind.name} | ${r.threePhase} | '
          '${r.phase.name} | ${m?.cosPhi} | ${m?.demandFactor} | ${r.loadW} | '
          '${r.connectedW} | ${r.designCurrent.amperes} '
          '(exact ${r.designCurrentExactA}) | ${r.runCurrentA.amperes} | '
          '${r.breaker.deviceClass.code} ${r.breaker.ratingA.amperes}A '
          '${r.breaker.curve.name.toUpperCase()} | ${poles}P | '
          '${cf?.breakerKa} (fault ${cf?.faultkA}, Zs ${_f(cf?.zsOhm, 4)}/${_f(cf?.zsMaxOhm, 4)}, '
          'ADS ${cf?.adsOk}${cf?.adsByRcd == true ? ' by RCD' : ''}) | '
          '${r.grounding.cableType} ${r.grounding.cableSpec} '
          '(${r.cable.csaMm2} mm2, PE ${r.grounding.peCsaMm2}, N ${r.grounding.neutralCsaMm2}, '
          'cores ${r.grounding.cores}) | '
          '${r.cable.deratedIz.amperes} (${r.cable.baseKha.amperes}, '
          '${r.cable.deratingFactor}, ${r.cable.izRequired?.amperes}, '
          '${r.cable.continuousLoadFactor}, ${r.cable.appliedRule}, vdDriven ${r.cable.vdDriven}) | '
          '${_f(r.voltageDrop.dropPercent)} (${_f(r.voltageDrop.dropV)} V) / '
          '${r.voltageDrop.limitPercent} | ${_f(r.cumulativeDropPercent)} | '
          '${r.rcd.required ? '${r.rcd.ratingMa} mA ${r.rcd.type?.name} (${r.rcd.reason})' : 'none (${r.rcd.reason})'} | '
          '${r.lengthM} |');
    }
    final inc = p.incomer;
    _p('connectedW=${p.connectedW} demandW=${p.demandW} demandVa=${p.demandVa} '
        'demandCurrent=${p.demandCurrent.amperes} futureLoadW=${p.futureLoadW} '
        'largestDownstreamRunA=${p.largestDownstreamRunA}');
    _p('incomer=${inc.breaker.deviceClass.code} ${inc.breaker.ratingA.amperes}A '
        '${inc.breaker.curve.name.toUpperCase()} ${inc.poles}P '
        'sizingCurrent=${inc.sizingCurrent?.amperes} overRange=${inc.overRange}');
    final b = p.busbar;
    _p('busbar=${b.widthMm}x${b.thicknessMm} (${b.csaMm2} mm2, x${b.parallelBars}) '
        'ampacity=${b.ampacityA.amperes} A total=${b.totalCurrentA.amperes} A '
        'reason=${b.sizingReason.name} withstand=${b.withstand == null ? null : '${b.withstand!.faultKa} kA/${b.withstand!.durationS} s Icw ${b.withstand!.icwKa} adequate ${b.withstand!.adequate}'}');
    final np = p.neutralPeBars;
    _p('N/PE bars: N ${np.neutralCsaMm2} mm2 (${np.neutralAmpacityA.amperes} A) '
        'PE ${np.peCsaMm2} mm2 oversize=${np.neutralOversizeFactor}');
    final pf = adv.fault.panels[pid];
    _p('busFault=${pf?.prospectiveFaultkA} kA incomerKa=${pf?.incomerKa} '
        'adequate=${pf?.incomerAdequate}');
    _p('phaseBalance l1=${p.phaseBalance.l1} l2=${p.phaseBalance.l2} '
        'l3=${p.phaseBalance.l3}');
  }
  final e = sys.earthing;
  _p('earthing=${e.system.name} "${e.label}" requiresRcd=${e.requiresRcd} '
      'mainEarthingConductor=${e.mainEarthingConductorMm2} mm2 '
      'bonding=${e.mainBondingConductorMm2} mm2 '
      'electrodeTarget=${e.electrodeResistanceTarget.ohms} ohm | ${e.note}');
  _p('supply: connectedW=${sys.supply.connectedW} demandW=${sys.supply.demandW} '
      'demandVa=${sys.supply.demandVa.voltAmperes} system=${sys.supply.system.name} '
      'V=${sys.supply.voltage.volts}');
  final s = adv.supply;
  _p('supplyDesign: level=${s.lvOrMv.name} demandKva=${s.demandKva} '
      'declared=${s.declared} declaredBelowDemand=${s.declaredBelowDemand} '
      'tx=${s.transformerKva} | ${s.note}');
  _p('recommendedDaya=${adv.recommendedDayaVa} VA '
      'threePhase=${adv.recommendedDayaThreePhase}');
  _p('fault verify items: ${adv.fault.verifyItems}');
  _p('## APP electrical warnings (electricalAllWarningsProvider)');
  for (final w in c.read(electricalAllWarningsProvider)) {
    _p('- [${w.severity.name}] ${w.code} (${w.panelId}/${w.circuitId}): '
        '${w.message}');
  }
}

void main() {
  test('reference house loads through the store intents and every provider '
      'evaluates', () async {
    final house = buildHouse();
    final c = await _loadHouse(house);
    addTearDown(c.dispose);

    // Loaded as built.
    final project = c.read(projectControllerProvider);
    expect(project.floors.length, 2);
    expect(project.calibrations.length, 2);
    expect(c.read(feedStrategyProvider), FeedStrategy.downfeed);
    expect(c.read(sizingNetworkProvider).edges.length,
        house.network.edges.length);
    expect(c.read(electricalProjectProvider).panels.map((p) => p.id),
        contains(kHousePanelId));

    // Every provider evaluates.
    final sizing = c.read(sizingProvider);
    for (final e in house.network.edges) {
      expect(sizing[e.id], isNotNull, reason: e.id);
    }
    expect(c.read(gravityDownfeedDrawnProvider), isTrue);
    expect(c.read(downfeedProvider), isNotNull);
    expect(c.read(downfeedDeliveredProvider), isNotNull);
    c.read(pumpDutyProvider);
    c.read(zonesProvider);
    expect(c.read(bomProvider), isNotEmpty);
    expect(c.read(fittingsProvider), isNotEmpty);
    c.read(designIssuesProvider);
    c.read(complianceSummaryProvider);
    final sys = c.read(electricalResultProvider);
    expect(sys.panels[kHousePanelId]!.circuits.length, 9);
    c.read(electricalAdvancedProvider);
    c.read(electricalAllWarningsProvider);

    if (_dump) {
      _dumpMechanical(c, house);
      _dumpIssues(c);
      _dumpElectrical(c);
      // ignore: avoid_print
      print(_out.toString());
    }
  });


  // ══ Hand-derived values the APP owns (reference review 2026-11-13) ════════
  // The engine-level pins live in packages/mechx_engine/test/
  // reference_house_test.dart; these assert the same verdicts through the
  // providers every printed surface reads.
  group('hand values (app)', () {
    late ProviderContainer c;
    setUp(() async {
      c = await _loadHouse(buildHouse());
      addTearDown(c.dispose);
    });

    test('downfeed verdict: critical WC1 at (2.4 − 0.1771 − 0.5807 − 0.1393) '
        '× 9.81 = 14.74 kPa, booster 225/9.81 − 1.503 = 21.43 m, no pump duty',
        () {
      final d = c.read(downfeedDeliveredProvider)!;
      expect(d.criticalNodeId, 'WC1');
      expect(d.minResidual.inKiloPascals, closeTo(14.74, 0.05));
      expect(d.boosterHeadRequired.meters, closeTo(21.43, 0.005));
      // No pump / booster is drawn ⇒ no duty is derived.
      expect(c.read(pumpDutyProvider), isNull);
      // Faucet floor 0.5 kgf/cm² = 49.03 kPa (no flush valve on any path).
      expect(c.read(downfeedSniMinimumResidualProvider)!.inKiloPascals,
          closeTo(49.03, 0.05));
    });

    test('issues: the downfeed WARNING, the service-capacity warning, 5 laid-'
        'steeper + 1 trap-arm (KS0 2.0 m > 1.8 m) + 1 cleanout advisory, and '
        '5 // VERIFY', () {
      final issues = c.read(designIssuesProvider);
      final open = [for (final i in issues) if (!i.isVerify) i];
      final kinds = [for (final i in open) i.kind]..sort();
      expect(kinds, [
        'downfeed-below-target',
        'drainage-cleanout',
        'drainage-laid-steeper', 'drainage-laid-steeper',
        'drainage-laid-steeper', 'drainage-laid-steeper',
        'drainage-laid-steeper',
        'drainage-length',
        'electrical:service-capacity-below-demand',
      ]);
      // Every delivery node is below its SNI floor ⇒ a WARNING, not info.
      expect(open.firstWhere((i) => i.kind == 'downfeed-below-target').severity,
          IssueSeverity.warning);
      // The laid-steeper runs are exactly the DN40 / DN50 runs (<= DN65 lay
      // at 1:50, the project fall is 1:100).
      expect(
          {
            for (final i in open)
              if (i.kind == 'drainage-laid-steeper') i.locate!.edgeId,
          },
          {
            'e_dr_LAV1_D1', 'e_dr_SH1_D1', 'e_dr_LAV0_D0', 'e_dr_SH0_D0',
            'e_dr_KS0_D0', //
          });
      expect(open.firstWhere((i) => i.kind == 'drainage-length').locate!.edgeId,
          'e_dr_KS0_D0');
      expect(
          open.firstWhere((i) => i.kind == 'drainage-cleanout').locate!.nodeId,
          'D0');
      expect(issues.where((i) => i.isVerify).length, 5);
    });

    test('compliance rows', () {
      final rows = {
        for (final it in c.read(complianceSummaryProvider).items)
          it.category: it.pass,
      };
      expect(rows['Velocity'], isTrue);
      expect(rows['Sheet calibration'], isTrue);
      expect(rows['Supply pressure'], isFalse);
      expect(rows['Electrical circuit sizing'], isFalse);
    });

    test('BOM metres (§10 lengths summed per service / kind / DN)', () {
      final m = <String, double>{
        for (final b in c.read(bomProvider))
          '${b.service.name}/${b.kind.name}/${b.diameterMm}':
              b.totalLength.meters,
      };
      final expected = {
        // CW DN15 runs: L2 3.0 + 3.1 + 3.6 + 4.1, L1 3.1 + 3.6 + 4.1 + 3.0
        // + 3.1 + 7.1 = 37.8.
        'coldWater/run/15': 37.8,
        'coldWater/run/20': 4.0, // A0→B0
        'coldWater/run/25': 2.3, // RT→A1 2.0 + 0.3 leg
        'coldWater/riser/20': 3.5, // 6.7 − 3.2
        'drainage/run/40': 5.0, // LAV1 1.5 + LAV0 1.5 + KS0 2.0
        'drainage/run/50': 3.0, // SH1 + SH0
        'drainage/run/75': 9.0, // WC1 + WC0 + D0→OUT 6.0
        'drainage/riser/75': 3.2,
        'rainwater/run/100': 8.8, // 4.8 + 4.0
        'rainwater/riser/100': 3.2,
        'vent/riser/50': 3.8, // M1: 7.0 − 3.2; F3: 16 DFU at the stack base ⇒ DN50
      };
      expect(m.keys.toSet(), expected.keys.toSet());
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(m[key], closeTo(value, 1e-6), reason: key);
      }
    });

    test('electrical: one warning, incomer 40 A 2P 6 kA, daya 7700 VA 1φ, '
        'plain 1φ supply note (M2)', () {
      final w = c.read(electricalAllWarningsProvider);
      expect([for (final x in w) x.code], ['service-capacity-below-demand']);
      final p = c.read(electricalResultProvider).panels[kHousePanelId]!;
      expect(p.incomer.breaker.ratingA.amperes, 40);
      expect(p.incomer.poles, 2);
      final adv = c.read(electricalAdvancedProvider);
      expect(adv.fault.panels[kHousePanelId]!.incomerKa, 6.0);
      expect(adv.recommendedDayaVa, 7700);
      expect(adv.recommendedDayaThreePhase, isFalse);
      expect(adv.supply.note, isNot(contains('worst-phase')));
    });
  });
}
