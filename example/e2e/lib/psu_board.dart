import 'e2e_test.dart' show Plug;

class PsuBoard implements Plug {
  PsuBoard({this.brownout5v = false});

  final bool brownout5v;

  Future<double> railVoltage(String rail) async {
    await Future<void>.delayed(Duration.zero);
    return switch (rail) {
      '3v3' => 3.31,
      '5v' => brownout5v ? 4.10 : 4.98,
      _ => throw ArgumentError('unknown rail: $rail'),
    };
  }
}
