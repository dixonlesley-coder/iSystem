// Round 66 (regression-canvas-section-row-feeds-other-sections-board) — on a
// sectioned service the interactive single-line wires the spine's baseline
// row (section 1: TRAFO-1 -> LVMDP-1, the feed-out at y = 0) into a board
// that section's 'feeds ...' caption names — one section numbering on the
// canvas and on the issued single-line ([serviceSectionOfRoot]).
//
// Probe: a dual-transformer service, roots MDP-A (240 kW, no feeders) listed
// before MDP-B (240 kW + a feeder to SDP). Two equal boards on two sections
// put one board on each; sections are numbered by first appearance in the
// solve order, so MDP-A is section 1. The demand / has-feeders order alone
// anchored the canvas on MDP-B, so the row captioned 'feeds MDP-A' was drawn
// feeding MDP-B's card.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/electrical/panel_geometry.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

ElectricalPanel _board(String id, String name, double kw,
        {String? feeds}) =>
    ElectricalPanel(id: id, name: name, circuits: [
      for (var k = 0; k < 4; k++)
        ElectricalCircuit(
            id: '$id-$k',
            name: 'Load $k',
            loadKind: LoadKind.general,
            loadW: kw * 1000 / 4,
            cosPhi: 1,
            phases: 3,
            length: const Length(10)),
      if (feeds != null)
        ElectricalCircuit(
            id: '$id-f',
            name: '$feeds feeder',
            loadKind: LoadKind.feeder,
            length: const Length(20),
            feedsPanelId: feeds),
    ]);

void main() {
  test('the canvas anchor root is on the baseline (section 1) row', () {
    final project = ElectricalProject(
      id: 'p',
      name: 'Dual',
      dualTransformer: true,
      panels: [
        _board('A', 'MDP-A', 240),
        _board('B', 'MDP-B', 200, feeds: 'SDP'),
        _board('SDP', 'SDP', 40),
      ],
    );
    final result = computeSystem(const PuilProfile(), project);
    final sections = serviceSectionOfRoot(project, result);
    expect(sections, {'A': 0, 'B': 1});
    final anchor = serviceRootId(project, result);
    expect(sections[anchor], 0);
    final spine = buildElectricalSourceSpine(
        project: project, result: result, horizontal: true);
    final feeds = [
      for (final p in spine.prims)
        if (p is SldLabel && p.text.startsWith('feeds ')) p,
    ]..sort((a, b) => a.y.compareTo(b.y));
    expect(feeds, hasLength(2));
    final anchorName =
        project.panels.firstWhere((p) => p.id == anchor).name;
    // The baseline row's caption names the board the canvas wires it into.
    expect(feeds.first.text, contains(anchorName));
    expect(feeds.last.text, isNot(contains(anchorName)));
  });

  test('an unsectioned service keeps the has-feeders / demand anchor', () {
    final project = ElectricalProject(
      id: 'p',
      name: 'Single',
      panels: [
        _board('A', 'MDP-A', 240),
        _board('B', 'MDP-B', 200, feeds: 'SDP'),
        _board('SDP', 'SDP', 40),
      ],
    );
    final result = computeSystem(const PuilProfile(), project);
    expect(serviceRootId(project, result), 'B');
  });
}
