// Reference building 4 (apartment) — APP-level smoke test.
//
// Loads the fixed 12-storey apartment block
// (`packages/mechx_engine/test/reference/apartment.dart`) into a
// ProviderContainer through the real store intents (sheets, floors,
// calibrations, roof-tank DOWNFEED, private occupancy, light fire hazard,
// the network, the two Lantai 6 bedrooms drawn with `roomAreasProvider` and
// the electrical project with its standby genset), lets the real MEP sync
// mint the "MEP Equipment" board, then RE-FEEDS that board from the
// essential board PP-E with the real `connectFeeder` intent and specifies the
// new feeder FRC with `setCircuit` (the sync auto-wires the MEP board onto
// the one unfed root, LVMDP). It evaluates the providers every printed
// surface reads: sizing, the gravity downfeed field and the delivered field
// with the booster running, the transfer / booster duties, the zone table,
// the fire system basis (duty / standby / jockey), the room cooling loads,
// BOM + fittings, the Review fan-in, the compliance roll-up, the electrical
// result / advanced study / genset sizing / warnings. The cold-water field
// and the zone table are dumped BEFORE (no PRV) and AFTER the PRV station
// the zone table prescribes is drawn. It asserts only that the project
// loads and the providers evaluate; hand-derived expected values are a later
// task. Set REF_DUMP=1 to print every solved figure.
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
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/electrical/advanced_study.dart'
    show
        gensetPlantVa,
        gensetStartMotors,
        gensetStartFloorFor,
        originPanelIdsOf,
        rootServiceBasisVa,
        servicePerPhaseBasisVa;
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/panel_results.dart'
    show PhaseAssignmentInfo;
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart'
    show sprinklerPumpRatedPoint;
import 'package:mechx_engine/sizing/network_sizing.dart'
    show serviceComponentRoots;
import 'package:mechx_engine/sizing/standpipe_outlet_pressure.dart';
import 'package:mechx_engine/standards/puil.dart' show BreakerClassCode;
import 'package:mechx_engine/units.dart';

import '../packages/mechx_engine/test/reference/apartment.dart';

final bool _dump = Platform.environment['REF_DUMP'] == '1';
final StringBuffer _out = StringBuffer();
void _p(String s) => _out.writeln(s);

String _f(double? v, [int dp = 3]) => v == null ? '-' : v.toStringAsFixed(dp);

const String _mepBoard = 'mep-equipment';

