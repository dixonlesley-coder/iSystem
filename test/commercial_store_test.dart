/// Commercial store seam: the pricelist + quote-settings edit intents mutate the
/// settings, the derived BOM / cost / quotation providers recompute, and the
/// settings round-trip through the `.mechx` document.
library;

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/commercial_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

void main() {
  group('CommercialController edit intents', () {
    test('setPrice adds / overwrites; clearPrice + blank remove it', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(commercialSettingsProvider.notifier);

      ctrl.setPrice('A9F44116', 90000);
      expect(c.read(commercialSettingsProvider).priceList['A9F44116'], 90000);

      ctrl.setPrice('A9F44116', 95000); // overwrite
      expect(c.read(commercialSettingsProvider).priceList['A9F44116'], 95000);

      ctrl.setPrice('A9F44116', null); // blank → remove
      expect(c.read(commercialSettingsProvider).priceList.containsKey('A9F44116'),
          isFalse);

      ctrl.setPrice('NYY-4', 12000);
      ctrl.clearPrice('NYY-4');
      expect(c.read(commercialSettingsProvider).priceList.containsKey('NYY-4'),
          isFalse);

      // A non-positive price is treated as "no price".
      ctrl.setPrice('NYY-6', 0);
      ctrl.setPrice('NYY-6', -5);
      expect(c.read(commercialSettingsProvider).priceList.containsKey('NYY-6'),
          isFalse);
    });

    test('markup setters clamp into range', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(commercialSettingsProvider.notifier);

      ctrl.setLabourRate(-100); // negative → 0
      ctrl.setOverheadPct(250); // → 100
      ctrl.setContingencyPct(-5); // → 0
      ctrl.setMarginPct(150); // → 99.9

      final s = c.read(commercialSettingsProvider);
      expect(s.labourRatePerHour, 0);
      expect(s.overheadPct, 100);
      expect(s.contingencyPct, 0);
      expect(s.marginPct, 99.9);
    });
  });

  group('derived providers recompute', () {
    // A2: build() starts EMPTY — seed the sample switchboard explicitly so the
    // commercial pipeline has content to derive from.
    void seedSample(ProviderContainer c) => c
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());

    test('the BOM is non-empty for the sample electrical project', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      expect(c.read(electricalBomProvider).lines, isNotEmpty);
    });

    test('a fresh (empty) electrical project prices NOTHING (A2 — the demo '
        'switchboard never leaks into a quotation)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(electricalBomProvider).lines, isEmpty);
      expect(c.read(electricalCostProvider).grandTotal, 0);
    });

    test('empty pricelist → cost 0 and every line unmatched; pricing lifts it',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);

      final bom = c.read(electricalBomProvider);
      final cost0 = c.read(electricalCostProvider);
      expect(cost0.grandTotal, 0);
      expect(cost0.unmatchedCount, bom.lines.length);

      // Price every matched sku → the cost rises and the quotation follows.
      final ctrl = c.read(commercialSettingsProvider.notifier);
      for (final l in bom.lines) {
        if (l.sku != null) ctrl.setPrice(l.sku!, 1000);
      }
      final cost1 = c.read(electricalCostProvider);
      expect(cost1.grandTotal, greaterThan(0));

      final q = c.read(electricalQuotationProvider);
      // Grand total includes the markups, so it is at least the material base.
      expect(q.materialSubtotal, closeTo(cost1.grandTotal, 1e-6));
      expect(q.grandTotal, greaterThanOrEqualTo(q.materialSubtotal));
    });

    test('changing the margin recomputes the quotation grand total', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(commercialSettingsProvider.notifier);
      for (final l in c.read(electricalBomProvider).lines) {
        if (l.sku != null) ctrl.setPrice(l.sku!, 1000);
      }

      ctrl.setMarginPct(0);
      final low = c.read(electricalQuotationProvider).grandTotal;
      ctrl.setMarginPct(30);
      final high = c.read(electricalQuotationProvider).grandTotal;
      expect(high, greaterThan(low));
    });
  });

  group('.mechx round-trip', () {
    test('pricelist + quote settings survive encode/decode', () {
      final doc = ProjectDocument(
        projectName: 'Priced project',
        floors: const [Floor('Ground', Length(4.0))],
        calibrations: const {},
        sheets: const [Sheet(id: 's1', name: 'S1', sizePx: Size(800, 600))],
        network: const Network(),
        settings: const DesignSettings(
          priceList: {'A9F44116': 90000, 'NYY-4': 12000},
          labourRatePerHour: 175000,
          overheadPct: 12,
          contingencyPct: 6,
          marginPct: 22,
        ),
      );

      final back = ProjectDocument.decode(doc.encode()).settings;
      expect(back.priceList['A9F44116'], 90000);
      expect(back.priceList['NYY-4'], 12000);
      expect(back.labourRatePerHour, 175000);
      expect(back.overheadPct, 12);
      expect(back.contingencyPct, 6);
      expect(back.marginPct, 22);
    });

    test('an older file (no commercial keys) decodes to sensible defaults', () {
      // Mimic a v1/early-v2 settings block with none of the commercial keys.
      final settings = DesignSettings.fromJson(const {'occupancy': 'private'});
      expect(settings.priceList, isEmpty);
      expect(settings.labourRatePerHour, 150000);
      expect(settings.overheadPct, 10);
      expect(settings.contingencyPct, 5);
      expect(settings.marginPct, 15);
    });
  });

  group('Commercial workspace', () {
    testWidgets('the BOM, pricelist and quotation render', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      // A2: the sample is no longer auto-seeded — load it explicitly so the
      // BOM/pricelist/quotation have content.
      container
          .read(electricalProjectProvider.notifier)
          .setProject(sampleElectricalProject());
      container.read(shellSectionProvider.notifier).set(ShellSection.commercial);
      await tester.pump();

      expect(find.text('Bill of materials'), findsOneWidget);
      expect(find.text('Pricelist'), findsOneWidget);
      expect(find.text('Quotation'), findsOneWidget);
      expect(find.text('Export BOM (CSV)'), findsOneWidget);
      // The empty-pricelist state lists unmatched lines.
      expect(find.text('unmatched'), findsWidgets);
    });

    testWidgets('both commercial exports route through the shared zero-length '
        'export guard (H3 — block + loadError, no silent write)',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container
          .read(electricalProjectProvider.notifier)
          .setProject(sampleElectricalProject());
      // A run drawn on the UNCALIBRATED demo sheet sizes to ZERO length — the
      // shared export gate must fire before any file dialog.
      container.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [
              NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
              NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
            ], edges: [
              NetEdge(
                  id: 'e1',
                  fromId: 'na',
                  toId: 'nb',
                  service: ServiceType.coldWater),
            ]),
          );
      container.read(shellSectionProvider.notifier).set(ShellSection.commercial);
      await tester.pump();
      expect(container.read(loadErrorProvider), isNull);

      await tester.tap(find.text('Export BOM (CSV)'));
      await tester.pump();
      var err = container.read(loadErrorProvider);
      expect(err, isNotNull);
      expect(err, contains('zero length'));
      expect(err, contains('electrical BOM'));
      // Blocked — no success pill.
      expect(container.read(statusMessageProvider), isNull);

      container.read(loadErrorProvider.notifier).set(null);
      await tester.tap(find.text('Export proposal (Markdown)'));
      await tester.pump();
      err = container.read(loadErrorProvider);
      expect(err, isNotNull);
      expect(err, contains('quotation proposal'));
      expect(container.read(statusMessageProvider), isNull);
    });
  });
}
