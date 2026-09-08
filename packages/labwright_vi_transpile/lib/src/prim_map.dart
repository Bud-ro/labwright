import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'naming.dart';
import 'numeric.dart';
import 'runtime.dart';
import 'type_map.dart';
import 'wire_type.dart';

abstract final class LvArrayTerminalRole {
  static const int array = 0x20000;

  static const int output = 0x1;

  static const int grownOutput = 0x40001;

  static const int newElement = 0x40000;

  static const int singleIndex = 0x600000;

  static const int groupFirst = 0x200000;

  static const int groupLast = 0x400000;
}

class LvPrimTerminal {
  const LvPrimTerminal({
    required this.port,
    required this.type,
    required this.roleFlags,
    required this.expression,
    this.memberName,
  });

  final int port;

  final LvWireType type;

  final int roleFlags;

  final String expression;

  final String? memberName;
}

class LvPrimCall {
  const LvPrimCall({
    required this.op,
    required this.classCode,
    required this.inputs,
    required this.outputs,
    required this.outputPorts,
    required this.portDrawnTop,
    required this.requireImport,
    required this.names,
    required this.nodeFlags,
    this.primResId,
  });

  final PrimOp? op;

  final int? primResId;

  final int classCode;

  final int? nodeFlags;

  final List<LvPrimTerminal> inputs;

  final List<LvPrimTerminal> outputs;

  final List<int> outputPorts;

  final Map<int, int> portDrawnTop;

  final void Function(String) requireImport;

  final LvNaming names;

  LvPrimTerminal? inputWithRole(int flags) => _single(inputs.where((terminal) => terminal.roleFlags == flags));

  LvPrimTerminal? outputWithRole(int flags) => _single(outputs.where((terminal) => terminal.roleFlags == flags));

  bool get hasSoleSourceTerminal => outputPorts.length == 1;

  List<LvPrimTerminal>? get inputsTopDown {
    final rows = <(int, LvPrimTerminal)>[];
    for (final terminal in inputs) {
      final top = portDrawnTop[terminal.port];
      if (top == null || rows.any((row) => row.$1 == top)) return null;
      rows.add((top, terminal));
    }
    rows.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final row in rows) row.$2];
  }

  List<int>? portsTopDown(List<int> ports) {
    final rows = <(int, int)>[];
    for (final port in ports) {
      final top = portDrawnTop[port];
      if (top == null || rows.any((row) => row.$1 == top)) return null;
      rows.add((top, port));
    }
    rows.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final row in rows) row.$2];
  }

  (LvPrimTerminal, LvPrimTerminal)? get operandsTopDown {
    if (inputs.length != 2) return null;
    final ordered = inputsTopDown;
    return ordered == null ? null : (ordered[0], ordered[1]);
  }

  (LvPrimTerminal?, LvPrimTerminal?)? get resultsTopDown {
    final ranked = _rankTopDown(outputPorts);
    return ranked == null ? null : (_terminalAt(outputs, ranked.$1), _terminalAt(outputs, ranked.$2));
  }

  (int, int)? _rankTopDown(List<int> ports) {
    if (ports.length != 2) return null;
    final first = portDrawnTop[ports[0]], second = portDrawnTop[ports[1]];
    if (first == null || second == null || first == second) return null;
    return first < second ? (ports[0], ports[1]) : (ports[1], ports[0]);
  }

  static LvPrimTerminal? _terminalAt(List<LvPrimTerminal> terminals, int port) =>
      terminals.where((terminal) => terminal.port == port).firstOrNull;

  static LvPrimTerminal? _single(Iterable<LvPrimTerminal> matches) {
    final list = matches.toList();
    return list.length == 1 ? list.single : null;
  }
}

typedef LvLowering = List<String>? Function(LvPrimCall call);

enum LvClassNameBasis { captions, terminalGrammar }

/// Block-diagram node classes the transpiler names, by heap object class code.
enum LvNodeClass {
  indexArray(0x44, 'Index Array'),
  replaceArraySubset(0xb9, 'Replace Array Subset'),
  bundle(0x34, 'Bundle'),
  unbundle(0x36, 'Unbundle'),
  buildArray(0x3a, 'Build Array'),
  concatenateStrings(0x3e, 'Concatenate Strings'),
  compoundArithmetic(0x6c, 'Compound Arithmetic'),
  scanFromString(0x92, 'Scan From String'),
  formatIntoString(0x93, 'Format Into String'),
  matchRegularExpression(0x105, 'Match Regular Expression'),
  deleteFromArray(0xbd, 'Delete From Array'),
  mergeErrors(0x172, 'Merge Errors'),
  initializeArray(0x114, 'Initialize Array', basis: LvClassNameBasis.terminalGrammar),
  byName(0x63, 'Bundle/Unbundle By Name', basis: LvClassNameBasis.terminalGrammar)
  ;

  const LvNodeClass(this.code, this.title, {this.basis = LvClassNameBasis.captions});

  final int code;

  final String title;

  final LvClassNameBasis basis;

  static LvNodeClass? ofCode(int code) => _byCode[code];

  static final Map<int, LvNodeClass> _byCode = {for (final nodeClass in values) nodeClass.code: nodeClass};
}

const int kLvRotatePrimResId = 1082;

const int kLvHexStringPrimResId = 1181;

