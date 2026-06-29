/// Decoder for the `DTHP` block — the **data-type heap** table.
///
/// Corpus finding (7583 sections): 99.45% (7541/7583) are exactly **4 bytes** —
/// a `[u16 field0][u16 field1]` header (e.g. `0x0017,0x0004`). The two values are
/// small and do NOT equal the `VCTP` pool count, so their meaning is left
/// undecoded. (9 sections are 2 bytes — too short for the header, decode→null.)
/// A rare extended form (33 sections, up to ~1.8 KB) follows the header with
/// `40xx`-tagged named-item records — the VI's data-item / terminal names
/// (`Auto Stop`, `Mode`, `preTriggerSamples`), the same `40 21`-style naming
/// seen in the `ICON` terminal-name table.
///
/// Clean-room: the 4-byte framing is corpus-confirmed; the header-field meaning
/// and the extended-record framing are tentative (names are recovered by a
/// tolerant, printability-validated scan, not a byte-exact record walk).
library;

import 'dart:typed_data';

import 'block_catalog.dart' show BlockConfidence;

/// A decoded `DTHP` data-type heap.
class ViDataTypeHeap {
  const ViDataTypeHeap({
    required this.rawLength,
    required this.field0,
    required this.field1,
    required this.isExtended,
    required this.names,
  });

  /// The block length (4 for the dominant header-only form).
  final int rawLength;

  /// `u16 @0` — small; meaning not yet decoded (not the VCTP pool count).
  final int field0;

  /// `u16 @2` — small; meaning not yet decoded.
  final int field1;

  /// True when the block carries the rare extended named-item table after the
  /// 4-byte header.
  final bool isExtended;

  /// Data-item / terminal names recovered from the extended form (tolerant scan).
  /// Empty for the common header-only form.
  final List<String> names;

  /// Confidence in the 4-byte header *framing* (corpus: 99.45%).
  static const BlockConfidence framingConfidence = BlockConfidence.confirmed;

  /// Confidence in the header field *meanings* and the extended-record framing.
  static const BlockConfidence semanticsConfidence = BlockConfidence.tentative;
}

/// Decodes a `DTHP` body. Null when too short for the header.
ViDataTypeHeap? decodeDataTypeHeap(Uint8List b) {
  if (b.length < 4) return null;
  final field0 = (b[0] << 8) | b[1];
  final field1 = (b[2] << 8) | b[3];
  final extended = b.length > 4;
  return ViDataTypeHeap(
    rawLength: b.length,
    field0: field0,
    field1: field1,
    isExtended: extended,
    names: extended ? _scanNames(b, 4) : const [],
  );
}

/// Tolerant scan for `40xx [u8 len][printable name]` records from [from]. The
/// per-record prefix bytes vary, so we anchor on the `40xx` tag and validate the
/// length + printability rather than assume a fixed record stride.
List<String> _scanNames(Uint8List b, int from) {
  final out = <String>[];
  var i = from;
  while (i + 3 < b.length) {
    if (b[i] == 0x40 && b[i + 1] <= 0x7f) {
      final len = b[i + 2];
      final start = i + 3;
      if (len > 0 && start + len <= b.length && _printable(b, start, start + len)) {
        out.add(String.fromCharCodes(b.sublist(start, start + len)));
        i = start + len;
        continue;
      }
    }
    i++;
  }
  return out;
}

bool _printable(Uint8List b, int start, int end) {
  for (var i = start; i < end; i++) {
    final c = b[i];
    if (c != 0x09 && c != 0x0a && c != 0x0d && (c < 0x20 || c >= 0x7f)) return false;
  }
  return true;
}
