/// The **imperative lowering**: a block diagram's dataflow IR emitted as a
/// Dart function, and the VIs it calls emitted alongside it as a library.
///
/// Dataflow becomes statements in three moves:
///
/// 1. every edge becomes one single-assignment local, named from the decoded
///    label nearest to it (a control's name, a constant's caption, the
///    primitive's own name);
/// 2. each region's units are emitted in topological order, so a value is
///    always defined before it is read — and a back edge, which a real diagram
///    only has through a shift register, is refused;
/// 3. each structure becomes the control flow its terminals describe: a For
///    loop's count and auto-indexing tunnels become the loop bound, its shift
///    registers become loop-carried locals, a Case structure's frames become
///    the branches its own per-frame selector ranges guard.
///
/// A **subVI call** becomes a Dart call to the callee's own lowering, emitted
/// into the same file once however many diagrams call it; the arguments are
/// named, so the binding is by connector-pane terminal rather than by position
/// (see `subvi.dart` for the pane contract, and [LvErrorMode] for what the
/// error cluster does to a signature).
///
/// Nothing partial is ever emitted. A construct whose meaning is not decoded
/// aborts the whole library with an [LvRefusal] naming it, so generated code
/// is either complete or absent.
library;

import 'package:dart_style/dart_style.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'dataflow_ir.dart';
import 'error_mode.dart';
import 'naming.dart';
import 'numeric.dart';
import 'prim_map.dart';
import 'runtime.dart';
import 'subvi.dart';
import 'type_map.dart';
import 'wire_type.dart';

/// The block diagram [model]'s code is lowered from: the block-diagram heap
/// that carries objects.
///
/// A VI holds up to three block-diagram sections (`BDHb`, `BDHP`, `BDEx`) and
/// the ones it does not use decode to an empty heap, so "the block diagram" is
/// the one with content — never simply the first.
ViDiagram? lvBlockDiagramOf(ViModel model) {
  ViDiagram? best;
  for (final diagram in model.blockDiagrams) {
    if (best == null || diagram.objects.length > best.objects.length) best = diagram;
  }
  return best == null || best.objects.isEmpty ? null : best;
}

/// The page width the emitted source is formatted to — the repo's own.
const int kLvEmitPageWidth = 120;

/// Resolves a subVI call's target: the VI a call node's file name refers to,
/// or null when it is not available.
typedef LvViResolver = LvViUnit? Function(String fileName);

/// [diagram] as a Dart function named [functionName], or an [LvRefusal] naming
/// the decoded fact that is missing. Never throws for a diagram it cannot
/// lower.
///
/// [sourceNote] is recorded in the file header so a reader can find the VI the
/// code came from. [pool] is the VI's consolidated type pool, which a cluster
/// wire's member types are resolved through; without it a cluster wire has no
/// decided Dart shape. A diagram lowered this way reaches no subVI, since a
/// bare [ViDiagram] carries no connector pane to bind one through — use
/// [emitLvLibrary] for that.
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

/// [entry] and every VI it calls as one Dart library, or an [LvRefusal] naming
/// the decoded fact that is missing. Never throws.
///
/// [functionName] names the entry point; a callee's function is named from its
/// own file name by the naming policy, emitted **once** however many call sites
/// reach it, and a VI that calls itself emits an ordinary recursive call.
/// [resolveSubVi] supplies a callee by the file name its call node spells;
/// without it, any subVI call is refused.
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

Never _refuse(LvRefusalKind kind, String detail, {int? oid}) =>
    throw LvRefusedException(LvRefusal(kind, detail, oid: oid));

/// One signature position of a lowered VI: a parameter or a result field.
class _Port {
  const _Port({required this.terminal, required this.name, required this.type});

  /// The oid of the connector-pane terminal on the VI's own block diagram.
  final int terminal;

  /// The Dart identifier: a parameter name, or a result record's field name.
  final String name;

  /// What the terminal's wire carries.
  final LvWireType type;
}

/// One VI's lowering: its declared signature, then its body.
class _Callable {
  _Callable({required this.unit, required this.functionName, required this.flow});

  final LvViUnit unit;
  final String functionName;
  final LvDataflow flow;
  final LvNaming names = LvNaming();

  /// The parameters, in the order the VI draws its controls.
  final List<_Port> parameters = <_Port>[];

  /// The results, in the order the VI draws its indicators.
  final List<_Port> results = <_Port>[];

