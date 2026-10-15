import 'dart:typed_data';

import '../block_tag.dart';
import '../blocks/VCTP_type_pool.dart';
import '../diagram/diagram.dart';
import '../diagram/obj_flags.dart';
import '../diagram/objects.dart';
import '../diagram/prim_ops.dart';
import '../diagram/prim_terminals.dart';
import '../diagram/wire_route.dart';
import '../heap/heap.dart';
import '../heap/heap_tree.dart';
import '../section_buffer.dart';
import 'empty_vi.dart';
import 'front_panel.dart';
import 'layout.dart';
import 'records.dart';

part 'model_editing.dart';

/// The lists a diagram frame's records open: its placed objects, its node order with the
/// endpoint table first, and its signals; [rawId] is the ten-bit group id, [tag] its low byte.
enum BdFrameList {
  objects(0x14e),
  nodes(0x0c3),
  signals(0x108);

  const BdFrameList(this.rawId);

  final int rawId;

  int get tag => rawId & 0xff;
}

/// The lists a structure's records open besides its terminal list and frames.
enum BdStructureList {
  tunnels(0x137),
  frames(0x05e),
  rightShiftRegisters(0x112),
  list282(0x282),
  list52(0x052),
  caseFrameEntries(0x256),
  caseStrings(0x258),
  disableFrameEntries(0x228),
  sequenceFrames(0x105);

  const BdStructureList(this.rawId);

  final int rawId;
}

/// Which way a tunnel carries its value through a structure's border.
enum BdTunnelDirection { input, output }

/// A data type a wire carries, a constant holds or a control shows: a scalar, or an array of
/// one over [dims] dimensions.
class BdType {
  const BdType.scalar(this.element) : dims = 0, flavor = null;

  /// An array over [dims] dimensions; none makes the scalar itself.
  const BdType.array(this.element, {this.dims = 1, this.flavor}) : assert(dims >= 0);

  const BdType._measure(this.flavor) : element = ViDataType.measureData, dims = 0;

  final ViDataType element;

  final int dims;

  /// The shape of a measurement-data element.
  final ViMeasureDataFlavor? flavor;

  static const timestamp = BdType._measure(ViMeasureDataFlavor.timeStamp);

  static const i8 = BdType.scalar(ViDataType.i8);

  static const i16 = BdType.scalar(ViDataType.i16);

  static const i32 = BdType.scalar(ViDataType.i32);

  static const i64 = BdType.scalar(ViDataType.i64);

  static const u8 = BdType.scalar(ViDataType.u8);

  static const u16 = BdType.scalar(ViDataType.u16);

  static const u32 = BdType.scalar(ViDataType.u32);

  static const u64 = BdType.scalar(ViDataType.u64);

  static const sgl = BdType.scalar(ViDataType.sgl);

  static const dbl = BdType.scalar(ViDataType.dbl);

  static const boolean = BdType.scalar(ViDataType.boolean);

  static const string = BdType.scalar(ViDataType.string);

  /// The array of this type: one dimension more.
  BdType get array => BdType.array(element, dims: dims + 1, flavor: flavor);

  /// The descriptor code of [element].
  int get code => typeCodeOfDataType(element) ?? (throw ArgumentError.value(element, 'element', 'has no single code'));

  /// The signal's type word: the depth above the code, one for a number or boolean, two for
  /// a string, three for measurement data, plus one per array dimension.
  int get signalWord => ((_scalarDepth + dims) << 8) | code;

  int get _scalarDepth => switch (element) {
    ViDataType.string || ViDataType.path => 2,
    ViDataType.measureData => 3,
    _ => 1,
  };

  /// Bytes of one flattened scalar.
  int get scalarSize => switch (element) {
    ViDataType.boolean || ViDataType.i8 || ViDataType.u8 => 1,
    ViDataType.i16 || ViDataType.u16 => 2,
    ViDataType.i32 || ViDataType.u32 || ViDataType.sgl => 4,
    ViDataType.i64 || ViDataType.u64 || ViDataType.dbl => 8,
    _ => throw ArgumentError.value(element, 'element', 'is not flattened as a fixed-size scalar'),
  };

  /// Appends the type to [model]'s pool, labelled [label], and returns its pool index.
  int addTo(ViEditing model, {String? label}) {
    final scalarLabel = dims == 0 ? label : null;
    final scalar = switch (element) {
      ViDataType.boolean => ViBooleanType.encode(label: scalarLabel),
      ViDataType.string => ViStringType.encode(label: scalarLabel),
      ViDataType.measureData => ViMeasureDataType.encode(flavor!, label: scalarLabel),
      _ => ViNumericType.encode(code, label: scalarLabel),
    };
    final index = model.addType(scalar);
    if (dims == 0) return index;
    return model.addType(ViArrayType.encode(index, dimSizes: List.filled(dims, kViUnboundedLength), label: label));
  }

  @override
  bool operator ==(Object other) =>
      other is BdType && other.element == element && other.dims == dims && other.flavor == flavor;

  @override
  int get hashCode => Object.hash(element, dims, flavor);

  @override
  String toString() => dims == 0 ? (flavor?.name ?? element.name) : '${element.name}[${',' * (dims - 1)}]';
}

/// A frame: the diagram itself or one frame of a structure, holding placed objects, its
/// node order and its signals. Objects placed without bounds are laid out by their wires
/// when the diagram is written: [padding] in from the frame's edge, columns [gap] apart,
/// rows [rowGap] apart.
class BdFrame {
  BdFrame._lifted(this.owner, this.node, {ViEditing? model}) : _model = model;

  /// The root frame of the diagram heap [tree] holds.
  BdFrame._root(ViEditing model, List<HeapNode> tree)
    : this._lifted(
        null,
        tree.objects
            .firstWhere((o) => o.kind == HeapObjectClass.diagramRoot.code)
            .children
            .objects
            .firstWhere((o) => o.kind == HeapObjectClass.bdFrame.code),
        model: model,
      );

  /// A frame of a structure not yet placed: its records exist once the structure's do.
  BdFrame._pending(this.owner) : _model = null;

  /// The structure this frame belongs to, null for the diagram's root frame.
  final BdStructure? owner;

  late final HeapObjectNode node;

  bool get _built => owner == null || owner!.isPlaced;

  final ViEditing? _model;

  ViEditing get model => _model ?? owner!.frameOf.model;

  int get oid => node.oid;

  /// The frames from the root down to this one.
  List<BdFrame> get ancestry => [...?owner?.frameOf.ancestry, this];

  BdInsets? _padding;

  /// Space between the frame's edge and its contents: its structure's padding, or the
  /// diagram's own.
  BdInsets get padding => _padding ?? owner?.padding ?? const BdInsets.all(kBdFramePadding);

  set padding(BdInsets value) => _padding = value;

  int gap = kBdColumnGap;

  int rowGap = kBdRowGap;

  final List<BdPlaced> _pending = [];

  HeapGroupNode? _list(BdFrameList list) => node.children.group(list.tag);

  /// The list, opened when the frame had none: after the lists before it in record order.
  HeapGroupNode _ensureList(BdFrameList list) {
    final existing = _list(list);
    if (existing != null) return existing;
    final group = HeapGroupNode.counted(list.rawId);
    var at = node.children.length;
    for (final later in BdFrameList.values.skip(list.index + 1)) {
      final next = _list(later);
      if (next != null) {
        at = node.children.indexOf(next);
        break;
      }
    }
    node.children.insert(at, group);
    return group;
  }

  /// The endpoint table: the frame's wire object, whose terminal list declares the panel
  /// terminals, the constants and the structure-terminal endpoints signals reach; null for a
  /// frame saved without one.
  HeapObjectNode? get endpointTable =>
      _list(BdFrameList.nodes)?.children.objects.where((o) => o.kind == HeapObjectClass.bdWire.code).firstOrNull;

  HeapObjectNode _ensureEndpointTable() {
    final existing = endpointTable;
    if (existing != null) return existing;
    final table = object(
      HeapObjectClass.bdWire.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1000),
        list(kBdTermList),
        c4Rect(HeapOpcode.bounds, kZeroRect),
        attr(HeapAttribute.shortCount, HeapAttrWidth.u8, 1),
      ],
    );
    final nodes = _ensureList(BdFrameList.nodes);
    nodes.children.insert(0, table);
    nodes.syncCount();
    return table;
  }

  HeapGroupNode? get _endpointList => endpointTable?.children.group(HeapGroupTag.termList.tag);

  /// Everything placed in the frame, in record order.
  late final List<BdPlaced> placed = _lift();

  List<BdPlaced> _lift() {
    final out = <BdPlaced>[];
    for (final item in _endpointList?.children.objects ?? const <HeapObjectNode>[]) {
      if (item.kind == HeapObjectClass.bdLeaf.code) {
        out.add(BdPanelTerminal._lifted(this, item));
      } else if (item.children.objects.any((o) => o.kind == HeapObjectClass.bdConstDco.code)) {
        out.add(BdConstant._lifted(this, item));
      }
    }
    for (final object in _list(BdFrameList.objects)?.children.objects ?? const <HeapObjectNode>[]) {
      final objectClass = HeapObjectClass.fromCode(object.kind);
      out.add(switch (objectClass) {
        HeapObjectClass.bdNode || HeapObjectClass.bdNodeBd => BdPrimitive._lifted(this, object),
        HeapObjectClass.bdNode44 => BdIndexArray._lifted(this, object),
        HeapObjectClass.bdNodeB9 => BdReplaceArraySubset._lifted(this, object),
        HeapObjectClass.bdForLoop || HeapObjectClass.bdWhileLoop => BdLoop._lifted(this, object),
        HeapObjectClass.bdStructureFrame => BdCase._lifted(this, object),
        HeapObjectClass.bdDisableStructure => BdDisable._lifted(this, object),
        HeapObjectClass.bdFlatSequence => BdSequence._lifted(this, object),
        _ when objectClass.category == ViObjectKind.structure => BdStructure._lifted(this, object),
        _ when objectClass.category == ViObjectKind.node => BdNode._lifted(this, object),
        HeapObjectClass.controlLabel => BdText._lifted(this, object),
        _ => BdPlaced._lifted(this, object),
      });
    }
    return out;
  }

  /// The signals wired in this frame, in record order.
  late final List<BdWire> wires = [
    for (final signal in _list(BdFrameList.signals)?.children.objects ?? const <HeapObjectNode>[])
      if (signal.kind == HeapObjectClass.signal.code) BdWire._(this, signal),
  ];

  Iterable<T> all<T extends BdPlaced>() => placed.whereType<T>();

  /// The endpoint-table entry with [oid], or null.
  HeapObjectNode? _entry(int oid) => _endpointList?.children.objects.where((o) => o.oid == oid).firstOrNull;

  void _addEntry(HeapObjectNode entry) {
    final entries = _ensureEndpointTable().children.group(HeapGroupTag.termList.tag)!;
    entries.children.add(entry);
    entries.syncCount();
  }

  void _addObjectRef(int oid) {
    final objects = _ensureList(BdFrameList.objects);
    objects.children.add(ref(HeapRefKind.childRef, oid));
    objects.syncCount();
  }

  /// A free label reading [text], laid out above the frame's contents.
  BdText comment(String text) => add(BdText(text));

  /// Places [item] in this frame: a node or structure joins the object list and the node
  /// order, a constant or panel terminal the endpoint table, text the object list; one
  /// without bounds is laid out when the diagram is written. In a frame of a structure not
  /// yet placed, [item] waits until the structure is.
  T add<T extends BdPlaced>(T item) {
    if (item._frameOf != null) throw StateError('$item is already placed');
    item._frameOf = this;
    if (_built) {
      _place(item);
    } else {
      _pending.add(item);
    }
    return item;
  }

  void _place(BdPlaced item) {
    item._build(model);
    final placed = this.placed;
    if (item is BdNode) {
      final objects = _ensureList(BdFrameList.objects);
      objects.children.add(item.node);
      objects.syncCount();
      _ensureEndpointTable();
      final nodes = _ensureList(BdFrameList.nodes);
      nodes.children.add(ref(HeapRefKind.childRef, item.oid));
      nodes.syncCount();
      placed.add(item);
    } else if (item is BdText) {
      final objects = _ensureList(BdFrameList.objects);
      objects.children.add(item.node);
      objects.syncCount();
      placed.add(item);
    } else {
      _addEntry(item.node);
      _addObjectRef(item.oid);
      final at = placed.indexWhere((p) => p is BdNode);
      placed.insert(at < 0 ? placed.length : at, item);
    }
    if (item is BdStructure) {
      for (final frame in item.frames) {
        frame._flush();
      }
    }
  }

  void _flush() {
    final waiting = [..._pending];
    _pending.clear();
    waiting.forEach(_place);
  }
}

/// Anything placed in a frame: an object with an id, a class and usually bounds. A new
/// object exists on its own until a frame [BdFrame.add]s it, which gives it its records.
class BdPlaced {
  BdPlaced._lifted(BdFrame? frameOf, HeapObjectNode node) : _frameOf = frameOf, _node = node;

  BdPlaced._create({HeapRect? at}) : _at = at, _autoPlace = at == null;

  BdFrame? _frameOf;

  HeapRect? _at;

  bool _autoPlace = false;

  HeapObjectNode? _node;

  /// Whether the layout places the object, which it does unless it was created at a
  /// position or loaded from a file.
  bool get autoPlaced => _autoPlace;

  /// Space the layout keeps around the object's box.
  BdInsets margin = const BdInsets.all(kBdObjectMargin);

