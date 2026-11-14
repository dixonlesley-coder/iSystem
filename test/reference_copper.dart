// Backlog B-1 / B-2 (2026-11-13) — the copper a reference building's
// AUTO-sized cables carry, Σ mm² × m × loaded cores (phase + neutral, × runs;
// a star-delta way's two 3-core lead cables), so the cost effect of the
// electrical backlog stream is on record (docs/REFERENCE-BUILDINGS.md).
// A user-fixed cable (`cableOverrideMm2`) is excluded.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx/store/electrical_store.dart';

double autoSizedCopperMm2M(ProviderContainer c) {
  final sys = c.read(electricalResultProvider);
  final project = c.read(electricalSizingProjectProvider);
  final fixed = {
    for (final p in project.panels)
      for (final w in p.circuits)
        if (w.cableOverrideMm2 != null) w.id,
  };
  var cu = 0.0;
  for (final pr in sys.panels.values) {
    for (final w in pr.circuits) {
      if (fixed.contains(w.circuitId)) continue;
      cu += w.cable.csaMm2 *
          w.lengthM *
          (w.grounding.cores - 1) *
          (w.cable.runsPerPhase ?? 1);
      final ml = w.motorLeads;
      if (ml != null) {
        cu += 2 * 3 * ml.csaMm2 * w.lengthM * (ml.runsPerPhase ?? 1);
      }
    }
  }
  return cu;
}
