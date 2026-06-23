/// One acquired data point from an analog input stream.
class Sample {
  const Sample({required this.elapsed, required this.value});

  factory Sample.fromJson(Map<String, Object?> json) => Sample(
        elapsed: Duration(microseconds: (json['elapsedUs']! as num).toInt()),
        value: (json['value']! as num).toDouble(),
      );

  /// Time since the stream started (virtual on the simulated backend).
  final Duration elapsed;

  /// The measured value, in the channel's engineering units (volts by default).
  final double value;

  Map<String, Object?> toJson() => {
        'elapsedUs': elapsed.inMicroseconds,
        'value': value,
      };

  @override
  String toString() => 'Sample(${elapsed.inMicroseconds}us, $value)';
}
