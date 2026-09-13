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

  final int fileLength;

  final bool byteExact;

  final int headerBytes;

  final int infoStructBytes;

  final int sectionPrefixBytes;

  final int typedPayloadBytes;

  final int alignPadBytes;

  final int infoRawBytes;

  final int gapBytes;

  final int compressedPayloadBytes;

  final int untypedPayloadBytes;

  final int inflatedContentBytes;

  final int heapModelBytes;

  final int heapCopiedBytes;

  final int heapModelBugs;

  final int imageCompressedBytes;

  final int imageInflatedBytes;

  final int imageInflatedModelBytes;

  final int imageInflatedCopiedBytes;

  int get modelBytes => headerBytes + infoStructBytes + sectionPrefixBytes + typedPayloadBytes + alignPadBytes;

  int get copiedBytes => infoRawBytes + gapBytes + compressedPayloadBytes + untypedPayloadBytes;

  int get contentTotalBytes =>
      fileLength - compressedPayloadBytes + inflatedContentBytes - imageCompressedBytes + imageInflatedBytes;

  int get contentModelBytes => modelBytes + heapModelBytes + imageInflatedModelBytes;

  int get contentCopiedBytes =>
      copiedBytes - compressedPayloadBytes + heapCopiedBytes - imageCompressedBytes + imageInflatedCopiedBytes;
}

const int _maxEmbedDepth = 8;

WriterAttribution attributeVi(Uint8List bytes, {int depth = 0}) {
  final vi = ViVi.parse(bytes);
  final info = vi.infoArea;

  final sections = readViSections(bytes);
  final tagBySecRel = <int, String>{};
  final secIndexBySecRel = <int, int>{};
  for (final s in sections) {
    tagBySecRel[s.dataOffset] = s.tag;
    secIndexBySecRel[s.dataOffset] = s.index;
  }

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
    final sectionIndex = secIndexBySecRel[secRel];
    final tm80 = (sectionIndex == null ? null : tm80BySection[sectionIndex]) ?? tm80BySection.values.first;
    return DfdsContext(vctp: vctp, tm80: tm80, verGe10: verGe10);
  }

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
          final image = tag == null ? null : decodeImageBlock(tag, payload);
          final meta = tag == null ? null : frameMetafile(tag, payload);
          if (modeled != null) {
            typedPayload += payload.length;
          } else if (meta != null && _eq(meta.bytes, payload)) {
            typedPayload += meta.modelBytes;
            untyped += meta.copiedBytes;
          } else if (image != null && _eq(image.bytes, payload)) {
            typedPayload += image.modelBytes;
            untyped += image.copiedBytes;
            imageCompressed += image.compressedContentBytes;
            imageInflated += image.inflatedContentBytes;
            imageInflatedModel += image.inflatedModelBytes;
            imageInflatedCopied += image.inflatedCopiedBytes;
          } else if (isCompressedHeapPayload(payload)) {
            compressed += payload.length;
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
