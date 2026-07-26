/// The app-wide keyboard accelerator TABLE — the "normal controls" a desktop
/// authoring tool is expected to answer to (Ctrl+N new, Ctrl+S save, Ctrl+O
/// open, Ctrl+Z undo, …), plus the reference list that documents every binding
/// for the Keyboard-shortcuts sheet.
///
/// PURE by design: [matchShellShortcut] maps a key + modifier state to a
/// [ShellCommand] with no widget tree, no providers and no side effects, so the
/// whole accelerator table is unit-testable. `app_shell.dart` owns the dispatch
/// (it holds the live [WidgetRef]); this file owns WHICH key means WHAT.
///
/// Two rules keep the table safe to run PRE-focus (the shell registers it on
/// [HardwareKeyboard], ahead of focus dispatch):
///  • Alt is never part of a binding. On Windows AltGr reports as Ctrl+Alt, so
///    swallowing `Ctrl+Alt+<key>` would eat real characters on an ID/EU layout.
///  • [deferToTextField] marks the combos a focused text field owns (undo /
///    redo), which the shell must let fall through to the field's own editing
///    shortcuts rather than applying to the drawing.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One globally-accelerated app command.
enum ShellCommand {
  // — File —
  newProject,
  openProject,
  save,
  saveAs,
  importPlan,
  printPlan,
  // — Edit —
  undo,
  redo,
  // — Find / help —
  commandPalette,
  shortcutsHelp,
  // — Go to (the nav-rail destinations, in rail order) —
  goLayout,
  goRiser,
  goElectrical,
  goBuilding,
  goReview,
  goCommercial,
  goProjects,
  goPreferences,
}

extension ShellCommandBehaviour on ShellCommand {
  /// Whether a focused text field owns this combo. Undo/redo inside a field
  /// must edit the FIELD (the framework's `DefaultTextEditingShortcuts`), never
  /// the drawing — so the shell stands down and lets the event flow on.
  ///
  /// Everything else (Ctrl+S, Ctrl+N, Ctrl+1…) is not a text-editing key, so it
  /// stays live while typing — exactly as it does in every desktop editor.
  bool get deferToTextField =>
      this == ShellCommand.undo || this == ShellCommand.redo;
}

/// The nav destination each `Ctrl+<digit>` selects, in nav-rail order:
/// 1 Layout · 2 Riser · 3 Electrical · 4 Building · 5 Review · 6 Commercial ·
/// 7 Projects · 8 Preferences.
const List<ShellCommand> kGoToByDigit = [
  ShellCommand.goLayout,
  ShellCommand.goRiser,
  ShellCommand.goElectrical,
  ShellCommand.goBuilding,
  ShellCommand.goReview,
  ShellCommand.goCommercial,
  ShellCommand.goProjects,
  ShellCommand.goPreferences,
];

/// The 1-based digit (and its numpad twin) that selects the Nth destination.
const List<LogicalKeyboardKey> _digitKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
];
const List<LogicalKeyboardKey> _numpadDigitKeys = [
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5,
  LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7,
  LogicalKeyboardKey.numpad8,
];

/// Resolve a key press to the app command it triggers, or null when the press
/// is not an app accelerator (and must flow on to the focused widget).
///
/// [mod] is the platform command modifier — Ctrl on Windows/Linux, Cmd on
/// macOS — as the shell already computes it. [alt] presses NEVER match (AltGr).
ShellCommand? matchShellShortcut(
  LogicalKeyboardKey key, {
  required bool mod,
  required bool shift,
  required bool alt,
}) {
  if (alt) return null;
  // The one bare-key binding: F1 is the universal "help" key, and the app has
  // no other use for it.
  if (!mod && !shift && key == LogicalKeyboardKey.f1) {
    return ShellCommand.shortcutsHelp;
  }
  if (!mod) return null;

  if (shift) {
    // Shift+<mod> variants first, so plain Ctrl+S / Ctrl+Z can't swallow them.
    if (key == LogicalKeyboardKey.keyS) return ShellCommand.saveAs;
    if (key == LogicalKeyboardKey.keyZ) return ShellCommand.redo;
    // The VS Code muscle-memory alias for the palette, beside Ctrl+K.
    if (key == LogicalKeyboardKey.keyP) return ShellCommand.commandPalette;
    return null;
  }

  if (key == LogicalKeyboardKey.keyN) return ShellCommand.newProject;
  if (key == LogicalKeyboardKey.keyO) return ShellCommand.openProject;
  if (key == LogicalKeyboardKey.keyS) return ShellCommand.save;
  if (key == LogicalKeyboardKey.keyI) return ShellCommand.importPlan;
  if (key == LogicalKeyboardKey.keyP) return ShellCommand.printPlan;
  if (key == LogicalKeyboardKey.keyZ) return ShellCommand.undo;
  if (key == LogicalKeyboardKey.keyY) return ShellCommand.redo;
  if (key == LogicalKeyboardKey.keyK) return ShellCommand.commandPalette;
  if (key == LogicalKeyboardKey.comma) return ShellCommand.goPreferences;

  for (var i = 0; i < kGoToByDigit.length; i++) {
    if (key == _digitKeys[i] || key == _numpadDigitKeys[i]) {
      return kGoToByDigit[i];
    }
  }
  return null;
}

// ── The reference list (documentation, not dispatch) ────────────────────────

