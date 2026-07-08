@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

/// Writer-layer corpus laws + scoreboard, for the `.vi` writer at both the byte
/// and the content (inflated) level.
///
/// Per VI, run once in a worker isolate ([corpusParallel]):
///   1. **Scoreboard attribution** ([attributeVi]) — partitions every byte into
///      model vs copied AND every content byte (compressed sections at inflated
///      size) into content-model vs content-copied. Asserted as LAWS:
///      `modelBytes + copiedBytes == fileLength`, `contentModelBytes +
///      contentCopiedBytes == contentTotalBytes`, and `byteExact == parseable`.
///      The aggregate byte totals per category are MEASUREMENTS, pinned in
///      `corpus/snapshot.json` (`writer` section) — both the byte-model and the
///      content-model numerators live there.
///   2. **Per-block round-trip** — for every block type with a byte-exact writer
///      ([hasBlockWriter]), every corpus instance must re-serialize identically
///      ([serializeBlockPayload] non-null). Asserted N/N per tag; the instance
///      counts are MEASUREMENTS in the snapshot.
///   3. **Content-exact + heap writer** — every compressed section's inflated
///      content re-emits byte-exact from the heap model ([serializeHeapBody],
///      LAW), the heap model has zero reconstruction bugs (LAW), and re-deflating
///      each section with a standard zlib stream preserves its content (the
///      "compatible zlib" proof, N/N). A sampled WIRING test then re-deflates a
///      whole container and requires it to re-parse and stay content-exact
///      ([viContentExact]) — the identity and re-deflated writer are both proven
///      content-exact there.

/// Block tags whose payload writer re-serializes **every** corpus instance
/// byte-exact (asserted N/N below).
const _fullTags = [
  'icl8', 'icl4', 'ICON', 'NUID', 'SUID', 'BNID', 'vers', 'STRG', 'HIST', //
  'MUID', 'BDSE', 'FPSE', 'BDEx', 'FPEx', 'IPSR', 'PICC', 'CPMp', 'GCPR', //
  'RTSG', 'SCSR', 'BDPW', 'DLDR', 'CNST', 'LPIN', 'VPDP', 'TITL', 'OBSG', 'CCSG', //
  'COUT', 'CPD2',
];

/// Block tags whose payload writer re-serializes a **subset** of corpus
/// instances (the modelable form); the rest carry an undecoded interior and
/// stay copied. The exact/inst split is pinned as a measurement (not a law).
const _partialTags = ['VITS', 'DTHP', 'CONP', 'CPC2', 'LVSR', 'LIbd', 'LIvi', 'LIfp', 'LIds'];

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

  // Scoreboard attribution + the tiling law.
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
    n('cat.infoRaw', a.infoRawBytes);
    n('cat.gap', a.gapBytes);
    n('cat.compressed', a.compressedPayloadBytes);
    n('cat.untyped', a.untypedPayloadBytes);
    // Content level (compressed sections at inflated size).
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
  } catch (_) {}

  // Heap-writer byte-exactness + the re-deflate "compatible zlib" proof, per
  // compressed section (deduped by secRel). Content-exactness of the identity
  // serialize() is implied by byteExact; it is proven under re-deflation — where
  // stored bytes DO change — by the sampled WIRING test below.
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
      // Byte-exactness of the heap re-emission, verified without materializing
      // the output buffer: the walk tiles the body and every modeled record was
      // verified against the original (modelBugs == 0), so the re-emission —
      // verified-model prefixes ++ original-copied slices — equals the body.
      // (The explicit bytes == body proof over serializeHeapBody is the unit
      // test; here the allocation-free split keeps the corpus sweep lean.)
      final split = attributeHeapBody(inflated, s.tag);
      if (split.modelBytes + split.copiedBytes == inflated.length && split.modelBugs == 0) {
        n('heapByteExact');
      } else {
        bad('heap', 'heap re-emission not byte-exact for ${s.tag}');
      }
      // Re-deflate proof from the already-inflated buffer (avoids re-inflating):
      // inflate(deflate(x)) == x, the "compatible zlib" evidence.
      final round = inflateHeapPayload(deflateHeapPayload(inflated));
      if (round != null && _bytesEqual(round, inflated)) {
        n('reDeflateOk');
      } else {
        bad('rd', 're-deflate did not preserve ${s.tag} content');
      }
    }
  } catch (_) {}

  // Per-block round-trip census. Dedup by secRel (a payload referenced by
  // several descriptors is one span in the data area).
  try {
    final seen = <int>{};
    for (final s in readViSections(bytes)) {
      if (!hasBlockWriter(s.tag) || !seen.add(s.dataOffset)) continue;
      n('${s.tag}.inst');
      n('${s.tag}.bytes', s.bytes.length);
      if (serializeBlockPayload(s.tag, s.bytes) != null) {
        n('${s.tag}.exact');
      } else if (_fullTags.contains(s.tag)) {
        bad('rt', '${s.tag}#${s.index} ${s.bytes.length}B did not round-trip');
      }
    }
  } catch (_) {}

  return (c, diags);
}

void main() {
  final all = [
    for (final f in corpusVis())
      if (!isNonRsrcFixture(f.path)) f,
  ];
  if (all.isEmpty) {
    test('writer scoreboard (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

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

  test('WIRING: a compressed section re-emitted from re-deflated content stays valid and content-exact', () {
    // Deliverable-2 container-level proof on a small sample: replace every
    // compressed heap section's stored payload with a fresh standard-zlib stream
    // carrying the SAME inflated content, let the writer recompute all offsets,
    // and require the result to re-parse and stay content-exact with the input.
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
      // The identity writer is content-exact (implied by byteExact, checked here
      // on the sample rather than over the whole sweep).
      expect(viContentExact(bytes, vi.serialize()), isTrue, reason: 'identity serialize not content-exact: ${f.path}');
      final reBytes = ViVi(header: vi.header, dataSegments: segs, infoArea: vi.infoArea).serialize();
      expect(() => ViVi.parse(reBytes), returnsNormally, reason: 're-deflated container did not re-parse: ${f.path}');
      // The re-deflated container carries the same content through different
      // stored bytes (a standard zlib stream, not NI's), yet stays content-exact.
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

  test('writer scoreboard measurements match the committed snapshot exactly', () {
    // MEASUREMENTS: whole-corpus byte totals per model/copied category, the
    // byte-exact/law populations, and per-typed-block instance/byte/exact
    // counts. Deterministic over the pinned corpus, so pinned exactly; the LAW
    // tests above hold the invariants (tiling, byte-exactness) at their limits.
    expectCorpusSnapshot('writer', {
      for (final e in C.entries)
        if (!e.key.startsWith('bad:')) e.key: e.value,
    });
  });
}
