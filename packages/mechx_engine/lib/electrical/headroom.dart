/// Spare-ways / future-load HEADROOM for a distribution panel.
///
/// Designers routinely oversize a board for future load and provide a number of
/// SPARE OUTGOING WAYS so that circuits can be added later without replacing the
/// board. This module models both as a small immutable [HeadroomSpec] on the
/// panel:
///   - [HeadroomSpec.sparePercentage] — a % spare applied to the panel's
///     diversified demand, so the incomer + busbar are rated for the future
///     load, not just today's connected load;
///   - [HeadroomSpec.spareWays] — N reserved outgoing ways, which count toward
///     the busbar way capacity (so the bus is split into the right number of
///     sections to physically host them).
///
/// Headroom is OPT-IN and additive. A null [HeadroomSpec] (or a 0 % / 0-way
/// spec) leaves the incomer, busbar and section count BYTE-IDENTICAL to a
/// project that never set headroom — the regression guard.
///
/// PROVENANCE: a spare allowance is general design practice, NOT a PUIL clause.
/// The % and the way count are project inputs (the engineer's call), so there is
/// no standards table to verify — the spec just carries the engineer's choice.
///
/// Zero Flutter imports.
library;

/// A panel's spare-ways / future-load headroom. Both fields default to "none",
/// so a default-constructed spec applies no headroom.
class HeadroomSpec {
  /// Future-load allowance as a percentage of the panel's diversified demand
  /// (e.g. 25 ⇒ size the incomer + busbar for 1.25× the demand). Clamped ≥ 0.
  final double sparePercentage;

  /// Reserved spare outgoing ways — empty ways the busbar is sized to host so
  /// later circuits don't force a board change. Clamped ≥ 0.
  final int spareWays;

  const HeadroomSpec({
    this.sparePercentage = 0,
    this.spareWays = 0,
  });

  /// A no-op headroom (the default) — applies no future-load uplift and reserves
  /// no spare ways. `computePanel` treats a null spec and [none] identically.
  static const HeadroomSpec none = HeadroomSpec();

  /// The future-load multiplier on demand: 1 + sparePercentage/100, floored at
  /// 1.0 (a negative percentage never shrinks the demand).
  double get demandMultiplier {
    final pct = sparePercentage > 0 ? sparePercentage : 0.0;
    return 1 + pct / 100.0;
  }

  /// Non-negative spare-way count.
  int get effectiveSpareWays => spareWays > 0 ? spareWays : 0;

  /// True when this spec actually does something (so the panel result can flag
  /// that headroom was applied).
  bool get isActive => demandMultiplier > 1.0 || effectiveSpareWays > 0;

  HeadroomSpec copyWith({double? sparePercentage, int? spareWays}) =>
      HeadroomSpec(
        sparePercentage: sparePercentage ?? this.sparePercentage,
        spareWays: spareWays ?? this.spareWays,
      );

  /// Serialize to a plain JSON map; the zero fields are still written so the
  /// round-trip is explicit (the panel only writes the key when the spec is set).
  Map<String, dynamic> toJson() => {
        'sparePercentage': sparePercentage,
        'spareWays': spareWays,
      };

  /// Tolerant decode — absent fields default to 0, never throws.
  static HeadroomSpec fromJson(Map<String, dynamic> json) => HeadroomSpec(
        sparePercentage: (json['sparePercentage'] as num?)?.toDouble() ?? 0,
        spareWays: (json['spareWays'] as num?)?.toInt() ?? 0,
      );
}
