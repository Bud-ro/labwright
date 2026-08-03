/// The **primitive map**: the Dart statements one block-diagram operation
/// node lowers to.
///
/// A node is mapped only when both halves of its meaning are decoded facts:
///
/// - its **identity** — a `primResID` this reader names ([PrimOp]) or a class
///   code that *is* one operation and whose name corpus node labels carry
///   (`0x44` Index Array ×27, `0xB9` Replace Array Subset ×10, with no
///   competing caption); and
/// - its **operand roles** — which terminal is which argument. These come
///   from the terminal's own decoded record where it carries one (the
///   direction flag, the wire's dimensionality, the growable array nodes'
///   role bits below), and otherwise from the **drawn-order rule**.
///
/// Everything else lands on the review list ([lvPrimUnmappedReason]) with what
/// is missing, so a corpus sweep can size the gap instead of hiding it.
///
/// ## The drawn-order rule
///
/// **A node's first operand is the input it draws uppermost.** So `Subtract`
/// is `top - bottom`, `Divide` is `top / bottom`, and `Greater?` asks
/// `top > bottom`.
///
/// The role bits do not supply this. Corpus census of the input terminals'
/// role bits, over every node of each operation in 7 524 VIs: `Subtract` —
/// 1 172 nodes read `{0x0, 0x10000}` in heap order, 395 read `{0x10000, 0x0}`,
/// and 64 carry `0x0` on BOTH inputs; `Divide` — 247 of 516 carry `0x0` on
/// both; `Greater?` — 231 of 237, and `Less?` 100 of 106, likewise. The bits
/// distinguish nothing for most ordered nodes, where two codes do appear their
/// heap order flips both ways, and `0x10000` sits on the commutative `Add`
/// (910 nodes) and `Exclusive Or` (17) too, so it is not an operand ordinal.
///
/// Geometry does. Every two-input primitive stacks its inputs — 4 748 corpus
/// nodes across `Add`, `Multiply`, `Exclusive Or`, `Subtract`, `Divide`,
/// `Greater?`, `Less?`, `Quotient & Remainder` and the unnamed 1082/1181, not
/// one of them drawing its two inputs on the same row — and the rule that
/// order carries is established four ways, each with no counterexample:
///
/// - **The roles already decoded reproduce it.** On the 2 324 `0x44`/`0xB9`
///   nodes whose array and index terminals the role bits fix and whose
///   geometry resolves, the array — the first argument — is drawn above the
///   index every time.
/// - **`Quotient & Remainder` divides by its lower operand.** Its lower-drawn
///   input is a constant on 131 of 149 corpus nodes and its upper on 2, and
///   those constants are moduli (2 ×95, then 4, 5, 6, 8, 16, 32, 64, 100, 128,
///   and the floating 60.0/3600.0 of a seconds-to-hours conversion). A divisor
///   has that distribution; a dividend does not.
/// - **`Subtract` and `Divide` take their subject from the top.** An
///   `Array Size` or `String Length` feeds `Subtract`'s upper input 240 times
///   against 36 on the lower (the `size - 1` idiom), and `Divide`'s upper 36
///   against 10; constants sit on the lower input 256 against 71, and 285
///   against 29.
/// - **An ordered comparison never compares to a constant on top.** Across
///   184 corpus `Greater?` and `Less?` nodes with a constant operand, the
///   constant is the LOWER input 184 times and the upper 0 — a threshold is
///   the second argument of `value > threshold`.
///
/// Heap order is not the rule and is not used as one: on those 4 748 nodes the
/// first holder in heap order is the LOWER terminal, while on the `0x44` nodes
/// the first holder is the array, which is drawn ABOVE. The two conventions
/// disagree; the drawn order is what both classes share, so terminals carry
/// their drawn position ([LvPrimTerminal.drawnTop]) and a node whose geometry
/// does not resolve is refused rather than ordered by its heap layout.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'numeric.dart';
import 'runtime.dart';
import 'type_map.dart';
import 'wire_type.dart';

