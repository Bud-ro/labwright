@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

/// Corpus census for the scalar-width short-caption decode (raw tag `0x022`,
/// [HeapAttribute.shortText]) — the numbers the [buildDiagram] caption comment
/// cites, recomputed from scratch and asserted exactly against the `short_text`
/// snapshot section.
///
/// Every scalar-width `0x022` record (`u8`/`u16`/`u24`/`u32`) across every heap
/// section is bucketed exactly once:
///  * `zero` — value 0 (an empty caption).
///  * `captured` — every stored byte a printable ASCII glyph AND the decoded
///    text fills the whole stored width (a genuine N-char caption uses the
///    N-byte width). These become object labels; split by width `capW1..capW4`
///    and by carrier class (`capOn0a` = the label class, the dominant scope).
///  * `widthInconsistent` — all-printable low bytes but a null leading byte, so
///    the string is shorter than the width: a number, left numeric.
///  * `nonPrintableHighBit` / `nonPrintableLowCtrl` — a byte outside
///    `0x20..0x7e` (high-bit Latin-1, or a control code): left numeric.
const _heapTags = {'BDHb', 'BDHP', 'BDEx', 'FPHb', 'FPHP', 'FPEx'};

int _scalarBytes(HeapAttrWidth w) => switch (w) {
  HeapAttrWidth.u8 => 1,
  HeapAttrWidth.u16 => 2,
  HeapAttrWidth.u24 => 3,
  HeapAttrWidth.rgb => 4,
  _ => 0,
};

Map<String, int> _census(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final List<DecodedSection> secs;
  try {
    secs = decodeSections(bytes).toList();
  } catch (_) {
    return c;
  }
  for (final s in secs) {
    if (!_heapTags.contains(s.tag) || s.bytes.length < 6) continue;
    final body = s.bytes;
    walkHeapObjects<int>(
      body,
      onObjectOpen: (span, kind, oid, parent) => kind,
      onRecord: (span, kind) {
        final off = span.offset;
        if (span.lead == kHeapRecordPrefix || span.lead == 0x14) return;
        if (off + 1 >= body.length || body[off + 1] != 0x22) return;
        final attr = decodeHeapAttr(body, off);
        if (attr == null || attr.rawTag != 0x022) return;
        final sb = _scalarBytes(attr.width);
        if (sb == 0) return; // flag / length-prefixed widths carry no scalar text
        bump('total');
        final v = attr.asInt ?? -1;
        if (v == 0) {
          bump('zero');
          return;
        }
        final txt = attr.asciiText;
        if (txt == null) {
          var highBit = false;
          for (var x = v; x > 0; x >>= 8) {
            if ((x & 0xff) >= 0x80) highBit = true;
          }
          bump(highBit ? 'nonPrintableHighBit' : 'nonPrintableLowCtrl');
          return;
        }
        if (txt.length != sb) {
          bump('widthInconsistent');
          return;
        }
        bump('captured');
        bump('capW$sb');
        bump(kind == 0x0a ? 'capOn0a' : 'capOnOther');
      },
    );
  }
  return c;
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('short-text census (skipped: corpus not fetched)', () {
      markTestSkipped('corpus not fetched');
    }, skip: true);
    return;
  }

  late final Map<String, int> C;
  setUpAll(() async {
    final res = await corpusParallel(all, _census);
    C = {};
    for (final m in res) {
      m.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
    }
  });

  test('short-text buckets partition every scalar-width record', () {
    final sum =
        (C['zero'] ?? 0) +
        (C['captured'] ?? 0) +
        (C['widthInconsistent'] ?? 0) +
        (C['nonPrintableHighBit'] ?? 0) +
        (C['nonPrintableLowCtrl'] ?? 0);
    expect(sum, C['total'], reason: 'each record lands in exactly one bucket');
    expect((C['capW1'] ?? 0) + (C['capW2'] ?? 0) + (C['capW3'] ?? 0) + (C['capW4'] ?? 0), C['captured']);
    expect((C['capOn0a'] ?? 0) + (C['capOnOther'] ?? 0), C['captured']);
  });

  test('short-text census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('short_text', C);
  });
}
