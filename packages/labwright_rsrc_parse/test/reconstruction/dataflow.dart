import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// What a block diagram computes, read back through the editor and spelled without object
/// ids or order: every placed object by what it is, every structure by its border terminals
/// and frames, every wire by the names of the endpoints it joins and its type word's depth
/// and code. Objects alike in every way are told apart by their order, nothing else is. Two
/// VIs with the same text wire the same things together.
String bdDataflow(ViModel model) {
  final diagram = model.primaryBlockDiagram!;
  final names = <int, String>{};
  final sinks = <int, bool>{};
  final lines = <String>[];

  String unique(Map<String, int> seen, String base) {
    final n = seen[base] = (seen[base] ?? 0) + 1;
    return n == 1 ? base : '$base#${n - 1}';
  }

  void frame(BdFrame f, String prefix) {
    final seen = <String, int>{};
    for (final item in f.placed) {
      final record = diagram.byId[item.oid];
      final String base;
      switch (item) {
        case BdStructure():
          base = '${item.objectClass.name} displayed ${record?.visibleFrameIndex ?? 0}';
        case BdPrimitive():
          base = 'prim ${item.op?.name ?? item.primResId}';
        case BdNode():
          base = '${item.objectClass.name} ${item.terminals.map((t) => t.name).join(',')}';
        case BdConstant():
          final data = diagram.byId[item.data.oid];
          final value = data?.constText ?? data?.constNumeric ?? data?.constBool ?? data?.constArray;
          final label = data?.typeName == null ? '' : ' ${data!.typeName}';
          base = 'const ${data?.dataType?.name}$label = $value';
        case BdPanelTerminal():
          base = '${item.isIndicator ? 'indicator' : 'control'} ${record?.typeName}';
        case _:
          continue;
      }
      final id = '$prefix${unique(seen, base)}';
      lines.add(id);
      switch (item) {
        case BdStructure():
          final kinds = <String, int>{};
          for (final t in item.borderTerminals) {
            final direction = t.holder == null
                ? 'inner'
                : t.outer.isSink
                ? 'in'
                : 'out';
            final tid = '$id.${unique(kinds, '${t.kind.name}${t.indexing ? ' indexing' : ''} $direction')}';
            lines.add('$tid frames ${t.inners.length}');
            if (t.holder != null) {
              names[t.outer.oid] = tid;
              sinks[t.outer.oid] = t.outer.isSink;
            }
            for (final (k, f) in item.frames.indexed) {
              for (final port in t.inners) {
                if (identical(port.frameOf, f)) {
                  names[port.oid] = '$tid.f$k';
                  sinks[port.oid] = port.isSink;
                }
              }
            }
          }
          for (final (k, f) in item.frames.indexed) {
            frame(f, '$id.f$k.');
          }
        case BdNode():
          for (final t in item.terminals) {
            names[t.oid] = '$id.${t.name}';
            sinks[t.oid] = t.isSink;
          }
        case _:
          names[item.oid] = id;
          sinks[item.oid] = item is BdPanelTerminal && item.isIndicator;
      }
    }
    for (final wire in f.wires) {
      final ends = wire.endpointOids;
      final source = ends.where((e) => sinks[e] == false).map((e) => names[e] ?? '?').join(',');
      final targets = [
        for (final e in ends)
          if (sinks[e] != false) names[e] ?? '?',
      ]..sort();
      lines.add('$source -> ${targets.join(',')} : 0x${((wire.signalKind ?? 0) & 0xfff).toRadixString(16)}');
    }
  }

  frame(model.diagram, '');
  lines.sort();
  return lines.join('\n');
}
