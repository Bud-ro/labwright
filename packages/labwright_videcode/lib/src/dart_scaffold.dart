import 'graph.dart';
import 'ir.dart';
import 'type_pool.dart';

/// Marker line embedded in every [generateDartScaffold] output — the honest
/// disclaimer that this is a structural outline; the dataflow is not yet
/// recovered. Tests and tools can detect generated scaffolds by this string.
const String scaffoldMarker = 'structural scaffold, dataflow not yet recovered';

/// Max control/label captions listed as candidate parameters before truncating
/// (with an explicit "+N more" note — never a silent cap). A few VIs carry
/// hundreds of captions; the header stays readable without hiding the count.
const int _captionCap = 50;

/// Max nesting depth the scaffold walk recurses before stopping (with a
/// truncation note). Real diagrams nest a few dozen levels; a corrupt/hostile
/// heap could encode thousands, so this bounds the recursion to keep generation
/// total (no `StackOverflowError`). Anything cut off here is still listed by the
/// trailing "outside the nesting tree" coverage pass, so nothing is dropped.
const int _maxNestingDepth = 96;

/// Max characters of the VI's description shown in the header (truncated with an
/// ellipsis). Descriptions are usually a line or two but can be long help text.
const int _descCap = 200;

/// Max named typedefs listed in the scaffold header before truncating (with a
/// "+N more" note). VIs can define dozens; the header stays readable.
const int _namedTypeCap = 40;

/// Max recovered cluster structures listed in the scaffold header before
/// truncating (with a "+N more" note).
const int _structCap = 20;

