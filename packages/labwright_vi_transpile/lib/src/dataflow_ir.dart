/// The **dataflow IR**: a decoded block diagram ([ViDiagram]) recast as a
/// directed graph of value-producing units joined by typed edges, hierarchical
/// over structure frames.
///
/// The heap gives a positional tree and a flat list of signals; neither states
/// which end of a wire produces and which consumes, and neither separates a
/// structure's outside from its insides. This layer answers both, from decoded
/// bytes alone:
///
/// - **Direction** comes from the endpoint holder's own flag bit
///   ([kLvSinkEndpointFlag]), with a connector-pane terminal's direction taken
///   from its panel data item instead ([lvEndpointIsSink]). Corpus, over
///   428 043 signals in 7 524 files: 424 466 resolve exactly one source
///   endpoint and 3 577 do not — every one of those has SEVERAL sources, none
///   has none, and they are refused ([LvRefusalKind.wireDirection]) rather
///   than picked between.
/// - **Nesting** comes from the frame (`0x1b`) each node, structure and signal
///   is parented to, so every edge lives in exactly one [LvRegion] and a
///   structure's terminals split cleanly into an outer port (in the parent
///   region) and one inner port per frame.
///
/// The result is acyclic *within* a region by construction: a loop's feedback
/// runs through a shift register, whose inner read is a region entry and whose
/// inner write is a region exit, so it is never an edge. A back edge that
/// survives that is a malformed diagram and is refused.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'declare.dart';
import 'type_map.dart';
import 'wire_type.dart';

/// The endpoint-holder ([ViHeapObject.objFlags]) bit marking the holder as a
/// wire's **sink**; clear marks its source. See the library doc for the corpus
/// census behind it.
const int kLvSinkEndpointFlag = 0x8000;

/// Whether the wire endpoint [object] consumes the value rather than produces
/// it.
///
/// A **connector-pane terminal** (`0x16`) answers from its panel data item
/// ([ViHeapObject.isIndicator], bit 0 of the owning DCO's flags): an indicator
/// consumes, a control produces. Every other endpoint answers from its own
/// [kLvSinkEndpointFlag].
///
/// The two never contradict each other and the panel bit is stated more often.
/// Corpus, over 428 043 signals in 7 524 VIs: on the 423 985 signals whose
/// flags already resolve exactly one source, the panel bit agrees with the flag
/// on all 38 744 connector-pane endpoints it covers, with no disagreement; and
/// on the 4 058 signals whose flags resolve two or more sources, 481 resolve to
/// exactly one once a connector-pane endpoint answers from its panel item.
bool lvEndpointIsSink(ViHeapObject object) {
  if (object.kind == kLvInterfaceTerminalCode) {
    if (object.isIndicator case final indicator?) return indicator;
  }
  return ((object.objFlags ?? 0) & kLvSinkEndpointFlag) != 0;
}

/// The tunnel ([ViHeapObject.objFlags]) bit marking an **auto-indexing** loop
/// tunnel — the boundary that iterates an array element-wise instead of
/// passing the whole value. Corpus, over 21 486 loop tunnels whose two sides
/// both resolve a dimensionality: every one of the 6 584 flagged tunnels drops
/// exactly one dimension across the border and every one of the 10 370
/// unflagged tunnels drops none. 595 unflagged tunnels do drop a dimension;
/// those disagree with the flag and are refused
/// ([LvRefusalKind.tunnelIndexing]).
const int kLvAutoIndexTunnelFlag = 0x1000000;

/// The heap class code of a structure's **frame** — one subdiagram.
const int kLvFrameCode = 0x1b;

/// The heap class code of an endpoint **holder**: the record a signal names as
/// an endpoint and that binds it to a node terminal, a constant or a structure
/// terminal.
const int kLvHolderCode = 0x15;

/// The heap class code of a **constant** record (the value carrier under a
/// diagram constant's holder).
const int kLvConstantCode = 0x13;

/// The heap class code of a **connector-pane terminal** — a control or
/// indicator of the VI's own interface, drawn on the diagram.
const int kLvInterfaceTerminalCode = 0x16;

/// The heap class code of a case structure's **selector label** (the displayed
/// frame's case value).
const int kLvSelectorLabelCode = 0x95;

