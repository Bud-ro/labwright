import 'dart:convert';
import 'dart:typed_data';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_property.dart';
import 'seq_step.dart';

/// Reader for the **legacy INI** `.seq` encoding (TestStand 3.x–era; some newer
/// installs still emit it). It is a *plaintext* serialization of the **same
/// PropertyObject model** the binary `TOF1` and the XML forms encode, which makes
/// it a readable Rosetta for the binary record tree.
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

/// One `key = value` line of an INI section, VERBATIM: [key] is the full
/// left-hand side (member name or `%`-directive), [rawValue] is the exact text
/// after the ` = ` separator — quoting and C-style escapes intact, `KEY LineNNNN`
/// continuation fragments already rejoined (see `_reassembleEntryList`). The
/// ordered entry list is a section's writing source of truth: members and
/// directives INTERLEAVE freely in real files (e.g. `LoadOpt = "..."`
/// immediately followed by `%FLG: LoadOpt = ...`; 7184 corpus sections
/// interleave), which the split [IniSection.members]/[IniSection.directives]
/// maps cannot represent.
class IniEntry {
  const IniEntry(this.key, this.rawValue);

  /// The full left-hand side: a member name (`Version`), a bare directive
  /// (`%NAME`), or a scoped directive (`%FLG: Seq`).
  final String key;

  /// The exact right-hand side text: quoted values keep their quotes and
  /// escapes (`"0.0.0.0"`, `"a\nb"`), bare tokens stay bare (`4194304`).
  final String rawValue;

  /// True when the entry is a `%`-directive rather than a plain member.
  bool get isDirective => key.startsWith('%');

  @override
  String toString() => 'IniEntry($key = $rawValue)';
}

/// One `[...]` block of an INI `.seq`: a value instance (`[path]`), a type
/// definition (`[DEF, path]`), or an external-adapter data blob
/// (`[EXTDATA, path, KIND]`, see [extDataKind]).
class IniSection {
  IniSection({
    required this.isDef,
    required this.path,
    required this.entries,
    this.extDataKind,
  }) : members = _selectEntries(entries, directives: false),
       directives = _selectEntries(entries, directives: true);

  /// True for a `[DEF, path]` section (member→type declarations); false for a
  /// `[path]` value instance (member→value).
  final bool isDef;

  /// The object path, e.g. `SF`, `SF.Seq[0]`, or the root alias `%OBJROOT`.
  final String path;

  /// For an `[EXTDATA, path, KIND]` section: the adapter-data kind token —
  /// corpus-observed kinds are `STRUCT`, `CLUST`, `DNSTRUCT`, `BLVCLUSTER`
  /// (per-adapter representations of the property at [path]). null for value
  /// and DEF sections. EXTDATA sections are kept reachable here but are NOT
  /// part of the property-object data tree ([iniDataTree] skips them); wiring
  /// them into [SeqProperty] is TODO (writer milestone).
  final String? extDataKind;

  /// True for an `[EXTDATA, path, KIND]` section.
  bool get isExtData => extDataKind != null;

  /// EVERY `key = value` line of the section in DOCUMENT ORDER, members and
  /// directives interleaved exactly as on disk, values verbatim (continuation
  /// fragments rejoined). The writer's source of truth; [members] and
  /// [directives] are derived indexes over it.
  final List<IniEntry> entries;

  /// Plain `member = value` (value section) or `member = TypeName` (DEF section)
  /// lines, excluding the `%`-directives. Insertion order preserved. Derived
  /// from [entries] (a duplicate key — unobserved in the corpus — keeps the
  /// last occurrence here; [entries] retains all).
  final Map<String, String> members;

  /// The `%`-directives, keyed by their full left-hand side, e.g.
  /// `%NAME`, `%FLG: Seq`, `%HI: Main`, `%TYPE: %[0]`, `%[0]`. Derived from
  /// [entries] like [members].
  final Map<String, String> directives;

  /// This object's display name (`%NAME = "..."`), unquoted, or null.
  String? get name => _unquote(directives['%NAME']);

  @override
  String toString() =>
      'IniSection(${isDef ? 'DEF ' : ''}$path, ${members.length} members, '
      '${directives.length} directives)';

  /// Splits [entries] into the member/directive index for the derived maps.
  static Map<String, String> _selectEntries(List<IniEntry> entries, {required bool directives}) => {
    for (final e in entries)
      if (e.isDirective == directives) e.key: e.rawValue,
  };
}

