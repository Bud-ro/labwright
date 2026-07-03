import 'dart:typed_data';

import 'viparse.dart' show ViFormatException, readViSections;

/// The 32-byte RSRC (`.vi`) file header, modeled field-by-field — the first
/// fully-typed piece of the exporter: every one of the 32 bytes maps to a named
/// field, so [serialize] reconstructs the header byte-for-byte (no opaque span).
///
/// Layout (big-endian), corpus-validated across 7583 VIs as a symmetric
/// `(offset, size)` pair per region:
///   `[0:6]` magic `RSRC\r\n` · `u16 formatVersion @6` (always 3) ·
///   `[8:12]` fileType tag (`LVIN` VI / `LVCC` control) · `[12:16]` creator tag
///   (`LBVW`) · `u32 infoOffset @16` · `u32 infoSize @20` · `u32 dataOffset @24`
///   (always 32) · `u32 dataSize @28`. With `dataOffset + dataSize == infoOffset`
///   and `infoOffset + infoSize == fileLength`.
class ViHeader {
  ViHeader({
    required this.magic,
    required this.formatVersion,
    required this.fileTypeBytes,
    required this.creatorBytes,
    required this.infoOffset,
    required this.infoSize,
    required this.dataOffset,
    required this.dataSize,
  });

  /// `RSRC\r\n` — kept as raw bytes so serialization is exact even if a future
  /// file deviates.
  final Uint8List magic;

  /// `u16 @6` — the RSRC format version (3 in every observed file).
  final int formatVersion;

  /// `[8:12]` file-type tag bytes (`LVIN` = VI, `LVCC` = control). Raw 4 bytes for
  /// exact round-trip; see [fileType] for the string.
  final Uint8List fileTypeBytes;

  /// `[12:16]` creator tag bytes (`LBVW`). Raw 4 bytes; see [creator].
  final Uint8List creatorBytes;

  /// `u32 @16` — start of the info area.
  final int infoOffset;

  /// `u32 @20` — size of the info area (`infoOffset + infoSize == fileLength`).
  final int infoSize;

  /// `u32 @24` — start of the data area (always 32, right after this header).
  final int dataOffset;

  /// `u32 @28` — size of the data area (`dataOffset + dataSize == infoOffset`).
  final int dataSize;

  String get fileType => String.fromCharCodes(fileTypeBytes);
  String get creator => String.fromCharCodes(creatorBytes);

  /// The RSRC magic bytes (`RSRC\r\n`) every container/header begins with.
  static const List<int> _magic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

  /// Parses the first 32 bytes of [bytes] into a [ViHeader]. Throws
  /// [ViFormatException] on a too-short or non-RSRC buffer.
  factory ViHeader.parse(Uint8List bytes) {
    if (bytes.length < 32) throw ViFormatException('too small for an RSRC header');
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) throw ViFormatException('not an RSRC/.vi file (bad magic)');
    }
    final d = ByteData.sublistView(bytes);
    return ViHeader(
      magic: Uint8List.fromList(bytes.sublist(0, 6)),
      formatVersion: d.getUint16(6),
      fileTypeBytes: Uint8List.fromList(bytes.sublist(8, 12)),
      creatorBytes: Uint8List.fromList(bytes.sublist(12, 16)),
      infoOffset: d.getUint32(16),
      infoSize: d.getUint32(20),
      dataOffset: d.getUint32(24),
      dataSize: d.getUint32(28),
    );
  }

  /// Re-emits the 32 header bytes. Byte-identical to the input for a parsed,
  /// unmodified header — the per-field serialize() contract.
  Uint8List serialize() {
    final out = Uint8List(32);
    final d = ByteData.sublistView(out);
    out.setRange(0, 6, magic);
    d.setUint16(6, formatVersion);
    out.setRange(8, 12, fileTypeBytes);
    out.setRange(12, 16, creatorBytes);
    d
      ..setUint32(16, infoOffset)
      ..setUint32(20, infoSize)
      ..setUint32(24, dataOffset)
      ..setUint32(28, dataSize);
    return out;
  }
}

/// The fixed prefix of the info area, `[0, blockListRel)` — modeled field-by-field.
/// The RSRC format repeats the 32-byte file header at the start of the info area;
/// after it come [reservedA] (`[0,0,0x20]`), the `blockListRel` pointer
/// (`u32 @0x2c`; `0x34` in every corpus VI, though the parser accepts any in-range
/// value), and [reservedB] (the info-relative offset of the trailing VI name).
/// [serialize] reconstructs the prefix byte-exact.
class ViInfoSubheader {
  ViInfoSubheader({
    required this.headerCopy,
    required this.reservedA,
    required this.blockListRel,
    required this.reservedB,
  });

  /// `[0:32]` — a duplicate of the file's [ViHeader] (the RSRC dual-header).
  final ViHeader headerCopy;

  /// `[32:44]` — three `u32`s between the dup header and `blockListRel`.
  /// Corpus-probed (7583 VIs): `[u32 0][u32 0][u32 0x20]` — the first two are
  /// always zero and the third is the constant `0x20` (=32). See [reservedAMarker].
  /// Kept raw (re-emitted exactly); the constant is not asserted in [parse].
  // TODO(labwright): identify the `0x20` marker's meaning (a fixed size/version?).
  final Uint8List reservedA;

  /// `u32 @0x2c` — offset (info-area-relative) where the block list begins.
  final int blockListRel;

