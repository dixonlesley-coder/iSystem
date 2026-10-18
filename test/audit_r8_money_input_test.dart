/// Audit round 8 costing-3 — locale-aware money / rate input.
///
/// The issued quotation notation is Indonesian (`1.181.250,00`), so a typed
/// `12.500` is twelve thousand five hundred rupiah, and `1.250.000` must never
/// silently clear a price.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/commercial/commercial_table.dart';
import 'package:mechx/ui/commercial/money_input.dart';
import 'package:mechx_engine/report/number_format.dart' as engine;

void main() {
  group('parseMoneyInput — Indonesian locale', () {
    double? id(String s) => parseMoneyInput(s, indonesian: true);
    test('the finding\'s probes', () {
      expect(id('12.500'), 12500); // was 12.5 (1000× low)
      expect(id('12.500,50'), 12500.5); // was 12.5005
      expect(id('1.250.000'), 1250000); // was null ⇒ price deleted
      expect(id('12500'), 12500);
      expect(id('150.000'), 150000); // labour rate, was 150 IDR/h
    });
    test('decimal comma and malformed input', () {
      expect(id('12,5'), 12.5);
      expect(id('0,25'), 0.25);
      expect(id('12.50'), 12.5); // 2 digits after a single dot ⇒ decimal
      expect(id('1.25.000'), isNull);
      expect(id('abc'), isNull);
      expect(id(''), isNull);
      expect(id('1.250,000.5'), isNull);
    });
    test('mixed separators validate the thousands grouping too', () {
      expect(id('1.25,5'), isNull); // was 125.5
      expect(id('.250,5'), isNull);
      expect(id('1250.000,5'), isNull);
      expect(id('1.250,5'), 1250.5);
      expect(id('12.250.000,75'), 12250000.75);
      expect(id('1250,5'), 1250.5); // no grouping mark at all
      expect(parseMoneyInput('1,25.5', indonesian: false), isNull);
      expect(parseMoneyInput('1,250.5', indonesian: false), 1250.5);
    });
  });

  group('parseMoneyInput — English locale', () {
    double? en(String s) => parseMoneyInput(s, indonesian: false);
    test('grouping comma, decimal point', () {
      expect(en('12,500'), 12500);
      expect(en('1,250,000.50'), 1250000.5);
      expect(en('12.500'), 12.5);
      // Both marks present ⇒ the LAST is the decimal, whatever the locale.
      expect(en('1.250.000,50'), 1250000.5);
    });
  });

  test('property (seeded): the issued notation round-trips through the parser',
      () {
    final rng = math.Random(3);
    for (var i = 0; i < 500; i++) {
      final v = (rng.nextDouble() * 1e9 * 100).roundToDouble() / 100;
      final printed = engine.money(v, dp: 2);
      expect(parseMoneyInput(printed, indonesian: true), closeTo(v, 1e-6),
          reason: printed);
      // The screen now prints exactly the issued notation.
      expect(CommercialFormat.money(v), printed);
    }
  });
}
