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
/// their drawn position ([LvPrimCall.portDrawnTop]) and a node whose geometry
/// does not resolve is refused rather than ordered by its heap layout.
///
/// ## The rule at N inputs
///
/// The growable and three-terminal operations read the same way, and their
/// geometry is even cleaner than the two-input family's. Corpus, over every
/// node of each in 7 524 VIs, counting the nodes whose terminal geometry
/// resolves at all: `Concatenate Strings` 2 036 of 2 036, `Compound Arithmetic`
/// 1 104 of 1 104, `Select` 2 401 of 2 401 and `Build Array` 3 676 of 3 682 —
/// **not one node draws two inputs on the same row**, so drawn order is a total
/// order over an operand list of any length. (Heap order is a second, separate
/// convention again: these four classes list their terminals top-down in heap
/// order on every node, where the two-input arithmetic family lists them
/// bottom-up. Neither is read.)
///
/// That the drawn order is the ARGUMENT order is the same rule, corroborated on
/// the one variadic operation whose argument order is observable in its
/// operands — `Concatenate Strings`, where a string constant's own text says
/// where in the result it belongs:
///
/// - a two-input node's lone constant ending in a label separator (`Name:`,
///   `x =`) is the UPPER input 26 times and the lower 4;
/// - a two-input node's lone constant *beginning* with one is the LOWER input
///   44 times and the upper 7;
/// - a bracket-opening constant (`<`, `(`, `[`, `{`) is drawn ABOVE the
///   matching closer 25 times and below it 5.
///
/// [Select] is fixed by its own terminals rather than by an idiom: on the
/// 2 058 three-input nodes whose wires type and which carry exactly one boolean
/// operand, that boolean is the MIDDLE of the three drawn rows 2 058 times and
/// an outer row 0 times, so the selector is the middle terminal and the two
/// values are the outer ones. Which outer value the selector's true case takes
/// is fixed by the constants the corpus wires to them, with no counterexample:
/// an affirmative/negative word pair (`True`/`False`, `Yes`/`No`, `On`/`Off`,
/// `Enabled`/`Disabled`, …) puts the affirmative on the UPPER input 22 times
/// and the lower 0, and a `true`/`false` boolean-constant pair puts `true`
/// upper 10 times and lower 0.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'naming.dart';
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
  const LvPrimTerminal({
    required this.port,
    required this.type,
    required this.roleFlags,
    required this.expression,
    this.memberName,
  });

  /// The endpoint-holder oid.
  final int port;

  /// The type of the wire attached to it.
  final LvWireType type;

  /// The terminal record's own flags ([LvArrayTerminalRole]).
  final int roleFlags;

  /// For an input, the Dart expression feeding it; for an output, the name it
  /// is bound to, or null when nothing consumes it.
  final String? expression;

  /// The cluster MEMBER this terminal selects, for the by-name nodes that
  /// carry one on the terminal's own record ([LvPrimUnit.portMemberName]).
  final String? memberName;
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
    required this.names,
    required this.nodeFlags,
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

  /// The node's own record flags ([LvPrimUnit.nodeFlags]), or null where the
  /// object carries no flags word. It selects [LvCompoundMode] and separates
  /// the two by-name operations sharing class [kLvByNameClass]; both readings
  /// refuse on null, since zero is a value the field holds rather than its
  /// absence.
  final int? nodeFlags;

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

  /// Allocates the identifiers a lowering needs beyond the ones its terminals
  /// already carry — an elementwise loop's index and its per-output builder.
  final LvNaming names;

  /// The single input carrying [flags] in its role bits, or null.
  LvPrimTerminal? inputWithRole(int flags) => _single(inputs.where((t) => t.roleFlags == flags));

  /// The single output carrying [flags] in its role bits, or null.
  LvPrimTerminal? outputWithRole(int flags) => _single(outputs.where((t) => t.roleFlags == flags));

  /// Whether the node draws exactly one source terminal. An input LabVIEW
  /// leaves unwired reads as a source rather than a sink, so a variadic node
  /// with a spare source terminal has an operand the diagram supplies a default
  /// for — a value that is not decoded — and this is what refuses it.
  bool get hasSoleSourceTerminal => outputPorts.length == 1;

  /// Every input **in drawn order**, uppermost first — the operand list (see
  /// the library doc) — or null when any terminal's drawn position is missing
  /// or two of them share a row, in which case the order is not stated.
  List<LvPrimTerminal>? get inputsTopDown {
    final rows = <int>{};
    for (final terminal in inputs) {
      final top = portDrawnTop[terminal.port];
      if (top == null || !rows.add(top)) return null;
    }
    return [...inputs]..sort((a, b) => portDrawnTop[a.port]!.compareTo(portDrawnTop[b.port]!));
  }

  /// [ports] **in drawn order**, uppermost first — or null when any port's
  /// drawn position is missing or two of them share a row, in which case the
  /// order is not stated.
  List<int>? portsTopDown(List<int> ports) {
    final rows = <int>{};
    for (final port in ports) {
      final top = portDrawnTop[port];
      if (top == null || !rows.add(top)) return null;
    }
    return [...ports]..sort((a, b) => portDrawnTop[a]!.compareTo(portDrawnTop[b]!));
  }

  /// The node's two **inputs in drawn order**, uppermost first — its operand
  /// order (see the library doc) — or null when it has other than two inputs,
  /// when either terminal's drawn position is missing, or when the two share a
  /// row and the order is therefore not stated.
  (LvPrimTerminal, LvPrimTerminal)? get operandsTopDown {
    if (inputs.length != 2) return null;
    final ordered = inputsTopDown;
    return ordered == null ? null : (ordered[0], ordered[1]);
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
  PrimOp.emptyArray,
  PrimOp.addArrayElements,
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
  PrimOp.stringSubset,
  PrimOp.toLowerCase,
  PrimOp.rotateLeftWithCarry,
  PrimOp.rotateRightWithCarry,
  PrimOp.swapBytes,
  PrimOp.swapWords,
  PrimOp.select,
  PrimOp.logicalShift,
  PrimOp.typeCast,
  PrimOp.notANumberPathRefnum,
  PrimOp.waitMs,
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
/// The bar an addition clears: exactly **one** distinct caption text over the
/// whole corpus, carried by at least three nodes. A class the corpus captions
/// two ways is not one identity until something decoded separates the two, and
/// a class captioned once is one author's word.
///
/// What the corpus says about the classes that do not clear it:
/// `0x63` (14 975 nodes) is `Unbundle By Name` ×269 AND `Bundle By Name` ×177,
/// and [kLvByNameUnbundlesBit] is the decoded record that separates them;
/// `0xae` (156) is `Start Asynchronous Call` ×95 AND `Wait On Asynchronous
/// Call` ×3; `0xd6` (2 437) is `Event Data Node` ×17 AND `Event Filter Node`
/// ×1; `0x14a` (380) is `Feedback Node` ×12 and
/// `Target Angle` ×2. `0xa9` (2 619) carries 38 distinct captions of which
/// `Invoke Node` ×84 is only the most common — the rest (`Classes` ×10,
/// `Attribute` ×10, `Save` ×8, …) name a member rather than the node.
/// `0x48` `Array Subset` ×1 and `0xeb` `Register For Events` ×2 are below the
/// floor. `0x153` (1 466), `0x170` (380) and `0x150` (406) carry no caption at
/// all.
///
/// Two of those are identified anyway, by records rather than by captions, and
/// are absent here because captions are not what named them.
/// `0x6a` (865) is the **Call Library Function node**: every one carries a path
/// record naming a native shared library and a symbol record naming an entry
/// point in it ([ViHeapObject.foreignLibraryPath] / [foreignEntryPoint]), and
/// its 248 caption texts are not evidence of anything — 392 of the 761
/// captioned nodes carry a caption the two records contradict. It is refused as
/// [LvRefusalKind.foreignCall], not as a primitive: see [kLvCallLibraryClass].
/// `0x153` (1 466) is an **In Place Element Structure border node** accessing a
/// data value reference ([HeapObjectClass.bdNode153]); a rule for it would
/// lower nothing on its own, since all 1 466 sit inside an In Place Element
/// Structure, whose control flow is not modelled and which refuses first
/// ([LvRefusalKind.structure]).
///
/// [kLvUnbundleClass]'s entry predates the bar and does not clear it: its
/// second caption text is `Template unbundler` ×4, which reads as author text
/// beside `Unbundle` ×25.
///
/// One entry is named by its **terminal grammar** instead
/// ([LvClassNameBasis.terminalGrammar]) — see [kLvInitializeArrayClass], whose
/// captions do not agree and whose signature admits one operation.
const Map<int, ({String name, int captions, LvClassNameBasis basis})> kLvNamedNodeClasses = {
  kLvIndexArrayClass: (name: 'Index Array', captions: 27, basis: LvClassNameBasis.captions),
  kLvReplaceArraySubsetClass: (name: 'Replace Array Subset', captions: 10, basis: LvClassNameBasis.captions),
  kLvBundleClass: (name: 'Bundle', captions: 26, basis: LvClassNameBasis.captions),
  kLvUnbundleClass: (name: 'Unbundle', captions: 25, basis: LvClassNameBasis.captions),
  kLvBuildArrayClass: (name: 'Build Array', captions: 74, basis: LvClassNameBasis.captions),
  kLvConcatenateStringsClass: (name: 'Concatenate Strings', captions: 32, basis: LvClassNameBasis.captions),
  kLvCompoundArithmeticClass: (name: 'Compound Arithmetic', captions: 14, basis: LvClassNameBasis.captions),
  0x92: (name: 'Scan From String', captions: 3, basis: LvClassNameBasis.captions),
  0x93: (name: 'Format Into String', captions: 37, basis: LvClassNameBasis.captions),
  0x105: (name: 'Match Regular Expression', captions: 4, basis: LvClassNameBasis.captions),
  0xbd: (name: 'Delete From Array', captions: 7, basis: LvClassNameBasis.captions),
  kLvMergeErrorsClass: (name: 'Merge Errors', captions: 113, basis: LvClassNameBasis.captions),
  kLvInitializeArrayClass: (name: 'Initialize Array', captions: 3, basis: LvClassNameBasis.terminalGrammar),
};

/// What names a node class in [kLvNamedNodeClasses].
enum LvClassNameBasis {
  /// **One** distinct caption text across the whole corpus, carried by at
  /// least three nodes. Users rarely rename a primitive, so captions that
  /// agree are LabVIEW's own default node name.
  captions,

  /// The class's **terminal grammar** admits one operation, and the corpus
  /// captions it under a name that grammar fits. Read where the captions alone
  /// do not clear the bar above, and stated with the grammar that does.
  terminalGrammar,
}

/// The node **classes** that are one operation and have a lowering rule — the
/// [kLvNamedNodeClasses] entries whose operand roles the terminal records
/// establish (see [LvArrayTerminalRole]) or the drawn order does (see the
/// library doc's N-input section).
///
/// `Compound Arithmetic` (`0x6c`) is here for the two modes a published test
/// vector decides and no others; [LvCompoundMode] carries the field's whole
/// reading and [kLvLoweredCompoundModes] the part of it that lowers.
const Set<int> kLvMappedPrimClasses = {
  kLvIndexArrayClass,
  kLvReplaceArraySubsetClass,
  kLvBuildArrayClass,
  kLvConcatenateStringsClass,
  kLvUnbundleClass,
  kLvMergeErrorsClass,
  kLvByNameClass,
  kLvCompoundArithmeticClass,
  kLvInitializeArrayClass,
};

/// The **primResIDs with no name** whose operation in a given shape a published
/// test vector nonetheless decides.
///
/// [PrimOp] names an id only on the evidence its own library doc sets out, and
/// neither id here clears that bar: no corpus VI labels either node. What this
/// set adds is a different kind of evidence, and a weaker claim. A lowering is
/// hypothesised for the node from its terminal grammar and its position in a
/// diagram whose output is published, the diagram is lowered under the
/// hypothesis, and the result is compared with the published vectors. A wrong
/// hypothesis produces a wrong result; the right one reproduces every vector.
///
/// So each entry states **what the node computes in the shapes below**, proven
/// against a vector, and does not name the primitive in general — a node
/// outside those shapes is refused exactly as an unnamed one is: `_rotate` and
/// `_hexString` gate on the width the vectors exercise, and the runtime refuses
/// the operands they leave undecided.
///
/// - [kLvRotatePrimResId] (1082, 3 corpus nodes) — a rotation over the value's
///   own width. Its terminal grammar is byte-for-byte the corpus-labelled
///   `Logical Shift`'s (1081): two inputs and one output, role bits
///   `[0x10000, 0x0]` in heap order on 3 of 3 nodes against 67 of 68, and the
///   role-`0x10000` operand is the one carrying the result's numeric kind on
///   both. `MD5.vi` wires it between a four-term sum and an addition, with its
///   count taken from the published per-round rotation table, and the RFC 1321
///   digests hold only if the node rotates left by a positive count. Only a
///   32-bit result lowers; the count is a table lookup even in `MD5.vi`, so it
///   is the runtime that refuses one outside a single width.
/// - [kLvHexStringPrimResId] (1181, 14 corpus nodes) — an integer written in
///   **hexadecimal** at a stated field width. Its signature is one
///   I16 and one integer in, one string out, on all 14; the corpus-labelled
///   `Number To Decimal String` is 1180 and `Decimal String To Number` 1184, so
///   1181 sits in the to-string half of a radix run whose two ends are pinned,
///   and the two integer radices left in that half are hexadecimal and octal.
///   `MD5.vi` formats its four state words through it at width 8 and the RFC
///   1321 digests hold under hexadecimal and under no other radix or width.
///   Only a 32-bit value lowers, and the runtime refuses a field the value
///   overflows.
const Set<int> kLvProvenPrimResIds = {kLvRotatePrimResId, kLvHexStringPrimResId};

/// The `primResID` of the rotation node — see [kLvProvenPrimResIds].
const int kLvRotatePrimResId = 1082;

/// The `primResID` of the hexadecimal number-to-string node — see
/// [kLvProvenPrimResIds].
const int kLvHexStringPrimResId = 1181;

/// Whether a node identified by [op] (null when its class is the identity),
/// [classCode] and [primResId] has a lowering rule at all. A node that passes
/// this may still be refused once its operands are resolved — a growable Index
/// Array, say, whose terminal roles are outside the pinned 1-D shape.
bool lvPrimHasRule({PrimOp? op, required int classCode, int? primResId}) => op == null
    ? kLvMappedPrimClasses.contains(classCode) || kLvProvenPrimResIds.contains(primResId)
    : kLvMappedPrimOps.contains(op);

/// The statements defining a node's outputs, or null when the node has no
/// decided lowering — in which case [lvPrimUnmappedReason] says what is
/// missing.
///
/// A node whose own rule does not read its wires is tried once more as the
/// **elementwise** form ([_elementwise]), which is how a scalar operation
/// wired to arrays lowers.
List<String>? lvPrimLowering(LvPrimCall call) {
  if (!lvPrimHasRule(op: call.op, classCode: call.classCode, primResId: call.primResId)) return null;
  return _lowerDirect(call) ?? _elementwise(call);
}

List<String>? _lowerDirect(LvPrimCall call) {
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
    case PrimOp.emptyArray:
      return _emptyArray(call);
    case PrimOp.addArrayElements:
      return _addArrayElements(call);

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

    case PrimOp.select:
      return _select(call);

    case PrimOp.logicalShift:
      return _logicalShift(call);

    case PrimOp.typeCast:
      return _typeCast(call);

    case PrimOp.notANumberPathRefnum:
      return _isNotANumber(call);

    case PrimOp.stringSubset:
      return _stringSubset(call);

    case PrimOp.toLowerCase:
      return _toLowerCase(call);

    case PrimOp.waitMs:
      return _waitMs(call);

    case null:
      // The ids with no name whose operation a published vector decides.
      switch (call.primResId) {
        case kLvRotatePrimResId:
          return _rotate(call);
        case kLvHexStringPrimResId:
          return _hexString(call);
      }

    case _:
      break;
  }
  if (call.classCode == kLvIndexArrayClass) return _indexArray(call);
  if (call.classCode == kLvReplaceArraySubsetClass) return _replaceArraySubset(call);
  if (call.classCode == kLvBuildArrayClass) return _buildArray(call);
  if (call.classCode == kLvConcatenateStringsClass) return _concatenateStrings(call);
  if (call.classCode == kLvUnbundleClass) return _unbundle(call);
  if (call.classCode == kLvMergeErrorsClass) return _mergeErrors(call);
  if (call.classCode == kLvByNameClass) return _byName(call);
  if (call.classCode == kLvCompoundArithmeticClass) return _compoundArithmetic(call);
  if (call.classCode == kLvInitializeArrayClass) return _initializeArray(call);
  return null;
}

