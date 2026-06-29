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
  final channels = <TdmsChannel>[];
  for (var col = 0; col < header.length; col++) {
    final values = <double>[];
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (col >= row.length) continue; // ragged row
      final cell = row[col].trim();
      if (cell.isEmpty) continue; // blank cell
      final v = double.tryParse(cell);
      if (v != null) values.add(v);
    }
    channels.add(TdmsChannel(group: group, name: header[col], data: values));
  }
  return (TdmsWriter()..writeSegment(channels)).toBytes();
}

List<List<String>> _parseCsv(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  final delim = delimiter.isEmpty ? 0x2c : delimiter.codeUnitAt(0);

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
      if (c == 0x22) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x22) {
          field.writeCharCode(0x22);
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.writeCharCode(c);
      }
    } else if (c == 0x22) {
      inQuotes = true;
    } else if (c == delim) {
      endField();
    } else if (c == 0x0a) {
      endRow();
    } else if (c != 0x0d) {
      field.writeCharCode(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
