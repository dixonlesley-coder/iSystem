// Reference building 2 (shophouse row) — APP-level smoke test.
//
// Loads the fixed three-unit shophouse row
// (`packages/mechx_engine/test/reference/shophouse.dart`) into a
// ProviderContainer through the real store intents (sheets, floors,
// calibrations, feed strategy, occupancy, the network, unit A's room drawn
// with `roomAreasProvider` and the electrical project) and evaluates the
// providers every printed surface reads: sizing, the downfeed solve (gravity
// and delivered with the movers running), the supply-mover duties (transfer
// pump + booster), BOM + fittings, the room cooling load, the MEP-equipment
// electrical sync, the Review fan-in, the compliance roll-up and the
// electrical result / advanced study / warnings. No way is added by hand
// for the transfer pump, booster or AC: whatever the real MEP sync creates is
// dumped. It asserts only that the project loads and the providers evaluate;
// hand-derived expected values are a later task. Set REF_DUMP=1 to print
// every solved figure (the source of the reference report).
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/store/tank_fill_store.dart';
import 'package:mechx_engine/electrical/advanced_study.dart'
    show originPanelIdsOf, rootServiceBasisVa, servicePerPhaseBasisVa;
import 'package:mechx_engine/electrical/load_kind.dart' show LoadKind;
import 'package:mechx_engine/electrical/load_list.dart'
    show MepLoadSource, MepLoadSourceInfo;
import 'package:mechx_engine/electrical/model.dart' show ElectricalSystem;
import 'package:mechx_engine/electrical/panel_results.dart' show PhaseAssignmentInfo;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart'
    show serviceComponentRoots;
import 'package:mechx_engine/standards/puil.dart' show BreakerClassCode;
import 'package:mechx_engine/units.dart';

import 'reference_board_floors.dart';
import 'reference_copper.dart';
import '../packages/mechx_engine/test/reference/shophouse.dart';

final bool _dump = Platform.environment['REF_DUMP'] == '1';
final StringBuffer _out = StringBuffer();
void _p(String s) => _out.writeln(s);

String _f(double? v, [int dp = 3]) => v == null ? '-' : v.toStringAsFixed(dp);

Future<ProviderContainer> _loadShophouse(ReferenceBuilding shop) async {
  final c = ProviderContainer();
  c.read(sheetsControllerProvider.notifier).loadSheets(
    [
      for (final s in shop.sheets)
        Sheet(id: s.id, name: s.name, sizePx: const Size(1684, 1190)),
    ],
    sheetFloors: {for (final s in shop.sheets) s.id: s.floorIndex},
  );
  final project = c.read(projectControllerProvider.notifier)
    ..setFloors(shop.building.floors);
  for (final MapEntry(:key, :value) in shop.calibrations.entries) {
    project.setCalibration(key, value);
  }
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(occupancyProvider.notifier).set(shop.occupancy);
  c.read(populationProvider.notifier).set(shop.population);
  c.read(networkControllerProvider.notifier).loadNetwork(shop.network);
  // Unit A's shop: drawn through the Room tool's intent (default ceiling =
  // the controller's seed), then typed and named as in the Rooms inspector.
  final rooms = c.read(roomAreasProvider.notifier);
  for (final r in kShophouseRooms) {
    final id = rooms.add(
      sheetId: r.sheetId,
      floorIndex: r.floorIndex,
      ax: r.ax,
      ay: r.ay,
      bx: r.bx,
      by: r.by,
    )!;
    rooms
      ..setRoomType(id, r.roomType)
      ..setName(id, r.name);
  }
  c.read(electricalProjectProvider.notifier).setProject(shop.electrical);
  // Let the electrical store's deferred MEP-equipment sync run.
  await Future<void>.delayed(Duration.zero);
  // Drawing backlog C-2 — every board on its own floor (riser).
  setReferenceBoardFloors(c);
  return c;
}

