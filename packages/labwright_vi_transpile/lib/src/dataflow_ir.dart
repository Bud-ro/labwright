import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'class_index.dart';
import 'declare.dart';
import 'subvi.dart';
import 'type_map.dart';
import 'wire_type.dart';

const int kLvSinkEndpointFlag = 0x8000;

/// A second flag marking an endpoint that consumes its wire, carried by some node terminals and
/// pane indicators that lack [kLvSinkEndpointFlag] and by no producing endpoint.
const int kLvInputEndpointFlag = 0x4000;

/// Whether a signal endpoint consumes the wire: a pane terminal by its indicator bit, any other by
/// [kLvSinkEndpointFlag] or [kLvInputEndpointFlag].
bool lvEndpointIsSink(BdObject object) {
  if (object.panelTerminal?.isIndicator case final indicator?) return indicator;
  return ((object.objFlags ?? 0) & (kLvSinkEndpointFlag | kLvInputEndpointFlag)) != 0;
}

const int kLvTunnelIndexerCode = 0x23;

/// How far below its output tunnel's record a condition terminal's record is drawn.
const int kConditionBelowTunnel = 9;

/// The heap kind of an In Place Element border node.
const int kInPlaceBorderNodeKind = 0x14f;

/// The marker object an In Place Element structure holds per Index/Replace Array Elements pair.
const int kInPlaceArrayPairKind = 0x158;

/// The marker object an In Place Element structure holds per Unbundle/Bundle Cluster Elements
/// pair, and the heap kind of that pair's border nodes.
const int kInPlaceClusterPairKind = 0x159;

const int kInPlaceClusterNodeKind = 0x150;

/// Set on the left border node of a pair, which reads the elements; clear on the right, which
/// writes them back.
const int kInPlaceLeftNodeFlag = 0x10000;

/// The high bits of a border node's terminal record that say what it is: `0x800000` the array
/// terminal, `0xe00000` a one-dimensional index terminal (fewer bits set index more dimensions),
/// and none of them an element terminal.
const int kInPlaceArrayTerminalFlag = 0x800000;

const int kInPlaceIndexTerminalFlag = 0xe00000;

bool lvTunnelAutoIndexes(Iterable<BdObject> children) =>
    children.any((child) => child.kind == kLvTunnelIndexerCode && (child.objFlags ?? 0) != 0);

/// Which boolean a loop's conditional terminal exits on, from bit `0x10000` of its record's
/// flags: set stops the loop on true, clear continues it on true.
enum LvConditionalPolarity {
  stopIfTrue,

  continueIfTrue;

  static const int _stopBit = 0x10000;

  static LvConditionalPolarity ofFlags(int flags) => flags & _stopBit != 0 ? stopIfTrue : continueIfTrue;
}

enum LvStructureKind {
  forLoop(0x20),

  whileLoop(0x21),

  caseStructure(0x2c),

  disableStructure(0xcd),

  flatSequence(0xca),

  inPlaceElement(0x14d);

  const LvStructureKind(this.code);

  final int code;

  static LvStructureKind? ofCode(int code) => _byCode[code];

  static final Map<int, LvStructureKind> _byCode = {for (final kind in values) kind.code: kind};
}

enum LvTerminalRole {
  iteration(0x24),

  conditional(0x25),

  count(0x26),

  leftShiftRegister(0x27),

  rightShiftRegister(0x28),

  loopTunnel(0x22),

  caseTunnel(0x2d),

  selector(0x2e),

  /// A Flat Sequence frame's tunnel to the enclosing diagram.
  sequenceTunnel(0x2a),

  /// A Flat Sequence frame's tunnel to the adjacent frame, whose outer endpoints the two frames'
  /// records wire to each other.
  sequenceBorder(0xcb),

  disableTunnel(0xce),

  /// A plain tunnel on an In Place Element structure's border.
  inPlaceTunnel(0x14e),

  /// The boolean condition terminal of a loop's conditional output tunnel, inner side only.
  tunnelCondition(0x176),

  /// An In Place Element border node's array terminal: its outer side is the structure's array
  /// holder, its inner side is unwired.
  inPlaceArray(-1),

  /// An In Place Element border node's index terminal, outer side only.
  inPlaceIndex(-2),

  /// An In Place Element border node's element terminal, inner side only: a source on the left
  /// node, a sink on the right.
  inPlaceElement(-3);

  const LvTerminalRole(this.code);

  final int code;

  static LvTerminalRole? ofCode(int code) => _byCode[code];

  static final Map<int, LvTerminalRole> _byCode = {for (final role in values) role.code: role};
}

enum LvRefusalKind {
  wireDirection,

  wireType,

  typeDeclaration,

  primitive,

  foreignCall,

  constantValue,

  structure,

  caseSelector,

  tunnelIndexing,

  tunnelCoercion,

  unwiredTerminal,

  cycle,

  endpointBinding,

  unboundValue,

  subViCall,

  /// A Property Node or Invoke Node, which acts on the class of a reference.
  referenceNode,

  noDiagram,
}

class LvRefusal {
  const LvRefusal(this.kind, this.detail, {this.oid});

  final LvRefusalKind kind;

  final String detail;

  final int? oid;

  @override
  String toString() => '${kind.name}: $detail${oid == null ? '' : ' (oid $oid)'}';
}

class LvRefusedException implements Exception {
  const LvRefusedException(this.refusal);

  final LvRefusal refusal;

