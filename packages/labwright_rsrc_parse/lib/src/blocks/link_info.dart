import 'dart:typed_data';

import 'version_word.dart';

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

/// A byte-exact `LI*` model: the header/terminator framing plus the entry region
/// retained verbatim so [serialize] reproduces the section body.
///
/// The framing — [version] u16, [rootKind] 4cc, then (on pre-14.0 files) a
/// self-name `PStr` and an `[u16 wordlen][2·wordlen]` header, then an entry
/// `count` (u32), then the entries, then a u16 [terminator] — holds on every
/// corpus section (26136/26136, 0 desyncs). The entry region is retained in
/// [entryRegion] and re-emitted verbatim, so [serialize] round-trips regardless
/// of the interior grammar.
///
/// [tiled] records whether the interior entry boundaries are *recovered*, which
/// is what lets the writer credit the region as model-sourced rather than an
/// opaque copy:
///  * `count` 0 or 1 — the region is empty or a single entry whose boundary is
///    the whole region up to [terminator]; [tiled] is true.
///  * `count` ≥ 2 — [tiled] is true only when a forward walk of the per-entry
///    grammar consumes every entry to exactly the [terminator] with each entry
///    opening on the `0x0002` marker (the boundary checksum). The walk is
///    version-gated (many field widths depend on the LabVIEW save version, which
///    is not in the block), so a null version leaves ≥ 2-entry sections untiled.
///
/// The per-entry grammar (reference: pylabview `LVlinkinfo`, corpus-verified):
/// each entry is `[u16 0x0002][4cc kind][body]`. Bodies for the covered kinds
/// (`VILB`/`VIVI`/`VICC`/`VIPV`/`VIPR`/`VIAV`/`BSVR`/`IUVI`/`PUPV`/`SVVI`/
/// `TDCC`/`DSDS`/`DSSV`/`DSEF`/`NEXF`/`XNXI`/`VIXN`/`FPPI`/`DDPI`/`VRPI`/`DyOM`/
/// `PNOM`/`DRPI`/`DOPI`/`VIPI`) are built from self-delimiting records — a
/// length-prefixed qualified name, a `PTH0` path (`[u32 len]`-framed), an offset
/// list (`[u32 count][u32…]`), a type-id, version-gated link-save flags, an
/// external-function / GObject-interface / UDClass-API-cache record, and a
/// `VILinkRefInfo` block whose library-identity/GUID bytes are retained opaque.
/// Sections whose entries use a kind outside that set, or a version variant the
/// walk does not reproduce, do not reach the terminator and stay copied.
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

  /// The u32 at offset 6, retained verbatim so [serialize] is exact. This is the
  /// entry count only for the count-first header form; for a library self-name
  /// header it is the leading bytes of that name.
  final int entryCount;

  /// The entry bytes between the header and the terminator (`[10, len-2)`),
  /// retained verbatim. Empty when the section carries no entries.
  final Uint8List entryRegion;

  /// The trailing u16 (3 across the corpus).
  final int terminator;

  /// Whether the interior entry boundaries are recovered (see the class doc), so
  /// [serialize] reproducing the section is a model-sourced round-trip rather
  /// than an opaque copy. [serialize] is byte-exact either way.
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
///
/// [version] is the file's LabVIEW save version (from `vers`), used to size the
/// version-gated per-entry fields when recovering ≥ 2-entry boundaries; without
/// it only the 0/1-entry forms tile (see [ViLinkInfoRaw.tiled]).
ViLinkInfoRaw? decodeLinkInfoRaw(Uint8List bytes, {ViVersionWord? version}) {
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
    tiled: terminator == 3 && _tilesLinkInfo(bytes, version),
  );
}

