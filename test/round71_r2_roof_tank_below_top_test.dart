// Round 71 r2 — a roof tank drawn on a NON-top storey is read at that
// floor's surface (Round 71 `nodeElevation`). In a one-sheet project the
// only sheet is the ground floor, so a tank dropped there sits at 0.0 m and
// every fixture can read LOW with nothing explaining why: Review raises the
// locatable info `roof-tank-below-top:<id>`. An explicit elevation / mount
// height (the engineer's datum) or a tank on the top storey raises nothing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

void main() {
  List<DesignIssue> issuesFor(ProviderContainer c) => [
        for (final i in c.read(designIssuesProvider))
          if (i.kind.startsWith('roof-tank-below-top:')) i,
      ];

  void drawTank(ProviderContainer c, int floor,
      {Length? elevation, Length? mountHeight}) {
    c.read(networkControllerProvider.notifier).restoreNetwork(Network(
          nodes: [
            NetNode(
              id: 'rt',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: floor,
              role: NodeRole.plant,
              component: NodeComponent.roofTank,
              elevation: elevation,
              mountHeight: mountHeight,
            ),
          ],
          edges: const [],
        ));
  }

  test('roof tank on L0 of 4 is flagged where it sits', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var i = 0; i < 4; i++) Floor('L$i', const Length(3.5)),
    ]);
    drawTank(c, 0);
    final hits = issuesFor(c);
    expect(hits, hasLength(1));
    expect(hits.single.kind, 'roof-tank-below-top:rt');
    expect(hits.single.severity, IssueSeverity.info);
    expect(hits.single.locate?.nodeId, 'rt');
    expect(hits.single.message, contains('"L0"'));
    expect(hits.single.message, contains('0.00 m'));
  });

  test('top storey, explicit elevation or mount height: no advisory', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var i = 0; i < 4; i++) Floor('L$i', const Length(3.5)),
    ]);
    drawTank(c, 3);
    expect(issuesFor(c), isEmpty);
    drawTank(c, 0, elevation: const Length(14));
    expect(issuesFor(c), isEmpty);
    drawTank(c, 1, mountHeight: const Length(1));
    expect(issuesFor(c), isEmpty);
  });
}
