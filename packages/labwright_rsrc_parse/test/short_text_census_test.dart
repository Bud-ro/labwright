@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

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
        if (sb == 0) return;
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
