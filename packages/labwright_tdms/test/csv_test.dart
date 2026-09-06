import 'dart:math';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

import 'util.dart';

void main() {
  // dart format off
  const toTdms = <(String, String, String, Map<String, List<double>>)>[
    ('columns become channels; blank cells and short rows tolerated', 'a,b\n1,9\n2,8\n3,\n', ',', {'a': [1, 2, 3], 'b': [9, 8]}),
    ('CRLF parses like LF', 'a,b\r\n1,2\r\n3,4\r\n', ',', {'a': [1, 3], 'b': [2, 4]}),
    ('non-numeric cells are skipped', 'v\n1\nNaNish\n3\n', ',', {'v': [1, 3]}),
    ('extra cells beyond the header are ignored', 'a\n1,2,3\n4\n', ',', {'a': [1, 4]}),
    ('cell whitespace is trimmed before parsing', 'a\n  1.5 \n\t2.5\t\n', ',', {'a': [1.5, 2.5]}),
    ('custom delimiter', 'a;b\n1;2\n', ';', {'a': [1], 'b': [2]}),
    ('header-only input yields empty channels', 'a,b\n', ',', {'a': [], 'b': []}),
    ('whitespace-only input yields one empty channel', '   ', ',', {'   ': []}),
    ('quoted header containing the delimiter', '"a,b",c\n1,2\n', ',', {'a,b': [1], 'c': [2]}),
    ('quoted header containing a newline', '"a\nb",c\n1,2\n', ',', {'a\nb': [1], 'c': [2]}),
    ('quoted data cell', 'a\n"1"\n', ',', {'a': [1]}),
    ('scientific notation and leading-dot values', 'a\n-2e3\n.5\n', ',', {'a': [-2000, 0.5]}),
    ('empty input yields an empty file', '', ',', {}),
  ];
  // dart format on
  for (final (name, csv, delimiter, want) in toTdms) {
    test('csvToTdms: $name', () {
      final f = TdmsReader.read(csvToTdms(csv, delimiter: delimiter));
      expect(channelsOf(f).map((k, v) => MapEntry(k.substring('Imported/'.length), v)), want);
    });
  }

  // dart format off
  final toCsv = <(String, List<TdmsChannel>, String, bool, String)>[
    ('one column per channel, shorter columns padded with empty cells',
        [ch('M', 'a', [1, 2, 3]), ch('M', 'b', [9, 8])], ',', true, 'M/a,M/b\n1.0,9.0\n2.0,8.0\n3.0,\n'),
    ('header names containing the delimiter are quoted', [ch('a,b', 'v', [1])], ',', true, '"a,b/v"\n1.0\n'),
    ('custom delimiter, header omitted', [ch('M', 'v', [1, 2])], ';', false, '1.0\n2.0\n'),
    ('channels from different groups share the table',
        [ch('G1', 'a', [1]), ch('G2', 'b', [2])], ',', true, 'G1/a,G2/b\n1.0,2.0\n'),
    ('no numeric channels yields an empty string', [ch('M', 'note', [], props: {'value': 'hi'})], ',', true, ''),
  ];
  // dart format on
  for (final (name, channels, delimiter, header, want) in toCsv) {
    test('tdmsToCsv: $name', () {
      expect(tdmsToCsv(write(channels), delimiter: delimiter, header: header), want);
    });
  }

  test('tdmsToCsv(csvToTdms) round-trips values with the group in the header', () {
    final lines = tdmsToCsv(csvToTdms('x,y\n1.5,2.5\n3.5,4.5\n', group: 'G')).trim().split('\n');
    expect(lines, ['G/x,G/y', '1.5,2.5', '3.5,4.5']);
  });

  test('csv -> tdms -> csv -> tdms is numerically stable', () {
    const csv = 'x,y,z\n1.5,2.5,3.5\n4.5,5.5,6.5\n7.5,8.5,9.5\n';
    List<List<double>> cols(String c) => channelsOf(TdmsReader.read(csvToTdms(c))).values.toList();
    final first = cols(csv);
    // dart format off
    expect(first, [[1.5, 4.5, 7.5], [2.5, 5.5, 8.5], [3.5, 6.5, 9.5]]);
    // dart format on
    expect(cols(tdmsToCsv(csvToTdms(csv))), first);
  });

  test('fuzz: csvToTdms tolerates arbitrary junk and emits readable TDMS', () {
    final rng = Random(99);
    const chars = [',', '\n', '\r', '"', ';', ' ', '\t', '1', '2', '.', '-', 'a', 'Z', 'é', '∑', '0'];
    String junk() => [for (var i = 0, n = rng.nextInt(60); i < n; i++) chars[rng.nextInt(chars.length)]].join();
    for (var i = 0; i < 3000; i++) {
      final s = junk();
      expect(() => TdmsReader.read(csvToTdms(s)), returnsNormally, reason: 'from: ${s.codeUnits}');
    }
    for (final s in ['', '"', '""', '\n', '\r\n', ',', ',,,', '"unterminated', 'a\n"x""y"']) {
      expect(() => TdmsReader.read(csvToTdms(s)), returnsNormally, reason: 'corner case: ${s.codeUnits}');
    }
    for (var i = 0; i < 500; i++) {
      expect(() => TdmsReader.read(csvToTdms(junk(), delimiter: ';')), returnsNormally);
    }
  });
}
