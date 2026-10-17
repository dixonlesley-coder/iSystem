// reports-4 — a RUN whose two endpoints sit at different solved §10
// elevations (a ceiling main dropping to a WC, a floor pump rising to the
// ceiling main) includes that vertical leg in its length, so the BOM, the run
// schedule and the friction term all carry the pipe the installer actually
// pulls; the plan label states the horizontal leg's hanging height plus the
// drop instead of the mean of the two ends.
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // Two 4.0 m storeys. Defaults: ceiling drop 0.3 m, fixture height 1.1 m.
  //   main on floor 1  → 4.0 + 4.0 − 0.3 = 7.70 m
  //   WC on floor 1    → 4.0 + 1.1       = 5.10 m
  //   pump (explicit 0.0, ground floor) → main on floor 0 at 4.0 − 0.3 = 3.70
  const building = BuildingLevels([Floor('G', Length(4)), Floor('1', Length(4))]);
  const cal = {'s0': ScaleCalibration(0.01), 's1': ScaleCalibration(0.01)};

  const net = Network(
    nodes: [
      NetNode(
          id: 'pump',
          sheetId: 's0',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
          elevation: Length(0)),
      NetNode(id: 'm0', sheetId: 's0', x: 440, y: 0, floorIndex: 0),
      NetNode(id: 'm1a', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
      NetNode(id: 'm1b', sheetId: 's1', x: 300, y: 0, floorIndex: 1),
      NetNode(
          id: 'wc',
          sheetId: 's1',
          x: 300,
          y: 23,
          floorIndex: 1,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.waterClosetFlushTank),
    ],
    edges: [
      // pump → ceiling main: 440 px × 0.01 = 4.40 m on plan, +3.70 m rise.
      NetEdge(
          id: 'pm', fromId: 'pump', toId: 'm0', service: ServiceType.coldWater),
      // level main on floor 1: 300 px × 0.01 = 3.00 m, no leg.
      NetEdge(
          id: 'mm', fromId: 'm1a', toId: 'm1b', service: ServiceType.coldWater),
      // main → WC branch: 23 px × 0.01 = 0.23 m on plan, 7.70 − 5.10 = 2.60 drop.
      NetEdge(
          id: 'mw', fromId: 'm1b', toId: 'wc', service: ServiceType.coldWater),
    ],
  );

  double len(String id) => edgeLength(net.edgeById(id)!, net,
          calibrationBySheet: cal, building: building)
      .meters;

  test('a run length = horizontal span + the endpoints\' elevation delta', () {
    expect(len('pm'), closeTo(4.40 + 3.70, 1e-9));
    expect(len('mm'), closeTo(3.00, 1e-9));
    expect(len('mw'), closeTo(0.23 + 2.60, 1e-9));
    expect(
        runVerticalLeg(net.edgeById('mm')!, net, building: building).meters, 0);
  });

  test('an uncalibrated run stays zero (never a vertical-only figure)', () {
    final l = edgeLength(net.edgeById('mw')!, net,
        calibrationBySheet: const {}, building: building);
    expect(l.meters, 0);
  });

  test('the BOM metres include every vertical leg', () {
    final sizing = {
      for (final e in net.edges)
        e.id: EdgeSizing(
          edgeId: e.id,
          service: e.service,
          flow: const FlowRate(0.0005),
          diameter: const Diameter(0.025),
          velocity: const Velocity(1.0),
        ),
    };
    final lines = buildBom(
        net: net,
        sizing: sizing,
        calibrationBySheet: cal,
        building: building);
    final total = lines.fold<double>(0, (s, l) => s + l.totalLength.meters);
    // 8.10 + 3.00 + 2.83 = 13.93 m (was 4.40 + 3.00 + 0.23 = 7.63 m).
    expect(total, closeTo(8.10 + 3.00 + 2.83, 1e-9));
  });

  test('plan CL label: the main\'s hanging height + the drop', () {
    final labels = runCentrelineLabels(net, building);
    // Ground-floor main at 3.70 above FFL 0.00; the pump leg is 3.70 m.
    expect(labels['pm'], 'CL +3.70 drop 3.70 m');
    // Level run: bare token (byte-identical to the old mean form).
    expect(labels['mm'], 'CL +3.70');
    // Floor-1 main 7.70 − FFL 4.00 = 3.70; the WC drop 2.60 m.
    expect(labels['mw'], 'CL +3.70 drop 2.60 m');
  });
}
