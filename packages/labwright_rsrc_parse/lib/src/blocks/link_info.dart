import 'dart:typed_data';

/// A decoded `LIbd`/`LIvi`/`LIfp`/`LIds` **link-info** block: the linkage list
/// binding this VI to what its block diagram / VI / front panel / data space
/// reference — sub-VIs, classes, type definitions, and paths.
///
/// Corpus-verified layout (7583 of each across 7584 VIs): a u16 version (== 1),
/// then the 4-char root kind naming the linked section (`BDHP`, `LVIN`, `FPHP`,
/// `VIDS`), then a u32 entry count, then the entries. Each entry opens with a
/// u16 sub-count and a 4-char entry kind (`IUVI` linked VI instance, `VILB`
/// VI-library member, `VICC`/`TDCC` class/typedef cluster, `FPPI` panel item,
/// …) followed by name/path payloads. The full per-entry grammar is **not yet
/// decoded**; [linkedNames] and [pathCount] are recovered by a bounded scan of
/// the entry region (Pascal-string names + `PTH0` path markers), which is
/// enough to surface the VI's dependency list.
class ViLinkInfo {
  const ViLinkInfo({
    required this.version,
    required this.rootKind,
    required this.entryCount,
    required this.linkedNames,
    required this.pathCount,
  });

  /// The u16 at offset 0 (1 across the corpus).
  final int version;

  /// The 4-char tag of the section this link info describes
  /// (`BDHP`/`LVIN`/`FPHP`/`VIDS`).
  final String rootKind;

  /// Declared entry count (u32 at offset 6).
  final int entryCount;

  /// Names recovered from the entry region: linked VIs (`Foo.vi`), classes
  /// (`Bar.lvclass`), controls (`Baz.ctl`) — the dependency surface.
  final List<String> linkedNames;

  /// Number of embedded `PTH0` path records in the entry region.
  final int pathCount;

  bool get isEmpty => entryCount == 0 && linkedNames.isEmpty;
}

/// Decodes a link-info block ([ViLinkInfo]); null when [bytes] is too short to
/// carry the 12-byte header. Total over arbitrary input.
ViLinkInfo? decodeLinkInfo(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final view = ByteData.sublistView(bytes);
  final version = view.getUint16(0);
  final rootKind = String.fromCharCodes(bytes.sublist(2, 6));
  final entryCount = view.getUint32(6);

  final linkedNames = <String>[];
  var pathCount = 0;
  // Bounded scan of the entry region: a Pascal name is [u8 len][printable
  // ASCII] where the text looks like a file-ish name; a PTH0 marker is the
  // literal "PTH0". Grammar of the surrounding records is not yet decoded.
  for (var pos = 10; pos < bytes.length - 4; pos++) {
    if (bytes[pos] == 0x50 &&
        bytes[pos + 1] == 0x54 &&
        bytes[pos + 2] == 0x48 &&
        bytes[pos + 3] == 0x30) {
      pathCount++;
      pos += 3;
      continue;
    }
    final len = bytes[pos];
    if (len < 4 || len > 120 || pos + 1 + len > bytes.length) continue;
    var printable = true;
    for (var i = pos + 1; i <= pos + len; i++) {
      final byte = bytes[i];
      if (byte < 0x20 || byte >= 0x7f) {
        printable = false;
        break;
      }
    }
    if (!printable) continue;
    final text = String.fromCharCodes(bytes.sublist(pos + 1, pos + 1 + len));
    // Keep only file-ish names so scan noise never fabricates a dependency.
    if (RegExp(r'\.(vi|vim|vit|ctl|ctt|lvclass|lvlib|llb)$', caseSensitive: false)
        .hasMatch(text)) {
      if (!linkedNames.contains(text)) linkedNames.add(text);
      pos += len;
    }
  }
  return ViLinkInfo(
    version: version,
    rootKind: rootKind,
    entryCount: entryCount,
    linkedNames: linkedNames,
    pathCount: pathCount,
  );
}
