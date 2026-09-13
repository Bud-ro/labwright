/// The object tree of one C4 record heap: [buildDiagram] replays an `FPHb` or `BDHb` body
/// through [walkHeapObjects] and turns every object header into a [ViHeapObject], every
/// record it carries into a field of that object, and every `signal` object into a [ViWire]
/// with its decoded route.
///
/// Which records feed which fields:
///
/// ```text
/// record                                   field
/// object header                            oid, kind, objectClass, offset, parentOid
/// C4 bounds (0x2d)                         bounds; absBounds accumulates the ancestors' origins
/// C4 size (0x1f)                           termCount, one per record
/// C4 caption (0x22), attribute shortText   label
/// C4 formatString (0x74)                   typeKind (format conversion character)
/// C4 stringTable (0x2e)                    items
/// C4 description (0x19)                    helpText
/// C4 plotName (0x27)                       plotNames
/// C4 path (0xa4), symbolName (0xc4)        foreignLibraryPath, foreignEntryPoint (Call Library nodes)
/// reference records                        refs (childRef targets), typedRefs (all kinds)
/// attributes                               controlMin/Max, constText, constValueRaw, displayFormat,
///                                          labelModeWord, termBounds, termBmp, typeDescIdx, objFlags,
///                                          primResId, dIdx, wireTableRaw, defaultFrameIndex,
///                                          lastSignalKind, the *Rgb colours, plotColors
/// font run groups                          textStyleRuns
/// array index group                        arrayIndex
/// case selector groups                     selectorRanges, selectorStrings
/// ```
///
/// [resolveDataSpaceTypes] then joins the diagrams to the type pool through the data-space type
/// map (`TM80`), filling `dataType`, `resolvedType` and the member lists, and
/// [decodeBdConstValues] reads each constant's flat value through its type.
///
/// [ViDiagram] indexes the objects by oid and parent and derives the wires; [ViWire] carries a
/// wire's endpoints, anchors and route; [ViWireRoute], [ViWireBranchRoute] and
/// [ViWireRouteTree] are the decoded route tables; [ViSignalType] is a wire's type word;
/// [HeapObjectClass] names the object classes.
library;

import 'dart:math';
import 'dart:typed_data';

import '../blocks/FTAB_font_table.dart';
import '../blocks/VCTP_type_pool.dart';
import '../heap/heap.dart';
import 'obj_flags.dart';
import 'prim_ops.dart';

/// What role an object plays on a diagram; [classifyObject] assigns it from the object's
/// [HeapObjectClass] and terminal count.
enum ViObjectKind {
  /// An object that carries terminals: a node's terminal group or any object with a size record.
  terminalCluster,

  /// A control, indicator, label, constant or other single terminal object.
  terminal,

  /// A primitive, subVI call or other executable node.
  node,

  /// A loop, case, sequence or other container that owns a sub-diagram.
  structure,

  /// One sub-diagram frame of a multi-frame structure.
  frame,

  /// Chrome, glyphs and free decorations that carry no data.
  decoration,

  /// A signal or wire segment.
  wire,

  /// A class whose role is not established.
  unknown,
}

/// The broad data type of an object or wire; [inferTypeKind] guesses it from the object's
/// records and [resolveDataSpaceTypes] replaces the guess with the pool type's kind.
enum ViTypeKind {
  /// A signed or unsigned integer.
  numericInt,

  /// A floating-point or complex number.
  numericFloat,

  /// An enum or ring.
  enumRing,

  /// A file-system path.
  path,

  /// A Call Library node's symbol.
  clnNode,

  /// A string.
  string,

  /// A boolean.
  boolean,

  /// A cluster.
  cluster,

  /// An array of any element type.
  array,

  /// A refnum.
  refnum,

  /// Not established.
  unknown,
}

/// The `selectDefaultCase` value of a case structure without a default frame.
const int kViNoDefaultFrame = 255;

/// The frame index a case structure without a `selectDefaultCase` attribute defaults to.
const int kViFirstFrameIsDefault = 0;

/// Group tags that open a case structure's selector data: the range lists and the string pool.
final Set<int> kViSelectorGroupTags = {
  HeapGroupTag.selectorRangeList.tag,
  HeapGroupTag.selectorRangeListAlt.tag,
  HeapGroupTag.selectorStringPool.tag,
};

int _signedAtWidth(int value, HeapAttrWidth width) => switch (width) {
  HeapAttrWidth.u8 => value.toSigned(8),
  HeapAttrWidth.u16 => value.toSigned(16),
  HeapAttrWidth.u24 => value.toSigned(24),
  HeapAttrWidth.rgb => value.toSigned(32),
  _ => value,
};

String? _selectorPoolString(Uint8List body, int offset, int lead, int span) {
  if (lead == kHeapRecordPrefix) {
    if (offset + 3 > body.length) return null;
    final count = body[offset + 2];
    if (3 + count > span || offset + 3 + count > body.length) return null;
    return String.fromCharCodes(body.sublist(offset + 3, offset + 3 + count));
  }
  final attr = decodeHeapAttr(body, offset);
  final value = attr?.asInt;
  if (attr == null || value == null) return null;
  final bytes = switch (attr.width) {
    HeapAttrWidth.u8 => 1,
    HeapAttrWidth.u16 => 2,
    HeapAttrWidth.u24 => 3,
    HeapAttrWidth.rgb => 4,
    _ => 0,
  };
  final chars = [for (var i = bytes - 1; i >= 0; i--) (value >> (8 * i)) & 0xff];
  return String.fromCharCodes(chars.skipWhile((char) => char == 0));
}

/// How one end of a case-selector range is bounded.
enum ViSelectorBound {
  /// The range is one value.
  single(0),

  /// The end is inclusive.
  inclusive(1),

  /// The range is open at this end (`..N` or `N..`).
  unbounded(3)
  ;

  const ViSelectorBound(this.code);

  final int code;

  /// The bound with [code], or null for a code not listed.
  static ViSelectorBound? ofCode(int code) => switch (code) {
    0 => single,
    1 => inclusive,
    3 => unbounded,
    _ => null,
  };
}

/// One entry of a case structure's selector range list: the values [low]..[high] select
/// [frame]; a bound is null when its code is not a [ViSelectorBound].
class ViSelectorRange {
  const ViSelectorRange({
    required this.low,
    required this.high,
    required this.lowBound,
    required this.highBound,
    required this.frame,
  });

  final int low;

  final int high;

  final ViSelectorBound? lowBound;

  final ViSelectorBound? highBound;

  /// The index of the frame this range selects.
  final int frame;

  bool get isSingle => lowBound == ViSelectorBound.single && highBound == ViSelectorBound.single;

  bool get isClosed => lowBound == ViSelectorBound.inclusive && highBound == ViSelectorBound.inclusive;
}

/// One object of a record heap with every field the walk decoded from its records; unset
/// fields are null, zero or empty. Coordinates are in pixels; [bounds] is relative to the
/// parent's origin and [absBounds] to the diagram's.
class ViHeapObject {
  ViHeapObject({required this.oid, required this.kind, required this.offset})
    : objectClass = HeapObjectClass.fromCode(kind);

  /// The object id the header declares; references name objects by it.
  final int oid;

  /// The class code the header declares, also when no [HeapObjectClass] names it.
  final int kind;

  final HeapObjectClass objectClass;

  /// Byte offset of the object header in the heap body.
  final int offset;

  /// The bounds record, relative to the parent object's origin.
  HeapRect? bounds;

  /// [bounds] shifted by every ancestor's origin; null for objects without a bounds record.
  HeapRect? absBounds;

  /// The enclosing object, null for a root.
  int? parentOid;

  /// The caption record, else the `shortText` attribute, else for a node the first child label.
  String? label;

  /// Targets of the object's `childRef` references, in record order; a signal's are its endpoints.
  final List<int> refs = <int>[];

  /// Targets of every reference, by kind.
  final Map<HeapRefKind, List<int>> typedRefs = <HeapRefKind, List<int>>{};

  /// The `childRef` and `dcoRef` targets together.
  Iterable<int> get memberOids => <int>{
    ...?typedRefs[HeapRefKind.childRef],
    ...?typedRefs[HeapRefKind.dcoRef],
  };

  /// The number of size records ([HeapOpcode.size]) the object carries.
  int termCount = 0;

  // TODO: a font run's colour record (raw 0x029) is not captured.
  /// The font runs of the object's text: each starts at a character index and names an `FTAB`
  /// font id.
  List<({int start, int fontId})> textStyleRuns = const [];

  /// The `FTAB` entry of the label's first font run, set by the model once the font table is read.
  ViFontEntry? labelFont;

  bool get labelIsBold => labelFont?.isBold ?? false;

  ViObjectKind category = ViObjectKind.unknown;

  ViTypeKind typeKind = ViTypeKind.unknown;

  /// Enum or ring item names from the string table record, copied up to the owning control.
  List<String> items = const [];

  /// Plot names of a graph or chart, one per plot-name record.
  List<String> plotNames = const [];

  /// The `stdNumMin` attribute of a control terminal.
  double? controlMin;

  /// The `stdNumMax` attribute of a control terminal.
  double? controlMax;

  /// The description record, copied up to the nearest bounded ancestor when the object has no bounds.
  String? helpText;

  /// A constant's text, from the `constValue` attribute or [decodeBdConstValues].
  String? constText;

  /// A constant's numeric value, from [decodeBdConstValues].
  num? constNumeric;

  /// A constant's boolean value, from [decodeBdConstValues].
  bool? constBool;

  /// The flat bytes of a constant DCO's `constValue` attribute.
  Uint8List? constValueRaw;

  /// Whether [constValueRaw] came from a scalar attribute width rather than a container blob.
  bool constValueScalar = false;

  /// A numeric array constant's elements in row-major order, from [decodeBdConstValues].
  List<num>? constArray;

  /// The dimension sizes of [constArray].
  List<int>? constArrayDims;

  /// The `cosmColorB` word of a label, read as a mode word: `0x20` centres the text, `0x800000`
  /// widens the text inset.
  int? labelModeWord;

  bool get labelJustifyCenter => ((labelModeWord ?? 0) & 0x20) != 0;

  /// The inset between a label's box and its text, in pixels.
  int get labelTextInset => ((labelModeWord ?? 0) & 0x800000) != 0 ? 2 : 1;

  /// The displayed element index of an array container, from its array index group.
  int? arrayIndex;

  /// A case structure's selector ranges.
  List<ViSelectorRange> selectorRanges = const <ViSelectorRange>[];

  /// A case structure's selector strings.
  List<String> selectorStrings = const <String>[];

  /// A case structure's default frame, null when the attribute holds [kViNoDefaultFrame].
  int? defaultFrameIndex;

  /// The `formatStyle` attribute of a numeric display, a `%` format string.
  String? displayFormat;

  /// The `backgroundColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? bgRgb;

  /// The `fgColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? fgRgb;

  /// The `contentColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? contentRgb;

  /// The `structColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? structRgb;

  /// The `borderColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? borderRgb;

  /// The `termBounds` attribute: a terminal's box relative to the nearest bounded ancestor's
  /// origin.
  HeapRect? termBounds;

  /// The `termBMPs` attribute: which glyph the terminal draws.
  int? termBmp;

  /// The `typeDescIndex` attribute: an index into the data-space type map, resolved by
  /// [resolveDataSpaceTypes].
  int? typeDescIdx;

  /// The label of the resolved pool type.
  String? typeName;

  /// The kind of the resolved pool type.
  ViDataType? dataType;

  /// The pool type [typeDescIdx] resolves to, else the one of the object's `dcoRef` target.
  ViType? resolvedType;

  /// The element type when [resolvedType] is an array.
  ViType? resolvedElementType;

  /// The member types when [resolvedType] is a cluster.
  List<ViType> resolvedMembers = const [];

  /// The member types when [resolvedElementType] is a cluster.
  List<ViType> resolvedElementMembers = const [];

  /// The `objFlags` attribute; [ViObjFlag] names the decoded bits.
  int? objFlags;

  /// The `primResID` attribute of a primitive node; [PrimOp] names the ids.
  int? primResId;

  String? get primName {
    final id = primResId;
    return id == null ? null : PrimOp.fromId(id)?.opName;
  }

  /// A Call Library node's library path record.
  String? foreignLibraryPath;

  /// A Call Library node's symbol name record.
  String? foreignEntryPoint;

  /// A signal's `compressedWireTable` attribute, decoded by [decodeWireRoute] and
  /// [decodeWireBranchRoute].
  Uint8List? wireTableRaw;

  /// A signal's `lastSignalKind` attribute; [ViSignalType] reads it.
  int? lastSignalKind;

  /// The `dIdx` attribute of a multi-frame structure.
  int? dIdx;

  /// The frame a multi-frame structure shows: [dIdx] without its high bit.
  int get visibleFrameIndex => (dIdx ?? 0) & 0x7fffffff;

  /// Whether every bit of [flag] is set in [objFlags].
  bool hasFlag(ViObjFlag flag) => ((objFlags ?? 0) & flag.mask) == flag.mask;

  bool get isLabelHidden => objectClass == HeapObjectClass.controlLabel && hasFlag(ViObjFlag.labelHidden);

