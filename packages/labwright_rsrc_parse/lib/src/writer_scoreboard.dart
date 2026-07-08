/// The **writer scoreboard** — byte attribution for the byte-exact `.vi` writer.
///
/// `ViVi.serialize` re-emits every `.vi` byte-for-byte, but not every byte is
/// *model-sourced*: the container/info-area structs are rebuilt from typed
/// fields, while section payloads (and a few TODO-raw struct words) are copied
/// verbatim from the input. This partitions every byte of a `.vi` into **model**
/// bytes (emitted from a typed, understood field) and **copied** bytes (verbatim
/// spans), so a corpus sweep measures the model fraction while byte-exactness
/// stays pinned.
///
/// The partition tiles the whole file (`modelBytes + copiedBytes == fileLength`,
/// asserted as a law), so the two totals are exhaustive and non-overlapping.
///
/// Categories (model): the 32-byte header; the info-area structs (dup header,
/// `blockListRel`, block list, preGap, section descriptors, trailing VI name);
/// each section's recomputed `u32` length prefix; and payloads re-emitted by a
/// block writer ([serializeBlockPayload]). Categories (copied): TODO-raw struct
/// words (subheader `reservedA`/`reservedB`, name-table header); data-area gaps;
/// compressed payloads (the zlib heap — copy-verbatim, since NI's deflate is
/// not bit-reproducible); and uncompressed-but-untyped payloads.
library;

import 'dart:typed_data';

import 'blocks/block_writer.dart';
import 'container.dart';
import 'viparse.dart' show readViSections;

/// A single `.vi`'s byte attribution. Every field is a byte count; the model
/// and copied category groups each sum to [modelBytes]/[copiedBytes], and those
/// two sum to [fileLength].
class WriterAttribution {
  WriterAttribution({
    required this.fileLength,
    required this.byteExact,
    required this.headerBytes,
    required this.infoStructBytes,
    required this.sectionPrefixBytes,
    required this.typedPayloadBytes,
    required this.infoRawBytes,
    required this.gapBytes,
    required this.compressedPayloadBytes,
    required this.untypedPayloadBytes,
  });

  /// Total file length in bytes (`modelBytes + copiedBytes`).
  final int fileLength;

  /// Whether `ViVi.parse(bytes).serialize()` reproduced the input exactly.
  final bool byteExact;

  // --- model categories ---
  /// The 32-byte RSRC header.
  final int headerBytes;

  /// Typed info-area struct bytes (dup header, `blockListRel`, block list,
  /// preGap record, section descriptors, trailing VI-name record).
  final int infoStructBytes;

  /// Recomputed `u32` section-length prefixes (4 bytes per data-area section).
  final int sectionPrefixBytes;

  /// Payload bytes re-emitted by a block writer ([serializeBlockPayload]).
  final int typedPayloadBytes;

  // --- copied categories ---
  /// TODO-raw info-area struct spans (subheader `reservedA`/`reservedB`,
  /// name-table header) — named but not decoded, kept verbatim.
  final int infoRawBytes;

  /// Data-area padding gaps between/around sections.
  final int gapBytes;

  /// Compressed (zlib heap) payloads — the permanent copy-verbatim floor.
  final int compressedPayloadBytes;

  /// Uncompressed payloads with no byte-exact block writer.
  final int untypedPayloadBytes;

  /// Bytes emitted from a typed, understood field.
  int get modelBytes => headerBytes + infoStructBytes + sectionPrefixBytes + typedPayloadBytes;

  /// Bytes copied verbatim from the input.
  int get copiedBytes => infoRawBytes + gapBytes + compressedPayloadBytes + untypedPayloadBytes;
}

/// Whether a stored section payload is a zlib heap stream (`[u32 size][0x78 …]`)
/// — the same cheap CMF-byte pre-check the decoder uses. Compressed payloads are
/// never modelable (NI deflate is not reproducible), so they are attributed as
/// the compressed copy-verbatim floor.
bool _looksCompressed(Uint8List payload) => payload.length >= 6 && payload[4] == 0x78;

/// Attributes every byte of [bytes] to a model or copied category. Throws
/// [ViFormatException] (from [ViVi.parse]) on a non-RSRC container; callers that
/// sweep the corpus should skip the lone non-RSRC fixture.
WriterAttribution attributeVi(Uint8List bytes) {
  final vi = ViVi.parse(bytes);
  final info = vi.infoArea;

  // secRel -> block tag, so each data-area section payload is dispatched to its
  // block writer. decomposeDataArea keys sections by these same offsets.
  final tagBySecRel = <int, String>{};
  for (final s in readViSections(bytes)) {
    tagBySecRel[s.dataOffset] = s.tag;
  }

  var sectionPrefix = 0, typedPayload = 0, gaps = 0, compressed = 0, untyped = 0;
  for (final seg in vi.dataSegments) {
    switch (seg) {
      case ViGap(:final bytes):
        gaps += bytes.length;
      case ViSectionData(:final secRel, :final payload):
        sectionPrefix += 4;
        final tag = tagBySecRel[secRel];
        final modeled = tag == null ? null : serializeBlockPayload(tag, payload);
        if (modeled != null) {
          typedPayload += payload.length;
        } else if (_looksCompressed(payload)) {
          compressed += payload.length;
        } else {
          untyped += payload.length;
        }
    }
  }

  // Info-area struct vs TODO-raw split. subheader: dup header (32) + blockListRel
  // (4) are struct; reservedA/reservedB are TODO-raw. blockList, preGap, and
  // descriptors are fully typed structs. name table: header is TODO-raw, the
  // trailing VI-name record is a typed field.
  final infoStruct =
      32 +
      4 +
      info.blockList.byteLength +
      (info.preGap == null ? 0 : 20) +
      20 * info.descriptors.length +
      info.nameTable.trailingNameRecord.length;
  final infoRaw = info.subheader.reservedA.length + info.subheader.reservedB.length + info.nameTable.header.length;

  final attribution = WriterAttribution(
    fileLength: bytes.length,
    byteExact: _eq(vi.serialize(), bytes),
    headerBytes: 32,
    infoStructBytes: infoStruct,
    sectionPrefixBytes: sectionPrefix,
    typedPayloadBytes: typedPayload,
    infoRawBytes: infoRaw,
    gapBytes: gaps,
    compressedPayloadBytes: compressed,
    untypedPayloadBytes: untyped,
  );
  return attribution;
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
