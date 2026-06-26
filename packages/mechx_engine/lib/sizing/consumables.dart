/// Jointing-consumables estimate — how many cans of PVC solvent cement, tubes of
/// duct sealant, and rolls of thread-seal tape a job needs, for the bill of
/// materials / quotation. Counts come from the joints the network implies
/// (fittings + inline couplings) and the duct joint length.
///
/// PROVENANCE (§12.6): the per-joint cement volume, the sealant bead coverage
/// and the tape coverage are representative trade figures, NOT an SNI verbatim
/// clause — every value is `// VERIFY` and should be checked against the product
/// datasheet before a submission.
///
/// Pure Dart, zero Flutter imports.
library;

import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/bom.dart' show FittingType;

/// How a pipe service's joints are made — which drives the consumable (if any):
/// solvent-welded PVC needs cement; heat-fused PPR/HDPE needs none; threaded
/// steel needs thread-seal tape.
enum PipeJoinMethod { solventWeld, heatFusion, threaded, other }

/// The default jointing method for a pipe [service]: PVC solvent weld for the
/// gravity drainage / vent / storm services, PPR heat fusion for cold/hot water,
/// threaded steel for the fire services.
PipeJoinMethod joinMethodForService(ServiceType service) => switch (service) {
      ServiceType.drainage ||
      ServiceType.vent ||
      ServiceType.rainwater =>
        PipeJoinMethod.solventWeld,
      ServiceType.coldWater || ServiceType.hotWater => PipeJoinMethod.heatFusion,
      ServiceType.fireSprinkler ||
      ServiceType.fireHydrant =>
        PipeJoinMethod.threaded,
      _ => PipeJoinMethod.other,
    };

/// Glued/threaded sockets a fitting presents (each is one made joint).
int fittingSockets(FittingType type) => switch (type) {
      FittingType.elbow => 2,
      FittingType.tee => 3,
      FittingType.cross => 4,
      FittingType.reducer => 2,
    };

// ── Coverage figures (VERIFY — representative trade values) ─────────────────

/// PVC solvent cement used per solvent-weld joint (ml), scaling with the nominal
/// bore — a bigger socket takes more cement. ~3 ml at DN50, ~6 ml at DN100.
// VERIFY: representative; confirm against the cement datasheet's joints/can.
double pvcCementMlPerJoint(int dnMm) => math.max(2.0, 0.06 * dnMm);

/// One tin/can of PVC solvent cement (ml) — the 1 kg ≈ 1 L tin.
const double pvcCementCanMl = 1000.0; // VERIFY

/// Duct joint sealant a 300 ml cartridge lays as a bead (m).
const double ductSealantMetresPerCartridge = 11.0; // VERIFY

/// Threaded joints one roll of thread-seal (PTFE) tape makes.
const int threadJointsPerTapeRoll = 30; // VERIFY

/// The estimate result — quantities to buy plus the joint counts behind them.
class ConsumablesEstimate {
  final int solventJoints;
  final double pvcCementMl;
  final int pvcCementCans;

  final double ductSealMetres;
  final int ductSealantCartridges;

  final int threadedJoints;
  final int threadTapeRolls;

  const ConsumablesEstimate({
    required this.solventJoints,
    required this.pvcCementMl,
    required this.pvcCementCans,
    required this.ductSealMetres,
    required this.ductSealantCartridges,
    required this.threadedJoints,
    required this.threadTapeRolls,
  });

  bool get isEmpty =>
      pvcCementCans == 0 && ductSealantCartridges == 0 && threadTapeRolls == 0;
}

/// Estimate the jointing consumables from the made-joint counts:
/// [solventJointsByDn] (PVC solvent-weld joints keyed by nominal DN),
/// [ductSealMetres] (total duct joint/seam length to seal) and [threadedJoints]
/// (steel threaded joints). Each quantity rounds UP to whole units.
ConsumablesEstimate estimateConsumables({
  required Map<int, int> solventJointsByDn,
  required double ductSealMetres,
  required int threadedJoints,
}) {
  var ml = 0.0;
  var joints = 0;
  solventJointsByDn.forEach((dn, n) {
    if (n <= 0) return;
    ml += n * pvcCementMlPerJoint(dn);
    joints += n;
  });
  return ConsumablesEstimate(
    solventJoints: joints,
    pvcCementMl: ml,
    pvcCementCans: ml <= 0 ? 0 : (ml / pvcCementCanMl).ceil(),
    ductSealMetres: ductSealMetres,
    ductSealantCartridges:
        ductSealMetres <= 0 ? 0 : (ductSealMetres / ductSealantMetresPerCartridge).ceil(),
    threadedJoints: threadedJoints,
    threadTapeRolls:
        threadedJoints <= 0 ? 0 : (threadedJoints / threadJointsPerTapeRoll).ceil(),
  );
}
