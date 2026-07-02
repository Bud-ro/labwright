import 'blocks/type_pool.dart';
import 'graph.dart';
import 'ir.dart';

/// Marker line embedded in every [generateDartScaffold] output — the honest
/// disclaimer that this is a structural outline; the dataflow is not yet
/// recovered. Tests and tools can detect generated scaffolds by this string.
const String scaffoldMarker = 'structural scaffold, dataflow not yet recovered';

const int _captionCap = 50;

/// Max nesting depth the scaffold walk recurses before stopping (with a
/// truncation note). Real diagrams nest a few dozen levels; a corrupt/hostile
/// heap could encode thousands, so this bounds the recursion to keep generation
/// total (no `StackOverflowError`). Anything cut off here is still listed by the
/// trailing "outside the nesting tree" coverage pass, so nothing is dropped.
const int _maxNestingDepth = 96;

const int _descCap = 200;

const int _namedTypeCap = 40;

const int _structCap = 20;

const int _enumItemCap = 16;

/// Generates an **honest structural Dart scaffold** from a decoded [ViModel] —
/// the first VI→IR→Dart codegen step. It is deliberately NOT executable logic
/// yet: LabVIEW stores wires as geometry, so node→node dataflow is not yet
/// decoded from the block diagram.
/// What it does today is lay out the VI's recovered *structure* (dataflow wiring
/// is future work, not yet decoded):
///
/// - a function stub named [name] (the IR carries no reliable VI name);
/// - the Call-Library function symbols + library paths the VI references, listed
///   in the header as the native call surface a translator must bind;
/// - each block-diagram **structure** (loop/case/sequence) as a nested,
///   commented block reflecting the positional nesting (`parentOid`);
/// - each **node / subVI** as a `// TODO:` stub carrying its label (or class
///   name when unlabeled).
///
/// Every structure and node is represented — nothing is silently dropped
/// (objects outside the nesting tree are listed in a trailing section). Terminals,
/// decorations and unclassified heap objects are not logic and are not emitted
/// (only traversed). Deterministic: output depends only on [model].
String generateDartScaffold(ViModel model, {String name = 'vi'}) {
  final out = StringBuffer()
    ..writeln('// AUTO-GENERATED structural scaffold (labwright_rsrc_parse VI->IR->Dart).')
    ..writeln('// $scaffoldMarker —')
    ..writeln('// LabVIEW wires are stored as geometry, so node->node dataflow is not yet')
    ..writeln('// decoded; this is a STRUCTURAL OUTLINE of the block diagram. Fill in.')
    ..writeln('// Nodes are listed in POSITIONAL order (visual top->left), which is NOT')
    ..writeln('// execution/dataflow order (that is not recovered).');
  if (model.version != null) out.writeln('// Saved in LabVIEW ${model.version}.');
  final desc = model.description?.trim();
  if (desc != null && desc.isNotEmpty) {
    final one = _oneLine(desc);
    out.writeln('// Description: ${one.length > _descCap ? '${one.substring(0, _descCap)}…' : one}');
  }
  if (model.symbolNames.isNotEmpty) {
    out.writeln('// Call-Library functions referenced:');
    for (final symbol in model.symbolNames) {
      out.writeln('//   - ${_oneLine(symbol)}');
    }
  }
  if (model.paths.isNotEmpty) {
    out.writeln('// Libraries referenced:');
    for (final path in model.paths) {
      out.writeln('//   - ${_oneLine(path)}');
    }
  }
  if (model.subViNames.isNotEmpty) {
    out.writeln('// SubVIs called (from LIbd; which node calls which is not yet recovered):');
    for (final subViName in model.subViNames) {
      out.writeln('//   - ${_oneLine(subViName)}');
    }
  }
  if (model.types.isNotEmpty) {
    final hist = typeKindHistogram(model.types);
    final summary = hist.entries.map((e) => '${e.key}:${e.value}').join(', ');
    out.writeln('// Data types (VCTP, ${model.types.length}): ${_oneLine(summary)}');
  }
  final named = namedTypes(model.types);
  if (named.isNotEmpty) {
    out.writeln('// Named types (typedefs / labelled data items):');
    for (final type in named.take(_namedTypeCap)) {
      if (type.enumItems.isNotEmpty) {
        final items = type.enumItems.take(_enumItemCap).map(_oneLine).join(', ');
        final more = type.enumItems.length > _enumItemCap ? ', …' : '';
        out.writeln('//   enum ${_oneLine(type.name!)} { $items$more }');
      } else {
        out.writeln('//   ${typeLabel(type, model.types)} ${_oneLine(type.name!)}');
      }
    }
    if (named.length > _namedTypeCap) {
      out.writeln('//   (+${named.length - _namedTypeCap} more not shown)');
    }
  }
  final structs = [
    for (final type in model.types)
      if (type.kind == ViDataType.cluster && type.name != null && type.members.isNotEmpty) type,
  ];
  if (structs.isNotEmpty) {
    out.writeln('// Recovered cluster structures:');
    for (final type in structs.take(_structCap)) {
      final fields = clusterFields(type, model.types)
          .map((f) => f.name != null ? '${typeLabel(f, model.types)} ${_oneLine(f.name!)}' : typeLabel(f, model.types))
          .join('; ');
      out.writeln('//   ${_oneLine(type.name!)} { $fields }');
    }
    if (structs.length > _structCap) {
      out.writeln('//   (+${structs.length - _structCap} more not shown)');
    }
  }
  final cpIdx = model.connectorPaneTypeIndex;
  final cpTerms = <ViType>[];
  if (cpIdx != null && cpIdx >= 1 && cpIdx <= model.types.length) {
    final cp = model.types[cpIdx - 1];
    cpTerms.addAll(cp.kind == ViDataType.cluster ? clusterFields(cp, model.types) : <ViType>[cp]);
    out.writeln("// Connector-pane terminals (the VI's interface; in/out direction not recovered):");
    for (final term in cpTerms) {
      final nm = term.name != null && term.name!.isNotEmpty ? ' ${_oneLine(term.name!)}' : '';
      out.writeln('//   ${typeLabel(term, model.types)}$nm');
    }
  }
  final captions = model.captions;
  if (captions.isNotEmpty) {
    out.writeln('// Candidate parameters (control/label captions — direction & type');
    out.writeln('// are not yet recovered from the diagram, so these are names only):');
    for (final caption in captions.take(_captionCap)) {
      out.writeln('//   ${_oneLine(caption)}');
    }
    if (captions.length > _captionCap) {
      out.writeln('//   (+${captions.length - _captionCap} more not shown)');
    }
  }
  if (cpTerms.isNotEmpty) {
    final sig = [
      for (final term in cpTerms)
        term.name != null && term.name!.isNotEmpty
            ? '${typeLabel(term, model.types)} ${_ident(_oneLine(term.name!))}'
            : typeLabel(term, model.types),
    ].join(', ');
    out
      ..writeln()
      ..writeln('// suggested signature (conpane terminals, positional — in/out not recovered):')
      ..writeln('//   ${_ident(name)}($sig)');
  }
  out
    ..writeln()
    ..writeln('void ${_ident(name)}() {');

  final diagrams = [
    for (final diagram in model.blockDiagrams)
      if (diagram.objects.any((o) => o.category == ViObjectKind.structure || o.category == ViObjectKind.node)) diagram,
  ];
  if (diagrams.isEmpty) {
    out.writeln('  // (no block-diagram structures or nodes recovered)');
  } else {
    for (var i = 0; i < diagrams.length; i++) {
      if (diagrams.length > 1) out.writeln('  // --- block diagram ${diagrams[i].sectionTag} ---');
      _emitDiagram(out, diagrams[i]);
    }
  }
  out.writeln('}');
  return out.toString();
}

