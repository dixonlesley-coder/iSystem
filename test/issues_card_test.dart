import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/ui/review/issues_card.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

import 'test_util.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

Widget _host(List<DesignIssue> issues) => ProviderScope(
      overrides: [
        designIssuesProvider.overrideWithValue(issues),
      ],
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 420, child: IssuesCard()),
          ),
        ),
      ),
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets('clean design shows an explicit positive success state',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host(const []));
    await tester.pumpAndSettle();

    // No more invisible void — the card states the design is clean.
    expect(find.text('No design issues found'), findsOneWidget);
    // And it surfaces the reassuring detail line.
    expect(find.textContaining('Air velocities are in band'), findsOneWidget);
  });

  testWidgets('issues render grouped Warnings + Advisory', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host(const [
      DesignIssue(
        severity: IssueSeverity.warning,
        title: 'Air velocity high',
        message: 'A supply duct is over 7 m/s.',
      ),
      DesignIssue(
        severity: IssueSeverity.info,
        title: 'Unverified standard',
        message: 'A value awaits the official SNI clause.',
      ),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Design issues'), findsOneWidget);
    expect(find.text('No design issues found'), findsNothing);
    expect(find.textContaining('Warnings'), findsOneWidget);
    expect(find.textContaining('Advisory'), findsOneWidget);
    expect(find.text('Air velocity high'), findsOneWidget);
    expect(find.text('Unverified standard'), findsOneWidget);
  });
}
