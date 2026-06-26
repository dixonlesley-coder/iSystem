/// Commercial layer (BOM · catalogue · costing · quotation) tests.
///
/// Expected values are hand-derived with the arithmetic in comments (tests are
/// the spec). The BOM enumeration is checked against the engine's own computed
/// result (the per-circuit breaker/cable/RCD facts the BOM must mirror), while
/// the SKU match, cost sum and quotation sell price are derived purely from
/// fixed inputs.
library;

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/commercial_export.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/costing.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/quotation.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = PuilProfile();

  // ── (1) BOM from a small single-phase panel ────────────────────────────────
  //
  // A 1φ 230 V panel (lighting + a socket). On a single-phase panel the
  // circuits run at 230 V (no √3 split).
  //   c1 Lighting 1150 W, cosφ 0.9  → Ib = 1150/(230·0.9)=1150/207=5.555 → 5.6 A
  //         breaker = smallest MCB ≥ 5.6 = 6 A; lighting final min = 1.5 mm²;
  //         1φ ⇒ L+N+PE = 3-core; type NYM ⇒ cableSpec "NYM 3×1.5 mm²".
  //   c2 Socket  1800 W, cosφ 0.9   → Ib = 1800/207 = 8.695 → 8.7 A
  //         breaker = smallest MCB ≥ 8.7 = 10 A; socket final min = 2.5 mm²;
  //         RCD required (socket, 30 mA Type A).
  group('(1) BOM enumeration', () {
    const panel = ElectricalPanel(
      id: 'LP',
      name: 'LP-1',
      system: ElectricalSystem.singlePhase,
      voltage: Voltage(230),
      circuits: [
        ElectricalCircuit(
          id: 'c1',
          name: 'Lighting',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 1150,
          cosPhi: 0.9,
          length: Length(15),
        ),
        ElectricalCircuit(
          id: 'c2',
          name: 'Socket',
          loadKind: LoadKind.socket,
          loadW: 1800,
          cosPhi: 0.9,
          length: Length(15),
        ),
      ],
    );

    final r = computePanel(profile, panel);
    final sys = ElectricalSystemResult(
      projectId: 'p',
      panels: {'LP': r},
      order: const ['LP'],
      totalDemandW: r.demandW,
      supply: SupplySummary(
        connectedW: r.connectedW,
        demandW: r.demandW,
        demandVa: const ApparentPower(0),
        system: panel.system,
        voltage: panel.voltage,
      ),
      earthing: computeEarthing(profile,
          system: EarthingSystem.tnCs, supplyPeMm2: 16),
      warnings: const [],
    );

    final bom = buildBom(sys);
    final byCat = <PartCategory, List<BomLine>>{};
    for (final l in bom.lines) {
      (byCat[l.category] ??= []).add(l);
    }

    test('anchor: engine sized the two circuits as derived above', () {
      final c1 = r.circuits.firstWhere((c) => c.circuitId == 'c1');
      final c2 = r.circuits.firstWhere((c) => c.circuitId == 'c2');
      expect(c1.designCurrent.amperes, closeTo(5.6, 1e-9));
      expect(c1.breaker.ratingA.amperes, 6);
      expect(c1.cable.csaMm2, 1.5);
      expect(c1.grounding.cores, 3); // L+N+PE
      expect(c2.breaker.ratingA.amperes, 10);
      expect(c2.cable.csaMm2, 2.5);
      expect(c2.rcd.required, isTrue);
      expect(c2.rcd.ratingMa, 30);
    });

    test('breaker lines: 1 incomer + 2 branch = 3', () {
      // incomer (2-pole, 1φ) + c1 breaker + c2 breaker.
      expect(byCat[PartCategory.breaker]!.length, 3);
      expect(
        byCat[PartCategory.breaker]!.any((l) => l.description.contains('incomer')),
        isTrue,
      );
    });

    test('cable lines: one run per non-spare circuit = 2', () {
      final cables = byCat[PartCategory.cable]!;
      expect(cables.length, 2);
      // The 1.5 mm² lighting run matches NYM-1.5; the 2.5 mm² socket NYM-2.5.
      expect(cables.any((l) => l.sku == 'NYM-1.5'), isTrue);
      expect(cables.any((l) => l.sku == 'NYM-2.5'), isTrue);
    });

    test('one RCD line (socket only)', () {
      expect(byCat[PartCategory.rcd]!.length, 1);
      expect(byCat[PartCategory.rcd]!.single.description, contains('30 mA'));
    });

    test('busbar set + neutral + PE bars (3 busbar lines), 1 enclosure', () {
      expect(byCat[PartCategory.busbar]!.length, 3);
      expect(byCat[PartCategory.enclosure]!.length, 1);
      expect(byCat[PartCategory.enclosure]!.single.qty, 1);
    });

    test('cable quantity is the run length in metres', () {
      // Both runs are 15 m → qty 15 each (cable is sold per metre).
      expect(byCat[PartCategory.cable]!.every((l) => l.qty == 15), isTrue);
    });

    test('wiring accessories: light points + switches + sockets (estimate)', () {
      final acc = byCat[PartCategory.accessory]!;
      double q(String prefix) =>
          acc.firstWhere((l) => l.description.startsWith(prefix)).qty;
      // 1150 W / 36 W ⇒ 32 light points; 32 / 3 ⇒ 11 switches.
      expect(q('Light point'), 32);
      expect(q('Light switch (saklar)'), 11);
      // 1800 VA / 200 ⇒ 9 socket outlets.
      expect(q('Socket outlet (stop kontak)'), 9);
      // The small branch cables (1.5 / 2.5 mm²) clamp directly — no skun.
      expect(acc.any((l) => l.description.startsWith('Cable lug')), isFalse);
    });
  });

  group('(1b) cable lugs (skun) for a large cable', () {
    test('a 3φ feeder-size cable gets 5 conductors × 2 ends = 10 lugs', () {
      const big = ElectricalPanel(
        id: 'P',
        name: 'P',
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
            id: 'm',
            name: 'Big motor',
            loadKind: LoadKind.motor,
            loadW: 30000,
            cosPhi: 0.85,
            length: Length(10),
          ),
        ],
      );
      final r = computePanel(profile, big);
      final sys = ElectricalSystemResult(
        projectId: 'p',
        panels: {'P': r},
        order: const ['P'],
        totalDemandW: r.demandW,
        supply: SupplySummary(
          connectedW: r.connectedW,
          demandW: r.demandW,
          demandVa: const ApparentPower(0),
          system: big.system,
          voltage: big.voltage,
        ),
        earthing: computeEarthing(profile,
            system: EarthingSystem.tnCs, supplyPeMm2: 16),
        warnings: const [],
      );
      final bom = buildBom(sys);
      final skun = bom.lines
          .where((l) => l.description.startsWith('Cable lug'))
          .toList();
      expect(skun, isNotEmpty);
      expect(skun.first.qty, 10); // 5 conductors (3L+N+PE) × 2 ends
      // Sanity: the motor cable was indeed >= the 10 mm² skun threshold.
      expect(r.circuits.single.cable.csaMm2, greaterThanOrEqualTo(10));
    });
  });

  // ── (2) Breaker SKU match (class/poles/curve/rating ranking) ───────────────
  group('(2) matchBreakerSku', () {
    // Seed-catalogue facts: A9F44110 = MCB 1P C10; A9F44116 = MCB 1P C16;
    //                       A9F44316 = MCB 3P C16.
    test('1P C-curve, need 10 A → smallest covering 1P C = A9F44110', () {
      const need = BreakerResult(
        ratingA: Current(10),
        deviceClass: BreakerClass.mcb,
        curve: BreakerCurve.c,
      );
      // Candidates ≥ 10 A include 1P {10,16,20,…} and 3P {16,25,…}. A 1P match
      // (poles ok, penalty 0) beats a 3P match (penalty 100) even though both
      // exist at 16 A; among 1P the smallest covering rating is 10 A.
      expect(matchBreakerSku(need, seedCatalog, poles: 1), 'A9F44110');
    });

    test('3P need 16 A → 3-pole part wins over a smaller 1-pole', () {
      const need = BreakerResult(
        ratingA: Current(16),
        deviceClass: BreakerClass.mcb,
        curve: BreakerCurve.c,
      );
      // A 1P 16 A (A9F44116) covers the rating but mismatches poles (penalty
      // 100); the 3P 16 A (A9F44316) has penalty 0 → it wins.
      expect(matchBreakerSku(need, seedCatalog, poles: 3), 'A9F44316');
    });

    test('MCCB need 120 A 3P → smallest covering MCCB = NSX160F (LV430630)', () {
      const need = BreakerResult(
        ratingA: Current(120),
        deviceClass: BreakerClass.mccb,
        curve: BreakerCurve.c,
      );
      // MCCBs covering 120 A: NSX160F 160 A, NSX250F 250 A. Smallest = 160 A.
      // (The MCBs top out at 63 A so they never cover 120 A anyway.)
      expect(matchBreakerSku(need, seedCatalog, poles: 3), 'LV430630');
    });

    test('cable section match prefers the construction type', () {
      // Need 2.5 mm² NYM → NYM-2.5 (same type) over the NYY ladder.
      expect(matchCableSku(2.5, seedCatalog, cableType: 'NYM'), 'NYM-2.5');
      // Need 6 mm² with no NYM at 6 mm² → falls back to section-only = NYY-6.
      expect(matchCableSku(6, seedCatalog, cableType: 'NYM'), 'NYY-6');
    });
  });

  // ── (3) Cost = Σ qty × price; unmatched flagged ────────────────────────────
  group('(3) estimateCost', () {
    // A hand-built BOM (so the totals are unambiguous):
    //   2 × A9F44116 (breaker)  @ 90 000  → 180 000
    //   30 × NYY-4   (cable, m) @  12 000 → 360 000
    //   1 × <no sku>  enclosure            → unmatched (0)
    const bom = Bom([
      BomLine(
          description: 'MCB 16A C',
          qty: 2,
          category: PartCategory.breaker,
          sku: 'A9F44116'),
      BomLine(
          description: 'Cable NYY 4',
          qty: 30,
          category: PartCategory.cable,
          sku: 'NYY-4'),
      BomLine(
          description: 'Enclosure', qty: 1, category: PartCategory.enclosure),
    ]);
    final prices = {'A9F44116': 90000.0, 'NYY-4': 12000.0};

    test('grand total = 2·90 000 + 30·12 000 = 540 000', () {
      final est = estimateCost(bom, prices);
      // 180 000 + 360 000 = 540 000.
      expect(est.grandTotal, closeTo(540000, 1e-9));
      expect(est.unmatchedCount, 1); // the enclosure has no sku/price
    });

    test('per-line totals + matched flags', () {
      final est = estimateCost(bom, prices);
      final breaker = est.lines[0];
      expect(breaker.matched, isTrue);
      expect(breaker.lineTotal, closeTo(180000, 1e-9));
      final enclosure = est.lines[2];
      expect(enclosure.matched, isFalse);
      expect(enclosure.lineTotal, isNull);
    });
  });

  // ── (4) Quotation sell price from material + labour + markups ──────────────
  group('(4) buildQuotation', () {
    test('explicit labour + markups → derived sell price', () {
      // Material = 540 000 (from the cost estimate above).
      // Labour   = 4 h × 100 000 = 400 000.
      // Prime    = 540 000 + 400 000 = 940 000.
      // Overhead = 10 % · 940 000   =  94 000.
      // Conting. =  5 % · 940 000   =  47 000.
      // marginBase = 940 000 + 94 000 + 47 000 = 1 081 000.
      // Margin 20 % is a TRUE margin: sell = base/(1−0.20) = 1 081 000/0.8
      //          = 1 351 250.  margin = 1 351 250 − 1 081 000 = 270 250.
      const material = CostEstimate(
        lines: [],
        grandTotal: 540000,
        currency: 'IDR',
        unmatchedCount: 0,
      );
      final q = buildQuotation(
        material,
        labourHours: 4,
        labourRate: 100000,
        overheadPct: 10,
        contingencyPct: 5,
        marginPct: 20,
      );
      expect(q.materialSubtotal, closeTo(540000, 1e-9));
      expect(q.labourSubtotal, closeTo(400000, 1e-9));
      expect(q.overhead, closeTo(94000, 1e-9));
      expect(q.contingency, closeTo(47000, 1e-9));
      expect(q.marginBase, closeTo(1081000, 1e-9));
      expect(q.margin, closeTo(270250, 1e-9));
      expect(q.grandTotal, closeTo(1351250, 1e-9));
      expect(q.currency, 'IDR');
    });

    test('zero labour + zero markups ⇒ grand total = material', () {
      const material = CostEstimate(
        lines: [],
        grandTotal: 250000,
        currency: 'IDR',
        unmatchedCount: 0,
      );
      final q = buildQuotation(
        material,
        labourHours: 0,
        labourRate: 0,
        overheadPct: 0,
        contingencyPct: 0,
        marginPct: 0,
      );
      expect(q.grandTotal, closeTo(250000, 1e-9));
    });

    test('labour derived from the BOM via the labour standard', () {
      // BOM: 1 breaker (0.3 h) + 1 cable (0.2 h) + 1 enclosure (4.0 h)
      //   = 4.5 h.  At 100 000/h → labour = 450 000.
      const bom = Bom([
        BomLine(description: 'b', qty: 1, category: PartCategory.breaker),
        BomLine(description: 'c', qty: 1, category: PartCategory.cable),
        BomLine(description: 'e', qty: 1, category: PartCategory.enclosure),
      ]);
      expect(labourHoursForBom(bom), closeTo(4.5, 1e-9));
      const material = CostEstimate(
        lines: [],
        grandTotal: 0,
        currency: 'IDR',
        unmatchedCount: 0,
      );
      final q = buildQuotation(
        material,
        bom: bom,
        labourRate: 100000,
        overheadPct: 0,
        contingencyPct: 0,
        marginPct: 0,
      );
      expect(q.labourHours, closeTo(4.5, 1e-9));
      expect(q.labourSubtotal, closeTo(450000, 1e-9));
      expect(q.grandTotal, closeTo(450000, 1e-9));
    });
  });

  // ── (5) Full pipeline: buildBom(fullCatalog) → estimateCost → buildQuotation ─
  //
  // Wire the whole commercial chain over a real sized system + the FULL
  // catalogue (the Commercial workspace's exact path), asserting the boundary
  // behaviours the UI relies on.
  group('(5) full commercial pipeline', () {
    // A small 3φ panel with a mix of ways so the BOM has several lines.
    const panel = ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
          id: 'c1',
          name: 'Lighting',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 2400,
          cosPhi: 0.9,
          length: Length(20),
        ),
        ElectricalCircuit(
          id: 'c2',
          name: 'Sockets',
          loadKind: LoadKind.socket,
          loadW: 3600,
          cosPhi: 0.9,
          length: Length(18),
        ),
        ElectricalCircuit(
          id: 'c3',
          name: 'HVAC',
          loadKind: LoadKind.hvac,
          loadW: 9000,
          cosPhi: 0.85,
          length: Length(25),
        ),
      ],
    );

    ElectricalSystemResult sized() {
      final r = computePanel(profile, panel);
      return ElectricalSystemResult(
        projectId: 'p',
        panels: {'MDP': r},
        order: const ['MDP'],
        totalDemandW: r.demandW,
        supply: SupplySummary(
          connectedW: r.connectedW,
          demandW: r.demandW,
          demandVa: const ApparentPower(0),
          system: panel.system,
          voltage: panel.voltage,
        ),
        earthing: computeEarthing(profile,
            system: EarthingSystem.tnCs, supplyPeMm2: 16),
        warnings: const [],
      );
    }

    test('empty pricelist → grandTotal 0 and EVERY line unmatched', () {
      final bom = buildBom(sized(), parts: fullCatalog());
      expect(bom.lines, isNotEmpty);

      final cost = estimateCost(bom, const {});
      expect(cost.grandTotal, 0);
      // No price ⇒ no line can be matched.
      expect(cost.unmatchedCount, bom.lines.length);
      expect(cost.lines.every((l) => !l.matched), isTrue);

      // A quotation off a zero material base with the engine default markups is
      // still zero (every percentage applies to a zero prime cost).
      final q = buildQuotation(cost, bom: bom, labourRate: 0);
      expect(q.materialSubtotal, 0);
      expect(q.grandTotal, 0);
    });

    test('all-zero markups + zero labour → grandTotal == material subtotal', () {
      final bom = buildBom(sized(), parts: fullCatalog());

      // Price every catalogue-matched line at a flat 1000 so the material
      // subtotal is a known, non-zero figure.
      final priceList = <String, double>{
        for (final l in bom.lines)
          if (l.sku != null) l.sku!: 1000,
      };
      final cost = estimateCost(bom, priceList);
      expect(cost.grandTotal, greaterThan(0));

      final q = buildQuotation(
        cost,
        bom: bom,
        labourHours: 0,
        labourRate: 0,
        overheadPct: 0,
        contingencyPct: 0,
        marginPct: 0,
      );
      expect(q.materialSubtotal, closeTo(cost.grandTotal, 1e-9));
      expect(q.labourSubtotal, 0);
      expect(q.overhead, 0);
      expect(q.contingency, 0);
      expect(q.margin, 0);
      expect(q.grandTotal, closeTo(cost.grandTotal, 1e-9));
    });

    test('margin == sell − base (true gross margin)', () {
      final bom = buildBom(sized(), parts: fullCatalog());
      final priceList = <String, double>{
        for (final l in bom.lines)
          if (l.sku != null) l.sku!: 1000,
      };
      final cost = estimateCost(bom, priceList);

      final q = buildQuotation(
        cost,
        bom: bom,
        labourHours: 2,
        labourRate: 100000,
        overheadPct: 8,
        contingencyPct: 4,
        marginPct: 18,
      );
      // The defining identity: profit is sell minus the cost base.
      expect(q.margin, closeTo(q.grandTotal - q.marginBase, 1e-6));
      // And the cost base is prime + overhead + contingency.
      final prime = q.materialSubtotal + q.labourSubtotal;
      expect(q.marginBase, closeTo(prime + q.overhead + q.contingency, 1e-6));
    });

    test('exporters render the priced BOM (CSV) + proposal (Markdown)', () {
      final bom = buildBom(sized(), parts: fullCatalog());
      final priceList = <String, double>{
        for (final l in bom.lines)
          if (l.sku != null) l.sku!: 1000,
      };
      final cost = estimateCost(bom, priceList);
      final q = buildQuotation(cost, bom: bom);

      final csv = costEstimateToCsv(cost);
      // Header + one row per line + a trailing subtotal row.
      final csvLines = csv.trim().split('\n');
      expect(csvLines.first, startsWith('qty,category,description'));
      expect(csvLines.length, cost.lines.length + 2);
      expect(csv, contains('Material subtotal'));

      final md = quotationToMarkdown(q, cost, projectName: 'Tower A');
      expect(md, contains('# Electrical proposal — Tower A'));
      expect(md, contains('Grand total'));

      final pl = priceListToCsv(priceList);
      expect(pl.split('\n').first, 'sku,unit_price');
    });
  });
}
