import 'dart:typed_data';

import '../block_tag.dart';
import '../diagram/objects.dart';
import '../diagram/prim_ops.dart';
import '../diagram/wire_route.dart';
import '../heap/heap.dart';
import '../heap/heap_tree.dart';
import '../model.dart';
import '../section_buffer.dart';

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

  int get rootOid => _root.oid;

  /// A fresh object id, which `MUID` now records.
  int allocateOid() => model.allocateUid();

  /// Wires [source] to [sink] in the frame they share: a signal over the two endpoints with a
  /// route from one to the other, typed by [type], the signal's type word.
  BdWire connect(BdTerminal source, BdTerminal sink, {required int type}) {
    if (source.isSink) throw ArgumentError.value(source, 'source', 'consumes its wire');
    if (!sink.isSink) throw ArgumentError.value(sink, 'sink', 'produces its wire');
    final frame = source.owner.frameOf;
    if (!identical(frame, sink.owner.frameOf)) throw ArgumentError('the two terminals are in different frames');
    final route = bdRouteBetween(source.attachPoint, sink.attachPoint);
    final signal = HeapObjectNode.create(
      HeapObjectClass.signal.code,
      allocateOid(),
      children: [
        HeapGroupNode.counted(
          kBdTermList,
          children: [
            HeapRecordNode(encodeHeapRef(0x14, HeapRefKind.childRef.raw & 0xff, source.oid)),
            HeapRecordNode(encodeHeapRef(0x14, HeapRefKind.childRef.raw & 0xff, sink.oid)),
          ],
        ),
        HeapRecordNode(encodeHeapScalarAttr(HeapAttribute.signalState.raw, HeapAttrWidth.u8, 1)),
        HeapRecordNode(encodeWireTableRecord(route.encode())),
        HeapRecordNode(encodeHeapScalarAttr(HeapAttribute.lastSignalKind.raw, HeapAttrWidth.u16, type)),
      ],
    );
    final signals = frame._list(BdFrameList.signals);
    signals.children.add(signal);
    signals.syncCount();
    final wire = BdWire._(frame, signal);
    frame.wires.add(wire);
    return wire;
  }

  /// Writes the heap back into the model's section and rebuilds the model's diagram from it.
  void write() {
    section.replace(encodeHeapTree(tree));
    for (final diagram in model.blockDiagrams) {
      if (diagram.sectionIndex == section.index) model.reloadDiagram(diagram);
    }
  }

  /// The heap bytes the records encode now.
  Uint8List encode() => encodeHeapTree(tree);
}

/// A frame: the diagram itself or one frame of a structure, holding placed objects, its
/// node order and its signals.
class BdFrame {
  BdFrame._(this.owner, this.node);

  /// The structure this frame belongs to, null for the diagram's root frame.
  final BdStructure? owner;

  final HeapObjectNode node;

  BdEditor? _editor;

  BdEditor get editor => _editor ?? owner!.frameOf.editor;

  int get oid => node.oid;

  HeapGroupNode _list(BdFrameList list) {
    final group = node.children.group(list.tag);
    if (group == null) throw StateError('frame ${node.oid} has no ${list.name} list');
    return group;
  }

  /// The endpoint table: the frame's wire object, whose terminal list declares the panel
  /// terminals, the constants and the structure-terminal endpoints signals reach.
  HeapObjectNode get endpointTable =>
      _list(BdFrameList.nodes).children.objects.firstWhere((o) => o.kind == HeapObjectClass.bdWire.code);

  List<HeapNode> get _endpoints => endpointTable.children.group(HeapGroupTag.termList.tag)!.children;

  /// Everything placed in the frame, in record order.
  late final List<BdPlaced> placed = _lift();

  List<BdPlaced> _lift() {
    final out = <BdPlaced>[];
    for (final item in _endpoints.objects) {
      if (item.kind == HeapObjectClass.bdLeaf.code) {
        out.add(BdPanelTerminal._(this, item));
      } else if (item.children.objects.any((o) => o.kind == HeapObjectClass.bdConstDco.code)) {
        out.add(BdConstant._(this, item));
      }
    }
    for (final object in _list(BdFrameList.objects).children.objects) {
      final objectClass = HeapObjectClass.fromCode(object.kind);
      out.add(switch (objectClass) {
        HeapObjectClass.bdNode || HeapObjectClass.bdNodeBd => BdPrimitive._(this, object),
        HeapObjectClass.bdForLoop || HeapObjectClass.bdWhileLoop => BdLoop._(this, object),
        HeapObjectClass.bdStructureFrame => BdCase._(this, object),
        _ when objectClass.category == ViObjectKind.structure => BdStructure._(this, object),
        _ when objectClass.category == ViObjectKind.node => BdNode._(this, object),
        _ => BdPlaced._(this, object),
      });
    }
    return out;
  }