  /// The size of the object's label as laid out beside or above it; none by default.
  BdSize get labelSize => BdSize.zero;

  /// The frame this is placed in.
  BdFrame get frameOf => _frameOf ?? (throw StateError('$this is not placed yet'));

  /// Whether a frame holds the object and its records exist.
  bool get isPlaced => _node != null;

  /// The object's records.
  HeapObjectNode get node => _node ?? (throw StateError('$this is not placed yet; add it to a frame first'));

  void _build(ViEditing model) {
    _node ??= _make(model);
  }

  /// The object's records, with ids and type slots from [model].
  HeapObjectNode _make(ViEditing model) => throw UnsupportedError('$runtimeType cannot be created');

  int get oid => node.oid;

  HeapObjectClass get objectClass => HeapObjectClass.fromCode(node.kind);

  /// The bounds record, relative to the frame's origin; null for an object without one.
  HeapRect? get bounds => node.children.bounds;

  set bounds(HeapRect? rect) {
    if (rect == null) throw ArgumentError.notNull('rect');
    if (!node.children.setBounds(rect)) throw StateError('object $oid has no bounds record');
  }

  @override
  String toString() => _node == null ? '$runtimeType (unplaced)' : '${objectClass.name}#$oid';
}

/// Text placed on a frame by itself: a free label on the comment background.
class BdText extends BdPlaced {
  BdText._lifted(super.frameOf, super.node) : _text = null, super._lifted();

  /// A free label reading [text], at [at] or laid out by its frame.
  BdText(String text, {super.at}) : _text = text, super._create();

  final String? _text;

  @override
  HeapObjectNode _make(ViEditing model) {
    final text = _text!;
    return object(
      HeapObjectClass.controlLabel.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x170002),
        attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
        c4Rect(HeapOpcode.bounds, _at ?? bdTextBox(text)),
        worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, 0xfd95)]),
        attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, kBdCommentColor),
        worded(kPartText, kPartTextWord, [
          attr(HeapAttribute.cosmFgColor, HeapAttrWidth.u16, 0x600),
          attr(HeapAttribute.cosmColorB, HeapAttrWidth.rgb, 0x814404),
          caption(text),
          attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, kBdCommentColor),
        ]),
      ],
    );
  }

  @override
  String toString() => isPlaced ? 'text#$oid' : 'text (unplaced)';
}

/// The box a label's lines take: the longest line's width and a line per line.
HeapRect bdTextBox(String text) {
  final lines = text.split('\n');
  var longest = 0;
  for (final line in lines) {
    if (line.length > longest) longest = line.length;
  }
  return HeapRect(top: 0, left: 0, bottom: kBdLabelHeight * lines.length, right: bdLabelWidth(' ' * longest));
}

/// Where a wire can start or end: an endpoint record a signal references.
abstract mixin class BdEndpoint {
  BdFrame get frameOf;

  HeapObjectNode get node;

  int get oid => node.oid;

  int get objFlags => node.children.attr(HeapAttribute.objFlags)?.asInt ?? 0;

  /// Whether the endpoint consumes its wire.
  bool get isSink => objFlags & (kBdSinkEndpointFlag | kBdInputEndpointFlag) != 0;

  /// Where a wire meets the endpoint, in its frame.
  ViPoint get attachPoint;

  /// The type the endpoint declares, when it does.
  BdType? get type => null;

  String get name;
}

/// A node: something with endpoint holders a wire can reach.
class BdNode extends BdPlaced {
  BdNode._lifted(super.frameOf, super.node) : _labelText = null, _showLabel = true, super._lifted();

  BdNode._create({super.at, String? label, bool showLabel = true})
    : _labelText = label,
      _showLabel = showLabel,
      super._create();

  final String? _labelText;

  final bool _showLabel;

  /// The node's own label, shown above it.
  String? get label => _showLabel ? _labelText : null;

  @override
  BdSize get labelSize => label == null ? BdSize.zero : BdSize(bdLabelWidth(label!), kBdLabelHeight);

  /// The label record a created node carries, when it was given one.
  HeapObjectNode? _labelRecord(ViEditing model) {
    final text = _labelText;
    return text == null ? null : _nodeLabel(model, text, null, shown: _showLabel);
  }

  /// The node's terminals in record order, outputs first as LabVIEW lists them, named by
  /// [terminalNames] or `in0`, `out0`, … by role and order, each meeting its wire at the
  /// offset the corpus measured for the node's icon, else the middle of its box.
  late final List<BdTerminal> terminals = () {
    var ins = 0, outs = 0;
    final names = terminalNames;
    return [
      for (final (i, holder)
          in (node.children.group(HeapGroupTag.termList.tag)?.children.objects ?? const <HeapObjectNode>[]).indexed)
        if (holder.kind == kNodeEndpointDcoKind)
          BdTerminal._(
            frameOf,
            holder,
            owner: this,
            name: names != null && i < names.length ? names[i] : (_consumes(holder) ? 'in${ins++}' : 'out${outs++}'),
            type: terminalType(i),
            attach: () {
              final b = bounds ?? kZeroRect;
              final t = holder.children.objects
                  .map((o) => o.children.attr(HeapAttribute.termBounds)?.asRect)
                  .firstWhere((r) => r != null, orElse: () => kZeroRect)!;
              final key = iconKey;
              final offset = key == null ? null : bdPrimTerminalOffset(key, i, b.right - b.left, b.bottom - b.top);
              return (
                x: b.left + (offset?.dx ?? (t.left + t.right) ~/ 2),
                y: b.top + (offset?.dy ?? (t.top + t.bottom) ~/ 2),
              );
            },
          ),
    ];
  }();

  static bool _consumes(HeapObjectNode holder) =>
      (holder.children.attr(HeapAttribute.objFlags)?.asInt ?? 0) & (kBdSinkEndpointFlag | kBdInputEndpointFlag) != 0;

  List<BdTerminal> get inputs => [
    for (final t in terminals)
      if (t.isSink) t,
  ];

  List<BdTerminal> get outputs => [
    for (final t in terminals)
      if (!t.isSink) t,
  ];

  /// The terminal named [name], as [BdTerminal.name] spells it; an output before an input of
  /// the same name, which [input] and [output] tell apart.
  BdTerminal terminal(String name) => _named(terminals, name);

  /// The node's one output.
  BdTerminal get out {
    final outputs = this.outputs;
    if (outputs.length != 1) throw StateError('$this has ${outputs.length} outputs; name one');
    return outputs.single;
  }

  BdTerminal input(String name) => _named(inputs, name);

  BdTerminal output(String name) => _named(outputs, name);

  BdTerminal _named(List<BdTerminal> among, String name) => among.firstWhere(
    (t) => t.name == name,
    orElse: () => throw ArgumentError.value(name, 'name', 'no such terminal on $this'),
  );

  /// The terminals' names in record order, when the node's kind fixes them.
  List<String>? get terminalNames => null;

  /// The type the node fixes for its terminal at [index] in record order, when it does.
  BdType? terminalType(int index) => null;

  /// The key the node's icon is measured under: its `primResID`, or the negated class code
  /// of a class that is one primitive.
  int? get iconKey => null;
}

/// A primitive node.
class BdPrimitive extends BdNode {
  BdPrimitive._lifted(super.frameOf, super.node) : _op = null, super._lifted();

  /// A node of [op], 32 by 32 at [at] or laid out by its frame, its terminals as every corpus
  /// node of the primitive draws them; [label] names it, shown above it when [showLabel].
  BdPrimitive(PrimOp op, {super.at, super.label, super.showLabel}) : _op = op, super._create() {
    if (op.terminals == null) throw ArgumentError.value(op, 'op', 'has no measured terminals');
  }

  final PrimOp? _op;

  @override
  HeapObjectNode _make(ViEditing model) {
    final op = _op!;
    return object(
      HeapObjectClass.bdNode.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x10000),
        list(kBdTermList, [
          for (final terminal in op.terminals!)
            _holder(
              model,
              input: terminal.input,
              inner: object(
                kBdNodeTerminalDcoKind,
                model.allocateUid(),
                rawTag: HeapRefKind.dcoRef.raw,
                children: [
                  if (!terminal.input) attr(HeapAttribute.objFlags, HeapAttrWidth.u8, 1),
                  rectAttr(
                    HeapAttribute.termBounds,
                    HeapRect(top: terminal.top, left: terminal.left, bottom: terminal.bottom, right: terminal.right),
                  ),
                ],
              ),
            ),
        ]),
        ?_labelRecord(model),
        c4Rect(HeapOpcode.bounds, _at ?? const HeapRect(top: 0, left: 0, bottom: 32, right: 32)),
        attr(HeapAttribute.primResID, HeapAttrWidth.u16, op.id),
      ],
    );
  }

  int? get primResId => isPlaced ? node.children.attr(HeapAttribute.primResID)?.asInt : _op?.id;

  PrimOp? get op => isPlaced ? (primResId == null ? null : PrimOp.fromId(primResId!)) : _op;

  @override
  List<String>? get terminalNames => op?.terminalNames;

  @override
  int? get iconKey => primResId;

  /// A measurement scalar is a time stamp.
  @override
  BdType? terminalType(int index) {
    final terminals = op?.terminals;
    final terminal = terminals != null && index < terminals.length ? terminals[index] : null;
    final element = terminal?.type;
    if (element == null) return null;
    if (element == ViDataType.measureData) return BdType.timestamp;
    return BdType.array(element, dims: terminal!.dims);
  }

  @override
  String toString() => isPlaced ? 'prim ${op?.name ?? primResId}#$oid' : 'prim ${_op?.name} (unplaced)';
}

HeapObjectNode _holder(ViEditing model, {required bool input, required HeapObjectNode inner, int flags = 0}) => object(
  kNodeEndpointDcoKind,
  model.allocateUid(),
  children: [
    input
        ? attr(HeapAttribute.objFlags, HeapAttrWidth.u24, kBdSinkEndpointFlag | 0x1000 | flags)
        : attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1000 | flags),
    inner,
  ],
);

/// An Index Array node: one element of an array, by index.
class BdIndexArray extends BdNode {
  BdIndexArray._lifted(super.frameOf, super.node) : super._lifted();

  BdIndexArray({super.at}) : super._create();

  @override
  HeapObjectNode _make(ViEditing model) {
    final array = object(
      kBdIndexArrayTerminalKind,
      model.allocateUid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x20000),
        rectAttr(HeapAttribute.termBounds, const HeapRect(top: 0, left: 0, bottom: 18, right: 16)),
      ],
    );
    final element = object(
      kBdIndexArrayTerminalKind,
      model.allocateUid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u8, 1),
        rectAttr(HeapAttribute.termBounds, const HeapRect(top: 0, left: 16, bottom: 27, right: 32)),
        attr(HeapAttribute.termHotPoint, HeapAttrWidth.rgb, 0x90000),
      ],
    );
    final index = object(
      kBdIndexArrayTerminalKind,
      model.allocateUid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x600000),
        rectAttr(HeapAttribute.termBounds, const HeapRect(top: 18, left: 0, bottom: 26, right: 16)),
      ],
    );
    return object(
      HeapObjectClass.bdNode44.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x80000),
        list(kBdTermList, [
          _holder(model, input: true, inner: array, flags: 0x40),
          _holder(model, input: false, inner: element, flags: 0x40),
          _holder(model, input: true, inner: index, flags: 0x40),
        ]),
        c4Rect(HeapOpcode.bounds, _at ?? const HeapRect(top: 0, left: 0, bottom: 27, right: 32)),
        list(BdStructureList.list52.rawId, [ref(HeapRefKind.childRef, index.oid)]),
        ref(HeapRefKind.dcoAggRef, element.oid),
        ref(HeapRefKind.srcDCORef, array.oid),
      ],
    );
  }

  @override
  List<String> get terminalNames => const ['array', 'element', 'index'];

  @override
  int get iconKey => -HeapObjectClass.bdNode44.code;

  @override
  String toString() => isPlaced ? 'Index Array#$oid' : 'Index Array (unplaced)';
}

/// A Replace Array Subset node: an array with one element replaced, by index.
class BdReplaceArraySubset extends BdNode {
  BdReplaceArraySubset._lifted(super.frameOf, super.node) : super._lifted();

  BdReplaceArraySubset({super.at}) : super._create();

  @override
  HeapObjectNode _make(ViEditing model) {
    HeapObjectNode terminal(List<HeapNode> children) => object(
      kBdReplaceArraySubsetTerminalKind,
      model.allocateUid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: children,
    );
    final array = terminal([
      attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x20000),
      rectAttr(HeapAttribute.termBounds, const HeapRect(top: 0, left: 0, bottom: 16, right: 16)),
    ]);
    final out = terminal([
      attr(HeapAttribute.objFlags, HeapAttrWidth.u8, 1),
      rectAttr(HeapAttribute.termBounds, const HeapRect(top: 0, left: 16, bottom: 33, right: 32)),
      attr(HeapAttribute.termHotPoint, HeapAttrWidth.rgb, 0xfff80000),
    ]);
    final element = terminal([
      attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x40000),
      rectAttr(HeapAttribute.termBounds, const HeapRect(top: 25, left: 0, bottom: 33, right: 16)),
    ]);
    final index = terminal([
      attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x600000),
      rectAttr(HeapAttribute.termBounds, const HeapRect(top: 16, left: 0, bottom: 24, right: 16)),
    ]);
    return object(
      HeapObjectClass.bdNodeB9.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x40000),
        list(kBdTermList, [
          _holder(model, input: true, inner: array, flags: 0x40),
          _holder(model, input: false, inner: out, flags: 0x40),
          _holder(model, input: true, inner: element, flags: 0x40),
          _holder(model, input: true, inner: index, flags: 0x40),
        ]),
        c4Rect(HeapOpcode.bounds, _at ?? const HeapRect(top: 0, left: 0, bottom: 33, right: 32)),
        list(BdStructureList.list52.rawId, [
          ref(HeapRefKind.childRef, element.oid),
          ref(HeapRefKind.childRef, index.oid),
        ]),
        ref(HeapRefKind.dcoAggRef, out.oid),
        raw(const [0x24, 0xbb, 0x01]),
        raw(const [0x24, 0xb9, 0x01]),
        rawRef(kBdReplaceArraySubsetArrayRef, array.oid),
      ],
    );
  }

  @override
  List<String> get terminalNames => const ['array', 'output array', 'new element', 'index'];

  @override
  int get iconKey => -HeapObjectClass.bdNodeB9.code;

  @override
  String toString() => isPlaced ? 'Replace Array Subset#$oid' : 'Replace Array Subset (unplaced)';
}

