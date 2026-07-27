import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/panel_templates.dart';
import 'package:test/test.dart';

/// Sub-panel TEMPLATE data tests — a pure lookup + the three frozen presets
/// replayed through `addCircuit` by the UI. No compute, no `.mechx` schema;
/// just pin the frozen contract (ids, counts, watts, shared headroom).
void main() {
  group('panelTemplateById', () {
    test('finds each built-in id', () {
      expect(panelTemplateById('lighting')?.id, 'lighting');
      expect(panelTemplateById('power')?.id, 'power');
      expect(panelTemplateById('mixed')?.id, 'mixed');
    });

    test('unknown id returns null, never throws', () {
      expect(panelTemplateById('nope'), isNull);
      expect(panelTemplateById(''), isNull);
    });
  });

  test('kPanelTemplates has exactly the three frozen ids, in order', () {
    expect(kPanelTemplates.map((t) => t.id).toList(),
        ['lighting', 'power', 'mixed']);
  });

  test('every template carries the shared 20 %/2-way headroom', () {
    for (final t in kPanelTemplates) {
      expect(t.headroom, isNotNull, reason: '${t.id} should set headroom');
      expect(t.headroom!.sparePercentage, 20,
          reason: '${t.id} sparePercentage');
      expect(t.headroom!.spareWays, 2, reason: '${t.id} spareWays');
    }
  });

  test('every template has unique circuit names within itself', () {
    for (final t in kPanelTemplates) {
      final names = t.circuits.map((c) => c.name).toList();
      expect(names.toSet().length, names.length,
          reason: '${t.id} has duplicate circuit names: $names');
    }
  });

  group('lighting template', () {
    final t = panelTemplateById('lighting')!;

    test('circuit count: 4 lighting + 1 socket = 5', () {
      expect(t.circuits.length, 5);
      expect(
          t.circuits.where((c) => c.kind == LoadKind.lighting).length, 4);
      expect(t.circuits.where((c) => c.kind == LoadKind.socket).length, 1);
    });

    test('frozen names + watts', () {
      expect(t.circuits[0].name, 'Lighting — zone 1');
      expect(t.circuits[1].name, 'Lighting — zone 2');
      expect(t.circuits[2].name, 'Lighting — zone 3');
      expect(t.circuits[3].name, 'Lighting — zone 4');
      expect(t.circuits[4].name, 'Sockets — utility');
      for (var i = 0; i < 4; i++) {
        expect(t.circuits[i].loadW, 1200);
      }
      expect(t.circuits[4].loadW, 2000);
    });

    test('no motor kw / explicit phases on this template', () {
      for (final c in t.circuits) {
        expect(c.motorKw, isNull);
        expect(c.phases, isNull);
      }
    });
  });

  group('power template', () {
    final t = panelTemplateById('power')!;

    test('circuit count: 4 socket + 1 hvac = 5', () {
      expect(t.circuits.length, 5);
      expect(t.circuits.where((c) => c.kind == LoadKind.socket).length, 4);
      expect(t.circuits.where((c) => c.kind == LoadKind.hvac).length, 1);
    });

    test('frozen names + watts', () {
      expect(t.circuits[0].name, 'Sockets — zone 1');
      expect(t.circuits[1].name, 'Sockets — zone 2');
      expect(t.circuits[2].name, 'Sockets — zone 3');
      expect(t.circuits[3].name, 'Sockets — zone 4');
      expect(t.circuits[4].name, 'Air-con');
      for (var i = 0; i < 4; i++) {
        expect(t.circuits[i].loadW, 2000);
      }
      expect(t.circuits[4].loadW, 2500);
    });

    test('the air-con way is pinned single-phase', () {
      final ac = t.circuits.last;
      expect(ac.kind, LoadKind.hvac);
      expect(ac.phases, 1);
    });
  });

  group('mixed template', () {
    final t = panelTemplateById('mixed')!;

    test('circuit count: 2 lighting + 2 socket + 1 hvac = 5', () {
      expect(t.circuits.length, 5);
      expect(
          t.circuits.where((c) => c.kind == LoadKind.lighting).length, 2);
      expect(t.circuits.where((c) => c.kind == LoadKind.socket).length, 2);
      expect(t.circuits.where((c) => c.kind == LoadKind.hvac).length, 1);
    });

    test('frozen names + watts', () {
      expect(t.circuits[0].name, 'Lighting — zone 1');
      expect(t.circuits[1].name, 'Lighting — zone 2');
      expect(t.circuits[2].name, 'Sockets — zone 1');
      expect(t.circuits[3].name, 'Sockets — zone 2');
      expect(t.circuits[4].name, 'Air-con');
      expect(t.circuits[0].loadW, 1200);
      expect(t.circuits[1].loadW, 1200);
      expect(t.circuits[2].loadW, 2000);
      expect(t.circuits[3].loadW, 2000);
      expect(t.circuits[4].loadW, 2500);
    });

    test('the air-con way is pinned single-phase', () {
      final ac = t.circuits.last;
      expect(ac.kind, LoadKind.hvac);
      expect(ac.phases, 1);
    });
  });
}