/// Loads [b] through the store intents, lets the MEP sync run and re-feeds
/// the MEP board from PP-E (FRC).
Future<ProviderContainer> _loadApartment(ReferenceBuilding b) async {
  final c = ProviderContainer();
  c
      .read(sheetsControllerProvider.notifier)
      .loadSheets(
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
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(occupancyProvider.notifier).set(b.occupancy);
  c.read(fireHazardProvider.notifier).set(FireHazardClass.lightHazard);
  c.read(networkControllerProvider.notifier).loadNetwork(b.network);
  final rooms = c.read(roomAreasProvider.notifier);
  for (final r in kApartmentRooms) {
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
  _refeedMep(c);
  await Future<void>.delayed(Duration.zero);
  return c;
}

/// Where the sync wired the MEP board before the re-feed (for the report).
String? _mepFedByBefore;

/// The MEP board onto PP-E: the real re-parenting `connectFeeder` intent,
/// then the new feeder way specified FRC through `setCircuit`.
void _refeedMep(ProviderContainer c) {
  final store = c.read(electricalProjectProvider.notifier);
  final before = c.read(electricalProjectProvider);
  final mep = before.panels.where((p) => p.id == _mepBoard).firstOrNull;
  if (mep == null) return;
  final parent = before.panels
      .where((p) => p.circuits.any((w) => w.feedsPanelId == _mepBoard))
      .firstOrNull;
  _mepFedByBefore = '${parent?.id} via ${mep.fedByCircuitId}';
  if (parent?.id == kAptEssentialPanelId) return;
  final r = store.connectFeeder(kAptEssentialPanelId, _mepBoard);
  expect(r.connected, isTrue, reason: r.reason);
  final after = c.read(electricalProjectProvider);
  final way = after.panels
      .firstWhere((p) => p.id == kAptEssentialPanelId)
      .circuits
      .firstWhere((w) => w.feedsPanelId == _mepBoard);
  store.setCircuit(kAptEssentialPanelId, way.id, cableType: 'FRC');
}

double _len(ProviderContainer c, NetEdge e) {
  final project = c.read(projectControllerProvider);
  return edgeLength(
    e,
    c.read(sizingNetworkProvider),
    calibrationBySheet: project.calibrations,
    building: project.building,
    mounting: project.mounting,
  ).meters;
}

void _dumpMechanical(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final project = c.read(projectControllerProvider);
  final sizing = c.read(sizingProvider);
  final fu = c.read(edgeFixtureUnitsProvider);
  final lengths = projectEdgeLengths(net, project);
  _p(
    '## APP sizing (edge | service | kind | L m | FU | Q L/s | DN | '
    'v m/s | from | flags)',
  );
  for (final e in net.edges) {
    final s = sizing[e.id];
    final flags = [
      if (s?.overCapacity ?? false) 'overCapacity',
      if (s?.stackRaisedForBranch ?? false) 'stackRaisedForBranch',
      if (!(s?.selfCleansingOk ?? true)) 'selfCleansingFail',
      if (s?.loopUnbalanced ?? false) 'loopUnbalanced',
      if (s?.demandCurveExtrapolated ?? false) 'demandCurveExtrapolated',
      if (s?.belowCodeMinimum ?? false) 'belowCodeMinimum',
      if (e.sizeOverride != null) 'sizeOverride',
    ];
    _p(
      '| ${e.id} | ${e.service.name} | ${e.kind.name} | '
      '${_f(lengths[e.id]?.meters)} | ${fu[e.id] ?? '-'} | '
      '${_f(s?.flow.inLitersPerSecond, 4)} | ${s?.diameter.inMillimeters} | '
      '${_f(s?.velocity.metersPerSecond)} | ${s?.flowFromId} | '
      '${flags.isEmpty ? '-' : flags.join(',')} |',
    );
  }
  final d = c.read(sizingDetailProvider);
  _p(
    'flushSystem=${d.flushSystem.name} parallelLegs='
    '${(d.parallelLegs.toList()..sort())} assumedJockeys=${d.assumedJockeys}',
  );
  _p('## APP water velocity checks');
  for (final e in c.read(waterVelocityChecksProvider).entries) {
    final v = e.value;
    _p(
      '${e.key}: ${_f(v.actual.metersPerSecond)} in '
      '[${_f(v.min.metersPerSecond)}, ${_f(v.max.metersPerSecond)}] '
      '${v.verdict.name}',
    );
  }
  _p('## APP drainage advisories');
  for (final a in c.read(drainageAdvisoryProvider)) {
    _p('${a.edgeId}: ${a.kind} ${a.message}');
  }
  _p('## APP node elevations (nodeElevation / displayed)');
  for (final n in net.nodes) {
    _p(
      '${n.id} floor=${n.floorIndex} role=${n.role.name} '
      'comp=${n.component?.name} fixture=${n.fixture?.name} '
      'z=${_f(nodeElevation(n, project.building, project.mounting).meters)} '
      'shown=${_f(displayedNodeElevation(net, n, project.building, project.mounting).meters)}',
    );
  }
}

/// The downfeed field (gravity + delivered), the movers and the zone table.
void _dumpDownfeed(ProviderContainer c, String label) {
  final net = c.read(sizingNetworkProvider);
  final sizing = c.read(sizingProvider);
  final project = c.read(projectControllerProvider);
  _p('## APP $label downfeed');
  _p(
    'gravityDownfeedDrawn=${c.read(gravityDownfeedDrawnProvider)} '
    'tankElevation=${_f(c.read(downfeedTankElevationProvider)?.meters)} '
    'effectiveDatum=${_f(c.read(effectiveDownfeedDatumProvider)?.meters)} '
    'datumByFloor=${c.read(downfeedDatumByFloorProvider)?.map((k, v) => MapEntry(k, _f(v.meters)))} '
    'target=${_f(c.read(targetResidualProvider).inKiloPascals)} kPa',
  );
  final roots = serviceComponentRoots(
    net,
    ServiceType.coldWater,
    demandNodeIds: {
      for (final n in net.nodes)
        if (n.role == NodeRole.fixture) n.id,
    },
  );
  _p('sizer roots (cold water): ${{for (final r in roots.values) r}}');
  _p(
    'extraDownfeedTanks=${[for (final x in c.read(extraDownfeedTanksProvider)) x.tank]} extraSupplySources=${[for (final x in c.read(extraSupplySourcesProvider)) x.source]}',
  );
  final down = c.read(downfeedProvider);
  final del = c.read(downfeedDeliveredProvider);
  final floors = c.read(downfeedSniFloorsProvider);
  _p(
    'gravity: critical=${down?.criticalNodeId} '
    'min=${_f(down?.minResidual.inKiloPascals)} '
    'boosterHeadRequired=${_f(down?.boosterHeadRequired.meters)} '
    'gravitySufficient=${down?.gravitySufficient}',
  );
  _p(
    'delivered: critical=${del?.criticalNodeId} '
    'min=${_f(del?.minResidual.inKiloPascals)} '
    'gravitySufficient=${del?.gravitySufficient}',
  );
  _p(
    'sniMinimumAtCritical='
    '${_f(c.read(downfeedSniMinimumResidualProvider)?.inKiloPascals)} kPa',
  );
  _p(
    '| node | delivery | gravity static | gravity residual | delivered static '
    '| delivered residual | SNI floor |',
  );
  final ids = {
    ...?down?.residualPressure.keys,
    ...?del?.residualPressure.keys,
  }.toList()..sort();
  for (final id in ids) {
    _p(
      '| $id | ${del?.deliveryNodeIds.contains(id)} | '
      '${_f(down?.noFlowStaticPressure[id]?.inKiloPascals)} | '
      '${_f(down?.residualPressure[id]?.inKiloPascals)} | '
      '${_f(del?.noFlowStaticPressure[id]?.inKiloPascals)} | '
      '${_f(del?.residualPressure[id]?.inKiloPascals)} | '
      '${_f(floors[id]?.inKiloPascals)} |',
    );
  }
  _p('downfeedOverPressure=${c.read(downfeedOverPressureProvider)}');
  // Movers.
  final duties = c.read(supplyMoverDutiesProvider);
  final transfers = c.read(transferPumpNodeIdsProvider);
  final heads = c.read(downfeedMoverHeadsProvider);
  final bind = c.read(mepDutyBindingProvider);
  _p(
    '## APP $label supply movers (node | inEdge | Q | served (count, '
    'delivery fixtures) | transfer)',
  );
  for (final m in supplyMovers(
    net,
    sizing,
    excludeEdgeIds: c.read(parallelLegEdgeIdsProvider),
    rootFlowOf: (_) => const FlowRate(0),
  )) {
    final served = m.served.toList()..sort();
    final fx = served
        .where((id) => net.nodeById(id)?.role == NodeRole.fixture)
        .toList();
    _p(
      '${m.nodeId} | in=${m.inEdgeId} | Q=${_f(m.flow.inLitersPerSecond, 4)} '
      '| served=${served.length} nodes, ${fx.length} fixtures '
      '(floors ${{for (final id in fx) net.nodeById(id)!.floorIndex}.toList()..sort()}) '
      'tanks=${[for (final n in served)
        if (net.nodeById(n)?.component == NodeComponent.roofTank || net.nodeById(n)?.component == NodeComponent.groundTank) n]} | transfer=${m.transfer}',
    );
  }
  for (final id in (duties.keys.toList()..sort())) {
    final d = duties[id]!;
    String extra = '';
    if (transfers.contains(id)) {
      final l =
          nodeElevation(
            net.nodeById('RT')!,
            project.building,
            project.mounting,
          ).meters -
          nodeElevation(
            net.nodeById('GT')!,
            project.building,
            project.mounting,
          ).meters;
      extra = ' lift(GT->RT)=${_f(l)} friction=${_f(d.head.meters - l)}';
    }
    _p(
      'duty $id ${transfers.contains(id) ? 'transfer' : 'booster'}: '
      'Q=${_f(d.flow.inLitersPerSecond, 4)} H=${_f(d.head.meters)} m$extra '
      'hyd=${_f(d.hydraulicPower.watts, 1)} shaft=${_f(d.shaftPower.watts, 1)} '
      'input=${_f(d.motorInputPower.watts, 1)} motor=${_f(d.selectedMotor.inKiloWatts, 2)} kW '
      'oversized=${d.motorOversized} deliveredHead=${_f(heads[id]?.meters)}',
    );
  }
  final pump = c.read(pumpDutyProvider);
  _p(
    'pumpDuty(primary)=${pump == null ? 'null' : 'Q=${_f(pump.flow.inLitersPerSecond, 4)} '
              'H=${_f(pump.head.meters)} motor=${_f(pump.selectedMotor.inKiloWatts, 2)} kW'} '
    'primaryNode=${c.read(primarySupplyPumpNodeProvider)} '
    'supplyBooster=${c.read(supplyBoosterProvider)} '
    'binding.supplyPump=${bind.supplyPumpNodeId} '
    'peakFlow=${_f(c.read(supplyPeakFlowProvider)?.inLitersPerSecond, 4)} L/s',
  );
  // Zone table.
  _p('## APP $label zone table (prvSetpoint basis)');
  for (final g in c.read(downfeedZoneGroupsProvider)) {
    _p(
      'group tank=${g.tankId} datum=${_f(g.tankElevation?.meters)} '
      'byFloor=${g.tankElevationByFloor?.map((k, v) => MapEntry(k, _f(v.meters)))} '
      'zones=${[for (final z in g.zones) '${z.bottomFloorIndex}-${z.topFloorIndex}']}',
    );
  }
  for (final z in c.read(zoneStaticsProvider)) {
    _p(
      'zoneStatic ${z.zone.bottomFloorIndex}-${z.zone.topFloorIndex} '
      'topResidual=${_f(z.topResidual.inKiloPascals)} '
      'bottomStatic=${_f(z.bottomStatic.inKiloPascals)} '
      'within=${z.withinLimit} viaPrv=${z.viaPrv}',
    );
  }
}

