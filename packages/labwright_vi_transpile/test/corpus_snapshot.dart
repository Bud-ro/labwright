import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

import 'snippets.dart';

const corpusSnapshotPath = 'test/corpus_snapshot.json';

const List<String> kSnippetDirs = [
  'vi-corpus/sources/rcpacini__VI-Snippets',
  'vi-corpus/sources/rcpacini__LabVIEW-VI-Snippet/Examples/Snippets',
];

const Set<int> kLvStructureOwnedNodeKinds = {
  kInPlaceBorderNodeKind,
  kInPlaceClusterNodeKind,
  kInPlaceDataValueRefNodeKind,
  kFeedbackNodeKind,
  kFeedbackInputKind,
};

typedef CorpusSweep = ({List<String> lines, Set<String> sources, List<String> directionDisagreements});

String corpusRelativePath(String path) => path.substring(corpusVi.path.length + 1).replaceAll(r'\', '/');

String corpusSnapshotText(List<String> lines) => '[\n${lines.join(',\n')}\n]\n';

String _line(String name, List<String?> outcomes, Iterable<String> unruled) => jsonEncode({
  'name': name,
  'lowering': outcomes.first,
  if (outcomes.last != outcomes.first) 'threaded': outcomes.last,
  if (unruled.isNotEmpty) 'unruled': unruled.toList()..sort(),
});

Set<String> unruledPrimitives(BdDiagram diagram) => {
  for (final object in diagram.objects)
    if (object.category == BdObjectKind.node &&
        !(kSubViCallNodeCodes.contains(object.kind) && object.kind != BdObjectClass.propertyNode.code) &&
        object.kind != BdObjectClass.callLibrary.code &&
        !kLvStructureOwnedNodeKinds.contains(object.kind))
      if (object.primitive?.primResId case final id
          when !lvPrimHasRule(op: id == null ? null : PrimOp.fromId(id), classCode: object.kind, primResId: id))
        _reviewKey(id == null ? null : PrimOp.fromId(id), object),
};

String _reviewKey(PrimOp? op, BdObject object) {
  if (op != null) return '${op.opName} (primResID ${op.id})';
  if (object.primitive?.primResId case final id?) return 'primResID $id (name not decoded)';
  return 'node class 0x${object.kind.toRadixString(16)}';
}

String? _snippetOutcome(LvViUnit unit, LvErrorMode mode) =>
    emitLvFunction(unit.diagram, functionName: 'lowered', pool: unit.pool, errorMode: mode).refusal?.kind.name ??
    'lowered';

List<String> snippetLines() => [
  for (final dir in kSnippetDirs)
    for (final png in corpusFiles(Directory('${corpusVi.path}/$dir'), '.png'))
      if (extractSnippetVi(png.readAsBytesSync()) case final vi?)
        if (LvViUnit.fromSections(
              decodeSections(Uint8List.fromList(vi)),
              fileName: png.uri.pathSegments.last.replaceAll('.png', '.vi'),
            )
            case final unit?)
          _line(corpusRelativePath(png.path), [
            for (final mode in LvErrorMode.values) _snippetOutcome(unit, mode),
          ], unruledPrimitives(unit.diagram)),
];

CorpusSweep sweepLoweringChunk((List<String>, Map<String, String>) input) {
  final (paths, index) = input;
  final lines = <String>[], emitted = <String>{}, disagreements = <String>[];
  final units = <String, LvViUnit?>{};
  final libraries = LvProjectIndex.scan(corpusVi);
  LvViUnit? load(String path, String fileName) => units.putIfAbsent(path, () {
    try {
      return LvViUnit.fromSections(decodeSections(File(path).readAsBytesSync()), fileName: fileName, path: path);
    } catch (_) {
      return null;
    }
  });
  LvViUnit? resolveCallee(LvCallee callee) {
    if ((callee.link, callee.caller.path) case (final link?, final viPath?)) {
      final linked = libraries.fileOfLink(link, viPath: viPath);
      if (linked != null && File(linked).existsSync()) return load(linked, callee.fileName);
    }
    final path = index[callee.fileName.toLowerCase()];
    return path == null ? null : load(path, callee.fileName);
  }

  final classData = <String, ViModel?>{};
  ViModel? resolveClass(List<String> qualifiedName) => classData.putIfAbsent(qualifiedName.join(':'), () {
    final path = libraries.fileOf(qualifiedName);
    if (path == null) return null;
    try {
      final control = LvLibraryFile.parse(
        File(path).readAsStringSync(),
        fileName: qualifiedName.last,
      ).privateDataControl;
      return control == null ? null : buildViModel(control);
    } catch (_) {
      return null;
    }
  });
  void checkCall(String name, LvDataflow flow, LvViUnit caller, LvSubViUnit call) {
    final calleeName = call.calleeName;
    if (calleeName == null) return;
    final link = caller.linkTo(calleeName);
    if (link == null &&
        caller.links.any((l) => l.qualifiedName.lastOrNull?.toLowerCase() == calleeName.toLowerCase())) {
      return;
    }
    if (lvVilibVis.containsKey(calleeName.toLowerCase()) &&
        (link?.path?.text.startsWith('<vilib>') ?? caller.links.isEmpty)) {
      return;
    }
    final callee = resolveCallee(LvCallee(caller: caller, fileName: calleeName, link: link));
    if (callee == null || callee.paneTerminals.isEmpty || callee.paneTerminals.length != call.panePorts.length) return;
    for (var pane = 0; pane < call.panePorts.length; pane++) {
      final into = flow.into(call.panePorts[pane]), outOf = flow.outOf(call.panePorts[pane]);
      final terminal = callee.paneTerminal(pane);
      if ((into == null && outOf == null) || terminal == null) continue;
      if ((into != null) != !lvEndpointIsSink(terminal)) disagreements.add('$name: $calleeName pane $pane');
    }
  }

  void walk(String name, LvDataflow flow, LvViUnit caller, LvRegion region) {
    for (final unit in region.units) {
      if (unit is LvSubViUnit) checkCall(name, flow, caller, unit);
      if (unit is LvStructUnit) {
        for (final frame in unit.frames) {
          walk(name, flow, caller, frame);
        }
      }
    }
  }

  for (final path in paths) {
    final name = corpusRelativePath(path);
    final unit = load(path, path.split(Platform.pathSeparator).last);
    if (unit == null) {
      lines.add(jsonEncode({'name': name, 'lowering': 'unread'}));
      continue;
    }
    final built = buildLvDataflow(
      unit.diagram,
      pool: unit.pool,
      declarations: LvDeclarations(),
      caller: unit,
      resolve: resolveCallee,
      resolveClass: resolveClass,
    );
    if (built.dataflow case final flow?) walk(name, flow, unit, flow.root);
    final outcomes = <String?>[];
    for (final mode in LvErrorMode.values) {
      final result = emitLvLibrary(
        unit,
        functionName: 'lowered',
        errorMode: mode,
        resolveSubVi: resolveCallee,
        resolveClass: resolveClass,
      );
      outcomes.add(result.refusal?.kind.name ?? 'lowered');
      if (mode == LvErrorMode.exceptions && result.source != null) emitted.add(result.source!);
    }
    lines.add(_line(name, outcomes, unruledPrimitives(unit.diagram)));
  }
  return (lines: lines, sources: emitted, directionDisagreements: disagreements);
}

Future<CorpusSweep> corpusSweep() => _corpusSweep ??= _runCorpusSweep();

Future<CorpusSweep>? _corpusSweep;

Future<CorpusSweep> _runCorpusSweep() async {
  final paths = corpusViPaths();
  final index = <String, String>{};
  for (final path in paths) {
    index.putIfAbsent(path.split(Platform.pathSeparator).last.toLowerCase(), () => path);
  }
  final workers = (Platform.numberOfProcessors - 2).clamp(1, 16);
  final chunks = List.generate(workers, (_) => <String>[]);
  for (var i = 0; i < paths.length; i++) {
    chunks[i % workers].add(paths[i]);
  }
  final results = await Future.wait(chunks.map((chunk) => Isolate.run(() => sweepLoweringChunk((chunk, index)))));
  return (
    lines: [...snippetLines(), for (final result in results) ...result.lines]..sort(),
    sources: {for (final result in results) ...result.sources},
    directionDisagreements: [for (final result in results) ...result.directionDisagreements],
  );
}