  /// Per connector-pane terminal oid, the signature position it became.
  final Map<int, _Port> byTerminal = <int, _Port>{};

  /// The connector-pane terminal oids the error mode removed from the
  /// signature — a call site passes and binds nothing for these.
  final Set<int> elided = <int>{};

  /// The emitted source, once the body has run.
  String? source;

  /// The Dart type the function returns.
  String get returnType => switch (results.length) {
    0 => 'void',
    1 => results.single.type.dartType!,
    _ => '({${[for (final result in results) '${result.type.dartType} ${result.name}'].join(', ')}})',
  };
}

/// The whole emitted file: its imports, its file-scope constants, and one
/// function per VI reached.
class _Library {
  _Library({required this.errorMode, required this.resolve, required this.sourceNote});

  final LvErrorMode errorMode;
  final LvViResolver? resolve;
  final String? sourceNote;

  final Set<String> imports = <String>{};

  /// The hoisted array constants, per declared name. A constant whose value no
  /// emitted body reads is dropped by [assemble] — a `Type Cast`'s type
  /// operand contributes only its TYPE, so the constant wired there is live on
  /// the diagram and dead in the lowering.
  final Map<String, String> fileConstants = <String, String>{};

  /// Per callee file name, its declaration. Keyed case-insensitively, since a
  /// call node's caption and a file name need not agree in case.
  final Map<String, _Callable> byFile = <String, _Callable>{};

  /// The functions in emission order, entry first.
  final List<_Callable> functions = <_Callable>[];

  final Set<String> takenNames = <String>{};

  /// Names the entry point and lowers it and everything it reaches.
  void emit(LvViUnit unit, {required String entryName}) {
    final entry = declare(unit, name: entryName);
    // A callee declared while a body runs is appended to `functions`, so the
    // list grows during the walk; index over it rather than iterating.
    for (var index = 0; index < functions.length; index++) {
      final callable = functions[index];
      callable.source ??= _FunctionEmitter(this, callable).run();
    }
    assert(entry.source != null);
  }