void _dumpFire(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final sizing = c.read(sizingProvider);
  final project = c.read(projectControllerProvider);
  _p('## APP fire inputs');
  final sd = c.read(sprinklerDesignProvider);
  _p(
    'hazard=${c.read(fireHazardProvider).name} '
    'K=${c.read(firePerHeadKFactorProvider)} designArea='
    '${_f(sd.designAreaValue.squareMeters)} m2 requiredFlow='
    '${_f(sd.requiredFlow.inLitersPerSecond, 4)} L/s count=${sd.sprinklerCount} '
    'perHead=${_f(sd.flowPerSprinkler.inLitersPerSecond, 4)} L/s',
  );
  final ra = c.read(sprinklerRemoteAreaProvider);
  _p(
    'remoteArea: headFlow=${_f(ra.remoteHeadFlow.inLitersPerSecond, 4)} L/s '
    'headP=${_f(ra.remoteHeadPressure.inKiloPascals)} kPa '
    'branchFriction=${_f(ra.branchLineFrictionHead.meters)} m '
    'branchBaseP=${_f(ra.branchBasePressure.inKiloPascals)} kPa '
    'demand=${_f(ra.remoteAreaDemand.inLitersPerSecond, 4)} L/s '
    'governedByMinP=${ra.governedByMinimumPressure}',
  );
  final st = c.read(standpipeDesignProvider);
  _p(
    'standpipe (advisory, sizer flow): class=${st.standpipeClass.name} '
    'flow=${_f(st.requiredFlow.inLitersPerSecond, 4)} L/s '
    'topResidual=${_f(st.topResidualPressure.inKiloPascals)} kPa '
    'minRiser=${st.minRiserDiameter.inMillimeters} head=${_f(st.pumpHead.meters)} m',
  );
  final rst = c.read(reportStandpipeDesignProvider);
  _p(
    'standpipe (report): ${rst == null ? 'null' : 'class=${rst.standpipeClass.name} '
              'flow=${_f(rst.requiredFlow.inLitersPerSecond, 4)} L/s '
              'head=${_f(rst.pumpHead.meters)} m '
              'hyd=${_f(rst.pumpHydraulicPower.watts, 1)} W shaft=${_f(rst.pumpShaftPower.watts, 1)} W'}',
  );
  _p('## APP fire pipes (edge | service | kind | L m | Q L/s | DN | v m/s)');
  for (final e in net.edges) {
    if (e.service != ServiceType.fireHydrant &&
        e.service != ServiceType.fireSprinkler) {
      continue;
    }
    final s = sizing[e.id];
    _p(
      '| ${e.id} | ${e.service.name} | ${e.kind.name} | ${_f(_len(c, e))} | '
      '${_f(s?.flow.inLitersPerSecond, 4)} | ${s?.diameter.inMillimeters} | '
      '${_f(s?.velocity.metersPerSecond)} |',
    );
  }
  _p('## APP fire system bases');
  for (final b in c.read(fireSystemBasesProvider)) {
    _p(
      'pumps=${b.pumpIds} duty=${b.dutyPumpId} sprinklerOnly=${b.sprinklerOnly} '
      'risers=${b.standpipeRisers} class=${b.standpipeClass.name} '
      'staticLift=${_f(b.staticLiftM)} m indexFriction=${_f(b.indexFrictionM)} m '
      'flow=${_f(b.flow.inLitersPerSecond, 4)} L/s head=${_f(b.head.meters)} m '
      'sprinklerGovernsCombined=${b.sprinklerGovernsCombined} '
      'gravityFed=${b.gravityFed} transfer=${b.transfer} dry=${b.dry} '
      'stages=${b.stages.length} stageHeads=${b.stageHeads}',
    );
    final liftH = b.system.staticLiftM(
      net,
      project.building,
      FireTerminalKind.hydrant,
    );
    final liftS = b.system.staticLiftM(
      net,
      project.building,
      FireTerminalKind.sprinkler,
    );
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
      _p(
        '  sprinkler point: ${_f(sp.flow.inLitersPerSecond, 4)} L/s @ '
        '${_f(sp.head.meters)} m',
      );
    }
    final r = b.rating;
    _p(
      '  rating: rated ${_f(r.ratedFlow.inLitersPerSecond, 4)} L/s @ '
      '${_f(r.ratedHead.meters)} m; churn @ ${_f(r.churn.head.meters)}; '
      'overload ${_f(r.overload.flow.inLitersPerSecond, 4)} @ '
      '${_f(r.overload.head.meters)} shaft ${_f(r.overload.shaftPower.watts, 1)} W; '
      'motor=${_f(r.selectedMotor.inKiloWatts, 2)} kW oversized=${r.oversized} '
      'jockey ${_f(r.jockeyFlow.inLitersPerSecond, 4)} L/s @ '
      '${_f(r.jockeyHead.meters)} m designation=${r.designation.name} '
      'standbyRecommended=${r.standbyRecommended}',
    );
    final d = b.duty;
    _p(
      '  duty: ${d == null ? null : 'Q=${_f(d.flow.inLitersPerSecond, 4)} H=${_f(d.head.meters)} '
                'hyd=${_f(d.hydraulicPower.watts, 1)} shaft=${_f(d.shaftPower.watts, 1)} '
                'input=${_f(d.motorInputPower.watts, 1)} motor=${_f(d.selectedMotor.inKiloWatts, 2)} kW'}',
    );
    final j = b.jockey;
    _p(
      '  jockey: ${j == null ? null : 'Q=${_f(j.flow.inLitersPerSecond, 4)} H=${_f(j.head.meters)} '
                'shaft=${_f(j.shaftPower.watts, 1)} motor=${_f(j.selectedMotor.inKiloWatts, 2)} kW'}',
    );
    if (b.dutyPumpId case final pump?) {
      for (final kind in [
        FireTerminalKind.hydrant,
        FireTerminalKind.sprinkler,
      ]) {
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
        _p(
          '  friction ${kind.name}: index=${_f(fr)} m per terminal '
          '${{for (final k in (per.keys.toList()..sort())) k: _f(per[k])}}',
        );
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
        churnHeadByPump: {
          for (final id in b.pumpIds) id: b.rating.churn.head.meters,
        },
        ratedHeadByPump: {
          for (final id in b.pumpIds) id: b.rating.ratedHead.meters,
        },
        frictionToOutletM: hyd,
      )) {
        _p(
          '  outlet ${o.outletId} floor=${o.floorIndex} '
          'static(churn)=${_f(o.staticKpa)} kPa residual(rated)=${_f(o.residualKpa)} kPa '
          'overStatic=${o.overStatic} overResidual=${o.overResidual}',
        );
      }
    }
  }
  final fpd = c.read(firePumpDutyProvider);
  final jd = c.read(fireJockeyDutyProvider);
  _p(
    'firePumpDuty=${fpd == null ? null : 'Q=${_f(fpd.flow.inLitersPerSecond, 4)} '
              'H=${_f(fpd.head.meters)} motor=${_f(fpd.selectedMotor.inKiloWatts, 2)} kW'} '
    'jockeyDuty=${jd == null ? null : 'Q=${_f(jd.flow.inLitersPerSecond, 4)} '
              'H=${_f(jd.head.meters)} motor=${_f(jd.selectedMotor.inKiloWatts, 2)} kW'}',
  );
  final rp = c.read(fireRatedPointProvider);
  _p(
    'ratedPoint=${_f(rp.flow.inLitersPerSecond, 4)} L/s @ ${_f(rp.head.meters)} m '
    'sprinklerOnly=${rp.sprinklerOnly} allGravityFed=${c.read(fireAllGravityFedProvider)}',
  );
  _p('assumedFireJockeys=${c.read(assumedFireJockeysProvider)}');
  _p('sprinklerPumpCheck=${c.read(sprinklerPumpCheckProvider)}');
  _p('fireOverPressure=${c.read(fireOverPressureProvider)}');
  _p(
    'standpipeOutletOverPressure=${[for (final o in c.read(standpipeOutletOverPressureProvider)) '${o.residual ? 'residual' : 'static'} floors ${o.lowFloor}-${o.highFloor} '
          'max ${_f(o.maxKpa)} min ${_f(o.minKpa)} limit ${_f(o.limitKpa)}']}',
  );
  _p(
    'fire tank: FT tankCapacityLitres=${net.nodeById('FT')?.tankCapacityLitres} '
    '(no provider sizes a fire-water reserve)',
  );
}

