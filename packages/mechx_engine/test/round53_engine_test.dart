// Round 53 (2026-10-18) — engine pins:
//
//   elec-convergence-5-tt-vfd-final-30ma-rcd — a TT final way's RCD IΔn is
//     chosen by what it feeds (VFD 300 mA Type B, fixed motor 100 mA), never
//     30 mA for a 22 kW drive; Ra x IΔn <= 50 V is judged.
//   regression-shared-header-sizer-partitions-on-fireSystems /
//   regression-cross-service-fire-suction-leg-zero-flow /
//   fire-convergence-5-sprinkler-trunk-feeding-hydrant-not-floored-at-
//     standpipe-flow / regression-transfer-pump-rated-class-i-flow — the
//     sizer reads the rating partition, carries fire flow across a service
//     change and rates a transfer line on the zone it fills.
//
// First principles: 1 US gpm = 3.785411784 / 60 L/s; 500 gpm = 31.545 L/s,
// 100 gpm = 6.309 L/s, 750 gpm = 47.318 L/s.
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _gpm = 3.785411784 / 60;
const _profile = PuilProfile();

NetNode _n(String id, double x,
        {int floor = 0, double y = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.fireHydrant, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

ElectricalCircuit _motor(String id, double kw,
        {StarterType? starter, LoadKind kind = LoadKind.pump}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: kind,
      motorKw: kw,
      phases: 3,
      cosPhi: 0.85,
      length: const Length(20),
      starterType: starter,
    );

Map<String, EdgeSizing> _size(Network net, BuildingLevels b,
        {FlowRate? sprinkler, FlowRate? hydrant}) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.005),
        ServiceType.fireSprinkler: FlowRate(0.001),
      },
      sprinklerDemandCap: sprinkler,
      hydrantDesignFlow: hydrant,
      building: b,
    );