/// An endpoint of a node or a structure terminal: a node terminal's holder, a border
/// terminal's holder outside its structure, or its entry inside a frame.
class BdTerminal extends BdEndpoint {
  BdTerminal._(
    this.frameOf,
    this.node, {
    required this.name,
    required this.type,
    required ViPoint Function() attach,
    this.owner,
  }) : _attach = attach;

  @override
  final BdFrame frameOf;

  /// The node this is a terminal of; null for a structure terminal's endpoint.
  final BdNode? owner;

  @override
  final HeapObjectNode node;

  @override
  final String name;

  @override
  final BdType? type;

  final ViPoint Function() _attach;

  @override
  ViPoint get attachPoint => _attach();

  @override
  String toString() => name;
}

/// The side of a structure a border terminal sits on.
enum BdBorderSide { left, right, topLeft, bottomLeft, bottomRight }

/// What a structure's border terminal is.
enum BdBorderKind {
  count(HeapObjectClass.bdCountTerminal, 'N'),
  iteration(HeapObjectClass.bdIterationTerminal, 'i'),
  conditional(HeapObjectClass.bdConditionalTerminal, 'stop'),
  loopTunnel(HeapObjectClass.bdLoopTunnel, 'tunnel'),
  leftShiftRegister(HeapObjectClass.bdLeftShiftRegister, 'left shift register'),
  rightShiftRegister(HeapObjectClass.bdRightShiftRegister, 'right shift register'),
  caseTunnel(HeapObjectClass.bdCaseTunnel, 'tunnel'),
  selector(HeapObjectClass.bdSelectorTerminal, 'selector'),
  sequenceTunnel(HeapObjectClass.bdSequenceTunnel, 'tunnel'),
  frameTunnel(HeapObjectClass.bdFrameTunnel, 'frame tunnel');

  const BdBorderKind(this.objectClass, this.label);

  final HeapObjectClass objectClass;

  final String label;

  static BdBorderKind? ofCode(int code) => values.where((k) => k.objectClass.code == code).firstOrNull;
}

/// A terminal on a structure's border: its object, the holder that is its outer endpoint,
/// and its inner endpoint in each frame. Wired as an endpoint itself, [ViEditing.connect]
/// takes the side facing the other end; [outer] and [inner] name a side.
class BdStructureTerminal with BdEndpoint {
  BdStructureTerminal._(
    this.owner,
    this.kind,
    this.terminal,
    this.holder, {
    BdType? type,
    BdType? innerType,
    BdBorderSide? side,
    int? slot,
  }) : _type = type,
       _innerType = innerType ?? type,
       _side = side,
       _slot = slot;

  final BdStructure owner;

  final BdBorderKind kind;

  final HeapObjectNode terminal;

  /// The holder in the structure's terminal list; null for a terminal drawn inside, such as
  /// a loop's iteration terminal.
  final HeapObjectNode? holder;

  final BdType? _type;

  /// The type inside: one dimension fewer than [_type] through an indexing tunnel.
  final BdType? _innerType;

  final BdBorderSide? _side;

  int? _slot;

  @override
  String get name => kind.label;

  /// The endpoint outside the structure, in the structure's frame.
  late final BdTerminal outer = holder == null
      ? throw StateError('$this has no endpoint outside its structure')
      : BdTerminal._(owner.frameOf, holder!, name: '$owner.$name', type: _type, attach: _outerAttach);

  /// The endpoint inside [frame].
  BdTerminal inner(BdFrame frame) {
    final entry = _inners[frame.oid];
    if (entry == null) throw ArgumentError.value(frame, 'frame', '$owner.$name has no endpoint in it');
    return entry;
  }

  /// The endpoint inside the structure's only frame.
  BdTerminal get innerPort {
    final inners = _inners.values;
    if (inners.length != 1) throw StateError('$this has ${inners.length} inner endpoints; name the frame');
    return inners.single;
  }

  List<BdTerminal> get inners => _inners.values.toList();

  /// The side a wire reaches when nothing says which: inside for a terminal with no outer
  /// endpoint, outside otherwise.
  BdEndpoint get _facing => holder == null ? innerPort : outer;

  @override
  BdFrame get frameOf => _facing.frameOf;

  @override
  HeapObjectNode get node => _facing.node;

  @override
  bool get isSink => _facing.isSink;

  @override
  ViPoint get attachPoint => _facing.attachPoint;

  @override
  BdType? get type => _facing.type;

  late final Map<int, BdTerminal> _inners = () {
    final out = <int, BdTerminal>{};
    final members = [
      for (final r in terminal.children.group(HeapGroupTag.termList.tag)?.children.refs ?? const <HeapRef>[])
        if (r.kind == HeapRefKind.childRef) r.targetOid,
    ];
    for (final frame in owner.frames) {
      for (final member in members) {
        final entry = frame._entry(member);
        if (entry != null) {
          out[frame.oid] = BdTerminal._(
            frame,
            entry,
            name: '$owner.$name.inner',
            type: _innerType,
            attach: _innerAttach,
          );
        }
      }
    }
    return out;
  }();

  HeapRect get termBounds => terminal.children.attr(HeapAttribute.termBounds)?.asRect ?? kZeroRect;

  /// The frame tunnel on the neighbouring frame this one passes its value to or takes it
  /// from, or the other half of a shift register.
  BdStructureTerminal? get partner {
    final owner = this.owner;
    if (owner is BdSequenceFrame) {
      final oid = terminal.children.refs.where((r) => r.kind == HeapRefKind.objectRef).firstOrNull?.targetOid;
      return owner.sequence.borderTerminals.where((t) => t.terminal.oid == oid).firstOrNull;
    }
    final other = switch (kind) {
      BdBorderKind.leftShiftRegister => BdBorderKind.rightShiftRegister,
      BdBorderKind.rightShiftRegister => BdBorderKind.leftShiftRegister,
      _ => null,
    };
    if (other == null) return null;
    final mine = terminal.children.refs.map((r) => r.targetOid).toSet();
    for (final t in owner.borderTerminals) {
      if (t.kind != other) continue;
      if (mine.contains(t.terminal.oid) ||
          t.terminal.children.refs.any((r) => r.targetOid == terminal.oid) ||
          t.terminal.children.whereType<HeapGroupNode>().any(
            (g) => g.children.refs.any((r) => r.targetOid == terminal.oid),
          )) {
        return t;
      }
    }
    return null;
  }

  /// Hides the terminal's glyph inside the structure.
  void hideGlyph() {
    for (final port in inners) {
      final children = port.node.children;
      for (var i = 0; i < children.length; i++) {
        final child = children[i];
        if (child is! HeapRecordNode) continue;
        final record = decodeHeapAttr(child.bytes, 0);
        if (record?.attribute != HeapAttribute.objFlags) continue;
        children[i] = attr(
          HeapAttribute.objFlags,
          HeapAttrWidth.rgb,
          record!.asInt! | ViObjFlag.terminalGlyphHidden.mask,
        );
      }
    }
  }

  /// Whether a loop tunnel indexes: reads or builds one element per iteration.
  bool get indexing => terminal.children.objects.any(
    (o) => o.kind == HeapObjectClass.bdTunnelIndexer.code && (o.children.attr(HeapAttribute.objFlags)?.asInt ?? 0) != 0,
  );

  bool get isInput => holder != null && outer.isSink;

  ViPoint _innerAttach() {
    final t = termBounds;
    return (x: (t.left + t.right) ~/ 2, y: (t.top + t.bottom) ~/ 2);
  }

  /// The middle of the terminal in the frame holding its structure: a sequence frame's
  /// bounds are relative to its sequence.
  ViPoint _outerAttach() {
    final t = termBounds;
    final owner = this.owner;
    final s = owner.bounds ?? kZeroRect;
    final origin = owner is BdSequenceFrame ? owner.sequence.bounds ?? kZeroRect : kZeroRect;
    return (
      x: origin.left + s.left + (t.left + t.right) ~/ 2,
      y: origin.top + s.top + (t.top + t.bottom) ~/ 2,
    );
  }

  /// Puts the terminal on [row], the wire row in its structure's coordinates.
  set row(int row) {
    final t = termBounds;
    _slot = row - (t.bottom - t.top) ~/ 2;
    _place();
  }

  void _place() {
    final side = _side;
    if (side == null) return;
    final s = owner.bounds ?? kZeroRect;
    final w = s.right - s.left, h = s.bottom - s.top;
    final y = _slot ?? 0;
    final rect = switch (side) {
      BdBorderSide.left => switch (kind) {
        BdBorderKind.leftShiftRegister => HeapRect(top: y, left: 0, bottom: y + 12, right: 16),
        BdBorderKind.selector => HeapRect(top: y, left: 0, bottom: y + 12, right: 8),
        _ => HeapRect(top: y, left: 0, bottom: y + 9, right: 9),
      },
      BdBorderSide.right => switch (kind) {
        BdBorderKind.rightShiftRegister => HeapRect(top: y, left: w - 16, bottom: y + 12, right: w),
        _ => HeapRect(top: y, left: w - 9, bottom: y + 9, right: w),
      },
      BdBorderSide.topLeft => const HeapRect(top: 0, left: 0, bottom: 16, right: 16),
      BdBorderSide.bottomLeft => HeapRect(top: h - 26, left: 10, bottom: h - 10, right: 26),
      BdBorderSide.bottomRight => HeapRect(top: h - 26, left: w - 26, bottom: h - 10, right: w - 10),
    };
    final children = terminal.children;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (child is HeapRecordNode && decodeHeapAttr(child.bytes, 0)?.attribute == HeapAttribute.termBounds) {
        children[i] = rectAttr(HeapAttribute.termBounds, rect);
      }
    }
  }

  @override
  String toString() => '$owner.$name';
}

/// A loop's shift register: its left and right terminals.
class BdShiftRegister {
  const BdShiftRegister(this.left, this.right);

  final BdStructureTerminal left;

  final BdStructureTerminal right;
}

/// A structure: a node that owns frames and border terminals.
class BdStructure extends BdNode {
  BdStructure._lifted(super.frameOf, super.node) : super._lifted();

  BdStructure._create(int frameCount, {super.at, BdInsets? padding, BdSize? size, super.label}) : super._create() {
    _createdFrames = List.generate(frameCount, (_) => BdFrame._pending(this));
    if (padding != null) this.padding = padding;
    if (size != null) minSize = size;
  }

  List<BdFrame>? _createdFrames;

  ViEditing get _model =>
      isPlaced ? frameOf.model : throw StateError('$this is not placed yet; add it to a frame first');

  /// Space between the structure's edge and its body.
  BdInsets padding = kBdStructurePadding;

  /// The least the structure is sized to.
  BdSize minSize = BdSize.zero;

  int _leftSlot = kBdFirstBorderSlot;

  int _rightSlot = kBdFirstBorderSlot;

  /// The structure's frames in record order.
  late final List<BdFrame> frames =
      _createdFrames ??
      [
        for (final child in node.children.objects)
          if (child.kind == HeapObjectClass.bdFrame.code) BdFrame._lifted(this, child),
        for (final group in node.children.whereType<HeapGroupNode>())
          for (final child in group.children.objects)
            if (child.kind == HeapObjectClass.bdFrame.code) BdFrame._lifted(this, child),
      ];

  /// The border terminals in record order: those in the terminal list, then those drawn
  /// inside.
  late final List<BdStructureTerminal> borderTerminals = [
    for (final holder in node.children.group(HeapGroupTag.termList.tag)?.children.objects ?? const <HeapObjectNode>[])
      for (final child in holder.children.objects)
        if (BdBorderKind.ofCode(child.kind) case final kind?) BdStructureTerminal._(this, kind, child, holder),
    for (final child in node.children.objects)
      if (BdBorderKind.ofCode(child.kind) case final kind?) BdStructureTerminal._(this, kind, child, null),
  ];

  BdStructureTerminal? _borderTerminal(BdBorderKind kind) => borderTerminals.where((t) => t.kind == kind).firstOrNull;

  BdStructureTerminal _requireTerminal(BdBorderKind kind) =>
      _borderTerminal(kind) ?? (throw StateError('$this has no ${kind.name} terminal'));

  HeapGroupNode _group(BdStructureList which) {
    final group = node.children.whereType<HeapGroupNode>().where((g) => g.rawId == which.rawId).firstOrNull;
    if (group == null) throw StateError('$this has no ${which.name} list');
    return group;
  }

  /// The rectangle the structure's inside is drawn in.
  HeapRect get typeBounds => node.children.c4(HeapOpcode.typeBounds)?.rect ?? kZeroRect;

