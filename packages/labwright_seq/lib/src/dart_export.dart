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
///  * Sequence-call parameter bindings become real Dart named arguments
///    against the callee's generated signature (`UseDef` rows are omitted —
///    exact via the declared default); an argument beyond mechanical
///    translation rides in a `ts.eval` value, and a scalar bound by
///    reference to a parameter the callee assigns is stated (writeback is
///    not exported).
///  * Code-module steps become stub invocations; each unique module gets one
///    stub function that throws [UnimplementedError] with the original target.
///    An external-sequence stub carries a typed signature recovered from the
///    call sites' prototype snapshots.
///  * Steps whose type carries no exportable action are kept as comments —
///    present, ordered, and labeled, never invented.
///
/// [exportSeqFileToLabwright] layers a generated labwright harness on the
/// same export — one test per root sequence, unimplemented surfaces skip
/// instead of fail — the first (deliberately minimal) cut of the labwright
/// test API.
library;

import 'seq_file.dart';
import 'seq_module.dart';
import 'seq_property.dart';
import 'seq_step.dart';
import 'seq_typedefs.dart';

/// Exports [file] as self-contained Dart source. [sourceName] labels the
/// header comment (typically the input file name). [stats] (optional)
/// collects the call-parameter translation counters.
String exportSeqFileToDart(SeqFile file, {String? sourceName, SeqExportStats? stats}) =>
    _DartExporter(file, sourceName: sourceName, stats: stats).export();

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
String exportSeqFileToLabwright(SeqFile file, {String? sourceName, SeqExportStats? stats}) =>
    _DartExporter(file, sourceName: sourceName, asTest: true, stats: stats).export();

/// Counters the exporter fills while translating SequenceCall argument
/// bindings — the corpus tests print and gate on them. Passing one to
/// [exportSeqFileToDart] / [exportSeqFileToLabwright] is optional and
/// purely observational (the same instance can accumulate across files).
class SeqExportStats {
  /// SequenceCall sites emitted (every target kind).
  int callSites = 0;

  /// Sites that bind at least one argument row (excluding the
  /// expression-form targets, which stay disarmed untranslated).
  int boundSites = 0;

  /// Bound sites whose target is a sequence in the same file.
  int localBoundSites = 0;

  /// Local bound sites emitted with NO per-site call-parameter disarm —
  /// the sites call-parameter export re-arms. (A ts.eval VALUE among the
  /// arguments may still disarm the owning test via the hazard scan.)
  int localBoundSitesRearmed = 0;

  /// Argument rows omitted because the call defers to the callee's
  /// declared default (`UseDef` — exact by omission: the generated
  /// callee signature carries that default).
  int argsByOmission = 0;

  /// Argument rows translated to real Dart named arguments.
  int argsTranslated = 0;

  /// Emitted argument rows whose VALUE is a ts.eval fallback (honest —
  /// the expression rides verbatim; suite mode disarms the owning test).
  int argsEvalFallback = 0;

  /// Per-site call-parameter disarms, counted by reason kind
  /// (`unknown parameter`, `type guard`, `by-ref writeback`, …).
  final Map<String, int> siteDisarms = {};
}

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
/// module's real exported function — bound arguments included, against
/// the callee module's PREDICTED parameter scope
/// (`await other_module.fn(container: c);`) — instead of a stub. [byPath] keys are '/'-separated relative paths (as the
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
        .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m.group(1)}_${m.group(2)}')
        .toLowerCase()
        .replaceAll(RegExp('_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleaned.isEmpty ? 'module' : cleaned;
  }

  // Module names and import prefixes: uniquified STEMS (the `_seq` suffix
  // keeps them clear of `main`/`lw_runtime`), so colliding inputs read
  // `foo_seq`, `foo2_seq`, ….
  final ordered = byPath.keys.toList()..sort();
  final takenStems = <String>{};
  final moduleOf = {
    for (final key in ordered) key: '${_uniqueName(snake(stemOf(key)), takenStems)}_seq',
  };

  // Each module's sequence → function-name table AND per-sequence scope
  // (parameter ids + refined types), computed by the SAME routines the
  // exporter assigns with ([_sequenceFnTable] / [_sequenceScopeTable]
  // over the same reserved-name seed) — predictions that cannot drift,
  // so a cross-module call can bind REAL named arguments.
  final fnOf = <String, Map<String, String>>{};
  final scopeByNameOf = <String, Map<String, _SeqScope>>{};
  for (final key in ordered) {
    final taken = _reservedTopLevelNames(asTest: true, registerName: 'register');
    final file = byPath[key]!;
    fnOf[key] = _sequenceFnTable(file, taken);
    final scopes = _sequenceScopeTable(file, taken, sourceName: key);
    final byName = <String, _SeqScope>{};
    for (var i = 0; i < file.sequences.length; i++) {
      byName.putIfAbsent(file.sequences[i].name, () => scopes[i]);
    }
    scopeByNameOf[key] = byName;
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

  // (callerKey, targetFileRef|seqName) → the callee's 'prefix.fn' plus
  // its predicted scope (named-argument binding), per-file imports, and
  // the globally-called sequence set (those are not roots).
  final resolvedOf = <String, Map<String, _ResolvedCall>>{};
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
        (resolvedOf[key] ??= {})['$sf|$target'] = (fn: '$prefix.$fn', scope: scopeByNameOf[targetKey]![target]!);
        (importsOf[key] ??= {}).add(targetKey);
        (externallyCalledOf[targetKey] ??= {}).add(target);
      }
    }
  }

  // StationGlobals placement: shared state is declared exactly ONCE.
  // Only the modules whose expressions touch it participate; a single
  // referencing module hosts the struct itself (globals stay constrained
  // to the file with the relevant sequences), two or more share it via
  // lw_runtime.dart.
  final stationRefsOf = {
    for (final key in ordered) key: _collectStationGlobalRefs(byPath[key]!),
  };
  final stationUnion = <String>{
    for (final refs in stationRefsOf.values) ...refs,
  };
  final referencing = [
    for (final key in ordered)
      if (stationRefsOf[key]!.isNotEmpty) key,
  ];
  final sharedStation = referencing.length > 1;
  final stationOwner = referencing.length == 1 ? referencing.first : null;
  final stationHome = sharedStation
      ? 'lw_runtime.dart'
      : stationOwner != null
      ? '${moduleOf[stationOwner]!}.dart'
      : 'lw_runtime.dart';

  final files = <String, String>{};
  // The exported modules use `dynamic` engine state on purpose (member
  // paths on RunState/containers resolve at runtime), which strict-casts
  // would reject — the project carries its own default analysis options
  // so it analyzes the same everywhere.
  files['analysis_options.yaml'] = [
    '# GENERATED by labwright_seq exportSeqProjectToLabwright.',
    '# Exported modules use dynamic TestStand engine state by design;',
    '# implicit downcasts from dynamic are part of that contract.',
    'analyzer:',
    '  language:',
    '    strict-casts: false',
    '',
  ].join('\n');
  if (sharedStation) {
    final fields = stationUnion.toList()..sort();
    final canon = <String, String>{};
    final lines = <String>[];
    for (final name in fields) {
      if (_validGlobalFieldName(name) && !canon.containsKey(name.toLowerCase())) {
        canon[name.toLowerCase()] = name;
        lines.add('  dynamic $name;');
      } else {
        lines.add('  ${_unportableFieldLine(name)}');
      }
    }
    files['lw_runtime.dart'] = [
      '// GENERATED by labwright_seq exportSeqProjectToLabwright — shared',
      '// runtime.',
      '',
      '/// Station-wide state (StationGlobals) — ONE instance across every',
      "/// module, mirroring the engine's scoping. Fields are the surface",
      "/// OBSERVED across the project's expressions; station-level values",
      '/// come from the machine, so nothing has a declared default.',
      'class StationGlobals {',
      ...lines,
      '}',
      '',
      'final stationGlobals = StationGlobals();',
      '',
    ].join('\n');
  }

  final registers = <String>[];
  for (final key in ordered) {
    final module = moduleOf[key]!;
    final extra = <String>[
      if (sharedStation && stationRefsOf[key]!.isNotEmpty) "import 'lw_runtime.dart';",
      for (final dep in (importsOf[key] ?? const <String>{}).toList()..sort())
        "import '${moduleOf[dep]!}.dart' as ${moduleOf[dep]!};",
    ];
    final resolved = resolvedOf[key] ?? const <String, _ResolvedCall>{};
    files['$module.dart'] = _DartExporter(
      byPath[key]!,
      sourceName: key,
      asTest: true,
      registerName: 'register',
      extraImports: extra,
      resolveExternalCall: (m) => resolved['${m.sequenceFile}|${m.sequenceName}'],
      externallyCalled: externallyCalledOf[key] ?? const <String>{},
      stationGlobalNames: stationUnion,
      hostStationGlobals: !sharedStation && key == stationOwner,
      stationGlobalsHome: stationHome,
    ).export();
    // Modules that never touch station-wide state don't need the shared
    // runtime import (the placeholder comment deliberately avoids the
    // lowercase identifier so it can't defeat this check).
    files['$module.dart'] = _withoutUnusedImport(
      files['$module.dart']!,
      "import 'lw_runtime.dart';\n",
      RegExp(r'stationGlobals'),
    );
    registers.add(module);
  }

  files['main.dart'] = [
    '// GENERATED by labwright_seq exportSeqProjectToLabwright — the e2e',
    '// entry point: registers every module; labwright runs the suite.',
    for (final module in registers) "import '$module.dart' as $module;",
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
            .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m.group(1)} ${m.group(2)}')
            .replaceAllMapped(RegExp(r'([A-Z]+)([A-Z][a-z])'), (m) => '${m.group(1)} ${m.group(2)}')
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

/// Claims a name derived from [base] that is not yet in [taken] — `base`,
/// then `base2`, `base3`, … — and records it. The ONE suffix-uniquifying
/// routine every generated-name registry uses (top-level names, stub
/// names, per-sequence scope ids, project module names).
String _uniqueName(String base, Set<String> taken) {
  var name = base;
  var n = 2;
  while (!taken.add(name)) {
    name = '$base${n++}';
  }
  return name;
}

/// The top-level identifiers the generator itself occupies — the engine
/// state, the import prefixes, and the harness entry — which no generated
/// sequence/stub name may take. The SINGLE source both the exporter's own
/// registry and the project pre-pass seed from, so the pre-pass can never
/// predict a name the exporter would refuse to mint.
Set<String> _reservedTopLevelNames({required bool asTest, String? registerName}) => {
  'ts',
  'fileGlobals',
  'stationGlobals',
  'runState',
  'step',
  'FileGlobals',
  'StationGlobals',
  if (asTest) ...const {'lw', 'main'},
  if (registerName != null) registerName,
};

/// Sequence name → generated function name for [file], in file order
/// (first declaration wins on duplicate names), claiming through [taken].
/// THE scope table: the exporter assigns its own names with it, and the
/// project pre-pass predicts sibling modules' names with it — one routine,
/// so cross-module bindings cannot drift from the names actually minted.
Map<String, String> _sequenceFnTable(SeqFile file, Set<String> taken) {
  final table = <String, String>{};
  for (final sequence in file.sequences) {
    if (table.containsKey(sequence.name)) continue;
    table[sequence.name] = _uniqueName(dartIdentifier(sequence.name), taken);
  }
  return table;
}

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
    result = result.substring(0, at) + result.substring(at + marker.length, i - 1) + result.substring(i);
    at = result.indexOf(marker);
  }
  return result;
}

/// Splits [text] at every comma that sits at bracket depth ≤ 0 outside
/// string literals — one part means "no top-level comma". Depth carries
/// ACROSS string-literal boundaries: in `f(a + "s"), b` the comma's
/// depth is only correct when the `(` from the first code segment is
/// still counted after the string (review-class bug: per-segment depth
/// read `),` as depth -1 and missed the top-level comma). The ONE
/// comma scanner — `_expr`'s fallback gate and [_rawStmtPieces] share it.
List<String> _splitTopLevelCommas(String text) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  var consumed = 0;
  for (final (segment, isString) in _segments(text)) {
    if (!isString) {
      for (var i = 0; i < segment.length; i++) {
        switch (segment[i]) {
          case '(' || '[' || '{':
            depth++;
          case ')' || ']' || '}':
            depth--;
          case ',':
            if (depth <= 0) {
              parts.add(text.substring(start, consumed + i));
              start = consumed + i + 1;
            }
        }
      }
    }
    consumed += segment.length;
  }
  parts.add(text.substring(start));
  return parts;
}

