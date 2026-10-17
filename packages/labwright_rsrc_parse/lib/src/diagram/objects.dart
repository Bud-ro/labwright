/// The objects of a diagram: [ViHeapObject] with the fields [buildDiagram] fills from the heap
/// records, [BdHeapObjectClass] and [FpHeapObjectClass] naming the object classes, the roles [ViObjectKind] and
/// [ViTypeKind], the case-selector ranges, and [ViSignalType], a wire's type word.
library;

import 'dart:typed_data';

import '../blocks/FTAB_font_table.dart';
import '../blocks/VCTP_type_pool.dart';
import '../heap/heap.dart';
import 'diagram.dart';
import 'obj_flags.dart';
import 'prim_ops.dart';

/// What role an object plays: a [BdObjectKind] on a block diagram, an [FpObjectKind] on a front
/// panel; [classifyObject] assigns it from the object's class and terminal count.
sealed class ViObjectKind {
  bool get isUnknown;
}

extension ViObjectKindName on ViObjectKind {
  String get label => switch (this) {
    BdObjectKind(:final name) => name,
    FpObjectKind(:final name) => name,
  };
}

/// The role of a block-diagram object.
enum BdObjectKind implements ViObjectKind {
  /// A loop, case, sequence or other container that owns a sub-diagram.
  structure,

  /// One sub-diagram frame of a multi-frame structure.
  frame,

  /// A primitive, sub-VI call or other executable node.
  node,

  /// A terminal, constant, label or other single-terminal object.
  terminal,

  /// An object that carries terminals: a terminal group or any object with a size record.
  terminalCluster,

  /// A signal or wire.
  wire,

  /// Glyphs and chrome that carry no data.
  decoration,

  /// A class whose role is not established.
  unknown;

  @override
  bool get isUnknown => this == unknown;
}

/// The role of a front-panel object.
enum FpObjectKind implements ViObjectKind {
  /// The panel root and its per-panel records.
  root,

  /// A pane or the splitter between panes.
  pane,

  /// An array, cluster, tab control or other control that holds controls.
  container,

  /// A control or indicator, or the data object that owns one.
  control,

  /// A label, scale, numeric display, chrome or other part of a control.
  part,

  /// An object that carries terminals: a terminal group or any object with a size record.
  terminalCluster,

  /// A class whose role is not established.
  unknown;

  @override
  bool get isUnknown => this == unknown;
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
  unbounded(3);

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
  ViHeapObject({required this.oid, required this.kind, required this.offset, required this.objectClass})
    : category = objectClass.category;

  /// Position in [ViDiagram.objects], heap order; the diagram assigns it.
  int index = 0;

  /// The object id the header declares; references name objects by it.
  final int oid;

  /// The class code the header declares, also when no [HeapObjectClass] names it.
  final int kind;

  final HeapObjectClass objectClass;

  /// Byte offset of the object header in the heap body.
  int offset;

  /// Where the object's records end: after its closing group, or the body's end when the walk
  /// left it open.
  int end = 0;

  /// Offset of the bounds record's payload, its four `i16`s, when the object has one.
  int? boundsOffset;

  /// Offset of the label record, header included, when the object has one, and its length.
  int? labelOffset;

  int labelLength = 0;

  /// The bounds record, relative to the parent object's origin.
  HeapRect? bounds;

  /// [bounds] shifted by every ancestor's origin; null for objects without a bounds record.
  HeapRect? absBounds;

  /// The enclosing object, null for a root.
  int? parentOid;

  /// The caption record, else the `shortText` attribute, else for a node the first child label.
  String? label;

  List<List<int>?>? _refsByKind;

  /// Targets of the object's references of [kind], in record order; null when it has none.
  List<int>? refsOf(HeapRefKind kind) => _refsByKind?[kind.index];

  void addRef(HeapRefKind kind, int target) {
    final byKind = _refsByKind ??= List<List<int>?>.filled(HeapRefKind.values.length, null);
    (byKind[kind.index] ??= <int>[]).add(target);
  }

  /// Targets of the object's `childRef` references, in record order; a signal's are its endpoints.
  List<int> get refs => refsOf(HeapRefKind.childRef) ?? const <int>[];

  /// The `childRef` and `dcoRef` targets together.
  Iterable<int> get memberOids => <int>{...?refsOf(HeapRefKind.childRef), ...?refsOf(HeapRefKind.dcoRef)};

  /// The number of size records ([HeapOpcode.size]) the object carries.
  int termCount = 0;

  // TODO: a font run's colour record (raw 0x029) is not captured.
  /// The font runs of the object's text: each starts at a character index and names an `FTAB`
  /// font id.
  List<({int start, int fontId})> textStyleRuns = const [];

  /// The `FTAB` entry of the label's first font run, set by the model once the font table is read.
  ViFontEntry? labelFont;

  bool get labelIsBold => labelFont?.isBold ?? false;

  ViObjectKind category;

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

  /// A string array constant's elements in row-major order, from [decodeBdConstValues].
  List<String>? constTextArray;

  /// The dimension sizes of [constArray] or [constTextArray].
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

