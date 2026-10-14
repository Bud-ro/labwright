import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The icons of the sub-VIs named in [wanted], by file name, read from the files the VI at
/// [viPath] links to: each link's path record from the VI's directory, else its library-qualified
/// name through the library files under the directory [levelsUp] above the VI, else the file of
/// that name nearest the VI within those directories.
Map<String, ViLegacyIcon> resolveSubViIcons(
  String viPath,
  Set<String> wanted, {
  int levelsUp = 4,
  int directoryBudget = kLvProjectScanDirectoryBudget,
}) {
  final out = <String, ViLegacyIcon>{};
  if (wanted.isEmpty) return out;
  final remaining = {for (final name in wanted) name.toLowerCase(): name};
  final callerDir = File(viPath).parent.path;
  final root = subViSearchRoot(callerDir, levelsUp);

  var links = const <ViLinkEntryFramed>[];
  try {
    links = readSubViLinks(File(viPath).readAsBytesSync());
  } catch (_) {}
  final byQualifiedName = <ViLinkEntryFramed>[];
  for (final link in links) {
    final fileName = link.qualifiedName.lastOrNull;
    final name = fileName == null ? null : remaining[fileName.toLowerCase()];
    if (name == null) continue;
    final path = link.path;
    if (path != null && path.pathType == 1) {
      final file = resolveViPath(viPath, path.components);
      final icon = decodeViFileIcon(file);
      if (icon != null) {
        out[name] = icon;
        remaining.remove(fileName!.toLowerCase());
        continue;
      }
    }
    if (path != null && path.text.startsWith('<')) {
      remaining.remove(fileName!.toLowerCase());
      continue;
    }
    if (link.qualifiedName.length > 1) byQualifiedName.add(link);
  }
  if (byQualifiedName.isNotEmpty) {
    final index = LvProjectIndex.scan(
      root,
      directoryBudget: directoryBudget,
      skipHidden: true,
    );
    for (final link in byQualifiedName) {
      final fileName = link.qualifiedName.last.toLowerCase();
      final name = remaining[fileName];
      if (name == null) continue;
      final file = index.fileOf(link.qualifiedName);
      final icon = file == null ? null : decodeViFileIcon(file);
      if (icon != null) {
        out[name] = icon;
        remaining.remove(fileName);
      }
    }
  }

  var ring = Directory(callerDir);
  String? searched;
  var budget = directoryBudget;
  while (remaining.isNotEmpty && budget > 0) {
    budget -= _searchRing(ring.path, searched, remaining, out, budget);
    if (ring.path == root.path) break;
    searched = ring.path;
    ring = ring.parent;
  }
  return out;
}

/// The directory [levelsUp] above [callerDir], stopping short of [home] (the user's home
/// directory unless given) and the filesystem root, which a search must never walk.
Directory subViSearchRoot(String callerDir, int levelsUp, {String? home}) {
  home ??= Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  var root = Directory(callerDir);
  for (var up = 0; up < levelsUp; up++) {
    final parent = root.parent;
    if (parent.path == home || parent.parent.path == parent.path) break;
    root = parent;
  }
  return root;
}

/// Searches [root] for the files [remaining] names, skipping the subtree [exclude] already
/// searched, visiting at most [budget] directories; the number visited.
int _searchRing(
  String root,
  String? exclude,
  Map<String, String> remaining,
  Map<String, ViLegacyIcon> out,
  int budget,
) {
  final stack = <String>[root];
  var visited = 0;
  while (stack.isNotEmpty && remaining.isNotEmpty && visited < budget) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(stack.removeLast()).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    visited++;
    for (final entity in entries) {
      if (entity is Directory) {
        final name = entity.uri.pathSegments.lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => '',
        );
        if (entity.path != exclude && !name.startsWith('.'))
          stack.add(entity.path);
      } else if (entity is File) {
        final fileName = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last.toLowerCase();
        final name = remaining[fileName];
        if (name == null) continue;
        final icon = decodeViFileIcon(entity.path);
        if (icon != null) out[name] = icon;
        remaining.remove(fileName);
      }
    }
  }
  return visited;
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
