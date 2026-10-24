// Round 53 fire fixtures (shared by the Round 53 tests): the networks the
// review reproduced each finding on.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;

NetNode _n(
  String id,
  double x, {
  int floor = 0,
  double y = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: role,
      component: c,
    );

NetEdge _e(
  String id,
  String a,
  String b, {
  ServiceType s = ServiceType.fireHydrant,
  EdgeKind k = EdgeKind.run,
}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

const _sp = ServiceType.fireSprinkler;

/// GT -> SH (a bare suction header) -> FPA -> a hose-reel stack L0-L7 and
/// SH -> FPB -> a hydrant-box stack L0-L7. [separateTanks]: each pump on its
/// own tank instead (GT -> FPA, GT2 -> FPB) — the reference drawing.
Network r53TwoTowers({bool separateTanks = false}) => Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        if (separateTanks)
          _n('GT2', 0,
              y: 500, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('SH', 100),
        if (separateTanks) _n('SH2', 100, y: 500),
        _n('FPA', 200, role: NodeRole.plant, c: NodeComponent.pump),
        _n('DA', 300),
        _n('FPB', 200, y: 500, role: NodeRole.plant, c: NodeComponent.pump),
        _n('DB', 300, y: 500),
        for (var f = 0; f < 8; f++) ...[
          _n('A$f', 400, floor: f),
          _n('HR$f', 500,
              floor: f, role: NodeRole.fixture, c: NodeComponent.hoseReel),
          _n('B$f', 400, y: 500, floor: f),
          _n('HB$f', 500,
              y: 500,
              floor: f,
              role: NodeRole.fixture,
              c: NodeComponent.hydrantBox),
        ],
      ],
      edges: [
        _e('gs', 'GT', 'SH'),
        _e('sa', 'SH', 'FPA'),
        _e('pa', 'FPA', 'DA'),
        _e('da', 'DA', 'A0'),
        if (separateTanks) _e('gs2', 'GT2', 'SH2'),
        _e('sb', separateTanks ? 'SH2' : 'SH', 'FPB'),
        _e('pb', 'FPB', 'DB'),
        _e('db', 'DB', 'B0'),
        for (var f = 0; f < 8; f++) ...[
          if (f > 0) _e('a$f', 'A${f - 1}', 'A$f', k: EdgeKind.riser),
          _e('hr$f', 'A$f', 'HR$f'),
          if (f > 0) _e('b$f', 'B${f - 1}', 'B$f', k: EdgeKind.riser),
          _e('hb$f', 'B$f', 'HB$f'),
        ],
      ],
    );

/// GT -> SH -> FPH (hydrant stack L0-L5, a box per floor) and SH -> FPS
/// (a sprinkler riser, 4 heads per floor). The header `gs` and both suction
/// legs `sh` / `ss` are drawn on [header] service.
Network r53Cross(ServiceType header) => Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('SH', 100),
        _n('FPH', 200, role: NodeRole.plant, c: NodeComponent.pump),
        _n('DH', 300),
        _n('FPS', 200, y: 500, role: NodeRole.plant, c: NodeComponent.pump),
        _n('DS', 300, y: 500),
        for (var f = 0; f < 6; f++) ...[
          _n('Q$f', 400, floor: f),
          _n('HB$f', 500,
              floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
          _n('R$f', 400, y: 500, floor: f),
          for (var k = 1; k <= 4; k++)
            _n('S$f-$k', 400 + 300.0 * k,
                y: 500,
                floor: f,
                role: NodeRole.fixture,
                c: NodeComponent.sprinklerHead),
        ],
      ],
      edges: [
        _e('gs', 'GT', 'SH', s: header),
        _e('sh', 'SH', 'FPH', s: header),
        _e('ph', 'FPH', 'DH'),
        _e('dq', 'DH', 'Q0'),
        _e('ss', 'SH', 'FPS', s: header),
        _e('ps', 'FPS', 'DS', s: _sp),
        _e('dr', 'DS', 'R0', s: _sp),
        for (var f = 0; f < 6; f++) ...[
          if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser),
          _e('hb$f', 'Q$f', 'HB$f'),
          if (f > 0) _e('r$f', 'R${f - 1}', 'R$f', s: _sp, k: EdgeKind.riser),
          for (var k = 1; k <= 4; k++)
            _e('s$f-$k', k == 1 ? 'R$f' : 'S$f-${k - 1}', 'S$f-$k', s: _sp),
        ],
      ],
    );

