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
///    verbatim in an `_eval('…')` call so no logic is silently dropped or
///    guessed.
///  * Code-module steps become stub invocations; each unique module gets one
///    stub function that throws [UnimplementedError] with the original target.
///  * Steps whose type carries no exportable action are kept as comments —
///    present, ordered, and labeled, never invented.
///
/// [exportSeqFileToDartTest] layers a generated `package:test` harness on the
/// same export — one test per sequence, unimplemented surfaces skip instead
/// of fail — the first (deliberately minimal) cut of the labwright test API.
library;

import 'seq_file.dart';
import 'seq_module.dart';
import 'seq_step.dart';

/// Exports [file] as self-contained Dart source. [sourceName] labels the
/// header comment (typically the input file name).
String exportSeqFileToDart(SeqFile file, {String? sourceName}) =>
    _DartExporter(file, sourceName: sourceName).export();

/// Exports [file] as a **labwright E2E program** — the same exported logic as
/// [exportSeqFileToDart] plus a generated `main()` that turns each **root**
/// sequence (one no other sequence in the file calls — the smallest
/// independently runnable unit) into one `lw.test`; called sequences stay
/// plain functions the tests reach. Steps are just lines of code. The output
/// is a plain Dart program: run it with `dart run` or a set of them with the
/// `labwright` runner — never `dart test` (hardware E2E owns the process).
///
/// The boilerplate contract:
///  * **Stubs are generated for VI calls only.** A LabVIEW-adapter step calls
///    a named stub that throws [UnimplementedError] — implement the stub to
///    port it. Every other unported surface (DLL / Python / external
///    sequence / a typed step whose action is not exported) is an inline
///    `throw UnimplementedError('…')` line naming its target — exceptions
///    are how tests fail, so an armed test is loud about what is missing.
///  * A test whose reachable code still contains unported surfaces is
///    emitted as `lw.skipTest` with a TODO comment listing them — the suite
///    ships green; renaming to `lw.test` arms it.
///  * Requirement tracing IDs (`Requirements.Links`) attach to TESTS: each
///    test carries the union of the links declared by every sequence and
///    step it reaches — the runner's report traces them.
String exportSeqFileToLabwright(SeqFile file, {String? sourceName}) =>
    _DartExporter(file, sourceName: sourceName, asTest: true).export();

/// A multi-file project export: generated sources by output path.
class SeqProjectExport {
  const SeqProjectExport({required this.files});

  /// Output file name → generated Dart source. Contains one
  /// `<stem>_seq.dart` module per input (exposing `register()`), the
  /// shared `lw_runtime.dart` (station-wide state), and a `main.dart`
  /// that registers every module — the labwright e2e entry point.
  final Map<String, String> files;
}