  /// The `conNum` attribute of a panel control: its connector-pane terminal, [kViNotOnPane] off
  /// the pane; a control saved without it sits on terminal 0.
  int? conNum;

  /// The frame a multi-frame structure shows: [dIdx] without its high bit.
  int get visibleFrameIndex => (dIdx ?? 0) & 0x7fffffff;

  /// Whether every bit of [flag] is set in [objFlags].
  bool hasFlag(ViObjFlag flag) => ((objFlags ?? 0) & flag.mask) == flag.mask;

  bool get isLabelHidden => objectClass.isLabel && hasFlag(ViObjFlag.labelHidden);

  /// Whether a front-panel control is an indicator, from its [ViObjFlag.indicator] bit or its
  /// `dcoRef` target's; null until [resolveDataSpaceTypes] runs or when neither states it.
  bool? isIndicator;

  /// The `plotColor` attributes as `0xRRGGBB`, one per plot.
  List<int> plotColors = const [];
}

/// How well a heap object class's role is established.
enum ClassConfidence {
  /// Named from a corpus law or a reference render.
  confirmed,

  /// Named from consistent corpus evidence without a direct check.
  inferred,

  /// Only the class code and its category are known.
  kindOnly,
}

/// The class an object header declares: a [BdHeapObjectClass] in a block-diagram heap, an
/// [FpHeapObjectClass] in a front-panel heap. [label] is the display name and [category] the role
/// [classifyObject] starts from.
sealed class HeapObjectClass {
  int get code;
  String get label;
  ViObjectKind get category;
  ClassConfidence get confidence;
  bool get isUnknown;

  /// Whether the class is one of the typed control bodies that carry a value.
  bool get isControlTerminal;

  /// Whether the class holds one frame per case, event or sequence step and shows one at a time.
  bool get isMultiFrameStructure;
}

/// The classes both heaps hold under the same code.
extension HeapObjectClassRoles on HeapObjectClass {
  bool get isLabel => this == BdHeapObjectClass.textLabel || this == FpHeapObjectClass.textLabel;
  bool get isChrome => this == BdHeapObjectClass.chrome || this == FpHeapObjectClass.chrome;
  bool get isArray => this == BdHeapObjectClass.array || this == FpHeapObjectClass.array;
  bool get isPane => this == BdHeapObjectClass.pane || this == FpHeapObjectClass.pane;
  bool get isConnectorTerminal =>
      this == BdHeapObjectClass.connectorTerminal || this == FpHeapObjectClass.connectorTerminal;
}