  /// How far the inside sits from each edge of the bounds.
  HeapRect get _typeInsets => const HeapRect(top: 1, left: 1, bottom: 1, right: 1);

  @override
  set bounds(HeapRect? rect) {
    super.bounds = rect;
    final typeRect = _inset(rect!, _typeInsets);
    final children = node.children;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (child is HeapRecordNode &&
          child.bytes[0] == kHeapRecordPrefix &&
          child.bytes[1] == HeapOpcode.typeBounds.byte) {
        children[i] = c4Rect(HeapOpcode.typeBounds, typeRect);
      }
    }
    for (final terminal in borderTerminals) {
      terminal._place();
    }
  }

  /// A new tunnel of [type] through the border, carrying a value in or out; indexing on a
  /// loop reads or builds one element per iteration.
  BdStructureTerminal tunnel(BdType type, {required BdTunnelDirection direction, bool indexing = false}) =>
      throw UnsupportedError('$this takes no tunnels');

  HeapRect _nextSlot({required bool right}) {
    final s = bounds ?? kZeroRect;
    final y = right ? _rightSlot : _leftSlot;
    if (right) {
      _rightSlot += kBdBorderSlotStep;
    } else {
      _leftSlot += kBdBorderSlotStep;
    }
    final w = s.right - s.left;
    return right
        ? HeapRect(top: y, left: w - 9, bottom: y + 9, right: w)
        : HeapRect(top: y, left: 0, bottom: y + 9, right: 9);
  }

  /// Adds [terminal]'s holder to the terminal list and, in each frame it names, an endpoint
  /// entry with [innerFlags] referring to the terminal.
  BdStructureTerminal _addBorderTerminal(
    ViEditing model,
    BdBorderKind kind,
    HeapObjectNode terminal, {
    required int holderFlags,
    required HeapAttrWidth holderWidth,
    required int innerFlags,
    required BdType? type,
    BdType? innerType,
    required BdBorderSide side,
    required int slot,
    List<BdFrame>? inFrames,
    bool drawn = false,
  }) {
    final borderTerminals = this.borderTerminals;
    final holder = holderFlags == 0
        ? null
        : object(
            kNodeEndpointDcoKind,
            model.allocateUid(),
            children: [attr(HeapAttribute.objFlags, holderWidth, holderFlags), terminal],
          );
    final refs = terminal.children.group(HeapGroupTag.termList.tag)!;
    for (final frame in inFrames ?? frames) {
      final entry = object(
        kNodeEndpointDcoKind,
        model.allocateUid(),
        children: [attr(HeapAttribute.objFlags, HeapAttrWidth.u24, innerFlags), ref(HeapRefKind.dcoRef, terminal.oid)],
      );
      frame._addEntry(entry);
      if (drawn) frame._addObjectRef(entry.oid);
      refs.children.add(ref(HeapRefKind.childRef, entry.oid));
    }
    if (holder != null) {
      refs.children.add(ref(HeapRefKind.childRef, holder.oid));
      final holders = node.children.group(HeapGroupTag.termList.tag)!;
      holders.children.add(holder);
      holders.syncCount();
    } else {
      node.children.add(terminal);
    }
    refs.syncCount();
    final border = BdStructureTerminal._(
      this,
      kind,
      terminal,
      holder,
      type: type,
      innerType: innerType,
      side: side,
      slot: slot,
    ).._place();
    if (holder == null) {
      borderTerminals.add(border);
    } else {
      final at = borderTerminals.indexWhere((t) => t.holder == null);
      borderTerminals.insert(at < 0 ? borderTerminals.length : at, border);
    }
    return border;
  }

  /// The records of each created frame.
  List<HeapObjectNode> _frameNodes(ViEditing model, {HeapRect tableBounds = kZeroRect}) => [
    for (final frame in frames) frame.node = _frameNode(model, tableBounds: tableBounds),
  ];

  static HeapObjectNode _frameNode(ViEditing model, {HeapRect tableBounds = kZeroRect}) => object(
    HeapObjectClass.bdFrame.code,
    model.allocateUid(),
    children: [
      list(BdFrameList.objects.rawId),
      list(BdFrameList.nodes.rawId, [
        object(
          HeapObjectClass.bdWire.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1000),
            list(kBdTermList),
            c4Rect(HeapOpcode.bounds, tableBounds),
            attr(HeapAttribute.shortCount, HeapAttrWidth.u8, 1),
          ],
        ),
      ]),
      list(BdFrameList.signals.rawId),
      attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
    ],
  );

  static HeapRect _inset(HeapRect r, HeapRect by) =>
      HeapRect(top: r.top + by.top, left: r.left + by.left, bottom: r.bottom - by.bottom, right: r.right - by.right);
}

/// A For or While loop.
class BdLoop extends BdStructure {
  BdLoop._lifted(super.frameOf, super.node) : _isFor = null, super._lifted();

  BdLoop._create({required bool isFor, super.at, super.padding, super.size, super.label})
    : _isFor = isFor,
      super._create(1);

  /// A For loop with its count and iteration terminals, at [at] or laid out by its frame
  /// around what its body takes, inside [padding] and at least [size]; [label] names it.
  factory BdLoop.forLoop({HeapRect? at, BdInsets? padding, BdSize? size, String? label}) =>
      BdLoop._create(isFor: true, at: at, padding: padding, size: size, label: label);

  /// A While loop with its iteration and conditional terminals, at [at] or laid out by its
  /// frame around what its body takes, inside [padding] and at least [size]; [label] names it.
  factory BdLoop.whileLoop({HeapRect? at, BdInsets? padding, BdSize? size, String? label}) =>
      BdLoop._create(isFor: false, at: at, padding: padding, size: size, label: label);

  final bool? _isFor;

  @override
  HeapObjectNode _make(ViEditing model) {
    final isFor = _isFor!;
    final bounds =
        _at ?? const HeapRect(top: 0, left: 0, bottom: kBdDefaultStructureHeight, right: kBdDefaultStructureWidth);
    final node = object(
      isFor ? HeapObjectClass.bdForLoop.code : HeapObjectClass.bdWhileLoop.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, isFor ? 0x10000000 : 0x10005280),
        list(kBdTermList),
        ?_labelRecord(model),
        c4Rect(HeapOpcode.bounds, bounds),
        c4Rect(HeapOpcode.typeBounds, BdStructure._inset(bounds, _typeInsets)),
        list(BdStructureList.tunnels.rawId),
        list(BdStructureList.frames.rawId, _frameNodes(model)),
        if (!isFor) attr(HeapAttribute.structColor, HeapAttrWidth.rgb, 0x7f7f7f),
      ],
    );
    _node = node;
    if (isFor) {
      final count = object(
        HeapObjectClass.bdCountTerminal.code,
        model.allocateUid(),
        rawTag: HeapRefKind.dcoRef.raw,
        children: [
          list(kBdTermList),
          attr(HeapAttribute.dcoFiller, HeapAttrWidth.u16, 0x200),
          rectAttr(HeapAttribute.termBounds, kZeroRect),
          attr(HeapAttribute.termBMPs, HeapAttrWidth.u8, 2),
        ],
      );
      _addBorderTerminal(
        model,
        BdBorderKind.count,
        count,
        holderFlags: 0x9040,
        holderWidth: HeapAttrWidth.u24,
        innerFlags: 0x20000,
        type: BdType.i32,
        side: BdBorderSide.topLeft,
        slot: 0,
      );
    }
    _addBorderTerminal(
      model,
      BdBorderKind.iteration,
      object(
        HeapObjectClass.bdIterationTerminal.code,
        model.allocateUid(),
        rawTag: 0xa8,
        children: [
          list(kBdTermList),
          rectAttr(HeapAttribute.termBounds, kZeroRect),
          attr(HeapAttribute.termBMPs, HeapAttrWidth.u8, 1),
        ],
      ),
      holderFlags: 0,
      holderWidth: HeapAttrWidth.u8,
      innerFlags: 0x20140,
      type: BdType.i32,
      side: BdBorderSide.bottomLeft,
      slot: 0,
      drawn: true,
    );
    if (isFor) {
      node.children.add(ref(HeapRefKind.loopLimitDCORef, count.terminal.oid));
    } else {
      _addBorderTerminal(
        model,
        BdBorderKind.conditional,
        object(
          HeapObjectClass.bdConditionalTerminal.code,
          model.allocateUid(),
          rawTag: 0x1be,
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x10001),
            list(kBdTermList),
            rectAttr(HeapAttribute.termBounds, kZeroRect),
            attr(HeapAttribute.termBMPs, HeapAttrWidth.u16, 0xc0),
          ],
        ),
        holderFlags: 0,
        holderWidth: HeapAttrWidth.u8,
        innerFlags: 0x29140,
        type: BdType.boolean,
        side: BdBorderSide.bottomRight,
        slot: 0,
        drawn: true,
      );
    }
    node.children.addAll([
      list(BdStructureList.rightShiftRegisters.rawId),
      list(BdStructureList.list282.rawId),
      if (isFor) ...[
        attr(HeapAttribute.parForIndexDistribution, HeapAttrWidth.u8, 0),
        attr(HeapAttribute.parForNumStaticWorkers, HeapAttrWidth.u8, 0),
        attr(HeapAttribute.debuggingEnabled, HeapAttrWidth.flag, 0),
        attr(HeapAttribute.outputInstanceNumberFromP, HeapAttrWidth.flag, 0),
      ] else
        list(BdStructureList.list52.rawId),
    ]);
    return node;
  }

  bool get isFor => _isFor ?? node.kind == HeapObjectClass.bdForLoop.code;

  BdFrame get body => frames.single;

  /// Places [item] in the body.
  T add<T extends BdPlaced>(T item) => body.add(item);

  /// A For loop's count terminal, wired from outside.
  BdStructureTerminal get count => _requireTerminal(BdBorderKind.count);

  /// The iteration terminal inside the body.
  BdStructureTerminal get iteration => _requireTerminal(BdBorderKind.iteration);

  /// A While loop's conditional terminal inside the body.
  BdStructureTerminal get conditional => _requireTerminal(BdBorderKind.conditional);

  @override
  BdStructureTerminal tunnel(BdType type, {required BdTunnelDirection direction, bool indexing = false}) {
    final model = _model;
    final output = direction == BdTunnelDirection.output;
    final slot = _nextSlot(right: output);
    final refs = list(kBdTermList);
    final terminal = object(
      HeapObjectClass.bdLoopTunnel.code,
      model.allocateUid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        indexing
            ? attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, 0x1000800 | (output ? 1 : 0))
            : attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x800 | (output ? 1 : 0)),
        refs,
        rectAttr(HeapAttribute.termBounds, slot),
      ],
    );
    if (indexing && type.dims == 0) throw ArgumentError.value(type, 'type', 'an indexing tunnel carries an array');
    final border = _addBorderTerminal(
      model,
      BdBorderKind.loopTunnel,
      terminal,
      holderFlags: output ? 0x201040 : 0x209040,
      holderWidth: HeapAttrWidth.u24,
      innerFlags: output ? 0x228000 : 0x220000,
      type: type,
      innerType: indexing ? BdType.array(type.element, dims: type.dims - 1) : type,
      side: output ? BdBorderSide.right : BdBorderSide.left,
      slot: slot.top,
    );
    final countHolder = indexing && !output ? _borderTerminal(BdBorderKind.count)?.holder : null;
    if (countHolder != null) {
      final holder = countHolder.children;
      for (var i = 0; i < holder.length; i++) {
        final child = holder[i];
        if (child is HeapRecordNode && decodeHeapAttr(child.bytes, 0)?.attribute == HeapAttribute.objFlags) {
          holder[i] = attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1040);
        }
      }
    }
    if (indexing) {
      terminal.children.addAll([
        object(
          HeapObjectClass.bdTunnelIndexer.code,
          model.allocateUid(),
          rawTag: 0x94,
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, 0x1000001),
            list(kBdTermList, [for (final r in refs.children) r]),
            rawRef(kBdIndexerTunnelRef, terminal.oid),
          ],
        ),
        attr(HeapAttribute.tunnelType, HeapAttrWidth.u8, 1),
        attr(HeapAttribute.defaultTunnelType, HeapAttrWidth.u8, 1),
      ]);
    }
    final tunnels = _group(BdStructureList.tunnels);
    tunnels.children.add(ref(HeapRefKind.childRef, terminal.oid));
    tunnels.syncCount();
    return border;
  }

  /// A new shift register of [type]: its right terminal takes the value for the next
  /// iteration, its left terminal gives the previous one.
  BdShiftRegister shiftRegister(BdType type) {
    final model = _model;
    final y = _leftSlot;
    _leftSlot += kBdBorderSlotStep;
    _rightSlot += kBdBorderSlotStep;
    final rightOid = model.allocateUid(), leftOid = model.allocateUid();
    final right = object(
      HeapObjectClass.bdRightShiftRegister.code,
      rightOid,
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u8, 1),
        list(kBdTermList),
        rectAttr(HeapAttribute.termBounds, kZeroRect),
        attr(HeapAttribute.termHotPoint, HeapAttrWidth.rgb, 0xfffc),
        attr(HeapAttribute.termBMPs, HeapAttrWidth.u8, 4),
        list(kBdShiftRegisterPartnerList, [ref(HeapRefKind.childRef, leftOid)]),
      ],
    );
    final left = object(
      HeapObjectClass.bdLeftShiftRegister.code,
      leftOid,
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        list(kBdTermList),
        rectAttr(HeapAttribute.termBounds, kZeroRect),
        attr(HeapAttribute.termHotPoint, HeapAttrWidth.rgb, 0x4),
        attr(HeapAttribute.termBMPs, HeapAttrWidth.u8, 3),
        rawRef(kBdShiftRegisterPartnerRef, rightOid),
      ],
    );
    final rightTerminal = _addBorderTerminal(
      model,
      BdBorderKind.rightShiftRegister,
      right,
      holderFlags: 0x1040,
      holderWidth: HeapAttrWidth.u16,
      innerFlags: 0x28000,
      type: type,
      side: BdBorderSide.right,
      slot: y,
    );
    final leftTerminal = _addBorderTerminal(
      model,
      BdBorderKind.leftShiftRegister,
      left,
      holderFlags: 0x9040,
      holderWidth: HeapAttrWidth.u24,
      innerFlags: 0x20000,
      type: type,
      side: BdBorderSide.left,
      slot: y,
    );
    final rights = _group(BdStructureList.rightShiftRegisters);
    rights.children.add(ref(HeapRefKind.childRef, rightOid));
    rights.syncCount();
    return BdShiftRegister(leftTerminal, rightTerminal);
  }

  @override
  String toString() => '${isFor ? 'For' : 'While'} loop${isPlaced ? '#$oid' : ' (unplaced)'}';
}

