// The single source of truth for this package's `package:logging` namespaces.
//
// Every logger hangs off the `labwright.nidaqmx` root, so an app can configure the
// whole package with two global flags in `main()` (see README "Logging"):
//
//   Logger.root.level = Level.ALL;                 // global verbosity
//   Logger.root.onRecord.listen(print);            // global sink
//
// or, with `hierarchicalLoggingEnabled = true`, dial in one area
// (e.g. `DaqLoggers.grpc.level = Level.FINE`) while the rest stay quiet.
//
// The package only *emits* on these loggers; it never installs a handler or sets a
// level. Wiring output is the application's choice — a library that prints uninvited
// is a library that fights its host.

import 'package:logging/logging.dart';

/// Namespaced loggers for `labwright_nidaqmx`. All descend from [root], so
/// `Logger.root.level` / `Logger.root.onRecord` govern them collectively.
abstract final class DaqLoggers {
  /// Root logger for the whole package (`labwright.nidaqmx`).
  static final Logger root = Logger('labwright.nidaqmx');

  /// Local FFI backend: library loading, task lifecycle, DAQmx call status.
  static final Logger ffi = Logger('labwright.nidaqmx.ffi');

  /// Remote gRPC backend: channel connect/shutdown and RPC lifecycle.
  static final Logger grpc = Logger('labwright.nidaqmx.grpc');

  /// DAQmx task lifecycle shared across backends (create / clear).
  static final Logger task = Logger('labwright.nidaqmx.task');

  /// Measurement I/O: analog read/write operations and their values.
  static final Logger io = Logger('labwright.nidaqmx.io');
}
