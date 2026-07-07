@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// The number of INI-flavor `.seq` files in the pinned corpus — the byte-exact
/// gate asserts ALL of them round-trip, and pins the count so a corpus refresh
/// that adds INI files consciously extends the gate rather than silently
/// widening it.
const _pinnedIniSeqCount = 58;

/// A document in EXACTLY the writer's serialization (header first line, one
/// blank line before each section, trailing blank line, single-space ` = `)
/// wrapping the given section blocks — unit inputs are written in this shape
/// so `write(parse(input)) == input` can be asserted byte-for-byte.
String _doc(List<String> sections, {String nl = '\n', List<String>? header}) {
  final h =
      header ?? ['ProductName = "TestStand"', 'ProductVersion = 3.5.0.365', 'Version = 354', 'Type = "SequenceFile"'];
  final sb = StringBuffer('[__Header__]$nl');
  for (final line in h) {
    sb.write('$line$nl');
  }
  for (final section in sections) {
    sb.write(nl);
    for (final line in const LineSplitter().convert(section)) {
      sb.write('$line$nl');
    }
  }
  sb.write(nl);
  return sb.toString();
}

Uint8List _bytes(String doc) => Uint8List.fromList(latin1.encode(doc));

/// Asserts the writer reproduces [doc] byte-for-byte and returns the parse.
IniSeqFile _roundTrips(String doc) {
  final original = _bytes(doc);
  final file = parseIniSeqBytes(original);
  expect(writeIniSeq(file), original, reason: 'write(parse(doc)) must be byte-identical');
  return file;
}