void _dumpRooms(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final project = c.read(projectControllerProvider);
  final rooms = c.read(roomAreasProvider);
  _p(
    '## APP rooms + cooling (method=${c.read(coolingLoadMethodProvider).name})',
  );
  for (final r in rooms) {
    final mpp = project.calibrationFor(r.sheetId)!.metersPerPixel;
    final load = c.read(roomCoolingLoadProvider(r.id));
    _p(
      '${r.id} "${r.name}" type=${r.roomType.name} floor=${r.floorIndex} '
      '${_f(r.widthPx * mpp)} x ${_f(r.heightPx * mpp)} m '
      'area=${_f(r.netAreaM2(mpp, rooms))} m2 ceiling=${r.ceilingHeightM} m '
      'ACH=${r.effectiveAch()} equipment=${r.equipmentKind.name}',
    );
    if (load != null) {
      _p(
        '  load=${_f(load.btuPerHr, 1)} BTU/h (${_f(load.watts, 1)} W) '
        'pk=${_f(load.pk)} recommended=${load.recommended.pk} PK '
        '(${load.recommended.nominalBtuPerHr} BTU/h) '
        'exceedsRange=${load.recommended.exceedsRange}',
      );
    }
    final s = c.read(roomSizingProvider)[r.id];
    if (s != null) {
      _p(
        '  air: ${_f(s.airflow.inLitersPerSecond, 3)} L/s '
        'supply x${s.supply.count} face ${s.supply.faceMm} '
        'equipment motor=${_f(s.equipment.selectedMotor.inKiloWatts, 2)} kW',
      );
    }
  }
  final fed = c.read(nodeFedLoadsProvider);
  for (final n in net.nodes) {
    if (!RoomArea.isAcComponent(n.component)) continue;
    final share = acUnitShare(
      net,
      rooms,
      (s) => project.calibrationFor(s)?.metersPerPixel,
      n,
      method: c.read(coolingLoadMethodProvider),
    );
    _p(
      'AC ${n.id} ${n.component!.name}: room=${share?.room.id} '
      'perUnit=${_f(share?.btuPerHr, 1)} BTU/h unit=${share?.unit.pk} PK '
      '(${share?.unit.nominalBtuPerHr} BTU/h, exceedsRange=${share?.unit.exceedsRange}) '
      'inputW=${_f(share?.inputW, 1)} | fed=${_f(fed[n.id]?.watts, 1)} W '
      'input=${_f(fed[n.id]?.input, 1)} (${fed[n.id]?.source.name})',
    );
  }
}

