import 'dart:typed_data';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

List<int> pascal(String text) => [text.length, ...text.codeUnits];

List<int> _label(String text) => [...pascal(text), if (text.length.isEven) 0];

List<int> _descriptor(int code, List<int> body, {String? name}) {
  final rest = [name == null ? 0 : 0x40, code, ...body, if (name != null) ..._label(name)];
  return [(2 + rest.length) >> 8 & 0xff, (2 + rest.length) & 0xff, ...rest];
}

List<int> _bodyOf(int code) => switch (code) {
  >= TypeCode.i8 && <= TypeCode.complexExt => const [0],
  TypeCode.string || TypeCode.path || TypeCode.picture || TypeCode.subString => const [0xff, 0xff, 0xff, 0xff],
  TypeCode.refnum || TypeCode.measureData || TypeCode.function => const [0, 0],
  TypeCode.arrayDataPointer || TypeCode.subArray => const [0, 1, 0xff, 0xff, 0xff, 0xff, 0, 0],
  _ => const [],
};

List<int> scalar(int code, {String? name}) => _descriptor(code, _bodyOf(code), name: name);

List<int> cluster(List<int> members, {String? name}) => _descriptor(
  TypeCode.cluster,
  [
    members.length >> 8 & 0xff,
    members.length & 0xff,
    for (final member in members) ...[member >> 8 & 0xff, member & 0xff],
  ],
  name: name,
);

List<int> enumeration(List<String> items, {int code = TypeCode.enumU16, String? name}) {
  final body = [items.length >> 8 & 0xff, items.length & 0xff, for (final item in items) ...pascal(item)];
  return _descriptor(code, [...body, if (body.length.isOdd) 0, 0], name: name);
}

List<int> array(int elementIndex, int dimCount) => _descriptor(TypeCode.array, [
  dimCount >> 8 & 0xff,
  dimCount & 0xff,
  for (var i = 0; i < dimCount; i++) ...[0xff, 0xff, 0xff, 0xff],
  elementIndex >> 8 & 0xff,
  elementIndex & 0xff,
]);

/// A typedef whose inline base is [baseBody] (`flags, code, body...`) labelled [name].
List<int> typeDef(List<int> baseBody, String name) {
  final base = _descriptor(baseBody[1], baseBody.sublist(2), name: name);
  base[1] += 4;
  return _descriptor(TypeCode.typeDef, [0, 0, 0, 0, 0, 0, 0, 1, ...pascal(name), ...base]);
}

List<ViType> poolOf(List<List<int>> descriptors) => decodeTypePool(
  Uint8List.fromList([
    0, 0, 0, descriptors.length, //
    for (final descriptor in descriptors) ...descriptor,
    0, 0,
  ]),
).types;
