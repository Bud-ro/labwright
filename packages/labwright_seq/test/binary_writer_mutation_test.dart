@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// MUTATION PROBES over the binary writer: apply one targeted model mutation,
/// re-serialize, and assert the delta is EXACTLY the intended field — at the
/// byte level (diff spans confined to the mutated pool entry / value slot)
/// and at the decoded-model level (re-parse of the written file changes only
/// the intended surface). A mutation that bled into unrelated spans or
/// unrelated decoded fields is an entanglement bug and fails here.
///
/// The record region references the string pool BY INDEX, so a pool-string
/// mutation must leave the record region untouched — including a
/// LENGTH-CHANGING rename (probed below), which shifts every later pool
/// entry's byte offset without invalidating a single reference.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('binary writer mutation probes (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  Uint8List read(String relative) => Uint8List.fromList(File('${corpusSeqDir.path}/$relative').readAsBytesSync());

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

    // Re-parse the whole written FILE: exactly one step name changed.
    final reparsed = model.writeFile();
    final before = _stepNamesOf(bytes);
    final after = _stepNamesOf(reparsed);
    expect(after, [
      for (final name in before) name == oldName ? newName : name,
    ]);
    // The full decoded surface (XML lift) changes only on lines carrying
    // the renamed step.
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
    final before = _stepNamesOf(bytes);
    final after = _stepNamesOf(reparsed);
    expect(after, [
      for (final name in before) name == oldName ? newName : name,
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

    // Decoded-surface diff over the leaf property records: exactly the
    // Priority record's value changed.
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
    // The rosetta binaries are the newer record generation whose sequence
    // heads carry no comment slot, so the comment probe anchors on a
    // comment-carrying corpus binary (older-generation head).
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
    final mutated = model.writeBody();
    final (start, end) = model.poolEntryRange(entryIndex);
    _expectSpansWithin(_diffSpans(body, mutated), start, end);

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
}

/// Asserts the diff is non-empty and every span sits inside `[start, end)` —
/// the mutation touched its target and NOTHING else.
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
/// full decoded surface, so a mutation that perturbed ANY unrelated decoded
/// field shows up here.
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
