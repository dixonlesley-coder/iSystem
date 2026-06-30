/// App-side MECHANICAL riser single-line export actions — gather the live
/// network / sizing / building / feed-strategy providers, build the pure-engine
/// [SldSheet] (`report/mechanical_sld_drawing.dart`), render it to a vector PDF
/// or DXF via the discipline-neutral `report/sld_export.dart`, and write the
/// result to a user-chosen file. The mechanical mirror of
/// `ui/electrical/electrical_export.dart`.
///
/// The KETERANGAN legend + title block ride the EXPORT sheet (the live working
/// canvas keeps them off by default), so a real issued drawing always carries
/// its key while the editing surface stays uncluttered.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';

import '../../store/app_state.dart';
import '../../store/project_store.dart';
import '../../store/network_store.dart';
import '../../store/sizing_store.dart';
import '../strings/app_strings.dart';

/// The title-block heading for the active system [focus] — a per-service riser
/// title (Indonesian air-bersih convention) when one system is filtered, else
/// the generic mechanical single-line heading. ASCII-only (renders in PDF/DXF).
String _diagramTitle(ServiceType? focus) {
  if (focus == null) return 'MECHANICAL SINGLE-LINE DIAGRAM';
  return switch (focus) {
    ServiceType.coldWater => 'DIAGRAM SISTEM AIR BERSIH',
    ServiceType.hotWater => 'HOT WATER RISER DIAGRAM',
    ServiceType.drainage => 'DRAINAGE RISER DIAGRAM',
    ServiceType.vent => 'VENT RISER DIAGRAM',
    ServiceType.rainwater => 'STORMWATER RISER DIAGRAM',
    ServiceType.duct ||
    ServiceType.returnAir ||
    ServiceType.exhaust =>
      'AIR DUCT RISER DIAGRAM',
    ServiceType.fireSprinkler ||
    ServiceType.fireHydrant =>
      'FIRE RISER DIAGRAM',
  };
}

/// A short title-block supply note from the live feed strategy + the tanks
/// actually present (honest — only mentions a tank/pump the network has).
String _supplyNote(Network net, FeedStrategy feed) {
  final hasRoofTank =
      net.nodes.any((n) => n.component == NodeComponent.roofTank);
  final hasGroundTank =
      net.nodes.any((n) => n.component == NodeComponent.groundTank);
  final hasPump = net.nodes.any((n) =>
      n.component == NodeComponent.pump ||
      n.component == NodeComponent.boosterSet);
  final parts = <String>[
    feed == FeedStrategy.downfeed
        ? 'Feed: gravity downfeed'
        : 'Feed: upfeed / booster',
  ];
  if (hasRoofTank) parts.add('roof tank');
  if (hasGroundTank) parts.add('ground tank');
  if (hasPump) parts.add('pump');
  return parts.join(' - ');
}

/// Build the live mechanical riser [SldSheet] for [focus] from the current
/// project providers (the SAME §10 geometry the working canvas reads).
SldSheet _buildSheet(WidgetRef ref, ServiceType? focus) {
  final network = ref.read(networkControllerProvider).network;
  final sizing = ref.read(sizingProvider);
  final building = ref.read(projectControllerProvider).building;
  final feed = ref.read(feedStrategyProvider);
  return buildMechanicalRiserSld(
    network: network,
    sizing: sizing,
    building: building,
    focus: focus,
    downfeed: feed == FeedStrategy.downfeed,
    supplyNote: _supplyNote(network, feed),
  );
}

/// Export the mechanical riser single-line as a native (vector) PDF.
Future<void> exportMechanicalRiserPdf(WidgetRef ref, ServiceType? focus) async {
  final sheet = _buildSheet(ref, focus);
  final bytes = sldSheetToPdf(
    sheet: sheet,
    title: 'iSystem mechanical single-line',
    diagramTitle: _diagramTitle(focus),
    chrome: const DrawingChrome(sheetIndex: 1, sheetTotal: 1),
  );
  final project = ref.read(projectControllerProvider);
  final base = project.name.isEmpty ? 'mechanical' : project.name;
  final path = await FilePicker.saveFile(
    dialogTitle: MechXStringsData(ref.read(localeProvider))(
        StringKey.exportTitleSldPdf),
    fileName: '$base-riser-sld.pdf',
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
  );
  if (path == null) return;
  final full = path.endsWith('.pdf') ? path : '$path.pdf';
  await File(full).writeAsBytes(bytes);
}

/// Export the mechanical riser single-line as a DXF (R12) drawing file.
Future<void> exportMechanicalRiserDxf(WidgetRef ref, ServiceType? focus) async {
  final sheet = _buildSheet(ref, focus);
  final dxf = sldSheetToDxf(sheet: sheet, diagramTitle: _diagramTitle(focus));
  final project = ref.read(projectControllerProvider);
  final base = project.name.isEmpty ? 'mechanical' : project.name;
  final path = await FilePicker.saveFile(
    dialogTitle: MechXStringsData(ref.read(localeProvider))(
        StringKey.exportTitleSldDxf),
    fileName: '$base-riser-sld.dxf',
    type: FileType.custom,
    allowedExtensions: const ['dxf'],
  );
  if (path == null) return;
  final full = path.endsWith('.dxf') ? path : '$path.dxf';
  await File(full).writeAsString(dxf);
}
