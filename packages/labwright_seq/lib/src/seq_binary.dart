import 'dart:io';
import 'dart:typed_data';

import 'seq_format.dart';

/// zlib stream first byte (CMF): deflate method, 32K window — the marker the
/// body scan keys on.
const _zlibCmf = 0x78;

/// Recognized zlib FLG second bytes (the byte after [_zlibCmf]) seen in TOF1
/// bodies — one documented catalog instead of scattered hex literals.
enum ZlibFlag {
  none(0x01),

  byDefault(0x9c),

  best(0xda);

  const ZlibFlag(this.byte);
  final int byte;

  static bool isKnown(int flagByte) =>
      flagByte == none.byte || flagByte == byDefault.byte || flagByte == best.byte;
}

/// Minimum inflated size to accept a candidate zlib stream as the body — guards
/// against tiny false-positive streams.
const _minInflatedBytes = 64;

/// `0xff` — the byte [_countSentinels] scans for as a `ff ff ff ff` dword. NOTE:
/// despite the legacy "sentinel" name, these are **not** record delimiters
/// (refuted across the corpus — see [BinaryBodyLayout.sentinelCount]); they are
/// `0xffffffff` all-ones *values* in the byte-packed records.
const _sentinelByte = 0xff;

/// Bytes per little-endian u32 word in the record region.
const _u32Bytes = 4;

/// Bytes per little-endian IEEE-754 double in the record region.
const _f64Bytes = 8;

/// Minimum printable-run length when scanning the body for strings.
const _minRunLength = 3;

/// Minimum printable-run length when reading the loose body/name pool (looser
/// than [_minRunLength], which frames the layout).
const _poolMinRunLength = 2;

/// The all-ones `u32` that separates object-record groups in the record region.
const _recordDelimiter = 0xffffffff;

/// Minimum runs in a NUL-adjacent chain to mark the record/string boundary.
const _boundaryChainMin = 5;

/// Minimum entries for [binaryStringTable] to return a table.
const _minTableEntries = 5;

/// Default minimum runs in a chain for [binaryStringSegments].
const _minSegmentChain = 2;

/// PropertyObject model NAME/type tokens NI's engine writes into every sequence
/// file — one documented catalog used to pick the **property-name table** out of
/// the packed string segments by content (it carries the most of these, where the
/// value/expression tables carry few or none). Not exhaustive; enough to identify
/// the name table reliably (matches in all 83 corpus binaries). The record
/// grammar that would label the tables directly is **not yet decoded**.
const _modelNameTokens = {
  'Sequence',
  'MainSequence',
  'SequenceFile',
  'Step',
  'StepType',
  'Locals',
  'Parameters',
};

/// The fixed PropertyObject **container scaffold** that opens a binary TOF1 name
/// table. The name table is the file's *ordered* string pool — the record region
/// references its entries by 0-based index — and for a standard sequence file it
/// always begins with these five entries: the root `SequenceFileData` object and
/// its `Data`/`Objs` array structure, then the first array element (`Seq`/`[0]`).
/// Corpus-verified: every binary file whose name table is rooted at
/// `SequenceFileData` (82/83 — the lone exception is a partial plugin file with
/// no file-data root) opens with exactly this prefix. Entries past index 4 are
/// the file's own sequences/objects and vary. The record grammar that consumes
/// these indices is still being decoded.
const binaryNameScaffold = ['SequenceFileData', 'Data', 'Objs', 'Seq', '[0]'];

/// How many leading record-region u32 words [analyzeBinaryBody] captures.
const _leadingWordCount = 3;

/// Locates and inflates the zlib-compressed body of a binary `TOF1` `.seq`.
///
/// Reconnaissance established (verified across the whole binary corpus) that a
/// TOF1 file is a plaintext header followed by a single zlib stream whose
/// inflated bytes hold the **same PropertyObject model** as the XML form (the
/// names `SequenceFileData`, `Sequence`, `MainSequence`, `Step`, `StepType`, …
/// appear in the clear inside it) — the direct analog of the VI heap's zlib
/// sections.
///
/// Returns the decompressed body, or null when [bytes] is not a binary TOF1 file
/// or no inflatable stream is found. Total over arbitrary input (never throws).
/// The body is *inflated* here but **not yet parsed** into the typed model — that
/// binary record grammar is the next milestone.
Uint8List? inflateBinaryBody(Uint8List bytes) {
  if (detectSeqFormat(bytes) != SeqFormat.binary) return null;
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] != _zlibCmf) continue;
    if (!ZlibFlag.isKnown(bytes[i + 1])) continue;
    try {
      // sublistView + identity check: neither the candidate tail nor the
      // inflated result is copied (zlib.decode already returns a Uint8List
      // in practice; a file-sized copy per parse adds up over corpus sweeps).
      final out = zlib.decode(Uint8List.sublistView(bytes, i));
      if (out.length > _minInflatedBytes) {
        return out is Uint8List ? out : Uint8List.fromList(out);
      }
    } catch (_) {
      // Keep scanning past a position that does not start a valid stream.
    }
  }
  return null;
}

/// Recovers the string/name pool from a binary TOF1 `.seq` — the inflated body's
/// NUL-terminated ASCII runs (property names, expressions, paths), each with its
/// offset into the inflated body.
///
/// Verified across the corpus: the inflated body packs the PropertyObject names
/// as NUL-terminated strings (a 0x00 sits before and after each run), so the key
/// model names (`Sequence`, `Step`, `Locals`, `Parameters`, `StepType`, …) are
/// recovered cleanly. This surfaces *what is in* a binary file even though the
/// record tree that links the names is **not yet parsed**. Returns `[]` when
/// [seqBytes] is not an inflatable binary file.
List<BinaryString> binaryBodyStrings(
  Uint8List seqBytes, {
  int minLength = _poolMinRunLength,
}) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return binaryStrings(body, minLength: minLength);
}

/// A recon framing of a binary TOF1 inflated body into its two regions: a
/// leading **record region** (little-endian u32 fields with `ff ff ff ff`
/// sentinels) followed by the **string region** (packed NUL-terminated tables
/// the records reference by index). Every field here is *honestly derivable*
/// from the bytes; the record grammar that links the two regions is **not yet
/// decoded**.
class BinaryBodyLayout {
  const BinaryBodyLayout({
    required this.inflatedSize,
    required this.recordRegionLength,
    required this.stringCount,
    required this.sentinelCount,
    required this.segmentCount,
    required this.leadingWords,
  });

  /// Total inflated-body size in bytes.
  final int inflatedSize;

  /// Bytes before the string region — i.e. the length of the leading record
  /// region. This boundary is the start of the first packed string table (a
  /// recon heuristic, not yet a byte-exact record-grammar boundary).
  final int recordRegionLength;

  /// Where the string region begins (== [recordRegionLength]).
  int get stringRegionOffset => recordRegionLength;

  /// Number of NUL-terminated printable runs in the string region.
  final int stringCount;

  /// Count of `ff ff ff ff` dwords (on 4-byte steps) within the record region.
  /// **Not a record delimiter** — refuted across the corpus: byte-granularity
  /// `ff ff ff ff` runs occur at all four byte phases ~uniformly (so they are not
  /// u32-aligned markers), they outnumber the named objects by ~14–310× (median
  /// 43×), and the u32 after a run is a valid name index only ~45% of the time.
  /// They are best explained as `0xffffffff` all-ones *values* (−1 / "not set"
  /// defaults) embedded in the byte-packed records. Kept as a descriptive count.
  final int sentinelCount;

  /// Number of distinct packed string tables (maximal NUL-adjacent run chains)
  /// in the string region. Corpus-observed: ≥6 in all 83 binary files.
  final int segmentCount;

  /// The first few little-endian u32 words at the start of the record region
  /// (descriptive). Corpus-observed invariants across all 83 binary files:
  /// `leadingWords[2] == 1` (a constant marker) and `leadingWords[1] ∈ {16, 118}`
  /// (0x10 / 0x76); and `leadingWords[0]` varies and is **not** a simple count.
  ///
  /// `leadingWords[1]` is a **record-prefix layout selector** — it deterministi-
  /// cally picks one of two serialization layouts for the scaffold prefix (82/82
  /// rooted files): with `0x76` the prefix runs `…1=Data, 2=Objs, _, 4=[0], _, _,
  /// 768`; with `0x10` it runs `…1=Data, _, _, 3=Seq, _, 0`. It is NOT the
  /// engine/save version (both cohorts span header versions 14/19/21), NOT the
  /// fileType (all SequenceFile), and NOT the source tool (the same repos produce
  /// both). The 0x76 layout also carries more string segments.
  // TODO: the *reason* a file uses one layout vs the other (e.g. a structure
  // sub-variant) and the meaning of leadingWords[0] are not yet determined.
  final List<int> leadingWords;

  @override
  String toString() =>
      'BinaryBodyLayout(inflated=$inflatedSize, '
      'recordRegion=$recordRegionLength, strings=$stringCount, '
      'segments=$segmentCount, sentinels=$sentinelCount, lead=$leadingWords)';
}

/// Frames the inflated body of a binary TOF1 `.seq` into a [BinaryBodyLayout]:
/// the leading record region and the trailing string region, with recon counts.
/// Returns null when [seqBytes] is not an inflatable binary file or no packed
/// string table is found.
///
/// Verified across the whole binary corpus: every file splits into a non-empty
/// record region followed by a string table of ≥5 entries. This is the framing
/// step toward decoding the record grammar — which is **not yet decoded**, so
/// this exposes *where* the records and strings live and *how many*, not their
/// meaning.
BinaryBodyLayout? analyzeBinaryBody(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  return _layoutFromBody(body);
}

BinaryBodyLayout? _layoutFromBody(Uint8List body) {
  final runs = binaryStrings(body, minLength: _minRunLength);
  final boundary = _firstTableOffset(runs);
  if (boundary == null) return null;
  final stringCount = runs.where((r) => r.offset >= boundary).length;
  return BinaryBodyLayout(
    inflatedSize: body.length,
    recordRegionLength: boundary,
    stringCount: stringCount,
    sentinelCount: _countSentinels(body, boundary),
    segmentCount: _segmentsFrom(runs, boundary).length,
    leadingWords: _leadingWords(body, _leadingWordCount),
  );
}

/// A packed string table in a binary TOF1 body: a maximal chain of
/// NUL-terminated runs (each starting one byte after the previous one's NUL),
/// with the offset of its first entry. Which table is which (property names vs
/// value/expression tables) is **not yet decoded**.
typedef BinaryStringSegment = ({int offset, List<BinaryString> entries});

/// Splits the string region of a binary TOF1 body into its packed tables — every
/// maximal NUL-adjacent run chain of ≥[minChain] entries, in order. Returns `[]`
/// when [seqBytes] is not an inflatable binary file or has no string region.
///
/// Where [binaryStringTable] returns only the single largest table, this returns
/// them all (corpus-observed: ≥6 segments in all 83 binary files). The record
/// grammar that references these by index is **not yet decoded**.
List<BinaryStringSegment> binaryStringSegments(
  Uint8List seqBytes, {
  int minChain = _minSegmentChain,
}) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return _segmentsFromBody(body, minChain: minChain);
}

List<BinaryStringSegment> _segmentsFromBody(
  Uint8List body, {
  int minChain = _minSegmentChain,
}) {
  final runs = binaryStrings(body, minLength: _minRunLength);
  final boundary = _firstTableOffset(runs);
  if (boundary == null) return const [];
  return [
    for (final chain in _segmentsFrom(runs, boundary, minChain: minChain))
      (offset: chain.first.offset, entries: chain),
  ];
}

/// Identifies the **property-name table** among a binary TOF1 body's packed
/// string segments — the segment carrying the PropertyObject NAME/type tokens
/// (`Sequence`, `Step`, `Locals`, …), as distinct from the value/expression
/// tables. Picked by *content* (the segment matching the most [_modelNameTokens],
/// earliest on a tie), which is the honest discriminator while the record grammar
/// that would label the tables is **not yet decoded**.
///
/// Corpus-observed across all 83 binary files: such a name table always exists
/// (83/83), always contains the core tokens, and is never the largest segment —
/// the value/expression tables are bigger. It is the *first* segment in 82/83
/// files (a strong tendency, not relied on here — selection is by content).
/// Returns null when [seqBytes] is not an inflatable binary file or no segment
/// carries model names.
BinaryStringSegment? binaryNameTable(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  return _nameTableFromSegments(_segmentsFromBody(body));
}

/// The property/object **names a binary TOF1 file defines**, beyond the fixed
/// container [binaryNameScaffold] — i.e. the file's own sequences, steps, locals,
/// and other named objects, in name-pool order.
///
/// These are genuinely **recovered names** (the ordered name pool the records
/// index); the record links that give them hierarchy and values are **not yet
/// decoded**, so this is a flat, honest name list — not a parsed tree. Drops the
/// leading scaffold prefix when present (rooted files), else returns the whole
/// pool. Returns `[]` when [seqBytes] is not an inflatable binary file.
List<String> binaryObjectNames(Uint8List seqBytes) {
  final table = binaryNameTable(seqBytes);
  if (table == null) return const [];
  return _objectNamesFrom([for (final entry in table.entries) entry.text]);
}

/// Drops the leading [binaryNameScaffold] prefix from an ordered name list.
List<String> _objectNamesFrom(List<String> names) {
  var start = 0;
  while (start < names.length &&
      start < binaryNameScaffold.length &&
      names[start] == binaryNameScaffold[start]) {
    start++;
  }
  return names.sublist(start);
}

/// Module call-target extensions a step's adapter binding points at — the same
/// LabVIEW/DLL/sequence/library targets the INI/XML lens recovers, here matched
/// in the binary string pool by suffix.
final _modulePathRe = RegExp(r'\.(vi|dll|seq|llb)$', caseSensitive: false);

/// Whether [s] looks like a **module call-target path** — a path-separated string
/// ending in a known adapter target extension (`.vi`/`.dll`/`.seq`/`.llb`), e.g.
/// `My Computer\ExcelReadWrite\Excel_Read.vi` or `SubSequences\AC_Gerilim.seq`.
/// A bare suffix (`.vi`) or a separator-less token is rejected.
bool isBinaryModulePath(String text) =>
    text.contains('\\') && _modulePathRe.hasMatch(text);

/// The **module call-target paths** a binary TOF1 file references — the LabVIEW
/// VIs / DLLs / sub-sequences / libraries its steps invoke (see
/// [isBinaryModulePath]), distinct and in name-pool order.
///
/// These are genuinely **recovered call targets** read straight from the string
/// pool: even though the record grammar that ties a path to its step is **not yet
/// decoded**, the targets themselves are honest data — *what* the sequence calls,
/// if not yet *from which step*. Corpus-observed: 190/288 binary files expose ≥1
/// (median 5); the rest either make no external calls or carry paths fragmented by
/// non-ASCII bytes in the run splitter. Returns `[]` when [seqBytes] is not an
/// inflatable binary file.
List<String> binaryModulePaths(Uint8List seqBytes) =>
    _poolWhere(seqBytes, isBinaryModulePath);

