@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Structural scaffold/model tokens that must never be recovered as TYPE
/// names — the same honesty gate the sequence-name sweep enforces (see
/// `binary_sequence_names_test.dart`: an ungated floating-window matcher
/// emitted structural tokens on 47/294 binaries until the corpus pinned it).
const _structuralTokens = {
  'SequenceFileData',
  'Data',
  'Seq',
  'Objs',
  'Obj',
  'Setup',
  'Main',
  'Cleanup',
  'Step',
  'Sequence',
  'Locals',
  'Parameters',
  'ResultList',
  'Calls',
};

/// Whole-corpus sweep for [binaryTypeNames]: the shape gate (pool-resolvable
/// identifier name + plausible save-timestamp + >=2 version-string refs) must
/// never emit structural scaffold tokens as type names, and its recovery
/// floors must not silently regress when the gates are tuned. The per-name
/// twin validation lives in `binary_parse_seq_file_test.dart` (only the
/// OutputVoltage pair is content-exact). Skips when the corpus is not fetched.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('binary type names (skipped: corpus not fetched)', () {},
        skip: 'corpus absent — run tool/fetch_seq_corpus.dart');
    return;
  }

  test('rosetta-wide: type-record HEADS match every twin, attribute for '
      'attribute', () {
    // Cross-file validation of the head layout AND the flag-naming rule
    // (count + typecategory): for every rosetta pair, every recovered type
    // that is a root typedef in the twin must match classname and every
    // SAVE-STABLE attribute exactly. Timestamps and version stamps differ
    // legitimately between the twin toolchains (only the OutputVoltage
    // pair is content-exact — the parse test pins those bytes too).
    final rosetta = Directory('${corpusSeqDir.path}/rosetta');
    var pairs = 0, compared = 0;
    for (final bin in rosetta
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('_BIN.seq'))) {
      final name = bin.uri.pathSegments.last;
      final prefix =
          name.replaceAll('_labview_BIN.seq', '').replaceAll('_BIN.seq', '');
      File? twin;
      for (final suffix in ['_python_XML.seq', '_XML.seq', '_python.seq']) {
        final f = File('${rosetta.path}/$prefix$suffix');
        if (f.existsSync()) {
          twin = f;
          break;
        }
      }
      if (twin == null) continue;
      pairs++;
      final twinByName = {
        for (final t in parseSeqFile(twin.readAsBytesSync()).types) t.name: t,
      };
      for (final record in binaryTypeRecords(bin.readAsBytesSync())) {
        final expected = twinByName[record.name];
        if (expected == null) continue;
        compared++;
        expect(record.className, expected.className,
            reason: '$name ${record.name}: classname');
        const saveDependent = {
          'timestamp', 'typeversion', 'typelastmodversion',
          'typeminprodversion',
        };
        record.toAttributes().forEach((key, value) {
          if (saveDependent.contains(key)) return;
          expect(value, expected.attributes[key],
              reason: '$name ${record.name}: attribute $key');
        });
      }
    }
    // ignore: avoid_print
    print('type-record heads: $compared typedefs matched across $pairs '
        'twin pairs');
    expect(pairs, greaterThanOrEqualTo(5));
    expect(compared, greaterThanOrEqualTo(100),
        reason: 'the rosetta twins carry hundreds of comparable typedefs');
  });

  test('whole-corpus sweep: no structural tokens, recovery floors hold', () {
    var binaries = 0, withNames = 0, totalNames = 0;
    final offenders = <String>[];
    final files = corpusSeqDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.seq'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binaries++;
      final names = binaryTypeNames(bytes);
      if (names.isNotEmpty) withNames++;
      totalNames += names.length;
      for (final name in names) {
        if (_structuralTokens.contains(name)) {
          offenders.add('${f.path}: $name');
        }
      }
    }
    // ignore: avoid_print
    print('binary type names: $withNames/$binaries files yield names · '
        '$totalNames names total');
    expect(offenders, isEmpty,
        reason: 'structural token recovered as a type name:\n'
            '${offenders.take(5).join('\n')}');
    expect(binaries, 294, reason: 'binary corpus count drifted');
    expect(withNames, greaterThanOrEqualTo(280),
        reason: 'type-name recovery regressed ($withNames files)');
    expect(totalNames, greaterThanOrEqualTo(7000),
        reason: 'type-name recovery regressed ($totalNames names)');
  });
}
