/// Decoder for the `TM80` block — LabVIEW's **data-space type map** (LV 8.0+).
///
/// `TM80` is stored compressed from LV 10.0 on and uncompressed on 8.0–9.x; pass
/// the **decompressed** bytes here. It is the successor of the pre-8.0 `DSTM`
/// (Data Space Type Map); the 8.0 type consolidation moved every type descriptor
/// into the `VCTP` pool, so `TM80` no longer carries type descriptors — it is a
/// list of **references into `VCTP`** with a per-reference flag word.
///
/// Layout (big-endian), each field a **variable-size u2p2** word — a `u16`, or,
/// when its top bit is set, a 32-bit value `((word & 0x7fff) << 16) | next-u16`:
///
///   `[u2p2 count][u2p2 indexShift]` then `count` × `[u2p2 flags]`
///
/// (`indexShift` is present only when `count > 0`.) Entry `i` maps to the `VCTP`
/// **top-level type** at index `indexShift + i`, and its `flags` word is a
/// bitfield describing that data item's role in the data space. Corpus-verified:
/// the walk consumes every byte of 7408/7408 compressed `TM80` bodies and 93/125
/// uncompressed ones; the remaining uncompressed bodies are the older inline
/// type-descriptor form (a leading `u16 0x0000`) that this walk does not frame.
///
/// The `flags` bit roles are clean-room, cross-referenced from the pylabview
/// project (not LabVIEW-verified): bit 0 `IsDSAlignPadding`, bit 2 `IsFPDCOOpData`,
/// bit 4 `IsChartHistory`, bit 7 `IsSubType`, bit 13 `HasSaveData` (the item's
/// default value is stored in the `DFDS` block). `DFDS` is the concatenation, in
/// type-map order, of the flattened default values of the entries whose flags
/// mark them as carrying save data — there is no offset table; each value's
/// extent is implied by its `VCTP` type's flattened width, read sequentially.
library;

import 'dart:typed_data';

/// A decoded `TM80` data-space type map.
class ViTypeMap {
  const ViTypeMap({
    required this.rawLength,
    required this.framesExactly,
    required this.indexShift,
    required this.entries,
  });

  /// The decompressed block length in bytes.
  final int rawLength;

  /// Whether the `[count][indexShift][flags…]` walk consumed the whole body
  /// exactly. True for the variable-field flag-list form; false for the older
  /// inline type-descriptor form and any truncated body ([entries] is then the
  /// partial list read before the walk ran out).
  final bool framesExactly;

  /// The `VCTP` top-level type index of `entries[0]`; entry `i` maps to index
  /// `indexShift + i`. 0 for an empty map.
  final int indexShift;

  /// The per-entry flag words in order (see the library doc for bit roles). One
  /// per mapped data item; `entries.length` is the map's `count`.
  final List<int> entries;
}

/// A variable-size u2p2 field read at [next] with its stored [width] (2 or 4).
typedef _Var = ({int value, int next, int width});

/// Reads a variable-size u2p2 word at [off]: a `u16`, or a 32-bit value when the
/// `u16`'s top bit is set (`((hi & 0x7fff) << 16) | lo`). Null when out of bounds.
_Var? _readVar(Uint8List b, int off) {
  if (off + 2 > b.length) return null;
  final hi = (b[off] << 8) | b[off + 1];
  if ((hi & 0x8000) == 0) return (value: hi, next: off + 2, width: 2);
  if (off + 4 > b.length) return null;
  final lo = (b[off + 2] << 8) | b[off + 3];
  return (value: ((hi & 0x7fff) << 16) | lo, next: off + 4, width: 4);
}

/// Writes [value] as a variable-size u2p2 word at its original [width] — the
/// exact inverse of [_readVar] (byte-identical to the field it decoded).
void _writeVar(BytesBuilder out, int value, int width) {
  if (width == 2) {
    out.add([value >> 8, value & 0xff]);
  } else {
    final hi = 0x8000 | (value >> 16);
    out.add([hi >> 8, hi & 0xff, (value >> 8) & 0xff, value & 0xff]);
  }
}

/// Decodes a decompressed `TM80` body. Total: returns null only when the buffer
/// is too short to hold the `count` field. [ViTypeMap.framesExactly] reports
/// whether the variable-field walk tiled the whole body.
ViTypeMap? decodeTypeMap(Uint8List bytes) {
  final c = _readVar(bytes, 0);
  if (c == null) return null;
  final count = c.value;
  var off = c.next;
  var indexShift = 0;
  if (count > 0) {
    final s = _readVar(bytes, off);
    if (s == null) {
      return ViTypeMap(rawLength: bytes.length, framesExactly: false, indexShift: 0, entries: const []);
    }
    indexShift = s.value;
    off = s.next;
  }
  final entries = <int>[];
  var ran = true;
  for (var i = 0; i < count; i++) {
    final e = _readVar(bytes, off);
    if (e == null) {
      ran = false;
      break;
    }
    entries.add(e.value);
    off = e.next;
  }
  return ViTypeMap(
    rawLength: bytes.length,
    framesExactly: ran && off == bytes.length,
    indexShift: indexShift,
    entries: entries,
  );
}

/// Whether a `TM80` [body] parses and tiles exactly under the variable-field
/// grammar, without allocating — the lean predicate for the content scoreboard.
/// Total; never throws.
bool typeMapFrames(Uint8List body) {
  final c = _readVar(body, 0);
  if (c == null) return false;
  final count = c.value;
  var off = c.next;
  if (count > 0) {
    final s = _readVar(body, off);
    if (s == null) return false;
    off = s.next;
  }
  for (var i = 0; i < count; i++) {
    final e = _readVar(body, off);
    if (e == null) return false;
    off = e.next;
  }
  return off == body.length;
}

/// Re-serializes a `TM80` [body] from its variable-field grammar, or returns null
/// when [body] does not tile under it (the older inline form, or a truncated
/// body). Total; never throws. Each field is re-emitted at the width it was read,
/// so the output is byte-identical to a well-formed [body] — the reconstruction
/// proves the framing rather than copying it.
Uint8List? reserializeTypeMap(Uint8List body) {
  final c = _readVar(body, 0);
  if (c == null) return null;
  final count = c.value;
  final out = BytesBuilder(copy: false);
  _writeVar(out, c.value, c.width);
  var off = c.next;
  if (count > 0) {
    final s = _readVar(body, off);
    if (s == null) return null;
    _writeVar(out, s.value, s.width);
    off = s.next;
  }
  for (var i = 0; i < count; i++) {
    final e = _readVar(body, off);
    if (e == null) return null;
    _writeVar(out, e.value, e.width);
    off = e.next;
  }
  if (off != body.length) return null;
  return out.toBytes();
}

/// The `TM80` flag bit signalling that a mapped data item's default value is
/// stored in the `DFDS` block (`HasSaveData`, clean-room from pylabview).
const int kTypeMapHasSaveData = 1 << 13;
