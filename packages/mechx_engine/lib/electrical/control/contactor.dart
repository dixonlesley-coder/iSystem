/// Contactor and overload-relay selection, IEC 60947-4-1.
/// Ported from PanelMaker `engine/control/selectContactor.ts` + `selectOverload.ts`
/// and `standards/control/contactor.ts`.
///
///   - AC-3 frame ratings mapped to switchable motor power at 400 V.
///   - AC-4 (inching/plugging) derating.
///   - Star-delta winding current factor.
///   - Per-frame heat dissipation for enclosure thermal sizing.
///   - Overload-relay set-point + trip class.
///
/// PURE Dart — zero Flutter imports.
library;

import '../../units.dart';

/// Motor starting duty — drives AC-4 frame derating and the overload trip class.
enum StartingDuty { normal, heavy, jogging }

/// Overload-relay trip class (IEC 60947-4-1).
enum OverloadTripClass {
  class10A('10A'),
  class10('10'),
  class20('20'),
  class30('30');

  final String label;
  const OverloadTripClass(this.label);
}

/// A standard contactor frame.
class ContactorFrame {
  /// Rated operational current Ie under AC-3 (A).
  final double ac3A;

  /// Max motor power switched at 400 V under AC-3 (kW).
  final double kw400;

  /// Approximate steady-state heat dissipation at rated current (W).
  final double heatLossW;

  const ContactorFrame({
    required this.ac3A,
    required this.kw400,
    required this.heatLossW,
  });
}

/// Standard contactor frames, ascending by AC-3 current.
///
/// // VERIFY (secondarySource): IEC 60947-4-1 typical frame ladder — confirm
/// against the chosen manufacturer's catalogue (Schneider TeSys, ABB AF, …).
const List<ContactorFrame> contactorAc3Frames = [
  ContactorFrame(ac3A: 9, kw400: 4, heatLossW: 2.2),
  ContactorFrame(ac3A: 12, kw400: 5.5, heatLossW: 2.5),
  ContactorFrame(ac3A: 18, kw400: 7.5, heatLossW: 3.0),
  ContactorFrame(ac3A: 25, kw400: 11, heatLossW: 3.5),
  ContactorFrame(ac3A: 32, kw400: 15, heatLossW: 4.0),
  ContactorFrame(ac3A: 40, kw400: 18.5, heatLossW: 4.5),
  ContactorFrame(ac3A: 50, kw400: 22, heatLossW: 6.0),
  ContactorFrame(ac3A: 65, kw400: 30, heatLossW: 7.5),
  ContactorFrame(ac3A: 80, kw400: 37, heatLossW: 8.5),
  ContactorFrame(ac3A: 95, kw400: 45, heatLossW: 9.5),
  ContactorFrame(ac3A: 115, kw400: 55, heatLossW: 11),
  ContactorFrame(ac3A: 150, kw400: 75, heatLossW: 14),
  ContactorFrame(ac3A: 185, kw400: 90, heatLossW: 16),
  ContactorFrame(ac3A: 225, kw400: 110, heatLossW: 18),
  ContactorFrame(ac3A: 265, kw400: 132, heatLossW: 22),
  ContactorFrame(ac3A: 300, kw400: 160, heatLossW: 26),
  ContactorFrame(ac3A: 400, kw400: 200, heatLossW: 32),
  ContactorFrame(ac3A: 500, kw400: 250, heatLossW: 40),
  ContactorFrame(ac3A: 630, kw400: 300, heatLossW: 48),
];

/// When an AC-3 frame is used for AC-4 duty (inching/plugging — breaking locked-
/// rotor current every cycle), usable current is ~0.2–0.3×. Default 0.25.
///
/// // VERIFY (secondarySource): IEC 60947-4-1 utilisation-category derating.
const double ac4DerateFactor = 0.25;