/// The comma-split raw pieces of a statement expression (comment/
/// NoValidation-stripped), or null when a piece is mis-sliced (quotes/
/// brackets unbalanced) and the whole raw must translate as one.
List<String>? _rawStmtPieces(String raw) {
  final cleaned = _stripNoValidation(_stripComments(raw));
  final parts = _splitTopLevelCommas(cleaned);
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
    return d == 0 && '"'.allMatches(p.replaceAll(r'\"', '')).length.isEven;
  }

  if (parts.length > 1 && !parts.every(balanced)) {
    return null; // a piece mis-sliced — do not split
  }
  return parts;
}

/// The Dart (type, zero-default) for a TestStand value class, or null when
/// the class has no scalar Dart form (containers/refs stay `dynamic` so
/// exported member paths compile via dynamic dispatch — `Object?` would
/// reject `.member` at compile time).
(String, String)? _scalarType(SeqVariable v) => switch (v.raw.className) {
  'Num' => ('double', '0'),
  'Bool' || 'Boolean' => ('bool', 'false'),
  'Str' || 'ExprValue' || 'PathValue' => ('String', "''"),
  _ => null,
};

/// Whether the variable is a TestStand array (`Nums`/`Strs`/`Objs`/
/// `Containers` — any `s`-suffixed array class or an explicit array value).
bool _isArrayVar(SeqVariable v) =>
    v.raw.array != null || const {'Nums', 'Strs', 'Objs', 'Containers'}.contains(v.raw.className);

/// Escapes [s] for a single-quoted generated Dart string literal.
String _escape(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll(r'$', r'\$')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');

/// The initializer for a scalar-typed variable: the declared default when
/// it is a valid literal of the type, else the class zero (with the
/// original kept in a comment by the caller via `_typeComment` — a default
/// that is an expression can't be a Dart initializer).
String _scalarInit(SeqVariable v, String type, String zero) {
  final value = v.value;
  if (value == null) return zero;
  switch (type) {
    case 'int':
      // Only reachable for a refined int candidate — integral by
      // construction ([_refineIntTypes] checked the declared default).
      final i = num.tryParse(value);
      return i == null ? zero : i.toInt().toString();
    case 'double':
      final n = num.tryParse(value);
      if (n == null) return zero; // non-literal default; raw kept in comment
      return _numLiteral(n);
    case 'bool':
      final lower = value.toLowerCase();
      if (lower == 'true') return 'true';
      if (lower == 'false') return 'false';
      return zero; // non-literal default; raw kept in comment
    default:
      return "'${_escape(value)}'";
  }
}

/// The declared Dart type of a stub parameter recovered from a call
/// site's prototype snapshot ('double' | 'bool' | 'String' | 'List' |
/// 'dynamic') — no int refinement (the callee's body is not available
/// to prove integrality).
String _stubParamType(SeqVariable p) {
  final scalar = _scalarType(p);
  if (scalar != null) return scalar.$1;
  return _isArrayVar(p) ? 'List' : 'dynamic';
}

/// A stub parameter declaration from a prototype snapshot: scalars are
/// non-nullable with the snapshot's declared default (or the class zero),
/// arrays nullable, containers `dynamic` — mirroring the sequence
/// parameter shape minus the int refinement and the `??=` preamble (a
/// stub body throws; nothing reads an array default).
String _stubParamDecl(SeqVariable p, String id) {
  final scalar = _scalarType(p);
  if (scalar != null) {
    final (type, zero) = scalar;
    return '$type $id = ${_scalarInit(p, type, zero)}';
  }
  if (_isArrayVar(p)) return 'List<dynamic>? $id';
  return 'dynamic $id';
}

/// Whether a raw TestStand expression is a plain VARIABLE PATH (a
/// writable location — `Locals.X.Y`, `FileGlobals.Z[2]`) rather than a
/// computed value: the shape the engine binds BY REFERENCE into a
/// sequence-call parameter.
bool _isVariablePath(String raw) => RegExp(
  r'^(Locals|Parameters|FileGlobals|StationGlobals|RunState)'
  r'(\.[A-Za-z_][A-Za-z0-9_]*(\[[0-9]+\])?)+$',
  caseSensitive: false,
).hasMatch(raw.trim());

/// One generated stub's accumulated call-site knowledge: the minted
/// function name and, for an external-sequence stub, the parameter
/// surface recovered from the call sites' prototype snapshots
/// (`SData.Prototype` — TestStand copies the callee's parameter list
/// onto each call site) and bound argument rows. The signature renders
/// once every site is seen: TYPED from the snapshot when every site
/// carries the same one (1326/1326 external bound corpus sites carry a
/// prototype; none disagree), else the dynamic name union — so
/// implementing the stub is implementing a real function.
class _StubInfo {
  _StubInfo({
    required this.name,
    required this.isSeq,
    required this.adapter,
    required this.target,
    required this.firstStepName,
  });

  final String name;
  final bool isSeq;
  final String adapter;
  final String target;
  final String firstStepName;

  /// Lowercased parameter name → claimed Dart id, in first-seen order —
  /// the signature's parameter union.
  final Map<String, String> _idOf = {};
  final Set<String> _takenIds = {};

  /// Lowercased name → the FIRST prototype snapshot declaring it (the
  /// typed declaration source).
  final Map<String, SeqVariable> _protoVarOf = {};

  /// The first snapshot's `name|class` list; null until a site carries one.
  List<String>? _protoShape;

  /// Every snapshot matched [_protoShape] and every arg-binding site
  /// carried one — the condition for a TYPED signature (a site that
  /// binds arguments UNTYPED could otherwise pass a value the typed
  /// signature rejects at compile time).
  bool _agree = true;

  bool get typed => _agree && _protoShape != null;

  String _claim(String display) =>
      _idOf.putIfAbsent(display.toLowerCase(), () => _uniqueName(dartIdentifier(display), _takenIds));

  /// Records one call site's parameter knowledge.
  void note(StepModule module) {
    final proto = module.prototypeParameters;
    if (proto.isNotEmpty) {
      final shape = [for (final p in proto) '${p.name.toLowerCase()}|${p.raw.className}'];
      if (_protoShape == null) {
        _protoShape = shape;
      } else if (_protoShape!.join(' ') != shape.join(' ')) {
        _agree = false;
      }
      for (final p in proto) {
        _claim(p.name);
        _protoVarOf.putIfAbsent(p.name.toLowerCase(), () => p);
      }
    } else if (module.sequenceArguments.isNotEmpty) {
      _agree = false; // an arg-binding site with no snapshot: untyped
    }
    for (final a in module.sequenceArguments) {
      _claim(a.name);
    }
  }

  /// The site-local binding table for `_renderCallArgs`: this site's own
  /// snapshot types when it has one — conservative, since the final
  /// signature is either identically typed or loosened to dynamic —
  /// else all-dynamic over the site's own rows.
  Map<String, ({String id, String type})> paramTableFor(StepModule module) {
    final proto = module.prototypeParameters;
    if (proto.isNotEmpty) {
      return {
        for (final p in proto) p.name.toLowerCase(): (id: _idOf[p.name.toLowerCase()]!, type: _stubParamType(p)),
      };
    }
    return {
      for (final a in module.sequenceArguments)
        if (_idOf.containsKey(a.name.toLowerCase()))
          a.name.toLowerCase(): (id: _idOf[a.name.toLowerCase()]!, type: 'dynamic'),
    };
  }

  /// The rendered parameter declarations, in snapshot order when [typed]
  /// (stale bound names were disarmed at their sites and are NOT added
  /// to a typed signature), else the observed union as `dynamic`.
  List<String> signatureDecls() {
    if (!isSeq || _idOf.isEmpty) return const [];
    if (typed) {
      return [
        for (final key in _protoShape!)
          _stubParamDecl(
            _protoVarOf[key.substring(0, key.indexOf('|'))]!,
            _idOf[key.substring(0, key.indexOf('|'))]!,
          ),
      ];
    }
    return [for (final id in _idOf.values) 'dynamic $id'];
  }
}

/// A project-resolved external SequenceCall: the sibling module's
/// `prefix.fn` reference plus that sequence's predicted [_SeqScope]
/// (parameter ids and types — what a bound argument list binds against).
typedef _ResolvedCall = ({String fn, _SeqScope scope});

/// One sequence's generated Dart scope, computed by [_sequenceScopeTable]
/// BEFORE any body emits: the deduplicated declarations, their claimed
/// Dart identifiers, and each identifier's declared type (int refinement
/// applied file-wide). The exporter emits bodies FROM this table, and a
/// call site (same file, or a sibling module predicting it) reads callee
/// parameter ids/types from the SAME table — one routine, so a bound
/// argument can never drift from the signature actually minted.
class _SeqScope {
  _SeqScope({
    required this.emittedParams,
    required this.emittedLocals,
    required this.paramIds,
    required this.localIds,
    required this.idTypes,
    required this.writtenParams,
  });

  /// Declarations that survive dedup (first declaration wins) and the
  /// engine's implicit `ResultList` skip, in source order.
  final List<SeqVariable> emittedParams;
  final List<SeqVariable> emittedLocals;

  /// TestStand name → generated Dart identifier.
  final Map<String, String> paramIds;
  final Map<String, String> localIds;

  /// Generated identifier → its declared Dart type ('double' | 'int' |
  /// 'bool' | 'String' | 'List' | 'dynamic').
  final Map<String, String> idTypes;

  /// Lowercased names of parameters the sequence's own raw expressions
  /// ASSIGN — the callee-side signal for the scalar by-ref writeback
  /// disarm (a variable-path argument bound to a written scalar
  /// parameter would write through in the engine; the export passes
  /// scalars by value).
  final Set<String> writtenParams;

  /// Callee-parameter lookup by lowercased name (engine names are
  /// case-insensitive).
  late final Map<String, String> paramIdOfLower = {
    for (final e in paramIds.entries) e.key.toLowerCase(): e.value,
  };

  /// Every identifier the scope claimed (parameters + locals).
  late final Set<String> allIds = {...paramIds.values, ...localIds.values};
}

/// Builds every sequence's [_SeqScope] for [file] (parallel to
/// `file.sequences`), claiming identifiers against a per-sequence COPY of
/// [taken] (the reserved names + sequence function names — [taken] itself
/// is not mutated), then refines Num types to int FILE-WIDE
/// ([_refineIntTypes], sequence-call bindings included). THE callee-scope
/// table: the exporter emits with it and the project pre-pass predicts
/// sibling modules' signatures with it. [sourceName] is the file's own
/// path (local-call resolution).
List<_SeqScope> _sequenceScopeTable(SeqFile file, Set<String> taken, {String? sourceName}) {
  final scopes = <_SeqScope>[];
  for (final sequence in file.sequences) {
    final used = <String>{...taken};
    final seenParams = <String>{};
    final emittedParams = [
      for (final p in sequence.parameters)
        if (seenParams.add(p.name)) p, // duplicate names in source: first wins
    ];
    final paramIds = {for (final p in emittedParams) p.name: _uniqueName(dartIdentifier(p.name), used)};
    final seenLocals = <String>{};
    final emittedLocals = [
      for (final local in sequence.locals)
        // ResultList is the engine's implicit result bookkeeping, not user
        // state — skipped (a reference to it falls back to _eval).
        if (local.name != 'ResultList' && seenLocals.add(local.name)) local,
    ];
    final localIds = {for (final l in emittedLocals) l.name: _uniqueName(dartIdentifier(l.name), used)};
    String typeOf(SeqVariable v) {
      final scalar = _scalarType(v);
      if (scalar != null) return scalar.$1;
      return _isArrayVar(v) ? 'List' : 'dynamic';
    }

    scopes.add(
      _SeqScope(
        emittedParams: emittedParams,
        emittedLocals: emittedLocals,
        paramIds: paramIds,
        localIds: localIds,
        idTypes: {
          for (final p in emittedParams) paramIds[p.name]!: typeOf(p),
          for (final l in emittedLocals) localIds[l.name]!: typeOf(l),
        },
        writtenParams: _writtenParameterNames(sequence),
      ),
    );
  }
  _refineIntTypes(file, scopes, sourceName);
  return scopes;
}

/// The lowercased parameter names [sequence]'s raw expressions assign
/// (`Parameters.X = …`, compound assigns included), across every stored
/// expression position. Only a DIRECT scalar assignment counts: a member
/// or element write (`Parameters.X.Y = …`, `Parameters.X[0] = …`) mutates
/// an object/array the export already passes by identity.
Set<String> _writtenParameterNames(Sequence sequence) {
  final names = <String>{};
  final re = RegExp(r'Parameters\.([A-Za-z_][A-Za-z0-9_]*)\s*([-+*/]?=)(?!=)', caseSensitive: false);
  void scan(String? raw) {
    if (raw == null) return;
    for (final m in re.allMatches(raw)) {
      names.add(m.group(1)!.toLowerCase());
    }
  }

  for (final step in sequence.steps) {
    scan(step.settings.precondition);
    scan(step.settings.preExpression);
    scan(step.settings.postExpression);
    scan(step.settings.statusExpression);
    scan(step.timeoutExpression);
    scan(step.waitTimeExpression);
    final flow = step.flowControl;
    if (flow != null) {
      scan(flow.condition);
      scan(flow.initialization);
      scan(flow.increment);
      scan(flow.arrayExpr);
      scan(flow.itemExpression);
      scan(flow.arrayElement);
    }
  }
  return names;
}

/// TestStand Num is a double, but a Num the author uses as a counter or
/// index is an `int` to any Dart reader (`num` would be an anti-pattern
/// and `double index` reads wrong). Refines each scope's `idTypes` double
/// → int for a Num local/param whose declared default is integral and
/// whose every raw assignment keeps it integral: RHS built ONLY of
/// integer literals (dec/hex), other int-candidate Locals/Parameters
/// refs, and `+ - *` — anything else (division, function calls, engine
/// paths, non-integral literals) demotes to double. Sequence-CALL
/// bindings participate as assigns too (callee parameter ← argument
/// expression, the RHS read in the CALLER's scope): a parameter bound a
/// non-integral argument anywhere in the file demotes, and a caller's
/// candidate bound into a stay-double parameter demotes as well (Dart
/// does not widen an int EXPRESSION to double) — so a call site can pass
/// the translated argument straight through. Iterated to fixpoint;
/// ForEach element targets demote (element types are not pinned). Purely
/// conservative: a miss just keeps double.
void _refineIntTypes(SeqFile file, List<_SeqScope> scopes, String? sourceName) {
  bool integralDefault(SeqVariable v) {
    final value = v.value;
    if (value == null) return true; // class zero (0)
    final n = num.tryParse(value);
    return n != null && n % 1 == 0 && n.abs() < _maxExactIntDouble;
  }

  final candidates = <(_SeqScope, String)>{};
  for (final scope in scopes) {
    void seed(List<SeqVariable> list, Map<String, String> ids) {
      for (final v in list) {
        final id = ids[v.name];
        if (id != null && scope.idTypes[id] == 'double' && integralDefault(v)) {
          candidates.add((scope, id));
        }
      }
    }

    seed(scope.emittedParams, scope.paramIds);
    seed(scope.emittedLocals, scope.localIds);
  }
  if (candidates.isEmpty) return;

  // Callee lookup by name — first declaration wins, matching the
  // function-name table.
  final scopeByName = <String, _SeqScope>{};
  for (var i = 0; i < scopes.length; i++) {
    scopeByName.putIfAbsent(file.sequences[i].name, () => scopes[i]);
  }

  String? idOf(_SeqScope s, String root, String name) =>
      root.toLowerCase() == 'locals' ? s.localIds[name] : s.paramIds[name];

  final refRe = RegExp(r'(Locals|Parameters)\.([A-Za-z_][A-Za-z0-9_]*)', caseSensitive: false);
  // (target scope, target id, raw RHS, scope the RHS reads in); a null
  // RHS is an unconditional demotion.
  final assigns = <(_SeqScope, String, String?, _SeqScope)>[];
  final assignRe = RegExp(
    r'^\s*(Locals|Parameters)\.([A-Za-z_][A-Za-z0-9_]*)'
    r'\s*([-+*/]?=)(?!=)\s*(.*)$',
    caseSensitive: false,
    dotAll: true,
  );
  for (var i = 0; i < scopes.length; i++) {
    final scope = scopes[i];
    void scan(String? raw) {
      if (raw == null) return;
      for (final piece in _rawStmtPieces(raw) ?? [raw]) {
        final m = assignRe.firstMatch(piece);
        if (m == null) continue;
        final id = idOf(scope, m.group(1)!, m.group(2)!);
        if (id == null) continue;
        assigns.add((scope, id, m.group(3) == '/=' ? null : m.group(4)!, scope));
      }
    }

    for (final step in file.sequences[i].steps) {
      scan(step.settings.preExpression);
      scan(step.settings.postExpression);
      final flow = step.flowControl;
      if (flow != null) {
        scan(flow.initialization);
        scan(flow.increment);
        final element = flow.arrayElement;
        if (element != null) {
          final m = refRe.firstMatch(element);
          final id = m != null ? idOf(scope, m.group(1)!, m.group(2)!) : null;
          if (id != null) candidates.remove((scope, id));
        }
      }
      // Sequence-call bindings: callee parameter ← argument expression.
      final module = step.module;
      if (module.adapter == SeqAdapter.sequenceCall &&
          module.specifiesByExpression != true &&
          module.resolvesLocalCall(ownFilePath: sourceName)) {
        final callee = scopeByName[module.sequenceName];
        if (callee == null) continue;
        for (final arg in module.sequenceArguments) {
          if (arg.usesDefault == true) continue;
          final expr = arg.expression;
          final id = callee.paramIdOfLower[arg.name.toLowerCase()];
          if (expr == null || id == null) continue;
          assigns.add((callee, id, expr, scope));
        }
      }
    }
  }

  bool intExpr(String rhs, _SeqScope reader) {
    for (final m in refRe.allMatches(rhs)) {
      final id = idOf(reader, m.group(1)!, m.group(2)!);
      if (id == null || !candidates.contains((reader, id))) return false;
    }
    final rest = rhs.replaceAll(refRe, '0');
    return rest.trim().isNotEmpty && RegExp(r'^(?:\s|[()+\-*]|0x[0-9A-Fa-f]+|\d+(?![\d.eE]))+$').hasMatch(rest);
  }

  var changed = true;
  while (changed) {
    changed = false;
    for (final (target, id, rhs, reader) in assigns) {
      if (candidates.contains((target, id))) {
        if (rhs == null || !intExpr(rhs, reader)) {
          candidates.remove((target, id));
          changed = true;
        }
      } else if (target.idTypes[id] == 'double' && rhs != null) {
        // A double target with an int-typed RHS would not compile —
        // unless the RHS is a bare literal (Dart types a literal by
        // context). Demote the RHS's candidate refs.
        final refs = [
          for (final m in refRe.allMatches(rhs)) idOf(reader, m.group(1)!, m.group(2)!),
        ].whereType<String>();
        if (refs.isNotEmpty && intExpr(rhs, reader)) {
          for (final ref in refs) {
            if (candidates.remove((reader, ref))) changed = true;
          }
        }
      }
    }
  }
  for (final (scope, id) in candidates) {
    scope.idTypes[id] = 'int';
  }
}

/// Drops [importLine] from [source] when nothing else in it matches
/// [usage] — a generated file must not carry analyzer-noise imports.
String _withoutUnusedImport(String source, String importLine, RegExp usage) {
  final stripped = source.replaceFirst(importLine, '');
  return usage.hasMatch(stripped) ? source : stripped;
}

/// 2^53 — the largest magnitude below which every integer is exactly
/// representable as a double. An integral value at or past it cannot be
/// emitted as a Dart int literal in a double context without silent
/// precision loss, so numeric-literal emission switches to the double
/// form there.
const int _maxExactIntDouble = 9007199254740992;

/// The Dart literal for a parsed TestStand Num in a double-typed position:
/// the int form while exactly representable (reads like the source), else
/// the double form.
String _numLiteral(num n) => n is int && n.abs() < _maxExactIntDouble ? n.toString() : n.toDouble().toString();

/// Text destined for a `//` comment: newlines flattened so nothing spills
/// out of the comment onto a code line.
String _comment(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' | ').trim();

/// The in-class placeholder for a global whose name cannot be a Dart
/// field ([_validGlobalFieldName] fails) — present, stated, reachable only
/// by porting its uses. Deliberately avoids the lowercase struct
/// identifiers so it cannot defeat the unused-import checks.
String _unportableFieldLine(String name) =>
    '// not a Dart field name — reachable only by porting its uses: ${_comment(name)}';

/// Whether a global's name can be a generated struct FIELD — a valid
/// Dart identifier that collides with nothing structural. Names that
/// fail stay accessible only through eval fallback (stated in the class).
bool _validGlobalFieldName(String name) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name) &&
    !_dartReserved.contains(name) &&
    !const {
      'toString',
      'hashCode',
      'runtimeType',
      'noSuchMethod',
      'FileGlobals',
      'StationGlobals',
      'ts',
      'lw',
    }.contains(name);

