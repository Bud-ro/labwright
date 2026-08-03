/// The **primitive map**: the Dart statements one block-diagram operation
/// node lowers to.
///
/// A node is mapped only when both halves of its meaning are decoded facts:
///
/// - its **identity** — a `primResID` this reader names ([PrimOp]) or a class
///   code that *is* one operation and whose name corpus node labels carry
///   (`0x44` Index Array ×27, `0xB9` Replace Array Subset ×10, with no
///   competing caption); and
/// - its **operand roles** — which terminal is which argument. Terminal
///   position alone does not say, so roles come from the terminal's own
///   decoded record: its direction flag, its wire's dimensionality, and for
///   the growable array nodes the role bits below.
///
/// Everything else lands on the review list ([lvPrimUnmappedReason]) with what
/// is missing, so a corpus sweep can size the gap instead of hiding it. That
/// includes operations whose meaning is obvious but whose *operand order* is
/// not decoded: `Subtract` needs to know which terminal is the minuend.
///
/// The terminal role bits do not supply it. Corpus census of the input
/// terminals' role bits, over every node of each operation in 7 524 VIs:
///
/// - `Subtract` — 1 172 nodes read `{0x0, 0x10000}` in heap order, 395 read
///   `{0x10000, 0x0}`, and 64 carry `0x0` on BOTH inputs;
/// - `Divide` — 247 of 516 carry `0x0` on both inputs, 228 read
///   `{0x0, 0x10000}` and 39 the reverse;
/// - `Greater?` — 231 of 237, and `Less?` 100 of 106, carry `0x0` on both.
///
/// So the bits distinguish nothing at all for most ordered nodes; where two
/// codes do appear their heap order flips both ways; and `0x10000` appears on
/// the commutative `Add` (910 nodes) and `Exclusive Or` (17) as well, so it is
/// not an operand ordinal. Nothing here says which terminal is the left
/// operand, and these operations stay refused.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'numeric.dart';
import 'runtime.dart';
import 'wire_type.dart';

/// Role bits on a growable array node's terminal record
/// ([ViHeapObject.objFlags] of the typed child under the terminal's holder).
///
/// Corpus, over the 3 228 `0x44` and 372 `0xB9` nodes: the 1-D shapes are
/// `{array 0x20000, out 0x1, index 0x600000}` (1 623 Index Array nodes) and
/// `{array 0x20000, out 0x1, element 0x40000, index 0x600000}` (310 Replace
/// Array Subset nodes). Higher-rank nodes split the index across `0x200000`
/// (first dimension) and `0x400000` (second), and growable nodes repeat the
/// output/index pair; both shapes are refused rather than assumed, so only the
/// 1-D form above lowers.
abstract final class LvArrayTerminalRole {
  /// The array being read or written.
  static const int array = 0x20000;

  /// The node's primary output.
  static const int output = 0x1;

  /// Replace Array Subset's new element.
  static const int newElement = 0x40000;

  /// The single index of a 1-D access — both dimension bits set.
  static const int singleIndex = 0x600000;
}

/// One terminal of a node, resolved.
class LvPrimTerminal {
  const LvPrimTerminal({required this.port, required this.type, required this.roleFlags, required this.expression});

  /// The endpoint-holder oid.
  final int port;

  /// The type of the wire attached to it.
  final LvWireType type;

  /// The terminal record's own flags ([LvArrayTerminalRole]).
  final int roleFlags;

  /// For an input, the Dart expression feeding it; for an output, the name it
  /// is bound to, or null when nothing consumes it.
  final String? expression;
}

/// One node's lowering request.
class LvPrimCall {
  const LvPrimCall({
    required this.op,
    required this.classCode,
    required this.inputs,
    required this.outputs,
    required this.requireImport,
  });

  /// The decoded primitive operation, or null when the node's identity is its
  /// class code alone.
  final PrimOp? op;

  /// The node's heap class code.
  final int classCode;

  /// The input terminals, in terminal order.
  final List<LvPrimTerminal> inputs;

