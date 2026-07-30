/// MODULE-AUDIT-REVIEW Wave A — the sizing FLAGS that were computed but never
/// reached the caller, plus the two verdicts that were plain wrong.
///
/// Covered here (each finding id is quoted on its group):
///   M2  — `sizeByEqualFriction` / `sizeRectangularByEqualFriction` never
///         consulted the duct velocity cap.
///   M6  — rectangular `overCapacity` was judged from the IDEAL sides, flagging
///         compliant ducts.
///   M3  — storm `RainwaterSizingResult.overCapacity` was dropped by
///         `autoSizeNetwork`.
///   M4  — water-supply `WaterSupplySizingResult.overVelocity` likewise.
///   M5  — drainage self-cleansing (v ≥ 0.6 m/s) was never applied on the DFU
///         path.
///   M11 — `selectMotor` clamped at 75 kW with no flag on the duty.
///   M17 — Hardy–Cross non-convergence was unobservable.
///   M18 — `applySizeOverride` dropped the flags and zeroed a sanitary
///         override's velocity.
///
/// Every expected number is hand-derived from first principles in the comment
/// above its expectation (areas from πD²/4, Manning from (1/n)·R^(2/3)·√S,
/// shaft power from ρgQH/η) — the engine's own primitives are used only where
/// the point of the test is "the dispatcher chose THIS primitive".
library;

