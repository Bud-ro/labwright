import 'dart:io';
import 'dart:typed_data';

/// Builds a best-effort `filename → bytes` loader used to resolve **on-node subVI
/// icons** (see `resolveSubViIcons`): it indexes the opened VI's project
/// neighbourhood so a subVI-call node captioned `Assert Equal.vi` can be matched
/// to that file on disk and its icon read.
///
/// The index is built by a **bounded, nearest-first** directory walk: it starts
/// at the opened VI's own directory and expands outward through up to [levelsUp]
/// ancestor directories, visiting each directory at most once. A called subVI
/// usually lives in a sibling folder of the caller, so the nearest files are
/// indexed first. The walk stops as soon as any of these holds — so it can never
/// stall the UI on a large or slow filesystem (the previous
/// `listSync(recursive: true)` eagerly materialised the entire ancestor subtree
/// before any cap applied, which could take tens of seconds on a deep or
/// network/WSL-mounted tree):
/// - every name in [wantedNames] has been located (the common, fast path);
/// - [maxFiles] `.vi`/`.vim` files have been indexed;
/// - [maxEntries] directory entries have been visited (the hard backstop).
///
/// Returns a loader that reads a file's bytes by bare filename (first path wins),
/// or null when the name is unknown/unreadable — a node whose target is not found
/// keeps its neutral plate (the icon is never guessed). Directory-walk failures
/// are swallowed: icon resolution is an enhancement, never a load blocker.
Uint8List? Function(String fileName) buildProjectViLoader(
  String viPath, {
  int levelsUp = 4,
  int maxFiles = 4000,
  int maxEntries = 6000,
  Set<String>? wantedNames,
}) {
  final byName = <String, String>{};
  final wanted = wantedNames == null ? null : {...wantedNames};
  final seenDirs = <String>{};
  var entriesVisited = 0;

  bool done() =>
      entriesVisited >= maxEntries ||
      byName.length >= maxFiles ||
      (wanted != null && wanted.isEmpty);

  // Breadth-first index of [start]'s subtree, skipping directories already
  // walked by a nearer level, bounded by the shared [done] budget.
  void indexSubtree(Directory start) {
    final queue = <Directory>[start];
    while (queue.isNotEmpty && !done()) {
      final dir = queue.removeAt(0);
      if (!seenDirs.add(dir.path)) continue;
      final List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        continue; // permission/race: skip this directory, keep indexing.
      }
      for (final entity in entries) {
        entriesVisited++;
        if (done()) return;
        if (entity is Directory) {
          queue.add(entity);
          continue;
        }
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        final lower = name.toLowerCase();
        if (lower.endsWith('.vi') || lower.endsWith('.vim')) {
          if (byName.putIfAbsent(name, () => entity.path) == entity.path) {
            wanted?.remove(name);
          }
        }
      }
    }
  }

  // Nearest-first: the caller's own directory, then each ancestor in turn. The
  // seen-set makes each directory cost at most once across levels.
  var dir = File(viPath).parent;
  for (var level = 0; level <= levelsUp && !done(); level++) {
    indexSubtree(dir);
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  return (fileName) {
    final path = byName[fileName];
    if (path == null) return null;
    try {
      return File(path).readAsBytesSync();
    } catch (_) {
      return null;
    }
  };
}
