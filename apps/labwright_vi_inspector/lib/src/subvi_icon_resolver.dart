import 'dart:io';
import 'dart:typed_data';

/// Builds a best-effort `filename → bytes` loader used to resolve **on-node subVI
/// icons** (see `resolveSubViIcons`): it indexes the opened VI's project
/// neighbourhood so a subVI-call node captioned `Assert Equal.vi` can be matched
/// to that file on disk and its icon read.
///
/// The index walks up [levelsUp] parent directories from [viPath] — a called
/// subVI usually lives in a sibling folder of the caller, not the caller's own
/// directory — then indexes every `.vi`/`.vim` beneath that root (first path wins,
/// capped at [maxFiles] so a very large tree cannot stall the load). Returns a
/// loader that reads a file's bytes by bare filename, or null when the name is
/// unknown/unreadable — a node whose target is not found keeps its neutral plate
/// (the icon is never guessed). Directory-walk failures are swallowed: icon
/// resolution is an enhancement, never a load blocker.
Uint8List? Function(String fileName) buildProjectViLoader(
  String viPath, {
  int levelsUp = 4,
  int maxFiles = 4000,
}) {
  var root = File(viPath).parent;
  for (var i = 0; i < levelsUp; i++) {
    final parent = root.parent;
    if (parent.path == root.path) break;
    root = parent;
  }
  final byName = <String, String>{};
  try {
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (byName.length >= maxFiles) break;
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last;
      final lower = name.toLowerCase();
      if (lower.endsWith('.vi') || lower.endsWith('.vim')) {
        byName.putIfAbsent(name, () => entity.path);
      }
    }
  } catch (_) {
    // A permission or race error mid-walk leaves whatever was indexed so far.
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
