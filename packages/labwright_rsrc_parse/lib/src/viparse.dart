import 'dart:typed_data';

/// Thrown when bytes are not a valid LabVIEW RSRC (`.vi`) container. The parser
/// bounds-checks every read, so it raises this rather than `RangeError`.
class ViFormatException implements Exception {
  ViFormatException(this.message);
  final String message;
  @override
  String toString() => 'ViFormatException: $message';
}

/// A structural summary of a LabVIEW VI — enough to say *what it is and does*
/// without (yet) recovering the block-diagram logic.
class ViSummary {
  ViSummary({
    required this.fileType,
    required this.creator,
    required this.formatVersion,
    required this.blocks,
    this.name,
  });

  /// e.g. `LVIN` (a VI), `LVCC` (a control/typedef).
  final String fileType;

  /// e.g. `LBVW` (LabVIEW).
  final String creator;

  /// RSRC container format version.
  final int formatVersion;

  /// The 4-char resource-block tags present (the VI's component inventory).
  final List<String> blocks;

  /// Best-effort VI name (trailing length-prefixed string), if recoverable.
  final String? name;

  bool get isVi => fileType == 'LVIN';
  bool get isControl => fileType == 'LVCC';

  /// Has executable logic (a block diagram).
  bool get hasBlockDiagram => blocks.contains('BDHb') || blocks.contains('BDHP');

  /// Has a front-panel UI.
  bool get hasFrontPanel => blocks.contains('FPHb') || blocks.contains('FPHP');

  /// Has a connector pane (its input/output signature).
  bool get hasConnectorPane => blocks.contains('CONP');

  /// References other VIs (calls sub-VIs).
  bool get hasSubViLinks => blocks.contains('LIvi') || blocks.contains('LIbd') || blocks.contains('LIfp');

  Map<String, Object?> toJson() => {
        'fileType': fileType,
        'creator': creator,
        'formatVersion': formatVersion,
        'name': name,
        'blocks': blocks,
        'hasBlockDiagram': hasBlockDiagram,
        'hasFrontPanel': hasFrontPanel,
        'hasConnectorPane': hasConnectorPane,
        'hasSubViLinks': hasSubViLinks,
      };

  /// A one-line human description of what the VI is/does.
  String describe() {
    final kind = switch (fileType) {
      'LVIN' => 'VI',
      'LVCC' => 'control/typedef',
      _ => fileType,
    };
    final caps = [
      if (hasFrontPanel) 'front panel',
      if (hasBlockDiagram) 'block diagram (logic)',
      if (hasConnectorPane) 'connector pane',
      if (hasSubViLinks) 'sub-VI links',
    ];
    return '${name ?? '(unnamed)'} — $kind, ${blocks.length} resource blocks'
        '${caps.isEmpty ? '' : '; has ${caps.join(', ')}'}';
  }
}

/// One block section's raw bytes located in the RSRC data area.
///
/// A block (e.g. `BDHb`, `vers`) owns one or more sections; each is stored in
/// the data area as a length-prefixed run. Heap sections remain **as stored**
/// here — typically zlib-compressed; inflation + heap parsing live in the
/// `labwright_rsrc_parse` layer so this reader stays pure and web-safe.
class ViSection {
  ViSection({required this.tag, required this.index, required this.dataOffset, required this.bytes});

  /// The 4-char block tag this section belongs to.
  final String tag;

  /// The section's 0-based index within its block.
  final int index;

  /// The section's offset within the RSRC data area (diagnostic).
  final int dataOffset;

  /// The section's bytes exactly as stored (heap sections stay compressed).
  final Uint8List bytes;
}

/// The RSRC magic bytes (`RSRC\r\n`) every container begins with.
const List<int> _magic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

/// True when every byte in `b[start..end)` is printable ASCII (0x20–0x7e).
bool _allPrintable(Uint8List b, int start, int end) {
  for (var i = start; i < end; i++) {
    if (b[i] < 0x20 || b[i] >= 0x7f) return false;
  }
  return true;
}

/// Splits a name on either path separator; compiled once (used per-name).
final _pathSep = RegExp(r'[\\/]');

/// The bare filename of [s], with any `.llb`/directory prefix stripped.
String _baseName(String s) => s.split(_pathSep).last;

/// Best-effort embedded sections; empty on a malformed container (never throws).
List<ViSection> _embeddedOrEmpty(Uint8List bytes) {
  try {
    return readEmbeddedSections(bytes);
  } catch (_) {
    return const [];
  }
}

