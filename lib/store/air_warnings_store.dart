/// Air-velocity warnings for a MANUALLY routed/sized air network.
///
/// The user draws ducts and places diffusers / AHU / FCU / fans by hand and may
/// pick a specific duct size (`NetEdge.sizeOverride`) and diffuser face size
/// (`NetNode.faceWidthMm/faceHeightMm`) for aesthetic / coordination reasons.
/// This provider judges the resulting air velocity of each element against the
/// recommended band (`sizing/air_velocity.dart`) and flags too-high / too-low,
/// so the engineer is warned without the app overriding their chosen size.
///
/// Only MANUALLY sized elements are judged: a duct edge with a chosen
/// `sizeOverride` (checked against the supply-duct band, or the shared
/// return/exhaust extract-duct band for `ServiceType.returnAir`/`exhaust`),
/// and an air terminal with a chosen face. An AUTO-sized duct is excluded
/// entirely — the sizing engine already picked the closest standard size to
/// the target velocity, so re-judging its own unavoidable pick (e.g. rounding
/// up to the smallest standard duct on a small flow) would warn about
/// something the engineer cannot act on.
///
/// It reads the live sizing (already velocity-aware per edge) + the drawn
/// network; it never mutates anything.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/sizing/grille_sizing.dart'
    show standardGrilleFacesMm;
import 'package:mechx_engine/units.dart';

import 'network_store.dart';
import 'sizing_store.dart';

/// Per-element air-velocity checks keyed by element id (edge id OR node id).
/// Only air elements that carry enough information to judge are included:
///   • air duct edges (mean velocity from the live sizing), and
///   • air terminals that have BOTH an airflow and a chosen face size.
final airVelocityChecksProvider = Provider<Map<String, VelocityCheck>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final out = <String, VelocityCheck>{};

  // Duct edges — mean velocity vs the supply-duct band, or the shared
  // return/exhaust extract-duct band for a return-air/exhaust duct. Only
  // MANUALLY sized ducts are judged (a chosen `sizeOverride`); an auto-sized
  // duct is the sizing engine's own pick and is never re-judged here (see the
  // header note).
  for (final e in net.edges) {
    if (!e.service.isAir || e.sizeOverride == null) continue;
    final s = sizing[e.id];
    if (s == null) continue;
    final isExtract =
        e.service == ServiceType.returnAir || e.service == ServiceType.exhaust;
    out[e.id] = isExtract
        ? checkExtractDuctVelocity(s.velocity)
        : checkSupplyDuctVelocity(s.velocity);
  }

  // Air terminals — face velocity vs the supply/return band. Only judged once
  // the terminal carries an airflow AND has a manually chosen face size.
  //
  // M7 — a terminal sitting on the SMALLEST standard catalogue face
  // ([kSmallestGrilleFaceMm], 150×150) cannot be made smaller, so a TOO-LOW
  // verdict there is unactionable: it is the terminal analogue of the auto-duct
  // exclusion above (a 0.05 m³/s diffuser the engine stamped 150×150 reads
  // 0.69 m/s and warned "too low", with no smaller face in existence). Such a
  // terminal is judged against an OPEN lower bound (min 0) instead — a TOO-HIGH
  // verdict at the smallest face IS actionable (choose a bigger face, or split
  // the airflow across more terminals) and is deliberately still reported.
  for (final n in net.nodes) {
    final q = n.airflow;
    final w = n.faceWidthMm, h = n.faceHeightMm;
    if (q == null || w == null || h == null) continue;
    final gross = Area((w / 1000.0) * (h / 1000.0));
    final v = faceVelocityFor(q, grossFaceArea: gross);
    final isReturn = n.component == NodeComponent.returnGrille ||
        n.component == NodeComponent.exhaustGrille;
    final smallestFace =
        w == kSmallestGrilleFaceMm.$1 && h == kSmallestGrilleFaceMm.$2;
    if (smallestFace) {
      out[n.id] = checkVelocityBand(
        v,
        min: const Velocity(0),
        max: isReturn ? kReturnFaceVelocityMax : kSupplyFaceVelocityMax,
      );
    } else {
      out[n.id] =
          isReturn ? checkReturnFaceVelocity(v) : checkSupplyFaceVelocity(v);
    }
  }
  return out;
});

/// The SMALLEST standard grille face in the engine catalogue (width, height in
/// mm) — the face below which no selection exists, so a too-low face velocity
/// there has no available remedy (M7). Derived from the catalogue itself
/// ([standardGrilleFacesMm]) by gross area, never hardcoded, so adding a smaller
/// catalogue entry moves this automatically.
final (double, double) kSmallestGrilleFaceMm = standardGrilleFacesMm.reduce(
  (a, b) => (a.$1 * a.$2) <= (b.$1 * b.$2) ? a : b,
);