/// A structure kind whose control flow this IR models.
enum LvStructureKind {
  /// `0x20` — a For loop: an `N` count terminal, an `i` iteration terminal,
  /// tunnels and shift registers.
  forLoop(0x20),

  /// `0x21` — a While loop: an `i` iteration terminal and a conditional
  /// terminal, tunnels and shift registers. It has no count terminal (corpus:
  /// 1 460 While loops carry tunnels, 0 carry a `0x26`).
  whileLoop(0x21),

  /// `0x2c` — a Case structure: a selector terminal and one frame per case.
  caseStructure(0x2c),

  /// `0xcd` — a Diagram Disable structure: exactly one frame executes and the
  /// others are dead code.
  disableStructure(0xcd)
  ;

  const LvStructureKind(this.code);

  /// The heap class code.
  final int code;

  /// The kind for heap class [code], or null when the structure's control flow
  /// is not modelled.
  static LvStructureKind? ofCode(int code) => _byCode[code];

  static final Map<int, LvStructureKind> _byCode = {for (final kind in values) kind.code: kind};
}

/// The role a structure's border terminal plays, keyed by its heap class code.
enum LvTerminalRole {
  /// `0x24` — a loop's **iteration** terminal (`i`), readable inside only.
  iteration(0x24),

  /// `0x25` — a While loop's **conditional** terminal, written inside only.
  ///
  /// Its POLARITY — whether a true value stops the loop or continues it — is
  /// not decoded, and the corpus says why. Over the 2 267 conditional
  /// terminals in 7 524 VIs the terminal carries six record kinds and only
  /// three of them vary at all:
  ///
  /// - the glyph selector ([ViHeapObject.termBmp]) is `192` on **1 892 of
  ///   1 892** drawn terminals — one value, so the file names one drawn form;
  /// - the terminal's own flags are `0x10001` on those 1 892 and `0x1` on the
  ///   375 that carry no glyph at all (all of them on For loops);
  /// - a `dsw` word (raw `0x061`) of `0x1000` appears on 244 of the 2 267;
  /// - the carried DCO's flags set bit `0x1` on 382 and bit `0x1000` on 140.
  ///
  /// The three varying fields are not the polarity: each takes BOTH values
  /// across the 26 conditional terminals the snippet references draw (`fg`
  /// carries the `dsw` word and no other snippet does; `large` and
  /// `Excel_Read_XLSX` split on both DCO bits), and all 26 reference renders
  /// draw the identical red stop octagon. So nothing that varies changes what
  /// LabVIEW draws, and the one field that would — the glyph selector — is
  /// constant. While loops are refused rather than given a guessed exit test.
  conditional(0x25),

  /// `0x26` — a For loop's **count** terminal (`N`), written outside only.
  count(0x26),

  /// `0x27` — the **left** shift register: reads the previous iteration's
  /// value inside, takes its initial value from outside.
  leftShiftRegister(0x27),

  /// `0x28` — the **right** shift register: written inside, read outside after
  /// the loop. Names its left partner among its members.
  rightShiftRegister(0x28),

  /// `0x22` — a loop **tunnel**, optionally auto-indexing
  /// ([kLvAutoIndexTunnelFlag]).
  loopTunnel(0x22),

  /// `0x2d` — a case/event structure **tunnel**: one inner port per frame.
  caseTunnel(0x2d),

  /// `0x2e` — a case structure's **selector** terminal.
  selector(0x2e),

  /// `0xce` — a disable structure's **tunnel**.
  disableTunnel(0xce)
  ;

  const LvTerminalRole(this.code);

  /// The heap class code.
  final int code;

  /// The role for heap class [code], or null when the class is not a modelled
  /// structure terminal.
  static LvTerminalRole? ofCode(int code) => _byCode[code];

  static final Map<int, LvTerminalRole> _byCode = {for (final role in values) role.code: role};
}

/// Why a diagram could not be lowered. Every refusal names a decoded fact that
/// is missing or contradictory — never a shortfall of effort.
enum LvRefusalKind {
  /// A signal's endpoints do not resolve to exactly one source.
  wireDirection,

  /// A signal's decoded type word has no Dart representation.
  wireType,

  /// A wire carries a nominal type whose Dart declaration cannot be written
  /// ([LvTypeDecl.undeclarable]).
  typeDeclaration,

