@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// End-to-end oracle test for the binary → typed-model path: [parseSeqFile] on
/// the content-exact `OutputVoltage_BIN.seq` must reconstruct the same sequence
/// with the same grouped, ordered step names as its XML twin. Skips when the
/// corpus is not fetched.
void main() {
  final rosetta = Directory('${corpusSeqDir.path}/rosetta');
  final bin = File('${rosetta.path}/OutputVoltage_BIN.seq');
  final xml = File('${rosetta.path}/OutputVoltage_XML.seq');
  if (!bin.existsSync() || !xml.existsSync()) {
    test('binary parseSeqFile (skipped: Rosetta corpus not fetched)', () {},
        skip: true);
    return;
  }

  final binFile = parseSeqFile(Uint8List.fromList(bin.readAsBytesSync()));
  final xmlFile = parseSeqFile(Uint8List.fromList(xml.readAsBytesSync()));

  test('binary parses to the same sequences as the content-exact XML twin', () {
    expect(binFile.sequences.map((s) => s.name).toList(),
        xmlFile.sequences.map((s) => s.name).toList());
  });

  test('grouped, ordered step names match the XML twin exactly', () {
    for (var i = 0; i < xmlFile.sequences.length; i++) {
      final xs = xmlFile.sequences[i];
      final bs = binFile.sequences[i];
      expect(bs.setup.map((s) => s.name).toList(),
          xs.setup.map((s) => s.name).toList(),
          reason: '${xs.name}.Setup');
      expect(bs.main.map((s) => s.name).toList(),
          xs.main.map((s) => s.name).toList(),
          reason: '${xs.name}.Main');
      expect(bs.cleanup.map((s) => s.name).toList(),
          xs.cleanup.map((s) => s.name).toList(),
          reason: '${xs.name}.Cleanup');
    }
  });

  test('the partial model is honest: undecoded lenses read empty, not fabricated', () {
    expect(binFile.types, isEmpty);
    for (final seq in binFile.sequences) {
      expect(seq.locals, isEmpty, reason: 'locals are not yet decoded from binary');
      expect(seq.parameters, isEmpty);
      for (final step in seq.steps) {
        expect(step.type, isNull, reason: 'step types are not yet decoded from binary');
      }
    }
  });
}