  /// Whether a front-panel control is an indicator, from its [ViObjFlag.indicator] bit or its
  /// `dcoRef` target's; null until [resolveDataSpaceTypes] runs or when neither states it.
  bool? isIndicator;

  /// The `plotColor` attributes as `0xRRGGBB`, one per plot.
  List<int> plotColors = const [];
}

/// How well a [HeapObjectClass] row's role is established.
enum ClassConfidence {
  /// Named from a corpus law or a reference render.
  confirmed,

  /// Named from consistent corpus evidence without a direct check.
  inferred,

  /// Only the class code and its category are known.
  kindOnly,
}

/// The classes an object header declares, by code; [label] is the display name and
/// [category] the role [classifyObject] starts from.
enum HeapObjectClass {
  diagramRoot(0x7e, 'Diagram root', ViObjectKind.structure, ClassConfidence.confirmed),

  diagramFrame(0x4c, 'Panel root frame (FP)', ViObjectKind.structure, ClassConfidence.confirmed),

  diagramProps(0x7f, 'Diagram properties', ViObjectKind.structure, ClassConfidence.inferred),

  bdWire(0x1d, 'Wire segment (BD)', ViObjectKind.wire, ClassConfidence.inferred),

  signal(0x17, 'Signal / dataflow wire (BD)', ViObjectKind.wire, ClassConfidence.inferred),

  rootAux(0x101, 'Root auxiliary', ViObjectKind.unknown, ClassConfidence.kindOnly),

  loop(0x53, 'Loop (BD) / container (FP)', ViObjectKind.structure, ClassConfidence.confirmed),

  caseOrSequence(0x52, 'Container (placed controls)', ViObjectKind.structure, ClassConfidence.inferred),

  clusterShell(0x64, 'Cluster/array shell', ViObjectKind.structure, ClassConfidence.inferred),

  bdStructureFrame(0x2c, 'Case structure', ViObjectKind.structure, ClassConfidence.inferred),

  bdForLoop(0x20, 'For loop', ViObjectKind.structure, ClassConfidence.inferred),

  bdWhileLoop(0x21, 'While loop', ViObjectKind.structure, ClassConfidence.inferred),

  bdDisableStructure(0xcd, 'Disable structure', ViObjectKind.structure, ClassConfidence.inferred),

  bdInPlaceStructure(0x14d, 'In Place Element structure', ViObjectKind.structure, ClassConfidence.inferred),

  bdFlatSequence(0xca, 'Flat Sequence structure', ViObjectKind.structure, ClassConfidence.inferred),

  bdStackedSequence(0x29, 'Stacked Sequence structure', ViObjectKind.structure, ClassConfidence.inferred),

  bdEventStructure(0xd5, 'Event structure', ViObjectKind.structure, ClassConfidence.inferred),

  bdSequenceFrame(0x121, 'Sequence frame', ViObjectKind.structure, ClassConfidence.inferred),

  bdSelectorLabel(0x95, 'Case selector label', ViObjectKind.terminal, ClassConfidence.inferred),

  bdGlyph(0x177, 'Node glyph', ViObjectKind.decoration, ClassConfidence.kindOnly),

  subdiagramContainer(0xc7, 'Subdiagram container', ViObjectKind.structure, ClassConfidence.inferred),

  rareStructure(0xef, 'Structure (rare)', ViObjectKind.structure, ClassConfidence.kindOnly),

  nodeGroup(0xac, 'Node group', ViObjectKind.structure, ClassConfidence.kindOnly),

  contentViewport(0x11c, 'Content viewport', ViObjectKind.structure, ClassConfidence.confirmed),

  node(0x12, 'Content group (FP)', ViObjectKind.node, ClassConfidence.confirmed),

  bdConstDco(0x13, 'Constant DCO (BD)', ViObjectKind.unknown, ClassConfidence.inferred),

