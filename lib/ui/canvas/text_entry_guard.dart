import 'package:flutter/widgets.dart';

/// True when the primary focus sits inside an [EditableText] — i.e. the user
/// is typing in a text field. Destructive/selection canvas shortcuts
/// (Delete/Backspace, Ctrl+A/C/V/Z/Y…) must then be left to the field and the
/// framework's DefaultTextEditingShortcuts, never applied to the drawing.
///
/// Shared by the Layout, electrical and schematic canvases so the three key
/// handlers agree on one definition of "the keyboard belongs to a text field".
bool isTextEntryFocused() {
  final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorStateOfType<EditableTextState>() != null;
}
