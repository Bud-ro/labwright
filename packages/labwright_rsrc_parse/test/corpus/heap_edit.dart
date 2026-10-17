import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _laws = {'span', 'nesting', 'boundsRecord', 'labelRecord', 'moved', 'relabelled', 'cloned', 'others', 'undone'};

String _row(BdObject o) {
  final b = o.bounds;
  return '${o.oid}:${o.kind}:${o.parentOid}:${b?.top},${b?.left},${b?.bottom},${b?.right}:${o.label}:${o.typeDescIdx}';
}

Map<String, int> _census(CorpusVi vi) {
  final c = <String, int>{};
  void bad(String k) => c[k] = (c[k] ?? 0) + 1;
  final model = vi.model;
  if (model == null || isNonRsrcFixture(vi.path)) return c;

  for (final diagram in <HeapObjectTree>[...model.blockDiagrams, ...model.frontPanels]) {
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
        final record = c4FrameAt(body, at, model.sectionOf(diagram).tag);
        final matches = record != null && record.byteLength == object.labelLength && record.text == object.label;
        if (!matches) bad('labelRecord');
      }
    }
  }

  final edited = buildViModelFromDecoded(vi.decoded!, file: vi.bytes);
  final primary = edited.primaryBlockDiagram;
  if (primary == null) return c;
  var diagram = primary;
  final before = [for (final o in diagram.objects) _row(o)];
  final movable = diagram.objects.where((o) => o.boundsOffset != null).firstOrNull;
  final labelled = diagram.objects.where((o) => o.labelOffset != null).firstOrNull;
  final leaf = diagram.objects.where((o) => o.boundsOffset != null && diagram.childrenOf(o).isEmpty).firstOrNull;
  if (movable == null && labelled == null && leaf == null) return c;
  if (movable != null) edited.moveObject(diagram, movable, dx: 3, dy: 5);
  if (labelled != null) edited.setLabel(diagram, labelled, '${labelled.label}+');
  final expected = [for (final o in diagram.objects) _row(o)];
  var cloneIndex = -1;
  if (leaf != null && edited.section(BlockTag.muid.tag) != null) {
    final uid = ViMaxUid(edited.section(BlockTag.muid.tag)!.bytes).maxUid;
    final (heap: rebuilt, :clone) = edited.cloneObject(diagram, leaf);
    cloneIndex = leaf.index + 1;
    diagram = rebuilt;
    final original = _row(leaf);
    if (clone.oid != uid + 1 || _row(clone).replaceFirst('${clone.oid}:', '${leaf.oid}:') != original) bad('cloned');
    expected.insert(cloneIndex, _row(clone));
  }
  final after = buildViModel(
    edited.serialize(),
  ).blockDiagrams.where((d) => d.sectionIndex == diagram.sectionIndex).first;
  if (after.objects.length != expected.length) {
    bad('others');
  } else {
    for (var i = 0; i < expected.length; i++) {
      final j = cloneIndex >= 0 && i > cloneIndex ? i - 1 : i;
      final key = i == cloneIndex
          ? 'cloned'
          : identical(diagram.objects[i], movable) ||
                j < before.length && movable != null && diagram.objects[i].oid == movable.oid
          ? 'moved'
          : labelled != null && diagram.objects[i].oid == labelled.oid
          ? 'relabelled'
          : 'others';
      if (_row(after.objects[i]) != expected[i]) bad(key);
      if (key == 'moved' && expected[i] == before[j]) bad('moved');
      if (key == 'relabelled' && expected[i] == before[j]) bad('relabelled');
    }
  }
  while (edited.undo()) {}
  if (!_same(edited.serialize(), vi.bytes)) bad('undone');
  return c;
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const heapEditLaw = CorpusLaw('heap_edit', _census);

void heapEditTests() {
  test(
    'object spans nest and name their records; a move, a relabel and a clone survive a round trip alone, and undo restores the file',
    () async {
      expect(await heapEditLaw.nonzero(_laws), isEmpty);
    },
  );
}
