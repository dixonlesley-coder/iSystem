/// Air-velocity warnings for a MANUALLY routed/sized air network.
///
/// The user draws ducts and places diffusers / AHU / FCU / fans by hand and may
/// pick a specific duct size (`NetEdge.sizeOverride`) and diffuser face size
/// (`NetNode.faceWidthMm/faceHeightMm`) for aesthetic / coordination reasons.
/// This provider judges the resulting air velocity of each element against the
/// recommended band (`sizing/air_velocity.dart`) and flags too-high / too-low,
/// so the engineer is warned without the app overriding their chosen size.
///
/// It reads the live sizing (already velocity-aware per edge) + the drawn
/// network; it never mutates anything.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/air_velocity.dart';
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

  // Duct edges — mean velocity vs the supply-duct band.
  for (final e in net.edges) {
    if (!e.service.isAir) continue;
    final s = sizing[e.id];
    if (s == null) continue;
    out[e.id] = checkSupplyDuctVelocity(s.velocity);
  }

  // Air terminals — face velocity vs the supply/return band. Only judged once
  // the terminal carries an airflow AND has a manually chosen face size.
  for (final n in net.nodes) {
    final q = n.airflow;
    final w = n.faceWidthMm, h = n.faceHeightMm;
    if (q == null || w == null || h == null) continue;
    final gross = Area((w / 1000.0) * (h / 1000.0));
    final v = faceVelocityFor(q, grossFaceArea: gross);
    final isReturn = n.component == NodeComponent.returnGrille ||
        n.component == NodeComponent.exhaustGrille;
    out[n.id] =
        isReturn ? checkReturnFaceVelocity(v) : checkSupplyFaceVelocity(v);
  }
  return out;
});

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
