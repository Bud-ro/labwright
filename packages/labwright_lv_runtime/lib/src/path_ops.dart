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
