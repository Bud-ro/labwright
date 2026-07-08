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

  /// Re-emits the `[u16 field0][u16 field1]` header — the inverse of
  /// [decodeDataTypeHeap] for the dominant 4-byte header-only form, which it
  /// reproduces byte-exactly. The rare [isExtended] form carries an undecoded
  /// named-item table after the header, so this emits only the 4-byte header;
  /// it is shorter than the input there and the writer's round-trip guard keeps
  /// such a section copied (see `serializeBlockPayload`).
  Uint8List serialize() {
    final out = Uint8List(4);
    final bd = ByteData.sublistView(out);
    bd.setUint16(0, field0);
    bd.setUint16(2, field1);
    return out;
  }
}

/// Decodes a `DTHP` body. Null when too short for the header.
ViDataTypeHeap? decodeDataTypeHeap(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final extended = bytes.length > 4;
  return ViDataTypeHeap(
    rawLength: bytes.length,
    field0: (bytes[0] << 8) | bytes[1],
    field1: (bytes[2] << 8) | bytes[3],
    isExtended: extended,
    names: extended ? _scanNames(bytes, 4) : const [],
  );
}

/// Tolerant scan for `40xx [u8 len][printable name]` records from [from]. The
/// per-record prefix bytes vary, so we anchor on the `40xx` tag and validate the
/// length + printability rather than assume a fixed record stride.
List<String> _scanNames(Uint8List bytes, int from) {
  final out = <String>[];
  var pos = from;
  while (pos + 3 < bytes.length) {
    final len = bytes[pos + 2];
    final start = pos + 3;
    if (bytes[pos] == 0x40 &&
        bytes[pos + 1] <= 0x7f &&
        len > 0 &&
        start + len <= bytes.length &&
        _printable(bytes, start, start + len)) {
      out.add(String.fromCharCodes(bytes, start, start + len));
      pos = start + len;
      continue;
    }
    pos++;
  }
  return out;
}

bool _printable(Uint8List bytes, int start, int end) =>
    bytes.getRange(start, end).every((c) => c == 0x09 || c == 0x0a || c == 0x0d || (c >= 0x20 && c < 0x7f));