/// A Case structure.
class BdCase extends BdStructure {
  BdCase._lifted(super.frameOf, super.node) : _displayed = null, super._lifted();

  /// A Case structure over a boolean selector with [frameCount] frames, False first, showing
  /// [displayed], inside [padding] and at least [size]; [label] names it.
  BdCase({int frameCount = 2, int? displayed, super.at, super.padding, super.size, super.label})
    : _displayed = displayed ?? frameCount - 1,
      super._create(frameCount);

  final int? _displayed;

  @override
  HeapObjectNode _make(ViEditing model) {
    final bounds =
        _at ?? const HeapRect(top: 0, left: 0, bottom: kBdDefaultStructureHeight, right: kBdDefaultStructureWidth);
    final shown = _displayed!;
    final labelText = ' ${shown == 0 ? 'False' : 'True'} ';
    final labelWidth = bdLabelWidth(labelText);
    final width = bounds.right - bounds.left;
    final node = object(
      HeapObjectClass.bdStructureFrame.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, 0x10010000),
        list(kBdTermList),
        ?_labelRecord(model),
        c4Rect(HeapOpcode.bounds, bounds),
        c4Rect(HeapOpcode.typeBounds, BdStructure._inset(bounds, _typeInsets)),
        list(BdStructureList.tunnels.rawId),
        attr(HeapAttribute.dIdx, HeapAttrWidth.u8, shown),
        list(BdStructureList.frames.rawId, _frameNodes(model)),
      ],
    );
    _node = node;
    final selector = object(
      HeapObjectClass.bdSelectorTerminal.code,
      model.allocateUid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        list(kBdTermList),
        rectAttr(HeapAttribute.termBounds, kZeroRect),
        attr(HeapAttribute.termBMPs, HeapAttrWidth.u8, 5),
      ],
    );
    _addBorderTerminal(
      model,
      BdBorderKind.selector,
      selector,
      holderFlags: 0x409040,
      holderWidth: HeapAttrWidth.u24,
      innerFlags: 0x420000,
      type: BdType.boolean,
      side: BdBorderSide.left,
      slot: _nextSlot(right: false).top,
    );
    node.children.addAll([
      rawRef(kBdCaseSelectorRef, selector.oid),
      object(
        HeapObjectClass.bdSelectorLabel.code,
        model.allocateUid(),
        rawTag: 0x102,
        children: [
          attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x241131),
          attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x50),
          attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
          attr(HeapAttribute.howGrow, HeapAttrWidth.u8, 0x34),
          c4Rect(
            HeapOpcode.bounds,
            HeapRect(top: 0, left: (width - labelWidth) ~/ 2, bottom: 17, right: (width + labelWidth) ~/ 2),
          ),
          worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xf5)]),
          attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
          worded(kPartText, kPartTextWord, [
            attr(HeapAttribute.cosmColorB, HeapAttrWidth.u16, 0x4501),
            caption(labelText),
            attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, 0xffffff),
          ]),
          attr(HeapAttribute.nVisItems, HeapAttrWidth.u8, 0xa),
        ],
      ),
      attr(HeapAttribute.selectNRightType, HeapAttrWidth.u8, 2),
      list(BdStructureList.caseFrameEntries.rawId, [
        for (var i = 0; i < frames.length; i++)
          worded(kBdCaseFrameEntry, kBdCaseFrameEntryWord, [
            attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, i),
            attr(HeapAttribute.cosmFgColor, HeapAttrWidth.u8, i),
            attr(HeapAttribute.cosmColorB, HeapAttrWidth.u8, 0),
            attr(HeapAttribute.shortText, HeapAttrWidth.u8, 0),
            attr(HeapAttribute.field23, HeapAttrWidth.u8, i),
          ]),
      ]),
      list(BdStructureList.caseStrings.rawId),
      attr(HeapAttribute.selectSelLabFlags, HeapAttrWidth.u16, 0x109c),
    ]);
    return node;
  }

  @override
  HeapRect get _typeInsets => const HeapRect(top: 6, left: 6, bottom: 6, right: 6);

  /// The selector terminal, wired from outside.
  BdStructureTerminal get selector => _requireTerminal(BdBorderKind.selector);

  /// The frames a boolean selector chooses between.
  BdFrame get whenFalse => frames[0];

  BdFrame get whenTrue => frames[1];

  @override
  BdStructureTerminal tunnel(BdType type, {required BdTunnelDirection direction, bool indexing = false}) {
    if (indexing) throw ArgumentError.value(indexing, 'indexing', 'a Case tunnel does not index');
    final model = _model;
    final output = direction == BdTunnelDirection.output;
    final slot = _nextSlot(right: output);
    final terminal = object(
      HeapObjectClass.bdCaseTunnel.code,
      model.allocateUid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x800 | (output ? 1 : 0)),
        list(kBdTermList),
        rectAttr(HeapAttribute.termBounds, slot),
      ],
    );
    final border = _addBorderTerminal(
      model,
      BdBorderKind.caseTunnel,
      terminal,
      holderFlags: output ? 0x401040 : 0x409040,
      holderWidth: HeapAttrWidth.u24,
      innerFlags: output ? 0x428000 : 0x420000,
      type: type,
      side: output ? BdBorderSide.right : BdBorderSide.left,
      slot: slot.top,
    );
    final tunnels = _group(BdStructureList.tunnels);
    tunnels.children.add(ref(HeapRefKind.childRef, terminal.oid));
    tunnels.syncCount();
    return border;
  }

  @override
  String toString() => isPlaced ? 'Case#$oid' : 'Case (unplaced)';
}

/// A Diagram Disable structure: its first frame disabled, its second enabled.
class BdDisable extends BdStructure {
  BdDisable._lifted(super.frameOf, super.node) : super._lifted();

  /// A Diagram Disable structure at [at] or laid out by its frame, inside [padding] and at
  /// least [size].
  BdDisable({super.at, super.padding, super.size}) : super._create(2);

  @override
  HeapObjectNode _make(ViEditing model) {
    final bounds =
        _at ?? const HeapRect(top: 0, left: 0, bottom: kBdDefaultStructureHeight, right: kBdDefaultStructureWidth);
    const labelText = ' Disabled ';
    final labelWidth = bdLabelWidth(labelText);
    final width = bounds.right - bounds.left;
    return object(
      HeapObjectClass.bdDisableStructure.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, 0x10010000),
        list(kBdTermList),
        c4Rect(HeapOpcode.bounds, bounds),
        c4Rect(HeapOpcode.typeBounds, BdStructure._inset(bounds, _typeInsets)),
        list(BdStructureList.tunnels.rawId),
        list(BdStructureList.frames.rawId, _frameNodes(model)),
        object(
          HeapObjectClass.bdSelectorLabel.code,
          model.allocateUid(),
          rawTag: 0x102,
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x241531),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x50),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u8, 0x34),
            c4Rect(
              HeapOpcode.bounds,
              HeapRect(top: 0, left: (width - labelWidth) ~/ 2, bottom: 17, right: (width + labelWidth) ~/ 2),
            ),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xf5)]),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
            worded(kPartText, kPartTextWord, [
              attr(HeapAttribute.cosmColorB, HeapAttrWidth.u16, 0x4501),
              caption(labelText),
              attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, 0xffffff),
            ]),
            attr(HeapAttribute.nVisItems, HeapAttrWidth.u8, 0xa),
          ],
        ),
        attr(HeapAttribute.cosmFgColor, HeapAttrWidth.u8, 1),
        raw(const [0x24, 0x57, 0x01]),
        raw(const [0xe4, 0x41]),
        list(BdStructureList.disableFrameEntries.rawId, [
          for (var i = 0; i < 2; i++)
            worded(kBdCaseFrameEntry, kBdDisableFrameEntryWord, [
              raw(const [0x04, 0x1f]),
              worded(0x020, kBdDisableFrameEntryInnerWord, [list(0x01f), list(0x020)]),
            ]),
        ]),
        raw(const [0x26, 0x68, 0x1c]),
      ],
    );
  }

  BdFrame get disabled => frames[0];

  BdFrame get enabled => frames[1];

  @override
  String toString() => isPlaced ? 'Disable#$oid' : 'Disable (unplaced)';
}

/// A Flat Sequence structure: its frames run left to right, each a [BdSequenceFrame] with a
/// body; a value crosses from one frame to the next through a pair of frame tunnels.
class BdSequence extends BdStructure {
  BdSequence._lifted(super.frameOf, super.node) : super._lifted();

  /// A Flat Sequence of [frameCount] frames at [at] or laid out by its frame, each frame
  /// around what its body takes, inside [padding] and at least [size].
  BdSequence({int frameCount = 2, super.at, super.padding, super.size}) : super._create(0) {
    _stages = [for (var i = 0; i < frameCount; i++) BdSequenceFrame._create(this, i)];
  }

  List<BdSequenceFrame>? _stages;

  /// The frames in order, as LabVIEW calls them.
  late final List<BdSequenceFrame> stages =
      _stages ??
      [
        for (final group in node.children.whereType<HeapGroupNode>())
          for (final (i, child) in group.children.objects.indexed)
            if (child.kind == HeapObjectClass.bdSequenceFrame.code) BdSequenceFrame._lifted(this, child, i),
      ];

  @override
  List<BdFrame> get frames => [for (final stage in stages) stage.body];

  @override
  List<BdStructureTerminal> get borderTerminals => [for (final stage in stages) ...stage.borderTerminals];

  @override
  HeapObjectNode _make(ViEditing model) {
    final bounds =
        _at ?? const HeapRect(top: 0, left: 0, bottom: kBdDefaultStructureHeight, right: kBdDefaultStructureWidth);
    final width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
    final step = width - kBdSequenceFrameOverlap;
    for (final (i, stage) in stages.indexed) {
      stage._at = HeapRect(top: 0, left: i * step, bottom: height, right: i * step + width);
      stage._build(model);
    }
    return object(
      HeapObjectClass.bdFlatSequence.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x800),
        list(BdStructureList.sequenceFrames.rawId, [for (final stage in stages) stage.node]),
        c4Rect(
          HeapOpcode.bounds,
          HeapRect(
            top: bounds.top,
            left: bounds.left,
            bottom: bounds.bottom,
            right: bounds.left + width + step * (stages.length - 1),
          ),
        ),
        attr(HeapAttribute.structColor, HeapAttrWidth.rgb, kBdSequenceColor),
      ],
    );
  }

  /// Sizes every frame to [frame], side by side and overlapping as the corpus draws them, and
  /// the sequence around them.
  void sizeFrames(BdSize frame) {
    final step = frame.width - kBdSequenceFrameOverlap;
    for (final (i, stage) in stages.indexed) {
      final left = i * step;
      stage.bounds = HeapRect(top: 0, left: left, bottom: frame.height, right: left + frame.width);
      stage.body.endpointTable?.children.setBounds(HeapRect(top: 0, left: -left, bottom: 0, right: -left));
    }
    final s = bounds ?? kZeroRect;
    bounds = HeapRect(
      top: s.top,
      left: s.left,
      bottom: s.top + frame.height,
      right: s.left + frame.width + step * (stages.length - 1),
    );
  }

  @override
  String toString() => isPlaced ? 'Sequence#$oid' : 'Sequence (unplaced)';
}

/// One frame of a Flat Sequence: a structure with one body, placed by its sequence.
class BdSequenceFrame extends BdStructure {
  BdSequenceFrame._lifted(this.sequence, HeapObjectNode node, this.index) : super._lifted(null, node);

  BdSequenceFrame._create(this.sequence, this.index) : super._create(1);

  final BdSequence sequence;

  /// Position among the sequence's frames.
  final int index;

  @override
  BdFrame get frameOf => sequence.frameOf;

  BdFrame get body => frames.single;

  /// Places [item] in the body.
  T add<T extends BdPlaced>(T item) => body.add(item);

  /// The sequence's padding.
  @override
  BdInsets get padding => sequence.padding;

  @override
  set padding(BdInsets value) => sequence.padding = value;

  @override
  HeapRect get _typeInsets => const HeapRect(top: 10, left: 6, bottom: 10, right: 6);

