/// Distributed energy sources for the electrical domain — standby/prime
/// generator (+ motor-start voltage-dip screen), grid-tied / hybrid solar PV
/// array + inverter, and a backup battery bank. Ported from PanelMaker
/// `engine/{sources,gensetTransient}.ts` + `standards/{sources,gensetTransient}.ts`.
///
/// Pure Dart, ZERO Flutter imports. SI typed quantities cross every API
/// (`ApparentPower`, `Power`, `Energy`, `Voltage`); engineering units are
/// constructed / read only at the boundary.
///
/// Standards / verification: every reference constant below is a typical
/// Indonesian-market design default tagged `// VERIFY` — confirm against the
/// alternator / panel / battery datasheets (and, for the dip screen, ISO 8528-5
/// + IEC 60034-4). None is an SNI/PUIL verbatim clause; results carry the
/// applicable defaults in their `verifyItems` so the honesty surface survives.
/// Folding these into `PuilProfile` is a deliberate follow-up.
library;

import 'dart:math' as math;

import '../units.dart';

// ===========================================================================
// Reference data (local `// VERIFY` constants — see the library doc).
// ===========================================================================

/* ------------------------------- Generator -------------------------------- */

/// Standard genset apparent-power ratings (kVA). // VERIFY — typical market ladder.
const List<double> kGeneratorKva = <double>[
  10, 15, 20, 25, 33, 40, 50, 65, 82, 100, 125, 150, 200, 250, 300, 350, 400,
  500, 650, 800, 1000, 1250, 1500, 2000, 2500,
];

/// Typical genset power factor. // VERIFY — datasheet value.
const double kGeneratorPf = 0.8;

/// Diesel specific fuel consumption (litres per kWh) at ~75% loading.
/// // VERIFY — engine datasheet.
const double kGensetSfcLPerKwh = 0.25;

/// Standard day-tank runtime target (hours) used to recommend a tank size.
/// // VERIFY — project requirement.
const double kGensetDayTankHours = 8;

/// Smallest standard genset (kVA) covering a required apparent power.
ApparentPower selectGeneratorKva(ApparentPower required) {
  final reqKva = required.inKilovoltAmperes;
  for (final k in kGeneratorKva) {
    if (k >= reqKva) return ApparentPower.kilovoltAmperes(k);
  }
  return ApparentPower.kilovoltAmperes(kGeneratorKva.last);
}

/* ------------------------------ Genset dip -------------------------------- */

/// Typical per-unit direct-axis sub-transient reactance Xd'' of a genset
/// alternator on its own kVA base (real machines ~0.12–0.20 pu).
/// // VERIFY — IEC 60034-4 / alternator datasheet.
const double kGensetSubtransientReactancePu = 0.15;

/// Maximum permissible MOMENTARY terminal-voltage dip during motor starting
/// (% of nominal). // VERIFY — ISO 8528-5 transient-deviation class.
const double kMaxStartVoltageDipPct = 25;

/// Effective combined motor η·pf converting shaft kW → electrical kVA.
/// // VERIFY — motor datasheet (~0.8 general LV induction).
const double kMotorKvaFromKwFactor = 0.8;

/// Starting-kVA as a multiple of a motor's RUNNING (full-load) kVA, by starter
/// method (how each starter limits inrush). // VERIFY — IEC 60947-4-1 basis.
const Map<String, double> kStartKvaMultiple = <String, double>{
  'DOL': 6,
  'STAR_DELTA': 2,
  'SOFT_STARTER': 3,
  'VFD': 1,
  'REVERSING': 6,
  'PUMP': 6,
  'ATS': 6,
};

/// Fallback multiple for unrecognised starter strings (worst case = DOL).
const double kDefaultStartKvaMultiple = 6;

/// Starting-kVA multiple of running kVA for a starter method (case-insensitive;
/// unknown → DOL, the worst case).
double startKvaMultiple(String? starterType) {
  if (starterType == null) return kDefaultStartKvaMultiple;
  final key = starterType.trim().toUpperCase();
  return kStartKvaMultiple[key] ?? kDefaultStartKvaMultiple;
}

