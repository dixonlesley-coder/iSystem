// Round 24 — app half of the round-24 review fixes.
//
//   regression-mep-legacy-typed-character-reverted
//     A pre-round-23 .mechx carries NO provenance flags. Those builds never
//     re-derived a machine way's cos phi / phases / load kind, so an unflagged
//     value that differs from the mint may be one the engineer typed. The
//     first sync after Open must KEEP it (and record the provenance), never
//     revert it to the mint (golden rule 7: migrate, don't break old files).
//   import-2-1  'Apply scale to all sheets' rescales DXF -> DXF by the two
//               import frames, keeps PDF -> PDF verbatim, skips mixed pairs
//   import-2-2  Replace-all keeps a surviving sheet's work on ITS floor
//   import-2-3  a DXF sheet's import frame round-trips + survives a DXF
//               revision; a changed extent is detected
//   import-2-4  a multi-page replacement lists the sheet's own page first

import 'dart:convert';

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/shell/project_io.dart' show orderReplacementPages;
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart' show LoadKind;
import 'package:mechx_engine/electrical/load_list.dart' show defaultMotorCosPhi;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart' show DxfBounds;
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

Future<void> _settle(ProviderContainer c) async {
  await Future<void>.delayed(Duration.zero);
  c.read(electricalProjectProvider);
}

ElectricalCircuit _mepWay(ProviderContainer c) => c
    .read(electricalProjectProvider)
    .panels
    .firstWhere((p) => p.id == kMepEquipmentPanelId)
    .circuits
    .single;

