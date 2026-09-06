import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'numeric.dart';
import 'type_map.dart';

class LvWireType {
  LvWireType._({required this.dims, required this.element, required this.value});

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

int? lvRefnumWireDims(ViDiagram diagram, ViWire wire) {
  final signal = wire.signalType;
  if (signal == null || !kLvWireRefnumCodes.contains(signal.typeCode)) return null;
  if (signal.arrayDims != null) return null;
  if (kLvRefnumContradictedCells.contains((signal.typeCode, signal.depth))) return null;
  int? answer;
  for (final endpoint in wire.endpointOids) {
    for (final part in diagram.childrenByOid[endpoint] ?? const <ViHeapObject>[]) {
      final dims = _refnumDimsOf(part);
      if (dims == null) continue;
      if (answer != null && answer != dims) return null;
      answer = dims;
    }
  }
  return answer;
}

int? _refnumDimsOf(ViHeapObject object) {
  final own = _throughTypedefs(object.resolvedType);
  if (own == null) return null;
  if (own.kind == ViDataType.refnum) return 0;
  if (own.kind != ViDataType.array) return null;
  return _throughTypedefs(object.resolvedElementType)?.kind == ViDataType.refnum ? (own.dimCount ?? 1) : null;
}

ViType? _throughTypedefs(ViType? type) {
  for (var depth = 0; type != null && depth < kLvTypedefDepth; depth++) {
    if (type.kind != ViDataType.typeDef) return type;
    type = type.typedefBase;
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
    if (type.kind != ViDataType.typeDef) return null;
    type = type.typedefBase;
  }
  return null;
}

String lvClusterShape(ViType type, List<ViType> pool) {
  final members = clusterFields(lvClusterBase(type) ?? type, pool);
  return '${type.name ?? ''}|${members.map((member) => '${member.code}:${member.name ?? ''}').join(',')}';
}

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
