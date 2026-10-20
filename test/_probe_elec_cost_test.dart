import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';

void main() {
  test('probe cost', () {
    final project = sampleElectricalProject();
    for (var i = 0; i < 5; i++) { computeSystem(const PuilProfile(), project); }
    final sw = Stopwatch()..start();
    late dynamic r;
    for (var i = 0; i < 50; i++) { r = computeSystem(const PuilProfile(), project); }
    final tSys = sw.elapsedMicroseconds / 50;
    sw..reset()..start();
    for (var i = 0; i < 20; i++) { computeAdvancedStudy(const PuilProfile(), project, r); }
    final tAdv = sw.elapsedMicroseconds / 20;
    sw..reset()..start();
    var n = 0;
    for (var i = 0; i < 20; i++) {
      for (final p in project.panels) { buildElectricalPanelDetail(project: project, result: r, panelId: p.id); n++; }
    }
    final tDet = sw.elapsedMicroseconds / 20;
    // ignore: avoid_print
    print('PROBE panels=${project.panels.length} ways=${project.panels.fold<int>(0,(a,p)=>a+p.circuits.length)} computeSystem=${tSys.toStringAsFixed(0)}us advanced=${tAdv.toStringAsFixed(0)}us allPanelDetails=${tDet.toStringAsFixed(0)}us');
  });
}
