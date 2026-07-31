import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

/// F8 (WORKFLOW-FRICTION) — `MountingHeights` (ceiling drop 0.3 / fixture
/// height 1.1) shapes EVERY vertical length and static lift and was documented
/// "editable per project", yet it was only ever constructed as defaults: no UI,
/// no `.mechx` field, no design-basis row. It is now a real project input.
void main() {
  test('a virgin project carries the engine defaults', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final m = c.read(projectControllerProvider).mounting;
    expect(m.ceilingDrop.meters, 0.3);
    expect(m.fixtureHeight.meters, 1.1);
    // The derived provider is the ONE place a consumer reads it from.
    expect(c.read(mountingProvider), const MountingHeights());
  });

  test('the setters clamp, no-op when unchanged, and are one undo step each',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(projectControllerProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    ctrl.setCeilingDrop(0.45);
    expect(c.read(mountingProvider).ceilingDrop.meters, closeTo(0.45, 1e-9));
    // The fixture height is untouched by a ceiling-drop edit.
    expect(c.read(mountingProvider).fixtureHeight.meters, 1.1);

    ctrl.setFixtureHeight(0.85);
    expect(c.read(mountingProvider).fixtureHeight.meters, closeTo(0.85, 1e-9));

    // Setting the SAME value again records nothing (so a stepper held at a
    // limit can't pile up empty undo entries).
    expect(hist.canUndo, isTrue);
    ctrl.setCeilingDrop(0.45);
    hist.undo(); // reverts the fixture height
    expect(c.read(mountingProvider).fixtureHeight.meters, 1.1);
    hist.undo(); // reverts the ceiling drop
    expect(c.read(mountingProvider).ceilingDrop.meters, 0.3);

    // Out-of-band typing clamps rather than producing a nonsense elevation.
    ctrl.setCeilingDrop(9.0);
    expect(c.read(mountingProvider).ceilingDrop.meters, 1.5);
    ctrl.setFixtureHeight(-2.0);
    expect(c.read(mountingProvider).fixtureHeight.meters, 0.0);
  });

  test('the mounting heights drive the role-aware §10 elevations', () {
    // The whole point of the input: a 0.3 m drop puts the Ground main at
    // 4.0 − 0.3 = 3.70 m; a 0.6 m drop puts it at 3.40 m.
    const levels = BuildingLevels([
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(3.5)),
    ]);
    expect(levels.ceilingElevationOf(0).meters, closeTo(3.7, 1e-9));
    expect(
        levels
            .ceilingElevationOf(0, const MountingHeights(ceilingDrop: Length(0.6)))
            .meters,
        closeTo(3.4, 1e-9));
    expect(
        levels
            .fixtureElevationOf(1,
                const MountingHeights(fixtureHeight: Length(0.8)))
            .meters,
        closeTo(4.8, 1e-9));
  });

  ProjectDocument doc({MountingHeights mounting = const MountingHeights()}) =>
      ProjectDocument(
        projectName: 'P',
        floors: const [Floor('Ground', Length(4.0))],
        mounting: mounting,
        calibrations: const {},
        sheets: const [],
        network: const Network(),
      );

  test('.mechx: the DEFAULT heights are not written at all (byte-identical)',
      () {
    final encoded = doc().encode();
    expect(encoded.contains('ceilingDropM'), isFalse);
    expect(encoded.contains('fixtureHeightM'), isFalse);
    // …and a file that never carried them loads with the engine defaults.
    final back = ProjectDocument.decode(encoded);
    expect(back.mounting, const MountingHeights());
  });

  test('.mechx: non-default heights round-trip', () {
    final custom = doc(
        mounting: const MountingHeights(
            ceilingDrop: Length(0.55), fixtureHeight: Length(0.9)));
    final encoded = custom.encode();
    expect(encoded.contains('"ceilingDropM": 0.55'), isTrue);
    final back = ProjectDocument.decode(encoded);
    expect(back.mounting.ceilingDrop.meters, closeTo(0.55, 1e-9));
    expect(back.mounting.fixtureHeight.meters, closeTo(0.9, 1e-9));
    // withSheets (asset rehydration) carries the value through.
    expect(back.withSheets(const []).mounting, back.mounting);
  });

  test('.mechx: a garbage / out-of-band value falls back, never throws', () {
    final raw = jsonDecode(doc().encode()) as Map<String, dynamic>;
    (raw['project'] as Map<String, dynamic>)['ceilingDropM'] = 'x';
    (raw['project'] as Map<String, dynamic>)['fixtureHeightM'] = 99.0;
    final back = ProjectDocument.fromJson(raw);
    expect(back.mounting, const MountingHeights());
  });

  test('loading a document seeds the project state (absent ⇒ defaults)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(projectControllerProvider.notifier);
    ctrl.load(
      name: 'P',
      floors: const [Floor('Ground', Length(4.0))],
      calibrations: const {},
      mounting: const MountingHeights(ceilingDrop: Length(0.5)),
    );
    expect(c.read(mountingProvider).ceilingDrop.meters, 0.5);
    ctrl.load(
      name: 'P',
      floors: const [Floor('Ground', Length(4.0))],
      calibrations: const {},
    );
    expect(c.read(mountingProvider), const MountingHeights());
  });
}
