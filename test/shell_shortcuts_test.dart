/// The pure accelerator table (`ui/shell/shell_shortcuts.dart`): WHICH key
/// means WHAT, with no widget tree. The shell only dispatches what this table
/// resolves, so pinning it here pins the app's whole keyboard contract.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/shell/shell_shortcuts.dart';

ShellCommand? match(LogicalKeyboardKey key,
        {bool mod = true, bool shift = false, bool alt = false}) =>
    matchShellShortcut(key, mod: mod, shift: shift, alt: alt);

void main() {
  test('the standard document-app file commands are bound', () {
    expect(match(LogicalKeyboardKey.keyN), ShellCommand.newProject);
    expect(match(LogicalKeyboardKey.keyO), ShellCommand.openProject);
    expect(match(LogicalKeyboardKey.keyS), ShellCommand.save);
    expect(match(LogicalKeyboardKey.keyS, shift: true), ShellCommand.saveAs);
    expect(match(LogicalKeyboardKey.keyI), ShellCommand.importPlan);
    expect(match(LogicalKeyboardKey.keyP), ShellCommand.printPlan);
  });

  test('undo / redo answer to both redo conventions', () {
    expect(match(LogicalKeyboardKey.keyZ), ShellCommand.undo);
    expect(match(LogicalKeyboardKey.keyY), ShellCommand.redo);
    expect(match(LogicalKeyboardKey.keyZ, shift: true), ShellCommand.redo);
  });

  test('the palette keeps Ctrl+K and gains the Ctrl+Shift+P alias; F1 opens '
      'the shortcuts sheet with no modifier', () {
    expect(match(LogicalKeyboardKey.keyK), ShellCommand.commandPalette);
    expect(match(LogicalKeyboardKey.keyP, shift: true),
        ShellCommand.commandPalette);
    expect(match(LogicalKeyboardKey.f1, mod: false), ShellCommand.shortcutsHelp);
    // F1 is a bare-key binding: with a modifier held it is NOT the help key.
    expect(match(LogicalKeyboardKey.f1), isNull);
  });

  test('Ctrl+1..8 select the nav destinations in rail order (numpad too)', () {
    const digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
    ];
    const numpad = [
      LogicalKeyboardKey.numpad1,
      LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpad6,
      LogicalKeyboardKey.numpad7,
      LogicalKeyboardKey.numpad8,
    ];
    expect(kGoToByDigit, hasLength(digits.length));
    for (var i = 0; i < digits.length; i++) {
      expect(match(digits[i]), kGoToByDigit[i]);
      expect(match(numpad[i]), kGoToByDigit[i]);
    }
    expect(match(LogicalKeyboardKey.comma), ShellCommand.goPreferences);
  });

  test('the canvas zoom family is deliberately NOT claimed globally', () {
    // Ctrl +/-/0 belong to CanvasView (zoom in / out / actual size). If the
    // shell swallowed them pre-focus the canvas would never see them.
    for (final k in [
      LogicalKeyboardKey.equal,
      LogicalKeyboardKey.minus,
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.numpadAdd,
      LogicalKeyboardKey.numpadSubtract,
    ]) {
      expect(match(k), isNull, reason: '$k must stay with the canvas');
    }
    // So do the selection combos, which are scoped to the focused canvas.
    for (final k in [
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.delete,
      LogicalKeyboardKey.escape,
    ]) {
      expect(match(k), isNull, reason: '$k must stay with the canvas');
    }
  });

  test('Alt never matches — AltGr reports as Ctrl+Alt and must keep typing '
      'real characters on an ID / EU layout', () {
    for (final k in [
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyZ,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.f1,
    ]) {
      expect(match(k, alt: true), isNull);
      expect(match(k, mod: false, alt: true), isNull);
    }
  });

  test('a bare letter is never a global accelerator (the canvas tool keys)', () {
    for (final k in [
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyR,
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.keyO,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.digit1,
    ]) {
      expect(match(k, mod: false), isNull, reason: '$k must reach the canvas');
    }
  });

  test('only undo / redo defer to a focused text field', () {
    for (final c in ShellCommand.values) {
      final expected = c == ShellCommand.undo || c == ShellCommand.redo;
      expect(c.deferToTextField, expected, reason: '$c');
    }
  });

  test('the shortcuts sheet documents every global command, and every keycap '
      'it advertises really resolves to that command', () {
    final documented = <ShellCommand>{};
    for (final group in kShellShortcutGroups) {
      for (final doc in group.shortcuts) {
        expect(doc.command, isNotNull,
            reason: 'a global group must carry its command: ${doc.keys}');
        documented.add(doc.command!);
        expect(_resolve(doc.keys), doc.command,
            reason: '"${doc.keys}" (${doc.label}) must really do that');
      }
    }
    expect(documented, ShellCommand.values.toSet(),
        reason: 'no global command may be undocumented');
    // The canvas groups document bindings owned by a canvas key handler, so
    // they carry no ShellCommand (and must not claim one).
    for (final group in kCanvasShortcutGroups) {
      for (final doc in group.shortcuts) {
        expect(doc.command, isNull, reason: doc.keys);
      }
    }
  });
}

/// Parse a documented keycap ("Ctrl Shift S") back through the real matcher, so
/// the sheet can never advertise a binding the app doesn't answer to.
ShellCommand? _resolve(String keys) {
  final parts = keys.split(' ');
  final mod = parts.contains('Ctrl');
  final shift = parts.contains('Shift');
  const byToken = <String, LogicalKeyboardKey>{
    'F1': LogicalKeyboardKey.f1,
    ',': LogicalKeyboardKey.comma,
    'I': LogicalKeyboardKey.keyI,
    'K': LogicalKeyboardKey.keyK,
    'N': LogicalKeyboardKey.keyN,
    'O': LogicalKeyboardKey.keyO,
    'P': LogicalKeyboardKey.keyP,
    'S': LogicalKeyboardKey.keyS,
    'Y': LogicalKeyboardKey.keyY,
    'Z': LogicalKeyboardKey.keyZ,
    '1': LogicalKeyboardKey.digit1,
    '2': LogicalKeyboardKey.digit2,
    '3': LogicalKeyboardKey.digit3,
    '4': LogicalKeyboardKey.digit4,
    '5': LogicalKeyboardKey.digit5,
    '6': LogicalKeyboardKey.digit6,
    '7': LogicalKeyboardKey.digit7,
    '8': LogicalKeyboardKey.digit8,
  };
  final key = byToken[parts.last];
  expect(key, isNotNull, reason: 'unknown keycap token "${parts.last}"');
  return matchShellShortcut(key!, mod: mod, shift: shift, alt: false);
}
