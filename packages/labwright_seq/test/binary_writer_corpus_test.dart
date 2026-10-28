@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
  Uint8List read(String relative) => File('${corpusSeqDir.path}/$relative').readAsBytesSync();

  test('whole corpus: writeFile(parse(f)) re-inflates to the original body and re-parses to the same model', () {
    var binaries = 0;
    for (final f in corpusSeqDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binaries++;
      final rel = corpusSeqRelativePath(f.path);
      final model = parseBinarySeqWriteModel(bytes)!;
      final body = inflateBinaryBody(bytes)!;
      expect(model.writeBody(), body, reason: rel);
      final file = model.writeFile();
      expect(
        Uint8List.sublistView(file, 0, Tof1HeaderField.body.offset),
        Uint8List.sublistView(bytes, 0, Tof1HeaderField.body.offset),
        reason: '$rel: header',
      );
      expect(inflateBinaryBody(file), body, reason: '$rel: re-inflated body');
      expect(
        seqPropertyDeepEquals(parseSeqFile(file).data, parseSeqFile(bytes).data),
        isTrue,
        reason: '$rel: the rewritten file must lift to the same model',
      );
    }
    expect(binaries, 140);
  });

  group('mutation probes', () {
    test('a step rename of equal length changes the pool entry alone', () {
      final bytes = read('seq-corpus/rosetta/OutputVoltage_BIN.seq');
      final model = parseBinarySeqWriteModel(bytes)!;
      final body = model.writeBody();
      const oldName = 'Output voltage test';
      const newName = 'OUTPUT VOLTAGE test';
      final entryIndex = model.pool.indexOf(oldName);
      expect(entryIndex, greaterThan(0));
      expect(model.replacePoolEntry(oldName, newName), 1);
      final mutated = model.writeBody();
      final (start, end) = model.poolEntryRange(entryIndex);
      expect(mutated.length, body.length);
      _expectSpansWithin(_diffSpans(body, mutated), start, end);
      expect(_stepNames(model.writeFile()), [for (final n in _stepNames(bytes)) n == oldName ? newName : n]);
    });

    test('a step rename of a different length leaves the record region byte-identical', () {
      final bytes = read('seq-corpus/rosetta/NIDmm_labview_BIN.seq');
      final model = parseBinarySeqWriteModel(bytes)!;
      const oldName = 'Acquire Measurement';
      const newName = 'Acquire Measurement (probed)';
      expect(model.replacePoolEntry(oldName, newName), 1);
      final body = inflateBinaryBody(bytes)!;
      final mutated = model.writeBody();
      expect(mutated.length, body.length + newName.length - oldName.length);
      expect(
        Uint8List.sublistView(mutated, 0, model.recordRegionLength),
        Uint8List.sublistView(body, 0, model.recordRegionLength),
      );
      expect(_stepNames(model.writeFile()), [for (final n in _stepNames(bytes)) n == oldName ? newName : n]);
    });

    test('a numeric value changes its eight bytes and the one property that holds it', () {
      final bytes = read('seq-corpus/rosetta/OutputVoltage_BIN.seq');
      final model = parseBinarySeqWriteModel(bytes)!;
      const oldValue = 2953567917.0;
      const newValue = 2953567918.0;
      final sites = model.f64Sites(oldValue);
      expect(sites, hasLength(1));
      expect(model.replaceF64(oldValue, newValue), 1);
      final body = inflateBinaryBody(bytes)!;
      final mutated = model.writeBody();
      expect(mutated.length, body.length);
      _expectSpansWithin(_diffSpans(body, mutated), sites.single, sites.single + 8);
      final before = parseSeqFile(bytes), after = parseSeqFile(model.writeFile());
      final changed = <String>[];
      void walk(String path, SeqProperty a, SeqProperty b) {
        if (a.scalar != b.scalar) changed.add('$path ${a.scalar} -> ${b.scalar}');
        for (var i = 0; i < a.subProps.length; i++) {
          walk('$path/${a.subProps[i].name}', a.subProps[i], b.subProps[i]);
        }
        for (var i = 0; i < (a.array?.length ?? 0); i++) {
          walk('$path[$i]', a.array![i], b.array![i]);
        }
      }

      walk('Data', before.data, after.data);
      expect(changed, ['Data/Seq[0]/RTS/Priority 2953567917 -> 2953567918']);
    });

    test('a parameter rename stays confined to its pool entry', () {
      final bytes = read('seq-corpus/sources/FloresFelipe__csv-doc-gen-tool-teststand/src/docgen_html.seq');
      final model = parseBinarySeqWriteModel(bytes)!;
      final body = model.writeBody();
      const oldName = 'TotalNumSteps';
      const newName = 'TOTALnumSTEPS';
      final entryIndex = model.pool.indexOf(oldName);
      expect(model.replacePoolEntry(oldName, newName), 1);
      final mutated = model.writeBody();
      final (start, end) = model.poolEntryRange(entryIndex);
      _expectSpansWithin(_diffSpans(body, mutated), start, end);
      final renamed = parseSeqFile(model.writeFile());
      final names = {
        for (final s in renamed.sequences)
          for (final p in [...s.parameters, ...s.locals]) p.name,
      };
      expect(names, contains(newName));
      expect(names, isNot(contains(oldName)));
    });

    test('a sequence comment changes through its pool entry alone', () {
      final bytes = read('seq-corpus/sources/Aldo633__TestStandLock-API/Lock Test.seq');
      final model = parseBinarySeqWriteModel(bytes)!;
      const oldComment =
          'Test UUTs and Single Pass call this callback in their setup step group. It is empty in the model file.  '
          'Override this in the client file to perform an action before any code in the model executes.';
      const newComment =
          'Test UUTs and Single Pass call this callback in their setup step group. It is empty in the model file.  '
          'OVERRIDE this in the client file to perform an action before any code in the model executes.';
      final entryIndex = model.pool.indexOf(oldComment);
      expect(entryIndex, greaterThan(0));
      expect(model.replacePoolEntry(oldComment, newComment), 1);
      final body = inflateBinaryBody(bytes)!;
      final (start, end) = model.poolEntryRange(entryIndex);
      _expectSpansWithin(_diffSpans(body, model.writeBody()), start, end);
      final before = parseSeqFile(bytes).sequences, after = parseSeqFile(model.writeFile()).sequences;
      var changed = 0;
      for (var i = 0; i < before.length; i++) {
        expect(after[i].name, before[i].name);
        if (before[i].comment != after[i].comment) {
          changed++;
          expect((before[i].comment, after[i].comment), (oldComment, newComment));
        }
      }
      expect(changed, 1);
    });
  });
}

void _expectSpansWithin(List<(int, int)> spans, int start, int end) {
  expect(spans, isNotEmpty, reason: 'the mutation must change bytes');
  for (final span in spans) {
    expect(span.$1 >= start && span.$2 <= end, isTrue, reason: 'diff span $span escapes [$start, $end)');
  }
}

List<(int, int)> _diffSpans(Uint8List a, Uint8List b) {
  final spans = <(int, int)>[];
  var start = -1;
  for (var i = 0; i <= a.length; i++) {
    final differs = i < a.length && a[i] != b[i];
    if (differs && start < 0) start = i;
    if (!differs && start >= 0) {
      spans.add((start, i));
      start = -1;
    }
  }
  return spans;
}

List<String> _stepNames(Uint8List seqBytes) => [
  for (final sequence in parseSeqFile(seqBytes).sequences)
    for (final step in sequence.steps) step.name,
];
