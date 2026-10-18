/// The objects of a block diagram, one shape per record layout: [BdObject] is the sealed root,
/// [BdPlaced] the objects with a bounds record, and the leaves ([BdNode], [BdStructure],
/// [BdTerminal], [BdSignal], [BdConstant], …) carry exactly the fields their records give them.
/// [BdObjectClass] names the object classes and [BdObjectKind] the roles.
library;

import 'dart:typed_data';

import '../blocks/FTAB_font_table.dart';
import '../heap/heap.dart';
import '../heap/heap_object.dart';
import '../heap/obj_flags.dart';
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

/// One object of a block-diagram heap. The shape says what records the object has; the class
/// says what LabVIEW object it is.
sealed class BdObject extends HeapObject implements HeapCaptioned {
  BdObject(
    this.objectClass, {
    required super.oid,
    int? kind,
    super.offset = 0,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    this.refs = const [],
    this.caption,
  }) : super(kind: kind ?? objectClass.code);

  final BdObjectClass objectClass;

  /// The role the class gives the object; a promoted object overrides it.
  BdObjectKind get category => objectClass.category;

  /// Targets of the object's `childRef` references, in record order.
  final List<int> refs;

  /// Every object the object refers to: [refs], plus a `dcoRef` where the shape has one.
  Iterable<int> get memberOids => refs;

  /// The caption record, else the `shortText` attribute; a node without one takes its first
  /// child label.
  @override
  HeapCaption? caption;

  String? get label => caption?.text;
}

/// The diagram's root object.
final class BdRoot extends BdObject {
  BdRoot({required super.oid, super.kind, super.offset, super.end, super.refs}) : super(BdObjectClass.root);
}

/// One sub-diagram frame of a multi-frame structure; the frame has no bounds of its own.
final class BdFrame extends BdObject {
  BdFrame({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    super.caption,
    this.bgRgb,
    this.fgRgb,
    this.contentRgb,
  }) : super(BdObjectClass.frame);

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;
}

/// A signal: the data path a wire draws, from its first endpoint to the others.
final class BdSignal extends BdObject {
  BdSignal({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.caption,
    required List<int> endpoints,
    this.wireTableRaw,
    this.lastSignalKind,
  }) : super(BdObjectClass.signal, refs: endpoints);

  /// The endpoint objects, source first: the `childRef` targets.
  List<int> get endpoints => refs;

  /// The `compressedWireTable` attribute's bytes, the encoded route.
  final Uint8List? wireTableRaw;

  /// The `lastSignalKind` word, the wire's type encoding.
  final int? lastSignalKind;
}

/// A terminal holder: the object a wire ends on inside a node, which may name the node's data
/// object through `dcoRef` and then takes that object's type in the data-space join.
final class BdTerminalHolder extends BdObject implements HeapTypeBearer {
  BdTerminalHolder({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    super.caption,
    this.dcoRef,
    this.typeKind = ViTypeKind.unknown,
  }) : super(BdObjectClass.terminalHolder);

  final int? dcoRef;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;

  @override
  Iterable<int> get memberOids => dcoRef == null ? refs : [...refs, dcoRef!];
}

/// A node's terminal: placed by its `termBounds` relative to the nearest placed ancestor,
/// typed, drawn with the glyph [termBmp] names.
class BdTerminal extends BdObject implements HeapTyped {
  BdTerminal(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required this.termBounds,
    required this.typeDescIdx,
    this.termBmp,
    super.caption,
    this.typeKind = ViTypeKind.unknown,
  });

  final HeapRect termBounds;

  @override
  final int typeDescIdx;

  final int? termBmp;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;
}

/// A Formula Node or MATLAB script node terminal: a terminal captioned with its variable name,
/// drawn in a font on a coloured box.
final class BdScriptTerminal extends BdTerminal implements HeapFontRuns {
  BdScriptTerminal(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.termBounds,
    required super.typeDescIdx,
    super.termBmp,
    super.caption,
    super.typeKind,
    this.fontRuns = const [],
    this.bgRgb,
    this.fgRgb,
    this.contentRgb,
  });

  @override
  final List<HeapFontRun> fontRuns;

  @override
  ViFontEntry? font;

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;
}

/// A tunnel's auto-index marker.
final class BdTunnelIndexer extends BdObject implements HeapTyped {
  BdTunnelIndexer({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    super.caption,
    required this.typeDescIdx,
    this.typeKind = ViTypeKind.unknown,
  }) : super(BdObjectClass.tunnelIndexer);

  @override
  final int typeDescIdx;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;
}

/// A constant: typed, holding its value as the flat bytes of its `constValue` attribute, drawn
/// by the control body it owns.
final class BdConstant extends BdObject implements HeapTyped {
  BdConstant({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.refs,
    super.caption,
    super.helpText,
    required this.typeDescIdx,
    this.raw,
    this.scalar = false,
    this.text,
    this.typeKind = ViTypeKind.unknown,
  }) : super(BdObjectClass.constant);

  @override
  final int typeDescIdx;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;

  /// The flat bytes of the `constValue` attribute.
  final Uint8List? raw;

