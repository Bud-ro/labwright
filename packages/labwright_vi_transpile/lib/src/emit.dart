/// The **imperative lowering**: a block diagram's dataflow IR emitted as a
/// Dart function.
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
///    registers become loop-carried locals, a Case structure's selector
///    becomes an `if`.
///
/// Nothing partial is ever emitted. A construct whose meaning is not decoded
/// aborts the whole function with an [LvRefusal] naming it, so generated code
/// is either complete or absent.
library;

import 'package:dart_style/dart_style.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'dataflow_ir.dart';
import 'numeric.dart';
import 'prim_map.dart';
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

/// [diagram] as a Dart function named [functionName], or an [LvRefusal] naming
/// the decoded fact that is missing. Never throws for a diagram it cannot
/// lower.
///
/// [sourceNote] is recorded in the file header so a reader can find the VI the
/// code came from.
({String? source, LvRefusal? refusal}) emitLvFunction(
  ViDiagram diagram, {
  required String functionName,
  String? sourceNote,
}) {
  final built = buildLvDataflow(diagram);
  if (built.refusal case final refusal?) return (source: null, refusal: refusal);
  try {
    final source = _Emitter(
      built.dataflow!,
      functionName: functionName,
      sourceNote: sourceNote,
    ).run();
    return (source: source, refusal: null);
  } on LvRefusedException catch (error) {
    return (source: null, refusal: error.refusal);
  }
}

/// Allocates unique, readable Dart identifiers.
class _Names {
  final Set<String> _used = <String>{};

  /// A fresh identifier derived from [base], never shorter than three
  /// characters and never colliding with one already taken. A [base] that is
  /// already a lowerCamelCase Dart identifier is kept verbatim — sanitizing it
  /// would flatten the case a caller chose deliberately.
  String take(String base) {
    var stem = _isLowerCamel(base) ? base : lvFieldName(base);
    if (stem.isEmpty) stem = 'value';
    if (stem.length < 3) stem = '${stem}Value';
    return _unique(stem);
  }

  /// A fresh file-scope constant name derived from [base] — the `_k` prefix
  /// the repo spells library-level constants with.
  String takeFileConstant(String base) {
    final stem = lvClassName(base);
    return _unique('_k${stem.isEmpty ? 'Constant' : stem}');
  }

  String _unique(String stem) {
    if (_used.add(stem)) return stem;
    for (var index = 2; ; index++) {
      final candidate = '$stem$index';
      if (_used.add(candidate)) return candidate;
    }
  }

  static bool _isLowerCamel(String text) => RegExp(r'^[a-z][A-Za-z0-9]*$').hasMatch(text);
}

class _Emitter {
  _Emitter(this.flow, {required this.functionName, required this.sourceNote});

  final LvDataflow flow;
  final String functionName;
  final String? sourceNote;

  final _Names names = _Names();
  final StringBuffer body = StringBuffer();
  final Map<int, String> valueOf = <int, String>{};
  final Set<String> imports = <String>{};
  final Map<String, LvHelper> helpers = <String, LvHelper>{};

  /// The file-scope declarations of the diagram's array constants, in the
  /// order the lowering reached them.
  final List<String> fileConstants = <String>[];

  Never refuse(LvRefusalKind kind, String detail, {int? oid}) =>
      throw LvRefusedException(LvRefusal(kind, detail, oid: oid));

  String run() {
    final interface = [
      for (final unit in flow.root.units)
        if (unit is LvInterfaceUnit) unit,
    ];
    final controls = interface.where((unit) => !unit.isIndicator).toList()..sort(_byDrawnPosition);
    final indicators = interface.where((unit) => unit.isIndicator).toList()..sort(_byDrawnPosition);

    final parameters = <String>[];
    for (final control in controls) {
      final edge = flow.outOf(control.oid);
      if (edge == null) {
        refuse(
          LvRefusalKind.unwiredTerminal,
          'connector-pane control "${control.name ?? 'unnamed'}" drives no wire, '
          'so the diagram states no type for it',
          oid: control.oid,
        );
      }
      final name = names.take(control.name ?? 'input');
      valueOf[control.oid] = name;
      parameters.add('required ${edge.type.dartType} $name');
      _noteImportsFor(edge.type);
    }

    final exits = {for (final indicator in indicators) indicator.oid};
    _emitRegion(flow.root, exits);

    final results = <({String name, String type, String expression})>[];
    for (final indicator in indicators) {
      final edge = flow.into(indicator.oid);
      if (edge == null) {
        refuse(
          LvRefusalKind.unwiredTerminal,
          'connector-pane indicator "${indicator.name ?? 'unnamed'}" receives no wire',
          oid: indicator.oid,
        );
      }
      _noteImportsFor(edge.type);
      results.add((
        name: lvFieldName(indicator.name ?? 'result'),
        type: edge.type.dartType!,
        expression: valueOf[edge.source]!,
      ));
    }
    return _assemble(parameters, results);
  }