  /// A node's primitive identity is not decoded, or has no mapping.
  primitive,

  /// A diagram constant whose value the heap decode did not recover.
  constantValue,

  /// A structure class whose control flow is not modelled.
  structure,

  /// A Case structure carrying no selector range list, or one whose ranges
  /// have no reading as a test over the selector's own type.
  caseSelector,

  /// An auto-indexing flag that contradicts the two sides' dimensionalities.
  tunnelIndexing,

  /// A terminal that must carry a value but no wire reaches it.
  unwiredTerminal,

  /// A region whose dataflow contains a cycle outside a shift register.
  cycle,

  /// An endpoint holder that resolves to no known producer or consumer.
  endpointBinding,

  /// A live terminal reads a wire whose producing unit the lowering never
  /// emitted, so the value it would read is not defined.
  unboundValue,

  /// A subVI call that cannot be bound: the called VI was not supplied, its
  /// connector pane does not resolve to the caller's terminals, or the two
  /// disagree about a terminal's type.
  subViCall,

  /// The diagram carries no block-diagram frame at all.
  noDiagram,
}

/// A refused diagram, with the decoded fact that is missing.
class LvRefusal {
  const LvRefusal(this.kind, this.detail, {this.oid});

  /// The category, for grouping a corpus sweep's outcomes.
  final LvRefusalKind kind;

  /// What specifically is missing, including any identifying number.
  final String detail;

  /// The heap object the refusal is about, when there is one.
  final int? oid;

  @override
  String toString() => '${kind.name}: $detail${oid == null ? '' : ' (oid $oid)'}';
}

/// Thrown inside the builder and the emitter to abort with an [LvRefusal].
class LvRefusedException implements Exception {
  const LvRefusedException(this.refusal);

  /// The refusal to report.
  final LvRefusal refusal;

  @override
  String toString() => 'LvRefusedException($refusal)';
}

/// One typed dataflow edge: a decoded `0x17` signal, resolved to its single
/// source port and its sink ports.
class LvEdge {
  const LvEdge({required this.signalOid, required this.source, required this.sinks, required this.type});

  /// The signal record's oid.
  final int signalOid;

  /// The endpoint-holder oid that produces the value.
  final int source;

  /// The endpoint-holder oids that consume it.
  final List<int> sinks;

  /// The Dart type the edge carries.
  final LvWireType type;
}

/// A unit of a region: something that consumes ports and produces ports.
sealed class LvUnit {
  const LvUnit();

  /// The heap oid the unit is identified by.
  int get oid;

  /// The endpoint-holder oids the unit reads.
  List<int> get inputPorts;

  /// The endpoint-holder oids the unit writes.
  List<int> get outputPorts;
}

/// A primitive or class-identified operation node.
class LvPrimUnit extends LvUnit {
  const LvPrimUnit({
    required this.oid,
    required this.classCode,
    required this.op,
    required this.primResId,
    required this.label,
    required this.inputPorts,
    required this.outputPorts,
    required this.portRoleFlags,
    required this.portDrawnTop,
  });

  @override
  final int oid;

  /// The node's heap class code — the identity for the classes that are one
  /// operation (see `kSingleOpPrimClasses`).
  final int classCode;

  /// The decoded primitive operation, or null when the node's identity is its
  /// [classCode] alone.
  final PrimOp? op;

  /// The node's raw `primResID`, whether or not [PrimOp] names it — the number
  /// a refusal reports so an unnamed operation is identifiable.
  final int? primResId;

  /// The node's own recovered caption, or null when it carries none — the
  /// only name the diagram states for the values it produces.
  final String? label;

  @override
  final List<int> inputPorts;

  @override
  final List<int> outputPorts;

  /// Per port oid, the flags on the terminal's own typed record — the decoded
  /// operand role for the growable array nodes (see `LvArrayTerminalRole`).
  final Map<int, int> portRoleFlags;

  /// Per port oid, the y of the point the terminal is DRAWN at, in absolute
  /// diagram coordinates ([ViDiagram.dcoChildTerminalAttach]) — the operand
  /// order for the operations whose terminal records do not carry one (see
  /// `LvPrimCall.operandsTopDown`). Absent for a terminal whose attach
  /// geometry does not resolve.
  final Map<int, int> portDrawnTop;
}

