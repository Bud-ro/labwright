import 'dart:math' show max, min;

import 'package:dart_style/dart_style.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'dataflow_ir.dart';
import 'declare.dart';
import 'error_mode.dart';
import 'naming.dart';
import 'numeric.dart';
import 'prim_map.dart';
import 'runtime.dart';
import 'subvi.dart';
import 'type_map.dart';
import 'wire_type.dart';

ViDiagram? lvBlockDiagramOf(ViModel model) {
  ViDiagram? best;
  for (final diagram in model.blockDiagrams) {
    if (best == null || diagram.objects.length > best.objects.length) best = diagram;
  }
  return best == null || best.objects.isEmpty ? null : best;
}

const int kLvEmitPageWidth = 120;

typedef LvViResolver = LvViUnit? Function(String fileName);

({String? source, LvRefusal? refusal}) emitLvFunction(
  ViDiagram diagram, {
  required String functionName,
  String? sourceNote,
  List<ViType> pool = const [],
  LvErrorMode errorMode = LvErrorMode.exceptions,
}) => emitLvLibrary(
  LvViUnit(
    fileName: sourceNote ?? functionName,
    diagram: diagram,
    pool: pool,
    paneMap: const [],
    panelDataItems: const [],
    terminalOfDataItem: const {},
  ),
  functionName: functionName,
  sourceNote: sourceNote,
  errorMode: errorMode,
);

({String? source, LvRefusal? refusal}) emitLvLibrary(
  LvViUnit entry, {
  required String functionName,
  String? sourceNote,
  LvErrorMode errorMode = LvErrorMode.exceptions,
  LvViResolver? resolveSubVi,
}) {
  final library = _Library(errorMode: errorMode, resolve: resolveSubVi, sourceNote: sourceNote);
  try {
    library.emit(entry, entryName: functionName);
    return (source: library.assemble(), refusal: null);
  } on LvRefusedException catch (error) {
    return (source: null, refusal: error.refusal);
  }
}

class _Port {
  const _Port({required this.terminal, required this.name, required this.type});

  final int terminal;

  final String name;

  final LvWireType type;
}

class _Callable {
  _Callable({required this.unit, required this.functionName, required this.flow});

  final LvViUnit unit;
  final String functionName;
  final LvDataflow flow;
  final LvNaming names = LvNaming();

  final List<_Port> parameters = <_Port>[];

  final List<_Port> results = <_Port>[];

  final Map<int, _Port> byTerminal = <int, _Port>{};

  final Set<int> elided = <int>{};

  String? source;

  String get returnType => switch (results.length) {
    0 => 'void',
    1 => results.single.type.dartType!,
    _ => '({${[for (final result in results) '${result.type.dartType} ${result.name}'].join(', ')}})',
  };
}

class _Library {
  _Library({required this.errorMode, required this.resolve, required this.sourceNote});

  final LvErrorMode errorMode;
  final LvViResolver? resolve;
  final String? sourceNote;

  final Set<String> imports = <String>{};

  final LvDeclarations declarations = LvDeclarations();

  final Map<String, String> fileConstants = <String, String>{};

  final Map<String, _Callable> byFile = <String, _Callable>{};

  final List<_Callable> functions = <_Callable>[];

  final Set<String> takenNames = <String>{};

  void emit(LvViUnit unit, {required String entryName}) {
    final entry = declare(unit, name: entryName);
    // Callees declared while a body runs append to `functions`; index over it.
    for (var i = 0; i < functions.length; i++) {
      final callable = functions[i];
      callable.source ??= _FunctionEmitter(this, callable).run();
    }
    assert(entry.source != null);
  }

  _Callable declare(LvViUnit unit, {String? name}) {
    final key = unit.fileName.toLowerCase();
    if (byFile[key] case final existing?) return existing;
    final built = buildLvDataflow(unit.diagram, pool: unit.pool, declarations: declarations);
    if (built.refusal case final refusal?) throw LvRefusedException(refusal);
    final callable = _Callable(
      unit: unit,
      functionName: _uniqueName(name ?? lvFieldName(unit.fileName.replaceAll(RegExp(r'\.\w+$'), ''))),
      flow: built.dataflow!,
    );
    byFile[key] = callable;
    functions.add(callable);
    _declareSignature(callable);
    return callable;
  }

  String _uniqueName(String stem) {
    final base = stem.isEmpty ? 'lowered' : stem;
    if (takenNames.add(base)) return base;
    for (var index = 2; ; index++) {
      if (takenNames.add('$base$index')) return '$base$index';
    }
  }

  void _declareSignature(_Callable callable) {
    final interface = [
      for (final unit in callable.flow.root.units)
        if (unit is LvInterfaceUnit) unit,
    ];
    final controls = interface.where((unit) => !unit.isIndicator).toList()..sort(_byDrawnPosition);
    final indicators = interface.where((unit) => unit.isIndicator).toList()..sort(_byDrawnPosition);

    for (final control in controls) {
      final edge = callable.flow.outOf(control.oid);
      if (edge == null) {
        lvRefuse(
          LvRefusalKind.unwiredTerminal,
          'connector-pane control "${control.name ?? 'unnamed'}" drives no wire, '
          'so the diagram states no type for it',
          oid: control.oid,
        );
      }
      if (_elides(edge.type)) {
        callable.elided.add(control.oid);
        continue;
      }
      final port = _Port(terminal: control.oid, name: callable.names.parameter(control.name), type: edge.type);
      callable.parameters.add(port);
      callable.byTerminal[control.oid] = port;
      noteImportsFor(edge.type);
    }
    for (final indicator in indicators) {
      final edge = callable.flow.into(indicator.oid);
      if (edge == null) {
        lvRefuse(
          LvRefusalKind.unwiredTerminal,
          'connector-pane indicator "${indicator.name ?? 'unnamed'}" receives no wire',
          oid: indicator.oid,
        );
      }
      if (_elides(edge.type)) {
        callable.elided.add(indicator.oid);
        continue;
      }
      final port = _Port(terminal: indicator.oid, name: callable.names.resultField(indicator.name), type: edge.type);
      callable.results.add(port);
      callable.byTerminal[indicator.oid] = port;
      noteImportsFor(edge.type);
    }
  }

