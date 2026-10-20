/// Round 21 (bom-quote-5) — the bill-of-materials lines for the gear the
/// ADVANCED study designs but the panel take-off ([buildBom]) never reached:
/// starter / control-assembly devices, the genset (per-set kVA × n) + its ATS,
/// the per-panel SPDs, the earth-electrode rods and the main earthing
/// conductor. Pure TABULATION of already-designed results — no new sizing.
///
/// Every line is UNMATCHED against the catalogue (none of this gear is in it,
/// bar bare copper) and carries a deterministic `elec:` price key, so the
/// quotation can price it and an unpriced line is counted, never silently
/// dropped. The way breaker of a control assembly is already the panel's way
/// breaker line, so control devices of the breaker category are skipped.
///
/// Pure Dart, zero Flutter imports.
library;

import 'bom.dart';
import 'catalog.dart' show PartCategory;
import 'containment.dart' show ContainmentResult, conduitFillSingle;
import 'control/starter.dart' show ControlAssembly, DeviceCategory;
import 'electrode.dart' show ElectrodeDesign;
import 'genset_backup.dart' show gensetBackupDemandVa, gensetBackupDemandW;
import 'load_kind.dart' show LoadKind;
import 'metering.dart' show MeteringKind, MeteringSpec;
import 'model.dart' show ElectricalProject, ElectricalSystem;
import 'panel_results.dart' show ElectricalSystemResult;
import 'power_factor.dart' show PowerFactorResult, capacitorBanksToProcure;
import 'sources.dart' show GeneratorTransfer, sizeGenerator;
import 'spd.dart' show SpdRecommendation, SpdTypeLabel;
import 'supply_design.dart' show serviceTransformer;

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// A price-key-safe token: lower case, runs of anything but `[a-z0-9.]`
/// collapsed to one `-`.
String _keyToken(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9.]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

