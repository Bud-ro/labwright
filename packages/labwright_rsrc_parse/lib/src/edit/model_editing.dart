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

  /// Wires [source] to [sink], typed by [type] or by whichever end declares one: a signal over
  /// the two in the frame they share, through a tunnel on every structure border between
  /// them, reusing a tunnel the source already feeds, and joining the signal [source]
  /// already drives in its frame. A structure terminal given as an end is taken on the side
  /// facing the other end.
  BdWire connect(BdEndpoint source, BdEndpoint sink, {BdType? type}) =>
      _connect(_facing(source, sink), _facing(sink, source), type);

  BdWire _connect(BdEndpoint source, BdEndpoint sink, BdType? type) {
    if (source.isSink) throw ArgumentError.value(source, 'source', 'consumes its wire');
    final wireType =
        type ?? source.type ?? sink.type ?? _wireFrom(source)?.type ?? _siblingType(source) ?? _siblingType(sink);
    if (wireType == null) throw ArgumentError('neither $source nor $sink declares a type; pass one');
    final sourcePath = source.frameOf.ancestry, sinkPath = sink.frameOf.ancestry;
    var shared = 0;
    while (shared < sourcePath.length && shared < sinkPath.length && identical(sourcePath[shared], sinkPath[shared])) {
      shared++;
    }
    final (a, b) = shared < sourcePath.length && shared < sinkPath.length
        ? (sourcePath[shared].owner, sinkPath[shared].owner)
        : (null, null);
    final carried =
        a is BdSequenceFrame && b is BdSequenceFrame && identical(a.sequence, b.sequence) && a.index < b.index;
    final border = carried ? shared + 1 : shared;
    var from = source;
    for (var i = sourcePath.length - 1; i >= border; i--) {
      final frame = sourcePath[i];
      var tunnel = _fedTunnel(from, frame.owner!, wireType, output: true);
      if (tunnel == null) {
        tunnel = frame.owner!.tunnel(wireType, direction: BdTunnelDirection.output);
        _wire(from, tunnel.inner(frame), wireType);
      }
      from = tunnel.outer;
    }
    if (carried) {
      for (var stage = a; stage.index < b.index; stage = stage.sequence.stages[stage.index + 1]) {
        var out = _fedTunnel(from, stage, wireType, output: true, kind: BdBorderKind.frameTunnel);
        if (out == null) {
          final pair = stage.link(stage.sequence.stages[stage.index + 1], wireType);
          out = pair.$1;
          _wire(from, out.innerPort, wireType);
          _wire(out.outer, pair.$2.outer, wireType);
        }
        from = out.partner!.innerPort;
      }
    }
    for (var i = border; i < sinkPath.length; i++) {
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

  /// The type a wire on another terminal of [end]'s node carries: a polymorphic node's
  /// terminals share one.
  BdType? _siblingType(BdEndpoint end) {
    final owner = end is BdTerminal ? end.owner : null;
    if (owner == null) return null;
    final oids = {for (final t in owner.terminals) t.oid};
    for (final wire in owner.frameOf.wires) {
      if (wire.type != null && wire.endpointOids.any(oids.contains)) return wire.type;
    }
    return null;
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

  /// A tunnel of [type] on [structure] the signal from [from] already reaches: one of [kind],
  /// else any plain one.
  BdStructureTerminal? _fedTunnel(
    BdEndpoint from,
    BdStructure structure,
    BdType type, {
    required bool output,
    BdBorderKind? kind,
  }) {
    final fed = _wireFrom(from)?.endpointOids.toSet();
    if (fed == null) return null;
    for (final tunnel in structure.borderTerminals) {
      if (tunnel.holder == null || tunnel._type != type || tunnel.indexing) continue;
      if (kind == null ? !_plainTunnels.contains(tunnel.kind) : tunnel.kind != kind) continue;
      if (tunnel.isInput == output) continue;
      final port = output ? tunnel.inner(from.frameOf) : tunnel.outer;
      if (fed.contains(port.oid)) return tunnel;
    }
    return null;
  }

  static const _plainTunnels = {BdBorderKind.loopTunnel, BdBorderKind.caseTunnel, BdBorderKind.sequenceTunnel};

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

  /// Lays out what has no position yet, routes the wires, writes the edited heaps back into
  /// the model's sections and rebuilds its diagrams.
  void write() {
    BdLayout(diagram).run();
    _bdSection.replace(encodeHeapTree(_bdTree));
    for (final diagram in blockDiagrams) {
      if (diagram.sectionIndex == _bdSection.index) reloadDiagram(diagram);
    }
    panel.write();
  }
}
