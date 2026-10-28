import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'format_string.dart';
import 'naming.dart';
import 'numeric.dart';
import 'type_map.dart';

/// The refnum kinds whose flattened value is a bare `u32` reference number.
const Set<ViRefnumKind> kLvFlatU32RefnumKinds = {
  ViRefnumKind.generic,
  ViRefnumKind.dataLog,
  ViRefnumKind.byteStream,
  ViRefnumKind.device,
  ViRefnumKind.occurrence,
  ViRefnumKind.tcpConnection,
  ViRefnumKind.autoRef,
  ViRefnumKind.lvObjectControl,
  ViRefnumKind.menu,
  ViRefnumKind.dataSocket,
  ViRefnumKind.udpConnection,
  ViRefnumKind.notifier,
  ViRefnumKind.queue,
  ViRefnumKind.irdaConnection,
  ViRefnumKind.userDefined,
  ViRefnumKind.eventRegistration,
  ViRefnumKind.dotNet,
  ViRefnumKind.userEvent,
  ViRefnumKind.callback,
  ViRefnumKind.bluetoothConnection,
  ViRefnumKind.dataValueReference,
  ViRefnumKind.fifo,
  ViRefnumKind.tdmsFile,
};

/// The default object of the class [declaration] declares, every level of its lineage holding
/// the default its private data control saves, or each member's type default ([defaultOf]) where
/// it saves none; null when a level's default does not decode.
String? lvClassDefaultLiteral(LvTypeDecl declaration, String? Function(LvTypeMapping mapping)? defaultOf) {
  final values = <String>[];
  for (final level in declaration.lineage) {
    final saved = level.classDefault;
    if (saved == null || saved.why != null) return null;
    if (saved.members case final members?) {
      values.addAll(members);
      continue;
    }
    for (final field in level.fields) {
      final value = defaultOf?.call(field.type);
      if (value == null) return null;
      values.add(value);
    }
  }
  final names = declaration.allFieldNames;
  return '${declaration.name}(${[for (var i = 0; i < values.length; i++) '${names[i]}: ${values[i]}'].join(', ')})';
}

/// The `u16` version words a flattened class object carries per level of its lineage.
const int kLvClassVersionWords = 4;

/// The bytes of a flattened LabVIEW timestamp: an `i64` of seconds, then a `u64` fraction.
const int kLvFlatTimestampBytes = 16;

/// The Dart literal of a value flattened by its [descriptor] (the default data space's grammar,
/// big-endian), spelled as [mapping], the Dart type [mapLvType] gives the descriptor; or why it
/// is not decoded. The whole of [bytes] must be the value, or the value and one trailing zero
/// byte, the pad a heap blob carries after some values.
({String? literal, String? why}) lvFlatLiteral(
  Uint8List bytes,
  ViType descriptor,
  List<ViType> pool,
  LvTypeMapping mapping,
  LvDeclarations declarations, {
  String? Function(LvTypeMapping mapping)? defaultOf,
}) {
  final reader = _FlatReader(bytes, pool, declarations, defaultOf);
  final String literal;
  try {
    literal = reader.value(descriptor, mapping, 0);
  } on _Undecoded catch (undecoded) {
    return (literal: null, why: undecoded.why);
  }
  final rest = bytes.length - reader.at;
  if (rest == 0 || (rest == 1 && bytes.last == 0)) return (literal: literal, why: null);
  return (literal: null, why: 'the flattened value ends $rest bytes before the saved bytes do');
}

/// The literal of each member of a cluster flattened by [cluster] in [bytes], spelled as
/// [fields]; or why they are not decoded.
({List<String>? literals, String? why}) lvFlatClusterMembers(
  Uint8List bytes,
  ViType cluster,
  List<ViType> pool,
  List<LvDeclField> fields,
  LvDeclarations declarations,
) {
  final reader = _FlatReader(bytes, pool, declarations);
  final List<String> literals;
  try {
    final type = lvThroughTypedefs(cluster);
    if (type is! ViClusterType) return (literals: null, why: 'the private data is not a cluster');
    final members = clusterFields(type, pool);
    if (members.length != fields.length) return (literals: null, why: 'the members and their mapping disagree');
    literals = [for (var i = 0; i < members.length; i++) reader.value(members[i], fields[i].type, 1)];
  } on _Undecoded catch (undecoded) {
    return (literals: null, why: undecoded.why);
  }
  final rest = bytes.length - reader.at;
  if (rest == 0 || (rest == 1 && bytes.last == 0)) return (literals: literals, why: null);
  return (literals: null, why: 'the flattened value ends $rest bytes before the saved bytes do');
}

