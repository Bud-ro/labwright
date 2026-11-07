@Tags(['corpus'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'corpus_snapshot.dart';

void main() {
  test('every corpus .seq keeps exactly its snapshotted format, version and counts', () {
    final want = File(
      corpusSnapshotPath,
    ).readAsLinesSync().where((l) => l.startsWith('{')).map((l) => l.replaceAll(RegExp(r',$'), ''));
    final got = corpusSnapshotLines();
    final missing = want.toSet().difference(got.toSet()), added = got.toSet().difference(want.toSet());
    expect(
      missing.isEmpty && added.isEmpty,
      isTrue,
      reason: 'regenerate with `dart run tool/snapshot.dart`\n- ${missing.join('\n- ')}\n+ ${added.join('\n+ ')}',
    );
  });
}
