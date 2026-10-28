import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'format_string.dart';
import 'naming.dart';
import 'numeric.dart';
import 'prim_families.dart';
import 'runtime.dart';
import 'type_map.dart';
import 'wire_type.dart';

abstract final class LvArrayTerminalRole {
  /// An array input; Array Subset's length terminal carries the same bits.
  static const int array = 0x20000;

  static const int output = 0x1;

  /// A repeated Index Array output; Delete From Array's deleted portion carries the same bits.
  static const int grownOutput = 0x40001;

  static const int newElement = 0x40000;

  static const int singleIndex = 0x600000;

  static const int groupFirst = 0x200000;

  static const int groupLast = 0x400000;

  /// Set on an index or length terminal that is left unwired and takes its default.
  static const int unwiredDefault = 0x80000;

  /// Array Subset's array input.
  static const int subsetArray = 0x10000;
}

/// The role bits of a Property Node, Invoke Node or Register For Events node's fixed terminals.
abstract final class LvServerNodeRole {
  static const int referenceIn = 0x10000;

  static const int referenceOut = 0x40001;

  static const int errorIn = 0x20000;

  static const int errorOut = 0x80001;

  /// An Invoke Node's method name record, on the left and on the right.
  static const int methodLeft = 0x30000;

  static const int methodRight = 0x30001;

  /// The bit a Register For Events reference-in terminal may add.
  static const int referenceInVariant = 0x4;

  /// Set on an Invoke Node parameter the method does not require.
  static const int optionalParameter = 0x40000;
}

class LvPrimTerminal {
  const LvPrimTerminal({
    required this.port,
    required this.type,
    required this.roleFlags,
    required this.expression,
    this.memberName,
    this.constantText,
  });

  final int port;

  final LvWireType type;

  final int roleFlags;

  final String? expression;

  final String? memberName;

  /// The text of the diagram constant feeding an input, when one does.
  final String? constantText;
}

class LvPrimCall {
  LvPrimCall({
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
    this.portRoleFlags = const {},
    this.ports = const [],
    this.portMemberName = const {},
  });

  final PrimOp? op;

  final int? primResId;

  final int classCode;

  final int? nodeFlags;

  final List<LvPrimTerminal> inputs;

  final List<LvPrimTerminal> outputs;

  final List<int> outputPorts;

  final Map<int, int> portDrawnTop;

  /// Every terminal's role flags, wired or not.
  final Map<int, int> portRoleFlags;

  /// Every terminal holder in heap child order, wired or not.
  final List<int> ports;

  /// The type label of every terminal's own record, wired or not, where it carries one.
  final Map<int, String> portMemberName;

  final void Function(String) requireImport;

  final LvNaming names;

  /// Why the lowering that ran last declined this call, when it said.
  String? refusal;

  /// Declines the call for [reason]; the lowering returns this.
  Null refuse(String reason) {
    refusal = reason;
    return null;
  }

  LvPrimTerminal? inputWithRole(int flags) => _single(inputs.where((terminal) => terminal.roleFlags == flags));

  LvPrimTerminal? outputWithRole(int flags) => _single(outputs.where((terminal) => terminal.roleFlags == flags));

  bool get hasSoleSourceTerminal => outputPorts.length == 1;

  List<LvPrimTerminal>? get inputsTopDown {
    final rows = <int>{};
    for (final terminal in inputs) {
      final top = portDrawnTop[terminal.port];
      if (top == null || !rows.add(top)) return null;
    }
    return [...inputs]..sort((a, b) => portDrawnTop[a.port]!.compareTo(portDrawnTop[b.port]!));
  }

  List<int>? portsTopDown(List<int> ports) {
    final rows = <int>{};
    for (final port in ports) {
      final top = portDrawnTop[port];
      if (top == null || !rows.add(top)) return null;
    }
    return [...ports]..sort((a, b) => portDrawnTop[a]!.compareTo(portDrawnTop[b]!));
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
  byName(0x63, 'Bundle/Unbundle By Name', basis: LvClassNameBasis.terminalGrammar),
  arraySubset(0x48, 'Array Subset', basis: LvClassNameBasis.terminalGrammar),
  insertIntoArray(0xbb, 'Insert Into Array', basis: LvClassNameBasis.terminalGrammar),
  decimateArray(0x40, 'Decimate 1D Array', basis: LvClassNameBasis.terminalGrammar),
  reshapeArray(0x116, 'Reshape Array', basis: LvClassNameBasis.terminalGrammar),
  propertyNode(0x8c, 'Property Node', basis: LvClassNameBasis.terminalGrammar),
  invokeNode(0xa9, 'Invoke Node', basis: LvClassNameBasis.terminalGrammar),
  localVariable(0xb6, 'Local Variable', basis: LvClassNameBasis.terminalGrammar),
  registerForEvents(0xeb, 'Register For Events', basis: LvClassNameBasis.terminalGrammar),
  eventDataNode(0xd6, 'Event Data Node', basis: LvClassNameBasis.terminalGrammar),
  feedbackNode(0x14a, 'Feedback Node', basis: LvClassNameBasis.terminalGrammar),
  feedbackInitializer(0x170, 'Feedback Node initializer', basis: LvClassNameBasis.terminalGrammar);

  const LvNodeClass(this.code, this.title, {this.basis = LvClassNameBasis.captions});

  final int code;

  final String title;

  final LvClassNameBasis basis;

  static LvNodeClass? ofCode(int code) => _byCode[code];

  static final Map<int, LvNodeClass> _byCode = {for (final nodeClass in values) nodeClass.code: nodeClass};
}

const int kLvRotatePrimResId = 1082;

/// Primitives whose effect is more than their outputs, so a call runs even when nothing reads
/// them: waits, dialogs, file and reference operations, queue, notifier and event traffic.
const Set<PrimOp> kLvSideEffectPrimOps = {
  PrimOp.waitMs,
  PrimOp.waitUntilNextMsMultiple,
  PrimOp.oneButtonDialog,
  PrimOp.twoButtonDialog,
  PrimOp.fileDialog,
  PrimOp.stop,
  PrimOp.quitLabview,
  PrimOp.openCreateReplaceFile,
  PrimOp.closeFile,
  PrimOp.writeToTextFile,
  PrimOp.writeToBinaryFile,
  PrimOp.readFromTextFile,
  PrimOp.readFromBinaryFile,
  PrimOp.setFilePosition,
  PrimOp.setFileSize,
  PrimOp.createFolder,
  PrimOp.delete,
  PrimOp.copy,
  PrimOp.move,
  PrimOp.setPermissions,
  PrimOp.obtainQueue,
  PrimOp.releaseQueue,
  PrimOp.enqueueElement,
  PrimOp.sendNotification,
  PrimOp.waitOnNotification,
  PrimOp.newDataValueReference,
  PrimOp.deleteDataValueReference,
  PrimOp.createUserEvent,
  PrimOp.generateUserEvent,
  PrimOp.destroyUserEvent,
  PrimOp.unregisterForEvents,
  PrimOp.openViReference,
  PrimOp.closeReference,
  PrimOp.newViObject,
  PrimOp.tcpOpenConnection,
  PrimOp.tcpRead,
  PrimOp.tcpWrite,
  PrimOp.tcpCloseConnection,
  PrimOp.visaClose,
  PrimOp.visaLock,
  PrimOp.tdmsOpen,
  PrimOp.tdmsWrite,
  PrimOp.tdmsClose,
  PrimOp.tdmsSetProperties,
  PrimOp.openPythonSession,
  PrimOp.closePythonSession,
};

/// Node classes whose effect is more than their outputs.
const Set<LvNodeClass> kLvSideEffectNodeClasses = {
  LvNodeClass.propertyNode,
  LvNodeClass.invokeNode,
  LvNodeClass.localVariable,
  LvNodeClass.registerForEvents,
};

/// Whether a primitive node runs for its effect even when nothing reads its outputs.
bool lvPrimHasSideEffect({PrimOp? op, required int classCode}) {
  if (op != null) return kLvSideEffectPrimOps.contains(op);
  final nodeClass = LvNodeClass.ofCode(classCode);
  return nodeClass != null && kLvSideEffectNodeClasses.contains(nodeClass);
}

final Map<PrimOp, LvLowering> kLvPrimOpLowerings = {
  ...kLvFamilyLowerings,
  PrimOp.exclusiveOr: (call) => _binaryCommutative(call, '^'),
  PrimOp.numberToHexadecimalString: _hexString,
  PrimOp.and: (call) => _binaryCommutative(call, '&'),
  PrimOp.or: (call) => _binaryCommutative(call, '|'),
  PrimOp.add: (call) => _binaryCommutative(call, '+'),
  PrimOp.multiply: (call) => _binaryCommutative(call, '*'),
  PrimOp.equal: (call) => _binaryPredicate(call, '=='),
  PrimOp.notEqual: (call) => _binaryPredicate(call, '!='),
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
  PrimOp.matchPattern: _matchPattern,
  PrimOp.buildPath: _buildPath,
  PrimOp.search1dArray: _search1dArray,
  PrimOp.randomNumber: _randomNumber,
  PrimOp.toLowerCase: _toLowerCase,
  PrimOp.waitMs: _waitMs,
};

final Map<LvNodeClass, LvLowering> kLvNodeClassLowerings = {
  LvNodeClass.indexArray: _indexArray,
  LvNodeClass.replaceArraySubset: _replaceArraySubset,
  LvNodeClass.buildArray: _buildArray,
  LvNodeClass.concatenateStrings: _concatenateStrings,
  LvNodeClass.formatIntoString: _formatIntoString,
  LvNodeClass.unbundle: _unbundle,
  LvNodeClass.mergeErrors: _mergeErrors,
  LvNodeClass.byName: _byName,
  LvNodeClass.compoundArithmetic: _compoundArithmetic,
  LvNodeClass.initializeArray: _initializeArray,
  LvNodeClass.bundle: _bundle,
  LvNodeClass.deleteFromArray: _deleteFromArray,
  LvNodeClass.arraySubset: _arraySubset,
  LvNodeClass.insertIntoArray: _insertIntoArray,
  LvNodeClass.decimateArray: _decimateArray,
  LvNodeClass.reshapeArray: _reshapeArray,
  LvNodeClass.propertyNode: _propertyNode,
  LvNodeClass.invokeNode: _invokeNode,
  LvNodeClass.localVariable: _localVariable,
  LvNodeClass.registerForEvents: _registerForEvents,
};

final Map<int, LvLowering> kLvPrimResIdLowerings = {kLvRotatePrimResId: _rotate};

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

