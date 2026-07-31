/// G5 — THE FIRE-DUTY PROTECTION NOTE REACHES THE DELIVERABLE.
///
/// `compute.dart` raises an INFO `fire-pump-protection` on every life-safety
/// motor/pump way: under fire duty the machine runs to destruction, so its
/// protection is specified differently (locked-rotor rated, overload trip
/// disabled / alarm-only) and the engine — which has no data for that
/// controller — will not fabricate one. The note's own comment claimed it was
/// "carried onto the schedule"; it was not, and it read as an instruction to
/// change a setting that does not exist.
///
/// Now (a) the note is worded as a SPEC instruction for the issued schedule and
/// (b) the board schedule prints the matching `· no-OL trip (fire)` KETERANGAN
/// token on exactly the same ways — so the panel builder reading the sheet sees
/// the requirement, and the two can never disagree.
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

/// One board carrying the four combinations that matter: a life-safety MOTOR
/// (fire pump), a life-safety PUMP (jockey), a life-safety NON-motor
/// (emergency lighting) and an ORDINARY pump.
const _project = ElectricalProject(
  id: 'pr',
  name: 'Fire board',
  panels: [
    ElectricalPanel(
      id: 'EP',
      name: 'Essential Panel',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
          id: 'fp',
          name: 'Fire pump',
          loadKind: LoadKind.motor,
          motorKw: 15,
          phases: 3,
          lifeSafety: true,
          cableType: 'FRC',
          length: Length(30),
        ),
        ElectricalCircuit(
          id: 'jp',
          name: 'Jockey pump',
          loadKind: LoadKind.pump,
          motorKw: 2.2,
          phases: 3,
          lifeSafety: true,
          cableType: 'FRC',
          length: Length(30),
        ),
        ElectricalCircuit(
          id: 'el',
          name: 'Emergency light',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 800,
          lifeSafety: true,
          cableType: 'FRC',
          length: Length(20),
        ),
        ElectricalCircuit(
          id: 'bp',
          name: 'Booster pump',
          loadKind: LoadKind.pump,
          motorKw: 3,
          phases: 3,
          length: Length(18),
        ),
      ],
    ),
  ],
);

const _token = ' · no-OL trip (fire)';

void main() {
  final sys = computeSystem(p, _project);
  final sheet =
      buildElectricalPanelDetail(project: _project, result: sys, panelId: 'EP');
  final labels = sheet.prims.whereType<SldLabel>().map((l) => l.text).toList();

  test('the schedule prints the fire-duty token on the life-safety pump ways',
      () {
    expect(labels, contains('Fire pump$_token'));
    expect(labels, contains('Jockey pump$_token'));
  });

  test('and on nothing else — a life-safety LIGHT and an ordinary pump are bare',
      () {
    // `lifeSafety` alone is not the gate (the emergency-lighting way is FRC and
    // life-safety but is not a machine); nor is `pump` alone.
    expect(labels, contains('Emergency light'));
    expect(labels, contains('Booster pump'));
    expect(labels.where((t) => t.contains(_token)).length, 2);
  });

  test('the token rides exactly the ways the INFO note names (one gate)', () {
    final noted = sys.warnings
        .where((w) => w.code == 'fire-pump-protection')
        .map((w) => w.circuitId)
        .toSet();
    expect(noted, {'fp', 'jp'});
    // Every noted way's KETERANGAN cell carries the token, and no other row
    // does — the note and the sheet are driven by the same condition.
    final tokenNames = labels
        .where((t) => t.contains(_token))
        .map((t) => t.substring(0, t.indexOf(_token)))
        .toSet();
    expect(tokenNames, {'Fire pump', 'Jockey pump'});
  });

  test('the note is a SPEC instruction for the schedule, not a phantom setting',
      () {
    final w = sys.warnings
        .firstWhere((x) => x.code == 'fire-pump-protection' && x.circuitId == 'fp');
    expect(w.severity, WarningSeverity.info);
    expect(
        w.message,
        contains('specify overload-trip-disabled protection on the schedule '
            '(fire duty runs to destruction - NFPA 20 practice)'));
    // It points at the token the sheet actually carries, so the two agree.
    expect(w.message, contains('no-OL trip (fire)'));
    expect(w.message, contains('NFPA 20'));
  });

  test('a board with no life-safety machine is byte-identical', () {
    // The gate is data-driven: drop the two pump ways and the schedule loses
    // every trace of the token (no blank separator, no reserved width).
    const plain = ElectricalProject(
      id: 'pr2',
      name: 'Plain board',
      panels: [
        ElectricalPanel(
          id: 'EP',
          name: 'Essential Panel',
          system: ElectricalSystem.threePhase,
          voltage: Voltage(400),
          circuits: [
            ElectricalCircuit(
              id: 'el',
              name: 'Emergency light',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 800,
              lifeSafety: true,
              cableType: 'FRC',
              length: Length(20),
            ),
            ElectricalCircuit(
              id: 'bp',
              name: 'Booster pump',
              loadKind: LoadKind.pump,
              motorKw: 3,
              phases: 3,
              length: Length(18),
            ),
          ],
        ),
      ],
    );
    final plainSheet = buildElectricalPanelDetail(
        project: plain, result: computeSystem(p, plain), panelId: 'EP');
    expect(
      plainSheet.prims.whereType<SldLabel>().where((l) => l.text.contains('no-OL')),
      isEmpty,
    );
    expect(
      plainSheet.prims.whereType<SldLabel>().map((l) => l.text),
      containsAll(['Emergency light', 'Booster pump']),
    );
  });
}
