/// Tests for `store/compliance_store.dart` (H2): the pure compliance fan-in
/// and the WATCHED provider that keeps the Review hub's verdict live (the
/// pre-H2 `ref.read` helper snapshotted once and went stale).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mep_report.dart';

ComplianceItem _item(ComplianceSummary s, String category) =>
    s.items.firstWhere((i) => i.category == category,
        orElse: () => fail('missing compliance row: $category'));

void main() {
  group('buildComplianceSummaryFrom (pure)', () {
    test('clean inputs pass every named check', () {
      final s = buildComplianceSummaryFrom(
        issues: const [],
        electricalWarnings: const [],
        date: '2026-07-02',
      );
      expect(s.allPass, isTrue);
      expect(s.date, '2026-07-02');
      expect(_item(s, 'Velocity').pass, isTrue);
      expect(_item(s, 'Sheet calibration').pass, isTrue);
      expect(_item(s, 'Standards verification').pass, isTrue);
      expect(_item(s, 'Electrical circuit sizing').pass, isTrue);
      // No remainder rows appear from nowhere.
      expect(s.items, hasLength(4));
    });

    test('an uncalibrated-sheet warning fails the calibration row', () {
      final s = buildComplianceSummaryFrom(
        issues: const [
          DesignIssue(
            severity: IssueSeverity.warning,
            title: 'Sheet not calibrated',
            message: 'x',
            kind: 'sheet-uncalibrated:x',
          ),
        ],
        electricalWarnings: const [],
        date: 'd',
      );
      final row = _item(s, 'Sheet calibration');
      expect(row.pass, isFalse);
      expect(row.detail, '1 uncalibrated');
      expect(s.allPass, isFalse);
    });

    test('an unclaimed issue title gets its own row (complete by construction)',
        () {
      final s = buildComplianceSummaryFrom(
        issues: const [
          DesignIssue(
            severity: IssueSeverity.info,
            title: 'Some future advisory',
            message: 'x',
          ),
        ],
        electricalWarnings: const [],
        date: 'd',
      );
      final row = _item(s, 'Some future advisory');
      // Info severity ⇒ an advisory note, not a failure.
      expect(row.pass, isTrue);
      expect(row.detail, '1 advisory note');
    });

    test('an error-severity electrical warning fails the electrical row', () {
      final s = buildComplianceSummaryFrom(
        issues: const [],
        electricalWarnings: const [
          ElectricalWarning(
            severity: WarningSeverity.error,
            code: 'cable-ampacity-inadequate',
            message: 'x',
          ),
        ],
        date: 'd',
      );
      final row = _item(s, 'Electrical circuit sizing');
      expect(row.pass, isFalse);
      expect(row.detail, '1 error, 0 warnings');
    });

    // ── H1: reachable PASS via advisory acknowledgement ──────────────────────
    test('unverified-standard advisories block PASS until acknowledged', () {
      const items = [
        DesignIssue(
          severity: IssueSeverity.info,
          title: 'Unverified: KHA ampacity table',
          message: 'KHA table awaits the official PUIL clause.',
          isVerify: true,
          kind: 'verify:kha',
        ),
        DesignIssue(
          severity: IssueSeverity.info,
          title: 'Unverified: nominal voltage',
          message: 'Nominal voltage awaits confirmation.',
          isVerify: true,
          kind: 'verify:nominal',
        ),
      ];
      // Unacknowledged: the standards row REVIEWs and the whole verdict fails —
      // this is the structurally-unreachable-PASS state H1 fixes.
      final open = buildComplianceSummaryFrom(
        issues: items,
        electricalWarnings: const [],
        date: 'd',
      );
      final openRow = _item(open, 'Standards verification');
      expect(openRow.pass, isFalse);
      expect(open.allPass, isFalse);

      // Acknowledge BOTH advisories ⇒ the standards row passes and, with no
      // warnings/criticals, the overall verdict reaches PASS.
      final acked = buildComplianceSummaryFrom(
        issues: items,
        electricalWarnings: const [],
        date: 'd',
        acknowledged: {items[0].key, items[1].key},
      );
      final ackedRow = _item(acked, 'Standards verification');
      expect(ackedRow.pass, isTrue);
      expect(ackedRow.detail, '2 acknowledged, none open');
      expect(acked.allPass, isTrue);
    });

    test('acknowledging an advisory NEVER unblocks a real error/warning', () {
      const warn = DesignIssue(
        severity: IssueSeverity.warning,
        title: 'Duct velocity out of band',
        message: 'A supply duct is over 7 m/s.',
        kind: 'duct-velocity',
      );
      // A warning is not acknowledgeable; even if its key is (spuriously) in the
      // acknowledged set, it must still fail — acknowledgement can't hide it.
      final s = buildComplianceSummaryFrom(
        issues: const [warn],
        electricalWarnings: const [
          ElectricalWarning(
            severity: WarningSeverity.error,
            code: 'cable-ampacity-inadequate',
            message: 'x',
          ),
        ],
        date: 'd',
        acknowledged: {warn.key},
      );
      expect(_item(s, 'Velocity').pass, isFalse);
      expect(_item(s, 'Electrical circuit sizing').pass, isFalse);
      expect(s.allPass, isFalse);
    });

    test('a partially-acknowledged standards register reports open + ack', () {
      const items = [
        DesignIssue(
          severity: IssueSeverity.info,
          title: 'Unverified: one',
          message: 'one',
          isVerify: true,
          kind: 'verify:one',
        ),
        DesignIssue(
          severity: IssueSeverity.info,
          title: 'Unverified: two',
          message: 'two',
          isVerify: true,
          kind: 'verify:two',
        ),
      ];
      final s = buildComplianceSummaryFrom(
        issues: items,
        electricalWarnings: const [],
        date: 'd',
        acknowledged: {items[0].key},
      );
      final row = _item(s, 'Standards verification');
      expect(row.pass, isFalse);
      expect(row.detail, '1 open, 1 acknowledged');
    });
  });

  group('complianceSummaryProvider (watched)', () {
    test('the verdict moves with its inputs — calibrating flips the row', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      // A BLANK uncalibrated sheet is now only an INFO advisory (nothing
      // measurable is wrong yet), so it no longer fails this row — draw an
      // edge on s1 to make its calibration gap a real (failing) finding; s2/s3
      // stay blank/info and don't count toward the failure.
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      const nodeA = NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const nodeB = NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
      const edge = NetEdge(
          id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);
      c.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [nodeA, nodeB], edges: [edge]),
          );
      var summary = c.read(complianceSummaryProvider);
      var row = _item(summary, 'Sheet calibration');
      expect(row.pass, isFalse);
      expect(row.detail, '1 uncalibrated');

      // Fix the issue (the quick-fix path): calibrate every sheet. The
      // provider WATCHES designIssuesProvider, so the next read re-verdicts —
      // this is exactly the staleness H2 killed.
      final project = c.read(projectControllerProvider.notifier);
      for (final s in kDemoSheets) {
        project.setCalibration(s.id, const ScaleCalibration(0.01));
      }
      summary = c.read(complianceSummaryProvider);
      row = _item(summary, 'Sheet calibration');
      expect(row.pass, isTrue);
      expect(row.detail, 'all sheets calibrated');
    });
  });
}
