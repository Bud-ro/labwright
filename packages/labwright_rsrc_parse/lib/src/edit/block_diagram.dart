import 'dart:typed_data';

import '../block_tag.dart';
import '../blocks/VCTP_type_pool.dart';
import '../diagram/objects.dart';
import '../diagram/prim_ops.dart';
import '../diagram/prim_terminals.dart';
import '../diagram/wire_route.dart';
import '../heap/heap.dart';
import '../heap/heap_tree.dart';
import '../model.dart';
import '../section_buffer.dart';
import 'empty_vi.dart';
import 'front_panel.dart';
import 'records.dart';

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
  disableFrameEntries(0x228);

  const BdStructureList(this.rawId);

  final int rawId;
}

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

  static const i32 = BdType.scalar(ViDataType.i32);

  static const u8 = BdType.scalar(ViDataType.u8);

  static const u32 = BdType.scalar(ViDataType.u32);

  static const boolean = BdType.scalar(ViDataType.boolean);

  static const string = BdType.scalar(ViDataType.string);

  static const dbl = BdType.scalar(ViDataType.dbl);

  static const u8Array = BdType.array(ViDataType.u8);

  static const booleanArray = BdType.array(ViDataType.boolean);

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
  int addTo(ViModel model, {String? label}) {
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

/// The block diagram of a model as objects to place, nest and wire, over the heap's own
/// records: what was loaded keeps every record it came with, what is added is written as
/// LabVIEW writes it, and [write] puts the heap back into the model.
class BdEditor {
  BdEditor._(this.model, this.section, this.tree, HeapObjectNode root, HeapObjectNode frame)
    : _root = root,
      diagram = BdFrame._(null, frame) {
    diagram._editor = this;
  }

  /// The editor over [model]'s primary block diagram heap.
  factory BdEditor.lift(ViModel model) {
    final section = model.section(BlockTag.bdhb.tag);
    if (section == null) throw StateError('the model has no block diagram heap');
    final tree = parseHeapTree(section.bytes);
    final root = tree.objects.firstWhere((o) => o.kind == HeapObjectClass.diagramRoot.code);
    final frame = root.children.objects.firstWhere((o) => o.kind == HeapObjectClass.bdFrame.code);
    return BdEditor._(model, section, tree, root, frame);
  }

  final ViModel model;

  final ViSectionBuffer section;

  /// The heap's records; the diagram's objects live inside [diagram]'s frame.
  final List<HeapNode> tree;

  final HeapObjectNode _root;

  /// The root frame: the diagram itself.
  final BdFrame diagram;

  /// The front panel, where [control] and [indicator] put their panel objects.
  late final FpEditor panel = FpEditor.lift(model);

  int get rootOid => _root.oid;

  /// A fresh object id, which `MUID` now records.
  int allocateOid() => model.allocateUid();

  /// A new control of [type] named [name] on the panel, as its terminal in [frame], the
  /// diagram itself unless given.
  BdPanelTerminal control(BdType type, String name, {BdFrame? frame, ViPoint? at, HeapRect? labelAt}) =>
      _panelTerminal(type, name, indicator: false, frame: frame, at: at, labelAt: labelAt);

  /// A new indicator of [type] named [name] on the panel, as its terminal in [frame], the
  /// diagram itself unless given.
  BdPanelTerminal indicator(BdType type, String name, {BdFrame? frame, ViPoint? at, HeapRect? labelAt}) =>
      _panelTerminal(type, name, indicator: true, frame: frame, at: at, labelAt: labelAt);

  /// The terminal of a new panel object: 32 by 16 at [at] or laid out by its frame, its
  /// label at [labelAt] relative to it or to its left.
  BdPanelTerminal _panelTerminal(
    BdType type,
    String name, {
    required bool indicator,
    BdFrame? frame,
    ViPoint? at,
    HeapRect? labelAt,
  }) {
    final index = type.addTo(model, label: name);
    final nodeSlot = model.allocateTypeSlot(index);
    final controlSlot = model.allocateTypeSlot(index);
    final panelOid = panel.addControl(
      allocateOid(),
      controlOid: allocateOid(),
      labelOid: allocateOid(),
      slot: nodeSlot,
      controlSlot: controlSlot,
      name: name,
      indicator: indicator,
    );
    final leaf = object(
      HeapObjectClass.bdLeaf.code,
      allocateOid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x20040 | (indicator ? kBdSinkEndpointFlag : 0)),
        ref(HeapRefKind.dcoRef, panelOid),
        c4Rect(
          HeapOpcode.bounds,
          at == null
              ? kZeroRect
              : HeapRect(
                  top: at.y,
                  left: at.x,
                  bottom: at.y + kBdPanelTerminalHeight,
                  right: at.x + kBdPanelTerminalWidth,
                ),
        ),
        object(
          HeapObjectClass.controlLabel.code,
          allocateOid(),
          rawTag: 0x9e,
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, labelAt == null || labelAt.left < 0 ? 0x170142 : 0x171142),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x10),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1000),
            c4Rect(HeapOpcode.bounds, labelAt ?? HeapRect(top: 0, left: -bdLabelWidth(name), bottom: 17, right: 0)),
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
    final terminal = BdPanelTerminal._(null, leaf)
      .._type = type
      .._name = name
      .._indicator = indicator
      .._autoPlace = at == null;
    return (frame ?? diagram).add(terminal);
  }

  /// Wires [source] to [sink], typed by [type] or by whichever end declares one: a signal over
  /// the two in the frame they share, through a tunnel on every structure border between
  /// them, and joining the signal [source] already drives in its frame.
  BdWire connect(BdEndpoint source, BdEndpoint sink, {BdType? type}) {
    if (source.isSink) throw ArgumentError.value(source, 'source', 'consumes its wire');
    if (!sink.isSink) throw ArgumentError.value(sink, 'sink', 'produces its wire');
    final wireType = type ?? source.type ?? sink.type ?? _wireFrom(source)?.type;
    if (wireType == null) throw ArgumentError('neither end declares a type; pass one');
    final sourcePath = source.frameOf.ancestry, sinkPath = sink.frameOf.ancestry;
    var shared = 0;
    while (shared < sourcePath.length && shared < sinkPath.length && identical(sourcePath[shared], sinkPath[shared])) {
      shared++;
    }
    var from = source;
    for (var i = sourcePath.length - 1; i >= shared; i--) {
      final frame = sourcePath[i];
      final tunnel = frame.owner!.tunnel(wireType, output: true);
      _wire(from, tunnel.inner(frame), wireType);
      from = tunnel.outer!;
    }
    for (var i = shared; i < sinkPath.length; i++) {
      final frame = sinkPath[i];
      final tunnel = frame.owner!.tunnel(wireType, output: false);
      _wire(from, tunnel.outer!, wireType);
      from = tunnel.inner(frame);
    }
    return _wire(from, sink, wireType);
  }

  /// The signal [source] already drives, if the editor wired one.
  BdWire? _wireFrom(BdEndpoint source) =>
      source.frameOf.wires.where((wire) => wire.source?.oid == source.oid).firstOrNull;

  BdWire _wire(BdEndpoint source, BdEndpoint sink, BdType type) {
    final frame = source.frameOf;
    if (!identical(frame, sink.frameOf)) throw StateError('$source and $sink are in different frames');
    if (_wireFrom(source) case final wire?) {
      wire._addSink(sink);
      return wire;
    }
    final signal = object(
      HeapObjectClass.signal.code,
      allocateOid(),
      children: [
        list(kBdTermList, [ref(HeapRefKind.childRef, source.oid), ref(HeapRefKind.childRef, sink.oid)]),
        attr(HeapAttribute.signalState, HeapAttrWidth.u8, 1),
        HeapRecordNode(encodeWireTableRecord(bdRouteFanOut(source.attachPoint, [sink.attachPoint]).encode())),
        attr(HeapAttribute.lastSignalKind, HeapAttrWidth.u16, type.signalWord),
      ],
    );
    final wires = frame.wires;
    final signals = frame._ensureList(BdFrameList.signals);
    signals.children.add(signal);
    signals.syncCount();
    final wire = BdWire._(frame, signal)
      .._ends = [source, sink]
      .._type = type;
    wires.add(wire);
    return wire;
  }

  /// Writes the heaps back into the model's sections and rebuilds the model's diagrams.
  void write() {
    section.replace(encodeHeapTree(tree));
    for (final diagram in model.blockDiagrams) {
      if (diagram.sectionIndex == section.index) model.reloadDiagram(diagram);
    }
    panel.write();
  }

  /// The diagram heap bytes the records encode now.
  Uint8List encode() => encodeHeapTree(tree);
}

