# labwright_nidaqmx

Cross-platform, **pure-Dart** access to NI's own **NI-DAQmx** driver behind a single
API. Where NI supports the platform it calls NI-DAQmx directly over FFI (no reverse
engineering); where NI does not (macOS), it talks to an NI gRPC Device Server over the
network. No method channels, no native glue you have to build — just Dart.

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
| **FFI** (local) | `Daqmx.local()` | Pure `dart:ffi` into `nicaiu.dll` / `libnidaqmx.so` | Windows, Linux¹ |
| **gRPC** (remote) | `Daqmx.remote(host:)` | Pure-Dart `package:grpc` client for the [NI gRPC Device Server](https://github.com/ni/grpc-device) | All platforms; **required on macOS** |

¹ NI flags incompatibility with default IOMMU settings on Linux kernel 6.8+; see NI's
compatibility docs.

**macOS has no local path.** NI ships no modern NI-DAQmx for macOS (only the dead
NI-DAQmx *Base*, ≤ macOS 10.14, Intel-only). So `Daqmx.local()` throws
`UnimplementedError` on macOS, directing you to run the NI gRPC Device Server on a
Windows/Linux host and connect with `Daqmx.remote(...)`. Windows/Linux *may* host the
server too, but there's no need — `local()` calls the driver directly under the hood.

The transport is the only thing that differs. `DaqmxApi`, `DaqmxException`
(NI's status + extended error text) and `DaqmxUnavailable` (transport unreachable)
are shared, so callers handle both backends identically.

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

Want just one area? Flip on hierarchical levels and dial a single logger:

```dart
hierarchicalLoggingEnabled = true;               // global flag
DaqLoggers.grpc.level = Level.FINE;              // gRPC chatter only
```

## Status

| Piece | State |
|-------|-------|
| Unified `DaqmxApi` + `Daqmx` factory + transport gating | done, analyze-clean, unit-tested |
| **gRPC backend** (`GrpcDaqmxBackend`) | implemented over `package:grpc`; covered end-to-end against an in-process fake NI server (deviceNames, read/write session model, error mapping, transport-failure mapping) |
| **FFI backend** (`FfiDaqmxBackend`) — load, deviceNames, AI/AO scalar read/write, error info | code complete; **not yet run against a live NI-DAQmx runtime** |

**Honesty:** the gRPC wire path is exercised against a *fake* server that speaks the
real protocol, not yet against NI's actual server + hardware. The FFI calls are
transcribed from NI's published C reference and `dart analyze` is clean, but they have
**not** been run against a live NI-DAQmx runtime (this dev environment is WSL2, where
NI-DAQmx's kernel modules don't build). Validate both on real hardware before relying
on them in production.

## gRPC wire definitions

The gRPC stubs are generated from **scoped, wire-compatible subsets** of NI's
MIT-licensed protos (see [`proto/PROVENANCE.md`](proto/PROVENANCE.md) for sources,
commits, and license). Only the analog-I/O RPC subset is vendored; package/service/
method/message/field-numbers match NI's exactly, so the client interoperates with a
real server. Regenerate after editing the protos:

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
