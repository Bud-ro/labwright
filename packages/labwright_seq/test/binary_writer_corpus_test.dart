@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// The binary TOF1 writer's corpus gates (`write(parse(x)) == x` over every
/// corpus binary) and its mutation probes (one targeted model mutation must
/// change EXACTLY the intended bytes and decoded surface — anything else is
/// entanglement). Full-file container gates are structural, not byte-exact:
/// no Dart `ZLibCodec` setting reproduces NI's DEFLATE bytes on any corpus
/// file, so the gate re-inflates the fresh stream instead.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('binary writer corpus gates (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  test('whole corpus: write(parse(f)) reproduces every inflated body byte-exactly', () {
    var binaries = 0, bodyExact = 0, containerOk = 0, sizeWords = 0;
    var total = const BinaryWriteScoreboard(
      bodyBytes: 0,
      poolBytes: 0,
      modelBytes: 0,
      structuralBytes: 0,
      copiedBytes: 0,
    );
    final failures = <String>[];
    for (final f in corpusSeqDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final model = parseBinarySeqWriteModel(bytes);
      if (model == null) continue;
      binaries++;
      final body = inflateBinaryBody(bytes)!;
      if (_bytesEqual(model.writeBody(), body)) {
        bodyExact++;
      } else {
        failures.add(f.path);
      }
      total = total + model.scoreboard;

      if (model.headerHasSizeWord) sizeWords++;
      final file = model.writeFile();
      final reBody = inflateBinaryBody(file);
      if (detectSeqFormat(file) == SeqFormat.binary &&
          _bytesEqual(
            Uint8List.sublistView(file, 0, model.header.length),
            Uint8List.sublistView(bytes, 0, model.header.length),
          ) &&
          reBody != null &&
          _bytesEqual(reBody, body)) {
        containerOk++;
      }
    }
    print(
      'binary writer: $bodyExact/$binaries bodies byte-exact · '
      '$containerOk containers structurally reproduced · '
      '$sizeWords size words · $total',
    );
    expect(failures, isEmpty, reason: 'body round-trip diverged:\n${failures.take(5).join('\n')}');
    expect(binaries, greaterThanOrEqualTo(165));
    expect(bodyExact, binaries);
    expect(containerOk, binaries);
    expect(sizeWords, binaries, reason: 'a header lost its PMCZ size field');
    // Scoreboard floors: model + structure tracks the coverage pass's semantic
    // tier by construction; decode progress must raise them.
    expect(total.recordModelRatio, greaterThanOrEqualTo(0.15));
    expect((total.modelBytes + total.structuralBytes) / total.recordRegionBytes, greaterThanOrEqualTo(0.30));
    expect(total.bodyModelRatio, greaterThanOrEqualTo(0.22));
  });

  test('rosetta binaries: byte-exact bodies with a majority-model record region', () {
    var checked = 0;
    for (final f in Directory('${corpusSeqDir.path}/rosetta').listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final model = parseBinarySeqWriteModel(bytes)!;
      expect(model.writeBody(), inflateBinaryBody(bytes), reason: f.path);
      expect(model.scoreboard.recordModelRatio, greaterThanOrEqualTo(0.25), reason: f.path);
      checked++;
    }
    expect(checked, greaterThanOrEqualTo(6), reason: 'rosetta binaries missing — partial checkout?');
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
      // The twin-validated `Priority` default — the only slot holding it.
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

    test('sequence comment via its pool string: delta is the comment alone', () {
      // The rosetta binaries' newer record generation carries no comment slot,
      // so this anchors on an older-generation corpus binary.
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

/// Asserts the diff is non-empty and every span sits inside `[start, end)`.
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

/// Maximal differing byte spans between two equal-length buffers.
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

/// Every step name of every sequence outline, flattened in order.
List<String> _stepNamesOf(Uint8List seqBytes) => [
  for (final outline in binarySequenceOutlines(seqBytes))
    for (final step in [...outline.setup, ...outline.main, ...outline.cleanup, ...outline.ungrouped]) step.name,
];

/// The multiset line delta between the XML lifts of two binary files — the
/// full decoded surface, so any perturbed unrelated field shows up here.
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