final Map<PrimOp, LvLowering> kLvPrimOpLowerings = {
  PrimOp.exclusiveOr: (call) => _binaryCommutative(call, '^'),
  PrimOp.and: (call) => _binaryCommutative(call, '&'),
  PrimOp.or: (call) => _binaryCommutative(call, '|'),
  PrimOp.add: (call) => _binaryCommutative(call, '+'),
  PrimOp.multiply: (call) => _binaryCommutative(call, '*'),
  PrimOp.subtract: (call) => _binaryOrdered(call, '-'),
  PrimOp.divide: _divide,
  PrimOp.quotientRemainder: _quotientRemainder,
  PrimOp.equal: (call) => _binaryPredicate(call, '=='),
  PrimOp.notEqual: (call) => _binaryPredicate(call, '!='),
  PrimOp.greater: (call) => _orderedPredicate(call, '>'),
  PrimOp.less: (call) => _orderedPredicate(call, '<'),
  PrimOp.not: _not,
  PrimOp.increment: (call) => _unaryNumeric(call, '+ 1'),
  PrimOp.decrement: (call) => _unaryNumeric(call, '- 1'),
  PrimOp.equalToZero: (call) => _comparedToZero(call, '=='),
  PrimOp.notEqualToZero: (call) => _comparedToZero(call, '!='),
  PrimOp.greaterThanZero: (call) => _comparedToZero(call, '>'),
  PrimOp.lessThanZero: (call) => _comparedToZero(call, '<'),
  PrimOp.greaterOrEqualToZero: (call) => _comparedToZero(call, '>='),
  PrimOp.lessOrEqualToZero: (call) => _comparedToZero(call, '<='),
  PrimOp.emptyStringPath: _isEmpty,
  PrimOp.stringLength: (call) => _unaryOfString(call, 'length', LvCarrier.integer),
  PrimOp.arraySize: _arraySize,
  PrimOp.reverse1dArray: _reverse1dArray,
  PrimOp.emptyArray: _emptyArray,
  PrimOp.addArrayElements: _addArrayElements,
  PrimOp.toSinglePrecisionFloat: _floatConversion,
  PrimOp.toDoublePrecisionFloat: _floatConversion,
  PrimOp.toByteInteger: _integerConversion,
  PrimOp.toWordInteger: _integerConversion,
  PrimOp.toLongInteger: _integerConversion,
  PrimOp.toUnsignedByteInteger: _integerConversion,
  PrimOp.toUnsignedWordInteger: _integerConversion,
  PrimOp.toUnsignedLongInteger: _integerConversion,
  PrimOp.toQuadInteger: _integerConversion,
  PrimOp.toUnsignedQuadInteger: _integerConversion,
  PrimOp.stringToByteArray: (call) => _byteArrayConversion(call, encode: true),
  PrimOp.byteArrayToString: (call) => _byteArrayConversion(call, encode: false),
  PrimOp.rotateLeftWithCarry: (call) => _rotateWithCarry(call, left: true),
  PrimOp.rotateRightWithCarry: (call) => _rotateWithCarry(call, left: false),
  PrimOp.swapBytes: (call) => _swap(call, LvRuntimeCall.swapBytes, fieldPairBits: 16),
  PrimOp.swapWords: (call) => _swap(call, LvRuntimeCall.swapWords, fieldPairBits: 32),
  PrimOp.select: _select,
  PrimOp.logicalShift: _logicalShift,
  PrimOp.typeCast: _typeCast,
  PrimOp.notANumberPathRefnum: _isNotANumber,
  PrimOp.stringSubset: _stringSubset,
  PrimOp.toLowerCase: _toLowerCase,
  PrimOp.waitMs: _waitMs,
};

final Map<LvNodeClass, LvLowering> kLvNodeClassLowerings = {
  LvNodeClass.indexArray: _indexArray,
  LvNodeClass.replaceArraySubset: _replaceArraySubset,
  LvNodeClass.buildArray: _buildArray,
  LvNodeClass.concatenateStrings: _concatenateStrings,
  LvNodeClass.unbundle: _unbundle,
  LvNodeClass.mergeErrors: _mergeErrors,
  LvNodeClass.byName: _byName,
  LvNodeClass.compoundArithmetic: _compoundArithmetic,
  LvNodeClass.initializeArray: _initializeArray,
};

final Map<int, LvLowering> kLvPrimResIdLowerings = {
  kLvRotatePrimResId: _rotate,
  kLvHexStringPrimResId: _hexString,
};

final Set<PrimOp> kLvMappedPrimOps = kLvPrimOpLowerings.keys.toSet();

LvLowering? lvPrimRule({PrimOp? op, required int classCode, int? primResId}) {
  if (op != null) return kLvPrimOpLowerings[op];
  return kLvNodeClassLowerings[LvNodeClass.ofCode(classCode)] ?? kLvPrimResIdLowerings[primResId];
}

bool lvPrimHasRule({PrimOp? op, required int classCode, int? primResId}) =>
    lvPrimRule(op: op, classCode: classCode, primResId: primResId) != null;

List<String>? lvPrimLowering(LvPrimCall call) {
  if (!lvPrimHasRule(op: call.op, classCode: call.classCode, primResId: call.primResId)) return null;
  return _lowerDirect(call) ?? _elementwise(call);
}

List<String>? _lowerDirect(LvPrimCall call) =>
    lvPrimRule(op: call.op, classCode: call.classCode, primResId: call.primResId)?.call(call);

abstract final class LvInitializeArrayRole {
  static const int element = 0x20000;

  static const int size = 0x0;

  static const int output = 0x1;
}

enum LvCompoundMode {
  add(0, 'Add'),

  multiply(1, 'Multiply'),

  and(2, 'AND'),

  or(3, 'OR'),

  exclusiveOr(4, 'Exclusive OR')
  ;

  const LvCompoundMode(this.selector, this.opName);

  final int selector;

  final String opName;

  static LvCompoundMode? ofNodeFlags(int? nodeFlags) => nodeFlags == null ? null : _bySelector[(nodeFlags >> 16) & 0x7];

  static final Map<int, LvCompoundMode> _bySelector = {for (final mode in values) mode.selector: mode};
}

const Map<LvCompoundMode, String> kLvLoweredCompoundModes = {
  LvCompoundMode.add: '+',
  LvCompoundMode.exclusiveOr: '^',
};

const int kLvCompoundInversionBit = 0x10000;

const int kLvByNameUnbundlesBit = 0x10000;