  /// The output terminals, in terminal order.
  final List<LvPrimTerminal> outputs;

  /// Declares an import in the emitted file.
  final void Function(String) requireImport;

  /// The single input carrying [flags] in its role bits, or null.
  LvPrimTerminal? inputWithRole(int flags) => _single(inputs.where((t) => t.roleFlags == flags));

  /// The single output carrying [flags] in its role bits, or null.
  LvPrimTerminal? outputWithRole(int flags) => _single(outputs.where((t) => t.roleFlags == flags));

  static LvPrimTerminal? _single(Iterable<LvPrimTerminal> matches) {
    final list = matches.toList();
    return list.length == 1 ? list.single : null;
  }
}

/// The [PrimOp]s with a lowering rule — the identity half of the map, before
/// any operand is resolved. A node whose op is outside this set can never
/// lower, so a corpus census can size the gap without building an IR.
///
/// The set is deliberately narrow. An operation is here only when its operand
/// roles follow from the terminals themselves: commutative pairs (either order
/// gives the same value), unary operations (there is only one operand), and
/// the conversions. `Subtract`, `Divide` and the ordered comparisons are
/// absent because nothing decoded says which terminal is the left operand.
const Set<PrimOp> kLvMappedPrimOps = {
  PrimOp.exclusiveOr,
  PrimOp.and,
  PrimOp.or,
  PrimOp.add,
  PrimOp.multiply,
  PrimOp.not,
  PrimOp.increment,
  PrimOp.decrement,
  PrimOp.toByteInteger,
  PrimOp.toWordInteger,
  PrimOp.toLongInteger,
  PrimOp.toUnsignedByteInteger,
  PrimOp.toUnsignedWordInteger,
  PrimOp.toUnsignedLongInteger,
  PrimOp.stringToByteArray,
  PrimOp.byteArrayToString,
  PrimOp.rotateLeftWithCarry,
  PrimOp.rotateRightWithCarry,
};

/// Node **classes the corpus names**: a class that is one operation, with
/// LabVIEW's default node name read off corpus captions and the number of
/// captions behind it. Users rarely rename a primitive, so a class whose
/// captions agree on one name is identified by that agreement.
///
/// Being named is the identity half of the map and does not by itself give a
/// lowering: [kLvMappedPrimClasses] is the subset whose OPERAND ROLES are also
/// decoded. The rest are named here so the review list says what it is
/// refusing — a `Concatenate Strings` whose input order is not decoded reads
/// very differently from an unidentified class.
///
/// Two classes are deliberately absent. `0x63` (14 975 nodes) is not one
/// operation: its captions read `Unbundle By Name` ×269 AND `Bundle By Name`
/// ×177, so the class cannot be an identity. `0x114` (414 nodes) has no
/// agreement — `Overflow array` ×4 against `Initialize Array` ×3, both of
/// which read as user text.
const Map<int, ({String name, int captions})> kLvNamedNodeClasses = {
  kLvIndexArrayClass: (name: 'Index Array', captions: 27),
  kLvReplaceArraySubsetClass: (name: 'Replace Array Subset', captions: 10),
  0x34: (name: 'Bundle', captions: 26),
  0x36: (name: 'Unbundle', captions: 25),
  0x3a: (name: 'Build Array', captions: 74),
  0x3e: (name: 'Concatenate Strings', captions: 32),
  0x6c: (name: 'Compound Arithmetic', captions: 14),
  0x93: (name: 'Format Into String', captions: 37),
  0x105: (name: 'Match Regular Expression', captions: 4),
  0x172: (name: 'Merge Errors', captions: 113),
};

/// The node **classes** that are one operation and have a lowering rule — the
/// [kLvNamedNodeClasses] entries whose operand roles the terminal records
/// establish (see [LvArrayTerminalRole]).
const Set<int> kLvMappedPrimClasses = {kLvIndexArrayClass, kLvReplaceArraySubsetClass};

