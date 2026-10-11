/// `PTH0` - Path: [ViPath]
///
/// A path class.
///
/// This is the main path class used in `.vi`'s, there are `PTH2` (and thus likely
/// an unseen PTH1) but they aren't as widely used. As of yet there are no models.
///
/// A PTH0 path can generally be one of a few things:
/// - A file system relative/absolute path
/// - A file system absolute path with a symbolic root (e.g. `<vilib>`, `<helpdir>`)
/// - An unset `<Not A Path>`
/// - A one component relative path to a .NET assembly or DLL (e.g. mscorlib or user32.dll)
/// - A URL (absolute path)
///
/// The kind of path is determined by the [ViPathType] and the components: [ViPath.form] names
/// the five cases and [ViPath.text] spells each.
///
/// Path components are always devoid of separators, and '' is used for `..`. Paths start
/// at the `.vi` file, so filesystem relative paths will always start with a ''. Examples include:
/// - ["C", "Users", ...] => "C:\Users\..."
/// - ["", "Robot Global Data.vi"] => "Robot Global Data.vi", a sibling of the file
/// - ["http", "//www.example.com/doc"]
/// - `["<vilib>", "Utility", "file.llb", "Read From Spreadsheet File.vi"]` => `<vilib>\Utility\file.llb\Read From Spreadsheet File.vi`
///
/// No corpus path has the [ViPathType.unc] type.
///
/// ```text
/// offset  size  field          type                 meaning
/// 0       4     magic          4cc                  "PTH0".
/// 4       4     length         u32                  Bytes that follow this word.
/// 8       2     pathType       u16                  The ViPathType code.
/// 10      2     componentCount u16                  Number of components.
/// 12      …     components     pstr[componentCount] The path components.
/// ```
library;

import 'dart:typed_data';

import 'byte_layout.dart';
import 'byte_record.dart';

final class ViPath extends ByteRecord {
  ViPath(Uint8List bytes) : super(bytes, layout) {
    assert(isPth0(bytes), 'a PTH0 path: magic, length word, and components tiling the bytes');
    assert(ViPathType.of(_pathType.read(view)) != null, 'the path type word is a known type');
    final count = _componentCount.read(view);
    _componentOffsets = List<int>.filled(count, 0);
    var pos = _components.offset;
    for (var i = 0; i < count; i++) {
      _componentOffsets[i] = pos;
      pos = PStr.endAt(view, pos);
    }
  }

  /// The [ViPathType] code.
  int get pathType => _pathType.read(view);

  ViPathType get type => ViPathType.of(pathType)!;

  /// What the components spell, decided from [type] and the components alone.
  ViPathForm get form {
    final c = components;
    switch (type) {
      case ViPathType.notAPath:
        return ViPathForm.notAPath;
      case ViPathType.unc:
        return ViPathForm.unc;
      case ViPathType.absolute:
        if (c.isEmpty) return ViPathForm.empty;
        if (c.length >= 2 && c[1].startsWith('//')) return ViPathForm.url;
        if (c.isNotEmpty && c.first.startsWith('<') && c.first.endsWith('>')) return ViPathForm.symbolic;
        return ViPathForm.absolute;
      case ViPathType.relative:
        if (c.isEmpty) return ViPathForm.empty;
        if (c.length == 1 && c.first == '<Not A Path>') return ViPathForm.notAPath;
        return c.first.isEmpty ? ViPathForm.relative : ViPathForm.name;
    }
  }

  /// Number of components.
  int get componentCount => _componentOffsets.length;

  String componentAt(int index) => PStr.readAt(view, _componentOffsets[index]);

  /// The path components.
  List<String> get components => [for (var i = 0; i < componentCount; i++) componentAt(i)];

  /// The last component, or `''`.
  String get fileName => componentCount == 0 ? '' : componentAt(componentCount - 1);

  /// Directories a [ViPathForm.relative] path climbs from the directory of the file holding
  /// it: the leading empty components less the one that climbs from the file to its directory.
  int get upLevels {
    var empties = 0;
    while (empties < componentCount && componentAt(empties).isEmpty) {
      empties++;
    }
    return empties == 0 ? 0 : empties - 1;
  }

