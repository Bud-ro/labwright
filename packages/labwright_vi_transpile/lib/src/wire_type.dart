/// The **wire** half of the type model: what a decoded block-diagram signal
/// word ([ViSignalType]) carries, expressed in the same [LvTypeMapping] terms
/// the consolidated type pool resolves to.
///
/// A signal word is not a pool descriptor — it holds an element type code, an
/// array depth and a flag nibble, and nothing else. That is exactly enough to
/// type a dataflow edge, and it is per-wire rather than per-terminal, so it is
/// the authority on what flows: a tunnel whose two sides carry different
/// dimensionalities is visible here as two different [LvWireType]s.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'numeric.dart';
import 'type_map.dart';

/// The Dart type of one dataflow edge.
class LvWireType {
  LvWireType._({required this.dims, required this.element, required this.value});

  /// The Dart representation of the edge's **element** — the scalar under any
  /// array wrapping, and the whole value itself when [dims] is 0.
  final LvTypeMapping element;

  /// The Dart representation of the whole edge value.
  final LvTypeMapping value;

  /// The array dimension count: 0 for a scalar edge, 1 for a 1-D array.
  final int dims;

  /// The element's numeric width model, or null when it is not a number.
  LvNumericKind? get numeric => element.numeric;

  /// Whether the whole edge value has a decided Dart representation.
  bool get isMapped => value.isMapped;

  /// The Dart type source of the whole edge value, or null when unmapped.
  String? get dartType => value.dartType;

  /// [expression] renormalized to the element's LabVIEW width — the identity
  /// for a non-numeric or already-exact carrier.
  String wrap(String expression) => numeric?.wrap(expression) ?? expression;

  /// The Dart type of a 1-D array **over this edge's element**: the storage a
  /// value of this element type is collected into.
  String get elementListType => lvArrayDartType(element, 1);
}

/// The Dart type of a wire whose decoded signal word is [signal].
///
/// Total: a word whose element code has no decided representation, or whose
/// array depth base is not pinned ([ViSignalType.arrayDims] null), comes back
/// with an unmapped [LvWireType.value] carrying the reason — never a guess.
LvWireType mapLvWireType(ViSignalType signal) {
  final dims = signal.arrayDims;
  final element = _mapSignalElement(signal.typeCode);
  if (dims == null) {
    final why =
        'wire type code 0x${signal.typeCode.toRadixString(16)} has no pinned '
        'array-depth base, so the wire\'s dimensionality is not decoded';
    return LvWireType._(dims: 0, element: element, value: LvTypeMapping.unmapped(why));
  }
  if (dims == 0 || !element.isMapped) {
    return LvWireType._(dims: dims, element: element, value: element);
  }
  return LvWireType._(
    dims: dims,
    element: element,
    value: LvTypeMapping.mapped(lvArrayDartType(element, dims)),
  );
}

/// Element codes whose Dart representation the type model has decided but
/// whose **carrier type a generated file does not declare** — every one is a
/// runtime type a translation still needs ([LvRuntimeType]). A wire of one of
/// these is unmapped here on purpose: naming a type nothing declares would
/// emit code that does not compile.
const Map<int, String> kLvWireRuntimeCarriers = {
  TypeCode.path: LvRuntimeType.path,
  TypeCode.variant: LvRuntimeType.variant,
  TypeCode.refnum: LvRuntimeType.refnum,
  ViSignalType.typedRefnumCode: LvRuntimeType.refnum,
};

/// The element codes of a **cluster** wire, in both the plain and the
/// typedef/class form ([ViSignalType.clusterVariantCode]).
const Set<int> kLvWireClusterCodes = {TypeCode.cluster, ViSignalType.clusterVariantCode};

/// The Dart representation of a signal word's element type [code].
///
/// The wire word carries only the flattened scalar family — enums, typedefs
/// and substrings ride their flattened code — so this resolves the leaf codes
/// directly rather than through a pool descriptor.
LvTypeMapping _mapSignalElement(int code) {
  if (LvNumericKind.ofCode(code) case final kind?) {
    return LvTypeMapping.mapped(kind.dartType, numeric: kind);
  }
  if (kLvWireClusterCodes.contains(code)) {
    return LvTypeMapping.unmapped(
      'a cluster wire\'s member types are not in the signal word, so its Dart '
      'record or class shape is not decided per-wire',
      unmappedCode: code,
    );
  }
  if (kLvWireRuntimeCarriers[code] case final carrier?) {
    return LvTypeMapping.unmapped(
      'the wire carries a $carrier, a runtime type a generated file does not '
      'declare yet',
      unmappedCode: code,
    );
  }
  switch (code) {
    case TypeCode.boolean:
    case TypeCode.booleanU16:
      return const LvTypeMapping.mapped('bool');
    case TypeCode.string:
    case TypeCode.cString:
    case TypeCode.pascalString:
      return const LvTypeMapping.mapped('String', note: kStringEncodingNote);
    default:
      return LvTypeMapping.unmapped(
        'wire element type code 0x${code.toRadixString(16)} has no decided Dart '
        'representation',
        unmappedCode: code,
      );
  }
}
