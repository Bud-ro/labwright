// TdmsWriter -> bytes -> TdmsReader round-trips, plus reader edge inputs.
import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

import 'util.dart';

void main() {
  test('one segment round-trips file/group/channel properties of every type', () {
    final f = reread(
      [
        ch('Meas', 'rail_V', [3.30, 3.31, 3.29], props: {'unit': 'V', 'count': 3, 'gain': 2.0, 'inverted': false}),
      ],
      fileProps: {'operator': 'loop'},
      groupProps: {
        'Meas': {'dut': 'DUT-1'},
      },
    );
    expect(f.properties['operator'], 'loop');
    expect(f.group('Meas')!.properties['dut'], 'DUT-1');
    final c = f.group('Meas')!.channel('rail_V')!;
    expect(c.data, [3.30, 3.31, 3.29]);
    expect(c.properties, {'unit': 'V', 'count': 3, 'gain': 2.0, 'inverted': false});
  });

  // dart format off
  final shapes = <(String, List<List<TdmsChannel>>, Map<String, List<double>>)>[
    ('multiple segments append samples to the same channel',
        [[ch('M', 'v', [1, 2])], [ch('M', 'v', [3, 4, 5])]], {'M/v': [1, 2, 3, 4, 5]}),
    ('channels in one segment stay separate',
        [[ch('M', 'a', [1, 2]), ch('M', 'b', [9, 8])]], {'M/a': [1, 2], 'M/b': [9, 8]}),
    ('two groups in one segment', [[ch('A', 'x', [1]), ch('B', 'y', [2])]], {'A/x': [1], 'B/y': [2]}),
    ('a later segment can introduce a new channel',
        [[ch('M', 'a', [1])], [ch('M', 'b', [2])]], {'M/a': [1], 'M/b': [2]}),
    ('single quotes in group/channel names are escaped',
        [[ch("O'Brien", "a'b", [1])]], {"O'Brien/a'b": [1]}),
    ('zero-value channel round-trips empty', [[ch('M', 'v', [])]], {'M/v': []}),
    ('single sample', [[ch('M', 'v', [42])]], {'M/v': [42]}),
  ];
  // dart format on
  for (final (name, segments, want) in shapes) {
    test(name, () {
      final w = TdmsWriter();
      segments.forEach(w.writeSegment);
      expect(channelsOf(TdmsReader.read(w.toBytes())), want);
    });
  }

  test('lead-in begins with the TDSm tag and TDMS v2 version', () {
    final b = write([
      ch('M', 'v', [1]),
    ]);
    expect(String.fromCharCodes(b.sublist(0, 4)), 'TDSm');
    expect(ByteData.sublistView(b).getUint32(8, Endian.little), 4713);
  });

  test('empty bytes parse to an empty file', () {
    final f = TdmsReader.read(Uint8List(0));
    expect(f.groups, isEmpty);
    expect(f.properties, isEmpty);
  });

  test('zero-channel segment keeps file properties, no groups', () {
    final f = reread(const [], fileProps: {'op': 'x'});
    expect(f.groups, isEmpty);
    expect(f.properties['op'], 'x');
  });

  test('every writable numeric channel type round-trips', () {
    // dart format off
    const cases = <(TdsType, List<double>, double)>[
      (TdsType.i8, [-5, 0, 127, -128], 0),
      (TdsType.u8, [0, 1, 255], 0),
      (TdsType.i16, [-5, 0, 32767, -32768], 0),
      (TdsType.u16, [0, 1, 65535], 0),
      (TdsType.i32, [-5, 7, 2147483647, -2147483648], 0),
      (TdsType.u32, [0, 1, 4294967295], 0),
      (TdsType.i64, [-5, 7, 1000000000000, -1000000000000], 0),
      (TdsType.u64, [0, 1, 1000000000000], 0),
      (TdsType.singleFloat, [1.5, -2.25, 0, 3.14], 1e-5),
      (TdsType.doubleFloat, [3.30, -1.0e9, 0, 1e-300], 0),
    ];
    // dart format on
    for (final (type, values, tol) in cases) {
      final read = TdmsReader.read(write([ch('M', 'v', values, type: type)])).group('M')!.channel('v')!.data;
      for (var i = 0; i < values.length; i++) {
        expect(read[i], tol == 0 ? values[i] : closeTo(values[i], tol), reason: '$type[$i]');
      }
      expect(read, hasLength(values.length), reason: '$type');
    }
  });

  test('the writer rejects every non-numeric channel type', () {
    for (final type in const [TdsType.string, TdsType.boolean, TdsType.timestamp]) {
      expect(
        () => TdmsWriter().writeSegment([ch('M', 's', const [], type: type)]),
        throwsArgumentError,
        reason: '$type',
      );
    }
  });
}
