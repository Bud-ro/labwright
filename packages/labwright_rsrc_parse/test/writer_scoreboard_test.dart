@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

const _fullTags = [
  'icl8', 'icl4', 'ICON', 'NUID', 'SUID', 'BNID', 'vers', 'STRG', 'HIST', //
  'MUID', 'BDSE', 'FPSE', 'BDEx', 'FPEx', 'IPSR', 'PICC', 'CPMp', 'GCPR', //
  'RTSG', 'SCSR', 'BDPW', 'DLDR', 'CNST', 'LPIN', 'VPDP', 'TITL', 'OBSG', 'CCSG', //
  'COUT', 'CPD2', 'PRT ', 'FPTD', 'HLPT', 'HLPP', 'FTAB', 'BKMK', 'TRec', //
  'CCST', 'CPST', 'CPSP', 'BDTS',
];

const _partialTags = ['VITS', 'DTHP', 'CONP', 'CPC2', 'LVSR', 'LIbd', 'LIvi', 'LIfp', 'LIds', 'TM80'];

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

(Map<String, int>, List<String>) _writer(Uint8List bytes, String path) {
  final c = <String, int>{};
  final diags = <String>[];
  final base = path.split('/').last;
  void n(String k, [int by = 1]) => c[k] = (c[k] ?? 0) + by;
  void bad(String key, String msg) {
    n('bad:$key');
    if (diags.length < 8) diags.add('$key• $base: $msg');
  }

  try {
    final a = attributeVi(bytes);
    n('files');
    if (a.byteExact) n('byteExact');
    if (a.modelBytes + a.copiedBytes == a.fileLength) {
      n('lawOk');
    } else {
      bad('law', 'model ${a.modelBytes} + copied ${a.copiedBytes} != len ${a.fileLength}');
    }
    n('fileBytes', a.fileLength);
    n('model', a.modelBytes);
    n('copied', a.copiedBytes);
    n('cat.header', a.headerBytes);
    n('cat.infoStruct', a.infoStructBytes);
    n('cat.secPrefix', a.sectionPrefixBytes);
    n('cat.typedPayload', a.typedPayloadBytes);
    n('cat.alignPad', a.alignPadBytes);
    n('cat.infoRaw', a.infoRawBytes);
    n('cat.gap', a.gapBytes);
    n('cat.compressed', a.compressedPayloadBytes);
    n('cat.untyped', a.untypedPayloadBytes);
    if (a.contentModelBytes + a.contentCopiedBytes == a.contentTotalBytes) {
      n('contentLawOk');
    } else {
      bad(
        'claw',
        'contentModel ${a.contentModelBytes} + copied ${a.contentCopiedBytes} != total ${a.contentTotalBytes}',
      );
    }
    n('inflatedContent', a.inflatedContentBytes);
    n('contentModel', a.contentModelBytes);
    n('contentCopied', a.contentCopiedBytes);
    n('contentTotal', a.contentTotalBytes);
    n('heap.model', a.heapModelBytes);
    n('heap.copied', a.heapCopiedBytes);
    n('heapModelBugs', a.heapModelBugs);
    n('image.compressed', a.imageCompressedBytes);
    n('image.inflated', a.imageInflatedBytes);
    n('image.inflatedModel', a.imageInflatedModelBytes);
    n('image.inflatedCopied', a.imageInflatedCopiedBytes);
  } catch (_) {}

  try {
    final seen = <int>{};
    for (final s in readViSections(bytes)) {
      if (!isCompressedHeapPayload(s.bytes) || !seen.add(s.dataOffset)) continue;
      n('compSec');
      final inflated = inflateHeapPayload(s.bytes);
      if (inflated == null) {
        n('inflateFail');
        continue;
      }
      final split = attributeHeapBody(inflated, s.tag);
      if (split.modelBytes + split.copiedBytes == inflated.length && split.modelBugs == 0) {
        n('heapByteExact');
      } else {
        bad('heap', 'heap re-emission not byte-exact for ${s.tag}');
      }
      final round = inflateHeapPayload(deflateHeapPayload(inflated));
      if (round != null && _bytesEqual(round, inflated)) {
        n('reDeflateOk');
      } else {
        bad('rd', 're-deflate did not preserve ${s.tag} content');
      }
    }
  } catch (_) {}

  try {
    final secs = readViSections(bytes);
    Uint8List? vctp;
    final tm80 = <int, Uint8List>{};
    for (final s in secs) {
      if (s.tag == 'VCTP') {
        vctp ??= inflateHeapPayload(s.bytes) ?? s.bytes;
      } else if (s.tag == 'TM80') {
        tm80[s.index] = inflateHeapPayload(s.bytes) ?? s.bytes;
      }
    }
    final verGe10 = (versionWordFromSections(secs)?.major ?? 0) >= 10;
    final seen = <int>{};
    for (final s in secs) {
      if (s.tag != 'DFDS' || !seen.add(s.dataOffset)) continue;
      final inflated = inflateHeapPayload(s.bytes);
      if (inflated == null || vctp == null || tm80.isEmpty) continue;
      n('dfds.inst');
      n('dfds.bytes', inflated.length);
      final ctx = DfdsContext(vctp: vctp, tm80: tm80[s.index] ?? tm80.values.first, verGe10: verGe10);
      if (dataSpaceFrames(inflated, ctx)) {
        n('dfds.frames');
        n('dfds.framedBytes', inflated.length);
        final res = serializeHeapBody(inflated, 'DFDS', ctx);
        if (_bytesEqual(res.bytes, inflated) && res.copiedBytes == 0) {
          n('dfds.exact');
        } else {
          bad('dfds', 'DFDS framed walk did not re-emit byte-exact');
        }
      }
    }
  } catch (_) {}

  try {
    final secs = readViSections(bytes);
    final ver = versionWordFromSections(secs);
    final seen = <int>{};
    for (final s in secs) {
      if (!hasBlockWriter(s.tag) || !seen.add(s.dataOffset)) continue;
      n('${s.tag}.inst');
      n('${s.tag}.bytes', s.bytes.length);
      if (serializeBlockPayload(s.tag, s.bytes, version: ver) != null) {
        n('${s.tag}.exact');
      } else if (_fullTags.contains(s.tag)) {
        bad('rt', '${s.tag}#${s.index} ${s.bytes.length}B did not round-trip');
      }
    }
  } catch (_) {}

  try {
    final seen = <int>{};
    for (final s in readViSections(bytes)) {
      if ((s.tag != 'DSIM' && s.tag != 'MNGI') || !seen.add(s.dataOffset)) continue;
      n('${s.tag}.inst');
      final img = decodeImageBlock(s.tag, s.bytes);
      if (img == null) continue;
      if (_bytesEqual(img.bytes, s.bytes)) {
        n('${s.tag}.exact');
      } else {
        bad('img', '${s.tag}#${s.index} did not re-emit byte-exact');
      }
      n('${s.tag}.model', img.modelBytes);
      n('${s.tag}.copied', img.copiedBytes);
      n('img.chunks', img.pngChunks);
      n('img.crcVerified', img.crcVerified);
      final anc = imageAncillaryRoundTrips(s.tag, s.bytes);
      n('img.ancillary', anc.count);
      n('img.ancillaryRoundTrip', anc.ok);
      if (anc.ok != anc.count) {
        bad('anc', '${s.tag}#${s.index} an ancillary stream did not round-trip through standard zlib');
      }
      final rt = imageRasterRoundTrips(s.tag, s.bytes);
      if (rt == null) continue;
      n('${s.tag}.png');
      n('img.pngRaster');
      if (rt) {
        n('img.rasterRoundTrip');
      } else {
        bad('raster', '${s.tag}#${s.index} raster did not round-trip through standard zlib');
      }
    }
  } catch (_) {}

  try {
    final seen = <int>{};
    for (final s in readViSections(bytes)) {
      if ((s.tag != 'PICT' && s.tag != 'WEMF') || !seen.add(s.dataOffset)) continue;
      n('${s.tag}.inst');
      final meta = frameMetafile(s.tag, s.bytes);
      if (meta == null) continue;
      if (_bytesEqual(meta.bytes, s.bytes) && meta.modelBytes + meta.copiedBytes == s.bytes.length) {
        n('${s.tag}.exact');
      } else {
        bad('meta', '${s.tag}#${s.index} did not re-emit byte-exact');
      }
      n('${s.tag}.model', meta.modelBytes);
      n('${s.tag}.copied', meta.copiedBytes);
      n('${s.tag}.elements', meta.elementCount);
    }
  } catch (_) {}

  return (c, diags);
}

