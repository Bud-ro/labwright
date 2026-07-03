# Changelog

## 0.1.0

First release candidate: cross-platform, pure-Dart access to NI's NI-DAQmx behind one
API. Public surface is considered frozen for the 1.0 line.

### Added
- Unified `DaqmxApi` with a `Daqmx` factory choosing the transport: `Daqmx.local()`
  (in-process FFI, Windows/Linux) and `Daqmx.remote()` (gRPC, all platforms; required
  on macOS, where `Daqmx.local()` throws `UnsupportedError`).
- **FFI backend** — device enumeration, scalar AI/AO (`readVoltage`/`writeVoltage`),
  and buffered streaming (`readStream` + typed wrappers) on a dedicated isolate with
  DMA input-buffer headroom for continuous high-rate acquisition.
- **gRPC backend** — scalar I/O plus **data-moniker streaming** (in-band
  `DataMoniker.StreamRead`), per-RPC deadlines, TLS/mTLS via `credentials`, and a
  `SidebandStrategy` selector (`inBandGrpc` implemented; `sockets`/`sharedMemory`/`rdma`
  negotiated but pending native support).
- **Streaming formats** — `volts` (f64) plus raw `i16`/`i32`/`u16`/`u32` ADC codes.
- **TDMS recording** — `recordStreamToTdms` writes a stream to NI's TDMS format,
  storing raw formats as their compact `TdsType`.
- **Logging** — `package:logging` via the `DaqLoggers` namespace class.
- Shared `DaqmxException` (status + NI extended error text) and `DaqmxUnavailable`.
- Wire-compatible vendored NI protos (MIT; see `proto/PROVENANCE.md`) with reproducible
  codegen (`tool/gen_proto.sh`, `protoc_plugin` pinned).

### Testing
- FFI path validated against a compiled C shim exercising the real `dart:ffi` ABI;
  gRPC + moniker streaming validated against an in-process fake NI gRPC server.
- Hardware-gated integration + parity suites (`test/integration/`, tag `hardware`)
  self-skip unless `DAQMX_AI_CHANNEL` / `NI_GRPC_HOST` are set.

### Not yet validated
- Neither backend has been run against a live NI-DAQmx runtime or NI gRPC Device
  Server. Run the `hardware` suites on an NI box (incl. NI MAX simulated devices)
  before depending on this in production. See README "Validating against real hardware".

### Out of scope (post-1.0)
- Sideband sockets/RDMA transports, a fully-native read pump, digital I/O, counters,
  buffered AO waveform generation, and a `labwright_daq` HAL adapter.