/// Distinct pool entries (in order) matching [keep], over a fresh inflate.
List<String> _poolWhere(Uint8List seqBytes, bool Function(String) keep) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return _poolWhereFrom(_segmentsFromBody(body), keep);
}

List<String> _poolWhereFrom(
  List<BinaryStringSegment> segments,
  bool Function(String) keep,
) {
  final seen = <String>{};
  final out = <String>[];
  for (final seg in segments) {
    for (final entry in seg.entries) {
      if (keep(entry.text) && seen.add(entry.text)) out.add(entry.text);
    }
  }
  return out;
}

/// The `ID#:` **step references** a binary TOF1 file carries — the unique step-ID
/// tokens the INI/XML lens resolves to step links. Distinct, in pool order.
///
/// Recovered verbatim (the same `ID#:<base64-ish>` form the text encodings use);
/// resolving each to its target step needs the **not yet decoded** record grammar.
/// Corpus-observed: 285/288 binary files expose ≥1. Returns `[]` when [seqBytes]
/// is not an inflatable binary file.
List<String> binaryStepReferences(Uint8List seqBytes) =>
    _poolWhere(seqBytes, _isStepRef);

bool _isStepRef(String text) => text.startsWith('ID#:');

/// Member access on a TestStand expression **root** (`Locals.x`, `Step.Result…`,
/// `RunState.LoopIndex`, `StationGlobals.…`, …) — the surest expression marker.
final _exprRootRe = RegExp(
    r'\b(Locals|Parameters|Step|RunState|FileGlobals|StationGlobals|Seq|ThisContext)\.');

/// A comparison / logical / ternary operator (the test-logic operators).
final _exprOpRe = RegExp(r'(==|!=|<=|>=|&&|\|\||\?.*:)');

/// A known TestStand expression **function call** (`Abs(`, `Str(`, `ResStr(`, …).
final _exprFnRe = RegExp(
    r'\b(Abs|Str|Val|Round|Mid|Len|Left|Right|ResStr|LocalizeExpression|Mod)\s*\(');

/// Whether [s] looks like a TestStand **expression** — the strings that carry a
/// sequence's actual logic: limit/condition comparisons, `RunState`/`Locals`/
/// `Step` member access, ternaries, and known expression-function calls. Module
/// paths ([isBinaryModulePath]) and `ID#:` step references are excluded so this
/// stays disjoint from those recoveries.
bool isBinaryExpression(String text) {
  if (text.startsWith('ID#:') || isBinaryModulePath(text)) return false;
  return _exprRootRe.hasMatch(text) ||
      _exprOpRe.hasMatch(text) ||
      _exprFnRe.hasMatch(text);
}

/// The **expression strings** a binary TOF1 file carries — its test logic
/// (conditions, limit/numeric expressions, name/description format expressions,
/// loop and result expressions; see [isBinaryExpression]), distinct and in
/// name-pool order.
///
/// Recovered straight from the string pool: the **not yet decoded** record grammar
/// is what would attach each expression to its specific step/field, so this is the
/// honest *set* of expressions a file evaluates, not a per-step mapping.
/// Corpus-observed: 285/288 binary files expose ≥1 (15910 distinct total). Returns
/// `[]` when [seqBytes] is not an inflatable binary file.
List<String> binaryExpressions(Uint8List seqBytes) =>
    _poolWhere(seqBytes, isBinaryExpression);

/// Whether [s] is a **quoted string literal** — a whole entry wrapped in double
/// quotes (`"6105A"`, `"Unnamed Entry Point"`, `"%ModuleDescription"`), i.e. a
/// constant value rather than an [isBinaryExpression] (a quoted entry that also
/// contains operators — `"a" == "b"` — is an expression, not a literal, and is
/// excluded here so the recoveries stay disjoint).
bool isBinaryQuotedLiteral(String text) =>
    text.length >= 2 &&
    text.startsWith('"') &&
    text.endsWith('"') &&
    !isBinaryExpression(text);

/// The **quoted string literals** a binary TOF1 file carries — constant values
/// its steps/expressions reference (instrument resource strings, expected values,
/// captions, …; see [isBinaryQuotedLiteral]), distinct and in name-pool order.
///
/// Recovered straight from the string pool; *which* literal a given step uses
/// needs the **not yet decoded** record grammar. Corpus-observed: 288/288 binary
/// files expose ≥1 (2883 distinct total). Returns `[]` when [seqBytes] is not an
/// inflatable binary file.
List<String> binaryQuotedLiterals(Uint8List seqBytes) =>
    _poolWhere(seqBytes, isBinaryQuotedLiteral);

BinaryStringSegment? _nameTableFromSegments(
  List<BinaryStringSegment> segments,
) {
  BinaryStringSegment? best;
  var bestHits = 0;
  for (final seg in segments) {
    final texts = {for (final entry in seg.entries) entry.text};
    final hits = _modelNameTokens.where(texts.contains).length;
    if (hits > bestHits) {
      bestHits = hits;
      best = seg;
    }
  }
  return best;
}

/// The record region of a binary TOF1 body as little-endian u32 words — the raw
/// record stream that precedes the string region.
///
/// The records reference [binaryNameTable] entries **by 0-based index**: a fresh
/// inflated body opens `[leadingWords[0], leadingWords[1], 1, …]` and the small
/// words that follow index the name pool (e.g. the constant `1` selects
/// `name[1] == 'Data'`, then `name[2] == 'Objs'`, … — the [binaryNameScaffold]
/// path). Indices are interleaved with binary field values, and the records are
/// **variable-length** (value payloads shift u32 alignment), so this is a decode
/// aid, **not** a flat index array — the full record grammar is **not yet
/// decoded**. Returns `[]` when [seqBytes] is not an inflatable binary file or
/// the body does not frame.
List<int> binaryRecordWords(Uint8List seqBytes) =>
    _withLayout(seqBytes, _recordWordsFromBody);

/// Inflates [seqBytes], frames its layout, and delegates to [f] over the body and
/// its record-region length — the shared inflate+frame+guard prologue for the
/// record-region readers. Returns `[]` when the file is not an inflatable binary
/// file or does not frame. (`const <Never>[]` is used because a bare `const []`
/// would try to infer the type parameter `T`, which is a compile error.)
List<T> _withLayout<T>(
  Uint8List seqBytes,
  List<T> Function(Uint8List body, int recordRegionLength) extract,
) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const <Never>[];
  final layout = _layoutFromBody(body);
  if (layout == null) return const <Never>[];
  return extract(body, layout.recordRegionLength);
}

List<int> _recordWordsFromBody(Uint8List body, int recordRegionLength) {
  final view = ByteData.sublistView(body);
  final out = <int>[];
  for (var i = 0; i + _u32Bytes <= recordRegionLength; i += _u32Bytes) {
    out.add(view.getUint32(i, Endian.little));
  }
  return out;
}

/// Lower bound on a recovered double's magnitude (smaller is treated as noise).
const _minScalarMagnitude = 1e-9;

/// Upper bound on a recovered double's magnitude (larger is treated as noise).
const _maxScalarMagnitude = 1e12;

/// The **inline scalar `double` values** a binary TOF1 file embeds in its record
/// region — genuinely recovered numeric data (e.g. step-TYPE parameter defaults /
/// numeric limits).
///
/// A named numeric property stores an 8-byte little-endian IEEE-754 `double` two
/// u32 words after its name reference — the record shape
/// `⟨tag⟩ ⟨name-offset⟩ ⟨type-code⟩ ⟨f64⟩` (verified on the Rosetta near-twins:
/// the same value set is byte-identical across the NIDmm/NIScope minimal
/// binaries). This recovers the *values*; tying each to its exact leaf property
/// needs the **not yet fully decoded** record grammar, so this is the honest value
/// *set* — distinct, in record order.
///
/// To suppress coincidental bit patterns it accepts only **clean** doubles: the
/// low 32 bits must be zero (a round value, as every observed default is), finite,
/// non-zero, and `|v|` within [[_minScalarMagnitude], [_maxScalarMagnitude]].
/// Returns `[]` when [seqBytes] is not an inflatable binary file or doesn't frame.
List<double> binaryScalarDoubles(Uint8List seqBytes) =>
    _withLayout(seqBytes, _scalarDoublesFromBody);

/// A **clean** recovered double: finite, non-zero, and `|v|` within
/// [[_minScalarMagnitude], [_maxScalarMagnitude]] — the shared acceptance filter
/// for [binaryScalarDoubles] and [binaryNamedScalarRecords].
bool _isCleanScalar(double value) {
  if (!value.isFinite || value == 0) return false;
  final magnitude = value.abs();
  return magnitude >= _minScalarMagnitude && magnitude <= _maxScalarMagnitude;
}

List<double> _scalarDoublesFromBody(Uint8List body, int recordRegionLength) {
  final view = ByteData.sublistView(body);
  final seen = <double>{};
  final out = <double>[];
  for (var i = 0; i + _f64Bytes <= recordRegionLength; i += _u32Bytes) {
    if ((body[i] | body[i + 1] | body[i + 2] | body[i + 3]) != 0) continue;
    final value = view.getFloat64(i, Endian.little);
    if (!_isCleanScalar(value)) continue;
    if (seen.add(value)) out.add(value);
  }
  return out;
}

/// One inline scalar `double` recovered from a **named-property record** in the
/// binary TOF1 record region — the value plus the structural context that ties it
/// to a property-name reference.
///
/// A numeric named property is stored as the record header
/// `⟨tag⟩ ⟨name-offset⟩ ⟨type-code⟩ ⟨f64⟩` (confirmed on the Rosetta near-twins):
/// the `name-offset` word is the string-region-relative byte offset of the
/// property name (so it resolves to [name] via the name table), and an 8-byte
/// little-endian IEEE-754 `double` follows the type word. Across the minimal
/// binaries every emitted record resolves to the `Parameters` container with
/// [rawTag] `0`, carrying the step-TYPE's numeric defaults/limits in record order.
///
/// [rawTag] and [rawTypeCode] are the **raw NI tag / type words, carried verbatim
/// and NOT modeled** — mapping them to NI's type/class enumeration would be
/// fabrication. They are exposed so callers can group or disambiguate records
/// without us inventing semantics for the codes.
class BinaryNamedScalar {
  const BinaryNamedScalar({
    required this.name,
    required this.rawTag,
    required this.rawTypeCode,
    required this.value,
    required this.wordIndex,
  });

  /// The offset-referenced property name this record is filed under (e.g.
  /// `Parameters`), resolved from the name table by the record's name-offset word.
  final String name;

  /// The raw leading `tag` word of the record header — **not modeled** (verbatim).
  final int rawTag;

  /// The raw `type-code` word following the name reference — **not modeled**
  /// (verbatim); an NI type/option code we deliberately do not interpret.
  final int rawTypeCode;

  /// The recovered inline IEEE-754 `double` value.
  final double value;

  /// The record-region u32 word index of the name-offset word (record order).
  final int wordIndex;
}

/// Maps each string-region-relative byte offset to the name that begins there —
/// the inverse of a record's name-offset reference. Built from [binaryStrings]
/// (runs in the string region, keyed by `offset - recordRegionLength`).
Map<int, String> _stringRegionNamesByRel(Uint8List body, int recordRegionLength) {
  final out = <int, String>{};
  for (final run in binaryStrings(body, minLength: _poolMinRunLength)) {
    if (run.offset >= recordRegionLength) out[run.offset - recordRegionLength] = run.text;
  }
  return out;
}

/// The **named-property scalar records** a binary TOF1 file embeds — each inline
/// `double` that sits in a decoded named-property record, paired with the property
/// name it is filed under and the raw (unmodeled) tag/type words of its header.
///
/// Scans the record region for the header shape `⟨tag⟩ ⟨name-offset⟩ ⟨type-code⟩
/// ⟨f64⟩`: a word that resolves (as a string-region-relative offset) to a real
/// name-table entry, immediately followed by a type word and a **clean** inline
/// double (low 32 bits zero, finite, non-zero, magnitude within
/// [[_minScalarMagnitude], [_maxScalarMagnitude]] — the same filter as
/// [binaryScalarDoubles]). The clean-f64 requirement plus the exact name-offset
/// match suppresses coincidental hits: on the Rosetta near-twins every emitted
/// record resolves to the `Parameters` container (tag `0`) with no false positives.
///
/// This is the structurally-attributed subset of [binaryScalarDoubles]: it ties
/// each such value to a property-name reference and surfaces the raw type code,
/// **without** modeling what the NI type codes mean (see [BinaryNamedScalar]).
/// Records are returned in record order; duplicate values are kept (distinct
/// record slots). Returns `[]` when [seqBytes] is not an inflatable binary file
/// or the body does not frame.
List<BinaryNamedScalar> binaryNamedScalarRecords(Uint8List seqBytes) =>
    _withLayout(seqBytes, _namedScalarsFromBody);

/// [binaryNamedScalarRecords] core over an already-inflated [body] (no
/// re-inflate), given the record-region length [recordRegionLength] — for the single-inflate
/// [analyzeBinary] path. Word `w` is the record's name-offset word; `w-1` is the
/// tag, `w+1` the type-code, and `w+2..w+3` the inline f64.
List<BinaryNamedScalar> _namedScalarsFromBody(Uint8List body, int recordRegionLength) {
  final relToName = _stringRegionNamesByRel(body, recordRegionLength);
  if (relToName.isEmpty) return const [];

  final view = ByteData.sublistView(body);
  final out = <BinaryNamedScalar>[];
  final wordCount = recordRegionLength ~/ _u32Bytes;
  for (var wordIndex = 1; wordIndex + 3 < wordCount; wordIndex++) {
    final name = relToName[view.getUint32(wordIndex * _u32Bytes, Endian.little)];
    if (name == null) continue;
    final doubleOffset = (wordIndex + 2) * _u32Bytes;
    if (doubleOffset + _f64Bytes > recordRegionLength) continue;
    if (view.getUint32(doubleOffset, Endian.little) != 0) continue;
    final value = view.getFloat64(doubleOffset, Endian.little);
    if (!_isCleanScalar(value)) continue;
    out.add(BinaryNamedScalar(
      name: name,
      rawTag: view.getUint32((wordIndex - 1) * _u32Bytes, Endian.little),
      rawTypeCode: view.getUint32((wordIndex + 1) * _u32Bytes, Endian.little),
      value: value,
      wordIndex: wordIndex,
    ));
  }
  return out;
}

