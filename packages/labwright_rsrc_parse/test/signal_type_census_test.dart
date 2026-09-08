@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

const _laws = {'oversizedTypeWord', 'depthOutOfRange', 'flagsLow2Set'};

Map<String, int> _census(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bump(String k) => c[k] = (c[k] ?? 0) + 1;
  final List<DecodedSection> decoded;
  final ViModel model;
  try {
    decoded = decodeSections(bytes).toList();
    model = buildViModelFromDecoded(decoded);
  } catch (_) {
    return c;
  }
  for (final d in decoded) {
    if (!const {'BDHb', 'BDHP', 'BDEx'}.contains(d.tag) || d.bytes.length < 6) continue;
    final body = d.bytes;
    walkHeapObjects<int>(
      body,
      onObjectOpen: (span, kind, oid, parent) => kind,
      onRecord: (span, kind) {
        if (kind != 0x17 || span.lead == kHeapRecordPrefix || span.lead == 0x14) return;
        final attr = decodeHeapAttr(body, span.offset);
        final v = attr?.value;
        if (attr?.rawTag == 0x09f && v is int && v > 0xffff) bump('oversizedTypeWord');
      },
    );
  }
  for (final diagram in model.blockDiagrams) {
    for (final wire in diagram.wires) {
      final t = wire.signalType;
      if (t == null) continue;
      if (t.depth < 1 || t.depth > 6) bump('depthOutOfRange');
      if ((t.raw & 0x3000) != 0) bump('flagsLow2Set');
    }
  }
  return c;
}

void main() {
  final all = corpusVis();

  test('wire-type word laws: u16 wide, depth 1..6, flag bits 12-13 clear', () async {
    final res = await corpusParallel(all, _census);
    expect(perFileNonzero(all, res, _laws), const <String, Map<String, int>>{});
  });
}
