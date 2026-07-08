import 'dart:typed_data';

/// A decoded `LIbd`/`LIvi`/`LIfp`/`LIds` **link-info** block: the linkage list
/// binding this VI to what its block diagram / VI / front panel / data space
/// reference — sub-VIs, classes, type definitions, and paths.
///
/// Corpus-verified header (26136/26136 sections, 0 desyncs): a u16 version
/// (== 1), then the 4-char root kind naming the linked section (`BDHP`, `LVIN`,
/// `FPHP`, `VIDS`), then a u32 entry count, then the entries, then a u16
/// terminator (== 3). Each entry opens with `[u16 0x0002][4-char kind]` (`IUVI`
/// linked VI instance, `VILB` VI-library member, `VICC`/`TDCC` class/typedef
/// cluster, `VIVI`/`DSDS` VI/data-space link, `FPPI` panel item, …) followed by
/// a u32 link-type discriminant, name/`PTH0`-path records, and a trailer that
/// carries an optional library-identity sub-record. The trailer is variable and
/// data-dependent, so an entry's byte length is not separable from the entry
/// region alone; the byte-exact writer ([ViLinkInfoRaw]) reproduces the region
/// verbatim rather than splitting it. [linkedNames] and [pathCount] are
/// recovered by a bounded scan of the entry region (Pascal-string names +
/// `PTH0` path markers), which surfaces the VI's dependency list.
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
  // literal "PTH0". The surrounding per-record trailer grammar is not decoded
  // here; the scan surfaces the dependency names without it.
  for (var pos = 10; pos < bytes.length - 4; pos++) {
    if (bytes[pos] == 0x50 && bytes[pos + 1] == 0x54 && bytes[pos + 2] == 0x48 && bytes[pos + 3] == 0x30) {
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
    if (RegExp(r'\.(vi|vim|vit|ctl|ctt|lvclass|lvlib|llb)$', caseSensitive: false).hasMatch(text)) {
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

/// A byte-exact `LI*` model: the proven header/terminator framing plus the
/// entry region retained verbatim so [serialize] reproduces the section body.
///
/// The framing — [version] u16, [rootKind] 4cc, [entryCount] u32, [entryRegion],
/// [terminator] u16 — holds on every corpus section (26136/26136, 0 desyncs).
/// An entry's byte length is not separable from the region alone (its trailer is
/// variable and data-dependent — see [ViLinkInfo]), so the region is
/// deterministically bounded only when it holds at most one entry: [tiled] is
/// true for [entryCount] 0 (the region is empty) or 1 (the single entry occupies
/// the whole region up to [terminator]). For those the region is a leaf of known
/// extent and [serialize] round-trips; for [entryCount] ≥ 2 the interior record
/// boundaries are not recovered, so [tiled] is false and the writer keeps the
/// section copied.
class ViLinkInfoRaw {
  const ViLinkInfoRaw({
    required this.version,
    required this.rootKind,
    required this.entryCount,
    required this.entryRegion,
    required this.terminator,
    required this.tiled,
  });

  /// The u16 at offset 0 (1 across the corpus).
  final int version;

  /// The 4-char linked-section tag (`BDHP`/`LVIN`/`FPHP`/`VIDS`).
  final String rootKind;

  /// Declared entry count (u32 at offset 6).
  final int entryCount;

  /// The entry bytes between the header and the terminator (`[10, len-2)`),
  /// retained verbatim. Empty when [entryCount] is 0.
  final Uint8List entryRegion;

  /// The trailing u16 (3 across the corpus).
  final int terminator;

  /// Whether the section is deterministically bounded ([entryCount] ≤ 1 and a
  /// well-formed terminator), i.e. [serialize] reproduces it byte-for-byte.
  final bool tiled;

  /// Re-emits `[u16 version][rootKind][u32 entryCount][entryRegion][u16
  /// terminator]` — byte-identical to the parsed body.
  Uint8List serialize() {
    final out = Uint8List(12 + entryRegion.length);
    final view = ByteData.sublistView(out);
    view.setUint16(0, version);
    out.setRange(2, 6, rootKind.codeUnits);
    view.setUint32(6, entryCount);
    out.setRange(10, 10 + entryRegion.length, entryRegion);
    view.setUint16(10 + entryRegion.length, terminator);
    return out;
  }
}

/// Decodes a `LI*` body into a byte-exact [ViLinkInfoRaw]; null when [bytes]
/// cannot hold the 12-byte header+terminator. Total.
ViLinkInfoRaw? decodeLinkInfoRaw(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final view = ByteData.sublistView(bytes);
  final entryCount = view.getUint32(6);
  final terminator = view.getUint16(bytes.length - 2);
  return ViLinkInfoRaw(
    version: view.getUint16(0),
    rootKind: String.fromCharCodes(bytes.sublist(2, 6)),
    entryCount: entryCount,
    entryRegion: Uint8List.sublistView(bytes, 10, bytes.length - 2),
    terminator: terminator,
    tiled: entryCount <= 1 && terminator == 3,
  );
}