/// The heap class code of the **Index Array** node (its class is its identity;
/// corpus node labels read `Index Array` ×27, with no competing caption).
const int kLvIndexArrayClass = 0x44;

/// The heap class code of the **Replace Array Subset** node (corpus node
/// labels ×10, no competing caption).
const int kLvReplaceArraySubsetClass = 0xb9;

/// The heap class code of the **Build Array** node (corpus node labels ×74, no
/// competing caption).
const int kLvBuildArrayClass = 0x3a;

/// The heap class code of the **Concatenate Strings** node (corpus node labels
/// ×32, no competing caption).
const int kLvConcatenateStringsClass = 0x3e;

/// The heap class code of the **Unbundle** node — the positional one (corpus
/// node labels `Unbundle` ×25).
const int kLvUnbundleClass = 0x36;

/// The heap class code of the **Bundle** node — the positional one (corpus
/// node labels ×26, no competing caption).
const int kLvBundleClass = 0x34;

/// The heap class code of the **Merge Errors** node (corpus node labels ×113,
/// no competing caption).
const int kLvMergeErrorsClass = 0x172;

/// The heap class code of the **Compound Arithmetic** node (corpus node labels
/// ×14, no competing caption). Which operation it performs is
/// [LvCompoundMode].
const int kLvCompoundArithmeticClass = 0x6c;