/// A parsed legacy INI `.seq`: its header plus every section in document order.
class IniSeqFile {
  IniSeqFile({
    required this.header,
    required this.headerFields,
    required this.sections,
    this.lineTerminator = '\n',
  });

  /// Header recovered from `[__Header__]` (format [SeqFormat.ini]).
  final SeqFileHeader header;

  /// EVERY `[__Header__]` field verbatim (key → raw value, insertion order),
  /// beyond the few [header] surfaces — e.g. `Path`, `ProductVersion`.
  /// Continuation lines (`Path Line0001` …) are reassembled the same way as
  /// section values. Header keys are unique across the corpus, so the ordered
  /// map is a faithful record of the header block.
  final Map<String, String> headerFields;

  /// The file's line terminator, replayed verbatim by the writer. Corpus:
  /// 57/58 files use `\n`; exactly one (`KernelTestSequence.seq`) uses `\r\n`;
  /// none mix terminators.
  final String lineTerminator;

  /// All `[...]` / `[DEF, ...]` / `[EXTDATA, ...]` sections in order (header
  /// section excluded).
  final List<IniSection> sections;

  /// The `[EXTDATA, path, KIND]` sections, in document order — external
  /// adapter data blobs, kept reachable but not part of the data tree.
  Iterable<IniSection> get extDataSections => sections.where((s) => s.isExtData);
}

/// Parses [bytes] of a legacy INI `.seq`. INI files are single-byte (SBCS), so
/// the bytes are decoded as Latin-1 to avoid choking on non-ASCII in comments.
IniSeqFile parseIniSeqBytes(Uint8List bytes) => parseIniSeq(latin1.decode(bytes, allowInvalid: true));

/// Parses the text of a legacy INI `.seq` into its header and sections.
IniSeqFile parseIniSeq(String text) {
  final headerEntries = <IniEntry>[];
  final rawSections = <_RawSection>[];

  bool inHeader = false;
  _RawSection? current;

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
      var path = isDef ? inner.substring('DEF,'.length).trim() : inner;
      String? extDataKind;
      if (!isDef && inner.startsWith('EXTDATA,')) {
        // `[EXTDATA, <path>, <KIND>]` — always exactly three comma-separated
        // parts across the corpus (1829 sections). A malformed header lacking
        // the kind comma (unobserved) stays a plain value section, defensively.
        final rest = inner.substring('EXTDATA,'.length);
        final kindComma = rest.lastIndexOf(',');
        if (kindComma >= 0) {
          path = rest.substring(0, kindComma).trim();
          extDataKind = rest.substring(kindComma + 1).trim();
        }
      }
      current = _RawSection(isDef: isDef, path: path, extDataKind: extDataKind);
      rawSections.add(current);
      continue;
    }
    final eq = line.indexOf(' = ');
    // Purely defensive: no corpus INI section line lacks a ' = ' separator
    // (verified corpus-wide and guarded by a corpus test).
    if (eq < 0) continue;
    final key = line.substring(0, eq).trim();
    final value = line.substring(eq + ' = '.length);
    if (inHeader) {
      headerEntries.add(IniEntry(key, value));
    } else if (current != null) {
      current.entries.add(IniEntry(key, value));
    }
  }
  // Values split across `KEY LineNNNN` continuation lines (header fields and
  // section entries alike) are rejoined in place, at the first fragment's
  // document position.
  final headerFields = <String, String>{
    for (final e in _reassembleEntryList(headerEntries)) e.key: e.rawValue,
  };
  return IniSeqFile(
    header: _headerFrom(headerFields),
    headerFields: headerFields,
    sections: [
      for (final raw in rawSections)
        IniSection(
          isDef: raw.isDef,
          path: raw.path,
          entries: _reassembleEntryList(raw.entries),
          extDataKind: raw.extDataKind,
        ),
    ],
    // The corpus never mixes terminators within one file (57 pure-LF, 1 pure
    // CRLF), so one sniff classifies the whole file.
    lineTerminator: text.contains('\r\n') ? '\r\n' : '\n',
  );
}

/// Parser scratch for a section whose entries are still accumulating (the
/// public [IniSection] derives its member/directive indexes at construction,
/// so it wants the final, continuation-rejoined entry list).
class _RawSection {
  _RawSection({required this.isDef, required this.path, required this.extDataKind});

  final bool isDef;
  final String path;
  final String? extDataKind;
  final List<IniEntry> entries = [];
}

