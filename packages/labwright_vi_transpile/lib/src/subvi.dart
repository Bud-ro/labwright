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

  /// The panel's data items in `CPMp` order; null where no panel object matches a member.
  final List<ViHeapObject?> panelDataItems;

  final Map<int, ViHeapObject> terminalOfDataItem;

  ViHeapObject? paneTerminal(int paneIndex) {
    if (paneIndex < 0 || paneIndex >= paneMap.length) return null;
    if (paneMap[paneIndex] case PanelObjectTerminal(:final index) when index < panelDataItems.length) {
      return switch (panelDataItems[index]) {
        final item? => terminalOfDataItem[item.oid],
        null => null,
      };
    }
    return null;
  }

  static LvViUnit? fromSections(Iterable<DecodedSection> sections, {required String fileName}) {
    final model = buildViModelFromDecoded(sections);
    final diagram = lvBlockDiagramOf(model);
    if (diagram == null) return null;
    final items = lvPanelDataItems(model, sections);
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
    if (section.tag == 'CPMp') return ViConnectorPaneMap(section.bytes).terminals;
  }
  return const <ConnectorTerminal>[];
}

/// The panel's data items in `CPMp` order: the members of the cluster `FPTD` names
/// ([ViFrontPanelType.panelItemsIn]), each matched to the top-level panel object with the same
/// name and, when both pools are the VI's, the same type. Without `FPTD` the top-level objects
/// stand in reverse heap order, which is the same list wherever the corpus has both.
List<ViHeapObject?> lvPanelDataItems(ViModel model, Iterable<DecodedSection> sections) {
  final top = <ViHeapObject>[
    for (final panel in model.frontPanelDiagrams)
      for (final object in panel.objects)
        if (object.kind == HeapObjectClass.node.code && object.typeDescIdx != null) object,
  ];
  DecodedSection? fptd, vctp;
  for (final section in sections) {
    if (section.tag == 'FPTD') fptd ??= section;
    if (section.tag == 'VCTP') vctp ??= section;
  }
  if (fptd == null) return top.reversed.toList();
  final frontPanelType = ViFrontPanelType(fptd.bytes);
  final pool = vctp == null ? null : ViTypePool(vctp.bytes);
  final items = frontPanelType.panelItemsIn(pool);
  if (items == null) return top.reversed.toList();
  final types = frontPanelType is ViFrontPanelTypeInline ? frontPanelType.pool.types : pool!.types;
  final sameTypes = frontPanelType is! ViFrontPanelTypeInline;
  final reversed = top.reversed.toList();
  final bound = <ViHeapObject>{};
  ViHeapObject? match(int i, ViType member) {
    bool free(ViHeapObject o) => !bound.contains(o);
    bool sameType(ViHeapObject o) => !sameTypes || o.resolvedType?.offset == member.offset;
    bool sameName(ViHeapObject o) => member.label != null && o.typeName == member.label;
    final positional = i < reversed.length && free(reversed[i]) ? reversed[i] : null;
    final hit = switch (positional) {
      final o? when sameType(o) && sameName(o) => o,
      _ =>
        reversed.where((o) => free(o) && sameType(o) && sameName(o)).firstOrNull ??
            (positional != null && sameType(positional) ? positional : null) ??
            reversed.where((o) => free(o) && sameName(o)).firstOrNull,
    };
    if (hit != null) bound.add(hit);
    return hit;
  }

  return [
    for (var i = 0; i < items.memberCount; i++)
      if (items.memberIndexAt(i) case final index when index < types.length) match(i, types[index]) else null,
  ];
}

Map<int, ViHeapObject> lvTerminalsOfDataItems(ViDiagram diagram) => {
  for (final object in diagram.objects)
    if (object.kind == HeapObjectClass.bdLeaf.code)
      for (final ref in object.refsOf(HeapRefKind.dcoRef) ?? const <int>[]) ref: object,
};
