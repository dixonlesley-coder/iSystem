/// The B12 plan-underlay SNAP SERVICE — the one place a gesture asks "does the
/// imported plan offer a snap point near here?". It unifies the three underlay
/// sources behind a single [UnderlaySnapService.snap] call, in the required
/// precedence:
///
///   DXF/DWG vector candidates  >  traced reference lines  >  PDF ink ridge
///
/// (Node/fitting snap and the magnetic grid are handled by the store — this
/// service sits BETWEEN them: its result is offered to the store only after a
/// node/tee snap failed, and it is preferred over the grid.)
///
///  * DXF/DWG sheets → a cached [UnderlaySnapIndex] built from the SAME parsed
///    [DxfDrawing] the canvas paints (via [DxfSheetPage.cachedDrawing]), mapped
///    into sheet-px through [UnderlayTransform.forSheet]. Built once per path.
///  * Reference lines → always contribute, as a tiny per-call segment index.
///  * PDF sheets → an async, LRU-cached (<=3 sheets) grayscale **luminance map**
///    rendered once via pdfrx; [findInkSnap] finds the nearest dark ridge. The
///    render is fire-and-forget: until it lands, the ink source is simply absent
///    (graceful — vector/reference snapping still works, and a PDF with no ink
///    map yet just falls through to the grid).
///
/// All sources honour the caller's world-space radius (the standard 14 screen-px
/// tolerance ÷ zoom). Nothing here mutates the network; the caller applies the
/// returned point.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../store/models/sheet.dart';
import '../../store/reference_line_store.dart';
import '../../store/sheets_store.dart';
import '../../store/snap_settings_store.dart';
import 'dxf_sheet_page.dart';
import 'ink_snap.dart';
import 'snapping.dart';
import 'underlay_snap.dart';

/// Which underlay source a snap latched onto (for the caller's ring feedback /
/// diagnostics). Precedence order: [vector] > [referenceLine] > [ink].
enum UnderlaySource { vector, referenceLine, ink }

/// One resolved underlay snap: the snapped [point] (sheet/world px), which
/// [source] produced it, its [distance] from the query, and the [kind] of
/// feature it latched onto (the B24 OSNAP marker vocabulary — the UI draws a
/// distinct marker per [SnapKind]). [source] keeps the provenance (vector wall
/// vs traced reference line) even where both read as [SnapKind.refline].
@immutable
class UnderlaySnapHit {
  final Offset point;
  final UnderlaySource source;
  final double distance;
  final SnapKind kind;
  const UnderlaySnapHit(this.point, this.source, this.distance,
      {this.kind = SnapKind.refline});
}

/// Map an underlay [source] + its geometric [uk] to the shared [SnapKind] marker
/// vocabulary: endpoint / intersection / perpendicular are geometric features
/// regardless of the producing line; a plain nearest-on-a-line snap (DXF wall or
/// reference line) reads as [SnapKind.refline]; PDF ink reads as [SnapKind.ink].
SnapKind snapKindForUnderlay(UnderlaySource source, UnderlaySnapKind? uk) {
  if (source == UnderlaySource.ink) return SnapKind.ink;
  switch (uk) {
    case UnderlaySnapKind.endpoint:
      return SnapKind.endpoint;
    case UnderlaySnapKind.intersection:
      return SnapKind.intersection;
    case UnderlaySnapKind.perpendicular:
      return SnapKind.perpendicular;
    case UnderlaySnapKind.onSegment:
    case null:
      return SnapKind.refline;
  }
}

/// Max sheets whose PDF luminance map is kept resident (LRU).
const int _kLumLruMax = 3;

/// Longest edge (px) the PDF page is rendered to for the ink map — bounds memory
/// while keeping wall linework a few px thick for the centreline refine.
const int _kLumMaxEdge = 2000;

/// Cached ink luminance map for one PDF sheet + the sheet-px→luminance-px scale.
class _LumMap {
  final Uint8List lum;
  final int w;
  final int h;

  /// luminance-px per sheet-px (the page was rendered at this fraction of its
  /// content size). Query points (sheet-px) map in by ×[scale]; the returned hit
  /// maps back out by ÷[scale].
  final double scale;
  const _LumMap(this.lum, this.w, this.h, this.scale);
}

