import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

import 'dart_export.dart';
import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_module.dart';

/// How a LabVIEW step states where its VI is.
enum SeqViPathKind {
  /// The step records no VI path.
  none,

  /// A file path from the sequence file's directory.
  relative,

  /// A LabVIEW project item path, `My Computer\Lib.lvlib\Folder\Name.vi`: the target, then the
  /// owning libraries and virtual folders, then the file name.
  project,

  /// A bare file name owned by the library or class the step's namespace names.
  namespaced,

  /// A path under one of LabVIEW's own symbolic roots, `<vilib>`, `<instrlib>`, `<userlib>`.
  symbolic,

  /// A path from a drive or filesystem root of the authoring machine.
  absolute;

  static SeqViPathKind of(StepModule module) {
    final path = module.viPath;
    if (path == null) return none;
    if (path.startsWith('<')) return symbolic;
    if (RegExp(r'^([A-Za-z]:|[\\/])').hasMatch(path)) return absolute;
    final normalized = path.replaceAll(r'\', '/');
    if (module.viProjectPath != null || normalized.startsWith('My Computer/')) return project;
    if (!normalized.contains('/') && module.viNamespace != null && LvLibraryKind.ofPath(module.viNamespace!) != null) {
      return namespaced;
    }
    return relative;
  }
}

sealed class SeqViTarget {
  const SeqViTarget(this.kind);

  final SeqViPathKind kind;
}

final class SeqViFile extends SeqViTarget {
  const SeqViFile(super.kind, this.file);

  final File file;
}

final class SeqViUnlocated extends SeqViTarget {
  const SeqViUnlocated(super.kind, this.path);

  final String path;
}

/// A source tree holding sequence files and the LabVIEW files their steps call: the text
/// sequence files parsed, the LabVIEW libraries indexed, and every VI by file name.
class SeqSourceTree {
  SeqSourceTree._(this.root, this.sequenceFiles, this.unparsed, this.libraries, this._visByName);

  final Directory root;

  /// Each text sequence file by its path relative to [root], in path order.
  final Map<String, SeqFile> sequenceFiles;

  /// Text sequence files that did not parse, relative to [root].
  final List<String> unparsed;

  final LvProjectIndex libraries;

  final Map<String, List<File>> _visByName;

  factory SeqSourceTree.scan(Directory root) {
    final sequenceFiles = <String, SeqFile>{};
    final unparsed = <String>[];
    final visByName = <String, List<File>>{};
    final files = lvWalkProjectFiles(root, skipHidden: true).toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final lower = file.path.toLowerCase();
      if (lower.endsWith('.vi')) {
        (visByName[file.uri.pathSegments.last.toLowerCase()] ??= []).add(file);
        continue;
      }
      if (!lower.endsWith('.seq')) continue;
      final bytes = file.readAsBytesSync();
      if (!detectSeqFormat(bytes).isText) continue;
      final relative = _relative(root, file.path);
      try {
        sequenceFiles[relative] = parseSeqFile(bytes);
      } on Exception {
        unparsed.add(relative);
      }
    }
    return SeqSourceTree._(root, sequenceFiles, unparsed, LvProjectIndex.scan(root, skipHidden: true), visByName);
  }