/// A **subVI call**: one endpoint holder per connector-pane terminal of the
/// called VI, in pane-index order.
class LvSubViUnit extends LvUnit {
  const LvSubViUnit({
    required this.oid,
    required this.classCode,
    required this.calleeName,
    required this.panePorts,
    required this.inputPorts,
    required this.outputPorts,
  });

  @override
  final int oid;

  /// The node's heap class code.
  final int classCode;

  /// The called VI's file name, from the node's caption, or null when the
  /// caption is not a `.vi`/`.vim` file name.
  final String? calleeName;

  /// The endpoint-holder oids in connector-pane order — one per pane
  /// position, in heap order.
  final List<int> panePorts;

  @override
  final List<int> inputPorts;

  @override
  final List<int> outputPorts;

  /// The connector-pane position [port] occupies, or null when it is not one
  /// of this node's ports.
  int? paneIndexOf(int port) {
    final index = panePorts.indexOf(port);
    return index < 0 ? null : index;
  }
}

/// A diagram constant: one output port carrying a decoded literal.
class LvConstUnit extends LvUnit {
  const LvConstUnit({required this.oid, required this.port, required this.record, required this.label});

  @override
  final int oid;

  /// The endpoint-holder oid the constant feeds.
  final int port;

  /// The `0x13` record carrying the decoded value.
  final ViHeapObject record;

  /// The constant's own recovered name, or null.
  final String? label;

  @override
  List<int> get inputPorts => const [];

  @override
  List<int> get outputPorts => [port];
}

/// A connector-pane control or indicator drawn on the diagram: the VI's own
/// interface, and so a parameter or a result of the emitted function.
class LvInterfaceUnit extends LvUnit {
  const LvInterfaceUnit({required this.oid, required this.name, required this.isIndicator, required this.bounds});

  @override
  final int oid;

  /// The control's recovered name ([ViHeapObject.typeName]), or null.
  final String? name;

  /// Whether the terminal consumes (an indicator, a result) rather than
  /// produces (a control, a parameter).
  final bool isIndicator;

  /// The terminal's drawn box, which orders the emitted parameter list.
  final HeapRect? bounds;

  @override
  List<int> get inputPorts => isIndicator ? [oid] : const [];

  @override
  List<int> get outputPorts => isIndicator ? const [] : [oid];
}

/// One border terminal of a structure, with its outer port and its per-frame
/// inner ports.
class LvStructTerminal {
  const LvStructTerminal({
    required this.oid,
    required this.role,
    required this.outerPort,
    required this.innerPorts,
    required this.autoIndexing,
    required this.partnerOid,
    required this.outerIsSink,
  });

  /// The terminal record's oid.
  final int oid;

  /// What the terminal does.
  final LvTerminalRole role;

  /// The endpoint-holder oid on the structure's outside, or null when the role
  /// has no outside (`i`, the conditional terminal).
  final int? outerPort;

  /// Per frame oid, the endpoint-holder oid on that frame's inside.
  final Map<int, int> innerPorts;

  /// Whether the tunnel iterates an array element-wise
  /// ([kLvAutoIndexTunnelFlag]).
  final bool autoIndexing;

  /// For a right shift register, its left partner's oid; else null.
  final int? partnerOid;

  /// Whether [outerPort] consumes rather than produces — read off the outer
  /// holder's own direction flag, so a tunnel's direction is a decoded fact
  /// rather than an assumption about which way tunnels of its role run.
  final bool outerIsSink;
}

/// A structure node: its terminals, and one region per frame.
class LvStructUnit extends LvUnit {
  const LvStructUnit({
    required this.oid,
    required this.kind,
    required this.terminals,
    required this.frames,
    required this.displayedFrame,
    required this.displayedCase,
    this.selectorRanges = const <ViSelectorRange>[],
    this.selectorStrings = const <String>[],
    this.defaultFrame = 0,
  });

  @override
  final int oid;

  /// The structure's control-flow kind.
  final LvStructureKind kind;

  /// The border terminals, in heap order.
  final List<LvStructTerminal> terminals;

  /// One region per frame, in frame order.
  final List<LvRegion> frames;

  /// The index into [frames] of the frame LabVIEW displays.
  final int displayedFrame;

