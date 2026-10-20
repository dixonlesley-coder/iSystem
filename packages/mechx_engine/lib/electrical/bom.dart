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

import '../standards/puil.dart'
    show BreakerClass, BreakerClassCode, BreakerCurve;
import 'catalog.dart';
import 'earthing.dart' show RcdType, rcdTypeRank;
import 'enclosure.dart' show EnclosureResult;
import 'fault.dart' show FaultStudyResult;
import 'load_kind.dart' show LoadKind;
import 'model.dart' show ElectricalSystemInfo;
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
String _classStr(BreakerClass c) => c.code;

/// Map a [BreakerCurve] to the catalogue `curve` string.
String _curveStr(BreakerCurve c) => switch (c) {
      BreakerCurve.b => 'B',
      BreakerCurve.c => 'C',
      BreakerCurve.d => 'D',
    };

/// Pick the catalogue breaker SKU for a sized breaker.
///
/// Round 33 (engineer-walkthrough-bom-breaker-upsized-above-cable-iz) — the
/// RATING and the BREAKING CAPACITY are hard requirements, never ranking
/// penalties: only a part of EXACTLY the sized rating qualifies (a higher
/// rating is a protection change — the cable's In <= Iz was checked at the
/// sized rating, so an MCCB 40A bought for an MCB 32A on a 36 A cable leaves
/// the cable unprotected), and a part whose declared `breakingKa` is below
/// [minBreakingKa] (the kA the schedule specifies) never qualifies. Among
/// the qualifying parts the device class (MCB/MCCB), pole count and trip
/// curve rank (penalty 1000/100/10; an RCCB 2000); a part that doesn't
/// declare an attribute is treated as compatible. Returns null when nothing
/// qualifies — the line stays unmatched on its `elec:breaker:` price key.
String? matchBreakerSku(
  BreakerResult breaker,
  List<Part> parts, {
  required int poles,
  double? minBreakingKa,
}) =>
    _matchBreaker(breaker, parts, poles: poles, minBreakingKa: minBreakingKa)
        ?.sku;