/// The classes of block-diagram heap objects, by code.
enum BdHeapObjectClass implements HeapObjectClass {
  chrome(0x0009, 'Chrome', BdObjectKind.decoration, ClassConfidence.inferred),
  textLabel(0x000a, 'Label', BdObjectKind.terminal, ClassConfidence.confirmed),
  controlPart(0x000b, 'Control part', BdObjectKind.terminal, ClassConfidence.inferred),
  terminalCluster(0x000c, 'Terminal cluster', BdObjectKind.terminalCluster, ClassConfidence.confirmed),
  itemList(0x000d, 'Enum/ring item list', BdObjectKind.terminal, ClassConfidence.confirmed),
  constant(0x0013, 'Constant', BdObjectKind.unknown, ClassConfidence.inferred),
  expressionNodeTerminal(0x0014, 'Expression Node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  terminalHolder(0x0015, 'Terminal holder', BdObjectKind.terminal, ClassConfidence.inferred),
  panelTerminal(0x0016, 'Front-panel terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  signal(0x0017, 'Signal', BdObjectKind.wire, ClassConfidence.inferred),
  frame(0x001b, 'Structure frame', BdObjectKind.frame, ClassConfidence.inferred),
  wire(0x001d, 'Wire', BdObjectKind.wire, ClassConfidence.inferred),
  forLoop(0x0020, 'For Loop', BdObjectKind.structure, ClassConfidence.inferred),
  whileLoop(0x0021, 'While Loop', BdObjectKind.structure, ClassConfidence.inferred),
  loopTunnel(0x0022, 'Loop tunnel', BdObjectKind.terminal, ClassConfidence.inferred),
  tunnelIndexer(0x0023, 'Tunnel indexer', BdObjectKind.terminal, ClassConfidence.inferred),
  iterationTerminal(0x0024, 'Iteration terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  conditionalTerminal(0x0025, 'Conditional terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  countTerminal(0x0026, 'Count terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  leftShiftRegister(0x0027, 'Left shift register', BdObjectKind.terminal, ClassConfidence.inferred),
  rightShiftRegister(0x0028, 'Right shift register', BdObjectKind.terminal, ClassConfidence.inferred),
  stackedSequence(0x0029, 'Stacked Sequence structure', BdObjectKind.structure, ClassConfidence.inferred),
  sequenceTunnel(0x002a, 'Sequence tunnel', BdObjectKind.terminal, ClassConfidence.inferred),
  sequenceLocal(0x002b, 'Sequence local', BdObjectKind.terminal, ClassConfidence.inferred),
  caseStructure(0x002c, 'Case structure', BdObjectKind.structure, ClassConfidence.inferred),
  caseTunnel(0x002d, 'Case tunnel', BdObjectKind.terminal, ClassConfidence.inferred),
  caseSelectorTerminal(0x002e, 'Case selector terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  primitive(0x002f, 'Primitive', BdObjectKind.node, ClassConfidence.inferred),
  primitiveTerminal(0x0030, 'Primitive terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  subViCall(0x0031, 'Sub-VI call', BdObjectKind.node, ClassConfidence.inferred),
  staticViReference(0x0032, 'Static VI Reference', BdObjectKind.node, ClassConfidence.inferred),
  subViTerminal(0x0033, 'Sub-VI call terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  bundle(0x0034, 'Bundle', BdObjectKind.node, ClassConfidence.inferred),
  bundleTerminal(0x0035, 'Bundle terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  unbundle(0x0036, 'Unbundle', BdObjectKind.node, ClassConfidence.inferred),
  unbundleTerminal(0x0037, 'Unbundle terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  buildArray(0x003a, 'Build Array', BdObjectKind.node, ClassConfidence.inferred),
  buildArrayTerminal(0x003b, 'Build Array terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  indexBundleClusterArray(0x003c, 'Index & Bundle Cluster Array', BdObjectKind.node, ClassConfidence.inferred),
  indexBundleClusterArrayTerminal(0x003d, 'Index & Bundle terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  concatenateStrings(0x003e, 'Concatenate Strings', BdObjectKind.node, ClassConfidence.inferred),
  concatenateStringsTerminal(0x003f, 'Concatenate Strings terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  decimateArray(0x0040, 'Decimate 1D Array', BdObjectKind.node, ClassConfidence.inferred),
  decimateArrayTerminal(0x0041, 'Decimate 1D Array terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  indexArray(0x0044, 'Index Array', BdObjectKind.node, ClassConfidence.inferred),
  indexArrayTerminal(0x0045, 'Index Array terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  arraySubset(0x0048, 'Array Subset', BdObjectKind.node, ClassConfidence.inferred),
  arraySubsetTerminal(0x0049, 'Array Subset terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  formulaNode(0x004a, 'Formula Node', BdObjectKind.node, ClassConfidence.inferred),
  formulaNodeTerminal(0x004b, 'Formula Node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  iconConstant(0x004e, 'Iconic constant (Empty String, Not A Path…)', BdObjectKind.terminal, ClassConfidence.inferred),
  boolean(0x004f, 'Boolean', BdObjectKind.terminal, ClassConfidence.inferred),
  numeric(0x0050, 'Numeric', BdObjectKind.terminal, ClassConfidence.confirmed),
  string(0x0051, 'String', BdObjectKind.terminal, ClassConfidence.inferred),
  array(0x0052, 'Array', BdObjectKind.structure, ClassConfidence.inferred),
  cluster(0x0053, 'Cluster', BdObjectKind.structure, ClassConfidence.inferred),
  refnum(0x0055, 'Refnum (queue, event, DVR)', BdObjectKind.terminal, ClassConfidence.inferred),
  colorBox(0x0056, 'Color box', BdObjectKind.terminal, ClassConfidence.inferred),
  enumRing(0x0057, 'Enum/ring', BdObjectKind.terminal, ClassConfidence.confirmed),
  path(0x005b, 'Path', BdObjectKind.terminal, ClassConfidence.inferred),
  picture(0x005f, 'Picture', BdObjectKind.terminal, ClassConfidence.inferred),
  byNameTerminal(0x0062, 'Bundle/Unbundle By Name terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  bundleByName(0x0063, 'Bundle/Unbundle By Name', BdObjectKind.node, ClassConfidence.inferred),
  typeDefinition(0x0064, 'Type definition instance', BdObjectKind.structure, ClassConfidence.inferred),
  convertUnit(0x0066, 'Convert Unit', BdObjectKind.node, ClassConfidence.inferred),
  staticViReferenceTerminal(0x0067, 'Static VI Reference terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  connectorTerminal(0x0068, 'Connector terminal', BdObjectKind.terminal, ClassConfidence.confirmed),
  callLibrary(0x006a, 'Call Library Function Node', BdObjectKind.node, ClassConfidence.confirmed),
  callLibraryTerminal(0x006b, 'Call Library parameter terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  compoundArithmetic(0x006c, 'Compound Arithmetic', BdObjectKind.node, ClassConfidence.inferred),
  compoundArithmeticTerminal(0x006d, 'Compound Arithmetic terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  root(0x007e, 'Diagram root', BdObjectKind.structure, ClassConfidence.confirmed),
  propertyNode(0x008c, 'Property Node', BdObjectKind.node, ClassConfidence.inferred),
  propertyTerminal(0x008d, 'Property terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  refErrorTerminal(0x008e, 'Reference and error terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  scanFromStringTerminal(0x0090, 'Scan From String terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  formatIntoStringTerminal(0x0091, 'Format Into String terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  scanFromString(0x0092, 'Scan From String', BdObjectKind.node, ClassConfidence.inferred),
  formatIntoString(0x0093, 'Format Into String', BdObjectKind.node, ClassConfidence.inferred),
  ioName(0x0094, 'I/O name (channel, tag)', BdObjectKind.terminal, ClassConfidence.inferred),
  caseSelectorLabel(0x0095, 'Case selector label', BdObjectKind.terminal, ClassConfidence.inferred),
  invokeNode(0x00a9, 'Invoke Node', BdObjectKind.node, ClassConfidence.inferred),
  invokeTerminal(0x00aa, 'Invoke Node parameter terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  callByReference(0x00ae, 'Call By Reference / asynchronous call', BdObjectKind.node, ClassConfidence.inferred),
  matlabScriptTerminal(0x00b3, 'MATLAB script node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  matlabScriptNode(0x00b4, 'MATLAB script node', BdObjectKind.node, ClassConfidence.inferred),
  comboBox(0x00b5, 'Combo box', BdObjectKind.terminal, ClassConfidence.inferred),
  localVariable(0x00b6, 'Local variable', BdObjectKind.node, ClassConfidence.inferred),
  localVariableTerminal(0x00b7, 'Local variable terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  waveform(0x00b8, 'Waveform', BdObjectKind.terminal, ClassConfidence.inferred),
  replaceArraySubset(0x00b9, 'Replace Array Subset', BdObjectKind.node, ClassConfidence.inferred),
  replaceArraySubsetTerminal(0x00ba, 'Replace Array Subset terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  insertIntoArray(0x00bb, 'Insert Into Array', BdObjectKind.node, ClassConfidence.inferred),
  insertIntoArrayTerminal(0x00bc, 'Insert Into Array terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  deleteFromArray(0x00bd, 'Delete From Array', BdObjectKind.node, ClassConfidence.inferred),
  deleteFromArrayTerminal(0x00be, 'Delete From Array terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  expressionNode(0x00c0, 'Expression Node', BdObjectKind.node, ClassConfidence.inferred),
  tipStrip(0x00c1, 'Tip strip', BdObjectKind.terminal, ClassConfidence.confirmed),
  variant(0x00c2, 'Variant', BdObjectKind.terminal, ClassConfidence.inferred),
  polymorphicViCall(0x00c5, 'Polymorphic VI call', BdObjectKind.node, ClassConfidence.inferred),
  polymorphicViTerminal(0x00c6, 'Polymorphic VI call terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  flatSequence(0x00ca, 'Flat Sequence structure', BdObjectKind.structure, ClassConfidence.inferred),
  sequenceFrameTunnel(0x00cb, 'Sequence frame tunnel', BdObjectKind.terminal, ClassConfidence.inferred),
  expressViPart(0x00cc, 'Express VI call part', BdObjectKind.terminal, ClassConfidence.inferred),
  disableStructure(0x00cd, 'Disable structure', BdObjectKind.structure, ClassConfidence.inferred),
  disableTunnel(0x00ce, 'Disable structure tunnel', BdObjectKind.terminal, ClassConfidence.inferred),
  waveformNode(0x00d0, 'Waveform node', BdObjectKind.node, ClassConfidence.inferred),
  waveformNodeTerminal(0x00d1, 'Waveform node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  listItem(0x00d2, 'Listbox/legend item', BdObjectKind.decoration, ClassConfidence.inferred),
  eventStructure(0x00d5, 'Event structure', BdObjectKind.structure, ClassConfidence.inferred),
  eventDataNode(0x00d6, 'Event Data Node', BdObjectKind.node, ClassConfidence.inferred),
  eventDataTerminal(0x00d7, 'Event Data Node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  eventTimeoutTerminal(0x00d8, 'Event structure timeout terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  timeStamp(0x00df, 'Time stamp', BdObjectKind.terminal, ClassConfidence.inferred),
  numericDisplay(0x00e0, 'Numeric display', BdObjectKind.terminal, ClassConfidence.confirmed),
  polymorphicSelector(0x00e5, 'Polymorphic instance selector', BdObjectKind.unknown, ClassConfidence.inferred),
  listbox(0x00e6, 'Listbox', BdObjectKind.terminal, ClassConfidence.inferred),
  registerForEvents(0x00eb, 'Register For Events', BdObjectKind.node, ClassConfidence.inferred),
  registerForEventsTerminal(0x00ec, 'Register For Events terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  constructorNode(0x00ed, '.NET Constructor Node', BdObjectKind.node, ClassConfidence.inferred),
  eventRefnumNode(0x00f4, 'Event refnum node', BdObjectKind.node, ClassConfidence.inferred),
  eventRefnumTerminal(0x00f5, 'Event refnum node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  timedLoopTerminal(0x00f9, 'Timed Loop terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  timedLoop(0x00fb, 'Timed Loop', BdObjectKind.structure, ClassConfidence.inferred),
  strictStaticViReference(0x0103, 'Static VI Reference (strictly typed)', BdObjectKind.node, ClassConfidence.inferred),
  classMethodCall(0x0104, 'Class method call', BdObjectKind.node, ClassConfidence.inferred),
  xnode(0x0105, 'XNode', BdObjectKind.node, ClassConfidence.inferred),
  xnodeTerminal(0x0106, 'XNode terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  classMethodCallPart(0x010b, 'Class method call part', BdObjectKind.terminal, ClassConfidence.inferred),
  objectRefnum(0x010c, 'Refnum (VI Server, LabVIEW object)', BdObjectKind.terminal, ClassConfidence.inferred),
  propertyItem(0x0110, 'Property item', BdObjectKind.terminal, ClassConfidence.inferred),
  propertyAccessorItem(0x0113, 'Property item (class accessor)', BdObjectKind.terminal, ClassConfidence.inferred),
  initializeArray(0x0114, 'Initialize Array', BdObjectKind.node, ClassConfidence.inferred),
  initializeArrayTerminal(0x0115, 'Initialize Array terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  reshapeArray(0x0116, 'Reshape Array', BdObjectKind.node, ClassConfidence.inferred),
  reshapeArrayTerminal(0x0117, 'Reshape Array terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  pane(0x011c, 'Array element viewport', BdObjectKind.structure, ClassConfidence.confirmed),
  timedLoopNode(0x0120, 'Timed Loop node', BdObjectKind.node, ClassConfidence.inferred),
  sequenceFrame(0x0121, 'Sequence frame', BdObjectKind.structure, ClassConfidence.inferred),
  mathScriptNode(0x012a, 'MathScript Node', BdObjectKind.structure, ClassConfidence.inferred),
  mathScriptTerminal(0x012b, 'MathScript Node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  mathScriptFrame(0x0137, 'MathScript Node frame', BdObjectKind.frame, ClassConfidence.inferred),
  feedbackInitializerTerminal(0x0145, 'Feedback Node init terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  sharedVariable(0x0148, 'Shared variable node', BdObjectKind.node, ClassConfidence.inferred),
  sharedVariableTerminal(0x0149, 'Shared variable node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  feedbackNode(0x014a, 'Feedback Node', BdObjectKind.node, ClassConfidence.inferred),
  primitiveClusterTerminal(0x014b, 'Cluster arithmetic terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  inPlaceElementStructure(0x014d, 'In Place Element structure', BdObjectKind.structure, ClassConfidence.inferred),
  inPlaceBorderTerminal(0x014e, 'In Place Element border terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  mathScriptPart(0x015f, 'MathScript Node part', BdObjectKind.terminal, ClassConfidence.inferred),
  mathScriptSubVi(0x0167, 'MathScript generated sub-VI', BdObjectKind.node, ClassConfidence.inferred),
  parallelInstancesTerminal(0x0169, 'Parallel instances terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  openVariableConnection(0x016a, 'Open Variable Connection', BdObjectKind.node, ClassConfidence.inferred),
  writeVariable(0x016c, 'Write Variable', BdObjectKind.node, ClassConfidence.inferred),
  variableConnectionTerminal(0x016d, 'Variable connection terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  feedbackInitializerPart(0x016e, 'Feedback Node initializer part', BdObjectKind.terminal, ClassConfidence.inferred),
  feedbackInitializer(0x0170, 'Feedback Node initializer', BdObjectKind.node, ClassConfidence.inferred),
  mergeErrors(0x0172, 'Merge Errors', BdObjectKind.node, ClassConfidence.inferred),
  mergeErrorsTerminal(0x0173, 'Merge Errors terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  forLoopConditionalTerminal(0x0176, 'For Loop conditional terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  attachmentArrow(0x0177, 'Comment attachment arrow', BdObjectKind.decoration, ClassConfidence.inferred),
  pythonNode(0x0183, 'Python Node', BdObjectKind.node, ClassConfidence.inferred),
  pythonTerminal(0x0184, 'Python Node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  set(0x0185, 'Set', BdObjectKind.terminal, ClassConfidence.inferred),
  map(0x0186, 'Map', BdObjectKind.terminal, ClassConfidence.inferred),
  mapSetNode(0x018d, 'Map/set node', BdObjectKind.node, ClassConfidence.inferred),
  mapSetTerminal(0x018e, 'Map/set node terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  matlabNode(0x0193, 'Call MATLAB Function', BdObjectKind.node, ClassConfidence.inferred),
  matlabTerminal(0x0194, 'Call MATLAB Function terminal', BdObjectKind.terminal, ClassConfidence.inferred),

  node0042(0x0042, 'Array node (0x0042)', BdObjectKind.node, ClassConfidence.kindOnly),
  terminal0043(0x0043, 'Array node (0x0042) terminal', BdObjectKind.terminal, ClassConfidence.kindOnly),

  invokeParameter0111(0x0111, 'Invoke parameter item (0x0111)', BdObjectKind.terminal, ClassConfidence.inferred),
  invokeParameter0112(0x0112, 'Invoke parameter item (0x0112)', BdObjectKind.terminal, ClassConfidence.inferred),

  classMethodCall0124(0x0124, 'Class method call (0x0124)', BdObjectKind.node, ClassConfidence.inferred),

  feedbackTerminal0144(0x0144, 'Feedback Node terminal (0x0144)', BdObjectKind.terminal, ClassConfidence.inferred),
  feedbackTerminal0146(0x0146, 'Feedback Node terminal (0x0146)', BdObjectKind.terminal, ClassConfidence.inferred),

  inPlaceNode014f(0x014f, 'In Place Element border node (0x014f)', BdObjectKind.node, ClassConfidence.inferred),
  inPlaceNode0150(0x0150, 'In Place Element border node (0x0150)', BdObjectKind.node, ClassConfidence.inferred),
  inPlaceNode0152(0x0152, 'In Place Element border node (0x0152)', BdObjectKind.node, ClassConfidence.inferred),
  inPlaceNode0153(0x0153, 'In Place Element node (0x0153)', BdObjectKind.node, ClassConfidence.inferred),
  inPlacePart0154(0x0154, 'In Place Element part (0x0154)', BdObjectKind.terminal, ClassConfidence.inferred),
  inPlaceTerminal0155(0x0155, 'In Place node (0x0153) terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  inPlaceTerminal0156(0x0156, 'In Place node (0x0150) terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  inPlacePart0158(0x0158, 'In Place Element part (0x0158)', BdObjectKind.terminal, ClassConfidence.inferred),
  inPlacePart0159(0x0159, 'In Place Element part (0x0159)', BdObjectKind.terminal, ClassConfidence.inferred),
  inPlacePart015b(0x015b, 'In Place Element part (0x015b)', BdObjectKind.terminal, ClassConfidence.inferred),
  inPlaceTerminal0163(0x0163, 'In Place node (0x014f) terminal', BdObjectKind.terminal, ClassConfidence.inferred),
  inPlacePart018f(0x018f, 'In Place Element part (0x018f)', BdObjectKind.terminal, ClassConfidence.inferred),

  node018b(0x018b, 'Node (0x018b)', BdObjectKind.node, ClassConfidence.kindOnly),
  terminal018c(0x018c, 'Node (0x018b) terminal', BdObjectKind.terminal, ClassConfidence.kindOnly),

  waveform00e2(0x00e2, 'Waveform (0x00e2)', BdObjectKind.terminal, ClassConfidence.inferred),

  unknown(-0x0001, 'Unknown class', BdObjectKind.unknown, ClassConfidence.kindOnly);

  const BdHeapObjectClass(this.code, this.label, this.category, this.confidence);

  @override
  final int code;
  @override
  final String label;
  @override
  final BdObjectKind category;
  @override
  final ClassConfidence confidence;

  static final List<BdHeapObjectClass> _byCode = _classTable(values, unknown);

  /// The class with [code], or [unknown].
  static BdHeapObjectClass fromCode(int code) => code >= 0 && code < _byCode.length ? _byCode[code] : unknown;

  static final List<bool> _controlTerminal = [for (final c in values) kBdControlTerminalClasses.contains(c)];
  static final List<bool> _multiFrame = [for (final c in values) kMultiFrameStructureClasses.contains(c)];

  @override
  bool get isUnknown => this == unknown;
  @override
  bool get isControlTerminal => _controlTerminal[index];
  @override
  bool get isMultiFrameStructure => _multiFrame[index];
}

/// The classes of front-panel heap objects, by code.
enum FpHeapObjectClass implements HeapObjectClass {
  chrome(0x0009, 'Chrome', FpObjectKind.part, ClassConfidence.inferred),
  textLabel(0x000a, 'Label', FpObjectKind.part, ClassConfidence.confirmed),
  controlPart(0x000b, 'Control part', FpObjectKind.part, ClassConfidence.inferred),
  terminalCluster(0x000c, 'Terminal cluster', FpObjectKind.terminalCluster, ClassConfidence.confirmed),
  itemList(0x000d, 'Enum/ring/boolean item list', FpObjectKind.part, ClassConfidence.confirmed),
  dco(0x0012, 'Control data object', FpObjectKind.control, ClassConfidence.confirmed),
  panelRoot(0x004c, 'Panel root frame', FpObjectKind.root, ClassConfidence.confirmed),
  boolean(0x004f, 'Boolean', FpObjectKind.control, ClassConfidence.inferred),
  numeric(0x0050, 'Numeric', FpObjectKind.control, ClassConfidence.confirmed),
  string(0x0051, 'String', FpObjectKind.control, ClassConfidence.inferred),
  array(0x0052, 'Array', FpObjectKind.container, ClassConfidence.inferred),
  cluster(0x0053, 'Cluster', FpObjectKind.container, ClassConfidence.inferred),
  refnum(0x0055, 'Refnum (queue, event, DVR)', FpObjectKind.control, ClassConfidence.inferred),
  colorBox(0x0056, 'Color box', FpObjectKind.control, ClassConfidence.inferred),
  enumRing(0x0057, 'Enum/ring', FpObjectKind.control, ClassConfidence.confirmed),
  slide(0x0058, 'Slide', FpObjectKind.control, ClassConfidence.inferred),
  gauge(0x0059, 'Meter/gauge', FpObjectKind.control, ClassConfidence.inferred),
  path(0x005b, 'Path', FpObjectKind.control, ClassConfidence.inferred),
  graph(0x005e, 'Graph/chart', FpObjectKind.control, ClassConfidence.inferred),
  picture(0x005f, 'Picture', FpObjectKind.control, ClassConfidence.inferred),
  typeDefinition(0x0064, 'Type definition instance', FpObjectKind.container, ClassConfidence.inferred),
  connectorTerminal(0x0068, 'Connector terminal', FpObjectKind.part, ClassConfidence.confirmed),
  root(0x007e, 'Panel root', FpObjectKind.root, ClassConfidence.confirmed),
  panelProperties(0x007f, 'Panel properties', FpObjectKind.root, ClassConfidence.inferred),
  scale(0x008f, 'Scale', FpObjectKind.part, ClassConfidence.inferred),
  ioName(0x0094, 'I/O name (channel, tag)', FpObjectKind.control, ClassConfidence.inferred),
  ringText(0x0095, 'Combo box / I/O name text', FpObjectKind.part, ClassConfidence.inferred),
  controlGroup(0x00ac, 'Grouped controls', FpObjectKind.container, ClassConfidence.inferred),
  automationRefnum(0x00af, '.NET/ActiveX refnum', FpObjectKind.control, ClassConfidence.inferred),
  comboBox(0x00b5, 'Combo box', FpObjectKind.control, ClassConfidence.inferred),
  waveform(0x00b8, 'Waveform', FpObjectKind.control, ClassConfidence.inferred),
  tipStrip(0x00c1, 'Tip strip', FpObjectKind.part, ClassConfidence.confirmed),
  variant(0x00c2, 'Variant', FpObjectKind.control, ClassConfidence.inferred),
  tabControl(0x00c3, 'Tab control', FpObjectKind.container, ClassConfidence.inferred),
  tabPages(0x00c7, 'Tab control pages', FpObjectKind.container, ClassConfidence.inferred),
  tabPage(0x00c8, 'Tab page', FpObjectKind.container, ClassConfidence.inferred),
  subPanel(0x00cf, 'Sub panel', FpObjectKind.control, ClassConfidence.inferred),
  legendItem(0x00d2, 'Legend/list item', FpObjectKind.part, ClassConfidence.inferred),
  timeStamp(0x00df, 'Time stamp', FpObjectKind.control, ClassConfidence.inferred),
  numericDisplay(0x00e0, 'Numeric display', FpObjectKind.part, ClassConfidence.confirmed),
  table(0x00e1, 'Table', FpObjectKind.control, ClassConfidence.inferred),
  listbox(0x00e6, 'Listbox', FpObjectKind.control, ClassConfidence.inferred),
  graphLegend(0x00e7, 'Graph legend', FpObjectKind.part, ClassConfidence.inferred),
  image(0x00ee, 'IMAQ image', FpObjectKind.control, ClassConfidence.inferred),
  radioButtons(0x00ef, 'Radio buttons', FpObjectKind.container, ClassConfidence.inferred),
  mixedSignalPlotArea(0x00f2, 'Mixed signal graph plot area', FpObjectKind.part, ClassConfidence.inferred),
  xcontrol(0x0102, 'XControl', FpObjectKind.control, ClassConfidence.inferred),
  objectRefnum(0x010c, 'Refnum (VI Server, LabVIEW object)', FpObjectKind.control, ClassConfidence.inferred),
  pane(0x011c, 'Pane', FpObjectKind.pane, ClassConfidence.confirmed),
  splitter(0x011d, 'Splitter bar', FpObjectKind.pane, ClassConfidence.inferred),
  set(0x0185, 'Set', FpObjectKind.control, ClassConfidence.inferred),
  map(0x0186, 'Map', FpObjectKind.control, ClassConfidence.inferred),

  waveform00e2(0x00e2, 'Waveform (0x00e2)', FpObjectKind.control, ClassConfidence.inferred),

  panelRecord0101(0x0101, 'Panel record (0x0101)', FpObjectKind.root, ClassConfidence.kindOnly),

  enum014c(0x014c, 'Enum (0x014c)', FpObjectKind.control, ClassConfidence.inferred),

  unknown(-0x0001, 'Unknown class', FpObjectKind.unknown, ClassConfidence.kindOnly);

  const FpHeapObjectClass(this.code, this.label, this.category, this.confidence);

  @override
  final int code;
  @override
  final String label;
  @override
  final FpObjectKind category;
  @override
  final ClassConfidence confidence;

  static final List<FpHeapObjectClass> _byCode = _classTable(values, unknown);

  /// The class with [code], or [unknown].
  static FpHeapObjectClass fromCode(int code) => code >= 0 && code < _byCode.length ? _byCode[code] : unknown;

  static final List<bool> _controlTerminal = [for (final c in values) kFpControlTerminalClasses.contains(c)];

  @override
  bool get isUnknown => this == unknown;
  @override
  bool get isControlTerminal => _controlTerminal[index];
  @override
  bool get isMultiFrameStructure => false;
}

List<T> _classTable<T extends HeapObjectClass>(List<T> values, T unknown) {
  final codeCount = values.fold(0, (count, c) => c.code >= count ? c.code + 1 : count);
  final table = List<T>.filled(codeCount, unknown);
  for (final c in values) {
    if (c != unknown) table[c.code] = c;
  }
  return table;
}

/// The class of [kind] in the heap [sectionTag] names: a front-panel class for `FPH*`, else a
/// block-diagram class.
HeapObjectClass heapObjectClassOf(String sectionTag, int kind) =>
    sectionTag.startsWith('FP') ? FpHeapObjectClass.fromCode(kind) : BdHeapObjectClass.fromCode(kind);

/// The block-diagram classes of the typed control bodies that carry a value: numeric, boolean,
/// enum/ring, path and string.
const kBdControlTerminalClasses = {
  BdHeapObjectClass.numeric,
  BdHeapObjectClass.boolean,
  BdHeapObjectClass.enumRing,
  BdHeapObjectClass.path,
  BdHeapObjectClass.string,
};

/// The front-panel classes of the typed controls that carry a value: numeric, boolean, enum/ring,
/// path and string.
const kFpControlTerminalClasses = {
  FpHeapObjectClass.numeric,
  FpHeapObjectClass.boolean,
  FpHeapObjectClass.enumRing,
  FpHeapObjectClass.path,
  FpHeapObjectClass.string,
};

/// Class codes a signal's endpoint references target: a terminal holder or a front-panel terminal.
final Set<int> kSignalEndpointDcoKinds = {kNodeEndpointDcoKind, BdHeapObjectClass.panelTerminal.code};

/// The class code of a terminal holder, the object a wire ends on inside a node.
const int kNodeEndpointDcoKind = 0x0015;

/// Pixels a wire's attach point moves left of a right shift register's column centre.
const int kShiftRegisterColumnLeftOffset = 4;

/// Pixels a wire's attach point moves right of a left shift register's column centre.
const int kShiftRegisterColumnRightOffset = 4;

/// Classes of a node's terminal strip, the column of terminals along its edge.
const kBdTerminalStripClasses = {BdHeapObjectClass.byNameTerminal, BdHeapObjectClass.bundleTerminal};

/// Width in pixels of a terminal strip's attach box.
const int kTerminalStripColumnWidth = 8;

/// Pixels a wire's target lies left of a terminal strip's attach point.
const int kTerminalStripTargetLeftOffset = 8;

/// Structures that hold one frame per case, event or sequence step and show one at a time.
const kMultiFrameStructureClasses = {
  BdHeapObjectClass.caseStructure,
  BdHeapObjectClass.disableStructure,
  BdHeapObjectClass.eventStructure,
  BdHeapObjectClass.stackedSequence,
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
ViObjectKind classifyObject({required HeapObjectClass objectClass, required int termCount}) => switch (objectClass) {
  BdHeapObjectClass() =>
    objectClass == BdHeapObjectClass.terminalCluster || termCount >= 1
        ? BdObjectKind.terminalCluster
        : objectClass.category,
  FpHeapObjectClass() =>
    objectClass == FpHeapObjectClass.terminalCluster || termCount >= 1
        ? FpObjectKind.terminalCluster
        : objectClass.category,
};

const _intConvChars = {0x62, 0x64, 0x6f, 0x78, 0x58};

int? _formatConvChar(List<int> payload) {
  final pct = payload.indexOf(0x25);
  if (pct < 0) return null;
  for (final byte in payload.skip(pct + 1)) {
    if ((byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)) return byte;
  }
  return null;
}

/// What an object's C4 records say about its [ViTypeKind]; [inferTypeKind] reads a set of these
/// as the bits [bit] names.
enum ViTypeKindEvidence {
  /// A `symbolName` record: a Call Library node.
  clnNode,

  /// A `path` record.
  path,

  /// A `stringTable` record: an enum or ring.
  enumRing,

  /// A `formatString` record: a number.
  numeric,

  /// The format string's conversion character is `b`, `d`, `o`, `x` or `X`: an integer.
  integerFormat;

  int get bit => 1 << index;

  /// The bit a record with [opcode] carries on its own; a format string needs [ofFormat].
  static int ofOpcode(int opcode) {
    if (opcode == HeapOpcode.symbolName.byte) return clnNode.bit;
    if (opcode == HeapOpcode.path.byte) return path.bit;
    if (opcode == HeapOpcode.stringTable.byte) return enumRing.bit;
    return 0;
  }

  /// The bits a `formatString` record's [payload] carries.
  static int ofFormat(List<int> payload) {
    final conv = _formatConvChar(payload);
    return numeric.bit | (conv != null && _intConvChars.contains(conv) ? integerFormat.bit : 0);
  }
}

/// The type kind the [ViTypeKindEvidence] bits in [evidence] support, strongest first.
ViTypeKind inferTypeKind(int evidence) {
  if (evidence & ViTypeKindEvidence.clnNode.bit != 0) return ViTypeKind.clnNode;
  if (evidence & ViTypeKindEvidence.path.bit != 0) return ViTypeKind.path;
  if (evidence & ViTypeKindEvidence.enumRing.bit != 0) return ViTypeKind.enumRing;
  if (evidence & ViTypeKindEvidence.numeric.bit != 0) {
    return evidence & ViTypeKindEvidence.integerFormat.bit != 0 ? ViTypeKind.numericInt : ViTypeKind.numericFloat;
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
