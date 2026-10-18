/// The objects of a front panel, one shape per record layout: [FpObject] is the sealed root,
/// [FpPlaced] the objects with a bounds record, and the leaves ([FpControl], [FpContainer],
/// [FpDataObject], [FpText], …) carry exactly the fields their records give them.
/// [FpObjectClass] names the object classes and [FpObjectKind] the roles.
library;

import '../blocks/FTAB_font_table.dart';
import '../heap/heap.dart';
import '../heap/heap_object.dart';
import '../heap/obj_flags.dart';
import '../heap/object_class.dart';

/// The role of a front-panel object.
enum FpObjectKind {
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
  unknown,
}

/// Which terminal of the connector pane each panel control is wired to, read from its `conNum`
/// attribute: a control saved without the attribute sits on terminal 0, and this word marks one
/// that is not on the pane at all.
const int kViNotOnPane = 0xff;

/// One object of a front-panel heap. The shape says what records the object has; the class
/// says what LabVIEW object it is.
sealed class FpObject extends HeapObject implements HeapCaptioned {
  FpObject(
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

  final FpObjectClass objectClass;

  /// The role the class gives the object; a terminal cluster overrides it.
  FpObjectKind get category => objectClass.category;

  /// Targets of the object's `childRef` references, in record order.
  final List<int> refs;

  /// The caption record, else the `shortText` attribute.
  @override
  HeapCaption? caption;

  String? get label => caption?.text;
}

/// The panel's root object, or a per-panel record object.
final class FpRecord extends FpObject {
  FpRecord(
    super.objectClass, {
    required super.oid,
    super.kind,
    super.offset,
    super.end,
    super.parentOid,
    super.refs,
    super.caption,
  });
}

/// A control's data object: typed, placed on the connector pane by `conNum`, and an indicator
/// when its flags say so; the control body it owns is a child.
final class FpDataObject extends FpObject implements HeapTyped {
  FpDataObject({
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
    this.conNum,
    this.typeKind = ViTypeKind.unknown,
  }) : super(FpObjectClass.dco);

  @override
  final int typeDescIdx;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;

  /// The `conNum` attribute: the control's connector-pane terminal, [kViNotOnPane] off the
  /// pane; a control saved without it sits on terminal 0.
  final int? conNum;

