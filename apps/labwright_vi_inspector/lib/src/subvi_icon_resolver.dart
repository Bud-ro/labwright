import 'dart:io';
import 'dart:isolate';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Resolves the icons of the subVIs an opened VI calls, by **searching outward
/// ring by ring** from the VI's own directory and **streaming each ring's finds**
/// as soon as they decode — so icons from the caller's own folder (where called
/// subVIs usually live) render within moments of the load, while farther rings
/// keep searching in the background.
///
/// Ring `N` is the subtree of the VI's `N`-th ancestor directory, minus ring
/// `N-1`'s subtree (each directory is visited exactly once across the whole
/// search). Every ring runs off the UI isolate ([Isolate.run]): it walks its
/// directories, and for each file whose name is still wanted it reads the file
/// and decodes its richest legacy icon (`icl8` → `icl4` → `ICON`) right there,
/// returning a `filename → icon` batch. The search is complete — it ends only
/// when every wanted name is found or all [levelsUp] rings are exhausted — and
/// carries no directory/file caps; the nearest-first order is what makes the
/// first icons fast, not a coverage cut. First path wins for a duplicated
/// filename; unreadable files and directories are skipped (icon resolution is an
/// enhancement, never a load blocker).
Stream<Map<String, ViLegacyIcon>> streamSubViIcons(
  String viPath,
  Set<String> wantedNames, {
  int levelsUp = 4,
}) async* {
  final remaining = {...wantedNames};
  var ring = File(viPath).parent;
  String? searched; // the previous ring's root — its subtree is already done
  for (var level = 0; level <= levelsUp && remaining.isNotEmpty; level++) {
    final root = ring.path;
    final exclude = searched;
    final wanted = {...remaining};
    final batch = await Isolate.run(
      () => searchIconRing(root, exclude, wanted),
    );
    if (batch.isNotEmpty) {
      remaining.removeAll(batch.keys);
      yield batch;
    }
    searched = root;
    final parent = ring.parent;
    if (parent.path == ring.path) break;
    ring = parent;
  }
}

/// Walks the [root] subtree (skipping the already-searched [exclude] subtree),
/// decoding the icon of every file whose name is in [wanted]. Returns the
/// `filename → icon` finds; stops early once every wanted name is found. Runs
/// inside [Isolate.run] — synchronous I/O is fine here and keeps the walk tight.
Map<String, ViLegacyIcon> searchIconRing(
  String root,
  String? exclude,
  Set<String> wanted,
) {
  final out = <String, ViLegacyIcon>{};
  final remaining = {...wanted};
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
        final icon = _decodeIconOf(entity.path);
        if (icon != null) {
          out[name] = icon;
        }
        // Found or unreadable/icon-less: either way this name is settled
        // (first path wins; a later duplicate would not render differently).
        remaining.remove(name);
      }
    }
  }
  return out;
}

/// Reads a `.vi` file and decodes its richest legacy icon (`icl8` → `icl4` →
/// `ICON`), or null when the file is unreadable, not a VI, or icon-less.
ViLegacyIcon? _decodeIconOf(String path) {
  final List<DecodedSection> sections;
  try {
    sections = decodeSections(File(path).readAsBytesSync());
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
