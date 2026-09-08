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
  String norm(String path) => path.replaceAll(r'\', '/');
  String baseOf(String path) => norm(path).split('/').last;
  String stemOf(String path) {
    final base = baseOf(path);
    return base.toLowerCase().endsWith('.seq') ? base.substring(0, base.length - 4) : base;
  }

  String snake(String text) {
    final cleaned = text
        .replaceAll(RegExp('[^A-Za-z0-9]+'), '_')
        .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (match) => '${match.group(1)}_${match.group(2)}')
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
    for (var sequenceIndex = 0; sequenceIndex < file.sequences.length; sequenceIndex++) {
      byName.putIfAbsent(file.sequences[sequenceIndex].name, () => scopes[sequenceIndex]);
    }
    scopeByNameOf[key] = byName;
  }

  final lowerByBase = <String, List<String>>{};
  for (final key in ordered) {
    (lowerByBase[baseOf(key).toLowerCase()] ??= []).add(key);
  }
  String dirOf(String key) {
    final normalized = norm(key);
    final cut = normalized.lastIndexOf('/');
    return cut < 0 ? '' : normalized.substring(0, cut);
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
      for (final candidate in candidates)
        if (dirOf(candidate) == dirOf(callerKey)) candidate,
    ];
    return sameDir.length == 1 ? sameDir.single : null;
  }

  final resolvedOf = <String, Map<(String, String), _ResolvedCall>>{};
  final importsOf = <String, Set<String>>{};
  final externallyCalledOf = <String, Set<String>>{};
  for (final key in ordered) {
    for (final sequence in byPath[key]!.sequences) {
      for (final step in sequence.steps) {
        final module = step.module;
        if (module.adapter != SeqAdapter.sequenceCall) continue;
        if (module.specifiesByExpression == true) continue;
        final sequenceFile = module.sequenceFile;
        final target = module.sequenceName;
        if (sequenceFile == null || target == null) continue;
        final targetKey = resolveTargetFile(key, sequenceFile);
        if (targetKey == null || targetKey == key) continue;
        final functionName = fnOf[targetKey]![target];
        if (functionName == null) continue;
        final prefix = moduleOf[targetKey]!;
        (resolvedOf[key] ??= {})[(sequenceFile, target)] = (
          functionName: '$prefix.$functionName',
          scope: scopeByNameOf[targetKey]![target]!,
        );
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
      resolveExternalCall: (module) {
        final (sequenceFile, name) = (module.sequenceFile, module.sequenceName);
        return sequenceFile == null || name == null ? null : resolved[(sequenceFile, name)];
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
            .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (match) => '${match.group(1)} ${match.group(2)}')
            .replaceAllMapped(RegExp(r'([A-Z]+)([A-Z][a-z])'), (match) => '${match.group(1)} ${match.group(2)}')
            .split(' ')
            .where((piece) => piece.isNotEmpty),
  ];
  if (words.isEmpty) return capitalize ? 'Unnamed' : 'unnamed';
  final buffer = StringBuffer();
  for (var wordIndex = 0; wordIndex < words.length; wordIndex++) {
    final word = words[wordIndex].toLowerCase();
    if (wordIndex == 0 && !capitalize) {
      buffer.write(word);
    } else {
      buffer.write(word[0].toUpperCase() + word.substring(1));
    }
  }
  var identifier = buffer.toString();
  if (RegExp(r'^[0-9]').hasMatch(identifier)) identifier = 'v$identifier';
  if (_dartReserved.contains(identifier)) identifier = '$identifier\$';
  return identifier;
}

String _uniqueName(String base, Set<String> taken) {
  var name = base;
  var suffix = 2;
  while (!taken.add(name)) {
    name = '$base${suffix++}';
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
  var cursor = 0;
  while (cursor < text.length) {
    final char = text[cursor];
    if (char == '"' || char == "'") {
      if (cursor > start) out.add((text.substring(start, cursor), false));
      final quote = char;
      var quoteEnd = cursor + 1;
      while (quoteEnd < text.length) {
        if (text[quoteEnd] == r'\') {
          quoteEnd += 2;
          continue;
        }
        if (text[quoteEnd] == quote) break;
        quoteEnd++;
      }
      quoteEnd = quoteEnd < text.length ? quoteEnd + 1 : text.length;
      out.add((text.substring(cursor, quoteEnd), true));
      start = quoteEnd;
      cursor = quoteEnd;
    } else {
      cursor++;
    }
  }
  if (start < text.length) out.add((text.substring(start), false));
  return out;
}

String _stripComments(String text) {
  final out = StringBuffer();
  var cursor = 0;
  while (cursor < text.length) {
    final char = text[cursor];
    if (char == '"' || char == "'") {
      out.write(char);
      cursor++;
      while (cursor < text.length) {
        out.write(text[cursor]);
        if (text[cursor] == r'\') {
          if (cursor + 1 < text.length) out.write(text[cursor + 1]);
          cursor += 2;
          continue;
        }
        final closed = text[cursor] == char;
        cursor++;
        if (closed) break;
      }
      continue;
    }
    if (char == '/' && cursor + 1 < text.length && text[cursor + 1] == '/') {
      while (cursor < text.length && text[cursor] != '\n' && text[cursor] != '\r') {
        cursor++;
      }
      continue;
    }
    if (char == '/' && cursor + 1 < text.length && text[cursor + 1] == '*') {
      final end = text.indexOf('*/', cursor + 2);
      out.write(' ');
      cursor = end < 0 ? text.length : end + 2;
      continue;
    }
    out.write(char);
    cursor++;
  }
  return out.toString();
}

String _stripNoValidation(String text) {
  const marker = '#NoValidation(';
  var result = text;
  var markerAt = result.indexOf(marker);
  while (markerAt >= 0) {
    var depth = 1;
    var cursor = markerAt + marker.length;
    while (cursor < result.length && depth > 0) {
      if (result[cursor] == '(') depth++;
      if (result[cursor] == ')') depth--;
      cursor++;
    }
    if (depth != 0) return text;
    result =
        result.substring(0, markerAt) +
        result.substring(markerAt + marker.length, cursor - 1) +
        result.substring(cursor);
    markerAt = result.indexOf(marker);
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
      for (var charIndex = 0; charIndex < segment.length; charIndex++) {
        switch (segment[charIndex]) {
          case '(' || '[' || '{':
            depth++;
          case ')' || ']' || '}':
            depth--;
          case ',':
            if (depth <= 0) {
              parts.add(text.substring(start, consumed + charIndex));
              start = consumed + charIndex + 1;
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
  bool balanced(String piece) {
    var depth = 0;
    for (final (segment, isString) in _segments(piece)) {
      if (isString) continue;
      for (var charIndex = 0; charIndex < segment.length; charIndex++) {
        if (segment[charIndex] == '(' || segment[charIndex] == '[' || segment[charIndex] == '{') depth++;
        if (segment[charIndex] == ')' || segment[charIndex] == ']' || segment[charIndex] == '}') depth--;
        if (depth < 0) return false;
      }
    }
    return depth == 0 && '"'.allMatches(piece.replaceAll(r'\"', '')).length.isEven;
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

  untyped('dynamic')
  ;

  const _DartSlot(this.source);

  final String source;

  bool get isScalar => this != list && this != untyped;
}

(_DartSlot, String)? _scalarType(SeqVariable variable) => switch (variable.raw.valueClass) {
  SeqValueClass.number => (_DartSlot.number, '0'),
  SeqValueClass.boolean => (_DartSlot.flag, 'false'),
  SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path => (_DartSlot.text, "''"),
  _ => null,
};

bool _isArrayVar(SeqVariable variable) => variable.raw.array != null || (variable.raw.valueClass?.isArray ?? false);

String _escape(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll(r'$', r'\$')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');

String _scalarInit(SeqVariable variable, _DartSlot type, String zero) {
  final value = variable.value;
  if (value == null) return zero;
  switch (type) {
    case _DartSlot.integer:
      final parsed = num.tryParse(value);
      return parsed == null ? zero : parsed.toInt().toString();
    case _DartSlot.number:
      final number = _parseTsNum(value);
      if (number == null) return zero;
      return _numLiteral(number);
    case _DartSlot.flag:
      final lower = value.toLowerCase();
      if (lower == 'true') return 'true';
      if (lower == 'false') return 'false';
      return zero;
    default:
      return "'${_escape(value)}'";
  }
}

_DartSlot _stubParamType(SeqVariable parameter) {
  final scalar = _scalarType(parameter);
  if (scalar != null) return scalar.$1;
  return _isArrayVar(parameter) ? _DartSlot.list : _DartSlot.untyped;
}

String _stubParamDecl(SeqVariable parameter, String identifier) {
  final scalar = _scalarType(parameter);
  if (scalar != null) {
    final (type, zero) = scalar;
    return '${type.source} $identifier = ${_scalarInit(parameter, type, zero)}';
  }
  if (_isArrayVar(parameter)) return 'List<dynamic>? $identifier';
  return 'dynamic $identifier';
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
      final shape = [for (final parameter in proto) '${parameter.name.toLowerCase()}|${parameter.raw.className}'];
      if (_protoShape == null) {
        _protoShape = shape;
      } else if (_protoShape!.join('\u0000') != shape.join('\u0000')) {
        _agree = false;
      }
      for (final parameter in proto) {
        _claim(parameter.name);
        _protoVarOf.putIfAbsent(parameter.name.toLowerCase(), () => parameter);
      }
    } else if (module.sequenceArguments.isNotEmpty) {
      _agree = false;
    }
    for (final argument in module.sequenceArguments) {
      _claim(argument.name);
    }
  }

  Map<String, ({String identifier, _DartSlot type})> paramTableFor(StepModule module) {
    final proto = module.prototypeParameters;
    if (proto.isNotEmpty) {
      return {
        for (final parameter in proto)
          parameter.name.toLowerCase(): (
            identifier: _idOf[parameter.name.toLowerCase()]!,
            type: _stubParamType(parameter),
          ),
      };
    }
    return {
      for (final argument in module.sequenceArguments)
        if (_idOf.containsKey(argument.name.toLowerCase()))
          argument.name.toLowerCase(): (identifier: _idOf[argument.name.toLowerCase()]!, type: _DartSlot.untyped),
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
    return [for (final identifier in _idOf.values) 'dynamic $identifier'];
  }
}

typedef _ResolvedCall = ({String functionName, _SeqScope scope});

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
    for (final entry in paramIds.entries) entry.key.toLowerCase(): entry.value,
  };

  late final Set<String> allIds = {...paramIds.values, ...localIds.values};
}

List<_SeqScope> _sequenceScopeTable(SeqFile file, Set<String> taken, {String? sourceName}) {
  final scopes = <_SeqScope>[];
  for (final sequence in file.sequences) {
    final used = <String>{...taken};
    final seenParams = <String>{};
    final emittedParams = [
      for (final parameter in sequence.parameters)
        if (seenParams.add(parameter.name)) parameter,
    ];
    final paramIds = {
      for (final parameter in emittedParams) parameter.name: _uniqueName(dartIdentifier(parameter.name), used),
    };
    final seenLocals = <String>{};
    final emittedLocals = [
      for (final local in sequence.locals)
        if (local.name != 'ResultList' && seenLocals.add(local.name)) local,
    ];
    final localIds = {for (final local in emittedLocals) local.name: _uniqueName(dartIdentifier(local.name), used)};
    _DartSlot typeOf(SeqVariable variable) {
      final scalar = _scalarType(variable);
      if (scalar != null) return scalar.$1;
      return _isArrayVar(variable) ? _DartSlot.list : _DartSlot.untyped;
    }

    scopes.add(
      _SeqScope(
        emittedParams: emittedParams,
        emittedLocals: emittedLocals,
        paramIds: paramIds,
        localIds: localIds,
        idTypes: {
          for (final parameter in emittedParams) paramIds[parameter.name]!: typeOf(parameter),
          for (final local in emittedLocals) localIds[local.name]!: typeOf(local),
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
  final assignmentPattern = RegExp(r'Parameters\.([A-Za-z_][A-Za-z0-9_]*)\s*([-+*/]?=)(?!=)', caseSensitive: false);
  void scan(String? raw) {
    if (raw == null) return;
    for (final match in assignmentPattern.allMatches(raw)) {
      names.add(match.group(1)!.toLowerCase());
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

void _refineIntTypes(SeqFile file, List<_SeqScope> scopes, String? sourceName) {
  bool integralDefault(SeqVariable variable) {
    final value = variable.value;
    if (value == null) return true;
    final number = num.tryParse(value);
    return number != null && number % 1 == 0 && number.abs() < _maxExactIntDouble;
  }

  final candidates = <(_SeqScope, String)>{};
  for (final scope in scopes) {
    void seed(List<SeqVariable> list, Map<String, String> ids) {
      for (final variable in list) {
        final identifier = ids[variable.name];
        if (identifier != null && scope.idTypes[identifier] == _DartSlot.number && integralDefault(variable)) {
          candidates.add((scope, identifier));
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

  String? idOf(_SeqScope owner, String root, String name) =>
      root.toLowerCase() == 'locals' ? owner.localIds[name] : owner.paramIds[name];

  final refRe = RegExp(r'(Locals|Parameters)\.([A-Za-z_][A-Za-z0-9_]*)', caseSensitive: false);
  final assigns = <(_SeqScope, String, String?, _SeqScope)>[];
  final assignRe = RegExp(
    r'^\s*(Locals|Parameters)\.([A-Za-z_][A-Za-z0-9_]*)'
    r'\s*([-+*/]?=)(?!=)\s*(.*)$',
    caseSensitive: false,
    dotAll: true,
  );
  for (var sequenceIndex = 0; sequenceIndex < scopes.length; sequenceIndex++) {
    final scope = scopes[sequenceIndex];
    void scan(String? raw) {
      if (raw == null) return;
      for (final piece in _rawStmtPieces(raw) ?? [raw]) {
        final match = assignRe.firstMatch(piece);
        if (match == null) continue;
        final identifier = idOf(scope, match.group(1)!, match.group(2)!);
        if (identifier == null) continue;
        assigns.add((scope, identifier, match.group(3) == '/=' ? null : match.group(4)!, scope));
      }
    }

    for (final step in file.sequences[sequenceIndex].steps) {
      scan(step.settings.preExpression);
      scan(step.settings.postExpression);
      final flow = step.flowControl;
      if (flow != null) {
        scan(flow.initialization);
        scan(flow.increment);
        final element = flow.arrayElement;
        if (element != null) {
          final match = refRe.firstMatch(element);
          final identifier = match != null ? idOf(scope, match.group(1)!, match.group(2)!) : null;
          if (identifier != null) candidates.remove((scope, identifier));
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
          final identifier = callee.paramIdOfLower[arg.name.toLowerCase()];
          if (expr == null || identifier == null) continue;
          assigns.add((callee, identifier, expr, scope));
        }
      }
    }
  }

  bool intExpr(String rhs, _SeqScope reader) {
    for (final match in refRe.allMatches(rhs)) {
      final identifier = idOf(reader, match.group(1)!, match.group(2)!);
      if (identifier == null || !candidates.contains((reader, identifier))) return false;
    }
    final rest = rhs.replaceAll(refRe, '0');
    return rest.trim().isNotEmpty && RegExp(r'^(?:\s|[()+\-*]|0x[0-9A-Fa-f]+|\d+(?![\d.eE]))+$').hasMatch(rest);
  }

  var changed = true;
  while (changed) {
    changed = false;
    for (final (target, identifier, rhs, reader) in assigns) {
      if (candidates.contains((target, identifier))) {
        if (rhs == null || !intExpr(rhs, reader)) {
          candidates.remove((target, identifier));
          changed = true;
        }
      } else if (target.idTypes[identifier] == _DartSlot.number && rhs != null) {
        final refs = [
          for (final match in refRe.allMatches(rhs)) idOf(reader, match.group(1)!, match.group(2)!),
        ].whereType<String>();
        if (refs.isNotEmpty && intExpr(rhs, reader)) {
          for (final ref in refs) {
            if (candidates.remove((reader, ref))) changed = true;
          }
        }
      }
    }
  }
  for (final (scope, identifier) in candidates) {
    scope.idTypes[identifier] = _DartSlot.integer;
  }
}

String _withoutUnusedImport(String source, String importLine, RegExp usage) {
  final stripped = source.replaceFirst(importLine, '');
  return usage.hasMatch(_withoutLineComments(stripped)) ? source : stripped;
}

String _withoutLineComments(String source) {
  final buffer = StringBuffer();
  for (final line in source.split('\n')) {
    var inString = false;
    var cut = line.length;
    for (var charIndex = 0; charIndex < line.length; charIndex++) {
      final codeUnit = line.codeUnitAt(charIndex);
      if (inString && codeUnit == 0x5C /* \ */ ) {
        charIndex++;
      } else if (codeUnit == 0x27 /* ' */ ) {
        inString = !inString;
      } else if (!inString &&
          codeUnit == 0x2F /* / */ &&
          charIndex + 1 < line.length &&
          line.codeUnitAt(charIndex + 1) == 0x2F) {
        cut = charIndex;
        break;
      }
    }
    buffer.writeln(line.substring(0, cut));
  }
  return buffer.toString();
}

/// 2^53, above which a double no longer represents every integer exactly.
const int _maxExactIntDouble = 9007199254740992;

String _numLiteral(num value) =>
    value is int && value.abs() < _maxExactIntDouble ? value.toString() : value.toDouble().toString();

final RegExp _i64SuffixLiteral = RegExp(r'(?<![\w.$])(\d+|0[xX][0-9a-fA-F]+)u?i64\b');

num? _parseTsNum(String text) {
  final trimmed = text.trim();
  final direct = num.tryParse(trimmed);
  if (direct != null) return direct;
  final match = RegExp(r'^-?(\d+|0[xX][0-9a-fA-F]+)u?i64$').firstMatch(trimmed);
  if (match == null) return null;
  final digits = num.tryParse(match.group(1)!);
  return digits == null ? null : (trimmed.startsWith('-') ? -digits : digits);
}

String _comment(String text) => text.replaceAll(RegExp(r'[\r\n]+'), ' | ').trim();

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
  final referencePattern = RegExp(r'StationGlobals\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)(\s*\()?', caseSensitive: false);
  void scan(String? raw) {
    if (raw == null) return;
    for (final match in referencePattern.allMatches(raw)) {
      if (match.group(2) == null) names.add(match.group(1)!);
    }
  }

  for (final sequence in file.sequences) {
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
  }
  return names;
}

const _variableRoots = {
  'FileGlobals': 'fileGlobals',
  'StationGlobals': 'stationGlobals',
  'RunState': 'runState',
  'Step': 'step',
};

/// `%` is absent: TestStand modulo keeps the sign of the dividend, Dart does not.
final _dartSafeExpression = RegExp(r"^[A-Za-z0-9_.\s+\-*/!<>=&|(),'\x22\[\]]+$");

const _builtinCalls = {
  'Len': 'ts.len',
  'GetNumElements': 'ts.getNumElements',
  'SetNumElements': 'ts.setNumElements',
  'Str': 'ts.str',
  'Left': 'ts.left',
  'Right': 'ts.right',
  'Mid': 'ts.mid',
  'Find': 'ts.find',
};

final _testStandOnly = RegExp(r'(?<!\.)\b[A-Za-z][A-Za-z0-9_]*\s*\(|#|->');

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
    for (final typeDef in file.typeDefs)
      if ((typeDef.raw.prop('TS')?.prop('PreCond')?.scalar ?? '').isNotEmpty)
        typeDef.name: typeDef.raw.prop('TS')!.prop('PreCond')!.scalar!,
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
    for (var sequenceIndex = 0; sequenceIndex < file.sequences.length; sequenceIndex++) {
      _scopeByName.putIfAbsent(file.sequences[sequenceIndex].name, () => _scopes[sequenceIndex]);
    }
    _allScopeIds = {for (final scope in _scopes) ...scope.allIds};
    for (var sequenceIndex = 0; sequenceIndex < file.sequences.length; sequenceIndex++) {
      _emitSequence(file.sequences[sequenceIndex], _scopes[sequenceIndex]);
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
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return "''";
    trimmed = _stripNoValidation(_stripComments(trimmed)).trim();
    if (trimmed.isEmpty) return "''";

    if (_splitTopLevelCommas(trimmed).length > 1) return _evalFallback(raw);

    final rebuilt = StringBuffer();
    for (final (segment, isString) in _segments(trimmed)) {
      if (isString) {
        if (segment.contains('\n') || segment.contains('\r')) {
          return _evalFallback(raw);
        }
        if (RegExp(r'''\\[^nrt"'\\]''').hasMatch(segment)) {
          return _evalFallback(raw);
        }
        rebuilt.write(segment.replaceAll('\$', r'\$'));
        continue;
      }
      final code = _translateSegment(segment);
      if (code == null) return _evalFallback(raw);
      rebuilt.write(code);
    }
    return rebuilt.toString();
  }

  String? _translateSegment(String segment) {
    var code = segment;
    for (final match in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\.').allMatches(code)) {
      final precededByDot = match.start > 0 && code.substring(match.start - 1, match.start) == '.';
      final root = match.group(1)!;
      if (!precededByDot && !_variableRoots.containsKey(root) && root != 'Locals' && root != 'Parameters') {
        return null;
      }
    }
    if (RegExp(r'\*\s*[A-Za-z_]').hasMatch(code)) return null;
    code = code
        .replaceAll(RegExp(r'\bTrue\b'), 'true')
        .replaceAll(RegExp(r'\bFalse\b'), 'false')
        .replaceAll(RegExp(r'(?<!\.)\bNothing\b'), 'null')
        .replaceAllMapped(_i64SuffixLiteral, (match) => match.group(1)!);
    var undeclared = false;
    for (final (root, ids) in [
      ('Locals', _localIds),
      ('Parameters', _paramIds),
    ]) {
      code = code.replaceAllMapped(
        RegExp('\\b$root\\.([A-Za-z_][A-Za-z0-9_.]*)'),
        (match) {
          final segments = match.group(1)!.split('.');
          final identifier = ids[segments.first];
          if (identifier == null) {
            undeclared = true;
            return match.group(0)!;
          }
          return segments.length == 1 ? identifier : '$identifier.${segments.sublist(1).join('.')}';
        },
      );
    }
    if (undeclared) return null;
    for (final entry in _variableRoots.entries) {
      code = code.replaceAllMapped(
        RegExp('\\b${entry.key}\\.([A-Za-z_][A-Za-z0-9_.]*)'),
        (match) => '${entry.value}.${match.group(1)!}',
      );
    }
    var unknownGlobal = false;
    code = code.replaceAllMapped(
      RegExp(
        r'\b(fileGlobals|stationGlobals)\.'
        r'([A-Za-z_][A-Za-z0-9_]*)(\s*\()?',
      ),
      (match) {
        final isFile = match.group(1) == 'fileGlobals';
        final declared = (isFile ? _fileGlobalCanon : _stationGlobalCanon)[match.group(2)!.toLowerCase()];
        final call = match.group(3);
        final type = declared == null ? null : (isFile ? _fileGlobalTypes[declared] : _DartSlot.untyped);
        if (declared == null || (call != null && type != _DartSlot.untyped)) {
          unknownGlobal = true;
          return match.group(0)!;
        }
        return '${match.group(1)}.$declared${call ?? ''}';
      },
    );
    if (unknownGlobal) return null;
    for (final entry in {
      ..._builtinCalls,
      'Random': asTest ? 'lw.rand' : 'ts.rand',
    }.entries) {
      code = code.replaceAllMapped(
        RegExp('(?<![.A-Za-z0-9_])${entry.key}\\s*\\('),
        (_) => '${entry.value}(',
      );
    }
    final masked = code.replaceAll('&&', '  ').replaceAll('||', '  ');
    if (masked.contains('&') || masked.contains('|')) {
      return null;
    }
    if (!_dartSafeExpression.hasMatch(code) || _testStandOnly.hasMatch(code)) {
      return null;
    }
    code = code.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');
    if (RegExp(r'[.+\-*/<>=&|!,]\s*$').hasMatch(code)) {
      return null;
    }
    for (final match in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\.[A-Za-z_][A-Za-z0-9_.]*\s*\(').allMatches(code)) {
      if (_idTypes.containsKey(match.group(1)) && _idTypes[match.group(1)] != _DartSlot.untyped) {
        return null;
      }
    }
    for (final match in RegExp(r'\[([^\[\]]*)\]').allMatches(code)) {
      for (final identifierMatch in RegExp(r'[A-Za-z_][A-Za-z0-9_]*').allMatches(match.group(1)!)) {
        if (_idTypes[identifierMatch.group(0)] == _DartSlot.number) return null;
      }
    }
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
    for (final match in RegExp(r'\b([A-Za-z_][A-Za-z0-9_]*)\b').allMatches(codeSansKeys)) {
      final identifier = match.group(1)!;
      final precededByDot = match.start > 0 && codeSansKeys.substring(match.start - 1, match.start) == '.';
      if (precededByDot) continue;
      if (!knownBare.contains(identifier) &&
          identifier != generatedName &&
          !_localIds.containsValue(identifier) &&
          !_paramIds.containsValue(identifier)) {
        return null;
      }
    }
    return code;
  }

  String _evalFallback(String raw) => "ts.eval('${_escape(raw)}')";

  String _cond(String raw) {
    final translated = _expr(raw);
    if (translated.startsWith('ts.eval(')) return 'ts.cond${translated.substring(7)}';
    if (_staticallyBool(translated)) return translated;
    final numeric = _idTypes[translated] == _DartSlot.number || _idTypes[translated] == _DartSlot.integer;
    if (numeric) return '$translated != 0';
    return 'ts.truthy($translated)';
  }

  bool _staticallyBool(String expression) {
    if (expression.startsWith('ts.eval(')) return false;
    if (expression == 'true' || expression == 'false') return true;
    if (_idTypes[expression] == _DartSlot.flag) return true;
    if (expression.startsWith('!')) return true;
    var depth = 0;
    String? topOp;
    for (final (segment, isString) in _segments(expression)) {
      if (isString) continue;
      for (var charIndex = 0; charIndex < segment.length; charIndex++) {
        final char = segment[charIndex];
        if (char == '(' || char == '[') depth++;
        if (char == ')' || char == ']') depth--;
        if (depth > 0) continue;
        if (char == '&' && charIndex + 1 < segment.length && segment[charIndex + 1] == '&') {
          return true;
        }
        if (char == '|' && charIndex + 1 < segment.length && segment[charIndex + 1] == '|') {
          return true;
        }
        if ((char == '=' || char == '!') && charIndex + 1 < segment.length && segment[charIndex + 1] == '=') {
          topOp ??= '==';
        }
        if (char == '<' || char == '>') topOp ??= '<';
      }
    }
    if (topOp == '==') return true;
    if (topOp == '<') {
      final lead = RegExp(r'^\(?\s*([A-Za-z_][A-Za-z0-9_]*|[0-9.]+)').firstMatch(expression)?.group(1);
      if (lead == null) return false;
      if (RegExp(r'^[0-9.]').hasMatch(lead)) return true;
      final leadType = _idTypes[lead];
      return leadType != null && leadType.isScalar;
    }
    return false;
  }

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
      for (final parameter in emittedParams) _paramDecl(parameter, _paramIds[parameter.name]!),
    ];
    _out.writeln(
      'Future<void> $fnName('
      '${params.isEmpty ? '' : '{${params.join(', ')}}'}) async {',
    );
    _indent = 1;

    var arrayPreamble = false;
    for (final parameter in emittedParams) {
      if (_scalarType(parameter) == null && _isArrayVar(parameter)) {
        _line('${_paramIds[parameter.name]!} ??= ${_arrayInit(parameter)};${_typeComment(parameter)}');
        arrayPreamble = true;
      }
    }
    if (arrayPreamble) _line('');

    for (final local in emittedLocals) {
      _line(_localDecl(local, _localIds[local.name]!));
    }
    if (emittedLocals.isNotEmpty) _line('');

    final nonEmptyGroups = [
      for (final group in StepGroup.values)
        if (sequence.stepsIn(group).isNotEmpty) group,
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
    final type = v.type;
    final comment = v.comment;
    final parts = [
      if (type != null) type,
      if (rawDefault != null) "default: ${_comment(rawDefault)}",
      if (comment != null) _comment(comment),
    ];
    if (parts.isEmpty) return '';
    return ' // ${parts.join(' — ')}';
  }

  (_DartSlot, String, String)? _scalarDecl(SeqVariable variable, String identifier) {
    final scalar = _scalarType(variable);
    if (scalar == null) return null;
    var (type, zero) = scalar;
    if (type == _DartSlot.number && _idTypes[identifier] == _DartSlot.integer) type = _DartSlot.integer;
    return (type, zero, _scalarInit(variable, type, zero));
  }

  String _paramDecl(SeqVariable parameter, String identifier) {
    final scalar = _scalarDecl(parameter, identifier);
    if (scalar != null) {
      final (type, _, init) = scalar;
      return '${type.source} $identifier = $init';
    }
    if (_isArrayVar(parameter)) return 'List<dynamic>? $identifier';
    return 'dynamic $identifier';
  }

  String _localDecl(SeqVariable local, String identifier) {
    final scalar = _scalarDecl(local, identifier);
    if (scalar != null) {
      final (type, zero, init) = scalar;
      final fellBack = local.value != null && init == zero && type != _DartSlot.text;
      return '${type.source} $identifier = $init;'
          '${_typeComment(local, rawDefault: fellBack ? local.value : null)}';
    }
    if (_isArrayVar(local)) {
      return 'List<dynamic> $identifier = ${_arrayInit(local)};${_typeComment(local)}';
    }
    final valueClass = local.raw.valueClass;
    if (valueClass == SeqValueClass.reference || (valueClass == null && local.raw.subProps.isEmpty)) {
      return 'dynamic $identifier;${_typeComment(local)}';
    }
    return 'dynamic $identifier = ${_propObjInit(local.raw, {})};'
        '${_typeComment(local)}';
  }

  String _arrayInit(SeqVariable variable) => _listInit(variable.raw, {});

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
      for (var blockIndex = open.length - 1; blockIndex >= 0; blockIndex--) {
        if (test(open[blockIndex].kind)) return open[blockIndex];
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
      final authorComment = step.comment;
      if (authorComment != null) {
        for (final line in authorComment.split('\n')) {
          _line('// ${_comment(line)}');
        }
      }
      final mode = step.settings.mode;
      final runMode = step.settings.runMode;
      var modeNote = '';
      if (!step.settings.isNormalMode) {
        final structural = flow != null && flow.kind != FlowKind.breakStmt && flow.kind != FlowKind.continueStmt;
        if (!structural) {
          if (runMode == StepRunMode.fail && asTest) {
            _markUnported(
              'force-fail step "${step.name}" '
              '(status semantics not exported)',
            );
          }
          final what = switch (runMode) {
            StepRunMode.skip => 'skipped',
            StepRunMode.pass => 'force-pass',
            StepRunMode.fail => 'force-fail',
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
            final assign = _expr('$element = __LWELEMENT__');
            if (assign.startsWith('ts.eval(')) {
              _line(
                '// TODO: bind loop element: '
                '${_comment(element)} = <element>',
              );
            } else {
              final targetId = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)').firstMatch(assign)?.group(1);
              final cast = switch (_idTypes[targetId]) {
                _DartSlot.number => '($loopVar as num).toDouble()',
                _DartSlot.integer => '($loopVar as num).toInt()',
                _DartSlot.flag => '$loopVar as bool',
                _DartSlot.text => '$loopVar as String',
                _DartSlot.list => '$loopVar as List<dynamic>',
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
          final select = innermost((kind) => kind == FlowKind.selectBlock)?.selectId ?? 0;
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
          final target = innermost((kind) => kind == FlowKind.selectBlock || loopKinds.contains(kind));
          if (target == null) {
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
    while (open.isNotEmpty) {
      closeBlock(open.removeLast(), note: ' // closed: unbalanced block in source');
    }
  }

  String _exprStatement(String raw) {
    final translated = _expr(raw);
    if (translated.startsWith('ts.eval(')) return translated;
    final match = RegExp(
      r'^((?:fileGlobals|stationGlobals)\.)?'
      r'([A-Za-z_][A-Za-z0-9_]*)\s*=(?![=])',
    ).firstMatch(translated);
    if (match != null) {
      final lhsType = switch (match.group(1)) {
        'fileGlobals.' => _fileGlobalTypes[match.group(2)],
        'stationGlobals.' => _DartSlot.untyped,
        _ => _idTypes[match.group(2)],
      };
      if (_kindMismatch(lhsType, translated.substring(match.end).trim())) {
        return _evalFallback(raw);
      }
    }
    return translated;
  }

  bool _kindMismatch(_DartSlot? lhsType, String rhs) {
    if (lhsType == null || lhsType == _DartSlot.untyped) return false;
    if (rhs == 'null') return true;
    final looksString =
        rhs.startsWith("'") || rhs.startsWith('"') || _idTypes[rhs] == _DartSlot.text || rhs.startsWith('ts.str(');
    final rhsLeadType = _idTypes[RegExp(r'^[A-Za-z_][A-Za-z0-9_\$]*').firstMatch(rhs)?.group(0) ?? ''];
    final looksNumericLead =
        RegExp(r'^[0-9(]').hasMatch(rhs) || rhsLeadType == _DartSlot.number || rhsLeadType == _DartSlot.integer;
    return switch (lhsType) {
      _DartSlot.text => (looksNumericLead && !looksString) || _staticallyBool(rhs),
      _DartSlot.number || _DartSlot.integer => looksString || _staticallyBool(rhs),
      _DartSlot.flag => !_staticallyBool(rhs) && (looksString || looksNumericLead),
      _DartSlot.list => looksString || _staticallyBool(rhs) || (looksNumericLead && !rhs.startsWith('(')),
      _ => false,
    };
  }

  bool _staticallyIntExpr(String expression) {
    if (expression.contains("'") || expression.contains('"')) return false;
    final sansHex = expression.replaceAll(RegExp('0x[0-9A-Fa-f]+'), '0');
    for (final match in RegExp(r'[A-Za-z_][A-Za-z0-9_\$]*').allMatches(sansHex)) {
      if (_idTypes[match.group(0)] != _DartSlot.integer) return false;
    }
    final rest = sansHex.replaceAll(RegExp(r'[A-Za-z_][A-Za-z0-9_\$]*'), '0');
    return rest.trim().isNotEmpty && RegExp(r'^[0-9\s()+\-*]+$').hasMatch(rest);
  }

  List<String> _stmtParts(String raw) {
    final pieces = _rawStmtPieces(raw);
    if (pieces == null) return [_exprStatement(raw)];
    final out = <String>[
      for (final piece in pieces)
        if (piece.trim().isNotEmpty) _exprStatement(piece),
    ];
    return out.isEmpty ? [_exprStatement(raw)] : out;
  }

  void _emitStmt(String raw, String note) {
    final parts = _stmtParts(raw);
    for (var partIndex = 0; partIndex < parts.length; partIndex++) {
      final suffix = note.isEmpty ? '' : (partIndex == 0 ? ' // $note' : ' // $note (cont.)');
      _line('${parts[partIndex]};$suffix');
    }
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

    if (settings.passAction != null && settings.passFlowAction != StepFlowAction.next) {
      notes.add('on pass: ${settings.passAction}${jump(settings.passActionTarget)}');
    }
    if (settings.failAction != null && settings.failFlowAction != StepFlowAction.next) {
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
        (settings.passAction != null && settings.passFlowAction != StepFlowAction.next) ||
        (settings.failAction != null && settings.failFlowAction != StepFlowAction.next) ||
        settings.customTrueTarget != null ||
        settings.customFalseTarget != null;
    if (jumps) {
      _markUnported('flow action of step "${step.name}" (${settings.flowSummary ?? 'custom/goto'}) not exported');
    }
    final status = settings.statusExpression;
    if (status != null && status.trim() != '""') {
      _markUnported('status expression of step "${step.name}" not exported');
    }
  }

  void _emitPlainStep(Step step) {
    final settings = step.settings;
    _emitPayloadNotes(step);
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
    if (post != null && step.stepType != StepType.statement) {
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
    switch (step.stepType) {
      case StepType.statement:
        final expression = step.settings.postExpression;
        if (expression != null) {
          _emitStmt(expression, name == 'Statement' ? '' : name);
        } else {
          _line('// $name: Statement with no expression');
        }
        return;
      case StepType.label:
        _line('// label: $name');
        return;
      case StepType.wait:
        _emitWaitStep(step, name);
        return;
      case _:
    }

    switch (module.adapter) {
      case SeqAdapter.sequenceCall:
        _emitSequenceCall(step, module, name);
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

  void _emitWaitStep(Step step, String name) {
    final timeout = step.timeoutExpression ?? step.waitTimeExpression;
    final literal = timeout != null ? num.tryParse(timeout.trim()) : null;
    final waitNote = name == 'Wait' ? '' : ' // $name';
    if (literal != null) {
      final milliseconds = (literal * 1000).round();
      _line(
        milliseconds % 1000 == 0
            ? 'await Future<void>.delayed('
                  'const Duration(seconds: ${milliseconds ~/ 1000}));$waitNote'
            : 'await Future<void>.delayed('
                  'const Duration(milliseconds: $milliseconds));$waitNote',
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
  }

  void _emitSequenceCall(Step step, StepModule module, String name) {
    final target = module.sequenceName;
    _stats.callSites++;
    final spawns = switch (module.threadOption) {
      SequenceCallThreadOption.newThread => 'a new thread',
      SequenceCallThreadOption.newExecution => 'a new execution',
      null => null,
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
      _line('await $inFileFn($argsText); // $name');
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
        _line('await ${resolved.functionName}($argsText); // $name: external sequence');
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
      final direction = parameter.directionKind;
      final writesBack = direction == CallParameterDirection.output || direction == CallParameterDirection.inOut;
      if (expression == null && !writesBack) continue;
      _stats.wiredArgs++;
      final arrow = switch (direction) {
        CallParameterDirection.output => '->',
        CallParameterDirection.inOut => '<->',
        _ => '<-',
      };
      _line(
        '//   ${_comment(expression != null ? '${parameter.name} $arrow $expression' : '${parameter.name} [${direction?.label}]')}',
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

  Map<String, ({String identifier, _DartSlot type})> _scopeParamTable(_SeqScope scope) => {
    for (final entry in scope.paramIds.entries)
      entry.key.toLowerCase(): (identifier: entry.value, type: scope.idTypes[entry.value]!),
  };

  ({String text, bool disarmed}) _renderCallArgs(
    StepModule module, {
    required String calleeLabel,
    required Map<String, ({String identifier, _DartSlot type})> params,
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
      var value = _expr(raw);
      if (!value.startsWith('ts.eval(')) {
        if (_kindMismatch(param.type, value) || (param.type == _DartSlot.integer && !_staticallyIntExpr(value))) {
          value = _evalFallback(raw);
          disarm('type guard', '${arg.name} binding is not visibly ${param.type.source}-typed');
        } else if (param.type == _DartSlot.number && _staticallyIntExpr(value) && !RegExp(r'^\d+$').hasMatch(value)) {
          value = RegExp(r'^[A-Za-z_][A-Za-z0-9_\$]*$').hasMatch(value) ? '$value.toDouble()' : '($value).toDouble()';
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
      parts.add('${param.identifier}: $value');
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
      for (final sequence in file.sequences)
        if (!called.contains(sequence.name) && !externallyCalled.contains(sequence.name)) sequence,
    ];
    if (roots.isEmpty) roots = file.sequences;

    final byName = {for (final sequence in file.sequences) sequence.name: sequence};
    Set<String> reach(String name) {
      final seen = <String>{};
      void visit(String current) {
        if (!seen.add(current)) return;
        callTargets[current]?.forEach(visit);
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
      for (final parameter in root.parameters) {
        if (_scalarType(parameter) == null && !_isArrayVar(parameter)) {
          unported.add(
            "root parameter '${parameter.name}' is an engine object "
            '(nothing binds it when run as a test)',
          );
        }
      }
      final reqArg = reqs.isEmpty
          ? ''
          : ' requirements: '
                "[${reqs.map((requirement) => "'${_escape(requirement)}'").join(', ')}],";
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
    for (final typeDef in file.typeDefs) typeDef.name: typeDef,
  };

  final Map<String, String> _fileGlobalCanon = {};
  final Map<String, _DartSlot> _fileGlobalTypes = {};
  final List<String> _fileGlobalDecls = [];
  final List<String> _fileGlobalSkipped = [];

  final Map<String, String> _stationGlobalCanon = {};
  final List<String> _stationGlobalSkipped = [];

  void _buildGlobals() {
    final defaults = file.data.prop('FileGlobalDefaults');
    for (final global in defaults?.subProps ?? const <SeqProperty>[]) {
      if (!_validGlobalFieldName(global.name) || _fileGlobalCanon.containsKey(global.name.toLowerCase())) {
        _fileGlobalSkipped.add(global.name);
        continue;
      }
      _fileGlobalCanon[global.name.toLowerCase()] = global.name;
      final (type, decl) = _globalField(global);
      _fileGlobalTypes[global.name] = type;
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

  (_DartSlot, String) _globalField(SeqProperty property) {
    final name = property.name;
    final note = ' // ${property.typeName ?? property.className ?? 'value'}';
    final valueClass = property.valueClass;
    if (property.array != null || property.declaredArrayLength != null || (valueClass?.isArray ?? false)) {
      return (_DartSlot.list, 'List<dynamic> $name = ${_listInit(property, {})};$note');
    }
    final scalar = property.scalar;
    switch (valueClass) {
      case SeqValueClass.number:
        final number = num.tryParse(scalar ?? '');
        return (_DartSlot.number, 'double $name = ${number == null ? '0' : _numLiteral(number)};$note');
      case SeqValueClass.boolean:
        return (_DartSlot.flag, 'bool $name = ${scalar?.toLowerCase() == 'true'};$note');
      case SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path:
        return (_DartSlot.text, "String $name = '${_escape(scalar ?? '')}';$note");
      case SeqValueClass.reference:
        return (_DartSlot.untyped, 'dynamic $name;$note');
      default:
        return (_DartSlot.untyped, 'dynamic $name = ${_propObjInit(property, {})};$note');
    }
  }

  String _propObjInit(SeqProperty property, Set<String> seenTypes) {
    final children = property.subProps;
    if (children.isEmpty) {
      return _typeOrEmpty(property.typeName ?? property.className, seenTypes);
    }
    final parts = [
      for (final child in children) "'${_escape(child.name)}': ${_propValue(child, seenTypes)}",
    ];
    return 'ts.PropObj({${parts.join(', ')}})';
  }

  String _typeOrEmpty(String? className, Set<String> seenTypes) {
    final typeDef = className != null ? _typeByName[className] : null;
    if (typeDef == null || !seenTypes.add(className!)) return 'ts.PropObj()';
    final init = _propObjInit(typeDef.raw, seenTypes);
    seenTypes.remove(className);
    return init;
  }

  String _propValue(SeqProperty property, Set<String> seenTypes) {
    if (property.array != null || property.declaredArrayLength != null) {
      return _listInit(property, seenTypes);
    }
    final scalar = property.scalar;
    final valueClass = property.valueClass;
    if (scalar != null) {
      return switch (valueClass) {
        SeqValueClass.number => num.tryParse(scalar)?.toString() ?? "'${_escape(scalar)}'",
        SeqValueClass.boolean => scalar.toLowerCase() == 'true' ? 'true' : 'false',
        _ => "'${_escape(scalar)}'",
      };
    }
    if (property.subProps.isNotEmpty) return _propObjInit(property, seenTypes);
    return switch (valueClass) {
      SeqValueClass.number => '0',
      SeqValueClass.boolean => 'false',
      SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path => "''",
      SeqValueClass.reference => 'null',
      final arrayClass? when arrayClass.isArray => '<dynamic>[]',
      _ => switch (property.typeName ?? property.className) {
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
      for (final element in elements) {
        final match = RegExp(r'^\[(\d+)\]$').firstMatch(element.name);
        final index = match != null ? int.parse(match.group(1)!) : -1;
        if (index < 0 || index >= declared) {
          placeable = false;
          break;
        }
        final value = _propValue(element, seenTypes);
        if (value != 'null' || zero == 'null') overrides.add((index, value));
      }
      if (placeable) {
        final base = zero.startsWith('ts.PropObj')
            ? 'List<dynamic>.generate($declared, (_) => $zero, '
                  'growable: true)'
            : 'List<dynamic>.filled($declared, $zero, growable: true)';
        if (overrides.isEmpty) return base;
        final sets = [for (final (index, value) in overrides) '..[$index] = $value'].join();
        return '($base$sets)';
      }
    }
    if (elements.isEmpty) return '<dynamic>[]';
    final parts = [for (final element in elements) _propValue(element, seenTypes)];
    final first = parts.first;
    if (parts.length > 8 && !first.startsWith('ts.PropObj') && parts.every((part) => part == first)) {
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
