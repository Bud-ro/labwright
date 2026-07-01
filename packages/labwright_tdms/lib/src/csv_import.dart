import 'dart:typed_data';

import 'tdms.dart';

/// Imports CSV into TDMS (the inverse of [tdmsToCsv]). The header row supplies
/// channel names; each column becomes a double channel under [group]. Blank
/// cells and ragged rows are tolerated (skipped); non-numeric cells are ignored.
/// Minimal RFC-4180 quoting (double-quoted fields, `""` escapes a quote).
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
          for (var r = 1; r < rows.length; r++)
            if (col < rows[r].length)
              if (double.tryParse(rows[r][col].trim()) case final v?) v,
        ],
      ),
  ];
  return (TdmsWriter()..writeSegment(channels)).toBytes();
}

const _quote = 0x22; // "
const _lf = 0x0a; // \n
const _cr = 0x0d; // \r
const _comma = 0x2c; // ,

List<List<String>> _parseCsv(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  final delim = delimiter.isEmpty ? _comma : delimiter.codeUnitAt(0);

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
    final c = text.codeUnitAt(i);
    if (inQuotes) {
      if (c == _quote) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == _quote) {
          field.writeCharCode(_quote);
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.writeCharCode(c);
      }
    } else if (c == _quote) {
      inQuotes = true;
    } else if (c == delim) {
      endField();
    } else if (c == _lf) {
      endRow();
    } else if (c != _cr) {
      field.writeCharCode(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
