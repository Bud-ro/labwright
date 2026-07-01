import 'dart:typed_data';

import 'tdms.dart';

/// A machine-readable (JSON-encodable) summary of a TDMS file: root properties
/// and, per group/channel, value counts, min/max/mean for numeric channels, and
/// properties. Timestamps are emitted as ISO-8601 strings so the whole map is
/// `jsonEncode`-safe. Complements the human-readable `inspectTdms`.
Map<String, Object?> tdmsSummary(Uint8List bytes) {
  final file = TdmsReader.read(bytes);
  return {
    'properties': _jsonProps(file.properties),
    'groups': [
      for (final g in file.groups)
        {
          'name': g.name,
          'properties': _jsonProps(g.properties),
          'channels': [
            for (final c in g.channels)
              {
                'name': c.name,
                'count': c.data.length,
                if (c.data.isNotEmpty) ...{
                  'min': _min(c.data),
                  'max': _max(c.data),
                  'mean': _mean(c.data),
                },
                'properties': _jsonProps(c.properties),
              },
          ],
        },
    ],
  };
}

Map<String, Object?> _jsonProps(Map<String, Object> props) => {
      for (final MapEntry(:key, :value) in props.entries)
        key: value is DateTime ? value.toIso8601String() : value,
    };

double _min(List<double> d) => d.reduce((m, v) => v < m ? v : m);

double _max(List<double> d) => d.reduce((m, v) => v > m ? v : m);

double _mean(List<double> d) => d.fold(0.0, (s, v) => s + v) / d.length;
