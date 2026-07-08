import 'dart:typed_data';

/// One entry of a `VITS` tag store: a named blob the editor/runtime attaches
/// to the VI (e.g. `NI.LV.ALL.VILastSavedTarget`, `NI_IconEditor_*` state).
class ViTagEntry {
  const ViTagEntry({required this.name, required this.payload});

  /// The entry's tag name (length-prefixed ASCII in the store).
  final String name;

  /// The entry's payload bytes, retained verbatim. Per-tag content whose
  /// interior is not decoded further here; [payloadLength] is its length.
  final Uint8List payload;

  /// Byte length of the entry's payload (`payload.length`).
  int get payloadLength => payload.length;
}

/// A decoded `VITS` **VI tag store**: `[u32 count]` then `count` entries of
/// `[u32 nameLen][name][u32 payloadLen][payload]`.
///
/// Corpus-verified: 5211/7143 sections walk this grammar exactly to the last
/// byte with every name printable ([walkComplete]); those re-serialize
/// byte-exactly. The remaining 1932 sections stop the walk early — [entries]
/// holds the entries recovered before the mismatch (never fabricated) and
/// [walkComplete] is false.
///
/// The early stop is a per-entry interior that is not a flat length-prefixed
/// blob: after a first entry name (predominantly `NI_IconEditor`) the bytes are
/// a nested record stream — a `13 xx 80 xx …` header, `40xx`-tagged named items
/// (`data string`, `Load & Unload.lvclass`), `PTH0` path records, and further
/// length-prefixed sub-records — so reading the post-name `u32` as a payload
/// length lands far past the block end. Those sub-record bytes (18.25 MB, the
/// `NI_IconEditor` editor-state entries) are not decoded here; the writer keeps
/// them copied.
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

  /// Re-emits `[u32 count]` then `[u32 nameLen][name][u32 payloadLen][payload]`
  /// per entry — the inverse of [decodeTagStore]. Byte-identical to the parsed
  /// body **iff** the walk consumed the whole body ([walkComplete]); an entry's
  /// name and payload are retained verbatim, so a complete walk round-trips
  /// exactly. A section that stopped early (its per-entry interior does not fit
  /// the flat `[nameLen][name][payloadLen][payload]` grammar) re-emits shorter
  /// than the input; the writer's round-trip guard keeps it copied (see
  /// `serializeBlockPayload`).
  Uint8List serialize() {
    var size = 4;
    for (final e in entries) {
      size += 8 + e.name.length + e.payload.length;
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
      bd.setUint32(pos, e.payload.length);
      pos += 4;
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
