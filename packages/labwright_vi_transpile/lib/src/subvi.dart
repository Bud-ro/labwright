import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'emit.dart';

class LvViUnit {
  LvViUnit({
    required this.fileName,
    required this.diagram,
    required this.pool,
    required this.paneMap,
    required this.panelDataItems,
    required this.terminalOfDataItem,
  });

  final String fileName;

  final ViDiagram diagram;

  final List<ViType> pool;

  final List<ConnectorTerminal> paneMap;

  final List<ViHeapObject> panelDataItems;

  final Map<int, ViHeapObject> terminalOfDataItem;

  ViHeapObject? paneTerminal(int paneIndex) {
    if (paneIndex < 0 || paneIndex >= paneMap.length) return null;
    if (paneMap[paneIndex] case PanelObjectTerminal(:final index) when index < panelDataItems.length) {
      return terminalOfDataItem[panelDataItems[index].oid];
    }
    return null;
  }

  static LvViUnit? fromSections(Iterable<DecodedSection> sections, {required String fileName}) {
    final model = buildViModelFromDecoded(sections);
    final diagram = lvBlockDiagramOf(model);
    if (diagram == null) return null;
    final items = lvPanelDataItems(model);
    return LvViUnit(
      fileName: fileName,
      diagram: diagram,
      pool: model.types,
      paneMap: lvConnectorPaneMap(sections),
      panelDataItems: items,
      terminalOfDataItem: lvTerminalsOfDataItems(diagram),
    );
  }
}

List<ConnectorTerminal> lvConnectorPaneMap(Iterable<DecodedSection> sections) {
  for (final section in sections) {
    if (section.tag == 'CPMp') return decodeConnectorPaneMap(section.bytes).terminals;
  }
  return const <ConnectorTerminal>[];
}

List<ViHeapObject> lvPanelDataItems(ViModel model) => <ViHeapObject>[
  for (final panel in model.frontPanelDiagrams)
    for (final object in panel.objects)
      if (object.kind == HeapObjectClass.node.code && object.typeDescIdx != null) object,
]..sort((a, b) => b.typeDescIdx!.compareTo(a.typeDescIdx!));

Map<int, ViHeapObject> lvTerminalsOfDataItems(ViDiagram diagram) => {
  for (final object in diagram.objects)
    if (object.kind == HeapObjectClass.bdLeaf.code)
      for (final ref in object.typedRefs[HeapRefKind.dcoRef] ?? const <int>[]) ref: object,
};