/// Count of out-of-band air-velocity warnings (for a summary / status surface).
final airWarningCountProvider = Provider<int>((ref) => ref
    .watch(airVelocityChecksProvider)
    .values
    .where((c) => c.isWarning)
    .length);

/// Air elements (duct edges + air terminals) that carry air but have NO manually
/// chosen size yet — they are still relying on auto-sizing. A softer advisory
/// than an out-of-band velocity warning: it just nudges the engineer to pick a
/// size / face for the hand-routed network. An element that already carries a
/// chosen size (edge `sizeOverride`, node face) is NOT listed.
final airUnsizedProvider = Provider<Set<String>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final out = <String>{};

  // Air ducts that carry flow but have no manual size override.
  for (final e in net.edges) {
    if (!e.service.isAir || e.sizeOverride != null) continue;
    final s = sizing[e.id];
    if (s == null || s.flow.cubicMetersPerSecond <= 0) continue;
    out.add(e.id);
  }

  // Air terminals (a node carrying an airflow) with no chosen face size.
  for (final n in net.nodes) {
    final q = n.airflow;
    if (q == null || q.cubicMetersPerSecond <= 0) continue;
    if (n.faceWidthMm != null && n.faceHeightMm != null) continue;
    out.add(n.id);
  }
  return out;
});

/// Count of air elements not yet manually sized (for a summary / status surface).
final airUnsizedCountProvider =
    Provider<int>((ref) => ref.watch(airUnsizedProvider).length);

/// Air duct edges whose required size EXCEEDED the largest standard duct and
/// were CLAMPED to it (`EdgeSizing.overCapacity`). The auto-sizer no longer
/// throws on an oversize flow — it clamps and flags — so this surfaces the
/// clamped edges as a per-edge design issue (the chosen duct cannot meet the
/// velocity limit / friction target at that airflow). Empty when every air
/// duct is in range ⇒ no issue.
final airOverCapacityProvider = Provider<Set<String>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final out = <String>{};
  for (final e in net.edges) {
    if (!e.service.isAir) continue;
    final s = sizing[e.id];
    if (s != null && s.overCapacity) out.add(e.id);
  }
  return out;
});

/// EVERY edge whose printed size is a TABLE LIMIT rather than a valid selection
/// ([EdgeSizing.overCapacity]) — the discipline-neutral superset of
/// [airOverCapacityProvider]. Wave 1 widened the engine flag beyond air to:
///   • STORM (M3) — the catchment exceeds the largest tabulated downpipe;
///   • WATER SUPPLY (M4) — no DN in the series holds the mean velocity under
///     the `sniVerbatim` 2,0 m/s supply cap.
/// Both were computed and then DROPPED on the floor. This provider is the one
/// source the Review fan-in and the on-plan red warning-triangle badge read, so
/// a clamped downpipe or an over-velocity riser is as visible as a clamped duct.
/// Empty when every edge is in range ⇒ byte-identical.
final overCapacityEdgesProvider = Provider<Set<String>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final out = <String>{};
  for (final e in net.edges) {
    final s = sizing[e.id];
    if (s != null && s.overCapacity) out.add(e.id);
  }
  return out;
});

/// Gravity DRAINAGE edges the sizer judged BELOW the self-cleansing velocity
/// ([EdgeSizing.selfCleansingOk] false, i.e. full-bore Manning < 0.6 m/s at the
/// design slope) — solids drop out of suspension and the branch silts up. The
/// engine forms the verdict on the DFU path; nothing consumed it. Empty ⇒
/// byte-identical.
final selfCleansingDefectsProvider = Provider<Set<String>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final out = <String>{};
  for (final e in net.edges) {
    final s = sizing[e.id];
    if (s != null && !s.selfCleansingOk) out.add(e.id);
  }
  return out;
});

/// Edges belonging to a LOOPED (ring/grid) component whose Hardy–Cross balance
/// did NOT converge within its iteration budget ([EdgeSizing.loopUnbalanced]).
/// The carried flow still satisfies continuity, but the loop head-loss balance
/// was never achieved — so the split, and every size derived from it, is
/// PROVISIONAL. Empty for trees and settled loops ⇒ byte-identical.
final loopUnbalancedEdgesProvider = Provider<Set<String>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final sizing = ref.watch(sizingProvider);
  final out = <String>{};
  for (final e in net.edges) {
    final s = sizing[e.id];
    if (s != null && s.loopUnbalanced) out.add(e.id);
  }
  return out;
});
