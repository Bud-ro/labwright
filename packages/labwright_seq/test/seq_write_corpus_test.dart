@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

const _pinnedIniSeqCount = 45;
const _pinnedXmlSeqCount = 42;

void main() {
  final seqs =
      corpusSeqDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.seq'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('INI: write(parse(f)) == f byte-exact AND model/tree deep-equal for every INI .seq', () {
    var iniCount = 0;
    final mismatches = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
      iniCount++;
      final first = parseIniSeqBytes(bytes);
      final rewritten = writeIniSeq(first);
      if (!_bytesEqual(bytes, rewritten)) mismatches.add(f.path);
      final second = parseIniSeqBytes(rewritten);
      expect(iniDeepEquals(first, second), isTrue, reason: 'model drift after rewrite: ${f.path}');
      final firstTree = iniDataTree(first);
      expect(firstTree, isNotNull, reason: 'no data root: ${f.path}');
      expect(
        seqPropertyDeepEquals(firstTree!, iniDataTree(second)!),
        isTrue,
        reason: 'derived SeqProperty tree drift after rewrite: ${f.path}',
      );
    }
    print('INI .seq byte-exact round-trip: ${iniCount - mismatches.length}/$iniCount');
    expect(iniCount, _pinnedIniSeqCount, reason: 'INI corpus population changed — re-verify the writer over it');
    expect(mismatches, isEmpty, reason: 'every INI corpus file must round-trip byte-exactly');
  });

  test('XML: write(parse(f)) == f byte-exact AND model deep-equal for every XML .seq', () {
    var xmlCount = 0;
    final mismatches = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      xmlCount++;
      final first = parseSeqFile(bytes);
      final rewritten = writeSeqFileXml(first);
      if (!_bytesEqual(bytes, rewritten)) mismatches.add(f.path);
      expect(seqFileDeepEquals(first, parseSeqFile(rewritten)), isTrue, reason: 'model drift after rewrite: ${f.path}');
    }
    print('XML .seq byte-exact round-trip: ${xmlCount - mismatches.length}/$xmlCount');
    expect(xmlCount, _pinnedXmlSeqCount, reason: 'XML corpus population changed — re-verify the writer over it');
    expect(mismatches, isEmpty, reason: 'every XML corpus file must round-trip byte-exactly');
  });
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
