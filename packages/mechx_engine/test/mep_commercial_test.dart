/// Unified M+E+P commercial costing tests.
///
/// Expected values are hand-derived from first principles (the arithmetic is in
/// the comments — tests are the spec). The mechanical material sum, labour and
/// the folded M+E+P quotation are computed against fixed inputs; the
/// electrical-only reduction is pinned against the engine's own
/// `buildQuotation` (H10 byte-identical-by-default).
library;

import 'package:mechx_engine/electrical/bom.dart' as elec;
import 'package:mechx_engine/electrical/catalog.dart' show PartCategory;
import 'package:mechx_engine/electrical/costing.dart';
import 'package:mechx_engine/electrical/quotation.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mep_commercial.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // A hand-built mechanical BOM (so the totals are unambiguous):
  //   CW run   DN50  20 m
  //   CW riser DN50  12 m
  //   Supply-air (duct) run DN200  10 m
  final pipes = [
    const BomLine(
      service: ServiceType.coldWater,
      kind: EdgeKind.run,
      diameterMm: 50,
      totalLength: Length(20),
      segmentCount: 2,
    ),
    const BomLine(
      service: ServiceType.coldWater,
      kind: EdgeKind.riser,
      diameterMm: 50,
      totalLength: Length(12),
      segmentCount: 1,
    ),
    const BomLine(
      service: ServiceType.duct,
      kind: EdgeKind.run,
      diameterMm: 200,
      totalLength: Length(10),
      segmentCount: 1,
    ),
  ];
  // Fittings: 4 CW elbows + 2 CW tees at DN50.
  const fittings = [
    FittingLine(
        service: ServiceType.coldWater,
        type: FittingType.elbow,
        diameterMm: 50,
        count: 4),
    FittingLine(
        service: ServiceType.coldWater,
        type: FittingType.tee,
        diameterMm: 50,
        count: 2),
  ];

  // Price everything EXCEPT the CW tee (left unpriced on purpose).
  final prices = <String, double>{
    mechPipeKey(ServiceType.coldWater, EdgeKind.run, 50): 25000,
    mechPipeKey(ServiceType.coldWater, EdgeKind.riser, 50): 25000,
    mechPipeKey(ServiceType.duct, EdgeKind.run, 200): 40000,
    mechFittingKey(ServiceType.coldWater, FittingType.elbow, 50): 15000,
  };

  group('mechanical price keys', () {
    test('are mech-namespaced and stable', () {
      expect(mechPipeKey(ServiceType.coldWater, EdgeKind.run, 50),
          'mech:pipe:coldWater:run:50');
      expect(mechFittingKey(ServiceType.coldWater, FittingType.elbow, 50),
          'mech:fitting:coldWater:elbow:50');
      expect(isMechPriceKey('mech:pipe:coldWater:run:50'), isTrue);
      // An electrical catalogue order code is NOT a mechanical key.
      expect(isMechPriceKey('A9F44116'), isFalse);
    });
  });

  group('estimateMechanicalCost', () {
    test('grand total = Σ priced (pipe per-metre + fittings per-piece)', () {
      final est = estimateMechanicalCost(
        pipes: pipes,
        fittings: fittings,
        priceList: prices,
      );
      // CW run   20 · 25 000 =   500 000
      // CW riser 12 · 25 000 =   300 000
      // duct run 10 · 40 000 =   400 000
      // CW elbow  4 · 15 000 =    60 000
      // CW tee    unpriced   =         0  (counted unpriced)
      //                       = 1 260 000
      expect(est.grandTotal, closeTo(1260000, 1e-6));
      expect(est.unpricedCount, 1);
      expect(est.lines.length, 5); // 3 pipe + 2 fitting

      final tee = est.lines.firstWhere((l) => l.key.contains('fitting') &&
          l.key.contains('tee'));
      expect(tee.priced, isFalse);
      expect(tee.lineTotal, isNull);

      final ductRun = est.lines.firstWhere(
          (l) => l.key == mechPipeKey(ServiceType.duct, EdgeKind.run, 200));
      expect(ductRun.unit, 'm');
      expect(ductRun.lineTotal, closeTo(400000, 1e-6));
      expect(ductRun.description, 'Supply air duct DN200');
    });

    test('empty pricelist → grand total 0 and EVERY line unpriced', () {
      final est = estimateMechanicalCost(
        pipes: pipes,
        fittings: fittings,
        priceList: const {},
      );
      expect(est.grandTotal, 0);
      expect(est.unpricedCount, est.lines.length);
      expect(est.lines.every((l) => !l.priced), isTrue);
    });

    test('cut plan annotates a pipe RUN line with stock bars + waste', () {
      // 20 m of DN50 packed into 4 m bars → 5 whole bars, no waste.
      final cutPlan = [
        PipeCutGroup(
          service: ServiceType.coldWater,
          diameterMm: 50,
          stockLengthM: 4,
          plan: planStockCuts(const [20.0], 4),
        ),
      ];
      final est = estimateMechanicalCost(
        pipes: pipes,
        fittings: fittings,
        priceList: prices,
        cutPlan: cutPlan,
      );
      final run = est.lines.firstWhere(
          (l) => l.key == mechPipeKey(ServiceType.coldWater, EdgeKind.run, 50));
      expect(run.stockBars, 5);
      expect(run.wastePercent, closeTo(0, 1e-9));
      // The riser is excluded from the cut plan → no bars.
      final riser = est.lines.firstWhere((l) =>
          l.key == mechPipeKey(ServiceType.coldWater, EdgeKind.riser, 50));
      expect(riser.stockBars, isNull);
    });
  });

  group('mechanicalLabourHours', () {
    test('pipe rate + duct rate + per-fitting rate', () {
      // CW run   20 · 0.2 = 4.0
      // CW riser 12 · 0.2 = 2.4
      // duct run 10 · 0.3 = 3.0   (air uses the duct rate)
      // elbows    4 · 0.3 = 1.2
      // tees      2 · 0.3 = 0.6
      //                    = 11.2 h
      expect(
        mechanicalLabourHours(pipes: pipes, fittings: fittings),
        closeTo(11.2, 1e-9),
      );
    });
  });

  group('buildMepQuotation', () {
    test('mechanical-only fold: material + labour + markups → sell price', () {
      final mech = estimateMechanicalCost(
        pipes: pipes,
        fittings: fittings,
        priceList: prices,
      );
      const noElec = CostEstimate(
        lines: [],
        grandTotal: 0,
        currency: 'IDR',
        unmatchedCount: 0,
      );
      final q = buildMepQuotation(
        mechanical: mech,
        electrical: noElec,
        mechanicalPipes: pipes,
        mechanicalFittings: fittings,
        labourRate: 100000,
        overheadPct: 10,
        contingencyPct: 5,
        marginPct: 20,
      );
      // Material = 1 260 000; labour 11.2 h · 100 000 = 1 120 000.
      // Prime    = 2 380 000.  Overhead 10% = 238 000; contingency 5% = 119 000.
      // marginBase = 2 737 000. Margin 20% (true): sell = base/0.8 = 3 421 250,
      //   margin = 684 250.
      expect(q.mechanicalMaterial, closeTo(1260000, 1e-6));
      expect(q.electricalMaterial, 0);
      expect(q.materialSubtotal, closeTo(1260000, 1e-6));
      expect(q.labourHours, closeTo(11.2, 1e-9));
      expect(q.labourSubtotal, closeTo(1120000, 1e-6));
      expect(q.overhead, closeTo(238000, 1e-6));
      expect(q.contingency, closeTo(119000, 1e-6));
      expect(q.marginBase, closeTo(2737000, 1e-6));
      expect(q.margin, closeTo(684250, 1e-6));
      expect(q.grandTotal, closeTo(3421250, 1e-6));
      expect(q.unpricedCount, 1);
      expect(q.mechanicalUnpricedCount, 1);
    });

    test('ELECTRICAL-ONLY reduces to buildQuotation (byte-identical, H10)', () {
      // Electrical BOM: 1 breaker (0.3 h) + 1 cable (0.2 h) + 1 enclosure
      //   (4.0 h) = 4.5 h. Material 540 000.
      const eb = elec.Bom([
        elec.BomLine(description: 'b', qty: 1, category: PartCategory.breaker),
        elec.BomLine(description: 'c', qty: 1, category: PartCategory.cable),
        elec.BomLine(description: 'e', qty: 1, category: PartCategory.enclosure),
      ]);
      const elecCost = CostEstimate(
        lines: [],
        grandTotal: 540000,
        currency: 'IDR',
        unmatchedCount: 0,
      );
      const emptyMech = MechCostEstimate(
        lines: [],
        grandTotal: 0,
        currency: 'IDR',
        unpricedCount: 0,
      );

      final ref = buildQuotation(
        elecCost,
        bom: eb,
        labourRate: 100000,
        overheadPct: 10,
        contingencyPct: 5,
        marginPct: 20,
      );
      final mep = buildMepQuotation(
        mechanical: emptyMech,
        electrical: elecCost,
        electricalBom: eb,
        labourRate: 100000,
        overheadPct: 10,
        contingencyPct: 5,
        marginPct: 20,
      );

      // Every roll-up figure matches the electrical-only quotation.
      expect(mep.materialSubtotal, closeTo(ref.materialSubtotal, 1e-9));
      expect(mep.labourHours, closeTo(ref.labourHours, 1e-9));
      expect(mep.labourSubtotal, closeTo(ref.labourSubtotal, 1e-9));
      expect(mep.overhead, closeTo(ref.overhead, 1e-9));
      expect(mep.contingency, closeTo(ref.contingency, 1e-9));
      expect(mep.marginBase, closeTo(ref.marginBase, 1e-9));
      expect(mep.margin, closeTo(ref.margin, 1e-9));
      expect(mep.grandTotal, closeTo(ref.grandTotal, 1e-9));
      // The mechanical side is empty/zero.
      expect(mep.mechanicalMaterial, 0);
      expect(mep.electricalMaterial, closeTo(540000, 1e-9));
    });
  });

  group('exports', () {
    test('CSV lists mechanical + electrical rows + a combined subtotal', () {
      final mech = estimateMechanicalCost(
        pipes: pipes,
        fittings: fittings,
        priceList: prices,
      );
      const elecCost = CostEstimate(
        lines: [
          CostLine(
            line: elec.BomLine(
                description: 'MCB 16A', qty: 2, category: PartCategory.breaker,
                sku: 'A9F44116'),
            matched: true,
            unitPrice: 90000,
            lineTotal: 180000,
          ),
        ],
        grandTotal: 180000,
        currency: 'IDR',
        unmatchedCount: 0,
      );
      final csv = mepBomToCsv(mech, elecCost);
      final rows = csv.trim().split('\n');
      expect(rows.first, startsWith('discipline,qty,unit,category'));
      // 5 mechanical + 1 electrical + 1 subtotal row.
      expect(rows.length, 5 + 1 + 1 + 1); // +1 header
      expect(csv, contains('mechanical,20,m,pipe,Cold water pipe DN50'));
      expect(csv, contains('electrical,2,,breaker,MCB 16A'));
      // Combined subtotal = 1 260 000 + 180 000 = 1 440 000.
      expect(csv, contains('1440000.00'));
      // CSV money stays UNGROUPED + 2 dp (spreadsheet-parseable).
      expect(csv, contains(',500000.00,'));
    });

    test('Markdown proposal folds both disciplines + the roll-up', () {
      final mech = estimateMechanicalCost(
        pipes: pipes,
        fittings: fittings,
        priceList: prices,
      );
      const noElec = CostEstimate(
        lines: [],
        grandTotal: 0,
        currency: 'IDR',
        unmatchedCount: 0,
      );
      final q = buildMepQuotation(
        mechanical: mech,
        electrical: noElec,
        mechanicalPipes: pipes,
        mechanicalFittings: fittings,
      );
      final md = mepQuotationToMarkdown(q,
          mechanical: mech, electrical: noElec, projectName: 'Tower A');
      expect(md, contains('# MEP proposal — Tower A'));
      expect(md, contains('## Mechanical bill of materials'));
      // No electrical lines ⇒ that section is omitted.
      expect(md, isNot(contains('## Electrical bill of materials')));
      expect(md, contains('Mechanical material'));
      expect(md, contains('Grand total'));
      // The unpriced tee is called out in the note.
      expect(md, contains('unpriced'));
    });
  });
}
