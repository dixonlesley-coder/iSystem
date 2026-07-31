/// J7 — the Commercial workspace still spoke as if it were electrical-only: the
/// hub lead said "the electrical bill of materials" above a Mechanical BOM
/// table, the export dialog said "Export electrical BOM" while writing a
/// unified `-mep-bom.csv`, and 'Mechanical BOM' (plus its columns and
/// priced/unpriced flags) were unlocalized EN literals.
///
/// This pins the string surface in BOTH locales.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/ui/strings/app_strings.dart';

void main() {
  const en = MechXStringsData(AppLocale.en);
  const id = MechXStringsData(AppLocale.id);

  test('the Commercial hub lead names M+E+P, not electrical alone', () {
    final lead = en(StringKey.commercialHubLead);
    expect(lead, contains('M+E+P'));
    expect(lead.toLowerCase(),
        isNot(contains('the electrical bill of materials')));
    expect(id(StringKey.commercialHubLead), contains('M+E+P'));
  });

  test('the BOM export dialog title says MEP (the file IS the unified CSV)',
      () {
    expect(en(StringKey.exportTitleElectricalBom), 'Export MEP BOM');
    expect(id(StringKey.exportTitleElectricalBom), contains('MEP'));
  });

  test('the mechanical BOM table is localized (title, lead, columns, flags)',
      () {
    expect(en(StringKey.commercialMechBomTitle), 'Mechanical BOM');
    expect(id(StringKey.commercialMechBomTitle), isNot('Mechanical BOM'));

    // The lead takes PRE-pluralized counts (no '(s)' dev-speak) and both
    // locales carry the same placeholders.
    final lead = en.format(
        StringKey.commercialMechBomLead, {'lines': '7 lines', 'unpriced': '2'});
    expect(lead, contains('7 lines'));
    expect(lead, contains('2'));
    expect(lead, isNot(contains('{')));
    expect(lead, isNot(contains('(s)')));

    for (final key in [
      StringKey.commercialMechBomEmpty,
      StringKey.commercialColPriced,
      StringKey.commercialPriced,
      StringKey.commercialUnpriced,
    ]) {
      expect(en(key), isNotEmpty);
      expect(id(key), isNotEmpty);
    }
  });

  test('the electrical BOM table keeps its own (electrical) naming', () {
    // The hub carries BOTH tables, so the electrical one stays explicitly
    // named — only the shared lead / export were over-claiming.
    expect(en(StringKey.commercialBomTitle), 'Electrical BOM');
  });
}