/// The level-1 member names a file's expressions touch on StationGlobals
/// — the observed surface the generated struct declares. Root matching is
/// case-insensitive (engine names are); call-position names (methods,
/// which a struct field cannot host) are excluded.
Set<String> _collectStationGlobalRefs(SeqFile file) {
  final names = <String>{};
  final re = RegExp(r'StationGlobals\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)(\s*\()?', caseSensitive: false);
  void scan(String? raw) {
    if (raw == null) return;
    for (final m in re.allMatches(raw)) {
      if (m.group(2) == null) names.add(m.group(1)!);
    }
  }

  for (final seq in file.sequences) {
    for (final step in seq.steps) {
      scan(step.settings.precondition);
      scan(step.settings.preExpression);
      scan(step.settings.postExpression);
      scan(step.settings.statusExpression);
      scan(step.timeoutExpression);
      scan(step.waitTimeExpression);
      final flow = step.flowControl;
      if (flow != null) {
        scan(flow.condition);
        scan(flow.initialization);
        scan(flow.increment);
        scan(flow.arrayExpr);
        scan(flow.itemExpression);
        scan(flow.arrayElement);
      }
    }
  }
  return names;
}

/// The TestStand variable roots the translator rewrites. `FileGlobals`/
/// `StationGlobals`/`RunState`/`Step` map to generated top-level state
/// (member paths resolve by dynamic dispatch); `Locals`/`Parameters`
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
final _dartSafeExpression = RegExp(r"^[A-Za-z0-9_.\s+\-*/!<>=&|(),'\x22\[\]]+$");

/// TestStand built-ins the exporter translates to generated top-level
/// helper functions (chosen from corpus frequency: these cover the bulk of
/// the `_eval` fallbacks). Each helper implements the common arity and
/// throws [UnimplementedError] for the engine-specific forms, so the
/// generated code always compiles and never silently changes semantics.
const _builtinCalls = {
  'Len': 'ts.len',
  'GetNumElements': 'ts.getNumElements',
  'SetNumElements': 'ts.setNumElements',
  'Str': 'ts.str',
  'Left': 'ts.left',
  'Right': 'ts.right',
  'Mid': 'ts.mid',
  'Find': 'ts.find',
  // 'Random' is handled per mode: lw.rand in suite mode (draws from the
  // labwright seed so runs reproduce), ts.rand in plain mode.
};

