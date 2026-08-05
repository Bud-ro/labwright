import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_property.dart';

part 'seq_binary_metrics.dart';
part 'seq_binary_write.dart';

/// zlib stream first byte (CMF): deflate method, 32K window — the marker the
/// body scan keys on.
const _zlibCmf = 0x78;

/// Recognized zlib FLG second bytes (the byte after [_zlibCmf]) seen in TOF1
/// bodies.
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

/// The all-ones `ff ff ff ff` dword [_countSentinels] counts. Not a record
/// delimiter (see [BinaryBodyLayout.sentinelCount]) but an all-ones value in
/// the byte-packed records — numerically the same word as [_recordDelimiter],
/// catalogued apart because the meaning differs.
const _sentinelWord = 0xffffffff;

/// Bytes per little-endian u32 word in the record region.
const _u32Bytes = 4;

/// Bytes per little-endian IEEE-754 double in the record region.
const _f64Bytes = 8;

/// The smallest positive normal IEEE-754 double (2^-1022). Subnormals are the
/// signature of a mis-framed scalar run: small-integer / handle data read as an
/// f64 collapses into this range (the i64 IDs `1..10` decode as ~5e-324). Real
/// f64 array elements are zero or human-scale, so rejecting subnormals leaves a
/// mis-frame undecoded instead of fabricating values.
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

/// PropertyObject model name/type tokens NI's engine writes into every sequence
/// file. Used to pick the property-name table out of the packed string segments
/// by content — it carries the most of these, the value/expression tables few or
/// none. Not exhaustive; matches in all 83 corpus binaries. The record grammar
/// that would label the tables directly is not yet decoded.
const _modelNameTokens = {
  'Sequence',
  'MainSequence',
  'SequenceFile',
  'Step',
  'StepType',
  'Locals',
  'Parameters',
};

/// The fixed PropertyObject container scaffold that opens a binary TOF1 name
/// table — the file's ordered string pool, referenced by 0-based index. The five
/// entries are the root `SequenceFileData` object, its `Data`/`Objs` array
/// structure, and the first array element (`Seq`/`[0]`). Every binary file rooted
/// at `SequenceFileData` (82/83; the exception is a partial plugin file with no
/// file-data root) opens with this prefix; entries past index 4 vary.
const binaryNameScaffold = ['SequenceFileData', 'Data', 'Objs', 'Seq', '[0]'];

/// How many leading record-region u32 words [analyzeBinaryBody] captures.
const _leadingWordCount = 3;

/// Locates and inflates the zlib-compressed body of a binary `TOF1` `.seq`.
///
/// A TOF1 file is a plaintext header followed by a single zlib stream whose
/// inflated bytes hold the same PropertyObject model as the XML form (the names
/// `SequenceFileData`, `Sequence`, `MainSequence`, `Step`, `StepType`, … appear
/// in the clear) — the analog of the VI heap's zlib sections. Inflation is
/// streamed under the [_maxInflatedBytes] cap so a decompression bomb aborts
/// instead of exhausting memory.
///
/// Returns the decompressed body, or null when [bytes] is not a binary TOF1 file
/// or no inflatable stream is found. Total over arbitrary input (never throws).
Uint8List? inflateBinaryBody(Uint8List bytes) {
  return _locateAndInflateBody(bytes)?.$2;
}

/// Inflates [input] with a chunked [ZLibDecoder], returning null once the
/// running output exceeds [_maxInflatedBytes] — a decompression bomb aborts
/// after buffering at most one input chunk past the cap. Rethrows format
/// errors so the caller keeps scanning.
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
/// The inflated body packs the PropertyObject names as NUL-terminated strings (a
/// 0x00 sits before and after each run), so the model names (`Sequence`, `Step`,
/// `Locals`, `Parameters`, `StepType`, …) are recovered cleanly. Returns `[]`
/// when [seqBytes] is not an inflatable binary file.
List<BinaryString> binaryBodyStrings(
  Uint8List seqBytes, {
  int minLength = _poolMinRunLength,
}) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return binaryStrings(body, minLength: minLength);
}

/// A recon framing of a binary TOF1 inflated body into its two regions: a
/// leading record region (little-endian u32 fields with `ff ff ff ff`
/// sentinels) followed by the string region (packed NUL-terminated tables the
/// records reference by index). Every field here is derived from the bytes; the
/// record grammar linking the two regions is not yet decoded.
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
  /// Not a record delimiter: byte-granularity `ff ff ff ff` runs occur at all
  /// four byte phases ~uniformly, they outnumber the named objects by ~14–310×
  /// (median 43×), and the u32 after a run is a valid name index only ~45% of
  /// the time. They are `0xffffffff` all-ones values (−1 / "not set" defaults)
  /// embedded in the byte-packed records. Kept as a descriptive count.
  ///
  /// The largest residual undecoded spans (the populated array/step element
  /// content that defeats [_populatedArrayTail] and [_stepElementPrefix]) are a
  /// regular but non-word-aligned object-reference graph: partitioning a span on
  /// `ff ff ff ff` byte runs yields variable-length records whose byte lengths
  /// cluster at recurring sizes (44 / 68 / 129 bytes) carrying a monotonically
  /// increasing per-record id word. Walking it by delimiter counting is unsound:
  /// 4-byte and 8-byte `ff` runs coexist (an 8-byte run is ambiguous between two
  /// adjacent separators and one separator abutting an all-ones null-reference
  /// value) and record lengths are byte-granular (44 vs 45, 129 vs 130), so the
  /// word grid cannot arbitrate. That needs the record payload grammar, which is
  /// not yet decoded and which no XML/twin oracle materializes.
  final int sentinelCount;

  /// Number of distinct packed string tables (maximal NUL-adjacent run chains)
  /// in the string region. Corpus-observed: ≥6 in all 83 binary files.
  final int segmentCount;

  /// The first few little-endian u32 words at the start of the record region.
  /// Across all 83 binary files `leadingWords[2] == 1` (a constant marker) and
  /// `leadingWords[1] ∈ {16, 118}` (0x10 / 0x76); `leadingWords[0]` varies and
  /// is not a simple count.
  ///
  /// `leadingWords[1]` is a record-prefix layout selector, picking one of two
  /// serialization layouts for the scaffold prefix (82/82 rooted files): with
  /// `0x76` the prefix runs `…1=Data, 2=Objs, _, 4=[0], _, _, 768`, with `0x10`
  /// `…1=Data, _, _, 3=Seq, _, 0`. It is not the engine/save version (both
  /// cohorts span header versions 14/19/21), not the fileType (all
  /// SequenceFile), and not the source tool (the same repos produce both). The
  /// 0x76 layout also carries more string segments.
  // TODO: why a file uses one layout over the other, and the meaning of
  // leadingWords[0], are not yet determined.
  final List<int> leadingWords;

  @override
  String toString() =>
      'BinaryBodyLayout(inflated=$inflatedSize, '
      'recordRegion=$recordRegionLength, strings=$stringCount, '
      'segments=$segmentCount, sentinels=$sentinelCount, lead=$leadingWords)';
}

/// Frames the inflated body of a binary TOF1 `.seq` into a [BinaryBodyLayout]:
/// the leading record region and the trailing string region, with recon counts.
/// Every corpus file splits into a non-empty record region followed by a string
/// table of ≥5 entries. Exposes where the records and strings live and how many,
/// not their meaning. Returns null when [seqBytes] is not an inflatable binary
/// file or no packed string table is found.
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
/// value/expression tables) is not yet decoded.
typedef BinaryStringSegment = ({int offset, List<BinaryString> entries});

/// Splits the string region of a binary TOF1 body into its packed tables — every
/// maximal NUL-adjacent run chain of ≥[minChain] entries, in order. Returns `[]`
/// when [seqBytes] is not an inflatable binary file or has no string region.
///
/// Where [binaryStringTable] returns only the single largest table, this returns
/// them all (≥6 segments in all 83 binary files). The record grammar that
/// references these by index is not yet decoded.
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

/// Identifies the property-name table among a binary TOF1 body's packed string
/// segments — the segment carrying the PropertyObject name/type tokens
/// (`Sequence`, `Step`, `Locals`, …), as distinct from the value/expression
/// tables. Picked by content (the segment matching the most [_modelNameTokens],
/// earliest on a tie) while the record grammar that would label the tables stays
/// undecoded. All 83 binary files have one; it is never the largest segment (the
/// value/expression tables are bigger) and is the first segment in 82/83, a
/// tendency selection does not rely on. Null when [seqBytes] is not an
/// inflatable binary file or no segment carries model names.
BinaryStringSegment? binaryNameTable(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  return _nameTableFromSegments(_segmentsFromBody(body));
}

/// The property/object names a binary TOF1 file defines, beyond the fixed
/// container [binaryNameScaffold] — the file's own sequences, steps, locals, and
/// other named objects, in name-pool order. A flat list, not a parsed tree: the
/// record links giving the names hierarchy and values are not yet decoded. Drops
/// the leading scaffold prefix when present (rooted files), else returns the
/// whole pool; `[]` when [seqBytes] is not an inflatable binary file.
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

/// Whether [s] looks like a module call-target path — a path-separated string
/// ending in a known adapter target extension (`.vi`/`.dll`/`.seq`/`.llb`), e.g.
/// `My Computer\ExcelReadWrite\Excel_Read.vi` or `SubSequences\AC_Gerilim.seq`.
/// A bare suffix (`.vi`) or a separator-less token is rejected.
bool isBinaryModulePath(String text) => text.contains('\\') && _modulePathRe.hasMatch(text);

/// The module call-target paths a binary TOF1 file references — the LabVIEW VIs
/// / DLLs / sub-sequences / libraries its steps invoke (see
/// [isBinaryModulePath]), distinct and in name-pool order. What the sequence
/// calls, not yet from which step: the record grammar tying a path to its step
/// is not yet decoded. 190/288 binary files expose ≥1 (median 5); the rest make
/// no external calls or carry paths fragmented by non-ASCII bytes in the run
/// splitter. `[]` when [seqBytes] is not an inflatable binary file.
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

/// The `ID#:` step references a binary TOF1 file carries — the unique step-ID
/// tokens the INI/XML lens resolves to step links, verbatim in the same
/// `ID#:<base64-ish>` form the text encodings use. Distinct, in pool order.
/// Resolving each to its target step needs the not-yet-decoded record grammar.
/// 285/288 binary files expose ≥1; `[]` when [seqBytes] is not an inflatable
/// binary file.
List<String> binaryStepReferences(Uint8List seqBytes) => _poolWhere(seqBytes, _isStepRef);

bool _isStepRef(String text) => text.startsWith('ID#:');

/// Member access on a TestStand expression root (`Locals.x`, `Step.Result…`,
/// `RunState.LoopIndex`, `StationGlobals.…`, …) — the surest expression marker.
final _exprRootRe = RegExp(r'\b(Locals|Parameters|Step|RunState|FileGlobals|StationGlobals|Seq|ThisContext)\.');

/// A comparison / logical / ternary operator (the test-logic operators).
final _exprOpRe = RegExp(r'(==|!=|<=|>=|&&|\|\||\?.*:)');

/// A known TestStand expression function call (`Abs(`, `Str(`, `ResStr(`, …).
final _exprFnRe = RegExp(r'\b(Abs|Str|Val|Round|Mid|Len|Left|Right|ResStr|LocalizeExpression|Mod)\s*\(');

/// Whether [s] looks like a TestStand expression — the strings carrying a
/// sequence's logic: limit/condition comparisons, `RunState`/`Locals`/`Step`
/// member access, ternaries, and known expression-function calls. Module paths
/// ([isBinaryModulePath]) and `ID#:` step references are excluded so this stays
/// disjoint from those recoveries.
bool isBinaryExpression(String text) {
  if (text.startsWith('ID#:') || isBinaryModulePath(text)) return false;
  return _exprRootRe.hasMatch(text) || _exprOpRe.hasMatch(text) || _exprFnRe.hasMatch(text);
}

/// The expression strings a binary TOF1 file carries — its test logic
/// (conditions, limit/numeric expressions, name/description format expressions,
/// loop and result expressions; see [isBinaryExpression]), distinct and in
/// name-pool order. The set a file evaluates, not a per-step mapping: attaching
/// each to its step/field needs the not-yet-decoded record grammar. 285/288
/// binary files expose ≥1 (15910 distinct total); `[]` when [seqBytes] is not an
/// inflatable binary file.
List<String> binaryExpressions(Uint8List seqBytes) => _poolWhere(seqBytes, isBinaryExpression);

/// Whether [s] is a quoted string literal — a whole entry wrapped in double
/// quotes (`"6105A"`, `"Unnamed Entry Point"`, `"%ModuleDescription"`), i.e. a
/// constant value rather than an [isBinaryExpression]. A quoted entry that also
/// contains operators (`"a" == "b"`) is an expression, excluded here so the
/// recoveries stay disjoint.
bool isBinaryQuotedLiteral(String text) =>
    text.length >= 2 && text.startsWith('"') && text.endsWith('"') && !isBinaryExpression(text);

/// The quoted string literals a binary TOF1 file carries — constant values its
/// steps/expressions reference (instrument resource strings, expected values,
/// captions, …; see [isBinaryQuotedLiteral]), distinct and in name-pool order.
/// Which literal a given step uses needs the not-yet-decoded record grammar.
/// 288/288 binary files expose ≥1 (2883 distinct total); `[]` when [seqBytes] is
/// not an inflatable binary file.
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
/// record stream preceding the string region.
///
/// The records reference [binaryNameTable] entries by 0-based index: a fresh
/// inflated body opens `[leadingWords[0], leadingWords[1], 1, …]` and the small
/// words that follow index the name pool (the constant `1` selects
/// `name[1] == 'Data'`, then `name[2] == 'Objs'`, … — the [binaryNameScaffold]
/// path). Indices are interleaved with binary field values and the records are
/// variable-length (value payloads shift u32 alignment), so this is a decode
/// aid, not a flat index array. `[]` when [seqBytes] is not an inflatable binary
/// file or the body does not frame.
List<int> binaryRecordWords(Uint8List seqBytes) => _withLayout(seqBytes, _recordWordsFromBody);

/// Inflates [seqBytes], frames its layout, and delegates to [extract] over the
/// body and its record-region length — the shared inflate+frame+guard prologue
/// for the record-region readers. Returns `[]` when the file is not an
/// inflatable binary file or does not frame. (`const <Never>[]` because a bare
/// `const []` would try to infer `T`, a compile error.)
List<T> _withLayout<T>(
  Uint8List seqBytes,
  List<T> Function(Uint8List body, int recordRegionLength) extract,
) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const <Never>[];
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

/// The inline scalar `double` values a binary TOF1 file embeds in its record
/// region — step-type parameter defaults / numeric limits, distinct and in
/// record order.
///
/// A named numeric property stores an 8-byte little-endian IEEE-754 `double` two
/// u32 words after its name reference — the record shape
/// `⟨tag⟩ ⟨name-offset⟩ ⟨type-code⟩ ⟨f64⟩`, verified on the Rosetta near-twins
/// (the same value set is byte-identical across the NIDmm/NIScope minimal
/// binaries). Tying each value to its leaf property needs the record grammar, so
/// this is the value set only. To suppress coincidental bit patterns it accepts
/// only clean doubles: low 32 bits zero (a round value, as every observed
/// default is), finite, non-zero, and `|v|` within [[_minScalarMagnitude],
/// [_maxScalarMagnitude]]. `[]` when [seqBytes] is not an inflatable binary file
/// or doesn't frame.
List<double> binaryScalarDoubles(Uint8List seqBytes) => _withLayout(seqBytes, _scalarDoublesFromBody);

/// A clean recovered double: finite, non-zero, and `|v|` within
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
    // A clean default has all-zero low 32 bits.
    if (view.getUint32(i, Endian.little) != 0) continue;
    final value = view.getFloat64(i, Endian.little);
    if (!_isCleanScalar(value)) continue;
    if (seen.add(value)) out.add(value);
  }
  return out;
}

