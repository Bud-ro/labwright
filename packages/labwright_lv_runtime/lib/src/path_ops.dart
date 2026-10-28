import 'dart:io';

import 'values.dart';

/// Build Path: [base] with [nameOrRelativePath] (a `String` or an [LvPath]) appended. An invalid
/// base, an invalid relative path or an empty name gives [LvPath.notAPath]; an absolute name on
/// an empty base is that path.
LvPath lvBuildPath(LvPath base, Object nameOrRelativePath) {
  final relative = switch (nameOrRelativePath) {
    final LvPath path => path,
    final String name => lvPathOfString(name),
    _ => throw ArgumentError.value(nameOrRelativePath, 'nameOrRelativePath', 'a String or an LvPath'),
  };
  if (!base.valid || !relative.valid) return LvPath.notAPath;
  if (relative.absolute) {
    if (base.isEmpty) return relative;
    throw UnsupportedError("Build Path of an absolute path onto a non-empty base: LabVIEW's result is not decoded");
  }
  return LvPath(components: [...base.components, ...relative.components], absolute: base.absolute);
}

/// A path spelled as the running platform spells one: components between its separators, with a
/// leading separator or a drive letter making it absolute. An empty string is [LvPath.notAPath].
LvPath lvPathOfString(String text) {
  if (text.isEmpty) return LvPath.notAPath;
  final separator = Platform.pathSeparator;
  final pieces = text.split(separator);
  final absolute = pieces.first.isEmpty || (Platform.isWindows && RegExp(r'^[A-Za-z]:\$').hasMatch(pieces.first));
  return LvPath(
    components: [
      for (final piece in pieces)
        if (piece.isNotEmpty) piece,
    ],
    absolute: absolute,
  );
}

// TODO(lv-refnum-validity): references are not tracked after creation, so a reference other
// than Not A Refnum reads as valid.
bool lvNotARefnum(LvRefnum refnum) => refnum.id == LvRefnum.none.id;

/// Strip Path: the last component and the path leading to it. An empty or invalid path gives an
/// empty name and Not A Path; a path of one relative component gives an empty relative path,
/// and the root of an absolute path strips to Not A Path.
({LvPath strippedPath, String name}) lvStripPath(LvPath path) {
  if (!path.valid || path.components.isEmpty) return (strippedPath: LvPath.notAPath, name: '');
  return (
    strippedPath: LvPath(components: path.components.sublist(0, path.components.length - 1), absolute: path.absolute),
    name: path.components.last,
  );
}

/// Path To String, in the running platform's spelling; Not A Path spells `<Not A Path>`.
String lvPathToString(LvPath path) {
  if (!path.valid) return '<Not A Path>';
  final separator = Platform.pathSeparator;
  if (!path.absolute) return path.components.join(separator);
  if (Platform.isWindows && path.components.isNotEmpty && RegExp(r'^[A-Za-z]:$').hasMatch(path.components.first)) {
    return path.components.join(separator) + (path.components.length == 1 ? separator : '');
  }
  return separator + path.components.join(separator);
}

/// Is Path And Not Empty?: the path's type as LabVIEW numbers them, 0 absolute, 1 relative,
/// 2 Not A Path, 3 empty.
int lvPathType(LvPath path) {
  if (!path.valid) return 2;
  if (path.isEmpty) return 3;
  return path.absolute ? 0 : 1;
}

/// Path To Array Of Strings: the components, and whether the path is relative.
({bool relative, List<String> components}) lvPathToArrayOfStrings(LvPath path) =>
    (relative: !path.absolute, components: path.valid ? List<String>.of(path.components) : <String>[]);

/// Array Of Strings To Path.
LvPath lvArrayOfStringsToPath(List<String> components, {bool relative = false}) =>
    LvPath(components: List<String>.of(components), absolute: !relative);

/// Whether two paths name the same location.
bool lvSamePath(LvPath left, LvPath right) => lvSameValue(left, right);