/// Whether a node identified by [op] (null when its class is the identity) and
/// [classCode] has a lowering rule at all. A node that passes this may still
/// be refused once its operands are resolved — a growable Index Array, say,
/// whose terminal roles are outside the pinned 1-D shape.
bool lvPrimHasRule({PrimOp? op, required int classCode}) =>
    op == null ? kLvMappedPrimClasses.contains(classCode) : kLvMappedPrimOps.contains(op);

/// The statements defining a node's outputs, or null when the node has no
/// decided lowering — in which case [lvPrimUnmappedReason] says what is
/// missing.
List<String>? lvPrimLowering(LvPrimCall call) {
  if (!lvPrimHasRule(op: call.op, classCode: call.classCode)) return null;
  switch (call.op) {
    // Commutative bitwise/arithmetic pairs: the two inputs are interchangeable,
    // so a lowering needs no decoded operand order.
    case PrimOp.exclusiveOr:
      return _binaryCommutative(call, '^');
    case PrimOp.and:
      return _binaryCommutative(call, '&');
    case PrimOp.or:
      return _binaryCommutative(call, '|');
    case PrimOp.add:
      return _binaryCommutative(call, '+');
    case PrimOp.multiply:
      return _binaryCommutative(call, '*');
    case PrimOp.not:
      return _unaryBoolean(call, '!');
    case PrimOp.increment:
      return _unaryNumeric(call, '+ 1');
    case PrimOp.decrement:
      return _unaryNumeric(call, '- 1');

    // Integer width conversions.
    case PrimOp.toByteInteger:
    case PrimOp.toWordInteger:
    case PrimOp.toLongInteger:
    case PrimOp.toUnsignedByteInteger:
    case PrimOp.toUnsignedWordInteger:
    case PrimOp.toUnsignedLongInteger:
      return _integerConversion(call);

    case PrimOp.stringToByteArray:
      return _byteArrayConversion(call, encode: true);
    case PrimOp.byteArrayToString:
      return _byteArrayConversion(call, encode: false);

    case PrimOp.rotateLeftWithCarry:
      return _rotateWithCarry(call, left: true);
    case PrimOp.rotateRightWithCarry:
      return _rotateWithCarry(call, left: false);

    case _:
      break;
  }
  if (call.classCode == kLvIndexArrayClass) return _indexArray(call);
  if (call.classCode == kLvReplaceArraySubsetClass) return _replaceArraySubset(call);
  return null;
}

/// The heap class code of the **Index Array** node (its class is its identity;
/// corpus node labels read `Index Array` ×27, with no competing caption).
const int kLvIndexArrayClass = 0x44;

/// The heap class code of the **Replace Array Subset** node (corpus node
/// labels ×10, no competing caption).
const int kLvReplaceArraySubsetClass = 0xb9;

/// Why the node [call] describes has no lowering — the review-list entry.
String lvPrimUnmappedReason(LvPrimCall call) {
  if (call.op case final op?) {
    return 'primitive ${op.opName} (primResID ${op.id}) has no decided lowering: '
        'its operand roles are not established from the terminal records';
  }
  if (call.classCode == kLvIndexArrayClass || call.classCode == kLvReplaceArraySubsetClass) {
    return 'class 0x${call.classCode.toRadixString(16)} node is not the 1-D shape whose '
        'terminal roles the corpus pins (${call.inputs.length} inputs, '
        '${call.outputs.length} outputs, role bits '
        '${[
          for (final t in [...call.inputs, ...call.outputs]) '0x${t.roleFlags.toRadixString(16)}',
        ].join('/')})';
  }
  if (kLvNamedNodeClasses[call.classCode] case final named?) {
    return 'class 0x${call.classCode.toRadixString(16)} is ${named.name} '
        '(${named.captions} corpus captions), but which terminal is which '
        'argument is not established from the terminal records';
  }
  return 'node class 0x${call.classCode.toRadixString(16)} carries no decoded primitive identity';
}

List<String>? _binaryCommutative(LvPrimCall call, String operator) {
  if (call.inputs.length != 2 || call.outputs.length != 1) return null;
  final out = call.outputs.single;
  final name = out.expression;
  if (name == null) return const [];
  final body = '${call.inputs[0].expression} $operator ${call.inputs[1].expression}';
  return ['final ${out.type.dartType} $name = ${lvWrapped(out.type, body)};'];
}

