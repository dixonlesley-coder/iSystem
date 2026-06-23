/// Full multi-brand catalogue (`electrical/catalog.dart` + `catalog_data/`) tests.
///
/// The dataset is ported VERBATIM from PanelMaker (ref
/// 8436cca3f471000eb86fffe520bc9c46e7b69e22): each brand's JSON is embedded as a
/// raw `const String` and parsed at load. These tests assert STRUCTURAL
/// invariants only (nothing hand-derived/random): every row validates, SKUs are
/// globally unique across all brands, the count is in the expected ballpark,
/// each declared brand contributes parts, no prices leaked into the dataset, and
/// the matchers still resolve a representative breaker + cable against the full
/// catalogue. Mirrors PanelMaker's catalogue test gate (`CATALOG_ISSUES` empty +
/// globally-unique SKUs).
library;

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('full multi-brand catalogue', () {
    final parts = fullCatalog();

    test('no validation issues (a bad row can never be committed)', () {
      // Mirrors PanelMaker asserting CATALOG_ISSUES is empty.
      expect(catalogIssues, isEmpty,
          reason: catalogIssues.map((i) => i.toString()).join('\n'));
    });

    test('every part has the required fields and a known category', () {
      const enumValues = {
        PartCategory.breaker,
        PartCategory.cable,
        PartCategory.rcd,
        PartCategory.busbar,
        PartCategory.enclosure,
        PartCategory.accessory,
      };
      for (final p in parts) {
        expect(p.sku.trim(), isNotEmpty, reason: 'empty sku');
        expect(p.model.trim(), isNotEmpty, reason: '${p.sku} empty model');
        expect(p.manufacturer.trim(), isNotEmpty, reason: '${p.sku} no brand');
        expect(enumValues.contains(p.category), isTrue,
            reason: '${p.sku} bad enum category');
        // The original PanelMaker category string is preserved + still known.
        final original = p.attributes['partCategory'];
        expect(original, isA<String>(), reason: '${p.sku} no partCategory');
        expect(knownPartCategories.contains(original), isTrue,
            reason: '${p.sku} unknown partCategory "$original"');
      }
    });

    test('SKUs are globally unique across every brand', () {
      final seen = <String>{};
      final dups = <String>[];
      for (final p in parts) {
        if (!seen.add(p.sku)) dups.add(p.sku);
      }
      expect(dups, isEmpty, reason: 'duplicate SKUs: $dups');
    });

    test('total part count is in the expected ballpark (report exact)', () {
      // PanelMaker's CLAUDE.md said "~492"; the pinned ref has grown to 534.
      // ignore: avoid_print
      print('Full catalogue: ${parts.length} parts across '
          '${catalogBrands.length} brands.');
      expect(parts.length, greaterThanOrEqualTo(480));
      // De-dup must not silently drop the bulk of the dataset.
      expect(parts.length, lessThanOrEqualTo(600));
    });

    test('exact per-brand contribution (matches the ported datasets)', () {
      final byBrand = <String, int>{};
      for (final p in parts) {
        byBrand[p.manufacturer] = (byBrand[p.manufacturer] ?? 0) + 1;
      }
      // ignore: avoid_print
      print('Per-brand: $byBrand');
      // Counts hand-verified against the PanelMaker JSON at the pinned ref.
      expect(byBrand['Schneider'], 139);
      expect(byBrand['Mitsubishi Electric'], 63);
      expect(byBrand['LS Electric'], 42);
      expect(byBrand['ABB'], 69);
      expect(byBrand['Legrand'], 92);
      expect(byBrand['Chint'], 71);
      expect(byBrand['Generic'], 58); // generic cable ladder
      expect(parts.length, 534);
    });

    test('every declared brand contributes parts', () {
      final present = parts.map((p) => p.manufacturer).toSet();
      for (final brand in catalogBrands) {
        expect(present.contains(brand), isTrue,
            reason: 'brand "$brand" contributed no parts');
      }
      expect(catalogBrands, [
        'Schneider',
        'Mitsubishi Electric',
        'LS Electric',
        'ABB',
        'Legrand',
        'Chint',
        'Generic',
      ]);
    });

    test('prices stay out of the catalogue (price-free dataset)', () {
      for (final p in parts) {
        expect(p.attributes.containsKey('priceIdr'), isFalse,
            reason: '${p.sku} carries a price — must route to the pricelist');
        expect(p.attributes.containsKey('price'), isFalse);
      }
    });

    test('the dataset has plenty of breakers and the generic cable ladder', () {
      final breakers = parts.where((p) => p.category == PartCategory.breaker);
      final cables = parts.where((p) => p.category == PartCategory.cable);
      expect(breakers.length, greaterThan(250));
      expect(cables.length, greaterThanOrEqualTo(58));
      // Generic cables stay branded 'Generic' so a brand filter keeps them.
      expect(cables.every((p) => p.manufacturer == 'Generic'), isTrue);
    });

    test('partsForBrand keeps the brand + generic cables only', () {
      final abb = partsForBrand(parts, 'ABB');
      expect(abb, isNotEmpty);
      expect(
          abb.every((p) => p.manufacturer == 'ABB' || p.manufacturer == 'Generic'),
          isTrue);
      // Generic cables survive the filter (so cable runs still price).
      expect(abb.any((p) => p.manufacturer == 'Generic'), isTrue);
      // A null/empty brand returns everything.
      expect(partsForBrand(parts, null).length, parts.length);
    });
  });

  group('matchers resolve against the full catalogue', () {
    final parts = fullCatalog();

    test('a representative MCB resolves to a covering breaker SKU', () {
      const need = BreakerResult(
        ratingA: Current(16),
        deviceClass: BreakerClass.mcb,
        curve: BreakerCurve.c,
      );
      final sku = matchBreakerSku(need, parts, poles: 1);
      expect(sku, isNotNull);
      final part = parts.firstWhere((p) => p.sku == sku);
      expect(part.category, PartCategory.breaker);
      expect(part.ratingA, isNotNull);
      expect(part.ratingA! >= 16, isTrue);
    });

    test('a representative cable section resolves to a covering cable SKU', () {
      final sku = matchCableSku(4, parts, cableType: 'NYY');
      expect(sku, isNotNull);
      final part = parts.firstWhere((p) => p.sku == sku);
      expect(part.category, PartCategory.cable);
      expect(part.cableType, 'NYY');
      expect(part.csaMm2! >= 4, isTrue);
    });
  });
}
