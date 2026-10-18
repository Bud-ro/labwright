import 'dart:math' show max, min;

import 'package:dart_style/dart_style.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'dataflow_ir.dart';
import 'declare.dart';
import 'error_mode.dart';
import 'format_string.dart';
import 'naming.dart';
import 'numeric.dart';
import 'prim_map.dart';
import 'runtime.dart';
import 'subvi.dart';
import 'type_map.dart';
import 'vilib/vilib.dart';
import 'wire_type.dart';

const int kLvEmitPageWidth = 120;

({String? source, LvRefusal? refusal}) emitLvFunction(
  BdDiagram diagram, {
  required String functionName,
  String? sourceNote,
  List<ViType> pool = const [],
  LvErrorMode errorMode = LvErrorMode.exceptions,
}) => emitLvLibrary(
  LvViUnit(
    fileName: sourceNote ?? functionName,
    diagram: diagram,
    pool: pool,
    paneTerminals: const [],
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
  LvClassResolver? resolveClass,
}) {
  final library = _Library(
    errorMode: errorMode,
    resolve: resolveSubVi,
    resolveClass: resolveClass,
    sourceNote: sourceNote,
  );
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
  _Callable({required this.unit, required this.functionName, required this.flow, required this.names});

  final LvViUnit unit;
  final String functionName;
  final LvDataflow flow;
  final LvNaming names;

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

/// Every public name of the runtime package starts with `lv` or `Lv`.
final RegExp _spellsRuntime = RegExp(r'\b[Ll]v[A-Z]\w*');

final RegExp _spellsTypedData = RegExp(
  r'\b(?:Uint|Int)(?:8|16|32|64)List\b|\bFloat(?:32|64)List\b|\bByteData\b|\bByteBuffer\b',
);

class _Library {
  _Library({required this.errorMode, required this.resolve, required this.resolveClass, required this.sourceNote});

  final LvErrorMode errorMode;
  final LvViResolver? resolve;
  final LvClassResolver? resolveClass;
  final String? sourceNote;

  final Set<String> imports = <String>{};

  final LvDeclarations declarations = LvDeclarations();

  final Map<String, String> fileConstants = <String, String>{};

  final Map<String, _Callable> byFile = <String, _Callable>{};

  final List<_Callable> functions = <_Callable>[];

  /// The function names declared so far, which no local may take.
  final Set<String> takenNames = <String>{};

  /// Every local named so far in any function, which no later function may take.
  final Set<String> localNames = <String>{};

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
    final built = buildLvDataflow(
      unit.diagram,
      pool: unit.pool,
      declarations: declarations,
      caller: unit,
      resolve: resolve,
      resolveClass: resolveClass,
    );
    if (built.refusal case final refusal?) throw LvRefusedException(refusal);
    final callable = _Callable(
      unit: unit,
      functionName: _uniqueName(name ?? lvFieldName(unit.fileName.replaceAll(RegExp(r'\.\w+$'), ''))),
      flow: built.dataflow!,
      names: LvNaming(reserved: takenNames, shared: localNames),
    );
    byFile[key] = callable;
    functions.add(callable);
    _declareSignature(callable);
    return callable;
  }

  String _uniqueName(String stem) {
    final base = stem.isEmpty ? 'lowered' : stem;
    for (var index = 1; ; index++) {
      final candidate = index == 1 ? base : '$base$index';
      if (!localNames.contains(candidate) && takenNames.add(candidate)) return candidate;
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
      final type = edge?.type ?? _unwiredControlType(callable, control);
      if (_elides(type)) {
        callable.elided.add(control.oid);
        continue;
      }
      final port = _Port(terminal: control.oid, name: callable.names.parameter(control.name), type: type);
      callable.parameters.add(port);
      callable.byTerminal[control.oid] = port;
      noteImportsFor(type);
    }
    for (final indicator in indicators) {
      final edge = callable.flow.into(indicator.oid);
      if (edge == null) {
        lvRefuse(
          LvRefusalKind.unwiredTerminal,
          'connector-pane indicator "${indicator.name ?? 'unnamed'}" receives no wire, so it '
          'returns the value saved with it, which is not read',
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

  /// The type of a connector-pane control nothing reads: a parameter the function takes and
  /// never uses, typed by the control's own descriptor.
  LvWireType _unwiredControlType(_Callable callable, LvInterfaceUnit control) {
    final descriptor = callable.unit.diagram.byId[control.oid]?.resolvedType?.type;
    final mapped = descriptor == null
        ? const LvTypeMapping.unmapped('the terminal resolves no descriptor')
        : mapLvType(descriptor, callable.unit.pool, 0, declarations);
    if (!mapped.isMapped) {
      lvRefuse(
        LvRefusalKind.unwiredTerminal,
        'connector-pane control "${control.name ?? 'unnamed'}" drives no wire, and its own '
        'descriptor does not type it: ${mapped.note}',
        oid: control.oid,
      );
    }
    return LvWireType.scalarOf(mapped);
  }

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
    final text = '$spelled\n${[for (final declaration in declared) lvDeclarationSource(declaration)].join('\n')}';
    if (!_spellsRuntime.hasMatch(text)) imports.remove(kLvRuntimeImport);
    if (!_spellsTypedData.hasMatch(text)) imports.remove('dart:typed_data');

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
      if (node.kind == BdObjectClass.callLibrary.code) {
        lvRefuse(LvRefusalKind.foreignCall, lvForeignCallDetail(node), oid: node.oid);
      }
    }
    for (final parameter in callable.parameters) {
      valueOf[parameter.terminal] = parameter.name;
    }
    for (final terminal in callable.elided) {
      if (flow.outOf(terminal) != null) {
        library.imports.add(kLvRuntimeImport);
        valueOf[terminal] = LvRuntimeType.clearedError;
      }
    }
    final thrown = _thrown;
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

  /// The elided error indicators whose incoming error the function throws instead of returning.
  List<int> get _thrown => [
    for (final terminal in callable.elided)
      if (flow.outOf(terminal) == null && flow.into(terminal) != null) terminal,
  ];

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
      pending.addAll(unit.inputPorts.where(_readsPort));
    }
    return live;
  }

  late final Map<int, LvUnit> _unitByOid = {
    for (final unit in _allUnits(flow.root)) unit.oid: unit,
  };

  static Iterable<LvUnit> _allUnits(LvRegion region) sync* {
    for (final unit in region.units) {
      yield unit;
      if (unit is LvStructUnit) {
        for (final frame in unit.frames) {
          yield* _allUnits(frame);
        }
      }
    }
  }

  /// The ports whose values the function reads, found backwards from its results: a node reads
  /// every input once any output is read; a structure reads an output tunnel's inner sides once
  /// its outer side is read, an input tunnel's outer side once an inner side is read, and its
  /// count, selector, conditional, shift-register and auto-indexing ports once anything of it is.
  late final Set<int> _read = _readPorts();

  Set<int> _readPorts() {
    final read = <int>{};
    final structures = <int>{};
    final pending = <int>[for (final result in callable.results) result.terminal, ..._thrown];
    void wake(LvStructUnit unit) {
      if (!structures.add(unit.oid)) return;
      for (final terminal in unit.terminals) {
        switch (terminal.role) {
          case LvTerminalRole.count || LvTerminalRole.selector || LvTerminalRole.leftShiftRegister:
            if (terminal.outerPort case final port?) pending.add(port);
          case LvTerminalRole.conditional || LvTerminalRole.rightShiftRegister:
            pending.addAll(terminal.innerPorts.values);
          case LvTerminalRole.loopTunnel when terminal.outerIsSink && terminal.autoIndexing:
            if (terminal.outerPort case final port? when terminal.innerPorts.isNotEmpty) pending.add(port);
          case LvTerminalRole.inPlaceArray || LvTerminalRole.inPlaceIndex when terminal.outerIsSink:
            pending.add(terminal.outerPort!);
          case _:
        }
      }
    }

    while (pending.isNotEmpty) {
      final sink = pending.removeLast();
      if (!read.add(sink)) continue;
      final edge = flow.into(sink);
      if (edge == null) continue;
      read.add(edge.source);
      switch (_unitByOid[flow.ownerOfPort[edge.source]]) {
        case final LvStructUnit unit:
          for (final terminal in unit.terminals) {
            if (terminal.outerPort == edge.source && !terminal.outerIsSink) {
              pending.addAll(terminal.innerPorts.values);
              wake(unit);
            } else if (terminal.innerPorts.containsValue(edge.source)) {
              if (terminal.outerPort case final port? when terminal.outerIsSink) pending.add(port);
              wake(unit);
            }
          }
          for (final terminal in unit.terminals) {
            if (terminal.outerPort == edge.source && !terminal.outerIsSink) {
              for (final condition in unit.terminals) {
                if (condition.role == LvTerminalRole.tunnelCondition && condition.partnerOid == terminal.oid) {
                  pending.addAll(condition.innerPorts.values);
                }
              }
            }
          }
          for (final pair in unit.inPlacePairs) {
            if (pair.arrayOut == edge.source) pending.addAll([for (final element in pair.elements) element.elementIn]);
          }
          for (final pair in unit.inPlaceClusterPairs) {
            if (pair.clusterOut == edge.source) pending.addAll([for (final member in pair.members) member.elementIn]);
          }
        case final unit?:
          pending.addAll(unit.inputPorts);
        case null:
      }
    }
    return read;
  }

  bool _readsPort(int sink) => _read.contains(sink);

  bool _readsEdge(LvEdge edge) => _read.contains(edge.source);

  bool _readsOuter(LvStructTerminal tunnel) => _read.contains(tunnel.outerPort);

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
    if (edge == null || !_readsEdge(edge)) return;
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
    final dims = record.constant?.arrayDims;
    final numbers = record.constant?.array;
    final texts = record.constant?.textArray;
    final String flat;
    final String elements;
    if (dims != null && dims.length == type.dims && numbers != null && type.numeric != null) {
      flat = _typedListLiteral(numbers, type);
      elements = type.numeric!.glyph;
    } else if (dims != null && dims.length == type.dims && texts != null && type.element.carrier == LvCarrier.text) {
      flat = '<String>[${[for (final text in texts) _stringLiteral(text)].join(', ')}]';
      elements = 'string';
    } else {
      lvRefuse(
        LvRefusalKind.constantValue,
        'diagram constant of ${type.dims}-D type ${type.dartType} carries no decoded value',
        oid: unit.oid,
      );
    }
    valueOf[unit.port] = _hoistArrayConstant(unit, type, flat, dims, elements);
  }

  String _hoistArrayConstant(LvConstUnit unit, LvWireType type, String flat, List<int> dims, String elements) {
    library.noteImportsFor(type);
    final name = names.fileConstant(unit.label);
    final shape = dims.join(' × ');
    final initializer = dims.length <= 1
        ? flat
        : '${LvRuntimeType.arrayNd}<${type.elementListType}>($flat, '
              'Uint32List.fromList(const <int>[${dims.join(', ')}]))';
    final caption = unit.label?.replaceAll(RegExp(r'\s+'), ' ').trim();
    final declaration =
        '/// The block diagram\'s ${caption == null || caption.isEmpty ? 'unnamed constant' : '"$caption" constant'}: '
        '$shape $elements elements.\n'
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

  String? _scalarLiteral(BdObject record, LvWireType type) {
    if (type.carrier == LvCarrier.boolean) {
      return record.constant?.boolValue?.toString();
    }
    if (type.carrier == LvCarrier.text) {
      final text = record.constant?.text;
      return text == null ? null : _stringLiteral(text);
    }
    final value = record.constant?.numeric;
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

  static String _stringLiteral(String text) => lvDartStringLiteral(text);

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
      final producer = isInput ? _unitByOid[flow.ownerOfPort[edge.source]] : null;
      return LvPrimTerminal(
        port: port,
        type: edge.type,
        roleFlags: unit.portRoleFlags[port] ?? 0,
        expression: isInput ? _bound(edge.source, unit.oid) : names.wire(edge.type, decoded: unit.label),
        memberName: unit.portMemberName[port],
        constantText: producer is LvConstUnit ? producer.record.constant?.text : null,
      );
    }

    final outputs = [
      for (final port in unit.outputPorts)
        if (flow.outOf(port) case final edge? when _readsEdge(edge)) terminal(port, isInput: false),
    ];
    final call = LvPrimCall(
      op: unit.op,
      primResId: unit.primResId,
      classCode: unit.classCode,
      inputs: [for (final port in unit.inputPorts) terminal(port, isInput: true)],
      outputs: outputs,
      outputPorts: unit.outputPorts,
      portDrawnTop: unit.portDrawnTop,
      portRoleFlags: unit.portRoleFlags,
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
      valueOf[output.port] = output.expression!;
    }
  }

  /// The `<vilib>` VI a call node reaches, when its link points into LabVIEW's own library (or
  /// the diagram links nothing, as a snippet's does) and the runtime implements it.
  LvVilibVi? _vilibCallee(LvSubViUnit unit) {
    final name = unit.calleeName;
    if (name == null) return null;
    final vi = lvVilibVis[name.toLowerCase()];
    if (vi == null) return null;
    final link = callable.unit.linkTo(name);
    final symbolic = link?.path?.text.startsWith('<vilib>') ?? callable.unit.links.isEmpty;
    return symbolic ? vi : null;
  }

  void _emitVilibCall(LvSubViUnit unit, LvVilibVi vi) {
    if (vi.paneWidth != unit.panePorts.length) {
      lvRefuse(
        LvRefusalKind.subViCall,
        'the call node draws ${unit.panePorts.length} connector-pane terminals but '
        '"${vi.fileName}" has a ${vi.paneWidth}-terminal pane, so the two do not '
        'describe the same interface',
        oid: unit.oid,
      );
    }
    LvVilibTerminal terminalFor(int holder, {required bool isInput}) {
      final pane = unit.paneIndexOf(holder)!;
      final terminal = vi.terminalAt(pane);
      if (terminal == null || terminal.isIndicator == isInput) {
        lvRefuse(
          LvRefusalKind.subViCall,
          'connector-pane terminal $pane of "${vi.fileName}" is wired here but the '
          'VI has no ${isInput ? 'control' : 'indicator'} there',
          oid: unit.oid,
        );
      }
      return terminal;
    }

    final arguments = <String>[];
    for (final holder in unit.inputPorts) {
      final edge = flow.into(holder);
      if (edge == null) continue;
      final terminal = terminalFor(holder, isInput: true);
      if (library._elides(edge.type) && terminal.isErrorCluster) continue;
      final value = _bound(edge.source, unit.oid);
      if (terminal.runtimeEnum case final runtimeEnum?) {
        if (edge.type.carrier != LvCarrier.nominal || edge.type.declarations.any((d) => !d.isEnum)) {
          lvRefuse(
            LvRefusalKind.subViCall,
            'connector-pane terminal ${terminal.pane} of "${vi.fileName}" takes an enum, '
            'and the wire carries ${edge.type.dartType}',
            oid: unit.oid,
          );
        }
        arguments.add('${lvFieldName(terminal.name)}: $runtimeEnum.values[$value.index]');
        continue;
      }
      if (edge.type.dartType != terminal.wireType.dartType) {
        lvRefuse(
          LvRefusalKind.subViCall,
          'the wire at connector-pane terminal ${terminal.pane} carries ${edge.type.dartType}, '
          'but "${vi.fileName}" takes ${terminal.wireType.dartType} there',
          oid: unit.oid,
        );
      }
      arguments.add('${lvFieldName(terminal.name)}: $value');
    }
    final results = [
      for (final terminal in vi.terminals)
        if (terminal.isIndicator) terminal,
    ];
    final wanted = <int, LvVilibTerminal>{};
    for (final holder in unit.outputPorts) {
      if (flow.outOf(holder) case final edge? when _readsEdge(edge)) {
      } else {
        continue;
      }
      final terminal = terminalFor(holder, isInput: false);
      if (library._elides(terminal.wireType)) {
        library.imports.add(kLvRuntimeImport);
        valueOf[holder] = LvRuntimeType.clearedError;
        continue;
      }
      wanted[holder] = terminal;
    }
    library.imports.add(kLvRuntimeImport);
    final call = '${vi.dartName}(${arguments.join(', ')})';
    final raised = results.where((terminal) => terminal.isErrorCluster && library._elides(terminal.wireType)).toList();
    if (raised.isNotEmpty) {
      final error = names.role(LvNameRole.value, decoded: raised.single.name);
      body.writeln('final ${LvRuntimeType.error} $error = $call;');
      body.writeln('if ($error.status) throw $error;');
      return;
    }
    if (results.isEmpty || wanted.isEmpty) {
      body.writeln('$call;');
      return;
    }
    if (results.length == 1) {
      final terminal = results.single;
      final type = terminal.wireType;
      final name = names.wire(type, decoded: terminal.name);
      library.noteImportsFor(type);
      body.writeln('final ${type.dartType} $name = $call;');
      for (final holder in wanted.keys) {
        valueOf[holder] = name;
      }
      return;
    }
    final record = names.role(LvNameRole.value, decoded: vi.dartName);
    final fields = [
      for (final terminal in results) '${terminal.wireType.dartType} ${lvFieldName(terminal.name)}',
    ];
    body.writeln('final ({${fields.join(', ')}}) $record = $call;');
    wanted.forEach((holder, terminal) => valueOf[holder] = '$record.${lvFieldName(terminal.name)}');
  }

  void _emitSubVi(LvSubViUnit unit) {
    if (_vilibCallee(unit) case final vi?) {
      _emitVilibCall(unit, vi);
      return;
    }
    final callee = _resolveCallee(unit);
    final target = library.declare(callee);
    if (callee.paneTerminals.length != unit.panePorts.length) {
      lvRefuse(
        LvRefusalKind.subViCall,
        'the call node draws ${unit.panePorts.length} connector-pane terminals but '
        '"${callee.fileName}" has a ${callee.paneTerminals.length}-terminal pane, so the '
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
      if (flow.outOf(holder) case final edge? when _readsEdge(edge)) {
      } else {
        continue;
      }
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
    final link = callable.unit.linkTo(name);
    if (link == null &&
        callable.unit.links.where((l) => l.qualifiedName.lastOrNull?.toLowerCase() == name.toLowerCase()).length > 1) {
      lvRefuse(
        LvRefusalKind.subViCall,
        'the diagram links to more than one VI named "$name", so the node does not say which it calls',
        oid: unit.oid,
      );
    }
    final callee = library.resolve?.call(LvCallee(caller: callable.unit, fileName: name, link: link));
    if (callee == null) {
      lvRefuse(LvRefusalKind.subViCall, 'the called VI "$name" was not supplied to the lowering', oid: unit.oid);
    }
    if (callee.paneTerminals.isEmpty) {
      lvRefuse(
        LvRefusalKind.subViCall,
        'the called VI "$name" carries no connector pane, so which of its '
        'controls each call terminal feeds is not decoded',
        oid: unit.oid,
      );
    }
    return callee;
  }

  void _emitStructure(LvStructUnit unit) {
    switch (unit.kind) {
      case LvStructureKind.forLoop:
        _emitLoop(unit, bounded: true);
      case LvStructureKind.caseStructure:
        _emitCase(unit);
      case LvStructureKind.disableStructure:
        _emitDisable(unit);
      case LvStructureKind.flatSequence:
        _emitSequence(unit);
      case LvStructureKind.inPlaceElement:
        _emitInPlaceElement(unit);
      case LvStructureKind.whileLoop:
        _emitLoop(unit, bounded: false);
    }
  }

  String? _outerValue(LvStructTerminal terminal) {
    final port = terminal.outerPort;
    if (port == null) return null;
    final edge = flow.into(port);
    return edge == null ? null : valueOf[edge.source];
  }

  LvWireType? _typeAt(int port) => (flow.into(port) ?? flow.outOf(port))?.type;

  /// The frame's inner sink ports whose values are read.
  Set<int> _frameExits(LvStructUnit unit, int frameOid) => {
    for (final terminal in unit.terminals)
      if (terminal.innerPorts[frameOid] case final port? when flow.sinkPorts.contains(port) && _read.contains(port))
        port,
  };

  /// A For loop ([bounded]) or a While loop: one `for` whose body is the frame, its shift
  /// registers and tunnels written at the end of each iteration, and a wired conditional
  /// terminal tested last by its polarity.
  void _emitLoop(LvStructUnit unit, {required bool bounded}) {
    final kind = bounded ? 'For' : 'While';
    if (unit.frames.length != 1) {
      lvRefuse(LvRefusalKind.structure, 'a $kind loop has ${unit.frames.length} frames, not one', oid: unit.oid);
    }
    final frame = unit.frames.single;
    ({LvStructTerminal terminal, int port})? exit;
    for (final terminal in unit.terminals) {
      if (terminal.role != LvTerminalRole.conditional) continue;
      if (terminal.innerPorts[frame.frameOid] case final port? when flow.into(port) != null) {
        exit = (terminal: terminal, port: port);
      }
    }
    if (!bounded && exit == null) {
      lvRefuse(LvRefusalKind.unwiredTerminal, 'a While loop\'s conditional terminal receives no wire', oid: unit.oid);
    }
    final conditionOf = <int, int>{};
    for (final terminal in unit.terminals) {
      if (terminal.role != LvTerminalRole.tunnelCondition) continue;
      if (terminal.innerPorts[frame.frameOid] case final port? when flow.into(port) != null) {
        final tunnel = terminal.partnerOid;
        if (tunnel == null) {
          lvRefuse(
            LvRefusalKind.structure,
            'a loop output tunnel is conditional, and no output tunnel is drawn where its condition '
            'terminal names one',
            oid: terminal.oid,
          );
        }
        conditionOf[tunnel] = port;
      }
    }
    final tunnels = unit.terminals.where((terminal) => terminal.role == LvTerminalRole.loopTunnel).toList();
    final indexedInputs = <({LvStructTerminal terminal, String array})>[];
    final indexedOutputs = <({LvStructTerminal terminal, String builder, LvWireType type})>[];
    final lastOutputs = <({LvStructTerminal terminal, String name})>[];

    for (final tunnel in tunnels) {
      final inner = tunnel.innerPorts[frame.frameOid];
      if (inner == null || !_read.contains(tunnel.outerIsSink ? tunnel.outerPort : inner)) continue;
      if (tunnel.outerPort != null && _typeAt(tunnel.outerPort!) == null) continue;
      if (tunnel.outerIsSink) {
        final outer = _outerValue(tunnel);
        if (outer == null) {
          lvRefuse(LvRefusalKind.unwiredTerminal, 'a $kind loop input tunnel receives no wire', oid: tunnel.oid);
        }
        if (!tunnel.autoIndexing) {
          _checkTunnelDims(tunnel, unit.oid, drop: 0);
          valueOf[inner] = outer;
          continue;
        }
        if (!bounded) {
          lvRefuse(
            LvRefusalKind.structure,
            'a While loop\'s auto-indexing input tunnel reads past the array\'s end, and the '
            'value it yields there is not decoded',
            oid: tunnel.oid,
          );
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
      if (!_readsOuter(tunnel)) continue;
      if (!tunnel.autoIndexing) {
        if (conditionOf.containsKey(tunnel.oid)) {
          lvRefuse(
            LvRefusalKind.structure,
            'a conditional output tunnel that does not auto-index is not modelled',
            oid: tunnel.oid,
          );
        }
        _checkTunnelDims(tunnel, unit.oid, drop: 0);
        final type = _typeAt(tunnel.outerPort!)!;
        final fallback = _defaultValueOf(type);
        if (fallback == null) {
          lvRefuse(
            LvRefusalKind.structure,
            'a $kind loop\'s non-indexing output tunnel carries the last iteration\'s '
            'value, or the default of ${type.dartType} when the loop runs zero times, '
            'which has no decided spelling',
            oid: tunnel.oid,
          );
        }
        final name = names.wire(type);
        library.noteImportsFor(type);
        body.writeln('${type.dartType} $name = $fallback;');
        lastOutputs.add((terminal: tunnel, name: name));
        continue;
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
    String? bound;
    if (bounded) {
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
      if (bounds.length == 1) {
        bound = bounds.single;
      } else {
        library.imports.add(kLvRuntimeImport);
        bound = names.role(LvNameRole.count);
        body.writeln('final int $bound = ${LvRuntimeCall.iterationCount}(<int>[${bounds.join(', ')}]);');
      }
    }

    final iteration = names.loopIndex();
    body.writeln('for (var $iteration = 0; ${bound == null ? '' : '$iteration < $bound'}; $iteration++) {');
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
      final added = '${output.builder}.add(${_bound(edge.source, output.terminal.oid)});';
      if (conditionOf[output.terminal.oid] case final condition?) {
        final gate = _bound(flow.into(condition)!.source, output.terminal.oid);
        body.writeln('if ($gate) $added');
      } else {
        body.writeln(added);
      }
    }
    for (final output in lastOutputs) {
      final inner = output.terminal.innerPorts[frame.frameOid];
      final edge = inner == null ? null : flow.into(inner);
      if (edge == null) {
        lvRefuse(
          LvRefusalKind.unwiredTerminal,
          'a $kind loop output tunnel is not written inside the loop',
          oid: output.terminal.oid,
        );
      }
      body.writeln('${output.name} = ${_bound(edge.source, output.terminal.oid)};');
      valueOf[output.terminal.outerPort!] = output.name;
    }
    if (exit case (:final terminal, :final port)) {
      final test = _bound(flow.into(port)!.source, terminal.oid);
      final stops = switch (terminal.polarity!) {
        LvConditionalPolarity.stopIfTrue => test,
        LvConditionalPolarity.continueIfTrue => lvIsAtomic(test) ? '!$test' : '!($test)',
      };
      body.writeln('if ($stops) break;');
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
      if (left.outerPort == null || _typeAt(left.outerPort!) == null) {
        final read = [left.innerPorts[frameOid], right.outerPort].any((port) => port != null && _read.contains(port));
        if (!read) continue;
        lvRefuse(
          LvRefusalKind.structure,
          'an uninitialised shift register keeps its value from the previous call, '
          'which the lowering does not model',
          oid: left.oid,
        );
      }
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

  /// The value an unwired structure output carries: the default of its type, as LabVIEW's
  /// *use default if unwired* substitutes it. Null where this package spells no default for
  /// the type.
  String? _defaultValueOf(LvWireType type) => _defaultOfMapping(type.value);

  String? _defaultOfMapping(LvTypeMapping mapping) {
    if (!mapping.isMapped) return null;
    final dartType = mapping.dartType;
    if (dartType == null) return null;
    switch (mapping.carrier) {
      case LvCarrier.boolean:
        return 'false';
      case LvCarrier.integer:
        return '0';
      case LvCarrier.float:
        return '0.0';
      case LvCarrier.text:
        return "''";
      case LvCarrier.error:
        library.imports.add(kLvRuntimeImport);
        return LvRuntimeType.clearedError;
      case LvCarrier.path:
        library.imports.add(kLvRuntimeImport);
        return 'const ${LvRuntimeType.path}(components: [], absolute: false)';
      case LvCarrier.refnum:
        library.imports.add(kLvRuntimeImport);
        return LvRuntimeType.notARefnum;
      case LvCarrier.timestamp:
        library.imports.add(kLvRuntimeImport);
        return LvRuntimeType.timestampEpoch;
      case LvCarrier.nominal:
        final declaration = mapping.declarations.singleOrNull;
        if (declaration == null) return null;
        if (declaration.isEnum) return declaration.items.isEmpty ? null : '${declaration.name}.values.first';
        final names = LvNaming.declarationFields([for (final field in declaration.fields) field.label]);
        final values = <String>[];
        for (var i = 0; i < declaration.fields.length; i++) {
          final value = _defaultOfMapping(declaration.fields[i].type);
          if (value == null) return null;
          values.add('${names[i]}: $value');
        }
        return '${declaration.name}(${values.join(', ')})';
      case LvCarrier.compound:
        if (mapping.fields.isNotEmpty) {
          final names = [for (final field in mapping.fields) lvFieldName(field.label ?? '')];
          if (names.any((name) => name.isEmpty) || names.toSet().length != names.length) return null;
          final values = <String>[];
          for (var i = 0; i < mapping.fields.length; i++) {
            final value = _defaultOfMapping(mapping.fields[i].type);
            if (value == null) return null;
            values.add('${names[i]}: $value');
          }
          return '(${values.join(', ')})';
        }
        if (dartType.endsWith('List') && !dartType.contains('<')) return '$dartType(0)';
        if (dartType.startsWith('List<')) return 'const <${dartType.substring(5, dartType.length - 1)}>[]';
        return null;
      case LvCarrier.variant:
      case LvCarrier.voidValue:
      case null:
        return null;
    }
  }

  List<_TunnelValue> _declareCaseOutputs(LvStructUnit unit) {
    final outputs = <_TunnelValue>[];
    for (final tunnel in unit.terminals) {
      if (tunnel.role != LvTerminalRole.caseTunnel || tunnel.outerIsSink || !_readsOuter(tunnel)) continue;
      final port = tunnel.outerPort!;
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
        final fallback = _defaultValueOf(output.type);
        if (fallback == null) {
          lvRefuse(
            LvRefusalKind.unwiredTerminal,
            'a Case output tunnel is unwired in one frame, so it carries the default value of '
            '${output.type.dartType}, which has no decided spelling',
            oid: output.terminal.oid,
          );
        }
        body.writeln('${output.name} = $fallback;');
        continue;
      }
      final coerced = _coerced(_bound(edge.source, output.terminal.oid), edge.type, output.type);
      if (coerced == null) {
        lvRefuse(
          LvRefusalKind.tunnelCoercion,
          'a Case output tunnel carries ${output.type.dartType} outside and '
          '${edge.type.dartType} in one frame, and the coercion LabVIEW applies '
          'at the border is not decoded',
          oid: output.terminal.oid,
        );
      }
      body.writeln('${output.name} = $coerced;');
    }
  }

  /// [expression] of type [from] spelled as [to]: itself when the Dart types agree, else a
  /// member-by-member copy when both are clusters whose members match by label and type, so
  /// that two typedefs of one shape cross a border as LabVIEW lets them; null otherwise.
  String? _coerced(String expression, LvWireType from, LvWireType to) {
    if (from.dartType == to.dartType) return expression;
    if (from.dims != to.dims || from.dims > 1) return null;
    final source = _clusterShapeOf(from.element), target = _clusterShapeOf(to.element);
    if (source == null || target == null || source.fields.length != target.fields.length) return null;
    for (var i = 0; i < source.fields.length; i++) {
      if (source.fields[i].label != target.fields[i].label) return null;
      if (source.fields[i].type.dartType != target.fields[i].type.dartType) return null;
    }
    final names = target.name == null
        ? [for (final field in target.fields) lvFieldName(field.label ?? '')]
        : LvNaming.declarationFields([for (final field in target.fields) field.label]);
    final sourceNames = source.name == null
        ? [for (final field in source.fields) lvFieldName(field.label ?? '')]
        : LvNaming.declarationFields([for (final field in source.fields) field.label]);
    if (names.any((name) => name.isEmpty) || sourceNames.any((name) => name.isEmpty)) return null;
    String copy(String item) {
      final members = [for (var i = 0; i < names.length; i++) '${names[i]}: $item.${sourceNames[i]}'].join(', ');
      return target.name == null ? '($members)' : '${target.name}($members)';
    }

    if (from.dims == 0) return copy(expression);
    final item = sourceNames.contains('item') ? 'element' : 'item';
    return '[for (final $item in $expression) ${copy(item)}]';
  }

  /// A cluster mapping's Dart name (null for an anonymous record) and members, or null for any
  /// other mapping.
  ({String? name, List<LvDeclField> fields})? _clusterShapeOf(LvTypeMapping mapping) {
    switch (mapping.carrier) {
      case LvCarrier.nominal:
        final declaration = mapping.declarations.singleOrNull;
        if (declaration == null || declaration.isEnum) return null;
        return (name: declaration.name, fields: declaration.fields);
      case LvCarrier.compound:
        return mapping.fields.isEmpty ? null : (name: null, fields: mapping.fields);
      case _:
        return null;
    }
  }

  void _bindFrameInputs(LvStructUnit unit, int frameOid, String? selectorValue) {
    for (final terminal in unit.terminals) {
      final inner = terminal.innerPorts[frameOid];
      if (inner == null || flow.outOf(inner) == null || !_read.contains(inner)) continue;
      if (terminal.outerPort == null && terminal.role != LvTerminalRole.selector) continue;
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

  /// A Flat Sequence runs its frames left to right; a value crossing a frame border is the
  /// previous frame's output tunnel, already bound when the next frame's inputs are.
  void _emitSequence(LvStructUnit unit) {
    for (final frame in unit.frames) {
      _bindFrameInputs(unit, frame.frameOid, null);
      _emitRegion(frame, _frameExits(unit, frame.frameOid));
      for (final tunnel in unit.terminals) {
        if (tunnel.outerIsSink || !_readsOuter(tunnel)) continue;
        final inner = tunnel.innerPorts[frame.frameOid];
        if (inner == null) continue;
        final edge = flow.into(inner);
        if (edge == null) {
          lvRefuse(LvRefusalKind.unwiredTerminal, 'a sequence frame\'s output tunnel is unwired', oid: tunnel.oid);
        }
        valueOf[tunnel.outerPort!] = _bound(edge.source, tunnel.oid);
      }
    }
  }

  /// An In Place Element structure of Index/Replace Array Elements pairs: each element is read
  /// from its array at its index before the frame, and each array written after it is a copy of
  /// the array with the frame's results at the same indices; an index passes through.
  void _emitInPlaceElement(LvStructUnit unit) {
    final frame = unit.frames.single;
    _bindFrameInputs(unit, frame.frameOid, null);
    final writes = <({String array, String index, int elementIn, int arrayOut, LvWireType type})>[];
    for (final pair in unit.inPlacePairs) {
      final arrayType = _typeAt(pair.arrayIn);
      final array = _outerValue(unit.terminals.firstWhere((terminal) => terminal.outerPort == pair.arrayIn));
      if (arrayType == null || array == null) {
        lvRefuse(LvRefusalKind.unwiredTerminal, 'an In Place Element array terminal receives no wire', oid: unit.oid);
      }
      if (arrayType.dims != 1) {
        lvRefuse(
          LvRefusalKind.structure,
          'an Index/Replace Array Elements pair over a ${arrayType.dims}-dimensional array is not modelled',
          oid: unit.oid,
        );
      }
      final held = lvIsAtomic(array) ? array : names.wire(arrayType);
      if (held != array) {
        library.noteImportsFor(arrayType);
        body.writeln('final ${arrayType.dartType} $held = $array;');
      }
      for (final element in pair.elements) {
        final index = _outerValue(unit.terminals.firstWhere((terminal) => terminal.outerPort == element.indexIn));
        if (index == null) {
          lvRefuse(
            LvRefusalKind.unwiredTerminal,
            'an Index/Replace Array Elements index receives no wire, and the index LabVIEW takes then is not decoded',
            oid: unit.oid,
          );
        }
        final at = lvIsAtomic(index) ? index : names.wire(_typeAt(element.indexIn)!);
        if (at != index) body.writeln('final int $at = $index;');
        if (_read.contains(element.elementOut)) {
          final innerType = _typeAt(element.elementOut) ?? LvWireType.scalarOf(arrayType.element);
          final read = _coerced('$held[$at]', LvWireType.scalarOf(arrayType.element), innerType);
          if (read == null) {
            lvRefuse(
              LvRefusalKind.tunnelCoercion,
              'an In Place Element reads ${arrayType.element.dartType} elements into a ${innerType.dartType} '
              'wire, and the coercion LabVIEW applies at the border is not decoded',
              oid: unit.oid,
            );
          }
          final name = names.role(LvNameRole.element);
          library.noteImportsFor(innerType);
          body.writeln('final ${innerType.dartType} $name = $read;');
          valueOf[element.elementOut] = name;
        }
        if (_read.contains(element.indexOut)) valueOf[element.indexOut] = at;
        writes.add((array: held, index: at, elementIn: element.elementIn, arrayOut: pair.arrayOut, type: arrayType));
      }
    }
    final clusterWrites =
        <({String cluster, LvWireType type, int clusterOut, List<({int field, int elementIn})> members})>[];
    for (final pair in unit.inPlaceClusterPairs) {
      final type = _typeAt(pair.clusterIn);
      final cluster = _outerValue(unit.terminals.firstWhere((terminal) => terminal.outerPort == pair.clusterIn));
      if (type == null || cluster == null) {
        lvRefuse(LvRefusalKind.unwiredTerminal, 'an In Place Element cluster terminal receives no wire', oid: unit.oid);
      }
      final shape = type.dims == 0 ? _clusterShapeOf(type.element) : null;
      if (shape == null) {
        lvRefuse(
          LvRefusalKind.structure,
          'an Unbundle/Bundle Cluster Elements pair over ${type.dartType}, which resolves no members',
          oid: unit.oid,
        );
      }
      final fieldNames = shape.name == null
          ? [for (final field in shape.fields) lvFieldName(field.label ?? '')]
          : LvNaming.declarationFields([for (final field in shape.fields) field.label]);
      final held = lvIsAtomic(cluster) ? cluster : names.wire(type);
      if (held != cluster) {
        library.noteImportsFor(type);
        body.writeln('final ${type.dartType} $held = $cluster;');
      }
      final members = <({int field, int elementIn})>[];
      for (final member in pair.members) {
        final field = shape.fields.indexWhere((candidate) => candidate.label == member.name);
        if (field < 0 || fieldNames[field].isEmpty) {
          lvRefuse(
            LvRefusalKind.structure,
            'an Unbundle/Bundle Cluster Elements terminal names "${member.name}", which ${type.dartType} '
            'has no member of',
            oid: unit.oid,
          );
        }
        final fieldType = LvWireType.scalarOf(shape.fields[field].type);
        if (_read.contains(member.elementOut)) {
          final innerType = _typeAt(member.elementOut) ?? fieldType;
          final read = _coerced('$held.${fieldNames[field]}', fieldType, innerType);
          if (read == null) {
            lvRefuse(
              LvRefusalKind.tunnelCoercion,
              'an In Place Element reads a ${fieldType.dartType} member into a ${innerType.dartType} wire, '
              'and the coercion LabVIEW applies at the border is not decoded',
              oid: unit.oid,
            );
          }
          final name = names.role(LvNameRole.element);
          library.noteImportsFor(innerType);
          body.writeln('final ${innerType.dartType} $name = $read;');
          valueOf[member.elementOut] = name;
        }
        members.add((field: field, elementIn: member.elementIn));
      }
      clusterWrites.add((cluster: held, type: type, clusterOut: pair.clusterOut, members: members));
    }
    _emitRegion(frame, _frameExits(unit, frame.frameOid));
    for (final write in clusterWrites) {
      if (!_read.contains(write.clusterOut)) continue;
      final shape = _clusterShapeOf(write.type.element)!;
      final fieldNames = shape.name == null
          ? [for (final field in shape.fields) lvFieldName(field.label ?? '')]
          : LvNaming.declarationFields([for (final field in shape.fields) field.label]);
      final values = [for (final name in fieldNames) '${write.cluster}.$name'];
      for (final member in write.members) {
        final edge = flow.into(member.elementIn);
        if (edge == null) {
          lvRefuse(LvRefusalKind.unwiredTerminal, 'an In Place Element frame writes no member back', oid: unit.oid);
        }
        final fieldType = LvWireType.scalarOf(shape.fields[member.field].type);
        final value = _coerced(_bound(edge.source, unit.oid), edge.type, fieldType);
        if (value == null) {
          lvRefuse(
            LvRefusalKind.tunnelCoercion,
            'an In Place Element writes a ${edge.type.dartType} wire back into a ${fieldType.dartType} member, '
            'and the coercion LabVIEW applies at the border is not decoded',
            oid: unit.oid,
          );
        }
        values[member.field] = value;
      }
      final arguments = [for (var i = 0; i < fieldNames.length; i++) '${fieldNames[i]}: ${values[i]}'].join(', ');
      final name = names.wire(write.type);
      library.noteImportsFor(write.type);
      body.writeln(
        'final ${write.type.dartType} $name = ${shape.name == null ? '($arguments)' : '${shape.name}($arguments)'};',
      );
      valueOf[write.clusterOut] = name;
    }
    for (final tunnel in unit.terminals) {
      if (tunnel.role != LvTerminalRole.inPlaceTunnel || tunnel.outerIsSink || !_readsOuter(tunnel)) continue;
      final inner = tunnel.innerPorts[frame.frameOid];
      final edge = inner == null ? null : flow.into(inner);
      if (edge == null) {
        lvRefuse(LvRefusalKind.unwiredTerminal, 'an In Place Element output tunnel is unwired', oid: tunnel.oid);
      }
      valueOf[tunnel.outerPort!] = _bound(edge.source, tunnel.oid);
    }
    final copies = <int, String>{};
    for (final write in writes) {
      if (!_read.contains(write.arrayOut)) continue;
      final edge = flow.into(write.elementIn);
      if (edge == null) {
        lvRefuse(LvRefusalKind.unwiredTerminal, 'an In Place Element frame writes no element back', oid: unit.oid);
      }
      final value = _coerced(_bound(edge.source, unit.oid), edge.type, LvWireType.scalarOf(write.type.element));
      if (value == null) {
        lvRefuse(
          LvRefusalKind.tunnelCoercion,
          'an In Place Element writes a ${edge.type.dartType} wire back into ${write.type.element.dartType} '
          'elements, and the coercion LabVIEW applies at the border is not decoded',
          oid: unit.oid,
        );
      }
      var copy = copies[write.arrayOut];
      if (copy == null) {
        copy = copies[write.arrayOut] = names.wire(write.type);
        final element = write.type.element;
        final fresh = element.numeric != null
            ? lvArrayFreeze(element, write.array)
            : 'List<${element.dartType}>.of(${write.array})';
        body.writeln('final ${write.type.dartType} $copy = $fresh;');
      }
      body.writeln('$copy[${write.index}] = $value;');
      valueOf[write.arrayOut] = copy;
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
      if (tunnel.outerIsSink || !_readsOuter(tunnel)) continue;
      final port = tunnel.outerPort!;
      final inner = tunnel.innerPorts[frame.frameOid];
      final edge = inner == null ? null : flow.into(inner);
      if (edge == null) {
        lvRefuse(LvRefusalKind.unwiredTerminal, 'a disable-structure output tunnel is unwired', oid: tunnel.oid);
      }
      valueOf[port] = _bound(edge.source, tunnel.oid);
    }
  }
}
