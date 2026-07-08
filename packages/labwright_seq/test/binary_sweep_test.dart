@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Structural scaffold/model tokens that must never be recovered as TYPE names.
const _typeNameTokens = {
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

/// Tokens that must never surface as a step TS subprop name.
const _tsTokens = {
  'SequenceFileData',
  'Data',
  'Seq',
  'Objs',
  'Obj',
  'Step',
  'Sequence',
  'Setup',
  'Main',
  'Cleanup',
  'TS',
};

/// Tokens that must never surface as a populated-array element child name.
const _elementTokens = {'Objs', 'Obj', 'Seq', 'Data', 'Step', 'Sequence', 'SequenceFileData', '[0]', '[]'};

BinaryTypeField? _child(BinaryTypeField f, String name) => f.children.where((c) => c.name == name).firstOrNull;

/// Whole-corpus honesty sweep over every binary (one streaming pass): the
/// decoders must never fabricate (no structural tokens, types from the file's
/// own table, `ID#:` anchors, bounds == element counts, byte-coverage
/// invariants) and the recovery floors must not silently regress. The
/// per-value twin validation lives in `binary_oracle_test.dart`.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test(
      'binary corpus sweep (skipped: corpus not fetched)',
      () {},
      skip: 'corpus absent — run tool/fetch_seq_corpus.dart',
    );
    return;
  }

  final files =
      corpusSeqDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.seq'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  File? pin(String suffix) => files.where((f) => f.path.replaceAll(r'\', '/').endsWith(suffix)).firstOrNull;

  /// The element count a populated bound-token pair declares, or null.
  int? boundCount(String? lb, String? ub) {
    if (lb == null || ub == null || ub == '[]') return null;
    List<int>? dims(String t) {
      final out = <int>[];
      for (final m in RegExp(r'\[(\d*)\]').allMatches(t)) {
        final v = int.tryParse(m.group(1)!);
        if (v == null) return null;
        out.add(v);
      }
      return out.isEmpty ? null : out;
    }

    final l = dims(lb), u = dims(ub);
    if (l == null || u == null || l.length != u.length) return null;
    var count = 1;
    for (var i = 0; i < l.length; i++) {
      count *= u[i] - l[i] + 1;
    }
    return count;
  }

  test('whole corpus: nothing fabricates, all invariants hold, floors ratchet', () {
    var binaries = 0, covFiles = 0, withNames = 0, totalNames = 0, nonzeroBaseFiles = 0, anchors = 0;
    var withLeading = 0, leadingTotal = 0, withTs = 0, tsTotal = 0, withRr = 0, withFa = 0;
    var groupArrays = 0, steps = 0, ids = 0, comments = 0;
    var elementArrays = 0, elements = 0, dataSubProps = 0;
    var totalCov = const BinaryByteCoverage(
      bodyBytes: 0,
      poolBytes: 0,
      recordSemanticBytes: 0,
      recordStructuralBytes: 0,
    );
    final offenders = <String>[];

    for (final f in files) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binaries++;
      final base = f.uri.pathSegments.last;

      // Byte-coverage scoreboard invariants + aggregate.
      final cov = binaryByteCoverage(bytes);
      if (cov != null) {
        expect(cov.recordUndecodedBytes, greaterThanOrEqualTo(0), reason: f.path);
        expect(cov.recordRegionBytes, greaterThan(0), reason: f.path);
        covFiles++;
        totalCov = totalCov + cov;
      }

      // Type-name recovery: never a structural token.
      final names = binaryTypeNames(bytes);
      if (names.isNotEmpty) withNames++;
      totalNames += names.length;
      for (final name in names) {
        if (_typeNameTokens.contains(name)) offenders.add('$base: type name $name');
      }
      final tableNames = names.toSet();

      // Type-index base recovery + the 0-fabrication anchor guard: every
      // decoded DescriptionFormat/DefaultNameFormat must be Expression-typed.
      if (binaryTypeIndexBase(bytes) != 0) nonzeroBaseFiles++;
      void anchorWalk(List<BinaryTypeField> fs) {
        for (final field in fs) {
          if ((field.name == 'DescriptionFormat' || field.name == 'DefaultNameFormat') && field.typeName != null) {
            anchors++;
            if (field.typeName != 'Expression') offenders.add('$base: ${field.name} -> ${field.typeName}');
          }
          anchorWalk(field.children);
        }
      }

      // Populated-array ELEMENT decode: element children are real fields,
      // never structural tokens.
      void elementWalk(BinaryTypeField field, bool isElement) {
        if (isElement) {
          elements++;
          for (final child in field.children) {
            if (_elementTokens.contains(child.name)) {
              offenders.add('$base: element child "${child.name}" is a structural token');
            }
          }
        }
        final elementContext = field.isArray && field.children.isNotEmpty;
        if (elementContext) elementArrays++;
        for (final child in field.children) {
          elementWalk(child, elementContext);
        }
      }

      for (final r in binaryTypeRecords(bytes)) {
        anchorWalk(r.fields ?? const []);
        for (final field in r.fields ?? const <BinaryTypeField>[]) {
          elementWalk(field, false);
        }
      }

      // Sequence outlines: leading subprops, TS subprops, group arrays.
      for (final outline in binarySequenceOutlines(bytes)) {
        if (outline.comment != null) comments++;
        if (outline.leadingSubProps.isNotEmpty) withLeading++;
        for (final sp in outline.leadingSubProps) {
          leadingTotal++;
          if (sp.name != 'Parameters' && sp.name != 'Locals') offenders.add('$base: leading subprop ${sp.name}');
        }
        for (final g in outline.groupArrays) {
          groupArrays++;
          if (!const {'Main', 'Setup', 'Cleanup'}.contains(g.name)) offenders.add('$base: group ${g.name}');
          if (g.className != 'Objs') offenders.add('$base: group class ${g.className}');
          final count = boundCount(g.arrayLBound, g.arrayUBound);
          if (g.children.isNotEmpty) {
            expect(g.children, hasLength(count), reason: '$base ${outline.name}.${g.name}: bounds vs elements');
          }
          for (final s in g.children) {
            steps++;
            expect(s.className, 'Step', reason: '$base ${outline.name}.${g.name}');
            expect(s.name, isNotEmpty, reason: '$base ${outline.name}.${g.name}');
            if (s.typeName != null) {
              expect(
                tableNames,
                contains(s.typeName),
                reason: '$base step ${s.name}: type outside the recovered table',
              );
            }
            final id = _child(_child(s, 'TS') ?? s, 'Id');
            if (id != null && id.value != null) {
              ids++;
              expect(id.value, startsWith('ID#:'), reason: '$base step ${s.name}');
            }
          }
        }
        for (final step in [...outline.setup, ...outline.main, ...outline.cleanup, ...outline.ungrouped]) {
          if (step.tsSubProps.isNotEmpty) withTs++;
          for (final sp in step.tsSubProps) {
            tsTotal++;
            if (_tsTokens.contains(sp.name)) offenders.add('$base: TS subprop ${sp.name}');
          }
          dataSubProps += step.dataSubProps.length;
          for (final field in step.dataSubProps) {
            if (!const {'Measurement', 'PinMapPath'}.contains(field.name)) {
              offenders.add('$base: data subprop ${field.name}');
            }
          }
          for (final field in [...step.tsSubProps, ...step.dataSubProps]) {
            elementWalk(field, false);
          }
        }
      }

      // Post-group scalar subprops via the typed model.
      for (final s in parseSeqFile(bytes).sequences) {
        final rr = s.raw.prop('RecordResults');
        if (rr != null) {
          withRr++;
          if (rr.className != 'Bool' || (rr.scalar != 'true' && rr.scalar != 'false')) {
            offenders.add('$base: RecordResults=${rr.className}/${rr.scalar}');
          }
        }
        final fa = s.raw.prop('FailureAction');
        if (fa != null) {
          withFa++;
          if (fa.className != 'Num' || int.tryParse(fa.scalar ?? '') == null) {
            offenders.add('$base: FailureAction=${fa.className}/${fa.scalar}');
          }
        }
        final req = s.raw.prop('Requirements');
        if (req != null && !req.subProps.any((c) => c.name == 'Links')) {
          offenders.add('$base: Requirements w/o Links');
        }
        for (final c in s.raw.prop('RTS')?.subProps ?? const <SeqProperty>[]) {
          if (const {'Objs', 'Obj', 'Seq', 'Data', 'Step'}.contains(c.name)) {
            offenders.add('$base: RTS.${c.name}');
          }
        }
      }
    }

    print(
      'binary sweep: $binaries binaries · $withNames with type names ($totalNames) · '
      '$nonzeroBaseFiles misaligned · $anchors anchors · $leadingTotal leading subprops in $withLeading sequences · '
      '$tsTotal TS subprops in $withTs steps · $withRr RecordResults · $withFa FailureAction · '
      '$groupArrays group arrays · $steps step elements · $ids Id anchors · $comments comments · '
      '$elementArrays element arrays · $elements elements · $dataSubProps data subprops',
    );
    expect(offenders, isEmpty, reason: 'fabrication/honesty offenders:\n${offenders.take(10).join('\n')}');
    expect(binaries, 169, reason: 'binary corpus count drifted');
    expect(covFiles, greaterThanOrEqualTo(165));
    expect(totalCov.recordSemanticRatio, greaterThanOrEqualTo(0.32));
    expect(totalCov.recordAccountedRatio, greaterThanOrEqualTo(0.40));
    expect(withNames, greaterThanOrEqualTo(155), reason: 'type-name recovery regressed ($withNames files)');
    expect(totalNames, greaterThanOrEqualTo(4900), reason: 'type-name recovery regressed ($totalNames names)');
    expect(anchors, greaterThanOrEqualTo(2000), reason: 'anchor-field decode regressed ($anchors)');
    expect(
      nonzeroBaseFiles,
      greaterThanOrEqualTo(10),
      reason: 'misaligned-cohort recovery regressed ($nonzeroBaseFiles)',
    );
    expect(withLeading, greaterThanOrEqualTo(80), reason: 'leading-subprop recovery regressed ($withLeading)');
    expect(withRr, greaterThanOrEqualTo(80), reason: 'RecordResults recovery regressed ($withRr)');
    expect(groupArrays, greaterThanOrEqualTo(600));
    expect(steps, greaterThanOrEqualTo(1650));
    expect(elementArrays, greaterThanOrEqualTo(22));
    expect(elements, greaterThanOrEqualTo(200));
    expect(dataSubProps, greaterThanOrEqualTo(28));
  });

  test('misaligned cohort recovers its exact per-file base, and the rebase is semantic', () {
    // A framed 1-based type reference X names table[X - 1 - base]; base is
    // recovered from the invariant that DescriptionFormat/DefaultNameFormat
    // are always Expression-typed. Positive = intrinsic types reserved before
    // the first serialized record; negative = a head over-detected.
    const expected = {
      'teststand/Sequence File 1.seq': 1,
      'EnumControls/EnumControls.seq': 4,
      'DotNetEnums/DotNetEnums.seq': 9,
      'Example Sequences/Sample Project.seq': 23,
      'TestProgram/AppNoteMEMS_TestProgram_Example.seq': 5,
      'src/docgen_csv.seq': -1,
    };
    var checked = 0;
    expected.forEach((suffix, base) {
      final f = pin(suffix);
      if (f == null) return; // pinned file absent — do not fail the sweep
      checked++;
      expect(binaryTypeIndexBase(f.readAsBytesSync()), base, reason: '$suffix type-index base');
    });
    expect(checked, greaterThanOrEqualTo(4), reason: 'too few cohort files present to guard the recovery');

    // With the base applied, a cohort file's anchor fields must decode with
    // typeName 'Expression' — direct evidence the rebase lands right.
    final f = pin('teststand/Sequence File 1.seq');
    if (f == null) return;
    final bytes = f.readAsBytesSync();
    var anchors = 0;
    void walk(List<BinaryTypeField> fs) {
      for (final field in fs) {
        if (field.name == 'DescriptionFormat' || field.name == 'DefaultNameFormat') {
          anchors++;
          expect(field.typeName, 'Expression', reason: '${field.name} must be Expression-typed');
        }
        walk(field.children);
      }
    }

    for (final r in binaryTypeRecords(bytes)) {
      walk(r.fields ?? const []);
    }
    expect(anchors, greaterThanOrEqualTo(2), reason: 'the cohort file must decode its anchor fields');
  });

  group('pinned corpus files (record-walk correctness)', () {
    const pinnedSuffixes = [
      'SubSequences/6-H_Akım/Harmonik_Akım.seq',
      'sandbox/Test Sequence.seq',
      'SubSequences/5-Reaktif/Reaktif_Güç_1A_PF1.seq',
      'Very Old/Elatch-bench Backup.seq',
    ];

    List<BinarySequenceOutline> outlinesOf(String suffix) => binarySequenceOutlines(pin(suffix)!.readAsBytesSync());

    test('pinned files are present (guards silent skips after a corpus rename)', () {
      expect(pinnedSuffixes.where((s) => pin(s) != null).length, pinnedSuffixes.length);
    });

    test('Harmonik_Akım.seq: record-walk-only discovery (no declaration paths)', () {
      if (pin(pinnedSuffixes[0]) == null) return;
      final outlines = outlinesOf(pinnedSuffixes[0]);
      final main = outlines.single.groupArrays.firstWhere((g) => g.name == 'Main');
      expect(main.children, hasLength(25));
      expect(main.children.every((s) => s.typeName != null), isTrue);
      // The populated scalar-array locals: a 51-element Nums local.
      final locals = outlines.single.leadingSubProps.firstWhere((p) => p.name == 'Locals');
      final limit = locals.children.firstWhere((c) => c.className == 'Nums');
      expect(limit.arrayUBound, '[50]');
      expect(limit.children, hasLength(51));
      expect(limit.children.first.value, '0');
    });

    test('Test Sequence.seq: a genuine sequence NAMED `Sequence` (walk-corroborated)', () {
      if (pin(pinnedSuffixes[1]) == null) return;
      final seq = outlinesOf(pinnedSuffixes[1]).where((o) => o.name == 'Sequence').single;
      final step = seq.groupArrays.firstWhere((g) => g.name == 'Main').children.single;
      expect((step.name, step.typeName), ('Subseq', 'DanfossStringValueTest'));
      expect(step.children.where((c) => c.name == 'Limits').single.children.single.value, 'String Limit');
    });

    test('Reaktif_Güç_1A_PF1.seq: expression-array elements (DataSourceArray) decode', () {
      if (pin(pinnedSuffixes[2]) == null) return;
      final main = outlinesOf(pinnedSuffixes[2]).single.groupArrays.firstWhere((g) => g.name == 'Main');
      expect(main.children, hasLength(18));
      BinaryTypeField? findDataSources(BinaryTypeField f) {
        if (f.name == 'DataSourceArray' && f.children.isNotEmpty) return f;
        for (final c in f.children) {
          final hit = findDataSources(c);
          if (hit != null) return hit;
        }
        return null;
      }

      final dataSources = main.children.map(findDataSources).whereType<BinaryTypeField>().first;
      expect(dataSources.children.every((e) => e.className == 'ExprValue' && e.name.isEmpty), isTrue);
      expect(dataSources.children.first.value, startsWith('Abs('));
    });

    test('Elatch-bench Backup.seq: comment-slot record head decodes', () {
      if (pin(pinnedSuffixes[3]) == null) return;
      final outlines = outlinesOf(pinnedSuffixes[3]);
      expect(
        outlines.firstWhere((o) => o.name == 'MainSequence').comment,
        'Override this in the client file with a sequence that performs tests on the UUT.',
      );
      final load = outlines.firstWhere((o) => o.name == 'Load_Variables');
      expect(load.groupArrays.firstWhere((g) => g.name == 'Main').children, hasLength(6));
    });
  });
}
