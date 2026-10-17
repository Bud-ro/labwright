/// The objects of a block diagram: [BdObject] with the fields [buildBlockDiagram] fills from
/// the heap records, [BdObjectClass] naming the object classes, [BdObjectKind] the roles, the
/// per-class payloads ([BdPayload]) and the case-selector ranges.
library;

import 'dart:typed_data';

import '../heap/heap.dart';
import '../heap/heap_object.dart';
import '../heap/object_class.dart';
import 'prim_ops.dart';

/// The role of a block-diagram object.
enum BdObjectKind {
  /// A loop, case, sequence or other container that owns a sub-diagram.
  structure,

  /// One sub-diagram frame of a multi-frame structure.
  frame,

  /// A primitive, sub-VI call or other executable node.
  node,

  /// A terminal, constant, label or other single-terminal object.
  terminal,

  /// A terminal group.
  terminalCluster,

  /// A signal or wire.
  wire,

  /// Glyphs and chrome that carry no data.
  decoration,

  /// A class whose role is not established.
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

/// What an object's class adds to the shared fields; [BdPayload.forClass] picks the payload a
/// class carries.
sealed class BdPayload {
  BdPayload();

  /// The payload objects of [objectClass] carry, or null for a class with none.
  static BdPayload? forClass(BdObjectClass objectClass) => switch (objectClass) {
    BdObjectClass.constant => BdConstant(),
    BdObjectClass.caseStructure => BdCaseFrames(),
    BdObjectClass.disableStructure || BdObjectClass.eventStructure || BdObjectClass.stackedSequence => BdFrames(),
    BdObjectClass.signal => BdSignal(),
    BdObjectClass.primitive => BdPrimitive(),
    BdObjectClass.callLibrary => BdForeignCall(),
    BdObjectClass.panelTerminal => BdPanelTerminal(),
    _ => null,
  };
}

/// A constant's value: the flat bytes of its `constValue` attribute and what
/// [decodeBdConstValues] reads out of them.
final class BdConstant extends BdPayload {
  /// The flat bytes of the `constValue` attribute.
  Uint8List? raw;

  /// Whether [raw] came from a scalar attribute width rather than a container blob.
  bool scalar = false;

  /// The constant's text, from the attribute's string form or the decoded bytes.
  String? text;

  num? numeric;

  bool? boolValue;

  /// A numeric array's elements in row-major order.
  List<num>? array;

  /// A string array's elements in row-major order.
  List<String>? textArray;

  /// The dimension sizes of [array] or [textArray].
  List<int>? arrayDims;
}

/// A structure that holds one frame per case, event or sequence step and shows one at a time.
class BdFrames extends BdPayload {
  /// The `dIdx` attribute.
  int? dIdx;

  /// The frame the structure shows: [dIdx] without its high bit.
  int get visibleFrameIndex => (dIdx ?? 0) & 0x7fffffff;
}

/// A case structure: its frames and the selector that picks one.
final class BdCaseFrames extends BdFrames {
  List<ViSelectorRange> selectorRanges = const [];

  List<String> selectorStrings = const [];

  /// The default frame, null when the attribute holds [kViNoDefaultFrame].
  int? defaultFrameIndex;
}

/// A signal: the packed wire route and type word of the wire it draws.
final class BdSignal extends BdPayload {
  /// The `compressedWireTable` attribute, decoded by [decodeWireRoute] and
  /// [decodeWireBranchRoute].
  Uint8List? wireTableRaw;

  /// The `lastSignalKind` attribute; [ViSignalType] reads it.
  int? lastSignalKind;
}

/// A primitive node: which operation it performs.
final class BdPrimitive extends BdPayload {
  /// The `primResID` attribute; [PrimOp] names the ids.
  int? primResId;

  String? get primName {
    final id = primResId;
    return id == null ? null : PrimOp.fromId(id)?.opName;
  }
}

/// A Call Library Function node: the library and symbol it calls.
final class BdForeignCall extends BdPayload {
  /// The library path record.
  String? libraryPath;

  /// The symbol name record.
  String? entryPoint;
}

/// A front-panel terminal: what the data-space join learned from the panel control it
/// references.
final class BdPanelTerminal extends BdPayload {
  /// Whether the panel control is an indicator; null until the join runs or when the control
  /// was not found.
  bool? isIndicator;
}

/// One object of a block-diagram heap.
class BdObject extends HeapObject {
  BdObject({required super.oid, required super.kind, required super.offset})
    : objectClass = BdObjectClass.fromCode(kind),
      category = BdObjectClass.fromCode(kind).category {
    payload = BdPayload.forClass(objectClass);
  }

