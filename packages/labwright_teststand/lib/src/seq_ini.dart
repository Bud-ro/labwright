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
/// `SF` is the `%OBJROOT` alias for `SequenceFileData`. [parseIniSeq] parses the
/// header and section structure (value vs. DEF, path, members, `%`-directives);
/// [iniDataTree] then assembles the full [SeqProperty] tree from those sections
/// (type inheritance, arrays, instance overrides, comments) — **fully decoded**
/// across the corpus (58/58), feeding the same typed lens as the XML form.

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
    // No ` = `: not a key=value line. None occur in any corpus INI inside a
    // section (verified + guarded by a corpus test); skip defensively.
    if (eq < 0) continue;
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
  for (final s in sections) {
    _reassembleContinuations(s.members);
    _reassembleContinuations(s.directives);
  }
  return IniSeqFile(
    header: _headerFrom(headerFields),
    sections: sections,
    headerFields: headerFields,
  );
}

/// Matches a continuation key: a base key plus a 4-digit ` LineNNNN` suffix.
final _continuationKey = RegExp(r'^(.+) Line(\d+)$');

/// Reassembles split long values in [map] (a section's members or directives).
///
/// NI splits a value past a line-length cap across continuation lines named
/// `KEY Line0001`, `KEY Line0002`, … — the base key with a ` LineNNNN` suffix —
/// each holding a separately-quoted fragment of the whole. This rejoins them, in
/// numeric order, into the single base key `KEY` whose value is the fragments'
/// inner text concatenated with no separator and rewrapped in one pair of quotes.
/// Verified across the full corpus (19818 fragments, all quoted, all contiguous
/// from 0001, never coexisting with a bare base key). Single-line values, which
/// never match the suffix, are left untouched.
void _reassembleContinuations(Map<String, String> map) {
  Map<String, List<(int, String)>>? groups;
  for (final key in map.keys) {
    final m = _continuationKey.firstMatch(key);
    if (m == null) continue;
    (groups ??= {})
        .putIfAbsent(m.group(1)!, () => [])
        .add((int.parse(m.group(2)!), map[key]!));
  }
  if (groups == null) return;
  // Rebuild preserving insertion order: emit the joined base value where the
  // group's first fragment sat; drop the remaining fragment keys.
  final rebuilt = <String, String>{};
  final emitted = <String>{};
  for (final entry in map.entries) {
    final m = _continuationKey.firstMatch(entry.key);
    if (m == null) {
      rebuilt[entry.key] = entry.value;
      continue;
    }
    final base = m.group(1)!;
    if (emitted.add(base)) {
      final frags = groups[base]!..sort((a, b) => a.$1.compareTo(b.$1));
      rebuilt[base] = _joinFragments(frags.map((f) => f.$2));
    }
  }
  map
    ..clear()
    ..addAll(rebuilt);
}

/// Joins quoted continuation [fragments] into one value: strips each fragment's
/// surrounding quotes, concatenates the inner text in order, and rewraps in a
/// single pair of quotes. A fragment lacking surrounding quotes is concatenated
/// verbatim (unobserved in the corpus, handled defensively); the joined value
/// stays quoted as long as any fragment was.
String _joinFragments(Iterable<String> fragments) {
  final buf = StringBuffer();
  var anyQuoted = false;
  for (final f in fragments) {
    final t = f.trim();
    if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
      anyQuoted = true;
      buf.write(t.substring(1, t.length - 1));
    } else {
      buf.write(f);
    }
  }
  return anyQuoted ? '"$buf"' : buf.toString();
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
/// to [SeqProperty.array] from the `member[i]` element paths. Type inheritance
/// (defaults pulled from a typed object's `[DEF, <Type>]`, instance-wins) and
/// instance overrides (`%INSTOVRD`) and comments (`%COMMENT`) are modelled — see
/// [_IniBuilder]. The `%INSTOVRD` flags *bitmask* is kept verbatim (its bit
/// meanings need NI's PropFlags enum), not yet interpreted.
SeqProperty? iniDataTree(IniSeqFile doc) {
  final b = _IniBuilder(doc);
  final rootPath = b.dataRootPath();
  return rootPath == null ? null : b.build(rootPath, 'Data', 'SequenceFileData');
}