Future<ProviderContainer> _ahu() async {
  final c = _c();
  c.read(projectControllerProvider.notifier)
    ..setFloors([Floor('L0', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(electricalProjectProvider);
  c
      .read(networkControllerProvider.notifier)
      .addComponentNode('s1', 0, const Offset(700, 200), NodeComponent.ahu);
  await _settle(c);
  return c;
}

/// Re-encode the live project as a LEGACY (pre-round-23) file would have
/// stored it: no `*UserSet` flags, no provenance marker, and the MEP way
/// carrying [edit]'s typed values.
ElectricalProject _legacy(
  ElectricalProject p,
  void Function(Map<String, dynamic> way) edit,
) {
  final json = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
  for (final panel in (json['panels'] as List).cast<Map<String, dynamic>>()) {
    for (final w in (panel['circuits'] as List).cast<Map<String, dynamic>>()) {
      if (w['sourceEquipmentId'] == null) continue;
      w
        ..remove('cosPhiUserSet')
        ..remove('phasesUserSet')
        ..remove('loadKindUserSet')
        ..remove('demandFactorUserSet')
        ..remove(ElectricalCircuit.kMepProvenanceKey);
      edit(w);
    }
  }
  return ElectricalProject.fromJson(json);
}

void main() {
  group('legacy MEP-way character survives the first sync (migration)', () {
    test('typed cos phi 0.95 + phases 1 are kept and flagged', () async {
      final c = await _ahu();
      final minted = _mepWay(c);
      // The mint: cos phi = defaultMotorCosPhi (0.85), three-phase.
      expect(minted.cosPhi, closeTo(defaultMotorCosPhi, 1e-12));
      expect(minted.phases, 3);
      final e = c.read(electricalProjectProvider.notifier);
      e.setProject(_legacy(c.read(electricalProjectProvider), (w) {
        w['cosPhi'] = 0.95;
        w['phases'] = 1;
      }));
      expect(_mepWay(c).legacyProvenance, isTrue);
      e.resyncMepEquipment();
      final now = _mepWay(c);
      expect(now.cosPhi, 0.95);
      expect(now.phases, 1);
      expect(now.cosPhiUserSet, isTrue);
      expect(now.phasesUserSet, isTrue);
      // The untouched load kind stays machine-owned.
      expect(now.loadKindUserSet, isFalse);
      expect(now.legacyProvenance, isFalse);
      // Re-saved: the provenance marker + flags are now on disk.
      final j = now.toJson();
      expect(j[ElectricalCircuit.kMepProvenanceKey], 1);
      expect(j['cosPhiUserSet'], isTrue);
    });

    test('a legacy value the old mint produced is not locked as typed (r2)',
        () async {
      final c = _c();
      c.read(projectControllerProvider.notifier)
        ..setFloors([Floor('L0', const Length(3.5))])
        ..setCalibration('s1', const ScaleCalibration(0.01));
      c.read(electricalProjectProvider);
      c.read(networkControllerProvider.notifier).addComponentNode(
          's1', 0, const Offset(700, 200), NodeComponent.acCassette);
      await _settle(c);
      expect(_mepWay(c).loadKind, LoadKind.hvac);
      final e = c.read(electricalProjectProvider.notifier);
      // A pre-hvac build minted the AC unit as a `motor` at the historical
      // cos phi: both are machine values, not typed ones.
      e.setProject(_legacy(c.read(electricalProjectProvider), (w) {
        w['loadKind'] = 'motor';
        w['cosPhi'] = defaultMotorCosPhi;
      }));
      e.resyncMepEquipment();
      var now = _mepWay(c);
      expect(now.loadKind, LoadKind.hvac);
      expect(now.loadKindUserSet, isFalse);
      expect(now.cosPhiUserSet, isFalse);
      // Re-derived Round 42 (regression-mep-kind-lock-traps-spare-rekinded-
      // machine): the drawn machine owns its kind, so even a kind no mint
      // ever produced is migrated back to the mint on a DERIVED way (the
      // kind lock refuses every re-kind, so a kept foreign kind could never
      // be undone).
      e.setProject(_legacy(c.read(electricalProjectProvider), (w) {
        w['loadKind'] = 'general';
      }));
      e.resyncMepEquipment();
      now = _mepWay(c);
      expect(now.loadKind, LoadKind.hvac);
      expect(now.loadKindUserSet, isFalse);
    });

    test('an untouched legacy way stays machine-owned', () async {
      final c = await _ahu();
      final e = c.read(electricalProjectProvider.notifier);
      e.setProject(_legacy(c.read(electricalProjectProvider), (_) {}));
      e.resyncMepEquipment();
      final now = _mepWay(c);
      expect(now.cosPhiUserSet || now.phasesUserSet || now.loadKindUserSet,
          isFalse);
      expect(now.legacyProvenance, isFalse);
    });

    test('a provenance-aware file (marker, no flags) still re-derives',
        () async {
      final c = await _ahu();
      final e = c.read(electricalProjectProvider.notifier);
      final json = jsonDecode(jsonEncode(
          c.read(electricalProjectProvider).toJson())) as Map<String, dynamic>;
      final board = (json['panels'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((p) => p['id'] == kMepEquipmentPanelId);
      final w = (board['circuits'] as List).cast<Map<String, dynamic>>().single;
      expect(w[ElectricalCircuit.kMepProvenanceKey], 1);
      w['cosPhi'] = 0.95; // unflagged in a provenance-aware file ⇒ minted
      e.setProject(ElectricalProject.fromJson(json));
      e.resyncMepEquipment();
      expect(_mepWay(c).cosPhi, closeTo(defaultMotorCosPhi, 1e-12));
    });
  });

  group('import-2-1: scale transfer follows the sheet type', () {
    // Two DXFs at the same CAD scale (mm): gf spans 60 000 x 30 000, l2
    // 40 000 x 20 000. Each is normalised so its longest side is 1684 px:
    // k_gf = 1684 / 60000, k_l2 = 1684 / 40000 content px per mm.
    const gf = Sheet(
        id: 'gf',
        name: 'gf',
        dxfPath: '/x/gf.dxf',
        sizePx: Size(1684, 842),
        dxfFrame: DxfBounds(0, 0, 60000, 30000));
    const l2 = Sheet(
        id: 'l2',
        name: 'l2',
        dxfPath: '/x/l2.dxf',
        sizePx: Size(1684, 842),
        dxfFrame: DxfBounds(0, 0, 40000, 20000));
    const pdf = Sheet(id: 'p', name: 'p', pdfPath: '/x/p.pdf');
    const pdf2 = Sheet(id: 'q', name: 'q', pdfPath: '/x/q.pdf');

    test('DXF -> DXF: l2 real 40 m wall reads 40 m, not 60 m', () {
      // gf calibrated over its 60 m wall = 1684 px: 60 / 1684 m/px.
      const src = ScaleCalibration(60 / 1684);
      final t = transferCalibration(src, from: gf, to: l2)!;
      // mpp_l2 = mpp_gf x k_gf / k_l2 = (60/1684) x (40000/60000) = 40/1684.
      expect(t.metersPerPixel, closeTo(40 / 1684, 1e-12));
      expect(t.lengthForPixels(1684).meters, closeTo(40, 1e-9));
    });

    test('PDF -> PDF verbatim; mixed or frameless skipped', () {
      const src = ScaleCalibration(0.02);
      expect(transferCalibration(src, from: pdf, to: pdf2), src);
      expect(transferCalibration(src, from: pdf, to: gf), isNull);
      expect(transferCalibration(src, from: gf, to: pdf), isNull);
      const legacy = Sheet(id: 'z', name: 'z', dxfPath: '/x/z.dxf');
      expect(transferCalibration(src, from: gf, to: legacy), isNull);
    });

    test('the store applies the rescale and reports skipped sheets', () {
      final c = _c();
      c.read(sheetsControllerProvider.notifier).loadSheets([gf, l2, pdf]);
      final ctrl = c.read(projectControllerProvider.notifier)
        ..setCalibration('gf', const ScaleCalibration(60 / 1684));
      final skipped = <String>{};
      final n = ctrl.applyCalibrationToAllSheets('gf',
          toSheetIds: {'gf', 'l2', 'p'},
          sheets: {for (final s in [gf, l2, pdf]) s.id: s},
          skippedOut: skipped);
      expect(n, 1);
      expect(skipped, {'p'});
      expect(c.read(projectControllerProvider).calibrationFor('l2')!.metersPerPixel,
          closeTo(40 / 1684, 1e-12));
      expect(c.read(projectControllerProvider).calibrationFor('p'), isNull);
    });
  });

  group('import-2-2: Replace-all keeps surviving work on its floor', () {
    test('plan#0 (floor 1) survives as the only sheet: still floor 1', () {
      final c = _c();
      c.read(projectControllerProvider.notifier).setFloors(const [
        Floor('G', Length(3)),
        Floor('L1', Length(3)),
        Floor('L2', Length(3)),
      ]);
      c.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 'site#0', name: 'site'),
        Sheet(id: 'plan#0', name: 'plan'),
      ]);
      c.read(networkControllerProvider.notifier).restoreNetwork(const Network(
            nodes: [
              NetNode(id: 'a', sheetId: 'plan#0', x: 0, y: 0, floorIndex: 1),
              NetNode(id: 'b', sheetId: 'plan#0', x: 100, y: 0, floorIndex: 1),
            ],
            edges: [
              NetEdge(
                  id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
            ],
          ));
      c.read(historyProvider.notifier).reset();
      expect(c.read(sheetsControllerProvider).floorFor('plan#0', 3), 1);

      c
          .read(sheetsControllerProvider.notifier)
          .replaceAllSheets(const [Sheet(id: 'plan#0', name: 'plan rev B')]);
      // Positionally it would be floor 0; the work says floor 1 ⇒ kept.
      expect(c.read(sheetsControllerProvider).floorFor('plan#0', 3), 1);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.map((n) => n.floorIndex).toSet(), {1});
      expect(net.edges, hasLength(1));

      // One structural undo step brings the old set back.
      c.read(historyProvider.notifier).undo();
      expect(c.read(sheetsControllerProvider).sheets.map((s) => s.id),
          ['site#0', 'plan#0']);
    });
  });

  group('import-2-3: the DXF import frame', () {
    test('round-trips in .mechx (absent = legacy)', () {
      const frame = DxfBounds(-5, 10, 40000, 20010);
      const doc = ProjectDocument(
        projectName: 'D',
        floors: [Floor('G', Length(3))],
        calibrations: {},
        sheets: [
          Sheet(
              id: 'd#0',
              name: 'd',
              dxfPath: '/x/d.dxf',
              sizePx: Size(1684, 842),
              dxfFrame: frame),
          Sheet(id: 'p#0', name: 'p', pdfPath: '/x/p.pdf'),
        ],
        network: Network(),
      );
      final back = ProjectDocument.decode(doc.encode());
      final f = back.sheets.first.dxfFrame!;
      expect([f.minX, f.minY, f.maxX, f.maxY], [-5, 10, 40000, 20010]);
      expect(back.sheets.last.dxfFrame, isNull);
    });

    test('a DXF revision keeps the old mapping; the change is detectable', () {
      final c = _c();
      const old = Sheet(
          id: 'd#0',
          name: 'd',
          dxfPath: '/x/d.dxf',
          sizePx: Size(1684, 842),
          dxfFrame: DxfBounds(0, 0, 40000, 20000));
      c.read(sheetsControllerProvider.notifier).loadSheets([old]);
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('d#0', const ScaleCalibration(40 / 1684));
      // rev 2 adds an 8 m boundary line: longest extent 48 m.
      const rev = Sheet(
          id: 'rev#0',
          name: 'rev',
          dxfPath: '/x/rev.dxf',
          sizePx: Size(1684, 701.6666666666666),
          dxfFrame: DxfBounds(0, 0, 48000, 20000));
      c.read(sheetsControllerProvider.notifier).replaceSheetSource('d#0', rev);
      final s = c.read(sheetsControllerProvider).sheets.single;
      expect(s.dxfPath, '/x/rev.dxf');
      expect(s.sizePx, old.sizePx);
      expect(s.dxfFrame!.maxX, 40000);
      // The 40 m wall still spans 1684 px under the unchanged calibration.
      expect(s.dxfContentPerWorld! * 40000, closeTo(1684, 1e-9));
      expect(
          c.read(projectControllerProvider).isCalibrationStale('d#0'), isTrue);
      expect(s.dxfFrame!.differsFrom(rev.dxfFrame!), isTrue);
    });
  });

  test('import-2-4: the replaced sheet\'s own page is listed first', () {
    final pages = [
      for (var i = 0; i < 3; i++)
        Sheet(id: 'denah#$i', name: 'denah', pdfPath: '/x/d.pdf', pageIndex: i),
    ];
    expect(orderReplacementPages(pages, 2).map((s) => s.pageIndex), [2, 0, 1]);
    expect(orderReplacementPages(pages, 0).map((s) => s.pageIndex), [0, 1, 2]);
    expect(orderReplacementPages(pages, 7).map((s) => s.pageIndex), [0, 1, 2]);
  });
}