/// A **consistently-referenced named-property record header** in a binary TOF1
/// record region: a name the records cite (by its string-region-relative offset)
/// always with the *same* leading [rawTag] word, across [count] occurrences.
///
/// The per-name tag **consistency is the evidence** that these are real record
/// headers rather than coincidental offset matches: a chance collision would not
/// repeatedly carry the identical preceding word. (Confirmed members surface this
/// way — `Parameters` tag 0, `ResultList` tag 2.) [rawTag] is the **raw NI tag
/// word, carried verbatim and NOT modeled**. The per-record **type** word is not
/// summarized here because it varies per member (e.g. `Parameters` holds many
/// distinct type codes); use [binaryNamedScalarRecords] for the typed scalar slots.
class BinaryNamedRecord {
  const BinaryNamedRecord({
    required this.name,
    required this.count,
    required this.rawTag,
  });

  /// The offset-referenced property/container name (e.g. `Parameters`,
  /// `ResultList`), resolved from the name table.
  final String name;

  /// How many times the record region references [name] as a header (all with
  /// [rawTag]).
  final int count;

  /// The consistent leading `tag` word of the record header — **not modeled**.
  final int rawTag;
}

/// The **consistently-referenced named-property record headers** of a binary
/// TOF1 file — the structural skeleton beyond the scalar slots
/// ([binaryNamedScalarRecords]): which property/container names the records cite
/// (by string-region-relative offset) and how often, gated to suppress
/// coincidental offset matches (see [BinaryNamedRecord]).
///
/// Gate: a name qualifies when it is non-empty, referenced at a **non-zero**
/// string-region offset (offset 0 is the root `SequenceFileData`, which every
/// zero record word would spuriously match), referenced **≥2** times, and **every**
/// such reference carries the **same** preceding `tag` word. On the Rosetta
/// near-twins this admits exactly the real TestStand identifiers (`Parameters`,
/// `ResultList`, `[0]`, `DescriptionFormat`, `NI_DotNetParameterResult`, …) and
/// drops the inconsistently-tagged noise (e.g. `Locals`, `Seq`). Returned by
/// descending [BinaryNamedRecord.count]. The record grammar linking these to the
/// step tree is **not yet decoded** — this is a header census, not a parse.
/// Returns `[]` when [seqBytes] is not an inflatable binary file or doesn't frame.
/// Whether [s] looks like a property/container **name** rather than a recovered
/// **value** string. Value strings (quoted literals, expressions, module paths,
/// `ID#:` step refs) are confirmed **not** offset-referenced, so a record word
/// matching one's offset is coincidence — excluded from [binaryNamedRecords].
bool _isNameLike(String text) =>
    !isBinaryQuotedLiteral(text) &&
    !isBinaryExpression(text) &&
    !isBinaryModulePath(text) &&
    !_isStepRef(text);

List<BinaryNamedRecord> binaryNamedRecords(Uint8List seqBytes) =>
    _withLayout(seqBytes, _namedRecordsFromBody);

List<BinaryNamedRecord> _namedRecordsFromBody(Uint8List body, int recordRegionLength) {
  final relToName = _stringRegionNamesByRel(body, recordRegionLength);
  if (relToName.isEmpty) return const [];

  final view = ByteData.sublistView(body);
  final counts = <String, int>{};
  final tags = <String, Set<int>>{};
  final wordCount = recordRegionLength ~/ _u32Bytes;
  for (var wordIndex = 1; wordIndex + 1 < wordCount; wordIndex++) {
    final off = view.getUint32(wordIndex * _u32Bytes, Endian.little);
    if (off == 0) continue;
    final name = relToName[off];
    if (name == null || name.isEmpty || !_isNameLike(name)) continue;
    counts.update(name, (v) => v + 1, ifAbsent: () => 1);
    (tags[name] ??= <int>{}).add(view.getUint32((wordIndex - 1) * _u32Bytes, Endian.little));
  }

  final out = <BinaryNamedRecord>[];
  for (final entry in counts.entries) {
    final tagSet = tags[entry.key]!;
    if (entry.value < 2 || tagSet.length != 1) continue;
    out.add(BinaryNamedRecord(
      name: entry.key,
      count: entry.value,
      rawTag: tagSet.single,
    ));
  }
  out.sort((a, b) => b.count.compareTo(a.count));
  return out;
}

/// The fixed shape of an **old-format** (TS 4.x/5.0) TOF1 property record, whose
/// fields sit at constant byte offsets from the record's lead byte. Decoded and
/// corpus-validated against the content-exact Rosetta XML twin (see
/// [binaryPropertyRecords]); catalogued as an enhanced enum rather than bare
/// offsets because a wrong offset silently misreads every value.
enum _PropRecordField {
  /// Byte 0: the record lead — one of [_propRecordLeads]. Byte 1 is a flags byte
  /// (`0x00`/`0x04` observed; not yet modeled).
  lead(0),

  /// Bytes 2..5: a `u32` that is always zero in a valid record (a framing guard).
  zeroA(2),

  /// Bytes 6..9: the record `kind` code — NOT a byte size. `Bool`/`Num`/`Str`
  /// all read `6` when valued despite 1/8/4-byte values, so it classifies the
  /// record's shape, not its length. Observed across the twins: `2` empty list,
  /// `4` bare (no stored value), `6` scalar value present, `14` a special string
  /// form; `36`/`66` are structured `Status`/`ReportText`/`CustomResults`
  /// descriptor records (out of scope for the leaf decoder — see
  /// tool/binary_record_map.dart).
  kind(6),

  /// Bytes 10..13: a second always-zero `u32` framing guard.
  zeroB(10),

  /// Bytes 14..17: the `u32` **pool index** of the record's type name
  /// (`Bool`/`Num`/`Str`/`Path`/`Expr`/a container type).
  typeNameIndex(14),

  /// Bytes 18..21: the `u32` **pool index** of the property name.
  nameIndex(18),

  /// Byte 22: where the inline value begins on a scalar-valued record
  /// ([kind] `>= _propScalarKind`).
  value(22);

  const _PropRecordField(this.offset);

  /// Byte offset of the field from the record's lead byte.
  final int offset;
}

/// The record lead bytes that introduce a property record. The trailing `u16`
/// zero after the value terminates the record.
const _propRecordLeads = {0x40, 0x44};
const _propRecordFlagsWidth = 1;
const _propTerminatorWidth = 2;

/// The [_PropRecordField.kind] range the leaf decoder accepts: `2` (empty list)
/// through `14` (special string) — exactly the observed leaf kinds. Structured
/// descriptor kinds (`36`/`66`) sit above this and are left to the
/// not-yet-decoded type/tree layer.
const _propMinKind = 2;
const _propMaxLeafKind = 14;

/// The type names observed on real leaf property records across the validated
/// corpus. Requiring the decoded type name to be one of these is the false-
/// positive gate for newer-layout binaries whose record bytes are NOT pool
/// indices: on such files a coincidental `0x40` lead with two zero words can
/// pass the framing test while its "type index" resolves to an arbitrary pool
/// string (review-confirmed on three corpus files where identical record
/// offsets resolved to different type names per file). With this gate those
/// files emit 0 records while the validated oracle keeps its exact 37/37.
const _propLeafTypeNames = {'Bool', 'Num', 'Str', 'Path', 'Expr', 'Obj', 'Objs'};

/// The [_PropRecordField.kind] at/above which a record carries an inline scalar
/// value (`6`); below it (`4` bare, `2` empty list) there is no stored value.
const _propScalarKind = 6;

/// A **decoded old-format TOF1 property record**: a leaf `name = value` pair with
/// its TestStand type name, read by the fixed [_PropRecordField] grammar and
/// resolved against the ordered NUL string pool.
///
/// The value is a [bool] (`Bool`), a [double] (`Num`), a [String] (`Str`/`Path`/
/// `Expr`, resolved from the pool), or `null` for a bare ([_PropRecordField.kind]
/// `4`) or container record that carries no inline value. Unlike [binaryScalarDoubles],
/// which *guesses* numeric slots from clean bit patterns, this reads the record's
/// declared type — so it recovers every value, including non-round doubles (e.g.
/// TestStand's `Priority` default `2953567917`).
class BinaryPropertyRecord {
  const BinaryPropertyRecord({
    required this.name,
    required this.typeName,
    required this.value,
    required this.offset,
  });

  /// The property name, resolved from the ordered string pool.
  final String name;

  /// The declared TestStand type name (`Bool`/`Num`/`Str`/`Path`/`Expr`/…).
  final String typeName;

  /// The decoded value: [bool], [double], [String], or `null` when the record is
  /// bare or a container (no inline value).
  final Object? value;

  /// The record's byte offset within the inflated body (record order).
  final int offset;
}

/// The **ordered NUL-terminated string pool** of a binary TOF1 body: the string
/// region (from [recordRegionLength] to the end) split on NUL, in order, empties
/// kept — so a record's pool index resolves positionally.
List<String> _orderedStringPool(Uint8List body, int recordRegionLength) {
  final pool = <String>[];
  var at = recordRegionLength;
  while (at < body.length) {
    final start = at;
    while (at < body.length && body[at] != 0) {
      at++;
    }
    // fromCharCodes with a range — no intermediate sublist copy per string.
    pool.add(String.fromCharCodes(body, start, at));
    at++;
  }
  return pool;
}

/// The **leaf property records** an old-format (TS 4.x/5.0) binary TOF1 file
/// embeds — each `name = value` pair with its declared TestStand type, decoded by
/// the fixed [_PropRecordField] grammar.
///
/// Corpus-validated against the content-exact Rosetta twin: every valued record
/// decoded from `OutputVoltage_BIN.seq` whose (unambiguous) name resolves in
/// `OutputVoltage_XML.seq` carries the twin's exact value — `BatchSync = 1`,
/// `FailureAction = 2`, `Priority = 2953567917`, `RecordResults = true`, string
/// expressions like `EPNameExpr`, etc.
///
/// This is a **leaf-record scan**, not a tree parse: it walks the record region
/// emitting every record matching the grammar's shape (a [_propRecordLeads] lead,
/// two zero framing guards, a leaf-range [_PropRecordField.kind], and
/// pool-resolvable type/name indices), skipping unrecognized bytes. The
/// **container nesting** that would
/// place each leaf in the sequence/step tree is **not yet decoded**, so records
/// are returned flat, in file order; duplicate names at different tree positions
/// are therefore indistinguishable here. Returns `[]` when [seqBytes] is not an
/// inflatable binary file or does not frame.
List<BinaryPropertyRecord> binaryPropertyRecords(Uint8List seqBytes) =>
    _withLayout(seqBytes, _propertyRecordsFromBody);

List<BinaryPropertyRecord> _propertyRecordsFromBody(Uint8List body, int recordRegionLength) {
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);

  int wordAt(int at) => view.getUint32(at, Endian.little);
  final out = <BinaryPropertyRecord>[];

  var at = 0;
  while (at < recordRegionLength) {
    if (at + _u32Bytes <= recordRegionLength && wordAt(at) == _recordDelimiter) {
      at += _u32Bytes;
      continue;
    }
    final headerEnd = at + _PropRecordField.value.offset;
    if (_propRecordLeads.contains(body[at + _PropRecordField.lead.offset]) &&
        headerEnd <= recordRegionLength) {
      final kind = wordAt(at + _PropRecordField.kind.offset);
      final typeIndex = wordAt(at + _PropRecordField.typeNameIndex.offset);
      final nameIndex = wordAt(at + _PropRecordField.nameIndex.offset);
      final framed = wordAt(at + _PropRecordField.zeroA.offset) == 0 &&
          wordAt(at + _PropRecordField.zeroB.offset) == 0 &&
          kind >= _propMinKind &&
          kind <= _propMaxLeafKind &&
          typeIndex < pool.length &&
          nameIndex < pool.length &&
          _propLeafTypeNames.contains(pool[typeIndex]);
      if (framed) {
        final typeName = pool[typeIndex];
        var consumed = _PropRecordField.value.offset;
        Object? value;
        if (kind >= _propScalarKind) {
          final valueAt = at + _PropRecordField.value.offset;
          switch (typeName) {
            case 'Str' || 'Path' || 'Expr':
              if (valueAt + _u32Bytes <= recordRegionLength) {
                final poolIndex = wordAt(valueAt);
                if (poolIndex < pool.length) value = pool[poolIndex];
                consumed += _u32Bytes;
              }
            case 'Bool':
              if (valueAt < recordRegionLength) {
                value = body[valueAt] != 0;
                consumed += _propRecordFlagsWidth;
              }
            case 'Num':
              if (valueAt + _f64Bytes <= recordRegionLength) {
                value = view.getFloat64(valueAt, Endian.little);
                consumed += _f64Bytes;
              }
          }
        }
        if (at + consumed + _propTerminatorWidth <= recordRegionLength &&
            body[at + consumed] == 0 &&
            body[at + consumed + 1] == 0) {
          consumed += _propTerminatorWidth;
        }
        out.add(BinaryPropertyRecord(
          name: pool[nameIndex],
          typeName: typeName,
          value: value,
          offset: at,
        ));
        at += consumed;
        continue;
      }
    }
    at++;
  }
  return out;
}

/// The record region holds a SECOND record shape besides the leaf property
/// record: a **path/object declaration**. It shares the `0x40`/`0x44` lead but is
/// distinguished by a NON-zero word at [_PropRecordField.zeroA]'s offset — where a
/// leaf record has its framing zero, a path record has the first **pool index** of
/// the object's location path. The path is a run of `u32` pool-index words
/// (`0` acts as a separator), naming the containers from the file root down to the
/// object, e.g. `[] / MainSequence / Objs / Seq / [0]` declares the sequence
/// `MainSequence` living at `…/Objs/Seq/[0]`. Element `[1]` is the object's own
/// name; the structural tokens (`Objs`, `Seq`, `[i]`, `Data`, …) spell the path.
///
/// Upper bound on the words read for one declaration path. Review-confirmed:
/// an unbounded walk crosses record boundaries (every zero word reads as a
/// separator), letting unrelated trailing words complete a match.
const _maxDeclarationPathWords = 8;

/// Reads the path words of the record at [at], or `null` if it is not a
/// path-declaration record. Stops at the first word that is neither zero nor a
/// resolvable pool index, and after [_maxDeclarationPathWords] words.
List<String>? _objectDeclarationPath(
    Uint8List body, ByteData view, List<String> pool, int at, int recordRegionLength) {
  if (at + _PropRecordField.zeroA.offset + _u32Bytes > recordRegionLength) return null;
  if (!_propRecordLeads.contains(body[at + _PropRecordField.lead.offset])) return null;
  if (body[at + 1] != 0) return null; // flags byte
  final firstOffset = at + _PropRecordField.zeroA.offset;
  final first = view.getUint32(firstOffset, Endian.little);
  if (first == 0 || first >= pool.length || pool[first].isEmpty) return null;

  final path = <String>[];
  var offset = firstOffset;
  while (offset + _u32Bytes <= recordRegionLength &&
      path.length < _maxDeclarationPathWords) {
    final word = view.getUint32(offset, Endian.little);
    if (word == 0) {
      offset += _u32Bytes; // separator
      continue;
    }
    if (word < pool.length && pool[word].isNotEmpty) {
      path.add(pool[word]);
      offset += _u32Bytes;
    } else {
      break;
    }
  }
  return path;
}

