import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

void main() {
  test('empty bytes parse to an empty file', () {
    final f = TdmsReader.read(Uint8List(0));
    expect(f.groups, isEmpty);
    expect(f.properties, isEmpty);
  });

  test('zero-channel segment keeps file properties, no groups', () {
    final f = TdmsReader.read((TdmsWriter()..writeSegment(const [], fileProperties: {'op': 'x'})).toBytes());
    expect(f.groups, isEmpty);
    expect(f.properties['op'], 'x');
  });

  test('a channel with zero values round-trips empty', () {
    final f = TdmsReader.read(
      (TdmsWriter()..writeSegment([TdmsChannel(group: 'M', name: 'v', data: const [])])).toBytes(),
    );
    expect(f.group('M')!.channel('v')!.data, isEmpty);
  });

  test('single-sample channel round-trips', () {
    final f = TdmsReader.read(
      (TdmsWriter()..writeSegment([
            TdmsChannel(group: 'M', name: 'v', data: const [42.0]),
          ]))
          .toBytes(),
    );
    expect(f.group('M')!.channel('v')!.data, [42.0]);
  });
}
