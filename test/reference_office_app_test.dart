// Reference building 3 (office) — APP-level smoke test.
//
// Loads the fixed 4-storey office
// (`packages/mechx_engine/test/reference/office.dart`) into a
// ProviderContainer through the real store intents (sheets, floors,
// calibrations, UPFEED feed strategy, public occupancy, light fire hazard,
// the network, the Lantai 2 office room drawn with `roomAreasProvider` and
// the electrical project) and evaluates the providers every printed surface
// reads: sizing, the upfeed solve (sizing basis and delivered with the pump
// running), the supply-mover duty, the fire system basis / fire pump / jockey,
// the room air sizing + drawn duct fan, BOM + fittings, the MEP-equipment
// electrical sync, the Review fan-in, the compliance roll-up and the
// electrical result / advanced study / warnings. No way is added by hand for
// P1, FP or FCU1: whatever the real MEP sync creates is dumped. It asserts
// only that the project loads and the providers evaluate; hand-derived
// expected values are a later task. Set REF_DUMP=1 to print every solved
// figure (the source of the reference report).
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/air_warnings_store.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/electrical/advanced_study.dart'
    show originPanelIdsOf, rootServiceBasisVa, servicePerPhaseBasisVa;
import 'package:mechx_engine/electrical/panel_results.dart'
    show PhaseAssignmentInfo;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart'
    show ductFrictionPaPerMetre;
import 'package:mechx_engine/sizing/air_velocity.dart' show VelocityBandVerdict;
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart'
    show sprinklerPumpRatedPoint;
import 'package:mechx_engine/sizing/network_sizing.dart'
    show serviceComponentRoots;
import 'package:mechx_engine/sizing/standpipe_outlet_pressure.dart';
import 'package:mechx_engine/standards/duct_products.dart'
    show ductRoughnessFor;
import 'package:mechx_engine/standards/puil.dart' show BreakerClassCode;
import 'package:mechx_engine/units.dart' show Head;

import '../packages/mechx_engine/test/reference/office.dart';

final bool _dump = Platform.environment['REF_DUMP'] == '1';
final StringBuffer _out = StringBuffer();
void _p(String s) => _out.writeln(s);

String _f(double? v, [int dp = 3]) => v == null ? '-' : v.toStringAsFixed(dp);

