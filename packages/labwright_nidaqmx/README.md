# labwright_nidaqmx

Cross-platform, **pure-Dart** access to NI's own **NI-DAQmx** driver behind a single
API. This is the *trusted* DAQ backend: where NI supports the platform it calls
NI-DAQmx directly (no reverse engineering); where NI does not (macOS), it talks to an
NI gRPC Device Server over the network.

Program against one interface — `DaqmxApi` — and obtain it from the `Daqmx` factory.
The factory picks the transport; your code never changes:

```dart
import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';

// Windows/Linux: in-process FFI straight into NI-DAQmx.
final daq = Daqmx.local();

// macOS (or any client): gRPC to a host running the NI gRPC Device Server.
final daq = Daqmx.remote(host: '192.168.1.50');

print(await daq.deviceNames());                 // e.g. [cDAQ1, cDAQ1Mod1]
print(await daq.readVoltage('cDAQ1Mod1/ai0'));  // one AI sample
await daq.writeVoltage('cDAQ1Mod2/ao0', 2.5);
await daq.close();
```

## One API, two implementations

| Transport | `Daqmx` entry point | How it works | Platforms |
|-----------|---------------------|--------------|-----------|
| **FFI** (local) | `Daqmx.local()` | Pure `dart:ffi` into `nicaiu.dll` / `libnidaqmx.so` — no method channels, no helper process | Windows, Linux¹ |
| **gRPC** (remote) | `Daqmx.remote(host:)` | Pure-Dart gRPC client for the [NI gRPC Device Server](https://github.com/ni/grpc-device) | All platforms; **required on macOS** |

¹ NI flags incompatibility with default IOMMU settings on Linux kernel 6.8+; see NI's
compatibility docs.

**macOS has no local path.** NI ships no modern NI-DAQmx for macOS (only the dead
NI-DAQmx *Base*, ≤ macOS 10.14, Intel-only). So `Daqmx.local()` throws
`UnimplementedError` on macOS, directing you to run the NI gRPC Device Server on a
Windows/Linux host and connect with `Daqmx.remote(...)`. Windows/Linux *may* host the
server too, but there's no need — `local()` calls the driver directly under the hood.

The transport is the only thing that differs. `DaqmxApi`, `DaqmxException`
(NI's extended error text + status), and `DaqmxUnavailable` (transport unreachable)
are shared, so callers handle both backends identically.

## Status

| Piece | State |
|-------|-------|
| Unified `DaqmxApi` + `Daqmx` factory + transport gating | done, analyze-clean, unit-tested |
| **FFI backend** (`FfiDaqmxBackend`) — load, deviceNames, AI/AO scalar read/write, error info | code complete; **not yet run against a live NI-DAQmx runtime** |
| **gRPC backend** (`GrpcDaqmxBackend`) — connection params + API conformance | scaffold; data-path methods throw `UnimplementedError` (see below) |

**Honesty:** the FFI calls are transcribed from NI's published C reference and the
package compiles + `dart analyze` is clean, but they have **not** been exercised
against a live NI-DAQmx runtime yet — this dev environment is WSL2, where NI-DAQmx's
kernel modules don't build. Validate on a Windows/Linux box with NI-DAQmx installed.
The gRPC data path is **not implemented** yet — it throws `UnimplementedError` rather
than fake a connection.

## gRPC backend — remaining work

`GrpcDaqmxBackend` carries the connection (`host`, `port` default **31763**, `secure`)
and conforms to `DaqmxApi`, but the wire calls are pending. To finish it:

1. **Vendor the protos.** NI's `grpc-device` repo is MIT-licensed; copy its
   `nidaqmx.proto` and `session.proto` (plus their imports) into `third_party/`.
2. **Generate Dart stubs** with `protoc` + `protoc_gen_dart` (`dart pub global activate
   protoc_plugin`).
3. **Add deps** `grpc` + `protobuf` and implement the methods over a `ClientChannel`,
   following the server's session model (create session → create AI/AO task →
   read/write → clear).
4. **Validate** against a running NI gRPC Device Server (a Windows/Linux host with
   NI-DAQmx + hardware) before claiming it works.

Deferred until it can be validated end-to-end — shipping an unverified gRPC client
would overclaim.

## Next steps

- Implement + validate the gRPC backend (above).
- Validate the FFI backend against a real runtime, then widen the API: buffered /
  continuous acquisition (`DAQmxReadAnalogF64`, binding already present), digital I/O,
  counters.
- A `DaqDevice` adapter so `labwright_daq`'s HAL can drive either transport.

## Clean-room note

This package **wraps** NI's driver through its **public C API** (FFI) and NI's own
**open-source gRPC server** — normal, supported interop. It does not reimplement or
copy NI code. The clean-room rule applies to the separate, frozen `qdaq` effort
(reverse-engineering the device protocol), which is deferred.
