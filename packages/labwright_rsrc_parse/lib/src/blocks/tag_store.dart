import 'dart:typed_data';

/// One entry of a `VITS` tag store: a named blob the editor/runtime attaches
/// to the VI (e.g. `NI.LV.ALL.VILastSavedTarget`, `NI_IconEditor_*` state).
class ViTagEntry {
  const ViTagEntry({required this.name, required this.payload, this.nested = false});

  /// The entry's tag name (length-prefixed ASCII in the store).
  final String name;

  /// The entry's payload bytes, retained verbatim. Per-tag content whose
  /// interior is not decoded further here; [payloadLength] is its length.
  final Uint8List payload;

  /// Whether the payload is a **nested, self-delimiting record stream** carried
  /// without a `u32 payloadLen` prefix, rather than a flat length-prefixed blob.
  /// A nested payload opens with the marker word `0x13008000` and runs to the
  /// store's end (see [ViTagStore]); [serialize] omits the length prefix for it.
  final bool nested;

  /// Byte length of the entry's payload (`payload.length`).
  int get payloadLength => payload.length;
}

/// A decoded `VITS` **VI tag store**: `[u32 count]` then `count` entries. An
/// entry is either **flat** — `[u32 nameLen][name][u32 payloadLen][payload]` —
/// or **nested** (see below).
///
/// Corpus-verified: 6056/7143 sections walk to the last byte with every name
/// printable ([walkComplete]) and re-serialize byte-exactly. The remaining 1087
/// sections stop the walk early — [entries] holds the entries recovered before
/// the mismatch (never fabricated) and [walkComplete] is false.
///
/// **Nested entry.** After some entry names the bytes are not a flat
/// length-prefixed blob but a self-delimiting record stream: the marker word
/// `0x13008000`, then `40xx`-tagged named items (`data string`,
/// `Load & Unload.lvclass`), `PTH0` path records, an icon-image record, and
/// further length-prefixed sub-records. There is no `u32 payloadLen` — reading
/// the post-name word as one lands far past the store end. A single-entry store
/// (`count == 1`) whose sole entry is nested is bounded by the store end, so its
/// payload runs to the last byte and re-serializes byte-exactly ([ViTagEntry.nested]);
/// 845 sections take this form (the `NI_IconEditor` and `NI.LV.All.SourceOnly`
/// editor-state entries). A multi-entry store with a leading nested entry
/// (1086 sections, 11.25 MB) has no length prefix to bound the first entry, so
/// the record grammar is not framed here and [walkComplete] is false; the writer
/// keeps those copied.
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

  /// Whether the `[len][name][len][payload]` walk consumed the whole body for
  /// exactly [declaredCount] entries.
  final bool walkComplete;

  /// Re-emits `[u32 count]` then each entry — the inverse of [decodeTagStore]. A
  /// flat entry is `[u32 nameLen][name][u32 payloadLen][payload]`; a nested entry
  /// ([ViTagEntry.nested]) is `[u32 nameLen][name][payload]` (no length prefix,
  /// its record stream is self-delimiting). Byte-identical to the parsed body
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
    // Nested single-entry store: the sole entry's payload is a self-delimiting
    // record stream (marker `0x13008000`) with no length prefix, so the word
    // read as `payloadLen` overflows the remaining bytes. It is bounded by the
    // store end; capture it byte-faithfully. Only when this is the one and only
    // entry — a multi-entry store gives no boundary to frame the nested stream.
    if (payloadLen > bytes.length - pos - 4 && declaredCount == 1 && entries.isEmpty) {
      entries.add(ViTagEntry(name: name, payload: Uint8List.sublistView(bytes, pos), nested: true));
      pos = bytes.length;
      break;
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