  @override
  HeapObjectNode _make(ViEditing model) {
    final bounds = _at!;
    return object(
      HeapObjectClass.bdSequenceFrame.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, 0x10010280),
        list(kBdTermList),
        c4Rect(HeapOpcode.bounds, bounds),
        c4Rect(HeapOpcode.typeBounds, BdStructure._inset(bounds, _typeInsets)),
        list(BdStructureList.tunnels.rawId),
        list(
          BdStructureList.frames.rawId,
          _frameNodes(
            model,
            tableBounds: HeapRect(top: 0, left: -bounds.left, bottom: 0, right: -bounds.left),
          ),
        ),
        attr(HeapAttribute.structColor, HeapAttrWidth.rgb, kBdSequenceColor),
      ],
    );
  }

  /// A tunnel through the sequence's border into or out of this frame.
  @override
  BdStructureTerminal tunnel(BdType type, {required BdTunnelDirection direction, bool indexing = false}) {
    if (indexing) throw ArgumentError.value(indexing, 'indexing', 'a sequence tunnel does not index');
    return _tunnel(BdBorderKind.sequenceTunnel, type, output: direction == BdTunnelDirection.output);
  }

  /// The pair of frame tunnels carrying a value of [type] from this frame into [next]: the
  /// one it leaves by and the one it enters by.
  (BdStructureTerminal, BdStructureTerminal) link(BdSequenceFrame next, BdType type) {
    final out = _tunnel(BdBorderKind.frameTunnel, type, output: true);
    final into = next._tunnel(BdBorderKind.frameTunnel, type, output: false);
    out.terminal.children.add(rawRef(kBdFrameTunnelPartnerRef, into.terminal.oid));
    into.terminal.children.add(rawRef(kBdFrameTunnelPartnerRef, out.terminal.oid));
    return (out, into);
  }

  BdStructureTerminal _tunnel(BdBorderKind kind, BdType type, {required bool output}) {
    final model = _model;
    final slot = _nextSlot(right: output);
    final entering = kind == BdBorderKind.frameTunnel && !output;
    final terminal = object(
      kind.objectClass.code,
      model.allocateUid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        entering
            ? attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x200800)
            : attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x800 | (output ? 1 : 0)),
        list(kBdTermList),
        rectAttr(HeapAttribute.termBounds, slot),
      ],
    );
    final border = _addBorderTerminal(
      model,
      kind,
      terminal,
      holderFlags: output ? 0x1040 : 0x9040,
      holderWidth: HeapAttrWidth.u16,
      innerFlags: output ? 0x28000 : 0x20000,
      type: type,
      side: output ? BdBorderSide.right : BdBorderSide.left,
      slot: slot.top,
    );
    final tunnels = _group(BdStructureList.tunnels);
    tunnels.children.add(ref(HeapRefKind.childRef, terminal.oid));
    tunnels.syncCount();
    return border;
  }

  @override
  String toString() => '$sequence.frame$index';
}

/// A constant: an endpoint-table entry holding its own data object, and the endpoint its
/// wire leaves from.
class BdConstant extends BdPlaced with BdEndpoint {
  BdConstant._lifted(super.frameOf, super.node)
    : _value = null,
      _label = null,
      _showLabel = false,
      _view = null,
      _emptyString = false,
      super._lifted();

  /// A constant of [type] holding [value], which [label] names, shown on the diagram when
  /// [showLabel]; an array shows itself as [view] says.
  BdConstant._(
    BdType type,
    Object value, {
    String? label,
    bool showLabel = false,
    BdArrayView? view,
    bool emptyString = false,
    super.at,
  }) : _type = type,
       _value = value,
       _label = label,
       _showLabel = showLabel,
       _view = view,
       _emptyString = emptyString,
       super._create();

  BdConstant.i8(int value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.i8, value, label: label, showLabel: showLabel, at: at);

  BdConstant.i16(int value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.i16, value, label: label, showLabel: showLabel, at: at);

  BdConstant.i32(int value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.i32, value, label: label, showLabel: showLabel, at: at);

  BdConstant.i64(int value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.i64, value, label: label, showLabel: showLabel, at: at);

  BdConstant.u8(int value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.u8, value, label: label, showLabel: showLabel, at: at);

  BdConstant.u16(int value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.u16, value, label: label, showLabel: showLabel, at: at);

  BdConstant.u32(int value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.u32, value, label: label, showLabel: showLabel, at: at);

  BdConstant.u64(int value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.u64, value, label: label, showLabel: showLabel, at: at);

  BdConstant.sgl(double value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.sgl, value, label: label, showLabel: showLabel, at: at);

  BdConstant.dbl(double value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.dbl, value, label: label, showLabel: showLabel, at: at);

  BdConstant.boolean(bool value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.boolean, value, label: label, showLabel: showLabel, at: at);

  BdConstant.string(String value, {String? label, bool showLabel = false, HeapRect? at})
    : this._(BdType.string, value, label: label, showLabel: showLabel, at: at);

  /// An array constant over [element]s holding [values]: numbers or bools, shown as [view]
  /// says.
  BdConstant.array(
    BdType element,
    List<Object> values, {
    String? label,
    bool showLabel = false,
    BdArrayView? view,
    HeapRect? at,
  }) : this._(element.array, values, label: label, showLabel: showLabel, view: view, at: at);

  /// The palette's Empty String Constant: an 18 by 16 glyph at [at]'s top left, with no label.
  BdConstant.emptyString({ViPoint? at})
    : this._(
        BdType.string,
        '',
        emptyString: true,
        at: at == null
            ? null
            : HeapRect(
                top: at.y,
                left: at.x,
                bottom: at.y + kBdEmptyStringConstantHeight,
                right: at.x + kBdEmptyStringConstantWidth,
              ),
      );

  BdType? _type;

  final Object? _value;

  final String? _label;

  final bool _showLabel;

  final BdArrayView? _view;

  final bool _emptyString;

  @override
  HeapObjectNode _make(ViEditing model) {
    if (_emptyString) return _makeEmptyString(model);
    final type = _type!, label = _label, array = _view;
    final index = type.addTo(model, label: label);
    final slot = model.allocateTypeSlot(index);
    final controlSlot = model.allocateTypeSlot(index);
    final bounds =
        _at ??
        (array != null
            ? HeapRect(
                top: 0,
                left: 0,
                bottom:
                    (array.element.bottom > array.index.bottom ? array.element.bottom : array.index.bottom) +
                    kBdArrayFrameInset,
                right: array.element.right + kBdArrayFrameInset,
              )
            : type.element == ViDataType.boolean && type.dims == 0
            ? const HeapRect(top: 0, left: 0, bottom: 14, right: 16)
            : const HeapRect(top: 0, left: 0, bottom: 19, right: 36));
    return object(
      kNodeEndpointDcoKind,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x20040),
        object(
          HeapObjectClass.bdConstDco.code,
          model.allocateUid(),
          rawTag: HeapRefKind.dcoRef.raw,
          children: [
            attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, slot),
            attr(HeapAttribute.dsw, HeapAttrWidth.u16, 0x1000),
            object(
              _carrierClass(type).code,
              model.allocateUid(),
              rawTag: HeapRefKind.ddoRef.raw,
              children: [
                switch (_carrierClass(type)) {
                  HeapObjectClass.booleanOrClusterControl => attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1004),
                  HeapObjectClass.caseOrSequence ||
                  HeapObjectClass.stringOrArrayControl => attr(HeapAttribute.objFlags, HeapAttrWidth.u8, 4),
                  _ => attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x60000),
                },
                c4Rect(HeapOpcode.bounds, bounds),
                list(
                  kControlParts,
                  array == null
                      ? _constantParts(
                          model,
                          type,
                          label,
                          HeapRect(
                            top: 0,
                            left: 0,
                            bottom: bounds.bottom - bounds.top,
                            right: bounds.right - bounds.left,
                          ),
                          null,
                          showLabel: _showLabel,
                        )
                      : [
                          if (label != null) _constantLabelPart(model, label, null, showLabel: _showLabel),
                          ..._arrayShellParts(model, array),
                        ],
                ),
                attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, controlSlot),
                attr(
                  HeapAttribute.mouseWheelSupport,
                  HeapAttrWidth.u8,
                  _carrierClass(type) == HeapObjectClass.stringOrArrayControl || array != null ? 3 : 2,
                ),
                if (array != null) ...[
                  _arrayElementControl(model, array, model.allocateTypeSlot(BdType.scalar(type.element).addTo(model))),
                  list(kBdArrayIndexGroup, [attr(HeapAttribute.arrayElemValue, HeapAttrWidth.u16, array.firstIndex)]),
                ],
              ],
            ),
            _constValue(type, _value!),
          ],
        ),
      ],
    );
  }

  HeapObjectNode _makeEmptyString(ViEditing model) {
    final index = BdType.string.addTo(model);
    final slot = model.allocateTypeSlot(index);
    final controlSlot = model.allocateTypeSlot(index);
    return object(
      kNodeEndpointDcoKind,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x21040),
        object(
          HeapObjectClass.bdConstDco.code,
          model.allocateUid(),
          rawTag: HeapRefKind.dcoRef.raw,
          children: [
            attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, slot),
            attr(HeapAttribute.dsw, HeapAttrWidth.u16, 0x1000),
            object(
              HeapObjectClass.bdConstant4e.code,
              model.allocateUid(),
              rawTag: HeapRefKind.ddoRef.raw,
              children: [
                attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1020),
                c4Rect(
                  HeapOpcode.bounds,
                  _at ??
                      const HeapRect(
                        top: 0,
                        left: 0,
                        bottom: kBdEmptyStringConstantHeight,
                        right: kBdEmptyStringConstantWidth,
                      ),
                ),
                list(kControlParts, [
                  object(
                    HeapObjectClass.controlChrome.code,
                    model.allocateUid(),
                    children: [
                      attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1933),
                      attr(HeapAttribute.partRole, HeapAttrWidth.u8, 9),
                      attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
                      c4Rect(HeapOpcode.bounds, const HeapRect(top: -8, left: -7, bottom: 24, right: 25)),
                      worded(kPartOffset, kPartOffsetWord, [
                        attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, kBdEmptyStringGlyph),
                      ]),
                      attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xff00ff),
                      attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
                    ],
                  ),
                  _connectorTerminalPart(model, 0x5bcf),
                ]),
                attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, controlSlot),
                attr(HeapAttribute.mouseWheelSupport, HeapAttrWidth.u8, 0),
                attr(HeapAttribute.fixedConstant, HeapAttrWidth.u8, kBdEmptyStringConstant),
              ],
            ),
            _constValue(BdType.string, ''),
          ],
        ),
      ],
    );
  }

  HeapObjectNode get data => node.children.objects.firstWhere((o) => o.kind == HeapObjectClass.bdConstDco.code);

  HeapObjectNode get _control => data.children.objects.first;

  @override
  HeapRect? get bounds => _control.children.bounds;

  @override
  set bounds(HeapRect? rect) {
    if (rect == null) throw ArgumentError.notNull('rect');
    _control.children.setBounds(rect);
  }

  @override
  BdType? get type => _type;

  @override
  bool get isSink => false;

  @override
  String get name => isPlaced ? 'constant#$oid' : 'constant (unplaced)';

  @override
  ViPoint get attachPoint {
    final b = bounds ?? kZeroRect;
    return (x: (b.left + b.right) ~/ 2, y: (b.top + b.bottom) ~/ 2);
  }

  @override
  BdSize get labelSize => _label == null ? BdSize.zero : BdSize(bdLabelWidth(_label), kBdLabelHeight);

  @override
  String toString() => name;
}

