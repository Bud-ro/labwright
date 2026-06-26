import 'dart:convert';
import 'dart:typed_data';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_property.dart';

/// Reader for the **legacy INI** `.seq` encoding (TestStand 3.x–era; some newer
/// installs still emit it). It is a *plaintext* serialization of the **same
/// PropertyObject model** the binary `TOF1` and the XML forms encode, which makes
/// it a readable Rosetta for the binary record tree (see NOTES.md).
///
/// Grammar (confirmed across the 58 INI files in the corpus, versions
/// 143/354/797/894/920):
///
/// ```
/// [__Header__]                 ← file header: ProductName/ProductVersion/Version/Type/Path/...
/// ProductName = "TestStand"
/// Version = 354
/// Type = "SequenceFile"
///
/// [DEF, %OBJROOT]              ← type/member DECLARATIONS for the object at a path
/// SF = SequenceFileData            member = TypeName
/// [DEF, SF]
/// Seq = Objs
/// %NAME = "Data"                   directive: this object's display name
///
/// [SF]                         ← VALUE instance for the object at a path
/// %HI: Seq = [0]                   directive: array high-index / bounds
/// %FLG: Seq = 4194304              directive: property flags
/// Version = "0.0.0.0"              member = value
/// [DEF, SF.Seq]
/// %[0] = Sequence                  array-element type declaration
/// [DEF, SF.Seq[0]]
/// %NAME = "MainSequence"
/// ```
///
/// Paths nest like the binary name pool (`SF` → `SF.Seq` → `SF.Seq[0]`), where
/// `SF` is the `%OBJROOT` alias for `SequenceFileData`. This first slice parses
/// the header and the section structure (value vs. DEF, path, members, and the
/// `%`-directives). Assembling the full [SeqProperty] tree from these sections is
/// the next slice — **not yet decoded**, not unrecoverable.

/// One `[...]` block of an INI `.seq`: either a value instance (`[path]`) or a
/// type definition (`[DEF, path]`).
class IniSection {
  IniSection({
    required this.isDef,
    required this.path,
    required this.members,
    required this.directives,
  });

  /// True for a `[DEF, path]` section (member→type declarations); false for a
  /// `[path]` value instance (member→value).
  final bool isDef;

  /// The object path, e.g. `SF`, `SF.Seq[0]`, or the root alias `%OBJROOT`.
  final String path;

  /// Plain `member = value` (value section) or `member = TypeName` (DEF section)
  /// lines, excluding the `%`-directives. Insertion order preserved.
  final Map<String, String> members;

  /// The `%`-directives, keyed by their full left-hand side, e.g.
  /// `%NAME`, `%FLG: Seq`, `%HI: Main`, `%TYPE: %[0]`, `%[0]`.
  final Map<String, String> directives;

  /// This object's display name (`%NAME = "..."`), unquoted, or null.
  String? get name => _unquote(directives['%NAME']);

  @override
  String toString() =>
      'IniSection(${isDef ? 'DEF ' : ''}$path, ${members.length} members, '
      '${directives.length} directives)';
}

/// A parsed legacy INI `.seq`: its header plus every section in document order.
class IniSeqFile {
  IniSeqFile({
    required this.header,
    required this.sections,
    required this.headerFields,
  });

  /// Header recovered from `[__Header__]` (format [SeqFormat.ini]).
  final SeqFileHeader header;

  /// All `[...]` / `[DEF, ...]` sections in order (header section excluded).
  final List<IniSection> sections;

  /// The raw `[__Header__]` key→value map (quoted values left as-is).
  final Map<String, String> headerFields;
}

/// Parses [bytes] of a legacy INI `.seq`. INI files are single-byte (SBCS), so
/// the bytes are decoded as Latin-1 to avoid choking on non-ASCII in comments.
IniSeqFile parseIniSeqBytes(Uint8List bytes) => parseIniSeq(latin1.decode(bytes, allowInvalid: true));