/// Validates the RSRC container header: minimum size + magic bytes.
void _checkRsrcMagic(Uint8List bytes) {
  if (bytes.length < 32) throw ViFormatException('too small to be an RSRC file');
  for (var i = 0; i < _magic.length; i++) {
    if (bytes[i] != _magic[i]) throw ViFormatException('not an RSRC/.vi file (bad magic)');
  }
}

/// Extracts every block section's raw bytes from an RSRC container.
///
/// Total and bounds-safe like [parseVi]: a malformed *container* (bad magic,
/// truncated header/block-list) throws [ViFormatException], while an individual
/// ill-formed section descriptor is skipped — so the result is a best-effort
/// (possibly partial) list, never a crash. Each section descriptor is a 20-byte
/// record; this extractor returns the VI's own data sections (`@16` word
/// `0xFFFFFFFF`). The LIBN/VINS sections (`@16` word `0` — owning-library names
/// and embedded sub-VIs) are returned separately by [readEmbeddedSections], so
/// this list (and the section-edit path built on it) stays a clean 1:1 view of
/// the primary sections.
///
/// **Descriptor-table base.** A block-list entry's third word (`descRel`) is the
/// offset to that block's 20-byte section descriptors **relative to the block
/// list, not to the info section** — specifically `countPos + 8` (the `u32`
/// count word is at `countPos`, the 12-byte entries begin at `countPos + 4`, and
/// the descriptor table follows them; `descRel` is measured from `countPos + 8`).
/// Corpus-validated: across 409 real `.vi` files this base makes the universal
/// blocks `LVSR`/`RTSG`/`LIvi` (present in all 409) and `OBSG` (present in 9)
/// decode to valid `[u32 len][bytes]` sections in 100% of the files that contain
/// them, recovering ~1,200 sections, with the per-VI tag inventory a superset of
/// the old (info-relative) base — i.e. 0 blocks regress. (Using `infoOffset`
/// directly placed the first descriptors *inside* the block-list region and
/// returned the wrong bytes for nearly every block.)
List<ViSection> readViSections(Uint8List bytes) => _readSections(bytes, wantWord16: 0xFFFFFFFF);

/// Extracts the **secondary** sections a VI embeds: the `LIBN` owning-library
/// names and the `VINS` embedded sub-VIs, whose descriptor `@16` word is `0`
/// (vs `0xFFFFFFFF` for the VI's own data sections — see [ViSectionDescriptor]).
/// These are real, data-bearing sections that [readViSections] deliberately
/// leaves out so its list stays a clean 1:1 view for the section-edit path.
///
/// Corpus-validated (7583 VIs): every `VINS` section's bytes are a complete
/// nested `RSRC…LVIN` VI (begins with the `RSRC` magic), every `LIBN` section's
/// bytes are a printable library name, and no such section's data range overlaps
/// any primary section. Total/bounds-safe exactly like [readViSections].
List<ViSection> readEmbeddedSections(Uint8List bytes) => _readSections(bytes, wantWord16: 0);

/// One embedded sub-VI recovered from a `VINS` section — a complete nested VI.
class ViEmbeddedVi {
  ViEmbeddedVi({required this.name, required this.sizeBytes, this.bytes});

  /// The nested VI's recovered name (its trailing VI name via [parseVi]), or
  /// `null` if none was cleanly recovered. Best-effort, like any [parseVi] name.
  final String? name;

  /// The embedded VI's size in bytes (the nested `RSRC…LVIN` payload length).
  final int sizeBytes;

  /// The nested VI's raw bytes (a complete `RSRC…LVIN` container) — feed these
  /// straight back to [parseVi]/the inspector to open the embedded VI. May be
  /// null when an [ViEmbeddedVi] is constructed without them (e.g. in tests).
  final Uint8List? bytes;
}

/// The owning-library names a VI declares via its `LIBN` sections. The LIBN
/// payload is `[u32][u8 len][name]…`; the library name is the Pascal string at
/// offset 4 (e.g. `MQTT Server.lvlib`). Returns one entry per LIBN section that
/// yields a clean printable name (deduped, order-preserving). Never throws.
List<String> readOwningLibraryNames(Uint8List bytes) {
  final out = <String>[];
  for (final s in _embeddedOrEmpty(bytes)) {
    if (s.tag != 'LIBN') continue;
    final b = s.bytes;
    if (b.length < 5) continue;
    final len = b[4];
    if (len == 0 || 5 + len > b.length) continue;
    if (!_allPrintable(b, 5, 5 + len)) continue;
    final name = String.fromCharCodes(b.sublist(5, 5 + len));
    if (!out.contains(name)) out.add(name);
  }
  return out;
}

