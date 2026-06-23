import 'dart:math' as math;

import 'package:labwright_core/labwright_core.dart';

import 'sample.dart';

/// A waveform as a pure function of elapsed time — used to drive simulated
/// inputs (and, later, to script stimulus for DUT fuzzing).
typedef Signal = double Function(Duration elapsed);

/// Common [Signal] generators.
abstract final class Signals {
  /// A flat signal that always reads [value].
  static Signal constant(double value) => (_) => value;

  /// A linear ramp starting at [from], rising [voltsPerSecond].
  static Signal ramp({double from = 0, required double voltsPerSecond}) =>
      (t) => from + voltsPerSecond * (t.inMicroseconds / 1e6);

  /// A sine of [amplitude] at [frequencyHz], centered on [offset].
  static Signal sine({double amplitude = 1, double frequencyHz = 1, double offset = 0}) =>
      (t) => offset + amplitude * math.sin(2 * math.pi * frequencyHz * (t.inMicroseconds / 1e6));
}

/// Single analog input channel.
abstract interface class AnalogInput {
  /// One immediate reading, in volts.
  Future<double> read();

  /// A finite stream of [count] samples at [rateHz]. The simulated backend
  /// produces them with virtual timestamps (no real-time wait); a hardware
  /// backend paces to the device clock.
  Stream<Sample> stream({required double rateHz, required int count});
}

/// Single analog output channel.
abstract interface class AnalogOutput {
  /// Drive the channel to [volts].
  Future<void> write(double volts);
}

/// Digital I/O lines, addressed by index.
abstract interface class DigitalIO {
  /// Read the logic level of [line] (true = high).
  Future<bool> read(int line);

  /// Drive [line] high or low.
  Future<void> write(int line, {required bool high});
}

/// Edge/event counter channel.
abstract interface class Counter {
  /// The current accumulated count.
  Future<int> read();

  /// Zero the count.
  Future<void> reset();
}

/// A DAQ device: a [Peripheral] that vends channels. Concrete devices are the
/// simulated backend (here) and, later, LabJack/NI backends over `native/qdaq`.
abstract class DaqDevice extends Peripheral {
  /// Analog input channel [channel].
  AnalogInput analogIn(int channel);

  /// Analog output channel [channel].
  AnalogOutput analogOut(int channel);

  /// The device's digital I/O lines.
  DigitalIO get digital;

  /// Edge/event counter channel [channel].
  Counter counter(int channel);
}