/// Whether the `LI*` body [bytes] tiles: the header resolves to a `count` and
/// entry-list start, and either the count is ≤ 1 (a known-extent leaf) or a
/// forward walk consumes all `count` entries to exactly the terminator. Total.
bool _tilesLinkInfo(Uint8List bytes, ViVersionWord? version) {
  final termOff = bytes.length - 2;
  final view = ByteData.sublistView(bytes);
  final u32at6 = view.getUint32(6);

  // Header form V (version-gated, pylabview `LinkObjRefs`): `[u16 1][4cc root]`,
  // then on pre-14.0 files a `PStr` (pad-to-2) self-name + `[u16 wordlen][2·
  // wordlen bytes]` header, then `[u32 count]`, then entries. Needs the file
  // version to size the pre-14 header and the ≥ 2-entry walk.
  if (version != null) {
    var pos = 6;
    var ok = true;
    if (version.major < 14) {
      final nameLen = bytes[6];
      pos = 7 + nameLen;
      if ((nameLen + 1).isOdd) pos += 1; // pad-to-2
      if (pos + 2 > bytes.length) {
        ok = false;
      } else {
        pos += 2 + 2 * view.getUint16(pos);
      }
    }
    if (ok && pos + 4 <= bytes.length) {
      final countV = view.getUint32(pos);
      if (countV <= 0x10000 && _tilesFrom(bytes, version, countV, pos + 4, termOff)) {
        return true;
      }
    }
  }
  // Header form A: `[u32 count]` at offset 6, entries at 10.
  if (u32at6 <= 0x10000 && _tilesFrom(bytes, version, u32at6, 10, termOff)) {
    return true;
  }
  // Header form B (library-owned VI): `[u8 nameLen][name]` padded to 4, a u16,
  // then `[u32 count]`, then entries.
  if (bytes[6] != 0) {
    var pos = 7 + bytes[6];
    if (pos % 4 != 0) pos += 4 - (pos % 4);
    pos += 2;
    if (pos + 4 <= bytes.length) {
      final countB = view.getUint32(pos);
      if (countB <= 0x10000 && _tilesFrom(bytes, version, countB, pos + 4, termOff)) {
        return true;
      }
    }
  }
  return false;
}

/// Tiles [count] entries starting at [start]; true iff they consume to exactly
/// [termOff]. A 0/1-entry region is a known-extent leaf (true without walking);
/// ≥ 2 entries require the version-gated walk to certify the boundaries.
bool _tilesFrom(Uint8List bytes, ViVersionWord? version, int count, int start, int termOff) {
  if (count <= 1) return start <= termOff;
  if (version == null) return false;
  final c = _LiCursor(bytes, version.major, version.minor, version.patch)..p = start;
  for (var i = 0; i < count; i++) {
    if (c.p + 6 > termOff || c.u16() != 2) return false;
    final kind = c.tag4();
    c.skip(4);
    _liEntry(c, kind);
    if (!c.ok) return false;
  }
  return c.ok && c.p == termOff;
}

/// A forward cursor over a `LI*` body with the absolute-offset alignment the
/// entry grammar uses. Any out-of-bounds read clears [ok] and stops the walk.
class _LiCursor {
  _LiCursor(this.b, this.major, this.minor, this.patch);
  final Uint8List b;
  final int major, minor, patch;
  int p = 0;
  bool ok = true;

  /// Byte length of the most recent `PTH0` path read by [_liPathRef] (-1 before
  /// any). A `HeapToVI` link stores its target either as a non-empty path or as
  /// an empty path followed by a heap offset list; [_liHeapToVi] reads this to
  /// tell the two apart.
  int lastPathLen = -1;

  /// Whether the trailing `viLSPathRef` of the last [_liHeapToVi] was empty, so
  /// the entry carries a heap offset list in its place.
  bool heapPathEmpty = false;

  /// Whether the file version is ≥ `a.c.d` (release stage always satisfies the
  /// small stage thresholds pylabview uses, so a major/minor/patch compare is
  /// sufficient across the corpus).
  bool ge(int a, int c, int d) {
    if (major != a) return major > a;
    if (minor != c) return minor > c;
    return patch >= d;
  }

  int u8() {
    if (p + 1 > b.length) {
      ok = false;
      return 0;
    }
    return b[p++];
  }

  int u16() {
    if (p + 2 > b.length) {
      ok = false;
      return 0;
    }
    final v = (b[p] << 8) | b[p + 1];
    p += 2;
    return v;
  }

  int u32() {
    if (p + 4 > b.length) {
      ok = false;
      return 0;
    }
    final v = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    p += 4;
    return v;
  }

  void skip(int n) {
    if (n < 0 || p + n > b.length) {
      ok = false;
      return;
    }
    p += n;
  }

  void pad(int align) {
    final m = p % align;
    if (m > 0) skip(align - m);
  }

  String tag4() {
    if (p + 4 > b.length) {
      ok = false;
      return '';
    }
    return String.fromCharCodes(b, p, p + 4);
  }
}

// The per-entry grammar. Each helper consumes one self-delimiting record; an
// over-read clears the cursor's `ok`. Reference: pylabview `LVlinkinfo`.

/// `[u32 count][count × [u8 len][bytes]]`.
void _liQualName(_LiCursor c) {
  final count = c.u32();
  if (!c.ok || count > 4096) {
    c.ok = false;
    return;
  }
  for (var i = 0; i < count; i++) {
    c.skip(c.u8());
    if (!c.ok) return;
  }
}