/// Emits one diagram's structures/nodes into [b]. Children are walked in
/// positional (visual top→left) order — a layout heuristic, NOT execution/
/// dataflow order. Coverage is guaranteed: roots, orphans (whose parent is
/// absent), and any structure/node not reached by the nesting walk (e.g. in a
/// cycle) are all emitted — the last as a trailing "outside the nesting tree"
/// section — so nothing is silently dropped.
void _emitDiagram(StringBuffer b, ViDiagram d) {
  final kids = <int, List<ViHeapObject>>{};
  for (final object in d.objects) {
    if (object.parentOid != null) (kids[object.parentOid!] ??= <ViHeapObject>[]).add(object);
  }
  for (final parentOid in kids.keys) {
    kids[parentOid] = _positional(kids[parentOid]!);
  }
  final present = {for (final object in d.objects) object.oid};
  final seen = <int>{};
  final emitted = <int>{};

  void walk(ViHeapObject object, int depth) {
    if (!seen.add(object.oid)) return;
    if (depth > _maxNestingDepth) {
      b.writeln('${'  ' * (depth + 1)}// (nesting truncated at depth $_maxNestingDepth)');
      return;
    }
    final pad = '  ' * (depth + 1);
    final children = kids[object.oid] ?? const <ViHeapObject>[];
    switch (object.category) {
      case ViObjectKind.structure:
        b.writeln('$pad// ${_oneLine(object.objectClass.label)}  [oid ${object.oid}] {');
        emitted.add(object.oid);
        for (final child in children) {
          walk(child, depth + 1);
        }
        b.writeln('$pad// }');
      case ViObjectKind.node:
        b.writeln('$pad// ${_nodeStub(object)}  [oid ${object.oid}]');
        emitted.add(object.oid);
        for (final child in children) {
          walk(child, depth + 1);
        }
      case ViObjectKind.terminal:
      case ViObjectKind.terminalCluster:
      case ViObjectKind.decoration:
      case ViObjectKind.unknown:
        for (final child in children) {
          walk(child, depth);
        }
    }
  }

  for (final root in _positional(d.roots.toList())) {
    walk(root, 0);
  }
  for (final object in d.objects) {
    if (object.parentOid != null && !present.contains(object.parentOid)) walk(object, 0);
  }
  final leftover = [
    for (final object in d.objects)
      if ((object.category == ViObjectKind.structure || object.category == ViObjectKind.node) && !emitted.contains(object.oid)) object,
  ];
  if (leftover.isNotEmpty) {
    b.writeln('  // (objects outside the nesting tree:)');
    for (final object in leftover) {
      final body = object.category == ViObjectKind.structure ? _nodeName(object) : _nodeStub(object);
      b.writeln('  // $body  [oid ${object.oid}]');
    }
  }
}