/// Role bits on a growable array node's terminal record
/// ([ViHeapObject.objFlags] of the typed child under the terminal's holder).
///
/// **Index Array's terminal grammar is measured.** Over the 3 479 `0x44` nodes
/// in 7 524 VIs, 3 478 read as `[array] ([output] [index]×rank)+` in heap
/// order — one array terminal, then one group per element the node yields, and
/// one index terminal per array dimension inside each group. The single
/// irregular node is not lowered.
///
/// The two high bits DELIMIT a group; they are not dimension names. A group of
/// one index carries BOTH ([singleIndex] `0x600000`, 2 898 single-group
/// nodes); a rank-2 group carries [groupFirst] on its first index and
/// [groupLast] on its second; and a rank-3 group's middle index carries
/// neither. So a group's rank is how many index terminals it holds and a
/// dimension is an index terminal's position in it. An index terminal LabVIEW
/// leaves unwired reads as a source rather than a sink, so it never reaches a
/// lowering as an operand.
///
/// What that does NOT establish is which array dimension the first index
/// terminal selects. Geometry gives a total drawn order — on the 24 nodes
/// carrying exactly one `0x200000` and one `0x400000` terminal, the `0x200000`
/// one is drawn above the `0x400000` one 24 times and below it none — but
/// nothing decoded ties that order to the array type's own dimension order,
/// and a rank-2 lowering must choose between `flat[i * dims[1] + j]` and
/// `flat[j * dims[0] + i]`. Higher-rank groups are therefore refused: 22
/// corpus nodes index a 2-D array on both terminals, 36 on the first alone and
/// 14 on the second alone (each yielding a 1-D slice that is a row under one
/// reading and a column under the other), and 12 index a 3-D array. This is
/// the same missing tie that refuses `Subtract`'s operand order.
///
/// `0xB9` (Replace Array Subset, 371 nodes) does not read as this grammar at
/// all — its group carries a new-element terminal too — so only its pinned 1-D
/// shape `{array, out, element 0x40000, index 0x600000}` lowers.
abstract final class LvArrayTerminalRole {
  /// The array being read or written.
  static const int array = 0x20000;

  /// The node's primary output — the first group's element.
  static const int output = 0x1;

  /// A growable node's SUBSEQUENT element output ([output] plus the grown-row
  /// bit): groups after the first carry this.
  static const int grownOutput = 0x40001;

  /// Replace Array Subset's new element.
  static const int newElement = 0x40000;

  /// The one index terminal of a rank-1 group — both group-delimiter bits, so
  /// it is the group's first index and its last.
  static const int singleIndex = 0x600000;

  /// Marks a group's FIRST index terminal.
  static const int groupFirst = 0x200000;

  /// Marks a group's LAST index terminal.
  static const int groupLast = 0x400000;
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
    required this.outputPorts,
    required this.portDrawnTop,
    required this.requireImport,
    this.primResId,
  });

  /// The decoded primitive operation, or null when the node's identity is its
  /// class code alone.
  final PrimOp? op;

  /// The node's raw `primResID`, whether or not [PrimOp] names it — reported
  /// by [lvPrimUnmappedReason] so an unnamed operation is identifiable.
  final int? primResId;

  /// The node's heap class code.
  final int classCode;

  /// The input terminals, in terminal order.
  final List<LvPrimTerminal> inputs;

  /// The output terminals, in terminal order.
  final List<LvPrimTerminal> outputs;

  /// EVERY output port of the node in heap order — [outputs] holds only the
  /// ones something consumes, so a node whose second result is left unwired
  /// still says here that it has two.
  final List<int> outputPorts;

  /// Per port oid, the y the terminal is drawn at
  /// ([LvPrimUnit.portDrawnTop]).
  final Map<int, int> portDrawnTop;

  /// Declares an import in the emitted file.
  final void Function(String) requireImport;

  /// The single input carrying [flags] in its role bits, or null.
  LvPrimTerminal? inputWithRole(int flags) => _single(inputs.where((t) => t.roleFlags == flags));

  /// The single output carrying [flags] in its role bits, or null.
  LvPrimTerminal? outputWithRole(int flags) => _single(outputs.where((t) => t.roleFlags == flags));

  /// The node's two **inputs in drawn order**, uppermost first — its operand
  /// order (see the library doc) — or null when it has other than two inputs,
  /// when either terminal's drawn position is missing, or when the two share a
  /// row and the order is therefore not stated.
  (LvPrimTerminal, LvPrimTerminal)? get operandsTopDown {
    if (inputs.length != 2) return null;
    final ranked = _rankTopDown([for (final terminal in inputs) terminal.port]);
    return ranked == null ? null : (_terminalAt(inputs, ranked.$1)!, _terminalAt(inputs, ranked.$2)!);
  }

  /// The node's two **outputs in drawn order**, uppermost first. An entry is
  /// null where nothing consumes that output, so a node that uses only one of
  /// its two results still resolves which result that is.
  (LvPrimTerminal?, LvPrimTerminal?)? get resultsTopDown {
    final ranked = _rankTopDown(outputPorts);
    return ranked == null ? null : (_terminalAt(outputs, ranked.$1), _terminalAt(outputs, ranked.$2));
  }

  /// [ports] — exactly two — ordered uppermost first, or null when either
  /// resolves no drawn position or the two share a row.
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

