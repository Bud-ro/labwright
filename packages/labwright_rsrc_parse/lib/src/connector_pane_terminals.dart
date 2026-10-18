import 'blocks/CPMp_connector_pane_map.dart';
import 'blocks/FPTD_front_panel_datalog_type.dart';
import 'blocks/VCTP_type_pool.dart';
import 'front_panel/fp_object.dart';
import 'front_panel/fp_panel.dart';

/// The panel control behind each connector-pane terminal, in pane order, null where the terminal
/// is unwired or no control answers for it.
///
/// A `CPMp` map names each terminal's data item outright. Without one, the terminal is the
/// control whose `conNum` attribute says so, and terminal 0 is the one top-level control saved
/// without the attribute.
List<FpObject?> connectorPaneTerminals({
  required ViType? paneType,
  required List<FpPanel> panels,
  required ViConnectorPaneMap? map,
  required ViFrontPanelType? panelType,
  required ViTypePool? pool,
}) {
  if (paneType is! ViFunctionType) return const [];
  final controls = [for (final panel in panels) ...panel.controls];
  if (map != null) {
    final items = panelDataItems(controls, panelType: panelType, pool: pool);
    return [
      for (var i = 0; i < paneType.parameterCount; i++)
        switch (i < map.terminals.length ? map.terminals[i] : null) {
          PanelObjectTerminal(:final index) when index < items.length => items[index],
          _ => null,
        },
    ];
  }
  final unnumbered = [
    for (final control in controls)
      if (control.dataObject!.conNum == null) control,
  ];
  return [
    for (var i = 0; i < paneType.parameterCount; i++)
      switch ([
        for (final control in controls)
          if (control.dataObject!.conNum == i) control,
      ]) {
        [final control] => control,
        [] when i == 0 && unnumbered.length == 1 => unnumbered.single,
        _ => null,
      },
  ];
}

/// The panel's data items in `CPMp` order: the members of the cluster `FPTD` names
/// ([ViFrontPanelType.panelItemsIn]), each matched to the top-level control with the same name
/// and, when both pools are the VI's, the same type. Without `FPTD` the top-level controls
/// stand in reverse heap order, which is the same list wherever the corpus has both.
List<FpObject?> panelDataItems(
  List<FpObject> controls, {
  required ViFrontPanelType? panelType,
  required ViTypePool? pool,
}) {
  final reversed = controls.reversed.toList();
  if (panelType == null) return reversed;
  final items = panelType.panelItemsIn(pool);
  if (items == null) return reversed;
  final types = panelType is ViFrontPanelTypeInline ? panelType.pool.types : pool!.types;
  final sameTypes = panelType is! ViFrontPanelTypeInline;
  final bound = <FpObject>{};
  FpObject? match(int i, ViType member) {
    bool free(FpObject o) => !bound.contains(o);
    bool sameType(FpObject o) => !sameTypes || o.resolvedType?.type.offset == member.offset;
    bool sameName(FpObject o) => member.label != null && o.typeName == member.label;
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
