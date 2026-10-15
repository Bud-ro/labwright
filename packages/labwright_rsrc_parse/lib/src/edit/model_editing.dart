part of 'block_diagram.dart';

/// Editing a VI through its model: the diagram's root frame to place in, the panel's
/// controls and indicators, [connect] to wire, and [write] to put the heaps back into the
/// sections. Every object id and type slot an edit takes comes from the model, so what is
/// added is consistent with what was loaded.
mixin ViEditing {
  ViSectionBuffer? section(String tag, [int index = 0]);

  int allocateUid();

  int addType(Uint8List descriptor);

  int allocateTypeSlot(int index);

  List<ViDiagram> get blockDiagrams;

  List<ViDiagram> get frontPanelDiagrams;

  ViDiagram reloadDiagram(ViDiagram diagram);

  late final ViSectionBuffer _bdSection =
      section(BlockTag.bdhb.tag) ?? (throw StateError('the model has no block diagram heap'));

  late final List<HeapNode> _bdTree = parseHeapTree(_bdSection.bytes);

  /// The block diagram's root frame, lifted once from the primary heap.
  late final BdFrame diagram = BdFrame._root(this, _bdTree);

  /// The front panel, where [control] and [indicator] put their panel objects.
  late final FpEditor panel = FpEditor.lift(this);

  /// Places [item] on the block diagram.
  T add<T extends BdPlaced>(T item) => diagram.add(item);

  /// A new control of [type] named [name] on the panel, its terminal in [frame], the diagram
  /// itself unless given.
  BdPanelTerminal control(BdType type, String name, {BdFrame? frame}) =>
      (frame ?? diagram).add(BdPanelTerminal.control(type, name));

  /// A new indicator of [type] named [name] on the panel, its terminal in [frame], the
  /// diagram itself unless given.
  BdPanelTerminal indicator(BdType type, String name, {BdFrame? frame}) =>
      (frame ?? diagram).add(BdPanelTerminal.indicator(type, name));

  /// Wires [ends], a source and then at least one more endpoint: every sink is wired from the
  /// nearest source before it, so `[a, b, c]` fans `a` out to `b` and `c` while
  /// `[a, b.x, b.out, c.x]` chains. A wire is typed by [type] or by whichever end declares
  /// one; it runs through a tunnel on every structure border between its ends, reusing a
  /// tunnel the source already feeds, and joins the signal its source already drives in its
  /// frame. A structure terminal given as an end is taken on the side facing the other end.
  BdWire connect(List<BdEndpoint> ends, {BdType? type}) {
    if (ends.length < 2) throw ArgumentError.value(ends, 'ends', 'name a source and at least one sink');
    var source = _facing(ends[0], ends[1]);
    BdWire? wire;
    for (final end in ends.skip(1)) {
      final facing = _facing(end, source);
      if (facing.isSink) {
        wire = _connect(source, facing, type);
      } else {
        source = facing;
      }
    }
    return wire ?? (throw ArgumentError.value(ends, 'ends', 'has no sink'));
  }

  BdWire _connect(BdEndpoint source, BdEndpoint sink, BdType? type) {
    if (source.isSink) throw ArgumentError.value(source, 'source', 'consumes its wire');
    final wireType = type ?? source.type ?? sink.type ?? _wireFrom(source)?.type;
    if (wireType == null) throw ArgumentError('neither $source nor $sink declares a type; pass one');
    final sourcePath = source.frameOf.ancestry, sinkPath = sink.frameOf.ancestry;
    var shared = 0;
    while (shared < sourcePath.length && shared < sinkPath.length && identical(sourcePath[shared], sinkPath[shared])) {
      shared++;
    }
    var from = source;
    for (var i = sourcePath.length - 1; i >= shared; i--) {
      final frame = sourcePath[i];
      var tunnel = _fedTunnel(from, frame.owner!, wireType, output: true);
      if (tunnel == null) {
        tunnel = frame.owner!.tunnel(wireType, direction: BdTunnelDirection.output);
        _wire(from, tunnel.inner(frame), wireType);
      }
      from = tunnel.outer;
    }
    for (var i = shared; i < sinkPath.length; i++) {
      final frame = sinkPath[i];
      var tunnel = _fedTunnel(from, frame.owner!, wireType, output: false);
      if (tunnel == null) {
        tunnel = frame.owner!.tunnel(wireType, direction: BdTunnelDirection.input);
        _wire(from, tunnel.outer, wireType);
      }
      from = tunnel.inner(frame);
    }
    return _wire(from, sink, wireType);
  }

  /// [end] as the endpoint on the side of its structure that faces [other]: inside the frame
  /// of [other]'s ancestry the structure owns, else outside.
  static BdEndpoint _facing(BdEndpoint end, BdEndpoint other) {
    if (end is! BdStructureTerminal) return end;
    final near = other is BdStructureTerminal ? other._facing.frameOf : other.frameOf;
    for (final frame in near.ancestry) {
      if (end.owner.frames.any((f) => identical(f, frame))) return end.inner(frame);
    }
    return end.holder == null ? end.innerPort : end.outer;
  }

  /// A plain tunnel of [type] on [structure] the signal from [from] already reaches.
  BdStructureTerminal? _fedTunnel(BdEndpoint from, BdStructure structure, BdType type, {required bool output}) {
    final fed = _wireFrom(from)?.endpointOids.toSet();
    if (fed == null) return null;
    for (final tunnel in structure.borderTerminals) {
      if (tunnel.holder == null || tunnel._type != type || tunnel.indexing) continue;
      if (tunnel.kind != BdBorderKind.loopTunnel && tunnel.kind != BdBorderKind.caseTunnel) continue;
      if (tunnel.isInput == output) continue;
      final port = output ? tunnel.inner(from.frameOf) : tunnel.outer;
      if (fed.contains(port.oid)) return tunnel;
    }
    return null;
  }

  /// The signal [source] already drives, if this editing wired one.
  BdWire? _wireFrom(BdEndpoint source) =>
      source.frameOf.wires.where((wire) => wire.source?.oid == source.oid).firstOrNull;

  BdWire _wire(BdEndpoint source, BdEndpoint sink, BdType type) {
    final frame = source.frameOf;
    if (!identical(frame, sink.frameOf)) throw StateError('$source and $sink are in different frames');
    if (!sink.isSink) throw ArgumentError.value(sink, 'sink', 'produces its wire');
    if (_wireFrom(source) case final wire?) {
      wire._addSink(sink);
      return wire;
    }
    final signal = object(
      HeapObjectClass.signal.code,
      allocateUid(),
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

  /// Writes the edited heaps back into the model's sections and rebuilds its diagrams.
  void write() {
    _bdSection.replace(encodeHeapTree(_bdTree));
    for (final diagram in blockDiagrams) {
      if (diagram.sectionIndex == _bdSection.index) reloadDiagram(diagram);
    }
    panel.write();
  }
}
