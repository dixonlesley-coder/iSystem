/// Display-boundary formatting helpers for the electrical workspace — convert
/// SI engine values to engineering units (A / kW / kVA / breaker / busbar /
/// RCD-type labels). Shared by the canvas, the inspector and the advanced card
/// so the formatting stays consistent.
library;

import 'package:mechx_engine/electrical/earthing.dart' show RcdType;
import 'package:mechx_engine/electrical/results.dart'
    show BreakerResult, BusbarResult;
import 'package:mechx_engine/standards/puil.dart' show BreakerClass;

/// One-or-zero-dp number.
String fmtNum(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// Whole-number amps.
String fmtAmp0(double a) =>
    a == a.roundToDouble() ? a.toInt().toString() : a.toStringAsFixed(0);

String fmtAmp(double a) => '${fmtNum(a)} A';

String fmtKw(double w) => '${(w / 1000).toStringAsFixed(1)} kW';

String fmtKva(double kva) => '${kva.toStringAsFixed(1)} kVA';

String fmtBreaker(BreakerResult b) {
  final cls = b.deviceClass == BreakerClass.mccb ? 'MCCB' : 'MCB';
  final curve = b.curve.name.toUpperCase();
  return '${fmtAmp0(b.ratingA.amperes)}A $cls·$curve';
}

String fmtBusbar(BusbarResult b) {
  if (b.widthMm > 0 && b.thicknessMm > 0) {
    return '${fmtNum(b.widthMm)}×${fmtNum(b.thicknessMm)} mm';
  }
  return '${fmtNum(b.csaMm2)} mm2';
}

String fmtRcdType(RcdType t) => switch (t) {
      RcdType.ac => 'AC',
      RcdType.a => 'A',
      RcdType.f => 'F',
      RcdType.b => 'B',
    };