/// [matchBreakerSku] returning the matched [Part] (null when none covers).
///
/// Round 39 r3 — [incomer]: a board's MAIN device is never bought as a
/// different breaker CLASS (an 'MCB 16A C 1P' for a scheduled 'MCCB 16A 4P')
/// nor with FEWER poles (nor as an RCCB): such parts are disqualified, not
/// merely ranked, so an incomer with no qualifying part stays unmatched on
/// its own `elec:breaker:<class>:<A>:<poles>P[:kA]` price key — the same
/// hard-requirement rule as the Round-33 exact rating.
Part? _matchBreaker(
  BreakerResult breaker,
  List<Part> parts, {
  required int poles,
  double? minBreakingKa,
  bool incomer = false,
}) {
  final wantClass = _classStr(breaker.deviceClass);
  final wantCurve = _curveStr(breaker.curve);
  final need = breaker.ratingA.amperes;

  final candidates = _exactRatingBreakers(parts, need)
      .where((p) => !incomer || _incomerCompatible(p, wantClass, poles))
      .where((p) => !_kaShort(p, minBreakingKa))
      .toList();
  if (candidates.isEmpty) return null;

  int penalty(Part p) {
    var s = 0;
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

/// Round 19 (electrical-parity-2-bom-breaker-silent-substitution) — how the
/// matched catalogue [p] departs from the SIZED [breaker] at [poles]: a
/// ` (catalogue part: MCB 10A D 1P)` note naming the part actually priced,
/// or null when it matches on every declared attribute (class, rating,
/// curve, poles). A part that does not declare an attribute is not judged on
/// it.
String? _substitutionNote(Part? p, BreakerResult breaker, int poles) {
  if (p == null) return null;
  final wantClass = _classStr(breaker.deviceClass);
  final wantCurve = _curveStr(breaker.curve);
  final need = breaker.ratingA.amperes;
  final classDiff = p.deviceClass != null && p.deviceClass != wantClass;
  final ratingDiff = p.ratingA != null && (p.ratingA! - need).abs() > 1e-9;
  final curveDiff = p.curve != null && p.curve != wantCurve;
  final polesDiff = p.poles != null && p.poles != poles;
  if (!classDiff && !ratingDiff && !curveDiff && !polesDiff) return null;
  final attrs = <String>[
    p.deviceClass ?? wantClass,
    if (p.ratingA != null) '${_fmt(p.ratingA!)}A',
    if (p.curve != null) p.curve!,
    if (p.poles != null) '${p.poles}P',
  ];
  return ' (catalogue part: ${attrs.join(' ')})';
}

/// The breaker POLE count the schedule prints for a way (E8b): a 3φ way is
/// 3-pole, a 1φ FEEDER leaving a 3φ board is 2-pole, any other 1φ way 1-pole.
int _wayBreakerPoles(ElectricalCircuitResult c,
    {required bool boardThreePhase}) {
  if (c.phase.isThreePhase) return 3;
  if (c.loadKind == LoadKind.feeder && boardThreePhase) return 2;
  return 1;
}

/// Round 39 r3 — true when [p] may serve as a board INCOMER of [wantClass]
/// with [poles] poles: never an RCCB, never another declared class, never
/// fewer declared poles. An undeclared attribute is not judged.
bool _incomerCompatible(Part p, String wantClass, int poles) =>
    p.deviceClass != 'RCCB' &&
    (p.deviceClass == null || p.deviceClass == wantClass) &&
    (p.poles == null || p.poles! >= poles);

/// Round 33 — the catalogue breakers of EXACTLY [needA] (the sized rating).
List<Part> _exactRatingBreakers(List<Part> parts, double needA) => [
      for (final p in parts)
        if (p.category == PartCategory.breaker &&
            p.ratingA != null &&
            (p.ratingA! - needA).abs() <= 1e-9)
          p,
    ];

/// Round 41 — a multi-core way's REDUCED make-up for its price key: the count
/// of full-section conductors and a `+<csa>` (or `+<n>x<csa>`) suffix per
/// reduced section, resolved exactly as the schedule's `cableLabel` does
/// (live + neutral when present + PE inside the cable). Null when every
/// conductor is at the phase section (the legacy `:nC` key stands).
({int full, String suffix})? _reducedMakeup(
    ElectricalCircuitResult c, int cores) {
  final csa = c.cable.csaMm2;
  final live = c.threePhase ? 3 : 1;
  final peCsa = c.grounding.peCsaMm2;
  final hasPe = peCsa > 0;
  final hasN = cores - live - (hasPe ? 1 : 0) >= 1;
  final nCsa = c.grounding.neutralCsaMm2 > 0 ? c.grounding.neutralCsaMm2 : csa;
  final conductors = <double>[
    for (var i = 0; i < live; i++) csa,
    if (hasN) nCsa,
    if (hasPe) peCsa,
  ];
  if (conductors.length != cores) return null;
  final full = conductors.where((x) => (x - csa).abs() <= 1e-9).length;
  if (full == conductors.length) return null;
  final reduced = <double, int>{};
  for (final x in conductors) {
    if ((x - csa).abs() <= 1e-9) continue;
    reduced[x] = (reduced[x] ?? 0) + 1;
  }
  final sizes = reduced.keys.toList()..sort((a, b) => b.compareTo(a));
  final suffix = sizes
      .map((s) => '+${reduced[s]! > 1 ? '${reduced[s]}x' : ''}${_fmt(s)}')
      .join();
  return (full: full, suffix: suffix);
}

/// True when [p] cannot be SHOWN to reach [minBreakingKa]: its declared
/// breaking capacity is below it — or (Round 41, elec-report-bom-2-
/// undeclared-ka-part-bought-at-specified-ka) it declares NO breaking
/// capacity at all while one is specified. A part whose Icu the catalogue
/// omits (LS TS400N: listings disagree 50 vs 65 kA, both below a specified
/// 70 kA) used to pass ANY specified kA and was bought silently as adequate;
/// like an untyped RCD part for a typed spec (Round 19) it now never
/// qualifies, so the line stays unmatched on its `elec:breaker:` key and is
/// flagged short. No specified kA ⇒ unchanged.
bool _kaShort(Part? p, double? minBreakingKa) {
  final need = minBreakingKa ?? 0;
  if (need <= 0) return false;
  final ka = p?.breakingKa;
  return ka == null || ka + 1e-9 < need;
}

/// Pick the catalogue RCCB / RCBO part for a way's residual-current device:
/// residual rating == [residualMa], poles ≥ the way's ([poles] 1φ → 2P, 3φ →
/// 4P), current rating ≥ the way's breaker. Null when the catalogue carries
/// none.
///
/// Round 19 (electrical-parity-2-bom-rcd-type-ignored) — the WAVEFORM type is
/// part of the specification: when [type] is given only a part AT LEAST as
/// capable qualifies (B > F > A > AC, [rcdTypeRank]); a part that does not
/// declare its type cannot be shown to qualify and is skipped. A Type AC
/// device does not detect the pulsating-DC fault current Type A was specified
/// for, so ordering one where the schedule prints `RCD 30mA A` was a silent
/// protection-class substitution. [timeDelayed] (the TT feeder's S-type)
/// likewise admits only a time-delayed part. Ranking: the EXACT pole count
/// first (a 4P part for a 2P need is a last resort), then the smallest rating,
/// then the least capable adequate type. Nothing qualifying ⇒ null (the line
/// stays unmatched with its deterministic `elec:rcd` price key).
String? matchRcdSku(
  int residualMa,
  double breakerA,
  List<Part> parts, {
  required bool threePhase,
  RcdType? type,
  bool timeDelayed = false,
}) {
  final wantPoles = threePhase ? 4 : 2;
  int? rankOf(Part p) {
    final t = p.rcdType;
    if (t == null) return null;
    final base = t.split(RegExp(r'[\s\-]')).first;
    return switch (base) {
      'AC' => rcdTypeRank(RcdType.ac),
      'A' => rcdTypeRank(RcdType.a),
      'F' => rcdTypeRank(RcdType.f),
      'B' => rcdTypeRank(RcdType.b),
      _ => null,
    };
  }

  bool typeOk(Part p) {
    if (type == null) return true;
    final r = rankOf(p);
    return r != null && r >= rcdTypeRank(type);
  }

  int exact(Part p) => (p.poles ?? wantPoles) == wantPoles ? 0 : 1;
  final c = parts
      .where((p) =>
          (p.deviceClass == 'RCCB' || p.deviceClass == 'RCBO') &&
          p.residualMa != null &&
          (p.residualMa! - residualMa).abs() < 1e-9 &&
          p.ratingA != null &&
          p.ratingA! >= breakerA &&
          (p.poles ?? wantPoles) >= wantPoles &&
          typeOk(p) &&
          (!timeDelayed || p.rcdTimeDelayed))
      .toList()
    ..sort((a, b) {
      final e = exact(a).compareTo(exact(b));
      if (e != 0) return e;
      final r = a.ratingA!.compareTo(b.ratingA!);
      if (r != 0) return r;
      final t = (rankOf(a) ?? 9).compareTo(rankOf(b) ?? 9);
      if (t != 0) return t;
      return (a.poles ?? 9).compareTo(b.poles ?? 9);
    });
  return c.isEmpty ? null : c.first.sku;
}

/// Pick a catalogue cable SKU whose section is ≥ the sized section, of the
/// circuit's construction (`cableType`, e.g. NYM vs NYY vs FRC). With no
/// [cableType] any family matches (section only). Returns null when no part
/// covers it.
///
/// Round 21 (bom-quote-1) — a given family NEVER falls back to another
/// family's part: the catalogue carries FRC only to 95 mm² and NYM only to
/// 10 mm², so the old section-only fallback bought and priced a fire-rated
/// FRC 3x300 life-safety run (or an NYM 3x16) as plain NYY with no flag. Such
/// a line now stays unmatched and is priced on a deterministic family key
/// (`elec:cable:<family>:<cores>x<csa>`, see the BOM builder).
String? matchCableSku(double csaMm2, List<Part> parts, {String? cableType}) {
  final pool = parts
      .where((p) =>
          p.category == PartCategory.cable &&
          p.csaMm2 != null &&
          p.csaMm2! >= csaMm2 &&
          (cableType == null || p.cableType == cableType))
      .toList();
  if (pool.isEmpty) return null;
  pool.sort((a, b) => a.csaMm2!.compareTo(b.csaMm2!));
  return pool.first.sku;
}

/// True for a SINGLE-CORE cable family (NYA / NYAF — one conductor per
/// cable, so a way needs one pull per conductor). Case-insensitive.
bool isSingleCoreCableFamily(String? cableType) {
  final t = cableType?.trim().toUpperCase();
  return t == 'NYA' || t == 'NYAF';
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

  /// True when the matched catalogue breaker differs from the SIZED device in
  /// class, rating, curve or poles (Round 19) — the description then names
  /// the part actually priced, and consolidation keys it apart, so a
  /// substitution is never silent.
  final bool deviceSubstituted;

  /// Round 41 — a READ-TIME fallback pricelist key: the key this line was
  /// priced by before a key refinement (a reduced-make-up cable's legacy
  /// `SKU:nC`, a control device's role-less `elec:control:<category>…`), so a
  /// pricelist saved before still prices it until re-priced. Null ⇒ none.
  final String? legacyPriceKey;

  /// Round 41 (elec-report-bom-2-way-name-dash-corrupts-bom-lines) — the way /
  /// board this un-consolidated line belongs to, when [description] ends with
  /// ` — <location>`. Kept EXPLICITLY so consolidation strips exactly that
  /// suffix: a way NAME containing ' — ' (the app's own 'Lighting — zone 1'
  /// templates) used to be cut inside the name by a `lastIndexOf(' — ')`, so
  /// identical devices split across lines and notes landed mid-name. Null on
  /// a consolidated (location-agnostic) line.
  final String? location;

  const BomLine({
    required this.description,
    required this.qty,
    required this.category,
    this.sku,
    this.runs = 1,
    String? priceKey,
    this.breakingCapacityShort = false,
    this.deviceSubstituted = false,
    this.legacyPriceKey,
    this.location,
  }) : priceKey = priceKey ?? sku;

  /// The description WITHOUT its ` — <location>` suffix (the whole
  /// description when the line carries no [location]).
  String get baseDescription => splitBomLocation(description, location).base;

  BomLine copyWith({double? qty, int? runs}) => BomLine(
        description: description,
        qty: qty ?? this.qty,
        category: category,
        sku: sku,
        runs: runs ?? this.runs,
        priceKey: priceKey,
        breakingCapacityShort: breakingCapacityShort,
        deviceSubstituted: deviceSubstituted,
        legacyPriceKey: legacyPriceKey,
        location: location,
      );
}

/// Round 41 — split a BOM [description] into its base text and the
/// ` — <location>` suffix. With a known [location] only that exact suffix is
/// split off (a ' — ' inside a way name stays part of the base); without one
/// the legacy last-separator split applies (lines built without a location).
({String base, String suffix}) splitBomLocation(
    String description, String? location) {
  if (location != null) {
    final tail = ' — $location';
    return description.endsWith(tail)
        ? (
            base: description.substring(0, description.length - tail.length),
            suffix: tail,
          )
        : (base: description, suffix: '');
  }
  final i = description.lastIndexOf(' — ');
  return i < 0
      ? (base: description, suffix: '')
      : (base: description.substring(0, i), suffix: description.substring(i));
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
  double? incomerKa,
  Map<String, double> breakerKaByCircuitId = const {},
  EnclosureResult? enclosure,
}) {
  final lines = <BomLine>[];
  final pname = panel.name;
  final partBySku = {for (final p in parts) p.sku: p};

  // Round 15 (elec-props-3-bom-mccb-ka-below-schedule) — a device with a
  // SPECIFIED breaking capacity (the fault study's Icu rung, which already
  // satisfies Ics = fraction·Icu ≥ Isc for an MCCB) matches against THAT
  // figure — the one the schedule prints — never the raw bus fault (a 16 kA
  // MCCB has Ics 12 kA < a 16 kA fault, the study rules it out).
  BomLine breakerLine(String description, BreakerResult b, int poles,
      {double? specifiedKa, bool incomer = false, String? location}) {
    final needKa = specifiedKa ?? minBreakingKa;
    final kaTag = (needKa ?? 0) > 0 ? ' ${_fmt(_r1(needKa!))}kA' : '';
    final part = _matchBreaker(b, parts,
        poles: poles, minBreakingKa: needKa, incomer: incomer);
    // Round 33 — parts of the sized rating exist but none reaches the
    // specified kA: the line stays unmatched AND is flagged (never priced as
    // an adequate device, never merged with an adequate line). Round 39 r3 —
    // for an incomer only the class / pole-compatible parts count.
    final short = part == null &&
        (needKa ?? 0) > 0 &&
        _exactRatingBreakers(parts, b.ratingA.amperes)
            .where((p) =>
                !incomer ||
                _incomerCompatible(p, _classStr(b.deviceClass), poles))
            .any((p) => _kaShort(p, needKa));
    final subst = _substitutionNote(part, b, poles);
    // The notes go BEFORE the trailing " — <location>" suffix, so
    // consolidation (which strips that suffix) keeps them on the merged line.
    // Round 41 — split at the EXPLICIT location, never inside a way name.
    String withNote(String d, String note) {
      final s = splitBomLocation(d, location);
      return '${s.base}$note${s.suffix}';
    }

    var desc = description;
    if (subst != null) desc = withNote(desc, subst);
    if (short) desc = withNote(desc, ' (no catalogue part reaches$kaTag)');
    // Round 24 — an UNMATCHED device names its specified kA in the line
    // itself, so two non-catalogue breakers differing only in breaking
    // capacity stay two orderable lines (and the BOM reader sees the kA).
    if (part == null && kaTag.isNotEmpty) desc = withNote(desc, kaTag);
    return BomLine(
      description: desc,
      qty: 1,
      category: PartCategory.breaker,
      sku: part?.sku,
      // Round 23 follow-up — an UNMATCHED device (an ACB, an MCCB above the
      // catalogue's widest frame) still carries an `elec:` price key (audit
      // round 8: every non-catalogue electrical line is priceable), keyed on
      // what the schedule specifies: class · rating · poles · kA.
      priceKey: part == null
          ? '${kElecPriceKeyPrefix}breaker:${_classStr(b.deviceClass)}:'
              '${_fmt(b.ratingA.amperes)}A:${poles}P'
              '${(needKa ?? 0) > 0 ? ':${_fmt(_r1(needKa!))}kA' : ''}'
          : null,
      breakingCapacityShort: short,
      deviceSubstituted: subst != null,
      location: location,
    );
  }

  // Panel incomer (main breaker).
  final inc = panel.incomer;
  lines.add(breakerLine(
    '${_classStr(inc.breaker.deviceClass)} ${_fmt(inc.breaker.ratingA.amperes)}A '
    '${inc.poles}P incomer — $pname',
    location: pname,
    inc.breaker,
    inc.poles,
    specifiedKa: incomerKa,
    incomer: true,
  ));

  // Enclosure — one per panel (the panel box itself; un-matched without an
  // enclosure catalogue, but carrying a pricelist key so it CAN be priced).
  // Round 21 (bom-quote-4) — with the advanced study's SIZED enclosure the
  // line names its W x H x D and is priced per size, so a 2 m MDP cubicle and
  // a 12-way LP box never consolidate onto one line at one price.
  if (enclosure != null) {
    final dims = '${_fmt(enclosure.widthMm.roundToDouble())}x'
        '${_fmt(enclosure.heightMm.roundToDouble())}x'
        '${_fmt(enclosure.depthMm.roundToDouble())}';
    lines.add(BomLine(
      description: 'Enclosure $dims mm ${enclosure.ip} — $pname',
      location: pname,
      qty: 1,
      category: PartCategory.enclosure,
      priceKey: '${kElecPriceKeyPrefix}enclosure:$dims',
    ));
  } else {
    lines.add(BomLine(
      description: 'Enclosure / panel board — $pname',
      location: pname,
      qty: 1,
      category: PartCategory.enclosure,
      priceKey: '${kElecPriceKeyPrefix}enclosure',
    ));
  }

  // Busbar set + neutral/PE bars — one per panel.
  lines.add(_busbarLine(panel.busbar, pname, threePhase: inc.poles >= 3));
  lines.addAll(_neutralPeLines(panel.neutralPeBars, pname));

  final boardThreePhase = panel.system.isThreePhase;
  for (final c in panel.circuits) {
    // Round 19 — the schedule's pole rule (a 1φ feeder off a 3φ board is 2P).
    final poles = _wayBreakerPoles(c, boardThreePhase: boardThreePhase);

    // Branch breaker.
    lines.add(breakerLine(
      '${_classStr(c.breaker.deviceClass)} ${_fmt(c.breaker.ratingA.amperes)}A '
      // Round 23 r2 — only an MCB carries a B/C/D curve; an MCCB / ACB has
      // an adjustable trip unit, so its line names no curve letter.
      '${c.breaker.deviceClass.hasTripCurve ? 'curve ${_curveStr(c.breaker.curve)} ' : ''}'
      '— ${c.name}',
      location: c.name,
      c.breaker,
      poles,
      specifiedKa: breakerKaByCircuitId[c.circuitId],
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
      final family = c.grounding.cableType;
      if (isSingleCoreCableFamily(family) || cablePart?.cores == 1) {
        // SINGLE-CORE construction (NYA / NYAF): every conductor is its own
        // pull, so the metres are run × conductors (audit r8 — buying one run
        // length bought 1/3–1/4 of the copper). The PE (when it has its own
        // section) is listed as its own single-core line. The trigger is the
        // way's cable FAMILY, not only the matched part: the catalogue carries
        // single-core NYA only up to 95 mm², so a larger NYA run used to fall
        // through to a multi-core NYY SKU and be bought as ONE run length. A
        // matched part that is not single-core is never used for a single-core
        // run — the line goes unmatched with a deterministic `elec:` price key.
        String? singleCoreSku(String? sku) =>
            (sku != null && partBySku[sku]?.cores == 1) ? sku : null;
        String singleCoreKey(double csa) =>
            '${kElecPriceKeyPrefix}cable:$family:1x${_fmt(csa)}';
        final hasPe = c.grounding.peCsaMm2 > 0;
        final live = hasPe ? math.max(1, cores - 1) : cores;
        final liveSku = singleCoreSku(cableSku);
        lines.add(BomLine(
          description: 'Cable $spec ($live × 1C) — ${c.name}',
          location: c.name,
          qty: runLengthM * runs * live,
          category: PartCategory.cable,
          sku: liveSku,
          runs: runs,
          priceKey: liveSku ?? singleCoreKey(c.cable.csaMm2),
        ));
        if (hasPe) {
          final peSku = singleCoreSku(
              matchCableSku(c.grounding.peCsaMm2, parts, cableType: family));
          lines.add(BomLine(
            description: 'Cable $family 1×'
                '${_fmt(c.grounding.peCsaMm2)} mm² PE — ${c.name}',
                location: c.name,
            qty: runLengthM * runs,
            category: PartCategory.cable,
            sku: peSku,
            runs: runs,
            priceKey: peSku ?? singleCoreKey(c.grounding.peCsaMm2),
          ));
        }
      } else {
        // MULTI-CORE: the SKU names family + CSA only, so the price key carries
        // the core count — a 5×50 prices apart from a 3×50.
        //
        // Round 41 (elec-report-bom-2-reduced-makeup-cable-priced-as-full-
        // section) — and the MAKE-UP: a reduced neutral / PE is part of the
        // cable (`NYY 4x240+120` is 1080 mm² of copper, not a 5x240's 1200),
        // so the key names the full-section count and each reduced section
        // (`NYY-240:4C+120`, `elec:cable:NYM:3x185+95`). A full-section cable
        // keeps the legacy key (byte-identical); a reduced one falls back to
        // the legacy `:nC` key at read time so a saved pricelist still applies.
        final makeup = _reducedMakeup(c, cores);
        final legacyKey = cableSku == null
            ? '${kElecPriceKeyPrefix}cable:$family:'
                '${cores}x${_fmt(c.cable.csaMm2)}'
            : '$cableSku:${cores}C';
        final key = makeup == null
            ? legacyKey
            : cableSku == null
                ? '${kElecPriceKeyPrefix}cable:$family:'
                    '${makeup.full}x${_fmt(c.cable.csaMm2)}${makeup.suffix}'
                : '$cableSku:${makeup.full}C${makeup.suffix}';
        lines.add(BomLine(
          description: 'Cable $spec — ${c.name}',
          location: c.name,
          qty: runLengthM * runs,
          category: PartCategory.cable,
          sku: cableSku,
          runs: runs,
          // Round 21 — an unmatched run keeps its OWN family on a
          // deterministic key (never another family's SKU).
          priceKey: key,
          legacyPriceKey: makeup == null ? null : legacyKey,
        ));
      }

      // Round 41 (electrical-sim-6-star-delta-motor-has-one-cable-not-six-
      // leads) — a star-delta way's MOTOR LEADS: two 3-core (+PE) cables
      // from the starter to the motor's six terminals, each on Ib/√3, at the
      // way length (starter in the board, `// VERIFY`). Taken off apart
      // from the supply cable above.
      final leads = c.motorLeads;
      if (leads != null) {
        final leadRuns =
            2 * ((leads.runsPerPhase ?? 1) > 1 ? leads.runsPerPhase! : 1);
        final pe = c.motorLeadsPeCsaMm2 ?? leads.csaMm2;
        final reduced = pe > 0 && (pe - leads.csaMm2).abs() > 1e-9;
        final leadSpec = reduced
            ? '$family 3×${_fmt(leads.csaMm2)} + ${_fmt(pe)} mm²'
            : '$family 4×${_fmt(leads.csaMm2)} mm²';
        final leadSku =
            matchCableSku(leads.csaMm2, parts, cableType: family);
        final suffix = reduced ? '3C+${_fmt(pe)}' : '4C';
        lines.add(BomLine(
          description: 'Cable $leadSpec motor leads (star-delta, '
              '$leadRuns runs) — ${c.name}',
          qty: runLengthM * leadRuns,
          category: PartCategory.cable,
          sku: leadSku,
          runs: leadRuns,
          priceKey: leadSku == null
              ? '${kElecPriceKeyPrefix}cable:$family:'
                  '${reduced ? '3x${_fmt(leads.csaMm2)}+${_fmt(pe)}' : '4x${_fmt(leads.csaMm2)}'}'
              : '$leadSku:$suffix',
          location: c.name,
        ));
      }

      // ── Wiring accessories (estimate) ──────────────────────────────────────
      // Light points + switches for a lighting way; socket outlets for a socket
      // way; cable lugs (skun) at both ends of a larger cable.
      if (c.loadKind == LoadKind.lighting) {
        // At least the chained point count (c.points), at least the load-implied
        // estimate.
        final points = math.max(
            c.points, math.max(1, (c.connectedWOrLoad / _wattsPerLightPoint).ceil()));
        final switches = math.max(1, (points / _pointsPerSwitch).ceil());
        lines.add(BomLine(
          description: 'Light point — ${c.name}',
          location: c.name,
          qty: points.toDouble(),
          category: PartCategory.accessory,
          priceKey: '${kElecPriceKeyPrefix}accessory:light-point',
        ));
        lines.add(BomLine(
          description: 'Light switch (saklar) — ${c.name}',
          location: c.name,
          qty: switches.toDouble(),
          category: PartCategory.accessory,
          priceKey: '${kElecPriceKeyPrefix}accessory:light-switch',
        ));
      } else if (c.loadKind == LoadKind.socket) {
        final sockets =
            math.max(c.points, math.max(1, (c.connectedWOrLoad / _vaPerSocket).ceil()));
        lines.add(BomLine(
          description: 'Socket outlet (stop kontak) — ${c.name}',
          location: c.name,
          qty: sockets.toDouble(),
          category: PartCategory.accessory,
          priceKey: '${kElecPriceKeyPrefix}accessory:socket-outlet',
        ));
      }
      // Cable lugs (skun): one per conductor at EACH end of a larger cable.
      // Round 19 (electrical-parity-2-lug-count-ignores-cores) — the conductor
      // count is the cable's own make-up (`grounding.cores`: a motor / HVAC /
      // capacitor run is 3L+PE, 4 cores, not 5), and each conductor gets a
      // lug of ITS section: a reduced neutral / PE is its own lug line (one
      // below the lug threshold clamps straight into its terminal).
      if (c.cable.csaMm2 >= _skunMinCsaMm2) {
        final live = c.threePhase ? 3 : 1;
        final hasPe = c.grounding.peCsaMm2 > 0;
        final hasN = cores - live - (hasPe ? 1 : 0) >= 1;
        final sizes = <double>[
          for (var i = 0; i < live; i++) c.cable.csaMm2,
          if (hasN)
            c.grounding.neutralCsaMm2 > 0
                ? c.grounding.neutralCsaMm2
                : c.cable.csaMm2,
          if (hasPe) c.grounding.peCsaMm2,
        ];
        // Any conductor the make-up did not account for is phase-size.
        while (sizes.length < cores) {
          sizes.add(c.cable.csaMm2);
        }
        final bySize = <double, int>{};
        for (final sz in sizes) {
          if (sz < _skunMinCsaMm2) continue;
          bySize[sz] = (bySize[sz] ?? 0) + 1;
        }
        for (final e in bySize.entries) {
          lines.add(BomLine(
            description: 'Cable lug (skun) ${_fmt(e.key)} mm² — ${c.name}',
            location: c.name,
            // Both ends of EVERY parallel run.
            qty: (e.value * 2 * runs).toDouble(),
            category: PartCategory.accessory,
            priceKey: '${kElecPriceKeyPrefix}accessory:lug-${_fmt(e.key)}',
          ));
        }
      }
    }

    // RCD, when the circuit requires one.
    if (c.rcd.required) {
      final typeTag = c.rcd.type != null ? _rcdType(c.rcd.type!) : '-';
      final rcdPoles = poles >= 3 ? 4 : 2;
      final rcdSku = matchRcdSku(
          c.rcd.ratingMa, c.breaker.ratingA.amperes, parts,
          threePhase: poles >= 3,
          type: c.rcd.type,
          timeDelayed: c.rcd.timeDelayed);
      // Round 39 (elec-reports-parity-2) — an UNMATCHED RCD names (and keys
      // on) the rated current it must carry — the next standard RCCB frame
      // ≥ the way's breaker In — so devices of different ratings never
      // consolidate into one line; above the largest RCCB frame it is an
      // earth-leakage relay + shunt trip on the MCCB.
      final frameA = rcdSku == null ? rcdFrameRatingA(c.breaker.ratingA.amperes) : null;
      final frameText = rcdSku == null
          ? (frameA != null ? ' ${_fmt(frameA)}A' : ' (ELR + shunt-trip on ${_fmt(c.breaker.ratingA.amperes)}A MCCB)')
          : '';
      final frameKey = rcdSku == null
          ? ':${frameA != null ? '${_fmt(frameA)}A' : 'elr${_fmt(c.breaker.ratingA.amperes)}A'}'
          : '';
      lines.add(BomLine(
        description:
            'RCD ${c.rcd.ratingMa} mA${c.rcd.type != null ? ' Type ${_rcdType(c.rcd.type!)}' : ''}'
            '${c.rcd.timeDelayed ? ' S' : ''} '
            '${rcdPoles}P$frameText — ${c.name}',
            location: c.name,
        qty: 1,
        category: PartCategory.rcd,
        sku: rcdSku,
        // An unmatched RCD still carries a deterministic pricelist key.
        priceKey: rcdSku ??
            '${kElecPriceKeyPrefix}rcd:${c.rcd.ratingMa}:$typeTag'
                '${c.rcd.timeDelayed ? 'S' : ''}:$rcdPoles$frameKey',
      ));
    }
  }

  return lines;
}

/// Round 39 — standard RCCB frame ratings (A). // VERIFY — secondarySource
/// (IEC 61008-1 preferred rated currents; the catalogue's RCCB range tops out
/// at 125 A — above it residual-current protection is an earth-leakage relay
/// with a shunt trip on the MCCB).
const List<double> kRcdFrameRatingsA = [16, 25, 40, 63, 80, 100, 125];

/// The smallest standard RCCB frame (A) ≥ [breakerA], or null above the
/// largest frame (⇒ ELR + shunt trip). Pure.
double? rcdFrameRatingA(double breakerA) {
  for (final f in kRcdFrameRatingsA) {
    if (f + 1e-9 >= breakerA) return f;
  }
  return null;
}

BomLine _busbarLine(BusbarResult b, String pname, {required bool threePhase}) {
  final spec = b.widthMm > 0 && b.thicknessMm > 0
      ? '${_fmt(b.widthMm)}×${_fmt(b.thicknessMm)} mm (${_fmt(b.csaMm2)} mm²)'
      : '${_fmt(b.csaMm2)} mm²';
  final ph = threePhase ? '3φ' : '1φ';
  return BomLine(
    description: 'Busbar set ($ph) $spec — $pname',
    location: pname,
    qty: 1,
    category: PartCategory.busbar,
    priceKey: '${kElecPriceKeyPrefix}busbar:${threePhase ? 3 : 1}ph:'
        '${_fmt(b.csaMm2)}',
  );
}

List<BomLine> _neutralPeLines(NeutralPeBars np, String pname) => [
      BomLine(
        description: 'Neutral bar ${_fmt(np.neutralCsaMm2)} mm² — $pname',
        location: pname,
        qty: 1,
        category: PartCategory.busbar,
        priceKey: '${kElecPriceKeyPrefix}neutral-bar:${_fmt(np.neutralCsaMm2)}',
      ),
      BomLine(
        description: 'PE / earth bar ${_fmt(np.peCsaMm2)} mm² — $pname',
        location: pname,
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
///
/// Round 15 — [incomerKaByPanelId] / [breakerKaByCircuitId] are the
/// SPECIFIED per-device breaking capacities the schedule prints (the fault
/// study's `incomerKa` / `breakerKa`); when given they win over the bus
/// figure for that device, so the ordered part can never contradict the
/// issued schedule (see [faultSpecifiedKa]).
Bom buildBom(
  ElectricalSystemResult sys, {
  List<Part> parts = seedCatalog,
  Map<String, double> requiredIcuKaByPanelId = const {},
  Map<String, double> incomerKaByPanelId = const {},
  Map<String, double> breakerKaByCircuitId = const {},
  Map<String, EnclosureResult> enclosureByPanelId = const {},
  List<BomLine> extraLines = const [],
}) {
  final flat = <BomLine>[];
  for (final id in sys.order) {
    final panel = sys.panels[id];
    if (panel != null) {
      flat.addAll(_panelLines(panel, parts,
          minBreakingKa: requiredIcuKaByPanelId[id],
          incomerKa: incomerKaByPanelId[id],
          breakerKaByCircuitId: breakerKaByCircuitId,
          enclosure: enclosureByPanelId[id]));
    }
  }
  // Round 21 (bom-quote-5) — the advanced study's designed gear (starter
  // control devices, genset + ATS, SPDs, earth rods, main earthing
  // conductor; `advancedBomLines`) is consolidated with the panel lines.
  flat.addAll(extraLines);
  return Bom(_consolidate(flat));
}

/// Round 15 — the three breaking-capacity maps a BOM needs, read off one
/// fault study: the bus prospective fault per panel (fallback), the specified
/// incomer kA per panel and the specified way kA per circuit (only finite,
/// positive figures).
({
  Map<String, double> bus,
  Map<String, double> incomers,
  Map<String, double> breakers,
}) faultSpecifiedKa(FaultStudyResult fault) {
  bool ok(double v) => v.isFinite && v > 0;
  return (
    bus: {
      for (final e in fault.panels.entries)
        if (ok(e.value.prospectiveFaultkA)) e.key: e.value.prospectiveFaultkA,
    },
    incomers: {
      for (final e in fault.panels.entries)
        if (ok(e.value.incomerKa)) e.key: e.value.incomerKa,
    },
    breakers: {
      for (final e in fault.circuits.entries)
        if (ok(e.value.breakerKa)) e.key: e.value.breakerKa,
    },
  );
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
    final desc = _stripSuffix(line);
    // A cable SKU names family + CSA only (`NYY-2.5`), NOT the core count or
    // make-up, so 3-, 4- and 5-core runs of one section would merge under the
    // first line's description. Cable lines therefore key on the SKU AND the
    // full stripped spec (family · cores · make-up), staying separate orderable
    // lines; every other category keeps the plain SKU key.
    // A breaker SKU that is adequate on one board but SHORT of another board's
    // prospective fault keys apart (`::kA-short::<desc>`, the desc carrying
    // the kA it misses), so consolidation can never
    // fold the shortfall into an adequate line and drop the flag.
    // Round 24 — a sku-less line also keys on its PRICE KEY: the price key
    // carries what the description may not (an unmatched breaker's poles /
    // kA), so two devices that price differently never merge onto the first
    // line's key (an under-rated breaker could otherwise reach procurement).
    final key = line.sku == null
        ? '${line.category.name}::${line.priceKey ?? ''}::$desc'
        : line.category == PartCategory.cable
            ? '${line.sku}::$desc'
            : line.breakingCapacityShort
                ? '${line.sku}::kA-short::$desc'
                : line.deviceSubstituted
                    ? '${line.sku}::subst::$desc'
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
        deviceSubstituted: line.deviceSubstituted,
        legacyPriceKey: line.legacyPriceKey,
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
String _stripSuffix(BomLine line) =>
    splitBomLocation(line.description, line.location).base.trimRight();

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
