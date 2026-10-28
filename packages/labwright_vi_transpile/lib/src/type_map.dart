import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'class_index.dart';
import 'naming.dart';
import 'numeric.dart';

abstract final class LvRuntimeType {
  static const String error = 'LvError';

  static const String clearedError = '$error.none';

  static const String path = 'LvPath';

  static const String refnum = 'LvRefnum';

  static const String notARefnum = '$refnum.none';

  static const String variant = 'LvVariant';

  static const String timestamp = 'LvTimestamp';

  static const String timestampEpoch = '$timestamp.epoch';

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
  timestamp(LvRuntimeType.timestamp, runtime: true),
  nominal(null),
  compound(null);

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
  TypeCode.measureData: 'waveform / digital-waveform; the subkind word is decoded but its layout is not',
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
  const LvTypeDecl.cluster({
    required this.name,
    required this.label,
    required this.fields,
    this.qualifiedName = const [],
    this.parent,
  }) : items = const [],
       isEnum = false;

  const LvTypeDecl.enumeration({
    required this.name,
    required this.label,
    required this.items,
    this.qualifiedName = const [],
  }) : fields = const [],
       isEnum = true,
       parent = null;

  final String name;

  /// The class this one extends: a LabVIEW class object's parent class, whose fields the
  /// object carries before its own; null for every other declaration.
  final LvTypeDecl? parent;

  /// This declaration and its ancestors, root first.
  List<LvTypeDecl> get lineage => [...?parent?.lineage, this];

  /// Whether this declares [ancestor] or a class descending from it.
  bool descendsFrom(LvTypeDecl ancestor) => lineage.any((declaration) => identical(declaration, ancestor));

  /// Every field an instance carries: the ancestors' first, then [fields].
  List<LvDeclField> get allFields => [for (final declaration in lineage) ...declaration.fields];

  /// The Dart name of each of [allFields], distinct across the whole lineage.
  List<String> get allFieldNames => LvNaming.declarationFields([for (final field in allFields) field.label]);

  /// The Dart names of [fields], the last of [allFieldNames].
  List<String> get fieldNames => allFieldNames.sublist(allFields.length - fields.length);

  final String? label;

  /// The typedef control this declares, `Lib.lvlib`, `Class.lvclass`, `Name.ctl`; empty for a
  /// type declared from a cluster or enum label.
  final List<String> qualifiedName;

  /// The name the declaration asks for before the registry disambiguates it.
  String get preferredName => qualifiedName.isNotEmpty
      ? lvClassName(qualifiedName.last.replaceAll(RegExp(r'\.\w+$'), ''))
      : label == null
      ? LvRuntimeType.anonymousEnum
      : lvClassName(label!);

  final List<LvDeclField> fields;

  final List<String> items;

  final bool isEnum;

  String? get undeclarable => isEnum && items.isEmpty
      ? 'the enum descriptor\'s item labels did not decode, so its Dart enum would have no members'
      : null;