  @override
  String toString() => 'LvRefusedException($refusal)';
}

Never lvRefuse(LvRefusalKind kind, String detail, {int? oid}) =>
    throw LvRefusedException(LvRefusal(kind, detail, oid: oid));

class LvEdge {
  const LvEdge({required this.signalOid, required this.source, required this.sinks, required this.type});

  final int signalOid;

  final int source;

  final List<int> sinks;

  final LvWireType type;
}

sealed class LvUnit {
  const LvUnit();

  int get oid;

  List<int> get inputPorts;

  List<int> get outputPorts;
}

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
    required this.nodeFlags,
    required this.portMemberName,
    required this.portTypes,
  });

  @override
  final int oid;

  final int classCode;

  final PrimOp? op;

  final int? primResId;

  final String? label;

  @override
  final List<int> inputPorts;

  @override
  final List<int> outputPorts;

  final Map<int, int> portRoleFlags;

  final Map<int, int> portDrawnTop;

  final int? nodeFlags;

  final Map<int, String> portMemberName;

  /// The descriptor each terminal's record resolves, by port.
  final Map<int, ViType> portTypes;
}

String lvForeignCallDetail(BdObject node) {
  final entry = node.foreignCall?.entryPoint;
  final library = node.foreignCall?.libraryPath;
  return 'the diagram calls ${entry == null ? 'an entry point' : '`$entry`'} in '
      '${library == null ? 'a native shared library the node names no path for' : '`$library`'}, '
      'whose behaviour is not in the VI';
}

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

  final int classCode;

  final String? calleeName;

  final List<int> panePorts;

  @override
  final List<int> inputPorts;

  @override
  final List<int> outputPorts;

  int? paneIndexOf(int port) {
    final index = panePorts.indexOf(port);
    return index < 0 ? null : index;
  }
}

class LvConstUnit extends LvUnit {
  const LvConstUnit({required this.oid, required this.port, required this.record, required this.label});

  @override
  final int oid;

  final int port;

  final BdObject record;

  final String? label;

  @override
  List<int> get inputPorts => const [];

  @override
  List<int> get outputPorts => [port];
}

class LvInterfaceUnit extends LvUnit {
  const LvInterfaceUnit({required this.oid, required this.name, required this.isIndicator, required this.bounds});

  @override
  final int oid;

  final String? name;

  final bool isIndicator;

  final HeapRect? bounds;

  @override
  List<int> get inputPorts => isIndicator ? [oid] : const [];

  @override
  List<int> get outputPorts => isIndicator ? const [] : [oid];
}

class LvStructTerminal {
  const LvStructTerminal({
    required this.oid,
    required this.role,
    required this.outerPort,
    required this.innerPorts,
    required this.autoIndexing,
    required this.partnerOid,
    required this.outerIsSink,
    this.polarity,
  });

  final int oid;

  final LvTerminalRole role;

  final int? outerPort;

  final Map<int, int> innerPorts;

  final bool autoIndexing;

  final int? partnerOid;

  final bool outerIsSink;

  /// A conditional terminal's exit test; null for every other role.
  final LvConditionalPolarity? polarity;
}

enum LvDisableFrame {
  enabled,
  disabled,
  other;

  static LvDisableFrame ofLabel(String? label) => switch (label?.trim().toLowerCase()) {
    'enabled' => enabled,
    'disabled' => disabled,
    _ => other,
  };
}

enum LvCaseLabel {
  isTrue('true'),
  isFalse('false'),
  error('error'),
  noError('no error'),
  other('');

  const LvCaseLabel(this.label);

  final String label;

  static LvCaseLabel ofLabel(String? label) => switch (label?.trim().toLowerCase()) {
    'true' => isTrue,
    'false' => isFalse,
    'error' => error,
    'no error' => noError,
    _ => other,
  };
}

/// One Index/Replace Array Elements pair of an In Place Element structure: the array holders on
/// each side and, per element, the index holders and the element ports inside the frame.
class LvInPlaceArrayPair {
  const LvInPlaceArrayPair({required this.arrayIn, required this.arrayOut, required this.elements});

  final int arrayIn;

  final int arrayOut;

  final List<({int indexIn, int indexOut, int elementOut, int elementIn})> elements;
}

/// One Unbundle/Bundle Cluster Elements pair of an In Place Element structure: the cluster
/// holders on each side and, per member read, its name and the element ports inside the frame.
class LvInPlaceClusterPair {
  const LvInPlaceClusterPair({required this.clusterIn, required this.clusterOut, required this.members});

  final int clusterIn;

  final int clusterOut;

  final List<({String name, int elementOut, int elementIn})> members;
}

class LvStructUnit extends LvUnit {
  LvStructUnit({
    required this.oid,
    required this.kind,
    required this.terminals,
    required this.frames,
    required this.displayedFrame,
    required this.displayedCase,
    this.selectorRanges = const <ViSelectorRange>[],
    this.selectorStrings = const <String>[],
    this.defaultFrame = 0,
    this.inPlacePairs = const <LvInPlaceArrayPair>[],
    this.inPlaceClusterPairs = const <LvInPlaceClusterPair>[],
  }) : displayedDisable = LvDisableFrame.ofLabel(displayedCase),
       displayedLabel = LvCaseLabel.ofLabel(displayedCase);

  @override
  final int oid;

  final LvStructureKind kind;

  final List<LvStructTerminal> terminals;