String lvPrimUnmappedReason(LvPrimCall call) {
  if (call.op case final op?) {
    final depths = {
      for (final terminal in [...call.inputs, ...call.outputs]) terminal.type.dims,
    };
    if (kLvMappedPrimOps.contains(op) && depths.length > 1 && depths.contains(0)) {
      return 'primitive ${op.opName} (primResID ${op.id}) mixes array and scalar '
          'terminals (dimensionalities ${(depths.toList()..sort()).join('/')}), and the '
          'value LabVIEW broadcasts the scalar operand to at each index is not decoded';
    }
    return 'primitive ${op.opName} (primResID ${op.id}) has no decided lowering: '
        'its operand roles are not established from the terminal records';
  }
  final nodeClass = LvNodeClass.ofCode(call.classCode);
  if (nodeClass == LvNodeClass.indexArray || nodeClass == LvNodeClass.replaceArraySubset) {
    return 'class 0x${call.classCode.toRadixString(16)} node is not the 1-D shape whose '
        'terminal roles the corpus pins (${call.inputs.length} inputs, '
        '${call.outputs.length} outputs, role bits '
        '${[
          for (final terminal in [...call.inputs, ...call.outputs]) '0x${terminal.roleFlags.toRadixString(16)}',
        ].join('/')})';
  }
  if (nodeClass == LvNodeClass.byName) {
    final flags = call.nodeFlags;
    if (flags == null) {
      return 'Bundle/Unbundle By Name (class 0x${call.classCode.toRadixString(16)}) carries no '
          'flags word, and [kLvByNameUnbundlesBit] is the only reading that separates the two';
    }
    final unbundles = (flags & kLvByNameUnbundlesBit) != 0;
    final members = unbundles ? call.outputs : call.inputs;
    final cluster = (unbundles ? call.inputs : call.outputs).firstOrNull?.type;
    final declaration = cluster == null ? null : _clusterDecl(cluster);
    return '${unbundles ? 'Unbundle' : 'Bundle'} By Name (class '
        '0x${call.classCode.toRadixString(16)}) does not resolve its members: '
        '${declaration == null ? 'its cluster wire carries no declared class, and' : 'against ${declaration.name},'} '
        '${members.where((terminal) => terminal.memberName == null).length} of ${members.length} '
        'member terminals name no member on their own record';
  }
  if (nodeClass == LvNodeClass.compoundArithmetic) {
    final mode = LvCompoundMode.ofNodeFlags(call.nodeFlags);
    if (mode == null || !kLvLoweredCompoundModes.containsKey(mode)) {
      final flags = call.nodeFlags;
      final selects = flags == null ? 'no mode, carrying no flags word' : 'mode ${(flags >> 16) & 0x7}';
      return 'Compound Arithmetic (class 0x${call.classCode.toRadixString(16)}) selects $selects'
          '${mode == null ? '' : ' (${mode.opName})'}, which no published test vector decides, '
          'and a wrong reduction is a silently wrong value';
    }
    final inverted = [
      ...call.inputs,
      ...call.outputs,
    ].where((terminal) => terminal.roleFlags & kLvCompoundInversionBit != 0);
    if (inverted.isNotEmpty) {
      return 'Compound Arithmetic (class 0x${call.classCode.toRadixString(16)}) carries the '
          'per-terminal inversion bit on ${inverted.length} of ${call.inputs.length + call.outputs.length} '
          'terminals, and which state the bit names is not decoded';
    }
  }
  if (nodeClass != null) {
    if (kLvNodeClassLowerings.containsKey(nodeClass)) {
      return 'class 0x${call.classCode.toRadixString(16)} is ${nodeClass.title} and its '
          'operand roles are decoded, but this node is outside the shape that '
          'lowers (${call.inputs.length} wired inputs, ${call.outputs.length} of '
          '${call.outputPorts.length} outputs consumed, terminal types '
          '${[
            for (final terminal in [...call.inputs, ...call.outputs]) terminal.type.dartType ?? '?',
          ].join('/')})';
    }
    return 'class 0x${call.classCode.toRadixString(16)} is ${nodeClass.title}, but which '
        'terminal is which argument is not established from the terminal records';
  }
  if (call.primResId case final id?) {
    if (kLvPrimResIdLowerings.containsKey(id)) {
      return 'primResID $id is not named anywhere in the corpus; what it computes is '
          'established for the shapes a published test vector exercises '
          '(see kLvPrimResIdLowerings), and this node is outside them '
          '(${call.inputs.length} wired inputs, ${call.outputs.length} of '
          '${call.outputPorts.length} outputs consumed, terminal types '
          '${[
            for (final terminal in [...call.inputs, ...call.outputs]) terminal.type.dartType ?? '?',
          ].join('/')})';
    }
    return 'primResID $id on node class 0x${call.classCode.toRadixString(16)} is '
        'not named anywhere in the corpus, so the operation it performs is not decoded';
  }
  return 'node class 0x${call.classCode.toRadixString(16)} carries no decoded primitive identity';
}

List<String>? _binaryCommutative(LvPrimCall call, String operator) {
  if (call.inputs.length != 2 || call.outputs.length != 1) return null;
  final out = call.outputs.single;
  if (out.type.dims != 0 || call.inputs.any((operand) => operand.type.dims != 0)) return null;
  final name = out.expression;
  final body = '${call.inputs[0].expression} $operator ${call.inputs[1].expression}';
  return ['final ${out.type.dartType} $name = ${lvWrapped(out.type, body)};'];
}

List<String>? _binaryOrdered(LvPrimCall call, String operator) {
  if (call.outputs.length != 1) return null;
  final operands = call.operandsTopDown;
  if (operands == null) return null;
  final out = call.outputs.single;
  if (out.type.dims != 0 || operands.$1.type.dims != 0 || operands.$2.type.dims != 0) return null;
  if (_hazardous(out.type, operator)) return null;
  final name = out.expression;
  final body = '${operands.$1.expression} $operator ${operands.$2.expression}';
  return ['final ${out.type.dartType} $name = ${lvWrapped(out.type, body)};'];
}

List<String>? _divide(LvPrimCall call) {
  if (call.outputs.length != 1) return null;
  final operands = call.operandsTopDown;
  if (operands == null) return null;
  final out = call.outputs.single;
  if (out.type.dims != 0 || !(out.type.numeric?.isFloat ?? false)) return null;
  final name = out.expression;
  for (final operand in [operands.$1, operands.$2]) {
    if (operand.type.dims != 0 || operand.type.numeric == null) return null;
    if (_hazardous(operand.type, 'toDouble')) return null;
  }
  String widened(LvPrimTerminal operand) =>
      operand.type.isInteger ? '${operand.expression}.toDouble()' : operand.expression;
  final body = '${widened(operands.$1)} / ${widened(operands.$2)}';
  if (out.type.numeric == LvNumericKind.sgl) call.requireImport('dart:typed_data');
  return ['final double $name = ${lvWrapped(out.type, body)};'];
}