  exclusiveOr(4, 'Exclusive OR');

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
  if (call.refusal case final reason?) return reason;
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
    if (call.nodeFlags == null) {
      return 'Bundle/Unbundle By Name (class 0x${call.classCode.toRadixString(16)}) carries no '
          'flags word, and [kLvByNameUnbundlesBit] is the only reading that separates the two';
    }
    final unbundles = (call.nodeFlags! & kLvByNameUnbundlesBit) != 0;
    final members = unbundles ? call.outputs : call.inputs;
    final cluster = (unbundles ? call.inputs : call.outputs).firstOrNull?.type;
    final shape = cluster == null ? null : _ClusterShape.of(cluster);
    return '${unbundles ? 'Unbundle' : 'Bundle'} By Name (class '
        '0x${call.classCode.toRadixString(16)}) does not resolve its members: '
        '${shape == null ? 'its cluster wire carries no class or named record, and' : 'against ${shape.dartType},'} '
        '${members.where((terminal) => terminal.memberName == null).length} of ${members.length} '
        'member terminals name no member on their own record';
  }
  if (nodeClass == LvNodeClass.compoundArithmetic) {
    final mode = LvCompoundMode.ofNodeFlags(call.nodeFlags);
    if (mode == null || !kLvLoweredCompoundModes.containsKey(mode)) {
      final selects = call.nodeFlags == null
          ? 'no mode, carrying no flags word'
          : 'mode ${(call.nodeFlags! >> 16) & 0x7}';
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
  if (call.inputs.any((operand) => operand.type.carrier != out.type.carrier)) return null;
  final name = out.expression;
  if (name == null) return const [];
  final body = '${call.inputs[0].expression} $operator ${call.inputs[1].expression}';
  return ['final ${out.type.dartType} $name = ${lvWrapped(out.type, body)};'];
}

List<String>? _swap(LvPrimCall call, String runtimeCall, {required int fieldPairBits}) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  final kind = out.type.numeric;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  if (kind == null || kind.isFloat || kind.bits < fieldPairBits) return null;
  if (source.type.numeric != kind) return null;
  final name = out.expression;
  if (name == null) return const [];
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
  if (name == null) return const [];
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
  if (count.type.dims != 0 || count.type.numeric == null || count.type.numeric!.isFloat) return null;
  final name = out.expression;
  if (name == null) return const [];
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
    if (typed.length == 1) {
      value = call.inputs.firstWhere((operand) => !identical(operand, typed.single));
    } else {
      final operands = call.inputsTopDown;
      if (operands == null || !_sameWireType(operands[0].type, out.type)) return null;
      value = operands[1];
    }
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
  if (name == null) return const [];
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
    if (operand.type.carrier == LvCarrier.refnum) {
      return '${LvRuntimeCall.flatOfInt}(${operand.expression}.id, $kLvRefnumBits)';
    }
    if (kind == null) return null;
    final call = kind.isFloat ? LvRuntimeCall.flatOfFloat : LvRuntimeCall.flatOfInt;
    return '$call(${operand.expression}, ${kind.bits})';
  }
  if (operand.type.dims != 1 || kind == null || kind.isFloat) return null;
  return '${LvRuntimeCall.flatOfIntList}(${operand.expression}, ${kind.bits})';
}

/// The width of a flattened reference.
const int kLvRefnumBits = 32;

String? _valueOfFlat(LvWireType type, String bytes) {
  final kind = type.numeric;
  if (type.dims == 0) {
    if (type.carrier == LvCarrier.text) return '${LvRuntimeCall.stringOfFlat}($bytes)';
    if (type.carrier == LvCarrier.refnum) {
      return '${LvRuntimeType.refnum}(${LvRuntimeCall.intOfFlat}($bytes, $kLvRefnumBits))';
    }
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
        pieces.add(operand.expression!);
      case _:
        return null;
    }
  }
  final name = out.expression;
  if (name == null) return const [];
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
  if (name == null) return const [];
  final operands = [for (final operand in ordered) operand.expression];
  final joined = operands.length == 1 ? operands.single : "'${operands.map(_interpolated).join()}'";
  return ['final String $name = $joined;'];
}

const int kLvFormatFixedTerminalBit = 0x10000;

const int kLvFormatFixedRightTerminal = kLvFormatFixedTerminalBit | 1;

/// Format Into String with a constant format, expanded here: the fixed terminals (format string,
/// initial string and error in on the left; resulting string and error out on the right) carry
/// [kLvFormatFixedTerminalBit] in their role flags and read by drawn row, then by port within a
/// row; the arguments carry none and read the same way. Each specifier spells its argument by conversion: `%s` a string or
/// a boolean as `TRUE`/`FALSE`, `%d` an integer or a boolean as `1`/`0`, `%x`/`%X` an integer at
/// its own width, `%f` a float or an integer. The error passes through.
List<String>? _formatIntoString(LvPrimCall call) {
  final fixedLeft = <int>[], fixedRight = <int>[], arguments = <int>[];
  final wired = {for (final operand in call.inputs) operand.port: operand};
  final consumed = {for (final result in call.outputs) result.port: result};
  for (final port in [...wired.keys, ...call.outputPorts]) {
    final flags = call.portRoleFlags[port] ?? wired[port]?.roleFlags ?? 0;
    switch (flags) {
      case 0:
        arguments.add(port);
      case kLvFormatFixedTerminalBit:
        fixedLeft.add(port);
      case kLvFormatFixedRightTerminal:
        fixedRight.add(port);
      case _:
        return null;
    }
  }
  List<int> rowsThenPorts(List<int> ports) => [...ports]
    ..sort((a, b) {
      final rows = (call.portDrawnTop[a] ?? 0).compareTo(call.portDrawnTop[b] ?? 0);
      return rows != 0 ? rows : a.compareTo(b);
    });
  final left = rowsThenPorts(fixedLeft), right = rowsThenPorts(fixedRight), order = rowsThenPorts(arguments);
  if (left.length != 3 || right.length != 2) return null;
  final [formatPort, initialPort, errorInPort] = left;
  final [resultPort, errorOutPort] = right;
  final formatTerminal = wired[formatPort];
  final format = formatTerminal == null ? _defaultFormat(wired, order) : formatTerminal.constantText;
  if (format == null) return null;
  final pieces = lvFormatPieces(format);
  if (pieces == null) return null;
  final initial = wired[initialPort], errorIn = wired[errorInPort];
  if (initial != null && (initial.type.dims != 0 || initial.type.carrier != LvCarrier.text)) return null;
  final operands = <LvPrimTerminal>[];
  for (final port in order) {
    final operand = wired[port];
    if (operand == null || operand.type.dims != 0) return null;
    operands.add(operand);
  }
  final result = consumed[resultPort], errorOut = consumed[errorOutPort];
  if (result != null && (result.type.dims != 0 || result.type.carrier != LvCarrier.text)) return null;
  if (errorOut != null && !errorOut.type.isErrorCluster) return null;
  final lines = <String>[];
  if (errorOut != null) {
    call.requireImport(kLvRuntimeImport);
    lines.add(
      'final ${LvRuntimeType.error} ${errorOut.expression} = ${errorIn?.expression ?? LvRuntimeType.clearedError};',
    );
  }
  if (result == null) return lines;
  final text = StringBuffer("'");
  if (initial != null) text.write(_interpolated(initial.expression));
  var next = 0;
  for (final piece in pieces) {
    switch (piece) {
      case LvFormatLiteral(text: final chunk):
        final literal = lvDartStringLiteral(chunk);
        text.write(literal.substring(1, literal.length - 1));
      case LvFormatSpecifier():
        final index = piece.argument ?? next;
        if (index < 0 || index >= operands.length) return null;
        next = index + 1;
        final spelled = _formatted(piece, operands[index], call);
        if (spelled == null) return null;
        text.write(spelled);
    }
  }
  text.write("'");
  lines.add('final String ${result.expression} = $text;');
  return lines;
}