/// Max enum item labels shown inline for a named enum (with a "…" if more).
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
  final b = StringBuffer()
    ..writeln('// AUTO-GENERATED structural scaffold (labwright_videcode VI->IR->Dart).')
    ..writeln('// $scaffoldMarker —')
    ..writeln('// LabVIEW wires are stored as geometry, so node->node dataflow is not yet')
    ..writeln('// decoded; this is a STRUCTURAL OUTLINE of the block diagram. Fill in.')
    ..writeln('// Nodes are listed in POSITIONAL order (visual top->left), which is NOT')
    ..writeln('// execution/dataflow order (that is not recovered).');
  if (model.version != null) b.writeln('// Saved in LabVIEW ${model.version}.');
  final desc = model.description?.trim();
  if (desc != null && desc.isNotEmpty) {
    final one = _oneLine(desc);
    b.writeln('// Description: ${one.length > _descCap ? '${one.substring(0, _descCap)}…' : one}');
  }
  if (model.symbolNames.isNotEmpty) {
    b.writeln('// Call-Library functions referenced:');
    for (final s in model.symbolNames) {
      b.writeln('//   - ${_oneLine(s)}');
    }
  }
  if (model.paths.isNotEmpty) {
    b.writeln('// Libraries referenced:');
    for (final p in model.paths) {
      b.writeln('//   - ${_oneLine(p)}');
    }
  }
  if (model.subViNames.isNotEmpty) {
    b.writeln('// SubVIs called (from LIbd; which node calls which is not yet recovered):');
    for (final s in model.subViNames) {
      b.writeln('//   - ${_oneLine(s)}');
    }
  }
  if (model.types.isNotEmpty) {
    final hist = typeKindHistogram(model.types);
    final summary = hist.entries.map((e) => '${e.key}:${e.value}').join(', ');
    b.writeln('// Data types (VCTP, ${model.types.length}): ${_oneLine(summary)}');
  }
  final named = namedTypes(model.types);
  if (named.isNotEmpty) {
    b.writeln('// Named types (typedefs / labelled data items):');
    for (final t in named.take(_namedTypeCap)) {
      if (t.enumItems.isNotEmpty) {
        final items = t.enumItems.take(_enumItemCap).map(_oneLine).join(', ');
        final more = t.enumItems.length > _enumItemCap ? ', …' : '';
        b.writeln('//   enum ${_oneLine(t.name!)} { $items$more }');
      } else {
        b.writeln('//   ${typeLabel(t, model.types)} ${_oneLine(t.name!)}');
      }
    }
    if (named.length > _namedTypeCap) {
      b.writeln('//   (+${named.length - _namedTypeCap} more not shown)');
    }
  }
  // Recovered cluster structures (named clusters with resolved member fields) —
  // honest field KINDS (+ a member's typedef name where it has one); shown as a
  // comment, not real Dart, since field names are only partially recoverable.
  final structs = [
    for (final t in model.types)
      if (t.kind == ViDataType.cluster && t.name != null && t.members.isNotEmpty) t,
  ];
  if (structs.isNotEmpty) {
    b.writeln('// Recovered cluster structures:');
    for (final t in structs.take(_structCap)) {
      final fields = clusterFields(t, model.types)
          .map((f) => f.name != null ? '${typeLabel(f, model.types)} ${_oneLine(f.name!)}' : typeLabel(f, model.types))
          .join('; ');
      b.writeln('//   ${_oneLine(t.name!)} { $fields }');
    }
    if (structs.length > _structCap) {
      b.writeln('//   (+${structs.length - _structCap} more not shown)');
    }
  }
  // Connector pane — the VI's actual interface terminals (from CONP -> VCTP).
  // More reliable than caption-guessing: when the conpane type is a cluster its
  // members ARE the terminals; otherwise it is a single terminal. Direction
  // (input vs output) is NOT recovered from the diagram, so we don't claim it.
  final cpIdx = model.connectorPaneTypeIndex;
  if (cpIdx != null && cpIdx >= 1 && cpIdx <= model.types.length) {
    final cp = model.types[cpIdx - 1];
    final terms = cp.kind == ViDataType.cluster ? clusterFields(cp, model.types) : <ViType>[cp];
    b.writeln("// Connector-pane terminals (the VI's interface; in/out direction not recovered):");
    for (final t in terms) {
      final nm = t.name != null && t.name!.isNotEmpty ? ' ${_oneLine(t.name!)}' : '';
      b.writeln('//   ${typeLabel(t, model.types)}$nm');
    }
  }
  // Candidate parameters: the VI's recovered control/label captions. These are
  // the NAMES of the VI's controls/indicators — the raw material of its function
  // signature — but the block diagram alone does not say which are inputs vs
  // outputs, nor their types, so they are listed (not turned into typed params).
  final captions = model.captions;
  if (captions.isNotEmpty) {
    b.writeln('// Candidate parameters (control/label captions — direction & type');
    b.writeln('// are not yet recovered from the diagram, so these are names only):');
    for (final c in captions.take(_captionCap)) {
      b.writeln('//   ${_oneLine(c)}');
    }
    if (captions.length > _captionCap) {
      b.writeln('//   (+${captions.length - _captionCap} more not shown)');
    }
  }
  b
    ..writeln()
    ..writeln('void ${_ident(name)}() {');

  final diagrams = [
    for (final d in model.blockDiagrams)
      if (d.objects.any((o) => o.category == ViObjectKind.structure || o.category == ViObjectKind.node)) d,
  ];
  if (diagrams.isEmpty) {
    b.writeln('  // (no block-diagram structures or nodes recovered)');
  } else {
    for (var i = 0; i < diagrams.length; i++) {
      if (diagrams.length > 1) b.writeln('  // --- block diagram ${diagrams[i].sectionTag} ---');
      _emitDiagram(b, diagrams[i]);
    }
  }
  b.writeln('}');
  return b.toString();
}

