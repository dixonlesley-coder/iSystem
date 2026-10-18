import 'dart:io';

/// A cheap identity stamp for the file at [path] — `size:mtime(µs)` — or null
/// when the file does not exist / cannot be stat'ed.
String? fileStamp(String path) {
  try {
    final st = File(path).statSync();
    if (st.type == FileSystemEntityType.notFound) return null;
    return '${st.size}:${st.modified.microsecondsSinceEpoch}';
  } catch (_) {
    return null;
  }
}

/// A process-lifetime parse cache keyed by file PATH **and** the file's
/// [fileStamp] (Round 10, import-pipeline-2). A path-only key served the
/// previous revision forever when a plan was overwritten in place (an
/// architect's rev2 at the same path, or every DWG re-conversion landing at
/// the same cache path) — the canvas painted rev1 squashed into rev2's frame
/// while Save embedded rev2. A changed size/mtime now re-parses.
class FileStampedCache<T> {
  final T Function(String path) _load;
  final Map<String, (String?, T)> _entries = {};

  FileStampedCache(this._load);

  /// The cached value for [path], re-loading when the file's stamp changed.
  T get(String path) {
    final stamp = fileStamp(path);
    final hit = _entries[path];
    if (hit != null && hit.$1 == stamp) return hit.$2;
    final value = _load(path);
    _entries[path] = (stamp, value);
    return value;
  }

  /// Prime [path] with [value] against the file's CURRENT stamp (a test seam:
  /// a non-existent path primes against a null stamp and stays a hit).
  void prime(String path, T value) => _entries[path] = (fileStamp(path), value);

  /// Drop [path]'s entry (or every entry).
  void evict(String path) => _entries.remove(path);
  void clear() => _entries.clear();
}
