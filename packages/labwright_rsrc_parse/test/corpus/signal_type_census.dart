import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _laws = {'oversizedTypeWord', 'depthOutOfRange', 'flagsLow2Set'};

Map<String, int> _census(CorpusVi vi) {
  final c = <String, int>{};
  void bump(String k) => c[k] = (c[k] ?? 0) + 1;
  final decoded = vi.decoded;
  final model = vi.model;
  if (decoded == null || model == null) return c;
  for (final d in decoded) {
    if (!const {'BDHb', 'BDHP', 'BDEx'}.contains(d.tag) || d.bytes.length < 6) continue;
    final body = d.bytes;
    walkHeapObjects<int>(
      body,
      onObjectOpen: (offset, kind, oid, parent) => kind,
      onRecord: (offset, length, lead, kind) {
        if (kind != 0x17 || lead == kHeapRecordPrefix || lead == 0x14) return;
        final attr = decodeHeapAttr(body, offset);
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

void signalTypeCensusTests() {
  final all = corpusVis.files;

  test('wire-type word laws: u16 wide, depth 1..6, flag bits 12-13 clear', () async {
    final res = await corpusVis.map(_census);
    // TODO: two editor VIs carry a wire-type depth outside 1..6.
    expect(perFileNonzero(all, res, _laws), const <String, Map<String, int>>{
      'vi-corpus/sources/LabVIEW-DCAF__calcs/src/editor node/Main Editor UI.vi': {'depthOutOfRange': 1},
      'vi-corpus/sources/LabVIEW-DCAF__calcs/src/editor node/Node Change Event.vi': {'depthOutOfRange': 1},
    });
  });
}