/// Reconstructs the type list (`[%TYPES]`) of a parsed INI `.seq` into
/// [SeqProperty] objects — the INI analogue of XML's `<typelist>`. Each entry of
/// the `[%TYPES]` section names a top-level type defined by its own
/// `[DEF, <Type>]`/`[<Type>]` sections. Returns an empty list if absent.
List<SeqProperty> iniTypes(IniSeqFile doc) {
  final b = _IniBuilder(doc);
  final typeList = doc.sections
      .where((s) => !s.isDef && s.path == '%TYPES')
      .firstOrNull;
  if (typeList == null) return const [];
  return [
    for (final t in typeList.members.keys)
      if (b.hasPath(t)) b.build(t, t, _unquote(typeList.members[t])),
  ];
}

/// Builds [SeqProperty] objects from an INI `.seq`'s path-addressed sections.
class _IniBuilder {
  _IniBuilder(IniSeqFile doc) {
    for (final s in doc.sections) {
      (s.isDef ? _defs : _vals)[s.path] = s;
    }
    _allPaths = {..._defs.keys, ..._vals.keys};
  }

  final Map<String, IniSection> _defs = {};
  final Map<String, IniSection> _vals = {};
  late final Set<String> _allPaths;

  bool hasPath(String path) => _allPaths.contains(path);

  /// The root-objects alias sections, in priority order. Newer files declare
  /// top-level objects under `[DEF, %OBJROOT]`; older ones (e.g. versions 127/143)
  /// use `[DEF, %OBJECTS]`. Both list `member = TypeName`, including the
  /// sequence-file root (`SF = SequenceFileData`).
  static const _rootAliases = ['%OBJROOT', '%OBJECTS'];

  /// The data root: the alias member declaring type `SequenceFileData` (e.g.
  /// `SF = SequenceFileData`) in the first root-objects section that has one, or
  /// null when absent.
  String? dataRootPath() {
    for (final alias in _rootAliases) {
      final root = _defs[alias];
      if (root == null) continue;
      for (final e in root.members.entries) {
        if (e.value == 'SequenceFileData') return e.key;
      }
    }
    return null;
  }

  /// Distinct array indices present under a child path C (keys "C[0]", "C[1]"…).
  List<int> _elementIndices(String c) {
    final prefix = '$c[';
    final idx = <int>{};
    for (final p in _allPaths) {
      if (!p.startsWith(prefix)) continue;
      final close = p.indexOf(']', prefix.length);
      if (close < 0) continue;
      final n = int.tryParse(p.substring(prefix.length, close));
      if (n != null) idx.add(n);
    }
    return idx.toList()..sort();
  }

  bool _isContainer(String childPath) =>
      _allPaths.contains(childPath) ||
      _allPaths.any((p) => p.startsWith('$childPath.') || p.startsWith('$childPath['));