/// The format an unwired format string defaults to, which the reference says matches the
/// argument's data type: `%d` for one integer argument, `%s` for one string; null for any other
/// argument list, whose default the reference does not spell.
String? _defaultFormat(Map<int, LvPrimTerminal> wired, List<int> order) {
  if (order.length != 1) return null;
  final operand = wired[order.single];
  if (operand == null || operand.type.dims != 0) return null;
  if (operand.type.carrier == LvCarrier.text) return '%s';
  final kind = operand.type.numeric;
  return kind != null && !kind.isFloat ? '%d' : null;
}

/// How [spec] spells [operand] inside the resulting string's interpolation.
String? _formatted(LvFormatSpecifier spec, LvPrimTerminal operand, LvPrimCall call) {
  final kind = operand.type.numeric;
  final carrier = operand.type.carrier;
  final padding = [
    if (spec.width case final width?) 'width: $width',
    if (spec.zeroPad) 'zeroPad: true',
    if (spec.leftJustify) 'leftJustify: true',
  ];
  final signing = [if (spec.plusSign) 'plusSign: true'];
  String interpolate(String runtimeCall, String value, List<String> named) {
    call.requireImport(kLvRuntimeImport);
    return '\${$runtimeCall(${[value, ...named].join(', ')})}';
  }

  switch (spec.conversion) {
    case LvFormatConversion.text:
      if (spec.plusSign || spec.zeroPad) return null;
      final String value;
      if (carrier == LvCarrier.text) {
        value = operand.expression!;
      } else if (carrier == LvCarrier.boolean) {
        value = "(${operand.expression} ? 'TRUE' : 'FALSE')";
      } else {
        return null;
      }
      if (spec.width == null && spec.precision == null) return _interpolated(value);
      return interpolate(LvRuntimeCall.formatText, value, [
        ...padding,
        if (spec.precision case final precision?) 'maxLength: $precision',
      ]);
    case LvFormatConversion.decimal:
      if (spec.precision != null) return null;
      final String value;
      if (kind != null && !kind.isFloat) {
        value = operand.expression!;
      } else if (carrier == LvCarrier.boolean) {
        value = '(${operand.expression} ? 1 : 0)';
      } else {
        return null;
      }
      if (padding.isEmpty && signing.isEmpty) return _interpolated(value);
      return interpolate(LvRuntimeCall.formatInt, value, [...padding, ...signing]);
    case LvFormatConversion.hexadecimal || LvFormatConversion.hexadecimalUpper:
      if (kind == null || kind.isFloat || spec.precision != null || spec.plusSign) return null;
      return interpolate(LvRuntimeCall.formatRadix, operand.expression!, [
        '16',
        '${kind.bits}',
        ...padding,
        if (spec.conversion == LvFormatConversion.hexadecimalUpper) 'upper: true',
      ]);
    case LvFormatConversion.fixed:
      if (kind == null) return null;
      final value = kind.isFloat ? operand.expression! : '${operand.expression}.toDouble()';
      return interpolate(LvRuntimeCall.formatFixed, value, [
        '${spec.precision ?? kLvFormatDefaultPrecision}',
        ...padding,
        ...signing,
      ]);
  }
}

/// Digits after the point when a `%f` names no precision.
const int kLvFormatDefaultPrecision = 6;

/// The members of the runtime's error cluster, as `LvError` declares them.
final List<LvDeclField> _errorClusterFields = [
  const LvDeclField(label: 'status', type: LvTypeMapping.mapped(LvCarrier.boolean)),
  const LvDeclField(
    label: 'code',
    type: LvTypeMapping.mapped(LvCarrier.integer, numeric: LvNumericKind.i32),
  ),
  const LvDeclField(label: 'source', type: LvTypeMapping.mapped(LvCarrier.text)),
];

/// A cluster wire's members as Dart spells them: a declared class's fields, the named fields
/// of the record an anonymous cluster is carried as, or the runtime error cluster's.
class _ClusterShape {
  _ClusterShape._(this.dartType, this.fields, this.names, {required this.isRecord});

  final String dartType;

  final List<LvDeclField> fields;

  /// Each field's Dart name.
  final List<String> names;

  final bool isRecord;

  static _ClusterShape? of(LvWireType type) {
    if (type.dims != 0) return null;
    if (type.isErrorCluster) {
      return _ClusterShape._(
        LvRuntimeType.error,
        _errorClusterFields,
        [for (final field in _errorClusterFields) field.label!],
        isRecord: false,
      );
    }
    if (type.declarations.length == 1 && type.declarations.single.name == type.dartType) {
      final declaration = type.declarations.single;
      if (declaration.isEnum || declaration.allFields.isEmpty) return null;
      return _ClusterShape._(declaration.name, declaration.allFields, declaration.allFieldNames, isRecord: false);
    }
    final fields = type.value.fields;
    if (fields.isEmpty || type.dartType == null || !type.dartType!.startsWith('({')) return null;
    return _ClusterShape._(
      type.dartType!,
      fields,
      [for (final field in fields) lvFieldName(field.label ?? '')],
      isRecord: true,
    );
  }

  int? soleFieldIndex(String? label) {
    if (label == null) return null;
    int? found;
    for (var i = 0; i < fields.length; i++) {
      if (fields[i].label != label) continue;
      if (found != null) return null;
      found = i;
    }
    return found;
  }

  bool memberMatches(int index, LvWireType wire) {
    final type = fields[index].type;
    return type.isMapped && type.dartType == wire.dartType;
  }
}

