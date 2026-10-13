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
}) {
  final out = <String, ViLegacyIcon>{};
  if (wanted.isEmpty) return out;
  final remaining = {for (final name in wanted) name.toLowerCase(): name};
  final callerDir = File(viPath).parent.path;
  var root = Directory(callerDir);
  for (var up = 0; up < levelsUp; up++) {
    final parent = root.parent;
    if (parent.path == root.path) break;
    root = parent;
  }

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
    final index = LvProjectIndex.scan(root);
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
  Map<String, String> remaining,
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