/// One inline scalar `double` recovered from a named-property record in the
/// binary TOF1 record region, with the structural context tying it to a
/// property-name reference.
///
/// A numeric named property is stored as the record header
/// `⟨tag⟩ ⟨name-offset⟩ ⟨type-code⟩ ⟨f64⟩` (confirmed on the Rosetta near-twins):
/// the `name-offset` word is the string-region-relative byte offset of the
/// property name (resolving to [name] via the name table), and an 8-byte
/// little-endian IEEE-754 `double` follows the type word. Across the minimal
/// binaries every emitted record resolves to the `Parameters` container with
/// [rawTag] `0`, carrying the step-type's numeric defaults/limits in record
/// order. [rawTag] and [rawTypeCode] are raw NI words, exposed verbatim so
/// callers can group records without inventing semantics for the codes.
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

  /// The raw leading `tag` word of the record header, verbatim (not modeled).
  final int rawTag;

  /// The raw `type-code` word following the name reference, verbatim — an NI
  /// type/option code left uninterpreted.
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

/// The named-property scalar records a binary TOF1 file embeds — the
/// structurally-attributed subset of [binaryScalarDoubles], each inline `double`
/// paired with the property name it is filed under and the raw tag/type words of
/// its header (see [BinaryNamedScalar]).
///
/// Scans the record region for the header shape `⟨tag⟩ ⟨name-offset⟩ ⟨type-code⟩
/// ⟨f64⟩`: a word resolving (as a string-region-relative offset) to a real
/// name-table entry, followed by a type word and a clean inline double (the same
/// filter as [binaryScalarDoubles]). The clean-f64 requirement plus the exact
/// name-offset match suppresses coincidental hits: on the Rosetta near-twins
/// every emitted record resolves to the `Parameters` container (tag `0`) with no
/// false positives. In record order, duplicate values kept (distinct record
/// slots); `[]` when [seqBytes] is not an inflatable binary file or does not
/// frame.
List<BinaryNamedScalar> binaryNamedScalarRecords(Uint8List seqBytes) => _withLayout(seqBytes, _namedScalarsFromBody);

/// [binaryNamedScalarRecords] core over an already-inflated [body]. Word `w` is
/// the record's name-offset word; `w-1` is the tag, `w+1` the type-code, and
/// `w+2..w+3` the inline f64.
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

/// A consistently-referenced named-property record header in a binary TOF1
/// record region: a name the records cite (by its string-region-relative offset)
/// always with the same leading [rawTag] word, across [count] occurrences.
///
/// The per-name tag consistency is the evidence these are real record headers
/// rather than coincidental offset matches — a chance collision would not
/// repeatedly carry the identical preceding word (`Parameters` tag 0,
/// `ResultList` tag 2). [rawTag] is the raw NI tag word, verbatim. The
/// per-record type word varies per member (`Parameters` holds many distinct type
/// codes), so it is not summarized here; use [binaryNamedScalarRecords] for the
/// typed scalar slots.
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

  /// The consistent leading `tag` word of the record header (not modeled).
  final int rawTag;
}

/// Whether [s] looks like a property/container name rather than a recovered
/// value string. Value strings (quoted literals, expressions, module paths,
/// `ID#:` step refs) are not offset-referenced, so a record word matching one's
/// offset is coincidence — excluded from [binaryNamedRecords].
bool _isNameLike(String text) =>
    !isBinaryQuotedLiteral(text) && !isBinaryExpression(text) && !isBinaryModulePath(text) && !_isStepRef(text);

/// The consistently-referenced named-property record headers of a binary TOF1
/// file — the structural skeleton beyond the scalar slots
/// ([binaryNamedScalarRecords]): which property/container names the records cite
/// (by string-region-relative offset) and how often, by descending
/// [BinaryNamedRecord.count].
///
/// A name qualifies when it is non-empty, referenced at a non-zero string-region
/// offset (offset 0 is the root `SequenceFileData`, which every zero record word
/// would spuriously match), referenced ≥2 times, and every such reference
/// carries the same preceding `tag` word. On the Rosetta near-twins this admits
/// the real TestStand identifiers (`Parameters`, `ResultList`, `[0]`,
/// `DescriptionFormat`, `NI_DotNetParameterResult`, …) and drops the
/// inconsistently-tagged noise (`Locals`, `Seq`). A header census, not a parse:
/// the record grammar linking these to the step tree is not yet decoded. `[]`
/// when [seqBytes] is not an inflatable binary file or doesn't frame.
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

/// The fixed shape of an old-format (TS 4.x/5.0) TOF1 property record, whose
/// fields sit at constant byte offsets from the record's lead byte. Validated
/// against the content-exact Rosetta XML twin (see [binaryPropertyRecords]);
/// catalogued as an enum because a wrong offset silently misreads every value.
enum _PropRecordField {
  /// Byte 0: the record lead — one of [_propRecordLeads]. Byte 1 is a flags byte
  /// (`0x00`/`0x04` observed; not yet modeled).
  lead(0),

  /// Bytes 2..5: a `u32` that is zero in a valid record (a framing guard).
  zeroA(2),

  /// Bytes 6..9: the record `kind` code, a shape classifier and not a byte size
  /// — `Bool`/`Num`/`Str` all read `6` when valued despite 1/8/4-byte values.
  /// Observed across the twins: `2` empty list, `4` bare (no stored value), `6`
  /// scalar value present, `14` a special string form; `36`/`66` are structured
  /// `Status`/`ReportText`/`CustomResults` descriptor records, out of scope for
  /// the leaf decoder (see tool/binary_record_map.dart).
  kind(6),

  /// Bytes 10..13: a second always-zero `u32` framing guard.
  zeroB(10),

  /// Bytes 14..17: the `u32` pool index of the record's type name
  /// (`Bool`/`Num`/`Str`/`Path`/`Expr`/a container type).
  typeNameIndex(14),

  /// Bytes 18..21: the `u32` pool index of the property name.
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

/// The type names observed on real leaf property records across the corpus.
/// Requiring the decoded type name to be one of these rejects newer-layout
/// binaries whose record bytes are not pool indices: there a coincidental `0x40`
/// lead with two zero words passes the framing test while its "type index"
/// resolves to an arbitrary pool string (three corpus files resolved identical
/// record offsets to different type names). With this check those files emit 0
/// records while the validated oracle keeps its 37/37.
const _propLeafTypeNames = {'Bool', 'Num', 'Str', 'Path', 'Expr', 'Obj', 'Objs'};

/// The [_PropRecordField.kind] at/above which a record carries an inline scalar
/// value (`6`); below it (`4` bare, `2` empty list) there is no stored value.
const _propScalarKind = 6;

/// A decoded old-format TOF1 property record: a leaf `name = value` pair with
/// its TestStand type name, read by the fixed [_PropRecordField] grammar and
/// resolved against the ordered NUL string pool.
///
/// The value is a [bool] (`Bool`), a [double] (`Num`), a [String] (`Str`/`Path`/
/// `Expr`, resolved from the pool), or `null` for a bare ([_PropRecordField.kind]
/// `4`) or container record with no inline value. Where [binaryScalarDoubles]
/// infers numeric slots from clean bit patterns, this reads the record's
/// declared type, so it recovers non-round doubles too (TestStand's `Priority`
/// default `2953567917`).
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

  /// The record's lead byte, one of [_propRecordLeads] (`0x40`/`0x44`; which of
  /// the two a record carries is not yet decoded).
  final int lead;

  /// The record's flags byte (byte 1; `0x00`/`0x04` observed, bit meanings not
  /// yet decoded).
  final int flagsByte;

  /// The record's kind code ([_PropRecordField.kind]): a shape classifier, not a
  /// byte size — `2` empty list, `4` bare (no stored value), `6` scalar value
  /// present, `14` special string form. `>= 6` ([_propScalarKind]) is what makes
  /// [value] decodable.
  final int kind;
}

/// The ordered NUL-terminated string pool of a binary TOF1 body: the string
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

/// The leaf property records an old-format (TS 4.x/5.0) binary TOF1 file embeds
/// — each `name = value` pair with its declared TestStand type, decoded by the
/// fixed [_PropRecordField] grammar.
///
/// Every valued record decoded from `OutputVoltage_BIN.seq` whose (unambiguous)
/// name resolves in `OutputVoltage_XML.seq` carries the twin's value —
/// `BatchSync = 1`, `FailureAction = 2`, `Priority = 2953567917`,
/// `RecordResults = true`, string expressions like `EPNameExpr`.
///
/// A leaf-record scan, not a tree parse: it walks the record region emitting
/// every record matching the grammar's shape (a [_propRecordLeads] lead, two
/// zero framing guards, a leaf-range [_PropRecordField.kind], and
/// pool-resolvable type/name indices), skipping unrecognized bytes. The
/// container nesting is not yet decoded, so records are returned flat in file
/// order and duplicate names at different tree positions are indistinguishable.
/// Returns `[]` when [seqBytes] is not an inflatable binary file or does not
/// frame.
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

/// Upper bound on the words read for one declaration path — an unbounded walk
/// crosses record boundaries (every zero word reads as a separator), letting
/// unrelated trailing words complete a match.
///
/// The record region holds a second record shape besides the leaf property
/// record: a path/object declaration. It shares the `0x40`/`0x44` lead but
/// carries a non-zero word at [_PropRecordField.zeroA]'s offset — where a leaf
/// record has its framing zero, a path record has the first pool index of the
/// object's location path. The path is a run of `u32` pool-index words (`0`
/// separates), naming the containers from the file root down to the object:
/// `[] / MainSequence / Objs / Seq / [0]` declares the sequence `MainSequence`
/// living at `…/Objs/Seq/[0]`. Element `[1]` is the object's own name; the
/// structural tokens (`Objs`, `Seq`, `[i]`, `Data`, …) spell the path.
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

/// Whether a declaration [path] is a sequence declaration in the validated root
/// shape `[] / <name> / Objs / Seq / [i]`: the array-root token first, the
/// sequence name at element 1, and `Objs / Seq / [i]` at elements 2-4.
///
/// The exact positions matter: paths shaped `ResultList / <x> / Objs / Seq / [i]`
/// (result containers) and `<class> / Calls / Objs / Seq / [i]` (.NET call
/// containers) match a floating `Objs/Seq/[i]` window without being sequence
/// declarations — a floating-window matcher emitted structural tokens as
/// sequence names on 47/294 corpus binaries. With the root shape required, a
/// corpus sweep emits zero structural tokens (86/294 binaries declare sequences
/// in this shape; the rest use layouts not yet decoded).
bool _isSequenceDeclaration(List<String> path) =>
    path.length >= 5 && path[0] == '[]' && path[2] == 'Objs' && path[3] == 'Seq' && path[4].startsWith('[');

/// The sequence names of a binary TOF1 file, recovered from the object-path
/// declarations in the validated root shape (see [_isSequenceDeclaration]).
///
/// Validated two ways: on the six Rosetta binary twins this yields the sequence
/// list their XML twins parse to (`[MainSequence]`; only the OutputVoltage pair
/// is content-exact — the others are same-sequence re-saves), and a whole-corpus
/// sweep emits zero structural-token false positives. Files whose sequences are
/// declared in a not-yet-decoded layout return `[]`. De-duplicated, first-seen
/// order.
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
/// The stamp is the file's typedef `timestamp` attribute, varying per file (on
/// the OutputVoltage oracle 0x6259ecd3 == 1650060499, the XML twin's
/// `timestamp='1650060499'`).
const _typeStampMin = 0x386D4380;
const _typeStampMax = 0x83AA7E80;

/// Type names are identifier-like tokens; this rejects coincidental matches on
/// newer-layout files whose candidate name word resolves to arbitrary text.
final _typeNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_.\- ]*$');

/// Byte geometry of a type record's fixed head, in record-region words:
/// `[u32 nameIdx][u32 ?][u32 timestamp][version-string refs ...]`.
/// TODO: word 1 (offset `_u32Bytes`) is not yet decoded.
const _typeStampOffset = 2 * _u32Bytes; // the save timestamp is word 2

/// A type record carries the XML twin's version-attribute triple —
/// `typeversion` / `typelastmodversion` / `typeminprodversion` — as three
/// consecutive pool references. Two record generations place it differently:
/// old-layout records (TS 4.x/5.0-era) follow the stamp immediately (triple at
/// word 3), newer records carry one more pool-ref word before it (triple at word
/// 4; that word resolves to e.g. `SequenceFileData` — TODO: not yet decoded).
/// The consecutive-triple shape is what separates a real record: accepting any 2
/// version refs in words 3..8 fabricated `Objs`/enum-member names on one corpus
/// file.
const _typeVersionTripleStarts = [3 * _u32Bytes, 4 * _u32Bytes];
const _typeVersionTripleWords = 3;

/// Minimum bytes a type record needs: the 3-word head plus the word-3
/// (old-layout) version triple. The word-4 variant is bounds-checked where
/// it is probed.
const _typeRecordMinBytes = (3 + _typeVersionTripleWords) * _u32Bytes;

/// The type names defined by a binary TOF1 file. A type record opens
/// `[u32 nameIdx][u32 ?][u32 timestamp]` followed by the consecutive
/// version-string triple (see [_typeVersionTripleStarts]) — the fields the XML
/// encoding stores as `<TypeName timestamp='...' typeversion='21.0.0.49156'
/// typelastmodversion='...' typeminprodversion='...'>`. Detection keys on that
/// shape, not on any constant. De-duplicated, in file order; `[]` when
/// [seqBytes] is not an inflatable binary file or does not frame.
///
/// The content-exact OutputVoltage twin yields 25 names, each appearing in the
/// twin as a typedef element or a `typename`/`xsi:type` reference. Whole-corpus
/// sweep: 275/297 binaries yield names, with zero structural-token fabrications
/// beyond three `Obj` counterexamples (a fully-framed record window named `Obj`
/// in one HIL project — real record vs over-detected head undecided; see
/// `binary_sweep_test.dart`). The placed-step `typename` binds through the step
/// reference's second word, the 1-based index into this table (see
/// [BinaryStepRef]), so the table's order is load-bearing: a false or missed
/// record shifts every later step's binding.
///
/// Every rosetta binary decodes every typedef body end to end; ~2.2 MB across
/// 1,042 corpus bodies still bail.
/// TODO(binary decode — typedef bodies), remaining:
///  * extdata block payloads (STRUCT packing/type/buffer words, member-name
///    slots): the blocks are walked — type-level opener
///    `[0][extCount]{blocks}[subCount]`, per-field 0x100-flagged tails — but
///    their contents are not surfaced;
///  * bodies whose 0x4-flagged fields store a zero attr word (`LowExpr`
///    `[0][0]`): no reliable arity signal. Counting bit 0x4 in the attr floor is
///    refuted unconditionally (4 rosetta bodies break) and per record-prefix
///    layout (the 0x76 exemplars regress);
///  * framed valued scalars of a non-`Expression` scalar type (an enum
///    `ModelType` = `'Sequential'`): the grammar covers only the `Expression`
///    case (1 corpus record);
///  * the intrinsic-type id → name map ([BinaryTypeField.intrinsicTypeId]:
///    2 = StepTypeSubstepsArray measured);
///  * locals/parameters: thin twin oracle (rosetta declares only the implicit
///    `ResultList`).
List<String> binaryTypeNames(Uint8List seqBytes) => _withLayout(seqBytes, _typeNamesFromBody);

/// The known field-flag bits (word 1 of a typedef field record; see
/// [BinaryTypeField] and the body parser). [_fieldKnownFlagBits] is derived from
/// these so the mask cannot drift from the individual bit checks. Bits
/// 0x4/0x8/0x20/0x40 advertise which flag attributes the field stores; their
/// arity is not reliable (see [_attrTail]), so they stay grouped.
const _fieldHasValueBit = 0x2; // a stored value follows
const _fieldAttrBits = 0x4 | 0x8 | 0x20 | 0x40; // flag-attribute markers
const _fieldFramedBit = 0x80; // delimiter-framed form
const _fieldHasExtDataBit = 0x100; // extdata (marshalling) tail
const _fieldHasFormatBit = 0x200; // display-format string after the value