  final BdObjectClass objectClass;

  BdObjectKind category;

  /// The class's payload, see [BdPayload.forClass].
  BdPayload? payload;

  BdConstant? get constant => switch (payload) {
    final BdConstant constant => constant,
    _ => null,
  };

  BdFrames? get frames => switch (payload) {
    final BdFrames frames => frames,
    _ => null,
  };

  BdCaseFrames? get caseFrames => switch (payload) {
    final BdCaseFrames frames => frames,
    _ => null,
  };

  BdSignal? get signal => switch (payload) {
    final BdSignal signal => signal,
    _ => null,
  };

  BdPrimitive? get primitive => switch (payload) {
    final BdPrimitive primitive => primitive,
    _ => null,
  };

  BdForeignCall? get foreignCall => switch (payload) {
    final BdForeignCall call => call,
    _ => null,
  };

  BdPanelTerminal? get panelTerminal => switch (payload) {
    final BdPanelTerminal terminal => terminal,
    _ => null,
  };

  /// The `termBounds` attribute: a terminal's box relative to the nearest bounded ancestor's
  /// origin.
  HeapRect? termBounds;

  /// The `termBMPs` attribute: which glyph the terminal draws.
  int? termBmp;

  /// The `structColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? structRgb;

  @override
  bool get isTextLabel => objectClass == BdObjectClass.textLabel;
}

/// The classes of block-diagram heap objects, by code.
enum BdObjectClass {
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

  const BdObjectClass(this.code, this.label, this.category, this.confidence);

  final int code;
  final String label;
  final BdObjectKind category;
  final ClassConfidence confidence;

  static final List<BdObjectClass> _byCode = classCodeTable(values, unknown, (c) => c.code);

  /// The class with [code], or [unknown].
  static BdObjectClass fromCode(int code) => code >= 0 && code < _byCode.length ? _byCode[code] : unknown;

  static final List<bool> _controlTerminal = [for (final c in values) kBdControlTerminalClasses.contains(c)];
  static final List<bool> _multiFrame = [for (final c in values) kMultiFrameStructureClasses.contains(c)];

  bool get isUnknown => this == unknown;

  /// Whether the class is one of the typed control bodies that carry a value.
  bool get isControlTerminal => _controlTerminal[index];

  /// Whether the class holds one frame per case, event or sequence step and shows one at a time.
  bool get isMultiFrameStructure => _multiFrame[index];
}

/// The block-diagram classes of the typed control bodies that carry a value: numeric, boolean,
/// enum/ring, path and string.
const kBdControlTerminalClasses = {
  BdObjectClass.numeric,
  BdObjectClass.boolean,
  BdObjectClass.enumRing,
  BdObjectClass.path,
  BdObjectClass.string,
};

/// Class codes a signal's endpoint references target: a terminal holder or a front-panel terminal.
final Set<int> kSignalEndpointDcoKinds = {kNodeEndpointDcoKind, BdObjectClass.panelTerminal.code};

/// The class code of a terminal holder, the object a wire ends on inside a node.
const int kNodeEndpointDcoKind = 0x0015;

/// Pixels a wire's attach point moves left of a right shift register's column centre.
const int kShiftRegisterColumnLeftOffset = 4;

/// Pixels a wire's attach point moves right of a left shift register's column centre.
const int kShiftRegisterColumnRightOffset = 4;

/// Classes of a node's terminal strip, the column of terminals along its edge.
const kBdTerminalStripClasses = {BdObjectClass.byNameTerminal, BdObjectClass.bundleTerminal};

/// Width in pixels of a terminal strip's attach box.
const int kTerminalStripColumnWidth = 8;

/// Pixels a wire's target lies left of a terminal strip's attach point.
const int kTerminalStripTargetLeftOffset = 8;

/// Structures that hold one frame per case, event or sequence step and show one at a time.
const kMultiFrameStructureClasses = {
  BdObjectClass.caseStructure,
  BdObjectClass.disableStructure,
  BdObjectClass.eventStructure,
  BdObjectClass.stackedSequence,
};