void _dumpBom(ProviderContainer c) {
  _p(
    '## APP BOM (service | kind | DN | m | segs | material | tag | floor | flags)',
  );
  for (final b in c.read(bomProvider)) {
    _p(
      '| ${b.service.name} | ${b.kind.name} | ${b.diameterMm} | '
      '${_f(b.totalLength.meters)} | ${b.segmentCount} | ${b.material} | '
      '${b.tag} | ${b.floorIndex} | manual=${b.manual} assumed=${b.assumed} '
      'unmeasured=${b.unmeasuredSegments} |',
    );
  }
  _p('## APP fittings (service | type | DN | count | material)');
  for (final f in c.read(fittingsProvider)) {
    _p(
      '| ${f.service.name} | ${f.type.name} | ${f.diameterMm} | ${f.count} | '
      '${f.material} |',
    );
  }
  _p('## APP component takeoff');
  for (final l in c.read(componentTakeoffProvider)) {
    _p(
      '${l.service.name} ${l.component.name} ${l.sizeLabel} x${l.count} '
      'assumed=${l.assumed} equipment=${l.equipment}',
    );
  }
}

void _dumpIssues(ProviderContainer c, String label) {
  final issues = c.read(designIssuesProvider);
  _p(
    '## APP $label design issues (${issues.length}; '
    '${issues.where((i) => i.isVerify).length} are // VERIFY)',
  );
  final verifyBySeverity = <String, int>{};
  for (final i in issues) {
    if (i.isVerify) {
      verifyBySeverity.update(i.severity.name, (n) => n + 1, ifAbsent: () => 1);
      continue;
    }
    _p(
      '- [${i.severity.name}] ${i.kind} | ${i.title} | ${i.message} | '
      'locate=${i.locate?.sheetId}/${i.locate?.nodeId}/${i.locate?.edgeId}'
      '/${i.locate?.panelId}/${i.locate?.circuitId}',
    );
  }
  _p('verify advisories by severity: $verifyBySeverity');
  _p('## APP $label verify advisories (kind | title)');
  for (final i in issues.where((i) => i.isVerify)) {
    _p('- ${i.kind} | ${i.title}');
  }
  _p('## APP $label compliance summary');
  for (final it in c.read(complianceSummaryProvider).items) {
    _p('- ${it.category}: pass=${it.pass} | ${it.detail}');
  }
}