class _Undecoded implements Exception {
  const _Undecoded(this.why);

  final String why;
}

class _FlatReader {
  _FlatReader(this.bytes, this.pool, this.declarations, [this.defaultOf]) : view = ByteData.sublistView(bytes);

  /// The default value's literal of a mapping, for the members of a default class object.
  final String? Function(LvTypeMapping mapping)? defaultOf;

  final LvDeclarations declarations;

  final Uint8List bytes;

  final ByteData view;

  final List<ViType> pool;

  int at = 0;

  Never _refuse(String why) => throw _Undecoded(why);

  void _need(int count) {
    if (at + count > bytes.length) _refuse('the saved bytes end inside the flattened value');
  }

  int _unsigned(int width) {
    _need(width);
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = (value << 8) | bytes[at + i];
    }
    at += width;
    return value;
  }

  String value(ViType descriptor, LvTypeMapping mapping, int depth) {
    if (depth > 16) _refuse('the descriptor nests deeper than 16 levels');
    final type = lvThroughTypedefs(descriptor);
    if (type == null) _refuse('the typedef base did not frame');
    if (mapping.carrier == LvCarrier.error) return _error(type, depth);
    if (mapping.enumeration case final enumeration?) {
      if (type is! ViEnumType) _refuse('an enum mapping over a ${type.kind.name} descriptor');
      final ordinal = _unsigned(type.width);
      if (ordinal >= enumeration.items.length) _refuse('enum ordinal $ordinal is past the enum\'s items');
      return '${enumeration.name}.${LvNaming.declarationItems(enumeration.items)[ordinal]}';
    }
    if (mapping.numeric case final kind?) return _number(kind);
    switch (mapping.carrier) {
      case LvCarrier.boolean:
        final width = type is ViBooleanType ? type.width : 1;
        final flag = _unsigned(width);
        if (flag > 1) _refuse('a boolean flattened as $flag');
        return flag == 1 ? 'true' : 'false';
      case LvCarrier.text:
        final length = _unsigned(4);
        _need(length);
        final text = String.fromCharCodes(bytes, at, at + length);
        at += length;
        return lvDartStringLiteral(text);
      case LvCarrier.refnum:
        if (type is! ViRefnumType || !kLvFlatU32RefnumKinds.contains(type.refnumKind)) {
          _refuse('a refnum of this reference kind does not flatten as a reference number');
        }
        final id = _unsigned(4);
        if (id != 0) _refuse('reference number $id names a reference no lowered program holds');
        return LvRuntimeType.notARefnum;
      case LvCarrier.timestamp:
        _need(kLvFlatTimestampBytes);
        final seconds = view.getInt64(at), fraction = view.getUint64(at + 8);
        at += kLvFlatTimestampBytes;
        return '${LvRuntimeType.timestamp}(seconds: $seconds, fraction: $fraction)';
      case LvCarrier.nominal:
        final declaration = mapping.declarations.single;
        if (declaration.isClassObject) return _classObject(declaration);
        return _cluster(type, declaration.fields, declaration.fieldNames, declaration.name, depth);
      case LvCarrier.compound:
        if (type is ViArrayType) return _array(type, mapping, depth);
        if (mapping.fields.isEmpty) _refuse('${mapping.dartType} has no decoded flattened form');
        final names = [for (final field in mapping.fields) lvFieldName(field.label ?? '')];
        final named = names.every((name) => name.isNotEmpty) && names.toSet().length == names.length;
        return _cluster(type, mapping.fields, named ? names : null, null, depth);
      case LvCarrier.path:
      case LvCarrier.variant:
      case LvCarrier.voidValue:
      case LvCarrier.integer:
      case LvCarrier.float:
      case LvCarrier.error:
      case null:
        _refuse('a ${mapping.dartType} value\'s flattened form is not decoded');
    }
  }

  /// A class object: `u32` levels, zero for the declared class's default object; else the
  /// object's class as a counted, zero-terminated list of Pascal strings padded to four bytes,
  /// four `u16` version words per level and, unless the one level's version is zero, each
  /// level's private data.
  String _classObject(LvTypeDecl declaration) {
    final start = at;
    final levels = _unsigned(4);
    if (levels != 0) {
      if (levels != 1) _refuse('a class object flattened with $levels levels of private data is not decoded');
      final length = _unsigned(1);
      _need(length);
      final names = <String>[];
      var cursor = at;
      final end = at + length;
      while (cursor < end) {
        final part = bytes[cursor];
        if (part == 0 || cursor + 1 + part > end) {
          cursor++;
          continue;
        }
        names.add(String.fromCharCodes(bytes, cursor + 1, cursor + 1 + part));
        cursor += 1 + part;
      }
      at = end;
      at += (4 - (at - start) % 4) % 4;
      final versions = [for (var i = 0; i < kLvClassVersionWords; i++) _unsigned(2)];
      if (versions.any((word) => word != 0)) {
        _refuse('a class object that saves its own private data is not decoded');
      }
      if (names.join(':') != declaration.qualifiedName.join(':')) {
        _refuse('a ${names.join(':')} object held where ${declaration.qualifiedName.join(':')} is declared');
      }
    }
    final object = lvClassDefaultLiteral(declaration, defaultOf);
    if (object == null) _refuse('the default object of ${declaration.name} is not decoded');
    return object;
  }

  String _number(LvNumericKind kind) {
    if (kind.isFloat) {
      final width = kind == LvNumericKind.sgl ? 4 : 8;
      _need(width);
      final value = width == 4 ? view.getFloat32(at) : view.getFloat64(at);
      at += width;
      if (!value.isFinite) _refuse('a non-finite float has no Dart literal');
      final text = value.toString();
      return text.contains('.') || text.contains('e') ? text : '$text.0';
    }
    final width = kind.bits ~/ 8;
    _need(width);
    final value = switch (width) {
      1 => kind.signed ? view.getInt8(at) : view.getUint8(at),
      2 => kind.signed ? view.getInt16(at) : view.getUint16(at),
      4 => kind.signed ? view.getInt32(at) : view.getUint32(at),
      _ => view.getInt64(at),
    };
    at += width;
    return '$value';
  }

  String _error(ViType type, int depth) {
    if (type is! ViClusterType) _refuse('an error mapping over a ${type.kind.name} descriptor');
    final members = clusterFields(type, pool);
    final status = value(members[0], const LvTypeMapping.mapped(LvCarrier.boolean), depth + 1);
    final code = value(members[1], mapLvType(members[1], pool, 0, declarations), depth + 1);
    final source = value(members[2], const LvTypeMapping.mapped(LvCarrier.text), depth + 1);
    return '${LvRuntimeType.error}(status: $status, code: $code, source: $source)';
  }

  String _cluster(ViType type, List<LvDeclField> fields, List<String>? names, String? className, int depth) {
    if (type is! ViClusterType) _refuse('a cluster mapping over a ${type.kind.name} descriptor');
    final members = clusterFields(type, pool);
    if (members.length != fields.length) _refuse('the cluster descriptor and its mapping disagree on members');
    final values = [for (var i = 0; i < members.length; i++) value(members[i], fields[i].type, depth + 1)];
    final arguments = names == null
        ? values.join(', ')
        : [for (var i = 0; i < values.length; i++) '${names[i]}: ${values[i]}'].join(', ');
    if (className != null) return '$className($arguments)';
    return values.length == 1 && names == null ? '($arguments,)' : '($arguments)';
  }

  String _array(ViArrayType type, LvTypeMapping mapping, int depth) {
    if (type.dimCount != 1) _refuse('a ${type.dimCount}-D array constant\'s flattened form is not spelled');
    if (type.elementIndex >= pool.length) _refuse('the array element did not resolve against the pool');
    final elementType = pool[type.elementIndex];
    final element = mapLvType(elementType, pool, depth + 1, declarations);
    if (!element.isMapped) _refuse('the array element is unmapped: ${element.note}');
    final count = _unsigned(4);
    if (count > bytes.length - at) _refuse('an array of $count elements cannot fit the saved bytes');
    final values = [for (var i = 0; i < count; i++) value(elementType, element, depth + 1)];
    final storage = lvArrayDartType(element, 1);
    if (element.numeric case final kind?) {
      if (values.isEmpty) return '$storage(0)';
      return '$storage.fromList(<${kind.isFloat ? 'double' : 'int'}>[${values.join(', ')}])';
    }
    return '<${element.dartType}>[${values.join(', ')}]';
  }
}
