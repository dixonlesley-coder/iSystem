/// Round 24 follow-up — the 'apply scale to all sheets' status is ONE
/// localized formatter (`MechXStringsData.scaleAppliedStatus`) shared by the
/// Scale inspector button and the Review quick fix: EN pluralizes, ID does
/// not, and a skipped PDF <-> DXF target is always said.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart' show AppLocale;
import 'package:mechx/ui/strings/app_strings.dart';

void main() {
  const en = MechXStringsData(AppLocale.en);
  const id = MechXStringsData(AppLocale.id);

  test('EN pluralizes the applied and skipped counts', () {
    expect(en.scaleAppliedStatus(1, 0), 'Scale applied to 1 sheet');
    expect(en.scaleAppliedStatus(3, 0), 'Scale applied to 3 sheets');
    expect(en.scaleAppliedStatus(2, 1),
        'Scale applied to 2 sheets; 1 skipped (different plan type - '
        'calibrate it separately)');
    expect(en.scaleAppliedStatus(2, 4),
        'Scale applied to 2 sheets; 4 skipped (different plan type - '
        'calibrate them separately)');
  });

  test('ID carries the same counts and no EN leaks', () {
    expect(id.scaleAppliedStatus(3, 2),
        'Skala diterapkan ke 3 lembar; 2 dilewati (jenis denah berbeda - '
        'kalibrasi tersendiri)');
    expect(id(StringKey.scaleAlreadyAllSheets),
        'Semua lembar lain sudah memakai skala ini');
    for (final k in [
      StringKey.scaleAlreadyAllSheets,
      StringKey.scaleAppliedOne,
      StringKey.scaleAppliedMany,
      StringKey.scaleSkippedOne,
      StringKey.scaleSkippedMany,
    ]) {
      expect(id(k), isNot(en(k)), reason: '$k');
    }
  });
}
