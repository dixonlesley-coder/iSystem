/// Bill-of-materials derivation (pure).
///
/// The sizing engine (`compute.dart`) sizes gear but emits no bill of materials,
/// so this module derives one from a computed [ElectricalSystemResult]: one line
/// per panel incomer, one per branch breaker, the cable runs (priced per metre
/// of run length), the per-circuit RCDs, each panel's busbar + neutral/PE bars,
/// an enclosure line per panel, and the **wiring accessories** (light points +
/// switches, socket outlets, cable lugs/skun). Quantities for identical items
/// are aggregated. Lines are matched to catalogue [Part] SKUs by a
/// class/poles/curve/rating heuristic (breakers) or a section/type heuristic
/// (cables); unmatched lines keep `sku == null`.
///
/// Ported (core slice) from PanelMaker `engine/bom.ts`, then extended: the cable
/// quantity is the run length in metres (cable is sold per metre) and the
/// accessory takeoff is added. The accessory counts are an ESTIMATE from the
/// circuit load (see the `// VERIFY` coverage constants).
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../standards/puil.dart' show BreakerClass, BreakerCurve;
import 'catalog.dart';
import 'earthing.dart' show RcdType;
import 'load_kind.dart' show LoadKind;
import 'panel_results.dart';
import 'results.dart' show BreakerResult, BusbarResult, NeutralPeBars;

// ── Accessory takeoff coverage (VERIFY — representative trade figures) ──────

/// Connected watts per lighting point (typical LED/TL fitting).
const double _wattsPerLightPoint = 36; // VERIFY

/// Lighting points controlled per switch (saklar) gang group.
const int _pointsPerSwitch = 3; // VERIFY

/// Connected VA per socket outlet (stop kontak) — SNI ~200 VA/point.
const double _vaPerSocket = 200; // VERIFY

/// Minimum conductor section (mm²) that terminates with a cable lug (skun);
/// smaller cables clamp directly into the terminal.
const double _skunMinCsaMm2 = 10; // VERIFY

// ── matchers ─────────────────────────────────────────────────────────────────

/// Map a [BreakerClass] to the catalogue `deviceClass` string.
String _classStr(BreakerClass c) =>
    c == BreakerClass.mcb ? 'MCB' : 'MCCB';

/// Map a [BreakerCurve] to the catalogue `curve` string.
String _curveStr(BreakerCurve c) => switch (c) {
      BreakerCurve.b => 'B',
      BreakerCurve.c => 'C',
      BreakerCurve.d => 'D',
    };

/// Pick the catalogue breaker SKU that best fits a sized breaker: the smallest
/// standard rating that COVERS the sized rating, preferring the right device
/// class (MCB/MCCB), pole count and trip curve. A coarse rating-only match would
/// grab a 1-pole part for a 3-pole breaker now the catalogue carries the
/// 1P–4P × B/C/D matrix, so a mismatch on class/poles/curve outweighs a smaller
/// rating (penalty 1000/100/10). A part that simply doesn't declare an attribute
/// is treated as compatible (no penalty). Returns null when nothing covers it.
String? matchBreakerSku(
  BreakerResult breaker,
  List<Part> parts, {
  required int poles,
}) {
  final wantClass = _classStr(breaker.deviceClass);
  final wantCurve = _curveStr(breaker.curve);
  final need = breaker.ratingA.amperes;

  final candidates = parts
      .where((p) =>
          p.category == PartCategory.breaker &&
          p.ratingA != null &&
          p.ratingA! >= need)
      .toList();
  if (candidates.isEmpty) return null;

  int penalty(Part p) {
    var s = 0;
    if (p.deviceClass != null && p.deviceClass != wantClass) s += 1000;
    if (p.poles != null && p.poles != poles) s += 100;
    if (p.curve != null && p.curve != wantCurve) s += 10;
    return s;
  }

  candidates.sort((a, b) {
    final byPenalty = penalty(a).compareTo(penalty(b));
    if (byPenalty != 0) return byPenalty;
    final byRating = a.ratingA!.compareTo(b.ratingA!);
    if (byRating != 0) return byRating;
    return (a.poles ?? 9).compareTo(b.poles ?? 9);
  });
  return candidates.first.sku;
}

