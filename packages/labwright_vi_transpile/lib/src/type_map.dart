import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'numeric.dart';

abstract final class LvRuntimeType {
  static const String error = 'LvError';

  static const String clearedError = '$error.none';

  static const String path = 'LvPath';

  static const String refnum = 'LvRefnum';

  static const String variant = 'LvVariant';

  static const String arrayNd = 'LvArrayNd';

  static const String anonymousEnum = 'LvEnum';
}

enum LvCarrier {
  voidValue('void'),
  boolean('bool'),
  text('String'),
  integer('int'),
  float('double'),
  error(LvRuntimeType.error, runtime: true),
  path(LvRuntimeType.path, runtime: true),
  refnum(LvRuntimeType.refnum, runtime: true),
  variant(LvRuntimeType.variant, runtime: true),
  nominal(null),
  compound(null)
  ;

  const LvCarrier(this.dartType, {this.runtime = false});

  final String? dartType;

  final bool runtime;
}

extension LvNumericCarrier on LvNumericKind {
  LvCarrier get carrier => isFloat ? LvCarrier.float : LvCarrier.integer;
}

final Set<String> kLvReservedTypeNames = {
  ...kLvRuntimeDeclaredTypes,
  LvRuntimeType.anonymousEnum,
  for (final kind in LvNumericKind.values) kind.typedListType,
  'BigInt',
  'Function',
  'Iterable',
  'List',
  'Map',
  'Never',
  'Null',
  'Object',
  'Record',
  'Set',
  'String',
  'Type',
};

const Set<String> kLvRuntimeDeclaredTypes = {
  LvRuntimeType.error,
  LvRuntimeType.path,
  LvRuntimeType.refnum,
  LvRuntimeType.variant,
  LvRuntimeType.arrayNd,
};

bool lvTypeNeedsRuntime(LvTypeMapping type) => type._namesRuntimeType || (type.carrier?.runtime ?? false);

bool lvTypeNeedsTypedData(LvTypeMapping type) => type._namesTypedData;

enum LvMapStatus { mapped, internal, unmapped }

const Map<int, String> kInternalTypeCodes = {
  TypeCode.function: 'connector-pane signature, not a value',
  TypeCode.polyVi: 'polymorphic-VI reference, not a value',
  TypeCode.block: 'data-space storage block',
  TypeCode.typeBlock: 'data-space storage block',
  TypeCode.voidBlock: 'data-space storage block',
  TypeCode.alignedBlock: 'data-space storage block',
  TypeCode.repeatedBlock: 'data-space storage block',
  TypeCode.alignmentMarker: 'data-space alignment marker',
  TypeCode.ptr: 'reference that flattens to zero bytes',
  TypeCode.ptrTo: 'pointer-to-type, a Call Library parameter mode',
  TypeCode.arrayDataPointer: 'array-data pointer, a Call Library parameter mode',
};

const Map<int, String> kUnmappedTypeCodes = {
  TypeCode.ext: 'x87 80-bit extended float; Dart has no wider-than-binary64 float, so any mapping loses precision',
  TypeCode.complexSgl: 'complex pair; no Dart complex type and no decided (re, im) representation',
  TypeCode.complexDbl: 'complex pair; no Dart complex type and no decided (re, im) representation',
  TypeCode.complexExt: 'complex pair of 80-bit extended floats',
  TypeCode.fixedPoint: 'fixed-point numeric; the descriptor\'s word length / integer word length are not decoded',
  TypeCode.complexFixedPoint: 'complex fixed-point numeric; the descriptor\'s scaling is not decoded',
  TypeCode.picture: 'LabVIEW picture (a draw-op list); the op stream is not decoded',
  TypeCode.tag: 'tag type; the fixed record after its sentinel is not decoded',
  TypeCode.subString: 'substring view; whether it carries an offset/length into another string is not decoded',
  TypeCode.subArray: 'sub-array view; its interior is a dim count and element index with no bounds, not decoded',
  TypeCode.measureData: 'waveform / timestamp / digital-waveform; the subkind word is decoded but its layout is not',
  TypeCode.unitSgl: 'physical-unit float; the unit exponent vector is not decoded',
  TypeCode.unitDbl: 'physical-unit float; the unit exponent vector is not decoded',
  TypeCode.unitExt: 'physical-unit extended float; the unit exponent vector is not decoded',
  TypeCode.unitComplexSgl: 'physical-unit complex float; the unit exponent vector is not decoded',
  TypeCode.unitComplexDbl: 'physical-unit complex float; the unit exponent vector is not decoded',
  TypeCode.unitComplexExt: 'physical-unit complex float; the unit exponent vector is not decoded',
  0x73: 'uncatalogued type code adjacent to refnum (0x70); its descriptor interior is not decoded',
  0x74: 'uncatalogued type code adjacent to refnum (0x70); its descriptor interior is not decoded',
};

