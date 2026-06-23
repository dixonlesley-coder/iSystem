/// Motor starting analysis by starting method: starting current (× FLC) and
/// starting torque (% of full-load torque). Ported from PanelMaker
/// `engine/control/startingAnalysis.ts` + `standards/control/starting.ts`.
///
/// PURE Dart — zero Flutter imports.
library;

import '../../units.dart';
import 'contactor.dart' show StartingDuty;
import 'starter.dart' show StarterType;

/// Typical starting characteristics for a starting method.
class StartingProfile {
  /// Starting current as a multiple of full-load current.
  final double startMultiple;

  /// Starting torque as a percentage of full-load torque.
  final double startTorquePct;

  final String label;

  const StartingProfile({
    required this.startMultiple,
    required this.startTorquePct,
    required this.label,
  });
}

/// Per-method starting profiles.
///
/// // VERIFY (secondarySource): typical starting current/torque figures —
/// confirm against the motor and starter datasheets.
const Map<StarterType, StartingProfile> startingProfiles = {
  StarterType.dol: StartingProfile(
      startMultiple: 6.5, startTorquePct: 100, label: 'Direct-on-line'),
  StarterType.starDelta: StartingProfile(
      startMultiple: 2.2, startTorquePct: 33, label: 'Star-delta'),
  StarterType.reversing: StartingProfile(
      startMultiple: 6.5, startTorquePct: 100, label: 'Reversing (DOL)'),
  StarterType.softStarter: StartingProfile(
      startMultiple: 3, startTorquePct: 40, label: 'Soft starter'),
  StarterType.vfd: StartingProfile(
      startMultiple: 1.5, startTorquePct: 100, label: 'VFD / VSD'),
  StarterType.ats: StartingProfile(
      startMultiple: 1, startTorquePct: 0, label: 'ATS (no motor)'),
  StarterType.pump: StartingProfile(
      startMultiple: 6.5, startTorquePct: 100, label: 'Pump (DOL)'),
};

/// The result of a motor starting analysis for the chosen method.
class StartingAnalysisResult {
  /// Human-readable method name.
  final String method;

  /// Starting current (A).
  final Current startCurrentA;

  /// Starting current as a multiple of FLC.
  final double startCurrentMultiple;

  /// Starting torque (% of full-load torque).
  final double startTorquePct;

  /// Plain-language note on the trade-off (inrush vs torque, energy saving, …).
  final String note;

  const StartingAnalysisResult({
    required this.method,
    required this.startCurrentA,
    required this.startCurrentMultiple,
    required this.startTorquePct,
    required this.note,
  });
}

double _round(double x, [int dp = 2]) {
  var f = 1.0;
  for (var i = 0; i < dp; i++) {
    f *= 10;
  }
  return (x * f).round() / f;
}

/// Starting current/torque for a motor under [starter], and a note on the
/// trade-off. [variableTorque] (pump/fan) refines the VFD energy-saving note.
StartingAnalysisResult startingAnalysis(
  Current flc,
  StarterType starter, {
  bool variableTorque = false,
  StartingDuty duty = StartingDuty.normal,
}) {
  final p = startingProfiles[starter] ?? startingProfiles[StarterType.dol]!;
  final startCurrentA = _round(flc.amperes * p.startMultiple, 0);

  var note =
      '${p.label}: starting current ~${p.startMultiple}x FLC ($startCurrentA A), '
      '~${p.startTorquePct}% starting torque.';
  switch (starter) {
    case StarterType.vfd:
      note += variableTorque
          ? ' Variable-torque load — large energy saving at part speed (cube law).'
          : ' Full torque from standstill with minimal inrush.';
    case StarterType.softStarter:
      note += ' Smooth voltage ramp (adjustable ~2-4x FLC) reduces mechanical '
          'and electrical stress.';
    case StarterType.starDelta:
      note += ' Inrush cut to ~1/3 of DOL, but only ~1/3 starting torque — '
          'not for high-inertia loads.';
    case StarterType.dol:
    case StarterType.reversing:
    case StarterType.ats:
    case StarterType.pump:
      break;
  }

  return StartingAnalysisResult(
    method: p.label,
    startCurrentA: Current(startCurrentA),
    startCurrentMultiple: p.startMultiple,
    startTorquePct: p.startTorquePct,
    note: note,
  );
}
