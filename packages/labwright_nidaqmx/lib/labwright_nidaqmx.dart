/// Pure-Dart FFI wrapper over NI's own NI-DAQmx driver (Windows/Linux).
///
/// This is the "trusted backend": on platforms NI supports, it calls NI-DAQmx
/// directly rather than reverse-engineering the USB protocol. It is interchangeable
/// (behind the `labwright_daq` HAL) with the clean-room `qdaq` backend, which
/// remains the path for macOS — where NI ships no DAQmx — and for the simulator.
///
/// See README.md for the platform matrix and validation status.
library;

export 'src/nidaqmx.dart';