const String kRefnumSubtypeNote = 'refnum reference class is not decoded; all refnums share one opaque handle';

const Set<int> kStructuralTypeCodes = {
  TypeCode.voidType,
  TypeCode.boolean,
  TypeCode.booleanU16,
  TypeCode.string,
  TypeCode.cString,
  TypeCode.pascalString,
  TypeCode.path,
  TypeCode.variant,
  TypeCode.refnum,
  TypeCode.enumU8,
  TypeCode.enumU16,
  TypeCode.enumU32,
  TypeCode.array,
  TypeCode.cluster,
  TypeCode.typeDef,
};

bool lvTypeCodeIsAccountedFor(int code) =>
    LvNumericKind.ofCode(code) != null ||
    kStructuralTypeCodes.contains(code) ||
    kInternalTypeCodes.containsKey(code) ||
    kUnmappedTypeCodes.containsKey(code);

class LvDeclField {
  const LvDeclField({required this.label, required this.type});

  final String? label;

  final LvTypeMapping type;
}

class LvTypeDecl {
  const LvTypeDecl.cluster({required this.name, required this.label, required this.fields})
    : items = const [],
      isEnum = false;

  const LvTypeDecl.enumeration({required this.name, required this.label, required this.items})
    : fields = const [],
      isEnum = true;

  final String name;

  final String? label;

  final List<LvDeclField> fields;

  final List<String> items;

  final bool isEnum;

  String? get undeclarable => isEnum && items.isEmpty
      ? 'the enum descriptor\'s item labels did not decode, so its Dart enum would have no members'
      : null;

  Iterable<LvTypeDecl> get dependencies sync* {
    for (final field in fields) {
      yield* field.type.declarations;
    }
  }
}

class LvDeclarations {
  final Map<String, LvTypeDecl> _bySignature = <String, LvTypeDecl>{};
  final Set<String> _taken = <String>{};

  Iterable<LvTypeDecl> get all => _bySignature.values;

  LvTypeDecl allocate(String preferred, String signature, LvTypeDecl Function(String name) build) {
    if (_bySignature[signature] case final existing?) return existing;
    var name = preferred;
    for (var index = 2; kLvReservedTypeNames.contains(name) || _taken.contains(name); index++) {
      name = '$preferred$index';
    }
    _taken.add(name);
    return _bySignature[signature] = build(name);
  }
}

class LvTypeMapping {
  const LvTypeMapping.mapped(LvCarrier this.carrier, {this.numeric, this.note})
    : status = LvMapStatus.mapped,
      _source = null,
      _namesRuntimeType = false,
      _namesTypedData = false,
      unmappedCode = null,
      declarations = const [];

  LvTypeMapping.compound(
    String this._source, {
    required bool namesRuntimeType,
    required bool namesTypedData,
    this.note,
    this.declarations = const [],
  }) : status = LvMapStatus.mapped,
       carrier = LvCarrier.compound,
       numeric = null,
       _namesRuntimeType = namesRuntimeType,
       _namesTypedData = namesTypedData,
       unmappedCode = null;

  LvTypeMapping.array(LvTypeMapping element, int dimCount)
    : this.compound(
        lvArrayDartType(element, dimCount),
        namesRuntimeType: dimCount > 1 || lvTypeNeedsRuntime(element),
        namesTypedData: element.numeric != null || lvTypeNeedsTypedData(element),
        declarations: element.declarations,
      );

  LvTypeMapping.nominal(LvTypeDecl declaration, {this.note})
    : status = LvMapStatus.mapped,
      carrier = LvCarrier.nominal,
      _source = declaration.name,
      _namesRuntimeType = false,
      _namesTypedData = false,
      numeric = null,
      unmappedCode = null,
      declarations = [declaration];

  const LvTypeMapping.internal(this.note)
    : status = LvMapStatus.internal,
      carrier = null,
      _source = null,
      _namesRuntimeType = false,
      _namesTypedData = false,
      numeric = null,
      unmappedCode = null,
      declarations = const [];

  const LvTypeMapping.unmapped(this.note, {this.unmappedCode})
    : status = LvMapStatus.unmapped,
      carrier = null,
      _source = null,
      _namesRuntimeType = false,
      _namesTypedData = false,
      numeric = null,
      declarations = const [];

  final LvMapStatus status;

  final LvCarrier? carrier;

  final String? _source;

  final bool _namesRuntimeType;

