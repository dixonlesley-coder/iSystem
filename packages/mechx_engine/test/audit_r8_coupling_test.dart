/// Audit round 8 — MEP→electrical coupling (engine side).
///
///   coupling-5  a fire-pump way is minted on FRC; a life-safety way with no
///               cable type, or on a non-essential board, is warned.
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _proj({required bool essential, String? cableType}) =>
    ElectricalProject(
      id: 'p',
      name: 'p',
      earthingSystem: EarthingSystem.tnCs,
      panels: [
        ElectricalPanel(
          id: 'mdp',
          name: 'MDP',
          voltage: const Voltage(400),
          essential: essential,
          circuits: [
            const ElectricalCircuit(
              id: 'f',
              name: 'To EMG',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'emg',
              length: Length(10),
            ),
          ],
        ),
        ElectricalPanel(
          id: 'emg',
          name: 'EMG',
          voltage: const Voltage(400),
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f',
          circuits: [
            ElectricalCircuit(
              id: 'fp',
              name: 'Fire pump',
              loadKind: LoadKind.pump,
              motorKw: 30,
              lifeSafety: true,
              cableType: cableType,
              length: const Length(20),
            ),
          ],
        ),
      ],
    );

void main() {
  test('a fire-pump equipment way is minted on FRC', () {
    final c = equipmentToCircuit(
      const MepEquipmentLoad(
          id: 'fire-pump',
          name: 'Fire pump',
          source: MepLoadSource.firePump,
          mechanicalPower: Power(55000)),
      panelVoltage: const Voltage(400),
    );
    expect(c.lifeSafety, isTrue);
    expect(c.cableType, 'FRC');
    // A non-life-safety machine keeps the default family (null).
    final p = equipmentToCircuit(
      const MepEquipmentLoad(
          id: 'p',
          name: 'Pump',
          source: MepLoadSource.supplyPump,
          mechanicalPower: Power(1500)),
      panelVoltage: const Voltage(400),
    );
    expect(p.cableType, isNull);
  });

  test('life-safety way with no cable type is warned', () {
    final sys = computeSystem(_profile, _proj(essential: true));
    final w = sys.warnings
        .where((w) => w.code == 'life-safety-cable' && w.circuitId == 'fp');
    expect(w, hasLength(1));
    expect(w.single.message, contains('no cable type'));
    // FRC ⇒ no cable warning.
    expect(
        computeSystem(_profile, _proj(essential: true, cableType: 'FRC'))
            .warnings
            .where((w) => w.code == 'life-safety-cable'),
        isEmpty);
  });

  test('life-safety way off the essential path is warned; an essential '
      'ancestor clears it', () {
    final off = computeSystem(_profile, _proj(essential: false, cableType: 'FRC'));
    expect(
        off.warnings.where((w) =>
            w.code == 'life-safety-not-essential' && w.circuitId == 'fp'),
        hasLength(1));
    // MDP essential ⇒ EMG (fed from it) is on the essential path.
    final on = computeSystem(_profile, _proj(essential: true, cableType: 'FRC'));
    expect(on.warnings.where((w) => w.code == 'life-safety-not-essential'),
        isEmpty);
  });
}
