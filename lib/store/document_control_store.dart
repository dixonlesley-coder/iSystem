/// Riverpod store for document control — the issuable-sheet identity that
/// feeds every report head, the PDF/DXF title blocks, and a drawings register:
/// document/drawing number, current revision tag, client name, and the
/// preparer/checker/approver names (a DRAWN/CHECKED/APPROVED block), plus the
/// revision history table.
///
/// The state is owned here (mutable) and persisted with the project via the
/// matching `DesignSettings` fields (`applyDocument` calls [set] on load,
/// `buildDocument` reads the state), mirroring `commercial_store.dart`'s shape.
///
/// Default build() ⇒ all fields unset / no revisions, so a project that has
/// never touched document control is byte-identical to before this feature.
library;

import 'package:flutter/widgets.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/standards/sni.dart' show Revision;

import '../ui/strings/app_strings.dart';
import 'app_state.dart' show localeProvider;
import 'history_store.dart' show SettingsUndoEntry, settingsHistoryProvider;

/// The user-editable document-control identity. Immutable; the controller
/// replaces it on every edit.
@immutable
class DocumentControl {
  final String? documentNumber;
  final String? revisionTag;
  final String? clientName;
  final String? preparedBy;
  final String? checkedBy;
  final String? approvedBy;

  /// The revision history (date + description), oldest-first — the same
  /// `Revision` value object the calc reports already render.
  final List<Revision> revisions;

  const DocumentControl({
    this.documentNumber,
    this.revisionTag,
    this.clientName,
    this.preparedBy,
    this.checkedBy,
    this.approvedBy,
    this.revisions = const [],
  });

  /// A copy with [revisions] replaced. The six identity fields are NOT covered
  /// here (unlike `CommercialSettings.copyWith`): each is independently
  /// nullable, so a plain `field ?? this.field` copyWith couldn't distinguish
  /// "leave unchanged" from "clear to null" — the string setters below build
  /// the replacement directly instead.
  DocumentControl copyWithRevisions(List<Revision> revisions) => DocumentControl(
        documentNumber: documentNumber,
        revisionTag: revisionTag,
        clientName: clientName,
        preparedBy: preparedBy,
        checkedBy: checkedBy,
        approvedBy: approvedBy,
        revisions: revisions,
      );
}

/// The mutable document-control identity. Edited by a future "Document
/// control" inspector card; loaded / saved with the project via
/// [DesignSettings]'s matching fields.
final documentControlProvider =
    NotifierProvider<DocumentControlController, DocumentControl>(
  DocumentControlController.new,
);

class DocumentControlController extends Notifier<DocumentControl> {
  @override
  DocumentControl build() => const DocumentControl();

  /// Replace the whole value (used by `applyDocument` on load).
  void set(DocumentControl value) => state = value;

  /// Round 28 (persist-undo-2-3) — every user edit is persisted in `.mechx`
  /// and printed on every issued sheet, so it records ONE
  /// [UndoDomain.settings] step on the global timeline (a registered revert
  /// pair), like an acknowledgement; an equal-value edit records nothing.
  /// Ctrl+Z after a document-control edit used to revert an older, unrelated
  /// design setting instead. [set] (load / new document) stays non-recording.
  void _commit(DocumentControl next) {
    final previous = state;
    if (_signature(previous) == _signature(next)) return;
    state = next;
    ref.read(settingsHistoryProvider.notifier).record(SettingsUndoEntry(
          label: MechXStringsData(ref.read(localeProvider))(
              StringKey.undoLabelDocumentControl),
          undo: () => state = previous,
          redo: () => state = next,
        ));
  }

  static String _signature(DocumentControl d) => [
        d.documentNumber,
        d.revisionTag,
        d.clientName,
        d.preparedBy,
        d.checkedBy,
        d.approvedBy,
        for (final r in d.revisions) '${r.date}\u0001${r.description}',
      ].join('\u0000');

  /// Set / clear the document number. An empty/whitespace string clears it
  /// (stored as null, matching the persisted "absent ⇒ null" contract).
  void setDocumentNumber(String? value) => _commit(DocumentControl(
        documentNumber: _normalize(value),
        revisionTag: state.revisionTag,
        clientName: state.clientName,
        preparedBy: state.preparedBy,
        checkedBy: state.checkedBy,
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      ));

  void setRevisionTag(String? value) => _commit(DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: _normalize(value),
        clientName: state.clientName,
        preparedBy: state.preparedBy,
        checkedBy: state.checkedBy,
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      ));

  void setClientName(String? value) => _commit(DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: state.revisionTag,
        clientName: _normalize(value),
        preparedBy: state.preparedBy,
        checkedBy: state.checkedBy,
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      ));

  void setPreparedBy(String? value) => _commit(DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: state.revisionTag,
        clientName: state.clientName,
        preparedBy: _normalize(value),
        checkedBy: state.checkedBy,
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      ));

  void setCheckedBy(String? value) => _commit(DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: state.revisionTag,
        clientName: state.clientName,
        preparedBy: state.preparedBy,
        checkedBy: _normalize(value),
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      ));

  void setApprovedBy(String? value) => _commit(DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: state.revisionTag,
        clientName: state.clientName,
        preparedBy: state.preparedBy,
        checkedBy: state.checkedBy,
        approvedBy: _normalize(value),
        revisions: state.revisions,
      ));

  /// Append one revision row (date + description) to the history.
  void addRevision(String date, String description) {
    _commit(state.copyWithRevisions(
        [...state.revisions, Revision(date, description)]));
  }

  /// Remove the revision at [index] (no-op if out of range).
  void removeRevisionAt(int index) {
    if (index < 0 || index >= state.revisions.length) return;
    final next = [...state.revisions]..removeAt(index);
    _commit(state.copyWithRevisions(next));
  }

  /// `copyWith` only overrides a field when the new value is non-null, so a
  /// null-clearing setter needs its own path: normalize an empty/whitespace
  /// string to null, otherwise pass the trimmed value through.
  static String? _normalize(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
