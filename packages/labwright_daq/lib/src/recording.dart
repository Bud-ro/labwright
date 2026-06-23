import 'hal.dart';
import 'sample.dart';
import 'trace.dart';

/// Wraps any [DaqDevice] and records every read into [trace] while passing calls
/// through to the real device. Use during a live run, then persist `trace`.
class RecordingDaq extends DaqDevice {
  RecordingDaq(this._inner, {DaqTrace? trace}) : trace = trace ?? DaqTrace();

  final DaqDevice _inner;
  final DaqTrace trace;

  @override
  String get name => _inner.name;

  @override
  Future<void> open() => _inner.open();

  @override
  Future<void> close() => _inner.close();

  @override
  AnalogInput analogIn(int channel) => _RecordingAnalogIn(_inner.analogIn(channel), channel, trace);

  @override
  AnalogOutput analogOut(int channel) => _RecordingAnalogOut(_inner.analogOut(channel), channel, trace);

  @override
  DigitalIO get digital => _RecordingDigital(_inner.digital, trace);

  @override
  Counter counter(int channel) => _RecordingCounter(_inner.counter(channel), channel, trace);
}

class _RecordingAnalogIn implements AnalogInput {
  _RecordingAnalogIn(this._inner, this._channel, this._trace);
  final AnalogInput _inner;
  final int _channel;
  final DaqTrace _trace;

  @override
  Future<double> read() async {
    final v = await _inner.read();
    (_trace.analogReads[_channel] ??= []).add(v);
    return v;
  }

  @override
  Stream<Sample> stream({required double rateHz, required int count}) async* {
    final captured = <Sample>[];
    await for (final s in _inner.stream(rateHz: rateHz, count: count)) {
      captured.add(s);
      yield s;
    }
    (_trace.analogStreams[_channel] ??= []).add(captured);
  }
}

class _RecordingAnalogOut implements AnalogOutput {
  _RecordingAnalogOut(this._inner, this._channel, this._trace);
  final AnalogOutput _inner;
  final int _channel;
  final DaqTrace _trace;

  @override
  Future<void> write(double volts) async {
    await _inner.write(volts);
    _trace.analogWrites.add((channel: _channel, volts: volts));
  }
}

class _RecordingDigital implements DigitalIO {
  _RecordingDigital(this._inner, this._trace);
  final DigitalIO _inner;
  final DaqTrace _trace;

  @override
  Future<bool> read(int line) async {
    final v = await _inner.read(line);
    (_trace.digitalReads[line] ??= []).add(v);
    return v;
  }

  @override
  Future<void> write(int line, {required bool high}) => _inner.write(line, high: high);
}

class _RecordingCounter implements Counter {
  _RecordingCounter(this._inner, this._channel, this._trace);
  final Counter _inner;
  final int _channel;
  final DaqTrace _trace;

  @override
  Future<int> read() async {
    final v = await _inner.read();
    (_trace.counterReads[_channel] ??= []).add(v);
    return v;
  }

  @override
  Future<void> reset() => _inner.reset();
}

/// A [DaqDevice] backed entirely by a recorded [DaqTrace]: reads return the
/// recorded values in order; writes are accepted and ignored. Re-running a test
/// against this reproduces the original acquisition deterministically, with no
/// hardware. Throws if the test asks for a read the trace doesn't have (the test
/// diverged from what was recorded).
class ReplayDaq extends DaqDevice {
  ReplayDaq(this.trace, {this.name = 'replay-daq'});

  @override
  final String name;
  final DaqTrace trace;

  final Map<int, int> _analog = {};
  final Map<int, int> _stream = {};
  final Map<int, int> _digital = {};
  final Map<int, int> _counter = {};

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  AnalogInput analogIn(int channel) => _ReplayAnalogIn(this, channel);

  @override
  AnalogOutput analogOut(int channel) => _ReplayAnalogOut();

  @override
  DigitalIO get digital => _ReplayDigital(this);

  @override
  Counter counter(int channel) => _ReplayCounter(this, channel);

  double _nextAnalog(int ch) {
    final list = trace.analogReads[ch];
    final i = _analog[ch] ?? 0;
    if (list == null || i >= list.length) {
      throw StateError('replay: no recorded analogIn[$ch] read #$i');
    }
    _analog[ch] = i + 1;
    return list[i];
  }

  List<Sample> _nextStream(int ch) {
    final list = trace.analogStreams[ch];
    final i = _stream[ch] ?? 0;
    if (list == null || i >= list.length) {
      throw StateError('replay: no recorded analogIn[$ch] stream #$i');
    }
    _stream[ch] = i + 1;
    return list[i];
  }

  bool _nextDigital(int line) {
    final list = trace.digitalReads[line];
    final i = _digital[line] ?? 0;
    if (list == null || i >= list.length) {
      throw StateError('replay: no recorded digital[$line] read #$i');
    }
    _digital[line] = i + 1;
    return list[i];
  }

  int _nextCounter(int ch) {
    final list = trace.counterReads[ch];
    final i = _counter[ch] ?? 0;
    if (list == null || i >= list.length) {
      throw StateError('replay: no recorded counter[$ch] read #$i');
    }
    _counter[ch] = i + 1;
    return list[i];
  }
}

class _ReplayAnalogIn implements AnalogInput {
  _ReplayAnalogIn(this._daq, this._channel);
  final ReplayDaq _daq;
  final int _channel;

  @override
  Future<double> read() async => _daq._nextAnalog(_channel);

  @override
  Stream<Sample> stream({required double rateHz, required int count}) =>
      Stream.fromIterable(_daq._nextStream(_channel));
}

class _ReplayAnalogOut implements AnalogOutput {
  @override
  Future<void> write(double volts) async {}
}

class _ReplayDigital implements DigitalIO {
  _ReplayDigital(this._daq);
  final ReplayDaq _daq;

  @override
  Future<bool> read(int line) async => _daq._nextDigital(line);

  @override
  Future<void> write(int line, {required bool high}) async {}
}

class _ReplayCounter implements Counter {
  _ReplayCounter(this._daq, this._channel);
  final ReplayDaq _daq;
  final int _channel;

  @override
  Future<int> read() async => _daq._nextCounter(_channel);

  @override
  Future<void> reset() async {}
}