  final List<LvRegion> frames;

  final int displayedFrame;

  final String? displayedCase;

  final LvDisableFrame displayedDisable;

  final LvCaseLabel displayedLabel;

  final List<ViSelectorRange> selectorRanges;

  final List<String> selectorStrings;

  final int defaultFrame;

  final List<LvInPlaceArrayPair> inPlacePairs;

  final List<LvInPlaceClusterPair> inPlaceClusterPairs;

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

class LvRegion {
  const LvRegion({required this.frameOid, required this.units, required this.edges});

  final int frameOid;

  final List<LvUnit> units;

  final List<LvEdge> edges;
}

class LvDataflow {
  const LvDataflow({
    required this.root,
    required this.edgeBySink,
    required this.edgeBySource,
    required this.ownerOfPort,
    required this.sinkPorts,
    required this.wireRoutes,
  });

  final LvRegion root;

  final Map<int, LvEdge> edgeBySink;

  final Map<int, LvEdge> edgeBySource;

  final Map<int, int> ownerOfPort;

  final Set<int> sinkPorts;

  /// What decided each wire's type, by signal oid.
  final Map<int, LvWireRoute> wireRoutes;

  LvEdge? into(int port) => edgeBySink[port];

  LvEdge? outOf(int port) => edgeBySource[port];
}

/// Builds the dataflow of [diagram]. With [caller] and [resolve], a cluster wire no endpoint of
/// its own types takes its member shape from the connector-pane control of the callee it reaches;
/// [classes] supplies the LabVIEW classes the wires name.
({LvDataflow? dataflow, LvRefusal? refusal}) buildLvDataflow(
  BdDiagram diagram, {
  List<ViType> pool = const [],
  LvDeclarations? declarations,
  LvViUnit? caller,
  LvViResolver? resolve,
  LvClassIndex? classes,
}) {
  try {
    return (
      dataflow: _Builder(diagram, pool, declarations ?? LvDeclarations(), caller, resolve, classes).build(),
      refusal: null,
    );
  } on LvRefusedException catch (error) {
    return (dataflow: null, refusal: error.refusal);
  }
}

/// What decides each wire of [diagram], typed one wire at a time so a refused wire does not hide
/// the others: the [LvWireRoute] of each wire that types, by signal oid, and the refusal of each
/// that does not.
({Map<int, LvWireRoute> routes, Map<int, LvRefusal> refusals}) lvWireRouteCensus(
  BdDiagram diagram, {
  List<ViType> pool = const [],
  LvViUnit? caller,
  LvViResolver? resolve,
  LvClassIndex? classes,
}) {
  final builder = _Builder(diagram, pool, LvDeclarations(), caller, resolve, classes);
  final refusals = <int, LvRefusal>{};
  for (final wire in diagram.wires) {
    try {
      final signal = wire.signalType;
      if (signal == null) {
        lvRefuse(LvRefusalKind.wireType, 'signal carries no decoded type word', oid: wire.signalOid);
      }
      final type = builder._wireType(wire, signal);
      if (!type.isMapped) {
        lvRefuse(LvRefusalKind.wireType, type.value.note ?? 'wire type is unmapped', oid: wire.signalOid);
      }
    } on LvRefusedException catch (error) {
      builder.wireRoutes.remove(wire.signalOid);
      refusals[wire.signalOid] = error.refusal;
    }
  }
  return (routes: builder.wireRoutes, refusals: refusals);
}

class _Builder {
  _Builder(this.diagram, this.pool, this.declarations, this.caller, this.resolve, this.classes) : byId = diagram.byId;

  final BdDiagram diagram;
  final List<ViType> pool;
  final LvDeclarations declarations;
  final LvViUnit? caller;
  final LvViResolver? resolve;
  final LvClassIndex? classes;
  final HeapObjectsByOid<BdObject> byId;

  /// Each sub-VI call port by its oid: the call node and the pane index the port draws.
  late final Map<int, (BdObject node, int pane)> _callPorts = {
    for (final node in diagram.objects)
      if (kSubViCallNodeCodes.contains(node.kind))
        for (final (pane, holder)
            in diagram.childrenOf(node).where((c) => c.objectClass == BdObjectClass.terminalHolder).indexed)
          holder.oid: (node, pane),
  };

  /// The callee behind a sub-VI call port, resolved through the caller's link entry.
  final Map<int, LvViUnit?> _calleeOfNode = {};

  LvViUnit? _calleeOf(BdObject node) => _calleeOfNode.putIfAbsent(node.oid, () {
    final unit = caller;
    final name = node.label?.trim();
    if (unit == null || resolve == null || name == null) return null;
    final lower = name.toLowerCase();
    if (!lower.endsWith('.vi') && !lower.endsWith('.vim')) return null;
    final link = unit.linkTo(name);
    if (link == null && unit.links.any((l) => l.qualifiedName.lastOrNull?.toLowerCase() == lower)) return null;
    return resolve!(LvCallee(caller: unit, fileName: name, link: link));
  });

  /// The number of connector-pane terminals each sub-VI call node draws, by node oid.
  late final Map<int, int> _callPortCounts = _countCallPorts();

  Map<int, int> _countCallPorts() {
    final counts = <int, int>{};
    for (final (node, _) in _callPorts.values) {
      counts[node.oid] = (counts[node.oid] ?? 0) + 1;
    }
    return counts;
  }