  /// The displayed frame's case value, from the structure's `0x95` selector
  /// label. Null when no label was recovered. It is the only case value the
  /// file states in WORDS; the values themselves are in [selectorRanges].
  final String? displayedCase;

  /// A Case structure's per-frame case values ([ViHeapObject.selectorRanges]),
  /// in the file's own order. Empty for the structures that carry no range list
  /// and for the other structure kinds.
  final List<ViSelectorRange> selectorRanges;

  /// The string pool [selectorRanges] indexes when the selector carries
  /// strings, empty otherwise ([ViHeapObject.selectorStrings]).
  final List<String> selectorStrings;

  /// The index into [frames] of the frame a selector value no range names
  /// reaches ([ViHeapObject.defaultFrameIndex], or the first frame).
  final int defaultFrame;

  @override
  List<int> get inputPorts => [
    for (final terminal in terminals)
      if (terminal.outerPort case final port? when terminal.outerIsSink) port,
  ];

  @override
  List<int> get outputPorts => [
    for (final terminal in terminals)
      if (terminal.outerPort case final port? when !terminal.outerIsSink) port,
  ];
}

/// One subdiagram's dataflow: the units drawn in it and the edges between them.
class LvRegion {
  const LvRegion({required this.frameOid, required this.units, required this.edges});

  /// The frame (`0x1b`) record this region is the inside of.
  final int frameOid;

  /// The units drawn directly in this frame, in heap order.
  final List<LvUnit> units;

  /// The signals parented to this frame.
  final List<LvEdge> edges;
}

/// A whole block diagram as dataflow.
class LvDataflow {
  const LvDataflow({
    required this.root,
    required this.edgeBySink,
    required this.edgeBySource,
    required this.ownerOfPort,
    required this.sinkPorts,
  });

  /// The top-level region.
  final LvRegion root;

  /// Per sink port oid, the edge feeding it.
  final Map<int, LvEdge> edgeBySink;

  /// Per source port oid, the edge it feeds.
  final Map<int, LvEdge> edgeBySource;

  /// Per port oid, the oid of the unit that owns it. A structure terminal's
  /// inner port maps to the owning structure, so a region's own entries and
  /// exits are recognisable as ports whose owner is not a unit of the region.
  final Map<int, int> ownerOfPort;

  /// The port oids that are sinks.
  final Set<int> sinkPorts;

  /// The edge feeding [port], or null when nothing reaches it.
  LvEdge? into(int port) => edgeBySink[port];

  /// The edge [port] feeds, or null when it drives nothing.
  LvEdge? outOf(int port) => edgeBySource[port];
}

/// [diagram] as dataflow, or an [LvRefusal] naming the decoded fact that is
/// missing. Never throws for a malformed diagram.
///
/// [declarations] is the generated library's declaration registry, which the
/// nominal types the diagram's wires carry are named through. A build with no
/// registry gets one of its own, so a diagram lowered on its own is typed the
/// same way.
({LvDataflow? dataflow, LvRefusal? refusal}) buildLvDataflow(
  ViDiagram diagram, {
  List<ViType> pool = const [],
  LvDeclarations? declarations,
}) {
  try {
    return (dataflow: _Builder(diagram, pool, declarations ?? LvDeclarations()).build(), refusal: null);
  } on LvRefusedException catch (error) {
    return (dataflow: null, refusal: error.refusal);
  }
}

class _Builder {
  _Builder(this.diagram, this.pool, this.declarations) : byId = diagram.byId, kids = diagram.childrenByOid;

  final ViDiagram diagram;
  final List<ViType> pool;
  final LvDeclarations declarations;
  final Map<int, ViHeapObject> byId;
  final Map<int, List<ViHeapObject>> kids;

  final edgeBySink = <int, LvEdge>{};
  final edgeBySource = <int, LvEdge>{};
  final ownerOfPort = <int, int>{};
  final sinkPorts = <int>{};

  Never refuse(LvRefusalKind kind, String detail, {int? oid}) =>
      throw LvRefusedException(LvRefusal(kind, detail, oid: oid));

  LvDataflow build() {
    final rootFrame = _rootFrame();
    _buildEdges();
    final root = _region(rootFrame);
    return LvDataflow(
      root: root,
      edgeBySink: edgeBySink,
      edgeBySource: edgeBySource,
      ownerOfPort: ownerOfPort,
      sinkPorts: sinkPorts,
    );
  }

