/// ONE byte-order policy for every CSV deliverable (Round 13, export-files-5).
///
/// The CSVs carry non-ASCII text (the `—` model/spec placeholder, `3φ`, `×`,
/// `mm²` …), and Excel on Windows opens a BOM-less UTF-8 CSV by double-click
/// in the ANSI code page — `â€”` / `3Ï†` mojibake on the procurement schedule
/// and BOM a QS works from. Every CSV writer passes its text through
/// [excelCsv] at the file boundary, so the file starts with a UTF-8 BOM and
/// Excel reads it as UTF-8. Pure.
library;

/// The UTF-8 byte-order mark (U+FEFF), written as `EF BB BF` by a UTF-8
/// encoder.
const String kCsvBom = '\u{FEFF}';

/// [csv] prefixed with exactly one UTF-8 BOM (idempotent).
String excelCsv(String csv) => csv.startsWith(kCsvBom) ? csv : '$kCsvBom$csv';