/// Provider of the app-wide underlay snap service. A plain [Provider] (the
/// service holds its own caches + kicks off async PDF renders itself; snapping
/// never triggers a provider rebuild, so an idle canvas is byte-identical).
final underlaySnapServiceProvider =
    Provider<UnderlaySnapService>((ref) => UnderlaySnapService());

/// The underlay snap callback for [sheetId] at the current zoom [scale], reading
/// the live 'Snap to plan' toggle + reference-line set, or null when the sheet
/// isn't loaded. Pass into a store gesture's `underlaySnap:` param. [orthoAnchor]
/// (the run's fixed endpoint) keeps a straight run on-axis when Ortho is active;
/// [anchor] (the run's pending start) enables the B24 perpendicular-foot snap.
Offset? Function(Offset world)? underlaySnapFor(
  WidgetRef ref,
  String sheetId,
  double scale, {
  Offset? orthoAnchor,
  Offset? anchor,
}) {
  final sheet = ref.read(sheetsControllerProvider).sheetById(sheetId);
  if (sheet == null) return null;
  return ref.read(underlaySnapServiceProvider).callback(
        sheet,
        ref.read(referenceLinesProvider),
        scale,
        orthoAnchor: orthoAnchor,
        anchor: anchor,
        enabled: ref.read(snapToPlanProvider),
      );
}

class UnderlaySnapService {
  UnderlaySnapService();

  /// DXF/DWG vector index per source path (null = parsed-but-empty/failed).
  final Map<String, UnderlaySnapIndex?> _vectorByPath = {};

  /// PDF ink luminance maps, LRU-ordered by sheet id (most-recent last).
  final Map<String, _LumMap> _lumBySheet = {};

  /// Sheet ids whose luminance render is in flight (so we don't render twice).
  final Set<String> _lumInFlight = {};

  /// Sheet ids whose luminance render FAILED (threw or produced no image) — a
  /// negative memo so a page that can't render is attempted once, not re-scheduled
  /// on every hover-draw frame. Cleared by [invalidateAll] (a new project may reuse
  /// the id for a renderable sheet).
  final Set<String> _lumFailed = {};

  /// Drop every cached underlay index + ink map. Called on `File→Open` /
  /// crash-recovery restore: the caches are keyed by sheet id / source path /
  /// reference-line ids, all of which RESTART deterministically per project
  /// (`stem#i`, `rl0…`), so without this a fresh project could be served the
  /// previous project's snap geometry for a colliding sheet id/path.
  void invalidateAll() {
    _vectorByPath.clear();
    _lumBySheet.clear();
    _lumInFlight.clear();
    _lumFailed.clear();
    _refKey = null;
    _refIdx = null;
  }

