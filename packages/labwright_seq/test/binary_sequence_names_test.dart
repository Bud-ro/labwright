@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Validates binary sequence-name recovery ([binarySequenceNames]) against the
/// content-exact Rosetta twins: for each `*_BIN.seq` the names decoded from the
/// binary object-path declarations must equal the sequence list its XML/python
/// twin parses to via [parseSeqFile]. Skips when the corpus is not fetched.
///
/// Twin pairing is by shared prefix before the toolchain tag (`OutputVoltage`,
/// `NIDmm`, …); the binary is `<prefix>_labview_BIN.seq` or `<prefix>_BIN.seq`,
/// the model twin is `<prefix>_python_XML.seq` or `<prefix>_XML.seq`.
File? _twin(Directory dir, String binName) {
  final prefix = binName
      .replaceAll('_labview_BIN.seq', '')
      .replaceAll('_BIN.seq', '');
  for (final suffix in ['_python_XML.seq', '_XML.seq', '_python.seq']) {
    final f = File('${dir.path}/$prefix$suffix');
    if (f.existsSync()) return f;
  }
  return null;
}

void main() {
  final rosetta = Directory('${corpusSeqDir.path}/rosetta');
  if (!rosetta.existsSync()) {
    test('binary sequence names (skipped: Rosetta corpus not fetched)', () {},
        skip: true);
    return;
  }

  final binaries = rosetta
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('_BIN.seq'))
      .toList();

  test('a binary twin is present to validate against', () {
    expect(binaries, isNotEmpty);
  });

  for (final bin in binaries) {
    final name = bin.uri.pathSegments.last;
    test('$name: binary sequence names match its XML twin', () {
      final twin = _twin(rosetta, name);
      if (twin == null) return; // no model twin fetched for this binary
      final expected =
          parseSeqFile(Uint8List.fromList(twin.readAsBytesSync()))
              .sequences
              .map((s) => s.name)
              .toList();
      final actual =
          binarySequenceNames(Uint8List.fromList(bin.readAsBytesSync()));
      expect(actual, equals(expected),
          reason: 'binary decoded $actual, XML twin has $expected');
    });
  }
}
