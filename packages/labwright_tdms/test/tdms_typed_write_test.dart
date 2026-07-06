import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips every writable numeric channel type', () {
    final cases = <(TdsType, List<double>)>[
      (TdsType.i8, [-5, 0, 127, -128]),
      (TdsType.u8, [0, 1, 255]),
      (TdsType.i16, [-5, 0, 32767, -32768]),
      (TdsType.u16, [0, 1, 65535]),
      (TdsType.i32, [-5, 7, 2147483647, -2147483648]),
      (TdsType.u32, [0, 1, 4294967295]),
      (TdsType.i64, [-5, 7, 1000000000000]),
      (TdsType.u64, [0, 1, 1000000000000]),
      (TdsType.singleFloat, [1.5, -2.25, 0]),
      (TdsType.doubleFloat, [3.30, -1.0e9, 0]),
    ];

    for (final (type, values) in cases) {
      final bytes = (TdmsWriter()..writeSegment([TdmsChannel(group: 'M', name: 'v', data: values, type: type)]))
          .toBytes();
      final read = TdmsReader.read(bytes).group('M')!.channel('v')!.data;
      if (type == TdsType.singleFloat) {
        expect(read.length, values.length);
        for (var i = 0; i < values.length; i++) {
          expect(read[i], closeTo(values[i], 1e-5), reason: '$type[$i]');
        }
      } else {
        expect(read, values, reason: '$type');
      }
    }
  });

  test('the writer rejects non-numeric channel types', () {
    expect(
      () => (TdmsWriter()..writeSegment([TdmsChannel(group: 'M', name: 's', data: const [], type: TdsType.string)])),
      throwsArgumentError,
    );
  });
}
