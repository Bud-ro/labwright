import 'package:e2e_test/e2e_test.dart';

/// A simulated power-supply board — stands in for a real bench [Plug] so the
/// example suite runs in CI with no hardware. A real board would implement the
/// same surface over a DAQ/SCPI transport; the test bodies wouldn't change.
class PsuBoard implements Plug {
  PsuBoard({this.brownout5v = false});

  /// When true, the 5 V rail sags out of spec — used to exercise a failing run.
  final bool brownout5v;

  /// Reads a rail's voltage. The `await` stands in for real instrument I/O.
  Future<double> railVoltage(String rail) async {
    await Future<void>.delayed(Duration.zero);
    return switch (rail) {
      '3v3' => 3.31,
      '5v' => brownout5v ? 4.10 : 4.98,
      _ => throw ArgumentError('unknown rail: $rail'),
    };
  }
}
