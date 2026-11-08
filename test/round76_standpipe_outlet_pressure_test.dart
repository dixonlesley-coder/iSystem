// Round 76 (fire-convergence-27-hose-outlet-static-over-175psi-unjudged) —
// every hose outlet of a pumped standpipe is judged against the NFPA 14
// hose-connection limits (judge-only, never resizes):
//   7.2.3.2 — static at pump churn above 175 psi (1207 kPa) needs a PRV;
//   7.2.3.1 — residual at a 1.5 in hose reel above 100 psi (690 kPa).
// A drawn PRV on the outlet's branch (or the riser zone feeding it) clears it.
//
// First principles (storeys 3.5 m, one Class I stack, a box per storey L1+,
// pump datum L0): the churn head is 1.4 x the rated head H (NFPA 20 shut-off
// ceiling). The box on floor f sits at z = 3.5 f + 1.2 m above the datum, so
//   P_static(f) = 9.81 (1.4 H - (3.5 f + 1.2)) kPa
// and it is over when 1.4 H - (3.5 f + 1.2) > 1207 / 9.81 = 123.04 m. A
// 20-storey hotel (H ~ 153 m, churn ~ 214 m) is over on every valve L1..L19
// (even the top one: 214 - 67.7 = 146.6 m = 1438 kPa); a 2-storey standpipe (H = 4.7 + 70.3 + 15 = 90 m allowance basis,
// churn 126 m, L1 static 1190 kPa) is clean.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/standpipe_outlet_pressure.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart' show standpipeVerifyChecklist;
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

/// GT -> FP -> one hydrant riser Q0..Q(n-1), a hose outlet on L1..L(n-1);
/// [prvFloors] put a PRV on that floor's branch (Q -> PRV -> outlet);
/// [zonePrv] puts one PRV on the pump discharge (regulating the whole riser).
Network _tower(
  int floors, {
  Set<int> prvFloors = const {},
  bool zonePrv = false,
  NodeComponent outlet = NodeComponent.hydrantBox,
}) => Network(
  nodes: [
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 50, role: NodeRole.plant, c: NodeComponent.pump),
    if (zonePrv) _n('ZP', 100, c: NodeComponent.prv),
    for (var f = 0; f < floors; f++) ...[
      _n('Q$f', 150, floor: f),
      if (f > 0) ...[
        if (prvFloors.contains(f)) _n('PV$f', 175, floor: f, c: NodeComponent.prv),
        _n('HB$f', 200, floor: f, role: NodeRole.fixture, c: outlet),
      ],
    ],
  ],
  edges: [
    _e('g', 'GT', 'FP'),
    if (zonePrv) ...[
      _e('p', 'FP', 'ZP'),
      _e('pz', 'ZP', 'Q0'),
    ] else
      _e('p', 'FP', 'Q0'),
    for (var f = 1; f < floors; f++) ...[
      _e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser),
      if (prvFloors.contains(f)) ...[
        _e('hv$f', 'Q$f', 'PV$f'),
        _e('hb$f', 'PV$f', 'HB$f'),
      ] else
        _e('hb$f', 'Q$f', 'HB$f'),
    ],
  ],
);

ProviderContainer _container(Network net, int floors) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

/// The static (kPa) at floor [f]'s box at churn, from first principles.
double _staticKpa(double ratedHeadM, int f) =>
    9.81 * (1.4 * ratedHeadM - (3.5 * f + 1.2));

/// Seeded property: for any storey count / height, the flagged floors are
/// exactly the floors whose first-principles churn static exceeds 1207 kPa,
/// and a PRV on each flagged branch clears every one of them.
void _seededProperty() {
  test('seeded: flagged floors == first-principles set; PRVs clear them', () {
    for (var seed = 0; seed < 12; seed++) {
      final n = 2 + (seed * 7919) % 27; // 2..28 storeys
      final hM = 3.0 + ((seed * 31) % 16) / 10; // 3.0..4.5 m
      ProviderContainer make(Network net) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.read(projectControllerProvider.notifier)
          ..setFloors([for (var i = 0; i < n; i++) Floor('L$i', Length(hM))])
          ..setCalibration('s1', const ScaleCalibration(0.01));
        c.read(networkControllerProvider.notifier).loadNetwork(net);
        return c;
      }

      final c = make(_tower(n));
      final b = c.read(fireSystemBasesProvider).single;
      final churn = b.rating.churn.head.meters;
      final expected = <int>{
        for (var f = 1; f < n; f++)
          if (9.81 * (churn - (hM * f + 1.2)) >
              kStandpipeOutletMaxStaticKpa + 1e-9)
            f,
      };
      final got = <int>{
        for (final r in c.read(standpipeOutletOverPressureProvider))
          if (!r.residual)
            for (var f = r.lowFloor; f <= r.highFloor; f++) f,
      };
      expect(got, expected, reason: 'seed $seed n $n h $hM');
      if (expected.isNotEmpty) {
        final cleared = make(_tower(n, prvFloors: expected));
        expect(cleared.read(standpipeOutletOverPressureProvider), isEmpty,
            reason: 'seed $seed');
      }
    }
  });
}

