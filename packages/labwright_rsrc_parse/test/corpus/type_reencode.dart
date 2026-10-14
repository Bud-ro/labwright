import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _laws = {
  'differs.voidType',
  'differs.numeric',
  'differs.enum',
  'differs.boolean',
  'differs.string',
  'differs.array',
  'differs.cluster',
  'differs.function',
  'differs.variant',
};

/// The descriptor re-encoded from the fields [type] decodes, or null for a kind without an
/// encoder.
(String, Uint8List)? _reencoded(ViType type) {
  final label = type.hasLabel ? type.label : null;
  final flags = type.flags & ~ViTypeFlag.label.mask;
  return switch (type) {
    ViVoidType() => ('voidType', ViVoidType.encode(label: label, flags: flags)),
    ViNumericType(:final property?) => (
      'numeric',
      ViNumericType.encode(type.code, label: label, property: property, flags: flags),
    ),
    ViEnumType(:final property?) => (
      'enum',
      ViEnumType.encode(type.code, type.items, label: label, property: property, flags: flags),
    ),
    ViBooleanType() => ('boolean', ViBooleanType.encode(code: type.code, label: label, flags: flags)),
    ViStringType() => (
      'string',
      ViStringType.encode(code: type.code, maxLength: type.maxLength ?? 0, label: label, flags: flags),
    ),
    ViArrayType() => (
      'array',
      ViArrayType.encode(
        type.elementIndex,
        dimSizes: [for (var d = 0; d < type.dimCount; d++) type.dimSizeAt(d)],
        code: type.code,
        label: label,
        flags: flags,
      ),
    ),
    ViClusterType() => ('cluster', ViClusterType.encode(type.memberIndices, label: label, flags: flags)),
    ViFunctionType() => (
      'function',
      ViFunctionType.encode(
        [for (var p = 0; p < type.parameterCount; p++) type.parameterIndexAt(p)],
        trailer: type.undecoded,
        flags: flags,
      ),
    ),
    ViVariantType() => ('variant', ViVariantType.encode(label: label, flags: flags)),
    _ => null,
  };
}

Map<String, int> _census(CorpusVi vi) {
  final c = <String, int>{};
  for (final type in vi.model?.types ?? const <ViType>[]) {
    final reencoded = _reencoded(type);
    if (reencoded == null) continue;
    final (kind, bytes) = reencoded;
    final original = type.descriptorBytes;
    var same = bytes.length == original.length;
    for (var i = 0; same && i < bytes.length; i++) {
      same = bytes[i] == original[i];
    }
    final key = same ? 'same' : 'differs.$kind';
    c[key] = (c[key] ?? 0) + 1;
  }
  return c;
}

const typeReencodeLaw = CorpusLaw('type_reencode', _census);

void typeReencodeTests() {
  test('every descriptor of a kind with an encoder re-encodes to its own bytes', () async {
    expect(await typeReencodeLaw.nonzero(_laws), isEmpty);
  });
}
