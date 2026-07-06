import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

void main() {
  group('csvToTdms edge cases', () {
    test('CRLF line endings parse like LF', () {
      final f = TdmsReader.read(csvToTdms('a,b\r\n1,2\r\n3,4\r\n'));
      expect(f.group('Imported')!.channel('a')!.data, [1.0, 3.0]);
      expect(f.group('Imported')!.channel('b')!.data, [2.0, 4.0]);
    });

    test('non-numeric cells are skipped, numeric kept', () {
      final f = TdmsReader.read(csvToTdms('v\n1\nNaNish\n3\n'));
      expect(f.group('Imported')!.channel('v')!.data, [1.0, 3.0]);
    });

    test('rows with extra cells beyond the header do not crash; extras ignored', () {
      final f = TdmsReader.read(csvToTdms('a\n1,2,3\n4\n'));
      expect(f.group('Imported')!.channel('a')!.data, [1.0, 4.0]);
    });

    test('leading/trailing whitespace in cells is trimmed before parsing', () {
      final f = TdmsReader.read(csvToTdms('a\n  1.5 \n\t2.5\t\n'));
      expect(f.group('Imported')!.channel('a')!.data, [1.5, 2.5]);
    });

    test('custom delimiter', () {
      final f = TdmsReader.read(csvToTdms('a;b\n1;2\n', delimiter: ';'));
      expect(f.group('Imported')!.channel('a')!.data, [1.0]);
      expect(f.group('Imported')!.channel('b')!.data, [2.0]);
    });

    test('whitespace-only / header-only input yields empty channels, no crash', () {
      expect(() => csvToTdms('   '), returnsNormally);
      final f = TdmsReader.read(csvToTdms('a,b\n'));
      expect(f.group('Imported')!.channel('a')!.data, isEmpty);
      expect(f.group('Imported')!.channel('b')!.data, isEmpty);
    });
  });

  group('tdmsToCsv edge cases', () {
    test('header:false omits the header row', () {
      final bytes =
          (TdmsWriter()..writeSegment([
                TdmsChannel(group: 'G', name: 'x', data: const [1.5, 2.5]),
              ]))
              .toBytes();
      final csv = tdmsToCsv(bytes, header: false).trim();
      expect(csv, '1.5\n2.5');
    });

    test('ragged channel lengths pad shorter columns with empty cells', () {
      final bytes =
          (TdmsWriter()..writeSegment([
                TdmsChannel(group: 'G', name: 'long', data: const [1.0, 2.0, 3.0]),
                TdmsChannel(group: 'G', name: 'short', data: const [9.0]),
              ]))
              .toBytes();
      final lines = tdmsToCsv(bytes).trim().split('\n');
      expect(lines[0], 'G/long,G/short');
      expect(lines[1], '1.0,9.0');
      expect(lines[2], '2.0,');
      expect(lines[3], '3.0,');
    });

    test('a file with no numeric channels yields empty CSV', () {
      final bytes =
          (TdmsWriter()..writeSegment([
                TdmsChannel(group: 'G', name: 'note', data: const [], properties: {'value': 'hi'}),
              ]))
              .toBytes();
      expect(tdmsToCsv(bytes), '');
    });
  });

  test('csv -> tdms -> csv -> tdms is numerically stable (column data preserved)', () {
    const csv = 'x,y,z\n1.5,2.5,3.5\n4.5,5.5,6.5\n7.5,8.5,9.5\n';
    List<List<double>> cols(String c) {
      final f = TdmsReader.read(csvToTdms(c));
      return [
        for (final g in f.groups)
          for (final ch in g.channels) ch.data,
      ];
    }

    final first = cols(csv);
    final second = cols(tdmsToCsv(csvToTdms(csv)));
    expect(first, [
      [1.5, 4.5, 7.5],
      [2.5, 5.5, 8.5],
      [3.5, 6.5, 9.5],
    ]);
    expect(second, first);
  });
}