  /// Whether [raw] came from a scalar attribute width rather than a container blob.
  final bool scalar;

  /// The value as text, when the attribute decodes to a string or [decodeBdConstValues] reads one.
  String? text;

  /// The value as a number, when [decodeBdConstValues] reads one.
  num? numeric;

  /// The value as a boolean, when [decodeBdConstValues] reads one.
  bool? boolValue;

  /// The elements of a numeric array constant, row-major.
  List<num>? array;

  /// The elements of a string array constant, row-major.
  List<String>? textArray;

  /// The dimension sizes of an array constant.
  List<int>? arrayDims;
}

/// An object with no bounds record and no shape of its own: connector terminals, property items
/// and the parts of nodes, or a class that wants bounds but was saved without them.
final class BdUnplaced extends BdObject {
  BdUnplaced(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    super.caption,
  });
}

/// An object with a bounds record.
sealed class BdPlaced extends BdObject implements HeapPlaced {
  BdPlaced(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required this.bounds,
    this.boundsOffset = 0,
    HeapRect? absBounds,
    super.caption,
    this.termCount = 0,
  }) : absBounds = absBounds ?? bounds;

  @override
  HeapRect bounds;

  @override
  int boundsOffset;

  @override
  HeapRect absBounds;

  /// The number of size records the object carries; one or more makes it a terminal cluster.
  final int termCount;

  @override
  BdObjectKind get category => termCount >= 1 ? BdObjectKind.terminalCluster : objectClass.category;
}

/// A primitive, sub-VI call or other executable node.
class BdNode extends BdPlaced implements HeapCaptioned {
  BdNode(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    this.typeKind = ViTypeKind.unknown,
  });

  /// The data kind the node's own records imply: a symbol name on a Call Library node, a path
  /// record on a path node.
  final ViTypeKind typeKind;

  @override
  BdObjectKind get category => termCount >= 1 ? BdObjectKind.terminalCluster : BdObjectKind.node;
}

/// A primitive node, drawn by the icon its `primResID` names.
final class BdPrimitive extends BdNode {
  BdPrimitive({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    super.typeKind,
    required this.primResId,
  }) : super(BdObjectClass.primitive);

  final int primResId;

  /// The catalogued name of the primitive, when [PrimOp] knows it.
  String? get primName => PrimOp.fromId(primResId)?.opName;
}

/// A Call Library Function Node: the library and symbol it calls.
final class BdForeignCall extends BdNode {
  BdForeignCall({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    super.typeKind,
    this.libraryPath,
    this.entryPoint,
  }) : super(BdObjectClass.callLibrary);

  /// The path record's text.
  final String? libraryPath;

  /// The symbol name record's text.
  final String? entryPoint;
}

/// A Formula Node or MATLAB script node: a node whose caption is its script, drawn in a font
/// on a coloured box.
final class BdScriptNode extends BdNode implements HeapFontRuns {
  BdScriptNode(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    super.typeKind,
    this.fontRuns = const [],
    this.bgRgb,
    this.fgRgb,
    this.contentRgb,
  });

  @override
  final List<HeapFontRun> fontRuns;

  @override
  ViFontEntry? font;

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;
}

/// A loop, sequence frame, In Place Element or other structure that owns a sub-diagram.
class BdStructure extends BdPlaced {
  BdStructure(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    this.structRgb,
    this.bgRgb,
    this.fgRgb,
    this.contentRgb,
  });

  /// The `structColor` attribute as `0xRRGGBB`; null when absent or transparent.
  final int? structRgb;

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;
}

/// A structure that holds one frame per case, event or sequence step and shows one at a time.
class BdMultiFrameStructure extends BdStructure {
  BdMultiFrameStructure(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    super.structRgb,
    super.bgRgb,
    super.fgRgb,
    super.contentRgb,
    this.dIdx,
  });

  /// The `dIdx` attribute: the index of the frame shown; absent means the first.
  final int? dIdx;

  /// The frame shown: [dIdx] without its bit 31, which is a flag.
  int get visibleFrameIndex => (dIdx ?? 0) & 0x7fffffff;
}

/// A case structure: its selector ranges and strings and its default frame.
final class BdCaseStructure extends BdMultiFrameStructure {
  BdCaseStructure({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    super.structRgb,
    super.bgRgb,
    super.fgRgb,
    super.contentRgb,
    super.dIdx,
    this.selectorRanges = const [],
    this.selectorStrings = const [],
    this.defaultFrameIndex,
  }) : super(BdObjectClass.caseStructure);

  /// The selector range list: which values select which frame.
  final List<ViSelectorRange> selectorRanges;

  /// The selector string pool, for a string or enum selector.
  final List<String> selectorStrings;

  /// The `selectDefaultCase` attribute: the default frame's index, null without one.
  final int? defaultFrameIndex;
}

/// A cluster, array or type definition shell: a typed container of control bodies, drawn
/// around a constant's or a terminal's elements.
final class BdContainer extends BdPlaced implements HeapTyped {
  BdContainer(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    required this.typeDescIdx,
    this.arrayIndex,
    this.typeKind = ViTypeKind.unknown,
  });

  @override
  final int typeDescIdx;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;

  /// The displayed element index of an array shell, from its array index group.
  final int? arrayIndex;
}