import 'dart:math' as math;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/hardy_cross.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show kSelfCleansingVelocityMps;
import 'package:mechx_engine/sizing/duct_sizing.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// A two-node, one-edge network of [service] (the smallest thing that can be
/// auto-sized): a source root `r` and a demand leaf `d`.
Network _twoNode(ServiceType service) => Network(
      nodes: const [
        NetNode(id: 'r', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(
          id: 'd',
          sheetId: 's1',
          x: 100,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture,
        ),
      ],
      edges: [NetEdge(id: 'e', fromId: 'r', toId: 'd', service: service)],
    );

void main() {
  // ── M2 — equal friction must ALSO respect the velocity cap ─────────────────

  group('M2 · equal-friction honours a velocity cap (round)', () {
    // Q = 2.0 m³/s at a 2.0 Pa/m target. The audit's probe case: friction alone
    // settles on DN500, whose mean velocity is
    //   A = π·0.500²/4 = 0.196349540849 m²
    //   v = 2.0 / 0.196349540849 = 10.1859 m/s
    // — a 10 m/s duct shipped with overCapacity false and no velocity warning
    // (the checker skips auto-sized ducts by design).
    const q = FlowRate(2.0);
    const target = 2.0;

    test('without a cap it still picks the friction-only size (10.19 m/s)', () {
      final r = sizeByEqualFriction(airflow: q, targetPaPerMetre: target);
      expect(r.diameter.inMillimeters, closeTo(500, 1e-9));
      expect(
        r.actualVelocity.metersPerSecond,
        closeTo(2.0 / (math.pi * 0.5 * 0.5 / 4.0), 1e-12),
      );
      expect(r.actualVelocity.metersPerSecond, closeTo(10.185916357881, 1e-9));
      expect(r.frictionPerMetrePa, lessThanOrEqualTo(target));
      // Byte-identical guarantee: a null cap changes nothing.
      expect(r.overCapacity, isFalse);
    });

    test('with the 5 m/s cap it steps UP until both constraints hold', () {
      final r = sizeByEqualFriction(
        airflow: q,
        targetPaPerMetre: target,
        maxVelocity: const Velocity(5.0),
      );
      // The ladder from DN500 upward, v = Q / (πD²/4):
      //   DN560 → 0.246301 m² → 8.1202 m/s   (over)
      //   DN630 → 0.311725 m² → 6.4159 m/s   (over)
      //   DN710 → 0.395919 m² → 5.0516 m/s   (over — only just)
      //   DN800 → 0.502655 m² → 3.9789 m/s   (OK) ⇒ chosen
      expect(r.diameter.inMillimeters, closeTo(800, 1e-9));
      expect(
        r.actualVelocity.metersPerSecond,
        closeTo(2.0 / (math.pi * 0.8 * 0.8 / 4.0), 1e-12),
      );
      expect(r.actualVelocity.metersPerSecond, closeTo(3.978873577297, 1e-9));
      // Both constraints genuinely hold at the chosen size.
      expect(r.actualVelocity.metersPerSecond, lessThanOrEqualTo(5.0));
      expect(r.frictionPerMetrePa, lessThanOrEqualTo(target));
      expect(r.overCapacity, isFalse);
      // DN710 (the rung below) really was over the cap — so DN800 is the
      // SMALLEST size satisfying both, not merely a size that satisfies both.
      expect(2.0 / (math.pi * 0.71 * 0.71 / 4.0), greaterThan(5.0));
    });

    test('clamps + flags overCapacity when no size can meet the cap', () {
      // Q = 4.92 m³/s. At a 1.0 Pa/m target friction alone settles on DN900
      // (7.73 m/s, overCapacity FALSE — the silent case). With the cap, even
      // the largest standard duct is too small:
      //   DN1000 → A = π·1.0²/4 = 0.785398 m² → v = 4.92/0.785398 = 6.2643 m/s
      const big = FlowRate(4.92);
      final uncapped = sizeByEqualFriction(airflow: big);
      expect(uncapped.diameter.inMillimeters, closeTo(900, 1e-9));
      expect(uncapped.overCapacity, isFalse);
      expect(
        uncapped.actualVelocity.metersPerSecond,
        closeTo(4.92 / (math.pi * 0.9 * 0.9 / 4.0), 1e-12),
      );

      final capped =
          sizeByEqualFriction(airflow: big, maxVelocity: const Velocity(5.0));
      expect(capped.diameter.inMillimeters, closeTo(1000, 1e-9));
      expect(
        capped.actualVelocity.metersPerSecond,
        closeTo(4.92 / (math.pi * 1.0 * 1.0 / 4.0), 1e-12),
      );
      expect(capped.actualVelocity.metersPerSecond, closeTo(6.264338560097, 1e-9));
      expect(capped.actualVelocity.metersPerSecond, greaterThan(5.0));
      expect(capped.overCapacity, isTrue);
    });
  });

  group('M2 · equal-friction honours a velocity cap (rectangular)', () {
    // Q = 1.2 m³/s, aspect 1.5, target 1.0 Pa/m.
    const q = FlowRate(1.2);

    test('without a cap it picks the friction-only 600 × 350 (5.71 m/s)', () {
      final r = sizeRectangularByEqualFriction(airflow: q);
      expect(r.width.inMillimeters, closeTo(600, 1e-9));
      expect(r.height.inMillimeters, closeTo(350, 1e-9));
      // A = 0.600 × 0.350 = 0.21 m² → v = 1.2 / 0.21 = 5.714 m/s
      expect(r.actualVelocity.metersPerSecond, closeTo(1.2 / 0.21, 1e-12));
      expect(r.overCapacity, isFalse);
    });

    test('with the 5 m/s cap it steps up one rung to 600 × 400', () {
      final r = sizeRectangularByEqualFriction(
        airflow: q,
        maxVelocity: const Velocity(5.0),
      );
      // Next candidate: H = 400, W = roundUp(1.5 × 400 = 600) = 600.
      // A = 0.600 × 0.400 = 0.24 m² → v = 1.2 / 0.24 = 5.000 m/s — exactly ON
      // the cap, which must be ACCEPTED (the comparison carries a relative
      // tolerance so floating-point dust in the area product cannot reject a
      // size that is arithmetically compliant).
      expect(r.width.inMillimeters, closeTo(600, 1e-9));
      expect(r.height.inMillimeters, closeTo(400, 1e-9));
      expect(r.actualVelocity.metersPerSecond, closeTo(5.0, 1e-9));
      expect(r.frictionPerMetrePa, lessThanOrEqualTo(1.0));
      expect(r.overCapacity, isFalse);
    });
  });

  group('M2 · the network dispatcher threads ctx.maxDuctVelocity', () {
    test('round equal-friction edge is sized against the context cap', () {
      const ctx = SizingContext(
        ductMethod: DuctSizingMethod.equalFriction,
        ductEqualFrictionPa: 2.0,
        // maxDuctVelocity defaults to 5.0 m/s.
      );
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.duct),
        ctx,
        leafDemand: const {ServiceType.duct: FlowRate(2.0)},
      );
      // Same case as the unit test above: DN800, not the friction-only DN500.
      expect(sized['e']!.diameter.inMillimeters, closeTo(800, 1e-9));
      expect(sized['e']!.velocity.metersPerSecond, lessThanOrEqualTo(5.0));
      expect(sized['e']!.overCapacity, isFalse);
    });

    test('rectangular equal-friction edge is sized against the context cap', () {
      const ctx = SizingContext(
        ductShape: DuctShape.rectangular,
        ductMethod: DuctSizingMethod.equalFriction,
      );
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.duct),
        ctx,
        leafDemand: const {ServiceType.duct: FlowRate(1.2)},
      );
      expect(sized['e']!.width!.inMillimeters, closeTo(600, 1e-9));
      expect(sized['e']!.height!.inMillimeters, closeTo(400, 1e-9));
      expect(sized['e']!.velocity.metersPerSecond, closeTo(5.0, 1e-9));
    });

    test('the VELOCITY method path is untouched by the cap threading', () {
      // Q = 1.2 m³/s, round, velocity method: A_req = 1.2/5 = 0.24 m² →
      // D_ideal = √(4 × 0.24 / π) = 0.5527 m → the first standard size ≥ that
      // is DN560 (v = 1.2 / 0.246301 = 4.872 m/s).
      const ctx = SizingContext();
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.duct),
        ctx,
        leafDemand: const {ServiceType.duct: FlowRate(1.2)},
      );
      expect(sized['e']!.diameter.inMillimeters, closeTo(560, 1e-9));
      expect(
        sized['e']!.velocity.metersPerSecond,
        closeTo(1.2 / (math.pi * 0.56 * 0.56 / 4.0), 1e-12),
      );
      expect(sized['e']!.overCapacity, isFalse);
    });
  });

  // ── M6 — rectangular overCapacity from the ACHIEVED velocity ───────────────

  group('M6 · rectangular overCapacity is judged from the achieved velocity',
      () {
    test('the confirmed false positive is clean (1200 × 900 at 4.56 m/s)', () {
      // Q = 4.92 m³/s, cap 5.0, aspect 1.5.
      //   A_req = 4.92 / 5.0        = 0.984 m²
      //   H_ideal = √(0.984 / 1.5)  = 0.80994 m → 810 mm → rounds up to 900
      //   W_ideal = 1.5 × 0.80994   = 1.21491 m → 1215 mm → clamps to 1200
      // The IDEAL width exceeds the largest standard side, which is what the
      // old test flagged — but the DELIVERED section is
      //   A = 1.200 × 0.900 = 1.08 m² → v = 4.92 / 1.08 = 4.5556 m/s ≤ 5.0.
      final r = sizeRectangularByVelocity(
        airflow: const FlowRate(4.92),
        maxVelocity: const Velocity(5.0),
      );
      expect(r.width.inMillimeters, closeTo(1200, 1e-9));
      expect(r.height.inMillimeters, closeTo(900, 1e-9));
      expect(r.actualVelocity.metersPerSecond, closeTo(4.92 / 1.08, 1e-12));
      expect(r.actualVelocity.metersPerSecond, lessThanOrEqualTo(5.0));
      expect(r.overCapacity, isFalse, reason: 'compliant duct must not flag');
    });

    test('a genuinely over-velocity clamped section still flags', () {
      // Q = 8.0 m³/s, cap 5.0, aspect 1.5.
      //   A_req = 1.6 m²; H_ideal = √(1.6/1.5) = 1.0328 m → clamps to 1200
      //   W_ideal = 1.5492 m → clamps to 1200
      //   A = 1.2 × 1.2 = 1.44 m² → v = 8.0 / 1.44 = 5.5556 m/s > 5.0
      final r = sizeRectangularByVelocity(
        airflow: const FlowRate(8.0),
        maxVelocity: const Velocity(5.0),
      );
      expect(r.width.inMillimeters, closeTo(1200, 1e-9));
      expect(r.height.inMillimeters, closeTo(1200, 1e-9));
      expect(r.actualVelocity.metersPerSecond, closeTo(8.0 / 1.44, 1e-12));
      expect(r.overCapacity, isTrue);
    });

    test('the flag reaches the edge through autoSizeNetwork', () {
      const ctx = SizingContext(ductShape: DuctShape.rectangular);
      final clean = autoSizeNetwork(
        _twoNode(ServiceType.duct),
        ctx,
        leafDemand: const {ServiceType.duct: FlowRate(4.92)},
      );
      expect(clean['e']!.overCapacity, isFalse);
      final over = autoSizeNetwork(
        _twoNode(ServiceType.duct),
        ctx,
        leafDemand: const {ServiceType.duct: FlowRate(8.0)},
      );
      expect(over['e']!.overCapacity, isTrue);
    });
  });

  // ── M3 — storm over-capacity reaches EdgeSizing ────────────────────────────

  group('M3 · storm downpipe over-capacity reaches the edge', () {
    test('75 L/s exceeds the DN200 table top ⇒ overCapacity', () {
      // The largest tabulated downpipe carries 65 L/s at DN200; 75 L/s cannot
      // be carried by ANY single downpipe in the table, so the DN200 returned
      // is the table limit and the catchment must be split.
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.rainwater),
        const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.075)},
      );
      expect(sized['e']!.diameter.inMillimeters, closeTo(200, 1e-9));
      expect(sized['e']!.overCapacity, isTrue);
    });

    test('a catchment inside the table is NOT flagged', () {
      // 30 L/s is exactly the DN150 rated capacity (30.0 L/s ≥ 30.0).
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.rainwater),
        const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.030)},
      );
      expect(sized['e']!.diameter.inMillimeters, closeTo(150, 1e-9));
      expect(sized['e']!.overCapacity, isFalse);
    });
  });

  // ── M4 — water-supply over-velocity reaches EdgeSizing ─────────────────────

  group('M4 · water-supply over-velocity reaches the edge', () {
    test('an 80 L/s trunk exceeds the DN200 table top ⇒ overCapacity', () {
      // DN200 is the largest DN in the series:
      //   A = π·0.200²/4 = 0.0314159265 m²
      //   v = 0.080 / 0.0314159265 = 2.5465 m/s  >  the 2.0 m/s SNI cap
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.coldWater),
        const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0.080)},
      );
      final s = sized['e']!;
      expect(s.diameter.inMillimeters, closeTo(200, 1e-9));
      expect(
        s.velocity.metersPerSecond,
        closeTo(0.080 / (math.pi * 0.2 * 0.2 / 4.0), 1e-12),
      );
      expect(s.velocity.metersPerSecond, closeTo(2.546479089470, 1e-9));
      expect(s.velocity.metersPerSecond, greaterThan(2.0));
      expect(s.overCapacity, isTrue);
    });

    test('an in-band branch is NOT flagged', () {
      // 2 L/s: DN15 → A = 1.767e-4 → 11.3 m/s (over) … up to
      // DN40 → A = π·0.040²/4 = 1.256637e-3 m² → v = 1.5915 m/s ≤ 2.0 ⇒ chosen.
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.coldWater),
        const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0.002)},
      );
      expect(sized['e']!.diameter.inMillimeters, closeTo(40, 1e-9));
      expect(
        sized['e']!.velocity.metersPerSecond,
        closeTo(0.002 / (math.pi * 0.04 * 0.04 / 4.0), 1e-12),
      );
      expect(sized['e']!.overCapacity, isFalse);
    });
  });

  // ── M5 — self-cleansing on the DFU path ────────────────────────────────────

  group('M5 · drainage self-cleansing is judged on the DFU path', () {
    // Manning full-bore velocity at the default slope 0.01 and n = 0.010:
    //   v = (1/n)·R^(2/3)·√S  with R = D/4 and √0.01 = 0.1
    //   DN40  → R = 0.01000 → 0.01^(2/3)    = 0.0464159 → v = 0.46416 m/s
    //   DN50  → R = 0.01250 → 0.0125^(2/3)  = 0.0538609 → v = 0.53861 m/s
    //   DN100 → R = 0.02500 → 0.025^(2/3)   = 0.0854988 → v = 0.85499 m/s
    // The self-cleansing minimum is 0.6 m/s, so DN40 and DN50 FAIL and DN100
    // passes — exactly the band the audit measured (0.46–0.54 m/s "OK").
    Map<String, EdgeSizing> sizeDrain(double dfu) => autoSizeNetwork(
          _twoNode(ServiceType.drainage),
          const SizingContext(),
          leafDemand: const {ServiceType.drainage: FlowRate(0)},
          nodeDrainageUnits: {'d': dfu},
        );

    test('a DN40 branch at 1:100 is NOT self-cleansing (0.464 m/s)', () {
      // Branch DFU table: dfu ≤ 1 ⇒ DN40.
      final s = sizeDrain(1.0)['e']!;
      expect(s.diameter.inMillimeters, closeTo(40, 1e-9));
      expect(s.velocity.metersPerSecond, closeTo(0.464158883361, 1e-9));
      expect(s.velocity.metersPerSecond, lessThan(kSelfCleansingVelocityMps));
      expect(s.selfCleansingOk, isFalse);
    });

    test('a DN50 branch at 1:100 is NOT self-cleansing (0.539 m/s)', () {
      // Branch DFU table: 1 < dfu ≤ 3 ⇒ DN50.
      final s = sizeDrain(3.0)['e']!;
      expect(s.diameter.inMillimeters, closeTo(50, 1e-9));
      expect(s.velocity.metersPerSecond, closeTo(0.538608672508, 1e-9));
      expect(s.selfCleansingOk, isFalse);
    });

    test('a DN100 branch at 1:100 IS self-cleansing (0.855 m/s)', () {
      // Branch DFU table: 20 < dfu ≤ 160 ⇒ DN100.
      final s = sizeDrain(30.0)['e']!;
      expect(s.diameter.inMillimeters, closeTo(100, 1e-9));
      expect(s.velocity.metersPerSecond, closeTo(0.854987973338, 1e-9));
      expect(
        s.velocity.metersPerSecond,
        greaterThanOrEqualTo(kSelfCleansingVelocityMps),
      );
      expect(s.selfCleansingOk, isTrue);
    });

    test('a VENT carries no flow, so it never fails self-cleansing', () {
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.vent),
        const SizingContext(),
        leafDemand: const {ServiceType.vent: FlowRate(0)},
        nodeDrainageUnits: const {'d': 1.0},
      );
      expect(sized['e']!.velocity.metersPerSecond, 0.0);
      expect(sized['e']!.selfCleansingOk, isTrue);
    });

    test('non-gravity services default to true (byte-identical)', () {
      final water = autoSizeNetwork(
        _twoNode(ServiceType.coldWater),
        const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0.002)},
      );
      expect(water['e']!.selfCleansingOk, isTrue);
      final air = autoSizeNetwork(
        _twoNode(ServiceType.duct),
        const SizingContext(),
        leafDemand: const {ServiceType.duct: FlowRate(0.5)},
      );
      expect(air['e']!.selfCleansingOk, isTrue);
    });

    test('a steeper slope lifts a DN50 branch over the threshold', () {
      // At slope 0.04, √S = 0.2 ⇒ v doubles: DN50 → 2 × 0.53861 = 1.07722 m/s.
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.drainage),
        const SizingContext(drainageSlope: 0.04),
        leafDemand: const {ServiceType.drainage: FlowRate(0)},
        nodeDrainageUnits: const {'d': 3.0},
      );
      expect(
        sized['e']!.velocity.metersPerSecond,
        closeTo(2.0 * 0.538608672508, 1e-9),
      );
      expect(sized['e']!.selfCleansingOk, isTrue);
    });
  });

  // ── M11 — the clamped motor frame is flagged ───────────────────────────────

  group('M11 · a clamped 75 kW motor is flagged on the duty', () {
    test('a 90 kW-class pump duty reports motorOversized', () {
      // Q = 0.5 m³/s at H = 12 m, η_pump = 0.70:
      //   P_hyd   = ρ·g·Q·H = 1000 × 9.81 × 0.5 × 12 = 58 860 W
      //   P_shaft = 58 860 / 0.70                    = 84 085.714 W = 84.09 kW
      // The largest standard frame is 75 kW ⇒ selectMotor CLAMPS.
      final duty = sizePump(flow: const FlowRate(0.5), head: const Head(12.0));
      expect(duty.hydraulicPower.watts, closeTo(58860.0, 1e-6));
      expect(duty.shaftPower.watts, closeTo(58860.0 / 0.70, 1e-6));
      expect(duty.shaftPower.inKiloWatts, greaterThan(standardMotorKw.last));
      expect(duty.selectedMotor.inKiloWatts, closeTo(75.0, 1e-9));
      expect(duty.motorOversized, isTrue);
    });

    test('an in-ladder pump duty does NOT (default byte-identical)', () {
      // Q = 0.02 m³/s at H = 30 m: P_hyd = 1000 × 9.81 × 0.02 × 30 = 5 886 W;
      // P_shaft = 5 886 / 0.70 = 8 408.571 W = 8.41 kW ⇒ the 11 kW frame.
      final duty = sizePump(flow: const FlowRate(0.02), head: const Head(30.0));
      expect(duty.shaftPower.watts, closeTo(5886.0 / 0.70, 1e-6));
      expect(duty.selectedMotor.inKiloWatts, closeTo(11.0, 1e-9));
      expect(duty.motorOversized, isFalse);
    });

    test('a 92 kW-class fan duty reports motorOversized', () {
      // Q = 20 m³/s at Δp = 3000 Pa, η_fan = 0.65:
      //   P_air   = 20 × 3000       = 60 000 W
      //   P_shaft = 60 000 / 0.65   = 92 307.692 W = 92.31 kW  > 75 kW
      final duty = sizeFan(
        airflow: const FlowRate(20.0),
        totalStaticPressure: const Pressure(3000.0),
      );
      expect(duty.airPower.watts, closeTo(60000.0, 1e-6));
      expect(duty.shaftPower.watts, closeTo(60000.0 / 0.65, 1e-6));
      expect(duty.selectedMotor.inKiloWatts, closeTo(75.0, 1e-9));
      expect(duty.motorOversized, isTrue);
    });

    test('an in-ladder fan duty does NOT', () {
      // Q = 2 m³/s at 500 Pa: P_air = 1000 W; P_shaft = 1000/0.65 = 1538.46 W
      // = 1.538 kW ⇒ the 1.5 kW frame is too small, so 2.2 kW is selected.
      final duty = sizeFan(
        airflow: const FlowRate(2.0),
        totalStaticPressure: const Pressure(500.0),
      );
      expect(duty.shaftPower.watts, closeTo(1000.0 / 0.65, 1e-6));
      expect(duty.selectedMotor.inKiloWatts, closeTo(2.2, 1e-9));
      expect(duty.motorOversized, isFalse);
    });

    test('a duty landing exactly ON the largest frame is not oversized', () {
      // The comparison is strict: 75.0 kW of shaft power selects the 75 kW
      // frame, which is a valid selection, not a clamp.
      expect(motorOversizedFor(Power.kiloWatts(75.0)), isFalse);
      expect(motorOversizedFor(Power.kiloWatts(75.0000001)), isTrue);
    });
  });

  // ── M17 — Hardy–Cross convergence is observable ────────────────────────────

  group('M17 · Hardy–Cross non-convergence is observable', () {
    // A square ring: root A feeds B and D, which meet at the draw point C.
    final ringEdges = <({String id, String from, String to})>[
      (id: 'AB', from: 'A', to: 'B'),
      (id: 'BC', from: 'B', to: 'C'),
      (id: 'AD', from: 'A', to: 'D'),
      (id: 'DC', from: 'D', to: 'C'),
    ];

    test('an empty loop list converges trivially in 0 iterations', () {
      expect(hardyCrossDetailed(const []), (iterations: 0, converged: true));
      expect(hardyCross(const []), 0);
    });

    test('a TREE reports converged with 0 iterations', () {
      final r = balanceFlows(
        edges: const [
          (id: 'AB', from: 'A', to: 'B'),
          (id: 'BC', from: 'B', to: 'C'),
        ],
        root: 'A',
        demand: const {'C': 0.01},
        resistance: (_) => 1.0,
      );
      expect(r.loopCount, 0);
      expect(r.iterations, 0);
      expect(r.converged, isTrue);
    });

    test('an asymmetric ring given ONE sweep reports converged == false', () {
      // Deliberately starving the solver proves the verdict is real: the seed
      // routes ALL demand down the tree (chord flow 0), so one correction on an
      // asymmetric ring cannot drive |ΔQ| below the 1e-12 tolerance.
      final starved = balanceFlows(
        edges: ringEdges,
        root: 'A',
        demand: const {'C': 0.01},
        resistance: (id) => id == 'AB' || id == 'BC' ? 1.0 : 7.0,
        maxIterations: 1,
      );
      expect(starved.loopCount, 1);
      expect(starved.iterations, 1);
      expect(starved.converged, isFalse);

      // With the normal budget the SAME ring settles.
      final settled = balanceFlows(
        edges: ringEdges,
        root: 'A',
        demand: const {'C': 0.01},
        resistance: (id) => id == 'AB' || id == 'BC' ? 1.0 : 7.0,
      );
      expect(settled.converged, isTrue);
      expect(settled.iterations, lessThan(500));
      // Continuity holds either way: both legs out of A sum to the draw.
      expect(
        starved.edgeFlow['AB']! + starved.edgeFlow['AD']!,
        closeTo(0.01, 1e-12),
      );
      expect(
        settled.edgeFlow['AB']! + settled.edgeFlow['AD']!,
        closeTo(0.01, 1e-12),
      );
    });

    test('a settled ring leaves every edge loopUnbalanced == false', () {
      // The autoSizeNetwork wiring in its byte-identical state: a real looped
      // air component that DOES converge must carry no provisional marks.
      const ring = Network(
        nodes: [
          NetNode(id: 'A', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'B', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'C', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
          NetNode(id: 'D', sheetId: 's1', x: 0, y: 100, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'AB', fromId: 'A', toId: 'B', service: ServiceType.duct),
          NetEdge(id: 'BC', fromId: 'B', toId: 'C', service: ServiceType.duct),
          NetEdge(id: 'AD', fromId: 'A', toId: 'D', service: ServiceType.duct),
          NetEdge(id: 'DC', fromId: 'D', toId: 'C', service: ServiceType.duct),
        ],
      );
      final sized = autoSizeNetwork(
        ring,
        const SizingContext(),
        leafDemand: const {ServiceType.duct: FlowRate(0)},
        nodeFlowDemand: const {'C': FlowRate(0.4)},
      );
      expect(sized.length, 4);
      for (final s in sized.values) {
        expect(s.loopUnbalanced, isFalse);
      }
    });

    test('withLoopUnbalanced preserves every other field', () {
      const base = EdgeSizing(
        edgeId: 'e',
        service: ServiceType.duct,
        flow: FlowRate(0.4),
        diameter: Diameter(0.4),
        velocity: Velocity(3.2),
        width: Length(0.5),
        height: Length(0.3),
        overCapacity: true,
        stackRaisedForBranch: true,
        flowFromId: 'A',
        selfCleansingOk: false,
      );
      final out = base.withLoopUnbalanced(true);
      expect(out.loopUnbalanced, isTrue);
      expect(out.edgeId, 'e');
      expect(out.flow.cubicMetersPerSecond, 0.4);
      expect(out.diameter.meters, 0.4);
      expect(out.velocity.metersPerSecond, 3.2);
      expect(out.width!.meters, 0.5);
      expect(out.height!.meters, 0.3);
      expect(out.overCapacity, isTrue);
      expect(out.stackRaisedForBranch, isTrue);
      expect(out.flowFromId, 'A');
      expect(out.selfCleansingOk, isFalse);
      // …and withFlowFrom preserves the new flags too.
      final rotated = out.withFlowFrom('B');
      expect(rotated.flowFromId, 'B');
      expect(rotated.loopUnbalanced, isTrue);
      expect(rotated.selfCleansingOk, isFalse);
    });
  });

  // ── M18 — applySizeOverride preserves the flags + re-derives the velocity ──

  group('M18 · applySizeOverride keeps the findings and the right velocity', () {
    test('every design flag survives an override', () {
      const base = EdgeSizing(
        edgeId: 'e',
        service: ServiceType.duct,
        flow: FlowRate(0.4),
        diameter: Diameter(0.4),
        velocity: Velocity(3.2),
        overCapacity: true,
        stackRaisedForBranch: true,
        flowFromId: 'A',
        selfCleansingOk: false,
        loopUnbalanced: true,
      );
      final out = applySizeOverride(base, Diameter.mm(500));
      expect(out.overCapacity, isTrue);
      expect(out.stackRaisedForBranch, isTrue);
      expect(out.loopUnbalanced, isTrue);
      expect(out.flowFromId, 'A');
      expect(out.selfCleansingOk, isFalse); // no ctx ⇒ carried, not re-judged
      // v = Q/A at the overridden diameter (continuity, unchanged behaviour).
      expect(
        out.velocity.metersPerSecond,
        closeTo(0.4 / (math.pi * 0.5 * 0.5 / 4.0), 1e-12),
      );
    });

    test('a drainage override recomputes MANNING, not the zero-flow continuity',
        () {
      // The sanitary path carries a placeholder flow of 0 (it is sized from
      // DFU), so the old continuity formula returned 0.0 m/s for every drainage
      // override. With the context supplied the velocity is the full-bore
      // Manning velocity at the OVERRIDDEN diameter:
      //   DN100, n = 0.010, S = 0.01 ⇒ v = 100 × 0.025^(2/3) × 0.1 = 0.85499
      const ctx = SizingContext();
      const base = EdgeSizing(
        edgeId: 'e',
        service: ServiceType.drainage,
        flow: FlowRate(0), // the DFU-path placeholder
        diameter: Diameter(0.040),
        velocity: Velocity(0.464158883361278),
        selfCleansingOk: false,
      );
      final out = applySizeOverride(base, Diameter.mm(100), ctx: ctx);
      expect(out.velocity.metersPerSecond, closeTo(0.854987973338, 1e-9));
      // …and the self-cleansing verdict is re-judged AT the chosen size:
      // a hand-picked DN100 at 1:100 does clear 0.6 m/s.
      expect(out.selfCleansingOk, isTrue);

      // The reverse direction too: overriding DOWN to DN40 fails the check.
      final down = applySizeOverride(
        base.withFlowFrom(null),
        Diameter.mm(40),
        ctx: ctx,
      );
      expect(down.velocity.metersPerSecond, closeTo(0.464158883361, 1e-9));
      expect(down.selfCleansingOk, isFalse);
    });

    test('a VENT override still carries no velocity', () {
      const ctx = SizingContext();
      const base = EdgeSizing(
        edgeId: 'e',
        service: ServiceType.vent,
        flow: FlowRate(0),
        diameter: Diameter(0.040),
        velocity: Velocity(0),
      );
      final out = applySizeOverride(base, Diameter.mm(75), ctx: ctx);
      expect(out.velocity.metersPerSecond, 0.0);
      expect(out.selfCleansingOk, isTrue);
    });

    test('autoSizeNetwork keeps a storm over-capacity flag across an override',
        () {
      // 75 L/s is past the DN200 table top; hand-overriding the pipe to DN200
      // must NOT erase the finding that no single downpipe carries the flow.
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.rainwater),
        const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.075)},
        sizeOverrides: {'e': Diameter.mm(200)},
      );
      expect(sized['e']!.diameter.inMillimeters, closeTo(200, 1e-9));
      expect(sized['e']!.overCapacity, isTrue);
    });

    test('autoSizeNetwork re-judges a drainage override end-to-end', () {
      // A single DFU-1 branch auto-sizes to DN40 (0.464 m/s, not
      // self-cleansing); overriding it to DN100 lifts it over the threshold,
      // and the velocity shown is Manning at DN100 — never the placeholder 0.
      final sized = autoSizeNetwork(
        _twoNode(ServiceType.drainage),
        const SizingContext(),
        leafDemand: const {ServiceType.drainage: FlowRate(0)},
        nodeDrainageUnits: const {'d': 1.0},
        sizeOverrides: {'e': Diameter.mm(100)},
      );
      final s = sized['e']!;
      expect(s.diameter.inMillimeters, closeTo(100, 1e-9));
      expect(s.velocity.metersPerSecond, closeTo(0.854987973338, 1e-9));
      expect(s.selfCleansingOk, isTrue);
      // The flow-direction record still rides through the override.
      expect(s.flowFromId, 'd');
    });
  });

  // ── Cross-check: the engine's own primitive agrees with the hand arithmetic ─

  test('the hand-derived Manning figures match manningVelocity', () {
    for (final (mm, expected) in <(double, double)>[
      (40, 0.464158883361278),
      (50, 0.538608672507971),
      (100, 0.854987973338349),
    ]) {
      final v = manningVelocity(
        manningN: 0.010,
        hydraulicRadius: Length(Diameter.mm(mm).meters / 4.0),
        slope: 0.01,
      );
      expect(v.metersPerSecond, closeTo(expected, 1e-12));
      // …and the closed form: (1/n)·R^(2/3)·√S.
      expect(
        v.metersPerSecond,
        closeTo(
          (1.0 / 0.010) * math.pow(mm / 1000.0 / 4.0, 2.0 / 3.0) * 0.1,
          1e-12,
        ),
      );
    }
  });
}
