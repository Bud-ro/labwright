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

  /// This edge's type with its array wrapping removed — the scalar an
  /// elementwise lowering operates on. Already scalar edges return themselves.
  LvWireType get scalar => dims == 0 ? this : LvWireType._(dims: 0, element: element, value: element);
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
/// The refnum codes are here too. A refnum wire's depth base rides its
/// reference class rather than its code, so only the ones the depth-1 law
/// decides ([kSignalMinScalarDepth]) carry a dimensionality; a deeper refnum
/// word reaches this map with [ViSignalType.arrayDims] null and is refused.
const Map<int, String> kLvWireRuntimeCarriers = {
  TypeCode.path: LvRuntimeType.path,
  TypeCode.variant: LvRuntimeType.variant,
  TypeCode.refnum: LvRuntimeType.refnum,
  ViSignalType.typedRefnumCode: LvRuntimeType.refnum,
};

/// The element codes of a **refnum** wire, in both the plain and the
/// inner-typed form ([ViSignalType.typedRefnumCode]).
const Set<int> kLvWireRefnumCodes = {TypeCode.refnum, ViSignalType.typedRefnumCode};

/// The element codes of a **cluster** wire, in both the plain and the
/// typedef/class form ([ViSignalType.clusterVariantCode]).
const Set<int> kLvWireClusterCodes = {TypeCode.cluster, ViSignalType.clusterVariantCode};

/// How many typedef wrappers [lvClusterBase] looks through. The pool decodes
/// a typedef's base inline and admits a typedef of a typedef, so the walk is
/// bounded rather than open-ended.
const int kLvTypedefDepth = 8;

/// The **cluster** [type] stands for: itself when it is one, and the base of a
/// typedef over one. Null for every other descriptor.
///
/// A typedef is transparent to its base — [mapLvType] already reads it that
/// way, giving the typedef's name to the cluster it wraps — so a typedef over
/// a cluster is a cluster descriptor for the purpose of typing a wire. It is
/// also the shape the `0x51` wire code names (the typedef'd / class-typed
/// cluster family), and looking through it resolves 9 381 of the corpus's
/// 133 106 cluster wires that the bare-cluster test alone leaves with no
/// member shape, while contradicting that test on 24.
ViType? lvClusterBase(ViType? type) {
  for (var depth = 0; type != null && depth < kLvTypedefDepth; depth++) {
    if (type.kind == ViDataType.cluster) return type;
    if (type.kind != ViDataType.typeDef) return null;
    type = type.typedefBase;
  }
  return null;
}

/// The identity two endpoints of a cluster wire must agree on for the wire to
/// have one Dart type: the descriptor's own name, and its members' type codes
/// and names. Two descriptors with the same shape are the same wire type
/// however many pool entries spell it.
String lvClusterShape(ViType type, List<ViType> pool) {
  final members = clusterFields(lvClusterBase(type) ?? type, pool);
  return '${type.name ?? ''}|${members.map((member) => '${member.code}:${member.name ?? ''}').join(',')}';
}

/// The cluster descriptor the wire endpoint [oid] resolves in [diagram], or
/// null when neither it nor its owner carries one. A typedef over a cluster is
/// returned as itself ([lvClusterBase]), so the wire keeps the typedef's name.
///
/// [array] selects which half of an endpoint's resolved type to read: the
/// element descriptor of a resolved array for an array-of-cluster wire, and
/// the type itself for a scalar cluster wire. Reading the OTHER half instead
/// would resolve a further 586 wires, but it asserts that an endpoint
/// describing an array of clusters describes a scalar cluster wire's element
/// (and the converse) — which nothing decoded says — so it is not read. The
/// walk stops at the endpoint's owner: the corpus resolves nothing further up
/// (a 1-, 2- and 6-parent walk return identical counts over all 133 106
/// cluster-coded signals).
///
/// It stops there because there is nothing there to read. Across the 184 697
/// endpoints of the 88 743 cluster wires no endpoint resolves, NOT ONE carries
/// a type-descriptor index of its own ([ViHeapObject.typeDescIdx]) — a wire
/// endpoint is a holder (`0x15`, 174 208) or an interface terminal (`0x16`,
/// 10 489), and neither class stores one. Every type such an endpoint has is
/// inherited from a paired panel DCO through its `dcoRef`, and 123 263 of them
/// carry no `dcoRef` either. This is a missing decode of where the compiled
/// data space types a wire, not a walk that gives up early.
ViType? lvClusterOfEndpoint(ViDiagram diagram, int oid, {required bool array}) {
  var object = diagram.byId[oid];
  for (var depth = 0; object != null && depth < 2; depth++) {
    final type = array ? object.resolvedElementType : object.resolvedType;
    if (lvClusterBase(type) != null) return type;
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
/// Corpus, over 133 106 cluster-coded signals in 7 524 VIs: 88 743 have no
/// endpoint that resolves a cluster descriptor at all, 43 861 resolve exactly
/// one member shape, and 502 resolve two or more. The agreement where two ends
/// can be compared is the evidence the route is sound; a wire whose ends
/// disagree, and a wire no end resolves, are both refused rather than picked
/// between.
///
/// The **callee's connector pane** is not a second source. A call node's
/// holders are its pane terminals in pane order (the binding the subVI
/// contract already proves at 99.83%), so a cluster wire ending on one can be
/// read against the callee VI's own terminal for that pane — but measured over
/// the corpus that reading decides only 1 960 of the 88 743 unresolved wires
/// (2.2%), and where both it and the endpoint route resolve exactly one shape
/// it reproduces that shape 338 times against 505 disagreements. Comparing
/// member type codes alone lifts the agreement to 764/844, so most of the
/// disagreement is the descriptor NAME: caller and callee spell the same
/// members under different typedefs, and the name is what the emitted Dart
/// type is. Two readings that name a wire differently 60% of the time are not
/// one route, so the pane side is measured ([kCorpusLoweringSweep]'s
/// `clus.pane*`) and not read.
///
/// The unresolved majority is the corpus's single largest lowering blocker.
/// Of the 6 804 VIs whose dataflow build refuses on `wireType`, the wire the
/// refusal names is a cluster wire in 5 088, and 2 626 have no unmapped wire
/// of any other family at all. The rest of that bucket is the refnum codes'
/// array-depth base, which rides the reference class rather than the code
/// (named first in 1 532 VIs, the sole family in 224 — the depth-1 law
/// [kSignalMinScalarDepth] decides the other half of those wires), and the
/// element codes with no Dart representation (measureData `0x54` 71, the
/// uncatalogued `0xff` 54, packed string `0x33` 37, tag `0x37` 16).
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
