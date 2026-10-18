// Round 10 (2026-10-18) — app-side findings from the canvas-geometry and
// import-pipeline lenses, each pinned on the real providers / real files.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart' show buildDocument;
import 'package:mechx/data/dwg_converter.dart';
import 'package:mechx/data/file_stamped_cache.dart';
import 'package:mechx/data/project_assets.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/data/recovery.dart' show appSupportDirOverride;
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/route_geometry.dart';
import 'package:mechx/store/smart_input_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/shell/project_io.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

const _cw = ServiceType.coldWater;

NetworkController _seed(ProviderContainer c, Network net) {
  final n = c.read(networkControllerProvider.notifier);
  n.loadNetwork(net);
  return n;
}

Offset _pos(Network net, String id) {
  final n = net.nodeById(id)!;
  return Offset(n.x, n.y);
}

bool _axisOr45(Offset a, Offset b) {
  final dx = (b.dx - a.dx).abs(), dy = (b.dy - a.dy).abs();
  return dx < 1e-9 || dy < 1e-9 || (dx - dy).abs() < 1e-9;
}

ProjectDocument _doc(String name,
        {List<Sheet> sheets = const [], Map<String, String> assets = const {}}) =>
    ProjectDocument(
      projectName: name,
      floors: const [Floor('Ground', Length(4.0))],
      calibrations: const {},
      sheets: sheets,
      network: const Network(),
      assets: assets,
    );

bool _allFinite(Network net) =>
    net.nodes.every((n) => n.x.isFinite && n.y.isFinite);