List<String>? _unbundle(LvPrimCall call) {
  if (call.inputs.length != 1) return null;
  final source = call.inputs.single;
  final shape = _ClusterShape.of(source.type);
  if (shape == null) return null;
  final ordered = call.portsTopDown(call.outputPorts);
  if (ordered == null || ordered.length != shape.fields.length) return null;
  final statements = <String>[];
  for (var i = 0; i < ordered.length; i++) {
    final result = LvPrimCall._terminalAt(call.outputs, ordered[i]);
    if (result == null) continue;
    if (!shape.memberMatches(i, result.type)) return null;
    if (result.memberName != null && result.memberName != shape.fields[i].label) return null;
    statements.add(
      'final ${shape.fields[i].type.dartType} ${result.expression} = ${source.expression}.${shape.names[i]};',
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
  final shape = _ClusterShape.of(source.type);
  if (shape == null) return null;
  final statements = <String>[];
  for (final result in call.outputs) {
    final index = shape.soleFieldIndex(result.memberName);
    if (index == null || !shape.memberMatches(index, result.type)) return null;
    statements.add(
      'final ${shape.fields[index].type.dartType} ${result.expression} = ${source.expression}.${shape.names[index]};',
    );
  }
  return statements;
}

List<String>? _bundleByName(LvPrimCall call) {
  if (call.outputs.length != 1 || !call.hasSoleSourceTerminal) return null;
  final result = call.outputs.single;
  final shape = _ClusterShape.of(result.type);
  if (shape == null) return null;
  final written = <int, LvPrimTerminal>{};
  final bases = <LvPrimTerminal>[];
  for (final operand in call.inputs) {
    final index = shape.soleFieldIndex(operand.memberName);
    if (index == null) {
      bases.add(operand);
      continue;
    }
    if (written.containsKey(index) || !shape.memberMatches(index, operand.type)) return null;
    written[index] = operand;
  }
  if (bases.length != 1 || written.isEmpty) return null;
  final base = bases.single;
  if (base.type.dartType != shape.dartType) return null;
  final name = result.expression;
  if (name == null) return const [];
  final statements = <String>[];
  var carrier = base.expression!;
  if (!lvIsAtomic(carrier) && written.length < shape.fields.length) {
    final local = call.names.wire(base.type);
    statements.add('final ${shape.dartType} $local = $carrier;');
    carrier = local;
  }
  final arguments = [
    for (var i = 0; i < shape.fields.length; i++)
      '${shape.names[i]}: ${written[i]?.expression ?? '$carrier.${shape.names[i]}'}',
  ];
  final value = shape.isRecord ? '(${arguments.join(', ')})' : '${shape.dartType}(${arguments.join(', ')})';
  return statements..add('final ${shape.dartType} $name = $value;');
}

List<String>? _mergeErrors(LvPrimCall call) {
  if (call.outputs.length != 1 || !call.hasSoleSourceTerminal || call.inputs.length < 2) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final result = call.outputs.single;
  if (!result.type.isErrorCluster || ordered.any((operand) => !operand.type.isErrorCluster)) return null;
  final name = result.expression;
  if (name == null) return const [];
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
  if (source.type.dims != 0 || result.type.dims != 0 || result.type.carrier != LvCarrier.boolean) return null;
  final name = result.expression;
  if (name == null) return const [];
  switch (source.type.carrier) {
    case LvCarrier.float:
      return ['final bool $name = ${source.expression}.isNaN;'];
    case LvCarrier.path:
      return ['final bool $name = !${source.expression}.valid;'];
    case LvCarrier.refnum:
      call.requireImport(kLvRuntimeImport);
      return ['final bool $name = ${LvRuntimeCall.notARefnum}(${source.expression});'];
    case _:
      return null;
  }
}

List<String>? _randomNumber(LvPrimCall call) {
  if (call.inputs.isNotEmpty || call.outputs.length > 1) return null;
  final out = call.outputs.singleOrNull;
  if (out == null) return const [];
  if (out.type.dims != 0 || !(out.type.numeric?.isFloat ?? false)) return null;
  call.requireImport(kLvRuntimeImport);
  return ['final double ${out.expression} = ${LvRuntimeCall.randomNumber}();'];
}

/// Search 1D Array's terminals top-down: the array, the element and an optional start index on
/// the left, the index of the element on the right; an unwired start index is among
/// [LvPrimCall.outputPorts] with role flags 0. Elements compare as text, booleans, integers or
/// paths; other kinds are not decided.
List<String>? _search1dArray(LvPrimCall call) {
  if (call.outputs.length > 1) return null;
  final left = [for (final operand in call.inputs) operand.port];
  final right = <int>[];
  for (final port in call.outputPorts) {
    switch (call.portRoleFlags[port] ?? 0) {
      case 0:
        left.add(port);
      case 1:
        right.add(port);
      case _:
        return null;
    }
  }
  final operands = call.portsTopDown(left);
  if (operands == null || operands.length < 2 || operands.length > 3 || right.length != 1) return null;
  final wired = {for (final operand in call.inputs) operand.port: operand};
  final array = wired[operands[0]], element = wired[operands[1]];
  final start = operands.length == 3 ? wired[operands[2]] : null;
  if (array == null || element == null) return null;
  if (array.type.dims != 1 || element.type.dims != 0) return null;
  final carrier = element.type.carrier;
  final numeric = element.type.numeric;
  final comparable =
      carrier == LvCarrier.text ||
      carrier == LvCarrier.boolean ||
      carrier == LvCarrier.path ||
      (numeric != null && !numeric.isFloat);
  if (!comparable || array.type.element.dartType != element.type.dartType) return null;
  if (start != null && (start.type.dims != 0 || start.type.numeric == null || start.type.numeric!.isFloat)) return null;
  final out = call.outputs.singleOrNull;
  if (out == null) return const [];
  if (out.type.dims != 0 || out.type.numeric == null || out.type.numeric!.isFloat) return null;
  call.requireImport(kLvRuntimeImport);
  final arguments = [array.expression, element.expression, if (start != null) start.expression];
  return ['final int ${out.expression} = ${LvRuntimeCall.search1dArray}(${arguments.join(', ')});'];
}

/// Build Path's terminals top-down: the base path, then a name (text) or relative path.
List<String>? _buildPath(LvPrimCall call) {
  if (call.inputs.length != 2 || call.outputs.length > 1 || !call.hasSoleSourceTerminal) return null;
  final operands = call.inputsTopDown;
  if (operands == null) return null;
  final [base, name] = operands;
  if (base.type.dims != 0 || base.type.carrier != LvCarrier.path) return null;
  if (name.type.dims != 0 || (name.type.carrier != LvCarrier.text && name.type.carrier != LvCarrier.path)) return null;
  final out = call.outputs.singleOrNull;
  if (out == null) return const [];
  if (out.type.dims != 0 || out.type.carrier != LvCarrier.path) return null;
  call.requireImport(kLvRuntimeImport);
  return [
    'final ${LvRuntimeType.path} ${out.expression} = ${LvRuntimeCall.buildPath}(${base.expression}, ${name.expression});',
  ];
}

String _interpolated(String? expression) =>
    RegExp(r'^[A-Za-z_]\w*$').hasMatch(expression!) ? '\$$expression' : '\${$expression}';

List<String>? _elementwise(LvPrimCall call) {
  if (call.op == null && !kLvPrimResIdLowerings.containsKey(call.primResId)) return null;
  if (call.op == PrimOp.typeCast || call.inputs.isEmpty) return null;
  final terminals = [...call.inputs, ...call.outputs];
  if (terminals.any((terminal) => terminal.type.dims != 1)) return null;

  final prologue = <String>[];
  final arrayOf = <int, String>{};
  for (final operand in call.inputs) {
    final expression = operand.expression!;
    if (lvIsAtomic(expression)) {
      arrayOf[operand.port] = expression;
      continue;
    }
    final local = call.names.wire(operand.type);
    prologue.add('final ${operand.type.dartType} $local = $expression;');
    arrayOf[operand.port] = local;
  }

  final index = call.names.loopIndex();
  final scalarOf = <int, String>{};
  final scalar = LvPrimCall(
    op: call.op,
    primResId: call.primResId,
    classCode: call.classCode,
    inputs: [
      for (final operand in call.inputs)
        LvPrimTerminal(
          port: operand.port,
          type: operand.type.scalar,
          roleFlags: operand.roleFlags,
          expression: '${arrayOf[operand.port]}[$index]',
        ),
    ],
    outputs: [
      for (final result in call.outputs)
        LvPrimTerminal(
          port: result.port,
          type: result.type.scalar,
          roleFlags: result.roleFlags,
          expression: scalarOf[result.port] = call.names.wire(result.type.scalar),
        ),
    ],
    outputPorts: call.outputPorts,
    ports: call.ports,
    portMemberName: call.portMemberName,
    portRoleFlags: call.portRoleFlags,
    portDrawnTop: call.portDrawnTop,
    requireImport: call.requireImport,
    names: call.names,
    nodeFlags: call.nodeFlags,
  );
  final body = _lowerDirect(scalar);
  if (body == null) return null;

  final builderOf = <int, String>{};
  final statements = [...prologue];
  for (final result in call.outputs) {
    final builder = call.names.role(LvNameRole.builder);
    builderOf[result.port] = builder;
    statements.add('final ${lvArrayBuilderType(result.type.element)} $builder = <${result.type.element.dartType}>[];');
  }
  final lengths = [for (final operand in call.inputs) '${arrayOf[operand.port]}.length'];
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
    ..addAll([for (final result in call.outputs) '${builderOf[result.port]}.add(${scalarOf[result.port]});'])
    ..add('}');
  for (final result in call.outputs) {
    if (result.type.numeric != null) call.requireImport('dart:typed_data');
    final frozen = lvArrayFreeze(result.type.element, builderOf[result.port]!);
    statements.add('final ${result.type.dartType} ${result.expression} = $frozen;');
  }
  return statements;
}

const Set<LvCarrier> _kValueEqualityCarriers = {LvCarrier.integer, LvCarrier.float, LvCarrier.boolean, LvCarrier.text};

List<String>? _binaryPredicate(LvPrimCall call, String operator) {
  if (call.inputs.length != 2 || call.outputs.length != 1) return null;
  final left = call.inputs[0], right = call.inputs[1], out = call.outputs.single;
  if (left.type.dims != 0 || right.type.dims != 0) return null;
  if (left.type.enumeration == null || left.type.dartType != right.type.dartType) {
    if (!_kValueEqualityCarriers.contains(left.type.carrier)) return null;
    if (left.type.carrier != right.type.carrier) return null;
  }
  if (out.type.carrier != LvCarrier.boolean) return null;
  final name = out.expression;
  if (name == null) return const [];
  return ['final bool $name = ${left.expression} $operator ${right.expression};'];
}

List<String>? _comparedToZero(LvPrimCall call, String operator) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || source.type.numeric == null) return null;
  if (_hazardous(source.type, operator)) return null;
  if (out.type.carrier != LvCarrier.boolean) return null;
  final name = out.expression;
  if (name == null) return const [];
  final zero = source.type.numeric!.isFloat ? '0.0' : '0';
  return ['final bool $name = ${source.expression} $operator $zero;'];
}

