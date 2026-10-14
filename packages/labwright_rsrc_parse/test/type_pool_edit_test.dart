import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

Uint8List _pool(List<Uint8List> descriptors, {List<int> topLevel = const []}) =>
    poolOf([for (final d in descriptors) d], topLevel: topLevel);

void main() {
  test('each encoder writes the descriptor its decoder reads back', () {
    final pool = ViTypePool(
      _pool(
        [
          ViBooleanType.encode(label: 'status'),
          ViNumericType.encode(TypeCode.i32, label: 'code'),
          ViStringType.encode(label: 'source'),
          ViClusterType.encode([0, 1, 2], label: 'error out'),
          ViEnumType.encode(TypeCode.enumU32, ['both', 'start', 'end'], label: 'location'),
          ViArrayType.encode(1, dimSizes: [kViUnboundedLength, 3]),
          ViVoidType.encode(),
          ViFunctionType.encode([3, 4, 5, 6], trailer: [3, 0, 0, 0x78]),
          ViVariantType.encode(),
          ViStringType.encode(code: TypeCode.path, label: 'where'),
          ViStringType.encode(code: TypeCode.cString),
          ViNumericType.encode(TypeCode.u8, property: 1, flags: 0x80),
        ],
        topLevel: [7],
      ),
    );
    expect(pool.topLevelIndices, [7]);
    expect(pool.types.map((t) => t.kind), [
      ViDataType.boolean,
      ViDataType.i32,
      ViDataType.string,
      ViDataType.cluster,
      ViDataType.enumU32,
      ViDataType.array,
      ViDataType.voidType,
      ViDataType.function,
      ViDataType.variant,
      ViDataType.path,
      ViDataType.cString,
      ViDataType.u8,
    ]);
    expect(pool.types.map((t) => t.label), [
      'status', 'code', 'source', 'error out', 'location', null, null, null, null, 'where', null, null, //
    ]);
    expect(pool.types.map((t) => t.undecoded.length), [0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0]);
    expect((pool[1] as ViNumericType).property, 0);
    expect((pool[2] as ViStringType).maxLength, kViUnboundedLength);
    expect((pool[3] as ViClusterType).memberIndices, [0, 1, 2]);
    expect((pool[4] as ViEnumType).items, ['both', 'start', 'end']);
    expect((pool[4] as ViEnumType).property, 0);
    final array = pool[5] as ViArrayType;
    expect((array.dimCount, array.dimSizeAt(0), array.dimSizeAt(1), array.elementIndex), (2, kViUnboundedLength, 3, 1));
    final function = pool[7] as ViFunctionType;
    expect([for (var i = 0; i < 4; i++) function.parameterIndexAt(i)], [3, 4, 5, 6]);
    expect(function.undecoded, [3, 0, 0, 0x78]);
    expect((pool[10] as ViStringType).maxLength, isNull);
    expect(((pool[11] as ViNumericType).property, pool[11].flags), (1, 0x80));
  });

  test('labels pad to an even length and enum items pad as a block before the property byte', () {
    expect(ViBooleanType.encode(label: 'ab'), [0, 8, 0x40, TypeCode.boolean, 2, 0x61, 0x62, 0]);
    expect(ViBooleanType.encode(label: 'abc'), [0, 8, 0x40, TypeCode.boolean, 3, 0x61, 0x62, 0x63]);
    expect(ViEnumType.encode(TypeCode.enumU8, ['a']), [0, 9, 0, TypeCode.enumU8, 0, 1, 1, 0x61, 0]);
    expect(ViEnumType.encode(TypeCode.enumU8, ['ab']), [0, 11, 0, TypeCode.enumU8, 0, 1, 2, 0x61, 0x62, 0, 0]);
  });

  test('a model adds, replaces and re-lists top-level types, reloading what depends on them', () {
    final file = buildRsrc([
      (
        tag: 'VCTP',
        sections: [
          _pool(
            [
              ViNumericType.encode(TypeCode.i32, label: 'n'),
              ViFunctionType.encode([0]),
            ],
            topLevel: [1],
          ),
        ],
      ),
      (tag: 'CONP', sections: [be16(1)]),
      (tag: 'MUID', sections: [be32(1)]),
    ]);
    final model = buildViModel(file);
    expect(model.types.map((t) => t.kind), [ViDataType.i32, ViDataType.function]);
    expect((model.connectorPaneType as ViFunctionType).parameterCount, 1);

    final text = model.addType(ViStringType.encode(label: 'text'));
    expect((text, model.types.length, model.types[2].label), (2, 3, 'text'));
    model.replaceType(1, ViFunctionType.encode([0, text]));
    expect((model.connectorPaneType as ViFunctionType).parameterCount, 2);
    expect(model.types[2].label, 'text');

    final pane = model.addType(ViFunctionType.encode([text]));
    model.setTopLevelTypes([pane, 0]);
    expect(ViTypePool(model.section('VCTP')!.bytes).topLevelIndices, [pane, 0]);
    expect((model.connectorPaneType as ViFunctionType).parameterIndexAt(0), text);

    final again = buildViModel(model.serialize());
    expect(again.types.map((t) => t.label), ['n', null, 'text', null]);
    expect(again.types.map((t) => t.kind), [
      ViDataType.i32,
      ViDataType.function,
      ViDataType.string,
      ViDataType.function,
    ]);
    expect((again.connectorPaneType as ViFunctionType).parameterIndexAt(0), text);
  });
}