/// A frame: the diagram itself or one frame of a structure, holding placed objects, its
/// node order and its signals. Objects placed without bounds flow left to right from
/// [margin] in, [gap] apart.
class BdFrame {
  BdFrame._(this.owner, this.node);

  /// The structure this frame belongs to, null for the diagram's root frame.
  final BdStructure? owner;

  final HeapObjectNode node;

  BdEditor? _editor;

  BdEditor get editor => _editor ?? owner!.frameOf.editor;

  int get oid => node.oid;

  /// The frames from the root down to this one.
  List<BdFrame> get ancestry => [...?owner?.frameOf.ancestry, this];

  int margin = 20;

  int gap = 20;

  int _cursor = 0;

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
      editor.allocateOid(),
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
        out.add(BdPanelTerminal._(this, item));
      } else if (item.children.objects.any((o) => o.kind == HeapObjectClass.bdConstDco.code)) {
        out.add(BdConstant._(this, item));
      }
    }
    for (final object in _list(BdFrameList.objects)?.children.objects ?? const <HeapObjectNode>[]) {
      final objectClass = HeapObjectClass.fromCode(object.kind);
      out.add(switch (objectClass) {
        HeapObjectClass.bdNode || HeapObjectClass.bdNodeBd => BdPrimitive._(this, object),
        HeapObjectClass.bdNode44 => BdIndexArray._(this, object),
        HeapObjectClass.bdNodeB9 => BdReplaceArraySubset._(this, object),
        HeapObjectClass.bdForLoop || HeapObjectClass.bdWhileLoop => BdLoop._(this, object),
        HeapObjectClass.bdStructureFrame => BdCase._(this, object),
        HeapObjectClass.bdDisableStructure => BdDisable._(this, object),
        _ when objectClass.category == ViObjectKind.structure => BdStructure._(this, object),
        _ when objectClass.category == ViObjectKind.node => BdNode._(this, object),
        _ => BdPlaced._(this, object),
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

  /// Places [item] in this frame: a node or structure joins the object list and the node
  /// order, a constant or panel terminal the endpoint table; one without bounds is laid out.
  T add<T extends BdPlaced>(T item) {
    if (item._frameOf != null) throw StateError('$item is already placed');
    item._frameOf = this;
    final placed = this.placed;
    if (item is BdNode) {
      final objects = _ensureList(BdFrameList.objects);
      objects.children.add(item.node);
      objects.syncCount();
      _ensureEndpointTable();
      final nodes = _ensureList(BdFrameList.nodes);
      nodes.children.add(ref(HeapRefKind.childRef, item.oid));
      nodes.syncCount();
    } else {
      _addEntry(item.node);
      _addObjectRef(item.oid);
    }
    if (item is BdNode) {
      placed.add(item);
    } else {
      final at = placed.indexWhere((p) => p is BdNode);
      placed.insert(at < 0 ? placed.length : at, item);
    }
    if (item._autoPlace) {
      final size = item.bounds ?? kZeroRect;
      final left = margin + _cursor;
      item.bounds = HeapRect(
        top: margin,
        left: left,
        bottom: margin + size.bottom - size.top,
        right: left + size.right - size.left,
      );
      _cursor += size.right - size.left + gap;
    }
    owner?._contain(item.bounds);
    return item;
  }
}

/// Anything placed in a frame: an object with an id, a class and usually bounds.
class BdPlaced {
  BdPlaced._(BdFrame? frameOf, this.node) : _frameOf = frameOf;

  BdFrame? _frameOf;

  bool _autoPlace = false;

  /// The frame this is placed in.
  BdFrame get frameOf => _frameOf ?? (throw StateError('$this is not placed yet'));

  final HeapObjectNode node;

  int get oid => node.oid;

  HeapObjectClass get objectClass => HeapObjectClass.fromCode(node.kind);

  /// The bounds record, relative to the frame's origin; null for an object without one.
  HeapRect? get bounds => node.children.bounds;

  set bounds(HeapRect? rect) {
    if (rect == null) throw ArgumentError.notNull('rect');
    if (!node.children.setBounds(rect)) throw StateError('object $oid has no bounds record');
  }

  @override
  String toString() => '${objectClass.name}#$oid';
}

/// Where a wire can start or end: an endpoint record a signal references.
abstract class BdEndpoint {
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
  BdNode._(super.frameOf, super.node) : super._();

  /// The node's terminals in record order, outputs first as LabVIEW lists them.
  late final List<BdTerminal> terminals = [
    for (final (i, holder)
        in (node.children.group(HeapGroupTag.termList.tag)?.children.objects ?? const <HeapObjectNode>[]).indexed)
      if (holder.kind == kNodeEndpointDcoKind) BdTerminal._(this, holder, i),
  ];

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

  BdTerminal input(String name) => _named(inputs, name);

  BdTerminal output(String name) => _named(outputs, name);

  BdTerminal _named(List<BdTerminal> among, String name) => among.firstWhere(
    (t) => t.name == name,
    orElse: () => throw ArgumentError.value(name, 'name', 'no such terminal on $this'),
  );

  /// The terminals' names in record order, when the node's kind fixes them.
  List<String>? get terminalNames => null;

  /// The key the node's icon is measured under: its `primResID`, or the negated class code
  /// of a class that is one primitive.
  int? get iconKey => null;
}

/// A primitive node.
class BdPrimitive extends BdNode {
  BdPrimitive._(super.frameOf, super.node) : super._();

  /// A new node of [op], 32 by 32 at [at] or laid out by its frame, its terminals as every
  /// corpus node of the primitive draws them.
  factory BdPrimitive.create(BdEditor editor, PrimOp op, {HeapRect? at}) {
    final terminals = op.terminals;
    if (terminals == null) throw ArgumentError.value(op, 'op', 'has no measured terminals');
    final node = object(
      HeapObjectClass.bdNode.code,
      editor.allocateOid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x10000),
        list(kBdTermList, [
          for (final terminal in terminals)
            _holder(
              editor,
              input: terminal.input,
              inner: object(
                kBdNodeTerminalDcoKind,
                editor.allocateOid(),
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
        c4Rect(HeapOpcode.bounds, at ?? const HeapRect(top: 0, left: 0, bottom: 32, right: 32)),
        attr(HeapAttribute.primResID, HeapAttrWidth.u16, op.id),
      ],
    );
    return BdPrimitive._(null, node).._autoPlace = at == null;
  }

  int? get primResId => node.children.attr(HeapAttribute.primResID)?.asInt;

  PrimOp? get op => primResId == null ? null : PrimOp.fromId(primResId!);

  @override
  List<String>? get terminalNames => op?.terminalNames;

  @override
  int? get iconKey => primResId;

  @override
  String toString() => 'prim ${op?.name ?? primResId}#$oid';
}

HeapObjectNode _holder(BdEditor editor, {required bool input, required HeapObjectNode inner, int flags = 0}) => object(
  kNodeEndpointDcoKind,
  editor.allocateOid(),
  children: [
    input
        ? attr(HeapAttribute.objFlags, HeapAttrWidth.u24, kBdSinkEndpointFlag | 0x1000 | flags)
        : attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1000 | flags),
    inner,
  ],
);

/// An Index Array node: one element of an array, by index.
class BdIndexArray extends BdNode {
  BdIndexArray._(super.frameOf, super.node) : super._();

  factory BdIndexArray.create(BdEditor editor, {HeapRect? at}) {
    final array = object(
      kBdIndexArrayTerminalKind,
      editor.allocateOid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x20000),
        rectAttr(HeapAttribute.termBounds, const HeapRect(top: 0, left: 0, bottom: 18, right: 16)),
      ],
    );
    final element = object(
      kBdIndexArrayTerminalKind,
      editor.allocateOid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u8, 1),
        rectAttr(HeapAttribute.termBounds, const HeapRect(top: 0, left: 16, bottom: 27, right: 32)),
        attr(HeapAttribute.termHotPoint, HeapAttrWidth.rgb, 0x90000),
      ],
    );
    final index = object(
      kBdIndexArrayTerminalKind,
      editor.allocateOid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x600000),
        rectAttr(HeapAttribute.termBounds, const HeapRect(top: 18, left: 0, bottom: 26, right: 16)),
      ],
    );
    final node = object(
      HeapObjectClass.bdNode44.code,
      editor.allocateOid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x80000),
        list(kBdTermList, [
          _holder(editor, input: true, inner: array, flags: 0x40),
          _holder(editor, input: false, inner: element, flags: 0x40),
          _holder(editor, input: true, inner: index, flags: 0x40),
        ]),
        c4Rect(HeapOpcode.bounds, at ?? const HeapRect(top: 0, left: 0, bottom: 27, right: 32)),
        list(BdStructureList.list52.rawId, [ref(HeapRefKind.childRef, index.oid)]),
        ref(HeapRefKind.dcoAggRef, element.oid),
        ref(HeapRefKind.srcDCORef, array.oid),
      ],
    );
    return BdIndexArray._(null, node).._autoPlace = at == null;
  }

  @override
  List<String> get terminalNames => const ['array', 'element', 'index'];

  @override
  int get iconKey => -HeapObjectClass.bdNode44.code;

  @override
  String toString() => 'Index Array#$oid';
}