/// Bit 0x800: the `Num` field carries a numeric-representation word right after
/// the name — the XML `representation` attribute's code — and its stored value
/// (bit 0x2) is an i64, not the default f64. Measured on the oracle:
/// `NI_MeasurementParameter`'s typedef stores `ID` as `[0x800][0][Num][ID][2][0]`
/// and `Dimension` as `[…][Dimension][3][0]` where the twin materializes
/// `representation='Int64'`/`'UInt64'`, and the placed step's enum members store
/// `AC_VOLTS` as `[0x802][0][Num][AC_VOLTS][2][i64 1][0]` — the twin's
/// `<value representation='Int64'>1</value>`. Codes are surfaced verbatim
/// ([BinaryTypeField.numericRepresentation]); see [BinaryNumericRepresentation]
/// for the twin-evidenced code↔name pairs.
const _fieldHasNumericRepBit = 0x800;

/// Every bit the field grammar recognizes; a field carrying any other bit is a
/// shape the grammar does not cover and bails.
const _fieldKnownFlagBits =
    _fieldHasValueBit |
    _fieldAttrBits |
    _fieldFramedBit |
    _fieldHasExtDataBit |
    _fieldHasFormatBit |
    _fieldHasNumericRepBit;

/// The numeric-representation codes with twin evidence (see
/// [_fieldHasNumericRepBit]): each pairs a binary code observed in the oracle
/// with the `representation` attribute its content-exact XML twin writes for the
/// same field. Codes without such evidence are surfaced raw, never named.
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

  /// Whether [code] is a twin-evidenced integer representation — the codes whose
  /// stored values are i64, the trigger for the i64 value read.
  static bool isInteger(int code) => of(code) != null;
}

/// Cap on a typedef's subprop count (the largest real corpus body carries 49
/// fields — TEInf).
const _typeMaxFields = 200;

/// Cap on decoded populated-array elements; real corpus arrays are far smaller,
/// so this only bounds a hostile count.
const _maxArrayElements = 4096;

/// The value classes whose serialized tail the field grammar reads directly. A
/// class outside this set opens a nested object declaration instead, whose child
/// count is found by scanning past the attr words.
const _tailedValueClasses = {
  SeqValueClass.boolean,
  SeqValueClass.string,
  SeqValueClass.number,
  SeqValueClass.numbers,
  SeqValueClass.strings,
  SeqValueClass.objects,
  SeqValueClass.expression,
  SeqValueClass.path,
  SeqValueClass.reference,
};

/// The value classes an unvalued field may carry — it reads its class default
/// (`false` / `''` / `0`), or inherits when inside an instance.
const _unvaluedScalarClasses = {
  SeqValueClass.boolean,
  SeqValueClass.string,
  SeqValueClass.number,
  SeqValueClass.reference,
};

/// The array classes serialized as a `lbound ubound` bound-token pair.
const _boundedArrayClasses = {SeqValueClass.numbers, SeqValueClass.strings, SeqValueClass.objects};

/// Parses a typedef body (`[0][subpropCount][field…]`, starting right after the
/// head's record delimiter) into its field list, or null when any field uses a
/// shape the grammar does not yet cover — all-or-nothing, so an undecoded
/// construct cannot fabricate a partial body. See [BinaryTypeField] for the
/// field grammar and its twin validation. [table] is the file's complete type
/// table (both passes done): framed default-instance references index it
/// 1-based, the same convention as step references, and may point forward.
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
/// element-type spec the decode accepted a structural skip for, as (field name,
/// spec start offset within the inflated body, byte length) — ground-truth sites
/// for probing the spec's internal grammar.
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

/// The fixed byte count between a type-record body's final field terminator and
/// the next record's head (its className word): 17 on every cleanly-decoded
/// rosetta body. Used only to compute the body-end boundary that constrains
/// element-type spec skips — a wrong value there makes skips bail, never
/// fabricate. TODO: the preamble's contents are not yet decoded.
const _typeRecordPreambleBytes = 17;

/// The field names that are `Expression`-typed across every record generation
/// and file — the display-format expression properties every step type declares.
/// Their framed valued-scalar sites anchor [deriveTypeIndexBase]: whatever their
/// `X` resolves to must be the table's `Expression` record, so the base is
/// `X - 1 - exprIndex`. 219 aligned corpus files confirm `X - 1 == exprIndex`
/// (base 0); the misaligned cohort resolves them to a wrong record until
/// rebased.
const _typeIndexAnchorFields = {'DescriptionFormat', 'DefaultNameFormat'};