/// Minimum bytes a declaration record needs before scanning (lead + flags +
/// one path word).
const _minDeclarationBytes = 8;

/// Whether a declaration [path] is a **sequence declaration** in the validated
/// root shape `[] / <name> / Objs / Seq / [i]`: the array-root token first, the
/// sequence name at element 1, and `Objs / Seq / [i]` at exactly elements 2-4.
///
/// The exact-position requirement is the false-positive gate: review-confirmed,
/// paths shaped `ResultList / <x> / Objs / Seq / [i]` (result containers) and
/// `<class> / Calls / Objs / Seq / [i]` (.NET call containers) match a
/// floating `Objs/Seq/[i]` window but are NOT sequence declarations — a
/// floating-window matcher emitted structural tokens as "sequence names" on
/// 47/294 corpus binaries. With the root shape pinned, a corpus sweep emits
/// zero structural tokens (86/294 binaries legitimately declare sequences in
/// this shape; the rest use layouts not yet decoded).
bool _isSequenceDeclaration(List<String> path) =>
    path.length >= 5 &&
    path[0] == '[]' &&
    path[2] == 'Objs' &&
    path[3] == 'Seq' &&
    path[4].startsWith('[');

/// The **sequence names** of a binary TOF1 file, recovered from the object-path
/// declarations in the validated root shape (see [_isSequenceDeclaration]).
///
/// Corpus-validated two ways: on the six Rosetta binary twins this yields
/// exactly the sequence list their XML twins parse to (`[MainSequence]`; only
/// the OutputVoltage pair is content-exact — the others are same-sequence
/// re-saves), and a whole-corpus sweep emits zero structural-token false
/// positives. Files whose sequences are declared in a not-yet-decoded layout
/// honestly return `[]`. De-duplicated, first-seen order.
List<String> binarySequenceNames(Uint8List seqBytes) =>
    _withLayout(seqBytes, _sequenceNamesFromBody);

List<String> _sequenceNamesFromBody(Uint8List body, int recordRegionLength) {
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final seen = <String>{};
  final names = <String>[];
  for (var at = 0; at + _minDeclarationBytes <= recordRegionLength; at++) {
    final path = _objectDeclarationPath(body, view, pool, at, recordRegionLength);
    if (path == null || !_isSequenceDeclaration(path)) continue;
    if (seen.add(path[1])) names.add(path[1]);
  }
  return names;
}

/// The UNIX-timestamp range accepted as a type-record save stamp (~2000-2040).
/// The stamp is the file's typedef `timestamp` attribute — NOT a magic
/// constant: it varies per file (on the OutputVoltage oracle it is
/// 0x6259ecd3 == 1650060499, exactly the XML twin's `timestamp='1650060499'`).
const _typeStampMin = 0x386D4380;
const _typeStampMax = 0x83AA7E80;

/// Type names are identifier-like tokens; this gates coincidental matches on
/// newer-layout files whose candidate "name" word resolves to arbitrary text.
final _typeNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_.\- ]*$');

/// Byte geometry of a type record's fixed head, in record-region words:
/// `[u32 nameIdx][u32 ?][u32 timestamp][version-string refs ...]`.
/// TODO: word 1 (offset `_u32Bytes`) is not yet decoded.
const _typeStampOffset = 2 * _u32Bytes; // the save timestamp is word 2

/// A type record carries the XML twin's version-attribute triple —
/// `typeversion` / `typelastmodversion` / `typeminprodversion` — as three
/// CONSECUTIVE pool references. Two corpus-observed record generations place
/// the triple differently: old-layout records (TS 4.x/5.0-era files) follow
/// the stamp immediately (triple at word 3), newer records carry one more
/// pool-ref word (resolving to e.g. `SequenceFileData`; TODO: not yet
/// decoded) before it (triple at word 4). A looser gate (any 2 version refs
/// in words 3..8) fabricated `Objs`/enum-member names on one corpus file —
/// the consecutive-triple shape is what separates a real record.
const _typeVersionTripleStarts = [3 * _u32Bytes, 4 * _u32Bytes];
const _typeVersionTripleWords = 3;

/// Minimum bytes a type record needs: the 3-word head plus the word-3
/// (old-layout) version triple. The word-4 variant is bounds-checked where
/// it is probed.
const _typeRecordMinBytes = (3 + _typeVersionTripleWords) * _u32Bytes;

/// The **type names** defined by a binary TOF1 file, recovered from its type
/// records. A type record opens `[u32 nameIdx][u32 ?][u32 timestamp]` followed
/// by the consecutive version-string triple (see [_typeVersionTripleStarts])
/// — the same fields the XML encoding stores as `<TypeName timestamp='...'
/// typeversion='21.0.0.49156' typelastmodversion='...' typeminprodversion=
/// '...'>`. Detection keys on the record SHAPE (pool-resolvable name +
/// plausible save-timestamp + the version triple), not on any constant.
///
/// Corpus-validated on the content-exact OutputVoltage twin: 25 names
/// recovered — the root typedefs of the XML typelist plus the step/parameter
/// types the XML stores on steps (`NI_Measurement`, `NI_UpdatePinMap`,
/// `NI_MeasurementParameter`, ...); every recovered name appears in the twin
/// as a typedef element or a `typename`/`xsi:type` reference (pinned by
/// `binary_parse_seq_file_test.dart`). Whole-corpus sweep: 283/294 binaries
/// yield names with zero structural-token fabrications (pinned by
/// `binary_type_names_test.dart`). De-duplicated, in file order. Returns `[]`
/// when [seqBytes] is not an inflatable binary file or does not frame.
///
/// RESOLVED (the differential sweep found it — see [BinaryStepRef]): the
/// placed-step `typename` binds through the step reference's second word,
/// which is the 1-based index into THIS table. This makes the table's
/// ORDER load-bearing: a false or missed type record shifts every later
/// step's binding, so the corpus sweeps that pin this list are the guard.
/// Earlier negative probe results (kind-token reading is coincidental;
/// StepType record-tail IDs belong to embedded default instances; the
/// word before SData is a ResStr index; the TS 4.x/5.0 leaf grammar
/// barely fires on TS2021 files) are kept in git history at PRs #39/#48.
///
/// TODO(binary decode — typedef bodies: SPEC GRAMMAR + descriptor
/// nodes + framed-lite + inline instances w/ attr-scanned counts +
/// class-name declarations + populated-array bounds landed; 87 rosetta
/// bodies twin-exact; see [BinaryTypeField] and the body parser).
/// Remaining:
///  * `Error`'s adapter-marshalling EXTDATA blocks (the twin's
///    `<extdata controllername='STRUCT'/'CLUST'/'DNSTRUCT'/
///    'BLVCLUSTER'…>` elements) — serialized both at type level (after
///    the body's `[0][count]`) and per field (inside the attr tail,
///    e.g. `Code` trails `[0x4][STRUCT]…[CLUST]…[DNSTRUCT 'code']
///    [BLVCLUSTER 'code']`) — the last twin-validated typedef still
///    bailing;
///  * the binary-only step-type bodies (NI_Measurement/NI_UpdatePinMap
///    — no XML twin carries them): the count-less `[0]{fields}` +
///    compact `[name][value]` machinery walks them to `Substeps`, whose
///    POPULATED framed array (`'[0]' '[1]'`) trails non-DELIM-led
///    substep-element instances (`[0xe][count?][name]…`) — undecoded,
///    and unverifiable without an oracle, so they stay bailing;
///  * populated-array ELEMENT VALUES: bounds tokens and the trailing
///    type-spec + element-content blocks are walked and surfaced as one
///    undecoded blob ([BinaryTypeField.elementSpecBytes]); decoding the
///    content awaits more corpus shapes;
///  * the intrinsic-type id → name map ([BinaryTypeField.
///    intrinsicTypeId]: 2 = StepTypeSubstepsArray measured);
///  * locals/parameters: thin twin oracle (rosetta declares only the
///    implicit `ResultList`) — ride along once needed.
List<String> binaryTypeNames(Uint8List seqBytes) =>
    _withLayout(seqBytes, _typeNamesFromBody);

/// Field-flag bits (see [BinaryTypeField]): a stored value, and a display-
/// format string following it (e.g. `%#x` on `Flags` fields).
const _fieldHasValueBit = 0x2;
const _fieldHasFormatBit = 0x200;

/// Defensive cap on a typedef's subprop count (the largest real body in
/// the corpus carries 49 fields — TEInf).
const _typeMaxFields = 200;

/// Parses a typedef BODY (`[0][subpropCount][field…]`, starting right after
/// the head's record delimiter) into its field list, or null when any
/// field uses a shape the grammar does not yet cover — all-or-nothing, so
/// an undecoded construct can never fabricate a partial body. See
/// [BinaryTypeField] for the field grammar and its twin validation.

/// Parses a typedef BODY (`[0][subpropCount][field…]`, starting right after
/// the head's record delimiter) into its field list, or null when any
/// field uses a shape the grammar does not yet cover — all-or-nothing, so
/// an undecoded construct can never fabricate a partial body. See
/// [BinaryTypeField] for the field grammar and its twin validation.
/// [table] is the file's complete type table (both passes done): framed
/// default-instance references index it 1-based, the same convention as
/// step references, and may point forward.
List<BinaryTypeField>? _typeFieldsAt(
        Uint8List body,
        ByteData view,
        List<String> pool,
        int after,
        int recordRegionLength,
        List<BinaryTypeRecord> table,
        [int? endBoundary]) =>
    _TypeBodyParser(view, pool, recordRegionLength, table, endBoundary)
        .parse(after);

/// Tooling aid for grammar iteration, not part of the decode API: every
/// element-type spec the decode ACCEPTED a structural skip for, as
/// (field name, spec start offset within the inflated body, byte
/// length) — ground truth sites for probing the spec's internal
/// grammar. Uses the production parser.
List<(String, int, int)> binaryElementSpecSites(Uint8List seqBytes) {
  _TypeBodyParser.debugSpecSites.clear();
  _TypeBodyParser.debugCollectSpecs = true;
  try {
    binaryTypeRecords(seqBytes);
  } finally {
    _TypeBodyParser.debugCollectSpecs = false;
  }
  return List.of(_TypeBodyParser.debugSpecSites);
}

/// The fixed byte count between a type-record body's final field
/// terminator and the next record's head (its className word): measured
/// 17 on every cleanly-decoded rosetta body ("gap=17" in the extents
/// tool). The preamble's contents are not yet decoded (TODO); it is used
/// only to compute the body-end boundary that gates element-type spec
/// skips — a wrong value there makes skips bail, never fabricate.
const _typeRecordPreambleBytes = 17;

/// The recursive typedef-body field parser — see [_typeFieldsAt].
class _TypeBodyParser {
  _TypeBodyParser(this.view, this.pool, this.recordRegionLength, this.table,
      [this.bodyEndBoundary]);

  final ByteData view;
  final List<String> pool;
  final int recordRegionLength;
  final List<BinaryTypeRecord> table;

  /// Where this body must END — the next type record's head start minus
  /// its preamble ([_typeRecordPreambleBytes]) — or null for the last
  /// record. An element-type spec skip is only accepted when the
  /// remaining fields land EXACTLY here; without this gate a trial skip
  /// can re-anchor inside the spec (its interior parses as field-alikes)
  /// and fabricate a body, measured on TEInf/DotNetStepAdditions.
  final int? bodyEndBoundary;

  int _u32(int at) => view.getUint32(at, Endian.little);
  String? _tok(int word) =>
      word > 0 && word < pool.length && pool[word].isNotEmpty
          ? pool[word]
          : null;

  /// Whether [token] is an array-bound token: `'[]'` or `'[<digits>]'`
  /// (the XML twin writes these verbatim as lbound/ubound).
  static final _boundPattern = RegExp(r'^\[\d*\]$');
  static bool _isBoundToken(String? token) =>
      token != null && _boundPattern.hasMatch(token);

  /// Whether any element-type spec was walked during the current
  /// [parse] — arms the body-end boundary gate (a walker misparse must
  /// never fabricate a body silently).
  bool _usedSpec = false;

  /// Whether the walk is inside an INSTANCE's children (framed X >= 1).
  /// There an unvalued field means "value INHERITED from the type's
  /// default" (Action's TS stores PassAct with flags 0x60 and no value
  /// — a flags-only override of TEInf's default 'Next'), so class
  /// defaults must not be materialized; [BinaryTypeField.value] stays
  /// null and consumers treat it as not-overridden.
  bool _inInstance = false;

  /// Consumes a field's ATTR-WORD tail: zero or more nonzero words —
  /// the field's flag attributes, `flagsforinstances`/
  /// `instanceoverrideflags`/`valueflags` when present (TEInf.Links
  /// stores its twin's exact 71303168/72286233/71303168 triple; 0x4d0018
  /// everywhere is the ubiquitous `instanceoverrideflags='5046296'`) —
  /// then the 0 terminator. Returns the offset after the terminator, or
  /// null when no terminator arrives within the cap. On array fields, an
  /// attr word with bit 0x8000 (0x8001/0x8801 measured) signals a
  /// trailing element-type spec and arms [_specPending].
  int? _attrTail(int from) {
    var at = from;
    for (var i = 0; i <= _fieldMaxAttrWords; i++) {
      if (at + _u32Bytes > recordRegionLength) return null;
      final word = _u32(at);
      at += _u32Bytes;
      if (word == 0) return at;
      // Bits 0x8000/0x800 accompany SOME element-type specs (0x8001/
      // 0x8801/0x801) but are unreliable in both directions (Substep.TS's
      // CustomResults spec follows a plain 0x1; Action.Substeps carries
      // 0x8001800 with no spec at all) — specs are detected by their
      // DELIM-led frame instead (see [_fields]).
    }
    return null;
  }

