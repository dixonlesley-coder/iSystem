import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/network_store.dart';
import '../store/project_store.dart';
import '../store/sheets_store.dart';
import 'project_document.dart';
import 'recovery.dart';

/// A recovery document found on launch (previous session ended without a clean
/// exit). Non-null ⇒ the shell offers to restore it.
final recoveryDocProvider =
    NotifierProvider<RecoveryController, ProjectDocument?>(
  RecoveryController.new,
);

class RecoveryController extends Notifier<ProjectDocument?> {
  @override
  ProjectDocument? build() => null;

  void set(ProjectDocument? doc) => state = doc;
  void clear() => state = null;
}

/// Build a [ProjectDocument] from the current live state in [c].
ProjectDocument buildDocument(ProviderContainer c) {
  final project = c.read(projectControllerProvider);
  final sheets = c.read(sheetsControllerProvider);
  final network = c.read(networkControllerProvider).network;
  return ProjectDocument(
    projectName: project.name,
    floors: project.floors,
    calibrations: project.calibrations,
    sheets: sheets.sheets,
    network: network,
    viewports: sheets.viewports,
  );
}

/// Start the periodic autosave loop: every [interval], snapshot the current
/// work to the recovery file (only once there's a drawn network worth saving).
/// Returns the timer so the caller can cancel it.
Timer startAutosave(
  ProviderContainer c, {
  Duration interval = const Duration(seconds: 15),
}) {
  return Timer.periodic(interval, (_) {
    final network = c.read(networkControllerProvider).network;
    if (network.nodes.isEmpty) return; // nothing worth recovering yet
    writeRecovery(buildDocument(c));
  });
}
