import 'package:flutter/widgets.dart';

import '../../store/app_state.dart';

/// Stable, symbolic keys for every localisable UI string. Adding a key here
/// (and to BOTH [_en] and [_id]) is how a literal becomes translatable; the
/// i18n test asserts the two maps carry exactly the same key set.
///
/// EN values are deliberately BYTE-IDENTICAL to the literals they replace so
/// the default rendered text — and therefore the golden screenshots — never
/// moves when a literal is migrated.
enum StringKey {
  // Left navigation rail.
  navGroupDesign,
  navLayout,
  navSchematic,
  navElectrical,
  navReview,
  navCommercial,
  navProjects,
  navPreferences,

  // Preferences screen.
  prefsTitle,
  prefsLead,
  prefsAppearance,
  prefsDark,
  prefsLight,
  prefsSwitchToLight,
  prefsSwitchToDark,
  prefsLanguage,
}

/// English — the source language. These MUST match the inline literals being
/// migrated character-for-character (see the per-key migration notes).
const Map<StringKey, String> _en = {
  StringKey.navGroupDesign: 'DESIGN',
  StringKey.navLayout: 'Layout',
  StringKey.navSchematic: 'Schematic',
  StringKey.navElectrical: 'Electrical',
  StringKey.navReview: 'Review',
  StringKey.navCommercial: 'Commercial',
  StringKey.navProjects: 'Projects',
  StringKey.navPreferences: 'Preferences',
  StringKey.prefsTitle: 'Preferences',
  StringKey.prefsLead: 'App-wide settings. More design defaults will gather here.',
  StringKey.prefsAppearance: 'Appearance',
  StringKey.prefsDark: 'Dark',
  StringKey.prefsLight: 'Light',
  StringKey.prefsSwitchToLight: 'Switch to Light',
  StringKey.prefsSwitchToDark: 'Switch to Dark',
  StringKey.prefsLanguage: 'Language',
};

/// Bahasa Indonesia. Any missing key falls back to [_en] at lookup time, so the
/// app never shows a blank even before a translation lands.
const Map<StringKey, String> _id = {
  StringKey.navGroupDesign: 'DESAIN',
  StringKey.navLayout: 'Tata Letak',
  StringKey.navSchematic: 'Skematik',
  StringKey.navElectrical: 'Listrik',
  StringKey.navReview: 'Tinjauan',
  StringKey.navCommercial: 'Komersial',
  StringKey.navProjects: 'Proyek',
  StringKey.navPreferences: 'Preferensi',
  StringKey.prefsTitle: 'Preferensi',
  StringKey.prefsLead:
      'Pengaturan seluruh aplikasi. Lebih banyak default desain akan terkumpul di sini.',
  StringKey.prefsAppearance: 'Tampilan',
  StringKey.prefsDark: 'Gelap',
  StringKey.prefsLight: 'Terang',
  StringKey.prefsSwitchToLight: 'Beralih ke Terang',
  StringKey.prefsSwitchToDark: 'Beralih ke Gelap',
  StringKey.prefsLanguage: 'Bahasa',
};

/// The active string table for a locale. Exposed for tests; resolves a [key]
/// against the active map, falling back to English for any missing translation.
@immutable
class MechXStringsData {
  final AppLocale locale;
  const MechXStringsData(this.locale);

  Map<StringKey, String> get _map => switch (locale) {
        AppLocale.en => _en,
        AppLocale.id => _id,
      };

  /// Resolve [key]: the active locale's value, or the English fallback so the
  /// app never renders a blank for an as-yet-untranslated key.
  String call(StringKey key) => _map[key] ?? _en[key]!;
}

/// Inherited string table. Mirrors [MechXTheme]: provided once above the shell
/// (keyed off [localeProvider]) and read via the `context.strings` extension.
class MechXStrings extends InheritedWidget {
  final MechXStringsData data;

  const MechXStrings({super.key, required this.data, required super.child});

  static MechXStringsData of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<MechXStrings>();
    assert(widget != null, 'No MechXStrings found in context');
    return widget!.data;
  }

  static MechXStringsData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MechXStrings>()?.data;

  @override
  bool updateShouldNotify(MechXStrings oldWidget) =>
      data.locale != oldWidget.data.locale;
}

/// Ergonomic accessor: `context.strings(StringKey.navLayout)`.
extension MechXStringsContext on BuildContext {
  MechXStringsData get strings => MechXStrings.of(this);
}

/// Test-only view onto the raw maps (so the i18n test can assert key parity and
/// resolution without reaching into private symbols via reflection).
@visibleForTesting
Map<StringKey, String> debugEnStrings() => _en;
@visibleForTesting
Map<StringKey, String> debugIdStrings() => _id;
