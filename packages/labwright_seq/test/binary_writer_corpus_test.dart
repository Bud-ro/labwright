@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
  test('whole corpus: write(parse(f)) reproduces every inflated body byte-exactly', () {
    final bodyDiverged = <String>[], containerDiverged = <String>[], sizeWordLost = <String>[];
    final subnormalSlots = <String, int>{};
    var binaries = 0;
    for (final f in corpusSeqDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final model = parseBinarySeqWriteModel(bytes);
      if (model == null) continue;
      binaries++;
      final rel = corpusSeqRelativePath(f.path);
      final body = inflateBinaryBody(bytes)!;
      if (!_bytesEqual(model.writeBody(), body)) bodyDiverged.add(rel);
      final subnormal = model.f64Values.where((v) => v != 0 && v.isFinite && v.abs() < 2.2250738585072014e-308).length;
      if (subnormal != 0) subnormalSlots[rel] = subnormal;
      if (!model.headerHasSizeWord) sizeWordLost.add(rel);
      final file = model.writeFile();
      final reBody = inflateBinaryBody(file);
      final containerOk =
          detectSeqFormat(file) == SeqFormat.binary &&
          _bytesEqual(
            Uint8List.sublistView(file, 0, model.header.length),
            Uint8List.sublistView(bytes, 0, model.header.length),
          ) &&
          reBody != null &&
          _bytesEqual(reBody, body);
      if (!containerOk) containerDiverged.add(rel);
    }
    expect(binaries, greaterThan(0));
    expect(bodyDiverged, isEmpty);
    expect(subnormalSlots, const <String, int>{}, reason: 'i64-stored Num slots mis-read as f64');
    expect(containerDiverged, isEmpty);
    expect(sizeWordLost, isEmpty, reason: 'a header lost its PMCZ size field');
  });

  test('rosetta binaries: byte-exact bodies', () {
    final files = Directory('${corpusSeqDir.path}/rosetta').listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      expect(parseBinarySeqWriteModel(bytes)!.writeBody(), inflateBinaryBody(bytes), reason: f.path);
    }
  });

  group('mutation probes', () {
    Uint8List read(String relative) => File('${corpusSeqDir.path}/$relative').readAsBytesSync();

    test('step rename via its pool string (same length): delta is the pool entry alone', () {
      final bytes = read('rosetta/OutputVoltage_BIN.seq');
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

      final reparsed = model.writeFile();
      expect(_stepNamesOf(reparsed), [
        for (final name in _stepNamesOf(bytes)) name == oldName ? newName : name,
      ]);
      final delta = _liftDelta(bytes, reparsed);
      expect(delta, isNotEmpty);
      for (final line in delta) {
        expect(
          line.contains(oldName) || line.contains(newName),
          isTrue,
          reason: 'mutation bled into an unrelated decoded field: $line',
        );
      }
    });

    test('step rename with a DIFFERENT length: record region byte-identical (references are by index)', () {
      final bytes = read('rosetta/NIDmm_labview_BIN.seq');
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
        reason: 'a pool-length change must not perturb the record region',
      );

      final reparsed = model.writeFile();
      expect(_stepNamesOf(reparsed), [
        for (final name in _stepNamesOf(bytes)) name == oldName ? newName : name,
      ]);
      for (final line in _liftDelta(bytes, reparsed)) {
        expect(
          line.contains(oldName) || line.contains(newName),
          isTrue,
          reason: 'mutation bled into an unrelated decoded field: $line',
        );
      }
    });

    test('numeric value via its f64 slot: delta is the 8-byte slot and one decoded record', () {
      final bytes = read('rosetta/OutputVoltage_BIN.seq');
      final model = parseBinarySeqWriteModel(bytes)!;
      const oldValue = 2953567917.0;
      const newValue = 2953567918.0;
      expect(model.f64Sites(oldValue), hasLength(1));
      final site = model.f64Sites(oldValue).single;
      expect(model.replaceF64(oldValue, newValue), 1);

      final body = inflateBinaryBody(bytes)!;
      final mutated = model.writeBody();
      expect(mutated.length, body.length);
      _expectSpansWithin(_diffSpans(body, mutated), site, site + 8);

      final before = binaryPropertyRecords(bytes);
      final after = binaryPropertyRecords(model.writeFile());
      expect(after.length, before.length);
      var changed = 0;
      for (var i = 0; i < before.length; i++) {
        expect(after[i].name, before[i].name);
        expect(after[i].typeName, before[i].typeName);
        expect(after[i].offset, before[i].offset);
        if (before[i].value != after[i].value) {
          changed++;
          expect(before[i].name, 'Priority');
          expect(before[i].value, oldValue);
          expect(after[i].value, newValue);
        }
      }
      expect(changed, 1);
    });

    test('typed flag/attr surfaces are mutation-stable: a value mutation leaves every fieldFlags/attrWords intact', () {
      final bytes = read('rosetta/OutputVoltage_BIN.seq');
      final model = parseBinarySeqWriteModel(bytes)!;
      const oldValue = 2953567917.0;
      expect(model.replaceF64(oldValue, oldValue + 1), 1);

      List<String> flagSurface(Uint8List seq) {
        final out = <String>[];
        void walk(String path, BinaryTypeField f) {
          out.add('$path/${f.name}: flags=${f.fieldFlags} attrs=${f.attrWords}');
          for (final c in f.children) {
            walk('$path/${f.name}', c);
          }
        }

        for (final rec in binaryTypeRecords(seq)) {
          for (final f in rec.fields ?? const <BinaryTypeField>[]) {
            walk(rec.name, f);
          }
        }
        return out;
      }

      final before = flagSurface(bytes);
      final after = flagSurface(model.writeFile());
      expect(before, isNotEmpty);
      expect(after, before, reason: 'flag/attr surface must be identical after an unrelated value mutation');
    });

    test('pool[0]-`Obj` generation: a parameter rename mutates exactly its pool entry, decode stays stable', () {
      final bytes = read('michael-harhay-arx_CICDUtility/michael-harhay-arx-CICDUtility-02c6c67/Sequence/iTAC.seq');
      final model = parseBinarySeqWriteModel(bytes)!;
      final body = model.writeBody();
      const oldName = 'iTACStationID';
      const newName = 'iTacSTATIONid';
      final entryIndex = model.pool.indexOf(oldName);
      expect(entryIndex, greaterThan(0));
      expect(model.replacePoolEntry(oldName, newName), 1);

      final mutated = model.writeBody();
      final (start, end) = model.poolEntryRange(entryIndex);
      expect(mutated.length, body.length);
      _expectSpansWithin(_diffSpans(body, mutated), start, end);

      List<String> surface(Uint8List seq) => [
        for (final o in binarySequenceOutlines(seq))
          for (final p in o.leadingSubProps)
            for (final c in p.children) '${o.name}/${p.name}/${c.className}:${c.name}=${c.value}',
      ];
      final before = surface(bytes);
      final after = surface(model.writeFile());
      expect(after.length, before.length);
      var changed = 0;
      for (var i = 0; i < before.length; i++) {
        if (before[i] != after[i]) {
          changed++;
          expect(after[i], before[i].replaceAll(oldName, newName), reason: 'only the renamed parameter may differ');
        }
      }
      expect(changed, greaterThanOrEqualTo(1), reason: 'the rename must be visible in the decoded surface');
    });

    test('sequence comment via its pool string: delta is the comment alone', () {
      final bytes = read(
        'JavierABH_Elatch-Bench-Test/JavierABH-Elatch-Bench-Test-71012f4/'
        'Sequence/History/Very Old/Elatch-bench - Ford Test.seq',
      );
      final model = parseBinarySeqWriteModel(bytes)!;
      const oldComment = 'Override this in the client file with a sequence that performs tests on the UUT.';
      const newComment = 'OVERRIDE this in the client file with a sequence that performs tests on the UUT.';
      final entryIndex = model.pool.indexOf(oldComment);
      expect(entryIndex, greaterThan(0));
      expect(model.replacePoolEntry(oldComment, newComment), 1);

      final body = inflateBinaryBody(bytes)!;
      final (start, end) = model.poolEntryRange(entryIndex);
      _expectSpansWithin(_diffSpans(body, model.writeBody()), start, end);

      final beforeOutlines = binarySequenceOutlines(bytes);
      final afterOutlines = binarySequenceOutlines(model.writeFile());
      expect(afterOutlines.length, beforeOutlines.length);
      var changed = 0;
      for (var i = 0; i < beforeOutlines.length; i++) {
        expect(afterOutlines[i].name, beforeOutlines[i].name);
        if (beforeOutlines[i].comment != afterOutlines[i].comment) {
          changed++;
          expect(beforeOutlines[i].comment, oldComment);
          expect(afterOutlines[i].comment, newComment);
        }
      }
      expect(changed, 1, reason: 'exactly one sequence comment must change');
    });
  });
}

void _expectSpansWithin(List<(int, int)> spans, int start, int end) {
  expect(spans, isNotEmpty, reason: 'the mutation must change bytes');
  for (final span in spans) {
    expect(
      span.$1 >= start && span.$2 <= end,
      isTrue,
      reason: 'diff span $span escapes the mutated range [$start, $end) — entanglement',
    );
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

List<String> _stepNamesOf(Uint8List seqBytes) => [
  for (final outline in binarySequenceOutlines(seqBytes))
    for (final step in [...outline.setup, ...outline.main, ...outline.cleanup, ...outline.ungrouped]) step.name,
];

List<String> _liftDelta(Uint8List a, Uint8List b) {
  List<String> lift(Uint8List bytes) =>
      String.fromCharCodes(writeSeqFileXml(binaryToXmlSeqFile(parseSeqFile(bytes)))).split('\n');
  final counts = <String, int>{};
  for (final line in lift(a)) {
    counts.update(line, (v) => v + 1, ifAbsent: () => 1);
  }
  for (final line in lift(b)) {
    counts.update(line, (v) => v - 1, ifAbsent: () => -1);
  }
  return [
    for (final e in counts.entries)
      if (e.value != 0) e.key.trim(),
  ];
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