void main() {
  group('TT final RCD sensitivity', () {
    test('a VFD way: 300 mA Type B; a fixed motor: 100 mA at 63 A and at 64 A; '
        'a general way keeps 30 mA up to 63 A', () {
      final vfd = circuitRcd(
        earthingSystem: EarthingSystem.tt,
        loadKind: LoadKind.pump,
        isFinalCircuit: true,
        designCurrent: const Current(42.5),
        hasVfd: true,
      );
      expect(vfd.required, isTrue);
      expect(vfd.ratingMa, 300);
      expect(vfd.type, RcdType.b);
      for (final a in [20.0, 63.0, 64.0, 120.0]) {
        for (final k in [LoadKind.motor, LoadKind.pump, LoadKind.hvac]) {
          expect(
              circuitRcd(
                earthingSystem: EarthingSystem.tt,
                loadKind: k,
                isFinalCircuit: true,
                designCurrent: Current(a),
              ).ratingMa,
              100,
              reason: '$k at $a A');
        }
      }
      expect(ttFinalRcdMa(LoadKind.general, designCurrent: const Current(63)),
          30);
      expect(ttFinalRcdMa(LoadKind.general, designCurrent: const Current(64)),
          100);
      expect(ttFinalRcdMa(LoadKind.socket, designCurrent: const Current(16)),
          30);
    });

    test('Ra x IΔn <= 50 V: 5 ohm x 0.3 A = 1.5 V holds; 200 ohm x 0.3 A = '
        '60 V fails', () {
      expect(ttRcdTouchVoltageOk(5, 300), isTrue);
      expect(ttRcdTouchVoltageOk(166, 300), isTrue); // 49.8 V
      expect(ttRcdTouchVoltageOk(200, 300), isFalse); // 60 V
      expect(ttRcdTouchVoltageOk(500, 100), isTrue); // 50 V exactly
    });

    test('a TT factory MDP: two 22 kW VFD pumps -> RCD 300 mA B, a 37 kW '
        'star-delta compressor -> 100 mA; no touch-voltage warning at the '
        '5 ohm electrode target', () {
      final project = ElectricalProject(
        id: 'p',
        name: 'factory',
        earthingSystem: EarthingSystem.tt,
        panels: [
          ElectricalPanel(
            id: 'mdp',
            name: 'MDP',
            voltage: const Voltage(400),
            circuits: [
              _motor('p1', 22, starter: StarterType.vfd),
              _motor('p2', 22, starter: StarterType.vfd),
              _motor('k1', 37,
                  starter: StarterType.starDelta, kind: LoadKind.motor),
            ],
          ),
        ],
      );
      final sys = computeSystem(_profile, project);
      final ways = {
        for (final c in sys.panels['mdp']!.circuits) c.circuitId: c,
      };
      // Ib = 22000 / 0.88 / (sqrt(3) x 400 x 0.85) = 42.45 A <= 63 A: the
      // legacy rule printed 30 mA here.
      expect(ways['p1']!.designCurrent.amperes, lessThan(63));
      expect(ways['p1']!.rcd.ratingMa, 300);
      expect(ways['p1']!.rcd.type, RcdType.b);
      expect(ways['p2']!.rcd.ratingMa, 300);
      expect(ways['k1']!.rcd.ratingMa, 100);
      expect(sys.warnings.where((w) => w.code == 'tt-rcd-touch-voltage'),
          isEmpty);
    });

    test('the kind -> IΔn mapping is on the verify checklist', () {
      expect(
          _profile.verifyChecklist
              .any((v) => '${v.value}'.startsWith('TT final-circuit RCD')),
          isTrue);
    });
  });

  group('fire design flows', () {
    // GT -> TP -> riser -> TT (L10) -> FP2 -> [stacks] stacks of [reels].
    Network transfer({required bool reels, int stacks = 1}) => Network(
          nodes: [
            _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
            _n('TP', 100, role: NodeRole.plant, c: NodeComponent.pump),
            _n('A0', 200),
            _n('A10', 200, floor: 10),
            _n('TT', 300,
                floor: 10, role: NodeRole.plant, c: NodeComponent.groundTank),
            _n('FP2', 400,
                floor: 10, role: NodeRole.plant, c: NodeComponent.pump),
            _n('J', 450, floor: 10),
            for (var s = 0; s < stacks; s++)
              for (var f = 10; f < 20; f++) ...[
                _n('B$s-$f', 500, y: 300.0 * s, floor: f),
                _n('HB$s-$f', 600,
                    y: 300.0 * s,
                    floor: f,
                    role: NodeRole.fixture,
                    c: reels
                        ? NodeComponent.hoseReel
                        : NodeComponent.hydrantBox),
              ],
          ],
          edges: [
            _e('g', 'GT', 'TP'),
            _e('t', 'TP', 'A0'),
            _e('r', 'A0', 'A10', k: EdgeKind.riser),
            _e('a', 'A10', 'TT'),
            _e('s2', 'TT', 'FP2'),
            _e('d2', 'FP2', 'J'),
            for (var s = 0; s < stacks; s++) ...[
              _e('j$s', 'J', 'B$s-10'),
              for (var f = 10; f < 20; f++) ...[
                if (f > 10)
                  _e('q$s-$f', 'B$s-${f - 1}', 'B$s-$f', k: EdgeKind.riser),
                _e('hb$s-$f', 'B$s-$f', 'HB$s-$f'),
              ],
            ],
          ],
        );
    final building = BuildingLevels(
        [for (var i = 0; i < 20; i++) Floor('L$i', const Length(3))]);
    double elev(NetNode n) => nodeElevation(n, building).meters;

    for (final (reels, stacks, expected) in [
      (true, 1, 100 * _gpm),
      (false, 1, 500 * _gpm),
      (false, 2, 750 * _gpm),
    ]) {
      test('a transfer into a ${reels ? 'hose-reel' : '$stacks-stack box'} '
          'zone: fed flow ${expected.toStringAsFixed(3)} L/s, carried on the '
          'transfer pipe', () {
        final net = transfer(reels: reels, stacks: stacks);
        final systems = fireRatingSystems(net);
        final t = systems.firstWhere((s) => s.nodeIds.contains('TP'));
        final tank = fireTransferDestinationTank(net, t, elev)!;
        expect(tank.id, 'TT');
        final fed = fireTransferFedFlow(net, t, tank.id, systems)!;
        expect(fed.inLitersPerSecond, closeTo(expected, 1e-9));
        final sz = _size(net, building,
            hydrant: standpipeFlow(drawnStandpipeRiserCount(net)));
        for (final id in ['g', 't', 'r', 'a']) {
          expect(sz[id]!.flow.inLitersPerSecond, closeTo(expected, 1e-9),
              reason: id);
        }
        // A 100 gpm transfer line takes the hose-station floors (DN50
        // riser), a Class I one the DN100 standpipe floor.
        expect(sz['r']!.diameter.inMillimeters, reels ? 50 : greaterThanOrEqualTo(100));
      });
    }

    test('fireSystemDesignFlow: no terminal -> null; a combined system the '
        'larger of standpipe and remote-area flow', () {
      final net = transfer(reels: false);
      final t = fireRatingSystems(net).firstWhere((s) => s.nodeIds.contains('TP'));
      expect(fireSystemDesignFlow(net, t), isNull);
      final zone = fireRatingSystems(net).firstWhere((s) => s.nodeIds.contains('FP2'));
      expect(fireSystemDesignFlow(net, zone)!.inLitersPerSecond,
          closeTo(500 * _gpm, 1e-9));
    });

    test('a sprinkler-drawn supply main feeding a hydrant branch carries the '
        'hydrant flow (engine path)', () {
      final net = Network(
        nodes: [
          _n('RT', 0, role: NodeRole.plant, c: NodeComponent.roofTank),
          _n('BP', 100, role: NodeRole.plant, c: NodeComponent.boosterSet),
          _n('M', 200),
          for (var k = 1; k <= 6; k++)
            _n('S$k', 200 + 300.0 * k,
                role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
          _n('HJ', 200, y: 400),
          _n('HB', 300,
              y: 400, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
          _n('HB2', 200,
              y: 800, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ],
        edges: [
          _e('rb', 'RT', 'BP', s: ServiceType.fireSprinkler),
          _e('bm', 'BP', 'M', s: ServiceType.fireSprinkler),
          for (var k = 1; k <= 6; k++)
            _e('s$k', k == 1 ? 'M' : 'S${k - 1}', 'S$k',
                s: ServiceType.fireSprinkler),
          _e('mh', 'M', 'HJ'),
          _e('hb', 'HJ', 'HB'),
          _e('hb2', 'HJ', 'HB2'),
        ],
      );
      const b = BuildingLevels([Floor('L0', Length(9))]);
      final sz = _size(net, b,
          sprinkler: const FlowRate(0.012),
          hydrant: standpipeFlow(drawnStandpipeRiserCount(net)));
      final hydrantQ = sz['mh']!.flow.inLitersPerSecond;
      expect(hydrantQ, closeTo(500 * _gpm, 1e-9));
      for (final id in ['rb', 'bm']) {
        expect(sz[id]!.flow.inLitersPerSecond, closeTo(hydrantQ, 1e-9),
            reason: id);
        expect(sz[id]!.diameter.inMillimeters,
            greaterThanOrEqualTo(sz['mh']!.diameter.inMillimeters),
            reason: id);
      }
      // The sprinkler branch keeps its own accumulation: 6 heads x 1 L/s =
      // 6 L/s, under the 12 L/s remote-area cap.
      expect(sz['s1']!.flow.inLitersPerSecond, closeTo(6, 1e-9));
    });
  });
}