List<String>? _orderedPredicate(LvPrimCall call, String operator) {
  if (call.outputs.length != 1) return null;
  final operands = call.operandsTopDown;
  if (operands == null) return null;
  final out = call.outputs.single;
  if (out.type.carrier != LvCarrier.boolean) return null;
  for (final operand in [operands.$1, operands.$2]) {
    if (operand.type.dims != 0 || operand.type.numeric == null) return null;
    if (_hazardous(operand.type, operator)) return null;
  }
  final name = out.expression;
  return ['final bool $name = ${operands.$1.expression} $operator ${operands.$2.expression};'];
}

List<String>? _quotientRemainder(LvPrimCall call) {
  final operands = call.operandsTopDown, results = call.resultsTopDown;
  if (operands == null || results == null) return null;
  final (dividend, divisor) = operands;
  final (remainder, quotient) = results;
  if (quotient == null && remainder == null) return const [];
  for (final terminal in [dividend, divisor, remainder, quotient]) {
    if (terminal == null) continue;
    final kind = terminal.type.numeric;
    if (terminal.type.dims != 0 || kind == null || kind.isFloat) return null;
    if (_hazardous(terminal.type, '~/')) return null;
  }
  call.requireImport(kLvRuntimeImport);
  return [
    'final (${quotient?.expression ?? '_'}, ${remainder?.expression ?? '_'}) = '
        '${LvRuntimeCall.quotientRemainder}(${dividend.expression}, ${divisor.expression});',
  ];
}

List<String>? _swap(LvPrimCall call, String runtimeCall, {required int fieldPairBits}) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  final kind = out.type.numeric;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  if (kind == null || kind.isFloat || kind.bits < fieldPairBits) return null;
  if (source.type.numeric != kind) return null;
  final name = out.expression;
  call.requireImport(kLvRuntimeImport);
  return ['final int $name = ${lvWrapped(out.type, '$runtimeCall(${source.expression})')};'];
}

List<String>? _select(LvPrimCall call) {
  if (call.inputs.length != 3 || call.outputs.length != 1 || !call.hasSoleSourceTerminal) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final (whenTrue, selector, whenFalse) = (ordered[0], ordered[1], ordered[2]);
  final out = call.outputs.single;
  if (selector.type.dims != 0 || selector.type.carrier != LvCarrier.boolean) return null;
  if (whenTrue.type.dartType != out.type.dartType || whenFalse.type.dartType != out.type.dartType) return null;
  if (whenTrue.type.dims != out.type.dims || whenFalse.type.dims != out.type.dims) return null;
  final name = out.expression;
  return [
    'final ${out.type.dartType} $name = '
        '${selector.expression} ? ${whenTrue.expression} : ${whenFalse.expression};',
  ];
}

List<String>? _logicalShift(LvPrimCall call) {
  if (call.inputs.length != 2 || call.outputs.length != 1 || !call.hasSoleSourceTerminal) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final (count, value) = (ordered[0], ordered[1]);
  final out = call.outputs.single;
  final kind = out.type.numeric;
  if (kind == null || kind.isFloat || out.type.dims != 0) return null;
  if (value.type.dims != 0 || value.type.numeric != kind) return null;
  if (count.type.dims != 0 || !count.type.isInteger) return null;
  final name = out.expression;
  call.requireImport(kLvRuntimeImport);
  final shifted = '${LvRuntimeCall.logicalShift}(${value.expression}, ${count.expression}, ${kind.bits})';
  return ['final int $name = ${lvWrapped(out.type, shifted)};'];
}

List<String>? _typeCast(LvPrimCall call) {
  if (call.outputs.length != 1) return null;
  final out = call.outputs.single;
  final LvPrimTerminal value;
  if (call.inputs.length == 2 && call.hasSoleSourceTerminal) {
    final typed = call.inputs.where((operand) => _sameWireType(operand.type, out.type)).toList();
    if (typed.length != 1) return null;
    value = call.inputs.firstWhere((operand) => !identical(operand, typed.single));
  } else if (call.inputs.length == 1 && call.outputPorts.length == 2) {
    if (out.type.dims != 0 || out.type.carrier != LvCarrier.text) return null;
    value = call.inputs.single;
  } else {
    return null;
  }
  final bytes = _flatOf(value);
  if (bytes == null) return null;
  final result = _valueOfFlat(out.type, bytes);
  if (result == null) return null;
  final name = out.expression;
  call.requireImport(kLvRuntimeImport);
  if (out.type.dims == 1 && out.type.numeric != null) call.requireImport('dart:typed_data');
  return ['final ${out.type.dartType} $name = $result;'];
}

bool _sameWireType(LvWireType left, LvWireType right) =>
    left.dims == right.dims && left.dartType == right.dartType && left.numeric == right.numeric;

String? _flatOf(LvPrimTerminal operand) {
  final kind = operand.type.numeric;
  if (operand.type.dims == 0) {
    if (operand.type.carrier == LvCarrier.text) {
      return '${LvRuntimeCall.flatOfString}(${operand.expression})';
    }
    if (kind == null) return null;
    final call = kind.isFloat ? LvRuntimeCall.flatOfFloat : LvRuntimeCall.flatOfInt;
    return '$call(${operand.expression}, ${kind.bits})';
  }
  if (operand.type.dims != 1 || kind == null || kind.isFloat) return null;
  return '${LvRuntimeCall.flatOfIntList}(${operand.expression}, ${kind.bits})';
}

String? _valueOfFlat(LvWireType type, String bytes) {
  final kind = type.numeric;
  if (type.dims == 0) {
    if (type.carrier == LvCarrier.text) return '${LvRuntimeCall.stringOfFlat}($bytes)';
    if (kind == null) return null;
    if (kind.isFloat) return '${LvRuntimeCall.floatOfFlat}($bytes, ${kind.bits})';
    return lvWrapped(type, '${LvRuntimeCall.intOfFlat}($bytes, ${kind.bits})');
  }
  if (type.dims != 1 || kind == null || kind.isFloat) return null;
  return '${kind.typedListType}.fromList(${LvRuntimeCall.intListOfFlat}($bytes, ${kind.bits}))';
}

