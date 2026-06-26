#!/usr/bin/env bash
# Regenerate the Dart gRPC stubs from the vendored protos in proto/.
#
# Prerequisites (pinned — the plugin version dictates the generated ABI, hence the
# `protobuf` constraint floor in pubspec.yaml; bumping it may require bumping that):
#   - protoc on PATH                              (tested with protoc 28.3)
#   - dart pub global activate protoc_plugin 25.0.0   (provides protoc-gen-dart)
#
# The generated output (lib/src/generated/) IS committed so the package builds and
# tests run without protoc. Re-run this only when the protos change.
set -euo pipefail
cd "$(dirname "$0")/.."

out="lib/src/generated"
mkdir -p "$out"

protoc -Iproto --dart_out="grpc:$out" proto/session.proto proto/nidaqmx.proto

echo "Generated Dart stubs -> $out"
