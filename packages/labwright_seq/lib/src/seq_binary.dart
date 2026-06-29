import 'dart:io';
import 'dart:typed_data';

import 'seq_format.dart';

/// zlib stream first byte (CMF): deflate method, 32K window — the marker the
/// body scan keys on.
const _zlibCmf = 0x78;

/// Recognized zlib FLG second bytes (the byte after [_zlibCmf]) seen in TOF1
/// bodies — one documented catalog instead of scattered hex literals.
enum ZlibFlag {
  /// No compression / fastest.
  none(0x01),

  /// Default compression.
  byDefault(0x9c),

  /// Best compression.
  best(0xda);

  const ZlibFlag(this.byte);
  final int byte;

  /// Whether [b] is a recognized FLG byte.
  static bool isKnown(int b) =>
      b == none.byte || b == byDefault.byte || b == best.byte;
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

/// Minimum printable-run length when scanning the body for strings.
const _minRunLength = 3;

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
      final out = zlib.decode(bytes.sublist(i));
      if (out.length > _minInflatedBytes) return Uint8List.fromList(out);
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
List<BinaryString> binaryBodyStrings(Uint8List seqBytes, {int minLength = 2}) {
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

/// [analyzeBinaryBody] core over an already-inflated [body] (no re-inflate).
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

/// [binaryStringSegments] core over an already-inflated [body] (no re-inflate).
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
  return _objectNamesFrom([for (final e in table.entries) e.text]);
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
bool isBinaryModulePath(String s) =>
    s.contains('\\') && _modulePathRe.hasMatch(s);

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

/// [_poolWhere] core over already-computed [segments] (no inflate).
List<String> _poolWhereFrom(
  List<BinaryStringSegment> segments,
  bool Function(String) keep,
) {
  final seen = <String>{};
  final out = <String>[];
  for (final seg in segments) {
    for (final e in seg.entries) {
      if (keep(e.text) && seen.add(e.text)) out.add(e.text);
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

bool _isStepRef(String s) => s.startsWith('ID#:');

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
bool isBinaryExpression(String s) {
  if (s.startsWith('ID#:') || isBinaryModulePath(s)) return false;
  return _exprRootRe.hasMatch(s) ||
      _exprOpRe.hasMatch(s) ||
      _exprFnRe.hasMatch(s);
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
bool isBinaryQuotedLiteral(String s) =>
    s.length >= 2 &&
    s.startsWith('"') &&
    s.endsWith('"') &&
    !isBinaryExpression(s);

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

/// [binaryNameTable] core over already-computed [segments] (no re-inflate).
BinaryStringSegment? _nameTableFromSegments(
  List<BinaryStringSegment> segments,
) {
  BinaryStringSegment? best;
  var bestHits = 0;
  for (final seg in segments) {
    final texts = {for (final e in seg.entries) e.text};
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
List<int> binaryRecordWords(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  final layout = _layoutFromBody(body);
  if (layout == null) return const [];
  return _recordWordsFromBody(body, layout.recordRegionLength);
}

/// [binaryRecordWords] core over an already-inflated [body] (no re-inflate).
List<int> _recordWordsFromBody(Uint8List body, int recordRegionLength) {
  final rr = recordRegionLength;
  final out = <int>[];
  for (
    var i = 0;
    i + _u32Bytes <= rr && i + _u32Bytes <= body.length;
    i += _u32Bytes
  ) {
    out.add(body[i] | body[i + 1] << 8 | body[i + 2] << 16 | body[i + 3] << 24);
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
List<double> binaryScalarDoubles(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  final layout = _layoutFromBody(body);
  if (layout == null) return const [];
  return _scalarDoublesFromBody(body, layout.recordRegionLength);
}

/// [binaryScalarDoubles] core over an already-inflated [body] (no re-inflate),
/// given the record-region length [rr] — for the single-inflate [analyzeBinary]
/// path.
List<double> _scalarDoublesFromBody(Uint8List body, int rr) {
  final bd = ByteData.sublistView(body);
  final seen = <double>{};
  final out = <double>[];
  for (var i = 0; i + 8 <= rr && i + 8 <= body.length; i += _u32Bytes) {
    if ((body[i] | body[i + 1] | body[i + 2] | body[i + 3]) != 0) continue;
    final v = bd.getFloat64(i, Endian.little);
    if (!v.isFinite || v == 0) continue;
    final a = v.abs();
    if (a < _minScalarMagnitude || a > _maxScalarMagnitude) continue;
    if (seen.add(v)) out.add(v);
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

  @override
  String toString() =>
      'BinaryNamedScalar($name tag=$rawTag type=$rawTypeCode value=$value)';
}

/// Maps each string-region-relative byte offset to the name that begins there —
/// the inverse of a record's name-offset reference. Built from [binaryStrings]
/// (runs in the string region, keyed by `offset - recordRegionLength`).
Map<int, String> _stringRegionNamesByRel(Uint8List body, int rr) {
  final out = <int, String>{};
  for (final s in binaryStrings(body, minLength: 2)) {
    if (s.offset >= rr) out[s.offset - rr] = s.text;
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
List<BinaryNamedScalar> binaryNamedScalarRecords(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  final layout = _layoutFromBody(body);
  if (layout == null) return const [];
  return _namedScalarsFromBody(body, layout.recordRegionLength);
}

/// [binaryNamedScalarRecords] core over an already-inflated [body] (no
/// re-inflate), given the record-region length [rr] — for the single-inflate
/// [analyzeBinary] path. Word `w` is the record's name-offset word; `w-1` is the
/// tag, `w+1` the type-code, and `w+2..w+3` the inline f64.
List<BinaryNamedScalar> _namedScalarsFromBody(Uint8List body, int rr) {
  final relToName = _stringRegionNamesByRel(body, rr);
  if (relToName.isEmpty) return const [];

  final bd = ByteData.sublistView(body);
  final out = <BinaryNamedScalar>[];
  final wordCount = rr ~/ _u32Bytes;
  for (var w = 1; w + 3 < wordCount; w++) {
    final name = relToName[bd.getUint32(w * _u32Bytes, Endian.little)];
    if (name == null) continue;
    final fp = (w + 2) * _u32Bytes;
    if (fp + 8 > rr) continue;
    if (bd.getUint32(fp, Endian.little) != 0) continue;
    final v = bd.getFloat64(fp, Endian.little);
    if (!v.isFinite || v == 0) continue;
    final a = v.abs();
    if (a < _minScalarMagnitude || a > _maxScalarMagnitude) continue;
    out.add(BinaryNamedScalar(
      name: name,
      rawTag: bd.getUint32((w - 1) * _u32Bytes, Endian.little),
      rawTypeCode: bd.getUint32((w + 1) * _u32Bytes, Endian.little),
      value: v,
      wordIndex: w,
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

  @override
  String toString() =>
      'BinaryNamedRecord($name x$count, tag=$rawTag)';
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
bool _isNameLike(String s) =>
    !isBinaryQuotedLiteral(s) &&
    !isBinaryExpression(s) &&
    !isBinaryModulePath(s) &&
    !_isStepRef(s);

List<BinaryNamedRecord> binaryNamedRecords(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  final layout = _layoutFromBody(body);
  if (layout == null) return const [];
  return _namedRecordsFromBody(body, layout.recordRegionLength);
}

/// [binaryNamedRecords] core over an already-inflated [body] (no re-inflate),
/// given the record-region length [rr] — for the single-inflate [analyzeBinary].
List<BinaryNamedRecord> _namedRecordsFromBody(Uint8List body, int rr) {
  final relToName = _stringRegionNamesByRel(body, rr);
  if (relToName.isEmpty) return const [];

  final bd = ByteData.sublistView(body);
  final counts = <String, int>{};
  final tags = <String, Set<int>>{};
  final wordCount = rr ~/ _u32Bytes;
  for (var w = 1; w + 1 < wordCount; w++) {
    final off = bd.getUint32(w * _u32Bytes, Endian.little);
    if (off == 0) continue;
    final name = relToName[off];
    if (name == null || name.isEmpty || !_isNameLike(name)) continue;
    counts.update(name, (v) => v + 1, ifAbsent: () => 1);
    (tags[name] ??= <int>{}).add(bd.getUint32((w - 1) * _u32Bytes, Endian.little));
  }

  final out = <BinaryNamedRecord>[];
  for (final e in counts.entries) {
    final tagSet = tags[e.key]!;
    if (e.value < 2 || tagSet.length != 1) continue;
    out.add(BinaryNamedRecord(
      name: e.key,
      count: e.value,
      rawTag: tagSet.single,
    ));
  }
  out.sort((a, b) => b.count.compareTo(a.count));
  return out;
}

/// Maximal chains of NUL-adjacent runs at/after [from], each of ≥[minChain].
List<List<BinaryString>> _segmentsFrom(
  List<BinaryString> runs,
  int from, {
  int minChain = _minSegmentChain,
}) {
  final segs = <List<BinaryString>>[];
  var chain = <BinaryString>[];
  for (final r in runs) {
    if (r.offset < from) continue;
    if (chain.isNotEmpty) {
      final prev = chain.last;
      final adjacent = r.offset == prev.offset + prev.text.length + 1;
      if (!adjacent) {
        if (chain.length >= minChain) segs.add(chain);
        chain = <BinaryString>[];
      }
    }
    chain.add(r);
  }
  if (chain.length >= minChain) segs.add(chain);
  return segs;
}

/// Reads up to [count] little-endian u32 words from the start of [body].
List<int> _leadingWords(Uint8List body, int count) {
  final out = <int>[];
  for (
    var i = 0;
    i + _u32Bytes - 1 < body.length && out.length < count;
    i += _u32Bytes
  ) {
    out.add(body[i] | body[i + 1] << 8 | body[i + 2] << 16 | body[i + 3] << 24);
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
      final adjacent = runs[i].offset == prev.offset + prev.text.length + 1;
      if (adjacent) {
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
  var n = 0;
  for (var i = 0; i + _u32Bytes - 1 < limit; i += _u32Bytes) {
    if (bytes[i] == _sentinelByte &&
        bytes[i + 1] == _sentinelByte &&
        bytes[i + 2] == _sentinelByte &&
        bytes[i + 3] == _sentinelByte) {
      n++;
    }
  }
  return n;
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

/// [binaryStringTable] core over an already-inflated [body] (no re-inflate).
List<BinaryString> _stringTableFromBody(
  Uint8List body, {
  int minLength = _minRunLength,
}) {
  final runs = binaryStrings(body, minLength: minLength);
  List<BinaryString> best = const [];
  var chain = <BinaryString>[];
  for (final r in runs) {
    if (chain.isNotEmpty) {
      final prev = chain.last;
      final adjacent = r.offset == prev.offset + prev.text.length + 1;
      if (!adjacent) {
        if (chain.length > best.length) best = chain;
        chain = <BinaryString>[];
      }
    }
    chain.add(r);
  }
  if (chain.length > best.length) best = chain;
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
    strings: binaryStrings(body, minLength: 2),
    stringTable: _stringTableFromBody(body),
    layout: layout,
    nameTable: nameTable,
    objectNames: _objectNamesFrom([for (final e in nameTable) e.text]),
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