List<String>? _buildArray(LvPrimCall call) {
  if (call.outputs.length != 1 || !call.hasSoleSourceTerminal || call.inputs.isEmpty) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final out = call.outputs.single;
  if (out.type.dims != 1) return null;
  final element = out.type.element;
  final pieces = <String>[];
  for (final operand in ordered) {
    if (operand.type.element.dartType != element.dartType) return null;
    switch (out.type.dims - operand.type.dims) {
      case 0:
        pieces.add('...${operand.expression}');
      case 1:
        pieces.add(operand.expression);
      case _:
        return null;
    }
  }
  final name = out.expression;
  if (out.type.numeric != null) call.requireImport('dart:typed_data');
  final built = lvArrayFreeze(element, '<${element.dartType}>[${pieces.join(', ')}]');
  return ['final ${out.type.dartType} $name = $built;'];
}

List<String>? _concatenateStrings(LvPrimCall call) {
  if (call.outputs.length != 1 || !call.hasSoleSourceTerminal || call.inputs.isEmpty) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final out = call.outputs.single;
  if (out.type.dims != 0 || out.type.carrier != LvCarrier.text) return null;
  for (final operand in ordered) {
    if (operand.type.dims != 0 || operand.type.carrier != LvCarrier.text) return null;
  }
  final name = out.expression;
  final operands = [for (final operand in ordered) operand.expression];
  final joined = operands.length == 1 ? operands.single : "'${operands.map(_interpolated).join()}'";
  return ['final String $name = $joined;'];
}

LvTypeDecl? _clusterDecl(LvWireType type) {
  if (type.dims != 0 || type.declarations.length != 1) return null;
  final declaration = type.declarations.single;
  if (declaration.isEnum || declaration.fields.isEmpty) return null;
  return declaration.name == type.dartType ? declaration : null;
}

int? _soleFieldIndex(LvTypeDecl declaration, String? label) {
  if (label == null) return null;
  int? found;
  for (var i = 0; i < declaration.fields.length; i++) {
    if (declaration.fields[i].label != label) continue;
    if (found != null) return null;
    found = i;
  }
  return found;
}

bool _memberMatches(LvTypeDecl declaration, int index, LvWireType wire) {
  final type = declaration.fields[index].type;
  return type.isMapped && type.dartType == wire.dartType;
}

List<String>? _unbundle(LvPrimCall call) {
  if (call.inputs.length != 1) return null;
  final source = call.inputs.single;
  final declaration = _clusterDecl(source.type);
  if (declaration == null) return null;
  final ordered = call.portsTopDown(call.outputPorts);
  if (ordered == null || ordered.length != declaration.fields.length) return null;
  final names = LvNaming.declarationFields([for (final field in declaration.fields) field.label]);
  final statements = <String>[];
  for (var i = 0; i < ordered.length; i++) {
    final result = LvPrimCall._terminalAt(call.outputs, ordered[i]);
    if (result == null) continue;
    if (!_memberMatches(declaration, i, result.type)) return null;
    if (result.memberName != null && result.memberName != declaration.fields[i].label) return null;
    statements.add(
      'final ${declaration.fields[i].type.dartType} ${result.expression} = '
      '${source.expression}.${names[i]};',
    );
  }
  return statements;
}

List<String>? _byName(LvPrimCall call) => switch (call.nodeFlags) {
  null => null,
  final flags when flags & kLvByNameUnbundlesBit != 0 => _unbundleByName(call),
  _ => _bundleByName(call),
};

List<String>? _unbundleByName(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.isEmpty) return null;
  final source = call.inputs.single;
  final declaration = _clusterDecl(source.type);
  if (declaration == null) return null;
  final names = LvNaming.declarationFields([for (final field in declaration.fields) field.label]);
  final statements = <String>[];
  for (final result in call.outputs) {
    final index = _soleFieldIndex(declaration, result.memberName);
    if (index == null || !_memberMatches(declaration, index, result.type)) return null;
    statements.add(
      'final ${declaration.fields[index].type.dartType} ${result.expression} = '
      '${source.expression}.${names[index]};',
    );
  }
  return statements;
}

List<String>? _bundleByName(LvPrimCall call) {
  if (call.outputs.length != 1 || !call.hasSoleSourceTerminal) return null;
  final result = call.outputs.single;
  final declaration = _clusterDecl(result.type);
  if (declaration == null) return null;
  final written = <int, LvPrimTerminal>{};
  final bases = <LvPrimTerminal>[];
  for (final operand in call.inputs) {
    final index = _soleFieldIndex(declaration, operand.memberName);
    if (index == null) {
      bases.add(operand);
      continue;
    }
    if (written.containsKey(index) || !_memberMatches(declaration, index, operand.type)) return null;
    written[index] = operand;
  }
  if (bases.length != 1 || written.isEmpty) return null;
  final base = bases.single;
  if (base.type.dartType != declaration.name) return null;
  final name = result.expression;
  final statements = <String>[];
  var carrier = base.expression;
  if (!lvIsAtomic(carrier) && written.length < declaration.fields.length) {
    final local = call.names.wire(base.type);
    statements.add('final ${declaration.name} $local = $carrier;');
    carrier = local;
  }
  final names = LvNaming.declarationFields([for (final field in declaration.fields) field.label]);
  final arguments = [
    for (var i = 0; i < declaration.fields.length; i++)
      '${names[i]}: ${written[i]?.expression ?? '$carrier.${names[i]}'}',
  ];
  return statements..add('final ${declaration.name} $name = ${declaration.name}(${arguments.join(', ')});');
}

List<String>? _mergeErrors(LvPrimCall call) {
  if (call.outputs.length != 1 || !call.hasSoleSourceTerminal || call.inputs.length < 2) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final result = call.outputs.single;
  if (!result.type.isErrorCluster || ordered.any((operand) => !operand.type.isErrorCluster)) return null;
  final name = result.expression;
  call.requireImport(kLvRuntimeImport);
  final operands = [for (final operand in ordered) operand.expression].join(', ');
  return [
    'final ${LvRuntimeType.error} $name = '
        '${LvRuntimeCall.mergeErrors}(<${LvRuntimeType.error}>[$operands]);',
  ];
}