  /// The diagram's single top-level frame: the `0x1b` under the root object.
  int _rootFrame() {
    for (final object in diagram.objects) {
      if (object.parentOid == null) {
        final frame = kids[object.oid]?.where((k) => k.kind == kLvFrameCode).firstOrNull;
        if (frame != null) return frame.oid;
      }
    }
    refuse(LvRefusalKind.noDiagram, 'the diagram has no top-level frame');
  }

  /// Whether the endpoint holder [oid] consumes rather than produces.
  bool _isSink(int oid) {
    final holder = byId[oid];
    if (holder == null) {
      refuse(LvRefusalKind.endpointBinding, 'signal endpoint $oid resolves to no heap object', oid: oid);
    }
    return lvEndpointIsSink(holder);
  }

  void _buildEdges() {
    for (final wire in diagram.wires) {
      final sources = [
        for (final oid in wire.endpointOids)
          if (!_isSink(oid)) oid,
      ];
      if (sources.length != 1) {
        refuse(
          LvRefusalKind.wireDirection,
          'signal has ${sources.length} source endpoints among ${wire.endpointOids.length}; '
          'exactly one endpoint must read as a producer ([lvEndpointIsSink])',
          oid: wire.signalOid,
        );
      }
      final signal = wire.signalType;
      if (signal == null) {
        refuse(LvRefusalKind.wireType, 'signal carries no decoded type word', oid: wire.signalOid);
      }
      final type = _wireType(wire, signal);
      if (!type.isMapped) {
        refuse(LvRefusalKind.wireType, type.value.note ?? 'wire type is unmapped', oid: wire.signalOid);
      }
      for (final declaration in lvDeclarationClosure(type.declarations)) {
        if (declaration.undeclarable case final why?) {
          refuse(
            LvRefusalKind.typeDeclaration,
            'the wire\'s type spells ${declaration.name}, and $why',
            oid: wire.signalOid,
          );
        }
      }
      final sinks = [
        for (final oid in wire.endpointOids)
          if (oid != sources.single) oid,
      ];
      final edge = LvEdge(signalOid: wire.signalOid, source: sources.single, sinks: sinks, type: type);
      edgeBySource[edge.source] = edge;
      for (final sink in sinks) {
        edgeBySink[sink] = edge;
        sinkPorts.add(sink);
      }
    }
  }

  /// The Dart type of [wire], resolving a cluster wire's members through its
  /// endpoints when the signal word alone does not carry them.
  ///
  /// Two endpoints that resolve descriptors are compared by the **Dart type
  /// each one maps to**, not by the descriptors' own spelling: allocated
  /// against one [LvDeclarations], two readings hold the same [LvWireType.dartType]
  /// exactly when they are one type in the generated library, and hold
  /// different ones as soon as their structures differ. Reading the spelling
  /// instead refuses a wire whose ends carry the same type under two control
  /// LABELS, which is what 1 216 of the corpus's 1 372 disagreeing wires are
  /// (`error in` against `error out`, both the error cluster).
  LvWireType _wireType(ViWire wire, ViSignalType signal) {
    final direct = mapLvWireType(signal);
    if (direct.isMapped) return direct;
    if (kLvWireRefnumCodes.contains(signal.typeCode)) {
      final dims = lvRefnumWireDims(diagram, wire);
      return dims == null ? direct : lvRefnumWireType(signal, dims);
    }
    if (!kLvWireClusterCodes.contains(signal.typeCode)) return direct;
    final array = (signal.arrayDims ?? 0) > 0;
    final resolved = <ViType>[
      for (final endpoint in wire.endpointOids)
        if (lvClusterOfEndpoint(diagram, endpoint, array: array) case final cluster?) cluster,
    ];
    if (resolved.isEmpty) return direct;
    final readings = [for (final cluster in resolved) lvClusterWireType(signal, cluster, pool, declarations)];
    final types = {for (final reading in readings) reading.dartType};
    if (types.length != 1) {
      refuse(
        LvRefusalKind.wireType,
        'the wire\'s endpoints resolve ${types.length} different Dart types, '
        'so the value it carries is not decided',
        oid: wire.signalOid,
      );
    }
    return readings.first;
  }

