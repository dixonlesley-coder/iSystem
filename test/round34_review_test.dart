// Round 34 — Review honesty findings:
//
//   ui-simplicity-5-riser-only-sheet-false-critical   a sheet holding only
//     riser ends is an advisory, never the CRITICAL 'sizing to ZERO length'
//     (a riser's length is the §10 elevation delta, golden rule 3).
//   ui-simplicity-5-lone-riser-triple-report   one isolated 2-node riser is
//     ONE Review row (the no-source), not three.
//   ui-simplicity-5-verify-rows-research-notes   verification rows carry a
//     short localized action, never a research-session log.
//   ui-simplicity-5-electrical-titles-raw-codes   electrical titles are
//     localized human titles, never 'Electrical: non selective'.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/strings/app_strings.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(sheetsControllerProvider.notifier).loadDemoSheets(); // s1 s2 s3
  c.read(projectControllerProvider.notifier)
      .setCalibration('s1', const ScaleCalibration(0.02));
  return c;
}

NetNode _n(String id, String sheet, int floor, double x,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: sheet,
        floorIndex: floor,
        x: x,
        y: 0,
        role: role,
        component: c);

List<DesignIssue> _sheetIssues(ProviderContainer c, String sheet) => c
    .read(designIssuesProvider)
    .where((i) => i.kind == 'sheet-uncalibrated:$sheet')
    .toList();

void main() {
  group('a riser-only sheet is never a critical calibration blocker', () {
    test('calibrated s1 + a riser whose upper end sits on uncalibrated s2',
        () {
      final c = _c();
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('T', 's1', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('B', 's1', 0, 200),
        _n('U', 's2', 1, 200),
      ], edges: const [
        NetEdge(
            id: 'run', fromId: 'T', toId: 'B', service: ServiceType.coldWater),
        NetEdge(
            id: 'rsr',
            fromId: 'B',
            toId: 'U',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser),
      ]));
      final s2 = _sheetIssues(c, 's2');
      expect(s2, hasLength(1));
      // Nothing on s2 sizes to zero: the riser takes the elevation delta.
      expect(s2.single.severity, IssueSeverity.info);
    });

    test('a RUN on the uncalibrated sheet still raises the critical', () {
      final c = _c();
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('U', 's2', 1, 0),
        _n('V', 's2', 1, 200),
      ], edges: const [
        NetEdge(id: 'r', fromId: 'U', toId: 'V', service: ServiceType.coldWater),
      ]));
      expect(_sheetIssues(c, 's2').single.severity, IssueSeverity.critical);
    });
  });

  test('an isolated 2-node hot-water riser is ONE Review row', () {
    final c = _c();
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('n15', 's1', 0, 500),
      _n('n16', 's2', 1, 500),
    ], edges: const [
      NetEdge(
          id: 'e17',
          fromId: 'n15',
          toId: 'n16',
          service: ServiceType.hotWater,
          kind: EdgeKind.riser),
    ]));
    final issues = c.read(designIssuesProvider);
    expect(issues.where((i) => i.kind == 'no-source:hotWater'), hasLength(1));
    expect(
        issues.where((i) =>
            i.kind == 'unconnected-loose-end:n15' ||
            i.kind == 'unconnected-loose-end:n16'),
        isEmpty);
  });

  group('verify + electrical rows read as titles, not logs or codes', () {
    ProviderContainer withPanel() {
      final c = _c();
      c.read(electricalProjectProvider.notifier).addPanel(name: 'DB');
      return c;
    }

    for (final locale in AppLocale.values) {
      test('verification rows carry the short action (${locale.name})', () {
        final c = withPanel();
        c.read(localeProvider.notifier).set(locale);
        final verify =
            c.read(designIssuesProvider).where((i) => i.isVerify).toList();
        expect(verify, isNotEmpty);
        for (final v in verify) {
          final m = v.message.toLowerCase();
          expect(m.contains('research pass'), isFalse, reason: v.message);
          expect(m.contains('blocked'), isFalse, reason: v.message);
          // The kind is 'verify:<citation>': the message names that source.
          expect(v.message, contains(v.kind.substring('verify:'.length)));
        }
      });
    }

    test('every engine electrical code has a localized title', () {
      const en = MechXStringsData(AppLocale.en);
      const id = MechXStringsData(AppLocale.id);
      expect(en.electricalWarningTitle('non-selective'),
          'Breakers not selective');
      expect(id.electricalWarningTitle('non-selective'),
          'Pemutus tidak selektif');
      expect(en.electricalWarningTitle('life-safety-not-essential'),
          'Life-safety load on a normal supply');
      // Unknown code: the humanized fallback, never blank.
      expect(en.electricalWarningTitle('some-new-code'), 'some new code');
    });
  });
}
