import 'package:labwright_daq/labwright_daq.dart';
import 'package:test/test.dart';

void main() {
  test('a stream of count 0 yields nothing', () async {
    final daq = SimulatedDaq(analogInputs: {0: Signals.constant(1)});
    expect(await daq.analogIn(0).stream(rateHz: 1000, count: 0).toList(), isEmpty);
  });

  test('reading an unconfigured channel returns 0', () async {
    expect(await SimulatedDaq().analogIn(7).read(), 0.0);
  });
}
