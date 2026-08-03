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

  /// Whether the edge carries a bare LabVIEW **error cluster** — the wire an
  /// [LvErrorMode] decides the carrier of. An array of error clusters is
  /// ordinary data and is not one.
  bool get isErrorCluster => dims == 0 && value.dartType == LvRuntimeType.error;
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

/// Element codes carried by a **runtime type** ([LvRuntimeType]) rather than
/// by a Dart core type. The runtime declares each of them, so a wire of one of
/// these is typed exactly as a numeric wire is.
///
/// The refnum codes are here too, but a refnum wire is refused before it
/// reaches this map: its depth base rides the referenced inner type, so
/// [ViSignalType.arrayDims] is null and the wire's array-ness is not decoded.
/// The entry states the carrier a refnum wire would take once that base is.
const Map<int, String> kLvWireRuntimeCarriers = {
  TypeCode.path: LvRuntimeType.path,
  TypeCode.variant: LvRuntimeType.variant,
  TypeCode.refnum: LvRuntimeType.refnum,
  ViSignalType.typedRefnumCode: LvRuntimeType.refnum,
};

/// The element codes of a **cluster** wire, in both the plain and the
/// typedef/class form ([ViSignalType.clusterVariantCode]).
const Set<int> kLvWireClusterCodes = {TypeCode.cluster, ViSignalType.clusterVariantCode};

/// The cluster descriptor the wire endpoint [oid] resolves in [diagram], or
/// null when neither it nor its owner carries one.
///
/// [array] selects which half of an endpoint's resolved type to read: the
/// element descriptor of a resolved array for an array-of-cluster wire, and
/// the type itself for a scalar cluster wire. The walk stops at the endpoint's
/// owner — the corpus resolves nothing further up (a 1-, 2- and 6-parent walk
/// return identical counts over all 133 106 cluster-coded signals).
ViType? lvClusterOfEndpoint(ViDiagram diagram, int oid, {required bool array}) {
  var object = diagram.byId[oid];
  for (var depth = 0; object != null && depth < 2; depth++) {
    final type = array ? object.resolvedElementType : object.resolvedType;
    if (type != null && type.kind == ViDataType.cluster) return type;
    final parent = object.parentOid;
    object = parent == null ? null : diagram.byId[parent];
  }
  return null;
}

/// The Dart type of a cluster wire whose element descriptor is [cluster],
/// resolved against the VI's type [pool].
///
/// The signal word says only *cluster*; the member types come from the
/// data-space type an endpoint of the wire resolves ([lvClusterOfEndpoint]).
/// Corpus, over 133 106 cluster-coded signals in 7 524 VIs: 99 790 have no
/// endpoint that resolves a cluster descriptor at all, 22 500 have exactly
/// one, and 10 816 have two or more — of which 10 414 (96.3%) agree on the
/// member shape and 402 disagree. The agreement where two ends can be
/// compared is the evidence the route is sound; a wire whose ends disagree,
/// and a wire no end resolves, are both refused rather than picked between.
LvWireType lvClusterWireType(ViSignalType signal, ViType cluster, List<ViType> pool) {
  final element = mapLvType(cluster, pool);
  final dims = signal.arrayDims ?? 0;
  if (dims == 0 || !element.isMapped) {
    return LvWireType._(dims: dims, element: element, value: element);
  }
  return LvWireType._(dims: dims, element: element, value: LvTypeMapping.mapped(lvArrayDartType(element, dims)));
}

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
      'a cluster wire\'s member types are not in the signal word, and no '
      'endpoint of this wire resolves a cluster descriptor to take them from',
      unmappedCode: code,
    );
  }
  if (kLvWireRuntimeCarriers[code] case final carrier?) {
    return LvTypeMapping.mapped(carrier, note: carrier == LvRuntimeType.refnum ? kRefnumSubtypeNote : null);
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