  final bool _namesTypedData;

  String? get dartType => _source ?? carrier?.dartType;

  final LvNumericKind? numeric;

  final String? note;

  final List<LvTypeDecl> declarations;

  final int? unmappedCode;

  bool get isMapped => status == LvMapStatus.mapped;
}

LvTypeMapping mapLvType(ViType type, List<ViType> pool, [int depth = 0, LvDeclarations? declarations]) {
  if (depth > 16) return const LvTypeMapping.unmapped('type nesting deeper than 16 levels');
  if (kInternalTypeCodes[type.code] case final why?) return LvTypeMapping.internal(why);
  if (kUnmappedTypeCodes[type.code] case final why?) return LvTypeMapping.unmapped(why, unmappedCode: type.code);
  if (LvNumericKind.ofCode(type.code) case final kind?) {
    return LvTypeMapping.mapped(kind.carrier, numeric: kind);
  }
  switch (type.code) {
    case TypeCode.voidType:
      return const LvTypeMapping.mapped(LvCarrier.voidValue);
    case TypeCode.boolean:
    case TypeCode.booleanU16:
      return const LvTypeMapping.mapped(LvCarrier.boolean);
    case TypeCode.string:
    case TypeCode.cString:
    case TypeCode.pascalString:
      return const LvTypeMapping.mapped(LvCarrier.text, note: kStringEncodingNote);
    case TypeCode.path:
      return const LvTypeMapping.mapped(LvCarrier.path);
    case TypeCode.variant:
      return const LvTypeMapping.mapped(LvCarrier.variant, note: 'variant payloads are not decoded');
    case TypeCode.refnum:
      return const LvTypeMapping.mapped(LvCarrier.refnum, note: kRefnumSubtypeNote);
    case TypeCode.enumU8:
    case TypeCode.enumU16:
    case TypeCode.enumU32:
      return _mapEnum(type, type.name, declarations);
    case TypeCode.array:
      return _mapArray(type, pool, depth, declarations);
    case TypeCode.cluster:
      return _mapCluster(type, type.name, pool, depth, declarations);
    case TypeCode.typeDef:
      return _mapTypeDef(type, pool, depth, declarations);
    default:
      return LvTypeMapping.unmapped(
        'type code 0x${type.code.toRadixString(16)} is not catalogued',
        unmappedCode: type.code,
      );
  }
}

const String kStringEncodingNote = 'byte string carried as Latin-1 code units';

LvTypeMapping _mapArray(ViType type, List<ViType> pool, int depth, LvDeclarations? declarations) {
  final elementIndex = type.elementIndex;
  if (elementIndex == null || elementIndex >= pool.length) {
    return const LvTypeMapping.unmapped('array element type not recovered from the descriptor');
  }
  final element = mapLvType(pool[elementIndex], pool, depth + 1, declarations);
  if (element.status == LvMapStatus.internal) {
    return LvTypeMapping.internal('array of a non-value element: ${element.note}');
  }
  if (!element.isMapped) {
    return LvTypeMapping.unmapped('array element is unmapped: ${element.note}', unmappedCode: element.unmappedCode);
  }
  return LvTypeMapping.array(element, type.dimCount ?? 1);
}

String lvArrayDartType(LvTypeMapping element, int dimCount) {
  final storage = element.numeric?.typedListType ?? 'List<${element.dartType}>';
  return dimCount <= 1 ? storage : '${LvRuntimeType.arrayNd}<$storage>';
}

String lvArrayBuilderType(LvTypeMapping element) => 'List<${element.dartType}>';

String lvArrayFreeze(LvTypeMapping element, String builder) =>
    element.numeric == null ? builder : '${element.numeric!.typedListType}.fromList($builder)';

LvTypeMapping _mapCluster(ViType type, String? label, List<ViType> pool, int depth, LvDeclarations? declarations) {
  if (isLvErrorCluster(type, pool)) return const LvTypeMapping.mapped(LvCarrier.error);
  final members = clusterFields(type, pool);
  if (members.length != type.members.length) {
    return const LvTypeMapping.unmapped('cluster member indices did not resolve against the pool');
  }
  final mapped = <LvTypeMapping>[];
  for (final member in members) {
    final field = mapLvType(member, pool, depth + 1, declarations);
    if (field.status == LvMapStatus.internal) {
      return LvTypeMapping.internal('cluster holding a non-value member: ${field.note}');
    }
    if (!field.isMapped) {
      return LvTypeMapping.unmapped('cluster member is unmapped: ${field.note}', unmappedCode: field.unmappedCode);
    }
    mapped.add(field);
  }
  if (label != null && lvClassName(label).isNotEmpty) {
    final className = lvClassName(label);
    final fields = [
      for (var index = 0; index < members.length; index++) LvDeclField(label: members[index].name, type: mapped[index]),
    ];
    final signature =
        'C:$className|${[for (final field in fields) '${field.label ?? ''}:${field.type.dartType}'].join(',')}';
    return LvTypeMapping.nominal(
      (declarations ?? LvDeclarations()).allocate(
        className,
        signature,
        (name) => LvTypeDecl.cluster(name: name, label: label, fields: fields),
      ),
    );
  }
  return LvTypeMapping.compound(
    lvRecordType(members, mapped),
    namesRuntimeType: mapped.any(lvTypeNeedsRuntime),
    namesTypedData: mapped.any(lvTypeNeedsTypedData),
    declarations: [for (final field in mapped) ...field.declarations],
  );
}