/// Matches a continuation key: a base key plus a 4-digit ` LineNNNN` suffix.
final _continuationKey = RegExp(r'^(.+) Line(\d+)$');

/// Reassembles split long values in an ordered [entries] list (a section's
/// lines or the header block's), returning a new list with each fragment group
/// collapsed into one entry at the FIRST fragment's position.
///
/// NI splits a quoted value whose inner (escaped) text exceeds 120 characters
/// across continuation lines named `KEY Line0001`, `KEY Line0002`, … — the base
/// key with a ` LineNNNN` suffix — each holding a separately-quoted 120-char
/// fragment of the escaped text (the last holds the 1–120-char remainder; an
/// exact multiple of 120 ends with a full 120-char fragment, never an empty
/// one). The chunking is escape-BLIND: a `\"`/`\\` pair may straddle a fragment
/// boundary, so fragments are rejoined on the raw escaped text, never unescaped
/// individually. This rejoins them, in numeric order, into the single base key
/// `KEY` whose value is the fragments' inner text concatenated with no
/// separator and rewrapped in one pair of quotes. Verified across the full
/// corpus (19820 fragments in 1925 groups: all quoted, all contiguous from
/// 0001, document-adjacent, never coexisting with a bare base key; every
/// non-final fragment inner exactly 120 chars; no unsplit quoted inner exceeds
/// 120; the longest bare value is 23 chars). Single-line values, which never
/// match the suffix, are left untouched. The inverse split lives in the writer
/// (`writeIniSeq`).
List<IniEntry> _reassembleEntryList(List<IniEntry> entries) {
  Map<String, List<(int, String)>>? groups;
  for (final entry in entries) {
    final match = _continuationKey.firstMatch(entry.key);
    if (match == null) continue;
    (groups ??= {}).putIfAbsent(match.group(1)!, () => []).add((int.parse(match.group(2)!), entry.rawValue));
  }
  if (groups == null) return entries;
  final rebuilt = <IniEntry>[];
  final joined = <String>{};
  for (final entry in entries) {
    final match = _continuationKey.firstMatch(entry.key);
    if (match == null) {
      rebuilt.add(entry);
      continue;
    }
    final base = match.group(1)!;
    if (joined.add(base)) {
      final frags = groups[base]!..sort((a, b) => a.$1.compareTo(b.$1));
      rebuilt.add(IniEntry(base, _joinFragments(frags.map((f) => f.$2))));
    }
  }
  return rebuilt;
}

