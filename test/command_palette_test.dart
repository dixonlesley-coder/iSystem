import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

void main() {
  group('fuzzyScore', () {
    test('empty query matches everything with a baseline score', () {
      expect(fuzzyScore('', 'Go to Layout'), 0);
      expect(fuzzyMatches('', 'anything'), isTrue);
    });

    test('in-order subsequence matches; out-of-order does not', () {
      // "glt" is a subsequence of "Go to Layout" (G…o…t…? — actually G,L,T):
      // G(o) L(ayout) T → present in order.
      expect(fuzzyMatches('glt', 'Go to Layout'), isTrue);
      // "tlg" reverses the order — no in-order subsequence.
      expect(fuzzyMatches('tlg', 'Go to Layout'), isFalse);
    });

    test('is case-insensitive', () {
      expect(fuzzyMatches('LAYOUT', 'Go to Layout'), isTrue);
      expect(fuzzyMatches('layout', 'Go to Layout'), isTrue);
    });

    test('a contiguous run outranks the same letters scattered apart', () {
      // "size" as a contiguous substring (run + boundary bonuses, early indices)
      // beats the same letters spread across a longer string.
      final contiguous = fuzzyScore('size', 'Size network')!;
      final scattered = fuzzyScore('size', 'Six analyzers everywhere')!;
      expect(contiguous, greaterThan(scattered));
    });

    test('a prefix match scores higher than a later match', () {
      // "go" at the very start (earlier indices + word boundary) beats the same
      // letters appearing later in the string.
      final atStart = fuzzyScore('go', 'Go to Review')!;
      final later = fuzzyScore('go', 'A long goal')!;
      expect(atStart, greaterThan(later));
    });
  });

  group('workflowStageStateProvider', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      // Production launches with NO sheets (A1); the Calibrate stage keys off a
      // calibrated sheet, so seed the demo sheets (s1/s2/s3) as the stepper's
      // subjects (uncalibrated at seed — the tests calibrate as needed).
      seedDemoSheets(c);
      return c;
    }

    test('fresh project: only Floors done (3 default floors), active=Calibrate',
        () {
      final c = makeContainer();
      final s = c.read(workflowStageStateProvider);
      // The default project ships with 3 floors → Floors is done.
      expect(s.isDone(WorkflowStage.floors), isTrue);
      // Demo sheets are uncalibrated; nothing drawn or sized.
      expect(s.isDone(WorkflowStage.calibrate), isFalse);
      expect(s.isDone(WorkflowStage.draw), isFalse);
      expect(s.isDone(WorkflowStage.size), isFalse);
      expect(s.isDone(WorkflowStage.report), isFalse);
      // The first not-done stage is the active one.
      expect(s.active, WorkflowStage.calibrate);
    });

    test('calibrating a sheet marks Calibrate done and advances active', () {
      final c = makeContainer();
      // The default demo sheet ids include 's1'; calibrate that.
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
      final s = c.read(workflowStageStateProvider);
      expect(s.isDone(WorkflowStage.calibrate), isTrue);
      // Floors already done, calibrate now done → active is Draw.
      expect(s.active, WorkflowStage.draw);
    });

    test('drawing an edge marks Draw + Size done; Report needs a real export',
        () {
      final c = makeContainer();
      final net = c.read(networkControllerProvider.notifier);
      net.setService(ServiceType.coldWater);
      net.setTool(DrawTool.drawRun);
      net.placeRunPoint('s1', 0, const Offset(100, 100));
      net.placeRunPoint('s1', 0, const Offset(300, 100));
      net.setTool(DrawTool.select);
      // The network now has an edge; sizingProvider sizes it.
      expect(
          c.read(networkControllerProvider).network.edges, isNotEmpty);
      final s = c.read(workflowStageStateProvider);
      expect(s.isDone(WorkflowStage.draw), isTrue);
      expect(s.isDone(WorkflowStage.size), isTrue);
      // Report must NOT claim completion off the same predicate as Size — it
      // is done only once a deliverable has actually been exported.
      expect(s.isDone(WorkflowStage.report), isFalse);
      c.read(reportExportedProvider.notifier).markExported();
      expect(
          c.read(workflowStageStateProvider).isDone(WorkflowStage.report),
          isTrue);
    });

    test('single-floor building: Floors NOT done', () {
      final c = makeContainer();
      c
          .read(projectControllerProvider.notifier)
          .setFloors(const [Floor('Only', Length(3.0))]);
      final s = c.read(workflowStageStateProvider);
      expect(s.isDone(WorkflowStage.floors), isFalse);
      // With nothing else done, the first not-done stage is Calibrate.
      expect(s.active, WorkflowStage.calibrate);
    });
  });
}
