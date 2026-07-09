import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Indexes every `.vi`/`.vim` file in the opened VI's project neighbourhood to a
/// `filename → absolute path` map, used to resolve **on-node subVI icons** (see
/// `resolveSubViIcons`): a subVI-call node captioned `Assert Equal.vi` is matched
/// to that file on disk and its icon read.
///
/// The walk is **complete** — it visits every directory in the subtree of the
/// [levelsUp]-th ancestor of [viPath] (a called subVI usually lives in a sibling
/// folder of the caller, so nearby files matter, but any of them can be a target)
/// so every subVI that exists on disk resolves. It is a plain iterative walk (no
/// eager `listSync(recursive: true)` materialisation of the whole tree). Run it
/// off the UI isolate via [buildProjectViLoader] so a large or slow (network /
/// WSL-mounted) project tree never stalls the load. First path wins for a
/// duplicated filename; directory-walk failures are swallowed (icon resolution is
/// an enhancement, never a load blocker).
Map<String, String> indexProjectVis(String viPath, {int levelsUp = 4}) {
  var root = File(viPath).parent;
  for (var i = 0; i < levelsUp; i++) {
    final parent = root.parent;
    if (parent.path == root.path) break;
    root = parent;
  }
  final byName = <String, String>{};
  final stack = <String>[root.path];
  while (stack.isNotEmpty) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(stack.removeLast()).listSync(followLinks: false);
    } catch (_) {
      continue; // permission/race: skip this directory, keep indexing.
    }
    for (final entity in entries) {
      if (entity is Directory) {
        stack.add(entity.path);
      } else if (entity is File) {
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        final lower = name.toLowerCase();
        if (lower.endsWith('.vi') || lower.endsWith('.vim')) {
          byName.putIfAbsent(name, () => entity.path);
        }
      }
    }
  }
  return byName;
}

/// Builds the project VI index off the main isolate (via [Isolate.run]) so the
/// complete directory walk never blocks the UI, then returns a `filename → bytes`
/// loader over it. The returned function reads a file's bytes by bare filename,
/// or null when the name is unknown/unreadable — a node whose target is not found
/// keeps its neutral plate (the icon is never guessed).
Future<Uint8List? Function(String fileName)> buildProjectViLoader(
  String viPath, {
  int levelsUp = 4,
}) async {
  final index = await Isolate.run(
    () => indexProjectVis(viPath, levelsUp: levelsUp),
  );
  return (String fileName) {
    final path = index[fileName];
    if (path == null) return null;
    try {
      return File(path).readAsBytesSync();
    } catch (_) {
      return null;
    }
  };
}
