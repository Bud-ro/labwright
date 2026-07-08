import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'seq_format.dart';

part 'seq_binary_metrics.dart';
part 'seq_binary_write.dart';

/// zlib stream first byte (CMF): deflate method, 32K window — the marker the
/// body scan keys on.
const _zlibCmf = 0x78;

/// Recognized zlib FLG second bytes (the byte after [_zlibCmf]) seen in TOF1
/// bodies — one documented catalog instead of scattered hex literals.
enum ZlibFlag {
  none(0x01),

  byDefault(0x9c),

  best(0xda)
  ;

  const ZlibFlag(this.byte);
  final int byte;

  static bool isKnown(int flagByte) => flagByte == none.byte || flagByte == byDefault.byte || flagByte == best.byte;
}

/// Minimum inflated size to accept a candidate zlib stream as the body — guards
/// against tiny false-positive streams.
const _minInflatedBytes = 64;

/// Hard cap on an inflated body (16× headroom over the largest real
/// corpus body, ~8 MB) — bounds a zlib decompression bomb during the
/// planned fuzzing. See [_inflateCapped].
const _maxInflatedBytes = 128 * 1024 * 1024;

/// The all-ones `ff ff ff ff` dword [_countSentinels] counts. NOTE: despite
/// the legacy "sentinel" name, these are **not** record delimiters (refuted
/// across the corpus — see [BinaryBodyLayout.sentinelCount]); they are
/// `0xffffffff` all-ones *values* in the byte-packed records — numerically
/// the same word as [_recordDelimiter], catalogued apart because the meaning
/// differs.
const _sentinelWord = 0xffffffff;

/// Bytes per little-endian u32 word in the record region.
const _u32Bytes = 4;

/// Bytes per little-endian IEEE-754 double in the record region.
const _f64Bytes = 8;

/// The smallest positive NORMAL IEEE-754 double (2^-1022). Values below it
/// (subnormals) are the diagnostic signature of a MIS-FRAMED scalar run:
/// small-integer / handle data read as an f64 collapses into this denormal
/// range (e.g. the i64 IDs `1..10` decode as ~5e-324). Genuine f64 array
/// elements are either exactly zero or human-scale reals, never subnormal,
/// so rejecting subnormals turns a mis-frame into an honest undecoded read.
const _smallestNormalF64 = 2.2250738585072014e-308;

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
  // Streamed with a hard output cap so a decompression bomb (a few KB
  // that inflates to gigabytes) aborts instead of exhausting memory —
  // the fuzzing corpus WILL feed hostile inputs. The cap is generous
  // vs. real files (the largest corpus body inflates to ~8 MB, ratio
  // ~22×) yet bounds the worst case. See [_locateAndInflateBody] (shared
  // with the writer's container model, which also needs the stream offset).
  return _locateAndInflateBody(bytes)?.$2;
}

/// Inflates [input] with a chunked [ZLibDecoder], returning null once the
/// running output exceeds [_maxInflatedBytes] — a decompression bomb
/// aborts after buffering at most one input chunk past the cap, never the
/// whole gigabyte output. Rethrows genuine format errors so the caller
/// keeps scanning.
Uint8List? _inflateCapped(Uint8List input) {
  final sink = _CappedByteSink(_maxInflatedBytes);
  final decoderInput = ZLibDecoder().startChunkedConversion(sink);
  const chunk = 1 << 16;
  for (var o = 0; o < input.length && !sink.overflowed; o += chunk) {
    final end = o + chunk < input.length ? o + chunk : input.length;
    decoderInput.add(Uint8List.sublistView(input, o, end));
  }
  if (!sink.overflowed) decoderInput.close();
  return sink.overflowed ? null : sink.takeBytes();
}

/// A byte sink that accumulates decoded chunks and latches [overflowed]
/// once the total passes [_cap], so [_inflateCapped] can stop feeding a
/// bomb.
class _CappedByteSink extends ByteConversionSink {
  _CappedByteSink(this._cap);

  final int _cap;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  bool overflowed = false;