/// A Replace Array Subset node: an array with one element replaced, by index.
class BdReplaceArraySubset extends BdNode {
  BdReplaceArraySubset._(super.frameOf, super.node) : super._();

  factory BdReplaceArraySubset.create(BdEditor editor, {HeapRect? at}) {
    HeapObjectNode terminal(List<HeapNode> children) => object(
      kBdReplaceArraySubsetTerminalKind,
      editor.allocateOid(),
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
    final node = object(
      HeapObjectClass.bdNodeB9.code,
      editor.allocateOid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x40000),
        list(kBdTermList, [
          _holder(editor, input: true, inner: array, flags: 0x40),
          _holder(editor, input: false, inner: out, flags: 0x40),
          _holder(editor, input: true, inner: element, flags: 0x40),
          _holder(editor, input: true, inner: index, flags: 0x40),
        ]),
        c4Rect(HeapOpcode.bounds, at ?? const HeapRect(top: 0, left: 0, bottom: 33, right: 32)),
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
    return BdReplaceArraySubset._(null, node).._autoPlace = at == null;
  }

  @override
  List<String> get terminalNames => const ['array', 'output array', 'new element', 'index'];

  @override
  int get iconKey => -HeapObjectClass.bdNodeB9.code;

  @override
  String toString() => 'Replace Array Subset#$oid';
}

/// One terminal of a node: its endpoint holder, which signals reference.
class BdTerminal extends BdEndpoint {
  BdTerminal._(this.owner, this.holder, this.index);

