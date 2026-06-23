import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the right-side inspector (the [ProjectPanel] / electrical Loads
/// column) is collapsed to a thin toggle strip, freeing the canvas to dominate
/// the workspace. Defaults to EXPANDED (the full panel) so a fresh launch — and
/// the golden-screenshot test, which does not touch this — keeps the inspector
/// visible.
final inspectorCollapsedProvider =
    NotifierProvider<InspectorCollapsedController, bool>(
  InspectorCollapsedController.new,
);

class InspectorCollapsedController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void set(bool collapsed) => state = collapsed;
}
