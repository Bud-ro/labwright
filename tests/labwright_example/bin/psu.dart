import 'dart:io';

import 'package:labwright_example/labwright_example.dart';
import 'package:labwright_runner/labwright_runner.dart';

/// Run the PSU example and write record.json + record.tdms:
/// `dart run labwright_example:psu --dut PSU-001 --out ./out`
Future<void> main(List<String> args) async {
  exitCode = await runCli(psuTest(demoPsuDaq()), args);
}