Future<ProviderContainer> _loadOffice(ReferenceBuilding b) async {
  final c = ProviderContainer();
  c.read(sheetsControllerProvider.notifier).loadSheets(
    [
      for (final s in b.sheets)
        Sheet(id: s.id, name: s.name, sizePx: const Size(2384, 1684)),
    ],
    sheetFloors: {for (final s in b.sheets) s.id: s.floorIndex},
  );
  final project = c.read(projectControllerProvider.notifier)
    ..setFloors(b.building.floors);
  for (final MapEntry(:key, :value) in b.calibrations.entries) {
    project.setCalibration(key, value);
  }
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
  c.read(occupancyProvider.notifier).set(b.occupancy);
  c.read(fireHazardProvider.notifier).set(FireHazardClass.lightHazard);
  c.read(networkControllerProvider.notifier).loadNetwork(b.network);
  final rooms = c.read(roomAreasProvider.notifier);
  for (final r in kOfficeRooms) {
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
  c.read(electricalProjectProvider.notifier).setProject(b.electrical);
  // Let the electrical store's deferred MEP-equipment sync run.
  await Future<void>.delayed(Duration.zero);
  return c;
}

double _len(ProviderContainer c, NetEdge e) {
  final project = c.read(projectControllerProvider);
  return edgeLength(e, c.read(sizingNetworkProvider),
          calibrationBySheet: project.calibrations,
          building: project.building,
          mounting: project.mounting)
      .meters;
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
  final d = c.read(sizingDetailProvider);
  _p('flushSystem=${d.flushSystem.name} flushValveNodes='
      '${(d.flushValveNodeIds.toList()..sort())}');
  _p('## APP water velocity checks');
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
}

void _dumpUpfeed(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final sizing = c.read(sizingProvider);
  final sol = c.read(solveProvider);
  final del = c.read(upfeedDeliveredProvider);
  final floors = c.read(upfeedSniFloorsProvider);
  _p('## APP upfeed (solveProvider = sizing basis, upfeedDeliveredProvider = '
      'movers running)');
  _p('target=${_f(c.read(targetResidualProvider).inKiloPascals)} kPa '
      'gravityDownfeedDrawn=${c.read(gravityDownfeedDrawnProvider)} '
      'downfeed=${c.read(downfeedProvider) == null ? 'null' : 'non-null'}');
  if (sol != null) {
    _p('basis: critical=${sol.criticalNodeId} '
        'requiredPumpHead=${_f(sol.requiredPumpHead.meters)} m '
        'targetHeldByDesign=${sol.targetHeldByDesign}');
  }
  if (del != null) {
    _p('delivered: critical=${del.criticalNodeId} '
        'requiredPumpHead=${_f(del.requiredPumpHead.meters)} m');
  }
  _p('sniMinimumAtCritical='
      '${_f(c.read(upfeedSniMinimumResidualProvider)?.inKiloPascals)} kPa');
  _p('| node | delivery | basis static | basis residual | delivered static | '
      'delivered residual | SNI floor |');
  final ids = {...?sol?.residualPressure.keys, ...?del?.residualPressure.keys}
      .toList()
    ..sort();
  for (final id in ids) {
    _p('| $id | ${sol?.deliveryNodeIds.contains(id)} | '
        '${_f(sol?.noFlowStaticPressure[id]?.inKiloPascals)} | '
        '${_f(sol?.residualPressure[id]?.inKiloPascals)} | '
        '${_f(del?.noFlowStaticPressure[id]?.inKiloPascals)} | '
        '${_f(del?.residualPressure[id]?.inKiloPascals)} | '
        '${_f(floors[id]?.inKiloPascals)} |');
  }
  _p('upfeedOverPressure=${[
    for (final o in c.read(upfeedOverPressureProvider)) o.toString()
  ]}');
  // The friction path source → critical node (the oriented sized flows).
  if (sol != null) {
    final critical = sol.criticalNodeId;
    final roots = serviceComponentRootsFor(net, ServiceType.coldWater);
    _p('sizer roots (cold water): $roots');
    final path = <NetEdge>[];
    String? cur = critical;
    final seen = <String>{};
    while (cur != null && !roots.contains(cur) && seen.add(cur)) {
      NetEdge? inEdge;
      for (final e in net.edges) {
        if (e.service != ServiceType.coldWater) continue;
        final s = sizing[e.id];
        if (s == null) continue;
        final other = e.fromId == cur ? e.toId : (e.toId == cur ? e.fromId : null);
        if (other == null) continue;
        if (s.flowFromId == other) inEdge = e;
      }
      if (inEdge == null) break;
      path.insert(0, inEdge);
      cur = inEdge.fromId == cur ? inEdge.toId : inEdge.fromId;
    }
    _p('friction path to $critical (edge | L m | Q L/s | DN):');
    for (final e in path) {
      final s = sizing[e.id]!;
      _p('  ${e.id} | ${_f(_len(c, e))} | ${_f(s.flow.inLitersPerSecond, 4)} | '
          '${s.diameter.inMillimeters}');
    }
  }
  final pump = c.read(pumpDutyProvider);
  _p('pumpDuty=${pump == null ? 'null' : 'Q=${_f(pump.flow.inLitersPerSecond, 4)} L/s '
      'H=${_f(pump.head.meters)} m hyd=${_f(pump.hydraulicPower.watts, 1)} W '
      'shaft=${_f(pump.shaftPower.watts, 1)} W input=${_f(pump.motorInputPower.watts, 1)} W '
      'motor=${_f(pump.selectedMotor.inKiloWatts, 2)} kW oversized=${pump.motorOversized}'}');
  _p('primarySupplyPumpNode=${c.read(primarySupplyPumpNodeProvider)} '
      'transfers=${c.read(transferPumpNodeIdsProvider)} '
      'supplyBooster=${c.read(supplyBoosterProvider)} '
      'peakFlow=${_f(c.read(supplyPeakFlowProvider)?.inLitersPerSecond, 4)} L/s');
  for (final e in c.read(supplyMoverDutiesProvider).entries) {
    final d = e.value;
    _p('mover ${e.key}: Q=${_f(d.flow.inLitersPerSecond, 4)} H=${_f(d.head.meters)} '
        'hyd=${_f(d.hydraulicPower.watts, 1)} shaft=${_f(d.shaftPower.watts, 1)} '
        'input=${_f(d.motorInputPower.watts, 1)} motor=${_f(d.selectedMotor.inKiloWatts, 2)} kW');
  }
  _p('zones=${[for (final z in c.read(zonesProvider)) '${z.bottomFloorIndex}-${z.topFloorIndex}']}');
  for (final z in c.read(zoneStaticsProvider)) {
    _p('zoneStatic ${z.zone.bottomFloorIndex}-${z.zone.topFloorIndex} '
        'topResidual=${_f(z.topResidual.inKiloPascals)} '
        'bottomStatic=${_f(z.bottomStatic.inKiloPascals)} '
        'within=${z.withinLimit} viaPrv=${z.viaPrv}');
  }
}

/// The sizer's cold-water component roots (the plant the UBAP accumulate
/// from), as the shophouse dump prints them.
List<String> serviceComponentRootsFor(Network net, ServiceType s) {
  final r = serviceComponentRoots(net, s, demandNodeIds: {
    for (final n in net.nodes)
      if (n.role == NodeRole.fixture) n.id,
  });
  return ({for (final v in r.values) v}.toList()..sort());
}