List<String>? _isEmpty(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || out.type.carrier != LvCarrier.boolean) return null;
  if (source.type.carrier != LvCarrier.text && source.type.carrier != LvCarrier.path) return null;
  final name = out.expression;
  if (name == null) return const [];
  return ['final bool $name = ${source.expression}.isEmpty;'];
}

List<String>? _reverse1dArray(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 1 || out.type.dims != 1) return null;
  if (source.type.dartType != out.type.dartType) return null;
  final name = out.expression;
  if (name == null) return const [];
  if (out.type.numeric != null) call.requireImport('dart:typed_data');
  final reversed = lvArrayFreeze(out.type.element, '${source.expression}.reversed.toList()');
  return ['final ${out.type.dartType} $name = $reversed;'];
}

List<String>? _emptyArray(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 1 || out.type.dims != 0 || out.type.carrier != LvCarrier.boolean) return null;
  final name = out.expression;
  if (name == null) return const [];
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
  if (name == null) return const [];
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
  if (name == null) return const [];
  return ['final ${result.dartType} $name = ${source.expression}.$member;'];
}

List<String>? _arraySize(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 1 || out.type.dims != 0) return null;
  if (out.type.numeric == null || out.type.numeric!.isFloat) return null;
  final name = out.expression;
  if (name == null) return const [];
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
    if (name == null) return const [];
    return ['final bool $name = !${source.expression};'];
  }
  final kind = out.type.numeric;
  if (kind == null || kind.isFloat) return null;
  if (name == null) return const [];
  return ['final int $name = ${lvWrapped(out.type, '~${source.expression}')};'];
}

/// Increment and Decrement: the wrapped sum on a numeric, and on an enum the next or previous
/// item, wrapping past either end as the reference states.
List<String>? _unaryNumeric(LvPrimCall call, String suffix) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  final name = out.expression;
  if (out.type.enumeration case final enumeration? when source.type.dartType == out.type.dartType) {
    if (name == null) return const [];
    final items = '${enumeration.name}.values';
    return ['final ${enumeration.name} $name = $items[(${source.expression}.index $suffix) % $items.length];'];
  }
  if (out.type.numeric == null) return null;
  if (name == null) return const [];
  final body = '${source.expression} $suffix';
  return ['final ${out.type.dartType} $name = ${lvWrapped(out.type, body)};'];
}

List<String>? _integerConversion(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  final target = out.type.numeric;
  if (target == null || target.isFloat) return null;
  final fromEnum = source.type.enumeration != null;
  if (!fromEnum && (source.type.numeric == null || source.type.numeric!.isFloat)) return null;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  final name = out.expression;
  if (name == null) return const [];
  call.requireImport(kLvRuntimeImport);
  final value = fromEnum ? '${source.expression}.index' : source.expression;
  return ['final int $name = ${LvRuntimeCall.integerConversion(target)}($value);'];
}

List<String>? _floatConversion(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  final target = out.type.numeric, from = source.type.numeric;
  if (target == null || !target.isFloat || from == null) return null;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  if (_hazardous(source.type, 'toDouble')) return null;
  final name = out.expression;
  if (name == null) return const [];
  if (target == LvNumericKind.sgl) call.requireImport('dart:typed_data');
  final widened = from.isFloat ? source.expression! : '${source.expression}.toDouble()';
  return ['final double $name = ${lvWrapped(out.type, widened)};'];
}

List<String>? _byteArrayConversion(LvPrimCall call, {required bool encode}) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (encode && (source.type.dims != 0 || out.type.dims != 1)) return null;
  if (!encode && (source.type.dims != 1 || out.type.dims != 0)) return null;
  if (out.type.numeric != null && out.type.numeric != LvNumericKind.u8) return null;
  final name = out.expression;
  if (name == null) return const [];
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
  if (rotated.expression == null && carryOut.expression == null) return const [];
  call.requireImport(kLvRuntimeImport);
  final rotate = left ? LvRuntimeCall.rotateLeftWithCarry : LvRuntimeCall.rotateRightWithCarry;
  return [
    'final (${rotated.expression ?? '_'}, ${carryOut.expression ?? '_'}) = '
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
    if (name == null) return null;
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
  if (name == null) return const [];
  if (element.type.dartType != out.type.element.dartType || array.type.dartType != out.type.dartType) return null;
  final storage = out.type.elementListType;
  final copy = out.type.numeric == null ? '$storage.of' : '$storage.fromList';
  return ['final $storage $name = $copy(${array.expression})..[${index.expression}] = ${element.expression};'];
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
  if (name == null) return const [];
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
  if (size.type.dims != 0 || size.type.numeric == null || size.type.numeric!.isFloat) return null;
  final name = out.expression;
  if (name == null) return const [];
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
    if (count.type.dims != 0 || count.type.numeric == null || count.type.numeric!.isFloat) return null;
    if (_hazardous(count.type, '<')) return null;
  }
  final name = out.expression;
  if (name == null) return const [];
  call.requireImport(kLvRuntimeImport);
  final arguments = [string.expression, offset.expression, if (length != null) length.expression];
  return ['final String $name = ${LvRuntimeCall.stringSubset}(${arguments.join(', ')});'];
}

/// Match Pattern's terminals, top-down on each side: string, regular expression and an optional
/// offset on the left; before, match and after substrings and the offset past the match on the
/// right. An unwired left terminal is among [LvPrimCall.outputPorts] with role flags 0, a right
/// one with role flags 1.
List<String>? _matchPattern(LvPrimCall call) {
  final left = <int>[], right = <int>[];
  for (final operand in call.inputs) {
    if (operand.roleFlags != 0) return null;
    left.add(operand.port);
  }
  for (final port in call.outputPorts) {
    switch (call.portRoleFlags[port] ?? 0) {
      case 0:
        left.add(port);
      case 1:
        right.add(port);
      case _:
        return null;
    }
  }
  final operands = call.portsTopDown(left), results = call.portsTopDown(right);
  if (operands == null || results == null || operands.length < 2 || operands.length > 3 || results.length != 4) {
    return null;
  }
  final wired = {for (final operand in call.inputs) operand.port: operand};
  final consumed = {for (final result in call.outputs) result.port: result};
  final string = wired[operands[0]], pattern = wired[operands[1]];
  final offset = operands.length == 3 ? wired[operands[2]] : null;
  if (string == null || pattern == null) return null;
  final texts = [string, pattern, for (final port in results.take(3)) consumed[port]];
  for (final text in texts) {
    if (text != null && (text.type.dims != 0 || text.type.carrier != LvCarrier.text)) return null;
  }
  final past = consumed[results[3]];
  for (final count in [offset, past]) {
    final kind = count?.type.numeric;
    if (count == null) continue;
    if (count.type.dims != 0 || kind == null || kind.isFloat) return null;
  }
  if (past != null && (!past.type.numeric!.signed || past.type.numeric!.bits < 32)) return null;
  final [before, match, after] = [for (final port in results.take(3)) consumed[port]?.expression];
  if (before == null && match == null && after == null && past == null) return const [];
  call.requireImport(kLvRuntimeImport);
  final arguments = [string.expression, pattern.expression, if (offset != null) offset.expression];
  return [
    'final (before: ${before ?? '_'}, match: ${match ?? '_'}, after: ${after ?? '_'}, '
        'offsetPastMatch: ${past?.expression ?? '_'}) = ${LvRuntimeCall.matchPattern}(${arguments.join(', ')});',
  ];
}