/// `PTH0`/`PTH1`/`PTH2` path: 4cc ident + `[u32 len]` + `len` self-framed bytes.
void _liPathRef(_LiCursor c) {
  final id = c.tag4();
  if (!c.ok) return;
  if (id != 'PTH0' && id != 'PTH1' && id != 'PTH2') {
    c.ok = false;
    return;
  }
  c.skip(4);
  final len = c.u32();
  c.lastPathLen = len;
  c.skip(len);
}

/// `[u8 len][bytes]` padded so `(len+1)` is even (pylabview `readPStr` padto 2).
void _liPStr(_LiCursor c) {
  final n = c.u8();
  c.skip(n);
  if ((n + 1).isOdd) c.skip(1);
}

/// `[u32 len][bytes]` (pylabview `readLStr` padto 1 — no trailing pad).
void _liLStr(_LiCursor c) {
  final n = c.u32();
  if (!c.ok || n > 0x20000000) {
    c.ok = false;
    return;
  }
  c.skip(n);
}

/// Variable-size type id: a u16, extended by a second u16 when the high bit set.
void _liU2p2(_LiCursor c) {
  if ((c.u16() & 0x8000) != 0) c.u16();
}

/// Qualified name + `PTH0` path + a version-gated link-save flag.
void _liBasic(_LiCursor c) {
  c.pad(4);
  _liQualName(c);
  if (!c.ok) return;
  c.pad(2);
  _liPathRef(c);
  if (!c.ok) return;
  if (c.ge(8, 6, 0)) {
    c.skip(4);
  } else if (c.ge(8, 5, 0)) {
    c.skip(1);
  }
}

/// VI-link reference info: a version-gated flag byte selecting an inline form or
/// an expanded form whose library-version/identity words are retained opaque.
void _liViLinkRef(_LiCursor c) {
  var flagBt = 0xff;
  if (c.ge(14, 0, 0)) flagBt = c.u8();
  if (!c.ok || flagBt != 0xff) return;
  if (c.ge(8, 0, 0)) c.skip(12); // field4(4) + libVersion(8)
  if (c.ge(6, 0, 0)) c.skip(12); // three identity words (opaque)
}

/// Basic link-save info + a type id + VI-link ref info + version-gated flags.
void _liTyped(_LiCursor c) {
  if (!c.ge(8, 0, 0)) {
    c.ok = false;
    return;
  }
  _liBasic(c);
  if (!c.ok) return;
  _liU2p2(c);
  if (!c.ok) return;
  _liViLinkRef(c);
  if (!c.ok) return;
  if (c.ge(12, 0, 0)) c.skip(4);
}

/// `[u32 count][count × u32]` offset list.
void _liOffList(_LiCursor c) {
  final n = c.u32();
  if (!c.ok || n > 1 << 20) {
    c.ok = false;
    return;
  }
  c.skip(4 * n);
}

void _liOffsetSave(_LiCursor c) {
  _liTyped(c);
  if (!c.ok) return;
  if (c.ge(8, 2, 0)) _liOffList(c);
}

void _liHeapToVi(_LiCursor c) {
  c.heapPathEmpty = false;
  _liOffsetSave(c);
  if (!c.ok) return;
  if (c.ge(8, 2, 0)) {
    _liPathRef(c);
    c.heapPathEmpty = c.lastPathLen == 0;
  }
}

/// UDClass API link cache: a version-gated library-version word, a few booleans,
/// an `LStr` content blob, then a version-gated fixed trailing field (5 bytes at
/// major ≥ 16, a further 4 at major ≥ 20; corpus-derived, beyond pylabview's
/// version coverage). The trailing bytes are 0 across the corpus for an empty
/// cache; retained verbatim by the serializer, certified by the terminator gate.
void _liUdApiCache(_LiCursor c) {
  c.pad(4);
  c.skip(c.ge(8, 0, 0) ? 8 : 4);
  if (!c.ge(8, 0, 4)) c.skip(4);
  c.skip(1);
  if (c.ge(8, 1, 0)) c.skip(1);
  if (c.ge(9, 0, 0)) c.skip(1);
  _liLStr(c);
  if (c.major >= 16) c.skip(5);
  if (c.major >= 20) c.skip(4);
}

void _liUdHeapApi(_LiCursor c) {
  _liBasic(c);
  if (!c.ok) return;
  if (c.ge(8, 0, 3)) _liUdApiCache(c);
  if (!c.ok) return;
  c.pad(4);
  _liOffList(c);
}

