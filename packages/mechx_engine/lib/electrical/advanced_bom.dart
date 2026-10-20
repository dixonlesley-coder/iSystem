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
import 'control/starter.dart' show ControlAssembly, DeviceCategory;
import 'electrode.dart' show ElectrodeDesign;
import 'genset_backup.dart' show gensetBackupDemandVa, gensetBackupDemandW;
import 'load_kind.dart' show LoadKind;
import 'model.dart' show ElectricalProject, ElectricalSystem;
import 'panel_results.dart' show ElectricalSystemResult;
import 'power_factor.dart' show PowerFactorResult;
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
      final ratingKey = d.rating == null ? '' : ':${_keyToken(d.rating!)}';
      lines.add(BomLine(
        description: '${d.role}$rating — ${circuitName[id] ?? id}',
        qty: d.qty.toDouble(),
        category: PartCategory.accessory,
        priceKey: '${kElecPriceKeyPrefix}control:${d.category.name}$ratingKey',
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
  var installedKvar = 0.0;
  final bankPanelIds = [for (final p in project.panels) p.id]..sort();
  for (final id in bankPanelIds) {
    final p = project.panels.firstWhere((x) => x.id == id);
    var kvar = 0.0;
    for (final c in p.circuits) {
      if (c.loadKind == LoadKind.capacitor && c.loadW > 0) kvar += c.loadW;
    }
    if (kvar <= 0) continue;
    installedKvar += kvar / 1000;
    final k = _fmt(double.parse((kvar / 1000).toStringAsFixed(1)));
    lines.add(BomLine(
      description: 'Capacitor bank $k kvar — ${panelName[id] ?? id}',
      qty: 1,
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}capacitor-bank:${k}kvar',
    ));
  }
  final declaredBank = project.capacitorBankKvar;
  if (installedKvar <= 0 && declaredBank != null && declaredBank > 0) {
    installedKvar = declaredBank;
    final k = _fmt(double.parse(declaredBank.toStringAsFixed(1)));
    lines.add(BomLine(
      description: 'Capacitor bank $k kvar — LV main bus',
      qty: 1,
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}capacitor-bank:${k}kvar',
    ));
  }
  // The PF study's RECOMMENDED bank (APFC), unless an installed bank covers it.
  final pf = powerFactor;
  if (pf != null &&
      pf.needed &&
      pf.bankKvar > 0 &&
      installedKvar + 1e-9 < pf.bankKvar) {
    final banks = pf.banks < 1 ? 1 : pf.banks;
    final per = pf.bankKvar / banks;
    final k = _fmt(double.parse(per.toStringAsFixed(1)));
    lines.add(BomLine(
      description: 'Capacitor bank (APFC, recommended) $k kvar, '
          '${pf.steps} steps${pf.detuned ? ', detuned 7 %' : ''}',
      qty: banks.toDouble(),
      category: PartCategory.accessory,
      priceKey: '${kElecPriceKeyPrefix}capacitor-bank:${k}kvar'
          '${pf.detuned ? ':detuned' : ''}',
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
  return lines;
}
