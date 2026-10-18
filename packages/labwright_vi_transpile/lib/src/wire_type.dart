import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'numeric.dart';
import 'type_map.dart';

class LvWireType {
  LvWireType._({required this.dims, required this.element, required this.value});

  /// A scalar wire of [type].
  LvWireType.scalarOf(LvTypeMapping type) : this._(dims: 0, element: type, value: type);

  final LvTypeMapping element;

  final LvTypeMapping value;

  final int dims;

  LvNumericKind? get numeric => element.numeric;

  bool get isMapped => value.isMapped;

  List<LvTypeDecl> get declarations => value.declarations;

  String? get dartType => value.dartType;

  LvCarrier? get carrier => value.carrier;

  String wrap(String expression) => numeric?.wrap(expression) ?? expression;

  String get elementListType => lvArrayDartType(element, 1);

  bool get isErrorCluster => dims == 0 && value.carrier == LvCarrier.error;

  LvWireType get scalar => dims == 0 ? this : LvWireType._(dims: 0, element: element, value: element);
}

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
  return LvWireType._(dims: dims, element: element, value: LvTypeMapping.array(element, dims));
}

LvWireType lvRefnumWireType(ViSignalType signal, int dims) {
  final element = _mapSignalElement(signal.typeCode);
  if (dims == 0 || !element.isMapped) {
    return LvWireType._(dims: dims, element: element, value: element);
  }
  return LvWireType._(dims: dims, element: element, value: LvTypeMapping.array(element, dims));
}

const Set<(int, int)> kLvRefnumContradictedCells = {(TypeCode.refnum, 4)};

/// A refnum wire's dimensionality: from the descriptors of its endpoints' node-terminal parts
/// when they agree, else zero when an endpoint's own descriptor is a scalar refnum, which never
/// contradicts the parts in the corpus (an endpoint's own array descriptor does, and decides
/// nothing).
int? lvRefnumWireDims(BdDiagram diagram, ViWire wire) {
  final signal = wire.signalType;
  if (signal == null || !kLvWireRefnumCodes.contains(signal.typeCode)) return null;
  if (signal.arrayDims != null) return null;
  if (kLvRefnumContradictedCells.contains((signal.typeCode, signal.depth))) return null;
  int? answer;
  for (final endpoint in wire.endpointOids) {
    for (final part in diagram.children(endpoint)) {
      final dims = _refnumDimsOf(part);
      if (dims == null) continue;
      if (answer != null && answer != dims) return null;
      answer = dims;
    }
  }
  if (answer != null) return answer;
  for (final endpoint in wire.endpointOids) {
    final object = diagram.byOid(endpoint);
    if (object != null && _refnumDimsOf(object) == 0) return 0;
  }
  return null;
}

/// The class a refnum wire carries, read from the class-instance descriptor of an endpoint or
/// one of its node-terminal parts; null when none names one.
List<String>? lvClassOfEndpoint(BdDiagram diagram, int endpoint, {required bool array}) {
  final objects = [if (diagram.byOid(endpoint) case final object?) object, ...diagram.children(endpoint)];
  for (final object in objects) {
    final resolved = object.resolvedType;
    final own = _throughTypedefs(array ? resolved?.elementType ?? resolved?.type : resolved?.type);
    if (own is ViRefnumType && own.refnumKind == ViRefnumKind.classInstance && own.classQualifiedName.isNotEmpty) {
      return own.classQualifiedName;
    }
  }
  return null;
}

/// Whether an endpoint of a measure-data wire resolves a timestamp descriptor (the element's for
/// an [array] wire), itself or through typedefs.
bool lvEndpointIsTimestamp(BdDiagram diagram, int oid, {required bool array}) {
  final object = diagram.byOid(oid);
  if (object == null) return false;
  final type = _throughTypedefs(array ? object.resolvedType?.elementType : object.resolvedType?.type);
  return type is ViMeasureDataType && type.flavor == ViMeasureDataFlavor.timeStamp;
}

/// The signal-word type code of a wire whose type the word does not state.
const int kLvUntypedSignalCode = 0xff;

/// The one scalar descriptor the endpoints of an untyped wire resolve, through typedefs; null
/// when none does or when two resolve different ones. An endpoint's array descriptor decides
/// nothing, since it may be the array an element wire indexes.
ViType? lvScalarOfEndpoints(BdDiagram diagram, ViWire wire, List<ViType> pool) {
  ViType? reading;
  for (final endpoint in wire.endpointOids) {
    final own = _throughTypedefs(diagram.byOid(endpoint)?.resolvedType?.type);
    if (own == null || own is ViArrayType) continue;
    if (reading != null && !identical(reading, own) && !_sameDescriptor(reading, own, pool)) return null;
    reading ??= own;
  }
  return reading;
}

bool _sameDescriptor(ViType left, ViType right, List<ViType> pool) {
  if (left.code != right.code || left.label != right.label) return false;
  return left.kind != ViDataType.cluster || lvClusterShape(left, pool) == lvClusterShape(right, pool);
}