/// Motor running (full-load) apparent power from rated shaft power
/// (kVA ≈ kW / 0.8). Zero for non-positive input.
ApparentPower motorRunningKva(Power shaftPower) {
  final kw = shaftPower.inKiloWatts;
  if (!(kw > 0)) return const ApparentPower(0);
  return ApparentPower.kilovoltAmperes(kw / kMotorKvaFromKwFactor);
}

/* ---------------------------------- Solar --------------------------------- */

/// A typical 550 Wp monocrystalline panel. // VERIFY — module datasheet.
const int kPvPanelDefaultWp = 550;

/// Voltage at max power (V). // VERIFY.
const double kPvVmp = 41.7;

/// Open-circuit voltage (V). // VERIFY.
const double kPvVoc = 49.5;

/// MPPT operating window + system limits for a ~1000 V string inverter (V).
/// // VERIFY — inverter datasheet.
const double kMpptVmin = 200;
const double kMpptVmax = 850;
const double kMaxSystemVoltage = 1000;

/// Cold-temperature Voc-rise factor used when checking the max-voltage limit.
/// // VERIFY — site min temperature.
const double kVocColdFactor = 1.15;

/// Indonesian average peak-sun-hours per day. // VERIFY — site irradiance data.
const double kPeakSunHours = 4.8;

/// Overall PV performance ratio (soiling, temperature, wiring, inverter).
/// // VERIFY.
const double kPvPerformanceRatio = 0.8;

/// Default DC/AC (array-to-inverter) oversizing ratio. // VERIFY.
const double kDcAcRatio = 1.2;

/// Standard inverter AC ratings (kW), shared by PV + battery inverters.
/// // VERIFY — typical market ladder.
const List<double> kInverterKw = <double>[
  3, 5, 8, 10, 15, 20, 25, 30, 40, 50, 60, 80, 100, 125, 150, 200, 250,
];

/// Smallest standard inverter (kW) covering a required power.
Power selectInverterKw(Power required) {
  final reqKw = required.inKiloWatts;
  for (final k in kInverterKw) {
    if (k >= reqKw) return Power.kiloWatts(k);
  }
  return Power.kiloWatts(kInverterKw.last);
}

/* --------------------------------- Battery -------------------------------- */

/// Battery chemistry, with its usable depth-of-discharge.
enum BatteryChemistry { lifepo4, leadAcid }

extension BatteryChemistryInfo on BatteryChemistry {
  /// Usable depth-of-discharge (0–1). // VERIFY — cell datasheet.
  double get depthOfDischarge => switch (this) {
        BatteryChemistry.lifepo4 => 0.9,
        BatteryChemistry.leadAcid => 0.5,
      };

  String get label => switch (this) {
        BatteryChemistry.lifepo4 => 'LiFePO4',
        BatteryChemistry.leadAcid => 'lead-acid',
      };
}

/// A typical 5.12 kWh (51.2 V / 100 Ah) LiFePO4 module. // VERIFY — datasheet.
const Energy kBatteryModuleLfp = Energy(5.12 * 3.6e6);

/// One-way discharge-path efficiency (battery DC → inverter → AC load). Backup
/// autonomy sizing only incurs the discharge side, so the full round-trip
/// efficiency would double-count the charging loss. // VERIFY — ~0.95.
const double kBatteryDischargeEfficiency = 0.95;

// ===========================================================================
// Input type — `ElectricalSources` (this domain's OWN immutable input; NOT a
// field on `ElectricalProject`, which the parent wires it onto at integration).
// ===========================================================================

/// Generator transfer arrangement.
enum GeneratorTransfer { ats, manual }

extension GeneratorTransferInfo on GeneratorTransfer {
  bool get isManual => this == GeneratorTransfer.manual;
}

/// Generator (genset) duty mode.
enum GeneratorMode { standby, prime }

extension GeneratorModeInfo on GeneratorMode {
  String get label => switch (this) {
        GeneratorMode.standby => 'Standby',
        GeneratorMode.prime => 'Prime (continuous)',
      };
}

/// Standby/prime generator request.
class GeneratorSource {
  /// Optional user-forced rating; when set, the ladder selection is skipped.
  final ApparentPower? kva;

  /// Fraction of the building demand the genset must back up (0–1) when no
  /// explicit essential demand is supplied.
  final double backupFraction;

  /// standby = intermittent (mains failure); prime = continuous (needs headroom).
  final GeneratorMode mode;

