part of 'dart_export.dart';

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
