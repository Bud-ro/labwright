import 'dart:io';
import 'dart:isolate';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

Future<Map<String, ViLegacyIcon>> resolveSubViIconsFor(
  String viPath,
  Set<String> wantedNames, {
  int levelsUp = 4,
}) {
  if (wantedNames.isEmpty) return Future.value(const {});
  final wanted = {...wantedNames};
  return Isolate.run(() => resolveIconsOnDisk(viPath, wanted, levelsUp));
}

Map<String, ViLegacyIcon> resolveIconsOnDisk(
  String viPath,
  Set<String> wanted,
  int levelsUp,
) {
  final out = <String, ViLegacyIcon>{};
  final remaining = {...wanted};
  final callerDir = File(viPath).parent.path;

  List<ViSubViPath> paths;
  try {
    paths = readSubViPaths(File(viPath).readAsBytesSync());
  } catch (_) {
    paths = const [];
  }
  for (final path in paths) {
    final name = path.fileName;
    if (!remaining.contains(name)) continue;
    switch (path.kind) {
      case ViSubViPathKind.relative:
        var dir = callerDir;
        for (var up = 0; up < path.upLevels; up++) {
          dir = Directory(dir).parent.path;
        }
        final icon = decodeViFileIcon('$dir/${path.segments.join('/')}');
        if (icon != null) out[name] = icon;
        remaining.remove(name);
      case ViSubViPathKind.viLib:
        remaining.remove(name);
      case ViSubViPathKind.symbolic:
      case ViSubViPathKind.other:
        break;
    }
  }

  var ring = Directory(callerDir);
  String? searched;
  for (var level = 0; level <= levelsUp && remaining.isNotEmpty; level++) {
    _searchRing(ring.path, searched, remaining, out);
    searched = ring.path;
    final parent = ring.parent;
    if (parent.path == ring.path) break;
    ring = parent;
  }
  return out;
}

void _searchRing(
  String root,
  String? exclude,
  Set<String> remaining,
  Map<String, ViLegacyIcon> out,
) {
  final stack = <String>[root];
  while (stack.isNotEmpty && remaining.isNotEmpty) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(stack.removeLast()).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final entity in entries) {
      if (entity is Directory) {
        if (entity.path != exclude) stack.add(entity.path);
      } else if (entity is File) {
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        if (!remaining.contains(name)) continue;
        final icon = decodeViFileIcon(entity.path);
        if (icon != null) out[name] = icon;
        remaining.remove(name);
      }
    }
  }
}

ViLegacyIcon? decodeViFileIcon(String path) {
  final List<ViSection> sections;
  try {
    sections = readViSections(File(path).readAsBytesSync());
  } catch (_) {
    return null;
  }
  return legacyIconFromSections(sections);
}