  /// Automatic transfer switch (default) vs a manual changeover (COS).
  final GeneratorTransfer transfer;

  const GeneratorSource({
    this.kva,
    this.backupFraction = 1.0,
    this.mode = GeneratorMode.standby,
    this.transfer = GeneratorTransfer.ats,
  });
}

/// Grid-tied / hybrid solar PV request.
class SolarSource {
  /// Panel nameplate power (Wp).
  final int panelWp;

  /// Number of panels in the array.
  final int panels;

  /// DC/AC (array-to-inverter) oversizing ratio.
  final double dcAcRatio;

  const SolarSource({
    this.panelWp = kPvPanelDefaultWp,
    required this.panels,
    this.dcAcRatio = kDcAcRatio,
  });
}

/// Backup battery request.
class BatterySource {
  /// Cell chemistry (sets depth-of-discharge).
  final BatteryChemistry chemistry;

  /// Required autonomy (hours) at the critical load.
  final double autonomyHours;

  const BatterySource({
    this.chemistry = BatteryChemistry.lifepo4,
    required this.autonomyHours,
  });
}

/// The energy-sources design input. Any subset may be present; an absent source
/// is simply not sized. Immutable.
class ElectricalSources {
  final GeneratorSource? generator;
  final SolarSource? solar;
  final BatterySource? battery;

  /// Topology of the DC-coupled sources. A hybrid (multi-mode) inverter combines
  /// the PV array, the battery and the grid into ONE unit feeding the bus.
  /// Null = auto: hybrid whenever both solar and battery are present.
  final bool? hybridInverter;

  const ElectricalSources({
    this.generator,
    this.solar,
    this.battery,
    this.hybridInverter,
  });
}

// ===========================================================================
// Result types.
// ===========================================================================

/// One motor the genset must be able to start (for the dip screen).
class GensetMotor {
  final String? name;

  /// Rated mechanical shaft power.
  final Power shaftPower;

  /// Starter method (loose string; see [startKvaMultiple]). Null = DOL.
  final String? starterType;

  const GensetMotor({this.name, required this.shaftPower, this.starterType});
}

/// Outcome of a genset motor-starting voltage-dip screen.
class GensetStartResult {
  /// Genset continuous apparent-power rating assessed.
  final ApparentPower gensetKva;

  /// Name of the worst (limiting) motor, if any.
  final String? limitingMotorName;

  /// Starting apparent power of the limiting motor.
  final ApparentPower startingKva;

  /// Estimated momentary voltage dip for the limiting motor (% of nominal).
  final double estimatedDipPct;

  /// True when the estimated dip is within [kMaxStartVoltageDipPct].
  final bool acceptable;

  /// Smallest genset rating that holds the limiting motor's dip within limit.
  final ApparentPower recommendedMinGensetKva;

  final String note;
  final String clause;

  const GensetStartResult({
    required this.gensetKva,
    this.limitingMotorName,
    required this.startingKva,
    required this.estimatedDipPct,
    required this.acceptable,
    required this.recommendedMinGensetKva,
    required this.note,
    required this.clause,
  });
}

/// Generator sizing result.
class GeneratorResult {
  /// Selected standard rating.
  final ApparentPower ratingKva;

  /// The backup demand the genset was sized against.
  final ApparentPower backupKva;

  final GeneratorMode mode;
  final GeneratorTransfer transfer;

  /// Estimated diesel consumption at the backup load (litres/hour).
  final double fuelLph;

  /// Recommended day-tank capacity (litres) for the runtime target.
  final double dayTankL;

  /// Runtime (hours) the recommended day-tank provides.
  final double runtimeHours;

  final String note;
  final List<String> verifyItems;

  const GeneratorResult({
    required this.ratingKva,
    required this.backupKva,
    required this.mode,
    required this.transfer,
    required this.fuelLph,
    required this.dayTankL,
    required this.runtimeHours,
    required this.note,
    required this.verifyItems,
  });
}

/// Solar PV array + inverter + string sizing result.
class SolarResult {
  final int panelWp;
  final int panelCount;

  /// Installed DC array size.
  final Power arrayKwp;

  /// Selected inverter AC rating.
  final Power inverterKw;

