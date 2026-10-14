import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_text/labwright_vi_text.dart';
import 'package:test/test.dart';

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
  test(
    'typed records re-encode to the bytes they were read from, verbatim ones stay verbatim',
    () {
      final body = _b([
        0, 0, 0, 0, //
        0x10,
        0x19,
        0x02,
        0xfe,
        0x00,
        0x2f,
        0xfd,
        0x00,
        0x07, // object 0x2f oid 7
        0xc4, 0x2d, 0x08, 0, 1, 0, 2, 0, 3, 0, 4, // bounds
        0xc4, 0x22, 0x02, 0x68, 0x69, // caption hi
        0x45, 0x3a, 0x12, 0x34, // typeDescIndex u16 (bank 1)
        0x04, 0x05, // flag false
        0x14, 0x19, 0x01, 0xfd, 0x00, 0x03, // childRef 3
        0x11,
        0x19,
        0x02,
        0xfe,
        0x00,
        0x16,
        0xfd,
        0x80,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00, // wide object oid 65536
        0x09, 0x19, //
        0x08, 0x19,
      ]);
      ByteData.sublistView(body).setUint32(0, body.length - 4);
      final records = heapSpecsOf(body);
      expect(encodeHeapSpecs(records), body);
      final object = records.single as ObjectSpec;
      expect(
        (object.objectClass, object.oid, object.close),
        (HeapObjectClass.bdNode, 7, (0x08, 0x19)),
      );
      expect(object.children.map((r) => r.runtimeType.toString()), [
        'C4Spec',
        'C4Spec',
        'AttrSpec',
        'AttrSpec',
        'RefSpec',
        'ObjectSpec',
      ]);
      final attr = object.children[2] as AttrSpec;
      expect(
        (attr.attribute, attr.value, attr.width),
        (HeapAttribute.typeDescIndex, 0x1234, HeapAttrWidth.u16),
      );
      final inner = object.children.last as ObjectSpec;
      expect(
        (inner.oid, inner.wide, inner.lead, inner.close),
        (65536, true, 0x11, (0x09, 0x19)),
      );
    },
  );

  test('a spec builds a file that reads back to the same sections', () {
    final spec = ViSpec('demo.vi', [
      RawSection('LVSR', _b([1, 2, 3, 4])),
      TypePoolSection(
        [ViNumericType.encode(TypeCode.i32, label: 'n')],
        topLevel: [0],
      ),
      HeapSection('BDHb', [
        ObjectSpec(
          HeapObjectClass.diagramRoot,
          1,
          children: [C4Spec.bounds(0, 0, 10, 10), C4Spec.caption('root')],
        ),
      ]),
      RawSection('MUID', _b([0, 0, 0, 1])),
    ]);
    final again = decodeSections(spec.encode());
    expect(again.map((s) => (s.tag, s.index, s.wasCompressed)), [
      ('LVSR', 0, false),
      ('VCTP', 0, true),
      ('BDHb', 0, true),
      ('MUID', 0, false),
    ]);
    for (var i = 0; i < again.length; i++) {
      expect(again[i].bytes, spec.sections[i].payload);
    }
    expect(
      viSpecOf(spec.encode()).sections.map((s) => s.runtimeType.toString()),
      ['RawSection', 'TypePoolSection', 'HeapSection', 'RawSection'],
    );
  });

  test('the emitted Dart names what the records are', () {
    final spec = ViSpec('demo.vi', [
      HeapSection('BDHb', [
        ObjectSpec(
          HeapObjectClass.bdNode,
          7,
          children: [
            C4Spec.bounds(1, 2, 3, 4),
            C4Spec.caption('hi'),
            const AttrSpec(0x13a, 0x1234, width: HeapAttrWidth.u16),
            const RefSpec(0x019, 3),
          ],
        ),
      ]),
      RawSection('MUID', _b([0, 0, 0, 7])),
    ]);
    final text = emitViSpecDart(spec, identifier: 'demo');
    expect(text, contains("final ViSpec demo = ViSpec('demo.vi', ["));
    expect(text, contains('ObjectSpec(HeapObjectClass.bdNode, 7, children: ['));
    expect(text, contains('C4Spec.bounds(1, 2, 3, 4),'));
    expect(text, contains("C4Spec.caption('hi'),"));
    expect(
      text,
      contains(
        'AttrSpec(HeapAttribute.typeDescIndex.raw, 0x1234, width: HeapAttrWidth.u16),',
      ),
    );
    expect(text, contains('RefSpec(HeapRefKind.childRef.raw, 3),'));
    expect(text, contains("RawSection('MUID', _h('00000007')),"));
  });
}
