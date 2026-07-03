/// TestStand → Dart exporter: renders a parsed [SeqFile] as a runnable-shaped,
/// self-contained Dart source file — the sequence *logic* (control flow,
/// statements, sequence calls, variables) exported as real Dart, with every
/// code-module call (VI / DLL / .NET / Python) emitted as a named **stub**.
///
/// Honesty contract:
///  * Control flow (`NI_Flow_If`/`While`/`DoWhile`/`For`/`ForEach`/`Select`/
///    `Case`/`Break`/`Continue`) becomes real Dart control flow using the
///    step's stored expressions (For increments and Do-While conditions
///    included; Select/Case lowers to a labeled block so Break targets it).
///  * TestStand expressions are translated where the translation is purely
///    mechanical (variable-root rewriting + the shared C-like operator set,
///    applied OUTSIDE string literals only); anything beyond that is preserved
///    verbatim in a `ts.eval('…')` call so no logic is silently dropped or
///    guessed.
///  * Code-module steps become stub invocations; each unique module gets one
///    stub function that throws [UnimplementedError] with the original target.
///  * Steps whose type carries no exportable action are kept as comments —
///    present, ordered, and labeled, never invented.
library;

import 'seq_file.dart';
import 'seq_module.dart';
import 'seq_step.dart';

/// Exports [file] as self-contained Dart source. [sourceName] labels the
/// header comment (typically the input file name).
String exportSeqFileToDart(SeqFile file, {String? sourceName}) =>
    _DartExporter(file, sourceName: sourceName).export();

/// Dart reserved words and builtins a generated identifier must not collide
/// with (suffixed with `$` when hit).
const _dartReserved = {
  'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default', 'break',
  'continue', 'return', 'var', 'final', 'const', 'void', 'main', 'class',
  'new', 'this', 'super', 'true', 'false', 'null', 'is', 'in', 'try',
  'catch', 'finally', 'throw', 'rethrow', 'assert', 'await', 'async',
  'enum', 'extends', 'with', 'implements', 'abstract', 'static', 'late',
  'required', 'dynamic', 'yield', 'export', 'import', 'library', 'part',
  // names the generator itself uses in scope:
  'ts', 'params', 'locals',
};

/// A Dart-identifier-safe form of a TestStand name: camelCase, invalid
/// characters dropped, leading digit guarded, reserved/in-scope words suffixed.
String dartIdentifier(String name, {bool capitalize = false}) {
  final words = name
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return capitalize ? 'Unnamed' : 'unnamed';
  final buffer = StringBuffer();
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (i == 0 && !capitalize) {
      buffer.write(word[0].toLowerCase() + word.substring(1));
    } else {
      buffer.write(word[0].toUpperCase() + word.substring(1));
    }
  }
  var id = buffer.toString();
  if (RegExp(r'^[0-9]').hasMatch(id)) id = 'v$id';
  if (_dartReserved.contains(id)) id = '$id\$';
  return id;
}

/// The TestStand variable roots the translator rewrites, mapped to the Dart
/// expression that replaces them. `Locals`/`Parameters` resolve to the
/// generated runtime maps so nested member paths keep working uniformly.
const _variableRoots = {
  'Locals': 'locals',
  'Parameters': 'params',
  'FileGlobals': 'ts.fileGlobals',
  'StationGlobals': 'ts.stationGlobals',
  'RunState': 'ts.runState',
  'Step': 'ts.step',
};

/// Whether a root-rewritten expression is **mechanically Dart-safe**: only
/// identifiers/member access, numbers, strings, and the operator set TestStand
/// shares with Dart. `%` is deliberately absent — TestStand's modulo is
/// C-style (sign of dividend) while Dart's is Euclidean, so `%` expressions
/// keep their TestStand semantics via `ts.eval`. Bitwise `&`/`|` are handled
/// separately (they bind tighter than comparisons in Dart but looser in
/// TestStand's C-like grammar, so mechanical passthrough would silently
/// re-parenthesize the expression).
final _dartSafeExpression = RegExp(
    r"^[A-Za-z0-9_.\s+\-*/!<>=&|(),'\x22\[\]]+$");

