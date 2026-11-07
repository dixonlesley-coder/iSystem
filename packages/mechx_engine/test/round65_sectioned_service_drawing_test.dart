// Round 65 (elec-convergence-17-sectioned-service-drawn-as-paralleled-
// transformers) — a SECTIONED (dual-transformer / transformerUnits >= 2)
// service is drawn as separate sections with a normally-open bus coupler,
// never as n units paralleled onto one LV main.
//
// The fault study rates every device on ONE unit's fault (Round 58/60:
// Isc = S / (sqrt(3) x 400 x 0.04) per section); paralleling two units onto
// one bus would double it. The issued spine (vertical overview chain AND the
// horizontal canvas chain) and the power one-line must therefore state
// '2 separate sections · coupler N.O.' beside the 'n x kVA' figure. A single
// section prints neither (byte-identical).
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalProject _proj({bool dual = false, int? units}) => ElectricalProject(
      id: 'x',
      name: 'x',
      dualTransformer: dual,
      transformerUnits: units,
      sources: const ElectricalSources(generator: GeneratorSource()),
      panels: [
        for (final id in ['A', 'B'])
          ElectricalPanel(
            id: id,
            name: 'MDP-$id',
            system: ElectricalSystem.threePhase,
            voltage: const Voltage(400),
            circuits: [
              for (var i = 0; i < 4; i++)
                ElectricalCircuit(
                  id: '$id$i',
                  name: 'Load $i',
                  loadKind: LoadKind.general,
                  loadW: 40000,
                  cosPhi: 1,
                  phases: 3,
                  length: const Length(10),
                ),
            ],
          ),
      ],
    );

Iterable<String> _labels(SldSheet s) =>
    s.prims.whereType<SldLabel>().map((l) => l.text);

void main() {
  for (final (name, pr) in [
    ('dualTransformer', _proj(dual: true)),
    ('transformerUnits 2', _proj(units: 2)),
  ]) {
    test('$name: sections + N.O. coupler on every surface', () {
      final sys = computeSystem(_p, pr);
      for (final horizontal in [false, true]) {
        final spine = buildElectricalSourceSpine(
            project: pr, result: sys, horizontal: horizontal);
        expect(_labels(spine).join(' | '), contains('coupler N.O.'),
            reason: 'horizontal $horizontal');
      }
      final overview =
          buildElectricalOverview(project: pr, result: sys, sourceChain: true);
      expect(_labels(overview).join(' | '),
          contains('LV main · 2 sections, coupler N.O.'));
      final study = computeAdvancedStudy(_p, pr, sys);
      final bus =
          study.powerOneLine!.nodes.firstWhere((n) => n.id == 'bus');
      expect(bus.sub, contains('2 sections, coupler N.O.'));
      final utility = study.powerOneLine!.nodes
          .map((n) => n.sub ?? '')
          .where((s) => s.startsWith('MV via TX'));
      expect(utility.join(), contains('2 sections, coupler N.O.'));
    });
  }

  test('one section: no section note anywhere', () {
    final pr = _proj();
    final sys = computeSystem(_p, pr);
    for (final horizontal in [false, true]) {
      final spine = buildElectricalSourceSpine(
          project: pr, result: sys, horizontal: horizontal);
      expect(_labels(spine).join(' | '), isNot(contains('coupler')));
    }
    final study = computeAdvancedStudy(_p, pr, sys);
    final bus = study.powerOneLine!.nodes.firstWhere((n) => n.id == 'bus');
    expect(bus.sub, '400 V');
  });
}
