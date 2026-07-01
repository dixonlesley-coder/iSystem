import 'dart:io';

import 'package:mechx_engine/geometry/dxf_drawing.dart';

import '../store/models/sheet.dart';
import 'dwg_converter.dart';
import 'dxf_import.dart' show dxfContentSize;

/// Persistent directory the DWG→DXF conversions are cached in, so a converted
/// plan survives across the session (and usually across restarts). Created on
/// first use. (No `path_provider` dependency — mirrors the recovery file's use
/// of [Directory.systemTemp].)
String dwgCacheDir() {
  final dir = Directory('${Directory.systemTemp.path}/mechx_dwg_cache');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir.path;
}

/// Reads a binary **DWG** CAD floor plan by first converting it to DXF (DWG's
/// format is proprietary — there is no in-process reader), then feeding the
/// produced DXF through the same pipeline as [importDxf]. Returns a single
/// [Sheet] whose canvas background is the converted DXF ([Sheet.dxfPath]) while
/// the original DWG is kept as provenance ([Sheet.dwgPath]).
///
/// [converter] does the DWG→DXF step (injected for tests). [outDir] is a
/// PERSISTENT directory the converted DXF lives in, so it survives across app
/// runs (a temp dir would break a reopened project).
///
/// Throws a [StateError] with a user-facing message when the converter is
/// missing, the conversion fails, or the result carries no geometry — the caller
/// surfaces it in the load-error banner.
Future<List<Sheet>> importDwg(
  String filePath, {
  required DwgConverter converter,
  required String outDir,
}) async {
  final basename = File(filePath).uri.pathSegments.last;
  final lower = basename.toLowerCase();
  final stem = lower.endsWith('.dwg')
      ? basename.substring(0, basename.length - 4)
      : basename;

  final result = await converter.toDxf(filePath, outDir);
  if (!result.isOk) {
    throw StateError(result.message ??
        'Could not convert DWG "$basename" — install the ODA File Converter or '
            'export to DXF.');
  }

  final dxfPath = result.dxfPath!;
  final drawing = parseDxf(File(dxfPath).readAsStringSync());
  if (drawing == null || drawing.isEmpty) {
    throw StateError('DWG "$basename" converted, but the DXF had no geometry.');
  }

  return [
    Sheet(
      id: '$stem#0',
      name: stem,
      dxfPath: dxfPath,
      dwgPath: filePath,
      pageIndex: 0,
      sizePx: dxfContentSize(drawing.bounds),
    ),
  ];
}