/// The [PrimOp]s with a lowering rule — the identity half of the map, before
/// any operand is resolved. A node whose op is outside this set can never
/// lower, so a corpus census can size the gap without building an IR.
///
/// The set is deliberately narrow. An operation is here only when its operand
/// roles follow from the terminals themselves — commutative pairs, unary
/// operations, and the conversions — or from the drawn-order rule, which is
/// what admits `Subtract`, `Divide`, the two ordered comparisons and
/// `Quotient & Remainder`.
///
/// Having one operand is necessary but not sufficient: the RESULT must follow
/// from the operand too. These unary corpus operations are refused for want of
/// a rule rather than a role, and each names the missing fact.
///
/// - `Sort 1D Array` (1120, 181 nodes) — the sort direction, and the order it
///   puts equal elements in, are not stated anywhere in the file.
/// - `Boolean To (0,1)` (1167, 550) — the name gives the pair, not which
///   member each boolean maps to.
/// - `To Lower Case` (1189, 673) — LabVIEW's case-mapping table over a byte
///   string is not decoded, and Dart's `toLowerCase` is Unicode's, which
///   differs above U+007F.
/// - `Type Cast` (1166, 1259) — reinterprets an operand's *flattened* bytes,
///   and the flattened layout of a general value is not decoded.
/// - `Number To Boolean Array` (1814, 21) and `Boolean Array To Number`
///   (1815, 26) — the bit order of the array is not decoded.
/// - `Transpose 2D Array` (1902) and a rank-2 `Array Size` — the array's own
///   dimension order, the same missing tie that refuses a higher-rank Index
///   Array (see [LvArrayTerminalRole]).
const Set<PrimOp> kLvMappedPrimOps = {
  PrimOp.exclusiveOr,
  PrimOp.and,
  PrimOp.or,
  PrimOp.add,
  PrimOp.multiply,
  PrimOp.subtract,
  PrimOp.divide,
  PrimOp.quotientRemainder,
  PrimOp.equal,
  PrimOp.notEqual,
  PrimOp.greater,
  PrimOp.less,
  PrimOp.not,
  PrimOp.increment,
  PrimOp.decrement,
  PrimOp.equalToZero,
  PrimOp.notEqualToZero,
  PrimOp.greaterThanZero,
  PrimOp.lessThanZero,
  PrimOp.greaterOrEqualToZero,
  PrimOp.lessOrEqualToZero,
  PrimOp.emptyStringPath,
  PrimOp.stringLength,
  PrimOp.arraySize,
  PrimOp.reverse1dArray,
  PrimOp.toSinglePrecisionFloat,
  PrimOp.toDoublePrecisionFloat,
  PrimOp.toByteInteger,
  PrimOp.toWordInteger,
  PrimOp.toLongInteger,
  PrimOp.toUnsignedByteInteger,
  PrimOp.toUnsignedWordInteger,
  PrimOp.toUnsignedLongInteger,
  PrimOp.toQuadInteger,
  PrimOp.toUnsignedQuadInteger,
  PrimOp.stringToByteArray,
  PrimOp.byteArrayToString,
  PrimOp.rotateLeftWithCarry,
  PrimOp.rotateRightWithCarry,
  PrimOp.swapBytes,
  PrimOp.swapWords,
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

    // Ordered arithmetic: the drawn-order rule names the first operand.
    case PrimOp.subtract:
      return _binaryOrdered(call, '-');
    case PrimOp.divide:
      return _divide(call);
    case PrimOp.quotientRemainder:
      return _quotientRemainder(call);

    // Symmetric comparisons: `a == b` and `b == a` are the same test, so no
    // operand order is needed. Both sides must carry the same Dart type, which
    // keeps the elementwise array and cluster forms out.
    case PrimOp.equal:
      return _binaryPredicate(call, '==');
    case PrimOp.notEqual:
      return _binaryPredicate(call, '!=');

    // Ordered comparisons: the same test read off the drawn operand order.
    case PrimOp.greater:
      return _orderedPredicate(call, '>');
    case PrimOp.less:
      return _orderedPredicate(call, '<');

    case PrimOp.not:
      return _not(call);
    case PrimOp.increment:
      return _unaryNumeric(call, '+ 1');
    case PrimOp.decrement:
      return _unaryNumeric(call, '- 1');

    // Compare-to-zero: the second operand is the constant the operation is
    // named for, so there is only one terminal and no order to decode.
    case PrimOp.equalToZero:
      return _comparedToZero(call, '==');
    case PrimOp.notEqualToZero:
      return _comparedToZero(call, '!=');
    case PrimOp.greaterThanZero:
      return _comparedToZero(call, '>');
    case PrimOp.lessThanZero:
      return _comparedToZero(call, '<');
    case PrimOp.greaterOrEqualToZero:
      return _comparedToZero(call, '>=');
    case PrimOp.lessOrEqualToZero:
      return _comparedToZero(call, '<=');

    case PrimOp.emptyStringPath:
      return _isEmpty(call);
    case PrimOp.stringLength:
      return _unaryOfString(call, 'length', 'int');
    case PrimOp.arraySize:
      return _arraySize(call);
    case PrimOp.reverse1dArray:
      return _reverse1dArray(call);

    // Widening to a floating type: the target's own rounding, and no operand
    // order to decode.
    case PrimOp.toSinglePrecisionFloat:
    case PrimOp.toDoublePrecisionFloat:
      return _floatConversion(call);

    // Integer width conversions.
    case PrimOp.toByteInteger:
    case PrimOp.toWordInteger:
    case PrimOp.toLongInteger:
    case PrimOp.toUnsignedByteInteger:
    case PrimOp.toUnsignedWordInteger:
    case PrimOp.toUnsignedLongInteger:
    case PrimOp.toQuadInteger:
    case PrimOp.toUnsignedQuadInteger:
      return _integerConversion(call);

    case PrimOp.stringToByteArray:
      return _byteArrayConversion(call, encode: true);
    case PrimOp.byteArrayToString:
      return _byteArrayConversion(call, encode: false);

    case PrimOp.rotateLeftWithCarry:
      return _rotateWithCarry(call, left: true);
    case PrimOp.rotateRightWithCarry:
      return _rotateWithCarry(call, left: false);

    case PrimOp.swapBytes:
      return _swap(call, LvRuntimeCall.swapBytes, fieldPairBits: 16);
    case PrimOp.swapWords:
      return _swap(call, LvRuntimeCall.swapWords, fieldPairBits: 32);

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
  if (call.primResId case final id?) {
    return 'primResID $id on node class 0x${call.classCode.toRadixString(16)} is '
        'not named anywhere in the corpus, so the operation it performs is not decoded';
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

/// An ordered arithmetic pair — the operands taken in drawn order, so the
/// upper terminal is the left-hand side.
List<String>? _binaryOrdered(LvPrimCall call, String operator) {
  if (call.outputs.length != 1) return null;
  final operands = call.operandsTopDown;
  if (operands == null) return null;
  final out = call.outputs.single;
  if (_hazardous(out.type, operator)) return null;
  final name = out.expression;
  if (name == null) return const [];
  final body = '${operands.$1.expression} $operator ${operands.$2.expression}';
  return ['final ${out.type.dartType} $name = ${lvWrapped(out.type, body)};'];
}

/// `Divide` — the upper operand over the lower.
///
/// The result is a floating type: every one of the 516 corpus nodes whose
/// operands are scalar numerics yields a `DBL` or a `SGL`, integer operands
/// included. A node whose output is an integer would need LabVIEW's own
/// coercion rounding, which is not decoded, so it is refused.
List<String>? _divide(LvPrimCall call) {
  if (call.outputs.length != 1) return null;
  final operands = call.operandsTopDown;
  if (operands == null) return null;
  final out = call.outputs.single;
  if (out.type.dims != 0 || !(out.type.numeric?.isFloat ?? false)) return null;
  final name = out.expression;
  for (final operand in [operands.$1, operands.$2]) {
    if (operand.type.dims != 0 || operand.type.numeric == null) return null;
    // A U64 operand's carrier reads as signed under `toDouble`.
    if (_hazardous(operand.type, 'toDouble')) return null;
  }
  if (name == null) return const [];
  String widened(LvPrimTerminal operand) =>
      operand.type.numeric!.isFloat ? operand.expression! : '${operand.expression}.toDouble()';
  final body = '${widened(operands.$1)} / ${widened(operands.$2)}';
  if (out.type.numeric == LvNumericKind.sgl) call.requireImport('dart:typed_data');
  return ['final double $name = ${lvWrapped(out.type, body)};'];
}

/// An ordered two-terminal comparison, read off the drawn operand order.
///
/// Both operands must be scalar numerics: an array wire would make the node
/// the elementwise form, and LabVIEW's ordering of the non-numeric carriers
/// (a string's collation, a cluster's field-by-field order) is not decoded.
List<String>? _orderedPredicate(LvPrimCall call, String operator) {
  if (call.outputs.length != 1) return null;
  final operands = call.operandsTopDown;
  if (operands == null) return null;
  final out = call.outputs.single;
  if (out.type.dartType != 'bool') return null;
  for (final operand in [operands.$1, operands.$2]) {
    if (operand.type.dims != 0 || operand.type.numeric == null) return null;
    if (_hazardous(operand.type, operator)) return null;
  }
  final name = out.expression;
  if (name == null) return const [];
  return ['final bool $name = ${operands.$1.expression} $operator ${operands.$2.expression};'];
}

/// `Quotient & Remainder` — the upper operand divided by the lower, with the
/// quotient on the LOWER output and the remainder on the upper (see
/// [PrimOp.quotientRemainder] for the icon glyphs and the corpus idiom that
/// fix both orders).
///
/// Integer operands only: LabVIEW's floating form yields a floating quotient,
/// whose rounding is the same undecided question the runtime records plus the
/// binary-format one, so it is refused rather than approximated. A `U64`
/// operand divides as signed on its carrier
/// ([LvArithmeticHazard.unsignedDivide]) and is refused too. Most corpus nodes
/// consume ONE of the two results — 98 of 149 leave the remainder unwired and
/// 30 the quotient — so an unused result binds to `_`.
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

/// A **field swap** — `Swap Bytes` or `Swap Words`, whichever [runtimeCall]
/// names.
///
/// The operand must be a scalar integer at least [fieldPairBits] wide, which
/// is the narrowest type that holds the pair of fields the operation
/// exchanges; the corpus never wires a narrower one. The result carries the
/// operand's own type, so the width wrap is what re-establishes the sign of a
/// narrow signed carrier.
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

/// The carriers whose Dart `==` is a VALUE comparison, so that a symmetric
/// LabVIEW comparison lowers to the operator directly. The runtime's own
/// carriers ([LvRuntimeType]) are deliberately absent: none of them defines
/// `==`, so Dart would compare identities where LabVIEW compares contents.
const Set<String> _kValueEqualityCarriers = {'int', 'double', 'bool', 'String'};

/// A symmetric two-terminal comparison. Both operands must be scalars of the
/// same value-equality carrier: an array wire would make the node the
/// elementwise form, whose result is a shape this does not model, and a
/// cluster or runtime carrier has no decided equality.
List<String>? _binaryPredicate(LvPrimCall call, String operator) {
  if (call.inputs.length != 2 || call.outputs.length != 1) return null;
  final left = call.inputs[0], right = call.inputs[1], out = call.outputs.single;
  if (left.type.dims != 0 || right.type.dims != 0) return null;
  if (!_kValueEqualityCarriers.contains(left.type.dartType)) return null;
  if (left.type.dartType != right.type.dartType) return null;
  if (out.type.dartType != 'bool') return null;
  final name = out.expression;
  if (name == null) return const [];
  return ['final bool $name = ${left.expression} $operator ${right.expression};'];
}

/// A compare-to-zero predicate: one numeric scalar in, one boolean out.
List<String>? _comparedToZero(LvPrimCall call, String operator) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || source.type.numeric == null) return null;
  if (_hazardous(source.type, operator)) return null;
  if (out.type.dartType != 'bool') return null;
  final name = out.expression;
  if (name == null) return const [];
  final zero = source.type.numeric!.isFloat ? '0.0' : '0';
  return ['final bool $name = ${source.expression} $operator $zero;'];
}

