import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// An axis-aligned box in drawing space. A LABEL's box is sized with the SAME
/// per-size character advance the builder uses ([kElectricalRiserLabelCharW]):
/// the baseline is the box's BOTTOM edge, the text rising one `size` above it.
class _Box {
  final double minX, minY, maxX, maxY;
  const _Box(this.minX, this.minY, this.maxX, this.maxY);

  factory _Box.ofLabel(SldLabel l) => _Box(l.x, l.y - l.size,
      l.x + l.text.length * l.size * kElectricalRiserLabelCharW, l.y);

  factory _Box.ofRect(SldRect r) => _Box(r.x, r.y, r.x + r.w, r.y + r.h);

  /// True only when the two boxes share a POSITIVE area — touching edges is not
  /// an overlap (the same test the builder's placer applies).
  bool overlaps(_Box o) =>
      math.min(maxX, o.maxX) - math.max(minX, o.minX) > 0 &&
      math.min(maxY, o.maxY) - math.max(minY, o.minY) > 0;
}

void main() {
  const profile = PuilProfile();

  // A 3-floor building (each 4 m floor-to-floor).
  const building = BuildingLevels([
    Floor('Ground', Length(4)),
    Floor('First', Length(4)),
    Floor('Second', Length(4)),
  ]);

  // LVMDP (floor 0) feeds LP-G (floor 0) + LP-1 (floor 1) + an EMERGENCY board
  // (floor 2) carrying a life-safety way; plus one UNPLACED sub-board.
  const project = ElectricalProject(
    id: 'r1',
    name: 'Riser tower',
    panels: [
      ElectricalPanel(
        id: 'LVMDP',
        name: 'LVMDP',
        layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 100, y: 100),
        circuits: [
          ElectricalCircuit(
              id: 'fg', name: 'Feeder LP-G', loadKind: LoadKind.feeder,
              feedsPanelId: 'LPG', length: Length(10)),
          ElectricalCircuit(
              id: 'f1', name: 'Feeder LP-1', loadKind: LoadKind.feeder,
              feedsPanelId: 'LP1', length: Length(20)),
          ElectricalCircuit(
              id: 'fe', name: 'Feeder EMG', loadKind: LoadKind.feeder,
              feedsPanelId: 'EMG', length: Length(25)),
          ElectricalCircuit(
              id: 'fu', name: 'Feeder UP', loadKind: LoadKind.feeder,
              feedsPanelId: 'UP', length: Length(30)),
        ],
      ),
      ElectricalPanel(
        id: 'LPG', name: 'LP-G', sourceType: PanelSource.feeder,
        layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 300, y: 100),
        circuits: [
          ElectricalCircuit(
              id: 'g1', name: 'Lighting', loadKind: LoadKind.lighting,
              isLighting: true, loadW: 1200, length: Length(12)),
        ],
      ),
      ElectricalPanel(
        id: 'LP1', name: 'LP-1', sourceType: PanelSource.feeder,
        layoutPos: LayoutPos(sheetId: 's', floorIndex: 1, x: 300, y: 100),
        circuits: [
          ElectricalCircuit(
              id: 'l1', name: 'Lighting', loadKind: LoadKind.lighting,
              isLighting: true, loadW: 1500, length: Length(15)),
        ],
      ),
      ElectricalPanel(
        id: 'EMG', name: 'MDP EMERGENCY', sourceType: PanelSource.feeder,
        layoutPos: LayoutPos(sheetId: 's', floorIndex: 2, x: 300, y: 100),
        circuits: [
          ElectricalCircuit(
              id: 'e1', name: 'Smoke fan', loadKind: LoadKind.motor,
              motorKw: 5.5, lifeSafety: true, length: Length(18)),
        ],
      ),
      // No layoutPos ⇒ falls to a feeder-depth tier.
      ElectricalPanel(
        id: 'UP', name: 'PP UNPLACED', sourceType: PanelSource.feeder,
        circuits: [
          ElectricalCircuit(
              id: 'u1', name: 'Sockets', loadKind: LoadKind.general,
              loadW: 2000, length: Length(20)),
        ],
      ),
    ],
  );

  final result = computeSystem(profile, project);

  test('emits one rect per panel + finite bounds', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    expect(sheet.isEmpty, isFalse);
    expect(sheet.prims.whereType<SldRect>().length, project.panels.length);
    expect(sheet.minX.isFinite && sheet.maxX.isFinite, isTrue);
    expect(sheet.maxX, greaterThan(sheet.minX));
    expect(sheet.maxY, greaterThan(sheet.minY));
  });

  test('panels stack by true elevation: higher floor => smaller y', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    double yOf(String name) => sheet.prims
        .whereType<SldLabel>()
        .firstWhere((l) => l.bold && l.text.contains(name))
        .y;
    // floor 0 < floor 1 < floor 2 in elevation ⇒ y descends.
    expect(yOf('LP-G'), greaterThan(yOf('LP-1')));
    expect(yOf('LP-1'), greaterThan(yOf('MDP EMERGENCY')));
  });

  test('the unplaced panel still renders (falls to a tier, no throw)', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    expect(joined, contains('PP UNPLACED'));
  });

  test('the gutter carries the floor names + FFL elevations', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    expect(joined, contains('Ground'));
    expect(joined, contains('First'));
    expect(joined, contains('Second'));
    // FFL tags: floor 1 surface = +4.00, floor 2 = +8.00.
    expect(joined, contains('FFL +0.00'));
    expect(joined, contains('FFL +4.00'));
    expect(joined, contains('FFL +8.00'));
  });

  test('essential propagation matches the overview', () {
    final riser = buildElectricalRiser(
        project: project, result: result, building: building);
    final overview = buildElectricalOverview(project: project, result: result);
    SldRole roleIn(SldSheet s, String name) => s.prims
        .whereType<SldLabel>()
        .firstWhere((l) => l.bold && l.text.contains(name))
        .role;
    for (final name in ['LVMDP', 'LP-G', 'MDP EMERGENCY', 'PP UNPLACED']) {
      expect(roleIn(riser, name), roleIn(overview, name),
          reason: 'role mismatch for $name');
    }
    // The emergency board is essential (red).
    expect(roleIn(riser, 'MDP EMERGENCY'), SldRole.essential);
  });

  test('building: null degrades to feeder-depth tiers (no throw, still rects)',
      () {
    final sheet = buildElectricalRiser(project: project, result: result);
    expect(sheet.prims.whereType<SldRect>().length, project.panels.length);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    // Tier gutter, no FFL elevation labels.
    expect(joined, contains('Tier '));
    expect(joined.contains('FFL '), isFalse);
  });

  test('an empty building level list also degrades gracefully', () {
    const empty = BuildingLevels([]);
    final sheet = buildElectricalRiser(
        project: project, result: result, building: empty);
    expect(sheet.prims.whereType<SldRect>().length, project.panels.length);
  });

  test('an out-of-range floorIndex is clamped (no index throw)', () {
    const oob = ElectricalProject(
      id: 'oob',
      name: 'OOB',
      panels: [
        ElectricalPanel(
          id: 'P',
          name: 'P',
          // floorIndex 9 on a 3-floor building ⇒ clamp to the top floor.
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 9, x: 0, y: 0),
          circuits: [
            ElectricalCircuit(
                id: 'c', name: 'L', loadKind: LoadKind.general, loadW: 500,
                length: Length(5)),
          ],
        ),
      ],
    );
    final r = computeSystem(profile, oob);
    final sheet =
        buildElectricalRiser(project: oob, result: r, building: building);
    expect(sheet.prims.whereType<SldRect>().length, 1);
  });

  test('sourceChain=true prepends a source spine above the top band — the '
      'honest LV head here (nothing declares an MV service)', () {
    final sheet = buildElectricalRiser(
        project: project,
        result: result,
        building: building,
        sourceChain: true);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    // An undeclared (LV) service draws the plain PLN head — never a
    // fabricated MV station / transformer chain.
    expect(joined, contains('PLN'));
    expect(joined, isNot(contains('MV STATION')));
    expect(joined, isNot(contains('TRANSFORMER')));
    expect(
        sheet.prims
            .whereType<SldCircle>()
            .where((c) => c.role == SldRole.source),
        isEmpty);
    expect(sheet.legend.map((e) => e.code), contains('Source'));
  });

  test('sourceChain=true with a DECLARED transformer draws the MV spine '
      'symbols above the top band', () {
    final mv = ElectricalProject(
      id: project.id,
      name: project.name,
      transformerKva: const ApparentPower(400000),
      panels: project.panels,
    );
    final mr = computeSystem(profile, mv);
    final sheet = buildElectricalRiser(
        project: mv, result: mr, building: building, sourceChain: true);
    // The spine draws single-line SYMBOLS: the two transformer winding
    // circles ⇒ at least 2 source circles (not boxes).
    final sourceCircles = sheet.prims
        .whereType<SldCircle>()
        .where((c) => c.role == SldRole.source);
    expect(sourceCircles.length, greaterThanOrEqualTo(2));
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    expect(joined, contains('PLN MV STATION'));
    expect(sheet.legend.map((e) => e.code), contains('Source'));
  });

  test('an empty project yields an empty riser (no panel rects)', () {
    const e = ElectricalProject(id: 'e', name: 'Empty');
    final er = computeSystem(profile, e);
    final sheet =
        buildElectricalRiser(project: e, result: er, building: building);
    expect(sheet.prims.whereType<SldRect>(), isEmpty);
  });

  test('feeder runs carry a cable + breaker annotation', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    // LVMDP feeds LPG / LP1 / EMG / UP — four resolvable feeder labels.
    final feederLabels = sheet.prims
        .whereType<SldLabel>()
        .where((l) => l.text.contains(' mm2 ') && l.text.contains('·'))
        .toList();
    expect(feederLabels.length, project.panels.length - 1);
    for (final l in feederLabels) {
      expect(l.text, matches(RegExp(r'\dx\d')), reason: l.text); // cable cores
      expect(l.text, matches(RegExp(r'(MCB|MCCB) \d+(\.\d+)?A \dph')),
          reason: l.text);
    }
  });

  test('per-floor branch fan-out: a board shows a labelled load-way stub', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    // LP-G distributes a 'Lighting' way; it hangs as a stub with its rating.
    final stub = sheet.prims
        .whereType<SldLabel>()
        .where((l) =>
            l.size == 6 && l.text.startsWith('Lighting') && l.text.contains('A'))
        .toList();
    expect(stub, isNotEmpty);
    expect(joined, contains('Sockets')); // the unplaced board's load way
  });

  test('the compact node sub-line carries kW AND kVA demand', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    final sub = sheet.prims.whereType<SldLabel>().where(
        (l) => !l.bold && l.text.contains('kW') && l.text.contains('kVA'));
    expect(sub, isNotEmpty);
    expect(sub.first.text, matches(RegExp(r'\d+A \dP · .*kW / .*kVA')));
  });

  test('no riser label contains a non-ASCII tofu glyph', () {
    final sheet = buildElectricalRiser(
        project: project, result: result, building: building);
    for (final l in sheet.prims.whereType<SldLabel>()) {
      expect(l.text.contains('Ø'), isFalse, reason: l.text);
      expect(l.text.contains('²'), isFalse, reason: l.text);
      expect(l.text.contains('³'), isFalse, reason: l.text);
    }
  });

  // H5: buildElectricalRiser's per-floor fan-out used to hard-`substring(0,
  // 14)` a circuit name with no ellipsis, producing a mid-word chop like
  // 'Power socke' / 'Lighting - Lev'. It should now cut on a word boundary and
  // append an ASCII ellipsis, and never silently drop the fact it was cut.
  //
  // E-4 (2026-07-30): the fixed 14-char cap itself was replaced by a budget
  // derived from the actual clear space to the next panel / sheet margin (see
  // `electrical_riser_fanout_width_test.dart`), so a lone panel with a wide-
  // open band now gets a MUCH bigger budget than 14 — this fixture's name is
  // lengthened so it still exceeds that (larger, but still finite) budget and
  // exercises the same word-boundary + ellipsis behaviour.
  test('a long circuit name in the fan-out is truncated at a word boundary '
      'with an ellipsis, never mid-word', () {
    const longName = 'Power socket ring circuit serving the west wing '
        'mezzanine store annex block four';
    const longNameProject = ElectricalProject(
      id: 'ln',
      name: 'Long names',
      panels: [
        ElectricalPanel(
          id: 'P1',
          name: 'LP-1',
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 100, y: 100),
          circuits: [
            ElectricalCircuit(
                id: 'c1',
                name: longName,
                loadKind: LoadKind.general,
                loadW: 2000,
                length: Length(10)),
          ],
        ),
      ],
    );
    final r = computeSystem(profile, longNameProject);
    final sheet = buildElectricalRiser(
        project: longNameProject, result: r, building: building);
    final stub = sheet.prims
        .whereType<SldLabel>()
        .where((l) => l.size == 6 && l.text.contains('A'))
        .map((l) => l.text)
        .toList();
    expect(stub, isNotEmpty);
    final label = stub.first;

    // Truncated with an explicit ASCII ellipsis, and the word it was cut at
    // is never split mid-token.
    expect(label, contains('...'), reason: label);
    expect(label, isNot(contains('four')), reason: label);
    final namePart = label.split('...').first;
    final words = longName.split(' ');
    final wordBoundaryPrefixes = [
      for (var i = 1; i <= words.length; i++) words.sublist(0, i).join(' ')
    ];
    expect(wordBoundaryPrefixes, contains(namePart), reason: label);
    // The total budget (name + ellipsis) stays within the SPACE-DERIVED
    // budget (E-4) — the sole panel on its band, so the budget is the clear
    // run from its stub-label x to the sheet's right margin, minus the same
    // clearance/char-advance the builder uses — never the old fixed 14.
    final rect = sheet.prims.whereType<SldRect>().single;
    final labelX = rect.x + 26;
    const fanClearanceX = 10.0;
    final avail = sheet.maxX - labelX - fanClearanceX;
    const charW = 6 * kElectricalRiserLabelCharW;
    final budget = math.max(14, (avail / charW).floor());
    expect(namePart.length + 3, lessThanOrEqualTo(budget));
    // And this scenario's free space genuinely earns a bigger budget than the
    // old fixed cap (the exact bug this fixture now documents the fix for).
    expect(budget, greaterThan(14));
  });

  // ── Feeder-annotation collision (recorded follow-up) ───────────────────────
  // A feeder's cable/breaker tag used to be pinned at the CHILD board's right
  // edge on its horizontal branch. When several boards share one floor band the
  // band packs them left-to-right, so that branch crosses the siblings and the
  // tag printed straight over a sibling board's box.
  group('feeder annotations never overprint a board on a shared band', () {
    // FOUR boards forced onto ONE band (all floorIndex 0): an MDP feeding three
    // sub-boards ⇒ three feeder branches that all run the width of the band.
    const dense = ElectricalProject(
      id: 'dense',
      name: 'Dense band',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 10, y: 10),
          circuits: [
            ElectricalCircuit(
                id: 'f1', name: 'Feeder PP-PUMP', loadKind: LoadKind.feeder,
                feedsPanelId: 'P1', length: Length(12)),
            ElectricalCircuit(
                id: 'f2', name: 'Feeder PP-LIGHT', loadKind: LoadKind.feeder,
                feedsPanelId: 'P2', length: Length(18)),
            ElectricalCircuit(
                id: 'f3', name: 'Feeder PP-SOCKET', loadKind: LoadKind.feeder,
                feedsPanelId: 'P3', length: Length(24)),
          ],
        ),
        ElectricalPanel(
          id: 'P1', name: 'PP-PUMP', sourceType: PanelSource.feeder,
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 40, y: 10),
          circuits: [
            ElectricalCircuit(
                id: 'c1', name: 'Pump', loadKind: LoadKind.motor,
                motorKw: 5.5, length: Length(8)),
          ],
        ),
        ElectricalPanel(
          id: 'P2', name: 'PP-LIGHT', sourceType: PanelSource.feeder,
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 70, y: 10),
          circuits: [
            ElectricalCircuit(
                id: 'c2', name: 'Lighting', loadKind: LoadKind.lighting,
                isLighting: true, loadW: 1800, length: Length(14)),
          ],
        ),
        ElectricalPanel(
          id: 'P3', name: 'PP-SOCKET', sourceType: PanelSource.feeder,
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 100, y: 10),
          circuits: [
            ElectricalCircuit(
                id: 'c3', name: 'Sockets', loadKind: LoadKind.general,
                loadW: 3000, length: Length(16)),
          ],
        ),
      ],
    );
    final denseResult = computeSystem(profile, dense);
    final sheet = buildElectricalRiser(
        project: dense, result: denseResult, building: building);

    // A feeder annotation is the only label carrying both a cable size and the
    // ` mm2 · ` separator (see `_feederConnLabel`).
    List<SldLabel> feederLabels(SldSheet s) => s.prims
        .whereType<SldLabel>()
        .where((l) => l.text.contains(' mm2 ') && l.text.contains('·'))
        .toList();

    // The floor gutter's own labels (floor name + FFL) — a displaced tag must
    // not escape into that column either.
    List<SldLabel> gutterLabels(SldSheet s) => s.prims
        .whereType<SldLabel>()
        .where((l) =>
            l.text.startsWith('FFL ') ||
            building.floors.any((f) => f.name == l.text))
        .toList();

    test('no annotation is dropped: still one per fed board', () {
      // MDP + 3 sub-boards ⇒ 3 feeders, every one resolvable ⇒ 3 tags.
      expect(feederLabels(sheet).length, dense.panels.length - 1);
    });

    test('every annotation box clears every board box, every other annotation '
        'and the floor gutter', () {
      final labels = feederLabels(sheet);
      final boxes = [for (final l in labels) _Box.ofLabel(l)];
      final rects = [
        for (final r in sheet.prims.whereType<SldRect>()) _Box.ofRect(r)
      ];
      expect(rects.length, dense.panels.length);
      for (var i = 0; i < labels.length; i++) {
        for (final r in rects) {
          expect(boxes[i].overlaps(r), isFalse,
              reason: 'tag "${labels[i].text}" at ${labels[i].x},'
                  '${labels[i].y} overprints a board box');
        }
        for (var j = 0; j < labels.length; j++) {
          if (i == j) continue;
          expect(boxes[i].overlaps(boxes[j]), isFalse,
              reason: 'tags "${labels[i].text}" + "${labels[j].text}" fuse');
        }
        for (final g in gutterLabels(sheet)) {
          expect(boxes[i].overlaps(_Box.ofLabel(g)), isFalse,
              reason: 'tag "${labels[i].text}" reaches the gutter');
        }
      }
    });

    test('a displaced annotation is leadered back to ITS branch; the tag that '
        'never collided keeps the legacy anchor', () {
      final labels = feederLabels(sheet);
      // The legacy anchor of a fed board: its box right edge + 6, on the branch
      // (the box centre-line) less 4. Boards are 168 x 46 packed from x = 174
      // (gutter 150 + gap 24) at a 192 pitch, band 0 top y = 300 (two bands
      // above it at 150 each) ⇒ branch y = 300 + 23 = 323, anchors y = 319 and
      // x in {540, 732, 924} for the boards at x = 366 / 558 / 750.
      final anchors = {
        for (final r in sheet.prims.whereType<SldRect>())
          (r.x + r.w + 6, r.y + r.h / 2 - 4)
      };
      final kept =
          labels.where((l) => anchors.contains((l.x, l.y))).toList();
      final moved =
          labels.where((l) => !anchors.contains((l.x, l.y))).toList();
      // The RIGHTMOST board has nothing beyond it, so its own tag never
      // collided and must be untouched; the two behind it had to escape.
      expect(kept.length, 1, reason: 'kept: ${kept.map((l) => l.text)}');
      expect(kept.single.x, 924.0);
      expect(kept.single.y, 319.0);
      expect(moved, isNotEmpty);

      // Every moved tag gets a THIN leader ending exactly on it, starting on a
      // board's branch line (a box centre-line).
      final branchYs = {
        for (final r in sheet.prims.whereType<SldRect>()) r.y + r.h / 2
      };
      for (final l in moved) {
        final leaders = sheet.prims.whereType<SldLine>().where((s) =>
            s.weight == SldWeight.thin && s.x2 == l.x && s.y2 == l.y);
        expect(leaders, hasLength(1), reason: 'no leader for "${l.text}"');
        expect(branchYs, contains(leaders.first.y1), reason: l.text);
      }
      // A displaced tag escapes past the feeder channel, so the sheet widens to
      // hold it (it is never clipped).
      for (final l in moved) {
        expect(_Box.ofLabel(l).maxX, lessThanOrEqualTo(sheet.maxX),
            reason: l.text);
      }
    });

    test('a single-board-per-band riser keeps EXACTLY the legacy anchors '
        '(byte-identity guard)', () {
      // MDP (band 0) -> LP-1 (band 1) -> LP-2 (band 2): one board per band, so
      // no branch ever crosses a sibling and nothing may move.
      const chain = ElectricalProject(
        id: 'chain',
        name: 'One per band',
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 10, y: 10),
            circuits: [
              ElectricalCircuit(
                  id: 'fa', name: 'Feeder LP-1', loadKind: LoadKind.feeder,
                  feedsPanelId: 'A', length: Length(12)),
            ],
          ),
          ElectricalPanel(
            id: 'A', name: 'LP-1', sourceType: PanelSource.feeder,
            layoutPos: LayoutPos(sheetId: 's', floorIndex: 1, x: 10, y: 10),
            circuits: [
              ElectricalCircuit(
                  id: 'fb', name: 'Feeder LP-2', loadKind: LoadKind.feeder,
                  feedsPanelId: 'B', length: Length(9)),
            ],
          ),
          ElectricalPanel(
            id: 'B', name: 'LP-2', sourceType: PanelSource.feeder,
            layoutPos: LayoutPos(sheetId: 's', floorIndex: 2, x: 10, y: 10),
            circuits: [
              ElectricalCircuit(
                  id: 'cb', name: 'Sockets', loadKind: LoadKind.general,
                  loadW: 1200, length: Length(11)),
            ],
          ),
        ],
      );
      final r = computeSystem(profile, chain);
      final s = buildElectricalRiser(
          project: chain, result: r, building: building);
      final labels = feederLabels(s);
      expect(labels.length, chain.panels.length - 1);
      final anchors = {
        for (final rc in s.prims.whereType<SldRect>())
          (rc.x + rc.w + 6, rc.y + rc.h / 2 - 4)
      };
      for (final l in labels) {
        expect(anchors.contains((l.x, l.y)), isTrue,
            reason: '"${l.text}" moved to ${l.x},${l.y}');
        expect(l.size, 6.5);
      }
      // Hand-derived: the sole board of each band sits at x = 174 (gutter 150 +
      // gap 24), box 168 wide ⇒ right edge 342 ⇒ anchor x 342 + 6 = 348; the
      // TOP band starts at y 0 and the branch is the box centre-line 46 / 2 =
      // 23 ⇒ anchor y = 23 - 4 = 19.
      expect(labels.any((l) => l.x == 348.0 && l.y == 19.0), isTrue);
      // Nothing was displaced ⇒ no leader ends on any annotation.
      for (final l in labels) {
        expect(
            s.prims.whereType<SldLine>().any((ln) =>
                ln.weight == SldWeight.thin && ln.x2 == l.x && ln.y2 == l.y),
            isFalse,
            reason: 'unexpected leader for "${l.text}"');
      }
    });
  });
}
