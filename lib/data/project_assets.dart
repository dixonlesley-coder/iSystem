import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' show sha256;

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

/// Round 10 (import-pipeline-1) — the embedded payloads this process already
/// holds, keyed by the LOCAL path a sheet renders from (the original source
/// path after a Save; the extracted `mechx_assets/<sha>` path after an Open).
/// Save rebuilds the asset map from disk every time, so without this a plan
/// whose source vanished (an unplugged USB stick, a temp-cleaned extraction)
/// was silently DROPPED from the re-saved `.mechx`. The gather now falls back
/// to the payload already embedded. Main-isolate state only — the isolate
/// gathers receive the relevant slice as a plain sendable map.
final Map<String, String> _knownPayloads = <String, String>{};

/// Remember [byLocalPath] (`local path → base64(gzip(bytes))`) as embedded
/// payloads the next Save may fall back to. Called with an opened document's
/// re-keyed [ProjectDocument.assets] (see [rehydrateAssets]) and after every
/// gather.
void rememberEmbeddedAssets(Map<String, String> byLocalPath) =>
    _knownPayloads.addAll(byLocalPath);

/// Replace every remembered payload with [byLocalPath] — called when a project
/// is OPENED (or recovered), so the previous project's plan payloads are
/// released instead of accumulating for the whole process lifetime.
void replaceEmbeddedAssets(Map<String, String> byLocalPath) => _knownPayloads
  ..clear()
  ..addAll(byLocalPath);

/// Keep only the payloads for [paths] (the sheets the project still renders
/// from) and add [gathered] — so a payload for a removed sheet is released at
/// the next Save rather than held for the process lifetime.
void _rememberGathered(List<String> paths, Map<String, String> gathered) {
  final keep = paths.toSet();
  _knownPayloads
    ..removeWhere((k, _) => !keep.contains(k))
    ..addAll(gathered);
}

/// Forget every remembered payload (tests).
void debugClearEmbeddedAssets() => _knownPayloads.clear();

/// Read every distinct sheet source file and return `path → base64(gzip(bytes))`,
/// ready to attach as [ProjectDocument.assets]. Plans are gzip-compressed before
/// base64 (PDF/DXF are highly compressible), clawing back most of base64's ~33 %
/// inflation. A missing/unreadable file falls back to the payload already
/// embedded for that path ([rememberEmbeddedAssets]); with neither it is
/// skipped (the project still saves; [missingSheetAssetPaths] names it so the
/// caller can warn).
Map<String, String> gatherSheetAssets(List<Sheet> sheets) {
  final paths = _distinctSheetSourcePaths(sheets);
  final out = _gatherFromPaths(paths, _fallbackFor(paths));
  _rememberGathered(paths, out);
  return out;
}

/// The distinct sheet source paths that ended up WITHOUT a payload in [assets]
/// — plans that could not be embedded (source unreadable and nothing embedded
/// before). Empty ⇒ the saved file is fully portable.
List<String> missingSheetAssetPaths(
        List<Sheet> sheets, Map<String, String> assets) =>
    [
      for (final p in _distinctSheetSourcePaths(sheets))
        if (!assets.containsKey(p)) p,
    ];

Map<String, String> _fallbackFor(List<String> paths) => {
      for (final p in paths)
        if (_knownPayloads[p] != null) p: _knownPayloads[p]!,
    };

/// The distinct source paths [sheets] render from, in first-seen order (the same
/// dedup [gatherSheetAssets] applies) — the sendable input for the off-thread
/// gather. Sheets aren't trivially isolate-portable, but their plain-string paths
/// are, so we reduce to paths on the caller's thread.
List<String> _distinctSheetSourcePaths(List<Sheet> sheets) {
  final paths = <String>[];
  final seen = <String>{};
  for (final s in sheets) {
    final path = sheetSourcePath(s);
    if (path == null || !seen.add(path)) continue;
    paths.add(path);
  }
  return paths;
}