  /// `[0x30, blockListRel)` — a `u32` (4 bytes; `blockListRel` is `0x34`
  /// throughout the corpus). Corpus-probed: this is the **info-area-relative
  /// offset of the trailing VI-name record** (`[u8 len][name]` at EOF) — it
  /// equals that offset in all 7583 VIs (it is the authoritative VI-name locator;
  /// see [viNameOffset], used by [ViNameTable.parse]). Kept raw to stay byte-exact
  /// for any non-canonical `blockListRel`.
  final Uint8List reservedB;

  /// The constant marker word of [reservedA] (`u32 @8`, i.e. info `@0x28`); `0x20`
  /// across the corpus. Null if [reservedA] is not the canonical 12 bytes.
  int? get reservedAMarker =>
      reservedA.length >= 12 ? ByteData.sublistView(reservedA).getUint32(8) : null;

  /// The info-area-relative offset of the trailing VI-name record, read from
  /// [reservedB] (`u32 @0x30`). Null if [reservedB] is not the canonical 4 bytes.
  int? get viNameOffset =>
      reservedB.length == 4 ? ByteData.sublistView(reservedB).getUint32(0) : null;

  /// Parses the subheader from the start of an [infoArea]. Throws
  /// [ViFormatException] if the area is too short or `blockListRel` is implausible.
  factory ViInfoSubheader.parse(Uint8List infoArea) {
    if (infoArea.length < 0x30) throw ViFormatException('info area too small for a subheader');
    final d = ByteData.sublistView(infoArea);
    final blockListRel = d.getUint32(0x2c);
    if (blockListRel < 0x30 || blockListRel > infoArea.length) {
      throw ViFormatException('implausible blockListRel $blockListRel');
    }
    return ViInfoSubheader(
      headerCopy: ViHeader.parse(Uint8List.sublistView(infoArea, 0, 32)),
      reservedA: Uint8List.fromList(infoArea.sublist(32, 0x2c)),
      blockListRel: blockListRel,
      reservedB: Uint8List.fromList(infoArea.sublist(0x30, blockListRel)),
    );
  }

  /// Re-emits the `[0, blockListRel)` prefix, byte-identical to the input for a
  /// parsed, unmodified subheader.
  Uint8List serialize() {
    final out = BytesBuilder()
      ..add(headerCopy.serialize())
      ..add(reservedA);
    final blr = ByteData(4)..setUint32(0, blockListRel);
    out
      ..add(blr.buffer.asUint8List())
      ..add(reservedB);
    return out.toBytes();
  }
}

/// One 12-byte block-list entry: a resource-block [tag] and the section(s) it
/// owns. Big-endian `{tag[4], u32 sectionCount-1, u32 descRel}`.
class ViBlockListEntry {
  ViBlockListEntry({required this.tagBytes, required this.sectionCountMinus1, required this.descRel});

  /// `[0:4]` the block tag bytes (e.g. `LVSR`, `BDHb`, `CONP`). Raw for exact
  /// round-trip; see [tag].
  final Uint8List tagBytes;

  /// `u32 @4` — the number of sections this block owns, minus one (LabVIEW's
  /// count-1 convention).
  final int sectionCountMinus1;

  /// `u32 @8` — offset of this block's first section descriptor, relative to the
  /// block-list count word + 8 (`countPos + 8`).
  final int descRel;

  String get tag => String.fromCharCodes(tagBytes);

  factory ViBlockListEntry.parse(Uint8List info, int at) {
    final d = ByteData.sublistView(info);
    return ViBlockListEntry(
      tagBytes: Uint8List.fromList(info.sublist(at, at + 4)),
      sectionCountMinus1: d.getUint32(at + 4),
      descRel: d.getUint32(at + 8),
    );
  }

  void writeInto(ByteData d, Uint8List out, int at) {
    out.setRange(at, at + 4, tagBytes);
    d
      ..setUint32(at + 4, sectionCountMinus1)
      ..setUint32(at + 8, descRel);
  }
}

/// The info area's **block list**: a `u32 count` followed by `count` contiguous
/// 12-byte [ViBlockListEntry]s, beginning at `blockListRel`. The directory of
/// every resource block in the VI. [serialize] reconstructs the
/// `[blockListRel, blockListRel + 4 + count*12)` region byte-exact.
class ViBlockList {
  ViBlockList({required this.entries});

  final List<ViBlockListEntry> entries;

  int get count => entries.length;

  /// Total serialized byte length (the `u32 count` + the entry array).
  int get byteLength => 4 + entries.length * 12;

  /// Parses the block list at [blockListRel] within [infoArea].
  factory ViBlockList.parse(Uint8List infoArea, int blockListRel) {
    if (blockListRel + 4 > infoArea.length) throw ViFormatException('block list out of range');
    final d = ByteData.sublistView(infoArea);
    final count = d.getUint32(blockListRel);
    if (count > 100000) throw ViFormatException('implausible block count $count');
    final end = blockListRel + 4 + count * 12;
    if (end > infoArea.length) throw ViFormatException('block list entries out of range');
    return ViBlockList(entries: [
      for (var i = 0; i < count; i++) ViBlockListEntry.parse(infoArea, blockListRel + 4 + i * 12),
    ]);
  }

  /// Re-emits `[u32 count][entries…]`, byte-identical to the parsed region.
  Uint8List serialize() {
    final out = Uint8List(byteLength);
    final d = ByteData.sublistView(out);
    d.setUint32(0, entries.length);
    for (var i = 0; i < entries.length; i++) {
      entries[i].writeInto(d, out, 4 + i * 12);
    }
    return out;
  }
}