/// A transfer pump room: GT -> SH -> [pumps] identical pumps TP1..TPn ->
/// A0 -> riser -> break tank TT on [tt] -> FP2 -> J -> [stacks] stacks of
/// hydrant boxes (or hose reels, [reels]) on floors [tt]..[top]-1.
Network r53Transfer({
  bool reels = false,
  int stacks = 1,
  int top = 20,
  int tt = 10,
  int pumps = 3,
}) =>
    Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('SH', 50),
        for (var i = 1; i <= pumps; i++)
          _n('TP$i', 100,
              y: 100.0 * i, role: NodeRole.plant, c: NodeComponent.pump),
        _n('A0', 200),
        _n('A10', 200, floor: tt),
        _n('TT', 300,
            floor: tt, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FP2', 400,
            floor: tt, role: NodeRole.plant, c: NodeComponent.pump),
        _n('J', 450, floor: tt),
        for (var s = 0; s < stacks; s++)
          for (var f = tt; f < top; f++) ...[
            _n('B$s-$f', 500, y: 300.0 * s, floor: f),
            _n('HB$s-$f', 600,
                y: 300.0 * s,
                floor: f,
                role: NodeRole.fixture,
                c: reels ? NodeComponent.hoseReel : NodeComponent.hydrantBox),
          ],
      ],
      edges: [
        _e('g', 'GT', 'SH'),
        for (var i = 1; i <= pumps; i++) ...[
          _e('s$i', 'SH', 'TP$i'),
          _e('t$i', 'TP$i', 'A0'),
        ],
        _e('r', 'A0', 'A10', k: EdgeKind.riser),
        _e('a', 'A10', 'TT'),
        _e('s2', 'TT', 'FP2'),
        _e('d2', 'FP2', 'J'),
        for (var s = 0; s < stacks; s++) ...[
          _e('j$s', 'J', 'B$s-$tt'),
          for (var f = tt; f < top; f++) ...[
            if (f > tt)
              _e('q$s-$f', 'B$s-${f - 1}', 'B$s-$f', k: EdgeKind.riser),
            _e('hb$s-$f', 'B$s-$f', 'HB$s-$f'),
          ],
        ],
      ],
    );

