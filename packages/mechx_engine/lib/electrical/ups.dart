/// The UPS input constants (Round 44), a dependency-free leaf so both
/// `compute.dart` and `genset_backup.dart` read them without an import cycle
/// (Round 45 r2). Re-exported from `compute.dart`.
library;

/// Round 44 — a double-conversion UPS's input-to-output efficiency (the
/// rectifier + inverter losses its supply carries). // VERIFY
/// (notAnSniClause): typical online-UPS datasheet figure.
const double kUpsEfficiency = 0.94;

/// Round 44 — the battery-recharge allowance on the UPS input (× the
/// output-loss-adjusted load). // VERIFY (notAnSniClause): typical 10 %.
const double kUpsRechargeAllowance = 1.10;

/// Round 44 — the factor from a UPS-backed board's output demand to the
/// demand its feeder carries: `1 / η × recharge` (≈ 1.17).
const double kUpsInputFactor = kUpsRechargeAllowance / kUpsEfficiency;