/// In a star-delta starter each phase winding carries line current / √3, so the
/// star contactor only needs ~58 % of the motor FLC. (1/√3 ≈ 0.577.)
///
/// // VERIFY (secondarySource): standard Y-Δ winding-current relationship.
const double starDeltaWindingFactor = 0.58;

/// Overload relay set-point factor on motor FLC (IEC allows 1.05–1.15).
///
/// // VERIFY (secondarySource): IEC 60947-4-1 overload setting range.
const double overloadSettingFactor = 1.15;

/// Round [x] to [dp] decimal places (mirrors PanelMaker `round`).
double _round(double x, [int dp = 2]) {
  final f = _pow10(dp);
  return (x * f).round() / f;
}

double _pow10(int n) {
  var r = 1.0;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

/// The result of selecting a contactor frame.
class ContactorSelection {
  /// The chosen frame.
  final ContactorFrame frame;

  /// Frame AC-3 rating (A).
  final double ac3A;

  /// Frame motor power at 400 V (kW).
  final double kw400;

  /// Frame steady-state heat dissipation (W).
  final double heatLossW;

  /// Current the frame must cover after winding / duty adjustment (A).
  final double targetA;

  /// False when no standard frame is large enough (the largest is returned).
  final bool ok;

  const ContactorSelection({
    required this.frame,
    required this.ac3A,
    required this.kw400,
    required this.heatLossW,
    required this.targetA,
    required this.ok,
  });
}

/// Select the smallest AC-3 frame covering the (adjusted) motor current.
///
/// - [starDelta] true → the *star* contactor only needs 58 % of [flc].
/// - [jogging] (AC-4 inching/plugging) → the frame must be much larger
///   (`target / 0.25`).
ContactorSelection selectContactor(
  Current flc, {
  bool starDelta = false,
  StartingDuty duty = StartingDuty.normal,
}) {
  final windingFactor = starDelta ? starDeltaWindingFactor : 1.0;
  final targetA = flc.amperes * windingFactor;

  // AC-4 (inching/plugging) needs a much larger AC-3 frame.
  final isAc4 = duty == StartingDuty.jogging;
  final requiredAc3 = isAc4 ? targetA / ac4DerateFactor : targetA;

  for (final f in contactorAc3Frames) {
    if (f.ac3A >= requiredAc3) {
      return ContactorSelection(
        frame: f,
        ac3A: f.ac3A,
        kw400: f.kw400,
        heatLossW: f.heatLossW,
        targetA: _round(targetA, 1),
        ok: true,
      );
    }
  }
  final largest = contactorAc3Frames.last;
  return ContactorSelection(
    frame: largest,
    ac3A: largest.ac3A,
    kw400: largest.kw400,
    heatLossW: largest.heatLossW,
    targetA: _round(targetA, 1),
    ok: false,
  );
}

/// Trip class recommended for a given starting duty.
OverloadTripClass overloadTripClassFor(StartingDuty duty) {
  switch (duty) {
    case StartingDuty.heavy:
      return OverloadTripClass.class20;
    case StartingDuty.jogging:
      return OverloadTripClass.class30;
    case StartingDuty.normal:
      return OverloadTripClass.class10;
  }
}

/// The result of selecting an overload relay.
class OverloadSelection {
  /// Recommended dial setting (A): the motor FLC (or delta-leg current).
  final Current settingA;

  /// Trip class.
  final OverloadTripClass tripClass;

  const OverloadSelection({required this.settingA, required this.tripClass});
}

/// Overload-relay set-point and trip class for a motor.
///
/// - [inStarLeg] true → the relay sits in a delta leg of a Y-Δ starter, so it
///   is set to FLC × 0.58.
OverloadSelection selectOverload(
  Current flc, {
  bool inStarLeg = false,
  StartingDuty duty = StartingDuty.normal,
}) {
  final legFactor = inStarLeg ? starDeltaWindingFactor : 1.0;
  return OverloadSelection(
    settingA: Current(_round(flc.amperes * legFactor, 1)),
    tripClass: overloadTripClassFor(duty),
  );
}