void _dumpMechanical(ProviderContainer c) {
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

/// [id] with its unit suffix stripped (`e_cw_WM_A_GT_A` → `e_cw_WM_GT`).
String _unsuffixed(String id) => id.replaceAll(RegExp(r'_[ABC](?=_|$)'), '');

void _dumpMovers(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final sizing = c.read(sizingProvider);
  final project = c.read(projectControllerProvider);
  final duties = c.read(supplyMoverDutiesProvider);
  final transfers = c.read(transferPumpNodeIdsProvider);
  final bind = c.read(mepDutyBindingProvider);
  final heads = c.read(downfeedMoverHeadsProvider);
  final nodeDuties = c.read(equipmentNodeDutiesProvider);
  final fed = c.read(nodeFedLoadsProvider);
  final placed = {
    for (final l in c.read(placedEquipmentLoadsProvider)) l.id: l,
  };
  final roots = serviceComponentRoots(net, kSupplyService, demandNodeIds: {
    for (final n in net.nodes)
      if (n.role == NodeRole.fixture) n.id,
  });
  _p('## APP supply sources');
  _p('sizer roots (cold water): '
      '${{for (final r in roots.values) r}.toList()..sort()}');
  _p('downfeed tank (main solve) critical/source: '
      'gravityDownfeedDrawn=${c.read(gravityDownfeedDrawnProvider)} '
      'tankElevation=${_f(c.read(downfeedTankElevationProvider)?.meters)}');
  _p('extraSupplySources=${[
    for (final x in c.read(extraSupplySourcesProvider))
      '${x.source} (${x.nodes.length} nodes)'
  ]}');
  _p('## APP supply movers (supplyMovers: node | inEdge | flow | served | transfer)');
  for (final m in supplyMovers(net, sizing,
      excludeEdgeIds: c.read(parallelLegEdgeIdsProvider),
      rootFlowOf: (_) => const FlowRate(0))) {
    _p('${m.nodeId} | in=${m.inEdgeId} | Q=${_f(m.flow.inLitersPerSecond, 4)} '
        'L/s | served=${(m.served.toList()..sort()).length} nodes '
        '(tanks: ${[
      for (final n in m.served)
        if (net.nodeById(n)?.component == NodeComponent.roofTank ||
            net.nodeById(n)?.component == NodeComponent.groundTank)
          n
    ]..sort()}) | transfer=${m.transfer}');
  }
  _p('## APP mover duties (node | role | Q L/s | H m | lift m | friction m | '
      'hydraulic W | shaft W | motor input W | motor kW | oversized | '
      'delivered head m | node duty motor/input | fed W (source) | MEP load)');
  final ids = {...duties.keys, ...placed.keys.map((k) => k.substring(5))}
      .where((id) {
    final comp = net.nodeById(id)?.component;
    return comp == NodeComponent.pump || comp == NodeComponent.boosterSet;
  }).toList()
    ..sort();
  for (final id in ids) {
    final d = duties[id];
    final n = net.nodeById(id)!;
    final role = bind.firePumpNodeIds.contains(id)
        ? 'fire'
        : transfers.contains(id)
            ? 'transfer'
            : bind.standbyPumpNodeIds.contains(id)
                ? 'standby'
                : id == bind.supplyPumpNodeId
                    ? 'duty (primary supply)'
                    : 'booster (series)';
    String lift = '-', friction = '-';
    if (d != null && transfers.contains(id)) {
      // The transfer lift = tank elevation − source (ground-tank) elevation;
      // friction = the rest of the duty head.
      final unit = id.substring(id.lastIndexOf('_') + 1);
      final rt = net.nodeById(shopId('RT', unit));
      final gt = net.nodeById(shopId('GT', unit));
      if (rt != null && gt != null) {
        final l = nodeElevation(rt, project.building, project.mounting).meters -
            nodeElevation(gt, project.building, project.mounting).meters;
        lift = _f(l);
        friction = _f(d.head.meters - l);
      }
    }
    final mep = placed['node-$id'];
    _p('| $id | ${n.component?.name} | $role | '
        '${_f(d?.flow.inLitersPerSecond, 4)} | ${_f(d?.head.meters)} | '
        '$lift | $friction | ${_f(d?.hydraulicPower.watts, 1)} | '
        '${_f(d?.shaftPower.watts, 1)} | ${_f(d?.motorInputPower.watts, 1)} | '
        '${_f(d?.selectedMotor.inKiloWatts, 2)} | ${d?.motorOversized} | '
        '${_f(heads[id]?.meters)} | '
        '${_f(nodeDuties[id]?.motor.watts, 1)}/${_f(nodeDuties[id]?.input.watts, 1)} | '
        '${_f(fed[id]?.watts, 1)} (${fed[id]?.source.name}) | '
        '${mep == null ? '-' : '${mep.name} mech=${_f(mep.mechanicalPower.watts, 1)} '
            'input=${_f(mep.electricalInputPower?.watts, 1)} phases=${mep.phases} '
            'cos=${mep.cosPhi} eff=${mep.motorEfficiency} source=${mep.source.name}'} |');
  }
  final pump = c.read(pumpDutyProvider);
  _p('pumpDuty(primary)=${pump == null ? 'null' : 'Q=${_f(pump.flow.inLitersPerSecond, 4)} '
      'H=${_f(pump.head.meters)} motor=${_f(pump.selectedMotor.inKiloWatts, 2)} kW'} '
      'primaryNode=${c.read(primarySupplyPumpNodeProvider)} '
      'supplyBooster=${c.read(supplyBoosterProvider)} '
      'binding.supplyPump=${bind.supplyPumpNodeId}');

  _p('## APP delivered pressure: gravity-only (downfeedProvider) vs booster '
      'running (downfeedDeliveredProvider), every node');
  final down = c.read(downfeedProvider);
  final del = c.read(downfeedDeliveredProvider);
  final floors = c.read(downfeedSniFloorsProvider);
  final allIds = {...?down?.residualPressure.keys, ...?del?.residualPressure.keys}
      .toList()
    ..sort();
  _p('| node | delivery | gravity static | gravity residual | delivered static '
      '| delivered residual | SNI floor |');
  for (final id in allIds) {
    _p('| $id | ${del?.deliveryNodeIds.contains(id)} | '
        '${_f(down?.noFlowStaticPressure[id]?.inKiloPascals)} | '
        '${_f(down?.residualPressure[id]?.inKiloPascals)} | '
        '${_f(del?.noFlowStaticPressure[id]?.inKiloPascals)} | '
        '${_f(del?.residualPressure[id]?.inKiloPascals)} | '
        '${_f(floors[id]?.inKiloPascals)} |');
  }
  _p('gravity: critical=${down?.criticalNodeId} '
      'min=${_f(down?.minResidual.inKiloPascals)} '
      'boosterHeadRequired=${_f(down?.boosterHeadRequired.meters)} '
      'gravitySufficient=${down?.gravitySufficient}');
  _p('delivered: critical=${del?.criticalNodeId} '
      'min=${_f(del?.minResidual.inKiloPascals)} '
      'gravitySufficient=${del?.gravitySufficient}');
}