/// The heap class code of the **Initialize Array** node.
///
/// Its captions do not agree — `Overflow array` ×4 against `Initialize Array`
/// ×3 over 414 corpus nodes — so the class is named by its **terminal
/// grammar**, which admits one operation. Every node reads as one
/// [LvInitializeArrayRole.element] terminal, then one plain size terminal per
/// dimension, then one output: 369 nodes are `[element, size] → 1-D` and 43 are
/// `[element, size, size] → 2-D`, with 2 more whose second terminal is unwired
/// and none of any other shape. Two wire facts fix which terminal is which,
/// each on all 414: the role-flagged terminal's own wire type is the OUTPUT's
/// element type (`0x50d0` in / `0x50d1` out, `0x3d0` in / `0x3d1` out, …), and
/// every other input is an integer whose width does not track the element's.
/// An operation taking one element and one length per dimension and yielding an
/// array of that element is Initialize Array, which is also the LabVIEW default
/// name the captions carry; `Overflow array` names a value rather than an
/// operation and reads as author text.
const int kLvInitializeArrayClass = 0x114;

/// Role bits on an [kLvInitializeArrayClass] terminal's own record.
abstract final class LvInitializeArrayRole {
  /// The **element** every cell of the new array takes: the one input whose
  /// wire type is the output's element type.
  static const int element = 0x20000;

  /// A **dimension size**. Carries no role bit of its own.
  static const int size = 0x0;

  /// The array the node yields.
  static const int output = 0x1;
}