/// Joins quoted continuation [fragments] into one value: strips each fragment's
/// surrounding quotes, concatenates the inner text in order, and rewraps in a
/// single pair of quotes. A fragment lacking surrounding quotes is concatenated
/// verbatim (unobserved in the corpus, handled defensively); the joined value
/// stays quoted as long as any fragment was.
String _joinFragments(Iterable<String> fragments) {
  final buf = StringBuffer();
  var anyQuoted = false;
  for (final fragment in fragments) {
    final trimmed = fragment.trim();
    if (_isQuoted(trimmed)) {
      anyQuoted = true;
      buf.write(trimmed.substring(1, trimmed.length - 1));
    } else {
      buf.write(fragment);
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
  fileVersion: h['Version'],
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
  final builder = _IniBuilder(doc);
  final rootPath = builder.dataRootPath();
  return rootPath == null ? null : builder.build(rootPath, 'Data', 'SequenceFileData');
}

/// Reconstructs the type list (`[%TYPES]`) of a parsed INI `.seq` into
/// [SeqProperty] objects — the INI analogue of XML's `<typelist>`. Each entry of
/// the `[%TYPES]` section names a top-level type defined by its own
/// `[DEF, <Type>]`/`[<Type>]` sections. A `[%TYPES]` member VALUE is only the
/// quoted display name (always equal to the member key across the corpus, 2242
/// entries); the type's CLASS comes from the root alias DEF (`[DEF, %OBJROOT]`
/// / `[DEF, %OBJECTS]`, e.g. `Action = StepType`, `TEInf = Obj`) — the same
/// classname the XML flavor puts on its typedef root. Every corpus `[%TYPES]`
/// entry resolves there; a missing one (unobserved) yields a null className.
/// Returns an empty list if `[%TYPES]` is absent.
List<SeqProperty> iniTypes(IniSeqFile doc) {
  final builder = _IniBuilder(doc);
  final typeList = doc.sections.where((s) => !s.isDef && !s.isExtData && s.path == '%TYPES').firstOrNull;
  if (typeList == null) return const [];
  return [
    for (final typeName in typeList.members.keys)
      if (builder.hasPath(typeName)) builder.build(typeName, typeName, builder.rootAliasClass(typeName)),
  ];
}

/// Builds [SeqProperty] objects from an INI `.seq`'s path-addressed sections.
class _IniBuilder {
  _IniBuilder(IniSeqFile doc) {
    for (final section in doc.sections) {
      // EXTDATA sections are adapter data blobs, not property-object value
      // sections — indexing them would alias real property paths (their path
      // component reuses object paths like `Error.Code`) and pollute the path
      // index. They stay reachable on IniSeqFile.extDataSections.
      if (section.isExtData) continue;
      (section.isDef ? _defs : _vals)[section.path] = section;
    }
    _allPaths = {..._defs.keys, ..._vals.keys};
    _indexPaths();
  }

  final Map<String, IniSection> _defs = {};
  final Map<String, IniSection> _vals = {};
  late final Set<String> _allPaths;

  final Map<String, List<String>> _memberChildren = {};
  final Map<String, Set<String>> _memberChildSeen = {};
  final Map<String, List<int>> _elemIdx = {};

  /// Single pass over [_allPaths]: for every path, register each immediate
  /// `parent.member` and `parent[index]` edge against its parent. A path's member
  /// segments are separated by `.`; array elements by `[n]`. For each container
  /// path this records its immediate member-name children (first-seen order) and
  /// its array element indices. Built once so per-node child lookups are
  /// O(children) instead of re-scanning every path (which made [build] O(paths²)).
  void _indexPaths() {
    final elemSets = <String, Set<int>>{};
    for (final path in _allPaths) {
      final pathLength = path.length;
      var i = 0;
      while (i < pathLength && path[i] != '.' && path[i] != '[') {
        i++;
      }
      while (i < pathLength) {
        final anc = path.substring(0, i);
        if (path[i] == '.') {
          var j = i + 1;
          while (j < pathLength && path[j] != '.' && path[j] != '[') {
            j++;
          }
          if (j > i + 1) {
            final seg = path.substring(i + 1, j);
            final seen = _memberChildSeen[anc] ??= <String>{};
            if (seen.add(seg)) (_memberChildren[anc] ??= <String>[]).add(seg);
          }
          i = j;
        } else {
          var j = i + 1;
          while (j < pathLength && path[j] != ']') {
            j++;
          }
          if (j < pathLength) {
            final idx = int.tryParse(path.substring(i + 1, j));
            if (idx != null) (elemSets[anc] ??= <int>{}).add(idx);
            i = j + 1;
          } else {
            i = pathLength;
          }
        }
      }
    }
    elemSets.forEach((k, v) => _elemIdx[k] = v.toList()..sort());
  }

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
      for (final member in root.members.entries) {
        if (member.value == 'SequenceFileData') return member.key;
      }
    }
    return null;
  }

  /// The declared CLASS of a top-level object [name] from the root alias DEF
  /// (`SF = SequenceFileData`, `Action = StepType`, `TEInf = Obj`, …), or null
  /// when no root alias declares it (unobserved for `[%TYPES]` entries: all
  /// 2242 across the corpus resolve here).
  String? rootAliasClass(String name) {
    for (final alias in _rootAliases) {
      final declared = _defs[alias]?.members[name];
      if (declared != null) return _unquote(declared);
    }
    return null;
  }

  /// Distinct array indices present under a child path C (keys "C[0]", "C[1]"…),
  /// sorted ascending. Sourced from the prebuilt index.
  List<int> _elementIndices(String childPath) => _elemIdx[childPath] ?? const <int>[];

  bool _isContainer(String childPath) =>
      _allPaths.contains(childPath) || _memberChildren.containsKey(childPath) || _elemIdx.containsKey(childPath);

  /// Immediate child member names of [path] discovered from the path set —
  /// catches container members (e.g. a step's `SData`) implied only by a deeper
  /// section and not listed in the object's own DEF/value members. Sourced from
  /// the prebuilt index (first-seen order preserved).
  List<String> _discoveredChildren(String path) => _memberChildren[path] ?? const <String>[];

  /// Cache of inherited (type-default) member subtrees. The key is the type
  /// path PLUS the active recursion-guard set ([build]'s `visiting`): the guard
  /// truncates inheritance when a type is already being expanded, so the same
  /// type path can legitimately build to a DIFFERENT subtree under a different
  /// guard state — a bare-path key would leak a truncated build into contexts
  /// that deserve the full one (or vice versa).
  ///
  /// ALIASING INVARIANT: a cache hit shares ONE [SeqProperty] instance across
  /// every inheriting parent. That is safe only because the built model is
  /// immutable (all fields final, never mutated after construction); any future
  /// mutable decoration of the tree must clone instead of alias.
  final Map<String, SeqProperty> _inheritCache = {};

  /// The sound cache key for an inherited [typePath] built under [visiting] —
  /// the path alone when no guard is active, else the path plus the guard set
  /// in sorted (order-insensitive) form. Typical repeated builds (e.g. every
  /// `Action` step inheriting `Action.TS`) share identical guard states, so
  /// caching still collapses them.
  static String _inheritKey(String typePath, Set<String> visiting) =>
      visiting.isEmpty ? typePath : '$typePath|${(visiting.toList()..sort()).join('|')}';

  /// Splits a member's declared type string into (className, typeName). A
  /// `"TYPE, X"` reference is a typed object of type X (className null, typeName
  /// X); anything else is a plain value-kind (className = it, typeName null).
  (String?, String?) _memberType(String? raw) {
    final text = _unquote(raw);
    if (text == null) return (null, null);
    if (text.startsWith('TYPE, ')) return (null, text.substring('TYPE, '.length).trim());
    return (text, null);
  }

  /// The attribute key under which an instance-override marker is stored on a
  /// built [SeqProperty] (see [SeqProperty.isInstanceOverride]).
  static const instOverrideAttr = '%INSTOVRD';

  /// The attribute key under which a property's type-level **PropertyFlags**
  /// bitmask is stored on a built [SeqProperty] (see [SeqProperty.propertyFlags]).
  /// Sourced from the `%FLG: <member>` directive on the owning object's section.
  static const flagsAttr = '%FLG';

  /// The attribute key under which a member's declared array high-index
  /// bounds are stored (`%HI: <member> = [63]`) — see
  /// [SeqProperty.highIndices].
  static const highIndexAttr = '%HI';

  /// The attribute key under which a member's declared array LOW-index
  /// bounds are stored (`%LO: <member> = [1]`) — see
  /// [SeqProperty.lowIndices]. Nonzero low bounds are corpus-real
  /// (`%LO: ColumnList = [1]` + `%HI: ColumnList = [2]` — 2 elements).
  static const lowIndexAttr = '%LO';

  /// The attribute key under which a property's INSTANCE-level flags bitmask
  /// is stored, from the `%INSTFLG: <member>` / bare own-section `%INSTFLG`
  /// directives (18k+ corpus lines). Kept verbatim; bit meanings are **not
  /// yet decoded** (distinct from the type-level [flagsAttr] mask and from
  /// the override marker [instOverrideAttr]).
  static const instFlagsAttr = '%INSTFLG';

  /// The attribute key under which an array's ELEMENT prototype type is
  /// stored (a bare `%EPTYPE = TEResult` directive on the array's own
  /// section) — the type every default element instantiates.
  static const elementTypeAttr = '%EPTYPE';

  /// The attribute key under which an object's free-text comment is stored on a
  /// built [SeqProperty] (the editor's per-step/per-object note). Sourced from
  /// the `%COMMENT` directive; stored unquoted.
  static const commentAttr = '%COMMENT';

  /// Builds the property node for a section, producing members in a
  /// deterministic order: instance `DEF` declarations first (authoritative +
  /// typed), then value-only members, then members implied by deeper sections,
  /// then members inherited from the type but never mentioned.
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
    final name = val?.name ?? def?.name ?? displayName;
    Map<String, String> memberAttrs(String memberName) {
      final ovr = val?.directives['$instOverrideAttr: $memberName'];
      final flg = val?.directives['$flagsAttr: $memberName'] ?? def?.directives['$flagsAttr: $memberName'];
      final instFlg = val?.directives['$instFlagsAttr: $memberName'] ?? def?.directives['$instFlagsAttr: $memberName'];
      final hi = val?.directives['$highIndexAttr: $memberName'] ?? def?.directives['$highIndexAttr: $memberName'];
      final lo = val?.directives['$lowIndexAttr: $memberName'] ?? def?.directives['$lowIndexAttr: $memberName'];
      return {
        if (ovr != null) instOverrideAttr: ovr,
        if (flg != null) flagsAttr: flg,
        if (instFlg != null) instFlagsAttr: instFlg,
        if (hi != null) highIndexAttr: hi,
        if (lo != null) lowIndexAttr: lo,
      };
    }

    final typeRoot = (declaredTypeName != null && declaredTypeName != path && _defs.containsKey(declaredTypeName))
        ? declaredTypeName
        : null;
    final inheritGuard = typeRoot != null && visiting.add(typeRoot);
    final typeDefMembers = inheritGuard ? _defs[typeRoot]!.members : const <String, String>{};
    String? memberTypeOf(String memberName) => def?.members[memberName] ?? typeDefMembers[memberName];

    final memberOrder = <String>{
      ...?def?.members.keys,
      ...?val?.members.keys,
      ..._discoveredChildren(path),
      ...typeDefMembers.keys,
    };

    final subs = <SeqProperty>[];
    for (final memberName in memberOrder) {
      final (className, typeName) = _memberType(memberTypeOf(memberName));
      final instPath = '$path.$memberName';
      final typePath = typeRoot == null ? null : '$typeRoot.$memberName';
      final elems = _elementIndices(instPath);
      if (elems.isNotEmpty) {
        final arrDef = _defs[instPath];
        final arr = [
          for (final item in elems)
            build(
              '$instPath[$item]',
              '[$item]',
              arrDef?.directives['%[$item]'],
              _unquote(arrDef?.directives['%TYPE: %[$item]']),
              visiting,
            ),
        ];
        subs.add(SeqProperty(name: memberName, className: className, array: arr, attributes: memberAttrs(memberName)));
      } else if (_isContainer(instPath)) {
        subs.add(build(instPath, memberName, className, typeName, visiting, memberAttrs(memberName)));
      } else if (typePath != null && _isContainer(typePath)) {
        subs.add(
          _inheritCache[_inheritKey(typePath, visiting)] ??= build(typePath, memberName, className, typeName, visiting),
        );
      } else {
        subs.add(
          SeqProperty(
            name: memberName,
            className: className,
            typeName: typeName,
            scalar:
                _unquote(val?.members[memberName]) ??
                (typeRoot == null ? null : _unquote(_vals[typeRoot]?.members[memberName])),
            attributes: memberAttrs(memberName),
          ),
        );
      }
    }
    if (inheritGuard) visiting.remove(typeRoot);

    final bareOvr = val?.directives[instOverrideAttr] ?? def?.directives[instOverrideAttr];
    // Bare own-section flag masks (`%FLG = N`, `%INSTFLG = N` — value sections
    // only across the corpus, and never coexisting with the member form on the
    // owning parent) are retained under the same literal keys as the member
    // form, so a property's flags read the same either way.
    final bareFlg = val?.directives[flagsAttr] ?? def?.directives[flagsAttr];
    final bareInstFlg = val?.directives[instFlagsAttr] ?? def?.directives[instFlagsAttr];
    final comment = _unquote(val?.directives[commentAttr] ?? def?.directives[commentAttr]);
    final elementType = _unquote(val?.directives[elementTypeAttr] ?? def?.directives[elementTypeAttr]);
    final attrs = <String, String>{
      ...ownAttributes,
      if (bareOvr != null) instOverrideAttr: bareOvr,
      if (bareFlg != null) flagsAttr: bareFlg,
      if (bareInstFlg != null) instFlagsAttr: bareInstFlg,
      if (comment != null && comment.isNotEmpty) commentAttr: comment,
      if (elementType != null && elementType.isNotEmpty) elementTypeAttr: elementType,
    };

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
  final trimmed = s.trim();
  return _isQuoted(trimmed) ? _unescapeIni(trimmed.substring(1, trimmed.length - 1)) : trimmed;
}

/// True when [t] is surrounded by a matching pair of double quotes.
bool _isQuoted(String text) => text.length >= 2 && text.startsWith('"') && text.endsWith('"');

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
String _unescapeIni(String text) {
  if (!text.contains(r'\')) return text;
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (text[i] == r'\' && i + 1 < text.length) {
      final decoded = switch (text[i + 1]) {
        r'\' => r'\',
        '"' => '"',
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        _ => null,
      };
      if (decoded != null) {
        buffer.write(decoded);
        i++;
        continue;
      }
    }
    buffer.write(text[i]);
  }
  return buffer.toString();
}
