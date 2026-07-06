import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

void main() {
  test('columns per channel, rows per sample, shorter channels padded', () {
    final bytes =
        (TdmsWriter()..writeSegment([
              TdmsChannel(group: 'M', name: 'a', data: const [1.0, 2.0, 3.0]),
              TdmsChannel(group: 'M', name: 'b', data: const [9.0, 8.0]),
            ]))
            .toBytes();
    final lines = tdmsToCsv(bytes).trim().split('\n');
    expect(lines, ['M/a,M/b', '1.0,9.0', '2.0,8.0', '3.0,']);
  });

  test('quotes header names containing the delimiter', () {
    final bytes =
        (TdmsWriter()..writeSegment([
              TdmsChannel(group: 'a,b', name: 'v', data: const [1.0]),
            ]))
            .toBytes();
    expect(tdmsToCsv(bytes).split('\n').first, '"a,b/v"');
  });

  test('honors a custom delimiter and header:false', () {
    final bytes =
        (TdmsWriter()..writeSegment([
              TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0]),
            ]))
            .toBytes();
    expect(tdmsToCsv(bytes, delimiter: ';', header: false).trim().split('\n'), ['1.0', '2.0']);
  });

  test('omits non-numeric (empty-data) channels; empty file -> empty string', () {
    final bytes =
        (TdmsWriter()..writeSegment([
              TdmsChannel(group: 'M', name: 'note', data: const [], properties: {'value': 'hi'}),
            ]))
            .toBytes();
    expect(tdmsToCsv(bytes), '');
  });
}
