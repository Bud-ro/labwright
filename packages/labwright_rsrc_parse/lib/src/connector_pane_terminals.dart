import 'blocks/CPMp_connector_pane_map.dart';
import 'blocks/FPTD_front_panel_datalog_type.dart';
import 'blocks/VCTP_type_pool.dart';
import 'front_panel/fp_object.dart';
import 'front_panel/fp_panel.dart';

/// The panel data object behind each connector-pane terminal, in pane order, null where the
/// terminal is unwired or no data object answers for it.
///
/// A `CPMp` map names each terminal's data item outright. Without one, the terminal is the
/// data object whose `conNum` attribute says so, and terminal 0 is the one top-level data
/// object saved without the attribute.
List<FpDataObject?> connectorPaneTerminals({
  required ViType? paneType,
  required List<FpPanel> panels,
  required ViConnectorPaneMap? map,
  required ViFrontPanelType? panelType,
  required ViTypePool? pool,
}) {
  if (paneType is! ViFunctionType) return const [];
  final dataObjects = [for (final panel in panels) ...panel.dataObjects];
  if (map != null) {
    final items = panelDataItems(dataObjects, panelType: panelType, pool: pool);
    return [
      for (var i = 0; i < paneType.parameterCount; i++)
        switch (i < map.terminals.length ? map.terminals[i] : null) {
          PanelObjectTerminal(:final index) when index < items.length => items[index],
          _ => null,
        },
    ];
  }
  final unnumbered = [
    for (final dco in dataObjects)
      if (dco.conNum == null) dco,
  ];
  return [
    for (var i = 0; i < paneType.parameterCount; i++)
      switch ([
        for (final dco in dataObjects)
          if (dco.conNum == i) dco,
      ]) {
        [final dco] => dco,
        [] when i == 0 && unnumbered.length == 1 => unnumbered.single,
        _ => null,
      },
  ];
}

/// The panel's data items in `CPMp` order: the members of the cluster `FPTD` names
/// ([ViFrontPanelType.panelItemsIn]), each matched to the top-level data object with the same
/// name and, when both pools are the VI's, the same type. Without `FPTD` the data objects stand
/// in reverse heap order, which is the same list wherever the corpus has both.
List<FpDataObject?> panelDataItems(
  List<FpDataObject> dataObjects, {
  required ViFrontPanelType? panelType,
  required ViTypePool? pool,
}) {
  final reversed = dataObjects.reversed.toList();
  if (panelType == null) return reversed;
  final items = panelType.panelItemsIn(pool);
  if (items == null) return reversed;
  final types = panelType is ViFrontPanelTypeInline ? panelType.pool.types : pool!.types;
  final sameTypes = panelType is! ViFrontPanelTypeInline;
  final bound = <FpDataObject>{};
  FpDataObject? match(int i, ViType member) {
    bool free(FpDataObject o) => !bound.contains(o);
    bool sameType(FpDataObject o) => !sameTypes || o.resolvedType?.type.offset == member.offset;
    bool sameName(FpDataObject o) => member.label != null && o.typeName == member.label;
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