/// Exports several sequence files as ONE labwright E2E project, so an
/// external SequenceCall whose target file is in the set binds to that
/// module's real exported function (`await other_module.fn();`) instead
/// of a stub. [byPath] keys are '/'-separated relative paths (as the
/// files reference each other); targets outside the set keep stubs.
/// Resolution: exact caller-relative path first, then a unique
/// case-insensitive basename match (TestStand resolves bare basenames
/// via search paths — 99.5% of corpus references are bare basenames);
/// expression-form targets and ambiguous matches stay stubs. Resolved
/// calls still mark the owning test disarmed (`lw.skipTest`) — the
/// callee usually carries its own stubs, and v1 does not chase
/// cross-module reachability, so nothing can fabricate a green run.
SeqProjectExport exportSeqProjectToLabwright(Map<String, SeqFile> byPath) {
  String norm(String p) => p.replaceAll(r'\', '/');
  String baseOf(String p) => norm(p).split('/').last;
  String stemOf(String p) {
    final b = baseOf(p);
    return b.toLowerCase().endsWith('.seq') ? b.substring(0, b.length - 4) : b;
  }

  String snake(String text) {
    final cleaned = text
        .replaceAll(RegExp('[^A-Za-z0-9]+'), '_')
        .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'),
            (m) => '${m.group(1)}_${m.group(2)}')
        .toLowerCase()
        .replaceAll(RegExp('_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleaned.isEmpty ? 'module' : cleaned;
  }

  // Module names and import prefixes, uniquified.
  final ordered = byPath.keys.toList()..sort();
  final moduleOf = <String, String>{};
  final taken = <String>{'main', 'lw_runtime'};
  for (final key in ordered) {
    var name = '${snake(stemOf(key))}_seq';
    var n = 2;
    while (!taken.add(name)) {
      name = '${snake(stemOf(key))}${n++}_seq';
    }
    moduleOf[key] = name;
  }

  // Predict each module's sequence → function-name table (mirrors the
  // exporter's own assignment: dartIdentifier per sequence in file
  // order, uniquified against the pre-claimed harness names).
  final fnOf = <String, Map<String, String>>{};
  for (final key in ordered) {
    final claimed = <String>{'lw', 'main', 'register'};
    final table = <String, String>{};
    for (final seq in byPath[key]!.sequences) {
      if (table.containsKey(seq.name)) continue;
      var fn = dartIdentifier(seq.name);
      var n = 2;
      while (!claimed.add(fn)) {
        fn = '${dartIdentifier(seq.name)}${n++}';
      }
      table[seq.name] = fn;
    }
    fnOf[key] = table;
  }

  final lowerByBase = <String, List<String>>{};
  for (final key in ordered) {
    (lowerByBase[baseOf(key).toLowerCase()] ??= []).add(key);
  }
  String dirOf(String key) {
    final n = norm(key);
    final cut = n.lastIndexOf('/');
    return cut < 0 ? '' : n.substring(0, cut);
  }

  String joinNorm(String dir, String rel) {
    final parts = <String>[
      if (dir.isNotEmpty) ...dir.split('/'),
      ...norm(rel).split('/'),
    ];
    final out = <String>[];
    for (final part in parts) {
      if (part == '.' || part.isEmpty) continue;
      if (part == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(part);
    }
    return out.join('/');
  }

  String? resolveTargetFile(String callerKey, String sfPath) {
    final exact = joinNorm(dirOf(callerKey), sfPath);
    for (final key in ordered) {
      if (norm(key).toLowerCase() == exact.toLowerCase()) return key;
    }
    final candidates = lowerByBase[baseOf(sfPath).toLowerCase()];
    if (candidates == null) return null;
    if (candidates.length == 1) return candidates.single;
    // Prefer the caller's own directory; otherwise ambiguous → stub.
    final sameDir = [
      for (final c in candidates)
        if (dirOf(c) == dirOf(callerKey)) c,
    ];
    return sameDir.length == 1 ? sameDir.single : null;
  }

  // (callerKey, targetFileRef|seqName) → 'prefix.fn', per-file imports,
  // and the globally-called sequence set (those are not roots).
  final resolvedOf = <String, Map<String, String>>{};
  final importsOf = <String, Set<String>>{};
  final externallyCalledOf = <String, Set<String>>{};
  for (final key in ordered) {
    for (final seq in byPath[key]!.sequences) {
      for (final st in seq.steps) {
        final m = st.module;
        if (m.adapter != SeqAdapter.sequenceCall) continue;
        if (m.specifiesByExpression == true) continue;
        final sf = m.sequenceFile;
        final target = m.sequenceName;
        if (sf == null || target == null) continue;
        final targetKey = resolveTargetFile(key, sf);
        if (targetKey == null || targetKey == key) continue;
        final fn = fnOf[targetKey]![target];
        if (fn == null) continue; // named sequence absent → stub
        final prefix = moduleOf[targetKey]!;
        (resolvedOf[key] ??= {})['$sf|$target'] =
            '$prefix.$fn';
        (importsOf[key] ??= {}).add(targetKey);
        (externallyCalledOf[targetKey] ??= {}).add(target);
      }
    }
  }

  final files = <String, String>{};
  // The exported modules use `dynamic` engine state on purpose (member
  // paths on FileGlobals/RunState resolve at runtime), which
  // strict-casts would reject — the project carries its own default
  // analysis options so it analyzes the same everywhere.
  files['analysis_options.yaml'] = [
    '# GENERATED by labwright_seq exportSeqProjectToLabwright.',
    '# Exported modules use dynamic TestStand engine state by design;',
    '# implicit downcasts from dynamic are part of that contract.',
    'analyzer:',
    '  language:',
    '    strict-casts: false',
    '',
  ].join('\n');
  files['lw_runtime.dart'] = [
    '// GENERATED by labwright_seq exportSeqProjectToLabwright — shared',
    '// runtime.',
    '',
    '/// Station-wide TestStand state (StationGlobals) — ONE instance',
    "/// across every module, mirroring the engine's scoping.",
    'final dynamic stationGlobals = <String, dynamic>{};',
    '',
  ].join('\n');

  final registers = <String>[];
  for (final key in ordered) {
    final module = moduleOf[key]!;
    final extra = <String>[
      "import 'lw_runtime.dart';",
      for (final dep in (importsOf[key] ?? const <String>{}).toList()
        ..sort())
        "import '${moduleOf[dep]!}.dart' as ${moduleOf[dep]!};",
    ];
    final resolved = resolvedOf[key] ?? const <String, String>{};
    files['$module.dart'] = _DartExporter(
      byPath[key]!,
      sourceName: key,
      asTest: true,
      registerName: 'register',
      extraImports: extra,
      resolveExternalCall: (m) =>
          resolved['${m.sequenceFile}|${m.sequenceName}'],
      externallyCalled: externallyCalledOf[key] ?? const <String>{},
    ).export();
    // Modules that never touch station-wide state don't need the shared
    // runtime import (the placeholder comment deliberately avoids the
    // lowercase identifier so it can't defeat this check).
    var src = files['$module.dart']!;
    if (!RegExp(r'stationGlobals').hasMatch(
        src.replaceFirst("import 'lw_runtime.dart';\n", ''))) {
      src = src.replaceFirst("import 'lw_runtime.dart';\n", '');
      files['$module.dart'] = src;
    }
    registers.add(module);
  }

  files['main.dart'] = [
    '// GENERATED by labwright_seq exportSeqProjectToLabwright — the e2e',
    '// entry point: registers every module; labwright runs the suite.',
    for (final module in registers)
      "import '$module.dart' as $module;",
    '',
    'void main() {',
    for (final module in registers) '  $module.register();',
    '}',
    '',
  ].join('\n');

  return SeqProjectExport(files: files);
}

/// Dart reserved words and builtins a generated identifier must not collide
/// with (suffixed with `$` when hit).
const _dartReserved = {
  'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default', 'break',
  'continue', 'return', 'var', 'final', 'const', 'void', 'main', 'class',
  'new', 'this', 'super', 'true', 'false', 'null', 'is', 'in', 'try',
  'catch', 'finally', 'throw', 'rethrow', 'assert', 'await', 'async',
  'enum', 'extends', 'with', 'implements', 'abstract', 'static', 'late',
  'required', 'dynamic', 'yield', 'export', 'import', 'library', 'part',
  // names the generator itself uses in scope (the top-level engine-state
  // globals, the labwright import prefix, and legacy context names):
  'fileGlobals', 'stationGlobals', 'runState', 'step',
  'ts', 'params', 'locals', 's', 'ctx', 'lw',
};

/// A Dart-identifier-safe form of a TestStand name: camelCase, invalid
/// characters dropped, leading digit guarded, reserved/in-scope words suffixed.
String dartIdentifier(String name, {bool capitalize = false}) {
  // Split on non-alphanumerics, then split camel/acronym boundaries inside
  // each chunk: lower→Upper, and acronym-run→Word (DUTPresent → DUT +
  // Present). Acronym runs then case like ordinary words (Effective Dart:
  // "capitalize acronyms like words") — GUI Message UI SET →
  // guiMessageUiSet, not gUIMessageUISET.
  final words = <String>[
    for (final chunk in name.split(RegExp(r'[^A-Za-z0-9]+')))
      if (chunk.isNotEmpty)
        ...chunk
            .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'),
                (m) => '${m.group(1)} ${m.group(2)}')
            .replaceAllMapped(RegExp(r'([A-Z]+)([A-Z][a-z])'),
                (m) => '${m.group(1)} ${m.group(2)}')
            .split(' ')
            .where((w) => w.isNotEmpty),
  ];
  if (words.isEmpty) return capitalize ? 'Unnamed' : 'unnamed';
  final buffer = StringBuffer();
  for (var i = 0; i < words.length; i++) {
    final word = words[i].toLowerCase();
    if (i == 0 && !capitalize) {
      buffer.write(word);
    } else {
      buffer.write(word[0].toUpperCase() + word.substring(1));
    }
  }
  var id = buffer.toString();
  if (RegExp(r'^[0-9]').hasMatch(id)) id = 'v$id';
  if (_dartReserved.contains(id)) id = '$id\$';
  return id;
}

/// The TestStand variable roots the translator rewrites. `FileGlobals`/
/// `StationGlobals`/`RunState`/`Step` map to generated top-level `dynamic`
/// state (member paths resolve by dynamic dispatch); `Locals`/`Parameters`
/// rewrite to the sequence's own typed Dart variables (per-sequence id
/// maps — see `_localIds`/`_paramIds`), so they are not in this table.
const _variableRoots = {
  'FileGlobals': 'fileGlobals',
  'StationGlobals': 'stationGlobals',
  'RunState': 'runState',
  'Step': 'step',
};

/// Whether a root-rewritten expression is **mechanically Dart-safe**: only
/// identifiers/member access, numbers, strings, and the operator set TestStand
/// shares with Dart. `%` is deliberately absent — TestStand's modulo is
/// C-style (sign of dividend) while Dart's is Euclidean, so `%` expressions
/// keep their TestStand semantics via `_eval`. Bitwise `&`/`|` are handled
/// separately (they bind tighter than comparisons in Dart but looser in
/// TestStand's C-like grammar, so mechanical passthrough would silently
/// re-parenthesize the expression).
final _dartSafeExpression = RegExp(
    r"^[A-Za-z0-9_.\s+\-*/!<>=&|(),'\x22\[\]]+$");

/// TestStand built-ins the exporter translates to generated top-level
/// helper functions (chosen from corpus frequency: these cover the bulk of
/// the `_eval` fallbacks). Each helper implements the common arity and
/// throws [UnimplementedError] for the engine-specific forms, so the
/// generated code always compiles and never silently changes semantics.
const _builtinCalls = {
  'Len': '_len',
  'GetNumElements': '_getNumElements',
  'SetNumElements': '_setNumElements',
  'Str': '_str',
  'Left': '_left',
  'Right': '_right',
  'Mid': '_mid',
  'Find': '_find',
  'Random': '_random',
};

/// Constructs that force the `_eval` fallback even when the charset looks
/// safe: any function-style call that is NOT a rewritten helper call
/// (TestStand's built-in library is large; only [_builtinCalls] are
/// translated), plus engine-only operators. Parenthesized grouping
/// (`(a || b)`) is fine — only `identifier(` marks a call; the rewritten
/// `_helper(` calls are exempted by the leading underscore.
final _testStandOnly = RegExp(r'(?<!\.)\b[A-Za-z][A-Za-z0-9_]*\s*\(|#|->');

class _DartExporter {
  _DartExporter(this.file,
      {this.sourceName,
      this.asTest = false,
      this.registerName,
      this.extraImports = const [],
      this.resolveExternalCall,
      this.externallyCalled = const {}});

  /// PROJECT mode (multi-file export): the module exposes
  /// `void <registerName>()` instead of `main()`, [extraImports] lines
  /// (the shared runtime + prefixed sibling modules) follow the header,
  /// [resolveExternalCall] binds an external SequenceCall to a sibling
  /// module's `prefix.fn` (null → today's stub), and sequences in
  /// [externallyCalled] are not roots (another module calls them).
  final String? registerName;
  final List<String> extraImports;
  final String? Function(StepModule module)? resolveExternalCall;
  final Set<String> externallyCalled;

  final SeqFile file;
  final String? sourceName;

  /// When set, the export is a labwright E2E program: the header imports
  /// `package:labwright` (prefixed `lw` so generated names cannot shadow
  /// it), only VI calls get stubs (other unported surfaces are inline
  /// throws), and a `main()` harness of one `lw.test`/`lw.skipTest` per root
  /// sequence is appended after the runtime.
  final bool asTest;

  /// E2E mode: sequences whose own emitted body contains an unported surface
  /// (a stub call or an inline `throw UnimplementedError`), by name —
  /// reachability from each root decides `lw.test` vs `lw.skipTest`.
  final Map<String, Set<String>> _seqUnported = {};

  /// The sequence currently being emitted (unported bookkeeping).
  String? _currentSeq;

  /// TestStand name → generated Dart identifier for the current sequence's
  /// locals and parameters (typed top-of-function declarations / named
  /// args). `Locals.X` / `Parameters.X` rewrite through these; a reference
  /// to an undeclared name falls back to `_eval` (honest, never guessed).
  Map<String, String> _localIds = const {};
  Map<String, String> _paramIds = const {};

  /// Generated Dart identifier → its declared Dart type ('double' | 'bool'
  /// | 'String' | 'List' | 'dynamic') for the current sequence — drives the
  /// _truthy elision and the double-subscript guard.
  Map<String, String> _idTypes = const {};

  void _markUnported(String target) {
    final seq = _currentSeq;
    if (seq != null) (_seqUnported[seq] ??= {}).add(target);
  }

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

  void _line(String text) {
    if (asTest && text.isNotEmpty) _scanHazards(text);
    _out.writeln(text.isEmpty ? '' : '${'  ' * _indent}$text');
  }

  /// E2E mode: statically-CERTAIN runtime hazards in an emitted body line
  /// disarm the owning root, so a fresh export runs green and the skip
  /// reason says what to port. `_eval` always throws; the engine-state
  /// placeholders can never satisfy a member access (`runState`/`step` are
  /// null, the globals are plain Maps with no such getters). Lookarounds
  /// exclude claimed identifiers (a parameter named `step\$`) and
  /// member paths on other objects (`caller.step.Result`).
  static final Map<RegExp, String> _hazards = {
    RegExp(r'_eval\('): 'untranslated expression in body',
    RegExp(r'(?<![\w\$.])runState(?![\w\$])'):
        'RunState engine access (no engine at run time)',
    RegExp(r'(?<![\w\$.])step\.'):
        'Step engine access (no engine at run time)',
    RegExp(r'(?<![\w\$.])(?:fileGlobals|stationGlobals)\.'):
        'FileGlobals/StationGlobals member access (not exported yet)',
  };

  void _scanHazards(String text) {
    if (_currentSeq == null) return;
    for (final entry in _hazards.entries) {
      if (entry.key.hasMatch(text)) _markUnported(entry.value);
    }
  }

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
    // `lw` is the package:labwright import prefix and `main` the harness
    // entry — no generated top-level name may shadow either.
    if (asTest) _topLevelNames.addAll(const {'lw', 'main'});
    final regName = registerName;
    if (regName != null) _topLevelNames.add(regName);
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
    if (asTest) _emitTestMain();
    return _out.toString();
  }

  void _emitHeader() {
    _out
      ..writeln('// GENERATED by labwright_seq '
          'exportSeqFileToDart${asTest ? 'Test' : ''}'
          '${sourceName != null ? ' from ${_comment(sourceName!)}' : ''}.')
      ..writeln('//')
      ..writeln('// Sequence logic is exported as idiomatic Dart: typed '
          'locals, real control')
      ..writeln('// flow, native waits, and direct function calls. '
          'Code-module calls and')
      ..writeln('// external sequences are stubs; expressions beyond '
          'mechanical translation')
      ..writeln('// are kept verbatim in _eval(...) calls. Nothing is '
          'fabricated: unexportable')
      ..writeln('// steps remain as ordered comments.')
      ..writeln('// ignore_for_file: unused_local_variable, dead_code, '
          'unused_element, unused_label')
      ..writeln()
      ..writeln("import 'dart:math' as math; // ignore: unused_import")
      ..writeln();
    if (asTest) {
      _out.writeln("import 'package:labwright/labwright.dart' as lw;");
      for (final line in extraImports) {
        _out.writeln(line);
      }
      _out.writeln();
    }
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
        while (j < text.length) {
          if (text[j] == r'\') {
            j += 2; // consume the escape pair (fixes even-backslash endings)
            continue;
          }
          if (text[j] == quote) break;
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

  /// Strips TestStand `//` and `/* */` comments from code (non-string)
  /// segments — comments are non-semantic, and a surviving `//` would
  /// swallow the generated line tail after newline flattening.
  String _stripComments(String text) {
    // Single-pass scanner: string literals copy through escape-aware
    // (a quote INSIDE a /* */ comment must not open a bogus string, and
    // a /* inside a string must not open a comment — segment-based
    // stripping got both wrong).
    final out = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      if (c == '"' || c == "'") {
        out.write(c);
        i++;
        while (i < text.length) {
          out.write(text[i]);
          if (text[i] == r'\') {
            if (i + 1 < text.length) out.write(text[i + 1]);
            i += 2;
            continue;
          }
          final closed = text[i] == c;
          i++;
          if (closed) break;
        }
        continue;
      }
      if (c == '/' && i + 1 < text.length && text[i + 1] == '/') {
        while (i < text.length && text[i] != '\n' && text[i] != '\r') {
          i++;
        }
        continue;
      }
      if (c == '/' && i + 1 < text.length && text[i + 1] == '*') {
        final end = text.indexOf('*/', i + 2);
        out.write(' ');
        i = end < 0 ? text.length : end + 2;
        continue;
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// Unwraps `#NoValidation(...)`: it suppresses EDIT-TIME expression
  /// validation only — runtime semantics are the identity, so stripping
  /// the wrapper is lossless.
  String _stripNoValidation(String text) {
    const marker = '#NoValidation(';
    var result = text;
    var at = result.indexOf(marker);
    while (at >= 0) {
      var depth = 1;
      var i = at + marker.length;
      while (i < result.length && depth > 0) {
        if (result[i] == '(') depth++;
        if (result[i] == ')') depth--;
        i++;
      }
      if (depth != 0) return text; // unbalanced — leave for the eval fallback
      result = result.substring(0, at) +
          result.substring(at + marker.length, i - 1) +
          result.substring(i);
      at = result.indexOf(marker);
    }
    return result;
  }

  /// Translates a TestStand expression to Dart, or wraps it in `_eval`.
  String _expr(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return "''";
    trimmed = _stripNoValidation(_stripComments(trimmed)).trim();
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
        // A raw newline cannot live in a single-line Dart literal, and
        // escapes Dart does not share with TestStand (\a, \0, …) would
        // silently drop the backslash — both keep TestStand semantics
        // via the eval fallback. `\$` is escaped so a TestStand literal
        // can never become accidental Dart interpolation.
        if (segment.contains('\n') || segment.contains('\r')) {
          return _evalFallback(raw);
        }
        if (RegExp(r'''\\[^nrt"'\\]''').hasMatch(segment)) {
          return _evalFallback(raw);
        }
        rebuilt.write(segment.replaceAll('\$', r'\$'));
        continue;
      }
      var code = segment;
      // Unknown dotted roots (Enums.X, station types) and the `*` dereference
      // prefix have no mechanical Dart form.
      for (final m
          in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\.').allMatches(code)) {
        final precededByDot =
            m.start > 0 && code.substring(m.start - 1, m.start) == '.';
        final root = m.group(1)!;
        if (!precededByDot &&
            !_variableRoots.containsKey(root) &&
            root != 'Locals' &&
            root != 'Parameters') {
          return _evalFallback(raw);
        }
      }
      if (RegExp(r'\*\s*[A-Za-z_]').hasMatch(code)) return _evalFallback(raw);
      code = code
          .replaceAll(RegExp(r'\bTrue\b'), 'true')
          .replaceAll(RegExp(r'\bFalse\b'), 'false')
          .replaceAll(RegExp(r'(?<!\.)\bNothing\b'), 'null');
      // Locals/Parameters rewrite to the sequence's own typed Dart
      // variables; a reference to an UNDECLARED name has no variable to
      // land on — _eval fallback, never guessed.
      var undeclared = false;
      for (final (root, ids) in [
        ('Locals', _localIds),
        ('Parameters', _paramIds),
      ]) {
        code = code.replaceAllMapped(
          RegExp('\\b$root\\.([A-Za-z_][A-Za-z0-9_.]*)'),
          (m) {
            final segments = m.group(1)!.split('.');
            final id = ids[segments.first];
            if (id == null) {
              undeclared = true;
              return m.group(0)!;
            }
            return segments.length == 1
                ? id
                : '$id.${segments.sublist(1).join('.')}';
          },
        );
      }
      if (undeclared) return _evalFallback(raw);
      for (final entry in _variableRoots.entries) {
        code = code.replaceAllMapped(
          RegExp('\\b${entry.key}\\.([A-Za-z_][A-Za-z0-9_.]*)'),
          (m) => '${entry.value}.${m.group(1)!}',
        );
      }
      // Translate the catalogued TestStand built-ins to ts.* method calls
      // (not preceded by a dot — a member path stays a member path).
      for (final entry in _builtinCalls.entries) {
        code = code.replaceAllMapped(
          RegExp('(?<![.A-Za-z0-9_])${entry.key}\\s*\\('),
          (_) => '${entry.value}(',
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
      // An expression left syntactically incomplete (a comment swallowed
      // its continuation: `GetSequenceFile().`) cannot be emitted as Dart.
      if (RegExp(r'[.+\-*/<>=&|!,]\s*$').hasMatch(code)) {
        return _evalFallback(raw);
      }
      // A method call on a TYPED local (x.SetNumElements(...)) has no
      // Dart member to land on — dynamic receivers dispatch, typed
      // ones would not compile. Keep TestStand semantics via eval.
      for (final m in RegExp(
              r'\b([A-Za-z_][A-Za-z0-9_]*)\.[A-Za-z_][A-Za-z0-9_.]*\s*\(')
          .allMatches(code)) {
        if (_idTypes.containsKey(m.group(1)) &&
            _idTypes[m.group(1)] != 'dynamic') {
          return _evalFallback(raw);
        }
      }
      // A double-typed variable used as a LIST SUBSCRIPT cannot compile
      // (Dart indexes with int) and truncation vs rounding is a TestStand
      // semantic we have not pinned — keep via eval.
      for (final m in RegExp(r'\[([^\[\]]*)\]').allMatches(code)) {
        for (final idm in RegExp(r'[A-Za-z_][A-Za-z0-9_]*')
            .allMatches(m.group(1)!)) {
          if (_idTypes[idm.group(0)] == 'double') return _evalFallback(raw);
        }
      }
      // Any bare identifier that survived rewriting must be a name the
      // generated scope actually declares — otherwise it is a TestStand
      // constant (Nothing, NAN, INF, ...) that would not compile.
      const knownBare = {
        'true', 'false', 'null',
        'fileGlobals', 'stationGlobals', 'runState', 'step',
      };
      final generatedName =
          RegExp(r'^_(select|matched)\d+$|^_element$|^__LWELEMENT__$|^_[a-z][A-Za-z0-9]*$');
      final codeSansKeys = code.replaceAll(RegExp(r"'[^']*'"), '');
      for (final m in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\b')
          .allMatches(codeSansKeys)) {
        final id = m.group(1)!;
        final precededByDot = m.start > 0 &&
            codeSansKeys.substring(m.start - 1, m.start) == '.';
        if (precededByDot) continue;
        if (!knownBare.contains(id) &&
            !generatedName.hasMatch(id) &&
            !_localIds.containsValue(id) &&
            !_paramIds.containsValue(id)) {
          return _evalFallback(raw);
        }
      }
      rebuilt.write(code);
    }
    return rebuilt.toString();
  }

  String _evalFallback(String raw) => "_eval('${_escape(raw)}')";

  /// A condition expression: translates via [_expr] and drops the `_truthy`
  /// wrapper when the result is STATICALLY a Dart bool — comparisons
  /// (`==`/`!=` are bool on Object; `<` etc. only with a typed/literal
  /// receiver), `!`-prefixed forms, `&&`/`||` combinations (Dart casts the
  /// operands to bool either way), bool literals, and bool-typed
  /// locals/params. A double-typed variable becomes the exact TestStand
  /// numeric truthiness `x != 0`. Everything else (dynamic member paths,
  /// `_eval` results, String/num expressions) keeps `_truthy`.
  String _cond(String raw) {
    final e = _expr(raw);
    if (_staticallyBool(e)) return e;
    if (_idTypes[e] == 'double') return '$e != 0';
    return '_truthy($e)';
  }

  bool _staticallyBool(String e) {
    if (e.startsWith('_eval(')) return false;
    if (e == 'true' || e == 'false') return true;
    if (_idTypes[e] == 'bool') return true;
    if (e.startsWith('!')) return true; // Dart ! forces a bool static type
    // Top-level scan outside string literals and parens.
    var depth = 0;
    String? topOp;
    for (final (segment, isString) in _segments(e)) {
      if (isString) continue;
      for (var i = 0; i < segment.length; i++) {
        final c = segment[i];
        if (c == '(' || c == '[') depth++;
        if (c == ')' || c == ']') depth--;
        if (depth > 0) continue;
        if (c == '&' && i + 1 < segment.length && segment[i + 1] == '&') {
          return true; // both operands are cast to bool by Dart
        }
        if (c == '|' && i + 1 < segment.length && segment[i + 1] == '|') {
          return true;
        }
        if ((c == '=' || c == '!') &&
            i + 1 < segment.length &&
            segment[i + 1] == '=') {
          topOp ??= '==';
        }
        if (c == '<' || c == '>') topOp ??= '<';
      }
    }
    if (topOp == '==') return true; // Object.== is declared bool
    if (topOp == '<') {
      // Ordering operators are provably bool only on a typed receiver:
      // a numeric/string literal or a typed local/param leading the LHS.
      final lead = RegExp(r'^\(?\s*([A-Za-z_][A-Za-z0-9_]*|[0-9.]+)')
          .firstMatch(e)
          ?.group(1);
      if (lead == null) return false;
      if (RegExp(r'^[0-9.]').hasMatch(lead)) return true;
      final t = _idTypes[lead];
      return t == 'double' || t == 'bool' || t == 'String';
    }
    return false;
  }

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

    _currentSeq = sequence.name;
    // Parameter and local identifiers: unique within the function scope and
    // never colliding with the generated top-level names (state globals,
    // sequence functions, stubs) — a local named like a sequence would
    // otherwise shadow the function it calls.
    final used = <String>{
      'fileGlobals', 'stationGlobals', 'runState', 'step',
      ..._topLevelNames,
    };
    String claim(String name) {
      final base = dartIdentifier(name);
      var id = base;
      var n = 2;
      while (!used.add(id)) {
        id = '$base$n';
        n++;
      }
      return id;
    }

    final seenParams = <String>{};
    final emittedParams = [
      for (final p in sequence.parameters)
        if (seenParams.add(p.name)) p, // duplicate names in source: first wins
    ];
    _paramIds = {for (final p in emittedParams) p.name: claim(p.name)};
    final seenLocals = <String>{};
    final emittedLocals = [
      for (final local in sequence.locals)
        // ResultList is the engine's implicit result bookkeeping, not user
        // state — skipped (a reference to it falls back to _eval).
        if (local.name != 'ResultList' && seenLocals.add(local.name)) local,
    ];
    _localIds = {for (final l in emittedLocals) l.name: claim(l.name)};
    String typeOf(SeqVariable v) {
      final scalar = _scalarType(v);
      if (scalar != null) return scalar.$1;
      return _isArrayVar(v) ? 'List' : 'dynamic';
    }

    _idTypes = {
      for (final p in emittedParams) _paramIds[p.name]!: typeOf(p),
      for (final l in emittedLocals) _localIds[l.name]!: typeOf(l),
    };

    // Parameters: typed where the class is scalar. Scalars with a declared
    // default are non-nullable; containers are `dynamic` so exported member
    // paths (Parameters.Result.Status) still compile via dynamic dispatch.
    final params = [
      for (final p in emittedParams) _paramDecl(p, _paramIds[p.name]!),
    ];
    _out.writeln('Future<void> $fnName('
        '${params.isEmpty ? '' : '{${params.join(', ')}}'}) async {');
    _indent = 1;

    // Locals: real typed Dart declarations, defaults from the sequence file
    // (TestStand's declared defaults) or the class zero.
    for (final local in emittedLocals) {
      _line(_localDecl(local, _localIds[local.name]!));
    }
    if (emittedLocals.isNotEmpty) _line('');

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
    _currentSeq = null;
    _localIds = const {};
    _paramIds = const {};
    _idTypes = const {};
  }

  /// The Dart (type, zero-default) for a TestStand value class, or null when
  /// the class has no scalar Dart form (containers/refs stay `dynamic` so
  /// exported member paths compile via dynamic dispatch — `Object?` would
  /// reject `.member` at compile time).
  (String, String)? _scalarType(SeqVariable v) =>
      switch (v.raw.className) {
        'Num' => ('double', '0'),
        'Bool' || 'Boolean' => ('bool', 'false'),
        'Str' || 'ExprValue' || 'PathValue' => ('String', "''"),
        _ => null,
      };

  /// Whether the variable is a TestStand array (`Nums`/`Strs`/`Objs`/
  /// `Containers` — any `s`-suffixed array class or an explicit array value).
  bool _isArrayVar(SeqVariable v) =>
      v.raw.array != null ||
      const {'Nums', 'Strs', 'Objs', 'Containers'}
          .contains(v.raw.className);

  String _typeComment(SeqVariable v, {String? rawDefault}) {
    final t = v.type;
    final c = v.comment;
    final parts = [
      if (t != null) t,
      if (rawDefault != null) "default: ${_comment(rawDefault)}",
      if (c != null) _comment(c),
    ];
    if (parts.isEmpty) return '';
    return ' // ${parts.join(' — ')}';
  }

  /// The initializer for a scalar-typed variable: the declared default when
  /// it is a valid literal of the type, else the class zero (with the
  /// original kept in a comment by the caller via [_typeComment] — a default
  /// that is an expression can't be a Dart initializer).
  String _scalarInit(SeqVariable v, String type, String zero) {
    final value = v.value;
    if (value == null) return zero;
    switch (type) {
      case 'double':
        final n = num.tryParse(value);
        if (n == null) return zero; // non-literal default; raw kept in comment
        // Integral magnitudes past 2^53 are imprecise as Dart int literals
        // in a double context — emit the double form instead.
        return n is int && n.abs() < 9007199254740992
            ? n.toString()
            : n.toDouble().toString();
      case 'bool':
        final lower = value.toLowerCase();
        if (lower == 'true') return 'true';
        if (lower == 'false') return 'false';
        return zero; // non-literal default; raw kept in comment
      default:
        return "'${_escape(value)}'";
    }
  }

  /// A typed named-parameter declaration. Scalars are non-nullable with the
  /// declared default (or the class zero — TestStand parameters always have
  /// a default); containers are `dynamic`.
  String _paramDecl(SeqVariable p, String id) {
    final scalar = _scalarType(p);
    if (scalar != null) {
      final (type, zero) = scalar;
      final init = _scalarInit(p, type, zero);
      return '$type $id = $init';
    }
    if (_isArrayVar(p)) return 'List<dynamic> $id = const []';
    return 'dynamic $id';
  }

  /// A typed local declaration line: `double loopIndex = 0; // Num`.
  String _localDecl(SeqVariable local, String id) {
    final scalar = _scalarType(local);
    if (scalar != null) {
      final (type, zero) = scalar;
      final init = _scalarInit(local, type, zero);
      // A non-literal declared default (expression, NAN, …) initializes to
      // the class zero — the raw text rides in the comment, never dropped.
      final fellBack = local.value != null &&
          init == zero &&
          type != 'String';
      return '$type $id = $init;'
          '${_typeComment(local, rawDefault: fellBack ? local.value : null)}';
    }
    if (_isArrayVar(local)) {
      return 'List<dynamic> $id = ${_arrayInit(local)};${_typeComment(local)}';
    }
    return 'dynamic $id;${_typeComment(local)}';
  }

  /// An array local's initializer: the DECLARED default elements (TestStand
  /// pre-fills sized arrays — an empty list here would make count-driven
  /// loops silently run zero times where the engine runs N). Scalars come
  /// from each element's stored value or the element-class zero; nested
  /// arrays/objects fall back to null placeholders of the right LENGTH.
  String _arrayInit(SeqVariable local) {
    final elements = local.raw.array;
    if (elements == null || elements.isEmpty) return '<dynamic>[]';
    final parts = <String>[];
    for (final e in elements) {
      final cls = e.className;
      final scalar = e.scalar;
      if (scalar != null) {
        parts.add(switch (cls) {
          'Num' => num.tryParse(scalar)?.toString() ?? "'${_escape(scalar)}'",
          'Bool' || 'Boolean' =>
            scalar.toLowerCase() == 'true' ? 'true' : 'false',
          _ => "'${_escape(scalar)}'",
        });
      } else {
        parts.add(switch (cls) {
          'Num' => '0',
          'Bool' || 'Boolean' => 'false',
          'Str' || 'ExprValue' || 'PathValue' => "''",
          _ => 'null',
        });
      }
    }
    return '<dynamic>[${parts.join(', ')}]';
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
        _line('} while (${_cond(opened.condition ?? 'true')});$note');
      } else {
        _line('}$note');
      }
    }

    const defaultFlowNames = {
      'If', 'Else', 'Else If', 'While', 'Do While', 'For', 'For Each',
      'Select', 'Case', 'End', 'Break', 'Continue', 'Statement', 'Goto',
    };
    for (final step in steps) {
      final flow = step.flowControl;
      final rawName = _comment(step.name);
      // A flow step named by its default TestStand name duplicates the
      // emitted keyword (`} // End`, `{ // If`) — suppressed; a CUSTOM
      // name stays (it is documentation).
      final nameNote =
          defaultFlowNames.contains(rawName) ? '' : ' // $rawName';
      final name = rawName;
      if (flow == null) {
        _emitPlainStep(step);
        continue;
      }
      switch (flow.kind) {
        case FlowKind.ifBlock:
          _line('if (${_cond(flow.condition ?? 'true')}) {$nameNote');
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
          _line('} else if (${_cond(flow.condition ?? 'true')}) '
              '{$nameNote');
          _indent++;
        case FlowKind.elseBlock:
          if (open.isEmpty || open.last.kind != FlowKind.ifBlock) {
            _line('// $name: Else without an open If (unbalanced source) — '
                'kept as a comment');
            continue;
          }
          _indent--;
          _line('} else {$nameNote');
          _indent++;
        case FlowKind.whileLoop:
          _line('while (${_cond(flow.condition ?? 'true')}) '
              '{$nameNote');
          _indent++;
          open.add(
              (kind: flow.kind, increment: null, condition: null, selectId: 0));
        case FlowKind.doWhile:
          _line('do {$nameNote');
          _indent++;
          open.add((
            kind: flow.kind,
            increment: null,
            condition: flow.condition ?? 'true',
            selectId: 0,
          ));
        case FlowKind.forLoop:
          final init = flow.initialization;
          final initDart = init != null ? _exprStatement(init) : null;
          final incrDart =
              flow.increment != null ? _exprStatement(flow.increment!) : null;
          // A real Dart `for` when init and increment both translate
          // mechanically: the increment then runs on `continue` natively,
          // eliminating the re-emit-before-continue pattern (and its
          // missed-increment bug class). Otherwise keep the while-lowering.
          final canFor = (initDart == null || !initDart.startsWith('_eval(')) &&
              (incrDart == null || !incrDart.startsWith('_eval('));
          if (canFor) {
            _line('for (${initDart ?? ''}; '
                '${_cond(flow.condition ?? 'true')}; ${incrDart ?? ''}) '
                '{$nameNote');
            _indent++;
            open.add((
              kind: flow.kind,
              increment: null, // the for statement owns it
              condition: null,
              selectId: 0,
            ));
          } else {
            if (init != null) {
              _line('${initDart!};${nameNote.isEmpty ? ' // init' : '$nameNote (init)'}');
            }
            _line('while (${_cond(flow.condition ?? 'true')}) '
                '{$nameNote');
            _indent++;
            open.add((
              kind: flow.kind,
              increment: flow.increment,
              condition: null,
              selectId: 0,
            ));
          }
        case FlowKind.forEach:
          final array = flow.arrayExpr ?? '[]';
          _line('for (final _element in _iterate(${_expr(array)})) '
              '{$nameNote');
          _indent++;
          final element = flow.arrayElement;
          if (element != null) {
            final assign = _expr('$element = __LWELEMENT__');
            if (assign.startsWith('_eval(')) {
              // Baking the Dart loop variable into a TestStand expression
              // string would be fabrication — keep the binding as a TODO.
              _line('// TODO: bind loop element: '
                  '${_comment(element)} = <element>');
            } else {
              // Cast to the target's declared type — loud on a
              // mismatched element, never a silent reinterpretation.
              final targetId = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)')
                  .firstMatch(assign)
                  ?.group(1);
              final cast = switch (_idTypes[targetId]) {
                'double' => '(_element as num).toDouble()',
                'bool' => '_element as bool',
                'String' => '_element as String',
                'List' => '_element as List<dynamic>',
                _ => '_element',
              };
              _line('${assign.replaceAll('__LWELEMENT__', cast)};');
            }
          }
          open.add(
              (kind: flow.kind, increment: null, condition: null, selectId: 0));
        case FlowKind.selectBlock:
          selectCounter++;
          _line('sel$selectCounter: {$nameNote');
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
            _line('if (!_matched$select) {${nameNote.isEmpty ? ' // default case' : '$nameNote (default)'}');
          } else {
            _line('if (!_matched$select && _select$select == '
                '${_expr(flow.itemExpression ?? 'null')}) {$nameNote');
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
          closeBlock(open.removeLast(), note: nameNote);
        case FlowKind.breakStmt:
          final target = innermost(
              (k) => k == FlowKind.selectBlock || loopKinds.contains(k));
          if (target == null) {
            _line('// $name: Break with no enclosing loop/select — kept as a '
                'comment');
          } else if (target.kind == FlowKind.selectBlock) {
            _line('break sel${target.selectId};$nameNote');
          } else {
            _line('break;$nameNote');
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
            _line('continue;$nameNote');
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
  /// anything else routes through `_eval` to keep the side effect.
  /// A top-level assignment to a TYPED variable whose right-hand side
  /// is visibly of another kind (Str local = numeric expression —
  /// TestStand's engine coercion there is not pinned) keeps TestStand
  /// semantics via the eval fallback rather than a guessed cast.
  String _exprStatement(String raw) {
    final translated = _expr(raw);
    if (translated.startsWith('_eval(')) return translated;
    final m =
        RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=(?![=])').firstMatch(translated);
    if (m != null) {
      final lhsType = _idTypes[m.group(1)];
      final rhs = translated.substring(m.end).trim();
      final looksString = rhs.startsWith("'") ||
          rhs.startsWith('"') ||
          _idTypes[rhs] == 'String' ||
          rhs.startsWith('_str(');
      final looksNumericLead = RegExp(r'^[0-9(]').hasMatch(rhs) ||
          _idTypes[RegExp(r'^[A-Za-z_][A-Za-z0-9_]*')
                  .firstMatch(rhs)
                  ?.group(0) ??
              ''] ==
          'double';
      if (lhsType == 'String' && looksNumericLead && !looksString) {
        return _evalFallback(raw);
      }
      if (lhsType == 'double' && looksString) return _evalFallback(raw);
      if (lhsType == 'bool' &&
          !_staticallyBool(rhs) &&
          (looksString || looksNumericLead)) {
        return _evalFallback(raw);
      }
    }
    return translated;
  }

  /// A statement-position expression, split at TOP-LEVEL COMMAS into
  /// sequential statements — TestStand's comma is C-heritage sequential
  /// evaluation, and in statement position the value is discarded, so the
  /// split is lossless (30% of all corpus eval-fallbacks are these
  /// assignment chains). Each piece translates independently; a piece
  /// beyond mechanical translation gets its own _eval line.
  List<String> _stmtParts(String raw) {
    final cleaned = _stripNoValidation(_stripComments(raw));
    final parts = <String>[];
    var depth = 0;
    var start = 0;
    var consumed = 0;
    for (final (segment, isString) in _segments(cleaned)) {
      final base = consumed;
      if (!isString) {
        for (var i = 0; i < segment.length; i++) {
          switch (segment[i]) {
            case '(' || '[' || '{':
              depth++;
            case ')' || ']' || '}':
              depth--;
            case ',':
              if (depth <= 0) {
                parts.add(cleaned.substring(start, base + i));
                start = base + i + 1;
              }
          }
        }
      }
      consumed += segment.length;
    }
    parts.add(cleaned.substring(start));
    bool balanced(String p) {
      var d = 0;
      for (final (seg, isString) in _segments(p)) {
        if (isString) continue;
        for (var i = 0; i < seg.length; i++) {
          if (seg[i] == '(' || seg[i] == '[' || seg[i] == '{') d++;
          if (seg[i] == ')' || seg[i] == ']' || seg[i] == '}') d--;
          if (d < 0) return false;
        }
      }
      // A piece ending inside an unterminated string shows up as a
      // string segment missing its close quote — _segments absorbs to
      // the end, so check the piece's own quote parity cheaply.
      return d == 0 &&
          '"'.allMatches(p.replaceAll(r'\"', '')).length.isEven;
    }

    if (parts.length > 1 && !parts.every(balanced)) {
      return [_exprStatement(raw)]; // a piece mis-sliced — do not split
    }
    final out = <String>[
      for (final p in parts)
        if (p.trim().isNotEmpty) _exprStatement(p),
    ];
    return out.isEmpty ? [_exprStatement(raw)] : out;
  }

  /// Emits a statement-position expression, one line per top-level piece.
  void _emitStmt(String raw, String note) {
    final parts = _stmtParts(raw);
    for (var i = 0; i < parts.length; i++) {
      _line('${parts[i]};'
          '${i == 0 ? ' // $note' : ' // $note (cont.)'}');
    }
  }

  void _emitPlainStep(Step step) {
    final settings = step.settings;
    final precondition = settings.precondition;
    if (precondition != null) {
      _line('if (${_cond(precondition)}) { '
          '// precondition of ${_comment(step.name)}');
      _indent++;
    }

    final pre = settings.preExpression;
    if (pre != null) _emitStmt(pre, 'pre-expression');

    _emitStepAction(step);

    final post = settings.postExpression;
    if (post != null && step.type != 'Statement') {
      _emitStmt(post, 'post-expression');
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
          _emitStmt(expression, name);
        } else {
          _line('// $name: Statement with no expression');
        }
        return;
      case 'Label':
        _line('// label: $name');
        return;
      case 'NI_Wait':
        final timeout = step.timeoutExpression ?? step.waitTimeExpression;
        // A literal wait becomes a plain Future.delayed — no runtime shim;
        // computed waits go through the generated _wait helper.
        final literal = timeout != null ? num.tryParse(timeout.trim()) : null;
        if (literal != null) {
          final ms = (literal * 1000).round();
          _line(ms % 1000 == 0
              ? 'await Future<void>.delayed('
                  'const Duration(seconds: ${ms ~/ 1000})); // $name'
              : 'await Future<void>.delayed('
                  'const Duration(milliseconds: $ms)); // $name');
        } else {
          _line('await _wait('
              '${timeout != null ? _expr(timeout) : 'null'}); // $name');
        }
        return;
    }

    switch (module.adapter) {
      case SeqAdapter.sequenceCall:
        final target = module.sequenceName;
        // Bind to a local sequence ONLY when the call targets the current
        // file (UseCurFile, no file named, or the file's own path) —
        // matching by name alone bound external calls to same-named local
        // sequences, which generated infinite self-recursion (17 corpus
        // sites, e.g. a MainSequence delegating to sibling MainSequences).
        final inFileFn = _isLocalCall(module) && target != null
            ? _sequenceFnNames[target]
            : null;
        // Parameter bindings on the call are not exported yet — the callee
        // would run on its declared defaults, which is NOT the authored
        // semantics (it can even change termination: a corpus recursion
        // walks Parameters.Caller upward and never stops on defaults). A
        // binding call therefore disarms the owning test; a bare call
        // (1 in 20 in the corpus) is exact and stays armed.
        final hasArgs = module.actualArguments?.subProps.isNotEmpty == true ||
            module.actualArguments?.array?.isNotEmpty == true;
        final caveat =
            hasArgs ? ' (call parameters not exported yet)' : '';
        if (inFileFn != null) {
          if (asTest && hasArgs) {
            _markUnported(
                'call parameters of sequence ${target ?? inFileFn}');
          }
          _line('await $inFileFn(); // $name$caveat');
        } else {
          // An EXTERNAL sequence call is just a function that lives in
          // another file. In PROJECT mode a resolvable target binds to the
          // sibling module's real exported function; otherwise (or in
          // single-file mode) it calls a generated stub. Either way it is
          // counted unported so the harness ships the owning test disarmed
          // — a resolved callee usually still contains its own stubs, and
          // v1 does not chase cross-module reachability (conservative,
          // never a fabricated green).
          final resolved = resolveExternalCall?.call(module);
          if (resolved != null) {
            if (asTest) {
              _markUnported('cross-file sequence '
                  '${_stubTarget(step, module)} (see its module TODOs)');
            }
            _line('await $resolved(); // $name: external sequence$caveat');
          } else {
            if (asTest) {
              _markUnported(
                  'external sequence: ${_stubTarget(step, module)}');
            }
            _line('await ${_stubFor(step, module)}(); // $name: '
                'external sequence call');
          }
        }
      case SeqAdapter.labView:
        // VI calls are the ONE code-module adapter that gets a generated
        // stub in E2E mode: the VI is the port target — implementing the
        // stub arms the step (other unported surfaces are inline throws).
        if (asTest) _markUnported(_stubTarget(step, module));
        _line('await ${_stubFor(step, module)}(); // $name'
            '${step.type != null ? ' [${_comment(step.type!)}]' : ''}');
      case SeqAdapter.cModule:
      case SeqAdapter.python:
      case SeqAdapter.unknown:
        if (asTest) {
          _throwLine(
              step, '${module.adapter.name} call', _stubTarget(step, module));
        } else {
          _line('await ${_stubFor(step, module)}(); // $name'
              '${step.type != null ? ' [${_comment(step.type!)}]' : ''}');
        }
      case SeqAdapter.none:
        // E2E mode: a typed step with no code module still carries its
        // TYPE's action (NI_Measurement measures, NumericLimitTest compares)
        // — none of that is exported yet, so a silent no-op would fabricate
        // a pass. Inline throw, naming the type. An UNtyped module-less step
        // genuinely has nothing to run and stays a comment.
        if (asTest && step.type != null) {
          _throwLine(
              step, 'step type ${step.type}', 'action not exported yet');
        } else {
          _line('// $name'
              '${step.type != null ? ' [${_comment(step.type!)}]' : ''}: '
              'no code module');
        }
    }
  }

  /// E2E mode: an unported non-VI surface is an inline throw — exceptions
  /// are how tests fail, so an armed test is loud about what is missing.
  /// Also recorded so the harness emits the owning root as `lw.skipTest`.
  void _throwLine(Step step, String kind, String target) {
    _markUnported('$kind: $target');
    _line("throw UnimplementedError('${_escape('$kind: $target')}'); "
        '// ${_comment(step.name)}'
        '${step.type != null ? ' [${_comment(step.type!)}]' : ''}');
  }

  /// Whether a SequenceCall targets a sequence in the CURRENT file:
  /// the UseCurFile flag, no file named at all, or the file's own path.
  /// Both the emitted call and the root call graph use this — matching
  /// by name alone bound external calls to same-named local sequences
  /// (17 corpus sites), generating infinite self-recursion.
  bool _isLocalCall(StepModule m) =>
      m.usesCurrentFile == true ||
      (m.sequenceFile == null && m.sequenceNameExpression == null) ||
      _isOwnFile(m.sequenceFile);

  /// Whether a SequenceCall's named file is THIS file (by basename,
  /// case-insensitive, as TestStand resolves it) — one corpus file calls
  /// itself by its own path rather than the UseCurFile flag.
  bool _isOwnFile(String? seqFile) {
    final own = sourceName;
    if (seqFile == null || own == null) return false;
    String base(String p) =>
        p.replaceAll(r'\', '/').split('/').last.toLowerCase();
    return base(seqFile) == base(own);
  }

  /// The module's call target — the path/name a stub or pending marker
  /// records so nothing is silently dropped.
  String _stubTarget(Step step, StepModule module) =>
      module.viPath ??
      module.moduleSourcePath ??
      module.pythonModulePath ??
      module.sequenceName ??
      // An expression-form SequenceCall names its target dynamically; keep
      // the expression so the stub says what it would resolve.
      module.sequenceNameExpression ??
      step.name;

  String _stubFor(Step step, StepModule module) {
    final target = _stubTarget(step, module);
    final adapter = module.adapter.name;
    final key = '$adapter|$target';
    return _stubs.putIfAbsent(key, () {
      final isSeq = module.adapter == SeqAdapter.sequenceCall;
      // Strip only a known file extension; a dotted TARGET NAME
      // (UI.TestSocket.SetCaption) keeps every segment — collapsing to the
      // first segment minted unreadable uI2…uI8 collision names.
      final lastSegment = target
          .split(RegExp(r'[/\\]'))
          .last
          .replaceFirst(RegExp(r'\.(vi|seq|dll|py)\$', caseSensitive: false), '');
      // An external sequence call reads as the sequence's own function name
      // (`await loadIniFile();` — implement it, or point it at the other
      // exported file's function); code-module stubs keep the `call` prefix.
      final name = _uniqueTopLevel(isSeq
          ? dartIdentifier(lastSegment)
          : 'call${dartIdentifier(lastSegment, capitalize: true)}');
      _stubDecls.add([
        if (isSeq) ...[
          '/// External sequence `${_comment(target)}`',
          '/// (called from step `${_comment(step.name)}`) — lives in another',
          '/// sequence file. TODO: implement, or delegate to that file\'s',
          '/// exported function.',
        ] else ...[
          '/// Stub for the $adapter module call `${_comment(target)}`',
          '/// (from step `${_comment(step.name)}`). TODO: implement against '
              'the real module.',
        ],
        'Future<Object?> $name() async =>',
        "    throw UnimplementedError('"
            "${_escape(isSeq ? 'external sequence: $target' : '$adapter call: $target')}');",
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

  /// The generated labwright harness: `main()` runs one `lw.test` per ROOT
  /// sequence (the smallest unit no other sequence calls), in file order,
  /// in a plain async call. Called sequences are reached as plain
  /// functions. A root whose reachable code still contains unported
  /// surfaces is emitted `lw.skipTest` with a TODO listing them; its
  /// `requirements:` is the union of the links declared by everything it
  /// reaches. See [exportSeqFileToLabwright] for the contract.
  void _emitTestMain() {
    // In-file call graph (self-calls do not disqualify a root).
    final callTargets = <String, Set<String>>{};
    final called = <String>{};
    for (final sequence in file.sequences) {
      final targets = callTargets[sequence.name] ??= {};
      for (final step in sequence.steps) {
        final target = step.module.sequenceName;
        if (step.module.adapter == SeqAdapter.sequenceCall &&
            _isLocalCall(step.module) &&
            target != null &&
            _sequenceFnNames.containsKey(target) &&
            target != sequence.name) {
          targets.add(target);
          called.add(target);
        }
      }
    }
    var roots = [
      for (final s in file.sequences)
        if (!called.contains(s.name) && !externallyCalled.contains(s.name))
          s,
    ];
    // A purely cyclic file has no roots; every sequence becomes a test
    // rather than silently exporting none.
    if (roots.isEmpty) roots = file.sequences;

    final byName = {for (final s in file.sequences) s.name: s};
    Set<String> reach(String name) {
      final seen = <String>{};
      void visit(String at) {
        if (!seen.add(at)) return;
        callTargets[at]?.forEach(visit);
      }

      visit(name);
      return seen;
    }

    _out
      ..writeln('// ── generated labwright harness '
          '─────────────────────────────────────────────')
      ..writeln()
      // Registration only — bodies run after main returns, in order.
      ..writeln('void ${registerName ?? 'main'}() {');
    for (final root in roots) {
      final reachable = reach(root.name);
      // Requirement links of the whole unit this test runs: the root's, the
      // reached sequences', and every reached step's — de-duplicated, in
      // declaration order.
      final reqs = <String>{};
      final unported = <String>{};
      for (final name in reachable) {
        final seq = byName[name];
        if (seq == null) continue;
        reqs.addAll(seq.requirementLinks);
        for (final step in seq.steps) {
          reqs.addAll(step.settings.requirementLinks);
        }
        unported.addAll(_seqUnported[name] ?? const {});
      }
      // A root with an engine-object parameter (container/reference —
      // emitted `dynamic`, defaulting null) is a CALLBACK: nothing binds
      // that parameter when the harness runs it as a test, so it either
      // throws on the null or vacuously no-ops behind a null guard.
      // Neither is the authored behavior — disarmed, stated.
      for (final p in root.parameters) {
        if (_scalarType(p) == null && !_isArrayVar(p)) {
          unported.add("root parameter '${p.name}' is an engine object "
              '(nothing binds it when run as a test)');
        }
      }
      final reqArg = reqs.isEmpty
          ? ''
          : ' requirements: '
              "[${reqs.map((r) => "'${_escape(r)}'").join(', ')}],";
      final fnName = _sequenceFnNames[root.name]!;
      if (unported.isNotEmpty) {
        _out.writeln('  // TODO: unported — implement, then rename '
            'lw.skipTest -> lw.test to arm:');
        for (final target in unported) {
          _out.writeln('  //   ${_comment(target)}');
        }
      }
      _out
        ..writeln('  lw.${unported.isEmpty ? 'test' : 'skipTest'}'
            "('${_escape(root.name)}',$reqArg () async {")
        ..writeln('    await $fnName();')
        ..writeln('  });');
    }
    _out.writeln('}');
  }

  void _emitRuntime() {
    // The seeded RNG: E2E mode draws the seed from the labwright suite
    // (`--seed` / -Dlabwright.seed) so runs reproduce; plain mode has no
    // suite, so it is unseeded.
    final rngInit = asTest
        ? 'lw.seed != 0 ? math.Random(lw.seed) : math.Random()'
        : 'math.Random()';
    _out.writeln("""
// ── engine state and helpers ────────────────────────────────────────────────
//
// The exported logic is plain Dart. The four TestStand variable scopes that
// outlive a sequence live here as top-level state — `dynamic` on purpose:
// exported member paths (FileGlobals.X.Y) resolve by dynamic dispatch, and a
// real host can back them with typed objects. Expressions beyond mechanical
// translation arrive at [_eval] verbatim; the helper functions cover the
// corpus-frequent TestStand built-ins with the common arity, throwing
// UnimplementedError for engine-specific forms.

final dynamic fileGlobals = <String, dynamic>{};
${registerName != null ? '// Station-wide state (StationGlobals) lives in lw_runtime.dart.' : 'final dynamic stationGlobals = <String, dynamic>{};'}
final dynamic runState = null;
final dynamic step = null;

Object? _eval(String expression) =>
    throw UnimplementedError('TestStand expression: \$expression');

/// TestStand `Len`: string length or array element count.
double _len(Object? v) => switch (v) {
      String s => s.length.toDouble(),
      Iterable i => i.length.toDouble(),
      Map m => m.length.toDouble(),
      _ => throw UnimplementedError('Len of \${v.runtimeType}'),
    };

/// TestStand `GetNumElements` (array size). The engine-specific forms
/// (extra arguments) are not implemented.
double _getNumElements(Object? v, [Object? a]) => a == null
    ? _len(v)
    : throw UnimplementedError('GetNumElements with options');

/// TestStand `SetNumElements`: resizes a growable list, null-filling new
/// slots (the engine default-fills by element type — a null fill is the
/// closest core-Dart equivalent; replace in a real host if it matters).
Object? _setNumElements(Object? v, Object? n, [Object? a]) {
  if (v is! List || n is! num || a != null) {
    throw UnimplementedError('SetNumElements on \${v.runtimeType}');
  }
  final target = n.toInt();
  while (v.length > target) {
    v.removeLast();
  }
  while (v.length < target) {
    v.add(null);
  }
  return v;
}

/// TestStand `Str` (1-arg): number -> string with the engine's default
/// `%\$.13g` format, approximated with toStringAsPrecision(13) + cleanup.
/// C-printf %g edge cases may differ — replace in a real host if exactness
/// matters. Format-string forms are not implemented.
String _str(Object? v, [Object? f1, Object? f2, Object? f3]) {
  if (f1 != null || f2 != null || f3 != null) {
    throw UnimplementedError('Str with format options');
  }
  if (v is! num) return v.toString();
  if ((v is int || v == v.roundToDouble()) && v.abs() < 9007199254740992) {
    return v.toInt().toString();
  }
  var text = v.toStringAsPrecision(13);
  if (text.contains('.') && !text.contains('e')) {
    text = text.replaceAll(RegExp(r'0+\$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  return text;
}

/// TestStand `Left`/`Right`/`Mid`/`Find` string helpers (count clamped).
String _left(Object? s, Object? n) => _clip(s, n, fromLeft: true);
String _right(Object? s, Object? n) => _clip(s, n, fromLeft: false);
String _mid(Object? s, Object? offset, [Object? count]) {
  final text =
      s is String ? s : throw UnimplementedError('Mid of \${s.runtimeType}');
  final start = (offset is num ? offset.toInt() : 0).clamp(0, text.length);
  final end = count is num
      ? (start + count.toInt()).clamp(start, text.length)
      : text.length;
  return text.substring(start, end);
}

double _find(Object? s, Object? sub, [Object? start]) {
  if (s is! String || sub is! String) {
    throw UnimplementedError('Find of \${s.runtimeType}');
  }
  return s
      .indexOf(sub, (start is num ? start.toInt() : 0).clamp(0, s.length))
      .toDouble();
}

String _clip(Object? s, Object? n, {required bool fromLeft}) {
  final text = s is String
      ? s
      : throw UnimplementedError('Left/Right of \${s.runtimeType}');
  final count = (n is num ? n.toInt() : 0).clamp(0, text.length);
  return fromLeft
      ? text.substring(0, count)
      : text.substring(text.length - count);
}

/// TestStand `Random()` / `Random(min, max)`. Seeded from the suite seed
/// when one is set, so a seeded run reproduces its random waits/values.
math.Random? _rngInstance;
double _random([Object? min, Object? max]) {
  final rng = _rngInstance ??= $rngInit;
  final r = rng.nextDouble();
  if (min is num && max is num) return min + r * (max - min);
  if (min == null && max == null) return r;
  throw UnimplementedError('Random with non-numeric bounds');
}

/// A computed wait (a literal wait exports as a plain Future.delayed).
Future<void> _wait(Object? seconds) async {
  final s = seconds is num ? seconds : null;
  if (s != null) {
    await Future<void>.delayed(Duration(microseconds: (s * 1e6).round()));
  }
}

bool _truthy(Object? v) => switch (v) {
      bool b => b,
      num n => n != 0,
      // TestStand converts string operands by numeric parse: non-zero
      // number text is True, anything else False (NI forum-confirmed).
      String s => switch (num.tryParse(s.trim())) {
          final num n => n != 0,
          _ => false,
        },
      null => false,
      _ => throw UnimplementedError(
          'TestStand condition of type \${v.runtimeType}'),
    };

Iterable<Object?> _iterate(Object? v) => v is Iterable
    ? v
    : throw UnimplementedError('ForEach over \${v.runtimeType}');""");
  }
}