void _dumpFire(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final sizing = c.read(sizingProvider);
  final project = c.read(projectControllerProvider);
  _p('## APP fire inputs');
  final sd = c.read(sprinklerDesignProvider);
  _p('hazard=${c.read(fireHazardProvider).name} '
      'K=${c.read(firePerHeadKFactorProvider)} designArea='
      '${_f(sd.designAreaValue.squareMeters)} m2 requiredFlow='
      '${_f(sd.requiredFlow.inLitersPerSecond, 4)} L/s count=${sd.sprinklerCount} '
      'perHead=${_f(sd.flowPerSprinkler.inLitersPerSecond, 4)} L/s');
  final ra = c.read(sprinklerRemoteAreaProvider);
  _p('remoteArea: headFlow=${_f(ra.remoteHeadFlow.inLitersPerSecond, 4)} L/s '
      'densityShare=${_f(ra.densityShareFlow.inLitersPerSecond, 4)} '
      'headP=${_f(ra.remoteHeadPressure.inKiloPascals)} kPa '
      'minOpP=${_f(ra.minOperatingPressure.inKiloPascals)} kPa '
      'branchFriction=${_f(ra.branchLineFrictionHead.meters)} m '
      'branchBaseP=${_f(ra.branchBasePressure.inKiloPascals)} kPa '
      'demand=${_f(ra.remoteAreaDemand.inLitersPerSecond, 4)} L/s '
      'governedByMinP=${ra.governedByMinimumPressure}');
  final st = c.read(standpipeDesignProvider);
  _p('standpipe (advisory, sizer flow): class=${st.standpipeClass.name} '
      'flow=${_f(st.requiredFlow.inLitersPerSecond, 4)} L/s '
      'topResidual=${_f(st.topResidualPressure.inKiloPascals)} kPa '
      'minRiser=${st.minRiserDiameter.inMillimeters} head=${_f(st.pumpHead.meters)} m');
  final rst = c.read(reportStandpipeDesignProvider);
  _p('standpipe (report): ${rst == null ? 'null' : 'class=${rst.standpipeClass.name} '
      'flow=${_f(rst.requiredFlow.inLitersPerSecond, 4)} L/s '
      'topResidual=${_f(rst.topResidualPressure.inKiloPascals)} kPa '
      'minRiser=${rst.minRiserDiameter.inMillimeters} head=${_f(rst.pumpHead.meters)} m '
      'hyd=${_f(rst.pumpHydraulicPower.watts, 1)} W shaft=${_f(rst.pumpShaftPower.watts, 1)} W'}');
  _p('## APP fire pipes (edge | service | kind | L m | Q L/s | DN | v m/s)');
  for (final e in net.edges) {
    if (e.service != ServiceType.fireHydrant &&
        e.service != ServiceType.fireSprinkler) {
      continue;
    }
    final s = sizing[e.id];
    _p('| ${e.id} | ${e.service.name} | ${e.kind.name} | ${_f(_len(c, e))} | '
        '${_f(s?.flow.inLitersPerSecond, 4)} | ${s?.diameter.inMillimeters} | '
        '${_f(s?.velocity.metersPerSecond)} |');
  }
  _p('## APP fire system bases');
  for (final b in c.read(fireSystemBasesProvider)) {
    _p('pumps=${b.pumpIds} duty=${b.dutyPumpId} sprinklerOnly=${b.sprinklerOnly} '
        'risers=${b.standpipeRisers} class=${b.standpipeClass.name} '
        'staticLift=${_f(b.staticLiftM)} m indexFriction=${_f(b.indexFrictionM)} m '
        'flow=${_f(b.flow.inLitersPerSecond, 4)} L/s head=${_f(b.head.meters)} m '
        'sprinklerGovernsCombined=${b.sprinklerGovernsCombined} '
        'gravityFed=${b.gravityFed} transfer=${b.transfer} dry=${b.dry} '
        'stages=${b.stages.length} stageHeads=${b.stageHeads}');
    final liftH = b.system.staticLiftM(net, project.building, FireTerminalKind.hydrant);
    final liftS = b.system.staticLiftM(net, project.building, FireTerminalKind.sprinkler);
    _p('  lifts: hydrant=${_f(liftH)} m sprinkler=${_f(liftS)} m');
    if (b.dutyPumpId case final pump?) {
      final fs = fireIndexPathFrictionM(
        net: net,
        system: b.system,
        pumpId: pump,
        sizing: sizing,
        lengthOf: (e) => _len(c, e),
        terminals: FireTerminalKind.sprinkler,
      );
      final sp = sprinklerPumpRatedPoint(
        remote: c.read(sprinklerRemoteAreaProvider),
        staticLiftM: liftS,
        indexPathFriction: fs == null ? null : Head(fs),
      );
      final sp0 = sprinklerPumpRatedPoint(
        remote: c.read(sprinklerRemoteAreaProvider),
        staticLiftM: liftS,
      );
      _p('  sprinkler point (not governing unless larger): '
          '${_f(sp.flow.inLitersPerSecond, 4)} L/s @ ${_f(sp.head.meters)} m '
          '(allowance-only basis ${_f(sp0.head.meters)} m)');
    }
    final r = b.rating;
    _p('  rating: rated ${_f(r.ratedFlow.inLitersPerSecond, 4)} L/s @ '
        '${_f(r.ratedHead.meters)} m; churn ${_f(r.churn.flow.inLitersPerSecond, 4)} '
        '@ ${_f(r.churn.head.meters)}; overload ${_f(r.overload.flow.inLitersPerSecond, 4)} '
        '@ ${_f(r.overload.head.meters)}; motor=${_f(r.selectedMotor.inKiloWatts, 2)} kW '
        'oversized=${r.oversized} jockey ${_f(r.jockeyFlow.inLitersPerSecond, 4)} L/s @ '
        '${_f(r.jockeyHead.meters)} m designation=${r.designation.name} '
        'standbyRecommended=${r.standbyRecommended}');
    final d = b.duty;
    _p('  duty: ${d == null ? null : 'Q=${_f(d.flow.inLitersPerSecond, 4)} H=${_f(d.head.meters)} '
        'hyd=${_f(d.hydraulicPower.watts, 1)} shaft=${_f(d.shaftPower.watts, 1)} '
        'input=${_f(d.motorInputPower.watts, 1)} motor=${_f(d.selectedMotor.inKiloWatts, 2)} kW'}');
    final j = b.jockey;
    _p('  jockey: ${j == null ? null : 'Q=${_f(j.flow.inLitersPerSecond, 4)} H=${_f(j.head.meters)} '
        'motor=${_f(j.selectedMotor.inKiloWatts, 2)} kW'}');
    if (b.standpipe case final sp?) {
      _p('  standpipe: flow=${_f(sp.requiredFlow.inLitersPerSecond, 4)} '
          'topResidual=${_f(sp.topResidualPressure.inKiloPascals)} kPa '
          'minRiser=${sp.minRiserDiameter.inMillimeters} head=${_f(sp.pumpHead.meters)} m');
    }
    // Per-terminal friction from the duty pump, and the outlet pressures.
    if (b.dutyPumpId case final pump?) {
      for (final kind in [FireTerminalKind.hydrant, FireTerminalKind.sprinkler]) {
        final per = <String, double>{};
        final fr = fireIndexPathFrictionM(
          net: net,
          system: b.system,
          pumpId: pump,
          sizing: sizing,
          lengthOf: (e) => _len(c, e),
          terminals: kind,
          frictionByTerminalOut: per,
        );
        _p('  friction ${kind.name}: index=${_f(fr)} m per terminal '
            '${{for (final k in (per.keys.toList()..sort())) k: _f(per[k])}}');
      }
      final hyd = <String, double>{};
      fireIndexPathFrictionM(
        net: net,
        system: b.system,
        pumpId: pump,
        sizing: sizing,
        lengthOf: (e) => _len(c, e),
        terminals: FireTerminalKind.hydrant,
        frictionByTerminalOut: hyd,
      );
      for (final o in standpipeOutletPressures(
        net: net,
        system: b.system,
        sizing: sizing,
        building: project.building,
        churnHeadByPump: {for (final id in b.pumpIds) id: b.rating.churn.head.meters},
        ratedHeadByPump: {for (final id in b.pumpIds) id: b.rating.ratedHead.meters},
        frictionToOutletM: hyd,
      )) {
        _p('  outlet ${o.outletId} floor=${o.floorIndex} hoseStation=${o.hoseStation} '
            'static(churn)=${_f(o.staticKpa)} kPa residual(rated)=${_f(o.residualKpa)} kPa '
            'overStatic=${o.overStatic} overResidual=${o.overResidual}');
      }
    }
  }
  final fpd = c.read(firePumpDutyProvider);
  _p('firePumpDuty=${fpd == null ? null : 'Q=${_f(fpd.flow.inLitersPerSecond, 4)} '
      'H=${_f(fpd.head.meters)} motor=${_f(fpd.selectedMotor.inKiloWatts, 2)} kW'} '
      'jockeyDuty=${c.read(fireJockeyDutyProvider) == null ? null : 'Q=${_f(c.read(fireJockeyDutyProvider)!.flow.inLitersPerSecond, 4)} H=${_f(c.read(fireJockeyDutyProvider)!.head.meters)} motor=${_f(c.read(fireJockeyDutyProvider)!.selectedMotor.inKiloWatts, 2)} kW'}');
  final rp = c.read(fireRatedPointProvider);
  _p('ratedPoint=${_f(rp.flow.inLitersPerSecond, 4)} L/s @ ${_f(rp.head.meters)} m '
      'sprinklerOnly=${rp.sprinklerOnly} allGravityFed=${c.read(fireAllGravityFedProvider)}');
  _p('sprinklerPumpCheck=${c.read(sprinklerPumpCheckProvider)}');
  _p('fireOverPressure=${c.read(fireOverPressureProvider)}');
  _p('standpipeOutletOverPressure=${[
    for (final o in c.read(standpipeOutletOverPressureProvider))
      '${o.residual ? 'residual' : 'static'} floors ${o.lowFloor}-${o.highFloor} '
          'max ${_f(o.maxKpa)} min ${_f(o.minKpa)} limit ${_f(o.limitKpa)}'
  ]}');
  _p('fire tank volume: not computed by any provider (FT tankCapacityLitres='
      '${net.nodeById('FT')?.tankCapacityLitres})');
}

