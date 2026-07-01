/// Decoder for the `TM80` block — LabVIEW's compact **type map** (LV 8.0+).
///
/// `TM80` is zlib-compressed; pass the **decompressed** bytes here.
///
/// Corpus finding (7593 TM80 sections; VIs typically have ~2): ~71%
/// (5367/7593) follow a short form whose length is exactly `4 + 2*count` — a
/// `[u16 count][u16 field1][count × u16 entry]` table. `field1` varies (most
/// often `2`). The remaining ~29% use a larger layout (often the VI's second
/// TM80 section) that is not yet decoded.
///
/// The 16-bit entries are type-map values; their exact meaning is **not yet
/// decoded** — they do NOT resolve cleanly as `VCTP` indices (only ~31% match
/// even after masking), so we expose them raw rather than mislabel them. Clean-
/// room, corpus-grounded: the short-form layout is corpus-verified; entry
/// semantics are open.
library;

import 'dart:typed_data';

/// A decoded `TM80` type map.
class ViTypeMap {
  const ViTypeMap({
    required this.rawLength,
    required this.isShortForm,
    required this.count,
    required this.field1,
    required this.entries,
  });

  /// The decompressed block length in bytes.
  final int rawLength;

  /// True when the block matched the short form (`length == 4 + 2*count`); the
  /// header + [entries] are then populated. False for the larger, not-yet-decoded
  /// layout — [entries] is empty in that case.
  final bool isShortForm;

  /// The `u16 @0` entry count (short form). 0 for the undecoded large form.
  final int count;

  /// The `u16 @2` header field (varies; most often `2`). Role not yet decoded.
  final int field1;

  /// The `count` 16-bit entries (short form). Raw values — semantics not yet
  /// decoded (they are NOT plain VCTP indices). Empty for the large form.
  final List<int> entries;
}

/// Decodes a decompressed `TM80` body. Total: returns null only when the buffer
/// is too short to hold the header.
ViTypeMap? decodeTypeMap(Uint8List b) {
  if (b.length < 4) return null;
  final count = (b[0] << 8) | b[1];
  final field1 = (b[2] << 8) | b[3];
  if (b.length == 4 + 2 * count) {
    final entries = <int>[
      for (var i = 0; i < count; i++) (b[4 + 2 * i] << 8) | b[4 + 2 * i + 1],
    ];
    return ViTypeMap(rawLength: b.length, isShortForm: true, count: count, field1: field1, entries: entries);
  }
  return ViTypeMap(rawLength: b.length, isShortForm: false, count: 0, field1: field1, entries: const []);
}