/// A pane: the scrolled viewport the diagram's objects are placed in.
final class BdPane extends BdPlaced implements HeapPane {
  BdPane({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
  }) : super(BdObjectClass.pane);
}

/// A wire's drawn segments; the signal it draws is its `signal` sibling.
final class BdWire extends BdPlaced {
  BdWire({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
  }) : super(BdObjectClass.wire);
}

/// A front-panel terminal on the diagram: it names its panel data object through `dcoRef` and
/// takes that object's type and direction in the data-space join.
final class BdPanelTerminal extends BdPlaced implements HeapTypeBearer {
  BdPanelTerminal({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    required this.dcoRef,
    this.isIndicator,
    this.typeKind = ViTypeKind.unknown,
  }) : super(BdObjectClass.panelTerminal);

  final int dcoRef;

  /// Whether the panel control is an indicator; null until the join runs or when the control
  /// was not found.
  bool? isIndicator;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;

  @override
  Iterable<int> get memberOids => [...refs, dcoRef];
}

/// A typed control body on the diagram: the face of a constant or terminal, carrying its value.
final class BdControlBody extends BdPlaced implements HeapControlBody {
  BdControlBody(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    required this.typeDescIdx,
    this.items = const [],
    this.typeKind = ViTypeKind.unknown,
    this.bgRgb,
    this.fgRgb,
    this.contentRgb,
  });

  @override
  final int typeDescIdx;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;

  /// Enum or ring item names, from the body's own string table or its item list part.
  @override
  List<String> items;

  @override
  bool get isValueControl => objectClass.isControlTerminal;

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;
}

/// A text label: a node's or a control's name, or a case structure's selector label.
final class BdText extends BdPlaced implements HeapTextLabel {
  BdText(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    this.fontRuns = const [],
    this.modeWord = 0,
    this.bgRgb,
    this.fgRgb,
    this.contentRgb,
  });

  @override
  final List<HeapFontRun> fontRuns;

  @override
  ViFontEntry? font;

  @override
  final int modeWord;

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;

  /// Whether a text label is hidden; the bit is not decoded on a case selector label.
  @override
  bool get isHidden => objectClass == BdObjectClass.textLabel && hasFlag(ViObjFlag.labelHidden);

  @override
  bool get isBold => font?.isBold ?? false;

  @override
  bool get justifyCenter => modeWord & 0x20 != 0;

  /// The inset between the label's box and its text, in pixels.
  int get textInset => modeWord & 0x800000 != 0 ? 2 : 1;
}

/// A placed part of a node or control: chrome, a control part, a glyph.
class BdPart extends BdPlaced {
  BdPart(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    this.bgRgb,
    this.fgRgb,
    this.contentRgb,
    this.typeKind = ViTypeKind.unknown,
  });

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;

  /// The data kind the part's own records imply: a format string on a numeric display, an item
  /// table on an item list.
  final ViTypeKind typeKind;
}

/// A numeric display part: the digits of a numeric control body, formatted by [displayFormat].
final class BdNumericDisplay extends BdPart implements HeapFontRuns {
  BdNumericDisplay({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    super.bgRgb,
    super.fgRgb,
    super.contentRgb,
    super.typeKind,
    this.displayFormat,
    this.fontRuns = const [],
  }) : super(BdObjectClass.numericDisplay);

  /// The `formatStyle` attribute, a `%` format string.
  final String? displayFormat;

  @override
  final List<HeapFontRun> fontRuns;

  @override
  ViFontEntry? font;
}

/// An enum, ring or boolean item list part.
final class BdItemList extends BdPart implements HeapItems, HeapFontRuns {
  BdItemList({
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
    super.bgRgb,
    super.fgRgb,
    super.contentRgb,
    super.typeKind,
    this.items = const [],
    this.fontRuns = const [],
  }) : super(BdObjectClass.itemList);

  @override
  final List<String> items;

  @override
  final List<HeapFontRun> fontRuns;

  @override
  ViFontEntry? font;
}

/// A placed object of a class whose role is not established.
final class BdUnknownPlaced extends BdPlaced {
  BdUnknownPlaced(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.objFlags,
    super.helpText,
    super.refs,
    required super.bounds,
    super.boundsOffset,
    super.absBounds,
    super.caption,
    super.termCount,
  });
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

  bool get isUnknown => this == unknown;

  /// Whether the class is one of the typed control bodies that carry a value.
  bool get isControlTerminal => _controlTerminal[index];

  /// Whether the class holds one frame per case, event or sequence step and shows one at a time.
  bool get isMultiFrameStructure =>
      this == caseStructure || this == disableStructure || this == eventStructure || this == stackedSequence;

  /// Whether a signal's endpoint reference can target the class: a terminal holder inside a node
  /// or a front-panel terminal.
  bool get isSignalEndpoint => this == terminalHolder || this == panelTerminal;
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
