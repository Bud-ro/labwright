import 'hal.dart';
import 'sample.dart';

/// A fully in-memory [DaqDevice] for hardware-free tests, CI, and replay.
///
/// Analog inputs are driven by [Signal]s (constant by default), analog outputs
/// and digital writes are captured for assertions, and counters are plain
/// settable values. Same interface as a real backend, so a test written against
/// this runs unchanged against hardware.
class SimulatedDaq extends DaqDevice {
  SimulatedDaq({this.name = 'sim-daq', Map<int, Signal>? analogInputs})
      : _signals = {...?analogInputs};

  @override
  final String name;

  final Map<int, Signal> _signals;

  /// Last value written to each analog output channel.
  final Map<int, double> writtenAnalog = {};

  /// Full, ordered history of analog output writes (for stimulus assertions).
  final List<({int channel, double volts})> analogWrites = [];

  /// Current digital line states.
  final Map<int, bool> digitalLines = {};

  /// Current counter values.
  final Map<int, int> counters = {};

  bool _open = false;
  bool get isOpen => _open;

  @override
  Future<void> open() async => _open = true;

  @override
  Future<void> close() async => _open = false;

  /// Set or replace the signal feeding analog input [channel].
  void setInput(int channel, Signal signal) => _signals[channel] = signal;

  @override
  AnalogInput analogIn(int channel) => _SimAnalogIn(this, channel);

  @override
  AnalogOutput analogOut(int channel) => _SimAnalogOut(this, channel);

  @override
  DigitalIO get digital => _SimDigital(this);

  @override
  Counter counter(int channel) => _SimCounter(this, channel);

  double _sampleAt(int channel, Duration t) {
    final signal = _signals[channel];
    return signal == null ? 0.0 : signal(t);
  }
}

class _SimAnalogIn implements AnalogInput {
  _SimAnalogIn(this._daq, this._channel);
  final SimulatedDaq _daq;
  final int _channel;

  @override
  Future<double> read() async => _daq._sampleAt(_channel, Duration.zero);

  @override
  Stream<Sample> stream({required double rateHz, required int count}) async* {
    final periodUs = (1e6 / rateHz).round();
    for (var i = 0; i < count; i++) {
      final t = Duration(microseconds: periodUs * i);
      yield Sample(elapsed: t, value: _daq._sampleAt(_channel, t));
    }
  }
}

class _SimAnalogOut implements AnalogOutput {
  _SimAnalogOut(this._daq, this._channel);
  final SimulatedDaq _daq;
  final int _channel;

  @override
  Future<void> write(double volts) async {
    _daq.writtenAnalog[_channel] = volts;
    _daq.analogWrites.add((channel: _channel, volts: volts));
  }
}

class _SimDigital implements DigitalIO {
  _SimDigital(this._daq);
  final SimulatedDaq _daq;

  @override
  Future<bool> read(int line) async => _daq.digitalLines[line] ?? false;

  @override
  Future<void> write(int line, {required bool high}) async => _daq.digitalLines[line] = high;
}

class _SimCounter implements Counter {
  _SimCounter(this._daq, this._channel);
  final SimulatedDaq _daq;
  final int _channel;

  @override
  Future<int> read() async => _daq.counters[_channel] ?? 0;

  @override
  Future<void> reset() async => _daq.counters[_channel] = 0;
}