  /// Immediate child member names of [path] discovered from the path set —
  /// catches container members (e.g. a step's `SData`) implied only by a deeper
  /// section and not listed in the object's own DEF/value members.
  List<String> _discoveredChildren(String path) {
    final prefix = '$path.';
    final seen = <String>{};
    final order = <String>[];
    for (final p in _allPaths) {
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

  // Cache of inherited member subtrees keyed by their type-default path, so a
  // type's defaults (e.g. Action.TS) are built once, not per instance.
  final Map<String, SeqProperty> _inheritCache = {};

  /// Splits a member's declared type string into (className, typeName). A
  /// `"TYPE, X"` reference is a typed object of type X (className null, typeName
  /// X); anything else is a plain value-kind (className = it, typeName null).
  (String?, String?) _memberType(String? raw) {
    final t = _unquote(raw);
    if (t == null) return (null, null);
    if (t.startsWith('TYPE, ')) return (null, t.substring(6).trim());
    return (t, null);
  }

  /// The attribute key under which an instance-override marker is stored on a
  /// built [SeqProperty] (see [SeqProperty.isInstanceOverride]).
  static const instOverrideAttr = '%INSTOVRD';

  /// The attribute key under which a property's type-level **PropertyFlags**
  /// bitmask is stored on a built [SeqProperty] (see [SeqProperty.propertyFlags]).
  /// Sourced from the `%FLG: <member>` directive on the owning object's section.
  static const flagsAttr = '%FLG';

  /// The attribute key under which an object's free-text comment is stored on a
  /// built [SeqProperty] (the editor's per-step/per-object note). Sourced from
  /// the `%COMMENT` directive; stored unquoted.
  static const commentAttr = '%COMMENT';

  SeqProperty build(
    String path,
    String displayName,
    String? declaredType, [
    String? declaredTypeName,
    Set<String>? visiting,
    Map<String, String> ownAttributes = const {},
  ]) {
    visiting ??= <String>{};
    final def = _defs[path];
    final val = _vals[path];
    final name = _unquote(val?.directives['%NAME']) ??
        _unquote(def?.directives['%NAME']) ??
        displayName;
    // Instance overrides. `%INSTOVRD: <member> = <flags>` in a value section marks
    // a member this object overrides relative to its base type; a bare
    // `%INSTOVRD = <flags>` marks the whole object. The flags are a bitmask we
    // don't fully decode yet; presence is the signal. Preserved as an attribute.
    String? ovrOf(String m) => val?.directives['$instOverrideAttr: $m'];
    // Type-level PropertyFlags. `%FLG: <member> = <bitmask>` records the member's
    // fixed property options (it is ~constant per property name across the corpus,
    // so it encodes the property's type, not instance data). We keep the bitmask
    // verbatim; individual bit meanings are not yet decoded. Found on the owning
    // object's value or DEF section.
    String? flgOf(String m) =>
        val?.directives['$flagsAttr: $m'] ?? def?.directives['$flagsAttr: $m'];
    Map<String, String> memberAttrs(String m) {
      final ovr = ovrOf(m), flg = flgOf(m);
      if (ovr == null && flg == null) return const {};
      return {
        if (ovr != null) instOverrideAttr: ovr,
        if (flg != null) flagsAttr: flg,
      };
    }
    // Type inheritance. A typed object (e.g. a step of type "Action") declares
    // its member *types* in its `[DEF, <Type>]`; the instance stores only the
    // members/values it overrides. So the type def supplies (a) member type
    // declarations the instance omits — even for members the instance only
    // implies via a deeper section, like a step's `TS` whose type lives in the
    // step type def — and (b) whole members the instance never mentions, whose
    // values come from the type's own default subtree. Bounded against type
    // cycles by [visiting]; inherited default subtrees are cached.
    final typeRoot = (declaredTypeName != null &&
            declaredTypeName != path &&
            _defs.containsKey(declaredTypeName))
        ? declaredTypeName
        : null;
    final inheritGuard = typeRoot != null && visiting.add(typeRoot);
    final typeDefMembers = (typeRoot != null && inheritGuard)
        ? _defs[typeRoot]!.members
        : const <String, String>{};
    // The member's declared type: instance declaration wins over the type def's.
    String? memberTypeOf(String m) => def?.members[m] ?? typeDefMembers[m];

    // Member order: instance DEF declarations first (authoritative + typed),
    // then value-only members, then members implied by deeper sections, and
    // finally members the object inherits from its type but never mentions.
    final memberOrder = <String>[...(def?.members.keys ?? const <String>[])];
    final seen = memberOrder.toSet();
    for (final m in (val?.members.keys ?? const <String>[])) {
      if (seen.add(m)) memberOrder.add(m);
    }
    for (final m in _discoveredChildren(path)) {
      if (seen.add(m)) memberOrder.add(m);
    }
    for (final m in typeDefMembers.keys) {
      if (seen.add(m)) memberOrder.add(m);
    }

    final subs = <SeqProperty>[];
    for (final m in memberOrder) {
      final (cls, tn) = _memberType(memberTypeOf(m));
      final instPath = '$path.$m';
      final typePath = typeRoot == null ? null : '$typeRoot.$m';
      final elems = _elementIndices(instPath);
      if (elems.isNotEmpty) {
        // An array member: build each element object in index order. The element
        // class (%[i]) and TestStand type (%TYPE: %[i]) are declared in the
        // array's own DEF section (e.g. `%[0] = Step`, `%TYPE: %[0] = "Action"`).
        final arrDef = _defs[instPath];
        final arr = [
          for (final i in elems)
            build(
              '$instPath[$i]',
              '[$i]',
              arrDef?.directives['%[$i]'],
              _unquote(arrDef?.directives['%TYPE: %[$i]']),
              visiting,
            ),
        ];
        subs.add(SeqProperty(
            name: m, className: cls, array: arr, attributes: memberAttrs(m)));
      } else if (_isContainer(instPath)) {
        // The instance has this container: build it (and let it inherit its own
        // type's defaults via the typeName we pass down).
        subs.add(build(instPath, m, cls, tn, visiting, memberAttrs(m)));
      } else if (typePath != null && _isContainer(typePath)) {
        // Inherited-only container: take the type's default subtree (cached). The
        // instance is silent here, so it carries no override marker.
        subs.add(_inheritCache[typePath] ??= build(typePath, m, cls, tn, visiting));
      } else {
        // Scalar leaf: instance value wins, else the type default value.
        subs.add(SeqProperty(
          name: m,
          className: cls,
          typeName: tn,
          scalar: _unquote(val?.members[m]) ??
              (typeRoot == null ? null : _unquote(_vals[typeRoot]?.members[m])),
          attributes: memberAttrs(m),
        ));
      }
    }
    if (inheritGuard) visiting.remove(typeRoot);

    // The object's own attributes: any passed-in override marker (from its
    // parent's `%INSTOVRD: <thisMember>`) plus a bare `%INSTOVRD` on its section.
    final attrs = <String, String>{...ownAttributes};
    final bareOvr =
        val?.directives[instOverrideAttr] ?? def?.directives[instOverrideAttr];
    if (bareOvr != null) attrs[instOverrideAttr] = bareOvr;
    // Free-text comment (`%COMMENT`): the editor's per-object note. Long comments
    // arrive pre-joined from continuation fragments. Stored unquoted; absent or
    // empty comments carry no attribute.
    final comment =
        _unquote(val?.directives[commentAttr] ?? def?.directives[commentAttr]);
    if (comment != null && comment.isNotEmpty) attrs[commentAttr] = comment;

    return SeqProperty(
      name: name,
      className: declaredType,
      typeName: declaredTypeName,
      attributes: attrs,
      subProps: subs,
    );
  }
}

/// Parses a legacy INI `.seq` into a [SeqFile] so the shared typed lens
/// ([SeqFile.sequences] / [Sequence] / [Step]) works on it. The data tree comes
/// from [iniDataTree] and the type list from [iniTypes]. Throws [FormatException]
/// if the data root cannot be reconstructed (e.g. a file lacking `%OBJROOT`).
SeqFile parseIniSeqFile(Uint8List bytes) {
  final doc = parseIniSeqBytes(bytes);
  final data = iniDataTree(doc);
  if (data == null) {
    throw const FormatException(
      'INI .seq has no reconstructable %OBJROOT data root (not yet decoded)',
    );
  }
  return SeqFile(header: doc.header, types: iniTypes(doc), data: data);
}

/// Strips one layer of surrounding double quotes, if present, and decodes the
/// C-style escapes TestStand writes *inside* a quoted value (see [_unescapeIni]).
/// Returns null for a null input.
String? _unquote(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    return _unescapeIni(t.substring(1, t.length - 1));
  }
  return t;
}

/// Decodes the C-style escapes TestStand writes inside a *quoted* INI value:
/// `\\`→`\`, `\"`→`"`, `\n`→newline, `\t`→tab, `\r`→CR. NI always doubles a
/// literal backslash (`\\`) — verified across the corpus, where the only escape
/// targets seen are `" n t r \` — so a lone `\n` unambiguously means a newline,
/// not a path separator. This brings INI string scalars in line with the XML
/// form (which uses XML entities) so both decode to the same logical text — e.g.
/// the expression `Locals.M != \"S001\"` reads as `Locals.M != "S001"`.
/// Processed left-to-right, consuming each pair; an unrecognized `\x` (none seen
/// in the corpus) is kept verbatim, defensively. Only called on quoted values,
/// so unquoted bare tokens (numbers, enums) are never touched.
String _unescapeIni(String s) {
  if (!s.contains(r'\')) return s; // fast path — most values carry no escapes
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (s[i] == r'\' && i + 1 < s.length) {
      final decoded = switch (s[i + 1]) {
        r'\' => r'\',
        '"' => '"',
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        _ => null,
      };
      if (decoded != null) {
        b.write(decoded);
        i++; // consume the escaped char
        continue;
      }
    }
    b.write(s[i]);
  }
  return b.toString();
}
