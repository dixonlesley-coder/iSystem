/// The UI surfaces added in the 2026-10 UI pass resolve through the i18n table:
/// the Export sheet's document-control identity bar, the merged electrical
/// Supply inspector, and the two command-palette "on Projects" subtitles. EN
/// stays byte-identical (goldens hold); ID renders Bahasa.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/ui/electrical/electrical_view.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/strings/app_strings.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

import 'test_util.dart';

Widget _host(AppLocale locale, Widget child) => ProviderScope(
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: MechXStrings(
          data: MechXStringsData(locale),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 420, height: 1400, child: child),
            ),
          ),
        ),
      ),
    );

void main() {
  test('the new keys keep the exact EN copy (goldens byte-identical)', () {
    const en = MechXStringsData(AppLocale.en);
    expect(en(StringKey.exportIdentityTitle), 'Document control');
    expect(en(StringKey.exportIdentityDrawingNo), 'Drawing no.');
    expect(en(StringKey.paletteEditDocControlSub),
        'Sign-off + revisions on Projects');
    expect(en(StringKey.paletteEditEquipmentSpecsSub),
        'Equipment model/spec on Projects');
    expect(en(StringKey.electricalSupplyCapacityVa), 'Connection capacity (VA)');
    expect(
        en.format(StringKey.electricalMepFeedNote, {'names': 'P-01, F-01'}),
        startsWith('Folds the app-sized P-01, F-01 into the MEP Equipment'));
  });

  testWidgets('ExportIdentityBar renders in Bahasa under the ID locale',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host(AppLocale.id, const ExportIdentityBar()));
    await tester.pumpAndSettle();
    expect(find.text('Kontrol dokumen'), findsOneWidget);
    expect(find.text('No. gambar'), findsOneWidget);
    expect(find.text('Revisi'), findsOneWidget);
    expect(find.text('Klien'), findsOneWidget);
    expect(find.text('Document control'), findsNothing);
    expect(find.text('Drawing no.'), findsNothing);
  });

  testWidgets('the Supply inspector body renders in Bahasa under ID',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host(
        AppLocale.id, ElectricalSupplyInspector(onClose: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Sumber'), findsOneWidget);
    expect(find.text('Daya tersambung (VA)'), findsOneWidget);
    expect(find.text('Source'), findsNothing);
    expect(find.text('Connection capacity (VA)'), findsNothing);
  });
}
