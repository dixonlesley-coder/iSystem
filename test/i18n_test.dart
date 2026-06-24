import 'package:flutter/widgets.dart' show Brightness, SizedBox, Builder;
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/ui/strings/app_strings.dart';

void main() {
  test('every EN key has an ID translation and vice versa (no orphans)', () {
    final en = debugEnStrings().keys.toSet();
    final id = debugIdStrings().keys.toSet();
    expect(id, en,
        reason: 'EN and ID string tables must carry identical key sets');
    // And both cover the whole StringKey enum so nothing is silently untyped.
    expect(en, StringKey.values.toSet());
  });

  test('locale displayName is the human-readable label', () {
    expect(AppLocale.en.displayName, 'English');
    expect(AppLocale.id.displayName, 'Bahasa Indonesia');
  });

  testWidgets('context.strings degrades to EN when no MechXStrings ancestor',
      (tester) async {
    // A widget pumped in isolation (no MechXStrings provider) must still
    // resolve strings — falling back to English rather than throwing.
    late String resolved;
    await tester.pumpWidget(Builder(builder: (context) {
      resolved = context.strings(StringKey.values.first);
      return const SizedBox();
    }));
    expect(resolved, debugEnStrings()[StringKey.values.first]);
  });

  test('AppLocale round-trips through the design settings', () {
    for (final loc in AppLocale.values) {
      final settings = DesignSettings(localeCode: loc.name);
      final restored = DesignSettings.fromJson(settings.toJson());
      expect(restored.localeCode, loc.name);
    }
  });

  test('an unknown / missing locale code decodes to en', () {
    // Missing key (e.g. an older .mechx with no locale) → en.
    expect(DesignSettings.fromJson(const {}).localeCode, 'en');
    // Unknown code → en.
    expect(
      DesignSettings.fromJson(const {'locale': 'fr'}).localeCode,
      'en',
    );
    // Default constructor → en.
    expect(const DesignSettings().localeCode, 'en');
  });

  test('full DesignSettings round-trip preserves a non-default locale', () {
    const s = DesignSettings(localeCode: 'id', brightness: Brightness.light);
    final r = DesignSettings.fromJson(s.toJson());
    expect(r.localeCode, 'id');
    expect(r.brightness, Brightness.light);
  });

  test('a missing ID translation falls back to EN (never blank)', () {
    // Resolution always returns a non-empty string for every key under each
    // locale (the fallback guarantees this even before a key is translated).
    for (final loc in AppLocale.values) {
      final data = MechXStringsData(loc);
      for (final key in StringKey.values) {
        expect(data(key), isNotEmpty, reason: '$key under $loc');
      }
    }
  });

  testWidgets('context.strings resolves a known key under each locale',
      (tester) async {
    for (final entry in {
      AppLocale.en: 'Layout',
      AppLocale.id: 'Tata Letak',
    }.entries) {
      late String seen;
      await tester.pumpWidget(
        MechXStrings(
          data: MechXStringsData(entry.key),
          child: Builder(
            builder: (context) {
              seen = context.strings(StringKey.navLayout);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, entry.value, reason: 'navLayout under ${entry.key}');
    }
  });
}