/// A single-storey warehouse: RT -> A -> BP (booster) -> M on SPRINKLER
/// service -> 12 heads; M -> HJ -> two hydrant boxes on hydrant service.
Network r53Warehouse() => Network(
      nodes: [
        _n('RT', 0, role: NodeRole.plant, c: NodeComponent.roofTank),
        _n('A', 50),
        _n('BP', 100, role: NodeRole.plant, c: NodeComponent.boosterSet),
        _n('M', 200),
        for (var k = 1; k <= 12; k++)
          _n('S$k', 200 + 300.0 * k,
              role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
        _n('HJ', 200, y: 400),
        _n('HB1', 300,
            y: 400, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        _n('HB2', 200,
            y: 800, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ],
      edges: [
        _e('ra', 'RT', 'A', s: _sp),
        _e('ab', 'A', 'BP', s: _sp),
        _e('bm', 'BP', 'M', s: _sp),
        for (var k = 1; k <= 12; k++)
          _e('s$k', k == 1 ? 'M' : 'S${k - 1}', 'S$k', s: _sp),
        _e('mh', 'M', 'HJ'),
        _e('h1', 'HJ', 'HB1'),
        _e('h2', 'HJ', 'HB2'),
      ],
    );

/// P1 on L0 serves hydrant boxes L0-L17; a series booster P2 on L17 (suction
/// from Q17) serves the L18 box.
Network r53StageClamp() => Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P1', 100, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 18; f++) ...[
          _n('Q$f', 300, floor: f),
          _n('HB$f', 400,
              floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ],
        _n('P2', 500, floor: 17, role: NodeRole.plant, c: NodeComponent.pump),
        _n('X17', 600, floor: 17),
        _n('Q18', 600, floor: 18),
        _n('HB18', 700,
            floor: 18, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ],
      edges: [
        _e('g', 'GT', 'P1'),
        _e('p', 'P1', 'Q0'),
        for (var f = 0; f < 18; f++) ...[
          if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser),
          _e('hb$f', 'Q$f', 'HB$f'),
        ],
        _e('s2', 'Q17', 'P2'),
        _e('d2', 'P2', 'X17'),
        _e('q18', 'X17', 'Q18', k: EdgeKind.riser),
        _e('hb18', 'Q18', 'HB18'),
      ],
    );

/// Round 53 — a 7-storey hotel with a DRAWN hot-water return: heater H ->
/// main M -> riser bases B0..B3 -> supply risers (6 showers per floor on
/// stubs) -> a 30 m top run per riser -> return risers -> a common return
/// main -> RJ -> check valve CV -> circulator P -> H.
Network r53HotelReturn({int risers = 4, int floors = 7}) {
  const hw = ServiceType.hotWater;
  final nodes = <NetNode>[
    _n('H', 0, role: NodeRole.plant),
    _n('M', 100),
    _n('RJ', 0, y: 600),
    _n('CV', 0, y: 400, c: NodeComponent.checkValve),
    _n('P', 0, y: 200, role: NodeRole.plant, c: NodeComponent.pump),
  ];
  final edges = <NetEdge>[
    _e('hm', 'H', 'M', s: hw),
    _e('rj', 'RJ', 'CV', s: hw),
    _e('cv', 'CV', 'P', s: hw),
    _e('ph', 'P', 'H', s: hw),
  ];
  for (var r = 0; r < risers; r++) {
    final x = 400.0 + 800 * r;
    nodes.add(_n('B$r', x));
    edges.add(_e('m$r', r == 0 ? 'M' : 'B${r - 1}', 'B$r', s: hw));
    for (var f = 0; f < floors; f++) {
      nodes.add(_n('S$r-$f', x, y: 100, floor: f));
      edges.add(f == 0
          ? _e('b$r', 'B$r', 'S$r-0', s: hw)
          : _e('sr$r-$f', 'S$r-${f - 1}', 'S$r-$f', s: hw, k: EdgeKind.riser));
      for (var k = 0; k < 6; k++) {
        nodes.add(NetNode(
          id: 'F$r-$f-$k',
          sheetId: 's1',
          x: x + 50 + 30.0 * k,
          y: 150,
          floorIndex: f,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.shower,
        ));
        edges.add(_e('f$r-$f-$k', 'S$r-$f', 'F$r-$f-$k', s: hw));
      }
      nodes.add(_n('Q$r-$f', x + 3000, y: 100, floor: f));
      if (f > 0) {
        edges.add(_e('qr$r-$f', 'Q$r-$f', 'Q$r-${f - 1}',
            s: hw, k: EdgeKind.riser));
      }
    }
    edges.add(_e('top$r', 'S$r-${floors - 1}', 'Q$r-${floors - 1}', s: hw));
    nodes.add(_n('QB$r', x + 3000, y: 600));
    edges.add(_e('qb$r', 'Q$r-0', 'QB$r', s: hw));
    edges.add(_e('qm$r', 'QB$r', r == 0 ? 'RJ' : 'QB${r - 1}', s: hw));
  }
  return Network(nodes: nodes, edges: edges);
}
