import 'graph.dart';
import 'heap.dart';
import 'ir.dart';
import 'type_pool.dart';

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
  final m = <String, Object?>{
    'oid': o.oid,
    'kindCode': o.kind,
    // the documented class catalog entry: human label + structural category +
    // how well-grounded the name is (clean-room honesty).
    'class': {
      'label': cls.label,
      'category': cls.category.name,
      'confidence': cls.confidence.name,
    },
    'objectKind': o.category.name,
    'typeKind': o.typeKind.name,
  };
  if (o.parentOid != null) m['parentOid'] = o.parentOid;
  if (o.label != null) m['label'] = o.label;
  if (o.bounds != null) m['bounds'] = _rectToJson(o.bounds!);
  if (o.absBounds != null) m['absBounds'] = _rectToJson(o.absBounds!);
  if (o.items.isNotEmpty) m['items'] = o.items;
  if (o.termCount != 0) m['termCount'] = o.termCount;
  final members = o.memberOids.toList();
  if (members.isNotEmpty) m['memberOids'] = members;
  if (o.controlMin != null && o.controlMin!.isFinite) m['controlMin'] = o.controlMin;
  if (o.controlMax != null && o.controlMax!.isFinite) m['controlMax'] = o.controlMax;
  if (o.helpText != null) m['helpText'] = o.helpText;
  return m;
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
    for (final t in terms) {'kind': typeLabel(t, m.types), if (t.name != null) 'name': t.name},
  ];
}

Map<String, Object?> viModelToJson(ViModel m) => {
      if (m.version != null) 'labviewVersion': m.version,
      if (m.title != null) 'title': m.title,
      if (m.description != null) 'description': m.description,
      if (m.symbolNames.isNotEmpty) 'symbolNames': m.symbolNames,
      if (m.paths.isNotEmpty) 'libraryPaths': m.paths,
      if (m.subViNames.isNotEmpty) 'subViNames': m.subViNames,
      // Connector pane (the VI's interface): the VCTP index + resolved terminal
      // types/names. Input/output direction is NOT recovered from the diagram.
      if (m.connectorPaneTypeIndex != null) 'connectorPaneTypeIndex': m.connectorPaneTypeIndex,
      if (_conpaneTerminals(m) != null) 'connectorPaneTerminals': _conpaneTerminals(m),
      // VCTP type pool: a compact inventory (count + kind histogram). The full
      // ordered descriptor list lives on ViModel.types; the JSON keeps a summary.
      if (m.types.isNotEmpty) 'typeCount': m.types.length,
      if (m.types.isNotEmpty) 'typeHistogram': typeKindHistogram(m.types),
      // named typedefs / labelled data items (capped to keep the IR compact)
      if (namedTypes(m.types).isNotEmpty)
        'namedTypes': [
          for (final t in namedTypes(m.types).take(200))
            {
              'index': t.index,
              'kind': typeLabel(t, m.types), // resolves array<elem>
              'name': t.name,
              // for a named cluster, its resolved member fields (the struct)
              if (t.members.isNotEmpty)
                'members': [
                  for (final f in clusterFields(t, m.types)) {'kind': typeLabel(f, m.types), if (f.name != null) 'name': f.name},
                ],
              if (t.enumItems.isNotEmpty) 'items': t.enumItems,
            },
        ],
      'blockDiagrams': [for (final d in m.blockDiagrams) viDiagramToJson(d)],
      'frontPanelDiagrams': [for (final d in m.frontPanelDiagrams) viDiagramToJson(d)],
    };
