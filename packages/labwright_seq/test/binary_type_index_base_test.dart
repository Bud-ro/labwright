@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Guards the per-file TYPE-INDEX BASE recovery ([binaryTypeIndexBase] /
/// deriveTypeIndexBase). A framed 1-based type reference `X` names
/// `table[X - 1 - base]`; `base` is 0 for the aligned majority and a
/// constant (either sign) for the misaligned cohort, recovered from the
/// cross-format invariant that `DescriptionFormat` / `DefaultNameFormat` are
/// always `Expression`-typed. These tests pin: aligned files stay base 0
/// (no regression), the cohort recovers its exact base, and NO decoded
/// anchor field is ever typed anything but `Expression` (0 fabrication).
void main() {
  if (!corpusSeqDir.existsSync()) {
    test(
      'type-index base (skipped: corpus not fetched)',
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

  test('aligned files (rosetta oracle + twins) derive base 0 AND resolve their anchors', () {
    // The content-exact oracle and every rosetta binary are aligned: their
    // anchor refs resolve to Expression under base 0, so the base machinery
    // must not perturb them.
    var binaries = 0, anchors = 0;
    for (final f in Directory('${corpusSeqDir.path}/rosetta').listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binaries++;
      expect(binaryTypeIndexBase(bytes), 0, reason: 'rosetta binary ${f.path.split('/').last} must be aligned');
      // Base 0 must be a CORRECT alignment, not deriveTypeIndexBase giving
      // up to 0: every decoded anchor field must still resolve to the
      // Expression type under it. (A give-up 0 would mis-resolve these to a
      // wrong record and surface a non-Expression typeName here.)
      void walk(List<BinaryTypeField> fs) {
        for (final field in fs) {
          if ((field.name == 'DescriptionFormat' || field.name == 'DefaultNameFormat') && field.typeName != null) {
            anchors++;
            expect(field.typeName, 'Expression', reason: '${f.path.split('/').last} ${field.name}');
          }
          walk(field.children);
        }
      }

      for (final r in binaryTypeRecords(bytes)) {
        walk(r.fields ?? const []);
      }
    }
    // Aggregate presence guard: the rosetta oracle set must be present, else
    // a corpus rename/partial checkout has silently disabled the assertion.
    expect(binaries, greaterThanOrEqualTo(6), reason: 'rosetta binaries missing — partial checkout?');
    expect(
      anchors,
      greaterThanOrEqualTo(6),
      reason: 'aligned anchor fields did not decode — base-0 resolution regressed',
    );
  });

  test('misaligned cohort recovers its exact per-file base', () {
    // Representative cohort files, each with the base measured from its
    // anchor refs (positive = intrinsic types reserved before the first
    // serialized record; negative = a head over-detected before Expression).
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
      expect(
        binaryTypeIndexBase(Uint8List.fromList(f.readAsBytesSync())),
        base,
        reason: '$suffix type-index base',
      );
    });
    expect(checked, greaterThanOrEqualTo(4), reason: 'too few cohort files present to guard the recovery');
  });

  test('cohort anchor refs resolve to the Expression type (semantic check)', () {
    // With the base applied, the always-Expression fields of a cohort file
    // must decode with typeName 'Expression' — the direct evidence the
    // rebase lands on the right record (they resolved to a WRONG type name
    // before the base was recovered).
    final f = pin('teststand/Sequence File 1.seq');
    if (f == null) return;
    final bytes = Uint8List.fromList(f.readAsBytesSync());
    expect(binaryTypeIndexBase(bytes), 1);
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

  test('whole-corpus sweep: no anchor field is ever typed non-Expression', () {
    // The 0-fabrication guard: across every binary, every decoded
    // DescriptionFormat / DefaultNameFormat field that carries a typeName
    // must be typed 'Expression'. A wrong base (or an ungated rebase) would
    // surface a bogus type name here.
    var anchors = 0, nonzeroBaseFiles = 0;
    final offenders = <String>[];
    void walk(String file, List<BinaryTypeField> fs) {
      for (final field in fs) {
        if ((field.name == 'DescriptionFormat' || field.name == 'DefaultNameFormat') && field.typeName != null) {
          anchors++;
          if (field.typeName != 'Expression') {
            offenders.add('$file: ${field.name} -> ${field.typeName}');
          }
        }
        walk(file, field.children);
      }
    }

    for (final f in files) {
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      if (binaryTypeIndexBase(bytes) != 0) nonzeroBaseFiles++;
      final base = f.path.split('/').last;
      for (final r in binaryTypeRecords(bytes)) {
        walk(base, r.fields ?? const []);
      }
    }
    // ignore: avoid_print
    print('type-index base: $nonzeroBaseFiles/169 misaligned · $anchors anchor fields decoded, all Expression');
    expect(offenders, isEmpty, reason: 'anchor field typed non-Expression:\n${offenders.take(5).join('\n')}');
    expect(anchors, greaterThanOrEqualTo(2000), reason: 'anchor-field decode regressed ($anchors)');
    expect(
      nonzeroBaseFiles,
      greaterThanOrEqualTo(10),
      reason: 'misaligned-cohort recovery regressed ($nonzeroBaseFiles)',
    );
  });
}
