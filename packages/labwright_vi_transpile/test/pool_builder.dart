import 'dart:typed_data';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

/// Synthetic `VCTP` descriptors, so the type model's tests state a pool by its
/// shape instead of by a corpus file. Each builder returns one descriptor
/// (`[u16 length][u8 flags][u8 code][interior]`); [poolOf] frames a list of
/// them into a pool and decodes it.

/// A Pascal string: `[u8 length][chars]`.
List<int> pascal(String text) => [text.length, ...text.codeUnits];

List<int> _descriptor(List<int> body) => [(2 + body.length) >> 8 & 0xff, (2 + body.length) & 0xff, ...body];

/// A leaf descriptor of [code], optionally carrying a trailing [name].
List<int> scalar(int code, {String? name}) => _descriptor([0x40, code, if (name != null) ...pascal(name)]);

/// A cluster over [members] (pool indices), optionally named.
List<int> cluster(List<int> members, {String? name}) => _descriptor([
  0x40,
  TypeCode.cluster,
  members.length >> 8 & 0xff,
  members.length & 0xff,
  for (final member in members) ...[member >> 8 & 0xff, member & 0xff],
  if (name != null) ...pascal(name),
]);

/// An enum of [items] in ordinal order, optionally named.
List<int> enumeration(List<String> items, {int code = TypeCode.enumU16, String? name}) => _descriptor([
  0x40,
  code,
  items.length >> 8 & 0xff,
  items.length & 0xff,
  for (final item in items) ...pascal(item),
  if (name != null) ...pascal(name),
]);

/// A [dimCount]-dimensional array of variable-length dimensions over the pool
/// entry at [elementIndex].
List<int> array(int elementIndex, int dimCount) => _descriptor([
  0x40,
  TypeCode.array,
  dimCount >> 8 & 0xff,
  dimCount & 0xff,
  for (var i = 0; i < dimCount; i++) ...[0xff, 0xff, 0xff, 0xff],
  elementIndex >> 8 & 0xff,
  elementIndex & 0xff,
]);

/// A typedef named [name] over an inline base whose flags-and-interior bytes
/// are [baseBody]: `[u32 checksum][u32 pathCount][path][base][trailing name]`,
/// where the base's length word counts 4 more than the bytes it occupies.
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

/// The decoded pool of [descriptors], in order.
List<ViType> poolOf(List<List<int>> descriptors) => decodeTypePool(
  Uint8List.fromList([
    0, 0, 0, descriptors.length, //
    for (final descriptor in descriptors) ...descriptor,
  ]),
);
