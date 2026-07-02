import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/recovery.dart';

void main() {
  test('probe: atomicWriteString on the global recovery path', () async {
    final path = '${Directory.systemTemp.path}/mechx_recovery.mechx';
    for (final p in [path, '$path.tmp', '$path.bak']) {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    }
    try {
      await atomicWriteString(path, '{"probe": true}');
      // ignore: avoid_print
      print('write ok; exists: ${File(path).existsSync()}, '
          'tmp: ${File('$path.tmp').existsSync()}');
    } catch (e, st) {
      // ignore: avoid_print
      print('write FAILED: $e');
      // ignore: avoid_print
      print('$st');
    }
  });
}
