import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _laws = {'undecoded', 'tableDiffers', 'recordDiffers'};

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<String, int> _census(CorpusVi vi) {
  final c = <String, int>{};
  void bump(String k) => c[k] = (c[k] ?? 0) + 1;
  void visit(List<HeapNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case HeapObjectNode(:final children) || HeapGroupNode(:final children):
          visit(children);
        case HeapRecordNode(:final bytes):
          final table = wireTableOfRecord(bytes);
          if (table == null) continue;
          bump('tables');
          if (!_same(encodeWireTableRecord(table), bytes)) bump('recordDiffers');
          final decoded = decodeWireTable(table);
          if (decoded == null) {
            bump('undecoded');
          } else if (!_same(decoded.encode(), table)) {
            bump('tableDiffers');
          }
      }
    }
  }

  for (final section in vi.decoded ?? const <DecodedSection>[]) {
    if (section.tag != 'BDHb' && section.tag != 'FPHb' || section.bytes.length < 4) continue;
    visit(parseHeapTree(section.bytes));
  }
  return c;
}

const wireTableLaw = CorpusLaw('wire_table', _census);

void wireTableTests() {
  test('every wire table decodes and re-encodes byte for byte, in the record it came in', () async {
    // TODO: a signal with no endpoints carries four bytes past its n − 1 lengths.
    expect(await wireTableLaw.nonzero(_laws), const <String, Map<String, int>>{
      'vi-corpus/sources/rcpacini__LabVIEW-VI-Snippet/Examples/Snippets/broken_wires_only.png': {'undecoded': 2},
    });
  });
}