  /// The nearest enclosing frame of [oid], or null.
  int? _frameOf(int oid) {
    var current = byId[oid];
    for (var depth = 0; current != null && depth < 64; depth++) {
      final parent = current.parentOid;
      if (parent == null) return null;
      final object = byId[parent];
      if (object == null) return null;
      if (object.kind == kLvFrameCode) return object.oid;
      current = object;
    }
    return null;
  }

  LvRegion _region(int frameOid) {
    final units = <LvUnit>[];
    for (final child in kids[frameOid] ?? const <ViHeapObject>[]) {
      switch (child.category) {
        case ViObjectKind.node:
          units.add(kSubViCallNodeCodes.contains(child.kind) ? _subViUnit(child) : _primUnit(child));
        case ViObjectKind.structure:
          units.add(_structUnit(child));
        case _:
          if (child.kind == 0x1d) units.addAll(_wireRecordUnits(child));
      }
    }
    final edges = [
      for (final wire in diagram.wires)
        if (_frameOf(wire.signalOid) == frameOid || byId[wire.signalOid]?.parentOid == frameOid)
          if (edgeBySource[_sourceOf(wire)] case final edge?) edge,
    ];
    return LvRegion(frameOid: frameOid, units: units, edges: edges);
  }

  int _sourceOf(ViWire wire) => wire.endpointOids.firstWhere((oid) => !_isSink(oid));

  /// A subVI call node. Its holders are its connector-pane terminals in pane
  /// order, so their heap order is preserved rather than sorted.
  LvSubViUnit _subViUnit(ViHeapObject node) {
    final ports = <int>[];
    final inputs = <int>[], outputs = <int>[];
    for (final holder in kids[node.oid] ?? const <ViHeapObject>[]) {
      if (holder.kind != kLvHolderCode) continue;
      ownerOfPort[holder.oid] = node.oid;
      ports.add(holder.oid);
      (_isSink(holder.oid) ? inputs : outputs).add(holder.oid);
    }
    final name = node.label?.trim();
    return LvSubViUnit(
      oid: node.oid,
      classCode: node.kind,
      calleeName: name != null && _isViFileName(name) ? name : null,
      panePorts: ports,
      inputPorts: inputs,
      outputPorts: outputs,
    );
  }

