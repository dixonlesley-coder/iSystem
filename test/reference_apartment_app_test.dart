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
import 'package:mechx_engine/sizing/fire_pump_rating.dart'
    show FirePressureClass;
import 'package:mechx_engine/sizing/fire_water_reserve.dart' show FireTankVerdict;
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
import 'package:mechx/store/tank_fill_store.dart';
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
    show ElectricalCircuitResult, PhaseAssignmentInfo;
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/tank_fill.dart' show formatReserveDays;
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart'
    show sprinklerPumpRatedPoint;
import 'package:mechx_engine/sizing/network_sizing.dart'
    show serviceComponentRoots;
import 'package:mechx_engine/sizing/standpipe_outlet_pressure.dart';
import 'package:mechx_engine/standards/puil.dart'
    show BreakerClass, BreakerClassCode;
import 'package:mechx_engine/units.dart';

import 'package:mechx_engine/report/electrical_sld_drawing.dart'
    show electricalRiserFloorOf;
import 'reference_board_floors.dart';
import 'reference_copper.dart';
import 'reference_riser_component_util.dart';
import '../packages/mechx_engine/test/reference/apartment.dart';

final bool _dump = Platform.environment['REF_DUMP'] == '1';
final StringBuffer _out = StringBuffer();
void _p(String s) => _out.writeln(s);

String _f(double? v, [int dp = 3]) => v == null ? '-' : v.toStringAsFixed(dp);

const String _mepBoard = 'mep-equipment';

