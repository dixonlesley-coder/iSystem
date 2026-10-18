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
///
/// [minBreakingKa] is the prospective fault at the device's board (kA): a part
/// whose declared `breakingKa` is BELOW it is heavily penalised (5000 — above a
/// class mismatch, so a 36 kA MCCB beats a 6 kA MCB at an 18 kA bus) so the
/// BOM never prices a device the schedule's kA token rules out (audit r8).
/// Null / 0 ⇒ the kA-blind ranking, byte-identical.
String? matchBreakerSku(
  BreakerResult breaker,
  List<Part> parts, {
  required int poles,
  double? minBreakingKa,
}) =>
    _matchBreaker(breaker, parts, poles: poles, minBreakingKa: minBreakingKa)
        ?.sku;

/// [matchBreakerSku] returning the matched [Part] (null when none covers).
Part? _matchBreaker(
  BreakerResult breaker,
  List<Part> parts, {
  required int poles,
  double? minBreakingKa,
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

  final needKa = minBreakingKa ?? 0;
  int penalty(Part p) {
    var s = 0;
    final ka = p.breakingKa;
    if (needKa > 0 && ka != null && ka + 1e-9 < needKa) s += 5000;
    // An RCCB (residual-current only) is never an overcurrent breaker.
    if (p.deviceClass == 'RCCB') s += 2000;
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
  return candidates.first;
}

/// True when [p] declares a breaking capacity below [minBreakingKa].
bool _kaShort(Part? p, double? minBreakingKa) {
  final need = minBreakingKa ?? 0;
  final ka = p?.breakingKa;
  return need > 0 && ka != null && ka + 1e-9 < need;
}

/// Pick the catalogue RCCB / RCBO part for a way's residual-current device:
/// residual rating == [residualMa], poles ≥ the way's ([poles] 1φ → 2P, 3φ →
/// 4P), current rating ≥ the way's breaker. Smallest adequate rating wins;
/// null when the catalogue carries none.
String? matchRcdSku(
  int residualMa,
  double breakerA,
  List<Part> parts, {
  required bool threePhase,
}) {
  final wantPoles = threePhase ? 4 : 2;
  final c = parts
      .where((p) =>
          (p.deviceClass == 'RCCB' || p.deviceClass == 'RCBO') &&
          p.residualMa != null &&
          (p.residualMa! - residualMa).abs() < 1e-9 &&
          p.ratingA != null &&
          p.ratingA! >= breakerA &&
          (p.poles ?? wantPoles) >= wantPoles)
      .toList()
    ..sort((a, b) {
      final r = a.ratingA!.compareTo(b.ratingA!);
      if (r != 0) return r;
      return (a.poles ?? 9).compareTo(b.poles ?? 9);
    });
  return c.isEmpty ? null : c.first.sku;
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

  /// Physical cable RUNS this line represents (a [PartCategory.cable] line's
  /// [qty] is metres, so the run count cannot be recovered from it). Summed on
  /// consolidation; per-run labour reads it. 1 for every non-cable line.
  final int runs;

  /// The PRICELIST key this line is priced by (audit r8). Equal to [sku] for an
  /// ordinary matched part; a multi-core cable carries its core count
  /// (`NYY-50:5C` — a 5×50 does not cost what a 3×50 does); an unmatched
  /// enclosure / busbar / RCD / accessory carries a deterministic `elec:` key
  /// so it CAN be priced. Null only when nothing can address it.
  final String? priceKey;

  /// True when the matched breaker's declared breaking capacity is below the
  /// board's prospective fault (no adequate catalogue part existed) — flagged,
  /// never silently priced as adequate.
  final bool breakingCapacityShort;

  const BomLine({
    required this.description,
    required this.qty,
    required this.category,
    this.sku,
    this.runs = 1,
    String? priceKey,
    this.breakingCapacityShort = false,
  }) : priceKey = priceKey ?? sku;

  BomLine copyWith({double? qty, int? runs}) => BomLine(
        description: description,
        qty: qty ?? this.qty,
        category: category,
        sku: sku,
        runs: runs ?? this.runs,
        priceKey: priceKey,
        breakingCapacityShort: breakingCapacityShort,
      );
}

/// Every electrical pricelist key minted for an UNMATCHED line starts with
/// this (catalogue order codes never do), so these prices share the persisted
/// `sku → price` map without collision.
const String kElecPriceKeyPrefix = 'elec:';

/// A whole project's bill of materials (consolidated lines).
class Bom {
  final List<BomLine> lines;

  const Bom(this.lines);

  /// Total piece/metre count across all lines (informational).
  double get totalQty => lines.fold(0.0, (s, l) => s + l.qty);
}

// ── derivation ───────────────────────────────────────────────────────────────

/// Build the flat (un-consolidated) list of BOM lines for one panel.
List<BomLine> _panelLines(
  ElectricalPanelResult panel,
  List<Part> parts, {
  double? minBreakingKa,
}) {
  final lines = <BomLine>[];
  final pname = panel.name;
  final partBySku = {for (final p in parts) p.sku: p};
  final kaTag = (minBreakingKa ?? 0) > 0 ? ' ${_fmt(_r1(minBreakingKa!))}kA' : '';

  BomLine breakerLine(String description, BreakerResult b, int poles) {
    final part = _matchBreaker(b, parts,
        poles: poles, minBreakingKa: minBreakingKa);
    final short = _kaShort(part, minBreakingKa);
    return BomLine(
      description: short
          ? '$description (no catalogue part reaches$kaTag)'
          : description,
      qty: 1,
      category: PartCategory.breaker,
      sku: part?.sku,
      breakingCapacityShort: short,
    );
  }

  // Panel incomer (main breaker).
  final inc = panel.incomer;
  lines.add(breakerLine(
    '${_classStr(inc.breaker.deviceClass)} ${_fmt(inc.breaker.ratingA.amperes)}A '
    '${inc.poles}P incomer — $pname',
    inc.breaker,
    inc.poles,
  ));

  // Enclosure — one per panel (the panel box itself; un-matched without an
  // enclosure catalogue, but carrying a pricelist key so it CAN be priced).
  lines.add(BomLine(
    description: 'Enclosure / panel board — $pname',
    qty: 1,
    category: PartCategory.enclosure,
    priceKey: '${kElecPriceKeyPrefix}enclosure',
  ));

  // Busbar set + neutral/PE bars — one per panel.
  lines.add(_busbarLine(panel.busbar, pname, threePhase: inc.poles >= 3));
  lines.addAll(_neutralPeLines(panel.neutralPeBars, pname));

  for (final c in panel.circuits) {
    final poles = c.phase.isThreePhase ? 3 : 1;

    // Branch breaker.
    lines.add(breakerLine(
      '${_classStr(c.breaker.deviceClass)} ${_fmt(c.breaker.ratingA.amperes)}A '
      'curve ${_curveStr(c.breaker.curve)} — ${c.name}',
      c.breaker,
      poles,
    ));

    // Cable run — the conductor PULL LENGTH in metres (cable is sold per metre),
    // from the geo/manual run length; a length-less run lists 1 m as a
    // placeholder. A spare way has no load and no cable to pull.
    if (c.loadKind != LoadKind.spare) {
      // A way sized as N parallel runs needs N cables of the run length: the
      // line is the TOTAL metres of the SINGLE cable (the matched SKU is the
      // single cable priced per metre), so the 'N× ' prefix of the spec is
      // dropped from the description to keep the metres unambiguous.
      final runs = (c.cable.runsPerPhase ?? 1) > 1 ? c.cable.runsPerPhase! : 1;
      final rawSpec = c.grounding.cableSpec;
      final runPrefix = '$runs× ';
      final spec = runs > 1 && rawSpec.startsWith(runPrefix)
          ? rawSpec.substring(runPrefix.length)
          : rawSpec;
      final runLengthM = c.lengthM > 0 ? c.lengthM.ceilToDouble() : 1.0;
      final cableSku =
          matchCableSku(c.cable.csaMm2, parts, cableType: c.grounding.cableType);
      final cablePart = cableSku == null ? null : partBySku[cableSku];
      final cores = c.grounding.cores;
      if (cablePart?.cores == 1) {
        // SINGLE-CORE construction (NYA / NYAF): every conductor is its own
        // pull, so the metres are run × conductors (audit r8 — buying one run
        // length bought 1/3–1/4 of the copper). The PE (when it has its own
        // section) is listed as its own single-core line.
        final hasPe = c.grounding.peCsaMm2 > 0;
        final live = hasPe ? math.max(1, cores - 1) : cores;
        lines.add(BomLine(
          description: 'Cable $spec ($live × 1C) — ${c.name}',
          qty: runLengthM * runs * live,
          category: PartCategory.cable,
          sku: cableSku,
          runs: runs,
        ));
        if (hasPe) {
          final peSku = matchCableSku(c.grounding.peCsaMm2, parts,
              cableType: c.grounding.cableType);
          lines.add(BomLine(
            description: 'Cable ${c.grounding.cableType} 1×'
                '${_fmt(c.grounding.peCsaMm2)} mm² PE — ${c.name}',
            qty: runLengthM * runs,
            category: PartCategory.cable,
            sku: peSku,
            runs: runs,
          ));
        }
      } else {
        // MULTI-CORE: the SKU names family + CSA only, so the price key carries
        // the core count — a 5×50 prices apart from a 3×50.
        lines.add(BomLine(
          description: 'Cable $spec — ${c.name}',
          qty: runLengthM * runs,
          category: PartCategory.cable,
          sku: cableSku,
          runs: runs,
          priceKey: cableSku == null ? null : '$cableSku:${cores}C',
        ));
      }

      // ── Wiring accessories (estimate) ──────────────────────────────────────
      // Light points + switches for a lighting way; socket outlets for a socket
      // way; cable lugs (skun) at both ends of a larger cable.
      if (c.loadKind == LoadKind.lighting) {
        // At least the chained point count (c.points), at least the load-implied
        // estimate.
        final points = math.max(
            c.points, math.max(1, (c.loadW / _wattsPerLightPoint).ceil()));
        final switches = math.max(1, (points / _pointsPerSwitch).ceil());
        lines.add(BomLine(
          description: 'Light point — ${c.name}',
          qty: points.toDouble(),
          category: PartCategory.accessory,
          priceKey: '${kElecPriceKeyPrefix}accessory:light-point',
        ));
        lines.add(BomLine(
          description: 'Light switch (saklar) — ${c.name}',
          qty: switches.toDouble(),
          category: PartCategory.accessory,
          priceKey: '${kElecPriceKeyPrefix}accessory:light-switch',
        ));
      } else if (c.loadKind == LoadKind.socket) {
        final sockets =
            math.max(c.points, math.max(1, (c.loadW / _vaPerSocket).ceil()));
        lines.add(BomLine(
          description: 'Socket outlet (stop kontak) — ${c.name}',
          qty: sockets.toDouble(),
          category: PartCategory.accessory,
          priceKey: '${kElecPriceKeyPrefix}accessory:socket-outlet',
        ));
      }
      // Cable lugs (skun): one per conductor at EACH end of a larger cable.
      if (c.cable.csaMm2 >= _skunMinCsaMm2) {
        final conductors = c.threePhase ? 5 : 3; // 3L+N+PE or L+N+PE
        lines.add(BomLine(
          description: 'Cable lug (skun) ${_fmt(c.cable.csaMm2)} mm² — ${c.name}',
          // Both ends of EVERY parallel run.
          qty: (conductors * 2 * runs).toDouble(),
          category: PartCategory.accessory,
          priceKey: '${kElecPriceKeyPrefix}accessory:lug-${_fmt(c.cable.csaMm2)}',
        ));
      }
    }

    // RCD, when the circuit requires one.
    if (c.rcd.required) {
      final typeTag = c.rcd.type != null ? _rcdType(c.rcd.type!) : '-';
      final rcdPoles = poles >= 3 ? 4 : 2;
      final rcdSku = matchRcdSku(
          c.rcd.ratingMa, c.breaker.ratingA.amperes, parts,
          threePhase: poles >= 3);
      lines.add(BomLine(
        description:
            'RCD ${c.rcd.ratingMa} mA${c.rcd.type != null ? ' Type ${_rcdType(c.rcd.type!)}' : ''} '
            '${rcdPoles}P — ${c.name}',
        qty: 1,
        category: PartCategory.rcd,
        sku: rcdSku,
        // An unmatched RCD still carries a deterministic pricelist key.
        priceKey: rcdSku ??
            '${kElecPriceKeyPrefix}rcd:${c.rcd.ratingMa}:$typeTag:$rcdPoles',
      ));
    }
  }

  return lines;
}

BomLine _busbarLine(BusbarResult b, String pname, {required bool threePhase}) {
  final spec = b.widthMm > 0 && b.thicknessMm > 0
      ? '${_fmt(b.widthMm)}×${_fmt(b.thicknessMm)} mm (${_fmt(b.csaMm2)} mm²)'
      : '${_fmt(b.csaMm2)} mm²';
  final ph = threePhase ? '3φ' : '1φ';
  return BomLine(
    description: 'Busbar set ($ph) $spec — $pname',
    qty: 1,
    category: PartCategory.busbar,
    priceKey: '${kElecPriceKeyPrefix}busbar:${threePhase ? 3 : 1}ph:'
        '${_fmt(b.csaMm2)}',
  );
}

List<BomLine> _neutralPeLines(NeutralPeBars np, String pname) => [
      BomLine(
        description: 'Neutral bar ${_fmt(np.neutralCsaMm2)} mm² — $pname',
        qty: 1,
        category: PartCategory.busbar,
        priceKey: '${kElecPriceKeyPrefix}neutral-bar:${_fmt(np.neutralCsaMm2)}',
      ),
      BomLine(
        description: 'PE / earth bar ${_fmt(np.peCsaMm2)} mm² — $pname',
        qty: 1,
        category: PartCategory.busbar,
        priceKey: '${kElecPriceKeyPrefix}pe-bar:${_fmt(np.peCsaMm2)}',
      ),
    ];

/// Enumerate the whole system into a consolidated bill of materials. Lines for
/// identical items (same sku, or same description+category when un-matched) are
/// merged and their quantities summed, dropping the per-circuit/-panel suffix
/// (everything after the last " — ") so the same device across panels collapses
/// into one orderable line.
///
/// [requiredIcuKaByPanelId] (panel id → the prospective fault at that bus, kA —
/// the fault study's `prospectiveFaultkA`) makes every breaker on that board
/// match a part whose breaking capacity covers it (see [matchBreakerSku]);
/// absent ⇒ the kA-blind match, byte-identical.
Bom buildBom(
  ElectricalSystemResult sys, {
  List<Part> parts = seedCatalog,
  Map<String, double> requiredIcuKaByPanelId = const {},
}) {
  final flat = <BomLine>[];
  for (final id in sys.order) {
    final panel = sys.panels[id];
    if (panel != null) {
      flat.addAll(_panelLines(panel, parts,
          minBreakingKa: requiredIcuKaByPanelId[id]));
    }
  }
  return Bom(_consolidate(flat));
}

/// Build the (un-consolidated) bill for a single panel result — useful for a
/// per-panel view.
List<BomLine> buildPanelBom(ElectricalPanelResult panel,
        {List<Part> parts = seedCatalog, double? minBreakingKa}) =>
    _panelLines(panel, parts, minBreakingKa: minBreakingKa);

/// Merge identical lines, summing quantities and stripping the trailing
/// " — <circuit/panel>" suffix so the merged line is location-agnostic.
List<BomLine> _consolidate(List<BomLine> lines) {
  final byKey = <String, BomLine>{};
  final order = <String>[];
  for (final line in lines) {
    final desc = _stripSuffix(line.description);
    // A cable SKU names family + CSA only (`NYY-2.5`), NOT the core count or
    // make-up, so 3-, 4- and 5-core runs of one section would merge under the
    // first line's description. Cable lines therefore key on the SKU AND the
    // full stripped spec (family · cores · make-up), staying separate orderable
    // lines; every other category keeps the plain SKU key.
    final key = line.sku == null
        ? '${line.category.name}::$desc'
        : line.category == PartCategory.cable
            ? '${line.sku}::$desc'
            : line.sku!;
    final existing = byKey[key];
    if (existing == null) {
      byKey[key] = BomLine(
        description: desc,
        qty: line.qty,
        category: line.category,
        sku: line.sku,
        runs: line.runs,
        priceKey: line.priceKey,
        breakingCapacityShort: line.breakingCapacityShort,
      );
      order.add(key);
    } else {
      byKey[key] = existing.copyWith(
          qty: existing.qty + line.qty, runs: existing.runs + line.runs);
    }
  }
  return [for (final k in order) byKey[k]!];
}

/// Strip a trailing " — <suffix>" (the per-circuit / per-panel tag).
String _stripSuffix(String s) {
  final idx = s.lastIndexOf(' — ');
  return idx >= 0 ? s.substring(0, idx).trimRight() : s;
}

double _r1(double v) => (v * 10).round() / 10;

/// Format a number without a trailing `.0`.
String _fmt(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

String _rcdType(RcdType t) => switch (t) {
      RcdType.ac => 'AC',
      RcdType.a => 'A',
      RcdType.f => 'F',
      RcdType.b => 'B',
    };