  static bool _isViFileName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.vi') || lower.endsWith('.vim');
  }

  LvPrimUnit _primUnit(ViHeapObject node) {
    final inputs = <int>[], outputs = <int>[];
    final roleFlags = <int, int>{};
    final drawnTop = <int, int>{};
    for (final holder in kids[node.oid] ?? const <ViHeapObject>[]) {
      if (holder.kind != kLvHolderCode) continue;
      ownerOfPort[holder.oid] = node.oid;
      (_isSink(holder.oid) ? inputs : outputs).add(holder.oid);
      final record = (kids[holder.oid] ?? const <ViHeapObject>[]).firstOrNull;
      roleFlags[holder.oid] = record?.objFlags ?? 0;
      final attach = diagram.dcoChildTerminalAttach(holder.oid);
      if (attach != null) drawnTop[holder.oid] = attach.candidates.first.y;
    }
    return LvPrimUnit(
      oid: node.oid,
      classCode: node.kind,
      op: node.primResId == null ? null : PrimOp.fromId(node.primResId!),
      primResId: node.primResId,
      label: _captionOf(node),
      inputPorts: inputs,
      outputPorts: outputs,
      portRoleFlags: roleFlags,
      portDrawnTop: drawnTop,
    );
  }

  /// The units a frame's wire record (`0x1d`) contributes: diagram constants
  /// and connector-pane terminals. Holders that bind a structure terminal's
  /// inner side belong to that structure, not here.
  List<LvUnit> _wireRecordUnits(ViHeapObject record) {
    final units = <LvUnit>[];
    for (final child in kids[record.oid] ?? const <ViHeapObject>[]) {
      if (child.kind == kLvInterfaceTerminalCode) {
        ownerOfPort[child.oid] = child.oid;
        units.add(
          LvInterfaceUnit(
            oid: child.oid,
            name: child.typeName,
            isIndicator: _isSink(child.oid),
            bounds: child.absBounds,
          ),
        );
        continue;
      }
      if (child.kind != kLvHolderCode) continue;
      if (child.memberOids.isNotEmpty) continue; // a structure terminal's inner side
      final constant = kids[child.oid]?.where((k) => k.kind == kLvConstantCode).firstOrNull;
      if (constant == null) {
        refuse(
          LvRefusalKind.endpointBinding,
          'endpoint holder binds neither a constant nor a structure terminal',
          oid: child.oid,
        );
      }
      ownerOfPort[child.oid] = constant.oid;
      units.add(
        LvConstUnit(oid: constant.oid, port: child.oid, record: constant, label: _constantLabel(constant)),
      );
    }
    return units;
  }

  /// A node's own drawn caption, or null when it carries none. A caption is
  /// LabVIEW's default node name unless the author renamed it, so it is used
  /// only where a name is wanted and never as an identity.
  static String? _captionOf(ViHeapObject node) {
    final label = nodeDisplayLabel(node);
    return label.isHint ? null : label.text;
  }

  /// A constant's drawn name: the visible `0xa` caption on its bounded shell.
  String? _constantLabel(ViHeapObject constant) {
    for (final shell in kids[constant.oid] ?? const <ViHeapObject>[]) {
      for (final part in kids[shell.oid] ?? const <ViHeapObject>[]) {
        if (part.kind == 0xa) {
          final text = part.label?.trim();
          if (text != null && text.isNotEmpty) return text;
        }
      }
    }
    return null;
  }

  LvStructUnit _structUnit(ViHeapObject structure) {
    final kind = LvStructureKind.ofCode(structure.kind);
    if (kind == null) {
      refuse(
        LvRefusalKind.structure,
        'structure class 0x${structure.kind.toRadixString(16)} '
        '(${structure.objectClass.label}) has no modelled control flow',
        oid: structure.oid,
      );
    }
    final frames = [
      for (final child in kids[structure.oid] ?? const <ViHeapObject>[])
        if (child.kind == kLvFrameCode) child.oid,
    ];
    final terminals = <LvStructTerminal>[];
    for (final terminal in _terminalRecords(structure)) {
      final role = LvTerminalRole.ofCode(terminal.kind);
      if (role == null) continue;
      int? outer;
      final inner = <int, int>{};
      int? partner;
      for (final member in terminal.memberOids) {
        final object = byId[member];
        if (object == null) continue;
        if (object.kind != kLvHolderCode) {
          if (LvTerminalRole.ofCode(object.kind) != null) partner = object.oid;
          continue;
        }
        ownerOfPort[object.oid] = structure.oid;
        if (object.parentOid == structure.oid) {
          outer = object.oid;
        } else {
          final frame = _frameOf(object.oid);
          if (frame != null) inner[frame] = object.oid;
        }
      }
      terminals.add(
        LvStructTerminal(
          oid: terminal.oid,
          role: role,
          outerPort: outer,
          innerPorts: inner,
          autoIndexing: ((terminal.objFlags ?? 0) & kLvAutoIndexTunnelFlag) != 0,
          partnerOid: partner,
          outerIsSink: outer != null && _isSink(outer),
        ),
      );
    }
    final label = kids[structure.oid]?.where((k) => k.kind == kLvSelectorLabelCode).firstOrNull;
    return LvStructUnit(
      oid: structure.oid,
      kind: kind,
      terminals: terminals,
      frames: [for (final frame in frames) _region(frame)],
      displayedFrame: structure.visibleFrameIndex,
      displayedCase: label?.label?.trim(),
      selectorRanges: structure.selectorRanges,
      selectorStrings: structure.selectorStrings,
      defaultFrame: structure.defaultFrameIndex ?? kViFirstFrameIsDefault,
    );
  }

  /// A structure's border-terminal records: the direct children that are a
  /// terminal class (`i`, the conditional terminal) plus the ones one level
  /// down under an outer holder (everything with an outside).
  Iterable<ViHeapObject> _terminalRecords(ViHeapObject structure) sync* {
    for (final child in kids[structure.oid] ?? const <ViHeapObject>[]) {
      if (LvTerminalRole.ofCode(child.kind) != null) {
        yield child;
        continue;
      }
      if (child.kind != kLvHolderCode) continue;
      for (final grand in kids[child.oid] ?? const <ViHeapObject>[]) {
        if (LvTerminalRole.ofCode(grand.kind) != null) yield grand;
      }
    }
  }
}