void _dumpMachines(ProviderContainer c) {
  final net = c.read(sizingNetworkProvider);
  final bind = c.read(mepDutyBindingProvider);
  final nodeDuties = c.read(equipmentNodeDutiesProvider);
  final fed = c.read(nodeFedLoadsProvider);
  _p(
    '## APP machines -> MEP loads (binding: supplyPump=${bind.supplyPumpNodeId} '
    'standby=${bind.standbyPumpNodeIds} fire=${bind.firePumpNodeIds} '
    'fireStandby=${bind.fireStandbyPumpNodeIds} '
    'fireJockey=${bind.fireJockeyPumpNodeIds} '
    'assumedJockey=${bind.fireAssumedJockeyPumpNodeIds})',
  );
  for (final l in c.read(placedEquipmentLoadsProvider)) {
    final id = l.id.startsWith('node-') ? l.id.substring(5) : l.id;
    _p(
      '${l.id} "${l.name}" comp=${net.nodeById(id)?.component?.name} '
      'source=${l.source.name} mech=${_f(l.mechanicalPower.watts, 1)} W '
      'input=${_f(l.electricalInputPower?.watts, 1)} W phases=${l.phases} '
      'cos=${l.cosPhi} eff=${l.motorEfficiency} '
      'nodeDuty=${_f(nodeDuties[id]?.motor.watts, 1)}/${_f(nodeDuties[id]?.input.watts, 1)} '
      'fed=${_f(fed[id]?.watts, 1)} input ${_f(fed[id]?.input, 1)} (${fed[id]?.source.name})',
    );
  }
}

