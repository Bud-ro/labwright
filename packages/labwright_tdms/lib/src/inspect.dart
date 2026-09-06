import 'dart:typed_data';

import 'reader.dart';

String inspectTdms(Uint8List bytes, {int preview = 5}) {
  final file = TdmsReader.read(bytes);
  final out = StringBuffer()..writeln('TDMS file');

  if (file.properties.isNotEmpty) {
    out.writeln('  properties:');
    for (final property in file.properties.entries) {
      out.writeln('    ${property.key} = ${property.value}');
    }
  }

  for (final group in file.groups) {
    out.writeln('  group "${group.name}"${_props(group.properties)}');
    for (final channel in group.channels) {
      if (channel.data.isEmpty) {
        out.writeln('    channel "${channel.name}": 0 values${_props(channel.properties)}');
        continue;
      }
      final stats = _stats(channel.data);
      out.writeln(
        '    channel "${channel.name}": ${channel.data.length} values  '
        'min=${_fmt(stats.min)} max=${_fmt(stats.max)} mean=${_fmt(stats.mean)}'
        '${_props(channel.properties)}',
      );
      final head = channel.data.take(preview).map(_fmt).join(', ');
      out.writeln('        [$head${channel.data.length > preview ? ', ...' : ''}]');
    }
  }

  return out.toString();
}

String _props(Map<String, Object> properties) =>
    properties.isEmpty ? '' : '  (${properties.entries.map((e) => '${e.key}=${e.value}').join(', ')})';

String _fmt(double value) => value.toStringAsPrecision(6);

({double min, double max, double mean}) _stats(List<double> data) {
  var min = data.first;
  var max = data.first;
  var sum = 0.0;
  for (final value in data) {
    if (value < min) min = value;
    if (value > max) max = value;
    sum += value;
  }
  return (min: min, max: max, mean: sum / data.length);
}
