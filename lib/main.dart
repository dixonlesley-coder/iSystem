import 'package:flutter/material.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/units.dart';

void main() {
  // Exercise the engine path dependency: compute cross-sectional area for a
  // DN100 pipe (inside diameter 100 mm) and display it. This is the only
  // purpose of main.dart in Phase 0 — real UI is built in later phases.
  final dn100 = Diameter(0.100); // 100 mm expressed in metres
  final area = circularArea(dn100); // Area in m²
  final areaStr = area.squareMeters.toStringAsFixed(6);

  runApp(MechXShell(dn100AreaM2: areaStr));
}

class MechXShell extends StatelessWidget {
  const MechXShell({super.key, required this.dn100AreaM2});

  final String dn100AreaM2;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('MechX shell - P0 UI pending (DN100 area = $dn100AreaM2 m2)'),
        ),
      ),
    );
  }
}
