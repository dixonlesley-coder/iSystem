// Backlog W-1 / W-2 (2026-11-14) — the tank refill time (per tank node) and
// the available mains head (a project input) round-trip through `.mechx`
// additively, and an old file (no such key) loads with the defaults (golden
// rule 7).
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart'
    show
        kDefaultMainsHeadM,
        kGroundStorageDaysDefault,
        kRoofStorageFractionDefault;
import 'package:mechx_engine/units.dart';

NetNode _tank(String id, {double? l, double? h}) => NetNode(
      id: id,
      sheetId: 's',
      x: 0,
      y: 0,
      floorIndex: 0,
      role: NodeRole.plant,
      component: NodeComponent.roofTank,
      tankCapacityLitres: l,
      tankRefillHours: h,
    );

ProjectDocument _doc(Network n) => ProjectDocument(
      projectName: 'Fill',
      floors: const [Floor('G', Length(3))],
      calibrations: const {},
      sheets: const [],
      network: n,
    );

void main() {
  test('W-1: the refill time round-trips; an unset one writes no key', () {
    final text = _doc(Network(nodes: [
      _tank('a', l: 10000, h: 2.5),
      _tank('b', l: 5000),
    ])).encode();
    final back = ProjectDocument.decode(text).network.nodes;
    expect([for (final n in back) n.tankRefillHours], [2.5, null]);
    expect([for (final n in back) n.tankCapacityLitres], [10000, 5000]);
    expect(RegExp('tank_refill_h').allMatches(text).length, 1);
  });

  test('W-1: an old file (no key) and a bad value load as the default', () {
    final text = _doc(Network(nodes: [_tank('a', l: 10000)])).encode();
    expect(text.contains('tank_refill_h'), isFalse);
    expect(ProjectDocument.decode(text).network.nodes.single.tankRefillHours,
        isNull);
    final bad = text.replaceFirst('"tank_l"', '"tank_refill_h":-3,"tank_l"');
    expect(bad, isNot(text));
    expect(ProjectDocument.decode(bad).network.nodes.single.tankRefillHours,
        isNull);
  });

  test('W-2: the mains head round-trips; the default writes no key', () {
    const set = DesignSettings(mainsHeadM: 18.5);
    expect(DesignSettings.fromJson(set.toJson()).mainsHeadM, 18.5);
    const def = DesignSettings();
    expect(def.toJson().containsKey('mainsHead_m'), isFalse);
    // An old file (no key) and an out-of-band value load the default /
    // the clamped band.
    expect(DesignSettings.fromJson(const {}).mainsHeadM, kDefaultMainsHeadM);
    expect(DesignSettings.fromJson(const {'mainsHead_m': 500}).mainsHeadM,
        100.0);
  });

  test('W-5: the storage targets round-trip; defaults write no key', () {
    const set = DesignSettings(groundStorageDays: 1.5, roofStorageFraction: 0.3);
    final back = DesignSettings.fromJson(set.toJson());
    expect(back.groundStorageDays, 1.5);
    expect(back.roofStorageFraction, 0.3);
    final def = const DesignSettings().toJson();
    expect(def.containsKey('ground_storage_days'), isFalse);
    expect(def.containsKey('roof_storage_frac'), isFalse);
    final old = DesignSettings.fromJson(const {});
    expect(old.groundStorageDays, kGroundStorageDaysDefault);
    expect(old.roofStorageFraction, kRoofStorageFractionDefault);
  });
}
