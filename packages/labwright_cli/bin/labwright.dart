import 'dart:io';

import 'package:labwright_cli/labwright_cli.dart';

void main(List<String> args) {
  exitCode = run(args, out: stdout, err: stderr);
}
