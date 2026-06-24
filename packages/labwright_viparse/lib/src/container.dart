import 'dart:typed_data';

import 'viparse.dart' show ViFormatException;

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