  /// Panels in series per string.
  final int stringSize;

  /// Number of parallel strings.
  final int strings;

  /// Estimated daily energy yield.
  final Energy dailyKwh;

  final String note;
  final List<String> verifyItems;

  const SolarResult({
    required this.panelWp,
    required this.panelCount,
    required this.arrayKwp,
    required this.inverterKw,
    required this.stringSize,
    required this.strings,
    required this.dailyKwh,
    required this.note,
    required this.verifyItems,
  });
}

/// Battery-bank sizing result.
class BatteryResult {
  final BatteryChemistry chemistry;

  /// Energy the bank must store after DoD + discharge-efficiency losses.
  final Energy requiredKwh;

  /// Usable energy of the installed modules (installed × DoD).
  final Energy usableKwh;

  /// Installed (nameplate) energy = moduleCount × moduleKwh.
  final Energy installedKwh;

  final Energy moduleKwh;
  final int moduleCount;

  /// Inverter/charger AC rating.
  final Power inverterKw;

  /// The critical load the bank was sized for.
  final Power criticalLoad;

  final String note;
  final List<String> verifyItems;

  const BatteryResult({
    required this.chemistry,
    required this.requiredKwh,
    required this.usableKwh,
    required this.installedKwh,
    required this.moduleKwh,
    required this.moduleCount,
    required this.inverterKw,
    required this.criticalLoad,
    required this.note,
    required this.verifyItems,
  });
}

// ===========================================================================
// Sizing functions.
// ===========================================================================

double _round(double x, [int dp = 2]) {
  final f = math.pow(10, dp).toDouble();
  return (x * f).round() / f;
}

int _ceil(double x) => x.ceil();

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Estimated momentary voltage-dip % for a starting kVA against a genset rating,
/// via the voltage-divider model with Xd'' the alternator sub-transient
/// reactance: dip = 100·z/(gen + z), z = startKva·Xd''.
double _estimateDipPct(double startKva, double genKva) {
  if (genKva <= 0) return 100;
  if (startKva <= 0) return 0;
  final z = startKva * kGensetSubtransientReactancePu;
  return 100 * (z / (genKva + z));
}

/// Smallest genset kVA holding the dip from [startKva] within [limitPct].
/// From dip ≤ limit ⇒ gen ≥ z·(100 − limit)/limit, z = startKva·Xd''.
double _minGensetKvaForDip(double startKva, double limitPct) {
  if (startKva <= 0) return 0;
  if (limitPct <= 0) return double.infinity;
  final z = startKva * kGensetSubtransientReactancePu;
  return z * ((100 - limitPct) / limitPct);
}

/// Assess whether a genset can start its motors within the permissible momentary
/// voltage dip. The limiting case is the single largest motor (by starting kVA)
/// against the rating; with no motors the result is trivially acceptable.
GensetStartResult assessGensetStart(
  ApparentPower gensetKva, {
  List<GensetMotor> motors = const <GensetMotor>[],
}) {
  const clause = 'ISO 8528-5 / IEC 60034-4';
  final genKva = _round(gensetKva.inKilovoltAmperes);

  final candidates =
      motors.where((m) => m.shaftPower.inKiloWatts > 0).toList();

  if (candidates.isEmpty) {
    return GensetStartResult(
      gensetKva: ApparentPower.kilovoltAmperes(genKva),
      startingKva: const ApparentPower(0),
      estimatedDipPct: 0,
      acceptable: true,
      recommendedMinGensetKva: const ApparentPower(0),
      note: 'no motors',
      clause: clause,
    );
  }

  // Limiting motor = largest starting kVA (worst per-motor dip).
  GensetMotor limiting = candidates.first;
  double limitingStartKva =
      motorRunningKva(limiting.shaftPower).inKilovoltAmperes *
          startKvaMultiple(limiting.starterType);
  for (final m in candidates.skip(1)) {
    final sk = motorRunningKva(m.shaftPower).inKilovoltAmperes *
        startKvaMultiple(m.starterType);
    if (sk > limitingStartKva) {
      limiting = m;
      limitingStartKva = sk;
    }
  }

  final estimatedDipPct = _round(_estimateDipPct(limitingStartKva, genKva));
  final acceptable = estimatedDipPct <= kMaxStartVoltageDipPct;
  final recommendedMin =
      _round(_minGensetKvaForDip(limitingStartKva, kMaxStartVoltageDipPct));

  final who = (limiting.name != null && limiting.name!.isNotEmpty)
      ? '"${limiting.name}"'
      : 'the largest motor';
  final note = acceptable
      ? 'Starting $who (${_round(limitingStartKva, 1)} kVA) dips '
          '$estimatedDipPct% on a $genKva kVA genset — within the '
          '${_fmt(kMaxStartVoltageDipPct)}% limit.'
      : 'Starting $who (${_round(limitingStartKva, 1)} kVA) dips '
          '$estimatedDipPct% on a $genKva kVA genset — exceeds the '
          '${_fmt(kMaxStartVoltageDipPct)}% limit; use at least '
          '$recommendedMin kVA (or a reduced-inrush starter).';

  return GensetStartResult(
    gensetKva: ApparentPower.kilovoltAmperes(genKva),
    limitingMotorName: limiting.name,
    startingKva: ApparentPower.kilovoltAmperes(_round(limitingStartKva)),
    estimatedDipPct: estimatedDipPct,
    acceptable: acceptable,
    recommendedMinGensetKva: ApparentPower.kilovoltAmperes(recommendedMin),
    note: note,
    clause: clause,
  );
}