/// Orders objects by their on-diagram position (top, then left) — a VISUAL
/// reading order, NOT execution order. Objects with no/invalid bounds sort last;
/// ties (and bounds-less objects) keep their original heap order (stable).
List<ViHeapObject> _positional(List<ViHeapObject> objs) {
  final indexed = [for (var i = 0; i < objs.length; i++) (object: objs[i], index: i)];
  indexed.sort((a, b) {
    final boundsA = a.object.absBounds;
    final boundsB = b.object.absBounds;
    final validA = boundsA != null && boundsA.isValid;
    final validB = boundsB != null && boundsB.isValid;
    if (validA != validB) return validA ? -1 : 1;
    if (validA && validB) {
      final byTop = boundsA.top.compareTo(boundsB.top);
      if (byTop != 0) return byTop;
      final byLeft = boundsA.left.compareTo(boundsB.left);
      if (byLeft != 0) return byLeft;
    }
    return a.index.compareTo(b.index);
  });
  return [for (final entry in indexed) entry.object];
}

/// The stub line body for a node: a subVI-call node carries the called-VI
/// filename in its 0xa caption (recovered ~99.6%), so emit it as `calls <name>`;
/// every other node stays a generic `TODO: <name/hint>`. This names WHAT is
/// called, never which wires connect calls (dataflow is not recovered).
String _nodeStub(ViHeapObject object) {
  final name = _nodeName(object);
  final lower = name.toLowerCase();
  final isCall = lower.endsWith('.vi') || lower.endsWith('.lvclass') || lower.endsWith('.lvlib');
  return isCall ? 'calls $name' : 'TODO: $name';
}

String _nodeName(ViHeapObject object) {
  final label = object.label?.trim();
  return _oneLine(label != null && label.isNotEmpty ? label : object.objectClass.label);
}

/// Collapses newlines/control chars to single spaces so a value stays on one
/// comment line, and neutralizes a stray `*/` that could close a block comment.
String _oneLine(String text) => text
    .replaceAll(RegExp(r'[\x00-\x1f]+'), ' ')
    .replaceAll('*/', '* /')
    .trim();

String _ident(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (cleaned.isEmpty || RegExp(r'^[0-9]').hasMatch(cleaned)) return 'vi_$cleaned';
  return cleaned;
}
