import 'dart:typed_data';

/// One entry of a `VITS` tag store: a named blob the editor/runtime attaches
/// to the VI (e.g. `NI.LV.ALL.VILastSavedTarget`, `NI_IconEditor_*` state).
class ViTagEntry {
  const ViTagEntry({required this.name, required this.payloadLength});

  /// The entry's tag name (length-prefixed ASCII in the store).
  final String name;

  /// Byte length of the entry's payload (payload content varies per tag and is
  /// not decoded further here).
  final int payloadLength;
}

/// A decoded `VITS` **VI tag store**: `[u32 count]` then `count` entries of
/// `[u32 nameLen][name][u32 payloadLen][payload]`.
///
/// Corpus-verified: 5219/7203 sections walk this grammar exactly to the last
/// byte with every name printable; the remainder carry a trailing variant that
/// stops the walk early — [walkComplete] is false there and [entries] holds
/// the entries recovered before the mismatch (never fabricated).
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
    pos += payloadLen;
    entries.add(ViTagEntry(name: name, payloadLength: payloadLen));
  }
  return ViTagStore(
    declaredCount: declaredCount,
    entries: entries,
    walkComplete: entries.length == declaredCount && pos == bytes.length,
  );
}
