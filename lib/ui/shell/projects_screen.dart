import 'package:flutter/widgets.dart';

import '../widgets/hub_scaffold.dart';

/// Projects landing. The app's open/save flows live in the top bar (file
/// pickers); this is the durable home for a project browser/recents list, which
/// arrives in a later wave.
class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const HubScaffold(
      title: 'Projects',
      lead: 'Open and save projects from the top bar for now. A recent-projects '
          'browser will live here.',
      children: [
        HubNote(
          'Use Open in the top bar to load a .mechx file, or Save to write the '
          'current project. Autosave keeps a recovery snapshot between sessions.',
        ),
      ],
    );
  }
}
