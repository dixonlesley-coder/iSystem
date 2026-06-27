import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Spare-ways / future-load HEADROOM tests.
///
/// A null (or 0 %/0-way) [HeadroomSpec] leaves the incomer, busbar and section
/// count byte-identical; a future-load % grows the incomer + busbar; reserved
/// spare ways grow the busbar section count.
void main() {
  const p = PuilProfile();

  // A 3-phase panel with a sizeable balanced motor load so the demand current
  // sits well below the largest breaker frame (headroom room to grow).
  // Motor 50 kW, cosφ 0.85, 3-phase 400 V:
  //   Ib = 50000 / (√3 · 400 · 0.85) = 50000 / 588.9 = 84.9 A.
  ElectricalPanel panelWith(HeadroomSpec? headroom) => ElectricalPanel(
        id: 'MDP',
        name: 'Main',
        system: ElectricalSystem.threePhase,
        voltage: const Voltage(400),
        headroom: headroom,
        circuits: const [
          ElectricalCircuit(
            id: 'm1',
            name: 'Motor',
            loadKind: LoadKind.motor,
            motorKw: 50,
            cosPhi: 0.85,
            length: Length(10),
          ),
        ],
      );

  test('null headroom ⇒ no uplift, byte-identical incomer/busbar', () {
    final base = computePanel(p, panelWith(null));
    expect(base.headroomApplied, isFalse);
    expect(base.spareWaysReserved, 0);
    // futureLoadW collapses to demandW when no headroom is applied.
    expect(base.futureLoadW, base.demandW);

    // An explicit all-zero spec is identical to null.
    final zero = computePanel(p, panelWith(const HeadroomSpec()));
    expect(zero.headroomApplied, isFalse);
    expect(zero.incomer.breaker.ratingA.amperes,
        base.incomer.breaker.ratingA.amperes);
    expect(zero.busbar.csaMm2, base.busbar.csaMm2);
    expect(zero.busbarSections.length, base.busbarSections.length);
  });

  test('future-load % raises the incomer current and demand', () {
    final base = computePanel(p, panelWith(null));
    // 50 % spare ⇒ incomer sized for 1.5× the demand current.
    final spare = computePanel(
        p, panelWith(const HeadroomSpec(sparePercentage: 50)));

    expect(spare.headroomApplied, isTrue);
    // The reported future demand is 1.5× the present demand.
    expect(spare.futureLoadW, closeTo(base.demandW * 1.5, 1));
    // demandCurrent (today's load) is unchanged — only the incomer/busbar grow.
    expect(spare.demandCurrent.amperes, base.demandCurrent.amperes);
    // The incomer breaker frame is at least as large (it must cover 1.5×).
    expect(spare.incomer.breaker.ratingA.amperes,
        greaterThanOrEqualTo(base.incomer.breaker.ratingA.amperes));
    // 84.9 A → ×1.5 = 127.4 A. Base breaker covers ~84.9 A (next frame ≥ that);
    // the uplifted frame must cover ≥127.4 A, so it is strictly larger here.
    expect(spare.incomer.breaker.ratingA.amperes,
        greaterThan(base.incomer.breaker.ratingA.amperes));
  });

  test('spare ways grow the busbar section count past the per-section cap', () {
    // The profile caps a section at maxWaysPerBusbar (12) ways. One real way +
    // 12 reserved spare ways = 13 ways > 12 ⇒ the bus must split into 2 sections.
    final spareWays = computePanel(
        p, panelWith(HeadroomSpec(spareWays: p.maxWaysPerBusbar)));
    expect(spareWays.headroomApplied, isTrue);
    expect(spareWays.spareWaysReserved, p.maxWaysPerBusbar);
    expect(spareWays.busbarSections.length, greaterThanOrEqualTo(2));

    // Without the spare ways the single real way fits in one section.
    final base = computePanel(p, panelWith(null));
    expect(base.busbarSections.length, 1);
  });

  test('100 % headroom on an empty panel ⇒ futureLoadW = 0 (no divide trap)',
      () {
    const empty = ElectricalPanel(
      id: 'E',
      name: 'Empty',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      headroom: HeadroomSpec(sparePercentage: 100),
    );
    final r = computePanel(p, empty);
    expect(r.demandW, 0);
    expect(r.futureLoadW, 0); // 0 × 2.0 = 0
    expect(r.headroomApplied, isTrue);
  });

  group('HeadroomSpec arithmetic', () {
    test('demandMultiplier and spare-way clamps', () {
      expect(const HeadroomSpec().demandMultiplier, 1.0);
      expect(const HeadroomSpec(sparePercentage: 25).demandMultiplier, 1.25);
      // Negative % never shrinks demand.
      expect(const HeadroomSpec(sparePercentage: -10).demandMultiplier, 1.0);
      expect(const HeadroomSpec(spareWays: -3).effectiveSpareWays, 0);
      expect(const HeadroomSpec().isActive, isFalse);
      expect(const HeadroomSpec(sparePercentage: 10).isActive, isTrue);
      expect(const HeadroomSpec(spareWays: 2).isActive, isTrue);
    });

    test('JSON round-trip', () {
      const spec = HeadroomSpec(sparePercentage: 25, spareWays: 3);
      final back = HeadroomSpec.fromJson(spec.toJson());
      expect(back.sparePercentage, 25);
      expect(back.spareWays, 3);
      // Tolerant decode of an empty map.
      final empty = HeadroomSpec.fromJson(const {});
      expect(empty.sparePercentage, 0);
      expect(empty.spareWays, 0);
    });
  });

  test('model: panel round-trips headroom + diversityLibraryId', () {
    final panel = panelWith(const HeadroomSpec(sparePercentage: 20, spareWays: 2))
        .copyWith(diversityLibraryId: 'office');
    final back = ElectricalPanel.fromJson(panel.toJson());
    expect(back.headroom!.sparePercentage, 20);
    expect(back.headroom!.spareWays, 2);
    expect(back.diversityLibraryId, 'office');

    // Absent ⇒ null (byte-identical legacy file).
    final legacy = ElectricalPanel.fromJson(panelWith(null).toJson());
    expect(legacy.headroom, isNull);
    expect(legacy.diversityLibraryId, isNull);
  });
}