/// Constructs that force the `ts.eval` fallback even when the charset looks
/// safe: ANY function-style call (TestStand's built-in library is large and
/// none of it exists in Dart), plus engine-only operators. Parenthesized
/// grouping (`(a || b)`) is fine — only `identifier(` marks a call.
final _testStandOnly = RegExp(r'[A-Za-z_][A-Za-z0-9_]*\s*\(|#|->');

class _DartExporter {
  _DartExporter(this.file, {this.sourceName});

  final SeqFile file;
  final String? sourceName;

  final StringBuffer _out = StringBuffer();
  int _indent = 1;

  /// Every top-level identifier the generator has handed out (sequence
  /// functions + stubs) — the collision registry.
  final Set<String> _topLevelNames = {};

  /// Sequence name → its (uniquified) generated function name.
  final Map<String, String> _sequenceFnNames = {};

  /// stub key (adapter + target) → generated stub function name.
  final Map<String, String> _stubs = {};

  /// Stub declarations, emitted after the sequences.
  final List<String> _stubDecls = [];

  void _line(String text) =>
      _out.writeln(text.isEmpty ? '' : '${'  ' * _indent}$text');

  /// Claims a unique top-level identifier derived from [base].
  String _uniqueTopLevel(String base) {
    var name = base;
    var n = 2;
    while (!_topLevelNames.add(name)) {
      name = '$base$n';
      n++;
    }
    return name;
  }

  String export() {
    _emitHeader();
    for (final sequence in file.sequences) {
      _sequenceFnNames.putIfAbsent(
          sequence.name, () => _uniqueTopLevel(dartIdentifier(sequence.name)));
    }
    for (final sequence in file.sequences) {
      _emitSequence(sequence);
    }
    _emitStubs();
    _emitRuntime();
    return _out.toString();
  }

  void _emitHeader() {
    _out
      ..writeln('// GENERATED by labwright_seq exportSeqFileToDart'
          '${sourceName != null ? ' from ${_comment(sourceName!)}' : ''}.')
      ..writeln('//')
      ..writeln('// Sequence logic is exported as Dart; code-module calls '
          '(VI/DLL/.NET/Python)')
      ..writeln('// are stubs, and expressions beyond mechanical translation '
          'are kept verbatim')
      ..writeln('// in ts.eval(...) calls. Nothing is fabricated: unexportable '
          'steps remain as')
      ..writeln('// ordered comments.')
      ..writeln('// ignore_for_file: unused_local_variable, dead_code, '
          'unused_element, unused_label')
      ..writeln();
  }

  // ── expressions ────────────────────────────────────────────────────────────

  /// Splits [text] into alternating non-string / string-literal segments so
  /// rewrites touch only code, never quoted content (review finding: True/
  /// False and root rewriting corrupted string constants).
  List<(String, bool)> _segments(String text) {
    final out = <(String, bool)>[];
    var start = 0;
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      if (c == '"' || c == "'") {
        if (i > start) out.add((text.substring(start, i), false));
        final quote = c;
        var j = i + 1;
        while (j < text.length && (text[j] != quote || text[j - 1] == r'\')) {
          j++;
        }
        j = j < text.length ? j + 1 : text.length;
        out.add((text.substring(i, j), true));
        start = j;
        i = j;
      } else {
        i++;
      }
    }
    if (start < text.length) out.add((text.substring(start), false));
    return out;
  }