  /// The components after the leading empty ones.
  List<String> get segments {
    final c = components;
    var skip = 0;
    while (skip < c.length && c[skip].isEmpty) {
      skip++;
    }
    return c.sublist(skip);
  }

  /// The path as LabVIEW spells it on Windows: `C:\Users\me\x.vi`, `<vilib>\Utility\x.vi`,
  /// `..\Sub\x.vi` from the directory of the file holding it, `http://host/doc`,
  /// `<Not A Path>`, or a bare `user32.dll`.
  String get text {
    final c = components;
    switch (form) {
      case ViPathForm.empty:
        return '';
      case ViPathForm.notAPath:
        return '<Not A Path>';
      case ViPathForm.symbolic:
      case ViPathForm.name:
        return c.join(r'\');
      case ViPathForm.url:
        return '${c[0]}:${c.sublist(1).join('/')}';
      case ViPathForm.absolute:
        return c.first.isEmpty ? c.join(r'\') : '${c.first}:\\${c.sublist(1).join(r'\')}';
      case ViPathForm.relative:
        return [for (var i = 0; i < upLevels; i++) '..', ...segments].join(r'\');
      case ViPathForm.unc:
        return r'\\' + c.join(r'\');
    }
  }

  /// The byte extent of a `PTH0` whose magic sits at [at] in [bytes], or null when the bytes
  /// there do not hold a complete path.
  static int? extentAt(Uint8List bytes, int at) {
    if (at + _components.offset > bytes.length) return null;
    final view = ByteData.sublistView(bytes);
    if (_magic.read(ByteData.sublistView(bytes, at, at + _magic.end)) != 'PTH0') return null;
    if (ViPathType.of(view.getUint16(at + _pathType.offset)) == null) return null;
    final end = at + _length.end + view.getUint32(at + _length.offset);
    if (end > bytes.length) return null;
    var pos = at + _components.offset;
    for (var i = view.getUint16(at + _componentCount.offset); i > 0; i--) {
      if (pos >= end) return null;
      pos = PStr.endAt(view, pos);
    }
    return pos == end ? end - at : null;
  }

  late final List<int> _componentOffsets;

  static const _magic = FourCc(0); // "PTH0".
  static const _length = U32(4); // Bytes that follow this word.
  static const _pathType = U16(8);
  static const _componentCount = U16(10);
  static const _components = PStrList(12, count: _componentCount);

  static const layout = ByteLayout([_magic, _length, _pathType, _componentCount, _components]);
}

bool isPth0(Uint8List bytes) => ViPath.extentAt(bytes, 0) == bytes.length;

/// The path type word, numbered as LabVIEW's Path Type function reports it; the `PTH2` form
/// spells the same four kinds as `abs `, `rel `, `!pth` and `unc `. The corpus stores only 0
/// and 1.
enum ViPathType {
  absolute(0),

  /// Relative to the file that holds the path; each empty component climbs one level.
  relative(1),

  /// Never stored in the corpus: an unset help path is a [relative] path whose one component
  /// reads `<Not A Path>`.
  notAPath(2),

  /// Not in the corpus.
  unc(3);

  const ViPathType(this.code);

  final int code;

  static ViPathType? of(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// What a [ViPath] spells, see [ViPath.form].
enum ViPathForm {
  /// A path with no components.
  empty,

  /// The [ViPathType.notAPath] type, or a relative path whose one component is `<Not A Path>`.
  notAPath,

  /// An absolute path from a symbolic root such as `<vilib>` or `<helpdir>`.
  symbolic,

  /// An absolute path whose second component begins `//`: a URL, the scheme first.
  url,

  /// An absolute file-system path: a drive letter without its colon, or an empty first
  /// component for a path from the root.
  absolute,

  /// A relative file-system path; its leading empty components climb from the file holding it.
  relative,

  /// A relative path with no leading empty component: a bare .NET assembly or DLL name.
  name,

  /// The [ViPathType.unc] type; not in the corpus.
  unc,
}
