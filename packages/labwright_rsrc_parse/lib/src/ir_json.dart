import 'blocks/type_pool.dart';
import 'graph.dart';
import 'heap.dart';
import 'ir.dart';

/// Serializes a recovered [ViDiagram] to a JSON-encodable map: its section tag
/// plus a **flat list of objects** carrying the positional nesting via
/// `parentOid`. Flat-with-parent (not a nested `children` tree) is deliberate —
/// it is lossless, avoids duplicating shared nodes, preserves the heap pre-order,
/// and the tree is trivially rebuilt from `parentOid`. Every drawable object
/// (one with absolute bounds) is represented.
///
/// Each node map omits null/empty fields to stay compact. Non-finite control
/// range sentinels (±infinity = "no bound") are dropped rather than emitted as
/// invalid JSON numbers. Deterministic: object order follows the diagram's
/// pre-order [ViDiagram.objects].
///
/// Honesty note on the two id fields: `parentOid` is the containment tree (the
/// nesting is rebuilt from it). `memberOids` is the heap's *declared*
/// childRef/memberRef reflist — NOT containment and NOT wire endpoints; it is
/// orthogonal to `parentOid` and diverges from it ~72% of the time, so a
/// consumer must not read it as the child list.
Map<String, Object?> viDiagramToJson(ViDiagram d) => {
      'sectionTag': d.sectionTag,
      'objects': [for (final o in d.objects) _objectToJson(o)],
    };

Map<String, Object?> _objectToJson(ViHeapObject o) {
  final cls = o.objectClass;
  return {
    'oid': o.oid,
    'kindCode': o.kind,
    'class': {
      'label': cls.label,
      'category': cls.category.name,
      'confidence': cls.confidence.name,
    },
    'objectKind': o.category.name,
    'typeKind': o.typeKind.name,
    if (o.parentOid != null) 'parentOid': o.parentOid,
    if (o.label != null) 'label': o.label,
    if (o.bounds != null) 'bounds': _rectToJson(o.bounds!),
    if (o.absBounds != null) 'absBounds': _rectToJson(o.absBounds!),
    if (o.items.isNotEmpty) 'items': o.items,
    if (o.termCount != 0) 'termCount': o.termCount,
    if (o.memberOids.isNotEmpty) 'memberOids': o.memberOids.toList(),
    if (o.controlMin != null && o.controlMin!.isFinite) 'controlMin': o.controlMin,
    if (o.controlMax != null && o.controlMax!.isFinite) 'controlMax': o.controlMax,
    if (o.helpText != null) 'helpText': o.helpText,
  };
}

Map<String, Object?> _rectToJson(HeapRect r) => {
      'top': r.top,
      'left': r.left,
      'bottom': r.bottom,
      'right': r.right,
    };

/// Serializes a whole [ViModel] to a JSON-encodable map — the top-level IR
/// artifact: schema version, VI identity (version/title/description), the
/// external symbols/library paths the VI calls (the Call-Library surface a
/// translator must bind), and the recovered block-diagram + front-panel object
/// trees ([viDiagramToJson]).
///
/// Scope note carried from [ViModel]: dataflow wires/edges are **not yet
/// decoded** (LabVIEW stores wires as geometry), so the IR is currently a typed,
/// nested object graph rather than a dataflow graph. Deterministic and
/// `jsonEncode`-safe (no non-finite numbers, no cycles).
/// The connector-pane terminals (kind + recovered name) resolved from the VI's
/// VCTP type pool, or null when no in-range conpane index is present. A cluster's
/// members are the terminals; otherwise the conpane type is a single terminal.
/// Direction (in/out) is not recovered, so it is not emitted.
List<Map<String, Object?>>? _conpaneTerminals(ViModel m) {
  final i = m.connectorPaneTypeIndex;
  if (i == null || i < 1 || i > m.types.length) return null;
  final cp = m.types[i - 1];
  final terms = cp.kind == ViDataType.cluster ? clusterFields(cp, m.types) : <ViType>[cp];
  return [
    for (final t in terms) _termJson(t, m.types),
  ];
}

/// A terminal/cluster field rendered as its `{kind, name?}` JSON object — the
/// shared shape used by both the connector-pane terminals and named-type members.
Map<String, Object?> _termJson(ViType t, List<ViType> types) =>
    {'kind': typeLabel(t, types), if (t.name != null) 'name': t.name};

Map<String, Object?> viModelToJson(ViModel m) {
  final terminals = _conpaneTerminals(m);
  final named = namedTypes(m.types);
  return {
    if (m.version != null) 'labviewVersion': m.version,
    if (m.title != null) 'title': m.title,
    if (m.description != null) 'description': m.description,
    if (m.symbolNames.isNotEmpty) 'symbolNames': m.symbolNames,
    if (m.paths.isNotEmpty) 'libraryPaths': m.paths,
    if (m.subViNames.isNotEmpty) 'subViNames': m.subViNames,
    if (m.connectorPaneTypeIndex != null) 'connectorPaneTypeIndex': m.connectorPaneTypeIndex,
    if (terminals != null) 'connectorPaneTerminals': terminals,
    if (m.types.isNotEmpty) 'typeCount': m.types.length,
    if (m.types.isNotEmpty) 'typeHistogram': typeKindHistogram(m.types),
    if (named.isNotEmpty)
      'namedTypes': [
        for (final t in named.take(200))
          {
            'index': t.index,
            'kind': typeLabel(t, m.types),
            'name': t.name,
            if (t.members.isNotEmpty)
              'members': [
                for (final f in clusterFields(t, m.types)) _termJson(f, m.types),
              ],
            if (t.enumItems.isNotEmpty) 'items': t.enumItems,
          },
      ],
    'blockDiagrams': [for (final d in m.blockDiagrams) viDiagramToJson(d)],
    'frontPanelDiagrams': [for (final d in m.frontPanelDiagrams) viDiagramToJson(d)],
  };
}
