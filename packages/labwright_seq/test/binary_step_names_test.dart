@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Validates binary step recovery ([binaryStepNames]) against the Rosetta twins.
///
/// Only the `OutputVoltage` pair is content-exact (same file re-saved binary↔XML),
/// so its step *names* must match exactly. The other pairs are the same sequence
/// saved from different toolchains (LabVIEW binary vs Python XML), so their step
/// names legitimately differ — there the step *count* must match. Skips when the
/// corpus is not fetched.
File? _twin(Directory dir, String binName) {
  final prefix =
      binName.replaceAll('_labview_BIN.seq', '').replaceAll('_BIN.seq', '');
  for (final suffix in ['_python_XML.seq', '_XML.seq', '_python.seq']) {
    final f = File('${dir.path}/$prefix$suffix');
    if (f.existsSync()) return f;
  }
  return null;
}

Set<String> _xmlSteps(File twin) {
  final file = parseSeqFile(Uint8List.fromList(twin.readAsBytesSync()));
  return {
    for (final seq in file.sequences) ...[
      ...seq.setup.map((s) => s.name),
      ...seq.main.map((s) => s.name),
      ...seq.cleanup.map((s) => s.name),
    ],
  };
}

void main() {
  final rosetta = Directory('${corpusSeqDir.path}/rosetta');
  if (!rosetta.existsSync()) {
    test('binary step names (skipped: Rosetta corpus not fetched)', () {},
        skip: true);
    return;
  }

  final outputVoltage = File('${rosetta.path}/OutputVoltage_BIN.seq');
  test('content-exact twin: binary step names match the XML twin exactly', () {
    if (!outputVoltage.existsSync()) return;
    final actual =
        binaryStepNames(Uint8List.fromList(outputVoltage.readAsBytesSync()))
            .toSet();
    final expected = _xmlSteps(File('${rosetta.path}/OutputVoltage_XML.seq'));
    expect(actual, equals(expected));
  });

  for (final bin in rosetta
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('_BIN.seq'))) {
    final name = bin.uri.pathSegments.last;
    test('$name: binary step count matches its twin', () {
      final twin = _twin(rosetta, name);
      if (twin == null) return;
      final actual =
          binaryStepNames(Uint8List.fromList(bin.readAsBytesSync()));
      expect(actual, isNotEmpty);
      expect(actual.length, _xmlSteps(twin).length,
          reason: '$name decoded ${actual.length} steps: $actual');
    });
  }
}
