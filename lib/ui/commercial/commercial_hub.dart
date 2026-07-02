import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/commercial_export.dart';

import '../../store/app_state.dart';
import '../../store/commercial_store.dart';
import '../../store/project_store.dart';
import '../inspector/project_panel.dart' show runExportGuarded;
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import 'electrical_bom_view.dart';
import 'pricelist_screen.dart';
import 'quotation_view.dart';

/// The Commercial workspace — the electrical BOM, the pricelist editor and the
/// priced quotation, with CSV / Markdown export. Built over the pure engine
/// commercial pipeline (BOM → cost → quotation); prices live with the project,
/// never the catalogue.
class CommercialHub extends ConsumerWidget {
  const CommercialHub({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;

    return ColoredBox(
      color: colors.background,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MechXSpacing.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.strings(StringKey.commercialHubTitle),
                    style: type.display.copyWith(color: colors.textPrimary)),
                const SizedBox(height: MechXSpacing.sm),
                Text(
                  context.strings(StringKey.commercialHubLead),
                  style: type.body.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: MechXSpacing.lg),
                const _ExportBar(),
                const SizedBox(height: MechXSpacing.lg),
                const ElectricalBomView(),
                const SizedBox(height: MechXSpacing.xl),
                const PricelistScreen(),
                const SizedBox(height: MechXSpacing.xl),
                const QuotationView(),
              ],
            ),
          ),
        ),
      ),
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
          onPressed: () => _exportBomCsv(ref),
        ),
        MechXButton(
          label: context.strings(StringKey.commercialExportProposalMd),
          primary: true,
          onPressed: () => _exportProposalMarkdown(ref),
        ),
      ],
    );
  }

  // Both commercial exports route through the shared export guard (H3): the
  // zero-length completeness gate, cancel ⇒ no pill, success ⇒ the "Exported
  // ..." confirmation, and an IO failure surfaces instead of no-oping.
  Future<void> _exportBomCsv(WidgetRef ref) => runExportGuarded(
        ref,
        name: 'electrical BOM',
        write: () async {
          final name = ref.read(projectControllerProvider).name;
          final csv = costEstimateToCsv(ref.read(electricalCostProvider));
          final path = await FilePicker.saveFile(
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleElectricalBom),
            fileName: '$name-electrical-bom.csv',
            type: FileType.custom,
            allowedExtensions: const ['csv'],
          );
          if (path == null) return false;
          final full = path.endsWith('.csv') ? path : '$path.csv';
          await File(full).writeAsString(csv);
          return true;
        },
      );

  Future<void> _exportProposalMarkdown(WidgetRef ref) => runExportGuarded(
        ref,
        name: 'quotation proposal',
        write: () async {
          final name = ref.read(projectControllerProvider).name;
          final md = quotationToMarkdown(
            ref.read(electricalQuotationProvider),
            ref.read(electricalCostProvider),
            projectName: name,
          );
          final path = await FilePicker.saveFile(
            dialogTitle: MechXStringsData(ref.read(localeProvider))(
                StringKey.exportTitleElectricalProposal),
            fileName: '$name-electrical-proposal.md',
            type: FileType.custom,
            allowedExtensions: const ['md'],
          );
          if (path == null) return false;
          final full = path.endsWith('.md') ? path : '$path.md';
          await File(full).writeAsString(md);
          return true;
        },
      );
}