/// One 20-byte info-area section descriptor. The info area holds a contiguous run
/// of these after the block list; corpus-proven, **every** record is a real
/// section referenced by a block-list entry (no "name-table rows" exist — all
/// 281,313 records across 7583 VIs are referenced, and each carries a valid
/// data-area `[u32 len][payload]`). Every byte is captured (the unclassified
/// words as raw fields with TODOs) so [serialize] reconstructs it byte-exact.
class ViSectionDescriptor {
  ViSectionDescriptor({
    required this.word0,
    required this.secRel,
    required this.word8,
    required this.nameRef,
    required this.word16,
  });

  /// `u32 @0` — **`0` in every one of the 281,313 corpus descriptors** (a
  /// reserved/unused leading word). // TODO(labwright): confirm it is always reserved.
  final int word0;

  /// `u32 @4` — for a section descriptor, the data-area-relative offset
  /// (`secRel`) of the section's `[u32 len][payload]` bytes.
  final int secRel;

  /// `u32 @8` — `0` in every modern VI (LabVIEW 8+); nonzero ONLY in the legacy
  /// LV ≤7.x format (the lone LV7 corpus VI, 151 descriptors). So this is an
  /// old-format field, zero today. // TODO(labwright): decode the LV7-era meaning
  /// (only one sample; values share a low `0x4E01`).
  final int word8;

  /// `u32 @12` — a **1-based index into a VI-wide name table** for the section
  /// (`0` ⇒ unnamed; non-zero for ~25% of sections). Probed over all 7583 corpus
  /// VIs: values are small (global max 360), and distinct sections SHARE an index
  /// (e.g. a type record and its data-space twin both reference the same name), so
  /// this is a *shared index*, not an inline byte offset. It is NOT an index into
  /// the descriptor array (it exceeds the descriptor/section count in ~12% of named
  /// sections), so the name table is a separate structure.
  // TODO(labwright): locate the name table's bytes. RULED OUT: the post-descriptor
  // region (too small); any section payload as a flat `[u32 count][pascal…]` list
  // (a full-section scan finds no contiguous pascal pool anywhere); and the VCTP
  // type-name list by index (TRec-format VIs recover no VCTP names, and named-type
  // count >= maxNameRef in only ~5% of VIs). Likely embedded/interleaved in the
  // heap object graph or link-info, not a flat table.
  final int nameRef;

  /// `u32 @16` — a per-section word, exactly binary across the full corpus:
  /// `0xFFFFFFFF` for ~98.3% of sections, and `0` for exactly the **LIBN** (4730)
  /// and **VINS** (40) block sections — both of which are real, data-bearing
  /// sections (LIBN payloads are owning-library names like `MQTT Server.lvlib…`;
  /// VINS payloads are entire embedded sub-VIs — a nested `RSRC…LVIN` file). So
  /// `0` here does NOT mean "not a section"; it co-occurs with those two blocks.
  // TODO(labwright): decode @16's meaning (a kind/flag distinguishing embedded
  // LIBN/VINS sections from the VI's own data sections?).
  final int word16;

  /// The `@16` value carried by the VI's own data sections (~98.3% of sections);
  /// LIBN/VINS sections carry `0` instead. Not a section-vs-nonsection flag.
  static const int commonWord16 = 0xFFFFFFFF;

  /// Whether this section carries a name (a non-zero [nameRef] index). The name
  /// itself is not yet resolvable — see [nameRef] — but a caller can already tell
  /// named sections from anonymous ones.
  bool get isNamed => nameRef != 0;

  /// Parses the 20-byte record (five big-endian `u32`s) at [at] within [info].
  factory ViSectionDescriptor.parse(Uint8List info, int at) {
    if (at < 0 || at + 20 > info.length) throw ViFormatException('descriptor out of range at $at');
    final d = ByteData.sublistView(info);
    return ViSectionDescriptor(
      word0: d.getUint32(at),
      secRel: d.getUint32(at + 4),
      word8: d.getUint32(at + 8),
      nameRef: d.getUint32(at + 12),
      word16: d.getUint32(at + 16),
    );
  }

  /// Re-emits the 20 bytes (five `u32`s), byte-identical to the parsed record.
  Uint8List serialize() {
    final out = Uint8List(20);
    ByteData.sublistView(out)
      ..setUint32(0, word0)
      ..setUint32(4, secRel)
      ..setUint32(8, word8)
      ..setUint32(12, nameRef)
      ..setUint32(16, word16);
    return out;
  }
}

/// The info area's name-table tail: a small fixed [header] followed by the
/// **trailing Pascal VI name** at EOF (e.g. `PicoScope5000ExampleStreaming.vi`).
/// The trailing name is recovered as a typed field. [serialize] reconstructs the
/// tail byte-exact.
///
/// Corpus-probed (7583 VIs): [header] is exactly **12 bytes** in every VI —
/// `[u32 @0 = 0][u32 @4 = a varying value][u32 @8 = 0]` (the only non-zero field
/// is [headerValue]). Its size does NOT scale with the section `nameRef` indices
/// (it stays 12 bytes even when the max index is 128), so this header is NOT the
/// name table that `nameRef` points into — that table is still unlocated.
class ViNameTable {
  ViNameTable({required this.header, required this.trailingNameRecord});

  /// Leading bytes of the tail before the trailing VI name. Canonically 12 bytes:
  /// `[u32 0][u32 headerValue][u32 0]`. Kept as a raw span (no larger form is
  /// known once the name is located via `viNameOffset`). See [headerValue].
  // TODO(labwright): identify [headerValue]'s meaning (offset/size/signature?).
  final Uint8List header;

