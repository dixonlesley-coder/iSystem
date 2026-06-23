/// Load-type catalog for the electrical domain — typical electrical characteristics
/// and design defaults per kind of load. Ported from PanelMaker `standards/loads.ts`
/// (LOAD_DEFAULTS). Drives power-factor / demand-factor defaults, the breaker trip
/// curve, and whether a load is naturally three-phase or motor-like.
///
/// Zero Flutter imports.
library;

import '../standards/puil.dart' show BreakerCurve;

/// The kinds of electrical load the engine knows defaults for. Mirrors
/// PanelMaker's `LoadKind` (ev_charger → [evCharger]).
enum LoadKind {
  general,
  lighting,
  socket,
  heating,
  hvac,
  motor,
  pump,
  evCharger,
  welding,
  capacitor,
  ups,
  spare,
  feeder,
}

/// Typical electrical defaults for a [LoadKind].
class LoadDefaults {
  final String label;

  /// Typical power factor (cos φ).
  final double cosPhi;

  /// Typical demand / utilisation factor (0–1).
  final double demandFactor;

  /// Preferred breaker trip curve.
  final BreakerCurve curve;

  /// Larger ratings of this load are normally supplied three-phase.
  final bool threePhasePreferred;

  /// Behaves like a motor (high inrush) for protection purposes.
  final bool motorLike;

  /// Whether the load uses a neutral conductor (extra core).
  final bool needsNeutral;

  const LoadDefaults({
    required this.label,
    required this.cosPhi,
    required this.demandFactor,
    required this.curve,
    required this.threePhasePreferred,
    required this.motorLike,
    required this.needsNeutral,
  });
}

/// Per-kind defaults, transcribed verbatim from PanelMaker LOAD_DEFAULTS.
const Map<LoadKind, LoadDefaults> loadDefaults = {
  LoadKind.general: LoadDefaults(
      label: 'General', cosPhi: 0.85, demandFactor: 1, curve: BreakerCurve.c,
      threePhasePreferred: false, motorLike: false, needsNeutral: true),
  LoadKind.lighting: LoadDefaults(
      label: 'Lighting', cosPhi: 0.9, demandFactor: 1, curve: BreakerCurve.b,
      threePhasePreferred: false, motorLike: false, needsNeutral: true),
  LoadKind.socket: LoadDefaults(
      label: 'Socket outlets', cosPhi: 0.9, demandFactor: 0.7,
      curve: BreakerCurve.c, threePhasePreferred: false, motorLike: false,
      needsNeutral: true),
  LoadKind.heating: LoadDefaults(
      label: 'Heating / resistive', cosPhi: 1.0, demandFactor: 1,
      curve: BreakerCurve.c, threePhasePreferred: true, motorLike: false,
      needsNeutral: false),
  LoadKind.hvac: LoadDefaults(
      label: 'HVAC / air-con', cosPhi: 0.85, demandFactor: 0.9,
      curve: BreakerCurve.c, threePhasePreferred: true, motorLike: true,
      needsNeutral: true),
  LoadKind.motor: LoadDefaults(
      label: 'Motor', cosPhi: 0.85, demandFactor: 1, curve: BreakerCurve.d,
      threePhasePreferred: true, motorLike: true, needsNeutral: false),
  LoadKind.pump: LoadDefaults(
      label: 'Pump', cosPhi: 0.85, demandFactor: 1, curve: BreakerCurve.d,
      threePhasePreferred: true, motorLike: true, needsNeutral: false),
  LoadKind.evCharger: LoadDefaults(
      label: 'EV charger', cosPhi: 0.98, demandFactor: 1, curve: BreakerCurve.c,
      threePhasePreferred: true, motorLike: false, needsNeutral: true),
  LoadKind.welding: LoadDefaults(
      label: 'Welding', cosPhi: 0.7, demandFactor: 0.5, curve: BreakerCurve.d,
      threePhasePreferred: true, motorLike: false, needsNeutral: true),
  LoadKind.capacitor: LoadDefaults(
      label: 'Capacitor bank', cosPhi: 1.0, demandFactor: 1,
      curve: BreakerCurve.c, threePhasePreferred: true, motorLike: false,
      needsNeutral: false),
  LoadKind.ups: LoadDefaults(
      label: 'UPS', cosPhi: 0.9, demandFactor: 1, curve: BreakerCurve.c,
      threePhasePreferred: false, motorLike: false, needsNeutral: true),
  LoadKind.spare: LoadDefaults(
      label: 'Spare way', cosPhi: 1.0, demandFactor: 0, curve: BreakerCurve.c,
      threePhasePreferred: false, motorLike: false, needsNeutral: true),
  LoadKind.feeder: LoadDefaults(
      label: 'Feeder (sub-panel)', cosPhi: 0.85, demandFactor: 1,
      curve: BreakerCurve.c, threePhasePreferred: true, motorLike: false,
      needsNeutral: true),
};

/// Practical ceiling (W) for a single-phase final circuit before three-phase is
/// preferred — Indonesian single-phase service tops out around 5.5 kVA.
const double singlePhaseMaxW = 5500;

/// Motors at/above this rating (kW) are normally three-phase.
const double motorThreePhaseKw = 3;