  /// Walks a full ELEMENT-TYPE SPEC structurally and returns the offset
  /// after it, or null when the bytes don't frame as one. Measured
  /// grammar (constant across the rosetta corpus):
  /// `[00 pad?][DELIM][X][DELIM][0x20000?][count]{items}[attrs…][0]`
  /// where X is the array's ELEMENT TYPE as a 1-based type-table
  /// reference (CustomResults→5=NI_CustomResult, Params→12=
  /// DotNetParameter, Calls→14=DotNetCall), 0x20000 tags the compact
  /// form, and the items reuse the standard field grammar — descriptor
  /// NODEs ([_field]'s `[0][0][DELIM][name][count]` shape), plain
  /// fields, and nested spec'd arrays (recursion). The spec's CONTENT
  /// is not surfaced (no twin oracle — XML writes only
  /// `<value lbound='0' ubound='-1'/>`); only its extent is walked.
  int? _elementSpec(int at) {
    var p = at;
    if (p >= recordRegionLength) return null;
    // A single realignment pad byte precedes the frame after non-Objs
    // arrays (Objs arrays already consume their own pad).
    if (view.getUint8(p) == 0) p++;
    if (p + 4 * _u32Bytes > recordRegionLength ||
        _u32(p) != _recordDelimiter) {
      return null;
    }
    p += _u32Bytes;
    // X = the element type as a 1-based table reference. When the next
    // word is already the closing delimiter, X is OMITTED — a
    // self/inherit reference (Substep.TS's CustomResults spec reads
    // [DELIM][DELIM][count]).
    final x = _u32(p);
    if (x == _recordDelimiter) {
      p += _u32Bytes;
    } else {
      if (x < 1 || x > table.length) return null;
      p += _u32Bytes;
      if (_u32(p) != _recordDelimiter) return null;
      p += _u32Bytes;
    }
    var tagged = false;
    if (_u32(p) == 0x20000) {
      tagged = true;
      p += _u32Bytes;
    }
    final count = _u32(p);
    // Zero items only frames as a full spec under the 0x20000 tag
    // (PythonCall.Parameters' type spec: the element type is fully
    // named by X, so no descriptor items follow) — an untagged
    // [DELIM][DELIM][0][0][0] is the short REFERENCE spec ([_refSpec]).
    if ((count < 1 && !tagged) || count > _typeMaxFields) return null;
    p += _u32Bytes;
    final items = _fields(p, count);
    if (items == null) return null;
    return _attrTail(items.$2);
  }

  /// Walks a short REFERENCE spec: `[00 pad?][DELIM][ref][0][0][0]` —
  /// the 0x800-signalled form (the full spec's nested arrays reference
  /// an already-described element type instead of respelling it).
  int? _refSpec(int at) {
    var p = at;
    if (p >= recordRegionLength) return null;
    if (view.getUint8(p) == 0) p++;
    if (p + 5 * _u32Bytes > recordRegionLength ||
        _u32(p) != _recordDelimiter) {
      return null;
    }
    if (_u32(p + _u32Bytes) == 0) return null; // ref word must exist
    for (var i = 2; i < 5; i++) {
      if (_u32(p + i * _u32Bytes) != 0) return null;
    }
    return p + 5 * _u32Bytes;
  }

  /// Tooling aid (grammar iteration): the byte offset of the most recent
  /// [_field] attempt — after a bailed parse this points at the shape the
  /// grammar does not cover yet. Not part of the decode result.
  static int? debugLastFieldOffset;

  /// Tooling aid: the end offset (exclusive) the most recent successful
  /// [parse] consumed to. Not part of the decode result.
  static int? debugLastEndOffset;

  /// Tooling aid: when [debugCollectSpecs] is on, every ACCEPTED
  /// element-type spec skip is recorded as (field name, spec start
  /// offset, byte length) — ground truth for the spec-content prober.
  /// Off by default so decode runs never accumulate.
  static bool debugCollectSpecs = false;
  static final List<(String, int, int)> debugSpecSites = [];

  /// The whole body: `[0][count]` then exactly `count` fields.
  List<BinaryTypeField>? parse(int after) {
    debugLastFieldOffset = null;
    _usedSpec = false;
    if (after + 2 * _u32Bytes > recordRegionLength || _u32(after) != 0) {
      return null;
    }
    final count = _u32(after + _u32Bytes);
    var parsed = count > _typeMaxFields
        ? null
        : _fields(after + 2 * _u32Bytes, count);
    if (parsed == null) {
      // COUNT-LESS body: the step-type typedefs that exist only in the
      // binary (NI_Measurement/NI_UpdatePinMap — no XML twin carries
      // them) open `[0]{fields}` with no subprop count; the walk runs
      // until it lands EXACTLY on the body-end boundary. Without a
      // boundary (the last record) this form stays undecoded.
      final boundary = bodyEndBoundary;
      if (boundary == null) return null;
      parsed = _fieldsUntil(after + _u32Bytes, boundary);
      if (parsed == null) return null;
    }
    // Boundary gate: when a body used element-type specs and the next
    // record's position is known, the walk must not OVERRUN it — a
    // walker misparse must never fabricate a body silently. (Ending
    // short of the boundary is normal: some records trail undecoded
    // inter-record content.)
    final boundary = bodyEndBoundary;
    if (_usedSpec && boundary != null && parsed.$2 > boundary) return null;
    debugLastEndOffset = parsed.$2;
    return parsed.$1;
  }

  /// Parses fields until the walk lands EXACTLY on [boundary] — the
  /// count-less body form. Any misparse, overshoot, or runaway bails.
  (List<BinaryTypeField>, int)? _fieldsUntil(int from, int boundary) {
    var at = from;
    final fields = <BinaryTypeField>[];
    while (at < boundary && fields.length <= _typeMaxFields) {
      final parsed = _fields(at, 1);
      if (parsed == null) return null;
      fields.addAll(parsed.$1);
      at = parsed.$2;
    }
    if (at != boundary) return null;
    return (fields, at);
  }

  (List<BinaryTypeField>, int)? _fields(int from, int count) {
    var at = from;
    final fields = <BinaryTypeField>[];
    for (var i = 0; i < count; i++) {
      final field = _field(at);
      if (field == null) return null;
      at = field.$2;
      var specBytes = 0;
      if (field.$1.emptyArray) {
        // An element-type spec may follow any empty array. It is
        // detected by its frame — nothing else in a field walk leads
        // with a bare DELIMITER — not by the attr bits (TEInf's
        // CustomResults carries 0x8001 before its spec, the same field
        // inside Substep.TS a plain 0x1, and Action.Substeps 0x8001800
        // with no spec at all). Walked structurally ([_elementSpec] /
        // [_refSpec]); the length is surfaced as an explicitly
        // undecoded blob (elementSpecBytes) — the spec encodes the
        // array's element type, needed later for populated arrays and
        // .seq writing. A DELIM-led tail neither form can walk fails
        // the body, honestly.
        // Blocks CHAIN: a populated array stores its type spec and then
        // its element-content block, both DELIM-led.
        while (true) {
          final specEnd = _elementSpec(at) ?? _refSpec(at);
          if (specEnd == null) break;
          specBytes += specEnd - at;
          at = specEnd;
          _usedSpec = true;
        }
        if (specBytes == 0) {
          var lead = at;
          if (lead < recordRegionLength && view.getUint8(lead) == 0) lead++;
          if (lead + _u32Bytes <= recordRegionLength &&
              _u32(lead) == _recordDelimiter) {
            return null;
          }
        }
      }
      if (specBytes > 0) {
        if (debugCollectSpecs) {
          debugSpecSites.add((field.$1.name, field.$2, specBytes));
        }
        fields.add(BinaryTypeField(
          field.$1.name,
          className: field.$1.className,
          typeName: field.$1.typeName,
          value: field.$1.value,
          emptyArray: field.$1.emptyArray,
          children: field.$1.children,
          instanceOverrides: field.$1.instanceOverrides,
          elementSpecBytes: specBytes,
        ));
      } else {
        fields.add(field.$1);
      }
    }
    return (fields, at);
  }

  /// One field record; returns (field, next offset) or null on an
  /// uncovered shape.
  ///
  /// FIELD MODEL (twin-validated): bit 0x2 = stored value; 0x200 =
  /// display-format word after the value; 0x80 = delimiter-framed
  /// (Expression scalars, typed references, inline instances). The other
  /// low bits (0x4/0x8/0x20/0x40) advertise which FLAG ATTRIBUTES the
  /// field stores, but the attr words themselves simply run until the 0
  /// terminator ([_attrTail]) — except on Obj declarations, which have
  /// no terminator, so there the 0x8/0x20/0x40 bit count is
  /// load-bearing (one word each; twin-validated on Requirements).
  (BinaryTypeField, int)? _field(int at) {
    debugLastFieldOffset = at;
    if (at + 6 * _u32Bytes > recordRegionLength) return null;
    final fieldFlags = _u32(at);
    if (_u32(at + _u32Bytes) != 0) {
      // COMPACT form: [name][value][attr words…][0] — no flags/class
      // prefix (every other form has 0 in the second slot; here it is
      // the stored value). Measured on the binary-only step-type
      // typedefs (DescriptionFormat = ResStr(…) in NI_Measurement).
      // The class is not serialized — surfaced as null, undecoded.
      final name = _tok(fieldFlags);
      final value = _tok(_u32(at + _u32Bytes));
      if (name == null || value == null) return null;
      final after = _attrTail(at + 2 * _u32Bytes);
      if (after == null) return null;
      return (BinaryTypeField(name, value: value), after);
    }
    if (fieldFlags & ~(0x2 | 0x4 | 0x8 | 0x20 | 0x40 | 0x80 | 0x200) != 0) {
      return null;
    }
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasFormat = fieldFlags & _fieldHasFormatBit != 0;

    // DESCRIPTOR NODE: [0][0][DELIM][name][childCount][children…] — no
    // tail. The shape type descriptors use for nested objects, measured
    // inside element-type specs and PropertyObjectType instances (the
    // spec's 'Type'/'ArrayDimensions' nodes). Distinguished from the
    // framed form by flags == 0 (framed fields always carry bit 0x80)
    // and from the plain form by the DELIMITER where the class word
    // would sit. Children serialize like overrides: a subset, so they
    // compare by name against the materialized twin.
    if (fieldFlags == 0 && _u32(at + 2 * _u32Bytes) == _recordDelimiter) {
      final name = _tok(_u32(at + 3 * _u32Bytes));
      if (name == null) return null;
      final childCount = _u32(at + 4 * _u32Bytes);
      if (childCount > _typeMaxFields) return null;
      final children = _fields(at + 5 * _u32Bytes, childCount);
      if (children == null) return null;
      return (
        BinaryTypeField(name,
            className: 'Obj',
            children: children.$1,
            instanceOverrides: true),
        children.$2
      );
    }

    // Framed form: [flags|0x80][0][DELIM][X][name][value…][extras…][0].
    if (fieldFlags & 0x80 != 0) {
      if (_u32(at + 2 * _u32Bytes) != _recordDelimiter) return null;
      final x = _u32(at + 3 * _u32Bytes);
      final name = _tok(_u32(at + 4 * _u32Bytes));
      if (name == null) return null;
      var next = at + 5 * _u32Bytes;
      String? value;
      var typeName = 'Expression';
      var className = 'ExprValue';
      if (x == 0) {
        if (valued) {
          value = _tok(_u32(next));
          if (value == null) return null;
          next += _u32Bytes;
        } else {
          // The twin's `<value/>` reads as an empty string — unless
          // inside an instance, where an unvalued field is inherited.
          value = _inInstance ? null : '';
        }
      } else if (x >= 2 && valued) {
        // Typed EMPTY-ARRAY instance (`Substeps` of StepTypeSubstepsArray):
        // ['[0]']['[]'][attr words…][0][one 0x00 pad byte] — anchor-
        // measured across every rosetta binary.
        if (_tok(_u32(next)) != '[0]' ||
            next + 2 * _u32Bytes > recordRegionLength ||
            _tok(_u32(next + _u32Bytes)) != '[]') {
          return null;
        }
        final tail = _attrTail(next + 2 * _u32Bytes);
        if (tail == null ||
            tail >= recordRegionLength ||
            view.getUint8(tail) != 0) {
          return null;
        }
        // X here is NOT a table reference: Substeps carries X=2 while
        // its twin types it StepTypeSubstepsArray — an ENGINE-INTRINSIC
        // type that is never serialized (the table has no such record).
        // X is surfaced as the undecoded intrinsic-type id.
        return (
          BinaryTypeField(name,
              className: 'Objs', emptyArray: true, intrinsicTypeId: x),
          tail + 1
        );
      } else if (x >= 2 && !valued && x - 1 < table.length) {
        // Type table[X-1] (1-based, the same convention as step
        // references), in one of two twin-validated shapes:
        //  * an INLINE OVERRIDE instance — `[name][attr words…]
        //    [childCount]` then the overridden fields in the full field
        //    grammar (the same explicit count the X == 1 custom-instance
        //    form carries; Substep.TS stores an attr word 0x440018
        //    before its count). Like X == 1 this serializes ONLY the
        //    overrides (DotNetStepAdditions.StructDef stores 2 of
        //    DotNetParameter's 11 fields), so children compare as a
        //    subset of the materialized twin;
        //  * a default-instance REFERENCE — no inline content, just the
        //    attr-word tail.
        final ref = table[x - 1];
        for (var k = 0; k <= _fieldMaxAttrWords; k++) {
          final countAt = next + k * _u32Bytes;
          if (countAt + _u32Bytes > recordRegionLength) break;
          final word = _u32(countAt);
          if (word == 0) break; // the ref-only terminator — no instance
          if (word < 1 || word > _typeMaxFields) continue; // attr word
          final outerInstance = _inInstance;
          _inInstance = true;
          final children = _fields(countAt + _u32Bytes, word);
          _inInstance = outerInstance;
          if (children != null) {
            return (
              BinaryTypeField(name,
                  className: ref.className ?? 'Obj',
                  typeName: ref.name,
                  children: children.$1,
                  instanceOverrides: true),
              children.$2
            );
          }
        }
        className = ref.className ?? 'Obj';
        typeName = ref.name;
        // A reference to a scalar-classed type reads that class's
        // default, the twin's `<value/>` semantics (AssemblyPath:Path
        // materializes '' via its PathValue class) — object-classed
        // references carry no value, and inside an instance an
        // unvalued field is inherited, not defaulted.
        value = _inInstance
            ? null
            : switch (className) {
                'Str' || 'PathValue' || 'ExprValue' => '',
                'Bool' => 'false',
                'Num' => '0',
                _ => null,
              };
      } else if (x == 1 && !valued) {
        // Inline CUSTOM instance: [name][attr words…][overrideCount]
        // then entries,
        // each `[2][0]` + `[cls][name][value][trail]` (trail: one 0x00
        // byte after Bool, u32 0 after Str) or `[2][0][DELIM][name]
        // [value][u32 0]` for ExprValue overrides. No terminator — the
        // next field starts immediately. The instance's TYPE is
        // engine-intrinsic (not serialized), so typeName stays null and
        // children carry ONLY the overrides. Anchor-measured across all
        // rosetta instances.
        // Attr words may precede the count (Action.Menu stores two
        // 0x80018 words) — scan past them, same as the X >= 2 form.
        var overrideCount = _u32(next);
        for (var k = 0;
            overrideCount > _typeMaxFields && k < _fieldMaxAttrWords;
            k++) {
          next += _u32Bytes;
          if (next + _u32Bytes > recordRegionLength) return null;
          overrideCount = _u32(next);
        }
        if (overrideCount > _typeMaxFields) return null;
        next += _u32Bytes;
        final overrides = <BinaryTypeField>[];
        for (var i = 0; i < overrideCount; i++) {
          if (next + 5 * _u32Bytes > recordRegionLength) return null;
          if (_u32(next) != 0x2 || _u32(next + _u32Bytes) != 0) return null;
          final third = _u32(next + 2 * _u32Bytes);
          final childName = _tok(_u32(next + 3 * _u32Bytes));
          final valueWord = _u32(next + 4 * _u32Bytes);
          if (childName == null) return null;
          if (third == _recordDelimiter) {
            final childValue = _tok(valueWord);
            if (childValue == null ||
                next + 6 * _u32Bytes > recordRegionLength ||
                _u32(next + 5 * _u32Bytes) != 0) {
              return null;
            }
            overrides.add(BinaryTypeField(childName,
                className: 'ExprValue',
                typeName: 'Expression',
                value: childValue));
            next += 6 * _u32Bytes;
            continue;
          }
          final childClass = _tok(third);
          switch (childClass) {
            case 'Bool':
              if (valueWord > 1 ||
                  next + 5 * _u32Bytes + 1 > recordRegionLength ||
                  view.getUint8(next + 5 * _u32Bytes) != 0) {
                return null;
              }
              overrides.add(BinaryTypeField(childName,
                  className: 'Bool',
                  value: valueWord == 1 ? 'true' : 'false'));
              next += 5 * _u32Bytes + 1;
            case 'Str':
              final childValue = _tok(valueWord);
              if (childValue == null ||
                  next + 6 * _u32Bytes > recordRegionLength ||
                  _u32(next + 5 * _u32Bytes) != 0) {
                return null;
              }
              overrides.add(BinaryTypeField(childName,
                  className: 'Str', value: childValue));
              next += 6 * _u32Bytes;
            default:
              return null;
          }
        }
        return (
          BinaryTypeField(name,
              className: 'Obj',
              children: overrides,
              instanceOverrides: true),
          next
        );
      } else {
        return null;
      }
      final after = _attrTail(next);
      if (after == null) return null;
      return (
        BinaryTypeField(name,
            className: className, typeName: typeName, value: value),
        after
      );
    }

    // FRAMED-LITE form: [flags][0][DELIM][name][value?][attrs…][0] — an
    // Expression-typed field with the DELIMITER in the class slot and no
    // X word (Action's TS override stores PassActTarget/FailActTarget
    // this way with flags 0x60). Distinguished from the full framed form
    // by the absent 0x80 bit and from the descriptor node by flags != 0.
    if (fieldFlags != 0 && _u32(at + 2 * _u32Bytes) == _recordDelimiter) {
      final name = _tok(_u32(at + 3 * _u32Bytes));
      if (name == null) return null;
      var next = at + 4 * _u32Bytes;
      // The twin's `<value/>` reads as an empty string — unless inside
      // an instance, where an unvalued field is inherited (null).
      var value = _inInstance ? null : '';
      if (valued) {
        final stored = _tok(_u32(next));
        if (stored == null) return null;
        value = stored;
        next += _u32Bytes;
      }
      final after = _attrTail(next);
      if (after == null) return null;
      return (
        BinaryTypeField(name,
            className: 'ExprValue', typeName: 'Expression', value: value),
        after
      );
    }

    // Plain form: [flags][0][cls][name][value-part][format?][extras…]
    // [terminator 0] — extras sit AFTER the value part (anchor-measured on
    // CodeTemplates: [Str][name][value][0x480018][0]); with no value part
    // they directly precede the terminator (BlockStartTypes:
    // [Str][name][0x480018][0]).
    final className = _tok(_u32(at + 2 * _u32Bytes));
    final name = _tok(_u32(at + 3 * _u32Bytes));
    if (className == null || name == null) return null;
    var next = at + 4 * _u32Bytes;
    // Nested object DECLARATION — class word 'Obj' or a CLASS NAME
    // string (PythonStepAdditions.PythonCall declares class
    // 'CPythonCall' this way, its 14 children inline):
    // [attr words…][childCount][children…] — no trailing zero, so the
    // childCount is found by scanning past the attr words: the first
    // word small enough to be a count whose children then parse
    // (Substep.TS's Result stores two 0x400000 attr words where its
    // flag bits promise one — bit arity is not reliable here either).
    if (!valued &&
        !const {'Bool', 'Str', 'Num', 'Nums', 'Strs', 'Objs', 'ExprValue',
            'PathValue'}.contains(className)) {
      for (var k = 0; k <= _fieldMaxAttrWords; k++) {
        final countAt = next + k * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final childCount = _u32(countAt);
        if (childCount > _typeMaxFields) continue; // attr word
        final children = _fields(countAt + _u32Bytes, childCount);
        if (children == null) continue;
        return (
          BinaryTypeField(name,
              className: className, children: children.$1),
          children.$2
        );
      }
      return null;
    }
    if (!valued) {
      // Unvalued fields read their class defaults (false / '' / 0 — the
      // twin's `<value/>` semantics): [attr words…][terminator 0].
      // Inside an instance the value is INHERITED instead (null).
      final after = _attrTail(next);
      if (after == null) return null;
      if (!const {'Bool', 'Str', 'Num'}.contains(className)) return null;
      return (
        BinaryTypeField(name,
            className: className,
            value: _inInstance
                ? null
                : switch (className) {
                    'Bool' => 'false',
                    'Num' => '0',
                    _ => '',
                  }),
        after
      );
    }
    // Empty array field: value tokens '[0]' '[]' then trail 0. Object
    // arrays (`Objs`) additionally carry ONE 0x00 pad byte after the
    // trail — the stream is byte-granular, and this pad is what shifts
    // everything after an empty Objs array off word alignment.
    if (const {'Nums', 'Strs', 'Objs'}.contains(className) &&
        next + 2 * _u32Bytes <= recordRegionLength &&
        _isBoundToken(_tok(_u32(next))) &&
        _isBoundToken(_tok(_u32(next + _u32Bytes)))) {
      // Bounds are literal tokens ('[0]' '[]' = empty; '[0]' '[0]' = a
      // populated one-element array — PythonCall.Parameters). Populated
      // content rides in the trailing DELIM-led blocks, currently
      // surfaced undecoded via elementSpecBytes (TODO: decode element
      // values once more corpus shapes are in hand).
      var after = _attrTail(next + 2 * _u32Bytes);
      if (after == null) return null;
      if (className == 'Objs') {
        if (after >= recordRegionLength || view.getUint8(after) != 0) {
          return null;
        }
        after += 1;
      }
      return (
        BinaryTypeField(name, className: className, emptyArray: true),
        after
      );
    }
    switch (className) {
      case 'Str':
        final value = _tok(_u32(next));
        if (value == null) return null;
        final after = _attrTail(next + _u32Bytes);
        if (after == null) return null;
        return (
          BinaryTypeField(name, className: 'Str', value: value),
          after
        );
      case 'Bool':
        // A stored Bool is ONE byte (TEInf's StepFCSeqF=true measured:
        // [01][attr 0x4d0018][terminator]) — the same byte the instance
        // grammar reads. Reading it as u32 was survivable only while
        // every validated stored Bool was false.
        final value = view.getUint8(next);
        if (value > 1) return null;
        final after = _attrTail(next + 1);
        if (after == null) return null;
        return (
          BinaryTypeField(name,
              className: 'Bool', value: value == 1 ? 'true' : 'false'),
          after
        );
      case 'Num':
        if (next + 2 * _u32Bytes > recordRegionLength) return null;
        final value = view.getFloat64(next, Endian.little);
        next += 2 * _u32Bytes;
        if (hasFormat) {
          if (next + _u32Bytes > recordRegionLength ||
              _tok(_u32(next)) == null) {
            return null;
          }
          next += _u32Bytes; // display-format ref, e.g. '%#x'
        }
        final after = _attrTail(next);
        if (after == null) return null;
        return (
          BinaryTypeField(name,
              className: 'Num',
              value: value == value.truncateToDouble() && value.abs() < 1e15
                  ? '${value.truncate()}'
                  : '$value'),
          after
        );
      default:
        return null;
    }
  }
}