/// Loads [b] through the store intents, lets the MEP sync run and re-feeds
/// the MEP board from PP-E (FRC).
/// Backlog D-4 — the apartment as drawn in the app: the fixture without its
/// spliced PRV, the station then placed ON the gravity riser with
/// `insertComponentOnRiser` (pinned equal to the spliced fixture below).
Future<ProviderContainer> _loadApartmentDrawnPrv() async {
  final c = await _loadApartment(buildApartment(prvFloor: null));
  placePrvsByIntent(c, [kAptPrvFloor!]);
  return c;
}

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
  c.read(populationProvider.notifier).set(b.population);
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
  // Drawing backlog C-2 — every board on its own floor (riser).
  setReferenceBoardFloors(c);
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
    final c = await _loadApartmentDrawnPrv();
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

  // Backlog D-4 — the PRV station placed ON the riser with the store intent
  // (riser GR1 → PRV → GR0, both riser segments) solves, zones and prices
  // exactly as the fixture's spliced station (riser GR1 → PRV0 + a 0 m RUN
  // PRV0 → GR0).
  test('D-4: the PRV placed with insertComponentOnRiser = the spliced '
      'fixture', () async {
    final fixture = await _loadApartment(buildApartment());
    final drawn = await _loadApartment(buildApartment(prvFloor: null));
    final ids = placePrvsByIntent(drawn, [kAptPrvFloor!]);
    final a = prvFingerprint(fixture);
    final b = prvFingerprint(drawn, {for (final e in ids.entries) e.value: e.key});
    // ignore: avoid_print
    if (_dump) print([for (final l in {...a}.difference({...b})) '- $l', for (final l in {...b}.difference({...a})) '+ $l'].join('\n'));
    expect(b, a);
    fixture.dispose();
    drawn.dispose();
  });

  // ── Hand-derived pins (reviewer pass 2, 2026-11-13) ─────────────────────
  group('hand values (app providers)', () {
    late ProviderContainer before;
    late ProviderContainer c;
    setUpAll(() async {
      before = await _loadApartment(buildApartment(prvFloor: null));
      c = await _loadApartmentDrawnPrv();
    });
    tearDownAll(() {
      before.dispose();
      c.dispose();
    });

    test(
      'movers: TP transfer 48.833 m, BS booster 22.230 m on floors 10-11',
      () {
        final duties = c.read(supplyMoverDutiesProvider);
        expect(c.read(transferPumpNodeIdsProvider), {'TP'});
        // Backlog W-1 / W-3 (2026-11-14) — TP: Q = RT's fill flow 10 000 L
        // / 3600 s = 2.77778 L/s (was the 180-UBAP peak 4.39333); lift RT
        // 42.0 − GT 0.0 = 42.000 + friction 0.039839 m/m (DN50 at 2.77778,
        // C150) x 46.0 m (GT → TP 1.0 + TP → U0 4.2 + 11 x 3.5 + U11 → RT
        // 2.3) = 1.833 + the float-valve inlet residual 5.0 ⇒ 48.833 m (was
        // 43.194 on DN65 at 4.39333, 0 m inlet); hydraulic 9810 x 2.77778e-3
        // x 48.833 = 1330.7 W; shaft / 0.70 = 1901.0 W ⇒ 2.2 kW (was 3.0).
        final tp = duties['TP']!;
        expect(tp.flow.inLitersPerSecond, closeTo(2.77778, 5e-5));
        expect(tp.head.meters, closeTo(48.833, 5e-4));
        expect(tp.hydraulicPower.watts, closeTo(1330.7, 0.05));
        expect(tp.shaftPower.watts, closeTo(1901.0, 0.05));
        expect(tp.selectedMotor.inKiloWatts, closeTo(2.2, 1e-9));
        // BS: Q = A → BS 1.07333 L/s; H = (225 − 6.921) / 9.81 = 22.230 m;
        // hydraulic 9810 x 1.07333e-3 x 22.230 = 234.1 W ⇒ 0.37 kW.
        final bs = duties['BS']!;
        expect(bs.flow.inLitersPerSecond, closeTo(1.07333, 5e-5));
        expect(bs.head.meters, closeTo(22.230, 5e-4));
        expect(bs.hydraulicPower.watts, closeTo(234.1, 0.05));
        expect(bs.selectedMotor.inKiloWatts, closeTo(0.37, 1e-9));
        expect(c.read(primarySupplyPumpNodeProvider), 'BS');
        // BS serves only floors 10-11 (16 fixtures).
        final net = c.read(sizingNetworkProvider);
        final m = supplyMovers(
          net,
          c.read(sizingProvider),
          excludeEdgeIds: c.read(parallelLegEdgeIdsProvider),
          rootFlowOf: (_) => const FlowRate(0),
        ).firstWhere((x) => x.nodeId == 'BS');
        final fx = [
          for (final id in m.served)
            if (net.nodeById(id)!.role == NodeRole.fixture) net.nodeById(id)!,
        ];
        expect(fx.length, 16);
        expect({for (final n in fx) n.floorIndex}, {10, 11});
      },
    );

    test(
      'delivered field: boosted floors at target, KSb9 the critical node',
      () {
        final del = c.read(downfeedDeliveredProvider)!;
        // KSb11 = 6.921 + 22.230 x 9.81 = 225.000.
        expect(
          del.residualPressure['KSb11']!.inKiloPascals,
          closeTo(225.0, 2e-3),
        );
        // KSb9 is gravity-fed (74.735) and the delivered critical node.
        expect(del.criticalNodeId, 'KSb9');
        expect(
          del.residualPressure['KSb9']!.inKiloPascals,
          closeTo(74.735, 2e-3),
        );
        // Deliberate finding: below the 225 kPa target, above the SNI 49.033
        // minimum ⇒ the INFO `downfeed-below-target`.
        final hits = [
          for (final i in c.read(designIssuesProvider))
            if (i.kind == 'downfeed-below-target') i,
        ];
        expect(hits.length, 1);
        expect(hits.single.severity, IssueSeverity.info);
        expect(hits.single.locate?.nodeId, 'KSb9');
        // Backlog D-7 (apartment backlog e) — the +15.3 m figure is for the
        // GRAVITY floors below the 225 kPa target that the drawn side-branch
        // booster BS (floors 10-11) does not serve: Lantai 6..10 (indices
        // 5..9; Lantai 1 is behind the PRV at 255, Lantai 2..5 are at or
        // above 225). The message names them and says BS does not serve
        // them; no number changes (75 kPa, 49, 225, +15.3 m).
        expect(
          hits.single.message,
          'The worst-served fixture on "Lantai 10" gets 75 kPa from the roof '
          'tank: the SNI 8153 minimum of 49 kPa is met, but it is below the '
          '225 kPa comfort target. Lantai 6 to Lantai 10 are fed by gravity '
          'and are NOT served by the drawn booster (BS): a separate booster '
          'of about +15.3 m for these floors is recommended.',
        );
        c.read(localeProvider.notifier).set(AppLocale.id);
        final id = c
            .read(designIssuesProvider)
            .singleWhere((i) => i.kind == 'downfeed-below-target');
        expect(id.message, contains('Lantai 6 s.d. Lantai 10 dilayani secara '
            'gravitasi dan TIDAK dilayani oleh booster yang digambar (BS)'));
        expect(id.message, contains('+15.3 m'));
        c.read(localeProvider.notifier).set(AppLocale.en);
      },
    );

    test('PRV: zones [1-11, 0-0]; 8 over-pressure warnings BEFORE, none '
        'AFTER; one station', () {
      for (final x in [before, c]) {
        expect(
          [
            for (final z in x.read(zonesProvider))
              (z.bottomFloorIndex, z.topFloorIndex),
          ],
          [(1, 11), (0, 0)],
        );
        final st = x.read(zoneStaticsProvider);
        // Tank-fed zone: bottom (42.0 − 4.6) x 9.81 = 366.894; PRV zone:
        // 255 + (3.2 − 1.1) x 9.81 = 275.601.
        expect(st[0].bottomStatic.inKiloPascals, closeTo(366.894, 2e-3));
        expect(st[0].viaPrv, isFalse);
        expect(st[1].topResidual.inKiloPascals, closeTo(255.0, 1e-6));
        expect(st[1].bottomStatic.inKiloPascals, closeTo(275.601, 2e-3));
        expect(st[1].viaPrv, isTrue);
      }
      int over(ProviderContainer x) => [
        for (final i in x.read(designIssuesProvider))
          if (i.kind.startsWith('downfeed-over-pressure:')) i,
      ].length;
      expect(over(before), 8);
      expect(before.read(downfeedOverPressureProvider).length, 8);
      for (final o in before.read(downfeedOverPressureProvider)) {
        expect(o.noFlow.inKiloPascals, closeTo(401.229, 2e-3));
      }
      expect(over(c), 0);
      expect(c.read(downfeedOverPressureProvider), isEmpty);
      final del = c.read(downfeedDeliveredProvider)!;
      expect(
        del.noFlowStaticPressure['WCa0']!.inKiloPascals,
        closeTo(275.601, 2e-3),
      );
      // Floor 1 stays on the tank head.
      expect(
        del.noFlowStaticPressure['WCa1']!.inKiloPascals,
        closeTo(366.894, 2e-3),
      );
      final prv = [
        for (final l in c.read(componentTakeoffProvider))
          if (l.component == NodeComponent.prv) l,
      ];
      expect(prv.single.count, 1);
      expect([
        for (final i in c.read(designIssuesProvider))
          if (i.kind.startsWith('pressure-zone')) i,
      ], isEmpty);
    });

    test('rooms: 6400 BTU/h → 0.75 PK, 683.8 W per split AC', () {
      for (final r in c.read(roomAreasProvider)) {
        // 12 m² x 500 x 3.2 / 3.0 = 6400 BTU/h.
        final load = c.read(roomCoolingLoadProvider(r.id))!;
        expect(r.ceilingHeightM, closeTo(3.2, 1e-9));
        expect(load.btuPerHr, closeTo(6400, 1e-6));
        expect(load.recommended.pk, 0.75);
        expect(load.recommended.nominalBtuPerHr, 7000);
      }
      final fed = c.read(nodeFedLoadsProvider);
      for (final id in kAptAcNodeIds) {
        // 7000 / 3.412141633 / 3.0 = 683.8 W.
        expect(fed[id]!.input, closeTo(683.83, 5e-3));
      }
    });
  });

  // ── Hand-derived pins (reviewer pass 4, 2026-11-13): fire + electrical ──
  group('hand values (pass 4): fire and electrical', () {
    late ProviderContainer c;
    setUpAll(() async {
      c = await _loadApartmentDrawnPrv();
    });
    tearDownAll(() => c.dispose());

    test('backlog E-4: genset step load 101.9 kW <= 0.6 x 240 = 144 kW, OK',
        () {
      // On ATS transfer the 300 kVA set picks up PP-E (lift, emergency
      // lighting, the MEP board) in one step: 101 879 W = 101.9 kW (backup
      // fraction 0; 102 768 before backlog W-1 / W-3 took TP 3.0 → 2.2 kW).
      // Allowable first step 0.6 x 300 kVA x 0.8 = 0.6 x 240 = 144 kW >=
      // 101.9 => OK.
      final st = c.read(electricalAdvancedProvider).powerOneLine!
          .gensetStepLoad!;
      expect(st.stepKw, closeTo(101.879, 1e-9));
      expect(st.ratedKw, closeTo(240, 1e-9));
      expect(st.allowableKw, closeTo(144, 1e-9));
      expect(st.exceeded, isFalse);
      expect(
          c
              .read(electricalAdvancedProvider)
              .warnings
              .where((w) => w.code == 'genset-step-load-staged'),
          isEmpty);
    });

    test('fire: standpipe 125.036 m, sprinkler 87.347 m on the enlarged '
        'DN40 feed main, rated 31.545 L/s @ 125.036 m, 75 kW, jockey, '
        'standby', () {
      final b = c.read(fireSystemBasesProvider).single;
      final net = c.read(sizingNetworkProvider);
      final project = c.read(projectControllerProvider);
      final sz = c.read(sizingProvider);
      double len(NetEdge e) => _len(c, e);
      // Standpipe: lift 38.5 + 1.2 = 39.7; hydrant index friction 7.847 m <
      // the 15 m allowance; 690 / 9.81 = 70.336 ⇒ 125.036 m. Backlog D-1:
      // the index box sits at its 1.2 m hose-outlet height (was 1.1 m), so
      // its DN65 @ 5 L/s leg drops 3.2 − 1.2 = 2.0 m from the ceiling main
      // (was 2.1): friction 7.852 → 7.847 m, the head stays on the allowance.
      final fh = fireIndexPathFrictionM(
        net: net,
        system: b.system,
        pumpId: 'FP',
        sizing: sz,
        lengthOf: len,
        terminals: FireTerminalKind.hydrant,
      )!;
      expect(fh, closeTo(7.847, 5e-4));
      expect(
        b.system.staticLiftM(net, project.building, FireTerminalKind.hydrant),
        closeTo(39.7, 1e-9),
      );
      expect(
        b.standpipe!.requiredFlow.inLitersPerSecond,
        closeTo(31.5451, 5e-4),
      );
      expect(b.standpipe!.pumpHead.meters, closeTo(125.036, 5e-4));
      // Sprinkler point: lift to the top ceiling 41.7 + 50 kPa / 9.81 =
      // 5.097 + the sized index friction. Reference tower T2: on the
      // velocity-sized DN32 feed main the friction was 80.257 m (127.054 m >
      // the 125.036 m standpipe head), so the feed main FH→S0→…→S11 is
      // enlarged one step to DN40 (cap: the DN100 standpipe riser): friction
      // 40.550 m ⇒ 87.347 m <= 125.036.
      final fs = fireIndexPathFrictionM(
        net: net,
        system: b.system,
        pumpId: 'FP',
        sizing: sz,
        lengthOf: len,
        terminals: FireTerminalKind.sprinkler,
      )!;
      expect(fs, closeTo(40.550, 5e-4));
      expect(
        b.system.staticLiftM(net, project.building, FireTerminalKind.sprinkler),
        closeTo(41.7, 1e-9),
      );
      expect(
        c.read(sprinklerRemoteAreaProvider).remoteHeadPressure.inKiloPascals,
        closeTo(50.0, 1e-9),
      );
      expect(41.7 + 50 / 9.81 + fs, closeTo(87.347, 5e-4));
      // The standpipe point governs both flow and head.
      expect(b.sprinklerGovernsCombined, isFalse);
      expect(b.flow.inLitersPerSecond, closeTo(31.5451, 5e-4));
      expect(b.head.meters, closeTo(125.036, 5e-4));
      final d = c.read(firePumpDutyProvider)!;
      // 9810 x 0.0315451 x 125.036 = 38 693.4 W; / 0.70 = 55 276.3 W.
      expect(d.hydraulicPower.watts, closeTo(38693.4, 0.05));
      expect(d.shaftPower.watts, closeTo(55276.3, 0.05));
      final r = b.rating;
      // Churn 1.4 x 125.0364 = 175.051; overload 1.5 Q @ 0.65 H = 81.274 m,
      // shaft 0.975 x 38 693.4 / 0.595 = 63 405.2 W ⇒ still 75 kW.
      expect(r.churn.head.meters, closeTo(175.051, 5e-4));
      expect(r.overload.flow.inLitersPerSecond, closeTo(47.3176, 5e-4));
      expect(r.overload.head.meters, closeTo(81.274, 5e-4));
      expect(r.overload.shaftPower.watts, closeTo(63405.2, 0.05));
      expect(r.selectedMotor.inKiloWatts, closeTo(75, 1e-9));
      // Fed input 75 / 0.9 = 83 333.3 W.
      expect(c.read(nodeFedLoadsProvider)['FP']!.input, closeTo(83333.3, 0.05));
      // Jockey 1 % = 0.31545 L/s @ churn + 5 = 180.051 m, 1.1 kW.
      final j = c.read(fireJockeyDutyProvider)!;
      expect(j.flow.inLitersPerSecond, closeTo(0.31545, 5e-5));
      expect(j.head.meters, closeTo(180.051, 5e-4));
      expect(j.selectedMotor.inKiloWatts, closeTo(1.1, 1e-9));
      // Standby FPS: same machine, demand factor 0.
      final bind = c.read(mepDutyBindingProvider);
      expect(bind.fireStandbyPumpNodeIds, {'FPS'});
      expect(bind.fireJockeyPumpNodeIds, {'FJ'});
      final mepWays = c
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == 'mep-equipment')
          .circuits;
      expect(mepWays.firstWhere((w) => w.id == 'mep-node-FPS').demandFactor, 0);
      // Pipes: pump train and header DN125 at the rated 31.545 L/s, hydrant
      // risers DN100, boxes DN65 at 5 L/s, sprinkler feed main (FH→S0 and
      // the riser) enlarged to DN40 at 4.714 (T2),
      // the heads' line DN32 / DN25, jockey legs DN25 at 0.3155.
      for (final id in [
        'e_fh_FT_FP',
        'e_fh_FP_FH',
        'e_fh_FT_FPS',
        'e_fh_FPS_FH',
        'e_fh_FH_H0', //
      ]) {
        expect(sz[id]!.diameter.inMillimeters, 125, reason: id);
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(31.5451, 5e-4));
      }
      for (var f = 1; f < kAptFloors; f++) {
        expect(sz['e_fh_H${f - 1}_H$f']!.diameter.inMillimeters, 100);
        expect(sz['e_sp_S${f - 1}_S$f']!.diameter.inMillimeters, 40);
        expect(
          sz['e_sp_S${f - 1}_S$f']!.flow.inLitersPerSecond,
          closeTo(4.71405, 5e-5),
        );
      }
      for (var f = 0; f < kAptFloors; f++) {
        final id = 'e_fh_H${f}_HYD$f';
        expect(sz[id]!.diameter.inMillimeters, 65);
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(5.0, 1e-9));
      }
      const spLine = <String, (double, int)>{
        'e_sp_FH_S0': (4.71405, 40), // the feed main, enlarged (T2)
        'e_sp_S11_SP1': (4.71405, 32),
        'e_sp_SP1_SP2': (4.71405, 32),
        'e_sp_SP2_SP3': (3.77124, 32),
        'e_sp_SP3_SP4': (2.82843, 25),
        'e_sp_SP4_SP5': (1.88562, 25),
        'e_sp_SP5_SP6': (0.94281, 25),
      };
      for (final MapEntry(key: id, value: (q, dn)) in spLine.entries) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(q, 5e-5), reason: id);
        expect(sz[id]!.diameter.inMillimeters, dn, reason: id);
      }
      for (final id in ['e_fh_FT_FJ', 'e_fh_FJ_FH']) {
        expect(sz[id]!.diameter.inMillimeters, 25);
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(0.31545, 5e-5));
      }
    });

    test('drawing backlog C-2: the riser stands every board on its own floor '
        '(PP-Lt N / PP-L N on Lantai N, the rest on Lantai 1)', () {
      final e = c.read(electricalProjectProvider);
      final floorOf = electricalRiserFloorOf(e, c.read(electricalResultProvider),
          c.read(projectControllerProvider).building);
      expect(e.panels, isNotEmpty);
      for (final p in e.panels) {
        expect(p.floorIndex, referenceBoardFloor(p.name), reason: p.name);
        expect(floorOf[p.id], referenceBoardFloor(p.name), reason: p.name);
      }
    });

    test('floor boards (each of 12) and their feeders', () {
      final sys = c.read(electricalResultProvider);
      final lv = sys.panels[kAptMainPanelId]!;
      // Ways at 231 V: lighting 400 / (231 x 0.9) = 1.924; corridor 300 →
      // 1.443; socket run 1500 / (231 x 0.9) = 7.215, design x 0.7 = 5.051;
      // AC run 900 / (231 x 0.85) = 4.584, design x 0.9 = 4.125.
      const ways =
          <
            String,
            ({
              double ib,
              double run,
              int mcb,
              String curve,
              double csa,
              double vd,
              bool rcd,
            })
          >{
            'lampu_a': (
              ib: 1.924,
              run: 1.924,
              mcb: 6,
              curve: 'b',
              csa: 1.5,
              vd: 0.33,
              rcd: false,
            ),
            'lampu_b': (
              ib: 1.924,
              run: 1.924,
              mcb: 6,
              curve: 'b',
              csa: 1.5,
              vd: 0.44,
              rcd: false,
            ),
            'kk_a': (
              ib: 5.051,
              run: 7.215,
              mcb: 10,
              curve: 'c',
              csa: 2.5,
              vd: 0.75,
              rcd: true,
            ),
            'kk_b': (
              ib: 5.051,
              run: 7.215,
              mcb: 10,
              curve: 'c',
              csa: 2.5,
              vd: 1.00,
              rcd: true,
            ),
            'ac_a': (
              ib: 4.125,
              run: 4.584,
              mcb: 6,
              curve: 'c',
              csa: 2.5,
              vd: 0.36,
              rcd: false,
            ),
            'ac_b': (
              ib: 4.125,
              run: 4.584,
              mcb: 6,
              curve: 'c',
              csa: 2.5,
              vd: 0.51,
              rcd: false,
            ),
            'lampu_koridor': (
              ib: 1.443,
              run: 1.443,
              mcb: 6,
              curve: 'b',
              csa: 1.5,
              vd: 0.41,
              rcd: false,
            ),
          };
      // Feeder VD own grows with 10 + 3.5 x floor.
      const feederVd = [
        0.18,
        0.24,
        0.30,
        0.37,
        0.43,
        0.49,
        0.55,
        0.62,
        0.68,
        0.74,
        0.80,
        0.87, //
      ];
      for (var f = 0; f < kAptFloors; f++) {
        final p = sys.panels[aptFloorPanelId(f)]!;
        final t = 'lt${f + 1}';
        for (final MapEntry(key: base, value: x) in ways.entries) {
          final r = p.circuits.firstWhere((w) => w.circuitId == 'c_${base}_$t');
          expect(r.designCurrentExactA, closeTo(x.ib, 5e-4), reason: base);
          expect(r.runCurrentA.amperes, closeTo(x.run, 0.05), reason: base);
          expect(r.breaker.ratingA.amperes, x.mcb, reason: base);
          expect(r.breaker.curve.name, x.curve, reason: base);
          expect(r.cable.csaMm2, x.csa, reason: base);
          expect(r.grounding.cores, 3, reason: base);
          expect(r.voltageDrop.dropPercent, closeTo(x.vd, 1e-9), reason: base);
          expect(r.rcd.required, x.rcd, reason: base);
          if (x.rcd) expect(r.rcd.ratingMa, 30);
          // Cumulative = feeder + own, within the 3 / 5 % limits.
          expect(
            r.cumulativeDropPercent,
            closeTo(feederVd[f] + x.vd, 1e-9),
            reason: base,
          );
          expect(
            r.cumulativeDropPercent,
            lessThanOrEqualTo(r.voltageDrop.limitPercent),
          );
        }
        // 1100 + 0.7 x 3000 + 0.9 x 1800 = 4820 W; VA 1100 / 0.9 + 2100 /
        // 0.9 + 1620 / 0.85 = 5461 VA.
        expect(p.demandW, closeTo(4820, 1e-6));
        expect(p.demandVa, closeTo(5461, 0.5));
        // Lines {5.051 + 1.924 + 1.443, 4.125 x 2, 5.051 + 1.924}.
        expect(
          [p.phaseBalance.l1, p.phaseBalance.l2, p.phaseBalance.l3]..sort(),
          [7.0, 8.3, 8.4],
        );
        expect(p.incomer.breaker.ratingA.amperes, 10);
        expect(p.incomer.poles, 4);
        // Feeder: Ib 8.4 (worst line); load-sized 10 A, selectivity floor 1.6
        // x 10 = 16 A within Iz 28 of 4 mm² ⇒ MCB 16 A C 3P, NYY 5 x 4.
        final fd = lv.circuits.firstWhere(
          (w) => w.circuitId == aptFloorFeederId(f),
        );
        expect(fd.designCurrent.amperes, 8.4);
        expect(fd.breaker.ratingA.amperes, 16);
        expect(fd.breaker.curve.name, 'c');
        expect(fd.threePhase, isTrue);
        expect(fd.cable.csaMm2, 4);
        expect(fd.grounding.cores, 5);
        expect(fd.grounding.cableType, 'NYY');
        expect(fd.voltageDrop.dropPercent, closeTo(feederVd[f], 1e-9));
        expect(fd.lengthM, closeTo(10 + 3.5 * f, 1e-9));
      }
      final codes = [for (final w in c.read(electricalAllWarningsProvider)) w];
      expect(
        codes.where(
          (w) =>
              w.code == 'non-selective' &&
              (w.circuitId ?? '').startsWith('c_feeder_lt'),
        ),
        isEmpty,
      );
    });

    test('PP-E, MEP board, LVMDP, daya', () {
      final sys = c.read(electricalResultProvider);
      final project = c.read(electricalProjectProvider);
      ElectricalCircuitResult way(String panel, String id) =>
          sys.panels[panel]!.circuits.firstWhere((w) => w.circuitId == id);
      List<double> lines(String panel) {
        final p = sys.panels[panel]!;
        return [p.phaseBalance.l1, p.phaseBalance.l2, p.phaseBalance.l3]
          ..sort();
      }

      // PP-E: Lift 11 kW / 0.88 = 12 500 W; 12 500 / (√3 x 400 x 0.85) =
      // 21.226 A, MCB 25 A D 3P, 4 x 10 mm² (raised for ADS).
      final lift = way(kAptEssentialPanelId, kAptLiftWayId);
      expect(lift.loadW, closeTo(12500, 1e-6));
      expect(lift.designCurrentExactA, closeTo(21.226, 5e-4));
      expect(lift.breaker.ratingA.amperes, 25);
      expect(lift.breaker.curve.name, 'd');
      expect(lift.threePhase, isTrue);
      expect(lift.cable.csaMm2, 10);
      expect(lift.grounding.cores, 4);
      // Lampu darurat 600 / (231 x 0.9) = 2.886 A, 6 A B.
      final el = way(kAptEssentialPanelId, kAptEmergencyLightWayId);
      expect(el.designCurrentExactA, closeTo(2.886, 5e-4));
      expect(el.breaker.ratingA.amperes, 6);
      expect(el.breaker.curve.name, 'b');
      final pe = sys.panels[kAptEssentialPanelId]!;
      // Backlog W-1 / W-3 (2026-11-14): the transfer pump TP drops 3.0 →
      // 2.2 kW (see the movers test), its way 3000 / 0.9 = 3333.3 → 2200 /
      // 0.9 = 2444.4 W (−888.9 W, −888.9 / 0.85 = −1045.8 VA, −1.509 A on
      // each line: 5.660 → 4.151 A). 88 779 + 12 500 + 600 = 101 879 W
      // (was 102 768); 119 818 VA (was 120 864).
      expect(pe.demandW, closeTo(101879, 0.5));
      expect(pe.demandVa, closeTo(119818, 0.5));
      expect(lines(kAptEssentialPanelId), [172.5, 173.1, 173.1]);
      expect(pe.incomer.breaker.ratingA.amperes, 200);
      expect(pe.incomer.breaker.deviceClass, BreakerClass.mccb);
      expect(pe.incomer.poles, 4);
      // Its feeder on LVMDP: Ib 173.1 (was 174.6), MCCB 200 C, FRC 4 x 70 +
      // 35 (0.47 %, was 0.48).
      // Bounded B-1 (2026-11-13): its 1.6 x 200 = 320 ⇒ 400 A rung would sit
      // above LVMDP's own 315 A incomer and need FRC 185 mm² (four sizes up
      // from 70), so the growth is refused: the cable and the device-only
      // floor (largest rung under Iz 222 = 200 A) stay, `non-selective` kept.
      final fpe = way(kAptMainPanelId, kAptEssentialFeederId);
      expect(fpe.designCurrent.amperes, 173.1);
      expect(fpe.breaker.ratingA.amperes, 200);
      expect(fpe.grounding.cableType, 'FRC');
      expect(fpe.cable.csaMm2, 70);
      expect(fpe.cableRaisedForSelectivity, isFalse);
      expect(fpe.voltageDrop.dropPercent, closeTo(0.47, 1e-9));

      // MEP board. FLA = input / (√3 x 400 x 0.85).
      const mep = 'mep-equipment';
      // TP 2444.4 / (√3 x 400 x 0.85) = 4.151 A (was 3333.3 W, 5.660 A).
      expect(way(mep, 'mep-node-TP').designCurrentExactA, closeTo(4.151, 5e-4));
      expect(way(mep, 'mep-node-BS').designCurrentExactA, closeTo(0.698, 5e-4));
      final fp = way(mep, 'mep-node-FP');
      expect(fp.loadW, closeTo(83333.3, 0.05));
      expect(fp.designCurrentExactA, closeTo(141.507, 5e-4));
      expect(fp.breaker.ratingA.amperes, 160);
      expect(fp.breaker.deviceClass, BreakerClass.mccb);
      expect(fp.grounding.cableType, 'FRC');
      expect(fp.cable.csaMm2, 70);
      expect(fp.grounding.peCsaMm2, 35);
      // Iz 222 >= 1.25 x 141.507 = 176.9.
      expect(fp.cable.deratedIz.amperes, 222);
      expect(fp.rcd.required, isFalse);
      final fps = way(mep, 'mep-node-FPS');
      expect(fps.breaker.ratingA.amperes, 160);
      expect(fps.cable.csaMm2, 70);
      expect(fps.designCurrentExactA, 0); // DF 0
      final fj = way(mep, 'mep-node-FJ');
      expect(fj.designCurrentExactA, closeTo(2.075, 5e-4));
      expect(fj.grounding.cableType, 'FRC');
      final ac = [way(mep, 'mep-node-AC6a'), way(mep, 'mep-node-AC6b')];
      for (final a in ac) {
        // 683.8 / (231 x 0.85) = 3.483 A, 6 A C.
        expect(a.designCurrentExactA, closeTo(3.483, 5e-4));
        expect(a.breaker.ratingA.amperes, 6);
        expect(a.breaker.curve.name, 'c');
      }
      expect(ac[0].phase, isNot(ac[1].phase));
      final m = sys.panels[mep]!;
      // 2444.4 + 411.1 + 83 333.3 + 1222.2 + 2 x 683.8 = 88 779 W (was
      // 89 668 with TP 3333.3); 104 446 VA (was 105 491).
      expect(m.demandW, closeTo(88779, 0.5));
      expect(m.demandVa, closeTo(104446, 0.5));
      expect(lines(mep), [148.4, 151.9, 151.9]);
      expect(m.incomer.breaker.ratingA.amperes, 160);
      expect(m.incomer.poles, 4);
      final mepFeeder = project.panels
          .firstWhere((p) => p.id == kAptEssentialPanelId)
          .circuits
          .firstWhere((w) => w.feedsPanelId == mep);
      expect(mepFeeder.cableType, 'FRC');

      // LVMDP: 101 879 + 12 x 4820 = 159 719 W (was 160 608); 185 355 VA
      // (was 186 401); lines 173.1 + 4 x (8.4 + 8.3 + 7.0) = 267.9 (was
      // 269.4).
      final lv = sys.panels[kAptMainPanelId]!;
      expect(lv.demandW, closeTo(159719, 0.5));
      expect(lv.demandVa, closeTo(185355, 0.5));
      expect(lines(kAptMainPanelId), [267.3, 267.9, 267.9]);
      // Service floor 197 000 / (√3 x 400) = 284.3 A ⇒ MCCB 315 A 4P.
      expect(lv.incomer.sizingCurrent!.amperes, closeTo(284.3, 1e-9));
      expect(lv.incomer.breaker.ratingA.amperes, 315);
      expect(lv.incomer.poles, 4);
      final adv = c.read(electricalAdvancedProvider);
      // Basis √3 x 400 x 267.9 = 185.6 kVA ⇒ 197 000 VA (unchanged), LV, no
      // transformer.
      expect(adv.recommendedDayaVa, 197000);
      expect(adv.recommendedDayaThreePhase, isTrue);
      expect(adv.supply.lvOrMv.name, 'lv');
      expect(adv.supply.transformerKva, isNull);
    });

    test('genset: 127.35 kVA running, 286.83 kVA start floor ⇒ 300 kVA', () {
      final sys = c.read(electricalResultProvider);
      final project = c.read(electricalSizingProjectProvider);
      // Running: max(the per-phase 173.1 x √3 x 400 = 119 927, 101 879 /
      // 0.8 = 127 348.75) = 127.35 kVA (128.46 before backlog W-1 / W-3).
      expect(
        requiredGeneratorKva(
          gensetBackupDemandVa(project, sys),
          backupPower: gensetBackupDemandW(project, sys),
        ),
        closeTo(127.34875, 5e-3),
      );
      // FP start: 6.5 x 141.507 (→ 141.5) A x √3 x 400 = 637.39 kVA; x 0.15
      // x 75 / 25 = 286.83 kVA.
      expect(
        gensetStartFloorFor(project, sys).inKilovoltAmperes,
        closeTo(286.83, 5e-3),
      );
      final gen = project.sources!.generator!;
      final r = sizeGenerator(
        gensetBackupDemandVa(project, sys),
        mode: gen.mode,
        transfer: gen.transfer,
        backupPower: gensetBackupDemandW(project, sys),
        minKvaForStart: gensetStartFloorFor(project, sys),
      );
      expect(r.ratingKva.inKilovoltAmperes, 300);
      expect(r.units, 1);
      final gs = c.read(electricalAdvancedProvider).powerOneLine!.gensetStart!;
      expect(gs.startingKva.inKilovoltAmperes, closeTo(637.39, 5e-3));
      expect(gs.estimatedDipPct, closeTo(24.17, 1e-9));
      // Alternator fault 300 000 / (√3 x 400 x 0.12) = 3608 A: no way fails.
      expect(300000 / (1.7320508075688772 * 400 * 0.12), closeTo(3608.4, 0.05));
      expect(
        c.read(electricalAdvancedProvider).gensetAdsFailedCircuitIds,
        isEmpty,
      );
    });

    test('Review: deliberate findings present, the rest absent', () {
      final issues = c.read(designIssuesProvider);
      final kinds = [for (final i in issues) i.kind];
      int count(String k) => kinds.where((x) => x == k).length;
      // Backlog A-3 — churn 1.4 x 125.036 = 175.051 m x 9.81 = 1717.2 kPa:
      // 1600 < 1717.2 <= 2413 ⇒ PN25, no zone-split warning.
      expect(count('fire-system-over-pressure:FP'), 0);
      final cls = c.read(firePressureClassesProvider).single;
      expect(cls.churnKpa, closeTo(175.051 * 9.81, 0.05));
      expect(cls.pressureClass, FirePressureClass.pn25);
      // Backlog A-2 — FT 60 000 L >= 31.545 L/s x 1800 s = 56 781 L.
      expect(kinds.where((k) => k.startsWith('fire-tank-')), isEmpty);
      final ft = c.read(fireTankReservesProvider).single;
      expect(ft.tankId, 'FT');
      expect(ft.requiredLitres, closeTo(31.5451 * 1800, 0.5));
      expect(ft.capacityLitres, 60000);
      expect(ft.verdict, FireTankVerdict.ok);
      // Backlog A-3 — static 9.81 x (175.051 - (3.5 f + 1.2)) > 1207 for
      // f <= 14: every floor 0..11 (1705.5 .. 1327.8 kPa) is designated
      // pressure-regulating (info), no warning.
      expect(count('standpipe-prv-hose-valves:FP:0-11'), 1);
      expect(kinds.where((k) => k.startsWith('standpipe-outlet-over-pressure')),
          isEmpty);
      final r = c.read(standpipeOutletOverPressureProvider).single;
      expect(r.maxKpa, closeTo(9.81 * (175.051 - 1.2), 0.05));
      expect(r.minKpa, closeTo(9.81 * (175.051 - 3.5 * 11 - 1.2), 0.05));
      expect(c.read(prvHoseValvesProvider), hasLength(12));
      // Bounded B-1: both feeders keep `non-selective` (as at 3f4e78c), now
      // naming a selective device: Feeder PP-E's 400 A rung would sit above
      // LVMDP's 315 A incomer, Feeder to MEP's 315 A rung (1.6 x 160 = 256)
      // above PP-E's own 200 A incomer. No selectivity raise puts a device
      // above its incomer.
      expect(count('electrical:non-selective'), 2);
      expect(count('electrical:outgoing-exceeds-incomer'), 0);
      expect(count('electrical:enclosure-temp-rise-exceeded'), 1);
      // Reference tower T2: the enlarged feed main hands the head back to
      // the standpipe, so the combined-governs info is gone.
      expect(count('combined-fire-sprinkler-governs:FP'), 0);
      expect(count('downfeed-below-target'), 1);
      expect(count('electrical:cable-raised-for-ads'), 1);
      expect(count('electrical:fire-pump-protection'), 3);
      expect(
        issues.where((i) => i.severity == IssueSeverity.critical),
        isEmpty,
      );
      for (final prefix in [
        'electrical:ads-disconnection-on-genset',
        'electrical:life-safety',
        'electrical:service-capacity-below-demand',
        'pressure-zone',
        'downfeed-over-pressure',
        'unfed-panel',
      ]) {
        expect(
          kinds.where((k) => k.startsWith(prefix)),
          isEmpty,
          reason: prefix,
        );
      }
      expect(
        c
            .read(electricalAllWarningsProvider)
            .where(
              (w) =>
                  w.severity.name == 'error' || w.severity.name == 'critical',
            ),
        isEmpty,
      );
    });
  });

  // Backlog B-1 / B-2 — the copper of the auto-sized cables, on record in
  // docs/REFERENCE-BUILDINGS.md (REF_DUMP=1 prints it).
  test('(REF_DUMP) auto-sized copper total', () async {
    if (!_dump) return;
    final c = await _loadApartment(buildApartment());
    // ignore: avoid_print
    print('COPPER apartment ${autoSizedCopperMm2M(c).toStringAsFixed(0)} mm2.m');
    c.dispose();
  });

  // Backlog W-4 (2026-11-14) — daily demand and water reserve: 4 persons x 2 units x 12 floors = 96 x 120 L/person/day (private) = 11 520 L = 11.52 m3/day; stored GT 20 000 + RT 10 000 = 30 000 L; reserve 30 000 / 11 520 = 2.6042 days.
  test('backlog W-4: daily demand 11.52 m3/day, reserve 2.6 days', () async {
    final c = await _loadApartmentDrawnPrv();
    expect(c.read(populationProvider), 96);
    expect(c.read(demandPerPersonProvider), 120.0);
    expect(c.read(dailyDemandLitresProvider), closeTo(11520.0, 1e-9));
    final r = c.read(waterReserveProvider);
    // GT + RT counted (the fire tank FT is fire-only, not domestic).
    expect([for (final t in r.counted) t.tankId], ['GT', 'RT']);
    expect(r.excludedTankIds, isEmpty);
    expect(r.storedLitres, closeTo(30000.0, 1e-9));
    expect(r.days, closeTo(2.604167, 5e-5));
    expect(formatReserveDays(r.days!), '2.6 days');
    final kinds = [for (final i in c.read(designIssuesProvider)) i.kind];
    expect(kinds, isNot(contains('daily-demand-unset')));
    c.dispose();
  });
}