void _dumpHvac(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final sizing = c.read(sizingProvider);
  final rooms = c.read(roomAreasProvider);
  final project = c.read(projectControllerProvider);
  final ducts = c.read(ductSettingsProvider);
  _p('## APP HVAC (duct settings shape=${ducts.shape.name} '
      'method=${ducts.method.name})');
  for (final r in rooms) {
    final mpp = project.calibrationFor(r.sheetId)!.metersPerPixel;
    final s = c.read(roomSizingProvider)[r.id];
    _p('${r.id} "${r.name}" type=${r.roomType.name} floor=${r.floorIndex} '
        '${_f(r.widthPx * mpp)} x ${_f(r.heightPx * mpp)} m '
        'area=${_f(r.netAreaM2(mpp, rooms))} m2 ceiling=${r.ceilingHeightM} m '
        'ACH=${r.effectiveAch()} equipment=${r.equipmentKind.name}');
    if (s != null) {
      _p('  airflow=${_f(s.airflow.inLitersPerSecond, 3)} L/s '
          '(${_f(s.airflowCfm, 1)} CFM) volume=${_f(s.roomVolumeM3)} m3');
      _p('  supply bank x${s.supply.count} each ${_f(s.supply.airflowEach.inLitersPerSecond, 3)} '
          'L/s face ${s.supply.faceMm} faceV ${_f(s.supply.each.faceVelocity.metersPerSecond)}; '
          'return bank x${s.return_.count} each ${_f(s.return_.airflowEach.inLitersPerSecond, 3)} '
          'L/s face ${s.return_.faceMm} faceV ${_f(s.return_.each.faceVelocity.metersPerSecond)}');
      _p('  trunk D=${s.supplyDuctDiameter.inMillimeters} v=${_f(s.supplyDuctVelocity.metersPerSecond)} '
          'equipment static=${_f(s.equipment.totalStaticPressure.pascals, 2)} Pa '
          'motor=${_f(s.equipment.selectedMotor.inKiloWatts, 2)} kW '
          'input=${_f(s.equipment.motorInputPower.watts, 2)} W');
      final load = c.read(roomCoolingLoadProvider(r.id));
      if (load != null) {
        _p('  cooling load=${_f(load.btuPerHr, 1)} BTU/h pk=${_f(load.pk)} '
            'recommended=${load.recommended.pk} PK exceedsRange=${load.recommended.exceedsRange}');
      }
    }
  }
  _p('fixture stamped airflow: SD each ${_f(kOfficeRoomAirflow.inLitersPerSecond / 4, 4)} L/s, '
      'RG1 ${_f(kOfficeRoomAirflow.inLitersPerSecond, 4)} L/s');
  _p('## APP air terminals (node | comp | airflow L/s | face mm)');
  for (final n in net.nodes) {
    if (n.airflow == null && n.component != NodeComponent.fcu) continue;
    _p('${n.id} | ${n.component?.name} | ${_f(n.airflow?.inLitersPerSecond, 4)} | '
        '${n.faceWidthMm}x${n.faceHeightMm}');
  }
  _p('## APP ducts (edge | service | L m | Q L/s | D mm | W x H | v m/s | '
      'friction Pa/m galvanised default | product | friction Pa/m at product)');
  for (final e in net.edges) {
    if (e.service.regime != FlowRegime.air) continue;
    final s = sizing[e.id];
    _p('| ${e.id} | ${e.service.name} | ${_f(_len(c, e))} | '
        '${_f(s?.flow.inLitersPerSecond, 3)} | ${s?.diameter.inMillimeters} | '
        '${s?.width == null ? '-' : '${s!.width!.inMillimeters}x${s.height!.inMillimeters}'} | '
        '${_f(s?.velocity.metersPerSecond)} | '
        '${s == null ? '-' : _f(ductFrictionPaPerMetre(s.flow, s.diameter), 4)} | '
        '${effectiveDuctProductFor(e).name} | '
        '${s == null ? '-' : _f(ductFrictionPaPerMetre(s.flow, s.diameter, roughness: ductRoughnessFor(effectiveDuctProductFor(e))), 4)} |');
  }
  _p('## APP air velocity checks');
  for (final e in c.read(airVelocityChecksProvider).entries) {
    final v = e.value;
    _p('${e.key}: ${_f(v.actual.metersPerSecond)} in '
        '[${_f(v.min.metersPerSecond)}, ${_f(v.max.metersPerSecond)}] ${v.verdict.name}');
  }
  _p('airUnsized=${(c.read(airUnsizedProvider).toList()..sort())} '
      'airOverCapacity=${c.read(airOverCapacityProvider)}');
  for (final svc in [ServiceType.duct, ServiceType.returnAir]) {
    for (final s in c.read(airSystemsProvider(svc))) {
      _p('airSystem ${svc.name} root=${s.fanNodeId} '
          'trunk=${_f(s.trunk.inLitersPerSecond, 3)} L/s '
          'stat=${_f(s.stat.pascals, 2)} Pa intake=${_f(s.intake.pascals, 2)} Pa '
          'inlineFans=${s.inlineFanIds}');
    }
  }
  _p('internal static (FCU) = '
      '${_f(airUnitInternalStatic(net.nodeById(kOfficeFcuId)).pascals, 1)} Pa');
  for (final e in c.read(supplyFanDutiesByRootProvider).entries) {
    final d = e.value;
    _p('fanDuty ${e.key}: Q=${_f(d.airflow.inLitersPerSecond, 3)} L/s '
        'static=${_f(d.totalStaticPressure.pascals, 2)} Pa air=${_f(d.airPower.watts, 2)} W '
        'shaft=${_f(d.shaftPower.watts, 2)} W input=${_f(d.motorInputPower.watts, 2)} W '
        'motor=${_f(d.selectedMotor.inKiloWatts, 2)} kW');
  }
  final df = c.read(ductFanProvider);
  _p('ductFan=${df == null ? null : '${_f(df.totalStaticPressure.pascals, 2)} Pa '
      '${_f(df.selectedMotor.inKiloWatts, 2)} kW'} '
      'airBalance=${c.read(airBalanceProvider)}');
  for (final e in c.read(roomAirUnitDutiesProvider).entries) {
    _p('roomAirUnitDuty ${e.key}: room=${e.value.room.id} '
        'static=${_f(e.value.duty.totalStaticPressure.pascals, 2)} Pa '
        'motor=${_f(e.value.duty.selectedMotor.inKiloWatts, 2)} kW');
  }
}