void main() {
  // ── canvas-geometry-1 ────────────────────────────────────────────────────
  group('canvas-geometry-1 — smart input rejects non-finite / extra tokens', () {
    test('NaN / Infinity / 1e400 lengths and angles are errors, not lengths',
        () {
      for (final t in const [
        'NaN',
        'Infinity',
        '-Infinity',
        '1e400',
        '3000 NaN',
        '3000 Infinity',
        '3000 1e400',
        '3000 90 junk',
      ]) {
        final r = parseDrawingInput(t);
        expect(r.ok, isFalse, reason: t);
        expect(r.error, isNotNull, reason: t);
      }
      // The valid forms still parse.
      expect(parseDrawingInput('3000').lengthMm, 3000);
      expect(parseDrawingInput('3000 90').angleDeg, 90);
    });

    test('property: every accepted parse is finite (seeded fuzz)', () {
      final rnd = math.Random(1010);
      const pool = [
        '0', '1', '3000', '-5', 'NaN', 'Infinity', '1e308', '1e400', '90',
        'abc', '', '2.5e3', '-0', '45.5',
      ];
      for (var i = 0; i < 2000; i++) {
        final n = 1 + rnd.nextInt(3);
        final text =
            [for (var k = 0; k < n; k++) pool[rnd.nextInt(pool.length)]]
                .join(' ');
        final r = parseDrawingInput(text);
        if (r.ok) {
          expect(r.lengthMm!.isFinite && r.lengthMm! > 0, isTrue, reason: text);
          expect(r.angleDeg == null || r.angleDeg!.isFinite, isTrue,
              reason: text);
        }
      }
    });

    test('placeRunPoint refuses a non-finite world point; the project still '
        'encodes', () {
      final c = _c();
      final n = _seed(c, const Network());
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(double.nan, double.nan));
      n.placeRunPoint('s1', 0, const Offset(double.infinity, 0));
      final net = c.read(networkControllerProvider).network;
      expect(net.edges, isEmpty);
      expect(_allFinite(net), isTrue);
      expect(() => buildDocument(c.read).encode(), returnsNormally);
    });
  });

  // ── canvas-geometry-2 ────────────────────────────────────────────────────
  group('canvas-geometry-2 — the calibration chokepoint refuses a non-finite '
      'scale', () {
    test('Infinity metres-per-pixel is refused; Save still encodes', () {
      final c = _c();
      final p = c.read(projectControllerProvider.notifier);
      p.setCalibration('s1', const ScaleCalibration(0.02));
      p.setCalibration('s1', const ScaleCalibration(double.infinity));
      expect(c.read(projectControllerProvider).calibrationFor('s1'),
          const ScaleCalibration(0.02));
      expect(() => buildDocument(c.read).encode(), returnsNormally);
    });
  });

  // ── canvas-geometry-3 ────────────────────────────────────────────────────
  group('canvas-geometry-3 — offset run refuses NaN / Infinity distances', () {
    test('no NaN/Infinity nodes are created', () {
      final c = _c();
      final n = _seed(
          c,
          const Network(nodes: [
            NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: _cw),
          ]));
      expect(n.offsetEdgeParallel('e1', double.nan, leftSide: true), isNull);
      expect(
          n.offsetEdgeParallel('e1', double.infinity, leftSide: true), isNull);
      final net = c.read(networkControllerProvider).network;
      expect(net.edges, hasLength(1));
      expect(_allFinite(net), isTrue);
      // A real distance still offsets: 50 px left of an East-pointing run on a
      // y-down screen is y = -50.
      final id = n.offsetEdgeParallel('e1', 50, leftSide: true);
      final e = c.read(networkControllerProvider).network.edgeById(id!)!;
      expect(_pos(c.read(networkControllerProvider).network, e.fromId).dy, -50);
    });
  });

  // ── canvas-geometry-4 ────────────────────────────────────────────────────
  group('canvas-geometry-4 — a snapped route start keeps every leg on axis',
      () {
    test('start click 10 px off an existing end: first leg stays horizontal',
        () {
      final c = _c();
      final n = _seed(
          c,
          const Network(nodes: [
            NetNode(id: 'p', sheetId: 's1', x: 0, y: 100, floorIndex: 0),
            NetNode(id: 'q', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'e0', fromId: 'p', toId: 'q', service: _cw),
          ]));
      // Routed from the RAW click (108,106); the store snaps it onto q.
      final pts = orthoRoute(const Offset(108, 106), const Offset(300, 400));
      n.commitRoute('s1', 0, pts, _cw);
      final net = c.read(networkControllerProvider).network;
      final added = net.edges.where((e) => e.id != 'e0').toList();
      expect(added, isNotEmpty);
      // The route starts AT q (the snap target) …
      expect(added.any((e) => e.fromId == 'q' || e.toId == 'q'), isTrue);
      // … and its first leg is the exact horizontal (100,100)->(300,100): the
      // bend re-derives as (end.x, resolvedStart.y), never (300,106).
      for (final e in added) {
        expect(_axisOr45(_pos(net, e.fromId), _pos(net, e.toId)), isTrue,
            reason: '${_pos(net, e.fromId)}->${_pos(net, e.toId)}');
      }
      final first = added.firstWhere((e) => e.fromId == 'q');
      expect(_pos(net, first.toId), const Offset(300, 100));
    });

    test('property: every committed leg is axis/45 for snapped starts (seeded)',
        () {
      final rnd = math.Random(4040);
      for (var i = 0; i < 200; i++) {
        final c = _c();
        final n = _seed(
            c,
            const Network(nodes: [
              NetNode(id: 'p', sheetId: 's1', x: 0, y: 100, floorIndex: 0),
              NetNode(id: 'q', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
            ], edges: [
              NetEdge(id: 'e0', fromId: 'p', toId: 'q', service: _cw),
            ]));
        // A raw start within the 12 px snap radius of q.
        final ang = rnd.nextDouble() * 2 * math.pi;
        final r = rnd.nextDouble() * 11;
        final start = Offset(100 + r * math.cos(ang), 100 + r * math.sin(ang));
        final end = Offset(200 + rnd.nextDouble() * 400,
            200 + rnd.nextDouble() * 400);
        final kind = OrthoRouteKind.values[rnd.nextInt(3)];
        n.commitRoute('s1', 0, orthoRoute(start, end, kind: kind), _cw);
        final net = c.read(networkControllerProvider).network;
        for (final e in net.edges) {
          expect(_axisOr45(_pos(net, e.fromId), _pos(net, e.toId)), isTrue,
              reason: 'seed $i: ${_pos(net, e.fromId)}->${_pos(net, e.toId)}');
        }
      }
    });
  });

  // ── canvas-geometry-5 ────────────────────────────────────────────────────
  group('canvas-geometry-5 — trim/extend + corner never move an end through '
      'its anchor', () {
    test('trim/extend to a boundary BEHIND the anchor is refused', () {
      final c = _c();
      final n = _seed(
          c,
          const Network(nodes: [
            NetNode(id: 'a', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
            NetNode(id: 'm', sheetId: 's1', x: 200, y: 100, floorIndex: 0),
            NetNode(id: 'q0', sheetId: 's1', x: 50, y: 0, floorIndex: 0),
            NetNode(id: 'q1', sheetId: 's1', x: 50, y: 200, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'e1', fromId: 'a', toId: 'm', service: _cw),
            NetEdge(id: 'b1', fromId: 'q0', toId: 'q1', service: _cw),
          ]));
      // Line a->m: a + t·(100,0) meets x=50 at t = -0.5 (< 0) ⇒ behind a.
      expect(n.trimExtendEdge('e1', 'm', 'b1'), isFalse);
      expect(n.canUndo, isFalse);
      expect(_pos(c.read(networkControllerProvider).network, 'm'),
          const Offset(200, 100));
    });

    test('a corner behind one anchor is refused', () {
      final c = _c();
      final n = _seed(
          c,
          const Network(nodes: [
            NetNode(id: 'aa', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
            NetNode(id: 'ea', sheetId: 's1', x: 200, y: 100, floorIndex: 0),
            NetNode(id: 'ab', sheetId: 's1', x: 50, y: 200, floorIndex: 0),
            NetNode(id: 'eb', sheetId: 's1', x: 50, y: 150, floorIndex: 0),
          ], edges: [
            NetEdge(id: 'ea1', fromId: 'aa', toId: 'ea', service: _cw),
            NetEdge(id: 'eb1', fromId: 'ab', toId: 'eb', service: _cw),
          ]));
      // Corner (50,100): tA = (50-100)/100 = -0.5 (behind aa), tB = +2 (ahead).
      expect(n.joinCorner('ea', 'eb'), isFalse);
      expect(n.canUndo, isFalse);
    });

    test('property: a successful trim/extend never reverses the run (seeded)',
        () {
      final rnd = math.Random(5050);
      for (var i = 0; i < 300; i++) {
        double r() => rnd.nextDouble() * 400;
        final a = Offset(r(), r()), m = Offset(r(), r());
        final q0 = Offset(r(), r()), q1 = Offset(r(), r());
        final c = _c();
        final n = _seed(
            c,
            Network(nodes: [
              NetNode(id: 'a', sheetId: 's1', x: a.dx, y: a.dy, floorIndex: 0),
              NetNode(id: 'm', sheetId: 's1', x: m.dx, y: m.dy, floorIndex: 0),
              NetNode(
                  id: 'q0', sheetId: 's1', x: q0.dx, y: q0.dy, floorIndex: 0),
              NetNode(
                  id: 'q1', sheetId: 's1', x: q1.dx, y: q1.dy, floorIndex: 0),
            ], edges: const [
              NetEdge(id: 'e1', fromId: 'a', toId: 'm', service: _cw),
              NetEdge(id: 'b1', fromId: 'q0', toId: 'q1', service: _cw),
            ]));
        if (!n.trimExtendEdge('e1', 'm', 'b1')) continue;
        final net = c.read(networkControllerProvider).network;
        final e1 = net.edgeById('e1')!;
        final moved = _pos(net, e1.fromId == 'a' ? e1.toId : e1.fromId);
        // Same direction from the anchor as before: dot product > 0.
        final before = m - a, after = moved - a;
        expect(before.dx * after.dx + before.dy * after.dy, greaterThan(0),
            reason: 'seed $i');
      }
    });
  });

  // ── canvas-geometry-6 ────────────────────────────────────────────────────
  group('canvas-geometry-6 — a corrupt saved viewport is dropped on load', () {
    test('scale 0 / negative / out-of-range entries drop; a sane one loads',
        () {
      final doc = _doc('V');
      final json = jsonDecode(doc.encode()) as Map<String, dynamic>;
      json['viewports'] = {
        's0': {'scale': 0, 'dx': 1, 'dy': 2},
        'sneg': {'scale': -2, 'dx': 0, 'dy': 0},
        'shuge': {'scale': 1e9, 'dx': 0, 'dy': 0},
        'sok': {'scale': 1.5, 'dx': 3, 'dy': 4},
      };
      final back = ProjectDocument.decode(jsonEncode(json));
      expect(back.viewports.keys, ['sok']);
      expect(back.viewports['sok']!.scale, 1.5);
      expect(back.viewports['sok']!.offset, const Offset(3, 4));
      expect(ViewportTransform.minScale, greaterThan(0));
    });
  });

  // ── import-pipeline-1 / -5 ───────────────────────────────────────────────
  group('import-pipeline-1/5 — embedded plans survive a re-save; torn '
      'extractions are rewritten', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mechx_r10_assets');
      debugClearEmbeddedAssets();
    });
    tearDown(() {
      debugClearEmbeddedAssets();
      tmp.deleteSync(recursive: true);
    });

    test('a vanished source falls back to the payload already embedded', () {
      final plan = File('${tmp.path}/denah.dxf')
        ..writeAsStringSync('0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n');
      final sheets = [
        Sheet(id: 's1', name: 'S1', dxfPath: plan.path, sizePx: const Size(10, 10)),
      ];
      final first = gatherSheetAssets(sheets);
      expect(first.keys, [plan.path]);
      plan.deleteSync(); // the USB stick is unplugged
      final second = gatherSheetAssets(sheets);
      expect(second, first); // the plan is NOT dropped from the re-save
      expect(missingSheetAssetPaths(sheets, second), isEmpty);
    });

    test('an opened project re-keys its assets by the extracted path, so a '
        'cleaned extraction still re-embeds', () {
      final bytes = utf8.encode('0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n');
      final payload = base64Encode(gzip.encode(bytes));
      final doc = _doc('P',
          sheets: const [
            Sheet(id: 's1', name: 'S1', dxfPath: r'C:\usb\denah.dxf'),
          ],
          assets: {r'C:\usb\denah.dxf': payload});
      final opened = rehydrateAssets(doc);
      final local = opened.sheets.single.dxfPath!;
      expect(opened.assets.keys, [local]);
      rememberEmbeddedAssets(opened.assets);
      File(local).deleteSync(); // temp cleanup removed the extraction
      final regathered = gatherSheetAssets(opened.sheets);
      expect(regathered[local], payload);
    });

    test('neither a readable file nor a prior payload ⇒ reported missing', () {
      final sheets = [
        Sheet(id: 's1', name: 'S1', dxfPath: '${tmp.path}/gone.dxf'),
      ];
      final assets = gatherSheetAssets(sheets);
      expect(assets, isEmpty);
      expect(missingSheetAssetPaths(sheets, assets), ['${tmp.path}/gone.dxf']);
    });

    test('a truncated file under the content name is rewritten on rehydrate',
        () {
      final bytes = List<int>.generate(3600, (i) => 48 + i % 10);
      final payload = base64Encode(gzip.encode(bytes));
      final doc = _doc('P',
          sheets: const [Sheet(id: 's1', name: 'S1', dxfPath: '/x/plan.dxf')],
          assets: {'/x/plan.dxf': payload});
      // First extraction to learn the content-hash path, then tear it.
      final local = rehydrateAssets(doc).sheets.single.dxfPath!;
      File(local).writeAsBytesSync(bytes.sublist(0, 10));
      final again = rehydrateAssets(doc).sheets.single.dxfPath!;
      expect(again, local);
      expect(File(again).lengthSync(), 3600);
    });
  });

  // ── import-pipeline-2 ────────────────────────────────────────────────────
  group('import-pipeline-2 — the plan parse cache re-reads a revised file', () {
    test('same path, new content ⇒ re-loaded; unchanged ⇒ cached', () async {
      final tmp = Directory.systemTemp.createTempSync('mechx_r10_cache');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final f = File('${tmp.path}/denah.dxf')..writeAsStringSync('rev1');
      var loads = 0;
      final cache = FileStampedCache<String>((p) {
        loads++;
        return File(p).readAsStringSync();
      });
      expect(cache.get(f.path), 'rev1');
      expect(cache.get(f.path), 'rev1');
      expect(loads, 1);
      // The architect's rev2 overwrites the file in place (different size).
      f.writeAsStringSync('rev2-wider');
      expect(cache.get(f.path), 'rev2-wider');
      expect(loads, 2);
      // Same size, new mtime also re-loads.
      f.writeAsStringSync('rev3-wider');
      f.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
      expect(cache.get(f.path), 'rev3-wider');
    });
  });

  // ── import-pipeline-3 ────────────────────────────────────────────────────
  group('import-pipeline-3 — a failed DWG reconversion is a failure', () {
    test('fake ODA: rev1 converts, rev2 fails ⇒ failed, never the stale DXF',
        () async {
      if (Platform.isWindows) return; // the fake converter is a POSIX script
      final tmp = Directory.systemTemp.createTempSync('mechx_r10_dwg');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final mode = File('${tmp.path}/mode')..writeAsStringSync('ok');
      final oda = File('${tmp.path}/fake_oda.sh')
        ..writeAsStringSync('#!/bin/sh\n'
            'if [ "\$(cat ${mode.path})" = "ok" ]; then\n'
            '  for f in "\$1"/*.dwg; do b=\$(basename "\$f" .dwg); '
            'cp "\$f" "\$2/\$b.dxf"; done\n'
            '  exit 0\n'
            'fi\n'
            'echo "unsupported DWG version" >&2\n'
            'exit 1\n');
      await Process.run('chmod', ['+x', oda.path]);
      final dwg = File('${tmp.path}/denah.dwg')..writeAsStringSync('REV1');
      final out = Directory('${tmp.path}/cache')..createSync();
      final conv = OdaDwgConverter(binaryOverride: oda.path);

      final r1 = await conv.toDxf(dwg.path, out.path);
      expect(r1.isOk, isTrue);
      expect(File(r1.dxfPath!).readAsStringSync(), 'REV1');

      dwg.writeAsStringSync('REV2-revised');
      mode.writeAsStringSync('fail');
      final r2 = await conv.toDxf(dwg.path, out.path);
      expect(r2.status, DwgConvertStatus.failed);
      expect(r2.dxfPath, isNull);
      // rev1's DXF (content-addressed) is untouched for sheets still using it.
      expect(File(r1.dxfPath!).readAsStringSync(), 'REV1');

      mode.writeAsStringSync('ok');
      final r3 = await conv.toDxf(dwg.path, out.path);
      expect(r3.isOk, isTrue);
      expect(r3.dxfPath, isNot(r1.dxfPath));
      expect(File(r3.dxfPath!).readAsStringSync(), 'REV2-revised');
      expect(File(r1.dxfPath!).readAsStringSync(), 'REV1');
    });
  });

  // ── import-pipeline-4 ────────────────────────────────────────────────────
  group('import-pipeline-4 — Open restores from the .bak after a torn save',
      () {
    setUpAll(() {
      appSupportDirOverride =
          Directory.systemTemp.createTempSync('mechx_r10_open').path;
    });

    test('missing target + valid .bak ⇒ opened from the backup and restored',
        () async {
      final c = _c();
      final tmp = Directory.systemTemp.createTempSync('mechx_r10_bak');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/Gedung.mechx';
      final doc = _doc('Gedung from backup');
      File('$path.bak').writeAsStringSync(doc.encode());
      File('$path.tmp').writeAsStringSync('{"torn'); // the torn write
      await openProjectAtLaunch(c, path);
      expect(c.read(projectControllerProvider).name, 'Gedung from backup');
      expect(c.read(currentProjectPathProvider), path);
      expect(c.read(loadErrorProvider), isNull);
      // The good copy is back in place and the backup is preserved.
      expect(ProjectDocument.decode(File(path).readAsStringSync()).projectName,
          'Gedung from backup');
      expect(File('$path.bak').existsSync(), isTrue);
    });

    test('corrupt target + valid .bak ⇒ opened from the backup', () async {
      final c = _c();
      final tmp = Directory.systemTemp.createTempSync('mechx_r10_bak2');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/Gedung.mechx';
      File(path).writeAsStringSync('{"torn');
      final doc = _doc('Good copy');
      File('$path.bak').writeAsStringSync(doc.encode());
      await openProjectAtLaunch(c, path);
      expect(c.read(projectControllerProvider).name, 'Good copy');
      expect(c.read(loadErrorProvider), isNull);
    });
  });
}
