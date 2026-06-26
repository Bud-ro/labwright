/// Cross-platform, pure-Dart access to NI's **NI-DAQmx** driver behind one API.
///
/// Program against [DaqmxApi]; obtain one from the `Daqmx` factory and the transport
/// is chosen for you:
///
///   - `Daqmx.local()`  — in-process **FFI** into NI-DAQmx (Windows/Linux). Pure
///                        `dart:ffi`; no method channels, no helper process. Throws
///                        [UnsupportedError] on macOS (no NI macOS runtime).
///   - `Daqmx.remote()` — pure-Dart **gRPC** client for the NI gRPC Device Server,
///                        for any platform and required on macOS.
///
/// Same API, two implementations. See README.md for the platform matrix, the gRPC
/// codegen plan, and validation status.
library;

export 'src/daqmx.dart' show Daqmx;
export 'src/daqmx_api.dart';
export 'src/daqmx_constants.dart';
export 'src/ffi.dart' show NidaqmxBindings, TaskHandle;
export 'src/ffi_backend.dart' show FfiDaqmxBackend;
export 'src/grpc_backend.dart' show GrpcDaqmxBackend;
export 'src/logging.dart' show DaqLoggers;
export 'src/streaming.dart' show DaqSampleFormat, DaqmxStreams, SidebandStrategy;
export 'src/tdms_sink.dart' show recordStreamToTdms, tdsTypeFor;