void _dumpBom(ProviderContainer c) {
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

void _dumpMachines(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final bind = c.read(mepDutyBindingProvider);
  final nodeDuties = c.read(equipmentNodeDutiesProvider);
  final fed = c.read(nodeFedLoadsProvider);
  _p('## APP machines -> MEP loads (binding: supplyPump=${bind.supplyPumpNodeId} '
      'fire=${bind.firePumpNodeIds} fireStandby=${bind.fireStandbyPumpNodeIds} '
      'fireJockey=${bind.fireJockeyPumpNodeIds} assumedJockey=${bind.fireAssumedJockeyPumpNodeIds} '
      'supplyFan=${bind.supplyFanNodeId} exhaustFan=${bind.exhaustFanNodeId})');
  for (final l in c.read(placedEquipmentLoadsProvider)) {
    final id = l.id.startsWith('node-') ? l.id.substring(5) : l.id;
    _p('${l.id} "${l.name}" comp=${net.nodeById(id)?.component?.name} '
        'source=${l.source.name} mech=${_f(l.mechanicalPower.watts, 1)} W '
        'input=${_f(l.electricalInputPower?.watts, 1)} W phases=${l.phases} '
        'cos=${l.cosPhi} eff=${l.motorEfficiency} '
        'nodeDuty=${_f(nodeDuties[id]?.motor.watts, 1)}/${_f(nodeDuties[id]?.input.watts, 1)} '
        'fed=${_f(fed[id]?.watts, 1)} input ${_f(fed[id]?.input, 1)} (${fed[id]?.source.name})');
  }
}

void _dumpMepSync(ProviderContainer c) {
  final project = c.read(electricalProjectProvider);
  _p('## APP electrical project after the MEP sync');
  for (final p in project.panels) {
    _p('panel ${p.id} "${p.name}" tag=${p.tag} system=${p.system.name} '
        'V=${p.voltage.volts} source=${p.sourceType.name} '
        'fedBy=${p.fedByCircuitId} essential=${p.essential} ways=${p.circuits.length}');
    for (final w in p.circuits) {
      if (w.sourceEquipmentId == null && w.feedsPanelId == null) continue;
      _p('  ${w.id} "${w.name}" kind=${w.loadKind.name} loadW=${w.loadW} '
          'motorKw=${w.motorKw} phases=${w.phases} cos=${w.cosPhi} '
          'DF=${w.demandFactor} lifeSafety=${w.lifeSafety} cableType=${w.cableType} '
          'starter=${w.starterType?.name} fla=${w.flaOverrideA?.amperes} '
          'source=${w.sourceEquipmentId} feeds=${w.feedsPanelId} '
          'L=${w.length.meters}');
    }
  }
  _p('mepDutyFeedEnabled=${c.read(mepDutyFeedEnabledProvider)}');
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
        'grouping=${panelModel.groupingCount} diversity=${panelModel.diversityFactor} '
        'essential=${panelModel.essential}');
    _p('| way | name | kind | 3ph | phase | cos | DF | loadW | connW | Ib | run | '
        'breaker | poles | kA | cable | Iz derated (base, k, Izreq, CLF, rule) | '
        'VD% own/lim | VD% cum | RCD | L m | lifeSafety |');
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
          '${r.lengthM} | ${m?.lifeSafety} |');
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
  final roots = originPanelIdsOf(sys, project).toList()..sort();
  for (final id in roots) {
    final va = rootServiceBasisVa(project, sys, id);
    _p('root $id basisVa=${_f(va, 1)} lineA=${_f(va / (1.7320508075688772 * 400), 2)}');
  }
  _p('servicePerPhaseBasisVa=${_f(servicePerPhaseBasisVa(project, sys, roots), 1)}');
  _p('## APP electrical warnings (electricalAllWarningsProvider)');
  for (final w in c.read(electricalAllWarningsProvider)) {
    _p('- [${w.severity.name}] ${w.code} (${w.panelId}/${w.circuitId}): '
        '${w.message}');
  }
}

