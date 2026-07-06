// `dart run labwright:hash <entry.dart>` — computes the suite's content
// identity and prints it as JSON: {"setupHash": "...", "sites": {"<abs
// path>:<line>": "<test hash>", ...}}.
//
// For EXTERNAL tooling (skip-unmodified systems comparing reports without
// running a suite). The runtime itself computes the same identity via an
// isolate (src/hash_main.dart) so the analyzer never enters the suite's
// import graph and no `dart run` child is nested under `dart run`.
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