  final BdNode owner;

  final HeapObjectNode holder;

  /// Position in the node's terminal list.
  final int index;

  @override
  HeapObjectNode get node => holder;

  @override
  BdFrame get frameOf => owner.frameOf;

  /// The terminal's rectangle within its node, from its endpoint's `termBounds`.
  HeapRect? get termBounds {
    for (final inner in holder.children.objects) {
      final rect = inner.children.attr(HeapAttribute.termBounds)?.asRect;
      if (rect != null) return rect;
    }
    return null;
  }

  /// Where a wire meets the terminal: the offset the corpus measured for the node's icon,
  /// else the middle of the terminal box.
  @override
  ViPoint get attachPoint {
    final node = owner.bounds ?? kZeroRect;
    final term = termBounds ?? kZeroRect;
    final offset = owner.iconKey == null
        ? null
        : bdPrimTerminalOffset(owner.iconKey!, index, node.right - node.left, node.bottom - node.top);
    return (
      x: node.left + (offset?.dx ?? (term.left + term.right) ~/ 2),
      y: node.top + (offset?.dy ?? (term.top + term.bottom) ~/ 2),
    );
  }

  /// The type the primitive fixes for the terminal, when it does; a measurement scalar is a
  /// time stamp.
  @override
  BdType? get type {
    final owner = this.owner;
    final terminals = owner is BdPrimitive ? owner.op?.terminals : null;
    final terminal = terminals != null && index < terminals.length ? terminals[index] : null;
    final element = terminal?.type;
    if (element == null) return null;
    if (element == ViDataType.measureData) return BdType.timestamp;
    return BdType.array(element, dims: terminal!.dims);
  }

  /// The terminal's name: the node's own, else `in0`, `out0`, … by role and order.
  @override
  String get name {
    final names = owner.terminalNames;
    if (names != null && index < names.length) return names[index];
    final peers = isSink ? owner.inputs : owner.outputs;
    return '${isSink ? 'in' : 'out'}${peers.indexOf(this)}';
  }

  @override
  String toString() => '$owner.$name';
}

/// An endpoint that is an endpoint-table entry or a structure's holder: a constant's, a panel
/// terminal's or a border terminal's.
class BdPort extends BdEndpoint {
  BdPort._(this.frameOf, this.node, {required this.name, required this.type, required ViPoint Function() attach})
    : _attach = attach;

  @override
  final BdFrame frameOf;

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
  selector(HeapObjectClass.bdSelectorTerminal, 'selector');

  const BdBorderKind(this.objectClass, this.label);

  final HeapObjectClass objectClass;

  final String label;

  static BdBorderKind? ofCode(int code) => values.where((k) => k.objectClass.code == code).firstOrNull;
}

/// A terminal on a structure's border: its object, the holder that is its outer endpoint,
/// and its inner endpoint in each frame.
class BdStructureTerminal {
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

  final int? _slot;

  String get name => kind.label;

  /// The endpoint outside the structure, in the structure's frame; null when there is none.
  late final BdPort? outer = holder == null
      ? null
      : BdPort._(owner.frameOf, holder!, name: '$owner.$name', type: _type, attach: _outerAttach);

  /// The endpoint inside [frame].
  BdPort inner(BdFrame frame) {
    final entry = _inners[frame.oid];
    if (entry == null) throw ArgumentError.value(frame, 'frame', '$owner.$name has no endpoint in it');
    return entry;
  }

  /// The endpoint inside the structure's only frame.
  BdPort get innerPort => _inners.values.single;

  List<BdPort> get inners => _inners.values.toList();

  late final Map<int, BdPort> _inners = () {
    final out = <int, BdPort>{};
    final members = [
      for (final r in terminal.children.group(HeapGroupTag.termList.tag)?.children.refs ?? const <HeapRef>[])
        if (r.kind == HeapRefKind.childRef) r.targetOid,
    ];
    for (final frame in owner.frames) {
      for (final member in members) {
        final entry = frame._entry(member);
        if (entry != null) {
          out[frame.oid] = BdPort._(frame, entry, name: '$owner.$name.inner', type: _innerType, attach: _innerAttach);
        }
      }
    }
    return out;
  }();

  HeapRect get termBounds => terminal.children.attr(HeapAttribute.termBounds)?.asRect ?? kZeroRect;

  /// Moves the terminal's box within its structure.
  set termBounds(HeapRect rect) {
    final children = terminal.children;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (child is HeapRecordNode && decodeHeapAttr(child.bytes, 0)?.attribute == HeapAttribute.termBounds) {
        children[i] = rectAttr(HeapAttribute.termBounds, rect);
      }
    }
  }

  /// Whether a loop tunnel indexes: reads or builds one element per iteration.
  bool get indexing => terminal.children.objects.any(
    (o) => o.kind == HeapObjectClass.bdTunnelIndexer.code && (o.children.attr(HeapAttribute.objFlags)?.asInt ?? 0) != 0,
  );

  bool get isInput => outer?.isSink ?? false;

  ViPoint _innerAttach() {
    final t = termBounds;
    return (x: (t.left + t.right) ~/ 2, y: (t.top + t.bottom) ~/ 2);
  }

