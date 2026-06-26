# labwright_nidaqmx

Cross-platform, **pure-Dart** access to NI's own **NI-DAQmx** driver behind a single
API. Where NI supports the platform it calls NI-DAQmx directly over FFI (no reverse
engineering); where NI does not (macOS), it talks to an NI gRPC Device Server over the
network. No method channels, no native glue you have to build — just Dart.

Program against one interface — `DaqmxApi` — and obtain it from the `Daqmx` factory.
The factory picks the transport; your code never changes:

```dart
import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';

// Pick the transport for your platform/deployment — the rest is identical:
final daq = Daqmx.local();                       // Windows/Linux: in-process FFI
// final daq = Daqmx.remote(host: '192.168.1.50'); // any client (required on macOS)

print(await daq.deviceNames());                 // e.g. [cDAQ1, cDAQ1Mod1]
print(await daq.readVoltage('cDAQ1Mod1/ai0'));  // one AI sample
await daq.writeVoltage('cDAQ1Mod2/ao0', 2.5);
await daq.close();
```

## One API, two implementations

| Transport | `Daqmx` entry point | How it works | Platforms |
|-----------|---------------------|--------------|-----------|
| **FFI** (local) | `Daqmx.local()` | Pure `dart:ffi` into `nicaiu.dll` / `libnidaqmx.so` | Windows, Linux¹ |
| **gRPC** (remote) | `Daqmx.remote(host:)` | Pure-Dart `package:grpc` client for the [NI gRPC Device Server](https://github.com/ni/grpc-device) | All platforms; **required on macOS** |

¹ NI flags incompatibility with default IOMMU settings on Linux kernel 6.8+; see NI's
compatibility docs.

**macOS has no local path.** NI ships no modern NI-DAQmx for macOS (only the dead
NI-DAQmx *Base*, ≤ macOS 10.14, Intel-only). So `Daqmx.local()` throws
`UnsupportedError` on macOS, directing you to run the NI gRPC Device Server on a
Windows/Linux host and connect with `Daqmx.remote(...)`. Windows/Linux *may* host the
server too, but there's no need — `local()` calls the driver directly under the hood.

The transport is the only thing that differs. `DaqmxApi`, `DaqmxException`
(NI's status + extended error text) and `DaqmxUnavailable` (transport unreachable)
are shared, so callers handle both backends identically.

### Securing the gRPC transport

`Daqmx.remote()` defaults to an **insecure (cleartext)** channel — fine on a trusted,
isolated lab segment, but anyone on-path can read or inject DAQ commands, so the
backend logs a warning when it connects insecurely. This transport controls physical
hardware: secure it for anything else.

- `Daqmx.remote(host: ..., secure: true)` — TLS validated against system root CAs.
- `Daqmx.remote(host: ..., credentials: ...)` — supply a `ChannelCredentials` for a
  self-signed / private CA or client certificate (mTLS), which is the usual NI setup.
- `callTimeout:` (default 30 s) bounds every RPC so a hung server can't hang you.

## Logging

The package uses [`package:logging`](https://pub.dev/packages/logging) and emits on a
small set of namespaced loggers, all defined in one place —
[`lib/src/logging.dart`](lib/src/logging.dart), class `DaqLoggers`:

| Logger | Name | Covers |
|--------|------|--------|
| `DaqLoggers.root` | `labwright.nidaqmx` | the whole package |
| `DaqLoggers.ffi`  | `labwright.nidaqmx.ffi` | local runtime load + DAQmx call status |
| `DaqLoggers.grpc` | `labwright.nidaqmx.grpc` | channel connect/shutdown + RPC lifecycle |
| `DaqLoggers.task` | `labwright.nidaqmx.task` | task create/clear (both backends) |
| `DaqLoggers.io`   | `labwright.nidaqmx.io` | analog read/write values |

The library only *emits*; it never installs a handler or sets a level (a library that
prints uninvited fights its host). Wiring output is two global flags in your `main()`:

```dart
import 'package:logging/logging.dart';

void main() {
  Logger.root.level = Level.ALL;                  // 1. global verbosity
  Logger.root.onRecord.listen((r) =>              // 2. global sink
      print('${r.level.name} ${r.loggerName}: ${r.message}'));

  // ... run your app; labwright_nidaqmx logs flow through automatically.
}
```

Want just one area? Keep the global sink from the setup above, flip on hierarchical
levels, and dial a single logger (set `Logger.root.level` no stricter than the level
you want to see):

```dart
hierarchicalLoggingEnabled = true;               // global flag
DaqLoggers.grpc.level = Level.FINE;              // gRPC chatter only
```

## Streaming

Scalar `readVoltage` is one sample per call. For real acquisition use `readStream` —
buffered, hardware-clocked, set the **sample rate from Dart**:

```dart
final daq = Daqmx.local();

// Raw 16-bit codes (the practical high-speed format) at 50 kS/s, in 1000-sample
// chunks, until you stop:
final sub = daq.readRawI16Stream('cDAQ1Mod1/ai0', rateHz: 50000, samplesPerChunk: 1000)
    .listen((Int16List chunk) => process(chunk));
// ... later:
await sub.cancel();   // stops + clears the task

// Or a finite capture that completes on its own:
await for (final Float64List chunk
    in daq.readVoltageStream('cDAQ1Mod1/ai0', rateHz: 1000, totalSamples: 10000)) {
  process(chunk);
}
```

**Format = throughput.** `volts` (f64) is pre-scaled and convenient but 8 bytes/sample;
the raw integer formats move the device's native ADC codes with no per-sample scaling —
`rawI16` is half the bytes (the usual choice for sustained high speed), `rawI32` for
24-/32-bit devices and counters, plus `rawU16`/`rawU32`. The core `readStream(...,
format: DaqSampleFormat.rawI16)` yields the matching typed list; `readVoltageStream` /
`readRawI16Stream` / `readRawI32Stream` are typed convenience wrappers.

**The FFI backend runs the blocking read loop on a dedicated isolate**, so streaming
never stalls your event loop; the Dart stream's pause/resume/cancel drive the worker
(and tear the task down on cancel). **gRPC streaming is not implemented** — doing it at
rate needs NI's data-moniker / sideband RPCs; for now high-speed streaming is the local
FFI path (`Daqmx.local()`), and `GrpcDaqmxBackend.readStream` throws `UnsupportedError`.
For *very* high rates, the read loop itself should move fully native (a future step).

### Recording to TDMS

`recordStreamToTdms` writes a stream straight into NI's TDMS format (one segment per
chunk), storing raw formats as their compact `TdsType` (i16 stays i16 on disk):

```dart
final bytes = await recordStreamToTdms(
  daq.readRawI16Stream('cDAQ1Mod1/ai0', rateHz: 50000, totalSamples: 1000000),
  format: DaqSampleFormat.rawI16, group: 'AI', channel: 'ai0', rateHz: 50000,
);
await File('capture.tdms').writeAsBytes(bytes); // opens as a waveform in DIAdem/LabVIEW
```

## Status

| Piece | State |
|-------|-------|
| Unified `DaqmxApi` + `Daqmx` factory + transport gating | done, analyze-clean, unit-tested |
| **gRPC backend** (`GrpcDaqmxBackend`) | scalar I/O implemented over `package:grpc`; covered end-to-end against an in-process fake NI server (deviceNames, read/write session model, error mapping, transport/deadline). Streaming: not implemented (moniker path). |
| **FFI backend** (`FfiDaqmxBackend`) — scalar AI/AO + buffered streaming | implemented; the full ABI (scalar + all stream formats + the isolate read-loop + error path + sample-rate config) is exercised through a compiled C shim, so it's ~ready for a real DLL — but **not yet run against a live NI-DAQmx runtime** |
| **Streaming** (`readStream` + typed wrappers) + **TDMS** (`recordStreamToTdms`) | implemented on the FFI backend (isolate); round-trips into TDMS in tests |

**Honesty:** the gRPC wire path is exercised against a *fake* server, and the FFI path
against a *C shim* — both speak the real ABI/protocol but are not NI's actual
server/driver + hardware. The signatures are transcribed from NI's published C
reference and `dart analyze` is clean, but nothing here has been run against a live
NI-DAQmx runtime (this dev box is WSL2, where NI-DAQmx's kernel modules don't build).
The shim gets the FFI surface ~90% of the way to a real DLL; validate on real hardware
(or NI-DAQmx *simulated devices*) before relying on it in production.

## gRPC wire definitions

The gRPC stubs are generated from **scoped, wire-compatible subsets** of NI's
MIT-licensed protos (see [`proto/PROVENANCE.md`](proto/PROVENANCE.md) for sources,
commits, and license). Only the analog-I/O + task-lifecycle + error-string RPC subset
is vendored; package/service/method/message/field-numbers match NI's exactly, so the
client is **designed to** interoperate with a real server — though that has only been
exercised against the in-process fake so far (see Status). Regenerate after editing
the protos:

```sh
dart pub global activate protoc_plugin   # provides protoc-gen-dart
# plus protoc on PATH
bash tool/gen_proto.sh                    # -> lib/src/generated/ (committed)
```

The generated `lib/src/generated/` is committed so the package builds and tests run
without protoc.

## Next steps

- Validate both backends against real hardware (a live NI gRPC Device Server + an
  actual NI-DAQmx runtime).
- Widen the API: buffered / continuous acquisition (`DAQmxReadAnalogF64`), digital
  I/O, counters — vendoring the matching RPCs into the proto subset as needed.
- A `DaqDevice` adapter so `labwright_daq`'s HAL can drive either transport.

## Clean-room note

This package **wraps** NI's driver through its **public C API** (FFI) and NI's own
**open-source gRPC server** — normal, supported interop. It does not reimplement or
copy NI driver code. The clean-room rule applies to the separate, frozen `qdaq` effort
(reverse-engineering the device protocol), which is deferred.