/// Parses the text of a legacy INI `.seq` into its header and sections.
IniSeqFile parseIniSeq(String text) {
  final headerFields = <String, String>{};
  final sections = <IniSection>[];

  bool inHeader = false;
  IniSection? current;

  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trimRight();
    if (line.isEmpty) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      final inner = line.substring(1, line.length - 1).trim();
      if (inner == '__Header__') {
        inHeader = true;
        current = null;
        continue;
      }
      inHeader = false;
      final isDef = inner.startsWith('DEF,');
      final path = isDef ? inner.substring(4).trim() : inner;
      current = IniSection(
        isDef: isDef,
        path: path,
        members: <String, String>{},
        directives: <String, String>{},
      );
      sections.add(current);
      continue;
    }
    // A `key = value` line (the only non-section line shape). Split on the first
    // ` = ` so values may themselves contain '='.
    final eq = line.indexOf(' = ');
    if (eq < 0) continue; // not yet decoded line shape — skip rather than guess
    final key = line.substring(0, eq).trim();
    final value = line.substring(eq + 3);
    if (inHeader) {
      headerFields[key] = value;
    } else if (current != null) {
      if (key.startsWith('%')) {
        current.directives[key] = value;
      } else {
        current.members[key] = value;
      }
    }
  }
  return IniSeqFile(
    header: _headerFrom(headerFields),
    sections: sections,
    headerFields: headerFields,
  );
}

/// Builds a [SeqFileHeader] from a parsed `[__Header__]` map. `Type` →
/// [SeqFileHeader.fileType], `ProductName` → product, `Version` → fileVersion.
SeqFileHeader parseIniHeader(String text) => parseIniSeq(text).header;

SeqFileHeader _headerFrom(Map<String, String> h) => SeqFileHeader(
      format: SeqFormat.ini,
      fileType: _unquote(h['Type']),
      productName: _unquote(h['ProductName']),
      fileVersion: h['Version'], // a bare integer like 354 (no quotes)
    );

