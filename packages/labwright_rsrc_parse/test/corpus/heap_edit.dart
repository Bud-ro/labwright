import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _laws = {'span', 'nesting', 'boundsRecord', 'labelRecord', 'moved', 'relabelled', 'others'};

String _row(ViHeapObject o) {
  final b = o.bounds;
  return '${o.oid}:${o.kind}:${o.parentOid}:${b?.top},${b?.left},${b?.bottom},${b?.right}:${o.label}:${o.typeDescIdx}';
}

Map<String, int> _census(CorpusVi vi) {
  final c = <String, int>{};
  void bad(String k) => c[k] = (c[k] ?? 0) + 1;
  final model = vi.model;
  if (model == null || isNonRsrcFixture(vi.path)) return c;

  for (final diagram in model.diagrams) {
    final body = model.sectionOf(diagram).bytes;
    final view = ByteData.sublistView(body);
    for (final object in diagram.objects) {
      if (object.offset >= object.end || object.end > body.length) bad('span');
      final parent = diagram.parentOf(object);
      if (parent != null && (object.offset < parent.offset || object.end > parent.end)) bad('nesting');
      if (object.boundsOffset case final at?) {
        final b = object.bounds!;
        if (view.getInt16(at) != b.top ||
            view.getInt16(at + 2) != b.left ||
            view.getInt16(at + 4) != b.bottom ||
            view.getInt16(at + 6) != b.right) {
          bad('boundsRecord');
        }
      }
      if (object.labelOffset case final at?) {
        final record = c4FrameAt(body, at, diagram.sectionTag);
        final matches = record != null && record.byteLength == object.labelLength && record.text == object.label;
        if (!matches) bad('labelRecord');
      }
    }
  }

  final edited = buildViModelFromDecoded(vi.decoded!, file: vi.bytes);
  final diagram = edited.primaryBlockDiagram;
  if (diagram == null) return c;
  final before = [for (final o in diagram.objects) _row(o)];
  final movable = diagram.objects.where((o) => o.boundsOffset != null).firstOrNull;
  final labelled = diagram.objects.where((o) => o.labelOffset != null).firstOrNull;
  if (movable == null && labelled == null) return c;
  if (movable != null) edited.moveObject(diagram, movable, dx: 3, dy: 5);
  if (labelled != null) edited.setLabel(diagram, labelled, '${labelled.label}+');
  final after = buildViModel(
    edited.serialize(),
  ).blockDiagrams.where((d) => d.sectionIndex == diagram.sectionIndex).first;
  if (after.objects.length != before.length) {
    bad('others');
    return c;
  }
  for (var i = 0; i < before.length; i++) {
    final object = diagram.objects[i];
    final expected = _row(object);
    final key = identical(object, movable)
        ? 'moved'
        : identical(object, labelled)
        ? 'relabelled'
        : 'others';
    if (_row(after.objects[i]) != expected || (key != 'others' && expected == before[i])) bad(key);
  }
  return c;
}

const heapEditLaw = CorpusLaw('heap_edit', _census);

void heapEditTests() {
  test('object spans nest and name their records; a move and a relabel survive a round trip alone', () async {
    expect(await heapEditLaw.nonzero(_laws), isEmpty);
  });
}