/// Pick a catalogue cable SKU whose section is ≥ the sized section, preferring
/// parts of the circuit's construction (`type`, e.g. NYM vs NYY). When the
/// catalogue has no part of that type, fall back to section-only matching so a
/// brand stocking one construction still prices the run. Returns null when no
/// section covers it.
String? matchCableSku(double csaMm2, List<Part> parts, {String? cableType}) {
  final candidates = parts
      .where((p) =>
          p.category == PartCategory.cable &&
          p.csaMm2 != null &&
          p.csaMm2! >= csaMm2)
      .toList();
  if (candidates.isEmpty) return null;

  final sameType =
      cableType == null ? const <Part>[] : candidates.where((p) => p.cableType == cableType).toList();
  final pool = sameType.isNotEmpty ? sameType : candidates;
  pool.sort((a, b) => a.csaMm2!.compareTo(b.csaMm2!));
  return pool.first.sku;
}

// ── BOM line + bill ──────────────────────────────────────────────────────────

/// One aggregated bill-of-materials line.
class BomLine {
  final String description;
  final double qty;
  final PartCategory category;

  /// Matched catalogue order code, or null when no part fit.
  final String? sku;

  const BomLine({
    required this.description,
    required this.qty,
    required this.category,
    this.sku,
  });

  BomLine copyWith({double? qty}) => BomLine(
        description: description,
        qty: qty ?? this.qty,
        category: category,
        sku: sku,
      );
}

/// A whole project's bill of materials (consolidated lines).
class Bom {
  final List<BomLine> lines;

  const Bom(this.lines);

  /// Total piece/metre count across all lines (informational).
  double get totalQty => lines.fold(0.0, (s, l) => s + l.qty);
}

// ── derivation ───────────────────────────────────────────────────────────────

/// Build the flat (un-consolidated) list of BOM lines for one panel.
List<BomLine> _panelLines(ElectricalPanelResult panel, List<Part> parts) {
  final lines = <BomLine>[];
  final pname = panel.name;

  // Panel incomer (main breaker).
  final inc = panel.incomer;
  lines.add(BomLine(
    description:
        '${_classStr(inc.breaker.deviceClass)} ${_fmt(inc.breaker.ratingA.amperes)}A '
        '${inc.poles}P incomer — $pname',
    qty: 1,
    category: PartCategory.breaker,
    sku: matchBreakerSku(inc.breaker, parts, poles: inc.poles),
  ));

  // Enclosure — one per panel (the panel box itself; un-matched without an
  // enclosure catalogue).
  lines.add(BomLine(
    description: 'Enclosure / panel board — $pname',
    qty: 1,
    category: PartCategory.enclosure,
  ));

  // Busbar set + neutral/PE bars — one per panel.
  lines.add(_busbarLine(panel.busbar, pname));
  lines.addAll(_neutralPeLines(panel.neutralPeBars, pname));

  for (final c in panel.circuits) {
    final poles = c.phase.isThreePhase ? 3 : 1;

    // Branch breaker.
    lines.add(BomLine(
      description:
          '${_classStr(c.breaker.deviceClass)} ${_fmt(c.breaker.ratingA.amperes)}A '
          'curve ${_curveStr(c.breaker.curve)} — ${c.name}',
      qty: 1,
      category: PartCategory.breaker,
      sku: matchBreakerSku(c.breaker, parts, poles: poles),
    ));

    // Cable run — the conductor PULL LENGTH in metres (cable is sold per metre),
    // from the geo/manual run length; a length-less run lists 1 m as a
    // placeholder. A spare way has no load and no cable to pull.
    if (c.loadKind != LoadKind.spare) {
      final spec = c.grounding.cableSpec;
      lines.add(BomLine(
        description: 'Cable $spec — ${c.name}',
        qty: c.lengthM > 0 ? c.lengthM.ceilToDouble() : 1,
        category: PartCategory.cable,
        sku: matchCableSku(c.cable.csaMm2, parts, cableType: c.grounding.cableType),
      ));

      // ── Wiring accessories (estimate) ──────────────────────────────────────
      // Light points + switches for a lighting way; socket outlets for a socket
      // way; cable lugs (skun) at both ends of a larger cable.
      if (c.loadKind == LoadKind.lighting) {
        final points = math.max(1, (c.loadW / _wattsPerLightPoint).ceil());
        final switches = math.max(1, (points / _pointsPerSwitch).ceil());
        lines.add(BomLine(
          description: 'Light point — ${c.name}',
          qty: points.toDouble(),
          category: PartCategory.accessory,
        ));
        lines.add(BomLine(
          description: 'Light switch (saklar) — ${c.name}',
          qty: switches.toDouble(),
          category: PartCategory.accessory,
        ));
      } else if (c.loadKind == LoadKind.socket) {
        final sockets = math.max(1, (c.loadW / _vaPerSocket).ceil());
        lines.add(BomLine(
          description: 'Socket outlet (stop kontak) — ${c.name}',
          qty: sockets.toDouble(),
          category: PartCategory.accessory,
        ));
      }
      // Cable lugs (skun): one per conductor at EACH end of a larger cable.
      if (c.cable.csaMm2 >= _skunMinCsaMm2) {
        final conductors = c.threePhase ? 5 : 3; // 3L+N+PE or L+N+PE
        lines.add(BomLine(
          description: 'Cable lug (skun) ${_fmt(c.cable.csaMm2)} mm² — ${c.name}',
          qty: (conductors * 2).toDouble(),
          category: PartCategory.accessory,
        ));
      }
    }

    // RCD, when the circuit requires one.
    if (c.rcd.required) {
      lines.add(BomLine(
        description:
            'RCD ${c.rcd.ratingMa} mA${c.rcd.type != null ? ' Type ${_rcdType(c.rcd.type!)}' : ''} '
            '— ${c.name}',
        qty: 1,
        category: PartCategory.rcd,
      ));
    }
  }

  return lines;
}

