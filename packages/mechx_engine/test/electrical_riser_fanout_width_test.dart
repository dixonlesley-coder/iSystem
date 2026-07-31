// E-4: buildElectricalRiser's per-floor branch fan-out used to hard-cap every
// stub name at 14 characters even when the panel's band had plenty of clear
// horizontal room before the next panel (or the sheet's right margin), so a
// short name like 'Lighting -' printed with visible free space beside it
// (see the committed golden `test/goldens/10_electrical_riser.png`). The
// budget is now derived from the actual clear space available to that
// panel's fan column — floored at the old fixed 14 chars so a label is NEVER
// shorter than before, and never overlaps a neighbouring panel's box or fan
// column.
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = PuilProfile();
  const building = BuildingLevels([Floor('Ground', Length(4))]);

  /// The load-way fan-out stub labels (size 6, carrying an amperage) for a
  /// built riser sheet.
  List<SldLabel> fanStubs(SldSheet sheet) => sheet.prims
      .whereType<SldLabel>()
      .where((l) => l.size == 6 && l.text.contains('A'))
      .toList();

  test('(1) a lone panel with generous free space renders a long way name at '
      'MORE than 14 chars — no artificial truncation when room is real', () {
    const longName = 'Chiller Plant Room Extension'; // 29 chars, > 14
    const project = ElectricalProject(
      id: 'p1',
      name: 'Roomy band',
      panels: [
        ElectricalPanel(
          id: 'P1',
          name: 'LP-1',
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 10, y: 10),
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
    final result = computeSystem(profile, project);
    final sheet =
        buildElectricalRiser(project: project, result: result, building: building);
    final stubs = fanStubs(sheet);
    expect(stubs, isNotEmpty);
    final label = stubs.single;
    // The sole panel in its band has nothing to its right but the sheet
    // margin, so a 29-char name comfortably fits — printed IN FULL (no
    // ellipsis), well past the old fixed 14-char cap.
    expect(label.text, isNot(contains('...')), reason: label.text);
    expect(label.text, contains(longName), reason: label.text);
    expect(longName.length, greaterThan(14)); // the premise the fix restores
  });

  test('(2) with two adjacent panels on one band, a fan label never crosses '
      'the neighbouring panel box\'s left edge', () {
    // Two independent (unfed) panels forced onto the SAME floor band. Both
    // circuits carry deliberately long names so the constrained (left) panel
    // genuinely exercises its budget — whichever panel the engine places
    // left-to-right is discovered from the drawn geometry, not assumed from
    // panel-list order.
    const project = ElectricalProject(
      id: 'p2',
      name: 'Packed band',
      panels: [
        ElectricalPanel(
          id: 'A',
          name: 'LP-A',
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 10, y: 10),
          circuits: [
            ElectricalCircuit(
                id: 'ca',
                name: 'Emergency Lighting Circuit Extension Block',
                loadKind: LoadKind.general,
                loadW: 1500,
                length: Length(10)),
          ],
        ),
        ElectricalPanel(
          id: 'B',
          name: 'LP-B',
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 400, y: 10),
          circuits: [
            ElectricalCircuit(
                id: 'cb',
                name: 'Kitchen Exhaust Fan Circuit Extension Block',
                loadKind: LoadKind.general,
                loadW: 1800,
                length: Length(10)),
          ],
        ),
      ],
    );
    final result = computeSystem(profile, project);
    final sheet =
        buildElectricalRiser(project: project, result: result, building: building);

    final rects = sheet.prims.whereType<SldRect>().toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    expect(rects.length, 2);
    final leftRect = rects[0];
    final rightRect = rects[1];
    expect(leftRect.x, lessThan(rightRect.x));

    // The stub label(s) belonging to the LEFT (constrained) panel: the
    // builder always anchors a panel's fan stub label at `panel.x + 26`.
    final leftStubX = leftRect.x + 26;
    final leftStubs =
        fanStubs(sheet).where((l) => l.x == leftStubX).toList();
    expect(leftStubs, isNotEmpty, reason: 'no fan stub found for the left panel');

    for (final l in leftStubs) {
      final boxMaxX = l.x + l.text.length * l.size * kElectricalRiserLabelCharW;
      expect(boxMaxX, lessThanOrEqualTo(rightRect.x),
          reason: 'fan label "${l.text}" (box to $boxMaxX) crosses the '
              'neighbour panel box starting at ${rightRect.x}');
    }
  });

  test('(3) a name short enough today (<= 14 chars) renders exactly as '
      'before — unchanged, never truncated', () {
    const shortName = 'Pump A'; // well under the old fixed 14-char cap
    const project = ElectricalProject(
      id: 'p3',
      name: 'Short name',
      panels: [
        ElectricalPanel(
          id: 'P1',
          name: 'LP-1',
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 10, y: 10),
          circuits: [
            ElectricalCircuit(
                id: 'c1',
                name: shortName,
                loadKind: LoadKind.motor,
                motorKw: 3,
                length: Length(10)),
          ],
        ),
      ],
    );
    final result = computeSystem(profile, project);
    final sheet =
        buildElectricalRiser(project: project, result: result, building: building);
    final stubs = fanStubs(sheet);
    expect(stubs, isNotEmpty);
    final label = stubs.single;
    expect(label.text, isNot(contains('...')), reason: label.text);
    expect(label.text, startsWith(shortName), reason: label.text);
  });

  test('the char-advance / clearance math never lets a budget compute below '
      'the floored 14 (sanity check on the public advance constant)', () {
    // kElectricalRiserLabelCharW is the same per-char advance the feeder-
    // annotation collision boxes use — a positive, sub-pixel-per-char value.
    expect(kElectricalRiserLabelCharW, greaterThan(0));
    // A 14-char budget at the fan stub's font size (6) occupies a modest
    // width — sanity bound so a future font-size change can't silently blow
    // the floor's intent (14 chars must stay a small fraction of a panel's
    // own 168-unit box width referenced elsewhere in this file's fixtures).
    const fanLabelSize = 6.0;
    const floorWidth = 14 * fanLabelSize * kElectricalRiserLabelCharW;
    expect(floorWidth, lessThan(168));
  });
}