  bool _elides(LvWireType type) => errorMode == LvErrorMode.exceptions && type.isErrorCluster;

  void noteImportsFor(LvWireType type) => noteImportsForType(type.value);

  void noteImportsForType(LvTypeMapping type) {
    if (lvTypeNeedsTypedData(type)) imports.add('dart:typed_data');
    if (lvTypeNeedsRuntime(type)) imports.add(kLvRuntimeImport);
  }

  static int _byDrawnPosition(LvInterfaceUnit left, LvInterfaceUnit right) {
    final one = left.bounds, two = right.bounds;
    if (one == null || two == null) return left.oid.compareTo(right.oid);
    return one.top != two.top ? one.top.compareTo(two.top) : one.left.compareTo(two.left);
  }

  String assemble() {
    final bodies = functions.map((function) => function.source ?? '').join('\n');
    final constants = [
      for (final entry in fileConstants.entries)
        if (RegExp('\\b${entry.key}\\b').hasMatch(bodies)) entry.value,
    ];
    final spelled = '$bodies\n${constants.join('\n')}';
    final declared = lvDeclarationClosure([
      for (final declaration in declarations.all)
        if (RegExp('\\b${declaration.name}\\b').hasMatch(spelled)) declaration,
    ]);
    for (final declaration in declared) {
      for (final field in declaration.fields) {
        noteImportsForType(field.type);
      }
    }

    final file = StringBuffer()
      ..writeln('// GENERATED by package:labwright_vi_transpile — do not edit by hand.')
      ..writeln('//')
      ..writeln('// Lowered from the block diagram of ${sourceNote ?? 'a LabVIEW VI'}.')
      ..writeln('// Every local is one dataflow wire; every control-flow construct is one')
      ..writeln('// block-diagram structure.')
      ..writeln();
    for (final import in imports.toList()..sort()) {
      file.writeln("import '$import';");
    }
    if (imports.isNotEmpty) file.writeln();
    for (final declaration in declared) {
      file
        ..writeln(lvDeclarationSource(declaration))
        ..writeln();
    }
    for (final constant in constants) {
      file
        ..writeln(constant)
        ..writeln();
    }
    for (var i = 0; i < functions.length; i++) {
      if (i > 0) file.writeln();
      file.write(functions[i].source);
    }
    return DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
      pageWidth: kLvEmitPageWidth,
      trailingCommas: TrailingCommas.preserve,
    ).format(file.toString());
  }
}

enum _Visit { onStack, emitted }

typedef _TunnelValue = ({LvStructTerminal terminal, String name, LvWireType type});

typedef _ShiftRegister = ({LvStructTerminal terminal, String name, int? rightOuter});

class _FunctionEmitter {
  _FunctionEmitter(this.library, this.callable);

  final _Library library;
  final _Callable callable;

  LvDataflow get flow => callable.flow;
  LvNaming get names => callable.names;

  final StringBuffer body = StringBuffer();
  final Map<int, String> valueOf = <int, String>{};

  String _bound(int port, int oid) {
    final expression = valueOf[port];
    if (expression == null) {
      lvRefuse(
        LvRefusalKind.unboundValue,
        'a live terminal reads a wire whose producer the lowering did not emit, '
        'so the region\'s execution order does not define the value',
        oid: oid,
      );
    }
    return expression;
  }