  /// The callee behind [endpoint], a sub-VI call port, and its connector-pane terminal there,
  /// when the node draws as many terminals as the callee's pane has.
  (LvViUnit, BdObject)? _paneTerminal(int endpoint) {
    final port = _callPorts[endpoint];
    if (port == null) return null;
    final (node, pane) = port;
    final callee = _calleeOf(node);
    if (callee == null || callee.paneTerminals.length != _callPortCounts[node.oid]) return null;
    final terminal = callee.paneTerminal(pane);
    return terminal == null ? null : (callee, terminal);
  }

  /// The cluster type the callee's connector-pane control gives [endpoint], a sub-VI call port.
  (ViType, List<ViType>)? _paneCluster(int endpoint, {required bool array}) {
    if (_paneTerminal(endpoint) case (final callee, final terminal)) {
      final cluster = lvClusterOfEndpoint(callee.diagram, terminal.oid, array: array);
      return cluster == null ? null : (cluster, callee.pool);
    }
    return null;
  }

  /// The refnum dimensionality the callee's connector-pane control gives [endpoint].
  int? _paneRefnumDims(int endpoint) {
    if (_paneTerminal(endpoint) case (final callee, final terminal)) {
      return lvRefnumDimsOfTerminal(callee.diagram, terminal.oid);
    }
    return null;
  }

