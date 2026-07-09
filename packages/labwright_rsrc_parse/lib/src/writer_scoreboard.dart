/// The **writer scoreboard** — byte attribution for the `.vi` writer, at two
/// levels: the raw **byte** model (stored file bytes) and the **content** model
/// (inflated-content bytes).
///
/// `ViVi.serialize` re-emits every `.vi` byte-for-byte, but not every byte is
/// *model-sourced*: the container/info-area structs are rebuilt from typed
/// fields, while section payloads (and a few TODO-raw struct words) are copied
/// verbatim. This partitions every byte of a `.vi` into **model** bytes (emitted
/// from a typed, understood field) and **copied** bytes (verbatim spans), so a
/// corpus sweep measures the model fraction while byte-exactness stays pinned.
/// The byte partition tiles the whole file (`modelBytes + copiedBytes ==
/// fileLength`, asserted as a law).
///
/// **Content level.** A compressed heap section's *stored* bytes are a zlib
/// stream, but LabVIEW/TestStand read the section THROUGH zlib, so correctness
/// is defined on the section's **inflated content** (see `content_exact.dart`).
/// The content scoreboard replaces each compressed section's stored size with
/// its inflated size and attributes that inflated content via the heap writer
/// ([serializeHeapBody]): [heapModelBytes] come from a typed heap-record model,
/// [heapCopiedBytes] are copied verbatim (undecoded / lossy interiors, the
/// leading `u32`, the walk tail). The content partition tiles the content total
/// (`contentModelBytes + contentCopiedBytes == contentTotalBytes`), where the
/// content total is the file length with each compressed section's stored size
/// swapped for its inflated size.
///
/// Categories (byte model): the 32-byte header; the info-area structs (dup
/// header, `blockListRel`, block list, preGap, section descriptors, trailing VI
/// name); each section's recomputed `u32` length prefix; and payloads re-emitted
/// by a block writer ([serializeBlockPayload]). Categories (byte copied):
/// TODO-raw struct words (subheader `reservedA`/`reservedB`, name-table header);
/// data-area gaps; compressed (zlib heap) payloads, kept stored-verbatim by the
/// byte-exact serialize path; and uncompressed-but-untyped payloads.
///
/// A `VINS` section carries a complete nested RSRC sub-VI. Its bytes are
/// attributed **recursively**: the sub-VI's own header/struct/prefix/model bytes
/// join the parent's model categories, its zlib heaps join the compressed
/// category, and its inflated heap content joins the parent's heap-model/copied
/// totals, rather than the parent counting the whole opaque sub-VI as one
/// untyped span. A sub-VI is folded only when it round-trips byte-exact.
library;

import 'dart:typed_data';

import 'blocks/block_writer.dart';
import 'blocks/dfds.dart' show DfdsContext;
import 'blocks/image_block.dart' show decodeImageBlock;
import 'blocks/version_word.dart' show versionWordFromSections;
import 'container.dart';
import 'decode.dart' show inflateHeapPayload, isCompressedHeapPayload;
import 'heap_writer.dart' show attributeHeapBody;
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
    required this.inflatedContentBytes,
    required this.heapModelBytes,
    required this.heapCopiedBytes,
    required this.heapModelBugs,
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

  /// Payload bytes re-emitted from a typed model: a whole-payload block writer
  /// ([serializeBlockPayload]), plus the modeled fraction of a partially-modeled
  /// image block ([decodeImageBlock] — PNG/geometry framing and uncompressed
  /// interiors; its compressed streams land in [untypedPayloadBytes]).
  final int typedPayloadBytes;

  // --- copied categories ---
  /// TODO-raw info-area struct spans (subheader `reservedA`/`reservedB`,
  /// name-table header) — named but not decoded, kept verbatim.
  final int infoRawBytes;

  /// Data-area padding gaps between/around sections.
  final int gapBytes;

  /// Compressed (zlib heap) payloads, as *stored* — kept stored-verbatim by the
  /// byte-exact serialize path. The content scoreboard attributes these sections
  /// at their inflated size instead (see [heapModelBytes] / [heapCopiedBytes]).
  final int compressedPayloadBytes;

  /// Uncompressed payloads with no byte-exact block writer, plus the opaque
  /// fraction of a partially-modeled image block (compressed PNG chunk streams
  /// and any undecoded trailer — see [typedPayloadBytes]).
  final int untypedPayloadBytes;

  // --- content-level categories (compressed sections at inflated size) ---
  /// Total inflated size of every compressed heap section (`heapModelBytes +
  /// heapCopiedBytes`); a section that fails to inflate contributes its stored
  /// size, kept copied.
  final int inflatedContentBytes;

  /// Inflated heap-content bytes re-emitted from a typed heap-record model
  /// ([serializeHeapBody]).
  final int heapModelBytes;

  /// Inflated heap-content bytes copied verbatim (undecoded / lossy interiors,
  /// the leading `u32` content-length, the walk tail) plus any section that
  /// failed to inflate.
  final int heapCopiedBytes;

  /// Count of heap records the model expected to reconstruct losslessly but did
  /// not — surfaced as a loud regression signal (0 for a faithful model).
  final int heapModelBugs;

  /// Bytes emitted from a typed, understood field (byte level).
  int get modelBytes => headerBytes + infoStructBytes + sectionPrefixBytes + typedPayloadBytes;

  /// Bytes copied verbatim from the input (byte level).
  int get copiedBytes => infoRawBytes + gapBytes + compressedPayloadBytes + untypedPayloadBytes;

  /// Content total: the file length with each compressed section's stored size
  /// swapped for its inflated size (`contentModelBytes + contentCopiedBytes`).
  int get contentTotalBytes => fileLength - compressedPayloadBytes + inflatedContentBytes;

  /// Content bytes emitted from a typed model — the byte-level model plus the
  /// inflated heap content re-emitted from the heap model.
  int get contentModelBytes => modelBytes + heapModelBytes;

  /// Content bytes copied verbatim — the byte-level copied set with the stored
  /// compressed payloads swapped for their inflated copied content.
  int get contentCopiedBytes => copiedBytes - compressedPayloadBytes + heapCopiedBytes;
}