/// Size a standby/prime generator for a backup demand. Prime (continuous) duty
/// needs ~25% headroom; standby covers the backup load directly. A user-forced
/// [GeneratorSource.kva] is honoured verbatim (no ladder snap).
///
/// [backupDemand] is the apparent power the genset must back (the essential bus,
/// or `backupFraction` × the building demand — resolved by the caller).
GeneratorResult sizeGenerator(
  ApparentPower backupDemand, {
  GeneratorMode mode = GeneratorMode.standby,
  GeneratorTransfer transfer = GeneratorTransfer.ats,
  ApparentPower? forcedKva,
}) {
  final backupKva = backupDemand.inKilovoltAmperes;
  final required = mode == GeneratorMode.prime ? backupKva * 1.25 : backupKva;
  final ratingKva =
      forcedKva ?? selectGeneratorKva(ApparentPower.kilovoltAmperes(required));

  final transferText = transfer.isManual
      ? 'Manual changeover (COS) — an operator must transfer; expect an outage '
          'until switched.'
      : 'Transfers automatically on mains failure via ATS.';

  // Fuel & runtime: diesel burns ~0.25 l/kWh; size a day-tank for the standard
  // runtime so the standby deliverable carries autonomy like the battery does.
  final loadKw = backupKva * kGeneratorPf;
  final fuelLph = _round(loadKw * kGensetSfcLPerKwh, 1);
  const runtimeHours = kGensetDayTankHours;
  // Round the day-tank up to the next 10 L, with a 10 L floor.
  final dayTankL =
      math.max(10, (_ceil((fuelLph * runtimeHours) / 10)) * 10).toDouble();
  final fuelText = fuelLph > 0
      ? ' Fuel ≈ $fuelLph l/h at the backup load; a ${_fmt(dayTankL)} L '
          'day-tank gives ~${_fmt(runtimeHours)} h runtime.'
      : '';

  return GeneratorResult(
    ratingKva: ratingKva,
    backupKva: ApparentPower.kilovoltAmperes(_round(backupKva, 1)),
    mode: mode,
    transfer: transfer,
    fuelLph: fuelLph,
    dayTankL: dayTankL,
    runtimeHours: runtimeHours,
    note: '${mode.label} genset backing ${_round(backupKva, 1)} kVA → '
        '${_fmt(ratingKva.inKilovoltAmperes)} kVA. $transferText$fuelText',
    verifyItems: const <String>[
      'Genset kVA ladder + power factor (0.8) — confirm against the genset datasheet.',
      'Diesel SFC (0.25 l/kWh) + day-tank runtime target (8 h) — confirm against the engine spec.',
    ],
  );
}