  /// Best underlay snap near [world] (sheet/world px) within [radiusWorld], or
  /// null. Gated by [enabled] (the 'Snap to plan' toggle) — off ⇒ always null.
  /// Reference [lines] are filtered to this [sheet]. When [orthoAnchor] is set
  /// (Ortho constrained the angle first) a candidate is accepted only if it lies
  /// near the constrained ray anchor→world, so an underlay snap never bends a
  /// straight run off-axis (same spirit as the magnetic-grid gate).
  ///
  /// [anchor] (the draw run's pending/start point, B24) enables the
  /// **perpendicular-foot** candidate on DXF walls + reference lines — a 90° drop
  /// from the anchor onto a line's interior — offered within the same precedence
  /// (above a plain on-segment hit). Null ⇒ no perpendicular candidates.
  UnderlaySnapHit? snap(
    Sheet sheet,
    List<ReferenceLine> lines,
    Offset world,
    double radiusWorld, {
    required bool enabled,
    Offset? orthoAnchor,
    Offset? anchor,
  }) {
    if (!enabled || radiusWorld <= 0) return null;

    bool onRay(Offset p) {
      if (orthoAnchor == null) return true;
      // Perpendicular distance from p to the infinite ray anchor→world.
      final dx = world.dx - orthoAnchor.dx, dy = world.dy - orthoAnchor.dy;
      final len2 = dx * dx + dy * dy;
      if (len2 <= 1e-9) return true;
      final cross = (p.dx - orthoAnchor.dx) * dy - (p.dy - orthoAnchor.dy) * dx;
      final perp = cross.abs() / math.sqrt(len2);
      return perp <= radiusWorld;
    }

    // 1) DXF/DWG vector candidates (endpoint > intersection > perp > on-segment).
    final vec = _vectorIndexFor(sheet);
    if (vec != null && !vec.isEmpty) {
      final c = vec.query(world.dx, world.dy, radiusWorld,
          anchorX: anchor?.dx, anchorY: anchor?.dy);
      if (c != null) {
        final p = Offset(c.x, c.y);
        if (onRay(p)) {
          return UnderlaySnapHit(p, UnderlaySource.vector, c.distance,
              kind: snapKindForUnderlay(UnderlaySource.vector, c.kind));
        }
      }
    }

    // 2) Traced reference lines (always contribute).
    final refIdx = _referenceIndexFor(sheet.id, lines);
    if (refIdx != null && !refIdx.isEmpty) {
      final c = refIdx.query(world.dx, world.dy, radiusWorld,
          anchorX: anchor?.dx, anchorY: anchor?.dy);
      if (c != null) {
        final p = Offset(c.x, c.y);
        if (onRay(p)) {
          return UnderlaySnapHit(p, UnderlaySource.referenceLine, c.distance,
              kind: snapKindForUnderlay(UnderlaySource.referenceLine, c.kind));
        }
      }
    }

    // 3) PDF ink ridge (lowest precedence). Kicks off the async render on first
    // ask; absent until it lands ⇒ falls through to the grid.
    if (sheet.pdfPath != null) {
      final lum = _lumFor(sheet);
      if (lum != null) {
        final qx = world.dx * lum.scale, qy = world.dy * lum.scale;
        final hit = findInkSnap(
            lum.lum, lum.w, lum.h, qx, qy, radiusWorld * lum.scale);
        if (hit != null) {
          final p = Offset(hit.x / lum.scale, hit.y / lum.scale);
          if (onRay(p)) {
            return UnderlaySnapHit(
                p, UnderlaySource.ink, hit.distance / lum.scale,
                kind: SnapKind.ink);
          }
        }
      }
    }
    return null;
  }

  // ── DXF/DWG vector index ───────────────────────────────────────────────────

  UnderlaySnapIndex? _vectorIndexFor(Sheet sheet) {
    final path = sheet.dxfPath;
    if (path == null) return null;
    final cached = _vectorByPath[path];
    if (cached != null || _vectorByPath.containsKey(path)) return cached;
    final drawing = DxfSheetPage.cachedDrawing(path);
    UnderlaySnapIndex? idx;
    if (drawing != null && !drawing.isEmpty) {
      final t = UnderlayTransform.forSheet(
          drawing.bounds, sheet.sizePx.width, sheet.sizePx.height);
      idx = UnderlaySnapIndex.fromDrawing(drawing, transform: t);
    }
    _vectorByPath[path] = idx;
    return idx;
  }

  // ── Reference-line index (rebuilt per sheet when the set changes) ───────────

  String? _refKey;
  UnderlaySnapIndex? _refIdx;

  UnderlaySnapIndex? _referenceIndexFor(
      String sheetId, List<ReferenceLine> lines) {
    final mine = [for (final l in lines) if (l.sheetId == sheetId) l];
    // A cheap identity key: sheet + count + each id (ref-line edits are rare).
    final key = '$sheetId|${mine.map((l) => l.id).join(',')}';
    if (key == _refKey) return _refIdx;
    _refKey = key;
    _refIdx = mine.isEmpty
        ? null
        : UnderlaySnapIndex.fromSegments(
            [for (final l in mine) UnderlaySegment(l.x1, l.y1, l.x2, l.y2)]);
    return _refIdx;
  }

  // ── PDF ink luminance map (async, LRU) ─────────────────────────────────────

