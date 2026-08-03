/// The **connector-pane contract**: how a subVI call node's terminals reach
/// the called VI's controls and indicators.
///
/// A call node and the VI it calls live in different files, and neither states
/// the other's names. Three decoded facts join them, each corpus-censused:
///
/// 1. **A call node holds one endpoint holder per connector-pane terminal, in
///    pane-index order.** Over 9 973 calls whose callee is in the corpus and
///    carries a `CPMp` block, 8 758 (87.8%) have exactly as many holders as
///    the callee's pane has terminals. The order is the pane's own: over the
///    16 711 calls on a twelve-terminal pane, holder 0 is a producer 9 991
///    times against 1 consumer and holder 11 a consumer 12 123 times against
///    595 producers — the left/right split a connector pane is drawn with.
/// 2. **`CPMp[i]` names the callee's i-th pane terminal's panel data item**,
///    counted over the panel's DCOs from the LAST data-space slot backwards
///    ([lvPanelDataItems]). Cross-checked from the call side over 30 587 wired
///    call terminals: the caller's own direction agrees with the named data
///    item's control/indicator bit 30 536 times (99.83%). The three other
///    orderings the panel admits score 55.1%, 89.7% and 52.3%, so the choice
///    is measured rather than assumed.
/// 3. **A panel data item is joined to the block-diagram terminal that draws
///    it** by that terminal's `dcoRef` — 17 461 of 17 465 panel data items
///    (99.98%), agreeing on direction 30 449 of 30 492 times (99.86%).
///
/// Every step that does not resolve is refused by name
/// ([LvRefusalKind.subViCall]); none is guessed at.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'dataflow_ir.dart';
import 'emit.dart';

/// The heap class code of a **panel data item** (a DCO): the front-panel
/// record a control or indicator's value lives in, and the thing a connector
/// pane's terminals are assigned to.
const int kLvPanelDataItemCode = 0x12;

/// One VI as the transpiler consumes it: the block diagram code is lowered
/// from, the type pool wires resolve through, and the connector-pane binding a
/// caller reaches its terminals by.
class LvViUnit {
  LvViUnit({
    required this.fileName,
    required this.diagram,
    required this.pool,
    required this.paneMap,
    required this.panelDataItems,
    required this.terminalOfDataItem,
  });

  /// The VI's file name as a call node spells it (`crc8.vi`).
  final String fileName;

  /// The block diagram the VI's code is lowered from.
  final ViDiagram diagram;

  /// The VI's consolidated type pool.
  final List<ViType> pool;

  /// The connector pane's `CPMp` assignments, one entry per pane terminal:
  /// the index into [panelDataItems] the terminal is wired to, or null when
  /// the pane position is unassigned.
  final List<int?> paneMap;

  /// The panel data items in [paneMap]'s index space ([lvPanelDataItems]).
  final List<ViHeapObject> panelDataItems;

  /// Per panel data item oid, the block-diagram terminal that draws it.
  final Map<int, ViHeapObject> terminalOfDataItem;

  /// The VI's interface terminal for pane position [paneIndex], or null when
  /// the position is unassigned, out of range, or joins no terminal.
  ViHeapObject? paneTerminal(int paneIndex) {
    if (paneIndex < 0 || paneIndex >= paneMap.length) return null;
    final item = paneMap[paneIndex];
    if (item == null || item < 0 || item >= panelDataItems.length) return null;
    return terminalOfDataItem[panelDataItems[item].oid];
  }

  /// The VI's decoded sections as one unit, or null when the sections carry no
  /// block diagram with content.
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

/// The `CPMp` connector-pane assignments in [sections], or `const []` when the
/// block is absent or does not frame.
List<int?> lvConnectorPaneMap(Iterable<DecodedSection> sections) {
  for (final section in sections) {
    if (section.tag == 'CPMp') return decodeConnectorPaneMap(section.bytes)?.terminals ?? const <int?>[];
  }
  return const <int?>[];
}

/// [model]'s panel data items in the connector pane's own index space: the
/// front panel's DCOs ordered from the LAST data-space slot backwards.
///
/// The descending order is the measured one — see the library doc for the four
/// orderings and their scores.
List<ViHeapObject> lvPanelDataItems(ViModel model) => <ViHeapObject>[
  for (final panel in model.frontPanelDiagrams)
    for (final object in panel.objects)
      if (object.kind == kLvPanelDataItemCode && object.typeDescIdx != null) object,
]..sort((a, b) => b.typeDescIdx!.compareTo(a.typeDescIdx!));

/// Per panel-data-item oid, the connector-pane terminal of [diagram] that
/// draws it — the terminal's own `dcoRef`.
Map<int, ViHeapObject> lvTerminalsOfDataItems(ViDiagram diagram) => {
  for (final object in diagram.objects)
    if (object.kind == kLvInterfaceTerminalCode)
      for (final ref in object.typedRefs[HeapRefKind.dcoRef] ?? const <int>[]) ref: object,
};
