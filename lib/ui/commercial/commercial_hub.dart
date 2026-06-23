import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/solve_store.dart';
import '../theme/design_tokens.dart';
import '../widgets/hub_scaffold.dart';

/// The Commercial hub — BOM, pricing and quotation live here.
///
/// For this pass it surfaces the existing bill of materials count and points at
/// the CSV export already wired into the app; the priced quotation UI arrives in
/// a later wave. This is the durable shell PanelMaker's "Commercial" group maps
/// onto.
class CommercialHub extends ConsumerWidget {
  const CommercialHub({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bom = ref.watch(bomProvider);
    final fittings = ref.watch(fittingsProvider);

    return HubScaffold(
      title: 'Commercial',
      lead: 'Bill of materials, pricing and the proposal come together here. '
          'The priced quotation is on the way; the BOM is already live.',
      children: [
        HubStatRow(
          stats: [
            ('BOM lines', '${bom.length}'),
            ('Fitting lines', '${fittings.length}'),
          ],
        ),
        const SizedBox(height: MechXSpacing.lg),
        const HubNote(
          'Export the bill of materials as CSV from the BOM panel for takeoff '
          'and costing in your spreadsheet of choice.',
        ),
      ],
    );
  }
}
