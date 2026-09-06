import 'dart:typed_data';

import 'reader.dart';

String tdmsToCsv(Uint8List bytes, {String delimiter = ',', bool header = true}) {
  final file = TdmsReader.read(bytes);

  final columns = <({String name, List<double> data})>[
    for (final group in file.groups)
      for (final channel in group.channels)
        if (channel.data.isNotEmpty) (name: '${group.name}/${channel.name}', data: channel.data),
  ];
  if (columns.isEmpty) return '';

  String quoteIfNeeded(String field) {
    if (field.contains(delimiter) || field.contains('"') || field.contains('\n') || field.contains('\r')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  final out = StringBuffer();
  if (header) {
    out.writeln([for (final column in columns) quoteIfNeeded(column.name)].join(delimiter));
  }

  final rowCount = columns.map((column) => column.data.length).reduce((a, b) => a > b ? a : b);
  for (var row = 0; row < rowCount; row++) {
    out.writeln(
      [
        for (final column in columns) row < column.data.length ? '${column.data[row]}' : '',
      ].join(delimiter),
    );
  }
  return out.toString();
}
