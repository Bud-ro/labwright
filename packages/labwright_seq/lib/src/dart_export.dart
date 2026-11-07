import 'scalar_read.dart';
import 'seq_expression.dart';
import 'seq_file.dart';
import 'seq_module.dart';
import 'seq_property.dart';
import 'seq_step.dart';
import 'seq_typedefs.dart';

String exportSeqFileToDart(SeqFile file, {String? sourceName, SeqExportStats? stats}) =>
    _DartExporter(file, sourceName: sourceName, stats: stats).export();

String exportSeqFileToLabwright(SeqFile file, {String? sourceName, SeqExportStats? stats}) =>
    _DartExporter(file, sourceName: sourceName, asTest: true, stats: stats).export();

class SeqExportStats {
  int callSites = 0;

  int boundSites = 0;

  int localBoundSites = 0;

  int localBoundSitesRearmed = 0;

  int argsByOmission = 0;

  int argsTranslated = 0;

  int argsEvalFallback = 0;

  final Map<String, int> siteDisarms = {};

  int payloadNotes = 0;

  int wiredArgs = 0;
}

class SeqProjectExport {
  const SeqProjectExport({required this.files});

  final Map<String, String> files;
}

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

  final ordered = byPath.keys.toList()..sort();
  final takenStems = <String>{};
  final moduleOf = {
    for (final key in ordered) key: '${_uniqueName(snake(stemOf(key)), takenStems)}_seq',
  };

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
    final sameDir = [
      for (final c in candidates)
        if (dirOf(c) == dirOf(callerKey)) c,
    ];
    return sameDir.length == 1 ? sameDir.single : null;
  }

  final resolvedOf = <String, Map<(String, String), _ResolvedCall>>{};
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
        if (fn == null) continue;
        final prefix = moduleOf[targetKey]!;
        (resolvedOf[key] ??= {})[(sf, target)] = (fn: '$prefix.$fn', scope: scopeByNameOf[targetKey]![target]!);
        (importsOf[key] ??= {}).add(targetKey);
        (externallyCalledOf[targetKey] ??= {}).add(target);
      }
    }
  }

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
    final resolved = resolvedOf[key] ?? const <(String, String), _ResolvedCall>{};
    files['$module.dart'] = _DartExporter(
      byPath[key]!,
      sourceName: key,
      asTest: true,
      registerName: 'register',
      extraImports: extra,
      resolveExternalCall: (m) {
        final (sf, name) = (m.sequenceFile, m.sequenceName);
        return sf == null || name == null ? null : resolved[(sf, name)];
      },
      externallyCalled: externallyCalledOf[key] ?? const <String>{},
      stationGlobalNames: stationUnion,
      hostStationGlobals: !sharedStation && key == stationOwner,
      stationGlobalsHome: stationHome,
    ).export();
    files['$module.dart'] = _withoutUnusedImport(
      files['$module.dart']!,
      "import 'lw_runtime.dart';\n",
      RegExp(r'stationGlobals'),
    );
    for (final dep in importsOf[key] ?? const <String>{}) {
      final depModule = moduleOf[dep]!;
      files['$module.dart'] = _withoutUnusedImport(
        files['$module.dart']!,
        "import '$depModule.dart' as $depModule;\n",
        RegExp('(?<![\\w\\\$.])$depModule\\.'),
      );
    }
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

const _dartReserved = {
  'if',
  'else',
  'for',
  'while',
  'do',
  'switch',
  'case',
  'default',
  'break',
  'continue',
  'return',
  'var',
  'final',
  'const',
  'void',
  'main',
  'class',
  'new',
  'this',
  'super',
  'true',
  'false',
  'null',
  'is',
  'in',
  'try',
  'catch',
  'finally',
  'throw',
  'rethrow',
  'assert',
  'await',
  'async',
  'enum',
  'extends',
  'with',
  'implements',
  'abstract',
  'static',
  'late',
  'required',
  'dynamic',
  'yield',
  'export',
  'import',
  'library',
  'part',
  'fileGlobals',
  'stationGlobals',
  'runState',
  'step',
  'ts',
  'params',
  'locals',
  's',
  'ctx',
  'lw',
};

String dartIdentifier(String name, {bool capitalize = false}) {
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

String _uniqueName(String base, Set<String> taken) {
  var name = base;
  var n = 2;
  while (!taken.add(name)) {
    name = '$base${n++}';
  }
  return name;
}

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

Map<String, String> _sequenceFnTable(SeqFile file, Set<String> taken) {
  final table = <String, String>{};
  for (final sequence in file.sequences) {
    if (table.containsKey(sequence.name)) continue;
    table[sequence.name] = _uniqueName(dartIdentifier(sequence.name), taken);
  }
  return table;
}

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
          j += 2;
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

String _stripComments(String text) {
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
    if (depth != 0) return text;
    result = result.substring(0, at) + result.substring(at + marker.length, i - 1) + result.substring(i);
    at = result.indexOf(marker);
  }
  return result;
}

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
    return d == 0 && '"'.allMatches(p.replaceAll(r'\"', '')).length.isEven;
  }

  if (parts.length > 1 && !parts.every(balanced)) {
    return null;
  }
  return parts;
}

enum _DartSlot {
  integer('int'),

  number('double'),

  flag('bool'),
  text('String'),
  list('List'),

  untyped('dynamic'),
  absent('Null'),
  opaque('Object?');

  const _DartSlot(this.source);

  final String source;

  bool get isScalar => const {integer, number, flag, text}.contains(this);
}

(_DartSlot, String)? _scalarType(SeqVariable v) => switch (v.raw.valueClass) {
  SeqValueClass.number => (_DartSlot.number, '0'),
  SeqValueClass.boolean => (_DartSlot.flag, 'false'),
  SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path => (_DartSlot.text, "''"),
  _ => null,
};

bool _isArrayVar(SeqVariable v) => v.raw.array != null || (v.raw.valueClass?.isArray ?? false);

