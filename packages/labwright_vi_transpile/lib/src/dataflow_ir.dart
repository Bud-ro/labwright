import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

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
bool lvEndpointIsSink(ViHeapObject object) {
  if (object.kind == HeapObjectClass.bdLeaf.code) {
    if (object.isIndicator case final indicator?) return indicator;
  }
  return ((object.objFlags ?? 0) & (kLvSinkEndpointFlag | kLvInputEndpointFlag)) != 0;
}

const int kLvTunnelIndexerCode = 0x23;

bool lvTunnelAutoIndexes(Iterable<ViHeapObject> children) =>
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

  flatSequence(0xca);

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

  disableTunnel(0xce);

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
}

String lvForeignCallDetail(ViHeapObject node) {
  final entry = node.foreignEntryPoint;
  final library = node.foreignLibraryPath;
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

  final ViHeapObject record;

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
  });

  final LvRegion root;

  final Map<int, LvEdge> edgeBySink;

  final Map<int, LvEdge> edgeBySource;

  final Map<int, int> ownerOfPort;

  final Set<int> sinkPorts;

  LvEdge? into(int port) => edgeBySink[port];

  LvEdge? outOf(int port) => edgeBySource[port];
}

/// Builds the dataflow of [diagram]. With [caller] and [resolve], a cluster wire no endpoint of
/// its own types takes its member shape from the connector-pane control of the callee it reaches.
({LvDataflow? dataflow, LvRefusal? refusal}) buildLvDataflow(
  ViDiagram diagram, {
  List<ViType> pool = const [],
  LvDeclarations? declarations,
  LvViUnit? caller,
  LvViResolver? resolve,
  LvClassResolver? resolveClass,
}) {
  try {
    return (
      dataflow: _Builder(diagram, pool, declarations ?? LvDeclarations(), caller, resolve, resolveClass).build(),
      refusal: null,
    );
  } on LvRefusedException catch (error) {
    return (dataflow: null, refusal: error.refusal);
  }
}

class _Builder {
  _Builder(this.diagram, this.pool, this.declarations, this.caller, this.resolve, this.resolveClass)
    : byId = diagram.byId;

  final ViDiagram diagram;
  final List<ViType> pool;
  final LvDeclarations declarations;
  final LvViUnit? caller;
  final LvViResolver? resolve;
  final LvClassResolver? resolveClass;
  final ViObjectsByOid byId;

  final Map<String, ViModel?> _classData = {};

  ViModel? _privateDataOf(List<String> qualifiedName) =>
      _classData.putIfAbsent(qualifiedName.join(':'), () => resolveClass?.call(qualifiedName));

  /// Each sub-VI call port by its oid: the call node and the pane index the port draws.
  late final Map<int, (ViHeapObject node, int pane)> _callPorts = {
    for (final node in diagram.objects)
      if (kSubViCallNodeCodes.contains(node.kind))
        for (final (pane, holder) in diagram.childrenOf(node).where((c) => c.kind == kNodeEndpointDcoKind).indexed)
          holder.oid: (node, pane),
  };

  /// The callee behind a sub-VI call port, resolved through the caller's link entry.
  final Map<int, LvViUnit?> _calleeOfNode = {};

  LvViUnit? _calleeOf(ViHeapObject node) => _calleeOfNode.putIfAbsent(node.oid, () {
    final unit = caller;
    final name = node.label?.trim();
    if (unit == null || resolve == null || name == null) return null;
    final lower = name.toLowerCase();
    if (!lower.endsWith('.vi') && !lower.endsWith('.vim')) return null;
    final link = unit.linkTo(name);
    if (link == null && unit.links.any((l) => l.qualifiedName.lastOrNull?.toLowerCase() == lower)) return null;
    return resolve!(LvCallee(caller: unit, fileName: name, link: link));
  });

  /// The cluster type the callee's connector-pane control gives [endpoint], a sub-VI call port.
  (ViType, List<ViType>)? _paneCluster(int endpoint, {required bool array}) {
    final port = _callPorts[endpoint];
    if (port == null) return null;
    final (node, pane) = port;
    final callee = _calleeOf(node);
    if (callee == null || callee.paneTerminals.length != _callPorts.values.where((p) => p.$1 == node).length) {
      return null;
    }
    final terminal = callee.paneTerminal(pane);
    if (terminal == null) return null;
    final cluster = lvClusterOfEndpoint(callee.diagram, terminal.oid, array: array);
    return cluster == null ? null : (cluster, callee.pool);
  }

  final edgeBySink = <int, LvEdge>{};
  final edgeBySource = <int, LvEdge>{};
  final ownerOfPort = <int, int>{};
  final sinkPorts = <int>{};

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

