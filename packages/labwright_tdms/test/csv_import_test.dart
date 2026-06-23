import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

void main() {
  test('imports CSV columns as channels (blanks + ragged rows tolerated)', () {
    const csv = 'a,b\n1,9\n2,8\n3,\n';
    final f = TdmsReader.read(csvToTdms(csv));
    final g = f.group('Imported')!;
    expect(g.channel('a')!.data, [1.0, 2.0, 3.0]);
    expect(g.channel('b')!.data, [9.0, 8.0]); // blank 3rd cell skipped
  });

  test('round-trips values through tdms2csv', () {
    const csv = 'x,y\n1.5,2.5\n3.5,4.5\n';
    final lines = tdmsToCsv(csvToTdms(csv, group: 'G')).trim().split('\n');
    expect(lines.first, 'G/x,G/y'); // channels get the group prefix on export
    expect(lines[1], '1.5,2.5');
    expect(lines[2], '3.5,4.5');
  });

  test('handles a quoted header containing the delimiter', () {
    const csv = '"a,b",c\n1,2\n';
    final f = TdmsReader.read(csvToTdms(csv));
    expect(f.group('Imported')!.channel('a,b')!.data, [1.0]);
    expect(f.group('Imported')!.channel('c')!.data, [2.0]);
  });

  test('empty CSV yields an empty TDMS file', () {
    expect(TdmsReader.read(csvToTdms('')).groups, isEmpty);
  });
}
