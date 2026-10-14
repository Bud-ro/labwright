import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import '../corpus_dirs.dart';
import 'reconstruction_test.dart';

/// Prints where everything in a snippet sits. `dart run test/reconstruction/facts.dart
/// snippet.png [built]` lists each placed object's bounds and labels, each structure's
/// border terminals, and each wire's endpoints, table and placed points, for the corpus
/// snippet or for its reconstruction.
String rect(HeapRect? r) => r == null ? '-' : '(${r.top},${r.left},${r.bottom},${r.right})';

void main(List<String> args) {
  final model = args.length > 1 && args[1] == 'built'
      ? reconstructions[args[0]]!()
      : buildViModel(extractSnippetVi(snippetPng(args[0]).readAsBytesSync())!);
  final diagram = model.primaryBlockDiagram!;
  final names = <int, String>{};
  void index(BdFrame f) {
    for (final item in f.placed) {
      switch (item) {
        case BdStructure():
          for (final t in item.borderTerminals) {
            if (t.outer case final o?) names[o.oid] = '${item.objectClass.name}.${t.kind.name}';
            for (final p in t.inners) {
              names[p.oid] = '${item.objectClass.name}.${t.kind.name}.inner';
            }
          }
          for (final fr in item.frames) {
            index(fr);
          }
        case BdNode():
          for (final t in item.terminals) {
            names[t.oid] = '${item is BdPrimitive ? item.op?.name : item.objectClass.name}.${t.name}';
          }
        case BdConstant():
          names[item.oid] = 'const';
        case BdPanelTerminal():
          names[item.oid] = 'panel ${diagram.byId[item.oid]?.typeName}';
        case _:
          break;
      }
    }
  }

  index(model.blockDiagram.diagram);
  void frame(BdFrame f, String pad) {
    for (final item in f.placed) {
      final o = diagram.byId[item.oid];
      final labels = [
        for (final node in item.node.children.objects)
          if (node.kind == HeapObjectClass.controlLabel.code)
            'label ${rect(node.children.bounds)} "${node.children.c4(HeapOpcode.caption)?.text ?? ''}"',
      ];
      switch (item) {
        case BdStructure():
          print('$pad${item.objectClass.name} ${rect(item.bounds)}');
          for (final t in item.borderTerminals) {
            print(
              '$pad  ${t.kind.name}${t.indexing ? ' indexing' : ''} ${t.outer == null
                  ? 'inner'
                  : t.outer!.isSink
                  ? 'in'
                  : 'out'} ${rect(t.termBounds)}',
            );
          }
          for (final (k, fr) in item.frames.indexed) {
            print('$pad  frame $k');
            frame(fr, '$pad    ');
          }
        case BdPrimitive():
          print('$pad${item.op?.name ?? item.primResId} ${rect(item.bounds)} ${labels.join(' ')}');
        case BdNode():
          print('$pad${item.objectClass.name} ${rect(item.bounds)}');
        case BdConstant():
          final data = diagram.byId[item.data.oid];
          final parts = [
            for (final node
                in item.data.children.objects.first.children.group(kControlParts)?.children.objects ??
                    const <HeapObjectNode>[])
              if (node.kind == HeapObjectClass.controlLabel.code)
                'label ${rect(node.children.bounds)} "${node.children.c4(HeapOpcode.caption)?.text ?? ''}"',
          ];
          print('$pad const ${data?.typeName} ${rect(item.bounds)} ${parts.join(' ')}');
        case BdPanelTerminal():
          print(
            '$pad${item.isIndicator ? 'indicator' : 'control'} ${o?.typeName} ${rect(item.bounds)} ${labels.join(' ')}',
          );
        case _:
          print('$pad${item.objectClass.name} ${rect(item.bounds)} ${labels.join(' ')}');
      }
    }
    for (final w in f.wires) {
      final parsed = diagram.wires.firstWhere((x) => x.signalOid == w.oid);
      final table = w.node.children
          .whereType<HeapRecordNode>()
          .map((r) => wireTableOfRecord(r.bytes))
          .whereType<Uint8List>()
          .firstOrNull;
      print(
        '${pad}wire ${w.endpointOids.map((e) => names[e] ?? e).join(' -> ')} table=${table?.map((b) => b.toRadixString(16)).join(' ')} points=${parsed.routePoints ?? parsed.routeTree?.polylines}',
      );
    }
  }

  frame(model.blockDiagram.diagram, '');
}