List<String>? _unaryBoolean(LvPrimCall call, String operator) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  if (call.inputs.single.type.dartType != 'bool') return null;
  final out = call.outputs.single;
  final name = out.expression;
  if (name == null) return const [];
  return ['final bool $name = $operator${call.inputs.single.expression};'];
}

List<String>? _unaryNumeric(LvPrimCall call, String suffix) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  if (out.type.numeric == null) return null;
  final name = out.expression;
  if (name == null) return const [];
  final body = '${source.expression} $suffix';
  return ['final ${out.type.dartType} $name = ${lvWrapped(out.type, body)};'];
}

List<String>? _integerConversion(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  final target = out.type.numeric;
  // Both sides must be integers: a float source would need LabVIEW's rounding
  // rule, which is not established here.
  if (target == null || target.isFloat) return null;
  if (source.type.numeric == null || source.type.numeric!.isFloat) return null;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  final name = out.expression;
  if (name == null) return const [];
  call.requireImport(kLvRuntimeImport);
  return ['final int $name = ${LvRuntimeCall.integerConversion(target)}(${source.expression});'];
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
  // A LabVIEW string is a byte sequence carried as Latin-1 code units
  // (kStringEncodingNote), so the byte view is latin1, never utf8.
  if (encode) {
    call.requireImport('dart:typed_data');
    return ['final Uint8List $name = latin1.encode(${source.expression});'];
  }
  return ['final String $name = latin1.decode(${source.expression});'];
}

List<String>? _rotateWithCarry(LvPrimCall call, {required bool left}) {
  if (call.inputs.length != 2 || call.outputs.length != 2) return null;
  // Roles are unambiguous by type: one numeric side and one boolean carry on
  // each of the input and output halves.
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
    LvPrimCall._single(terminals.where((t) => t.type.dims == 0 && t.type.numeric != null));

LvPrimTerminal? _onlyBoolean(List<LvPrimTerminal> terminals) =>
    LvPrimCall._single(terminals.where((t) => t.type.dims == 0 && t.type.dartType == 'bool'));

List<String>? _indexArray(LvPrimCall call) {
  final array = call.inputWithRole(LvArrayTerminalRole.array);
  final index = call.inputWithRole(LvArrayTerminalRole.singleIndex);
  final out = call.outputWithRole(LvArrayTerminalRole.output);
  if (array == null || index == null || out == null) return null;
  if (call.inputs.length != 2 || call.outputs.length != 1) return null;
  if (array.type.dims != 1 || index.type.dims != 0 || out.type.dims != 0) return null;
  final name = out.expression;
  if (name == null) return const [];
  return ['final ${out.type.dartType} $name = ${array.expression}[${index.expression}];'];
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
  // Dataflow, not mutation: the node yields a new array and the input keeps
  // its value, so the copy is the semantics rather than a precaution.
  final storage = out.type.elementListType;
  return [
    'final $storage $name = $storage.fromList(${array.expression})..[${index.expression}] = ${element.expression};',
  ];
}

/// [expression] renormalized to [type]'s LabVIEW width, without the redundant
/// parentheses [LvNumericKind.wrap] adds around an already-atomic operand.
String lvWrapped(LvWireType type, String expression) {
  final kind = type.numeric;
  return kind == null ? expression : lvWrapExpression(kind, expression);
}

/// [expression] renormalized to [kind]'s width, parenthesized only when the
/// expression is compound.
String lvWrapExpression(LvNumericKind kind, String expression) {
  if (!kind.needsWrap) return expression;
  final wrapped = kind.wrap(expression);
  return _isAtomic(expression) ? wrapped.replaceFirst('($expression)', expression) : wrapped;
}

/// Whether [expression] is a bare identifier or number — one that needs no
/// parentheses in any operator position.
bool _isAtomic(String expression) => RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$|^-?\d+$').hasMatch(expression);