  int _rootFrame() {
    for (final object in diagram.objects) {
      if (object.parentOid == null) {
        final frame = diagram
            .childrenOf(object)
            .where((child) => child.objectClass == HeapObjectClass.bdFrame)
            .firstOrNull;
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
    if (direct.isMapped) return direct;
    if (kLvWireRefnumCodes.contains(signal.typeCode)) {
      final dims = lvRefnumWireDims(diagram, wire) ?? signal.arrayDims;
      final classes = <String>{};
      List<String>? qualifiedName;
      for (final endpoint in wire.endpointOids) {
        if (lvClassOfEndpoint(diagram, endpoint, array: (dims ?? 0) > 0) case final named?) {
          qualifiedName = named;
          classes.add(named.join(':'));
        }
      }
      if (qualifiedName != null) {
        if (classes.length != 1) {
          lvRefuse(
            LvRefusalKind.wireType,
            'the wire\'s endpoints name ${classes.length} different classes, so the object it carries is not decided',
            oid: wire.signalOid,
          );
        }
        final element = lvClassObjectType(qualifiedName, _privateDataOf(qualifiedName), declarations);
        return lvClassObjectWireType(element, dims ?? 0);
      }
      return dims == null ? direct : lvRefnumWireType(signal, dims);
    }
    if (!kLvWireClusterCodes.contains(signal.typeCode)) return direct;
    final array = (signal.arrayDims ?? 0) > 0;
    final readings = <LvWireType>[
      for (final endpoint in wire.endpointOids)
        if (lvClusterOfEndpoint(diagram, endpoint, array: array) case final cluster?)
          lvClusterWireType(signal, cluster, pool, declarations),
    ];
    if (readings.isEmpty) {
      for (final endpoint in wire.endpointOids) {
        if (_paneCluster(endpoint, array: array) case (final cluster, final calleePool)) {
          readings.add(lvClusterWireType(signal, cluster, calleePool, declarations));
        }
      }
    }
    if (readings.isEmpty) return direct;
    final types = {for (final reading in readings) reading.dartType};
    if (types.length != 1) {
      lvRefuse(
        LvRefusalKind.wireType,
        'the wire\'s endpoints resolve ${types.length} different Dart types, '
        'so the value it carries is not decided',
        oid: wire.signalOid,
      );
    }
    return readings.first;
  }

  int? _frameOf(int oid) {
    var current = byId[oid];
    for (var depth = 0; current != null && depth < 64; depth++) {
      final parent = current.parentOid;
      if (parent == null) return null;
      final object = byId[parent];
      if (object == null) return null;
      if (object.objectClass == HeapObjectClass.bdFrame) return object.oid;
      current = object;
    }
    return null;
  }

  LvRegion _region(int frameOid) {
    final units = <LvUnit>[];
    for (final child in diagram.children(frameOid)) {
      switch (child.category) {
        case ViObjectKind.node:
          units.add(kSubViCallNodeCodes.contains(child.kind) ? _subViUnit(child) : _primUnit(child));
        case ViObjectKind.structure:
          units.add(_structUnit(child));
        case _:
          if (child.kind == HeapObjectClass.bdWire.code) units.addAll(_wireRecordUnits(child));
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

  LvSubViUnit _subViUnit(ViHeapObject node) {
    final ports = <int>[];
    final inputs = <int>[], outputs = <int>[];
    for (final holder in diagram.childrenOf(node)) {
      if (holder.kind != kNodeEndpointDcoKind) continue;
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
    final memberName = <int, String>{};
    for (final holder in diagram.childrenOf(node)) {
      if (holder.kind != kNodeEndpointDcoKind) continue;
      ownerOfPort[holder.oid] = node.oid;
      (_isSink(holder.oid) ? inputs : outputs).add(holder.oid);
      final record = diagram.childrenOf(holder).firstOrNull;
      roleFlags[holder.oid] = record?.objFlags ?? 0;
      if (record?.typeName case final name?) memberName[holder.oid] = name;
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
      nodeFlags: node.objFlags,
      portMemberName: memberName,
    );
  }

  List<LvUnit> _wireRecordUnits(ViHeapObject record) {
    final units = <LvUnit>[];
    for (final child in diagram.childrenOf(record)) {
      if (child.kind == HeapObjectClass.bdLeaf.code) {
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
      if (child.kind != kNodeEndpointDcoKind) continue;
      if (child.memberOids.isNotEmpty) continue;
      final constant = diagram
          .childrenOf(child)
          .where((child) => child.kind == HeapObjectClass.bdConstDco.code)
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

  static String? _captionOf(ViHeapObject node) {
    final label = nodeDisplayLabel(node);
    return label.isHint ? null : label.text;
  }

  String? _constantLabel(ViHeapObject constant) {
    for (final shell in diagram.childrenOf(constant)) {
      for (final part in diagram.childrenOf(shell)) {
        if (part.kind == HeapObjectClass.controlLabel.code) {
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
      lvRefuse(
        LvRefusalKind.structure,
        'structure class 0x${structure.kind.toRadixString(16)} '
        '(${structure.objectClass.label}) has no modelled control flow',
        oid: structure.oid,
      );
    }
    final frames = [
      for (final child in diagram.childrenOf(structure))
        if (child.objectClass == HeapObjectClass.bdFrame) child.oid,
      if (kind == LvStructureKind.flatSequence)
        for (final sequenceFrame in diagram.childrenOf(structure))
          if (sequenceFrame.objectClass == HeapObjectClass.bdSequenceFrame)
            for (final child in diagram.childrenOf(sequenceFrame))
              if (child.objectClass == HeapObjectClass.bdFrame) child.oid,
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
        if (object.kind != kNodeEndpointDcoKind) {
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
        .where((child) => child.kind == HeapObjectClass.bdSelectorLabel.code)
        .firstOrNull;
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

  Iterable<ViHeapObject> _terminalRecords(ViHeapObject structure) sync* {
    for (final child in diagram.childrenOf(structure)) {
      if (LvTerminalRole.ofCode(child.kind) != null) {
        yield child;
        continue;
      }
      if (child.objectClass == HeapObjectClass.bdSequenceFrame) {
        for (final holder in diagram.childrenOf(child)) {
          yield* _holderRecords(holder);
        }
        continue;
      }
      yield* _holderRecords(child);
    }
  }

  Iterable<ViHeapObject> _holderRecords(ViHeapObject holder) sync* {
    if (holder.kind != kNodeEndpointDcoKind) return;
    for (final record in diagram.childrenOf(holder)) {
      if (LvTerminalRole.ofCode(record.kind) != null) yield record;
    }
  }
}
