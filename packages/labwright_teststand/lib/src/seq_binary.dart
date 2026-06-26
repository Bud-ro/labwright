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