List<String>? _toLowerCase(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || source.type.carrier != LvCarrier.text) return null;
  if (out.type.dims != 0 || out.type.carrier != LvCarrier.text) return null;
  final name = out.expression;
  if (name == null) return const [];
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
  final name = out?.expression;
  return [if (name == null) '$wait;' else 'final ${out!.type.dartType} $name = $wait;'];
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
  if (count.type.dims != 0 || count.type.numeric == null || count.type.numeric!.isFloat) return null;
  final name = out.expression;
  if (name == null) return const [];
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
  if (width.type.dims != 0 || width.type.numeric == null || width.type.numeric!.isFloat) return null;
  final name = out.expression;
  if (name == null) return const [];
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

/// Bundle's terminals in heap child order: the output cluster, the input cluster, then one
/// element per member of the output cluster in member order; an unwired element takes the
/// member of the input cluster.
List<String>? _bundle(LvPrimCall call) {
  if (call.ports.length < 3 || call.outputPorts.isEmpty) return null;
  final out = call.outputs.where((terminal) => terminal.port == call.ports[0]).firstOrNull;
  final consumedElsewhere = call.outputs.any((terminal) => terminal.port != call.ports[0]);
  if (consumedElsewhere) return call.refuse('Bundle (class 0x34) reads a terminal other than its output cluster');
  if (out == null) return const [];
  final shape = _ClusterShape.of(out.type);
  if (shape == null) {
    return call.refuse('Bundle (class 0x34) assembles ${out.type.dartType ?? '?'}, which resolves no members');
  }
  final elements = call.ports.sublist(2);
  if (elements.length != shape.fields.length) {
    return call.refuse(
      'Bundle (class 0x34) draws ${elements.length} element terminals for a cluster of ${shape.fields.length} members',
    );
  }
  final wired = {for (final operand in call.inputs) operand.port: operand};
  final base = wired[call.ports[1]];
  if (base != null && base.type.dartType != shape.dartType) {
    return call.refuse('Bundle (class 0x34) replaces members of ${base.type.dartType}, not of ${shape.dartType}');
  }
  final statements = <String>[];
  var carrier = base?.expression;
  final readsBase = elements.any((port) => !wired.containsKey(port));
  if (carrier != null && readsBase && !lvIsAtomic(carrier)) {
    final local = call.names.wire(base!.type);
    statements.add('final ${shape.dartType} $local = $carrier;');
    carrier = local;
  }
  final arguments = <String>[];
  for (var i = 0; i < elements.length; i++) {
    final operand = wired[elements[i]];
    if (operand == null) {
      if (carrier == null) {
        return call.refuse('Bundle (class 0x34) leaves element $i unwired with no input cluster to take it from');
      }
      arguments.add('${shape.names[i]}: $carrier.${shape.names[i]}');
      continue;
    }
    if (!shape.memberMatches(i, operand.type)) {
      return call.refuse(
        'Bundle (class 0x34) wires ${operand.type.dartType ?? '?'} into member ${shape.fields[i].label ?? i} '
        'of ${shape.dartType}, whose type is ${shape.fields[i].type.dartType}',
      );
    }
    arguments.add('${shape.names[i]}: ${operand.expression}');
  }
  final value = shape.isRecord ? '(${arguments.join(', ')})' : '${shape.dartType}(${arguments.join(', ')})';
  return statements..add('final ${shape.dartType} ${out.expression} = $value;');
}

int _roleOf(LvPrimCall call, int port) => (call.portRoleFlags[port] ?? 0) & ~LvArrayTerminalRole.unwiredDefault;

LvPrimTerminal? _wiredAt(LvPrimCall call, int port) =>
    [...call.inputs, ...call.outputs].where((terminal) => terminal.port == port).firstOrNull;

/// Delete From Array over a 1-D array: terminals by role, the deleted portion an array when a
/// length is wired and the one element when it is not.
List<String>? _deleteFromArray(LvPrimCall call) {
  final array = call.inputWithRole(LvArrayTerminalRole.array);
  if (array == null) return call.refuse('Delete From Array (class 0xbd) has its array unwired');
  if (array.type.dims != 1) {
    return call.refuse('Delete From Array (class 0xbd) over a ${array.type.dims}-dimensional array is not modelled');
  }
  LvPrimTerminal? index, length, remaining, deleted;
  for (final port in call.ports) {
    final role = _roleOf(call, port);
    final terminal = _wiredAt(call, port);
    if (role == LvArrayTerminalRole.array) continue;
    if (role == LvArrayTerminalRole.singleIndex) {
      index = terminal;
    } else if (role == LvArrayTerminalRole.newElement) {
      length = terminal;
    } else if (role == LvArrayTerminalRole.output) {
      remaining = terminal;
    } else if (role == LvArrayTerminalRole.grownOutput) {
      deleted = terminal;
    } else {
      return call.refuse('Delete From Array (class 0xbd) carries role bits 0x${role.toRadixString(16)}, not decoded');
    }
  }
  for (final count in [index, length]) {
    if (count != null && (count.type.dims != 0 || count.type.numeric == null || count.type.numeric!.isFloat)) {
      return call.refuse('Delete From Array (class 0xbd) takes an integer index and length');
    }
  }
  if (remaining == null && deleted == null) return const [];
  call.requireImport(kLvRuntimeImport);
  if (array.type.numeric != null) call.requireImport('dart:typed_data');
  final element = array.type.element;
  final result = call.names.role(LvNameRole.value);
  final indexArgument = index == null ? '' : ', ${index.expression}';
  if (length == null) {
    if (deleted != null && deleted.type.dims != 0) {
      return call.refuse('Delete From Array (class 0xbd) with no length wired deletes one element, not an array');
    }
    return [
      'final $result = ${LvRuntimeCall.deleteFromArrayElement}(${array.expression}$indexArgument);',
      if (remaining != null)
        'final ${remaining.type.dartType} ${remaining.expression} = ${lvArrayFreeze(element, '$result.remaining')};',
      if (deleted != null) 'final ${deleted.type.dartType} ${deleted.expression} = $result.element;',
    ];
  }
  if (deleted != null && deleted.type.dims != 1) {
    return call.refuse('Delete From Array (class 0xbd) with a length wired deletes an array, not one element');
  }
  return [
    'final $result = ${LvRuntimeCall.deleteFromArray}(${array.expression}, '
        '${index == null ? '' : 'index: ${index.expression}, '}length: ${length.expression});',
    if (remaining != null)
      'final ${remaining.type.dartType} ${remaining.expression} = ${lvArrayFreeze(element, '$result.remaining')};',
    if (deleted != null)
      'final ${deleted.type.dartType} ${deleted.expression} = ${lvArrayFreeze(element, '$result.deleted')};',
  ];
}

/// Array Subset over a 1-D array: the array (role 0x10000), the output, then one index and
/// one length terminal; an unwired index reads as zero and an unwired length as the rest.
List<String>? _arraySubset(LvPrimCall call) {
  if (call.ports.length != 4) {
    return call.refuse('Array Subset (class 0x48) with ${call.ports.length} terminals indexes more than one dimension');
  }
  LvPrimTerminal? array, index, length, out;
  for (final port in call.ports) {
    final role = _roleOf(call, port);
    final terminal = _wiredAt(call, port);
    if (role == LvArrayTerminalRole.subsetArray) {
      array = terminal;
    } else if (role == LvArrayTerminalRole.output) {
      out = terminal;
    } else if (role == LvArrayTerminalRole.array) {
      length = terminal;
    } else if (role == 0) {
      index = terminal;
    } else {
      return call.refuse('Array Subset (class 0x48) carries role bits 0x${role.toRadixString(16)}, not decoded');
    }
  }
  if (array == null) return call.refuse('Array Subset (class 0x48) has its array unwired');
  if (array.type.dims != 1) return call.refuse('Array Subset (class 0x48) over a ${array.type.dims}-dimensional array');
  for (final count in [index, length]) {
    if (count != null && (count.type.dims != 0 || count.type.numeric == null || count.type.numeric!.isFloat)) {
      return call.refuse('Array Subset (class 0x48) takes an integer index and length');
    }
  }
  if (out == null) return const [];
  call.requireImport(kLvRuntimeImport);
  if (array.type.numeric != null) call.requireImport('dart:typed_data');
  final arguments = [array.expression, index?.expression ?? '0', if (length != null) length.expression];
  return [
    'final ${out.type.dartType} ${out.expression} = '
        '${lvArrayFreeze(array.type.element, '${LvRuntimeCall.arraySubset}(${arguments.join(', ')})')};',
  ];
}

