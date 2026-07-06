/// `Isolate.spawnUri` entry point for the suite hasher: computes the content
/// identity of the suite whose entry script is `args.single` and sends it
/// back as one JSON string:
/// `{"setupHash": ..., "sites": {"<abs path>:<line>": "<test hash>", ...}}`.
///
/// An isolate (not a child `dart run`), deliberately, for two reasons: the
/// analyzer must stay OUT of the runtime library's import graph (a `dart run
/// e2e/main.dart` recompiles its whole closure every invocation — measured at
/// ~3s extra startup), and nesting `dart run` under `dart run` contends the
/// dartdev resident-compiler cache, which exits 255 sporadically on Windows.
/// spawnUri compiles this library's closure lazily, in-process, only when
/// hashing is actually requested — off the bench-critical path.
library;

import 'dart:convert';
import 'dart:isolate';

import 'source_hash.dart';

void main(List<String> args, SendPort port) {
  final hashes = computeSuiteHashes(args.single);
  port.send(jsonEncode({'setupHash': hashes.setupHash, 'sites': hashes.sites}));
}