  /// [path] below [root] with forward slashes, or [path] itself when it is not below it.
  static String _relative(Directory root, String path) {
    final rootPath = root.path.replaceAll(r'\', '/');
    final prefix = rootPath.endsWith('/') ? rootPath : '$rootPath/';
    final normalized = path.replaceAll(r'\', '/');
    return normalized.startsWith(prefix) ? normalized.substring(prefix.length) : normalized;
  }

  /// The one VI in the tree named [fileName], or null when none or several are.
  File? uniqueViNamed(String fileName) => switch (_visByName[fileName.toLowerCase()]) {
    [final file] => file,
    _ => null,
  };

  /// Where the VI of a LabVIEW step of the sequence file at [sequencePath] is.
  SeqViTarget locate(String sequencePath, StepModule module) {
    final kind = SeqViPathKind.of(module);
    final raw = module.viPath;
    if (raw == null) return const SeqViUnlocated(SeqViPathKind.none, '');
    final path = raw.replaceAll(r'\', '/');
    final sequenceDirectory = Uri.directory(root.path).resolve(sequencePath).resolve('.');
    File? existing(String candidate) => File(candidate).existsSync() ? File(candidate) : null;
    switch (kind) {
      case SeqViPathKind.relative:
        if (existing(sequenceDirectory.resolve(Uri(pathSegments: path.split('/')).toString()).toFilePath())
            case final file?) {
          return SeqViFile(kind, file);
        }
      case SeqViPathKind.namespaced:
        if (libraries.fileOf([module.viNamespace!, path]) case final found? when File(found).existsSync()) {
          return SeqViFile(kind, File(found));
        }
      case SeqViPathKind.project:
        final components = path.split('/');
        final owners = [
          for (final component in components.skip(1).take(components.length - 2))
            if (LvLibraryKind.ofPath(component) case final owner? when owner != LvLibraryKind.project) component,
        ];
        if (module.viProjectPath case final projectPath?) {
          final project = sequenceDirectory
              .resolve(Uri(pathSegments: projectPath.replaceAll(r'\', '/').split('/')).toString())
              .toFilePath();
          if (_throughProject(project, components.skip(1).toList()) case final file?) return SeqViFile(kind, file);
        }
        if (owners.isNotEmpty) {
          if (libraries.fileOf([...owners, components.last]) case final found? when File(found).existsSync()) {
            return SeqViFile(kind, File(found));
          }
        }
      case SeqViPathKind.none:
      case SeqViPathKind.symbolic:
      case SeqViPathKind.absolute:
        break;
    }
    return SeqViUnlocated(kind, raw);
  }

  /// The member at the end of [itemPath], the item path below the target, reached from the
  /// project file at [projectPath]: the project's item for the first library leads to its
  /// library file, each library's item to the next, and the last library's item to the member.
  /// When a library file on the way is not in the tree, the member is looked for at the item
  /// path below that library's directory, which is where a library keeps a member whose virtual
  /// folders mirror its directories.
  File? _throughProject(String projectPath, List<String> itemPath) {
    final LvLibraryFile project;
    try {
      project = LvLibraryFile.parse(File(projectPath).readAsStringSync(), fileName: 'project.lvproj');
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    var container = project;
    var containerPath = projectPath;
    for (var i = 0; i < itemPath.length - 1; i++) {
      final component = itemPath[i];
      final owner = LvLibraryKind.ofPath(component);
      if (owner == null || owner == LvLibraryKind.project) continue;
      final item = _itemNamed(container, component);
      if (item?.url == null) return null;
      containerPath = resolveLibraryUrl(containerPath, item!.url!);
      final library = libraries.libraries[containerPath];
      if (library == null) {
        final below = Uri.directory(containerPath).resolve('.').resolveUri(Uri(pathSegments: itemPath.sublist(i + 1)));
        final file = File(below.toFilePath());
        return file.existsSync() ? file : null;
      }
      container = library;
    }
    final member = _itemNamed(container, itemPath.last);
    if (member?.url == null) return null;
    final file = File(resolveLibraryUrl(containerPath, member!.url!));
    return file.existsSync() ? file : null;
  }

  static LvLibraryItem? _itemNamed(LvLibraryFile container, String name) {
    final lower = name.toLowerCase();
    for (final item in container.items) {
      if (!item.isFolder && item.name.toLowerCase() == lower) return item;
    }
    return null;
  }
}

/// What one export of a source tree produced and left out.
class SeqTreeMeasures {
  SeqTreeMeasures({required this.sequenceFiles, required this.unparsedSequenceFiles, required this.seq});

  final int sequenceFiles;

  final int unparsedSequenceFiles;

  /// LabVIEW steps whose VI was located and lowered to a function with a body.
  int stepsLowered = 0;

  /// LabVIEW steps whose VI was located but whose lowering refused, so the step calls a throwing
  /// function typed by the VI's connector pane.
  int stepsStubbed = 0;

  /// LabVIEW steps whose VI file was located but read with no block diagram with content.
  int stepsWithoutDiagram = 0;

  /// LabVIEW steps whose VI was not located, by how the step states its path.
  final Map<SeqViPathKind, int> stepsUnlocated = {};

  /// Every function emitted: the VIs steps call and, transitively, the VIs those call.
  int viFunctions = 0;

  int viLowered = 0;

  int viStubbed = 0;

  /// Refused VIs by the refusal's kind.
  final Map<String, int> refusalsByKind = {};

  int declarations = 0;

  final SeqExportStats seq;

  int get labViewSteps =>
      stepsLowered + stepsStubbed + stepsWithoutDiagram + stepsUnlocated.values.fold(0, (sum, n) => sum + n);
}

class SeqTreeExport {
  const SeqTreeExport({required this.files, required this.measures});

  /// Every generated file by its path relative to the package root.
  final Map<String, String> files;

  final SeqTreeMeasures measures;

  void write(Directory out) {
    for (final MapEntry(key: path, value: source) in files.entries) {
      File('${out.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(source);
    }
  }
}

/// The shared declarations file of an exported tree.
const String kSeqExportTypesFile = 'lv_types.dart';

/// The path of the directory [to] from the directory [from], both absolute, as a `pubspec.yaml`
/// path dependency states it.
String seqRelativeDirectory({required String from, required String to}) {
  final fromParts = Uri.directory(from).pathSegments.where((s) => s.isNotEmpty).toList();
  final toParts = Uri.directory(to).pathSegments.where((s) => s.isNotEmpty).toList();
  var shared = 0;
  while (shared < fromParts.length && shared < toParts.length && fromParts[shared] == toParts[shared]) {
    shared++;
  }
  return [for (var i = shared; i < fromParts.length; i++) '..', ...toParts.sublist(shared)].join('/');
}

/// Exports every text sequence file under [root] as a Dart package: one `<dir>/<stem>.seq.dart`
/// per sequence file, one `<dir>/<stem>.vi.dart` per VI a step calls or one of those calls, the
/// nominal types they share in [kSeqExportTypesFile], `main.dart`, and a `pubspec.yaml` whose
/// [pathDependencies] map each package name to its path from the output directory.
SeqTreeExport exportSeqTree(
  Directory root, {
  required String packageName,
  required Map<String, String> pathDependencies,
}) {
  final tree = SeqSourceTree.scan(root);
  final stats = SeqExportStats();
  final measures = SeqTreeMeasures(
    sequenceFiles: tree.sequenceFiles.length,
    unparsedSequenceFiles: tree.unparsed.length,
    seq: stats,
  );

  final units = <String, LvViUnit?>{};
  LvViUnit? unitOf(File file, String fileName) => units.putIfAbsent(file.path, () {
    try {
      return LvViUnit.fromSections(decodeSections(file.readAsBytesSync()), fileName: fileName, path: file.path);
    } on Exception {
      return null;
    }
  });

  final targets = <(String, String), SeqViTarget>{};
  final steps = <SeqViTarget>[];
  final entries = <String, LvViUnit>{};
  for (final MapEntry(key: path, value: file) in tree.sequenceFiles.entries) {
    for (final sequence in file.sequences) {
      for (final step in sequence.steps) {
        final module = step.module;
        if (module.adapter != SeqAdapter.labView) continue;
        final target = targets.putIfAbsent((path, module.viPath ?? ''), () => tree.locate(path, module));
        steps.add(target);
        if (target case SeqViFile(:final file)) {
          final unit = unitOf(file, file.uri.pathSegments.last);
          if (unit != null) entries[file.path] = unit;
        }
      }
    }
  }

  final emitted = emitLvFunctions(
    entries.values,
    resolveSubVi: (callee) {
      final linked = switch ((callee.link, callee.caller.path)) {
        (final link?, final viPath?) => tree.libraries.fileOfLink(link, viPath: viPath),
        _ => null,
      };
      final file = linked != null && File(linked).existsSync() ? File(linked) : tree.uniqueViNamed(callee.fileName);
      return file == null ? null : unitOf(file, callee.fileName);
    },
    classes: LvProjectClassIndex(tree.libraries),
  );

  final files = <String, String>{};
  final takenPaths = <String>{};
  final fileOfFunction = <String, String>{};
  final byViPath = <String, LvEmittedFunction>{};
  for (final function in emitted.functions) {
    measures.viFunctions++;
    if (function.refusal case final refusal?) {
      measures.viStubbed++;
      measures.refusalsByKind[refusal.kind.name] = (measures.refusalsByKind[refusal.kind.name] ?? 0) + 1;
    } else {
      measures.viLowered++;
    }
    final viPath = function.unit.path!;
    byViPath[viPath] = function;
    fileOfFunction[function.functionName] = _uniquePath(_viDartPath(root, viPath), takenPaths);
  }

  final declarationNames = [for (final declaration in emitted.declarations) declaration.name];
  final spellsDeclaration = declarationNames.isEmpty
      ? null
      : RegExp('\\b(?:${declarationNames.map(RegExp.escape).join('|')})\\b');
  if (emitted.declarations.isNotEmpty) {
    measures.declarations = emitted.declarations.length;
    final body = [for (final declaration in emitted.declarations) lvDeclarationSource(declaration)].join('\n');
    files[kSeqExportTypesFile] = lvFormatDart(
      '${_viHeader('the typedefs, clusters and enums the exported VIs share')}'
      '${_importLines(lvImportsSpelledIn(body))}$body',
    );
  }
  for (final function in emitted.functions) {
    final path = fileOfFunction[function.functionName]!;
    final constants = [
      for (final MapEntry(key: name, value: source) in emitted.constants.entries)
        if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(function.source)) source,
    ];
    final body = '${constants.join('\n')}\n${function.source}';
    final imports = <String>{
      ...lvImportsSpelledIn(body),
      if (spellsDeclaration != null && spellsDeclaration.hasMatch(lvCodeOf(body)))
        seqRelativeImport(path, kSeqExportTypesFile),
      for (final callee in function.callees)
        if (callee != function.functionName) seqRelativeImport(path, fileOfFunction[callee]!),
    };
    files[path] = lvFormatDart(
      '${_viHeader('the block diagram of ${SeqSourceTree._relative(root, function.unit.path!)}')}'
      '${_importLines(imports)}$body',
    );
  }

  for (final target in steps) {
    switch (target) {
      case SeqViFile(:final file):
        switch (byViPath[file.path]) {
          case null:
            measures.stepsWithoutDiagram++;
          case LvEmittedFunction(isLowered: true):
            measures.stepsLowered++;
          case LvEmittedFunction():
            measures.stepsStubbed++;
        }
      case SeqViUnlocated(:final kind):
        measures.stepsUnlocated[kind] = (measures.stepsUnlocated[kind] ?? 0) + 1;
    }
  }

  SeqViCall? resolveViCall(String sourceKey, StepModule module) {
    final target = targets[(sourceKey, module.viPath ?? '')];
    if (target is! SeqViFile) return null;
    final function = byViPath[target.file.path];
    if (function == null) return null;
    return SeqViCall(
      functionName: function.functionName,
      filePath: fileOfFunction[function.functionName]!,
      parameters: {
        for (final port in function.parameters) port.pane: SeqViPort(name: port.name, dartType: port.dartType),
      },
      results: {
        for (final port in function.results) port.pane: SeqViPort(name: port.name, dartType: port.dartType),
      },
      elided: function.elided,
      undecided: function.undecided,
      refusal: function.refusal?.toString(),
    );
  }

  final project = exportSeqProjectToLabwright(
    tree.sequenceFiles,
    layout: SeqProjectLayout.mirrored,
    resolveViCall: resolveViCall,
    stats: stats,
  );
  files.addAll(project.files);
  files['pubspec.yaml'] = [
    'name: $packageName',
    'description: Generated from the TestStand sequence files and LabVIEW VIs of a source tree.',
    'publish_to: none',
    '',
    'environment:',
    "  sdk: '>=3.11.0 <4.0.0'",
    '',
    'dependencies:',
    for (final MapEntry(key: name, value: path) in pathDependencies.entries) ...['  $name:', '    path: $path'],
    '',
  ].join('\n');
  return SeqTreeExport(files: files, measures: measures);
}

String _viDartPath(Directory root, String viPath) {
  final relative = SeqSourceTree._relative(root, viPath);
  final segments = relative.split('/');
  final stem = segments.removeLast().replaceFirst(RegExp(r'\.vi$', caseSensitive: false), '');
  final directory = seqSnakeDirectory(segments.join('/'));
  return '${directory.isEmpty ? '' : '$directory/'}${seqSnakeCase(stem)}';
}

String _uniquePath(String stem, Set<String> taken) {
  var candidate = stem;
  for (var index = 2; !taken.add(candidate); index++) {
    candidate = '$stem$index';
  }
  return '$candidate.vi.dart';
}

String _viHeader(String note) =>
    '// GENERATED by package:labwright_seq exportSeqTree — do not edit by hand.\n'
    '//\n'
    '// Lowered from $note.\n\n';

String _importLines(Set<String> imports) {
  if (imports.isEmpty) return '';
  final sorted = imports.toList()..sort();
  return '${[for (final import in sorted) "import '$import';"].join('\n')}\n\n';
}
