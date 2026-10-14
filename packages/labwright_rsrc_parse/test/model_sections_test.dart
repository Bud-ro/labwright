import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

Uint8List _file() => buildRsrc([
  (tag: 'LVSR', sections: [List.filled(6, 1)]),
  (tag: 'MUID', sections: [be32(7)]),
  (tag: 'vers', sections: [List.filled(3, 2), List.filled(5, 3)]),
  (
    tag: 'BDHb',
    sections: [
      compressedSection(heapBody([...open(0x1234, 7), ...close()])),
    ],
  ),
]);

void main() {
  test('a loaded section shares its decoded bytes until the first edit, then owns slack', () {
    final section = ViSectionBuffer('LVSR', 0, u8([1, 2, 3, 4]), compressed: false, secRel: 0);
    expect((section.edited, section.length), (false, 4));
    expect(section.bytes, [1, 2, 3, 4]);
    section.splice(1, 3, [9, 9, 9]);
    expect(section.edited, isTrue);
    expect(section.bytes, [1, 9, 9, 9, 4]);
    section.splice(0, 1, []);
    expect(section.bytes, [9, 9, 9, 4]);
    section.splice(4, 4, List.filled(20000, 7));
    expect(section.length, 20004);
    expect(section.bytes.take(4), [9, 9, 9, 4]);
    section.replace([5]);
    expect(section.bytes, [5]);
  });

  test('a model holds every section with its tag, index, envelope and offset', () {
    final model = buildViModel(_file());
    expect(model.sections.map((s) => (s.tag, s.index, s.compressed, s.edited)), [
      ('LVSR', 0, false, false),
      ('MUID', 0, false, false),
      ('vers', 0, false, false),
      ('vers', 1, false, false),
      ('BDHb', 0, true, false),
    ]);
    expect(model.sections.map((s) => s.secRel!), [0, 12, 20, 28, 40]);
    expect(model.section('BDHb')!.bytes, heapBody([...open(0x1234, 7), ...close()]));
    expect(model.section('vers', 1)!.bytes, [3, 3, 3, 3, 3]);
    expect(model.section('vers', 2), isNull);
  });

  test('an unedited model serializes to the bytes it was loaded from', () {
    final bytes = _file();
    expect(buildViModel(bytes).serialize(), bytes);
  });

  test('an edited section is written back, re-deflated when it was compressed, and the rest realign', () {
    final model = buildViModel(_file());
    model.sections[0].splice(6, 6, [8, 8, 8]);
    model.section('BDHb')!.replace(heapBody([...open(0x4321, 9), ...caption('hi'), ...close()]));
    final again = buildViModel(model.serialize());
    expect(again.sections.map((s) => (s.tag, s.index, s.compressed)), [
      ('LVSR', 0, false),
      ('MUID', 0, false),
      ('vers', 0, false),
      ('vers', 1, false),
      ('BDHb', 0, true),
    ]);
    expect(again.sections.map((s) => s.bytes), [
      [1, 1, 1, 1, 1, 1, 8, 8, 8],
      be32(7),
      [2, 2, 2],
      [3, 3, 3, 3, 3],
      heapBody([...open(0x4321, 9), ...caption('hi'), ...close()]),
    ]);
    expect(again.sections.map((s) => s.secRel! & 3), everyElement(0));
    expect(again.blockDiagrams.single.objects.single.label, 'hi');
    expect(again.serialize(), model.serialize());
  });

  test('a field written in place lands in the section alone, and reads back after a round trip', () {
    final bytes = _file();
    final model = buildViModel(bytes);
    final muid = model.section('MUID')!;
    expect(ViMaxUid(muid.bytes).maxUid, 7);
    expect((model.allocateUid(), model.allocateUid()), (8, 9));
    expect((muid.edited, ViMaxUid(muid.bytes).maxUid), (true, 9));
    expect(model.sections.where((s) => s.edited).map((s) => s.tag), ['MUID']);
    expect(readViSections(bytes).firstWhere((s) => s.tag == 'MUID').bytes, be32(7));
    expect(ViMaxUid(buildViModel(model.serialize()).section('MUID')!.bytes).maxUid, 9);
  });

  test('a model built without a file has nothing to write into', () {
    final model = buildViModelFromDecoded(decodeSections(_file()));
    expect(model.file, isNull);
    expect(model.serialize, throwsStateError);
  });
}