List<String>? _isNotANumber(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, result = call.outputs.single;
  if (source.type.dims != 0 || !(source.type.numeric?.isFloat ?? false)) return null;
  if (result.type.dims != 0 || result.type.carrier != LvCarrier.boolean) return null;
  final name = result.expression;
  return ['final bool $name = ${source.expression}.isNaN;'];
}

String _interpolated(String expression) =>
    RegExp(r'^[A-Za-z_]\w*$').hasMatch(expression) ? '\$$expression' : '\${$expression}';

List<String>? _elementwise(LvPrimCall call) {
  if (call.op == null && !kLvPrimResIdLowerings.containsKey(call.primResId)) return null;
  if (call.op == PrimOp.typeCast || call.inputs.isEmpty) return null;
  final terminals = [...call.inputs, ...call.outputs];
  if (terminals.any((terminal) => terminal.type.dims != 1)) return null;

  final prologue = <String>[];
  final arrays = <String>[];
  for (final operand in call.inputs) {
    final expression = operand.expression;
    if (lvIsAtomic(expression)) {
      arrays.add(expression);
      continue;
    }
    final local = call.names.wire(operand.type);
    prologue.add('final ${operand.type.dartType} $local = $expression;');
    arrays.add(local);
  }

  final index = call.names.loopIndex();
  final scalars = [for (final result in call.outputs) call.names.wire(result.type.scalar)];
  final scalar = LvPrimCall(
    op: call.op,
    primResId: call.primResId,
    classCode: call.classCode,
    inputs: [
      for (final (i, operand) in call.inputs.indexed)
        LvPrimTerminal(
          port: operand.port,
          type: operand.type.scalar,
          roleFlags: operand.roleFlags,
          expression: '${arrays[i]}[$index]',
        ),
    ],
    outputs: [
      for (final (i, result) in call.outputs.indexed)
        LvPrimTerminal(
          port: result.port,
          type: result.type.scalar,
          roleFlags: result.roleFlags,
          expression: scalars[i],
        ),
    ],
    outputPorts: call.outputPorts,
    portDrawnTop: call.portDrawnTop,
    requireImport: call.requireImport,
    names: call.names,
    nodeFlags: call.nodeFlags,
  );
  final body = _lowerDirect(scalar);
  if (body == null) return null;

  final builders = <String>[];
  final statements = [...prologue];
  for (final result in call.outputs) {
    final builder = call.names.role(LvNameRole.builder);
    builders.add(builder);
    statements.add('final ${lvArrayBuilderType(result.type.element)} $builder = <${result.type.element.dartType}>[];');
  }
  final lengths = [for (final array in arrays) '$array.length'];
  String bound;
  if (lengths.length == 1) {
    bound = lengths.single;
  } else {
    call.requireImport(kLvRuntimeImport);
    bound = call.names.role(LvNameRole.count);
    statements.add('final int $bound = ${LvRuntimeCall.iterationCount}(<int>[${lengths.join(', ')}]);');
  }
  statements
    ..add('for (var $index = 0; $index < $bound; $index++) {')
    ..addAll(body)
    ..addAll([for (final (i, _) in call.outputs.indexed) '${builders[i]}.add(${scalars[i]});'])
    ..add('}');
  for (final (i, result) in call.outputs.indexed) {
    if (result.type.numeric != null) call.requireImport('dart:typed_data');
    final frozen = lvArrayFreeze(result.type.element, builders[i]);
    statements.add('final ${result.type.dartType} ${result.expression} = $frozen;');
  }
  return statements;
}

const Set<LvCarrier> _kValueEqualityCarriers = {LvCarrier.integer, LvCarrier.float, LvCarrier.boolean, LvCarrier.text};

List<String>? _binaryPredicate(LvPrimCall call, String operator) {
  if (call.inputs.length != 2 || call.outputs.length != 1) return null;
  final left = call.inputs[0], right = call.inputs[1], out = call.outputs.single;
  if (left.type.dims != 0 || right.type.dims != 0) return null;
  if (!_kValueEqualityCarriers.contains(left.type.carrier)) return null;
  if (left.type.carrier != right.type.carrier) return null;
  if (out.type.carrier != LvCarrier.boolean) return null;
  final name = out.expression;
  return ['final bool $name = ${left.expression} $operator ${right.expression};'];
}

List<String>? _comparedToZero(LvPrimCall call, String operator) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || source.type.numeric == null) return null;
  if (_hazardous(source.type, operator)) return null;
  if (out.type.carrier != LvCarrier.boolean) return null;
  final name = out.expression;
  final zero = source.type.isInteger ? '0' : '0.0';
  return ['final bool $name = ${source.expression} $operator $zero;'];
}

List<String>? _isEmpty(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || out.type.carrier != LvCarrier.boolean) return null;
  if (source.type.carrier != LvCarrier.text && source.type.carrier != LvCarrier.path) return null;
  final name = out.expression;
  return ['final bool $name = ${source.expression}.isEmpty;'];
}

List<String>? _reverse1dArray(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 1 || out.type.dims != 1) return null;
  if (source.type.dartType != out.type.dartType) return null;
  final name = out.expression;
  if (out.type.numeric != null) call.requireImport('dart:typed_data');
  final reversed = lvArrayFreeze(out.type.element, '${source.expression}.reversed.toList()');
  return ['final ${out.type.dartType} $name = $reversed;'];
}

List<String>? _emptyArray(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 1 || out.type.dims != 0 || out.type.carrier != LvCarrier.boolean) return null;
  final name = out.expression;
  return ['final bool $name = ${source.expression}.isEmpty;'];
}

List<String>? _addArrayElements(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 1 || out.type.dims != 0) return null;
  final kind = out.type.numeric;
  if (kind == null || kind.hazards.isNotEmpty) return null;
  if (source.type.element.dartType != out.type.dartType) return null;
  final name = out.expression;
  final total = call.names.role(LvNameRole.value);
  final element = call.names.role(LvNameRole.element);
  final step = lvWrapExpression(kind, '$total + $element');
  return [
    'final ${out.type.dartType} $name = ${source.expression}.fold<${out.type.dartType}>(',
    '  ${kind.isFloat ? '0.0' : '0'},',
    '  ($total, $element) => $step,',
    ');',
  ];
}