  /// Translates a TestStand expression to Dart, or wraps it in `ts.eval`.
  String _expr(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return "''";

    // Comma/paren state must carry ACROSS string-literal boundaries: in
    // `f(a + "s"), b` the comma's depth is only correct when the `(` from the
    // first code segment is still counted after the string (review-class bug:
    // per-segment depth read `),` as depth -1 and missed the top-level comma).
    var depth = 0;
    for (final (segment, isString) in _segments(trimmed)) {
      if (isString) continue;
      for (var i = 0; i < segment.length; i++) {
        switch (segment[i]) {
          case '(' || '[' || '{':
            depth++;
          case ')' || ']' || '}':
            depth--;
          case ',':
            if (depth <= 0) return _evalFallback(raw);
        }
      }
    }

    final rebuilt = StringBuffer();
    for (final (segment, isString) in _segments(trimmed)) {
      if (isString) {
        rebuilt.write(segment);
        continue;
      }
      var code = segment;
      // Unknown dotted roots (Enums.X, station types) and the `*` dereference
      // prefix have no mechanical Dart form.
      for (final m
          in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\.').allMatches(code)) {
        final precededByDot =
            m.start > 0 && code.substring(m.start - 1, m.start) == '.';
        if (!precededByDot && !_variableRoots.containsKey(m.group(1))) {
          return _evalFallback(raw);
        }
      }
      if (RegExp(r'\*\s*[A-Za-z_]').hasMatch(code)) return _evalFallback(raw);
      code = code
          .replaceAll(RegExp(r'\bTrue\b'), 'true')
          .replaceAll(RegExp(r'\bFalse\b'), 'false');
      for (final entry in _variableRoots.entries) {
        code = code.replaceAllMapped(
          RegExp('\\b${entry.key}\\.([A-Za-z_][A-Za-z0-9_.]*)'),
          (m) {
            final path = m.group(1)!;
            final root = entry.value;
            if (root == 'locals' || root == 'params') {
              final segments = path.split('.');
              final lookup = "$root['${segments.first}']";
              return segments.length == 1
                  ? lookup
                  : '$lookup.${segments.sublist(1).join('.')}';
            }
            return '$root.$path';
          },
        );
      }
      // Bitwise &/| (after masking the shared &&/||) parse with different
      // precedence in Dart — keep TestStand semantics via eval.
      final masked = code.replaceAll('&&', '  ').replaceAll('||', '  ');
      if (masked.contains('&') || masked.contains('|')) {
        return _evalFallback(raw);
      }
      if (!_dartSafeExpression.hasMatch(code) ||
          _testStandOnly.hasMatch(code)) {
        return _evalFallback(raw);
      }
      // Multi-line source expressions must land on one generated line.
      code = code.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');
      // Any bare identifier that survived rewriting must be a name the
      // generated scope actually declares — otherwise it is a TestStand
      // constant (Nothing, NAN, INF, ...) that would not compile.
      const knownBare = {'true', 'false', 'null', 'ts', 'locals', 'params'};
      final generatedName = RegExp(r'^_(select|matched)\d+$|^_element$');
      final codeSansKeys = code.replaceAll(RegExp(r"'[^']*'"), '');
      for (final m in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\b')
          .allMatches(codeSansKeys)) {
        final id = m.group(1)!;
        final precededByDot = m.start > 0 &&
            codeSansKeys.substring(m.start - 1, m.start) == '.';
        if (precededByDot) continue;
        if (!knownBare.contains(id) && !generatedName.hasMatch(id)) {
          return _evalFallback(raw);
        }
      }
      rebuilt.write(code);
    }
    return rebuilt.toString();
  }

  String _evalFallback(String raw) => "ts.eval('${_escape(raw)}')";

