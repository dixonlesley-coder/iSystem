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
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show electricalSldSheetsToPdf;
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_tags.dart'
    show equipmentDetail, riserServiceCode;
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/standards/sni.dart' show Occupancy;

import '../../store/app_state.dart';
import '../../store/document_control_store.dart';
import '../../store/project_store.dart';
import '../../store/network_store.dart';
import '../../store/sizing_store.dart';
import '../../store/solve_store.dart';
import '../inspector/project_panel.dart' show kDrawServices, runExportGuarded;
import '../strings/app_strings.dart';

/// The title-block heading for the active system [focus] — a per-service riser
/// title (Indonesian air-bersih convention) when one system is filtered, else
/// the generic mechanical single-line heading. ASCII-only (renders in PDF/DXF).
String _diagramTitle(ServiceType? focus) {
  if (focus == null) return 'MECHANICAL SINGLE-LINE DIAGRAM';
  return switch (focus) {
    ServiceType.coldWater => 'DIAGRAM SISTEM AIR BERSIH',
    ServiceType.hotWater => 'HOT WATER RISER DIAGRAM',
    // B2: drainage / vent / storm carry the same Indonesian sheet language as
    // the air-bersih deliverable.
    ServiceType.drainage => 'DIAGRAM SISTEM AIR KOTOR & BEKAS',
    ServiceType.vent => 'DIAGRAM SISTEM VEN',
    ServiceType.rainwater => 'DIAGRAM SISTEM AIR HUJAN',
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

/// The KETERANGAN system-notes lines for the exported sheet — the SAME live
/// echoes the canvas `_SystemNotes` card shows: the feed strategy, each tank
/// actually present with its REAL capacity, the occupancy class, and the peak
/// design flow when a supply pump was sized (upfeed). HONEST: a datum that
/// doesn't exist (no tank, no pump on downfeed) is simply not written.
List<String> _systemNotes(WidgetRef ref, Network net) {
  final feed = ref.read(feedStrategyProvider);
  final occupancy = ref.read(occupancyProvider);
  final pump = ref.read(pumpDutyProvider);

  // Capacity of the first node with [component] carrying a stored capacity —
  // the shared engine `equipmentDetail` ('237 m3'), so the note matches the
  // on-node suffix exactly.
  String? tankM3(NodeComponent component) {
    for (final n in net.nodes) {
      if (n.component != component) continue;
      final d = equipmentDetail(n);
      if (d != null) return d;
    }
    return null;
  }

  // F9: assert '(roof tank)' ONLY when a roofTank actually exists in the
  // network (mirrors `_supplyNote`) — the KETERANGAN must never claim
  // equipment the design doesn't contain.
  final hasRoofTank =
      net.nodes.any((n) => n.component == NodeComponent.roofTank);
  final lines = <String>[
    feed == FeedStrategy.downfeed
        ? (hasRoofTank
            ? 'Feed: gravity downfeed (roof tank)'
            : 'Feed: gravity downfeed')
        : 'Feed: upfeed / booster pump',
  ];
  final roofM3 = tankM3(NodeComponent.roofTank);
  if (roofM3 != null) lines.add('Roof tank: $roofM3');
  final groundM3 = tankM3(NodeComponent.groundTank);
  if (groundM3 != null) lines.add('Ground tank: $groundM3');
  lines.add('Occupancy: ${switch (occupancy) {
    Occupancy.private => 'Private',
    Occupancy.public => 'Public',
    Occupancy.assembly => 'Assembly',
  }}');
  // Peak design flow is upfeed-only (pumpDutyProvider null on downfeed). Never
  // fabricate a m3/day figure when no pump flow exists.
  if (pump != null) {
    lines.add('Peak design flow: '
        '${pump.flow.inLitersPerSecond.toStringAsFixed(1)} L/s');
  }
  return lines;
}

/// Build the live mechanical riser [SldSheet] for [focus] from the current
/// project providers (the SAME §10 geometry the working canvas reads), with
/// the B1 export-parity extras the on-screen Auto view already draws: per-node
/// equipment detail suffixes (tank m3 / pump-fan kW), the KETERANGAN system
/// notes, and the H101 detail callouts — so the issued sheet is always >= the
/// preview. Public for the export wiring test.
SldSheet buildLiveRiserSheet(WidgetRef ref, ServiceType? focus) {
  final network = ref.read(networkControllerProvider).network;
  final sizing = ref.read(sizingProvider);
  final building = ref.read(projectControllerProvider).building;
  final feed = ref.read(feedStrategyProvider);
  // Per-node capacity/duty suffixes — the same provider-fed resolution the
  // canvas uses (`equipmentDetail` returns null when no datum exists).
  final pump = ref.read(pumpDutyProvider);
  final fan = ref.read(ductFanProvider);
  final detailByNode = <String, String>{
    for (final node in network.nodes)
      node.id: ?equipmentDetail(node, supplyPump: pump, fan: fan),
  };
  return buildMechanicalRiserSld(
    network: network,
    sizing: sizing,
    building: building,
    focus: focus,
    downfeed: feed == FeedStrategy.downfeed,
    supplyNote: _supplyNote(network, feed),
    equipmentDetailByNodeId: detailByNode,
    notes: _systemNotes(ref, network),
    detailCallouts: true,
  );
}

/// The document-control (D3) chrome for riser sheet [index] of [total]: the
/// drawing number / revision tag / client / DRAWN-CHECKED-APPROVED identity
/// from [documentControlProvider] (unset fields stay null so their title-block
/// rows are omitted) plus today's date — the app formats the clock, the engine
/// never reads it.
DrawingChrome _riserChrome(WidgetRef ref,
    {required int index, required int total}) {
  final doc = ref.read(documentControlProvider);
  return DrawingChrome(
    sheetIndex: index,
    sheetTotal: total,
    drawingNumber: doc.documentNumber,
    revisionNumber: doc.revisionTag,
    clientName: doc.clientName,
    drawnBy: doc.preparedBy,
    checkedBy: doc.checkedBy,
    approvedBy: doc.approvedBy,
    dateString: DateTime.now().toIso8601String().split('T').first,
  );
}

/// Export the mechanical riser single-line as a native (vector) PDF. Routed
/// through the shared export guard (H3) like its sibling set exports below:
/// zero-length gate + try/catch + the "Exported ..." pill + Report-stage
/// credit — never a silent bare write.
Future<void> exportMechanicalRiserPdf(WidgetRef ref, ServiceType? focus) =>
    runExportGuarded(
      ref,
      name: 'riser single-line (PDF)',
      write: () async {
        final sheet = buildLiveRiserSheet(ref, focus);
        final bytes = sldSheetToPdf(
          sheet: sheet,
          title: 'iSystem mechanical single-line',
          diagramTitle: _diagramTitle(focus),
          chrome: _riserChrome(ref, index: 1, total: 1),
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
        if (path == null) return false;
        final full = path.endsWith('.pdf') ? path : '$path.pdf';
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// Export the mechanical riser single-line as a DXF (R12) drawing file. Routed
/// through the shared export guard (H3) — see [exportMechanicalRiserPdf].
Future<void> exportMechanicalRiserDxf(WidgetRef ref, ServiceType? focus) =>
    runExportGuarded(
      ref,
      name: 'riser single-line (DXF)',
      write: () async {
        final sheet = buildLiveRiserSheet(ref, focus);
        final dxf = sldSheetToDxf(
          sheet: sheet,
          diagramTitle: _diagramTitle(focus),
          chrome: _riserChrome(ref, index: 1, total: 1),
        );
        final project = ref.read(projectControllerProvider);
        final base = project.name.isEmpty ? 'mechanical' : project.name;
        final path = await FilePicker.saveFile(
          dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleSldDxf),
          fileName: '$base-riser-sld.dxf',
          type: FileType.custom,
          allowedExtensions: const ['dxf'],
        );
        if (path == null) return false;
        final full = path.endsWith('.dxf') ? path : '$path.dxf';
        await File(full).writeAsString(dxf);
        return true;
      },
    );

// ── B3: the numbered riser drawing SET (all systems) ─────────────────────────

/// The services that get their own sheet in the riser drawing SET — those with
/// at least one drawn edge, in the canonical draw order. Public for the export
/// wiring test.
List<ServiceType> riserSetServices(Network net) => [
      for (final s in kDrawServices)
        if (net.edges.any((e) => e.service == s)) s,
    ];

/// The set's sheet sequence: the combined all-systems sheet first, then one
/// focused sheet per service actually drawn.
List<ServiceType?> _riserSetFoci(WidgetRef ref) => [
      null,
      ...riserSetServices(ref.read(networkControllerProvider).network),
    ];

/// Export the riser drawing SET as ONE multi-page vector PDF: the combined
/// sheet, then one sheet per drawn system, each page stamped with its own
/// heading and a real `Sheet i of t` counter (the multi-page engine re-stamps
/// the counter per page) over the shared document-control chrome. [focus] is
/// accepted for menu-signature parity but ignored — the set always covers all
/// systems. Routed through the shared export guard + "Exported ..." feedback.
Future<void> exportMechanicalRiserSetPdf(
        WidgetRef ref, ServiceType? focus) =>
    runExportGuarded(
      ref,
      name: 'riser drawing set',
      write: () async {
        final foci = _riserSetFoci(ref);
        final project = ref.read(projectControllerProvider);
        final bytes = electricalSldSheetsToPdf(
          sheets: [for (final f in foci) buildLiveRiserSheet(ref, f)],
          title: 'iSystem mechanical riser drawing set',
          diagramTitles: [for (final f in foci) _diagramTitle(f)],
          chrome: _riserChrome(ref, index: 1, total: foci.length),
          projectName:
              project.name.isEmpty ? 'Untitled project' : project.name,
        );
        final base = project.name.isEmpty ? 'mechanical' : project.name;
        final path = await FilePicker.saveFile(
          dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleRiserSetPdf),
          fileName: '$base-riser-set.pdf',
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (path == null) return false;
        final full = path.endsWith('.pdf') ? path : '$path.pdf';
        await File(full).writeAsBytes(bytes);
        return true;
      },
    );

/// Export the riser drawing SET as a numbered DXF file series: the user picks
/// ONE base name and each sheet writes beside it with its system suffix —
/// `base-ALL.dxf` (combined) then `base-CW.dxf`, `base-D.dxf`, ... — each file
/// carrying its own `Sheet i of t` document-control chrome. [focus] is accepted
/// for menu-signature parity but ignored.
Future<void> exportMechanicalRiserSetDxf(
        WidgetRef ref, ServiceType? focus) =>
    runExportGuarded(
      ref,
      name: 'riser drawing set',
      write: () async {
        final foci = _riserSetFoci(ref);
        final project = ref.read(projectControllerProvider);
        final base = project.name.isEmpty ? 'mechanical' : project.name;
        final path = await FilePicker.saveFile(
          dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleRiserSetDxf),
          fileName: '$base-riser-set.dxf',
          type: FileType.custom,
          allowedExtensions: const ['dxf'],
        );
        if (path == null) return false;
        final stem =
            path.endsWith('.dxf') ? path.substring(0, path.length - 4) : path;
        for (var i = 0; i < foci.length; i++) {
          final f = foci[i];
          final code = f == null ? 'ALL' : riserServiceCode(f);
          final dxf = sldSheetToDxf(
            sheet: buildLiveRiserSheet(ref, f),
            diagramTitle: _diagramTitle(f),
            chrome: _riserChrome(ref, index: i + 1, total: foci.length),
          );
          await File('$stem-$code.dxf').writeAsString(dxf);
        }
        return true;
      },
    );