/// Reconstructs the data [SeqProperty] tree from a parsed INI `.seq`, rooted at
/// the `%OBJROOT` alias that maps to `SequenceFileData` (the file's `Data`
/// object). Returns null if no such root is found.
///
/// This is the bridge onto the shared PropertyObject model: paths like
/// `SF.Seq[0].Main[0]` become nested objects/arrays. Each object's members and
/// their declared types come from its `[DEF, path]` section; values from the
/// `[path]` section; `%NAME` becomes the node name; `Objs`/array members expand
/// to [SeqProperty.array] from the `member[i]` element paths. Type-reference
/// resolution against `[%TYPES]` and instance overrides (`%INSTOVRD`) are not yet
/// modelled — TODO, not unrecoverable.
SeqProperty? iniDataTree(IniSeqFile doc) {
  // Merge DEF + value sections by path into one record per object path.
  final defs = <String, IniSection>{};
  final vals = <String, IniSection>{};
  for (final s in doc.sections) {
    (s.isDef ? defs : vals)[s.path] = s;
  }
  // The data root is the %OBJROOT alias declaring type SequenceFileData (e.g.
  // `SF = SequenceFileData`).
  final objRoot = defs['%OBJROOT'];
  if (objRoot == null) return null;
  String? rootPath;
  objRoot.members.forEach((alias, type) {
    rootPath ??= type == 'SequenceFileData' ? alias : null;
  });
  if (rootPath == null) return null;

  final allPaths = {...defs.keys, ...vals.keys};

  // Distinct array indices present under a child path C (keys "C[0]", "C[1]"…).
  List<int> elementIndices(String c) {
    final prefix = '$c[';
    final idx = <int>{};
    for (final p in allPaths) {
      if (!p.startsWith(prefix)) continue;
      final close = p.indexOf(']', prefix.length);
      if (close < 0) continue;
      final n = int.tryParse(p.substring(prefix.length, close));
      if (n != null) idx.add(n);
    }
    final list = idx.toList()..sort();
    return list;
  }

  bool isContainer(String childPath) =>
      allPaths.contains(childPath) ||
      allPaths.any((p) => p.startsWith('$childPath.') || p.startsWith('$childPath['));

  // Immediate child member names of [path] discovered from the path set — catches
  // container members (e.g. a step's `SData`) that are implied only by a deeper
  // section and aren't listed in the object's own DEF/value members.
  List<String> discoveredChildren(String path) {
    final prefix = '$path.';
    final seen = <String>{};
    final order = <String>[];
    for (final p in allPaths) {
      if (!p.startsWith(prefix)) continue;
      final rest = p.substring(prefix.length);
      var end = rest.length;
      for (var i = 0; i < rest.length; i++) {
        if (rest[i] == '.' || rest[i] == '[') {
          end = i;
          break;
        }
      }
      final seg = rest.substring(0, end);
      if (seg.isNotEmpty && seen.add(seg)) order.add(seg);
    }
    return order;
  }

  SeqProperty build(
    String path,
    String displayName,
    String? declaredType, [
    String? declaredTypeName,
  ]) {
    final def = defs[path];
    final val = vals[path];
    final name = _unquote(val?.directives['%NAME']) ??
        _unquote(def?.directives['%NAME']) ??
        displayName;
    // Member order: the DEF declaration first (authoritative + typed), then any
    // value-only members not declared there.
    final memberTypes = def?.members ?? const <String, String>{};
    final memberOrder = <String>[...memberTypes.keys];
    final seen = memberTypes.keys.toSet();
    for (final m in (val?.members.keys ?? const <String>[])) {
      if (seen.add(m)) memberOrder.add(m);
    }
    // Container members implied only by deeper sections (e.g. a step's SData).
    for (final m in discoveredChildren(path)) {
      if (seen.add(m)) memberOrder.add(m);
    }

    final subs = <SeqProperty>[];
    for (final m in memberOrder) {
      final type = memberTypes[m];
      final childPath = '$path.$m';
      final elems = elementIndices(childPath);
      if (elems.isNotEmpty) {
        // An array member: build each element object in index order. The element
        // class (%[i]) and TestStand type (%TYPE: %[i]) are declared in the
        // array's own DEF section (e.g. `%[0] = Step`, `%TYPE: %[0] = "Action"`).
        final arrDef = defs[childPath];
        final arr = [
          for (final i in elems)
            build(
              '$childPath[$i]',
              '[$i]',
              arrDef?.directives['%[$i]'],
              _unquote(arrDef?.directives['%TYPE: %[$i]']),
            ),
        ];
        subs.add(SeqProperty(name: m, className: type, array: arr));
      } else if (isContainer(childPath)) {
        subs.add(build(childPath, m, type));
      } else {
        // Scalar leaf: declared type as className, value (if any) as scalar.
        subs.add(SeqProperty(
          name: m,
          className: type,
          scalar: _unquote(val?.members[m]),
        ));
      }
    }
    return SeqProperty(
      name: name,
      className: declaredType,
      typeName: declaredTypeName,
      subProps: subs,
    );
  }

  return build(rootPath!, 'Data', 'SequenceFileData');
}

/// Parses a legacy INI `.seq` into a [SeqFile] so the shared typed lens
/// ([SeqFile.sequences] / [Sequence] / [Step]) works on it. The data tree comes
/// from [iniDataTree]; the type list is not yet assembled from the `[%TYPES]`
/// sections (TODO — empty for now). Throws [FormatException] if the data root
/// cannot be reconstructed (e.g. the 2 corpus files lacking `%OBJROOT`).
SeqFile parseIniSeqFile(Uint8List bytes) {
  final doc = parseIniSeqBytes(bytes);
  final data = iniDataTree(doc);
  if (data == null) {
    throw const FormatException(
      'INI .seq has no reconstructable %OBJROOT data root (not yet decoded)',
    );
  }
  return SeqFile(header: doc.header, types: const [], data: data);
}

/// Strips one layer of surrounding double quotes, if present. Returns null for a
/// null input.
String? _unquote(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    return t.substring(1, t.length - 1);
  }
  return t;
}
