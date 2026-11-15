// Backlog E-1 / E-2 / E-5 (2026-11-13) — the electrical SUPPLY fields added
// by the supply backlog round-trip through `.mechx` additively, and an old
// file (no such key) loads unchanged (golden rule 7).
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

ProjectDocument _doc(ElectricalProject e) => ProjectDocument(
      projectName: 'Supply',
      floors: const [Floor('G', Length(3))],
      calibrations: const {},
      sheets: const [],
      network: const Network(),
      electrical: e,
    );

void main() {
  test('E-1: serviceEntrance round-trips; an unset flag writes no key', () {
    const e = ElectricalProject(id: 'e', name: 'E', panels: [
      ElectricalPanel(id: 'A', name: 'A', serviceEntrance: true),
      ElectricalPanel(id: 'B', name: 'B', serviceEntrance: false),
      ElectricalPanel(id: 'C', name: 'C'),
    ]);
    final text = _doc(e).encode();
    final back = ProjectDocument.decode(text).electrical!;
    expect([for (final p in back.panels) p.serviceEntrance],
        [true, false, null]);
    // An old file: the key absent => null (the default rule).
    expect(RegExp('serviceEntrance').allMatches(text).length, 2);
  });

  test('E-2: the auto cable-type record round-trips; a hand type has none',
      () {
    const e = ElectricalProject(id: 'e', name: 'E', panels: [
      ElectricalPanel(id: 'A', name: 'A', circuits: [
        ElectricalCircuit(
            id: 'f', name: 'Feeder', cableType: 'FRC', cableTypeAuto: true),
        ElectricalCircuit(id: 'h', name: 'Hand', cableType: 'FRC'),
      ]),
    ]);
    final text = _doc(e).encode();
    final back = ProjectDocument.decode(text).electrical!.panels.single;
    expect([for (final c in back.circuits) (c.cableType, c.cableTypeAuto)],
        [('FRC', true), ('FRC', false)]);
    expect(RegExp('cableTypeAuto').allMatches(text).length, 1);
  });
}