/// Constructs that force the `_eval` fallback even when the charset looks
/// safe: any function-style call that is NOT a rewritten helper call
/// (TestStand's built-in library is large; only [_builtinCalls] are
/// translated), plus engine-only operators. Parenthesized grouping
/// (`(a || b)`) is fine — only `identifier(` marks a call; the rewritten
/// `_helper(` calls are exempted by the leading underscore.
final _testStandOnly = RegExp(r'(?<!\.)\b[A-Za-z][A-Za-z0-9_]*\s*\(|#|->');

/// One open flow block during step emission: its kind plus the state its
/// closer needs — the For increment (emitted before `}` and before
/// `continue`), the Do-While condition, and the Select label id.
typedef _OpenBlock = ({FlowKind kind, String? increment, String? condition, int selectId});

/// An [_OpenBlock] with only the state its [kind] actually carries.
_OpenBlock _openBlock(FlowKind kind, {String? increment, String? condition, int selectId = 0}) =>
    (kind: kind, increment: increment, condition: condition, selectId: selectId);

class _DartExporter {
  _DartExporter(
    this.file, {
    this.sourceName,
    this.asTest = false,
    this.registerName,
    this.extraImports = const [],
    this.resolveExternalCall,
    this.externallyCalled = const {},
    this.stationGlobalNames = const {},
    this.hostStationGlobals = true,
    this.stationGlobalsHome = 'lw_runtime.dart',
    SeqExportStats? stats,
  }) : _stats = stats ?? SeqExportStats();

  /// Call-parameter translation counters (see [SeqExportStats]).
  final SeqExportStats _stats;

  /// Globals plumbing: [stationGlobalNames] is the observed StationGlobals
  /// level-1 surface (a project passes the cross-module union; empty means
  /// self-collect); [hostStationGlobals] says whether THIS file declares
  /// the struct + instance (a project hosts shared state once);
  /// [stationGlobalsHome] names where it lives when not hosted here.
  final Set<String> stationGlobalNames;
  final bool hostStationGlobals;
  final String stationGlobalsHome;

  /// PROJECT mode (multi-file export): the module exposes
  /// `void <registerName>()` instead of `main()`, [extraImports] lines
  /// (the shared runtime + prefixed sibling modules) follow the header,
  /// [resolveExternalCall] binds an external SequenceCall to a sibling
  /// module's `prefix.fn` (null → today's stub), and sequences in
  /// [externallyCalled] are not roots (another module calls them).
  final String? registerName;
  final List<String> extraImports;
  final _ResolvedCall? Function(StepModule module)? resolveExternalCall;
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

  /// Every identifier claimed in the current sequence's scope (locals,
  /// params, engine/state names) — emission-time names (loop elements,
  /// select scratch vars) claim through here so nothing shadows.
  Set<String> _usedIds = {};

  /// Claims an emission-time identifier in the current sequence's scope.
  String _claimId(String base) => _uniqueName(base, _usedIds);

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

  /// stub key (adapter + target) → the stub's accumulated info: minted
  /// function name plus, for external-sequence stubs, the parameter
  /// surface gathered from every call site ([_StubInfo]). Declarations
  /// render in [_emitStubs] AFTER all sites are seen, so the signature
  /// reflects the whole file.
  final Map<String, _StubInfo> _stubs = {};

