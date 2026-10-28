import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

BdDiagram? lvBlockDiagramOf(ViModel model) {
  BdDiagram? best;
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

  /// The block diagram's call link entries ([kLvCallLinkKinds]): each callee's qualified name
  /// and path record.
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

  /// The link entry a call [node] reaches: the one naming its label, or, among several, the one
  /// method whose class a terminal descriptor of the node names, as a class method's dispatch
  /// terminal does; null when none or several remain.
  ViLinkEntryFramed? linkOfNode(BdObject node) {
    final name = node.label?.trim().toLowerCase();
    if (name == null) return null;
    final named = [
      for (final link in links)
        if (link.qualifiedName.lastOrNull?.toLowerCase() == name) link,
    ];
    if (named.length <= 1) return named.singleOrNull;
    final classes = <String>{
      for (final holder in diagram.childrenOf(node))
        for (final record in diagram.childrenOf(holder))
          if (lvClassNamedBy(record.resolvedType?.type) case final qualified?) qualified.join(':').toLowerCase(),
    };
    final owned = [
      for (final link in named)
        if (classes.contains(link.qualifiedName.sublist(0, link.qualifiedName.length - 1).join(':').toLowerCase()))
          link,
    ];
    return owned.singleOrNull;
  }

  final BdDiagram diagram;

  final List<ViType> pool;

  /// The panel control behind each connector-pane terminal, [ViModel.paneTerminals].
  final List<FpObject?> paneTerminals;

  final Map<int, BdObject> terminalOfDataItem;

  /// The block-diagram terminal of the control behind pane terminal [paneIndex].
  BdObject? paneTerminal(int paneIndex) {
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

/// The class a class-instance descriptor names, through typedefs; null for any other.
List<String>? lvClassNamedBy(ViType? type) {
  for (var depth = 0; type is ViTypedefType && depth < 8; depth++) {
    type = type.base;
  }
  if (type is ViRefnumType && type.refnumKind == ViRefnumKind.classInstance && type.classQualifiedName.isNotEmpty) {
    return type.classQualifiedName;
  }
  return null;
}

/// The block diagram's sub-VI link entries, in link order.
/// The link-entry kinds that name a VI a block-diagram node calls: a sub-VI (`IUVI`), a
/// polymorphic VI (`PUPV`) and a dynamic-dispatch class method (`DyOM`).
const Set<String> kLvCallLinkKinds = {'IUVI', 'PUPV', 'DyOM'};

/// The link kind of a dynamic-dispatch class method, whose path record names the class file.
const String kLvDynamicDispatchLinkKind = 'DyOM';

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
      if (entry is ViLinkEntryFramed && kLvCallLinkKinds.contains(entry.kind)) entry,
  ];
}

Map<int, BdObject> lvTerminalsOfDataItems(BdDiagram diagram) => {
  for (final object in diagram.objects)
    if (object.kind == BdObjectClass.panelTerminal.code)
      for (final ref in object.refsOf(HeapRefKind.dcoRef) ?? const <int>[]) ref: object,
};

/// The node class of a call to a polymorphic VI, which draws the connector pane of the instance
/// it selected.
const int kLvPolymorphicCallNodeCode = 0x00c5;

/// What a type descriptor in [pool] is compared by when a polymorphic call's terminals are
/// matched to an instance's pane: its code and label, and those of its typedef base, array
/// element and cluster members, recursively.
String lvTerminalSignature(ViType? type, List<ViType> pool, [int depth = 0]) {
  if (type == null) return '';
  if (depth > 16) return '…';
  final inner = switch (type) {
    ViTypedefType(:final base) => lvTerminalSignature(base, pool, depth + 1),
    ViArrayType(:final dimCount, :final elementIndex) when elementIndex < pool.length =>
      '$dimCount×${lvTerminalSignature(pool[elementIndex], pool, depth + 1)}',
    ViClusterType() => clusterFields(
      type,
      pool,
    ).map((member) => lvTerminalSignature(member, pool, depth + 1)).join(','),
    _ => '',
  };
  return '${type.code}:${type.label ?? ''}($inner)';
}

/// The instance of [polymorphic] that a call [node] of [caller] selected: the one instance, among
/// those [polymorphic]'s own call links name and [resolve] supplies, whose connector-pane
/// terminals carry the descriptors the node's terminals do, pane for pane. Null, with why, when
/// none or several match.
({LvViUnit? instance, String? why}) lvPolymorphicInstance(
  BdDiagram diagram,
  BdObject node,
  LvViUnit polymorphic,
  LvViResolver resolve, {
  required List<ViType> pool,
}) {
  final drawn = [
    for (final holder in diagram.childrenOf(node))
      if (holder.objectClass == BdObjectClass.terminalHolder)
        lvTerminalSignature(diagram.childrenOf(holder).firstOrNull?.resolvedType?.type, pool),
  ];
  final matches = <LvViUnit>[];
  var candidates = 0;
  for (final link in polymorphic.links) {
    final name = link.qualifiedName.lastOrNull;
    if (name == null) continue;
    final instance = resolve(LvCallee(caller: polymorphic, fileName: name, link: link));
    if (instance == null) continue;
    candidates++;
    if (instance.paneTerminals.length != drawn.length) continue;
    var same = true;
    for (var pane = 0; pane < drawn.length && same; pane++) {
      final terminal = instance.paneTerminal(pane);
      final declared = lvTerminalSignature(terminal?.resolvedType?.type, instance.pool);
      same = terminal == null
          ? drawn[pane].startsWith('${TypeCode.voidType}:') || drawn[pane].isEmpty
          : declared == drawn[pane];
    }
    if (same &&
        !matches.any((match) => identical(match, instance) || (match.path != null && match.path == instance.path))) {
      matches.add(instance);
    }
  }
  return switch (matches) {
    [final instance] => (instance: instance, why: null),
    [] => (
      instance: null,
      why: '"${polymorphic.fileName}" supplies $candidates instances and none draws the connector pane the call does',
    ),
    _ => (
      instance: null,
      why: '${matches.length} instances of "${polymorphic.fileName}" draw the connector pane the call does',
    ),
  };
}