/// A documented binding, shown in the Keyboard-shortcuts sheet. [keys] is plain
/// ASCII, Windows-first ("Ctrl Shift S") so it can never render as tofu in the
/// bundled Roboto (see the CLAUDE.md watch-out).
@immutable
class ShortcutDoc {
  /// The key combination, e.g. `'Ctrl N'`.
  final String keys;

  /// What it does, e.g. `'New project'`.
  final String label;

  /// The app command, for the shell-level bindings; null for the bindings that
  /// live in a canvas key handler rather than the global table.
  final ShellCommand? command;

  const ShortcutDoc(this.keys, this.label, [this.command]);
}

/// A titled block of bindings in the shortcuts sheet.
@immutable
class ShortcutGroup {
  final String title;
  final List<ShortcutDoc> shortcuts;

  const ShortcutGroup(this.title, this.shortcuts);
}

/// Every GLOBAL accelerator, grouped for display. Pinned by a test against
/// [matchShellShortcut] so the sheet can never advertise a key the app doesn't
/// actually answer to (nor omit one it does).
const List<ShortcutGroup> kShellShortcutGroups = [
  ShortcutGroup('File', [
    ShortcutDoc('Ctrl N', 'New project', ShellCommand.newProject),
    ShortcutDoc('Ctrl O', 'Open project', ShellCommand.openProject),
    ShortcutDoc('Ctrl S', 'Save', ShellCommand.save),
    ShortcutDoc('Ctrl Shift S', 'Save as...', ShellCommand.saveAs),
    ShortcutDoc('Ctrl I', 'Import plan (PDF / DXF / DWG)',
        ShellCommand.importPlan),
    ShortcutDoc('Ctrl P', 'Export the plan as PDF', ShellCommand.printPlan),
  ]),
  ShortcutGroup('Edit', [
    ShortcutDoc('Ctrl Z', 'Undo', ShellCommand.undo),
    ShortcutDoc('Ctrl Y', 'Redo', ShellCommand.redo),
    ShortcutDoc('Ctrl Shift Z', 'Redo', ShellCommand.redo),
  ]),
  ShortcutGroup('Find', [
    ShortcutDoc('Ctrl K', 'Command palette', ShellCommand.commandPalette),
    ShortcutDoc('Ctrl Shift P', 'Command palette',
        ShellCommand.commandPalette),
    ShortcutDoc('F1', 'Keyboard shortcuts', ShellCommand.shortcutsHelp),
  ]),
  ShortcutGroup('Go to', [
    ShortcutDoc('Ctrl 1', 'Layout', ShellCommand.goLayout),
    ShortcutDoc('Ctrl 2', 'Riser', ShellCommand.goRiser),
    ShortcutDoc('Ctrl 3', 'Electrical', ShellCommand.goElectrical),
    ShortcutDoc('Ctrl 4', 'Building', ShellCommand.goBuilding),
    ShortcutDoc('Ctrl 5', 'Review', ShellCommand.goReview),
    ShortcutDoc('Ctrl 6', 'Commercial', ShellCommand.goCommercial),
    ShortcutDoc('Ctrl 7', 'Projects', ShellCommand.goProjects),
    ShortcutDoc('Ctrl 8', 'Preferences', ShellCommand.goPreferences),
    ShortcutDoc('Ctrl ,', 'Preferences', ShellCommand.goPreferences),
  ]),
];

/// The CANVAS bindings — implemented in the Layout / Riser / Electrical key
/// handlers, not in the global table. Listed here so the shortcuts sheet is the
/// one place an engineer can learn the whole keyboard, rather than half of it.
const List<ShortcutGroup> kCanvasShortcutGroups = [
  ShortcutGroup('Drawing tools (Layout)', [
    ShortcutDoc('V', 'Select'),
    ShortcutDoc('R', 'Draw run'),
    ShortcutDoc('E', 'Draw riser'),
    ShortcutDoc('M', 'Measure'),
    ShortcutDoc('K', 'Tank area'),
    ShortcutDoc('B', 'Room area'),
    ShortcutDoc('O', 'Ortho on / off'),
    ShortcutDoc('1 - 9', "Pick the layer's Nth service"),
    ShortcutDoc('Enter', 'Repeat the last tool'),
    ShortcutDoc('Tab', 'Flip the route legs while drawing'),
    ShortcutDoc('Esc', 'Cancel / back out'),
  ]),
  ShortcutGroup('Selection (canvas)', [
    ShortcutDoc('Ctrl A', 'Select all on this floor'),
    ShortcutDoc('Ctrl C', 'Copy'),
    ShortcutDoc('Ctrl V', 'Paste'),
    ShortcutDoc('Delete', 'Delete the selection'),
    ShortcutDoc('Arrows', 'Nudge the selection'),
    ShortcutDoc('Shift R', 'Rotate the selection'),
    ShortcutDoc('Shift M', 'Mirror the selection'),
  ]),
  ShortcutGroup('View (canvas)', [
    ShortcutDoc('F', 'Fit the sheet'),
    ShortcutDoc('Ctrl +', 'Zoom in'),
    ShortcutDoc('Ctrl -', 'Zoom out'),
    ShortcutDoc('Ctrl 0', 'Actual size'),
    ShortcutDoc('Hold Space', 'Pan'),
    ShortcutDoc('Arrows', 'Pan (nothing selected)'),
  ]),
];
