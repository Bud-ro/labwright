import 'dart:typed_data';

import 'tdms.dart';

/// Converts the numeric channels of a TDMS file to CSV: one column per channel
/// (header `group/channel`), one row per sample index, shorter channels padded
/// with empty cells. Non-numeric (empty-data) channels are omitted. Header names
/// are RFC-4180 quoted when they contain the delimiter, a quote, or a newline.
String tdmsToCsv(Uint8List bytes, {String delimiter = ',', bool header = true}) {
  final file = TdmsReader.read(bytes);

  final columns = <({String name, List<double> data})>[];
  for (final g in file.groups) {
    for (final c in g.channels) {
      if (c.data.isNotEmpty) columns.add((name: '${g.name}/${c.name}', data: c.data));
    }
  }
  if (columns.isEmpty) return '';

  String esc(String s) {
    if (s.contains(delimiter) || s.contains('"') || s.contains('\n') || s.contains('\r')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  final out = StringBuffer();
  if (header) out.writeln([for (final c in columns) esc(c.name)].join(delimiter));

  var rows = 0;
  for (final c in columns) {
    if (c.data.length > rows) rows = c.data.length;
  }
  for (var i = 0; i < rows; i++) {
    out.writeln([for (final c in columns) i < c.data.length ? '${c.data[i]}' : ''].join(delimiter));
  }
  return out.toString();
}
