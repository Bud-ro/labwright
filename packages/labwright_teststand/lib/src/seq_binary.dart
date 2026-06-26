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

/// Record-delimiter sentinel: a u32 of four [_sentinelByte]s (`ff ff ff ff`).
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
      // Not a valid stream at this position — keep scanning.
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

  /// Count of `ff ff ff ff` words (on 4-byte steps) within the record region —
  /// the record-delimiter sentinels (recon).
  final int sentinelCount;

  /// Number of distinct packed string tables (maximal NUL-adjacent run chains)
  /// in the string region. Corpus-observed: ≥6 in all 83 binary files.
  final int segmentCount;

  /// The first few little-endian u32 words at the start of the record region
  /// (descriptive, grammar not yet decoded). Corpus-observed invariants across
  /// all 83 binary files: `leadingWords[2] == 1` (a constant marker) and
  /// `leadingWords[1] ∈ {16, 118}` (0x10 / 0x76 — a small fixed set); and
  /// `leadingWords[0]` varies and is **not** a simple count.
  // TODO: decode the meaning of leadingWords[1] (0x10 / 0x76 — likely a
  // kind/version tag) and leadingWords[0] — not yet determined.
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
  BinaryStringSegment? best;
  var bestHits = 0;
  for (final seg in binaryStringSegments(seqBytes)) {
    final texts = {for (final e in seg.entries) e.text};
    final hits = _modelNameTokens.where(texts.contains).length;
    if (hits > bestHits) {
      bestHits = hits;
      best = seg;
    }
  }
  return best;
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
  final runs = binaryStrings(body, minLength: minLength);
  // Longest chain of runs separated by exactly one byte (the NUL terminator).
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