/// `Empty String/Path?` — `isEmpty` on the operand's own carrier.
///
/// Both carriers answer it: a Dart `String` directly, and [LvRuntimeType.path]
/// through the emptiness its `PTH0` record states — a relative path with no
/// components. A rooted path is never empty however few components it names.
List<String>? _isEmpty(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || out.type.dartType != 'bool') return null;
  if (source.type.dartType != 'String' && source.type.dartType != LvRuntimeType.path) return null;
  final name = out.expression;
  if (name == null) return const [];
  return ['final bool $name = ${source.expression}.isEmpty;'];
}

/// `Reverse 1D Array` — a new array holding the operand's elements in the
/// opposite order. Rank is on the wire, so a higher-rank operand is refused.
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

/// A unary string query — `member` read off a scalar string operand.
List<String>? _unaryOfString(LvPrimCall call, String member, String resultType) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || source.type.dartType != 'String') return null;
  if (out.type.dartType != resultType) return null;
  final name = out.expression;
  if (name == null) return const [];
  return ['final $resultType $name = ${source.expression}.$member;'];
}

/// Array Size over a 1-D array. The higher-rank node yields an ARRAY of
/// per-dimension sizes, whose dimension order is the same undecoded fact that
/// refuses a higher-rank Index Array ([LvArrayTerminalRole]), so it is refused.
List<String>? _arraySize(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 1 || out.type.dims != 0) return null;
  if (out.type.numeric == null || out.type.numeric!.isFloat) return null;
  final name = out.expression;
  if (name == null) return const [];
  return ['final int $name = ${source.expression}.length;'];
}

