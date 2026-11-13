// Reference buildings — the shared LOADER behind the drawing-set export
// (`reference_drawing_set_export_test.dart`) and the issued-drawing parity
// test (`issued_drawing_parity_test.dart`): each of the five fixtures loaded
// through the same store intents the `reference_*_app_test.dart` suites use,
// with the project identity a user types (name, Document control sign-off).
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/document_control_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/units.dart' show Length;

import 'reference_board_floors.dart';
import '../packages/mechx_engine/test/reference/apartment.dart' as apt;
import '../packages/mechx_engine/test/reference/house.dart' as house;
import '../packages/mechx_engine/test/reference/office.dart' as office;
import '../packages/mechx_engine/test/reference/reference_building.dart';
import '../packages/mechx_engine/test/reference/shophouse.dart' as shop;
import '../packages/mechx_engine/test/reference/tower.dart' as tower;


/// A save dialog that "chooses" [path] without any OS UI.
class FakeSavePicker extends FilePickerPlatform {
  final String path;
  FakeSavePicker(this.path);

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async =>
      path;
}

/// One room drawn with the Room tool (fields common to every fixture's room).
typedef RefRoom = ({
  String name,
  String sheetId,
  int floorIndex,
  double ax,
  double ay,
  double bx,
  double by,
  Object roomType,
  Object? equipment,
});

class RefDrawingSpec {
  final String key;
  final String projectName;
  final ReferenceBuilding Function() build;
  final Size sheetPx;
  final FeedStrategy feed;
  final bool fireLightHazard;
  final List<RefRoom> rooms;
  final void Function(ProviderContainer c)? extra;
  final void Function(ProviderContainer c)? afterElectrical;
  const RefDrawingSpec({
    required this.key,
    required this.projectName,
    required this.build,
    required this.sheetPx,
    required this.feed,
    this.fireLightHazard = false,
    this.rooms = const [],
    this.extra,
    this.afterElectrical,
  });
}

const String _mepBoard = 'mep-equipment';

/// The MEP board onto PP-E (FRC) — the same `connectFeeder` + `setCircuit`
/// intents the apartment / tower app suites run.
void _refeedMep(ProviderContainer c, String essentialId, {Length? length}) {
  final store = c.read(electricalProjectProvider.notifier);
  final before = c.read(electricalProjectProvider);
  if (!before.panels.any((p) => p.id == _mepBoard)) return;
  final parent = before.panels
      .where((p) => p.circuits.any((w) => w.feedsPanelId == _mepBoard))
      .firstOrNull;
  if (parent?.id == essentialId) return;
  final r = store.connectFeeder(essentialId, _mepBoard);
  if (!r.connected) return;
  final way = c
      .read(electricalProjectProvider)
      .panels
      .firstWhere((p) => p.id == essentialId)
      .circuits
      .firstWhere((w) => w.feedsPanelId == _mepBoard);
  store.setCircuit(essentialId, way.id, cableType: 'FRC', length: length);
}

List<RefRoom> _rooms(Iterable<dynamic> rs, {bool equipment = false}) => [
      for (final dynamic r in rs)
        (
          name: r.name as String,
          sheetId: r.sheetId as String,
          floorIndex: r.floorIndex as int,
          ax: r.ax as double,
          ay: r.ay as double,
          bx: r.bx as double,
          by: r.by as double,
          roomType: r.roomType as Object,
          equipment: equipment ? r.equipment as Object : null,
        ),
    ];

final List<RefDrawingSpec> kRefDrawingSpecs = [
  RefDrawingSpec(
    key: 'house',
    projectName: 'Rumah Contoh',
    build: house.buildHouse,
    sheetPx: const Size(1684, 1190),
    feed: FeedStrategy.downfeed,
  ),
  RefDrawingSpec(
    key: 'shophouse',
    projectName: 'Ruko Contoh',
    build: shop.buildShophouse,
    sheetPx: const Size(1684, 1190),
    feed: FeedStrategy.downfeed,
    rooms: _rooms(shop.kShophouseRooms),
  ),
  RefDrawingSpec(
    key: 'office',
    projectName: 'Kantor Contoh',
    build: office.buildOffice,
    sheetPx: const Size(2384, 1684),
    feed: FeedStrategy.upfeed,
    fireLightHazard: true,
    rooms: _rooms(office.kOfficeRooms),
  ),
  RefDrawingSpec(
    key: 'apartment',
    projectName: 'Apartemen Contoh',
    build: apt.buildApartment,
    sheetPx: const Size(2384, 1684),
    feed: FeedStrategy.downfeed,
    fireLightHazard: true,
    rooms: _rooms(apt.kApartmentRooms),
    afterElectrical: (c) => _refeedMep(c, apt.kAptEssentialPanelId),
  ),
  RefDrawingSpec(
    key: 'tower',
    projectName: 'Menara Contoh 30',
    build: tower.buildTower,
    sheetPx: const Size(4200, 1800),
    feed: FeedStrategy.downfeed,
    fireLightHazard: true,
    rooms: _rooms(tower.kTowerRooms, equipment: true),
    extra: (c) {
      c.read(ductSettingsProvider.notifier)
        ..setShape(tower.kTowerDuctShape)
        ..setMethod(tower.kTowerDuctMethod);
      c.read(mepDutyFeedEnabledProvider.notifier).enable();
    },
    afterElectrical: (c) => _refeedMep(c, tower.kTowerEssentialPanelId,
        length: const Length(10)),
  ),
];

Future<void> loadRefDrawingSpec(ProviderContainer c, RefDrawingSpec spec) async {
  final b = spec.build();
  c.read(sheetsControllerProvider.notifier).loadSheets(
    [
      for (final s in b.sheets)
        Sheet(id: s.id, name: s.name, sizePx: spec.sheetPx),
    ],
    sheetFloors: {for (final s in b.sheets) s.id: s.floorIndex},
  );
  final project = c.read(projectControllerProvider.notifier)
    ..setFloors(b.building.floors);
  for (final MapEntry(:key, :value) in b.calibrations.entries) {
    project.setCalibration(key, value);
  }
  c.read(feedStrategyProvider.notifier).set(spec.feed);
  c.read(occupancyProvider.notifier).set(b.occupancy);
  if (spec.fireLightHazard) {
    c.read(fireHazardProvider.notifier).set(FireHazardClass.lightHazard);
  }
  spec.extra?.call(c);
  c.read(networkControllerProvider.notifier).loadNetwork(b.network);
  final rooms = c.read(roomAreasProvider.notifier);
  for (final r in spec.rooms) {
    final id = rooms.add(
      sheetId: r.sheetId,
      floorIndex: r.floorIndex,
      ax: r.ax,
      ay: r.ay,
      bx: r.bx,
      by: r.by,
    )!;
    final dynamic d = rooms;
    d.setRoomType(id, r.roomType);
    if (r.equipment != null) d.setEquipment(id, r.equipment);
    rooms.setName(id, r.name);
  }
  c.read(electricalProjectProvider.notifier).setProject(b.electrical);
  await Future<void>.delayed(Duration.zero);
  spec.afterElectrical?.call(c);
  await Future<void>.delayed(Duration.zero);
  // Drawing backlog C-2 — every board on its own floor (the Panel
  // inspector's 'Riser floor' intent).
  setReferenceBoardFloors(c);
  await Future<void>.delayed(Duration.zero);

  // Project identity, as typed on the Projects page / Document control card.
  project.setName(spec.projectName);
  c.read(documentControlProvider.notifier)
    ..setPreparedBy('AB')
    ..setCheckedBy('CD')
    ..setApprovedBy('EF')
    ..setRevisionTag('A');
}
