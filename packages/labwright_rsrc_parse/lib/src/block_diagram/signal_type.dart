import '../blocks/VCTP_type_pool.dart';
import '../heap/heap_object.dart';

/// A signal's `lastSignalKind` word: the low byte is the `VCTP` type code, bits 8–11 the
/// depth (the scalar depth of the code plus one per array dimension), bits 12–15 flags.
class ViSignalType {
  const ViSignalType(this.raw);

  final int raw;

  /// The type code of a cluster carried as a variant.
  static const int clusterVariantCode = 0x51;

  /// The type code of a typed refnum.
  static const int typedRefnumCode = 0x71;

  int get typeCode => raw & 0xff;

  int get depth => (raw >> 8) & 0xf;

  // TODO: the flag nibble's meaning is not decoded.
  int get flags => (raw >> 12) & 0xf;

  /// The data type of [typeCode]; null for a code the pool grammar does not name.
  ViDataType? get dataType => switch (typeCode) {
    clusterVariantCode => ViDataType.cluster,
    typedRefnumCode => ViDataType.refnum,
    _ => dataTypeOfCode(typeCode),
  };

  /// The kind of the scalar or element type.
  ViTypeKind? get elementKind {
    final t = dataType;
    return t == null ? null : typeKindOfDataType(t);
  }

  /// Array dimensions: [depth] above the code's scalar depth; null when the code's scalar depth
  /// is not established and the depth is not the minimum.
  int? get arrayDims {
    final base = _signalScalarDepth(typeCode);
    if (base == null) return depth == kSignalMinScalarDepth ? 0 : null;
    final dims = depth - base;
    return dims < 0 ? null : dims;
  }

  bool? get isArray {
    final dims = arrayDims;
    return dims == null ? null : dims > 0;
  }

  /// [ViTypeKind.array] for an array, else [elementKind].
  ViTypeKind? get typeKind => isArray == true ? ViTypeKind.array : elementKind;

  @override
  bool operator ==(Object other) => other is ViSignalType && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;
}

/// The depth of a scalar numeric signal.
const int kSignalMinScalarDepth = 1;

int? _signalScalarDepth(int code) {
  if (code >= TypeCode.i8 && code <= TypeCode.complexExt) return 1;
  if (code >= TypeCode.enumU8 && code <= TypeCode.enumU32) return 1;
  if (code == TypeCode.booleanU16 || code == TypeCode.boolean) return 1;
  if (code == TypeCode.string || code == TypeCode.path || code == TypeCode.picture || code == TypeCode.tag) {
    return 2;
  }
  if (code == TypeCode.cluster ||
      code == ViSignalType.clusterVariantCode ||
      code == TypeCode.variant ||
      code == TypeCode.measureData) {
    return 3;
  }
  return null;
}
