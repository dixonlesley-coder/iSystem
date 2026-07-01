import 'dart:convert';
import 'dart:io';

import 'project_document.dart';
import '../store/models/sheet.dart';

/// Portable-project support: embed each sheet's SOURCE plan (the PDF/DXF the
/// canvas renders) into the `.mechx` so the file is self-contained, and extract
/// them back to local files on open so the existing path-based renderers work
/// unchanged.
///
/// A sheet renders from its `pdfPath` (PDF) or `dxfPath` (DXF, incl. a converted
/// DWG). We embed THAT file, keyed by its path, so a multi-page PDF (many sheets
/// sharing one path) is stored once. DWG stays converted-to-DXF on embed, so the
/// receiving machine needs no ODA converter to reopen the project.

/// The persistent directory embedded plans are extracted into on open. Mirrors
/// the recovery/DWG-cache use of [Directory.systemTemp] (no `path_provider`
/// dependency).
String projectAssetsDir() {
  final dir = Directory('${Directory.systemTemp.path}/mechx_assets');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir.path;
}

/// The file a [sheet] renders from — the source plan to embed. `pdfPath` wins
/// (PDF sheet); else `dxfPath` (DXF or a converted-DWG sheet). Null = a
/// placeholder sheet with nothing to embed.
String? sheetSourcePath(Sheet sheet) => sheet.pdfPath ?? sheet.dxfPath;

/// Read every distinct sheet source file and return `path → base64(gzip(bytes))`,
/// ready to attach as [ProjectDocument.assets]. Plans are gzip-compressed before
/// base64 (PDF/DXF are highly compressible), clawing back most of base64's ~33 %
/// inflation. A missing/unreadable file is skipped (the project still saves; that
/// sheet just isn't portable).
Map<String, String> gatherSheetAssets(List<Sheet> sheets) {
  final out = <String, String>{};
  for (final s in sheets) {
    final path = sheetSourcePath(s);
    if (path == null || out.containsKey(path)) continue;
    try {
      final f = File(path);
      if (!f.existsSync()) continue;
      out[path] = base64Encode(gzip.encode(f.readAsBytesSync()));
    } catch (_) {
      // Unreadable — skip; the rest of the project still embeds.
    }
  }
  return out;
}

/// Decode one embedded asset's base64 payload back to the original file bytes.
/// Payloads are gzip-compressed (detected by the `1f 8b` magic); a raw-base64
/// payload from before compression landed is passed through unchanged, so older
/// portable files still open.
List<int> _decodeAsset(String b64) {
  final raw = base64Decode(b64);
  final gzipped = raw.length >= 2 && raw[0] == 0x1f && raw[1] == 0x8b;
  return gzipped ? gzip.decode(raw) : raw;
}

/// Return a copy of [doc] with every embedded asset extracted to a local file
/// and the referencing sheet paths repointed at it — so an opened portable
/// project renders even if the original plan files aren't on this machine. A
/// document with no [ProjectDocument.assets] is returned unchanged.
ProjectDocument rehydrateAssets(ProjectDocument doc) {
  if (doc.assets.isEmpty) return doc;
  final dir = projectAssetsDir();

  // Extract each asset once to a stable, content-derived local path.
  final localForKey = <String, String>{};
  doc.assets.forEach((key, b64) {
    try {
      final bytes = _decodeAsset(b64);
      final ext = key.toLowerCase().endsWith('.pdf') ? 'pdf' : 'dxf';
      final id = '${key.hashCode.toUnsigned(32).toRadixString(16)}_${bytes.length}';
      final file = File('$dir/$id.$ext');
      if (!file.existsSync()) file.writeAsBytesSync(bytes);
      localForKey[key] = file.path;
    } catch (_) {
      // Corrupt asset — leave the sheet pointing at its original path.
    }
  });
  if (localForKey.isEmpty) return doc;

  final sheets = <Sheet>[
    for (final s in doc.sheets) _repoint(s, localForKey),
  ];
  return doc.withSheets(sheets);
}

/// Repoint a sheet's render path (pdf or dxf) at the extracted local file when
/// its original path was embedded; otherwise return it unchanged.
Sheet _repoint(Sheet s, Map<String, String> localForKey) {
  if (s.pdfPath != null && localForKey.containsKey(s.pdfPath)) {
    return s.copyWith(pdfPath: localForKey[s.pdfPath]);
  }
  if (s.dxfPath != null && localForKey.containsKey(s.dxfPath)) {
    return s.copyWith(dxfPath: localForKey[s.dxfPath]);
  }
  return s;
}