/// The embedded sub-VIs a VI carries in its `VINS` sections, each parsed for its
/// name + size. The bytes of each are a complete nested `RSRC…LVIN` VI, so they
/// are fed to [parseVi] for a best-effort name. Never throws.
List<ViEmbeddedVi> readEmbeddedVis(Uint8List bytes) {
  final out = <ViEmbeddedVi>[];
  for (final s in _embeddedOrEmpty(bytes)) {
    if (s.tag != 'VINS') continue;
    String? name;
    try {
      name = parseVi(s.bytes).name;
    } catch (_) {}
    out.add(ViEmbeddedVi(name: name, sizeBytes: s.bytes.length, bytes: Uint8List.fromList(s.bytes)));
  }
  return out;
}

/// Shared RSRC section walker. Returns the sections whose descriptor `@16` word
/// equals [wantWord16] — `0xFFFFFFFF` for the VI's own data sections
/// ([readViSections]) or `0` for the embedded LIBN/VINS sections
/// ([readEmbeddedSections]). See [readViSections] for the descriptor-table base.
List<ViSection> _readSections(Uint8List bytes, {required int wantWord16}) {
  final d = ByteData.sublistView(bytes);

  int u32(int p) {
    if (p < 0 || p + 4 > bytes.length) throw ViFormatException('truncated u32 at $p');
    return d.getUint32(p);
  }

  String tag(int p) => String.fromCharCodes(bytes.sublist(p, p + 4));

  _checkRsrcMagic(bytes);

  final infoOffset = u32(16);
  final dataOffset = u32(24);
  final dataSize = u32(28);
  if (infoOffset + 0x30 > bytes.length) throw ViFormatException('info section offset out of range');

  final blockListRel = u32(infoOffset + 0x2c);
  final countPos = infoOffset + blockListRel;
  final count = u32(countPos);
  if (count > 100000) throw ViFormatException('implausible block count $count');

  const descSize = 20;
  final descBase = countPos + 8;
  final sections = <ViSection>[];
  var entry = countPos + 4;
  for (var i = 0; i < count && entry + 12 <= bytes.length; i++) {
    final t = tag(entry);
    final sectionCount = u32(entry + 4) + 1;
    final descRel = u32(entry + 8);
    entry += 12;
    if (!_printableTag(t)) continue;
    for (var s = 0; s < sectionCount; s++) {
      final dpos = descBase + descRel + s * descSize;
      if (dpos + descSize > bytes.length) break;
      if (d.getUint32(dpos + 16) != wantWord16) continue;
      final secRel = d.getUint32(dpos + 4);
      final pos = dataOffset + secRel;
      if (pos + 4 > bytes.length) continue;
      final len = d.getUint32(pos);
      if (len > dataSize || pos + 4 + len > bytes.length) continue;
      sections.add(ViSection(
        tag: t,
        index: s,
        dataOffset: secRel,
        bytes: Uint8List.sublistView(bytes, pos + 4, pos + 4 + len),
      ));
    }
  }
  return sections;
}

/// Parses a LabVIEW RSRC container (`.vi`) into a [ViSummary]. Big-endian.
ViSummary parseVi(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);

  int u16(int p) {
    if (p + 2 > bytes.length) throw ViFormatException('truncated u16 at $p');
    return d.getUint16(p);
  }

  int u32(int p) {
    if (p < 0 || p + 4 > bytes.length) throw ViFormatException('truncated u32 at $p');
    return d.getUint32(p);
  }

  String tag(int p) {
    if (p + 4 > bytes.length) throw ViFormatException('truncated tag at $p');
    return String.fromCharCodes(bytes.sublist(p, p + 4));
  }

  _checkRsrcMagic(bytes);

  final formatVersion = u16(6);
  final fileType = tag(8);
  final creator = tag(12);
  final infoOffset = u32(16);
  if (infoOffset + 0x30 > bytes.length) {
    throw ViFormatException('info section offset $infoOffset out of range');
  }

  final blockListRel = u32(infoOffset + 0x2c);
  final countPos = infoOffset + blockListRel;
  final count = u32(countPos);
  if (count > 100000) throw ViFormatException('implausible block count $count');

  final blocks = <String>[];
  final seen = <String>{};
  var entry = countPos + 4;
  for (var i = 0; i < count && entry + 12 <= bytes.length; i++) {
    final t = tag(entry);
    if (!_printableTag(t)) break;
    if (seen.add(t)) blocks.add(t);
    entry += 12;
  }

  return ViSummary(
    fileType: fileType,
    creator: creator,
    formatVersion: formatVersion,
    blocks: blocks,
    name: _viName(bytes, infoOffset),
  );
}