  @override
  void add(List<int> chunk) {
    if (overflowed) return;
    _builder.add(chunk);
    if (_builder.length > _cap) overflowed = true;
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(Uint8List.sublistView(chunk as Uint8List, start, end));
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
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

BinaryBodyLayout? _layoutFromBody(Uint8List body) =>
    _layoutFromRuns(body, binaryStrings(body, minLength: _minRunLength));

BinaryBodyLayout? _layoutFromRuns(Uint8List body, List<BinaryString> runs) {
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
}) => _segmentsFromRuns(binaryStrings(body, minLength: _minRunLength), minChain: minChain);

List<BinaryStringSegment> _segmentsFromRuns(
  List<BinaryString> runs, {
  int minChain = _minSegmentChain,
}) {
  final boundary = _firstTableOffset(runs);
  if (boundary == null) return const [];
  return [
    for (final chain in _segmentsFrom(runs, boundary, minChain: minChain)) (offset: chain.first.offset, entries: chain),
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
  while (start < names.length && start < binaryNameScaffold.length && names[start] == binaryNameScaffold[start]) {
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
bool isBinaryModulePath(String text) => text.contains('\\') && _modulePathRe.hasMatch(text);

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
List<String> binaryModulePaths(Uint8List seqBytes) => _poolWhere(seqBytes, isBinaryModulePath);

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
List<String> binaryStepReferences(Uint8List seqBytes) => _poolWhere(seqBytes, _isStepRef);

bool _isStepRef(String text) => text.startsWith('ID#:');

/// Member access on a TestStand expression **root** (`Locals.x`, `Step.Result…`,
/// `RunState.LoopIndex`, `StationGlobals.…`, …) — the surest expression marker.
final _exprRootRe = RegExp(r'\b(Locals|Parameters|Step|RunState|FileGlobals|StationGlobals|Seq|ThisContext)\.');

/// A comparison / logical / ternary operator (the test-logic operators).
final _exprOpRe = RegExp(r'(==|!=|<=|>=|&&|\|\||\?.*:)');

/// A known TestStand expression **function call** (`Abs(`, `Str(`, `ResStr(`, …).
final _exprFnRe = RegExp(r'\b(Abs|Str|Val|Round|Mid|Len|Left|Right|ResStr|LocalizeExpression|Mod)\s*\(');

/// Whether [s] looks like a TestStand **expression** — the strings that carry a
/// sequence's actual logic: limit/condition comparisons, `RunState`/`Locals`/
/// `Step` member access, ternaries, and known expression-function calls. Module
/// paths ([isBinaryModulePath]) and `ID#:` step references are excluded so this
/// stays disjoint from those recoveries.
bool isBinaryExpression(String text) {
  if (text.startsWith('ID#:') || isBinaryModulePath(text)) return false;
  return _exprRootRe.hasMatch(text) || _exprOpRe.hasMatch(text) || _exprFnRe.hasMatch(text);
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
List<String> binaryExpressions(Uint8List seqBytes) => _poolWhere(seqBytes, isBinaryExpression);

/// Whether [s] is a **quoted string literal** — a whole entry wrapped in double
/// quotes (`"6105A"`, `"Unnamed Entry Point"`, `"%ModuleDescription"`), i.e. a
/// constant value rather than an [isBinaryExpression] (a quoted entry that also
/// contains operators — `"a" == "b"` — is an expression, not a literal, and is
/// excluded here so the recoveries stay disjoint).
bool isBinaryQuotedLiteral(String text) =>
    text.length >= 2 && text.startsWith('"') && text.endsWith('"') && !isBinaryExpression(text);

/// The **quoted string literals** a binary TOF1 file carries — constant values
/// its steps/expressions reference (instrument resource strings, expected values,
/// captions, …; see [isBinaryQuotedLiteral]), distinct and in name-pool order.
///
/// Recovered straight from the string pool; *which* literal a given step uses
/// needs the **not yet decoded** record grammar. Corpus-observed: 288/288 binary
/// files expose ≥1 (2883 distinct total). Returns `[]` when [seqBytes] is not an
/// inflatable binary file.
List<String> binaryQuotedLiterals(Uint8List seqBytes) => _poolWhere(seqBytes, isBinaryQuotedLiteral);

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
List<int> binaryRecordWords(Uint8List seqBytes) => _withLayout(seqBytes, _recordWordsFromBody);

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
  // Only the record/string boundary is needed here — use the cheap
  // boundary finder, not the full [_layoutFromBody] recon stats.
  final boundary = _recordRegionBoundary(body);
  if (boundary == null) return const <Never>[];
  return extract(body, boundary);
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
List<double> binaryScalarDoubles(Uint8List seqBytes) => _withLayout(seqBytes, _scalarDoublesFromBody);

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
    // A clean default has all-zero low 32 bits — one word read gates it.
    if (view.getUint32(i, Endian.little) != 0) continue;
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
List<BinaryNamedScalar> binaryNamedScalarRecords(Uint8List seqBytes) => _withLayout(seqBytes, _namedScalarsFromBody);

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
    out.add(
      BinaryNamedScalar(
        name: name,
        rawTag: view.getUint32((wordIndex - 1) * _u32Bytes, Endian.little),
        rawTypeCode: view.getUint32((wordIndex + 1) * _u32Bytes, Endian.little),
        value: value,
        wordIndex: wordIndex,
      ),
    );
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
    !isBinaryQuotedLiteral(text) && !isBinaryExpression(text) && !isBinaryModulePath(text) && !_isStepRef(text);

List<BinaryNamedRecord> binaryNamedRecords(Uint8List seqBytes) => _withLayout(seqBytes, _namedRecordsFromBody);

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
    out.add(
      BinaryNamedRecord(
        name: entry.key,
        count: entry.value,
        rawTag: tagSet.single,
      ),
    );
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
  value(22)
  ;

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
    required this.length,
    this.lead = 0,
    this.flagsByte = 0,
    this.kind = 0,
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

  /// The record's byte length — header through value and (when present)
  /// the trailing `u16` zero terminator. `offset + length` is where the
  /// scan resumed; used by the byte-coverage accounting.
  final int length;

  /// The record's LEAD byte, one of [_propRecordLeads] (`0x40`/`0x44`,
  /// corpus-observed; which of the two a record carries is not yet
  /// decoded) — retained typed-but-partially-interpreted.
  final int lead;

  /// The record's FLAGS byte (byte 1; `0x00`/`0x04` observed, bit
  /// meanings not yet decoded) — retained typed-but-uninterpreted.
  final int flagsByte;

  /// The record's KIND code ([_PropRecordField.kind]): a SHAPE
  /// classifier, not a byte size — `2` empty list, `4` bare (no stored
  /// value), `6` scalar value present, `14` special string form. A value
  /// `>= 6` ([_propScalarKind]) is what makes [value] decodable.
  final int kind;
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
List<BinaryPropertyRecord> binaryPropertyRecords(Uint8List seqBytes) => _withLayout(seqBytes, _propertyRecordsFromBody);

List<BinaryPropertyRecord> _propertyRecordsFromBody(
  Uint8List body,
  int recordRegionLength, [
  List<String>? sharedPool,
]) {
  final pool = sharedPool ?? _orderedStringPool(body, recordRegionLength);
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
    if (_propRecordLeads.contains(body[at + _PropRecordField.lead.offset]) && headerEnd <= recordRegionLength) {
      final kind = wordAt(at + _PropRecordField.kind.offset);
      final typeIndex = wordAt(at + _PropRecordField.typeNameIndex.offset);
      final nameIndex = wordAt(at + _PropRecordField.nameIndex.offset);
      final framed =
          wordAt(at + _PropRecordField.zeroA.offset) == 0 &&
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
        out.add(
          BinaryPropertyRecord(
            name: pool[nameIndex],
            typeName: typeName,
            value: value,
            offset: at,
            length: consumed,
            lead: body[at + _PropRecordField.lead.offset],
            flagsByte: body[at + _PropRecordField.lead.offset + 1],
            kind: kind,
          ),
        );
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

/// Reads the path words of the record at [at] — returned with the byte offset
/// just past the last path word consumed (for byte-coverage accounting) — or
/// `null` if it is not a path-declaration record. Stops at the first word that
/// is neither zero nor a resolvable pool index, and after
/// [_maxDeclarationPathWords] words.
(List<String>, int)? _objectDeclarationPath(
  Uint8List body,
  ByteData view,
  List<String> pool,
  int at,
  int recordRegionLength,
) {
  if (at + _PropRecordField.zeroA.offset + _u32Bytes > recordRegionLength) return null;
  if (!_propRecordLeads.contains(body[at + _PropRecordField.lead.offset])) return null;
  if (body[at + 1] != 0) return null; // flags byte
  final firstOffset = at + _PropRecordField.zeroA.offset;
  final first = view.getUint32(firstOffset, Endian.little);
  if (first == 0 || first >= pool.length || pool[first].isEmpty) return null;

  final path = <String>[];
  var offset = firstOffset;
  while (offset + _u32Bytes <= recordRegionLength && path.length < _maxDeclarationPathWords) {
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
  return (path, offset);
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
    path.length >= 5 && path[0] == '[]' && path[2] == 'Objs' && path[3] == 'Seq' && path[4].startsWith('[');

/// The **sequence names** of a binary TOF1 file, recovered from the object-path
/// declarations in the validated root shape (see [_isSequenceDeclaration]).
///
/// Corpus-validated two ways: on the six Rosetta binary twins this yields
/// exactly the sequence list their XML twins parse to (`[MainSequence]`; only
/// the OutputVoltage pair is content-exact — the others are same-sequence
/// re-saves), and a whole-corpus sweep emits zero structural-token false
/// positives. Files whose sequences are declared in a not-yet-decoded layout
/// honestly return `[]`. De-duplicated, first-seen order.
List<String> binarySequenceNames(Uint8List seqBytes) => _withLayout(seqBytes, _sequenceNamesFromBody);

List<String> _sequenceNamesFromBody(Uint8List body, int recordRegionLength) {
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final seen = <String>{};
  final names = <String>[];
  for (var at = 0; at + _minDeclarationBytes <= recordRegionLength; at++) {
    final decl = _objectDeclarationPath(body, view, pool, at, recordRegionLength);
    if (decl == null || !_isSequenceDeclaration(decl.$1)) continue;
    if (seen.add(decl.$1[1])) names.add(decl.$1[1]);
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
/// `binary_parse_seq_file_test.dart`). Whole-corpus sweep: 275/297 binaries
/// yield names, with zero structural-token fabrications beyond the three
/// pinned `Obj` counterexamples (a fully-framed record window named `Obj` in
/// one HIL project — genuine record vs over-detected head not yet decided;
/// see `binary_sweep_test.dart`). De-duplicated, in file order. Returns `[]`
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
/// nodes + framed-lite (scalar AND object forms) + inline instances w/
/// attr-scanned counts + class-name declarations + populated-array
/// bounds AND elements + substep elements + typed framed scalars +
/// element protos + EXTDATA landed; see [BinaryTypeField] and the body
/// parser). Every rosetta binary decodes every typedef body end to end
/// (zero bails, pinned by the binary tests); the corpus bail mass fell
/// from ~5.3 MB / 2,825 bodies to ~2.2 MB / 1,042.
/// Remaining:
///  * EXTDATA block CONTENT: the marshalling blocks (type-level opener
///    `[0][extCount]{blocks}[subCount]` and per-field 0x100-flagged
///    tails) are walked but their payloads (STRUCT packing/type/buffer
///    words, member-name slots) are not surfaced;
///  * corpus bodies whose 0x4-flagged fields store a zero attr word
///    (`LowExpr` `[0][0]`): no reliable arity signal found — counting
///    bit 0x4 in the attr floor was REFUTED both unconditionally (4
///    rosetta bodies break) and per record-prefix layout (0x76
///    exemplars regress); they stay bailing until per-field evidence
///    exists;
///  * framed VALUED scalars of a NON-`Expression` scalar type (e.g. an
///    enum `ModelType` = `'Sequential'`): the framed-scalar grammar only
///    covers the `Expression` case, so these bail (1 corpus record);
///  * the intrinsic-type id → name map ([BinaryTypeField.
///    intrinsicTypeId]: 2 = StepTypeSubstepsArray measured);
///  * locals/parameters: thin twin oracle (rosetta declares only the
///    implicit `ResultList`) — ride along once needed.
List<String> binaryTypeNames(Uint8List seqBytes) => _withLayout(seqBytes, _typeNamesFromBody);

/// The known field-flag bits (word 1 of a typedef field record; see
/// [BinaryTypeField] and the body parser). Cataloged so the known-bits
/// mask [_fieldKnownFlagBits] is DERIVED from the same source the code
/// tests against — a raw mask literal could silently drift from the
/// individual bit checks. Bits 0x4/0x8/0x20/0x40 advertise which flag
/// ATTRIBUTES the field stores; their exact arity is not reliable (see
/// `_attrTail`), so they are grouped rather than named individually.
const _fieldHasValueBit = 0x2; // a stored value follows
const _fieldAttrBits = 0x4 | 0x8 | 0x20 | 0x40; // flag-attribute markers
const _fieldFramedBit = 0x80; // delimiter-framed form
const _fieldHasExtDataBit = 0x100; // extdata (marshalling) tail
const _fieldHasFormatBit = 0x200; // display-format string after the value

/// Bit 0x800: the `Num` field carries a NUMERIC-REPRESENTATION word right
/// after the name — the XML `representation` attribute's code — and its
/// stored value (bit 0x2) is an **i64**, not the default f64. Measured on
/// the oracle: `NI_MeasurementParameter`'s typedef stores `ID` as
/// `[0x800][0][Num][ID][2][0]` and `Dimension` as `[…][Dimension][3][0]`
/// where the twin materializes `representation='Int64'`/`'UInt64'`, and
/// the placed step's enum members store `AC_VOLTS` as
/// `[0x802][0][Num][AC_VOLTS][2][i64 1][0]` — the twin's
/// `<value representation='Int64'>1</value>` exactly. Codes are surfaced
/// verbatim ([BinaryTypeField.numericRepresentation]); see
/// [BinaryNumericRepresentation] for the twin-evidenced code↔name pairs.
const _fieldHasNumericRepBit = 0x800;

/// Every bit the field grammar recognizes; a field carrying any OTHER
/// bit is a shape the grammar does not cover and bails.
const _fieldKnownFlagBits =
    _fieldHasValueBit |
    _fieldAttrBits |
    _fieldFramedBit |
    _fieldHasExtDataBit |
    _fieldHasFormatBit |
    _fieldHasNumericRepBit;

/// The numeric-representation codes with twin evidence (see
/// [_fieldHasNumericRepBit]): each pairs a binary code observed in the
/// oracle with the `representation` attribute its content-exact XML twin
/// writes for the same field. Codes without such evidence are surfaced
/// raw, never named.
enum BinaryNumericRepresentation {
  /// Code 2 ↔ `representation='Int64'` (oracle `ID`, enum members).
  int64(2, 'Int64'),

  /// Code 3 ↔ `representation='UInt64'` (oracle `Dimension`).
  uint64(3, 'UInt64')
  ;

  const BinaryNumericRepresentation(this.code, this.xmlName);

  /// The raw representation word value.
  final int code;

  /// The XML `representation` attribute the twin writes for this code.
  final String xmlName;

  /// The known mapping for [code], or null (raw code kept, name not guessed).
  static BinaryNumericRepresentation? of(int code) => switch (code) {
    2 => int64,
    3 => uint64,
    _ => null,
  };

  /// Whether [code] is a twin-evidenced INTEGER representation — the codes
  /// whose stored values are i64, the trigger for the i64 value read.
  static bool isInteger(int code) => of(code) != null;
}

/// Defensive cap on a typedef's subprop count (the largest real body in
/// the corpus carries 49 fields — TEInf).
const _typeMaxFields = 200;

/// Defensive cap on decoded populated-array elements (the largest real
/// corpus arrays are far smaller; this only bounds a hostile count).
const _maxArrayElements = 4096;

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
  List<BinaryTypeRecord> table, [
  int? endBoundary,
  int? typeIndexBase,
]) => _TypeBodyParser(view, pool, recordRegionLength, table, endBoundary, typeIndexBase).parse(after);

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

/// The field names that are ALWAYS `Expression`-typed across every record
/// generation and file — the format-expression properties every step type
/// declares. Their framed valued-scalar sites are the anchor
/// [deriveTypeIndexBase] uses to recover a file's type-index base: whatever
/// their `X` resolves to MUST be the table's `Expression` record, so the
/// base is `X - 1 - exprIndex`. Kept minimal and high-confidence — these two
/// are the display-format expressions, universally `Expression` (219 aligned
/// corpus files confirm `X - 1 == exprIndex`, i.e. base 0; the misaligned
/// cohort resolves them to a wrong record until rebased).
const _typeIndexAnchorFields = {'DescriptionFormat', 'DefaultNameFormat'};

/// Recovers the per-file type-index base (see [_TypeBodyParser.typeIndexBase]).
///
/// A framed 1-based reference `X` names `table[X - 1 - base]`. The recovered
/// head [table] can differ from TestStand's true type-index space in two
/// ways, both corpus-observed and both a CONSTANT per-file offset:
///  * the true space reserves engine-intrinsic types before the first
///    SERIALIZED record (e.g. `StepTypeSubstepsArray` ahead of `Expression`),
///    how many varying by record generation — a POSITIVE base;
///  * the head scan over-detects a record before `Expression` (an
///    enum/data record matching the type-record shape) — a NEGATIVE base.
/// The base is derived from the cross-format invariant that
/// [_typeIndexAnchorFields] are always `Expression`-typed: at each of their
/// framed valued-scalar sites the base candidates are `{X - 1 - i :
/// table[i] == 'Expression'}`, and the file's base is the value common to
/// EVERY anchor site (the one nearest zero when several agree). Returns 0
/// when no anchor site references the table (the aligned majority — those
/// sites carry X == 0, the implicit form — or old-generation files with no
/// framed table refs) or when the anchors disagree (never guessed).
/// Whole-corpus guard: aligned files derive 0, so resolution is unchanged.
int deriveTypeIndexBase(ByteData view, List<String> pool, int recordRegionLength, List<BinaryTypeRecord> table) {
  final exprIdx = <int>[];
  for (var i = 0; i < table.length; i++) {
    if (table[i].name == 'Expression') exprIdx.add(i);
  }
  if (exprIdx.isEmpty) return 0;
  const framedValued = 0x82; // 0x80 framed | 0x2 valued
  Set<int>? common;
  // How many framed anchor sites (X >= 1) actually constrained the base.
  // The base is the value common to EVERY such site, so all of them agree
  // with any base in [common]; a nonzero base standing on a SINGLE site is
  // uncorroborated (one coincidentally anchor-shaped run, or an ambiguous
  // multi-candidate set reduced by nearest-zero) and could mis-resolve
  // every framed type reference — so it is not adopted (see below).
  var anchorSites = 0;
  for (var at = 0; at + 6 * _u32Bytes <= recordRegionLength; at++) {
    final flags = view.getUint32(at, Endian.little);
    if (flags & framedValued != framedValued || flags & ~_fieldKnownFlagBits != 0) continue;
    if (view.getUint32(at + _u32Bytes, Endian.little) != 0) continue;
    if (view.getUint32(at + 2 * _u32Bytes, Endian.little) != _recordDelimiter) continue;
    final nameWord = view.getUint32(at + 4 * _u32Bytes, Endian.little);
    if (nameWord == 0 || nameWord >= pool.length || !_typeIndexAnchorFields.contains(pool[nameWord])) {
      continue;
    }
    final x = view.getUint32(at + 3 * _u32Bytes, Endian.little);
    if (x < 1) continue;
    // Each Expression record index yields one base under which this X
    // resolves to it (always in range: X - 1 - (X - 1 - e) == e).
    final cands = {for (final e in exprIdx) x - 1 - e};
    common = common == null ? cands : common.intersection(cands);
    if (common.isEmpty) return 0;
    anchorSites++;
  }
  if (common == null) return 0;
  final base = common.reduce((a, b) => a.abs() < b.abs() ? a : b);
  // Base 0 is the well-aligned default and always safe; a NONZERO base
  // demands corroboration — at least two agreeing anchor sites — before it
  // is trusted to rebase the whole table.
  if (base != 0 && anchorSites < 2) return 0;
  return base;
}

/// The recursive typedef-body field parser — see [_typeFieldsAt].
class _TypeBodyParser {
  _TypeBodyParser(this.view, this.pool, this.recordRegionLength, this.table, [this.bodyEndBoundary, int? typeIndexBase])
    : typeIndexBase = typeIndexBase ?? deriveTypeIndexBase(view, pool, recordRegionLength, table);

  final ByteData view;
  final List<String> pool;
  final int recordRegionLength;
  final List<BinaryTypeRecord> table;

  /// Write-op capture (the writer's re-serialization plan — see
  /// `seq_binary_write.dart`). The shared no-op sink ([_DecodeSink.none])
  /// on plain decode runs; under a recording sink every COMMITTED parse
  /// records the typed ops that re-emit its bytes, and every failed trial
  /// rolls its ops back. Pure additions: the sink never influences parse
  /// decisions.
  _DecodeSink ops = _DecodeSink.none;

  /// How many engine-intrinsic types precede the first SERIALIZED type
  /// record in this file's type-index space, so a framed 1-based
  /// reference `X` names [table]`[X - 1 - typeIndexBase]` (see
  /// [deriveTypeIndexBase] and [_tableRef]). Zero for the aligned
  /// majority; nonzero for files whose record generation reserves leading
  /// intrinsic types (e.g. `StepTypeSubstepsArray` before `Expression`).
  /// The X == 0 (implicit) and X == 1 !valued (custom instance) forms are
  /// generation-level sentinels and are NOT rebased.
  final int typeIndexBase;

  /// Whether [x] is a framed reference that resolves inside [table] under
  /// the file's [typeIndexBase].
  bool _validTableX(int x) {
    final i = x - 1 - typeIndexBase;
    return i >= 0 && i < table.length;
  }

  /// The type record a framed 1-based reference [x] names, rebased by
  /// [typeIndexBase]. Callers gate with [_validTableX] first.
  BinaryTypeRecord _tableRef(int x) => table[x - 1 - typeIndexBase];

  /// Where this body must END — the next type record's head start minus
  /// its preamble ([_typeRecordPreambleBytes]) — or null for the last
  /// record. An element-type spec skip is only accepted when the
  /// remaining fields land EXACTLY here; without this gate a trial skip
  /// can re-anchor inside the spec (its interior parses as field-alikes)
  /// and fabricate a body, measured on TEInf/DotNetStepAdditions.
  final int? bodyEndBoundary;

  int _u32(int at) => view.getUint32(at, Endian.little);
  String? _tok(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;

  /// Identifier shape a pool-index-0 CLASS token must have (see [_clsTok]).
  static final _rootClassPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,39}$');

  /// Resolves a CLASS-SLOT word: like [_tok], but index 0 additionally
  /// resolves to `pool[0]` — the file's ROOT token. The TS 4.x-era record
  /// generation puts `Obj` first in the pool (corpus-measured pool[0]
  /// values over 297 binaries: 221× `SequenceFileData` [newer gen], 47×
  /// `Obj`, 19× `SemiconductorModule`, 4× `StepType`, 3× `Enum`, 3 other)
  /// and its `Obj`-classed fields reference it by index 0 — the shape
  /// `[flags][0][0][name]` that previously bailed as "class slot zero".
  /// Only an identifier-shaped root resolves ([_rootClassPattern]); word 0
  /// outside a class slot keeps its framing-zero meaning everywhere else.
  String? _clsTok(int word) {
    if (word != 0) return _tok(word);
    if (pool.isEmpty) return null;
    final root = pool[0];
    return _rootClassPattern.hasMatch(root) ? root : null;
  }

  /// Whether [token] is an array-bound token: `'[]'`, `'[<digits>]'`, or
  /// a MULTI-DIMENSIONAL chain `'[<digits>][<digits>]…'` (the XML twin
  /// writes these verbatim as lbound/ubound — corpus arrays store 2-D
  /// locals as `lbound='[0][0]' ubound='[30][50]'`).
  static final _boundPattern = RegExp(r'^(\[\d*\])+$');
  static bool _isBoundToken(String? token) => token != null && _boundPattern.hasMatch(token);

  /// Whether any element-type spec was walked during the current
  /// [parse] — arms the body-end boundary gate (a walker misparse must
  /// never fabricate a body silently).
  bool _usedSpec = false;

  /// Current field-nesting depth. Bounded by [_maxFieldDepth] so a
  /// hostile body of self-nesting declarations (each descriptor node
  /// costs ~20 bytes and one recursion level) bails instead of
  /// overflowing the stack — [parse] must be total over arbitrary input.
  int _depth = 0;

  /// Whether the walk is inside an INSTANCE's children (framed X >= 1).
  /// There an unvalued field means "value INHERITED from the type's
  /// default" (Action's TS stores PassAct with flags 0x60 and no value
  /// — a flags-only override of TEInf's default 'Next'), so class
  /// defaults must not be materialized; [BinaryTypeField.value] stays
  /// null and consumers treat it as not-overridden.
  bool _inInstance = false;

  /// Numeric-representation codes BY FIELD NAME of the instance type
  /// whose children are being parsed, from its typedef's 0x800-flagged
  /// `Num` fields ([_reprsOf]). Inside such an instance a plain valued
  /// `[0x2]` Num INHERITS its representation, so its stored value is an
  /// i64 when the typedef declares an integer representation — measured
  /// on the oracle: the placed step's `NI_MeasurementParameter` element
  /// stores `ID` as `[0x2][0][Num][ID][i64 7]` (the twin's
  /// `<value representation='Int64'>7</value>`; an f64 read yields a
  /// denormal, not 7). Null outside instances / when the type stores no
  /// integer-represented Nums. Slots this context does not reach (element
  /// types riding an unresolved elemproto) are covered by the
  /// subnormal-signature i64 read at the value site — see the plain `Num`
  /// case in [_fieldParse].
  Map<String, int>? _numericReprContext;

  /// The integer-representation map of [ref]'s decoded typedef fields, or
  /// null when it has none (or its body is undecoded).
  static Map<String, int>? _reprsOf(BinaryTypeRecord ref) {
    Map<String, int>? out;
    for (final field in ref.fields ?? const <BinaryTypeField>[]) {
      final code = field.numericRepresentation;
      if (code != null && BinaryNumericRepresentation.isInteger(code)) {
        (out ??= {})[field.name] = code;
      }
    }
    return out;
  }

  /// Consumes a field's ATTR-WORD tail: zero or more nonzero words —
  /// the field's flag attributes, `flagsforinstances`/
  /// `instanceoverrideflags`/`valueflags` when present (TEInf.Links
  /// stores its twin's exact 71303168/72286233/71303168 triple; 0x4d0018
  /// everywhere is the ubiquitous `instanceoverrideflags='5046296'`) —
  /// then the 0 terminator. Returns the offset after the terminator, or
  /// null when no terminator arrives within the cap. On array fields, an
  /// attr word with bit 0x8000 (0x8001/0x8801 measured) signals a
  /// trailing element-type spec and arms [_specPending].
  ///
  /// [minWords]: attr slots can be ZERO-VALUED, in which case the
  /// until-zero rule alone would mistake them for the terminator. The
  /// field's flag bits give the floor: one stored attr word per set bit
  /// of 0x8/0x20/0x40 (measured: `ReportText` flags 0x20 stores `[0][0]`
  /// — one zero attr, then the terminator; a substep's `TS` flags 0x60
  /// stores two; `DescriptionFormat` flags 0xEE stores three). The first
  /// [minWords] words are consumed as attrs regardless of value; beyond
  /// the floor the until-zero rule still applies (rosetta bodies store
  /// MORE words than the bits promise — `Substep.TS.Result` stores two
  /// 0x400000 where its bits promise one — so the floor is a minimum,
  /// not an exact arity).
  /// [attrsOut]: when given, each consumed attr word (not the terminator)
  /// is collected for the field's typed model surface
  /// ([BinaryTypeField.attrWords]) and emitted as a MODEL word; without a
  /// collector (structural probe walks whose ops are rolled back) the
  /// words stay retained structure. The verified 0 terminator is
  /// grammar-determined either way.
  int? _attrTail(int from, {int minWords = 0, List<int>? attrsOut}) {
    final m = ops.mark();
    var at = from;
    for (var i = 0; i <= _fieldMaxAttrWords; i++) {
      if (at + _u32Bytes > recordRegionLength) return _blockBail(m);
      final word = _u32(at);
      if (word == 0 && i >= minWords) {
        ops.u32(at, 0, _OpSource.grammar); // the verified attr-tail terminator
        return at + _u32Bytes;
      }
      if (attrsOut != null) {
        attrsOut.add(word);
        ops.u32(at, word, _OpSource.model);
      } else {
        ops.u32(at, word, _OpSource.struct);
      }
      at += _u32Bytes;
      // Bits 0x8000/0x800 accompany SOME element-type specs (0x8001/
      // 0x8801/0x801) but are unreliable in both directions (Substep.TS's
      // CustomResults spec follows a plain 0x1; Action.Substeps carries
      // 0x8001800 with no spec at all) — specs are detected by their
      // DELIM-led frame instead (see [_fields]).
    }
    return _blockBail(m);
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
  ///
  /// The walk is a PROBE for the writer: its interior parses (fields,
  /// attr tails) capture no lasting write ops — callers copy the whole
  /// extent verbatim, mirroring the coverage pass's structural demotion
  /// of spec blobs.
  int? _elementSpec(int at) {
    final m = ops.mark();
    final end = _elementSpecWalk(at);
    ops.rollback(m);
    return end;
  }

  int? _elementSpecWalk(int at) {
    var p = at;
    if (p >= recordRegionLength) return null;
    // A single realignment pad byte precedes the frame after non-Objs
    // arrays (Objs arrays already consume their own pad).
    if (view.getUint8(p) == 0) p++;
    // Reads its words one at a time, each bounds-checked — the frame is
    // variable-length (optional X word, optional 0x20000 tag), so a
    // single entry guard cannot cover the later reads.
    if (!_canRead(p) || _u32(p) != _recordDelimiter) return null;
    p += _u32Bytes;
    // X = the element type as a 1-based table reference. When the next
    // word is already the closing delimiter, X is OMITTED — a
    // self/inherit reference (Substep.TS's CustomResults spec reads
    // [DELIM][DELIM][count]).
    if (!_canRead(p)) return null;
    final x = _u32(p);
    var xOmitted = false;
    if (x == _recordDelimiter) {
      xOmitted = true;
      p += _u32Bytes;
    } else {
      if (!_validTableX(x)) return null;
      p += _u32Bytes;
      if (!_canRead(p) || _u32(p) != _recordDelimiter) return null;
      p += _u32Bytes;
    }
    if (!_canRead(p)) return null;
    var tagged = false;
    // A scalar-classed element prototype stores its VALUE token before
    // the 0x20000 tag (FCParameter.ArrayDimensionsSize's elemproto:
    // [DELIM][X=Expression][DELIM]['1024'][0x20000][0][0] — the XML
    // twin shape writes `<elemproto>…<value>1024</value>`). The token
    // is only accepted when the tag follows, keeping the forms disjoint.
    if (_tok(_u32(p)) != null && p + 2 * _u32Bytes <= recordRegionLength && _u32(p + _u32Bytes) == 0x20000) {
      p += _u32Bytes;
    }
    if (_u32(p) == 0x20000) {
      tagged = true;
      p += _u32Bytes;
      if (!_canRead(p)) return null;
    }
    final count = _u32(p);
    // Zero items frames as a full spec under the 0x20000 tag
    // (PythonCall.Parameters' type spec) or with an EXPLICIT X — in both
    // the element type is fully named, so no descriptor items follow
    // (NI_Measurement's Parameters spec:
    // `[DELIM][X=NI_MeasurementParameter][DELIM][0][0]`). An untagged
    // X-less [DELIM][DELIM][0][0][0] is the short REFERENCE spec
    // ([_refSpec]) instead.
    if ((count < 1 && !tagged && xOmitted) || count > _typeMaxFields) return null;
    p += _u32Bytes;
    final items = _fields(p, count);
    if (items == null) return null;
    return _attrTail(items.$2);
  }

  /// Whether a `u32` can be read at [at] within the record region.
  bool _canRead(int at) => at + _u32Bytes <= recordRegionLength;

  /// Bails a parse that already recorded write ops: rolls back to mark [m]
  /// and returns null — the shared failure exit of the op-emitting parsers.
  Null _blockBail(int m) {
    ops.rollback(m);
    return null;
  }

  /// The per-dimension integers of a (possibly multi-dimensional) bound
  /// token (`'[30][50]'` → `[30, 50]`), or null when any dimension is
  /// empty/malformed.
  static List<int>? _boundDims(String token) {
    final dims = <int>[];
    for (final m in RegExp(r'\[(\d*)\]').allMatches(token)) {
      final v = int.tryParse(m.group(1)!);
      if (v == null) return null;
      dims.add(v);
    }
    return dims.isEmpty ? null : dims;
  }

  /// The ELEMENT COUNT a populated array's bound-token pair declares —
  /// the product over dimensions of `ubound − lbound + 1` (row-major
  /// storage; multi-dimensional corpus locals measured at exactly
  /// `∏(ubᵢ−lbᵢ+1)` inline elements). Null on empty/malformed bounds,
  /// dimension-count mismatch, or an inverted range.
  static int? _boundCount(String lbound, String ubound) {
    final lb = _boundDims(lbound);
    final ub = _boundDims(ubound);
    if (lb == null || ub == null || lb.length != ub.length) return null;
    var count = 1;
    for (var i = 0; i < lb.length; i++) {
      if (ub[i] < lb[i]) return null;
      count *= ub[i] - lb[i] + 1;
      if (count > _maxArrayElements) return null;
    }
    return count;
  }

  /// Decodes a POPULATED `Objs` array's element tail, starting right
  /// after the bound tokens. The element count is `ubound − lbound + 1`.
  /// Two context-split tail layouts, both anchor-measured on the oracle
  /// and validated value-for-value against the content-exact twin:
  ///
  ///  * DECLARATION context (a typedef/object field —
  ///    `Measurement.Parameters '[0]' '[10]'`, 11 blocks):
  ///    `[attrs…][0][one 0x00 pad]{elements}` — the standard array tail,
  ///    then the elements chained with no closing terminator (the count
  ///    bounds the run).
  ///  * INSTANCE context (a field inside an element/override instance —
  ///    `EnumDefinition '[0]' '[1]'`, 2 plain Num members):
  ///    `[one 0x00 pad]{elements}[attrs…][0]`.
  ///
  /// Count-gated and terminator-gated, all-or-nothing: any element that
  /// does not frame returns null and the array falls back to the
  /// structural blob walk.
  (List<BinaryTypeField>, int)? _populatedArrayTail(int at, String lbound, String ubound, {List<int>? attrsOut}) {
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (_inInstance) {
      // Instance layout: `[one 0x00 pad][proto?]{elements}[attrs…][0]`
      // (EnumDefinition; ArrayDimensionsSize carries a leading proto
      // block before its element). Some instance arrays instead use the
      // declaration layout with a leading attr tail (a substep SData's
      // `Parms`/`Calls`: `[attrs…][0][pad][proto?]{elements}`) — tried
      // second; both are all-or-nothing, arbitrated by the element
      // count, the terminators, and the body-end boundary gate.
      if (at < recordRegionLength && view.getUint8(at) == 0) {
        for (final start in _protoSpecEnds(at + 1)) {
          final m = ops.mark();
          final attrsMark = attrsOut?.length;
          ops.byte(at, 0, _OpSource.grammar); // the verified realignment pad
          ops.copy(at + 1, start); // proto block: extent walked, undecoded
          final elements = _elementRun(start, count);
          if (elements == null) {
            ops.rollback(m);
            continue;
          }
          final after = _attrTail(elements.$2, attrsOut: attrsOut);
          if (after != null) {
            _usedSpec = true;
            return (elements.$1, after);
          }
          ops.rollback(m);
          if (attrsMark != null) attrsOut!.length = attrsMark;
        }
      }
    }
    // Declaration layout: `[attrs…][0][pad][proto?]{elements}` — the
    // standard array tail, then the elements chained with no closing
    // terminator (the count bounds the run).
    final mDecl = ops.mark();
    final attrsDeclMark = attrsOut?.length;
    final tail = _attrTail(at, attrsOut: attrsOut);
    if (tail == null || tail >= recordRegionLength || view.getUint8(tail) != 0) {
      ops.rollback(mDecl);
      if (attrsDeclMark != null) attrsOut!.length = attrsDeclMark;
      return null;
    }
    ops.byte(tail, 0, _OpSource.grammar); // the verified pad after the array tail
    for (final start in _protoSpecEnds(tail + 1)) {
      final m = ops.mark();
      ops.copy(tail + 1, start); // proto block: extent walked, undecoded
      final elements = _elementRun(start, count);
      if (elements == null) {
        ops.rollback(m);
        continue;
      }
      // Element decode is boundary-sensitive like a spec walk — arm the
      // body-end overrun gate so a misparse can never fabricate a body.
      // (An unconditional closing-zero consume after proto'd runs was
      // tried and REFUTED: it ate the zero-led word following a proto'd
      // run inside NI_Measurement's typedef body — some instance-context
      // arrays DO trail one closing zero (`ArrayDimensionsSize`:
      // `[attrs][0][pad][proto]{element}[0]`), but no local rule
      // separates them; those parents stay bailing until parent-level
      // evidence exists.)
      _usedSpec = true;
      return (elements.$1, elements.$2);
    }
    ops.rollback(mDecl);
    if (attrsDeclMark != null) attrsOut!.length = attrsDeclMark;
    return null;
  }

  /// The candidate offsets an element run may start at, given an
  /// optional leading ELEMENT-PROTO block at [at]: after a six-word
  /// proto ([_protoSpec]), after the shorter five-word VALUED variant
  /// `[00 pad?][DELIM][DELIM][value][0][0]` (no attr slot — measured on
  /// instance-context `ArrayDimensionsSize`, value `'1024'`, whose XML
  /// twin writes `<elemproto>…<value>1024</value></elemproto>`), or [at]
  /// itself (no proto). The caller tries each in order; the count-gated
  /// element run and closing terminator arbitrate — a wrong candidate
  /// cannot decode.
  List<int> _protoSpecEnds(int at) {
    final ends = <int>[];
    final six = _protoSpec(at);
    if (six != null) ends.add(six);
    var p = at;
    if (p < recordRegionLength && view.getUint8(p) == 0) p++;
    if (p + 5 * _u32Bytes <= recordRegionLength &&
        _u32(p) == _recordDelimiter &&
        _u32(p + _u32Bytes) == _recordDelimiter &&
        _tok(_u32(p + 2 * _u32Bytes)) != null &&
        _u32(p + 3 * _u32Bytes) == 0 &&
        _u32(p + 4 * _u32Bytes) == 0) {
      final five = p + 5 * _u32Bytes;
      if (!ends.contains(five)) ends.add(five);
    }
    ends.add(at);
    return ends;
  }

  /// Decodes a populated plain SCALAR array's element run, starting right
  /// after the bound tokens: `{count × f64}[attr words…][0]` — the
  /// elements are stored inline back-to-back (no per-element framing),
  /// then the standard attr tail closes the field. Elements surface as
  /// anonymous `Num` children (the XML twin writes each as an unnamed
  /// `<value>`), formatted with the same f64 text rule as scalar `Num`
  /// fields. Returns null when the run + tail do not frame.
  (List<BinaryTypeField>, int)? _scalarArrayTail(int at, String lbound, String ubound, {List<int>? attrsOut}) {
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (at + count * _f64Bytes > recordRegionLength) return null;
    final m = ops.mark();
    final elements = <BinaryTypeField>[];
    var p = at;
    for (var i = 0; i < count; i++, p += _f64Bytes) {
      final value = view.getFloat64(p, Endian.little);
      // All-or-nothing per-element gate: reject NaN/Inf AND subnormals. A
      // single non-value element fails the whole run, so a mis-framed Nums
      // field (whose integer/handle words collapse into the denormal range)
      // falls back to the bounds-only undecoded read instead of emitting
      // fabricated numbers.
      if (!value.isFinite || (value != 0 && value.abs() < _smallestNormalF64)) {
        return _blockBail(m);
      }
      ops.f64(p, value);
      final text = value == value.truncateToDouble() && value.abs() < 1e15 ? '${value.truncate()}' : '$value';
      elements.add(BinaryTypeField('', className: 'Num', value: text));
    }
    final attrsMark = attrsOut?.length;
    final after = _attrTail(p, attrsOut: attrsOut);
    if (after == null) {
      ops.rollback(m);
      if (attrsMark != null) attrsOut!.length = attrsMark;
      return null;
    }
    return (elements, after);
  }

  /// Walks an empty array's trailing ELEMENT-TYPE block —
  /// `[classRef][DELIM][0][attr words…][0]` — returning the element
  /// class/type name and the offset after the block, or null when the
  /// bytes do not frame (see the call site for the disjointness
  /// argument).
  (String, int)? _elemProtoTail(int at) {
    if (at + 3 * _u32Bytes > recordRegionLength) return null;
    final cls = _tok(_u32(at));
    if (cls == null) return null;
    if (_u32(at + _u32Bytes) != _recordDelimiter) return null;
    if (_u32(at + 2 * _u32Bytes) != 0) return null;
    // Probe for the writer: the block is surfaced as an undecoded spec
    // blob, so the caller copies its extent — no lasting attr-tail ops.
    final m = ops.mark();
    final after = _attrTail(at + 3 * _u32Bytes);
    ops.rollback(m);
    if (after == null) return null;
    return (cls, after);
  }

  /// Exactly [count] chained array elements starting at [at].
  (List<BinaryTypeField>, int)? _elementRun(int at, int count) {
    final m = ops.mark();
    var p = at;
    final elements = <BinaryTypeField>[];
    for (var i = 0; i < count; i++) {
      final element = _arrayElement(p);
      if (element == null) return _blockBail(m);
      elements.add(element.$1);
      p = element.$2;
    }
    return (elements, p);
  }

  /// Walks an ELEMENT-PROTO block — the binary form of a scalar-classed
  /// XML `<elemproto>` (a populated or sized-empty array's element
  /// prototype): a fixed six-word block
  /// `[00 pad?][DELIM][DELIM][value|0][0][attr|0][0]`.
  /// Measured: `[D][D][0][0][0x80][0]` on the oracle's `Calls`
  /// (DotNetCall elements) and the corpus `Parms` (FCParameter
  /// elements); `[D][D]['1024'][0][0][0]` on the corpus
  /// `ArrayDimensionsSize` whose XML twin shape writes
  /// `<elemproto>…<value>1024</value></elemproto>`. A proto with
  /// OBJECT content (the typedef bodies' element-type specs) frames as
  /// a full [_elementSpec] instead. Only the extent is walked — the
  /// value/attr slots are surfaced via the spec blob, not decoded.
  /// Returns the offset after the block, or null.
  int? _protoSpec(int at) {
    var p = at;
    if (p >= recordRegionLength) return null;
    if (view.getUint8(p) == 0) p++;
    if (p + 6 * _u32Bytes > recordRegionLength) return null;
    if (_u32(p) != _recordDelimiter || _u32(p + _u32Bytes) != _recordDelimiter) {
      return null;
    }
    final value = _u32(p + 2 * _u32Bytes);
    if (value != 0 && _tok(value) == null) return null;
    if (_u32(p + 3 * _u32Bytes) != 0) return null;
    if (_u32(p + 5 * _u32Bytes) != 0) return null;
    // An all-zero block would also read as other spec shapes; require
    // SOME content (a value or an attr word) so the forms stay disjoint.
    if (value == 0 && _u32(p + 4 * _u32Bytes) == 0) return null;
    return p + 6 * _u32Bytes;
  }

  /// One populated-array element: an instance BLOCK
  /// `[pad 0?][DELIM][X][DELIM][count]{fields}[attrs…][0]` — X is the
  /// element's type as a 1-based table reference and the element name is
  /// not serialized (the twin writes `name=''`) — or, for scalar members
  /// (EnumDefinition's Num members), a PLAIN field carrying its own name.
  (BinaryTypeField, int)? _arrayElement(int at) {
    // A block may carry one realignment pad byte before its delimiter.
    for (final start in [at, if (at < recordRegionLength && view.getUint8(at) == 0) at + 1]) {
      if (!_canRead(start) || _u32(start) != _recordDelimiter) continue;
      final m = ops.mark();
      if (start > at) ops.byte(at, 0, _OpSource.grammar); // the verified realignment pad
      final block = _elementBlock(start);
      if (block == null) ops.rollback(m);
      return block;
    }
    // Named STEP element (a `Substeps` array's substep, or a sequence
    // group array's placed step) — a `Step`-led element is ALWAYS a step:
    // when it does not decode, the element fails (all-or-nothing) rather
    // than falling through, because the compact field form would misread
    // its first two words as `[name][value]` and fabricate a field named
    // `Step` (observed on a Setup array whose Action step's TS bailed).
    if (!_canRead(at)) return null;
    if (_tok(_u32(at)) == _stepToken) return _stepElement(at);
    // Plain-field element (its own [flags][0][cls][name] head).
    final outer = _inInstance;
    _inInstance = true;
    final field = _field(at);
    _inInstance = outer;
    return field;
  }

  /// A NAMED step element of a populated `Substeps` array:
  /// `['Step' clsRef][X][nameRef][childCount]{fields}` — the binary form
  /// of the XML `<Step typename='Substep' name='OnNewStep'>` substep
  /// (class ref `Step` and X measured on the oracle's NI_Measurement —
  /// X=10→`Substep` — and the corpus NI_Wait/MessagePopup families —
  /// X=20→`Substep`; the corpus XML `LoopForever.seq` materializes the
  /// same substeps with exactly this structure). Children serialize as
  /// an override subset in the standard field grammar (the `TS`
  /// descriptor node with `Id`/`SData`…), so they compare by name
  /// against a materialized twin. Disjoint from every [_field] form:
  /// a field's second word is 0 (flags forms) or a stored value
  /// (compact), never a type-table index gated `1..table.length` with a
  /// resolvable class token `Step` before it.
  (BinaryTypeField, int)? _stepElement(int at) {
    if (at + 4 * _u32Bytes > recordRegionLength) return null;
    if (_tok(_u32(at)) != 'Step') return null;
    final x = _u32(at + _u32Bytes);
    if (!_validTableX(x)) return null;
    final name = _tok(_u32(at + 2 * _u32Bytes));
    if (name == null) return null;
    final count = _u32(at + 3 * _u32Bytes);
    if (count > _typeMaxFields) return null;
    final ref = _tableRef(x);
    final m = ops.mark();
    ops.poolRef(at, _u32(at)); // the 'Step' class token
    ops.u32(at + _u32Bytes, x, _OpSource.model); // 1-based type-table reference
    ops.poolRef(at + 2 * _u32Bytes, _u32(at + 2 * _u32Bytes));
    ops.u32(at + 3 * _u32Bytes, count, _OpSource.model);
    final outerInstance = _inInstance;
    final outerRepr = _numericReprContext;
    _inInstance = true;
    _numericReprContext = _reprsOf(ref);
    final children = _fields(at + 4 * _u32Bytes, count);
    _inInstance = outerInstance;
    _numericReprContext = outerRepr;
    if (children == null) return _blockBail(m);
    // The standard closing attr tail, like [_elementBlock] (measured:
    // `[0x80][0]` after each substep's fields).
    final attrs = <int>[];
    final after = _attrTail(children.$2, attrsOut: attrs);
    if (after == null) return _blockBail(m);
    return (
      BinaryTypeField(
        name,
        className: 'Step',
        typeName: ref.name,
        children: children.$1,
        instanceOverrides: true,
        attrWords: attrs,
      ),
      after,
    );
  }

  /// The DELIM-led instance block of [_arrayElement], starting at its
  /// delimiter. Two twin-validated word-3 shapes:
  ///
  ///  * ANONYMOUS — `[DELIM][X][DELIM][count]{fields}[attrs…][0]`: X is
  ///    the element type as a 1-based table reference and the element
  ///    name is not serialized (the twin writes `name=''`) — the
  ///    typedef-array form (`Measurement.Parameters`).
  ///  * NAMED — `[DELIM][X][nameRef][count]{fields}[attrs…][0]`: the
  ///    element's NAME is serialized in the third slot and X is a pool
  ///    reference to adapter module data (the LabVIEW `Parms` elements
  ///    store the adapter version string, e.g. `'23.0.0.0'`), NOT a
  ///    type reference — the element type lives in the array's
  ///    elemproto instead, so typeName/className stay null (never
  ///    guessed). Cross-format oracle: the LabVIEW XML corpus
  ///    materializes the same elements as
  ///    `<VIParameter name='sequence context'>` with exactly the
  ///    decoded children (Label/ArgVal/Type/WireRequirement/…).
  ///
  /// Children parse in instance context with the element type's
  /// integer-representation map ([_numericReprContext]) in scope (the
  /// anonymous form; the named form has no serialized type to consult).
  (BinaryTypeField, int)? _elementBlock(int at) {
    final m = ops.mark();
    ops.u32(at, _recordDelimiter, _OpSource.grammar); // verified by the caller
    var p = at + _u32Bytes;
    if (!_canRead(p)) return _blockBail(m);
    final x = _u32(p);
    p += _u32Bytes;
    if (!_canRead(p)) return _blockBail(m);
    final word3 = _u32(p);
    var name = '';
    BinaryTypeRecord? ref;
    if (word3 == _recordDelimiter) {
      if (!_validTableX(x)) return _blockBail(m);
      ref = _tableRef(x);
      ops.u32(at + _u32Bytes, x, _OpSource.model); // 1-based type-table reference
      ops.u32(p, _recordDelimiter, _OpSource.grammar); // the verified anonymous-form slot
      // Expression-VALUED anonymous element — `[DELIM][X][DELIM]
      // [valueRef][attrs…][0]` where X resolves to the table's
      // `Expression` record (the same resolution gate as the framed
      // valued scalar): an expression-array element (`DataSourceArray`),
      // whose cross-format twin writes
      // `<ExprValue typename='Expression' name=''><value>…</value>`.
      // Tried when the next word is no plausible child count; the
      // count form keeps precedence (unchanged behavior).
      final word4At = p + _u32Bytes;
      if (ref.name == 'Expression' && _canRead(word4At) && _u32(word4At) > _typeMaxFields) {
        final value = _tok(_u32(word4At));
        if (value != null) {
          ops.poolRef(word4At, _u32(word4At));
          final attrs = <int>[];
          final after = _attrTail(word4At + _u32Bytes, attrsOut: attrs);
          if (after != null) {
            return (
              BinaryTypeField('', className: 'ExprValue', typeName: 'Expression', value: value, attrWords: attrs),
              after,
            );
          }
        }
        return _blockBail(m);
      }
    } else {
      final named = _tok(word3);
      // The named form still requires X to reference SOMETHING in the
      // pool (the module-data slot) — a zero/unresolvable X does not
      // frame.
      if (named == null || x == 0 || _tok(x) == null) return _blockBail(m);
      name = named;
      ops.poolRef(at + _u32Bytes, x); // module-data slot, a pool ref
      ops.poolRef(p, word3);
    }
    p += _u32Bytes;
    if (!_canRead(p)) return _blockBail(m);
    final count = _u32(p);
    if (count > _typeMaxFields) return _blockBail(m);
    ops.u32(p, count, _OpSource.model);
    p += _u32Bytes;
    final outerInstance = _inInstance;
    final outerRepr = _numericReprContext;
    _inInstance = true;
    _numericReprContext = ref != null ? _reprsOf(ref) : null;
    final children = _fields(p, count);
    _inInstance = outerInstance;
    _numericReprContext = outerRepr;
    if (children == null) return _blockBail(m);
    final attrs = <int>[];
    final after = _attrTail(children.$2, attrsOut: attrs);
    if (after == null) return _blockBail(m);
    return (
      BinaryTypeField(
        name,
        className: ref != null ? (ref.className ?? 'Obj') : null,
        typeName: ref?.name,
        children: children.$1,
        instanceOverrides: true,
        attrWords: attrs,
      ),
      after,
    );
  }

  /// Walks [remaining] adapter-marshalling EXTDATA blocks (the twin's
  /// `<extdata controllername='STRUCT'/'CLUST'/'DNSTRUCT'/'BLVCLUSTER'…>`
  /// elements). Each block is `[ctrlNameIdx][u16][string slot]` (10
  /// bytes; the slot is a member-name pool ref, DELIM for none) or the
  /// STRUCT kind `[ctrlNameIdx][u16][20 opaque payload bytes]` (26
  /// bytes: packing/type/buffer sizes — undecoded). The two sizes are
  /// disambiguated by trying the short form first and requiring the
  /// REMAINING blocks to parse. Content is not surfaced yet (TODO) —
  /// only the extent is walked.
  int? _extBlocksFrom(int at, int remaining) {
    if (remaining == 0) return at;
    if (at + 10 > recordRegionLength) return null;
    if (_tok(_u32(at)) == null) return null;
    final slotAt = at + _u32Bytes + 2;
    if (slotAt + _u32Bytes <= recordRegionLength) {
      final slot = _u32(slotAt);
      if (slot == _recordDelimiter || _tok(slot) != null) {
        final rest = _extBlocksFrom(slotAt + _u32Bytes, remaining - 1);
        if (rest != null) return rest;
      }
    }
    final structEnd = at + _u32Bytes + 2 + 20;
    if (structEnd > recordRegionLength) return null;
    return _extBlocksFrom(structEnd, remaining - 1);
  }

  /// A field's EXTDATA tail (flag bit 0x100):
  /// `[attr words…][extCount][blocks…][terminator 0]`.
  int? _extTail(int from) {
    var p = from;
    for (var k = 0; k <= _fieldMaxAttrWords; k++, p += _u32Bytes) {
      if (p + _u32Bytes > recordRegionLength) return null;
      final count = _u32(p);
      if (count == 0) return null; // terminator before any extdata
      if (count <= _typeMaxExtBlocks) {
        final end = _extBlocksFrom(p + _u32Bytes, count);
        if (end != null && end + _u32Bytes <= recordRegionLength && _u32(end) == 0) {
          if (debugCollectSpecs) debugExtSpans.add((p, end));
          for (var q = from; q < p; q += _u32Bytes) {
            ops.u32(q, _u32(q), _OpSource.struct); // attr words before the extdata count
          }
          ops.u32(p, count, _OpSource.struct); // extdata block count (blocks not modeled)
          ops.copy(p + _u32Bytes, end); // block payloads: undecoded
          ops.u32(end, 0, _OpSource.grammar); // the verified extdata terminator
          return end + _u32Bytes;
        }
      }
    }
    return null;
  }

  /// Walks a short REFERENCE spec: `[00 pad?][DELIM][ref][0][0][0]` —
  /// the 0x800-signalled form (the full spec's nested arrays reference
  /// an already-described element type instead of respelling it).
  int? _refSpec(int at) {
    var p = at;
    if (p >= recordRegionLength) return null;
    if (view.getUint8(p) == 0) p++;
    if (p + 5 * _u32Bytes > recordRegionLength || _u32(p) != _recordDelimiter) {
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

  /// Tooling aid: when [debugCollectSpecs] is on, every ACCEPTED extdata
  /// block region is recorded as (start, end) byte offsets — the
  /// marshalling blocks whose extent is walked but whose payload contents
  /// are not surfaced (see [_extTail]). Feeds the byte-coverage
  /// accounting's structurally-skipped tier.
  static final List<(int, int)> debugExtSpans = [];

  /// Parses the LEADING fields of a sequence record's subprop list
  /// (`[Sequence][name][subpropCount]` then the subprops) — the
  /// scalar/Obj subprops (`Parameters`, `Locals`) that precede the
  /// `Main` group array. Walks fields until it reaches a GROUP-array
  /// field ([groupNames]: Main/Setup/Cleanup, whose step-tree content is
  /// a separate decode), which BOUNDS the leading region and confirms
  /// the record framed correctly. Returns `[]` unless that boundary is
  /// reached within [max] fields — a partial/unbounded walk is not
  /// trusted (it would fabricate names past the record). Reuses the full
  /// field grammar (sequence subprops serialize identically to typedef
  /// fields — twin-validated: valueflags match attribute-for-attribute).
  /// Each decoded field is returned with its END offset (exclusive), so
  /// the byte-coverage accounting can attribute the exact span consumed.
  List<(BinaryTypeField, int)> parseLeadingSubProps(int at, int max, Set<String> groupNames) {
    _usedSpec = false;
    _depth = 0;
    final fields = <(BinaryTypeField, int)>[];
    var cur = at;
    for (var i = 0; i < max; i++) {
      // Peek the field header `[flags][0][class][name]`: a group array
      // (`Objs`-classed, group-named) BOUNDS the leading region. When
      // POPULATED it does not parse as a plain field (its trailing bytes
      // are step content, not a terminator); when EMPTY it does — so
      // detect the boundary from the header, before parsing, either way.
      if (cur + 4 * _u32Bytes <= recordRegionLength) {
        final cls = _tok(_u32(cur + 2 * _u32Bytes));
        final nm = _tok(_u32(cur + 3 * _u32Bytes));
        if (cls == 'Objs' && nm != null && groupNames.contains(nm)) {
          return fields; // bounded by the group array — trust the run
        }
      }
      final field = _field(cur);
      // A parse failure here is the POPULATED first group array
      // (framed step content) — the leading run ends, return what
      // decoded. (The caller still requires it to lead with
      // Parameters/Locals, the honesty gate against coincidence.)
      if (field == null) return fields;
      cur = field.$2;
      fields.add((field.$1, cur));
    }
    return fields;
  }

  /// Parses a single field at [at] — used for a step's data descriptor
  /// node (`[0][0][DELIM][TS][childCount][children…]`), which the field
  /// grammar already covers as a descriptor node. Returns the field
  /// (with its decoded children) or null when the bytes do not frame.
  BinaryTypeField? parseFieldAt(int at) {
    _usedSpec = false;
    _depth = 0;
    final parsed = _field(at);
    if (parsed == null) return null;
    debugLastEndOffset = parsed.$2;
    return parsed.$1;
  }

  /// Decodes a step's `TS` subprops from the descriptor node at [at]
  /// (`[0][0][DELIM][TS][childCount][children…]`).
  ///
  ///  * When the whole node decodes (measurement-type steps: Id +
  ///    CustomResults + AdditionalResultsHints), returns all its
  ///    children.
  ///  * When a later child uses a shape not yet covered (Action/Python
  ///    steps carry an inline module + expression fields as child 2),
  ///    the all-or-nothing node parse fails — but child 1 is invariably
  ///    the step's unique `Id` (`[flags][0][Str][Id]['ID#:…'][0]`), so
  ///    it is extracted on its own. The `ID#:` value prefix is the
  ///    honesty anchor against a coincidental parse.
  ///
  /// End offset (exclusive) of the byte span the most recent successful
  /// [parseStepTs] validated — the whole `TS` node on the full-node path,
  /// or the descriptor header plus the `Id` field on the fallback path.
  /// Null when the last call returned `[]`. For byte-coverage accounting.
  int? lastStepTsEnd;

  /// Returns `[]` unless the node is actually named `TS`.
  List<BinaryTypeField> parseStepTs(int at) {
    lastStepTsEnd = null;
    // Must be a `TS`-named descriptor node header (both framing zeros
    // verified — the Id-only fallback below re-emits them as grammar
    // constants).
    if (at + 5 * _u32Bytes > recordRegionLength) return const [];
    if (_u32(at) != 0 || _u32(at + _u32Bytes) != 0 || _u32(at + 2 * _u32Bytes) != _recordDelimiter) {
      return const [];
    }
    if (_tok(_u32(at + 3 * _u32Bytes)) != 'TS') return const [];
    final mFull = ops.mark();
    final full = parseFieldAt(at);
    if (full != null && full.name == 'TS' && full.children.isNotEmpty) {
      lastStepTsEnd = debugLastEndOffset;
      return full.children;
    }
    ops.rollback(mFull);
    // Fallback: extract just child 1 (the Id) from after the 5-word
    // descriptor header.
    final mId = ops.mark();
    final idField = parseFieldAt(at + 5 * _u32Bytes);
    if (idField != null &&
        idField.className == 'Str' &&
        idField.name == 'Id' &&
        (idField.value?.startsWith('ID#:') ?? false)) {
      // The descriptor-node header the fallback path validated:
      // `[0][0][DELIM][TS][childCount]`.
      ops.u32(at, 0, _OpSource.grammar);
      ops.u32(at + _u32Bytes, 0, _OpSource.grammar);
      ops.u32(at + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
      ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
      ops.u32(at + 4 * _u32Bytes, _u32(at + 4 * _u32Bytes), _OpSource.model);
      lastStepTsEnd = debugLastEndOffset;
      return [idField];
    }
    ops.rollback(mId);
    return const [];
  }

  /// The whole body: `[0][count]` then exactly `count` fields.
  List<BinaryTypeField>? parse(int after) {
    debugLastFieldOffset = null;
    _usedSpec = false;
    if (after + 2 * _u32Bytes > recordRegionLength || _u32(after) != 0) {
      return null;
    }
    final m0 = ops.mark();
    final count = _u32(after + _u32Bytes);
    (List<BinaryTypeField>, int)? parsed;
    if (count <= _typeMaxFields) {
      ops.u32(after, 0, _OpSource.grammar); // the verified body opener
      ops.u32(after + _u32Bytes, count, _OpSource.model);
      parsed = _fields(after + 2 * _u32Bytes, count);
      if (parsed == null) ops.rollback(m0);
    }
    if (parsed == null && count >= 1 && count <= _typeMaxExtBlocks) {
      // EXTDATA-OPENER body (Error): `[0][extCount]{extdata blocks}
      // [subpropCount]{fields}` — the type-level marshalling blocks sit
      // between the opener and the field count.
      final extEnd = _extBlocksFrom(after + 2 * _u32Bytes, count);
      if (extEnd != null && extEnd + _u32Bytes <= recordRegionLength) {
        final subCount = _u32(extEnd);
        if (subCount <= _typeMaxFields) {
          ops.u32(after, 0, _OpSource.grammar); // the verified body opener
          ops.u32(after + _u32Bytes, count, _OpSource.struct); // extdata block count (blocks not modeled)
          ops.copy(after + 2 * _u32Bytes, extEnd); // extdata blocks: undecoded
          ops.u32(extEnd, subCount, _OpSource.model);
          parsed = _fields(extEnd + _u32Bytes, subCount);
          if (parsed == null) ops.rollback(m0);
          if (parsed != null && debugCollectSpecs) {
            debugExtSpans.add((after + _u32Bytes, extEnd));
          }
        }
      }
    }
    if (parsed == null) {
      // COUNT-LESS body: the step-type typedefs that exist only in the
      // binary (NI_Measurement/NI_UpdatePinMap — no XML twin carries
      // them) open `[0]{fields}` with no subprop count; the walk runs
      // until it lands EXACTLY on the body-end boundary. Without a
      // boundary (the last record) this form stays undecoded.
      final boundary = bodyEndBoundary;
      if (boundary == null) return null;
      ops.u32(after, 0, _OpSource.grammar); // the verified body opener
      parsed = _fieldsUntil(after + _u32Bytes, boundary);
      if (parsed == null) return _blockBail(m0);
    }
    // Boundary gate: when a body used element-type specs and the next
    // record's position is known, the walk must not OVERRUN it — a
    // walker misparse must never fabricate a body silently. (Ending
    // short of the boundary is normal: some records trail undecoded
    // inter-record content.)
    final boundary = bodyEndBoundary;
    if (_usedSpec && boundary != null && parsed.$2 > boundary) return _blockBail(m0);
    debugLastEndOffset = parsed.$2;
    return parsed.$1;
  }

  /// Parses fields until the walk lands EXACTLY on [boundary] — the
  /// count-less body form. Any misparse, overshoot, or runaway bails.
  (List<BinaryTypeField>, int)? _fieldsUntil(int from, int boundary) {
    final m = ops.mark();
    var at = from;
    final fields = <BinaryTypeField>[];
    while (at < boundary && fields.length <= _typeMaxFields) {
      final parsed = _fields(at, 1);
      if (parsed == null) return _blockBail(m);
      fields.addAll(parsed.$1);
      at = parsed.$2;
    }
    if (at != boundary) return _blockBail(m);
    return (fields, at);
  }

  /// Runs one trial parse [body] under a fresh mark: a null return (the
  /// trial failed) rolls back every op it recorded. The scoped twin of the
  /// explicit mark/rollback pairs — used where a whole attempt is one call;
  /// sites with partial rollbacks or predicate-gated rejection (a PARSED
  /// field the layout gates refuse) keep explicit marks.
  T? _trial<T>(T? Function() body) {
    final m = ops.mark();
    final parsed = body();
    if (parsed == null) ops.rollback(m);
    return parsed;
  }

  (List<BinaryTypeField>, int)? _fields(int from, int count) {
    // Every recursion (_field → nested declaration/instance/spec →
    // _fields) routes through here, so one depth guard covers them all.
    if (_depth >= _maxFieldDepth) return null;
    _depth++;
    try {
      return _trial(() => _fieldsInner(from, count));
    } finally {
      _depth--;
    }
  }

  static const _debugTrace = bool.fromEnvironment('labwright.seq.trace');

  (List<BinaryTypeField>, int)? _fieldsInner(int from, int count) {
    var at = from;
    final fields = <BinaryTypeField>[];
    for (var i = 0; i < count; i++) {
      final field = _field(at);
      if (_debugTrace) {
        // ignore: avoid_print
        print(
          '${'  ' * _depth}$at ${field == null ? 'FAIL' : '${field.$1.className}:${field.$1.name} -> ${field.$2}'}',
        );
      }
      if (field == null) return null;
      at = field.$2;
      var specBytes = 0;
      // INSIDE an instance/element run, an element-decoded populated
      // array (children present) consumed its whole tail through the
      // terminator; a DELIM ahead then belongs to an ENCLOSING structure
      // (e.g. the parent array's next element), so the chain walk below
      // must not swallow it. At DECLARATION level there is no enclosing
      // element run, and a populated array's trailing DELIM-led block is
      // its element-type spec (NI_Wait's decoded AdditionalResultsHints
      // trails `[DELIM][X=NI_CustomResult][DELIM][count]{items}`).
      if (field.$1.isArray && (field.$1.children.isEmpty || !_inInstance)) {
        // An element-type spec may follow any array. It is
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
          final specEnd = _elementSpec(at) ?? _refSpec(at) ?? _protoSpec(at);
          if (specEnd == null) break;
          // Spec blob: extent walked, contents undecoded — the writer
          // copies it verbatim (mirrors the coverage pass's structural
          // demotion of spec sites).
          ops.copy(at, specEnd);
          specBytes += specEnd - at;
          at = specEnd;
          _usedSpec = true;
        }
        if (specBytes == 0) {
          var lead = at;
          if (lead < recordRegionLength && view.getUint8(lead) == 0) lead++;
          if (lead + _u32Bytes <= recordRegionLength && _u32(lead) == _recordDelimiter) {
            return null;
          }
        }
      }
      if (specBytes > 0) {
        if (debugCollectSpecs) {
          debugSpecSites.add((field.$1.name, field.$2, specBytes));
        }
        // copyWith (not a hand-copied constructor) so a future field on
        // BinaryTypeField can't silently vanish here — intrinsicTypeId
        // once did.
        fields.add(field.$1.withElementSpecBytes(specBytes));
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
    return _trial(() => _fieldParse(at));
  }

  (BinaryTypeField, int)? _fieldParse(int at) {
    if (at + 6 * _u32Bytes > recordRegionLength) return null;
    final fieldFlags = _u32(at);
    if (_u32(at + _u32Bytes) != 0) {
      // COMPACT form: [name][value][attr words…][0] — no flags/class
      // prefix (every other form has 0 in the second slot; here it is
      // the stored value). Measured on the binary-only step-type
      // typedefs (DescriptionFormat = ResStr(…) in NI_Measurement) —
      // a DECLARATION-level form only: inside an instance any two
      // adjacent pool words would match it, and it fabricated fields
      // from structural tokens there (a step TS's Requirements read a
      // bogus `Data = 'Sequence'` child until instance context
      // disabled it; the corpus sweep pins zero such reads).
      if (_inInstance) return null;
      final name = _tok(fieldFlags);
      final value = _tok(_u32(at + _u32Bytes));
      if (name == null || value == null) return null;
      ops.poolRef(at, fieldFlags);
      ops.poolRef(at + _u32Bytes, _u32(at + _u32Bytes));
      final attrs = <int>[];
      final after = _attrTail(at + 2 * _u32Bytes, attrsOut: attrs);
      if (after == null) return null;
      return (BinaryTypeField(name, value: value, attrWords: attrs), after);
    }
    if (fieldFlags & ~_fieldKnownFlagBits != 0) return null;
    final hasExtData = fieldFlags & _fieldHasExtDataBit != 0;
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasFormat = fieldFlags & _fieldHasFormatBit != 0;
    // Bit 0x800 is only measured on plain `Num` fields (typedef defaults
    // and instance members); any other shape carrying it is uncovered.
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    // The stored-attr-word floor the flag bits promise (see [_attrTail]).
    // Bit 0x4 does NOT belong in the floor. REFUTED twice: counting it
    // unconditionally broke 4 rosetta twin-validated bodies, and
    // counting it only under the 0x76 record-prefix layout regressed
    // the 0x76 exemplars (1→6 and 0→7 bailing bodies) — some 0x4
    // fields store a zero attr word (`LowExpr` `[0][0]`), most store
    // none, and no per-file marker separates them. Their bodies stay
    // bailing until per-field evidence exists.
    final minAttrs = ((fieldFlags >> 3) & 1) + ((fieldFlags >> 5) & 1) + ((fieldFlags >> 6) & 1);

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
      // The verified zero flags word is the FORM discriminator here —
      // grammar-determined, like the framing zero and delimiter.
      ops.u32(at, 0, _OpSource.grammar);
      ops.u32(at + _u32Bytes, 0, _OpSource.grammar);
      ops.u32(at + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
      ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
      ops.u32(at + 4 * _u32Bytes, childCount, _OpSource.model);
      final children = _fields(at + 5 * _u32Bytes, childCount);
      if (children == null) return null;
      return (
        BinaryTypeField(name, className: 'Obj', children: children.$1, instanceOverrides: true, fieldFlags: 0),
        children.$2,
      );
    }

    // Framed form: [flags|0x80][0][DELIM][X][name][value…][attrs…][0].
    if (fieldFlags & _fieldFramedBit != 0) {
      if (hasNumericRep) return null;
      if (_u32(at + 2 * _u32Bytes) != _recordDelimiter) return null;
      final x = _u32(at + 3 * _u32Bytes);
      final nameWord = _u32(at + 4 * _u32Bytes);
      // A DELIMITER in the name slot is an ANONYMOUS element — legal
      // only inside an instance/array context (an expression-array
      // element; its cross-format twin writes
      // `<ExprValue typename='Expression' name=''>`).
      final name = nameWord == _recordDelimiter && _inInstance ? '' : _tok(nameWord);
      if (name == null) return null;
      ops.u32(at, fieldFlags, _OpSource.model); // surfaced: BinaryTypeField.fieldFlags
      ops.u32(at + _u32Bytes, 0, _OpSource.grammar); // the verified framing zero
      ops.u32(at + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
      if (nameWord == _recordDelimiter) {
        // The verified anonymous-element sentinel (name == '').
        ops.u32(at + 4 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
      } else {
        ops.poolRef(at + 4 * _u32Bytes, nameWord);
      }
      var next = at + 5 * _u32Bytes;
      String? value;
      var typeName = 'Expression';
      var className = 'ExprValue';
      // A framed VALUED field whose stored tokens are a bound-token PAIR
      // is a typed ARRAY instance (`Substeps`): the pair discriminates it
      // from a framed scalar (whose single value token is followed by the
      // attr words). X here is NOT a table reference: Substeps carries
      // X=2 while its twin types it StepTypeSubstepsArray — an
      // ENGINE-INTRINSIC type that is never serialized (the table has no
      // such record) — and the newer record generation writes X=0
      // (corpus-measured; surfaced as no id). X is NOT further gated to
      // intrinsic sentinels: a framed valued ARRAY of Expression elements
      // (a step's `DataSourceArray`) legitimately carries an X that resolves
      // to the `Expression` record, so the bound-token PAIR — not X — is the
      // array discriminant. A genuine framed scalar cannot reach this
      // branch: its value word is followed by its first attr word, a flag
      // bitmask that is never a bound-shaped small pool index, so the second
      // `_isBoundToken` fails on any real scalar.
      final boundPair =
          valued &&
          next + 2 * _u32Bytes <= recordRegionLength &&
          _isBoundToken(_tok(_u32(next))) &&
          _isBoundToken(_tok(_u32(next + _u32Bytes)));
      if (boundPair) {
        final lbound = _tok(_u32(next))!;
        final ubound = _tok(_u32(next + _u32Bytes))!;
        // X here is an intrinsic type id / generation sentinel, surfaced
        // as [BinaryTypeField.intrinsicTypeId] (null ↔ 0, bijective).
        ops.u32(at + 3 * _u32Bytes, x, _OpSource.model);
        ops.poolRef(next, _u32(next));
        ops.poolRef(next + _u32Bytes, _u32(next + _u32Bytes));
        if (ubound == '[]') {
          // EMPTY array: ['[0]']['[]'][attr words…][0][one 0x00 pad byte]
          // — anchor-measured across every rosetta binary.
          if (lbound != '[0]') return null;
          final attrs = <int>[];
          final tail = _attrTail(next + 2 * _u32Bytes, minWords: minAttrs, attrsOut: attrs);
          if (tail == null || tail >= recordRegionLength || view.getUint8(tail) != 0) {
            return null;
          }
          ops.byte(tail, 0, _OpSource.grammar); // the verified trailing pad
          return (
            BinaryTypeField(
              name,
              className: 'Objs',
              arrayLBound: lbound,
              arrayUBound: ubound,
              intrinsicTypeId: x == 0 ? null : x,
              fieldFlags: fieldFlags,
              attrWords: attrs,
            ),
            tail + 1,
          );
        }
        // POPULATED framed array: the elements follow the standard array
        // tail, count-gated by the bounds ([_populatedArrayTail]) —
        // all-or-nothing; an element run that does not frame bails the
        // body (its extent cannot be measured without decoding it).
        final attrs = <int>[];
        final elements = _populatedArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
        if (elements == null) return null;
        return (
          BinaryTypeField(
            name,
            className: 'Objs',
            arrayLBound: lbound,
            arrayUBound: ubound,
            intrinsicTypeId: x == 0 ? null : x,
            children: elements.$1,
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          elements.$2,
        );
      }
      if (x == 0) {
        ops.u32(at + 3 * _u32Bytes, 0, _OpSource.grammar); // verified implicit-type X
        if (valued) {
          value = _tok(_u32(next));
          if (value == null) return null;
          ops.poolRef(next, _u32(next));
          next += _u32Bytes;
        } else {
          // The twin's `<value/>` reads as an empty string — unless
          // inside an instance, where an unvalued field is inherited.
          value = _inInstance ? null : '';
        }
      } else if (x >= 1 && valued && _validTableX(x) && _tableRef(x).name == 'Expression') {
        // Framed VALUED scalar with an explicit type-table reference —
        // the newer record generation's encoding of the Expression
        // scalar (the old generation writes X=0 with the type implicit).
        // Corpus-measured: the X of every such field resolves to the
        // table's `Expression` record (2,619 DescriptionFormat/
        // DefaultNameFormat sites; X - 1 - typeIndexBase == the Expression
        // record's index in every one, including files where Expression is
        // not first and files whose type-index base is nonzero); the gate
        // requires that resolution, so a file whose base cannot be
        // recovered bails instead of fabricating a type.
        value = _tok(_u32(next));
        if (value == null) return null;
        ops.u32(at + 3 * _u32Bytes, x, _OpSource.model); // 1-based type-table reference
        ops.poolRef(next, _u32(next));
        next += _u32Bytes;
      } else if (x >= 2 && !valued && _validTableX(x)) {
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
        final ref = _tableRef(x);
        ops.u32(at + 3 * _u32Bytes, x, _OpSource.model); // 1-based type-table reference
        // The scan starts past the flags-promised attr floor — a
        // zero-valued attr slot must not read as the ref-only
        // terminator (see [_attrTail]).
        for (var k = minAttrs; k <= _fieldMaxAttrWords; k++) {
          final countAt = next + k * _u32Bytes;
          if (countAt + _u32Bytes > recordRegionLength) break;
          final word = _u32(countAt);
          if (word == 0) break; // the ref-only terminator — no instance
          if (word < 1 || word > _typeMaxFields) continue; // attr word
          final mInst = ops.mark();
          final instAttrs = <int>[];
          for (var j = 0; j < k; j++) {
            instAttrs.add(_u32(next + j * _u32Bytes));
            ops.u32(next + j * _u32Bytes, instAttrs[j], _OpSource.model);
          }
          ops.u32(countAt, word, _OpSource.model);
          final outerInstance = _inInstance;
          final outerRepr = _numericReprContext;
          _inInstance = true;
          _numericReprContext = _reprsOf(ref);
          final children = _fields(countAt + _u32Bytes, word);
          _inInstance = outerInstance;
          _numericReprContext = outerRepr;
          if (children != null) {
            return (
              BinaryTypeField(
                name,
                className: ref.className ?? 'Obj',
                typeName: ref.name,
                children: children.$1,
                instanceOverrides: true,
                fieldFlags: fieldFlags,
                attrWords: instAttrs,
              ),
              children.$2,
            );
          }
          ops.rollback(mInst);
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
        // Inline CUSTOM instance: [name][attr words…][overrideCount] then
        // the overridden fields. The entries ARE ordinary valued fields
        // (`[0x2][0][cls][name][value]` — Bool/Str/framed-Expression), so
        // they decode with the general grammar in instance context; a
        // bespoke sub-parser here previously re-implemented it and
        // mis-read the Bool value as a u32 (the same latent slip PR #61
        // fixed in the shared path). The instance's TYPE is
        // engine-intrinsic (not serialized), so typeName stays null and
        // children carry ONLY the overrides.
        // Attr words may precede the count (Action.Menu stores two
        // 0x80018 words) — scan past them, same as the X >= 2 form,
        // starting past the flags-promised attr floor (zero-valued
        // slots must not read as a zero count; see [_attrTail]).
        ops.u32(at + 3 * _u32Bytes, 1, _OpSource.grammar); // verified X == 1 sentinel
        final attrsFrom = next;
        next += minAttrs * _u32Bytes;
        if (next + _u32Bytes > recordRegionLength) return null;
        var overrideCount = _u32(next);
        for (var k = 0; overrideCount > _typeMaxFields && k < _fieldMaxAttrWords; k++) {
          next += _u32Bytes;
          if (next + _u32Bytes > recordRegionLength) return null;
          overrideCount = _u32(next);
        }
        if (overrideCount > _typeMaxFields) return null;
        final customAttrs = <int>[];
        for (var q = attrsFrom; q < next; q += _u32Bytes) {
          customAttrs.add(_u32(q)); // attr words before the override count
          ops.u32(q, customAttrs.last, _OpSource.model);
        }
        ops.u32(next, overrideCount, _OpSource.model);
        next += _u32Bytes;
        final outer = _inInstance;
        _inInstance = true;
        final overrides = _fields(next, overrideCount);
        _inInstance = outer;
        if (overrides == null) return null;
        return (
          BinaryTypeField(
            name,
            className: 'Obj',
            children: overrides.$1,
            instanceOverrides: true,
            fieldFlags: fieldFlags,
            attrWords: customAttrs,
          ),
          overrides.$2,
        );
      } else {
        return null;
      }
      final attrs = <int>[];
      final after = _attrTail(next, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      return (
        BinaryTypeField(
          name,
          className: className,
          typeName: typeName,
          value: value,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        after,
      );
    }

    // FRAMED-LITE form: [flags][0][DELIM][name][value?][attrs…][0] — an
    // Expression-typed field with the DELIMITER in the class slot and no
    // X word (Action's TS override stores PassActTarget/FailActTarget
    // this way with flags 0x60). Distinguished from the full framed form
    // by the absent 0x80 bit and from the descriptor node by flags != 0.
    if (fieldFlags != 0 && _u32(at + 2 * _u32Bytes) == _recordDelimiter) {
      if (hasNumericRep) return null;
      final name = _tok(_u32(at + 3 * _u32Bytes));
      if (name == null) return null;
      ops.u32(at, fieldFlags, _OpSource.model); // surfaced: BinaryTypeField.fieldFlags
      ops.u32(at + _u32Bytes, 0, _OpSource.grammar); // the verified framing zero
      ops.u32(at + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
      ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
      var next = at + 4 * _u32Bytes;
      if (!valued) {
        // Framed-lite OBJECT form: `[flags][0][DELIM][name][attrs…]
        // [childCount]{children}` — an X-less instance node (a substep's
        // `TS` stores `[0x60][0][DELIM][TS][0x40018][0x40018][4]` then
        // its four children). Same count scan as the X >= 2 instance
        // form; when no count yields parsing children (the scan stops at
        // the scalar tail's 0 terminator), the field is the scalar below.
        // Starts past the flags-promised attr floor (see [_attrTail]).
        for (var k = minAttrs; k <= _fieldMaxAttrWords; k++) {
          final countAt = next + k * _u32Bytes;
          if (countAt + _u32Bytes > recordRegionLength) break;
          final word = _u32(countAt);
          if (word == 0) break; // the scalar terminator — not an object
          if (word < 1 || word > _typeMaxFields) continue; // attr word
          final mObj = ops.mark();
          final objAttrs = <int>[];
          for (var j = 0; j < k; j++) {
            objAttrs.add(_u32(next + j * _u32Bytes));
            ops.u32(next + j * _u32Bytes, objAttrs[j], _OpSource.model);
          }
          ops.u32(countAt, word, _OpSource.model);
          final outerInstance = _inInstance;
          _inInstance = true;
          final children = _fields(countAt + _u32Bytes, word);
          _inInstance = outerInstance;
          if (children != null) {
            return (
              BinaryTypeField(
                name,
                className: 'Obj',
                children: children.$1,
                instanceOverrides: true,
                fieldFlags: fieldFlags,
                attrWords: objAttrs,
              ),
              children.$2,
            );
          }
          ops.rollback(mObj);
        }
      }
      // The twin's `<value/>` reads as an empty string — unless inside
      // an instance, where an unvalued field is inherited (null).
      var value = _inInstance ? null : '';
      if (valued) {
        // An all-ones value slot is the UNSET sentinel — the field
        // stores a value slot but no value (MessagePopup's default TS
        // stores `[0x2][0][DELIM][LoopIncrement][DELIM][0]`), reading
        // like the twin's `<value/>`.
        if (_u32(next) == _recordDelimiter) {
          ops.u32(next, _recordDelimiter, _OpSource.grammar); // verified unset sentinel
          next += _u32Bytes;
        } else {
          final stored = _tok(_u32(next));
          if (stored == null) return null;
          value = stored;
          ops.poolRef(next, _u32(next));
          next += _u32Bytes;
        }
      }
      final attrs = <int>[];
      final after = _attrTail(next, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      // The X-less framed-lite shape serializes NO type: the twin's type
      // varies per site (Action's `PassActTarget`/`FailActTarget`
      // materialize `typename='Expression'`, but an old-generation
      // substep `Result` stores its `Error`/`Common` OBJECT references in
      // exactly this shape — `<Error typename='Error' classname='Obj'>`
      // in the materialized twin), so no class/type is claimed. The
      // former unconditional `ExprValue`/`Expression` claim is
      // corpus-refuted by those Result sites.
      return (BinaryTypeField(name, value: value, fieldFlags: fieldFlags, attrWords: attrs), after);
    }

    // Plain form: [flags][0][cls][name][value-part][format?][extras…]
    // [terminator 0] — extras sit AFTER the value part (anchor-measured on
    // CodeTemplates: [Str][name][value][0x480018][0]); with no value part
    // they directly precede the terminator (BlockStartTypes:
    // [Str][name][0x480018][0]).
    final className = _clsTok(_u32(at + 2 * _u32Bytes));
    final name = _tok(_u32(at + 3 * _u32Bytes));
    if (className == null || name == null) return null;
    ops.u32(at, fieldFlags, _OpSource.model); // surfaced: BinaryTypeField.fieldFlags
    ops.u32(at + _u32Bytes, 0, _OpSource.grammar); // the verified framing zero
    ops.poolRef(at + 2 * _u32Bytes, _u32(at + 2 * _u32Bytes));
    ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
    var next = at + 4 * _u32Bytes;
    // Nested object DECLARATION — class word 'Obj' or a CLASS NAME
    // string (PythonStepAdditions.PythonCall declares class
    // 'CPythonCall' this way, its 14 children inline):
    // [attr words…][childCount][children…] — no trailing zero, so the
    // childCount is found by scanning past the attr words: the first
    // word small enough to be a count whose children then parse
    // (Substep.TS's Result stores two 0x400000 attr words where its
    // flag bits promise one — bit arity is not reliable here either).
    // 'Ref' is a SCALAR value class (an engine object reference): every
    // XML-corpus site is a childless, valueless self-closing element
    // (`<EvaluatedConditionExpr classname='Ref'/>`, `<RTSequenceReference
    // classname='Ref'/>` — 8 sites), so it takes the scalar tail below,
    // NEVER this count-scan: a Ref tail `[attr 4][0]` misreads as
    // `[childCount 4]{4 swallowed siblings}` under the scan (measured on
    // the iTAC `Connect` record, where it ate the sequence's remaining
    // parameters and its `Locals`).
    if (!valued &&
        !const {'Bool', 'Str', 'Num', 'Nums', 'Strs', 'Objs', 'ExprValue', 'PathValue', 'Ref'}.contains(className)) {
      if (hasNumericRep) return null;
      // On EXACTLY flags == 0x4, a ZERO count candidate yields to the
      // IMMEDIATELY following word: that shape can store a zero-valued
      // attr slot before the count (`Limits` = `[0x4][0][Obj][Limits]
      // [0][4]{Low, High, LowExpr, HighExpr}` — the zero is the attr,
      // the 4 is the count), and an eager zero would silently drop the
      // children. Only the ADJACENT candidate is tried — a wider defer
      // was tried and REFUTED twice against the rosetta twins: any-flags
      // deferral let a truly-empty `NI_Data`'s trailing words parse as a
      // bogus count, and an unbounded 0x4 scan let an empty `Parameters`
      // steal the next field's child from seven words away.
      for (var k = 0; k <= _fieldMaxAttrWords; k++) {
        final countAt = next + k * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final childCount = _u32(countAt);
        if (childCount > _typeMaxFields) continue; // attr word
        if (childCount == 0 && fieldFlags == 0x4 && countAt + 2 * _u32Bytes <= recordRegionLength) {
          final adjacent = _u32(countAt + _u32Bytes);
          if (adjacent >= 1 && adjacent <= _typeMaxFields) {
            final mAdj = ops.mark();
            final adjAttrs = <int>[];
            for (var j = 0; j < k; j++) {
              adjAttrs.add(_u32(next + j * _u32Bytes));
              ops.u32(next + j * _u32Bytes, adjAttrs[j], _OpSource.model);
            }
            adjAttrs.add(0); // the zero-valued attr slot
            ops.u32(countAt, 0, _OpSource.model);
            ops.u32(countAt + _u32Bytes, adjacent, _OpSource.model);
            final children = _fields(countAt + 2 * _u32Bytes, adjacent);
            if (children != null) {
              return (
                BinaryTypeField(
                  name,
                  className: className,
                  children: children.$1,
                  fieldFlags: fieldFlags,
                  attrWords: adjAttrs,
                ),
                children.$2,
              );
            }
            ops.rollback(mAdj);
          }
        }
        final mDecl = ops.mark();
        final declAttrs = <int>[];
        for (var j = 0; j < k; j++) {
          declAttrs.add(_u32(next + j * _u32Bytes));
          ops.u32(next + j * _u32Bytes, declAttrs[j], _OpSource.model);
        }
        ops.u32(countAt, childCount, _OpSource.model);
        final children = _fields(countAt + _u32Bytes, childCount);
        if (children == null) {
          ops.rollback(mDecl);
          continue;
        }
        return (
          BinaryTypeField(
            name,
            className: className,
            children: children.$1,
            fieldFlags: fieldFlags,
            attrWords: declAttrs,
          ),
          children.$2,
        );
      }
      return null;
    }
    if (!valued) {
      // Unvalued fields read their class defaults (false / '' / 0 — the
      // twin's `<value/>` semantics): [attr words…][terminator 0], or
      // the extdata tail when flagged (Error's Code/Msg/Occurred).
      // Inside an instance the value is INHERITED instead (null).
      // A 0x800-flagged Num stores its representation word first
      // ([_fieldHasNumericRepBit]: NI_MeasurementParameter.ID/Dimension).
      int? repr;
      if (hasNumericRep) {
        if (className != 'Num' || !_canRead(next)) return null;
        repr = _u32(next);
        ops.u32(next, repr, _OpSource.model);
        next += _u32Bytes;
      }
      final attrs = <int>[];
      final after = hasExtData ? _extTail(next) : _attrTail(next, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      if (!const {'Bool', 'Str', 'Num', 'Ref'}.contains(className)) return null;
      return (
        BinaryTypeField(
          name,
          className: className,
          // A 'Ref' carries no persisted value in ANY context (its XML
          // twin form is always a self-closing element) — value stays
          // null rather than a fabricated default.
          value: _inInstance || className == 'Ref'
              ? null
              : switch (className) {
                  'Bool' => 'false',
                  'Num' => '0',
                  _ => '',
                },
          numericRepresentation: repr,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        after,
      );
    }
    // Array field: bound tokens `lbound ubound` then trail 0. Object
    // arrays (`Objs`) additionally carry ONE 0x00 pad byte after the
    // trail — the stream is byte-granular, and this pad is what shifts
    // everything after an empty Objs array off word alignment.
    if (const {'Nums', 'Strs', 'Objs'}.contains(className) &&
        next + 2 * _u32Bytes <= recordRegionLength &&
        _isBoundToken(_tok(_u32(next))) &&
        _isBoundToken(_tok(_u32(next + _u32Bytes)))) {
      if (hasNumericRep) return null;
      // The bounds are surfaced verbatim ('[0]' '[]' = empty; '[0]'
      // '[0]' = a populated one-element array — PythonCall.Parameters).
      final lbound = _tok(_u32(next))!;
      final ubound = _tok(_u32(next + _u32Bytes))!;
      ops.poolRef(next, _u32(next));
      ops.poolRef(next + _u32Bytes, _u32(next + _u32Bytes));
      // POPULATED Objs array: `[lb][ub][one 0x00 pad]{elements}[attrs][0]`
      // — the elements follow the bounds directly (anchor-measured on the
      // oracle: the placed step's Measurement.Parameters '[0]' '[10]'
      // carries exactly 11 element blocks; EnumDefinition '[0]' '[1]'
      // carries its 2 Num members as plain fields). Count-gated by the
      // bounds and terminator-gated, all-or-nothing; on failure the array
      // falls back to the structural blob walk in [_fieldsInner].
      if (className == 'Objs' && ubound != '[]') {
        final attrs = <int>[];
        final elements = _populatedArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
        if (elements != null) {
          return (
            BinaryTypeField(
              name,
              className: className,
              arrayLBound: lbound,
              arrayUBound: ubound,
              children: elements.$1,
              fieldFlags: fieldFlags,
              attrWords: attrs,
            ),
            elements.$2,
          );
        }
      }
      // POPULATED scalar array (`Nums`): the element values follow the
      // bounds directly as an inline f64 run, then the standard attr
      // tail — `[lb][ub]{count × f64}[attrs…][0]`. Anchor-measured on
      // corpus sequence locals (51-element `[0]'..'[50]'` runs whose
      // terminator and following field land exactly at count × 8 bytes)
      // and value-validated against the cross-format XML oracle (same
      // repo materializes the identical array in XML). Count-gated and
      // terminator-gated, all-or-nothing; on failure the array falls
      // back to the bounds-only read below (contents stay undecoded).
      if (className == 'Nums' && valued && ubound != '[]') {
        final attrs = <int>[];
        final run = _scalarArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
        if (run != null) {
          return (
            BinaryTypeField(
              name,
              className: className,
              arrayLBound: lbound,
              arrayUBound: ubound,
              children: run.$1,
              fieldFlags: fieldFlags,
              attrWords: attrs,
            ),
            run.$2,
          );
        }
      }
      // A populated array whose elements did not decode is NOT claimed
      // empty: its element content rides in the trailing DELIM-led
      // blocks, surfaced undecoded via elementSpecBytes.
      final attrs = <int>[];
      var after = _attrTail(next + 2 * _u32Bytes, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      if (className == 'Objs') {
        if (after >= recordRegionLength || view.getUint8(after) != 0) {
          return null;
        }
        ops.byte(after, 0, _OpSource.grammar); // the verified trailing Objs pad
        after += 1;
        // An EMPTY `Objs` array may carry a trailing ELEMENT-TYPE
        // block — `[classRef][DELIM][0][attr words…][0]`, the binary
        // form of the XML `<elemproto><_NAME_IN_ATTRIBUTE_ name=''
        // classname='TEResult'/></elemproto>` (anchor-measured on every
        // rosetta binary's sequence `Locals > ResultList`, whose XML
        // twins all write exactly that elemproto). The DELIMITER in the
        // name slot is what keeps the block disjoint from every field
        // form (plain/framed/descriptor heads have 0 there; a compact
        // field's value slot never resolves at the delimiter). The
        // block is surfaced as the field's element-type spec blob
        // ([BinaryTypeField.elementSpecBytes]) — its classname is the
        // ELEMENT's class, which the twin does not surface as the
        // array's own typename, so no type is claimed on the field.
        if (ubound == '[]') {
          final proto = _elemProtoTail(after);
          if (proto != null) {
            if (debugCollectSpecs) debugSpecSites.add((name, after, proto.$2 - after));
            // Element-type block: extent walked, contents undecoded —
            // copied verbatim like the other spec blobs.
            ops.copy(after, proto.$2);
            return (
              BinaryTypeField(
                name,
                className: className,
                arrayLBound: lbound,
                arrayUBound: ubound,
                elementSpecBytes: proto.$2 - after,
                fieldFlags: fieldFlags,
                attrWords: attrs,
              ),
              proto.$2,
            );
          }
        }
      }
      return (
        BinaryTypeField(
          name,
          className: className,
          arrayLBound: lbound,
          arrayUBound: ubound,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        after,
      );
    }
    switch (className) {
      case 'Str' when !hasNumericRep:
        final value = _tok(_u32(next));
        if (value == null) return null;
        ops.poolRef(next, _u32(next));
        final attrs = <int>[];
        final after = hasExtData
            ? _extTail(next + _u32Bytes)
            : _attrTail(next + _u32Bytes, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (BinaryTypeField(name, className: 'Str', value: value, fieldFlags: fieldFlags, attrWords: attrs), after);
      case 'Bool' when !hasNumericRep:
        // A stored Bool is ONE byte (TEInf's StepFCSeqF=true measured:
        // [01][attr 0x4d0018][terminator]) — the same byte the instance
        // grammar reads. Reading it as u32 was survivable only while
        // every validated stored Bool was false.
        final value = view.getUint8(next);
        if (value > 1) return null;
        ops.byte(next, value, _OpSource.model);
        final attrs = <int>[];
        final after = hasExtData ? _extTail(next + 1) : _attrTail(next + 1, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(
            name,
            className: 'Bool',
            value: value == 1 ? 'true' : 'false',
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          after,
        );
      case 'Num':
        // A 0x800-flagged Num stores [representation word][i64 value];
        // a plain one stores an f64 — unless it sits inside an instance
        // whose typedef declares this field with an integer
        // representation, in which case the stored value is an i64 with
        // the representation left implicit ([_numericReprContext]).
        int? repr;
        if (hasNumericRep) {
          if (!_canRead(next)) return null;
          repr = _u32(next);
          ops.u32(next, repr, _OpSource.model);
          next += _u32Bytes;
        }
        if (next + 2 * _u32Bytes > recordRegionLength) return null;
        // The stored value is an i64 when the representation says so —
        // explicitly (bit 0x800), via the instance type's declaration
        // ([_numericReprContext]), or by the SUBNORMAL signature: an
        // integer-stored slot read as f64 collapses into the denormal
        // range (i64 1 ↔ 5e-324), and no corpus text flavor ever stores
        // a subnormal numeric text (0 hits across all 384 XML/INI files),
        // while the oracle twin types exactly these slots Int64
        // (`<ID classname='Num'><value representation='Int64'>1</value>`
        // — the parameter-element ID runs whose element type rides an
        // elemproto the walk does not resolve). The same signature
        // already gates [_scalarArrayTail]'s element runs.
        var integer = repr != null
            ? BinaryNumericRepresentation.isInteger(repr)
            : _inInstance && _numericReprContext?[name] != null;
        if (!integer) {
          final raw = view.getFloat64(next, Endian.little);
          if (raw != 0 && raw.isFinite && raw.abs() < _smallestNormalF64) integer = true;
        }
        final String text;
        if (integer) {
          final value = view.getInt64(next, Endian.little);
          ops.i64(next, value);
          text = '$value';
        } else {
          final value = view.getFloat64(next, Endian.little);
          ops.f64(next, value);
          text = value == value.truncateToDouble() && value.abs() < 1e15 ? '${value.truncate()}' : '$value';
        }
        next += 2 * _u32Bytes;
        if (hasFormat) {
          if (next + _u32Bytes > recordRegionLength || _tok(_u32(next)) == null) {
            return null;
          }
          ops.poolRef(next, _u32(next));
          next += _u32Bytes; // display-format ref, e.g. '%#x'
        }
        final attrs = <int>[];
        final after = hasExtData ? _extTail(next) : _attrTail(next, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(
            name,
            className: 'Num',
            value: text,
            numericRepresentation: repr,
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          after,
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
({List<BinarySequenceOutline> outlines, List<BinaryTypeRecord> typeRecords}) binaryOutlinesAndTypeRecordsFromBody(
  Uint8List body,
) {
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) {
    return const (outlines: [], typeRecords: []);
  }
  final pool = _orderedStringPool(body, recordRegionLength);
  final typeRecords = _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool);
  return (
    outlines: _sequenceOutlinesFromBody(body, recordRegionLength, pool, [
      for (final record in typeRecords) record.name,
    ], typeRecords),
    typeRecords: typeRecords,
  );
}

List<String> _typeNamesFromBody(Uint8List body, int recordRegionLength, [List<String>? sharedPool]) => [
  // Names come entirely from the head scan — skip the (expensive)
  // second-pass body decode. This is the hot path for
  // [binaryTypeNames] and the whole-corpus name sweep.
  for (final record in _typeRecordsFromBody(body, recordRegionLength, sharedPool: sharedPool, decodeBodies: false))
    record.name,
];

/// One decoded typedef FIELD — the binary form of an XML typedef subprop.
///
/// Field records follow the typedef head as
/// `[fieldFlags][0][classIdx][nameIdx][value…]`, where flag bit 0x2 marks a
/// stored value, bit 0x80 a delimiter-framed form, bit 0x100 an extdata
/// tail, and bit 0x200 a display-format string after the value. Value
/// arity by class: Bool one byte, Str one word, Num an inline f64 (+
/// format ref when flagged), `Nums`/`Strs`/`Objs` arrays a bound-token
/// pair. Framed fields carry an X word selecting Expression / a
/// 1-based type-table reference / an inline instance. See the body
/// parser for the full grammar. Anything not matching a covered shape
/// leaves the WHOLE body undecoded (all-or-nothing — no partial trees,
/// no fabrication).
class BinaryTypeField {
  const BinaryTypeField(
    this.name, {
    this.className,
    this.typeName,
    this.value,
    this.arrayLBound,
    this.arrayUBound,
    this.children = const [],
    this.instanceOverrides = false,
    this.elementSpecBytes,
    this.intrinsicTypeId,
    this.numericRepresentation,
    this.fieldFlags,
    this.attrWords = const [],
  });

  /// The field name (`Code`, `ItemName`, …).
  final String name;

  /// The value class (`Bool`/`Str`/`Num`/`Nums`/`Strs`), or `ExprValue`
  /// for Expression-typed fields. Null for compact fields, whose class is
  /// not serialized (never guessed).
  final String? className;

  /// The named type for typed fields (`Expression`), null otherwise.
  final String? typeName;

  /// The stored scalar value in XML text form (`false`, `8192`, `""`), or
  /// null when the field carries none — including a flags-only override
  /// inside an instance, whose value is INHERITED from the type default.
  final String? value;

  /// The array bounds tokens as the file stores them (`'[0]'` /
  /// `'[]'` / `'[3]'`), or null for a non-array field. `arrayUBound ==
  /// '[]'` is an EMPTY array; anything else is POPULATED — the element
  /// values ride in [elementSpecBytes] (not yet decoded), so the field
  /// is honestly marked an array whose contents are undecoded rather
  /// than fabricated empty. See [isArray] / [isEmptyArray].
  final String? arrayLBound;
  final String? arrayUBound;

  /// Whether this field is an array (empty or populated).
  bool get isArray => arrayUBound != null;

  /// Whether this array is genuinely empty (`ubound == '[]'`). False for
  /// a populated array whose elements are undecoded.
  bool get isEmptyArray => arrayUBound == '[]';

  /// Nested declaration children (an `Obj` field's own field list),
  /// decoded recursively — or, on an ARRAY field ([isArray]), the array's
  /// decoded ELEMENTS ([_populatedArrayTail]: instance blocks carry
  /// `name ''` + [typeName]; scalar members their own names). A typed
  /// default-instance REFERENCE (`X >= 2` framed form) carries no
  /// children — the binary itself stores only the reference;
  /// materializing the referenced type's defaults is the XML writer's
  /// job, not the file's content.
  final List<BinaryTypeField> children;

  /// TODO(element-type spec): the length in bytes of this array field's
  /// trailing ELEMENT-TYPE SPEC plus (for a populated array whose
  /// elements did NOT decode — see [children]) its element content — an
  /// explicitly UNDECODED blob (needed for eventual .seq writing, so it
  /// is surfaced, never dropped). The blob starts right after this
  /// field's own encoding. Null when the field carries no spec (or the
  /// spec trails the body's last field, where the count-driven walk
  /// leaves it untouched).
  final int? elementSpecBytes;

  /// True for an inline CUSTOM/OVERRIDE instance (framed `X >= 1`) and
  /// for a descriptor node: [children] holds ONLY the fields serialized
  /// (a subset of the materialized type — the rest are inherited), so
  /// compare children as a subset of the twin, never as the full field
  /// list. For the `X == 1` intrinsic form the instance TYPE is
  /// engine-intrinsic (not in the file), so [typeName] stays null.
  final bool instanceOverrides;

  /// TODO(intrinsic types): for a framed VALUED empty array, the X word
  /// is an ENGINE-INTRINSIC type id, not a table reference (`Substeps`
  /// carries 2 while its twin types it `StepTypeSubstepsArray` — a type
  /// the file never serializes). Surfaced undecoded; the id → name map
  /// needs more corpus evidence. Null elsewhere.
  final int? intrinsicTypeId;

  /// The raw numeric-representation code a `Num` field flagged with bit
  /// 0x800 stores (see [_fieldHasNumericRepBit]): the XML `representation`
  /// attribute's binary form. Twin-evidenced codes are named by
  /// [BinaryNumericRepresentation]; others are carried verbatim. Null when
  /// the field stores none (a plain f64 `Num`, or any other class).
  final int? numericRepresentation;

  /// Whether this field's TYPE is engine-intrinsic and therefore not
  /// serialized — an intrinsically-typed array ([intrinsicTypeId]) or an
  /// inline custom instance ([instanceOverrides] with no [typeName]). For
  /// these, [typeName] is legitimately absent (not a decode gap), so a
  /// twin comparison checks [className] rather than the typename.
  bool get typeNameEngineIntrinsic => intrinsicTypeId != null || (instanceOverrides && typeName == null);

  /// Whether this is a plain nested-object DECLARATION whose [children]
  /// are the full field list — as opposed to an override subset
  /// ([instanceOverrides]) or a typed reference ([typeName] set, no
  /// serialized children). Only these are descended one-for-one against
  /// a twin.
  bool get isPlainDeclaration => children.isNotEmpty && !instanceOverrides && typeName == null;

  /// The raw FIELD-FLAGS word this record serialized (word 1 of the
  /// `[flags][0]…` field forms), retained typed-but-partially-interpreted.
  /// The decoded bits are cataloged at [_fieldKnownFlagBits]: 0x2 stored
  /// value, 0x80 framed form, 0x100 extdata tail, 0x200 display-format
  /// word, 0x800 numeric-representation word, 0x4/0x8/0x20/0x40
  /// flag-attribute markers. Corpus bit-population (330,099 flagged of
  /// 354,117 decoded fields over the 297-binary corpus): 0x2×211,848,
  /// 0x4×44,411, 0x8×22,692, 0x20×37,498, 0x40×44,361, 0x80×41,084,
  /// 0x100×1,876, 0x200×1,170, 0x800×143; every set bit falls inside the
  /// cataloged mask by construction (an unknown bit bails the field), and
  /// bit 0x2 co-varies with a decoded value/array/child surface on
  /// 211,676 of 211,848 sites (the 172 without one are the framed-lite
  /// UNSET sentinel inside instances — a value slot stored, no value).
  /// The attr-marker bits do NOT reliably predict the stored attr-word
  /// count (see [_attrTail]) — negative evidence, so they stay grouped
  /// rather than decoded per-bit. Null for forms that serialize NO flags
  /// word: the compact `[name][value]` form and the element-block/
  /// step-element forms (whose heads are DELIM- or class-token-led).
  final int? fieldFlags;

  /// The field's trailing FLAG-ATTRIBUTE words in serialization order
  /// (the words between the value part and the 0 terminator, plus any
  /// attr words preceding an instance/object child count), retained
  /// typed-but-uninterpreted. At the TYPE-RECORD level the analogous
  /// words carry the XML `typeflags`/`flagsforinstances`/
  /// `instanceoverrideflags`/`valueflags` attributes named by COUNT
  /// ([BinaryTypeRecord.flags]); at the FIELD level the count↔attribute
  /// mapping is corpus-refuted as unreliable (fields store MORE words
  /// than their flag bits promise — see [_attrTail]), so the words are
  /// surfaced raw, never named. Empty when the field stores none.
  final List<int> attrWords;

  /// Returns a copy with [elementSpecBytes] set — used when a trailing
  /// element-type spec is walked after the field's own encoding. A
  /// method (not a hand-copied constructor) so a newly added field can
  /// never be silently dropped in the copy.
  BinaryTypeField withElementSpecBytes(int bytes) => BinaryTypeField(
    name,
    className: className,
    typeName: typeName,
    value: value,
    arrayLBound: arrayLBound,
    arrayUBound: arrayUBound,
    children: children,
    instanceOverrides: instanceOverrides,
    elementSpecBytes: bytes,
    intrinsicTypeId: intrinsicTypeId,
    numericRepresentation: numericRepresentation,
    fieldFlags: fieldFlags,
    attrWords: attrWords,
  );
}

/// A decoded type record — the binary form of an XML typedef element.
///
/// The HEAD carries the same attributes the XML encoding puts on the
/// typedef element (classname, typecategory, timestamp, the version
/// triple, and the ordered flag words typeflags / flagsforinstances /
/// instanceoverrideflags / valueflags), from the layout
/// `[classIdx][nameIdx][typecategory][stamp][0?][ver][ver][ver]
/// [flags…][0][0xffffffff]` (the triple starts at word 3 on the TS
/// 4.x/5.0 layout, word 4 on newer). Head attributes are validated
/// attribute-for-attribute against the oracle twin. The BODY follows the
/// delimiter and decodes into [fields] (null when undecoded — see there).
class BinaryTypeRecord {
  const BinaryTypeRecord({
    required this.name,
    required this.className,
    required this.typeCategory,
    required this.timestamp,
    required this.versions,
    required this.flags,
    this.fields,
    this.undecodedBody = false,
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
  /// when the body was not decoded — either the record has no body
  /// region at all, or it has one whose shapes the grammar does not yet
  /// cover ([undecodedBody] distinguishes the two). Never partially
  /// guessed.
  final List<BinaryTypeField>? fields;

  /// True when a body region EXISTS but did not decode (all-or-nothing
  /// bail) — as opposed to a record with no body region. Both leave
  /// [fields] null; this separates "undecoded" from "declares nothing"
  /// so consumers do not present a bailed body as an empty type.
  final bool undecodedBody;

  int? get typeFlags => flags.isNotEmpty ? flags[0] : null;
  int? get flagsForInstances => flags.length > 2 ? flags[1] : null;
  int? get instanceOverrideFlags =>
      flags.length == 4 ? flags[2] : (flags.length == 3 && typeCategory == 1 ? flags[2] : null);
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
    if (flagsForInstances != null) 'flagsforinstances': '$flagsForInstances',
    if (instanceOverrideFlags != null) 'instanceoverrideflags': '$instanceOverrideFlags',
    if (valueFlags != null) 'valueflags': '$valueFlags',
  };
}

/// The decoded type-record heads of a binary TOF1 file, in table order —
/// see [BinaryTypeRecord] for the layout. Detection is IDENTICAL to
/// [binaryTypeNames] (this is the same scan keeping the head fields), so
/// the corpus-pinned table is shared.
List<BinaryTypeRecord> binaryTypeRecords(Uint8List seqBytes) => _withLayout(seqBytes, _typeRecordsFromBody);

/// The type-index base recovered for [seqBytes] — how far the file's framed
/// 1-based type references are offset from the recovered head table (see
/// [deriveTypeIndexBase]). Zero for the aligned majority; nonzero (either
/// sign) for the misaligned cohort. Returns 0 when [seqBytes] does not frame.
int binaryTypeIndexBase(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return 0;
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) return 0;
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return 0;
  final table = _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool, decodeBodies: false);
  return deriveTypeIndexBase(ByteData.sublistView(body), pool, recordRegionLength, table);
}

/// Defensive cap on a field's attr-word tail (three is the most any
/// twin-validated field stores — ffi/iof/vf, e.g. TEInf.Links).
const _fieldMaxAttrWords = 8;

/// Defensive cap on an extdata block list (Error stores four:
/// STRUCT/CLUST/DNSTRUCT/BLVCLUSTER).
const _typeMaxExtBlocks = 8;

/// Defensive cap on typedef-body field-nesting depth. The deepest real
/// nesting is a handful of levels (TS instance → Result Obj → Error
/// ref); this bound is far above that and exists only to make a hostile
/// self-nesting body bail instead of overflowing the stack.
const _maxFieldDepth = 64;

/// Defensive cap on flag words read after the version triple while looking
/// for the record delimiter (real records carry at most four flags plus a
/// trailing zero).
const _typeMaxFlagWords = 8;

List<BinaryTypeRecord> _typeRecordsFromBody(
  Uint8List body,
  int recordRegionLength, {
  List<String>? sharedPool,
  Map<String, int>? bodyOffsetsOut,
  Map<String, int>? headOffsetsOut,
  Map<String, int>? tripleOffsetsOut,
  bool decodeBodies = true,
}) {
  final pool = sharedPool ?? _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final versionLike = RegExp(r'^\d+\.\d+');
  final seen = <String>{};
  final records = <BinaryTypeRecord>[];
  final bodyOffsets = <int?>[];
  final headAts = <int>[];
  String? tok(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;
  for (var at = 0; at + _typeRecordMinBytes <= recordRegionLength; at++) {
    final stamp = view.getUint32(at + _typeStampOffset, Endian.little);
    if (stamp < _typeStampMin || stamp > _typeStampMax) continue;
    final nameIndex = view.getUint32(at, Endian.little);
    if (nameIndex == 0 || nameIndex >= pool.length) continue;
    final name = pool[nameIndex];
    if (name.isEmpty || !_typeNamePattern.hasMatch(name)) continue;
    int? tripleAt;
    for (final tripleStart in _typeVersionTripleStarts) {
      if (at + tripleStart + _typeVersionTripleWords * _u32Bytes > recordRegionLength) {
        continue;
      }
      var triple = true;
      for (var i = 0; i < _typeVersionTripleWords; i++) {
        final word = view.getUint32(at + tripleStart + i * _u32Bytes, Endian.little);
        // Index 0 is padding/separator by this file's pool convention (see
        // poolAt) — a zero word must not count as a version reference.
        if (word == 0 || word >= pool.length || !versionLike.hasMatch(pool[word])) {
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
    // record delimiter (trailing zeros dropped). A class word of 0
    // resolves to pool[0] — the file's root token, which the TS 4.x-era
    // generation references by index 0 (see [_TypeBodyParser._clsTok]).
    final classWord = at >= _u32Bytes ? view.getUint32(at - _u32Bytes, Endian.little) : null;
    final className = classWord == null
        ? null
        : classWord == 0
        ? (pool[0].isNotEmpty && _TypeBodyParser._rootClassPattern.hasMatch(pool[0]) ? pool[0] : null)
        : tok(classWord);
    final typeCategory = view.getUint32(at + _u32Bytes, Endian.little);
    final versions = [
      for (var i = 0; i < _typeVersionTripleWords; i++)
        pool[view.getUint32(at + tripleAt + i * _u32Bytes, Endian.little)],
    ];
    final flags = <int>[];
    var flagAt = at + tripleAt + _typeVersionTripleWords * _u32Bytes;
    var framed = false;
    while (flagAt + _u32Bytes <= recordRegionLength && flags.length < _typeMaxFlagWords) {
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
      // BINARY-ONLY record generation (typecategory 2, anchor-measured on
      // the oracle's NI_MeasurementParameter): the tail after the version
      // triple is `[1][idRef]` — a constant 1 and a unique-ID string
      // reference — then the STANDARD `[0][subpropCount][fields…]` body
      // with no delimiter. The unique-ID gate keeps this passive
      // (detection is unchanged; only records whose tail did not frame
      // gain a body offset).
      final tailAt = at + tripleAt + _typeVersionTripleWords * _u32Bytes;
      if (tailAt + 2 * _u32Bytes <= recordRegionLength && view.getUint32(tailAt, Endian.little) == 1) {
        final idRef = view.getUint32(tailAt + _u32Bytes, Endian.little);
        if (idRef > 0 && idRef < pool.length && _looksLikeUniqueId(pool[idRef])) {
          bodyAt = tailAt + 2 * _u32Bytes;
        }
      }
    }
    records.add(
      BinaryTypeRecord(
        name: name,
        className: className,
        typeCategory: typeCategory,
        timestamp: stamp,
        versions: versions,
        flags: flags,
      ),
    );
    bodyOffsets.add(bodyAt);
    headAts.add(at);
    if (bodyAt != null) bodyOffsetsOut?[name] = bodyAt;
    headOffsetsOut?[name] = at;
    tripleOffsetsOut?[name] = tripleAt;
  }
  // Names-only callers skip the second pass entirely (the head scan
  // already has every name) — the hot path for the whole-corpus name
  // sweep.
  if (!decodeBodies) return records;
  // Second pass: bodies parse with the COMPLETE table of heads in hand —
  // framed references index it 1-based (the same convention as step
  // references), and may point forward. Bodies parse in TABLE ORDER with
  // each result folded back in: an inline materialized instance needs the
  // REFERENCED type's field count, and the corpus defines element/base
  // types before their use sites.
  final result = List.of(records);
  // The type-index base is a whole-file property (see [deriveTypeIndexBase]):
  // compute it once from the complete head table, then rebase every body's
  // framed references consistently.
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, result);
  for (var i = 0; i < result.length; i++) {
    final bodyAt = bodyOffsets[i];
    if (bodyAt == null) continue;
    final boundary = i + 1 < headAts.length ? headAts[i + 1] - _u32Bytes - _typeRecordPreambleBytes : null;
    final fields = _typeFieldsAt(body, view, pool, bodyAt, recordRegionLength, result, boundary, typeIndexBase);
    // A body region existed here (bodyAt != null); record whether it
    // decoded so consumers can tell "undecoded" from "declares nothing".
    result[i] = BinaryTypeRecord(
      name: records[i].name,
      className: records[i].className,
      typeCategory: records[i].typeCategory,
      timestamp: records[i].timestamp,
      versions: records[i].versions,
      flags: records[i].flags,
      fields: fields,
      undecodedBody: fields == null,
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
List<({String name, int headAt, int bodyAt, int? end, int? bail})> binaryTypeBodyExtents(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) return const [];
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final bodyOffsets = <String, int>{};
  final headOffsets = <String, int>{};
  final records = _typeRecordsFromBody(
    body,
    recordRegionLength,
    sharedPool: pool,
    bodyOffsetsOut: bodyOffsets,
    headOffsetsOut: headOffsets,
  );
  final extents = <({String name, int headAt, int bodyAt, int? end, int? bail})>[];
  // Whole-file constant — derive once, not per record body (see finding-7
  // note in [_sequenceOutlinesFromBody]).
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, records);
  for (var i = 0; i < records.length; i++) {
    final record = records[i];
    final bodyAt = bodyOffsets[record.name];
    if (bodyAt == null) continue;
    final boundary = i + 1 < records.length
        ? (headOffsets[records[i + 1].name] ?? 0) - _u32Bytes - _typeRecordPreambleBytes
        : null;
    final parser = _TypeBodyParser(view, pool, recordRegionLength, records, boundary, typeIndexBase);
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
bool _looksLikeUniqueId(String text) => text.length >= 15 && RegExp(r'[;\\<>^\]]').hasMatch(text);

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
List<String> binaryStepNames(Uint8List seqBytes) => _withLayout(seqBytes, _stepNamesFromBody);

List<String> _stepNamesFromBody(Uint8List body, int recordRegionLength) {
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final stepToken = pool.indexOf(_stepToken);
  if (stepToken < 0) return const [];
  final view = ByteData.sublistView(body);
  int wordAt(int at) => view.getUint32(at, Endian.little);
  String? poolAt(int index) => index > 0 && index < pool.length && pool[index].isNotEmpty ? pool[index] : null;

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

/// The sequence-record subprops that precede the `Main` group array in
/// TestStand's fixed layout — the only ones the leading-subprop decode
/// covers (the rest sit after the group arrays, behind the not-yet-
/// decoded step content). Used as the honesty gate on the leading walk.
const _sequenceLeadingSubPropNames = {'Parameters', 'Locals'};

/// The fixed LEADING subprop order of a sequence record and the closed
/// TAIL name set that follows it. XML census over every corpus sequence
/// (43 files, 387 subprop sites): all lead `Parameters, Locals, Main,
/// Setup, Cleanup`; the tail is `RecordResults, RTS, Requirements,
/// FailureAction` (39 files) or `GotoCleanupOnFail, RecordResults, RTS,
/// Requirements` (4 older files) — no other name occurs. Older BINARY
/// generations carry up to all five tail names (10-subprop records,
/// corpus-measured), so the walk pins the five leading positions exactly
/// and gates each tail position to an UNSEEN member of the closed set —
/// every field still needs its exact class and a clean parse, which
/// stops the walk cold on any coincidental parse inside undecoded step
/// content.
const _sequenceSubPropHead = ['Parameters', 'Locals', 'Main', 'Setup', 'Cleanup'];
const _sequenceSubPropTailNames = {'GotoCleanupOnFail', 'RecordResults', 'RTS', 'Requirements', 'FailureAction'};

/// The value class each sequence subprop carries, from the same XML
/// census — the per-field shape gate of the full-record walk.
const _sequenceSubPropClasses = {
  'Parameters': 'Obj',
  'Locals': 'Obj',
  'Main': 'Objs',
  'Setup': 'Objs',
  'Cleanup': 'Objs',
  'RecordResults': 'Bool',
  'GotoCleanupOnFail': 'Bool',
  'RTS': 'Obj',
  'Requirements': 'Obj',
  'FailureAction': 'Num',
};

/// Upper bound on a credible `[Sequence][name][count]` subprop count —
/// both attested layouts have exactly 9; the margin admits a future
/// layout without letting a huge word through the candidate gate.
const _sequenceRecordMaxSubProps = 12;

/// One decoded sequence RECORD from the full-record walk: the
/// `[Sequence][name][subpropCount]` head at [offset] plus the decoded
/// subprop prefix (each with its end offset, for byte accounting).
/// [complete] when every declared subprop decoded.
class _SequenceRecordWalk {
  const _SequenceRecordWalk(
    this.offset,
    this.name,
    this.comment,
    this.headWords,
    this.subpropCount,
    this.subProps,
    this.end,
  );
  final int offset;
  final String name;

  /// The head word count this record framed with — 3 (`[Sequence][name]
  /// [count]`) or 4 (with the middle comment slot). Tracked independently
  /// of [comment], which may be null even on a 4-word head when the slot's
  /// word is not structurally a comment.
  final int headWords;

  /// The record's comment string, from the optional slot between the
  /// name and the count (`[Sequence][name][commentRef][count]` — an
  /// older record generation; the slot is absent when the count follows
  /// the name directly). Null when absent.
  final String? comment;
  final int subpropCount;
  final List<(BinaryTypeField, int)> subProps;
  final int end;
  bool get complete => subProps.length == subpropCount;
}

/// Locates and decodes every sequence RECORD with the FULL subprop walk —
/// `[Sequence][name][count]` then up to [count] fields in the fixed
/// layout order ([_sequenceSubPropHead] then [_sequenceSubPropTailNames]),
/// through the populated
/// Main/Setup/Cleanup group arrays (whose elements are the placed steps).
/// All-or-nothing per FIELD with a kept prefix per RECORD:
///
///  * each subprop must parse with the production field grammar AND
///    match the next name of a still-compatible layout AND carry that
///    name's class ([_sequenceSubPropClasses]) — any miss ends the walk
///    (nothing past it is claimed);
///  * a POPULATED group array that decodes bounds-only (its elements did
///    not parse) also ends the walk: the bytes that follow are step
///    content whose extent is unknown;
///  * a candidate record is kept only when its first subprop is
///    `Parameters` — the same coincidence gate the leading-subprop
///    decode uses, now backed by the fixed layout (43/43 XML sequences
///    lead with it).
///
/// Twin-validated: on every rosetta binary the walk decodes the complete
/// record (all 9 subprops, group arrays element-for-element — see the
/// rosetta tests), and the content-exact OutputVoltage pair matches
/// value-for-value.
List<_SequenceRecordWalk> _sequenceRecordWalks(
  ByteData view,
  List<String> pool,
  int recordRegionLength,
  List<BinaryTypeRecord> table,
  int typeIndexBase, [
  _DecodeSink sink = _DecodeSink.none,
]) {
  final seqIdx = <int>{
    for (var i = 1; i < pool.length; i++)
      if (pool[i] == 'Sequence') i,
  };
  if (seqIdx.isEmpty) return const [];
  int u32(int at) => view.getUint32(at, Endian.little);
  String? poolAt(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;

  // Walks the subprop run at [from], up to [count] fields, gated by the
  // fixed head order and the closed tail set. Returns the decoded
  // prefix with each field's end offset.
  (List<(BinaryTypeField, int)>, int) walkSubProps(int from, int count) {
    final subProps = <(BinaryTypeField, int)>[];
    final seenTail = <String>{};
    var cur = from;
    while (subProps.length < count) {
      final i = subProps.length;
      final mField = sink.mark();
      final field = parser.parseFieldAt(cur);
      if (field == null) break;
      var gated = false;
      if (i < _sequenceSubPropHead.length) {
        gated = field.name != _sequenceSubPropHead[i];
      } else {
        gated = !_sequenceSubPropTailNames.contains(field.name) || !seenTail.add(field.name);
      }
      if (!gated) gated = field.className != _sequenceSubPropClasses[field.name];
      // A group array's elements are ALWAYS placed steps — an element of
      // any other class is a misparse leaking a later field into the
      // array (corpus-caught: a short-read `ViCall` let the following
      // `TDChecksum` register as a group element), so the field and its
      // extent are not trusted and the walk stops BEFORE it.
      if (!gated && _stepGroupNames.contains(field.name) && field.children.any((c) => c.className != 'Step')) {
        gated = true;
      }
      if (gated) {
        // A parsed field the layout gates reject: its ops are not trusted.
        sink.rollback(mField);
        break;
      }
      cur = _TypeBodyParser.debugLastEndOffset!;
      subProps.add((field, cur));
      // A populated group array whose elements did not decode: the walk
      // cannot cross the undecoded step content that follows.
      if (_stepGroupNames.contains(field.name) && !field.isEmptyArray && field.children.isEmpty) {
        break;
      }
    }
    return (subProps, cur);
  }

  final walks = <_SequenceRecordWalk>[];
  var at = 0;
  while (at + 3 * _u32Bytes <= recordRegionLength) {
    if (!seqIdx.contains(u32(at))) {
      at++;
      continue;
    }
    final name = poolAt(u32(at + _u32Bytes));
    if (name == null) {
      at++;
      continue;
    }
    // Two head forms: `[Sequence][name][count]` and — an older record
    // generation — `[Sequence][name][commentRef][count]` (the comment is
    // a pool string; corpus-measured on 10-subprop records whose comment
    // slots carry the sequence's editor comment). The standard form is
    // tried first; the walk's Parameters-first gate arbitrates.
    _SequenceRecordWalk? walked;
    for (final withComment in const [false, true]) {
      final countAt = at + (withComment ? 3 : 2) * _u32Bytes;
      if (countAt + _u32Bytes > recordRegionLength) continue;
      final count = u32(countAt);
      if (count < 1 || count > _sequenceRecordMaxSubProps) continue;
      final mCand = sink.mark();
      final (subProps, end) = walkSubProps(countAt + _u32Bytes, count);
      if (subProps.isEmpty || subProps.first.$1.name != 'Parameters') {
        sink.rollback(mCand);
        continue;
      }
      // Positive comment gate: the framing (3- vs 4-word head) is arbitrated
      // purely by the Parameters-first walk above; the middle slot is
      // surfaced as an editor comment ONLY when its word cannot ALSO be a
      // subprop COUNT (a count-shaped word here is a structural word, not a
      // comment — surfacing it would fabricate a comment). A 4-word record
      // whose slot is count-shaped still decodes, simply with no comment.
      final commentWord = withComment ? u32(at + 2 * _u32Bytes) : 0;
      final comment = withComment && commentWord > _sequenceRecordMaxSubProps ? poolAt(commentWord) : null;
      sink.poolRef(at, u32(at)); // the 'Sequence' class token
      sink.poolRef(at + _u32Bytes, u32(at + _u32Bytes)); // sequence name
      if (withComment) {
        if (comment != null) {
          sink.poolRef(at + 2 * _u32Bytes, commentWord);
        } else {
          sink.u32(at + 2 * _u32Bytes, commentWord, _OpSource.struct);
        }
      }
      sink.u32(countAt, count, _OpSource.model);
      walked = _SequenceRecordWalk(at, name, comment, withComment ? 4 : 3, count, subProps, end);
      break;
    }
    if (walked == null) {
      at++;
      continue;
    }
    walks.add(walked);
    // Head words (3, or 4 with the comment slot) then each decoded field.
    sink.claim(at, at + walked.headWords * _u32Bytes, _tierSemantic);
    var fieldStart = at + walked.headWords * _u32Bytes;
    for (final (_, fieldEnd) in walked.subProps) {
      sink.claim(fieldStart, fieldEnd, _tierSemantic);
      fieldStart = fieldEnd;
    }
    at = walked.end > at ? walked.end : at + 1;
  }
  return walks;
}

/// The step-record DATA subprops (the plain fields following the step's
/// TS node) the decode keeps — only names twin-validated on the rosetta
/// oracle (`Measurement` name+parameters, `PinMapPath`). The gate stops
/// the after-TS field walk at the first non-listed parse, so a
/// coincidental field-alike past the step record can never surface.
const _stepDataSubPropNames = {'Measurement', 'PinMapPath'};

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
  const BinaryStepRef(
    this.name, {
    this.typeName,
    this.viPath,
    this.pythonModule,
    this.pythonFunction,
    this.tsSubProps = const [],
    this.dataSubProps = const [],
  });

  /// The step's display name.
  final String name;

  /// The step's type name resolved from the type table, or null when the
  /// type word does not land in the recovered table (never fabricated).
  final String? typeName;

  /// The step's `TS` (TestStand) subproperties decoded from the step-data
  /// descriptor node that follows the step reference
  /// (`[0][0][DELIM][TS][childCount][children…]` — the same descriptor
  /// grammar typedef bodies use). These are the fields the step
  /// SERIALIZES — its overrides of the step type's TS defaults (`Id`, and
  /// any non-default `CustomResults`/expressions), not the full
  /// materialized list. Empty when the step data does not frame.
  final List<BinaryTypeField> tsSubProps;

  /// The step's serialized DATA subprops beyond `TS` — the plain fields
  /// that follow the TS node in the step record (`Measurement` with its
  /// name + parameter array on measurement steps, `PinMapPath` on
  /// update-pin-map steps), decoded with the same field grammar and kept
  /// only for the twin-validated [_stepDataSubPropNames] (the honesty
  /// gate against a coincidental parse past the record's end). Oracle:
  /// all 11 `Measurement.Parameters` elements match the twin
  /// value-for-value. Empty when the step serializes none.
  final List<BinaryTypeField> dataSubProps;

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
  String toString() => 'BinaryStepRef($name${typeName != null ? ': $typeName' : ''})';
}

class BinarySequenceOutline {
  const BinarySequenceOutline({
    required this.name,
    required this.setup,
    required this.main,
    required this.cleanup,
    this.ungrouped = const [],
    this.leadingSubProps = const [],
    this.tailSubProps = const [],
    this.comment,
    this.groupArrays = const [],
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

  /// The sequence-record subprops that precede the `Main` group array —
  /// `Parameters`, `Locals` (decoded with the typedef field grammar; see
  /// [BinaryTypeField]). The group arrays themselves (`Main`/`Setup`/
  /// `Cleanup`) are surfaced via [setup]/[main]/[cleanup].
  final List<BinaryTypeField> leadingSubProps;

  /// The sequence subprops that FOLLOW the group arrays —
  /// `RecordResults` (Bool), `FailureAction` (Num), `Requirements` (Obj
  /// with its `Links` child) and `RTS` (Obj runtime settings) —
  /// anchor-located and single-field parsed (see [_sequenceTailSubProps]).
  final List<BinaryTypeField> tailSubProps;

  /// The sequence's editor COMMENT, from the record head's optional
  /// comment slot (`[Sequence][name][commentRef][count]` — the older
  /// record generation; see [_sequenceRecordWalks]). Null when the
  /// record uses the comment-less head or no record walk succeeded.
  final String? comment;

  /// The GROUP ARRAYS (`Main`/`Setup`/`Cleanup`) decoded by the
  /// full-record walk ([_sequenceRecordWalks]), in record order: each an
  /// `Objs`-classed [BinaryTypeField] whose children are the placed STEP
  /// elements (class `Step`, bound type, with their `TS`/data subprop
  /// trees — the binary form of the XML `<Main><value><Step …>`
  /// content). Empty when the record walk did not reach/decode a group
  /// array — [setup]/[main]/[cleanup] (the marker/scan assembly) remain
  /// the step lists either way; this surface carries the full decoded
  /// element content.
  final List<BinaryTypeField> groupArrays;
}

/// The **sequence outlines** of a binary TOF1 file — each sequence with its
/// typed steps grouped into Setup/Main/Cleanup (see [BinarySequenceOutline]
/// for the assembly rule, and [BinaryStepRef] for the type binding), plus
/// the sequence record's leading subprops (Parameters/Locals — see
/// [BinarySequenceOutline.leadingSubProps]) and the post-group subprops
/// (RecordResults/FailureAction/Requirements/RTS — see
/// [BinarySequenceOutline.tailSubProps]). Returns `[]` when [seqBytes] is
/// not an inflatable binary file or does not frame.
List<BinarySequenceOutline> binarySequenceOutlines(Uint8List seqBytes) =>
    _withLayout(seqBytes, _sequenceOutlinesFromBody);

List<BinarySequenceOutline> _sequenceOutlinesFromBody(
  Uint8List body,
  int recordRegionLength, [
  List<String>? sharedPool,
  List<String>? sharedTypeNames,
  List<BinaryTypeRecord>? sharedTypeRecords,
  _DecodeSink sink = _DecodeSink.none,
]) {
  final pool = sharedPool ?? _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);

  // 0. the FULL sequence-record walk — `[Sequence][name][count]` records
  // with their subprops decoded through the group arrays (the layout-
  // order gate makes a coincidental record impossible to walk past its
  // first field; see [_sequenceRecordWalks]). Feeds the group-array
  // surface, the byte accounting, and — on files whose sequences are
  // declared in a layout without the `[]/name/Objs/Seq/[i]` path
  // records — sequence DISCOVERY itself.
  final table = sharedTypeRecords ?? _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool);
  // The type-index base is a whole-file constant (see [deriveTypeIndexBase]):
  // derive it ONCE here and thread it into every parser this pass builds,
  // instead of paying the O(recordRegionLength) anchor scan per construction.
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, table);
  final recordWalks = _sequenceRecordWalks(view, pool, recordRegionLength, table, typeIndexBase, sink);

  // 1. sequence declarations, with offsets (same root-shape gate as
  // binarySequenceNames — see _isSequenceDeclaration)
  final sequenceDecls = <(int, String)>[];
  for (var at = 0; at + _minDeclarationBytes <= recordRegionLength; at++) {
    final decl = _objectDeclarationPath(body, view, pool, at, recordRegionLength);
    if (decl == null || !_isSequenceDeclaration(decl.$1)) continue;
    sequenceDecls.add((at, decl.$1[1]));
    sink.claim(at, decl.$2, _tierSemantic);
    // Record lead + flags byte, then the path words: pool references
    // with zero separators (see [_objectDeclarationPath]).
    sink.byte(at, body[at], _OpSource.struct);
    sink.byte(at + 1, body[at + 1], _OpSource.struct);
    for (var q = at + _PropRecordField.zeroA.offset; q + _u32Bytes <= decl.$2; q += _u32Bytes) {
      final word = view.getUint32(q, Endian.little);
      if (word == 0) {
        sink.u32(q, 0, _OpSource.grammar); // the verified path-separator zero
      } else {
        sink.poolRef(q, word);
      }
    }
  }
  if (sequenceDecls.isEmpty) {
    // No declaration-path records: fall back to the walked sequence
    // RECORDS as the declaration set (offset + name), so the step/marker
    // assembly below works on files whose declarations use the older
    // layout. On files where BOTH exist the paths are authoritative and
    // the walk only adds content — rosetta-validated to agree.
    for (final walk in recordWalks) {
      sequenceDecls.add((walk.offset, walk.name));
    }
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
  final typeNames = sharedTypeNames ?? _typeNamesFromBody(body, recordRegionLength, pool);
  final stepToken = pool.indexOf(_stepToken);
  // First pass: detect references (offset, name, 1-based type index).
  final found = <(int, String, int)>[];
  int wordAt(int at) => view.getUint32(at, Endian.little);
  String? poolAt(int index) => index > 0 && index < pool.length && pool[index].isNotEmpty ? pool[index] : null;
  if (stepToken > 0) {
    for (var at = 0; at + (_stepNameWordGap + 2) * _u32Bytes <= recordRegionLength; at++) {
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
  Set<int> indicesOf(String token) => {
    for (var i = 1; i < pool.length; i++)
      if (pool[i] == token) i,
  };
  final viPathIdx = indicesOf('VIPath');
  final modulePathIdx = indicesOf('ModulePath');
  final functionIdx = indicesOf('FunctionOrAttributeName');
  String? pairIn(int start, int end, Set<int> nameIdx) {
    if (nameIdx.isEmpty) return null;
    for (var at = start; at + 2 * _u32Bytes <= end; at++) {
      if (!nameIdx.contains(wordAt(at))) continue;
      final value = poolAt(wordAt(at + _u32Bytes));
      if (value != null) {
        sink.claim(at, at + 2 * _u32Bytes, _tierSemantic);
        sink.poolRef(at, wordAt(at));
        sink.poolRef(at + _u32Bytes, wordAt(at + _u32Bytes));
        return value;
      }
    }
    return null;
  }

  // The type table (already built for the record walk above) also serves
  // any framed references the step's TS subprops carry.
  final tsParser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;

  final steps = <(int, BinaryStepRef)>[];
  for (var i = 0; i < found.length; i++) {
    final (at, name, typeIndex) = found[i];
    final spanEnd = i + 1 < found.length ? found[i + 1].$1 : recordRegionLength;
    // The step's data descriptor node follows the four-word reference
    // (`[Step][kind][name][container]`): `[0][0][DELIM][TS][childCount]
    // [children…]`, which the field grammar decodes as a descriptor
    // node. Its children are the step's TS subprops (Id, …).
    final tsSubProps = _stepTsSubProps(tsParser, at + 4 * _u32Bytes);
    sink.claim(at, at + 4 * _u32Bytes, _tierSemantic);
    // The four-word step reference `[Step][type X][name][container]`.
    sink.poolRef(at, wordAt(at));
    final typeWord = wordAt(at + _u32Bytes);
    if (typeIndex >= 0 && typeIndex < typeNames.length) {
      sink.u32(at + _u32Bytes, typeWord, _OpSource.model); // 1-based type-table index
    } else {
      sink.u32(at + _u32Bytes, typeWord, _OpSource.struct); // out-of-table: retained raw
    }
    sink.poolRef(at + 2 * _u32Bytes, wordAt(at + 2 * _u32Bytes));
    sink.poolRef(at + 3 * _u32Bytes, wordAt(at + 3 * _u32Bytes));
    if (tsSubProps.isNotEmpty && tsParser.lastStepTsEnd != null) {
      sink.claim(at + 4 * _u32Bytes, tsParser.lastStepTsEnd!, _tierSemantic);
    }
    // After the TS node, the step's own DATA subprops follow as plain
    // fields (Measurement, PinMapPath) — walked with the same grammar and
    // kept only for twin-validated names (see [_stepDataSubPropNames]).
    final dataSubProps = <BinaryTypeField>[];
    if (tsSubProps.isNotEmpty && tsParser.lastStepTsEnd != null) {
      var cur = tsParser.lastStepTsEnd!;
      while (cur < spanEnd) {
        final mData = sink.mark();
        final field = tsParser.parseFieldAt(cur);
        if (field == null) break;
        final fieldEnd = _TypeBodyParser.debugLastEndOffset!;
        if (!_stepDataSubPropNames.contains(field.name) || fieldEnd > spanEnd) {
          // Parsed but rejected by the honesty gates — ops not trusted.
          sink.rollback(mData);
          break;
        }
        dataSubProps.add(field);
        sink.claim(cur, fieldEnd, _tierSemantic);
        cur = fieldEnd;
      }
    }
    steps.add((
      at,
      BinaryStepRef(
        name,
        typeName: typeIndex >= 0 && typeIndex < typeNames.length ? typeNames[typeIndex] : null,
        viPath: pairIn(at, spanEnd, viPathIdx),
        pythonModule: pairIn(at, spanEnd, modulePathIdx),
        pythonFunction: pairIn(at, spanEnd, functionIdx),
        tsSubProps: tsSubProps,
        dataSubProps: dataSubProps,
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

  // Sequence-record leading subprops (Parameters/Locals/…) per sequence.
  final leading = _sequenceLeadingSubProps(
    body,
    view,
    pool,
    recordRegionLength,
    table,
    typeIndexBase,
    {
      for (final (_, name) in sequenceDecls) name,
    },
    sink,
  );

  // Post-group subprops (RecordResults, FailureAction, Requirements,
  // RTS) — the fields that follow the Main/Setup/Cleanup group arrays.
  final tail = _sequenceTailSubProps(view, pool, recordRegionLength, table, typeIndexBase, sequenceDecls, sink);

  // The decoded GROUP ARRAYS (Main/Setup/Cleanup with their step
  // elements) and head comments from the full-record walk, first record
  // per name.
  final groups = <String, List<BinaryTypeField>>{};
  final comments = <String, String>{};
  for (final walk in recordWalks) {
    if (groups.containsKey(walk.name) || comments.containsKey(walk.name)) continue;
    final walked = [
      for (final (field, _) in walk.subProps)
        if (_stepGroupNames.contains(field.name)) field,
    ];
    if (walked.isNotEmpty) groups[walk.name] = walked;
    if (walk.comment != null) comments[walk.name] = walk.comment!;
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
          leadingSubProps: leading[name] ?? const [],
          tailSubProps: tail[name] ?? const [],
          comment: comments[name],
          groupArrays: groups[name] ?? const [],
        ),
  ];
}

/// The sequence subprops that follow the Main/Setup/Cleanup group arrays,
/// recovered by ANCHOR — each located by its expected class token
/// immediately before its name token (with a zero slot), parsed as a
/// single field, and associated with the nearest preceding sequence
/// declaration:
///   * scalars `RecordResults` (Bool) and `FailureAction` (Num);
///   * `Requirements` (Obj) with its `Links` (Strs) child — the
///     requirement-traceability list;
///   * `RTS` (Obj) — the runtime/entry-point settings.
/// Each is validated against its expected shape ([_TailSubProp.accepts])
/// so a coincidental anchor is rejected — never a positional guess.
Map<String, List<BinaryTypeField>> _sequenceTailSubProps(
  ByteData view,
  List<String> pool,
  int recordRegionLength,
  List<BinaryTypeRecord> table,
  int typeIndexBase,
  List<(int, String)> sequenceDecls, [
  _DecodeSink sink = _DecodeSink.none,
]) {
  if (sequenceDecls.isEmpty) return const {};
  int u32(int at) => view.getUint32(at, Endian.little);
  Set<int> indicesOf(String token) => {
    for (var i = 1; i < pool.length; i++)
      if (pool[i] == token) i,
  };
  final anchors = [
    for (final spec in _tailSubProps) (indicesOf(spec.name), indicesOf(spec.className), spec),
  ];
  final sorted = [...sequenceDecls]..sort((a, b) => a.$1.compareTo(b.$1));
  String ownerOf(int offset) {
    var owner = sorted.first.$2;
    for (final (declOffset, name) in sorted) {
      if (declOffset < offset) owner = name;
    }
    return owner;
  }

  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;
  final result = <String, List<BinaryTypeField>>{};
  final seenPerOwner = <String, Set<String>>{};
  for (var at = 0; at + 4 * _u32Bytes <= recordRegionLength; at++) {
    for (final (nameIdx, classIdx, spec) in anchors) {
      if (u32(at + _u32Bytes) != 0) continue; // the field's zero slot
      if (!classIdx.contains(u32(at + 2 * _u32Bytes))) continue;
      if (!nameIdx.contains(u32(at + 3 * _u32Bytes))) continue;
      final mAnchor = sink.mark();
      final field = parser.parseFieldAt(at);
      if (field == null) continue;
      final owner = ownerOf(at);
      final seen = seenPerOwner.putIfAbsent(owner, () => <String>{});
      if (!spec.accepts(field) || !seen.add(spec.name)) {
        // Parsed but rejected (shape gate / duplicate) — ops not trusted.
        sink.rollback(mAnchor);
        continue;
      }
      final fieldEnd = _TypeBodyParser.debugLastEndOffset;
      if (fieldEnd != null) sink.claim(at, fieldEnd, _tierSemantic);
      result.putIfAbsent(owner, () => <BinaryTypeField>[]).add(field);
    }
  }
  return result;
}

/// A tail-subprop anchor spec: the name/class to anchor on and the shape
/// gate that a coincidental parse must fail.
class _TailSubProp {
  const _TailSubProp(this.name, this.className, this.accepts);
  final String name;
  final String className;
  final bool Function(BinaryTypeField) accepts;
}

/// The tail subprops recovered by [_sequenceTailSubProps], with their
/// shape gates. Scalars must carry a value; `Requirements` must hold a
/// `Links` child; `RTS` must be an object with children.
final _tailSubProps = <_TailSubProp>[
  _TailSubProp('RecordResults', 'Bool', (f) => f.name == 'RecordResults' && f.value != null),
  _TailSubProp('FailureAction', 'Num', (f) => f.name == 'FailureAction' && f.value != null),
  _TailSubProp(
    'Requirements',
    'Obj',
    (f) =>
        f.name == 'Requirements' &&
        f.className == 'Obj' &&
        f.children.any((c) => c.name == 'Links' && c.className == 'Strs'),
  ),
  _TailSubProp('RTS', 'Obj', (f) => f.name == 'RTS' && f.className == 'Obj' && f.children.isNotEmpty),
];

/// Decodes a step's `TS` subprops from the step-data descriptor node at
/// [at] (`[0][0][DELIM][TS][childCount][children…]`, immediately after
/// the four-word step reference) — see [_TypeBodyParser.parseStepTs] for
/// the full-node vs Id-only fallback and the honesty gates.
List<BinaryTypeField> _stepTsSubProps(_TypeBodyParser parser, int at) => parser.parseStepTs(at);

/// Locates each sequence RECORD — `[Sequence][name][subpropCount]` — and
/// decodes the subprops that precede its `Main` group array (Parameters,
/// Locals, …) with the typedef field grammar. Keyed by sequence name; a
/// sequence whose record is not found or whose leading subprops do not
/// frame is simply absent (never guessed). The record is distinct from
/// the array-element DECLARATION (`[] / name / Objs / Seq / [i]`); it is
/// the `Sequence`-classed object that carries the sequence's own fields.
Map<String, List<BinaryTypeField>> _sequenceLeadingSubProps(
  Uint8List body,
  ByteData view,
  List<String> pool,
  int recordRegionLength,
  List<BinaryTypeRecord> table,
  int typeIndexBase,
  Set<String> sequenceNames, [
  _DecodeSink sink = _DecodeSink.none,
]) {
  final sequenceToken = pool.indexOf('Sequence');
  if (sequenceToken <= 0) return const {};
  final nameIndices = <int, String>{
    for (var i = 1; i < pool.length; i++)
      if (sequenceNames.contains(pool[i])) i: pool[i],
  };
  if (nameIndices.isEmpty) return const {};
  int u32(int at) => view.getUint32(at, Endian.little);
  final result = <String, List<BinaryTypeField>>{};
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;
  for (var at = 0; at + 3 * _u32Bytes <= recordRegionLength; at += 1) {
    if (u32(at) != sequenceToken) continue;
    final name = nameIndices[u32(at + _u32Bytes)];
    if (name == null || result.containsKey(name)) continue;
    final count = u32(at + 2 * _u32Bytes);
    if (count < 1 || count > _typeMaxFields) continue;
    final mWalk = sink.mark();
    final decoded = parser.parseLeadingSubProps(at + 3 * _u32Bytes, count, _stepGroupNames);
    // Keep only the KNOWN pre-Main subprops (Parameters, Locals — the
    // only two the sequence layout places before the Main group array),
    // as a leading prefix. This is the honesty gate: it drops any field
    // the walk misparsed past the real leading region (e.g. a field
    // spuriously named after a structural token) and rejects a
    // coincidental [Sequence][name][small-number] triple whose first
    // field is not one of them.
    final subProps = <BinaryTypeField>[];
    var keptEnd = at + 3 * _u32Bytes;
    for (final (field, fieldEnd) in decoded) {
      if (!_sequenceLeadingSubPropNames.contains(field.name)) break;
      subProps.add(field);
      keptEnd = fieldEnd;
    }
    if (subProps.isEmpty) {
      sink.rollback(mWalk);
      continue;
    }
    // Drop the ops of the fields past the kept prefix, then emit the
    // `[Sequence][name][count]` record head.
    sink.rollbackTailFrom(mWalk, keptEnd);
    sink.poolRef(at, u32(at));
    sink.poolRef(at + _u32Bytes, u32(at + _u32Bytes));
    sink.u32(at + 2 * _u32Bytes, count, _OpSource.model);
    // The `[Sequence][name][count]` record head plus the kept subprop run.
    sink.claim(at, keptEnd, _tierSemantic);
    result[name] = subProps;
  }
  return result;
}

/// Whether [cur] is packed immediately after [prev] in a NUL-terminated string
/// table — its offset is one byte (the single NUL) past the end of [prev]. The
/// back-to-back single-NUL packing invariant every chain-walker keys on.
bool _packedAfter(BinaryString prev, BinaryString cur) => cur.offset == prev.offset + prev.text.length + 1;

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
/// Finds the record/string boundary — the offset where the first packed
/// string table begins — WITHOUT materializing the body's strings.
///
/// Equivalent to `_firstTableOffset(binaryStrings(body, minLength:
/// _minRunLength))` (the record region is scanned for the first chain of
/// ≥[_boundaryChainMin] NUL-adjacent printable runs), but it tracks only
/// each run's (offset, length), returns the instant the chain first
/// reaches the threshold (its start is already fixed), and never touches
/// the bytes past the boundary. That turns an O(body)-time, O(strings)-
/// allocation pass — run on EVERY public lens via [_withLayout] — into an
/// O(boundary)-time, O(1)-allocation one. The rich [_layoutFromBody]
/// (string/sentinel/segment counts) stays for the recon views that need
/// those stats.
int? _recordRegionBoundary(Uint8List body) {
  int? prevStart, prevLen;
  var chainStart = -1;
  var chainCount = 0;
  var runStart = -1;
  final n = body.length;
  for (var i = 0; i <= n; i++) {
    if (i < n && isBinaryPrintable(body[i])) {
      if (runStart < 0) runStart = i;
      continue;
    }
    if (runStart >= 0) {
      final len = i - runStart;
      if (len >= _minRunLength) {
        // Packed right after the previous run (its start == the previous
        // run's end + one NUL) extends the chain; otherwise starts a new
        // one — the same adjacency [_packedAfter] tests.
        if (prevStart != null && runStart == prevStart + prevLen! + 1) {
          chainCount++;
        } else {
          chainStart = runStart;
          chainCount = 1;
        }
        if (chainCount >= _boundaryChainMin) return chainStart;
        prevStart = runStart;
        prevLen = len;
      }
      runStart = -1;
    }
  }
  return null;
}

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

/// Counts sentinel words ([_sentinelWord]) on u32 steps in `bytes[0, end)`.
/// [end] is clamped to the buffer so an over-large bound can't read past it.
int _countSentinels(Uint8List bytes, int end) {
  final limit = end < bytes.length ? end : bytes.length;
  final view = ByteData.sublistView(bytes);
  var count = 0;
  for (var i = 0; i + _u32Bytes <= limit; i += _u32Bytes) {
    if (view.getUint32(i, Endian.little) == _sentinelWord) count++;
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
}) => _stringTableFromRuns(binaryStrings(body, minLength: minLength));

List<BinaryString> _stringTableFromRuns(List<BinaryString> runs) {
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
///
/// A caller that has already inflated the body (e.g. `SeqDocument.parse`, which
/// also feeds the partial typed parse) can pass it as [body] to skip even that
/// one inflate; it must be the inflated body OF [seqBytes].
BinaryAnalysis? analyzeBinary(Uint8List seqBytes, {Uint8List? body}) {
  body ??= inflateBinaryBody(seqBytes);
  if (body == null) return null;
  // One printable-run scan feeds every recon view. The pool-grade runs
  // (min length [_poolMinRunLength]) are scanned once; the table-grade
  // list (min length [_minRunLength]) is a filter of them — a run's extent
  // does not depend on the threshold, so the filtered list is identical to
  // a second scan at the higher minimum.
  final strings = binaryStrings(body, minLength: _poolMinRunLength);
  final runs = [
    for (final run in strings)
      if (run.text.length >= _minRunLength) run,
  ];
  final segments = _segmentsFromRuns(runs);
  final nameTable = _nameTableFromSegments(segments)?.entries ?? const [];
  final layout = _layoutFromRuns(body, runs);
  return BinaryAnalysis(
    inflatedSize: body.length,
    strings: strings,
    stringTable: _stringTableFromRuns(runs),
    layout: layout,
    nameTable: nameTable,
    objectNames: _objectNamesFrom([for (final entry in nameTable) entry.text]),
    modulePaths: _poolWhereFrom(segments, isBinaryModulePath),
    stepReferences: _poolWhereFrom(segments, _isStepRef),
    expressions: _poolWhereFrom(segments, isBinaryExpression),
    quotedLiterals: _poolWhereFrom(segments, isBinaryQuotedLiteral),
    namedScalars: layout == null ? const [] : _namedScalarsFromBody(body, layout.recordRegionLength),
    scalarDoubles: layout == null ? const [] : _scalarDoublesFromBody(body, layout.recordRegionLength),
    namedRecords: layout == null ? const [] : _namedRecordsFromBody(body, layout.recordRegionLength),
  );
}

// ───────────────────────── the recorded decode stream ─────────────────────────

/// The single-decode bundle of one inflated binary TOF1 body: the body's
/// bytes, its record/string boundary, the ordered string pool, and the
/// recorded decode stream. Produced ONCE by [_decodeBody] (or [_decodeSeq]
/// from the container bytes); every downstream fold — the byte-coverage
/// accounting, the undecoded-span census, and the write-model builder —
/// consumes the same instance, so none re-inflates the container, re-splits
/// the pool, or re-runs the decode passes.
class _BodyDecode {
  const _BodyDecode(this.body, this.boundary, this.pool, this.stream);

  /// The inflated body the decode walked.
  final Uint8List body;

  /// The record-region length (the record/string boundary).
  final int boundary;

  /// The ordered NUL string pool of the string region ([_orderedStringPool]
  /// over `body[boundary..]`).
  final List<String> pool;

  /// The recorded decode stream: write ops plus coverage claims/demotions.
  final _RecordingDecodeSink stream;
}

/// Inflates and decodes a whole binary TOF1 container once —
/// [inflateBinaryBody] then [_decodeBody]. Returns null when [seqBytes] is
/// not an inflatable binary file or its body does not frame.
_BodyDecode? _decodeSeq(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  return _decodeBody(body);
}

/// Runs the production decode passes over [body]'s record region and records
/// their typed decode stream — write ops plus coverage tier claims — into one
/// [_DecodeSink], returned as a [_BodyDecode] bundle alongside the boundary
/// and the string pool it already built. Returns null when the body does not
/// frame. Never a parallel grammar: every op and claim comes from the same
/// scan/parser the decode lenses use.
///
/// The stream is the single product both downstream consumers fold:
/// the writer's re-serialization plan ([_buildWritePlan] over the ops — see
/// `seq_binary_write.dart`) and the byte-coverage metrics ([_tiersOfStream]
/// over the claims — see `seq_binary_metrics.dart`). They can never disagree
/// about what is decoded, because one pass records both.
_BodyDecode? _decodeBody(Uint8List body) {
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) return null;
  final sink = _RecordingDecodeSink();
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return _BodyDecode(body, recordRegionLength, pool, sink);
  final view = ByteData.sublistView(body);

  // Leading recon words: measured invariants (`leadingWords[2] == 1`, the
  // 0x10/0x76 layout selector), meaning not fully decoded.
  sink.claim(0, _leadingWordCount * _u32Bytes, _tierStructural);
  sink.copy(0, _leadingWordCount * _u32Bytes);

  // Type records: heads (semantic, minus the undecoded word-3 slot of the
  // word-4-triple layout), decoded bodies (semantic), the fixed preamble
  // before each subsequent head (structural). Blob sites (element-type
  // specs, extdata blocks) collected during the SAME parses demote below.
  final bodyOffsets = <String, int>{};
  final headOffsets = <String, int>{};
  final tripleOffsets = <String, int>{};
  // Heads and body/head/triple offsets only — the coverage pass RE-PARSES
  // each body below (with the spec/ext collector armed) to mark its spans,
  // so decoding bodies here too would parse every body twice. The head
  // table (names/offsets) is all the span loop and outline pass need.
  final records = _typeRecordsFromBody(
    body,
    recordRegionLength,
    sharedPool: pool,
    bodyOffsetsOut: bodyOffsets,
    headOffsetsOut: headOffsets,
    tripleOffsetsOut: tripleOffsets,
    decodeBodies: false,
  );
  // Whole-file constant — derive once and thread into every body parse.
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, records);
  final blobSpans = <(int, int)>[];
  _TypeBodyParser.debugSpecSites.clear();
  _TypeBodyParser.debugExtSpans.clear();
  _TypeBodyParser.debugCollectSpecs = true;
  try {
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      final headAt = headOffsets[record.name];
      final tripleAt = tripleOffsets[record.name];
      if (headAt == null || tripleAt == null) continue;
      final bodyAt = bodyOffsets[record.name];
      // classname word, name, typecategory, stamp.
      final headStart = headAt >= _u32Bytes ? headAt - _u32Bytes : headAt;
      sink.claim(headStart, headAt + _typeStampOffset + _u32Bytes, _tierSemantic);
      if (tripleAt > _typeStampOffset + _u32Bytes) {
        // The extra pool-ref word before a word-4 triple: not yet decoded.
        sink.claim(headAt + _typeStampOffset + _u32Bytes, headAt + tripleAt, _tierStructural);
      }
      // Version triple, flag words, terminator, head delimiter (when framed).
      final headEnd = bodyAt ?? headAt + tripleAt + _typeVersionTripleWords * _u32Bytes;
      sink.claim(headAt + tripleAt, headEnd, _tierSemantic);
      if (headAt >= _u32Bytes) {
        final classWord = view.getUint32(headAt - _u32Bytes, Endian.little);
        if (classWord > 0 && classWord < pool.length && pool[classWord].isNotEmpty) {
          sink.poolRef(headAt - _u32Bytes, classWord);
        } else {
          sink.u32(headAt - _u32Bytes, classWord, _OpSource.struct);
        }
      }
      sink.poolRef(headAt, view.getUint32(headAt, Endian.little));
      sink.u32(headAt + _u32Bytes, record.typeCategory, _OpSource.model);
      sink.u32(headAt + _typeStampOffset, record.timestamp, _OpSource.model);
      if (tripleAt > _typeStampOffset + _u32Bytes) {
        sink.copy(headAt + _typeStampOffset + _u32Bytes, headAt + tripleAt);
      }
      for (var v = 0; v < _typeVersionTripleWords; v++) {
        final wordAt = headAt + tripleAt + v * _u32Bytes;
        sink.poolRef(wordAt, view.getUint32(wordAt, Endian.little));
      }
      // Tail: flag words + trailing zeros + delimiter (framed), or the
      // `[1][idRef]` binary-only generation tail. The flag words are the
      // typed model's head attributes ([BinaryTypeRecord.flags], named
      // typeflags/flagsforinstances/instanceoverrideflags/valueflags by
      // count — twin-validated); every word past them is a zero the head
      // scan verified (only TRAILING zeros are dropped from [flags]),
      // then the verified record delimiter.
      final tailAt = headAt + tripleAt + _typeVersionTripleWords * _u32Bytes;
      if (bodyAt != null &&
          bodyAt >= _u32Bytes &&
          view.getUint32(bodyAt - _u32Bytes, Endian.little) == _recordDelimiter) {
        final flagsEnd = tailAt + record.flags.length * _u32Bytes;
        for (var q = tailAt; q + _u32Bytes <= headEnd; q += _u32Bytes) {
          final word = view.getUint32(q, Endian.little);
          if (q < flagsEnd) {
            sink.u32(q, word, _OpSource.model); // BinaryTypeRecord.flags[...]
          } else if (word == 0 || word == _recordDelimiter) {
            sink.u32(q, word, _OpSource.grammar);
          } else {
            sink.u32(q, word, _OpSource.struct); // unreachable by the scan's construction
          }
        }
      } else if (bodyAt != null) {
        // The binary-only generation tail `[1][idRef]` — the constant 1
        // is the scan's verified gate.
        sink.u32(tailAt, 1, _OpSource.grammar);
        sink.poolRef(tailAt + _u32Bytes, view.getUint32(tailAt + _u32Bytes, Endian.little));
      }
      final nextHeadAt = i + 1 < records.length ? headOffsets[records[i + 1].name] : null;
      if (nextHeadAt != null && nextHeadAt >= _u32Bytes + _typeRecordPreambleBytes) {
        // The fixed 17-byte preamble before the next record's head:
        // extent measured on every cleanly-decoded body, contents TODO.
        sink.claim(nextHeadAt - _u32Bytes - _typeRecordPreambleBytes, nextHeadAt - _u32Bytes, _tierStructural);
        sink.copy(nextHeadAt - _u32Bytes - _typeRecordPreambleBytes, nextHeadAt - _u32Bytes);
      }
      if (bodyAt == null) continue;
      final boundary = nextHeadAt != null ? nextHeadAt - _u32Bytes - _typeRecordPreambleBytes : null;
      final parser = _TypeBodyParser(view, pool, recordRegionLength, records, boundary, typeIndexBase)..ops = sink;
      final mBody = sink.mark();
      if (parser.parse(bodyAt) != null) {
        sink.claim(bodyAt, _TypeBodyParser.debugLastEndOffset!, _tierSemantic);
      } else {
        sink.rollback(mBody);
      }
      // A bailed body stays undecoded — all-or-nothing, nothing claimed.
    }

    // Sequences, steps, TS nodes, module pairs, leading/tail subprops —
    // the production outline pass with the sink threaded through.
    _sequenceOutlinesFromBody(
      body,
      recordRegionLength,
      pool,
      [
        for (final record in records) record.name,
      ],
      records,
      sink,
    );

    for (final (_, start, length) in _TypeBodyParser.debugSpecSites) {
      blobSpans.add((start, start + length));
    }
    blobSpans.addAll(_TypeBodyParser.debugExtSpans);
  } finally {
    _TypeBodyParser.debugCollectSpecs = false;
    _TypeBodyParser.debugSpecSites.clear();
    _TypeBodyParser.debugExtSpans.clear();
  }

  // Old-format (TS 4.x/5.0) leaf property records — includes the group
  // markers the outline pass anchors on.
  for (final record in _propertyRecordsFromBody(body, recordRegionLength, pool)) {
    sink.claim(record.offset, record.offset + record.length, _tierSemantic);
    _leafPropertyRecordOps(sink, view, record);
  }

  // Structurally-walked blobs: extent known, contents undecoded. Recorded as
  // demotions (semantic → structural, applied by the metrics fold) so a site
  // recorded during a parse trial that later bailed can never upgrade
  // unaccounted bytes.
  for (final (start, end) in blobSpans) {
    sink.demote(start, end);
  }
  return _BodyDecode(body, recordRegionLength, pool, sink);
}

/// Tooling aid for grammar iteration, not part of the decode API: parses a
/// single field record at byte offset [at] of the inflated body with the
/// production field grammar (full type table in scope — framed references
/// resolve), returning the decoded field and its end offset, or null when the
/// bytes do not frame. Uses the production parser, so a probe can never
/// disagree with the real decode.
(BinaryTypeField, int)? binaryFieldAt(Uint8List seqBytes, int at) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) return null;
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return null;
  final view = ByteData.sublistView(body);
  final table = _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool);
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table);
  final field = parser.parseFieldAt(at);
  if (field == null) return null;
  return (field, _TypeBodyParser.debugLastEndOffset!);
}

/// Tooling aid (grammar iteration, like [binaryFieldAt]): parses a single
/// field record at [at] and, when it FAILS, returns the byte offset of the
/// deepest field attempt the parse made before bailing — the exact spot to
/// point the prober at. Returns null when the field parses (no bail) or the
/// file does not frame.
int? binaryFieldBailOffset(Uint8List seqBytes, int at) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) return null;
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return null;
  final view = ByteData.sublistView(body);
  final table = _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool);
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table);
  if (parser.parseFieldAt(at) != null) return null;
  return _TypeBodyParser.debugLastFieldOffset;
}