void _dumpRooms(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final project = c.read(projectControllerProvider);
  final rooms = c.read(roomAreasProvider);
  _p('## APP rooms + cooling (method=${c.read(coolingLoadMethodProvider).name})');
  for (final r in rooms) {
    final mpp = project.calibrationFor(r.sheetId)?.metersPerPixel;
    final load = c.read(roomCoolingLoadProvider(r.id));
    _p('${r.id} "${r.name}" type=${r.roomType.name} sheet=${r.sheetId} '
        'floor=${r.floorIndex} ${_f(r.widthPx * mpp!)} x '
        '${_f(r.heightPx * mpp)} m area=${_f(r.areaM2(mpp))} '
        'net=${_f(r.netAreaM2(mpp, rooms))} m2 ceiling=${r.ceilingHeightM} m');
    if (load != null) {
      _p('  load=${_f(load.btuPerHr, 1)} BTU/h (${_f(load.watts, 1)} W) '
          'pk=${_f(load.pk)} recommended=${load.recommended.pk} PK '
          '(${load.recommended.nominalBtuPerHr} BTU/h) '
          'exceedsRange=${load.recommended.exceedsRange}');
    }
  }
  final fed = c.read(nodeFedLoadsProvider);
  for (final n in net.nodes) {
    if (!RoomArea.isAcComponent(n.component)) continue;
    final share = acUnitShare(net, rooms,
        (s) => project.calibrationFor(s)?.metersPerPixel, n,
        method: c.read(coolingLoadMethodProvider));
    _p('AC ${n.id} ${n.component!.name}: room=${share?.room.id} '
        'perUnit=${_f(share?.btuPerHr, 1)} BTU/h unit=${share?.unit.pk} PK '
        '(${share?.unit.nominalBtuPerHr} BTU/h, exceedsRange=${share?.unit.exceedsRange}) '
        'inputW=${_f(share?.inputW, 1)} | fed=${_f(fed[n.id]?.watts, 1)} W '
        'input=${_f(fed[n.id]?.input, 1)} (${fed[n.id]?.source.name})');
  }
}

void _dumpMepSync(ProviderContainer c) {
  final project = c.read(electricalProjectProvider);
  _p('## APP electrical project after the MEP sync');
  for (final p in project.panels) {
    _p('panel ${p.id} "${p.name}" tag=${p.tag} system=${p.system.name} '
        'V=${p.voltage.volts} source=${p.sourceType.name} '
        'fedBy=${p.fedByCircuitId} ways=${p.circuits.length}');
    for (final w in p.circuits) {
      if (w.sourceEquipmentId == null && w.feedsPanelId == null) continue;
      _p('  ${w.id} "${w.name}" kind=${w.loadKind.name} loadW=${w.loadW} '
          'motorKw=${w.motorKw} phases=${w.phases} cos=${w.cosPhi} '
          'DF=${w.demandFactor} lifeSafety=${w.lifeSafety} '
          'source=${w.sourceEquipmentId} feeds=${w.feedsPanelId} '
          'L=${w.length.meters}');
    }
  }
  _p('mepDutyFeedEnabled=${c.read(mepDutyFeedEnabledProvider)}');
}

/// The multi-root service basis: each origin board's per-root basis VA
/// (`rootServiceBasisVa`, a 1-phase root at sqrt3 x 400 x I on one line) and
/// the per-phase basis of the whole service (`servicePerPhaseBasisVa`, the
/// LPT line allocation x 3).
void _dumpServiceLines(ProviderContainer c) {
  final project = c.read(electricalSizingProjectProvider);
  final sys = c.read(electricalResultProvider);
  final roots = originPanelIdsOf(sys, project).toList()..sort();
  _p('## APP service roots + per-line basis');
  for (final id in roots) {
    final va = rootServiceBasisVa(project, sys, id);
    _p('root $id basisVa=${_f(va, 1)} lineA=${_f(va / (1.7320508075688772 * 400), 2)}');
  }
  _p('servicePerPhaseBasisVa=${_f(servicePerPhaseBasisVa(project, sys, roots), 1)} '
      '(= 3 x heaviest line)');
}

