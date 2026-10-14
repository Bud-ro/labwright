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
        0x45, 0xe7, 0x02, 0x08, // wire table, u16
        0xc5, 0xe7, 0x06, 0x04, 0x08, 0x01, 0x00, 0x06, 0x04, // wire table
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
        'WireTableSpec',
        'WireTableSpec',
        'ObjectSpec',
      ]);
      final table = (object.children[6] as WireTableSpec).table;
      expect(
        [table.pointCount, table.header, table.modes, table.lengths],
        [
          4,
          null,
          [8, 1, 0],
          [6, 4],
        ],
      );
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

  test(
    'a signal reads as a wire over its endpoints and legs, and writes back',
    () {
      final body = _b([
        0, 0, 0, 0, //
        0x10, 0x19, 0x02, 0xfe, 0x00, 0x17, 0xfd, 0x01, 0x0f, // signal 271
        0x11, 0x2b, 0x01, 0xfb, 0x00, 0x02, // two terminals
        0x14, 0x19, 0x01, 0xfd, 0x01, 0x06, //
        0x14, 0x19, 0x01, 0xfd, 0x00, 0xf2, //
        0x09, 0x2b, //
        0x25, 0x15, 0x01, // signalState
        0xc5, 0xe7, 0x06, 0x04, 0x08, 0x01, 0x00, 0x06, 0x04, // wire table
        0x44, 0x9f, 0x01, 0x05, // lastSignalKind
        0x08, 0x19,
      ]);
      ByteData.sublistView(body).setUint32(0, body.length - 4);
      final records = heapSpecsOf(body);
      expect(encodeHeapSpecs(records), body);
      final wire = records.single as WireSpec;
      expect(
        [wire.oid, wire.endpoints, wire.state, wire.kind, wire.flags],
        [
          271,
          [262, 242],
          1,
          0x105,
          null,
        ],
      );
      expect(wire.route!.map((leg) => (leg.direction, leg.length)), [
        (WireRouteDirection.right, 6),
        (WireRouteDirection.up, 4),
        (WireRouteDirection.right, null),
      ]);
      final built = WireSpec(
        271,
        [262, 242],
        route: const [WireLeg.right(6), WireLeg.up(4), WireLeg.right()],
        state: 1,
        kind: 0x105,
      );
      expect(encodeHeapSpecs([built]), body);
      expect(
        emitViSpecDart(
          ViSpec('w.vi', [
            HeapSection('BDHb', [built]),
          ]),
          identifier: 'w',
        ),
        contains(
          'WireSpec(271, [262, 242], route: [WireLeg.right(6), WireLeg.up(4), WireLeg.right()], state: 1, kind: 0x105),',
        ),
      );
      for (final legs in [
        const [WireLeg.right(6), WireLeg.left(4), WireLeg.up()],
        const [WireLeg.right(), WireLeg.up()],
        const [WireLeg.right(6), WireLeg.up(4)],
      ]) {
        expect(() => WireLeg.tableOf(legs), throwsArgumentError);
      }
      expect(
        WireLeg.tableOf(const [
          WireLeg.right(6),
          WireLeg.up(4),
          WireLeg.right(),
        ]).encode(),
        [
          4, 8, 1, 0, 6, 4, //
        ],
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
      MaxUidSection(maxUid: 1),
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
      ['RawSection', 'TypePoolSection', 'HeapSection', 'MaxUidSection'],
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
            WireTableSpec(3, header: [1], modes: [8, 0], lengths: [502]),
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
    expect(
      text,
      contains('WireTableSpec(3, header: [1], modes: [8, 0], lengths: [502]),'),
    );
    expect(text, contains("RawSection('MUID', _h('00000007')),"));
  });
}