  ViPoint _outerAttach() {
    final t = termBounds;
    final s = owner.bounds ?? kZeroRect;
    return (x: s.left + (t.left + t.right) ~/ 2, y: s.top + (t.top + t.bottom) ~/ 2);
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
  BdStructure._(super.frameOf, super.node) : super._();

  BdEditor? _creator;

  BdEditor get _editor => _creator ?? frameOf.editor;

  bool _grows = false;

  int _leftSlot = kBdFirstBorderSlot;

  int _rightSlot = kBdFirstBorderSlot;

  /// The structure's frames in record order.
  late final List<BdFrame> frames = [
    for (final child in node.children.objects)
      if (child.kind == HeapObjectClass.bdFrame.code) BdFrame._(this, child),
    for (final group in node.children.whereType<HeapGroupNode>())
      for (final child in group.children.objects)
        if (child.kind == HeapObjectClass.bdFrame.code) BdFrame._(this, child),
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

  HeapGroupNode _group(BdStructureList which) {
    final group = node.children.whereType<HeapGroupNode>().where((g) => g.rawId == which.rawId).firstOrNull;
    if (group == null) throw StateError('$this has no ${which.name} list');
    return group;
  }

  /// The rectangle the structure's inside is drawn in.
  HeapRect get typeBounds => node.children.c4(HeapOpcode.typeBounds)?.rect ?? kZeroRect;

  /// How far the inside sits in from the bounds on each side.
  HeapRect get _typeInset => const HeapRect(top: 1, left: 1, bottom: 1, right: 1);

  @override
  set bounds(HeapRect? rect) {
    super.bounds = rect;
    final r = rect!, inset = _typeInset;
    final typeRect = HeapRect(
      top: r.top + inset.top,
      left: r.left + inset.left,
      bottom: r.bottom - inset.bottom,
      right: r.right - inset.right,
    );
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

  /// Grows the structure to keep [rect], in its inside's coordinates, within its margin.
  void _contain(HeapRect? rect) {
    if (!_grows || rect == null) return;
    final s = bounds!;
    final margin = frames.first.margin;
    final right = rect.right + margin + s.left, bottom = rect.bottom + margin + s.top;
    if (right <= s.right && bottom <= s.bottom) return;
    bounds = HeapRect(
      top: s.top,
      left: s.left,
      bottom: bottom > s.bottom ? bottom : s.bottom,
      right: right > s.right ? right : s.right,
    );
    frameOf.owner?._contain(bounds);
  }

  /// A new tunnel of [type] through the border, carrying a value in or out; indexing on a
  /// loop reads or builds one element per iteration.
  BdStructureTerminal tunnel(BdType type, {required bool output, bool indexing = false, int? top}) =>
      throw UnsupportedError('$this takes no tunnels');

  /// The box of the next tunnel down the left or right side, at [top] or the next free row.
  HeapRect _nextSlot({required bool right, int? top}) {
    final s = bounds ?? kZeroRect;
    final y = top ?? (right ? _rightSlot : _leftSlot);
    if (top == null && right) {
      _rightSlot += kBdBorderSlotStep;
    } else if (top == null) {
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
    final editor = _editor;
    final borderTerminals = this.borderTerminals;
    final holder = holderFlags == 0
        ? null
        : object(
            kNodeEndpointDcoKind,
            editor.allocateOid(),
            children: [attr(HeapAttribute.objFlags, holderWidth, holderFlags), terminal],
          );
    final refs = terminal.children.group(HeapGroupTag.termList.tag)!;
    for (final frame in inFrames ?? frames) {
      final entry = object(
        kNodeEndpointDcoKind,
        editor.allocateOid(),
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

  static HeapObjectNode _frameNode(BdEditor editor) => object(
    HeapObjectClass.bdFrame.code,
    editor.allocateOid(),
    children: [
      list(BdFrameList.objects.rawId),
      list(BdFrameList.nodes.rawId, [
        object(
          HeapObjectClass.bdWire.code,
          editor.allocateOid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1000),
            list(kBdTermList),
            c4Rect(HeapOpcode.bounds, kZeroRect),
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
  BdLoop._(super.frameOf, super.node) : super._();

  /// A new loop at [at] or laid out by its frame, growing around what its body takes: a For
  /// loop with its count and iteration terminals, a While loop with its iteration and
  /// conditional terminals.
  factory BdLoop.create(BdEditor editor, {bool isFor = true, HeapRect? at}) {
    final bounds =
        at ?? const HeapRect(top: 0, left: 0, bottom: kBdDefaultStructureHeight, right: kBdDefaultStructureWidth);
    final frame = BdStructure._frameNode(editor);
    final node = object(
      isFor ? HeapObjectClass.bdForLoop.code : HeapObjectClass.bdWhileLoop.code,
      editor.allocateOid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, isFor ? 0x10000000 : 0x10005280),
        list(kBdTermList),
        c4Rect(HeapOpcode.bounds, bounds),
        c4Rect(HeapOpcode.typeBounds, BdStructure._inset(bounds, isFor ? kBdForLoopInset : kBdWhileLoopInset)),
        list(BdStructureList.tunnels.rawId),
        list(BdStructureList.frames.rawId, [frame]),
        if (!isFor) attr(HeapAttribute.structColor, HeapAttrWidth.rgb, 0x7f7f7f),
      ],
    );
    final loop = BdLoop._(null, node)
      .._creator = editor
      .._autoPlace = at == null
      .._grows = at == null;
    if (isFor) {
      final count = object(
        HeapObjectClass.bdCountTerminal.code,
        editor.allocateOid(),
        rawTag: HeapRefKind.dcoRef.raw,
        children: [
          list(kBdTermList),
          attr(HeapAttribute.dcoFiller, HeapAttrWidth.u16, 0x200),
          rectAttr(HeapAttribute.termBounds, kZeroRect),
          attr(HeapAttribute.termBMPs, HeapAttrWidth.u8, 2),
        ],
      );
      loop._addBorderTerminal(
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
    loop._addBorderTerminal(
      BdBorderKind.iteration,
      object(
        HeapObjectClass.bdIterationTerminal.code,
        editor.allocateOid(),
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
      node.children.add(ref(HeapRefKind.loopLimitDCORef, loop.count!.terminal.oid));
    } else {
      loop._addBorderTerminal(
        BdBorderKind.conditional,
        object(
          HeapObjectClass.bdConditionalTerminal.code,
          editor.allocateOid(),
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
    return loop;
  }

  bool get isFor => node.kind == HeapObjectClass.bdForLoop.code;

  @override
  HeapRect get _typeInset => isFor ? kBdForLoopInset : kBdWhileLoopInset;

  BdFrame get body => frames.single;

  /// A For loop's count terminal, wired from outside.
  BdStructureTerminal? get count => _borderTerminal(BdBorderKind.count);

  /// The iteration terminal inside the body.
  BdStructureTerminal get iteration => _borderTerminal(BdBorderKind.iteration)!;

  /// A While loop's conditional terminal inside the body.
  BdStructureTerminal? get conditional => _borderTerminal(BdBorderKind.conditional);

  @override
  BdStructureTerminal tunnel(BdType type, {required bool output, bool indexing = false, int? top}) {
    final editor = _editor;
    final slot = _nextSlot(right: output, top: top);
    final refs = list(kBdTermList);
    final terminal = object(
      HeapObjectClass.bdLoopTunnel.code,
      editor.allocateOid(),
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
    final countHolder = indexing && !output ? count?.holder : null;
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
          editor.allocateOid(),
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
  BdShiftRegister shiftRegister(BdType type, {int? top}) {
    final editor = _editor;
    final y = top ?? _leftSlot;
    if (top == null) {
      _leftSlot += kBdBorderSlotStep;
      _rightSlot += kBdBorderSlotStep;
    }
    final rightOid = editor.allocateOid(), leftOid = editor.allocateOid();
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
  String toString() => '${isFor ? 'For' : 'While'} loop#$oid';
}

/// A Case structure.
class BdCase extends BdStructure {
  BdCase._(super.frameOf, super.node) : super._();

  /// A new Case structure over a boolean selector with [frameCount] frames, False first,
  /// showing [displayed].
  factory BdCase.create(BdEditor editor, {int frameCount = 2, int? displayed, HeapRect? at}) {
    final bounds =
        at ?? const HeapRect(top: 0, left: 0, bottom: kBdDefaultStructureHeight, right: kBdDefaultStructureWidth);
    final frames = [for (var i = 0; i < frameCount; i++) BdStructure._frameNode(editor)];
    final shown = displayed ?? frameCount - 1;
    final labelText = ' ${shown == 0 ? 'False' : 'True'} ';
    final labelWidth = bdLabelWidth(labelText);
    final width = bounds.right - bounds.left;
    final node = object(
      HeapObjectClass.bdStructureFrame.code,
      editor.allocateOid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, 0x10010000),
        list(kBdTermList),
        c4Rect(HeapOpcode.bounds, bounds),
        c4Rect(HeapOpcode.typeBounds, BdStructure._inset(bounds, kBdCaseInset)),
        list(BdStructureList.tunnels.rawId),
        attr(HeapAttribute.dIdx, HeapAttrWidth.u8, shown),
        list(BdStructureList.frames.rawId, frames),
      ],
    );
    final structure = BdCase._(null, node)
      .._creator = editor
      .._autoPlace = at == null
      .._grows = at == null;
    final selector = object(
      HeapObjectClass.bdSelectorTerminal.code,
      editor.allocateOid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        list(kBdTermList),
        rectAttr(HeapAttribute.termBounds, kZeroRect),
        attr(HeapAttribute.termBMPs, HeapAttrWidth.u8, 5),
      ],
    );
    structure._addBorderTerminal(
      BdBorderKind.selector,
      selector,
      holderFlags: 0x409040,
      holderWidth: HeapAttrWidth.u24,
      innerFlags: 0x420000,
      type: BdType.boolean,
      side: BdBorderSide.left,
      slot: structure._nextSlot(right: false).top,
    );
    node.children.addAll([
      rawRef(kBdCaseSelectorRef, selector.oid),
      object(
        HeapObjectClass.bdSelectorLabel.code,
        editor.allocateOid(),
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
        for (var i = 0; i < frameCount; i++)
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
    return structure;
  }

  @override
  HeapRect get _typeInset => kBdCaseInset;

  /// The selector terminal, wired from outside.
  BdStructureTerminal get selector => _borderTerminal(BdBorderKind.selector)!;

  @override
  BdStructureTerminal tunnel(BdType type, {required bool output, bool indexing = false, int? top}) {
    if (indexing) throw ArgumentError.value(indexing, 'indexing', 'a Case tunnel does not index');
    final editor = _editor;
    final slot = _nextSlot(right: output, top: top);
    final terminal = object(
      HeapObjectClass.bdCaseTunnel.code,
      editor.allocateOid(),
      rawTag: HeapRefKind.dcoRef.raw,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x800 | (output ? 1 : 0)),
        list(kBdTermList),
        rectAttr(HeapAttribute.termBounds, slot),
      ],
    );
    final border = _addBorderTerminal(
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
  String toString() => 'Case#$oid';
}

/// A Diagram Disable structure: its first frame disabled, its second enabled.
class BdDisable extends BdStructure {
  BdDisable._(super.frameOf, super.node) : super._();

  factory BdDisable.create(BdEditor editor, {HeapRect? at}) {
    final bounds =
        at ?? const HeapRect(top: 0, left: 0, bottom: kBdDefaultStructureHeight, right: kBdDefaultStructureWidth);
    const labelText = ' Disabled ';
    final labelWidth = bdLabelWidth(labelText);
    final width = bounds.right - bounds.left;
    final node = object(
      HeapObjectClass.bdDisableStructure.code,
      editor.allocateOid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, 0x10010000),
        list(kBdTermList),
        c4Rect(HeapOpcode.bounds, bounds),
        c4Rect(HeapOpcode.typeBounds, BdStructure._inset(bounds, kBdDisableInset)),
        list(BdStructureList.tunnels.rawId),
        list(BdStructureList.frames.rawId, [BdStructure._frameNode(editor), BdStructure._frameNode(editor)]),
        object(
          HeapObjectClass.bdSelectorLabel.code,
          editor.allocateOid(),
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
    return BdDisable._(null, node)
      .._creator = editor
      .._autoPlace = at == null
      .._grows = at == null;
  }

  BdFrame get disabled => frames[0];

  BdFrame get enabled => frames[1];

  @override
  String toString() => 'Disable#$oid';
}

/// A constant: an endpoint-table entry holding its own data object.
class BdConstant extends BdPlaced {
  BdConstant._(super.frameOf, super.node) : super._();

  /// A new constant of [type] holding [value]: a number, a bool, a string, or a list of
  /// numbers or bools for an array; [label] names it on the diagram.
  factory BdConstant.create(BdEditor editor, BdType type, Object value, {String? label, HeapRect? at}) {
    final model = editor.model;
    final index = type.addTo(model, label: label);
    final slot = model.allocateTypeSlot(index);
    final controlSlot = model.allocateTypeSlot(index);
    final bounds =
        at ??
        (type.element == ViDataType.boolean && type.dims == 0
            ? const HeapRect(top: 0, left: 0, bottom: 14, right: 16)
            : const HeapRect(top: 0, left: 0, bottom: 19, right: 36));
    final entry = object(
      kNodeEndpointDcoKind,
      editor.allocateOid(),
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x20040),
        object(
          HeapObjectClass.bdConstDco.code,
          editor.allocateOid(),
          rawTag: HeapRefKind.dcoRef.raw,
          children: [
            attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, slot),
            attr(HeapAttribute.dsw, HeapAttrWidth.u16, 0x1000),
            object(
              _carrierClass(type).code,
              editor.allocateOid(),
              rawTag: HeapRefKind.ddoRef.raw,
              children: [
                switch (_carrierClass(type)) {
                  HeapObjectClass.booleanOrClusterControl => attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1004),
                  HeapObjectClass.caseOrSequence => attr(HeapAttribute.objFlags, HeapAttrWidth.u8, 4),
                  _ => attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x60000),
                },
                c4Rect(HeapOpcode.bounds, bounds),
                list(kControlParts, _constantParts(editor, type, label, bounds)),
                attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, controlSlot),
                attr(HeapAttribute.mouseWheelSupport, HeapAttrWidth.u8, 2),
              ],
            ),
            _constValue(type, value),
          ],
        ),
      ],
    );
    return BdConstant._(null, entry)
      .._type = type
      .._autoPlace = at == null;
  }

  BdType? _type;

  HeapObjectNode get data => node.children.objects.firstWhere((o) => o.kind == HeapObjectClass.bdConstDco.code);

  HeapObjectNode get _control => data.children.objects.first;

  @override
  HeapRect? get bounds => _control.children.bounds;

  @override
  set bounds(HeapRect? rect) {
    if (rect == null) throw ArgumentError.notNull('rect');
    _control.children.setBounds(rect);
  }

  /// The constant's one endpoint: the entry itself.
  late final BdPort out = BdPort._(
    frameOf,
    node,
    name: 'constant#$oid',
    type: _type,
    attach: () {
      final b = bounds ?? kZeroRect;
      return (x: (b.left + b.right) ~/ 2, y: (b.top + b.bottom) ~/ 2);
    },
  );

  @override
  String toString() => 'constant#$oid';
}

/// The parts of a constant's control: a numeric's label, display, increment buttons, frame
/// and terminal; a boolean's button and terminal, with a label only when it has one.
List<HeapNode> _constantParts(BdEditor editor, BdType type, String? label, HeapRect bounds) {
  final w = bounds.right - bounds.left, h = bounds.bottom - bounds.top;
  HeapObjectNode labelPart() => object(
    HeapObjectClass.controlLabel.code,
    editor.allocateOid(),
    children: [
      attr(HeapAttribute.objFlags, HeapAttrWidth.u24, label == null ? 0x17114a : 0x170142),
      attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x10),
      attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
      attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1000),
      c4Rect(HeapOpcode.bounds, HeapRect(top: -17, left: 0, bottom: 0, right: bdLabelWidth(label ?? ''))),
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
  HeapObjectNode terminalPart(int sizeExtent) => object(
    HeapObjectClass.connectorTerminal.code,
    editor.allocateOid(),
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
          editor.allocateOid(),
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
          editor.allocateOid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x161932),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0xa),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, HeapRect(top: 1, left: 1, bottom: h - 1, right: w - 1)),
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
          editor.allocateOid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x193a),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0xf),
            attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1008),
            c4Rect(HeapOpcode.bounds, const HeapRect(top: 3, left: -4, bottom: 15, right: 2)),
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
          editor.allocateOid(),
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0x1933),
            attr(HeapAttribute.partRole, HeapAttrWidth.u8, 9),
            attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
            c4Rect(HeapOpcode.bounds, HeapRect(top: 0, left: 0, bottom: h, right: w)),
            worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xef)]),
            attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xff),
            attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
          ],
        ),
        terminalPart(0x7d5),
      ];
    case _:
      return [labelPart()];
  }
}