void main() {
  test('reference office loads through the store intents and every provider '
      'evaluates', () async {
    final office = buildOffice();
    final c = await _loadOffice(office);
    addTearDown(c.dispose);

    final project = c.read(projectControllerProvider);
    expect(project.floors.length, 4);
    expect(project.calibrations.length, 4);
    expect(c.read(feedStrategyProvider), FeedStrategy.upfeed);
    expect(c.read(sizingNetworkProvider).edges.length,
        office.network.edges.length);
    final room = c.read(roomAreasProvider).single;
    expect(room.ceilingHeightM, closeTo(kOfficeRoomCeilingM, 1e-9));
    // The fixture's stamped airflow IS the app's room sizing.
    expect(c.read(roomSizingProvider)[room.id]!.airflow.cubicMetersPerSecond,
        closeTo(kOfficeRoomAirflow.cubicMetersPerSecond, 1e-12));

    final sizing = c.read(sizingProvider);
    for (final e in office.network.edges) {
      expect(sizing[e.id], isNotNull, reason: e.id);
    }
    expect(c.read(solveProvider), isNotNull);
    expect(c.read(upfeedDeliveredProvider), isNotNull);
    c.read(supplyMoverDutiesProvider);
    c.read(pumpDutyProvider);
    expect(c.read(fireSystemBasesProvider), isNotEmpty);
    c.read(firePumpDutyProvider);
    c.read(supplyFanDutiesByRootProvider);
    expect(c.read(bomProvider), isNotEmpty);
    c.read(fittingsProvider);
    c.read(designIssuesProvider);
    c.read(complianceSummaryProvider);
    final sys = c.read(electricalResultProvider);
    for (final t in kOfficeFloorTags) {
      expect(sys.panels[officePanelId(t)], isNotNull, reason: t);
    }
    c.read(electricalAdvancedProvider);
    c.read(electricalAllWarningsProvider);

    if (_dump) {
      _dumpMechanical(c);
      _dumpUpfeed(c);
      _dumpFire(c);
      _dumpHvac(c);
      _dumpBom(c);
      _dumpIssues(c);
      _dumpMachines(c);
      _dumpMepSync(c);
      _dumpElectrical(c);
      // ignore: avoid_print
      print(_out.toString());
    }
  });

  // ── Hand-derived pins (reviewer pass 2, 2026-11-13) ─────────────────────
  group('hand values (app providers)', () {
    late ProviderContainer c;
    setUpAll(() async {
      c = await _loadOffice(buildOffice());
    });
    tearDownAll(() => c.dispose());

    test('upfeed: P1 on 38.539 m; SNI floors; one zone, no PRV', () {
      final up = c.read(upfeedDeliveredProvider)!;
      expect(up.criticalNodeId, 'WCb3');
      expect(up.residualPressure['WCb3']!.inKiloPascals, closeTo(225.0, 2e-3));
      // Hydraulic 9810 x 3.91733e-3 x 38.539 = 1481.0 W; shaft / 0.70 =
      // 2115.7 W ⇒ 2.2 kW; fed input 2200 / 0.90 = 2444.4 W.
      final p1 = c.read(supplyMoverDutiesProvider)['P1']!;
      expect(p1.flow.inLitersPerSecond, closeTo(3.91733, 5e-5));
      expect(p1.head.meters, closeTo(38.539, 5e-4));
      expect(p1.hydraulicPower.watts, closeTo(1481.0, 0.05));
      expect(p1.shaftPower.watts, closeTo(2115.7, 0.05));
      expect(p1.selectedMotor.inKiloWatts, closeTo(2.2, 1e-9));
      expect(c.read(nodeFedLoadsProvider)['P1']!.input, closeTo(2444.4, 0.05));
      final floors = c.read(upfeedSniFloorsProvider);
      for (var f = 0; f < 4; f++) {
        for (final b in kOfficeFloorFixtures) {
          expect(floors['$b$f']!.inKiloPascals,
              closeTo(b.startsWith('WC') ? 98.067 : 49.033, 1e-3),
              reason: '$b$f');
        }
      }
      expect(c.read(upfeedOverPressureProvider), isEmpty);
      // O2 — one zone hung from the solved datum, no PRV station.
      expect([
        for (final z in c.read(zonesProvider))
          (z.bottomFloorIndex, z.topFloorIndex)
      ], [
        (0, 3)
      ]);
      expect(c.read(zoneStaticsProvider).single.viaPrv, isFalse);
    });

    test('fire pump: 31.545 L/s @ 98.536 m, NFPA 20 curve, 55 kW, jockey', () {
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.sprinklerOnly, isFalse);
      expect(b.dutyPumpId, 'FP');
      // 13.2 + max(15, 2.872) + 690 / 9.81 = 98.536 m.
      expect(b.staticLiftM, closeTo(13.2, 1e-9));
      expect(b.indexFrictionM, closeTo(2.872, 5e-4));
      expect(b.flow.inLitersPerSecond, closeTo(31.5451, 5e-4));
      expect(b.head.meters, closeTo(98.536, 5e-4));
      // Churn 1.4 x 98.536 = 137.951 m; overload 1.5 Q = 47.3176 L/s @ 0.65 H
      // = 64.049 m; overload shaft 1.5 x 0.65 x 30 492.8 / (0.7 x 0.85) =
      // 29 730.5 / 0.595 = 49 967.2 W ⇒ 55 kW.
      final r = b.rating;
      expect(r.churn.head.meters, closeTo(137.951, 5e-4));
      expect(r.overload.flow.inLitersPerSecond, closeTo(47.3176, 5e-4));
      expect(r.overload.head.meters, closeTo(64.049, 5e-4));
      expect(r.overload.shaftPower.watts, closeTo(49967.2, 0.05));
      expect(r.selectedMotor.inKiloWatts, closeTo(55, 1e-9));
      expect(r.standbyRecommended, isTrue);
      final d = c.read(firePumpDutyProvider)!;
      expect(d.hydraulicPower.watts, closeTo(30492.8, 0.05));
      expect(d.shaftPower.watts, closeTo(43561.2, 0.05));
      expect(c.read(nodeFedLoadsProvider)['FP']!.input, closeTo(61111.1, 0.05));
      // Jockey 1 % = 0.3155 L/s at churn + 5 = 142.951 m, 0.75 kW.
      final j = c.read(fireJockeyDutyProvider)!;
      expect(j.flow.inLitersPerSecond, closeTo(0.31545, 5e-5));
      expect(j.head.meters, closeTo(142.951, 5e-4));
      expect(j.selectedMotor.inKiloWatts, closeTo(0.75, 1e-9));
    });

    test('sprinkler point (not governing): 15.7 + 50 / 9.81 + 37.414 m', () {
      // Backlog A-1 (O3 / backlog f) — the judge requires the rating
      // basis' sprinkler point (one source of truth): lift to the top head
      // ceiling 15.7 + the 50 kPa remote head 5.097 + the sized sprinkler
      // index friction (after O1) 37.414 = 58.211 m, against the pump's
      // 98.536 m ⇒ not short. (Before A-1: the lower bound 15.7 +
      // 96.722 / 9.81 = 25.560 m.)
      final chk = c.read(sprinklerPumpCheckProvider)!;
      expect(chk.headShort, isFalse);
      expect(chk.flowShort, isFalse);
      expect(chk.requiredHeadM, closeTo(15.7 + 50 / 9.81 + 37.414, 5e-4));
      expect(chk.pumpHeadM, closeTo(98.536, 5e-4));
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.sprinklerPointHeadM, closeTo(chk.requiredHeadM, 1e-12));
    });

    test('HVAC: fan static (supply + return + FCU internal) 121.25 Pa', () {
      // Supply: (0.4462 + 0.4405 + 0.6651 + 1.0342) x 3 x 1.3 + 30 = 40.09;
      // return 0.4462 x 2 x 1.3 + 30 = 31.16; + 50 internal = 121.25 Pa.
      final fan = c.read(supplyFanDutiesByRootProvider)[kOfficeFcuId]!;
      expect(fan.airflow.cubicMetersPerSecond, closeTo(0.925, 1e-9));
      expect(fan.totalStaticPressure.pascals, closeTo(121.25, 0.005));
      expect(fan.airPower.watts, closeTo(112.15, 0.005));
      expect(fan.shaftPower.watts, closeTo(172.54, 0.005));
      expect(fan.selectedMotor.inKiloWatts, closeTo(0.37, 1e-9));
      final sz = c.read(sizingProvider);
      for (final (id, dn) in [
        ('e_sa_FCU1_SD1', 500), ('e_sa_SD1_SD2', 450), ('e_sa_SD2_SD3', 355),
        ('e_sa_SD3_SD4', 250), ('e_ra_RG1_FCU1', 500), //
      ]) {
        expect(sz[id]!.diameter.inMillimeters, dn, reason: id);
      }
      expect(c.read(airVelocityChecksProvider).values
          .where((v) => v.verdict != VelocityBandVerdict.ok), isEmpty);
    });

    test('MEP board, MEP feeder (O4) and LVMDP', () {
      final sys = c.read(electricalResultProvider);
      final mep = sys.panels['mep-equipment']!;
      Map<String, dynamic> way(String id) {
        final r = mep.circuits.firstWhere((x) => x.circuitId == id);
        return {
          'ib': r.designCurrentExactA,
          'mcb': r.breaker.ratingA.amperes,
          'csa': r.cable.csaMm2,
          'iz': r.cable.deratedIz.amperes,
          'cores': r.grounding.cores,
          'rcd': r.rcd.required,
          'type': r.grounding.cableType,
        };
      }

      // P1 2444.4 / (√3 x 400 x 0.85) = 4.151 A, 6 A D, 4 x 2.5.
      expect(way('mep-node-P1')['ib'], closeTo(4.151, 5e-4));
      expect(way('mep-node-P1')['mcb'], 6);
      expect(way('mep-node-P1')['cores'], 4);
      // FP 61 111 / (√3 x 400 x 0.85) = 103.77 A, MCCB 125 A, FRC 3 x 35 +
      // 16 (Iz 144 >= 1.25 x 103.77 = 129.7), no RCD.
      expect(way('mep-node-FP')['ib'], closeTo(103.77, 5e-3));
      expect(way('mep-node-FP')['mcb'], 125);
      expect(way('mep-node-FP')['csa'], 35);
      expect(way('mep-node-FP')['iz'], 144);
      expect(way('mep-node-FP')['type'], 'FRC');
      expect(way('mep-node-FP')['rcd'], isFalse);
      // FCU1 411.1 / (231 x 0.85) = 2.094 A, 6 A C, 1-phase.
      expect(way('mep-node-FCU1')['ib'], closeTo(2.094, 5e-4));
      expect(way('mep-node-FCU1')['mcb'], 6);
      expect(mep.demandW, closeTo(63967, 0.5));
      expect(mep.demandVa, closeTo(75255, 0.5));
      expect([mep.phaseBalance.l1, mep.phaseBalance.l2, mep.phaseBalance.l3],
          [107.9, 107.9, 110.0]);
      expect(mep.incomer.breaker.ratingA.amperes, 125);
      expect(mep.incomer.poles, 4);
      // MEP feeder: Ib 110.0 A, FRC (O4) sized on the XLPE table: 1.25 x
      // 110 = 137.5 <= 144 A at 35 mm² ⇒ the selectivity floor 1.6 x 125 is
      // capped at the largest rung Iz 144 protects: MCCB 125 A.
      final lv = sys.panels[kOfficeMainPanelId]!;
      final f = lv.circuits.firstWhere((x) => x.circuitId == 'mep-equipment-feeder');
      expect(f.designCurrent.amperes, 110.0);
      expect(f.grounding.cableType, 'FRC');
      expect(f.cable.csaMm2, 35);
      expect(f.breaker.ratingA.amperes, 125);
      // LVMDP: 4 x 16 050 + 63 967 = 128 167 W; lines 216.2 / 216.2 / 212.6;
      // incomer on the service floor 164 000 / (√3 x 400) = 236.7 A → 250 A
      // 4P; recommended daya 164 000 VA.
      expect(lv.demandW, closeTo(128167, 0.5));
      expect(lv.demandVa, closeTo(149059, 0.5));
      expect([lv.phaseBalance.l1, lv.phaseBalance.l2, lv.phaseBalance.l3],
          [216.2, 216.2, 212.6]);
      expect(lv.incomer.sizingCurrent!.amperes, closeTo(236.7, 1e-9));
      expect(lv.incomer.breaker.ratingA.amperes, 250);
      expect(lv.incomer.poles, 4);
      final adv = c.read(electricalAdvancedProvider);
      expect(adv.recommendedDayaVa, 164000);
      expect(adv.fault.originFaultkA, 10.0);
    });

    test('Review: deliberate findings present, fixed ones absent', () {
      final kinds = [for (final i in c.read(designIssuesProvider)) i.kind];
      int count(String k) => kinds.where((x) => x == k).length;
      expect(count('electrical:life-safety-not-essential'), 1);
      expect(count('electrical:non-selective'), 5);
      expect(count('fire-system-over-pressure:FP'), 1);
      // Backlog A-2 — FT has no capacity: the reserve 31.5451 L/s x 1800 s
      // = 56 781 L is stated as an info, never a fabricated capacity.
      expect(count('fire-tank-capacity-unset:FT'), 1);
      expect(kinds.where((k) => k.startsWith('fire-tank-undersized')), isEmpty);
      expect(count('standpipe-outlet-over-pressure:FP:0-3'), 1);
      expect(count('electrical:fire-pump-protection'), 1);
      // Consequence of the 164 kVA service floor (incomer 250 A): recorded.
      expect(count('electrical:enclosure-temp-rise-exceeded'), 1);
      expect(kinds, isNot(contains('electrical:service-capacity-below-demand')));
      expect(kinds, isNot(contains('electrical:life-safety-feeder-cable')));
      expect(kinds.where((k) => k.startsWith('air-terminal-unsized')), isEmpty);
      expect(kinds.where((k) => k.startsWith('unfed-panel')), isEmpty);
      expect(kinds.where((k) => k.startsWith('pressure-zone')), isEmpty);
      // Churn 137.951 x 9.81 = 1353.3 kPa > 1210; every hose valve's static
      // over 1207 kPa.
      final over = c.read(fireOverPressureProvider).single;
      expect(over.check.churnKpa, closeTo(1353.3, 0.05));
      final outlets = c.read(standpipeOutletOverPressureProvider).single;
      expect((outlets.lowFloor, outlets.highFloor), (0, 3));
    });
  });
}
