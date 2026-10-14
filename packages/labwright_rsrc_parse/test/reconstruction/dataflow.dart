import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// What a block diagram computes, read back through the editor and spelled without object
/// ids: every placed object by what it is, every structure by its border terminals and
/// frames, every wire by the names of the endpoints it joins and its type word's depth and
/// code. Two VIs with the same text wire the same things together.
String bdDataflow(ViModel model) {
  final diagram = model.primaryBlockDiagram!;
  final editor = model.blockDiagram;
  final names = <int, String>{};
  final sinks = <int, bool>{};
  final out = StringBuffer();

  List<BdPlaced> dataflowItems(BdFrame frame) => [
    for (final item in frame.placed)
      if (item is BdNode || item is BdConstant || item is BdPanelTerminal) item,
  ];

  void name(BdFrame frame, String prefix) {
    for (final (i, item) in dataflowItems(frame).indexed) {
      final id = '$prefix$i';
      switch (item) {
        case BdNode():
          for (final t in item.terminals) {
            names[t.oid] = '$id.${t.name}';
            sinks[t.oid] = t.isSink;
          }
          if (item is BdStructure) {
            for (final (j, t) in item.borderTerminals.indexed) {
              if (t.outer case final outer?) {
                names[outer.oid] = '$id.t$j';
                sinks[outer.oid] = outer.isSink;
              }
              for (final (k, f) in item.frames.indexed) {
                for (final port in t.inners) {
                  if (identical(port.frameOf, f)) {
                    names[port.oid] = '$id.t$j.f$k';
                    sinks[port.oid] = port.isSink;
                  }
                }
              }
            }
            for (final (k, f) in item.frames.indexed) {
              name(f, '$id.f$k.');
            }
          }
        case BdConstant() || BdPanelTerminal():
          names[item.oid] = id;
          sinks[item.oid] = item is BdPanelTerminal && item.isIndicator;
        case _:
          names[item.oid] = id;
      }
    }
  }

  void describe(BdFrame frame, String prefix, String pad) {
    for (final (i, item) in dataflowItems(frame).indexed) {
      final id = '$prefix$i';
      final record = diagram.byId[item.oid];
      switch (item) {
        case BdStructure():
          out.writeln('$pad$id ${item.objectClass.name} displayed ${record?.visibleFrameIndex ?? 0}');
          for (final (j, t) in item.borderTerminals.indexed) {
            final direction = t.outer == null
                ? 'inner'
                : t.outer!.isSink
                ? 'in'
                : 'out';
            out.writeln(
              '$pad  t$j ${t.kind.name}${t.indexing ? ' indexing' : ''} $direction frames ${t.inners.length}',
            );
          }
          for (final (k, f) in item.frames.indexed) {
            out.writeln('$pad  frame $k');
            describe(f, '$id.f$k.', '$pad    ');
          }
        case BdPrimitive():
          out.writeln('$pad$id prim ${item.op?.name ?? item.primResId}');
        case BdNode():
          out.writeln('$pad$id ${item.objectClass.name} ${item.terminals.map((t) => t.name).join(',')}');
        case BdConstant():
          final data = diagram.byId[item.data.oid];
          final value = data?.constText ?? data?.constNumeric ?? data?.constBool ?? data?.constArray;
          final label = data?.typeName == null ? '' : ' ${data!.typeName}';
          out.writeln('$pad$id const ${data?.dataType?.name}$label = $value');
        case BdPanelTerminal():
          out.writeln('$pad$id ${item.isIndicator ? 'indicator' : 'control'} ${record?.typeName}');
        case _:
          break;
      }
    }
    final edges = [
      for (final wire in frame.wires)
        () {
          final ends = wire.endpointOids;
          final source = ends.where((e) => sinks[e] == false).map((e) => names[e] ?? '?').join(',');
          final targets = [
            for (final e in ends)
              if (sinks[e] != false) names[e] ?? '?',
          ];
          return '$source -> ${targets.join(',')} : 0x${((wire.signalKind ?? 0) & 0xfff).toRadixString(16)}';
        }(),
    ]..sort();
    for (final edge in edges) {
      out.writeln('$pad$edge');
    }
  }

  name(editor.diagram, 'u');
  describe(editor.diagram, 'u', '');
  return out.toString();
}
