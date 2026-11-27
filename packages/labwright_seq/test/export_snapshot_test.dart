@Tags(['corpus'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'export_snapshot.dart';

void main() {
  test('every corpus source exports exactly its committed snapshot', () {
    final fresh = Directory('.dart_tool/export_snapshots');
    try {
      writeExportSnapshots(fresh);
      final want = readExportSnapshots(Directory(exportSnapshotPath)), got = readExportSnapshots(fresh);
      final changed = {...want.keys, ...got.keys}.where((path) => want[path] != got[path]).toList()..sort();
      expect(changed, isEmpty, reason: 'regenerate with `dart run tool/export_snapshot.dart`');
    } finally {
      if (fresh.existsSync()) fresh.deleteSync(recursive: true);
    }
  });
}
