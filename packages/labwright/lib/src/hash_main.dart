import 'dart:convert';
import 'dart:isolate';

import 'source_hash.dart';

void main(List<String> args, SendPort port) {
  final hashes = computeSuiteHashes(args.single);
  port.send(jsonEncode({'setupHash': hashes.setupHash, 'sites': hashes.sites}));
}
