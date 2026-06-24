import 'graph.dart';
import 'ir.dart';

/// Marker line embedded in every [generateDartScaffold] output — the honest
/// disclaimer that this is a structural outline, not recovered logic. Tests and
/// tools can detect generated scaffolds by this string.
const String scaffoldMarker = 'structural scaffold, no dataflow recovered';

/// Generates an **honest structural Dart scaffold** from a decoded [ViModel] —
/// the first VI→IR→Dart codegen step. It is deliberately NOT executable logic:
/// LabVIEW stores wires as pure geometry with no recoverable node→node
/// endpoints, so dataflow cannot be reconstructed from the block diagram alone.
/// What it CAN do, and does, is lay out the VI's recovered *structure*:
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
    ..writeln('// LabVIEW wires are geometry with no recoverable endpoints, so this is a')
    ..writeln('// STRUCTURAL OUTLINE of the block diagram, not executable logic. Fill in.');
  if (model.version != null) b.writeln('// Saved in LabVIEW ${model.version}.');
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
  final present = {for (final o in d.objects) o.oid};
  final seen = <int>{};
  final emitted = <int>{};

  void walk(ViHeapObject o, int depth) {
    if (!seen.add(o.oid)) return; // visit each object once (cycle/repeat guard)
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
        b.writeln('$pad// TODO: ${_nodeName(o)}  [oid ${o.oid}]');
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

  for (final r in d.roots) {
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
      final tag = o.category == ViObjectKind.structure ? '' : 'TODO: ';
      b.writeln('  // $tag${_nodeName(o)}  [oid ${o.oid}]');
    }
  }
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
