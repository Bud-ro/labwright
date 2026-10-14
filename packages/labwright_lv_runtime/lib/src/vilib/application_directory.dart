import 'dart:io';

import '../values.dart';

/// `Application Directory.vi`: the directory the running program was started from.
LvPath lvApplicationDirectory() {
  final directory = File(Platform.resolvedExecutable).parent;
  final segments = Uri.file(directory.path).pathSegments.where((segment) => segment.isNotEmpty).toList();
  return LvPath(components: segments, absolute: true);
}