List<String>? _unaryOfString(LvPrimCall call, String member, LvCarrier result) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || source.type.carrier != LvCarrier.text) return null;
  if (out.type.carrier != result) return null;
  final name = out.expression;
  return ['final ${result.dartType} $name = ${source.expression}.$member;'];
}

List<String>? _arraySize(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 1 || out.type.dims != 0) return null;
  if (!out.type.isInteger) return null;
  final name = out.expression;
  return ['final int $name = ${source.expression}.length;'];
}

bool _hazardous(LvWireType type, String operator) =>
    type.numeric?.hazards.any((hazard) => hazard.operators.contains(operator)) ?? false;

List<String>? _not(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  if (source.type.dartType != out.type.dartType) return null;
  final name = out.expression;
  if (out.type.carrier == LvCarrier.boolean) {
    return ['final bool $name = !${source.expression};'];
  }
  final kind = out.type.numeric;
  if (kind == null || kind.isFloat) return null;
  return ['final int $name = ${lvWrapped(out.type, '~${source.expression}')};'];
}

List<String>? _unaryNumeric(LvPrimCall call, String suffix) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  if (out.type.numeric == null) return null;
  final name = out.expression;
  final body = '${source.expression} $suffix';
  return ['final ${out.type.dartType} $name = ${lvWrapped(out.type, body)};'];
}

List<String>? _integerConversion(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  final target = out.type.numeric;
  if (target == null || target.isFloat) return null;
  if (!source.type.isInteger) return null;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  final name = out.expression;
  call.requireImport(kLvRuntimeImport);
  return ['final int $name = ${LvRuntimeCall.integerConversion(target)}(${source.expression});'];
}

List<String>? _floatConversion(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  final target = out.type.numeric, from = source.type.numeric;
  if (target == null || !target.isFloat || from == null) return null;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  if (_hazardous(source.type, 'toDouble')) return null;
  final name = out.expression;
  if (target == LvNumericKind.sgl) call.requireImport('dart:typed_data');
  final widened = from.isFloat ? source.expression : '${source.expression}.toDouble()';
  return ['final double $name = ${lvWrapped(out.type, widened)};'];
}

List<String>? _byteArrayConversion(LvPrimCall call, {required bool encode}) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (encode && (source.type.dims != 0 || out.type.dims != 1)) return null;
  if (!encode && (source.type.dims != 1 || out.type.dims != 0)) return null;
  if (out.type.numeric != null && out.type.numeric != LvNumericKind.u8) return null;
  final name = out.expression;
  call.requireImport('dart:convert');
  if (encode) {
    call.requireImport('dart:typed_data');
    return ['final Uint8List $name = latin1.encode(${source.expression});'];
  }
  return ['final String $name = latin1.decode(${source.expression});'];
}

List<String>? _rotateWithCarry(LvPrimCall call, {required bool left}) {
  if (call.inputs.length != 2 || call.outputs.length != 2) return null;
  final value = _onlyNumeric(call.inputs), carryIn = _onlyBoolean(call.inputs);
  final rotated = _onlyNumeric(call.outputs), carryOut = _onlyBoolean(call.outputs);
  if (value == null || carryIn == null || rotated == null || carryOut == null) {
    return null;
  }
  final kind = rotated.type.numeric;
  if (kind == null || kind.isFloat || value.type.numeric != kind) return null;
  call.requireImport(kLvRuntimeImport);
  final rotate = left ? LvRuntimeCall.rotateLeftWithCarry : LvRuntimeCall.rotateRightWithCarry;
  return [
    'final (${rotated.expression}, ${carryOut.expression}) = '
        '$rotate(${value.expression}, ${carryIn.expression}, ${kind.bits});',
  ];
}

LvPrimTerminal? _onlyNumeric(List<LvPrimTerminal> terminals) =>
    LvPrimCall._single(terminals.where((terminal) => terminal.type.dims == 0 && terminal.type.numeric != null));

LvPrimTerminal? _onlyBoolean(List<LvPrimTerminal> terminals) => LvPrimCall._single(
  terminals.where((terminal) => terminal.type.dims == 0 && terminal.type.carrier == LvCarrier.boolean),
);

List<String>? _indexArray(LvPrimCall call) {
  if (call.outputs.isEmpty || call.inputs.length != call.outputs.length + 1) {
    return null;
  }
  final array = call.inputs.first;
  if (array.roleFlags != LvArrayTerminalRole.array || array.type.dims != 1) {
    return null;
  }
  final statements = <String>[];
  for (var group = 0; group < call.outputs.length; group++) {
    final index = call.inputs[group + 1], out = call.outputs[group];
    if (index.roleFlags != LvArrayTerminalRole.singleIndex) return null;
    final expectedRole = group == 0 ? LvArrayTerminalRole.output : LvArrayTerminalRole.grownOutput;
    if (out.roleFlags != expectedRole) return null;
    if (index.type.dims != 0 || out.type.dims != 0) return null;
    final name = out.expression;
    statements.add('final ${out.type.dartType} $name = ${array.expression}[${index.expression}];');
  }
  return statements;
}

List<String>? _replaceArraySubset(LvPrimCall call) {
  final array = call.inputWithRole(LvArrayTerminalRole.array);
  final index = call.inputWithRole(LvArrayTerminalRole.singleIndex);
  final element = call.inputWithRole(LvArrayTerminalRole.newElement);
  final out = call.outputWithRole(LvArrayTerminalRole.output);
  if (array == null || index == null || element == null || out == null) {
    return null;
  }
  if (call.inputs.length != 3 || call.outputs.length != 1) return null;
  if (array.type.dims != 1 || index.type.dims != 0) return null;
  if (element.type.dims != 0 || out.type.dims != 1) return null;
  final name = out.expression;
  final storage = out.type.elementListType;
  return [
    'final $storage $name = $storage.fromList(${array.expression})..[${index.expression}] = ${element.expression};',
  ];
}

