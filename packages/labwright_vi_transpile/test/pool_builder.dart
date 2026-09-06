import 'dart:typed_data';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

List<int> pascal(String text) => [text.length, ...text.codeUnits];

List<int> _descriptor(List<int> body) => [(2 + body.length) >> 8 & 0xff, (2 + body.length) & 0xff, ...body];

List<int> scalar(int code, {String? name}) => _descriptor([0x40, code, if (name != null) ...pascal(name)]);

List<int> cluster(List<int> members, {String? name}) => _descriptor([
  0x40,
  TypeCode.cluster,
  members.length >> 8 & 0xff,
  members.length & 0xff,
  for (final member in members) ...[member >> 8 & 0xff, member & 0xff],
  if (name != null) ...pascal(name),
]);

List<int> enumeration(List<String> items, {int code = TypeCode.enumU16, String? name}) => _descriptor([
  0x40,
  code,
  items.length >> 8 & 0xff,
  items.length & 0xff,
  for (final item in items) ...pascal(item),
  if (name != null) ...pascal(name),
]);

List<int> array(int elementIndex, int dimCount) => _descriptor([
  0x40,
  TypeCode.array,
  dimCount >> 8 & 0xff,
  dimCount & 0xff,
  for (var i = 0; i < dimCount; i++) ...[0xff, 0xff, 0xff, 0xff],
  elementIndex >> 8 & 0xff,
  elementIndex & 0xff,
]);

List<int> typeDef(List<int> baseBody, String name) {
  final trailing = pascal(name);
  return _descriptor([
    0x40,
    TypeCode.typeDef,
    0, 0, 0, 0, //
    0, 0, 0, 1,
    ...pascal(name),
    0x00, 2 + baseBody.length + trailing.length + 4,
    ...baseBody,
    ...trailing,
  ]);
}

List<ViType> poolOf(List<List<int>> descriptors) => decodeTypePool(
  Uint8List.fromList([
    0, 0, 0, descriptors.length, //
    for (final descriptor in descriptors) ...descriptor,
  ]),
);
