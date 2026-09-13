@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

const _laws = {
  'attribute',
  'byteExact',
  'tiling',
  'contentTiling',
  'heapExact',
  'heapBugs',
  'reDeflate',
  'dfdsExact',
  'roundTrip',
  'enveloped',
  'plain',
  'imageExact',
  'ancillary',
  'raster',
  'pngCrc',
  'rasterCopied',
  'rasterModel',
  'metafileExact',
};

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<String, int> _violations(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bad(String k, [int by = 1]) => c[k] = (c[k] ?? 0) + by;

  try {
    final a = attributeVi(bytes);
    if (!a.byteExact) bad('byteExact');
    if (a.modelBytes + a.copiedBytes != a.fileLength) bad('tiling');
    if (a.contentModelBytes + a.contentCopiedBytes != a.contentTotalBytes) bad('contentTiling');
    bad('heapBugs', a.heapModelBugs);
    bad('rasterCopied', a.imageInflatedCopiedBytes);
    bad('rasterModel', (a.imageInflatedBytes - a.imageInflatedModelBytes).abs());
  } catch (_) {
    bad('attribute');
  }

  final List<ViSection> secs;
  try {
    secs = readViSections(bytes);
  } catch (_) {
    return c;
  }
  final ver = versionWordFromSections(secs);

  final seenHeap = <int>{};
  for (final s in secs) {
    if (!isCompressedHeapPayload(s.bytes) || !seenHeap.add(s.dataOffset)) continue;
    final inflated = inflateHeapPayload(s.bytes);
    if (inflated == null) continue;
    final split = attributeHeapBody(inflated, s.tag);
    if (split.modelBytes + split.copiedBytes != inflated.length || split.modelBugs != 0) bad('heapExact');
    final round = inflateHeapPayload(deflateHeapPayload(inflated));
    if (round == null || !_bytesEqual(round, inflated)) bad('reDeflate');
  }

  Uint8List? vctp;
  final tm80 = <int, Uint8List>{};
  for (final s in secs) {
    if (s.tag == 'VCTP') {
      vctp ??= inflateHeapPayload(s.bytes) ?? s.bytes;
    } else if (s.tag == 'TM80') {
      tm80[s.index] = inflateHeapPayload(s.bytes) ?? s.bytes;
    }
  }
  final seenDfds = <int>{};
  for (final s in secs) {
    if (s.tag != 'DFDS' || !seenDfds.add(s.dataOffset)) continue;
    final inflated = inflateHeapPayload(s.bytes);
    if (inflated == null || vctp == null || tm80.isEmpty) continue;
    final ctx = DfdsContext(vctp: vctp, tm80: tm80[s.index] ?? tm80.values.first, verGe10: (ver?.major ?? 0) >= 10);
    if (!dataSpaceFrames(inflated, ctx)) continue;
    final res = serializeHeapBody(inflated, 'DFDS', ctx);
    if (!_bytesEqual(res.bytes, inflated) || res.copiedBytes != 0) bad('dfdsExact');
  }

  final seenBlock = <int>{};
  for (final s in secs) {
    if (!seenBlock.add(s.dataOffset)) continue;
    final tag = BlockTag.of(s.tag);
    final inflated = inflateHeapPayload(s.bytes);
    if (inflated != null && !(tag?.isEnveloped ?? false)) bad('enveloped');
    if (inflated == null && tag != null && tag.isEnveloped && !_alsoPlain.contains(tag)) bad('plain');
    if (tag == null || !tag.hasWriter) continue;
    if (serializeBlockPayload(s.tag, inflated ?? s.bytes) == null) bad('roundTrip');
  }

  final seenImage = <int>{};
  for (final s in secs) {
    if ((s.tag != 'DSIM' && s.tag != 'MNGI') || !seenImage.add(s.dataOffset)) continue;
    final ViPngStream png;
    if (s.tag == 'MNGI') {
      png = decodePngStream(s.bytes);
    } else if (decodeDataSpaceImage(s.bytes) case ViDataSpacePng(png: final stream)) {
      png = stream;
    } else {
      continue;
    }
    bad('pngCrc', png.accounting().chunkCount - png.accounting().crcVerified);
    final anc = png.ancillaryRoundTrips();
    bad('ancillary', anc.count - anc.ok);
    if (png.rasterRoundTrips() == false) bad('raster');
  }

  final seenMeta = <int>{};
  for (final s in secs) {
    if ((s.tag != 'PICT' && s.tag != 'WEMF') || !seenMeta.add(s.dataOffset)) continue;
    final meta = metafileFrame(s.tag, s.bytes)!;
    if (meta.modelBytes + meta.copiedBytes != s.bytes.length) bad('metafileExact');
  }
  return c;
}

const kWriterViolations = <String, Map<String, int>>{};

const _alsoPlain = {BlockTag.tm80, BlockTag.vicd, BlockTag.dfds};

void main() {
  final all = [
    for (final f in corpusVis())
      if (!isNonRsrcFixture(f.path)) f,
  ];

  test('every VI obeys the writer laws', () async {
    final res = await corpusParallel(all, _violations);
    expect(perFileNonzero(all, res, _laws), kWriterViolations);
  });

  test('a compressed section re-emitted from re-deflated content stays valid and content-exact', () {
    var checked = 0;
    for (final f in all.take(15)) {
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      final vi = ViVi.parse(bytes);
      var changed = false;
      final segs = <ViDataSegment>[];
      for (final seg in vi.dataSegments) {
        if (seg is ViSectionData && isCompressedHeapPayload(seg.payload)) {
          final inflated = inflateHeapPayload(seg.payload);
          if (inflated != null) {
            changed = true;
            segs.add(ViSectionData(secRel: seg.secRel, payload: deflateHeapPayload(inflated)));
            continue;
          }
        }
        segs.add(seg);
      }
      if (!changed) continue;
      checked++;
      expect(viContentExact(bytes, vi.serialize()), isTrue, reason: 'identity serialize not content-exact: ${f.path}');
      final reBytes = ViVi(header: vi.header, dataSegments: segs, infoArea: vi.infoArea).serialize();
      expect(() => ViVi.parse(reBytes), returnsNormally, reason: 're-deflated container did not re-parse: ${f.path}');
      expect(viContentExact(bytes, reBytes), isTrue, reason: 're-deflated container not content-exact: ${f.path}');
    }
    expect(checked, greaterThan(0));
  });
}
