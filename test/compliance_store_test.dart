/// Tests for `store/compliance_store.dart` (H2): the pure compliance fan-in
/// and the WATCHED provider that keeps the Review hub's verdict live (the
/// pre-H2 `ref.read` helper snapshotted once and went stale).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
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
      expect(_item(s, 'Air velocities within band').pass, isTrue);
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
      expect(row.detail, '1 advisory note(s)');
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
      expect(row.detail, '1 error(s), 0 warning(s)');
    });
  });

  group('complianceSummaryProvider (watched)', () {
    test('the verdict moves with its inputs — calibrating flips the row', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      // Uncalibrated demo sheets ⇒ the calibration row REVIEWs.
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      var summary = c.read(complianceSummaryProvider);
      var row = _item(summary, 'Sheet calibration');
      expect(row.pass, isFalse);
      expect(row.detail, '3 uncalibrated');

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
