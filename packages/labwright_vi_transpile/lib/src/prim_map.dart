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
///
/// Terminal **geometry** does give a total order, and it is measured. Every
/// two-input primitive stacks its inputs — 4 606 corpus nodes across `Add`,
/// `Multiply`, `Exclusive Or`, `Subtract`, `Divide`, `Greater?` and `Less?`,
/// and not one draws its two inputs on the same row — and in every one of
/// those the FIRST holder in heap order is the LOWER terminal. Geometry also
/// reproduces the one operand order that is independently known: on the 2 352
/// `0x44`/`0xB9` nodes whose array and index terminals the role bits fix, the
/// array terminal is drawn above the index terminal 2 352 times and below it
/// none.
///
/// What is still missing is the tie from that drawn order to LabVIEW's own
/// argument names — that the upper terminal of a `Subtract` is the minuend
/// rather than the subtrahend. Confirming it needs a VI whose output is known
/// independently and whose lowering turns on the choice; no corpus VI reaches
/// that state (`crc16`, `crc32` and `Excel_Cell_to_RowCol` each stop at an
/// unrelated node class first), so the order stays refused.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'numeric.dart';
import 'runtime.dart';
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
/// gives the same value — `Equal?` and `Not Equal?` included, since they are
/// symmetric where `Greater?` is not), unary operations (there is only one
/// operand, which is what puts the six *compare-to-zero* predicates here while
/// the two-terminal comparisons stay out), and the conversions. `Subtract`,
/// `Divide` and the ordered two-terminal comparisons are absent because
/// nothing decoded says which terminal is the left operand.
const Set<PrimOp> kLvMappedPrimOps = {
  PrimOp.exclusiveOr,
  PrimOp.and,
  PrimOp.or,
  PrimOp.add,
  PrimOp.multiply,
  PrimOp.equal,
  PrimOp.notEqual,
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

    // Symmetric comparisons: `a == b` and `b == a` are the same test, so no
    // operand order is needed. Both sides must carry the same Dart type, which
    // keeps the elementwise array and cluster forms out.
    case PrimOp.equal:
      return _binaryPredicate(call, '==');
    case PrimOp.notEqual:
      return _binaryPredicate(call, '!=');

    case PrimOp.not:
      return _unaryBoolean(call, '!');
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
      return _unaryOfString(call, 'isEmpty', 'bool');
    case PrimOp.stringLength:
      return _unaryOfString(call, 'length', 'int');
    case PrimOp.arraySize:
      return _arraySize(call);

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
