@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

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

const _elementTokens = {'Objs', 'Obj', 'Seq', 'Data', 'Step', 'Sequence', 'SequenceFileData', '[0]', '[]'};

BinaryTypeField? _child(BinaryTypeField f, String name) => f.children.where((c) => c.name == name).firstOrNull;

const _knownOffenders = {
  'MainCycle.seq: type name Obj',
  'MainTest.seq: type name Obj',
  'RemoveUnusedChannels.seq: type name Obj',
};

void main() {
  final files =
      corpusSeqDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.seq'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  File? pin(String suffix) => files.where((f) => f.path.replaceAll(r'\', '/').endsWith(suffix)).firstOrNull;

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

  test('whole corpus: nothing fabricates, all invariants hold', () {
    final tally = Tally();
    final offenders = <String>[];

    for (final f in files) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      tally.bump('binaries');
      final base = f.uri.pathSegments.last;

      final cov = binaryByteCoverage(bytes);
      if (cov != null) {
        expect(cov.recordUndecodedBytes, greaterThanOrEqualTo(0), reason: f.path);
        expect(cov.recordRegionBytes, greaterThan(0), reason: f.path);
        tally.bump('covFiles');
      }

      final names = binaryTypeNames(bytes);
      if (names.isNotEmpty) tally.bump('withNames');
      tally.bump('totalNames', names.length);
      for (final name in names) {
        if (_typeNameTokens.contains(name)) offenders.add('$base: type name $name');
      }
      final tableNames = names.toSet();

      if (binaryTypeIndexBase(bytes) != 0) tally.bump('nonzeroBaseFiles');
      void anchorWalk(List<BinaryTypeField> fs) {
        for (final field in fs) {
          if ((field.name == 'DescriptionFormat' || field.name == 'DefaultNameFormat') && field.typeName != null) {
            tally.bump('anchors');
            if (field.typeName != 'Expression') offenders.add('$base: ${field.name} -> ${field.typeName}');
          }
          anchorWalk(field.children);
        }
      }

      void elementWalk(BinaryTypeField field, bool isElement) {
        if (isElement) {
          tally.bump('elements');
          for (final child in field.children) {
            if (_elementTokens.contains(child.name)) {
              offenders.add('$base: element child "${child.name}" is a structural token');
            }
          }
        }
        final elementContext = field.isArray && field.children.isNotEmpty;
        if (elementContext) tally.bump('elementArrays');
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

      for (final outline in binarySequenceOutlines(bytes)) {
        if (outline.comment != null) tally.bump('comments');
        if (outline.leadingSubProps.isNotEmpty) tally.bump('withLeading');
        for (final sp in outline.leadingSubProps) {
          tally.bump('leadingTotal');
          if (sp.name != 'Parameters' && sp.name != 'Locals') offenders.add('$base: leading subprop ${sp.name}');
        }
        for (final g in outline.groupArrays) {
          tally.bump('groupArrays');
          if (!const {'Main', 'Setup', 'Cleanup'}.contains(g.name)) offenders.add('$base: group ${g.name}');
          if (g.className != 'Objs') offenders.add('$base: group class ${g.className}');
          final count = boundCount(g.arrayLBound, g.arrayUBound);
          if (g.children.isNotEmpty) {
            if (g.partialArray) {
              tally.bump('partialGroups');
              expect(
                g.children,
                isNotEmpty,
                reason: '$base ${outline.name}.${g.name}: partial prefix must be nonempty',
              );
              expect(
                count != null && g.children.length < count,
                isTrue,
                reason: '$base ${outline.name}.${g.name}: partial prefix must be shorter than bounds',
              );
            } else {
              expect(g.children, hasLength(count), reason: '$base ${outline.name}.${g.name}: bounds vs elements');
            }
          }
          for (final s in g.children) {
            tally.bump('steps');
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
              tally.bump('ids');
              expect(id.value, startsWith('ID#:'), reason: '$base step ${s.name}');
            }
          }
        }
        for (final step in [...outline.setup, ...outline.main, ...outline.cleanup, ...outline.ungrouped]) {
          if (step.tsSubProps.isNotEmpty) tally.bump('withTs');
          for (final sp in step.tsSubProps) {
            tally.bump('tsTotal');
            if (_tsTokens.contains(sp.name)) offenders.add('$base: TS subprop ${sp.name}');
          }
          tally.bump('dataSubProps', step.dataSubProps.length);
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

      for (final s in parseSeqFile(bytes).sequences) {
        final rr = s.raw.prop('RecordResults');
        if (rr != null) {
          tally.bump('withRr');
          if (rr.className != 'Bool' || (rr.scalar != 'true' && rr.scalar != 'false')) {
            offenders.add('$base: RecordResults=${rr.className}/${rr.scalar}');
          }
        }
        final fa = s.raw.prop('FailureAction');
        if (fa != null) {
          tally.bump('withFa');
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
      'binary sweep: ${tally['binaries']} binaries · ${tally['withNames']} with type names (${tally['totalNames']}) · '
      '${tally['nonzeroBaseFiles']} misaligned · ${tally['anchors']} anchors · ${tally['leadingTotal']} leading subprops in ${tally['withLeading']} sequences · '
      '${tally['tsTotal']} TS subprops in ${tally['withTs']} steps · ${tally['withRr']} RecordResults · ${tally['withFa']} FailureAction · '
      '${tally['groupArrays']} group arrays (${tally['partialGroups']} partial) · ${tally['steps']} step elements · ${tally['ids']} Id anchors · '
      '${tally['comments']} comments · ${tally['elementArrays']} element arrays · ${tally['elements']} elements · ${tally['dataSubProps']} data subprops',
    );
    expect(
      offenders.toSet(),
      _knownOffenders,
      reason:
          'fabrication/honesty offenders beyond (or missing from) the pinned '
          'known counterexamples:\n${offenders.take(10).join('\n')}',
    );
  });

  test('misaligned cohort recovers its exact per-file base, and the rebase is semantic', () {
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
      if (f == null) return;
      checked++;
      expect(binaryTypeIndexBase(f.readAsBytesSync()), base, reason: '$suffix type-index base');
    });
    expect(checked, greaterThanOrEqualTo(4), reason: 'too few cohort files present to guard the recovery');

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
      'DHA_TestStand_Seq-39449e1/DHA5x5_STTE_CalibrationSequence.seq',
      'sandbox/Test Sequence.seq',
      'Bed of Nails Test Stand/BenchmarkTest.seq',
      'Very Old/Elatch-bench Backup.seq',
      'Sequence/iTAC.seq',
      'Solar_Panel Controller/Solar_panel_main.seq',
    ];

    List<BinarySequenceOutline> outlinesOf(String suffix) => binarySequenceOutlines(pin(suffix)!.readAsBytesSync());

    test('pinned files are present (guards silent skips after a corpus rename)', () {
      expect(pinnedSuffixes.where((s) => pin(s) != null).length, pinnedSuffixes.length);
    });

    test('DHA5x5_STTE_CalibrationSequence.seq: record-walk-only discovery (no declaration paths)', () {
      if (pin(pinnedSuffixes[0]) == null) return;
      final outlines = outlinesOf(pinnedSuffixes[0]);
      final verify = outlines.firstWhere((o) => o.name == 'VerifyCalibration');
      final main = verify.groupArrays.firstWhere((g) => g.name == 'Main');
      expect(main.children, hasLength(72));
      expect(main.children.every((s) => s.typeName != null), isTrue);
      final locals = verify.leadingSubProps.firstWhere((p) => p.name == 'Locals');
      final crosshair = locals.children.firstWhere((c) => c.name == 'CrosshairX');
      expect(crosshair.className, 'Nums');
      expect(crosshair.arrayUBound, '[8]');
      expect(crosshair.children, hasLength(9));
      expect(crosshair.children.first.value, '150');
    });

    test('Test Sequence.seq: a genuine sequence NAMED `Sequence` (walk-corroborated)', () {
      if (pin(pinnedSuffixes[1]) == null) return;
      final seq = outlinesOf(pinnedSuffixes[1]).where((o) => o.name == 'Sequence').single;
      final step = seq.groupArrays.firstWhere((g) => g.name == 'Main').children.single;
      expect((step.name, step.typeName), ('Subseq', 'DanfossStringValueTest'));
      expect(step.children.where((c) => c.name == 'Limits').single.children.single.value, 'String Limit');
    });

    test('BenchmarkTest.seq: expression-array elements (DataSourceArray) decode', () {
      if (pin(pinnedSuffixes[2]) == null) return;
      final main = outlinesOf(
        pinnedSuffixes[2],
      ).firstWhere((o) => o.name == 'MainSequence').groupArrays.firstWhere((g) => g.name == 'Main');
      expect(main.children, hasLength(9));
      BinaryTypeField? findDataSources(BinaryTypeField f) {
        if (f.name == 'DataSourceArray' && f.children.isNotEmpty) return f;
        for (final c in f.children) {
          final hit = findDataSources(c);
          if (hit != null) return hit;
        }
        return null;
      }

      final dataSources = main.children.map(findDataSources).whereType<BinaryTypeField>().first;
      expect(dataSources.children, hasLength(8));
      expect(dataSources.children.every((e) => e.className == 'ExprValue' && e.name.isEmpty), isTrue);
      expect(dataSources.children.first.value, 'Step.NumericArray[0]');
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

    test('iTAC.seq: pool[0]-`Obj` generation — class-slot-0 subprops and scalar `Ref` parameters decode', () {
      if (pin(pinnedSuffixes[4]) == null) return;
      final outlines = outlinesOf(pinnedSuffixes[4]);
      expect(outlines.map((o) => o.name), contains('Connect'));
      final connect = outlines.firstWhere((o) => o.name == 'Connect');
      final params = connect.leadingSubProps.firstWhere((p) => p.name == 'Parameters');
      expect(params.className, 'Obj', reason: 'class slot 0 resolves to pool[0]');
      expect(params.attrWords, [0x440000], reason: 'the twin-known Parameters valueflags word');
      expect(
        [for (final c in params.children) c.name],
        ['Error', 'iTACRef', 'iTACStationID', 'iTACSessionID', 'Errmsg'],
        reason: 'the true 5-parameter list — nothing swallowed by the Ref',
      );
      final ref = params.children[1];
      expect(ref.className, 'Ref');
      expect(ref.value, isNull, reason: 'a Ref never persists a value');
      expect(ref.children, isEmpty);
      final locals = connect.leadingSubProps.firstWhere((p) => p.name == 'Locals');
      expect(locals.attrWords, [0x400000], reason: 'the twin-known Locals valueflags word');
      expect(locals.children.single.name, 'ResultList');
    });

    test('Solar_panel_main.seq: pool[0]-`Obj` generation — NI_Wait typedef body decodes through its substeps', () {
      if (pin(pinnedSuffixes[5]) == null) return;
      final records = binaryTypeRecords(pin(pinnedSuffixes[5])!.readAsBytesSync());
      final wait = records.firstWhere((r) => r.name == 'NI_Wait');
      expect(wait.undecodedBody, isFalse);
      final substeps = wait.fields!.firstWhere((f) => f.name == 'Substeps');
      expect([for (final s in substeps.children) s.name], ['OnNewStep', 'Post', 'Edit']);
      final edit = substeps.children[2];
      final result = edit.children.firstWhere((f) => f.name == 'Result');
      expect(result.className, 'Obj', reason: 'class slot 0 resolves to pool[0]');
      expect([for (final c in result.children) c.name], ['Error', 'ReportText', 'Common']);
      expect(result.children[0].className, isNull);
      expect(
        edit.children.firstWhere((f) => f.name == 'MenuName').value,
        'ResStr("NI_WAIT_STEP_TYPE", "EDIT_STEP_MENU_NAME")',
      );
      expect(edit.children.firstWhere((f) => f.name == 'HasEditPanel').value, 'true');
      expect(records.where((r) => r.undecodedBody).length, 4);
    });
  });
}
