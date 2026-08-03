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
/// The same reframe reaches one level deeper into the `DSIM`/`MNGI` image
/// sections — uncompressed container sections whose stored bytes carry a PNG
/// whose `IDAT` and compressed ancillary chunks (`iCCP`/`zTXt`/compressed
/// `iTXt`) hold nested zlib streams. At the content level a PNG image's
/// compressed nested-deflate stored size ([imageCompressedBytes]) is swapped for
/// its inflated content ([imageInflatedBytes], the raster via
/// [inflateImageRaster] plus the inflated ancillary profiles/text), which is
/// modeled ([imageInflatedModelBytes]): leaves that re-deflate to a standard
/// zlib stream carrying the same content. The compressed streams across the
/// corpus are replaced in the content total by their larger inflated content,
/// nearly all modeled.
///
/// Categories (byte model): the 32-byte header; the info-area structs (dup
/// header, `blockListRel`, block list, preGap, section descriptors, trailing VI
/// name); each section's recomputed `u32` length prefix; payloads re-emitted
/// by a block writer ([serializeBlockPayload]); and the inter-section alignment
/// padding a writer regenerates from the 4-byte-align rule ([alignPadBytes]).
/// Categories (byte copied): TODO-raw struct words (subheader
/// `reservedA`/`reservedB`, name-table header); the residual data-area gaps
/// (non-zero/over-long stale bytes and the trailing gap); compressed (zlib heap)
/// payloads, kept stored-verbatim by the byte-exact serialize path; and
/// uncompressed-but-untyped payloads.
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
import 'blocks/metafile_block.dart' show frameMetafile;
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
    required this.alignPadBytes,
    required this.infoRawBytes,
    required this.gapBytes,
    required this.compressedPayloadBytes,
    required this.untypedPayloadBytes,
    required this.inflatedContentBytes,
    required this.heapModelBytes,
    required this.heapCopiedBytes,
    required this.heapModelBugs,
    required this.imageCompressedBytes,
    required this.imageInflatedBytes,
    required this.imageInflatedModelBytes,
    required this.imageInflatedCopiedBytes,
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

  /// Data-area inter-section **alignment padding** emitted from a rule: the
  /// zero-fill that pads a section's start to the next 4-byte boundary. Each such
  /// gap is exactly `(4 - start%4) % 4` zero bytes before a section, so a writer
  /// regenerates it from the alignment rule (`pad to 4, fill 0`) rather than
  /// copying — model-derivable. Non-minimal or non-zero gaps (stale/dead data)
  /// and the trailing data-area gap are NOT this; they stay in [gapBytes].
  final int alignPadBytes;

  // --- copied categories ---
  /// TODO-raw info-area struct spans (subheader `reservedA`/`reservedB`,
  /// name-table header) — named but not decoded, kept verbatim.
  final int infoRawBytes;

  /// Data-area padding gaps kept verbatim: non-zero or over-long inter-section
  /// gaps (stale/dead bytes not derivable from an alignment rule) and the
  /// trailing gap after the last section. The rule-derivable zero alignment pad
  /// is counted in [alignPadBytes] (model) instead.
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

  // --- content-level categories (image PNG nested-deflate at inflated size) ---
  /// Compressed PNG nested-deflate stored bytes (the `IDAT` pixel stream plus the
  /// compressed ancillary chunks' zlib streams) swapped out of the content total
  /// for their inflated content. These bytes are also in [untypedPayloadBytes] at
  /// the byte level (a DSIM/MNGI section is an uncompressed container section); at
  /// the content level they are replaced by [imageInflatedBytes].
  final int imageCompressedBytes;

  /// Total inflated content size for every PNG-bearing image section (the raster
  /// plus the inflated ancillary profiles/text;
  /// `imageInflatedModelBytes + imageInflatedCopiedBytes`), swapped in for
  /// [imageCompressedBytes] in the content total.
  final int imageInflatedBytes;

  /// Inflated PNG content bytes modeled as content — leaves that re-deflate to a
  /// standard zlib stream carrying the same content.
  final int imageInflatedModelBytes;

  /// Inflated PNG content bytes not modeled as content (0 when every stream
  /// inflates cleanly).
  final int imageInflatedCopiedBytes;

  /// Bytes emitted from a typed, understood field or rule (byte level).
  int get modelBytes => headerBytes + infoStructBytes + sectionPrefixBytes + typedPayloadBytes + alignPadBytes;

  /// Bytes copied verbatim from the input (byte level).
  int get copiedBytes => infoRawBytes + gapBytes + compressedPayloadBytes + untypedPayloadBytes;

  /// Content total: the file length with each compressed heap section's stored
  /// size swapped for its inflated size and each PNG image's compressed
  /// nested-deflate streams swapped for their inflated content
  /// (`contentModelBytes + contentCopiedBytes`).
  int get contentTotalBytes =>
      fileLength - compressedPayloadBytes + inflatedContentBytes - imageCompressedBytes + imageInflatedBytes;

  /// Content bytes emitted from a typed model — the byte-level model plus the
  /// inflated heap content and the inflated image content re-emitted from a model.
  int get contentModelBytes => modelBytes + heapModelBytes + imageInflatedModelBytes;

  /// Content bytes copied verbatim — the byte-level copied set with the stored
  /// compressed heap payloads swapped for their inflated copied content and the
  /// compressed PNG nested-deflate streams swapped for their inflated copied
  /// fraction.
  int get contentCopiedBytes =>
      copiedBytes - compressedPayloadBytes + heapCopiedBytes - imageCompressedBytes + imageInflatedCopiedBytes;
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
      (info.preGap == null ? 0 : ViInfoPreGap.byteSize) +
      20 * info.descriptors.length +
      info.nameTable.trailingNameRecord.length;
  var infoRaw = info.subheader.reservedA.length + info.subheader.reservedB.length + info.nameTable.header.length;
  var sectionPrefix = 0, typedPayload = 0, alignPad = 0, gaps = 0, compressed = 0, untyped = 0;
  var inflatedContent = 0, heapModel = 0, heapCopied = 0, heapBugs = 0;
  var imageCompressed = 0, imageInflated = 0, imageInflatedModel = 0, imageInflatedCopied = 0;

  // Running data-area offset, so an inter-section gap can be tested against the
  // 4-byte-alignment rule (its start offset determines the minimal pad length).
  var dataPos = 0;
  final segs = vi.dataSegments;
  for (var i = 0; i < segs.length; i++) {
    final seg = segs[i];
    switch (seg) {
      case ViGap(:final bytes):
        final hasNextSection = i + 1 < segs.length && segs[i + 1] is ViSectionData;
        if (_isDerivableAlignPad(bytes, dataPos, hasNextSection)) {
          alignPad += bytes.length;
        } else {
          gaps += bytes.length;
        }
        dataPos += bytes.length;
      case ViSectionData(:final secRel, :final payload):
        dataPos += 4 + payload.length;
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
          alignPad += sub.alignPadBytes;
          gaps += sub.gapBytes;
          compressed += sub.compressedPayloadBytes;
          untyped += sub.untypedPayloadBytes;
          inflatedContent += sub.inflatedContentBytes;
          heapModel += sub.heapModelBytes;
          heapCopied += sub.heapCopiedBytes;
          heapBugs += sub.heapModelBugs;
          imageCompressed += sub.imageCompressedBytes;
          imageInflated += sub.imageInflatedBytes;
          imageInflatedModel += sub.imageInflatedModelBytes;
          imageInflatedCopied += sub.imageInflatedCopiedBytes;
        } else {
          final modeled = tag == null ? null : serializeBlockPayload(tag, payload, version: versionWord);
          // An image block (DSIM/MNGI) is PARTIALLY modeled: its decoded/reproduced
          // framing (PNG signature + chunk length/type/verified-CRC, the geometry
          // header) and byte-faithful uncompressed interiors are model; its
          // compressed chunk streams (IDAT/…) and undecoded trailer stay copied.
          final image = tag == null ? null : decodeImageBlock(tag, payload);
          // A PICT/WEMF metafile block is framed element-by-element: its
          // opcode/record headers, length prefixes, and picture/metafile header
          // are reconstructed (model), a PICT's uncompressed (`raw` codec)
          // QuickTime raster is modeled, and an element's still-undecoded opaque
          // interior (a non-`raw` QuickTime image, an EMF record's parameter
          // block) is retained verbatim (copied). No nested-deflate reframe
          // applies — a metafile's opaque leaves are not zlib streams — so its
          // model bytes count identically at the byte and content levels.
          final meta = tag == null ? null : frameMetafile(tag, payload);
          if (modeled != null) {
            typedPayload += payload.length;
          } else if (meta != null && _eq(meta.bytes, payload)) {
            typedPayload += meta.modelBytes;
            untyped += meta.copiedBytes;
          } else if (image != null && _eq(image.bytes, payload)) {
            typedPayload += image.modelBytes;
            untyped += image.copiedBytes;
            // Content level: the compressed PNG nested-deflate stored bytes (the
            // IDAT raster + ancillary streams, part of the byte-level copied set)
            // are swapped for their inflated content, modeled as content. A stream
            // that fails to inflate leaves its bytes counted copied at the content
            // level.
            imageCompressed += image.compressedContentBytes;
            imageInflated += image.inflatedContentBytes;
            imageInflatedModel += image.inflatedModelBytes;
            imageInflatedCopied += image.inflatedCopiedBytes;
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
    alignPadBytes: alignPad,
    infoRawBytes: infoRaw,
    gapBytes: gaps,
    compressedPayloadBytes: compressed,
    untypedPayloadBytes: untyped,
    inflatedContentBytes: inflatedContent,
    heapModelBytes: heapModel,
    heapCopiedBytes: heapCopied,
    heapModelBugs: heapBugs,
    imageCompressedBytes: imageCompressed,
    imageInflatedBytes: imageInflated,
    imageInflatedModelBytes: imageInflatedModel,
    imageInflatedCopiedBytes: imageInflatedCopied,
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

/// Whether a data-area [gap] is rule-derivable inter-section alignment padding:
/// it precedes a section ([hasNextSection]), is all-zero, and its length is
/// exactly the minimal pad that aligns the next section's start to a 4-byte
/// boundary (`(4 - gapStart%4) % 4`). Such a gap is regenerated from the
/// alignment rule, so it is attributed to model rather than copied. A non-zero,
/// over-long, or trailing gap fails this test and stays copied.
bool _isDerivableAlignPad(Uint8List gap, int gapStart, bool hasNextSection) {
  if (!hasNextSection) return false;
  final need = (4 - (gapStart & 3)) & 3;
  if (need == 0 || gap.length != need) return false;
  for (var i = 0; i < gap.length; i++) {
    if (gap[i] != 0) return false;
  }
  return true;
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
