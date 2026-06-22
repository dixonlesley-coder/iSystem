import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/canvas/viewport.dart';
import 'models/sheet.dart';

/// Immutable sheet-navigation state: the loaded [sheets], the [currentIndex],
/// and a per-sheet [viewports] map so each sheet's pan/zoom is restored when
/// you switch back to it (§4 viewport restore). Disk persistence of this state
/// lands with the project-file / drift layer.
@immutable
class SheetsState {
  final List<Sheet> sheets;
  final int currentIndex;
  final Map<String, ViewportTransform> viewports;

  const SheetsState({
    this.sheets = const [],
    this.currentIndex = 0,
    this.viewports = const {},
  });

  bool get isEmpty => sheets.isEmpty;

  Sheet? get current =>
      sheets.isEmpty ? null : sheets[currentIndex.clamp(0, sheets.length - 1)];

  /// Stored viewport for [sheetId], or `null` if it hasn't been framed yet
  /// (the canvas will fit-to-view on first show).
  ViewportTransform? viewportFor(String sheetId) => viewports[sheetId];

  SheetsState copyWith({
    List<Sheet>? sheets,
    int? currentIndex,
    Map<String, ViewportTransform>? viewports,
  }) =>
      SheetsState(
        sheets: sheets ?? this.sheets,
        currentIndex: currentIndex ?? this.currentIndex,
        viewports: viewports ?? this.viewports,
      );
}

class SheetsController extends Notifier<SheetsState> {
  // Placeholder sheets so P0 demonstrates multi-sheet navigation before PDF
  // import (P1) replaces them.
  static const List<Sheet> _demoSheets = [
    Sheet(id: 's1', name: 'Ground Floor', sizePx: Size(1684, 1190)),
    Sheet(id: 's2', name: 'First Floor', sizePx: Size(1684, 1190)),
    Sheet(id: 's3', name: 'Roof Plan', sizePx: Size(1190, 1684)),
  ];

  @override
  SheetsState build() => const SheetsState(sheets: _demoSheets);

  void loadSheets(List<Sheet> sheets) =>
      state = SheetsState(sheets: sheets, currentIndex: 0, viewports: const {});

  void selectSheet(int index) {
    if (index < 0 || index >= state.sheets.length || index == state.currentIndex) {
      return;
    }
    state = state.copyWith(currentIndex: index);
  }

  void selectSheetById(String id) {
    final i = state.sheets.indexWhere((s) => s.id == id);
    if (i != -1) selectSheet(i);
  }

  /// Persist a sheet's pan/zoom so it restores on return.
  void setViewport(String sheetId, ViewportTransform transform) {
    if (state.viewports[sheetId] == transform) return;
    final next = Map<String, ViewportTransform>.from(state.viewports)
      ..[sheetId] = transform;
    state = state.copyWith(viewports: next);
  }

  void addSheet(Sheet sheet) =>
      state = state.copyWith(sheets: [...state.sheets, sheet]);
}

final sheetsControllerProvider =
    NotifierProvider<SheetsController, SheetsState>(SheetsController.new);