/// Read every path and return `path → base64(gzip(bytes))`. The pure, sendable
/// half of the gather (plain [String] paths + fallback payloads in, a
/// `Map<String,String>` out) so it runs verbatim on the caller's thread OR
/// inside an [Isolate]. An unreadable path takes its [fallback] payload.
Map<String, String> _gatherFromPaths(
    List<String> paths, Map<String, String> fallback) {
  final out = <String, String>{};
  for (final path in paths) {
    try {
      final f = File(path);
      if (f.existsSync()) {
        out[path] = base64Encode(gzip.encode(f.readAsBytesSync()));
        continue;
      }
    } catch (_) {
      // Unreadable — fall through to the already-embedded payload.
    }
    final prior = fallback[path];
    if (prior != null) out[path] = prior;
  }
  return out;
}

/// The off-UI-thread variant of [gatherSheetAssets]: the synchronous gzip+base64
/// of every plan (a real window freeze on a large project) runs on an [Isolate]
/// so the UI stays responsive during a portable Save. The distinct paths (and
/// their fallback payloads) are resolved on the caller's thread (only sendable
/// [String]s cross the boundary), and the returned map is byte-identical to the
/// synchronous [gatherSheetAssets]. An empty path set skips the isolate spin-up.
Future<Map<String, String>> gatherSheetAssetsAsync(List<Sheet> sheets) async {
  final paths = _distinctSheetSourcePaths(sheets);
  if (paths.isEmpty) return const {};
  final fallback = _fallbackFor(paths);
  final out = await Isolate.run(() => _gatherFromPaths(paths, fallback));
  _rememberGathered(paths, out);
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

  // Extract each asset once to a stable, CONTENT-derived local path: the name
  // is a SHA-256 of the decoded bytes (+ length), so two different plans that
  // were embedded under the same source path (rev A / rev B of
  // C:\plans\denah.dxf, or two projects importing Downloads\denah.dxf) can
  // never collide — and an equal name implies equal content, so the
  // exists-skip below is safe.
  final localForKey = <String, String>{};
  final byLocal = <String, String>{};
  doc.assets.forEach((key, b64) {
    try {
      final bytes = _decodeAsset(b64);
      final ext = key.toLowerCase().endsWith('.pdf') ? 'pdf' : 'dxf';
      final id = '${sha256.convert(bytes)}_${bytes.length}';
      final file = File('$dir/$id.$ext');
      // Round 10 (import-pipeline-5) — an existing file is reused only when its
      // on-disk length matches (a crash / disk-full mid-extraction would leave
      // a TRUNCATED file under the right content name that every later Open
      // reused); the write itself goes to a `.tmp` sibling renamed into place,
      // so a torn write never lands under the content name.
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        final tmp = File('${file.path}.tmp');
        tmp.writeAsBytesSync(bytes, flush: true);
        tmp.renameSync(file.path);
      }
      localForKey[key] = file.path;
      byLocal[file.path] = b64;
    } catch (_) {
      // Corrupt asset — leave the sheet pointing at its original path.
    }
  });
  if (localForKey.isEmpty) return doc;

  final sheets = <Sheet>[
    for (final s in doc.sheets) _repoint(s, localForKey),
  ];
  // The returned document's assets are RE-KEYED by the local path each sheet
  // now renders from, so the caller can [rememberEmbeddedAssets] them and a
  // later Save keeps the plan even if that extraction is cleaned away. Assets
  // that failed to extract keep their original key.
  final rekeyed = <String, String>{
    for (final e in doc.assets.entries)
      if (!localForKey.containsKey(e.key)) e.key: e.value,
    ...byLocal,
  };
  return doc.withSheets(sheets, assets: rekeyed);
}

/// The off-UI-thread variant of the whole OPEN decode path: JSON-decode
/// [source] (a large `.mechx` can be a sizeable object graph to parse) and
/// [rehydrateAssets] it (gunzip + disk writes) TOGETHER on one [Isolate] — the
/// two heaviest steps opening a portable project incurs, mirroring
/// [gatherSheetAssetsAsync]'s offload for the symmetric Save-side embed. Doing
/// both steps in one isolate hop (rather than decoding on the UI thread, then
/// hopping again just to rehydrate) avoids shipping the freshly-decoded — and
/// potentially large — document across the isolate boundary twice. Throws
/// [ProjectDocumentException] for a malformed/unsupported file exactly as
/// [ProjectDocument.decode] does (`Isolate.run` rethrows the same exception
/// type in the calling isolate).
Future<ProjectDocument> decodeAndRehydrateAsync(String source) =>
    Isolate.run(() => rehydrateAssets(ProjectDocument.decode(source)));

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