/// Recursion bound for nested `VINS` embedded sub-VIs. A VI may embed sub-VIs
/// that themselves embed sub-VIs; the bound keeps attribution total on any input.
const int _maxEmbedDepth = 8;

/// Attributes every byte of [bytes] to a model or copied category. Throws
/// [ViFormatException] (from [ViVi.parse]) on a non-RSRC container; callers that
/// sweep the corpus should skip the lone non-RSRC fixture.
///
/// [depth] tracks `VINS` embedded-sub-VI recursion (see [_maxEmbedDepth]); the
/// top-level call uses `0`.
WriterAttribution attributeVi(Uint8List bytes, {int depth = 0}) {
  final vi = ViVi.parse(bytes);
  final info = vi.infoArea;

  // secRel -> block tag, so each data-area section payload is dispatched to its
  // block writer. decomposeDataArea keys sections by these same offsets.
  final sections = readViSections(bytes);
  final tagBySecRel = <int, String>{};
  final secIndexBySecRel = <int, int>{};
  for (final s in sections) {
    tagBySecRel[s.dataOffset] = s.tag;
    secIndexBySecRel[s.dataOffset] = s.index;
  }

  // DFDS default-data-space framing needs the VI's VCTP type pool and TM80 type
  // map (see [DfdsContext]). Inflate the VCTP (single) and each TM80 by its
  // section index once, so a DFDS section can be paired with the TM80 of the same
  // index (falling back to the first). Absent context leaves DFDS copied.
  Uint8List? vctpBody;
  final tm80BySection = <int, Uint8List>{};
  for (final s in sections) {
    if (s.tag != 'VCTP' && s.tag != 'TM80') continue;
    final body = inflateHeapPayload(s.bytes) ?? s.bytes;
    if (s.tag == 'VCTP') {
      vctpBody ??= body;
    } else {
      tm80BySection[s.index] = body;
    }
  }
  final versionWord = versionWordFromSections(sections);
  final verGe10 = (versionWord?.major ?? 0) >= 10;
  DfdsContext? dfdsContextFor(int secRel) {
    final vctp = vctpBody;
    if (vctp == null || tm80BySection.isEmpty) return null;
    final tm80 = tm80BySection[secIndexBySecRel[secRel]] ?? tm80BySection.values.first;
    return DfdsContext(vctp: vctp, tm80: tm80, verGe10: verGe10);
  }

  // Info-area struct vs TODO-raw split. subheader: dup header (32) + blockListRel
  // (4) are struct; reservedA/reservedB are TODO-raw. blockList, preGap, and
  // descriptors are fully typed structs. name table: header is TODO-raw, the
  // trailing VI-name record is a typed field. Seeded here and grown by the
  // embedded sub-VIs a VINS section carries, so a nested VI's own struct/raw
  // bytes land in the matching category rather than the parent's untyped bucket.
  var header = 32;
  var infoStruct =
      32 +
      4 +
      info.blockList.byteLength +
      (info.preGap == null ? 0 : 20) +
      20 * info.descriptors.length +
      info.nameTable.trailingNameRecord.length;
  var infoRaw = info.subheader.reservedA.length + info.subheader.reservedB.length + info.nameTable.header.length;
  var sectionPrefix = 0, typedPayload = 0, gaps = 0, compressed = 0, untyped = 0;
  var inflatedContent = 0, heapModel = 0, heapCopied = 0, heapBugs = 0;

  for (final seg in vi.dataSegments) {
    switch (seg) {
      case ViGap(:final bytes):
        gaps += bytes.length;
      case ViSectionData(:final secRel, :final payload):
        sectionPrefix += 4;
        final tag = tagBySecRel[secRel];
        // A VINS section's payload is a complete nested RSRC sub-VI. Attribute it
        // recursively so its bytes land in the matching category — crucially its
        // zlib heaps join the compressed category, not model — instead of the
        // parent counting the whole opaque sub-VI as one untyped span.
        final sub = tag == 'VINS' && depth < _maxEmbedDepth ? _attributeEmbedded(payload, depth + 1) : null;
        if (sub != null) {
          header += sub.headerBytes;
          infoStruct += sub.infoStructBytes;
          infoRaw += sub.infoRawBytes;
          sectionPrefix += sub.sectionPrefixBytes;
          typedPayload += sub.typedPayloadBytes;
          gaps += sub.gapBytes;
          compressed += sub.compressedPayloadBytes;
          untyped += sub.untypedPayloadBytes;
          inflatedContent += sub.inflatedContentBytes;
          heapModel += sub.heapModelBytes;
          heapCopied += sub.heapCopiedBytes;
          heapBugs += sub.heapModelBugs;
        } else {
          final modeled = tag == null ? null : serializeBlockPayload(tag, payload, version: versionWord);
          // An image block (DSIM/MNGI) is PARTIALLY modeled: its decoded/reproduced
          // framing (PNG signature + chunk length/type/verified-CRC, the geometry
          // header) and byte-faithful uncompressed interiors are model; its
          // compressed chunk streams (IDAT/…) and undecoded trailer stay copied.
          final image = tag == null ? null : decodeImageBlock(tag, payload);
          if (modeled != null) {
            typedPayload += payload.length;
          } else if (image != null && _eq(image.bytes, payload)) {
            typedPayload += image.modelBytes;
            untyped += image.copiedBytes;
          } else if (isCompressedHeapPayload(payload)) {
            compressed += payload.length;
            // Content level: attribute the section's INFLATED content via the
            // heap writer. A section that fails to inflate contributes its stored
            // size, all copied, so the content total still tiles.
            final inflated = inflateHeapPayload(payload);
            if (inflated != null) {
              final res = attributeHeapBody(inflated, tag, tag == 'DFDS' ? dfdsContextFor(secRel) : null);
              inflatedContent += inflated.length;
              heapModel += res.modelBytes;
              heapCopied += res.copiedBytes;
              heapBugs += res.modelBugs;
            } else {
              inflatedContent += payload.length;
              heapCopied += payload.length;
            }
          } else {
            untyped += payload.length;
          }
        }
    }
  }

  final attribution = WriterAttribution(
    fileLength: bytes.length,
    byteExact: _eq(vi.serialize(), bytes),
    headerBytes: header,
    infoStructBytes: infoStruct,
    sectionPrefixBytes: sectionPrefix,
    typedPayloadBytes: typedPayload,
    infoRawBytes: infoRaw,
    gapBytes: gaps,
    compressedPayloadBytes: compressed,
    untypedPayloadBytes: untyped,
    inflatedContentBytes: inflatedContent,
    heapModelBytes: heapModel,
    heapCopiedBytes: heapCopied,
    heapModelBugs: heapBugs,
  );
  return attribution;
}

/// Attributes a `VINS` embedded-sub-VI [payload] recursively, returning its
/// per-category split **iff** [payload] is a nested RSRC container that
/// round-trips byte-exact (so claiming its model bytes is honest). Returns null
/// otherwise (a non-RSRC or non-reproducible payload), so the caller keeps it in
/// the copied categories. Its own bytes tile [payload] exactly, so folding every
/// category into the parent preserves the parent's tiling law.
WriterAttribution? _attributeEmbedded(Uint8List payload, int depth) {
  if (payload.length < 4 || payload[0] != 0x52 || payload[1] != 0x53 || payload[2] != 0x52 || payload[3] != 0x43) {
    return null;
  }
  try {
    final sub = attributeVi(payload, depth: depth);
    return sub.byteExact ? sub : null;
  } catch (_) {
    return null;
  }
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