void main() {
  _seededProperty();
  test('the two limits are 175 psi / 100 psi, in the verify checklist', () {
    expect(175 * 6.894757, closeTo(kStandpipeOutletMaxStaticKpa, 0.5));
    expect(100 * 6.894757, closeTo(kHoseStationMaxResidualKpa, 0.6));
    const list = standpipeVerifyChecklist;
    expect(list.any((v) => v.value == 1207.0 && v.citation.contains('7.2.3.2')),
        isTrue);
    expect(list.any((v) => v.value == 690.0 && v.citation.contains('7.2.3.1')),
        isTrue);
  });

  test('20-storey hydrant-only hotel: lower hose valves over 175 psi', () {
    const n = 20;
    final c = _container(_tower(n), n);
    final b = c.read(fireSystemBasesProvider).single;
    final h = b.head.meters;
    expect(b.rating.churn.head.meters, closeTo(1.4 * h, 1e-6));
    // The offending floors from first principles.
    final over = [
      for (var f = 1; f < n; f++)
        if (_staticKpa(h, f) > kStandpipeOutletMaxStaticKpa) f,
    ];
    expect(over.first, 1);
    expect(over.length, greaterThan(5));
    // With the 140 % churn ceiling even the top valve sits 0.4 H + the
    // residual + friction above zero: every valve of this riser is over.
    expect(over.last, n - 1);
    final ranges = c.read(standpipeOutletOverPressureProvider);
    expect(ranges, hasLength(1));
    final r = ranges.single;
    expect(r.residual, isFalse);
    expect(r.lowFloor, 1);
    expect(r.highFloor, over.last);
    expect(r.maxKpa, closeTo(_staticKpa(h, 1), 0.05));
    expect(r.minKpa, closeTo(_staticKpa(h, over.last), 0.05));
    expect(r.lowestOutletId, 'HB1');
    final issues = c
        .read(designIssuesProvider)
        .where((i) => i.kind.startsWith('standpipe-outlet-over-pressure'))
        .toList();
    expect(issues, hasLength(1));
    expect(issues.single.kind,
        'standpipe-outlet-over-pressure:FP:1-${over.last}');
    expect(issues.single.severity, IssueSeverity.warning);
    expect(issues.single.locate?.nodeId, 'HB1');
    expect(issues.single.message, contains('L1-L${over.last}'));
    expect(issues.single.message, contains('175 psi'));
    // The 350 psi system judge is untouched (2150 kPa < 2413).
    expect(c.read(fireOverPressureProvider), isEmpty);
  });

  test('a PRV on every offending branch clears the warning', () {
    const n = 20;
    final base = _container(_tower(n), n);
    final r = base.read(standpipeOutletOverPressureProvider).single;
    final prv = {for (var f = r.lowFloor; f <= r.highFloor; f++) f};
    final c = _container(_tower(n, prvFloors: prv), n);
    expect(c.read(standpipeOutletOverPressureProvider), isEmpty);
    expect(
      c.read(designIssuesProvider).any(
          (i) => i.kind.startsWith('standpipe-outlet-over-pressure')),
      isFalse,
    );
    // A PRV on only the lowest branch leaves the rest flagged.
    final partial = _container(_tower(n, prvFloors: {1}), n);
    final pr = partial.read(standpipeOutletOverPressureProvider).single;
    expect(pr.lowFloor, 2);
    expect(pr.highFloor, r.highFloor);
  });

  test('a zone PRV on the pump discharge regulates the whole riser', () {
    const n = 20;
    final c = _container(_tower(n, zonePrv: true), n);
    expect(c.read(standpipeOutletOverPressureProvider), isEmpty);
  });

  test('a 2-storey standpipe is clean (L1 churn static 1190 kPa)', () {
    final c = _container(_tower(2), 2);
    final b = c.read(fireSystemBasesProvider).single;
    expect(_staticKpa(b.head.meters, 1),
        lessThan(kStandpipeOutletMaxStaticKpa));
    expect(c.read(standpipeOutletOverPressureProvider), isEmpty);
  });

  test('hose reels: the 100 psi residual at the rated flow is judged', () {
    const n = 12;
    final c = _container(_tower(n, outlet: NodeComponent.hoseReel), n);
    final ranges = c.read(standpipeOutletOverPressureProvider);
    final res = ranges.where((r) => r.residual).toList();
    expect(res, isNotEmpty);
    final b = c.read(fireSystemBasesProvider).single;
    // The lowest reel's residual: rated head - its lift - its friction.
    // Friction >= 0 bounds it by the rated head less the lift.
    final r = res.first;
    expect(r.lowFloor, 1);
    expect(r.maxKpa,
        lessThanOrEqualTo(9.81 * (b.head.meters - (3.5 + 1.2)) + 1e-6));
    expect(r.maxKpa, greaterThan(kHoseStationMaxResidualKpa));
    expect(
      c.read(designIssuesProvider).any(
          (i) => i.kind.startsWith('hose-station-over-residual:')),
      isTrue,
    );
  });
}