/// A part's list of images and each image's group.
const int kPartImages = 0x11f;

const int kPartImage = 0x019;

/// The class of the control a constant of [type] shows its value through.
HeapObjectClass _carrierClass(BdType type) => type.dims > 0
    ? HeapObjectClass.caseOrSequence
    : switch (type.element) {
        ViDataType.boolean => HeapObjectClass.booleanOrClusterControl,
        ViDataType.string => HeapObjectClass.stringOrArrayControl,
        _ => HeapObjectClass.numericControl,
      };

/// The `constValue` record of [value] flattened as [type]: a bool as one byte when true and a
/// zero word when false, a number as its width, a string or array behind its length word.
HeapRecordNode _constValue(BdType type, Object value) {
  if (type.dims == 0) {
    switch (value) {
      case final bool b:
        return b
            ? attr(HeapAttribute.constValue, HeapAttrWidth.u8, 1)
            : attr(HeapAttribute.constValue, HeapAttrWidth.u16, 0);
      case final int n:
        return switch (type.scalarSize) {
          1 =>
            n == 0
                ? attr(HeapAttribute.constValue, HeapAttrWidth.u16, 0)
                : attr(HeapAttribute.constValue, HeapAttrWidth.u8, n),
          2 => attr(HeapAttribute.constValue, HeapAttrWidth.u16, n),
          _ => attr(HeapAttribute.constValue, HeapAttrWidth.rgb, n),
        };
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

/// A front-panel control's or indicator's terminal on the diagram.
class BdPanelTerminal extends BdPlaced {
  BdPanelTerminal._(super.frameOf, super.node) : super._();

  BdType? _type;

  String? _name;

  bool? _indicator;

  /// The panel object the terminal stands for.
  int? get panelOid => node.children.refs.where((r) => r.kind == HeapRefKind.dcoRef).firstOrNull?.targetOid;

  /// Whether the terminal consumes its wire: what the panel object says, else the terminal's
  /// own sink flag.
  bool get isIndicator => _indicator ??=
      (panelOid == null ? null : frameOf.editor.panel.isIndicator(panelOid!)) ??
      (node.children.attr(HeapAttribute.objFlags)?.asInt ?? 0) & kBdSinkEndpointFlag != 0;

  /// The terminal's one endpoint: a control's output or an indicator's input.
  late final BdPort terminal = BdPort._(
    frameOf,
    node,
    name: _name ?? 'panel#$oid',
    type: _type,
    attach: () {
      final b = bounds ?? kZeroRect;
      return (x: (b.left + b.right) ~/ 2, y: (b.top + b.bottom) ~/ 2);
    },
  );

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
  String toString() => _name ?? 'panel#$oid';
}

/// A signal: the endpoints it joins and its route.
class BdWire {
  BdWire._(this.frameOf, this.node);

  final BdFrame frameOf;

  final HeapObjectNode node;

  List<BdEndpoint>? _ends;

  BdType? _type;

  int get oid => node.oid;

  /// The type the editor wired the signal with; null for a loaded signal.
  BdType? get type => _type;

  HeapGroupNode get _refs => node.children.group(HeapGroupTag.termList.tag)!;

  /// The endpoints the signal references, in record order.
  List<int> get endpointOids => [
    for (final ref in _refs.children.refs)
      if (ref.kind == HeapRefKind.childRef) ref.targetOid,
  ];

  /// The endpoint driving the signal, when the editor wired it.
  BdEndpoint? get source => _ends?.first;

  List<BdEndpoint> get sinks => _ends?.sublist(1) ?? const [];

  int? get signalKind => node.children.attr(HeapAttribute.lastSignalKind)?.asInt;

  void _addSink(BdEndpoint sink) {
    final ends = _ends;
    if (ends == null) throw StateError('$this was loaded, not wired; its route cannot be rebuilt');
    ends.add(sink);
    _refs.children.add(ref(HeapRefKind.childRef, sink.oid));
    _refs.syncCount();
    final table = bdRouteFanOut(ends.first.attachPoint, [for (final s in sinks) s.attachPoint]).encode();
    final children = node.children;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (child is HeapRecordNode && wireTableOfRecord(child.bytes) != null) {
        children[i] = HeapRecordNode(encodeWireTableRecord(table));
      }
    }
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

/// A Replace Array Subset's reference to its array terminal.
const int kBdReplaceArraySubsetArrayRef = 0x152;

/// A Case or Disable structure's per-frame entry group and the words its open record carries.
const int kBdCaseFrameEntry = 0x019;

const int kBdCaseFrameEntryWord = 0x3a2;

const int kBdDisableFrameEntryWord = 0x393;

const int kBdDisableFrameEntryInnerWord = 0x392;

/// How far a structure's inside sits in from its bounds: a For loop's one pixel at the top
/// and left and five at the bottom and right, a While loop's and a Case structure's six all
/// round, a Disable structure's one.
const HeapRect kBdForLoopInset = HeapRect(top: 1, left: 1, bottom: 5, right: 5);

const HeapRect kBdWhileLoopInset = HeapRect(top: 6, left: 6, bottom: 6, right: 6);

const HeapRect kBdCaseInset = HeapRect(top: 6, left: 6, bottom: 6, right: 6);

const HeapRect kBdDisableInset = HeapRect(top: 1, left: 1, bottom: 1, right: 1);

/// A panel terminal's box on the diagram.
const int kBdPanelTerminalWidth = 32;

const int kBdPanelTerminalHeight = 16;

/// Where border terminals start down a structure's side and how far apart they sit.
const int kBdFirstBorderSlot = 24;

const int kBdBorderSlotStep = 16;

/// The size of a structure placed without bounds before its body grows it.
const int kBdDefaultStructureWidth = 120;

const int kBdDefaultStructureHeight = 100;

/// A label's width in pixels at the diagram font's seven-pixel advance.
int bdLabelWidth(String text) => text.length * 7;

/// The compressed table of a wire from [from] to each of [sinks]: a straight run or one
/// turn to a single sink; to several, a run right to a junction that forks up, down or on.
WireTable bdRouteFanOut(ViPoint from, List<ViPoint> sinks) {
  if (sinks.length == 1) return _bdRouteBetween(from, sinks.single);
  final byDirection = <WireRouteDirection, ViPoint>{};
  for (final sink in sinks) {
    final direction = sink.y == from.y
        ? WireRouteDirection.right
        : sink.y < from.y
        ? WireRouteDirection.up
        : WireRouteDirection.down;
    if (byDirection.containsKey(direction)) {
      final points = [from];
      for (final sink in sinks) {
        points.addAll([(x: sink.x, y: points.last.y), sink]);
      }
      return _bdRoutePolyline(points);
    }
    byDirection[direction] = sink;
  }
  var nearest = sinks.first.x;
  for (final sink in sinks) {
    if (sink.x < nearest) nearest = sink.x;
  }
  final junctionX = from.x + ((nearest - from.x) ~/ 2).clamp(4, 1 << 15);
  final junction = switch (byDirection.keys.toSet()) {
    final set when set.length == 3 => WireRouteJunction.cross,
    final set when set.contains(WireRouteDirection.up) && set.contains(WireRouteDirection.down) =>
      WireRouteJunction.upDown,
    final set when set.contains(WireRouteDirection.up) => WireRouteJunction.upRight,
    _ => WireRouteJunction.downRight,
  };
  final modes = <int>[WireRouteDirection.right.code, junction.code];
  final lengths = <int>[junctionX - from.x];
  for (final (i, direction) in junction.outgoing.indexed) {
    final sink = byDirection[direction]!;
    if (i > 0) modes.add(ViWireBranchRoute.popCode);
    if (direction == WireRouteDirection.right) {
      lengths.add(sink.x - junctionX);
    } else {
      lengths.add((sink.y - from.y).abs());
      modes.add(sink.x >= junctionX ? 0 : 1);
      lengths.add((sink.x - junctionX).abs());
    }
  }
  return WireTable(modes.length + 1, header: const [], modes: modes, lengths: lengths);
}

WireTable _bdRouteBetween(ViPoint from, ViPoint to) {
  final dx = to.x - from.x, dy = to.y - from.y;
  if (dy == 0) return WireTable(2, modes: [(dx >= 0 ? WireRouteDirection.right : WireRouteDirection.left).code]);
  if (dx == 0) return WireTable(2, modes: [(dy >= 0 ? WireRouteDirection.down : WireRouteDirection.up).code]);
  return _bdRoutePolyline([from, (x: to.x, y: from.y), to]);
}

/// The plain table of an axis-aligned polyline: the first direction, a turn sign per later
/// segment, and every length but the last.
WireTable _bdRoutePolyline(List<ViPoint> points) {
  final modes = <int>[], lengths = <int>[];
  var horizontal = true;
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1], b = points[i];
    final dx = b.x - a.x, dy = b.y - a.y;
    if (i == 1) {
      horizontal = dy == 0;
      modes.add(
        (horizontal
                ? (dx >= 0 ? WireRouteDirection.right : WireRouteDirection.left)
                : (dy >= 0 ? WireRouteDirection.down : WireRouteDirection.up))
            .code,
      );
    } else {
      horizontal = !horizontal;
      modes.add((horizontal ? dx : dy) >= 0 ? 0 : 1);
    }
    if (i < points.length - 1) lengths.add((horizontal ? dx : dy).abs());
  }
  return WireTable(points.length, modes: modes, lengths: lengths);
}
