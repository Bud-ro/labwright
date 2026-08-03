/// Decoder for the `DTHP` block — the **data-type heap** table.
///
/// Corpus finding (7583 sections): 99.45% (7541/7583) are exactly **4 bytes** —
/// a `[u16 heapTypeCount][u16 firstTopLevelIndex]` header (e.g. `0x0017,0x0004`).
/// (9 sections are 2 bytes — too short for the header, decode→null.) A rare
/// extended form (33 sections, up to ~1.8 KB) follows the header with
/// `40xx`-tagged named-item records — the VI's data-item / terminal names
/// (`Auto Stop`, `Mode`, `preTriggerSamples`), the same `40 21`-style naming
/// seen in the `ICON` terminal-name table.
///
/// The header **locates the heap's type-index space in the `VCTP` top-level
/// index list**: the heap owns [ViDataTypeHeap.heapTypeCount] consecutive
/// top-level entries beginning at the 1-based index
/// [ViDataTypeHeap.firstTopLevelIndex], and a heap object's
/// `typeDescIndex` is 1-based **within that run** — so index `i` resolves to
/// the top-level entry at 0-based position `firstTopLevelIndex + i - 2`
/// ([viTypeIndexBase]). The run always reaches the end of the list:
/// `firstTopLevelIndex + heapTypeCount - 1 == topLevel.length` on **7,481 of
/// 7,481** corpus VIs carrying both a 4-byte `DTHP` and a framing top-level
/// list. Of the 7,467 of those that carry any heap type index, every single
/// one has a minimum index of exactly 1 and a maximum no greater than
/// [ViDataTypeHeap.heapTypeCount] (0 out of range); the maximum *equals* the
/// count on 6,464, falls one short on 926 and two short on 71.
///
/// Independent validation of the base this yields is in `resolveDataSpaceTypes`.
///
/// Clean-room: the 4-byte framing and the index-space law are corpus-confirmed;
/// the extended-record framing is tentative (names are recovered by a tolerant,
/// printability-validated scan, not a byte-exact record walk).
library;

import 'dart:typed_data';

import 'block_catalog.dart' show BlockConfidence;

/// A decoded `DTHP` data-type heap.
class ViDataTypeHeap {
  const ViDataTypeHeap({
    required this.rawLength,
    required this.heapTypeCount,
    required this.firstTopLevelIndex,
    required this.isExtended,
    required this.names,
  });

  /// The block length (4 for the dominant header-only form).
  final int rawLength;

  /// `u16 @0` — how many `VCTP` top-level entries the heap's type-index space
  /// spans (see the library doc).
  final int heapTypeCount;

  /// `u16 @2` — the **1-based** `VCTP` top-level index the heap's type-index
  /// space starts at; a heap `typeDescIndex` of 1 addresses this entry.
  final int firstTopLevelIndex;

  /// True when the block carries the rare extended named-item table after the
  /// 4-byte header.
  final bool isExtended;

  /// Data-item / terminal names recovered from the extended form (tolerant scan).
  /// Empty for the common header-only form.
  final List<String> names;

  /// Confidence in the 4-byte header *framing* (corpus: 99.45%).
  static const BlockConfidence framingConfidence = BlockConfidence.confirmed;

  /// The additive base a heap `typeDescIndex` resolves through: the 0-based
  /// top-level position of index `i` is `viTypeIndexBase + i` (see the library
  /// doc). Negative only for the never-observed `firstTopLevelIndex < 2`.
  int get viTypeIndexBase => firstTopLevelIndex - 2;

  /// Re-emits the `[u16 heapTypeCount][u16 firstTopLevelIndex]` header — the inverse of
  /// [decodeDataTypeHeap] for the dominant 4-byte header-only form, which it
  /// reproduces byte-exactly. The rare [isExtended] form carries an undecoded
  /// named-item table after the header, so this emits only the 4-byte header;
  /// it is shorter than the input there and the writer's round-trip guard keeps
  /// such a section copied (see `serializeBlockPayload`).
  Uint8List serialize() {
    final out = Uint8List(4);
    final bd = ByteData.sublistView(out);
    bd.setUint16(0, heapTypeCount);
    bd.setUint16(2, firstTopLevelIndex);
    return out;
  }
}

/// Decodes a `DTHP` body. Null when too short for the header.
ViDataTypeHeap? decodeDataTypeHeap(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final extended = bytes.length > 4;
  return ViDataTypeHeap(
    rawLength: bytes.length,
    heapTypeCount: (bytes[0] << 8) | bytes[1],
    firstTopLevelIndex: (bytes[2] << 8) | bytes[3],
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