BomLine _busbarLine(BusbarResult b, String pname) {
  final spec = b.widthMm > 0 && b.thicknessMm > 0
      ? '${_fmt(b.widthMm)}×${_fmt(b.thicknessMm)} mm (${_fmt(b.csaMm2)} mm²)'
      : '${_fmt(b.csaMm2)} mm²';
  return BomLine(
    description: 'Busbar set (3φ) $spec — $pname',
    qty: 1,
    category: PartCategory.busbar,
  );
}

List<BomLine> _neutralPeLines(NeutralPeBars np, String pname) => [
      BomLine(
        description: 'Neutral bar ${_fmt(np.neutralCsaMm2)} mm² — $pname',
        qty: 1,
        category: PartCategory.busbar,
      ),
      BomLine(
        description: 'PE / earth bar ${_fmt(np.peCsaMm2)} mm² — $pname',
        qty: 1,
        category: PartCategory.busbar,
      ),
    ];

/// Enumerate the whole system into a consolidated bill of materials. Lines for
/// identical items (same sku, or same description+category when un-matched) are
/// merged and their quantities summed, dropping the per-circuit/-panel suffix
/// (everything after the last " — ") so the same device across panels collapses
/// into one orderable line.
Bom buildBom(ElectricalSystemResult sys, {List<Part> parts = seedCatalog}) {
  final flat = <BomLine>[];
  for (final id in sys.order) {
    final panel = sys.panels[id];
    if (panel != null) flat.addAll(_panelLines(panel, parts));
  }
  return Bom(_consolidate(flat));
}

/// Build the (un-consolidated) bill for a single panel result — useful for a
/// per-panel view.
List<BomLine> buildPanelBom(ElectricalPanelResult panel,
        {List<Part> parts = seedCatalog}) =>
    _panelLines(panel, parts);

/// Merge identical lines, summing quantities and stripping the trailing
/// " — <circuit/panel>" suffix so the merged line is location-agnostic.
List<BomLine> _consolidate(List<BomLine> lines) {
  final byKey = <String, BomLine>{};
  final order = <String>[];
  for (final line in lines) {
    final desc = _stripSuffix(line.description);
    final key = line.sku ?? '${line.category.name}::$desc';
    final existing = byKey[key];
    if (existing == null) {
      byKey[key] = BomLine(
        description: desc,
        qty: line.qty,
        category: line.category,
        sku: line.sku,
      );
      order.add(key);
    } else {
      byKey[key] = existing.copyWith(qty: existing.qty + line.qty);
    }
  }
  return [for (final k in order) byKey[k]!];
}

/// Strip a trailing " — <suffix>" (the per-circuit / per-panel tag).
String _stripSuffix(String s) {
  final idx = s.lastIndexOf(' — ');
  return idx >= 0 ? s.substring(0, idx).trimRight() : s;
}

/// Format a number without a trailing `.0`.
String _fmt(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

String _rcdType(RcdType t) => switch (t) {
      RcdType.ac => 'AC',
      RcdType.a => 'A',
      RcdType.f => 'F',
      RcdType.b => 'B',
    };
