import 'sample.dart';

/// An ordered log of every device read (and output write) captured during a run.
///
/// Serializable, so a real acquisition can be saved and later replayed through
/// [ReplayDaq] for deterministic, hardware-free debugging and regression. Reads
/// are keyed per channel; replay assumes the test issues the same per-channel
/// call sequence (deterministic test logic).
class DaqTrace {
  DaqTrace({
    Map<int, List<double>>? analogReads,
    Map<int, List<List<Sample>>>? analogStreams,
    Map<int, List<bool>>? digitalReads,
    Map<int, List<int>>? counterReads,
    List<({int channel, double volts})>? analogWrites,
  })  : analogReads = analogReads ?? {},
        analogStreams = analogStreams ?? {},
        digitalReads = digitalReads ?? {},
        counterReads = counterReads ?? {},
        analogWrites = analogWrites ?? [];

  final Map<int, List<double>> analogReads;
  final Map<int, List<List<Sample>>> analogStreams;
  final Map<int, List<bool>> digitalReads;
  final Map<int, List<int>> counterReads;

  /// Recorded for inspection (not needed to replay reads).
  final List<({int channel, double volts})> analogWrites;

  Map<String, Object?> toJson() => {
        'analogReads': {for (final e in analogReads.entries) '${e.key}': e.value},
        'analogStreams': {
          for (final e in analogStreams.entries)
            '${e.key}': [
              for (final s in e.value) [for (final x in s) x.toJson()],
            ],
        },
        'digitalReads': {for (final e in digitalReads.entries) '${e.key}': e.value},
        'counterReads': {for (final e in counterReads.entries) '${e.key}': e.value},
        'analogWrites': [
          for (final w in analogWrites) {'channel': w.channel, 'volts': w.volts},
        ],
      };

  factory DaqTrace.fromJson(Map<String, Object?> json) {
    Map<int, List<T>> perChannel<T>(Object? raw, T Function(Object?) convert) {
      final out = <int, List<T>>{};
      (raw as Map?)?.forEach((k, v) {
        out[int.parse(k as String)] = [for (final x in v as List) convert(x)];
      });
      return out;
    }

    final streams = <int, List<List<Sample>>>{};
    (json['analogStreams'] as Map?)?.forEach((k, v) {
      streams[int.parse(k as String)] = [
        for (final s in v as List)
          [for (final x in s as List) Sample.fromJson((x as Map).cast<String, Object?>())],
      ];
    });

    return DaqTrace(
      analogReads: perChannel<double>(json['analogReads'], (x) => (x! as num).toDouble()),
      analogStreams: streams,
      digitalReads: perChannel<bool>(json['digitalReads'], (x) => x! as bool),
      counterReads: perChannel<int>(json['counterReads'], (x) => (x! as num).toInt()),
      analogWrites: [
        for (final w in json['analogWrites'] as List? ?? const [])
          (channel: ((w as Map)['channel']! as num).toInt(), volts: (w['volts']! as num).toDouble()),
      ],
    );
  }
}