  final edgeBySink = <int, LvEdge>{};
  final edgeBySource = <int, LvEdge>{};
  final ownerOfPort = <int, int>{};
  final sinkPorts = <int>{};
  final wireRoutes = <int, LvWireRoute>{};

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
      wireRoutes: wireRoutes,
    );
  }

  int _rootFrame() {
    for (final object in diagram.objects) {
      if (object.parentOid == null) {
        final frame = diagram.childrenOf(object).where((child) => child.objectClass == BdObjectClass.frame).firstOrNull;
        if (frame != null) return frame.oid;
      }
    }
    lvRefuse(LvRefusalKind.noDiagram, 'the diagram has no top-level frame');
  }

  bool _isSink(int oid) {
    final holder = byId[oid];
    if (holder == null) {
      lvRefuse(LvRefusalKind.endpointBinding, 'signal endpoint $oid resolves to no heap object', oid: oid);
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
        lvRefuse(
          LvRefusalKind.wireDirection,
          'signal has ${sources.length} source endpoints among ${wire.endpointOids.length}; '
          'exactly one endpoint must read as a producer ([lvEndpointIsSink])',
          oid: wire.signalOid,
        );
      }
      final signal = wire.signalType;
      if (signal == null) {
        lvRefuse(LvRefusalKind.wireType, 'signal carries no decoded type word', oid: wire.signalOid);
      }
      final type = _wireType(wire, signal);
      if (!type.isMapped) {
        lvRefuse(LvRefusalKind.wireType, type.value.note ?? 'wire type is unmapped', oid: wire.signalOid);
      }
      for (final declaration in lvDeclarationClosure(type.declarations)) {
        if (declaration.undeclarable case final why?) {
          lvRefuse(
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

  LvWireType _wireType(ViWire wire, ViSignalType signal) {
    final direct = mapLvWireType(signal);
    if (direct.isMapped) {
      if (direct.numeric case final kind? when !kind.isFloat) {
        if (_enumWireType(wire, signal, direct) case final enumeration?) return enumeration;
      }
      wireRoutes[wire.signalOid] = LvWireRoute.signalWord;
      return direct;
    }
    final code = signal.typeCode;
    if (kLvWireRefnumCodes.contains(code)) return _refnumWireType(wire, signal, direct);
    final array = (signal.arrayDims ?? 0) > 0;
    if (code == kLvUntypedSignalCode) {
      final reading = lvScalarOfEndpoints(diagram, wire, pool);
      if (reading == null) return direct;
      final mapped = mapLvType(reading, pool, 0, declarations);
      if (!mapped.isMapped) return direct;
      wireRoutes[wire.signalOid] = LvWireRoute.untypedEndpoint;
      return LvWireType.scalarOf(mapped);
    }
    if (code == TypeCode.measureData) {
      if (wire.endpointOids.any((endpoint) => lvEndpointIsTimestamp(diagram, endpoint, array: array))) {
        wireRoutes[wire.signalOid] = LvWireRoute.timestamp;
        return lvTimestampWireType(signal);
      }
      return direct;
    }
    if (code == TypeCode.tag) {
      if (wire.endpointOids.any((endpoint) => lvTagEndpointIsRefnum(diagram, endpoint, array: array))) {
        wireRoutes[wire.signalOid] = LvWireRoute.tagRefnum;
        return lvRefnumHandleWireType(signal);
      }
      return direct;
    }
    if (!kLvWireClusterCodes.contains(code)) return direct;
    return _clusterWireType(wire, signal, direct);
  }

  /// An integer-coded wire carrying an enum of the word's width: the enum its source endpoint
  /// resolves, else the one every resolving sink agrees on; null when the source resolves a plain
  /// integer, when no end resolves an enum, or when the sinks disagree and the source is silent.
  LvWireType? _enumWireType(ViWire wire, ViSignalType signal, LvWireType direct) {
    final array = direct.dims > 0;
    List<LvTypeMapping> readingsOf(int endpoint) => [
      for (final type in lvEnumsOfEndpoint(diagram, endpoint, array: array))
        if (lvEnumIntegerCode(type) == signal.typeCode) mapLvType(type, pool, 0, declarations),
    ];
    final source = wire.endpointOids.firstWhere((oid) => !_isSink(oid));
    var readings = readingsOf(source);
    if (readings.isEmpty) {
      if (lvEndpointResolvesInteger(diagram, source, array: array)) return null;
      readings = [
        for (final endpoint in wire.endpointOids)
          if (endpoint != source) ...readingsOf(endpoint),
      ];
    }
    final types = {for (final reading in readings) reading.dartType};
    if (types.length != 1 || !readings.first.isMapped) return null;
    wireRoutes[wire.signalOid] = LvWireRoute.enumeration;
    return lvElementWireType(readings.first, direct.dims);
  }

  /// A refnum wire's dimensionality from its endpoints' node-terminal parts, else from the
  /// callee's connector pane, else zero from an endpoint's own scalar descriptor; the parts and
  /// the pane must agree where both speak. An endpoint naming a class types the wire as that
  /// class's object.
  LvWireType _refnumWireType(ViWire wire, ViSignalType signal, LvWireType direct) {
    var dims = signal.arrayDims;
    var route = LvWireRoute.signalWord;
    if (dims == null) {
      final parts = lvRefnumPartDims(diagram, wire);
      int? pane;
      for (final endpoint in wire.endpointOids) {
        final reading = _paneRefnumDims(endpoint);
        if (reading == null) continue;
        if (pane != null && pane != reading) {
          lvRefuse(
            LvRefusalKind.wireType,
            'the callees at the wire\'s ends declare $pane- and $reading-dimensional refnums, so its '
            'dimensionality is not decided',
            oid: wire.signalOid,
          );
        }
        pane = reading;
      }
      if (parts != null && pane != null && parts != pane) {
        lvRefuse(
          LvRefusalKind.wireType,
          'the wire\'s node-terminal parts carry a $parts-dimensional refnum where the callee\'s '
          'connector pane declares $pane dimensions, so its dimensionality is not decided',
          oid: wire.signalOid,
        );
      }
      if (kLvRefnumContradictedCells.contains((signal.typeCode, signal.depth))) {
        if (parts != null && pane == parts) {
          dims = parts;
          route = LvWireRoute.pane;
        }
      } else if (parts != null) {
        dims = parts;
        route = LvWireRoute.part;
      } else if (pane != null) {
        dims = pane;
        route = LvWireRoute.pane;
      } else if (lvRefnumEndpointIsScalar(diagram, wire)) {
        dims = 0;
        route = LvWireRoute.endpoint;
      }
    }
    if (dims == null) return direct;
    if (_classOfWire(wire, array: dims > 0) case final qualifiedName?) {
      final element = lvClassObjectType(qualifiedName, classes, declarations);
      wireRoutes[wire.signalOid] = LvWireRoute.classObject;
      return lvElementWireType(element, dims);
    }
    wireRoutes[wire.signalOid] = route;
    return lvRefnumWireType(signal, dims);
  }

  /// The class a refnum wire carries: the one its source endpoint names, which every sink must
  /// name or be an ancestor of, as a child object is wired into a parent-typed terminal; when the
  /// source names none, the one class the sinks agree on. Null when no endpoint names a class.
  List<String>? _classOfWire(ViWire wire, {required bool array}) {
    List<String>? source;
    final sinks = <String, List<String>>{};
    for (final endpoint in wire.endpointOids) {
      final named = lvClassOfEndpoint(diagram, endpoint, array: array);
      if (named == null) continue;
      if (_isSink(endpoint)) {
        sinks[named.join(':')] = named;
      } else {
        source = named;
      }
    }
    if (source == null) {
      if (sinks.length > 1) {
        lvRefuse(
          LvRefusalKind.wireType,
          'the wire\'s sinks name ${sinks.length} different classes and its source names none, so the '
          'object it carries is not decided',
          oid: wire.signalOid,
        );
      }
      return sinks.values.firstOrNull;
    }
    for (final sink in sinks.values) {
      if (!lvClassDescendsFrom(source, sink, classes)) {
        lvRefuse(
          LvRefusalKind.wireType,
          'the wire carries a ${source.join(':')} object into a terminal declared ${sink.join(':')}, which it '
          'does not descend from',
          oid: wire.signalOid,
        );
      }
    }
    return source;
  }

  /// A cluster wire's member shape from the descriptors its endpoints resolve, else from the
  /// node-terminal and structure-terminal records under them, else from the callee's connector
  /// pane; the readings of the route taken must map to one Dart type.
  LvWireType _clusterWireType(ViWire wire, ViSignalType signal, LvWireType direct) {
    final array = (signal.arrayDims ?? 0) > 0;
    var route = LvWireRoute.endpoint;
    var readings = <LvWireType>[
      for (final endpoint in wire.endpointOids)
        if (lvClusterOfEndpoint(diagram, endpoint, array: array) case final cluster?)
          lvClusterWireType(signal, cluster, pool, declarations),
    ];
    if (readings.isEmpty) {
      route = LvWireRoute.part;
      readings = [
        for (final endpoint in wire.endpointOids)
          for (final cluster in lvClustersOfParts(diagram, endpoint, array: array))
            lvClusterWireType(signal, cluster, pool, declarations),
      ];
    }
    if (readings.isEmpty) {
      route = LvWireRoute.pane;
      readings = [
        for (final endpoint in wire.endpointOids)
          if (_paneCluster(endpoint, array: array) case (final cluster, final calleePool))
            lvClusterWireType(signal, cluster, calleePool, declarations),
      ];
    }
    if (readings.isEmpty) return direct;
    final types = {for (final reading in readings) reading.dartType};
    if (types.length != 1) {
      lvRefuse(
        LvRefusalKind.wireType,
        'the wire\'s ${route.name} descriptors resolve ${types.length} different Dart types, '
        'so the value it carries is not decided',
        oid: wire.signalOid,
      );
    }
    wireRoutes[wire.signalOid] = route;
    return readings.first;
  }

  int? _frameOf(int oid) {
    var current = byId[oid];
    for (var depth = 0; current != null && depth < 64; depth++) {
      final parent = current.parentOid;
      if (parent == null) return null;
      final object = byId[parent];
      if (object == null) return null;
      if (object.objectClass == BdObjectClass.frame) return object.oid;
      current = object;
    }
    return null;
  }

  LvRegion _region(int frameOid) {
    final units = <LvUnit>[];
    for (final child in diagram.children(frameOid)) {
      switch (child.category) {
        case BdObjectKind.node:
          if (child.kind == kInPlaceBorderNodeKind || child.kind == kInPlaceClusterNodeKind) continue;
          units.add(kSubViCallNodeCodes.contains(child.kind) ? _subViUnit(child) : _primUnit(child));
        case BdObjectKind.structure:
          units.add(_structUnit(child));
        case _:
          if (child.kind == BdObjectClass.wire.code) units.addAll(_wireRecordUnits(child));
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

  LvSubViUnit _subViUnit(BdObject node) {
    final ports = <int>[];
    final inputs = <int>[], outputs = <int>[];
    for (final holder in diagram.childrenOf(node)) {
      if (holder.objectClass != BdObjectClass.terminalHolder) continue;
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

  LvPrimUnit _primUnit(BdObject node) {
    final inputs = <int>[], outputs = <int>[];
    final roleFlags = <int, int>{};
    final drawnTop = <int, int>{};
    final memberName = <int, String>{};
    final types = <int, ViType>{};
    for (final holder in diagram.childrenOf(node)) {
      if (holder.objectClass != BdObjectClass.terminalHolder) continue;
      ownerOfPort[holder.oid] = node.oid;
      (_isSink(holder.oid) ? inputs : outputs).add(holder.oid);
      final record = diagram.childrenOf(holder).firstOrNull;
      roleFlags[holder.oid] = record?.objFlags ?? 0;
      if (record?.typeName case final name?) memberName[holder.oid] = name;
      if (record?.resolvedType?.type case final type?) types[holder.oid] = type;
      final attach = diagram.dcoChildTerminalAttach(holder.oid);
      if (attach != null) drawnTop[holder.oid] = attach.candidates.first.y;
    }
    return LvPrimUnit(
      oid: node.oid,
      classCode: node.kind,
      op: switch (node.primitive?.primResId) {
        final id? => PrimOp.fromId(id),
        null => null,
      },
      primResId: node.primitive?.primResId,
      label: _captionOf(node),
      inputPorts: inputs,
      outputPorts: outputs,
      portRoleFlags: roleFlags,
      portDrawnTop: drawnTop,
      nodeFlags: node.objFlags,
      portMemberName: memberName,
      portTypes: types,
    );
  }

  List<LvUnit> _wireRecordUnits(BdObject record) {
    final units = <LvUnit>[];
    for (final child in diagram.childrenOf(record)) {
      if (child.kind == BdObjectClass.panelTerminal.code) {
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
      if (child.objectClass != BdObjectClass.terminalHolder) continue;
      if (child.memberOids.isNotEmpty) continue;
      final constant = diagram
          .childrenOf(child)
          .where((child) => child.kind == BdObjectClass.constant.code)
          .firstOrNull;
      if (constant == null) {
        lvRefuse(
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

  static String? _captionOf(BdObject node) {
    final label = nodeDisplayLabel(node);
    return label.isHint ? null : label.text;
  }

  String? _constantLabel(BdObject constant) {
    for (final shell in diagram.childrenOf(constant)) {
      for (final part in diagram.childrenOf(shell)) {
        if (part.kind == BdObjectClass.textLabel.code) {
          final text = part.label?.trim();
          if (text != null && text.isNotEmpty) return text;
        }
      }
    }
    return null;
  }

  LvStructUnit _structUnit(BdObject structure) {
    final kind = LvStructureKind.ofCode(structure.kind);
    if (kind == null) {
      lvRefuse(
        LvRefusalKind.structure,
        'structure class 0x${structure.kind.toRadixString(16)} '
        '(${structure.objectClass.label}) has no modelled control flow',
        oid: structure.oid,
      );
    }
    final frames = [
      for (final child in diagram.childrenOf(structure))
        if (child.objectClass == BdObjectClass.frame) child.oid,
      if (kind == LvStructureKind.flatSequence)
        for (final sequenceFrame in diagram.childrenOf(structure))
          if (sequenceFrame.objectClass == BdObjectClass.sequenceFrame)
            for (final child in diagram.childrenOf(sequenceFrame))
              if (child.objectClass == BdObjectClass.frame) child.oid,
    ];
    final frameSet = frames.toSet();
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
        if (object.objectClass != BdObjectClass.terminalHolder) {
          if (LvTerminalRole.ofCode(object.kind) != null) partner = object.oid;
          continue;
        }
        ownerOfPort[object.oid] = structure.oid;
        final frame = _frameOf(object.oid);
        if (frame != null && frameSet.contains(frame)) {
          inner[frame] = object.oid;
        } else {
          outer = object.oid;
        }
      }
      terminals.add(
        LvStructTerminal(
          oid: terminal.oid,
          role: role,
          outerPort: outer,
          innerPorts: inner,
          autoIndexing: lvTunnelAutoIndexes(diagram.childrenOf(terminal)),
          partnerOid: partner,
          outerIsSink: outer != null && _isSink(outer),
          polarity: role == LvTerminalRole.conditional ? LvConditionalPolarity.ofFlags(terminal.objFlags ?? 0) : null,
        ),
      );
    }
    final label = diagram
        .childrenOf(structure)
        .where((child) => child.kind == BdObjectClass.caseSelectorLabel.code)
        .firstOrNull;
    _pairConditions(terminals);
    var pairs = const <LvInPlaceArrayPair>[];
    var clusterPairs = const <LvInPlaceClusterPair>[];
    if (kind == LvStructureKind.inPlaceElement) {
      final inPlace = _inPlacePairs(structure, frames.singleOrNull);
      terminals.addAll(inPlace.terminals);
      pairs = inPlace.pairs;
      clusterPairs = inPlace.clusterPairs;
    }
    return LvStructUnit(
      oid: structure.oid,
      kind: kind,
      terminals: terminals,
      inPlacePairs: pairs,
      inPlaceClusterPairs: clusterPairs,
      frames: [for (final frame in frames) _region(frame)],
      displayedFrame: structure.frames?.visibleFrameIndex ?? 0,
      displayedCase: label?.label?.trim(),
      selectorRanges: structure.caseFrames?.selectorRanges ?? const [],
      selectorStrings: structure.caseFrames?.selectorStrings ?? const [],
      defaultFrame: structure.caseFrames?.defaultFrameIndex ?? kViFirstFrameIsDefault,
    );
  }

  /// An In Place Element structure's Index/Replace Array Elements and Unbundle/Bundle Cluster
  /// Elements pairs: each is a left and a right border node inside the frame, whose array or
  /// cluster and index terminals name the structure's holders through their members and whose
  /// element terminals are the frame's ports; a cluster element terminal's type name is the
  /// member it reads or writes.
  ({List<LvStructTerminal> terminals, List<LvInPlaceArrayPair> pairs, List<LvInPlaceClusterPair> clusterPairs})
  _inPlacePairs(BdObject structure, int? frameOid) {
    final markers = [
      for (final child in diagram.childrenOf(structure))
        if (child.objectClass != BdObjectClass.terminalHolder &&
            child.objectClass != BdObjectClass.frame &&
            child.kind != BdObjectClass.textLabel.code)
          child.kind,
    ];
    if (frameOid == null ||
        markers.isEmpty ||
        markers.any((kind) => kind != kInPlaceArrayPairKind && kind != kInPlaceClusterPairKind)) {
      lvRefuse(
        LvRefusalKind.structure,
        'an In Place Element structure whose border-node pairs are '
        '${markers.map((kind) => '0x${kind.toRadixString(16)}').join(', ')} has no modelled control '
        'flow; only Index/Replace Array Elements (0x${kInPlaceArrayPairKind.toRadixString(16)}) and '
        'Unbundle/Bundle Cluster Elements (0x${kInPlaceClusterPairKind.toRadixString(16)}) do',
        oid: structure.oid,
      );
    }
    final terminals = <LvStructTerminal>[];
    final sides = <int, List<({int anchor, List<int> indices, List<String> names, List<int> elements, bool left})>>{};
    for (final node in diagram.children(frameOid)) {
      if (node.kind != kInPlaceBorderNodeKind && node.kind != kInPlaceClusterNodeKind) continue;
      final isLeft = ((node.objFlags ?? 0) & kInPlaceLeftNodeFlag) != 0;
      int? anchor;
      final indices = <int>[], names = <String>[], elements = <int>[];
      for (final holder in diagram.childrenOf(node)) {
        if (holder.objectClass != BdObjectClass.terminalHolder) continue;
        final record = diagram.childrenOf(holder).firstOrNull;
        if (record == null) continue;
        final kindBits = (record.objFlags ?? 0) & kInPlaceIndexTerminalFlag;
        if (kindBits == 0) {
          ownerOfPort[holder.oid] = structure.oid;
          elements.add(holder.oid);
          if (node.kind == kInPlaceClusterNodeKind) {
            final name = record.typeName;
            if (name == null) {
              lvRefuse(
                LvRefusalKind.structure,
                'an Unbundle/Bundle Cluster Elements terminal names no member',
                oid: structure.oid,
              );
            }
            names.add(name);
          }
          terminals.add(
            LvStructTerminal(
              oid: record.oid,
              role: LvTerminalRole.inPlaceElement,
              outerPort: null,
              innerPorts: {frameOid: holder.oid},
              autoIndexing: false,
              partnerOid: null,
              outerIsSink: false,
            ),
          );
          continue;
        }
        final outer = record.memberOids.where((member) => byId[member]?.parentOid == structure.oid).firstOrNull;
        if (outer == null) continue;
        ownerOfPort[outer] = structure.oid;
        final role = kindBits == kInPlaceArrayTerminalFlag ? LvTerminalRole.inPlaceArray : LvTerminalRole.inPlaceIndex;
        if (role == LvTerminalRole.inPlaceArray) {
          anchor = outer;
        } else {
          if (kindBits != kInPlaceIndexTerminalFlag) {
            lvRefuse(
              LvRefusalKind.structure,
              'an Index/Replace Array Elements pair indexes more than one dimension, which is not modelled',
              oid: structure.oid,
            );
          }
          indices.add(outer);
        }
        terminals.add(
          LvStructTerminal(
            oid: record.oid,
            role: role,
            outerPort: outer,
            innerPorts: const {},
            autoIndexing: false,
            partnerOid: null,
            outerIsSink: _isSink(outer),
          ),
        );
      }
      if (anchor == null || (node.kind == kInPlaceBorderNodeKind && indices.length != elements.length)) {
        lvRefuse(
          LvRefusalKind.structure,
          'an In Place Element border node draws ${indices.length} indices for ${elements.length} elements',
          oid: node.oid,
        );
      }
      sides.putIfAbsent(node.kind, () => []).add((
        anchor: anchor,
        indices: indices,
        names: names,
        elements: elements,
        left: isLeft,
      ));
    }
    final pairs = <LvInPlaceArrayPair>[];
    final clusterPairs = <LvInPlaceClusterPair>[];
    for (final MapEntry(key: nodeKind, value: nodes) in sides.entries) {
      final lefts = nodes.where((node) => node.left).toList(), rights = nodes.where((node) => !node.left).toList();
      if (lefts.length != rights.length) {
        lvRefuse(
          LvRefusalKind.structure,
          'an In Place Element structure draws ${lefts.length} left and ${rights.length} right border nodes',
          oid: structure.oid,
        );
      }
      for (var i = 0; i < lefts.length; i++) {
        final left = lefts[i], right = rights[i];
        if (left.elements.length != right.elements.length) {
          lvRefuse(LvRefusalKind.structure, 'an In Place Element pair is uneven', oid: structure.oid);
        }
        if (nodeKind == kInPlaceBorderNodeKind) {
          pairs.add(
            LvInPlaceArrayPair(
              arrayIn: left.anchor,
              arrayOut: right.anchor,
              elements: [
                for (var k = 0; k < left.elements.length; k++)
                  (
                    indexIn: left.indices[k],
                    indexOut: right.indices[k],
                    elementOut: left.elements[k],
                    elementIn: right.elements[k],
                  ),
              ],
            ),
          );
        } else {
          for (var k = 0; k < left.elements.length; k++) {
            if (left.names[k] != right.names[k]) {
              lvRefuse(
                LvRefusalKind.structure,
                'an Unbundle/Bundle Cluster Elements pair names different members',
                oid: structure.oid,
              );
            }
          }
          clusterPairs.add(
            LvInPlaceClusterPair(
              clusterIn: left.anchor,
              clusterOut: right.anchor,
              members: [
                for (var k = 0; k < left.elements.length; k++)
                  (name: left.names[k], elementOut: left.elements[k], elementIn: right.elements[k]),
              ],
            ),
          );
        }
      }
    }
    if (pairs.isEmpty && clusterPairs.isEmpty) {
      lvRefuse(LvRefusalKind.structure, 'an In Place Element structure draws no border-node pair', oid: structure.oid);
    }
    return (terminals: terminals, pairs: pairs, clusterPairs: clusterPairs);
  }

  /// Names, on each condition terminal, the output tunnel it gates: the one whose record is drawn
  /// [kConditionBelowTunnel] pixels below its own at the same left, which every corpus loop has.
  void _pairConditions(List<LvStructTerminal> terminals) {
    for (var i = 0; i < terminals.length; i++) {
      final condition = terminals[i];
      if (condition.role != LvTerminalRole.tunnelCondition) continue;
      final at = _recordBounds(condition.oid);
      if (at == null) continue;
      for (final tunnel in terminals) {
        if (tunnel.role != LvTerminalRole.loopTunnel || tunnel.outerIsSink) continue;
        final box = _recordBounds(tunnel.oid);
        if (box == null || box.left != at.left || at.top - box.top != kConditionBelowTunnel) continue;
        terminals[i] = LvStructTerminal(
          oid: condition.oid,
          role: condition.role,
          outerPort: condition.outerPort,
          innerPorts: condition.innerPorts,
          autoIndexing: condition.autoIndexing,
          partnerOid: tunnel.oid,
          outerIsSink: condition.outerIsSink,
        );
        break;
      }
    }
  }

  HeapRect? _recordBounds(int oid) {
    final record = byId[oid];
    return record == null ? null : record.absBounds ?? record.termBounds;
  }

  Iterable<BdObject> _terminalRecords(BdObject structure) sync* {
    for (final child in diagram.childrenOf(structure)) {
      if (LvTerminalRole.ofCode(child.kind) != null) {
        yield child;
        continue;
      }
      if (child.objectClass == BdObjectClass.sequenceFrame) {
        for (final holder in diagram.childrenOf(child)) {
          yield* _holderRecords(holder);
        }
        continue;
      }
      yield* _holderRecords(child);
    }
  }

  Iterable<BdObject> _holderRecords(BdObject holder) sync* {
    if (holder.objectClass != BdObjectClass.terminalHolder) return;
    for (final record in diagram.childrenOf(holder)) {
      if (LvTerminalRole.ofCode(record.kind) != null) yield record;
    }
  }
}
