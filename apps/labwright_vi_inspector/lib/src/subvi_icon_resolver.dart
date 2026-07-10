import 'dart:io';
import 'dart:isolate';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Resolves the icons of the subVIs an opened VI calls — in one shot, fast.
///
/// The trick is that almost no searching is needed:
///
/// 1. **The linker says where each dependency is.** The `LIbd` block stores a
///    `PTH0` path per dependency ([readSubViPaths]). A *relative* path resolves
///    directly against the calling VI's directory — one file read, no search.
///    A relative target that is absent is **known-missing** (the linker's own
///    path says where it would be), so nothing searches for it. A `<vilib>`
///    path is LabVIEW's own library — never on the project disk, never
///    searched.
/// 2. **Icon reads touch no heap.** Icons come from the uncompressed
///    `icl8`/`icl4`/`ICON` sections via the container-level [readViSections] —
///    no zlib inflation of diagram heaps, so reading a target's icon costs one
///    file read plus a ~1KB decode.
/// 3. **Only unlocated names search** (symbolic `<userlib>`-style paths whose
///    project location differs from the save-time install, or labels with no
///    linker path). The search is nearest-first ring-by-ring — ring N is the
///    N-th ancestor's subtree minus the inner rings, each directory visited at
///    most once — and stops as soon as every searched-for name is found.
///
/// The whole resolution runs in a single [Isolate.run] so the UI thread never
/// touches the filesystem; the result is one `filename → icon` map. Unreadable
/// files/directories are skipped (icon resolution is an enhancement, never a
/// load blocker).
Future<Map<String, ViLegacyIcon>> resolveSubViIconsFor(
  String viPath,
  Set<String> wantedNames, {
  int levelsUp = 4,
}) {
  if (wantedNames.isEmpty) return Future.value(const {});
  final wanted = {...wantedNames};
  return Isolate.run(() => resolveIconsOnDisk(viPath, wanted, levelsUp));
}

/// The synchronous resolution body (runs inside [Isolate.run]; public for
/// tests). See [resolveSubViIconsFor] for the strategy.
Map<String, ViLegacyIcon> resolveIconsOnDisk(
  String viPath,
  Set<String> wanted,
  int levelsUp,
) {
  final out = <String, ViLegacyIcon>{};
  final remaining = {...wanted};
  final callerDir = File(viPath).parent.path;

  // 1. Linker-recorded paths: direct resolution, no searching.
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
        // Present or not, the linker's path is where this target lives —
        // absent means absent from this checkout, so it is never searched.
        remaining.remove(name);
      case ViSubViPathKind.viLib:
        remaining.remove(name); // LabVIEW's own library — never on disk here.
      case ViSubViPathKind.symbolic:
      case ViSubViPathKind.other:
        break; // save-time install location — the project tree may still have it.
    }
  }

  // 2. Nearest-first ring search for the names without a usable linker path.
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

/// Walks the [root] subtree (skipping the already-searched [exclude] subtree),
/// decoding the icon of every file named in [remaining] into [out] and removing
/// it from [remaining]; returns early once [remaining] empties.
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
      continue; // permission/race: skip this directory, keep searching.
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
        // First hit settles the name either way (first path wins).
        remaining.remove(name);
      }
    }
  }
}

/// Reads a `.vi` file's richest legacy icon (`icl8` → `icl4` → `ICON`) via the
/// container-level section reader — the icon sections are stored uncompressed,
/// so no heap is inflated. Null when the file is unreadable, not a VI, or
/// icon-less. Public for tests.
ViLegacyIcon? decodeViFileIcon(String path) {
  final List<ViSection> sections;
  try {
    sections = readViSections(File(path).readAsBytesSync());
  } catch (_) {
    return null;
  }
  for (final tag in const ['icl8', 'icl4', 'ICON']) {
    for (final section in sections) {
      if (section.tag != tag) continue;
      final bpp = legacyIconBpp(tag);
      if (bpp == null) continue;
      final icon = decodeLegacyIcon(section.bytes, bpp);
      if (icon != null) return icon;
    }
  }
  return null;
}