  /// The lone non-zero word of the canonical 12-byte [header] (`u32 @4`), or null
  /// when [header] is not the canonical 12-byte form. Corpus-probed: it is a
  /// **data-area-range value** — always `< dataSize` and typically ~120–160 below
  /// it (pointing near the end of the data area). Meaning not yet decoded; RULED
  /// OUT: it is not the trailing-name length/offset, the descriptor count, the
  /// info/data/file size, nor any section's `secRel`.
  // TODO(labwright): decode what near-end-of-data-area position/value this is.
  int? get headerValue => header.length == 12 ? ByteData.sublistView(header).getUint32(4) : null;

  /// The `[u8 len][name bytes]` Pascal record at EOF, or empty if no clean
  /// trailing name is present.
  final Uint8List trailingNameRecord;

  /// The VI name decoded from [trailingNameRecord] (Latin-1: each byte is a code
  /// point, so accented/Unicode names like `HÜll°` decode correctly), or null.
  String? get trailingName =>
      trailingNameRecord.isEmpty ? null : String.fromCharCodes(trailingNameRecord.sublist(1));

  /// Splits a name-table [tail] into header + trailing Pascal VI name.
  ///
  /// When [nameStart] is given (the authoritative within-tail offset of the name
  /// record, from the subheader's `viNameOffset`/`reservedB`), the record at that
  /// offset is taken **verbatim** if it is a `[u8 len]` ending exactly at EOF —
  /// no printable filter, so names with Latin-1/Unicode bytes are recovered, not
  /// dropped. Otherwise it falls back to scanning largest-first for a `u8 len` +
  /// `len` printable bytes ending at EOF (everything before is the header).
  factory ViNameTable.parse(Uint8List tail, {int? nameStart}) {
    if (nameStart != null && nameStart >= 0 && nameStart < tail.length) {
      final len = tail[nameStart];
      if (len > 0 && nameStart + 1 + len == tail.length) {
        return ViNameTable(
          header: Uint8List.fromList(tail.sublist(0, nameStart)),
          trailingNameRecord: Uint8List.fromList(tail.sublist(nameStart)),
        );
      }
    }
    final start = _trailingPascalStart(tail);
    if (start == null) {
      return ViNameTable(header: Uint8List.fromList(tail), trailingNameRecord: Uint8List(0));
    }
    return ViNameTable(
      header: Uint8List.fromList(tail.sublist(0, start)),
      trailingNameRecord: Uint8List.fromList(tail.sublist(start)),
    );
  }

  /// Index of the `len` byte of the trailing Pascal string (printable, ending at
  /// EOF), or null if none. Largest match wins so the full name is preferred.
  static int? _trailingPascalStart(Uint8List b) {
    final maxLen = b.length - 1 < 255 ? b.length - 1 : 255;
    for (var len = maxLen; len >= 1; len--) {
      final lenPos = b.length - 1 - len;
      if (lenPos < 0) continue;
      if (b[lenPos] != len) continue;
      var ok = true;
      for (var i = lenPos + 1; i < b.length; i++) {
        if (b[i] < 0x20 || b[i] >= 0x7f) {
          ok = false;
          break;
        }
      }
      if (ok) return lenPos;
    }
    return null;
  }

  Uint8List serialize() => (BytesBuilder()
        ..add(header)
        ..add(trailingNameRecord))
      .toBytes();
}

/// The 20-byte record between the block list and the first section descriptor —
/// **not** a gap. Corpus-probed (7583 VIs) as five big-endian `u32`s:
///   * [marker] `@0` — a 4-char tag, `FTAB` (7261) or `VITS` (322). It names the
///     ALTERNATE of the `FTAB`/`VITS` block pair: corpus-probed, the marker tag is
///     NEVER one of the VI's own blocks (100%), and the VI carries the *opposite*
///     tag as a block (a `VITS` marker ⇒ an `FTAB` block & no `VITS` block; an
///     `FTAB` marker ⇒ a `VITS` block, ~99%). Likely a font/type-table FORMAT or
///     version distinction. NOT an (uncounted) block-list entry — [word2] does not
///     resolve to a real section descriptor. See [markerTag].
///   * [word1] `@4` — `0` in every corpus VI.
///   * [word2] `@8` — a varying info-area offset/size (always `< infoArea.length`).
///   * [word3] `@12` — `0` in every corpus VI.
///   * [flags] `@16` — exactly `0xFFFFFFFF` **iff** the VI carries embedded
///     `LIBN`/`VINS` sections, else `0` (perfect correlation, 0 counterexamples;
///     see [hasEmbeddedSections] and `readEmbeddedSections`).
/// Every byte is a typed field so [serialize] reconstructs it byte-exact.
// TODO(labwright): decode WHY the marker is the alternate FTAB/VITS tag (font/type
// table format/version?) and [word2]'s exact role.
class ViInfoPreGap {
  ViInfoPreGap({
    required this.marker,
    required this.word1,
    required this.word2,
    required this.word3,
    required this.flags,
  });

  /// `u32 @0` — a 4-char marker tag (`FTAB` or `VITS`), naming the alternate of the
  /// FTAB/VITS block pair the VI carries (see the class doc). // TODO(labwright): why.
  final int marker;

  /// `u32 @4` — `0` across the corpus. // TODO(labwright): identify.
  final int word1;

  /// `u32 @8` — a varying info-area offset/size (`< infoArea.length`). // TODO.
  final int word2;

  /// `u32 @12` — `0` across the corpus. // TODO(labwright): identify.
  final int word3;

  /// `u32 @16` — `0xFFFFFFFF` iff the VI has embedded `LIBN`/`VINS` sections, else `0`.
  final int flags;