/// The advanced-study BOM lines (see the library doc). [panelNameById]
/// labels each SPD line with its board; [circuitNameById] each control
/// device with its way.
List<BomLine> advancedBomLines({
  required ElectricalProject project,
  required ElectricalSystemResult sys,
  Map<String, ControlAssembly> controlAssemblies = const {},
  Map<String, SpdRecommendation> spd = const {},
  ElectrodeDesign? electrode,
  PowerFactorResult? powerFactor,
  Map<String, ContainmentResult> containment = const {},
  Map<String, MeteringSpec> metering = const {},
}) {
  final lines = <BomLine>[];
  final circuitName = <String, String>{
    for (final p in project.panels)
      for (final c in p.circuits) c.id: c.name,
  };
  final panelName = <String, String>{
    for (final p in project.panels) p.id: p.name,
  };
  final panelSystem = <String, ElectricalSystem>{
    for (final p in project.panels) p.id: p.system,
  };

  // ── Starter / control gear (contactors, overloads, timers, VFDs …) ───────
  final assemblyIds = controlAssemblies.keys.toList()..sort();
  for (final id in assemblyIds) {
    final a = controlAssemblies[id]!;
    for (final d in a.devices) {
      if (d.category == DeviceCategory.breaker || d.qty <= 0) continue;
      final rating = d.rating == null ? '' : ' ${d.rating}';
      final ratingToken = d.rating == null ? '' : _keyToken(d.rating!);
      final legacyRatingKey = d.rating == null ? '' : ':$ratingToken';
      // Round 41 (elec-report-bom-2-control-device-price-key-collision) —
      // the ROLE is part of the key: a start push-button, a stop push-button
      // and a VFD speed potentiometer (all rating-less pilot devices) used
      // to share `elec:control:pilotDevice:`, so the pricelist held one
      // price for all three. The legacy role-less key stays a read-time
      // fallback so a saved pricelist still prices the line.
      final roleToken = _keyToken(d.role);
      final ratingKey = ratingToken.isEmpty ? '' : ':$ratingToken';
      lines.add(BomLine(
        description: '${d.role}$rating — ${circuitName[id] ?? id}',
        location: circuitName[id] ?? id,
        qty: d.qty.toDouble(),
        category: PartCategory.accessory,
        priceKey: '${kElecPriceKeyPrefix}control:${d.category.name}:'
            '$roleToken$ratingKey',
        legacyPriceKey:
            '${kElecPriceKeyPrefix}control:${d.category.name}$legacyRatingKey',
      ));
    }
  }

  // ── Genset (per-set kVA × n) + ATS — the SAME sizing as G-01 ─────────────
  final gen = project.sources?.generator;
  if (gen != null) {
    final demand = sys.supply.demandVa.inKilovoltAmperes;
    final sel = gen.kva != null
        ? (kva: gen.kva!.inKilovoltAmperes, units: 1)
        : demand > 0
            ? (() {
                final r = sizeGenerator(gensetBackupDemandVa(project, sys),
                    mode: gen.mode,
                    transfer: gen.transfer,
                    backupPower: gensetBackupDemandW(project, sys));
                return (kva: r.ratingKva.inKilovoltAmperes, units: r.units);
              })()
            : null;
    if (sel != null && sel.kva > 0) {
      final kva = _fmt(sel.kva.roundToDouble());
      lines.add(BomLine(
        description: 'Genset $kva kVA ${gen.mode.name} — G-01',
        qty: sel.units.toDouble(),
        category: PartCategory.accessory,
        priceKey: '${kElecPriceKeyPrefix}genset:${kva}kva',
      ));
      lines.add(BomLine(
        description: gen.transfer == GeneratorTransfer.ats
            ? 'Automatic transfer switch (ATS) for $kva kVA genset — G-01'
            : 'Manual changeover switch (COS) for $kva kVA genset — G-01',
        qty: 1,
        category: PartCategory.accessory,
        priceKey: '${kElecPriceKeyPrefix}transfer:${gen.transfer.name}:'
            '${kva}kva',
      ));
    }
  }

  // ── Round 37 (electrical-sim-4-capacitor-bank-missing-from-bom) — the
  // capacitor bank(s) and the customer transformer(s) the study, schedule and
  // drawings size were never taken off, so the quotation under-priced real
  // gear without even an unpriced line to count. ───────────────────────────
  // The INSTALLED bank: every capacitor way's kvar per board, else the
  // declared LV-bus bank ([ElectricalProject.capacitorBankKvar]) — the same
  // bank is never counted twice.
  // Round 39 — the ONE installed-bank definition ([installedCapacitorBanks]).
  // The PF study's RECOMMENDED bank (APFC). Round 38 (regression-
  // recommended-pfc-bank-dropped-from-bom) — `bankKvar` is already the
  // FURTHER correction net of the installed compensation (the study subtracts
  // it), so it is never compared with the installed kvar: a 55 kvar bank and
  // a recommended further 50 kvar bank are both bought. Round 41 — both come
  // from the ONE [capacitorBanksToProcure] list the schedule and spines read.
  for (final b in capacitorBanksToProcure(project, powerFactor)) {
    final k = _fmt(double.parse(b.kvar.toStringAsFixed(1)));
    if (b.recommended) {
      lines.add(BomLine(
        description: 'Capacitor bank (APFC, recommended) $k kvar, '
            '${b.steps} steps${b.detuned ? ', detuned 7 %' : ''}',
        qty: b.units.toDouble(),
        category: PartCategory.accessory,
        priceKey: '${kElecPriceKeyPrefix}capacitor-bank:${k}kvar'
            '${b.detuned ? ':detuned' : ''}',
      ));
      continue;
    }
    final where = b.panelId == null
        ? 'LV main bus'
        : (panelName[b.panelId] ?? b.panelId!);
    lines.add(BomLine(
      description: 'Capacitor bank $k kvar — $where',
      location: where,
      qty: 1,
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}capacitor-bank:${k}kvar',
    ));
  }
  // The customer TRANSFORMER(s) of a declared / study MV service — the same
  // [serviceTransformer] the schedule and drawings print.
  final tx = serviceTransformer(project, sys.supply.demandVa);
  if (tx != null && tx.kva > 0) {
    final k = _fmt(tx.kva.roundToDouble());
    lines.add(BomLine(
      description: 'Transformer $k kVA',
      qty: tx.units.toDouble(),
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}transformer:${k}kva',
    ));
  }

  // ── Surge protective devices, one per recommending board ────────────────
  final spdIds = spd.keys.toList()..sort();
  for (final id in spdIds) {
    final r = spd[id]!;
    if (!r.recommended) continue;
    final uc = _fmt(r.ucV.roundToDouble());
    // Round 30 (costing-2-3) — the CONNECTION is part of the part: a 3φ
    // board takes a 4-pole 3+N device, a 1φ board a 2-pole 1+N, and a TT
    // N-PE module (npeUcV) makes it 3+1 / 1+1. Merging them onto one line
    // and price ordered two identical devices for different parts.
    final threePhase = panelSystem[id] != ElectricalSystem.singlePhase;
    final conn = '${threePhase ? 3 : 1}+${r.npeUcV != null ? '1' : 'N'}';
    lines.add(BomLine(
      description:
          'SPD ${r.type.label} $conn Uc $uc V — ${panelName[id] ?? id}',
          location: panelName[id] ?? id,
      qty: 1,
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}spd:${r.type.name}:${uc}v:'
          '${conn.toLowerCase()}',
    ));
  }

  // ── Earth electrode rods (only when the electrode is designed) ───────────
  if (electrode != null && electrode.rodCount > 0) {
    final len = _fmt(electrode.rodLengthM);
    final dia = _fmt(electrode.rodDiameterMm);
    lines.add(BomLine(
      description: 'Earth electrode rod Ø$dia mm × $len m',
      qty: electrode.rodCount.toDouble(),
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}earth-rod:${dia}mm:${len}m',
    ));
  }

  // ── Main earthing conductor (BC bare copper, MET → electrode) ────────────
  // Round 29 — ordered as its ladder make-up: n parallel conductors of one
  // ladder section (never an unorderable `1x600 mm²`).
  final met = sys.earthing.mainEarthingPerConductorMm2;
  final metCount = sys.earthing.mainEarthingConductorCount;
  if (sys.panels.isNotEmpty && met > 0) {
    final csa = _fmt(met);
    lines.add(BomLine(
      description: 'Main earthing conductor BC 1x$csa mm² '
          '${metCount > 1 ? '($metCount in parallel, lot each, run length per '
              'site)' : '(lot, run length per site)'}',
      qty: metCount.toDouble(),
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}earthing:bc:$csa',
    ));
  }

  // ── Round 41 (elec-report-bom-2-containment-metering-never-taken-off) ────
  // The main protective BONDING conductor the calc report prints.
  final bond = sys.earthing.mainBondingConductorMm2;
  if (sys.panels.isNotEmpty && bond > 0) {
    final csa = _fmt(bond);
    lines.add(BomLine(
      description: 'Main protective bonding conductor 1x$csa mm² '
          '(lot, run length per site)',
      qty: 1,
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}earthing:bonding:$csa',
    ));
  }
  lines.addAll(containmentBomLines(sys, containment));
  lines.addAll(meteringBomLines(project, metering));
  return lines;
}

