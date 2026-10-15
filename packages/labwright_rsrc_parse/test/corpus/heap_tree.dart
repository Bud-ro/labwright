import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _laws = {'differs'};

int _unclosed(List<HeapNode> nodes) {
  var n = 0;
  for (final node in nodes) {
    switch (node) {
      case HeapObjectNode(:final closed, :final children):
        n += (closed ? 0 : 1) + _unclosed(children);
      case HeapGroupNode(:final closeLead, :final children):
        n += (closeLead == null ? 1 : 0) + _unclosed(children);
      case HeapRecordNode():
        break;
    }
  }
  return n;
}

Map<String, int> _census(CorpusVi vi) {
  final c = <String, int>{};
  void bump(String k, [int by = 1]) => c[k] = (c[k] ?? 0) + by;
  for (final section in vi.decoded ?? const <DecodedSection>[]) {
    if (section.tag != 'BDHb' && section.tag != 'FPHb' || section.bytes.length < 4) continue;
    final tree = parseHeapTree(section.bytes);
    final again = encodeHeapTree(tree);
    var same = again.length == section.bytes.length;
    for (var i = 0; same && i < again.length; i++) {
      same = again[i] == section.bytes[i];
    }
    bump(same ? 'same' : 'differs');
    bump('unclosed', _unclosed(tree));
  }
  return c;
}

const heapTreeLaw = CorpusLaw('heap_tree', _census);

void heapTreeTests() {
  test('every heap re-encodes from its record tree byte for byte, every scope closed', () async {
    expect(await heapTreeLaw.nonzero(_laws), isEmpty);
  });
}
