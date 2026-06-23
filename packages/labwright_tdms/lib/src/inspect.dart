import 'dart:typed_data';

import 'tdms.dart';

/// Renders a human-readable summary of a TDMS file: root properties, then each
/// group and channel with value counts, min/max/mean for numeric channels, a
/// short value preview, and channel properties. Pure (no I/O) so it is testable
/// and web-safe; the `bin/inspect.dart` CLI wraps it for files.
String inspectTdms(Uint8List bytes, {int preview = 5}) {
  final file = TdmsReader.read(bytes);
  final out = StringBuffer()..writeln('TDMS file');

  if (file.properties.isNotEmpty) {
    out.writeln('  properties:');
    for (final e in file.properties.entries) {
      out.writeln('    ${e.key} = ${e.value}');
    }
  }

  for (final g in file.groups) {
    out.writeln('  group "${g.name}"${_props(g.properties)}');
    for (final c in g.channels) {
      if (c.data.isEmpty) {
        out.writeln('    channel "${c.name}": 0 values${_props(c.properties)}');
        continue;
      }
      final s = _stats(c.data);
      out.writeln('    channel "${c.name}": ${c.data.length} values  '
          'min=${_fmt(s.min)} max=${_fmt(s.max)} mean=${_fmt(s.mean)}${_props(c.properties)}');
      final head = c.data.take(preview).map(_fmt).join(', ');
      out.writeln('        [$head${c.data.length > preview ? ', ...' : ''}]');
    }
  }

  return out.toString();
}

String _props(Map<String, Object> p) =>
    p.isEmpty ? '' : '  (${p.entries.map((e) => '${e.key}=${e.value}').join(', ')})';

String _fmt(double v) => v.toStringAsPrecision(6);

({double min, double max, double mean}) _stats(List<double> data) {
  var min = data.first;
  var max = data.first;
  var sum = 0.0;
  for (final v in data) {
    if (v < min) min = v;
    if (v > max) max = v;
    sum += v;
  }
  return (min: min, max: max, mean: sum / data.length);
}