/// Round 41 — the CONTAINMENT take-off: every non-spare way's run, routed
/// exactly as its board-schedule row prints it (the containment study's
/// conduit when one holds the cable — `· [N x ]PVC <mm>mm · <L> m` — else
/// `· tray`): conduit metres per trade size = Σ run length × the way's
/// conduit count (one conduit per parallel run), tray metres per width (the
/// board's tray study) = Σ run length. A way with no measured length adds
/// nothing (never a fabricated metre). The per-run tray metres are an UPPER
/// bound — shared tray routes are not de-duplicated (`// VERIFY`
/// notAnSniClause: take-off practice, confirm against the routing layout).
List<BomLine> containmentBomLines(
  ElectricalSystemResult sys,
  Map<String, ContainmentResult> containment,
) {
  final conduitM = <int, double>{};
  final trayM = <int, double>{};
  final panelIds = sys.panels.keys.toList()..sort();
  for (final pid in panelIds) {
    final study = containment[pid];
    if (study == null) continue;
    final specById = {for (final c in study.conduits) c.circuitId: c};
    for (final c in sys.panels[pid]!.circuits) {
      if (c.loadKind == LoadKind.spare || c.lengthM <= 0) continue;
      final cc = specById[c.circuitId];
      if (cc == null) continue;
      final fits = cc.conduit.fillPct <= conduitFillSingle * 100;
      if (fits) {
        final mm = cc.conduit.conduitSizeMm.round();
        final runs =
            (c.cable.runsPerPhase ?? 1) > 1 ? c.cable.runsPerPhase! : 1;
        conduitM[mm] = (conduitM[mm] ?? 0) + c.lengthM * runs;
      } else {
        final w = study.tray.widthMm.round();
        trayM[w] = (trayM[w] ?? 0) + c.lengthM;
      }
    }
  }
  double m1(double v) => (v * 10).roundToDouble() / 10;
  return [
    for (final mm in conduitM.keys.toList()..sort())
      BomLine(
        description: 'PVC conduit ${mm}mm',
        qty: m1(conduitM[mm]!),
        category: PartCategory.accessory,
        priceKey: '${kElecPriceKeyPrefix}containment:conduit:$mm',
      ),
    for (final w in trayM.keys.toList()..sort())
      BomLine(
        description: 'Cable tray ${w}mm (per-run metres, verify shared routes)',
        qty: m1(trayM[w]!),
        category: PartCategory.accessory,
        priceKey: '${kElecPriceKeyPrefix}containment:tray:$w',
      ),
  ];
}