/// Insert Into Array over a 1-D array: the array, the output, one index and the new element or
/// subarray; an unwired index appends.
List<String>? _insertIntoArray(LvPrimCall call) {
  if (call.ports.length != 4) {
    return call.refuse(
      'Insert Into Array (class 0xbb) with ${call.ports.length} terminals indexes more than one dimension',
    );
  }
  LvPrimTerminal? array, index, element, out;
  for (final port in call.ports) {
    final role = _roleOf(call, port);
    final terminal = _wiredAt(call, port);
    if (role == LvArrayTerminalRole.array) {
      array = terminal;
    } else if (role == LvArrayTerminalRole.output) {
      out = terminal;
    } else if (role == LvArrayTerminalRole.singleIndex) {
      index = terminal;
    } else if (role == LvArrayTerminalRole.newElement) {
      element = terminal;
    } else {
      return call.refuse('Insert Into Array (class 0xbb) carries role bits 0x${role.toRadixString(16)}, not decoded');
    }
  }
  if (array == null || element == null) {
    return call.refuse('Insert Into Array (class 0xbb) has its array or element unwired');
  }
  if (array.type.dims != 1) {
    return call.refuse('Insert Into Array (class 0xbb) over a ${array.type.dims}-dimensional array');
  }
  if (index != null && (index.type.dims != 0 || index.type.numeric == null || index.type.numeric!.isFloat)) {
    return call.refuse('Insert Into Array (class 0xbb) takes an integer index');
  }
  if (element.type.element.dartType != array.type.element.dartType || element.type.dims > 1) {
    return call.refuse('Insert Into Array (class 0xbb) inserts ${element.type.dartType} into ${array.type.dartType}');
  }
  if (out == null) return const [];
  call.requireImport(kLvRuntimeImport);
  if (array.type.numeric != null) call.requireImport('dart:typed_data');
  final inserted = element.type.dims == 1 ? element.expression! : '[${element.expression}]';
  final arguments = [array.expression, inserted, if (index != null) index.expression];
  return [
    'final ${out.type.dartType} ${out.expression} = '
        '${lvArrayFreeze(array.type.element, '${LvRuntimeCall.insertIntoArray}(${arguments.join(', ')})')};',
  ];
}

/// Decimate 1D Array: the array first, then the outputs in order.
List<String>? _decimateArray(LvPrimCall call) {
  if (call.inputs.length != 1 || call.ports.length < 3) return null;
  final array = call.inputs.single;
  if (array.port != call.ports.first || array.type.dims != 1) {
    return call.refuse('Decimate 1D Array (class 0x40) takes a 1-D array on its first terminal');
  }
  final outputs = call.ports.sublist(1);
  if (call.outputs.isEmpty) return const [];
  call.requireImport(kLvRuntimeImport);
  if (array.type.numeric != null) call.requireImport('dart:typed_data');
  final parts = call.names.role(LvNameRole.value);
  final lines = ['final $parts = ${LvRuntimeCall.decimate1dArray}(${array.expression}, ${outputs.length});'];
  for (var i = 0; i < outputs.length; i++) {
    final out = call.outputs.where((terminal) => terminal.port == outputs[i]).firstOrNull;
    if (out == null) continue;
    if (out.type.dartType != array.type.dartType) {
      return call.refuse('Decimate 1D Array (class 0x40) yields ${out.type.dartType} from ${array.type.dartType}');
    }
    lines.add('final ${out.type.dartType} ${out.expression} = ${lvArrayFreeze(array.type.element, '$parts[$i]')};');
  }
  return lines;
}

/// Reshape Array between 1-D and 2-D: the array, the output, then one dimension size per
/// output dimension.
List<String>? _reshapeArray(LvPrimCall call) {
  final array = call.inputWithRole(LvArrayTerminalRole.array);
  final out = call.outputWithRole(LvArrayTerminalRole.output);
  if (array == null) return call.refuse('Reshape Array (class 0x116) has its array unwired');
  if (array.type.dims < 1 || array.type.dims > 2) {
    return call.refuse('Reshape Array (class 0x116) over a ${array.type.dims}-dimensional array is not modelled');
  }
  final sizes = [
    for (final port in call.ports)
      if (_roleOf(call, port) == 0) _wiredAt(call, port),
  ];
  if (sizes.any((size) => size == null)) return call.refuse('Reshape Array (class 0x116) has a dimension size unwired');
  for (final size in sizes) {
    if (size!.type.dims != 0 || size.type.numeric == null || size.type.numeric!.isFloat) {
      return call.refuse('Reshape Array (class 0x116) takes integer dimension sizes');
    }
  }
  if (out == null) return const [];
  if (out.type.dims != sizes.length || out.type.dims < 1 || out.type.dims > 2) {
    return call.refuse(
      'Reshape Array (class 0x116) draws ${sizes.length} sizes for a ${out.type.dims}-dimensional result',
    );
  }
  if (out.type.element.dartType != array.type.element.dartType) {
    return call.refuse('Reshape Array (class 0x116) changes the element type');
  }
  final element = out.type.element;
  final padding = switch (element.carrier) {
    LvCarrier.boolean => 'false',
    LvCarrier.text => "''",
    LvCarrier.integer => '0',
    LvCarrier.float => '0.0',
    _ => null,
  };
  if (padding == null) {
    return call.refuse('Reshape Array (class 0x116) pads with a default this lowering does not spell');
  }
  call.requireImport(kLvRuntimeImport);
  call.requireImport('dart:typed_data');
  final data = array.type.dims == 1 ? array.expression! : '${array.expression}.data';
  final dims = [for (final size in sizes) size!.expression].join(', ');
  final reshaped = lvArrayFreeze(element, '${LvRuntimeCall.reshapeArray}($data, [$dims], $padding)');
  if (out.type.dims == 1) return ['final ${out.type.dartType} ${out.expression} = $reshaped;'];
  return [
    'final ${out.type.dartType} ${out.expression} = '
        '${LvRuntimeType.arrayNd}($reshaped, ${LvRuntimeCall.reshapeDims}([$dims]));',
  ];
}

/// The reference and error terminals every VI Server node opens with: reference in, reference
/// out, error in, error out, in that order.
({LvPrimTerminal? referenceIn, LvPrimTerminal? referenceOut, LvPrimTerminal? errorIn, LvPrimTerminal? errorOut})?
_serverTerminals(LvPrimCall call, String title) {
  if (call.ports.length < 4) {
    call.refuse('$title draws ${call.ports.length} terminals, fewer than its reference and error terminals');
    return null;
  }
  final roles = [for (final port in call.ports.take(4)) call.portRoleFlags[port] ?? 0];
  if (roles[0] & ~LvServerNodeRole.referenceInVariant != LvServerNodeRole.referenceIn ||
      roles[1] != LvServerNodeRole.referenceOut ||
      roles[2] != LvServerNodeRole.errorIn ||
      roles[3] != LvServerNodeRole.errorOut) {
    call.refuse(
      '$title carries role bits ${roles.map((role) => '0x${role.toRadixString(16)}').join('/')} on its first four '
      'terminals, not the reference and error roles',
    );
    return null;
  }
  final terminals = [for (final port in call.ports.take(4)) _wiredAt(call, port)];
  if (terminals[0] != null && !_isRefnumWire(terminals[0]!.type)) {
    call.refuse('$title takes a refnum on its reference terminal');
    return null;
  }
  for (final error in [terminals[2], terminals[3]]) {
    if (error != null && !error.type.isErrorCluster) {
      call.refuse('$title carries ${error.type.dartType} on an error terminal');
      return null;
    }
  }
  return (referenceIn: terminals[0], referenceOut: terminals[1], errorIn: terminals[2], errorOut: terminals[3]);
}

