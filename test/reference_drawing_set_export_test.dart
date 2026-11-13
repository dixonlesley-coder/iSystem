// Reference buildings — DRAWING-SET EXPORT generator (gated: REF_EXPORT=1).
//
// Loads each of the five reference buildings (house, shophouse, office,
// apartment, tower — fixtures in `packages/mechx_engine/test/reference/`)
// through the SAME store intents the `reference_*_app_test.dart` suites use,
// sets the project identity the way a user would (project name, Document
// control drawn / checked / approved + revision), then writes the issued set
// through the app's own export entry points:
//   * `writeSubmittalPackageToDir` — the ONE-folder submittal package the
//     Export sheet's primary row writes (cover + Daftar Gambar, every plan
//     PDF + DXF, riser SLD, electrical SLD / overview / riser / one-line,
//     reports, schedules, BOM);
//   * `exportElectricalPanelSchedulesPdf` — the panel-schedule set (not part
//     of the package), driven through a fake save dialog.
// Nothing is asserted beyond "the files were written"; the review is done on
// the rasterised PNGs (`tool/ref_drawings_precheck.py`).
//
// Run (from the repo root):
//   REF_EXPORT=1 REF_EXPORT_DIR=/abs/out flutter test \
//       test/reference_drawing_set_export_test.dart
// Output: $REF_EXPORT_DIR/<building>/ (default build/ref_drawings).
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart'
    show exportHasZeroLengthEdgesProvider;
import 'package:mechx/store/document_control_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/electrical/electrical_export.dart'
    show exportElectricalPanelSchedulesPdf;
import 'package:mechx/ui/inspector/project_panel.dart'
    show writeSubmittalPackageToDir;
import 'package:mechx_engine/report/file_names.dart' show safeFileStem;
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/units.dart' show Length;

import '../packages/mechx_engine/test/reference/apartment.dart' as apt;
import '../packages/mechx_engine/test/reference/house.dart' as house;
import '../packages/mechx_engine/test/reference/office.dart' as office;
import '../packages/mechx_engine/test/reference/reference_building.dart';
import '../packages/mechx_engine/test/reference/shophouse.dart' as shop;
import '../packages/mechx_engine/test/reference/tower.dart' as tower;

final bool _enabled = Platform.environment['REF_EXPORT'] == '1';
final String _outRoot =
    Platform.environment['REF_EXPORT_DIR'] ?? 'build/ref_drawings';

/// A save dialog that "chooses" [path] without any OS UI.
class _FakeSavePicker extends FilePickerPlatform {
  final String path;
  _FakeSavePicker(this.path);

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
typedef _Room = ({
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

class _Spec {
  final String key;
  final String projectName;
  final ReferenceBuilding Function() build;
  final Size sheetPx;
  final FeedStrategy feed;
  final bool fireLightHazard;
  final List<_Room> rooms;
  final void Function(ProviderContainer c)? extra;
  final void Function(ProviderContainer c)? afterElectrical;
  const _Spec({
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

List<_Room> _rooms(Iterable<dynamic> rs, {bool equipment = false}) => [
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

final List<_Spec> _specs = [
  _Spec(
    key: 'house',
    projectName: 'Rumah Contoh',
    build: house.buildHouse,
    sheetPx: const Size(1684, 1190),
    feed: FeedStrategy.downfeed,
  ),
  _Spec(
    key: 'shophouse',
    projectName: 'Ruko Contoh',
    build: shop.buildShophouse,
    sheetPx: const Size(1684, 1190),
    feed: FeedStrategy.downfeed,
    rooms: _rooms(shop.kShophouseRooms),
  ),
  _Spec(
    key: 'office',
    projectName: 'Kantor Contoh',
    build: office.buildOffice,
    sheetPx: const Size(2384, 1684),
    feed: FeedStrategy.upfeed,
    fireLightHazard: true,
    rooms: _rooms(office.kOfficeRooms),
  ),
  _Spec(
    key: 'apartment',
    projectName: 'Apartemen Contoh',
    build: apt.buildApartment,
    sheetPx: const Size(2384, 1684),
    feed: FeedStrategy.downfeed,
    fireLightHazard: true,
    rooms: _rooms(apt.kApartmentRooms),
    afterElectrical: (c) => _refeedMep(c, apt.kAptEssentialPanelId),
  ),
  _Spec(
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

Future<void> _load(ProviderContainer c, _Spec spec) async {
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

  // Project identity, as typed on the Projects page / Document control card.
  project.setName(spec.projectName);
  c.read(documentControlProvider.notifier)
    ..setPreparedBy('AB')
    ..setCheckedBy('CD')
    ..setApprovedBy('EF')
    ..setRevisionTag('A');
}

void main() {
  for (final spec in _specs) {
    testWidgets('export the ${spec.key} drawing set', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.runAsync(() => _load(c, spec));
      late WidgetRef ref;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(builder: (context, r, _) {
            ref = r;
            return const SizedBox.shrink();
          }),
        ),
      ));
      await tester.pump();

      final dir = Directory('$_outRoot/${spec.key}');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);

      // Drawing-review D7 — the package path applies the SAME zero-length
      // guard [runExportGuarded] applies to every other export (the folder
      // picker in front of it cannot run headless).
      expect(c.read(exportHasZeroLengthEdgesProvider), isFalse,
          reason: 'zero-length guard would refuse the submittal package');
      final ok = await tester
          .runAsync(() => writeSubmittalPackageToDir(ref, dir.path));
      expect(ok, isTrue);

      final previous = FilePickerPlatform.instance;
      final stem = safeFileStem(spec.projectName);
      FilePickerPlatform.instance =
          _FakeSavePicker('${dir.path}/$stem-panel-schedules.pdf');
      addTearDown(() => FilePickerPlatform.instance = previous);
      if (c.read(electricalResultProvider).order.isNotEmpty) {
        await tester.runAsync(() => exportElectricalPanelSchedulesPdf(ref));
      }
      final err = c.read(loadErrorProvider);
      if (err != null) {
        File('${dir.path}/EXPORT-ERRORS.txt').writeAsStringSync('$err\n');
      }
      final files = dir.listSync().whereType<File>().toList();
      expect(files, isNotEmpty);
    }, skip: !_enabled);
  }
}