List<String>? _compoundArithmetic(LvPrimCall call) {
  if (call.outputs.length != 1 || !call.hasSoleSourceTerminal || call.inputs.length < 2) return null;
  final mode = LvCompoundMode.ofNodeFlags(call.nodeFlags);
  final operator = kLvLoweredCompoundModes[mode];
  if (operator == null) return null;
  final out = call.outputs.single;
  if (out.roleFlags & kLvCompoundInversionBit != 0) return null;
  final kind = out.type.numeric;
  if (kind == null || out.type.dims != 0) return null;
  if (kind.isFloat) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  for (final operand in ordered) {
    if (operand.roleFlags & kLvCompoundInversionBit != 0) return null;
    if (operand.type.dims != 0 || operand.type.numeric != kind) return null;
  }
  final name = out.expression;
  final body = [for (final operand in ordered) operand.expression].join(' $operator ');
  return ['final ${out.type.dartType} $name = ${lvWrapped(out.type, body)};'];
}

List<String>? _initializeArray(LvPrimCall call) {
  if (call.outputs.length != 1 || !call.hasSoleSourceTerminal || call.inputs.length != 2) return null;
  final element = call.inputWithRole(LvInitializeArrayRole.element);
  final size = call.inputWithRole(LvInitializeArrayRole.size);
  final out = call.outputs.single;
  if (element == null || size == null || out.roleFlags != LvInitializeArrayRole.output) return null;
  if (out.type.dims != 1 || element.type.dims != 0) return null;
  if (element.type.dartType != out.type.element.dartType) return null;
  if (size.type.dims != 0 || !size.type.isInteger) return null;
  final name = out.expression;
  call.requireImport(kLvRuntimeImport);
  if (out.type.numeric != null) call.requireImport('dart:typed_data');
  final filled =
      '${LvRuntimeCall.initializeArray}<${out.type.element.dartType}>'
      '(${size.expression}, ${element.expression})';
  return ['final ${out.type.dartType} $name = ${lvArrayFreeze(out.type.element, filled)};'];
}

List<String>? _stringSubset(LvPrimCall call) {
  if (call.outputs.length != 1) return null;
  final out = call.outputs.single;
  if (out.type.dims != 0 || out.type.carrier != LvCarrier.text) return null;
  final rows = call.portsTopDown([
    for (final operand in call.inputs) operand.port,
    for (final port in call.outputPorts)
      if (port != out.port) port,
  ]);
  if (rows == null || rows.length != 3) return null;
  final wired = {for (final operand in call.inputs) operand.port: operand};
  final string = wired[rows[0]], offset = wired[rows[1]], length = wired[rows[2]];
  if (string == null || offset == null) return null;
  if (string.type.dims != 0 || string.type.carrier != LvCarrier.text) return null;
  for (final count in [offset, length]) {
    if (count == null) continue;
    if (count.type.dims != 0 || !count.type.isInteger) return null;
    if (_hazardous(count.type, '<')) return null;
  }
  final name = out.expression;
  call.requireImport(kLvRuntimeImport);
  final arguments = [string.expression, offset.expression, if (length != null) length.expression];
  return ['final String $name = ${LvRuntimeCall.stringSubset}(${arguments.join(', ')});'];
}

List<String>? _toLowerCase(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || source.type.carrier != LvCarrier.text) return null;
  if (out.type.dims != 0 || out.type.carrier != LvCarrier.text) return null;
  final name = out.expression;
  call.requireImport(kLvRuntimeImport);
  return ['final String $name = ${LvRuntimeCall.toLowerCase}(${source.expression});'];
}

List<String>? _waitMs(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputPorts.length != 1) return null;
  final source = call.inputs.single;
  final operand = source.type.numeric;
  if (source.type.dims != 0 || operand == null || operand.isFloat) return null;

  final out = call.outputs.singleOrNull;
  if (out != null && (out.type.dims != 0 || out.type.numeric != LvNumericKind.u32)) return null;

  call.requireImport(kLvRuntimeImport);
  final wait = '${LvRuntimeCall.waitMs}(${source.expression})';
  return [if (out == null) '$wait;' else 'final ${out.type.dartType} ${out.expression} = $wait;'];
}

List<String>? _rotate(LvPrimCall call) {
  if (call.inputs.length != 2 || call.outputs.length != 1 || !call.hasSoleSourceTerminal) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final (count, value) = (ordered[0], ordered[1]);
  final out = call.outputs.single;
  final kind = out.type.numeric;
  if (kind == null || kind.isFloat || kind.bits != 32 || out.type.dims != 0) return null;
  if (value.type.dims != 0 || value.type.numeric != kind) return null;
  if (count.type.dims != 0 || !count.type.isInteger) return null;
  final name = out.expression;
  call.requireImport(kLvRuntimeImport);
  final rotated = '${LvRuntimeCall.rotate}(${value.expression}, ${count.expression}, ${kind.bits})';
  return ['final int $name = ${lvWrapped(out.type, rotated)};'];
}

List<String>? _hexString(LvPrimCall call) {
  if (call.inputs.length != 2 || call.outputs.length != 1 || !call.hasSoleSourceTerminal) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final (value, width) = (ordered[0], ordered[1]);
  final out = call.outputs.single;
  final kind = value.type.numeric;
  if (out.type.dims != 0 || out.type.carrier != LvCarrier.text) return null;
  if (kind == null || kind.isFloat || kind.bits != 32 || value.type.dims != 0) return null;
  if (width.type.dims != 0 || !width.type.isInteger) return null;
  final name = out.expression;
  call.requireImport(kLvRuntimeImport);
  return [
    'final String $name = '
        '${LvRuntimeCall.hexString}(${value.expression}, ${width.expression}, ${kind.bits});',
  ];
}

String lvWrapped(LvWireType type, String expression) {
  final kind = type.numeric;
  return kind == null ? expression : lvWrapExpression(kind, expression);
}

String lvWrapExpression(LvNumericKind kind, String expression) {
  if (!kind.needsWrap) return expression;
  final wrapped = kind.wrap(expression);
  return lvIsAtomic(expression) ? wrapped.replaceFirst('($expression)', expression) : wrapped;
}