/// The parts of a constant's control around its [box]: a numeric's label, display, increment
/// buttons, frame and terminal; a boolean's button and terminal, with a label only when it has
/// one.
List<HeapNode> _constantParts(
  ViEditing model,
  BdType type,
  String? label,
  HeapRect box,
  HeapRect? labelAt, {
  required bool showLabel,
}) {
  final w = box.right - box.left, h = box.bottom - box.top, x = box.left, y = box.top;
  HeapObjectNode labelPart() => _constantLabelPart(model, label, labelAt, showLabel: showLabel);
  HeapObjectNode terminalPart(int sizeExtent) => object(
    HeapObjectClass.connectorTerminal.code,
    model.allocateUid(),
    children: [
      attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x42),
      attr(HeapAttribute.refListLength, HeapAttrWidth.u8, 0),
      attr(HeapAttribute.hGrowNodeListLength, HeapAttrWidth.u8, 0),
      attr(HeapAttribute.sizeExtent, HeapAttrWidth.u16, sizeExtent),
    ],
  );
  switch (_carrierClass(type)) {
    case HeapObjectClass.booleanOrClusterControl:
      return [
        if (label != null) labelPart(),
        object(
          HeapObjectClass.controlSubPart.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1936),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x15),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, HeapRect(top: 0, left: 0, bottom: h, right: w)),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0x7f00),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
            list(kPartImages, [
              worded(kPartImage, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, 0xf7c9)]),
              worded(kPartImage, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, 0xf7ca)]),
            ]),
          ],
        ),
        terminalPart(0x7d6),
      ];
    case HeapObjectClass.numericControl:
      return [
        labelPart(),
        object(
          HeapObjectClass.numericDisplay.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x161932),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0xa),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, HeapRect(top: y + 1, left: x + 1, bottom: y + h - 1, right: x + w - 1)),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xf5)]),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, kTransparent),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
            worded(kPartText, kPartTextWord, [
              attr(HeapAttribute.cosmColorB, HeapAttrWidth.rgb, 0x884412),
              attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, 0xffffff),
            ]),
            attr(HeapAttribute.formatStyle, HeapAttrWidth.rgb, 0x252e3066),
          ],
        ),
        object(
          HeapObjectClass.controlSubPart.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x193a),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0xf),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1008),
            c4Rect(HeapOpcode.bounds, HeapRect(top: y + 3, left: x - 4, bottom: y + 15, right: x + 2)),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xff),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
            list(kPartImages, [
              for (final offset in const [0xf830, 0xf82f, 0xf82e, 0xf82d, 0xf7d1])
                worded(kPartImage, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, offset)]),
            ]),
          ],
        ),
        object(
          HeapObjectClass.controlChrome.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1933),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, HeapRect(top: y, left: x, bottom: y + h, right: x + w)),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xef)]),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xff),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
          ],
        ),
        terminalPart(0x7d5),
      ];
    case HeapObjectClass.stringOrArrayControl:
      return [
        labelPart(),
        object(
          HeapObjectClass.controlLabel.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x160932),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0xb),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, HeapRect(top: 1, left: 3, bottom: h - 1, right: w - 1)),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xf5)]),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, kTransparent),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
            worded(kPartText, kPartTextWord, [
              attr(HeapAttribute.cosmColorB, HeapAttrWidth.rgb, 0x884412),
              attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, 0xffffff),
            ]),
          ],
        ),
        object(
          HeapObjectClass.controlSubPart.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x193a),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0xf),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1008),
            c4Rect(HeapOpcode.bounds, const HeapRect(top: 3, left: -4, bottom: 15, right: 2)),
            list(kPartImages, [
              for (final offset in const [0xf830, 0xf82f, 0xf82e, 0xf82d])
                worded(kPartImage, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, offset)]),
            ]),
          ],
        ),
        object(
          HeapObjectClass.controlChrome.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x913),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, HeapRect(top: 0, left: 0, bottom: h, right: w)),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xef)]),
          ],
        ),
        object(
          HeapObjectClass.connectorTerminal.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x42),
            attr(HeapAttribute.refListLength, HeapAttrWidth.u8, 0),
            attr(HeapAttribute.hGrowNodeListLength, HeapAttrWidth.u8, 0),
            attr(HeapAttribute.sizeExtent, HeapAttrWidth.u16, 0x7d7),
            attr(HeapAttribute.annexDDOFlag, HeapAttrWidth.u8, 2),
          ],
        ),
      ];
    case _:
      return [labelPart()];
  }
}

/// A constant's label part reading [label], or empty, at [labelAt] or above the constant.
HeapObjectNode _constantLabelPart(ViEditing model, String? label, HeapRect? labelAt, {required bool showLabel}) =>
    object(
      HeapObjectClass.controlLabel.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, showLabel ? kBdShownLabelFlags : kBdHiddenLabelFlags),
        attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x10),
        attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
        attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1000),
        c4Rect(HeapOpcode.bounds, labelAt ?? HeapRect(top: -17, left: 0, bottom: 0, right: bdLabelWidth(label ?? ''))),
        worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, 0xfd95)]),
        attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, kTransparent),
        attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, kTransparent),
        worded(kPartText, kPartTextWord, [
          attr(HeapAttribute.cosmColorB, HeapAttrWidth.u24, 0x14404),
          if (label == null) attr(HeapAttribute.shortText, HeapAttrWidth.u8, 0) else caption(label),
          attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, kTransparent),
        ]),
      ],
    );

/// How an array constant shows itself, relative to its bounds: its index display in [index],
/// its first element cell in [element], scrolled to [firstIndex], each element printed by the
/// C format [format] (at most four characters) and led by its radix when [showRadix]; the
/// element control carries a hidden, empty label part when [elementLabel].
class BdArrayView {
  const BdArrayView({
    required this.index,
    required this.element,
    this.firstIndex = 0,
    this.format = '%.0f',
    this.showRadix = false,
    this.elementLabel = false,
  });

  final HeapRect index;

  final HeapRect element;

  final int firstIndex;

  final String format;

  final bool showRadix;

  final bool elementLabel;

  /// The frame around the element cells.
  HeapRect get frame => HeapRect(
    top: element.top - kBdArrayFrameInset,
    left: element.left - kBdArrayFrameInset,
    bottom: element.bottom + kBdArrayFrameInset,
    right: element.right + kBdArrayFrameInset,
  );
}

/// How far an array constant's frame sits outside its element cells, and its index frame
/// outside its index display.
const int kBdArrayFrameInset = 3;

const int kBdArrayIndexFrameInset = 2;

/// An array constant's displayed first index, the counted group `0x15` in bank 2.
const int kBdArrayIndexGroup = 0x215;

/// A number format as the `formatStyle` attribute packs it: its characters big-endian.
int _formatStyle(String format) {
  if (format.length > 4) throw ArgumentError.value(format, 'format', 'is longer than four characters');
  var word = 0;
  for (final unit in format.codeUnits) {
    word = word << 8 | unit;
  }
  return word;
}

/// The parts of an array constant's shell: its index display with its arrows, the index frame,
/// the element area, the frame around the elements, and the shell's terminal.
List<HeapNode> _arrayShellParts(ViEditing model, BdArrayView view) {
  final index = view.index, iw = index.right - index.left, ih = index.bottom - index.top;
  HeapObjectNode chrome(int flags, int role, HeapRecordNode howGrow, HeapRect at, int offset, int fg) => object(
    HeapObjectClass.controlChrome.code,
    model.allocateUid(),
    children: [
      attr(HeapAttribute.objFlags, HeapAttrWidth.u16, flags),
      attr(HeapAttribute.partRole, HeapAttrWidth.u8, role),
      if (role != 9) attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
      howGrow,
      c4Rect(HeapOpcode.bounds, at),
      worded(kPartOffset, kPartOffsetWord, [
        attr(HeapAttribute.relativeOffset, offset > 0xff ? HeapAttrWidth.u16 : HeapAttrWidth.u8, offset),
      ]),
      attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, fg),
      attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
    ],
  );
  HeapObjectNode arrow(int role, HeapRecordNode howGrow, HeapRect at, int image) => object(
    HeapObjectClass.controlSubPart.code,
    model.allocateUid(),
    children: [
      attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x936),
      attr(HeapAttribute.partRole, HeapAttrWidth.u8, role),
      attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
      howGrow,
      c4Rect(HeapOpcode.bounds, at),
      attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xff),
      attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
      list(kPartImages, [
        for (var i = 0; i < 2; i++)
          worded(kPartImage, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, image)]),
      ]),
    ],
  );
  final digits = HeapRect(top: 0, left: kBdArrayIndexArrowWidth, bottom: ih, right: iw);
  final indexControl = object(
    HeapObjectClass.numericControl.code,
    model.allocateUid(),
    children: [
      attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0xc0936),
      attr(HeapAttribute.partRole, HeapAttrWidth.u16, 0x1f42),
      attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 0x1e),
      attr(HeapAttribute.howGrow, HeapAttrWidth.u8, 0x34),
      c4Rect(HeapOpcode.bounds, index),
      list(kControlParts, [
        object(
          HeapObjectClass.numericDisplay.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x40976),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0xa),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, digits),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xf5)]),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xff),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
            worded(kPartText, kPartTextWord, [
              attr(HeapAttribute.cosmFgColor, HeapAttrWidth.u16, 0x200),
              attr(HeapAttribute.cosmColorB, HeapAttrWidth.rgb, 0x884402),
              attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, 0xffffff),
            ]),
            attr(HeapAttribute.formatStyle, HeapAttrWidth.rgb, _formatStyle('%.0f')),
          ],
        ),
        arrow(
          2,
          attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1840),
          HeapRect(top: 0, left: 0, bottom: ih ~/ 2, right: kBdArrayIndexArrowWidth),
          0xff68,
        ),
        arrow(
          3,
          attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1480),
          HeapRect(top: ih ~/ 2, left: 0, bottom: ih, right: kBdArrayIndexArrowWidth),
          0xff67,
        ),
        object(
          HeapObjectClass.controlChrome.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x195f),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, digits),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xf5)]),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xff),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
          ],
        ),
        _connectorTerminalPart(model, 0x17ae),
      ]),
      attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, model.allocateTypeSlot(BdType.i32.addTo(model))),
      attr(HeapAttribute.mouseWheelSupport, HeapAttrWidth.u8, 2),
    ],
  );
  return [
    indexControl,
    chrome(
      0x957,
      0x1e,
      attr(HeapAttribute.howGrow, HeapAttrWidth.u8, 5),
      HeapRect(
        top: index.top - kBdArrayIndexFrameInset,
        left: index.left - kBdArrayIndexFrameInset,
        bottom: index.bottom + kBdArrayIndexFrameInset,
        right: index.right + kBdArrayIndexFrameInset,
      ),
      0xf5,
      0xff,
    ),
    chrome(0x977, 0x1c, attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0), view.element, 0xff11, 0xb3b3b3),
    chrome(0x955, 9, attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0), view.frame, 0xdd, 0xff),
    _connectorTerminalPart(model, 0x816),
  ];
}

/// A node's own label, shown at [at] relative to the node or above it.
HeapObjectNode _nodeLabel(ViEditing model, String text, HeapRect? at, {bool shown = true}) => object(
  HeapObjectClass.controlLabel.code,
  model.allocateUid(),
  rawTag: 0x9e,
  children: [
    attr(HeapAttribute.objFlags, HeapAttrWidth.u24, shown ? 0x170142 : 0x170142 | ViObjFlag.labelHidden.mask),
    attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x10),
    attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1000),
    c4Rect(HeapOpcode.bounds, at ?? HeapRect(top: -17, left: 0, bottom: 0, right: bdLabelWidth(text))),
    worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, 0xfd95)]),
    attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, kTransparent),
    attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, kTransparent),
    worded(kPartText, kPartTextWord, [
      attr(HeapAttribute.cosmColorB, HeapAttrWidth.u24, 0x14404),
      caption(text),
      attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, kTransparent),
    ]),
  ],
);

/// A label part's flags shown and hidden.
const int kBdShownLabelFlags = 0x170142;

const int kBdHiddenLabelFlags = 0x17114a;

/// The background of a free label and a subdiagram label.
const int kBdCommentColor = 0xffffd7;

/// How far a wire label's text sits in from its box.
const HeapRect kBdWireLabelTextInset = HeapRect(top: 0, left: 2, bottom: 0, right: 0);

/// A part's list of images and each image's group.
const int kPartImages = 0x11f;

const int kPartImage = 0x019;

/// The width of the increment and decrement arrows before an array constant's index digits.
const int kBdArrayIndexArrowWidth = 7;

/// Where an element's digits start when its radix shows before them.
const int kBdRadixDigitsLeft = 7;

HeapObjectNode _connectorTerminalPart(ViEditing model, int sizeExtent) => object(
  HeapObjectClass.connectorTerminal.code,
  model.allocateUid(),
  children: [
    attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x42),
    attr(HeapAttribute.refListLength, HeapAttrWidth.u8, 0),
    attr(HeapAttribute.hGrowNodeListLength, HeapAttrWidth.u8, 0),
    attr(HeapAttribute.sizeExtent, HeapAttrWidth.u16, sizeExtent),
  ],
);

/// The Empty String Constant's `fixedConstant` value, its glyph image and its size.
const int kBdEmptyStringConstant = 3;

const int kBdEmptyStringGlyph = 0xe0bd;

const int kBdEmptyStringConstantWidth = 18;

const int kBdEmptyStringConstantHeight = 16;

/// The control an array constant draws each element through, typed by [slot]: a numeric whose
/// radix, when shown, pushes its digits right.
HeapObjectNode _arrayElementControl(ViEditing model, BdArrayView view, int slot) {
  final e = view.element, w = e.right - e.left, h = e.bottom - e.top;
  final digitsLeft = view.showRadix ? kBdRadixDigitsLeft : 1;
  return object(
    HeapObjectClass.numericControl.code,
    model.allocateUid(),
    rawTag: HeapRefKind.ddoRef.raw,
    children: [
      attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x21000),
      c4Rect(HeapOpcode.bounds, e),
      list(kControlParts, [
        if (view.elementLabel)
          _constantLabelPart(model, null, const HeapRect(top: 1, left: -9, bottom: 18, right: 0), showLabel: false),
        object(
          HeapObjectClass.numericDisplay.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x101932),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0xa),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, HeapRect(top: 1, left: digitsLeft, bottom: h - 1, right: w - 1)),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xf5)]),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, kTransparent),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
            worded(kPartText, kPartTextWord, [
              attr(HeapAttribute.cosmFgColor, HeapAttrWidth.u16, 0x200),
              attr(HeapAttribute.cosmColorB, HeapAttrWidth.rgb, 0x884402),
              attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, 0xffffff),
            ]),
            attr(HeapAttribute.formatStyle, HeapAttrWidth.rgb, _formatStyle(view.format)),
          ],
        ),
        object(
          HeapObjectClass.controlSubPart.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, view.showRadix ? 0x1932 : 0x193a),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0xf),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1008),
            c4Rect(
              HeapOpcode.bounds,
              view.showRadix
                  ? const HeapRect(top: 3, left: 2, bottom: 15, right: 8)
                  : const HeapRect(top: 3, left: -4, bottom: 15, right: 2),
            ),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xff),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
            if (view.showRadix) attr(HeapAttribute.index90, HeapAttrWidth.u8, 1),
            list(kPartImages, [
              for (final offset in const [0xf830, 0xf82f, 0xf82e, 0xf82d, 0xf7d1])
                worded(kPartImage, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, offset)]),
            ]),
          ],
        ),
        object(
          HeapObjectClass.controlChrome.code,
          model.allocateUid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1913),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, HeapRect(top: 0, left: 0, bottom: h, right: w)),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xef)]),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xff),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
          ],
        ),
        _connectorTerminalPart(model, 0x7d5),
      ]),
      attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, slot),
      attr(HeapAttribute.mouseWheelSupport, HeapAttrWidth.u8, 2),
    ],
  );
}

