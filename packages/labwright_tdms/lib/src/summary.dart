import 'dart:typed_data';

import 'reader.dart';

/// A machine-readable (JSON-encodable) summary of a TDMS file: root properties
/// and, per group/channel, value counts, min/max/mean for numeric channels, and
/// properties. Timestamps are emitted as ISO-8601 strings so the whole map is
/// `jsonEncode`-safe. Complements the human-readable `inspectTdms`.
Map<String, Object?> tdmsSummary(Uint8List bytes) {
  final file = TdmsReader.read(bytes);
  return {
    'properties': _jsonProps(file.properties),
    'groups': [
      for (final group in file.groups)
        {
          'name': group.name,
          'properties': _jsonProps(group.properties),
          'channels': [
            for (final channel in group.channels)
              {
                'name': channel.name,
                'count': channel.data.length,
                if (channel.data.isNotEmpty) ...{
                  'min': _min(channel.data),
                  'max': _max(channel.data),
                  'mean': _mean(channel.data),
                },
                'properties': _jsonProps(channel.properties),
              },
          ],
        },
    ],
  };
}

Map<String, Object?> _jsonProps(Map<String, Object> props) => {
  for (final MapEntry(:key, :value) in props.entries) key: value is DateTime ? value.toIso8601String() : value,
};

double _min(List<double> data) => data.reduce((min, v) => v < min ? v : min);

double _max(List<double> data) => data.reduce((max, v) => v > max ? v : max);

double _mean(List<double> data) => data.fold(0.0, (sum, v) => sum + v) / data.length;
