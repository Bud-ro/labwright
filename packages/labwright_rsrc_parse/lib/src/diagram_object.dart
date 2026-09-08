import 'dart:typed_data';

import 'blocks/font_table.dart';
import 'blocks/prim_ops.dart';
import 'blocks/type_pool.dart';
import 'heap.dart';
import 'selector_range.dart';

enum ViObjectKind {
  terminalCluster,

  terminal,

  node,

  structure,

  decoration,

  wire,

  unknown,
}

enum ViTypeKind {
  numericInt,

  numericFloat,

  enumRing,

  path,

  clnNode,

  string,

  boolean,

  cluster,

  array,

  refnum,

  unknown,
}

const int kViNoDefaultFrame = 255;

const int kViFirstFrameIsDefault = 0;

const int kViFrameCode = 0x1b;

class ViHeapObject {
  ViHeapObject({required this.oid, required this.kind, required this.offset})
    : objectClass = HeapObjectClass.fromCode(kind);

  final int oid;

  final int kind;

  final HeapObjectClass objectClass;

  final int offset;

  HeapRect? bounds;

  HeapRect? absBounds;

  int? parentOid;

  String? label;

  final List<int> refs = <int>[];

  final Map<HeapRefKind, List<int>> typedRefs = <HeapRefKind, List<int>>{};

  Iterable<int> get memberOids => <int>{
    ...?typedRefs[HeapRefKind.childRef],
    ...?typedRefs[HeapRefKind.dcoRef],
  };

  int termCount = 0;

  // TODO: a font run's colour record (raw 0x029) is not captured.
  List<({int start, int fontId})> textStyleRuns = const [];

  ViFontEntry? labelFont;

  bool get labelIsBold => labelFont?.isBold ?? false;

  ViObjectKind category = ViObjectKind.unknown;

  ViTypeKind typeKind = ViTypeKind.unknown;

  List<String> items = const [];

  List<String> plotNames = const [];

  double? controlMin;

  double? controlMax;

  String? helpText;

  String? constText;

  num? constNumeric;

  bool? constBool;

  Uint8List? constValueRaw;

  bool constValueScalar = false;

  List<num>? constArray;

  List<int>? constArrayDims;

  int? labelModeWord;

  bool get labelJustifyCenter => ((labelModeWord ?? 0) & 0x20) != 0;

  int get labelTextInset => ((labelModeWord ?? 0) & 0x800000) != 0 ? 2 : 1;

  int? arrayIndex;

  List<ViSelectorRange> selectorRanges = const <ViSelectorRange>[];

  List<String> selectorStrings = const <String>[];

  int? defaultFrameIndex;

  String? displayFormat;

  int? bgRgb;

  int? fgRgb;

  int? contentRgb;

  int? structRgb;

  int? borderRgb;

  HeapRect? termBounds;

  int? termBmp;

  int? typeDescIdx;

  String? typeName;

  ViDataType? dataType;

  ViType? resolvedType;

  ViType? resolvedElementType;

  List<ViType> resolvedMembers = const [];

  List<ViType> resolvedElementMembers = const [];

  int? objFlags;

  int? primResId;

  String? get primName => primResId == null ? null : PrimOp.fromId(primResId!)?.opName;

  String? foreignLibraryPath;

  String? foreignEntryPoint;

  Uint8List? wireTableRaw;

  int? lastSignalKind;

  int? dIdx;

  int get visibleFrameIndex => (dIdx ?? 0) & 0x7fffffff;

  bool get isLabelHidden => objectClass == HeapObjectClass.controlLabel && ((objFlags ?? 0) & 0x08) != 0;

  bool? isIndicator;

  List<int> plotColors = const [];
}

enum ClassConfidence {
  confirmed,

  inferred,

  kindOnly,
}

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

  static HeapObjectClass fromCode(int code) => _byCode[code] ?? unknown;
}

const kControlTerminalClasses = {
  HeapObjectClass.numericControl,
  HeapObjectClass.booleanOrClusterControl,
  HeapObjectClass.enumRingControl,
  HeapObjectClass.pathControl,
  HeapObjectClass.stringOrArrayControl,
};

final Set<int> kSignalEndpointDcoKinds = {kNodeEndpointDcoKind, HeapObjectClass.bdLeaf.code};

const int kNodeEndpointDcoKind = 0x15;

const int kRightShiftRegisterClass = 0x28;

const int kLeftShiftRegisterClass = 0x27;

const int kShiftRegisterColumnLeftOffset = 4;

const int kShiftRegisterColumnRightOffset = 4;

const kNodeTerminalStripClasses = {0x62, 0x35};

const int kTerminalStripColumnWidth = 8;

const int kTerminalStripTargetLeftOffset = 8;

const int kTerminalGlyphHiddenFlag = 0x800000;

const kMultiFrameStructureClasses = {
  HeapObjectClass.bdStructureFrame,
  HeapObjectClass.bdDisableStructure,
  HeapObjectClass.bdEventStructure,
  HeapObjectClass.bdStackedSequence,
};

String _fmtNum(double value) =>
    value == value.roundToDouble() && value.abs() < 1e15 ? value.toInt().toString() : value.toString();

String? formatControlRange(double? min, double? max) {
  if (min?.isNaN == true || max?.isNaN == true) return null;
  final low = (min != null && min.isFinite) ? min : null;
  final high = (max != null && max.isFinite) ? max : null;
  if (low == null && high == null) return null;
  if (low != null && high != null) return low >= high ? null : '${_fmtNum(low)} … ${_fmtNum(high)}';
  return low != null ? '≥ ${_fmtNum(low)}' : '≤ ${_fmtNum(high!)}';
}

String stripHelpMarkup(String helpText) {
  final out = helpText.replaceAll(_helpMarkupTag, '').replaceAll(_interiorSpaces, ' ').trim();
  return out.isEmpty ? helpText.trim() : out;
}

final RegExp _helpMarkupTag = RegExp(r'<\s*/?\s*[A-Za-z][A-Za-z0-9]*\s*>');
final RegExp _interiorSpaces = RegExp(r'[ \t]{2,}');

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