/// Unit B / C vs A: every suffixed id compared on its unsuffixed key.
List<String> _unitDiffs(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final sizing = c.read(sizingProvider);
  final fu = c.read(edgeFixtureUnitsProvider);
  final down = c.read(downfeedProvider);
  final del = c.read(downfeedDeliveredProvider);
  final duties = c.read(supplyMoverDutiesProvider);
  final sys = c.read(electricalResultProvider);
  final out = <String>[];
  String? unitOf(String id) {
    final m = RegExp(r'_([ABC])$').firstMatch(id);
    return m?.group(1);
  }

  void compare(String what, Map<String, String> byId) {
    final byKey = <String, Map<String, String>>{};
    for (final e in byId.entries) {
      final u = unitOf(e.key);
      if (u == null) continue;
      (byKey[_unsuffixed(e.key)] ??= {})[u] = e.value;
    }
    for (final e in byKey.entries) {
      final a = e.value['A'];
      for (final u in ['B', 'C']) {
        if (e.value[u] != a) {
          out.add('$what ${e.key}: $u=${e.value[u]} vs A=$a');
        }
      }
    }
  }

  compare('sizing', {
    for (final e in net.edges)
      e.id: 'FU=${fu[e.id]} Q=${_f(sizing[e.id]?.flow.inLitersPerSecond, 6)} '
          'DN=${sizing[e.id]?.diameter.inMillimeters}',
  });
  compare('gravity', {
    for (final e in (down?.residualPressure ?? const {}).entries)
      e.key: '${_f(e.value.inKiloPascals)} / '
          '${_f(down!.noFlowStaticPressure[e.key]?.inKiloPascals)}',
  });
  compare('delivered', {
    for (final e in (del?.residualPressure ?? const {}).entries)
      e.key: '${_f(e.value.inKiloPascals)} / '
          '${_f(del!.noFlowStaticPressure[e.key]?.inKiloPascals)}',
  });
  compare('duty', {
    for (final e in duties.entries)
      e.key: 'Q=${_f(e.value.flow.inLitersPerSecond, 6)} '
          'H=${_f(e.value.head.meters)} '
          'motor=${e.value.selectedMotor.watts}',
  });
  compare('panel', {
    for (final u in kShopUnits)
      if (sys.panels[shopPanelId(u)] case final p?)
        shopPanelId(u): 'demandW=${p.demandW} VA=${p.demandVa} '
            'I=${p.demandCurrent.amperes} incomer=${p.incomer.breaker.ratingA.amperes}',
  });
  compare('way', {
    for (final u in kShopUnits)
      if (sys.panels[shopPanelId(u)] case final p?)
        for (final r in p.circuits)
          r.circuitId: 'Ib=${r.designCurrent.amperes} run=${r.runCurrentA.amperes} '
              'MCB=${r.breaker.ratingA.amperes} cable=${r.cable.csaMm2} '
              'vd=${_f(r.voltageDrop.dropPercent)} phase=${r.phase.name}',
  });
  out.sort();
  return out;
}

