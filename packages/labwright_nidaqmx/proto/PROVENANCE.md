# Proto provenance

The `.proto` files in this directory are **scoped, wire-compatible subsets**
transcribed from National Instruments' open-source gRPC interface definitions. They
are not the full upstream files — only the messages, enums, services, and RPCs that
`labwright_nidaqmx`'s gRPC backend uses are included. Package names, service names,
method names, message names, and field **numbers** are preserved exactly, so the
generated Dart client is wire-compatible with a real NI gRPC Device Server.

## Upstream sources

| This file | Transcribed from | Repo | Commit (at time of vendoring) |
|-----------|------------------|------|-------------------------------|
| `nidaqmx.proto` | `generated/nidaqmx/nidaqmx.proto` (service `NiDAQmx`, analog-I/O RPC subset) | [ni/grpc-device](https://github.com/ni/grpc-device) | `809c6e5efa7955df00690779614d6d712f0eca77` |
| `session.proto` | `source/protobuf/session_utilities.proto` (`SessionUtilities.EnumerateDevices`) | [ni/grpc-device](https://github.com/ni/grpc-device) | `809c6e5efa7955df00690779614d6d712f0eca77` |
| `session.proto` | `ni/grpcdevice/v1/session.proto` (`Session`, `SessionInitializationBehavior`) | [ni/ni-apis](https://github.com/ni/ni-apis) | `28d8249ecd0580f5d0568c11b87af8cd926f9a7e` |

Upstream `nidaqmx.proto` defines 451 RPCs; this subset includes 9 (task lifecycle,
AI/AO voltage channels, scalar read/write, error-string lookup). The upstream session
+ utilities messages we merged into one `session.proto` (both use package
`nidevice_grpc`) drop fields unused here; per proto3 rules absent fields default and
unknown fields are ignored, so the subset interoperates with the full server.

## License

Both upstream repositories are MIT-licensed:

> Copyright (c) 2022, National Instruments Corp.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in the
> Software without restriction... (full text: the MIT License).

The MIT License permits this use (including modification and redistribution) provided
the copyright notice and permission notice are retained — hence this file. These are
NI's published gRPC **interface** definitions; transcribing them is normal interop,
not reverse engineering.

## Regenerating

To re-vendor or extend the subset, copy the relevant definitions from the upstream
files above (keeping field numbers identical), then run `tool/gen_proto.sh` to
regenerate `lib/src/generated/`.
