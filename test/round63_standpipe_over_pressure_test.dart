// Round 63 (fire-convergence-15-standpipe-system-pressure-unjudged) — a
// hydrant-only standpipe is judged against the NFPA 14 7.2.1.1 SYSTEM
// maximum of 350 psi = 2413 kPa (SNI 03-1745 follows NFPA 14), the rule that
// forces vertical pressure zones. Judge-only: no size changes.
//
// First principles (storeys 3.5 m, one Class I stack, a box per storey):
//  * 40 storeys: lift to the top box = 39 x 3.5 + 1.2 = 137.7 m, + the
//    690 kPa (70.3 m) Class I residual, + the sized index friction ⇒ a rated
//    head above 208 m; churn = 1.4 x 208 = 291 m = 2856 kPa > 2413 ⇒ over.
//  * 15 storeys: 14 x 3.5 + 1.2 = 50.2 m + 70.3 m + friction (~10-20 m)
//    ⇒ ~135 m rated, churn ~1.4 x 135 = 189 m = ~1855 kPa < 2413 ⇒ under.
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
import 'package:mechx_engine/standards/sni.dart';
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

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
      id: id,
      fromId: a,
      toId: b,
      service: ServiceType.fireHydrant,
      kind: k,
    );

/// GT -> FP -> one hydrant riser Q0..Q(n-1), a hose box on L1..L(n-1).
Network _tower(int floors) => Network(
  nodes: [
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 50, role: NodeRole.plant, c: NodeComponent.pump),
    for (var f = 0; f < floors; f++) ...[
      _n('Q$f', 150, floor: f),
      if (f > 0)
        _n(
          'HB$f',
          200,
          floor: f,
          role: NodeRole.fixture,
          c: NodeComponent.hydrantBox,
        ),
    ],
  ],
  edges: [
    _e('g', 'GT', 'FP'),
    _e('p', 'FP', 'Q0'),
    for (var f = 1; f < floors; f++) ...[
      _e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser),
      _e('hb$f', 'Q$f', 'HB$f'),
    ],
  ],
);

ProviderContainer _container(int floors) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(_tower(floors));
  return c;
}

double _churnKpa(FireSystemBasis b) =>
    1000 * 9.81 * b.rating.churn.head.meters / 1000;

void main() {
  test('the limit is 350 psi = 2413 kPa, surfaced in the verify checklist', () {
    // 350 psi x 6.894757 kPa/psi = 2413.2 kPa.
    expect(350 * 6.894757, closeTo(kStandpipeMaxSystemPressureKpa, 0.5));
    expect(
      const SniProfile().verifyChecklist.any(
        (v) => v.value == 2413.0 && v.citation.contains('NFPA 14'),
      ),
      isTrue,
    );
  });

  test('40-storey single-zone standpipe: churn > 2413 kPa => one warning', () {
    final c = _container(40);
    final b = c.read(fireSystemBasesProvider).single;
    // Rated head >= lift + Class I residual (137.7 + 70.3 = 208 m).
    expect(b.head.meters, greaterThan(137.7 + 70.3));
    expect(b.rating.churn.head.meters, closeTo(1.4 * b.head.meters, 1e-6));
    expect(_churnKpa(b), greaterThan(kStandpipeMaxSystemPressureKpa));
    final over = c.read(fireOverPressureProvider);
    expect(over, hasLength(1));
    expect(over.single.standpipe, isTrue);
    expect(over.single.check.churnKpa, closeTo(_churnKpa(b), 1e-6));
    final issues = c.read(designIssuesProvider);
    final w = issues.where(
      (i) => i.kind == 'standpipe-system-over-pressure:FP',
    );
    expect(w, hasLength(1));
    expect(w.single.severity, IssueSeverity.warning);
    expect(w.single.locate?.nodeId, 'FP');
    expect(w.single.message, contains('350 psi'));
    expect(w.single.message, contains('pressure zones'));
    // Never the sprinkler-component kind on a hydrant-only system.
    expect(
      issues.any((i) => i.kind.startsWith('fire-system-over-pressure')),
      isFalse,
    );
  });

  test('15-storey standpipe: churn under 2413 kPa => no warning', () {
    final c = _container(15);
    final b = c.read(fireSystemBasesProvider).single;
    expect(_churnKpa(b), lessThan(kStandpipeMaxSystemPressureKpa));
    // ... though above the 1210 kPa sprinkler listing it is never judged on.
    expect(_churnKpa(b), greaterThan(kFireComponentMaxPressureKpa));
    expect(c.read(fireOverPressureProvider), isEmpty);
    expect(
      c.read(designIssuesProvider).any((i) => i.kind.contains('over-pressure')),
      isFalse,
    );
  });
}