bool _isRefnumWire(LvWireType type) => type.dims == 0 && type.carrier == LvCarrier.refnum;

/// Property Node: the reference and error terminals, then one item per property, each labelled
/// by its record with the property's long name and read or written as it is wired.
List<String>? _propertyNode(LvPrimCall call) {
  final fixed = _serverTerminals(call, 'Property Node (class 0x8c)');
  if (fixed == null) return null;
  final items = <String>[];
  final reads = <(int slot, LvPrimTerminal out)>[];
  for (var i = 4; i < call.ports.length; i++) {
    final port = call.ports[i];
    final name = call.portMemberName[port];
    if (name == null) {
      return call.refuse('Property Node (class 0x8c) carries an item whose property name is not decoded');
    }
    final terminal = _wiredAt(call, port);
    if (terminal == null) continue;
    final literal = lvDartStringLiteral(name);
    if (call.inputs.contains(terminal)) {
      items.add('${LvRuntimeType.propertyItem}.write($literal, ${terminal.expression})');
    } else {
      reads.add((items.length, terminal));
      items.add('${LvRuntimeType.propertyItem}.read($literal)');
    }
  }
  call.requireImport(kLvRuntimeImport);
  final reference = fixed.referenceIn?.expression ?? LvRuntimeType.notARefnum;
  final errorIn = fixed.errorIn?.expression ?? LvRuntimeType.clearedError;
  final invocation = '${LvRuntimeCall.environment}.propertyNode($reference, $errorIn, [${items.join(', ')}])';
  if (fixed.referenceOut == null && fixed.errorOut == null && reads.isEmpty) return ['$invocation;'];
  final node = call.names.role(LvNameRole.value);
  return [
    'final $node = $invocation;',
    if (fixed.referenceOut != null)
      'final ${LvRuntimeType.refnum} ${fixed.referenceOut!.expression} = $node.reference;',
    if (fixed.errorOut != null) 'final ${LvRuntimeType.error} ${fixed.errorOut!.expression} = $node.errorOut;',
    for (final (slot, out) in reads)
      'final ${out.type.dartType} ${out.expression} = $node.values[$slot] as ${out.type.dartType};',
  ];
}

/// Invoke Node: the reference and error terminals, the method name record on each side, then
/// one left and one right terminal per parameter, each labelled with the parameter's name.
List<String>? _invokeNode(LvPrimCall call) {
  final fixed = _serverTerminals(call, 'Invoke Node (class 0xa9)');
  if (fixed == null) return null;
  if (call.ports.length < 6 || (call.ports.length - 6).isOdd) {
    return call.refuse(
      'Invoke Node (class 0xa9) draws ${call.ports.length} terminals, not a method and parameter pairs',
    );
  }
  final methodRoles = [for (final port in call.ports.sublist(4, 6)) call.portRoleFlags[port] ?? 0];
  if (methodRoles[0] != LvServerNodeRole.methodLeft || methodRoles[1] != LvServerNodeRole.methodRight) {
    return call.refuse('Invoke Node (class 0xa9) carries no method name record where one is drawn');
  }
  final method = call.portMemberName[call.ports[4]] ?? call.portMemberName[call.ports[5]];
  if (method == null) return call.refuse('Invoke Node (class 0xa9) names no method');
  final inputs = <String>[];
  final outputs = <(int slot, LvPrimTerminal out)>[];
  for (var i = 6; i < call.ports.length; i += 2) {
    final left = _wiredAt(call, call.ports[i]), right = _wiredAt(call, call.ports[i + 1]);
    if (left != null && !call.inputs.contains(left)) {
      return call.refuse('Invoke Node (class 0xa9) has a parameter wired as a source on its left terminal');
    }
    inputs.add(left?.expression ?? 'null');
    if (right != null) {
      if (!call.outputs.contains(right)) {
        return call.refuse('Invoke Node (class 0xa9) has a parameter wired as a sink on its right terminal');
      }
      outputs.add((inputs.length - 1, right));
    }
  }
  call.requireImport(kLvRuntimeImport);
  final reference = fixed.referenceIn?.expression ?? LvRuntimeType.notARefnum;
  final errorIn = fixed.errorIn?.expression ?? LvRuntimeType.clearedError;
  final invocation =
      '${LvRuntimeCall.environment}.invokeNode($reference, $errorIn, ${lvDartStringLiteral(method)}, '
      '<Object?>[${inputs.join(', ')}])';
  if (fixed.referenceOut == null && fixed.errorOut == null && outputs.isEmpty) return ['$invocation;'];
  final node = call.names.role(LvNameRole.value);
  return [
    'final $node = $invocation;',
    if (fixed.referenceOut != null)
      'final ${LvRuntimeType.refnum} ${fixed.referenceOut!.expression} = $node.reference;',
    if (fixed.errorOut != null) 'final ${LvRuntimeType.error} ${fixed.errorOut!.expression} = $node.errorOut;',
    for (final (slot, out) in outputs)
      'final ${out.type.dartType} ${out.expression} = $node.outputs[$slot] as ${out.type.dartType};',
  ];
}

/// A local variable: one terminal named after its panel control, read as a source or written
/// as a sink.
List<String>? _localVariable(LvPrimCall call) {
  if (call.ports.length != 1) return call.refuse('a local variable (class 0xb6) draws ${call.ports.length} terminals');
  final name = call.portMemberName[call.ports.single];
  if (name == null) return call.refuse('a local variable (class 0xb6) names no panel control');
  final literal = lvDartStringLiteral(name);
  call.requireImport(kLvRuntimeImport);
  if (call.inputs.singleOrNull case final written?) {
    return ['${LvRuntimeCall.environment}.writeLocalVariable($literal, ${written.expression});'];
  }
  final read = call.outputs.singleOrNull;
  if (read == null) return const [];
  return [
    'final ${read.type.dartType} ${read.expression} = '
        '${LvRuntimeCall.environment}.readLocalVariable($literal) as ${read.type.dartType};',
  ];
}

/// Register For Events: the registration and error terminals, then one event source per
/// terminal, a user event refnum or a cluster of them.
List<String>? _registerForEvents(LvPrimCall call) {
  final fixed = _serverTerminals(call, 'Register For Events (class 0xeb)');
  if (fixed == null) return null;
  final sources = <String>[], events = <String>[];
  for (var i = 4; i < call.ports.length; i++) {
    final source = _wiredAt(call, call.ports[i]);
    if (source == null) continue;
    final event = call.portMemberName[call.ports[i]] ?? '';
    if (!call.inputs.contains(source)) {
      return call.refuse('Register For Events (class 0xeb) has an event source wired as a sink');
    }
    if (_isRefnumWire(source.type)) {
      sources.add(source.expression!);
      events.add(event);
      continue;
    }
    final shape = _ClusterShape.of(source.type);
    if (shape == null || shape.fields.any((field) => field.type.carrier != LvCarrier.refnum)) {
      return call.refuse(
        'Register For Events (class 0xeb) takes ${source.type.dartType ?? '?'} as an event source, which is neither '
        'a refnum nor a cluster of refnums',
      );
    }
    final carrier = lvIsAtomic(source.expression!) ? source.expression! : '(${source.expression})';
    sources.addAll([for (final name in shape.names) '$carrier.$name']);
    events.addAll([for (var k = 0; k < shape.fields.length; k++) shape.fields[k].label ?? shape.names[k]]);
  }
  call.requireImport(kLvRuntimeImport);
  final existing = fixed.referenceIn?.expression ?? LvRuntimeType.notARefnum;
  final errorIn = fixed.errorIn?.expression ?? LvRuntimeType.clearedError;
  final invocation =
      '${LvRuntimeCall.registerForEvents}(<${LvRuntimeType.refnum}>[${sources.join(', ')}], '
      'events: <String>[${events.map(lvDartStringLiteral).join(', ')}], existing: $existing, errorIn: $errorIn)';
  if (fixed.referenceOut == null && fixed.errorOut == null) return ['$invocation;'];
  final registered = call.names.role(LvNameRole.value);
  return [
    'final $registered = $invocation;',
    if (fixed.referenceOut != null)
      'final ${LvRuntimeType.refnum} ${fixed.referenceOut!.expression} = $registered.registration;',
    if (fixed.errorOut != null) 'final ${LvRuntimeType.error} ${fixed.errorOut!.expression} = $registered.errorOut;',
  ];
}
