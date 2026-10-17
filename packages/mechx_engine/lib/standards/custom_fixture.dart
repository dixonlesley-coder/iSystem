/// User-defined custom fixture types — the engine-side value object backing the
/// app's fixture library.
///
/// A [CustomFixture] is a pure data record an engineer can define when the
/// built-in [PlumbingFixture] set (SNI Tabel 3) does not cover a fixture they
/// need. It carries the loads DIRECTLY:
///   • [supplyUnits]   — the water-supply fixture-unit (UBAP) load, accumulated
///     up the tree and run through the SNI Hunter demand curve exactly like a
///     built-in fixture's [SniProfile.fixtureUnitLoad].
///   • [drainageUnits] — the Drainage Fixture Unit (DFU) load for the sanitary
///     drainage / vent sizing path (cf. `drainageFixtureUnit`).
///   • [isFlushValve]  — whether this fixture is a direct flush-valve WC; if any
///     selected fixture is, supply sizing uses the flush-VALVE demand branch.
///   • [isWaterCloset] — whether this fixture is a water closet; a drain
///     carrying one is floored at DN75 (`kMinWcDrainMm`, water-drainage-7),
///     like a built-in WC type.
///
/// DELIBERATE SIMPLIFICATION: unlike the built-in table, which tiers the UBAP
/// load by [Occupancy] (private / public / assembly), a custom fixture carries a
/// SINGLE supply-unit figure — the user enters the value appropriate to their
/// design. The occupancy multiplier is not applied to custom fixtures.
///
/// Zero Flutter imports (§12: the engine is framework-free). The engine core
/// never reads these directly — the app's integration layer resolves a node's
/// `customFixtureId` to its [CustomFixture] and feeds the loads into
/// `autoSizeNetwork`. SI throughout: [defaultMountingHeight] is a [Length] (m).
library;

import '../units.dart';

/// A user-defined fixture type with its supply (UBAP) + drainage (DFU) loads.
class CustomFixture {
  /// Stable id, referenced by `NetNode.customFixtureId`.
  final String id;

  /// Human-readable name shown in the inspector / library editor.
  final String name;

  /// Water-supply fixture-unit (UBAP) load. Accumulated + run through the SNI
  /// Hunter curve for supply sizing.
  final double supplyUnits;

  /// Drainage Fixture Unit (DFU) load for sanitary drainage / vent sizing.
  /// 0 ⇒ contributes no sanitary drain (e.g. a hose bibb).
  final double drainageUnits;

  /// Optional default mounting height for the fixture terminal (SI, metres).
  /// Null ⇒ use the role-derived fixture height.
  final Length? defaultMountingHeight;

  /// Whether this is a direct flush-valve WC (selects the flush-valve demand
  /// branch when present).
  final bool isFlushValve;

  /// Whether this is a WATER CLOSET (any flush type): the app passes such
  /// nodes to `autoSizeNetwork(waterClosetNodeIds:)` so every drainage edge
  /// carrying one is floored at the WC minimum (DN75), exactly as a built-in
  /// WC fixture is (audit water-drainage-7). Default false ⇒ byte-identical.
  final bool isWaterCloset;

  const CustomFixture({
    required this.id,
    required this.name,
    this.supplyUnits = 0,
    this.drainageUnits = 0,
    this.defaultMountingHeight,
    this.isFlushValve = false,
    this.isWaterCloset = false,
  });

  CustomFixture copyWith({
    String? id,
    String? name,
    double? supplyUnits,
    double? drainageUnits,
    Length? defaultMountingHeight,
    bool clearDefaultMountingHeight = false,
    bool? isFlushValve,
    bool? isWaterCloset,
  }) =>
      CustomFixture(
        id: id ?? this.id,
        name: name ?? this.name,
        supplyUnits: supplyUnits ?? this.supplyUnits,
        drainageUnits: drainageUnits ?? this.drainageUnits,
        defaultMountingHeight: clearDefaultMountingHeight
            ? null
            : (defaultMountingHeight ?? this.defaultMountingHeight),
        isFlushValve: isFlushValve ?? this.isFlushValve,
        isWaterCloset: isWaterCloset ?? this.isWaterCloset,
      );

  /// Plain-map JSON (SI: [defaultMountingHeight] stored in metres).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'supplyUnits': supplyUnits,
        'drainageUnits': drainageUnits,
        if (defaultMountingHeight != null)
          'mountingHeight_m': defaultMountingHeight!.meters,
        'isFlushValve': isFlushValve,
        // Additive: written only when set, so a legacy library is byte-identical.
        if (isWaterCloset) 'isWaterCloset': true,
      };

  /// Tolerant decode: returns null when the entry lacks the mandatory [id] /
  /// [name] (so a corrupt entry is dropped rather than throwing). Numeric loads
  /// default to 0; an absent mounting height ⇒ null.
  static CustomFixture? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final mh = raw['mountingHeight_m'];
    return CustomFixture(
      id: id,
      name: name,
      supplyUnits: (raw['supplyUnits'] as num?)?.toDouble() ?? 0,
      drainageUnits: (raw['drainageUnits'] as num?)?.toDouble() ?? 0,
      defaultMountingHeight: mh is num ? Length(mh.toDouble()) : null,
      isFlushValve: raw['isFlushValve'] == true,
      // Tolerant: absent / non-bool (an older file) ⇒ false.
      isWaterCloset: raw['isWaterCloset'] == true,
    );
  }
}