  /// [marker] rendered as its 4 ASCII bytes (e.g. `FTAB`, `VITS`).
  String get markerTag {
    final b = [(marker >> 24) & 0xff, (marker >> 16) & 0xff, (marker >> 8) & 0xff, marker & 0xff];
    return String.fromCharCodes([for (final c in b) (c >= 0x20 && c < 0x7f) ? c : 0x2e]);
  }

  /// Whether [flags] marks this VI as carrying embedded LIBN/VINS sections.
  bool get hasEmbeddedSections => flags == 0xFFFFFFFF;

  /// Parses the 20-byte record (five big-endian `u32`s) at the start of [b].
  factory ViInfoPreGap.parse(Uint8List b) {
    if (b.length < 20) throw ViFormatException('preGap record too short (${b.length})');
    final d = ByteData.sublistView(b);
    return ViInfoPreGap(
      marker: d.getUint32(0),
      word1: d.getUint32(4),
      word2: d.getUint32(8),
      word3: d.getUint32(12),
      flags: d.getUint32(16),
    );
  }

  /// Re-emits the 20 bytes (five `u32`s), byte-identical to the parsed record.
  Uint8List serialize() {
    final out = Uint8List(20);
    ByteData.sublistView(out)
      ..setUint32(0, marker)
      ..setUint32(4, word1)
      ..setUint32(8, word2)
      ..setUint32(12, word3)
      ..setUint32(16, flags);
    return out;
  }
}

/// The info area composed as typed regions: the [subheader] (dup header +
/// `blockListRel`), the [blockList] (resource-block directory), the 20-byte
/// [preGap] record, the [descriptors] table (contiguous 20-byte records), and the
/// as-yet raw [nameTable] tail (name table + trailing Pascal VI name).
/// [serialize] reconstructs the whole info area byte-exact.
///
/// Corpus-validated: after the block list comes a fixed 20-byte slot, then a
/// gapless run of `(descMax-descMin)/20` descriptor records, then the name
/// table — true for 100% of 7583 VIs. If a (hypothetical) file doesn't fit that
/// shape, [ViInfoArea.parse] falls back to keeping the whole remainder in
/// [nameTable] (descriptors empty) so serialization stays byte-exact regardless.
class ViInfoArea {
  ViInfoArea({
    required this.subheader,
    required this.blockList,
    required this.preGap,
    required this.descriptors,
    required this.nameTable,
  });

  final ViInfoSubheader subheader;
  final ViBlockList blockList;

  /// The 20-byte [ViInfoPreGap] record between the block list and the first
  /// descriptor (`null` in the raw-fallback case).
  final ViInfoPreGap? preGap;

  /// The contiguous 20-byte section descriptor records in address order (every
  /// one is a real block-referenced section). Empty in the fallback case.
  final List<ViSectionDescriptor> descriptors;

  /// The name-table tail (header + trailing VI name), typed. In the raw-fallback
  /// case this holds everything after the block list.
  final ViNameTable nameTable;

  /// Back-compat view: all bytes after the block list, as raw.
  Uint8List get rest => (BytesBuilder()
        ..add(preGap?.serialize() ?? Uint8List(0))
        ..add(_descriptorBytes())
        ..add(nameTable.serialize()))
      .toBytes();

  Uint8List _descriptorBytes() {
    final b = BytesBuilder();
    for (final d in descriptors) {
      b.add(d.serialize());
    }
    return b.toBytes();
  }

  factory ViInfoArea.parse(Uint8List infoArea) {
    final subheader = ViInfoSubheader.parse(infoArea);
    final blockList = ViBlockList.parse(infoArea, subheader.blockListRel);
    final restStart = subheader.blockListRel + blockList.byteLength;
    final descBase = subheader.blockListRel + 8;

    final maxRecords = infoArea.length ~/ 20;
    var minStart = infoArea.length, maxEnd = 0;
    var inBounds = true;
    for (final e in blockList.entries) {
      final n = e.sectionCountMinus1 + 1;
      for (var s = 0; s < n && s <= maxRecords; s++) {
        final dpos = descBase + e.descRel + s * 20;
        if (dpos + 20 > infoArea.length) {
          inBounds = false;
          break;
        }
        if (dpos < minStart) minStart = dpos;
        if (dpos + 20 > maxEnd) maxEnd = dpos + 20;
      }
    }

    final clean = inBounds && maxEnd > minStart && minStart == restStart + 20 && (maxEnd - minStart) % 20 == 0;
    if (clean) {
      final total = (maxEnd - minStart) ~/ 20;
      return ViInfoArea(
        subheader: subheader,
        blockList: blockList,
        preGap: ViInfoPreGap.parse(Uint8List.fromList(infoArea.sublist(restStart, restStart + 20))),
        descriptors: [for (var i = 0; i < total; i++) ViSectionDescriptor.parse(infoArea, minStart + i * 20)],
        nameTable: ViNameTable.parse(Uint8List.fromList(infoArea.sublist(maxEnd)),
            nameStart: subheader.viNameOffset == null ? null : subheader.viNameOffset! - maxEnd),
      );
    }
    return ViInfoArea(
      subheader: subheader,
      blockList: blockList,
      preGap: null,
      descriptors: const [],
      nameTable: ViNameTable.parse(Uint8List.fromList(infoArea.sublist(restStart))),
    );
  }

  Uint8List serialize() {
    final out = BytesBuilder()
      ..add(subheader.serialize())
      ..add(blockList.serialize())
      ..add(preGap?.serialize() ?? Uint8List(0))
      ..add(_descriptorBytes())
      ..add(nameTable.serialize());
    return out.toBytes();
  }
}

