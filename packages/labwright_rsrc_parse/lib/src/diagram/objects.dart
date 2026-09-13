/// The objects of a diagram: [ViHeapObject] with the fields [buildDiagram] fills from the heap
/// records, [HeapObjectClass] naming the object classes, the drawing kinds [ViObjectKind] and
/// [ViTypeKind], the case-selector ranges, and [ViSignalType], a wire's type word.
library;

import 'dart:typed_data';

import '../blocks/FTAB_font_table.dart';
import '../blocks/VCTP_type_pool.dart';
import '../heap/heap.dart';
import 'diagram.dart';
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

/// Structures that hold one frame per case, event or sequence step and show one at a time.
const kMultiFrameStructureClasses = {
  HeapObjectClass.bdStructureFrame,
  HeapObjectClass.bdDisableStructure,
  HeapObjectClass.bdEventStructure,
  HeapObjectClass.bdStackedSequence,
};

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
