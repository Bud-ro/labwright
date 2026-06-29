# Proto provenance

The `.proto` files in this directory are **scoped, wire-compatible subsets**
transcribed from National Instruments' open-source gRPC interface definitions. They
are not the full upstream files — only the messages, enums, services, and RPCs that
`labwright_nidaqmx`'s gRPC backend uses are included. Package names, service names,
method names, message names, and field **numbers** are preserved exactly, so the
generated Dart client is *designed to be* wire-compatible with a real NI gRPC Device
Server. (To date this is verified against an in-process fake that speaks the real
protocol, not yet against NI's actual server — see the package README "Status".)

## Upstream sources

| This file | Transcribed from | Repo | Commit (at time of vendoring) |
|-----------|------------------|------|-------------------------------|
| `nidaqmx.proto` | `generated/nidaqmx/nidaqmx.proto` (service `NiDAQmx`, analog-I/O RPC subset) | [ni/grpc-device](https://github.com/ni/grpc-device) | `809c6e5efa7955df00690779614d6d712f0eca77` |
| `session.proto` | `source/protobuf/session_utilities.proto` (`SessionUtilities.EnumerateDevices`) | [ni/grpc-device](https://github.com/ni/grpc-device) | `809c6e5efa7955df00690779614d6d712f0eca77` |
| `session.proto` | `ni/grpcdevice/v1/session.proto` (`Session`, `SessionInitializationBehavior`) | [ni/ni-apis](https://github.com/ni/ni-apis) | `28d8249ecd0580f5d0568c11b87af8cd926f9a7e` |
| `data_moniker.proto` | `imports/protobuf/data_moniker.proto` (`DataMoniker.StreamRead`/`BeginSidebandStream`, `Moniker`, `MonikerList`, `MonikerValues`, `SidebandStrategy`) | [ni/grpc-device](https://github.com/ni/grpc-device) | `809c6e5efa7955df00690779614d6d712f0eca77` |

Upstream `nidaqmx.proto` defines 451 RPCs; this subset includes 13 (task lifecycle,
AI/AO voltage channels, scalar read/write, error-string lookup, sample-clock timing,
and the `Begin{ReadAnalogF64,ReadBinaryI16,ReadBinaryI32}` moniker-streaming starts).
The upstream session
+ utilities messages we merged into one `session.proto` (both use package
`nidevice_grpc`) drop fields unused here; per proto3 rules absent fields default and
unknown fields are ignored, so the subset interoperates with the full server.

## License

Both upstream repositories are MIT-licensed, © 2022 National Instruments Corp. The
complete license — copyright notice, permission grant, and warranty disclaimer — is
reproduced verbatim alongside these protos in [`NI-LICENSE`](NI-LICENSE), as the MIT
terms require for redistributed/derivative material. The MIT License permits this use
(including modification and redistribution) provided that notice is retained. These
are NI's published gRPC **interface** definitions; transcribing them is normal interop,
not reverse engineering.

## Regenerating

To re-vendor or extend the subset, copy the relevant definitions from the upstream
files above (keeping field numbers identical), then run `tool/gen_proto.sh` to
regenerate `lib/src/generated/`.