  static int _byDrawnPosition(LvInterfaceUnit a, LvInterfaceUnit b) {
    final one = a.bounds, two = b.bounds;
    if (one == null || two == null) return a.oid.compareTo(b.oid);
    return one.top != two.top ? one.top.compareTo(two.top) : one.left.compareTo(two.left);
  }

  String _assemble(List<String> parameters, List<({String name, String type, String expression})> results) {
    final returnType = switch (results.length) {
      0 => 'void',
      1 => results.single.type,
      _ => '({${[for (final r in results) '${r.type} ${r.name}'].join(', ')}})',
    };
    final returnStatement = switch (results.length) {
      0 => '',
      1 => 'return ${results.single.expression};',
      _ => 'return (${[for (final r in results) '${r.name}: ${r.expression}'].join(', ')});',
    };
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
    for (final declaration in fileConstants) {
      file
        ..writeln(declaration)
        ..writeln();
    }
    file
      ..writeln('$returnType $functionName(${parameters.isEmpty ? '' : '{${parameters.join(', ')}}'}) {')
      ..write(body)
      ..writeln(returnStatement)
      ..writeln('}');
    for (final helper in (helpers.keys.toList()..sort()).map((key) => helpers[key]!)) {
      file
        ..writeln()
        ..writeln(helper.source);
    }
    return DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
      pageWidth: kLvEmitPageWidth,
      trailingCommas: TrailingCommas.preserve,
    ).format(file.toString());
  }

  void _noteImportsFor(LvWireType type) {
    if (type.dims > 0 && type.numeric != null) imports.add('dart:typed_data');
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
    imports.add('dart:typed_data');
    final name = names.takeFileConstant(unit.label ?? 'constant');
    final shape = dims.join(' × ');
    final flat = _typedListLiteral(values, type);
    final initializer = dims.length <= 1
        ? flat
        : '${LvRuntimeType.arrayNd}<${type.elementListType}>($flat, '
              'Uint32List.fromList(const <int>[${dims.join(', ')}]))';
    if (dims.length > 1) helpers[_arrayNdHelper.name] = _arrayNdHelper;
    fileConstants.add(
      '/// The block diagram\'s ${unit.label == null ? 'unnamed constant' : '"${unit.label}" constant'}: '
      '$shape ${type.numeric!.glyph} elements.\n'
      'final ${type.dartType} $name = $initializer;',
    );
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

  String _numberLiteral(num value, LvWireType type) {
    if (type.numeric?.isFloat ?? false) {
      return value is int ? '$value.0' : '$value';
    }
    return '${value is double ? value.toInt() : value}';
  }

  static String _stringLiteral(String text) {
    final escaped = text
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(r'$', r'\$')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    return "'$escaped'";
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
      _noteImportsFor(edge.type);
      return LvPrimTerminal(
        port: port,
        type: edge.type,
        roleFlags: unit.portRoleFlags[port] ?? 0,
        expression: isInput ? valueOf[edge.source]! : names.take(_baseNameFor(unit)),
      );
    }

    final outputs = [
      for (final port in unit.outputPorts)
        if (flow.outOf(port) != null) terminal(port, isInput: false),
    ];
    final call = LvPrimCall(
      op: unit.op,
      classCode: unit.classCode,
      inputs: [for (final port in unit.inputPorts) terminal(port, isInput: true)],
      outputs: outputs,
      requireHelper: (helper) => helpers[helper.name] = helper,
      requireImport: imports.add,
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

  String _baseNameFor(LvPrimUnit unit) {
    if (unit.op case final op?) return op.opName;
    return switch (unit.classCode) {
      kLvIndexArrayClass => 'element',
      kLvReplaceArraySubsetClass => 'array',
      _ => 'value',
    };
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
          'continue-if-true polarity that is not decoded, so its exit test has '
          'no meaning yet',
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
        final array = _atomic(outer) ? outer : names.take('array');
        if (array != outer) body.writeln('final ${_typeAt(tunnel.outerPort!)!.dartType} $array = $outer;');
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
      final builder = names.take('collected');
      imports.add('dart:typed_data');
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
      helpers[_iterationCountHelper.name] = _iterationCountHelper;
      bound = names.take('iterationCount');
      body.writeln('final int $bound = ${_iterationCountHelper.name}(<int>[${bounds.join(', ')}]);');
    }

    final iteration = names.take('iteration');
    body.writeln('for (var $iteration = 0; $iteration < $bound; $iteration++) {');
    for (final terminal in unit.terminals) {
      if (terminal.role != LvTerminalRole.iteration) continue;
      if (terminal.innerPorts[frame.frameOid] case final port?) valueOf[port] = iteration;
    }
    for (final input in indexedInputs) {
      final inner = input.terminal.innerPorts[frame.frameOid]!;
      final type = _typeAt(inner);
      if (flow.outOf(inner) == null) continue;
      final element = names.take('element');
      body.writeln('final ${type!.dartType} $element = ${input.array}[$iteration];');
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
      body.writeln('${register.name} = ${valueOf[edge.source]};');
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
      body.writeln('${output.builder}.add(${valueOf[edge.source]});');
    }
    body.writeln('}');

    for (final output in indexedOutputs) {
      final name = names.take('indexedOut');
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
      final name = names.take('shiftRegister');
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
    if (selectorEdge.type.dartType != 'bool' || unit.frames.length != 2) {
      refuse(
        LvRefusalKind.caseSelector,
        'only a two-frame Case over a boolean selector lowers: the file records '
        'the case value of the displayed frame alone, so the other frames\' '
        'values are decoded only when they are the complement of a boolean '
        '(this one has ${unit.frames.length} frames over '
        '${selectorEdge.type.dartType})',
        oid: unit.oid,
      );
    }
    final displayed = unit.displayedCase?.trim().toLowerCase();
    if (displayed != 'true' && displayed != 'false') {
      refuse(
        LvRefusalKind.caseSelector,
        'the displayed frame\'s case value reads "${unit.displayedCase}", which is '
        'not one of the boolean selector\'s two values',
        oid: unit.oid,
      );
    }
    if (unit.displayedFrame >= unit.frames.length) {
      refuse(LvRefusalKind.caseSelector, 'the displayed frame index is out of range', oid: unit.oid);
    }
    final trueIndex = displayed == 'true' ? unit.displayedFrame : 1 - unit.displayedFrame;
    final selectorValue = valueOf[selectorEdge.source]!;

    final outputs = <({LvStructTerminal terminal, String name, LvWireType type})>[];
    for (final tunnel in unit.terminals) {
      if (tunnel.role != LvTerminalRole.caseTunnel) continue;
      if (tunnel.outerIsSink) continue;
      final port = tunnel.outerPort;
      if (port == null || flow.outOf(port) == null) continue;
      final type = _typeAt(port)!;
      final name = names.take('caseResult');
      _noteImportsFor(type);
      body.writeln('final ${type.dartType} $name;');
      outputs.add((terminal: tunnel, name: name, type: type));
      valueOf[port] = name;
    }

    for (var branch = 0; branch < 2; branch++) {
      final frameIndex = branch == 0 ? trueIndex : 1 - trueIndex;
      final frame = unit.frames[frameIndex];
      body.writeln(branch == 0 ? 'if ($selectorValue) {' : '} else {');
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
        body.writeln('${output.name} = ${valueOf[edge.source]};');
      }
    }
    body.writeln('}');
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
      valueOf[port] = valueOf[edge.source]!;
    }
  }

  static bool _atomic(String expression) => RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(expression);
}

const LvHelper _arrayNdHelper = LvHelper(LvRuntimeType.arrayNd, '''
/// A LabVIEW multi-dimensional array: a flat, **row-major** typed buffer plus
/// its dimension lengths. LabVIEW arrays are rectangular, so one buffer and a
/// length vector is the exact shape — a list of rows would admit ragged
/// shapes LabVIEW forbids and cost an indirection per row.
class ${LvRuntimeType.arrayNd}<T extends List<Object?>> {
  ${LvRuntimeType.arrayNd}(this.data, this.dims);

  /// The elements, row-major: the last dimension varies fastest.
  final T data;

  /// The length of each dimension, outermost first.
  final Uint32List dims;

  /// The flat [data] offset of the element at [indices].
  int offsetOf(List<int> indices) {
    var offset = 0;
    for (var axis = 0; axis < dims.length; axis++) {
      offset = offset * dims[axis] + indices[axis];
    }
    return offset;
  }
}''');

const LvHelper _iterationCountHelper = LvHelper('_lvIterationCount', '''
/// LabVIEW's For loop iteration count: the smallest of the wired count
/// terminal and every auto-indexed input array's length.
int _lvIterationCount(List<int> bounds) => bounds.reduce((a, b) => a < b ? a : b);''');