  _LumMap? _lumFor(Sheet sheet) {
    final existing = _lumBySheet[sheet.id];
    if (existing != null) {
      // Touch for LRU recency.
      _lumBySheet.remove(sheet.id);
      _lumBySheet[sheet.id] = existing;
      return existing;
    }
    // A sheet whose page already failed to render stays ink-less — don't churn a
    // fresh pdfrx open+render+dispose on every draw frame.
    if (_lumFailed.contains(sheet.id)) return null;
    _scheduleLumRender(sheet);
    return null;
  }

  void _scheduleLumRender(Sheet sheet) {
    final path = sheet.pdfPath;
    if (path == null) return;
    if (_lumInFlight.contains(sheet.id)) return;
    _lumInFlight.add(sheet.id);
    unawaited(_renderLum(sheet, path));
  }

  Future<void> _renderLum(Sheet sheet, String path) async {
    var ok = false;
    try {
      final map = await _buildLum(path, sheet.pageIndex, sheet.sizePx);
      if (map != null) {
        ok = true;
        _lumBySheet[sheet.id] = map;
        // Evict the least-recently-used beyond the cap.
        while (_lumBySheet.length > _kLumLruMax) {
          _lumBySheet.remove(_lumBySheet.keys.first);
        }
      }
    } catch (_) {
      // Ink is best-effort — a render failure just leaves the sheet ink-less.
    } finally {
      _lumInFlight.remove(sheet.id);
      // Memoize a failure (threw or produced no image) so the sheet is attempted
      // once, not re-rendered on every subsequent draw-hover frame.
      if (!ok) _lumFailed.add(sheet.id);
    }
  }

  /// Test seam: inject a ready luminance map for [sheetId] (skips pdfrx/disk) so
  /// a test can exercise the ink source + its precedence deterministically.
  /// [scale] is luminance-px per sheet-px.
  @visibleForTesting
  void primeInkForTest(
          String sheetId, Uint8List lum, int w, int h, double scale) =>
      _lumBySheet[sheetId] = _LumMap(lum, w, h, scale);

  /// The underlay snap CALLBACK a store gesture consumes: it resolves the plan
  /// underlay for [sheet] at the standard 14 screen-px radius (÷ [scale] for the
  /// live zoom), gated by the 'Snap to plan' toggle + the current reference-line
  /// set, with an optional [orthoAnchor] (the run's fixed endpoint) so a snap
  /// never bends a straight run off-axis. Returns null (no callback effect) when
  /// snapping is off. Pass the result into `placeRunPoint` / `drawRunFromNode` /
  /// `endNodeDragWithSnap`'s `underlaySnap:` param.
  Offset? Function(Offset world) callback(
    Sheet sheet,
    List<ReferenceLine> lines,
    double scale, {
    Offset? orthoAnchor,
    Offset? anchor,
    bool enabled = true,
  }) {
    final radiusWorld = 14.0 / (scale <= 0 ? 1.0 : scale);
    return (world) => snap(sheet, lines, world, radiusWorld,
            enabled: enabled, orthoAnchor: orthoAnchor, anchor: anchor)
        ?.point;
  }

  Future<_LumMap?> _buildLum(String path, int pageIndex, Size sizePx) async {
    final w0 = sizePx.width, h0 = sizePx.height;
    if (w0 <= 0 || h0 <= 0) return null;
    final longEdge = w0 >= h0 ? w0 : h0;
    final scale = longEdge > _kLumMaxEdge ? _kLumMaxEdge / longEdge : 1.0;
    final rw = (w0 * scale).round().clamp(1, _kLumMaxEdge);
    final rh = (h0 * scale).round().clamp(1, _kLumMaxEdge);

    final doc = await PdfDocument.openFile(path);
    try {
      final pages = doc.pages;
      if (pageIndex < 0 || pageIndex >= pages.length) return null;
      final img = await pages[pageIndex].render(width: rw, height: rh);
      if (img == null) return null;
      try {
        final lum = luminanceFromRgba(img.pixels, img.width, img.height);
        if (lum.isEmpty) return null;
        return _LumMap(lum, img.width, img.height, rw / w0);
      } finally {
        img.dispose();
      }
    } finally {
      await doc.dispose();
    }
  }
}
