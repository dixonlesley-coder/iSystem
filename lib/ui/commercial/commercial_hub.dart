import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/report/csv_text.dart' show excelCsv;
import 'package:mechx_engine/report/mep_commercial.dart';

import '../../store/app_state.dart';
import '../../store/commercial_store.dart';
import '../../store/project_store.dart';
import '../inspector/project_panel.dart'
    show pickExportSave, reportStringsFor, runExportGuarded;
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';
import 'electrical_bom_view.dart';
import 'pricelist_screen.dart';
import 'quotation_view.dart';

/// The Commercial workspace — the mechanical + electrical BOMs, the pricelist
/// editor and the unified M+E+P priced quotation, with CSV / Markdown export.
/// Built over the pure engine commercial pipeline (BOM → cost → quotation);
/// prices live with the project, never the catalogue.
class CommercialHub extends ConsumerStatefulWidget {
  const CommercialHub({super.key});

  @override
  ConsumerState<CommercialHub> createState() => _CommercialHubState();
}

class _CommercialHubState extends ConsumerState<CommercialHub> {
  @override
  Widget build(BuildContext context) {
    // The SAME hub frame as Review / Projects / Building (HubScaffold, one
    // 720-px column): its own 920-px column used to start the title ~100 px
    // left of every other hub's, so switching hubs made the page jump.
    return HubScaffold(
      title: context.strings(StringKey.commercialHubTitle),
      lead: context.strings(StringKey.commercialHubLead),
      children: const [
        _ExportBar(),
        SizedBox(height: MechXSpacing.lg),
        MechanicalBomView(),
        SizedBox(height: MechXSpacing.xl),
        ElectricalBomView(),
        SizedBox(height: MechXSpacing.xl),
        PricelistScreen(),
        SizedBox(height: MechXSpacing.xl),
        QuotationView(),
      ],
    );
  }
}

/// The CSV / Markdown export actions for the commercial documents.
class _ExportBar extends ConsumerWidget {
  const _ExportBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: MechXSpacing.sm,
      runSpacing: MechXSpacing.sm,
      children: [
        MechXButton(
          label: context.strings(StringKey.commercialExportBomCsv),
          onPressed: () => exportMepBomCsv(ref),
        ),
        MechXButton(
          label: context.strings(StringKey.commercialExportProposalMd),
          primary: true,
          onPressed: () => exportMepProposalMarkdown(ref),
        ),
      ],
    );
  }
}

// Both commercial exports route through the shared export guard (H3): the
// zero-length completeness gate, cancel ⇒ no pill, success ⇒ the "Exported
// ..." confirmation, and an IO failure surfaces instead of no-oping.
// Public so the Export sheet (Ctrl/Cmd+E) lists the same two rows.
Future<void> exportMepBomCsv(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'MEP BOM',
      write: () async {
        final name = ref.read(projectControllerProvider).name;
        // The unified M+E+P BOM (mechanical pipe/duct + fittings, then the
        // electrical catalogue lines) in ONE CSV.
        final csv = mepBomToCsv(
          ref.read(mechanicalCostProvider),
          ref.read(electricalCostProvider),
        );
        final full = await pickExportSave(ref,
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleElectricalBom),
            fileName: '$name-mep-bom.csv',
            ext: 'csv');
        if (full == null) return false;
        await File(full).writeAsString(excelCsv(csv));
        return true;
      },
    );

Future<void> exportMepProposalMarkdown(WidgetRef ref) => runExportGuarded(
      ref,
      name: 'quotation proposal',
      write: () async {
        final name = ref.read(projectControllerProvider).name;
        // The unified M+E+P proposal — per-discipline BOM tables + the combined
        // costed roll-up.
        final md = mepQuotationToMarkdown(
          ref.read(mepQuotationProvider),
          mechanical: ref.read(mechanicalCostProvider),
          electrical: ref.read(electricalCostProvider),
          projectName: name,
          strings: reportStringsFor(ref),
        );
        final full = await pickExportSave(ref,
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
              StringKey.exportTitleElectricalProposal),
            fileName: '$name-mep-proposal.md',
            ext: 'md');
        if (full == null) return false;
        await File(full).writeAsString(md);
        return true;
      },
    );