/// The decoded typed-model lenses of an **already-inflated** [body] in one
/// shared frame+pool+table pass: the sequence outlines and the type-record
/// heads. This is the single-scan path for `parseSeqFile` — calling the
/// per-lens helpers separately would re-frame the layout, rebuild the
/// ordered string pool, and rescan the type table once per lens. Both
/// lenses read empty when the body does not frame.
({List<BinarySequenceOutline> outlines, List<BinaryTypeRecord> typeRecords})
    binaryOutlinesAndTypeRecordsFromBody(Uint8List body) {
  final layout = _layoutFromBody(body);
  if (layout == null) return const (outlines: [], typeRecords: []);
  final recordRegionLength = layout.recordRegionLength;
  final pool = _orderedStringPool(body, recordRegionLength);
  final typeRecords = _typeRecordsFromBody(body, recordRegionLength, pool);
  return (
    outlines: _sequenceOutlinesFromBody(body, recordRegionLength, pool,
        [for (final record in typeRecords) record.name]),
    typeRecords: typeRecords,
  );
}

List<String> _typeNamesFromBody(Uint8List body, int recordRegionLength,
        [List<String>? sharedPool]) =>
    [
      for (final record
          in _typeRecordsFromBody(body, recordRegionLength, sharedPool))
        record.name,
    ];

/// A decoded type-record HEAD — the same attributes the XML encoding puts
/// on the typedef element. Layout (validated attribute-for-attribute
/// against the oracle twin: 22/22 comparable typedefs exact):
///
/// `[classIdx][nameIdx][typecategory][stamp][0?][ver][ver][ver]
///  [flags…][0][0xffffffff]`
///
/// The version triple starts at word 3 (TS 4.x/5.0 layout) or word 4
/// (newer); the flag words after the triple — up to the `0xffffffff`
/// record delimiter, trailing zeros dropped — carry, IN ORDER: `typeflags`,
/// `flagsforinstances`, `instanceoverrideflags`, `valueflags` (later ones
/// only when the typedef declares them, exactly like the XML attributes).
/// The typedef BODY (fields, defaults) follows the delimiter and is not
/// yet decoded.
/// One decoded typedef FIELD — the binary form of an XML typedef subprop.
/// Field records follow the typedef head as
/// `[fieldFlags][0][classIdx][nameIdx][value…]`, where flag bit 0x2 marks a
/// stored value and bit 0x200 a display-format string after it. Value
/// arity by class: Bool/Str one word (+ trailing 0 when stored), Num an
/// inline f64 (+ format ref when flagged, + trailing 0), `Nums`/`Strs`
/// empty arrays the token pair `'[0]' '[]'` + 0. A field typed by
/// `Expression` fuses the prefix into a delimiter-framed block
/// `[marker][0][0xffffffff][0][nameIdx][value…]` (markers 0x80 bare,
/// 0x82/0xEE with a stored value). Twin-validated: 55 typedef bodies
/// across the rosetta pairs decode field-for-field exactly; anything not
/// matching these shapes leaves the WHOLE body undecoded (all-or-nothing —
/// no partial trees, no fabrication).
class BinaryTypeField {
  const BinaryTypeField(this.name,
      {this.className,
      this.typeName,
      this.value,
      this.emptyArray = false,
      this.children = const [],
      this.instanceOverrides = false,
      this.elementSpecBytes,
      this.intrinsicTypeId});

  /// The field name (`Code`, `ItemName`, …).
  final String name;

  /// The value class (`Bool`/`Str`/`Num`/`Nums`/`Strs`), or `ExprValue`
  /// for Expression-typed fields.
  final String? className;

  /// The named type for typed fields (`Expression`), null otherwise.
  final String? typeName;

  /// The stored scalar value in XML text form (`false`, `8192`, `""`), or
  /// null when the field carries none.
  final String? value;

  /// Whether this is an empty scalar-array field (`Nums`/`Strs` with
  /// `lbound 0, ubound -1`).
  final bool emptyArray;

  /// Nested declaration children (an `Obj` field's own field list),
  /// decoded recursively. A typed default-instance REFERENCE (`X >= 2`
  /// framed form) carries no children — the binary itself stores only the
  /// reference; materializing the referenced type's defaults is the XML
  /// writer's job, not the file's content.
  final List<BinaryTypeField> children;

  /// TODO(element-type spec): the length in bytes of this array field's
  /// trailing ELEMENT-TYPE SPEC — an explicitly UNDECODED blob (it
  /// encodes the array's element type; needed for populated arrays and
  /// eventual .seq writing, so it is surfaced, never dropped). The blob
  /// starts right after this field's own encoding. Null when the field
  /// carries no spec (or the spec trails the body's last field, where
  /// the count-driven walk leaves it untouched).
  final int? elementSpecBytes;

  /// True for an inline CUSTOM instance (framed `X == 1`): [children]
  /// holds ONLY the fields the instance OVERRIDES — the file serializes
  /// nothing else, and the instance's TYPE is engine-intrinsic (not in
  /// the file), so [typeName] stays null. Compare such children as a
  /// subset of the materialized twin, never as the full field list.
  final bool instanceOverrides;

  /// TODO(intrinsic types): for a framed VALUED empty array, the X word
  /// is an ENGINE-INTRINSIC type id, not a table reference (`Substeps`
  /// carries 2 while its twin types it `StepTypeSubstepsArray` — a type
  /// the file never serializes). Surfaced undecoded; the id → name map
  /// needs more corpus evidence. Null elsewhere.
  final int? intrinsicTypeId;
}

class BinaryTypeRecord {
  const BinaryTypeRecord({
    required this.name,
    required this.className,
    required this.typeCategory,
    required this.timestamp,
    required this.versions,
    required this.flags,
    this.fields,
  });

  /// The type name (the typedef element name in XML).
  final String name;

  /// The value-kind (`classname` attribute: `Obj`, `ExprValue`, `StepType`,
  /// …), or null when the class word does not resolve in the pool.
  final String? className;

  /// `typecategory` (verbatim code; NI-internal meaning not invented).
  final int typeCategory;

  /// The typedef save `timestamp` (UNIX seconds — the "type stamp").
  final int timestamp;

  /// `typeversion`, `typelastmodversion`, `typeminprodversion`, in order.
  final List<String> versions;

  /// The ordered flag words after the version triple (trailing zeros
  /// dropped). Absent attributes are simply not written, so the ATTRIBUTE
  /// each word carries depends on how many there are — and, for three, on
  /// the record's [typeCategory] (rosetta-twin enumerated: the only two
  /// 3-flag combos split exactly on category 1 vs not):
  ///   1 → typeflags
  ///   2 → typeflags, valueflags
  ///   3 → typeflags, flagsforinstances, then instanceoverrideflags when
  ///       [typeCategory] == 1 (step types), else valueflags
  ///   4 → typeflags, flagsforinstances, instanceoverrideflags, valueflags
  /// Empty when the record tail did not frame (absent, never guessed).
  final List<int> flags;

  /// The typedef's decoded FIELD list (see [BinaryTypeField]), or null
  /// when the body contains shapes the grammar does not yet cover (nested
  /// objects, populated arrays, instance-ID blocks) — undecoded, never
  /// partially guessed.
  final List<BinaryTypeField>? fields;