/// What a [kLvCompoundArithmeticClass] node computes: bits 16..18 of its own
/// record ([LvPrimCall.nodeFlags]), read as a mode selector.
///
/// LabVIEW draws one node for five reductions, and the corpus separates the
/// field's five values by the wire family they appear on. Over the 1 104 corpus
/// nodes, counting the nodes whose every wire types and agrees on a family:
///
/// | value | boolean | integer | float | nodes |
/// |-------|---------|---------|-------|-------|
/// | 0     | 0       | 52      | 12    | 66    |
/// | 1     | 0       | 0       | 1     | 9     |
/// | 2     | 674     | 2       | 0     | 719   |
/// | 3     | 250     | 4       | 0     | 309   |
/// | 4     | 0       | 1       | 0     | 1     |
///
/// That splits the five into a numeric pair (0, 1 — never boolean, and both
/// carry DBL wires, which no bitwise reduction does) and a bitwise triple
/// (2, 3, 4 — 924 of their 931 typed nodes are all-boolean). Two of the five
/// are then decided outright by a published test vector: `MD5.vi` sums four
/// U32 words through a **value-0** node and combines three through a
/// **value-4** node, and the RFC 1321 digests hold only if the first adds and
/// the second exclusive-ORs. The remaining three are named for the palette
/// order the pinned values bracket — 0 Add … 4 Exclusive OR, with Multiply the
/// other member of the numeric pair — and are NOT lowered
/// ([kLvLoweredCompoundModes]): a boolean node is equally an AND or an OR under
/// every reading the file supports, and a wrong reduction is a silently wrong
/// value.
///
/// Bit `0x80000` sits above the field on 1 091 of the 1 104 nodes and is not
/// part of it: the 13 that lack it are 5 value-2 and 8 value-3 nodes, i.e. the
/// same two modes the bit's carriers use, so it separates no operation.
enum LvCompoundMode {
  /// Proven by RFC 1321 in `MD5.vi`'s four-term U32 sum.
  add(0, 'Add'),

  /// Named from the palette order, on the numeric half of the census. Not
  /// lowered.
  multiply(1, 'Multiply'),

  /// Named from the palette order, on the boolean half. Not lowered.
  and(2, 'AND'),

  /// Named from the palette order, on the boolean half. Not lowered.
  or(3, 'OR'),

  /// Proven by RFC 1321 in `MD5.vi`'s three-term U32 combination.
  exclusiveOr(4, 'Exclusive OR')
  ;

  const LvCompoundMode(this.selector, this.opName);

  /// The value bits 16..18 of the node's record carry.
  final int selector;

  /// LabVIEW's own name for the reduction.
  final String opName;

  /// The mode [nodeFlags] selects, or null when it holds no catalogued value or
  /// the node carries no flags word at all.
  static LvCompoundMode? ofNodeFlags(int? nodeFlags) => nodeFlags == null ? null : _bySelector[(nodeFlags >> 16) & 0x7];

  static final Map<int, LvCompoundMode> _bySelector = {for (final mode in values) mode.selector: mode};
}

/// The [LvCompoundMode]s with a lowering — the ones a published test vector
/// decides, with the Dart operator each reduces its operands by.
const Map<LvCompoundMode, String> kLvLoweredCompoundModes = {
  LvCompoundMode.add: '+',
  LvCompoundMode.exclusiveOr: '^',
};

/// The bit a [kLvCompoundArithmeticClass] terminal's record carries where the
/// node **inverts** that operand — LabVIEW draws a small circle on the
/// terminal, and the node's published description is a reduction over operands
/// any of which may be inverted, with the result optionally inverted too.
///
/// Which of the two states the bit names is not decoded, and the corpus cannot
/// say: no node labels its inversions, and the same `0x10000` value sits on
/// ordinary `Subtract` inputs where an inversion would mean nothing. So this is
/// read only as a **gate** — a node carrying it on any terminal is refused,
/// whichever state it names — and never as a licence to emit a complement.
///
/// Over the corpus's 1 104 nodes it sits on a terminal of 583 (an input role
/// reads `0x50000` where a plain operand reads `0x40000`), and it concentrates
/// exactly where a boolean complement is idiomatic: 505 of them select AND and
/// 70 OR, against 8 that select Add and none that select Multiply or Exclusive
/// OR. So of the 67 nodes in a mode [kLvLoweredCompoundModes] carries, 59 have
/// no inverted terminal and this gate refuses 8.
const int kLvCompoundInversionBit = 0x10000;

/// The heap class code shared by **Bundle By Name** and **Unbundle By Name**.
///
/// The class is two operations, not one: its corpus captions read
/// `Unbundle By Name` ×269 AND `Bundle By Name` ×177. Which of the two a node
/// is comes from [kLvByNameUnbundlesBit].
const int kLvByNameClass = 0x63;

/// The bit of a [kLvByNameClass] node's own record ([LvPrimCall.nodeFlags])
/// that marks it **Unbundle** By Name rather than Bundle By Name.
///
/// Measured against the captions the corpus writes on these nodes, which are
/// LabVIEW's own default names for the two operations. Over the 507 captioned
/// nodes among the class's 14 975: every one of the 313 captioned
/// `Unbundle …` carries the bit (flag words `0x50000` ×255, `0x51000` ×57,
/// `0x10000` ×1) and every one of the 194 captioned `Bundle …` does not
/// (`0x40000` ×154, `0x41000` ×38, `0x40004` ×2). No node contradicts it.
///
/// The node's terminal ARITY is a second, independent reading — the cluster
/// side has one terminal and the member side has the rest — and it agrees on
/// 8 557 of the 8 588 nodes where it is decisive (99.6%). It is not the reading
/// used: on the captioned nodes the arity disagrees with the caption twice and
/// the bit never does, and an unwired input reads as a source, which flips the
/// arity of a node whose cluster terminal is left open.
const int kLvByNameUnbundlesBit = 0x10000;

