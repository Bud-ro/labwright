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

  // Compares a decoded binary field against its XML-twin subprop,
  // RECURSING into plain nested declarations (toolchain-stable across the
  // twin pairs). Instance/override and typed-reference subtrees carry a
  // subset (or nothing) and are validated at full depth by the
  // content-exact OutputVoltage parse test; here they are compared
  // shallowly (their own name/class), not descended.
  void compareField(String path, BinaryTypeField got, SeqProperty want) {
    expect(got.name, want.name, reason: '$path field name');
    // Intrinsically-typed arrays and inline custom instances carry no
    // recoverable typename (engine-intrinsic types are not serialized) —
    // the class still must match.
    final intrinsic = got.intrinsicTypeId != null ||
        (got.instanceOverrides && got.typeName == null);
    expect(
        intrinsic ? got.className : got.typeName ?? got.className,
        intrinsic ? want.className : want.typeName ?? want.className,
        reason: '$path.${got.name}: class/type');
    expect(got.value, want.scalar, reason: '$path.${got.name}: value');
    // Recurse only into plain declarations: children present, not an
    // override subset, not a typed reference. Then the twin's children
    // must match one-for-one — catches swapped/dropped/fabricated
    // grandchildren the old top-level-only check missed.
    final plainDeclaration = got.children.isNotEmpty &&
        !got.instanceOverrides &&
        got.typeName == null;
    if (plainDeclaration) {
      expect(got.children.length, want.subProps.length,
          reason: '$path.${got.name}: child count');
      for (var i = 0; i < got.children.length; i++) {
        compareField('$path.${got.name}', got.children[i], want.subProps[i]);
      }
    }
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
    var pairs = 0, compared = 0, decodedBodies = 0;
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
        // Decoded BODIES must equal the twin's subprops field-for-field
        // (bodies are toolchain-stable, unlike save timestamps — the
        // decode sweep held across every pair).
        final fields = record.fields;
        if (fields != null && fields.isNotEmpty) {
          decodedBodies++;
          expect(fields.length, expected.subProps.length,
              reason: '$name ${record.name}: field count');
          for (var i = 0; i < fields.length; i++) {
            compareField('$name ${record.name}', fields[i],
                expected.subProps[i]);
          }
        }
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
        'twin pairs · $decodedBodies bodies decoded field-for-field');
    expect(pairs, greaterThanOrEqualTo(5));
    expect(compared, greaterThanOrEqualTo(100),
        reason: 'the rosetta twins carry hundreds of comparable typedefs');
    expect(decodedBodies, greaterThanOrEqualTo(90),
        reason: 'the covered body grammar decodes a solid share '
            '($decodedBodies bodies; 93 at the extdata tier — every '
            'twinned typedef decodes)');
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

  test('whole-corpus sweep: sequence leading subprops never fabricate', () {
    // The leading-subprop decode (Parameters/Locals from the sequence
    // record) must never emit a structural token as a subprop name, and
    // must only ever emit the known pre-Main names — the honesty gate
    // over the whole corpus, not just the twinned pairs.
    var withLeading = 0, total = 0;
    final offenders = <String>[];
    for (final f in corpusSeqDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.seq'))) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      for (final outline in binarySequenceOutlines(bytes)) {
        if (outline.leadingSubProps.isNotEmpty) withLeading++;
        for (final sp in outline.leadingSubProps) {
          total++;
          if (sp.name != 'Parameters' && sp.name != 'Locals') {
            offenders.add('${f.uri.pathSegments.last}: ${sp.name}');
          }
        }
      }
    }
    // ignore: avoid_print
    print('sequence leading subprops: $total across $withLeading sequences');
    expect(offenders, isEmpty,
        reason: 'non-leading subprop name emitted:\n'
            '${offenders.take(5).join('\n')}');
    expect(withLeading, greaterThanOrEqualTo(80),
        reason: 'leading-subprop recovery regressed ($withLeading)');
  });

  test('whole-corpus sweep: step TS subprops never fabricate', () {
    // The per-step TS decode must never emit a structural token as a
    // subprop name — the honesty gate over the whole corpus.
    const structural = {
      'SequenceFileData', 'Data', 'Seq', 'Objs', 'Obj', 'Step',
      'Sequence', 'Setup', 'Main', 'Cleanup', 'TS',
    };
    var withTs = 0, total = 0;
    final offenders = <String>[];
    for (final f in corpusSeqDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.seq'))) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      for (final outline in binarySequenceOutlines(bytes)) {
        for (final step in [
          ...outline.setup,
          ...outline.main,
          ...outline.cleanup,
          ...outline.ungrouped,
        ]) {
          if (step.tsSubProps.isNotEmpty) withTs++;
          for (final sp in step.tsSubProps) {
            total++;
            if (structural.contains(sp.name)) {
              offenders.add('${f.uri.pathSegments.last}: ${sp.name}');
            }
          }
        }
      }
    }
    // ignore: avoid_print
    print('step TS subprops: $total across $withTs steps');
    expect(offenders, isEmpty,
        reason: 'structural token emitted as a TS subprop:\n'
            '${offenders.take(5).join('\n')}');
  });

  test('whole-corpus sweep: post-group scalar subprops never fabricate', () {
    // RecordResults must always decode as a Bool true/false, FailureAction
    // as an integer Num — the honesty gate over the whole corpus.
    var withRr = 0, withFa = 0;
    final offenders = <String>[];
    for (final f in corpusSeqDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.seq'))) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      for (final s in parseSeqFile(bytes).sequences) {
        final rr = s.raw.prop('RecordResults');
        final fa = s.raw.prop('FailureAction');
        if (rr != null) {
          withRr++;
          if (rr.className != 'Bool' ||
              (rr.scalar != 'true' && rr.scalar != 'false')) {
            offenders.add('${f.uri.pathSegments.last}: RecordResults='
                '${rr.className}/${rr.scalar}');
          }
        }
        if (fa != null) {
          withFa++;
          if (fa.className != 'Num' || int.tryParse(fa.scalar ?? '') == null) {
            offenders.add('${f.uri.pathSegments.last}: FailureAction='
                '${fa.className}/${fa.scalar}');
          }
        }
        // Requirements must hold a Links child; RTS children must never
        // be structural tokens (a coincidental Obj anchor).
        final req = s.raw.prop('Requirements');
        if (req != null &&
            !req.subProps.any((c) => c.name == 'Links')) {
          offenders.add('${f.uri.pathSegments.last}: Requirements w/o Links');
        }
        for (final c in s.raw.prop('RTS')?.subProps ?? const <SeqProperty>[]) {
          if (const {'Objs', 'Obj', 'Seq', 'Data', 'Step'}.contains(c.name)) {
            offenders.add('${f.uri.pathSegments.last}: RTS.${c.name}');
          }
        }
      }
    }
    // ignore: avoid_print
    print('post-group scalars: $withRr RecordResults · $withFa FailureAction');
    expect(offenders, isEmpty,
        reason: 'post-group scalar decoded wrong:\n'
            '${offenders.take(5).join('\n')}');
    expect(withRr, greaterThanOrEqualTo(80),
        reason: 'RecordResults recovery regressed ($withRr)');
  });

  test('rosetta-wide: sequence locals/parameters match every twin', () {
    // Every rosetta pair's sequences must decode the same locals and
    // parameters (name + type) as the XML twin — the leading-subprop
    // decode generalizes past the content-exact OutputVoltage pair.
    final rosetta = Directory('${corpusSeqDir.path}/rosetta');
    var pairs = 0, sequences = 0;
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
      final binFile = parseSeqFile(bin.readAsBytesSync());
      final xmlFile = parseSeqFile(twin.readAsBytesSync());
      final xmlByName = {for (final s in xmlFile.sequences) s.name: s};
      for (final bs in binFile.sequences) {
        final xs = xmlByName[bs.name];
        if (xs == null) continue;
        sequences++;
        expect(bs.locals.map((l) => '${l.name}:${l.type}').toList(),
            xs.locals.map((l) => '${l.name}:${l.type}').toList(),
            reason: '$name ${bs.name}: locals');
        expect(bs.parameters.map((p) => '${p.name}:${p.type}').toList(),
            xs.parameters.map((p) => '${p.name}:${p.type}').toList(),
            reason: '$name ${bs.name}: parameters');
        // Post-group scalars, where decoded, must match the twin (never
        // a wrong value; absent is honest when not decoded).
        if (bs.recordsResults != null) {
          expect(bs.recordsResults, xs.recordsResults,
              reason: '$name ${bs.name}: recordsResults');
        }
        if (bs.failureActionCode != null) {
          expect(bs.failureActionCode, xs.failureActionCode,
              reason: '$name ${bs.name}: failureActionCode');
        }
        // Requirement links and RTS presence, where decoded, match twin.
        if (bs.raw.prop('Requirements') != null) {
          expect(bs.requirementLinks, xs.requirementLinks,
              reason: '$name ${bs.name}: requirementLinks');
        }
        if (bs.runtimeSettings != null) {
          // Name, class AND value — the RTS Obj declaration stores every
          // field, so all must match the twin.
          expect(
              bs.raw
                  .prop('RTS')
                  ?.subProps
                  .map((p) => '${p.name}:${p.className}=${p.scalar}')
                  .toList(),
              xs.raw
                  .prop('RTS')
                  ?.subProps
                  .map((p) => '${p.name}:${p.className}=${p.scalar}')
                  .toList(),
              reason: '$name ${bs.name}: RTS children (name:class=value)');
        }
      }
    }
    expect(pairs, greaterThanOrEqualTo(5));
    expect(sequences, greaterThanOrEqualTo(5));
  });
}