  /// [unit]'s signature, declaring it (and its function name) on first sight.
  /// Re-entrant: a VI that calls itself sees the declaration it is inside.
  _Callable declare(LvViUnit unit, {String? name}) {
    final key = unit.fileName.toLowerCase();
    if (byFile[key] case final existing?) return existing;
    final built = buildLvDataflow(unit.diagram, pool: unit.pool);
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

  /// The VI's connector-pane terminals, split into parameters and results and
  /// named — everything a call site needs before the body exists.
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
        _refuse(
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
        _refuse(
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

  /// Whether a connector-pane terminal of [type] leaves the signature: an
  /// error cluster under [LvErrorMode.exceptions], where failure travels as a
  /// thrown [LvRuntimeType.error] rather than as a parameter or a result.
  bool _elides(LvWireType type) => errorMode == LvErrorMode.exceptions && type.isErrorCluster;

  /// Declares the imports spelling [type] needs — the one route by which an
  /// emitted type contributes an import, so the file's import list is exactly
  /// what its text uses and no more. A `List<String>` needs neither import
  /// where a `Uint8List` needs `dart:typed_data`; call this wherever a Dart
  /// type is written into the output.
  void noteImportsFor(LvWireType type) {
    if (type.dims > 0 && type.numeric != null) imports.add('dart:typed_data');
    if (lvTypeNeedsRuntime(type.dartType)) imports.add(kLvRuntimeImport);
  }

  static int _byDrawnPosition(LvInterfaceUnit a, LvInterfaceUnit b) {
    final one = a.bounds, two = b.bounds;
    if (one == null || two == null) return a.oid.compareTo(b.oid);
    return one.top != two.top ? one.top.compareTo(two.top) : one.left.compareTo(two.left);
  }

  String assemble() {
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
    final bodies = functions.map((function) => function.source ?? '').join('\n');
    for (final entry in fileConstants.entries) {
      if (!RegExp('\\b${entry.key}\\b').hasMatch(bodies)) continue;
      file
        ..writeln(entry.value)
        ..writeln();
    }
    for (var index = 0; index < functions.length; index++) {
      if (index > 0) file.writeln();
      file.write(functions[index].source);
    }
    return DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
      pageWidth: kLvEmitPageWidth,
      trailingCommas: TrailingCommas.preserve,
    ).format(file.toString());
  }
}

/// Lowers one VI's body against its already-declared signature.
class _FunctionEmitter {
  _FunctionEmitter(this.library, this.callable);

  final _Library library;
  final _Callable callable;

  LvDataflow get flow => callable.flow;
  LvNaming get names => callable.names;

  final StringBuffer body = StringBuffer();
  final Map<int, String> valueOf = <int, String>{};

  Never refuse(LvRefusalKind kind, String detail, {int? oid}) => _refuse(kind, detail, oid: oid);

  /// The expression bound to [port], refusing when no emitted unit produced
  /// one — a value read from a producer the lowering never reached.
  String _bound(int port, int oid) {
    final expression = valueOf[port];
    if (expression == null) {
      refuse(
        LvRefusalKind.unboundValue,
        'a live terminal reads a wire whose producer the lowering did not emit, '
        'so the region\'s execution order does not define the value',
        oid: oid,
      );
    }
    return expression;
  }

  String run() {
    for (final parameter in callable.parameters) {
      valueOf[parameter.terminal] = parameter.name;
    }
    // An `error in` the signature dropped starts cleared: under
    // [LvErrorMode.exceptions] a failing caller threw, so control only reaches
    // this VI with no error in hand.
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
    // …and an `error out` the signature dropped becomes the throw itself, so
    // the diagram's error computation is emitted rather than discarded.
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

  // --- regions -----------------------------------------------------------

  /// Emits [region]'s units in topological order, keeping only those that
  /// reach one of [exitPorts].
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

  /// [region]'s live units, each after every unit it reads from. A back edge
  /// is a cycle no shift register explains, and is refused.
  List<LvUnit> _ordered(LvRegion region, Map<int, LvUnit> byOid, Set<int> live) {
    final ordered = <LvUnit>[];
    final state = <int, int>{}; // 1 = on the stack, 2 = emitted
    void visit(LvUnit unit) {
      final mark = state[unit.oid];
      if (mark == 2) return;
      if (mark == 1) {
        refuse(
          LvRefusalKind.cycle,
          'the region\'s dataflow feeds back into this unit without passing a '
          'shift register, so it has no execution order',
          oid: unit.oid,
        );
      }
      state[unit.oid] = 1;
      for (final port in unit.inputPorts) {
        final edge = flow.into(port);
        if (edge == null) continue;
        final owner = flow.ownerOfPort[edge.source];
        final producer = owner == null || owner == unit.oid ? null : byOid[owner];
        if (producer != null && live.contains(owner)) visit(producer);
      }
      state[unit.oid] = 2;
      ordered.add(unit);
    }

    for (final unit in region.units) {
      if (live.contains(unit.oid)) visit(unit);
    }
    return ordered;
  }

  // --- units -------------------------------------------------------------

  void _emitConstant(LvConstUnit unit) {
    final edge = flow.outOf(unit.port);
    if (edge == null) return;
    final record = unit.record;
    final type = edge.type;
    if (type.dims == 0) {
      final literal = _scalarLiteral(record, type);
      if (literal == null) {
        refuse(
          LvRefusalKind.constantValue,
          'diagram constant of type ${type.dartType} carries no decoded value',
          oid: unit.oid,
        );
      }
      // A scalar literal is inlined at its use sites: binding it would be a
      // `final` over a compile-time constant, and it reads better in place.
      valueOf[unit.port] = literal;
      return;
    }
    final values = record.constArray;
    final dims = record.constArrayDims;
    if (values == null || dims == null || dims.length != type.dims || type.numeric == null) {
      refuse(
        LvRefusalKind.constantValue,
        'diagram constant of ${type.dims}-D type ${type.dartType} carries no decoded value',
        oid: unit.oid,
      );
    }
    valueOf[unit.port] = _hoistArrayConstant(unit, type, values, dims);
  }

  /// Declares an array constant at **file scope** and returns its name.
  ///
  /// A diagram constant reads no parameter, so its value is the same on every
  /// call: building it once at load rather than per invocation costs one
  /// allocation for the whole program instead of one per call. Sharing the
  /// single instance is safe because no lowering writes through an array it
  /// was given — Replace Array Subset copies, and an auto-indexing output
  /// tunnel builds a new list.
  String _hoistArrayConstant(LvConstUnit unit, LvWireType type, List<num> values, List<int> dims) {
    library.noteImportsFor(type);
    final name = names.fileConstant(unit.label);
    final shape = dims.join(' × ');
    final flat = _typedListLiteral(values, type);
    final initializer = dims.length <= 1
        ? flat
        : '${LvRuntimeType.arrayNd}<${type.elementListType}>($flat, '
              'Uint32List.fromList(const <int>[${dims.join(', ')}]))';
    // A caption is free text and may hold newlines, which a `///` comment
    // cannot; it is collapsed to one line rather than dropped.
    final caption = unit.label?.replaceAll(RegExp(r'\s+'), ' ').trim();
    library.fileConstants[name] =
        '/// The block diagram\'s ${caption == null || caption.isEmpty ? 'unnamed constant' : '"$caption" constant'}: '
        '$shape ${type.numeric!.glyph} elements.\n'
        'final ${type.dartType} $name = $initializer;';
    return name;
  }

  /// A numeric array constant's flat, row-major typed-list initializer. The
  /// element list is `const`, so the decoded values live in the binary's
  /// constant pool and the only run-time work is the one bulk copy into the
  /// typed list.
  ///
  /// An all-zero constant is the typed list's own length constructor instead:
  /// a `dart:typed_data` list is zero-filled on construction, so it is the
  /// same value written without an element per line.
  String _typedListLiteral(List<num> values, LvWireType type) {
    final kind = type.numeric!;
    if (values.isNotEmpty && values.every((value) => value == 0)) {
      return '${type.elementListType}(${values.length})';
    }
    final elements = [for (final value in values) _elementLiteral(value, kind)].join(', ');
    return '${type.elementListType}.fromList(const <${type.element.dartType}>[$elements])';
  }

  /// One array element's literal: hexadecimal at the kind's full width for an
  /// unsigned integer — the form a mask or lookup table is read in — and
  /// decimal for a signed integer or a float.
  static String _elementLiteral(num value, LvNumericKind kind) {
    if (kind.isFloat) return value is int ? '$value.0' : '$value';
    final integer = value is double ? value.toInt() : value as int;
    if (kind.signed || integer < 0) return '$integer';
    return '0x${integer.toRadixString(16).toUpperCase().padLeft(kind.bits ~/ 4, '0')}';
  }

  String? _scalarLiteral(ViHeapObject record, LvWireType type) {
    if (type.dartType == 'bool') {
      return record.constBool?.toString();
    }
    if (type.dartType == 'String') {
      final text = record.constText;
      return text == null ? null : _stringLiteral(text);
    }
    final value = record.constNumeric;
    return value == null ? null : _numberLiteral(value, type);
  }

  /// A numeric constant's literal, read at the width and signedness its WIRE
  /// states.
  ///
  /// The constant record carries the value's bytes; the signal word carries the
  /// type they are read as, and the two need not agree — a two-byte `FF FF` on
  /// an I16 wire decodes as the magnitude 65 535 and is the value −1. The
  /// signal word is the authority on what a wire carries, so a magnitude above
  /// a signed kind's range is the same bit pattern read as negative.
  String _numberLiteral(num value, LvWireType type) {
    final kind = type.numeric;
    if (kind?.isFloat ?? false) {
      return value is int ? '$value.0' : '$value';
    }
    final magnitude = value is double ? value.toInt() : value as int;
    if (kind == null || !kind.signed || kind.bits >= 64) return '$magnitude';
    return '${magnitude > (1 << (kind.bits - 1)) - 1 ? magnitude - (1 << kind.bits) : magnitude}';
  }

  /// A single-quoted Dart literal for [text]. A LabVIEW string constant holds
  /// arbitrary BYTES — one code unit each — so every unit outside printable
  /// ASCII is written as a `\u{…}` escape rather than pasted into the source:
  /// the emitted literal is the same sequence of code units whatever the
  /// bytes are, and stays readable.
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
        refuse(
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
    );
    final statements = lvPrimLowering(call);
    if (statements == null) {
      refuse(LvRefusalKind.primitive, lvPrimUnmappedReason(call), oid: unit.oid);
    }
    for (final statement in statements) {
      body.writeln(statement);
    }
    for (final output in outputs) {
      valueOf[output.port] = output.expression!;
    }
  }

  // --- subVI calls -------------------------------------------------------

  /// Emits one subVI call: the callee's function, named arguments bound
  /// through the connector pane, and the results bound to the wires that leave
  /// the node.
  void _emitSubVi(LvSubViUnit unit) {
    final callee = _resolveCallee(unit);
    final target = library.declare(callee);
    if (callee.paneMap.length != unit.panePorts.length) {
      refuse(
        LvRefusalKind.subViCall,
        'the call node draws ${unit.panePorts.length} connector-pane terminals but '
        '"${callee.fileName}" has a ${callee.paneMap.length}-terminal pane, so the '
        'two do not describe the same interface',
        oid: unit.oid,
      );
    }

    /// The callee's signature position for pane terminal [paneIndex], or null
    /// when the error mode took that terminal out of the signature.
    _Port? portFor(int paneIndex, int holder, {required bool isInput}) {
      final terminal = callee.paneTerminal(paneIndex);
      if (terminal == null) {
        refuse(
          LvRefusalKind.subViCall,
          'connector-pane terminal $paneIndex of "${callee.fileName}" is wired here but '
          'names no panel data item that a block-diagram terminal draws',
          oid: unit.oid,
        );
      }
      if (target.elided.contains(terminal.oid)) return null;
      final port = target.byTerminal[terminal.oid];
      if (port == null) {
        refuse(
          LvRefusalKind.subViCall,
          'connector-pane terminal $paneIndex of "${callee.fileName}" is wired here but '
          'is not part of the callee\'s signature',
          oid: unit.oid,
        );
      }
      final edge = isInput ? flow.into(holder)! : flow.outOf(holder)!;
      if (port.type.dartType != edge.type.dartType) {
        refuse(
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
      // A callee whose `error in` the signature dropped is entered only when
      // there is no error, so the wire feeding it is not passed.
      final port = portFor(unit.paneIndexOf(holder)!, holder, isInput: true);
      if (port == null) continue;
      arguments.add('${port.name}: ${_bound(edge.source, unit.oid)}');
    }
    final wanted = <int, _Port>{};
    for (final holder in unit.outputPorts) {
      if (flow.outOf(holder) == null) continue;
      final port = portFor(unit.paneIndexOf(holder)!, holder, isInput: false);
      // …and its `error out` is cleared, because a failure threw instead.
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
      refuse(
        LvRefusalKind.subViCall,
        'node class 0x${unit.classCode.toRadixString(16)} calls a VI whose file name '
        'the diagram does not state, so the callee cannot be identified',
        oid: unit.oid,
      );
    }
    final callee = library.resolve?.call(name);
    if (callee == null) {
      refuse(LvRefusalKind.subViCall, 'the called VI "$name" was not supplied to the lowering', oid: unit.oid);
    }
    if (callee.paneMap.isEmpty) {
      refuse(
        LvRefusalKind.subViCall,
        'the called VI "$name" carries no connector-pane map, so which of its '
        'controls each call terminal feeds is not decoded',
        oid: unit.oid,
      );
    }
    return callee;
  }

  // --- structures --------------------------------------------------------

  void _emitStructure(LvStructUnit unit) {
    switch (unit.kind) {
      case LvStructureKind.forLoop:
        _emitForLoop(unit);
      case LvStructureKind.caseStructure:
        _emitCase(unit);
      case LvStructureKind.disableStructure:
        _emitDisable(unit);
      case LvStructureKind.whileLoop:
        refuse(
          LvRefusalKind.structure,
          'a While loop\'s conditional terminal carries a stop-if-true / '
          'continue-if-true polarity that no decoded field distinguishes '
          '(see LvTerminalRole.conditional), so its exit test has no meaning',
          oid: unit.oid,
        );
    }
  }

  /// The expression reaching [terminal]'s outer port, or null when nothing
  /// does.
  String? _outerValue(LvStructTerminal terminal) {
    final port = terminal.outerPort;
    if (port == null) return null;
    final edge = flow.into(port);
    return edge == null ? null : valueOf[edge.source];
  }

  /// The type of the wire attached to [port], or null when there is none.
  LvWireType? _typeAt(int port) => (flow.into(port) ?? flow.outOf(port))?.type;

  /// The inner sink ports of [unit]'s terminals inside [frameOid] — the frame's
  /// exits.
  Set<int> _frameExits(LvStructUnit unit, int frameOid) => {
    for (final terminal in unit.terminals)
      if (terminal.innerPorts[frameOid] case final port? when flow.sinkPorts.contains(port)) port,
  };

  void _emitForLoop(LvStructUnit unit) {
    if (unit.frames.length != 1) {
      refuse(LvRefusalKind.structure, 'a For loop has ${unit.frames.length} frames, not one', oid: unit.oid);
    }
    final frame = unit.frames.single;
    final tunnels = unit.terminals.where((t) => t.role == LvTerminalRole.loopTunnel).toList();
    final indexedInputs = <({LvStructTerminal terminal, String array})>[];
    final indexedOutputs = <({LvStructTerminal terminal, String builder, LvWireType type})>[];

    for (final tunnel in tunnels) {
      final inner = tunnel.innerPorts[frame.frameOid];
      if (inner == null) continue;
      if (tunnel.outerPort != null && _typeAt(tunnel.outerPort!) == null) continue;
      if (tunnel.outerIsSink) {
        final outer = _outerValue(tunnel);
        if (outer == null) {
          refuse(LvRefusalKind.unwiredTerminal, 'a For loop input tunnel receives no wire', oid: tunnel.oid);
        }
        if (!tunnel.autoIndexing) {
          _checkTunnelDims(tunnel, unit.oid, drop: 0);
          valueOf[inner] = outer;
          continue;
        }
        _checkTunnelDims(tunnel, unit.oid, drop: 1);
        final outerType = _typeAt(tunnel.outerPort!)!;
        final array = _atomic(outer) ? outer : names.wire(outerType);
        if (array != outer) {
          library.noteImportsFor(outerType);
          body.writeln('final ${outerType.dartType} $array = $outer;');
        }
        indexedInputs.add((terminal: tunnel, array: array));
        continue;
      }
      if (!tunnel.autoIndexing) {
        refuse(
          LvRefusalKind.structure,
          'a For loop\'s non-indexing output tunnel carries the last iteration\'s '
          'value, or the element type\'s default when the loop runs zero times; '
          'that default is not decoded',
          oid: tunnel.oid,
        );
      }
      _checkTunnelDims(tunnel, unit.oid, drop: 1);
      final type = _typeAt(tunnel.outerPort!)!;
      final builder = names.role(LvNameRole.builder);
      library.noteImportsFor(type);
      body.writeln('final ${lvArrayBuilderType(type.element)} $builder = <${type.element.dartType}>[];');
      indexedOutputs.add((terminal: tunnel, builder: builder, type: type));
    }

    final carried = _emitShiftRegisters(unit, frame.frameOid);
    final bounds = <String>[
      if (unit.terminals.where((t) => t.role == LvTerminalRole.count).firstOrNull case final count?)
        if (_outerValue(count) case final value?) value,
      for (final input in indexedInputs) '${input.array}.length',
    ];
    if (bounds.isEmpty) {
      refuse(
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
      body.writeln('final ${type.dartType} $element = ${input.array}[$iteration];');
      valueOf[inner] = element;
    }

    _emitRegion(frame, _frameExits(unit, frame.frameOid));

    for (final register in carried) {
      final inner = register.terminal.innerPorts[frame.frameOid];
      final edge = inner == null ? null : flow.into(inner);
      if (edge == null) {
        refuse(
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
        refuse(
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

  /// Declares one loop-carried local per shift-register pair, initialised from
  /// the left register's outer input.
  List<({LvStructTerminal terminal, String name, int? rightOuter})> _emitShiftRegisters(
    LvStructUnit unit,
    int frameOid,
  ) {
    final carried = <({LvStructTerminal terminal, String name, int? rightOuter})>[];
    for (final right in unit.terminals) {
      if (right.role != LvTerminalRole.rightShiftRegister) continue;
      final left = unit.terminals.where((t) => t.oid == right.partnerOid).firstOrNull;
      if (left == null) {
        refuse(LvRefusalKind.structure, 'a right shift register names no left partner', oid: right.oid);
      }
      if (left.outerPort == null || _typeAt(left.outerPort!) == null) continue;
      final initial = _outerValue(left);
      if (initial == null) {
        refuse(
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

  void _checkTunnelDims(LvStructTerminal tunnel, int structureOid, {required int drop}) {
    final outer = tunnel.outerPort == null ? null : _typeAt(tunnel.outerPort!);
    final innerPorts = tunnel.innerPorts.values.map(_typeAt).whereType<LvWireType>();
    for (final inner in innerPorts) {
      if (outer != null && outer.dims - inner.dims != drop) {
        refuse(
          LvRefusalKind.tunnelIndexing,
          'the tunnel\'s auto-indexing flag says it drops $drop dimension(s), but '
          'its sides carry ${outer.dims} and ${inner.dims}',
          oid: tunnel.oid,
        );
      }
    }
  }

  void _emitCase(LvStructUnit unit) {
    final selector = unit.terminals.where((t) => t.role == LvTerminalRole.selector).firstOrNull;
    if (selector == null || selector.outerPort == null) {
      refuse(LvRefusalKind.caseSelector, 'a Case structure has no selector terminal', oid: unit.oid);
    }
    final selectorEdge = flow.into(selector.outerPort!);
    if (selectorEdge == null) {
      refuse(LvRefusalKind.unwiredTerminal, 'a Case structure\'s selector receives no wire', oid: unit.oid);
    }
    if (unit.displayedFrame >= unit.frames.length) {
      refuse(LvRefusalKind.caseSelector, 'the displayed frame index is out of range', oid: unit.oid);
    }
    // A boolean and an error cluster are the two selectors whose frames the
    // `0x95` label alone settles, and the only ones whose stored values
    // (0 and 1, or a sentinel pair) do not read as selector values.
    if (selectorEdge.type.isErrorCluster || selectorEdge.type.dartType == 'bool') {
      _emitTwoWayCase(unit, selectorEdge);
      return;
    }
    _emitRangeCase(unit, selectorEdge);
  }

  /// Lowers a Case over a boolean or an error-cluster selector, whose two
  /// frames are the displayed one and its complement.
  void _emitTwoWayCase(LvStructUnit unit, LvEdge selectorEdge) {
    final onError = selectorEdge.type.isErrorCluster;
    if (unit.frames.length != 2) {
      refuse(
        LvRefusalKind.caseSelector,
        'a Case over ${onError ? 'an error-cluster' : 'a boolean'} selector has '
        '${unit.frames.length} frames, not the two its selector can take',
        oid: unit.oid,
      );
    }
    // The error form's two labels are LabVIEW's own: over the corpus's Case
    // structures whose selector wire resolves an error cluster, every one has
    // two frames and every displayed label reads `No Error` or `Error`.
    final displayed = unit.displayedCase?.trim().toLowerCase();
    final trueLabel = onError ? 'error' : 'true', falseLabel = onError ? 'no error' : 'false';
    if (displayed != trueLabel && displayed != falseLabel) {
      refuse(
        LvRefusalKind.caseSelector,
        'the displayed frame\'s case value reads "${unit.displayedCase}", which is '
        'neither "$trueLabel" nor "$falseLabel"',
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

  /// Lowers a Case over a value selector from the structure's own per-frame
  /// range list ([LvStructUnit.selectorRanges]) — the values LabVIEW selects
  /// each frame by, which is what makes a Case of more than two frames
  /// lowerable at all.
  ///
  /// The frames come out in the file's own order, each guarded by the values
  /// its ranges name, with the Default frame last as the `else`. Order only
  /// decides a value two frames both claim, which the corpus has 1 pair of
  /// across 131 407 comparable pairs (the selector-range census's
  /// `rangesOverlap`), so it is very nearly no decision at all.
  void _emitRangeCase(LvStructUnit unit, LvEdge selectorEdge) {
    final type = selectorEdge.type;
    if (unit.selectorRanges.isEmpty) {
      refuse(
        LvRefusalKind.caseSelector,
        'a Case over a ${type.dartType} selector carries no range list, so only '
        'the displayed frame\'s value ("${unit.displayedCase}") is stated',
        oid: unit.oid,
      );
    }
    if (unit.defaultFrame >= unit.frames.length) {
      refuse(LvRefusalKind.caseSelector, 'the Default frame index is out of range', oid: unit.oid);
    }
    final selectorValue = _bound(selectorEdge.source, unit.oid);
    // Frames in the file's order, each with the conditions its ranges name.
    // The Default frame is left out: it is the `else`, whatever else names it.
    final guards = <int, List<String>>{};
    for (final range in unit.selectorRanges) {
      if (range.frame < 0 || range.frame >= unit.frames.length) {
        refuse(
          LvRefusalKind.caseSelector,
          'a selector range names frame ${range.frame}, which does not exist',
          oid: unit.oid,
        );
      }
      if (range.frame == unit.defaultFrame) continue;
      final guard = _rangeGuard(range, selectorValue, unit, type);
      if (guard == null) {
        refuse(
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
      body.writeln('${frame == guards.keys.first ? 'if' : '} else if'} (${guards[frame]!.join(' || ')}) {');
      _emitCaseFrame(unit, frame, outputs, selectorValue);
    }
    body.writeln(guards.isEmpty ? '{' : '} else {');
    _emitCaseFrame(unit, unit.defaultFrame, outputs, selectorValue);
    body.writeln('}');
  }

  /// The Dart test that [range] selects its frame, or null when the range's
  /// bound modes or the selector's [type] give it no decoded reading.
  ///
  /// A string selector's ranges index the structure's own pool, and only a
  /// single value reads as a test there — an ordering over pool indices is not
  /// the ordering over the strings themselves. An integer selector (an enum
  /// wire carries its underlying integer) reads all four value-carrying bound
  /// shapes. No other selector type has a decoded reading.
  String? _rangeGuard(ViSelectorRange range, String selectorValue, LvStructUnit unit, LvWireType type) {
    if (type.dims != 0) return null;
    if (unit.selectorStrings.isNotEmpty) {
      if (type.dartType != 'String' || !range.isSingle) return null;
      if (range.low < 0 || range.low >= unit.selectorStrings.length) return null;
      final text = unit.selectorStrings[range.low];
      if (text.codeUnits.any((code) => code < 0x20 || code > 0x7e)) return null;
      return '$selectorValue == ${_stringLiteral(text)}';
    }
    if (type.numeric == null || type.numeric!.isFloat) return null;
    if (range.isSingle) return '$selectorValue == ${range.low}';
    if (range.isClosed) return '($selectorValue >= ${range.low} && $selectorValue <= ${range.high})';
    if (range.lowBound == ViSelectorBound.inclusive && range.highBound == ViSelectorBound.unbounded) {
      return '$selectorValue >= ${range.low}';
    }
    if (range.lowBound == ViSelectorBound.unbounded && range.highBound == ViSelectorBound.inclusive) {
      return '$selectorValue <= ${range.high}';
    }
    return null;
  }

  /// Declares one local per live Case output tunnel and binds the tunnel's
  /// outer port to it, so every frame assigns the same names.
  List<({LvStructTerminal terminal, String name, LvWireType type})> _declareCaseOutputs(LvStructUnit unit) {
    final outputs = <({LvStructTerminal terminal, String name, LvWireType type})>[];
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

  /// Emits one Case frame's body into the open branch: its inner reads, its
  /// region, and the assignment of every output tunnel.
  void _emitCaseFrame(
    LvStructUnit unit,
    int frameIndex,
    List<({LvStructTerminal terminal, String name, LvWireType type})> outputs,
    String? selectorValue,
  ) {
    final frame = unit.frames[frameIndex];
    _bindFrameInputs(unit, frame.frameOid, selectorValue);
    _emitRegion(frame, _frameExits(unit, frame.frameOid));
    for (final output in outputs) {
      final inner = output.terminal.innerPorts[frame.frameOid];
      final edge = inner == null ? null : flow.into(inner);
      if (edge == null) {
        refuse(
          LvRefusalKind.unwiredTerminal,
          'a Case output tunnel is unwired in one frame; the value LabVIEW '
          'substitutes there is not decoded',
          oid: output.terminal.oid,
        );
      }
      body.writeln('${output.name} = ${_bound(edge.source, output.terminal.oid)};');
    }
  }

  /// Binds a frame's inner reads of the structure's input tunnels and selector
  /// to the values that reach them from outside.
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
        refuse(LvRefusalKind.unwiredTerminal, 'a frame reads a tunnel that receives no wire', oid: terminal.oid);
      }
      valueOf[inner] = outer;
    }
  }

  void _emitDisable(LvStructUnit unit) {
    final displayed = unit.displayedCase?.trim().toLowerCase();
    if (unit.frames.length != 2 || (displayed != 'disabled' && displayed != 'enabled')) {
      refuse(
        LvRefusalKind.caseSelector,
        'a Diagram Disable structure runs its Enabled frame alone; the file '
        'names only the displayed frame ("${unit.displayedCase}"), so which of '
        '${unit.frames.length} frames is enabled is decoded only for the '
        'two-frame case',
        oid: unit.oid,
      );
    }
    final enabled = displayed == 'enabled' ? unit.displayedFrame : 1 - unit.displayedFrame;
    if (enabled >= unit.frames.length) {
      refuse(LvRefusalKind.caseSelector, 'the displayed frame index is out of range', oid: unit.oid);
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
        refuse(LvRefusalKind.unwiredTerminal, 'a disable-structure output tunnel is unwired', oid: tunnel.oid);
      }
      valueOf[port] = _bound(edge.source, tunnel.oid);
    }
  }

  static bool _atomic(String expression) => RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(expression);
}