  bdNode(0x2f, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNamedNode(0x31, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  bdGrowableNode(0x63, 'Node (growable)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode8c(0x8c, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  bdNode3a(0x3a, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNoded6(0xd6, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  bdNode32(0x32, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  bdNodeC5(0xc5, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode104(0x104, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode124(0x124, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode44(0x44, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode3e(0x3e, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode34(0x34, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNodeA9(0xa9, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  bdNode93(0x93, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode172(0x172, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode6c(0x6c, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode36(0x36, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode153(0x153, 'Node (In Place Element)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode150(0x150, 'Node (In Place Element border)', ViObjectKind.node, ClassConfidence.kindOnly),

  bdNode14f(0x14f, 'Node (In Place Element border)', ViObjectKind.node, ClassConfidence.kindOnly),

  bdNode152(0x152, 'Node (In Place Element border)', ViObjectKind.node, ClassConfidence.kindOnly),

  bdCallLibrary(0x6a, 'Call Library node', ViObjectKind.node, ClassConfidence.confirmed),

  bdNodeBd(0xbd, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode114(0x114, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNodeB6(0xb6, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  bdNodeB9(0xb9, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode48(0x48, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  bdNodeEb(0xeb, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  bdNode103(0x103, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  bdNode14a(0x14a, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  bdLeaf(0x16, 'Terminal/constant (BD)', ViObjectKind.terminal, ClassConfidence.inferred),

  bdConstant4e(0x4e, 'Constant/terminal (BD)', ViObjectKind.terminal, ClassConfidence.inferred),

  numericControl(0x50, 'Numeric control', ViObjectKind.terminal, ClassConfidence.confirmed),

  enumRingControl(0x57, 'Enum/ring control', ViObjectKind.terminal, ClassConfidence.confirmed),

  booleanOrClusterControl(0x4f, 'Boolean/cluster control', ViObjectKind.terminal, ClassConfidence.inferred),

  stringOrArrayControl(0x51, 'String/array control', ViObjectKind.terminal, ClassConfidence.inferred),

  controlTerminal55(0x55, 'Control terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  controlTerminal10c(0x10c, 'Control terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  constantC2(0xc2, 'Constant/terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  pathControl(0x5b, 'Path control', ViObjectKind.terminal, ClassConfidence.inferred),

  graphIndicator(0x5e, 'Graph/chart indicator', ViObjectKind.terminal, ClassConfidence.inferred),

  numericControlVariant(0xdf, 'Numeric control (variant)', ViObjectKind.terminal, ClassConfidence.inferred),

  controlVariant(0x59, 'Control (variant)', ViObjectKind.terminal, ClassConfidence.kindOnly),

  nodeTerminalCluster(0x0c, 'Terminal cluster', ViObjectKind.terminalCluster, ClassConfidence.confirmed),

  controlLabel(0x0a, 'Label', ViObjectKind.terminal, ClassConfidence.confirmed),

  connectorTerminal(0x68, 'Connector terminal', ViObjectKind.terminal, ClassConfidence.confirmed),

  controlSubPart(0x0b, 'Control sub-part', ViObjectKind.terminal, ClassConfidence.inferred),

  numericDisplay(0xe0, 'Numeric display', ViObjectKind.terminal, ClassConfidence.confirmed),

  enumItemList(0x0d, 'Enum item list', ViObjectKind.terminal, ClassConfidence.confirmed),

  tipStrip(0xc1, 'Tip strip', ViObjectKind.terminal, ClassConfidence.confirmed),

  bdPolySelector(0xe5, 'Polymorphic instance selector (BD)', ViObjectKind.unknown, ClassConfidence.inferred),

  controlChrome(0x09, 'Resize handle/chrome', ViObjectKind.decoration, ClassConfidence.inferred),

  freeDecoration(0x8f, 'Decoration', ViObjectKind.decoration, ClassConfidence.inferred),

  graphLegend(0xe7, 'Graph legend', ViObjectKind.decoration, ClassConfidence.inferred),

  legendSubPart(0xd2, 'Legend sub-part', ViObjectKind.decoration, ClassConfidence.inferred),

  rare58(0x58, 'Undetermined (0x58)', ViObjectKind.unknown, ClassConfidence.kindOnly),

  rareStructureC3(0xc3, 'Structure (rare 0xC3)', ViObjectKind.structure, ClassConfidence.kindOnly),

  rareC8(0xc8, 'Undetermined (0xC8)', ViObjectKind.unknown, ClassConfidence.kindOnly),

  controlRare56(0x56, 'Control (rare 0x56)', ViObjectKind.terminal, ClassConfidence.kindOnly),

  bdFrame(0x1b, 'Structure frame', ViObjectKind.frame, ClassConfidence.inferred),

  bdLoopTunnel(0x22, 'Loop tunnel', ViObjectKind.terminal, ClassConfidence.inferred),

  bdTunnelIndexer(0x23, 'Tunnel indexer', ViObjectKind.terminal, ClassConfidence.inferred),

  bdIterationTerminal(0x24, 'Iteration terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  bdConditionalTerminal(0x25, 'Conditional terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  bdCountTerminal(0x26, 'Count terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  bdLeftShiftRegister(0x27, 'Left shift register', ViObjectKind.terminal, ClassConfidence.inferred),

  bdRightShiftRegister(0x28, 'Right shift register', ViObjectKind.terminal, ClassConfidence.inferred),

  bdBorderTerminal2a(0x2a, 'Border terminal (0x2A)', ViObjectKind.terminal, ClassConfidence.kindOnly),

  bdCaseTunnel(0x2d, 'Case tunnel', ViObjectKind.terminal, ClassConfidence.inferred),

  bdSelectorTerminal(0x2e, 'Case selector terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  bdTerminalStrip35(0x35, 'Node terminal strip (0x35)', ViObjectKind.terminal, ClassConfidence.kindOnly),

  bdTerminalStrip(0x62, 'Node terminal strip', ViObjectKind.terminal, ClassConfidence.inferred),

  bdBorderTerminalCb(0xcb, 'Border terminal (0xCB)', ViObjectKind.terminal, ClassConfidence.kindOnly),

  bdDisableTunnel(0xce, 'Disable-structure tunnel', ViObjectKind.terminal, ClassConfidence.inferred),

  bdXnode(0x105, 'XNode', ViObjectKind.node, ClassConfidence.inferred),

  unknown(-1, 'Unknown class', ViObjectKind.unknown, ClassConfidence.kindOnly)
  ;

  const HeapObjectClass(this.code, this.label, this.category, this.confidence);

  final int code;

  final String label;

  final ViObjectKind category;

  final ClassConfidence confidence;

  static final Map<int, HeapObjectClass> _byCode = {
    for (final objectClass in values)
      if (objectClass != unknown) objectClass.code: objectClass,
  };

  /// The class with [code], or [unknown].
  static HeapObjectClass fromCode(int code) => _byCode[code] ?? unknown;
}

/// Classes of the terminal objects that carry a control's value: numeric, boolean/cluster,
/// enum/ring, path and string/array.
const kControlTerminalClasses = {
  HeapObjectClass.numericControl,
  HeapObjectClass.booleanOrClusterControl,
  HeapObjectClass.enumRingControl,
  HeapObjectClass.pathControl,
  HeapObjectClass.stringOrArrayControl,
};

/// Class codes a signal's endpoint references target: a node endpoint DCO or a leaf.
final Set<int> kSignalEndpointDcoKinds = {kNodeEndpointDcoKind, HeapObjectClass.bdLeaf.code};

/// The class code of a node's endpoint DCO, the object a wire ends on inside a node.
const int kNodeEndpointDcoKind = 0x15;

/// Pixels a wire's attach point moves left of a right shift register's column centre.
const int kShiftRegisterColumnLeftOffset = 4;

/// Pixels a wire's attach point moves right of a left shift register's column centre.
const int kShiftRegisterColumnRightOffset = 4;

/// Classes of a node's terminal strip, the column of terminals along its edge.
const kBdTerminalStripClasses = {HeapObjectClass.bdTerminalStrip, HeapObjectClass.bdTerminalStrip35};

/// Width in pixels of a terminal strip's attach box.
const int kTerminalStripColumnWidth = 8;

/// Pixels a wire's target lies left of a terminal strip's attach point.
const int kTerminalStripTargetLeftOffset = 8;

const _objAttrIds = {
  0x20, 0x21, 0x6c, 0x24, 0x28, 0x6f, 0x19, 0x2b, 0x2a, 0x29, 0x3a, 0xcb, 0xea, 0xe7, 0x4d, 0x9f, 0x22, 0x74, //
  0x54,
};

/// Structures that hold one frame per case, event or sequence step and show one at a time.
const kMultiFrameStructureClasses = {
  HeapObjectClass.bdStructureFrame,
  HeapObjectClass.bdDisableStructure,
  HeapObjectClass.bdEventStructure,
  HeapObjectClass.bdStackedSequence,
};

const int _structureAreaCap = 20000;

String _fmtNum(double v) => v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();

/// A control's range as `lo … hi`, `≥ lo` or `≤ hi`; null when neither bound is finite or
/// the bounds are inverted.
String? formatControlRange(double? min, double? max) {
  if (min?.isNaN == true || max?.isNaN == true) return null;
  final lo = (min != null && min.isFinite) ? min : null;
  final hi = (max != null && max.isFinite) ? max : null;
  if (lo == null && hi == null) return null;
  if (lo != null && hi != null) return lo >= hi ? null : '${_fmtNum(lo)} … ${_fmtNum(hi)}';
  return lo != null ? '≥ ${_fmtNum(lo)}' : '≤ ${_fmtNum(hi!)}';
}

/// Help text without its `<tag>` markup and runs of spaces.
String stripHelpMarkup(String helpText) {
  final out = helpText.replaceAll(_helpMarkupTag, '').replaceAll(_interiorSpaces, ' ').trim();
  return out.isEmpty ? helpText.trim() : out;
}

final RegExp _helpMarkupTag = RegExp(r'<\s*/?\s*[A-Za-z][A-Za-z0-9]*\s*>');
final RegExp _interiorSpaces = RegExp(r'[ \t]{2,}');

/// The role of an object: a terminal cluster when it is one or carries a size record, else
/// its class's category.
ViObjectKind classifyObject({required HeapObjectClass objectClass, required int termCount}) =>
    objectClass == HeapObjectClass.nodeTerminalCluster || termCount >= 1
    ? ViObjectKind.terminalCluster
    : objectClass.category;

const _intConvChars = {0x62, 0x64, 0x6f, 0x78, 0x58};

int? _formatConvChar(List<int> payload) {
  final pct = payload.indexOf(0x25);
  if (pct < 0) return null;
  for (final byte in payload.skip(pct + 1)) {
    if ((byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)) return byte;
  }
  return null;
}

/// A type kind guessed from the C4 opcodes an object carries: a symbol name means a Call
/// Library node, a path record a path, a string table an enum or ring, and a format string a
/// number whose conversion character tells integer from float.
ViTypeKind inferTypeKind(Set<int> c4ops, List<int>? formatPayload) {
  if (c4ops.contains(0xc4)) return ViTypeKind.clnNode;
  if (c4ops.contains(0xa4)) return ViTypeKind.path;
  if (c4ops.contains(0x2e)) return ViTypeKind.enumRing;
  if (c4ops.contains(0x74)) {
    final conv = formatPayload == null ? null : _formatConvChar(formatPayload);
    return (conv != null && _intConvChars.contains(conv)) ? ViTypeKind.numericInt : ViTypeKind.numericFloat;
  }
  return ViTypeKind.unknown;
}

/// A signal's `lastSignalKind` word: the low byte is the `VCTP` type code, bits 8–11 the
/// depth (the scalar depth of the code plus one per array dimension), bits 12–15 flags.
class ViSignalType {
  const ViSignalType(this.raw);

  final int raw;

  /// The type code of a cluster carried as a variant.
  static const int clusterVariantCode = 0x51;

  /// The type code of a typed refnum.
  static const int typedRefnumCode = 0x71;

  int get typeCode => raw & 0xff;

  int get depth => (raw >> 8) & 0xf;

  // TODO: the flag nibble's meaning is not decoded.
  int get flags => (raw >> 12) & 0xf;

  /// The data type of [typeCode]; null for a code the pool grammar does not name.
  ViDataType? get dataType => switch (typeCode) {
    clusterVariantCode => ViDataType.cluster,
    typedRefnumCode => ViDataType.refnum,
    _ => dataTypeOfCode(typeCode),
  };

  /// The kind of the scalar or element type.
  ViTypeKind? get elementKind {
    final t = dataType;
    return t == null ? null : typeKindOfDataType(t);
  }

  /// Array dimensions: [depth] above the code's scalar depth; null when the code's scalar depth
  /// is not established and the depth is not the minimum.
  int? get arrayDims {
    final base = _signalScalarDepth(typeCode);
    if (base == null) return depth == kSignalMinScalarDepth ? 0 : null;
    final dims = depth - base;
    return dims < 0 ? null : dims;
  }

  bool? get isArray {
    final dims = arrayDims;
    return dims == null ? null : dims > 0;
  }

  /// [ViTypeKind.array] for an array, else [elementKind].
  ViTypeKind? get typeKind => isArray == true ? ViTypeKind.array : elementKind;

  @override
  bool operator ==(Object other) => other is ViSignalType && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;
}

/// The depth of a scalar numeric signal.
const int kSignalMinScalarDepth = 1;

int? _signalScalarDepth(int code) {
  if (code >= TypeCode.i8 && code <= TypeCode.complexExt) return 1;
  if (code >= TypeCode.enumU8 && code <= TypeCode.enumU32) return 1;
  if (code == TypeCode.booleanU16 || code == TypeCode.boolean) return 1;
  if (code == TypeCode.string || code == TypeCode.path || code == TypeCode.picture) return 2;
  if (code == TypeCode.cluster ||
      code == ViSignalType.clusterVariantCode ||
      code == TypeCode.variant ||
      code == TypeCode.measureData) {
    return 3;
  }
  return null;
}

/// How a decoded route was placed on the diagram.
enum WireRouteFidelity {
  /// The walk from one endpoint's attach point lands exactly on the other's.
  closed,

  /// The walk is anchored at one endpoint and ends inside the other's box.
  walked,
}

/// One `signal` object of a block diagram as a wire: its endpoints, where each attaches, and
/// its route in diagram pixels. The endpoint at index 0 is where the route table starts.
class ViWire {
  ViWire({
    required this.signalOid,
    required this.endpointOids,
    required this.endpointAnchors,
    List<HeapRect?>? endpointAttachRects,
    this.route,
    this.routePoints,
    this.routePointsFidelity,
    this.routeClosingStep,
    this.routeHeadSlack,
    this.branchRoute,
    ViWireRouteTree? routeTree,
    WireRouteFidelity? routeTreeFidelity,
    ({ViWireRouteTree tree, WireRouteFidelity fidelity})? Function()? routeTreeBuilder,
    this.signalType,
  }) : endpointAttachRects = endpointAttachRects ?? List<HeapRect?>.filled(endpointOids.length, null),
       _routeTree = routeTree,
       _directRouteTreeFidelity = routeTreeFidelity,
       _routeTreeBuilder = routeTreeBuilder;

  final ViWireRouteTree? _routeTree;
  final WireRouteFidelity? _directRouteTreeFidelity;
  final ({ViWireRouteTree tree, WireRouteFidelity fidelity})? Function()? _routeTreeBuilder;

  final int signalOid;

  /// The signal's `childRef` targets, in record order.
  final List<int> endpointOids;

  /// Per endpoint, the constant's bounds or the nearest bounded ancestor's; null when none.
  final List<HeapRect?> endpointAnchors;

  /// Per endpoint, the terminal's absolute `termBounds`, else the constant's bounds.
  final List<HeapRect?> endpointAttachRects;

  /// The decoded route table of a two-endpoint wire.
  final ViWireRoute? route;

  /// The decoded route table of a wire with three or more endpoints.
  final ViWireBranchRoute? branchRoute;

  late final ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _routeTreeResult = _routeTreeBuilder?.call();

  /// [branchRoute] walked from a solved origin; null when no origin closes it.
  late final ViWireRouteTree? routeTree = _routeTree ?? _routeTreeResult?.tree;

  late final WireRouteFidelity? routeTreeFidelity = routeTree == null
      ? null
      : (_routeTree != null ? _directRouteTreeFidelity : _routeTreeResult?.fidelity);

  /// [route] walked from a solved origin, as the corners of the polyline; null when no
  /// candidate attach point closes it.
  final List<ViPoint>? routePoints;

  final WireRouteFidelity? routePointsFidelity;

  /// For a walked route whose tail already lies inside the far box: the one-pixel direction the
  /// tail should keep moving in.
  final ViStep? routeClosingStep;

  /// For a route solved from its tail: the direction the head end may slide along.
  final ViStep? routeHeadSlack;

  /// The signal's type word.
  final ViSignalType? signalType;

  ViTypeKind? get typeKind => signalType?.typeKind;

  ViTypeKind? get elementTypeKind => signalType?.elementKind;
}

/// A diagram position in pixels.
typedef ViPoint = ({int x, int y});

/// A unit direction or offset in pixels.
typedef ViStep = ({int dx, int dy});

/// The direction of a route's first segment, as the route table codes it; the codes are bits
/// so a branch route's first mode can name several.
enum WireRouteDirection {
  up(0x01, 0, -1),

  left(0x02, -1, 0),

  down(0x04, 0, 1),

  right(0x08, 1, 0)
  ;

  const WireRouteDirection(this.code, this.dx, this.dy);

  final int code;

  final int dx;

  final int dy;

  bool get isHorizontal => dy == 0;

  static final Map<int, WireRouteDirection> _byCode = {
    for (final value in values) value.code: value,
  };

  /// The direction with [code], or null when the code is not exactly one direction.
  static WireRouteDirection? fromCode(int code) => _byCode[code];
}

/// A two-endpoint wire's route table: `[pointCount][direction][pointCount − 2 joint signs]`
/// `[pointCount − 2 segment lengths]`, a sign byte `0` turning positive and `1` negative, a
/// length byte `ff` escaping to a `u16`; a table of one byte is a single point.
class ViWireRoute {
  ViWireRoute({
    required this.pointCount,
    this.direction = WireRouteDirection.right,
    required this.segmentLengths,
    required this.jointSigns,
  });

  final int pointCount;

  /// The first segment's direction; null for a single-point route.
  final WireRouteDirection? direction;

  /// Each segment's length in pixels; segments alternate horizontal and vertical.
  final List<int> segmentLengths;

  /// Per segment after the first, `1` or `-1`: the sign of its axis step.
  final List<int> jointSigns;
}

List<int>? _decodeLengthTail(Uint8List table, int start) {
  var i = start;
  final lengths = <int>[];
  while (i < table.length) {
    var value = table[i++];
    if (value == 0xff) {
      if (i + 1 >= table.length) return null;
      value = ByteData.sublistView(table).getUint16(i);
      i += 2;
    }
    lengths.add(value);
  }
  return lengths;
}

// TODO: a residue of two-endpoint tables opening with the up code carries two trailing bytes this grammar does not explain.
/// The route of a two-endpoint wire, or null when [table] does not follow the [ViWireRoute]
/// grammar.
ViWireRoute? decodeWireRoute(Uint8List table) {
  if (table.isEmpty) return null;
  final n = table[0];
  if (n == 1) {
    if (table.length != 1) return null;
    return ViWireRoute(pointCount: 1, direction: null, segmentLengths: const [], jointSigns: const []);
  }
  if (n < 2 || table.length < 2) return null;
  final direction = WireRouteDirection.fromCode(table[1]);
  if (direction == null) return null;
  var i = 2;
  final signs = <int>[];
  for (var k = 0; k < n - 2; k++) {
    if (i >= table.length) return null;
    final m = table[i++];
    if (m != 0 && m != 1) return null;
    signs.add(m == 0 ? 1 : -1);
  }
  final lengths = _decodeLengthTail(table, i);
  if (lengths == null) return null;
  if (lengths.length != n - 2) return null;
  return ViWireRoute(pointCount: n, direction: direction, segmentLengths: lengths, jointSigns: signs);
}

/// A branch route mode that forks the wire: which directions leave the junction, in the order
/// the walk takes them; the direction the wire arrived from is replaced by [WireRouteDirection.left].
enum WireRouteJunction {
  cross(0x04, [WireRouteDirection.up, WireRouteDirection.down, WireRouteDirection.right]),

  downRight(0x05, [WireRouteDirection.down, WireRouteDirection.right]),

  upRight(0x06, [WireRouteDirection.up, WireRouteDirection.right]),

  upDown(0x07, [WireRouteDirection.up, WireRouteDirection.down])
  ;

  const WireRouteJunction(this.code, this.outgoing);

  final int code;

  final List<WireRouteDirection> outgoing;

  static final Map<int, WireRouteJunction> _byCode = {
    for (final value in values) value.code: value,
  };

  /// The junction with [code], or null for a code that is not one.
  static WireRouteJunction? fromCode(int code) => _byCode[code];
}

/// A branching wire's route table: `[pointCount][00][pointCount − 1 modes][pointCount − 1`
/// `segment lengths]`. The first mode is a set of [WireRouteDirection] bits; a later mode of
/// `0` or `1` turns positive or negative across the previous axis, [popCode] returns to the
/// last junction with directions left to walk, and any other mode is a [WireRouteJunction].
class ViWireBranchRoute {
  ViWireBranchRoute._({required this.pointCount, required this.modes, required this.segmentLengths});

  /// The mode that ends a branch and resumes at the last open junction.
  static const int popCode = 0x03;

  final int pointCount;

  final Uint8List modes;

  /// One length in pixels per mode.
  final List<int> segmentLengths;
}

/// The route of a branching wire, or null when [table] does not follow the
/// [ViWireBranchRoute] grammar or its junctions and pops do not balance.
ViWireBranchRoute? decodeWireBranchRoute(Uint8List table) {
  if (table.length < 2 || table[1] != 0) return null;
  final n = table[0];
  if (n < 2 || table.length < 1 + n) return null;
  final modes = Uint8List.sublistView(table, 2, 1 + n);
  final first = modes[0];
  if (first == 0 || first > 0x0f) return null;
  var pending = _bitCount(first) - 1;
  for (var k = 1; k < modes.length; k++) {
    final m = modes[k];
    if (m == 0 || m == 1) continue;
    if (m == ViWireBranchRoute.popCode) {
      if (pending == 0) return null;
      pending--;
      continue;
    }
    final junction = WireRouteJunction.fromCode(m);
    if (junction == null) return null;
    pending += junction.outgoing.length - 1;
  }
  if (pending != 0) return null;
  final lengths = _decodeLengthTail(table, 1 + n);
  if (lengths == null || lengths.length != n - 1) return null;
  return ViWireBranchRoute._(pointCount: n, modes: modes, segmentLengths: lengths);
}

int _bitCount(int v) => (v & 1) + ((v >> 1) & 1) + ((v >> 2) & 1) + ((v >> 3) & 1);

/// A branching route placed on the diagram: one polyline per branch, each starting at the
/// origin or a junction and ending at a leaf.
class ViWireRouteTree {
  ViWireRouteTree({required this.polylines, required this.junctions});

  final List<List<ViPoint>> polylines;

  /// Where branches fork.
  final List<ViPoint> junctions;

  /// The end of every branch; a wire with `n` endpoints has `n − 1` leaves.
  late final List<ViPoint> leaves = [for (final polyline in polylines) polyline.last];
}

/// Places [route] with its first point at [start].
ViWireRouteTree walkWireBranchRoute(ViWireBranchRoute route, ViPoint start) {
  final modes = route.modes;
  final lengths = route.segmentLengths;
  final polylines = <List<ViPoint>>[];
  final junctionPoints = <ViPoint>[];
  final stack = <(ViPoint, List<WireRouteDirection>)>[];
  var run = <ViPoint>[start];
  var pos = start;
  late WireRouteDirection prev;
  for (var k = 0; k < modes.length; k++) {
    final m = modes[k];
    final WireRouteDirection direction;
    if (k == 0) {
      final oneHot = WireRouteDirection.fromCode(m);
      if (oneHot != null) {
        direction = oneHot;
      } else {
        final dirs = [
          for (final d in WireRouteDirection.values)
            if (m & d.code != 0) d,
        ]..sort((a, b) => a.code.compareTo(b.code));
        direction = dirs.first;
        stack.add((pos, dirs.sublist(1)));
        junctionPoints.add(pos);
      }
    } else if (m == 0 || m == 1) {
      final positive = m == 0;
      direction = prev.isHorizontal
          ? (positive ? WireRouteDirection.down : WireRouteDirection.up)
          : (positive ? WireRouteDirection.right : WireRouteDirection.left);
    } else if (m == ViWireBranchRoute.popCode) {
      polylines.add(run);
      while (stack.last.$2.isEmpty) {
        stack.removeLast();
      }
      final (jpos, dirs) = stack.last;
      pos = jpos;
      run = <ViPoint>[pos];
      direction = dirs.removeAt(0);
    } else {
      final blocked = _reverse(prev);
      final dirs = [
        for (final d in WireRouteJunction.fromCode(m)!.outgoing) d == blocked ? WireRouteDirection.left : d,
      ];
      direction = dirs.first;
      stack.add((pos, dirs.sublist(1)));
      junctionPoints.add(pos);
    }
    pos = (x: pos.x + direction.dx * lengths[k], y: pos.y + direction.dy * lengths[k]);
    run.add(pos);
    prev = direction;
  }
  polylines.add(run);
  return ViWireRouteTree(polylines: polylines, junctions: junctionPoints);
}

WireRouteDirection _reverse(WireRouteDirection d) => switch (d) {
  WireRouteDirection.up => WireRouteDirection.down,
  WireRouteDirection.down => WireRouteDirection.up,
  WireRouteDirection.left => WireRouteDirection.right,
  WireRouteDirection.right => WireRouteDirection.left,
};

/// The corners of [route] walked from [origin], with the axis and sign of the segment that
/// would follow the last corner; null for a single-point route.
({List<ViPoint> points, WireRouteDirection direction, bool closingHorizontal, int closingSign})? walkRouteBends(
  ViWireRoute route, {
  ViPoint origin = (x: 0, y: 0),
}) {
  final direction = route.direction;
  if (direction == null) return null;
  var x = origin.x, y = origin.y;
  var horizontal = direction.isHorizontal;
  var sign = direction.dx + direction.dy;
  final lengths = route.segmentLengths;
  final points = <ViPoint>[origin];
  for (var k = 0; k < lengths.length; k++) {
    if (k > 0) sign = route.jointSigns[k - 1];
    if (horizontal) {
      x += lengths[k] * sign;
    } else {
      y += lengths[k] * sign;
    }
    points.add((x: x, y: y));
    horizontal = !horizontal;
  }
  return (
    points: points,
    direction: direction,
    closingHorizontal: horizontal,
    closingSign: route.jointSigns.isEmpty ? direction.dx + direction.dy : route.jointSigns.last,
  );
}

/// Places [route] with the endpoint at [anchoredIndex] fixed at [anchor] and the other end
/// closing on [farBox]: walked forward from the head, or walked backward from the tail when
/// [anchoredIndex] is 1. Null when the closing segment misses the box.
({List<ViPoint> points, ViStep? closingStep, ViStep? headSlack})? walkOneAnchoredRoute(
  ViWireRoute route, {
  required ViPoint anchor,
  required int anchoredIndex,
  required HeapRect farBox,
}) {
  if (route.pointCount < 2) return null;

  if (anchoredIndex == 0) {
    final walk = walkRouteBends(route, origin: anchor);
    if (walk == null) return null;
    final pts = walk.points;
    final closingSign = walk.closingSign;
    final tail = pts.last;
    final ViPoint terminus;
    if (walk.closingHorizontal) {
      if (tail.y < farBox.top || tail.y >= farBox.bottom) return null;
      final tx = closingSign > 0 ? farBox.left : farBox.right - 1;
      if ((tx - tail.x) * closingSign < 0) {
        final ahead = tail.x + closingSign;
        if (pts.length < 2 ||
            tail.x < farBox.left ||
            tail.x >= farBox.right ||
            ahead < farBox.left ||
            ahead >= farBox.right) {
          return null;
        }
        return (points: pts, closingStep: (dx: closingSign, dy: 0), headSlack: null);
      }
      terminus = (x: tx, y: tail.y);
    } else {
      if (tail.x < farBox.left || tail.x >= farBox.right) return null;
      final ty = closingSign > 0 ? farBox.top : farBox.bottom - 1;
      if ((ty - tail.y) * closingSign < 0) {
        final ahead = tail.y + closingSign;
        if (pts.length < 2 ||
            tail.y < farBox.top ||
            tail.y >= farBox.bottom ||
            ahead < farBox.top ||
            ahead >= farBox.bottom) {
          return null;
        }
        return (points: pts, closingStep: (dx: 0, dy: closingSign), headSlack: null);
      }
      terminus = (x: tail.x, y: ty);
    }
    if (terminus != tail) pts.add(terminus);
    return (points: pts, closingStep: null, headSlack: null);
  }

  final walk = walkRouteBends(route);
  if (walk == null) return null;
  final local = walk.points;
  final lastBend = local.last;
  final closingHorizontal = walk.closingHorizontal;
  final closingSign = walk.closingSign;
  final seg0Sign = walk.direction.dx + walk.direction.dy;
  if (walk.direction.isHorizontal != closingHorizontal) return null;
  final int tx, ty;
  if (closingHorizontal) {
    ty = anchor.y - lastBend.y;
    if (ty < farBox.top || ty >= farBox.bottom) return null;
    tx = seg0Sign > 0 ? farBox.right - 1 : farBox.left;
  } else {
    tx = anchor.x - lastBend.x;
    if (tx < farBox.left || tx >= farBox.right) return null;
    ty = seg0Sign > 0 ? farBox.bottom - 1 : farBox.top;
  }
  final pts = [for (final p in local) (x: p.x + tx, y: p.y + ty)];
  final tail = pts.last;
  if (closingHorizontal) {
    if (tail.y != anchor.y || (anchor.x - tail.x) * closingSign < 0) return null;
  } else {
    if (tail.x != anchor.x || (anchor.y - tail.y) * closingSign < 0) return null;
  }
  final headSlack = route.segmentLengths.isEmpty
      ? null
      : closingHorizontal
      ? (dx: -seg0Sign, dy: 0)
      : (dx: 0, dy: -seg0Sign);
  if (anchor != tail || headSlack != null) pts.add(anchor);
  return (points: pts, closingStep: null, headSlack: headSlack);
}

// TODO: LabVIEW < 8.6 heaps store bounds in an absolute coordinate space that is not decoded.
bool _predatesFrameRelativeTermBounds(String? version) {
  if (version == null) return false;
  final parts = version.split('.');
  if (parts.length < 2) return false;
  final major = int.tryParse(parts[0]);
  final minor = int.tryParse(parts[1]);
  if (major == null || minor == null) return false;
  return major < 8 || (major == 8 && minor < 6);
}

/// The objects of one heap section, indexed by oid and parent, with the wires derived from
/// its signals.
class ViDiagram {
  ViDiagram({required this.sectionTag, required this.objects, this.version});

  /// The section the heap came from, `FPHb` or `BDHb`.
  final String sectionTag;

  /// The saving LabVIEW version as `major.minor`, when the caller knows it.
  final String? version;

  /// Every object in heap order.
  final List<ViHeapObject> objects;

  late final Map<int, ViHeapObject> byId = {for (final object in objects) object.oid: object};

  Iterable<ViHeapObject> get roots => objects.where((o) => o.parentOid == null);

  Iterable<ViHeapObject> children(int oid) => childrenByOid[oid] ?? const <ViHeapObject>[];

  /// The frame objects of a structure, in heap order.
  List<ViHeapObject> framesOf(ViHeapObject structure) => [
    for (final child in children(structure.oid))
      if (child.objectClass == HeapObjectClass.bdFrame) child,
  ];

  /// The frame a multi-frame structure shows, null for other objects or an index past its frames.
  int? displayedFrameIndex(ViHeapObject structure) {
    if (!kMultiFrameStructureClasses.contains(structure.objectClass)) return null;
    var frames = 0;
    for (final child in children(structure.oid)) {
      if (child.objectClass == HeapObjectClass.bdFrame) frames++;
    }
    final index = structure.visibleFrameIndex;
    return index < frames ? index : null;
  }

  /// Every object with a bounds record.
  Iterable<ViHeapObject> get nodes => objects.where((o) => o.absBounds != null);

  /// One wire per `signal` object.
  late final List<ViWire> wires = [
    for (final object in objects)
      if (object.objectClass == HeapObjectClass.signal) _buildWire(object),
  ];

  ViWire _buildWire(ViHeapObject object) {
    final raw = object.wireTableRaw;
    final route = raw == null ? null : decodeWireRoute(raw);
    final branchRoute = raw == null || object.refs.length < 3 ? null : decodeWireBranchRoute(raw);
    final constantBounds = [for (final oid in object.refs) endpointConstantBounds(oid)];
    final attachRects = [
      for (var i = 0; i < object.refs.length; i++) endpointTerminalBounds(object.refs[i]) ?? constantBounds[i],
    ];
    final attachPoints = [
      for (var i = 0; i < object.refs.length; i++) _attachPointFrom(attachRects[i], object.refs[i]),
    ];
    final altAttachPoints = [
      for (var i = 0; i < object.refs.length; i++)
        switch (endpointConstantElementBounds(object.refs[i])) {
          null => null,
          final elem => attachPoints[i] == null ? null : _attachPointFrom(elem, object.refs[i]),
        },
    ];
    final stripTargets = [
      for (var i = 0; i < object.refs.length; i++) _stripFarTarget(object.refs[i], attachRects[i], attachPoints[i]),
    ];
    final anchors = [
      for (var i = 0; i < object.refs.length; i++) constantBounds[i] ?? _boundedOwnerBounds(object.refs[i]),
    ];
    final signalKind = object.lastSignalKind;
    final points = route == null || object.refs.length != 2
        ? null
        : _routePointsFor(route, object.refs, attachPoints, anchors, altAttachPoints, stripTargets);
    return ViWire(
      signalOid: object.oid,
      endpointOids: List<int>.of(object.refs),
      endpointAnchors: anchors,
      endpointAttachRects: attachRects,
      route: route,
      routePoints: points?.points,
      routePointsFidelity: points?.fidelity,
      routeClosingStep: points?.closingStep,
      routeHeadSlack: points?.headSlack,
      branchRoute: branchRoute,
      routeTreeBuilder: branchRoute == null
          ? null
          : () =>
                _shippableRouteTree(branchRoute, attachPoints, altAttachPoints, stripTargets, anchors[0]) ??
                _dcoChildRouteTree(branchRoute, object.refs, attachPoints, altAttachPoints, stripTargets),
      signalType: signalKind == null ? null : ViSignalType(signalKind),
    );
  }

  ({List<ViPoint> points, WireRouteFidelity fidelity, ViStep? closingStep, ViStep? headSlack})? _routePointsFor(
    ViWireRoute route,
    List<int> refs,
    List<ViPoint?> attachPoints,
    List<HeapRect?> anchors,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
  ) {
    for (final pair in [
      (attachPoints[0], stripTargets[1]),
      (altAttachPoints[0], stripTargets[1]),
      (attachPoints[0], attachPoints[1]),
      (altAttachPoints[0], attachPoints[1]),
      (attachPoints[0], altAttachPoints[1]),
      (altAttachPoints[0], altAttachPoints[1]),
    ]) {
      final closed = _closedRoutePoints(route, pair.$1, pair.$2);
      if (closed != null) {
        return (points: closed, fidelity: WireRouteFidelity.closed, closingStep: null, headSlack: null);
      }
    }
    final int anchoredIndex;
    final ViPoint anchorPoint;
    final head = attachPoints[0], tail = attachPoints[1];
    if (head != null && tail == null) {
      anchoredIndex = 0;
      anchorPoint = head;
    } else if (tail != null && head == null) {
      anchoredIndex = 1;
      anchorPoint = tail;
    } else {
      return _dcoChildTierPoints(route, refs, attachPoints, altAttachPoints, stripTargets, anchors);
    }
    if (_exactAttach(refs[anchoredIndex])) {
      final farBox = anchors[1 - anchoredIndex];
      if (farBox != null) {
        final walked = walkOneAnchoredRoute(
          route,
          anchor: anchorPoint,
          anchoredIndex: anchoredIndex,
          farBox: farBox,
        );
        if (walked != null) {
          return (
            points: walked.points,
            fidelity: WireRouteFidelity.walked,
            closingStep: walked.closingStep,
            headSlack: walked.headSlack,
          );
        }
      }
    }
    return _dcoChildTierPoints(route, refs, attachPoints, altAttachPoints, stripTargets, anchors);
  }

  ({List<ViPoint> points, WireRouteFidelity fidelity, ViStep? closingStep, ViStep? headSlack})? _dcoChildTierPoints(
    ViWireRoute route,
    List<int> refs,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
    List<HeapRect?> anchors,
  ) {
    final fallback = [for (final oid in refs) dcoChildTerminalAttach(oid)];
    final usesFallback = [
      for (var i = 0; i < 2; i++) attachPoints[i] == null && (fallback[i]?.candidates.isNotEmpty ?? false),
    ];
    if (!usesFallback[0] && !usesFallback[1]) return null;
    final sourceCandidates = usesFallback[0]
        ? fallback[0]!.candidates
        : [
            if (attachPoints[0] != null) attachPoints[0]!,
            if (altAttachPoints[0] != null) altAttachPoints[0]!,
          ];
    final targetCandidates = usesFallback[1]
        ? fallback[1]!.candidates
        : [
            if (stripTargets[1] != null) stripTargets[1]!,
            if (attachPoints[1] != null) attachPoints[1]!,
            if (altAttachPoints[1] != null) altAttachPoints[1]!,
          ];
    for (final source in sourceCandidates) {
      for (final target in targetCandidates) {
        final closed = _closedRoutePoints(route, source, target);
        if (closed != null) {
          return (points: closed, fidelity: WireRouteFidelity.closed, closingStep: null, headSlack: null);
        }
      }
    }
    final int anchoredIndex;
    if (usesFallback[0] && (fallback[0]?.wideRow ?? false) && attachPoints[1] == null) {
      anchoredIndex = 0;
    } else if (usesFallback[1] && (fallback[1]?.wideRow ?? false) && attachPoints[0] == null) {
      anchoredIndex = 1;
    } else {
      return null;
    }
    final farBox = anchors[1 - anchoredIndex];
    if (farBox == null) return null;
    final walked = walkOneAnchoredRoute(
      route,
      anchor: fallback[anchoredIndex]!.candidates.first,
      anchoredIndex: anchoredIndex,
      farBox: farBox,
    );
    return walked == null
        ? null
        : (
            points: walked.points,
            fidelity: WireRouteFidelity.walked,
            closingStep: walked.closingStep,
            headSlack: walked.headSlack,
          );
  }

  bool _exactAttach(int oid) {
    final terminal = endpointTerminal(oid);
    if (terminal == null) return endpointConstantBounds(oid) == null;
    final parentOid = terminal.parentOid;
    final parent = parentOid == null ? null : byId[parentOid];
    final frame = parent == null ? null : _boundedOwnerObject(parent);
    return frame != null && frame.category == ViObjectKind.structure;
  }

  static ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _shippableRouteTree(
    ViWireBranchRoute route,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
    HeapRect? headBox,
  ) {
    if (attachPoints.length < 3) return null;
    if (attachPoints[0] == null) {
      return _reverseSolvedRouteTree(route, attachPoints, altAttachPoints, stripTargets, headBox);
    }
    for (final origin in [attachPoints[0], altAttachPoints[0]]) {
      if (origin == null) continue;
      final tree = walkWireBranchRoute(route, origin);
      final leaves = tree.leaves;
      if (leaves.length != attachPoints.length - 1) continue;
      final remaining = <ViPoint, int>{};
      for (final leaf in leaves) {
        remaining.update(leaf, (c) => c + 1, ifAbsent: () => 1);
      }
      var fullyAnchored = true;
      var contradiction = false;
      for (var i = 1; i < attachPoints.length; i++) {
        if (attachPoints[i] == null) {
          fullyAnchored = false;
          continue;
        }
        ViPoint? match;
        for (final candidate in [stripTargets[i], attachPoints[i], altAttachPoints[i]]) {
          if (candidate != null && remaining.containsKey(candidate)) {
            match = candidate;
            break;
          }
        }
        if (match == null) {
          contradiction = true;
          break;
        }
        if (remaining.update(match, (count) => count - 1) == 0) remaining.remove(match);
      }
      if (contradiction) continue;
      return (tree: tree, fidelity: fullyAnchored ? WireRouteFidelity.closed : WireRouteFidelity.walked);
    }
    return null;
  }

  static ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _reverseSolvedRouteTree(
    ViWireBranchRoute route,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
    HeapRect? headBox,
  ) {
    if (headBox == null) return null;
    final local = walkWireBranchRoute(route, (x: 0, y: 0));
    final leaves = local.leaves;
    if (leaves.length != attachPoints.length - 1) return null;
    List<ViPoint> candidatesOf(int i) => [
      for (final p in [stripTargets[i], attachPoints[i], altAttachPoints[i]])
        if (p != null) p,
    ];
    bool closesAll(ViPoint origin) {
      final remaining = <ViPoint, int>{};
      for (final leaf in leaves) {
        final p = (x: leaf.x + origin.x, y: leaf.y + origin.y);
        remaining.update(p, (c) => c + 1, ifAbsent: () => 1);
      }
      for (var i = 1; i < attachPoints.length; i++) {
        if (attachPoints[i] == null) continue;
        ViPoint? match;
        for (final candidate in candidatesOf(i)) {
          if (remaining.containsKey(candidate)) {
            match = candidate;
            break;
          }
        }
        if (match == null) return false;
        if (remaining.update(match, (count) => count - 1) == 0) remaining.remove(match);
      }
      return true;
    }

    int? seed;
    for (var i = 1; i < attachPoints.length; i++) {
      if (attachPoints[i] != null) {
        seed = i;
        break;
      }
    }
    if (seed == null) return null;
    final candidates = <ViPoint>{
      for (final leaf in leaves)
        for (final p in candidatesOf(seed)) (x: p.x - leaf.x, y: p.y - leaf.y),
    };
    ViPoint? solved;
    for (final origin in candidates) {
      if (origin.x < headBox.left ||
          origin.x >= headBox.right ||
          origin.y < headBox.top ||
          origin.y >= headBox.bottom) {
        continue;
      }
      if (!closesAll(origin)) continue;
      if (solved != null) return null;
      solved = origin;
    }
    if (solved == null) return null;
    return (tree: walkWireBranchRoute(route, solved), fidelity: WireRouteFidelity.walked);
  }

  ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _dcoChildRouteTree(
    ViWireBranchRoute route,
    List<int> refs,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
  ) {
    if (attachPoints.length < 3 || attachPoints[0] != null) return null;
    final origins = dcoChildTerminalAttach(refs[0])?.candidates;
    if (origins == null) return null;
    for (final origin in origins) {
      final tree = walkWireBranchRoute(route, origin);
      final leaves = tree.leaves;
      if (leaves.length != attachPoints.length - 1) continue;
      final remaining = <ViPoint, int>{};
      for (final leaf in leaves) {
        remaining.update(leaf, (c) => c + 1, ifAbsent: () => 1);
      }
      var closed = true;
      for (var i = 1; i < attachPoints.length; i++) {
        ViPoint? match;
        for (final candidate in [
          stripTargets[i],
          attachPoints[i],
          altAttachPoints[i],
          ...?dcoChildTerminalAttach(refs[i])?.candidates,
        ]) {
          if (candidate != null && remaining.containsKey(candidate)) {
            match = candidate;
            break;
          }
        }
        if (match == null) {
          closed = false;
          break;
        }
        if (remaining.update(match, (count) => count - 1) == 0) remaining.remove(match);
      }
      if (closed) return (tree: tree, fidelity: WireRouteFidelity.closed);
    }
    return null;
  }

  /// The terminal each endpoint belongs to; an endpoint claimed by two terminals has no entry.
  late final Map<int, int> _terminalOidByMemberOid = _buildTerminalIndex();

  Map<int, int> _buildTerminalIndex() {
    final index = <int, int>{};
    final ambiguous = <int>{};
    for (final object in objects) {
      if (object.termBounds == null) continue;
      for (final target in object.typedRefs[HeapRefKind.childRef] ?? const <int>[]) {
        _claim(index, ambiguous, target, object.oid);
      }
    }
    return index;
  }

  static void _claim(Map<int, int> index, Set<int> ambiguous, int key, int owner) {
    if (ambiguous.contains(key)) return;
    final prev = index[key];
    if (prev == null) {
      index[key] = owner;
    } else if (prev != owner) {
      index.remove(key);
      ambiguous.add(key);
    }
  }

  /// The terminal object whose `childRef` names the endpoint [oid]; null for an object that is
  /// not an endpoint or is claimed by two terminals.
  ViHeapObject? endpointTerminal(int oid) {
    final endpoint = byId[oid];
    if (endpoint == null || !kSignalEndpointDcoKinds.contains(endpoint.kind)) return null;
    final terminalOid = _terminalOidByMemberOid[oid];
    return terminalOid == null ? null : byId[terminalOid];
  }

  late final Map<int, List<ViHeapObject>> childrenByOid = _childrenByParentOid(objects);

  /// The endpoint that names each terminal as its DCO; a terminal named by two has no entry.
  late final Map<int, int> _dcoOidByTerminalOid = _buildTerminalDcoIndex();

  Map<int, int> _buildTerminalDcoIndex() {
    final index = <int, int>{};
    final ambiguous = <int>{};
    for (final terminal in objects) {
      if (terminal.termBounds == null) continue;
      for (final target in terminal.typedRefs[HeapRefKind.childRef] ?? const <int>[]) {
        final candidate = byId[target];
        if (candidate == null || !kSignalEndpointDcoKinds.contains(candidate.kind)) continue;
        if (!(candidate.typedRefs[HeapRefKind.dcoRef] ?? const <int>[]).contains(terminal.oid)) continue;
        _claim(index, ambiguous, terminal.oid, candidate.oid);
      }
    }
    return index;
  }

  /// The endpoint DCO the terminal [oid] refers back to through `dcoRef`.
  ViHeapObject? terminalDco(int oid) {
    final dcoOid = _dcoOidByTerminalOid[oid];
    return dcoOid == null ? null : byId[dcoOid];
  }

  /// Whether the terminal's DCO carries [ViObjFlag.terminalGlyphHidden].
  bool terminalGlyphHidden(int oid) => terminalDco(oid)?.hasFlag(ViObjFlag.terminalGlyphHidden) ?? false;

  /// The constant DCO under the node endpoint [oid], when the endpoint feeds a constant.
  ViHeapObject? endpointConstant(int oid) {
    final endpoint = byId[oid];
    if (endpoint == null || endpoint.kind != kNodeEndpointDcoKind) return null;
    for (final child in childrenByOid[oid] ?? const <ViHeapObject>[]) {
      if (child.objectClass == HeapObjectClass.bdConstDco) return child;
    }
    return null;
  }

  /// The bounds of the constant's first bounded child; null before LabVIEW 8.6.
  HeapRect? endpointConstantBounds(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in childrenByOid[constant.oid] ?? const <ViHeapObject>[]) {
      if (child.absBounds != null) return child.absBounds;
    }
    return null;
  }

  /// For a constant drawn as a container, the bounds of its rightmost element part.
  HeapRect? endpointConstantElementBounds(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in childrenByOid[constant.oid] ?? const <ViHeapObject>[]) {
      if (child.absBounds == null) continue;
      if (child.objectClass != HeapObjectClass.caseOrSequence) return null;
      HeapRect? element;
      for (final kid in childrenByOid[child.oid] ?? const <ViHeapObject>[]) {
        final kidBounds = kid.absBounds;
        if (kid.objectClass == HeapObjectClass.controlChrome ||
            kid.objectClass == HeapObjectClass.controlLabel ||
            kidBounds == null) {
          continue;
        }
        if (element == null || kidBounds.left > element.left) {
          element = kidBounds;
        }
      }
      return element;
    }
    return null;
  }

  /// The endpoint's terminal box in diagram pixels: its `termBounds` shifted by the nearest
  /// bounded ancestor's origin; null before LabVIEW 8.6.
  HeapRect? endpointTerminalBounds(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final terminal = endpointTerminal(oid);
    final rel = terminal?.termBounds;
    if (terminal == null || rel == null) return null;
    final parentOid = terminal.parentOid;
    final frame = parentOid == null ? null : _boundedOwnerBounds(parentOid);
    if (frame == null) return null;
    return HeapRect(
      top: frame.top + rel.top,
      left: frame.left + rel.left,
      bottom: frame.top + rel.bottom,
      right: frame.left + rel.right,
    );
  }

  /// For a node endpoint without bounds whose single child carries `termBounds`: the centre of
  /// that box, and whether the child is a wide terminal strip.
  ({List<ViPoint> candidates, bool wideRow})? dcoChildTerminalAttach(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final endpoint = byId[oid];
    if (endpoint == null || endpoint.kind != kNodeEndpointDcoKind || endpoint.absBounds != null) return null;
    ViHeapObject? part;
    for (final child in childrenByOid[oid] ?? const <ViHeapObject>[]) {
      if (child.termBounds == null) continue;
      if (part != null) return null;
      part = child;
    }
    final rel = part?.termBounds;
    if (part == null || rel == null) return null;
    final frame = _boundedOwnerBounds(oid);
    if (frame == null) return null;
    final left = frame.left + rel.left, top = frame.top + rel.top;
    final width = rel.right - rel.left, height = rel.bottom - rel.top;
    final centre = (x: left + width ~/ 2, y: top + height ~/ 2);
    return (
      candidates: [centre],
      wideRow: part.kind == 0x62 && width > height,
    );
  }

  /// The centre of the endpoint's terminal or constant box, shifted inward for shift registers.
  ViPoint? wireAttachPoint(int oid) =>
      _attachPointFrom(endpointTerminalBounds(oid) ?? endpointConstantBounds(oid), oid);

  ViPoint? _attachPointFrom(HeapRect? attachRect, int oid) {
    var rect = attachRect;
    if (rect == null) {
      if (_predatesFrameRelativeTermBounds(version)) return null;
      final endpoint = byId[oid];
      if (endpoint == null || endpoint.objectClass != HeapObjectClass.bdLeaf) return null;
      rect = endpoint.absBounds;
      if (rect == null) return null;
    }
    var x = rect.left + (rect.right - rect.left) ~/ 2;
    if (attachRect != null) {
      final terminalKind = endpointTerminal(oid)?.kind;
      if (terminalKind == HeapObjectClass.bdRightShiftRegister.code) {
        x -= kShiftRegisterColumnLeftOffset;
      } else if (terminalKind == HeapObjectClass.bdLeftShiftRegister.code) {
        x += kShiftRegisterColumnRightOffset;
      }
    }
    return (x: x, y: rect.top + (rect.bottom - rect.top) ~/ 2);
  }

  ViPoint? _stripFarTarget(int oid, HeapRect? attachRect, ViPoint? attach) {
    if (attachRect == null || attach == null) return null;
    if (attachRect.right - attachRect.left != kTerminalStripColumnWidth) return null;
    if (!kBdTerminalStripClasses.contains(endpointTerminal(oid)?.objectClass)) return null;
    return (x: attach.x - kTerminalStripTargetLeftOffset, y: attach.y);
  }

  static List<ViPoint>? _closedRoutePoints(ViWireRoute route, ViPoint? start, ViPoint? destination) {
    if (start == null || destination == null) return null;
    if (route.pointCount == 1) return start == destination ? [start] : null;
    final walk = walkRouteBends(route, origin: start);
    if (walk == null) return null;
    final points = walk.points;
    final tail = points.last;
    if (walk.closingHorizontal ? tail.y != destination.y : tail.x != destination.x) return null;
    final along = walk.closingHorizontal ? destination.x - tail.x : destination.y - tail.y;
    if (along != 0 && (along > 0 ? 1 : -1) != walk.closingSign) return null;
    if (along != 0) points.add(destination);
    return points;
  }

  HeapRect? _boundedOwnerBounds(int oid) {
    final start = byId[oid];
    return start == null ? null : _boundedOwnerObject(start)?.absBounds;
  }

  ViHeapObject? _boundedOwnerObject(ViHeapObject start) {
    ViHeapObject? object = start;
    final seen = <int>{};
    while (object != null && seen.add(object.oid)) {
      if (object.absBounds != null) return object;
      final parentOid = object.parentOid;
      object = parentOid == null ? null : byId[parentOid];
    }
    return null;
  }
}

Map<int, List<ViHeapObject>> _childrenByParentOid(List<ViHeapObject> objects) {
  final kids = <int, List<ViHeapObject>>{};
  for (final object in objects) {
    if (object.parentOid != null) (kids[object.parentOid!] ??= <ViHeapObject>[]).add(object);
  }
  return kids;
}

int? _attrScalarBytes(HeapAttrWidth width) => switch (width) {
  HeapAttrWidth.flag => 0,
  HeapAttrWidth.u8 => 1,
  HeapAttrWidth.u16 => 2,
  HeapAttrWidth.u24 => 3,
  HeapAttrWidth.rgb => 4,
  _ => null,
};

Uint8List? _attrFlatBytes(HeapAttr record) {
  final raw = record.rawValueBytes;
  if (raw != null) return raw;
  final scalarBytes = _attrScalarBytes(record.width);
  final value = record.asInt;
  if (scalarBytes == null || scalarBytes == 0 || value == null) return null;
  final out = Uint8List(scalarBytes);
  for (var i = 0; i < scalarBytes; i++) {
    out[i] = (value >> (8 * (scalarBytes - 1 - i))) & 0xff;
  }
  return out;
}

const int _intCertainCeil = 0x800000;

const double _dblWindowFloor = 1e-12, _dblWindowCeil = 1e12;

const Set<int> _zeroPayloadLengths = {5, 9};

// TODO: absolute (type 0) and UNC (type 2) path text is not decoded.
/// The segments of a flat relative `PTH0` path joined with backslashes; null for any other
/// path form.
String? decodeFlatPathText(Uint8List? raw) {
  if (raw == null || raw.length < 12) return null;
  if (raw[0] != 0x50 || raw[1] != 0x54 || raw[2] != 0x48 || raw[3] != 0x30) {
    return null;
  }
  final view = ByteData.sublistView(raw);
  final contentLength = view.getUint32(4);
  final end = 8 + contentLength;
  if (end > raw.length) return null;
  final pathType = view.getUint16(8);
  final count = view.getUint16(10);
  if (pathType != 1 || count < 1) return null;
  var offset = 12;
  final segments = <String>[];
  for (var i = 0; i < count; i++) {
    if (offset >= end) return null;
    final len = raw[offset];
    if (offset + 1 + len > end) return null;
    segments.add(String.fromCharCodes(raw, offset + 1, offset + 1 + len));
    offset += 1 + len;
  }
  if (offset != end) return null;
  return segments.join(r'\');
}

/// A constant's value read from its flat bytes by the class of the control that draws it:
/// a path, a four-character string, a boolean, or a small non-negative integer, a zero or a
/// double in a plausible range; null when the bytes do not fit the carrier.
Object? decodeBdConstantValue({
  required HeapObjectClass carrier,
  required Uint8List? flat,
  required bool scalar,
  bool hasEnumItems = false,
}) {
  if (flat == null) return null;
  final scalarBytes = scalar ? flat.length : null;
  int? scalarValue;
  if (scalar) {
    var magnitude = 0;
    for (final byte in flat) {
      magnitude = (magnitude << 8) | byte;
    }
    scalarValue = magnitude;
  }
  final raw = scalar ? null : flat;
  switch (carrier) {
    case HeapObjectClass.pathControl:
      return decodeFlatPathText(raw);
    case HeapObjectClass.stringOrArrayControl:
      if (raw != null && raw.length == 8) {
        final strLen = ByteData.sublistView(raw).getUint32(0);
        if (strLen == 4 && raw.skip(4).every((b) => b >= 0x20 && b < 0x7f)) {
          return String.fromCharCodes(raw, 4);
        }
      }
      return null;
    case HeapObjectClass.booleanOrClusterControl:
      if (scalarBytes != null && scalarBytes <= 2 && (scalarValue == 0 || scalarValue == 1)) {
        return scalarValue == 1;
      }
      return null;
    case HeapObjectClass.enumRingControl when hasEnumItems:
    case HeapObjectClass.clusterShell when hasEnumItems:
    case HeapObjectClass.numericControl:
      if (scalarBytes != null && scalarValue != null) {
        if (scalarValue == 0) return scalarValue;
        final leading = (scalarValue >>> (8 * (scalarBytes - 1))) & 0xff;
        if (leading >= 0x80 || scalarValue >= _intCertainCeil) return null;
        return scalarValue;
      }
      if (carrier != HeapObjectClass.numericControl || raw == null) return null;
      if (_zeroPayloadLengths.contains(raw.length) && raw.every((byte) => byte == 0)) {
        return 0;
      }
      if (raw.length == 8) {
        final f64Reading = ByteData.sublistView(raw).getFloat64(0);
        if (!f64Reading.isFinite) return null;
        if (f64Reading == 0 || (f64Reading.abs() >= _dblWindowFloor && f64Reading.abs() <= _dblWindowCeil)) {
          return f64Reading;
        }
      }
      return null;
    default:
      return null;
  }
}

/// Builds the object tree of a heap body (the section payload including its length word).
/// After the walk, label bounds are re-based on their owner, flat-sequence frames are shifted
/// to their declared offsets, items and help text bubble up to the owning control, unlabelled
/// nodes take their first child label, and controls under a scrolled viewport are re-anchored.
ViDiagram buildDiagram(Uint8List body, {String sectionTag = 'BDHb', String? version}) {
  final objects = <ViHeapObject>[];
  final c4ops = <ViHeapObject, Set<int>>{};
  final formatPayloads = <ViHeapObject, List<int>>{};
  final absTop = <ViHeapObject, int>{};
  final absLeft = <ViHeapObject, int>{};
  final liveParent = <ViHeapObject, ViHeapObject?>{};
  final length = body.length;

  ViHeapObject? styleRunOwner;
  var styleRunGroupDepth = 0;
  var styleRunStart = 0;
  var styleRunFontId = 0;
  var styleRunOpen = false;
  var styleRuns = <({int start, int fontId})>[];

  ViHeapObject? arrayIndexOwner;
  var arrayIndexGroupDepth = 0;

  ViHeapObject? selectorOwner;
  var selectorGroupDepth = 0;
  var selectorInPool = false;
  var selectorEntryOpen = false;
  var selectorRanges = <ViSelectorRange>[];
  var selectorStrings = <String>[];
  var entryLow = 0, entryHigh = 0, entryLowBound = 0, entryHighBound = 0, entryFrame = 0;

  walkHeapObjects<ViHeapObject>(
    body,
    onGroupOpen: (groupTag, cur) {
      if (selectorOwner != null) {
        selectorGroupDepth++;
        if (groupTag == HeapGroupTag.selectorRange.tag && selectorGroupDepth == 2 && !selectorInPool) {
          selectorEntryOpen = true;
          entryLow = entryHigh = entryLowBound = entryHighBound = entryFrame = 0;
        }
      } else if (cur != null && cur.objectClass == HeapObjectClass.bdStructureFrame) {
        if (kViSelectorGroupTags.contains(groupTag)) {
          selectorOwner = cur;
          selectorGroupDepth = 1;
          selectorInPool = groupTag == HeapGroupTag.selectorStringPool.tag;
          if (selectorInPool) {
            selectorStrings = <String>[];
          } else {
            selectorRanges = <ViSelectorRange>[];
          }
        }
      }
      if (arrayIndexOwner != null) {
        arrayIndexGroupDepth++;
      } else if (groupTag == HeapGroupTag.arrayIndex.tag &&
          cur != null &&
          cur.objectClass == HeapObjectClass.caseOrSequence) {
        arrayIndexOwner = cur;
        arrayIndexGroupDepth = 1;
      }
      if (styleRunOwner == null) {
        if (groupTag == HeapGroupTag.fontRunList.tag && cur != null) {
          styleRunOwner = cur;
          styleRunGroupDepth = 1;
          styleRuns = [];
        }
        return;
      }
      styleRunGroupDepth++;
      if (groupTag == HeapGroupTag.fontRun.tag && styleRunGroupDepth == 2) {
        styleRunOpen = true;
        styleRunStart = 0;
        styleRunFontId = 0;
      }
    },
    onGroupClose: (groupTag, cur) {
      final owner = selectorOwner;
      if (owner != null) {
        if (selectorEntryOpen && selectorGroupDepth == 2) {
          selectorRanges.add(
            ViSelectorRange(
              low: entryLow,
              high: entryHigh,
              lowBound: ViSelectorBound.ofCode(entryLowBound),
              highBound: ViSelectorBound.ofCode(entryHighBound),
              frame: entryFrame,
            ),
          );
          selectorEntryOpen = false;
        }
        if (--selectorGroupDepth == 0) {
          if (selectorInPool) {
            if (owner.selectorStrings.isEmpty) owner.selectorStrings = selectorStrings;
          } else if (owner.selectorRanges.isEmpty) {
            owner.selectorRanges = selectorRanges;
          }
          selectorOwner = null;
          selectorInPool = false;
        }
      }
      if (arrayIndexOwner != null && --arrayIndexGroupDepth == 0) {
        arrayIndexOwner = null;
      }
      final runOwner = styleRunOwner;
      if (runOwner == null) return;
      styleRunGroupDepth--;
      if (styleRunOpen && styleRunGroupDepth == 1) {
        styleRuns.add((start: styleRunStart, fontId: styleRunFontId));
        styleRunOpen = false;
      }
      if (styleRunGroupDepth == 0) {
        if (styleRuns.isNotEmpty && runOwner.textStyleRuns.isEmpty) {
          runOwner.textStyleRuns = styleRuns;
        }
        styleRunOwner = null;
      }
    },
    onObjectOpen: (span, kind, oid, parent) {
      final cur = ViHeapObject(oid: oid, kind: kind, offset: span.offset);
      cur.parentOid = parent?.oid;
      liveParent[cur] = parent;
      absTop[cur] = absTop[parent] ?? 0;
      absLeft[cur] = absLeft[parent] ?? 0;
      objects.add(cur);
      c4ops[cur] = <int>{};
      return cur;
    },
    onRecord: (span, cur) {
      if (cur == null) return;
      final offset = span.offset;
      final lead = span.lead;
      if (selectorOwner != null && identical(cur, selectorOwner)) {
        if (selectorInPool) {
          final value = _selectorPoolString(body, offset, lead, span.length);
          if (value != null) {
            selectorStrings.add(value);
            return;
          }
        } else if (selectorEntryOpen) {
          final attr = decodeHeapAttr(body, offset);
          final value = attr?.asInt;
          if (attr != null && value != null) {
            final tag = attr.rawTag;
            if (tag == SelectorRangeAttr.low.raw) {
              entryLow = _signedAtWidth(value, attr.width);
              return;
            }
            if (tag == SelectorRangeAttr.high.raw) {
              entryHigh = _signedAtWidth(value, attr.width);
              return;
            }
            if (tag == SelectorRangeAttr.lowBound.raw) {
              entryLowBound = value;
              return;
            }
            if (tag == SelectorRangeAttr.highBound.raw) {
              entryHighBound = value;
              return;
            }
            if (tag == SelectorRangeAttr.frame.raw) {
              entryFrame = value;
              return;
            }
          }
        }
      }
      final indexOwner = arrayIndexOwner;
      if (indexOwner != null && identical(cur, indexOwner)) {
        final attr = decodeHeapAttr(body, offset);
        final value = attr?.asInt;
        if (value != null && attr != null && attr.rawTag == HeapAttribute.arrayElemValue.raw) {
          indexOwner.arrayIndex = value;
          return;
        }
      }
      if (styleRunOpen && identical(cur, styleRunOwner)) {
        final attr = decodeHeapAttr(body, offset);
        final value = attr?.asInt;
        if (attr != null && value != null) {
          if (attr.rawTag == FontRunAttr.start.raw) {
            styleRunStart = value;
            return;
          }
          if (attr.rawTag == FontRunAttr.fontId.raw) {
            styleRunFontId = value;
            return;
          }
        }
      }
      if (lead == kHeapRecordPrefix) {
        final rec = c4FrameAt(body, offset, sectionTag);
        if (rec == null) return;
        (c4ops[cur] ??= <int>{}).add(rec.opcode);
        switch (rec.opcode) {
          case 0x2d:
            final recBounds = rec.bounds;
            if (cur.bounds == null && recBounds != null) {
              final bounds = recBounds;
              cur.bounds = bounds;
              final top = (absTop[cur] ?? 0) + bounds.top;
              final left = (absLeft[cur] ?? 0) + bounds.left;
              absTop[cur] = top;
              absLeft[cur] = left;
              cur.absBounds = HeapRect(top: top, left: left, bottom: top + bounds.height, right: left + bounds.width);
            }
          case 0x22:
            cur.label ??= rec.text;
          case 0x1f:
            cur.termCount++;
          case 0x74:
            formatPayloads[cur] ??= rec.payload;
          case 0x2e:
            if (cur.items.isEmpty) cur.items = _parseEnumItems(rec.payload);
          case 0x19:
            cur.helpText ??= rec.descriptionText;
          case 0x27:
            {
              final text = rec.text ?? rec.path ?? rec.descriptionText;
              if (text != null && text.isNotEmpty) cur.plotNames = [...cur.plotNames, text];
            }
          case 0xa4:
            if (cur.objectClass == HeapObjectClass.bdCallLibrary) cur.foreignLibraryPath ??= rec.path;
          case 0xc4:
            if (cur.objectClass == HeapObjectClass.bdCallLibrary) cur.foreignEntryPoint ??= rec.text;
        }
      } else if (lead == 0x14) {
        final ref = decodeHeapRef(body, offset);
        if (ref != null) {
          (cur.typedRefs[ref.kind] ??= <int>[]).add(ref.targetOid);
          if (ref.kind == HeapRefKind.childRef) cur.refs.add(ref.targetOid);
        }
      } else if (offset + 1 < length && _objAttrIds.contains(body[offset + 1])) {
        final attr = decodeHeapAttr(body, offset);
        if (attr == null) return;
        final number = attr.asDouble;
        if (number != null && kControlTerminalClasses.contains(cur.objectClass)) {
          if (attr.attribute == HeapAttribute.stdNumMin) cur.controlMin ??= number;
          if (attr.attribute == HeapAttribute.stdNumMax) cur.controlMax ??= number;
        }
        if (attr.attribute == HeapAttribute.constValue) {
          final text = attr.asString;
          if (text != null && text.isNotEmpty) cur.constText ??= text;
        }
        if (attr.attribute == HeapAttribute.shortText) {
          final text = attr.asciiText;
          if (text != null && text.length == _attrScalarBytes(attr.width)) {
            cur.label ??= text;
          }
        }
        if (attr.attribute == HeapAttribute.constValue &&
            cur.objectClass == HeapObjectClass.bdConstDco &&
            cur.constValueRaw == null) {
          cur.constValueRaw = _attrFlatBytes(attr);
          cur.constValueScalar = _attrScalarBytes(attr.width) != null;
        }
        if (attr.attribute == HeapAttribute.formatStyle) {
          final bytes = _attrFlatBytes(attr);
          if (bytes != null && bytes.isNotEmpty && bytes.first == 0x25 && bytes.every((b) => b >= 0x20 && b < 0x7f)) {
            cur.displayFormat ??= String.fromCharCodes(bytes);
          }
        }
        if (attr.attribute == HeapAttribute.cosmColorB && cur.objectClass == HeapObjectClass.controlLabel) {
          cur.labelModeWord ??= attr.asInt;
        }
        if (attr.attribute == HeapAttribute.termBounds) cur.termBounds ??= attr.asRect;
        if (attr.attribute == HeapAttribute.termBMPs) cur.termBmp ??= attr.asInt;
        if (attr.attribute == HeapAttribute.typeDescIndex) cur.typeDescIdx ??= attr.asInt;
        if (attr.attribute == HeapAttribute.objFlags) cur.objFlags ??= attr.asInt;
        if (attr.attribute == HeapAttribute.primResID &&
            cur.objectClass == HeapObjectClass.bdNode &&
            attr.width == HeapAttrWidth.u16) {
          cur.primResId ??= attr.asInt;
        }
        if (attr.attribute == HeapAttribute.dIdx && kMultiFrameStructureClasses.contains(cur.objectClass)) {
          cur.dIdx ??= attr.asInt;
        }
        if (attr.attribute == HeapAttribute.compressedWireTable && cur.objectClass == HeapObjectClass.signal) {
          if (attr.width == HeapAttrWidth.container) {
            cur.wireTableRaw ??= attr.rawValueBytes;
          } else {
            final scalarBytes = _attrScalarBytes(attr.width);
            final value = attr.asInt;
            if (scalarBytes != null && scalarBytes > 0 && value != null) {
              final table = Uint8List(scalarBytes);
              for (var b = 0; b < scalarBytes; b++) {
                table[b] = (value >> (8 * (scalarBytes - 1 - b))) & 0xff;
              }
              cur.wireTableRaw ??= table;
            }
          }
        }
        if (attr.attribute == HeapAttribute.selectDefaultCase && cur.objectClass == HeapObjectClass.bdStructureFrame) {
          final frame = attr.asInt;
          if (frame != null && frame != kViNoDefaultFrame) cur.defaultFrameIndex ??= frame;
        }
        if (attr.attribute == HeapAttribute.lastSignalKind && cur.objectClass == HeapObjectClass.signal) {
          final word = attr.asInt;
          if (word != null && word <= 0xffff) cur.lastSignalKind ??= word;
        }
        final rawColor = attr.kind == HeapAttrKind.color && attr.value is int ? attr.value as int : null;
        final rgb = attr.isTransparent || rawColor == 0x1 ? null : attr.rgb;
        if (rgb != null) {
          switch (attr.attribute) {
            case HeapAttribute.backgroundColor:
              cur.bgRgb ??= rgb;
            case HeapAttribute.fgColor:
              cur.fgRgb ??= rgb;
            case HeapAttribute.contentColor:
              cur.contentRgb ??= rgb;
            case HeapAttribute.structColor:
              cur.structRgb ??= rgb;
            case HeapAttribute.borderColor:
              cur.borderRgb ??= rgb;
            case HeapAttribute.plotColor:
              (cur.plotColors.isEmpty ? (cur.plotColors = <int>[]) : cur.plotColors).add(rgb);
            default:
              break;
          }
        }
      }
    },
  );

  for (final object in objects) {
    if (object.objectClass != HeapObjectClass.controlLabel) continue;
    final parent = liveParent[object];
    final local = object.bounds;
    final ownerBounds = parent?.bounds;
    final ownerAbs = parent?.absBounds;
    if (local == null || ownerBounds == null || ownerAbs == null) continue;
    object.absBounds = HeapRect(
      top: ownerAbs.top + local.top,
      left: ownerAbs.left + local.left,
      bottom: ownerAbs.top + local.top + local.height,
      right: ownerAbs.left + local.left + local.width,
    );
  }

  final childrenOf = <ViHeapObject, List<ViHeapObject>>{};
  for (final object in objects) {
    final parent = liveParent[object];
    if (parent != null) (childrenOf[parent] ??= []).add(object);
  }
  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    final b = root.absBounds;
    if (b != null) {
      root.absBounds = HeapRect(
        top: b.top + dTop,
        left: b.left + dLeft,
        bottom: b.bottom + dTop,
        right: b.right + dLeft,
      );
    }
    for (final child in childrenOf[root] ?? const <ViHeapObject>[]) {
      shiftSubtree(child, dTop, dLeft);
    }
  }

  for (final object in objects) {
    if (object.objectClass != HeapObjectClass.bdFlatSequence || object.absBounds == null) continue;
    for (final frame in childrenOf[object] ?? const <ViHeapObject>[]) {
      final local = frame.bounds;
      final abs = frame.absBounds;
      final owner = object.absBounds;
      if (frame.objectClass != HeapObjectClass.bdSequenceFrame || local == null || abs == null || owner == null) {
        continue;
      }
      final dTop = owner.top + local.top - abs.top;
      final dLeft = owner.left + local.left - abs.left;
      if (dTop != 0 || dLeft != 0) shiftSubtree(frame, dTop, dLeft);
    }
  }

  for (final object in objects) {
    object.category = classifyObject(objectClass: object.objectClass, termCount: object.termCount);
    object.typeKind = inferTypeKind(c4ops[object] ?? const <int>{}, formatPayloads[object]);
  }

  final byOid = {for (final object in objects) object.oid: object};
  for (final object in objects) {
    if (object.items.isEmpty) continue;
    var parentOid = object.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 12) {
      final po = byOid[parentOid];
      if (po == null) break;
      if (kControlTerminalClasses.contains(po.objectClass)) {
        if (po.items.isEmpty) po.items = object.items;
        break;
      }
      parentOid = po.parentOid;
      depth++;
    }
  }

  for (final object in objects) {
    final helpText = object.helpText;
    if (helpText == null || helpText.isEmpty || object.absBounds != null) continue;
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null && seen.add(parentOid)) {
      final po = byOid[parentOid];
      if (po == null) break;
      if (po.absBounds != null) {
        po.helpText ??= helpText;
        break;
      }
      parentOid = po.parentOid;
    }
  }

  final nodeKids = _childrenByParentOid(objects);

  for (final object in objects) {
    if (object.category != ViObjectKind.unknown) continue;
    final bounds = object.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    if (bounds.width * bounds.height >= _structureAreaCap) continue;
    if (object.parentOid == null || byOid[object.parentOid]?.objectClass != HeapObjectClass.bdFrame) continue;
    final cs = nodeKids[object.oid];
    if (cs == null) continue;
    final hasStructural = cs.any((c) => c.kind == kNodeEndpointDcoKind);
    final hasConnector = cs.any((c) => c.objectClass == HeapObjectClass.connectorTerminal);
    if (!hasStructural || hasConnector) continue;
    object.category = ViObjectKind.node;
  }

  for (final object in objects) {
    if (object.category != ViObjectKind.node || object.label != null) continue;
    final caps = (nodeKids[object.oid] ?? const <ViHeapObject>[])
        .where((c) => c.objectClass == HeapObjectClass.controlLabel)
        .map((c) => c.label?.trim())
        .where((cap) => cap != null && cap.isNotEmpty);
    if (caps.isNotEmpty) object.label = caps.first;
  }

  _reanchorScrolledControls(objects, byOid, nodeKids);
  return ViDiagram(sectionTag: sectionTag, objects: objects, version: version);
}

List<String> _parseEnumItems(List<int> payload) {
  final out = <String>[];
  var i = 0;
  while (i < payload.length) {
    final len = payload[i++];
    if (len == 0) continue;
    if (i + len > payload.length) return const [];
    final text = String.fromCharCodes(payload.sublist(i, i + len));
    i += len;
    if (!text.codeUnits.every((c) => c >= 0x20 && c < 0x7f)) return const [];
    out.add(text);
  }
  return out;
}

void _reanchorScrolledControls(
  List<ViHeapObject> objects,
  Map<int, ViHeapObject> byOid,
  Map<int, List<ViHeapObject>> kids,
) {
  int? reanchorViewport(ViHeapObject object) {
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null) {
      if (!seen.add(parentOid)) return null;
      final po = byOid[parentOid];
      if (po == null) return null;
      if (po.objectClass == HeapObjectClass.contentViewport) return po.oid;
      if (kControlTerminalClasses.contains(po.objectClass) || po.bounds != null) return null;
      parentOid = po.parentOid;
    }
    return null;
  }

  final groups = <int, List<ViHeapObject>>{};
  for (final object in objects) {
    if (!kControlTerminalClasses.contains(object.objectClass) || object.bounds == null || object.absBounds == null) {
      continue;
    }
    final viewport = reanchorViewport(object);
    if (viewport != null) (groups[viewport] ??= <ViHeapObject>[]).add(object);
  }

  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    if (dTop == 0 && dLeft == 0) return;
    final seen = <ViHeapObject>{root};
    final expanded = <int>{};
    final work = <ViHeapObject>[root];
    while (work.isNotEmpty) {
      final object = work.removeLast();
      final bounds = object.absBounds;
      if (bounds != null) {
        object.absBounds = HeapRect(
          top: bounds.top + dTop,
          left: bounds.left + dLeft,
          bottom: bounds.bottom + dTop,
          right: bounds.right + dLeft,
        );
      }
      if (!expanded.add(object.oid)) continue;
      final cs = kids[object.oid];
      if (cs != null) {
        for (final child in cs) {
          if (seen.add(child)) work.add(child);
        }
      }
    }
  }

  for (final MapEntry(key: vOid, value: controls) in groups.entries) {
    final viewport = byOid[vOid];
    if (viewport?.absBounds == null) continue;
    final minTop = controls.map((c) => c.bounds!.top).reduce(min);
    final minLeft = controls.map((c) => c.bounds!.left).reduce(min);
    for (final control in controls) {
      final newTop = viewport!.absBounds!.top + (control.bounds!.top - minTop);
      final newLeft = viewport.absBounds!.left + (control.bounds!.left - minLeft);
      shiftSubtree(control, newTop - control.absBounds!.top, newLeft - control.absBounds!.left);
    }
  }
}

/// The drawing kind of a data type, or null for one the diagram does not classify.
ViTypeKind? typeKindOfDataType(ViDataType type) => switch (type) {
  ViDataType.i8 ||
  ViDataType.i16 ||
  ViDataType.i32 ||
  ViDataType.i64 ||
  ViDataType.u8 ||
  ViDataType.u16 ||
  ViDataType.u32 ||
  ViDataType.u64 => ViTypeKind.numericInt,
  ViDataType.sgl ||
  ViDataType.dbl ||
  ViDataType.ext ||
  ViDataType.complexSgl ||
  ViDataType.complexDbl ||
  ViDataType.complexExt => ViTypeKind.numericFloat,
  ViDataType.enumU8 || ViDataType.enumU16 || ViDataType.enumU32 => ViTypeKind.enumRing,
  ViDataType.boolean => ViTypeKind.boolean,
  ViDataType.string || ViDataType.cString || ViDataType.pascalString || ViDataType.subString => ViTypeKind.string,
  ViDataType.path => ViTypeKind.path,
  ViDataType.cluster => ViTypeKind.cluster,
  ViDataType.array || ViDataType.subArray || ViDataType.arrayDataPointer => ViTypeKind.array,
  ViDataType.refnum => ViTypeKind.refnum,
  _ => null,
};

/// Joins the diagrams to the type pool: marks indicators from their `objFlags`, resolves each
/// `typeDescIdx` through [table] (the data-space type map) offset by [typeIndexBase], copies
/// the result to objects that reach a DCO through `dcoRef`, then decodes constant values.
void resolveDataSpaceTypes({
  required List<ViType> pool,
  required List<int> table,
  required int? typeIndexBase,
  required List<ViDiagram> blockDiagrams,
  required List<ViDiagram> frontPanelDiagrams,
}) {
  final diagrams = [...blockDiagrams, ...frontPanelDiagrams];

  ViHeapObject? findDco(ViDiagram own, int oid) {
    final local = own.byId[oid];
    if (local != null) return local;
    for (final diagram in diagrams) {
      if (identical(diagram, own)) continue;
      final hit = diagram.byId[oid];
      if (hit != null) return hit;
    }
    return null;
  }

  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      if (object.objectClass == HeapObjectClass.node && object.typeDescIdx != null) {
        object.isIndicator = object.hasFlag(ViObjFlag.indicator);
      }
    }
  }
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      if (object.isIndicator != null) continue;
      final dcoRefs = object.typedRefs[HeapRefKind.dcoRef];
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      object.isIndicator = findDco(diagram, dcoRefs.first)?.isIndicator;
    }
  }

  _resolveTypeIndices(pool: pool, table: table, base: typeIndexBase, diagrams: diagrams, findDco: findDco);

  for (final diagram in diagrams) {
    decodeBdConstValues(diagram);
  }
}

void _resolveTypeIndices({
  required List<ViType> pool,
  required List<int> table,
  required int? base,
  required List<ViDiagram> diagrams,
  required ViHeapObject? Function(ViDiagram own, int oid) findDco,
}) {
  if (pool.isEmpty || table.isEmpty || base == null) return;

  ViType? resolve(int base, int index) {
    final ti = base + index;
    if (ti < 0 || ti >= table.length) return null;
    final pi = table[ti];
    return pi >= 0 && pi < pool.length ? pool[pi] : null;
  }

  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      final index = object.typeDescIdx;
      if (index == null) continue;
      final type = resolve(base, index);
      if (type == null) continue;
      final kind = typeKindOfDataType(type.kind);
      if (kind != null) object.typeKind = kind;
      object.dataType = type.kind;
      object.resolvedType = type;
      if (type case ViArrayType(:final elementIndex) when elementIndex < pool.length) {
        final elementType = pool[elementIndex];
        object.resolvedElementType = elementType;
        if (elementType.kind == ViDataType.cluster) {
          object.resolvedElementMembers = clusterFields(elementType, pool);
        }
      }
      if (type.kind == ViDataType.cluster) {
        object.resolvedMembers = clusterFields(type, pool);
      }
      final typeName = type.label?.trim();
      if (typeName != null && typeName.isNotEmpty) {
        object.typeName ??= typeName;
      }
    }
  }
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      if (object.typeDescIdx != null) continue;
      final dcoRefs = object.typedRefs[HeapRefKind.dcoRef];
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      final dco = findDco(diagram, dcoRefs.first);
      if (dco == null) continue;
      if (dco.typeKind != ViTypeKind.unknown) object.typeKind = dco.typeKind;
      object.dataType ??= dco.dataType;
      object.resolvedType ??= dco.resolvedType;
      object.resolvedElementType ??= dco.resolvedElementType;
      if (object.resolvedMembers.isEmpty) {
        object.resolvedMembers = dco.resolvedMembers;
      }
      if (object.resolvedElementMembers.isEmpty) {
        object.resolvedElementMembers = dco.resolvedElementMembers;
      }
      object.typeName ??= dco.typeName;
    }
  }
}

int? _flatNumericSize(ViDataType kind) => switch (kind) {
  ViDataType.i8 || ViDataType.u8 || ViDataType.enumU8 => 1,
  ViDataType.i16 || ViDataType.u16 || ViDataType.enumU16 => 2,
  ViDataType.i32 || ViDataType.u32 || ViDataType.enumU32 || ViDataType.sgl => 4,
  ViDataType.i64 || ViDataType.u64 || ViDataType.dbl => 8,
  _ => null,
};

num _flatNumericAt(Uint8List flat, int offset, ViDataType kind, int size) {
  if (kind == ViDataType.sgl) return ByteData.sublistView(flat).getFloat32(offset);
  if (kind == ViDataType.dbl) return ByteData.sublistView(flat).getFloat64(offset);
  var value = 0;
  for (var i = 0; i < size; i++) {
    value = (value << 8) | flat[offset + i];
  }
  final signed = kind == ViDataType.i8 || kind == ViDataType.i16 || kind == ViDataType.i32 || kind == ViDataType.i64;
  return signed ? value.toSigned(8 * size) : value;
}

// TODO: payloads stored wider than their numeric type, and arrays of non-numeric elements, are not decoded.
void _typedBdConstDecode(ViHeapObject object) {
  final flat = object.constValueRaw;
  final type = object.resolvedType;
  if (flat == null || type == null) return;
  final scalarSize = _flatNumericSize(type.kind);
  if (scalarSize != null) {
    if (flat.isEmpty || flat.length > scalarSize) return;
    if (flat.length < scalarSize && (type.kind == ViDataType.sgl || type.kind == ViDataType.dbl)) {
      return;
    }
    final size = flat.length;
    final kind = size < scalarSize ? ViDataType.u64 : type.kind;
    final value = _flatNumericAt(flat, 0, kind, size);
    if (value is double && !value.isFinite) return;
    object.constNumeric = value;
    return;
  }
  if (type.kind == ViDataType.string) {
    if (object.constValueScalar || flat.length < 4) return;
    final declared = ByteData.sublistView(flat).getUint32(0);
    if (4 + declared == flat.length) {
      object.constText = String.fromCharCodes(flat, 4);
    } else if (declared == 0 && flat.length == 5 && flat[4] == 0) {
      object.constText = '';
    }
    return;
  }
  if (type is! ViArrayType) return;
  final element = object.resolvedElementType;
  final dimCount = type.dimCount;
  if (element == null || dimCount < 1 || dimCount > 8) return;
  final elementSize = _flatNumericSize(element.kind);
  if (elementSize == null || flat.length < 4 * dimCount) return;
  final view = ByteData.sublistView(flat);
  final dims = [for (var d = 0; d < dimCount; d++) view.getUint32(4 * d)];
  var count = 1;
  for (final dim in dims) {
    count *= dim;
  }
  final expected = 4 * dimCount + count * elementSize;
  final emptyPadded = count == 0 && flat.length == 4 * dimCount + 1 && flat.last == 0;
  if (flat.length != expected && !emptyPadded) return;
  object.constArrayDims = dims;
  object.constArray = [
    for (var i = 0; i < count; i++) _flatNumericAt(flat, 4 * dimCount + i * elementSize, element.kind, elementSize),
  ];
}

/// Fills the `const*` fields of every constant DCO: through its resolved type first, then
/// through [decodeBdConstantValue] for the fields still unset.
void decodeBdConstValues(ViDiagram diagram) {
  final nodeKids = _childrenByParentOid(diagram.objects);
  bool subtreeHasItems(ViHeapObject o, [int depth = 0]) {
    if (o.items.isNotEmpty) return true;
    if (depth >= 16) return false;
    for (final kid in nodeKids[o.oid] ?? const <ViHeapObject>[]) {
      if (subtreeHasItems(kid, depth + 1)) return true;
    }
    return false;
  }

  for (final object in diagram.objects) {
    if (object.objectClass != HeapObjectClass.bdConstDco || object.constValueRaw == null) continue;
    _typedBdConstDecode(object);
    final kids = nodeKids[object.oid];
    if (kids == null || kids.isEmpty) continue;
    final carrier = kids.first.objectClass;
    final wantsItems = carrier == HeapObjectClass.enumRingControl || carrier == HeapObjectClass.clusterShell;
    final value = decodeBdConstantValue(
      carrier: carrier,
      flat: object.constValueRaw,
      scalar: object.constValueScalar,
      hasEnumItems: wantsItems && subtreeHasItems(object),
    );
    if (value is bool) object.constBool ??= value;
    if (value is num) object.constNumeric ??= value;
    if (value is String) object.constText ??= value;
  }
}
