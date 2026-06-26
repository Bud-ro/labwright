import 'dart:io';
import 'dart:typed_data';

import 'seq_format.dart';

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
    if (bytes[i] != 0x78) continue;
    final cmf = bytes[i + 1];
    if (cmf != 0x01 && cmf != 0x9c && cmf != 0xda) continue;
    try {
      final out = zlib.decode(bytes.sublist(i));
      if (out.length > 64) return Uint8List.fromList(out);
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

  /// The first few little-endian u32 words at the start of the record region
  /// (descriptive, grammar not yet decoded). Corpus-observed invariants across
  /// all 83 binary files: `leadingWords[2] == 1` (a constant marker) and
  /// `leadingWords[1] ∈ {16, 118}` (0x10 / 0x76 — a small fixed set, meaning not
  /// yet decoded); `leadingWords[0]` varies and is **not** a simple count.
  final List<int> leadingWords;

  @override
  String toString() => 'BinaryBodyLayout(inflated=$inflatedSize, '
      'recordRegion=$recordRegionLength, strings=$stringCount, '
      'sentinels=$sentinelCount, lead=$leadingWords)';
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
  final runs = binaryStrings(body, minLength: 3);
  final boundary = _firstTableOffset(runs);
  if (boundary == null) return null;
  final stringCount = runs.where((r) => r.offset >= boundary).length;
  return BinaryBodyLayout(
    inflatedSize: body.length,
    recordRegionLength: boundary,
    stringCount: stringCount,
    sentinelCount: _countSentinels(body, boundary),
    leadingWords: _leadingWords(body, 3),
  );
}

/// Reads up to [count] little-endian u32 words from the start of [body].
List<int> _leadingWords(Uint8List body, int count) {
  final out = <int>[];
  for (var i = 0; i + 3 < body.length && out.length < count; i += 4) {
    out.add(body[i] | body[i + 1] << 8 | body[i + 2] << 16 | body[i + 3] << 24);
  }
  return out;
}

/// The offset where the first chain of ≥[chainMin] NUL-adjacent runs begins —
/// the start of the string region. Null if no such chain exists.
int? _firstTableOffset(List<BinaryString> runs, {int chainMin = 5}) {
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

/// Counts `ff ff ff ff` words on 4-byte steps in `bytes[0, end)`.
int _countSentinels(Uint8List bytes, int end) {
  var n = 0;
  for (var i = 0; i + 3 < end; i += 4) {
    if (bytes[i] == 0xff &&
        bytes[i + 1] == 0xff &&
        bytes[i + 2] == 0xff &&
        bytes[i + 3] == 0xff) {
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
List<BinaryString> binaryStringTable(Uint8List seqBytes, {int minLength = 3}) {
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
  return best.length >= 5 ? best : const [];
}
