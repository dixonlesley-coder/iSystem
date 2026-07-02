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

  /// Set / clear the document number. An empty/whitespace string clears it
  /// (stored as null, matching the persisted "absent ⇒ null" contract).
  void setDocumentNumber(String? value) => state = DocumentControl(
        documentNumber: _normalize(value),
        revisionTag: state.revisionTag,
        clientName: state.clientName,
        preparedBy: state.preparedBy,
        checkedBy: state.checkedBy,
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      );

  void setRevisionTag(String? value) => state = DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: _normalize(value),
        clientName: state.clientName,
        preparedBy: state.preparedBy,
        checkedBy: state.checkedBy,
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      );

  void setClientName(String? value) => state = DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: state.revisionTag,
        clientName: _normalize(value),
        preparedBy: state.preparedBy,
        checkedBy: state.checkedBy,
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      );

  void setPreparedBy(String? value) => state = DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: state.revisionTag,
        clientName: state.clientName,
        preparedBy: _normalize(value),
        checkedBy: state.checkedBy,
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      );

  void setCheckedBy(String? value) => state = DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: state.revisionTag,
        clientName: state.clientName,
        preparedBy: state.preparedBy,
        checkedBy: _normalize(value),
        approvedBy: state.approvedBy,
        revisions: state.revisions,
      );

  void setApprovedBy(String? value) => state = DocumentControl(
        documentNumber: state.documentNumber,
        revisionTag: state.revisionTag,
        clientName: state.clientName,
        preparedBy: state.preparedBy,
        checkedBy: state.checkedBy,
        approvedBy: _normalize(value),
        revisions: state.revisions,
      );

  /// Append one revision row (date + description) to the history.
  void addRevision(String date, String description) {
    state = state.copyWithRevisions([...state.revisions, Revision(date, description)]);
  }

  /// Remove the revision at [index] (no-op if out of range).
  void removeRevisionAt(int index) {
    if (index < 0 || index >= state.revisions.length) return;
    final next = [...state.revisions]..removeAt(index);
    state = state.copyWithRevisions(next);
  }

  /// `copyWith` only overrides a field when the new value is non-null, so a
  /// null-clearing setter needs its own path: normalize an empty/whitespace
  /// string to null, otherwise pass the trimmed value through.
  static String? _normalize(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