void main() {
  test('reference shophouse row loads through the store intents and every '
      'provider evaluates', () async {
    final shop = buildShophouse();
    final c = await _loadShophouse(shop);
    addTearDown(c.dispose);

    // Loaded as built.
    final project = c.read(projectControllerProvider);
    expect(project.floors.length, 3);
    expect(project.calibrations.length, 3);
    expect(c.read(feedStrategyProvider), FeedStrategy.downfeed);
    expect(c.read(sizingNetworkProvider).edges.length,
        shop.network.edges.length);
    expect(c.read(roomAreasProvider).length, 1);
    expect(c.read(electricalProjectProvider).panels.map((p) => p.id),
        containsAll(
            [kShopMainPanelId, for (final u in kShopUnits) shopPanelId(u)]));

    // Every provider evaluates.
    final sizing = c.read(sizingProvider);
    for (final e in shop.network.edges) {
      expect(sizing[e.id], isNotNull, reason: e.id);
    }
    expect(c.read(gravityDownfeedDrawnProvider), isTrue);
    expect(c.read(downfeedProvider), isNotNull);
    expect(c.read(downfeedDeliveredProvider), isNotNull);
    c.read(supplyMoverDutiesProvider);
    c.read(pumpDutyProvider);
    c.read(zonesProvider);
    expect(c.read(bomProvider), isNotEmpty);
    expect(c.read(fittingsProvider), isNotEmpty);
    expect(c.read(roomCoolingLoadProvider(c.read(roomAreasProvider).single.id)),
        isNotNull);
    c.read(designIssuesProvider);
    c.read(complianceSummaryProvider);
    final sys = c.read(electricalResultProvider);
    for (final u in kShopUnits) {
      expect(sys.panels[shopPanelId(u)], isNotNull, reason: u);
    }
    c.read(electricalAdvancedProvider);
    c.read(electricalAllWarningsProvider);

    if (_dump) {
      _dumpMechanical(c);
      _dumpMovers(c);
      _dumpRooms(c);
      _dumpIssues(c);
      _dumpMepSync(c);
      _dumpElectrical(c);
      _dumpServiceLines(c);
      final diffs = _unitDiffs(c);
      _p('## APP unit B / C vs A differences (${diffs.length})');
      for (final d in diffs) {
        _p('- $d');
      }
      // ignore: avoid_print
      print(_out.toString());
    }
  });

  // ── Hand-derived pins (reviewer pass 2, 2026-11-13) ─────────────────────
  group('hand values (app providers)', () {
    late ProviderContainer c;
    setUpAll(() async {
      c = await _loadShophouse(buildShophouse());
    });
    tearDownAll(() => c.dispose());

    test('delivered field = gravity + the booster\'s 22.114 m (216.936 kPa) '
        'at every delivery node, every unit', () {
      final down = c.read(downfeedProvider)!;
      final del = c.read(downfeedDeliveredProvider)!;
      // 22.114 m × 9.81 = 216.936 kPa: WC2 8.064 + 216.936 = 225.000 …
      // WC0 72.136 + 216.936 = 289.072.
      const delivered = {
        'WC2': 225.000, 'LAV2': 226.256, 'WC1': 259.582, 'LAV1': 260.838,
        'WC0': 289.072, 'LAV0': 290.328, 'KS0': 288.735, //
      };
      for (final u in kShopUnits) {
        for (final MapEntry(key: f, value: kpa) in delivered.entries) {
          final id = shopId(f, u);
          expect(del.residualPressure[id]!.inKiloPascals, closeTo(kpa, 2e-3),
              reason: id);
          expect(
              del.residualPressure[id]!.inKiloPascals -
                  down.residualPressure[id]!.inKiloPascals,
              closeTo(216.936, 2e-3),
              reason: id);
        }
        // Ground-floor delivered static 106.929 + 216.936 = 323.865 kPa.
        expect(del.noFlowStaticPressure[shopId('WC0', u)]!.inKiloPascals,
            closeTo(323.865, 2e-3));
      }
      expect(del.criticalNodeId, shopId('WC2', 'A'));
      expect(c.read(downfeedOverPressureProvider), isEmpty);
    });

    test('one zone per tank (0-2), bottom static 323.87 < 392.266 kPa, no '
        'PRV', () {
      final zones = c.read(zonesProvider);
      expect(zones.length, 3);
      for (final z in zones) {
        expect((z.bottomFloorIndex, z.topFloorIndex), (0, 2));
      }
      for (final z in c.read(zoneStaticsProvider)) {
        expect(z.bottomStatic.inKiloPascals, closeTo(323.865, 2e-3));
        expect(z.withinLimit, isTrue);
        expect(z.viaPrv, isFalse);
      }
    });

    test('transfer pump and booster duties, every unit', () {
      final duties = c.read(supplyMoverDutiesProvider);
      final transfers = c.read(transferPumpNodeIdsProvider);
      final fed = c.read(nodeFedLoadsProvider);
      final project = c.read(projectControllerProvider);
      final net = c.read(sizingNetworkProvider);
      double z(String id) => nodeElevation(
              net.nodeById(id)!, project.building, project.mounting)
          .meters;
      for (final u in kShopUnits) {
        // Backlog W-5 (2026-11-14) — RT has no capacity entered, so it is
        // AUTO-sized: the daily demand 15 persons x 120 L = 1800 L/day; the
        // three roof tanks (each fed from its unit's GT: the roof fraction)
        // serve 12.5 UBAP each of 37.5 ⇒ share 1/3 ⇒ 600 L x 0.20 = 120 L ⇒
        // the 250 L standard size. Fill 250 / 3600 = 0.069444 L/s (was the
        // 12.5-UBAP peak 0.56389), DN15 (v 0.393). TP: lift RT 12.0 − GT 0.0
        // = 12.000 + friction 0.015133 m/m (DN15 at 0.069444, C150) × (1.0 +
        // 4.7 + 4.0 + 4.0 + 2.3 = 16.0) = 0.242 + the float-valve inlet
        // residual 5.0 ⇒ H = 17.242 m (was 19.884). P_h = 9810 × 0.069444e-3
        // × 17.242 = 11.7 W (was 110.0); shaft / 0.70 = 16.8 W ⇒ 0.37 kW
        // (the smallest frame, unchanged); fed input 370 / 0.90 = 411.1 W.
        final tp = duties[shopId('TP', u)]!;
        expect(transfers, contains(shopId('TP', u)));
        expect(z(shopId('RT', u)) - z(shopId('GT', u)), closeTo(12.0, 1e-9));
        expect(tp.flow.inLitersPerSecond, closeTo(0.069444, 5e-6));
        expect(tp.head.meters, closeTo(17.242, 5e-4));
        expect(tp.hydraulicPower.watts, closeTo(11.7, 0.05));
        expect(tp.shaftPower.watts, closeTo(16.8, 0.05));
        expect(tp.selectedMotor.inKiloWatts, closeTo(0.37, 1e-9));
        expect(fed[shopId('TP', u)]!.input, closeTo(411.1, 0.05));
        // BS: H = (225 − 8.064) / 9.81 = 22.114 m; P_h = 122.3 W, shaft
        // 174.8 W ⇒ 0.37 kW; 411.1 W.
        final bs = duties[shopId('BS', u)]!;
        expect(transfers, isNot(contains(shopId('BS', u))));
        expect(bs.flow.inLitersPerSecond, closeTo(0.5639, 5e-5));
        expect(bs.head.meters, closeTo(22.114, 5e-4));
        expect(bs.hydraulicPower.watts, closeTo(122.3, 0.05));
        expect(bs.shaftPower.watts, closeTo(174.8, 0.05));
        expect(bs.selectedMotor.inKiloWatts, closeTo(0.37, 1e-9));
        expect(fed[shopId('BS', u)]!.input, closeTo(411.1, 0.05));
      }
    });

    test('room: 44 400 BTU/h; two cassettes of 22 200 → 2.5 PK, 2344.6 W '
        'each', () {
      final room = c.read(roomAreasProvider).single;
      expect(room.ceilingHeightM, closeTo(3.7, 1e-9));
      final load = c.read(roomCoolingLoadProvider(room.id))!;
      expect(load.btuPerHr, closeTo(44400, 1e-6));
      expect(load.pk, closeTo(4.933, 5e-4));
      final fed = c.read(nodeFedLoadsProvider);
      for (final id in kShopAcNodeIds) {
        expect(fed[id]!.watts, closeTo(2344.6, 0.05), reason: id);
      }
    });

    test('Review: the deliberate findings are present, the fixed ones absent',
        () {
      final kinds = [for (final i in c.read(designIssuesProvider)) i.kind];
      int count(String k) => kinds.where((x) => x == k).length;
      expect(count('drainage-length'), 3); // KS0 trap arm, one per unit
      expect(count('drainage-laid-steeper'), 12); // 3 LAV + KS0, per unit
      expect(count('drainage-cleanout'), 3); // stack base D0, per unit
      expect(kinds.where((k) => k.startsWith('unfed-panel')), isEmpty);
      expect(kinds.where((k) => k.startsWith('unconnected-orphan')), isEmpty);
      expect(kinds, isNot(contains('electrical:service-capacity-below-demand')));
      expect(kinds, isNot(contains('downfeed-below-target')));
      // Backlog W-5 — no capacity is entered, but the population is: every
      // GT / RT is auto-sized (650 / 250 L), so no `tank-capacity-unset`;
      // every roof tank's fill is drawn (no `roof-tank-fill-undrawn`); each
      // meter: −0.5 + 3.5 m at 0.045139 L/s DN15 (0.02385 m) + 5.0 = 4.524 m
      // <= 10 m (no `mains-pressure-insufficient`, backlog W-2).
      expect(kinds.where((k) => k.startsWith('tank-capacity-unset')), isEmpty);
      expect(kinds.where((k) => k.startsWith('roof-tank-fill-undrawn')),
          isEmpty);
      expect(kinds.where((k) => k.startsWith('mains-pressure-insufficient')),
          isEmpty);
      // Backlog A-4 — two 2.5 PK cassettes = 48 000 >= 44 400 BTU/h.
      expect(kinds.where((k) => k.startsWith('room-cooling-undersized')),
          isEmpty);
    });

    test('MEP board: auto-wired from PP Ruko, 3-phase 400 V; pump and '
        'cassette ways', () {
      final project = c.read(electricalProjectProvider);
      final mep = project.panels.firstWhere((p) => p.id == kMepEquipmentPanelId);
      expect(mep.system, ElectricalSystem.threePhase);
      expect(mep.voltage.volts, 400);
      final feeder = project.panels
          .firstWhere((p) => p.id == kShopMainPanelId)
          .circuits
          .firstWhere((w) => w.feedsPanelId == kMepEquipmentPanelId);
      expect(mep.fedByCircuitId, feeder.id);
      final sys = c.read(electricalResultProvider);
      final adv = c.read(electricalAdvancedProvider);
      final r = sys.panels[kMepEquipmentPanelId]!;
      final lines = <String>{};
      for (final w in r.circuits) {
        if (w.loadKind == LoadKind.pump) {
          // 370 W motor / 0.90 = 411.1 W; 411.1 / (√3 × 400 × 0.85) =
          // 0.698 A, 3P, MCB 6 A D, NYY 4 × 2.5 mm² (no neutral).
          expect(w.loadW, closeTo(411.1, 0.05), reason: w.circuitId);
          expect(w.designCurrentExactA, closeTo(0.698, 5e-4),
              reason: w.circuitId);
          expect(w.threePhase, isTrue, reason: w.circuitId);
          expect(w.breaker.ratingA.amperes, 6, reason: w.circuitId);
          expect(w.breaker.curve.name, 'd', reason: w.circuitId);
          expect(w.cable.csaMm2, 2.5, reason: w.circuitId);
          expect(w.grounding.cores, 4, reason: w.circuitId);
        } else {
          // Cassette 2344.6 W on one line at 231 V: 2344.6 / (231 × 0.85) =
          // 11.94 A ⇒ MCB 16 A C 1P, 3 × 2.5 mm², VD 0.78 %.
          expect(w.loadKind, LoadKind.hvac, reason: w.circuitId);
          expect(w.loadW, closeTo(2344.6, 0.05), reason: w.circuitId);
          expect(w.designCurrentExactA, closeTo(11.94, 5e-3),
              reason: w.circuitId);
          expect(w.threePhase, isFalse, reason: w.circuitId);
          expect(w.breaker.ratingA.amperes, 16, reason: w.circuitId);
          expect(w.breaker.curve.name, 'c', reason: w.circuitId);
          expect(w.cable.csaMm2, 2.5, reason: w.circuitId);
          expect(w.grounding.cores, 3, reason: w.circuitId);
          expect(w.voltageDrop.dropPercent, closeTo(0.78, 1e-9),
              reason: w.circuitId);
          lines.add(w.phase.name);
        }
      }
      expect(r.circuits.where((w) => w.loadKind == LoadKind.pump).length, 6);
      expect(lines.length, 2, reason: 'the two cassettes on different lines');
      // 6 × 411.1 + 2 × 2344.6 = 7156 W; VA 7156 / 0.85 = 8419.
      expect(r.demandW, closeTo(7156, 0.5));
      expect(r.demandVa, closeTo(8419, 0.5));
      // Lines: 6 × 0.698 = 4.19 on each, + 11.94 on two of them.
      final pb = [r.phaseBalance.l1, r.phaseBalance.l2, r.phaseBalance.l3]
        ..sort();
      expect(pb, [4.2, 16.1, 16.1]);
      expect(r.incomer.breaker.ratingA.amperes, 20);
      expect(r.incomer.poles, 4);
      // Backlog B-1: the MEP feeder is 6 mm² (was 4). PP Ruko source R
      // 0.003266 / X 0.022863 Ω + 10 m of 6 mm² cold (3.69 x 0.01 x 254.5 /
      // 304.5 = 0.030841, X 0.0008) ⇒ |Z| 0.041512 ⇒ 400 / (√3 x 0.041512) =
      // 5.56 kA (was 4.22 on 4 mm²).
      expect(adv.fault.panels[kMepEquipmentPanelId]!.prospectiveFaultkA,
          closeTo(5.56, 1e-9));
    });

    test('B-4: the transfer pumps are their own electrical source', () {
      // Backlog B-4 (2026-11-13): TP_A/B/C are classified TRANSFER pumps by
      // the solve (ground tank → roof tank), so their MEP load source is
      // `transferPump` ('Transfer pump' / 'Pompa transfer'), never the
      // generic supply pump; the booster sets stay `boosterPump`. No figure
      // changes: same 370 W motor, 411.1 W input, pump load kind.
      final loads = {
        for (final l in c.read(placedEquipmentLoadsProvider)) l.id: l,
      };
      for (final u in kShopUnits) {
        final tp = loads['node-TP_$u']!;
        expect(tp.source, MepLoadSource.transferPump, reason: u);
        expect(tp.source.label, 'Transfer pump');
        expect(tp.source.labelFor(indonesian: true), 'Pompa transfer');
        expect(tp.source.circuitLoadKind, LoadKind.pump);
        expect(tp.inputPower.watts, closeTo(411.1, 0.05), reason: u);
        expect(loads['node-BS_$u']!.source, MepLoadSource.boosterPump,
            reason: u);
      }
    });

    test('MEP feeder and PP Ruko', () {
      final sys = c.read(electricalResultProvider);
      final adv = c.read(electricalAdvancedProvider);
      final pp = sys.panels[kShopMainPanelId]!;
      final mf = pp.circuits.firstWhere((w) => w.circuitId == kMepEquipmentFeederId);
      // The MEP feeder runs on its worst line 16.1 A: load-sized 20 A; Iz_req
      // max(20, 1.25 × 16.1 = 20.1) ⇒ NYY 5 × 4 mm² (3-phase trunk minimum 4,
      // Iz 28). Backlog B-1: the floor 1.6 × 20 = 32 A needs Iz ≥ 32, so the
      // auto-sized cable grows: 4 mm² 28 ✗, 6 mm² 36 ✓ ⇒ NYY 5 × 6, MCB
      // 32 A C 3P. VD on 10 m at pf 7156 / 8419 = 0.85 (sin 0.5268): √3 ×
      // 16.1 × 10 × (3.69 × 0.85 + 0.08 × 0.5268) / 1000 = 0.886 V = 0.22 %
      // (was 25 A on 5 × 4, 0.33 %).
      expect(mf.designCurrent.amperes, closeTo(16.1, 1e-9));
      expect(mf.threePhase, isTrue);
      expect(mf.cable.csaMm2, 6);
      expect(mf.cable.deratedIz.amperes, 36);
      expect(mf.cableRaisedForSelectivity, isTrue);
      expect(mf.grounding.cores, 5);
      expect(mf.breaker.ratingA.amperes, 32);
      expect(mf.breaker.curve.name, 'c');
      expect(mf.voltageDrop.dropPercent, closeTo(0.22, 1e-9));
      // PP Ruko: 14 040 + 7 156 = 21 196 W; 15 988 + 8 419 = 24 407 VA.
      expect(pp.demandW, closeTo(21196, 0.5));
      expect(pp.demandVa, closeTo(24407, 0.5));
      // Lines 24.2 + 16.1 = 40.3, 24.2 + 16.1 = 40.3, 24.2 + 4.2 = 28.4.
      final pb = [pp.phaseBalance.l1, pp.phaseBalance.l2, pp.phaseBalance.l3]
        ..sort();
      expect(pb, [28.4, 40.3, 40.3]);
      // Incomer on the service floor 33 000 / (√3 × 400) = 47.6 A ⇒ MCB
      // 50 A 4P, 10 kA; busbar 15 × 3 (withstand).
      expect(pp.incomer.sizingCurrent!.amperes, closeTo(47.6, 1e-9));
      expect(pp.incomer.breaker.ratingA.amperes, 50);
      expect(pp.incomer.poles, 4);
      expect(adv.fault.panels[kShopMainPanelId]!.incomerKa, 10.0);
      expect((pp.busbar.widthMm, pp.busbar.thicknessMm), (15.0, 3.0));
      // Per-phase basis √3 × 400 × 40.3 = 27 921 VA > 24 407 ⇒ 33 000 VA
      // 3-phase = the declared daya: no capacity warning.
      expect(adv.recommendedDayaVa, 33000);
      expect(adv.recommendedDayaThreePhase, isTrue);
      final codes = [for (final w in c.read(electricalAllWarningsProvider)) w.code];
      // Backlog B-1: the three unit feeders (10 mm², 40 A) and the MEP feeder
      // (6 mm², 32 A) now reach the 1.6× target on grown cables (was ×4).
      expect(codes.where((x) => x == 'non-selective'), isEmpty);
      expect(codes, isNot(contains('service-capacity-below-demand')));
    });
  });

  // Backlog B-1 / B-2 — the copper of the auto-sized cables, on record in
  // docs/REFERENCE-BUILDINGS.md (REF_DUMP=1 prints it).
  test('(REF_DUMP) auto-sized copper total', () async {
    if (!_dump) return;
    final c = await _loadShophouse(buildShophouse());
    // ignore: avoid_print
    print('COPPER shophouse ${autoSizedCopperMm2M(c).toStringAsFixed(0)} mm2.m');
    c.dispose();
  });

  // Backlog W-4 / W-5 (2026-11-14) — daily demand, auto capacities and the
  // water reserve: 5 persons x 3 units = 15 x 120 L/person/day (private,
  // `// VERIFY`) = 1800 L = 1.80 m3/day. No capacity is entered: each GT
  // (ground role, share 12.5 / 37.5 = 1/3) = 600 L x 1.0 day = 600 → 650 L;
  // each RT (roof role, fed from its GT, share 1/3) = 600 x 0.20 = 120 →
  // 250 L. Stored 3 x 650 + 3 x 250 = 2700 L; reserve 2700 / 1800 = 1.5 days.
  test('backlog W-4/W-5: auto 650 / 250 L tanks, reserve 1.5 days', () async {
    final c = await _loadShophouse(buildShophouse());
    expect(c.read(populationProvider), 15);
    expect(c.read(dailyDemandLitresProvider), closeTo(1800, 1e-9));
    final auto = c.read(autoTankCapacitiesProvider);
    for (final u in kShopUnits) {
      final gt = auto['GT_$u']!;
      expect(gt.roofTarget, isFalse);
      expect(gt.share, closeTo(1 / 3, 1e-12));
      expect(gt.rawLitres, closeTo(600, 1e-9));
      expect(gt.litres, 650);
      final rt = auto['RT_$u']!;
      expect(rt.roofTarget, isTrue);
      expect(rt.share, closeTo(1 / 3, 1e-12));
      expect(rt.rawLitres, closeTo(120, 1e-9));
      expect(rt.litres, 250);
      // Meter feed: 650 / 14 400 = 0.045139 L/s, DN15 v 0.255.
      final wm = c.read(sizingProvider)['e_cw_WM_${u}_GT_$u']!;
      expect(wm.flow.inLitersPerSecond, closeTo(0.045139, 5e-7));
      expect(wm.diameter.inMillimeters, 15);
      expect(wm.velocity.metersPerSecond, closeTo(0.255, 5e-4));
      // Transfer: 250 / 3600 = 0.069444 L/s, DN15 v 0.393.
      final tr = c.read(sizingProvider)['e_cw_U2_${u}_RT_$u']!;
      expect(tr.flow.inLitersPerSecond, closeTo(0.069444, 5e-7));
      expect(tr.diameter.inMillimeters, 15);
      expect(tr.velocity.metersPerSecond, closeTo(0.393, 5e-4));
    }
    final r = c.read(waterReserveProvider);
    expect(r.excludedTankIds, isEmpty);
    expect(r.storedLitres, closeTo(2700, 1e-9));
    expect(r.days, closeTo(1.5, 1e-12));
    final kinds = [for (final i in c.read(designIssuesProvider)) i.kind];
    expect(kinds, isNot(contains('daily-demand-unset')));
    c.dispose();
  });
}
