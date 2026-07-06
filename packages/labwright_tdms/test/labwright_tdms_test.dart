import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips one segment with file/group/channel properties', () {
    final w = TdmsWriter();
    w.writeSegment(
      [
        TdmsChannel(
          group: 'Meas',
          name: 'rail_V',
          data: [3.30, 3.31, 3.29],
          properties: {'unit': 'V', 'count': 3, 'gain': 2.0, 'inverted': false},
        ),
      ],
      fileProperties: {'operator': 'loop'},
      groupProperties: {
        'Meas': {'dut': 'DUT-1'},
      },
    );

    final f = TdmsReader.read(w.toBytes());
    expect(f.properties['operator'], 'loop');

    final g = f.group('Meas')!;
    expect(g.properties['dut'], 'DUT-1');

    final c = g.channel('rail_V')!;
    expect(c.data, [3.30, 3.31, 3.29]);
    expect(c.properties['unit'], 'V');
    expect(c.properties['count'], 3);
    expect(c.properties['gain'], 2.0);
    expect(c.properties['inverted'], false);
  });

  test('streams across multiple segments, appending samples', () {
    final w = TdmsWriter()
      ..writeSegment([
        TdmsChannel(group: 'M', name: 'v', data: [1.0, 2.0]),
      ])
      ..writeSegment([
        TdmsChannel(group: 'M', name: 'v', data: [3.0, 4.0, 5.0]),
      ]);
    final f = TdmsReader.read(w.toBytes());
    expect(f.group('M')!.channel('v')!.data, [1.0, 2.0, 3.0, 4.0, 5.0]);
  });

  test('keeps multiple channels in a segment separate', () {
    final w = TdmsWriter()
      ..writeSegment([
        TdmsChannel(group: 'M', name: 'a', data: [1.0, 2.0]),
        TdmsChannel(group: 'M', name: 'b', data: [9.0, 8.0]),
      ]);
    final f = TdmsReader.read(w.toBytes());
    expect(f.group('M')!.channel('a')!.data, [1.0, 2.0]);
    expect(f.group('M')!.channel('b')!.data, [9.0, 8.0]);
  });

  test('begins with the TDSm tag and TDMS v2 version', () {
    final b =
        (TdmsWriter()..writeSegment([
              TdmsChannel(group: 'M', name: 'v', data: [1.0]),
            ]))
            .toBytes();
    expect(String.fromCharCodes(b.sublist(0, 4)), 'TDSm');
    expect(ByteData.sublistView(b).getUint32(8, Endian.little), 4713);
  });

  test('escapes single quotes in group/channel names', () {
    final w = TdmsWriter()
      ..writeSegment([
        TdmsChannel(group: "O'Brien", name: "a'b", data: [1.0]),
      ]);
    final f = TdmsReader.read(w.toBytes());
    expect(f.group("O'Brien")!.channel("a'b")!.data, [1.0]);
  });
}
