import 'dart:convert';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = PuilProfile();

  // MDP feeds a 1-phase sub-panel LP-1 (one lighting way) + carries its own
  // motor way, so the drawing exercises feeders, ways, and both phase counts.
  const project = ElectricalProject(
    id: 'p1',
    name: 'Test building',
    panels: [
      ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        tag: 'MDP',
        circuits: [
          ElectricalCircuit(
            id: 'f1',
            name: 'Feeder to LP-1',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'LP1',
            length: Length(15),
          ),
          ElectricalCircuit(
            id: 'm1',
            name: 'Pompa',
            loadKind: LoadKind.motor,
            motorKw: 3,
            cableType: 'NYY',
            length: Length(22),
          ),
        ],
      ),
      ElectricalPanel(
        id: 'LP1',
        name: 'LP-1',
        tag: 'LP-1',
        system: ElectricalSystem.singlePhase,
        voltage: Voltage(220),
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'f1',
        circuits: [
          ElectricalCircuit(
            id: 'c1',
            name: 'Lighting',
            loadKind: LoadKind.lighting,
            isLighting: true,
            loadW: 1500,
            cableType: 'NYM',
            length: Length(18),
          ),
        ],
      ),
    ],
  );

  final result = computeSystem(profile, project);
  final sheet = buildElectricalSld(project: project, result: result);

  test('emits a non-empty drawing with finite bounds', () {
    expect(sheet.isEmpty, isFalse);
    expect(sheet.minX.isFinite && sheet.maxX.isFinite, isTrue);
    expect(sheet.maxX, greaterThan(sheet.minX));
    expect(sheet.maxY, greaterThan(sheet.minY));
  });

  test('draws a block (rect) + a busbar (thick line) per panel', () {
    final rects = sheet.prims.whereType<SldRect>().length;
    final thick = sheet.prims.whereType<SldLine>().where(
        (l) => l.weight == SldWeight.thick);
    // Two panels → at least two outer blocks; each bus is two thick verticals.
    expect(rects, greaterThanOrEqualTo(2));
    expect(thick.length, greaterThanOrEqualTo(4));
  });

  test('labels carry the drafter way content (breaker, cable, Ib)', () {
    final texts =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).toList();
    final joined = texts.join('\n');
    expect(joined, contains('Incomer'));
    expect(joined, contains('Ib '));
    expect(joined, contains('MCB'));
    // The two cable families used appear verbatim.
    expect(joined, contains('NYM'));
    expect(joined, contains('NYY'));
    // The sub-panel name reads on the feeding way.
    expect(joined, contains('LP-1'));
  });

  test('the feeder is routed (medium lines) from the way to the sub-panel', () {
    final medium = sheet.prims
        .whereType<SldLine>()
        .where((l) => l.weight == SldWeight.medium);
    // The orthogonal feeder channel is ≥ 3 medium segments.
    expect(medium.length, greaterThanOrEqualTo(3));
  });

  test('legend lists the symbols actually used + a supply note', () {
    final codes = sheet.legend.map((e) => e.code).toList();
    expect(codes, contains('MCB'));
    expect(codes, contains('Ib'));
    expect(codes.any((c) => c.startsWith('Curve')), isTrue);
    expect(codes, contains('NYM'));
    expect(sheet.supplyNote, contains('kVA'));
  });

  test('breakerLabel / cableLabel format to drafter notation', () {
    const profile = PuilProfile();
    final b = profile.breakerClassFor(16);
    expect(b, BreakerClass.mcb);
    // 1-phase lighting cable: 3-core notation, family preserved.
    expect(cableLabel(null, 2.5, false), 'Cu 3x2.5');
    // 3-phase: 5-core notation.
    expect(cableLabel(null, 6, true), 'Cu 5x6');
  });

  test('an empty project yields an empty drawing (no blocks)', () {
    const empty = ElectricalProject(id: 'e', name: 'Empty');
    final emptyResult = computeSystem(profile, empty);
    final emptySheet =
        buildElectricalSld(project: empty, result: emptyResult);
    expect(emptySheet.prims.whereType<SldRect>(), isEmpty);
  });

  group('buildElectricalOverview (zoomed-out building single-line)', () {
    // LV main feeds a normal sub-board (LP-1) and an EMERGENCY sub-board that
    // carries a life-safety load → the essential colour must propagate.
    const ov = ElectricalProject(
      id: 'ov',
      name: 'Tower',
      panels: [
        ElectricalPanel(
          id: 'LVMDP',
          name: 'LVMDP',
          circuits: [
            ElectricalCircuit(
                id: 'f1', name: 'MDP Normal', loadKind: LoadKind.feeder,
                feedsPanelId: 'LP1', length: Length(20)),
            ElectricalCircuit(
                id: 'f2', name: 'MDP Emergency', loadKind: LoadKind.feeder,
                feedsPanelId: 'EMG', length: Length(20)),
          ],
        ),
        ElectricalPanel(
          id: 'LP1', name: 'LP-1', sourceType: PanelSource.feeder,
          circuits: [
            ElectricalCircuit(
                id: 'c1', name: 'Lighting', loadKind: LoadKind.lighting,
                isLighting: true, loadW: 1500, length: Length(15)),
          ],
        ),
        ElectricalPanel(
          id: 'EMG', name: 'MDP EMERGENCY', sourceType: PanelSource.feeder,
          circuits: [
            ElectricalCircuit(
                id: 'fs', name: 'Fire pump', loadKind: LoadKind.motor,
                motorKw: 7.5, lifeSafety: true, feedsPanelId: 'FS',
                length: Length(25)),
          ],
        ),
        ElectricalPanel(
          id: 'FS', name: 'PP FIRE STAIRS', sourceType: PanelSource.feeder,
          circuits: [
            ElectricalCircuit(
                id: 'e1', name: 'Emergency light', loadKind: LoadKind.lighting,
                lifeSafety: true, loadW: 800, length: Length(18)),
          ],
        ),
      ],
    );

    final ovResult = computeSystem(profile, ov);
    final sheet = buildElectricalOverview(project: ov, result: ovResult);

    test('draws one compact node (rect) per panel', () {
      expect(sheet.prims.whereType<SldRect>().length, 4);
    });

    test('the EMERGENCY sub-tree is essential (red); normal stays normal', () {
      final labels = sheet.prims.whereType<SldLabel>();
      SldRole roleOf(String name) =>
          labels.firstWhere((l) => l.text.contains(name)).role;
      expect(roleOf('LVMDP'), SldRole.normal);
      expect(roleOf('LP-1'), SldRole.normal);
      expect(roleOf('MDP EMERGENCY'), SldRole.essential);
      // Propagated to the child of the emergency board.
      expect(roleOf('PP FIRE STAIRS'), SldRole.essential);
    });

    test('panels are tiered top-down by feeder depth', () {
      // The bold name label sits at a fixed offset inside each node, so its y is
      // monotonic with the panel's tier.
      double yOf(String name) => sheet.prims
          .whereType<SldLabel>()
          .firstWhere((l) => l.bold && l.text.contains(name))
          .y;
      expect(yOf('LVMDP'), lessThan(yOf('LP-1')));
      expect(yOf('MDP EMERGENCY'), lessThan(yOf('PP FIRE STAIRS')));
    });

    test('legend names the normal / essential split', () {
      final codes = sheet.legend.map((e) => e.code).toList();
      expect(codes, contains('Normal'));
      expect(codes, contains('Essential'));
    });

    test('overview PDF colours the essential branch red, normal byte-stable',
        () {
      final s = latin1.decode(electricalSldToPdf(
          project: ov, result: ovResult, overview: true));
      expect(s.startsWith('%PDF-1.4'), isTrue);
      expect(s, contains('0.80 0.13 0.13 RG')); // essential red stroke
      expect(s, contains('MDP EMERGENCY'));
    });

    test('overview DXF tags the essential branch ACI red (62 / 1)', () {
      final dxf = electricalSldToDxf(
          project: ov, result: ovResult, overview: true);
      expect(dxf, contains('PP FIRE STAIRS'));
      // group code 62 with value 1 (red) appears for essential entities.
      expect(dxf, contains('62\n1\n'));
    });
  });
}
