// Phase colour-coding on the board schedule: the R / S / T column headers,
// each way's line-current cell and the TOTAL footer's per-phase totals carry
// `SldRole.phaseR` / `phaseS` / `phaseT`, so every renderer (canvas painter,
// PDF, DXF) colours the three phases apart — the Indonesian panel-builder
// red / yellow / blue R-S-T convention. Everything else on the schedule stays
// `normal` (the monotone ink), so the colour reads as PHASE information, not
// decoration.
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:test/test.dart';

// The real "Menara Contoh" acceptance-harness fixture (MDP -> LP-1/PP-1/EMG),
// same as the imbalance-footer test, so the phase assignments asserted against
// are a solved, hand-reviewed project.
import '../tool/generate_export_samples.dart' show buildElectrical;

void main() {
  const profile = PuilProfile();
  final project = buildElectrical();
  final result = computeSystem(profile, project);

  List<SldLabel> labels(SldSheet sheet) =>
      [for (final p in sheet.prims) if (p is SldLabel) p];

  group('buildElectricalPanelDetail phase roles (3-phase board)', () {
    final sheet = buildElectricalPanelDetail(
        project: project, result: result, panelId: 'MDP');
    final all = labels(sheet);
    final mdp = result.panels['MDP']!;

    test('the R / S / T column headers carry their phase role', () {
      SldLabel head(String t) =>
          all.firstWhere((l) => l.text == t && l.bold && l.size == 7);
      expect(head('R').role, SldRole.phaseR);
      expect(head('S').role, SldRole.phaseS);
      expect(head('T').role, SldRole.phaseT);
      // The neighbouring headers stay monotone ink.
      expect(head('GRUP').role, SldRole.normal);
      expect(head('DAYA').role, SldRole.normal);
    });

    test('phase-role labels are ONLY the headers, way cells and totals', () {
      for (final l in all) {
        if (l.role == SldRole.phaseR ||
            l.role == SldRole.phaseS ||
            l.role == SldRole.phaseT) {
          expect(
            l.text == 'R' ||
                l.text == 'S' ||
                l.text == 'T' ||
                double.tryParse(l.text) != null,
            isTrue,
            reason: 'phase colour must mark phase data, not prose: "${l.text}"',
          );
        }
      }
    });

    test('per-way cell count per phase = ways loading that line (+header+total)',
        () {
      int loading(PhaseAssignment want) => mdp.circuits
          .where((c) =>
              c.phase == want || c.phase == PhaseAssignment.threePhase)
          .length;
      int roleCount(SldRole r) => all.where((l) => l.role == r).length;
      // header 'R' + one cell per way loading L1 + the bold footer total.
      expect(roleCount(SldRole.phaseR), 1 + loading(PhaseAssignment.l1) + 1);
      expect(roleCount(SldRole.phaseS), 1 + loading(PhaseAssignment.l2) + 1);
      expect(roleCount(SldRole.phaseT), 1 + loading(PhaseAssignment.l3) + 1);
    });

    test('the TOTAL footer per-phase figures carry role + bold', () {
      final pb = mdp.phaseBalance;
      for (final (v, role) in [
        (pb.l1, SldRole.phaseR),
        (pb.l2, SldRole.phaseS),
        (pb.l3, SldRole.phaseT),
      ]) {
        expect(
          all.any((l) =>
              l.bold && l.role == role && double.tryParse(l.text) == v),
          isTrue,
          reason: 'footer total $v missing its $role cell',
        );
      }
    });
  });

  group('renderers carry the phase colours', () {
    test('PDF: the schedule text stream uses the amber phase-S ink', () {
      final bytes = electricalSldToPdf(project: project, result: result);
      final s = String.fromCharCodes(bytes);
      // '0.80 0.50 0.03' is the S-phase amber — used by NO other role, so its
      // presence proves the phase cells took the phase ink (and its absence
      // before this change is what made the schedule monotone).
      expect(s, contains('0.80 0.50 0.03'));
    });

    test('DXF: a phase-S cell carries the ACI-2 yellow colour override', () {
      final dxf = electricalSldToDxf(project: project, result: result);
      // Group 62 (colour) with value 2 comes only from `SldRole.phaseS`
      // (essential/phaseR = 1, source/phaseT = 5).
      expect(RegExp(r'\n62\n2\n').hasMatch(dxf), isTrue);
    });
  });
}
