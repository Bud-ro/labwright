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
