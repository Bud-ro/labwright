import 'dart:typed_data';

/// One entry of a `VITS` tag store: a named blob the editor/runtime attaches
/// to the VI (e.g. `NI.LV.ALL.VILastSavedTarget`, `NI_IconEditor` state).
class ViTagEntry {
  const ViTagEntry({required this.name, required this.payload, this.nested = false});

  /// The entry's tag name (length-prefixed ASCII in the store).
  final String name;

  /// The entry's payload bytes, retained verbatim. Per-tag content whose
  /// interior is not decoded further here; [payloadLength] is its length.
  final Uint8List payload;

  /// Whether the payload is a **nested, self-delimiting variant record** carried
  /// without a `u32 payloadLen` prefix, rather than a flat length-prefixed blob.
  /// A nested payload opens with a variant marker word (`byte[2] == 0x80`, e.g.
  /// `0x13008000`); its extent is fixed by the variant framing (see [ViTagStore]).
  /// [serialize] omits the length prefix for it.
  final bool nested;

  /// Byte length of the entry's payload (`payload.length`).
  int get payloadLength => payload.length;
}

/// A decoded `VITS` **VI tag store**: `[u32 count]` then `count` entries. An
/// entry is either **flat** — `[u32 nameLen][name][u32 payloadLen][payload]` —
/// or **nested** (see below).
///
/// **Nested entry.** After some entry names the bytes are not a flat
/// length-prefixed blob but a self-delimiting flattened-variant record: a marker
/// word whose third byte is `0x80` (e.g. `0x13008000` / `0x12008004`), a
/// `u32` variant field-count, a `u16`-length-prefixed field descriptor (a
/// `xx 30 ff ff ff ff` type spec plus an inline field name such as `Data`,
/// `TagName`), then the field value. There is no `u32 payloadLen` — reading the
/// post-name word as one lands far past the store end. Two nested value shapes
/// are framed here:
///
/// * **Length-prefixed value** (single-field variant, `variantCount == 1`): a
///   `u32 contentLen` at offset `12 + fieldDescLen` from the entry start, then
///   `contentLen` content bytes and a `u32` trailer, so the entry spans
///   `20 + fieldDescLen + contentLen` bytes. This shape carries the
///   `NI_IconEditor` icon image, the `_ni_LastKnownOwningLVClassCluster` class
///   cluster, `NI.LV.ALL.VILastSavedTarget`, and `Localized` entries.
/// * **Source-only flag** (`NI.LV.All.SourceOnly`): a fixed 21-byte boolean-flag
///   variant — a 4-byte marker then the constant tail
///   `00 00 00 01 00 04 00 21 00 01 00 00 01 00 00 00 00`.
///
/// A store's final nested entry is bounded by the store end. Each earlier nested
/// entry is bounded by the framing above, its end cross-checked to land on the
/// next entry's `[u32 nameLen][printable name]` header. A store whose every
/// entry is framed (flat, or a nested shape above) walks to the last byte and
/// re-serializes byte-exactly ([walkComplete]); a store carrying a nested shape
/// not framed here (e.g. a multi-field `NI.LV.ALL.goodSyntaxTargets` in a
/// non-final position) stops the walk early — [entries] holds the entries
/// recovered before the stop (never fabricated) and [walkComplete] is false.
class ViTagStore {
  const ViTagStore({
    required this.declaredCount,
    required this.entries,
    required this.walkComplete,
  });

  /// The u32 entry count at offset 0.
  final int declaredCount;

  /// Entries recovered in order (all of them when [walkComplete]).
  final List<ViTagEntry> entries;

  /// Whether the entry walk consumed the whole body for exactly [declaredCount]
  /// entries.
  final bool walkComplete;

  /// Re-emits `[u32 count]` then each entry — the inverse of [decodeTagStore]. A
  /// flat entry is `[u32 nameLen][name][u32 payloadLen][payload]`; a nested entry
  /// ([ViTagEntry.nested]) is `[u32 nameLen][name][payload]` (no length prefix,
  /// its variant record is self-delimiting). Byte-identical to the parsed body
  /// **iff** the walk consumed the whole body ([walkComplete]); an entry's name
  /// and payload are retained verbatim, so a complete walk round-trips exactly. A
  /// section that stopped early re-emits shorter than the input; the writer's
  /// round-trip guard keeps it copied (see `serializeBlockPayload`).
  Uint8List serialize() {
    var size = 4;
    for (final e in entries) {
      size += 4 + e.name.length + (e.nested ? 0 : 4) + e.payload.length;
    }
    final out = Uint8List(size);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, declaredCount);
    var pos = 4;
    for (final e in entries) {
      bd.setUint32(pos, e.name.length);
      pos += 4;
      out.setRange(pos, pos + e.name.length, e.name.codeUnits);
      pos += e.name.length;
      if (!e.nested) {
        bd.setUint32(pos, e.payload.length);
        pos += 4;
      }
      out.setRange(pos, pos + e.payload.length, e.payload);
      pos += e.payload.length;
    }
    return out;
  }
}