/// A wire of timestamps at the signal's dimensionality.
LvWireType lvTimestampWireType(ViSignalType signal) {
  const element = LvTypeMapping.mapped(LvCarrier.timestamp);
  final dims = signal.arrayDims ?? 0;
  return LvWireType._(dims: dims, element: element, value: dims == 0 ? element : LvTypeMapping.array(element, dims));
}

/// A wire of class objects: [element] at [dims] dimensions.
LvWireType lvClassObjectWireType(LvTypeMapping element, int dims) {
  if (dims == 0 || !element.isMapped) return LvWireType._(dims: dims, element: element, value: element);
  return LvWireType._(dims: dims, element: element, value: LvTypeMapping.array(element, dims));
}

int? _refnumDimsOf(BdObject object) {
  final own = _throughTypedefs(object.resolvedType?.type);
  if (own == null) return null;
  if (own.kind == ViDataType.refnum) return 0;
  if (own is! ViArrayType || own.kind != ViDataType.array) return null;
  return _throughTypedefs(object.resolvedType?.elementType)?.kind == ViDataType.refnum ? own.dimCount : null;
}

ViType? _throughTypedefs(ViType? type) {
  for (var depth = 0; type != null && depth < kLvTypedefDepth; depth++) {
    if (type is! ViTypedefType) return type;
    type = type.base;
  }
  return null;
}

const Map<int, LvCarrier> kLvWireRuntimeCarriers = {
  TypeCode.path: LvCarrier.path,
  TypeCode.variant: LvCarrier.variant,
  TypeCode.refnum: LvCarrier.refnum,
  ViSignalType.typedRefnumCode: LvCarrier.refnum,
};

const Set<int> kLvWireRefnumCodes = {TypeCode.refnum, ViSignalType.typedRefnumCode};

const Set<int> kLvWireClusterCodes = {TypeCode.cluster, ViSignalType.clusterVariantCode};

const int kLvTypedefDepth = 8;

ViType? lvClusterBase(ViType? type) {
  for (var depth = 0; type != null && depth < kLvTypedefDepth; depth++) {
    if (type.kind == ViDataType.cluster) return type;
    if (type is! ViTypedefType) return null;
    type = type.base;
  }
  return null;
}

String lvClusterShape(ViType type, List<ViType> pool) {
  final members = clusterFields(lvClusterBase(type) ?? type, pool);
  return '${type.label ?? ''}|${members.map((member) => '${member.code}:${member.label ?? ''}').join(',')}';
}

/// The cluster an endpoint of a cluster wire resolves: its own descriptor (the element's for an
/// [array] wire), else its parent's; a scalar wire whose endpoint resolves a one-dimensional
/// array of clusters carries that array's element.
ViType? lvClusterOfEndpoint(BdDiagram diagram, int oid, {required bool array}) {
  var object = diagram.byOid(oid);
  for (var depth = 0; object != null && depth < 2; depth++) {
    final resolved = object.resolvedType;
    final type = array ? resolved?.elementType : resolved?.type;
    if (lvClusterBase(type) != null) return type;
    if (!array && depth == 0) {
      if (resolved?.type case final ViArrayType own when own.dimCount == 1) {
        final element = resolved?.elementType;
        if (lvClusterBase(element) != null) return element;
      }
    }
    final parent = object.parentOid;
    object = parent == null ? null : diagram.byOid(parent);
  }
  return null;
}

LvWireType lvClusterWireType(ViSignalType signal, ViType cluster, List<ViType> pool, [LvDeclarations? declarations]) {
  final element = mapLvType(cluster, pool, 0, declarations);
  final dims = signal.arrayDims ?? 0;
  if (dims == 0 || !element.isMapped) {
    return LvWireType._(dims: dims, element: element, value: element);
  }
  return LvWireType._(dims: dims, element: element, value: LvTypeMapping.array(element, dims));
}

LvTypeMapping _mapSignalElement(int code) {
  if (LvNumericKind.ofCode(code) case final kind?) {
    return LvTypeMapping.mapped(kind.carrier, numeric: kind);
  }
  if (kLvWireClusterCodes.contains(code)) {
    return LvTypeMapping.unmapped(
      'a cluster wire\'s member types are not in the signal word, and no '
      'endpoint of this wire resolves a cluster descriptor to take them from',
      unmappedCode: code,
    );
  }
  if (code == TypeCode.measureData) {
    return LvTypeMapping.unmapped(
      'a measure-data wire\'s flavor is not in the signal word, and no endpoint of this wire '
      'resolves a timestamp descriptor; waveforms have no decided Dart representation',
      unmappedCode: code,
    );
  }
  if (kLvWireRuntimeCarriers[code] case final carrier?) {
    return LvTypeMapping.mapped(carrier, note: carrier == LvCarrier.refnum ? kRefnumSubtypeNote : null);
  }
  switch (code) {
    case TypeCode.boolean:
    case TypeCode.booleanU16:
      return const LvTypeMapping.mapped(LvCarrier.boolean);
    case TypeCode.string:
    case TypeCode.cString:
    case TypeCode.pascalString:
      return const LvTypeMapping.mapped(LvCarrier.text, note: kStringEncodingNote);
    default:
      return LvTypeMapping.unmapped(
        'wire element type code 0x${code.toRadixString(16)} has no decided Dart '
        'representation',
        unmappedCode: code,
      );
  }
}
