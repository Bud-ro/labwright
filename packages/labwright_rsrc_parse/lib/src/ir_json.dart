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
/// childRef/dcoRef reflist — orthogonal to `parentOid` and diverging from it
/// ~72% of the time, so a consumer must not read it as the child list. For a
/// structure it is child membership (not containment); for a **signal** (`0x17`,
/// a dataflow wire) it is the wire's endpoint objects (see [ViWire]).
Map<String, Object?> viDiagramToJson(ViDiagram d) => {
  'sectionTag': d.sectionTag,
  'objects': d.objects.map(_objectToJson).toList(),
};

Map<String, Object?> _objectToJson(ViHeapObject object) {
  final cls = object.objectClass;
  return {
    'oid': object.oid,
    'kindCode': object.kind,
    'class': {
      'label': cls.label,
      'category': cls.category.name,
      'confidence': cls.confidence.name,
    },
    'objectKind': object.category.name,
    'typeKind': object.typeKind.name,
    if (object.parentOid != null) 'parentOid': object.parentOid,
    if (object.label != null) 'label': object.label,
    if (object.bounds != null) 'bounds': _rectToJson(object.bounds!),
    if (object.absBounds != null) 'absBounds': _rectToJson(object.absBounds!),
    if (object.items.isNotEmpty) 'items': object.items,
    if (object.termCount != 0) 'termCount': object.termCount,
    if (object.memberOids.isNotEmpty) 'memberOids': object.memberOids.toList(),
    if (object.controlMin?.isFinite ?? false) 'controlMin': object.controlMin,
    if (object.controlMax?.isFinite ?? false) 'controlMax': object.controlMax,
    if (object.helpText != null) 'helpText': object.helpText,
    if (object.constText != null) 'constText': object.constText,
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
/// Scope note carried from [ViModel]: dataflow **wire endpoint binding** is
/// decoded — each signal (`0x17`) object emits its endpoint objects as
/// `memberOids` (see [ViWire] / [ViDiagram.wires]) — but wire **datatype** and
/// packed **route geometry** are not decoded, so the IR is a typed, nested
/// object graph with wire endpoints rather than a fully typed dataflow graph.
/// Deterministic and `jsonEncode`-safe (no non-finite numbers, no cycles).
/// The connector-pane terminals (kind + recovered name) resolved from the VI's
/// VCTP type pool, or null when no in-range conpane index is present. A cluster's
/// members are the terminals; otherwise the conpane type is a single terminal.
/// Direction (in/out) is not recovered, so it is not emitted.
List<Map<String, Object?>>? _conpaneTerminals(ViModel m) {
  final typeIndex = m.connectorPaneTypeIndex;
  if (typeIndex == null || typeIndex < 1 || typeIndex > m.types.length) return null;
  final conpaneType = m.types[typeIndex - 1];
  final terms = conpaneType.kind == ViDataType.cluster ? clusterFields(conpaneType, m.types) : <ViType>[conpaneType];
  return [for (final term in terms) _termJson(term, m.types)];
}

/// A terminal/cluster field rendered as its `{kind, name?}` JSON object — the
/// shared shape used by both the connector-pane terminals and named-type members.
Map<String, Object?> _termJson(ViType t, List<ViType> types) => {
  'kind': typeLabel(t, types),
  if (t.name != null) 'name': t.name,
};

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
    if (m.types.isNotEmpty) ...{
      'typeCount': m.types.length,
      'typeHistogram': typeKindHistogram(m.types),
    },
    if (named.isNotEmpty)
      'namedTypes': [
        for (final type in named.take(200))
          {
            'index': type.index,
            'kind': typeLabel(type, m.types),
            'name': type.name,
            if (type.members.isNotEmpty)
              'members': [
                for (final field in clusterFields(type, m.types)) _termJson(field, m.types),
              ],
            if (type.enumItems.isNotEmpty) 'items': type.enumItems,
          },
      ],
    'blockDiagrams': [for (final diagram in m.blockDiagrams) viDiagramToJson(diagram)],
    'frontPanelDiagrams': [for (final diagram in m.frontPanelDiagrams) viDiagramToJson(diagram)],
  };
}
