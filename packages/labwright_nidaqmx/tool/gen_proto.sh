#!/usr/bin/env bash
# Regenerate the Dart gRPC stubs from the vendored protos in proto/.
#
# Prerequisites:
#   - protoc on PATH            (https://github.com/protocolbuffers/protobuf/releases)
#   - dart pub global activate protoc_plugin   (provides protoc-gen-dart on PATH)
#
# The generated output (lib/src/generated/) IS committed so the package builds and
# tests run without protoc. Re-run this only when the protos change.
set -euo pipefail
cd "$(dirname "$0")/.."

out="lib/src/generated"
mkdir -p "$out"

protoc -Iproto --dart_out="grpc:$out" proto/session.proto proto/nidaqmx.proto

echo "Generated Dart stubs -> $out"
