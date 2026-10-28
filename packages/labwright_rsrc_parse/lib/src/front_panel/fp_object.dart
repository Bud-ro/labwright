/// The objects of a front panel: [FpObject] with the fields [buildFrontPanel] fills from the
/// heap records, [FpObjectClass] naming the object classes, [FpObjectKind] the roles and the
/// per-class payloads ([FpPayload]).
library;

import 'dart:typed_data';

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

/// What an object's class adds to the shared fields; [FpPayload.forClass] picks the payload a
/// class carries.
sealed class FpPayload {
  FpPayload();

  /// The payload objects of [objectClass] carry, or null for a class with none.
  static FpPayload? forClass(FpObjectClass objectClass) => switch (objectClass) {
    FpObjectClass.dco => FpDataObject(),
    FpObjectClass.numeric || FpObjectClass.enumRing => FpNumericRange(),
    FpObjectClass.graph => FpGraph(),
    _ => null,
  };
}

/// A control's data object: where it sits on the connector pane.
final class FpDataObject extends FpPayload {
  /// The `conNum` attribute: the control's connector-pane terminal, [kViNotOnPane] off the
  /// pane; a control saved without it sits on terminal 0.
  int? conNum;

  /// The `defaultData` attribute: the control's default value flattened by its type, as a
  /// diagram constant's `constValue` holds a constant's.
  Uint8List? defaultData;

  /// Whether [defaultData] came from a scalar attribute width rather than a counted blob.
  bool defaultIsScalar = false;
}

/// A numeric control's range.
final class FpNumericRange extends FpPayload {
  /// The `stdNumMin` attribute.
  double? min;

  /// The `stdNumMax` attribute.
  double? max;
}

/// A graph or chart: its plots.
final class FpGraph extends FpPayload {
  /// One name per plot-name record.
  List<String> plotNames = const [];

  /// The `plotColor` attributes as `0xRRGGBB`, one per plot.
  List<int> plotColors = const [];
}

/// Which terminal of the connector pane each panel control is wired to, read from its `conNum`
/// attribute: a control saved without the attribute sits on terminal 0, and this word marks one
/// that is not on the pane at all.
const int kViNotOnPane = 0xff;

/// One object of a front-panel heap.
class FpObject extends HeapObject {
  FpObject({required super.oid, required super.kind, required super.offset})
    : objectClass = FpObjectClass.fromCode(kind);

  final FpObjectClass objectClass;

  /// The class's role; any object with a size record is a terminal cluster.
  FpObjectKind get category => termCount >= 1 ? FpObjectKind.terminalCluster : objectClass.category;

  /// The class's payload, see [FpPayload.forClass].
  late final FpPayload? payload = FpPayload.forClass(objectClass);

  T? _as<T extends FpPayload>() {
    final payload = this.payload;
    return payload is T ? payload : null;
  }

  FpDataObject? get dataObject => _as();

  FpNumericRange? get numericRange => _as();

  FpGraph? get graph => _as();

  /// Whether a typed data object is an indicator, from its [ViObjFlag.indicator] bit; null for
  /// any other object.
  bool? get isIndicator => dataObject == null || typeDescIdx == null ? null : hasFlag(ViObjFlag.indicator);

  /// The `borderColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? borderRgb;

  @override
  bool get isTextLabel => objectClass == FpObjectClass.textLabel;

  @override
  bool get isControlTerminal => objectClass.isControlTerminal;

  @override
  bool get isPane => objectClass == FpObjectClass.pane;
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
