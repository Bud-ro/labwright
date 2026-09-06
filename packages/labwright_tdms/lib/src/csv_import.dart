import 'dart:typed_data';

import 'model.dart';
import 'writer.dart';

Uint8List csvToTdms(String csv, {String group = 'Imported', String delimiter = ','}) {
  final rows = _parseCsv(csv, delimiter);
  if (rows.isEmpty) return (TdmsWriter()..writeSegment(const [])).toBytes();

  final header = rows.first;
  final channels = [
    for (var col = 0; col < header.length; col++)
      TdmsChannel(
        group: group,
        name: header[col],
        data: [
          for (var row = 1; row < rows.length; row++)
            if (col < rows[row].length)
              if (double.tryParse(rows[row][col].trim()) case final value?) value,
        ],
      ),
  ];
  return (TdmsWriter()..writeSegment(channels)).toBytes();
}

const _quote = 0x22;
const _lf = 0x0a;
const _cr = 0x0d;
const _comma = 0x2c;

List<List<String>> _parseCsv(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  final delimiterCode = delimiter.isEmpty ? _comma : delimiter.codeUnitAt(0);

  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final codeUnit = text.codeUnitAt(i);
    if (inQuotes) {
      if (codeUnit == _quote) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == _quote) {
          field.writeCharCode(_quote);
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.writeCharCode(codeUnit);
      }
    } else if (codeUnit == _quote) {
      inQuotes = true;
    } else if (codeUnit == delimiterCode) {
      endField();
    } else if (codeUnit == _lf) {
      endRow();
    } else if (codeUnit != _cr) {
      field.writeCharCode(codeUnit);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