void main() {
  final all = [
    for (final f in corpusVis())
      if (!isNonRsrcFixture(f.path)) f,
  ];

  late final Map<String, int> C;
  late final List<String> diags;
  setUpAll(() async {
    final res = await corpusParallel(all, _writer);
    C = {};
    diags = [];
    for (final (counts, d) in res) {
      counts.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
      diags.addAll(d);
    }
  });

  int cnt(String k) => C[k] ?? 0;
  List<String> D(String key) => diags.where((d) => d.startsWith('$key•')).take(8).toList();

  test('LAW: modelBytes + copiedBytes == fileLength for every VI', () {
    expect(cnt('lawOk'), cnt('files'), reason: 'byte attribution did not tile the file: ${D('law')}');
    expect(cnt('model') + cnt('copied'), cnt('fileBytes'), reason: 'aggregate model+copied != total file bytes');
  });

  test('LAW: the writer re-serializes every VI byte-exactly (== parseable)', () {
    expect(cnt('byteExact'), all.length, reason: 'writer not byte-exact for ${all.length - cnt('byteExact')} file(s)');
    expect(cnt('files'), all.length, reason: 'attributeVi did not cover every parseable VI');
  });

  test('LAW: contentModelBytes + contentCopiedBytes == contentTotalBytes for every VI', () {
    expect(cnt('contentLawOk'), cnt('files'), reason: 'content attribution did not tile: ${D('claw')}');
    expect(cnt('contentModel') + cnt('contentCopied'), cnt('contentTotal'), reason: 'aggregate content split != total');
  });

  test('LAW: every compressed section re-emits byte-exact from the heap model', () {
    final inflatable = cnt('compSec') - cnt('inflateFail');
    expect(
      cnt('heapByteExact'),
      inflatable,
      reason: 'heap writer not byte-exact for ${inflatable - cnt('heapByteExact')}: ${D('heap')}',
    );
    expect(cnt('compSec'), greaterThan(0), reason: 'no compressed heap sections found — census stale?');
  });

  test('LAW: the heap model has zero reconstruction bugs', () {
    expect(cnt('heapModelBugs'), 0, reason: '${cnt('heapModelBugs')} heap record(s) failed to reconstruct losslessly');
  });

  test('PROOF: re-deflating each compressed section preserves its content (compatible zlib)', () {
    final inflatable = cnt('compSec') - cnt('inflateFail');
    expect(
      cnt('reDeflateOk'),
      inflatable,
      reason: 're-deflate lost content for ${inflatable - cnt('reDeflateOk')}: ${D('rd')}',
    );
  });

  test('LAW: every DFDS that frames re-emits byte-exact from the flattened-value walk', () {
    expect(cnt('dfds.exact'), cnt('dfds.frames'), reason: 'DFDS framed walk not byte-exact: ${D('dfds')}');
    expect(cnt('dfds.frames'), greaterThan(0), reason: 'no DFDS framed — flattened-value walk broken?');
    expect(cnt('dfds.frames'), lessThanOrEqualTo(cnt('dfds.inst')), reason: 'framed more DFDS than exist');
  });

  test('WIRING: a compressed section re-emitted from re-deflated content stays valid and content-exact', () {
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
    expect(checked, greaterThan(0), reason: 'no sampled VI had an inflatable compressed section');
  });

  for (final tag in _fullTags) {
    test('ROUND-TRIP: every $tag payload re-serializes byte-exact from its model', () {
      expect(
        cnt('$tag.exact'),
        cnt('$tag.inst'),
        reason: '$tag not byte-exact for ${cnt('$tag.inst') - cnt('$tag.exact')} instance(s): ${D('rt')}',
      );
      expect(cnt('$tag.inst'), greaterThan(0), reason: 'no $tag instances found — census stale?');
    });
  }

  for (final tag in _partialTags) {
    test('ROUND-TRIP: $tag re-serializes its modelable form (subset, exact count pinned)', () {
      expect(cnt('$tag.exact'), greaterThan(0), reason: 'no $tag instance re-serialized — writer broken?');
      expect(
        cnt('$tag.exact'),
        lessThanOrEqualTo(cnt('$tag.inst')),
        reason: '$tag re-serialized more instances than exist',
      );
    });
  }

  for (final tag in const ['DSIM', 'MNGI']) {
    test('IMAGE: every framed $tag re-emits byte-exact (framed subset, counts pinned)', () {
      expect(cnt('$tag.exact'), greaterThan(0), reason: 'no $tag framed — image writer broken?');
      expect(cnt('$tag.exact'), lessThanOrEqualTo(cnt('$tag.inst')), reason: '$tag framed more than exist');
      expect(D('img'), isEmpty, reason: 'a framed $tag did not re-emit byte-exact: ${D('img')}');
    });
  }

  for (final tag in const ['PICT', 'WEMF']) {
    test('METAFILE: every $tag block frames and re-emits byte-exact (N/N, counts pinned)', () {
      expect(cnt('$tag.exact'), cnt('$tag.inst'), reason: 'a $tag did not frame byte-exact: ${D('meta')}');
      expect(cnt('$tag.inst'), greaterThan(0), reason: 'no $tag instances found — census stale?');
    });
  }

  test('IMAGE: every framed PNG chunk CRC-32 verifies', () {
    expect(cnt('img.crcVerified'), cnt('img.chunks'), reason: 'a framed PNG chunk failed CRC-32 verification');
    expect(cnt('img.chunks'), greaterThan(0), reason: 'no PNG chunks framed — census stale?');
  });

  test('IMAGE: every PNG-bearing image raster round-trips through standard zlib (compatible zlib)', () {
    expect(
      cnt('img.rasterRoundTrip'),
      cnt('img.pngRaster'),
      reason: 'raster did not round-trip for ${cnt('img.pngRaster') - cnt('img.rasterRoundTrip')}: ${D('raster')}',
    );
    expect(cnt('img.pngRaster'), greaterThan(0), reason: 'no PNG rasters inflated — census stale?');
  });

  test('PROOF: every PNG ancillary stream (iCCP/zTXt/iTXt) round-trips through standard zlib', () {
    expect(
      cnt('img.ancillaryRoundTrip'),
      cnt('img.ancillary'),
      reason:
          'an ancillary stream lost content for ${cnt('img.ancillary') - cnt('img.ancillaryRoundTrip')}: ${D('anc')}',
    );
    expect(cnt('img.ancillary'), greaterThan(0), reason: 'no ancillary streams inflated — census stale?');
  });

  test('LAW: contentModel counts the inflated raster in place of the compressed IDAT', () {
    expect(cnt('image.inflatedCopied'), 0, reason: 'a PNG raster was counted copied at the content level');
    expect(
      cnt('image.inflated'),
      cnt('image.inflatedModel'),
      reason: 'inflated raster not fully modeled at the content level',
    );
    expect(cnt('image.compressed'), greaterThan(0), reason: 'no compressed IDAT swapped for a raster — census stale?');
    expect(
      cnt('image.inflated'),
      greaterThan(cnt('image.compressed')),
      reason: 'inflated raster mass should exceed the compressed IDAT it replaces',
    );
  });

  test('writer scoreboard measurements match the committed snapshot exactly', () {
    expectCorpusSnapshot('writer', {
      for (final e in C.entries)
        if (!e.key.startsWith('bad:')) e.key: e.value,
    });
  });
}