/// Round 41 — the METERING take-off, exactly the instruments the board
/// schedule draws: every 3-phase board carries V / A / Hz panel meters, a
/// kWh meter (`kWh direct` whole-current, else CT-operated) and, when
/// CT-operated, one CT set (3 CTs of the study's ratio + class). Single-phase
/// final boards carry no metering (the schedule draws none). CTs stay
/// UNMATCHED on `elec:ct:<ratio>:<class>`: the catalogue CTs declare no
/// accuracy class, so a revenue 0.5S CT can never be confirmed from it.
List<BomLine> meteringBomLines(
  ElectricalProject project,
  Map<String, MeteringSpec> metering,
) {
  final out = <BomLine>[];
  final panels = [...project.panels]..sort((a, b) => a.id.compareTo(b.id));
  for (final p in panels) {
    if (p.system != ElectricalSystem.threePhase) continue;
    final m = metering[p.id];
    if (m == null) continue;
    final where = p.name;
    for (final (label, key) in const [
      ('Voltmeter', 'voltmeter'),
      ('Ammeter', 'ammeter'),
      ('Frequency meter', 'frequency'),
    ]) {
      out.add(BomLine(
        description: '$label (panel) — $where',
        location: where,
        qty: 1,
        category: PartCategory.accessory,
        priceKey: '${kElecPriceKeyPrefix}meter:$key',
      ));
    }
    final direct = m.metering == MeteringKind.direct;
    out.add(BomLine(
      description: direct
          ? 'kWh meter, direct (whole-current) — $where'
          : 'kWh meter, CT-operated — $where',
          location: where,
      qty: 1,
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}meter:kwh:${direct ? 'direct' : 'ct'}',
    ));
    if (!direct && m.ctRatio != null) {
      final cls = m.ctClass ?? '';
      out.add(BomLine(
        description: 'Current transformer ${m.ctRatio}A cl.$cls'
            '${m.ladderExceeded ? ' (special ratio required)' : ''} — $where',
            location: where,
        qty: 3,
        category: PartCategory.accessory,
        priceKey: '${kElecPriceKeyPrefix}ct:${_keyToken(m.ctRatio!)}:'
            '${_keyToken(cls)}',
      ));
    }
  }
  return out;
}
