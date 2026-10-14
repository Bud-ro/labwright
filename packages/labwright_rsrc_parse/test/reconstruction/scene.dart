import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// What a block diagram draws, spelled without positions or sizes: every drawable object by
/// its class and label, every structure's border terminals by kind, every constant's shown
/// value, every wire by how many ends it has, each list sorted. Two diagrams with the same
/// text draw the same things, wherever they put them.
String bdSceneText(ViModel model) {
  final diagram = model.primaryBlockDiagram!;
  final semantics = ViDiagramSemantics(diagram);
  final kinds = semantics.borderTerminalKinds;
  final lines = <String>[];
  for (final object in semantics.drawable) {
    final b = object.absBounds;
    final label = nodeDisplayLabel(object);
    if (object.objectClass == HeapObjectClass.controlLabel &&
        (label.isHint || label.text.isEmpty || object.hasFlag(ViObjFlag.labelHidden))) {
      continue;
    }
    final text = label.isHint ? '' : ' "${label.text}"';
    final value = semantics.constValues[object.oid];
    final border = b == null ? null : kinds[b];
    lines.add(
      '${object.objectClass.name}$text'
      '${value == null ? '' : ' = $value'}'
      '${border == null ? '' : ' ${border.objectClass.name}'}',
    );
  }
  lines.sort();
  final terminals = <String>[
    for (final MapEntry(key: oid, value: boxes) in semantics.structureTerminals.entries)
      '${diagram.byId[oid]?.objectClass.name} terminals ${boxes.map((t) => t.bmp).toList()..sort()}',
  ]..sort();
  final wires = <String>[for (final wire in semantics.wires) 'wire ${wire.endpointOids.length} ends']..sort();
  return [...lines, ...terminals, ...wires].join('\n');
}