LvTypeMapping _mapEnum(ViType type, String? label, LvDeclarations? declarations) {
  final stem = label == null ? '' : lvClassName(label);
  final className = stem.isEmpty ? LvRuntimeType.anonymousEnum : stem;
  final signature = 'E:$className|${type.enumItems.join('\u0000')}';
  return LvTypeMapping.nominal(
    (declarations ?? LvDeclarations()).allocate(
      className,
      signature,
      (name) => LvTypeDecl.enumeration(name: name, label: label, items: type.enumItems),
    ),
    note: type.enumItems.isEmpty ? 'enum item labels not recovered, so the enum has no members to declare' : null,
  );
}

String lvRecordType(List<ViType> members, List<LvTypeMapping> mapped) {
  final names = [for (final member in members) lvFieldName(member.name ?? '')];
  final named = names.every((n) => n.isNotEmpty) && names.toSet().length == names.length;
  if (!named) return '(${[for (final field in mapped) field.dartType!].join(', ')})';
  return '({${[for (var i = 0; i < mapped.length; i++) '${mapped[i].dartType} ${names[i]}'].join(', ')}})';
}

LvTypeMapping _mapTypeDef(ViType type, List<ViType> pool, int depth, LvDeclarations? declarations) {
  final base = type.typedefBase;
  if (base == null) return const LvTypeMapping.unmapped('typedef base descriptor did not frame');
  final name = type.name;
  if (name != null && lvClassName(name).isNotEmpty) {
    if (base.kind == ViDataType.cluster) return _mapCluster(base, name, pool, depth + 1, declarations);
    if (base.enumItems.isNotEmpty || _isEnumCode(base.code)) return _mapEnum(base, name, declarations);
  }
  final mapped = mapLvType(base, pool, depth + 1, declarations);
  if (mapped.status == LvMapStatus.internal) return LvTypeMapping.internal('typedef over a non-value: ${mapped.note}');
  if (!mapped.isMapped) {
    return LvTypeMapping.unmapped('typedef base is unmapped: ${mapped.note}', unmappedCode: mapped.unmappedCode);
  }
  return mapped;
}

bool _isEnumCode(int code) => code == TypeCode.enumU8 || code == TypeCode.enumU16 || code == TypeCode.enumU32;

bool isLvErrorCluster(ViType type, List<ViType> pool) {
  if (type.members.length != 3) return false;
  final members = clusterFields(type, pool);
  if (members.length != 3) return false;
  const shape = [
    [TypeCode.boolean],
    [TypeCode.i32, TypeCode.u32],
    [TypeCode.string],
  ];
  const names = ['status', 'code', 'source'];
  for (var i = 0; i < 3; i++) {
    if (!shape[i].contains(members[i].code)) return false;
    if (members[i].name?.toLowerCase() != names[i]) return false;
  }
  return true;
}

String lvClassName(String raw) {
  final words = raw.split(RegExp(r'[^A-Za-z0-9]+')).where((w) => w.isNotEmpty);
  final joined = words.map((w) => w[0].toUpperCase() + (w.length == 1 ? '' : w.substring(1).toLowerCase())).join();
  if (joined.isEmpty) return '';
  return _startsWithDigit(joined) ? 'Lv$joined' : joined;
}

String lvFieldName(String raw) {
  final name = lvClassName(raw);
  if (name.isEmpty) return '';
  final lower = name[0].toLowerCase() + name.substring(1);
  return kLvDartReservedWords.contains(lower) ? '\$$lower' : lower;
}

bool _startsWithDigit(String s) => s.codeUnitAt(0) >= 0x30 && s.codeUnitAt(0) <= 0x39;

const Set<String> kLvDartReservedWords = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum', 'extends', //
  'false', 'final', 'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super', 'switch',
  'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};
