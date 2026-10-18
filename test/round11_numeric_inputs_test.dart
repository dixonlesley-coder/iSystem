/// ROUND 11 (2026-10-18) — numeric-input robustness. `double.tryParse`
/// accepts 'NaN', 'Infinity' and '1e999' (→ Infinity), NaN fails every
/// comparison, and a non-finite double makes `jsonEncode` throw — so one bad
/// field used to make the whole project unsaveable. Pinned here:
///   * the shared field gate rejects non-finite input and enforces each bound
///     on its own (a min-only field used to accept negatives);
///   * the store setters never persist a non-finite / negative value;
///   * the scale + money formatters never throw on a non-finite value.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/commercial/money_input.dart';
import 'package:mechx/ui/electrical/electrical_controls.dart';
import 'package:mechx/ui/format/scale_format.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

Widget _host(Widget child) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 260, child: child),
          ),
        ),
      ),
    );

Future<void> _commit(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(EditableText), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

void main() {
  // ── the pure field gate ────────────────────────────────────────────────────
  group('ElectricalNumInput.rejectionFor', () {
    test('non-finite values are rejected whatever the bounds', () {
      for (final v in [double.nan, double.infinity, double.negativeInfinity]) {
        expect(ElectricalNumInput.rejectionFor(v), 'Enter a finite number');
        expect(ElectricalNumInput.rejectionFor(v, min: 0, max: 1),
            'Enter a finite number');
      }
      // '1e999' parses to Infinity.
      expect(double.parse('1e999'), double.infinity);
    });

    test('each bound is enforced on its own', () {
      expect(ElectricalNumInput.rejectionFor(-5, min: 0),
          'Enter a value of at least 0');
      expect(ElectricalNumInput.rejectionFor(0, min: 0), isNull);
      expect(ElectricalNumInput.rejectionFor(150, max: 100),
          'Enter a value of at most 100');
      expect(ElectricalNumInput.rejectionFor(0.05, min: 0.1, max: 1),
          'Enter a value between 0.1 and 1');
      expect(ElectricalNumInput.rejectionFor(0.75, min: 0.1, max: 1), isNull);
    });

    // Property: over a seeded mix of finite, non-finite and boundary values and
    // random optional bounds, the gate passes EXACTLY the finite values inside
    // every bound that is set.
    test('property: null ⇔ finite ∧ (min unset ∨ v ≥ min) ∧ (max unset ∨ v ≤ max)',
        () {
      final rnd = math.Random(20261018);
      final specials = [double.nan, double.infinity, double.negativeInfinity];
      for (var i = 0; i < 2000; i++) {
        final v = rnd.nextInt(10) == 0
            ? specials[rnd.nextInt(3)]
            : (rnd.nextDouble() - 0.5) * 2000;
        final min = rnd.nextBool() ? (rnd.nextDouble() - 0.5) * 1000 : null;
        final max = rnd.nextBool() ? (rnd.nextDouble() - 0.2) * 1000 : null;
        final ok = v.isFinite &&
            (min == null || v >= min) &&
            (max == null || v <= max);
        expect(ElectricalNumInput.rejectionFor(v, min: min, max: max) == null,
            ok,
            reason: 'v=$v min=$min max=$max');
      }
    });
  });

  // ── the widgets ────────────────────────────────────────────────────────────
  group('ElectricalNumInput widget', () {
    for (final bad in ['NaN', 'Infinity', '-Infinity', '1e999']) {
      testWidgets('"$bad" is rejected with a field error, never committed',
          (tester) async {
        setDesktopSurface(tester);
        final commits = <double>[];
        await tester.pumpWidget(
            _host(ElectricalNumInput(value: 0.1, onChanged: commits.add)));
        await _commit(tester, bad);
        expect(commits, isEmpty);
        expect(find.text('Enter a finite number'), findsOneWidget);
      });
    }

    testWidgets('a min-only field rejects a negative (was accepted)',
        (tester) async {
      setDesktopSurface(tester);
      final commits = <double>[];
      await tester.pumpWidget(_host(
          ElectricalNumInput(value: 100, min: 0, onChanged: commits.add)));
      await _commit(tester, '-5000');
      expect(commits, isEmpty);
      expect(find.text('Enter a value of at least 0'), findsOneWidget);
      await _commit(tester, '2500');
      expect(commits, [2500]);
    });

    testWidgets('a non-finite VALUE renders empty instead of throwing',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(_host(ElectricalNumInput(
          value: double.infinity, onChanged: (_) {})));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_host(ElectricalNumInput(
          value: double.nan, onChanged: (_) {}, enabled: false)));
      expect(tester.takeException(), isNull);
    });
  });

  group('ElectricalOptionalNumInput widget', () {
    testWidgets('"Infinity" is rejected with a field error', (tester) async {
      setDesktopSurface(tester);
      final commits = <double?>[];
      await tester.pumpWidget(_host(
          ElectricalOptionalNumInput(value: null, onChanged: commits.add)));
      await _commit(tester, 'Infinity');
      expect(commits, isEmpty);
      expect(find.text('Enter a finite number'), findsOneWidget);
      await _commit(tester, '25');
      expect(commits, [25]);
    });
  });

  // ── the store gates ────────────────────────────────────────────────────────
  group('ElectricalProjectController never persists a non-finite value', () {
    ProviderContainer seeded() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(electricalProjectProvider.notifier)
          .setProject(sampleElectricalProject());
      return c;
    }

    test('the five Supply setters ignore NaN / Infinity', () {
      final c = seeded();
      final ctl = c.read(electricalProjectProvider.notifier);
      final before = jsonEncode(c.read(electricalProjectProvider).toJson());
      ctl.setBusbarClearingTime(double.nan);
      ctl.setBusbarClearingTime(double.infinity);
      ctl.setOriginFaultLevel(const Current(double.infinity));
      ctl.setOriginFaultLevel(const Current(double.nan));
      ctl.setSupplyCapacityVa(const ApparentPower(double.infinity));
      ctl.setTransformerKva(const ApparentPower(double.nan));
      ctl.setCapacitorBankKvar(double.nan);
      ctl.setGeneratorKva(const ApparentPower(double.infinity));
      ctl.setBattery(const BatterySource(autonomyHours: double.nan));
      ctl.setSolar(
          const SolarSource(panelWp: 550, panels: 10, dcAcRatio: double.nan));
      // Unchanged — and therefore still encodable.
      expect(jsonEncode(c.read(electricalProjectProvider).toJson()), before);
    });

    test('the project still saves (encodes) after hostile input', () {
      final c = seeded();
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setBusbarClearingTime(double.nan);
      ctl.setOriginFaultLevel(const Current(double.infinity));
      expect(() => buildDocument(c.read).encode(), returnsNormally);
    });

    test('setCircuit rejects negative / non-finite loads, lengths and cos phi',
        () {
      final c = seeded();
      final ctl = c.read(electricalProjectProvider.notifier);
      final panel = c.read(electricalProjectProvider).panels.first;
      final way = panel.circuits.first;
      String snapshot() => jsonEncode(c.read(electricalProjectProvider).toJson());
      final before = snapshot();
      ctl.setCircuit(panel.id, way.id, loadW: -5000);
      ctl.setCircuit(panel.id, way.id, motorKw: -3);
      ctl.setCircuit(panel.id, way.id, length: const Length(-50));
      ctl.setCircuit(panel.id, way.id, length: const Length(0));
      ctl.setCircuit(panel.id, way.id, cosPhi: 0);
      ctl.setCircuit(panel.id, way.id, cosPhi: 1.2);
      expect(snapshot(), before);
      // NaN / Infinity used to throw out of the jsonEncode no-op guard.
      expect(() => ctl.setCircuit(panel.id, way.id, loadW: double.nan),
          returnsNormally);
      expect(
          () => ctl.setCircuit(panel.id, way.id,
              breakerOverrideA: const Current(double.infinity)),
          returnsNormally);
      expect(snapshot(), before);
      // A valid edit still lands.
      ctl.setCircuit(panel.id, way.id, loadW: 1234);
      final after = c
          .read(electricalProjectProvider)
          .panels
          .first
          .circuits
          .firstWhere((x) => x.id == way.id);
      expect(after.loadW, 1234);
    });

    // Property: the pure gate accepts EXACTLY the physically meaningful values.
    test('property: isValidCircuitEdit over seeded values', () {
      final rnd = math.Random(181018);
      double pick() => switch (rnd.nextInt(8)) {
            0 => double.nan,
            1 => double.infinity,
            2 => 0,
            _ => (rnd.nextDouble() - 0.3) * 100,
          };
      for (var i = 0; i < 1000; i++) {
        final w = pick(), len = pick(), cos = pick();
        final ok = w.isFinite &&
            w >= 0 &&
            len.isFinite &&
            len > 0 &&
            cos.isFinite &&
            cos > 0 &&
            cos <= 1;
        expect(
            isValidCircuitEdit(loadW: w, length: Length(len), cosPhi: cos), ok,
            reason: 'W=$w L=$len cos=$cos');
      }
      expect(isValidCircuitEdit(), isTrue); // nothing supplied ⇒ keep
    });
  });

  // ── formatters ─────────────────────────────────────────────────────────────
  group('scale + money formatters never throw on a non-finite value', () {
    test('formatScaleReadout / formatScaleShort read the dash', () {
      for (final mpp in [double.nan, double.infinity, -1.0, 0.0, 1e-320]) {
        expect(isFormattableScale(mpp), isFalse, reason: '$mpp');
        expect(formatScaleReadout(mpp, isPdf: true), '—');
        expect(formatScaleReadout(mpp, isPdf: false), '—');
        expect(formatScaleShort(mpp, isPdf: true), '—');
      }
      // A real scale is unchanged: 1:100 on a PDF ⇒ 100 × 0.0254 / 72.
      final mpp = metersPerPixelForPdfScale(100);
      expect(formatScaleShort(mpp, isPdf: true), '1 : 100');
    });

    test('property: any finite positive mpp formats without throwing', () {
      final rnd = math.Random(7);
      for (var i = 0; i < 500; i++) {
        final mpp = math.pow(10, -6 + rnd.nextDouble() * 9).toDouble();
        expect(() => formatScaleReadout(mpp, isPdf: rnd.nextBool()),
            returnsNormally);
      }
    });

    test('parseMoneyInput rejects a digit run that parses to Infinity', () {
      expect(parseMoneyInput('9' * 400, indonesian: true), isNull);
      expect(parseMoneyInput('9' * 400, indonesian: false), isNull);
      expect(parseMoneyInput('1.250', indonesian: true), 1250);
    });
  });
}