/// A **lossless** decomposition of an RSRC (`.vi`) container into its three
/// contiguous regions, plus a byte-exact serializer. This is the foundation for
/// the VI exporter/editor and the export→import idempotency test: parsing then
/// serializing an unmodified container must reproduce the original bytes exactly,
/// which is the strongest end-to-end proof that our container interpretation is
/// complete (nothing is dropped or misread).
///
/// Corpus-validated layout (7583/7583 files): the 32-byte header declares
/// `dataOffset` (@24) and `infoOffset` (@16); the file is exactly
/// `[0, dataOffset) header` ++ `[dataOffset, infoOffset) data area` ++
/// `[infoOffset, end) info area` — three ordered, contiguous, non-overlapping
/// spans (`dataOffset == 32`, `dataOffset + dataSize == infoOffset`). We split on
/// the declared offsets (not assumptions), so the partition is exact for any
/// well-ordered container and reconstruction is `header ++ data ++ info`.
///
/// Finer structure (sections, padding gaps, info-area descriptors, name table)
/// lives *within* [dataArea]/[infoArea] and is decomposed by later layers; this
/// model guarantees the whole-file round-trip those layers build on.
class ViContainer {
  ViContainer({required this.header, required this.dataArea, required this.infoArea});

  /// `[0, dataOffset)` — the 32-byte RSRC header (and anything before the data
  /// area, though `dataOffset == 32` in every observed file).
  final Uint8List header;

  /// `[dataOffset, infoOffset)` — the data area: the section payloads
  /// (`[u32 len][bytes]` each) plus inter-section padding, exactly as stored.
  final Uint8List dataArea;

  /// `[infoOffset, end)` — the info area: the block-info list, 20-byte section
  /// descriptors, the name table, and the trailing VI name, exactly as stored.
  final Uint8List infoArea;

  /// The fully-typed view of the 32-byte [header] (the first exporter region
  /// modeled field-by-field). `parsedHeader.serialize()` reproduces [header]
  /// byte-for-byte; over time the raw [dataArea]/[infoArea] spans become typed
  /// structs the same way until nothing opaque remains.
  ViHeader get parsedHeader => ViHeader.parse(header);

  /// The typed view of the info area's fixed subheader prefix (the dup header +
  /// `blockListRel`). Another region modeled toward a fully-typed exporter.
  ViInfoSubheader get parsedInfoSubheader => ViInfoSubheader.parse(infoArea);

  /// The typed view of the info area's block list (the resource-block directory).
  ViBlockList get parsedBlockList => ViBlockList.parse(infoArea, ViInfoSubheader.parse(infoArea).blockListRel);

  /// The info area composed as typed regions (subheader + block list + raw tail).
  ViInfoArea get parsedInfoArea => ViInfoArea.parse(infoArea);

  /// Re-emits the whole file from the **typed** model — `ViHeader.serialize()` +
  /// the (still-raw) data area + `ViInfoArea.serialize()`. Byte-identical to the
  /// input (and to [toBytes]) for an unmodified container; the proof that the
  /// typed regions compose losslessly as they replace the raw spans.
  Uint8List serialize() {
    final h = parsedHeader.serialize();
    final info = parsedInfoArea.serialize();
    final out = Uint8List(h.length + dataArea.length + info.length);
    out
      ..setRange(0, h.length, h)
      ..setRange(h.length, h.length + dataArea.length, dataArea)
      ..setRange(h.length + dataArea.length, out.length, info);
    return out;
  }

  /// The RSRC magic bytes (`RSRC\r\n`) every container/header begins with.
  static const List<int> _magic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

  /// Splits [bytes] into the three regions on the header's declared offsets.
  /// Lossless: the regions concatenate back to the input. Throws
  /// [ViFormatException] on a non-RSRC or mis-ordered container (so a caller can
  /// distinguish "can't round-trip this" from a silent partial parse).
  factory ViContainer.parse(Uint8List bytes) {
    if (bytes.length < 32) throw ViFormatException('too small to be an RSRC file');
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) throw ViFormatException('not an RSRC/.vi file (bad magic)');
    }
    final d = ByteData.sublistView(bytes);
    final infoOffset = d.getUint32(16);
    final dataOffset = d.getUint32(24);
    if (!(dataOffset >= 32 && dataOffset <= infoOffset && infoOffset <= bytes.length)) {
      throw ViFormatException('unexpected region order (dataOffset=$dataOffset, infoOffset=$infoOffset, len=${bytes.length})');
    }
    return ViContainer(
      header: Uint8List.sublistView(bytes, 0, dataOffset),
      dataArea: Uint8List.sublistView(bytes, dataOffset, infoOffset),
      infoArea: Uint8List.sublistView(bytes, infoOffset, bytes.length),
    );
  }

  /// Re-emits the container as bytes. For a container parsed and left unmodified
  /// this is byte-identical to the input (the idempotency contract).
  Uint8List toBytes() {
    final out = Uint8List(header.length + dataArea.length + infoArea.length);
    out
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + dataArea.length, dataArea)
      ..setRange(header.length + dataArea.length, out.length, infoArea);
    return out;
  }
}

