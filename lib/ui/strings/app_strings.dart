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
  commercialBomLead, // {lines} {unmatched}

  // Commercial workspace — pricelist.
  commercialPricelistTitle,
  commercialColUnit,
  commercialColUnitPrice,
  commercialPricelistLead, // {priced} {total}

  // Commercial workspace — quotation.
  commercialQuotationTitle,
  commercialAllPriced,
  commercialUnpricedExcluded, // {n}
  commercialLabourRate, // {cur}
  commercialColAmount, // {cur}
  commercialLabourHours, // {hours}
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

  // App shell — top bar.
  shellOpen,
  shellSave,
  shellImportPdf,
  shellDark,
  shellLight,

  // App shell — status bar.
  shellNoSheet,
  shellUncalibrated,
  shellStandardsProvenance,
  shellViewportHints,

  // App shell — banners.
  shellRecoverPrompt,
  shellRestore,
  shellDismiss,

  // App shell — Layout electrical inspector.
  shellElectricalLayer,
  shellElectricalLayerHelp,

  // Schematic / elevation — toolbar + palette.
  schematicAuto,
  schematicEdit,
  schematicRiserService,
  schematicNoNetwork,
  schematicPalette,
  schematicPaletteHelp,
  schematicRiser,
  schematicAddFloorBanner,

  // Schematic / elevation — help popover.
  schematicElevationGuide,
  schematicClose,
  schematicHelp1,
  schematicHelp2,
  schematicHelp3,
  schematicHelp4,
  schematicHelp5,
  schematicHelp6,

  // Inspector — section labels.
  inspectorProject,
  inspectorBuilding,
  inspectorDraw,
  inspectorSizing,
  inspectorNetwork,
  inspectorFire,
  inspectorHvacDucting,
  inspectorSheet,
  inspectorScale,
  inspectorSelection,

  // Inspector — Project section.
  inspectorExportCalcReportMd,
  inspectorExportDrawingDxf,
  inspectorExportDrawingPdf,

  // Inspector — Building section.
  inspectorAddLevel,

  // Inspector — Draw section.
  inspectorSelect,
  inspectorRun,
  inspectorRiser,
  inspectorUndo,
  inspectorRedo,
  inspectorClear,
  inspectorOrtho,
  inspectorDuplicateFloorUp,

  // Inspector — Sizing section.
  inspectorHideSizes,
  inspectorShowSizes,
  inspectorSizingNote,
  inspectorOccupancy,
  inspectorRainfallStorm,

  // Inspector — occupancy labels.
  inspectorOccupancyResidential,
  inspectorOccupancyPublic,
  inspectorOccupancyAssembly,

  // Inspector — Network section.
  inspectorUpfeedPump,
  inspectorRoofTankDownfeed,
  inspectorHideHeatmap,
  inspectorShowHeatmap,
  inspectorExportBomCsv,

  // Inspector — Selection section.
  inspectorDeleteNode,
  inspectorFixtureType,
  inspectorAirTerminalAirflow,
  inspectorClearSizeOverride,
  inspectorEdgeSizeHint,

  // Inspector — Scale section.
  inspectorNotCalibrated,
  inspectorCalibrateScale,
  inspectorReCalibrate,
  inspectorMapsToFloor,

  // Inspector — HVAC section.
  inspectorRound,
  inspectorRectangular,
  inspectorVelocity,
  inspectorEqualFriction,
  inspectorDuctNote,

  // Inspector — node role labels.
  inspectorRoleJunction,
  inspectorRoleFixture,
  inspectorRoleSource,

  // Export — OS save-dialog titles.
  exportTitleCalcReport,
  exportTitleDrawingDxf,
  exportTitleDrawingPdf,
  exportTitleBom,
  exportTitleSldDxf,
  exportTitleSldPdf,
  exportTitlePowerOneLineDxf,
  exportTitleElectricalReport,
  exportTitleElectricalBom,
  exportTitleElectricalProposal,
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
  StringKey.commercialBomLead:
      '{lines} line(s) from the sized electrical model, matched '
          'to the parts catalogue. {unmatched} line(s) have no catalogue match.',

  // Commercial workspace — pricelist.
  StringKey.commercialPricelistTitle: 'Pricelist',
  StringKey.commercialColUnit: 'Unit',
  StringKey.commercialColUnitPrice: 'Unit price',
  StringKey.commercialPricelistLead:
      'Unit prices for the catalogue parts your design uses. Stored with the '
          'project, never in the catalogue. {priced} of {total} priced.',

  // Commercial workspace — quotation.
  StringKey.commercialQuotationTitle: 'Quotation',
  StringKey.commercialAllPriced: 'All catalogue-matched lines are priced.',
  StringKey.commercialUnpricedExcluded:
      '{n} line(s) are unpriced and excluded from the material subtotal.',
  StringKey.commercialLabourRate: 'Labour rate ({cur} / h)',
  StringKey.commercialColAmount: 'Amount ({cur})',
  StringKey.commercialLabourHours: 'Labour ({hours} h)',
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

  // App shell — top bar.
  StringKey.shellOpen: 'Open',
  StringKey.shellSave: 'Save',
  StringKey.shellImportPdf: 'Import PDF',
  StringKey.shellDark: 'Dark',
  StringKey.shellLight: 'Light',

  // App shell — status bar.
  StringKey.shellNoSheet: 'No sheet',
  StringKey.shellUncalibrated: 'Uncalibrated',
  StringKey.shellStandardsProvenance: 'SNI 8153:2015 (draft)',
  StringKey.shellViewportHints: 'scroll zoom · drag pan · F fit · Ctrl+0 100%',

  // App shell — banners.
  StringKey.shellRecoverPrompt: 'Recover unsaved work from your last session?',
  StringKey.shellRestore: 'Restore',
  StringKey.shellDismiss: 'Dismiss',

  // App shell — Layout electrical inspector.
  StringKey.shellElectricalLayer: 'Electrical layer',
  StringKey.shellElectricalLayerHelp:
      'Drag a load onto a panel to add a way, or onto the plan to '
          'place it. Double-click to edit; right-click for the menu.',

  // Schematic / elevation — toolbar + palette.
  StringKey.schematicAuto: 'Auto',
  StringKey.schematicEdit: 'Edit',
  StringKey.schematicRiserService: 'Riser service',
  StringKey.schematicNoNetwork: 'No network drawn',
  StringKey.schematicPalette: 'PALETTE',
  StringKey.schematicPaletteHelp:
      'Drag onto a floor to drop a riser to the floor above. Its length is '
          'the elevation delta. Drag a riser sideways to move it; right-click '
          'to set its size.',
  StringKey.schematicRiser: 'Riser',
  StringKey.schematicAddFloorBanner:
      'Add a second floor (Project panel) to place risers — '
          'a riser spans a floor-to-floor elevation delta.',

  // Schematic / elevation — help popover.
  StringKey.schematicElevationGuide: 'Elevation guide',
  StringKey.schematicClose: 'Close',
  StringKey.schematicHelp1:
      'Drag the Riser card onto a floor to place a riser to the floor above',
  StringKey.schematicHelp2:
      'A riser length is the floor-to-floor elevation delta, never a PDF distance',
  StringKey.schematicHelp3:
      'Drag a riser sideways to reposition it; its length does not change',
  StringKey.schematicHelp4:
      'Right-click a riser to set its nominal size in inches or pick a material',
  StringKey.schematicHelp5: 'Select a riser and press Delete to remove it',
  StringKey.schematicHelp6:
      'Middle-drag or scroll to pan; Ctrl+scroll or pinch to zoom',

  // Inspector — section labels.
  StringKey.inspectorProject: 'Project',
  StringKey.inspectorBuilding: 'Building',
  StringKey.inspectorDraw: 'Draw',
  StringKey.inspectorSizing: 'Sizing',
  StringKey.inspectorNetwork: 'Network',
  StringKey.inspectorFire: 'Fire',
  StringKey.inspectorHvacDucting: 'HVAC · ducting',
  StringKey.inspectorSheet: 'Sheet',
  StringKey.inspectorScale: 'Scale',
  StringKey.inspectorSelection: 'Selection',

  // Inspector — Project section.
  StringKey.inspectorExportCalcReportMd: 'Export calc report (MD)',
  StringKey.inspectorExportDrawingDxf: 'Export drawing (DXF)',
  StringKey.inspectorExportDrawingPdf: 'Export drawing (PDF)',

  // Inspector — Building section.
  StringKey.inspectorAddLevel: '+  Add level',

  // Inspector — Draw section.
  StringKey.inspectorSelect: 'Select',
  StringKey.inspectorRun: 'Run',
  StringKey.inspectorRiser: 'Riser',
  StringKey.inspectorUndo: 'Undo',
  StringKey.inspectorRedo: 'Redo',
  StringKey.inspectorClear: 'Clear',
  StringKey.inspectorOrtho: 'Ortho',
  StringKey.inspectorDuplicateFloorUp: 'Duplicate floor up',

  // Inspector — Sizing section.
  StringKey.inspectorHideSizes: 'Hide sizes',
  StringKey.inspectorShowSizes: 'Show sizes',
  StringKey.inspectorSizingNote:
      'Auto-sized to SNI velocity limits. Water supply uses accumulated '
          'fixture units via the Hunter demand curve; assign fixture types per '
          'node.',
  StringKey.inspectorOccupancy: 'Occupancy',
  StringKey.inspectorRainfallStorm: 'Rainfall (storm)',

  // Inspector — occupancy labels.
  StringKey.inspectorOccupancyResidential: 'Residential',
  StringKey.inspectorOccupancyPublic: 'Office / public',
  StringKey.inspectorOccupancyAssembly: 'Assembly / mall',

  // Inspector — Network section.
  StringKey.inspectorUpfeedPump: 'Upfeed pump',
  StringKey.inspectorRoofTankDownfeed: 'Roof-tank downfeed',
  StringKey.inspectorHideHeatmap: 'Hide heatmap',
  StringKey.inspectorShowHeatmap: 'Show heatmap',
  StringKey.inspectorExportBomCsv: 'Export BOM (CSV)',

  // Inspector — Selection section.
  StringKey.inspectorDeleteNode: 'Delete node',
  StringKey.inspectorFixtureType: 'Fixture type',
  StringKey.inspectorAirTerminalAirflow: 'Air terminal (diffuser) airflow',
  StringKey.inspectorClearSizeOverride: 'Clear size override',
  StringKey.inspectorEdgeSizeHint:
      'Right-click the segment to set its size and material.',

  // Inspector — Scale section.
  StringKey.inspectorNotCalibrated: 'Not calibrated — mark a known distance',
  StringKey.inspectorCalibrateScale: 'Calibrate scale',
  StringKey.inspectorReCalibrate: 'Re-calibrate',
  StringKey.inspectorMapsToFloor: 'Maps to floor',

  // Inspector — HVAC section.
  StringKey.inspectorRound: 'Round',
  StringKey.inspectorRectangular: 'Rectangular',
  StringKey.inspectorVelocity: 'Velocity',
  StringKey.inspectorEqualFriction: 'Equal friction',
  StringKey.inspectorDuctNote:
      'Draw a duct network and assign diffuser airflows.',

  // Inspector — node role labels.
  StringKey.inspectorRoleJunction: 'Junction',
  StringKey.inspectorRoleFixture: 'Fixture',
  StringKey.inspectorRoleSource: 'Source / tank',

  // Export — OS save-dialog titles.
  StringKey.exportTitleCalcReport: 'Export calculation report',
  StringKey.exportTitleDrawingDxf: 'Export drawing (DXF)',
  StringKey.exportTitleDrawingPdf: 'Export drawing (PDF)',
  StringKey.exportTitleBom: 'Export bill of materials',
  StringKey.exportTitleSldDxf: 'Export single-line (DXF)',
  StringKey.exportTitleSldPdf: 'Export single-line (PDF)',
  StringKey.exportTitlePowerOneLineDxf: 'Export power one-line (DXF)',
  StringKey.exportTitleElectricalReport: 'Export electrical report',
  StringKey.exportTitleElectricalBom: 'Export electrical BOM',
  StringKey.exportTitleElectricalProposal: 'Export electrical proposal',
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
  StringKey.commercialBomLead:
      '{lines} baris dari model kelistrikan terhitung, dicocokkan ke katalog '
          'komponen. {unmatched} baris tanpa kecocokan katalog.',

  // Commercial workspace — pricelist.
  StringKey.commercialPricelistTitle: 'Daftar Harga',
  StringKey.commercialColUnit: 'Satuan',
  StringKey.commercialColUnitPrice: 'Harga satuan',
  StringKey.commercialPricelistLead:
      'Harga satuan untuk komponen katalog yang dipakai desain Anda. Disimpan '
          'bersama proyek, bukan di katalog. {priced} dari {total} diberi harga.',

  // Commercial workspace — quotation.
  StringKey.commercialQuotationTitle: 'Penawaran',
  StringKey.commercialAllPriced: 'Semua baris yang cocok katalog telah diberi harga.',
  StringKey.commercialUnpricedExcluded:
      '{n} baris belum diberi harga dan dikecualikan dari subtotal material.',
  StringKey.commercialLabourRate: 'Tarif tenaga kerja ({cur} / jam)',
  StringKey.commercialColAmount: 'Jumlah ({cur})',
  StringKey.commercialLabourHours: 'Tenaga kerja ({hours} jam)',
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

  // App shell — top bar.
  StringKey.shellOpen: 'Buka',
  StringKey.shellSave: 'Simpan',
  StringKey.shellImportPdf: 'Impor PDF',
  StringKey.shellDark: 'Gelap',
  StringKey.shellLight: 'Terang',

  // App shell — status bar.
  StringKey.shellNoSheet: 'Tidak ada lembar',
  StringKey.shellUncalibrated: 'Belum dikalibrasi',
  StringKey.shellStandardsProvenance: 'SNI 8153:2015 (draf)',
  StringKey.shellViewportHints:
      'gulir zoom · seret geser · F pas · Ctrl+0 100%',

  // App shell — banners.
  StringKey.shellRecoverPrompt:
      'Pulihkan pekerjaan yang belum disimpan dari sesi terakhir Anda?',
  StringKey.shellRestore: 'Pulihkan',
  StringKey.shellDismiss: 'Tutup',

  // App shell — Layout electrical inspector.
  StringKey.shellElectricalLayer: 'Lapisan listrik',
  StringKey.shellElectricalLayerHelp:
      'Seret beban ke panel untuk menambah jalur, atau ke denah untuk '
          'menempatkannya. Klik-ganda untuk mengedit; klik-kanan untuk menu.',

  // Schematic / elevation — toolbar + palette.
  StringKey.schematicAuto: 'Otomatis',
  StringKey.schematicEdit: 'Edit',
  StringKey.schematicRiserService: 'Layanan riser',
  StringKey.schematicNoNetwork: 'Belum ada jaringan digambar',
  StringKey.schematicPalette: 'PALET',
  StringKey.schematicPaletteHelp:
      'Seret ke lantai untuk menjatuhkan riser ke lantai di atasnya. '
          'Panjangnya adalah selisih elevasi. Seret riser ke samping untuk '
          'memindahkannya; klik-kanan untuk mengatur ukurannya.',
  StringKey.schematicRiser: 'Riser',
  StringKey.schematicAddFloorBanner:
      'Tambahkan lantai kedua (panel Proyek) untuk menempatkan riser — '
          'sebuah riser membentang sepanjang selisih elevasi antar-lantai.',

  // Schematic / elevation — help popover.
  StringKey.schematicElevationGuide: 'Panduan elevasi',
  StringKey.schematicClose: 'Tutup',
  StringKey.schematicHelp1:
      'Seret kartu Riser ke lantai untuk menempatkan riser ke lantai di atasnya',
  StringKey.schematicHelp2:
      'Panjang riser adalah selisih elevasi antar-lantai, bukan jarak pada PDF',
  StringKey.schematicHelp3:
      'Seret riser ke samping untuk memindahkannya; panjangnya tidak berubah',
  StringKey.schematicHelp4:
      'Klik-kanan riser untuk mengatur ukuran nominalnya dalam inci atau memilih material',
  StringKey.schematicHelp5:
      'Pilih riser dan tekan Delete untuk menghapusnya',
  StringKey.schematicHelp6:
      'Seret-tengah atau gulir untuk menggeser; Ctrl+gulir atau cubit untuk zoom',

  // Inspector — section labels.
  StringKey.inspectorProject: 'Proyek',
  StringKey.inspectorBuilding: 'Bangunan',
  StringKey.inspectorDraw: 'Gambar',
  StringKey.inspectorSizing: 'Pengukuran',
  StringKey.inspectorNetwork: 'Jaringan',
  StringKey.inspectorFire: 'Kebakaran',
  StringKey.inspectorHvacDucting: 'HVAC · saluran',
  StringKey.inspectorSheet: 'Lembar',
  StringKey.inspectorScale: 'Skala',
  StringKey.inspectorSelection: 'Pilihan',

  // Inspector — Project section.
  StringKey.inspectorExportCalcReportMd: 'Ekspor laporan hitung (MD)',
  StringKey.inspectorExportDrawingDxf: 'Ekspor gambar (DXF)',
  StringKey.inspectorExportDrawingPdf: 'Ekspor gambar (PDF)',

  // Inspector — Building section.
  StringKey.inspectorAddLevel: '+  Tambah lantai',

  // Inspector — Draw section.
  StringKey.inspectorSelect: 'Pilih',
  StringKey.inspectorRun: 'Saluran',
  StringKey.inspectorRiser: 'Riser',
  StringKey.inspectorUndo: 'Urungkan',
  StringKey.inspectorRedo: 'Ulangi',
  StringKey.inspectorClear: 'Bersihkan',
  StringKey.inspectorOrtho: 'Orto',
  StringKey.inspectorDuplicateFloorUp: 'Gandakan ke lantai atas',

  // Inspector — Sizing section.
  StringKey.inspectorHideSizes: 'Sembunyikan ukuran',
  StringKey.inspectorShowSizes: 'Tampilkan ukuran',
  StringKey.inspectorSizingNote:
      'Diukur otomatis sesuai batas kecepatan SNI. Pasokan air memakai akumulasi '
          'unit fikstur via kurva permintaan Hunter; tetapkan jenis fikstur per '
          'simpul.',
  StringKey.inspectorOccupancy: 'Hunian',
  StringKey.inspectorRainfallStorm: 'Curah hujan (badai)',

  // Inspector — occupancy labels.
  StringKey.inspectorOccupancyResidential: 'Hunian',
  StringKey.inspectorOccupancyPublic: 'Kantor / publik',
  StringKey.inspectorOccupancyAssembly: 'Pertemuan / mal',

  // Inspector — Network section.
  StringKey.inspectorUpfeedPump: 'Pompa naik',
  StringKey.inspectorRoofTankDownfeed: 'Tangki atap turun',
  StringKey.inspectorHideHeatmap: 'Sembunyikan peta panas',
  StringKey.inspectorShowHeatmap: 'Tampilkan peta panas',
  StringKey.inspectorExportBomCsv: 'Ekspor BOM (CSV)',

  // Inspector — Selection section.
  StringKey.inspectorDeleteNode: 'Hapus simpul',
  StringKey.inspectorFixtureType: 'Jenis fikstur',
  StringKey.inspectorAirTerminalAirflow: 'Aliran udara terminal (difuser)',
  StringKey.inspectorClearSizeOverride: 'Hapus penimpaan ukuran',
  StringKey.inspectorEdgeSizeHint:
      'Klik-kanan segmen untuk mengatur ukuran dan materialnya.',

  // Inspector — Scale section.
  StringKey.inspectorNotCalibrated:
      'Belum dikalibrasi — tandai jarak yang diketahui',
  StringKey.inspectorCalibrateScale: 'Kalibrasi skala',
  StringKey.inspectorReCalibrate: 'Kalibrasi ulang',
  StringKey.inspectorMapsToFloor: 'Memetakan ke lantai',

  // Inspector — HVAC section.
  StringKey.inspectorRound: 'Bulat',
  StringKey.inspectorRectangular: 'Persegi panjang',
  StringKey.inspectorVelocity: 'Kecepatan',
  StringKey.inspectorEqualFriction: 'Gesekan sama',
  StringKey.inspectorDuctNote:
      'Gambar jaringan saluran dan tetapkan aliran udara difuser.',

  // Inspector — node role labels.
  StringKey.inspectorRoleJunction: 'Persimpangan',
  StringKey.inspectorRoleFixture: 'Fikstur',
  StringKey.inspectorRoleSource: 'Sumber / tangki',

  // Export — OS save-dialog titles.
  StringKey.exportTitleCalcReport: 'Ekspor laporan perhitungan',
  StringKey.exportTitleDrawingDxf: 'Ekspor gambar (DXF)',
  StringKey.exportTitleDrawingPdf: 'Ekspor gambar (PDF)',
  StringKey.exportTitleBom: 'Ekspor daftar material',
  StringKey.exportTitleSldDxf: 'Ekspor satu-garis (DXF)',
  StringKey.exportTitleSldPdf: 'Ekspor satu-garis (PDF)',
  StringKey.exportTitlePowerOneLineDxf: 'Ekspor daya satu-garis (DXF)',
  StringKey.exportTitleElectricalReport: 'Ekspor laporan kelistrikan',
  StringKey.exportTitleElectricalBom: 'Ekspor BOM kelistrikan',
  StringKey.exportTitleElectricalProposal: 'Ekspor proposal kelistrikan',
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

  /// Resolve a parameterized [key] whose template carries `{name}` placeholders,
  /// substituting each entry of [params] (e.g. `format(k, {'n': 3})` turns
  /// `'{n} items'` into `'3 items'`). Unknown placeholders are left intact and
  /// unused params ignored, so a template + call can never throw. Falls back to
  /// English like [call] — keep the `{name}` placeholders identical across the EN
  /// and ID templates so both substitute correctly.
  String format(StringKey key, Map<String, Object?> params) {
    var out = _map[key] ?? _en[key]!;
    params.forEach((k, v) => out = out.replaceAll('{$k}', '$v'));
    return out;
  }
}

/// Inherited string table. Mirrors [MechXTheme]: provided once above the shell
/// (keyed off [localeProvider]) and read via the `context.strings` extension.
class MechXStrings extends InheritedWidget {
  final MechXStringsData data;

  const MechXStrings({super.key, required this.data, required super.child});

  /// The active string table for [context]. Falls back to English when no
  /// [MechXStrings] ancestor is present (e.g. a widget pumped in isolation by a
  /// test, or before the root provider is mounted) so `context.strings` never
  /// throws — a missing provider degrades to EN rather than crashing.
  static MechXStringsData of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<MechXStrings>();
    return widget?.data ?? const MechXStringsData(AppLocale.en);
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