/// Recovers the per-file type-index base (see [_TypeBodyParser.typeIndexBase]).
///
/// A framed 1-based reference `X` names `table[X - 1 - base]`. The recovered
/// head [table] can differ from TestStand's type-index space by a constant
/// per-file offset two ways: the true space reserves engine-intrinsic types
/// before the first serialized record (`StepTypeSubstepsArray` ahead of
/// `Expression`), how many varying by record generation — a positive base; or
/// the head scan over-detects a record before `Expression` (an enum/data record
/// matching the type-record shape) — a negative base.
///
/// The base comes from the cross-format invariant that [_typeIndexAnchorFields]
/// are `Expression`-typed: at each of their framed valued-scalar sites the
/// candidates are `{X - 1 - i : table[i] == 'Expression'}`, and the file's base
/// is the value common to every anchor site (nearest zero when several agree).
/// Returns 0 — never a guess — when no anchor site references the table (the
/// aligned majority carry X == 0, the implicit form; old-generation files have
/// no framed table refs) or when the anchors disagree.
int deriveTypeIndexBase(ByteData view, List<String> pool, int recordRegionLength, List<BinaryTypeRecord> table) {
  final exprIdx = <int>[];
  for (var i = 0; i < table.length; i++) {
    if (table[i].name == 'Expression') exprIdx.add(i);
  }
  if (exprIdx.isEmpty) return 0;
  const framedValued = 0x82; // 0x80 framed | 0x2 valued
  Set<int>? common;
  // How many framed anchor sites (X >= 1) constrained the base: a nonzero base
  // standing on a single site is uncorroborated (one coincidentally
  // anchor-shaped run, or an ambiguous candidate set reduced by nearest-zero)
  // and would mis-resolve every framed type reference.
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
    // Each Expression record index yields one base under which this X resolves
    // to it (in range by construction: X - 1 - (X - 1 - e) == e).
    final cands = {for (final e in exprIdx) x - 1 - e};
    common = common == null ? cands : common.intersection(cands);
    if (common.isEmpty) return 0;
    anchorSites++;
  }
  if (common == null) return 0;
  final base = common.reduce((a, b) => a.abs() < b.abs() ? a : b);
  // A nonzero base needs at least two agreeing anchor sites before it rebases
  // the whole table; base 0 is the aligned default.
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
  /// `seq_binary_write.dart`). The shared no-op sink ([_DecodeSink.none]) on
  /// plain decode runs; under a recording sink every committed parse records the
  /// typed ops that re-emit its bytes, and every failed trial rolls its ops
  /// back. The sink never influences parse decisions.
  _DecodeSink ops = _DecodeSink.none;

  /// How many engine-intrinsic types precede the first serialized type record in
  /// this file's type-index space, so a framed 1-based reference `X` names
  /// [table]`[X - 1 - typeIndexBase]` (see [deriveTypeIndexBase] and
  /// [_tableRef]). Zero for the aligned majority; nonzero for files whose record
  /// generation reserves leading intrinsic types (`StepTypeSubstepsArray` before
  /// `Expression`). The X == 0 (implicit) and X == 1 !valued (custom instance)
  /// forms are generation-level sentinels and are not rebased.
  final int typeIndexBase;

  /// Whether [x] is a framed reference that resolves inside [table] under
  /// the file's [typeIndexBase].
  bool _validTableX(int x) {
    final i = x - 1 - typeIndexBase;
    return i >= 0 && i < table.length;
  }

  /// The type record a framed 1-based reference [x] names, rebased by
  /// [typeIndexBase]. Callers check [_validTableX] first.
  BinaryTypeRecord _tableRef(int x) => table[x - 1 - typeIndexBase];

  /// Where this body must end — the next type record's head start minus its
  /// preamble ([_typeRecordPreambleBytes]) — or null for the last record. An
  /// element-type spec skip is accepted only when the remaining fields land
  /// exactly here; otherwise a trial skip can re-anchor inside the spec (its
  /// interior parses as field-alikes) and fabricate a body, as measured on
  /// TEInf/DotNetStepAdditions.
  final int? bodyEndBoundary;

  int _u32(int at) => view.getUint32(at, Endian.little);
  String? _tok(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;

  /// Identifier shape a pool-index-0 class token must have (see [_clsTok]).
  static final _rootClassPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,39}$');

  /// Resolves a class-slot word: like [_tok], but index 0 additionally resolves
  /// to `pool[0]`, the file's root token. The TS 4.x-era record generation puts
  /// `Obj` first in the pool (pool[0] over 297 binaries: 221× `SequenceFileData`
  /// [newer gen], 47× `Obj`, 19× `SemiconductorModule`, 4× `StepType`, 3×
  /// `Enum`, 3 other) and its `Obj`-classed fields reference it by index 0 — the
  /// shape `[flags][0][0][name]`. Only an identifier-shaped root resolves
  /// ([_rootClassPattern]); word 0 outside a class slot keeps its framing-zero
  /// meaning.
  String? _clsTok(int word) {
    if (word != 0) return _tok(word);
    if (pool.isEmpty) return null;
    final root = pool[0];
    return _rootClassPattern.hasMatch(root) ? root : null;
  }

  /// Whether [token] is an array-bound token: `'[]'`, `'[<digits>]'`, or a
  /// multi-dimensional chain `'[<digits>][<digits>]…'` (the XML twin writes
  /// these verbatim as lbound/ubound — corpus arrays store 2-D locals as
  /// `lbound='[0][0]' ubound='[30][50]'`).
  static final _boundPattern = RegExp(r'^(\[\d*\])+$');
  static bool _isBoundToken(String? token) => token != null && _boundPattern.hasMatch(token);

  /// Whether any element-type spec was walked during the current [parse] — arms
  /// the body-end boundary check so a walker misparse cannot fabricate a body.
  bool _usedSpec = false;

  /// Current field-nesting depth. Bounded by [_maxFieldDepth] so a hostile body
  /// of self-nesting declarations (each descriptor node costs ~20 bytes and one
  /// recursion level) bails instead of overflowing the stack — [parse] is total
  /// over arbitrary input.
  int _depth = 0;

  /// Whether the walk is inside an instance's children (framed X >= 1). There an
  /// unvalued field means the value is inherited from the type's default
  /// (Action's TS stores PassAct with flags 0x60 and no value — a flags-only
  /// override of TEInf's default 'Next'), so class defaults are not
  /// materialized: [BinaryTypeField.value] stays null and consumers treat it as
  /// not-overridden.
  bool _inInstance = false;

  /// Whether a declaration-level populated step array whose full element run
  /// does not frame may be decoded as a partial prefix (the leading steps that
  /// do frame, remainder left undecoded — see [_stepElementPrefix]). True only
  /// on the sequence-record-walk parser, where the array is a Main/Setup/Cleanup
  /// group of placed steps; false for typedef bodies and instances, which keep
  /// strict all-or-nothing.
  bool _partialStepArraysOk = false;

  /// Set by [_populatedArrayTail] when it returns a partial step prefix (see
  /// [_partialStepArraysOk]); read by [_fieldParse] right after the call to mark
  /// [BinaryTypeField.partialArray]. Reset at the start of every
  /// [_populatedArrayTail].
  bool _lastArrayPartial = false;

  /// Numeric-representation codes by field name of the instance type whose
  /// children are being parsed, from its typedef's 0x800-flagged `Num` fields
  /// ([_reprsOf]). Inside such an instance a plain valued `[0x2]` Num inherits
  /// its representation, so its stored value is an i64 when the typedef declares
  /// an integer representation: on the oracle the placed step's
  /// `NI_MeasurementParameter` element stores `ID` as `[0x2][0][Num][ID][i64 7]`
  /// (the twin's `<value representation='Int64'>7</value>`; an f64 read yields a
  /// denormal, not 7). Null outside instances and when the type stores no
  /// integer-represented Nums. Slots this context does not reach (element types
  /// riding an unresolved elemproto) are covered by the subnormal-signature i64
  /// read at the value site — see the plain `Num` case in [_fieldParse].
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

  /// Consumes a field's attr-word tail: zero or more nonzero words — the field's
  /// flag attributes, `flagsforinstances`/`instanceoverrideflags`/`valueflags`
  /// when present (TEInf.Links stores its twin's 71303168/72286233/71303168
  /// triple; the ubiquitous 0x4d0018 is `instanceoverrideflags='5046296'`) —
  /// then the 0 terminator. Returns the offset after the terminator, or null
  /// when no terminator arrives within the cap.
  ///
  /// [minWords] is the floor of zero-valued attr slots the until-zero rule would
  /// otherwise mistake for the terminator: one stored attr word per set bit of
  /// 0x8/0x20/0x40 (`ReportText` flags 0x20 stores `[0][0]`, a substep's `TS`
  /// flags 0x60 two, `DescriptionFormat` flags 0xEE three). It is a minimum, not
  /// an exact arity — rosetta bodies store more words than the bits promise
  /// (`Substep.TS.Result` stores two 0x400000 where its bits promise one) — so
  /// past it the until-zero rule still applies.
  ///
  /// [attrsOut], when given, collects each consumed attr word for
  /// [BinaryTypeField.attrWords] and emits it as a model word; without a
  /// collector (structural probe walks whose ops are rolled back) the words stay
  /// retained structure.
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
      // Bits 0x8000/0x800 accompany some element-type specs (0x8001/0x8801/
      // 0x801) but are unreliable in both directions (Substep.TS's
      // CustomResults spec follows a plain 0x1; Action.Substeps carries
      // 0x8001800 with no spec at all) — specs are detected by their DELIM-led
      // frame instead (see [_fields]).
    }
    return _blockBail(m);
  }

  /// Walks a full element-type spec structurally and returns the offset after
  /// it, or null when the bytes don't frame as one. Measured grammar (constant
  /// across the rosetta corpus):
  /// `[00 pad?][DELIM][X][DELIM][0x20000?][count]{items}[attrs…][0]` where X is
  /// the array's element type as a 1-based type-table reference
  /// (CustomResults→5=NI_CustomResult, Params→12=DotNetParameter,
  /// Calls→14=DotNetCall), 0x20000 tags the compact form, and the items reuse
  /// the standard field grammar — descriptor nodes ([_field]'s
  /// `[0][0][DELIM][name][count]` shape), plain fields, and nested spec'd arrays
  /// (recursion). Only the extent is walked: the content has no twin oracle, as
  /// XML writes just `<value lbound='0' ubound='-1'/>`. The walk is a probe for
  /// the writer — its interior parses capture no lasting write ops, and callers
  /// copy the whole extent verbatim.
  int? _elementSpec(int at) {
    final m = ops.mark();
    final end = _elementSpecWalk(at);
    ops.rollback(m);
    return end;
  }

  int? _elementSpecWalk(int at) {
    var p = at;
    if (p >= recordRegionLength) return null;
    // A single realignment pad byte precedes the frame after non-Objs arrays
    // (Objs arrays already consume their own pad).
    if (view.getUint8(p) == 0) p++;
    // The frame is variable-length (optional X word, optional 0x20000 tag), so
    // each word is bounds-checked at its own read.
    if (!_canRead(p) || _u32(p) != _recordDelimiter) return null;
    p += _u32Bytes;
    // X = the element type as a 1-based table reference. When the next word is
    // already the closing delimiter, X is omitted — a self/inherit reference
    // (Substep.TS's CustomResults spec reads [DELIM][DELIM][count]).
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
    // A scalar-classed element prototype stores its value token before the
    // 0x20000 tag (FCParameter.ArrayDimensionsSize's elemproto:
    // [DELIM][X=Expression][DELIM]['1024'][0x20000][0][0] — the XML twin shape
    // writes `<elemproto>…<value>1024</value>`). The token is accepted only when
    // the tag follows, keeping the forms disjoint.
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
    // (PythonCall.Parameters' type spec) or with an explicit X — in both the
    // element type is fully named, so no descriptor items follow
    // (NI_Measurement's Parameters spec:
    // `[DELIM][X=NI_MeasurementParameter][DELIM][0][0]`). An untagged X-less
    // [DELIM][DELIM][0][0][0] is the short reference spec ([_refSpec]).
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

  /// The element count a populated array's bound-token pair declares — the
  /// product over dimensions of `ubound − lbound + 1` (row-major storage;
  /// multi-dimensional corpus locals measure `∏(ubᵢ−lbᵢ+1)` inline elements).
  /// Null on empty/malformed bounds, dimension-count mismatch, or an inverted
  /// range.
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

  /// Decodes the leading placed-step elements of a populated array whose full
  /// element run does not frame — the record-walk group-array partial mode (see
  /// [_partialStepArraysOk]). Decodes step elements one at a time until one
  /// fails (or the declared [count] is reached), returning the decoded prefix
  /// and the offset after the last one, or null when not even the first element
  /// frames as a step. Every element passes the same per-element checks the full
  /// run uses (`Step` token, resolvable type, `ID#:`-anchored TS via
  /// [_stepElement]); the elements past the prefix stay an explicit undecoded
  /// span. Scoped to step arrays: a first element of any other class returns
  /// null, so a non-step declaration array never partial-decodes.
  (List<BinaryTypeField>, int)? _stepElementPrefix(int at, int count) {
    final elements = <BinaryTypeField>[];
    var p = at;
    for (var i = 0; i < count; i++) {
      final m = ops.mark();
      final element = _arrayElement(p);
      if (element == null || element.$1.valueClass != SeqValueClass.step) {
        ops.rollback(m);
        break;
      }
      elements.add(element.$1);
      p = element.$2;
    }
    if (elements.isEmpty) return null;
    return (elements, p);
  }

  /// Decodes a populated `Objs` array's element tail, starting right after the
  /// bound tokens; the element count is `ubound − lbound + 1`. Two context-split
  /// tail layouts, both measured on the oracle and validated value-for-value
  /// against the content-exact twin: declaration context (a typedef/object field
  /// — `Measurement.Parameters '[0]' '[10]'`, 11 blocks) is
  /// `[attrs…][0][one 0x00 pad]{elements}`, the standard array tail then the
  /// elements chained with no closing terminator; instance context (a field
  /// inside an element/override instance — `EnumDefinition '[0]' '[1]'`, 2 plain
  /// Num members) is `[one 0x00 pad]{elements}[attrs…][0]`.
  ///
  /// Count- and terminator-checked, all-or-nothing: any element that does not
  /// frame returns null and the array falls back to the structural blob walk.
  (List<BinaryTypeField>, int)? _populatedArrayTail(int at, String lbound, String ubound, {List<int>? attrsOut}) {
    _lastArrayPartial = false;
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (_inInstance) {
      // Instance layout: `[one 0x00 pad][proto?]{elements}[attrs…][0]`
      // (EnumDefinition; ArrayDimensionsSize carries a leading proto block
      // before its element). Some instance arrays instead use the declaration
      // layout with a leading attr tail (a substep SData's `Parms`/`Calls`:
      // `[attrs…][0][pad][proto?]{elements}`) — tried second; the element count,
      // the terminators, and the body-end boundary arbitrate.
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
    // Declaration layout: `[attrs…][0][pad][proto?]{elements}`.
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
      // Element decode is boundary-sensitive like a spec walk — arm the body-end
      // overrun check. Some instance-context arrays do trail one closing zero
      // (`ArrayDimensionsSize`: `[attrs][0][pad][proto]{element}[0]`), but no
      // local rule separates them from a proto'd run followed by an unrelated
      // zero-led word (consuming it unconditionally misparses
      // NI_Measurement's typedef body), so those parents stay bailing.
      _usedSpec = true;
      return (elements.$1, elements.$2);
    }
    // Partial step-array decode (record-walk group arrays only): when no proto
    // candidate frames the full element run, decode the leading step elements
    // that do and surface them as a partial array; the remaining bytes stay an
    // explicit undecoded span. The committed attr-tail/pad ops above are reused.
    if (_partialStepArraysOk && !_inInstance) {
      for (final start in _protoSpecEnds(tail + 1)) {
        final m = ops.mark();
        ops.copy(tail + 1, start); // proto block: extent walked, undecoded
        final prefix = _stepElementPrefix(start, count);
        if (prefix != null) {
          _usedSpec = true;
          _lastArrayPartial = true;
          return prefix;
        }
        ops.rollback(m);
      }
    }
    ops.rollback(mDecl);
    if (attrsDeclMark != null) attrsOut!.length = attrsDeclMark;
    return null;
  }

  /// The candidate offsets an element run may start at, given an optional
  /// leading element-proto block at [at]: after a six-word proto
  /// ([_protoSpec]), after the shorter five-word valued variant
  /// `[00 pad?][DELIM][DELIM][value][0][0]` (no attr slot — measured on
  /// instance-context `ArrayDimensionsSize`, value `'1024'`, whose XML twin
  /// writes `<elemproto>…<value>1024</value></elemproto>`), or [at] itself (no
  /// proto). The caller tries each in order; the count-checked element run and
  /// closing terminator arbitrate, so a wrong candidate cannot decode.
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

  /// Decodes a populated plain scalar array's element run, starting right after
  /// the bound tokens: `{count × f64}[attr words…][0]` — the elements are stored
  /// inline back-to-back (no per-element framing), then the standard attr tail
  /// closes the field. Elements surface as anonymous `Num` children (the XML
  /// twin writes each as an unnamed `<value>`), formatted with the same f64 text
  /// rule as scalar `Num` fields. Returns null when the run + tail do not frame.
  (List<BinaryTypeField>, int)? _scalarArrayTail(int at, String lbound, String ubound, {List<int>? attrsOut}) {
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (at + count * _f64Bytes > recordRegionLength) return null;
    final m = ops.mark();
    final elements = <BinaryTypeField>[];
    var p = at;
    for (var i = 0; i < count; i++, p += _f64Bytes) {
      final value = view.getFloat64(p, Endian.little);
      // Reject NaN/Inf and subnormals; one bad element fails the whole run, so a
      // mis-framed Nums field (whose integer/handle words collapse into the
      // denormal range) falls back to the bounds-only undecoded read.
      if (!value.isFinite || (value != 0 && value.abs() < _smallestNormalF64)) {
        return _blockBail(m);
      }
      ops.f64(p, value);
      final text = value == value.truncateToDouble() && value.abs() < 1e15 ? '${value.truncate()}' : '$value';
      elements.add(BinaryTypeField('', className: SeqValueClass.number.wire, value: text));
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

  /// Walks an empty array's trailing element-type block —
  /// `[classRef][DELIM][0][attr words…][0]` — returning the element class/type
  /// name and the offset after the block, or null when the bytes do not frame
  /// (see the call site for the disjointness argument).
  (String, int)? _elemProtoTail(int at) {
    if (at + 3 * _u32Bytes > recordRegionLength) return null;
    final cls = _tok(_u32(at));
    if (cls == null) return null;
    if (_u32(at + _u32Bytes) != _recordDelimiter) return null;
    if (_u32(at + 2 * _u32Bytes) != 0) return null;
    // Probe for the writer: the block is surfaced as an undecoded spec blob, so
    // the caller copies its extent — no lasting attr-tail ops.
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

  /// Walks an element-proto block — the binary form of a scalar-classed XML
  /// `<elemproto>` (a populated or sized-empty array's element prototype): a
  /// fixed six-word block `[00 pad?][DELIM][DELIM][value|0][0][attr|0][0]`,
  /// measured as `[D][D][0][0][0x80][0]` on the oracle's `Calls` (DotNetCall
  /// elements) and the corpus `Parms` (FCParameter elements) and as
  /// `[D][D]['1024'][0][0][0]` on the corpus `ArrayDimensionsSize`, whose XML
  /// twin shape writes `<elemproto>…<value>1024</value></elemproto>`. A proto
  /// with object content frames as a full [_elementSpec] instead. Only the
  /// extent is walked; the value/attr slots ride the spec blob undecoded.
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
    // An all-zero block would also read as other spec shapes; require some
    // content (a value or an attr word) so the forms stay disjoint.
    if (value == 0 && _u32(p + 4 * _u32Bytes) == 0) return null;
    return p + 6 * _u32Bytes;
  }

  /// One populated-array element: an instance block
  /// `[pad 0?][DELIM][X][DELIM][count]{fields}[attrs…][0]` — X is the element's
  /// type as a 1-based table reference and the element name is not serialized
  /// (the twin writes `name=''`) — or, for scalar members (EnumDefinition's Num
  /// members), a plain field carrying its own name.
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
    // Named step element (a `Substeps` array's substep, or a sequence group
    // array's placed step). A `Step`-led element is a step, so when it does not
    // decode the element fails rather than falling through to the compact field
    // form, which would misread its first two words as `[name][value]` and
    // fabricate a field named `Step` (seen on a Setup array whose Action step's
    // TS bailed).
    if (!_canRead(at)) return null;
    if (_tok(_u32(at)) == _stepToken) return _stepElement(at);
    // Plain-field element (its own [flags][0][cls][name] head).
    final outer = _inInstance;
    _inInstance = true;
    final field = _field(at);
    _inInstance = outer;
    return field;
  }

  /// A named step element of a populated `Substeps` array:
  /// `['Step' clsRef][X][nameRef][childCount]{fields}` — the binary form of the
  /// XML `<Step typename='Substep' name='OnNewStep'>` substep (X measured
  /// X=10→`Substep` on the oracle's NI_Measurement and X=20→`Substep` on the
  /// corpus NI_Wait/MessagePopup families; the corpus XML `LoopForever.seq`
  /// materializes the same substeps with this structure). Children serialize as
  /// an override subset in the standard field grammar (the `TS` descriptor node
  /// with `Id`/`SData`…), compared by name against a materialized twin. Disjoint
  /// from every [_field] form: a field's second word is 0 (flags forms) or a
  /// stored value (compact), never a type-table index in `1..table.length` with
  /// a resolvable class token `Step` before it.
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
    // The standard closing attr tail, like [_elementBlock] (`[0x80][0]` after
    // each substep's fields).
    final attrs = <int>[];
    final after = _attrTail(children.$2, attrsOut: attrs);
    if (after == null) return _blockBail(m);
    return (
      BinaryTypeField(
        name,
        className: SeqValueClass.step.wire,
        typeName: ref.name,
        children: children.$1,
        instanceOverrides: true,
        attrWords: attrs,
      ),
      after,
    );
  }

  /// The DELIM-led instance block of [_arrayElement], starting at its delimiter.
  /// Two twin-validated word-3 shapes:
  ///
  ///  * anonymous — `[DELIM][X][DELIM][count]{fields}[attrs…][0]`: X is the
  ///    element type as a 1-based table reference and the element name is not
  ///    serialized (the twin writes `name=''`) — the typedef-array form
  ///    (`Measurement.Parameters`). Children parse with the element type's
  ///    integer-representation map ([_numericReprContext]) in scope;
  ///  * named — `[DELIM][X][nameRef][count]{fields}[attrs…][0]`: the name is
  ///    serialized in the third slot and X is a pool reference to adapter module
  ///    data (the LabVIEW `Parms` elements store the adapter version string,
  ///    `'23.0.0.0'`), not a type reference — the element type lives in the
  ///    array's elemproto, so typeName/className stay null and there is no
  ///    serialized type to consult. The LabVIEW XML corpus materializes the same
  ///    elements as `<VIParameter name='sequence context'>` with the decoded
  ///    children (Label/ArgVal/Type/WireRequirement/…).
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
      // Expression-valued anonymous element — `[DELIM][X][DELIM][valueRef]
      // [attrs…][0]` where X resolves to the table's `Expression` record (the
      // same resolution the framed valued scalar requires): an expression-array
      // element (`DataSourceArray`), whose cross-format twin writes
      // `<ExprValue typename='Expression' name=''><value>…</value>`. Tried when
      // the next word is no plausible child count; the count form has
      // precedence.
      final word4At = p + _u32Bytes;
      if (ref.name == 'Expression' && _canRead(word4At) && _u32(word4At) > _typeMaxFields) {
        final value = _tok(_u32(word4At));
        if (value != null) {
          ops.poolRef(word4At, _u32(word4At));
          final attrs = <int>[];
          final after = _attrTail(word4At + _u32Bytes, attrsOut: attrs);
          if (after != null) {
            return (
              BinaryTypeField(
                '',
                className: SeqValueClass.expression.wire,
                typeName: 'Expression',
                value: value,
                attrWords: attrs,
              ),
              after,
            );
          }
        }
        return _blockBail(m);
      }
    } else {
      final named = _tok(word3);
      // The named form still requires X to resolve in the pool (the module-data
      // slot); a zero/unresolvable X does not frame.
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
        className: ref != null ? (ref.className ?? SeqValueClass.object.wire) : null,
        typeName: ref?.name,
        children: children.$1,
        instanceOverrides: true,
        attrWords: attrs,
      ),
      after,
    );
  }

  /// Walks [remaining] adapter-marshalling extdata blocks (the twin's
  /// `<extdata controllername='STRUCT'/'CLUST'/'DNSTRUCT'/'BLVCLUSTER'…>`
  /// elements). Each block is `[ctrlNameIdx][u16][string slot]` (10 bytes; the
  /// slot is a member-name pool ref, DELIM for none) or the STRUCT kind
  /// `[ctrlNameIdx][u16][20 opaque payload bytes]` (26 bytes:
  /// packing/type/buffer sizes, undecoded). The two sizes are disambiguated by
  /// trying the short form first and requiring the remaining blocks to parse.
  /// TODO: only the extent is walked; block content is not surfaced.
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

  /// A field's extdata tail (flag bit 0x100):
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

  /// Walks a short reference spec: `[00 pad?][DELIM][ref][0][0][0]` — the
  /// 0x800-signalled form, where the full spec's nested arrays reference an
  /// already-described element type instead of respelling it.
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

  /// Tooling aid: when [debugCollectSpecs] is on, every accepted element-type
  /// spec skip is recorded as (field name, spec start offset, byte length) —
  /// ground truth for the spec-content prober. Off by default so decode runs do
  /// not accumulate.
  static bool debugCollectSpecs = false;
  static final List<(String, int, int)> debugSpecSites = [];

  /// Tooling aid: when [debugCollectSpecs] is on, every accepted extdata block
  /// region is recorded as (start, end) byte offsets — the marshalling blocks
  /// whose extent is walked but whose payload contents are not surfaced (see
  /// [_extTail]). Feeds the byte-coverage accounting's structurally-skipped
  /// tier.
  static final List<(int, int)> debugExtSpans = [];

  /// Parses the leading fields of a sequence record's subprop list
  /// (`[Sequence][name][subpropCount]` then the subprops) — the scalar/Obj
  /// subprops (`Parameters`, `Locals`) preceding the `Main` group array. Walks
  /// fields until it reaches a group-array field ([groupNames]:
  /// Main/Setup/Cleanup, whose step-tree content is a separate decode), which
  /// bounds the leading region and confirms the record framed correctly; `[]`
  /// unless that boundary is reached within [max] fields, since an unbounded
  /// walk would fabricate names past the record. Sequence subprops serialize
  /// identically to typedef fields (twin-validated: valueflags match
  /// attribute-for-attribute), so the full field grammar is reused. Each field
  /// is returned with its end offset (exclusive) for byte-coverage accounting.
  List<(BinaryTypeField, int)> parseLeadingSubProps(int at, int max, Set<String> groupNames) {
    _usedSpec = false;
    _depth = 0;
    final fields = <(BinaryTypeField, int)>[];
    var cur = at;
    for (var i = 0; i < max; i++) {
      // Peek the field header `[flags][0][class][name]`: a group array
      // (`Objs`-classed, group-named) bounds the leading region. A populated one
      // does not parse as a plain field (its trailing bytes are step content,
      // not a terminator) while an empty one does, so the boundary comes from
      // the header, before parsing, either way.
      if (cur + 4 * _u32Bytes <= recordRegionLength) {
        final cls = _tok(_u32(cur + 2 * _u32Bytes));
        final nm = _tok(_u32(cur + 3 * _u32Bytes));
        if (cls == 'Objs' && nm != null && groupNames.contains(nm)) {
          return fields; // bounded by the group array — trust the run
        }
      }
      final field = _field(cur);
      // A parse failure here is the populated first group array (framed step
      // content): the leading run ends, return what decoded. The caller still
      // requires it to lead with Parameters/Locals.
      if (field == null) return fields;
      cur = field.$2;
      fields.add((field.$1, cur));
    }
    return fields;
  }

  /// Parses a single field at [at] — used for a step's data descriptor node,
  /// which the field grammar covers. Returns the field with its decoded children
  /// or null when the bytes do not frame.
  BinaryTypeField? parseFieldAt(int at) {
    _usedSpec = false;
    _depth = 0;
    final parsed = _field(at);
    if (parsed == null) return null;
    debugLastEndOffset = parsed.$2;
    return parsed.$1;
  }

  /// End offset (exclusive) of the byte span the most recent successful
  /// [parseStepTs] validated — the whole `TS` node on the full-node path, or the
  /// descriptor header plus the `Id` field on the fallback path. Null when the
  /// last call returned `[]`. For byte-coverage accounting.
  int? lastStepTsEnd;

  /// Decodes a step's `TS` subprops from the descriptor node at [at]
  /// (`[0][0][DELIM][TS][childCount][children…]`); `[]` unless the node is named
  /// `TS`.
  ///
  ///  * When the whole node decodes (measurement-type steps: Id +
  ///    CustomResults + AdditionalResultsHints), returns all its children.
  ///  * When a later child uses a shape not yet covered (Action/Python steps
  ///    carry an inline module + expression fields as child 2), the
  ///    all-or-nothing node parse fails, but child 1 is the step's unique `Id`
  ///    (`[flags][0][Str][Id]['ID#:…'][0]`), so it is extracted on its own. The
  ///    `ID#:` value prefix anchors it against a coincidental parse.
  List<BinaryTypeField> parseStepTs(int at) {
    lastStepTsEnd = null;
    // A `TS`-named descriptor node header, both framing zeros verified — the
    // Id-only fallback below re-emits them as grammar constants.
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
    // Fallback: child 1 (the Id) alone, after the 5-word descriptor header.
    final mId = ops.mark();
    final idField = parseFieldAt(at + 5 * _u32Bytes);
    if (idField != null &&
        idField.valueClass == SeqValueClass.string &&
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
      // Extdata-opener body (Error): `[0][extCount]{extdata blocks}
      // [subpropCount]{fields}` — the type-level marshalling blocks sit between
      // the opener and the field count.
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
      // Count-less body: the step-type typedefs that exist only in the binary
      // (NI_Measurement/NI_UpdatePinMap — no XML twin carries them) open
      // `[0]{fields}` with no subprop count, and the walk runs until it lands
      // exactly on the body-end boundary. Without a boundary (the last record)
      // this form stays undecoded.
      final boundary = bodyEndBoundary;
      if (boundary == null) return null;
      ops.u32(after, 0, _OpSource.grammar); // the verified body opener
      parsed = _fieldsUntil(after + _u32Bytes, boundary);
      if (parsed == null) return _blockBail(m0);
    }
    // When a body used element-type specs and the next record's position is
    // known, the walk must not overrun it, so a walker misparse cannot fabricate
    // a body. Ending short of the boundary is normal: some records trail
    // undecoded inter-record content.
    final boundary = bodyEndBoundary;
    if (_usedSpec && boundary != null && parsed.$2 > boundary) return _blockBail(m0);
    debugLastEndOffset = parsed.$2;
    return parsed.$1;
  }

  /// Parses fields until the walk lands exactly on [boundary] — the count-less
  /// body form. Any misparse, overshoot, or runaway bails.
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

  /// Runs one trial parse [body] under a fresh mark: a null return rolls back
  /// every op the trial recorded. The scoped form of the explicit mark/rollback
  /// pairs, for sites where a whole attempt is one call; sites with partial
  /// rollbacks, or that reject a field the parse already produced, keep explicit
  /// marks.
  T? _trial<T>(T? Function() body) {
    final m = ops.mark();
    final parsed = body();
    if (parsed == null) ops.rollback(m);
    return parsed;
  }

  (List<BinaryTypeField>, int)? _fields(int from, int count) {
    // Every recursion (_field → nested declaration/instance/spec → _fields)
    // routes through here, so one depth guard covers them all.
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
      // Inside an instance/element run an element-decoded populated array
      // (children present) already consumed its tail through the terminator, so
      // a DELIM ahead belongs to the parent array's next element and the chain
      // walk must not swallow it. At declaration level there is no enclosing
      // element run and a populated array's trailing DELIM-led block is its
      // element-type spec (NI_Wait's decoded AdditionalResultsHints trails
      // `[DELIM][X=NI_CustomResult][DELIM][count]{items}`).
      if (field.$1.isArray && (field.$1.children.isEmpty || !_inInstance)) {
        // Specs are detected by their frame — nothing else in a field walk leads
        // with a bare delimiter — not by the attr bits (TEInf's CustomResults
        // carries 0x8001 before its spec, the same field inside Substep.TS a
        // plain 0x1, and Action.Substeps 0x8001800 with no spec at all). Blocks
        // chain: a populated array stores its type spec and then its
        // element-content block, both DELIM-led. Each is walked structurally and
        // surfaced as an undecoded blob (elementSpecBytes), which .seq writing
        // and populated arrays need; a DELIM-led tail neither form can walk
        // fails the body.
        while (true) {
          final specEnd = _elementSpec(at) ?? _refSpec(at) ?? _protoSpec(at);
          if (specEnd == null) break;
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
        // A copy method, not a hand-written constructor call, so a field added
        // to BinaryTypeField cannot be dropped here.
        fields.add(field.$1.withElementSpecBytes(specBytes));
      } else {
        fields.add(field.$1);
      }
    }
    return (fields, at);
  }

  /// One field record; returns (field, next offset) or null on an uncovered
  /// shape.
  ///
  /// Field model (twin-validated): bit 0x2 = stored value; 0x200 =
  /// display-format word after the value; 0x80 = delimiter-framed (Expression
  /// scalars, typed references, inline instances). The other low bits
  /// (0x4/0x8/0x20/0x40) advertise which flag attributes the field stores, but
  /// the attr words run until the 0 terminator ([_attrTail]) — except on Obj
  /// declarations, which have no terminator, so there the 0x8/0x20/0x40 bit
  /// count is load-bearing (one word each; twin-validated on Requirements).
  (BinaryTypeField, int)? _field(int at) {
    debugLastFieldOffset = at;
    return _trial(() => _fieldParse(at));
  }

  (BinaryTypeField, int)? _fieldParse(int at) {
    if (at + 6 * _u32Bytes > recordRegionLength) return null;
    final fieldFlags = _u32(at);
    if (_u32(at + _u32Bytes) != 0) {
      // Compact form: [name][value][attr words…][0] — no flags/class prefix, so
      // the second slot holds the stored value where every other form has 0.
      // Measured on the binary-only step-type typedefs (DescriptionFormat =
      // ResStr(…) in NI_Measurement). Declaration level only: inside an instance
      // any two adjacent pool words match it and fabricate fields from
      // structural tokens (a step TS's Requirements read a bogus
      // `Data = 'Sequence'` child before instance context disabled it).
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
    // Bit 0x800 is only measured on plain `Num` fields (typedef defaults and
    // instance members); any other shape carrying it is uncovered.
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    // The stored-attr-word floor the flag bits promise (see [_attrTail]). Bit
    // 0x4 is excluded: some 0x4 fields store a zero attr word (`LowExpr`
    // `[0][0]`), most store none, and no per-file marker separates them —
    // counting it unconditionally breaks 4 rosetta twin-validated bodies, and
    // counting it only under the 0x76 record-prefix layout regresses the 0x76
    // exemplars (1→6 and 0→7 bailing bodies).
    final minAttrs = ((fieldFlags >> 3) & 1) + ((fieldFlags >> 5) & 1) + ((fieldFlags >> 6) & 1);

    // Descriptor node: [0][0][DELIM][name][childCount][children…] — no tail. The
    // shape type descriptors use for nested objects, measured inside
    // element-type specs and PropertyObjectType instances (the spec's
    // 'Type'/'ArrayDimensions' nodes). Distinguished from the framed form by
    // flags == 0 (framed fields carry bit 0x80) and from the plain form by the
    // delimiter where the class word would sit. Children serialize like
    // overrides — a subset, compared by name against the materialized twin.
    if (fieldFlags == 0 && _u32(at + 2 * _u32Bytes) == _recordDelimiter) {
      final name = _tok(_u32(at + 3 * _u32Bytes));
      if (name == null) return null;
      final childCount = _u32(at + 4 * _u32Bytes);
      if (childCount > _typeMaxFields) return null;
      // The zero flags word discriminates the form — grammar-determined, like
      // the framing zero and delimiter.
      ops.u32(at, 0, _OpSource.grammar);
      ops.u32(at + _u32Bytes, 0, _OpSource.grammar);
      ops.u32(at + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
      ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
      ops.u32(at + 4 * _u32Bytes, childCount, _OpSource.model);
      final children = _fields(at + 5 * _u32Bytes, childCount);
      if (children == null) return null;
      return (
        BinaryTypeField(
          name,
          className: SeqValueClass.object.wire,
          children: children.$1,
          instanceOverrides: true,
          fieldFlags: 0,
        ),
        children.$2,
      );
    }

    // Framed form: [flags|0x80][0][DELIM][X][name][value…][attrs…][0].
    if (fieldFlags & _fieldFramedBit != 0) {
      if (hasNumericRep) return null;
      if (_u32(at + 2 * _u32Bytes) != _recordDelimiter) return null;
      final x = _u32(at + 3 * _u32Bytes);
      final nameWord = _u32(at + 4 * _u32Bytes);
      // A delimiter in the name slot is an anonymous element, legal only inside
      // an instance/array context (an expression-array element; its
      // cross-format twin writes `<ExprValue typename='Expression' name=''>`).
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
      var className = SeqValueClass.expression.wire;
      // A bound-token pair — not X — discriminates a typed array instance
      // (`Substeps`) from a framed scalar, whose single value token is followed
      // by an attr word, a flag bitmask never shaped like a bound token. X is
      // not a table reference here: Substeps carries X=2 while its twin types it
      // the never-serialized intrinsic StepTypeSubstepsArray, the newer record
      // generation writes X=0, and a framed valued array of Expression elements
      // (a step's `DataSourceArray`) carries an X resolving to `Expression`.
      final boundPair =
          valued &&
          next + 2 * _u32Bytes <= recordRegionLength &&
          _isBoundToken(_tok(_u32(next))) &&
          _isBoundToken(_tok(_u32(next + _u32Bytes)));
      if (boundPair) {
        final lbound = _tok(_u32(next))!;
        final ubound = _tok(_u32(next + _u32Bytes))!;
        // X is an intrinsic type id / generation sentinel, surfaced as
        // [BinaryTypeField.intrinsicTypeId] (null ↔ 0, bijective).
        ops.u32(at + 3 * _u32Bytes, x, _OpSource.model);
        ops.poolRef(next, _u32(next));
        ops.poolRef(next + _u32Bytes, _u32(next + _u32Bytes));
        if (ubound == '[]') {
          // Empty array: ['[0]']['[]'][attr words…][0][one 0x00 pad byte] —
          // anchor-measured across every rosetta binary.
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
              className: SeqValueClass.objects.wire,
              arrayLBound: lbound,
              arrayUBound: ubound,
              intrinsicTypeId: x == 0 ? null : x,
              fieldFlags: fieldFlags,
              attrWords: attrs,
            ),
            tail + 1,
          );
        }
        // Populated framed array: the elements follow the standard array tail,
        // counted by the bounds ([_populatedArrayTail]). All-or-nothing — an
        // element run that does not frame bails the body, since its extent
        // cannot be measured without decoding it.
        final attrs = <int>[];
        final elements = _populatedArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
        if (elements == null) return null;
        return (
          BinaryTypeField(
            name,
            className: SeqValueClass.objects.wire,
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
          // The twin's `<value/>` reads as an empty string, unless inside an
          // instance where an unvalued field is inherited.
          value = _inInstance ? null : '';
        }
      } else if (x >= 1 && valued && _validTableX(x) && _tableRef(x).name == 'Expression') {
        // Framed valued scalar with an explicit type-table reference — the newer
        // record generation's Expression scalar (the old one writes X=0, type
        // implicit). Over 2,619 DescriptionFormat/DefaultNameFormat sites
        // `X - 1 - typeIndexBase` equals the Expression record's index,
        // including files where Expression is not first and files whose base is
        // nonzero, so requiring that resolution makes a file whose base cannot
        // be recovered bail instead of fabricating a type.
        value = _tok(_u32(next));
        if (value == null) return null;
        ops.u32(at + 3 * _u32Bytes, x, _OpSource.model); // 1-based type-table reference
        ops.poolRef(next, _u32(next));
        next += _u32Bytes;
      } else if (x >= 2 && !valued && _validTableX(x)) {
        // Type table[X-1] (1-based, the same convention as step references), in
        // one of two twin-validated shapes: an inline override instance —
        // `[name][attr words…][childCount]` then the overridden fields in the
        // full field grammar (Substep.TS stores an attr word 0x440018 before its
        // count), serializing only the overrides like X == 1
        // (DotNetStepAdditions.StructDef stores 2 of DotNetParameter's 11
        // fields), so children compare as a subset of the materialized twin; or
        // a default-instance reference with no inline content, just the
        // attr-word tail.
        final ref = _tableRef(x);
        ops.u32(at + 3 * _u32Bytes, x, _OpSource.model); // 1-based type-table reference
        // The scan starts past the flags-promised attr floor so a zero-valued
        // attr slot does not read as the ref-only terminator (see [_attrTail]).
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
                className: ref.className ?? SeqValueClass.object.wire,
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
        className = ref.className ?? SeqValueClass.object.wire;
        typeName = ref.name;
        // A reference to a scalar-classed type reads that class's default, the
        // twin's `<value/>` semantics (AssemblyPath:Path materializes '' via its
        // PathValue class). Object-classed references carry no value, and inside
        // an instance an unvalued field is inherited, not defaulted.
        value = _inInstance
            ? null
            : switch (SeqValueClass.from(className)) {
                SeqValueClass.string || SeqValueClass.path || SeqValueClass.expression => '',
                SeqValueClass.boolean => 'false',
                SeqValueClass.number => '0',
                _ => null,
              };
      } else if (x == 1 && !valued) {
        // Inline custom instance: [name][attr words…][overrideCount] then the
        // overridden fields, ordinary valued fields
        // (`[0x2][0][cls][name][value]` — Bool/Str/framed-Expression) decoding
        // with the general grammar in instance context. The instance's type is
        // engine-intrinsic, so typeName stays null and children carry only the
        // overrides. Attr words may precede the count (Action.Menu stores two
        // 0x80018 words) — scanned past as in the X >= 2 form, starting past the
        // flags-promised attr floor (see [_attrTail]).
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
            className: SeqValueClass.object.wire,
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

    // Framed-lite form: [flags][0][DELIM][name][value?][attrs…][0] — a field
    // with the delimiter in the class slot and no X word (Action's TS override
    // stores PassActTarget/FailActTarget this way with flags 0x60).
    // Distinguished from the full framed form by the absent 0x80 bit and from
    // the descriptor node by flags != 0.
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
        // Framed-lite object form: `[flags][0][DELIM][name][attrs…]
        // [childCount]{children}` — an X-less instance node (a substep's `TS`
        // stores `[0x60][0][DELIM][TS][0x40018][0x40018][4]` then its four
        // children). Same count scan as the X >= 2 instance form, starting past
        // the flags-promised attr floor (see [_attrTail]); when it stops at the
        // scalar tail's 0 terminator, the field is the scalar below.
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
      // The twin's `<value/>` reads as an empty string, unless inside an
      // instance where an unvalued field is inherited (null).
      var value = _inInstance ? null : '';
      if (valued) {
        // An all-ones value slot is the unset sentinel: the field stores a value
        // slot but no value (MessagePopup's default TS stores
        // `[0x2][0][DELIM][LoopIncrement][DELIM][0]`), reading like the twin's
        // `<value/>`.
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
      // The X-less framed-lite shape serializes no type, and the twin's type
      // varies per site: Action's `PassActTarget`/`FailActTarget` materialize
      // `typename='Expression'`, but an old-generation substep `Result` stores
      // its `Error`/`Common` object references in the same shape
      // (`<Error typename='Error' classname='Obj'>` in the materialized twin).
      // Claiming `ExprValue`/`Expression` here is wrong at those Result sites,
      // so no class/type is claimed.
      return (BinaryTypeField(name, value: value, fieldFlags: fieldFlags, attrWords: attrs), after);
    }

    // Plain form: [flags][0][cls][name][value-part][format?][extras…]
    // [terminator 0] — extras sit after the value part (CodeTemplates:
    // [Str][name][value][0x480018][0]); with no value part they precede the
    // terminator directly (BlockStartTypes: [Str][name][0x480018][0]).
    final className = _clsTok(_u32(at + 2 * _u32Bytes));
    final name = _tok(_u32(at + 3 * _u32Bytes));
    if (className == null || name == null) return null;
    final cls = SeqValueClass.from(className);
    ops.u32(at, fieldFlags, _OpSource.model); // surfaced: BinaryTypeField.fieldFlags
    ops.u32(at + _u32Bytes, 0, _OpSource.grammar); // the verified framing zero
    ops.poolRef(at + 2 * _u32Bytes, _u32(at + 2 * _u32Bytes));
    ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
    var next = at + 4 * _u32Bytes;
    // Nested object declaration — class word 'Obj' or a class-name string
    // (PythonStepAdditions.PythonCall declares class 'CPythonCall' this way, its
    // 14 children inline): [attr words…][childCount][children…] with no trailing
    // zero, so the childCount is the first word past the attr words small enough
    // to be a count whose children then parse (Substep.TS's Result stores two
    // 0x400000 attr words where its flag bits promise one).
    //
    // 'Ref' is a scalar value class (an engine object reference): all 8
    // XML-corpus sites are childless, valueless self-closing elements
    // (`<EvaluatedConditionExpr classname='Ref'/>`), so it takes the scalar tail
    // below rather than this count scan, under which a Ref tail `[attr 4][0]`
    // misreads as `[childCount 4]{4 swallowed siblings}` — measured on the iTAC
    // `Connect` record, where it ate the sequence's remaining parameters and its
    // `Locals`.
    if (!valued && !_tailedValueClasses.contains(cls)) {
      if (hasNumericRep) return null;
      // On exactly flags == 0x4 a zero count candidate yields to the immediately
      // following word: that shape can store a zero-valued attr slot before the
      // count (`Limits` = `[0x4][0][Obj][Limits][0][4]{Low, High, LowExpr,
      // HighExpr}` — the zero is the attr, the 4 the count), and taking the zero
      // would drop the children. Only the adjacent candidate is tried: deferring
      // under any flags lets a truly-empty `NI_Data`'s trailing words parse as a
      // bogus count, and an unbounded 0x4 scan lets an empty `Parameters` steal
      // the next field's child from seven words away.
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
      // Unvalued fields read their class defaults (false / '' / 0 — the twin's
      // `<value/>` semantics): [attr words…][terminator 0], or the extdata tail
      // when flagged (Error's Code/Msg/Occurred). Inside an instance the value
      // is inherited instead (null). A 0x800-flagged Num stores its
      // representation word first ([_fieldHasNumericRepBit]:
      // NI_MeasurementParameter.ID/Dimension).
      int? repr;
      if (hasNumericRep) {
        if (cls != SeqValueClass.number || !_canRead(next)) return null;
        repr = _u32(next);
        ops.u32(next, repr, _OpSource.model);
        next += _u32Bytes;
      }
      final attrs = <int>[];
      final after = hasExtData ? _extTail(next) : _attrTail(next, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      if (!_unvaluedScalarClasses.contains(cls)) return null;
      return (
        BinaryTypeField(
          name,
          className: className,
          // A 'Ref' carries no persisted value in any context (its XML twin form
          // is a self-closing element), so value stays null, not a default.
          value: _inInstance || cls == SeqValueClass.reference
              ? null
              : switch (cls) {
                  SeqValueClass.boolean => 'false',
                  SeqValueClass.number => '0',
                  _ => '',
                },
          numericRepresentation: repr,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        after,
      );
    }
    // Array field: bound tokens `lbound ubound` then trail 0. Object arrays
    // (`Objs`) additionally carry one 0x00 pad byte after the trail — the stream
    // is byte-granular, and this pad shifts everything after an empty Objs array
    // off word alignment.
    if (_boundedArrayClasses.contains(cls) &&
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
      // Populated Objs array: `[lb][ub][one 0x00 pad]{elements}[attrs][0]` — the
      // elements follow the bounds directly (on the oracle the placed step's
      // Measurement.Parameters '[0]' '[10]' carries 11 element blocks;
      // EnumDefinition '[0]' '[1]' carries its 2 Num members as plain fields).
      // Count- and terminator-checked, all-or-nothing; on failure the array
      // falls back to the structural blob walk in [_fieldsInner].
      if (cls == SeqValueClass.objects && ubound != '[]') {
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
              partialArray: _lastArrayPartial,
            ),
            elements.$2,
          );
        }
      }
      // Populated scalar array (`Nums`): the element values follow the bounds
      // directly as an inline f64 run, then the standard attr tail —
      // `[lb][ub]{count × f64}[attrs…][0]`. Measured on corpus sequence locals
      // (51-element `[0]'..'[50]'` runs whose terminator and following field
      // land at count × 8 bytes) and value-validated against the cross-format
      // XML oracle (the same repo materializes the identical array in XML).
      // Count- and terminator-checked, all-or-nothing; on failure the array
      // falls back to the bounds-only read below, contents undecoded.
      if (cls == SeqValueClass.numbers && valued && ubound != '[]') {
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
      // A populated array whose elements did not decode is not claimed empty:
      // its element content rides in the trailing DELIM-led blocks, surfaced
      // undecoded via elementSpecBytes.
      final attrs = <int>[];
      var after = _attrTail(next + 2 * _u32Bytes, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      if (cls == SeqValueClass.objects) {
        if (after >= recordRegionLength || view.getUint8(after) != 0) {
          return null;
        }
        ops.byte(after, 0, _OpSource.grammar); // the verified trailing Objs pad
        after += 1;
        // An empty `Objs` array may carry a trailing element-type block —
        // `[classRef][DELIM][0][attr words…][0]`, the binary form of the XML
        // `<elemproto><_NAME_IN_ATTRIBUTE_ name='' classname='TEResult'/>
        // </elemproto>` (measured on every rosetta binary's sequence
        // `Locals > ResultList`). The delimiter in the name slot keeps it
        // disjoint from every field form: plain/framed/descriptor heads have 0
        // there, and a compact field's value slot never resolves at the
        // delimiter. Surfaced as the field's element-type spec blob
        // ([BinaryTypeField.elementSpecBytes]) with extent walked and contents
        // undecoded; its classname is the element's class, which the twin does
        // not surface as the array's typename, so no type is claimed here.
        if (ubound == '[]') {
          final proto = _elemProtoTail(after);
          if (proto != null) {
            if (debugCollectSpecs) debugSpecSites.add((name, after, proto.$2 - after));
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
    switch (cls) {
      case SeqValueClass.string when !hasNumericRep:
        final value = _tok(_u32(next));
        if (value == null) return null;
        ops.poolRef(next, _u32(next));
        final attrs = <int>[];
        final after = hasExtData
            ? _extTail(next + _u32Bytes)
            : _attrTail(next + _u32Bytes, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(name, className: className, value: value, fieldFlags: fieldFlags, attrWords: attrs),
          after,
        );
      case SeqValueClass.boolean when !hasNumericRep:
        // A stored Bool is one byte (TEInf's StepFCSeqF=true measures
        // [01][attr 0x4d0018][terminator]) — the same byte the instance grammar
        // reads. A u32 read only appears to work while every stored Bool in
        // scope is false.
        final value = view.getUint8(next);
        if (value > 1) return null;
        ops.byte(next, value, _OpSource.model);
        final attrs = <int>[];
        final after = hasExtData ? _extTail(next + 1) : _attrTail(next + 1, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(
            name,
            className: className,
            value: value == 1 ? 'true' : 'false',
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          after,
        );
      case SeqValueClass.number:
        // A 0x800-flagged Num stores [representation word][i64 value]; a plain
        // one stores an f64, unless it sits inside an instance whose typedef
        // declares this field with an integer representation, where the stored
        // value is an i64 with the representation implicit
        // ([_numericReprContext]).
        int? repr;
        if (hasNumericRep) {
          if (!_canRead(next)) return null;
          repr = _u32(next);
          ops.u32(next, repr, _OpSource.model);
          next += _u32Bytes;
        }
        if (next + 2 * _u32Bytes > recordRegionLength) return null;
        // The stored value is an i64 when the representation says so —
        // explicitly (bit 0x800), via [_numericReprContext], or by the subnormal
        // signature also used in [_scalarArrayTail]: an integer-stored slot read
        // as f64 collapses into the denormal range (i64 1 ↔ 5e-324), no corpus
        // text flavor stores subnormal numeric text (0 hits across 384 XML/INI
        // files), and the oracle twin types these slots Int64 (`<ID
        // classname='Num'><value representation='Int64'>1</value>` — the
        // parameter-element ID runs whose element type rides an unresolved
        // elemproto).
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
            className: className,
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

/// The decoded typed-model lenses of an already-inflated [body] in one shared
/// frame+pool+table pass: the sequence outlines and the type-record heads. The
/// single-scan path for `parseSeqFile` — calling the per-lens helpers separately
/// would re-frame the layout, rebuild the ordered string pool, and rescan the
/// type table once per lens. Both lenses read empty when the body does not
/// frame.
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
  // Names come entirely from the head scan, so the expensive second-pass body
  // decode is skipped — the hot path for [binaryTypeNames] and the whole-corpus
  // name sweep.
  for (final record in _typeRecordsFromBody(body, recordRegionLength, sharedPool: sharedPool, decodeBodies: false))
    record.name,
];

/// One decoded typedef field — the binary form of an XML typedef subprop.
///
/// Field records follow the typedef head as
/// `[fieldFlags][0][classIdx][nameIdx][value…]`, where flag bit 0x2 marks a
/// stored value, bit 0x80 a delimiter-framed form, bit 0x100 an extdata tail,
/// and bit 0x200 a display-format string after the value. Value arity by class:
/// Bool one byte, Str one word, Num an inline f64 (+ format ref when flagged),
/// `Nums`/`Strs`/`Objs` arrays a bound-token pair. Framed fields carry an X word
/// selecting Expression / a 1-based type-table reference / an inline instance.
/// See the body parser for the full grammar. Anything not matching a covered
/// shape leaves the whole body undecoded — all-or-nothing, no partial trees.
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
    this.partialArray = false,
  });

  /// The field name (`Code`, `ItemName`, …).
  final String name;

  /// The value class (`Bool`/`Str`/`Num`/`Nums`/`Strs`), or `ExprValue` for
  /// Expression-typed fields. Null for compact fields, whose class is not
  /// serialized. Kept verbatim; [valueClass] is the cataloged form.
  final String? className;

  /// [className] resolved against the [SeqValueClass] catalog.
  SeqValueClass? get valueClass => SeqValueClass.of(className);

  /// The named type for typed fields (`Expression`), null otherwise.
  final String? typeName;

  /// The stored scalar value in XML text form (`false`, `8192`, `""`), or null
  /// when the field carries none — including a flags-only override inside an
  /// instance, whose value is inherited from the type default.
  final String? value;

  /// The array bounds tokens as the file stores them (`'[0]'` / `'[]'` /
  /// `'[3]'`), or null for a non-array field. `arrayUBound == '[]'` is an empty
  /// array; anything else is populated, its element values riding in
  /// [elementSpecBytes] undecoded rather than reported empty. See [isArray] /
  /// [isEmptyArray].
  final String? arrayLBound;
  final String? arrayUBound;

  /// Whether this field is an array (empty or populated).
  bool get isArray => arrayUBound != null;

  /// Whether this array is empty (`ubound == '[]'`). False for a populated array
  /// whose elements are undecoded.
  bool get isEmptyArray => arrayUBound == '[]';

  /// Nested declaration children (an `Obj` field's own field list), decoded
  /// recursively — or, on an array field ([isArray]), the array's decoded
  /// elements ([_populatedArrayTail]: instance blocks carry `name ''` +
  /// [typeName]; scalar members their own names). A typed default-instance
  /// reference (`X >= 2` framed form) carries no children: the binary stores
  /// only the reference, and materializing the referenced type's defaults is the
  /// XML writer's job.
  final List<BinaryTypeField> children;

  /// TODO(element-type spec): the length in bytes of this array field's trailing
  /// element-type spec plus, for a populated array whose elements did not decode
  /// (see [children]), its element content — an undecoded blob, surfaced because
  /// .seq writing needs it. The blob starts right after this field's own
  /// encoding. Null when the field carries no spec, or when the spec trails the
  /// body's last field where the count-driven walk leaves it untouched.
  final int? elementSpecBytes;

  /// True for an inline custom/override instance (framed `X >= 1`) and for a
  /// descriptor node: [children] holds only the fields serialized (a subset of
  /// the materialized type, the rest inherited), so compare children as a subset
  /// of the twin rather than as the full field list. For the `X == 1` form the
  /// instance type is engine-intrinsic (not in the file), so [typeName] stays
  /// null.
  final bool instanceOverrides;

  /// TODO(intrinsic types): for a framed valued empty array, the X word is an
  /// engine-intrinsic type id, not a table reference (`Substeps` carries 2 while
  /// its twin types it `StepTypeSubstepsArray`, a type the file never
  /// serializes). Surfaced undecoded; the id → name map needs more corpus
  /// evidence. Null elsewhere.
  final int? intrinsicTypeId;

  /// The raw numeric-representation code a `Num` field flagged with bit 0x800
  /// stores (see [_fieldHasNumericRepBit]): the XML `representation` attribute's
  /// binary form. Twin-evidenced codes are named by
  /// [BinaryNumericRepresentation]; others are carried verbatim. Null when the
  /// field stores none (a plain f64 `Num`, or any other class).
  final int? numericRepresentation;

  /// Whether this field's type is engine-intrinsic and therefore not serialized
  /// — an intrinsically-typed array ([intrinsicTypeId]) or an inline custom
  /// instance ([instanceOverrides] with no [typeName]). For these [typeName] is
  /// absent by design, not a decode gap, so a twin comparison checks [className]
  /// rather than the typename.
  bool get typeNameEngineIntrinsic => intrinsicTypeId != null || (instanceOverrides && typeName == null);

  /// Whether this is a plain nested-object declaration whose [children] are the
  /// full field list — as opposed to an override subset ([instanceOverrides]) or
  /// a typed reference ([typeName] set, no serialized children). Only these are
  /// descended one-for-one against a twin.
  bool get isPlainDeclaration => children.isNotEmpty && !instanceOverrides && typeName == null;

  /// The raw field-flags word this record serialized (word 1 of the
  /// `[flags][0]…` field forms); the bits are cataloged at [_fieldKnownFlagBits].
  /// Corpus bit population (330,099 flagged of 354,117 decoded fields over the
  /// 297-binary corpus): 0x2×211,848, 0x4×44,411, 0x8×22,692, 0x20×37,498,
  /// 0x40×44,361, 0x80×41,084, 0x100×1,876, 0x200×1,170, 0x800×143. Bit 0x2
  /// co-varies with a decoded value/array/child surface on 211,676 of 211,848
  /// sites; the 172 without one are the framed-lite unset sentinel inside
  /// instances (a value slot stored, no value). Null for forms that serialize no
  /// flags word: the compact `[name][value]` form and the
  /// element-block/step-element forms, whose heads are DELIM- or
  /// class-token-led.
  final int? fieldFlags;

  /// The field's trailing flag-attribute words in serialization order (between
  /// the value part and the 0 terminator, plus any attr words preceding an
  /// instance/object child count), retained uninterpreted. At the type-record
  /// level the analogous words carry the XML `typeflags`/`flagsforinstances`/
  /// `instanceoverrideflags`/`valueflags` attributes named by count
  /// ([BinaryTypeRecord.flags]); at the field level that count↔attribute mapping
  /// is corpus-refuted — fields store more words than their flag bits promise
  /// (see [_attrTail]) — so the words are surfaced raw. Empty when the field
  /// stores none.
  final List<int> attrWords;

  /// Whether this is a populated array whose declared element count exceeds the
  /// number of decoded [children]: the leading elements framed and the remainder
  /// uses a shape the grammar does not yet cover. Set only for the sequence
  /// group arrays (Main/Setup/Cleanup) the record walk decodes as a partial step
  /// run ([_TypeBodyParser._stepElementPrefix]), where [children] holds the
  /// decoded prefix steps and the bytes past this field stay an explicit
  /// undecoded span.
  final bool partialArray;

  /// Returns a copy with [elementSpecBytes] set — used when a trailing
  /// element-type spec is walked after the field's own encoding. A method, not a
  /// hand-written constructor call, so a newly added field cannot be dropped.
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
    partialArray: partialArray,
  );
}

/// A decoded type record — the binary form of an XML typedef element.
///
/// The head carries the same attributes the XML encoding puts on the typedef
/// element (classname, typecategory, timestamp, the version triple, and the
/// ordered flag words typeflags / flagsforinstances / instanceoverrideflags /
/// valueflags), from the layout `[classIdx][nameIdx][typecategory][stamp][0?]
/// [ver][ver][ver][flags…][0][0xffffffff]` — the triple starts at word 3 on the
/// TS 4.x/5.0 layout, word 4 on newer. Head attributes are validated
/// attribute-for-attribute against the oracle twin. The body follows the
/// delimiter and decodes into [fields].
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

  /// [className] resolved against the [SeqValueClass] catalog.
  SeqValueClass? get valueClass => SeqValueClass.of(className);

  /// `typecategory` (verbatim code; NI-internal meaning not invented).
  final int typeCategory;

  /// The typedef save `timestamp` (UNIX seconds — the "type stamp").
  final int timestamp;

  /// `typeversion`, `typelastmodversion`, `typeminprodversion`, in order.
  final List<String> versions;

  /// The ordered flag words after the version triple (trailing zeros dropped).
  /// Absent attributes are not written, so the attribute each word carries
  /// depends on how many there are — and, for three, on the record's
  /// [typeCategory] (rosetta-twin enumerated: the only two 3-flag combos split
  /// on category 1 vs not):
  ///   1 → typeflags
  ///   2 → typeflags, valueflags
  ///   3 → typeflags, flagsforinstances, then instanceoverrideflags when
  ///       [typeCategory] == 1 (step types), else valueflags
  ///   4 → typeflags, flagsforinstances, instanceoverrideflags, valueflags
  /// Empty when the record tail did not frame (absent, never guessed).
  final List<int> flags;

  /// The typedef's decoded field list (see [BinaryTypeField]), or null when the
  /// body was not decoded — either the record has no body region, or it has one
  /// whose shapes the grammar does not yet cover ([undecodedBody] distinguishes
  /// the two). Never partially guessed.
  final List<BinaryTypeField>? fields;

  /// True when a body region exists but did not decode (all-or-nothing bail), as
  /// opposed to a record with no body region. Both leave [fields] null; this
  /// separates "undecoded" from "declares nothing" so consumers do not present a
  /// bailed body as an empty type.
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

/// The decoded type-record heads of a binary TOF1 file, in table order — see
/// [BinaryTypeRecord] for the layout. The same scan as [binaryTypeNames],
/// keeping the head fields, so both share one corpus-validated table.
List<BinaryTypeRecord> binaryTypeRecords(Uint8List seqBytes) => _withLayout(seqBytes, _typeRecordsFromBody);

/// The type-index base recovered for [seqBytes] — how far the file's framed
/// 1-based type references are offset from the recovered head table (see
/// [deriveTypeIndexBase]). Zero for the aligned majority, nonzero (either sign)
/// for the misaligned cohort. Returns 0 when [seqBytes] does not frame.
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

/// Cap on a field's attr-word tail (three is the most any twin-validated field
/// stores — ffi/iof/vf, e.g. TEInf.Links).
const _fieldMaxAttrWords = 8;

/// Cap on an extdata block list (Error stores four:
/// STRUCT/CLUST/DNSTRUCT/BLVCLUSTER).
const _typeMaxExtBlocks = 8;

/// Cap on typedef-body field-nesting depth. The deepest real nesting is a
/// handful of levels (TS instance → Result Obj → Error ref); this bound exists
/// so a hostile self-nesting body bails instead of overflowing the stack.
const _maxFieldDepth = 64;

/// Cap on flag words read after the version triple while looking for the record
/// delimiter (real records carry at most four flags plus a trailing zero).
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
        // Index 0 is padding/separator by this file's pool convention, so a zero
        // word does not count as a version reference.
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
    // Head fields take no part in detection, so the corpus-validated detection
    // counts cannot shift: class word right before the name, typecategory right
    // after, flags after the triple up to the record delimiter (trailing zeros
    // dropped). A class word of 0 resolves to pool[0], the file's root token,
    // which the TS 4.x-era generation references by index 0 (see
    // [_TypeBodyParser._clsTok]).
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
      // Binary-only record generation (typecategory 2, measured on the oracle's
      // NI_MeasurementParameter): the tail after the version triple is
      // `[1][idRef]` — a constant 1 and a unique-ID string reference — then the
      // standard `[0][subpropCount][fields…]` body with no delimiter. Requiring
      // the unique ID leaves detection unchanged; only records whose tail did
      // not frame gain a body offset.
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
  // Names-only callers skip the second pass: the head scan already has every
  // name (the hot path for the whole-corpus name sweep).
  if (!decodeBodies) return records;
  // Second pass: bodies parse with the complete table of heads in hand — framed
  // references index it 1-based (the same convention as step references) and may
  // point forward. Bodies parse in table order with each result folded back in,
  // because an inline materialized instance needs the referenced type's field
  // count and the corpus defines element/base types before their use sites.
  final result = List.of(records);
  // The type-index base is a whole-file property (see [deriveTypeIndexBase]):
  // computed once, then rebasing every body's framed references consistently.
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, result);
  for (var i = 0; i < result.length; i++) {
    final bodyAt = bodyOffsets[i];
    if (bodyAt == null) continue;
    final boundary = i + 1 < headAts.length ? headAts[i + 1] - _u32Bytes - _typeRecordPreambleBytes : null;
    final fields = _typeFieldsAt(body, view, pool, bodyAt, recordRegionLength, result, boundary, typeIndexBase);
    // A body region existed here (bodyAt != null); record whether it decoded so
    // consumers can tell "undecoded" from "declares nothing".
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

/// Tooling aid for grammar iteration, not part of the decode API: every type
/// record with a framed body, in table order, with its body start offset (within
/// the inflated body) and either the end offset the parse consumed to or the
/// byte offset of the first field the grammar could not cover. Uses the
/// production parser, so it cannot disagree with the real decode.
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
  // Whole-file constant — derived once, not per record body.
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

/// The minimum length + punctuation signature of a TestStand unique-ID string
/// (`8;G6MnVLO732>8ODE2E3h4jDhR\`), the kind word of a normal placed step.
/// Corpus-tuned to admit the ID charset while rejecting ordinary identifiers.
bool _looksLikeUniqueId(String text) => text.length >= 15 && RegExp(r'[;\\<>^\]]').hasMatch(text);

/// The step names of a binary TOF1 file, recovered from the step references
/// ([_stepToken] runs) in the record region. In file order, de-duplicated — the
/// step set, not yet grouped into Setup/Main/Cleanup (file order is not
/// execution order). On the content-exact OutputVoltage twin the recovered set
/// equals the XML twin's steps; on every other Rosetta twin the count matches,
/// the names differing because those pairs are the same sequence saved from
/// different toolchains.
///
/// Known contamination: on 4/294 corpus binaries a step-type substep hook
/// (`OnNewStep`/`Post`/`Edit`) matches this reference shape and is reported as a
/// step. Those hooks are step-shaped objects inside type definitions;
/// separating them needs the not-yet-decoded type-region framing. `[]` when
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
  // boundaries), so scan every byte offset.
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
final _stepGroupNames = {for (final group in StepGroup.values) group.key};

/// The sequence-record subprops that precede the `Main` group array in
/// TestStand's fixed layout — the only ones the leading-subprop decode covers
/// (the rest sit after the group arrays, behind the not-yet-decoded step
/// content).
const _sequenceLeadingSubPropNames = {'Parameters', 'Locals'};

/// The fixed leading subprop order of a sequence record and the closed tail name
/// set that follows it. XML census over every corpus sequence (43 files, 387
/// subprop sites): all lead `Parameters, Locals, Main, Setup, Cleanup`; the tail
/// is `RecordResults, RTS, Requirements, FailureAction` (39 files) or
/// `GotoCleanupOnFail, RecordResults, RTS, Requirements` (4 older files), with
/// no other name. Older binary generations carry up to all five tail names
/// (10-subprop records), so the walk fixes the five leading positions and
/// requires each tail position to be an unseen member of the closed set. Every
/// field also needs its exact class and a clean parse, which stops the walk on
/// any coincidental parse inside undecoded step content.
final _sequenceSubPropHead = ['Parameters', 'Locals', StepGroup.main.key, StepGroup.setup.key, StepGroup.cleanup.key];
const _sequenceSubPropTailNames = {'GotoCleanupOnFail', 'RecordResults', 'RTS', 'Requirements', 'FailureAction'};

/// The value class each sequence subprop carries, from the same XML census —
/// the per-field shape check of the full-record walk.
final _sequenceSubPropClasses = {
  'Parameters': SeqValueClass.object,
  'Locals': SeqValueClass.object,
  StepGroup.main.key: SeqValueClass.objects,
  StepGroup.setup.key: SeqValueClass.objects,
  StepGroup.cleanup.key: SeqValueClass.objects,
  'RecordResults': SeqValueClass.boolean,
  'GotoCleanupOnFail': SeqValueClass.boolean,
  'RTS': SeqValueClass.object,
  'Requirements': SeqValueClass.object,
  'FailureAction': SeqValueClass.number,
};

/// Upper bound on a credible `[Sequence][name][count]` subprop count — both
/// attested layouts have 9; the margin admits a future layout without letting a
/// huge word through.
const _sequenceRecordMaxSubProps = 12;

/// One decoded sequence record from the full-record walk: the
/// `[Sequence][name][subpropCount]` head at [offset] plus the decoded subprop
/// prefix (each with its end offset, for byte accounting).
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

  /// The head word count this record framed with — 3, or 4 with the middle
  /// comment slot. Tracked independently of [comment], which may be null even on
  /// a 4-word head when the slot's word is not structurally a comment.
  final int headWords;

  /// The record's comment string, from the optional slot between the name and
  /// the count (`[Sequence][name][commentRef][count]`, an older record
  /// generation; absent when the count follows the name directly).
  final String? comment;
  final int subpropCount;
  final List<(BinaryTypeField, int)> subProps;
  final int end;
  bool get complete => subProps.length == subpropCount;
}

/// Locates and decodes every sequence record with the full subprop walk —
/// `[Sequence][name][count]` then up to [count] fields in the fixed layout order
/// ([_sequenceSubPropHead] then [_sequenceSubPropTailNames]), through the
/// populated Main/Setup/Cleanup group arrays whose elements are the placed
/// steps. All-or-nothing per field, with a kept prefix per record: each subprop
/// must parse with the production field grammar, match the next name of a
/// still-compatible layout, and carry that name's class
/// ([_sequenceSubPropClasses]); a populated group array that decodes bounds-only
/// also ends the walk, since the bytes that follow are step content of unknown
/// extent; and a candidate record is kept only when its first subprop is
/// `Parameters` (43/43 XML sequences lead with it). Nothing past a miss is
/// claimed.
///
/// On every rosetta binary the walk decodes the complete record (all 9 subprops,
/// group arrays element-for-element), and the content-exact OutputVoltage pair
/// matches value-for-value.
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
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)
    ..ops = sink
    .._partialStepArraysOk = true;

  // Walks the subprop run at [from], up to [count] fields, constrained by the
  // fixed head order and the closed tail set. Returns the decoded prefix with
  // each field's end offset.
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
      if (!gated) gated = field.valueClass != _sequenceSubPropClasses[field.name];
      // A group array's elements are placed steps; an element of any other class
      // is a misparse leaking a later field into the array (corpus-caught: a
      // short-read `ViCall` let the following `TDChecksum` register as a group
      // element), so the walk stops before that field.
      if (!gated &&
          _stepGroupNames.contains(field.name) &&
          field.children.any((c) => c.valueClass != SeqValueClass.step)) {
        gated = true;
      }
      if (gated) {
        // A field the layout rules reject: its ops are dropped.
        sink.rollback(mField);
        break;
      }
      cur = _TypeBodyParser.debugLastEndOffset!;
      subProps.add((field, cur));
      // A populated group array the walk cannot cross ends it: its elements
      // either did not decode at all (children empty) or only a prefix did
      // ([BinaryTypeField.partialArray]). Either way the bytes past the decoded
      // content are an undecoded span of unknown extent, so no later subprop can
      // be located.
      if (_stepGroupNames.contains(field.name) &&
          ((!field.isEmptyArray && field.children.isEmpty) || field.partialArray)) {
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
    // Two head forms: `[Sequence][name][count]` and, in an older record
    // generation, `[Sequence][name][commentRef][count]` (a pool string, measured
    // on 10-subprop records carrying the sequence's editor comment). The
    // standard form is tried first; Parameters-first arbitrates.
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
      // The 3- vs 4-word framing is arbitrated by the Parameters-first walk
      // above. The middle slot surfaces as an editor comment only when its word
      // cannot also be a subprop count — a count-shaped word there is
      // structural, so a 4-word record whose slot is count-shaped decodes with
      // no comment rather than a fabricated one.
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

/// The step-record data subprops (the plain fields following the step's TS node)
/// the decode keeps — only names twin-validated on the rosetta oracle
/// (`Measurement` name+parameters, `PinMapPath`). The after-TS field walk stops
/// at the first non-listed parse, so a coincidental field-alike past the step
/// record cannot surface.
const _stepDataSubPropNames = {'Measurement', 'PinMapPath'};

/// One placed step recovered from a binary step reference: its name and, when
/// the reference's type word lands in the file's type table, its step type name.
///
/// The word after the `Step` token is the step's 1-based index into the type
/// table ([binaryTypeNames] order), not a string-pool reference — validated by a
/// differential sweep across the rosetta twins (9 placed steps in 4 files,
/// testing every byte offset/width/transform near each step; the only consistent
/// survivor). Reading it as a kind token (`ExprValue`/`Expression`/unique-ID) is
/// a trap: low pool indices land in the typedef string region, so the oracle's
/// `Update pin map` carries word 21 = type #20 `NI_UpdatePinMap` (1-based 21)
/// while pool[21] happens to be `'ExprValue'`.
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

  /// The step's `TS` (TestStand) subproperties, from the descriptor node
  /// following the step reference (see [_TypeBodyParser.parseStepTs]). The
  /// fields the step serializes — its overrides of the step type's TS defaults
  /// (`Id`, and any non-default `CustomResults`/expressions), not the full
  /// materialized list. Empty when the step data does not frame.
  final List<BinaryTypeField> tsSubProps;

  /// The step's serialized data subprops beyond `TS` — the plain fields
  /// following the TS node in the step record (`Measurement` with its name +
  /// parameter array on measurement steps, `PinMapPath` on update-pin-map
  /// steps), decoded with the same field grammar and kept only for the
  /// twin-validated [_stepDataSubPropNames]. On the oracle all 11
  /// `Measurement.Parameters` elements match the twin value-for-value.
  final List<BinaryTypeField> dataSubProps;

  /// The step's code-module binding, recovered from the name→value word pairs in
  /// the step's record span (this step reference up to the next): the module
  /// payload serializes each field as `[nameIdx][valueIdx]` — `VIPath` for the
  /// LabVIEW adapter, `ModulePath` + `FunctionOrAttributeName` for the Python
  /// adapter. On the oracle all four Python steps' paths and functions equal the
  /// XML's, and every rosetta LabVIEW binary yields its `VIPath` pairs. Null when
  /// the span carries no such pair (no module, or an adapter whose pair tokens
  /// are not yet catalogued).
  final String? viPath;
  final String? pythonModule;
  final String? pythonFunction;

  @override
  String toString() => 'BinaryStepRef($name${typeName != null ? ': $typeName' : ''})';
}

/// A reconstructed sequence outline from a binary TOF1 record region: the
/// sequence's name and its steps grouped into Setup/Main/Cleanup.
///
/// Assembly rule, validated on the content-exact OutputVoltage twin where the
/// grouped, ordered result equals the XML twin: a step belongs to the nearest
/// preceding group container record (`Objs Setup` / `Objs Main` /
/// `Objs Cleanup`), and group containers and steps belong to the nearest
/// preceding sequence declaration ([_objectDeclarationPath] through
/// `Objs/Seq/[i]`), because the region lays each sequence's content out
/// contiguously.
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

  /// Steps whose group membership is not decodable from position — laid out
  /// before any group marker, seen on 7/294 corpus binaries. Reported here
  /// rather than guessed into a group.
  final List<BinaryStepRef> ungrouped;

  /// The sequence-record subprops preceding the `Main` group array —
  /// `Parameters`, `Locals`, decoded with the typedef field grammar (see
  /// [BinaryTypeField]).
  final List<BinaryTypeField> leadingSubProps;

  /// The sequence subprops that follow the group arrays — `RecordResults`
  /// (Bool), `FailureAction` (Num), `Requirements` (Obj with its `Links` child)
  /// and `RTS` (Obj runtime settings) — anchor-located and single-field parsed
  /// (see [_sequenceTailSubProps]).
  final List<BinaryTypeField> tailSubProps;

  /// The sequence's editor comment, from the record head's optional comment slot
  /// (see [_SequenceRecordWalk.comment]). Null when the record uses the
  /// comment-less head or no record walk succeeded.
  final String? comment;

  /// The group arrays (`Main`/`Setup`/`Cleanup`) decoded by the full-record walk
  /// ([_sequenceRecordWalks]), in record order: each an `Objs`-classed
  /// [BinaryTypeField] whose children are the placed step elements (class
  /// `Step`, bound type, with their `TS`/data subprop trees — the binary form of
  /// the XML `<Main><value><Step …>` content). Empty when the record walk did
  /// not reach or decode a group array; [setup]/[main]/[cleanup] remain the step
  /// lists either way.
  final List<BinaryTypeField> groupArrays;
}

/// The sequence outlines of a binary TOF1 file — each sequence with its typed
/// steps grouped into Setup/Main/Cleanup (see [BinarySequenceOutline] for the
/// assembly rule and [BinaryStepRef] for the type binding), plus the sequence
/// record's leading subprops (Parameters/Locals) and post-group subprops
/// (RecordResults/FailureAction/Requirements/RTS). Returns `[]` when [seqBytes]
/// is not an inflatable binary file or does not frame.
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

  // 0. the full sequence-record walk (see [_sequenceRecordWalks]). Feeds the
  // group-array surface, the byte accounting, and — on files whose sequences are
  // declared without the `[]/name/Objs/Seq/[i]` path records — sequence
  // discovery itself.
  final table = sharedTypeRecords ?? _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool);
  // The type-index base is a whole-file constant (see [deriveTypeIndexBase]):
  // derived once and threaded into every parser this pass builds, instead of
  // paying the O(recordRegionLength) anchor scan per construction.
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, table);
  final recordWalks = _sequenceRecordWalks(view, pool, recordRegionLength, table, typeIndexBase, sink);

  // 1. sequence declarations, with offsets (same root shape as
  // binarySequenceNames — see _isSequenceDeclaration)
  final sequenceDecls = <(int, String)>[];
  for (var at = 0; at + _minDeclarationBytes <= recordRegionLength; at++) {
    final decl = _objectDeclarationPath(body, view, pool, at, recordRegionLength);
    if (decl == null || !_isSequenceDeclaration(decl.$1)) continue;
    sequenceDecls.add((at, decl.$1[1]));
    sink.claim(at, decl.$2, _tierSemantic);
    // Record lead + flags byte, then the path words: pool references with zero
    // separators (see [_objectDeclarationPath]).
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
    // No declaration-path records: fall back to the walked sequence records as
    // the declaration set (offset + name), so the step/marker assembly works on
    // files whose declarations use the older layout. Where both exist the paths
    // are authoritative and the walk only adds content, and the two agree across
    // the rosetta twins.
    for (final walk in recordWalks) {
      sequenceDecls.add((walk.offset, walk.name));
    }
  }
  if (sequenceDecls.isEmpty) return const [];

  // 2. group-container markers (leaf records `Objs <group>`), with offsets
  final markers = <(int, StepGroup)>[];
  for (final record in _propertyRecordsFromBody(body, recordRegionLength)) {
    final group = StepGroup.byKey(record.name);
    if (group != null && record.typeName == SeqValueClass.objects.wire) {
      markers.add((record.offset, group));
    }
  }

  // 3. step references, with offsets (same detection discriminator as
  // binaryStepNames). The word after the Step token doubles as the step's
  // 1-based type-table index (see BinaryStepRef); detection keys on its
  // pool-string shape and the type binds only when the index lands in the table.
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
  // Second pass: each step's module fields from the name→value word pairs in its
  // span — this reference up to the next (or the region end). A token may sit at
  // several pool indices, hence index sets.
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
    // The step's TS descriptor node follows the four-word reference
    // `[Step][kind][name][container]`.
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
    // After the TS node the step's own data subprops follow as plain fields
    // (Measurement, PinMapPath) — walked with the same grammar and kept only for
    // twin-validated names (see [_stepDataSubPropNames]).
    final dataSubProps = <BinaryTypeField>[];
    if (tsSubProps.isNotEmpty && tsParser.lastStepTsEnd != null) {
      var cur = tsParser.lastStepTsEnd!;
      while (cur < spanEnd) {
        final mData = sink.mark();
        final field = tsParser.parseFieldAt(cur);
        if (field == null) break;
        final fieldEnd = _TypeBodyParser.debugLastEndOffset!;
        if (!_stepDataSubPropNames.contains(field.name) || fieldEnd > spanEnd) {
          // Parsed but rejected — its ops are dropped.
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
    for (final (_, name) in sequenceDecls) name: {for (final group in StepGroup.values) group: <BinaryStepRef>[]},
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
    StepGroup? group;
    for (final (markerOffset, markerGroup) in markers) {
      if (markerOffset < stepOffset) group = markerGroup;
    }
    final owner = sequenceAt(stepOffset);
    if (group == null) {
      // Step laid out before any group marker (7/294 corpus binaries): its
      // Setup/Main/Cleanup membership is not decodable from position, so it is
      // reported ungrouped rather than guessed.
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

  // Post-group subprops (RecordResults, FailureAction, Requirements, RTS) — the
  // fields that follow the Main/Setup/Cleanup group arrays.
  final tail = _sequenceTailSubProps(view, pool, recordRegionLength, table, typeIndexBase, sequenceDecls, sink);

  // The decoded group arrays (Main/Setup/Cleanup with their step elements) and
  // head comments from the full-record walk, first record per name.
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
          setup: outlines[name]![StepGroup.setup]!,
          main: outlines[name]![StepGroup.main]!,
          cleanup: outlines[name]![StepGroup.cleanup]!,
          ungrouped: ungrouped[name]!,
          leadingSubProps: leading[name] ?? const [],
          tailSubProps: tail[name] ?? const [],
          comment: comments[name],
          groupArrays: groups[name] ?? const [],
        ),
  ];
}

/// The sequence subprops that follow the Main/Setup/Cleanup group arrays, each
/// located by its expected class token immediately before its name token (with a
/// zero slot), parsed as a single field, and associated with the nearest
/// preceding sequence declaration:
///   * scalars `RecordResults` (Bool) and `FailureAction` (Num);
///   * `Requirements` (Obj) with its `Links` (Strs) child — the
///     requirement-traceability list;
///   * `RTS` (Obj) — the runtime/entry-point settings.
/// Each is validated against its expected shape ([_TailSubProp.accepts]), so a
/// coincidental anchor is rejected rather than guessed from position.
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
    for (final spec in _tailSubProps) (indicesOf(spec.name), indicesOf(spec.className.wire), spec),
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
        // Wrong shape or a duplicate — its ops are dropped.
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

/// A tail-subprop anchor spec: the name/class to anchor on and the shape test a
/// coincidental parse must fail.
class _TailSubProp {
  const _TailSubProp(this.name, this.className, this.accepts);
  final String name;
  final SeqValueClass className;
  final bool Function(BinaryTypeField) accepts;
}

/// The tail subprops recovered by [_sequenceTailSubProps], with their shape
/// tests: scalars must carry a value, `Requirements` must hold a `Links` child,
/// and `RTS` must be an object with children.
final _tailSubProps = <_TailSubProp>[
  _TailSubProp('RecordResults', SeqValueClass.boolean, (f) => f.name == 'RecordResults' && f.value != null),
  _TailSubProp('FailureAction', SeqValueClass.number, (f) => f.name == 'FailureAction' && f.value != null),
  _TailSubProp(
    'Requirements',
    SeqValueClass.object,
    (f) =>
        f.name == 'Requirements' &&
        f.valueClass == SeqValueClass.object &&
        f.children.any((c) => c.name == 'Links' && c.valueClass == SeqValueClass.strings),
  ),
  _TailSubProp(
    'RTS',
    SeqValueClass.object,
    (f) => f.name == 'RTS' && f.valueClass == SeqValueClass.object && f.children.isNotEmpty,
  ),
];

/// Decodes a step's `TS` subprops from the descriptor node at [at], immediately
/// after the four-word step reference — see [_TypeBodyParser.parseStepTs].
List<BinaryTypeField> _stepTsSubProps(_TypeBodyParser parser, int at) => parser.parseStepTs(at);

/// Locates each sequence record — `[Sequence][name][subpropCount]` — and decodes
/// the subprops preceding its `Main` group array (Parameters, Locals, …) with
/// the typedef field grammar. Keyed by sequence name; a sequence whose record is
/// not found or whose leading subprops do not frame is absent. The record is
/// distinct from the array-element declaration
/// (`[] / name / Objs / Seq / [i]`): it is the `Sequence`-classed object
/// carrying the sequence's own fields.
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
    // Keep only the known pre-Main subprops (Parameters, Locals — the two the
    // sequence layout places before the Main group array), as a leading prefix.
    // This drops any field the walk misparsed past the real leading region (a
    // field spuriously named after a structural token) and rejects a
    // coincidental [Sequence][name][small-number] triple whose first field is
    // neither.
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
    // `[Sequence][name][count]` record head and claim it with the kept run.
    sink.rollbackTailFrom(mWalk, keptEnd);
    sink.poolRef(at, u32(at));
    sink.poolRef(at + _u32Bytes, u32(at + _u32Bytes));
    sink.u32(at + 2 * _u32Bytes, count, _OpSource.model);
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

/// Finds the record/string boundary — the offset where the first packed string
/// table begins — without materializing the body's strings.
///
/// Equivalent to `_firstTableOffset(binaryStrings(body, minLength:
/// _minRunLength))`: the record region is scanned for the first chain of
/// ≥[_boundaryChainMin] NUL-adjacent printable runs. Tracking only each run's
/// (offset, length), returning as soon as the chain reaches the threshold, and
/// never touching the bytes past the boundary turns an O(body)-time,
/// O(strings)-allocation pass — run on every public lens via [_withLayout] —
/// into an O(boundary)-time, O(1)-allocation one. [_layoutFromBody] stays for
/// the recon views needing its string/sentinel/segment counts.
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
        // A run packed right after the previous one extends the chain, else
        // starts a new one — the same adjacency [_packedAfter] tests.
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

/// The largest contiguous string table in a binary TOF1 body: the longest run of
/// NUL-terminated strings packed back-to-back (each start == the previous end +
/// 1 NUL). The body holds such packed tables (a property-name/type table and
/// value/expression tables) that the records reference by index; name
/// byte-offsets are not referenced as u32. Which table this returns (names vs
/// values) depends on the file, so it is a recon view, not a labeled name pool.
/// Returns the ordered strings (offsets into the inflated body), or `[]` when
/// not an inflatable binary file or no table ≥5 entries is found.
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
/// single inflate of the body. The individual public helpers
/// ([binaryBodyStrings], [binaryStringTable], [analyzeBinaryBody],
/// [binaryNameTable]) each re-inflate; prefer this when several results are
/// needed at once so the zlib body is decompressed only once.
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
  /// doubles tied to their offset-referenced property name, with raw tag/type
  /// words.
  final List<BinaryNamedScalar> namedScalars;

  /// All distinct inline scalar `double` values (== [binaryScalarDoubles]) — a
  /// superset of [namedScalars]' values.
  final List<double> scalarDoubles;

  /// Consistently-referenced named-property record headers
  /// (== [binaryNamedRecords]): which property/container names the records cite
  /// and how often, with the raw consistent tag.
  final List<BinaryNamedRecord> namedRecords;
}

/// Inflates the binary TOF1 body once and runs the whole recon layer over it,
/// returning a [BinaryAnalysis]. Byte-for-byte equivalent to calling the
/// individual helpers, but decompresses the zlib stream a single time instead of
/// five-plus. Returns null when [seqBytes] is not an inflatable binary file.
///
/// A caller that has already inflated the body (`SeqDocument.parse`, which also
/// feeds the partial typed parse) can pass it as [body] to skip even that one
/// inflate; it must be the inflated body of [seqBytes].
BinaryAnalysis? analyzeBinary(Uint8List seqBytes, {Uint8List? body}) {
  body ??= inflateBinaryBody(seqBytes);
  if (body == null) return null;
  // One printable-run scan feeds every recon view. The pool-grade runs (min
  // length [_poolMinRunLength]) are scanned once; the table-grade list (min
  // length [_minRunLength]) is a filter of them, identical to a second scan at
  // the higher minimum because a run's extent does not depend on the threshold.
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

/// The single-decode bundle of one inflated binary TOF1 body: the body's bytes,
/// its record/string boundary, the ordered string pool, and the recorded decode
/// stream. Produced once by [_decodeBody] (or [_decodeSeq] from the container
/// bytes); every downstream fold — the byte-coverage accounting, the
/// undecoded-span census, and the write-model builder — consumes the same
/// instance, so none re-inflates the container, re-splits the pool, or re-runs
/// the decode passes.
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
/// [_DecodeSink], returned as a [_BodyDecode] bundle alongside the boundary and
/// the string pool it already built. Returns null when the body does not frame.
/// Not a parallel grammar: every op and claim comes from the same scan/parser
/// the decode lenses use.
///
/// The stream is the single product both downstream consumers fold: the writer's
/// re-serialization plan ([_buildWritePlan] over the ops — see
/// `seq_binary_write.dart`) and the byte-coverage metrics ([_tiersOfStream] over
/// the claims — see `seq_binary_metrics.dart`). One pass records both, so they
/// cannot disagree about what is decoded.
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
  // word-4-triple layout), decoded bodies (semantic), the fixed preamble before
  // each subsequent head (structural); blob sites collected during the same
  // parses demote below. Bodies are not decoded here — the span loop re-parses
  // each with the spec/ext collector armed, and only the head table is needed.
  final bodyOffsets = <String, int>{};
  final headOffsets = <String, int>{};
  final tripleOffsets = <String, int>{};
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
      // Tail: flag words ([BinaryTypeRecord.flags]) + trailing zeros +
      // delimiter (framed), or the `[1][idRef]` binary-only generation tail.
      // Every word past the flags is a zero the head scan verified (only
      // trailing zeros are dropped from [flags]), then the delimiter.
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
        // The binary-only generation tail `[1][idRef]`; the scan verified the
        // constant 1.
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
  // recorded during a parse trial that later bailed cannot upgrade unaccounted
  // bytes.
  for (final (start, end) in blobSpans) {
    sink.demote(start, end);
  }
  return _BodyDecode(body, recordRegionLength, pool, sink);
}

/// Tooling aid for grammar iteration, not part of the decode API: parses a
/// single field record at byte offset [at] of the inflated body with the
/// production field grammar (full type table in scope, so framed references
/// resolve), returning the decoded field and its end offset, or null when the
/// bytes do not frame.
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

/// Tooling aid (grammar iteration, like [binaryFieldAt]): parses a single field
/// record at [at] and, when it fails, returns the byte offset of the deepest
/// field attempt the parse made before bailing. Returns null when the field
/// parses or the file does not frame.
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