/// Size a grid-tied / hybrid solar PV array, its inverter and string layout.
/// [panels] × [panelWp] sets the array kWp; the inverter is the smallest
/// standard size ≥ arrayKwp / dcAcRatio; string length is bounded by the MPPT
/// window and the cold-Voc max-system-voltage limit.
SolarResult sizeSolar({
  required int panelWp,
  required int panels,
  double dcAcRatio = kDcAcRatio,
  double sunHours = kPeakSunHours,
}) {
  final panelCount = math.max(1, panels);
  final arrayKwp = _round(panelCount * panelWp / 1000, 2);
  final inverterKw = selectInverterKw(Power.kiloWatts(arrayKwp / dcAcRatio));

  // String length: MPPT window + cold-Voc max-system-voltage limit.
  final maxByMppt = (kMpptVmax / kPvVmp).floor();
  final maxByVoltage = (kMaxSystemVoltage / (kPvVoc * kVocColdFactor)).floor();
  final minByMppt = math.max(1, (kMpptVmin / kPvVmp).ceil());
  final stringSize = math.max(
    minByMppt,
    math.min(math.min(maxByMppt, maxByVoltage), panelCount),
  );
  final strings = (panelCount / stringSize).ceil();

  final dailyKwh = _round(arrayKwp * sunHours * kPvPerformanceRatio, 1);

  return SolarResult(
    panelWp: panelWp,
    panelCount: panelCount,
    arrayKwp: Power.kiloWatts(arrayKwp),
    inverterKw: inverterKw,
    stringSize: stringSize,
    strings: strings,
    dailyKwh: Energy.kilowattHours(dailyKwh),
    note: '$panelCount x $panelWp Wp ($arrayKwp kWp) as $strings string(s) of '
        '$stringSize; ${_fmt(inverterKw.inKiloWatts)} kW inverter (DC/AC '
        '$dcAcRatio); ~$dailyKwh kWh/day at $sunHours peak-sun-hours.',
    verifyItems: const <String>[
      'Panel Vmp/Voc + cold-Voc factor (1.15) + MPPT window — confirm against the module/inverter datasheets.',
      'Peak-sun-hours (4.8) + performance ratio (0.8) — confirm against site irradiance data.',
    ],
  );
}

/// Size a backup battery bank + inverter/charger for a critical load + autonomy.
/// Energy = load × hours / (DoD × discharge-efficiency) → module count
/// (round up). Backup autonomy only incurs the discharge path, so the round-trip
/// charging loss is deliberately not applied.
BatteryResult sizeBattery(
  Power criticalLoad, {
  required double autonomyHours,
  BatteryChemistry chemistry = BatteryChemistry.lifepo4,
  Energy moduleKwh = kBatteryModuleLfp,
}) {
  final backupKw = criticalLoad.inKiloWatts;
  final dod = chemistry.depthOfDischarge;
  final requiredKwh =
      backupKw * autonomyHours / (dod * kBatteryDischargeEfficiency);
  final modKwh = moduleKwh.inKilowattHours;
  final moduleCount = math.max(1, _ceil(requiredKwh / modKwh));
  final installedKwh = _round(moduleCount * modKwh, 2);
  final usableKwh = _round(installedKwh * dod, 2);
  final inverterKw = selectInverterKw(criticalLoad);

  return BatteryResult(
    chemistry: chemistry,
    requiredKwh: Energy.kilowattHours(_round(requiredKwh, 1)),
    usableKwh: Energy.kilowattHours(usableKwh),
    installedKwh: Energy.kilowattHours(installedKwh),
    moduleKwh: moduleKwh,
    moduleCount: moduleCount,
    inverterKw: inverterKw,
    criticalLoad: Power.kiloWatts(_round(backupKw, 1)),
    note: '${_round(backupKw, 1)} kW for ${_fmt(autonomyHours)} h '
        '(${chemistry.label}, DoD ${(dod * 100).round()}%, discharge eff '
        '${(kBatteryDischargeEfficiency * 100).round()}%) → '
        '${_round(requiredKwh, 1)} kWh ⇒ $moduleCount x ${_fmt(modKwh)} kWh = '
        '$installedKwh kWh; ${_fmt(inverterKw.inKiloWatts)} kW inverter/charger.',
    verifyItems: const <String>[
      'Battery DoD (LiFePO4 0.9 / lead-acid 0.5) + module kWh — confirm against the cell datasheet.',
      'Discharge-path efficiency (0.95) — confirm against the battery-inverter datasheet.',
    ],
  );
}