  String run() {
    for (final node in callable.unit.diagram.objects) {
      if (node.kind == HeapObjectClass.bdCallLibrary.code) {
        lvRefuse(LvRefusalKind.foreignCall, lvForeignCallDetail(node), oid: node.oid);
      }
    }
    for (final parameter in callable.parameters) {
      valueOf[parameter.terminal] = parameter.name;
    }
    final thrown = <int>[];
    for (final terminal in callable.elided) {
      if (flow.outOf(terminal) != null) {
        library.imports.add(kLvRuntimeImport);
        valueOf[terminal] = LvRuntimeType.clearedError;
      } else if (flow.into(terminal) != null) {
        thrown.add(terminal);
      }
    }
    _emitRegion(flow.root, {for (final result in callable.results) result.terminal, ...thrown});
    for (final terminal in thrown) {
      final value = _bound(flow.into(terminal)!.source, terminal);
      body.writeln('if ($value.status) throw $value;');
    }

    final signature = [
      for (final parameter in callable.parameters) 'required ${parameter.type.dartType} ${parameter.name}',
    ];
    final returnStatement = switch (callable.results.length) {
      0 => '',
      1 => 'return ${_bound(flow.into(callable.results.single.terminal)!.source, callable.results.single.terminal)};',
      _ =>
        'return (${[
          for (final result in callable.results) '${result.name}: ${_bound(flow.into(result.terminal)!.source, result.terminal)}',
        ].join(', ')});',
    };
    final source = StringBuffer()
      ..writeln(
        '${callable.returnType} ${callable.functionName}'
        '(${signature.isEmpty ? '' : '{${signature.join(', ')}}'}) {',
      )
      ..write(body)
      ..writeln(returnStatement)
      ..writeln('}');
    return source.toString();
  }

  void _emitRegion(LvRegion region, Set<int> exitPorts) {
    final byOid = {for (final unit in region.units) unit.oid: unit};
    final live = _liveUnits(region, exitPorts, byOid);
    for (final unit in _ordered(region, byOid, live)) {
      switch (unit) {
        case LvInterfaceUnit():
          break;
        case LvConstUnit():
          _emitConstant(unit);
        case LvPrimUnit():
          _emitPrimitive(unit);
        case LvSubViUnit():
          _emitSubVi(unit);
        case LvStructUnit():
          _emitStructure(unit);
      }
    }
  }

  Set<int> _liveUnits(LvRegion region, Set<int> exitPorts, Map<int, LvUnit> byOid) {
    final live = <int>{};
    final pending = <int>[...exitPorts];
    while (pending.isNotEmpty) {
      final port = pending.removeLast();
      final edge = flow.into(port);
      if (edge == null) continue;
      final owner = flow.ownerOfPort[edge.source];
      final unit = owner == null ? null : byOid[owner];
      if (unit == null || !live.add(owner!)) continue;
      pending.addAll(unit.inputPorts);
    }
    return live;
  }

  List<LvUnit> _ordered(LvRegion region, Map<int, LvUnit> byOid, Set<int> live) {
    final ordered = <LvUnit>[];
    final state = <int, _Visit>{};
    void visit(LvUnit unit) {
      final mark = state[unit.oid];
      if (mark == _Visit.emitted) return;
      if (mark == _Visit.onStack) {
        lvRefuse(
          LvRefusalKind.cycle,
          'the region\'s dataflow feeds back into this unit without passing a '
          'shift register, so it has no execution order',
          oid: unit.oid,
        );
      }
      state[unit.oid] = _Visit.onStack;
      for (final port in unit.inputPorts) {
        final edge = flow.into(port);
        if (edge == null) continue;
        final owner = flow.ownerOfPort[edge.source];
        final producer = owner == null || owner == unit.oid ? null : byOid[owner];
        if (producer != null && live.contains(owner)) visit(producer);
      }
      state[unit.oid] = _Visit.emitted;
      ordered.add(unit);
    }

    for (final unit in region.units) {
      if (live.contains(unit.oid)) visit(unit);
    }
    return ordered;
  }

  void _emitConstant(LvConstUnit unit) {
    final edge = flow.outOf(unit.port);
    if (edge == null) return;
    final record = unit.record;
    final type = edge.type;
    if (type.dims == 0) {
      final literal = _scalarLiteral(record, type);
      if (literal == null) {
        lvRefuse(
          LvRefusalKind.constantValue,
          'diagram constant of type ${type.dartType} carries no decoded value',
          oid: unit.oid,
        );
      }
      valueOf[unit.port] = literal;
      return;
    }
    final values = record.constArray;
    final dims = record.constArrayDims;
    if (values == null || dims == null || dims.length != type.dims || type.numeric == null) {
      lvRefuse(
        LvRefusalKind.constantValue,
        'diagram constant of ${type.dims}-D type ${type.dartType} carries no decoded value',
        oid: unit.oid,
      );
    }
    valueOf[unit.port] = _hoistArrayConstant(unit, type, values, dims);
  }

  String _hoistArrayConstant(LvConstUnit unit, LvWireType type, List<num> values, List<int> dims) {
    library.noteImportsFor(type);
    final name = names.fileConstant(unit.label);
    final shape = dims.join(' × ');
    final flat = _typedListLiteral(values, type);
    final initializer = dims.length <= 1
        ? flat
        : '${LvRuntimeType.arrayNd}<${type.elementListType}>($flat, '
              'Uint32List.fromList(const <int>[${dims.join(', ')}]))';
    final caption = unit.label?.replaceAll(RegExp(r'\s+'), ' ').trim();
    final declaration =
        '/// The block diagram\'s ${caption == null || caption.isEmpty ? 'unnamed constant' : '"$caption" constant'}: '
        '$shape ${type.numeric!.glyph} elements.\n'
        'final ${type.dartType} $name = $initializer;';
    library.fileConstants[name] = initializer.contains('\n')
        ? '// dart format off\n$declaration\n// dart format on'
        : declaration;
    return name;
  }

  String _typedListLiteral(List<num> values, LvWireType type) {
    final kind = type.numeric!;
    if (values.isNotEmpty && values.every((value) => value == 0)) {
      return '${type.elementListType}(${values.length})';
    }
    final literals = [for (final value in values) _elementLiteral(value, kind)];
    final open = '${type.elementListType}.fromList(const <${type.element.dartType}>[';
    if (literals.length <= _kElementsPerLineThreshold) return '$open${literals.join(', ')}])';
    final widest = literals.fold(0, (widest, literal) => max(widest, literal.length));
    final perRow = max(1, _kLiteralLineWidth ~/ (widest + 2));
    final rows = [
      for (var start = 0; start < literals.length; start += perRow)
        '  ${literals.sublist(start, min(start + perRow, literals.length)).join(', ')},',
    ];
    return '$open\n${rows.join('\n')}\n])';
  }

  static const int _kElementsPerLineThreshold = 12;

  static const int _kLiteralLineWidth = 96;

  static String _elementLiteral(num value, LvNumericKind kind) {
    if (kind.isFloat) return value is int ? '$value.0' : '$value';
    final integer = value is double ? value.toInt() : value as int;
    if (kind.signed || integer < 0) return '$integer';
    return '0x${integer.toRadixString(16).toUpperCase().padLeft(kind.bits ~/ 4, '0')}';
  }

  String? _scalarLiteral(ViHeapObject record, LvWireType type) {
    if (type.carrier == LvCarrier.boolean) {
      return record.constBool?.toString();
    }
    if (type.carrier == LvCarrier.text) {
      final text = record.constText;
      return text == null ? null : _stringLiteral(text);
    }
    final value = record.constNumeric;
    return value == null ? null : _numberLiteral(value, type);
  }

  String _numberLiteral(num value, LvWireType type) {
    final kind = type.numeric;
    if (kind?.isFloat ?? false) {
      return value is int ? '$value.0' : '$value';
    }
    final magnitude = value is double ? value.toInt() : value as int;
    if (kind == null || !kind.signed || kind.bits >= 64) return '$magnitude';
    return '${magnitude > (1 << (kind.bits - 1)) - 1 ? magnitude - (1 << kind.bits) : magnitude}';
  }

  static String _stringLiteral(String text) {
    final out = StringBuffer("'");
    for (final code in text.codeUnits) {
      switch (code) {
        case 0x5c:
          out.write(r'\\');
        case 0x27:
          out.write(r"\'");
        case 0x24:
          out.write(r'\$');
        case 0x0a:
          out.write(r'\n');
        case 0x0d:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        default:
          if (code < 0x20 || code >= 0x7f) {
            out.write('\\u{${code.toRadixString(16)}}');
          } else {
            out.writeCharCode(code);
          }
      }
    }
    return (out..write("'")).toString();
  }

  void _emitPrimitive(LvPrimUnit unit) {
    LvPrimTerminal terminal(int port, {required bool isInput}) {
      final edge = isInput ? flow.into(port) : flow.outOf(port);
      if (edge == null) {
        lvRefuse(
          LvRefusalKind.unwiredTerminal,
          'a live node terminal carries no wire, so its type is not decoded',
          oid: unit.oid,
        );
      }
      library.noteImportsFor(edge.type);
      return LvPrimTerminal(
        port: port,
        type: edge.type,
        roleFlags: unit.portRoleFlags[port] ?? 0,
        expression: isInput ? _bound(edge.source, unit.oid) : names.wire(edge.type, decoded: unit.label),
        memberName: unit.portMemberName[port],
      );
    }

    final outputs = [
      for (final port in unit.outputPorts)
        if (flow.outOf(port) != null) terminal(port, isInput: false),
    ];
    final call = LvPrimCall(
      op: unit.op,
      primResId: unit.primResId,
      classCode: unit.classCode,
      inputs: [for (final port in unit.inputPorts) terminal(port, isInput: true)],
      outputs: outputs,
      outputPorts: unit.outputPorts,
      portDrawnTop: unit.portDrawnTop,
      requireImport: library.imports.add,
      names: names,
      nodeFlags: unit.nodeFlags,
    );
    final statements = lvPrimLowering(call);
    if (statements == null) {
      lvRefuse(LvRefusalKind.primitive, lvPrimUnmappedReason(call), oid: unit.oid);
    }
    for (final statement in statements) {
      body.writeln(statement);
    }
    for (final output in outputs) {
      valueOf[output.port] = output.expression;
    }
  }

  void _emitSubVi(LvSubViUnit unit) {
    final callee = _resolveCallee(unit);
    final target = library.declare(callee);
    if (callee.paneMap.length != unit.panePorts.length) {
      lvRefuse(
        LvRefusalKind.subViCall,
        'the call node draws ${unit.panePorts.length} connector-pane terminals but '
        '"${callee.fileName}" has a ${callee.paneMap.length}-terminal pane, so the '
        'two do not describe the same interface',
        oid: unit.oid,
      );
    }

    _Port? portFor(int paneIndex, int holder, {required bool isInput}) {
      final terminal = callee.paneTerminal(paneIndex);
      if (terminal == null) {
        lvRefuse(
          LvRefusalKind.subViCall,
          'connector-pane terminal $paneIndex of "${callee.fileName}" is wired here but '
          'names no panel data item that a block-diagram terminal draws',
          oid: unit.oid,
        );
      }
      if (target.elided.contains(terminal.oid)) return null;
      final port = target.byTerminal[terminal.oid];
      if (port == null) {
        lvRefuse(
          LvRefusalKind.subViCall,
          'connector-pane terminal $paneIndex of "${callee.fileName}" is wired here but '
          'is not part of the callee\'s signature',
          oid: unit.oid,
        );
      }
      final edge = isInput ? flow.into(holder)! : flow.outOf(holder)!;
      if (port.type.dartType != edge.type.dartType) {
        lvRefuse(
          LvRefusalKind.subViCall,
          'the wire at connector-pane terminal $paneIndex carries ${edge.type.dartType}, '
          'but "${callee.fileName}" declares ${port.type.dartType} there',
          oid: unit.oid,
        );
      }
      return port;
    }

    final arguments = <String>[];
    for (final holder in unit.inputPorts) {
      final edge = flow.into(holder);
      if (edge == null) continue;
      final port = portFor(unit.paneIndexOf(holder)!, holder, isInput: true);
      if (port == null) continue;
      arguments.add('${port.name}: ${_bound(edge.source, unit.oid)}');
    }
    final wanted = <int, _Port>{};
    for (final holder in unit.outputPorts) {
      if (flow.outOf(holder) == null) continue;
      final port = portFor(unit.paneIndexOf(holder)!, holder, isInput: false);
      if (port == null) {
        library.imports.add(kLvRuntimeImport);
        valueOf[holder] = LvRuntimeType.clearedError;
        continue;
      }
      wanted[holder] = port;
    }
    final call = '${target.functionName}(${arguments.join(', ')})';

    if (target.results.isEmpty || wanted.isEmpty) {
      body.writeln('$call;');
      return;
    }
    if (target.results.length == 1) {
      final port = target.results.single;
      final name = names.wire(port.type, decoded: port.name);
      library.noteImportsFor(port.type);
      body.writeln('final ${port.type.dartType} $name = $call;');
      for (final holder in wanted.keys) {
        valueOf[holder] = name;
      }
      return;
    }
    final record = names.role(LvNameRole.value, decoded: target.functionName);
    for (final port in target.results) {
      library.noteImportsFor(port.type);
    }
    body.writeln('final ${target.returnType} $record = $call;');
    wanted.forEach((holder, port) => valueOf[holder] = '$record.${port.name}');
  }

  LvViUnit _resolveCallee(LvSubViUnit unit) {
    final name = unit.calleeName;
    if (name == null) {
      lvRefuse(
        LvRefusalKind.subViCall,
        'node class 0x${unit.classCode.toRadixString(16)} calls a VI whose file name '
        'the diagram does not state, so the callee cannot be identified',
        oid: unit.oid,
      );
    }
    final callee = library.resolve?.call(name);
    if (callee == null) {
      lvRefuse(LvRefusalKind.subViCall, 'the called VI "$name" was not supplied to the lowering', oid: unit.oid);
    }
    if (callee.paneMap.isEmpty) {
      lvRefuse(
        LvRefusalKind.subViCall,
        'the called VI "$name" carries no connector-pane map, so which of its '
        'controls each call terminal feeds is not decoded',
        oid: unit.oid,
      );
    }
    return callee;
  }

  void _emitStructure(LvStructUnit unit) {
    switch (unit.kind) {
      case LvStructureKind.forLoop:
        _emitForLoop(unit);
      case LvStructureKind.caseStructure:
        _emitCase(unit);
      case LvStructureKind.disableStructure:
        _emitDisable(unit);
      case LvStructureKind.whileLoop:
        lvRefuse(
          LvRefusalKind.structure,
          'a While loop\'s conditional terminal carries a stop-if-true / '
          'continue-if-true polarity that no decoded field distinguishes '
          '(see LvTerminalRole.conditional), so its exit test has no meaning',
          oid: unit.oid,
        );
    }
  }

  String? _outerValue(LvStructTerminal terminal) {
    final port = terminal.outerPort;
    if (port == null) return null;
    final edge = flow.into(port);
    return edge == null ? null : valueOf[edge.source];
  }

  LvWireType? _typeAt(int port) => (flow.into(port) ?? flow.outOf(port))?.type;

  Set<int> _frameExits(LvStructUnit unit, int frameOid) => {
    for (final terminal in unit.terminals)
      if (terminal.innerPorts[frameOid] case final port? when flow.sinkPorts.contains(port)) port,
  };

  void _emitForLoop(LvStructUnit unit) {
    if (unit.frames.length != 1) {
      lvRefuse(LvRefusalKind.structure, 'a For loop has ${unit.frames.length} frames, not one', oid: unit.oid);
    }
    final frame = unit.frames.single;
    final tunnels = unit.terminals.where((terminal) => terminal.role == LvTerminalRole.loopTunnel).toList();
    final indexedInputs = <({LvStructTerminal terminal, String array})>[];
    final indexedOutputs = <({LvStructTerminal terminal, String builder, LvWireType type})>[];

    for (final tunnel in tunnels) {
      final inner = tunnel.innerPorts[frame.frameOid];
      if (inner == null) continue;
      if (tunnel.outerPort != null && _typeAt(tunnel.outerPort!) == null) continue;
      if (tunnel.outerIsSink) {
        final outer = _outerValue(tunnel);
        if (outer == null) {
          lvRefuse(LvRefusalKind.unwiredTerminal, 'a For loop input tunnel receives no wire', oid: tunnel.oid);
        }
        if (!tunnel.autoIndexing) {
          _checkTunnelDims(tunnel, unit.oid, drop: 0);
          valueOf[inner] = outer;
          continue;
        }
        _checkTunnelDims(tunnel, unit.oid, drop: 1);
        _checkIndexedRank(tunnel, inner);
        final outerType = _typeAt(tunnel.outerPort!)!;
        final array = lvIsAtomic(outer) ? outer : names.wire(outerType);
        if (array != outer) {
          library.noteImportsFor(outerType);
          body.writeln('final ${outerType.dartType} $array = $outer;');
        }
        indexedInputs.add((terminal: tunnel, array: array));
        continue;
      }
      if (!tunnel.autoIndexing) {
        lvRefuse(
          LvRefusalKind.structure,
          'a For loop\'s non-indexing output tunnel carries the last iteration\'s '
          'value, or the element type\'s default when the loop runs zero times; '
          'that default is not decoded',
          oid: tunnel.oid,
        );
      }
      _checkTunnelDims(tunnel, unit.oid, drop: 1);
      _checkIndexedRank(tunnel, inner);
      final type = _typeAt(tunnel.outerPort!)!;
      final builder = names.role(LvNameRole.builder);
      library.noteImportsFor(type);
      body.writeln('final ${lvArrayBuilderType(type.element)} $builder = <${type.element.dartType}>[];');
      indexedOutputs.add((terminal: tunnel, builder: builder, type: type));
    }

    final carried = _emitShiftRegisters(unit, frame.frameOid);
    final bounds = <String>[
      if (unit.terminals.where((terminal) => terminal.role == LvTerminalRole.count).firstOrNull case final count?)
        if (_outerValue(count) case final value?) value,
      for (final input in indexedInputs) '${input.array}.${_indexedLength(input.terminal)}',
    ];
    if (bounds.isEmpty) {
      lvRefuse(
        LvRefusalKind.unwiredTerminal,
        'a For loop with neither a wired count terminal nor an auto-indexing '
        'input tunnel states no iteration count',
        oid: unit.oid,
      );
    }
    String bound;
    if (bounds.length == 1) {
      bound = bounds.single;
    } else {
      library.imports.add(kLvRuntimeImport);
      bound = names.role(LvNameRole.count);
      body.writeln('final int $bound = ${LvRuntimeCall.iterationCount}(<int>[${bounds.join(', ')}]);');
    }

    final iteration = names.loopIndex();
    body.writeln('for (var $iteration = 0; $iteration < $bound; $iteration++) {');
    for (final terminal in unit.terminals) {
      if (terminal.role != LvTerminalRole.iteration) continue;
      if (terminal.innerPorts[frame.frameOid] case final port?) valueOf[port] = iteration;
    }
    for (final input in indexedInputs) {
      final inner = input.terminal.innerPorts[frame.frameOid]!;
      if (flow.outOf(inner) == null) continue;
      final type = _typeAt(inner)!;
      library.noteImportsFor(type);
      final element = names.role(LvNameRole.element);
      final read = _typeAt(input.terminal.outerPort!)!.dims > 1
          ? '${input.array}.rowAt($iteration)'
          : '${input.array}[$iteration]';
      body.writeln('final ${type.dartType} $element = $read;');
      valueOf[inner] = element;
    }

    _emitRegion(frame, _frameExits(unit, frame.frameOid));

    for (final register in carried) {
      final inner = register.terminal.innerPorts[frame.frameOid];
      final edge = inner == null ? null : flow.into(inner);
      if (edge == null) {
        lvRefuse(
          LvRefusalKind.unwiredTerminal,
          'a shift register is not written inside the loop',
          oid: register.terminal.oid,
        );
      }
      body.writeln('${register.name} = ${_bound(edge.source, register.terminal.oid)};');
    }
    for (final output in indexedOutputs) {
      final inner = output.terminal.innerPorts[frame.frameOid];
      final edge = inner == null ? null : flow.into(inner);
      if (edge == null) {
        lvRefuse(
          LvRefusalKind.unwiredTerminal,
          'an auto-indexing output tunnel is not written inside the loop',
          oid: output.terminal.oid,
        );
      }
      body.writeln('${output.builder}.add(${_bound(edge.source, output.terminal.oid)});');
    }
    body.writeln('}');

    for (final output in indexedOutputs) {
      final name = names.wire(output.type);
      library.noteImportsFor(output.type);
      body.writeln('final ${output.type.dartType} $name = ${lvArrayFreeze(output.type.element, output.builder)};');
      valueOf[output.terminal.outerPort!] = name;
    }
    for (final register in carried) {
      if (register.rightOuter case final port?) valueOf[port] = register.name;
    }
  }

  List<_ShiftRegister> _emitShiftRegisters(LvStructUnit unit, int frameOid) {
    final carried = <_ShiftRegister>[];
    for (final right in unit.terminals) {
      if (right.role != LvTerminalRole.rightShiftRegister) continue;
      final left = unit.terminals.where((terminal) => terminal.oid == right.partnerOid).firstOrNull;
      if (left == null) {
        lvRefuse(LvRefusalKind.structure, 'a right shift register names no left partner', oid: right.oid);
      }
      if (left.outerPort == null || _typeAt(left.outerPort!) == null) continue;
      final initial = _outerValue(left);
      if (initial == null) {
        lvRefuse(
          LvRefusalKind.unwiredTerminal,
          'a shift register has no initial value wired in, and the element '
          'type\'s default is not decoded',
          oid: left.oid,
        );
      }
      final type = _typeAt(left.outerPort!)!;
      final name = names.role(LvNameRole.carried);
      library.noteImportsFor(type);
      body.writeln('${type.dartType} $name = $initial;');
      if (left.innerPorts[frameOid] case final port?) valueOf[port] = name;
      carried.add((terminal: right, name: name, rightOuter: right.outerPort));
    }
    return carried;
  }

  String _indexedLength(LvStructTerminal tunnel) => _typeAt(tunnel.outerPort!)!.dims > 1 ? 'outerLength' : 'length';

  void _checkIndexedRank(LvStructTerminal tunnel, int innerPort) {
    final inner = _typeAt(innerPort);
    if (inner == null || inner.dims < 2) return;
    lvRefuse(
      LvRefusalKind.tunnelIndexing,
      'the tunnel auto-indexes an array whose slice is itself ${inner.dims}-dimensional, '
      'and the dimension vector that slice carries is not decoded',
      oid: tunnel.oid,
    );
  }

  void _checkTunnelDims(LvStructTerminal tunnel, int structureOid, {required int drop}) {
    final outer = tunnel.outerPort == null ? null : _typeAt(tunnel.outerPort!);
    final innerPorts = tunnel.innerPorts.values.map(_typeAt).whereType<LvWireType>();
    for (final inner in innerPorts) {
      if (outer != null && outer.dims - inner.dims != drop) {
        lvRefuse(
          LvRefusalKind.tunnelIndexing,
          'the tunnel\'s auto-indexing flag says it drops $drop dimension(s), but '
          'its sides carry ${outer.dims} and ${inner.dims}',
          oid: tunnel.oid,
        );
      }
    }
  }

  void _emitCase(LvStructUnit unit) {
    final selector = unit.terminals.where((terminal) => terminal.role == LvTerminalRole.selector).firstOrNull;
    if (selector == null || selector.outerPort == null) {
      lvRefuse(LvRefusalKind.caseSelector, 'a Case structure has no selector terminal', oid: unit.oid);
    }
    final selectorEdge = flow.into(selector.outerPort!);
    if (selectorEdge == null) {
      lvRefuse(LvRefusalKind.unwiredTerminal, 'a Case structure\'s selector receives no wire', oid: unit.oid);
    }
    if (unit.displayedFrame >= unit.frames.length) {
      lvRefuse(LvRefusalKind.caseSelector, 'the displayed frame index is out of range', oid: unit.oid);
    }
    if (selectorEdge.type.isErrorCluster || selectorEdge.type.carrier == LvCarrier.boolean) {
      _emitTwoWayCase(unit, selectorEdge);
      return;
    }
    _emitRangeCase(unit, selectorEdge);
  }

  void _emitTwoWayCase(LvStructUnit unit, LvEdge selectorEdge) {
    final onError = selectorEdge.type.isErrorCluster;
    if (unit.frames.length != 2) {
      lvRefuse(
        LvRefusalKind.caseSelector,
        'a Case over ${onError ? 'an error-cluster' : 'a boolean'} selector has '
        '${unit.frames.length} frames, not the two its selector can take',
        oid: unit.oid,
      );
    }
    final displayed = unit.displayedLabel;
    final trueLabel = onError ? LvCaseLabel.error : LvCaseLabel.isTrue;
    final falseLabel = onError ? LvCaseLabel.noError : LvCaseLabel.isFalse;
    if (displayed != trueLabel && displayed != falseLabel) {
      lvRefuse(
        LvRefusalKind.caseSelector,
        'the displayed frame\'s case value reads "${unit.displayedCase}", which is '
        'neither "${trueLabel.label}" nor "${falseLabel.label}"',
        oid: unit.oid,
      );
    }
    final trueIndex = displayed == trueLabel ? unit.displayedFrame : 1 - unit.displayedFrame;
    final selectorValue = _bound(selectorEdge.source, unit.oid);
    final outputs = _declareCaseOutputs(unit);
    body.writeln('if (${onError ? '$selectorValue.status' : selectorValue}) {');
    _emitCaseFrame(unit, trueIndex, outputs, selectorValue);
    body.writeln('} else {');
    _emitCaseFrame(unit, 1 - trueIndex, outputs, selectorValue);
    body.writeln('}');
  }

  void _emitRangeCase(LvStructUnit unit, LvEdge selectorEdge) {
    final type = selectorEdge.type;
    if (unit.selectorRanges.isEmpty) {
      lvRefuse(
        LvRefusalKind.caseSelector,
        'a Case over a ${type.dartType} selector carries no range list, so only '
        'the displayed frame\'s value ("${unit.displayedCase}") is stated',
        oid: unit.oid,
      );
    }
    if (unit.defaultFrame >= unit.frames.length) {
      lvRefuse(LvRefusalKind.caseSelector, 'the Default frame index is out of range', oid: unit.oid);
    }
    final selectorValue = _bound(selectorEdge.source, unit.oid);
    final guards = <int, List<String>>{};
    for (final range in unit.selectorRanges) {
      if (range.frame < 0 || range.frame >= unit.frames.length) {
        lvRefuse(
          LvRefusalKind.caseSelector,
          'a selector range names frame ${range.frame}, which does not exist',
          oid: unit.oid,
        );
      }
      if (range.frame == unit.defaultFrame) continue;
      final guard = _rangeGuard(range, selectorValue, unit, type);
      if (guard == null) {
        lvRefuse(
          LvRefusalKind.caseSelector,
          'a selector range over a ${type.dartType} selector is stated as '
          '${range.low}..${range.high} with bound modes '
          '${range.lowBound?.name}/${range.highBound?.name}, which has no '
          'decoded reading as a value test',
          oid: unit.oid,
        );
      }
      (guards[range.frame] ??= <String>[]).add(guard);
    }
    final outputs = _declareCaseOutputs(unit);
    for (final frame in guards.keys) {
      final tests = guards[frame]!;
      final guard = tests.length == 1 ? tests.single : tests.map((test) => '($test)').join(' || ');
      body.writeln('${frame == guards.keys.first ? 'if' : '} else if'} ($guard) {');
      _emitCaseFrame(unit, frame, outputs, selectorValue);
    }
    body.writeln(guards.isEmpty ? '{' : '} else {');
    _emitCaseFrame(unit, unit.defaultFrame, outputs, selectorValue);
    body.writeln('}');
  }

  String? _rangeGuard(ViSelectorRange range, String selectorValue, LvStructUnit unit, LvWireType type) {
    if (type.dims != 0) return null;
    if (unit.selectorStrings.isNotEmpty) {
      if (type.carrier != LvCarrier.text || !range.isSingle) return null;
      if (range.low < 0 || range.low >= unit.selectorStrings.length) return null;
      final text = unit.selectorStrings[range.low];
      if (text.codeUnits.any((code) => code < 0x20 || code > 0x7e)) return null;
      return '$selectorValue == ${_stringLiteral(text)}';
    }
    if (type.numeric == null || type.numeric!.isFloat) return null;
    if (range.isSingle) return '$selectorValue == ${range.low}';
    if (range.isClosed) return '$selectorValue >= ${range.low} && $selectorValue <= ${range.high}';
    if (range.lowBound == ViSelectorBound.inclusive && range.highBound == ViSelectorBound.unbounded) {
      return '$selectorValue >= ${range.low}';
    }
    if (range.lowBound == ViSelectorBound.unbounded && range.highBound == ViSelectorBound.inclusive) {
      return '$selectorValue <= ${range.high}';
    }
    return null;
  }

  List<_TunnelValue> _declareCaseOutputs(LvStructUnit unit) {
    final outputs = <_TunnelValue>[];
    for (final tunnel in unit.terminals) {
      if (tunnel.role != LvTerminalRole.caseTunnel || tunnel.outerIsSink) continue;
      final port = tunnel.outerPort;
      if (port == null || flow.outOf(port) == null) continue;
      final type = _typeAt(port)!;
      final name = names.role(LvNameRole.branch);
      library.noteImportsFor(type);
      body.writeln('final ${type.dartType} $name;');
      outputs.add((terminal: tunnel, name: name, type: type));
      valueOf[port] = name;
    }
    return outputs;
  }

  void _emitCaseFrame(
    LvStructUnit unit,
    int frameIndex,
    List<_TunnelValue> outputs,
    String? selectorValue,
  ) {
    final frame = unit.frames[frameIndex];
    _bindFrameInputs(unit, frame.frameOid, selectorValue);
    _emitRegion(frame, _frameExits(unit, frame.frameOid));
    for (final output in outputs) {
      final inner = output.terminal.innerPorts[frame.frameOid];
      final edge = inner == null ? null : flow.into(inner);
      if (edge == null) {
        lvRefuse(
          LvRefusalKind.unwiredTerminal,
          'a Case output tunnel is unwired in one frame; the value LabVIEW '
          'substitutes there is not decoded',
          oid: output.terminal.oid,
        );
      }
      if (edge.type.dartType != output.type.dartType) {
        lvRefuse(
          LvRefusalKind.tunnelCoercion,
          'a Case output tunnel carries ${output.type.dartType} outside and '
          '${edge.type.dartType} in one frame, and the coercion LabVIEW applies '
          'at the border is not decoded',
          oid: output.terminal.oid,
        );
      }
      body.writeln('${output.name} = ${_bound(edge.source, output.terminal.oid)};');
    }
  }

  void _bindFrameInputs(LvStructUnit unit, int frameOid, String? selectorValue) {
    for (final terminal in unit.terminals) {
      final inner = terminal.innerPorts[frameOid];
      if (inner == null || flow.outOf(inner) == null) continue;
      if (terminal.role == LvTerminalRole.selector) {
        if (selectorValue != null) valueOf[inner] = selectorValue;
        continue;
      }
      final outer = _outerValue(terminal);
      if (outer == null) {
        lvRefuse(LvRefusalKind.unwiredTerminal, 'a frame reads a tunnel that receives no wire', oid: terminal.oid);
      }
      valueOf[inner] = outer;
    }
  }

  void _emitDisable(LvStructUnit unit) {
    final displayed = unit.displayedDisable;
    if (unit.frames.length != 2 || displayed == LvDisableFrame.other) {
      lvRefuse(
        LvRefusalKind.caseSelector,
        'a Diagram Disable structure runs its Enabled frame alone; the file '
        'names only the displayed frame ("${unit.displayedCase}"), so which of '
        '${unit.frames.length} frames is enabled is decoded only for the '
        'two-frame case',
        oid: unit.oid,
      );
    }
    final enabled = displayed == LvDisableFrame.enabled ? unit.displayedFrame : 1 - unit.displayedFrame;
    if (enabled >= unit.frames.length) {
      lvRefuse(LvRefusalKind.caseSelector, 'the displayed frame index is out of range', oid: unit.oid);
    }
    final frame = unit.frames[enabled];
    _bindFrameInputs(unit, frame.frameOid, null);
    _emitRegion(frame, _frameExits(unit, frame.frameOid));
    for (final tunnel in unit.terminals) {
      if (tunnel.outerIsSink) continue;
      final port = tunnel.outerPort;
      final inner = tunnel.innerPorts[frame.frameOid];
      final edge = inner == null ? null : flow.into(inner);
      if (port == null || flow.outOf(port) == null) continue;
      if (edge == null) {
        lvRefuse(LvRefusalKind.unwiredTerminal, 'a disable-structure output tunnel is unwired', oid: tunnel.oid);
      }
      valueOf[port] = _bound(edge.source, tunnel.oid);
    }
  }
}
