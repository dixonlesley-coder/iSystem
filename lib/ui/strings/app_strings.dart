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

  // Commercial workspace — hub.
  commercialHubTitle,
  commercialHubLead,
  commercialExportBomCsv,
  commercialExportProposalMd,

  // Commercial workspace — electrical BOM.
  commercialBomTitle,
  commercialColQty,
  commercialColPart,
  commercialColBrand,
  commercialColSku,
  commercialColMatch,
  commercialMatched,
  commercialUnmatched,

  // Commercial workspace — pricelist.
  commercialPricelistTitle,
  commercialColUnit,
  commercialColUnitPrice,

  // Commercial workspace — quotation.
  commercialQuotationTitle,
  commercialAllPriced,
  commercialQuoteSettings,
  commercialOverheadPct,
  commercialContingencyPct,
  commercialMarginPct,
  commercialColItem,
  commercialItemMaterial,
  commercialItemOverhead,
  commercialItemContingency,
  commercialItemMargin,
  commercialItemGrandTotal,

  // Commercial workspace — shared table.
  commercialNoItems,

  // Electrical — Export menu.
  electricalExportSld,
  electricalExportSldDxf,
  electricalExportSldPdf,
  electricalExportReport,
  electricalExportReportSub,
  electricalExportPowerOneLine,
  electricalExportPowerOneLineSub,

  // Electrical — Service & Earthing (Fold-1 fields).
  electricalOriginFaultLevel,
  electricalOriginFaultLevelNote,
  electricalBusbarClearingTime,
  electricalBusbarClearingTimeNote,
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

  // Commercial workspace — hub.
  StringKey.commercialHubTitle: 'Commercial',
  StringKey.commercialHubLead:
      'The electrical bill of materials, your pricelist and the '
          'priced proposal. Edit prices below and the quotation updates '
          'live.',
  StringKey.commercialExportBomCsv: 'Export BOM (CSV)',
  StringKey.commercialExportProposalMd: 'Export proposal (Markdown)',

  // Commercial workspace — electrical BOM.
  StringKey.commercialBomTitle: 'Bill of materials',
  StringKey.commercialColQty: 'Qty',
  StringKey.commercialColPart: 'Part',
  StringKey.commercialColBrand: 'Brand',
  StringKey.commercialColSku: 'SKU',
  StringKey.commercialColMatch: 'Match',
  StringKey.commercialMatched: 'matched',
  StringKey.commercialUnmatched: 'unmatched',

  // Commercial workspace — pricelist.
  StringKey.commercialPricelistTitle: 'Pricelist',
  StringKey.commercialColUnit: 'Unit',
  StringKey.commercialColUnitPrice: 'Unit price',

  // Commercial workspace — quotation.
  StringKey.commercialQuotationTitle: 'Quotation',
  StringKey.commercialAllPriced: 'All catalogue-matched lines are priced.',
  StringKey.commercialQuoteSettings: 'Quote settings',
  StringKey.commercialOverheadPct: 'Overhead (%)',
  StringKey.commercialContingencyPct: 'Contingency (%)',
  StringKey.commercialMarginPct: 'Margin (%)',
  StringKey.commercialColItem: 'Item',
  StringKey.commercialItemMaterial: 'Material',
  StringKey.commercialItemOverhead: 'Overhead',
  StringKey.commercialItemContingency: 'Contingency',
  StringKey.commercialItemMargin: 'Margin',
  StringKey.commercialItemGrandTotal: 'Grand total',

  // Commercial workspace — shared table.
  StringKey.commercialNoItems: 'No items.',

  // Electrical — Export menu.
  StringKey.electricalExportSld: 'Single-line drawing',
  StringKey.electricalExportSldDxf: 'DXF (CAD)',
  StringKey.electricalExportSldPdf: 'PDF (vector)',
  StringKey.electricalExportReport: 'Calculation report',
  StringKey.electricalExportReportSub: 'Markdown',
  StringKey.electricalExportPowerOneLine: 'Power one-line',
  StringKey.electricalExportPowerOneLineSub: 'DXF (needs energy sources)',

  // Electrical — Service & Earthing (Fold-1 fields).
  StringKey.electricalOriginFaultLevel: 'Origin fault level (kA)',
  StringKey.electricalOriginFaultLevelNote:
      'Prospective 3-phase fault at the supply origin. Drives '
          'Fold-1 busbar short-circuit withstand sizing. Default '
          '16 kA. VERIFY against the PLN / upstream let-through.',
  StringKey.electricalBusbarClearingTime: 'Busbar clearing time (s)',
  StringKey.electricalBusbarClearingTimeNote:
      'Protective-device clearing time for the withstand '
          'thermal check (smaller = less oversize). Default 0.1 s.',
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

  // Commercial workspace — hub.
  StringKey.commercialHubTitle: 'Komersial',
  StringKey.commercialHubLead:
      'Daftar material kelistrikan, daftar harga Anda, dan proposal '
          'berbiaya. Ubah harga di bawah ini dan penawaran akan diperbarui '
          'secara langsung.',
  StringKey.commercialExportBomCsv: 'Ekspor BOM (CSV)',
  StringKey.commercialExportProposalMd: 'Ekspor proposal (Markdown)',

  // Commercial workspace — electrical BOM.
  StringKey.commercialBomTitle: 'Daftar material',
  StringKey.commercialColQty: 'Jml',
  StringKey.commercialColPart: 'Komponen',
  StringKey.commercialColBrand: 'Merek',
  StringKey.commercialColSku: 'SKU',
  StringKey.commercialColMatch: 'Kecocokan',
  StringKey.commercialMatched: 'cocok',
  StringKey.commercialUnmatched: 'tidak cocok',

  // Commercial workspace — pricelist.
  StringKey.commercialPricelistTitle: 'Daftar Harga',
  StringKey.commercialColUnit: 'Satuan',
  StringKey.commercialColUnitPrice: 'Harga satuan',

  // Commercial workspace — quotation.
  StringKey.commercialQuotationTitle: 'Penawaran',
  StringKey.commercialAllPriced: 'Semua baris yang cocok katalog telah diberi harga.',
  StringKey.commercialQuoteSettings: 'Pengaturan penawaran',
  StringKey.commercialOverheadPct: 'Overhead (%)',
  StringKey.commercialContingencyPct: 'Kontingensi (%)',
  StringKey.commercialMarginPct: 'Margin (%)',
  StringKey.commercialColItem: 'Item',
  StringKey.commercialItemMaterial: 'Material',
  StringKey.commercialItemOverhead: 'Overhead',
  StringKey.commercialItemContingency: 'Kontingensi',
  StringKey.commercialItemMargin: 'Margin',
  StringKey.commercialItemGrandTotal: 'Total keseluruhan',

  // Commercial workspace — shared table.
  StringKey.commercialNoItems: 'Tidak ada item.',

  // Electrical — Export menu.
  StringKey.electricalExportSld: 'Gambar satu-garis',
  StringKey.electricalExportSldDxf: 'DXF (CAD)',
  StringKey.electricalExportSldPdf: 'PDF (vektor)',
  StringKey.electricalExportReport: 'Laporan perhitungan',
  StringKey.electricalExportReportSub: 'Markdown',
  StringKey.electricalExportPowerOneLine: 'Diagram daya satu-garis',
  StringKey.electricalExportPowerOneLineSub: 'DXF (perlu sumber energi)',

  // Electrical — Service & Earthing (Fold-1 fields).
  StringKey.electricalOriginFaultLevel: 'Tingkat gangguan sumber (kA)',
  StringKey.electricalOriginFaultLevelNote:
      'Gangguan 3-fasa prospektif di titik asal suplai. Menjadi dasar '
          'pengukuran ketahanan hubung-singkat busbar Fold-1. Default '
          '16 kA. VERIFIKASI terhadap let-through PLN / hulu.',
  StringKey.electricalBusbarClearingTime: 'Waktu pemutusan busbar (s)',
  StringKey.electricalBusbarClearingTimeNote:
      'Waktu pemutusan perangkat proteksi untuk pemeriksaan ketahanan '
          'termal (lebih kecil = lebih sedikit pembesaran). Default 0,1 s.',
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
