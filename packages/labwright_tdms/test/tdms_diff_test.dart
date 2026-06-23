import 'dart:convert';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

TdmsFile _read(List<TdmsChannel> channels) => TdmsReader.read((TdmsWriter()..writeSegment(channels)).toBytes());

void main() {
  test('identical files diff to identical=true and encode as JSON', () {
    final a = _read([TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0, 3.0])]);
    final b = _read([TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0, 3.0])]);
    final d = diffTdms(a, b);
    expect(d['identical'], isTrue);
    expect(d['channels'], isEmpty);
    expect(() => jsonEncode(d), returnsNormally);
  });

  test('detects a value difference with first index and max delta', () {
    final a = _read([TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0, 3.0])]);
    final b = _read([TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.5, 3.0])]);
    final d = diffTdms(a, b);
    expect(d['identical'], isFalse);
    final ch = (d['channels'] as List).single as Map<String, Object?>;
    expect(ch['status'], 'valueDiff');
    expect(ch['firstDiffIndex'], 1);
    expect(ch['maxAbsDelta'], closeTo(0.5, 1e-12));
  });

  test('tolerance absorbs small differences', () {
    final a = _read([TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0])]);
    final b = _read([TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.05])]);
    expect(diffTdms(a, b, tol: 0.1)['identical'], isTrue);
    expect(diffTdms(a, b, tol: 0.01)['identical'], isFalse);
  });

  test('detects added/removed channels and groups, and length mismatch', () {
    final a = _read([
      TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0]),
      TdmsChannel(group: 'OnlyA', name: 'x', data: const [9.0]),
    ]);
    final b = _read([
      TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0, 3.0]),
      TdmsChannel(group: 'M', name: 'added', data: const [7.0]),
    ]);
    final d = diffTdms(a, b);
    expect(d['identical'], isFalse);
    expect(d['groupsOnlyInA'], ['OnlyA']);
    final chans = (d['channels'] as List).cast<Map<String, Object?>>();
    final v = chans.firstWhere((c) => c['name'] == 'v');
    expect(v['status'], 'lengthMismatch');
    expect(v['lenA'], 2);
    expect(v['lenB'], 3);
    final added = chans.firstWhere((c) => c['name'] == 'added');
    expect(added['status'], 'onlyInB');
  });
}
