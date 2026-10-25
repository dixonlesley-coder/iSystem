/// Safe file-name stems for every exported deliverable (Round 13,
/// export-files-1). Pure.
///
/// A project or sheet name goes into every exported FILE name, but it is
/// free text: `Ruko A/B` made the submittal write target a non-existent
/// sub-folder and throw (zero files, or a half-written folder), and on
/// Windows — the only shipped target — `:` turns the name into an NTFS
/// alternate data stream while `"` `?` `*` `<` `>` `|` are rejected by
/// Win32. The RAW name keeps printing in title blocks; only the FILE name is
/// sanitised.
library;

final RegExp _illegal = RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]');

/// Windows device names that cannot be a file stem (case-insensitive, with or
/// without an extension).
final RegExp _reserved =
    RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$', caseSensitive: false);

/// [raw] made safe as a Windows / POSIX file-name stem: every character
/// illegal in a Win32 file name (`\ / : * ? " < > |` and control characters)
/// becomes `_`, surrounding spaces are trimmed, trailing dots / spaces are
/// dropped (Win32 strips them silently, so two names could collide), a
/// reserved device name (`CON`, `NUL`, `COM1` …) gets a `_` prefix, and an
/// empty result falls back to [fallback]. A name that is already safe is
/// returned unchanged (byte-identical file names).
String safeFileStem(String raw, {String fallback = 'project'}) {
  var s = raw.replaceAll(_illegal, '_').trim();
  while (s.isNotEmpty && (s.endsWith('.') || s.endsWith(' '))) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return fallback;
  if (_reserved.hasMatch(s)) s = '_$s';
  return s;
}