/// The `NI.LV.All.SourceOnly` boolean-flag variant tail — the 17 bytes that
/// follow the 4-byte variant marker in that entry's fixed 21-byte record.
final Uint8List _sourceOnlyTail = Uint8List.fromList(const [
  0x00, 0x00, 0x00, 0x01, // variant field-count = 1
  0x00, 0x04, 0x00, 0x21, 0x00, 0x01, // u16 fieldDescLen = 4, then the field desc
  0x00, 0x00, // zero word
  0x01, 0x00, 0x00, 0x00, 0x00, // boolean value + trailer
]);

/// Total byte length of the [_sourceOnlyTail] record including its 4-byte marker.
const int _sourceOnlyLen = 21;

/// Whether [bytes] at [off] begins a valid entry header — `[u32 nameLen][name]`
/// with a printable ASCII name of a plausible length — used to cross-check a
/// nested entry's computed end lands on the next entry rather than mid-payload.
bool _validEntryHeader(Uint8List bytes, int off, int end) {
  if (off + 4 > end) return false;
  final nameLen = ByteData.sublistView(bytes).getUint32(off);
  if (nameLen < 1 || nameLen > 128 || off + 4 + nameLen > end) return false;
  for (var i = off + 4; i < off + 4 + nameLen; i++) {
    final b = bytes[i];
    if (b < 0x20 || b >= 0x7f) return false;
  }
  return true;
}

/// End offset of a non-final nested entry whose value begins at [s], or null when
/// the framing does not bound it. Frames the length-prefixed single-field variant
/// and the fixed `SourceOnly` flag; a computed end must land on the next entry's
/// header ([_validEntryHeader]) so a mis-read never mis-tiles.
int? _nestedEntryEnd(Uint8List bytes, int s, int storeEnd) {
  if (s + 12 > storeEnd || bytes[s + 2] != 0x80) return null;
  final view = ByteData.sublistView(bytes);
  // Length-prefixed single-field variant: contentLen sits at 12 + fieldDescLen.
  if (view.getUint32(s + 4) == 1) {
    final fieldDescLen = view.getUint16(s + 8);
    final lenAt = s + 12 + fieldDescLen;
    if (lenAt + 4 <= storeEnd) {
      final contentLen = view.getUint32(lenAt);
      final end = lenAt + 4 + contentLen + 4;
      if (end <= storeEnd && _validEntryHeader(bytes, end, storeEnd)) return end;
    }
  }
  // Fixed SourceOnly boolean-flag record.
  if (s + _sourceOnlyLen <= storeEnd) {
    var match = true;
    for (var i = 0; i < _sourceOnlyTail.length; i++) {
      if (bytes[s + 4 + i] != _sourceOnlyTail[i]) {
        match = false;
        break;
      }
    }
    if (match && _validEntryHeader(bytes, s + _sourceOnlyLen, storeEnd)) {
      return s + _sourceOnlyLen;
    }
  }
  return null;
}

/// Decodes a `VITS` tag store; null when [bytes] cannot hold the count. Total.
ViTagStore? decodeTagStore(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final view = ByteData.sublistView(bytes);
  final declaredCount = view.getUint32(0);
  if (declaredCount > 65536) {
    return ViTagStore(declaredCount: declaredCount, entries: const [], walkComplete: false);
  }
  final entries = <ViTagEntry>[];
  var pos = 4;
  while (entries.length < declaredCount && pos + 4 <= bytes.length) {
    final nameLen = view.getUint32(pos);
    pos += 4;
    if (nameLen > 4096 || pos + nameLen > bytes.length) break;
    var printable = true;
    for (var i = pos; i < pos + nameLen; i++) {
      final byte = bytes[i];
      if (byte < 0x20 || byte >= 0x7f) {
        printable = false;
        break;
      }
    }
    if (!printable) break;
    final name = String.fromCharCodes(bytes.sublist(pos, pos + nameLen));
    pos += nameLen;
    if (pos + 4 > bytes.length) break;
    final payloadLen = view.getUint32(pos);
    if (payloadLen > bytes.length - pos - 4) {
      // Nested entry: the post-name word is a variant marker, not a payload
      // length. The store's final entry runs to the store end; an earlier nested
      // entry is bounded by its variant framing ([_nestedEntryEnd]).
      final isLast = entries.length == declaredCount - 1;
      final int end;
      if (isLast) {
        end = bytes.length;
      } else {
        final bounded = _nestedEntryEnd(bytes, pos, bytes.length);
        if (bounded == null) break;
        end = bounded;
      }
      entries.add(ViTagEntry(name: name, payload: Uint8List.sublistView(bytes, pos, end), nested: true));
      pos = end;
      continue;
    }
    pos += 4;
    if (payloadLen > bytes.length - pos) break;
    final payload = Uint8List.sublistView(bytes, pos, pos + payloadLen);
    pos += payloadLen;
    entries.add(ViTagEntry(name: name, payload: payload));
  }
  return ViTagStore(
    declaredCount: declaredCount,
    entries: entries,
    walkComplete: entries.length == declaredCount && pos == bytes.length,
  );
}
