// `dart run labwright:hash <entry.dart>` — computes the suite's content
// identity and prints it as JSON: {"setupHash": "...", "sites": {"<abs
// path>:<line>": "<test hash>", ...}}.
//
// This lives in a bin so the ANALYZER never enters the suite's own import
// graph: `dart run <path>` recompiles its whole closure every invocation, and
// dragging the analyzer into every `dart run e2e/main.dart` costs seconds of
// startup per run. A package executable's kernel is cached instead, and the
// runtime library spawns this child lazily, off the bench-critical path.
import 'dart:convert';
import 'dart:io';

import 'package:labwright/src/source_hash.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run labwright:hash <entry.dart>');
    exitCode = 64;
    return;
  }
  final hashes = computeSuiteHashes(args.single);
  stdout.writeln(jsonEncode({'setupHash': hashes.setupHash, 'sites': hashes.sites}));
}
