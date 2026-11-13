// Backlog G-3 (2026-11-13) — the hot-water recirculation pump's electrical
// way with a DRAWN return.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

NetNode _n(String id,
        {double x = 0,
        double y = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: c,
        fixture: fixture);

NetEdge _hw(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.hotWater);

/// H → M1 .. M4 (10 m each) with a shower off each, the return M4 → R →
/// [pump P →] H drawn back (0.01 m/px).
Network _loop({required bool pump, bool drawnReturn = true}) => Network(
      nodes: [
        _n('H', role: NodeRole.plant),
        for (var i = 1; i <= 4; i++) ...[
          _n('M$i', x: 1000.0 * i),
          _n('S$i',
              x: 1000.0 * i,
              y: 300,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.shower),
        ],
        if (drawnReturn) ...[
          _n('R', x: 4000, y: -500),
          if (pump) _n('P', x: 0, y: -500, role: NodeRole.plant,
              c: NodeComponent.pump),
        ],
      ],
      edges: [
        for (var i = 1; i <= 4; i++) ...[
          _hw('m$i', i == 1 ? 'H' : 'M${i - 1}', 'M$i'),
          _hw('b$i', 'M$i', 'S$i'),
        ],
        if (drawnReturn) ...[
          _hw('r1', 'M4', 'R'),
          if (pump) ...[
            _hw('r2', 'R', 'P'),
            _hw('r3', 'P', 'H'),
          ] else
            _hw('r2', 'R', 'H'),
        ],
      ],
    );

ProviderContainer _c(Network net) {
  final c = ProviderContainer();
  c.read(projectControllerProvider.notifier)
    ..setFloors([Floor('L0', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  List<String> autoIds(ProviderContainer c) =>
      [for (final x in c.read(mepAutoFeedCircuitsProvider)) x.id]..sort();

  test('a DRAWN return with no pump drawn: its recirc way is in the default '
      'sync', () {
    final c = _c(_loop(pump: false));
    addTearDown(c.dispose);
    final sys = c.read(hotWaterRecircSystemsProvider).single;
    expect(sys.drawnReturn, isTrue);
    expect(c.read(mepDutyFeedEnabledProvider), isFalse);
    expect(autoIds(c), ['mep-hw-recirc-pump']);
    final way = c
        .read(mepAutoFeedCircuitsProvider)
        .singleWhere((x) => x.id == 'mep-hw-recirc-pump');
    // The SAME machine the opt-in feed carries (one way, never two).
    final full = c
        .read(mepEquipmentCircuitsProvider)
        .singleWhere((x) => x.id == 'mep-hw-recirc-pump');
    expect(way.loadW, full.loadW);
    expect(way.flaOverrideA, full.flaOverrideA);
    expect(way.motorKw, sys.design.pump.selectedMotor.inKiloWatts);
    // Opt-in on: unchanged (the full feed).
    c.read(mepDutyFeedEnabledProvider.notifier).enable();
    expect(autoIds(c), contains('mep-hw-recirc-pump'));
  });

  test('a pump DRAWN on the return is a placed machine (default, as before)',
      () {
    final c = _c(_loop(pump: true));
    addTearDown(c.dispose);
    expect(c.read(hotWaterRecircSystemsProvider).single.drawnReturn, isTrue);
    expect(c.read(mepDutyBindingProvider).hwRecircPumpNodeIds, {'P'});
    // 0.37 kW / 0.90 = 411.1 W; no duplicate duty way.
    expect(autoIds(c), ['mep-node-P']);
    final p = c.read(mepAutoFeedCircuitsProvider).single;
    expect(p.loadW, closeTo(370 / 0.9, 1e-6));
    expect(c.read(hwRecircDutyLoadsProvider), isEmpty);
  });

  test('only an ASSUMED return: the opt-in still gates the way (unchanged)',
      () {
    final c = _c(_loop(pump: false, drawnReturn: false));
    addTearDown(c.dispose);
    expect(c.read(hotWaterRecircSystemsProvider).single.drawnReturn, isFalse);
    expect(autoIds(c), isEmpty);
    c.read(mepDutyFeedEnabledProvider.notifier).enable();
    expect(autoIds(c), ['mep-hw-recirc-pump']);
  });

  test('order-independent: shuffled node / edge lists mint the same way', () {
    final base = _loop(pump: false);
    final c0 = _c(base);
    addTearDown(c0.dispose);
    final w0 = c0.read(mepAutoFeedCircuitsProvider).single;
    for (var seed = 0; seed < 5; seed++) {
      final rnd = math.Random(seed);
      final c = _c(Network(
          nodes: [...base.nodes]..shuffle(rnd),
          edges: [...base.edges]..shuffle(rnd)));
      final w = c.read(mepAutoFeedCircuitsProvider).single;
      expect(w.id, w0.id);
      expect(w.loadW, w0.loadW);
      c.dispose();
    }
  });
}
