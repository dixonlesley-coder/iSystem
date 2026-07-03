/// H10 store seam: the mechanical BOM prices into the SAME pricelist as the
/// electrical catalogue (mech-namespaced keys), and `mepQuotationProvider` folds
/// both disciplines into ONE quotation. An electrical-only project reduces to the
/// electrical-only quotation (byte-identical). Mechanical prices ride the
/// existing persisted `priceList` (no new `.mechx` field).
library;

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/commercial_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mep_commercial.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/units.dart';

void main() {
  // A fixed mechanical BOM injected via provider overrides (so the store test
  // exercises the WIRING, not the network-sizing path the engine tests cover):
  //   CW run   DN50 20 m · supply-air duct run DN200 10 m · 4 CW elbows DN50.
  final mechPipes = [
    const BomLine(
      service: ServiceType.coldWater,
      kind: EdgeKind.run,
      diameterMm: 50,
      totalLength: Length(20),
      segmentCount: 2,
    ),
    const BomLine(
      service: ServiceType.duct,
      kind: EdgeKind.run,
      diameterMm: 200,
      totalLength: Length(10),
      segmentCount: 1,
    ),
  ];
  const mechFittings = [
    FittingLine(
        service: ServiceType.coldWater,
        type: FittingType.elbow,
        diameterMm: 50,
        count: 4),
  ];

  ProviderContainer withMechanicalBom() => ProviderContainer(overrides: [
        bomProvider.overrideWithValue(mechPipes),
        fittingsProvider.overrideWithValue(mechFittings),
        pipeCutPlanProvider.overrideWithValue(const []),
      ]);

  void priceMechanical(ProviderContainer c) {
    final ctrl = c.read(commercialSettingsProvider.notifier);
    ctrl.setPrice(mechPipeKey(ServiceType.coldWater, EdgeKind.run, 50), 25000);
    ctrl.setPrice(mechPipeKey(ServiceType.duct, EdgeKind.run, 200), 40000);
    ctrl.setPrice(
        mechFittingKey(ServiceType.coldWater, FittingType.elbow, 50), 15000);
  }

  group('mechanicalCostProvider', () {
    test('prices the mechanical BOM against the mech-namespaced pricelist', () {
      final c = withMechanicalBom();
      addTearDown(c.dispose);

      // Empty pricelist → nothing priced.
      expect(c.read(mechanicalCostProvider).grandTotal, 0);
      expect(c.read(mechanicalCostProvider).unpricedCount, 3);

      priceMechanical(c);
      final est = c.read(mechanicalCostProvider);
      // 20·25 000 + 10·40 000 + 4·15 000 = 500 000 + 400 000 + 60 000 = 960 000.
      expect(est.grandTotal, closeTo(960000, 1e-6));
      expect(est.unpricedCount, 0);
    });
  });

  group('mepQuotationProvider folds mechanical + electrical', () {
    test('mechanical material lands in the unified total (zero markups)', () {
      final c = withMechanicalBom();
      addTearDown(c.dispose);
      priceMechanical(c);

      // Strip the markups so the grand total equals the bare material.
      final ctrl = c.read(commercialSettingsProvider.notifier);
      ctrl.setLabourRate(0);
      ctrl.setOverheadPct(0);
      ctrl.setContingencyPct(0);
      ctrl.setMarginPct(0);

      final q = c.read(mepQuotationProvider);
      expect(q.mechanicalMaterial, closeTo(960000, 1e-6));
      expect(q.electricalMaterial, 0); // no electrical project seeded
      expect(q.materialSubtotal, closeTo(960000, 1e-6));
      expect(q.grandTotal, closeTo(960000, 1e-6));
      expect(q.unpricedCount, 0);
    });

    test('combined: material subtotal = mechanical + electrical', () {
      final c = withMechanicalBom();
      addTearDown(c.dispose);
      c
          .read(electricalProjectProvider.notifier)
          .setProject(sampleElectricalProject());
      priceMechanical(c);
      // Price every matched electrical sku at a flat 1000.
      final ctrl = c.read(commercialSettingsProvider.notifier);
      for (final l in c.read(electricalBomProvider).lines) {
        if (l.sku != null) ctrl.setPrice(l.sku!, 1000);
      }

      final mech = c.read(mechanicalCostProvider).grandTotal;
      final elec = c.read(electricalCostProvider).grandTotal;
      expect(mech, greaterThan(0));
      expect(elec, greaterThan(0));

      final q = c.read(mepQuotationProvider);
      expect(q.mechanicalMaterial, closeTo(mech, 1e-6));
      expect(q.electricalMaterial, closeTo(elec, 1e-6));
      expect(q.materialSubtotal, closeTo(mech + elec, 1e-6));
    });
  });

  group('electrical-only reduces to the electrical quotation (byte-identical)',
      () {
    test('no mechanical BOM ⇒ MEP grand total == electrical grand total', () {
      // A plain container (no mechanical sizing) — bomProvider is empty.
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c
          .read(electricalProjectProvider.notifier)
          .setProject(sampleElectricalProject());
      final ctrl = c.read(commercialSettingsProvider.notifier);
      for (final l in c.read(electricalBomProvider).lines) {
        if (l.sku != null) ctrl.setPrice(l.sku!, 1000);
      }

      expect(c.read(mechanicalCostProvider).lines, isEmpty);
      final mep = c.read(mepQuotationProvider);
      final elec = c.read(electricalQuotationProvider);
      expect(mep.mechanicalMaterial, 0);
      expect(mep.materialSubtotal, closeTo(elec.materialSubtotal, 1e-9));
      expect(mep.labourSubtotal, closeTo(elec.labourSubtotal, 1e-9));
      expect(mep.overhead, closeTo(elec.overhead, 1e-9));
      expect(mep.margin, closeTo(elec.margin, 1e-9));
      expect(mep.grandTotal, closeTo(elec.grandTotal, 1e-9));
    });
  });

  group('.mechx persistence', () {
    test('a mechanical price rides the existing priceList (no version bump)', () {
      final key = mechPipeKey(ServiceType.coldWater, EdgeKind.run, 50);
      final doc = ProjectDocument(
        projectName: 'Priced M+E+P',
        floors: const [Floor('Ground', Length(4.0))],
        calibrations: const {},
        sheets: const [Sheet(id: 's1', name: 'S1', sizePx: Size(800, 600))],
        network: const Network(),
        settings: DesignSettings(
          priceList: {key: 25000, 'A9F44116': 90000},
        ),
      );

      final back = ProjectDocument.decode(doc.encode()).settings;
      // Both the mechanical key and the electrical SKU survive in one map.
      expect(back.priceList[key], 25000);
      expect(back.priceList['A9F44116'], 90000);
    });
  });
}
