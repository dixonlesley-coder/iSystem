import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';

/// J2 — the first-auto-size session nudge. `firstAutoSizeNudgeProvider` is the
/// guard a `ref.listen(sizingProvider, ...)` in `AppShell` calls into (see
/// `lib/ui/app_shell.dart`); this test drives the guard directly (pure
/// Notifier logic, no widget tree needed) since the transition-detection is
/// already `ref.listen`'s job, not this provider's.
void main() {
  group('firstAutoSizeNudgeProvider', () {
    test('fires the confirmation once per session on the first non-zero count',
        () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(statusMessageProvider), isNull);
      expect(container.read(firstAutoSizeNudgeProvider), isFalse);

      container.read(firstAutoSizeNudgeProvider.notifier).maybeFire(5);

      expect(container.read(firstAutoSizeNudgeProvider), isTrue);
      expect(
        container.read(statusMessageProvider),
        'Auto-sized 5 runs - sizes shown on the plan',
      );
    });

    test('does not re-fire on a second call, even with a different count', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(firstAutoSizeNudgeProvider.notifier).maybeFire(3);
      expect(
        container.read(statusMessageProvider),
        'Auto-sized 3 runs - sizes shown on the plan',
      );

      // Clear the message so the assertion below proves the second call is a
      // true no-op, not just re-setting an identical string.
      container.read(statusMessageProvider.notifier).clear();
      container.read(firstAutoSizeNudgeProvider.notifier).maybeFire(9);

      expect(container.read(statusMessageProvider), isNull);
    });

    test('a zero count is a no-op and does not consume the one-shot', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(firstAutoSizeNudgeProvider.notifier).maybeFire(0);
      expect(container.read(firstAutoSizeNudgeProvider), isFalse);
      expect(container.read(statusMessageProvider), isNull);

      // The guard is still armed: the next genuine call still fires.
      container.read(firstAutoSizeNudgeProvider.notifier).maybeFire(2);
      expect(container.read(firstAutoSizeNudgeProvider), isTrue);
      expect(
        container.read(statusMessageProvider),
        'Auto-sized 2 runs - sizes shown on the plan',
      );
    });
  });
}
