@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Round-3 sequence-record walk validation: the `[Sequence][name][count]`
/// records decode END-TO-END (Parameters/Locals, the populated
/// Main/Setup/Cleanup group arrays with their step elements, and the tail
/// subprops), surfaced via [BinarySequenceOutline.groupArrays].
///
/// Three validation layers, per the campaign's wrong=0 rule:
///  * rosetta CROSS-PATH agreement — the walk's group elements must match
///    the independently-assembled step lists (marker/scan path), and the
///    content-exact OutputVoltage pair must match its XML twin
///    value-for-value;
///  * whole-corpus honesty sweep — element counts equal the declared
///    bounds, step types resolve in the file's own recovered table, `Id`
///    anchors keep their `ID#:` prefix, floors ratchet the recovery;
///  * pinned corpus files — the record-walk-only discoveries (files with
///    no declaration paths, the comment-slot head, populated scalar and
///    expression arrays) stay decoded.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('binary sequence records (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  BinaryTypeField? child(BinaryTypeField f, String name) => f.children.where((c) => c.name == name).firstOrNull;

  /// The element count a populated bound-token pair declares (product
  /// over dimensions), or null for an empty/malformed pair — the test's
  /// own reading of the tokens, independent of the parser's.
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

    final l = dims(lb);
    final u = dims(ub);
    if (l == null || u == null || l.length != u.length) return null;
    var count = 1;
    for (var i = 0; i < l.length; i++) {
      count *= u[i] - l[i] + 1;
    }
    return count;
  }

  test('rosetta-wide: every group array decodes and agrees with the scan-assembled outline', () {
    final rosetta = Directory('${corpusSeqDir.path}/rosetta');
    var binaries = 0;
    for (final bin in rosetta.listSync().whereType<File>().where((f) => f.path.endsWith('_BIN.seq'))) {
      final bytes = Uint8List.fromList(bin.readAsBytesSync());
      final outlines = binarySequenceOutlines(bytes);
      expect(outlines, hasLength(1), reason: bin.path);
      final o = outlines.single;
      binaries++;
      // All three group arrays decoded, in record order.
      expect(o.groupArrays.map((g) => g.name).toList(), ['Main', 'Setup', 'Cleanup'], reason: bin.path);
      for (final g in o.groupArrays) {
        expect(g.className, 'Objs', reason: '${bin.path} ${g.name}');
        // CROSS-PATH: the walk's step elements must equal the step list
        // the independent marker/scan assembly produced — name for name,
        // type for type.
        final scanSteps = switch (g.name) {
          'Setup' => o.setup,
          'Main' => o.main,
          _ => o.cleanup,
        };
        expect(
          g.children.map((s) => '${s.name}:${s.typeName}').toList(),
          scanSteps.map((s) => '${s.name}:${s.typeName}').toList(),
          reason: '${bin.path} ${g.name}: walk elements vs scan steps',
        );
        // Declared bounds equal the decoded element count.
        final count = boundCount(g.arrayLBound, g.arrayUBound);
        if (count != null) {
          expect(g.children, hasLength(count), reason: '${bin.path} ${g.name}: bounds vs elements');
        }
      }
    }
    expect(binaries, greaterThanOrEqualTo(6));
  });

  test('oracle: Main step element content matches the content-exact XML twin', () {
    final bin = Uint8List.fromList(File('${corpusSeqDir.path}/rosetta/OutputVoltage_BIN.seq').readAsBytesSync());
    final xml = parseSeqFile(File('${corpusSeqDir.path}/rosetta/OutputVoltage_XML.seq').readAsBytesSync());
    final main = binarySequenceOutlines(bin).single.groupArrays.firstWhere((g) => g.name == 'Main');
    final twinMain = xml.sequences.firstWhere((s) => s.name == 'MainSequence').main;
    expect(main.children, hasLength(twinMain.length));
    final step = main.children.single;
    final twinStep = twinMain.single;
    expect(step.name, twinStep.name);
    expect(step.typeName, 'NI_Measurement');
    // TS subprops: the serialized override subset — Id exact.
    final ts = child(step, 'TS')!;
    expect(child(ts, 'Id')!.value, twinStep.raw.prop('TS')?.prop('Id')?.scalar);
    // The Measurement data subprop: plug-in name + all 11 parameters,
    // name/value exact against the twin.
    final measurement = child(step, 'Measurement')!;
    final twinMeasurement = twinStep.raw.prop('Measurement')!;
    expect(child(measurement, 'Name')!.value, twinMeasurement.prop('Name')?.scalar);
    final parameters = child(measurement, 'Parameters')!;
    final twinParameters = twinMeasurement.prop('Parameters')!.array!;
    expect(parameters.children, hasLength(twinParameters.length));
    for (var i = 0; i < twinParameters.length; i++) {
      final p = parameters.children[i];
      final tp = twinParameters[i];
      for (final field in ['Name', 'Direction', 'Type', 'ID', 'TypeSpecialization']) {
        // Assert the binary decoded the field before comparing: a null-safe
        // compare of two absent values would pass vacuously and silently
        // stop testing the decode.
        final got = child(p, field);
        expect(got, isNotNull, reason: 'parameter $i missing decoded field $field');
        expect(got!.value, tp.prop(field)?.scalar, reason: 'parameter $i $field');
      }
    }
  });

  test('whole-corpus sweep: group-array step elements never fabricate', () {
    var files = 0, groupArrays = 0, steps = 0, ids = 0, comments = 0;
    for (final f in corpusSeqDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      files++;
      final tableNames = binaryTypeNames(bytes).toSet();
      for (final o in binarySequenceOutlines(bytes)) {
        if (o.comment != null) comments++;
        for (final g in o.groupArrays) {
          groupArrays++;
          expect(const {'Main', 'Setup', 'Cleanup'}, contains(g.name), reason: f.path);
          expect(g.className, 'Objs', reason: f.path);
          // A populated group's decoded element count equals its bounds.
          final count = boundCount(g.arrayLBound, g.arrayUBound);
          if (g.children.isNotEmpty) {
            expect(g.children, hasLength(count), reason: '${f.path} ${o.name}.${g.name}');
          }
          for (final s in g.children) {
            steps++;
            expect(s.className, 'Step', reason: '${f.path} ${o.name}.${g.name}');
            expect(s.name, isNotEmpty, reason: '${f.path} ${o.name}.${g.name}');
            // A bound type must come from the file's own recovered table.
            if (s.typeName != null) {
              expect(tableNames, contains(s.typeName), reason: '${f.path} step ${s.name}');
            }
            // The unique-Id honesty anchor, when serialized.
            final id = child(child(s, 'TS') ?? s, 'Id');
            if (id != null && id.value != null) {
              ids++;
              expect(id.value, startsWith('ID#:'), reason: '${f.path} step ${s.name}');
            }
          }
        }
      }
    }
    stdout.writeln(
      'sequence records: $groupArrays group arrays · $steps step elements · '
      '$ids Id anchors · $comments record comments across $files binaries',
    );
    // Round-3 measurement: 1019 group arrays / 2201 step elements (every
    // one carrying its `ID#:` anchor) across 294 binaries. Floors
    // under-pin slightly.
    expect(files, greaterThanOrEqualTo(165));
    expect(groupArrays, greaterThanOrEqualTo(600));
    expect(steps, greaterThanOrEqualTo(1650));
  });

  group('pinned corpus files (record-walk correctness)', () {
    final seqs = corpusSeqDir.existsSync()
        ? corpusSeqDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.seq'))
              .toList()
        : const <File>[];
    File? pin(String suffix) => seqs.where((f) => f.path.replaceAll(r'\', '/').endsWith(suffix)).firstOrNull;

    const pinnedSuffixes = [
      'SubSequences/6-H_Akım/Harmonik_Akım.seq',
      'sandbox/Test Sequence.seq',
      'SubSequences/5-Reaktif/Reaktif_Güç_1A_PF1.seq',
      'Very Old/Elatch-bench Backup.seq',
    ];

    test('pinned corpus files are present (guards silent skips)', () {
      // Each pinned test below early-returns when ITS file is absent (a
      // partial checkout may lack an individual file). This aggregate guard
      // catches the systemic case — a corpus rename/wholesale loss — that
      // would otherwise disable every pinned assertion silently.
      final present = pinnedSuffixes.where((s) => pin(s) != null).length;
      expect(
        present,
        pinnedSuffixes.length,
        reason: 'pinned record-walk corpus files missing — rename/partial checkout?',
      );
    });

    test('Harmonik_Akım.seq: record-walk-only discovery (no declaration paths)', () {
      final f = pin('SubSequences/6-H_Akım/Harmonik_Akım.seq');
      if (f == null) return; // pinned file absent from this corpus checkout
      final outlines = binarySequenceOutlines(Uint8List.fromList(f.readAsBytesSync()));
      final main = outlines.single.groupArrays.firstWhere((g) => g.name == 'Main');
      // 25 placed steps, all typed from the file's table.
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
      final f = pin('sandbox/Test Sequence.seq');
      if (f == null) return;
      final outlines = binarySequenceOutlines(Uint8List.fromList(f.readAsBytesSync()));
      final seq = outlines.where((o) => o.name == 'Sequence').single;
      final main = seq.groupArrays.firstWhere((g) => g.name == 'Main');
      final step = main.children.single;
      expect(step.name, 'Subseq');
      expect(step.typeName, 'DanfossStringValueTest');
      final limits = step.children.where((c) => c.name == 'Limits').single;
      expect(limits.children.single.value, 'String Limit');
    });

    test('Reaktif_Güç_1A_PF1.seq: expression-array elements (DataSourceArray) decode', () {
      final f = pin('SubSequences/5-Reaktif/Reaktif_Güç_1A_PF1.seq');
      if (f == null) return;
      final outlines = binarySequenceOutlines(Uint8List.fromList(f.readAsBytesSync()));
      final main = outlines.single.groupArrays.firstWhere((g) => g.name == 'Main');
      expect(main.children, hasLength(18));
      // A multi-numeric step's DataSourceArray: anonymous Expression
      // elements with their stored expressions.
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
      final f = pin('Very Old/Elatch-bench Backup.seq');
      if (f == null) return;
      final outlines = binarySequenceOutlines(Uint8List.fromList(f.readAsBytesSync()));
      final main = outlines.firstWhere((o) => o.name == 'MainSequence');
      expect(
        main.comment,
        'Override this in the client file with a sequence that performs tests on the UUT.',
      );
      // The record-walk-discovered subsequences with populated groups.
      final load = outlines.firstWhere((o) => o.name == 'Load_Variables');
      expect(load.groupArrays.firstWhere((g) => g.name == 'Main').children, hasLength(6));
    });
  });
}