  /// Whether the control is an indicator, from its [ViObjFlag.indicator] bit.
  bool get isIndicator => hasFlag(ViObjFlag.indicator);
}

/// An object with no bounds record and no shape of its own: a connector terminal, a tip strip,
/// or a class that wants bounds but was saved without them.
final class FpUnplaced extends FpObject {
  FpUnplaced(
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
sealed class FpPlaced extends FpObject implements HeapPlaced {
  FpPlaced(
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
  FpObjectKind get category => termCount >= 1 ? FpObjectKind.terminalCluster : objectClass.category;
}

/// The panel's root frame.
final class FpPanelRoot extends FpPlaced {
  FpPanelRoot({
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
  }) : super(FpObjectClass.panelRoot);
}

/// A pane, or the splitter between panes.
final class FpPane extends FpPlaced implements HeapPane {
  FpPane(
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

/// A control or indicator body: typed, with the items of an enum, ring or boolean.
class FpControl extends FpPlaced implements HeapControlBody {
  FpControl(
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
    required this.typeDescIdx,
    this.items = const [],
    this.typeKind = ViTypeKind.unknown,
    this.bgRgb,
    this.fgRgb,
    this.contentRgb,
    this.borderRgb,
    super.caption,
    super.termCount,
  });

  @override
  final int typeDescIdx;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;

  @override
  List<String> items;

  @override
  bool get isValueControl => objectClass.isControlTerminal;

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;

  /// The `borderColor` attribute as `0xRRGGBB`; null when absent or transparent.
  final int? borderRgb;
}

/// A numeric or enum/ring control body with its range.
final class FpNumericControl extends FpControl {
  FpNumericControl(
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
    required super.typeDescIdx,
    super.items,
    super.typeKind,
    super.bgRgb,
    super.fgRgb,
    super.contentRgb,
    super.borderRgb,
    super.caption,
    super.termCount,
    this.min,
    this.max,
  });

  /// The `stdNumMin` attribute.
  final double? min;

  /// The `stdNumMax` attribute.
  final double? max;
}

/// A graph or chart body: its plots.
final class FpGraph extends FpControl {
  FpGraph({
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
    required super.typeDescIdx,
    super.items,
    super.typeKind,
    super.bgRgb,
    super.fgRgb,
    super.contentRgb,
    super.borderRgb,
    super.caption,
    super.termCount,
    this.plotNames = const [],
    this.plotColors = const [],
  }) : super(FpObjectClass.graph);

  /// One name per plot-name record.
  final List<String> plotNames;

  /// The `plotColor` attributes as `0xRRGGBB`, one per plot.
  final List<int> plotColors;
}

/// A typed container of controls: a cluster, array, type definition, tab control or radio group.
final class FpContainer extends FpPlaced implements HeapTyped {
  FpContainer(
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
    this.typeKind = ViTypeKind.unknown,
  });

  @override
  final int typeDescIdx;

  @override
  ViResolvedType? resolvedType;

  @override
  ViTypeKind typeKind;
}

/// A text label.
final class FpText extends FpPlaced implements HeapTextLabel {
  FpText({
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
  }) : super(FpObjectClass.textLabel);

  @override
  final List<HeapFontRun> fontRuns;

  @override
  ViFontEntry? font;

  @override
  final int modeWord;

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;

  @override
  bool get isHidden => hasFlag(ViObjFlag.labelHidden);

  @override
  bool get isBold => font?.isBold ?? false;

  @override
  bool get justifyCenter => modeWord & 0x20 != 0;
}

/// A placed part of a control: chrome, a scale, a legend, a display.
class FpPart extends FpPlaced implements HeapItems, HeapFontRuns {
  FpPart(
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
    this.bgRgb,
    this.fgRgb,
    this.contentRgb,
    this.borderRgb,
    this.displayFormat,
    this.items = const [],
    super.caption,
    super.termCount,
    this.fontRuns = const [],
    ViTypeKind typeKind = ViTypeKind.unknown,
  }) : _typeKind = typeKind;

  final int? bgRgb;
  final int? fgRgb;
  final int? contentRgb;
  final int? borderRgb;

  ViTypeKind _typeKind;

  /// The data kind the part's own records imply: a format string on a display, an item table
  /// on an item list.
  ViTypeKind get typeKind => _typeKind;

  /// The `formatStyle` attribute of a numeric display or scale, a `%` format string.
  final String? displayFormat;

  /// The item names of an item list part.
  @override
  final List<String> items;

  @override
  final List<HeapFontRun> fontRuns;

  @override
  ViFontEntry? font;
}

/// A typed part of a control: a graph legend.
final class FpTypedPart extends FpPart implements HeapTyped {
  FpTypedPart(
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
    super.bgRgb,
    super.fgRgb,
    super.contentRgb,
    super.borderRgb,
    super.displayFormat,
    super.items,
    super.fontRuns,
    required this.typeDescIdx,
    super.typeKind,
  });

  @override
  final int typeDescIdx;

  @override
  ViResolvedType? resolvedType;

  @override
  set typeKind(ViTypeKind value) => _typeKind = value;
}

/// A placed object of a class whose role is not established.
final class FpUnknownPlaced extends FpPlaced {
  FpUnknownPlaced(
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

/// The classes of front-panel heap objects, by code.
enum FpObjectClass {
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

  const FpObjectClass(this.code, this.label, this.category, this.confidence);

  final int code;
  final String label;
  final FpObjectKind category;
  final ClassConfidence confidence;

  static final List<FpObjectClass> _byCode = classCodeTable(values, unknown, (c) => c.code);

  /// The class with [code], or [unknown].
  static FpObjectClass fromCode(int code) => code >= 0 && code < _byCode.length ? _byCode[code] : unknown;

  bool get isUnknown => this == unknown;

  /// Whether the class is one of the typed controls that carry a value.
  bool get isControlTerminal => switch (this) {
    numeric || boolean || enumRing || path || string => true,
    _ => false,
  };
}

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
