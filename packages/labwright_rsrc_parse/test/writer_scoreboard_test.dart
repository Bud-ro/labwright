@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

/// Writer-layer corpus laws + scoreboard, for the byte-exact `.vi` writer.
///
/// Two things per VI, run once in a worker isolate ([corpusParallel]):
///   1. **Scoreboard attribution** ([attributeVi]) — partitions every byte into
///      model vs copied. Asserted as LAWS: `modelBytes + copiedBytes ==
///      fileLength` for every file, and `byteExact == parseable` (the writer
///      re-emits every `.vi` exactly). The aggregate byte totals per category
///      are MEASUREMENTS, pinned in `corpus/snapshot.json` (`writer` section).
///   2. **Per-block round-trip** — for every block type with a byte-exact writer
///      ([hasBlockWriter]), every corpus instance must re-serialize identically
///      ([serializeBlockPayload] non-null). Asserted N/N per tag; the instance
///      counts are MEASUREMENTS in the snapshot.

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
