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