void main() {
  group('writeIniSeq (unit)', () {
    test('quoting fidelity: bare vs quoted values survive verbatim, header included', () {
      final file = _roundTrips(
        _doc([
          '[SF]\n'
              'Version = "0.0.0.0"\n'
              'BatchSync = 1\n'
              'GoalTime = 0.5',
        ]),
      );
      expect(file.headerFields['ProductName'], '"TestStand"');
      expect(file.headerFields['ProductVersion'], '3.5.0.365', reason: 'bare header value must not gain quotes');
      final sf = file.sections.single;
      expect(sf.members['Version'], '"0.0.0.0"');
      expect(sf.members['BatchSync'], '1');
    });

    test('interleaved member/directive line order is retained and re-emitted', () {
      final file = _roundTrips(
        _doc([
          '[SF.Seq[0]]\n'
              'LoadOpt = "opts"\n'
              '%FLG: LoadOpt = 4194304\n'
              'Version = "0.0.0.0"\n'
              '%FLG: Hidden = 8\n'
              '%NAME = "MainSequence"',
        ]),
      );
      final s = file.sections.single;
      expect(s.entries.map((e) => e.key).toList(), [
        'LoadOpt',
        '%FLG: LoadOpt',
        'Version',
        '%FLG: Hidden',
        '%NAME',
      ], reason: 'entries must keep document order — the maps alone cannot');
      // The lone `%FLG: Hidden` names a member with no value line of its own.
      expect(s.members.containsKey('Hidden'), isFalse);
      expect(s.directives['%FLG: Hidden'], '8');
      expect(s.name, 'MainSequence');
    });

    test('continuation re-split: a 130-char inner splits into 120 + 10, byte-exactly', () {
      final inner = List.generate(130, (i) => 'abcdefghij'[i % 10]).join();
      final doc = _doc([
        '[SF]\n'
            'Text Line0001 = "${inner.substring(0, 120)}"\n'
            'Text Line0002 = "${inner.substring(120)}"\n'
            'After = 1',
      ]);
      final file = _roundTrips(doc);
      final s = file.sections.single;
      expect(s.entries.map((e) => e.key).toList(), ['Text', 'After'], reason: 'fragments rejoin at the first position');
      expect(s.members['Text'], '"$inner"');
    });

    test('continuation re-split: an exact multiple of 120 ends with a FULL fragment', () {
      final inner = List.generate(240, (i) => 'ABCDEFGHIJ'[i % 10]).join();
      final doc = _doc([
        '[SF]\n'
            'Text Line0001 = "${inner.substring(0, 120)}"\n'
            'Text Line0002 = "${inner.substring(120)}"',
      ]);
      final file = _roundTrips(doc);
      expect(file.sections.single.members['Text'], '"$inner"');
    });

    test('continuation re-split is escape-BLIND: a \\\\ pair straddles the 120 boundary', () {
      // 119 chars, then an escaped backslash whose two raw chars straddle the
      // fragment boundary (fragment 1 ends with a lone `\`) — corpus-real (270
      // odd-backslash fragment boundaries).
      final inner = '${'x' * 119}\\\\tail-after-the-straddle';
      final doc = _doc([
        '[SF]\n'
            'Expr Line0001 = "${inner.substring(0, 120)}"\n'
            'Expr Line0002 = "${inner.substring(120)}"',
      ]);
      expect(inner.substring(119, 121), r'\\');
      final file = _roundTrips(doc);
      expect(file.sections.single.members['Expr'], '"$inner"');
    });

    test('continuation re-split applies to HEADER fields too (corpus: a long Path)', () {
      final inner = List.generate(150, (i) => 'pqrstuvwxy'[i % 10]).join();
      final doc = _doc(
        ['[SF]\nVersion = "0.0.0.0"'],
        header: [
          'ProductName = "TestStand"',
          'Path Line0001 = "${inner.substring(0, 120)}"',
          'Path Line0002 = "${inner.substring(120)}"',
          'Version = 354',
          'Type = "SequenceFile"',
        ],
      );
      final file = _roundTrips(doc);
      expect(file.headerFields['Path'], '"$inner"');
      expect(file.headerFields.keys.toList(), [
        'ProductName',
        'Path',
        'Version',
        'Type',
      ], reason: 'rejoined at the first fragment position');
    });

    test('a 120-char inner is NOT split (the corpus threshold is inner > 120)', () {
      final inner = 'y' * 120;
      final file = _roundTrips(_doc(['[SF]\nText = "$inner"']));
      expect(file.sections.single.members['Text'], '"$inner"');
    });

    test('escaping inversion: escapeIniQuoted(x) parses back to x', () {
      const logical = 'a\\b"c\nd\te\rf';
      final raw = escapeIniQuoted(logical);
      expect(raw, '"a\\\\b\\"c\\nd\\te\\rf"');
      final file = _roundTrips(_doc(['[SF]\n%NAME = $raw']));
      expect(file.sections.single.name, logical, reason: 'the reader unescape must invert escapeIniQuoted');
    });

    test('CRLF file: the terminator is captured and replayed byte-exactly', () {
      final doc = _doc(['[SF]\nVersion = "0.0.0.0"'], nl: '\r\n');
      final file = _roundTrips(doc);
      expect(file.lineTerminator, '\r\n');
      // And the LF twin stays LF.
      expect(_roundTrips(_doc(['[SF]\nVersion = "0.0.0.0"'])).lineTerminator, '\n');
    });

    test('EXTDATA sections round-trip in their original document position', () {
      final file = _roundTrips(
        _doc([
          '[DEF, SF]\nSeq = Objs',
          '[EXTDATA, SF.Seq, STRUCT]\nType = 6\nName = "s"',
          '[SF]\nVersion = "0.0.0.0"',
        ]),
      );
      expect(file.sections[1].isExtData, isTrue);
      expect(file.sections[1].extDataKind, 'STRUCT');
      expect(file.sections[1].path, 'SF.Seq');
      expect(file.sections.map((s) => s.isExtData).toList(), [
        false,
        true,
        false,
      ], reason: 'EXTDATA must stay interleaved, not segregated');
    });

    test('model deep-equals: write→parse preserves the model; a mutation is detected', () {
      final doc = _doc(['[SF]\nVersion = "0.0.0.0"\n%FLG: Seq = 4194304']);
      final file = parseIniSeqBytes(_bytes(doc));
      final reparsed = parseIniSeqBytes(writeIniSeq(file));
      expect(iniDeepEquals(file, reparsed), isTrue);
      final other = parseIniSeqBytes(_bytes(doc.replaceFirst('"0.0.0.0"', '"0.0.0.1"')));
      expect(iniDeepEquals(file, other), isFalse);
      final reordered = parseIniSeqBytes(
        _bytes(
          doc.replaceFirst('Version = "0.0.0.0"\n%FLG: Seq = 4194304', '%FLG: Seq = 4194304\nVersion = "0.0.0.0"'),
        ),
      );
      expect(iniDeepEquals(file, reordered), isFalse, reason: 'entry order is fidelity, not noise');
    });
  });

  if (!corpusSeqDir.existsSync()) {
    test('INI seq writer corpus round-trip', () {}, skip: 'corpus absent — run tool/fetch_seq_corpus.dart');
    return;
  }

  group('writeIniSeq (corpus)', () {
    final seqs =
        corpusSeqDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.seq'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    test('BYTE-EXACT: write(parse(f)) == f for every INI .seq', () {
      var iniCount = 0, exact = 0;
      final mismatches = <String>[];
      for (final f in seqs) {
        final bytes = f.readAsBytesSync();
        if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
        iniCount++;
        final rewritten = writeIniSeq(parseIniSeqBytes(bytes));
        if (_bytesEqual(bytes, rewritten)) {
          exact++;
        } else {
          mismatches.add(f.path);
        }
      }
      // The fraction is the campaign's tracked metric — report it even on success.
      print('INI .seq byte-exact round-trip: $exact/$iniCount');
      expect(iniCount, _pinnedIniSeqCount, reason: 'INI corpus population changed — re-verify the writer over it');
      expect(mismatches, isEmpty, reason: 'every INI corpus file must round-trip byte-exactly');
      expect(exact, _pinnedIniSeqCount);
    });

    test('MODEL: parse(write(parse(f))) deep-equals parse(f), and the derived data tree too', () {
      var checked = 0;
      for (final f in seqs) {
        final bytes = f.readAsBytesSync();
        if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
        final first = parseIniSeqBytes(bytes);
        final second = parseIniSeqBytes(writeIniSeq(first));
        expect(iniDeepEquals(first, second), isTrue, reason: 'model drift after rewrite: ${f.path}');
        final firstTree = iniDataTree(first);
        final secondTree = iniDataTree(second);
        expect(firstTree, isNotNull, reason: 'no data root: ${f.path}');
        expect(
          seqPropertyDeepEquals(firstTree!, secondTree!),
          isTrue,
          reason: 'derived SeqProperty tree drift after rewrite: ${f.path}',
        );
        checked++;
      }
      expect(checked, _pinnedIniSeqCount);
    });
  });
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