  /// Step-type name → the TYPE's default precondition (`<Type>.TS.PreCond`).
  /// A custom step type can carry the condition its instances inherit —
  /// corpus: NI_Flow_Break_Custom's "break on terminate" gate (29 sites),
  /// which made every such break read as unconditional dead code. An
  /// instance with its own PreCond overrides; one that CLEARED the type's
  /// default to empty is indistinguishable from inheritance in the text
  /// form (empty collapses to null) — none exist in the corpus.
  late final Map<String, String> _typePreconditions = {
    for (final t in file.typeDefs)
      if ((t.raw.prop('TS')?.prop('PreCond')?.scalar ?? '').isNotEmpty)
        t.name: t.raw.prop('TS')!.prop('PreCond')!.scalar!,
  };

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
    RegExp(r'ts\.(?:eval|cond)\('): 'untranslated expression in body',
    RegExp(r'(?<![\w\$.])runState(?![\w\$])'): 'RunState engine access (no engine at run time)',
    RegExp(r'(?<![\w\$.])step\.'): 'Step engine access (no engine at run time)',
  };

  /// StationGlobals is station-level state the file does not declare — a
  /// WRITE works on the shared bag, but a READ depends on values only the
  /// station (or another module's run order) provides. FileGlobals now
  /// carries the file's own declared defaults, so accessing it is real
  /// data and no longer a hazard at all.
  static final _stationWrite = RegExp(r'(?<![\w\$.])stationGlobals\.\w+\s*=(?![=])');
  static final _stationAccess = RegExp(r'(?<![\w\$.])stationGlobals\.');

  void _scanHazards(String text) {
    if (_currentSeq == null) return;
    for (final entry in _hazards.entries) {
      if (entry.key.hasMatch(text)) _markUnported(entry.value);
    }
    if (_stationAccess.hasMatch(text.replaceAll(_stationWrite, ''))) {
      _markUnported('StationGlobals read (station-level state not set here)');
    }
  }

  /// Claims a unique top-level identifier derived from [base], also
  /// steering clear of every sequence-scope identifier — a stub named
  /// like some sequence's local/parameter would be shadowed inside that
  /// sequence and the generated call would not compile.
  String _uniqueTopLevel(String base) {
    var name = _uniqueName(base, _topLevelNames);
    while (_allScopeIds.contains(name)) {
      name = _uniqueName(base, _topLevelNames);
    }
    return name;
  }

  /// Per-sequence generated scopes (parallel to `file.sequences`), the
  /// first-declaration-wins name view (callee lookup), and the union of
  /// every scope-claimed identifier (stub names must avoid them — a
  /// local named like a stub would shadow the stub it calls).
  late final List<_SeqScope> _scopes;
  late final Map<String, _SeqScope> _scopeByName;
  late final Set<String> _allScopeIds;

  String export() {
    _topLevelNames.addAll(_reservedTopLevelNames(asTest: asTest, registerName: registerName));
    _buildGlobals();
    _emitHeader();
    _sequenceFnNames.addAll(_sequenceFnTable(file, _topLevelNames));
    _scopes = _sequenceScopeTable(file, _topLevelNames, sourceName: sourceName);
    _scopeByName = {};
    for (var i = 0; i < file.sequences.length; i++) {
      _scopeByName.putIfAbsent(file.sequences[i].name, () => _scopes[i]);
    }
    _allScopeIds = {for (final scope in _scopes) ...scope.allIds};
    for (var i = 0; i < file.sequences.length; i++) {
      _emitSequence(file.sequences[i], _scopes[i]);
    }
    _emitStubs();
    _emitRuntime();
    if (asTest) _emitTestMain();
    var source = _out.toString();
    // A near-empty file may end up referencing neither `lw` (no sequences
    // → no tests) nor `ts` (no untranslated expressions, no structured
    // state) — either import would be the only analyzer noise in it.
    for (final (prefix, import) in const [
      ('lw', "import 'package:labwright/labwright.dart' as lw;\n"),
      ('ts', "import 'package:labwright/shims.dart' as ts;\n"),
    ]) {
      source = _withoutUnusedImport(source, import, RegExp('(?<![\\w\\\$.])$prefix\\.'));
    }
    return source;
  }

  void _emitHeader() {
    _out
      ..writeln(
        '// GENERATED by labwright_seq '
        '${asTest ? 'exportSeqFileToLabwright' : 'exportSeqFileToDart'}'
        '${sourceName != null ? ' from ${_comment(sourceName!)}' : ''}.',
      )
      ..writeln('//')
      ..writeln(
        '// Sequence logic is exported as idiomatic Dart: typed '
        'locals, real control',
      )
      ..writeln(
        '// flow, native waits, and direct function calls. '
        'Code-module calls and',
      )
      ..writeln(
        '// external sequences are stubs; expressions beyond '
        'mechanical translation',
      )
      ..writeln(
        '// are kept verbatim in eval(...) shim calls. Nothing is '
        'fabricated: unexportable',
      )
      ..writeln(
        '// steps remain as ordered comments. The shim library '
        '(package:labwright/shims.dart,',
      )
      ..writeln(
        '// imported as ts) hosts the engine built-ins and the '
        'PropObj variable model.',
      )
      ..writeln(
        '// ignore_for_file: unused_local_variable, dead_code, '
        'unused_element, unused_label, non_constant_identifier_names',
      )
      ..writeln();
    if (asTest) {
      _out.writeln("import 'package:labwright/labwright.dart' as lw;");
    }
    _out.writeln("import 'package:labwright/shims.dart' as ts;");
    for (final line in extraImports) {
      _out.writeln(line);
    }
    _out.writeln();
  }

  // ── expressions ────────────────────────────────────────────────────────────

  /// Translates a TestStand expression to Dart, or wraps it in `_eval`.
  String _expr(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return "''";
    trimmed = _stripNoValidation(_stripComments(trimmed)).trim();
    if (trimmed.isEmpty) return "''";

    // A top-level comma is C-heritage sequential evaluation — no single
    // Dart EXPRESSION form (statement position splits it; see _stmtParts).
    if (_splitTopLevelCommas(trimmed).length > 1) return _evalFallback(raw);

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
      for (final m in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\.').allMatches(code)) {
        final precededByDot = m.start > 0 && code.substring(m.start - 1, m.start) == '.';
        final root = m.group(1)!;
        if (!precededByDot && !_variableRoots.containsKey(root) && root != 'Locals' && root != 'Parameters') {
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
            return segments.length == 1 ? id : '$id.${segments.sublist(1).join('.')}';
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
      // Globals are typed STRUCTS: a level-1 member must be a declared
      // field (rewritten to its declared casing — engine names are
      // case-insensitive), and only a `dynamic` field can sit in call
      // position. Anything else keeps engine semantics via eval.
      var unknownGlobal = false;
      code = code.replaceAllMapped(
        RegExp(
          r'\b(fileGlobals|stationGlobals)\.'
          r'([A-Za-z_][A-Za-z0-9_]*)(\s*\()?',
        ),
        (m) {
          final isFile = m.group(1) == 'fileGlobals';
          final declared = (isFile ? _fileGlobalCanon : _stationGlobalCanon)[m.group(2)!.toLowerCase()];
          final call = m.group(3);
          final type = declared == null ? null : (isFile ? _fileGlobalTypes[declared] : 'dynamic');
          if (declared == null || (call != null && type != 'dynamic')) {
            unknownGlobal = true;
            return m.group(0)!;
          }
          return '${m.group(1)}.$declared${call ?? ''}';
        },
      );
      if (unknownGlobal) return _evalFallback(raw);
      // Translate the catalogued TestStand built-ins to ts.* method calls
      // (not preceded by a dot — a member path stays a member path).
      for (final entry in {
        ..._builtinCalls,
        'Random': asTest ? 'lw.rand' : 'ts.rand',
      }.entries) {
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
      if (!_dartSafeExpression.hasMatch(code) || _testStandOnly.hasMatch(code)) {
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
      for (final m in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\.[A-Za-z_][A-Za-z0-9_.]*\s*\(').allMatches(code)) {
        if (_idTypes.containsKey(m.group(1)) && _idTypes[m.group(1)] != 'dynamic') {
          return _evalFallback(raw);
        }
      }
      // A double-typed variable used as a LIST SUBSCRIPT cannot compile
      // (Dart indexes with int) and truncation vs rounding is a TestStand
      // semantic we have not pinned — keep via eval.
      for (final m in RegExp(r'\[([^\[\]]*)\]').allMatches(code)) {
        for (final idm in RegExp(r'[A-Za-z_][A-Za-z0-9_]*').allMatches(m.group(1)!)) {
          if (_idTypes[idm.group(0)] == 'double') return _evalFallback(raw);
        }
      }
      // Any bare identifier that survived rewriting must be a name the
      // generated scope actually declares — otherwise it is a TestStand
      // constant (Nothing, NAN, INF, ...) that would not compile.
      const knownBare = {
        'true',
        'false',
        'null',
        'ts',
        'lw',
        'fileGlobals',
        'stationGlobals',
        'runState',
        'step',
      };
      const generatedName = '__LWELEMENT__';
      final codeSansKeys = code.replaceAll(RegExp(r"'[^']*'"), '');
      for (final m in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\b').allMatches(codeSansKeys)) {
        final id = m.group(1)!;
        final precededByDot = m.start > 0 && codeSansKeys.substring(m.start - 1, m.start) == '.';
        if (precededByDot) continue;
        if (!knownBare.contains(id) &&
            id != generatedName &&
            !_localIds.containsValue(id) &&
            !_paramIds.containsValue(id)) {
          return _evalFallback(raw);
        }
      }
      rebuilt.write(code);
    }
    return rebuilt.toString();
  }

  String _evalFallback(String raw) => "ts.eval('${_escape(raw)}')";

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
    // The untranslated-condition case gets its OWN shim (`ts.cond`, typed
    // bool) instead of the doubly-wrapped truthy(eval(…)).
    if (e.startsWith('ts.eval(')) return 'ts.cond${e.substring(7)}';
    if (_staticallyBool(e)) return e;
    if (_idTypes[e] == 'double' || _idTypes[e] == 'int') return '$e != 0';
    return 'ts.truthy($e)';
  }

  bool _staticallyBool(String e) {
    if (e.startsWith('ts.eval(')) return false;
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
        if ((c == '=' || c == '!') && i + 1 < segment.length && segment[i + 1] == '=') {
          topOp ??= '==';
        }
        if (c == '<' || c == '>') topOp ??= '<';
      }
    }
    if (topOp == '==') return true; // Object.== is declared bool
    if (topOp == '<') {
      // Ordering operators are provably bool only on a typed receiver:
      // a numeric/string literal or a typed local/param leading the LHS.
      final lead = RegExp(r'^\(?\s*([A-Za-z_][A-Za-z0-9_]*|[0-9.]+)').firstMatch(e)?.group(1);
      if (lead == null) return false;
      if (RegExp(r'^[0-9.]').hasMatch(lead)) return true;
      final t = _idTypes[lead];
      return t == 'double' || t == 'int' || t == 'bool' || t == 'String';
    }
    return false;
  }

  // ── sequences ──────────────────────────────────────────────────────────────

  void _emitSequence(Sequence sequence, _SeqScope scope) {
    final fnName = _sequenceFnNames[sequence.name]!;
    _out.writeln(
      '/// Sequence `${_comment(sequence.name)}`'
      '${sequence.comment != null ? ' — ${_comment(sequence.comment!)}' : ''}.',
    );

    _currentSeq = sequence.name;
    // The sequence's scope comes precomputed ([_sequenceScopeTable]):
    // identifiers unique within the function and clear of the generated
    // top-level names (state globals, sequence functions, stubs) — a
    // local named like a sequence would otherwise shadow the function it
    // calls. Emission-time scratch names ([_claimId]) claim through the
    // merged view.
    _usedIds = <String>{..._topLevelNames, ...scope.allIds};
    final emittedParams = scope.emittedParams;
    _paramIds = scope.paramIds;
    final emittedLocals = scope.emittedLocals;
    _localIds = scope.localIds;
    _idTypes = scope.idTypes;

    // Parameters: typed where the class is scalar. Scalars with a declared
    // default are non-nullable; containers are `dynamic` so exported member
    // paths (Parameters.Result.Status) still compile via dynamic dispatch.
    final params = [
      for (final p in emittedParams) _paramDecl(p, _paramIds[p.name]!),
    ];
    _out.writeln(
      'Future<void> $fnName('
      '${params.isEmpty ? '' : '{${params.join(', ')}}'}) async {',
    );
    _indent = 1;

    // Array parameters are declared nullable (a Dart named-parameter
    // default must be const, and a shared const list would alias across
    // calls and throw on element writes) — the `??=` preamble gives an
    // omitted argument the sequence's DECLARED default, mutable and
    // per-call, exactly like a local's initializer.
    var arrayPreamble = false;
    for (final p in emittedParams) {
      if (_scalarType(p) == null && _isArrayVar(p)) {
        _line('${_paramIds[p.name]!} ??= ${_arrayInit(p)};${_typeComment(p)}');
        arrayPreamble = true;
      }
    }
    if (arrayPreamble) _line('');

    // Locals: real typed Dart declarations, defaults from the sequence file
    // (TestStand's declared defaults) or the class zero.
    for (final local in emittedLocals) {
      _line(_localDecl(local, _localIds[local.name]!));
    }
    if (emittedLocals.isNotEmpty) _line('');

    // Group banners earn their lines only when there is more than one
    // group to tell apart; an empty sequence states that it is empty in
    // the SOURCE (a real template hook), not a translation failure.
    final nonEmptyGroups = [
      for (final g in StepGroup.values)
        if (sequence.stepsIn(g).isNotEmpty) g,
    ];
    if (nonEmptyGroups.isEmpty) {
      _line('// (no steps in the source sequence)');
      _line('');
    }
    for (final group in nonEmptyGroups) {
      if (nonEmptyGroups.length > 1) _line('// ── ${group.name} ──');
      _emitSteps(sequence.stepsIn(group));
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

  /// The (type, class zero, initializer) of a scalar-typed declaration for
  /// [v] emitted as [id] — the class scalar type with the int refinement
  /// ([_refineIntTypes], recorded in `_idTypes`) applied. null when [v] has
  /// no scalar Dart form; [_paramDecl] and [_localDecl] share it.
  (String, String, String)? _scalarDecl(SeqVariable v, String id) {
    final scalar = _scalarType(v);
    if (scalar == null) return null;
    var (type, zero) = scalar;
    if (type == 'double' && _idTypes[id] == 'int') type = 'int';
    return (type, zero, _scalarInit(v, type, zero));
  }

  /// A typed named-parameter declaration. Scalars are non-nullable with the
  /// declared default (or the class zero — TestStand parameters always have
  /// a default); arrays are nullable (their declared default is not const —
  /// the body's `??=` preamble materializes it); containers are `dynamic`.
  String _paramDecl(SeqVariable p, String id) {
    final scalar = _scalarDecl(p, id);
    if (scalar != null) {
      final (type, _, init) = scalar;
      return '$type $id = $init';
    }
    if (_isArrayVar(p)) return 'List<dynamic>? $id';
    return 'dynamic $id';
  }

  /// A typed local declaration line: `double loopIndex = 0; // Num`.
  String _localDecl(SeqVariable local, String id) {
    final scalar = _scalarDecl(local, id);
    if (scalar != null) {
      final (type, zero, init) = scalar;
      // A non-literal declared default (expression, NAN, …) initializes to
      // the class zero — the raw text rides in the comment, never dropped.
      final fellBack = local.value != null && init == zero && type != 'String';
      return '$type $id = $init;'
          '${_typeComment(local, rawDefault: fellBack ? local.value : null)}';
    }
    if (_isArrayVar(local)) {
      return 'List<dynamic> $id = ${_arrayInit(local)};${_typeComment(local)}';
    }
    // A structured container (Obj / typed) local carries its declared
    // default structure — a plain reference (Ref) genuinely starts null.
    final cls = local.raw.className;
    if (cls == 'Ref' || (cls == null && local.raw.subProps.isEmpty)) {
      return 'dynamic $id;${_typeComment(local)}';
    }
    return 'dynamic $id = ${_propObjInit(local.raw, {})};'
        '${_typeComment(local)}';
  }

  /// An array local's initializer / an array parameter's `??=` default:
  /// the DECLARED default elements (TestStand pre-fills sized arrays — an
  /// empty list here would make count-driven loops silently run zero times
  /// where the engine runs N). Scalars come from each element's stored
  /// value or the element-class zero; nested arrays/objects fall back to
  /// null placeholders of the right LENGTH.
  String _arrayInit(SeqVariable v) => _listInit(v.raw, {});

  // ── steps ──────────────────────────────────────────────────────────────────

  void _emitSteps(List<Step> steps) {
    // Block stack: each opener records its kind plus the state its closer
    // needs — the For increment (emitted before `}` and before `continue`),
    // the Do-While condition, and the Select label id.
    final open = <_OpenBlock>[];
    var selectCounter = 0;
    final selectVars = <int, ({String value, String matched})>{};
    const loopKinds = {
      FlowKind.whileLoop,
      FlowKind.doWhile,
      FlowKind.forLoop,
      FlowKind.forEach,
    };

    _OpenBlock? innermost(bool Function(FlowKind) test) {
      for (var i = open.length - 1; i >= 0; i--) {
        if (test(open[i].kind)) return open[i];
      }
      return null;
    }

    void closeBlock(_OpenBlock opened, {String note = ''}) {
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
      'If',
      'Else',
      'Else If',
      'While',
      'Do While',
      'For',
      'For Each',
      'Select',
      'Case',
      'End',
      'Break',
      'Continue',
      'Statement',
      'Goto',
    };
    for (final step in steps) {
      final flow = step.flowControl;
      final rawName = _comment(step.name);
      // The step's author-written comment is real human content — always
      // kept, above the step it documents.
      final authorComment = step.comment;
      if (authorComment != null) {
        for (final line in authorComment.split('\n')) {
          _line('// ${_comment(line)}');
        }
      }
      // Run mode: a Skip/force-pass step does not run its action in the
      // engine — emitting active code for it would fabricate behavior the
      // author disabled (a template's skipped `break`/`wait` placeholders
      // read as live dead code). A STRUCTURAL flow step in a non-normal
      // mode keeps its block (balance is not negotiable), is annotated,
      // and disarms the owning test: skipped-flow semantics are not
      // pinned. A force-fail's status effect is not exported — stated.
      final mode = step.settings.mode;
      var modeNote = '';
      if (!step.settings.isNormalMode) {
        final structural = flow != null && flow.kind != FlowKind.breakStmt && flow.kind != FlowKind.continueStmt;
        if (!structural) {
          if (mode == 'Fail' && asTest) {
            _markUnported(
              'force-fail step "${step.name}" '
              '(status semantics not exported)',
            );
          }
          final what = switch (mode) {
            'Skip' => 'skipped',
            'Pass' => 'force-pass',
            'Fail' => 'force-fail',
            _ => 'mode $mode',
          };
          _line('// [$what in source] $rawName');
          continue;
        }
        if (asTest) {
          _markUnported(
            'flow step "${step.name}" is $mode in source '
            '(skipped flow semantics not pinned)',
          );
        }
        modeNote = ' [$mode in source]';
      }
      // A flow step named by its default TestStand name duplicates the
      // emitted keyword (`} // End`, `{ // If`) — suppressed; a CUSTOM
      // name stays (it is documentation).
      var nameNote = defaultFlowNames.contains(rawName) ? '' : ' // $rawName';
      if (modeNote.isNotEmpty) {
        nameNote = nameNote.isEmpty ? ' //$modeNote' : '$nameNote$modeNote';
      }
      if (flow == null) {
        _emitPlainStep(step);
        continue;
      }
      switch (flow.kind) {
        case FlowKind.ifBlock:
          _line('if (${_cond(flow.condition ?? 'true')}) {$nameNote');
          _indent++;
          open.add(_openBlock(flow.kind));
        case FlowKind.elseIf:
          if (open.isEmpty || open.last.kind != FlowKind.ifBlock) {
            _line(
              '// $rawName: Else-If without an open If (unbalanced source) — '
              'kept as a comment',
            );
            continue;
          }
          _indent--;
          _line(
            '} else if (${_cond(flow.condition ?? 'true')}) '
            '{$nameNote',
          );
          _indent++;
        case FlowKind.elseBlock:
          if (open.isEmpty || open.last.kind != FlowKind.ifBlock) {
            _line(
              '// $rawName: Else without an open If (unbalanced source) — '
              'kept as a comment',
            );
            continue;
          }
          _indent--;
          _line('} else {$nameNote');
          _indent++;
        case FlowKind.whileLoop:
          _line(
            'while (${_cond(flow.condition ?? 'true')}) '
            '{$nameNote',
          );
          _indent++;
          open.add(_openBlock(flow.kind));
        case FlowKind.doWhile:
          _line('do {$nameNote');
          _indent++;
          open.add(_openBlock(flow.kind, condition: flow.condition ?? 'true'));
        case FlowKind.forLoop:
          final init = flow.initialization;
          final initDart = init != null ? _exprStatement(init) : null;
          final incrDart = flow.increment != null ? _exprStatement(flow.increment!) : null;
          // A real Dart `for` when init and increment both translate
          // mechanically: the increment then runs on `continue` natively,
          // eliminating the re-emit-before-continue pattern (and its
          // missed-increment bug class). Otherwise keep the while-lowering.
          final canFor =
              (initDart == null || !initDart.startsWith('ts.eval(')) &&
              (incrDart == null || !incrDart.startsWith('ts.eval('));
          if (canFor) {
            _line(
              'for (${initDart ?? ''}; '
              '${_cond(flow.condition ?? 'true')}; ${incrDart ?? ''}) '
              '{$nameNote',
            );
            _indent++;
            open.add(_openBlock(flow.kind)); // the for statement owns the increment
          } else {
            if (init != null) {
              _line('${initDart!};${nameNote.isEmpty ? ' // init' : '$nameNote (init)'}');
            }
            _line(
              'while (${_cond(flow.condition ?? 'true')}) '
              '{$nameNote',
            );
            _indent++;
            open.add(_openBlock(flow.kind, increment: flow.increment));
          }
        case FlowKind.forEach:
          final array = flow.arrayExpr ?? '[]';
          final loopVar = _claimId('element');
          _line(
            'for (final $loopVar in ts.iterate(${_expr(array)})) '
            '{$nameNote',
          );
          _indent++;
          final element = flow.arrayElement;
          if (element != null) {
            final assign = _expr('$element = __LWELEMENT__');
            if (assign.startsWith('ts.eval(')) {
              // Baking the Dart loop variable into a TestStand expression
              // string would be fabrication — keep the binding as a TODO.
              _line(
                '// TODO: bind loop element: '
                '${_comment(element)} = <element>',
              );
            } else {
              // Cast to the target's declared type — loud on a
              // mismatched element, never a silent reinterpretation.
              final targetId = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)').firstMatch(assign)?.group(1);
              final cast = switch (_idTypes[targetId]) {
                'double' => '($loopVar as num).toDouble()',
                'int' => '($loopVar as num).toInt()',
                'bool' => '$loopVar as bool',
                'String' => '$loopVar as String',
                'List' => '$loopVar as List<dynamic>',
                _ => loopVar,
              };
              _line('${assign.replaceAll('__LWELEMENT__', cast)};');
            }
          }
          open.add(_openBlock(flow.kind));
        case FlowKind.selectBlock:
          selectCounter++;
          selectVars[selectCounter] = (
            value: _claimId('select$selectCounter'),
            matched: _claimId('matched$selectCounter'),
          );
          _line('sel$selectCounter: {$nameNote');
          _indent++;
          _line(
            'final ${selectVars[selectCounter]!.value} = '
            '${_expr(flow.itemExpression ?? 'null')};',
          );
          _line('var ${selectVars[selectCounter]!.matched} = false;');
          open.add(_openBlock(flow.kind, selectId: selectCounter));
        case FlowKind.caseBlock:
          final select = innermost((k) => k == FlowKind.selectBlock)?.selectId ?? 0;
          if (select == 0) {
            _line(
              '// $rawName: Case without an open Select (unbalanced source) '
              '— kept as a comment',
            );
            continue;
          }
          final vars = selectVars[select]!;
          if (flow.isDefaultCase) {
            _line('if (!${vars.matched}) {${nameNote.isEmpty ? ' // default case' : '$nameNote (default)'}');
          } else {
            _line(
              'if (!${vars.matched} && ${vars.value} == '
              '${_expr(flow.itemExpression ?? 'null')}) {$nameNote',
            );
          }
          _indent++;
          _line('${vars.matched} = true;');
          open.add(_openBlock(flow.kind, selectId: select));
        case FlowKind.end:
          if (open.isEmpty) {
            _line(
              '// $rawName: NI_Flow_End without an open block '
              '(unbalanced in source)',
            );
            continue;
          }
          closeBlock(open.removeLast(), note: nameNote);
        case FlowKind.breakStmt:
          final target = innermost((k) => k == FlowKind.selectBlock || loopKinds.contains(k));
          if (target == null) {
            _line(
              '// $rawName: Break with no enclosing loop/select — kept as a '
              'comment',
            );
          } else {
            final breakStmt = target.kind == FlowKind.selectBlock ? 'break sel${target.selectId};' : 'break;';
            // A break/continue step's effective precondition (instance or
            // type default) GATES the jump — emitting it bare fabricates
            // an unconditional exit (a "Break On Terminate" would kill its
            // loop on iteration one).
            final pre = step.settings.precondition ?? _typePreconditions[step.type];
            if (pre != null) {
              _line('if (${_cond(pre)}) {$nameNote');
              _indent++;
              _line(breakStmt);
              _indent--;
              _line('}');
            } else {
              _line('$breakStmt$nameNote');
            }
          }
        case FlowKind.continueStmt:
          final loop = innermost(loopKinds.contains);
          if (loop == null) {
            _line(
              '// $rawName: Continue with no enclosing loop — kept as a '
              'comment',
            );
          } else {
            final pre = step.settings.precondition ?? _typePreconditions[step.type];
            if (pre != null) {
              _line('if (${_cond(pre)}) {$nameNote');
              _indent++;
            }
            if (loop.kind == FlowKind.forLoop && loop.increment != null) {
              _line(
                '${_exprStatement(loop.increment!)}; // for increment '
                '(before continue)',
              );
            }
            _line('continue;${pre == null ? nameNote : ''}');
            if (pre != null) {
              _indent--;
              _line('}');
            }
          }
      }
    }
    // Close any blocks the source left unbalanced (never emit broken Dart).
    while (open.isNotEmpty) {
      closeBlock(open.removeLast(), note: ' // closed: unbalanced block in source');
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
    if (translated.startsWith('ts.eval(')) return translated;
    final m = RegExp(
      r'^((?:fileGlobals|stationGlobals)\.)?'
      r'([A-Za-z_][A-Za-z0-9_]*)\s*=(?![=])',
    ).firstMatch(translated);
    if (m != null) {
      final lhsType = switch (m.group(1)) {
        'fileGlobals.' => _fileGlobalTypes[m.group(2)],
        'stationGlobals.' => 'dynamic',
        _ => _idTypes[m.group(2)],
      };
      if (_kindMismatch(lhsType, translated.substring(m.end).trim())) {
        return _evalFallback(raw);
      }
    }
    return translated;
  }

  /// Whether putting [rhs] into a slot of declared Dart type [lhsType] is
  /// VISIBLY of another kind — the shared lhs-type guard: a statement
  /// assignment routes such an expression through the eval fallback
  /// (TestStand's engine coercion there is not pinned), and a sequence-call
  /// ARGUMENT does the same for its bound expression ([_renderCallArgs]).
  /// Heuristic and one-sided: `false` means "not visibly wrong", never
  /// "proven right".
  bool _kindMismatch(String? lhsType, String rhs) {
    if (lhsType == null || lhsType == 'dynamic') return false;
    // `Nothing` (null) has no typed scalar/list slot to land in.
    if (rhs == 'null') return true;
    final looksString =
        rhs.startsWith("'") || rhs.startsWith('"') || _idTypes[rhs] == 'String' || rhs.startsWith('ts.str(');
    final rhsLeadType = _idTypes[RegExp(r'^[A-Za-z_][A-Za-z0-9_\$]*').firstMatch(rhs)?.group(0) ?? ''];
    final looksNumericLead = RegExp(r'^[0-9(]').hasMatch(rhs) || rhsLeadType == 'double' || rhsLeadType == 'int';
    return switch (lhsType) {
      'String' => (looksNumericLead && !looksString) || _staticallyBool(rhs),
      'double' || 'int' => looksString || _staticallyBool(rhs),
      'bool' => !_staticallyBool(rhs) && (looksString || looksNumericLead),
      'List' => looksString || _staticallyBool(rhs) || (looksNumericLead && !rhs.startsWith('(')),
      _ => false,
    };
  }

  /// Whether translated expression [e] is STATICALLY an `int` in Dart:
  /// int-typed locals/params, integer literals (dec/hex), and `+ - *`
  /// grouping only. Drives call-argument int/double adaptation — Dart
  /// does not widen an int EXPRESSION to a double slot (only a bare
  /// integer literal is contextually retyped), and an int slot rejects
  /// anything not provably int.
  bool _staticallyIntExpr(String e) {
    if (e.contains("'") || e.contains('"')) return false;
    final sansHex = e.replaceAll(RegExp('0x[0-9A-Fa-f]+'), '0');
    for (final m in RegExp(r'[A-Za-z_][A-Za-z0-9_\$]*').allMatches(sansHex)) {
      if (_idTypes[m.group(0)] != 'int') return false;
    }
    final rest = sansHex.replaceAll(RegExp(r'[A-Za-z_][A-Za-z0-9_\$]*'), '0');
    return rest.trim().isNotEmpty && RegExp(r'^[0-9\s()+\-*]+$').hasMatch(rest);
  }

  /// A statement-position expression, split at TOP-LEVEL COMMAS into
  /// sequential statements — TestStand's comma is C-heritage sequential
  /// evaluation, and in statement position the value is discarded, so the
  /// split is lossless (30% of all corpus eval-fallbacks are these
  /// assignment chains). Each piece translates independently; a piece
  /// beyond mechanical translation gets its own _eval line.
  List<String> _stmtParts(String raw) {
    final pieces = _rawStmtPieces(raw);
    if (pieces == null) return [_exprStatement(raw)];
    final out = <String>[
      for (final p in pieces)
        if (p.trim().isNotEmpty) _exprStatement(p),
    ];
    return out.isEmpty ? [_exprStatement(raw)] : out;
  }

  /// Emits a statement-position expression, one line per top-level piece.
  void _emitStmt(String raw, String note) {
    final parts = _stmtParts(raw);
    for (var i = 0; i < parts.length; i++) {
      final suffix = note.isEmpty ? '' : (i == 0 ? ' // $note' : ' // $note (cont.)');
      _line('${parts[i]};$suffix');
    }
  }

  void _emitPlainStep(Step step) {
    final settings = step.settings;
    final precondition = settings.precondition ?? _typePreconditions[step.type];
    if (precondition != null) {
      _line(
        'if (${_cond(precondition)}) { '
        '// precondition of ${_comment(step.name)}',
      );
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
          // A default-named step's trailing comment restates nothing.
          _emitStmt(expression, name == 'Statement' ? '' : name);
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
        final waitNote = name == 'Wait' ? '' : ' // $name';
        if (literal != null) {
          final ms = (literal * 1000).round();
          _line(
            ms % 1000 == 0
                ? 'await Future<void>.delayed('
                      'const Duration(seconds: ${ms ~/ 1000}));$waitNote'
                : 'await Future<void>.delayed('
                      'const Duration(milliseconds: $ms));$waitNote',
          );
        } else if (timeout != null) {
          _line(
            'await Future<void>.delayed(Duration('
            'microseconds: ((${_expr(timeout)}) * 1e6).round()));'
            '$waitNote',
          );
        } else {
          _line('// $name: Wait with no time expression');
        }
        return;
    }

    switch (module.adapter) {
      case SeqAdapter.sequenceCall:
        final target = module.sequenceName;
        _stats.callSites++;
        // Bind to a local sequence ONLY when the call targets the current
        // file (UseCurFile, no file named, or the file's own path) —
        // matching by name alone bound external calls to same-named local
        // sequences, which generated infinite self-recursion (17 corpus
        // sites, e.g. a MainSequence delegating to sibling MainSequences).
        final inFileFn = module.resolvesLocalCall(ownFilePath: sourceName) && target != null
            ? _sequenceFnNames[target]
            : null;
        if (inFileFn != null) {
          // Bound arguments become real named arguments against the
          // callee's precomputed scope ([_renderCallArgs]); a bare call
          // is exact as-is.
          final scope = _scopeByName[target]!;
          var argsText = '';
          if (module.sequenceArguments.isNotEmpty) {
            _stats.boundSites++;
            _stats.localBoundSites++;
            final (:text, :disarmed) = _renderCallArgs(
              module,
              calleeLabel: target!,
              params: _scopeParamTable(scope),
              writtenParams: scope.writtenParams,
            );
            argsText = text;
            if (!disarmed) _stats.localBoundSitesRearmed++;
          }
          _line('await $inFileFn($argsText); // $name');
        } else {
          // An EXTERNAL sequence call is just a function that lives in
          // another file. In PROJECT mode a resolvable target binds to the
          // sibling module's real exported function (named arguments bind
          // against that module's PREDICTED parameter scope); otherwise
          // (or in single-file mode) it calls a generated stub typed from
          // the call sites' prototype snapshots. Either way it is counted
          // unported so the harness ships the owning test disarmed — a
          // resolved callee usually still contains its own stubs, and v1
          // does not chase cross-module reachability (conservative, never
          // a fabricated green).
          final resolved = resolveExternalCall?.call(module);
          if (resolved != null) {
            if (asTest) {
              _markUnported(
                'cross-file sequence '
                '${_stubTarget(step, module)} (see its module TODOs)',
              );
            }
            var argsText = '';
            if (module.sequenceArguments.isNotEmpty) {
              _stats.boundSites++;
              argsText = _renderCallArgs(
                module,
                calleeLabel: target ?? _stubTarget(step, module),
                params: _scopeParamTable(resolved.scope),
                writtenParams: resolved.scope.writtenParams,
              ).text;
            }
            _line('await ${resolved.fn}($argsText); // $name: external sequence');
          } else {
            if (asTest) {
              _markUnported('external sequence: ${_stubTarget(step, module)}');
            }
            final stub = _stubFor(step, module);
            var argsText = '';
            // Expression-form targets (SpecifyByExpr) stay untranslated:
            // the callee is not known statically, so no argument list can
            // honestly bind (4 corpus sites; already disarmed above).
            if (module.specifiesByExpression != true && module.sequenceArguments.isNotEmpty) {
              _stats.boundSites++;
              argsText = _renderCallArgs(
                module,
                calleeLabel: target ?? _stubTarget(step, module),
                params: stub.paramTableFor(module),
              ).text;
            }
            _line(
              'await ${stub.name}($argsText); // $name: '
              'external sequence call',
            );
          }
        }
      case SeqAdapter.labView:
        // VI calls are the ONE code-module adapter that gets a generated
        // stub in E2E mode: the VI is the port target — implementing the
        // stub arms the step (other unported surfaces are inline throws).
        if (asTest) _markUnported(_stubTarget(step, module));
        _line(
          'await ${_stubFor(step, module).name}(); // $name'
          '${step.type != null ? ' [${_comment(step.type!)}]' : ''}',
        );
      case SeqAdapter.cModule:
      case SeqAdapter.python:
      case SeqAdapter.unknown:
        if (asTest) {
          _throwLine(step, '${module.adapter.name} call', _stubTarget(step, module));
        } else {
          _line(
            'await ${_stubFor(step, module).name}(); // $name'
            '${step.type != null ? ' [${_comment(step.type!)}]' : ''}',
          );
        }
      case SeqAdapter.none:
        // E2E mode: a typed step with no code module still carries its
        // TYPE's action (NI_Measurement measures, NumericLimitTest compares)
        // — none of that is exported yet, so a silent no-op would fabricate
        // a pass. Inline throw, naming the type. An UNtyped module-less step
        // genuinely has nothing to run and stays a comment.
        if (asTest && step.type != null) {
          _throwLine(step, 'step type ${step.type}', 'action not exported yet');
        } else {
          _line(
            '// $name'
            '${step.type != null ? ' [${_comment(step.type!)}]' : ''}: '
            'no code module',
          );
        }
    }
  }

  /// E2E mode: an unported non-VI surface is an inline throw — exceptions
  /// are how tests fail, so an armed test is loud about what is missing.
  /// Also recorded so the harness emits the owning root as `lw.skipTest`.
  void _throwLine(Step step, String kind, String target) {
    _markUnported('$kind: $target');
    _line(
      "throw UnimplementedError('${_escape('$kind: $target')}'); "
      '// ${_comment(step.name)}'
      '${step.type != null ? ' [${_comment(step.type!)}]' : ''}',
    );
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

  /// The callee-parameter binding table of [scope]: lowercased TestStand
  /// name → the generated parameter id and its declared (int-refined) type.
  Map<String, ({String id, String type})> _scopeParamTable(_SeqScope scope) => {
    for (final e in scope.paramIds.entries) e.key.toLowerCase(): (id: e.value, type: scope.idTypes[e.value]!),
  };

  /// Translates one SequenceCall site's bound arguments into Dart named
  /// arguments against [params] (lowercased callee-parameter name → its
  /// generated id and declared type). Per row:
  ///  * `UseDef` → the named argument is OMITTED — exact, the generated
  ///    callee signature carries that declared default;
  ///  * a bound expression translates in the CALLER's scope ([_expr]),
  ///    guarded by the callee parameter's declared type ([_kindMismatch]
  ///    plus the int/double adaptation — a statically-int value widens
  ///    losslessly via `.toDouble()`, anything not visibly of the
  ///    parameter's kind keeps TestStand semantics via eval);
  ///  * a value beyond mechanical translation rides in `ts.eval(…)` —
  ///    honest (suite mode's hazard scan disarms the owning test);
  ///  * an unknown argument name (stale snapshot), a guard rejection, or
  ///    a scalar by-ref writeback records a per-SITE disarm naming the
  ///    reason.
  /// Returns the rendered `id: value` list and whether any per-site
  /// call-parameter disarm fired.
  ({String text, bool disarmed}) _renderCallArgs(
    StepModule module, {
    required String calleeLabel,
    required Map<String, ({String id, String type})> params,
    Set<String> writtenParams = const {},
  }) {
    final parts = <String>[];
    var disarmed = false;
    final seen = <String>{};
    void disarm(String kind, String reason) {
      disarmed = true;
      _stats.siteDisarms[kind] = (_stats.siteDisarms[kind] ?? 0) + 1;
      _markUnported('call parameters of sequence $calleeLabel: $reason');
    }

    for (final arg in module.sequenceArguments) {
      final lower = arg.name.toLowerCase();
      if (!seen.add(lower)) {
        disarm('duplicate binding', 'duplicate binding of ${arg.name}');
        continue;
      }
      final param = params[lower];
      if (param == null) {
        disarm('unknown parameter', 'no parameter named ${arg.name} (stale binding)');
        continue;
      }
      if (arg.usesDefault == true) {
        _stats.argsByOmission++;
        continue; // exact: omission binds the callee's declared default
      }
      final raw = arg.expression;
      if (raw == null) {
        // No expression and no UseDef flag — absent from the corpus, so
        // the engine's behavior there is not pinned: omit and state it.
        disarm('unbound argument', '${arg.name} binds no expression');
        continue;
      }
      var value = _expr(raw);
      if (!value.startsWith('ts.eval(')) {
        if (_kindMismatch(param.type, value) || (param.type == 'int' && !_staticallyIntExpr(value))) {
          // Not visibly of the parameter's kind — TestStand's coercion is
          // not pinned, so the raw expression rides in eval rather than a
          // guessed cast.
          value = _evalFallback(raw);
          disarm('type guard', '${arg.name} binding is not visibly ${param.type}-typed');
        } else if (param.type == 'double' && _staticallyIntExpr(value) && !RegExp(r'^\d+$').hasMatch(value)) {
          // Lossless: TestStand Num IS a double — the int refinement is
          // our own representation choice, so widening back is exact.
          // (Dart contextually retypes only a BARE integer literal.)
          value = RegExp(r'^[A-Za-z_][A-Za-z0-9_\$]*$').hasMatch(value) ? '$value.toDouble()' : '($value).toDouble()';
        }
      }
      if (value.startsWith('ts.eval(')) {
        _stats.argsEvalFallback++;
      } else {
        _stats.argsTranslated++;
      }
      // Scalar by-ref writeback: the engine binds a variable-path
      // argument BY REFERENCE, so a callee that assigns the parameter
      // writes through to the caller's variable — the export passes
      // scalars by value, losing that writeback. Containers/arrays pass
      // object identity (List/PropObj) and stay correct; a literal-bound
      // written parameter is safe too (nothing to write back to).
      if (writtenParams.contains(lower) &&
          const {'double', 'int', 'bool', 'String'}.contains(param.type) &&
          _isVariablePath(raw)) {
        disarmed = true;
        _stats.siteDisarms['by-ref writeback'] = (_stats.siteDisarms['by-ref writeback'] ?? 0) + 1;
        _markUnported('by-ref writeback of parameter ${arg.name} of sequence $calleeLabel not exported');
      }
      parts.add('${param.id}: $value');
    }
    return (text: parts.join(', '), disarmed: disarmed);
  }

  _StubInfo _stubFor(Step step, StepModule module) {
    final target = _stubTarget(step, module);
    final adapter = module.adapter.name;
    final key = '$adapter|$target';
    final info = _stubs.putIfAbsent(key, () {
      final isSeq = module.adapter == SeqAdapter.sequenceCall;
      // Strip only a known trailing file extension; a dotted TARGET NAME
      // (UI.TestSocket.SetCaption) keeps every segment — collapsing to the
      // first segment minted unreadable uI2…uI8 collision names. (Review
      // fix: `\$` in a raw string is a literal '$', not the end anchor, so
      // the strip never fired and stub names carried the .vi/.seq tail.)
      final lastSegment = target
          .split(RegExp(r'[/\\]'))
          .last
          .replaceFirst(RegExp(r'\.(vi|seq|dll|py)$', caseSensitive: false), '');
      // An external sequence call reads as the sequence's own function name
      // (`await loadIniFile();` — implement it, or point it at the other
      // exported file's function); code-module stubs keep the `call` prefix.
      final name = _uniqueTopLevel(
        isSeq ? dartIdentifier(lastSegment) : 'call${dartIdentifier(lastSegment, capitalize: true)}',
      );
      return _StubInfo(
        name: name,
        isSeq: isSeq,
        adapter: adapter,
        target: target,
        firstStepName: step.name,
      );
    });
    // An external-sequence site contributes its parameter knowledge (the
    // prototype snapshot / bound argument names) to the stub's signature.
    if (module.adapter == SeqAdapter.sequenceCall && module.specifiesByExpression != true) {
      info.note(module);
    }
    return info;
  }

  void _emitStubs() {
    if (_stubs.isEmpty) return;
    _out.writeln(
      '// ── code-module stubs '
      '─────────────────────────────────────────────────────',
    );
    for (final info in _stubs.values) {
      final params = info.signatureDecls();
      final lines = [
        if (info.isSeq) ...[
          '/// External sequence `${_comment(info.target)}`',
          '/// (called from step `${_comment(info.firstStepName)}`) — lives in another',
          '/// sequence file. TODO: implement, or delegate to that file\'s',
          '/// exported function.',
          if (params.isNotEmpty)
            info.typed
                ? "/// Signature: the call sites' prototype snapshot of the callee's"
                      '\n/// parameters (defaults included; a snapshot can be stale if the'
                      '\n/// callee changed after binding).'
                : '/// Parameters: the union of names observed across the call sites\''
                      '\n/// snapshots and bindings — they disagree or are partly missing,'
                      '\n/// so no types are claimed (dynamic).',
        ] else ...[
          '/// Stub for the ${info.adapter} module call `${_comment(info.target)}`',
          '/// (from step `${_comment(info.firstStepName)}`). TODO: implement against '
              'the real module.',
        ],
        'Future<Object?> ${info.name}('
            '${params.isEmpty ? '' : '{${params.join(', ')}}'}) async =>',
        "    throw UnimplementedError('"
            "${_escape(info.isSeq ? 'external sequence: ${info.target}' : '${info.adapter} call: ${info.target}')}');",
      ];
      _out
        ..writeln(lines.join('\n'))
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
            step.module.resolvesLocalCall(ownFilePath: sourceName) &&
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
        if (!called.contains(s.name) && !externallyCalled.contains(s.name)) s,
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
      ..writeln(
        '// ── generated labwright harness '
        '─────────────────────────────────────────────',
      )
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
          unported.add(
            "root parameter '${p.name}' is an engine object "
            '(nothing binds it when run as a test)',
          );
        }
      }
      final reqArg = reqs.isEmpty
          ? ''
          : ' requirements: '
                "[${reqs.map((r) => "'${_escape(r)}'").join(', ')}],";
      final fnName = _sequenceFnNames[root.name]!;
      if (unported.isNotEmpty) {
        _out.writeln(
          '  // TODO: unported — implement, then rename '
          'lw.skipTest -> lw.test to arm:',
        );
        for (final target in unported) {
          _out.writeln('  //   ${_comment(target)}');
        }
      }
      _out
        ..writeln(
          '  lw.${unported.isEmpty ? 'test' : 'skipTest'}'
          "('${_escape(root.name)}',$reqArg () async {",
        )
        ..writeln('    await $fnName();')
        ..writeln('  });');
    }
    _out.writeln('}');
  }

  void _emitRuntime() {
    // Engine STATE as typed structs — clearer than a property bag and
    // statically checkable: a member typo is a compile error, scalar
    // fields carry the file's declared defaults. Globals stay CONSTRAINED
    // to the file whose sequences use them: FileGlobals is per module;
    // StationGlobals is declared here only when this file hosts it.
    final buf = StringBuffer()
      ..writeln(
        '// ── engine state '
        '────────────────────────────────────────────────────────────',
      )
      ..writeln()
      ..writeln(
        "/// This file's globals (FileGlobals): typed fields with "
        'the declared',
      )
      ..writeln('/// defaults, names in the source casing.')
      ..writeln('class FileGlobals {');
    if (_fileGlobalDecls.isEmpty) {
      buf.writeln('  // (no file globals declared in the source)');
    }
    for (final decl in _fileGlobalDecls) {
      buf.writeln('  $decl');
    }
    for (final skipped in _fileGlobalSkipped) {
      buf.writeln('  ${_unportableFieldLine(skipped)}');
    }
    buf
      ..writeln('}')
      ..writeln()
      ..writeln('final fileGlobals = FileGlobals();');
    if (hostStationGlobals) {
      if (_stationGlobalCanon.isNotEmpty || _stationGlobalSkipped.isNotEmpty) {
        buf
          ..writeln()
          ..writeln(
            '/// Station-wide state (StationGlobals): the surface '
            'OBSERVED in this',
          )
          ..writeln(
            "/// file's expressions. Station-level values come from "
            'the machine, so',
          )
          ..writeln(
            '/// nothing here has a declared default — reads stay '
            'disarmed until',
          )
          ..writeln('/// ported.')
          ..writeln('class StationGlobals {');
        for (final name in _stationGlobalCanon.values) {
          buf.writeln('  dynamic $name;');
        }
        for (final skipped in _stationGlobalSkipped) {
          buf.writeln('  ${_unportableFieldLine(skipped)}');
        }
        buf
          ..writeln('}')
          ..writeln()
          ..writeln('final stationGlobals = StationGlobals();');
      }
    } else {
      buf
        ..writeln()
        ..writeln(
          '// Station-wide state (StationGlobals) lives in '
          '$stationGlobalsHome.',
        );
    }
    buf
      ..writeln()
      ..writeln(
        '// The engine execution objects — null placeholders a '
        'real host can back.',
      )
      ..writeln('final dynamic runState = null;')
      ..writeln('final dynamic step = null;');
    _out.write(buf);
  }

  late final Map<String, SeqType> _typeByName = {
    for (final t in file.typeDefs) t.name: t,
  };

  /// FileGlobals: lowercased name → declared casing, declared casing →
  /// emitted Dart type ('double'|'bool'|'String'|'List'|'dynamic'), and
  /// the field declaration lines. Built once in [export]; translation
  /// rewrites level-1 members to declared casing and falls back to eval
  /// for names the struct does not declare.
  final Map<String, String> _fileGlobalCanon = {};
  final Map<String, String> _fileGlobalTypes = {};
  final List<String> _fileGlobalDecls = [];
  final List<String> _fileGlobalSkipped = [];

  /// StationGlobals: lowercased name → declared casing (fields are all
  /// `dynamic` — station-level values carry no declared defaults).
  final Map<String, String> _stationGlobalCanon = {};
  final List<String> _stationGlobalSkipped = [];

  void _buildGlobals() {
    final defaults = file.data.prop('FileGlobalDefaults');
    for (final c in defaults?.subProps ?? const <SeqProperty>[]) {
      if (!_validGlobalFieldName(c.name) || _fileGlobalCanon.containsKey(c.name.toLowerCase())) {
        _fileGlobalSkipped.add(c.name);
        continue;
      }
      _fileGlobalCanon[c.name.toLowerCase()] = c.name;
      final (type, decl) = _globalField(c);
      _fileGlobalTypes[c.name] = type;
      _fileGlobalDecls.add(decl);
    }
    final names = (stationGlobalNames.isEmpty ? _collectStationGlobalRefs(file) : stationGlobalNames).toList()..sort();
    for (final name in names) {
      if (!_validGlobalFieldName(name) || _stationGlobalCanon.containsKey(name.toLowerCase())) {
        _stationGlobalSkipped.add(name);
        continue;
      }
      _stationGlobalCanon[name.toLowerCase()] = name;
    }
  }

  /// One FileGlobals field: typed scalars keep their declared default,
  /// arrays their declared length, containers their declared structure.
  (String, String) _globalField(SeqProperty c) {
    final name = c.name;
    final note = ' // ${c.typeName ?? c.className ?? 'value'}';
    if (c.array != null || c.declaredArrayLength != null || _arrayClasses.contains(c.className)) {
      return ('List', 'List<dynamic> $name = ${_listInit(c, {})};$note');
    }
    final scalar = c.scalar;
    switch (c.className) {
      case 'Num':
        final n = num.tryParse(scalar ?? '');
        return ('double', 'double $name = ${n == null ? '0' : _numLiteral(n)};$note');
      case 'Bool' || 'Boolean':
        return ('bool', 'bool $name = ${scalar?.toLowerCase() == 'true'};$note');
      case 'Str' || 'ExprValue' || 'PathValue':
        return ('String', "String $name = '${_escape(scalar ?? '')}';$note");
      case 'Ref':
        return ('dynamic', 'dynamic $name;$note');
      default:
        return ('dynamic', 'dynamic $name = ${_propObjInit(c, {})};$note');
    }
  }

  /// A structured (Obj/container) initializer preserving the DECLARED
  /// default structure — a sequence that iterates its own Obj local's
  /// sub-properties must run on real data, not null (corpus: a
  /// CreateStationGlobals sequence iterates two Obj locals' children to
  /// build the station bag). [seenTypes] breaks typedef cycles.
  String _propObjInit(SeqProperty p, Set<String> seenTypes) {
    final children = p.subProps;
    if (children.isEmpty) {
      return _typeOrEmpty(p.typeName ?? p.className, seenTypes);
    }
    final parts = [
      for (final c in children) "'${_escape(c.name)}': ${_propValue(c, seenTypes)}",
    ];
    return 'ts.PropObj({${parts.join(', ')}})';
  }

  /// A field with no materialized children still has its TYPE's declared
  /// shape — the file's typedef table gives the structure, class zeros
  /// give the values.
  String _typeOrEmpty(String? className, Set<String> seenTypes) {
    final t = className != null ? _typeByName[className] : null;
    if (t == null || !seenTypes.add(className!)) return 'ts.PropObj()';
    final init = _propObjInit(t.raw, seenTypes);
    seenTypes.remove(className);
    return init;
  }

  static const _arrayClasses = {'Nums', 'Strs', 'Bools', 'Objs', 'Containers'};

  String _propValue(SeqProperty c, Set<String> seenTypes) {
    if (c.array != null || c.declaredArrayLength != null) {
      return _listInit(c, seenTypes);
    }
    final scalar = c.scalar;
    if (scalar != null) {
      return switch (c.className) {
        'Num' => num.tryParse(scalar)?.toString() ?? "'${_escape(scalar)}'",
        'Bool' || 'Boolean' => scalar.toLowerCase() == 'true' ? 'true' : 'false',
        _ => "'${_escape(scalar)}'",
      };
    }
    if (c.subProps.isNotEmpty) return _propObjInit(c, seenTypes);
    // A typed field with no materialized children (`X = "TYPE, Foo"`)
    // carries its type as typeName, not className.
    return switch (c.className) {
      'Num' => '0',
      'Bool' || 'Boolean' => 'false',
      'Str' || 'ExprValue' || 'PathValue' => "''",
      'Ref' => 'null',
      final cls when _arrayClasses.contains(cls) => '<dynamic>[]',
      final cls => switch (c.typeName ?? cls) {
        null => 'null',
        final type => _typeOrEmpty(type, seenTypes),
      },
    };
  }

  /// A declared array's initializer, at the DECLARED length. The text
  /// format stores default-valued elements only as a `%HI` bound (2800
  /// corpus arrays are sized with zero materialized members — an empty
  /// list would run count-driven loops zero times where the engine runs
  /// N), and overridden elements sparsely by `[index]` name. Zeros come
  /// from the element class or the `%EPTYPE` prototype; uniform scalar
  /// runs compress to List.filled, object elements to List.generate
  /// (filled would alias ONE object), sparse overrides to cascades.
  String _listInit(SeqProperty owner, Set<String> seenTypes) {
    final elements = owner.array ?? const <SeqProperty>[];
    final declared = owner.declaredArrayLength ?? elements.length;
    if (declared == 0 && elements.isEmpty) return '<dynamic>[]';
    if (elements.length < declared) {
      final zero = _elementZero(owner, seenTypes);
      // Sparse: every materialized element carries its [index] name.
      final overrides = <(int, String)>[];
      var placeable = true;
      for (final e in elements) {
        final m = RegExp(r'^\[(\d+)\]$').firstMatch(e.name);
        final index = m != null ? int.parse(m.group(1)!) : -1;
        if (index < 0 || index >= declared) {
          placeable = false;
          break;
        }
        final value = _propValue(e, seenTypes);
        // A materialized element with no recovered content must not
        // erase the default-element structure.
        if (value != 'null' || zero == 'null') overrides.add((index, value));
      }
      if (placeable) {
        final base = zero.startsWith('ts.PropObj')
            ? 'List<dynamic>.generate($declared, (_) => $zero, '
                  'growable: true)'
            : 'List<dynamic>.filled($declared, $zero, growable: true)';
        if (overrides.isEmpty) return base;
        final sets = [for (final (i, v) in overrides) '..[$i] = $v'].join();
        return '($base$sets)';
      }
      // Unplaceable (stale bounds) — the materialized elements, honestly.
    }
    if (elements.isEmpty) return '<dynamic>[]';
    final parts = [for (final e in elements) _propValue(e, seenTypes)];
    final first = parts.first;
    if (parts.length > 8 && !first.startsWith('ts.PropObj') && parts.every((p) => p == first)) {
      return 'List<dynamic>.filled(${parts.length}, $first, growable: true)';
    }
    return '<dynamic>[${parts.join(', ')}]';
  }

  /// One default element of a sized array: the `%EPTYPE` prototype when
  /// declared, else the element-class zero (`Bools` → false, …).
  String _elementZero(SeqProperty owner, Set<String> seenTypes) {
    final proto = owner.elementTypeName;
    if (proto != null) return _typeOrEmpty(proto, seenTypes);
    return switch (owner.className) {
      'Nums' => '0',
      'Bools' => 'false',
      'Strs' => "''",
      'Objs' || 'Containers' => 'ts.PropObj()',
      _ => 'null',
    };
  }
}
