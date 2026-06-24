import 'dart:typed_data';

import 'viparse.dart' show ViFormatException, readViSections;

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

  static const List<int> _magic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]; // "RSRC\r\n"

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
    // Require the observed, well-ordered layout so the three spans partition the
    // file exactly: 0 < dataOffset <= infoOffset <= length.
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
abstract final class ViExport {
  /// Decomposes the data area of [viBytes] into ordered sections + gaps. Section
  /// positions come from the info-area descriptors ([readViSections]); the span
  /// length is read from the section's own `u32` prefix (authoritative).
  static List<ViDataSegment> decomposeDataArea(Uint8List viBytes) {
    final c = ViContainer.parse(viBytes);
    final data = c.dataArea;
    final bd = ByteData.sublistView(data);
    // distinct section offsets (a section's bytes may be referenced by >1
    // descriptor); sorted so we can walk the data area front-to-back.
    final secRels = <int>{for (final s in readViSections(viBytes)) s.dataOffset}.toList()..sort();
    final segs = <ViDataSegment>[];
    var pos = 0;
    for (final secRel in secRels) {
      if (secRel < pos || secRel + 4 > data.length) continue; // overlap/oob: skip defensively
      if (secRel > pos) segs.add(ViGap(Uint8List.sublistView(data, pos, secRel)));
      final len = bd.getUint32(secRel);
      final end = secRel + 4 + len;
      if (end > data.length) {
        // truncated section descriptor — keep the remainder as a gap, stop.
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
  /// only rows whose `+16` word is the `0xFFFFFFFF` sentinel (section, not name).
  static List<({int dpos, int secRel})> _infoDescriptors(Uint8List info) {
    final out = <({int dpos, int secRel})>[];
    if (info.length < 0x30) return out;
    final ibd = ByteData.sublistView(info);
    final blockListRel = ibd.getUint32(0x2c);
    final countPos = blockListRel; // info-relative
    if (countPos < 0 || countPos + 4 > info.length) return out;
    final count = ibd.getUint32(countPos);
    if (count > 100000) return out;
    const sentinel = 0xFFFFFFFF;
    const descSize = 20;
    final descBase = countPos + 8;
    var entry = countPos + 4;
    for (var i = 0; i < count && entry + 12 <= info.length; i++) {
      final sectionCount = ibd.getUint32(entry + 4) + 1; // stored as count-1
      final descRel = ibd.getUint32(entry + 8);
      entry += 12;
      for (var s = 0; s < sectionCount; s++) {
        final dpos = descBase + descRel + s * descSize;
        if (dpos < 0 || dpos + descSize > info.length) break;
        if (ibd.getUint32(dpos + 16) != sentinel) continue; // name-table row
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
  /// start in the data area.
  static Uint8List editSection(Uint8List viBytes, {required int secRel, required Uint8List newPayload}) {
    final c = ViContainer.parse(viBytes);
    final segs = decomposeDataArea(viBytes);
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

    // data area: swap the target payload, rebuild (later spans shift with it)
    final newSegs = [
      for (final s in segs)
        if (s is ViSectionData && s.secRel == secRel) ViSectionData(secRel: secRel, payload: newPayload) else s,
    ];
    final newData = rebuildDataArea(newSegs);

    // info area: shift every descriptor secRel strictly past the edit point
    final newInfo = Uint8List.fromList(c.infoArea);
    if (delta != 0) {
      final ibd = ByteData.sublistView(newInfo);
      for (final dsc in _infoDescriptors(newInfo)) {
        if (dsc.secRel > secRel) ibd.setUint32(dsc.dpos + 4, dsc.secRel + delta);
      }
    }

    // header: bump infoOffset + dataSize by delta (dataOffset stays put)
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