void _dumpMepSync(ProviderContainer c) {
  final project = c.read(electricalProjectProvider);
  _p(
    '## APP electrical project after the MEP sync + re-feed '
    '(MEP board was fed by $_mepFedByBefore before the re-feed)',
  );
  for (final p in project.panels) {
    _p(
      'panel ${p.id} "${p.name}" tag=${p.tag} system=${p.system.name} '
      'V=${p.voltage.volts} source=${p.sourceType.name} '
      'fedBy=${p.fedByCircuitId} essential=${p.essential} ways=${p.circuits.length}',
    );
    for (final w in p.circuits) {
      if (w.sourceEquipmentId == null &&
          w.feedsPanelId == null &&
          p.id != kAptEssentialPanelId) {
        continue;
      }
      _p(
        '  ${w.id} "${w.name}" kind=${w.loadKind.name} loadW=${w.loadW} '
        'motorKw=${w.motorKw} phases=${w.phases} cos=${w.cosPhi} '
        'DF=${w.demandFactor} lifeSafety=${w.lifeSafety} cableType=${w.cableType} '
        'starter=${w.starterType?.name} fla=${w.flaOverrideA?.amperes} '
        'source=${w.sourceEquipmentId} feeds=${w.feedsPanelId} '
        'L=${w.length.meters}',
      );
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
  _p(
    'panels=${project.panels.map((p) => '${p.id}:${p.name}').toList()} '
    'earthing=${project.earthingSystem.name} supplyKind=${project.supplyKind.name} '
    'declared=${project.supplyCapacityVa?.voltAmperes} VA '
    'genset kva=${project.sources?.generator?.kva?.inKilovoltAmperes} '
    'units=${project.sources?.generator?.units} '
    'mode=${project.sources?.generator?.mode.name} '
    'transfer=${project.sources?.generator?.transfer.name} '
    'backupFractionTyped=${project.sources?.generator?.backupFractionTyped}',
  );
  _p(
    'originFault=${_f(fault.amperes, 1)} A basis=${fault.basis.name} '
    'study.originFaultkA=${adv.fault.originFaultkA} '
    'busbarClearing=${effectiveBusbarClearingTimeS(project)} s',
  );
  final model = {
    for (final p in project.panels)
      for (final ci in p.circuits) ci.id: ci,
  };
  for (final pid in sys.order) {
    final p = sys.panels[pid]!;
    final panelModel = project.panels.firstWhere((x) => x.id == pid);
    _p(
      '### panel $pid "${p.name}" system=${p.system.name} '
      'V=${panelModel.voltage.volts} install=${panelModel.installMethod.name} '
      'diversity=${panelModel.diversityFactor} essential=${panelModel.essential} '
      'fedBy=${panelModel.fedByCircuitId}',
    );
    _p(
      '| way | name | kind | 3ph | phase | cos | DF | loadW | connW | Ib | run | '
      'breaker | poles | kA | cable | Iz (base, k, Izreq, rule) | '
      'VD% own/lim | VD% cum | RCD | L m | lifeSafety | starter |',
    );
    for (final r in p.circuits) {
      final m = model[r.circuitId];
      final cf = adv.fault.circuits[r.circuitId];
      final poles = r.phase.isThreePhase ? 3 : 1;
      _p(
        '| ${r.circuitId} | ${r.name} | ${r.loadKind.name} | ${r.threePhase} | '
        '${r.phase.name} | ${m?.cosPhi} | ${m?.demandFactor} | ${r.loadW} | '
        '${r.connectedW} | ${r.designCurrent.amperes} '
        '(exact ${r.designCurrentExactA}) | ${r.runCurrentA.amperes} | '
        '${r.breaker.deviceClass.code} ${r.breaker.ratingA.amperes}A '
        '${r.breaker.curve.name.toUpperCase()} | ${poles}P | '
        '${cf?.breakerKa} (fault ${cf?.faultkA}, Zs ${_f(cf?.zsOhm, 4)}/${_f(cf?.zsMaxOhm, 4)}, '
        'ADS ${cf?.adsOk}${cf?.adsByRcd == true ? ' by RCD' : ''}) | '
        '${r.grounding.cableType} ${r.grounding.cableSpec} '
        '(${r.cable.csaMm2} mm2, PE ${r.grounding.peCsaMm2}, cores ${r.grounding.cores}) | '
        '${r.cable.deratedIz.amperes} (${r.cable.baseKha.amperes}, '
        '${r.cable.deratingFactor}, ${r.cable.izRequired?.amperes}, '
        '${r.cable.appliedRule}, vdDriven ${r.cable.vdDriven}) | '
        '${_f(r.voltageDrop.dropPercent)} (${_f(r.voltageDrop.dropV)} V) / '
        '${r.voltageDrop.limitPercent} | ${_f(r.cumulativeDropPercent)} | '
        '${r.rcd.required ? '${r.rcd.ratingMa} mA ${r.rcd.type?.name}' : 'none (${r.rcd.reason})'} | '
        '${r.lengthM} | ${m?.lifeSafety} | ${m?.starterType?.name} |',
      );
    }
    final inc = p.incomer;
    _p(
      'connectedW=${p.connectedW} demandW=${p.demandW} demandVa=${p.demandVa} '
      'demandCurrent=${p.demandCurrent.amperes} '
      'largestDownstreamRunA=${p.largestDownstreamRunA}',
    );
    _p(
      'incomer=${inc.breaker.deviceClass.code} ${inc.breaker.ratingA.amperes}A '
      '${inc.breaker.curve.name.toUpperCase()} ${inc.poles}P '
      'sizingCurrent=${inc.sizingCurrent?.amperes} overRange=${inc.overRange}',
    );
    final b = p.busbar;
    _p(
      'busbar=${b.widthMm}x${b.thicknessMm} (${b.csaMm2} mm2, x${b.parallelBars}) '
      'ampacity=${b.ampacityA.amperes} A total=${b.totalCurrentA.amperes} A '
      'reason=${b.sizingReason.name}',
    );
    final pf = adv.fault.panels[pid];
    _p(
      'busFault=${pf?.prospectiveFaultkA} kA incomerKa=${pf?.incomerKa} '
      'adequate=${pf?.incomerAdequate}',
    );
    _p(
      'phaseBalance l1=${p.phaseBalance.l1} l2=${p.phaseBalance.l2} '
      'l3=${p.phaseBalance.l3}',
    );
  }
  _p(
    'supply: connectedW=${sys.supply.connectedW} demandW=${sys.supply.demandW} '
    'demandVa=${sys.supply.demandVa.voltAmperes} system=${sys.supply.system.name} '
    'V=${sys.supply.voltage.volts}',
  );
  final s = adv.supply;
  _p(
    'supplyDesign: level=${s.lvOrMv.name} demandKva=${s.demandKva} '
    'declared=${s.declared} declaredBelowDemand=${s.declaredBelowDemand} '
    'tx=${s.transformerKva} | ${s.note}',
  );
  _p(
    'recommendedDaya=${adv.recommendedDayaVa} VA '
    'threePhase=${adv.recommendedDayaThreePhase}',
  );
  final roots = originPanelIdsOf(sys, project).toList()..sort();
  for (final id in roots) {
    final va = rootServiceBasisVa(project, sys, id);
    _p(
      'root $id basisVa=${_f(va, 1)} lineA=${_f(va / (1.7320508075688772 * 400), 2)}',
    );
  }
  _p(
    'servicePerPhaseBasisVa=${_f(servicePerPhaseBasisVa(project, sys, roots), 1)}',
  );
  // Genset.
  final gen = project.sources?.generator;
  _p('## APP genset');
  _p(
    'backedPanels=${(gensetBackedPanelIds(project).toList()..sort())} '
    'effectiveBackupFraction=${effectiveGeneratorBackupFraction(project)} '
    'essentialDemandVa=${_f(essentialDemandVa(project, sys), 1)} '
    'essentialDemandW=${_f(essentialDemandW(project, sys), 1)} '
    'backupVa=${_f(gensetBackupDemandVa(project, sys).voltAmperes, 1)} '
    'backupW=${_f(gensetBackupDemandW(project, sys).watts, 1)} '
    'phaseDemandVa=${_f(gensetPhaseDemandVa(project, sys), 1)}',
  );
  final motors = gensetStartMotors(project, sys: sys);
  for (final m in motors) {
    _p(
      'startMotor ${m.name} circuit=${m.circuitId} shaft=${_f(m.shaftPower.inKiloWatts, 3)} kW '
      'starter=${m.starterType} startKva=${_f(m.startKva?.inKilovoltAmperes, 2)} '
      'lifeSafety=${m.lifeSafety}',
    );
  }
  _p(
    'startFloor=${_f(gensetStartFloorFor(project, sys).inKilovoltAmperes, 2)} kVA',
  );
  if (gen != null) {
    final r = sizeGenerator(
      gensetBackupDemandVa(project, sys),
      mode: gen.mode,
      transfer: gen.transfer,
      backupPower: gensetBackupDemandW(project, sys),
      minKvaForStart: gensetStartFloorFor(project, sys),
    );
    _p(
      'sized (unforced): rating=${_f(r.ratingKva.inKilovoltAmperes, 1)} kVA '
      'units=${r.units} backup=${_f(r.backupKva.inKilovoltAmperes, 2)} kVA '
      'fuel=${r.fuelLph} L/h dayTank=${r.dayTankL} L runtime=${r.runtimeHours} h | '
      '${r.note}',
    );
    _p(
      'required (load) kVA=${_f(requiredGeneratorKva(gensetBackupDemandVa(project, sys), mode: gen.mode, backupPower: gensetBackupDemandW(project, sys)), 2)}',
    );
  }
  _p('gensetPlantVa=${gensetPlantVa(project, sys)}');
  final gs = adv.powerOneLine?.gensetStart;
  _p(
    'oneLine gensetStart: ${gs == null ? null : 'genset=${_f(gs.gensetKva.inKilovoltAmperes, 1)} kVA '
              'limiting=${gs.limitingMotorName} startKva=${_f(gs.startingKva.inKilovoltAmperes, 2)} '
              'dip=${gs.estimatedDipPct}% acceptable=${gs.acceptable} '
              'recommendedMin=${_f(gs.recommendedMinGensetKva.inKilovoltAmperes, 2)} kVA | ${gs.note}'}',
  );
  for (final n in adv.powerOneLine?.nodes ?? const []) {
    _p('oneLine node ${n.id} ${n.kind} "${n.label}" ${n.sub ?? ''}');
  }
  for (final e in adv.powerOneLine?.edges ?? const []) {
    _p('oneLine edge ${e.from} -> ${e.to} ${e.label ?? ''}');
  }
  for (final i in adv.powerOneLine?.interlocks ?? const []) {
    _p('oneLine interlock $i');
  }
  _p('gensetAdsFailedCircuitIds=${adv.gensetAdsFailedCircuitIds}');
  _p('## APP electrical warnings (electricalAllWarningsProvider)');
  for (final w in c.read(electricalAllWarningsProvider)) {
    _p(
      '- [${w.severity.name}] ${w.code} (${w.panelId}/${w.circuitId}): '
      '${w.message}',
    );
  }
}

void main() {
  test('reference apartment loads through the store intents and every '
      'provider evaluates (BEFORE and AFTER the PRV station)', () async {
    // BEFORE: no PRV drawn.
    final before = await _loadApartment(buildApartment(prvFloor: null));
    addTearDown(before.dispose);
    final project = before.read(projectControllerProvider);
    expect(project.floors.length, kAptFloors);
    expect(project.calibrations.length, kAptFloors);
    expect(before.read(feedStrategyProvider), FeedStrategy.downfeed);
    expect(before.read(roomAreasProvider).length, 2);
    final sz0 = before.read(sizingProvider);
    for (final e in before.read(sizingNetworkProvider).edges) {
      expect(sz0[e.id], isNotNull, reason: e.id);
    }
    expect(before.read(downfeedProvider), isNotNull);
    expect(before.read(downfeedDeliveredProvider), isNotNull);
    before.read(zonesProvider);
    before.read(zoneStaticsProvider);
    before.read(designIssuesProvider);
    if (_dump) {
      _p('# BEFORE (no PRV drawn)');
      _dumpDownfeed(before, 'BEFORE');
      _dumpIssues(before, 'BEFORE');
    }

    // AFTER: the fixture as specified (the app-prescribed PRV station).
    final c = await _loadApartment(buildApartment());
    addTearDown(c.dispose);
    final sizing = c.read(sizingProvider);
    for (final e in c.read(sizingNetworkProvider).edges) {
      expect(sizing[e.id], isNotNull, reason: e.id);
    }
    expect(c.read(downfeedProvider), isNotNull);
    expect(c.read(downfeedDeliveredProvider), isNotNull);
    c.read(supplyMoverDutiesProvider);
    c.read(pumpDutyProvider);
    expect(c.read(fireSystemBasesProvider), isNotEmpty);
    c.read(firePumpDutyProvider);
    c.read(fireJockeyDutyProvider);
    expect(c.read(bomProvider), isNotEmpty);
    c.read(fittingsProvider);
    for (final r in c.read(roomAreasProvider)) {
      expect(c.read(roomCoolingLoadProvider(r.id)), isNotNull);
    }
    c.read(designIssuesProvider);
    c.read(complianceSummaryProvider);
    final ep = c.read(electricalProjectProvider);
    final mep = ep.panels.where((p) => p.id == _mepBoard).single;
    final feeder = ep.panels
        .expand((p) => [for (final w in p.circuits) (p, w)])
        .where((x) => x.$2.feedsPanelId == _mepBoard)
        .single;
    expect(feeder.$1.id, kAptEssentialPanelId);
    expect(feeder.$2.cableType, 'FRC');
    expect(mep.fedByCircuitId, feeder.$2.id);
    final sys = c.read(electricalResultProvider);
    for (var f = 0; f < kAptFloors; f++) {
      expect(sys.panels[aptFloorPanelId(f)], isNotNull);
    }
    c.read(electricalAdvancedProvider);
    c.read(electricalAllWarningsProvider);

    if (_dump) {
      _p('# AFTER (the fixture: PRV station drawn)');
      _dumpMechanical(c);
      _dumpDownfeed(c, 'AFTER');
      _dumpFire(c);
      _dumpRooms(c);
      _dumpBom(c);
      _dumpIssues(c, 'AFTER');
      _dumpMachines(c);
      _dumpMepSync(c);
      _dumpElectrical(c);
      // ignore: avoid_print
      print(_out.toString());
    }
  });
}
