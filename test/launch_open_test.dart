import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/data/recovery.dart' show appSupportDirOverride;
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/shell/project_io.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

/// M2 (Windows-desktop citizenship): `.mechx` file association + command-line
/// open. The OS handoff (Explorer double-click / "Open with" / jump list) is
/// exercised only on Windows CI + a manual smoke; here we pin the two Dart-side
/// pieces — the PURE launch decision and the launch-open loader.
void main() {
  group('launchProjectPathFromArgs (pure launch decision)', () {
    test('no arguments → null', () {
      expect(launchProjectPathFromArgs(const []), isNull);
    });

    test('a .mechx path is returned verbatim', () {
      expect(launchProjectPathFromArgs(const [r'C:\jobs\tower.mechx']),
          r'C:\jobs\tower.mechx');
    });

    test('the extension match is case-insensitive', () {
      expect(launchProjectPathFromArgs(const [r'C:\jobs\Tower.MECHX']),
          r'C:\jobs\Tower.MECHX');
    });

    test('empty tokens and switches (leading -) are skipped', () {
      expect(
        launchProjectPathFromArgs(const ['', '--verbose', '-x', 'plan.mechx']),
        'plan.mechx',
      );
    });

    test('a non-.mechx argument yields null', () {
      expect(launchProjectPathFromArgs(const [r'C:\jobs\plan.pdf']), isNull);
      // A `.mechx.bak` (the atomic writer's displaced copy) is not a project.
      expect(launchProjectPathFromArgs(const ['tower.mechx.bak']), isNull);
    });

    test('the FIRST .mechx wins when several are passed', () {
      expect(launchProjectPathFromArgs(const ['a.mechx', 'b.mechx']), 'a.mechx');
    });
  });

  group('openProjectAtLaunch (command-line open)', () {
    // The loader clears per-project recovery slots under the app-support dir —
    // isolate it to a temp dir so the concurrently-run suite doesn't race.
    setUpAll(() {
      appSupportDirOverride =
          Directory.systemTemp.createTempSync('mechx_launch_open_test').path;
    });

    test('opens a real .mechx into the live state (through the shared loader)',
        () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      final tmp = Directory.systemTemp.createTempSync('mechx_launch_file');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // Two floors + a distinctive name ⇒ we can tell the FILE loaded, not the
      // default three-floor virgin project.
      final doc = ProjectDocument(
        projectName: 'Command-line project',
        floors: const [
          Floor('Basement', Length(3.2)),
          Floor('Ground', Length(4.0)),
        ],
        calibrations: const {},
        sheets: const [],
        network: const Network(),
      );
      final file = File('${tmp.path}/from-explorer.mechx')
        ..writeAsStringSync(doc.encode());

      await openProjectAtLaunch(c, file.path);

      expect(c.read(currentProjectPathProvider), file.path);
      expect(c.read(projectControllerProvider).name, 'Command-line project');
      expect(c.read(projectControllerProvider).floors, hasLength(2));
      // A clean load leaves no error and a fresh baseline (not dirty).
      expect(c.read(loadErrorProvider), isNull);
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('a missing path is a silent no-op — no throw, no state change',
        () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await openProjectAtLaunch(c, '/no/such/file.mechx');
      // Nothing opened: the virgin defaults + no error banner remain.
      expect(c.read(currentProjectPathProvider), isNull);
      expect(c.read(loadErrorProvider), isNull);
      expect(c.read(projectControllerProvider).floors, hasLength(3));
    });
  });
}