  int? get typeFlags => flags.isNotEmpty ? flags[0] : null;
  int? get flagsForInstances => flags.length > 2 ? flags[1] : null;
  int? get instanceOverrideFlags => flags.length == 4
      ? flags[2]
      : (flags.length == 3 && typeCategory == 1 ? flags[2] : null);
  int? get valueFlags => switch (flags.length) {
        2 => flags[1],
        3 => typeCategory == 1 ? null : flags[2],
        4 => flags[3],
        _ => null,
      };

  /// The head as XML-shaped attributes (same names/format the XML twin
  /// uses), for the synthesized typed model.
  Map<String, String> toAttributes() => {
        'typecategory': '$typeCategory',
        'timestamp': '$timestamp',
        if (versions.isNotEmpty) 'typeversion': versions[0],
        if (versions.length > 1) 'typelastmodversion': versions[1],
        if (versions.length > 2) 'typeminprodversion': versions[2],
        if (typeFlags != null) 'typeflags': '$typeFlags',
        if (flagsForInstances != null)
          'flagsforinstances': '$flagsForInstances',
        if (instanceOverrideFlags != null)
          'instanceoverrideflags': '$instanceOverrideFlags',
        if (valueFlags != null) 'valueflags': '$valueFlags',
      };
}

/// The decoded type-record heads of a binary TOF1 file, in table order —
/// see [BinaryTypeRecord] for the layout. Detection is IDENTICAL to
/// [binaryTypeNames] (this is the same scan keeping the head fields), so
/// the corpus-pinned table is shared.
List<BinaryTypeRecord> binaryTypeRecords(Uint8List seqBytes) =>
    _withLayout(seqBytes, _typeRecordsFromBody);

/// Defensive cap on a field's attr-word tail (three is the most any
/// twin-validated field stores — ffi/iof/vf, e.g. TEInf.Links).
const _fieldMaxAttrWords = 8;

/// Defensive cap on flag words read after the version triple while looking
/// for the record delimiter (real records carry at most four flags plus a
/// trailing zero).
const _typeMaxFlagWords = 8;

List<BinaryTypeRecord> _typeRecordsFromBody(
    Uint8List body, int recordRegionLength,
    [List<String>? sharedPool,
    Map<String, int>? bodyOffsetsOut,
    Map<String, int>? headOffsetsOut]) {
  final pool = sharedPool ?? _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final versionLike = RegExp(r'^\d+\.\d+');
  final seen = <String>{};
  final records = <BinaryTypeRecord>[];
  final bodyOffsets = <int?>[];
  final headAts = <int>[];
  String? tok(int word) =>
      word > 0 && word < pool.length && pool[word].isNotEmpty
          ? pool[word]
          : null;
  for (var at = 0; at + _typeRecordMinBytes <= recordRegionLength; at++) {
    final stamp = view.getUint32(at + _typeStampOffset, Endian.little);
    if (stamp < _typeStampMin || stamp > _typeStampMax) continue;
    final nameIndex = view.getUint32(at, Endian.little);
    if (nameIndex == 0 || nameIndex >= pool.length) continue;
    final name = pool[nameIndex];
    if (name.isEmpty || !_typeNamePattern.hasMatch(name)) continue;
    int? tripleAt;
    for (final tripleStart in _typeVersionTripleStarts) {
      if (at + tripleStart + _typeVersionTripleWords * _u32Bytes >
          recordRegionLength) {
        continue;
      }
      var triple = true;
      for (var i = 0; i < _typeVersionTripleWords; i++) {
        final word =
            view.getUint32(at + tripleStart + i * _u32Bytes, Endian.little);
        // Index 0 is padding/separator by this file's pool convention (see
        // poolAt) — a zero word must not count as a version reference.
        if (word == 0 ||
            word >= pool.length ||
            !versionLike.hasMatch(pool[word])) {
          triple = false;
          break;
        }
      }
      if (triple) {
        tripleAt = tripleStart;
        break;
      }
    }
    if (tripleAt == null) continue;
    if (!seen.add(name)) continue;
    // Head fields are PASSIVE — never part of the detection gate, so the
    // corpus-pinned detection counts cannot shift: class word right before
    // the name, typecategory right after, flags after the triple up to the
    // record delimiter (trailing zeros dropped).
    final className = at >= _u32Bytes
        ? tok(view.getUint32(at - _u32Bytes, Endian.little))
        : null;
    final typeCategory = view.getUint32(at + _u32Bytes, Endian.little);
    final versions = [
      for (var i = 0; i < _typeVersionTripleWords; i++)
        pool[view.getUint32(at + tripleAt + i * _u32Bytes, Endian.little)],
    ];
    final flags = <int>[];
    var flagAt = at + tripleAt + _typeVersionTripleWords * _u32Bytes;
    var framed = false;
    while (flagAt + _u32Bytes <= recordRegionLength &&
        flags.length < _typeMaxFlagWords) {
      final value = view.getUint32(flagAt, Endian.little);
      if (value == _recordDelimiter) {
        framed = true;
        break;
      }
      flags.add(value);
      flagAt += _u32Bytes;
    }
    int? bodyAt;
    if (framed) {
      while (flags.isNotEmpty && flags.last == 0) {
        flags.removeLast();
      }
      // The body follows the head delimiter: [0][subpropCount][fields…].
      bodyAt = flagAt + _u32Bytes;
    } else {
      flags.clear(); // tail did not frame — report nothing, not guesses
    }
    records.add(BinaryTypeRecord(
      name: name,
      className: className,
      typeCategory: typeCategory,
      timestamp: stamp,
      versions: versions,
      flags: flags,
    ));
    bodyOffsets.add(bodyAt);
    headAts.add(at);
    if (bodyAt != null) bodyOffsetsOut?[name] = bodyAt;
    headOffsetsOut?[name] = at;
  }
  // Second pass: bodies parse with the COMPLETE table of heads in hand —
  // framed references index it 1-based (the same convention as step
  // references), and may point forward. Bodies parse in TABLE ORDER with
  // each result folded back in: an inline materialized instance needs the
  // REFERENCED type's field count, and the corpus defines element/base
  // types before their use sites.
  final result = List.of(records);
  for (var i = 0; i < result.length; i++) {
    final bodyAt = bodyOffsets[i];
    if (bodyAt == null) continue;
    final boundary = i + 1 < headAts.length
        ? headAts[i + 1] - _u32Bytes - _typeRecordPreambleBytes
        : null;
    final fields = _typeFieldsAt(
        body, view, pool, bodyAt, recordRegionLength, result, boundary);
    if (fields == null) continue;
    result[i] = BinaryTypeRecord(
      name: records[i].name,
      className: records[i].className,
      typeCategory: records[i].typeCategory,
      timestamp: records[i].timestamp,
      versions: records[i].versions,
      flags: records[i].flags,
      fields: fields,
    );
  }
  return result;
}

/// Tooling aid for grammar iteration, not part of the decode API: every
/// type record with a framed body, in table order, with its body start
/// offset (within the inflated body) and either the end offset the parse
/// consumed to, or the byte offset of the first field the grammar could
/// not cover — the exact spot to point the prober at. Uses the
/// production parser, so it can never disagree with the real decode.
List<({String name, int headAt, int bodyAt, int? end, int? bail})>
    binaryTypeBodyExtents(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  final layout = _layoutFromBody(body);
  if (layout == null) return const [];
  final recordRegionLength = layout.recordRegionLength;
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final bodyOffsets = <String, int>{};
  final headOffsets = <String, int>{};
  final records = _typeRecordsFromBody(
      body, recordRegionLength, pool, bodyOffsets, headOffsets);
  final extents =
      <({String name, int headAt, int bodyAt, int? end, int? bail})>[];
  for (var i = 0; i < records.length; i++) {
    final record = records[i];
    final bodyAt = bodyOffsets[record.name];
    if (bodyAt == null) continue;
    final boundary = i + 1 < records.length
        ? (headOffsets[records[i + 1].name] ?? 0) -
            _u32Bytes -
            _typeRecordPreambleBytes
        : null;
    final parser = _TypeBodyParser(
        view, pool, recordRegionLength, records, boundary);
    final ok = parser.parse(bodyAt) != null;
    extents.add((
      name: record.name,
      headAt: headOffsets[record.name] ?? -1,
      bodyAt: bodyAt,
      end: ok ? _TypeBodyParser.debugLastEndOffset : null,
      bail: ok ? null : _TypeBodyParser.debugLastFieldOffset ?? -1,
    ));
  }
  return extents;
}

/// A step reference in the record region is a run of four `u32` pool-index words
/// `Step / <kind> / <name> / <container>`: the `Step` token, then the step's kind
/// (a TestStand unique-ID string, or `Expression`/`ExprValue`), then the step's
/// name, then its subobject container (`Objs` or `Data`). The name is two words
/// after the `Step` token. The kind word is the discriminator that separates a
/// real step from the many other `Step`-token uses (type tables, `StepType`,
/// engine callbacks like `OnNewStep`/`Post`, whose middle word is `ResultList`,
/// a version, or `0xffffffff`).
const _stepToken = 'Step';
const _stepNameWordGap = 2; // words after the Step token to the name
const _stepContainerTokens = {'Objs', 'Data'};
const _stepExpressionKinds = {'Expression', 'ExprValue'};

/// The minimum length + punctuation signature of a TestStand **unique-ID** string
/// (e.g. `8;G6MnVLO732>8ODE2E3h4jDhR\`), the kind word of a normal placed step.
/// Corpus-tuned to admit the ID charset while rejecting ordinary identifiers.
bool _looksLikeUniqueId(String text) =>
    text.length >= 15 && RegExp(r'[;\\<>^\]]').hasMatch(text);

/// The **step names** of a binary TOF1 file, recovered from the step references
/// ([_stepToken] runs) in the record region. Returned in file order,
/// de-duplicated.
///
/// This is the step *set*, not yet grouped into each sequence's Setup/Main/
/// Cleanup lists (that membership is a further layer — file order is not
/// execution order). Corpus-validated: on the content-exact OutputVoltage twin
/// the recovered set equals the XML twin's steps exactly, and on every other
/// Rosetta twin the *count* matches (the names differ only because those pairs
/// are the same sequence saved from different toolchains).
///
/// Known contamination, review-measured: on 4/294 corpus binaries a step-TYPE
/// substep hook (`OnNewStep`/`Post`/`Edit`) matches this reference shape and is
/// wrongly reported as a step. Those hooks are step-shaped objects inside type
/// definitions; separating them needs the type-region framing (not yet
/// decoded) — a name blocklist would be pattern-matching, not decoding, so the
/// contamination is documented rather than masked. Returns `[]` when
/// [seqBytes] is not an inflatable binary file or does not frame.
List<String> binaryStepNames(Uint8List seqBytes) =>
    _withLayout(seqBytes, _stepNamesFromBody);

List<String> _stepNamesFromBody(Uint8List body, int recordRegionLength) {
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final stepToken = pool.indexOf(_stepToken);
  if (stepToken < 0) return const [];
  final view = ByteData.sublistView(body);
  int wordAt(int at) => view.getUint32(at, Endian.little);
  String? poolAt(int index) =>
      index > 0 && index < pool.length && pool[index].isNotEmpty ? pool[index] : null;

  // Step references are not 4-byte aligned (they pack at 2-byte record
  // boundaries), so scan every byte offset. Set-backed dedup keeps the scan
  // linear on files with many matches.
  final seen = <String>{};
  final names = <String>[];
  for (var at = 0; at + (_stepNameWordGap + 2) * _u32Bytes <= recordRegionLength; at++) {
    if (wordAt(at) != stepToken) continue;
    final kind = poolAt(wordAt(at + _u32Bytes));
    final name = poolAt(wordAt(at + _stepNameWordGap * _u32Bytes));
    final container = poolAt(wordAt(at + (_stepNameWordGap + 1) * _u32Bytes));
    if (name == null || container == null || kind == null) continue;
    if (!_stepContainerTokens.contains(container)) continue;
    if (!_looksLikeUniqueId(kind) && !_stepExpressionKinds.contains(kind)) continue;
    if (seen.add(name)) names.add(name);
  }
  return names;
}

/// The step-group container names, in the record region's declaration order
/// context (`Main` is emitted before `Setup`/`Cleanup` in observed files).
const _stepGroupNames = {'Setup', 'Main', 'Cleanup'};

/// A **reconstructed sequence outline** from a binary TOF1 record region: the
/// sequence's name and its step names grouped into Setup/Main/Cleanup.
///
/// Assembly rule (corpus-validated on the content-exact OutputVoltage twin,
/// where the grouped, ordered result equals the XML twin exactly): a step
/// belongs to the **nearest preceding group container** record (`Objs Setup` /
/// `Objs Main` / `Objs Cleanup`), and group containers/steps belong to the
/// nearest preceding sequence declaration ([_objectDeclarationPath] through
/// `Objs/Seq/[i]`) — the region lays each sequence's content out contiguously.
/// One placed step recovered from a binary step reference: its name and —
/// when the reference's type word lands in the file's type table — its step
/// TYPE name.
///
/// The binding (differential-sweep validated across the rosetta twins — 9
/// placed steps in 4 files, every byte offset/width/transform near each
/// step tested; the ONLY consistent survivor): the word after the `Step`
/// token is the step's **1-based index into the type table**
/// ([binaryTypeNames] order), NOT a string-pool reference. The historical
/// "kind token" reading (`ExprValue`/`Expression`/unique-ID) matched only
/// because low pool indices land in the typedef string region — e.g. the
/// oracle's `Update pin map` carries word 21 = type #20 `NI_UpdatePinMap`
/// (1-based 21), while pool[21] happens to be `'ExprValue'`.
class BinaryStepRef {
  const BinaryStepRef(this.name,
      {this.typeName, this.viPath, this.pythonModule, this.pythonFunction});

  /// The step's display name.
  final String name;

  /// The step's type name resolved from the type table, or null when the
  /// type word does not land in the recovered table (never fabricated).
  final String? typeName;

  /// The step's code-module binding, recovered from the **name→value word
  /// pairs** in the step's record span (this step reference up to the
  /// next): the module payload serializes each field as `[nameIdx]
  /// [valueIdx]` — `VIPath` for the LabVIEW adapter, `ModulePath` +
  /// `FunctionOrAttributeName` for the Python adapter. Twin-validated on
  /// the oracle (all four Python steps' paths and functions equal the
  /// XML's), and every rosetta LabVIEW binary yields its `VIPath` pairs.
  /// null when the span carries no such pair (no module, or an adapter
  /// whose pair tokens are not yet catalogued).
  final String? viPath;
  final String? pythonModule;
  final String? pythonFunction;

  @override
  String toString() =>
      'BinaryStepRef($name${typeName != null ? ': $typeName' : ''})';
}

