/// Labwright DAQ hardware-abstraction layer.
///
/// Device-agnostic channel interfaces ([AnalogInput], [AnalogOutput],
/// [DigitalIO], [Counter]) vended by a [DaqDevice], plus a [SimulatedDaq] backend
/// for hardware-free tests. A test written against these runs unchanged against a
/// real backend once one binds to `native/qdaq`.
library;

export 'src/hal.dart';
export 'src/recording.dart';
export 'src/sample.dart';
export 'src/simulated.dart';
export 'src/trace.dart';
