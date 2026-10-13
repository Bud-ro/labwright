import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

ViDiagram? lvBlockDiagramOf(ViModel model) {
  ViDiagram? best;
  for (final diagram in model.blockDiagrams) {
    if (best == null || diagram.objects.length > best.objects.length) best = diagram;
  }
  return best == null || best.objects.isEmpty ? null : best;
}

/// A call node's callee as its caller states it: the file name the node draws and the caller's
/// link entry for it, which carries the callee's qualified name and path record.
class LvCallee {
  const LvCallee({required this.caller, required this.fileName, required this.link});

  final LvViUnit caller;

  final String fileName;

  final ViLinkEntryFramed? link;
}

typedef LvViResolver = LvViUnit? Function(LvCallee callee);

class LvViUnit {
  LvViUnit({
    required this.fileName,
    required this.diagram,
    required this.pool,
    required this.paneTerminals,
    required this.terminalOfDataItem,
    this.path,
    this.links = const [],
  });

  final String fileName;

  /// The VI's file on disk, from which its relative links resolve; null for a VI held in memory.
  final String? path;

  /// The block diagram's sub-VI link entries (`LIbd` kind `IUVI`): each callee's qualified
  /// name and path record.
  final List<ViLinkEntryFramed> links;

  /// The link entry naming [calleeFileName], or null when none or several do.
  ViLinkEntryFramed? linkTo(String calleeFileName) {
    final lower = calleeFileName.toLowerCase();
    ViLinkEntryFramed? found;
    for (final link in links) {
      if (link.qualifiedName.isEmpty || link.qualifiedName.last.toLowerCase() != lower) continue;
      if (found != null) return null;
      found = link;
    }
    return found;
  }

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

  static LvViUnit? fromSections(Iterable<DecodedSection> sections, {required String fileName, String? path}) {
    final model = buildViModelFromDecoded(sections);
    final diagram = lvBlockDiagramOf(model);
    if (diagram == null) return null;
    return LvViUnit(
      fileName: fileName,
      diagram: diagram,
      pool: model.types,
      paneTerminals: model.paneTerminals,
      terminalOfDataItem: lvTerminalsOfDataItems(diagram),
      path: path,
      links: lvSubViLinks(sections),
    );
  }
}

/// The block diagram's sub-VI link entries, in link order.
List<ViLinkEntryFramed> lvSubViLinks(Iterable<DecodedSection> sections) {
  DecodedSection? libd, vers;
  for (final section in sections) {
    if (section.tag == 'LIbd') libd ??= section;
    if (section.tag == 'vers') vers ??= section;
  }
  if (libd == null) return const [];
  final version = vers == null ? null : ViVersBlock(vers.bytes).versionWord;
  return [
    for (final entry in ViLinkInfo(libd.bytes, version: version).entries)
      if (entry is ViLinkEntryFramed && entry.kind == 'IUVI') entry,
  ];
}

Map<int, ViHeapObject> lvTerminalsOfDataItems(ViDiagram diagram) => {
  for (final object in diagram.objects)
    if (object.kind == HeapObjectClass.bdLeaf.code)
      for (final ref in object.refsOf(HeapRefKind.dcoRef) ?? const <int>[]) ref: object,
};