/// The VI name, located authoritatively via the subheader's `reservedB`
/// (`u32 @ infoOffset+0x30`) — the info-relative offset of the trailing
/// `[u8 len][name]` record. Taken verbatim (so Latin-1/Unicode names decode and
/// are not dropped), with the printable-only [_trailingName] scan as a fallback.
String? _viName(Uint8List b, int infoOffset) {
  if (infoOffset + 0x34 <= b.length) {
    final rel = ByteData.sublistView(b).getUint32(infoOffset + 0x30);
    final at = infoOffset + rel;
    if (at < b.length && b[at] > 0 && at + 1 + b[at] == b.length) {
      return String.fromCharCodes(b.sublist(at + 1));
    }
  }
  return _trailingName(b);
}

bool _printableTag(String s) =>
    s.length == 4 && s.codeUnits.every((c) => c >= 0x20 && c < 0x7f);

/// Recovers the names of the **subVIs this VI calls**, from the block-diagram
/// linker-info block (`LIbd`). LabVIEW records each block-diagram dependency
/// there as a length-prefixed (`u8 len` + bytes) name; the subVI references end
/// in `.vi`. Returns them deduped and order-preserving, with the VI's own name
/// (from `LIvi`) excluded, and any container path (`.llb`/directory prefix)
/// stripped to the bare filename.
///
/// Corpus-validated: `LIbd` carries recoverable subVI names for ~82% of VIs
/// (the rest call no subVIs or none with a stored name). This is **honest,
/// VI-level** dependency info — it lists *which* subVIs are called, NOT which
/// block-diagram node calls which (that linkage is not recoverable from the
/// diagram alone). Total: returns `const []` if the block is absent/empty.
List<String> readSubViNames(Uint8List bytes) {
  List<ViSection> secs;
  try {
    secs = readViSections(bytes);
  } catch (_) {
    return const [];
  }
  Uint8List? sectionBytes(String tag) {
    for (final s in secs) {
      if (s.tag == tag) return s.bytes;
    }
    return null;
  }

  final libd = sectionBytes('LIbd');
  if (libd == null || libd.isEmpty) return const [];

  final self = <String>{};
  final livi = sectionBytes('LIvi');
  final liviNames = livi == null ? const <String>[] : _pascalViNames(livi);
  if (liviNames.isNotEmpty) {
    self.add(_baseName(liviNames.first).toLowerCase());
  }
  final trailing = _trailingName(bytes);
  if (trailing != null && trailing.toLowerCase().endsWith('.vi')) {
    self.add(_baseName(trailing).toLowerCase());
  }

  final seen = <String>{};
  final out = <String>[];
  for (final n in _pascalViNames(libd)) {
    final base = _baseName(n);
    final key = base.toLowerCase();
    if (self.contains(key)) continue;
    if (seen.add(key)) out.add(base);
  }
  return out;
}

/// Scans [b] for length-prefixed (`u8 len` + `len` printable bytes) Pascal
/// strings whose value ends in `.vi` (case-insensitive). Heuristic but precise:
/// requiring the exact length match + all-printable payload + `.vi` suffix makes
/// false positives vanishingly unlikely. Order-preserving (duplicates kept; the
/// caller dedupes).
List<String> _pascalViNames(Uint8List b) {
  final out = <String>[];
  for (var i = 0; i + 1 < b.length; i++) {
    final len = b[i];
    if (len < 4 || i + 1 + len > b.length) continue;
    if (!_allPrintable(b, i + 1, i + 1 + len)) continue;
    final s = String.fromCharCodes(b.sublist(i + 1, i + 1 + len));
    if (s.toLowerCase().endsWith('.vi')) {
      out.add(s);
      i += len;
    }
  }
  return out;
}

/// Recovers the trailing length-prefixed VI name (a Pascal string at EOF), if
/// present. Scans largest-first so the full name wins over shorter coincidences.
String? _trailingName(Uint8List b) {
  final maxLen = b.length - 1 < 255 ? b.length - 1 : 255;
  for (var len = maxLen; len >= 1; len--) {
    final lenPos = b.length - 1 - len;
    if (b[lenPos] != len) continue;
    if (_allPrintable(b, lenPos + 1, b.length)) return String.fromCharCodes(b.sublist(lenPos + 1));
  }
  return null;
}