  Iterable<LvTypeDecl> get dependencies sync* {
    if (parent case final parent?) yield parent;
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
      declarations = const [],
      fields = const [];

  LvTypeMapping.compound(
    String this._source, {
    required bool namesRuntimeType,
    required bool namesTypedData,
    this.note,
    this.declarations = const [],
    this.fields = const [],
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
      declarations = [declaration],
      fields = const [];

  const LvTypeMapping.internal(this.note)
    : status = LvMapStatus.internal,
      carrier = null,
      _source = null,
      _namesRuntimeType = false,
      _namesTypedData = false,
      numeric = null,
      unmappedCode = null,
      declarations = const [],
      fields = const [];

  const LvTypeMapping.unmapped(this.note, {this.unmappedCode})
    : status = LvMapStatus.unmapped,
      carrier = null,
      _source = null,
      _namesRuntimeType = false,
      _namesTypedData = false,
      numeric = null,
      declarations = const [],
      fields = const [];

  final LvMapStatus status;

  final LvCarrier? carrier;

  final String? _source;

  final bool _namesRuntimeType;

  final bool _namesTypedData;

  String? get dartType => _source ?? carrier?.dartType;

  final LvNumericKind? numeric;

  final String? note;

  final List<LvTypeDecl> declarations;

  /// The members of an anonymous cluster carried as a record, in order; empty for any other
  /// mapping.
  final List<LvDeclField> fields;

  final int? unmappedCode;

  bool get isMapped => status == LvMapStatus.mapped;

  /// The Dart enum this mapping names, when it is one.
  LvTypeDecl? get enumeration => switch (declarations) {
    [final declaration] when carrier == LvCarrier.nominal && declaration.isEnum => declaration,
    _ => null,
  };
}

LvTypeMapping mapLvType(ViType type, List<ViType> pool, [int depth = 0, LvDeclarations? declarations]) {
  if (depth > 16) return const LvTypeMapping.unmapped('type nesting deeper than 16 levels');
  if (kInternalTypeCodes[type.code] case final why?) return LvTypeMapping.internal(why);
  if (type is ViMeasureDataType && type.flavor == ViMeasureDataFlavor.timeStamp) {
    return const LvTypeMapping.mapped(LvCarrier.timestamp);
  }
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
      return _mapEnum(type, type.label, declarations);
    case TypeCode.array:
      return _mapArray(type, pool, depth, declarations);
    case TypeCode.cluster:
      return _mapCluster(type, type.label, pool, depth, declarations);
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
  if (type is! ViArrayType || type.elementIndex >= pool.length) {
    return const LvTypeMapping.unmapped('array element type not recovered from the descriptor');
  }
  final element = mapLvType(pool[type.elementIndex], pool, depth + 1, declarations);
  if (element.status == LvMapStatus.internal) {
    return LvTypeMapping.internal('array of a non-value element: ${element.note}');
  }
  if (!element.isMapped) {
    return LvTypeMapping.unmapped('array element is unmapped: ${element.note}', unmappedCode: element.unmappedCode);
  }
  return LvTypeMapping.array(element, type.dimCount);
}

String lvArrayDartType(LvTypeMapping element, int dimCount) {
  final storage = element.numeric?.typedListType ?? 'List<${element.dartType}>';
  return dimCount <= 1 ? storage : '${LvRuntimeType.arrayNd}<$storage>';
}

String lvArrayBuilderType(LvTypeMapping element) => 'List<${element.dartType}>';

String lvArrayFreeze(LvTypeMapping element, String builder) =>
    element.numeric == null ? builder : '${element.numeric!.typedListType}.fromList($builder)';

/// A cluster's members and their mappings, or the mapping that refuses the cluster.
({List<ViType> members, List<LvTypeMapping> mapped, LvTypeMapping? refusal}) _clusterMembers(
  ViType type,
  List<ViType> pool,
  int depth,
  LvDeclarations? declarations,
) {
  final members = clusterFields(type, pool);
  if (type is! ViClusterType || members.length != type.memberCount) {
    return (
      members: members,
      mapped: const [],
      refusal: const LvTypeMapping.unmapped('cluster member indices did not resolve against the pool'),
    );
  }
  final mapped = <LvTypeMapping>[];
  for (final member in members) {
    final field = mapLvType(member, pool, depth + 1, declarations);
    if (field.status == LvMapStatus.internal) {
      return (
        members: members,
        mapped: mapped,
        refusal: LvTypeMapping.internal('cluster holding a non-value member: ${field.note}'),
      );
    }
    if (!field.isMapped) {
      return (
        members: members,
        mapped: mapped,
        refusal: LvTypeMapping.unmapped('cluster member is unmapped: ${field.note}', unmappedCode: field.unmappedCode),
      );
    }
    mapped.add(field);
  }
  return (members: members, mapped: mapped, refusal: null);
}

LvTypeMapping _mapCluster(ViType type, String? label, List<ViType> pool, int depth, LvDeclarations? declarations) {
  if (isLvErrorCluster(type, pool)) return const LvTypeMapping.mapped(LvCarrier.error);
  final (:members, :mapped, :refusal) = _clusterMembers(type, pool, depth, declarations);
  if (refusal != null) return refusal;
  if (label != null && lvClassName(label).isNotEmpty) {
    final className = lvClassName(label);
    final fields = [
      for (var i = 0; i < members.length; i++) LvDeclField(label: members[i].label, type: mapped[i]),
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
    fields: [for (var i = 0; i < members.length; i++) LvDeclField(label: members[i].label, type: mapped[i])],
  );
}

LvTypeMapping _mapEnum(ViType type, String? label, LvDeclarations? declarations) {
  final items = type is ViEnumType ? type.items : const <String>[];
  final stem = label == null ? '' : lvClassName(label);
  final className = stem.isEmpty ? LvRuntimeType.anonymousEnum : stem;
  final signature = 'E:$className|${items.join('\u0000')}';
  return LvTypeMapping.nominal(
    (declarations ?? LvDeclarations()).allocate(
      className,
      signature,
      (name) => LvTypeDecl.enumeration(name: name, label: label, items: items),
    ),
    note: items.isEmpty ? 'enum item labels not recovered, so the enum has no members to declare' : null,
  );
}

String lvRecordType(List<ViType> members, List<LvTypeMapping> mapped) {
  final names = [for (final member in members) lvFieldName(member.label ?? '')];
  final named = names.every((name) => name.isNotEmpty) && names.toSet().length == names.length;
  if (!named) return '(${[for (final field in mapped) field.dartType!].join(', ')})';
  return '({${[for (var i = 0; i < mapped.length; i++) '${mapped[i].dartType} ${names[i]}'].join(', ')}})';
}

LvTypeMapping _mapTypeDef(ViType type, List<ViType> pool, int depth, LvDeclarations? declarations) {
  if (type is! ViTypedefType) return const LvTypeMapping.unmapped('typedef base descriptor did not frame');
  final base = type.base;
  if (type.componentCount > 0) {
    final qualified = [for (var i = 0; i < type.componentCount; i++) type.componentAt(i)];
    final stem = lvClassName(qualified.last.replaceAll(RegExp(r'\.\w+$'), ''));
    if (stem.isNotEmpty && (base.kind == ViDataType.cluster || _isEnumCode(base.code))) {
      return _mapQualifiedTypeDef(type, base, qualified, stem, pool, depth, declarations);
    }
  }
  final name = type.label;
  if (name != null && lvClassName(name).isNotEmpty) {
    if (base.kind == ViDataType.cluster) return _mapCluster(base, name, pool, depth + 1, declarations);
    if (_isEnumCode(base.code)) return _mapEnum(base, name, declarations);
  }
  final mapped = mapLvType(base, pool, depth + 1, declarations);
  if (mapped.status == LvMapStatus.internal) return LvTypeMapping.internal('typedef over a non-value: ${mapped.note}');
  if (!mapped.isMapped) {
    return LvTypeMapping.unmapped('typedef base is unmapped: ${mapped.note}', unmappedCode: mapped.unmappedCode);
  }
  return mapped;
}

/// A typedef that names its control file is one nominal type wherever its qualified name
/// appears, `Lib.lvlib`, `Class.lvclass`, `Name.ctl`, however each VI's copy labels it; the
/// first copy a library meets declares it, and a copy whose member types or items differ is a
/// stale save against another version of the control and is refused.
LvTypeMapping _mapQualifiedTypeDef(
  ViTypedefType type,
  ViType base,
  List<String> qualified,
  String stem,
  List<ViType> pool,
  int depth,
  LvDeclarations? declarations,
) {
  final signature = 'T:${qualified.join(':')}';
  final registry = declarations ?? LvDeclarations();
  final label = type.label ?? qualified.last;
  if (base.kind == ViDataType.cluster) {
    if (isLvErrorCluster(base, pool)) return const LvTypeMapping.mapped(LvCarrier.error);
    final (:members, :mapped, :refusal) = _clusterMembers(base, pool, depth + 1, declarations);
    if (refusal != null) return refusal;
    final fields = [
      for (var i = 0; i < members.length; i++) LvDeclField(label: members[i].label, type: mapped[i]),
    ];
    final declared = registry.allocate(
      stem,
      signature,
      (name) => LvTypeDecl.cluster(name: name, label: label, fields: fields, qualifiedName: qualified),
    );
    final declaredTypes = [for (final field in declared.fields) field.type.dartType];
    final copyTypes = [for (final field in fields) field.type.dartType];
    if (declaredTypes.join(',') != copyTypes.join(',')) {
      return LvTypeMapping.unmapped(
        'typedef ${qualified.join(':')} is saved here with members (${copyTypes.join(', ')}) where '
        'the library declares it with (${declaredTypes.join(', ')}), a stale copy of the control',
      );
    }
    return LvTypeMapping.nominal(declared);
  }
  final items = base is ViEnumType ? base.items : const <String>[];
  final declared = registry.allocate(
    stem,
    signature,
    (name) => LvTypeDecl.enumeration(name: name, label: label, items: items, qualifiedName: qualified),
  );
  if (declared.items.join('\u0000') != items.join('\u0000')) {
    return LvTypeMapping.unmapped(
      'typedef ${qualified.join(':')} is saved here with items (${items.join(', ')}) where the '
      'library declares it with (${declared.items.join(', ')}), a stale copy of the control',
    );
  }
  return LvTypeMapping.nominal(
    declared,
    note: items.isEmpty ? 'enum item labels not recovered, so the enum has no members to declare' : null,
  );
}

/// The root class every LabVIEW class descends from, which carries no data.
const List<String> kLvRootClassName = ['LabVIEW Object'];

/// [type] with its typedefs stripped, to [kLvTypedefDepth] levels.
ViType? lvThroughTypedefs(ViType? type) {
  for (var depth = 0; type != null && depth < kLvTypedefDepth; depth++) {
    if (type is! ViTypedefType) return type;
    type = type.base;
  }
  return null;
}

const int kLvTypedefDepth = 8;

/// The file name of a class's private data control: `X.ctl` for `X.lvclass`.
String lvPrivateDataControlName(String classFile) => classFile.replaceAll(RegExp(r'\.lvclass$'), '.ctl');

/// A LabVIEW class object as a Dart class named after the class, extending its parent's and
/// holding its own private data cluster's members, one declaration per qualified name; the root
/// class is empty. The private data is the typedef of the class file's `X.ctl` in the control
/// [LvClassData.privateData] carries, and a class [classes] does not hold is unmapped.
LvTypeMapping lvClassObjectType(List<String> qualifiedName, LvClassIndex? classes, LvDeclarations declarations) {
  final signature = 'K:${qualifiedName.join(':')}';
  final stem = lvClassName(qualifiedName.last.replaceAll(RegExp(r'\.\w+$'), ''));
  if (qualifiedName.length == 1 && qualifiedName.single == kLvRootClassName.single) {
    return LvTypeMapping.nominal(
      declarations.allocate(
        'LabViewObject',
        signature,
        (name) =>
            LvTypeDecl.cluster(name: name, label: qualifiedName.single, fields: const [], qualifiedName: qualifiedName),
      ),
    );
  }
  final data = classes?.classOf(qualifiedName);
  if (data == null) {
    return LvTypeMapping.unmapped('the class ${qualifiedName.join(':')} was not supplied to the lowering');
  }
  final parent = lvClassObjectType(data.parent.isEmpty ? kLvRootClassName : data.parent, classes, declarations);
  final parentDecl = parent.declarations.singleOrNull;
  if (parentDecl == null || !parent.isMapped) {
    return LvTypeMapping.unmapped(
      'the parent class of ${qualifiedName.join(':')} is not declared: ${parent.note}',
      unmappedCode: parent.unmappedCode,
    );
  }
  final classFile = qualifiedName.last;
  final controlName = lvPrivateDataControlName(classFile);
  final privateData = data.privateData;
  ViTypedefType? own;
  for (final type in privateData?.types ?? const <ViType>[]) {
    if (type is ViTypedefType &&
        type.componentCount >= 2 &&
        type.componentAt(type.componentCount - 2) == classFile &&
        type.componentAt(type.componentCount - 1) == controlName) {
      own = type;
      break;
    }
  }
  if (privateData == null || own == null || own.base.kind != ViDataType.cluster) {
    return LvTypeMapping.unmapped(
      'the class file of ${qualifiedName.join(':')} holds no private data cluster typedef named $controlName',
    );
  }
  final (:members, :mapped, :refusal) = _clusterMembers(own.base, privateData.types, 1, declarations);
  if (refusal != null) return refusal;
  final fields = [for (var i = 0; i < members.length; i++) LvDeclField(label: members[i].label, type: mapped[i])];
  return LvTypeMapping.nominal(
    declarations.allocate(
      stem.isEmpty ? 'LvClass' : stem,
      signature,
      (name) => LvTypeDecl.cluster(
        name: name,
        label: own!.label ?? classFile,
        fields: fields,
        qualifiedName: qualifiedName,
        parent: parentDecl,
      ),
    ),
  );
}

/// The class object a terminal's descriptor names, through typedefs, else [mapLvType] of the
/// descriptor: the type a connector-pane terminal declares.
LvTypeMapping lvTerminalType(ViType descriptor, List<ViType> pool, LvClassIndex? classes, LvDeclarations declarations) {
  final base = lvThroughTypedefs(descriptor);
  if (base is ViRefnumType && base.refnumKind == ViRefnumKind.classInstance && base.classQualifiedName.isNotEmpty) {
    return lvClassObjectType(base.classQualifiedName, classes, declarations);
  }
  return mapLvType(descriptor, pool, 0, declarations);
}

bool _isEnumCode(int code) => code == TypeCode.enumU8 || code == TypeCode.enumU16 || code == TypeCode.enumU32;

bool isLvErrorCluster(ViType type, List<ViType> pool) {
  if (type is! ViClusterType || type.memberCount != 3) return false;
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
    if (members[i].label?.toLowerCase() != names[i]) return false;
  }
  return true;
}

String lvClassName(String raw) {
  final words = raw.split(RegExp(r'[^A-Za-z0-9]+')).where((word) => word.isNotEmpty);
  final joined = words.map((word) => word[0].toUpperCase() + word.substring(1).toLowerCase()).join();
  if (joined.isEmpty) return '';
  return _startsWithDigit(joined) ? 'Lv$joined' : joined;
}

String lvFieldName(String raw) {
  final name = lvClassName(raw);
  if (name.isEmpty) return '';
  final lower = name[0].toLowerCase() + name.substring(1);
  return kLvDartReservedWords.contains(lower) ? '\$$lower' : lower;
}

bool _startsWithDigit(String text) => text.codeUnitAt(0) >= 0x30 && text.codeUnitAt(0) <= 0x39;

const Set<String> kLvDartReservedWords = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum', 'extends', //
  'false', 'final', 'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super', 'switch',
  'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};