/// Whether [operator] misreads [type]'s carrier ([LvNumericKind.hazards]) — a
/// U64's signed carrier makes every ordered comparison wrong, so those nodes
/// are refused rather than emitted with a silent sign bug.
bool _hazardous(LvWireType type, String operator) =>
    type.numeric?.hazards.any((hazard) => hazard.operators.contains(operator)) ?? false;

/// `Not` — a boolean negation, or an integer's one's complement renormalized
/// to its LabVIEW width. A float has no bitwise complement and is refused. A
/// U64 needs no special case: `~` is sign-agnostic, so it is exact on the raw
/// bit pattern that carrier holds.
List<String>? _not(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || out.type.dims != 0) return null;
  if (source.type.dartType != out.type.dartType) return null;
  final name = out.expression;
  if (out.type.dartType == 'bool') {
    if (name == null) return const [];
    return ['final bool $name = !${source.expression};'];
  }
  final kind = out.type.numeric;
  if (kind == null || kind.isFloat) return null;
  if (name == null) return const [];
  return ['final int $name = ${lvWrapped(out.type, '~${source.expression}')};'];
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

/// The **To-Float** conversions. Widening an integer or a SGL to a binary
/// floating type is the target format's own round-to-nearest, which is what
/// `toDouble` and the SGL narrowing wrap do, so the conversion needs no rule
/// this reader does not have. A U64 source is refused: `toDouble` reads its
/// carrier as signed ([LvArithmeticHazard.unsignedFormat]).
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

/// Index Array over a 1-D array, in the grammar's `[array] ([output]
/// [index])+` shape — one statement per group, the growable node included.
///
/// Both terminal lists keep heap order, so group `k`'s index is
/// `inputs[k + 1]` and its element is `outputs[k]`. Rank-1 groups are the only
/// ones that lower ([LvArrayTerminalRole]), and a rank-1 group's index carries
/// [LvArrayTerminalRole.singleIndex] exactly — which also rejects an unwired
/// index, since one never reaches the input list.
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