class BinarySequenceOutline {
  const BinarySequenceOutline({
    required this.name,
    required this.setup,
    required this.main,
    required this.cleanup,
    this.ungrouped = const [],
  });

  /// The sequence name (path element `[1]` of its object declaration).
  final String name;

  /// Steps in declaration order per group, with their bound types.
  final List<BinaryStepRef> setup;
  final List<BinaryStepRef> main;
  final List<BinaryStepRef> cleanup;

  /// Steps whose group membership is not decodable from position (they are
  /// laid out before any group marker — seen on 7/294 corpus binaries).
  /// Reported here rather than guessed into a group.
  final List<BinaryStepRef> ungrouped;
}

/// The **sequence outlines** of a binary TOF1 file — each sequence with its
/// typed steps grouped into Setup/Main/Cleanup (see [BinarySequenceOutline]
/// for the assembly rule, and [BinaryStepRef] for the type binding).
/// Sequence-level properties, locals, parameters, and step modules are
/// **not yet decoded**. Returns `[]` when [seqBytes] is not an inflatable
/// binary file or does not frame.
List<BinarySequenceOutline> binarySequenceOutlines(Uint8List seqBytes) =>
    _withLayout(seqBytes, _sequenceOutlinesFromBody);

List<BinarySequenceOutline> _sequenceOutlinesFromBody(
    Uint8List body, int recordRegionLength,
    [List<String>? sharedPool, List<String>? sharedTypeNames]) {
  final pool = sharedPool ?? _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);

  // 1. sequence declarations, with offsets (same root-shape gate as
  // binarySequenceNames — see _isSequenceDeclaration)
  final sequenceDecls = <(int, String)>[];
  for (var at = 0; at + _minDeclarationBytes <= recordRegionLength; at++) {
    final path = _objectDeclarationPath(body, view, pool, at, recordRegionLength);
    if (path == null || !_isSequenceDeclaration(path)) continue;
    sequenceDecls.add((at, path[1]));
  }
  if (sequenceDecls.isEmpty) return const [];

  // 2. group-container markers (leaf records `Objs <group>`), with offsets
  final markers = <(int, String)>[];
  for (final record in _propertyRecordsFromBody(body, recordRegionLength)) {
    if (record.typeName == 'Objs' && _stepGroupNames.contains(record.name)) {
      markers.add((record.offset, record.name));
    }
  }

  // 3. step references, with offsets (same detection discriminator as
  // binaryStepNames). The word after the Step token doubles as the step's
  // 1-based TYPE-TABLE index (see BinaryStepRef) — detection still keys on
  // its pool-string shape (corpus-pinned, zero false positives), and the
  // type binds only when the index lands in the recovered table.
  final typeNames =
      sharedTypeNames ?? _typeNamesFromBody(body, recordRegionLength, pool);
  final stepToken = pool.indexOf(_stepToken);
  // First pass: detect references (offset, name, 1-based type index).
  final found = <(int, String, int)>[];
  int wordAt(int at) => view.getUint32(at, Endian.little);
  String? poolAt(int index) =>
      index > 0 && index < pool.length && pool[index].isNotEmpty
          ? pool[index]
          : null;
  if (stepToken > 0) {
    for (var at = 0;
        at + (_stepNameWordGap + 2) * _u32Bytes <= recordRegionLength;
        at++) {
      if (wordAt(at) != stepToken) continue;
      final typeWord = wordAt(at + _u32Bytes);
      final kind = poolAt(typeWord);
      final name = poolAt(wordAt(at + _stepNameWordGap * _u32Bytes));
      final container = poolAt(wordAt(at + (_stepNameWordGap + 1) * _u32Bytes));
      if (name == null || container == null || kind == null) continue;
      if (!_stepContainerTokens.contains(container)) continue;
      if (!_looksLikeUniqueId(kind) && !_stepExpressionKinds.contains(kind)) continue;
      found.add((at, name, typeWord - 1));
    }
  }
  // Second pass: each step's module fields from the name→value word pairs
  // in its span — this reference up to the next (or the region end). A
  // token may sit at several pool indices, so match against index SETS.
  Set<int> indicesOf(String token) =>
      {for (var i = 1; i < pool.length; i++) if (pool[i] == token) i};
  final viPathIdx = indicesOf('VIPath');
  final modulePathIdx = indicesOf('ModulePath');
  final functionIdx = indicesOf('FunctionOrAttributeName');
  String? pairIn(int start, int end, Set<int> nameIdx) {
    if (nameIdx.isEmpty) return null;
    for (var at = start; at + 2 * _u32Bytes <= end; at++) {
      if (!nameIdx.contains(wordAt(at))) continue;
      final value = poolAt(wordAt(at + _u32Bytes));
      if (value != null) return value;
    }
    return null;
  }

  final steps = <(int, BinaryStepRef)>[];
  for (var i = 0; i < found.length; i++) {
    final (at, name, typeIndex) = found[i];
    final spanEnd =
        i + 1 < found.length ? found[i + 1].$1 : recordRegionLength;
    steps.add((
      at,
      BinaryStepRef(
        name,
        typeName: typeIndex >= 0 && typeIndex < typeNames.length
            ? typeNames[typeIndex]
            : null,
        viPath: pairIn(at, spanEnd, viPathIdx),
        pythonModule: pairIn(at, spanEnd, modulePathIdx),
        pythonFunction: pairIn(at, spanEnd, functionIdx),
      ),
    ));
  }

  // 4. assemble: nearest preceding sequence decl, then nearest preceding marker
  sequenceDecls.sort((a, b) => a.$1.compareTo(b.$1));
  final outlines = {
    for (final (_, name) in sequenceDecls)
      name: {
        'Setup': <BinaryStepRef>[],
        'Main': <BinaryStepRef>[],
        'Cleanup': <BinaryStepRef>[],
      },
  };
  String sequenceAt(int offset) {
    var owner = sequenceDecls.first.$2;
    for (final (declOffset, name) in sequenceDecls) {
      if (declOffset < offset) owner = name;
    }
    return owner;
  }

  final ungrouped = <String, List<BinaryStepRef>>{
    for (final (_, name) in sequenceDecls) name: <BinaryStepRef>[],
  };
  for (final (stepOffset, step) in steps) {
    String? group;
    for (final (markerOffset, markerName) in markers) {
      if (markerOffset < stepOffset) group = markerName;
    }
    final owner = sequenceAt(stepOffset);
    if (group == null) {
      // Step laid out before any group marker (review-confirmed on 7/294
      // corpus binaries): its Setup/Main/Cleanup membership is not decodable
      // from position, so it is reported ungrouped rather than guessed.
      ungrouped[owner]!.add(step);
      continue;
    }
    // Duplicate names stay: distinct steps legitimately share a name.
    outlines[owner]![group]!.add(step);
  }

  final seenNames = <String>{};
  return [
    for (final (_, name) in sequenceDecls)
      if (seenNames.add(name))
        BinarySequenceOutline(
          name: name,
          setup: outlines[name]!['Setup']!,
          main: outlines[name]!['Main']!,
          cleanup: outlines[name]!['Cleanup']!,
          ungrouped: ungrouped[name]!,
        ),
  ];
}

/// Whether [cur] is packed immediately after [prev] in a NUL-terminated string
/// table — its offset is one byte (the single NUL) past the end of [prev]. The
/// back-to-back single-NUL packing invariant every chain-walker keys on.
bool _packedAfter(BinaryString prev, BinaryString cur) =>
    cur.offset == prev.offset + prev.text.length + 1;

/// Maximal chains of NUL-adjacent runs at/after [from], each of ≥[minChain].
List<List<BinaryString>> _segmentsFrom(
  List<BinaryString> runs,
  int from, {
  int minChain = _minSegmentChain,
}) {
  final segs = <List<BinaryString>>[];
  var chain = <BinaryString>[];
  for (final run in runs) {
    if (run.offset < from) continue;
    if (chain.isNotEmpty) {
      final prev = chain.last;
      if (!_packedAfter(prev, run)) {
        if (chain.length >= minChain) segs.add(chain);
        chain = <BinaryString>[];
      }
    }
    chain.add(run);
  }
  if (chain.length >= minChain) segs.add(chain);
  return segs;
}

List<int> _leadingWords(Uint8List body, int count) {
  final out = <int>[];
  final view = ByteData.sublistView(body);
  for (var i = 0; i + _u32Bytes <= body.length && out.length < count; i += _u32Bytes) {
    out.add(view.getUint32(i, Endian.little));
  }
  return out;
}

/// The offset where the first chain of ≥[chainMin] NUL-adjacent runs begins —
/// the start of the string region. Null if no such chain exists.
int? _firstTableOffset(
  List<BinaryString> runs, {
  int chainMin = _boundaryChainMin,
}) {
  var chainStart = -1;
  var len = 0;
  for (var i = 0; i < runs.length; i++) {
    if (i > 0) {
      final prev = runs[i - 1];
      if (_packedAfter(prev, runs[i])) {
        len++;
        continue;
      }
      if (len >= chainMin) return chainStart;
    }
    chainStart = runs[i].offset;
    len = 1;
  }
  return len >= chainMin ? chainStart : null;
}

/// Counts sentinel words (a u32 of [_sentinelByte]s) on u32 steps in
/// `bytes[0, end)`. [end] is clamped to the buffer so an over-large bound can't
/// read past it.
int _countSentinels(Uint8List bytes, int end) {
  final limit = end < bytes.length ? end : bytes.length;
  var count = 0;
  for (var i = 0; i + _u32Bytes - 1 < limit; i += _u32Bytes) {
    if (bytes[i] == _sentinelByte &&
        bytes[i + 1] == _sentinelByte &&
        bytes[i + 2] == _sentinelByte &&
        bytes[i + 3] == _sentinelByte) {
      count++;
    }
  }
  return count;
}

/// The largest contiguous **string table** in a binary TOF1 body: the longest
/// run of NUL-terminated strings packed back-to-back (each start == the previous
/// end + 1 NUL). The body holds such packed tables (a property-name/type table
/// and value/expression tables) that the records reference **by index** (name
/// byte-offsets are *not* referenced as u32 — verified). Which table this returns
/// (names vs values) depends on the file; the record grammar that links them is
/// **not yet decoded**, so this is a recon view, not a labeled name pool.
///
/// Returns the ordered strings (offsets into the inflated body), or `[]` when not
/// an inflatable binary file or no table ≥5 entries is found.
List<BinaryString> binaryStringTable(
  Uint8List seqBytes, {
  int minLength = _minRunLength,
}) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return _stringTableFromBody(body, minLength: minLength);
}

List<BinaryString> _stringTableFromBody(
  Uint8List body, {
  int minLength = _minRunLength,
}) {
  final runs = binaryStrings(body, minLength: minLength);
  var best = const <BinaryString>[];
  for (final chain in _segmentsFrom(runs, 0, minChain: 1)) {
    if (chain.length > best.length) best = chain;
  }
  return best.length >= _minTableEntries ? best : const [];
}

/// Everything the recon layer extracts from a binary TOF1 file, computed with a
/// **single** inflate of the body. The individual public helpers
/// ([binaryBodyStrings], [binaryStringTable], [analyzeBinaryBody],
/// [binaryNameTable]) each re-inflate; prefer this when you need several results
/// at once (e.g. building a document) so the zlib body is decompressed only once.
class BinaryAnalysis {
  const BinaryAnalysis({
    required this.inflatedSize,
    required this.strings,
    required this.stringTable,
    required this.layout,
    required this.nameTable,
    this.objectNames = const [],
    this.modulePaths = const [],
    this.stepReferences = const [],
    this.expressions = const [],
    this.quotedLiterals = const [],
    this.namedScalars = const [],
    this.scalarDoubles = const [],
    this.namedRecords = const [],
  });

  /// Size of the inflated body in bytes.
  final int inflatedSize;

  /// All printable runs in the body (== [binaryBodyStrings]).
  final List<BinaryString> strings;

  /// The largest contiguous packed table (== [binaryStringTable]).
  final List<BinaryString> stringTable;

  /// The framed body layout (== [analyzeBinaryBody]), or null if it didn't frame.
  final BinaryBodyLayout? layout;

  /// The content-identified property-name table's entries (== the entries of
  /// [binaryNameTable]), or empty when none was found.
  final List<BinaryString> nameTable;

  /// The file's own object names beyond the scaffold (== [binaryObjectNames]).
  final List<String> objectNames;

  /// Module call-target paths the file references (== [binaryModulePaths]).
  final List<String> modulePaths;

  /// `ID#:` step references the file carries (== [binaryStepReferences]).
  final List<String> stepReferences;

  /// Expression strings — the file's test logic (== [binaryExpressions]).
  final List<String> expressions;

  /// Quoted string literals — constant values (== [binaryQuotedLiterals]).
  final List<String> quotedLiterals;

  /// Named-property scalar records (== [binaryNamedScalarRecords]) — inline
  /// doubles tied to their offset-referenced property name, with raw (unmodeled)
  /// tag/type words.
  final List<BinaryNamedScalar> namedScalars;

  /// All distinct inline scalar `double` values (== [binaryScalarDoubles]) — the
  /// superset of [namedScalars]' values (those not in a decoded named record too).
  final List<double> scalarDoubles;

  /// Consistently-referenced named-property record headers (== [binaryNamedRecords])
  /// — the structural skeleton: which property/container names the records cite and
  /// how often, with the raw (unmodeled) consistent tag.
  final List<BinaryNamedRecord> namedRecords;
}

/// Inflates the binary TOF1 body **once** and runs the whole recon layer over it,
/// returning a [BinaryAnalysis]. Byte-for-byte equivalent to calling the
/// individual helpers, but decompresses the zlib stream a single time instead of
/// five-plus. Returns null when [seqBytes] is not an inflatable binary file.
BinaryAnalysis? analyzeBinary(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  final segments = _segmentsFromBody(body);
  final nameTable = _nameTableFromSegments(segments)?.entries ?? const [];
  final layout = _layoutFromBody(body);
  return BinaryAnalysis(
    inflatedSize: body.length,
    strings: binaryStrings(body, minLength: _poolMinRunLength),
    stringTable: _stringTableFromBody(body),
    layout: layout,
    nameTable: nameTable,
    objectNames: _objectNamesFrom([for (final entry in nameTable) entry.text]),
    modulePaths: _poolWhereFrom(segments, isBinaryModulePath),
    stepReferences: _poolWhereFrom(segments, _isStepRef),
    expressions: _poolWhereFrom(segments, isBinaryExpression),
    quotedLiterals: _poolWhereFrom(segments, isBinaryQuotedLiteral),
    namedScalars: layout == null
        ? const []
        : _namedScalarsFromBody(body, layout.recordRegionLength),
    scalarDoubles: layout == null
        ? const []
        : _scalarDoublesFromBody(body, layout.recordRegionLength),
    namedRecords: layout == null
        ? const []
        : _namedRecordsFromBody(body, layout.recordRegionLength),
  );
}