void _liUdViApi(_LiCursor c) {
  _liBasic(c);
  if (!c.ok) return;
  _liUdApiCache(c);
}

/// An observed version-gated trailing offset-list on the data-space `DSDS` link
/// (present at major ≥ 14, beyond pylabview's version coverage). Retained as a
/// self-framed `[u32 count][u32…]`; the terminator checksum certifies it.
void _liTrailer(_LiCursor c) {
  if (c.major >= 14) _liOffList(c);
}

/// A boolean flag: 1 byte at version ≥ 4.5, else 2 (pylabview `parseBool`).
void _liBool(_LiCursor c) => c.skip(c.ge(4, 5, 0) ? 1 : 2);

/// External-function link save info (`DSEF`/`NEXF`): basic link-save info + an
/// offset list + a `PStr` name + two flag bytes + a version-gated boolean; a
/// plain offset-save on pre-8.0 files.
void _liExtFunc(_LiCursor c) {
  if (c.ge(8, 0, 3)) {
    _liBasic(c);
    if (!c.ok) return;
    _liOffList(c);
    if (!c.ok) return;
    _liPStr(c);
    if (!c.ok) return;
    c.skip(2); // prop3 + prop4
    if (c.ge(11, 0, 3)) _liBool(c);
  } else {
    _liOffsetSave(c);
  }
}

/// GObject-interface link save info (`VIXN`): basic link-save info (or an
/// offset-save on pre-8.0 files) followed by the five interface property words
/// (`u16`×4 + `u32`).
void _liGiSave(_LiCursor c) {
  c.ge(8, 0, 0) ? _liBasic(c) : _liOffsetSave(c);
  if (!c.ok) return;
  c.skip(12);
}

/// Consumes one entry body for [kind] (the `0x0002` marker and 4cc already
/// read). An unhandled kind clears [c.ok] so the section stays copied.
void _liEntry(_LiCursor c, String kind) {
  switch (kind) {
    case 'VILB':
      _liBasic(c);
    case 'IUVI':
      final heapForm = c.ge(8, 2, 0);
      heapForm ? _liHeapToVi(c) : _liOffsetSave(c);
      if (!c.ok) return;
      if (c.ge(8, 0, 0)) _liPStr(c);
      if (!c.ok) return;
      // An empty heap-to-VI path is replaced by a heap offset list.
      if (heapForm && c.heapPathEmpty) _liOffList(c);
    case 'VIVI':
      _liTyped(c);
      if (!c.ok) return;
      if (c.ge(10, 0, 0) && c.u8() != 0) c.skip(36); // stdViGUID
    case 'VICC': // VI → custom-control link
    case 'VIPV': // VI → poly link
    case 'VIPR': // VI → programmatic-return link
    case 'VIAV': // VI → adaptive-VI link
      _liTyped(c);
    case 'BSVR': // VI → static-VI link
      _liTyped(c);
      if (!c.ok) return;
      c.skip(4); // viLinkProp2
    case 'TDCC':
      _liHeapToVi(c);
      if (!c.ok) return;
      if (c.heapPathEmpty) _liOffList(c);
    case 'PUPV': // poly-instance-use → poly link
    case 'SVVI': // static-VI-ref → VI link
      _liHeapToVi(c);
    case 'DSDS':
      _liOffsetSave(c);
      if (!c.ok) return;
      if (c.ge(8, 6, 0)) _liOffList(c);
      if (!c.ok) return;
      _liTrailer(c);
    case 'DSSV': // data-space → static-VI link
      _liOffsetSave(c);
    case 'DSEF': // data-space → external-function link
    case 'NEXF': // node → external-function link
      _liExtFunc(c);
    case 'XNXI': // XNode → XInterface link
      _liOffsetSave(c);
      if (!c.ok) return;
      if (c.ge(8, 6, 0)) c.skip(12); // GILinkInfo
    case 'VIXN': // VI → XNode-interface link
      _liGiSave(c);
    case 'FPPI':
    case 'DDPI':
    case 'VRPI':
    case 'DyOM': // dynamic-info → UDClass-API link
    case 'PNOM': // property-node-item → UDClass-API link
    case 'DRPI': // create/destroy-ref → UDClass-API link
    case 'DOPI': // data-display-object → UDClass-API link
      _liUdHeapApi(c);
    case 'VIPI':
      _liUdViApi(c); // no trailer: UDClass VI-API save info has no offset list
    default:
      c.ok = false;
  }
}
