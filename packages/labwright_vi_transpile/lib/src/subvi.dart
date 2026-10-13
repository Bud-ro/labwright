import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'emit.dart';

class LvViUnit {
  LvViUnit({
    required this.fileName,
    required this.diagram,
    required this.pool,
    required this.paneTerminals,
    required this.terminalOfDataItem,
  });

  final String fileName;

  final ViDiagram diagram;

  final List<ViType> pool;

  /// The panel control behind each connector-pane terminal, [ViModel.paneTerminals].
  final List<ViHeapObject?> paneTerminals;

  final Map<int, ViHeapObject> terminalOfDataItem;

  /// The block-diagram terminal of the control behind pane terminal [paneIndex].
  ViHeapObject? paneTerminal(int paneIndex) {
    if (paneIndex < 0 || paneIndex >= paneTerminals.length) return null;
    return switch (paneTerminals[paneIndex]) {
      final control? => terminalOfDataItem[control.oid],
      null => null,
    };
  }

  static LvViUnit? fromSections(Iterable<DecodedSection> sections, {required String fileName}) {
    final model = buildViModelFromDecoded(sections);
    final diagram = lvBlockDiagramOf(model);
    if (diagram == null) return null;
    return LvViUnit(
      fileName: fileName,
      diagram: diagram,
      pool: model.types,
      paneTerminals: model.paneTerminals,
      terminalOfDataItem: lvTerminalsOfDataItems(diagram),
    );
  }
}

Map<int, ViHeapObject> lvTerminalsOfDataItems(ViDiagram diagram) => {
  for (final object in diagram.objects)
    if (object.kind == HeapObjectClass.bdLeaf.code)
      for (final ref in object.refsOf(HeapRefKind.dcoRef) ?? const <int>[]) ref: object,
};