/// The whole `.vi` file as a **fully-typed model** — the capstone of the
/// exporter re-architecture. A VI is its [header], an ordered list of data-area
/// [dataSegments] (length-prefixed sections + padding gaps), and its typed
/// [infoArea]. [serialize] reassembles the exact original bytes:
/// `header.serialize() ++ rebuildDataArea(dataSegments) ++ infoArea.serialize()`.
///
/// Corpus-validated: `ViVi.parse(bytes).serialize() == bytes` byte-for-byte for
/// every VI. The only bytes still held raw are (a) clearly-TODO'd unknown words
/// inside the typed structs, and (b) each section's compressed heap payload
/// ([ViSectionData.payload]) — whose *contents* are modeled separately in
/// `labwright_rsrc_parse`.
///
/// NOTE: [serialize] does NOT recompute cross-region offsets — it re-emits the
/// fields as-is. So a section-length change must go through [ViExport.editSection]
/// (which fixes the header `dataSize`/`infoOffset` and shifts later descriptor
/// `secRel`s); mutating [dataSegments]/[ViSectionData.payload] directly and then
/// serializing would emit an internally-inconsistent file. // TODO(labwright):
/// add a ViVi-level edit that recomputes those offsets so direct edits are safe.
class ViVi {
  ViVi({required this.header, required this.dataSegments, required this.infoArea});

  final ViHeader header;
  final List<ViDataSegment> dataSegments;
  final ViInfoArea infoArea;

  factory ViVi.parse(Uint8List bytes) {
    final container = ViContainer.parse(bytes);
    return ViVi(
      header: ViHeader.parse(container.header),
      dataSegments: ViExport.decomposeDataArea(bytes),
      infoArea: ViInfoArea.parse(container.infoArea),
    );
  }

  /// The recovered VI name (from the info-area name table), or null.
  String? get name => infoArea.nameTable.trailingName;

  /// The data-area sections (length-prefixed payloads), in storage order.
  Iterable<ViSectionData> get sections => dataSegments.whereType<ViSectionData>();

  /// Returns a NEW, coherent [ViVi] with the section at [secRel] replaced by
  /// [newPayload] — the **safe** way to edit. It routes through the corpus-tested
  /// [ViExport.editSection], which applies every offset fixup (the section's
  /// length prefix, later sections' bytes + descriptor `secRel`s, and the header
  /// `dataSize`/`infoOffset`), so the result re-parses and re-serializes exactly.
  /// (Mutating [dataSegments]/[ViSectionData.payload] in place and re-serializing
  /// does NOT recompute those offsets and would desync — always use this.)
  /// Throws [ViFormatException] if [secRel] is not a section start.
  ViVi withSectionEdited({required int secRel, required Uint8List newPayload}) =>
      ViVi.parse(ViExport.editSection(serialize(), secRel: secRel, newPayload: newPayload));

  Uint8List serialize() {
    final h = header.serialize();
    final data = ViExport.rebuildDataArea(dataSegments);
    final info = infoArea.serialize();
    final out = Uint8List(h.length + data.length + info.length);
    out
      ..setRange(0, h.length, h)
      ..setRange(h.length, h.length + data.length, data)
      ..setRange(h.length + data.length, out.length, info);
    return out;
  }
}

/// One piece of the data area in storage order: either a [ViSectionData] (a
/// `[u32 len][payload]` section located by its `secRel`) or a [ViGap] (the
/// padding bytes between/around sections). Together they tile `[0, dataSize)`.
sealed class ViDataSegment {
  const ViDataSegment();
}

/// Padding bytes in the data area, kept verbatim so a rebuild is byte-exact.
class ViGap extends ViDataSegment {
  const ViGap(this.bytes);
  final Uint8List bytes;
}

/// A stored section: its data-area-relative offset and its raw payload (the bytes
/// AFTER the `u32` length prefix). [ViExport.rebuildDataArea] re-prefixes the
/// length on serialization, so editing [payload] is sufficient to re-export.
class ViSectionData extends ViDataSegment {
  const ViSectionData({required this.secRel, required this.payload});
  final int secRel;
  final Uint8List payload;
}

/// Data-area decomposition + reconstruction — the editable layer over the
/// lossless [ViContainer]. Corpus-validated: sections (located via the info-area
/// descriptors) plus the gaps between them tile the data area exactly, so
/// `rebuildDataArea(decomposeDataArea(bytes)) == ViContainer.parse(bytes).dataArea`
/// byte-for-byte for 100% of VIs — the section-level idempotency contract.
bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

abstract final class ViExport {
  /// Decomposes the data area of [viBytes] into ordered sections + gaps. Section
  /// positions come from the info-area descriptors ([readViSections]) as a sorted
  /// set of distinct offsets (a section's bytes may be referenced by more than one
  /// descriptor); the span length is read from the section's own `u32` prefix
  /// (authoritative).
  static List<ViDataSegment> decomposeDataArea(Uint8List viBytes) {
    final c = ViContainer.parse(viBytes);
    final data = c.dataArea;
    final bd = ByteData.sublistView(data);
    final secRels = <int>{for (final s in readViSections(viBytes)) s.dataOffset}.toList()..sort();
    final segs = <ViDataSegment>[];
    var pos = 0;
    for (final secRel in secRels) {
      if (secRel < pos || secRel + 4 > data.length) continue;
      if (secRel > pos) segs.add(ViGap(Uint8List.sublistView(data, pos, secRel)));
      final len = bd.getUint32(secRel);
      final end = secRel + 4 + len;
      if (end > data.length) {
        segs.add(ViGap(Uint8List.sublistView(data, secRel)));
        pos = data.length;
        break;
      }
      segs.add(ViSectionData(secRel: secRel, payload: Uint8List.sublistView(data, secRel + 4, end)));
      pos = end;
    }
    if (pos < data.length) segs.add(ViGap(Uint8List.sublistView(data, pos)));
    return segs;
  }