  String _escape(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');

  /// Text destined for a `//` comment: newlines flattened so nothing spills
  /// out of the comment onto a code line.
  String _comment(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' | ').trim();

  // ── sequences ──────────────────────────────────────────────────────────────

  void _emitSequence(Sequence sequence) {
    final fnName = _sequenceFnNames[sequence.name]!;
    _out.writeln('/// Sequence `${_comment(sequence.name)}`'
        '${sequence.comment != null ? ' — ${_comment(sequence.comment!)}' : ''}.');

    // Parameter identifiers: unique within the signature and never colliding
    // with the generated scope names (`ts` is pre-claimed).
    final paramIds = <String, String>{};
    final usedParams = <String>{'ts'};
    for (final p in sequence.parameters) {
      final base = dartIdentifier(p.name);
      var id = base;
      var n = 2;
      while (!usedParams.add(id)) {
        id = '$base$n';
        n++;
      }
      paramIds[p.name] = id;
    }
    final params = [
      for (final p in sequence.parameters)
        'Object? ${paramIds[p.name]}'
            '${p.value != null ? ' = ${_literal(p.value!, p.type)}' : ''}',
    ];
    _out.writeln('Future<void> $fnName(TsRuntime ts'
        '${params.isEmpty ? '' : ', {${params.join(', ')}}'}) async {');
    _indent = 1;

    if (sequence.parameters.isNotEmpty) {
      _line('final params = <String, dynamic>{');
      for (final p in sequence.parameters) {
        _line("  '${_escape(p.name)}': ${paramIds[p.name]},");
      }
      _line('};');
    } else {
      _line('final params = <String, dynamic>{};');
    }
    _line('final locals = <String, dynamic>{');
    final seenLocals = <String>{};
    for (final local in sequence.locals) {
      if (!seenLocals.add(local.name)) continue; // duplicate name in source
      final init =
          local.value != null ? _literal(local.value!, local.type) : 'null';
      _line("  '${_escape(local.name)}': $init,"
          '${local.type != null ? ' // ${_comment(local.type!)}' : ''}');
    }
    _line('};');
    _line('');

    for (final group in StepGroup.values) {
      final steps = sequence.stepsIn(group);
      if (steps.isEmpty) continue;
      _line('// ── ${group.name} ──');
      _emitSteps(steps);
      _line('');
    }
    _indent = 0;
    _out
      ..writeln('}')
      ..writeln();
  }

  /// A Dart literal for a TestStand default value, respecting the variable's
  /// declared [type]: only Number/Boolean-typed values coerce (review finding:
  /// a Str local whose text is "True" or "42" must stay a string).
  String _literal(String value, String? type) {
    final t = type?.toLowerCase() ?? '';
    if (t.contains('num')) {
      return num.tryParse(value)?.toString() ?? "'${_escape(value)}'";
    }
    if (t.contains('bool')) {
      if (value == 'True') return 'true';
      if (value == 'False') return 'false';
      return "'${_escape(value)}'";
    }
    if (t.isEmpty) {
      // No declared type recovered: coerce only unambiguous numerics/bools.
      if (num.tryParse(value) != null) return value;
      if (value == 'True') return 'true';
      if (value == 'False') return 'false';
    }
    return "'${_escape(value)}'";
  }

  // ── steps ──────────────────────────────────────────────────────────────────

  void _emitSteps(List<Step> steps) {
    // Block stack: each opener records its kind plus the state its closer
    // needs — the For increment (emitted before `}` and before `continue`),
    // the Do-While condition, and the Select label id.
    final open =
        <({FlowKind kind, String? increment, String? condition, int selectId})>[];
    var selectCounter = 0;
    const loopKinds = {
      FlowKind.whileLoop,
      FlowKind.doWhile,
      FlowKind.forLoop,
      FlowKind.forEach,
    };

    ({FlowKind kind, String? increment, String? condition, int selectId})?
        innermost(bool Function(FlowKind) test) {
      for (var i = open.length - 1; i >= 0; i--) {
        if (test(open[i].kind)) return open[i];
      }
      return null;
    }

    void closeBlock(
        ({FlowKind kind, String? increment, String? condition, int selectId})
            opened,
        {String note = ''}) {
      if (opened.kind == FlowKind.forLoop && opened.increment != null) {
        _line('${_exprStatement(opened.increment!)}; // for increment');
      }
      _indent--;
      if (opened.kind == FlowKind.doWhile) {
        _line('} while (_truthy(${_expr(opened.condition ?? 'true')}));$note');
      } else {
        _line('}$note');
      }
    }

    for (final step in steps) {
      final flow = step.flowControl;
      final name = _comment(step.name);
      if (flow == null) {
        _emitPlainStep(step);
        continue;
      }
      switch (flow.kind) {
        case FlowKind.ifBlock:
          _line('if (_truthy(${_expr(flow.condition ?? 'true')})) { // $name');
          _indent++;
          open.add(
              (kind: flow.kind, increment: null, condition: null, selectId: 0));
        case FlowKind.elseIf:
          if (open.isEmpty || open.last.kind != FlowKind.ifBlock) {
            _line('// $name: Else-If without an open If (unbalanced source) — '
                'kept as a comment');
            continue;
          }
          _indent--;
          _line('} else if (_truthy(${_expr(flow.condition ?? 'true')})) '
              '{ // $name');
          _indent++;
        case FlowKind.elseBlock:
          if (open.isEmpty || open.last.kind != FlowKind.ifBlock) {
            _line('// $name: Else without an open If (unbalanced source) — '
                'kept as a comment');
            continue;
          }
          _indent--;
          _line('} else { // $name');
          _indent++;
        case FlowKind.whileLoop:
          _line('while (_truthy(${_expr(flow.condition ?? 'true')})) '
              '{ // $name');
          _indent++;
          open.add(
              (kind: flow.kind, increment: null, condition: null, selectId: 0));
        case FlowKind.doWhile:
          _line('do { // $name');
          _indent++;
          open.add((
            kind: flow.kind,
            increment: null,
            condition: flow.condition ?? 'true',
            selectId: 0,
          ));
        case FlowKind.forLoop:
          final init = flow.initialization;
          if (init != null) _line('${_exprStatement(init)}; // $name (init)');
          _line('while (_truthy(${_expr(flow.condition ?? 'true')})) '
              '{ // $name');
          _indent++;
          open.add((
            kind: flow.kind,
            increment: flow.increment,
            condition: null,
            selectId: 0,
          ));
        case FlowKind.forEach:
          final array = flow.arrayExpr ?? '[]';
          _line('for (final _element in _iterate(${_expr(array)})) '
              '{ // $name');
          _indent++;
          final element = flow.arrayElement;
          if (element != null) {
            final assign = _expr('$element = __LWELEMENT__');
            if (assign.startsWith('ts.eval(')) {
              // Baking the Dart loop variable into a TestStand expression
              // string would be fabrication — keep the binding as a TODO.
              _line('// TODO: bind loop element: '
                  '${_comment(element)} = <element>');
            } else {
              _line('${assign.replaceAll('__LWELEMENT__', '_element')};');
            }
          }
          open.add(
              (kind: flow.kind, increment: null, condition: null, selectId: 0));
        case FlowKind.selectBlock:
          selectCounter++;
          _line('sel$selectCounter: { // $name');
          _indent++;
          _line('final _select$selectCounter = '
              '${_expr(flow.itemExpression ?? 'null')};');
          _line('var _matched$selectCounter = false;');
          open.add((
            kind: flow.kind,
            increment: null,
            condition: null,
            selectId: selectCounter,
          ));
        case FlowKind.caseBlock:
          final select =
              innermost((k) => k == FlowKind.selectBlock)?.selectId ?? 0;
          if (select == 0) {
            _line('// $name: Case without an open Select (unbalanced source) '
                '— kept as a comment');
            continue;
          }
          if (flow.isDefaultCase) {
            _line('if (!_matched$select) { // $name (default case)');
          } else {
            _line('if (!_matched$select && _select$select == '
                '${_expr(flow.itemExpression ?? 'null')}) { // $name');
          }
          _indent++;
          _line('_matched$select = true;');
          open.add((
            kind: flow.kind,
            increment: null,
            condition: null,
            selectId: select,
          ));
        case FlowKind.end:
          if (open.isEmpty) {
            _line('// $name: NI_Flow_End without an open block '
                '(unbalanced in source)');
            continue;
          }
          closeBlock(open.removeLast(), note: ' // $name');
        case FlowKind.breakStmt:
          final target = innermost(
              (k) => k == FlowKind.selectBlock || loopKinds.contains(k));
          if (target == null) {
            _line('// $name: Break with no enclosing loop/select — kept as a '
                'comment');
          } else if (target.kind == FlowKind.selectBlock) {
            _line('break sel${target.selectId}; // $name');
          } else {
            _line('break; // $name');
          }
        case FlowKind.continueStmt:
          final loop = innermost(loopKinds.contains);
          if (loop == null) {
            _line('// $name: Continue with no enclosing loop — kept as a '
                'comment');
          } else {
            if (loop.kind == FlowKind.forLoop && loop.increment != null) {
              _line('${_exprStatement(loop.increment!)}; // for increment '
                  '(before continue)');
            }
            _line('continue; // $name');
          }
      }
    }
    // Close any blocks the source left unbalanced (never emit broken Dart).
    while (open.isNotEmpty) {
      closeBlock(open.removeLast(),
          note: ' // closed: unbalanced block in source');
    }
  }

  /// An expression used as a statement: assignment translates directly,
  /// anything else routes through `ts.eval` to keep the side effect.
  String _exprStatement(String raw) => _expr(raw);

  void _emitPlainStep(Step step) {
    final settings = step.settings;
    final precondition = settings.precondition;
    if (precondition != null) {
      _line('if (_truthy(${_expr(precondition)})) { '
          '// precondition of ${_comment(step.name)}');
      _indent++;
    }

    final pre = settings.preExpression;
    if (pre != null) _line('${_exprStatement(pre)}; // pre-expression');

    _emitStepAction(step);

    final post = settings.postExpression;
    if (post != null && step.type != 'Statement') {
      _line('${_exprStatement(post)}; // post-expression');
    }

    if (precondition != null) {
      _indent--;
      _line('}');
    }
  }

  void _emitStepAction(Step step) {
    final module = step.module;
    final name = _comment(step.name);
    switch (step.type) {
      case 'Statement':
        final expression = step.settings.postExpression;
        if (expression != null) {
          _line('${_exprStatement(expression)}; // $name');
        } else {
          _line('// $name: Statement with no expression');
        }
        return;
      case 'Label':
        _line('// label: $name');
        return;
      case 'NI_Wait':
        final timeout = step.timeoutExpression ?? step.waitTimeExpression;
        _line('await ts.wait('
            '${timeout != null ? _expr(timeout) : 'null'}); // $name');
        return;
    }

    switch (module.adapter) {
      case SeqAdapter.sequenceCall:
        final target = module.sequenceName;
        final inFileFn = target != null ? _sequenceFnNames[target] : null;
        if (inFileFn != null) {
          // Parameter bindings on the call are not yet exported — the callee
          // runs on its declared defaults. Stated, not hidden.
          _line('await $inFileFn(ts); // $name '
              '(call parameters not exported yet)');
        } else {
          _line('await ${_stubFor(step, module)}(ts); // $name: '
              'external sequence call');
        }
      case SeqAdapter.labView:
      case SeqAdapter.cModule:
      case SeqAdapter.python:
      case SeqAdapter.unknown:
        _line('await ${_stubFor(step, module)}(ts); // $name'
            '${step.type != null ? ' [${_comment(step.type!)}]' : ''}');
      case SeqAdapter.none:
        _line('// $name'
            '${step.type != null ? ' [${_comment(step.type!)}]' : ''}: '
            'no code module');
    }
  }

  String _stubFor(Step step, StepModule module) {
    final target = module.viPath ??
        module.moduleSourcePath ??
        module.pythonModulePath ??
        module.sequenceName ??
        // An expression-form SequenceCall names its target dynamically; keep
        // the expression so the stub says what it would resolve.
        module.sequenceNameExpression ??
        step.name;
    final adapter = module.adapter.name;
    final key = '$adapter|$target';
    return _stubs.putIfAbsent(key, () {
      final base = dartIdentifier(
          target.split(RegExp(r'[/\\]')).last.split('.').first,
          capitalize: true);
      final name = _uniqueTopLevel('call$base');
      _stubDecls.add([
        '/// Stub for the $adapter module call `${_comment(target)}`',
        '/// (from step `${_comment(step.name)}`). TODO: implement against '
            'the real module.',
        'Future<Object?> $name(TsRuntime ts) async =>',
        "    throw UnimplementedError('$adapter call: ${_escape(target)}');",
      ].join('\n'));
      return name;
    });
  }

  void _emitStubs() {
    if (_stubDecls.isEmpty) return;
    _out.writeln('// ── code-module stubs '
        '─────────────────────────────────────────────────────');
    for (final decl in _stubDecls) {
      _out
        ..writeln(decl)
        ..writeln();
    }
  }

  void _emitRuntime() {
    _out.writeln('''
// ── minimal runtime ─────────────────────────────────────────────────────────

/// The TestStand-engine surface the exported logic needs. Expressions beyond
/// mechanical translation arrive at [eval] verbatim.
class TsRuntime {
  // Dynamic on purpose: exported member paths (FileGlobals.X.Y) resolve by
  // dynamic dispatch; a real host can back these with typed objects.
  final dynamic fileGlobals = <String, dynamic>{};
  final dynamic stationGlobals = <String, dynamic>{};
  final dynamic runState = null;
  final dynamic step = null;

  Object? eval(String expression) =>
      throw UnimplementedError('TestStand expression: \$expression');

  Future<void> wait(Object? seconds) async {
    final s = seconds is num ? seconds : null;
    if (s != null) {
      await Future<void>.delayed(
          Duration(microseconds: (s * 1e6).round()));
    }
  }
}

bool _truthy(Object? v) => v == true || (v is num && v != 0);

Iterable<Object?> _iterate(Object? v) =>
    v is Iterable ? v : const <Object?>[];''');
  }
}
