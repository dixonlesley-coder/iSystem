import 'dart:convert';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// The content stream of each page, in page order (streams are uncompressed
/// text, one per page object).
List<String> _pageStreams(String pdf) => [
      for (final m
          in RegExp(r'stream\n(.*?)\nendstream', dotAll: true).allMatches(pdf))
        m.group(1)!,
    ];

void main() {
  const profile = PuilProfile();

  const project = ElectricalProject(
    id: 'p1',
    name: 'Test building',
    panels: [
      ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        tag: 'MDP',
        circuits: [
          ElectricalCircuit(
            id: 'f1',
            name: 'Feeder to LP-1',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'LP1',
            length: Length(15),
          ),
        ],
      ),
      ElectricalPanel(
        id: 'LP1',
        name: 'LP-1',
        tag: 'LP-1',
        system: ElectricalSystem.singlePhase,
        voltage: Voltage(220),
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'f1',
        x: 400,
        y: 220,
        circuits: [
          ElectricalCircuit(
            id: 'c1',
            name: 'Lighting',
            loadKind: LoadKind.lighting,
            isLighting: true,
            loadW: 1500,
            length: Length(18),
          ),
        ],
      ),
    ],
  );

  final result = computeSystem(profile, project);

  test('emits a well-formed single-page PDF', () {
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result, title: 'SLD'));
    expect(s.startsWith('%PDF-1.4'), isTrue);
    expect(s.trimRight().endsWith('%%EOF'), isTrue);
    expect(s, contains('/Type /Catalog'));
    expect(s, contains('/Type /Page'));
    expect(s, contains('/BaseFont /Helvetica'));
    expect(s, contains('stream'));
    expect(s, contains('endstream'));
    expect(s, contains('trailer'));
  });

  test('draws panel boxes (rect) + feeder line + labels', () {
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result, title: 'SLD'));
    expect(s, contains(' re S')); // a stroked rectangle (panel box)
    expect(s, contains(' l S')); // the feeder line
    expect(s, contains('MDP')); // a panel label
    expect(s, contains('LP-1'));
  });

  test('renders the professional single-line content + sheet frame', () {
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result, title: 'SLD'));
    // Title block frame text.
    expect(s, contains('ELECTRICAL SINGLE-LINE DIAGRAM'));
    expect(s, contains('Test building')); // project name in the title block
    expect(s, contains('LEGEND'));
    // Per-way drafter content: incomer breaker + a way row with cable + Ib.
    expect(s, contains('Incomer'));
    expect(s, contains('Lighting')); // the LP-1 way name
    expect(s, contains('Ib')); // design current label
    expect(s, contains('MCB')); // a breaker class in the legend / rows
  });

  test('the 3-phase MDP incomer metering draws as stroked circles (beziers)',
      () {
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result, title: 'SLD'));
    // A circle is 4 cubic-bezier ` c` ops then a stroke ` S`; the V/A/Hz
    // meters add at least three (12 bezier segments) on a 3-phase board.
    expect(' c\n'.allMatches(s).length, greaterThanOrEqualTo(12));
  });

  test('the cross-reference offsets actually point at their objects', () {
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result));
    final sx = s.lastIndexOf('startxref');
    final xrefOffset = int.parse(
        s.substring(sx + 'startxref'.length, s.indexOf('%%EOF', sx)).trim());
    expect(s.substring(xrefOffset, xrefOffset + 4), 'xref');
    final lines = s.substring(xrefOffset).split('\n');
    final obj1Offset = int.parse(lines[3].substring(0, 10));
    expect(s.substring(obj1Offset).startsWith('1 0 obj'), isTrue);
  });

  test('an empty project still produces a valid (title-only) page', () {
    const empty = ElectricalProject(id: 'e', name: 'Empty');
    final emptyResult = computeSystem(profile, empty);
    final s = latin1.decode(electricalSldToPdf(
        project: empty, result: emptyResult, title: 'Empty SLD'));
    expect(s.startsWith('%PDF-1.4'), isTrue);
    expect(s, contains('(Empty SLD) Tj'));
    expect(s.trimRight().endsWith('%%EOF'), isTrue);
  });

  test('the single-page writer keeps the original 5-object shape (pin)', () {
    // Byte-shape pin for the N-page generalization: one page ⇒ the exact
    // pre-pagination object layout (Catalog 1, Pages 2 with one kid 3, Page 3,
    // Contents 4, Font 5).
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result, title: 'SLD'));
    expect(s, contains('/Kids [3 0 R] /Count 1'));
    expect(s, contains('/Contents 4 0 R'));
    expect(s, contains('/F1 5 0 R'));
    expect(s, contains('/Size 6'));
    expect(_pageStreams(s).length, 1);
  });

  test('no chrome ⇒ none of the C3 title-block rows (byte-identity guard)', () {
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result, title: 'SLD'));
    expect(s, isNot(contains('(CLIENT)')));
    expect(s, isNot(contains('(NTS)')));
    expect(s, isNot(contains('(DRAWN)')));
    expect(s, isNot(contains('[4 3] 0 d')));
  });

  test('C3 — chrome renders CLIENT/DATE/SCALE/DRAWN/CHECKED/APPROVED rows', () {
    final s = latin1.decode(electricalSldToPdf(
      project: project,
      result: result,
      chrome: const DrawingChrome(
        clientName: 'PT Contoh',
        dateString: '2026-07-02',
        drawnBy: 'DL',
        checkedBy: 'AB',
        approvedBy: 'CD',
        sheetIndex: 1,
        sheetTotal: 1,
      ),
    ));
    expect(s, contains('(CLIENT)'));
    expect(s, contains('(PT Contoh)'));
    expect(s, contains('(DATE)'));
    expect(s, contains('(2026-07-02)'));
    expect(s, contains('(DRAWN)'));
    expect(s, contains('(DL)'));
    expect(s, contains('(CHECKED)'));
    expect(s, contains('(APPROVED)'));
    // A single-line is schematic: SCALE defaults NTS when no scale is given.
    expect(s, contains('(SCALE)'));
    expect(s, contains('(NTS)'));
    expect(s, contains('(Sheet 1 of 1)'));
  });

  test('an explicit chrome.scaleText wins over the NTS default', () {
    final s = latin1.decode(electricalSldToPdf(
      project: project,
      result: result,
      chrome: const DrawingChrome(scaleText: '1 : 50'),
    ));
    expect(s, contains('(SCALE)'));
    expect(s, contains('(1 : 50)'));
    expect(s, isNot(contains('(NTS)')));
  });

  test('a dashed SldLine strokes inside a dash pattern and resets it', () {
    const dashedSheet = SldSheet(
      prims: [
        SldLine(0, 0, 100, 0, dashed: true),
        SldLine(0, 20, 100, 20),
      ],
      minX: 0,
      minY: 0,
      maxX: 100,
      maxY: 20,
      legend: [],
      supplyNote: '',
    );
    final s = latin1.decode(electricalSldToPdf(sheet: dashedSheet));
    // Exactly one dashed prim ⇒ one set + one reset of the dash pattern.
    expect('[4 3] 0 d'.allMatches(s).length, 1);
    expect('[] 0 d'.allMatches(s).length, 1);
    // The reset comes after the set, so the solid line stays solid.
    expect(s.indexOf('[] 0 d'), greaterThan(s.indexOf('[4 3] 0 d')));
  });

  group('electricalSldToPdfPaginated (C1)', () {
    // MDP feeds LP-1 and LP-2 — three boards, root-first order MDP, LP1, LP2.
    const threePanels = ElectricalProject(
      id: 'p3',
      name: 'Paged building',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          tag: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'f1',
              name: 'Feeder to LP-1',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'LP1',
              length: Length(15),
            ),
            ElectricalCircuit(
              id: 'f2',
              name: 'Feeder to LP-2',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'LP2',
              length: Length(30),
            ),
          ],
        ),
        ElectricalPanel(
          id: 'LP1',
          name: 'LP-1',
          tag: 'LP-1',
          system: ElectricalSystem.singlePhase,
          voltage: Voltage(220),
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f1',
          circuits: [
            ElectricalCircuit(
              id: 'c1',
              name: 'Lighting',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 1500,
              length: Length(18),
            ),
          ],
        ),
        ElectricalPanel(
          id: 'LP2',
          name: 'LP-2',
          tag: 'LP-2',
          system: ElectricalSystem.singlePhase,
          voltage: Voltage(220),
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f2',
          circuits: [
            ElectricalCircuit(
              id: 'c2',
              name: 'Sockets',
              loadKind: LoadKind.socket,
              loadW: 2000,
              length: Length(12),
            ),
          ],
        ),
      ],
    );

    test('3 panels -> a 3-page set, one board schedule per page', () {
      final threeResult = computeSystem(profile, threePanels);
      // Root-first: MDP leads; the two sub-boards follow in traversal order.
      expect(threeResult.order.length, 3);
      expect(threeResult.order.first, 'MDP');
      expect(threeResult.order.toSet(), {'MDP', 'LP1', 'LP2'});
      final s = latin1.decode(electricalSldToPdfPaginated(
          project: threePanels, result: threeResult));
      expect(s, contains('/Count 3'));
      expect(s, contains('/Kids [3 0 R 5 0 R 7 0 R]'));
      final pages = _pageStreams(s);
      expect(pages.length, 3);
      // Page i carries panel order[i]'s schedule + a real per-page counter.
      final nameById = {for (final p in threePanels.panels) p.id: p.name};
      for (var i = 0; i < 3; i++) {
        expect(pages[i], contains('(${nameById[threeResult.order[i]]}'));
        expect(pages[i], contains('(Sheet ${i + 1} of 3)'));
      }
      // Each page carries the shared title block.
      for (final page in pages) {
        expect(page, contains('(Paged building)'));
        expect(page, contains('(ELECTRICAL SINGLE-LINE DIAGRAM)'));
        expect(page, contains('Sheet'));
      }
      // The xref stays byte-accurate on a multi-page document.
      final sx = s.lastIndexOf('startxref');
      final xrefOffset = int.parse(
          s.substring(sx + 'startxref'.length, s.indexOf('%%EOF', sx)).trim());
      expect(s.substring(xrefOffset, xrefOffset + 4), 'xref');
    });

    test('a panel-less project degrades to one valid page, never throws', () {
      const empty = ElectricalProject(id: 'e', name: 'Empty');
      final emptyResult = computeSystem(profile, empty);
      final s = latin1.decode(electricalSldToPdfPaginated(
          project: empty, result: emptyResult));
      expect(s.startsWith('%PDF-1.4'), isTrue);
      expect(s, contains('/Count 1'));
      expect(s, contains('(Sheet 1 of 1)'));
    });
  });
}
