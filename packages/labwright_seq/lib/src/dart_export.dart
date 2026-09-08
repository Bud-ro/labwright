import 'seq_file.dart';
import 'seq_module.dart';
import 'seq_property.dart';
import 'seq_step.dart';
import 'seq_typedefs.dart';

part 'dart_export_emitter.dart';
part 'dart_export_scopes.dart';
part 'dart_export_text.dart';

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