String _escape(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll(r'$', r'\$')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');

String _scalarInit(SeqVariable v, _DartSlot type, String zero) {
  final value = v.value;
  if (value == null) return zero;
  switch (type) {
    case _DartSlot.integer:
      final i = num.tryParse(value);
      return i == null ? zero : i.toInt().toString();
    case _DartSlot.number:
      final n = _parseTsNum(value);
      if (n == null) return zero;
      return _numLiteral(n);
    case _DartSlot.flag:
      final lower = value.toLowerCase();
      if (lower == 'true') return 'true';
      if (lower == 'false') return 'false';
      return zero;
    default:
      return "'${_escape(value)}'";
  }
}

_DartSlot _stubParamType(SeqVariable p) {
  final scalar = _scalarType(p);
  if (scalar != null) return scalar.$1;
  return _isArrayVar(p) ? _DartSlot.list : _DartSlot.untyped;
}

String _stubParamDecl(SeqVariable p, String id) {
  final scalar = _scalarType(p);
  if (scalar != null) {
    final (type, zero) = scalar;
    return '${type.source} $id = ${_scalarInit(p, type, zero)}';
  }
  if (_isArrayVar(p)) return 'List<dynamic>? $id';
  return 'dynamic $id';
}

bool _isVariablePath(String raw) => RegExp(
  r'^(Locals|Parameters|FileGlobals|StationGlobals|RunState)'
  r'(\.[A-Za-z_][A-Za-z0-9_]*(\[[0-9]+\])?)+$',
  caseSensitive: false,
).hasMatch(raw.trim());

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
  final SeqAdapter adapter;
  final String target;
  final String firstStepName;

  final Map<String, String> _idOf = {};
  final Set<String> _takenIds = {};

  final Map<String, SeqVariable> _protoVarOf = {};

  List<String>? _protoShape;
  bool _agree = true;

  bool get typed => _agree && _protoShape != null;

  String _claim(String display) =>
      _idOf.putIfAbsent(display.toLowerCase(), () => _uniqueName(dartIdentifier(display), _takenIds));

  void note(StepModule module) {
    final proto = module.prototypeParameters;
    if (proto.isNotEmpty) {
      final shape = [for (final p in proto) '${p.name.toLowerCase()}|${p.raw.className}'];
      if (_protoShape == null) {
        _protoShape = shape;
      } else if (_protoShape!.join('\u0000') != shape.join('\u0000')) {
        _agree = false;
      }
      for (final p in proto) {
        _claim(p.name);
        _protoVarOf.putIfAbsent(p.name.toLowerCase(), () => p);
      }
    } else if (module.sequenceArguments.isNotEmpty) {
      _agree = false;
    }
    for (final a in module.sequenceArguments) {
      _claim(a.name);
    }
  }

  Map<String, ({String id, _DartSlot type})> paramTableFor(StepModule module) {
    final proto = module.prototypeParameters;
    if (proto.isNotEmpty) {
      return {
        for (final p in proto) p.name.toLowerCase(): (id: _idOf[p.name.toLowerCase()]!, type: _stubParamType(p)),
      };
    }
    return {
      for (final a in module.sequenceArguments)
        if (_idOf.containsKey(a.name.toLowerCase()))
          a.name.toLowerCase(): (id: _idOf[a.name.toLowerCase()]!, type: _DartSlot.untyped),
    };
  }

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

typedef _ResolvedCall = ({String fn, _SeqScope scope});

class _SeqScope {
  _SeqScope({
    required this.emittedParams,
    required this.emittedLocals,
    required this.paramIds,
    required this.localIds,
    required this.idTypes,
    required this.writtenParams,
  });

  final List<SeqVariable> emittedParams;
  final List<SeqVariable> emittedLocals;

  final Map<String, String> paramIds;
  final Map<String, String> localIds;

  final Map<String, _DartSlot> idTypes;

  final Set<String> writtenParams;

  late final Map<String, String> paramIdOfLower = {
    for (final e in paramIds.entries) e.key.toLowerCase(): e.value,
  };

  late final Set<String> allIds = {...paramIds.values, ...localIds.values};
}

List<_SeqScope> _sequenceScopeTable(SeqFile file, Set<String> taken, {String? sourceName}) {
  final scopes = <_SeqScope>[];
  for (final sequence in file.sequences) {
    final used = <String>{...taken};
    final seenParams = <String>{};
    final emittedParams = [
      for (final p in sequence.parameters)
        if (seenParams.add(p.name)) p,
    ];
    final paramIds = {for (final p in emittedParams) p.name: _uniqueName(dartIdentifier(p.name), used)};
    final seenLocals = <String>{};
    final emittedLocals = [
      for (final local in sequence.locals)
        // ResultList is an implicit engine local, not user state.
        if (local.name != 'ResultList' && seenLocals.add(local.name)) local,
    ];
    final localIds = {for (final l in emittedLocals) l.name: _uniqueName(dartIdentifier(l.name), used)};
    _DartSlot typeOf(SeqVariable v) {
      final scalar = _scalarType(v);
      if (scalar != null) return scalar.$1;
      return _isArrayVar(v) ? _DartSlot.list : _DartSlot.untyped;
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
  final byValue = {
    for (final p in sequence.parameters)
      if (!p.passesByReference) p.name.toLowerCase(),
  };
  return names.difference(byValue);
}

void _refineIntTypes(SeqFile file, List<_SeqScope> scopes, String? sourceName) {
  bool integralDefault(SeqVariable v) {
    final value = v.value;
    if (value == null) return true;
    final n = num.tryParse(value);
    return n != null && n % 1 == 0 && n.abs() < _maxExactIntDouble;
  }

  final candidates = <(_SeqScope, String)>{};
  for (final scope in scopes) {
    void seed(List<SeqVariable> list, Map<String, String> ids) {
      for (final v in list) {
        final id = ids[v.name];
        if (id != null && scope.idTypes[id] == _DartSlot.number && integralDefault(v)) {
          candidates.add((scope, id));
        }
      }
    }

    seed(scope.emittedParams, scope.paramIds);
    seed(scope.emittedLocals, scope.localIds);
  }
  if (candidates.isEmpty) return;

  final scopeByName = <String, _SeqScope>{};
  for (var i = 0; i < scopes.length; i++) {
    scopeByName.putIfAbsent(file.sequences[i].name, () => scopes[i]);
  }

  String? idOf(_SeqScope s, String root, String name) =>
      root.toLowerCase() == 'locals' ? s.localIds[name] : s.paramIds[name];

  final refRe = RegExp(r'(Locals|Parameters)\.([A-Za-z_][A-Za-z0-9_]*)', caseSensitive: false);
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
      } else if (target.idTypes[id] == _DartSlot.number && rhs != null) {
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
    scope.idTypes[id] = _DartSlot.integer;
  }
}

String _withoutUnusedImport(String source, String importLine, RegExp usage) {
  final stripped = source.replaceFirst(importLine, '');
  return usage.hasMatch(_withoutLineComments(stripped)) ? source : stripped;
}

String _withoutLineComments(String source) {
  final sb = StringBuffer();
  for (final line in source.split('\n')) {
    var inString = false;
    var cut = line.length;
    for (var i = 0; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      if (inString && c == 0x5C /* \ */ ) {
        i++;
      } else if (c == 0x27 /* ' */ ) {
        inString = !inString;
      } else if (!inString && c == 0x2F /* / */ && i + 1 < line.length && line.codeUnitAt(i + 1) == 0x2F) {
        cut = i;
        break;
      }
    }
    sb.writeln(line.substring(0, cut));
  }
  return sb.toString();
}

/// 2^53, above which a double no longer represents every integer exactly.
const int _maxExactIntDouble = 9007199254740992;

String _numLiteral(num n) => switch (n) {
  _ when n.isNaN => 'double.nan',
  _ when n.isInfinite => n > 0 ? 'double.infinity' : '-double.infinity',
  int() when n.abs() < _maxExactIntDouble => n.toString(),
  _ => n.toDouble().toString(),
};

const _nonFiniteSpellings = {'NaN': double.nan, 'Inf': double.infinity, '-Inf': double.negativeInfinity};

num? _parseNumberScalar(String text) => num.tryParse(text) ?? _nonFiniteSpellings[text.trim()];

num? _parseTsNum(String text) {
  final t = text.trim();
  final direct = _parseNumberScalar(t);
  if (direct != null) return direct;
  final m = RegExp(r'^-?(\d+|0[xX][0-9a-fA-F]+)u?i64$').firstMatch(t);
  if (m == null) return null;
  final digits = num.tryParse(m.group(1)!);
  return digits == null ? null : (t.startsWith('-') ? -digits : digits);
}

String _comment(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' | ').trim();

String _unportableFieldLine(String name) =>
    '// not a Dart field name — reachable only by porting its uses: ${_comment(name)}';

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

const _variableRoots = {
  'FileGlobals': 'fileGlobals',
  'StationGlobals': 'stationGlobals',
  'RunState': 'runState',
  'Step': 'step',
};

typedef _Code = ({String code, _DartSlot type, int prec});

/// Dart operator precedence levels, lowest first, that decide where translated code needs parentheses.
abstract final class _Prec {
  static const assignment = 1;
  static const conditional = 2;
  static const ifNull = 3;
  static const or = 4;
  static const and = 5;
  static const equality = 6;
  static const relational = 7;
  static const bitOr = 8;
  static const bitXor = 9;
  static const bitAnd = 10;
  static const shift = 11;
  static const additive = 12;
  static const multiplicative = 13;
  static const prefix = 14;
  static const primary = 16;
}

/// An expression-language function with a runtime counterpart in the shim library.
enum _SeqFunction {
  len('Len', 'len', 1, 1, _DartSlot.number),
  getNumElements('GetNumElements', 'getNumElements', 1, 2, _DartSlot.number),
  setNumElements('SetNumElements', 'setNumElements', 2, 3, _DartSlot.opaque),
  str('Str', 'str', 1, 4, _DartSlot.text),
  left('Left', 'left', 2, 2, _DartSlot.text),
  right('Right', 'right', 2, 2, _DartSlot.text),
  mid('Mid', 'mid', 2, 3, _DartSlot.text),
  find('Find', 'find', 2, 3, _DartSlot.number),
  random('Random', 'rand', 0, 2, _DartSlot.number),
  checkLimits('CheckLimits', 'checkLimits', 4, 7, _DartSlot.text),
  checkStrLimit('CheckStrLimit', 'checkStrLimit', 3, 4, _DartSlot.text),

  /// True when every argument is true; lowered to `&&` when no argument has side effects.
  allOf('AllOf', '', 1, 1 << 16, _DartSlot.flag),

  /// True when any argument is true; lowered to `||` when no argument has side effects.
  anyOf('AnyOf', '', 1, 1 << 16, _DartSlot.flag),

  /// Evaluates an expression given as a string; lowered when the string is a literal.
  evaluate('Evaluate', '', 1, 1, _DartSlot.untyped);

  const _SeqFunction(this.name, this.dart, this.minArgs, this.maxArgs, this.result);
  final String name;
  final String dart;
  final int minArgs;
  final int maxArgs;
  final _DartSlot result;
  static final Map<String, _SeqFunction> byName = {for (final f in values) f.name: f};
}

typedef _OpenBlock = ({FlowKind kind, String? increment, String? condition, int selectId});

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

  final SeqExportStats _stats;

  final Set<String> stationGlobalNames;
  final bool hostStationGlobals;
  final String stationGlobalsHome;

  final String? registerName;
  final List<String> extraImports;
  final _ResolvedCall? Function(StepModule module)? resolveExternalCall;
  final Set<String> externallyCalled;

  final SeqFile file;
  final String? sourceName;

  final bool asTest;

  final Map<String, Set<String>> _seqUnported = {};

  String? _currentSeq;

  Set<String> _usedIds = {};

  String _claimId(String base) => _uniqueName(base, _usedIds);

  Map<String, String> _localIds = const {};
  Map<String, String> _paramIds = const {};

  Map<String, _DartSlot> _idTypes = const {};

  Sequence? _sequence;

  String _runId = 'run';

  Map<SeqProperty, String> _resultVars = Map.identity();

  Step? _foldStep;

  String? _foldResult;

  int _loopDepth = 0;

  void _markUnported(String target) {
    final seq = _currentSeq;
    if (seq != null) (_seqUnported[seq] ??= {}).add(target);
  }

  final StringBuffer _out = StringBuffer();
  int _indent = 1;

  final Set<String> _topLevelNames = {};

  final Map<String, String> _sequenceFnNames = {};

  final Map<(SeqAdapter, String), _StubInfo> _stubs = {};

  late final Map<String, String> _typePreconditions = {
    for (final t in file.typeDefs)
      if ((t.raw.prop('TS')?.prop('PreCond')?.scalar ?? '').isNotEmpty)
        t.name: t.raw.prop('TS')!.prop('PreCond')!.scalar!,
  };

  void _line(String text) {
    if (asTest && text.isNotEmpty) _scanHazards(text);
    _out.writeln(text.isEmpty ? '' : '${'  ' * _indent}$text');
  }

  static final Map<RegExp, String> _hazards = {
    RegExp(r'ts\.(?:eval|cond)\('): 'untranslated expression in body',
    RegExp(r'(?<![\w\$.])runState(?![\w\$])'): 'RunState engine access (no engine at run time)',
    RegExp(r'(?<![\w\$.])step\.'): 'Step engine access (no engine at run time)',
  };

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

  String _uniqueTopLevel(String base) {
    var name = _uniqueName(base, _topLevelNames);
    while (_allScopeIds.contains(name)) {
      name = _uniqueName(base, _topLevelNames);
    }
    return name;
  }

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

  String _expr(String raw) {
    if (raw.trim().isEmpty) return "''";
    return _translate(raw)?.code ?? _evalFallback(raw);
  }

  String _evalFallback(String raw) => "ts.eval('${_escape(raw)}')";

  _Code? _translate(String raw) {
    final parsed = parseSeqExpression(raw);
    return parsed == null || parsed is SeqSequence ? null : _emit(parsed);
  }

  String _cond(String raw) {
    final translated = _translate(raw);
    final condition = translated == null ? null : _asBool(translated);
    return condition?.code ?? "ts.cond('${_escape(raw)}')";
  }

  String _numeric(String raw) {
    final translated = _translate(raw);
    return translated != null &&
            const {_DartSlot.integer, _DartSlot.number, _DartSlot.untyped}.contains(translated.type)
        ? translated.code
        : _evalFallback(raw);
  }

  static const _dartReservedWords = {
    'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum', //
    'extends', 'false', 'final', 'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', //
    'super', 'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
  };

  _Code _wrap(_Code c, int min) => c.prec >= min ? c : (code: '(${c.code})', type: c.type, prec: _Prec.primary);

  _Code? _asBool(_Code c) => switch (c.type) {
    _DartSlot.flag => c,
    _DartSlot.integer ||
    _DartSlot.number => (code: '${_wrap(c, _Prec.relational).code} != 0', type: _DartSlot.flag, prec: _Prec.equality),
    _DartSlot.untyped => (code: 'ts.truthy(${c.code})', type: _DartSlot.flag, prec: _Prec.primary),
    _ => null,
  };

  _Code? _coerce(_Code value, _DartSlot target) {
    if (target == _DartSlot.untyped || value.type == target || value.type == _DartSlot.untyped) return value;
    if (target == _DartSlot.number && value.type == _DartSlot.integer) {
      return RegExp(r'^\d+$').hasMatch(value.code)
          ? value
          : (code: '${_wrap(value, _Prec.primary).code}.toDouble()', type: _DartSlot.number, prec: _Prec.primary);
    }
    return null;
  }

  static bool _isNumeric(_DartSlot t) => t == _DartSlot.integer || t == _DartSlot.number;

  String? _rootOf(String name) => switch (name.toLowerCase()) {
    'locals' => 'Locals',
    'parameters' => 'Parameters',
    'fileglobals' => 'FileGlobals',
    'stationglobals' => 'StationGlobals',
    'runstate' => 'RunState',
    'step' => 'Step',
    _ => null,
  };

  String? _idIn(Map<String, String> ids, String name) {
    final exact = ids[name];
    if (exact != null) return exact;
    final lower = name.toLowerCase();
    final matches = [
      for (final e in ids.entries)
        if (e.key.toLowerCase() == lower) e.value,
    ];
    return matches.length == 1 ? matches.single : null;
  }

  _Code? _emitRooted(String root, String name) {
    _Code typed(String code, _DartSlot? type) => (code: code, type: type ?? _DartSlot.untyped, prec: _Prec.primary);
    switch (root) {
      case 'Locals' || 'Parameters':
        final id = _idIn(root == 'Locals' ? _localIds : _paramIds, name);
        return id == null ? null : typed(id, _idTypes[id]);
      case 'FileGlobals':
        final declared = _fileGlobalCanon[name.toLowerCase()];
        return declared == null ? null : typed('fileGlobals.$declared', _fileGlobalTypes[declared]);
      case 'StationGlobals':
        final declared = _stationGlobalCanon[name.toLowerCase()];
        return declared == null ? null : typed('stationGlobals.$declared', null);
      case 'Step' when name.toLowerCase() == 'result' && _foldResult != null:
        return typed(_foldResult!, null);
      case 'RunState' when name.toLowerCase() == 'sequencefailed':
        return typed('$_runId.failed', _DartSlot.flag);
      default:
        return _dartReservedWords.contains(name) ? null : typed('${_variableRoots[root]}.$name', null);
    }
  }

  static final _stepSelfWrite = RegExp(
    r'(?<![\w.])Step\.(?!Result\b)[A-Za-z_][\w.]*(?:\[[^\]]*\])*\s*[-+*/%&|^]?=(?!=)',
    caseSensitive: false,
  );
  static final _stepReference = RegExp(r'(?<![\w.])Step\.(?!Result\b)', caseSensitive: false);

  final Map<SeqProperty, bool> _foldableSteps = Map.identity();

  bool _foldable(Step step) => _foldableSteps.putIfAbsent(step.raw, () {
    final settings = step.settings;
    final expressions = [
      settings.precondition,
      settings.preExpression,
      settings.postExpression,
      settings.statusExpression,
      settings.customExpression,
    ].nonNulls;
    if (expressions.any(_stepSelfWrite.hasMatch)) return false;
    final module = step.module;
    final bindings = [
      for (final p in [...module.viParameters, ...module.callParameters]) p.boundExpression,
      for (final call in module.dotNetCalls)
        for (final p in call.parameters) p.boundExpression,
      for (final a in module.sequenceArguments) a.expression,
    ].nonNulls;
    return !bindings.any(_stepReference.hasMatch);
  });

  SeqProperty? _stepLeaf(SeqExpr e) {
    final step = _foldStep;
    final path = <String>[];
    var at = e;
    while (at is SeqMember) {
      path.insert(0, at.name.toLowerCase());
      at = at.target;
    }
    if (step == null || at is! SeqName || at.name.toLowerCase() != 'step' || path.isEmpty || path.first == 'result') {
      return null;
    }
    final limits = step.limits;
    if (path.length == 2 && path.first == 'limits') {
      if (path.last == 'low' && limits?.usesLowExpression == true) return null;
      if (path.last == 'high' && limits?.usesHighExpression == true) return null;
    }
    if (!_foldable(step)) return null;
    SeqProperty? node = step.raw;
    for (final name in path) {
      node = node?.subProps.where((c) => c.name.toLowerCase() == name).firstOrNull;
    }
    final cls = node?.valueClass;
    return node != null &&
            node.isLeaf &&
            node.scalar != null &&
            cls != null &&
            cls.isLeaf &&
            cls != SeqValueClass.reference
        ? node
        : null;
  }

  _Code? _foldedStepProperty(SeqExpr e) {
    final leaf = _stepLeaf(e);
    if (leaf == null) return null;
    final scalar = leaf.scalar!;
    switch (leaf.valueClass) {
      case SeqValueClass.number:
        final n = _parseNumberScalar(scalar);
        if (n == null || !n.isFinite) return null;
        return (
          code: _numLiteral(n),
          type: n is int ? _DartSlot.integer : _DartSlot.number,
          prec: n < 0 ? _Prec.prefix : _Prec.primary,
        );
      case SeqValueClass.boolean:
        final flag = parseFlag(scalar);
        return flag == null ? null : (code: '$flag', type: _DartSlot.flag, prec: _Prec.primary);
      default:
        return (code: "'${_escape(scalar)}'", type: _DartSlot.text, prec: _Prec.primary);
    }
  }

  _Code? _stepResultRef(SeqIndex e) {
    final sequence = _sequence;
    final group = e.target;
    final key = e.index;
    if (sequence == null || key is! SeqString || group is! SeqMember) return null;
    final owner = group.target;
    if (owner is! SeqMember || owner.name.toLowerCase() != 'sequence') return null;
    final root = owner.target;
    if (root is! SeqName || root.name.toLowerCase() != 'runstate') return null;
    final stepGroup = StepGroup.values.where((g) => g.key.toLowerCase() == group.name.toLowerCase()).firstOrNull;
    if (stepGroup == null) return null;
    final matches = [
      for (final step in sequence.stepsIn(stepGroup))
        if (step.name == key.value || step.id == key.value) step,
    ];
    final variable = matches.length == 1 ? _resultVars[matches.single.raw] : null;
    return variable == null ? null : (code: variable, type: _DartSlot.untyped, prec: _Prec.primary);
  }

  static final _literalCode = RegExp(r"^(?:true|false|null|-?\d+(?:\.\d+)?|'(?:[^'\\]|\\.)*')$");

  _Code? _emitTarget(SeqExpr e) => switch (e) {
    SeqMember() || SeqIndex() => _emit(e),
    _ => null,
  };

  _Code? _emit(SeqExpr e) {
    switch (e) {
      case SeqNumber(:final value, :final integral):
        return (
          code: integral ? value.toString() : _numLiteral(value.toDouble()),
          type: integral ? _DartSlot.integer : _DartSlot.number,
          prec: _Prec.primary,
        );
      case SeqString(:final value):
        return (code: "'${_escape(value)}'", type: _DartSlot.text, prec: _Prec.primary);
      case SeqBool(:final value):
        return (code: '$value', type: _DartSlot.flag, prec: _Prec.primary);
      case SeqNothing():
        return (code: 'null', type: _DartSlot.absent, prec: _Prec.primary);
      case SeqName() || SeqSequence():
        return null;
      case SeqMember(:final target, :final name):
        final folded = _foldedStepProperty(e);
        if (folded != null) return folded;
        if (target is SeqIndex && name.toLowerCase() == 'result') {
          final ref = _stepResultRef(target);
          if (ref != null) return ref;
        }
        if (target is SeqName) {
          final root = _rootOf(target.name);
          return root == null ? null : _emitRooted(root, name);
        }
        final base = _emit(target);
        if (base == null || base.type != _DartSlot.untyped || _dartReservedWords.contains(name)) return null;
        return (code: '${_wrap(base, _Prec.primary).code}.$name', type: _DartSlot.untyped, prec: _Prec.primary);
      case SeqIndex(:final target, :final index):
        final base = _emit(target);
        final at = _emit(index);
        if (base == null || at == null) return null;
        final indexable =
            (base.type == _DartSlot.list && (at.type == _DartSlot.integer || at.type == _DartSlot.untyped)) ||
            (base.type == _DartSlot.untyped && at.type != _DartSlot.opaque && at.type != _DartSlot.absent);
        if (!indexable) return null;
        return (code: '${_wrap(base, _Prec.primary).code}[${at.code}]', type: _DartSlot.untyped, prec: _Prec.primary);
      case SeqCall(:final callee, :final arguments):
        return _emitCall(callee, arguments);
      case SeqUnary(:final op, :final operand):
        final inner = _emit(operand);
        if (inner == null) return null;
        switch (op) {
          case SeqUnaryOp.not:
            final b = _asBool(inner);
            return b == null
                ? null
                : (code: '!${_wrap(b, _Prec.prefix).code}', type: _DartSlot.flag, prec: _Prec.prefix);
          case SeqUnaryOp.negate || SeqUnaryOp.plus:
            if (!_isNumeric(inner.type) && inner.type != _DartSlot.untyped) return null;
            if (op == SeqUnaryOp.plus) return inner;
            final operand = inner.code.startsWith('-') ? '(${inner.code})' : _wrap(inner, _Prec.prefix).code;
            return (code: '-$operand', type: inner.type, prec: _Prec.prefix);
          case SeqUnaryOp.bitNot:
            if (inner.type != _DartSlot.integer) return null;
            return (code: '~${_wrap(inner, _Prec.prefix).code}', type: _DartSlot.integer, prec: _Prec.prefix);
        }
      case SeqStep(:final target, :final increment, :final prefix):
        final t = _emitTarget(target);
        if (t == null || !(_isNumeric(t.type) || t.type == _DartSlot.untyped)) return null;
        final op = increment ? '++' : '--';
        return (
          code: prefix ? '$op${t.code}' : '${t.code}$op',
          type: t.type,
          prec: prefix ? _Prec.prefix : _Prec.primary,
        );
      case SeqBinary(:final op, :final left, :final right):
        final l = _emit(left);
        final r = _emit(right);
        return l == null || r == null ? null : _emitBinary(op, l, r);
      case SeqConditional(:final condition, :final whenTrue, :final whenFalse):
        final c = _emit(condition);
        final cb = c == null ? null : _asBool(c);
        var t = _emit(whenTrue);
        var f = _emit(whenFalse);
        if (cb == null || t == null || f == null) return null;
        if (cb.code == 'true') return t;
        if (cb.code == 'false') return f;
        _DartSlot type;
        if (t.type == f.type) {
          type = t.type;
        } else if (t.type == _DartSlot.untyped || f.type == _DartSlot.untyped) {
          type = _DartSlot.untyped;
        } else if (_isNumeric(t.type) && _isNumeric(f.type)) {
          type = _DartSlot.number;
          t = _coerce(t, type)!;
          f = _coerce(f, type)!;
        } else {
          type = _DartSlot.opaque;
        }
        return (
          code: '${_wrap(cb, _Prec.ifNull).code} ? ${_wrap(t, _Prec.ifNull).code} : ${_wrap(f, _Prec.ifNull).code}',
          type: type,
          prec: _Prec.conditional,
        );
      case SeqAssign(:final op, :final target, :final value):
        final t = _emitTarget(target);
        final v = _emit(value);
        if (t == null || v == null) return null;
        final binary = op.binary;
        if (binary == null) {
          final coerced = _coerce(v, t.type);
          if (coerced == null) return null;
          return (code: '${t.code} = ${_wrap(coerced, _Prec.assignment).code}', type: t.type, prec: _Prec.assignment);
        }
        final combined = _emitBinary(binary, t, v);
        if (combined == null || _coerce(combined, t.type) != combined) return null;
        if (binary == SeqBinaryOp.modulo) {
          return (code: '${t.code} = ${combined.code}', type: t.type, prec: _Prec.assignment);
        }
        return (code: '${t.code} ${op.token} ${_wrap(v, _Prec.assignment).code}', type: t.type, prec: _Prec.assignment);
      case SeqArray(:final elements):
        final items = [for (final element in elements) _emit(element)];
        if (items.contains(null)) return null;
        return (code: '<dynamic>[${items.map((i) => i!.code).join(', ')}]', type: _DartSlot.list, prec: _Prec.primary);
    }
  }

  _Code? _emitBinary(SeqBinaryOp op, _Code l, _Code r) {
    _Code out(String code, _DartSlot type, int prec) => (code: code, type: type, prec: prec);
    String infix(int prec) => '${_wrap(l, prec).code} ${op.token} ${_wrap(r, prec + 1).code}';
    final dyn = l.type == _DartSlot.untyped || r.type == _DartSlot.untyped;
    final numeric = _isNumeric(l.type) && _isNumeric(r.type);
    final bothInt = l.type == _DartSlot.integer && r.type == _DartSlot.integer;
    bool operable({required bool text}) {
      if (numeric) return true;
      if (!dyn) return false;
      final other = l.type == _DartSlot.untyped ? r.type : l.type;
      return _isNumeric(other) || other == _DartSlot.untyped || (text && other == _DartSlot.text);
    }

    _DartSlot arithmetic() => l.type == _DartSlot.untyped
        ? _DartSlot.untyped
        : dyn
        ? _DartSlot.opaque
        : bothInt
        ? _DartSlot.integer
        : _DartSlot.number;
    switch (op) {
      case SeqBinaryOp.or || SeqBinaryOp.and:
        final lb = _asBool(l);
        final rb = _asBool(r);
        if (lb == null || rb == null) return null;
        final absorbing = op == SeqBinaryOp.or ? 'true' : 'false';
        final neutral = op == SeqBinaryOp.or ? 'false' : 'true';
        if (lb.code == neutral) return rb;
        if (rb.code == neutral) return lb;
        if (lb.code == absorbing) return lb;
        final prec = op == SeqBinaryOp.or ? _Prec.or : _Prec.and;
        return out('${_wrap(lb, prec).code} ${op.token} ${_wrap(rb, prec + 1).code}', _DartSlot.flag, prec);
      case SeqBinaryOp.equal || SeqBinaryOp.notEqual:
        if (_literalCode.hasMatch(l.code) &&
            _literalCode.hasMatch(r.code) &&
            l.type == r.type &&
            l.type != _DartSlot.absent) {
          final same = l.type == _DartSlot.text || l.type == _DartSlot.flag
              ? l.code == r.code
              : num.parse(l.code) == num.parse(r.code);
          return out('${same == (op == SeqBinaryOp.equal)}', _DartSlot.flag, _Prec.primary);
        }
        return out(
          '${_wrap(l, _Prec.relational).code} ${op.token} ${_wrap(r, _Prec.relational).code}',
          _DartSlot.flag,
          _Prec.equality,
        );
      case SeqBinaryOp.less || SeqBinaryOp.lessEqual || SeqBinaryOp.greater || SeqBinaryOp.greaterEqual:
        if (!operable(text: false)) return null;
        return out(
          '${_wrap(l, _Prec.bitOr).code} ${op.token} ${_wrap(r, _Prec.bitOr).code}',
          _DartSlot.flag,
          _Prec.relational,
        );
      case SeqBinaryOp.add:
        if (l.type == _DartSlot.text && (r.type == _DartSlot.text || r.type == _DartSlot.untyped)) {
          return out(infix(_Prec.additive), _DartSlot.text, _Prec.additive);
        }
        if (!operable(text: true)) return null;
        return out(infix(_Prec.additive), arithmetic(), _Prec.additive);
      case SeqBinaryOp.subtract || SeqBinaryOp.multiply || SeqBinaryOp.divide:
        if (!operable(text: false)) return null;
        final prec = op == SeqBinaryOp.subtract ? _Prec.additive : _Prec.multiplicative;
        final type = op == SeqBinaryOp.divide && numeric ? _DartSlot.number : arithmetic();
        return out(infix(prec), type, prec);
      case SeqBinaryOp.modulo:
        if (!numeric) return null;
        return out('${_wrap(l, _Prec.primary).code}.remainder(${r.code})', arithmetic(), _Prec.primary);
      case SeqBinaryOp.bitAnd ||
          SeqBinaryOp.bitOr ||
          SeqBinaryOp.bitXor ||
          SeqBinaryOp.shiftLeft ||
          SeqBinaryOp.shiftRight:
        if (!bothInt) return null;
        final prec = switch (op) {
          SeqBinaryOp.bitAnd => _Prec.bitAnd,
          SeqBinaryOp.bitXor => _Prec.bitXor,
          SeqBinaryOp.bitOr => _Prec.bitOr,
          _ => _Prec.shift,
        };
        return out(infix(prec), _DartSlot.integer, prec);
    }
  }

  _Code? _emitCall(SeqExpr callee, List<SeqExpr> arguments) {
    if (callee is SeqMember) {
      final base = callee.target is SeqName ? null : _emit(callee.target);
      if (base == null || base.type != _DartSlot.untyped || _dartReservedWords.contains(callee.name)) return null;
      final args = [for (final a in arguments) _emit(a)];
      if (args.any((a) => a == null)) return null;
      return (
        code: '${_wrap(base, _Prec.primary).code}.${callee.name}(${args.map((a) => a!.code).join(', ')})',
        type: _DartSlot.untyped,
        prec: _Prec.primary,
      );
    }
    if (callee is! SeqName) return null;
    final function = _SeqFunction.byName[callee.name];
    if (function == null || arguments.length < function.minArgs || arguments.length > function.maxArgs) return null;
    if (function == _SeqFunction.evaluate) {
      final source = arguments.single;
      final text = source is SeqString ? source.value : _stepLeaf(source)?.scalar;
      if (text == null) return null;
      final parsed = parseSeqExpression(text);
      return parsed == null || parsed is SeqSequence ? null : _emit(parsed);
    }
    final args = [for (final a in arguments) _emit(a)];
    if (args.any((a) => a == null)) return null;
    final codes = [for (final a in args) a!];
    if (function == _SeqFunction.allOf || function == _SeqFunction.anyOf) {
      if (arguments.any(_hasEffects)) return null;
      final bools = [for (final c in codes) _asBool(c)];
      if (bools.any((b) => b == null)) return null;
      final prec = function == _SeqFunction.allOf ? _Prec.and : _Prec.or;
      final joiner = function == _SeqFunction.allOf ? ' && ' : ' || ';
      return (code: bools.map((b) => _wrap(b!, prec + 1).code).join(joiner), type: _DartSlot.flag, prec: prec);
    }
    if (function == _SeqFunction.random && codes.any((c) => !_isNumeric(c.type) && c.type != _DartSlot.untyped)) {
      return null;
    }
    final name = function == _SeqFunction.random && asTest ? 'lw.rand' : 'ts.${function.dart}';
    return (code: '$name(${codes.map((c) => c.code).join(', ')})', type: function.result, prec: _Prec.primary);
  }

  static bool _hasEffects(SeqExpr e) => switch (e) {
    SeqCall(:final callee, :final arguments) =>
      callee is! SeqName ||
          !const {
            _SeqFunction.len,
            _SeqFunction.getNumElements,
            _SeqFunction.str,
            _SeqFunction.left,
            _SeqFunction.right,
            _SeqFunction.mid,
            _SeqFunction.find,
            _SeqFunction.allOf,
            _SeqFunction.anyOf,
          }.contains(_SeqFunction.byName[callee.name]) ||
          arguments.any(_hasEffects),
    SeqAssign() || SeqStep() => true,
    SeqMember(:final target) => _hasEffects(target),
    SeqIndex(:final target, :final index) => _hasEffects(target) || _hasEffects(index),
    SeqUnary(:final operand) => _hasEffects(operand),
    SeqBinary(:final left, :final right) => _hasEffects(left) || _hasEffects(right),
    SeqConditional(:final condition, :final whenTrue, :final whenFalse) =>
      _hasEffects(condition) || _hasEffects(whenTrue) || _hasEffects(whenFalse),
    SeqArray(:final elements) => elements.any(_hasEffects),
    SeqSequence() => true,
    _ => false,
  };

  void _emitSequence(Sequence sequence, _SeqScope scope) {
    final fnName = _sequenceFnNames[sequence.name]!;
    _out.writeln(
      '/// Sequence `${_comment(sequence.name)}`'
      '${sequence.comment != null ? ' — ${_comment(sequence.comment!)}' : ''}.',
    );

    _currentSeq = sequence.name;
    _usedIds = <String>{..._topLevelNames, ...scope.allIds};
    final emittedParams = scope.emittedParams;
    _paramIds = scope.paramIds;
    final emittedLocals = scope.emittedLocals;
    _localIds = scope.localIds;
    _idTypes = scope.idTypes;

    final params = [
      for (final p in emittedParams) _paramDecl(p, _paramIds[p.name]!),
    ];
    _out.writeln(
      'Future<String> $fnName('
      '${params.isEmpty ? '' : '{${params.join(', ')}}'}) async {',
    );
    _indent = 1;
    _sequence = sequence;
    _runId = _claimId('run');
    _resultVars = _trackedResults(sequence);

    var arrayPreamble = false;
    for (final p in emittedParams) {
      if (_scalarType(p) == null && _isArrayVar(p)) {
        _line('${_paramIds[p.name]!} ??= ${_arrayInit(p)};${_typeComment(p)}');
        arrayPreamble = true;
      }
    }
    if (arrayPreamble) _line('');

    for (final local in emittedLocals) {
      _line(_localDecl(local, _localIds[local.name]!));
    }
    if (emittedLocals.isNotEmpty) _line('');
    _line('final $_runId = ts.SequenceRun();');
    for (final step in sequence.steps) {
      final variable = _resultVars[step.raw];
      if (variable != null) _line('dynamic $variable = ${_resultInit(step)}; // result of ${_comment(step.name)}');
    }
    _line('');

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
    _line('return $_runId.status;');
    _indent = 0;
    _out
      ..writeln('}')
      ..writeln();
    _currentSeq = null;
    _sequence = null;
    _resultVars = Map.identity();
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

  (_DartSlot, String, String)? _scalarDecl(SeqVariable v, String id) {
    final scalar = _scalarType(v);
    if (scalar == null) return null;
    var (type, zero) = scalar;
    if (type == _DartSlot.number && _idTypes[id] == _DartSlot.integer) type = _DartSlot.integer;
    return (type, zero, _scalarInit(v, type, zero));
  }

  String _paramDecl(SeqVariable p, String id) {
    final scalar = _scalarDecl(p, id);
    if (scalar != null) {
      final (type, _, init) = scalar;
      return '${type.source} $id = $init';
    }
    if (_isArrayVar(p)) return 'List<dynamic>? $id';
    return 'dynamic $id';
  }

  String _localDecl(SeqVariable local, String id) {
    final scalar = _scalarDecl(local, id);
    if (scalar != null) {
      final (type, zero, init) = scalar;
      final fellBack = local.value != null && init == zero && type != _DartSlot.text;
      return '${type.source} $id = $init;'
          '${_typeComment(local, rawDefault: fellBack ? local.value : null)}';
    }
    if (_isArrayVar(local)) {
      return 'List<dynamic> $id = ${_arrayInit(local)};${_typeComment(local)}';
    }
    final cls = local.raw.valueClass;
    if (cls == SeqValueClass.reference || (cls == null && local.raw.subProps.isEmpty)) {
      return 'dynamic $id = null;${_typeComment(local)}';
    }
    return 'dynamic $id = ${_propObjInit(local.raw, {})};'
        '${_typeComment(local)}';
  }

  String _arrayInit(SeqVariable v) => _listInit(v.raw, {});

  void _emitSteps(List<Step> steps) {
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
      'Sweep Loop',
      'End',
      'Break',
      'Continue',
      'Statement',
      'Goto',
    };
    for (final step in steps) {
      final flow = step.flowControl;
      final rawName = _comment(step.name);
      final authorComment = step.comment;
      if (authorComment != null) {
        for (final line in authorComment.split('\n')) {
          _line('// ${_comment(line)}');
        }
      }
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
      var nameNote = defaultFlowNames.contains(rawName) ? '' : ' // $rawName';
      if (modeNote.isNotEmpty) {
        nameNote = nameNote.isEmpty ? ' //$modeNote' : '$nameNote$modeNote';
      }
      if (flow == null) {
        _loopDepth = open.where((o) => loopKinds.contains(o.kind) || o.kind == FlowKind.sweepLoop).length;
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
            open.add(_openBlock(flow.kind));
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
            final parsed = parseSeqExpression(element);
            final target = parsed == null ? null : _emitTarget(parsed);
            if (target == null || target.type == _DartSlot.absent || target.type == _DartSlot.opaque) {
              _line('// TODO: bind loop element: ${_comment(element)} = <element>');
            } else {
              final cast = switch (target.type) {
                _DartSlot.number => '($loopVar as num).toDouble()',
                _DartSlot.integer => '($loopVar as num).toInt()',
                _DartSlot.flag => '$loopVar as bool',
                _DartSlot.text => '$loopVar as String',
                _DartSlot.list => '$loopVar as List<dynamic>',
                _ => loopVar,
              };
              _line('${target.code} = $cast;');
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
        case FlowKind.sweepLoop:
          if (asTest) _markUnported('sweep loop "${step.name}": parameter sweep not exported');
          _line('// TODO: ${_comment(flow.header)} not exported; the body runs once');
          _line('{$nameNote');
          _indent++;
          open.add(_openBlock(flow.kind));
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
          final target = innermost(
            (k) => k == FlowKind.selectBlock || k == FlowKind.sweepLoop || loopKinds.contains(k),
          );
          if (target?.kind == FlowKind.sweepLoop) {
            if (asTest) _markUnported('break out of sweep loop at step "${step.name}" not exported');
            _line('// $rawName: Break out of a sweep loop — kept as a comment');
          } else if (target == null) {
            _line(
              '// $rawName: Break with no enclosing loop/select — kept as a '
              'comment',
            );
          } else {
            final breakStmt = target.kind == FlowKind.selectBlock ? 'break sel${target.selectId};' : 'break;';
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
          final loop = innermost((k) => k == FlowKind.sweepLoop || loopKinds.contains(k));
          if (loop?.kind == FlowKind.sweepLoop) {
            if (asTest) _markUnported('continue in sweep loop at step "${step.name}" not exported');
            _line('// $rawName: Continue in a sweep loop — kept as a comment');
          } else if (loop == null) {
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
    while (open.isNotEmpty) {
      closeBlock(open.removeLast(), note: ' // closed: unbalanced block in source');
    }
  }

  String _exprStatement(String raw) {
    if (_stripComments(raw).trim().isEmpty) return "''";
    final parsed = parseSeqExpression(raw);
    final translated = parsed == null || parsed is SeqSequence ? null : _emit(parsed);
    return translated?.code ?? _evalFallback(raw);
  }

  List<String> _stmtParts(String raw) {
    final pieces = _rawStmtPieces(raw);
    if (pieces == null) return [_exprStatement(raw)];
    final out = <String>[
      for (final p in pieces)
        if (p.trim().isNotEmpty) _exprStatement(p),
    ];
    return out.isEmpty ? [_exprStatement(raw)] : out;
  }

  bool _emitStmt(String raw, String note) {
    final parts = [
      for (final part in _stmtParts(raw))
        if (!_literalCode.hasMatch(part)) part,
    ];
    for (var i = 0; i < parts.length; i++) {
      final suffix = note.isEmpty ? '' : (i == 0 ? ' // $note' : ' // $note (cont.)');
      _line('${parts[i]};$suffix');
    }
    return parts.isNotEmpty;
  }

  List<String> _stepPayloadNotes(Step step) {
    final notes = <String>[];
    final settings = step.settings;

    final limits = step.limits;
    String? bound(String label, String? value, String? expression, bool? usesExpression) {
      final text = usesExpression == true ? (expression ?? value) : (value ?? expression);
      return text == null ? null : '$label $text';
    }

    if (limits != null) {
      final bounds = [
        bound('low', limits.low, limits.lowExpression, limits.usesLowExpression),
        bound('high', limits.high, limits.highExpression, limits.usesHighExpression),
        bound('nominal', limits.nominal, limits.nominalExpression, null),
      ].nonNulls.toList();
      final comparison = step.usesComparisonExpression == true
          ? 'comparison by ${limits.comparisonExpression ?? '?'}'
          : limits.comparison;
      notes.add(
        'checks: ${limits.dataSource ?? step.dataSource ?? '(data source unset)'}'
        '${comparison != null ? ' $comparison' : ''}'
        '${bounds.isEmpty ? '' : ' [${bounds.join(', ')}]'}'
        '${limits.thresholdType != null ? ' (${limits.thresholdType})' : ''}'
        '${step.resultUnits != null ? ' ${step.resultUnits}' : ''}',
      );
    } else if (step.dataSource != null) {
      notes.add('checks: ${step.dataSource}${step.resultUnits != null ? ' (${step.resultUnits})' : ''}');
    } else if (step.resultUnits != null) {
      notes.add('result units: ${step.resultUnits}');
    }
    if (settings.statusExpression != null) {
      notes.add('status expression: ${settings.statusExpression}');
    }

    if (settings.isLooping) {
      final parts = [
        if (settings.loopInitialize != null) 'init ${settings.loopInitialize}',
        if (settings.loopWhile != null) 'while ${settings.loopWhile}',
        if (settings.loopIncrement != null) 'increment ${settings.loopIncrement}',
        if (settings.loopStatus != null) 'status ${settings.loopStatus}',
      ];
      notes.add('step loop (${settings.loopType}): ${parts.join('; ')}');
    }

    String jump(String? target) {
      if (target == null) return '';
      final name = target.startsWith('ID#:') ? file.stepNameForId(target) : null;
      return ' -> ${name != null ? 'step "$name"' : target}';
    }

    if (settings.passAction != null && settings.passAction != 'Next') {
      notes.add('on pass: ${settings.passAction}${jump(settings.passActionTarget)}');
    }
    if (settings.failAction != null && settings.failAction != 'Next') {
      notes.add('on fail: ${settings.failAction}${jump(settings.failActionTarget)}');
    }
    if (step.type == 'Goto' && settings.customTrueTarget != null) {
      notes.add('goto${jump(settings.customTrueTarget)}');
    } else if (settings.customExpression != null ||
        settings.customTrueTarget != null ||
        settings.customFalseTarget != null) {
      notes.add(
        'custom flow: if (${settings.customExpression ?? 'True'}) '
        '${settings.customTrueAction ?? 'Next'}${jump(settings.customTrueTarget)}'
        ' else ${settings.customFalseAction ?? 'Next'}${jump(settings.customFalseTarget)}',
      );
    }

    if (settings.ignoresRunTimeErrors == true) notes.add('ignores run-time errors');
    if (settings.failureCausesSequenceFailure == false) {
      notes.add('failure does NOT fail the sequence');
    }
    if (step.suppressesNextResult == true) notes.add("suppresses the next step's result");
    if (settings.usesMutex == true) {
      notes.add('acquires mutex${settings.mutexName != null ? ' ${settings.mutexName}' : ''}');
    }
    if (settings.switchEnabled == true) {
      notes.add(
        'IVI switching: device ${settings.virtualDeviceName ?? '?'}'
        '${settings.routeGroupConnect != null ? ', connect ${settings.routeGroupConnect}' : ''}'
        '${settings.routeGroupDisconnect != null ? ', disconnect ${settings.routeGroupDisconnect}' : ''}',
      );
    }
    if (step.stepType != StepType.wait && step.timeoutEnabled == true && step.timeoutExpression != null) {
      notes.add(
        'timeout: ${step.timeoutExpression} s'
        '${step.errorsOnTimeout == true ? ' (error on timeout)' : ''}',
      );
    }

    if (step.specifiesBySequenceCall == true && step.referencedSequenceCallName != null) {
      notes.add('waits for sequence call step "${step.referencedSequenceCallName}"');
    }
    if (step.threadReferenceExpression != null) {
      notes.add('waits for thread: ${step.threadReferenceExpression}');
    }
    if (step.executionReferenceExpression != null) {
      notes.add('waits for execution: ${step.executionReferenceExpression}');
    }

    if (step.sqlStatement != null) notes.add('SQL: ${step.sqlStatement}');
    if (step.dbConnectionString != null) notes.add('DB connection: ${step.dbConnectionString}');
    if (step.statementHandle != null) notes.add('statement handle: ${step.statementHandle}');
    if (step.databaseHandle != null) notes.add('database handle: ${step.databaseHandle}');
    if (step.numberOfRecordsSelectedExpression != null) {
      notes.add('records selected -> ${step.numberOfRecordsSelectedExpression}');
    }

    if (step.popupTitleExpression != null) notes.add('popup title: ${step.popupTitleExpression}');
    if (step.popupMessageExpression != null) notes.add('popup message: ${step.popupMessageExpression}');
    final buttons = step.popupButtonLabelExpressions;
    if (buttons.isNotEmpty) notes.add('popup buttons: ${buttons.join(' | ')}');
    if (step.popupShowsResponse == true) {
      notes.add(
        'popup collects a response'
        '${step.popupDefaultResponseExpression != null ? ' (default ${step.popupDefaultResponseExpression})' : ''}',
      );
    }

    if (step.executablePath != null) {
      notes.add(
        'runs executable: ${step.executablePath}'
        '${step.executableArguments != null ? ' ${step.executableArguments}' : ''}'
        '${step.executableWaitCondition != null ? ' (${step.executableWaitCondition})' : ''}',
      );
    }

    if (step.syncNameOrReferenceExpression != null) {
      notes.add(
        'sync object: ${step.syncNameOrReferenceExpression}'
        '${step.syncOperationCode != null ? ', operation code ${step.syncOperationCode}' : ''}'
        '${step.syncLifetimeCode != null ? ', lifetime code ${step.syncLifetimeCode}' : ''}'
        '${step.syncCreatesIfMissing == true ? ', created if missing' : ''}',
      );
    }

    if (step.measurementName != null) notes.add('measurement: ${step.measurementName}');
    for (final parameter in step.measurementParameters) {
      final kind = [parameter.direction, parameter.dataType, parameter.typeSpecialization].nonNulls.join(' ');
      notes.add(
        'measurement param: ${parameter.name}'
        '${kind.isEmpty ? '' : ' ($kind)'}'
        '${parameter.value != null ? ' = ${parameter.value}' : ''}',
      );
    }
    if (step.pinMapPath != null) notes.add('pin map: ${step.pinMapPath}');
    if (step.description != null) notes.add('description: ${step.description}');
    return notes;
  }

  void _emitPayloadNotes(Step step) {
    for (final note in _stepPayloadNotes(step)) {
      _stats.payloadNotes++;
      _line('// ${_comment(note)}');
    }
    if (!asTest) return;
    final settings = step.settings;
    if (settings.isLooping) {
      _markUnported('step "${step.name}" loops (${settings.loopType}) — per-step looping not exported');
    }
    final jumps =
        (settings.passAction != null && settings.passAction != 'Next') ||
        (settings.failAction != null && settings.failAction != 'Next') ||
        settings.customTrueTarget != null ||
        settings.customFalseTarget != null;
    if (jumps) {
      _markUnported('flow action of step "${step.name}" (${settings.flowSummary ?? 'custom/goto'}) not exported');
    }
  }

  void _emitPlainStep(Step step) {
    final settings = step.settings;
    final result = _resultVars[step.raw];
    _foldStep = step;
    _foldResult = result;
    _emitPayloadNotes(step);
    final precondition = settings.precondition ?? _typePreconditions[step.type];
    if (precondition != null) {
      _line(
        'if (${_cond(precondition)}) { '
        '// precondition of ${_comment(step.name)}',
      );
      _indent++;
    }
    if (result != null && _loopDepth > 0) _line('$result = ${_resultInit(step)};');

    final pre = settings.preExpression;
    if (pre != null) _emitStmt(pre, 'pre-expression');

    _emitStepAction(step);

    final post = settings.postExpression;
    if (post != null && step.stepType != StepType.statement) {
      _emitStmt(post, 'post-expression');
    }
    final status = settings.statusExpression;
    if (result != null) {
      if (status != null) {
        final pieces = _rawStmtPieces(status) ?? [status];
        for (final piece in pieces.take(pieces.length - 1)) {
          _emitStmt(piece, 'status expression');
        }
        _line('$result.Status = ${_expr(pieces.last)}; // status expression');
      } else if (!_callsExportedSequence(step)) {
        _line("$result.Status = 'Done';");
      }
      if (settings.failureCausesSequenceFailure != false) _line('$_runId.record($result.Status);');
    }

    if (precondition != null) {
      _indent--;
      if (result != null) {
        _line('} else {');
        _line("  $result.Status = 'Skipped';");
      }
      _line('}');
    }
    _foldStep = null;
    _foldResult = null;
  }

  bool _callsExportedSequence(Step step) {
    final module = step.module;
    if (module.adapter != SeqAdapter.sequenceCall) return false;
    final target = module.sequenceName;
    final local =
        module.resolvesLocalCall(ownFilePath: sourceName) && target != null && _sequenceFnNames[target] != null;
    return local || resolveExternalCall?.call(module) != null;
  }

  String _sequenceCallLine(Step step, String call, String note) {
    final result = _resultVars[step.raw];
    if (result != null) return '$result.Status = await $call; // $note';
    if (step.settings.failureCausesSequenceFailure == false) return 'await $call; // $note';
    return '$_runId.record(await $call); // $note';
  }

  String _resultInit(Step step) {
    final raw = step.raw.prop('Result');
    final init = raw == null ? '' : _propObjInit(raw, {});
    return init.startsWith('ts.PropObj({') && raw!.subProps.any((p) => p.name == 'Status')
        ? init
        : "ts.PropObj({'Status': ''})";
  }

  Map<SeqProperty, String> _trackedResults(Sequence sequence) {
    final tracked = <SeqProperty>{};
    final referenced = RegExp(r'RunState\.Sequence\.(Main|Setup|Cleanup)\["((?:[^"\\]|\\.)*)"\]', caseSensitive: false);
    final ownResult = RegExp(r'(?<![\w.])Step\.Result\b', caseSensitive: false);
    final steps = sequence.steps;
    for (final step in steps) {
      final settings = step.settings;
      final expressions = [
        settings.precondition,
        settings.preExpression,
        settings.postExpression,
        settings.statusExpression,
        settings.customExpression,
      ].nonNulls;
      final status = settings.statusExpression;
      if ((status != null && status.trim() != '""') || expressions.any(ownResult.hasMatch)) tracked.add(step.raw);
      for (final m in expressions.expand(referenced.allMatches)) {
        final group = StepGroup.values.firstWhere((g) => g.key.toLowerCase() == m.group(1)!.toLowerCase());
        final matches = [
          for (final candidate in sequence.stepsIn(group))
            if (candidate.name == m.group(2) || candidate.id == m.group(2)) candidate.raw,
        ];
        if (matches.length == 1) tracked.add(matches.single);
      }
    }
    final vars = Map<SeqProperty, String>.identity();
    for (final step in steps) {
      if (tracked.contains(step.raw)) vars[step.raw] = _claimId('${dartIdentifier(step.name)}Result');
    }
    return vars;
  }

  void _emitStepAction(Step step) {
    final module = step.module;
    final name = _comment(step.name);
    switch (step.stepType) {
      case StepType.statement:
        final expression = step.settings.postExpression;
        if (expression == null || !_emitStmt(expression, name == 'Statement' ? '' : name)) {
          _line('// $name: Statement with no expression');
        }
        return;
      case StepType.label:
        _line('// label: $name');
        return;
      case StepType.wait:
        final timeout = step.timeoutExpression ?? step.waitTimeExpression;
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
            'microseconds: ((${_numeric(timeout)}) * 1e6).round()));'
            '$waitNote',
          );
        } else {
          _line('// $name: Wait with no time expression');
        }
        return;
      case _:
    }

    switch (module.adapter) {
      case SeqAdapter.sequenceCall:
        final target = module.sequenceName;
        _stats.callSites++;
        final spawns = switch (module.threadOptionCode) {
          1 => 'a new thread',
          2 => 'a new execution',
          _ => null,
        };
        if (spawns != null) {
          _line('// sequence call spawns $spawns in the engine — exported as a plain awaited call');
          if (asTest) _markUnported('step "${step.name}" runs its sequence call in $spawns (not exported)');
        }
        if (module.remoteExecution == true) {
          _line(
            '// sequence call executes on remote host ${_comment(module.remoteHost ?? module.remoteHostExpression ?? '?')}',
          );
          if (asTest) _markUnported('step "${step.name}" executes its sequence call remotely (not exported)');
        }
        final inFileFn = module.resolvesLocalCall(ownFilePath: sourceName) && target != null
            ? _sequenceFnNames[target]
            : null;
        if (inFileFn != null) {
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
          _line(_sequenceCallLine(step, '$inFileFn($argsText)', name));
        } else {
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
            _line(_sequenceCallLine(step, '${resolved.fn}($argsText)', '$name: external sequence'));
          } else {
            if (asTest) {
              _markUnported('external sequence: ${_stubTarget(step, module)}');
            }
            final stub = _stubFor(step, module);
            var argsText = '';
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
        if (asTest) _markUnported(_stubTarget(step, module));
        _emitModuleNotes(module);
        _line(
          'await ${_stubFor(step, module).name}(); // $name'
          '${step.type != null ? ' [${_comment(step.type!)}]' : ''}',
        );
      case SeqAdapter.cModule:
      case SeqAdapter.python:
      case SeqAdapter.dotNet:
      case SeqAdapter.unknown:
        _emitModuleNotes(module);
        if (asTest) {
          _throwLine(step, '${module.adapter.name} call', _stubTarget(step, module));
        } else {
          _line(
            'await ${_stubFor(step, module).name}(); // $name'
            '${step.type != null ? ' [${_comment(step.type!)}]' : ''}',
          );
        }
      case SeqAdapter.none:
        final status = step.settings.statusExpression;
        if (!_runsSubsteps(step.type) && status != null && status.trim() != '""') {
          _line('// $name${step.type != null ? ' [${_comment(step.type!)}]' : ''}: judged by its status expression');
        } else if (asTest && step.type != null) {
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

  bool _runsSubsteps(String? type) {
    final substeps = type == null ? null : _typeByName[type]?.raw.prop('Substeps');
    return substeps == null ||
        [
          ...substeps.subProps,
          ...?substeps.array,
        ].any((s) => s.typeName == 'PreSubstep' || s.typeName == 'PostSubstep');
  }

  void _throwLine(Step step, String kind, String target) {
    _markUnported('$kind: $target');
    _line(
      "throw UnimplementedError('${_escape('$kind: $target')}'); "
      '// ${_comment(step.name)}'
      '${step.type != null ? ' [${_comment(step.type!)}]' : ''}',
    );
  }

  void _emitCallWiring(List<CallParameter> parameters) {
    for (final parameter in parameters) {
      final expression = parameter.boundExpression ?? parameter.displayValue;
      final direction = parameter.direction;
      if (expression == null && direction != 'out' && direction != 'in/out') continue;
      _stats.wiredArgs++;
      final arrow = switch (direction) {
        'out' => '->',
        'in/out' => '<->',
        _ => '<-',
      };
      _line(
        '//   ${_comment(expression != null ? '${parameter.name} $arrow $expression' : '${parameter.name} [$direction]')}',
      );
    }
  }

  void _emitModuleNotes(StepModule module) {
    if (module.adapter == SeqAdapter.dotNet) {
      if (module.assemblyPath != null) {
        _line('// .NET assembly: ${_comment(module.assemblyPath!)}');
      }
      for (final call in module.dotNetCalls) {
        _line(
          '// .NET call: '
          '${_comment('${call.className ?? module.dotNetClassName ?? '?'}.${call.memberName ?? '?'}')}',
        );
        _emitCallWiring(call.parameters);
      }
      return;
    }
    _emitCallWiring(module.adapter == SeqAdapter.labView ? module.viParameters : module.callParameters);
  }

  String _stubTarget(Step step, StepModule module) =>
      module.viPath ??
      module.moduleSourcePath ??
      module.pythonModulePath ??
      (module.adapter == SeqAdapter.dotNet ? module.target : null) ??
      module.sequenceName ??
      module.sequenceNameExpression ??
      step.name;

  Map<String, ({String id, _DartSlot type})> _scopeParamTable(_SeqScope scope) => {
    for (final e in scope.paramIds.entries) e.key.toLowerCase(): (id: e.value, type: scope.idTypes[e.value]!),
  };

  ({String text, bool disarmed}) _renderCallArgs(
    StepModule module, {
    required String calleeLabel,
    required Map<String, ({String id, _DartSlot type})> params,
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
        continue;
      }
      final raw = arg.expression;
      if (raw == null) {
        disarm('unbound argument', '${arg.name} binds no expression');
        continue;
      }
      final translated = _translate(raw);
      var value = translated?.code ?? _evalFallback(raw);
      if (translated != null) {
        final coerced = _coerce(translated, param.type);
        if (coerced == null) {
          value = _evalFallback(raw);
          disarm('type guard', '${arg.name} binding is not visibly ${param.type.source}-typed');
        } else {
          value = coerced.code;
        }
      }
      if (value.startsWith('ts.eval(')) {
        _stats.argsEvalFallback++;
      } else {
        _stats.argsTranslated++;
      }
      if (writtenParams.contains(lower) && param.type.isScalar && _isVariablePath(raw)) {
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
    final info = _stubs.putIfAbsent((module.adapter, target), () {
      final isSeq = module.adapter == SeqAdapter.sequenceCall;
      final lastSegment = target
          .split(RegExp(r'[/\\]'))
          .last
          .replaceFirst(RegExp(r'\.(vi|seq|dll|py)$', caseSensitive: false), '');
      final name = _uniqueTopLevel(
        isSeq ? dartIdentifier(lastSegment) : 'call${dartIdentifier(lastSegment, capitalize: true)}',
      );
      return _StubInfo(
        name: name,
        isSeq: isSeq,
        adapter: module.adapter,
        target: target,
        firstStepName: step.name,
      );
    });
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
          '/// Stub for the ${info.adapter.name} module call `${_comment(info.target)}`',
          '/// (from step `${_comment(info.firstStepName)}`). TODO: implement against '
              'the real module.',
        ],
        'Future<Object?> ${info.name}('
            '${params.isEmpty ? '' : '{${params.join(', ')}}'}) async =>',
        "    throw UnimplementedError('"
            "${_escape(info.isSeq ? 'external sequence: ${info.target}' : '${info.adapter.name} call: ${info.target}')}');",
      ];
      _out
        ..writeln(lines.join('\n'))
        ..writeln();
    }
  }

  void _emitTestMain() {
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
      ..writeln('void ${registerName ?? 'main'}() {');
    for (final root in roots) {
      final reachable = reach(root.name);
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
        ..writeln("    lw.expect(await $fnName(), 'Passed');")
        ..writeln('  });');
    }
    _out.writeln('}');
  }

  void _emitRuntime() {
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

  final Map<String, String> _fileGlobalCanon = {};
  final Map<String, _DartSlot> _fileGlobalTypes = {};
  final List<String> _fileGlobalDecls = [];
  final List<String> _fileGlobalSkipped = [];

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

  (_DartSlot, String) _globalField(SeqProperty c) {
    final name = c.name;
    final note = ' // ${c.typeName ?? c.className ?? 'value'}';
    final cls = c.valueClass;
    if (c.array != null || c.declaredArrayLength != null || (cls?.isArray ?? false)) {
      return (_DartSlot.list, 'List<dynamic> $name = ${_listInit(c, {})};$note');
    }
    final scalar = c.scalar;
    switch (cls) {
      case SeqValueClass.number:
        final n = _parseNumberScalar(scalar ?? '');
        return (_DartSlot.number, 'double $name = ${n == null ? '0' : _numLiteral(n)};$note');
      case SeqValueClass.boolean:
        return (_DartSlot.flag, 'bool $name = ${scalar?.toLowerCase() == 'true'};$note');
      case SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path:
        return (_DartSlot.text, "String $name = '${_escape(scalar ?? '')}';$note");
      case SeqValueClass.reference:
        return (_DartSlot.untyped, 'dynamic $name = null;$note');
      default:
        return (_DartSlot.untyped, 'dynamic $name = ${_propObjInit(c, {})};$note');
    }
  }

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

  String _typeOrEmpty(String? className, Set<String> seenTypes) {
    final t = className != null ? _typeByName[className] : null;
    if (t == null || !seenTypes.add(className!)) return 'ts.PropObj()';
    final init = _propObjInit(t.raw, seenTypes);
    seenTypes.remove(className);
    return init;
  }

  String _propValue(SeqProperty c, Set<String> seenTypes) {
    if (c.array != null || c.declaredArrayLength != null) {
      return _listInit(c, seenTypes);
    }
    final scalar = c.scalar;
    final cls = c.valueClass;
    if (scalar != null) {
      return switch (cls) {
        SeqValueClass.number => switch (_parseNumberScalar(scalar)) {
          final n? => n.isFinite ? n.toString() : _numLiteral(n),
          null => "'${_escape(scalar)}'",
        },
        SeqValueClass.boolean => scalar.toLowerCase() == 'true' ? 'true' : 'false',
        _ => "'${_escape(scalar)}'",
      };
    }
    if (c.subProps.isNotEmpty) return _propObjInit(c, seenTypes);
    return switch (cls) {
      SeqValueClass.number => '0',
      SeqValueClass.boolean => 'false',
      SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path => "''",
      SeqValueClass.reference => 'null',
      final k? when k.isArray => '<dynamic>[]',
      _ => switch (c.typeName ?? c.className) {
        null => 'null',
        final type => _typeOrEmpty(type, seenTypes),
      },
    };
  }

  String _listInit(SeqProperty owner, Set<String> seenTypes) {
    final elements = owner.array ?? const <SeqProperty>[];
    final declared = owner.declaredArrayLength ?? elements.length;
    if (declared == 0 && elements.isEmpty) return '<dynamic>[]';
    if (elements.length < declared) {
      final zero = _elementZero(owner, seenTypes);
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
    }
    if (elements.isEmpty) return '<dynamic>[]';
    final parts = [for (final e in elements) _propValue(e, seenTypes)];
    final first = parts.first;
    if (parts.length > 8 && !first.startsWith('ts.PropObj') && parts.every((p) => p == first)) {
      return 'List<dynamic>.filled(${parts.length}, $first, growable: true)';
    }
    return '<dynamic>[${parts.join(', ')}]';
  }

  String _elementZero(SeqProperty owner, Set<String> seenTypes) {
    final proto = owner.elementTypeName;
    if (proto != null) return _typeOrEmpty(proto, seenTypes);
    return switch (owner.valueClass) {
      SeqValueClass.numbers => '0',
      SeqValueClass.booleans => 'false',
      SeqValueClass.strings => "''",
      SeqValueClass.objects || SeqValueClass.containers => 'ts.PropObj()',
      _ => 'null',
    };
  }
}