/// Why the node [call] describes has no lowering — the review-list entry.
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
  if (call.classCode == kLvIndexArrayClass || call.classCode == kLvReplaceArraySubsetClass) {
    return 'class 0x${call.classCode.toRadixString(16)} node is not the 1-D shape whose '
        'terminal roles the corpus pins (${call.inputs.length} inputs, '
        '${call.outputs.length} outputs, role bits '
        '${[
          for (final t in [...call.inputs, ...call.outputs]) '0x${t.roleFlags.toRadixString(16)}',
        ].join('/')})';
  }
  if (call.classCode == kLvByNameClass) {
    if (call.nodeFlags == null) {
      return 'Bundle/Unbundle By Name (class 0x${call.classCode.toRadixString(16)}) carries no '
          'flags word, and [kLvByNameUnbundlesBit] is the only reading that separates the two';
    }
    final unbundles = (call.nodeFlags! & kLvByNameUnbundlesBit) != 0;
    final members = unbundles ? call.outputs : call.inputs;
    final cluster = (unbundles ? call.inputs : call.outputs).firstOrNull?.type;
    final declaration = cluster == null ? null : _clusterDecl(cluster);
    return '${unbundles ? 'Unbundle' : 'Bundle'} By Name (class '
        '0x${call.classCode.toRadixString(16)}) does not resolve its members: '
        '${declaration == null ? 'its cluster wire carries no declared class, and' : 'against ${declaration.name},'} '
        '${members.where((terminal) => terminal.memberName == null).length} of ${members.length} '
        'member terminals name no member on their own record';
  }
  if (call.classCode == kLvCompoundArithmeticClass) {
    final mode = LvCompoundMode.ofNodeFlags(call.nodeFlags);
    if (mode == null || !kLvLoweredCompoundModes.containsKey(mode)) {
      final selects = call.nodeFlags == null
          ? 'no mode, carrying no flags word'
          : 'mode ${(call.nodeFlags! >> 16) & 0x7}';
      return 'Compound Arithmetic (class 0x${call.classCode.toRadixString(16)}) selects $selects'
          '${mode == null ? '' : ' (${mode.opName})'}, which no published test vector decides, '
          'and a wrong reduction is a silently wrong value';
    }
    final inverted = [...call.inputs, ...call.outputs].where((t) => t.roleFlags & kLvCompoundInversionBit != 0);
    if (inverted.isNotEmpty) {
      return 'Compound Arithmetic (class 0x${call.classCode.toRadixString(16)}) carries the '
          'per-terminal inversion bit on ${inverted.length} of ${call.inputs.length + call.outputs.length} '
          'terminals, and which state the bit names is not decoded';
    }
  }
  if (kLvNamedNodeClasses[call.classCode] case final named?) {
    if (kLvMappedPrimClasses.contains(call.classCode)) {
      return 'class 0x${call.classCode.toRadixString(16)} is ${named.name} and its '
          'operand roles are decoded, but this node is outside the shape that '
          'lowers (${call.inputs.length} wired inputs, ${call.outputs.length} of '
          '${call.outputPorts.length} outputs consumed, terminal types '
          '${[
            for (final t in [...call.inputs, ...call.outputs]) t.type.dartType ?? '?',
          ].join('/')})';
    }
    return 'class 0x${call.classCode.toRadixString(16)} is ${named.name} '
        '(${named.captions} corpus captions), but which terminal is which '
        'argument is not established from the terminal records';
  }
  if (call.primResId case final id?) {
    if (kLvProvenPrimResIds.contains(id)) {
      return 'primResID $id is not named anywhere in the corpus; what it computes is '
          'established for the shapes a published test vector exercises '
          '(see kLvProvenPrimResIds), and this node is outside them '
          '(${call.inputs.length} wired inputs, ${call.outputs.length} of '
          '${call.outputPorts.length} outputs consumed, terminal types '
          '${[
            for (final t in [...call.inputs, ...call.outputs]) t.type.dartType ?? '?',
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
  // Scalars only: an array wire makes the node the elementwise form, whose
  // operands the Dart operator does not apply to.
  if (out.type.dims != 0 || call.inputs.any((operand) => operand.type.dims != 0)) return null;
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
  if (out.type.dims != 0 || operands.$1.type.dims != 0 || operands.$2.type.dims != 0) return null;
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

/// `Select` — the middle-drawn input chooses between the two outer ones, and
/// the UPPER one is the value the true case takes (see the library doc for both
/// halves of the census that fixes this).
///
/// The selector must be a scalar boolean; an array selector is the elementwise
/// form, which the wrapper below reaches only when every terminal is an array.
/// The two values and the result must carry one Dart type, which is what keeps
/// LabVIEW's own coercion between differing operand types out.
List<String>? _select(LvPrimCall call) {
  if (call.inputs.length != 3 || call.outputs.length != 1 || !call.hasSoleSourceTerminal) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final (whenTrue, selector, whenFalse) = (ordered[0], ordered[1], ordered[2]);
  final out = call.outputs.single;
  if (selector.type.dims != 0 || selector.type.dartType != 'bool') return null;
  if (whenTrue.type.dartType != out.type.dartType || whenFalse.type.dartType != out.type.dartType) return null;
  if (whenTrue.type.dims != out.type.dims || whenFalse.type.dims != out.type.dims) return null;
  final name = out.expression;
  if (name == null) return const [];
  return [
    'final ${out.type.dartType} $name = '
        '${selector.expression} ? ${whenTrue.expression} : ${whenFalse.expression};',
  ];
}

/// `Logical Shift` — the LOWER operand shifted by the upper one, toward the
/// high bits when the count is positive and the low bits when it is negative.
///
/// Which operand is which is stated twice over and the two agree. The result
/// carries the shifted value's own type, so the operand whose numeric kind is
/// the result's is the value; on the 68 corpus nodes whose three wires all
/// type, that operand is the LOWER-drawn one 56 times and the upper 0, with 12
/// nodes whose operands share a kind and so distinguish nothing. The upper
/// operand is a small signed integer on every one of them (I16 on 54, I8 on 7,
/// I32 on 7), and the constants wired to it are shift counts rather than data:
/// −8 ×21, −16 ×14, −32 ×4, −1 ×3, −48 ×2, −4 ×2, and 16, 8, 4, 3, 1, 0 in the
/// ones and twos.
///
/// Integer operands only — a floating value has no bit pattern to shift — and
/// the count is taken at run time, since its sign is what names the direction.
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

/// `Type Cast` — the operand's own bytes read back as another type.
///
/// **Which terminal is the type.** The node takes a value and a *type*
/// operand, and its result carries the type operand's type — so the type
/// operand is the input whose wire type is the output's, and the other input
/// is the value. Corpus, over the 1 127 two-input nodes in 7 524 VIs: 1 017
/// resolve exactly one such input, 23 wire two inputs of ONE type (which this
/// reading cannot separate, and which are refused), and the remaining 87 are a
/// refnum-to-`0xff` family whose output wire code has no decided
/// representation at all. Geometry cannot supply this and is not consulted:
/// all 1 017 draw their two inputs on the SAME row, so the drawn-order rule
/// that names every other node's operands is silent here.
///
/// A node whose type terminal is left **unwired** takes LabVIEW's own default
/// for it, and the corpus states what that default is: on every one of the 106
/// such nodes the result wire is a scalar `String` — i.e. the value's bytes
/// themselves. Anything else is refused.
///
/// **The byte form** is [LvRuntimeCall.flatOfInt] and its siblings: scalars
/// big-endian at their width, an array's elements end to end, a string's
/// characters as bytes. Its big-endian half is the same law the parse
/// package's constant payloads decode under — a fixed-width numeric constant
/// stores its value big-endian at the type's width (5 211 of 5 730 corpus
/// integer scalars), an array constant stores `[u32 × dims][big-endian
/// elements]` (205 exact payloads, 322 empty ones), and a string constant
/// `[u32 length][bytes]` (8 493 exact of 9 813, plus 1 171 empty strings which
/// carry `[u32 0]` and one zero pad byte, every one of them length 0).
///
/// What the cast does NOT carry is those leading counts: the dimension vector
/// and the length prefix frame a value in STORAGE, and a cast reinterprets the
/// data alone. The round trip is what says so — `ReverseBitsVim` casts a `U64`
/// to a byte array and back, which reproduces the value only if the eight
/// bytes are the eight elements (see this package's behavioural pin).
///
/// Sizes must agree exactly; the runtime raises otherwise, since what LabVIEW
/// does with a short or long operand is not established (see
/// `TODO(lv-typecast-size)`).
List<String>? _typeCast(LvPrimCall call) {
  if (call.outputs.length != 1) return null;
  final out = call.outputs.single;
  final LvPrimTerminal value;
  if (call.inputs.length == 2 && call.hasSoleSourceTerminal) {
    final typed = call.inputs.where((operand) => _sameWireType(operand.type, out.type)).toList();
    if (typed.length != 1) return null;
    value = call.inputs.firstWhere((operand) => !identical(operand, typed.single));
  } else if (call.inputs.length == 1 && call.outputPorts.length == 2) {
    if (out.type.dims != 0 || out.type.dartType != 'String') return null;
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

/// Whether two wires carry the same LabVIEW type. The numeric kind is part of
/// it: `I32` and `U32` share a Dart carrier but are different LabVIEW types,
/// and a Type Cast between them is a real reinterpretation.
bool _sameWireType(LvWireType left, LvWireType right) =>
    left.dims == right.dims && left.dartType == right.dartType && left.numeric == right.numeric;

/// The expression yielding [operand]'s flat bytes, or null when its carrier
/// has no decided byte form.
String? _flatOf(LvPrimTerminal operand) {
  final kind = operand.type.numeric;
  if (operand.type.dims == 0) {
    if (operand.type.dartType == 'String') {
      return '${LvRuntimeCall.flatOfString}(${operand.expression})';
    }
    if (kind == null) return null;
    final call = kind.isFloat ? LvRuntimeCall.flatOfFloat : LvRuntimeCall.flatOfInt;
    return '$call(${operand.expression}, ${kind.bits})';
  }
  // Rank 2 and above is the array's own dimension order again, and a
  // non-numeric element has no stated element width.
  if (operand.type.dims != 1 || kind == null || kind.isFloat) return null;
  return '${LvRuntimeCall.flatOfIntList}(${operand.expression}, ${kind.bits})';
}

/// The expression reading the flat [bytes] back as [type], or null when that
/// carrier has no decided byte form.
String? _valueOfFlat(LvWireType type, String bytes) {
  final kind = type.numeric;
  if (type.dims == 0) {
    if (type.dartType == 'String') return '${LvRuntimeCall.stringOfFlat}($bytes)';
    if (kind == null) return null;
    if (kind.isFloat) return '${LvRuntimeCall.floatOfFlat}($bytes, ${kind.bits})';
    // The runtime yields the raw bit pattern; the width wrap is what
    // re-establishes a narrow signed carrier's sign.
    return lvWrapped(type, '${LvRuntimeCall.intOfFlat}($bytes, ${kind.bits})');
  }
  if (type.dims != 1 || kind == null || kind.isFloat) return null;
  return '${kind.typedListType}.fromList(${LvRuntimeCall.intListOfFlat}($bytes, ${kind.bits}))';
}

/// `Build Array` — one 1-D array holding, in drawn order, every operand: a
/// scalar operand as one element and an array operand spliced in whole.
///
/// Which of the two an operand is follows from the wires alone. Corpus, over
/// the 2 340 nodes whose operand and result wires all type: an operand is
/// exactly one dimension below the result on 3 723 terminals and level with it
/// on 1 809, and the node mixes the two on 1 038 of them — so the depth
/// difference names the role terminal by terminal and no node needs a mode
/// read off anywhere else. (The `0x800000` bit some of these terminals carry is
/// NOT that mode: it sits on 327 level operands and 1 482 lack it, and on 29
/// one-below operands.) The 6 terminals two dimensions below a result have no
/// reading and are refused.
///
/// A result of rank 2 or more is refused for the same reason a higher-rank
/// Index Array is ([LvArrayTerminalRole]): the array type's own dimension order
/// is not decoded.
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

/// `Concatenate Strings` — its operands joined in drawn order.
///
/// Scalar string operands only. LabVIEW also takes an ARRAY of strings here and
/// concatenates its elements, but which of the two an operand is would have to
/// come from the same depth reading Build Array uses, and the node's result is
/// a string either way, so the array form is left refused rather than assumed.
List<String>? _concatenateStrings(LvPrimCall call) {
  if (call.outputs.length != 1 || !call.hasSoleSourceTerminal || call.inputs.isEmpty) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final out = call.outputs.single;
  if (out.type.dims != 0 || out.type.dartType != 'String') return null;
  for (final operand in ordered) {
    if (operand.type.dims != 0 || operand.type.dartType != 'String') return null;
  }
  final name = out.expression;
  if (name == null) return const [];
  final operands = [for (final operand in ordered) operand.expression];
  final joined = operands.length == 1 ? operands.single : "'${operands.map(_interpolated).join()}'";
  return ['final String $name = $joined;'];
}

/// The generated cluster class a wire of [type] carries, or null when it is
/// not one: an array wire, a wire whose Dart type is not a declared class's
/// name, an enum, or a cluster with no members.
///
/// An anonymous cluster becomes a Dart record rather than a class
/// ([lvRecordType]) and so carries no declaration; the member operations below
/// read the declaration's field list, so they take the nominal form alone.
LvTypeDecl? _clusterDecl(LvWireType type) {
  if (type.dims != 0 || type.declarations.length != 1) return null;
  final declaration = type.declarations.single;
  if (declaration.isEnum || declaration.fields.isEmpty) return null;
  return declaration.name == type.dartType ? declaration : null;
}

/// The index of [declaration]'s single member named [label], or null when
/// [label] is absent, names no member, or names more than one.
int? _soleFieldIndex(LvTypeDecl declaration, String? label) {
  if (label == null) return null;
  int? found;
  for (var index = 0; index < declaration.fields.length; index++) {
    if (declaration.fields[index].label != label) continue;
    if (found != null) return null;
    found = index;
  }
  return found;
}

/// Whether the member at [index] of [declaration] can be read or written as
/// [wire] — the member's own Dart type is decided and is the wire's.
bool _memberMatches(LvTypeDecl declaration, int index, LvWireType wire) {
  final type = declaration.fields[index].type;
  return type.isMapped && type.dartType == wire.dartType;
}

/// `Unbundle` — the cluster's members, in drawn order.
///
/// The node takes one cluster and yields one terminal per member. That the
/// drawn order is the DESCRIPTOR order is stated twice by the corpus, and the
/// two agree. Over the 344 nodes whose cluster wire types and whose terminals
/// resolve distinct drawn rows: the terminal count equals the member count on
/// all 344, and the name the terminal's own record carries
/// ([LvPrimTerminal.memberName]) is the name of the member at the same drawn
/// position 782 times with **no counterexample** — where reading the terminals
/// bottom-up instead contradicts the member type codes on 238 of the 344 nodes
/// against 51 read top-down.
///
/// Both readings are applied: the position picks the member and the terminal's
/// own name, where it carries one, must be that member's. A terminal whose
/// wire type is not the member's own is refused rather than coerced.
List<String>? _unbundle(LvPrimCall call) {
  if (call.inputs.length != 1) return null;
  final source = call.inputs.single;
  final declaration = _clusterDecl(source.type);
  if (declaration == null) return null;
  final ordered = call.portsTopDown(call.outputPorts);
  if (ordered == null || ordered.length != declaration.fields.length) return null;
  final names = LvNaming.declarationFields([for (final field in declaration.fields) field.label]);
  final statements = <String>[];
  for (var index = 0; index < ordered.length; index++) {
    final result = LvPrimCall._terminalAt(call.outputs, ordered[index]);
    if (result == null) continue;
    if (!_memberMatches(declaration, index, result.type)) return null;
    if (result.memberName != null && result.memberName != declaration.fields[index].label) return null;
    statements.add(
      'final ${declaration.fields[index].type.dartType} ${result.expression} = '
      '${source.expression}.${names[index]};',
    );
  }
  return statements;
}

/// The **by-name** cluster access pair, which share a class code: Unbundle By
/// Name reads members out of a cluster, Bundle By Name writes them into one.
/// [kLvByNameUnbundlesBit] is which.
///
/// Neither reads the drawn order. A by-name terminal carries the member it
/// selects on its own record ([LvPrimTerminal.memberName]), and a terminal
/// naming other than exactly one member of the wire's cluster is refused: over
/// the corpus's 14 975 by-name nodes, the terminals of the 5 077 unbundling
/// nodes whose cluster wire types name exactly one member 8 015 times, name no
/// member of it 1 033 times, and carry no name 386 times, so 4 188 of those
/// nodes resolve every terminal and 889 do not.
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

/// `Bundle By Name` — the base cluster with the named members replaced.
///
/// The node takes the cluster to modify and one value per member it writes,
/// and every input but the base names its member on its own record. So the
/// base is the single input that names no member of the cluster: over the
/// 2 600 bundling nodes whose cluster wire types, exactly one input is that on
/// 2 121 and two or more are on 479, which are refused.
///
/// The result is a whole new value rather than a mutation — a generated cluster
/// class is immutable — so every member the node does not write is copied from
/// the base.
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
  if (name == null) return const [];
  // The base is read once per member the node does not write, so a compound
  // operand is bound to a local rather than re-evaluated.
  final statements = <String>[];
  var carrier = base.expression!;
  if (!_isAtomic(carrier) && written.length < declaration.fields.length) {
    final local = call.names.wire(base.type);
    statements.add('final ${declaration.name} $local = $carrier;');
    carrier = local;
  }
  final names = LvNaming.declarationFields([for (final field in declaration.fields) field.label]);
  final arguments = [
    for (var index = 0; index < declaration.fields.length; index++)
      '${names[index]}: ${written[index]?.expression ?? '$carrier.${names[index]}'}',
  ];
  return statements..add('final ${declaration.name} $name = ${declaration.name}(${arguments.join(', ')});');
}

/// `Merge Errors` — the first of its operands that carries an error, else the
/// first that carries a warning, else the cleared value.
///
/// The operands are taken in drawn order, which is this map's rule for every
/// N-input node (see the library doc) and which the operation's own published
/// description restates: the node is documented as searching its inputs from
/// the topmost terminal down, returning the first error and, when there is
/// none, the first warning. The error/warning/clear split is the error
/// cluster's own ([LvRuntimeType.error]): an error is `status` set, a warning is
/// a non-zero `code` with `status` clear.
///
/// Every operand and the result must be a scalar error cluster; an array of
/// them is ordinary data and has no such reading.
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

/// `Not A Number/Path/Refnum?` over a **floating** operand — IEEE 754's own
/// NaN test, which is what the operation's name states for that carrier and
/// what Dart's `isNaN` is.
///
/// The path and refnum halves of the operation are refused: LabVIEW's
/// Not-A-Path and Not-A-Refnum sentinels are not decoded, so nothing says what
/// value the test compares against.
List<String>? _isNotANumber(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, result = call.outputs.single;
  if (source.type.dims != 0 || !(source.type.numeric?.isFloat ?? false)) return null;
  if (result.type.dims != 0 || result.type.dartType != 'bool') return null;
  final name = result.expression;
  if (name == null) return const [];
  return ['final bool $name = ${source.expression}.isNaN;'];
}

/// A String-typed [expression] spliced into a string interpolation: `$name`
/// for a bare identifier, `${…}` for anything else (including a nested string
/// literal, whose own escaping already holds). Interpolation rather than `+`
/// so the emitted source is idiomatic Dart.
String _interpolated(String? expression) =>
    RegExp(r'^[A-Za-z_]\w*$').hasMatch(expression!) ? '\$$expression' : '\${$expression}';

/// A scalar operation **applied elementwise** to array wires: the node's own
/// rule run over the elements, collected into an array of the result's element
/// type.
///
/// LabVIEW's scalar primitives are polymorphic over arrays, and the wires say
/// when a node is being used that way — every operand and every result is an
/// array of the type the scalar rule takes. The lowering is therefore the
/// scalar lowering itself, emitted into a loop, so every operation the map
/// already carries gains the array form at once and none of them states a rule
/// twice.
///
/// Two shapes are refused rather than modelled:
///
/// - **rank 2 and above**, for the dimension order that refuses every other
///   higher-rank operation ([LvArrayTerminalRole]);
/// - **a mixed node** — an array operand beside a scalar one, which LabVIEW
///   broadcasts. The corpus has 113 of them across the mapped operations
///   (`Equal?` 23, `Multiply` 34, `Add` 14, `Divide` 12, `Subtract` 17, and the
///   rest in ones and twos), and the value the scalar operand contributes at
///   each index is not stated anywhere in the file, so they are left on the
///   review list.
///
/// `Type Cast` is excluded outright: it reads the WHOLE value's bytes, so an
/// array operand is one cast over the concatenated elements rather than one
/// cast per element, and its own rule already takes array wires.
///
/// An operand list longer than one uses [LvRuntimeCall.iterationCount] for its
/// length — the same shortest-operand rule an auto-indexing For loop takes.
List<String>? _elementwise(LvPrimCall call) {
  // Only the operations whose identity is a `primResID`: the classes this map
  // names are array and string operations already, and their own rule is what
  // reads an array wire.
  if (call.op == null && !kLvProvenPrimResIds.contains(call.primResId)) return null;
  if (call.op == PrimOp.typeCast || call.inputs.isEmpty) return null;
  final terminals = [...call.inputs, ...call.outputs];
  if (terminals.any((terminal) => terminal.type.dims != 1)) return null;

  // Each operand array is read once per iteration, so a compound operand is
  // bound to a local first rather than recomputed inside the loop.
  final prologue = <String>[];
  final arrayOf = <int, String>{};
  for (final operand in call.inputs) {
    final expression = operand.expression!;
    if (_isAtomic(expression)) {
      arrayOf[operand.port] = expression;
      continue;
    }
    final local = call.names.wire(operand.type);
    prologue.add('final ${operand.type.dartType} $local = $expression;');
    arrayOf[operand.port] = local;
  }

  // The scalar node the elements go through: the same ports and geometry, with
  // every wire's array wrapping removed.
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

/// `Empty Array?` — whether the operand array holds no elements. Unary, so
/// the roles are the terminals' own directions and there is no operand order
/// to decode. Rank is on the wire, and only rank 1 is lowered: what "empty"
/// means for a rank-2 operand — an empty outer list, or an outer list of empty
/// rows — is not decoded.
List<String>? _emptyArray(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 1 || out.type.dims != 0 || out.type.dartType != 'bool') return null;
  final name = out.expression;
  if (name == null) return const [];
  return ['final bool $name = ${source.expression}.isEmpty;'];
}

/// `Add Array Elements` — the sum of a 1-D numeric array, accumulated at the
/// element's own LabVIEW width so an integer sum wraps exactly where LabVIEW's
/// does (wrapping each step and wrapping once at the end agree modulo the
/// width). Unary, so there is no operand order to decode. An empty array sums
/// to the seed, zero.
///
/// The result must carry the element's own Dart type: a node whose output
/// widens or narrows the element would need LabVIEW's coercion rounding, which
/// is not decoded, and a `U64` operand is refused with it — its carrier is
/// signed, so the accumulator would misread ([LvArithmeticHazard]).
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

/// `Compound Arithmetic` — its operands reduced by the operation
/// [LvCompoundMode] names, in drawn order.
///
/// Only [kLvLoweredCompoundModes] lower, and only when no terminal carries
/// [kLvCompoundInversionBit]. Every operand and the result must be a scalar
/// INTEGER of the result's own kind: an array wire makes the node the
/// elementwise form, LabVIEW's coercion between differing widths is not
/// decoded, exclusive OR has no reading on a float, and float addition is not
/// associative — so a float reduction of three or more operands would turn on
/// an association order the file does not state. Over integers both lowered
/// reductions ARE associative, which is what makes taking the operands in drawn
/// order safe.
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

/// `Initialize Array` — a 1-D array of the drawn size, every cell holding the
/// element operand (see [kLvInitializeArrayClass] for the terminal grammar
/// that names both).
///
/// Rank 2 and above is refused for the reason every other higher-rank
/// operation is ([LvArrayTerminalRole]): the array type's own dimension order
/// is not decoded, so a two-size node cannot say which size is which axis.
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

/// `String Subset` — [length] characters of the string operand from [offset],
/// both taken in drawn order (`[string, offset, length]`; every one of the 669
/// corpus nodes draws its three inputs on distinct rows). The offset is
/// 0-based: 15 corpus nodes wire a `0` constant to it, which a 1-based offset
/// never takes.
///
/// An input LabVIEW leaves unwired reads as a SOURCE terminal, so the node's
/// three input rows are its wired inputs and its spare source ports together,
/// ordered by the row each is drawn on. The **length** may be one of those
/// spares: its unwired default is the rest of the string, which `MD5.vi`
/// depends on — the VI takes its trailing partial block that way, and the RFC
/// 1321 digest of every message whose length is not a multiple of 64 is wrong
/// under any other default. An unwired **offset** (312 corpus nodes) has no
/// such witness and is refused.
///
/// What an operand outside the string yields is not decoded either; the
/// runtime throws there rather than choosing between clamping and emptying
/// (see `TODO(lv-string-subset-range)`).
List<String>? _stringSubset(LvPrimCall call) {
  if (call.outputs.length != 1) return null;
  final out = call.outputs.single;
  if (out.type.dims != 0 || out.type.dartType != 'String') return null;
  final rows = call.portsTopDown([
    for (final operand in call.inputs) operand.port,
    for (final port in call.outputPorts)
      if (port != out.port) port,
  ]);
  if (rows == null || rows.length != 3) return null;
  final wired = {for (final operand in call.inputs) operand.port: operand};
  final string = wired[rows[0]], offset = wired[rows[1]], length = wired[rows[2]];
  if (string == null || offset == null) return null;
  if (string.type.dims != 0 || string.type.dartType != 'String') return null;
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

/// `To Lower Case` over a scalar string — LabVIEW's case mapping, which the
/// runtime carries for the ASCII range and refuses above it (see
/// `TODO(lv-lowercase-high)`). The node's numeric and array forms are refused:
/// what a character CODE lowers to is the same undecoded table.
List<String>? _toLowerCase(LvPrimCall call) {
  if (call.inputs.length != 1 || call.outputs.length != 1) return null;
  final source = call.inputs.single, out = call.outputs.single;
  if (source.type.dims != 0 || source.type.dartType != 'String') return null;
  if (out.type.dims != 0 || out.type.dartType != 'String') return null;
  final name = out.expression;
  if (name == null) return const [];
  call.requireImport(kLvRuntimeImport);
  return ['final String $name = ${LvRuntimeCall.toLowerCase}(${source.expression});'];
}

/// `Wait (ms)` — the one operand is the wait, the one result is the millisecond
/// timer read after it. There is no operand order to decode: the node draws one
/// input and one output, which the published reference names `milliseconds to
/// wait` and `millisecond timer value`, both unsigned 32-bit.
///
/// Unlike every other lowering here, the statement is emitted even when nothing
/// consumes the result: the elapsed time is the point of the node, so dropping
/// the call because its output is unwired would drop the operation itself.
///
/// A float or array operand is a coercion LabVIEW performs at the terminal and
/// what it rounds toward is not established; a result wire of some other width
/// is not what the node yields. Both are refused.
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

/// The rotation node ([kLvRotatePrimResId]) — the LOWER operand rotated toward
/// the high bits by the upper one. Which operand is which is `Logical Shift`'s
/// own reading, on `Logical Shift`'s own terminal grammar (see
/// [kLvProvenPrimResIds] and [_logicalShift]): the value is the operand
/// carrying the result's numeric kind, which is the lower-drawn one.
///
/// Only the proven shape lowers: a 32-bit integer result. The count stays a
/// run-time value even there — `MD5.vi` reads it from a table — so it is
/// [LvRuntimeCall.rotate] that refuses one outside a single width.
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

/// The hexadecimal number-to-string node ([kLvHexStringPrimResId]) — the UPPER
/// operand written in hexadecimal at the lower operand's width.
///
/// The drawn order is the same rule every other ordered node takes, and the
/// wires state it independently here: the width operand is an I16 on all 14
/// corpus nodes while the value carries the width of whatever is being
/// formatted, and the I16 is the lower-drawn terminal on every one of them.
///
/// Only the proven shape lowers: a 32-bit value. The field width is the wire's
/// own, and [LvRuntimeCall.hexString] refuses one the value overflows, which is
/// the only case the readings of it differ on. The digits are upper case on the
/// VI's own evidence — it follows the four conversions with a `To Lower Case`,
/// a no-op on a conversion that already writes lower case. The digests hold for
/// the PAIR either way, so they prove the radix and not the case.
List<String>? _hexString(LvPrimCall call) {
  if (call.inputs.length != 2 || call.outputs.length != 1 || !call.hasSoleSourceTerminal) return null;
  final ordered = call.inputsTopDown;
  if (ordered == null) return null;
  final (value, width) = (ordered[0], ordered[1]);
  final out = call.outputs.single;
  final kind = value.type.numeric;
  if (out.type.dims != 0 || out.type.dartType != 'String') return null;
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