  /// The signals wired in this frame, in record order.
  late final List<BdWire> wires = [
    for (final signal in _list(BdFrameList.signals).children.objects)
      if (signal.kind == HeapObjectClass.signal.code) BdWire._(this, signal),
  ];

  Iterable<T> all<T extends BdPlaced>() => placed.whereType<T>();

  /// Places [node] in this frame: its object joins the object list and the node order.
  T add<T extends BdNode>(T node) {
    if (node._frameOf != null) throw StateError('$node is already placed');
    node._frameOf = this;
    final objects = _list(BdFrameList.objects);
    objects.children.add(node.node);
    objects.syncCount();
    final nodes = _list(BdFrameList.nodes);
    nodes.children.add(HeapRecordNode(encodeHeapRef(0x14, HeapRefKind.childRef.raw & 0xff, node.oid)));
    nodes.syncCount();
    placed.add(node);
    return node;
  }
}

/// Anything placed in a frame: an object with an id, a class and usually bounds.
class BdPlaced {
  BdPlaced._(BdFrame? frameOf, this.node) : _frameOf = frameOf;

  BdFrame? _frameOf;

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

  /// The terminal named [name], as [BdTerminal.name] spells it.
  BdTerminal terminal(String name) => terminals.firstWhere(
    (t) => t.name == name,
    orElse: () => throw ArgumentError.value(name, 'name', 'no such terminal on $this'),
  );
}

/// A primitive node.
class BdPrimitive extends BdNode {
  BdPrimitive._(super.frameOf, super.node) : super._();