/// The class of the control a constant of [type] shows its value through.
HeapObjectClass _carrierClass(BdType type) => type.dims > 0
    ? HeapObjectClass.caseOrSequence
    : switch (type.element) {
        ViDataType.boolean => HeapObjectClass.booleanOrClusterControl,
        ViDataType.string => HeapObjectClass.stringOrArrayControl,
        _ => HeapObjectClass.numericControl,
      };

/// The `constValue` record of [value] flattened as [type]: a bool, an integer or a double as
/// its big-endian bytes, a string or array behind its length word.
HeapRecordNode _constValue(BdType type, Object value) {
  if (type.dims == 0) {
    switch (value) {
      case final bool b:
        return _flatNumber(_bigEndian(b ? 1 : 0, 1));
      case final int n:
        return _flatNumber(_bigEndian(n, type.scalarSize));
      case final double d when type.element == ViDataType.dbl:
        return _flatNumber((ByteData(8)..setFloat64(0, d)).buffer.asUint8List());
      case final double d when type.element == ViDataType.sgl:
        return _flatNumber((ByteData(4)..setFloat32(0, d)).buffer.asUint8List());
      case final String s:
        return containerAttr(HeapAttribute.constValue, [
          ...(ByteData(4)..setUint32(0, s.length)).buffer.asUint8List(),
          ...s.codeUnits,
        ]);
    }
    throw ArgumentError.value(value, 'value', 'is not a $type');
  }
  if (value is! List) throw ArgumentError.value(value, 'value', 'is not a $type');
  if (type.dims != 1) throw UnsupportedError('array constants of ${type.dims} dimensions');
  final size = type.scalarSize;
  final out = ByteData(4 + size * value.length)..setUint32(0, value.length);
  for (final (i, element) in value.indexed) {
    final at = 4 + i * size;
    switch (size) {
      case 1:
        out.setUint8(at, element is bool ? (element ? 1 : 0) : element as int);
      case 2:
        out.setUint16(at, element as int);
      case 4:
        out.setUint32(at, element as int);
      case 8:
        out.setUint64(at, element as int);
    }
  }
  return containerAttr(HeapAttribute.constValue, out.buffer.asUint8List());
}

/// A number's value record: its bytes as a scalar attribute up to four of them and as a
/// container beyond, and one zero byte more when they are all zero.
HeapRecordNode _flatNumber(Uint8List bytes) {
  final payload = bytes.every((b) => b == 0) ? Uint8List(bytes.length + 1) : bytes;
  final width = switch (payload.length) {
    1 => HeapAttrWidth.u8,
    2 => HeapAttrWidth.u16,
    3 => HeapAttrWidth.u24,
    4 => HeapAttrWidth.rgb,
    _ => null,
  };
  if (width == null) return containerAttr(HeapAttribute.constValue, payload);
  return attr(HeapAttribute.constValue, width, payload.fold(0, (v, b) => (v << 8) | b));
}

Uint8List _bigEndian(int n, int size) {
  final out = ByteData(size);
  switch (size) {
    case 1:
      out.setInt8(0, n.toSigned(8));
    case 2:
      out.setInt16(0, n.toSigned(16));
    case 4:
      out.setInt32(0, n.toSigned(32));
    case 8:
      out.setInt64(0, n);
  }
  return out.buffer.asUint8List();
}

/// A front-panel control's or indicator's terminal on the diagram: the endpoint a control's
/// wire leaves from or an indicator's wire arrives at.
class BdPanelTerminal extends BdPlaced with BdEndpoint {
  BdPanelTerminal._lifted(super.frameOf, super.node) : super._lifted();

  BdPanelTerminal._create(this._type, this._name, {required bool indicator}) : _indicator = indicator, super._create();

  /// A control of [type] named [name]: on the panel once placed, its terminal where it is.
  BdPanelTerminal.control(BdType type, String name) : this._create(type, name, indicator: false);

  /// An indicator of [type] named [name]: on the panel once placed, its terminal where it is.
  BdPanelTerminal.indicator(BdType type, String name) : this._create(type, name, indicator: true);

  BdType? _type;

  String? _name;

  bool? _indicator;

  @override
  HeapObjectNode _make(ViEditing model) {
    final type = _type!, name = _name!, indicator = _indicator!;
    final index = type.addTo(model, label: name);
    final nodeSlot = model.allocateTypeSlot(index);
    final controlSlot = model.allocateTypeSlot(index);
    final panelOid = model.panel.addControl(
      model.allocateUid(),
      controlOid: model.allocateUid(),
      labelOid: model.allocateUid(),
      slot: nodeSlot,
      controlSlot: controlSlot,
      name: name,
      indicator: indicator,
    );
    return object(
      HeapObjectClass.bdLeaf.code,
      model.allocateUid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x20040 | (indicator ? kBdSinkEndpointFlag : 0)),
        ref(HeapRefKind.dcoRef, panelOid),
        c4Rect(HeapOpcode.bounds, kZeroRect),
        object(
          HeapObjectClass.controlLabel.code,
          model.allocateUid(),
          rawTag: 0x9e,
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x170142),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x10),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1000),
            c4Rect(
              HeapOpcode.bounds,
              indicator
                  ? HeapRect(
                      top: 0,
                      left: kBdPanelTerminalWidth,
                      bottom: kBdLabelHeight,
                      right: kBdPanelTerminalWidth + bdLabelWidth(name),
                    )
                  : HeapRect(top: 0, left: -bdLabelWidth(name), bottom: kBdLabelHeight, right: 0),
            ),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, 0xfd95)]),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, kTransparent),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, kTransparent),
            worded(kPartText, kPartTextWord, [
              attr(HeapAttribute.cosmFgColor, HeapAttrWidth.u24, 0x8000),
              attr(HeapAttribute.cosmColorB, HeapAttrWidth.u16, 0x4404),
              attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, kTransparent),
            ]),
          ],
        ),
      ],
    );
  }

  /// The panel object the terminal stands for.
  int? get panelOid => node.children.refs.where((r) => r.kind == HeapRefKind.dcoRef).firstOrNull?.targetOid;

  /// Whether the terminal consumes its wire: what the panel object says, else the terminal's
  /// own sink flag.
  bool get isIndicator => _indicator ??=
      (panelOid == null ? null : frameOf.model.panel.isIndicator(panelOid!)) ??
      (node.children.attr(HeapAttribute.objFlags)?.asInt ?? 0) & kBdSinkEndpointFlag != 0;

  @override
  bool get isSink => isIndicator;

  @override
  BdType? get type => _type;

  @override
  String get name => _name ?? (isPlaced ? 'panel#$oid' : 'panel (unplaced)');

  @override
  ViPoint get attachPoint {
    final b = bounds ?? kZeroRect;
    return (x: (b.left + b.right) ~/ 2, y: (b.top + b.bottom) ~/ 2);
  }

  @override
  BdSize get labelSize => _name == null ? BdSize.zero : BdSize(bdLabelWidth(_name!), kBdLabelHeight);

  @override
  set bounds(HeapRect? rect) {
    if (rect == null) throw ArgumentError.notNull('rect');
    super.bounds = HeapRect(
      top: rect.top,
      left: rect.left,
      bottom: rect.top + kBdPanelTerminalHeight,
      right: rect.left + kBdPanelTerminalWidth,
    );
  }

  @override
  String toString() => name;
}

/// A signal: the endpoints it joins and its route.
class BdWire {
  BdWire._(this.frameOf, this.node);

  final BdFrame frameOf;

  final HeapObjectNode node;

  List<BdEndpoint>? _ends;

  BdType? _type;

  int get oid => node.oid;

  /// The type the signal was wired with; null for a loaded signal.
  BdType? get type => _type;

  HeapGroupNode get _refs => node.children.group(HeapGroupTag.termList.tag)!;

  /// The endpoints the signal references, in record order.
  List<int> get endpointOids => [
    for (final ref in _refs.children.refs)
      if (ref.kind == HeapRefKind.childRef) ref.targetOid,
  ];

  /// The endpoint driving the signal, when it was wired here.
  BdEndpoint? get source => _ends?.first;

  List<BdEndpoint> get sinks => _ends?.sublist(1) ?? const [];

  int? get signalKind => node.children.attr(HeapAttribute.lastSignalKind)?.asInt;

  String? _labelText;

  /// The wire's label text, if it has one.
  String? get labelText => _labelText;

  /// Shows [text] beside the wire, placed when the wire is routed: one character kept as a
  /// `shortText` code, more as a caption.
  void label(String text) {
    _labelText = text;
    node.children.insert(
      node.children.indexOf(_refs) + 1,
      object(
        HeapObjectClass.controlLabel.code,
        frameOf.model.allocateUid(),
        rawTag: 0x9e,
        children: [
          attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x170102),
          attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x10),
          attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1000),
          c4Rect(HeapOpcode.bounds, bdTextBox(text)),
          worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, 0xfd95)]),
          attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, kTransparent),
          attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0x1000037),
          worded(kPartText, kPartTextWord, [
            attr(HeapAttribute.cosmColorB, HeapAttrWidth.rgb, 0x814404),
            text.length == 1 ? attr(HeapAttribute.shortText, HeapAttrWidth.u8, text.codeUnitAt(0)) : caption(text),
            c4Rect(HeapOpcode.rect23, kBdWireLabelTextInset),
            attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, kTransparent),
          ]),
        ],
      ),
    );
  }

  /// Moves the wire's label to [at], in its frame's coordinates.
  void placeLabel(HeapRect at) {
    for (final child in node.children.objects) {
      if (child.kind == HeapObjectClass.controlLabel.code) child.children.setBounds(at);
    }
  }

  /// Replaces the signal's route with [table].
  void route(WireTable table) {
    final children = node.children;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (child is HeapRecordNode && wireTableOfRecord(child.bytes) != null) {
        children[i] = HeapRecordNode(encodeWireTableRecord(table.encode()));
      }
    }
  }

  void _addSink(BdEndpoint sink) {
    final ends = _ends;
    if (ends == null) throw StateError('$this was loaded, not wired; its route cannot be rebuilt');
    ends.add(sink);
    _refs.children.add(ref(HeapRefKind.childRef, sink.oid));
    _refs.syncCount();
    route(bdRouteFanOut(ends.first.attachPoint, [for (final s in sinks) s.attachPoint]));
  }

  @override
  String toString() => 'wire#$oid';
}

/// The endpoint flag marking a terminal that consumes its wire, and the second one some node
/// terminals and pane indicators carry instead.
const int kBdSinkEndpointFlag = 0x8000;

const int kBdInputEndpointFlag = 0x4000;

/// The class of the data object inside a primitive's endpoint holder, an Index Array's, and
/// a Replace Array Subset's.
const int kBdNodeTerminalDcoKind = 0x30;

const int kBdIndexArrayTerminalKind = 0x45;

const int kBdReplaceArraySubsetTerminalKind = 0xba;

/// A node's terminal list and a signal's endpoint list, the counted group `0x2b` in bank 1.
const int kBdTermList = 0x12b;

/// A right shift register's list naming its left partner, and the left one's reference back.
const int kBdShiftRegisterPartnerList = 0x0ab;

const int kBdShiftRegisterPartnerRef = 0x0f7;

/// An indexing tunnel's reference from its indexer back to the tunnel.
const int kBdIndexerTunnelRef = 0x0aa;

/// A Case structure's reference to its selector terminal.
const int kBdCaseSelectorRef = 0x034;

/// A frame tunnel's reference to its partner on the neighbouring frame.
const int kBdFrameTunnelPartnerRef = 0x0b0;

/// How far neighbouring sequence frames overlap, and the grey a sequence is drawn in.
const int kBdSequenceFrameOverlap = 5;

const int kBdSequenceColor = 0xe2e2e2;

/// A Replace Array Subset's reference to its array terminal.
const int kBdReplaceArraySubsetArrayRef = 0x152;

/// A Case or Disable structure's per-frame entry group and the words its open record carries.
const int kBdCaseFrameEntry = 0x019;

const int kBdCaseFrameEntryWord = 0x3a2;

const int kBdDisableFrameEntryWord = 0x393;

const int kBdDisableFrameEntryInnerWord = 0x392;

/// The layout's spacing: a frame's padding, the space between columns and rows, the margin
/// around every object, a structure's padding (room for its count and iteration terminals
/// and a selector label), and a label's height.
const int kBdFramePadding = 16;

const int kBdColumnGap = 32;

const int kBdRowGap = 16;

const int kBdObjectMargin = 4;

const BdInsets kBdStructurePadding = BdInsets(top: 24, left: 24, bottom: 36, right: 24);

const int kBdLabelHeight = 17;

/// A panel terminal's box on the diagram.
const int kBdPanelTerminalWidth = 32;

const int kBdPanelTerminalHeight = 16;

/// Where border terminals start down a structure's side and how far apart they sit.
const int kBdFirstBorderSlot = 24;

const int kBdBorderSlotStep = 16;

/// The size of a structure placed without bounds before its body grows it.
const int kBdDefaultStructureWidth = 120;

const int kBdDefaultStructureHeight = 100;

/// A label's width in pixels at the diagram font's six-pixel advance.
int bdLabelWidth(String text) => text.length * 6 + 4;
