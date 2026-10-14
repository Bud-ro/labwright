import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _laws = {'untouched', 'uid', 'rewritten', 'count', 'tag', 'envelope', 'payload', 'grown', 'aligned'};

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<String, int> _census(CorpusVi vi) {
  final c = <String, int>{};
  void bad(String k) => c[k] = (c[k] ?? 0) + 1;
  if (vi.model == null || isNonRsrcFixture(vi.path)) return c;
  if (!_same(vi.model!.serialize(), vi.bytes)) bad('untouched');

  final model = ViModel(
    version: null,
    title: null,
    components: const [],
    sections: [
      for (final section in vi.decoded!)
        ViSectionBuffer(
          section.tag,
          section.index,
          section.bytes,
          compressed: section.wasCompressed,
          secRel: section.section.dataOffset,
        ),
    ],
    file: ViVi.parse(vi.bytes),
  );
  if (model.section(BlockTag.muid.tag) case final muid?) {
    final before = ViMaxUid(muid.bytes).maxUid;
    final uid = model.allocateUid();
    final after = decodeSections(model.serialize());
    final written = after.where((s) => s.tag == BlockTag.muid.tag).map((s) => ViMaxUid(s.bytes).maxUid).firstOrNull;
    if (uid != before + 1 || written != uid || after.length != model.sections.length) bad('uid');
    for (var i = 0; i < after.length; i++) {
      if (after[i].tag != BlockTag.muid.tag && !_same(after[i].bytes, model.sections[i].bytes)) bad('uid');
    }
  }

  for (final section in model.sections) {
    section.replace(section.bytes);
  }
  final List<DecodedSection> again;
  try {
    again = decodeSections(model.serialize());
  } catch (_) {
    bad('rewritten');
    return c;
  }
  if (again.length != model.sections.length) {
    bad('count');
    return c;
  }
  for (var i = 0; i < again.length; i++) {
    final before = model.sections[i], after = again[i];
    if (after.tag != before.tag || after.index != before.index) bad('tag');
    if (after.wasCompressed != before.compressed) bad('envelope');
    if (!_same(after.bytes, before.bytes)) bad('payload');
  }

  final first = model.sections.first;
  final length = first.length;
  first.splice(length, length, const [0, 0, 0]);
  final grown = readViSections(model.serialize());
  if (grown.length != model.sections.length || grown.first.bytes.length != length + 3) bad('grown');
  for (final section in grown) {
    if (section.dataOffset & 3 != 0) bad('aligned');
  }
  return c;
}

const modelSerializeLaw = CorpusLaw('model_serialize', _census);

void modelSerializeTests() {
  test(
    'a model writes back byte-exact untouched, one field edited, section-exact rewritten, aligned when grown',
    () async {
      expect(await modelSerializeLaw.nonzero(_laws), isEmpty);
    },
  );
}