  /// A new node of [op], 32 by 32 at [at], its terminals as every corpus node of the
  /// primitive draws them; place it with [BdFrame.add].
  factory BdPrimitive.create(BdEditor editor, PrimOp op, {HeapRect? at}) {
    final terminals = op.terminals;
    if (terminals == null) throw ArgumentError.value(op, 'op', 'has no measured terminals');
    final bounds = at ?? const HeapRect(top: 0, left: 0, bottom: 32, right: 32);
    final node = HeapObjectNode.create(
      HeapObjectClass.bdNode.code,
      editor.allocateOid(),
      children: [
        HeapRecordNode(encodeHeapScalarAttr(HeapAttribute.objFlags.raw, HeapAttrWidth.u24, 0x10000)),
        HeapGroupNode.counted(
          kBdTermList,
          children: [
            for (final terminal in terminals)
              HeapObjectNode.create(
                kNodeEndpointDcoKind,
                editor.allocateOid(),
                children: [
                  HeapRecordNode(
                    terminal.input
                        ? encodeHeapScalarAttr(
                            HeapAttribute.objFlags.raw,
                            HeapAttrWidth.u24,
                            kBdSinkEndpointFlag | 0x1000,
                          )
                        : encodeHeapScalarAttr(HeapAttribute.objFlags.raw, HeapAttrWidth.u16, 0x1000),
                  ),
                  HeapObjectNode.create(
                    kBdNodeTerminalDcoKind,
                    editor.allocateOid(),
                    children: [
                      HeapRecordNode(
                        encodeHeapRectAttr(
                          HeapAttribute.termBounds.raw,
                          HeapRect(
                            top: terminal.top,
                            left: terminal.left,
                            bottom: terminal.bottom,
                            right: terminal.right,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
          ],
        ),
        HeapRecordNode(encodeHeapC4Record(HeapOpcode.bounds.byte, bounds.payload)),
        HeapRecordNode(encodeHeapScalarAttr(HeapAttribute.primResID.raw, HeapAttrWidth.u16, op.id)),
      ],
    );
    return BdPrimitive._(null, node);
  }

  int? get primResId => node.children.attr(HeapAttribute.primResID)?.asInt;

  PrimOp? get op => primResId == null ? null : PrimOp.fromId(primResId!);

  @override
  String toString() => 'prim ${op?.name ?? primResId}#$oid';
}

/// One terminal of a node: its endpoint holder, which signals reference.
class BdTerminal {
  BdTerminal._(this.owner, this.holder, this.index);

  final BdNode owner;

  final HeapObjectNode holder;

  /// Position in the node's terminal list.
  final int index;

  int get oid => holder.oid;

  int get objFlags => holder.children.attr(HeapAttribute.objFlags)?.asInt ?? 0;

  /// Whether the terminal consumes its wire.
  bool get isSink => objFlags & (kBdSinkEndpointFlag | kBdInputEndpointFlag) != 0;

  /// The terminal's rectangle within its node, from its endpoint's `termBounds`.
  HeapRect? get termBounds {
    for (final inner in holder.children.objects) {
      final rect = inner.children.attr(HeapAttribute.termBounds)?.asRect;
      if (rect != null) return rect;
    }
    return null;
  }

  /// Where a wire meets the terminal, in the frame: the middle of the terminal's outer edge.
  HeapRect get attachPoint {
    final node = owner.bounds ?? const HeapRect(top: 0, left: 0, bottom: 0, right: 0);
    final term = termBounds ?? const HeapRect(top: 0, left: 0, bottom: 0, right: 0);
    final y = node.top + (term.top + term.bottom) ~/ 2;
    final x = node.left + (isSink ? term.left : term.right);
    return HeapRect(top: y, left: x, bottom: y, right: x);
  }

  /// The terminal's name: the primitive's own, else `in0`, `out0`, … by role and order.
  String get name {
    final owner = this.owner;
    if (owner is BdPrimitive) {
      final names = owner.op?.terminalNames;
      if (names != null && index < names.length) return names[index];
    }
    final peers = isSink ? owner.inputs : owner.outputs;
    return '${isSink ? 'in' : 'out'}${peers.indexOf(this)}';
  }

  @override
  String toString() => '$owner.$name';
}

/// A structure: a node that owns frames.
class BdStructure extends BdNode {
  BdStructure._(super.frameOf, super.node) : super._();

  /// The structure's frames in record order.
  late final List<BdFrame> frames = [
    for (final child in node.children.objects)
      if (child.kind == HeapObjectClass.bdFrame.code) BdFrame._(this, child),
    for (final group in node.children.whereType<HeapGroupNode>())
      for (final child in group.children.objects)
        if (child.kind == HeapObjectClass.bdFrame.code) BdFrame._(this, child),
  ];
}

/// A For or While loop.
class BdLoop extends BdStructure {
  BdLoop._(super.frameOf, super.node) : super._();

  bool get isFor => node.kind == HeapObjectClass.bdForLoop.code;

  BdFrame get body => frames.single;
}

/// A Case structure.
class BdCase extends BdStructure {
  BdCase._(super.frameOf, super.node) : super._();
}

/// A constant: an endpoint-table entry holding its own data object.
class BdConstant extends BdPlaced {
  BdConstant._(super.frameOf, super.node) : super._();

  HeapObjectNode get data => node.children.objects.firstWhere((o) => o.kind == HeapObjectClass.bdConstDco.code);

  /// The constant's one terminal: the entry itself.
  int get terminalOid => node.oid;
}

/// A front-panel control's or indicator's terminal on the diagram.
class BdPanelTerminal extends BdPlaced {
  BdPanelTerminal._(super.frameOf, super.node) : super._();

  /// The panel object the terminal stands for.
  int? get panelOid => node.children.refs.where((r) => r.kind == HeapRefKind.dcoRef).firstOrNull?.targetOid;

  int get terminalOid => node.oid;
}

/// A signal: the endpoints it joins and its route.
class BdWire {
  BdWire._(this.frameOf, this.node);

  final BdFrame frameOf;

  final HeapObjectNode node;

  int get oid => node.oid;

  /// The endpoints the signal references, in record order.
  List<int> get endpointOids => [
    for (final ref in node.children.group(HeapGroupTag.termList.tag)?.children.refs ?? const <HeapRef>[])
      if (ref.kind == HeapRefKind.childRef) ref.targetOid,
  ];

  int? get signalKind => node.children.attr(HeapAttribute.lastSignalKind)?.asInt;
}

/// The endpoint flag marking a terminal that consumes its wire, and the second one some node
/// terminals and pane indicators carry instead.
const int kBdSinkEndpointFlag = 0x8000;

const int kBdInputEndpointFlag = 0x4000;

/// The class of the data object inside a primitive's endpoint holder.
const int kBdNodeTerminalDcoKind = 0x30;

/// A node's terminal list and a signal's endpoint list, the counted group `0x2b` in bank 1.
const int kBdTermList = 0x12b;

/// The route of a wire from [from] to [to], both points, as the compressed table spells it:
/// straight when they share a row or column, else one turn after the horizontal leg.
WireTable bdRouteBetween(HeapRect from, HeapRect to) {
  final dx = to.left - from.left, dy = to.top - from.top;
  final horizontal = dx >= 0 ? WireRouteDirection.right : WireRouteDirection.left;
  final vertical = dy >= 0 ? WireRouteDirection.down : WireRouteDirection.up;
  if (dy == 0) return WireTable(2, modes: [horizontal.code]);
  if (dx == 0) return WireTable(2, modes: [vertical.code]);
  final turn = (horizontal == WireRouteDirection.right) == (vertical == WireRouteDirection.down) ? 1 : 0;
  return WireTable(3, modes: [horizontal.code, turn], lengths: [dx.abs()]);
}