  /// Re-emits the data-area bytes from [segments]: gaps verbatim, sections as
  /// `[u32 len][payload]`. The inverse of [decomposeDataArea] for unmodified
  /// input; editing a [ViSectionData.payload] changes only that section's bytes
  /// (the length prefix is recomputed here).
  static Uint8List rebuildDataArea(List<ViDataSegment> segments) {
    final out = BytesBuilder();
    for (final s in segments) {
      switch (s) {
        case ViGap(:final bytes):
          out.add(bytes);
        case ViSectionData(:final payload):
          final prefix = ByteData(4)..setUint32(0, payload.length);
          out
            ..add(prefix.buffer.asUint8List())
            ..add(payload);
      }
    }
    return out.toBytes();
  }

  /// Walks the section descriptors inside an info-area buffer, yielding each
  /// real descriptor's position (relative to the info-area start) and its
  /// `secRel`. Mirrors `readViSections` but operates on the isolated info area
  /// (so offsets are info-relative): `blockListRel@0x2c` → block list
  /// (`u32 count` + `count` × 12-byte entries) → 20-byte descriptors, keeping
  /// only the VI's own data sections (`+16` word `0xFFFFFFFF`) and skipping the
  /// LIBN/VINS sections (`+16` word `0`) — their bytes are still preserved raw as
  /// data-area gaps, so the byte-exact round-trip is unaffected.
  static List<({int dpos, int secRel})> _infoDescriptors(Uint8List info) {
    final out = <({int dpos, int secRel})>[];
    if (info.length < 0x30) return out;
    final ibd = ByteData.sublistView(info);
    final blockListRel = ibd.getUint32(0x2c);
    final countPos = blockListRel;
    if (countPos + 4 > info.length) return out;
    final count = ibd.getUint32(countPos);
    if (count > 100000) return out;
    const commonWord16 = 0xFFFFFFFF;
    const descSize = 20;
    final descBase = countPos + 8;
    var entry = countPos + 4;
    for (var i = 0; i < count && entry + 12 <= info.length; i++) {
      final sectionCount = ibd.getUint32(entry + 4) + 1;
      final descRel = ibd.getUint32(entry + 8);
      entry += 12;
      for (var s = 0; s < sectionCount; s++) {
        final dpos = descBase + descRel + s * descSize;
        if (dpos + descSize > info.length) break;
        if (ibd.getUint32(dpos + 16) != commonWord16) continue;
        out.add((dpos: dpos, secRel: ibd.getUint32(dpos + 4)));
      }
    }
    return out;
  }

  /// Replaces the payload of the section at [secRel] with [newPayload] and
  /// re-serializes the whole `.vi`, applying every offset fixup so the result is
  /// a valid container that re-parses to the edited content. This is the core of
  /// the VI editor: change one section's bytes, get back a coherent file.
  ///
  /// Fixups, given `delta = newPayload.length - oldPayload.length`:
  /// - the section's own `u32` length prefix → `newPayload.length`;
  /// - every later data-area section shifts by `delta` (handled by rebuilding
  ///   from [decomposeDataArea]);
  /// - every info-area descriptor whose `secRel` is **strictly past** [secRel]
  ///   gets `delta` added (descriptors at or before the edit, incl. ones sharing
  ///   [secRel], are unchanged);
  /// - the header's `infoOffset@16` and `dataSize@28` grow by `delta`
  ///   (`dataOffset@24` is unaffected — the data area still starts at 32).
  ///
  /// A no-op edit (`newPayload` equal to the current payload) reproduces the
  /// input byte-for-byte. Corpus-validated across 7583 VIs (no-op byte-exact;
  /// grow and shrink both re-parse with the target updated and all other sections
  /// byte-identical). Throws [ViFormatException] if [secRel] is not a section
  /// start in the data area, or if the data area does not cleanly decompose
  /// (an overlapping/out-of-range/truncated section would desync the descriptor
  /// fixups) — only already-malformed VIs fail that check.
  static Uint8List editSection(Uint8List viBytes, {required int secRel, required Uint8List newPayload}) {
    final c = ViContainer.parse(viBytes);
    final segs = decomposeDataArea(viBytes);
    if (!_listEquals(rebuildDataArea(segs), c.dataArea)) {
      throw ViFormatException('data area does not cleanly decompose; refusing to edit');
    }
    ViSectionData? target;
    for (final s in segs) {
      if (s is ViSectionData && s.secRel == secRel) {
        target = s;
        break;
      }
    }
    if (target == null) {
      throw ViFormatException('no section at secRel $secRel to edit');
    }
    final delta = newPayload.length - target.payload.length;

    final newSegs = [
      for (final s in segs)
        if (s is ViSectionData && s.secRel == secRel) ViSectionData(secRel: secRel, payload: newPayload) else s,
    ];
    final newData = rebuildDataArea(newSegs);

    final newInfo = Uint8List.fromList(c.infoArea);
    if (delta != 0) {
      final ibd = ByteData.sublistView(newInfo);
      for (final dsc in _infoDescriptors(newInfo)) {
        if (dsc.secRel > secRel) ibd.setUint32(dsc.dpos + 4, dsc.secRel + delta);
      }
    }

    final newHeader = Uint8List.fromList(c.header);
    final hbd = ByteData.sublistView(newHeader);
    hbd
      ..setUint32(16, hbd.getUint32(16) + delta)
      ..setUint32(28, hbd.getUint32(28) + delta);

    final out = Uint8List(newHeader.length + newData.length + newInfo.length);
    out
      ..setRange(0, newHeader.length, newHeader)
      ..setRange(newHeader.length, newHeader.length + newData.length, newData)
      ..setRange(newHeader.length + newData.length, out.length, newInfo);
    return out;
  }
}