void _emitDiagram(StringBuffer b, ViDiagram d) {
  final kids = <int, List<ViHeapObject>>{};
  for (final o in d.objects) {
    if (o.parentOid != null) (kids[o.parentOid!] ??= <ViHeapObject>[]).add(o);
  }
  // Emit each parent's children in POSITIONAL order (visual top→left), so the
  // outline reads like the diagram's layout instead of raw heap order. This is a
  // VISUAL heuristic only — it is NOT execution/dataflow order (wires aren't
  // recovered). Stable: equal/absent bounds keep heap order, null-bounds last.
  for (final k in kids.keys) {
    kids[k] = _positional(kids[k]!);
  }
  final present = {for (final o in d.objects) o.oid};
  final seen = <int>{};
  final emitted = <int>{};

  void walk(ViHeapObject o, int depth) {
    if (!seen.add(o.oid)) return; // visit each object once (cycle/repeat guard)
    if (depth > _maxNestingDepth) {
      // Stop recursing on pathological nesting; un-emitted structures/nodes are
      // still covered by the trailing leftover pass (they stay out of `emitted`).
      b.writeln('${'  ' * (depth + 1)}// (nesting truncated at depth $_maxNestingDepth)');
      return;
    }
    final pad = '  ' * (depth + 1);
    final children = kids[o.oid] ?? const <ViHeapObject>[];
    switch (o.category) {
      case ViObjectKind.structure:
        b.writeln('$pad// ${_oneLine(o.objectClass.label)}  [oid ${o.oid}] {');
        emitted.add(o.oid);
        for (final c in children) {
          walk(c, depth + 1);
        }
        b.writeln('$pad// }');
      case ViObjectKind.node:
        b.writeln('$pad// ${_nodeStub(o)}  [oid ${o.oid}]');
        emitted.add(o.oid);
        for (final c in children) {
          walk(c, depth + 1);
        }
      case ViObjectKind.terminal:
      case ViObjectKind.terminalCluster:
      case ViObjectKind.decoration:
      case ViObjectKind.unknown:
        // not logic — don't emit, but recurse to reach nested structures/nodes
        for (final c in children) {
          walk(c, depth);
        }
    }
  }

  for (final r in _positional(d.roots.toList())) {
    walk(r, 0);
  }
  // objects whose parent is absent (orphans) are still roots of their own subtree
  for (final o in d.objects) {
    if (o.parentOid != null && !present.contains(o.parentOid)) walk(o, 0);
  }
  // coverage guarantee: any structure/node not reached above (e.g. in a cycle)
  final leftover = [
    for (final o in d.objects)
      if ((o.category == ViObjectKind.structure || o.category == ViObjectKind.node) && !emitted.contains(o.oid)) o,
  ];
  if (leftover.isNotEmpty) {
    b.writeln('  // (objects outside the nesting tree:)');
    for (final o in leftover) {
      final body = o.category == ViObjectKind.structure ? _nodeName(o) : _nodeStub(o);
      b.writeln('  // $body  [oid ${o.oid}]');
    }
  }
}

/// Orders objects by their on-diagram position (top, then left) — a VISUAL
/// reading order, NOT execution order. Objects with no/invalid bounds sort last;
/// ties (and bounds-less objects) keep their original heap order (stable).
List<ViHeapObject> _positional(List<ViHeapObject> objs) {
  final indexed = [for (var i = 0; i < objs.length; i++) (o: objs[i], i: i)];
  indexed.sort((a, b) {
    final ab = a.o.absBounds;
    final bb = b.o.absBounds;
    final av = ab != null && ab.isValid;
    final bv = bb != null && bb.isValid;
    if (av != bv) return av ? -1 : 1; // bounds-less last
    if (av && bv) {
      final t = ab.top.compareTo(bb.top);
      if (t != 0) return t;
      final l = ab.left.compareTo(bb.left);
      if (l != 0) return l;
    }
    return a.i.compareTo(b.i); // stable tiebreak = heap order
  });
  return [for (final e in indexed) e.o];
}

/// The stub line body for a node: a subVI-call node carries the called-VI
/// filename in its 0xa caption (recovered ~99.6%), so emit it as `calls <name>`;
/// every other node stays a generic `TODO: <name/hint>`. This names WHAT is
/// called, never which wires connect calls (dataflow is not recovered).
String _nodeStub(ViHeapObject o) {
  final name = _nodeName(o);
  final lower = name.toLowerCase();
  final isCall = lower.endsWith('.vi') || lower.endsWith('.lvclass') || lower.endsWith('.lvlib');
  return isCall ? 'calls $name' : 'TODO: $name';
}

String _nodeName(ViHeapObject o) {
  final l = o.label?.trim();
  return _oneLine(l != null && l.isNotEmpty ? l : o.objectClass.label);
}

/// Collapses newlines/control chars to single spaces so a value stays on one
/// comment line, and neutralizes a stray `*/` that could close a block comment.
String _oneLine(String s) => s
    .replaceAll(RegExp(r'[\x00-\x1f]+'), ' ')
    .replaceAll('*/', '* /')
    .trim();

/// Makes [name] a safe lowerCamel-ish Dart identifier for the function stub.
String _ident(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (cleaned.isEmpty || RegExp(r'^[0-9]').hasMatch(cleaned)) return 'vi_$cleaned';
  return cleaned;
}
