/// Pure, framework-free English pluralization helper.
///
/// Replaces the dev-speak `"run(s)"` / `"finding(s)"` / `"line(s)"` forms the
/// Apple design review (H2) flagged: the caller passes the singular and plural
/// nouns and gets the correct one for [n]. English-only word selection —
/// Bahasa Indonesia has no plural inflection (the ID strings already use the
/// singular noun), so ID callers simply pass the same word for both.
///
/// No Flutter import: this is plain Dart so it is unit-testable in isolation.
library;

/// Returns [one] when [n] is exactly 1, otherwise [many].
///
/// ```dart
/// plural(1, 'run', 'runs'); // 'run'
/// plural(3, 'run', 'runs'); // 'runs'
/// plural(0, 'run', 'runs'); // 'runs'
/// ```
String plural(int n, String one, String many) => n == 1 ? one : many;

/// Convenience: the count prefixed to the correct noun, e.g.
/// `pluralCount(3, 'run', 'runs')` -> `'3 runs'`.
String pluralCount(int n, String one, String many) =>
    '$n ${plural(n, one, many)}';
