// Round 48 (mech-convergence-3-fire-pressure-rating-unjudged) — a fire pump
// whose churn pressure exceeds the 175 psi sprinkler-component rating raises
// a locatable, judge-only Review warning.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x, {
  int floor = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: 0,
  floorIndex: floor,
  role: role,
  component: c,
);

NetEdge _e(
  String id,
  String a,
  String b, {
  ServiceType s = ServiceType.fireSprinkler,
  EdgeKind k = EdgeKind.run,
}) => NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// GT -> FP -> a sprinkler riser Q0..Q(n-1) with [heads] heads per storey
/// (3 m apart, 0.01 m/px); with [hydrant] the riser is a hydrant stack with
/// a hose box per storey instead (no sprinklers).
Network _tower(int floors, {int heads = 6, bool hydrant = false}) {
  final s = hydrant ? ServiceType.fireHydrant : ServiceType.fireSprinkler;
  return Network(
    nodes: [
      _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('FP', 50, role: NodeRole.plant, c: NodeComponent.pump),
      for (var f = 0; f < floors; f++) ...[
        _n('Q$f', 150, floor: f),
        if (hydrant)
          _n(
            'HB$f',
            200,
            floor: f,
            role: NodeRole.fixture,
            c: NodeComponent.hydrantBox,
          )
        else
          for (var h = 1; h <= heads; h++)
            _n(
              'H$f-$h',
              150 + 300.0 * h,
              floor: f,
              role: NodeRole.fixture,
              c: NodeComponent.sprinklerHead,
            ),
      ],
    ],
    edges: [
      _e('g', 'GT', 'FP', s: s),
      _e('p', 'FP', 'Q0', s: s),
      for (var f = 0; f < floors; f++) ...[
        if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', s: s, k: EdgeKind.riser),
        if (hydrant)
          _e('hb$f', 'Q$f', 'HB$f', s: s)
        else
          for (var h = 1; h <= heads; h++)
            _e('b$f-$h', h == 1 ? 'Q$f' : 'H$f-${h - 1}', 'H$f-$h'),
      ],
    ],
  );
}

ProviderContainer _container(Network net, int floors) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < floors; i++) Floor('L$i', const Length(3)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

bool _churnOver(FireSystemBasis b) =>
    1000 * 9.81 * b.rating.churn.head.meters / 1000 >
    kFireComponentMaxPressureKpa;

void main() {
  test('20-storey sprinkler system: churn > 1210 kPa => one warning', () {
    final c = _container(_tower(20), 20);
    final b = c.read(fireSystemBasesProvider).single;
    // The sprinkler pump's churn is 1.4 × its rated head (≥ 19 × 3 m of
    // lift alone ⇒ ≥ 80 m churn); the drawn DN40 riser adds tens of metres
    // of friction on top — the engine's own churn point is above 175 psi.
    expect(b.sprinklerOnly, isTrue);
    expect(_churnOver(b), isTrue);
    final issues = c.read(designIssuesProvider);
    final w = issues.where((i) => i.kind == 'fire-system-over-pressure:FP');
    expect(w, hasLength(1));
    expect(w.single.severity, IssueSeverity.warning);
    expect(w.single.locate?.nodeId, 'FP');
    expect(w.single.message, contains('175 psi'));
    expect(w.single.message, contains('pipe friction'));
  });

  test('3-storey sprinkler system: churn under the rating => no warning', () {
    final c = _container(_tower(3), 3);
    final b = c.read(fireSystemBasesProvider).single;
    expect(_churnOver(b), isFalse);
    expect(
      c
          .read(designIssuesProvider)
          .any((i) => i.kind.startsWith('fire-system-over-pressure')),
      isFalse,
    );
  });

  test('a hydrant-only standpipe is not judged on the sprinkler listing', () {
    // A 13-storey standpipe churns ~1765 kPa (128.5 m rated) — hose valves
    // are high-pressure listed with regulating outlets (NFPA 14): no warning.
    final c = _container(_tower(13, hydrant: true), 13);
    final b = c.read(fireSystemBasesProvider).single;
    expect(_churnOver(b), isTrue);
    expect(
      c
          .read(designIssuesProvider)
          .any((i) => i.kind.startsWith('fire-system-over-pressure')),
      isFalse,
    );
  });
}
